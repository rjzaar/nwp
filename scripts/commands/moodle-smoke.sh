#!/bin/bash
set -uo pipefail
################################################################################
# scripts/commands/moodle-smoke.sh — Moodle-aware promotion smoke (ADR-0031 D8)
#
# A smoke check for a PROMOTED Moodle tier, parallel to pair-smoke.sh but
# Moodle-specific:
#   1. bootstrap check — php admin/cli/checks.php against the local Moodle root
#      (run only with --run + a local --moodle-root; NEVER against prod);
#   2. consumer login page probe (/login/index.php);
#   3. provider OIDC discovery probe (/.well-known/openid-configuration),
#      consuming the pair contract's issuer + smoke_urls.
#
# SAFE BY DEFAULT — DRY RUN unless --run (prints the plan, no network, no CLI).
# --run against tier=prod is refused unless --force-prod. Read-only probes only.
#
# Usage:
#   pl moodle-smoke <consumer> [--tier=dev|stg|live|prod] [--dry-run|--run]
#                   [--moodle-root=DIR] [--provider-base=URL] [--consumer-base=URL]
#                   [--force-prod]
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
PROJECT_ROOT="${PROJECT_ROOT:-$REPO_ROOT}"

source "$REPO_ROOT/lib/ui.sh"
source "$REPO_ROOT/lib/pair.sh"

show_help() {
    cat <<EOF
${BOLD}NWP Moodle Smoke — Moodle-aware promotion smoke (ADR-0031 D8)${NC}

${BOLD}USAGE:${NC}
    pl moodle-smoke <consumer> [OPTIONS]

${BOLD}OPTIONS:${NC}
    -h, --help            Show this help
    --tier=<t>            dev | stg | live | prod   (default: dev)
    --dry-run             Print the plan only — NO network / CLI (DEFAULT)
    --run                 Actually probe (HTTP GET) + run the bootstrap check
    --moodle-root=DIR     Local Moodle root for the admin/cli/checks.php bootstrap
    --provider-base=URL   Override provider base (default: contract issuer)
    --consumer-base=URL   Consumer base URL (for the login-page probe)
    --force-prod          Permit --run against tier=prod (bootstrap check skipped)

${BOLD}NOTES:${NC}
    * Default is a DRY RUN. Nothing touches the network without --run.
    * The bootstrap check runs php admin/cli/checks.php against --moodle-root and
      is SKIPPED on prod (never run this substrate's CLI against a live site).
EOF
}

CONSUMER=""
TIER="dev"
MODE="dry-run"
MOODLE_ROOT=""
PROVIDER_BASE=""
CONSUMER_BASE=""
FORCE_PROD=false

for arg in "$@"; do
    case "$arg" in
        -h|--help)         show_help; exit 0 ;;
        --dry-run)         MODE="dry-run" ;;
        --run)             MODE="run" ;;
        --force-prod)      FORCE_PROD=true ;;
        --tier=*)          TIER="${arg#*=}" ;;
        --moodle-root=*)   MOODLE_ROOT="${arg#*=}" ;;
        --provider-base=*) PROVIDER_BASE="${arg#*=}" ;;
        --consumer-base=*) CONSUMER_BASE="${arg#*=}" ;;
        -*) print_error "Unknown option: $arg"; show_help; exit 1 ;;
        *)  [ -z "$CONSUMER" ] && CONSUMER="$arg" || { print_error "Unexpected arg: $arg"; exit 1; } ;;
    esac
done

[ -z "$CONSUMER" ] && { print_error "A consumer site (pair id) is required, e.g. 'pl moodle-smoke ssc'"; show_help; exit 1; }
case "$TIER" in dev|stg|live|prod) ;; *) print_error "Invalid --tier '$TIER'"; exit 1 ;; esac

CONTRACT="$(pair_contract_file "$CONSUMER")"
if ! pair_contract_valid "$CONTRACT"; then
    print_error "No valid pair contract for '$CONSUMER' at: $CONTRACT"
    print_info  "Author it from pair-contract.example.yml (see docs/guides/ops75-pair-contract-schema.md)."
    exit 1
