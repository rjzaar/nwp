#!/usr/bin/env bash
#
# run-bats.sh — run a bats suite so that "it didn't actually run" is a failure.
#
# WHY THIS FILE EXISTS
#   Three independent ways the bats jobs could report green without testing:
#
#   1. NO JUNIT.  `test:unit` / `test:integration` declared
#        artifacts: reports: junit: tests/unit/results.xml
#      but bats was invoked as plain `bats tests/unit/`, which never writes a
#      report. GitLab *warns* on a missing junit artifact and passes the job, so
#      the MR "Tests" panel has been permanently empty across ~1085 cases — the
#      one place a reviewer would notice a silently-skipped case.
#      (The correct incantation is `--report-formatter junit --output <dir>`,
#      which writes <dir>/report.xml. `--formatter junit` writes to stdout and
#      no file at all — an easy and invisible mistake.)
#
#   2. MISSING INTERPRETER.  tests/unit/test-auth-logic.bats skipped the SSO
#      uid-lock and the ops#81 erasure-guard tests when `php` was absent. bats
#      reports a skip as `ok`. The current runner has php; the registered
#      fallback runner does not — so a runner migration would silently drop both
#      without a single red line. An under-provisioned runner must report
#      "cannot verify", not green.
#
#   3. EMPTY GLOB.  A path typo makes bats run zero files and exit 0.
#
# CONTRACT
#   * preflight: every tool in REQUIRED_TOOLS must exist, else exit 2;
#   * the junit report must exist and contain at least one <testcase>;
#   * the skipped count must equal NWP_BATS_MAX_SKIPPED (default 0) exactly —
#     a skip reports as a pass, so its count is part of the contract.
#
# USAGE
#   scripts/ci/run-bats.sh <output-dir> <bats-target> [<bats-target>...]
#
# EXIT
#   0 — suite passed, report written, skip count as expected
#   1 — test failures, or skip-count drift
#   2 — cannot verify (missing tool, no report, zero testcases)

set -uo pipefail

OUT_DIR="${1:-}"
shift || true
TARGETS=("$@")

if [ -z "$OUT_DIR" ] || [ "${#TARGETS[@]}" -eq 0 ]; then
    echo "usage: $0 <output-dir> <bats-target>..." >&2
    exit 2
fi

REQUIRED_TOOLS_DEFAULT="bats git"
read -r -a required <<< "${NWP_BATS_REQUIRED_TOOLS:-$REQUIRED_TOOLS_DEFAULT}"

# Skip budget resolution — ONE source of truth for CI and for `pl test`.
#
#   NWP_BATS_MAX_SKIPPED  explicit, wins (a deliberately reduced runner)
#   NWP_BATS_SUITE        names a key in tests/.skip-budget
#   otherwise             0
#
# The budget used to be a literal in .gitlab-ci.yml while `pl test` had none at
# all, so the two disagreed about how much silence was acceptable. Declaring it
# in-tree makes it reviewable and shrink-only.
_repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUDGET_FILE="${NWP_SKIP_BUDGET_FILE:-$_repo_root/tests/.skip-budget}"
MAX_SKIPPED="${NWP_BATS_MAX_SKIPPED:-}"
if [ -z "$MAX_SKIPPED" ] && [ -n "${NWP_BATS_SUITE:-}" ] && [ -f "$BUDGET_FILE" ]; then
    MAX_SKIPPED=$(grep -E "^${NWP_BATS_SUITE}=[0-9]+" "$BUDGET_FILE" 2>/dev/null \
                  | head -1 | cut -d= -f2)
    [ -n "$MAX_SKIPPED" ] && echo "skip budget '${NWP_BATS_SUITE}'=$MAX_SKIPPED (from $BUDGET_FILE)"
fi
MAX_SKIPPED="${MAX_SKIPPED:-0}"
# The budget governs THE SUITE THIS INVOCATION RUNS — not suites that those
# tests themselves invoke. tests/unit/test-ci-lint-commands.bats runs this very
# script in a subprocess to prove a stray skip goes red; if the outer budget
# leaked in through the environment those meta-tests would assert against the
# CI job's number instead of the default and fail spuriously. Resolve first,
# then stop exporting, so every nested run starts from a clean default.
unset NWP_BATS_MAX_SKIPPED NWP_BATS_SUITE

echo "=== Preflight ==="
missing=()
for t in "${required[@]}"; do
    if command -v "$t" >/dev/null 2>&1; then
        echo "  OK   $t  ($(command -v "$t"))"
    else
        echo "  MISS $t"
        missing+=("$t")
    fi
done
if [ "${#missing[@]}" -gt 0 ]; then
    cat >&2 <<EOF

ERROR: this runner is missing: ${missing[*]}

       Refusing to run the suite. Tests that need a missing interpreter SKIP,
       and bats reports a skip as 'ok' — so running anyway would produce a
       green pipeline that verified less than it claims.

       Install the tool on the runner, or set NWP_BATS_REQUIRED_TOOLS to the
       reduced set deliberately (and expect NWP_BATS_MAX_SKIPPED to move).
EOF
    exit 2
fi

mkdir -p "$OUT_DIR"
report="$OUT_DIR/report.xml"
rm -f "$report"

echo ""
echo "=== Running bats: ${TARGETS[*]} ==="
# NWP_BATS_EXTRA_ARGS lets the interactive caller (pl test -v) add --verbose-run
# without a second bats invocation existing anywhere. The report flags are not
# negotiable: they are what makes "the suite did not run" detectable.
read -r -a extra_args <<< "${NWP_BATS_EXTRA_ARGS:-}"
bats "${extra_args[@]}" --report-formatter junit --output "$OUT_DIR" "${TARGETS[@]}"
rc=$?

echo ""
echo "=== Report assertions ==="
if [ ! -s "$report" ]; then
    echo "ERROR: no JUnit report at $report — the suite cannot be shown to have run." >&2
    exit 2
fi
# NOTE: `grep -c` already prints 0 when it matches nothing (and exits 1); an
# `|| echo 0` fallback would append a SECOND "0" and break the arithmetic below.
cases=$(grep -c '<testcase' "$report" 2>/dev/null); cases=${cases:-0}
skips=$(grep -c '<skipped' "$report" 2>/dev/null); skips=${skips:-0}
fails=$(grep -c '<failure' "$report" 2>/dev/null); fails=${fails:-0}
echo "  report:   $report"
echo "  testcases: $cases   failures: $fails   skipped: $skips (allowed: $MAX_SKIPPED)"

if [ "$cases" -eq 0 ]; then
    echo "ERROR: JUnit report contains 0 testcases — nothing ran." >&2
    exit 2
fi
if [ "$skips" -ne "$MAX_SKIPPED" ]; then
    echo "ERROR: skipped-test count is $skips, expected exactly $MAX_SKIPPED." >&2
    echo "       bats reports a skip as 'ok'. Either provision the missing" >&2
    echo "       dependency on the runner, or change NWP_BATS_MAX_SKIPPED" >&2
    echo "       deliberately in .gitlab-ci.yml, in the same MR, with a reason." >&2
    exit 1
fi

exit "$rc"
