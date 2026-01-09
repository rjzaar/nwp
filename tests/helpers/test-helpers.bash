#!/bin/bash
################################################################################
# NWP BATS Test Helpers
#
# Common helper functions for BATS tests
# Source this file in your test files: load helpers/test-helpers
################################################################################

# Get the project root directory
get_project_root() {
    echo "${BATS_TEST_DIRNAME}/../.."
}

# Setup function to be called in BATS setup()
# Loads NWP libraries and sets up test environment
test_setup() {
    export PROJECT_ROOT="${BATS_TEST_DIRNAME}/../.."
    export TEST_TEMP_DIR="${BATS_TEST_TMPDIR}"

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
}

# Teardown function to be called in BATS teardown()
test_teardown() {
    # Clean up any temporary files
    if [ -n "${TEST_TEMP_DIR}" ] && [ -d "${TEST_TEMP_DIR}" ]; then
        rm -rf "${TEST_TEMP_DIR:?}"/*
    fi
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

    local mock_script="${TEST_TEMP_DIR}/mock-${command}"
    cat > "$mock_script" << EOF
#!/bin/bash
echo "$output"
exit $exit_code
EOF
    chmod +x "$mock_script"
    export PATH="${TEST_TEMP_DIR}:${PATH}"
}

# Restore PATH after mocking
unmock_commands() {
    export PATH="${PATH#${TEST_TEMP_DIR}:}"
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
