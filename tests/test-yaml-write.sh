#!/bin/bash
# Unit Tests for YAML Writing Library
# Tests all functions in lib/yaml-write.sh

# Exit on error
set -e

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
NWP_ROOT="$(dirname "$SCRIPT_DIR")"

# Source the YAML library
source "$NWP_ROOT/lib/yaml-write.sh"

# Test configuration
TEST_DIR="/tmp/test_yaml_write_$$"
TEST_CONFIG="$TEST_DIR/test.cnwp.yml"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

#######################################
# Setup test environment
#######################################
setup() {
    echo -e "${BLUE}Setting up test environment...${NC}"
    mkdir -p "$TEST_DIR"

    # Create a minimal test cnwp.yml
    cat > "$TEST_CONFIG" <<'EOF'
# Test configuration file
settings:
  database: mariadb
  php: 8.2
  delete_site_yml: true

recipes:
  test_recipe:
    source: drupal/recommended-project:^10.2
    profile: standard
    webroot: web
    auto: y
    reinstall_modules: test_module

linode:
  servers:
    test_server:
      ssh_user: deploy
      ssh_host: 192.0.2.1
      ssh_port: 22
      domains:
        - test.example.com

sites:
EOF

    echo -e "${GREEN}Test environment created: $TEST_DIR${NC}\n"
}

#######################################
# Cleanup test environment
#######################################
cleanup() {
    echo -e "\n${BLUE}Cleaning up test environment...${NC}"
    rm -rf "$TEST_DIR"
    echo -e "${GREEN}Cleanup complete${NC}"
}

#######################################
# Run a test
# Arguments:
#   $1 - Test name
#   $2 - Test command
#######################################
run_test() {
    local test_name="$1"
    shift
    local test_command="$@"

    TESTS_RUN=$((TESTS_RUN + 1))
    echo -e "${BLUE}Test $TESTS_RUN: $test_name${NC}"

    if eval "$test_command"; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "${GREEN}✓ PASSED${NC}\n"
        return 0
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "${RED}✗ FAILED${NC}\n"
        return 1
    fi
}

#######################################
# Test: Add a site
#######################################
test_add_site() {
    YAML_CONFIG_FILE="$TEST_CONFIG" yaml_add_site "testsite" "/tmp/testsite" "test_recipe" "development" 2>&1 | grep -q "added"
    return $?
}

#######################################
# Test: Check site exists after adding
#######################################
test_site_exists() {
    YAML_CONFIG_FILE="$TEST_CONFIG" yaml_site_exists "testsite"
    return $?
}

#######################################
# Test: Get site field value
#######################################
test_get_site_field() {
    local directory=$(YAML_CONFIG_FILE="$TEST_CONFIG" yaml_get_site_field "testsite" "directory")
    [[ "$directory" == "/tmp/testsite" ]]
    return $?
}

#######################################
# Test: Get site recipe
#######################################
test_get_site_recipe() {
    local recipe=$(YAML_CONFIG_FILE="$TEST_CONFIG" yaml_get_site_field "testsite" "recipe")
    [[ "$recipe" == "test_recipe" ]]
    return $?
}

#######################################
# Test: Get site environment
#######################################
test_get_site_environment() {
    local env=$(YAML_CONFIG_FILE="$TEST_CONFIG" yaml_get_site_field "testsite" "environment")
    [[ "$env" == "development" ]]
    return $?
}

#######################################
# Test: Verify created timestamp exists
#######################################
test_get_site_created() {
    local created=$(YAML_CONFIG_FILE="$TEST_CONFIG" yaml_get_site_field "testsite" "created")
    [[ -n "$created" ]]
    return $?
}

#######################################
# Test: Update site field
#######################################
test_update_site_field() {
    YAML_CONFIG_FILE="$TEST_CONFIG" yaml_update_site_field "testsite" "environment" "staging" 2>&1 | grep -q "updated"
    local env=$(YAML_CONFIG_FILE="$TEST_CONFIG" yaml_get_site_field "testsite" "environment")
    [[ "$env" == "staging" ]]
    return $?
}

#######################################
# Test: Add modules to site
#######################################
test_add_site_modules() {
    YAML_CONFIG_FILE="$TEST_CONFIG" yaml_add_site_modules "testsite" "devel kint webprofiler" 2>&1 | grep -q "added"
    return $?
}

#######################################
# Test: Get site modules list
#######################################
test_get_site_modules() {
    local modules=$(YAML_CONFIG_FILE="$TEST_CONFIG" yaml_get_site_list "testsite" "installed_modules")
    echo "$modules" | grep -q "devel" && echo "$modules" | grep -q "kint" && echo "$modules" | grep -q "webprofiler"
    return $?
}

