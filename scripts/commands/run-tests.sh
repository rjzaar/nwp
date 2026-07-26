#!/bin/bash
set -euo pipefail

################################################################################
# NWP Comprehensive Test Runner
#
# Runs all levels of tests: unit (BATS), integration (BATS), and E2E
#
# Usage: ./run-tests.sh [OPTIONS]
################################################################################

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

# Source shared libraries
source "$PROJECT_ROOT/lib/ui.sh"

# Script start time
START_TIME=$(date +%s)

################################################################################
# Configuration
################################################################################

RUN_UNIT=false
RUN_INTEGRATION=false
RUN_E2E=false
RUN_ALL=true
VERBOSE=false
CI_MODE=false
BAIL_ON_FAIL=false

################################################################################
# Help
################################################################################

show_help() {
    cat << EOF
${BOLD}NWP Comprehensive Test Runner${NC}

${BOLD}USAGE:${NC}
    ./run-tests.sh [OPTIONS]

${BOLD}OPTIONS:${NC}
    -h, --help              Show this help message
    -u, --unit              Run unit tests only (BATS)
    -i, --integration       Run integration tests only (BATS)
    -e, --e2e               Run E2E tests only (requires Linode)
    -a, --all               Run all tests (default)
    -v, --verbose           Show verbose output
    --ci                    CI mode (stricter, JUnit output)
    --bail                  Stop on first failure
    -d, --debug             Enable debug output

${BOLD}EXAMPLES:${NC}
    ./run-tests.sh                    # Run all tests
    ./run-tests.sh -u                 # Unit tests only
    ./run-tests.sh -i                 # Integration tests only
    ./run-tests.sh -ui                # Unit and integration tests
    ./run-tests.sh --ci               # CI mode with all tests

${BOLD}TEST CATEGORIES:${NC}
    Unit Tests         - BATS tests for lib/*.sh functions
                        Fast (~1-2 minutes)
                        tests/unit/*.bats

    Integration Tests  - BATS tests for full workflows
                        Medium (~5-10 minutes with DDEV)
                        tests/integration/*.bats

    E2E Tests          - End-to-end tests on Linode
                        Slow (~30-60 minutes)
                        tests/e2e/*.sh (future)

${BOLD}REQUIREMENTS:${NC}
    Unit Tests:        BATS installed
    Integration Tests: BATS + DDEV running
    E2E Tests:         Linode API access

${BOLD}WHAT "PASSED" MEANS:${NC}
    A suite that executed ZERO tests has FAILED, not passed. Missing bats, an
    empty target or an unwired harness reports "SKIPPED SUITE — 0 tests did not
    run" and exits non-zero.

    bats reports a \`skip\` as \`ok\`, so the number of tests allowed to skip is
    declared in ${CYAN}tests/.skip-budget${NC} and enforced. Exceed it and the run fails;
    drop below it and you are told to lower the number in the same commit.
    Override for one run with NWP_SKIP_BUDGET_UNIT / _INTEGRATION / _E2E.

    Both suites run through scripts/ci/run-bats.sh — the same runner CI uses —
    so \`pl test\` and the pipeline cannot disagree about what was verified.

EOF
}

################################################################################
# Suite honesty
#
# Every runner below returns one of THREE states, not two:
#   0 — the suite ran and passed
#   1 — the suite ran and failed
#   2 — the suite DID NOT RUN (missing tool, empty target, not implemented)
#
# State 2 exists because it used to be reported as state 0. `run_e2e_tests`
# ended in a bare `return 0`, so `pl test --e2e` printed
#     Test suites run: 1 / Test suites passed: 1 / All test suites passed
# in 00:00:00 having executed nothing. main() below counts 2 as a failure and
# refuses to print "All test suites passed" for it.
#
# The bats suites delegate to scripts/ci/run-bats.sh — the SAME runner CI uses —
# so the verb a human types and the job that gates the MR cannot disagree about
# what "passed" means. run-bats.sh asserts a non-empty JUnit report, a non-zero
# <testcase> count, and an exact skip budget (bats reports a skip as `ok`).
################################################################################

# Per-suite skip-budget override, e.g. NWP_SKIP_BUDGET_INTEGRATION=0.
# When unset, run-bats.sh resolves the budget from tests/.skip-budget itself —
# it is the single reader, so `pl test` and CI cannot drift.
skip_budget_override() {
    local env_name
    env_name="NWP_SKIP_BUDGET_$(echo "$1" | tr '[:lower:]' '[:upper:]')"
    printf '%s' "${!env_name:-}"
}

# Run one bats suite through the CI runner.
run_bats_suite() {
    local suite="$1" test_dir="$2"
    local runner="$PROJECT_ROOT/scripts/ci/run-bats.sh"

    if ! command -v bats &>/dev/null; then
        print_error "BATS is not installed. Install with: apt-get install bats"
        print_info "The suite DID NOT RUN — 0 tests. That is a failure, not a pass."
        return 2
    fi
    if [ ! -d "$test_dir" ]; then
        print_error "Test directory not found: $test_dir"
        return 2
    fi
    if [ ! -x "$runner" ]; then
        print_error "Missing $runner — refusing to fall back to a bare 'bats' call,"
        print_error "which cannot tell a zero-test run from a passing one."
        return 2
    fi

    local budget out_dir result=0
    budget="$(skip_budget_override "$suite")"
    out_dir="${NWP_JUNIT_DIR:-$PROJECT_ROOT/.logs/junit}/$suite"

    local extra=""
    [ "$VERBOSE" = "true" ] && extra="--verbose-run"

    NWP_BATS_SUITE="$suite" NWP_BATS_MAX_SKIPPED="$budget" NWP_BATS_EXTRA_ARGS="$extra" \
        "$runner" "$out_dir" "$test_dir" || result=$?

    case $result in
        0) print_status "OK"   "${suite^} tests passed" ;;
        2) print_status "FAIL" "${suite^} tests DID NOT RUN — nothing was verified" ;;
        *) print_status "FAIL" "${suite^} tests failed" ;;
    esac
    return $result
}

################################################################################
# Test Runners
################################################################################

# Run BATS unit tests
run_unit_tests() {
    print_header "Running Unit Tests (BATS)"
    run_bats_suite unit "$PROJECT_ROOT/tests/unit"
}

# Run BATS integration tests
run_integration_tests() {
    print_header "Running Integration Tests (BATS)"

    # Not a warning any more: the lifecycle half of this suite skips without
    # ddev, and the skip budget in tests/.skip-budget is what decides whether
    # that shortfall is acceptable on this machine.
    if ! command -v ddev &>/dev/null; then
        print_warning "DDEV not available — the lifecycle tests will skip."
        print_info "They count against the declared skip budget, not as passes."
    fi

    run_bats_suite integration "$PROJECT_ROOT/tests/integration"
}

# Run E2E tests.
#
# tests/e2e/ holds standalone shell scripts (test-fresh-install.sh,
# test-basic-workflow.sh) that provision real Linodes. They are not wired to a
# harness, so this runner has never executed one. It used to say so and then
# `return 0`, which main() counted as a passing suite. It now returns 2 — DID
# NOT RUN — so `pl test --e2e` cannot report success over an empty run.
run_e2e_tests() {
    print_header "Running E2E Tests (Linode)"

    local test_dir="$PROJECT_ROOT/tests/e2e"
    if [ ! -d "$test_dir" ]; then
        print_error "E2E test directory not found: $test_dir"
        return 2
    fi

    if [ ! -f "$PROJECT_ROOT/.secrets.yml" ]; then
        print_error "No .secrets.yml — E2E tests need Linode API access."
        print_info  "0 tests ran. Reporting DID NOT RUN, not success."
        return 2
    fi

    print_error "E2E tests are not wired to a harness — 0 tests ran."
    print_info  "tests/e2e/ holds standalone scripts (see tests/e2e/README.md)."
    print_info  "Until one is invoked from here, --e2e cannot report a pass."
    return 2
}

################################################################################
# Main Script
################################################################################

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -u|--unit)
                RUN_UNIT=true
                RUN_ALL=false
                shift
                ;;
            -i|--integration)
                RUN_INTEGRATION=true
                RUN_ALL=false
                shift
                ;;
            -e|--e2e)
                RUN_E2E=true
                RUN_ALL=false
                shift
                ;;
            -a|--all)
                RUN_ALL=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            --ci)
                CI_MODE=true
                shift
                ;;
            --bail)
                BAIL_ON_FAIL=true
                shift
                ;;
            -d|--debug)
                set -x
                shift
                ;;
            *)
                echo "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done

    # If no specific tests selected, run all
    if [ "$RUN_ALL" = "true" ]; then
        RUN_UNIT=true
        RUN_INTEGRATION=true
        RUN_E2E=false  # E2E tests are opt-in only
    fi

    print_header "NWP Comprehensive Test Suite"

    # Track results.
    #
    # TESTS_SELECTED counts suites we were asked to run; TESTS_EXECUTED counts
    # suites that actually executed tests. They used to be the same variable,
    # which is how a suite that ran nothing landed in the "passed" column.
    local TESTS_SELECTED=0
    local TESTS_EXECUTED=0
    local TESTS_PASSED=0
    local TESTS_FAILED=0
    local FAILED_SUITES=()
    local NOTRUN_SUITES=()

    # Dispatch one suite and file its outcome in the right column.
    run_suite() {
        local name="$1" fn="$2" rc=0
        TESTS_SELECTED=$((TESTS_SELECTED + 1))
        "$fn" || rc=$?
        case $rc in
            0)
                TESTS_EXECUTED=$((TESTS_EXECUTED + 1))
                TESTS_PASSED=$((TESTS_PASSED + 1))
                ;;
            2)
                # DID NOT RUN — never a pass. Not counted as executed either,
                # so the summary cannot imply coverage it does not have.
                TESTS_FAILED=$((TESTS_FAILED + 1))
                NOTRUN_SUITES+=("$name")
                ;;
            *)
                TESTS_EXECUTED=$((TESTS_EXECUTED + 1))
                TESTS_FAILED=$((TESTS_FAILED + 1))
                FAILED_SUITES+=("$name")
                ;;
        esac
        if [ $rc -ne 0 ] && [ "$BAIL_ON_FAIL" = "true" ]; then
            print_error "Stopping due to failure (--bail)"
            exit 1
        fi
        echo ""
    }

    [ "$RUN_UNIT" = "true" ]        && run_suite unit        run_unit_tests
    [ "$RUN_INTEGRATION" = "true" ] && run_suite integration run_integration_tests
    [ "$RUN_E2E" = "true" ]         && run_suite e2e         run_e2e_tests

    # Summary
    print_header "Test Summary"
    echo "Test suites selected: $TESTS_SELECTED"
    echo "Test suites executed: $TESTS_EXECUTED"
    echo "Test suites passed:   ${GREEN}$TESTS_PASSED${NC}"

    if [ ${#FAILED_SUITES[@]} -gt 0 ]; then
        echo "Test suites failed:   ${RED}${#FAILED_SUITES[@]}${NC}"
        print_error "Failed test suites: ${FAILED_SUITES[*]}"
    fi
    if [ ${#NOTRUN_SUITES[@]} -gt 0 ]; then
        echo "Test suites NOT RUN:  ${RED}${#NOTRUN_SUITES[@]}${NC}"
        print_error "SKIPPED SUITE — 0 tests did not run: ${NOTRUN_SUITES[*]}"
        print_info  "A suite that executes nothing verifies nothing. Fix the"
        print_info  "runner (install the tool / wire the harness) or stop"
        print_info  "selecting the suite — do not read this as a pass."
    fi

    show_elapsed_time "Testing"

    if [ $TESTS_FAILED -gt 0 ]; then
        exit 1
    fi

    # Belt and braces: even with no explicit failure, selecting suites and
    # executing none of them is not success.
    if [ $TESTS_SELECTED -gt 0 ] && [ $TESTS_EXECUTED -eq 0 ]; then
        print_error "0 of $TESTS_SELECTED selected suites executed — nothing was verified."
        exit 1
    fi

    print_status "OK" "All test suites passed"
    exit 0
}

# Run main
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
