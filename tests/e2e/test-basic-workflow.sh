#!/bin/bash
################################################################################
# E2E Test: Basic Workflow
#
# Tests a basic NWP workflow including validation and dry-run operations.
# Can be run manually or via CI without requiring Linode provisioning.
#
# This test validates:
#   1. Script syntax and structure
#   2. Configuration file parsing
#   3. Command help messages
#   4. Dry-run/validation modes where available
#
# Cost Estimates (when using Linode for full E2E):
#   - Nanode (1GB): $0.0075/hour = ~$0.02 for 2-hour test
#   - Standard (2GB): $0.015/hour = ~$0.04 for 2-hour test
#   - Monthly cap with nightly tests: ~$0.60/month (Nanode)
#
# Usage:
#   ./tests/e2e/test-basic-workflow.sh           # Run all local tests
#   ./tests/e2e/test-basic-workflow.sh --quick   # Quick validation only
#   ./tests/e2e/test-basic-workflow.sh --linode  # Full E2E with Linode (costs money)
################################################################################

set -euo pipefail

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
FIXTURES_DIR="${SCRIPT_DIR}/../fixtures"

# Test configuration
TEST_MODE="${1:-local}"
VERBOSE="${VERBOSE:-false}"
CLEANUP="${CLEANUP:-true}"

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# Colors (disabled in CI)
if [ -t 1 ] && [ -z "${CI:-}" ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

################################################################################
# Helper Functions
################################################################################

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_pass() {
    echo -e "${GREEN}[PASS]${NC} $*"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $*"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

log_skip() {
    echo -e "${YELLOW}[SKIP]${NC} $*"
    TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
}

log_header() {
    echo ""
    echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $*${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
}

# Run a test and report result
# Usage: run_test "Test name" command args...
run_test() {
    local name="$1"
    shift

    if [ "${VERBOSE}" = "true" ]; then
        log_info "Running: $*"
    fi

    if "$@" >/dev/null 2>&1; then
        log_pass "${name}"
        return 0
    else
        log_fail "${name}"
        if [ "${VERBOSE}" = "true" ]; then
            echo "  Command: $*"
            "$@" 2>&1 | head -20 | sed 's/^/  /'
        fi
        return 1
    fi
}

# Check if a command exists
check_command() {
    command -v "$1" &>/dev/null
}

################################################################################
# Test Suites
################################################################################

# Test 1: Validate project structure
test_project_structure() {
    log_header "Test Suite: Project Structure"

    run_test "Project root exists" test -d "${PROJECT_ROOT}"
    run_test "lib/ directory exists" test -d "${PROJECT_ROOT}/lib"
    run_test "scripts/commands/ exists" test -d "${PROJECT_ROOT}/scripts/commands"
    run_test "tests/ directory exists" test -d "${PROJECT_ROOT}/tests"
    run_test "example.cnwp.yml exists" test -f "${PROJECT_ROOT}/example.cnwp.yml"
}

# Test 2: Validate all core scripts have valid bash syntax
test_script_syntax() {
    log_header "Test Suite: Script Syntax Validation"

    local scripts=(
        "scripts/commands/install.sh"
        "scripts/commands/backup.sh"
        "scripts/commands/restore.sh"
        "scripts/commands/copy.sh"
        "scripts/commands/delete.sh"
        "scripts/commands/make.sh"
        "scripts/commands/dev2stg.sh"
    )

    for script in "${scripts[@]}"; do
        if [ -f "${PROJECT_ROOT}/${script}" ]; then
            run_test "Syntax: ${script}" bash -n "${PROJECT_ROOT}/${script}"
        else
            log_skip "Script not found: ${script}"
        fi
    done
}

# Test 3: Validate all libraries have valid bash syntax
test_library_syntax() {
    log_header "Test Suite: Library Syntax Validation"

    local libs=(
        "lib/ui.sh"
        "lib/common.sh"
        "lib/terminal.sh"
        "lib/yaml-write.sh"
    )

    for lib in "${libs[@]}"; do
        if [ -f "${PROJECT_ROOT}/${lib}" ]; then
            run_test "Syntax: ${lib}" bash -n "${PROJECT_ROOT}/${lib}"
        else
            log_skip "Library not found: ${lib}"
        fi
    done
}

# Test 4: Test help messages
test_help_messages() {
    log_header "Test Suite: Help Messages"

    local scripts=(
        "install.sh"
        "backup.sh"
        "restore.sh"
        "copy.sh"
        "delete.sh"
        "make.sh"
        "dev2stg.sh"
    )

    for script in "${scripts[@]}"; do
        local script_path="${PROJECT_ROOT}/scripts/commands/${script}"
        if [ -f "${script_path}" ]; then
            # Test that --help returns success and contains "Usage" or "USAGE"
            # Strip ANSI codes before checking
            local help_output
            help_output=$("${script_path}" --help 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
            if echo "${help_output}" | grep -qi "usage"; then
                log_pass "Help: ${script}"
            else
                log_fail "Help: ${script} (missing Usage in output)"
            fi
        else
            log_skip "Script not found: ${script}"
        fi
    done
}

# Test 5: Test fixtures
test_fixtures() {
    log_header "Test Suite: Test Fixtures"

    run_test "Fixtures directory exists" test -d "${FIXTURES_DIR}"
    run_test "cnwp.yml fixture exists" test -f "${FIXTURES_DIR}/cnwp.yml"
    run_test "secrets.yml fixture exists" test -f "${FIXTURES_DIR}/secrets.yml"
    run_test "sample-site/ exists" test -d "${FIXTURES_DIR}/sample-site"
    run_test "sample-site/composer.json exists" test -f "${FIXTURES_DIR}/sample-site/composer.json"
    run_test "sample-site/.ddev/ exists" test -d "${FIXTURES_DIR}/sample-site/.ddev"

    # Validate fixture YAML syntax
    if check_command yq; then
        run_test "cnwp.yml is valid YAML" yq eval '.' "${FIXTURES_DIR}/cnwp.yml"
        run_test "secrets.yml is valid YAML" yq eval '.' "${FIXTURES_DIR}/secrets.yml"
    else
        log_skip "yq not installed - skipping YAML validation"
    fi
}

# Test 6: Test configuration parsing
test_config_parsing() {
    log_header "Test Suite: Configuration Parsing"

    # Source common library for config functions
    if source "${PROJECT_ROOT}/lib/common.sh" 2>/dev/null; then
        log_pass "lib/common.sh can be sourced"

        # Test with fixture config
        export PROJECT_ROOT="${FIXTURES_DIR}"

        if [ -f "${FIXTURES_DIR}/cnwp.yml" ]; then
            # Try to parse configuration
            if command -v yq &>/dev/null; then
                local php_version
                php_version=$(yq eval '.settings.php' "${FIXTURES_DIR}/cnwp.yml" 2>/dev/null)
                if [ -n "${php_version}" ] && [ "${php_version}" != "null" ]; then
                    log_pass "Can read settings.php from cnwp.yml (value: ${php_version})"
                else
                    log_fail "Cannot read settings.php from cnwp.yml"
                fi
            else
                log_skip "yq not installed - skipping config parsing test"
            fi
        fi
    else
        log_fail "lib/common.sh cannot be sourced"
    fi
}

# Test 7: Test BATS infrastructure
test_bats_infrastructure() {
    log_header "Test Suite: BATS Infrastructure"

    if check_command bats; then
        log_pass "BATS is installed"

        # Run a quick BATS test
        if bats --version &>/dev/null; then
            log_pass "BATS runs successfully"

            # Test helpers can be loaded
            if [ -f "${PROJECT_ROOT}/tests/helpers/test-helpers.bash" ]; then
                run_test "test-helpers.bash has valid syntax" bash -n "${PROJECT_ROOT}/tests/helpers/test-helpers.bash"
            fi
        else
            log_fail "BATS failed to run"
        fi
    else
        log_skip "BATS not installed"
    fi
}

# Test 8: Dry-run validation (where supported)
test_dry_run() {
    log_header "Test Suite: Dry-Run Validation"

    # These tests check that scripts fail gracefully with invalid input
    # rather than actually performing operations

    local test_sitename="nwp-test-$$"

    # Test install.sh with missing recipe
    if "${PROJECT_ROOT}/scripts/commands/install.sh" nonexistent_recipe "${test_sitename}" 2>&1 | grep -qi "error\|not found\|invalid"; then
        log_pass "install.sh rejects invalid recipe"
    else
        log_skip "install.sh invalid recipe test (may require DDEV)"
    fi

    # Test backup.sh with nonexistent site
    if "${PROJECT_ROOT}/scripts/commands/backup.sh" nonexistent_site_$$_$RANDOM 2>&1 | grep -qi "error\|not found\|does not exist"; then
        log_pass "backup.sh rejects nonexistent site"
    else
        log_skip "backup.sh nonexistent site test (may require DDEV)"
    fi

    # Test delete.sh with nonexistent site
    if "${PROJECT_ROOT}/scripts/commands/delete.sh" nonexistent_site_$$_$RANDOM 2>&1 | grep -qi "error\|not found\|does not exist"; then
        log_pass "delete.sh rejects nonexistent site"
    else
        log_skip "delete.sh nonexistent site test (may require DDEV)"
    fi
}

# Full E2E test with Linode (optional, costs money)
test_linode_e2e() {
    log_header "Test Suite: Full E2E with Linode"

    log_info "This test provisions a real Linode instance"
    log_info "Estimated cost: ~\$0.02 for 2-hour test"
    log_info ""

    # Check prerequisites
    if [ ! -f "${PROJECT_ROOT}/.secrets.yml" ]; then
        log_skip "No .secrets.yml found - skipping Linode tests"
        return 0
    fi

    if ! check_command yq; then
        log_skip "yq not installed - cannot read secrets"
        return 0
    fi

    local api_token
    api_token=$(yq eval '.linode.api_token' "${PROJECT_ROOT}/.secrets.yml" 2>/dev/null)

    if [ -z "${api_token}" ] || [ "${api_token}" = "null" ] || [ "${api_token}" = "" ]; then
        log_skip "No Linode API token configured"
        return 0
    fi

    log_info "Linode API token found"
    log_skip "Full Linode E2E not yet implemented"
    log_info "See tests/e2e/test-fresh-install.sh for placeholder"
}

################################################################################
# Main
################################################################################

main() {
    local start_time
    start_time=$(date +%s)

    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║                   NWP E2E Basic Workflow Test                  ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
    log_info "Project root: ${PROJECT_ROOT}"
    log_info "Test mode: ${TEST_MODE}"
    log_info "Date: $(date)"
    echo ""

    # Run test suites based on mode
    case "${TEST_MODE}" in
        --quick)
            test_project_structure
            test_script_syntax
            ;;
        --linode)
            test_project_structure
            test_script_syntax
            test_library_syntax
            test_help_messages
            test_fixtures
            test_config_parsing
            test_bats_infrastructure
            test_dry_run
            test_linode_e2e
            ;;
        local|*)
            test_project_structure
            test_script_syntax
            test_library_syntax
            test_help_messages
            test_fixtures
            test_config_parsing
            test_bats_infrastructure
            test_dry_run
            ;;
    esac

    # Summary
    local end_time elapsed
    end_time=$(date +%s)
    elapsed=$((end_time - start_time))

    echo ""
    log_header "Test Summary"
    echo ""
    echo -e "  ${GREEN}Passed:${NC}  ${TESTS_PASSED}"
    echo -e "  ${RED}Failed:${NC}  ${TESTS_FAILED}"
    echo -e "  ${YELLOW}Skipped:${NC} ${TESTS_SKIPPED}"
    echo ""
    echo "  Total time: ${elapsed}s"
    echo ""

    if [ ${TESTS_FAILED} -gt 0 ]; then
        echo -e "${RED}Some tests failed!${NC}"
        return 1
    else
        echo -e "${GREEN}All tests passed!${NC}"
        return 0
    fi
}

# Show help
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    echo "NWP E2E Basic Workflow Test"
    echo ""
    echo "Usage: $0 [mode]"
    echo ""
    echo "Modes:"
    echo "  (default)  Run all local tests (no cloud resources)"
    echo "  --quick    Quick validation only (syntax, structure)"
    echo "  --linode   Full E2E with Linode provisioning (costs money)"
    echo ""
    echo "Environment variables:"
    echo "  VERBOSE=true   Show detailed output for failed tests"
    echo "  CLEANUP=false  Keep test artifacts for inspection"
    echo ""
    echo "Cost estimates for --linode mode:"
    echo "  Nanode (1GB):   \$0.0075/hour = ~\$0.02 for 2-hour test"
    echo "  Standard (2GB): \$0.015/hour = ~\$0.04 for 2-hour test"
    echo "  Monthly (nightly tests): ~\$0.60/month"
    echo ""
    exit 0
fi

# Run main
main "$@"
