#!/bin/bash
set -euo pipefail
################################################################################
# scripts/demo/ssd-oidc-wire.sh — wire the demo Moodle consumer (ssd) to its
# demo Drupal issuer (nwd). ops#133 Phase 2.
#
#   AUTH SURFACE — DEV TIER ONLY, DEMO PAIR ONLY.
#
# Consumer half of the pairing. Everything it writes comes from the PAIR
# CONTRACT (pairs/<consumer>.pair-contract.yml → oidc:), so the file that
# documents the wiring is the file that produces it:
#
#   * core mdl_oauth2_issuer  "<oidc.issuer_name>" with MANUAL endpoints
#     (a Drupal simple_oauth issuer serves no discovery document);
#   * jwks_uri = /.well-known/jwks.json  — NOT /oauth/jwks, which 301-redirects
#     and silently breaks token signature verification;
#   * user-field mappings from oidc.user_field_mappings. sub→idnumber is the
#     UID-lock and is MANDATORY: without it auth_nwc's uid_lock::decide returns
#     ACTION_DENY for every login;
#   * auth_nwc plugin config — issuerid, nwc_url (MUST be overridden: the
#     plugin's built-in default is https://nwc-dev.ddev.site, which would send
#     ssd testers to the wrong site), autoredirect=0, link_legacy_by_email=0;
#   * $CFG->auth += oauth2,nwc (core 'email' kept so the site stays recoverable).
#
# It also applies the two dev-only reachability prerequisites the ops#93 ssc
# e2e proved are necessary inside ddev (container→container HTTPS alias and
# Moodle's cURL blocklist), because without them the code→token exchange fails
# with a misleading "Could not upgrade OAuth 2 token".
#
#   scripts/demo/ssd-oidc-wire.sh [--site=ssd] [--tier=dev] [--check]
#
# The client secret is read from the 0600 file the provider provisioner wrote
# and exported to the child php process only — never argv, never a file Moodle
# can serve, never stdout.
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
PROJECT_ROOT="${PROJECT_ROOT:-$REPO_ROOT}"

source "$REPO_ROOT/lib/ui.sh"
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/demo-pair.sh"

SITE="ssd"; TIER="dev"; CHECK="false"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --site=*) SITE="${1#--site=}"; shift ;;
        --tier=*) TIER="${1#--tier=}"; shift ;;
        --check)  CHECK="true"; shift ;;
        *) print_error "Unknown option '$1'"; exit 1 ;;
    esac
done

# ---- Tier gate: dev or live, never stg/prod. --------------------------------
#
# ops#146. Read this before widening it again.
#
# This script used to refuse every tier but dev, and the refusal was doing TWO
# jobs at once:
#   (1) "the ddev reachability shims below must never reach a real host"  — a
#       SECURITY constraint, and the reason the blanket refusal was right; and
#   (2) "there is no live consumer yet"                                   — a
#       statement of fact that stopped being true.
#
# Only (2) has changed. (1) is now enforced structurally instead of by tier
# accident: apply_dev_prereqs() asserts dev itself and is CALLED ONLY on dev.
# In particular `$CFG->curlsecurityblockedhosts=''` DOES NOT FOLLOW TO LIVE.
# It never needed to: that shim exists because inside ddev the provider hostname
# resolves to the ddev-router's RFC1918 address, which Moodle's default cURL
# blocklist (rightly) rejects. On live the provider resolves to a PUBLIC address
# that the default blocklist does not block — verified from the box itself:
#     getent hosts nwd.<example-prod-domain>          -> <public box ip>
#     curl https://nwd.<example-prod-domain>/user/login -> 200, remote_ip = same
# (i.e. the hairpin works and no RFC1918 address is involved)
# So the live consumer keeps Moodle's SSRF protection fully armed.
case "$TIER" in
    dev|live) ;;
    *)
        print_error "REFUSED: --tier=$TIER. Consumer OIDC wiring does dev and live only."
        print_info  "A prod consumer is wired from the offline deploy host under the hardware gate — never from here."
        exit 1 ;;
esac

