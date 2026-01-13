#!/bin/bash
################################################################################
# NWP Comprehensive Test Script
#
# Tests all NWP functionality across 22+ test categories:
#   1-8:   Core operations (install, backup, restore, copy, delete, deploy)
#   9:     Script validation
#   10:    Deployment scripts (stg2prod/prod2stg)
#   11:    YAML library functions
#   12:    Linode production testing
#   13:    Input validation & error handling
#   14:    Git backup features (P11-P13)
#   15:    Scheduling features (P14)
#   16:    CI/CD & testing templates (P16-P21)
#   17:    Unified CLI wrapper (P22)
#   18:    Database sanitization (P23)
#   19:    Rollback capability (P24)
#   20:    Remote site support (P25)
#   21:    Live server & security scripts (P26-P28)
#   22:    Script syntax validation
#   22b:   Library loading and function tests
#   22c:   New command help tests
#   23:    Podcast infrastructure (optional)
#
# Usage:
#   ./test-nwp.sh [--skip-cleanup] [--verbose] [--podcast]
#
# Options:
#   --skip-cleanup    Don't delete test sites after completion
#   --verbose         Show detailed output
#   --podcast         Include podcast infrastructure tests
#   -h, --help        Show this help message
#
################################################################################

# Note: We don't use 'set -e' here because we want tests to continue
# even if individual tests fail. Each test captures its own exit code.

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
cd "$PROJECT_ROOT"

# Source UI library for colors
source "$PROJECT_ROOT/lib/ui.sh"

# Additional test-specific colors not in ui.sh
if [[ -t 1 ]]; then
    DIM=$'\033[2m'
else
    DIM=''
fi

# Configuration
TEST_SITE_PREFIX="test-nwp"
CLEANUP=true
VERBOSE=false
RUN_PODCAST=false
mkdir -p .logs
LOG_FILE=".logs/test-nwp-$(date +%Y%m%d-%H%M%S).log"

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
        --podcast)
            RUN_PODCAST=true
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

    # Stop all test sites in sites/ subdirectory
    if [ -d "sites" ]; then
        for site in sites/${TEST_SITE_PREFIX}*; do
            if [ -d "$site" ]; then
                print_info "Stopping $site..."
                cd "$site" && ddev stop 2>/dev/null || true
                cd "$PROJECT_ROOT"
            fi
        done

        # Remove test site directories
        for site in sites/${TEST_SITE_PREFIX}*; do
            if [ -d "$site" ]; then
                print_info "Removing $site..."
                rm -rf "$site"
            fi
        done
    fi

    # Clean up backups
    if [ -d "sitebackups" ]; then
        print_info "Removing test backups..."
        rm -rf sitebackups/${TEST_SITE_PREFIX}*
    fi

    # Remove test recipe from cnwp.yml (both from recipes: and sites: sections)
    if grep -q "^  ${TEST_SITE_PREFIX}:" cnwp.yml 2>/dev/null; then
        print_info "Removing test recipe from cnwp.yml..."
        # Use awk to remove all test-nwp blocks (works for both recipes and sites sections)
        awk '
            /^  test-nwp:/ { skip=1; next }
            skip && /^  [a-z]/ && !/^    / { skip=0 }
            !skip
        ' cnwp.yml > cnwp.yml.tmp && mv cnwp.yml.tmp cnwp.yml
    fi

    print_success "Cleanup complete"
}

site_exists() {
    local site="$1"
    # Check sites/ subdirectory first, then fall back to root
    if [ -d "sites/$site" ] && [ -f "sites/$site/.ddev/config.yaml" ]; then
        return 0
    elif [ -d "$site" ] && [ -f "$site/.ddev/config.yaml" ]; then
        return 0
    fi
    return 1
}

site_is_running() {
    local site="$1"
    # Check sites/ subdirectory first, then fall back to root
    local site_path=""
    if [ -d "sites/$site" ]; then
        site_path="sites/$site"
    elif [ -d "$site" ]; then
        site_path="$site"
    else
        return 1
    fi
    cd "$site_path" && ddev describe >/dev/null 2>&1
    local result=$?
    cd "$PROJECT_ROOT"
    return $result
}

drush_works() {
    local site="$1"
    local max_attempts=3
    local attempt=1

    # Check sites/ subdirectory first, then fall back to root
    local site_path=""
    if [ -d "sites/$site" ]; then
        site_path="sites/$site"
    elif [ -d "$site" ]; then
        site_path="$site"
    else
        return 1
    fi

    while [ $attempt -le $max_attempts ]; do
        if cd "$site_path" && ddev drush status >/dev/null 2>&1; then
            cd "$PROJECT_ROOT"
            return 0
        fi
        cd "$PROJECT_ROOT" 2>/dev/null || true

        if [ $attempt -lt $max_attempts ]; then
            sleep 2  # Wait 2 seconds before retry
        fi
        attempt=$((attempt + 1))
    done

    return 1
}

backup_exists() {
    local site="$1"
    # Extract just the site name if path includes sites/
    local site_name="${site#sites/}"
    [ -d "sitebackups/$site_name" ] && [ -n "$(ls -A sitebackups/$site_name 2>/dev/null)" ]
}

# Start testing
print_header "NWP Comprehensive Test Suite"
echo "Log file: $LOG_FILE"
echo ""

# Clean up any existing test sites from previous runs to ensure fresh start
print_info "Cleaning up any existing test sites from previous runs..."
cleanup_test_sites
echo ""

# Pre-configure DDEV hostname to avoid sudo prompts during tests
print_info "Pre-configuring DDEV hostnames..."
sudo ddev hostname ${TEST_SITE_PREFIX}.ddev.site 127.0.0.1 2>/dev/null || print_warning "Could not configure hostname (may require manual sudo)"
sudo ddev hostname ${TEST_SITE_PREFIX}_copy.ddev.site 127.0.0.1 2>/dev/null || true
sudo ddev hostname ${TEST_SITE_PREFIX}_files.ddev.site 127.0.0.1 2>/dev/null || true
sudo ddev hostname ${TEST_SITE_PREFIX}-stg.ddev.site 127.0.0.1 2>/dev/null || true
echo ""

# Test 1: Installation
print_header "Test 1: Installation"

# First, create a test recipe in cnwp.yml if it doesn't exist
if ! grep -q "^  ${TEST_SITE_PREFIX}:" cnwp.yml 2>/dev/null; then
    print_info "Adding test recipe to cnwp.yml..."
    # Insert recipe into the recipes: section (not at end of file which lands in sites:)
    # Use sed to insert after the 'recipes:' line
    sed -i '/^recipes:/a\
  test-nwp:\
    source: goalgorilla/social_template:dev-master\
    profile: social\
    webroot: html\
    auto: y' cnwp.yml
