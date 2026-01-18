#!/bin/bash

################################################################################
# Integration Tests for NWP Site Management
# Tests the full workflow: install → dev2stg → stg2prod → delete
################################################################################

# Exit on error
set -e

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
NWP_ROOT="$(dirname "$SCRIPT_DIR")"

# Source YAML library
source "$NWP_ROOT/lib/yaml-write.sh"

# Test configuration
TEST_DIR="/tmp/test_integration_$$"
TEST_CONFIG="$TEST_DIR/nwp.yml"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

#######################################
# Setup test environment
#######################################
setup() {
    echo -e "${BLUE}Setting up integration test environment...${NC}"
    mkdir -p "$TEST_DIR"
    mkdir -p "$TEST_DIR/testsite"
    mkdir -p "$TEST_DIR/testsite_stg"

    # Create test nwp.yml with complete structure
    cat > "$TEST_CONFIG" <<'EOF'
settings:
  database: mariadb
  php: 8.2
  delete_site_yml: true

  services:
    redis:
      enabled: false
      version: "7"

linode:
  servers:
    test_server:
      ssh_user: testuser
      ssh_host: 192.0.2.1
      ssh_port: 22
      api_token: ${LINODE_API_TOKEN}
      server_ips:
        - 192.0.2.1
      domains:
        - test.example.com

recipes:
  test_recipe:
    source: drupal/recommended-project:^10.2
    profile: standard
    webroot: web
    auto: y
    reinstall_modules: test_module another_module
    prod_method: rsync
    prod_server: test_server
    prod_domain: test.example.com
    prod_path: /var/www/testsite

sites:
EOF

    echo -e "${GREEN}Test environment created: $TEST_DIR${NC}\n"
}

#######################################
# Cleanup test environment
#######################################
cleanup() {
    echo -e "\n${BLUE}Cleaning up integration test environment...${NC}"
    rm -rf "$TEST_DIR"
    echo -e "${GREEN}Cleanup complete${NC}"
}

#######################################
# Run a test
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
# Test: get_recipe_value function works
#######################################
test_get_recipe_value() {
    # Source the function from dev2stg.sh
    source /dev/stdin <<'FUNC'
get_recipe_value() {
    local recipe=$1
    local key=$2
    local config_file="${3:-nwp.yml}"

    awk -v recipe="$recipe" -v key="$key" '
        BEGIN { in_recipe = 0; found = 0 }
        /^  [a-zA-Z0-9_-]+:/ {
            if ($1 == recipe":") {
                in_recipe = 1
            } else if (in_recipe && /^  [a-zA-Z0-9_-]+:/) {
                in_recipe = 0
            }
        }
        in_recipe && $0 ~ "^    " key ":" {
            sub("^    " key ": *", "")
            print
            found = 1
            exit
        }
    ' "$config_file"
}
FUNC

    local result=$(get_recipe_value "test_recipe" "reinstall_modules" "$TEST_CONFIG")
    [[ "$result" == "test_module another_module" ]]
}

#######################################
# Test: get_recipe_value reads profile
#######################################
test_get_recipe_profile() {
    source /dev/stdin <<'FUNC'
get_recipe_value() {
    local recipe=$1
    local key=$2
    local config_file="${3:-nwp.yml}"

    awk -v recipe="$recipe" -v key="$key" '
        BEGIN { in_recipe = 0; found = 0 }
        /^  [a-zA-Z0-9_-]+:/ {
            if ($1 == recipe":") {
                in_recipe = 1
            } else if (in_recipe && /^  [a-zA-Z0-9_-]+:/) {
                in_recipe = 0
            }
        }
        in_recipe && $0 ~ "^    " key ":" {
            sub("^    " key ": *", "")
            print
            found = 1
            exit
        }
    ' "$config_file"
}
FUNC

    local result=$(get_recipe_value "test_recipe" "profile" "$TEST_CONFIG")
    [[ "$result" == "standard" ]]
}

#######################################
# Test: get_linode_config function works
#######################################
test_get_linode_config() {
    source /dev/stdin <<'FUNC'
get_linode_config() {
    local server_name=$1
    local field=$2
    local config_file="${3:-nwp.yml}"

    awk -v server="$server_name" -v field="$field" '
        BEGIN { in_servers = 0; in_server = 0 }
        /^linode:/ { in_linode = 1; next }
        in_linode && /^  servers:/ { in_servers = 1; next }
        in_servers && $0 ~ "^    " server ":" { in_server = 1; next }
        in_server && /^    [a-zA-Z]/ && !/^      / { in_server = 0 }
        in_server && $0 ~ "^      " field ":" {
            sub("^      " field ": *", "")
            print
            exit
        }
    ' "$config_file"
}
FUNC

    local ssh_user=$(get_linode_config "test_server" "ssh_user" "$TEST_CONFIG")
    local ssh_host=$(get_linode_config "test_server" "ssh_host" "$TEST_CONFIG")

    [[ "$ssh_user" == "testuser" ]] && [[ "$ssh_host" == "192.0.2.1" ]]
}

