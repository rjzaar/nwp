#!/usr/bin/env bats
#
# `pl mr release --merge`, and the cross-project guard that had to exist first
# (nwp/ops#291).
#
# WHY --merge EXISTS. The operator, twice in one evening: "for 80 it says 'set to
# automerge' not merge. Catch 22" and then "why do I need to release and merge.
# Can't the merge be the release?" The two-step existed because releasing and
# merging were written at different times, not because anything required it. The
# two-person property is that the AUTHOR is not the approver; the approver
# merging is not a weakening of that, it IS the approval.
#
# WHY THE GUARD EXISTS, AND WHY ITS FIRST VERSION WAS USELESS. `pl mr release
# <iid>` resolves its project from the current directory's git remote. Run from
# ~/nwp against what was meant to be nwp/nwc!80, it addressed nwp/nwp!80 — a
# different, long-merged MR. The first guard asked "does !N exist in the resolved
# project?" and BOTH projects have an !80 and an !81, so it passed and posted a
# release note onto the wrong project's MR — reproducing, while under test, the
# exact bug it was written to prevent. (The stray note on nwp/nwp!81 is corrected
# in place rather than deleted; the trail stays append-only.)
#
# The property that actually distinguishes them is SEMANTIC, not positional: a
# release only means anything on an MR that is currently HELD. So the guard tests
# for a hold, and the wrong-project case falls out for free — as do two shapes
# nobody had thought about, a closed MR and an open MR that was never held.
#
# EVERY CASE HERE RUNS WITH YQ EMPTY — and setup() sets it
# AFTER sourcing, because lib/gitlab-mr.sh resolves YQ on load and silently
# overwrote an earlier assignment. The first version of this file set it before,
# so it was NOT yq-less and said it was; a meta case now asserts the condition
# instead of asserting it in a comment. tests/unit/test-mr-json-yqless.bats has
# the same defect and is fixed under ops#293.
#
# That premise is load-bearing: _mr_has_hold_label parsed labels with $YQ, so
# WHERE YQ IS ABSENT it answered "no hold label" for every MR, and a guard keyed
# on it would call every held MR releasable — failing open.
#
# "WHERE YQ IS ABSENT", not "on the CI runner". An earlier version of this file
# and its commit message said the latter, and that is FALSE: lib/gitlab-mr.sh
# resolves yq by absolute candidate path, so job security:mr-hold of pipeline
# 1964 read `files changed: 3` and gave the right verdict without ever
# bootstrapping yq. These are LATENT defects — they bite on a host with no yq at
# any candidate path (a fresh workstation, mons, a new runner), which is worth
# fixing because the library advertises this fallback, but is not a live CI
# failure. Corrected here rather than left standing (ops#293).

bats_require_minimum_version 1.5.0

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export MR_STATUS_FILE="$(mktemp)"
    # shellcheck source=/dev/null
    source "$REPO_ROOT/lib/ui.sh" 2>/dev/null || true
    # shellcheck source=/dev/null
    source "$REPO_ROOT/lib/gitlab-mr.sh"
    # AFTER the source, and that ordering is the whole point. lib/gitlab-mr.sh
    # resolves YQ itself on load, so a `YQ=""` set BEFORE sourcing is silently
    # overwritten with the real binary — which is what the first version of this
    # file did, and what tests/unit/test-mr-json-yqless.bats has been doing since
    # ops#281 despite a docblock insisting otherwise. Measured: YQ inside a test
    # came back /home/rob/.local/bin/yq. Those suites were never yq-less, which is
    # precisely the blindness they were written to remove (ops#293).
    YQ=""
    # A resolvable project, so 'unresolved' never masks a real verdict.
    _mr_project(){ printf 'nwp%%2Fnwc'; }
}

