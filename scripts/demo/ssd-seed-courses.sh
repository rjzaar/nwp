#!/bin/bash
set -euo pipefail
################################################################################
# scripts/demo/ssd-seed-courses.sh — seed (or --check) the ssd demo catalogue.
# ops#133 Phase 2.
#
#   scripts/demo/ssd-seed-courses.sh [--site=ssd] [--tier=dev] [--check]
#                                    [--bind-cohorts]
#
# Stages ssd-seed-courses.php into the Moodle root, runs it, removes it again.
# See that file for what gets created and why. Dev/stg only.
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
PROJECT_ROOT="${PROJECT_ROOT:-$REPO_ROOT}"

source "$REPO_ROOT/lib/ui.sh"
source "$REPO_ROOT/lib/common.sh"

SITE="ssd"; TIER="dev"; PASS=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --site=*) SITE="${1#--site=}"; shift ;;
        --tier=*) TIER="${1#--tier=}"; shift ;;
        --check)  PASS="$PASS --check"; shift ;;
        --bind-cohorts) PASS="$PASS --bind-cohorts"; shift ;;
        *) print_error "Unknown option '$1'"; exit 1 ;;
    esac
done

case "$TIER" in dev|stg) ;; *) print_error "REFUSED: tier '$TIER' — seeding is dev|stg only."; exit 1 ;; esac

MOODLE_ROOT="$(resolve_project "$SITE" "$TIER")" || { print_error "Cannot resolve $SITE ($TIER)"; exit 1; }
[[ -f "$MOODLE_ROOT/version.php" ]] || { print_error "REFUSED: $MOODLE_ROOT is not a Moodle root"; exit 1; }
[[ -d "$MOODLE_ROOT/mod/depthcontent" ]] || {
    print_error "REFUSED: mod_depthcontent not installed — run scripts/demo/ssd-rebuild.sh first."
    exit 1
}

CLI_PHP="${CLI_PHP:-php8.3}"
STAGED="ssd_seed_courses_tmp.php"
cp "$SCRIPT_DIR/ssd-seed-courses.php" "$MOODLE_ROOT/$STAGED"
trap 'rm -f "$MOODLE_ROOT/$STAGED"' EXIT

set +e
( cd "$MOODLE_ROOT" && ddev exec "$CLI_PHP -d max_input_vars=5000 $STAGED $PASS" )
rc=$?
set -e

if [[ "$PASS" == *--check* ]]; then
    (( rc == 0 )) && print_status "OK" "$SITE demo catalogue present + enterable" \
                  || print_status "FAIL" "$SITE demo catalogue incomplete"
    exit "$rc"
fi
(( rc == 0 )) || { print_error "Seeding failed (rc=$rc)"; exit "$rc"; }
print_status "OK" "$SITE demo catalogue seeded"