fi

PROVIDER="$(pair_contract_get "$CONTRACT" '.provider' 2>/dev/null || echo '?')"
[ -z "$PROVIDER_BASE" ] && PROVIDER_BASE="$(pair_contract_get "$CONTRACT" ".endpoints.${TIER}.issuer" 2>/dev/null || true)"

print_header "Moodle smoke: ${CONSUMER} ↔ ${PROVIDER} @ ${TIER} (${MODE})"
echo "  Provider base: ${PROVIDER_BASE:-<unset>}"
echo "  Consumer base: ${CONSUMER_BASE:-<unset>}"
echo "  Moodle root:   ${MOODLE_ROOT:-<none — bootstrap check skipped>}"
echo ""

# --- Build the plan ----------------------------------------------------------
# 1. bootstrap check (local CLI), 2. consumer login page, 3. provider discovery.
print_info "Moodle promotion smoke plan:"
echo "   [1] bootstrap   php ${MOODLE_ROOT:-<moodle-root>}/admin/cli/checks.php"
echo "   [2] consumer    GET ${CONSUMER_BASE:-<consumer-base>}/login/index.php            expect 200,303"
echo "   [3] provider    GET ${PROVIDER_BASE:-<provider-base>}/.well-known/openid-configuration  expect 200"
echo ""

if [ "$MODE" != "run" ]; then
    print_status "OK" "Dry run — no network / CLI was touched. Re-run with --run to probe."
    exit 0
fi

# --- --run path --------------------------------------------------------------
if [ "$TIER" = "prod" ] && [ "$FORCE_PROD" != "true" ]; then
    print_error "Refusing to probe a PROD tier without --force-prod (safety)."
    exit 1
fi
command -v curl >/dev/null 2>&1 || { print_error "curl not found — required for --run."; exit 1; }

fails=0

# 1. bootstrap check — local CLI, never on prod.
if [ "$TIER" = "prod" ]; then
    print_info "Bootstrap check skipped on prod (never run this substrate's CLI against a live site)."
elif [ -n "$MOODLE_ROOT" ] && [ -f "$MOODLE_ROOT/admin/cli/checks.php" ]; then
    if command -v php >/dev/null 2>&1 && php "$MOODLE_ROOT/admin/cli/checks.php" >/dev/null 2>&1; then
        print_status "OK" "bootstrap → admin/cli/checks.php passed"
    else
        print_status "FAIL" "bootstrap → admin/cli/checks.php failed (or php missing)"
        fails=$((fails+1))
    fi
else
    print_status "WARN" "bootstrap → no --moodle-root/admin/cli/checks.php — skipped"
fi

# 2. consumer login page.
if [ -n "$CONSUMER_BASE" ]; then
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${CONSUMER_BASE%/}/login/index.php" 2>/dev/null || echo 000)"
    case "$code" in
        200|303) print_status "OK"   "consumer login → $code" ;;
        *)       print_status "FAIL" "consumer login → $code (expected 200/303)"; fails=$((fails+1)) ;;
    esac
else
    print_status "WARN" "consumer login → no --consumer-base — skipped"
fi

# 3. provider OIDC discovery.
if [ -n "$PROVIDER_BASE" ]; then
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${PROVIDER_BASE%/}/.well-known/openid-configuration" 2>/dev/null || echo 000)"
    if [ "$code" = "200" ]; then
        print_status "OK" "provider discovery → 200"
    else
        print_status "FAIL" "provider discovery → $code (expected 200)"; fails=$((fails+1))
    fi
else
    print_status "WARN" "provider discovery → no provider base — skipped"
fi

echo ""
if [ "$fails" -gt 0 ]; then
    print_error "Moodle smoke: $fails check(s) failed."
    exit 1
fi
print_status "OK" "Moodle smoke passed."
exit 0
