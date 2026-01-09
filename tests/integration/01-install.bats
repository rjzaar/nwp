#!/usr/bin/env bats
################################################################################
# Integration Test: Site Installation
#
# Tests the complete site installation workflow
# Corresponds to Test 1 in COMPREHENSIVE_TESTING_PROPOSAL.md
################################################################################

load ../helpers/test-helpers

# Test configuration
TEST_SITE="test-integration-install"
TEST_RECIPE="nwp"

setup() {
    test_setup
    export PROJECT_ROOT="${BATS_TEST_DIRNAME}/../.."
}

teardown() {
    # Cleanup test site if it exists (optional - can skip for debugging)
    if [ "${CLEANUP_SITES:-true}" = "true" ]; then
        if [ -d "${PROJECT_ROOT}/sites/${TEST_SITE}" ]; then
            cd "${PROJECT_ROOT}"
            ./scripts/commands/delete.sh -fy "${TEST_SITE}" 2>/dev/null || true
        fi
    fi
    test_teardown
}

@test "install: creates site directory" {
    skip "Requires DDEV and full environment - run manually with test-nwp.sh"

    cd "${PROJECT_ROOT}"
    run ./install.sh -y "${TEST_SITE}" "${TEST_RECIPE}"
    [ "$status" -eq 0 ]

    assert_dir_exists "sites/${TEST_SITE}"
}

@test "install: creates DDEV configuration" {
    skip "Requires DDEV and full environment - run manually with test-nwp.sh"

    assert_file_exists "sites/${TEST_SITE}/.ddev/config.yaml"
}

@test "install: starts DDEV container" {
    skip "Requires DDEV and full environment - run manually with test-nwp.sh"

    cd "${PROJECT_ROOT}/sites/${TEST_SITE}"
    run ddev describe
    [ "$status" -eq 0 ]
}

@test "install: Drush is functional" {
    skip "Requires DDEV and full environment - run manually with test-nwp.sh"

    cd "${PROJECT_ROOT}/sites/${TEST_SITE}"
    run ddev drush status
    [ "$status" -eq 0 ]
    [[ "$output" == *"Drupal"* ]]
}

@test "install: generates environment files" {
    skip "Requires DDEV and full environment - run manually with test-nwp.sh"

    assert_file_exists "sites/${TEST_SITE}/.env"
    assert_file_exists "sites/${TEST_SITE}/.env.local.example"
}

# Unit-style tests that don't require full installation
@test "install.sh: exists and is executable" {
    assert_file_exists "${PROJECT_ROOT}/install.sh"
    [ -x "${PROJECT_ROOT}/install.sh" ]
}

@test "install.sh: shows help message" {
    cd "${PROJECT_ROOT}"
    run ./install.sh --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage"* ]] || [[ "$output" == *"USAGE"* ]]
}

@test "install.sh: rejects empty sitename" {
    cd "${PROJECT_ROOT}"
    run ./install.sh ""
    [ "$status" -ne 0 ]
}

@test "install.sh: validates sitename for dangerous characters" {
    cd "${PROJECT_ROOT}"
    run ./install.sh "../dangerous"
    [ "$status" -ne 0 ]
}
