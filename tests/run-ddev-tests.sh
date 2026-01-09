#!/bin/bash
################################################################################
# DDEV Integration Test Runner
#
# This script runs integration tests that require DDEV to be installed and
# functional. It sets ENABLE_DDEV_TESTS=true to enable the DDEV-specific tests.
#
# Usage:
#   ./tests/run-ddev-tests.sh              # Run all DDEV integration tests
#   ./tests/run-ddev-tests.sh 01-install   # Run specific test file
#   ./tests/run-ddev-tests.sh --no-cleanup # Keep test sites after run
#
################################################################################

set -e

# Get script directory and project root
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
CLEANUP_SITES=true
SPECIFIC_TEST=""
TEST_SITE_PREFIX="bats-test"

#######################################
# Print usage information
#######################################
usage() {
    cat << EOF
DDEV Integration Test Runner

Usage: $(basename "$0") [OPTIONS] [TEST_FILE]

Options:
    --no-cleanup    Don't clean up test sites after running
    -h, --help      Show this help message

Arguments:
    TEST_FILE       Run specific test file (e.g., 01-install, 02-backup-restore)
                    If not provided, runs all integration tests

Examples:
    $(basename "$0")                    # Run all tests
    $(basename "$0") 01-install         # Run only install tests
    $(basename "$0") --no-cleanup       # Run all tests, keep test sites

EOF
}