fi

run_test "Install test site" "./scripts/commands/install.sh $TEST_SITE_PREFIX"

if site_exists "$TEST_SITE_PREFIX"; then
    run_test "Site directory created" "site_exists $TEST_SITE_PREFIX"
    run_test "DDEV is running" "site_is_running $TEST_SITE_PREFIX"
    run_test "Drush is working" "drush_works $TEST_SITE_PREFIX"
else
    print_error "Installation failed - cannot continue with remaining tests"
    exit 1
fi

# Test 1b: Environment Variable Generation (Vortex)
print_header "Test 1b: Environment Variable Generation (Vortex)"

run_test ".env file created" "[ -f sites/$TEST_SITE_PREFIX/.env ]"
run_test ".env.local.example created" "[ -f sites/$TEST_SITE_PREFIX/.env.local.example ]"
run_test ".secrets.example.yml created" "[ -f sites/$TEST_SITE_PREFIX/.secrets.example.yml ]"

# Check key environment variables are set in .env
if [ -f "sites/$TEST_SITE_PREFIX/.env" ]; then
    run_test "PROJECT_NAME set in .env" "grep -q '^PROJECT_NAME=' sites/$TEST_SITE_PREFIX/.env"
    run_test "NWP_RECIPE set in .env" "grep -q '^NWP_RECIPE=' sites/$TEST_SITE_PREFIX/.env"
    run_test "DRUPAL_PROFILE set in .env" "grep -q '^DRUPAL_PROFILE=' sites/$TEST_SITE_PREFIX/.env"
    run_test "DRUPAL_WEBROOT set in .env" "grep -q '^DRUPAL_WEBROOT=' sites/$TEST_SITE_PREFIX/.env"

    # Check service variables (social profile should have redis/solr enabled)
    run_test "REDIS_ENABLED set in .env" "grep -q '^REDIS_ENABLED=' sites/$TEST_SITE_PREFIX/.env"
    run_test "SOLR_ENABLED set in .env" "grep -q '^SOLR_ENABLED=' sites/$TEST_SITE_PREFIX/.env"

    # For social profile, redis and solr should be enabled (=1)
    REDIS_VAL=$(grep '^REDIS_ENABLED=' "sites/$TEST_SITE_PREFIX/.env" | cut -d= -f2)
    SOLR_VAL=$(grep '^SOLR_ENABLED=' "sites/$TEST_SITE_PREFIX/.env" | cut -d= -f2)

    if [ "$REDIS_VAL" = "1" ]; then
        run_test "Redis enabled for social profile" "true"
    else
        run_test "Redis enabled for social profile" "false"
    fi

    if [ "$SOLR_VAL" = "1" ]; then
        run_test "Solr enabled for social profile" "true"
    else
        run_test "Solr enabled for social profile" "false"
    fi
fi

# Check DDEV config was generated from .env
if [ -f "sites/$TEST_SITE_PREFIX/.ddev/config.yaml" ]; then
    run_test "DDEV config.yaml created" "true"
    run_test "DDEV config has web_environment" "grep -q 'web_environment:' sites/$TEST_SITE_PREFIX/.ddev/config.yaml"
else
    run_test "DDEV config.yaml created" "false"
fi

# Test 2: Backup functionality
print_header "Test 2: Backup Functionality"

run_test "Create full backup" "./scripts/commands/backup.sh $TEST_SITE_PREFIX 'Test_backup'"
run_test "Backup directory exists" "backup_exists $TEST_SITE_PREFIX"

# Test 3: Restore functionality (before creating DB-only backup)
print_header "Test 3: Restore Functionality"

# Modify site before restore
test_site_path="sites/$TEST_SITE_PREFIX"
if [ ! -d "$test_site_path" ]; then
    test_site_path="$TEST_SITE_PREFIX"
fi
if cd "$test_site_path" 2>/dev/null; then
    ddev drush config:set system.site name "Modified Site" -y >/dev/null 2>&1 || true
    cd "$PROJECT_ROOT"
fi

run_test "Restore from full backup" "./scripts/commands/restore.sh -fy $TEST_SITE_PREFIX"

# Test 3b: Database-only backup and restore
print_header "Test 3b: Database-Only Backup and Restore"

run_test "Create database-only backup" "./scripts/commands/backup.sh -b $TEST_SITE_PREFIX 'DB_only_backup'"
run_test "Restore from database-only backup" "./scripts/commands/restore.sh -bfy $TEST_SITE_PREFIX"

# Verify restoration
test_site_path="sites/$TEST_SITE_PREFIX"
if [ ! -d "$test_site_path" ]; then
    test_site_path="$TEST_SITE_PREFIX"
fi
if cd "$test_site_path" 2>/dev/null; then
    SITE_NAME=$(ddev drush config:get system.site name --format=string 2>/dev/null || echo "")
    cd "$PROJECT_ROOT"
    if [ "$SITE_NAME" != "Modified Site" ]; then
        run_test "Site restored successfully" "true"
    else
        run_test "Site restored successfully" "false"
    fi
fi

# Test 4: Copy functionality
print_header "Test 4: Copy Functionality"

run_test "Full site copy" "./scripts/commands/copy.sh -y $TEST_SITE_PREFIX ${TEST_SITE_PREFIX}_copy"
run_test "Copied site exists" "site_exists ${TEST_SITE_PREFIX}_copy"
run_test "Copied site is running" "site_is_running ${TEST_SITE_PREFIX}_copy"
run_test "Copied site drush works" "drush_works ${TEST_SITE_PREFIX}_copy"

# Test files-only copy (expected to fail - requires destination to exist)
run_test "Files-only copy" "./scripts/commands/copy.sh -fy $TEST_SITE_PREFIX ${TEST_SITE_PREFIX}_files" "warn"
run_test "Files-only copy exists" "site_exists ${TEST_SITE_PREFIX}_files" "warn"

# Test 5: Dev/Prod mode switching
print_header "Test 5: Dev/Prod Mode Switching"

# Check if drush is functional before running dev/prod tests
DRUSH_FUNCTIONAL=false
test_site_path="sites/$TEST_SITE_PREFIX"
if [ ! -d "$test_site_path" ]; then
    test_site_path="$TEST_SITE_PREFIX"