CONTRACT="$(demo_pair_contract_for "$SITE")" || {
    print_error "REFUSED: no demo-enabled pair contract names '$SITE'."
    exit 1
}
[[ "$(demo_pair_role "$SITE" "$CONTRACT")" == "consumer" ]] || {
    print_error "REFUSED: '$SITE' is not the CONSUMER in $(basename "$CONTRACT")."
    exit 1
}
PROVIDER="$(demo_pair_provider "$CONTRACT")"
ISSUER="$(demo_pair_issuer "$CONTRACT" "$TIER")" || {
    print_error "REFUSED: no endpoints.${TIER}.issuer in $CONTRACT"
    exit 1
}
# ISSUER_NAME is MEMBER-FACING: it is the label on the SSO login button. It has
# no safe default — a fallback here once put the internal codename "nwd (F26)"
# on the live login page. Fail loud, never guess (same posture as the issuer).
ISSUER_NAME="$(demo_pair_get "$CONTRACT" '.oidc.issuer_name')"
[[ -n "$ISSUER_NAME" ]] || {
    print_error "REFUSED: oidc.issuer_name is not set in $CONTRACT."
    print_info  "Set oidc.issuer_name to the member-facing SSO button label — it appears verbatim on the login page, so no internal codenames."
    exit 1
}
CLIENT_ID="$(demo_pair_get "$CONTRACT" '.oidc.provider_prereqs.consumer_client_id' "${SITE}_moodle")"
CLI_PHP="${CLI_PHP:-$(demo_pair_get "$CONTRACT" '.oidc.cli_php_version' '8.3')}"
[[ "$CLI_PHP" == php* ]] || CLI_PHP="php${CLI_PHP}"

# Per-tier client secret — must match nwd-issuer-provision.sh's SECRET_OUT.
SECRET_FILE="${PROJECT_ROOT}/private/demo/${SITE}-oidc-client-secret"
[[ "$TIER" == "dev" ]] || SECRET_FILE="${SECRET_FILE}.${TIER}"

################################################################################
# Transport. The wiring LOGIC (the staged PHP) is byte-identical on both tiers.
# What differs is only how it is delivered and where the secret is staged.
################################################################################
if [[ "$TIER" == "live" ]]; then
    [[ "$(get_site_config_value "$SITE" '.live.enabled' 'false')" != "false" ]] || {
        print_error "REFUSED: live.enabled is false for '$SITE'."; exit 1; }
    MOODLE_ROOT="$(get_site_config_value "$SITE" '.live.remote_path' "/var/www/${SITE}")"
    SERVER_NAME="$(get_site_config_value "$SITE" '.live.server' '')"
    REMOTE_IP=""
    [[ -n "$SERVER_NAME" ]] && REMOTE_IP="$(get_server_ip "$SERVER_NAME" 2>/dev/null || true)"
    [[ -n "$REMOTE_IP" ]] || REMOTE_IP="$(get_site_config_value "$SITE" '.live.server_ip' '')"
    [[ -n "$REMOTE_IP" ]] || { print_error "REFUSED: no live server for '$SITE'."; exit 1; }
    SSH_USER="$(get_ssh_user "$SITE" 2>/dev/null || echo gitlab)"
    SSH_TARGET="${SSH_USER}@${REMOTE_IP}"
    RSSH_OPTS="$(nwp_ssh_opts "$SITE" 2>/dev/null || true)"
    # shellcheck disable=SC2086
    rexec() { ssh $RSSH_OPTS -o BatchMode=yes -o ConnectTimeout=20 "$SSH_TARGET" "$1"; }
    rexec 'echo ok' >/dev/null 2>&1 || { print_error "Cannot reach $SSH_TARGET"; exit 1; }

    rexec "sudo test -f $(printf '%q' "$MOODLE_ROOT/version.php")" \
        || { print_error "REFUSED: $MOODLE_ROOT on $REMOTE_IP is not a Moodle root"; exit 1; }
    rexec "sudo test -f $(printf '%q' "$MOODLE_ROOT/auth/nwc/version.php")" || {
        print_error "REFUSED: auth_nwc is not installed at $MOODLE_ROOT/auth/nwc on live."
        print_hint  "Deploy it first: pl moodle plugin deploy $SITE auth/nwc --tier=live --apply"
        exit 1
    }
    # The live dataroot is authoritative in the live config.php, not in any local
    # yaml — read it there rather than assuming the dev convention.
    DATAROOT_REMOTE="$(rexec "sudo sed -n \"s/.*\\\$CFG->dataroot[[:space:]]*=[[:space:]]*'\\([^']*\\)'.*/\\1/p\" $(printf '%q' "$MOODLE_ROOT/config.php")" | head -1 | tr -d '\r')"
    [[ -n "$DATAROOT_REMOTE" ]] || { print_error "REFUSED: could not read \$CFG->dataroot from the live config.php"; exit 1; }
