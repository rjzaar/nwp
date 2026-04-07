#!/bin/bash

################################################################################
# CI/CD Test Script
#
# Runs comprehensive test suite for CI/CD pipelines including:
# - PHP CodeSniffer (Drupal coding standards)
# - PHPStan (static analysis)
# - PHPUnit (unit tests with coverage)
# - Behat (behavioral tests)
#
# Usage: scripts/ci/test.sh [options]
#
# Options:
#   --site-dir <dir>        Site directory (default: current directory)
#   --coverage-threshold    Coverage threshold percentage (default: skip check)
#   --skip-phpcs            Skip PHP CodeSniffer
#   --skip-phpstan          Skip PHPStan
#   --skip-phpunit          Skip PHPUnit
#   --skip-behat            Skip Behat
#   --stop-on-failure       Stop execution on first failure
#
# Exit codes:
#   0 - All tests passed
#   1 - One or more tests failed
#   2 - Critical error (missing dependencies, etc.)
################################################################################

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source UI library for output functions
source "$PROJECT_ROOT/lib/ui.sh"

################################################################################
# Configuration and defaults
################################################################################

SITE_DIR="${PWD}"
COVERAGE_THRESHOLD=""
SKIP_PHPCS=false
SKIP_PHPSTAN=false
SKIP_PHPUNIT=false
SKIP_BEHAT=false
STOP_ON_FAILURE=false

# Determine webroot (html or web)
WEBROOT=""
if [ -d "${SITE_DIR}/html" ]; then
    WEBROOT="${SITE_DIR}/html"
elif [ -d "${SITE_DIR}/web" ]; then
    WEBROOT="${SITE_DIR}/web"
fi

# Logs directory
LOGS_DIR="${SITE_DIR}/.logs"

# Exit codes
EXIT_CODE=0

# Test results tracking
declare -a FAILED_TESTS=()
declare -a PASSED_TESTS=()
declare -a SKIPPED_TESTS=()

################################################################################
# Helper Functions
################################################################################

# Print script usage
usage() {
    cat << EOF
Usage: $(basename "$0") [options]

CI/CD test runner for Drupal projects

Options:
  --site-dir <dir>         Site directory (default: current directory)
  --coverage-threshold N   Check coverage meets threshold (0-100)
  --skip-phpcs             Skip PHP CodeSniffer
  --skip-phpstan           Skip PHPStan
  --skip-phpunit           Skip PHPUnit
  --skip-behat             Skip Behat
  --stop-on-failure        Stop on first test failure
  -h, --help               Show this help message

Examples:
  # Run all tests in current directory
  scripts/ci/test.sh

  # Run tests with coverage threshold
  scripts/ci/test.sh --coverage-threshold 80

  # Run only static analysis
  scripts/ci/test.sh --skip-phpunit --skip-behat

  # Run tests in specific site
  scripts/ci/test.sh --site-dir /path/to/site
EOF
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --site-dir)
                SITE_DIR="$2"
                shift 2
                ;;
            --coverage-threshold)
                COVERAGE_THRESHOLD="$2"
                shift 2
                ;;
            --skip-phpcs)
                SKIP_PHPCS=true
                shift
                ;;
            --skip-phpstan)
                SKIP_PHPSTAN=true
                shift
                ;;
            --skip-phpunit)
                SKIP_PHPUNIT=true
                shift
                ;;
            --skip-behat)
                SKIP_BEHAT=true
                shift
                ;;
            --stop-on-failure)
                STOP_ON_FAILURE=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                usage
                exit 2
                ;;
        esac
    done
}

# Create logs directories
setup_logs() {
    info "Setting up log directories"

    mkdir -p "${LOGS_DIR}/phpunit"
    mkdir -p "${LOGS_DIR}/behat"
    mkdir -p "${LOGS_DIR}/coverage"
    mkdir -p "${LOGS_DIR}/phpcs"
    mkdir -p "${LOGS_DIR}/phpstan"

    pass "Log directories created in ${LOGS_DIR}"
}

# Check if a test should run
should_run_test() {
    local test_name=$1
    local skip_var="SKIP_${test_name^^}"

    if [ "${!skip_var}" = "true" ]; then
        return 1
    fi
    return 0
}

# Handle test failure
handle_failure() {
    local test_name=$1
    FAILED_TESTS+=("$test_name")
    EXIT_CODE=1

    if [ "$STOP_ON_FAILURE" = "true" ]; then
        fail "$test_name failed - stopping execution (--stop-on-failure)"
        exit 1
    fi
}

