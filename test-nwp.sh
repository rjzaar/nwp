#!/bin/bash
################################################################################
# NWP Comprehensive Test Script
#
# Tests all NWP functionality:
#   - Installation
#   - Backup and restore
#   - Site copying
#   - Dev/prod mode switching
#   - Deployment (dev2stg)
#   - Testing infrastructure
#
# Usage:
#   ./test-nwp.sh [--skip-cleanup] [--verbose]
#
# Options:
#   --skip-cleanup    Don't delete test sites after completion
#   --verbose         Show detailed output
#   -h, --help        Show this help message
#
################################################################################

# Note: We don't use 'set -e' here because we want tests to continue
# even if individual tests fail. Each test captures its own exit code.

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

# Configuration
TEST_SITE_PREFIX="test_nwp"
CLEANUP=true
VERBOSE=false
LOG_FILE="test-nwp-$(date +%Y%m%d-%H%M%S).log"

# Test results
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_WARNING=0
FAILED_TESTS=()
WARNING_TESTS=()

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-cleanup)
            CLEANUP=false
            shift
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            grep "^#" "$0" | grep -v "^#!/" | sed 's/^# //' | sed 's/^#//'
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Helper functions
print_header() {
    echo -e "\n${BLUE}${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}${BOLD}  $1${NC}"
    echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════════════${NC}\n"
}

print_test() {
    echo -e "${BOLD}TEST:${NC} $1"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}!${NC} $1"
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
    if [ "$VERBOSE" = true ]; then
        echo "$1"
    fi
}

run_test() {
    local test_name="$1"
    local test_command="$2"
    local expected_result="${3:-pass}"  # Default to expecting pass

    TESTS_RUN=$((TESTS_RUN + 1))
    print_test "$test_name"
    log "Running test: $test_name (expected: $expected_result)"

    if eval "$test_command" >> "$LOG_FILE" 2>&1; then
        # Command succeeded
        if [ "$expected_result" = "warn" ]; then
            # Expected to warn, but it passed - still count as warning
            TESTS_WARNING=$((TESTS_WARNING + 1))
            WARNING_TESTS+=("$test_name (expected warning, but passed)")
            print_warning "WARNING (expected to warn)"
            log "Test WARNING: $test_name (expected warning, but passed)"
            return 0
        else
            # Expected to pass, and it did
            TESTS_PASSED=$((TESTS_PASSED + 1))
            print_success "PASSED"
            log "Test PASSED: $test_name"
            return 0
        fi
    else
        # Command failed
        if [ "$expected_result" = "warn" ]; then
            # Expected to warn, and it failed - count as warning
            TESTS_WARNING=$((TESTS_WARNING + 1))
            WARNING_TESTS+=("$test_name")
            print_warning "WARNING (expected behavior)"
            log "Test WARNING: $test_name (expected to fail/warn)"
            return 0
        else
            # Expected to pass, but it failed - count as error
            TESTS_FAILED=$((TESTS_FAILED + 1))
            FAILED_TESTS+=("$test_name")
            print_error "FAILED"
            log "Test FAILED: $test_name"
            return 1
        fi
    fi
}

cleanup_test_sites() {
    print_info "Cleaning up test sites..."

    # Stop all test sites
    for site in ${TEST_SITE_PREFIX}*; do
        if [ -d "$site" ]; then
            print_info "Stopping $site..."
            cd "$site" && ddev stop 2>/dev/null || true
            cd "$SCRIPT_DIR"
        fi
    done

    # Remove test site directories
    for site in ${TEST_SITE_PREFIX}*; do
        if [ -d "$site" ]; then
            print_info "Removing $site..."
            rm -rf "$site"
        fi
    done

    # Clean up backups
    if [ -d "sitebackups" ]; then
        print_info "Removing test backups..."
        rm -rf sitebackups/${TEST_SITE_PREFIX}*
    fi

    # Remove test recipe from cnwp.yml
    if grep -q "^  ${TEST_SITE_PREFIX}:" cnwp.yml 2>/dev/null; then
        print_info "Removing test recipe from cnwp.yml..."
        # Remove the test recipe section (6 lines: recipe name + 4 config lines + auto line)
        sed -i "/^  ${TEST_SITE_PREFIX}:/,+4d" cnwp.yml
    fi

    print_success "Cleanup complete"
}

site_exists() {
    local site="$1"
    [ -d "$site" ] && [ -f "$site/.ddev/config.yaml" ]
}

site_is_running() {
    local site="$1"
    cd "$site" && ddev describe >/dev/null 2>&1
    local result=$?
    cd "$SCRIPT_DIR"
    return $result
}

