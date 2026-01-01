#!/usr/bin/env bats
################################################################################
# BATS tests for test_email.sh
#
# Run with:
#   bats tests/bats/email/test_email.bats
################################################################################

setup() {
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
    SCRIPT="${PROJECT_ROOT}/email/test_email.sh"

    [ -f "$SCRIPT" ]
}

################################################################################
# Syntax Tests
################################################################################

@test "test_email.sh - syntax check passes" {
    run bash -n "$SCRIPT"
    [ "$status" -eq 0 ]
}

@test "test_email.sh - script is executable" {
    [ -x "$SCRIPT" ]
}

@test "test_email.sh - has shebang" {
    head -1 "$SCRIPT" | grep -q "^#!/bin/bash"
}

################################################################################
# Help Output Tests
################################################################################

@test "test_email.sh --help - shows usage information" {
    run "$SCRIPT" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage"* ]]
}

@test "test_email.sh --help - documents --send option" {
    run "$SCRIPT" --help
    [[ "$output" == *"--send"* ]]
}

@test "test_email.sh --help - documents --send-verify option" {
    run "$SCRIPT" --help
    [[ "$output" == *"--send-verify"* ]]
}

@test "test_email.sh --help - documents --check-dns option" {
    run "$SCRIPT" --help
    [[ "$output" == *"--check-dns"* ]]
}

@test "test_email.sh --help - documents --check-mailpit option" {
    run "$SCRIPT" --help
    [[ "$output" == *"--check-mailpit"* ]]
}

@test "test_email.sh --help - documents --mail-tester option" {
    run "$SCRIPT" --help
    [[ "$output" == *"--mail-tester"* ]]
}

################################################################################
# DNS Check Tests
################################################################################

@test "test_email.sh --check-dns - runs without crashing" {
    run "$SCRIPT" --check-dns
    # Should complete (may have issues but shouldn't crash)
    [[ "$status" -eq 0 ]] || [[ "$output" == *"issue"* ]] || [[ "$output" == *"MISSING"* ]]
}

@test "test_email.sh --check-dns - checks A record" {
    run "$SCRIPT" --check-dns
    [[ "$output" == *"A Record"* ]]
}

@test "test_email.sh --check-dns - checks MX record" {
    run "$SCRIPT" --check-dns
    [[ "$output" == *"MX Record"* ]]
}

@test "test_email.sh --check-dns - checks SPF record" {
    run "$SCRIPT" --check-dns
    [[ "$output" == *"SPF"* ]]
}

@test "test_email.sh --check-dns - checks DKIM record" {
    run "$SCRIPT" --check-dns
    [[ "$output" == *"DKIM"* ]]
}

@test "test_email.sh --check-dns - checks DMARC record" {
    run "$SCRIPT" --check-dns
    [[ "$output" == *"DMARC"* ]]
}

@test "test_email.sh --check-dns - checks PTR record" {
    run "$SCRIPT" --check-dns
    [[ "$output" == *"PTR"* ]]
}

################################################################################
# Mailpit Integration Tests
################################################################################

@test "test_email.sh --check-mailpit - handles missing Mailpit gracefully" {
    # If Mailpit isn't running, should show helpful message
    MAILPIT_URL="http://localhost:9999" run "$SCRIPT" --check-mailpit
    [[ "$output" == *"NOT AVAILABLE"* ]] || [[ "$output" == *"AVAILABLE"* ]]
}

@test "test_email.sh --clear-mailpit - handles missing Mailpit gracefully" {
    MAILPIT_URL="http://localhost:9999" run "$SCRIPT" --clear-mailpit
    # Should fail gracefully
    [[ "$status" -ne 0 ]] || [[ "$output" == *"not available"* ]]
}

################################################################################
# Mail-Tester Instructions
################################################################################

@test "test_email.sh --mail-tester - shows instructions" {
    run "$SCRIPT" --mail-tester
    [ "$status" -eq 0 ]
    [[ "$output" == *"mail-tester.com"* ]]
}

@test "test_email.sh --mail-tester - shows expected score" {
    run "$SCRIPT" --mail-tester
    [[ "$output" == *"10/10"* ]]
}

################################################################################
# Input Validation Tests
################################################################################

@test "test_email.sh --send - requires email argument" {
    run "$SCRIPT" --send
    [ "$status" -ne 0 ]
    [[ "$output" == *"required"* ]] || [[ "$output" == *"Usage"* ]]
}

@test "test_email.sh --send-verify - requires email argument" {
    run "$SCRIPT" --send-verify
    [ "$status" -ne 0 ]
    [[ "$output" == *"required"* ]] || [[ "$output" == *"Usage"* ]]
}

@test "test_email.sh - rejects unknown options" {
    run "$SCRIPT" --invalid-option
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown"* ]]
}

################################################################################
# Environment Variable Tests
################################################################################

@test "test_email.sh - respects DOMAIN environment variable" {
    DOMAIN="custom.example.com" run "$SCRIPT" --check-dns
    [[ "$output" == *"custom.example.com"* ]]
}

@test "test_email.sh - respects MAILPIT_URL environment variable" {
    MAILPIT_URL="http://custom:8025" run "$SCRIPT" --check-mailpit
    [[ "$output" == *"custom:8025"* ]] || [[ "$output" == *"NOT AVAILABLE"* ]]
}

################################################################################
# Function Existence Tests
################################################################################

@test "test_email.sh - defines check_dns function" {
    run grep -q "^check_dns()" "$SCRIPT"
    [ "$status" -eq 0 ]
}

@test "test_email.sh - defines check_services function" {
    run grep -q "^check_services()" "$SCRIPT"
    [ "$status" -eq 0 ]
}

@test "test_email.sh - defines check_logs function" {
    run grep -q "^check_logs()" "$SCRIPT"
    [ "$status" -eq 0 ]
}

@test "test_email.sh - defines check_blacklists function" {
    run grep -q "^check_blacklists()" "$SCRIPT"
    [ "$status" -eq 0 ]
}

@test "test_email.sh - defines send_test_email function" {
    run grep -q "^send_test_email()" "$SCRIPT"
    [ "$status" -eq 0 ]
}

@test "test_email.sh - defines send_and_verify_email function" {
    run grep -q "^send_and_verify_email()" "$SCRIPT"
    [ "$status" -eq 0 ]
}

@test "test_email.sh - defines check_mailpit function" {
    run grep -q "^check_mailpit()" "$SCRIPT"
    [ "$status" -eq 0 ]
}

################################################################################
# Security Tests
################################################################################

@test "test_email.sh - uses set -euo pipefail" {
    run grep -q "set -euo pipefail" "$SCRIPT"
    [ "$status" -eq 0 ]
}

@test "test_email.sh - sources mailpit-client library safely" {
    run grep -E 'source.*mailpit-client\.sh' "$SCRIPT"
    [ "$status" -eq 0 ]
    # Should check file exists before sourcing
    run grep -B2 'source.*mailpit-client\.sh' "$SCRIPT"
    [[ "$output" == *"-f"* ]]
}
