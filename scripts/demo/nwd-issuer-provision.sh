#!/bin/bash
set -euo pipefail
################################################################################
# scripts/demo/nwd-issuer-provision.sh — provision the DEMO provider (nwd) as an
# OpenID Connect issuer for its demo consumer (ssd). ops#133 Phase 2.
#
#   AUTH SURFACE — DEV TIER ONLY, DEMO PAIR ONLY.
#
# This is the demo-tier sibling of scripts/f26/provision-nwc-issuer.sh (which
# provisions the REAL nwc issuer for ssc). It is deliberately a separate file
# rather than a flag on that one, because it carries guards the generic script
# cannot: it refuses to run unless the target site is the PROVIDER of a pair
# contract that declares `demo.enabled: true`, and it refuses any tier but dev.
# An auth-surface script that can only ever point at a throwaway demo pair is a
# much smaller thing to review.
#
#   scripts/demo/nwd-issuer-provision.sh [--site=nwd] [--tier=dev]
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

# ---- GUARD 1: dev only. -----------------------------------------------------
[[ "$TIER" == "dev" ]] || {
    print_error "REFUSED: --tier=$TIER. This provisioner is dev-only."
    print_info  "The live issuer half is an auth surface: operator-run, two-person reviewed."
    exit 1
}

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
REDIRECT="$(demo_pair_get "$CONTRACT" '.oidc.provider_prereqs.consumer_redirect')"
[[ -n "$REDIRECT" ]] || {
    print_error "REFUSED: no oidc.provider_prereqs.consumer_redirect in $CONTRACT — refusing to guess a redirect URI."
    exit 1
}

SITE_DIR="$(resolve_project "$SITE" "$TIER")" || { print_error "Cannot resolve $SITE ($TIER)"; exit 1; }
KEY_DIR="/var/www/html/oauth-keys"
SECRET_OUT="${PROJECT_ROOT}/private/demo/${CONSUMER}-oidc-client-secret"

print_header "Provisioning $SITE ($TIER) as the OIDC issuer for $CONSUMER"
print_info "Issuer   : $ISSUER"
print_info "Client   : $CLIENT_ID"
print_info "Redirect : $REDIRECT"

cd "$SITE_DIR"
d() { ddev drush "$@"; }

# ---- 0. sanity --------------------------------------------------------------
d pm:list --status=enabled --field=name 2>/dev/null | grep -qx 'simple_oauth' \
    || { print_error "simple_oauth is not enabled on $SITE"; exit 1; }

# ---- 1. signing keypair (generate if absent) --------------------------------
if ddev exec "test -r $KEY_DIR/private.key && test -r $KEY_DIR/public.key" >/dev/null 2>&1; then
    print_status "OK" "Signing keypair already present at $KEY_DIR"
else
    print_info "No signing keypair — generating (RS256)…"
    ddev exec "mkdir -p $KEY_DIR" >/dev/null
    d simple-oauth:generate-keys "$KEY_DIR" >/dev/null 2>&1 \
        || { print_error "drush simple-oauth:generate-keys failed"; exit 1; }
    ddev exec "chmod 600 $KEY_DIR/private.key && chmod 644 $KEY_DIR/public.key" >/dev/null
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
# argument on a container command line, so interpolating the secret there would
# expose it to anything that can read /proc inside the container. The file sits
# at the ddev project root — OUTSIDE the docroot (html/), so it is never
# web-servable — is 0600, and is unlinked by PHP the moment it is read.
SECRET_TMP_HOST="${SITE_DIR}/.oidc-client-secret.stage"
SECRET_TMP_CONTAINER="/var/www/html/.oidc-client-secret.stage"
( umask 077; printf '%s' "$SECRET" > "$SECRET_TMP_HOST" )
trap 'rm -f "$SECRET_TMP_HOST"' EXIT

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
jwks_code="$(curl -sk -o /dev/null -w '%{http_code}' "${ISSUER}/.well-known/jwks.json" || echo 000)"
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