@test "RED-PROOF: booleans come back in JSON spelling, not Python's" {
    # The bug this ordering fix exposed, and the reason it matters. python printed
    # True where yq prints true, so `[ "$draft" = "true" ]` was FALSE on the CI
    # runner for every MR — _mr_assert_releasable called a Draft MR 'not-held',
    # which is the guard failing open in exactly the environment it must not.
    run _mr_jget 'draft' <<<'{"draft":true}'
    [ "$output" = "true" ]
    run _mr_jget 'x' <<<'{"x":false}'
    [ "$output" = "false" ]
    # and a missing key stays empty rather than becoming the string "None"
    run _mr_jget 'nope' <<<'{"x":1}'
    [ -z "$output" ]
}

@test "RED-PROOF: _mr_is_draft works without yq — it CONFIRMS the D13 hold" {
    # It read .draft with a raw "$YQ", so on the runner it answered 'not draft'
    # for every MR, including ones whose hold had just been applied. That is the
    # difference between printing HELD and printing HOLD-MECHANISM-FAILED.
    run _mr_is_draft '{"draft":true}'
    [ "$status" -eq 0 ]
    run _mr_is_draft '{"draft":false}'
    [ "$status" -ne 0 ]
    run _mr_is_draft '{"work_in_progress":true}'
    [ "$status" -eq 0 ]
    run _mr_is_draft '{}'
    [ "$status" -ne 0 ]
}

@test "meta: YQ really IS empty in here — the claim this file rests on" {
    # Without this the yq-less premise is a comment, not a condition. It was a
    # comment for the first version of this file, and still is for ops#281's.
    [ -z "$YQ" ] || { echo "YQ=[$YQ] — this suite is NOT running yq-less"; false; }
    run _mr_have_yq
    [ "$status" -ne 0 ]
}
teardown() { rm -f "$MR_STATUS_FILE"; }

# Stub the one call that touches the network. Every case below differs ONLY in
# the MR json, which is exactly the axis the guard is supposed to discriminate on.
#
# NOT `local json="$1"` with a nested `_mr_fetch(){ printf '%s' "$json"; }`. A
# function body is parsed at definition time but EXPANDED at call time, so by the
# time _mr_fetch ran the local was long out of scope and every stub returned an
# EMPTY payload — all six shape cases silently exercised the empty-json path
# instead of the shapes they name. They failed, and this bats build prints no
# `not ok` for a failing test: it drops the line entirely and reports only
# "Executed 15 instead of expected 22" (ops#283). Seven tests disappeared rather
# than complained. A global assigned before the redefinition is what actually
# closes over the value.
_stub_mr() { MR_STUB_JSON="$1"; _mr_fetch(){ printf '%s' "$MR_STUB_JSON"; }; }

@test "meta: the stub really does deliver the payload it was given" {
    # Guards the harness itself. Without this, a stub silently returning empty
    # makes every case above test the same fail-closed path while reading as
    # broad coverage — which is exactly what happened.
    _stub_mr '{"iid":80,"title":"unmistakable-probe-title"}'
    run _mr_fetch 80
    [ "$output" = '{"iid":80,"title":"unmistakable-probe-title"}' ]
    run _mr_title "$(_mr_fetch 80)"
    [ "$output" = "unmistakable-probe-title" ]
}

j_draft='{"iid":80,"title":"Draft: something","state":"opened","draft":true,"labels":[]}'
j_hold='{"iid":80,"title":"something","state":"opened","draft":false,"labels":["hold::sensitive-path"]}'
j_manual='{"iid":80,"title":"something","state":"opened","draft":false,"labels":["hold::manual","other"]}'
j_plain='{"iid":80,"title":"something","state":"opened","draft":false,"labels":["ops"]}'
j_merged='{"iid":80,"title":"something","state":"merged","draft":false,"labels":[]}'
j_closed='{"iid":80,"title":"something","state":"closed","draft":false,"labels":["hold::manual"]}'

@test "a Draft MR is held — layer 1 of the D13 hold" {
    _stub_mr "$j_draft"
    run _mr_assert_releasable 80
    [ "$status" -eq 0 ]
    [ "$output" = "held" ]
}

