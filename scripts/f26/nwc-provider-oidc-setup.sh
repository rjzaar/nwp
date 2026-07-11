#!/bin/bash
set -uo pipefail
################################################################################
# scripts/f26/nwc-provider-oidc-setup.sh — F26 PROVIDER-side OIDC setup (nwc).
#
# Codifies the Drupal/nwc half of the ssc↔nwc OIDC flow that was done BY HAND and
# PROVEN end-to-end on live 2026-07-11 (memory f26-auth-plugin-reconcile). This is
# an OPERATOR-RUN helper — nwc is a separate site/repo, so it is NOT auto-invoked
# by `pl`. Run it from the nwc Drupal docroot (or pass --drush="ddev drush").
#
# It performs the three provider prerequisites (steps 5–7):
#   5. create/ensure the simple_oauth Consumer (client) for the Moodle consumer
#      — confidential=TRUE, pkce=TRUE, redirect=<moodle>/admin/oauth2callback.php,
#      grant_types=[authorization_code, refresh_token];
#   6. ensure simple_oauth has a signing KEYPAIR (generate if missing, then point
#      simple_oauth.settings public_key/private_key at it) — these were MISSING on
#      live and broke JWKS + token signing until generated;
#   7. grant the 'grant simple_oauth codes' permission to the authenticated role
#      (else the consent step fails).
#
# SAFETY:
#   * The client secret is NEVER taken on argv. Provide it via the environment:
#       NWC_OIDC_CLIENT_SECRET=... scripts/f26/nwc-provider-oidc-setup.sh ...
#     If unset, the script GENERATES one and prints it once for you to store in
#     the consumer's secret store (moodle.<consumer>.oauth.client_secret).
#   * DRY-RUN by default: prints the drush commands, runs nothing. --apply to run.
#   * REFUSES to target a prod issuer URL unless --force-prod (offline-gated).
#
# Usage:
#   scripts/f26/nwc-provider-oidc-setup.sh \
#       --client-id=ss_moodle \
#       --redirect=https://ssc.<example-prod-domain>/admin/oauth2callback.php \
#       [--drush="ddev drush"] [--keys-dir=/var/www/nwc/oauth-keys] \
#       [--apply] [--force-prod]
################################################################################

CLIENT_ID="ss_moodle"
REDIRECT=""
DRUSH="drush"
KEYS_DIR=""
MODE="dry-run"
FORCE_PROD="no"

die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }
run()  { # echo, then run only in --apply
    printf '  %s\n' "$*"
    [ "$MODE" = "apply" ] && eval "$*"
}

for arg in "$@"; do
    case "$arg" in
        -h|--help)      grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        --client-id=*)  CLIENT_ID="${arg#*=}" ;;
        --redirect=*)   REDIRECT="${arg#*=}" ;;
        --drush=*)      DRUSH="${arg#*=}" ;;
        --keys-dir=*)   KEYS_DIR="${arg#*=}" ;;
        --apply)        MODE="apply" ;;
        --force-prod)   FORCE_PROD="yes" ;;
        *)              die "Unknown argument: $arg" ;;
    esac
done

[ -n "$REDIRECT" ] || die "--redirect=<moodle-wwwroot>/admin/oauth2callback.php is required."
case "$REDIRECT" in
    */admin/oauth2callback.php) : ;;
    *) die "--redirect must end with /admin/oauth2callback.php (Moodle OAuth2 callback)." ;;
esac

# Refuse an obvious prod redirect unless forced (offline-deploy-gated per ADR).
if printf '%s' "$REDIRECT" | grep -qiE '(^|[^a-z])prod([^a-z]|$)' && [ "$FORCE_PROD" != "yes" ]; then
    die "Redirect looks like a prod host; refusing without --force-prod (offline-gated)."
fi

[ -z "$KEYS_DIR" ] && KEYS_DIR="oauth-keys"

info "F26 provider (nwc) OIDC setup — ${MODE} (client_id=${CLIENT_ID})"
info "This codifies the LIVE-PROVEN provider steps (memory f26-auth-plugin-reconcile)."
echo ""