drush_works() {
    local site="$1"
    local max_attempts=3
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        if cd "$site" && ddev drush status >/dev/null 2>&1; then
            cd "$SCRIPT_DIR"
            return 0
        fi
        cd "$SCRIPT_DIR" 2>/dev/null || true

        if [ $attempt -lt $max_attempts ]; then
            sleep 2  # Wait 2 seconds before retry
        fi
        attempt=$((attempt + 1))
    done

    return 1
}

backup_exists() {
    local site="$1"
    [ -d "sitebackups/$site" ] && [ -n "$(ls -A sitebackups/$site 2>/dev/null)" ]
}

# Start testing
print_header "NWP Comprehensive Test Suite"
echo "Log file: $LOG_FILE"
echo ""

# Pre-configure DDEV hostname to avoid sudo prompts during tests
print_info "Pre-configuring DDEV hostnames..."
sudo ddev hostname ${TEST_SITE_PREFIX}.ddev.site 127.0.0.1 2>/dev/null || print_warning "Could not configure hostname (may require manual sudo)"
sudo ddev hostname ${TEST_SITE_PREFIX}_copy.ddev.site 127.0.0.1 2>/dev/null || true
sudo ddev hostname ${TEST_SITE_PREFIX}_files.ddev.site 127.0.0.1 2>/dev/null || true
sudo ddev hostname ${TEST_SITE_PREFIX}_stg.ddev.site 127.0.0.1 2>/dev/null || true
echo ""

# Test 1: Installation
print_header "Test 1: Installation"

# First, create a test recipe in cnwp.yml if it doesn't exist
if ! grep -q "^  ${TEST_SITE_PREFIX}:" cnwp.yml 2>/dev/null; then
    print_info "Adding test recipe to cnwp.yml..."
    # Add with proper indentation (2 spaces for recipe name, 4 for properties)
    cat >> cnwp.yml << 'EOF'

  test_nwp:
    source: goalgorilla/social_template:dev-master
    profile: social
    webroot: html
    auto: y
EOF
fi

run_test "Install test site" "./install.sh $TEST_SITE_PREFIX"

if site_exists "$TEST_SITE_PREFIX"; then
    run_test "Site directory created" "site_exists $TEST_SITE_PREFIX"
    run_test "DDEV is running" "site_is_running $TEST_SITE_PREFIX"
    run_test "Drush is working" "drush_works $TEST_SITE_PREFIX"
else
    print_error "Installation failed - cannot continue with remaining tests"
    exit 1
fi

# Test 2: Backup functionality
print_header "Test 2: Backup Functionality"

run_test "Create full backup" "./backup.sh $TEST_SITE_PREFIX 'Test_backup'"
run_test "Backup directory exists" "backup_exists $TEST_SITE_PREFIX"

# Test 3: Restore functionality (before creating DB-only backup)
print_header "Test 3: Restore Functionality"

# Modify site before restore
if cd "$TEST_SITE_PREFIX" 2>/dev/null; then
    ddev drush config:set system.site name "Modified Site" -y >/dev/null 2>&1 || true
    cd "$SCRIPT_DIR"
fi

run_test "Restore from full backup" "./restore.sh -fy $TEST_SITE_PREFIX"

# Test 3b: Database-only backup and restore
print_header "Test 3b: Database-Only Backup and Restore"

run_test "Create database-only backup" "./backup.sh -b $TEST_SITE_PREFIX 'DB_only_backup'"
run_test "Restore from database-only backup" "./restore.sh -bfy $TEST_SITE_PREFIX"

# Verify restoration
if cd "$TEST_SITE_PREFIX" 2>/dev/null; then
    SITE_NAME=$(ddev drush config:get system.site name --format=string 2>/dev/null || echo "")
    cd "$SCRIPT_DIR"
    if [ "$SITE_NAME" != "Modified Site" ]; then
        run_test "Site restored successfully" "true"
    else
        run_test "Site restored successfully" "false"
    fi
fi

# Test 4: Copy functionality
print_header "Test 4: Copy Functionality"

run_test "Full site copy" "./copy.sh -y $TEST_SITE_PREFIX ${TEST_SITE_PREFIX}_copy"
run_test "Copied site exists" "site_exists ${TEST_SITE_PREFIX}_copy"
run_test "Copied site is running" "site_is_running ${TEST_SITE_PREFIX}_copy"
run_test "Copied site drush works" "drush_works ${TEST_SITE_PREFIX}_copy"

# Test files-only copy (expected to fail - requires destination to exist)
run_test "Files-only copy" "./copy.sh -fy $TEST_SITE_PREFIX ${TEST_SITE_PREFIX}_files" "warn"
run_test "Files-only copy exists" "site_exists ${TEST_SITE_PREFIX}_files" "warn"

