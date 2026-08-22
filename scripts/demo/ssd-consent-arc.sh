#!/bin/bash
set -euo pipefail
################################################################################
# scripts/demo/ssd-consent-arc.sh — check/apply the Art.9 consent arc on the
# MOODLE half of the nwd↔ssd demo pair (nwp/ops#279, operator GO 2026-08-07).
#
#   scripts/demo/ssd-consent-arc.sh [--site=ssd] [--tier=live] [--check|--apply]
#
# --check (default) is READ-ONLY and is the verification the operator asked for:
# a staged-PHP probe, not a grep. --apply grants Art.9 consent to the demo
# personas so their practice ticks persist instead of being silently discarded.
#
# DEMO TIER ONLY, BY CONSTRUCTION. The site must be a half of a pair contract
# that declares `demo.enabled: true`. That is the same declared fact the golden
# capture and the nightly reset key off, so this verb cannot be pointed at the
# real pair (ssc/ss) by passing --site — the contract lookup refuses first.
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
PROJECT_ROOT="${PROJECT_ROOT:-$REPO_ROOT}"

source "$REPO_ROOT/lib/ui.sh"
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/demo-pair.sh"

SITE="ssd"; TIER="live"; MODE="check"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --site=*) SITE="${1#--site=}"; shift ;;
        --tier=*) TIER="${1#--tier=}"; shift ;;
        --check)  MODE="check"; shift ;;
        --apply)  MODE="apply"; shift ;;
        *) print_error "Unknown option '$1'"; exit 1 ;;
    esac
done

case "$TIER" in dev|stg|live) ;; *) print_error "REFUSED: tier '$TIER'"; exit 1 ;; esac

CONTRACT="$(demo_pair_contract_for "$SITE")" || {
    print_error "REFUSED: no pair contract naming '$SITE' under $PROJECT_ROOT/pairs/"
    exit 1
}

# The demo-tier guard. A consent GRANT is a legal act on a real pair; here it is
# a fixture. Keying off the contract's declared demo flag (not the site name)
# keeps this correct if the demo pair is ever renamed — the NWP-ADR-0036 rule.
if [[ "$(demo_pair_get "$CONTRACT" '.demo.enabled' 'false')" != "true" ]]; then
    print_error "REFUSED: $CONTRACT does not declare demo.enabled: true."
    print_error "Seeding Art.9 consent is a DEMO-tier fixture. On a real pair,"
    print_error "consent is given by a member on the Drupal half — never seeded."
    exit 1
fi

CLI_PHP="${CLI_PHP:-$(demo_pair_get "$CONTRACT" '.oidc.cli_php_version' '8.3')}"

args="--check"
[[ "$MODE" == "apply" ]] && args="--apply"

set +e
demo_moodle_php_run "$SITE" "$TIER" "$SCRIPT_DIR/ssd-consent-arc.php" "$CLI_PHP" -- "$args"
rc=$?
set -e

case "$rc" in
    0) print_status "OK"   "$SITE ($TIER) Art.9 consent arc complete" ;;
    2) print_status "FAIL" "$SITE ($TIER) consent arc CANNOT-VERIFY (exit 2) — not a pass" ;;
    *) print_status "FAIL" "$SITE ($TIER) Art.9 consent arc INCOMPLETE (exit $rc)" ;;
esac
exit "$rc"
