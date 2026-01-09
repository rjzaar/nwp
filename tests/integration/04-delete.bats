#!/usr/bin/env bats
################################################################################
# Integration Test: Site Deletion
#
# Tests site deletion with various flags
# Corresponds to Test 8b in COMPREHENSIVE_TESTING_PROPOSAL.md
#
# To run DDEV tests:
#   ENABLE_DDEV_TESTS=true bats tests/integration/04-delete.bats
# Or use the test runner:
#   ./tests/run-ddev-tests.sh 04-delete
################################################################################

load ../helpers/test-helpers

# Use "d" recipe (standard Drupal) for faster tests
TEST_RECIPE="${TEST_RECIPE:-d}"

# File-level setup - runs once before all tests
setup_file() {
    export PROJECT_ROOT="${BATS_TEST_DIRNAME}/../.."
    export TEST_SITE="${TEST_SITE_PREFIX:-bats-test}-delete"
}

# File-level teardown - runs once after all tests
teardown_file() {
    if [ "${CLEANUP_SITES:-true}" = "true" ]; then
        for site in "${TEST_SITE}" "${TEST_SITE}-backup"; do
            if [ -d "${PROJECT_ROOT}/sites/${site}" ]; then
                cd "${PROJECT_ROOT}"
                if [ -f "${PROJECT_ROOT}/sites/${site}/.ddev/config.yaml" ]; then
                    (cd "${PROJECT_ROOT}/sites/${site}" && ddev stop --unlist 2>/dev/null) || true
                fi
                ./scripts/commands/delete.sh -fy "${site}" 2>/dev/null || rm -rf "${PROJECT_ROOT}/sites/${site}"
            fi
        done
        # Cleanup any test backups
        rm -rf "${PROJECT_ROOT}/sitebackups/${TEST_SITE}"* 2>/dev/null || true
    fi
}

setup() {
    test_setup
    export PROJECT_ROOT="${BATS_TEST_DIRNAME}/../.."
    export TEST_SITE="${TEST_SITE_PREFIX:-bats-test}-delete"
}

teardown() {
    test_teardown
}

# Helper to conditionally skip DDEV tests
skip_unless_ddev_enabled() {
    [[ "${ENABLE_DDEV_TESTS:-false}" != "true" ]] && skip "DDEV tests disabled - set ENABLE_DDEV_TESTS=true to run"
    command -v ddev &>/dev/null || skip "DDEV not installed"
}

# Helper to create a test site for deletion tests
create_site_for_deletion() {
    local sitename="$1"
    cd "${PROJECT_ROOT}"
    # install.sh <recipe> <target> - auto mode via recipe config
    ./scripts/commands/install.sh "${TEST_RECIPE}" "${sitename}" || return 1
}

@test "delete: removes site with -y flag" {
    skip_unless_ddev_enabled

    cd "${PROJECT_ROOT}"

    # First create a test site
    create_site_for_deletion "${TEST_SITE}"

    # Verify it was created
    assert_dir_exists "sites/${TEST_SITE}"

    run ./scripts/commands/delete.sh -fy "${TEST_SITE}"
    echo "Output: $output"
    [ "$status" -eq 0 ]

    # Verify it was deleted
    [ ! -d "sites/${TEST_SITE}" ]
}

@test "delete: creates backup with -b flag" {
    skip_unless_ddev_enabled

    cd "${PROJECT_ROOT}"

    # Create a test site
    create_site_for_deletion "${TEST_SITE}-backup"

    run ./scripts/commands/delete.sh -bfy "${TEST_SITE}-backup"
    echo "Output: $output"
    [ "$status" -eq 0 ]

    # Verify backup was created
    assert_dir_exists "sitebackups/${TEST_SITE}-backup"

    # Site should be deleted
    [ ! -d "sites/${TEST_SITE}-backup" ]
}

# Unit-style tests
@test "delete.sh: exists and is executable" {
    assert_file_exists "${PROJECT_ROOT}/scripts/commands/delete.sh"
    [ -x "${PROJECT_ROOT}/scripts/commands/delete.sh" ]
}

@test "delete.sh: shows help message" {
    cd "${PROJECT_ROOT}"
    run ./scripts/commands/delete.sh --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage"* ]] || [[ "$output" == *"USAGE"* ]]
}

@test "delete.sh: requires sitename argument" {
    cd "${PROJECT_ROOT}"
    run ./scripts/commands/delete.sh -y
    [ "$status" -ne 0 ]
}

@test "delete.sh: validates sitename" {
    cd "${PROJECT_ROOT}"
    run ./scripts/commands/delete.sh -y "../dangerous"
    [ "$status" -ne 0 ]
}

@test "delete.sh: rejects non-existent site gracefully" {
    cd "${PROJECT_ROOT}"
    run ./scripts/commands/delete.sh -y "site-that-does-not-exist-12345"
    # Should fail but not crash
    [ "$status" -ne 0 ]
}