else
    MOODLE_ROOT="$(resolve_project "$SITE" "$TIER")" || { print_error "Cannot resolve $SITE ($TIER)"; exit 1; }
    [[ -f "$MOODLE_ROOT/version.php" ]] || { print_error "REFUSED: $MOODLE_ROOT is not a Moodle root"; exit 1; }

    # The consumer plugin must actually be installed, or every login would be
    # denied by an issuer that nothing enforces.
    [[ -f "$MOODLE_ROOT/auth/nwc/version.php" ]] || {
        print_error "REFUSED: auth_nwc is not installed at $MOODLE_ROOT/auth/nwc."
        print_hint  "Run scripts/demo/ssd-rebuild.sh first."
        exit 1
    }
fi

################################################################################
# Dev-only reachability prerequisites (ops#93 findings, reproduced for ssd).
################################################################################

apply_dev_prereqs() {
    # STRUCTURAL GUARD (ops#146). Everything in this function weakens something
    # that is load-bearing off dev — most of all `curlsecurityblockedhosts=''`,
    # which disables Moodle's SSRF protection for every server-side fetch the
    # site makes, not just the OIDC ones. It exists solely to work around ddev's
    # container networking. It must never run against a real host, so it refuses
    # here as well as at its call site: two independent checks, because a future
    # edit that moves the call is exactly how this leaks.
    [[ "$TIER" == "dev" ]] || {
        print_error "INTERNAL REFUSAL: apply_dev_prereqs called on tier '$TIER'."
        print_error "These are ddev-only shims; applying them off dev would disable Moodle's"
        print_error "cURL SSRF blocklist on a real host. Refusing."
        return 1
    }
    local changed="false"

    # (a) container→container HTTPS: alias the provider hostname onto
    #     ddev-router, else the code→token POST loops back to ssd's own
    #     webserver ("Could not upgrade OAuth 2 token").
    local host="${ISSUER#https://}"; host="${host#http://}"; host="${host%%/*}"
    local compose="$MOODLE_ROOT/.ddev/docker-compose.${PROVIDER}-sso.yaml"
    if [[ ! -f "$compose" ]] || ! grep -q "$host" "$compose" 2>/dev/null; then
        cat > "$compose" <<EOF
# GENERATED by scripts/demo/ssd-oidc-wire.sh (ops#133 Phase 2) — dev only.
# Lets the ${SITE}-dev web container reach ${host} over HTTPS for the
# SERVER-SIDE half of the OIDC flow (code→token exchange + userinfo call).
# Without it DDEV points ${host} at 127.0.0.1 inside this container and the
# token request loops back to ${SITE}'s own webserver.
services:
  web:
    external_links:
      - "ddev-router:${host}"
EOF
        print_info "Wrote $(basename "$compose")"
        changed="true"
    fi

    # (b) Moodle's cURL security blocklist rejects the RFC1918 ddev-router
    #     address the provider hostname resolves to inside the container.
    if ! grep -q 'curlsecurityblockedhosts' "$MOODLE_ROOT/config.php" 2>/dev/null; then
        python3 - "$MOODLE_ROOT/config.php" <<'PY'
import sys, re
p = sys.argv[1]
src = open(p).read()
block = (
"\n// ops#133 Phase 2 (documented dev-only config): allow the server-side OIDC\n"
"// code->token / userinfo calls to the demo provider. Inside ddev the provider\n"
"// hostname is aliased onto the ddev-router (an RFC1918 address), which Moodle's\n"
"// default cURL security blocklist rejects (\"The URL is blocked\").\n"
"$CFG->curlsecurityblockedhosts = '';\n"
"$CFG->curlsecurityallowedport = '';\n"
)
needle = "require_once(__DIR__ . '/lib/setup.php');"
if needle in src:
    src = src.replace(needle, block + "\n" + needle, 1)
else:
    src = src.rstrip() + "\n" + block
open(p, 'w').write(src)
PY
        print_info "Added curlsecurity dev exceptions to config.php"
        changed="true"
    fi

    # (c) the project must be published on the default router ports: Moodle's
    #     $CFG->wwwroot is port-less and the router strips the port from Host,
    #     so a project registered on 33000/33001 can never receive the callback.
    local portcfg="$MOODLE_ROOT/.ddev/config.demo-ports.yaml"
    if [[ ! -f "$portcfg" ]]; then
        cat > "$portcfg" <<'EOF'
# GENERATED by scripts/demo/ssd-oidc-wire.sh (ops#133 Phase 2) — dev only.
# The OAuth callback redirect lands on :443; a ported wwwroot cannot work
# because the ddev router strips the port from the Host header.
router_http_port: "80"
router_https_port: "443"
EOF
        print_info "Wrote $(basename "$portcfg")"
        changed="true"
    fi

    if [[ "$changed" == "true" ]]; then
        print_info "Restarting $SITE-$TIER to apply ddev changes…"
        ( cd "$MOODLE_ROOT" && ddev restart >/dev/null 2>&1 ) || {
            print_error "ddev restart failed"; return 1; }
    fi
    return 0
}

