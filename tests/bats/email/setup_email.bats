#!/usr/bin/env bats
################################################################################
# BATS tests for setup_email.sh
#
# Run with:
#   bats tests/bats/email/setup_email.bats
#
# Prerequisites:
#   - bats-core installed: https://bats-core.readthedocs.io/
#   - Install: apt-get install bats OR brew install bats-core
################################################################################

# Load test helpers
setup() {
    # Get the directory of this test file
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
    SCRIPT="${PROJECT_ROOT}/email/setup_email.sh"

    # Ensure script exists
    [ -f "$SCRIPT" ]
}

################################################################################
# Syntax Tests
################################################################################

@test "setup_email.sh - syntax check passes" {
    run bash -n "$SCRIPT"
    [ "$status" -eq 0 ]
}

@test "setup_email.sh - script is executable" {
    [ -x "$SCRIPT" ]
}

@test "setup_email.sh - has shebang" {
    head -1 "$SCRIPT" | grep -q "^#!/bin/bash"
}

################################################################################
# Help Output Tests
################################################################################

@test "setup_email.sh --help - shows usage information" {
    run "$SCRIPT" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage"* ]]
}

@test "setup_email.sh --help - mentions --check option" {
    run "$SCRIPT" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--check"* ]]
}

@test "setup_email.sh --help - mentions --dns-only option" {
    run "$SCRIPT" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--dns-only"* ]]
}

################################################################################
# Check Mode Tests (safe to run without root)
################################################################################

@test "setup_email.sh --check - runs without errors" {
    # This should work even without root, just showing current status
    run "$SCRIPT" --check
    # May fail checks but shouldn't crash
    [[ "$status" -eq 0 ]] || [[ "$output" == *"issue"* ]]
}

@test "setup_email.sh --check - shows domain info" {
    run "$SCRIPT" --check
    [[ "$output" == *"Domain"* ]] || [[ "$output" == *"nwpcode.org"* ]]
}

@test "setup_email.sh --check - checks E01 Postfix" {
    run "$SCRIPT" --check
    [[ "$output" == *"E01"* ]] || [[ "$output" == *"Postfix"* ]]
}

@test "setup_email.sh --check - checks E02 SPF" {
    run "$SCRIPT" --check
    [[ "$output" == *"E02"* ]] || [[ "$output" == *"SPF"* ]]
}

@test "setup_email.sh --check - checks E03 OpenDKIM" {
    run "$SCRIPT" --check
    [[ "$output" == *"E03"* ]] || [[ "$output" == *"DKIM"* ]]
}

@test "setup_email.sh --check - checks E04 DMARC" {
    run "$SCRIPT" --check
    [[ "$output" == *"E04"* ]] || [[ "$output" == *"DMARC"* ]]
}

@test "setup_email.sh --check - checks E05 PTR" {
    run "$SCRIPT" --check
    [[ "$output" == *"E05"* ]] || [[ "$output" == *"PTR"* ]]
}

################################################################################
# Environment Variable Tests
################################################################################

@test "setup_email.sh - respects DOMAIN environment variable" {
    DOMAIN="test.example.com" run "$SCRIPT" --check
    [[ "$output" == *"test.example.com"* ]]
}

@test "setup_email.sh - respects MAIL_HOSTNAME environment variable" {
    MAIL_HOSTNAME="mail.test.com" run "$SCRIPT" --check
    [[ "$output" == *"mail.test.com"* ]]
}

################################################################################
# Error Handling Tests
################################################################################

@test "setup_email.sh - rejects unknown options" {
    run "$SCRIPT" --unknown-option
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown"* ]] || [[ "$output" == *"unknown"* ]]
}

@test "setup_email.sh - requires root for full setup" {
    # Skip if already root
    if [ "$(id -u)" -eq 0 ]; then
        skip "Running as root"
    fi

    run "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"root"* ]]
}

################################################################################
# Function Existence Tests
################################################################################

@test "setup_email.sh - defines setup_postfix function" {
    run grep -q "^setup_postfix()" "$SCRIPT"
    [ "$status" -eq 0 ]
}

@test "setup_email.sh - defines setup_spf function" {
    run grep -q "^setup_spf()" "$SCRIPT"
    [ "$status" -eq 0 ]
}

@test "setup_email.sh - defines setup_opendkim function" {
    run grep -q "^setup_opendkim()" "$SCRIPT"
    [ "$status" -eq 0 ]
}

@test "setup_email.sh - defines setup_dmarc function" {
    run grep -q "^setup_dmarc()" "$SCRIPT"
    [ "$status" -eq 0 ]
}

@test "setup_email.sh - defines setup_ptr function" {
    run grep -q "^setup_ptr()" "$SCRIPT"
    [ "$status" -eq 0 ]
}

@test "setup_email.sh - defines check_all function" {
    run grep -q "^check_all()" "$SCRIPT"
    [ "$status" -eq 0 ]
}

################################################################################
# Security Tests
################################################################################

@test "setup_email.sh - uses set -euo pipefail" {
    run grep -q "set -euo pipefail" "$SCRIPT"
    [ "$status" -eq 0 ]
}

@test "setup_email.sh - quotes variables in rm commands" {
    # Ensure no unquoted variable usage with dangerous commands
    run grep -E 'rm\s+(-rf?\s+)?\$[^"]' "$SCRIPT"
    [ "$status" -ne 0 ]  # Should NOT find unquoted variables
}

@test "setup_email.sh - does not contain hardcoded API tokens" {
    run grep -E "api_token\s*=\s*['\"][a-zA-Z0-9]{20,}" "$SCRIPT"
    [ "$status" -ne 0 ]  # Should NOT find hardcoded tokens
}
