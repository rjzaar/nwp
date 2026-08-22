#!/bin/bash
set -euo pipefail
################################################################################
# scripts/demo/nwd-consent-claim.sh — prove the ops#118 `art9_consent` claim
# actually rides in a TOKEN from the nwd (Drupal) half of the demo pair.
# nwp/ops#279, operator GO 2026-08-07 item 2.
#
#   scripts/demo/nwd-consent-claim.sh [--site=nwd] [--tier=live]
#
# READ-ONLY in effect: it mints a 2-minute access token for a synthetic
# @demo.invalid account, calls /oauth/userinfo with it, revokes it, and prints
# only the decoded claim set. No token value is ever printed or stored.
#
# The issuer base URL comes from the PAIR CONTRACT (endpoints.<tier>.issuer),
# never hardcoded — under drush CLI the site has no request host, so a probe
# that trusted \Drupal::request() would silently test `http://default`.
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
PROJECT_ROOT="${PROJECT_ROOT:-$REPO_ROOT}"
# The nested `pl drush` must resolve sites/ from the SAME root this script did,
# or it looks for the live host in a tree that has no site config.
export PROJECT_ROOT

source "$REPO_ROOT/lib/ui.sh"
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/demo-pair.sh"

SITE="nwd"; TIER="live"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --site=*) SITE="${1#--site=}"; shift ;;
        --tier=*) TIER="${1#--tier=}"; shift ;;
        *) print_error "Unknown option '$1'"; exit 1 ;;
    esac
done

case "$TIER" in dev|stg|live) ;; *) print_error "REFUSED: tier '$TIER'"; exit 1 ;; esac

CONTRACT="$(demo_pair_contract_for "$SITE")" || {
    print_error "REFUSED: no pair contract naming '$SITE' under $PROJECT_ROOT/pairs/"
    exit 1
}

# Demo-tier only. Minting a token for a member account on a real pair is not a
# probe, it is impersonation. Keyed off the contract's declared demo flag, not
# the site name (NWP-ADR-0036).
if [[ "$(demo_pair_get "$CONTRACT" '.demo.enabled' 'false')" != "true" ]]; then
    print_error "REFUSED: $CONTRACT does not declare demo.enabled: true."
    print_error "This probe mints an access token for an account. That is a DEMO-tier"
    print_error "act against synthetic @demo.invalid users only."
    exit 1
fi

ISSUER="$(demo_pair_issuer "$CONTRACT" "$TIER")" || {
    print_error "REFUSED: no endpoints.${TIER}.issuer in $CONTRACT — nothing to probe."
    exit 1
}

print_info "Issuer (from $CONTRACT): $ISSUER"

# WHY THE VERDICT IS PARSED AND NOT READ FROM $?
#
# `drush php:script` reports ANY exit() the script makes — exit(0) included — as
# "Drush command terminated abnormally" and returns 1 itself. Trusting $? here
# would report every successful probe as a failure, and a check whose green is
# indistinguishable from its red is not a check. So the probe prints its verdict
# as its last line and this reads that.
#
# Fail-closed: no verdict line at all means the script died before reaching its
# own conclusion. That is CANNOT-VERIFY, never a pass.
OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT

set +e
"$REPO_ROOT/pl" drush "$SITE" --tier="$TIER" --execute \
    --script="$SCRIPT_DIR/nwd-consent-claim.php" -- "--base-url=$ISSUER" 2>&1 | tee "$OUT"
set -e

VERDICT="$(grep -E '^result: ' "$OUT" | tail -1 || true)"

case "$VERDICT" in
    "result: OK"*)             print_status "OK"   "$SITE ($TIER) emits art9_consent in a real token"; exit 0 ;;
    "result: CANNOT-VERIFY"*)  print_status "FAIL" "$SITE ($TIER) claim probe CANNOT-VERIFY — not a pass"; exit 2 ;;
    "result: FAILED"*)         print_status "FAIL" "$SITE ($TIER) claim probe FAILED"; exit 1 ;;
    *)                         print_status "FAIL" "$SITE ($TIER) claim probe produced NO verdict — treating as CANNOT-VERIFY"; exit 2 ;;
esac
