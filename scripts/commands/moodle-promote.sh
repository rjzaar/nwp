#!/bin/bash
set -uo pipefail
################################################################################
# scripts/commands/moodle-promote.sh — Moodle promotion substrate entrypoint
#                                       (NWP-ADR-0031 D8 / ops D)
#
# The Moodle-stack analogue of the Drupal settings-rewrite + `drush cr` that
# dev2stg/prod2stg do. Given a Moodle site + a NON-canonical target tier, it
# (re)writes config.php, generates an nginx vhost, emits the F26 OIDC wiring
# descriptors, and prints the wwwroot DB-rewrite / cache-purge plan — then hands
# off to `pl moodle-smoke` (dry-run).
#
# SAFE BY DEFAULT:
#   * DRY RUN unless --apply. Dry run writes NOTHING and touches no network.
#   * OFF-UNLESS-CONFIGURED. A site whose project.type != moodle is a NO-OP
#     (exit 0). No fleet site is Moodle-canonical today, so this is inert.
#   * FAIL-CLOSED, non-canonical only. Refuses any tier that is not dev/stg/test
#     — it never rewrites a live/prod Moodle root.
#   * NO SECRETS on argv; NO nginx install/reload; NO DB execution; NO network.
#
# Usage:
#   pl moodle-promote <site> [--tier=dev|stg] [--dry-run|--apply]
#                     [--out-dir=DIR] [--php=8.1]
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
# Libs always load from the repo; sites/config resolve from PROJECT_ROOT, which
# defaults to the repo but is honoured if pre-set (test isolation).
PROJECT_ROOT="${PROJECT_ROOT:-$REPO_ROOT}"

source "$REPO_ROOT/lib/ui.sh"
# pair.sh gives pair_contract_* (issuer URL per tier); moodle-promote.sh the substrate.
[ -f "$REPO_ROOT/lib/pair.sh" ] && source "$REPO_ROOT/lib/pair.sh"
source "$REPO_ROOT/lib/moodle-promote.sh"

show_help() {
    cat <<EOF
${BOLD}NWP Moodle Promote — Moodle promotion substrate (NWP-ADR-0031 D8)${NC}

${BOLD}USAGE:${NC}
    pl moodle-promote <site> [OPTIONS]

${BOLD}OPTIONS:${NC}
    -h, --help          Show this help
    --tier=<t>          dev | stg | test   (default: dev). live/prod are REFUSED.
    --dry-run           Plan only — writes NOTHING, no network (DEFAULT)
    --apply             Actually write config.php + vhost + OIDC descriptors
    --out-dir=DIR       Where vhost + OIDC artifacts go (default: private/moodle/<site>)
    --php=<x.y>         PHP-FPM version for the vhost (default: 8.1)
    --auth-nwc-src=DIR  auth_nwc plugin source tree to deploy into <root>/auth/nwc
                        (F26 consumer; also read from .moodle.oauth.auth_nwc_src)
    --run-cli           Also EXECUTE the generated OIDC apply-script against the
                        Moodle DB (creates the issuer+mappings+auth config). Off by
                        default — the default only WRITES the script + prints how to
                        run it. Refuses prod. Needs the client secret provisioned.

${BOLD}NOTES:${NC}
    * A site whose project.type != moodle is a no-op (exit 0).
    * Only dev/stg/test are writable — a live/prod Moodle root is never rewritten.
    * The wwwroot DB-side rewrite + cache purge are PRINTED, never executed.
    * The F26 OIDC wiring (issuer + sub→idnumber lock + auth_nwc config) is emitted
      as a real, idempotent admin/cli-style PHP apply-script — codifies the flow
      proven by hand on live ssc↔nwc (see docs/guides/moodle-promotion-substrate.md).
EOF
}

SITE=""
TIER="dev"
MODE="dry-run"
OUT_DIR=""
PHP_VERSION="8.1"
AUTH_NWC_SRC=""
RUN_CLI="no"

