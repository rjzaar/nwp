#!/bin/bash
set -euo pipefail
################################################################################
# scripts/demo/ssd-demo-posture.sh — apply (or --check) the Moodle-side demo
# posture on the ssd half of the nwd↔ssd demo pair (ops#133 Phase 2, §2.5).
#
#   scripts/demo/ssd-demo-posture.sh [--site=ssd] [--tier=dev] [--check]
#
# Stages ssd-demo-posture.php into the Moodle root (the repo lives outside the
# ddev mount), runs it in the container, and removes it again — the same idiom
# the ops#93 e2e uses for its fixture.
#
# The provider (nwd) base URL and the "Report a problem" target come from the
# PAIR CONTRACT + the site config, never hardcoded:
#   provider base : pairs/<site>.pair-contract.yml → endpoints.<tier>.issuer
#   feedback path : pairs/<site>.pair-contract.yml → demo.feedback_path
#                   (default /demo/feedback)
# Fail-closed: no issuer for the tier ⇒ refuse (a banner with a dead
# "Report a problem" link is worse than no banner).
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

# ops#146: live is now implemented (the demo tier HAS a live consumer). The
# posture is banner text + noindex + a report-a-problem link — it carries no
# dev-only relaxation, so there is nothing here that must not follow to live.
case "$TIER" in dev|stg|live) ;; *) print_error "REFUSED: tier '$TIER'"; exit 1 ;; esac

if [[ "$TIER" != "live" ]]; then
    MOODLE_ROOT="$(resolve_project "$SITE" "$TIER")" || { print_error "Cannot resolve $SITE ($TIER)"; exit 1; }
    [[ -f "$MOODLE_ROOT/version.php" ]] || { print_error "REFUSED: $MOODLE_ROOT is not a Moodle root"; exit 1; }
fi

CONTRACT="$(demo_pair_contract_for "$SITE")" || {
    print_error "REFUSED: no pair contract naming '$SITE' under $PROJECT_ROOT/pairs/"
    exit 1
}
PROVIDER_URL="$(demo_pair_issuer "$CONTRACT" "$TIER")" || {
    print_error "REFUSED: no endpoints.${TIER}.issuer in $CONTRACT — cannot build the banner link."
    exit 1
}
FEEDBACK_PATH="$(demo_pair_get "$CONTRACT" '.demo.feedback_path' '/demo/feedback')"
FEEDBACK_URL="${PROVIDER_URL%/}${FEEDBACK_PATH}"

CLI_PHP="${CLI_PHP:-$(demo_pair_get "$CONTRACT" '.oidc.cli_php_version' '8.3')}"

args=""
[[ "$CHECK" == "true" ]] && args="--check"

# `ddev exec` interprets its argument with bash INSIDE the container, so the
# env assignment travels with the command. Both values are public URLs — no
# secret ever goes on a container command line (see ssd-oidc-wire.sh for the
# secret-bearing case, which uses a 0600 file outside the docroot instead).
set +e
demo_moodle_php_run "$SITE" "$TIER" "$SCRIPT_DIR/ssd-demo-posture.php" "$CLI_PHP" \
    "DEMO_PROVIDER_URL=$PROVIDER_URL" "DEMO_FEEDBACK_URL=$FEEDBACK_URL" -- $args
rc=$?
set -e

if [[ "$CHECK" == "true" ]]; then
    if (( rc == 0 )); then
        print_status "OK" "$SITE ($TIER) demo posture verified"
    else
        print_status "FAIL" "$SITE ($TIER) demo posture INCOMPLETE"
    fi
    exit "$rc"
fi

(( rc == 0 )) || { print_error "Demo posture apply failed (rc=$rc)"; exit "$rc"; }
print_status "OK" "$SITE ($TIER) demo posture applied (banner → ${FEEDBACK_URL})"
