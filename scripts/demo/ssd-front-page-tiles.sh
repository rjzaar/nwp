#!/bin/bash
set -euo pipefail
################################################################################
# scripts/demo/ssd-front-page-tiles.sh — recreate the v1 ten-tile
# "Where would you like to begin?" intent view as the ssd front page
# (nwp/ops#278, OPERATOR RULING 2026-08-06: option C, tiles FIRST).
#
#   scripts/demo/ssd-front-page-tiles.sh [--site=ssd] [--tier=dev] [--probe|--check]
#
#   --probe  read-only recon (current settings + rollback values), writes nothing
#   --check  exit 0 only if the tile page is fully applied, writes nothing
#   (none)   apply, idempotently
#
# Stages ssd-front-page-tiles.php into the Moodle root via the ops#146
# staged-PHP transport (lib/demo-pair.sh demo_moodle_php_run), runs it, removes
# it again — the same gated idiom as ssd-demo-posture.sh (live allowed, prod
# refused). After a LIVE apply the paired golden MUST be recaptured
# (`pl demo golden nwd --tier=live --with-pair`) or the nightly reset reverts
# the change (ops#269 lesson, restated in the ops#278 ruling).
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
PROJECT_ROOT="${PROJECT_ROOT:-$REPO_ROOT}"

source "$REPO_ROOT/lib/ui.sh"
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/demo-pair.sh"

SITE="ssd"; TIER="dev"; MODE="apply"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --site=*) SITE="${1#--site=}"; shift ;;
        --tier=*) TIER="${1#--tier=}"; shift ;;
        --probe)  MODE="probe"; shift ;;
        --check)  MODE="check"; shift ;;
        *) print_error "Unknown option '$1'"; exit 1 ;;
    esac
done

# Demo-tier front-page content only. prod refused — same posture as the seeder.
case "$TIER" in dev|stg|live) ;; *) print_error "REFUSED: tier '$TIER' — dev|stg|live only."; exit 1 ;; esac

if [[ "$TIER" != "live" ]]; then
    MOODLE_ROOT="$(resolve_project "$SITE" "$TIER")" || { print_error "Cannot resolve $SITE ($TIER)"; exit 1; }
    [[ -f "$MOODLE_ROOT/version.php" ]] || { print_error "REFUSED: $MOODLE_ROOT is not a Moodle root"; exit 1; }
fi

# Demo gate: only a demo-enabled pair contract may name this site. The real,
# student-bearing pair must never be reachable from a front-page rewrite.
CONTRACT="$(demo_pair_contract_for "$SITE")" || {
    print_error "REFUSED: no DEMO-ENABLED pair contract naming '$SITE' under $PROJECT_ROOT/pairs/"
    exit 1
}

CLI_PHP="${CLI_PHP:-$(demo_pair_get "$CONTRACT" '.oidc.cli_php_version' '8.3')}"

args=""
case "$MODE" in
    probe) args="--probe" ;;
    check) args="--check" ;;
esac

set +e
demo_moodle_php_run "$SITE" "$TIER" "$SCRIPT_DIR/ssd-front-page-tiles.php" "$CLI_PHP" -- $args
rc=$?
set -e

case "$MODE" in
    probe)
        exit "$rc" ;;
    check)
        if (( rc == 0 )); then
            print_status "OK" "$SITE ($TIER) front-page tiles verified"
        else
            print_status "FAIL" "$SITE ($TIER) front-page tiles NOT applied"
        fi
        exit "$rc" ;;
esac

(( rc == 0 )) || { print_error "Front-page tiles apply failed (rc=$rc)"; exit "$rc"; }
print_status "OK" "$SITE ($TIER) front page now carries the v1 ten-tile intent view (ops#278)"
if [[ "$TIER" == "live" ]]; then
    print_warning "Recapture the paired golden NOW or the nightly reset reverts this:"
    print_warning "    pl demo golden nwd --tier=live --with-pair"
fi