# --- Client secret: never on argv. Use env, or generate + print once. --------
SECRET="${NWC_OIDC_CLIENT_SECRET:-}"
GENERATED_SECRET="no"
if [ -z "$SECRET" ]; then
    if command -v openssl >/dev/null 2>&1; then
        SECRET="$(openssl rand -hex 32)"
    else
        SECRET="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    fi
    GENERATED_SECRET="yes"
fi

# --- Step 6: signing keypair (generate if missing) ---------------------------
info "Step 6 — simple_oauth signing keypair (JWKS/token-signing depends on it):"
run "$DRUSH simple-oauth:generate-keys ${KEYS_DIR} || true"
run "$DRUSH cset -y simple_oauth.settings public_key  ${KEYS_DIR}/public.key"
run "$DRUSH cset -y simple_oauth.settings private_key ${KEYS_DIR}/private.key"
echo ""

# --- Step 5: the Consumer (client) entity ------------------------------------
# Consumer entities are created via the entity API. We write an idempotent
# php:script (upsert by client_id) that reads its inputs from the environment —
# the client secret is passed via env, NEVER argv, and is not written to disk.
info "Step 5 — simple_oauth Consumer (confidential, PKCE, redirect, grant_types):"
UPSERT_PHP="$(mktemp "${TMPDIR:-/tmp}/nwc-consumer-upsert.XXXXXX.php")"
cat > "$UPSERT_PHP" <<'PHP'
<?php
// Idempotent simple_oauth Consumer upsert. Inputs from the environment only.
$cid    = getenv('NWC_OIDC_CLIENT_ID');
$redir  = getenv('NWC_OIDC_REDIRECT');
$secret = getenv('NWC_OIDC_CLIENT_SECRET');
$storage  = \Drupal::entityTypeManager()->getStorage('consumer');
$existing = $storage->loadByProperties(['client_id' => $cid]);
$consumer = $existing ? reset($existing) : $storage->create(['client_id' => $cid]);
$consumer->set('label', 'SS Moodle (' . $cid . ')');
$consumer->set('confidential', TRUE);
$consumer->set('pkce', TRUE);
$consumer->set('is_default', FALSE);
$consumer->set('redirect', $redir);
$consumer->set('grant_types', ['authorization_code', 'refresh_token']);
if ($secret) { $consumer->set('secret', $secret); }
$consumer->save();
print "Consumer saved: {$cid} (redirect={$redir})\n";
PHP
info "  # (client secret passed via env NWC_OIDC_CLIENT_SECRET — never argv/disk)"
info "  NWC_OIDC_CLIENT_ID=${CLIENT_ID} NWC_OIDC_REDIRECT=${REDIRECT} \\"
info "  NWC_OIDC_CLIENT_SECRET=<secret> ${DRUSH} php:script ${UPSERT_PHP}"
if [ "$MODE" = "apply" ]; then
    NWC_OIDC_CLIENT_ID="$CLIENT_ID" NWC_OIDC_REDIRECT="$REDIRECT" \
    NWC_OIDC_CLIENT_SECRET="$SECRET" $DRUSH php:script "$UPSERT_PHP" \
        || info "  (Consumer upsert reported an error — check the drush output above.)"
    rm -f "$UPSERT_PHP"
else
    info "  (dry-run: php:script written to ${UPSERT_PHP}; delete it when done.)"
fi
echo ""

# --- Step 7: consent permission ----------------------------------------------
info "Step 7 — grant 'grant simple_oauth codes' to the authenticated role:"
run "$DRUSH role:perm:add authenticated 'grant simple_oauth codes'"
echo ""

if [ "$MODE" != "apply" ]; then
    info "DRY-RUN — nothing executed. Re-run with --apply (from the nwc docroot) to perform it."
fi
if [ "$GENERATED_SECRET" = "yes" ]; then
    echo ""
    info "A client secret was GENERATED. Store it in the consumer's secret store as"
    info "moodle.<consumer>.oauth.client_secret (it is shown once):"
    info "  ${SECRET}"
fi
exit 0