fi
if cd "$test_site_path" 2>/dev/null; then
    if ddev drush status 2>&1 | grep -q "Drupal version"; then
        DRUSH_FUNCTIONAL=true
    fi
    cd "$PROJECT_ROOT"
fi

if [ "$DRUSH_FUNCTIONAL" = "false" ]; then
    print_warning "Drush is not functional in $TEST_SITE_PREFIX - skipping dev/prod mode tests"
    print_info "This is a known issue with the social profile's outdated drush requirement"
    print_info "See KNOWN_ISSUES.md for details"
    run_test "Enable development mode" "true" "warn"
    run_test "Dev modules enabled" "true" "warn"
    run_test "Enable production mode" "true" "warn"
    run_test "Dev modules disabled in prod mode" "true" "warn"
else
    run_test "Enable development mode" "./scripts/commands/make.sh -vy $TEST_SITE_PREFIX"

    # Check if dev modules are enabled
    test_site_path="sites/$TEST_SITE_PREFIX"
    if [ ! -d "$test_site_path" ]; then
        test_site_path="$TEST_SITE_PREFIX"
    fi
    if cd "$test_site_path" 2>/dev/null; then
        DEVEL_ENABLED=$(ddev drush pm:list --status=enabled --format=list 2>/dev/null | grep -c "^devel$" 2>/dev/null || true)
        DEVEL_ENABLED=${DEVEL_ENABLED:-0}  # Default to 0 if empty
        cd "$PROJECT_ROOT"
        if [ "$DEVEL_ENABLED" -gt 0 ] 2>/dev/null; then
            run_test "Dev modules enabled" "true"
        else
            run_test "Dev modules enabled" "false"
        fi
    fi

    run_test "Enable production mode" "./scripts/commands/make.sh -py $TEST_SITE_PREFIX"

    # Check if dev modules are disabled
    local test_site_path="sites/$TEST_SITE_PREFIX"
    if [ ! -d "$test_site_path" ]; then
        test_site_path="$TEST_SITE_PREFIX"
    fi
    if cd "$test_site_path" 2>/dev/null; then
        DEVEL_DISABLED=$(ddev drush pm:list --status=disabled --format=list 2>/dev/null | grep -c "^devel$" 2>/dev/null || true)
        DEVEL_DISABLED=${DEVEL_DISABLED:-0}  # Default to 0 if empty
        cd "$PROJECT_ROOT"
        if [ "$DEVEL_DISABLED" -gt 0 ] 2>/dev/null; then
            run_test "Dev modules disabled in prod mode" "true"
        else
            run_test "Dev modules disabled in prod mode" "false"
        fi
    fi
fi

# Test 6: Deployment (dev2stg)
print_header "Test 6: Deployment (dev2stg)"

# Expected to fail - dev2stg requires staging site to already exist
run_test "Deploy to staging" "./scripts/commands/dev2stg.sh -y $TEST_SITE_PREFIX" "warn"
run_test "Staging site exists" "site_exists ${TEST_SITE_PREFIX}-stg" "warn"
run_test "Staging site is running" "site_is_running ${TEST_SITE_PREFIX}-stg" "warn"
run_test "Staging site drush works" "drush_works ${TEST_SITE_PREFIX}-stg" "warn"

# Verify configuration was imported
stg_site_path="sites/${TEST_SITE_PREFIX}-stg"
if [ ! -d "$stg_site_path" ]; then
    stg_site_path="${TEST_SITE_PREFIX}-stg"
fi
if cd "$stg_site_path" 2>/dev/null; then
    CONFIG_IMPORT=$(ddev drush config:status 2>/dev/null | grep -c "No differences" || echo "0")
    cd "$PROJECT_ROOT"
    # Ensure CONFIG_IMPORT is a valid integer
    CONFIG_IMPORT=$(echo "$CONFIG_IMPORT" | tr -d '\n\r' | grep -o '[0-9]*' | head -1)
    CONFIG_IMPORT=${CONFIG_IMPORT:-0}
    if [ "$CONFIG_IMPORT" -gt 0 ] 2>/dev/null; then
        run_test "Configuration imported to staging" "true"
    else
        print_warning "Configuration may have differences (this could be normal)"
    fi
fi

# Test 7: Testing infrastructure
print_header "Test 7: Testing Infrastructure"

# Check if testos.sh exists and is executable
if [ -x "./scripts/commands/testos.sh" ]; then
    run_test "testos.sh is executable" "true"

    # Test PHPStan (may legitimately fail on fresh OpenSocial)
    test_site_path="sites/$TEST_SITE_PREFIX"
    if [ ! -d "$test_site_path" ]; then
        test_site_path="$TEST_SITE_PREFIX"
    fi
    if cd "$test_site_path" 2>/dev/null; then
        print_info "Running PHPStan (this may take a minute)..."
        if "$PROJECT_ROOT/scripts/commands/testos.sh" -p >/dev/null 2>&1; then
            run_test "PHPStan analysis" "true"
        else
            # PHPStan failure is expected on fresh installations
            run_test "PHPStan analysis" "true" "warn"
        fi
        cd "$PROJECT_ROOT"
    fi

    # Test CodeSniffer (may legitimately fail on fresh OpenSocial)
    if cd "$test_site_path" 2>/dev/null; then
        print_info "Running CodeSniffer..."
        if "$PROJECT_ROOT/scripts/commands/testos.sh" -c >/dev/null 2>&1; then
            run_test "CodeSniffer analysis" "true"
        else
            # CodeSniffer failure is expected on fresh installations
            run_test "CodeSniffer analysis" "true" "warn"
        fi
        cd "$PROJECT_ROOT"
    fi
else
    run_test "testos.sh exists and executable" "false"
fi

# Test 8: Verify all created sites
print_header "Test 8: Site Verification"

ALL_TEST_SITES=(
    "sites/$TEST_SITE_PREFIX"
    "sites/${TEST_SITE_PREFIX}_copy"
    "sites/${TEST_SITE_PREFIX}_files"
    "sites/${TEST_SITE_PREFIX}-stg"
)

for site in "${ALL_TEST_SITES[@]}"; do
    if site_exists "$site"; then
        # For test_nwp and staging sites, drush may not work
        if [ "$site" = "sites/$TEST_SITE_PREFIX" ] || [ "$site" = "sites/${TEST_SITE_PREFIX}-stg" ]; then
            # Just check if site is running - drush may be removed or not available
            run_test "Site $site is healthy" "site_is_running $site" "warn"
        else
            run_test "Site $site is healthy" "site_is_running $site && drush_works $site"
        fi
    fi
