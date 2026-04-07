#!/bin/bash
################################################################################
# NWP BATS Test Helpers
#
# Common helper functions for BATS tests
# Source this file in your test files: load helpers/test-helpers
#
# Features:
#   - Setup/teardown functions for test lifecycle
#   - Fixture management for test data
#   - Mock utilities for command mocking
#   - Assertion helpers for common checks
################################################################################

# Track mocked commands for cleanup
MOCKED_COMMANDS=()

# Get the project root directory
get_project_root() {
    echo "${BATS_TEST_DIRNAME}/../.."
}

# Get the fixtures directory
get_fixtures_dir() {
    echo "${BATS_TEST_DIRNAME}/../fixtures"
}

# Setup function to be called in BATS setup()
# Loads NWP libraries and sets up test environment
test_setup() {
    export PROJECT_ROOT="${BATS_TEST_DIRNAME}/../.."
    export TEST_TEMP_DIR="${BATS_TEST_TMPDIR}"
    export TEST_FIXTURES_DIR="${BATS_TEST_DIRNAME}/../fixtures"
    export TEST_ORIGINAL_PWD="$(pwd)"

    # Source UI library for color codes
    source "${PROJECT_ROOT}/lib/ui.sh"

    # Disable colors in tests for easier assertions
    export RED=''
    export GREEN=''
    export YELLOW=''
    export BLUE=''
    export CYAN=''
    export NC=''
    export BOLD=''

    # Reset mocked commands array
    MOCKED_COMMANDS=()
}

