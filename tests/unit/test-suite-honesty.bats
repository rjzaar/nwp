#!/usr/bin/env bats
#
# test-suite-honesty.bats — a test suite that runs nothing has FAILED.
#
# WHY THIS FILE EXISTS
#   `pl test` is the developer-facing gate. Until 2026-07-26 it could report
#
#       Test suites run:    1
#       Test suites passed: 1
#       [✓] All test suites passed
#
#   in 00:00:00 having executed ZERO tests, because run_e2e_tests() ends in a
#   bare `return 0` and main() increments TESTS_PASSED on any zero exit. The
#   same shape hides in the bats runners: bats reports a `skip` as `ok`, so an
#   under-provisioned machine (no ddev, no php) turns 14 real assertions into
#   14 green ticks and exits 0.
#
#   CI already refuses both shapes — scripts/ci/run-bats.sh asserts a non-empty
#   JUnit report, a non-zero <testcase> count and an exact skip budget. But the
#   verb a human types did not, so `pl test` and CI disagreed about what
#   "passed" means. These tests pin the contract on the VERB.
#
# CONTRACT
#   1. a suite that executed 0 tests is a FAILURE, never a pass;
#   2. a suite whose only green comes from skips is a FAILURE;
#   3. `pl test` routes its bats suites through the same runner as CI, so the
#      two cannot drift;
#   4. the integration skip budget is declared in-tree and is shrink-only.

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    RUNNER="$REPO_ROOT/scripts/commands/run-tests.sh"
    RUN_BATS="$REPO_ROOT/scripts/ci/run-bats.sh"
    BUDGET_FILE="$REPO_ROOT/tests/.skip-budget"
}

################################################################################
# 1. The vacuous pass that started this
################################################################################

@test "pl test --e2e must not report success when zero e2e tests ran" {
    run env NWP_TEST_NO_COLOR=1 "$RUNNER" --e2e
    # The e2e directory holds shell scripts that are not wired to a harness.
    # Whatever the runner decides to do about that, "All test suites passed"
    # with nothing executed is the one answer that is not allowed.
    if [ "$status" -eq 0 ]; then
        echo "--- runner output ---" >&2
        echo "$output" >&2
        echo "---" >&2
        echo "pl test --e2e exited 0 having executed no tests." >&2
        return 1
    fi
    [[ "$output" == *"0 tests"* || "$output" == *"did not run"* || "$output" == *"NOT RUN"* ]]
}

@test "a suite that executes zero tests is counted as failed, not passed" {
    # Drive the summary logic directly: a runner reporting 'ran nothing' must
    # land in the FAILED column.
    run env NWP_TEST_NO_COLOR=1 "$RUNNER" --e2e
    [ "$status" -ne 0 ]
    [[ "$output" != *"All test suites passed"* ]]
}

################################################################################
# 2. Skips are not passes
################################################################################

@test "the integration skip budget is declared in-tree" {
    [ -f "$BUDGET_FILE" ] || {
        echo "No $BUDGET_FILE — the number of tests allowed to skip is undeclared," >&2
        echo "so a suite can quietly stop testing anything and still exit 0." >&2
        return 1
    }
    grep -qE '^integration=[0-9]+' "$BUDGET_FILE"
}

@test "pl test --integration fails when more tests skip than the declared budget" {
    command -v bats >/dev/null 2>&1 || skip "bats not installed"
    # Budget of -1 can never be met by a real run; the runner must notice.
    run env NWP_TEST_NO_COLOR=1 NWP_SKIP_BUDGET_INTEGRATION=0 "$RUNNER" --integration
    if [ "$status" -eq 0 ]; then
        echo "$output" >&2
        echo "The integration suite skips 14 tests on a machine without ddev." >&2
        echo "With a budget of 0 the runner still exited 0 — skips read as passes." >&2
        return 1
    fi
    [[ "$output" == *"skip"* || "$output" == *"SKIP"* ]]
}

################################################################################
# 3. One implementation, so pl test and CI cannot disagree
################################################################################

@test "run-tests.sh delegates its bats suites to scripts/ci/run-bats.sh" {
    grep -q 'run-bats.sh' "$RUNNER" || {
        echo "run-tests.sh calls bats directly. CI calls scripts/ci/run-bats.sh," >&2
        echo "which asserts a non-empty report, >0 testcases and a skip budget." >&2
        echo "Two implementations of 'did the suite run' will drift; they already" >&2
        echo "did — CI refused a zero-testcase run while pl test celebrated one." >&2
        return 1
    }
}

@test "run-bats.sh still refuses a target that matches no test files" {
    command -v bats >/dev/null 2>&1 || skip "bats not installed"
    out="$BATS_TEST_TMPDIR/empty-out"
    mkdir -p "$BATS_TEST_TMPDIR/empty-suite"
    run "$RUN_BATS" "$out" "$BATS_TEST_TMPDIR/empty-suite"
    [ "$status" -ne 0 ]
}