for arg in "$@"; do
    case "$arg" in
        -h|--help)         show_help; exit 0 ;;
        --dry-run)         MODE="dry-run" ;;
        --apply)           MODE="apply" ;;
        --tier=*)          TIER="${arg#*=}" ;;
        --out-dir=*)       OUT_DIR="${arg#*=}" ;;
        --php=*)           PHP_VERSION="${arg#*=}" ;;
        --auth-nwc-src=*)  AUTH_NWC_SRC="${arg#*=}" ;;
        --run-cli)         RUN_CLI="yes" ;;
        -*)                print_error "Unknown option: $arg"; show_help; exit 1 ;;
        *)  [ -z "$SITE" ] && SITE="$arg" || { print_error "Unexpected arg: $arg"; exit 1; } ;;
    esac
done

[ -z "$SITE" ] && { print_error "A site is required, e.g. 'pl moodle-promote ssc --tier=dev'"; show_help; exit 1; }

case "$TIER" in
    dev|stg|test) ;;
    live|prod) print_error "REFUSED: tier '$TIER' — the substrate never targets a live/prod Moodle root."; exit 1 ;;
    *) print_error "Invalid --tier '$TIER' (dev|stg|test)"; exit 1 ;;
esac

# --- resolve the site config + moodle root (v2 nested layout) ----------------
CONFIG_FILE="$PROJECT_ROOT/sites/$SITE/.nwp.yml"
MOODLE_ROOT="$PROJECT_ROOT/sites/$SITE/$TIER"

if [ ! -f "$CONFIG_FILE" ]; then
    print_error "No site config at $CONFIG_FILE"
    exit 1
fi

# --- OFF-UNLESS-CONFIGURED: non-Moodle sites are a no-op ----------------------
if ! _moodle_is_moodle_site "$CONFIG_FILE"; then
    print_info "no-op: '$SITE' is not a Moodle site (project.type != moodle). Nothing to do."
    exit 0
fi

# --- pair contract (optional; drives the OIDC wiring) ------------------------
CONTRACT_FILE=""
if declare -F pair_contract_file >/dev/null 2>&1; then
    _c="$(pair_contract_file "$SITE")"
    [ -f "$_c" ] && CONTRACT_FILE="$_c"
fi

[ -z "$OUT_DIR" ] && OUT_DIR="$PROJECT_ROOT/private/moodle/$SITE"

print_header "Moodle promote: $SITE @ $TIER (${MODE})"

# --- DRY RUN: print the plan and exit ----------------------------------------
if [ "$MODE" != "apply" ]; then
    moodle_promote_plan "$SITE" "$TIER" "$CONFIG_FILE" "$MOODLE_ROOT" "$CONTRACT_FILE" "$OUT_DIR"
    echo ""
    print_status "OK" "Dry run — nothing written. Re-run with --apply to perform it."
    exit 0
fi

# --- APPLY -------------------------------------------------------------------
if [ ! -f "$MOODLE_ROOT/version.php" ]; then
    print_error "No Moodle codebase at $MOODLE_ROOT (version.php absent) — cannot apply."
    print_info  "Check out / build the Moodle tier tree first."
    exit 1
fi

mkdir -p "$OUT_DIR" 2>/dev/null || { print_error "Cannot create out-dir: $OUT_DIR"; exit 1; }

# 1. settings writer (config.php)
if ! moodle_write_config "$MOODLE_ROOT" "$TIER" "$CONFIG_FILE"; then
    print_error "config.php write failed — aborting."
    exit 1
fi

# 2. vhost
DOMAIN="$(_mp_cfg "$CONFIG_FILE" ".moodle.tiers.${TIER}.domain" '' || true)"
if [ -z "$DOMAIN" ]; then
    # derive host from the wwwroot
    _www="$(_mp_cfg "$CONFIG_FILE" ".moodle.tiers.${TIER}.wwwroot" '' || true)"
    DOMAIN="$(printf '%s' "$_www" | sed -E 's#^https?://##; s#/.*$##')"
fi
if [ -n "$DOMAIN" ]; then
    moodle_generate_vhost "$DOMAIN" "$MOODLE_ROOT" "$TIER" "$OUT_DIR/${SITE}-${TIER}.nginx.conf" "$PHP_VERSION" || true
