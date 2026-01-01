#!/usr/bin/env bats
################################################################################
# BATS tests for mailpit-client.sh library
#
# Run with:
#   bats tests/bats/email/mailpit_client.bats
################################################################################

setup() {
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
    LIBRARY="${PROJECT_ROOT}/email/lib/mailpit-client.sh"

    [ -f "$LIBRARY" ]

    # Source the library
    source "$LIBRARY"
}

################################################################################
# Syntax Tests
################################################################################

@test "mailpit-client.sh - syntax check passes" {
    run bash -n "$LIBRARY"
    [ "$status" -eq 0 ]
}

@test "mailpit-client.sh - can be sourced" {
    run bash -c "source '$LIBRARY'"
    [ "$status" -eq 0 ]
}

################################################################################
# Default Configuration Tests
################################################################################

@test "mailpit-client.sh - sets default MAILPIT_URL" {
    source "$LIBRARY"
    [ "$MAILPIT_URL" = "http://localhost:8025" ]
}

@test "mailpit-client.sh - sets default MAILPIT_TIMEOUT" {
    source "$LIBRARY"
    [ "$MAILPIT_TIMEOUT" = "30" ]
}

@test "mailpit-client.sh - respects MAILPIT_URL environment variable" {
    export MAILPIT_URL="http://custom:9000"
    source "$LIBRARY"
    [ "$MAILPIT_URL" = "http://custom:9000" ]
    unset MAILPIT_URL
}

################################################################################
# Function Existence Tests
################################################################################

@test "mailpit-client.sh - defines mailpit_init function" {
    run type mailpit_init
    [ "$status" -eq 0 ]
    [[ "$output" == *"function"* ]]
}

@test "mailpit-client.sh - defines mailpit_is_available function" {
    run type mailpit_is_available
    [ "$status" -eq 0 ]
}

@test "mailpit-client.sh - defines mailpit_info function" {
    run type mailpit_info
    [ "$status" -eq 0 ]
}

@test "mailpit-client.sh - defines mailpit_count function" {
    run type mailpit_count
    [ "$status" -eq 0 ]
}

@test "mailpit-client.sh - defines mailpit_list function" {
    run type mailpit_list
    [ "$status" -eq 0 ]
}

@test "mailpit-client.sh - defines mailpit_search function" {
    run type mailpit_search
    [ "$status" -eq 0 ]
}

@test "mailpit-client.sh - defines mailpit_get_message function" {
    run type mailpit_get_message
    [ "$status" -eq 0 ]
}

@test "mailpit-client.sh - defines mailpit_get_html function" {
    run type mailpit_get_html
    [ "$status" -eq 0 ]
}

@test "mailpit-client.sh - defines mailpit_get_text function" {
    run type mailpit_get_text
    [ "$status" -eq 0 ]
}

@test "mailpit-client.sh - defines mailpit_get_headers function" {
    run type mailpit_get_headers
    [ "$status" -eq 0 ]
}

@test "mailpit-client.sh - defines mailpit_delete_message function" {
    run type mailpit_delete_message
    [ "$status" -eq 0 ]
}

@test "mailpit-client.sh - defines mailpit_delete_all function" {
    run type mailpit_delete_all
    [ "$status" -eq 0 ]
}

@test "mailpit-client.sh - defines mailpit_mark_timestamp function" {
    run type mailpit_mark_timestamp
    [ "$status" -eq 0 ]
}

@test "mailpit-client.sh - defines mailpit_wait_for_email function" {
    run type mailpit_wait_for_email
    [ "$status" -eq 0 ]
}

@test "mailpit-client.sh - defines mailpit_assert_email function" {
    run type mailpit_assert_email
    [ "$status" -eq 0 ]
}

@test "mailpit-client.sh - defines mailpit_check_auth function" {
    run type mailpit_check_auth
    [ "$status" -eq 0 ]
}

@test "mailpit-client.sh - defines mailpit_save_artifacts function" {
    run type mailpit_save_artifacts
    [ "$status" -eq 0 ]
}

@test "mailpit-client.sh - defines mailpit_help function" {
    run type mailpit_help
    [ "$status" -eq 0 ]
}

################################################################################
# Function Behavior Tests (Mock/Offline)
################################################################################

@test "mailpit_mark_timestamp - returns RFC3339 timestamp" {
    run mailpit_mark_timestamp
    [ "$status" -eq 0 ]
    # Should match pattern like 2024-01-01T12:00:00Z
    [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "mailpit_is_available - returns 1 when Mailpit is not running" {
    MAILPIT_URL="http://localhost:59999"
    run mailpit_is_available
    [ "$status" -ne 0 ]
}

@test "mailpit_help - shows usage information" {
    run mailpit_help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Mailpit Client Library"* ]]
}

@test "mailpit_help - documents mailpit_init" {
    run mailpit_help
    [[ "$output" == *"mailpit_init"* ]]
}

@test "mailpit_help - documents mailpit_wait_for_email" {
    run mailpit_help
    [[ "$output" == *"mailpit_wait_for_email"* ]]
}

@test "mailpit_help - documents mailpit_assert_email" {
    run mailpit_help
    [[ "$output" == *"mailpit_assert_email"* ]]
}

################################################################################
# API Endpoint Tests (URL construction)
################################################################################

@test "mailpit-client.sh - uses correct API v1 endpoints" {
    run grep -E "/api/v1/(info|messages|search|message)" "$LIBRARY"
    [ "$status" -eq 0 ]
}

@test "mailpit-client.sh - uses correct view endpoints for HTML/text" {
    run grep -E "/view/.*\.(html|txt)" "$LIBRARY"
    [ "$status" -eq 0 ]
}

################################################################################
# Integration Tests (only run if Mailpit is available)
################################################################################

@test "mailpit integration - skip if Mailpit not available" {
    if ! mailpit_is_available; then
        skip "Mailpit not available at $MAILPIT_URL"
    fi

    run mailpit_info
    [ "$status" -eq 0 ]
    [[ "$output" == *"Version"* ]] || [[ "$output" == *"version"* ]]
}

@test "mailpit integration - can get message count" {
    if ! mailpit_is_available; then
        skip "Mailpit not available"
    fi

    run mailpit_count
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]+$ ]]
}

@test "mailpit integration - can list messages" {
    if ! mailpit_is_available; then
        skip "Mailpit not available"
    fi

    run mailpit_list 5
    [ "$status" -eq 0 ]
    # Should be valid JSON
    echo "$output" | jq . > /dev/null
}
