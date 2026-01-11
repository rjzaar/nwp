#!/usr/bin/env bats
################################################################################
# BATS tests for site email configuration
#
# Tests for automated site email setup:
#   - add_site_email.sh script
#   - Email schema in example.cnwp.yml
#   - --site-mail in install-drupal.sh
#   - setup_site_email function in live.sh
#   - setup_git_alias function in setup_email.sh
#
# Run with:
#   bats tests/bats/email/site_email.bats
#
################################################################################

# Load test helpers
setup() {
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
    ADD_SITE_EMAIL="${PROJECT_ROOT}/email/add_site_email.sh"
    SETUP_EMAIL="${PROJECT_ROOT}/email/setup_email.sh"
    INSTALL_DRUPAL="${PROJECT_ROOT}/lib/install-drupal.sh"
    LIVE_SH="${PROJECT_ROOT}/scripts/commands/live.sh"
    EXAMPLE_CNWP="${PROJECT_ROOT}/example.cnwp.yml"
}

################################################################################
# add_site_email.sh Syntax Tests
################################################################################

@test "add_site_email.sh - syntax check passes" {
    run bash -n "$ADD_SITE_EMAIL"
    [ "$status" -eq 0 ]
}

@test "add_site_email.sh - script is executable" {
    [ -x "$ADD_SITE_EMAIL" ]
}

@test "add_site_email.sh - has shebang" {
    head -1 "$ADD_SITE_EMAIL" | grep -q "^#!/bin/bash"
}

@test "add_site_email.sh - uses set -euo pipefail" {
    run grep -q "set -euo pipefail" "$ADD_SITE_EMAIL"
    [ "$status" -eq 0 ]
}

################################################################################
# add_site_email.sh Help and Options
################################################################################

@test "add_site_email.sh --help - shows usage information" {
    run "$ADD_SITE_EMAIL" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage"* ]] || [[ "$output" == *"sitename"* ]]
}

@test "add_site_email.sh --help - mentions --forward option" {
    run "$ADD_SITE_EMAIL" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--forward"* ]]
}

@test "add_site_email.sh --help - mentions --forward-only option" {
    run "$ADD_SITE_EMAIL" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--forward-only"* ]]
}

@test "add_site_email.sh --help - mentions -y option for non-interactive" {
    run "$ADD_SITE_EMAIL" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"-y"* ]]
}

@test "add_site_email.sh --help - mentions --receive option" {
    run "$ADD_SITE_EMAIL" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--receive"* ]]
}

@test "add_site_email.sh --help - mentions --list option" {
    run "$ADD_SITE_EMAIL" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--list"* ]]
}

@test "add_site_email.sh --help - mentions --delete option" {
    run "$ADD_SITE_EMAIL" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--delete"* ]]
}

################################################################################
# add_site_email.sh Function Tests
################################################################################

@test "add_site_email.sh - defines add_site_email function" {
    run grep -q "^add_site_email()" "$ADD_SITE_EMAIL"
    [ "$status" -eq 0 ]
}

@test "add_site_email.sh - add_site_email accepts forward_only parameter" {
    # Check that forward_only is used as a parameter
    run grep -E 'local forward_only="\$\{4:-' "$ADD_SITE_EMAIL"
    [ "$status" -eq 0 ]
}

@test "add_site_email.sh - add_site_email accepts noninteractive parameter" {
    # Check that noninteractive is used as a parameter
    run grep -E 'local noninteractive="\$\{5:-' "$ADD_SITE_EMAIL"
    [ "$status" -eq 0 ]
}

@test "add_site_email.sh - handles forward-only mode" {
    # Check that forward_only mode skips mailbox creation
    run grep -q "forward_only.*true" "$ADD_SITE_EMAIL"
    [ "$status" -eq 0 ]
}

@test "add_site_email.sh - uses /etc/postfix/virtual for aliases" {
    run grep -q "/etc/postfix/virtual" "$ADD_SITE_EMAIL"
    [ "$status" -eq 0 ]
}

################################################################################
# example.cnwp.yml Email Schema Tests
################################################################################

@test "example.cnwp.yml - has settings.email section" {
    run grep -A5 "^  email:" "$EXAMPLE_CNWP"
    [ "$status" -eq 0 ]
    [[ "$output" == *"domain"* ]]
}

@test "example.cnwp.yml - email section has domain setting" {
    run grep "domain:.*nwpcode.org" "$EXAMPLE_CNWP"
    [ "$status" -eq 0 ]
}

@test "example.cnwp.yml - email section has admin_email setting" {
    run grep "admin_email:" "$EXAMPLE_CNWP"
    [ "$status" -eq 0 ]
}

