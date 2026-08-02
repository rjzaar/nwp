#!/bin/bash
set -euo pipefail
################################################################################
# scripts/demo/ssd-completion-criteria.sh — give named ssd demo courses a
# COURSE-level completion criterion, so that finishing the activities actually
# finishes the course.
#
#   scripts/demo/ssd-completion-criteria.sh --courses=B1,B2,B3,B4 \
#       [--site=ssd] [--tier=dev] [--check|--apply]
#
# See ssd-completion-criteria.php for the measurement that motivated it: 58 of
# 59 ssd courses track activity completion and NONE has a course criterion, so
# `completed` is false even at progress=100 and no completion can ever flow.
#
# DRY-RUN BY DEFAULT. Demo tier only (same pair-contract guard as the web
# service provisioner).
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
PROJECT_ROOT="${PROJECT_ROOT:-$REPO_ROOT}"

source "$REPO_ROOT/lib/ui.sh"
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/demo-pair.sh"

SITE="ssd"; TIER="dev"; MODE="--check"; COURSES=""
ASSUME_YES="${NWP_ASSUME_YES:-false}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --site=*)    SITE="${1#--site=}"; shift ;;
        --tier=*)    TIER="${1#--tier=}"; shift ;;
        --courses=*) COURSES="${1#--courses=}"; shift ;;
        --check)     MODE="--check"; shift ;;
        --apply)     MODE="--apply"; shift ;;
        -y|--yes)    ASSUME_YES="true"; shift ;;
        *) print_error "Unknown option '$1'"; exit 1 ;;
    esac
done

[[ -n "$COURSES" ]] || {
    print_error "REFUSED: --courses is required."
    print_info  "There is deliberately no 'all' shortcut: ssd course content is"
    print_info  "owned elsewhere, and rewriting 58 courses' completion rules is"
    print_info  "not a side effect this bridge gets to have."
    exit 1
}

case "$TIER" in
    dev|stg|live) ;;
    *) print_error "REFUSED: tier '$TIER' — dev|stg|live only."; exit 1 ;;
esac

CONTRACT="$(demo_pair_contract_for "$SITE")" || {
    print_error "REFUSED: no demo-enabled pair contract names '$SITE'."
    exit 1
}
CLI_PHP="${CLI_PHP:-$(demo_pair_get "$CONTRACT" '.oidc.cli_php_version' '8.3')}"

if [[ "$TIER" == "live" && "$MODE" == "--apply" ]]; then
    print_warning "LIVE: $SITE — adding course completion criteria to: $COURSES"
    source "$REPO_ROOT/lib/impact.sh"
    impact_confirm typed "$SITE" "$ASSUME_YES" \
        "This declares completion criteria on LIVE $SITE courses. Reversible: delete the added {course_completion_criteria} rows." \
        || { print_error "Aborted."; exit 1; }
fi

set +e
demo_moodle_php_run "$SITE" "$TIER" "$SCRIPT_DIR/ssd-completion-criteria.php" "$CLI_PHP" -- "--courses=$COURSES" $MODE
rc=$?
set -e

if [[ "$MODE" == "--check" ]]; then
    (( rc == 0 )) && print_status "OK"   "$SITE: named courses have completion criteria" \
                  || print_status "FAIL" "$SITE: completion criteria missing"
    exit "$rc"
fi
(( rc == 0 )) || { print_error "Failed (rc=$rc)"; exit "$rc"; }
print_status "OK" "$SITE completion criteria applied"
