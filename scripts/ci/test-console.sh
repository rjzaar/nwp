#!/usr/bin/env bash
#
# test-console.sh — run the console pytest suite, with a collection-error
# preflight so "0 tests ran" can never look like success.
#
# WHY THIS FILE EXISTS
#   scripts/console/tests/ holds 500+ assertions across 10 modules, including
#   test_authz.py and test_notify.py — the runtime half of the Gotify `security`
#   detector that has never fired in production. As of 2026-07-26 they ran in no
#   CI job and behind no `pl` verb, and pytest was not in requirements.txt.
#   A borrowed venv gave "158 passed, 23 errors" — and 23 collection errors mean
#   23 modules' worth of assertions silently did not run. That is the
#   "ALL 13 passed / 18 skipped" shape this repo keeps getting bitten by.
#
# CONTRACT
#   1. Collection runs FIRST. The number of collection errors is compared with
#      scripts/ci/.console-collect-baseline. More errors than the baseline →
#      exit 1, even though the job itself is allow_failure for now. Fewer →
#      exit 1 too (shrink-only: update the baseline in the same MR).
#   2. Zero collected tests → exit 2 ("cannot verify"), never a pass.
#   3. Then the suite runs; failures propagate.
#
# The fix for the 23 collection errors themselves belongs to the console
# agents — this script does NOT touch scripts/console/** source.
#
# EXIT
#   0 — collection matches baseline and the suite passed
#   1 — collection-error count drifted, or tests failed
#   2 — cannot verify (no pytest, zero tests collected)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BASELINE_FILE="${NWP_CONSOLE_COLLECT_BASELINE:-$SCRIPT_DIR/.console-collect-baseline}"
PYTEST="${PYTEST:-pytest}"
TESTS_DIR="${1:-$PROJECT_ROOT/scripts/console/tests}"

command -v "$PYTEST" >/dev/null 2>&1 || {
    echo "ERROR: '$PYTEST' not found. Install with:" >&2
    echo "  pip install -r scripts/console/requirements.txt -r scripts/console/requirements-dev.txt" >&2
    exit 2
}
[ -d "$TESTS_DIR" ] || { echo "ERROR: no tests dir at $TESTS_DIR" >&2; exit 2; }

_baseline_key() {
    local k="$1" v=""
    [ -f "$BASELINE_FILE" ] && v="$(grep -E "^[[:space:]]*${k}[[:space:]]*=" "$BASELINE_FILE" | head -1 | cut -d= -f2 | tr -dc '0-9')"
    printf '%s' "${v:-0}"
}
baseline="$(_baseline_key collection_errors)"
skip_baseline="$(_baseline_key skipped)"

echo "=== Collection preflight (baseline: ${baseline} error(s)) ==="
collect_out="$("$PYTEST" --collect-only -q "$TESTS_DIR" 2>&1)"
echo "$collect_out" | tail -25

# pytest -q summary line looks like: "158 tests collected, 23 errors in 1.2s"
errors="$(printf '%s\n' "$collect_out" | grep -oE '[0-9]+ error' | tail -1 | grep -oE '[0-9]+' || true)"
errors="${errors:-0}"
collected="$(printf '%s\n' "$collect_out" | grep -oE '[0-9]+ tests? collected' | tail -1 | grep -oE '[0-9]+' || true)"
collected="${collected:-0}"

echo ""
echo "collected=${collected} collection_errors=${errors} baseline=${baseline}"

if [ "$collected" -eq 0 ]; then
    echo "ERROR: pytest collected 0 tests — cannot verify anything. Failing." >&2
    exit 2
fi
if [ "$errors" -gt "$baseline" ]; then
    echo "ERROR: collection errors went UP (${baseline} → ${errors})." >&2
    echo "       New modules are silently not running. Fix, or justify in the MR." >&2
    exit 1
fi
if [ "$errors" -lt "$baseline" ]; then
    echo "ERROR: collection errors went DOWN (${baseline} → ${errors}) — good!" >&2
    echo "       The baseline is shrink-only: set $BASELINE_FILE to ${errors} in this MR." >&2
    exit 1
fi

echo ""
echo "=== Running console suite ==="
run_out="$("$PYTEST" -q -rs "$TESTS_DIR" 2>&1)"
rc=$?
printf '%s\n' "$run_out"

# A skip reports as a pass. Baseline the skip count so a suite that quietly
# stops running cases goes red — this is the "ALL 13 passed / 18 skipped" shape.
skipped="$(printf '%s\n' "$run_out" | grep -oE '[0-9]+ skipped' | tail -1 | grep -oE '[0-9]+' || true)"
skipped="${skipped:-0}"
echo ""
echo "skipped=${skipped} skip_baseline=${skip_baseline}"
if [ "$skipped" -ne "$skip_baseline" ]; then
    echo "ERROR: skipped-test count drifted (${skip_baseline} → ${skipped})." >&2
    echo "       A skip reports as a pass. Either restore the missing dependency," >&2
    echo "       or update 'skipped=' in $BASELINE_FILE in this MR, with a reason." >&2
    exit 1
fi
exit "$rc"
