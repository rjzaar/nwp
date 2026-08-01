#!/usr/bin/env bats
# install.sh target-name validation.
#
# THE BUG. install.sh never called validate_sitename. The target name flows
# into directory creation, the DDEV project name and an nwp.yml site key, all
# of which assume a plain identifier. Proven on 2026-08-01 (ops#165):
#
#     pl install d 'test|cat /etc/passwd'
#
# was ACCEPTED. It created `sites/'test|cat '/etc/passwd/` — two nested
# directories out of one argument, because the unquoted name was word-split on
# the path separator — and registered a site named `passwd` in nwp.yml, before
# hanging in composer. (Found by NWP's own verification gate, whose "Reject
# pipe character" check had been red for months inside a permanently-red job.)
#
# The cases below are in two halves, and BOTH halves matter:
#   * REJECTED — hostile shapes, each asserted to fail with NOTHING created;
#   * ACCEPTED — every naming shape the live estate actually uses. A validator
#     that also rejects `avc-stg` or `ss2_moodledata` would be a worse bug
#     than the one it fixes, so the allowed set is pinned explicitly.
#
# install.sh runs here from a directory with NO nwp.yml, so rejection is proven
# to happen before any config is read: a hostile name cannot even reach the
# "Configuration file not found" stage.

setup() {
    REAL_ROOT="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
    INSTALL="${REAL_ROOT}/scripts/commands/install.sh"
    WORK="${BATS_TEST_TMPDIR}/emptycwd"
    mkdir -p "$WORK"
    cd "$WORK"   # no nwp.yml here — validation must not need one
}

# A rejected name: exit 1, a message naming the target, and NOTHING on disk.
_expect_rejected() {
    run timeout 10 bash "$INSTALL" d "$1"
    [ "$status" -eq 1 ]
    [[ "$output" == *"target site name"* ]]
    [[ "$output" != *"nwp.yml"* ]]   # refused before the config check
    [ -z "$(find . -mindepth 1 2>/dev/null)" ]
}

# An accepted name: passes validation, then fails later for the honest reason
# (no nwp.yml in this scratch cwd). Proves the gate let it through.
_expect_accepted() {
    run timeout 10 bash "$INSTALL" d "$1"
    [ "$status" -eq 1 ]
    [[ "$output" == *"nwp.yml"* ]]
    [[ "$output" != *"target site name"* ]]
}

################################################################################
# REJECTED — the shapes that were getting through
################################################################################

@test "REJECT: pipe + path, the exact payload accepted on 2026-08-01" {
    _expect_rejected 'test|cat /etc/passwd'
}

@test "REJECT: backtick command substitution" {
    _expect_rejected 'test`whoami`'
}

@test "REJECT: \$() command substitution" {
    _expect_rejected 'test$(whoami)'
}

@test "REJECT: semicolon command separator" {
    _expect_rejected 'test;rm'
}

@test "REJECT: ampersand" {
    _expect_rejected 'test&whoami'
}

@test "REJECT: space in the name" {
    _expect_rejected 'test site'
}

@test "REJECT: slash / path-shaped name" {
    _expect_rejected 'nested/dir'
}

@test "REJECT: absolute path" {
    _expect_rejected '/tmp/malicious'
}

@test "REJECT: path traversal" {
    _expect_rejected '../escape'
}

@test "REJECT: redirection metacharacter" {
    _expect_rejected 'test>out'
}

################################################################################
# ACCEPTED — every shape the live estate uses (do not over-restrict)
################################################################################

@test "ACCEPT: plain site names in the estate (ss, avc, dir1, ss2, nwc)" {
    for n in ss avc dir1 ss2 nwc rgs sso ba mt fin; do
        _expect_accepted "$n"
    done
}

@test "ACCEPT: hyphenated env twins and fixtures (avc-stg, verify-test)" {
    for n in avc-stg ss2-dev verify-test avc-dev nwc-dev ssd-dev; do
        _expect_accepted "$n"
    done
}

@test "ACCEPT: underscored companion trees (ss_moodledata, ssc1_moodledata)" {
    for n in ss_moodledata ssd_moodledata ssc1_moodledata; do
        _expect_accepted "$n"
    done
}

@test "ACCEPT: a timestamped import name with digits and repeated hyphens" {
    _expect_accepted '20260117T212337-no-git-no-git'
}

@test "ACCEPT: a dotted name (the validator's documented '.' allowance)" {
    _expect_accepted 'site.example'
}

@test "ACCEPT: every recipe id shipped in example.nwp.yml is a valid name" {
    # Recipe ids double as default target names (`pl install pod` → site 'pod'),
    # so a validator that rejected one would break plain installs.
    command -v yq >/dev/null || skip "needs yq"
    local ids
    ids="$(yq e '.recipes | keys | .[]' "${REAL_ROOT}/example.nwp.yml")"
    [ -n "$ids" ]
    local n
    for n in $ids; do
        run timeout 10 bash "$INSTALL" "$n" "$n"
        [[ "$output" != *"target site name"* ]]
    done
}

################################################################################
# The predicate itself — asserted directly, independent of install.sh's flow
################################################################################

@test "validate_sitename is the shared predicate and behaves as documented" {
    source "${REAL_ROOT}/lib/ui.sh"
    source "${REAL_ROOT}/lib/common.sh"
    # rejected
    ! validate_sitename 'test|cat /etc/passwd' >/dev/null 2>&1
    ! validate_sitename '' >/dev/null 2>&1
    ! validate_sitename '/abs' >/dev/null 2>&1
    ! validate_sitename '../up' >/dev/null 2>&1
    # accepted
    validate_sitename 'avc-stg' >/dev/null 2>&1
    validate_sitename 'ss_moodledata' >/dev/null 2>&1
    validate_sitename 'site.example' >/dev/null 2>&1
}

@test "install.sh calls the validator (the fix cannot be silently dropped)" {
    grep -q 'validate_sitename "\$target"' "$INSTALL"
}
