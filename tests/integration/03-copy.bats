#!/usr/bin/env bats
################################################################################
# Integration Test: Site Copy
#
# Tests site cloning functionality
# Corresponds to Test 4 in COMPREHENSIVE_TESTING_PROPOSAL.md
################################################################################

load ../helpers/test-helpers

TEST_SITE="test-integration-source"
TEST_COPY="test-integration-copy"

setup() {
    test_setup
    export PROJECT_ROOT="${BATS_TEST_DIRNAME}/../.."
}

teardown() {
    # Cleanup copy site
    if [ "${CLEANUP_SITES:-true}" = "true" ]; then
        if [ -d "${PROJECT_ROOT}/sites/${TEST_COPY}" ]; then
            cd "${PROJECT_ROOT}"
            ./scripts/commands/delete.sh -fy "${TEST_COPY}" 2>/dev/null || true
        fi
    fi
    test_teardown
}

@test "copy: creates full copy of site" {
    skip "Requires DDEV and full environment - run manually with test-nwp.sh"

    cd "${PROJECT_ROOT}"
    run ./copy.sh -y "${TEST_SITE}" "${TEST_COPY}"
    [ "$status" -eq 0 ]

    assert_dir_exists "sites/${TEST_COPY}"
}

@test "copy: copied site has DDEV config" {
    skip "Requires DDEV and full environment - run manually with test-nwp.sh"

    assert_file_exists "sites/${TEST_COPY}/.ddev/config.yaml"
}

@test "copy: copied site is running" {
    skip "Requires DDEV and full environment - run manually with test-nwp.sh"

    cd "${PROJECT_ROOT}/sites/${TEST_COPY}"
    run ddev describe
    [ "$status" -eq 0 ]
}

@test "copy: files-only copy with -f flag" {
    skip "Requires DDEV and full environment - run manually with test-nwp.sh"

    cd "${PROJECT_ROOT}"
    run ./copy.sh -fy "${TEST_SITE}" "${TEST_COPY}-files"
    # This should warn but not fail completely
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}

# Unit-style tests
@test "copy.sh: exists and is executable" {
    assert_file_exists "${PROJECT_ROOT}/copy.sh"
    [ -x "${PROJECT_ROOT}/copy.sh" ]
}

@test "copy.sh: shows help message" {
    cd "${PROJECT_ROOT}"
    run ./copy.sh --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage"* ]] || [[ "$output" == *"USAGE"* ]]
}

@test "copy.sh: requires source sitename" {
    cd "${PROJECT_ROOT}"
    run ./copy.sh
    [ "$status" -ne 0 ]
}

@test "copy.sh: requires destination sitename" {
    cd "${PROJECT_ROOT}"
    run ./copy.sh "${TEST_SITE}"
    [ "$status" -ne 0 ]
}

@test "copy.sh: validates source sitename" {
    cd "${PROJECT_ROOT}"
    run ./copy.sh "../bad" "destination"
    [ "$status" -ne 0 ]
}

@test "copy.sh: validates destination sitename" {
    cd "${PROJECT_ROOT}"
    run ./copy.sh "source" "../bad"
    [ "$status" -ne 0 ]
}
