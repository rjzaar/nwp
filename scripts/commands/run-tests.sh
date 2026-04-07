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

EOF
}

################################################################################
# Test Runners
################################################################################

# Run BATS unit tests
run_unit_tests() {
    print_header "Running Unit Tests (BATS)"

    if ! command -v bats &>/dev/null; then
        print_error "BATS is not installed. Install with: apt-get install bats"
        return 1
    fi

    local test_dir="$PROJECT_ROOT/tests/unit"
    if [ ! -d "$test_dir" ]; then
        print_error "Unit test directory not found: $test_dir"
        return 1
    fi

    local bats_args=""
    if [ "$VERBOSE" = "true" ]; then
        bats_args="--verbose-run"
    fi

    if [ "$CI_MODE" = "true" ]; then
        # CI mode - use TAP format for better parsing
        bats_args="$bats_args --formatter tap"
    fi

    local result=0
    bats $bats_args "$test_dir" || result=$?

    if [ $result -eq 0 ]; then
        print_status "OK" "Unit tests passed"
        return 0
    else
        print_status "FAIL" "Unit tests failed"
        return 1
    fi
}

# Run BATS integration tests
run_integration_tests() {
    print_header "Running Integration Tests (BATS)"

    if ! command -v bats &>/dev/null; then
        print_error "BATS is not installed"
        return 1
    fi

    # Check if DDEV is available (for full integration tests)
    if ! command -v ddev &>/dev/null; then
        print_warning "DDEV not available - some integration tests will be skipped"
    fi

    local test_dir="$PROJECT_ROOT/tests/integration"
    if [ ! -d "$test_dir" ]; then
        print_error "Integration test directory not found: $test_dir"
        return 1
    fi

    local bats_args=""
    if [ "$VERBOSE" = "true" ]; then
        bats_args="--verbose-run"
    fi

    if [ "$CI_MODE" = "true" ]; then
        bats_args="$bats_args --formatter tap"
    fi

    local result=0
    bats $bats_args "$test_dir" || result=$?

    if [ $result -eq 0 ]; then
        print_status "OK" "Integration tests passed"
        return 0
    else
        print_status "FAIL" "Integration tests failed"
        return 1
    fi
}

# Run E2E tests (placeholder for future Linode-based tests)
run_e2e_tests() {
    print_header "Running E2E Tests (Linode)"

    local test_dir="$PROJECT_ROOT/tests/e2e"
    if [ ! -d "$test_dir" ]; then
        print_error "E2E test directory not found: $test_dir"
        return 1
    fi

    # Check for Linode API access
    if [ ! -f "$PROJECT_ROOT/.secrets.yml" ]; then
        print_warning "No .secrets.yml found - E2E tests require Linode API access"
        print_info "E2E tests are skipped for now"
        return 0
    fi

    print_info "E2E tests are not yet implemented"
    print_info "See tests/e2e/README.md for planned implementation"

    return 0
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

    # Track results
    local TESTS_RUN=0
    local TESTS_PASSED=0
    local TESTS_FAILED=0
    local FAILED_SUITES=()

    # Run unit tests
    if [ "$RUN_UNIT" = "true" ]; then
        TESTS_RUN=$((TESTS_RUN + 1))
        if run_unit_tests; then
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            TESTS_FAILED=$((TESTS_FAILED + 1))
            FAILED_SUITES+=("unit")
            if [ "$BAIL_ON_FAIL" = "true" ]; then
                print_error "Stopping due to failure (--bail)"
                exit 1
            fi
        fi
        echo ""
    fi

    # Run integration tests
    if [ "$RUN_INTEGRATION" = "true" ]; then
        TESTS_RUN=$((TESTS_RUN + 1))
        if run_integration_tests; then
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            TESTS_FAILED=$((TESTS_FAILED + 1))
            FAILED_SUITES+=("integration")
            if [ "$BAIL_ON_FAIL" = "true" ]; then
                print_error "Stopping due to failure (--bail)"
                exit 1
            fi
        fi
        echo ""
    fi

    # Run E2E tests
    if [ "$RUN_E2E" = "true" ]; then
        TESTS_RUN=$((TESTS_RUN + 1))
        if run_e2e_tests; then
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            TESTS_FAILED=$((TESTS_FAILED + 1))
            FAILED_SUITES+=("e2e")
            if [ "$BAIL_ON_FAIL" = "true" ]; then
                print_error "Stopping due to failure (--bail)"
                exit 1
            fi
        fi
        echo ""
    fi

    # Summary
    print_header "Test Summary"
    echo "Test suites run:    $TESTS_RUN"
    echo "Test suites passed: ${GREEN}$TESTS_PASSED${NC}"

    if [ $TESTS_FAILED -gt 0 ]; then
        echo "Test suites failed: ${RED}$TESTS_FAILED${NC}"
        echo ""
        print_error "Failed test suites: ${FAILED_SUITES[*]}"
    fi

    show_elapsed_time "Testing"

    if [ $TESTS_FAILED -gt 0 ]; then
        exit 1
    else
        print_status "OK" "All test suites passed"
        exit 0
    fi
}

# Run main
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
