#!/usr/bin/env bats
# install.sh target-name validation (ops#165 / security_validation:17).
#
# Found by the verification gate itself: install.sh never called
# validate_sitename, so on 2026-08-01
#     pl install d 'test|cat /etc/passwd'
# was ACCEPTED — it created sites/'test|cat '/etc/passwd/, registered a site
# named "passwd" in nwp.yml, and hung in composer until killed. The check
# "Reject pipe character (|)" had been red on main and nobody looked, which is
# the whole ops#165 disease: the one real finding was buried in 140 fake ones.
#
# These cases run install.sh directly with NO nwp.yml present: rejection must
# happen before any config is read, so a hostile name can't even get as far as
# an error about configuration.

setup() {
    REAL_ROOT="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
    INSTALL="${REAL_ROOT}/scripts/commands/install.sh"
    WORK="${BATS_TEST_TMPDIR}/emptycwd"
    mkdir -p "$WORK"
    cd "$WORK"   # no nwp.yml here — validation must not need one
}

_expect_rejected() {
    run timeout 10 bash "$INSTALL" d "$1"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid"*"target site name"* || "$output" == *"not allowed"*"target site name"* ]]
    # And nothing was created on disk for the hostile name.
    [ -z "$(find . -mindepth 1 -maxdepth 1 2>/dev/null)" ]
}

@test "reject pipe character in target name (the 2026-08-01 escape)" {
    _expect_rejected 'test|cat /etc/passwd'
}

@test "reject slash / path-shaped target name" {
    _expect_rejected 'nested/dir'
}

@test "reject space in target name" {
    _expect_rejected 'test site'
}

@test "reject command substitution in target name" {
    _expect_rejected 'test$(whoami)'
}

@test "reject semicolon in target name" {
    _expect_rejected 'test;rm'
}

@test "reject path traversal in target name" {
    _expect_rejected '../escape'
}

@test "a clean target name passes validation (fails later, on config, not on the name)" {
    run timeout 10 bash "$INSTALL" d 'good-name.1'
    [ "$status" -eq 1 ]
    [[ "$output" == *"nwp.yml"* ]]          # reached the config check
    [[ "$output" != *"target site name"* ]] # without tripping validation
}