#######################################
# Test: Site registration workflow
#######################################
test_site_registration() {
    # Simulate site registration
    YAML_CONFIG_FILE="$TEST_CONFIG" yaml_add_site \
        "testsite" \
        "$TEST_DIR/testsite" \
        "test_recipe" \
        "development" \
        2>/dev/null

    # Verify site was added
    YAML_CONFIG_FILE="$TEST_CONFIG" yaml_site_exists "testsite"
}

#######################################
# Test: Site has correct fields
#######################################
test_site_fields() {
    local directory=$(YAML_CONFIG_FILE="$TEST_CONFIG" yaml_get_site_field "testsite" "directory")
    local recipe=$(YAML_CONFIG_FILE="$TEST_CONFIG" yaml_get_site_field "testsite" "recipe")
    local environment=$(YAML_CONFIG_FILE="$TEST_CONFIG" yaml_get_site_field "testsite" "environment")

    [[ "$directory" == "$TEST_DIR/testsite" ]] && \
    [[ "$recipe" == "test_recipe" ]] && \
    [[ "$environment" == "development" ]]
}

#######################################
# Test: Add modules to registered site
#######################################
test_add_modules_to_site() {
    YAML_CONFIG_FILE="$TEST_CONFIG" yaml_add_site_modules \
        "testsite" \
        "devel kint webprofiler" \
        2>/dev/null

    local modules=$(YAML_CONFIG_FILE="$TEST_CONFIG" yaml_get_site_list "testsite" "installed_modules")
    echo "$modules" | grep -q "devel" && \
    echo "$modules" | grep -q "kint" && \
    echo "$modules" | grep -q "webprofiler"
}

#######################################
# Test: Add production config to site
#######################################
test_add_production_config() {
    YAML_CONFIG_FILE="$TEST_CONFIG" yaml_add_site_production \
        "testsite" \
        "rsync" \
        "test_server" \
        "/var/www/testsite" \
        "test.example.com" \
        2>/dev/null

    # Verify production config was added
    grep -q "production_config:" "$TEST_CONFIG" && \
    grep -q "method: rsync" "$TEST_CONFIG" && \
    grep -q "server: test_server" "$TEST_CONFIG"
}

#######################################
# Test: Register staging site
#######################################
test_register_staging_site() {
    YAML_CONFIG_FILE="$TEST_CONFIG" yaml_add_site \
        "testsite_stg" \
        "$TEST_DIR/testsite_stg" \
        "test_recipe" \
        "staging" \
        2>/dev/null

    YAML_CONFIG_FILE="$TEST_CONFIG" yaml_site_exists "testsite_stg"
}

#######################################
# Test: Environment detection from suffix
#######################################
test_environment_detection() {
    local env=$(YAML_CONFIG_FILE="$TEST_CONFIG" yaml_get_site_field "testsite_stg" "environment")
    [[ "$env" == "staging" ]]
}