################################################################################
# Test Runners
################################################################################

# Run PHP CodeSniffer
run_phpcs() {
    if ! should_run_test "phpcs"; then
        SKIPPED_TESTS+=("phpcs")
        warn "Skipping PHP CodeSniffer (--skip-phpcs)"
        return 0
    fi

    info "Running PHP CodeSniffer"

    # Check for phpcs binary
    if [ ! -f "${SITE_DIR}/vendor/bin/phpcs" ]; then
        warn "phpcs not found in vendor/bin - skipping"
        SKIPPED_TESTS+=("phpcs")
        return 0
    fi

    # Check for custom modules
    if [ -z "$WEBROOT" ] || [ ! -d "${WEBROOT}/modules/custom" ]; then
        warn "No custom modules directory found - skipping phpcs"
        SKIPPED_TESTS+=("phpcs")
        return 0
    fi

    task "Checking custom modules with Drupal and DrupalPractice standards"

    local phpcs_output="${LOGS_DIR}/phpcs/results.txt"
    local phpcs_json="${LOGS_DIR}/phpcs/results.json"

    if "${SITE_DIR}/vendor/bin/phpcs" \
        --standard=Drupal,DrupalPractice \
        --report-full="${phpcs_output}" \
        --report-json="${phpcs_json}" \
        --colors \
        "${WEBROOT}/modules/custom" 2>&1 | tee -a "${phpcs_output}"; then
        pass "PHP CodeSniffer passed"
        PASSED_TESTS+=("phpcs")
        return 0
    else
        fail "PHP CodeSniffer found violations"
        note "See ${phpcs_output} for details"
        handle_failure "phpcs"
        return 1
    fi
}

# Run PHPStan
run_phpstan() {
    if ! should_run_test "phpstan"; then
        SKIPPED_TESTS+=("phpstan")
        warn "Skipping PHPStan (--skip-phpstan)"
        return 0
    fi

    info "Running PHPStan static analysis"

    # Check for phpstan binary
    if [ ! -f "${SITE_DIR}/vendor/bin/phpstan" ]; then
        warn "phpstan not found in vendor/bin - skipping"
        SKIPPED_TESTS+=("phpstan")
        return 0
    fi

    # Check for phpstan configuration
    local phpstan_config=""
    if [ -f "${SITE_DIR}/phpstan.neon" ]; then
        phpstan_config="${SITE_DIR}/phpstan.neon"
        task "Using phpstan.neon configuration"
    elif [ -f "${SITE_DIR}/phpstan.neon.dist" ]; then
        phpstan_config="${SITE_DIR}/phpstan.neon.dist"
        task "Using phpstan.neon.dist configuration"
    fi

    local phpstan_output="${LOGS_DIR}/phpstan/results.txt"
    local phpstan_json="${LOGS_DIR}/phpstan/results.json"

    local phpstan_cmd="${SITE_DIR}/vendor/bin/phpstan analyse --no-progress"

    if [ -n "$phpstan_config" ]; then
        phpstan_cmd+=" --configuration=${phpstan_config}"
        phpstan_cmd+=" --error-format=json > ${phpstan_json}"
    else
        # Default: analyze custom modules at level 5
        if [ -n "$WEBROOT" ] && [ -d "${WEBROOT}/modules/custom" ]; then
            task "Analyzing custom modules (level 5)"
            phpstan_cmd+=" --level=5 ${WEBROOT}/modules/custom"
            phpstan_cmd+=" --error-format=json > ${phpstan_json}"
        else
            warn "No phpstan configuration or custom modules found - skipping"
            SKIPPED_TESTS+=("phpstan")
            return 0
        fi
    fi

    if eval "$phpstan_cmd" 2>&1 | tee "${phpstan_output}"; then
        pass "PHPStan analysis passed"
        PASSED_TESTS+=("phpstan")
        return 0
    else
        fail "PHPStan found issues"
        note "See ${phpstan_output} for details"
        handle_failure "phpstan"
        return 1
    fi
}

