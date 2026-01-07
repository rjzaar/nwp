#!/bin/bash
set -euo pipefail

################################################################################
# NWP Test Script
#
# Run tests for DDEV sites (PHPCS, PHPStan, PHPUnit, Behat)
#
# Usage: ./test.sh [OPTIONS] <sitename>
################################################################################

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

# Source shared libraries
source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh"

# Script start time
START_TIME=$(date +%s)

################################################################################
# Configuration
################################################################################

# Test types and their commands
declare -A TEST_COMMANDS=(
    [lint]="phpcs"
    [stan]="phpstan"
    [unit]="phpunit:unit"
    [kernel]="phpunit:kernel"
    [functional]="phpunit:functional"
    [smoke]="behat:smoke"
    [behat]="behat:full"
)

################################################################################
# Help
################################################################################

show_help() {
    cat << EOF
${BOLD}NWP Test Script${NC}

${BOLD}USAGE:${NC}
    ./test.sh [OPTIONS] <sitename>

${BOLD}OPTIONS:${NC}
    -h, --help              Show this help message
    -d, --debug             Enable debug output
    -l, --lint              Run PHPCS linting only
    -t, --stan              Run PHPStan only
    -u, --unit              Run PHPUnit unit tests only
    -k, --kernel            Run PHPUnit kernel tests only
    -f, --functional        Run PHPUnit functional tests only
    -s, --smoke             Run Behat smoke tests only (~30s)
    -b, --behat             Run full Behat tests
    -p, --parallel          Run Behat in parallel (2 processes)
    -a, --all               Run all tests (default)
    --ci                    CI mode (stricter, JUnit output)

${BOLD}ARGUMENTS:${NC}
    sitename                Name of the DDEV site to test

${BOLD}EXAMPLES:${NC}
    ./test.sh nwp                    # Run all tests
    ./test.sh -l nwp                 # Lint only (PHPCS)
    ./test.sh -u nwp                 # Unit tests only
    ./test.sh -s nwp                 # Smoke tests only (~30s)
    ./test.sh -b nwp                 # Full Behat tests
    ./test.sh -bp nwp                # Parallel Behat tests
    ./test.sh -ltu nwp               # Lint, stan, and unit tests

${BOLD}TEST SPEED:${NC}
    -l (lint)       Fast (~10s)
    -t (stan)       Fast (~20s)
    -u (unit)       Fast (~30s)
    -k (kernel)     Medium (~2m)
    -s (smoke)      Medium (~30s)
    -b (behat)      Slow (~10m)

EOF
}

################################################################################
# Test Functions
################################################################################

# Check if test dependencies are available
check_test_deps() {
    local sitename=$1
    local test_type=$2

    cd "$sitename" || return 1

    case "$test_type" in
        phpcs)
            if [ ! -f "vendor/bin/phpcs" ]; then
                print_warning "PHPCS not found. Install with: composer require --dev drupal/coder"
                return 1
            fi
            ;;
        phpstan)
            if [ ! -f "vendor/bin/phpstan" ]; then
                print_warning "PHPStan not found. Install with: composer require --dev phpstan/phpstan"
                return 1
            fi
            ;;
        phpunit*)
            if [ ! -f "vendor/bin/phpunit" ]; then
                print_warning "PHPUnit not found. Install with: composer require --dev phpunit/phpunit"
                return 1
            fi
            ;;
        behat*)
            if [ ! -f "vendor/bin/behat" ]; then
                print_warning "Behat not found. Install with: composer require --dev drupal/drupal-extension"
                return 1
            fi
            ;;
    esac

    cd - > /dev/null
    return 0
}

# Run PHPCS linting
run_phpcs() {
    local sitename=$1
    local ci_mode=$2

    print_header "PHPCS Linting"

    if ! check_test_deps "$sitename" "phpcs"; then
        return 1
    fi

    cd "$sitename" || return 1

    # Find custom modules and themes
    local targets=""
    [ -d "web/modules/custom" ] && targets="$targets web/modules/custom"
    [ -d "web/themes/custom" ] && targets="$targets web/themes/custom"
    [ -d "html/modules/custom" ] && targets="$targets html/modules/custom"
    [ -d "html/themes/custom" ] && targets="$targets html/themes/custom"

    if [ -z "$targets" ]; then
        print_info "No custom modules/themes found to lint"
        cd - > /dev/null
        return 0
    fi

    local phpcs_args="--standard=Drupal,DrupalPractice"
    if [ "$ci_mode" = "true" ]; then
        phpcs_args="$phpcs_args --report=junit --report-file=reports/phpcs.xml"
        mkdir -p reports
    fi

    if ddev exec vendor/bin/phpcs $phpcs_args $targets; then
        print_status "OK" "PHPCS passed"
        cd - > /dev/null
        return 0
    else
        print_error "PHPCS found issues"
        cd - > /dev/null
        return 1
    fi
}