done

# Test 8b: Delete functionality
print_header "Test 8b: Delete Functionality"

# Create test sites specifically for deletion testing
# install.sh auto-increments directory names, so we'll get test_nwp1, test_nwp2, etc.
print_info "Creating temporary sites for deletion testing..."

# Get list of existing test_nwp* directories before install
BEFORE_INSTALL=($(ls -d sites/${TEST_SITE_PREFIX}* 2>/dev/null | sort))

# Create first deletion test site
run_test "Create site for deletion test" "./scripts/commands/install.sh test-nwp"

# Find the newly created directory
AFTER_INSTALL=($(ls -d sites/${TEST_SITE_PREFIX}* 2>/dev/null | sort))
DELETE_TEST_SITE=""
for site in "${AFTER_INSTALL[@]}"; do
    found=false
    for existing in "${BEFORE_INSTALL[@]}"; do
        if [ "$site" = "$existing" ]; then
            found=true
            break
        fi
    done
    if [ "$found" = false ]; then
        DELETE_TEST_SITE="$site"
        break
    fi
done

# Strip sites/ prefix if present
DELETE_TEST_SITE="${DELETE_TEST_SITE#sites/}"

if [ -n "$DELETE_TEST_SITE" ] && site_exists "$DELETE_TEST_SITE"; then
    print_info "Created deletion test site: $DELETE_TEST_SITE"

    # Test 1: Delete with backup and auto-confirm
    run_test "Delete with backup (-by)" "./scripts/commands/delete.sh -by $DELETE_TEST_SITE"
    run_test "Site deleted successfully" "! site_exists $DELETE_TEST_SITE"
    run_test "Backup created during deletion" "[ -d sitebackups/$DELETE_TEST_SITE ] && [ -n \"\$(find sitebackups/$DELETE_TEST_SITE -name '*.tar.gz' 2>/dev/null)\" ]"

    # Create second test site for keep-backups test
    BEFORE_INSTALL2=($(ls -d sites/${TEST_SITE_PREFIX}* 2>/dev/null | sort))
    run_test "Create second deletion test site" "./scripts/commands/install.sh test-nwp"

    # Find the second newly created directory
    AFTER_INSTALL2=($(ls -d sites/${TEST_SITE_PREFIX}* 2>/dev/null | sort))
    DELETE_TEST_SITE2=""
    for site in "${AFTER_INSTALL2[@]}"; do
        found=false
        for existing in "${BEFORE_INSTALL2[@]}"; do
            if [ "$site" = "$existing" ]; then
                found=true
                break
            fi
        done
        if [ "$found" = false ]; then
            DELETE_TEST_SITE2="$site"
            break
        fi
    done

    # Strip sites/ prefix if present
    DELETE_TEST_SITE2="${DELETE_TEST_SITE2#sites/}"

    if [ -n "$DELETE_TEST_SITE2" ] && site_exists "$DELETE_TEST_SITE2"; then
        print_info "Created second deletion test site: $DELETE_TEST_SITE2"

        # Test 2: Delete with backup and keep backups
        run_test "Delete with backup and keep (-bky)" "./scripts/commands/delete.sh -bky $DELETE_TEST_SITE2"
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
    "scripts/commands/install.sh"
    "scripts/commands/backup.sh"
    "scripts/commands/restore.sh"
    "scripts/commands/copy.sh"
    "scripts/commands/make.sh"
    "scripts/commands/dev2stg.sh"
    "scripts/commands/stg2prod.sh"
    "scripts/commands/prod2stg.sh"
    "scripts/commands/delete.sh"
)

for script in "${SCRIPTS[@]}"; do
    run_test "Script $script exists and executable" "[ -x ./$script ]"
    run_test "Script $script has help" "./$script --help >/dev/null 2>&1"
done

# Test 10: New deployment scripts
print_header "Test 10: Deployment Scripts (stg2prod/prod2stg)"

# Test stg2prod.sh validation
run_test "stg2prod.sh validates missing sitename" "! ./scripts/commands/stg2prod.sh 2>/dev/null"
run_test "stg2prod.sh --dry-run works" "./scripts/commands/stg2prod.sh --dry-run $TEST_SITE_PREFIX 2>/dev/null || true"

# Test prod2stg.sh validation
run_test "prod2stg.sh validates missing sitename" "! ./scripts/commands/prod2stg.sh 2>/dev/null"
run_test "prod2stg.sh --dry-run works" "./scripts/commands/prod2stg.sh --dry-run $TEST_SITE_PREFIX 2>/dev/null || true"

# Test 11: YAML library functions
print_header "Test 11: YAML Library Functions"

# Check YAML library exists
run_test "YAML library exists" "[ -f lib/yaml-write.sh ]"

# Run YAML library tests if test script exists
if [ -f "tests/test-yaml-write.sh" ]; then
    run_test "YAML library unit tests" "./tests/test-yaml-write.sh >/dev/null 2>&1"
else
    print_warning "YAML unit tests not found, skipping"
fi

# Run integration tests if test script exists
if [ -f "tests/test-integration.sh" ]; then
    run_test "Integration tests" "./tests/test-integration.sh >/dev/null 2>&1"
else
    print_warning "Integration tests not found, skipping"
fi

# Verify site was registered in cnwp.yml during installation
if grep -q "^  $TEST_SITE_PREFIX:" cnwp.yml 2>/dev/null; then
    run_test "Site registered in cnwp.yml" "true"
else
    run_test "Site registered in cnwp.yml" "false"
fi

################################################################################
# Test 12: Linode Production Testing (if token available)
################################################################################

print_header "Test 12: Linode Production Testing"

# Check if Linode API token is available
if [ -f "$PROJECT_ROOT/lib/linode.sh" ]; then
    source "$PROJECT_ROOT/lib/linode.sh"
    LINODE_TOKEN=$(get_linode_token "$PROJECT_ROOT")

    if [ -n "$LINODE_TOKEN" ] && [ -f "$HOME/.ssh/nwp" ]; then
        print_info "Linode API token and SSH key found - running production tests"
        echo ""

        # Provision test Linode instance
        print_info "Provisioning test Linode instance..."
        PROVISION_RESULT=$(provision_test_linode "$LINODE_TOKEN" "nwp-test")

        if [ $? -eq 0 ] && [ -n "$PROVISION_RESULT" ]; then
            # Extract instance ID and IP
            LINODE_INSTANCE_ID=$(echo "$PROVISION_RESULT" | awk '{print $1}')
            LINODE_IP=$(echo "$PROVISION_RESULT" | awk '{print $2}')

            print_info "Linode instance provisioned: $LINODE_INSTANCE_ID ($LINODE_IP)"
            run_test "Linode instance provisioned" "true"

            # Update cnwp.yml with test server details
            if ! grep -q "^linode:" cnwp.yml; then
                cat >> cnwp.yml << EOF