################################################################################
# The apply script (staged into the Moodle root, run, removed).
################################################################################

STAGED="ssd_oidc_wire_tmp.php"
# Where the apply script is written before it runs. On dev that is the Moodle
# root (inside the docroot, as it has always been — a ddev-local tree). On live
# it is written to a local temp file and then piped into MOODLEDATA, which is
# OUTSIDE the docroot and therefore not web-servable: a PHP file that wires
# authentication must never be fetchable, even for the seconds it exists.
STAGED_LOCAL=""
write_apply_script() {
    if [[ "$TIER" == "live" ]]; then
        STAGED_LOCAL="$(mktemp -t ssd-oidc-wire.XXXXXX.php)"
        chmod 600 "$STAGED_LOCAL"
    else
        STAGED_LOCAL="$MOODLE_ROOT/$STAGED"
    fi
    cat > "$STAGED_LOCAL" <<'PHPEOF'
<?php
// GENERATED by scripts/demo/ssd-oidc-wire.sh (ops#133 Phase 2). IDEMPOTENT.
// Codifies the consumer half of the demo pairing, mirroring the live-proven
// ssc↔nwc shape. Contains NO secret — reads OIDC_CLIENT_SECRET from the env.
define('CLI_SCRIPT', true);
$root = null;
foreach ([getcwd(), __DIR__] as $c) {
    if (is_file("$c/config.php") && is_dir("$c/lib")) { $root = $c; break; }
}
if ($root === null) { fwrite(STDERR, "Cannot find Moodle root\n"); exit(2); }
require("$root/config.php");
require_once($CFG->libdir . '/clilib.php');

$checkonly = in_array('--check', $argv, true);

$NAME     = getenv('OIDC_ISSUER_NAME');
$BASEURL  = rtrim((string) getenv('OIDC_ISSUER_URL'), '/');
$CLIENTID = getenv('OIDC_CLIENT_ID');
$MAPS_RAW = getenv('OIDC_FIELD_MAPS');   // "ext:int,ext:int,…"
// The secret travels by FILE, never by argv or by an env var visible in the
// container's process table. The staging file lives in moodledata — OUTSIDE
// the docroot, so it is not web-servable — is 0600, and is unlinked here the
// moment it has been read.
$SECRET = '';
$secretfile = (string) getenv('OIDC_CLIENT_SECRET_FILE');
if ($secretfile !== '' && is_readable($secretfile)) {
    $SECRET = trim((string) file_get_contents($secretfile));
    @unlink($secretfile);
}
if ($NAME === false || $NAME === '' || $BASEURL === '' || $CLIENTID === false || $CLIENTID === '') {
    cli_error('OIDC_ISSUER_NAME / OIDC_ISSUER_URL / OIDC_CLIENT_ID must all be set.');
}
if (!$checkonly && $SECRET === '') {
    cli_error('No client secret staged (OIDC_CLIENT_SECRET_FILE unreadable) — never pass a secret on argv.');
}

$maps = [];
foreach (explode(',', (string) $MAPS_RAW) as $pair) {
    $pair = trim($pair);
    if ($pair === '') { continue; }
    [$ext, $int] = array_pad(explode(':', $pair, 2), 2, '');
    if ($ext !== '' && $int !== '') { $maps[$ext] = $int; }
}
if (!isset($maps['sub']) || $maps['sub'] !== 'idnumber') {
    cli_error('FATAL: the field-map set must contain sub:idnumber — without the UID-lock auth_nwc DENIES every login.');
}

// ---- locate the issuer ------------------------------------------------------
$issuer = null;
foreach (\core\oauth2\api::get_all_issuers() as $i) {
    if ($i->get('name') === $NAME) { $issuer = $i; break; }
}

if ($checkonly) {
    $bad = [];
    if ($issuer === null) {
        cli_writeln('OIDC-WIRE-FAIL: no issuer named "' . $NAME . '"');
        exit(1);
    }
    if (rtrim((string) $issuer->get('baseurl'), '/') !== $BASEURL) { $bad[] = 'baseurl'; }
    if ((string) $issuer->get('clientid') !== $CLIENTID)           { $bad[] = 'clientid'; }
    if ((int) $issuer->get('enabled') !== 1)                       { $bad[] = 'enabled'; }
    $have = [];
    foreach (\core\oauth2\api::get_endpoints($issuer) as $e) { $have[$e->get('name')] = $e->get('url'); }
    foreach (['authorization_endpoint','token_endpoint','userinfo_endpoint','jwks_uri'] as $n) {
        if (empty($have[$n])) { $bad[] = "endpoint:$n"; }
    }
    if (($have['jwks_uri'] ?? '') !== $BASEURL . '/.well-known/jwks.json') { $bad[] = 'jwks_uri'; }
    $mapped = [];
    foreach (\core\oauth2\api::get_user_field_mappings($issuer) as $m) {
        $mapped[$m->get('externalfield')] = $m->get('internalfield');
    }
    foreach ($maps as $ext => $int) {
        if (($mapped[$ext] ?? null) !== $int) { $bad[] = "map:$ext"; }
    }
    if ((string) get_config('auth_nwc', 'issuerid') !== (string) $issuer->get('id')) { $bad[] = 'auth_nwc/issuerid'; }
    if (rtrim((string) get_config('auth_nwc', 'nwc_url'), '/') !== $BASEURL)          { $bad[] = 'auth_nwc/nwc_url'; }
    $auths = array_filter(array_map('trim', explode(',', (string) $CFG->auth)));
    foreach (['oauth2','nwc'] as $a) { if (!in_array($a, $auths, true)) { $bad[] = "auth:$a"; } }
    if ($bad) { cli_writeln('OIDC-WIRE-FAIL: ' . implode(',', $bad)); exit(1); }
    cli_writeln('OIDC-WIRE-OK issuerid=' . $issuer->get('id'));
    exit(0);
}

// ---- 1. issuer (idempotent by name) ----------------------------------------
$fields = (object) [
    'name'                => $NAME,
    // mdl_oauth2_issuer.image is NOT NULL with no DB default and the persistent
    // leaves it null — a bare create() dies with "Column 'image' cannot be
    // null". The admin UI always posts '', which is why this never shows up
    // when an issuer is made by hand.
    'image'               => '',
    'clientid'            => $CLIENTID,
    'clientsecret'        => $SECRET,
    'baseurl'             => $BASEURL,
    'loginscopes'         => 'openid email profile',
    'loginscopesoffline'  => 'openid email profile',
    'showonloginpage'     => 1,
    'enabled'             => 1,
    'requireconfirmation' => 0,   // trusted issuer — no email-confirm interstitial
];
if ($issuer === null) {
    $issuer = new \core\oauth2\issuer(0, $fields);
    $issuer->create();
    cli_writeln('Created issuer "' . $NAME . '" #' . $issuer->get('id'));
} else {
    foreach ((array) $fields as $k => $v) { $issuer->set($k, $v); }
    $issuer->update();
    cli_writeln('Updated issuer "' . $NAME . '" #' . $issuer->get('id'));
}
$issuerid = $issuer->get('id');

// ---- 2. MANUAL endpoints (no discovery doc on a simple_oauth issuer) -------
$endpoints = [
    'authorization_endpoint' => $BASEURL . '/oauth/authorize',
    'token_endpoint'         => $BASEURL . '/oauth/token',
    'userinfo_endpoint'      => $BASEURL . '/oauth/userinfo',
    // /.well-known/jwks.json — NOT /oauth/jwks, which 301-redirects.
    'jwks_uri'               => $BASEURL . '/.well-known/jwks.json',
];
$byname = [];
foreach (\core\oauth2\api::get_endpoints($issuer) as $e) { $byname[$e->get('name')] = $e; }
foreach ($endpoints as $name => $url) {
    if (isset($byname[$name])) { $byname[$name]->set('url', $url); $byname[$name]->update(); }
    else { (new \core\oauth2\endpoint(0, (object) [
        'issuerid' => $issuerid, 'name' => $name, 'url' => $url]))->create(); }
}

// ---- 3. user-field mappings (sub→idnumber = the UID-lock) ------------------
$mapped = [];
foreach (\core\oauth2\api::get_user_field_mappings($issuer) as $m) { $mapped[$m->get('externalfield')] = $m; }
foreach ($maps as $ext => $int) {
    if (isset($mapped[$ext])) { $mapped[$ext]->set('internalfield', $int); $mapped[$ext]->update(); }
    else { (new \core\oauth2\user_field_mapping(0, (object) [
        'issuerid' => $issuerid, 'externalfield' => $ext, 'internalfield' => $int]))->create(); }
}
$haslock = false;
foreach (\core\oauth2\api::get_user_field_mappings($issuer) as $m) {
    if ($m->get('externalfield') === 'sub' && $m->get('internalfield') === 'idnumber') { $haslock = true; }
}
if (!$haslock) { cli_error('FATAL: sub->idnumber mapping absent — auth_nwc would DENY all logins. Aborting.'); }

// ---- 4. auth_nwc plugin config + $CFG->auth --------------------------------
set_config('issuerid', $issuerid, 'auth_nwc');
// MUST be the demo provider: the plugin default is https://nwc-dev.ddev.site.
set_config('nwc_url', $BASEURL, 'auth_nwc');
set_config('autoredirect', 0, 'auth_nwc');          // keep the login page recoverable
set_config('link_legacy_by_email', 0, 'auth_nwc');  // demo tier: never link by email
$auths = array_filter(array_map('trim', explode(',', (string) $CFG->auth)));
foreach (['email', 'oauth2', 'nwc'] as $a) { if (!in_array($a, $auths, true)) { $auths[] = $a; } }
set_config('auth', implode(',', $auths));
if (class_exists('\\core\\plugininfo\\auth')) {
    \core\plugininfo\auth::enable_plugin('oauth2', 1);
    \core\plugininfo\auth::enable_plugin('nwc', 1);
}
purge_all_caches();
cli_writeln('OK: issuer #' . $issuerid . ' wired — sub->idnumber locked, auth=' . $CFG->auth);
PHPEOF
}

