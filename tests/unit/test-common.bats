#!/usr/bin/env bats
################################################################################
# Unit Tests for lib/common.sh
#
# Tests core utility functions from the common library
################################################################################

# Load test helpers
load ../helpers/test-helpers

setup() {
    test_setup
    source_lib "common.sh"
}

teardown() {
    test_teardown
}

################################################################################
# validate_sitename() tests
################################################################################

@test "validate_sitename: accepts valid alphanumeric names" {
    run validate_sitename "mysite"
    [ "$status" -eq 0 ]
}

@test "validate_sitename: accepts names with hyphens" {
    run validate_sitename "my-site"
    [ "$status" -eq 0 ]
}

@test "validate_sitename: accepts names with underscores" {
    run validate_sitename "my_site"
    [ "$status" -eq 0 ]
}

@test "validate_sitename: accepts names with dots" {
    run validate_sitename "my.site"
    [ "$status" -eq 0 ]
}

@test "validate_sitename: accepts names with mixed characters" {
    run validate_sitename "my-site_123.test"
    [ "$status" -eq 0 ]
}

@test "validate_sitename: rejects empty names" {
    run validate_sitename ""
    [ "$status" -eq 1 ]
    [[ "$output" == *"Empty"* ]]
}

@test "validate_sitename: rejects absolute paths" {
    run validate_sitename "/home/user/site"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Absolute paths not allowed"* ]]
}

@test "validate_sitename: rejects path traversal with .." {
    run validate_sitename "../mysite"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Path traversal not allowed"* ]]
}

@test "validate_sitename: rejects path traversal in middle" {
    run validate_sitename "my/../site"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Path traversal not allowed"* ]]
}

@test "validate_sitename: rejects names with spaces" {
    run validate_sitename "my site"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid characters"* ]]
}

@test "validate_sitename: rejects names with special characters" {
    run validate_sitename "my;site"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid characters"* ]]
}

@test "validate_sitename: rejects names with ampersand" {
    run validate_sitename "my&site"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid characters"* ]]
}

@test "validate_sitename: rejects names with only dots" {
    run validate_sitename "..."
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid"* ]]
}

@test "validate_sitename: rejects names with only slashes" {
    run validate_sitename "///"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid"* ]]
}

@test "validate_sitename: custom context in error message" {
    run validate_sitename "" "backup name"
    [ "$status" -eq 1 ]
    [[ "$output" == *"backup name"* ]]
}

################################################################################
# get_base_name() tests
################################################################################

@test "get_base_name: removes -stg suffix" {
    run get_base_name "mysite-stg"
    [ "$status" -eq 0 ]
    [ "$output" = "mysite" ]
}

@test "get_base_name: removes -prod suffix" {
    run get_base_name "mysite-prod"
    [ "$status" -eq 0 ]
    [ "$output" = "mysite" ]
}

@test "get_base_name: removes _prod suffix" {
    run get_base_name "mysite_prod"
    [ "$status" -eq 0 ]
    [ "$output" = "mysite" ]
}

@test "get_base_name: removes -live suffix" {
    run get_base_name "mysite-live"
    [ "$status" -eq 0 ]
    [ "$output" = "mysite" ]
}

@test "get_base_name: returns unchanged if no suffix" {
    run get_base_name "mysite"
    [ "$status" -eq 0 ]
    [ "$output" = "mysite" ]
}

@test "get_base_name: handles complex names" {
    run get_base_name "my-complex_site-stg"
    [ "$status" -eq 0 ]
    [ "$output" = "my-complex_site" ]
}

################################################################################
# get_env_label() tests
################################################################################

@test "get_env_label: converts prod to PRODUCTION" {
    run get_env_label "prod"
    [ "$status" -eq 0 ]
    [ "$output" = "PRODUCTION" ]
}

@test "get_env_label: converts stg to STAGING" {
    run get_env_label "stg"
    [ "$status" -eq 0 ]
    [ "$output" = "STAGING" ]
}

@test "get_env_label: converts dev to DEVELOPMENT" {
    run get_env_label "dev"
    [ "$status" -eq 0 ]
    [ "$output" = "DEVELOPMENT" ]
}

