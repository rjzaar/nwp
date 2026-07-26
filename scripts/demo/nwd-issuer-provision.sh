#!/bin/bash
set -euo pipefail
################################################################################
# scripts/demo/nwd-issuer-provision.sh — provision the DEMO provider (nwd) as an
# OpenID Connect issuer for its demo consumer (ssd). ops#133 Phase 2.
#
#   AUTH SURFACE — DEMO PAIR ONLY, dev + live tiers only.
#
# This is the demo-tier sibling of scripts/f26/provision-nwc-issuer.sh (which
# provisions the REAL nwc issuer for ssc). It is deliberately a separate file
# rather than a flag on that one, because it carries a guard the generic script
# cannot: it refuses to run unless the target site is the PROVIDER of a pair
# contract that declares `demo.enabled: true`. An auth-surface script that can
# only ever point at a throwaway demo pair is a much smaller thing to review.
#
# ops#146 implemented the live half, so the tier gate now admits dev and live and
# refuses stg/prod. What bounds this script is therefore the CONTRACT gate, not
# the tier: `pairs/ssc.pair-contract.yml` carries no `demo:` block, so the real
# student-bearing pair is unreachable from here no matter what --tier says.
# Nothing on the live path relaxes a security control — the live JWKS probe
# verifies TLS (dev keeps -k for ddev's self-signed cert), the client secret is
# per-tier, and there is no live equivalent of the consumer script's ddev
# reachability shims because a live provider needs none.
#
#   scripts/demo/nwd-issuer-provision.sh [--site=nwd] [--tier=dev|live]
#
# What it does (all idempotent, all reversible):
#   1. generates an RS256 signing keypair inside the container if absent
#      (nwd had NONE — /.well-known/jwks.json was returning 500);
#   2. registers the keys in simple_oauth.settings + enables OIDC;
#   3. ensures the openid / profile / email scope entities exist;
#   4. creates/updates ONE confidential, PKCE-required consumer for the demo
#      Moodle consumer, redirect = <consumer wwwroot>/admin/oauth2callback.php;
#   5. grants `grant simple_oauth codes` to the authenticated role — WITHOUT
#      this the consent step of the authorization-code flow fails (this is the
#      prereq the ssc live wiring was missing in 2026-07 and it cost hours);
#   6. verifies the JWKS actually serves 200 before declaring success.
#
# The client secret is generated locally, written 0600 to a gitignored file,
# and NEVER printed to stdout or placed on any argv.
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
PROJECT_ROOT="${PROJECT_ROOT:-$REPO_ROOT}"

source "$REPO_ROOT/lib/ui.sh"
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/demo-pair.sh"

SITE="nwd"; TIER="dev"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --site=*) SITE="${1#--site=}"; shift ;;
        --tier=*) TIER="${1#--tier=}"; shift ;;
        *) print_error "Unknown option '$1'"; exit 1 ;;
    esac
done

# ---- GUARD 1: dev or live, never stg/prod. ----------------------------------
# ops#146: the live issuer half is now implemented. It is STILL an auth surface —
# what bounds it is GUARD 2 (must be the provider of a `demo.enabled: true` pair,
# i.e. a disposable A14 demo site), not the tier alone. `prod` stays refused
# outright: a prod issuer is offline-deploy-host territory; nothing here may reach it.
case "$TIER" in
    dev|live) ;;
    *)
        print_error "REFUSED: --tier=$TIER. This provisioner does dev and live only."
        print_info  "A prod issuer is provisioned from the offline deploy host under the hardware gate — never from here."
        exit 1 ;;
esac

# ---- GUARD 2: must be the PROVIDER of a demo-enabled pair. -------------------
CONTRACT="$(demo_pair_contract_for "$SITE")" || {
    print_error "REFUSED: no demo-enabled pair contract names '$SITE'."
    print_info  "A contract must carry 'demo: {enabled: true}' before this script will touch its issuer."
    exit 1
}
[[ "$(demo_pair_role "$SITE" "$CONTRACT")" == "provider" ]] || {
    print_error "REFUSED: '$SITE' is not the PROVIDER in $(basename "$CONTRACT")."
    exit 1
}
CONSUMER="$(demo_pair_consumer "$CONTRACT")"
ISSUER="$(demo_pair_issuer "$CONTRACT" "$TIER")" || {
    print_error "REFUSED: no endpoints.${TIER}.issuer in $CONTRACT"
    exit 1
}
CLIENT_ID="$(demo_pair_get "$CONTRACT" '.oidc.provider_prereqs.consumer_client_id' "${CONSUMER}_moodle")"
REDIRECT="$(demo_pair_consumer_redirect "$CONTRACT" "$TIER")" || {
    print_error "REFUSED: cannot resolve the ${TIER} redirect URI for consumer '$CONSUMER'."
    print_info  "Needs oidc.provider_prereqs.consumer_redirect in $(basename "$CONTRACT") and, for a"
    print_info  "non-dev tier, moodle.tiers.${TIER}.wwwroot in sites/${CONSUMER}/.nwp.yml."
    print_info  "Refusing to guess a redirect URI — a wrong one hands the auth code to the wrong host."
    exit 1
}