################################################################################
# Run
################################################################################

MAPS="$(demo_pair_get "$CONTRACT" '.oidc.user_field_mappings | to_entries | map(.key + ":" + .value) | join(",")' 'sub:idnumber')"
[[ "$MAPS" == *"sub:idnumber"* ]] || {
    print_error "REFUSED: oidc.user_field_mappings in $CONTRACT lacks sub→idnumber (the UID-lock)."
    exit 1
}

if [[ "$CHECK" != "true" ]]; then
    # DEV ONLY — see the tier gate at the top. The ddev reachability shims are
    # never applied to a live host; a live provider is reached over public DNS
    # and TLS, so Moodle's cURL blocklist stays exactly as shipped.
    if [[ "$TIER" == "dev" ]]; then
        apply_dev_prereqs || exit 1
    else
        print_info "Live tier: ddev reachability shims NOT applied (Moodle's cURL SSRF blocklist stays armed)."
    fi
    [[ -s "$SECRET_FILE" ]] || {
        print_error "REFUSED: no client secret at $SECRET_FILE"
        print_hint  "Run scripts/demo/nwd-issuer-provision.sh --tier=$TIER first."
        exit 1
    }
fi

write_apply_script

# Stage the secret into moodledata (outside the docroot, 0600). PHP unlinks it
# on read; this trap covers the failure paths.
if [[ "$TIER" == "live" ]]; then
    SECRET_STAGE_TARGET="${DATAROOT_REMOTE%/}/.oidc-client-secret.stage"
    STAGED_TARGET="${DATAROOT_REMOTE%/}/${STAGED}"
    cleanup() {
        rm -f "$STAGED_LOCAL"
        rexec "sudo rm -f $(printf '%q' "$STAGED_TARGET") $(printf '%q' "$SECRET_STAGE_TARGET")" >/dev/null 2>&1 || true
    }
    trap cleanup EXIT

    # Ship the apply script itself (never web-servable: moodledata, 0600, www-data).
    # shellcheck disable=SC2086
    ssh $RSSH_OPTS -o BatchMode=yes -o ConnectTimeout=20 "$SSH_TARGET" \
        "umask 077 && sudo -u www-data tee $(printf '%q' "$STAGED_TARGET") >/dev/null && sudo chmod 600 $(printf '%q' "$STAGED_TARGET")" \
        < "$STAGED_LOCAL" || { print_error "could not stage the apply script on live"; exit 1; }

    if [[ "$CHECK" != "true" ]]; then
        # shellcheck disable=SC2086
        ssh $RSSH_OPTS -o BatchMode=yes -o ConnectTimeout=20 "$SSH_TARGET" \
            "umask 077 && sudo -u www-data tee $(printf '%q' "$SECRET_STAGE_TARGET") >/dev/null && sudo chmod 600 $(printf '%q' "$SECRET_STAGE_TARGET")" \
            < "$SECRET_FILE" || { print_error "could not stage the client secret on live"; exit 1; }
    fi