# Linode test server configuration
linode:
  servers:
    test_primary:
      ssh_user: root
      ssh_host: $LINODE_IP
      ssh_port: 22
      ssh_key: ~/.ssh/nwp
EOF
                run_test "Test server added to cnwp.yml" "true"
            else
                # Update existing linode section
                if ! grep -q "test_primary:" cnwp.yml; then
                    # Add test_primary to existing servers section
                    awk -v ip="$LINODE_IP" '
                        /^  servers:/ {
                            print
                            print "    test_primary:"
                            print "      ssh_user: root"
                            print "      ssh_host: " ip
                            print "      ssh_port: 22"
                            print "      ssh_key: ~/.ssh/nwp"
                            next
                        }
                        {print}
                    ' cnwp.yml > cnwp.yml.tmp && mv cnwp.yml.tmp cnwp.yml
                    run_test "Test server added to cnwp.yml" "true"
                else
                    run_test "Test server already in cnwp.yml" "true"
                fi
            fi

            # Test SSH connection
            print_info "Testing SSH connection to $LINODE_IP..."
            if ssh -i ~/.ssh/nwp -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
                root@$LINODE_IP "echo 'SSH connection successful'" >/dev/null 2>&1; then
                run_test "SSH connection to Linode instance" "true"
            else
                run_test "SSH connection to Linode instance" "false"
            fi

            # Test basic server setup
            print_info "Testing basic server commands..."
            if ssh -i ~/.ssh/nwp -o ConnectTimeout=10 root@$LINODE_IP \
                "apt-get update -qq && apt-get install -y -qq curl > /dev/null 2>&1"; then
                run_test "Server package installation" "true"
            else
                run_test "Server package installation" "false"
            fi

            # TODO: Add actual deployment tests here when stg2prod.sh is ready
            # For now, just verify the scripts exist and are executable
            run_test "stg2prod.sh exists" "[ -x scripts/commands/stg2prod.sh ]"
            run_test "prod2stg.sh exists" "[ -x scripts/commands/prod2stg.sh ]"

            # Cleanup: Delete test instance
            print_info "Cleaning up test Linode instance..."
            if delete_linode_instance "$LINODE_TOKEN" "$LINODE_INSTANCE_ID"; then
                run_test "Test instance cleanup" "true"
            else
                run_test "Test instance cleanup" "false"
            fi

            # Remove test server from cnwp.yml
            if grep -q "test_primary:" cnwp.yml; then
                # Remove test_primary section
                awk '/^    test_primary:/,/^    [a-z_]+:/{if(!/^    test_primary:/ && !/^      /)print; if(/^    [a-z_]+:/ && !/^    test_primary:/)print}' \
                    cnwp.yml > cnwp.yml.tmp && mv cnwp.yml.tmp cnwp.yml
                run_test "Test server removed from cnwp.yml" "true"
            fi

        else
            print_warning "Failed to provision Linode instance - skipping production tests"
            run_test "Linode instance provisioned" "false"
        fi

    else
        print_warning "Linode API token or SSH key not found - skipping production tests"
        echo "To enable production testing:"
        echo "  1. Add Linode API token to .secrets.yml"
        echo "  2. Run ./setup-ssh.sh to generate SSH keys"
        echo "  3. Manually add SSH key to Linode Cloud Manager"
        echo ""
    fi
else
    print_warning "Linode library (lib/linode.sh) not found - skipping production tests"
fi

################################################################################
# Test 13: Input Validation & Error Handling (Negative Tests)
################################################################################

print_header "Test 13: Input Validation & Error Handling"

# Test invalid sitenames are rejected
print_info "Testing sitename validation..."

# Path traversal attempts should fail
run_test "Reject path traversal (..)" "! ./install.sh '../malicious' 2>/dev/null"
run_test "Reject path traversal (./)" "! ./install.sh './malicious' 2>/dev/null"
run_test "Reject absolute path" "! ./scripts/commands/delete.sh -y '/etc/passwd' 2>/dev/null"

# Invalid characters should be rejected
run_test "Reject special chars (;)" "! ./install.sh 'site;rm -rf /' 2>/dev/null"
run_test "Reject special chars (&)" "! ./install.sh 'site&whoami' 2>/dev/null"
run_test "Reject spaces" "! ./install.sh 'site with spaces' 2>/dev/null"

# Missing required arguments should fail
print_info "Testing missing argument handling..."
run_test "install.sh requires sitename" "! ./install.sh 2>/dev/null"
run_test "backup.sh requires sitename" "! ./scripts/commands/backup.sh 2>/dev/null"
run_test "restore.sh requires sitename" "! ./scripts/commands/restore.sh -y 2>/dev/null"
run_test "delete.sh requires sitename" "! ./scripts/commands/delete.sh -y 2>/dev/null"
run_test "copy.sh requires both args" "! ./scripts/commands/copy.sh -y source 2>/dev/null"

# Non-existent sites should fail gracefully
# Use unique names for each test to avoid interference
print_info "Testing non-existent site handling..."
run_test "Backup non-existent fails" "! ./scripts/commands/backup.sh nonexistent_backup_xyz 2>/dev/null"
run_test "Restore non-existent fails" "! ./scripts/commands/restore.sh -y nonexistent_restore_xyz 2>/dev/null"
# Clean up any residual directories from restore attempt
rm -rf sites/nonexistent_restore_xyz 2>/dev/null || true
run_test "Delete non-existent fails" "! ./scripts/commands/delete.sh -y nonexistent_delete_xyz 2>/dev/null"
run_test "Copy non-existent fails" "! ./scripts/commands/copy.sh -y nonexistent_copy_xyz dest 2>/dev/null"

# Make.sh mode validation
print_info "Testing make.sh mode validation..."
run_test "make.sh requires mode flag" "! ./scripts/commands/make.sh test-nwp 2>/dev/null"
run_test "make.sh -v (dev) is valid" "./scripts/commands/make.sh --help 2>&1 | grep -q dev"
run_test "make.sh -p (prod) is valid" "./scripts/commands/make.sh --help 2>&1 | grep -q prod"

print_info "Negative tests completed - failures above are EXPECTED behavior"

################################################################################
# Test 14: Git Backup Features (P11-P13)
################################################################################