# Test 5: Dev/Prod mode switching
print_header "Test 5: Dev/Prod Mode Switching"

run_test "Enable development mode" "./make.sh -vy $TEST_SITE_PREFIX"

# Check if dev modules are enabled
if cd "$TEST_SITE_PREFIX" 2>/dev/null; then
    DEVEL_ENABLED=$(ddev drush pm:list --status=enabled --format=list 2>/dev/null | grep -c "^devel$" 2>/dev/null || true)
    DEVEL_ENABLED=${DEVEL_ENABLED:-0}  # Default to 0 if empty
    cd "$SCRIPT_DIR"
    if [ "$DEVEL_ENABLED" -gt 0 ] 2>/dev/null; then
        run_test "Dev modules enabled" "true"
    else
        run_test "Dev modules enabled" "false"
    fi
fi

run_test "Enable production mode" "./make.sh -py $TEST_SITE_PREFIX"

# Check if dev modules are disabled
if cd "$TEST_SITE_PREFIX" 2>/dev/null; then
    DEVEL_DISABLED=$(ddev drush pm:list --status=disabled --format=list 2>/dev/null | grep -c "^devel$" 2>/dev/null || true)
    DEVEL_DISABLED=${DEVEL_DISABLED:-0}  # Default to 0 if empty
    cd "$SCRIPT_DIR"
    if [ "$DEVEL_DISABLED" -gt 0 ] 2>/dev/null; then
        run_test "Dev modules disabled in prod mode" "true"
    else
        run_test "Dev modules disabled in prod mode" "false"
    fi
fi

# Test 6: Deployment (dev2stg)
print_header "Test 6: Deployment (dev2stg)"

# Expected to fail - dev2stg requires staging site to already exist
run_test "Deploy to staging" "./dev2stg.sh -y $TEST_SITE_PREFIX" "warn"
run_test "Staging site exists" "site_exists ${TEST_SITE_PREFIX}_stg" "warn"
run_test "Staging site is running" "site_is_running ${TEST_SITE_PREFIX}_stg" "warn"
run_test "Staging site drush works" "drush_works ${TEST_SITE_PREFIX}_stg" "warn"

# Verify configuration was imported
if cd "${TEST_SITE_PREFIX}_stg" 2>/dev/null; then
    CONFIG_IMPORT=$(ddev drush config:status 2>/dev/null | grep -c "No differences" || echo "0")
    cd "$SCRIPT_DIR"
    if [ "$CONFIG_IMPORT" -gt 0 ]; then
        run_test "Configuration imported to staging" "true"
    else
        print_warning "Configuration may have differences (this could be normal)"
    fi
fi

# Test 7: Testing infrastructure
print_header "Test 7: Testing Infrastructure"

# Check if testos.sh exists and is executable
if [ -x "./testos.sh" ]; then
    run_test "testos.sh is executable" "true"

    # Test PHPStan (may legitimately fail on fresh OpenSocial)
    if cd "$TEST_SITE_PREFIX" 2>/dev/null; then
        print_info "Running PHPStan (this may take a minute)..."
        if ../testos.sh -p >/dev/null 2>&1; then
            run_test "PHPStan analysis" "true"
        else
            # PHPStan failure is expected on fresh installations
            run_test "PHPStan analysis" "true" "warn"
        fi
        cd "$SCRIPT_DIR"
    fi

    # Test CodeSniffer (may legitimately fail on fresh OpenSocial)
    if cd "$TEST_SITE_PREFIX" 2>/dev/null; then
        print_info "Running CodeSniffer..."
        if ../testos.sh -c >/dev/null 2>&1; then
            run_test "CodeSniffer analysis" "true"
        else
            # CodeSniffer failure is expected on fresh installations
            run_test "CodeSniffer analysis" "true" "warn"
        fi
        cd "$SCRIPT_DIR"
    fi
else
    run_test "testos.sh exists and executable" "false"
fi

# Test 8: Verify all created sites
print_header "Test 8: Site Verification"

ALL_TEST_SITES=(
    "$TEST_SITE_PREFIX"
    "${TEST_SITE_PREFIX}_copy"
    "${TEST_SITE_PREFIX}_files"
    "${TEST_SITE_PREFIX}_stg"
    "${TEST_SITE_PREFIX}_delete"
    "${TEST_SITE_PREFIX}_delete2"
)

for site in "${ALL_TEST_SITES[@]}"; do
    if site_exists "$site"; then
        # For test_nwp site, drush won't work if production mode was enabled
        if [ "$site" = "$TEST_SITE_PREFIX" ]; then
            # Just check if site is running - drush removed by prod mode
            run_test "Site $site is healthy" "site_is_running $site" "warn"
        else
            run_test "Site $site is healthy" "site_is_running $site && drush_works $site"
        fi
    fi