else
    DATAROOT_REL="sites/${SITE}_moodledata"
    if command -v yq >/dev/null 2>&1 && [[ -f "${PROJECT_ROOT}/sites/${SITE}/.nwp.yml" ]]; then
        v="$(yq e '.moodle.dataroot_host // ""' "${PROJECT_ROOT}/sites/${SITE}/.nwp.yml" 2>/dev/null)"
        [[ -n "$v" && "$v" != "null" ]] && DATAROOT_REL="$v"
    fi
    DATAROOT_HOST="${PROJECT_ROOT}/${DATAROOT_REL}"
    SECRET_STAGE_HOST="${DATAROOT_HOST}/.oidc-client-secret.stage"
    SECRET_STAGE_TARGET="/var/www/moodledata/.oidc-client-secret.stage"
    STAGED_TARGET="$STAGED"
    cleanup() { rm -f "$MOODLE_ROOT/$STAGED" "$SECRET_STAGE_HOST"; }
    trap cleanup EXIT

    if [[ "$CHECK" != "true" ]]; then
        [[ -d "$DATAROOT_HOST" ]] || {
            print_error "REFUSED: moodledata host dir not found at $DATAROOT_HOST — cannot stage the secret outside the docroot."
            exit 1
        }
        ( umask 077; cp "$SECRET_FILE" "$SECRET_STAGE_HOST" )
    fi