#######################################
# Print section header
#######################################
print_header() {
    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

#######################################
# Print success message
#######################################
print_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

#######################################
# Print warning message
#######################################
print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

#######################################
# Print error message
#######################################
print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

#######################################
# Check if DDEV is installed and working
#######################################
check_ddev() {
    print_header "Checking DDEV Installation"

    # Check if ddev command exists
    if ! command -v ddev &>/dev/null; then
        print_error "DDEV is not installed or not in PATH"
        echo "Please install DDEV: https://ddev.readthedocs.io/en/stable/"
        exit 1
    fi
    print_success "DDEV command found: $(which ddev)"

    # Check DDEV version
    local version
    version=$(ddev version 2>/dev/null | grep "DDEV version" | awk '{print $3}' || echo "unknown")
    print_success "DDEV version: $version"

    # Check if Docker is running
    if ! docker info &>/dev/null; then
        print_error "Docker is not running"
        echo "Please start Docker and try again"
        exit 1
    fi
    print_success "Docker is running"

    # Check if bats is installed
    if ! command -v bats &>/dev/null; then
        print_error "BATS is not installed"
        echo "Please install BATS: https://bats-core.readthedocs.io/"
        exit 1
    fi
    print_success "BATS found: $(which bats)"

    echo ""
}

#######################################
# List any existing test sites
#######################################
list_test_sites() {
    local test_sites=()

    if [ -d "${PROJECT_ROOT}/sites" ]; then
        for site in "${PROJECT_ROOT}/sites"/${TEST_SITE_PREFIX}-*; do
            if [ -d "$site" ]; then
                test_sites+=("$(basename "$site")")
            fi
        done
    fi

    if [ ${#test_sites[@]} -gt 0 ]; then
        print_warning "Found existing test sites:"
        for site in "${test_sites[@]}"; do
            echo "  - $site"
        done
        echo ""
    fi
}

#######################################
# Clean up test sites
#######################################
cleanup_test_sites() {
    print_header "Cleaning Up Test Sites"

    if [ "$CLEANUP_SITES" != "true" ]; then
        print_warning "Cleanup disabled - test sites will be preserved"
        return 0
    fi

    local cleaned=0

    if [ -d "${PROJECT_ROOT}/sites" ]; then
        for site in "${PROJECT_ROOT}/sites"/${TEST_SITE_PREFIX}-*; do
            if [ -d "$site" ]; then
                local sitename
                sitename=$(basename "$site")
                echo -e "  Removing ${CYAN}${sitename}${NC}..."

                # Stop DDEV if running
                if [ -f "$site/.ddev/config.yaml" ]; then
                    (cd "$site" && ddev stop --unlist 2>/dev/null) || true
                fi

                # Use delete.sh if available
                if [ -x "${PROJECT_ROOT}/scripts/commands/delete.sh" ]; then
                    "${PROJECT_ROOT}/scripts/commands/delete.sh" -fy "$sitename" 2>/dev/null || rm -rf "$site"
                else
                    rm -rf "$site"
                fi

                ((cleaned++)) || true
            fi
        done
    fi

    # Clean up any test backups
    if [ -d "${PROJECT_ROOT}/sitebackups" ]; then
        for backup in "${PROJECT_ROOT}/sitebackups"/${TEST_SITE_PREFIX}-*; do
            if [ -d "$backup" ]; then
                rm -rf "$backup"
                ((cleaned++)) || true
            fi
        done
    fi

    if [ $cleaned -gt 0 ]; then
        print_success "Cleaned up $cleaned test site(s)/backup(s)"
    else
        echo "  No test sites to clean up"
    fi
}

#######################################
# Run the integration tests
#######################################
run_tests() {
    print_header "Running DDEV Integration Tests"

    # Export the environment variable to enable DDEV tests
    export ENABLE_DDEV_TESTS=true
    export CLEANUP_SITES="$CLEANUP_SITES"
    export TEST_SITE_PREFIX="$TEST_SITE_PREFIX"

    echo -e "Environment: ${CYAN}ENABLE_DDEV_TESTS=${ENABLE_DDEV_TESTS}${NC}"
    echo -e "Cleanup: ${CYAN}CLEANUP_SITES=${CLEANUP_SITES}${NC}"
    echo ""

    local test_files=()
    local integration_dir="${SCRIPT_DIR}/integration"

    if [ -n "$SPECIFIC_TEST" ]; then
        # Run specific test file
        local test_file="${integration_dir}/${SPECIFIC_TEST}.bats"
        if [ ! -f "$test_file" ]; then
            # Try without extension
            test_file="${integration_dir}/${SPECIFIC_TEST}"
            if [ ! -f "$test_file" ]; then
                print_error "Test file not found: $SPECIFIC_TEST"
                echo "Available test files:"
                ls -1 "${integration_dir}"/*.bats 2>/dev/null | xargs -n1 basename
                exit 1
            fi
        fi
        test_files=("$test_file")
    else
        # Run all integration tests (01-05)
        for num in 01 02 03 04 05; do
            for test_file in "${integration_dir}"/${num}-*.bats; do
                if [ -f "$test_file" ]; then
                    test_files+=("$test_file")
                fi
            done
        done
    fi

    if [ ${#test_files[@]} -eq 0 ]; then
        print_error "No test files found"
        exit 1
    fi

    echo "Test files to run:"
    for f in "${test_files[@]}"; do
        echo "  - $(basename "$f")"
    done
    echo ""

    # Run bats with the test files
    local exit_code=0
    cd "$PROJECT_ROOT"

    if bats "${test_files[@]}"; then
        print_success "All tests passed!"
    else
        exit_code=$?
        print_error "Some tests failed (exit code: $exit_code)"
    fi

    return $exit_code
}

#######################################
# Print test summary
#######################################
print_summary() {
    local exit_code=$1

    print_header "Test Summary"

    if [ $exit_code -eq 0 ]; then
        echo -e "${GREEN}All DDEV integration tests passed!${NC}"
    else
        echo -e "${RED}Some tests failed. Review the output above for details.${NC}"
        echo ""
        echo "Tips for debugging:"
        echo "  1. Run with --no-cleanup to inspect test sites"
        echo "  2. Check DDEV logs: ddev logs"
        echo "  3. Run individual tests: ./tests/run-ddev-tests.sh 01-install"
    fi
}

#######################################
# Main execution
#######################################
main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --no-cleanup)
                CLEANUP_SITES=false
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -*)
                print_error "Unknown option: $1"
                usage
                exit 1
                ;;
            *)
                SPECIFIC_TEST="$1"
                shift
                ;;
        esac
    done

    print_header "DDEV Integration Test Runner"
    echo "Project root: $PROJECT_ROOT"
    echo "Test directory: $SCRIPT_DIR/integration"

    # Pre-flight checks
    check_ddev

    # Show existing test sites
    list_test_sites

    # Run the tests
    local exit_code=0
    run_tests || exit_code=$?

    # Cleanup
    cleanup_test_sites

    # Summary
    print_summary $exit_code

    exit $exit_code
}

main "$@"
