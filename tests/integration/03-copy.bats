#!/usr/bin/env bats
################################################################################
# Integration Test: Site Copy
#
# Tests site cloning functionality
# Corresponds to Test 4 in COMPREHENSIVE_TESTING_PROPOSAL.md
#
# To run DDEV tests:
#   ENABLE_DDEV_TESTS=true bats tests/integration/03-copy.bats
# Or use the test runner:
#   ./tests/run-ddev-tests.sh 03-copy
################################################################################

load ../helpers/test-helpers

# Use "d" recipe (standard Drupal) for faster tests
TEST_RECIPE="${TEST_RECIPE:-d}"

# File-level setup - runs once before all tests
setup_file() {
    export PROJECT_ROOT="${BATS_TEST_DIRNAME}/../.."
    export TEST_SITE="${TEST_SITE_PREFIX:-bats-test}-copy-src"
    export TEST_COPY="${TEST_SITE_PREFIX:-bats-test}-copy-dst"
}

# File-level teardown - runs once after all tests
teardown_file() {
    if [ "${CLEANUP_SITES:-true}" = "true" ]; then
        for site in "${TEST_SITE}" "${TEST_COPY}"; do
            if [ -d "${PROJECT_ROOT}/sites/${site}" ]; then
                cd "${PROJECT_ROOT}"
                if [ -f "${PROJECT_ROOT}/sites/${site}/.ddev/config.yaml" ]; then
                    (cd "${PROJECT_ROOT}/sites/${site}" && ddev stop --unlist 2>/dev/null) || true
                fi
                ./scripts/commands/delete.sh -fy "${site}" 2>/dev/null || rm -rf "${PROJECT_ROOT}/sites/${site}"
            fi
        done
    fi
}

setup() {
    test_setup
    export PROJECT_ROOT="${BATS_TEST_DIRNAME}/../.."
    export TEST_SITE="${TEST_SITE_PREFIX:-bats-test}-copy-src"
    export TEST_COPY="${TEST_SITE_PREFIX:-bats-test}-copy-dst"
}

teardown() {
    test_teardown
}

# Helper to conditionally skip DDEV tests
skip_unless_ddev_enabled() {
    [[ "${ENABLE_DDEV_TESTS:-false}" != "true" ]] && skip "DDEV tests disabled - set ENABLE_DDEV_TESTS=true to run"
    command -v ddev &>/dev/null || skip "DDEV not installed"
}

# Helper to ensure source site exists
ensure_source_site() {
    if [ ! -d "${PROJECT_ROOT}/sites/${TEST_SITE}" ]; then
        cd "${PROJECT_ROOT}"
        # install.sh <recipe> <target> - auto mode via recipe config
        ./scripts/commands/install.sh "${TEST_RECIPE}" "${TEST_SITE}" || return 1
    fi
}

@test "copy: creates full copy of site" {
    skip_unless_ddev_enabled

    cd "${PROJECT_ROOT}"

    # First create a source site
    ensure_source_site

    run ./scripts/commands/copy.sh -y "${TEST_SITE}" "${TEST_COPY}"
    echo "Output: $output"
    [ "$status" -eq 0 ]

    assert_dir_exists "sites/${TEST_COPY}"
}

@test "copy: copied site has DDEV config" {
    skip_unless_ddev_enabled

    [ -d "${PROJECT_ROOT}/sites/${TEST_COPY}" ] || skip "Copy site not created - run full test suite"

    assert_file_exists "${PROJECT_ROOT}/sites/${TEST_COPY}/.ddev/config.yaml"
}

@test "copy: copied site is running" {
    skip_unless_ddev_enabled

    [ -d "${PROJECT_ROOT}/sites/${TEST_COPY}" ] || skip "Copy site not created - run full test suite"

    cd "${PROJECT_ROOT}/sites/${TEST_COPY}"
    run ddev describe
    echo "Output: $output"
    [ "$status" -eq 0 ]
}

# Unit-style tests
@test "copy.sh: exists and is executable" {
    assert_file_exists "${PROJECT_ROOT}/scripts/commands/copy.sh"
    [ -x "${PROJECT_ROOT}/scripts/commands/copy.sh" ]
}

@test "copy.sh: shows help message" {
    cd "${PROJECT_ROOT}"
    run ./scripts/commands/copy.sh --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage"* ]] || [[ "$output" == *"USAGE"* ]]
}

@test "copy.sh: requires source sitename" {
    cd "${PROJECT_ROOT}"
    run ./scripts/commands/copy.sh
    [ "$status" -ne 0 ]
}

@test "copy.sh: requires destination sitename" {
    cd "${PROJECT_ROOT}"
    run ./scripts/commands/copy.sh "${TEST_SITE}"
    [ "$status" -ne 0 ]
}

@test "copy.sh: validates source sitename" {
    cd "${PROJECT_ROOT}"
    run ./scripts/commands/copy.sh "../bad" "destination"
    [ "$status" -ne 0 ]
}

@test "copy.sh: validates destination sitename" {
    cd "${PROJECT_ROOT}"
    run ./scripts/commands/copy.sh "source" "../bad"
    [ "$status" -ne 0 ]
}