# Run PHPUnit with coverage
run_phpunit() {
    if ! should_run_test "phpunit"; then
        SKIPPED_TESTS+=("phpunit")
        warn "Skipping PHPUnit (--skip-phpunit)"
        return 0
    fi

    info "Running PHPUnit tests with coverage"

    # Check for phpunit binary
    if [ ! -f "${SITE_DIR}/vendor/bin/phpunit" ]; then
        warn "phpunit not found in vendor/bin - skipping"
        SKIPPED_TESTS+=("phpunit")
        return 0
    fi

    # Check for phpunit configuration
    local phpunit_config=""
    if [ -f "${SITE_DIR}/phpunit.xml" ]; then
        phpunit_config="${SITE_DIR}/phpunit.xml"
    elif [ -f "${SITE_DIR}/phpunit.xml.dist" ]; then
        phpunit_config="${SITE_DIR}/phpunit.xml.dist"
    elif [ -f "${WEBROOT}/core/phpunit.xml.dist" ]; then
        phpunit_config="${WEBROOT}/core/phpunit.xml.dist"
    fi

    if [ -z "$phpunit_config" ]; then
        warn "No phpunit configuration found - skipping"
        SKIPPED_TESTS+=("phpunit")
        return 0
    fi

    task "Using configuration: ${phpunit_config}"

    local phpunit_output="${LOGS_DIR}/phpunit/results.txt"
    local junit_xml="${LOGS_DIR}/phpunit/junit.xml"
    local clover_xml="${LOGS_DIR}/coverage/clover.xml"
    local cobertura_xml="${LOGS_DIR}/coverage/cobertura.xml"
    local html_coverage="${LOGS_DIR}/coverage/html"

    # Build phpunit command with coverage
    local phpunit_cmd="${SITE_DIR}/vendor/bin/phpunit"
    phpunit_cmd+=" --configuration=${phpunit_config}"
    phpunit_cmd+=" --log-junit=${junit_xml}"
    phpunit_cmd+=" --coverage-clover=${clover_xml}"
    phpunit_cmd+=" --coverage-cobertura=${cobertura_xml}"
    phpunit_cmd+=" --coverage-html=${html_coverage}"
    phpunit_cmd+=" --colors=always"

    if eval "$phpunit_cmd" 2>&1 | tee "${phpunit_output}"; then
        pass "PHPUnit tests passed"
        PASSED_TESTS+=("phpunit")

        # Display coverage info if available
        if [ -f "$clover_xml" ]; then
            note "Coverage reports generated:"
            note "  - Clover: ${clover_xml}"
            note "  - Cobertura: ${cobertura_xml}"
            note "  - HTML: ${html_coverage}/index.html"
        fi

        return 0
    else
        fail "PHPUnit tests failed"
        note "See ${phpunit_output} for details"
        handle_failure "phpunit"
        return 1
    fi
}

# Check coverage threshold
check_coverage() {
    if [ -z "$COVERAGE_THRESHOLD" ]; then
        return 0
    fi

    info "Checking coverage threshold (${COVERAGE_THRESHOLD}%)"

    local clover_xml="${LOGS_DIR}/coverage/clover.xml"

    if [ ! -f "$clover_xml" ]; then
        warn "No coverage file found - skipping threshold check"
        return 0
    fi

    # Check if check-coverage.sh script exists
    if [ -f "${SCRIPT_DIR}/check-coverage.sh" ]; then
        task "Using check-coverage.sh script"
        if "${SCRIPT_DIR}/check-coverage.sh" "$clover_xml" "$COVERAGE_THRESHOLD"; then
            pass "Coverage threshold met (${COVERAGE_THRESHOLD}%)"
            return 0
        else
            fail "Coverage below threshold (${COVERAGE_THRESHOLD}%)"
            handle_failure "coverage-threshold"
            return 1
        fi
    else
        # Simple coverage check using XML parsing
        task "Performing basic coverage check"

        # Extract coverage percentage from clover.xml
        # This is a simplified check - ideally use a proper XML parser
        if command -v xmllint >/dev/null 2>&1; then
            local coverage_pct
            coverage_pct=$(xmllint --xpath "string(//metrics/@percent)" "$clover_xml" 2>/dev/null || echo "0")

            # Convert to integer for comparison
            coverage_pct=${coverage_pct%.*}

            if [ "$coverage_pct" -ge "$COVERAGE_THRESHOLD" ]; then
                pass "Coverage at ${coverage_pct}% (threshold: ${COVERAGE_THRESHOLD}%)"
                return 0
            else
                fail "Coverage at ${coverage_pct}% (threshold: ${COVERAGE_THRESHOLD}%)"
                handle_failure "coverage-threshold"
                return 1
            fi
        else
            warn "xmllint not available - cannot parse coverage"
            note "Install libxml2-utils or create scripts/ci/check-coverage.sh"
            return 0
        fi
    fi
}