#######################################
# Test: Add production config to site
#######################################
test_add_site_production() {
    YAML_CONFIG_FILE="$TEST_CONFIG" yaml_add_site_production "testsite" "rsync" "test_server" "/var/www/testsite" "test.example.com" 2>&1 | grep -q "added"
    return $?
}

#######################################
# Test: Prevent duplicate site addition
#######################################
test_duplicate_prevention() {
    YAML_CONFIG_FILE="$TEST_CONFIG" yaml_add_site "testsite" "/tmp/testsite2" "test_recipe" "development" 2>&1 | grep -q "already exists"
    return $?
}

#######################################
# Test: Add second site
#######################################
test_add_second_site() {
    YAML_CONFIG_FILE="$TEST_CONFIG" yaml_add_site "testsite2" "/tmp/testsite2" "test_recipe" "production" 2>&1 | grep -q "added"
    return $?
}

#######################################
# Test: Both sites exist
#######################################
test_both_sites_exist() {
    YAML_CONFIG_FILE="$TEST_CONFIG" yaml_site_exists "testsite" && YAML_CONFIG_FILE="$TEST_CONFIG" yaml_site_exists "testsite2"
    return $?
}

#######################################
# Test: Remove first site
#######################################
test_remove_site() {
    YAML_CONFIG_FILE="$TEST_CONFIG" yaml_remove_site "testsite" 2>&1 | grep -q "removed"
    return $?
}

#######################################
# Test: Verify site removed
#######################################
test_site_not_exists() {
    ! YAML_CONFIG_FILE="$TEST_CONFIG" yaml_site_exists "testsite"
    return $?
}

#######################################
# Test: Second site still exists
#######################################
test_second_site_remains() {
    YAML_CONFIG_FILE="$TEST_CONFIG" yaml_site_exists "testsite2"
    return $?
}

#######################################
# Test: Backup file creation
#######################################
test_backup_created() {
    local backup_count=$(ls -1 "$TEST_DIR"/*.backup-* 2>/dev/null | wc -l)
    [[ $backup_count -gt 0 ]]
    return $?
}

#######################################
# Test: Error handling - site not found
#######################################
test_error_site_not_found() {
    YAML_CONFIG_FILE="$TEST_CONFIG" yaml_get_site_field "nonexistent" "directory" 2>&1
    [[ $? -ne 0 ]]
    return $?
}

#######################################
# Test: Error handling - missing parameters
#######################################
test_error_missing_params() {
    YAML_CONFIG_FILE="$TEST_CONFIG" yaml_add_site "" "" "" 2>&1 | grep -q "required"
    return $?
}

#######################################
# Display final test results
#######################################
display_results() {
    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}Test Results${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo -e "Total tests run: $TESTS_RUN"
    echo -e "${GREEN}Tests passed: $TESTS_PASSED${NC}"

    if [[ $TESTS_FAILED -gt 0 ]]; then
        echo -e "${RED}Tests failed: $TESTS_FAILED${NC}"
        echo -e "\n${RED}TEST SUITE FAILED${NC}"
        return 1
    else
        echo -e "\n${GREEN}ALL TESTS PASSED!${NC}"
        return 0
    fi
}

#######################################
# Main test execution
#######################################
main() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}YAML Writing Library Unit Tests${NC}"
    echo -e "${BLUE}========================================${NC}\n"

    # Setup
    setup

    # Run tests in sequence
    run_test "Add a site" test_add_site
    run_test "Check site exists" test_site_exists
    run_test "Get site directory field" test_get_site_field
    run_test "Get site recipe field" test_get_site_recipe
    run_test "Get site environment field" test_get_site_environment
    run_test "Get site created timestamp" test_get_site_created
    run_test "Update site field" test_update_site_field
    run_test "Add modules to site" test_add_site_modules
    run_test "Get site modules list" test_get_site_modules
    run_test "Add production config" test_add_site_production
    run_test "Prevent duplicate site" test_duplicate_prevention
    run_test "Add second site" test_add_second_site
    run_test "Both sites exist" test_both_sites_exist
    run_test "Remove first site" test_remove_site
    run_test "Verify site removed" test_site_not_exists
    run_test "Second site still exists" test_second_site_remains
    run_test "Backup files created" test_backup_created
    run_test "Error: site not found" test_error_site_not_found
    run_test "Error: missing parameters" test_error_missing_params

    # Display results
    display_results
    local result=$?

    # Cleanup
    cleanup

    return $result
}

# Run main function
main
exit $?