@test "get_env_label: converts live to LIVE" {
    run get_env_label "live"
    [ "$status" -eq 0 ]
    [ "$output" = "LIVE" ]
}

@test "get_env_label: returns LOCAL for unknown" {
    run get_env_label "unknown"
    [ "$status" -eq 0 ]
    [ "$output" = "LOCAL" ]
}

################################################################################
# get_env_type_from_name() tests
################################################################################

@test "get_env_type_from_name: detects -stg suffix" {
    run get_env_type_from_name "mysite-stg"
    [ "$status" -eq 0 ]
    [ "$output" = "stg" ]
}

@test "get_env_type_from_name: detects -prod suffix" {
    run get_env_type_from_name "mysite-prod"
    [ "$status" -eq 0 ]
    [ "$output" = "prod" ]
}

@test "get_env_type_from_name: detects _prod suffix" {
    run get_env_type_from_name "mysite_prod"
    [ "$status" -eq 0 ]
    [ "$output" = "prod" ]
}

@test "get_env_type_from_name: detects -live suffix" {
    run get_env_type_from_name "mysite-live"
    [ "$status" -eq 0 ]
    [ "$output" = "live" ]
}

@test "get_env_type_from_name: returns dev for no suffix" {
    run get_env_type_from_name "mysite"
    [ "$status" -eq 0 ]
    [ "$output" = "dev" ]
}

################################################################################
# generate_secure_password() tests
################################################################################

@test "generate_secure_password: generates 24 character password by default" {
    run generate_secure_password
    [ "$status" -eq 0 ]
    [ "${#output}" -eq 24 ]
}

@test "generate_secure_password: generates custom length password" {
    run generate_secure_password 32
    [ "$status" -eq 0 ]
    [ "${#output}" -eq 32 ]
}

@test "generate_secure_password: generates different passwords each time" {
    local pass1=$(generate_secure_password)
    local pass2=$(generate_secure_password)
    [ "$pass1" != "$pass2" ]
}

@test "generate_secure_password: generates alphanumeric only" {
    run generate_secure_password
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[a-zA-Z0-9]+$ ]]
}

################################################################################
# debug_msg() tests
################################################################################

@test "debug_msg: prints nothing when DEBUG is false" {
    export DEBUG=false
    run debug_msg "test message"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "debug_msg: prints message when DEBUG is true" {
    export DEBUG=true
    run debug_msg "test message"
    [ "$status" -eq 0 ]
    [[ "$output" == *"test message"* ]]
}

@test "debug_msg: includes DEBUG prefix when enabled" {
    export DEBUG=true
    run debug_msg "test message"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[DEBUG]"* ]]
}

################################################################################
# ask_yes_no() tests - Note: These are interactive, so we test the logic only
################################################################################

# Note: ask_yes_no requires interactive input, so we'll skip direct testing
# These would be better tested in integration tests with expect

################################################################################
# get_secret() tests - Note: Requires .secrets.yml file
################################################################################

@test "get_secret: returns default when secrets file missing" {
    export PROJECT_ROOT="${TEST_TEMP_DIR}"
    run get_secret "some.key" "default_value"
    [ "$status" -eq 0 ]
    [ "$output" = "default_value" ]
}

@test "get_infra_secret: calls get_secret with infra file" {
    export PROJECT_ROOT="${TEST_TEMP_DIR}"
    run get_infra_secret "some.key" "default_value"
    [ "$status" -eq 0 ]
    [ "$output" = "default_value" ]
}

################################################################################
# Edge cases and error handling
################################################################################

@test "validate_sitename: handles null byte" {
    # Bash doesn't handle null bytes well, but we test the behavior
    run validate_sitename $'my\0site'
    [ "$status" -eq 1 ]
}

@test "get_base_name: handles empty input gracefully" {
    run get_base_name ""
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "get_env_type_from_name: handles empty input" {
    run get_env_type_from_name ""
    [ "$status" -eq 0 ]
    [ "$output" = "dev" ]
}