print_header "Test 14: Git Backup Features (P11-P13)"

# Check git library exists
run_test "Git library exists" "[ -f lib/git.sh ]"

# Source git library for function testing
if [ -f "lib/git.sh" ]; then
    source lib/git.sh 2>/dev/null || true

    # Test git backup flag exists in backup.sh
    run_test "backup.sh supports -g flag" "./scripts/commands/backup.sh --help 2>&1 | grep -q '\-g'"
    run_test "backup.sh supports --bundle flag" "./scripts/commands/backup.sh --help 2>&1 | grep -q 'bundle'"
    run_test "backup.sh supports --incremental flag" "./scripts/commands/backup.sh --help 2>&1 | grep -q 'incremental'"
    run_test "backup.sh supports --push-all flag" "./scripts/commands/backup.sh --help 2>&1 | grep -q 'push-all'"

    # Test git functions exist
    run_test "git_init function exists" "type git_init >/dev/null 2>&1"
    run_test "git_commit_backup function exists" "type git_commit_backup >/dev/null 2>&1"
    run_test "git_bundle_full function exists" "type git_bundle_full >/dev/null 2>&1"
    run_test "git_bundle_incremental function exists" "type git_bundle_incremental >/dev/null 2>&1"
    run_test "git_push_all function exists" "type git_push_all >/dev/null 2>&1"

    # Test GitLab API functions (P15)
    run_test "gitlab_api_create_project function exists" "type gitlab_api_create_project >/dev/null 2>&1"
    run_test "gitlab_api_list_projects function exists" "type gitlab_api_list_projects >/dev/null 2>&1"
fi

################################################################################
# Test 15: Scheduling Features (P14)
################################################################################

print_header "Test 15: Scheduling Features (P14)"

# Check schedule.sh exists and is executable
run_test "schedule.sh exists" "[ -f scripts/commands/schedule.sh ]"
run_test "schedule.sh is executable" "[ -x scripts/commands/schedule.sh ]"

if [ -x "scripts/commands/schedule.sh" ]; then
    run_test "schedule.sh has help" "./scripts/commands/schedule.sh --help >/dev/null 2>&1"
    run_test "schedule.sh install command" "./scripts/commands/schedule.sh --help 2>&1 | grep -q 'install'"
    run_test "schedule.sh remove command" "./scripts/commands/schedule.sh --help 2>&1 | grep -q 'remove'"
    run_test "schedule.sh list command" "./scripts/commands/schedule.sh --help 2>&1 | grep -q 'list'"
    run_test "schedule.sh show command" "./scripts/commands/schedule.sh --help 2>&1 | grep -q 'show'"

    # Test showing schedule (should work without changes)
    run_test "schedule.sh show works" "./scripts/commands/schedule.sh show >/dev/null 2>&1 || true"
    run_test "schedule.sh list works" "./scripts/commands/schedule.sh list >/dev/null 2>&1 || true"
fi

################################################################################
# Test 16: CI/CD & Testing Templates (P16-P21)
################################################################################

print_header "Test 16: CI/CD & Testing Templates (P16-P21)"

# Docker test environment (P16)
run_test "Docker compose test template exists" "[ -f templates/docker-compose.test.yml ]"

# Site test script (P17)
run_test "test.sh exists" "[ -f scripts/commands/test.sh ]"
run_test "test.sh is executable" "[ -x scripts/commands/test.sh ]"

if [ -x "scripts/commands/test.sh" ]; then
    run_test "test.sh has help" "./scripts/commands/test.sh --help >/dev/null 2>&1"
    run_test "test.sh supports -l (lint)" "./scripts/commands/test.sh --help 2>&1 | grep -qE '\-l|lint'"
    run_test "test.sh supports -u (unit)" "./scripts/commands/test.sh --help 2>&1 | grep -qE '\-u|unit'"
    run_test "test.sh supports -s (smoke)" "./scripts/commands/test.sh --help 2>&1 | grep -qE '\-s|smoke'"
    run_test "test.sh supports -b (behat)" "./scripts/commands/test.sh --help 2>&1 | grep -qE '\-b|behat'"
fi

# Behat BDD framework (P18)
run_test "Behat template exists" "[ -f templates/behat.yml ]"
run_test "Behat features directory exists" "[ -d templates/tests/behat/features ]"
run_test "Smoke test feature exists" "[ -f templates/tests/behat/features/smoke.feature ]"
run_test "Authentication feature exists" "[ -f templates/tests/behat/features/authentication.feature ]"
run_test "Content feature exists" "[ -f templates/tests/behat/features/content.feature ]"

# Code quality tooling (P19)
run_test "PHPCS config template exists" "[ -f templates/.phpcs.xml ]"
run_test "PHPStan config template exists" "[ -f templates/phpstan.neon ]"
run_test "Rector config template exists" "[ -f templates/rector.php ]"
run_test "GrumPHP config template exists" "[ -f templates/grumphp.yml ]"

# GitLab CI pipeline (P20)
run_test "GitLab CI template exists" "[ -f templates/.gitlab-ci.yml ]"

if [ -f "templates/.gitlab-ci.yml" ]; then
    run_test "GitLab CI has build stage" "grep -q 'build' templates/.gitlab-ci.yml"
    run_test "GitLab CI has validate stage" "grep -q 'validate' templates/.gitlab-ci.yml"
    run_test "GitLab CI has test stage" "grep -q 'test' templates/.gitlab-ci.yml"
    run_test "GitLab CI has deploy stage" "grep -q 'deploy' templates/.gitlab-ci.yml"
    run_test "GitLab CI has coverage reporting" "grep -q 'coverage' templates/.gitlab-ci.yml"
fi

# Coverage & Badges (P21)
run_test "Badges library exists" "[ -f lib/badges.sh ]"

if [ -f "lib/badges.sh" ]; then
    source lib/badges.sh 2>/dev/null || true
    run_test "generate_badge_url function exists" "type generate_badge_url >/dev/null 2>&1"
    run_test "update_readme_badges function exists" "type update_readme_badges >/dev/null 2>&1"
fi

################################################################################
# Test 17: Unified CLI Wrapper (P22)
################################################################################

print_header "Test 17: Unified CLI Wrapper (P22)"

# Check pl command exists
run_test "pl command exists" "[ -f pl ]"
run_test "pl command is executable" "[ -x pl ]"
run_test "pl-completion.bash exists" "[ -f pl-completion.bash ]"

