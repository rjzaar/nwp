#!/usr/bin/env bats
# install-box.sh --stage-codes must PROVE what it staged.
#
# THE DEFECT UNDER TEST (found 2026-08-11 staging a real reissue). The block
# ended in a remote `jq -e '.codes|length'`, whose number nobody compared to
# anything, and whose exit status cannot fail on the case that matters:
#
#     $ echo '{"codes":[]}' | jq -e '.codes|length'
#     0
#     exit 0
#
# `jq -e` fails only on null/false, and 0 is neither. So staging an EMPTY or
# TRUNCATED payload printed a bare number and reported success — and the
# staged payload is exactly what the 01:00 reset restores, so a silent zero
# would wipe every live invite code with nothing anywhere saying so. A count
# that is printed but never compared is the estate's swallowed-verdict shape:
# a measurement taken and then thrown away.

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    INSTALLER="${REPO_ROOT}/servers/live/demo/install-box.sh"
    TMP="$BATS_TEST_TMPDIR"
}

@test "the staged count is COMPARED to the local count, not merely printed" {
    # the script must contain a real comparison of remote vs local, not a bare
    # `jq -e … length` whose output goes nowhere
    run bash -c "sed -n '/Staging hashed invite-code payload/,/^else/p' '$INSTALLER' | grep -Eq 'staged_n|remote_n|-ne|!='"
    [ "$status" -eq 0 ]
}

@test "an EMPTY staged payload is a hard failure, never a silent success" {
    # scoped to the staging block ONLY and to a marker that block must carry —
    # the first draft of this case matched an unrelated 'exit 1' from the
    # authorized_keys guard 13 lines away and passed without testing anything.
    run bash -c "sed -n '/Staging hashed invite-code payload/,/^else/p' '$INSTALLER' | grep -Eq 'staged (0|zero)|refus|would wipe|MISMATCH'"
    [ "$status" -eq 0 ]
}

@test "the count is LABELLED — a bare number tells the operator nothing" {
    run bash -c "sed -n '/Staging hashed invite-code payload/,/^else/p' '$INSTALLER' | grep -Eq 'code\\(s\\) staged'"
    [ "$status" -eq 0 ]
}

@test "jq -e alone cannot be the verdict (0 is truthy — pinned so nobody restores it)" {
    run bash -c "echo '{\"codes\":[]}' | jq -e '.codes|length'"
    [ "$status" -eq 0 ]   # documents WHY the comparison is needed
    [ "$output" = "0" ]
}

@test "the installer is syntactically valid" {
    run bash -n "$INSTALLER"
    [ "$status" -eq 0 ]
}