else
    print_warning "No domain/wwwroot to build a vhost from — skipped vhost generation."
fi

# 3. OIDC wiring (F26). Descriptors + the live-proven apply-script. Contract-gated.
CLI_PHP="$(_mp_cfg "$CONFIG_FILE" '.moodle.oauth.cli_php_version' '8.2' || true)"
APPLY_SCRIPT="$OUT_DIR/${SITE}-${TIER}.oidc-apply.php"
if [ -n "$CONTRACT_FILE" ]; then
    moodle_oauth_consumer_config "$SITE" "$TIER" "$CONTRACT_FILE" "$CONFIG_FILE" \
        "$OUT_DIR/${SITE}-${TIER}.oidc-consumer.yml" || \
        print_warning "OIDC consumer descriptor not written (see message above)."
    moodle_oauth_provider_snippet "$SITE" "$TIER" "$CONTRACT_FILE" "$CONFIG_FILE" \
        "$OUT_DIR/${SITE}-${TIER}.oidc-provider-snippet.yml" || \
        print_warning "OIDC provider snippet not written (see message above)."
    # The real, runnable apply-script (issuer + endpoints + sub→idnumber + auth_nwc).
    moodle_generate_oidc_apply_script "$SITE" "$TIER" "$CONTRACT_FILE" "$CONFIG_FILE" \
        "$APPLY_SCRIPT" || print_warning "OIDC apply-script not written (see message above)."
else
    print_info "No pair contract for '$SITE' — OIDC wiring skipped (author pairs/${SITE}.pair-contract.yml)."
fi

# 3b. Deploy the auth_nwc plugin (F26 consumer). Source from flag or config.
[ -z "$AUTH_NWC_SRC" ] && AUTH_NWC_SRC="$(_mp_cfg "$CONFIG_FILE" '.moodle.oauth.auth_nwc_src' '' || true)"
if [ -n "$AUTH_NWC_SRC" ]; then
    moodle_deploy_auth_nwc "$MOODLE_ROOT" "$TIER" "$AUTH_NWC_SRC" "$CLI_PHP" || \
        print_warning "auth_nwc plugin not deployed (see message above)."
else
    print_info "No auth_nwc source (--auth-nwc-src / .moodle.oauth.auth_nwc_src) — plugin deploy skipped."
fi

# 3c. Optionally EXECUTE the apply-script against the Moodle DB (--run-cli).
if [ "$RUN_CLI" = "yes" ] && [ -f "$APPLY_SCRIPT" ]; then
    moodle_run_oidc_apply "$MOODLE_ROOT" "$TIER" "$APPLY_SCRIPT" "$SITE" "$CONFIG_FILE" "$CLI_PHP" || \
        print_warning "OIDC apply-script execution reported an error (see above)."
elif [ -f "$APPLY_SCRIPT" ]; then
    print_info "OIDC apply-script written but NOT executed. To create the issuer on the DB, run:"
    echo "  MOODLE_CONFIG_PATH=${MOODLE_ROOT}/config.php \\"
    echo "  NWC_OIDC_CLIENT_SECRET=<secret> php${CLI_PHP} -d max_input_vars=5000 ${APPLY_SCRIPT}"
    echo "  # or: pl moodle-promote $SITE --tier=$TIER --apply --run-cli"
fi

# 4. wwwroot DB-rewrite + cache purge PLAN (printed, never executed here)
echo ""
NEW_WWWROOT="$(_mp_cfg "$CONFIG_FILE" ".moodle.tiers.${TIER}.wwwroot" '' || true)"
print_info "Post-write operator steps (run against this NON-prod tier only):"
moodle_wwwroot_rewrite_plan "$MOODLE_ROOT" "<old-wwwroot>" "${NEW_WWWROOT:-<new-wwwroot>}" || true

# 5. smoke (dry-run hand-off)
echo ""
print_info "Then verify: pl moodle-smoke $SITE --tier=$TIER --dry-run"

echo ""
print_status "OK" "Applied Moodle substrate for $SITE@$TIER. Artifacts in: $OUT_DIR"
print_warning "Nothing was installed/reloaded/executed against a server or DB — those are operator steps."
exit 0