# Run PHPStan analysis
run_phpstan() {
    local sitename=$1
    local ci_mode=$2

    print_header "PHPStan Analysis"

    if ! check_test_deps "$sitename" "phpstan"; then
        return 1
    fi

    cd "$sitename" || return 1

    # Find custom modules and themes
    local targets=""
    [ -d "web/modules/custom" ] && targets="$targets web/modules/custom"
    [ -d "web/themes/custom" ] && targets="$targets web/themes/custom"
    [ -d "html/modules/custom" ] && targets="$targets html/modules/custom"
    [ -d "html/themes/custom" ] && targets="$targets html/themes/custom"

    if [ -z "$targets" ]; then
        print_info "No custom modules/themes found to analyze"
        cd - > /dev/null
        return 0
    fi

    local phpstan_args="analyse --level=5"
    if [ "$ci_mode" = "true" ]; then
        phpstan_args="$phpstan_args --error-format=junit > reports/phpstan.xml"
        mkdir -p reports
    fi

    if ddev exec vendor/bin/phpstan $phpstan_args $targets; then
        print_status "OK" "PHPStan passed"
        cd - > /dev/null
        return 0
    else
        print_error "PHPStan found issues"
        cd - > /dev/null
        return 1
    fi
}

# Run PHPUnit tests
run_phpunit() {
    local sitename=$1
    local testsuite=$2
    local ci_mode=$3

    print_header "PHPUnit Tests ($testsuite)"

    if ! check_test_deps "$sitename" "phpunit"; then
        return 1
    fi

    cd "$sitename" || return 1

    local phpunit_args="--testsuite=$testsuite"
    if [ "$ci_mode" = "true" ]; then
        phpunit_args="$phpunit_args --log-junit=reports/phpunit-$testsuite.xml"
        mkdir -p reports
    fi

    if ddev exec vendor/bin/phpunit $phpunit_args; then
        print_status "OK" "PHPUnit $testsuite tests passed"
        cd - > /dev/null
        return 0
    else
        print_error "PHPUnit $testsuite tests failed"
        cd - > /dev/null
        return 1
    fi
}

# Run Behat tests
run_behat() {
    local sitename=$1
    local tags=$2
    local parallel=$3
    local ci_mode=$4

    print_header "Behat Tests ($tags)"

    if ! check_test_deps "$sitename" "behat"; then
        return 1
    fi

    cd "$sitename" || return 1

    local behat_args=""
    if [ -n "$tags" ]; then
        behat_args="--tags=$tags"
    fi

    if [ "$ci_mode" = "true" ]; then
        behat_args="$behat_args --format=progress --format=junit --out=,reports/behat.xml"
        mkdir -p reports
    fi

    if [ "$parallel" = "true" ]; then
        # Run in parallel using parallel profiles
        print_info "Running Behat in parallel (2 processes)"
        local failed=0
        ddev exec vendor/bin/behat --profile=p0 $behat_args &
        local pid1=$!
        ddev exec vendor/bin/behat --profile=p1 $behat_args &
        local pid2=$!

        wait $pid1 || failed=1
        wait $pid2 || failed=1

        if [ $failed -eq 0 ]; then
            print_status "OK" "Behat tests passed"
            cd - > /dev/null
            return 0
        else
            print_error "Behat tests failed"
            cd - > /dev/null
            return 1
        fi
    else
        if ddev exec vendor/bin/behat $behat_args; then
            print_status "OK" "Behat tests passed"
            cd - > /dev/null
            return 0
        else
            print_error "Behat tests failed"
            cd - > /dev/null
            return 1
        fi
    fi
}

################################################################################
# Main Script
################################################################################