# Per-tier client secret. dev keeps the historical un-suffixed path; any other
# tier gets its own file, because a dev and a live OAuth client that share a
# secret means a dev-tier compromise mints live tokens.
SECRET_OUT="${PROJECT_ROOT}/private/demo/${CONSUMER}-oidc-client-secret"
[[ "$TIER" == "dev" ]] || SECRET_OUT="${SECRET_OUT}.${TIER}"

################################################################################
# Transport. The provisioning LOGIC below is identical on both tiers — only the
# way a drush/shell command reaches the site differs. Nothing tier-specific is
# relaxed for live; there is no live equivalent of the consumer script's ddev
# reachability shims because a live provider is reached over ordinary public
# DNS + TLS and needs none.
################################################################################
if [[ "$TIER" == "live" ]]; then
    [[ "$(get_site_config_value "$SITE" '.live.enabled' 'false')" != "false" ]] || {
        print_error "REFUSED: live.enabled is false for '$SITE'."; exit 1; }
    REMOTE_PATH="$(get_site_config_value "$SITE" '.live.remote_path' "/var/www/${SITE}")"
    SERVER_NAME="$(get_site_config_value "$SITE" '.live.server' '')"
    REMOTE_IP=""
    [[ -n "$SERVER_NAME" ]] && REMOTE_IP="$(get_server_ip "$SERVER_NAME" 2>/dev/null || true)"
    [[ -n "$REMOTE_IP" ]] || REMOTE_IP="$(get_site_config_value "$SITE" '.live.server_ip' '')"
    [[ -n "$REMOTE_IP" ]] || { print_error "REFUSED: no live server for '$SITE'."; exit 1; }
    SSH_USER="$(get_ssh_user "$SITE" 2>/dev/null || echo gitlab)"
    SSH_TARGET="${SSH_USER}@${REMOTE_IP}"
    # shellcheck disable=SC2086
    RSSH_OPTS="$(nwp_ssh_opts "$SITE" 2>/dev/null || true)"
    SUDO_DRUSH="sudo -u www-data"
    KEY_DIR="${REMOTE_PATH%/}/keys"     # OUTSIDE the docroot (which is html/)

    # shellcheck disable=SC2086
    rexec() { ssh $RSSH_OPTS -o BatchMode=yes -o ConnectTimeout=15 "$SSH_TARGET" "$1"; }
    # A PRIVILEGED probe. The live key dir is 0700 www-data (see below), so the
    # ssh user cannot stat anything inside it — an unprivileged `test -r` there
    # always says "absent". That is not a cosmetic difference: the caller below
    # reads "absent" as "generate", so every single live run would mint a FRESH
    # RS256 signing keypair and silently invalidate every id_token and refresh
    # token this issuer has already signed. Idempotence on an auth surface is a
    # security property, not a nicety.
    rprobe() { rexec "sudo $1"; }
    d() {
        local q="" a
        for a in "$@"; do q+=" $(printf '%q' "$a")"; done
        rexec "cd ${REMOTE_PATH%/}/html && ${SUDO_DRUSH} ../vendor/bin/drush${q}"
    }
    rexec 'echo ok' >/dev/null 2>&1 || { print_error "Cannot reach $SSH_TARGET"; exit 1; }
    SECRET_STAGE_REMOTE="${KEY_DIR}/.oidc-client-secret.stage"
else
    SITE_DIR="$(resolve_project "$SITE" "$TIER")" || { print_error "Cannot resolve $SITE ($TIER)"; exit 1; }
    KEY_DIR="/var/www/html/oauth-keys"
    cd "$SITE_DIR"
    rexec() { ddev exec "$1"; }
    rprobe() { rexec "$1"; }   # dev: the ddev web user owns the key dir already
    d() { ddev drush "$@"; }
