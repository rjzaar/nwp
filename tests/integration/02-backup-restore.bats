#!/usr/bin/env bats
################################################################################
# Integration Test: Backup and Restore
#
# Tests backup creation and restoration
# Corresponds to Tests 2 and 3 in COMPREHENSIVE_TESTING_PROPOSAL.md
################################################################################

load ../helpers/test-helpers

TEST_SITE="test-integration-backup"

setup() {
    test_setup
    export PROJECT_ROOT="${BATS_TEST_DIRNAME}/../.."
}

teardown() {
    test_teardown
}

@test "backup: full site backup can be created" {
    skip "Requires DDEV and full environment - run manually with test-nwp.sh"

    cd "${PROJECT_ROOT}"
    run ./backup.sh -y "${TEST_SITE}"
    [ "$status" -eq 0 ]

    assert_dir_exists "sitebackups/${TEST_SITE}"
}

@test "backup: database-only backup with -b flag" {
    skip "Requires DDEV and full environment - run manually with test-nwp.sh"

    cd "${PROJECT_ROOT}"
    run ./backup.sh -by "${TEST_SITE}"
    [ "$status" -eq 0 ]
}

@test "restore: can restore from backup" {
    skip "Requires DDEV and full environment - run manually with test-nwp.sh"

    cd "${PROJECT_ROOT}"
    # Get latest backup
    local backup=$(ls -t sitebackups/${TEST_SITE}/*.tar.gz | head -1)
    run ./restore.sh -fy "${backup}"
    [ "$status" -eq 0 ]
}

# Unit-style tests
@test "backup.sh: exists and is executable" {
    assert_file_exists "${PROJECT_ROOT}/backup.sh"
    [ -x "${PROJECT_ROOT}/backup.sh" ]
}

@test "backup.sh: shows help message" {
    cd "${PROJECT_ROOT}"
    run ./backup.sh --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage"* ]] || [[ "$output" == *"USAGE"* ]]
}

@test "backup.sh: rejects missing sitename" {
    cd "${PROJECT_ROOT}"
    run ./backup.sh
    [ "$status" -ne 0 ]
}

@test "restore.sh: exists and is executable" {
    assert_file_exists "${PROJECT_ROOT}/restore.sh"
    [ -x "${PROJECT_ROOT}/restore.sh" ]
}

@test "restore.sh: shows help message" {
    cd "${PROJECT_ROOT}"
    run ./restore.sh --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage"* ]] || [[ "$output" == *"USAGE"* ]]
}

@test "restore.sh: rejects missing backup file" {
    cd "${PROJECT_ROOT}"
    run ./restore.sh
    [ "$status" -ne 0 ]
}