main() {
    # Parse options
    local DEBUG=false
    local CI_MODE=false
    local PARALLEL=false
    local SITENAME=""
    local RUN_LINT=false
    local RUN_STAN=false
    local RUN_UNIT=false
    local RUN_KERNEL=false
    local RUN_FUNCTIONAL=false
    local RUN_SMOKE=false
    local RUN_BEHAT=false
    local RUN_ALL=true

    # Use getopt for option parsing
    local OPTIONS=hdltukfsbpa
    local LONGOPTS=help,debug,lint,stan,unit,kernel,functional,smoke,behat,parallel,all,ci

    if ! PARSED=$(getopt --options=$OPTIONS --longoptions=$LONGOPTS --name "$0" -- "$@"); then
        show_help
        exit 1
    fi

    eval set -- "$PARSED"

    while true; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -d|--debug)
                DEBUG=true
                shift
                ;;
            -l|--lint)
                RUN_LINT=true
                RUN_ALL=false
                shift
                ;;
            -t|--stan)
                RUN_STAN=true
                RUN_ALL=false
                shift
                ;;
            -u|--unit)
                RUN_UNIT=true
                RUN_ALL=false
                shift
                ;;
            -k|--kernel)
                RUN_KERNEL=true
                RUN_ALL=false
                shift
                ;;
            -f|--functional)
                RUN_FUNCTIONAL=true
                RUN_ALL=false
                shift
                ;;
            -s|--smoke)
                RUN_SMOKE=true
                RUN_ALL=false
                shift
                ;;
            -b|--behat)
                RUN_BEHAT=true
                RUN_ALL=false
                shift
                ;;
            -p|--parallel)
                PARALLEL=true
                shift
                ;;
            -a|--all)
                RUN_ALL=true
                shift
                ;;
            --ci)
                CI_MODE=true
                shift
                ;;
            --)
                shift
                break
                ;;
            *)
                echo "Programming error"
                exit 3
                ;;
        esac
    done

    # Get sitename from remaining arguments
    if [ $# -ge 1 ]; then
        SITENAME="$1"
        shift
    else
        print_error "No site specified"
        echo ""
        show_help
        exit 1
    fi

    # Validate sitename
    if ! validate_sitename "$SITENAME"; then
        exit 1
    fi

    # Check if site exists - look in sites/ subdirectory first
    local SITE_PATH=""
    if [ -d "sites/$SITENAME" ]; then
        SITE_PATH="sites/$SITENAME"
    elif [ -d "$SITENAME" ]; then
        SITE_PATH="$SITENAME"
    else
        print_error "Site directory not found: $SITENAME"
        exit 1
    fi

    # Check if DDEV is configured
    if [ ! -f "$SITE_PATH/.ddev/config.yaml" ]; then
        print_error "DDEV not configured in $SITE_PATH"
        exit 1
    fi

    # Update SITENAME to use the found path
    SITENAME="$SITE_PATH"

    print_header "NWP Test Suite: $SITENAME"

    # Track test results
    local TESTS_RUN=0
    local TESTS_PASSED=0
    local TESTS_FAILED=0

    # Run selected tests or all tests
    if [ "$RUN_ALL" = "true" ] || [ "$RUN_LINT" = "true" ]; then
        TESTS_RUN=$((TESTS_RUN + 1))
        if run_phpcs "$SITENAME" "$CI_MODE"; then
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    fi

    if [ "$RUN_ALL" = "true" ] || [ "$RUN_STAN" = "true" ]; then
        TESTS_RUN=$((TESTS_RUN + 1))
        if run_phpstan "$SITENAME" "$CI_MODE"; then
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    fi

    if [ "$RUN_ALL" = "true" ] || [ "$RUN_UNIT" = "true" ]; then
        TESTS_RUN=$((TESTS_RUN + 1))
        if run_phpunit "$SITENAME" "unit" "$CI_MODE"; then
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    fi

    if [ "$RUN_KERNEL" = "true" ]; then
        TESTS_RUN=$((TESTS_RUN + 1))
        if run_phpunit "$SITENAME" "kernel" "$CI_MODE"; then
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    fi

    if [ "$RUN_FUNCTIONAL" = "true" ]; then
        TESTS_RUN=$((TESTS_RUN + 1))
        if run_phpunit "$SITENAME" "functional" "$CI_MODE"; then
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    fi

    if [ "$RUN_SMOKE" = "true" ]; then
        TESTS_RUN=$((TESTS_RUN + 1))
        if run_behat "$SITENAME" "@smoke" "$PARALLEL" "$CI_MODE"; then
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    fi

    if [ "$RUN_ALL" = "true" ] || [ "$RUN_BEHAT" = "true" ]; then
        TESTS_RUN=$((TESTS_RUN + 1))
        if run_behat "$SITENAME" "" "$PARALLEL" "$CI_MODE"; then
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    fi

    # Summary
    print_header "Test Summary"
    echo "Tests run:    $TESTS_RUN"
    echo "Tests passed: $TESTS_PASSED"
    echo "Tests failed: $TESTS_FAILED"

    show_elapsed_time "Testing"

    if [ $TESTS_FAILED -gt 0 ]; then
        print_error "Some tests failed"
        exit 1
    else
        print_status "OK" "All tests passed"
        exit 0
    fi
}

# Run main
main "$@"