@test "a hold::sensitive-path MR is held" {
    _stub_mr "$j_hold"
    run _mr_assert_releasable 80
    [ "$status" -eq 0 ]
    [ "$output" = "held" ]
}

@test "a hold::manual MR is held, even among other labels" {
    _stub_mr "$j_manual"
    run _mr_assert_releasable 80
    [ "$status" -eq 0 ]
    [ "$output" = "held" ]
}

@test "RED-PROOF: a MERGED MR is refused — this is the nwp/nwp!80 incident" {
    # The whole reason the guard exists. Before it, this posted a release note by
    # @nobody onto a long-merged MR in the wrong project and reported success.
    _stub_mr "$j_merged"
    run _mr_assert_releasable 80
    [ "$status" -ne 0 ]
    [ "$output" = "merged" ]
}

@test "RED-PROOF: an open MR that was never held is refused" {
    # Not the reported bug — found by asking what 'held' actually means. A release
    # lifts a hold; on an MR with no hold it writes an approval record that
    # authorised nothing, which is worse than an error because it is filed.
    _stub_mr "$j_plain"
    run _mr_assert_releasable 80
    [ "$status" -ne 0 ]
    [ "$output" = "not-held" ]
}

@test "a CLOSED MR is refused even though it carries a hold label" {
    # State is checked before labels, so a stale hold on a closed MR cannot make
    # it look releasable.
    _stub_mr "$j_closed"
    run _mr_assert_releasable 80
    [ "$status" -ne 0 ]
    [ "$output" = "closed" ]
}

@test "an MR that cannot be fetched is 'missing', never assumed releasable" {
    _mr_fetch(){ return 1; }
    run _mr_assert_releasable 80
    [ "$status" -ne 0 ]
    [ "$output" = "missing" ]
}

@test "an empty-but-successful fetch is also 'missing' (fail closed)" {
    # GitLab answers 404 with a json body and curl still exits 0, so a title-less
    # payload must not read as a valid MR.
    _stub_mr '{"message":"404 Not found"}'
    run _mr_assert_releasable 80
    [ "$status" -ne 0 ]
    [ "$output" = "missing" ]
}

@test "an unresolvable project is refused before any write" {
    _mr_project(){ return 1; }
    run _mr_assert_releasable 80
    [ "$status" -ne 0 ]
    [ "$output" = "unresolved" ]
}

@test "RED-PROOF: _mr_has_hold_label reads labels with NO yq on PATH" {
    # It used to do this with "$YQ", which is empty on the runner: the parse
    # produced nothing and every MR answered 'not held'. A guard built on that
    # would have declared every held MR releasable — the ops#281 class again,
    # inside the helper the new guard depends on.
    run _mr_has_hold_label "$j_hold"
    [ "$status" -eq 0 ]
    run _mr_has_hold_label "$j_manual"
    [ "$status" -eq 0 ]
    run _mr_has_hold_label "$j_plain"
    [ "$status" -ne 0 ]
}

@test "the label reader survives garbage instead of treating it as 'no hold'" {
    # Distinguishing "parsed, no hold" from "could not parse" is the point; the
    # guard's Draft check is what keeps a mangled payload from reading releasable.
    run _mr_has_hold_label 'not json at all'
    [ "$status" -ne 0 ]
    run _mr_has_hold_label ''
    [ "$status" -ne 0 ]
}

@test "no second label parser exists — one reader, or they drift" {
    # An earlier draft of this change added _mr_label_csv beside the existing
    # helper. Two readers of the same field is how one gets fixed and the other
    # keeps the bug.
    local dupes
    dupes="$(grep -n '_mr_label_csv' "$REPO_ROOT/lib/gitlab-mr.sh" \
               "$REPO_ROOT/scripts/commands/mr.sh" 2>/dev/null || true)"
    [ -z "$dupes" ] || { echo "duplicate label parser: $dupes"; false; }
}

@test "_mr_pipeline_status reports 'unknown' when it cannot look" {
    # "I could not look" is not "it is green". --merge keys off this.
    _mr_fetch(){ return 1; }
    run _mr_pipeline_status 80
    [ "$output" = "unknown" ]
}

