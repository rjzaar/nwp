#!/usr/bin/env bats
################################################################################
# Integration Test: Site Deletion
#
# Tests site deletion with various flags
# Corresponds to Test 8b in COMPREHENSIVE_TESTING_PROPOSAL.md
################################################################################

load ../helpers/test-helpers

setup() {
    test_setup
    export PROJECT_ROOT="${BATS_TEST_DIRNAME}/../.."
}

teardown() {
    test_teardown
}

@test "delete: removes site with -y flag" {
    skip "Requires DDEV and full environment - run manually with test-nwp.sh"

    # This test requires a pre-existing test site
    cd "${PROJECT_ROOT}"
    run ./delete.sh -y "test-for-deletion"
    [ "$status" -eq 0 ]
}

@test "delete: creates backup with -b flag" {
    skip "Requires DDEV and full environment - run manually with test-nwp.sh"

    cd "${PROJECT_ROOT}"
    run ./delete.sh -by "test-for-deletion-backup"
    [ "$status" -eq 0 ]

    # Verify backup was created
    assert_dir_exists "sitebackups/test-for-deletion-backup"
}

@test "delete: keeps backups with -k flag" {
    skip "Requires DDEV and full environment - run manually with test-nwp.sh"

    cd "${PROJECT_ROOT}"
    run ./delete.sh -bky "test-for-deletion-keep"
    [ "$status" -eq 0 ]
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
