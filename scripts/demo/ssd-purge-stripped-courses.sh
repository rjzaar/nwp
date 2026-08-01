#!/bin/bash
set -euo pipefail
################################################################################
# scripts/demo/ssd-purge-stripped-courses.sh — remove the stripped course rows
# that a failing admin/cli/delete_course.php run leaves behind (see the .php
# for the root cause: the stock CLI never loads course/lib.php, so every
# delete throws AFTER tearing the content down and BEFORE deleting the row).
#
#   scripts/demo/ssd-purge-stripped-courses.sh [--site=ssd] [--tier=dev] [--check]
#
# Only touches courses that are (a) in one of the four import rail categories,
# (b) named like the prod import set (letter+digit) and (c) hold ZERO course
# modules. A course with any content is skipped loudly, never deleted.
# Stages the .php into the Moodle root, runs it, removes it again — the same
# gated idiom as ssd-seed-courses.sh (ops#146: live allowed, prod refused).
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
PROJECT_ROOT="${PROJECT_ROOT:-$REPO_ROOT}"

source "$REPO_ROOT/lib/ui.sh"
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/demo-pair.sh"

SITE="ssd"; TIER="dev"; PASS=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --site=*) SITE="${1#--site=}"; shift ;;
        --tier=*) TIER="${1#--tier=}"; shift ;;
        --check)  PASS="$PASS --check"; shift ;;
        *) print_error "Unknown option '$1'"; exit 1 ;;
    esac
done

case "$TIER" in dev|stg|live) ;; *) print_error "REFUSED: tier '$TIER' — dev|stg|live only."; exit 1 ;; esac

if [[ "$TIER" != "live" ]]; then
    MOODLE_ROOT="$(resolve_project "$SITE" "$TIER")" || { print_error "Cannot resolve $SITE ($TIER)"; exit 1; }
    [[ -f "$MOODLE_ROOT/version.php" ]] || { print_error "REFUSED: $MOODLE_ROOT is not a Moodle root"; exit 1; }
fi

CONTRACT="$(demo_pair_contract_for "$SITE")" || { print_error "REFUSED: no demo-enabled pair contract names '$SITE'."; exit 1; }
CLI_PHP="${CLI_PHP:-$(demo_pair_get "$CONTRACT" '.oidc.cli_php_version' '8.3')}"

set +e
demo_moodle_php_run "$SITE" "$TIER" "$SCRIPT_DIR/ssd-purge-stripped-courses.php" "$CLI_PHP" -- $PASS
rc=$?
set -e

(( rc == 0 )) || { print_error "Purge failed (rc=$rc)"; exit "$rc"; }
print_status "OK" "$SITE stripped-course purge complete"
