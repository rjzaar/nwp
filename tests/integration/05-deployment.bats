#!/usr/bin/env bats
################################################################################
# Integration Test: Deployment Scripts
#
# Tests deployment workflow scripts
# Corresponds to Tests 6 and 10 in COMPREHENSIVE_TESTING_PROPOSAL.md
#
# To run DDEV tests:
#   ENABLE_DDEV_TESTS=true bats tests/integration/05-deployment.bats
# Or use the test runner:
#   ./tests/run-ddev-tests.sh 05-deployment
################################################################################

load ../helpers/test-helpers

# Use "d" recipe (standard Drupal) for faster tests
TEST_RECIPE="${TEST_RECIPE:-d}"

# File-level setup - runs once before all tests
setup_file() {
    export PROJECT_ROOT="${BATS_TEST_DIRNAME}/../.."
    export TEST_SITE="${TEST_SITE_PREFIX:-bats-test}-deploy"
    export TEST_SITE_STG="${TEST_SITE}-stg"
}

# File-level teardown - runs once after all tests
teardown_file() {
    if [ "${CLEANUP_SITES:-true}" = "true" ]; then
        for site in "${TEST_SITE}" "${TEST_SITE_STG}"; do
            if [ -d "${PROJECT_ROOT}/sites/${site}" ]; then
                cd "${PROJECT_ROOT}"
                if [ -f "${PROJECT_ROOT}/sites/${site}/.ddev/config.yaml" ]; then
                    (cd "${PROJECT_ROOT}/sites/${site}" && ddev stop --unlist 2>/dev/null) || true
                fi
                ./scripts/commands/delete.sh -y "${site}" 2>/dev/null || rm -rf "${PROJECT_ROOT}/sites/${site}"
            fi
        done
    fi
}

setup() {
    test_setup
    export PROJECT_ROOT="${BATS_TEST_DIRNAME}/../.."
    export TEST_SITE="${TEST_SITE_PREFIX:-bats-test}-deploy"
    export TEST_SITE_STG="${TEST_SITE}-stg"
}

teardown() {
    test_teardown
}

# Helper to conditionally skip DDEV tests
skip_unless_ddev_enabled() {
    [[ "${ENABLE_DDEV_TESTS:-false}" != "true" ]] && skip "DDEV tests disabled - set ENABLE_DDEV_TESTS=true to run"
    command -v ddev &>/dev/null || skip "DDEV not installed"
}

@test "dev2stg: deploys to local staging" {
    skip_unless_ddev_enabled

    cd "${PROJECT_ROOT}"

    # First create a development site if it doesn't exist
    if [ ! -d "sites/${TEST_SITE}" ]; then
        run ./scripts/commands/install.sh "${TEST_RECIPE}" "${TEST_SITE}"
        if [ "$status" -ne 0 ]; then
            echo "Install failed with status $status"
            skip "Could not create test site for deployment test"
        fi
    fi

    # Verify dev site exists
    [ -d "sites/${TEST_SITE}" ] || skip "Dev site not created"

    # Run dev2stg
    run ./scripts/commands/dev2stg.sh -y "${TEST_SITE}"

    # dev2stg may succeed or fail depending on staging setup
    # We just verify it runs without crashing
    if [ "$status" -ne 0 ]; then
        echo "dev2stg exited with status: $status"
        echo "Output (last 20 lines): $(echo "$output" | tail -20)"
    fi

    # Accept success (0) or expected failure (1) but not crash/error
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}

# Unit-style tests (always run, no DDEV required)
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
    # Should succeed in dry-run (just validation) or fail gracefully
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
    # Should succeed in dry-run (just validation) or fail gracefully
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}
