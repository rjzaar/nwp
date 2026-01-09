#!/usr/bin/env bats
################################################################################
# Integration Test: Backup and Restore
#
# Tests backup creation and restoration
# Corresponds to Tests 2 and 3 in COMPREHENSIVE_TESTING_PROPOSAL.md
#
# To run DDEV tests:
#   ENABLE_DDEV_TESTS=true bats tests/integration/02-backup-restore.bats
# Or use the test runner:
#   ./tests/run-ddev-tests.sh 02-backup-restore
################################################################################

load ../helpers/test-helpers

# Use "d" recipe (standard Drupal) for faster tests
TEST_RECIPE="${TEST_RECIPE:-d}"

# File-level setup - runs once before all tests
setup_file() {
    export PROJECT_ROOT="${BATS_TEST_DIRNAME}/../.."
    export TEST_SITE="${TEST_SITE_PREFIX:-bats-test}-backup"
}

# File-level teardown - runs once after all tests
teardown_file() {
    if [ "${CLEANUP_SITES:-true}" = "true" ]; then
        if [ -d "${PROJECT_ROOT}/sites/${TEST_SITE}" ]; then
            cd "${PROJECT_ROOT}"
            if [ -f "${PROJECT_ROOT}/sites/${TEST_SITE}/.ddev/config.yaml" ]; then
                (cd "${PROJECT_ROOT}/sites/${TEST_SITE}" && ddev stop --unlist 2>/dev/null) || true
            fi
            ./scripts/commands/delete.sh -fy "${TEST_SITE}" 2>/dev/null || true
        fi
        # Clean up backup directory
        if [ -d "${PROJECT_ROOT}/sitebackups/${TEST_SITE}" ]; then
            rm -rf "${PROJECT_ROOT}/sitebackups/${TEST_SITE}"
        fi
    fi
}

setup() {
    test_setup
    export PROJECT_ROOT="${BATS_TEST_DIRNAME}/../.."
    export TEST_SITE="${TEST_SITE_PREFIX:-bats-test}-backup"
}

teardown() {
    test_teardown
}

# Helper to conditionally skip DDEV tests
skip_unless_ddev_enabled() {
    [[ "${ENABLE_DDEV_TESTS:-false}" != "true" ]] && skip "DDEV tests disabled - set ENABLE_DDEV_TESTS=true to run"
    command -v ddev &>/dev/null || skip "DDEV not installed"
}

# Helper to ensure a test site exists
ensure_test_site() {
    if [ ! -d "${PROJECT_ROOT}/sites/${TEST_SITE}" ]; then
        cd "${PROJECT_ROOT}"
        # install.sh <recipe> <target> - auto mode via recipe config
        ./scripts/commands/install.sh "${TEST_RECIPE}" "${TEST_SITE}" || return 1
    fi
}

@test "backup: full site backup can be created" {
    skip_unless_ddev_enabled

    cd "${PROJECT_ROOT}"

    # First create a test site
    ensure_test_site

    run ./scripts/commands/backup.sh "${TEST_SITE}"
    echo "Output: $output"
    [ "$status" -eq 0 ]

    assert_dir_exists "sitebackups/${TEST_SITE}"
}

@test "backup: database-only backup with -b flag" {
    skip_unless_ddev_enabled

    cd "${PROJECT_ROOT}"

    # Ensure test site exists
    [ -d "${PROJECT_ROOT}/sites/${TEST_SITE}" ] || skip "Site not created - run full test suite"

    run ./scripts/commands/backup.sh -b "${TEST_SITE}"
    echo "Output: $output"
    [ "$status" -eq 0 ]
}

@test "restore: can restore from backup" {
    skip_unless_ddev_enabled

    cd "${PROJECT_ROOT}"

    # Ensure test site and backup exist
    [ -d "${PROJECT_ROOT}/sites/${TEST_SITE}" ] || skip "Site not created - run full test suite"
    [ -d "${PROJECT_ROOT}/sitebackups/${TEST_SITE}" ] || skip "Backup not created - run full test suite"

    # Check backup files exist
    local backup_count
    backup_count=$(ls sitebackups/${TEST_SITE}/*.sql 2>/dev/null | wc -l)
    [ "$backup_count" -gt 0 ] || skip "No backup files found"

    # Restore using site name with -f (auto-select latest) and -y (auto-confirm)
    run ./scripts/commands/restore.sh -fy "${TEST_SITE}"
    echo "Output: $output"
    [ "$status" -eq 0 ]
}

# Unit-style tests
@test "backup.sh: exists and is executable" {
    assert_file_exists "${PROJECT_ROOT}/scripts/commands/backup.sh"
    [ -x "${PROJECT_ROOT}/scripts/commands/backup.sh" ]
}

@test "backup.sh: shows help message" {
    cd "${PROJECT_ROOT}"
    run ./scripts/commands/backup.sh --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage"* ]] || [[ "$output" == *"USAGE"* ]]
}

@test "backup.sh: rejects missing sitename" {
    cd "${PROJECT_ROOT}"
    run ./scripts/commands/backup.sh
    [ "$status" -ne 0 ]
}

@test "restore.sh: exists and is executable" {
    assert_file_exists "${PROJECT_ROOT}/scripts/commands/restore.sh"
    [ -x "${PROJECT_ROOT}/scripts/commands/restore.sh" ]
}

@test "restore.sh: shows help message" {
    cd "${PROJECT_ROOT}"
    run ./scripts/commands/restore.sh --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage"* ]] || [[ "$output" == *"USAGE"* ]]
}

@test "restore.sh: rejects missing backup file" {
    cd "${PROJECT_ROOT}"
    run ./scripts/commands/restore.sh
    [ "$status" -ne 0 ]
}