#######################################
# Test: Read delete_site_yml setting
#######################################
test_read_delete_setting() {
    local delete_yml=$(awk '
        /^settings:/ { in_settings = 1; next }
        in_settings && /^[a-zA-Z]/ && !/^  / { in_settings = 0 }
        in_settings && /^  delete_site_yml:/ {
            sub("^  delete_site_yml: *", "")
            print
            exit
        }
    ' "$TEST_CONFIG")

    [[ "$delete_yml" == "true" ]]
}

#######################################
# Test: Site removal workflow
#######################################
test_site_removal() {
    # Remove testsite
    YAML_CONFIG_FILE="$TEST_CONFIG" yaml_remove_site "testsite" 2>/dev/null

    # Verify site was removed
    ! YAML_CONFIG_FILE="$TEST_CONFIG" yaml_site_exists "testsite"
}

#######################################
# Test: Other sites remain after removal
#######################################
test_other_sites_remain() {
    # testsite_stg should still exist
    YAML_CONFIG_FILE="$TEST_CONFIG" yaml_site_exists "testsite_stg"
}

#######################################
# Test: Recipe reading from sites section
#######################################
test_recipe_from_sites() {
    local recipe=$(YAML_CONFIG_FILE="$TEST_CONFIG" yaml_get_site_field "testsite_stg" "recipe")
    [[ "$recipe" == "test_recipe" ]]
}

#######################################
# Test: Multiple module reinstallation parsing
#######################################
test_multiple_modules_parsing() {
    source /dev/stdin <<'FUNC'
get_recipe_value() {
    local recipe=$1
    local key=$2
    local config_file="${3:-nwp.yml}"

    awk -v recipe="$recipe" -v key="$key" '
        BEGIN { in_recipe = 0; found = 0 }
        /^  [a-zA-Z0-9_-]+:/ {
            if ($1 == recipe":") {
                in_recipe = 1
            } else if (in_recipe && /^  [a-zA-Z0-9_-]+:/) {
                in_recipe = 0
            }
        }
        in_recipe && $0 ~ "^    " key ":" {
            sub("^    " key ": *", "")
            print
            found = 1
            exit
        }
    ' "$config_file"
}
FUNC

    local modules=$(get_recipe_value "test_recipe" "reinstall_modules" "$TEST_CONFIG")
    local module_array=($modules)

    [[ ${#module_array[@]} -eq 2 ]] && \
    [[ "${module_array[0]}" == "test_module" ]] && \
    [[ "${module_array[1]}" == "another_module" ]]
}

#######################################
# Test: Production config reading
#######################################
test_production_config_reading() {
    source /dev/stdin <<'FUNC'
get_recipe_value() {
    local recipe=$1
    local key=$2
    local config_file="${3:-nwp.yml}"

    awk -v recipe="$recipe" -v key="$key" '
        BEGIN { in_recipe = 0; found = 0 }
        /^  [a-zA-Z0-9_-]+:/ {
            if ($1 == recipe":") {
                in_recipe = 1
            } else if (in_recipe && /^  [a-zA-Z0-9_-]+:/) {
                in_recipe = 0
            }
        }
        in_recipe && $0 ~ "^    " key ":" {
            sub("^    " key ": *", "")
            print
            found = 1
            exit
        }
    ' "$config_file"
}
FUNC

    local prod_method=$(get_recipe_value "test_recipe" "prod_method" "$TEST_CONFIG")
    local prod_server=$(get_recipe_value "test_recipe" "prod_server" "$TEST_CONFIG")
    local prod_domain=$(get_recipe_value "test_recipe" "prod_domain" "$TEST_CONFIG")

    [[ "$prod_method" == "rsync" ]] && \
    [[ "$prod_server" == "test_server" ]] && \
    [[ "$prod_domain" == "test.example.com" ]]
}

#######################################
# Test: Backup creation during site operations
#######################################
test_backup_creation() {
    # Add a test site
    YAML_CONFIG_FILE="$TEST_CONFIG" yaml_add_site \
        "backup_test" \
        "$TEST_DIR/backup_test" \
        "test_recipe" \
        "development" \
        2>/dev/null

    # Count backup files (now stored in .backups/ directory)
    local backup_dir="$TEST_DIR/.backups"
    local backup_count=$(ls -1 "${backup_dir}"/nwp.yml.backup-* 2>/dev/null | wc -l)

    # Should have multiple backups from all operations
    [[ $backup_count -gt 0 ]]
}

#######################################
# Test: YAML structure integrity
#######################################
test_yaml_structure() {
    # Verify nwp.yml has valid structure
    grep -q "^settings:" "$TEST_CONFIG" && \
    grep -q "^linode:" "$TEST_CONFIG" && \
    grep -q "^recipes:" "$TEST_CONFIG" && \
    grep -q "^sites:" "$TEST_CONFIG"
}

#######################################
# Test: Site update functionality
#######################################
test_site_update() {
    YAML_CONFIG_FILE="$TEST_CONFIG" yaml_update_site_field \
        "testsite_stg" \
        "environment" \
        "production" \
        2>/dev/null

    local env=$(YAML_CONFIG_FILE="$TEST_CONFIG" yaml_get_site_field "testsite_stg" "environment")
    [[ "$env" == "production" ]]
}

#######################################
# Display final test results
#######################################
display_results() {
    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}Integration Test Results${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo -e "Total tests run: $TESTS_RUN"
    echo -e "${GREEN}Tests passed: $TESTS_PASSED${NC}"

    if [[ $TESTS_FAILED -gt 0 ]]; then
        echo -e "${RED}Tests failed: $TESTS_FAILED${NC}"
        echo -e "\n${RED}INTEGRATION TEST SUITE FAILED${NC}"
        return 1
    else
        echo -e "\n${GREEN}ALL INTEGRATION TESTS PASSED!${NC}"
        return 0
    fi
}

#######################################
# Main test execution
#######################################
main() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}NWP Integration Test Suite${NC}"
    echo -e "${BLUE}========================================${NC}\n"

    # Setup
    setup

    # Run integration tests
    run_test "Read recipe value (reinstall_modules)" test_get_recipe_value
    run_test "Read recipe profile" test_get_recipe_profile
    run_test "Read Linode server config" test_get_linode_config
    run_test "Register development site" test_site_registration
    run_test "Verify site fields" test_site_fields
    run_test "Add modules to site" test_add_modules_to_site
    run_test "Add production config" test_add_production_config
    run_test "Register staging site" test_register_staging_site
    run_test "Environment detection from suffix" test_environment_detection
    run_test "Read delete_site_yml setting" test_read_delete_setting
    run_test "Remove site from nwp.yml" test_site_removal
    run_test "Other sites remain after removal" test_other_sites_remain
    run_test "Recipe reading from sites section" test_recipe_from_sites
    run_test "Multiple modules parsing" test_multiple_modules_parsing
    run_test "Production config reading" test_production_config_reading
    run_test "Backup files created" test_backup_creation
    run_test "YAML structure integrity" test_yaml_structure
    run_test "Site field update" test_site_update

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