fi

print_header "Provisioning $SITE ($TIER) as the OIDC issuer for $CONSUMER"
print_info "Issuer   : $ISSUER"
print_info "Client   : $CLIENT_ID"
print_info "Redirect : $REDIRECT"
print_info "Keys     : $KEY_DIR"

# ---- 0. sanity --------------------------------------------------------------
d pm:list --status=enabled --field=name 2>/dev/null | grep -qx 'simple_oauth' \
    || { print_error "simple_oauth is not enabled on $SITE"; exit 1; }

# ---- 1. signing keypair (generate if absent) --------------------------------
if rprobe "test -r $KEY_DIR/private.key && test -r $KEY_DIR/public.key" >/dev/null 2>&1; then
    print_status "OK" "Signing keypair already present at $KEY_DIR"
else
    print_info "No signing keypair — generating (RS256)…"
    if [[ "$TIER" == "live" ]]; then
        # The keys must be READABLE BY THE WEBSERVER USER and by nothing else:
        # the private key signs every id_token this issuer mints. drush runs as
        # www-data, so create the dir owned by www-data 0700 and let drush write
        # into it, rather than writing as root and loosening the mode afterwards.
        rexec "sudo install -d -o www-data -g www-data -m 0700 $KEY_DIR" >/dev/null \
            || { print_error "could not create $KEY_DIR"; exit 1; }
    else
        rexec "mkdir -p $KEY_DIR" >/dev/null
    fi
    d simple-oauth:generate-keys "$KEY_DIR" >/dev/null 2>&1 \
        || { print_error "drush simple-oauth:generate-keys failed"; exit 1; }
    rexec "sudo chmod 600 $KEY_DIR/private.key && sudo chmod 644 $KEY_DIR/public.key" >/dev/null 2>&1 \
        || rexec "chmod 600 $KEY_DIR/private.key && chmod 644 $KEY_DIR/public.key" >/dev/null
    print_status "OK" "Generated signing keypair"
fi

# ---- 2. register keys + enable OIDC ----------------------------------------
d cset -y simple_oauth.settings public_key  "$KEY_DIR/public.key"  >/dev/null
d cset -y simple_oauth.settings private_key "$KEY_DIR/private.key" >/dev/null
d cset -y simple_oauth.settings disable_openid_connect 0 >/dev/null
print_status "OK" "Keys registered, OpenID Connect enabled"

# ---- 3. scope entities ------------------------------------------------------
d php:eval '
$storage = \Drupal::entityTypeManager()->getStorage("oauth2_scope");
$want = ["openid"=>"OpenID Connect","profile"=>"Profile","email"=>"Email address"];
foreach ($want as $id => $desc) {
  if (!$storage->load($id)) {
    $storage->create([
      "id" => $id, "name" => $id, "description" => $desc,
      "grant_types" => ["authorization_code" => ["status" => true, "description" => $desc]],
      "umbrella" => false, "granularity_id" => "permission",
      "granularity_configuration" => ["permission" => "access content"],
    ])->save();
    print "  created scope: $id\n";
  } else { print "  scope exists: $id\n"; }
}
'

# ---- 4. the confidential, PKCE-required consumer ----------------------------
mkdir -p "$(dirname "$SECRET_OUT")"
if [[ -f "$SECRET_OUT" ]]; then
    SECRET="$(cat "$SECRET_OUT")"
    print_info "Reusing the recorded client secret"
else
    SECRET="$(openssl rand -hex 32)"
    ( umask 077; printf '%s' "$SECRET" > "$SECRET_OUT" )
    print_info "Generated a new client secret → $SECRET_OUT (0600, gitignored)"
fi

# The secret travels by FILE, not by argv: `drush php:eval` puts its whole
# argument on a command line, so interpolating the secret there would expose it
# to anything that can read /proc on that host. The file sits OUTSIDE the docroot
# (which is html/), so it is never web-servable, is 0600, and is unlinked by PHP
# the moment it is read.
#
# On live it is also never written from this workstation over a shell argument:
# it is piped over ssh stdin into a 0600 file owned by www-data.
if [[ "$TIER" == "live" ]]; then
    SECRET_TMP_CONTAINER="$SECRET_STAGE_REMOTE"
    # shellcheck disable=SC2086
    printf '%s' "$SECRET" | ssh $RSSH_OPTS -o BatchMode=yes -o ConnectTimeout=15 "$SSH_TARGET" \
        "umask 077 && sudo -u www-data tee $(printf '%q' "$SECRET_TMP_CONTAINER") >/dev/null && sudo chmod 600 $(printf '%q' "$SECRET_TMP_CONTAINER")" \
        || { print_error "could not stage the client secret on the live host"; exit 1; }
    trap 'rexec "sudo rm -f $(printf "%q" "$SECRET_TMP_CONTAINER")" >/dev/null 2>&1 || true' EXIT