# Run Behat tests
run_behat() {
    if ! should_run_test "behat"; then
        SKIPPED_TESTS+=("behat")
        warn "Skipping Behat (--skip-behat)"
        return 0
    fi

    info "Running Behat behavioral tests"

    # Check for behat binary
    if [ ! -f "${SITE_DIR}/vendor/bin/behat" ]; then
        warn "behat not found in vendor/bin - skipping"
        SKIPPED_TESTS+=("behat")
        return 0
    fi

    # Check for behat configuration
    local behat_config=""
    if [ -f "${SITE_DIR}/behat.yml" ]; then
        behat_config="${SITE_DIR}/behat.yml"
    elif [ -f "${SITE_DIR}/behat.yml.dist" ]; then
        behat_config="${SITE_DIR}/behat.yml.dist"
    elif [ -d "${SITE_DIR}/behat" ] && [ -f "${SITE_DIR}/behat/behat.yml" ]; then
        behat_config="${SITE_DIR}/behat/behat.yml"
    fi

    if [ -z "$behat_config" ]; then
        warn "No behat configuration found - skipping"
        SKIPPED_TESTS+=("behat")
        return 0
    fi

    task "Using configuration: ${behat_config}"

    local behat_output="${LOGS_DIR}/behat/results.txt"
    local behat_junit="${LOGS_DIR}/behat/junit.xml"

    # Build behat command
    local behat_cmd="${SITE_DIR}/vendor/bin/behat"
    behat_cmd+=" --config=${behat_config}"
    behat_cmd+=" --format=pretty"
    behat_cmd+=" --out=${behat_output}"
    behat_cmd+=" --format=junit"
    behat_cmd+=" --out=${LOGS_DIR}/behat"
    behat_cmd+=" --colors"

    if eval "$behat_cmd" 2>&1 | tee -a "${behat_output}"; then
        pass "Behat tests passed"
        PASSED_TESTS+=("behat")
        return 0
    else
        fail "Behat tests failed"
        note "See ${behat_output} for details"
        handle_failure "behat"
        return 1
    fi
}

################################################################################
# Main Execution
################################################################################

main() {
    # Record start time
    START_TIME=$(date +%s)

    print_header "CI/CD Test Suite"

    # Parse arguments
    parse_args "$@"

    # Display configuration
    info "Configuration:"
    note "Site directory: ${SITE_DIR}"
    note "Webroot: ${WEBROOT:-not found}"
    note "Logs directory: ${LOGS_DIR}"
    if [ -n "$COVERAGE_THRESHOLD" ]; then
        note "Coverage threshold: ${COVERAGE_THRESHOLD}%"
    fi
    echo ""

    # Validate site directory
    if [ ! -d "$SITE_DIR" ]; then
        print_error "Site directory does not exist: ${SITE_DIR}"
        exit 2
    fi

    # Check for vendor directory
    if [ ! -d "${SITE_DIR}/vendor" ]; then
        print_error "Vendor directory not found - run 'composer install' first"
        exit 2
    fi

    # Setup logs
    setup_logs
    echo ""

    # Run tests in sequence
    # Continue even if tests fail (unless --stop-on-failure)

    run_phpcs || true
    echo ""

    run_phpstan || true
    echo ""

    run_phpunit || true
    echo ""

    # Check coverage if threshold specified and phpunit ran
    if [ -n "$COVERAGE_THRESHOLD" ] && [[ ! " ${SKIPPED_TESTS[@]} " =~ " phpunit " ]]; then
        check_coverage || true
        echo ""
    fi

    run_behat || true
    echo ""

    # Display summary
    print_header "Test Summary"

    local total_tests=$((${#PASSED_TESTS[@]} + ${#FAILED_TESTS[@]} + ${#SKIPPED_TESTS[@]}))

    info "Results:"
    pass "Passed: ${#PASSED_TESTS[@]}"
    if [ ${#FAILED_TESTS[@]} -gt 0 ]; then
        fail "Failed: ${#FAILED_TESTS[@]}"
        for test in "${FAILED_TESTS[@]}"; do
            note "  - $test"
        done
    fi
    if [ ${#SKIPPED_TESTS[@]} -gt 0 ]; then
        warn "Skipped: ${#SKIPPED_TESTS[@]}"
        for test in "${SKIPPED_TESTS[@]}"; do
            note "  - $test"
        done
    fi

    echo ""

    # Show elapsed time
    show_elapsed_time "Test suite"

    # Exit with appropriate code
    if [ ${#FAILED_TESTS[@]} -gt 0 ]; then
        echo ""
        fail "Test suite completed with failures"
        exit 1
    else
        echo ""
        pass "All tests passed successfully"
        exit 0
    fi
}

# Run main function
main "$@"