@test "_mr_pipeline_status reports 'none' for an MR with no pipeline" {
    _stub_mr "$j_plain"
    run _mr_pipeline_status 80
    [ "$output" = "none" ]
}

@test "_mr_pipeline_status reads a real status without yq" {
    _stub_mr '{"iid":80,"title":"t","state":"opened","head_pipeline":{"status":"success"}}'
    run _mr_pipeline_status 80
    [ "$output" = "success" ]
}

@test "_mr_project_human renders the project, and says so when it cannot" {
    run _mr_project_human
    [ "$output" = "nwp/nwc" ]
    _mr_project(){ return 1; }
    run _mr_project_human
    [ "$output" = "(project unresolved)" ]
}

# --- --merge: the refusals, which are the only part worth testing here ---------
# Merging for real needs a live held MR with a green pipeline; what CI can pin is
# that every NON-green verdict refuses. That is the direction a mistake is
# expensive in.

@test "RED-PROOF: --merge does NOT merge on a failed pipeline" {
    grep -q 'pipeline is \$st — NOT merging' "$REPO_ROOT/scripts/commands/mr.sh"
    # and it must say the release itself survived, or the operator re-releases
    grep -q 'The release is recorded; fix the pipeline' "$REPO_ROOT/scripts/commands/mr.sh"
}

@test "RED-PROOF: --merge does NOT merge on a timeout — patience is not green" {
    # The loop's exit condition is time, so falling out of it says nothing about
    # the pipeline. Anything other than an explicit success must refuse.
    grep -q 'NOT merging' "$REPO_ROOT/scripts/commands/mr.sh"
    grep -qE 'if \[ "\$st" != "success" \]' "$REPO_ROOT/scripts/commands/mr.sh"
}

@test "--merge waits for the gate job it just re-ran, rather than racing it" {
    # The release re-runs the gate job. Merging immediately would race a pipeline
    # deliberately re-checking the release just recorded.
    grep -q 'waiting for the pipeline to re-evaluate the release before merging' \
        "$REPO_ROOT/scripts/commands/mr.sh"
    grep -q 'NWP_MR_MERGE_TIMEOUT' "$REPO_ROOT/scripts/commands/mr.sh"
}

@test "--merge routes through cmd_merge, not a hand-rolled PUT" {
    # cmd_merge holds the stale-detailed_merge_status knowledge and the
    # one-rebase-per-run rule. A second merge path would not have either.
    grep -qE '^\s*cmd_merge "\$iid"' "$REPO_ROOT/scripts/commands/mr.sh"
    # exactly one place performs a merge PUT
    local puts
    puts="$(grep -cE "merge_requests/\\\$iid/merge" "$REPO_ROOT/scripts/commands/mr.sh" || true)"
    [ "$puts" -le 1 ] || { echo "more than one merge PUT: $puts"; false; }
}

@test "the release path calls the guard before it writes anything" {
    # Order is the property: a guard consulted after the POST is decoration.
    local guard_line note_line
    guard_line=$(grep -n '_mr_assert_releasable' "$REPO_ROOT/scripts/commands/mr.sh" | head -1 | cut -d: -f1)
    note_line=$(grep -n 'Release-Approved-By\|/notes' "$REPO_ROOT/scripts/commands/mr.sh" | head -1 | cut -d: -f1)
    [ -n "$guard_line" ] && [ -n "$note_line" ]
    [ "$guard_line" -lt "$note_line" ] \
        || { echo "guard at $guard_line runs AFTER the write at $note_line"; false; }
}

@test "the old existence-only guard is gone" {
    # It is the one that failed live. Leaving it callable invites its reuse.
    ! grep -q '_mr_assert_project' "$REPO_ROOT/scripts/commands/mr.sh"
    ! grep -q '^_mr_assert_project' "$REPO_ROOT/lib/gitlab-mr.sh"
}