fi

args=""
[[ "$CHECK" == "true" ]] && args="--check"

RUN_CMD="$(printf 'env OIDC_ISSUER_NAME=%q OIDC_ISSUER_URL=%q OIDC_CLIENT_ID=%q OIDC_CLIENT_SECRET_FILE=%q OIDC_FIELD_MAPS=%q %s -d max_input_vars=5000 %s %s' \
        "$ISSUER_NAME" "$ISSUER" "$CLIENT_ID" "$SECRET_STAGE_TARGET" "$MAPS" "$CLI_PHP" "$STAGED_TARGET" "$args")"

set +e
if [[ "$TIER" == "live" ]]; then
    # cwd = the Moodle root so the staged script's getcwd() probe finds
    # config.php + lib/, exactly as it does under ddev. -d max_input_vars=5000
    # is mandatory on this box (php.ini ships 1000, below Moodle's floor).
    rexec "cd $(printf '%q' "$MOODLE_ROOT") && sudo -u www-data $RUN_CMD"
else
    ( cd "$MOODLE_ROOT" && ddev exec "$RUN_CMD" )
fi
rc=$?
set -e

if [[ "$CHECK" == "true" ]]; then
    (( rc == 0 )) && print_status "OK" "$SITE OIDC wiring verified against $(basename "$CONTRACT")" \
                  || print_status "FAIL" "$SITE OIDC wiring does NOT match the contract"
    exit "$rc"
fi

(( rc == 0 )) || { print_error "OIDC wiring failed (rc=$rc)"; exit "$rc"; }
print_status "OK" "$SITE wired to the $PROVIDER issuer ($ISSUER)"
print_hint "Verify: scripts/demo/ssd-oidc-wire.sh --check"