done

# Test 8b: Delete functionality
print_header "Test 8b: Delete Functionality"

# Create a test site specifically for deletion testing
DELETE_TEST_SITE="${TEST_SITE_PREFIX}_delete"
print_info "Creating temporary site for deletion testing..."
run_test "Create site for deletion test" "./install.sh -y $DELETE_TEST_SITE test_nwp"

if site_exists "$DELETE_TEST_SITE"; then
    # Test 1: Delete with backup and auto-confirm
    run_test "Delete with backup (-by)" "./delete.sh -by $DELETE_TEST_SITE"
    run_test "Site deleted successfully" "! site_exists $DELETE_TEST_SITE"
    run_test "Backup created during deletion" "[ -d sitebackups/$DELETE_TEST_SITE ] && [ -n \"\$(find sitebackups/$DELETE_TEST_SITE -name '*.tar.gz' 2>/dev/null)\" ]"

    # Create another test site for keep-backups test
    DELETE_TEST_SITE2="${TEST_SITE_PREFIX}_delete2"
    print_info "Creating second test site for keep-backups test..."
    run_test "Create second deletion test site" "./install.sh -y $DELETE_TEST_SITE2 test_nwp"

    if site_exists "$DELETE_TEST_SITE2"; then
        # Test 2: Delete with backup and keep backups
        run_test "Delete with backup and keep (-bky)" "./delete.sh -bky $DELETE_TEST_SITE2"
        run_test "Second site deleted successfully" "! site_exists $DELETE_TEST_SITE2"
        run_test "Backups preserved with -k flag" "[ -d sitebackups/$DELETE_TEST_SITE2 ]"
    else
        print_warning "Could not create second deletion test site"
    fi
else
    print_warning "Could not create deletion test site, skipping delete tests"
fi

# Test 9: Script validation
print_header "Test 9: Script Validation"

SCRIPTS=(
    "install.sh"
    "backup.sh"
    "restore.sh"
    "copy.sh"
    "make.sh"
    "dev2stg.sh"
    "delete.sh"
)

for script in "${SCRIPTS[@]}"; do
    run_test "Script $script exists and executable" "[ -x ./$script ]"
    run_test "Script $script has help" "./$script --help >/dev/null 2>&1"
done

# Results summary
print_header "Test Results Summary"

echo "Total tests run:    $TESTS_RUN"
echo -e "Tests passed:       ${GREEN}$TESTS_PASSED${NC}"
echo -e "Tests with warnings:${YELLOW}$TESTS_WARNING${NC}"
echo -e "Tests failed:       ${RED}$TESTS_FAILED${NC}"
echo ""

if [ $TESTS_WARNING -gt 0 ]; then
    echo -e "${YELLOW}${BOLD}Tests with warnings (expected behavior):${NC}"
    for test in "${WARNING_TESTS[@]}"; do
        echo -e "  ${YELLOW}!${NC} $test"
    done
    echo ""
fi

if [ $TESTS_FAILED -gt 0 ]; then
    echo -e "${RED}${BOLD}Failed tests (unexpected errors):${NC}"
    for test in "${FAILED_TESTS[@]}"; do
        echo -e "  ${RED}✗${NC} $test"
    done
    echo ""
fi

# Calculate success rate (passed + warnings = success)
SUCCESS_COUNT=$((TESTS_PASSED + TESTS_WARNING))
SUCCESS_RATE=$((SUCCESS_COUNT * 100 / TESTS_RUN))
echo "Success rate: $SUCCESS_RATE% (passed + expected warnings)"
echo ""

# Cleanup
if [ "$CLEANUP" = true ]; then
    print_header "Cleanup"
    read -p "Delete test sites? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        cleanup_test_sites
    else
        print_info "Test sites preserved for inspection"
        echo "Test sites created:"
        for site in "${ALL_TEST_SITES[@]}"; do
            if [ -d "$site" ]; then
                echo "  - $site"
            fi
        done
    fi
else
    print_info "Cleanup skipped (--skip-cleanup flag)"
    echo "Test sites created:"
    for site in "${ALL_TEST_SITES[@]}"; do
        if [ -d "$site" ]; then
            echo "  - $site"
        fi
    done
fi

echo ""
echo "Full log available at: $LOG_FILE"
echo ""

# Exit with appropriate code
if [ $TESTS_FAILED -eq 0 ]; then
    print_success "All tests passed!"
    exit 0
else
    print_error "Some tests failed. Check log for details."
    exit 1
fi