# Teardown function to be called in BATS teardown()
test_teardown() {
    # Restore original directory
    if [ -n "${TEST_ORIGINAL_PWD}" ]; then
        cd "${TEST_ORIGINAL_PWD}" 2>/dev/null || true
    fi

    # Clean up mocked commands
    unmock_commands

    # Clean up any temporary files
    if [ -n "${TEST_TEMP_DIR}" ] && [ -d "${TEST_TEMP_DIR}" ]; then
        rm -rf "${TEST_TEMP_DIR:?}"/*
    fi
}

################################################################################
# Fixture Functions
################################################################################

# Set up fixtures for a test
# Copies fixtures to temp directory and exports paths
# Usage: setup_fixtures
setup_fixtures() {
    local fixture_dest="${TEST_TEMP_DIR}/fixtures"

    if [ ! -d "${TEST_FIXTURES_DIR}" ]; then
        echo "Warning: Fixture directory not found: ${TEST_FIXTURES_DIR}" >&2
        return 1
    fi

    # Copy fixtures to temp directory
    mkdir -p "${fixture_dest}"
    cp -r "${TEST_FIXTURES_DIR}"/* "${fixture_dest}/" 2>/dev/null || true

    # Export fixture paths
    export FIXTURE_CNWP="${fixture_dest}/nwp.yml"
    export FIXTURE_SECRETS="${fixture_dest}/secrets.yml"
    export FIXTURE_SAMPLE_SITE="${fixture_dest}/sample-site"

    return 0
}

# Clean up fixtures after a test
cleanup_fixtures() {
    if [ -n "${TEST_TEMP_DIR}" ] && [ -d "${TEST_TEMP_DIR}/fixtures" ]; then
        rm -rf "${TEST_TEMP_DIR}/fixtures"
    fi

    unset FIXTURE_CNWP FIXTURE_SECRETS FIXTURE_SAMPLE_SITE
}

# Get path to a fixture file
# Usage: fixture_path "nwp.yml"
fixture_path() {
    local filename="$1"
    echo "${TEST_FIXTURES_DIR}/${filename}"
}

# Load fixture configuration for tests
# Sets up PROJECT_ROOT to use fixture config
use_fixture_config() {
    setup_fixtures

    # Point PROJECT_ROOT to temp directory with fixtures
    export PROJECT_ROOT="${TEST_TEMP_DIR}/fixtures"

    # Create expected directory structure
    mkdir -p "${PROJECT_ROOT}/sites"
    mkdir -p "${PROJECT_ROOT}/lib"

    # Copy necessary libraries
    local real_project_root="${BATS_TEST_DIRNAME}/../.."
    cp "${real_project_root}/lib/"*.sh "${PROJECT_ROOT}/lib/" 2>/dev/null || true

    return 0
}

# Create a temporary test file
# Usage: temp_file=$(create_temp_file "content")
create_temp_file() {
    local content="$1"
    local temp_file="${TEST_TEMP_DIR}/test-file-$$-${RANDOM}"
    echo "$content" > "$temp_file"
    echo "$temp_file"
}

# Create a temporary directory
# Usage: temp_dir=$(create_temp_dir)
create_temp_dir() {
    local temp_dir="${TEST_TEMP_DIR}/test-dir-$$-${RANDOM}"
    mkdir -p "$temp_dir"
    echo "$temp_dir"
}

# Assert file exists
# Usage: assert_file_exists "/path/to/file"
assert_file_exists() {
    local file="$1"
    [ -f "$file" ] || {
        echo "Expected file to exist: $file"
        return 1
    }
}

# Assert directory exists
# Usage: assert_dir_exists "/path/to/dir"
assert_dir_exists() {
    local dir="$1"
    [ -d "$dir" ] || {
        echo "Expected directory to exist: $dir"
        return 1
    }
}

# Assert string contains substring
# Usage: assert_contains "haystack" "needle"
assert_contains() {
    local haystack="$1"
    local needle="$2"
    [[ "$haystack" == *"$needle"* ]] || {
        echo "Expected string to contain: $needle"
        echo "Got: $haystack"
        return 1
    }
}

# Assert string does not contain substring
# Usage: assert_not_contains "haystack" "needle"
assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    [[ "$haystack" != *"$needle"* ]] || {
        echo "Expected string to NOT contain: $needle"
        echo "Got: $haystack"
        return 1
    }
}

# Assert strings are equal
# Usage: assert_equals "expected" "actual"
assert_equals() {
    local expected="$1"
    local actual="$2"
    [ "$expected" = "$actual" ] || {
        echo "Expected: $expected"
        echo "Got: $actual"
        return 1
    }
}

# Assert exit code is 0
# Usage: assert_success $?
assert_success() {
    local code="$1"
    [ "$code" -eq 0 ] || {
        echo "Expected exit code 0, got: $code"
        return 1
    }
}

# Assert exit code is not 0
# Usage: assert_failure $?
assert_failure() {
    local code="$1"
    [ "$code" -ne 0 ] || {
        echo "Expected non-zero exit code, got: $code"
        return 1
    }
}

# Mock a command
# Usage: mock_command "command_name" "output" [exit_code]
mock_command() {
    local command="$1"
    local output="$2"
    local exit_code="${3:-0}"
    local mock_dir="${TEST_TEMP_DIR}/mocks"

    mkdir -p "${mock_dir}"

    local mock_script="${mock_dir}/${command}"
    cat > "$mock_script" << EOF
#!/bin/bash
echo "$output"
exit $exit_code
EOF
    chmod +x "$mock_script"

    # Add to PATH if not already there
    if [[ ":${PATH}:" != *":${mock_dir}:"* ]]; then
        export PATH="${mock_dir}:${PATH}"
    fi

    # Track mocked command for cleanup
    MOCKED_COMMANDS+=("${command}")
}

# Remove a specific mocked command
# Usage: unmock_command "command_name"
unmock_command() {
    local command="$1"
    local mock_dir="${TEST_TEMP_DIR}/mocks"

    rm -f "${mock_dir}/${command}" 2>/dev/null || true

    # Remove from tracked commands
    local new_array=()
    for cmd in "${MOCKED_COMMANDS[@]}"; do
        if [ "${cmd}" != "${command}" ]; then
            new_array+=("${cmd}")
        fi
    done
    MOCKED_COMMANDS=("${new_array[@]}")
}

# Restore PATH after mocking and clean up all mocked commands
unmock_commands() {
    local mock_dir="${TEST_TEMP_DIR}/mocks"

    # Remove all mock scripts
    for cmd in "${MOCKED_COMMANDS[@]}"; do
        rm -f "${mock_dir}/${cmd}" 2>/dev/null || true
    done

    MOCKED_COMMANDS=()

    # Remove mock directory from PATH
    export PATH="${PATH//${mock_dir}:/}"
}

# Skip test if not running in CI
# Usage: skip_if_not_ci
skip_if_not_ci() {
    if [ -z "${CI}" ]; then
        skip "Only runs in CI environment"
    fi
}

# Skip test if running in CI
# Usage: skip_if_ci
skip_if_ci() {
    if [ -n "${CI}" ]; then
        skip "Skipped in CI environment"
    fi
}

# Skip test if command is not available
# Usage: require_command "ddev" "DDEV is not installed"
require_command() {
    local command="$1"
    local message="${2:-$command is not available}"

    if ! command -v "$command" &>/dev/null; then
        skip "$message"
    fi
}

# Create a minimal .ddev config for testing
# Usage: create_mock_ddev_config "$site_dir"
create_mock_ddev_config() {
    local site_dir="$1"
    mkdir -p "$site_dir/.ddev"
    cat > "$site_dir/.ddev/config.yaml" << 'EOF'
name: test-site
type: drupal10
docroot: web
php_version: "8.2"
webserver_type: nginx-fpm
router_http_port: "80"
router_https_port: "443"
xdebug_enabled: false
additional_hostnames: []
additional_fqdns: []
database:
  type: mariadb
  version: "10.6"
use_dns_when_possible: true
composer_version: "2"
web_environment: []
EOF
}

# Create a minimal site structure for testing
# Usage: create_mock_site "$site_dir" "$webroot"
create_mock_site() {
    local site_dir="$1"
    local webroot="${2:-web}"

    mkdir -p "$site_dir/$webroot/sites/default"
    create_mock_ddev_config "$site_dir"

    # Create minimal composer.json
    cat > "$site_dir/composer.json" << 'EOF'
{
    "name": "test/test-site",
    "type": "project",
    "require": {
        "drupal/core": "^10.0"
    }
}
EOF

    # Create minimal index.php
    cat > "$site_dir/$webroot/index.php" << 'EOF'
<?php
// Minimal Drupal index
EOF
}

# Assert output matches regex pattern
# Usage: assert_output_matches "^ERROR:"
assert_output_matches() {
    local pattern="$1"
    [[ "$output" =~ $pattern ]] || {
        echo "Expected output to match pattern: $pattern"
        echo "Got: $output"
        return 1
    }
}

# Assert line count in output
# Usage: assert_line_count 3
assert_line_count() {
    local expected="$1"
    local actual="${#lines[@]}"
    [ "$expected" -eq "$actual" ] || {
        echo "Expected $expected lines, got $actual"
        return 1
    }
}

# Get a specific line from output (0-indexed)
# Usage: line=$(get_line 0)
get_line() {
    local index="$1"
    echo "${lines[$index]}"
}

# Create a YAML file for testing
# Usage: create_test_yaml "$file" "key: value"
create_test_yaml() {
    local file="$1"
    local content="$2"
    echo "$content" > "$file"
}

# Source a library with error handling
# Usage: source_lib "common.sh"
source_lib() {
    local lib="$1"
    local lib_path="${PROJECT_ROOT}/lib/${lib}"

    if [ ! -f "$lib_path" ]; then
        echo "Library not found: $lib_path"
        return 1
    fi

    source "$lib_path"
}

################################################################################
# Additional Test Utilities
################################################################################

# Create a mock backup file for testing
# Usage: create_mock_backup "$backup_dir" "$sitename"
create_mock_backup() {
    local backup_dir="$1"
    local sitename="$2"
    local timestamp
    timestamp="$(date +%Y%m%d_%H%M%S)"

    mkdir -p "${backup_dir}/${sitename}"

    # Create mock backup files
    touch "${backup_dir}/${sitename}/${sitename}_${timestamp}_db.sql.gz"
    touch "${backup_dir}/${sitename}/${sitename}_${timestamp}_files.tar.gz"

    echo "${backup_dir}/${sitename}"
}

# Skip test if not running in DDEV environment
skip_if_not_ddev() {
    if [ -z "${DDEV_PROJECT:-}" ]; then
        skip "Not running in DDEV environment"
    fi
}

# Assert that a variable is set and non-empty
# Usage: assert_set "$variable"
assert_set() {
    local value="$1"
    if [ -z "${value}" ]; then
        echo "Assertion failed: variable is empty or unset" >&2
        return 1
    fi
    return 0
}

# Assert that a variable is empty or unset
# Usage: assert_empty "$variable"
assert_empty() {
    local value="$1"
    if [ -n "${value}" ]; then
        echo "Assertion failed: variable should be empty, got '${value}'" >&2
        return 1
    fi
    return 0
}

# Assert that two values are not equal
# Usage: assert_not_equals "unexpected" "actual"
assert_not_equals() {
    local unexpected="$1"
    local actual="$2"
    if [ "${unexpected}" = "${actual}" ]; then
        echo "Assertion failed: value should not equal '${unexpected}'" >&2
        return 1
    fi
    return 0
}

# Get a value from a YAML file using yq or grep fallback
# Usage: yaml_get "path.to.key" "file.yml"
yaml_get() {
    local key_path="$1"
    local yaml_file="$2"

    if command -v yq &>/dev/null; then
        yq eval ".${key_path}" "${yaml_file}" 2>/dev/null
    else
        # Simple grep fallback for basic cases
        local key
        key=$(echo "${key_path}" | sed 's/.*\.//')
        grep "^[[:space:]]*${key}:" "${yaml_file}" 2>/dev/null | head -1 | sed 's/.*:[[:space:]]*//' | tr -d '"'
    fi
}

# Print debug information (only when DEBUG=true)
debug_test() {
    if [ "${DEBUG:-false}" = "true" ]; then
        echo "[TEST DEBUG] $*" >&2
    fi
}

# Print test context information for debugging
print_test_context() {
    echo "Test Context:"
    echo "  PROJECT_ROOT: ${PROJECT_ROOT:-not set}"
    echo "  TEST_FIXTURES_DIR: ${TEST_FIXTURES_DIR:-not set}"
    echo "  TEST_TEMP_DIR: ${TEST_TEMP_DIR:-not set}"
    echo "  PWD: $(pwd)"
}