else
    SECRET_TMP_HOST="${SITE_DIR}/.oidc-client-secret.stage"
    SECRET_TMP_CONTAINER="/var/www/html/.oidc-client-secret.stage"
    ( umask 077; printf '%s' "$SECRET" > "$SECRET_TMP_HOST" )
    trap 'rm -f "$SECRET_TMP_HOST"' EXIT
fi

d php:eval '
$cid    = "'"$CLIENT_ID"'";
$label  = "Demo Moodle ('"$CONSUMER"')";
$secretfile = "'"$SECRET_TMP_CONTAINER"'";
$secret = is_readable($secretfile) ? trim(file_get_contents($secretfile)) : "";
@unlink($secretfile);
if ($secret === "") { throw new \RuntimeException("client secret not staged"); }
$redirects = ["'"$REDIRECT"'"];
$etm = \Drupal::entityTypeManager()->getStorage("consumer");
$existing = $etm->loadByProperties(["client_id" => $cid]);
$c = $existing ? reset($existing) : $etm->create(["client_id" => $cid]);
$c->set("label", $label);
$c->set("client_id", $cid);
$c->set("secret", $secret);            // hashed on save by simple_oauth
$c->set("confidential", true);
$c->set("pkce", true);                 // require PKCE (S256)
$c->set("is_default", false);
$c->set("third_party", true);
$c->set("grant_types", ["authorization_code", "refresh_token"]);
$redir = [];
foreach ($redirects as $r) { $redir[] = ["value" => $r]; }
$c->set("redirect", $redir);
$scopes = [];
foreach (["openid","profile","email"] as $s) { $scopes[] = ["scope_id" => $s]; }
if ($c->hasField("scopes")) { $c->set("scopes", $scopes); }
$c->save();
printf("  client saved: client_id=%s pkce=%s confidential=%s\n",
  $c->get("client_id")->value,
  $c->get("pkce")->value ? "yes":"no",
  $c->get("confidential")->value ? "yes":"no");
'

# ---- 5. the consent permission (the prereq that silently breaks the flow) ---
d php:eval '
$role = \Drupal\user\Entity\Role::load("authenticated");
if ($role && !$role->hasPermission("grant simple_oauth codes")) {
  $role->grantPermission("grant simple_oauth codes");
  $role->save();
  print "  granted: grant simple_oauth codes -> authenticated\n";
} else {
  print "  permission already present: grant simple_oauth codes\n";
}
'

d cr >/dev/null 2>&1 || true

# ---- 6. verify the JWKS actually serves ------------------------------------
# -k only on dev (ddev's self-signed cert). On live the certificate is real and
# MUST be verified: an unverified probe would call a MITM'd issuer "healthy".
CURL_TLS=(); [[ "$TIER" == "dev" ]] && CURL_TLS=(-k)
jwks_code="$(curl -s "${CURL_TLS[@]}" -o /dev/null -w '%{http_code}' "${ISSUER}/.well-known/jwks.json" || echo 000)"
if [[ "$jwks_code" != "200" ]]; then
    print_error "JWKS check FAILED: ${ISSUER}/.well-known/jwks.json → HTTP $jwks_code"
    print_hint  "Without a served JWKS the issuer is not healthy; check the keypair + simple_oauth settings."
    exit 1
fi
print_status "OK" "JWKS serves 200 at ${ISSUER}/.well-known/jwks.json"

cat <<EOF

== Issuer ready. The Moodle consumer ($CONSUMER) needs: ==
  Issuer base URL : $ISSUER
  Authorization   : $ISSUER/oauth/authorize
  Token           : $ISSUER/oauth/token
  UserInfo        : $ISSUER/oauth/userinfo
  JWKS            : $ISSUER/.well-known/jwks.json
  Client ID       : $CLIENT_ID
  Client secret   : (0600 file $SECRET_OUT — never printed, never on argv)
  Scopes          : openid profile email      PKCE: required (S256)

Next: scripts/demo/ssd-oidc-wire.sh --site=$CONSUMER
EOF
