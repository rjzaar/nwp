#!/usr/bin/env bats
################################################################################
# Integration Test: Script Validation
#
# Tests that all core scripts exist and have valid syntax
# Corresponds to Tests 9 and 22 in COMPREHENSIVE_TESTING_PROPOSAL.md
################################################################################

load ../helpers/test-helpers

setup() {
    test_setup
    export PROJECT_ROOT="${BATS_TEST_DIRNAME}/../.."
}

teardown() {
    test_teardown
}

################################################################################
# Core Script Existence Tests
################################################################################

@test "install.sh: exists and is executable" {
    assert_file_exists "${PROJECT_ROOT}/scripts/commands/install.sh"
    [ -x "${PROJECT_ROOT}/scripts/commands/install.sh" ]
}

@test "backup.sh: exists and is executable" {
    assert_file_exists "${PROJECT_ROOT}/scripts/commands/backup.sh"
    [ -x "${PROJECT_ROOT}/scripts/commands/backup.sh" ]
}

@test "restore.sh: exists and is executable" {
    assert_file_exists "${PROJECT_ROOT}/scripts/commands/restore.sh"
    [ -x "${PROJECT_ROOT}/scripts/commands/restore.sh" ]
}

@test "copy.sh: exists and is executable" {
    assert_file_exists "${PROJECT_ROOT}/scripts/commands/copy.sh"
    [ -x "${PROJECT_ROOT}/scripts/commands/copy.sh" ]
}

@test "make.sh: exists and is executable" {
    assert_file_exists "${PROJECT_ROOT}/scripts/commands/make.sh"
    [ -x "${PROJECT_ROOT}/scripts/commands/make.sh" ]
}

@test "dev2stg.sh: exists and is executable" {
    assert_file_exists "${PROJECT_ROOT}/scripts/commands/dev2stg.sh"
    [ -x "${PROJECT_ROOT}/scripts/commands/dev2stg.sh" ]
}

@test "delete.sh: exists and is executable" {
    assert_file_exists "${PROJECT_ROOT}/scripts/commands/delete.sh"
    [ -x "${PROJECT_ROOT}/scripts/commands/delete.sh" ]
}

################################################################################
# Bash Syntax Validation Tests
################################################################################

@test "install.sh: has valid bash syntax" {
    run bash -n "${PROJECT_ROOT}/scripts/commands/install.sh"
    [ "$status" -eq 0 ]
}

@test "backup.sh: has valid bash syntax" {
    run bash -n "${PROJECT_ROOT}/scripts/commands/backup.sh"
    [ "$status" -eq 0 ]
}

@test "restore.sh: has valid bash syntax" {
    run bash -n "${PROJECT_ROOT}/scripts/commands/restore.sh"
    [ "$status" -eq 0 ]
}

@test "copy.sh: has valid bash syntax" {
    run bash -n "${PROJECT_ROOT}/scripts/commands/copy.sh"
    [ "$status" -eq 0 ]
}

@test "make.sh: has valid bash syntax" {
    run bash -n "${PROJECT_ROOT}/scripts/commands/make.sh"
    [ "$status" -eq 0 ]
}

@test "dev2stg.sh: has valid bash syntax" {
    run bash -n "${PROJECT_ROOT}/scripts/commands/dev2stg.sh"
    [ "$status" -eq 0 ]
}

@test "delete.sh: has valid bash syntax" {
    run bash -n "${PROJECT_ROOT}/scripts/commands/delete.sh"
    [ "$status" -eq 0 ]
}

################################################################################
# Library Syntax Validation Tests
################################################################################

@test "lib/ui.sh: has valid bash syntax" {
    run bash -n "${PROJECT_ROOT}/lib/ui.sh"
    [ "$status" -eq 0 ]
}

@test "lib/common.sh: has valid bash syntax" {
    run bash -n "${PROJECT_ROOT}/lib/common.sh"
    [ "$status" -eq 0 ]
}

@test "lib/terminal.sh: has valid bash syntax" {
    run bash -n "${PROJECT_ROOT}/lib/terminal.sh"
    [ "$status" -eq 0 ]
}

@test "lib/yaml-write.sh: has valid bash syntax" {
    run bash -n "${PROJECT_ROOT}/lib/yaml-write.sh"
    [ "$status" -eq 0 ]
}

################################################################################
# Help Message Tests
################################################################################

@test "install.sh: provides help message" {
    cd "${PROJECT_ROOT}"
    run ./scripts/commands/install.sh --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage"* ]] || [[ "$output" == *"USAGE"* ]]
}

@test "backup.sh: provides help message" {
    cd "${PROJECT_ROOT}"
    run ./scripts/commands/backup.sh --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage"* ]] || [[ "$output" == *"USAGE"* ]]
}

@test "restore.sh: provides help message" {
    cd "${PROJECT_ROOT}"
    run ./scripts/commands/restore.sh --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage"* ]] || [[ "$output" == *"USAGE"* ]]
}

@test "copy.sh: provides help message" {
    cd "${PROJECT_ROOT}"
    run ./scripts/commands/copy.sh --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage"* ]] || [[ "$output" == *"USAGE"* ]]
}

@test "make.sh: provides help message" {
    cd "${PROJECT_ROOT}"
    run ./scripts/commands/make.sh --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage"* ]] || [[ "$output" == *"USAGE"* ]]
}

@test "dev2stg.sh: provides help message" {
    cd "${PROJECT_ROOT}"
    run ./scripts/commands/dev2stg.sh --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage"* ]] || [[ "$output" == *"USAGE"* ]]
}

@test "delete.sh: provides help message" {
    cd "${PROJECT_ROOT}"
    run ./scripts/commands/delete.sh --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage"* ]] || [[ "$output" == *"USAGE"* ]]
}
