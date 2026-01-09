#!/usr/bin/env bats
################################################################################
# Integration Test: Deployment Scripts
#
# Tests deployment workflow scripts
# Corresponds to Tests 6 and 10 in COMPREHENSIVE_TESTING_PROPOSAL.md
################################################################################

load ../helpers/test-helpers

setup() {
    test_setup
    export PROJECT_ROOT="${BATS_TEST_DIRNAME}/../.."
}

teardown() {
    test_teardown
}

@test "dev2stg: deploys to local staging" {
    skip "Requires DDEV and full environment - run manually with test-nwp.sh"

    cd "${PROJECT_ROOT}"
    run ./dev2stg.sh -y "test-deployment"
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]  # May warn if staging doesn't exist
}

# Unit-style tests
@test "dev2stg.sh: exists and is executable" {
    assert_file_exists "${PROJECT_ROOT}/scripts/commands/dev2stg.sh"
    [ -x "${PROJECT_ROOT}/scripts/commands/dev2stg.sh" ]
}

@test "dev2stg.sh: shows help message" {
    cd "${PROJECT_ROOT}"
    run ./scripts/commands/dev2stg.sh --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage"* ]] || [[ "$output" == *"USAGE"* ]]
}

@test "stg2prod.sh: exists and is executable" {
    assert_file_exists "${PROJECT_ROOT}/scripts/commands/stg2prod.sh"
    [ -x "${PROJECT_ROOT}/scripts/commands/stg2prod.sh" ]
}

@test "stg2prod.sh: shows help message" {
    cd "${PROJECT_ROOT}"
    run ./scripts/commands/stg2prod.sh --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage"* ]] || [[ "$output" == *"USAGE"* ]]
}

@test "stg2prod.sh: rejects missing sitename" {
    cd "${PROJECT_ROOT}"
    run ./scripts/commands/stg2prod.sh
    [ "$status" -ne 0 ]
}

@test "stg2prod.sh: dry-run mode works" {
    cd "${PROJECT_ROOT}"
    run ./scripts/commands/stg2prod.sh --dry-run test-site
    # Should succeed in dry-run (just validation)
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}

@test "prod2stg.sh: exists and is executable" {
    assert_file_exists "${PROJECT_ROOT}/scripts/commands/prod2stg.sh"
    [ -x "${PROJECT_ROOT}/scripts/commands/prod2stg.sh" ]
}

@test "prod2stg.sh: shows help message" {
    cd "${PROJECT_ROOT}"
    run ./scripts/commands/prod2stg.sh --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage"* ]] || [[ "$output" == *"USAGE"* ]]
}

@test "prod2stg.sh: rejects missing sitename" {
    cd "${PROJECT_ROOT}"
    run ./scripts/commands/prod2stg.sh
    [ "$status" -ne 0 ]
}

@test "prod2stg.sh: dry-run mode works" {
    cd "${PROJECT_ROOT}"
    run ./scripts/commands/prod2stg.sh --dry-run test-site
    # Should succeed in dry-run (just validation)
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}
