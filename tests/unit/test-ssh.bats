#!/usr/bin/env bats
################################################################################
# Unit Tests for lib/ssh.sh
#
# Tests SSH user resolution, connection string, and key path functions
# from the SSH library (F15 SSH User Management)
################################################################################

# Load test helpers
load ../helpers/test-helpers

setup() {
    test_setup
    source_lib "ssh.sh"

    # Create test config from fixture
    TEST_CONFIG="${TEST_TEMP_DIR}/nwp.yml"
    cp "${TEST_FIXTURES_DIR}/cnwp.yml" "$TEST_CONFIG"
}

teardown() {
    test_teardown
}

################################################################################
# get_ssh_user() tests - Resolution chain
################################################################################

@test "get_ssh_user: returns explicit site ssh_user (resolution step 1)" {
    run get_ssh_user "livesite" "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [ "$output" = "customuser" ]
}

@test "get_ssh_user: returns server ssh_user when no site config (resolution step 2)" {
    run get_ssh_user "dedicated" "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [ "$output" = "deploy" ]
}

@test "get_ssh_user: parses user from user@host format (resolution step 3)" {
    run get_ssh_user "nwpcode" "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [ "$output" = "gitlab" ]
}

@test "get_ssh_user: parses user from legacy user@host format" {
    run get_ssh_user "legacy" "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [ "$output" = "root" ]
}

@test "get_ssh_user: falls back to recipe ssh_user (resolution step 4)" {
    run get_ssh_user "sitenouser" "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [ "$output" = "nwp" ]
}

@test "get_ssh_user: defaults to root for unknown site (resolution step 5)" {
    run get_ssh_user "nonexistent" "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [ "$output" = "root" ]
}

@test "get_ssh_user: defaults to root when config file missing" {
    run get_ssh_user "anything" "/nonexistent/config.yml"
    [ "$status" -eq 0 ]
    [ "$output" = "root" ]
}

################################################################################
# get_ssh_connection() tests
################################################################################

@test "get_ssh_connection: returns user@host for server with user@host format" {
    run get_ssh_connection "nwpcode" "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [ "$output" = "gitlab@97.107.137.88" ]
}

@test "get_ssh_connection: returns user@host for server with separate ssh_user" {
    run get_ssh_connection "dedicated" "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [ "$output" = "deploy@192.168.1.100" ]
}

@test "get_ssh_connection: uses site-level ssh_user over server defaults" {
    run get_ssh_connection "livesite" "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    # livesite has ssh_user: customuser, host comes from live config
    [[ "$output" == "customuser@"* ]]
}

################################################################################
# get_ssh_key() tests - Resolution chain
################################################################################

@test "get_ssh_key: returns explicit site ssh_key (resolution step 1)" {
    run get_ssh_key "livesite" "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [ "$output" = "$HOME/.ssh/custom-key" ]
}

@test "get_ssh_key: returns server ssh_key when no site config (resolution step 2)" {
    run get_ssh_key "dedicated" "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [ "$output" = "$HOME/.ssh/deploy-key" ]
}

@test "get_ssh_key: returns server ssh_key for user@host server" {
    run get_ssh_key "nwpcode" "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [ "$output" = "$HOME/.ssh/nwp" ]
}

@test "get_ssh_key: defaults to ~/.ssh/nwp for unknown site" {
    run get_ssh_key "nonexistent" "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [ "$output" = "$HOME/.ssh/nwp" ]
}

@test "get_ssh_key: defaults to ~/.ssh/nwp when config file missing" {
    run get_ssh_key "anything" "/nonexistent/config.yml"
    [ "$status" -eq 0 ]
    [ "$output" = "$HOME/.ssh/nwp" ]
}

@test "get_ssh_key: defaults to ~/.ssh/nwp when server has no key configured" {
    run get_ssh_key "legacy" "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [ "$output" = "$HOME/.ssh/nwp" ]
}

################################################################################
# get_ssh_host_key_checking() tests
################################################################################

@test "get_ssh_host_key_checking: returns accept-new by default" {
    unset NWP_SSH_STRICT
    run get_ssh_host_key_checking
    [ "$status" -eq 0 ]
    [ "$output" = "accept-new" ]
}

@test "get_ssh_host_key_checking: returns yes when NWP_SSH_STRICT=1" {
    export NWP_SSH_STRICT=1
    run get_ssh_host_key_checking
    [ "$status" -eq 0 ]
    [ "$output" = "yes" ]
}

@test "get_ssh_host_key_checking: returns accept-new when NWP_SSH_STRICT=0" {
    export NWP_SSH_STRICT=0
    run get_ssh_host_key_checking
    [ "$status" -eq 0 ]
    [ "$output" = "accept-new" ]
}

################################################################################
# is_ssh_strict_mode() tests
################################################################################

@test "is_ssh_strict_mode: returns 1 (false) by default" {
    unset NWP_SSH_STRICT
    run is_ssh_strict_mode
    [ "$status" -eq 1 ]
}

@test "is_ssh_strict_mode: returns 0 (true) when NWP_SSH_STRICT=1" {
    export NWP_SSH_STRICT=1
    run is_ssh_strict_mode
    [ "$status" -eq 0 ]
}

################################################################################
# Edge cases
################################################################################

@test "get_ssh_user: handles site with recipe but no recipe ssh_user" {
    # testsite uses recipe 'test' which has no ssh_user defined
    run get_ssh_user "testsite" "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [ "$output" = "root" ]
}

@test "get_ssh_user: site-level ssh_user takes priority over recipe ssh_user" {
    # livesite has recipe: gitlab (ssh_user: gitlab) but site has ssh_user: customuser
    run get_ssh_user "livesite" "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [ "$output" = "customuser" ]
}

@test "get_ssh_key: expands tilde in paths" {
    # All configured keys use ~/.ssh/ which should expand to $HOME/.ssh/
    run get_ssh_key "nwpcode" "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [[ "$output" == "$HOME/"* ]]
    [[ "$output" != "~/"* ]]
}