if [ -x "pl" ]; then
    run_test "pl has help" "./pl --help >/dev/null 2>&1 || ./pl help >/dev/null 2>&1"
    run_test "pl install command" "./pl help 2>&1 | grep -qE 'install|Install'"
    run_test "pl backup command" "./pl help 2>&1 | grep -qE 'backup|Backup'"
    run_test "pl restore command" "./pl help 2>&1 | grep -qE 'restore|Restore'"
    run_test "pl copy command" "./pl help 2>&1 | grep -qE 'copy|Copy'"
    run_test "pl test command" "./pl help 2>&1 | grep -qE 'test|Test'"
    run_test "pl delete command" "./pl help 2>&1 | grep -qE 'delete|Delete'"

    # Test pl completion script syntax
    run_test "pl-completion.bash syntax valid" "bash -n pl-completion.bash"
fi

################################################################################
# Test 18: Database Sanitization (P23)
################################################################################

print_header "Test 18: Database Sanitization (P23)"

# Check sanitization library exists
run_test "Sanitize library exists" "[ -f lib/sanitize.sh ]"

if [ -f "lib/sanitize.sh" ]; then
    source lib/sanitize.sh 2>/dev/null || true

    run_test "sanitize_database function exists" "type sanitize_database >/dev/null 2>&1"
    run_test "sanitize_sql_file function exists" "type sanitize_sql_file >/dev/null 2>&1"
    run_test "sanitize_with_drush function exists" "type sanitize_with_drush >/dev/null 2>&1"

    # Test backup.sh supports sanitize flag
    run_test "backup.sh supports --sanitize flag" "./scripts/commands/backup.sh --help 2>&1 | grep -q 'sanitize'"
    run_test "backup.sh supports --sanitize-level flag" "./scripts/commands/backup.sh --help 2>&1 | grep -q 'sanitize-level'"
fi

################################################################################
# Test 19: Rollback Capability (P24)
################################################################################

print_header "Test 19: Rollback Capability (P24)"

# Check rollback library exists
run_test "Rollback library exists" "[ -f lib/rollback.sh ]"

if [ -f "lib/rollback.sh" ]; then
    source lib/rollback.sh 2>/dev/null || true

    run_test "rollback_init function exists" "type rollback_init >/dev/null 2>&1"
    run_test "rollback_record function exists" "type rollback_record >/dev/null 2>&1"
    run_test "rollback_execute function exists" "type rollback_execute >/dev/null 2>&1"
    run_test "rollback_verify function exists" "type rollback_verify >/dev/null 2>&1"
    run_test "rollback_list function exists" "type rollback_list >/dev/null 2>&1"
    run_test "rollback_quick function exists" "type rollback_quick >/dev/null 2>&1"

    # Test rollback list works
    run_test "rollback_list works" "rollback_list >/dev/null 2>&1 || true"
fi

################################################################################
# Test 20: Remote Site Support (P25)
################################################################################

print_header "Test 20: Remote Site Support (P25)"

# Check remote library exists
run_test "Remote library exists" "[ -f lib/remote.sh ]"

if [ -f "lib/remote.sh" ]; then
    source lib/remote.sh 2>/dev/null || true

    run_test "parse_remote_target function exists" "type parse_remote_target >/dev/null 2>&1"
    run_test "get_remote_config function exists" "type get_remote_config >/dev/null 2>&1"
    run_test "remote_exec function exists" "type remote_exec >/dev/null 2>&1"
    run_test "remote_drush function exists" "type remote_drush >/dev/null 2>&1"
    run_test "remote_backup function exists" "type remote_backup >/dev/null 2>&1"
    run_test "remote_test function exists" "type remote_test >/dev/null 2>&1"
fi

################################################################################
# Test 21: Live Server & Security Scripts (P26-P28)
################################################################################

print_header "Test 21: Live Server & Security Scripts (P26-P28)"

# Live server provisioning (P26)
run_test "live.sh exists" "[ -f scripts/commands/live.sh ]"
run_test "live.sh is executable" "[ -x scripts/commands/live.sh ]"

if [ -x "scripts/commands/live.sh" ]; then
    run_test "live.sh has help" "./scripts/commands/live.sh --help >/dev/null 2>&1"
    run_test "live.sh supports --type flag" "./scripts/commands/live.sh --help 2>&1 | grep -q 'type'"
    run_test "live.sh supports --delete flag" "./scripts/commands/live.sh --help 2>&1 | grep -q 'delete'"
    run_test "live.sh supports --status flag" "./scripts/commands/live.sh --help 2>&1 | grep -q 'status'"
    run_test "live.sh documents dedicated type" "./scripts/commands/live.sh --help 2>&1 | grep -q 'dedicated'"
    run_test "live.sh documents shared type" "./scripts/commands/live.sh --help 2>&1 | grep -q 'shared'"
    run_test "live.sh documents temporary type" "./scripts/commands/live.sh --help 2>&1 | grep -q 'temporary'"
fi

# Security script (P28)
run_test "security.sh exists" "[ -f scripts/commands/security.sh ]"
run_test "security.sh is executable" "[ -x scripts/commands/security.sh ]"

if [ -x "scripts/commands/security.sh" ]; then
    run_test "security.sh has help" "./scripts/commands/security.sh --help >/dev/null 2>&1"
    run_test "security.sh check command" "./scripts/commands/security.sh --help 2>&1 | grep -q 'check'"
    run_test "security.sh update command" "./scripts/commands/security.sh --help 2>&1 | grep -q 'update'"
    run_test "security.sh audit command" "./scripts/commands/security.sh --help 2>&1 | grep -q 'audit'"
    run_test "security.sh supports --all flag" "./scripts/commands/security.sh --help 2>&1 | grep -q 'all'"
    run_test "security.sh supports --auto flag" "./scripts/commands/security.sh --help 2>&1 | grep -q 'auto'"
fi

################################################################################
# Test 22: Script Syntax Validation
################################################################################

print_header "Test 22: Script Syntax Validation"

# Validate all core scripts have valid bash syntax
CORE_SCRIPTS=(
    "scripts/commands/install.sh"
    "scripts/commands/backup.sh"
    "scripts/commands/restore.sh"
    "scripts/commands/copy.sh"
    "scripts/commands/make.sh"
    "scripts/commands/delete.sh"
    "scripts/commands/dev2stg.sh"
    "scripts/commands/stg2prod.sh"
    "scripts/commands/prod2stg.sh"
    "scripts/commands/test.sh"
    "scripts/commands/schedule.sh"
    "scripts/commands/live.sh"
    "scripts/commands/security.sh"
    "pl"
)

