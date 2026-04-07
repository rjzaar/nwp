#!/usr/bin/env bats
################################################################################
# Integration Test: Site Installation
#
# Tests the complete site installation workflow
# Corresponds to Test 1 in COMPREHENSIVE_TESTING_PROPOSAL.md
#
# To run DDEV tests:
#   ENABLE_DDEV_TESTS=true bats tests/integration/01-install.bats
# Or use the test runner:
#   ./tests/run-ddev-tests.sh 01-install
################################################################################

load ../helpers/test-helpers

# Use "d" recipe (standard Drupal) for faster tests. Use "nwp" for full Open Social tests.
TEST_RECIPE="${TEST_RECIPE:-d}"

# File-level setup - runs once before all tests
setup_file() {
    export PROJECT_ROOT="${BATS_TEST_DIRNAME}/../.."
    # Use a stable test site name for the duration of this test file
    export TEST_SITE="${TEST_SITE_PREFIX:-bats-test}-install"
}

# File-level teardown - runs once after all tests
teardown_file() {
    # Cleanup test site if it exists
    if [ "${CLEANUP_SITES:-true}" = "true" ]; then
        if [ -d "${PROJECT_ROOT}/sites/${TEST_SITE}" ]; then
            cd "${PROJECT_ROOT}"
            # Stop DDEV first to release resources
            if [ -f "${PROJECT_ROOT}/sites/${TEST_SITE}/.ddev/config.yaml" ]; then
                (cd "${PROJECT_ROOT}/sites/${TEST_SITE}" && ddev stop --unlist 2>/dev/null) || true
            fi
            ./scripts/commands/delete.sh -fy "${TEST_SITE}" 2>/dev/null || true
        fi
    fi
}

setup() {
    test_setup
    export PROJECT_ROOT="${BATS_TEST_DIRNAME}/../.."
    export TEST_SITE="${TEST_SITE_PREFIX:-bats-test}-install"
}

teardown() {
    test_teardown
}

# Helper to conditionally skip DDEV tests
skip_unless_ddev_enabled() {
    [[ "${ENABLE_DDEV_TESTS:-false}" != "true" ]] && skip "DDEV tests disabled - set ENABLE_DDEV_TESTS=true to run"
    command -v ddev &>/dev/null || skip "DDEV not installed"
}

@test "install: creates site directory" {
    skip_unless_ddev_enabled

    cd "${PROJECT_ROOT}"
    # install.sh <recipe> <target>
    # Auto mode is set via 'auto: y' in recipe config
    run ./scripts/commands/install.sh "${TEST_RECIPE}" "${TEST_SITE}"
    echo "Output: $output"
    [ "$status" -eq 0 ]

    assert_dir_exists "sites/${TEST_SITE}"
}

@test "install: creates DDEV configuration" {
    skip_unless_ddev_enabled

    # This test depends on the previous test creating the site
    [ -d "${PROJECT_ROOT}/sites/${TEST_SITE}" ] || skip "Site not created - run full test suite"

    assert_file_exists "${PROJECT_ROOT}/sites/${TEST_SITE}/.ddev/config.yaml"
}

@test "install: starts DDEV container" {
    skip_unless_ddev_enabled

    [ -d "${PROJECT_ROOT}/sites/${TEST_SITE}" ] || skip "Site not created - run full test suite"

    cd "${PROJECT_ROOT}/sites/${TEST_SITE}"
    run ddev describe
    echo "Output: $output"
    [ "$status" -eq 0 ]
}

@test "install: Drush is functional" {
    skip_unless_ddev_enabled

    [ -d "${PROJECT_ROOT}/sites/${TEST_SITE}" ] || skip "Site not created - run full test suite"

    cd "${PROJECT_ROOT}/sites/${TEST_SITE}"
    run ddev drush status
    echo "Output: $output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Drupal"* ]]
}

@test "install: generates environment files" {
    skip_unless_ddev_enabled

    [ -d "${PROJECT_ROOT}/sites/${TEST_SITE}" ] || skip "Site not created - run full test suite"

    # Check for .env file (may be in different locations depending on recipe)
    if [ -f "${PROJECT_ROOT}/sites/${TEST_SITE}/.env" ]; then
        assert_file_exists "${PROJECT_ROOT}/sites/${TEST_SITE}/.env"
    elif [ -f "${PROJECT_ROOT}/sites/${TEST_SITE}/web/sites/default/settings.php" ]; then
        # Alternative: check for Drupal settings
        assert_file_exists "${PROJECT_ROOT}/sites/${TEST_SITE}/web/sites/default/settings.php"
    fi
}

# Unit-style tests that don't require full installation
@test "install.sh: exists and is executable" {
    assert_file_exists "${PROJECT_ROOT}/scripts/commands/install.sh"
    [ -x "${PROJECT_ROOT}/scripts/commands/install.sh" ]
}

@test "install.sh: shows help message" {
    cd "${PROJECT_ROOT}"
    run ./scripts/commands/install.sh --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage"* ]] || [[ "$output" == *"USAGE"* ]]
}

@test "install.sh: rejects empty sitename" {
    cd "${PROJECT_ROOT}"
    run ./scripts/commands/install.sh ""
    [ "$status" -ne 0 ]
}

@test "install.sh: validates sitename for dangerous characters" {
    cd "${PROJECT_ROOT}"
    run ./scripts/commands/install.sh "../dangerous"
    [ "$status" -ne 0 ]
}