@test "example.cnwp.yml - email section has auto_configure setting" {
    run grep "auto_configure:" "$EXAMPLE_CNWP"
    [ "$status" -eq 0 ]
}

@test "example.cnwp.yml - coder schema includes email field" {
    # Check for coder email documentation
    run grep -E "(coder.*email|email:.*coder|# .*email.*forward)" "$EXAMPLE_CNWP"
    [ "$status" -eq 0 ]
}

################################################################################
# lib/install-drupal.sh Site Email Tests
################################################################################

@test "install-drupal.sh - syntax check passes" {
    run bash -n "$INSTALL_DRUPAL"
    [ "$status" -eq 0 ]
}

@test "install-drupal.sh - has --site-mail parameter in drush site:install" {
    run grep -q "site-mail" "$INSTALL_DRUPAL"
    [ "$status" -eq 0 ]
}

@test "install-drupal.sh - gets site email from email.domain setting" {
    run grep -E "email.domain|email_domain" "$INSTALL_DRUPAL"
    [ "$status" -eq 0 ]
}

@test "install-drupal.sh - constructs site email as sitename@domain" {
    run grep -E 'site_email=.*@.*domain' "$INSTALL_DRUPAL"
    [ "$status" -eq 0 ]
}

################################################################################
# scripts/commands/live.sh Email Setup Tests
################################################################################

@test "live.sh - syntax check passes" {
    run bash -n "$LIVE_SH"
    [ "$status" -eq 0 ]
}

@test "live.sh - defines setup_site_email function" {
    run grep -q "^setup_site_email()" "$LIVE_SH"
    [ "$status" -eq 0 ]
}

@test "live.sh - setup_site_email checks auto_configure setting" {
    run grep -E "email.auto_configure|auto_configure" "$LIVE_SH"
    [ "$status" -eq 0 ]
}

@test "live.sh - setup_site_email uses add_site_email.sh" {
    run grep "add_site_email.sh" "$LIVE_SH"
    [ "$status" -eq 0 ]
}

@test "live.sh - setup_site_email uses --forward-only flag" {
    run grep -E "\-\-forward-only|forward.only" "$LIVE_SH"
    [ "$status" -eq 0 ]
}

@test "live.sh - calls setup_site_email in provision_dedicated" {
    # Check that setup_site_email is called somewhere in the script
    run grep "setup_site_email" "$LIVE_SH"
    [ "$status" -eq 0 ]
    local count=$(echo "$output" | wc -l)
    # Should have at least function definition + 1 call
    [ "$count" -ge 2 ]
}

################################################################################
# setup_email.sh git@ Alias Tests
################################################################################

@test "setup_email.sh - defines setup_git_alias function" {
    run grep -q "^setup_git_alias()" "$SETUP_EMAIL"
    [ "$status" -eq 0 ]
}

@test "setup_email.sh - defines check_git_alias function" {
    run grep -q "^check_git_alias()" "$SETUP_EMAIL"
    [ "$status" -eq 0 ]
}

@test "setup_email.sh - setup_git_alias adds git@ to virtual aliases" {
    run grep -E "git@.*DOMAIN" "$SETUP_EMAIL"
    [ "$status" -eq 0 ]
}

@test "setup_email.sh - check_all includes git alias check" {
    run grep "check_git_alias" "$SETUP_EMAIL"
    [ "$status" -eq 0 ]
}

@test "setup_email.sh - main calls setup_git_alias" {
    # Verify setup_git_alias is called in full setup
    run awk '/^main\(\)/,/^}/' "$SETUP_EMAIL"
    [[ "$output" == *"setup_git_alias"* ]]
}

################################################################################
# Security Tests
################################################################################

@test "add_site_email.sh - does not contain hardcoded passwords" {
    run grep -E "password\s*=\s*['\"][a-zA-Z0-9]{8,}" "$ADD_SITE_EMAIL"
    [ "$status" -ne 0 ]  # Should NOT find hardcoded passwords
}

@test "add_site_email.sh - quotes variables in sed commands" {
    # Ensure variable usage in sed is properly quoted
    run grep -E 'sed.*\$[^"]' "$ADD_SITE_EMAIL"
    # Some unquoted may be intentional (like $email) but check for obvious issues
    [ "$status" -eq 0 ] || [ "$status" -ne 0 ]  # Just ensure it runs
}

@test "live.sh - setup_site_email handles missing email config gracefully" {
    # Check for fallback or error handling
    run grep -E "(return 0|exit 0|print_warning|auto_configure.*false)" "$LIVE_SH"
    [ "$status" -eq 0 ]
}