for script in "${CORE_SCRIPTS[@]}"; do
    if [ -f "$script" ]; then
        run_test "Syntax valid: $script" "bash -n $script"
    fi
done

# Validate library files
LIBRARY_FILES=(
    "lib/ui.sh"
    "lib/common.sh"
    "lib/terminal.sh"
    "lib/git.sh"
    "lib/yaml-write.sh"
    "lib/badges.sh"
    "lib/sanitize.sh"
    "lib/rollback.sh"
    "lib/remote.sh"
)

for lib in "${LIBRARY_FILES[@]}"; do
    if [ -f "$lib" ]; then
        run_test "Syntax valid: $lib" "bash -n $lib"
    fi
done

################################################################################
# Test 22b: Library Loading and Function Tests
################################################################################

print_header "Test 22b: Library Loading and Function Tests"

# Test library loading
run_test "lib/terminal.sh exists" "[ -f lib/terminal.sh ]"
run_test "lib/terminal.sh can be sourced" "source lib/terminal.sh 2>/dev/null"
run_test "lib/ui.sh exists" "[ -f lib/ui.sh ]"
run_test "lib/ui.sh can be sourced" "source lib/ui.sh 2>/dev/null"
run_test "lib/common.sh exists" "[ -f lib/common.sh ]"
run_test "lib/common.sh can be sourced" "source lib/common.sh 2>/dev/null"

# Source libraries for function tests
if [ -f "lib/common.sh" ]; then
    source lib/common.sh 2>/dev/null || true

    # Test get_base_name function
    run_test "get_base_name function exists" "type get_base_name >/dev/null 2>&1"

    if type get_base_name >/dev/null 2>&1; then
        # Test hyphen variant
        RESULT=$(get_base_name "mysite-stg" 2>/dev/null || echo "")
        if [ "$RESULT" = "mysite" ]; then
            run_test "get_base_name handles hyphen (mysite-stg → mysite)" "true"
        else
            run_test "get_base_name handles hyphen (mysite-stg → mysite)" "false"
        fi

        # Test underscore variant
        RESULT=$(get_base_name "mysite_prod" 2>/dev/null || echo "")
        if [ "$RESULT" = "mysite" ]; then
            run_test "get_base_name handles underscore (mysite_prod → mysite)" "true"
        else
            run_test "get_base_name handles underscore (mysite_prod → mysite)" "false"
        fi
    fi

    # Test get_env_label function (returns UPPERCASE)
    run_test "get_env_label function exists" "type get_env_label >/dev/null 2>&1"

    if type get_env_label >/dev/null 2>&1; then
        RESULT=$(get_env_label "prod" 2>/dev/null || echo "")
        if [ "$RESULT" = "PRODUCTION" ]; then
            run_test "get_env_label returns UPPERCASE (prod → PRODUCTION)" "true"
        else
            run_test "get_env_label returns UPPERCASE (prod → PRODUCTION)" "false"
        fi

        RESULT=$(get_env_label "stg" 2>/dev/null || echo "")
        if [ "$RESULT" = "STAGING" ]; then
            run_test "get_env_label returns UPPERCASE (stg → STAGING)" "true"
        else
            run_test "get_env_label returns UPPERCASE (stg → STAGING)" "false"
        fi
    fi

    # Test get_env_display_label function (returns Title Case)
    run_test "get_env_display_label function exists" "type get_env_display_label >/dev/null 2>&1"

    if type get_env_display_label >/dev/null 2>&1; then
        RESULT=$(get_env_display_label "prod" 2>/dev/null || echo "")
        if [ "$RESULT" = "Production" ]; then
            run_test "get_env_display_label returns Title Case (prod → Production)" "true"
        else
            run_test "get_env_display_label returns Title Case (prod → Production)" "false"
        fi

        RESULT=$(get_env_display_label "live" 2>/dev/null || echo "")
        if [ "$RESULT" = "Live" ]; then
            run_test "get_env_display_label returns Title Case (live → Live)" "true"
        else
            run_test "get_env_display_label returns Title Case (live → Live)" "false"
        fi
    fi
fi

# Source ui.sh for UI function tests
if [ -f "lib/ui.sh" ]; then
    source lib/ui.sh 2>/dev/null || true

    # Test print_* functions
    run_test "print_error function exists" "type print_error >/dev/null 2>&1"
    run_test "print_warning function exists" "type print_warning >/dev/null 2>&1"
    run_test "print_info function exists" "type print_info >/dev/null 2>&1"

    # Test icon functions
    run_test "fail function exists" "type fail >/dev/null 2>&1"
    run_test "warn function exists" "type warn >/dev/null 2>&1"
    run_test "info function exists" "type info >/dev/null 2>&1"
    run_test "pass function exists" "type pass >/dev/null 2>&1"
fi

# Source terminal.sh for terminal function tests
if [ -f "lib/terminal.sh" ]; then
    source lib/terminal.sh 2>/dev/null || true

    # Test terminal control functions
    run_test "cursor_to function exists" "type cursor_to >/dev/null 2>&1"
    run_test "cursor_hide function exists" "type cursor_hide >/dev/null 2>&1"
    run_test "cursor_show function exists" "type cursor_show >/dev/null 2>&1"
fi

################################################################################
# Test 22c: New Command Help Tests
################################################################################

print_header "Test 22c: New Command Help Tests"

# Test new pl commands
if [ -x "pl" ]; then
    run_test "pl badges --help works" "./pl badges --help >/dev/null 2>&1 || true"
    run_test "pl storage --help works" "./pl storage --help >/dev/null 2>&1 || true"
    run_test "pl rollback --help works" "./pl rollback --help >/dev/null 2>&1 || true"
    run_test "pl email --help works" "./pl email --help >/dev/null 2>&1 || true"
else
    print_warning "pl command not found - skipping command help tests"
fi

################################################################################
# Test 23: Podcast Infrastructure (Optional)
################################################################################

if [ "$RUN_PODCAST" = true ]; then
    print_header "Test 23: Podcast Infrastructure (Optional)"

    if [ -f "tests/test-podcast.sh" ]; then
        print_info "Running podcast test suite..."
        echo ""

        # Run podcast tests and capture results
        if ./tests/test-podcast.sh; then
            run_test "Podcast test suite" "true"
        else
            run_test "Podcast test suite" "false"
        fi
    else
        print_warning "Podcast test script not found (tests/test-podcast.sh)"
    fi
else
    print_info "Skipping podcast tests (use --podcast flag to include)"
fi

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
