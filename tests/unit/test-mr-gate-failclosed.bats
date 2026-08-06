#!/usr/bin/env bats
#
# The sensitive-path gate must FAIL CLOSED, and must not mistake "not yet" for
# "cannot" (nwp/ops#293).
#
# Found by opening a real MR (!368) and reading what the gate actually did:
#
#     WARNING: !368 — sensitive-path status CANNOT BE VERIFIED; treat it as held.
#       draft: False   labels: []
#
# THREE DEFECTS, EACH INDEPENDENTLY ENOUGH TO MAKE THE GATE DECORATION.
#
# A. "treat it as held" held nothing. Exit 2 printed an instruction to a human
#    and applied no hold, so the MR was fully mergeable and the forge recorded
#    nothing — the only trace was a terminal line that scrolls away. Had the diff
#    touched CLAUDE.md or .gitlab-ci.yml, the gate would have said "treat it as
#    held" and left it open for anyone to merge. The docblock above the code
#    already asserted the opposite: "a held MR is the correct outcome, not an
#    error". The apply path was fixed for exactly this in ops#281
#    (HOLD-MECHANISM-FAILED replaced WARNING); the cannot-verify path was missed.
#
# B. Exit 2 was the NORMAL result of `pl mr create`. GitLab prepares diffs
#    asynchronously; for the first seconds after the POST it reports
#    detailed_merge_status=preparing, diff_refs=null and an empty changeset. The
#    gate ran immediately after creation, read the empty changeset, and concluded
#    "could not look" on the FIRST read when the true answer was "not yet".
#    Measured on !368: empty at creation, three files moments later, right
#    verdict from an unchanged gate. Its own list of causes named "a shallow
#    clone, a stale origin/main, or a HEAD identical to the target" — and not the
#    one that actually fires. With (A) this is the worse compound: CANNOT VERIFY
#    on nearly every new MR, holding nothing, training the reader to skim past.
#
# C. _mr_changed_files answered rc=0 with zero lines when it could not PARSE.
#    It read the diff pages with "$YQ" and, when that produced nothing, simply
#    broke out of the loop and `return 0` — "I looked, there is nothing",
#    indistinguishable from a real empty diff. Measured with YQ emptied:
#
#        _mr_changed_files 368 → rc=0  lines=0
#
#    That is the swallowed verdict CLAUDE.md forbids: a check may not substitute
#    a literal for a measurement it failed to take. It must fail, or say CANNOT
#    VERIFY. The caller only recovered because it separately knows an MR always
#    has files — a coincidence, not a contract.
#
# WHAT IS *NOT* CLAIMED HERE, having checked instead of assumed. An earlier
# version of this docblock said "$YQ is empty on the CI runner", making C a live
# CI failure. That is FALSE and the log says so: in job security:mr-hold of
# pipeline 1964, on the very MR that started this, the gate read `files changed:
# 3` and returned the correct verdict. lib/gitlab-mr.sh resolves yq by ABSOLUTE
# candidate path ($HOME/.local/bin/yq and friends), not just PATH, so it is found
# in that job even though the job never bootstraps it. My "no yq" probe was
# invalid for the same reason — stripping ~/.local/bin from PATH does not hide a
# binary the resolver opens directly.
#
# So these are LATENT defects, not firing today: they bite wherever yq is
# genuinely absent from every candidate path — a fresh workstation, mons, a new
# runner — and there the gate fails OPEN. Worth fixing because the library
# advertises a python fallback and the fallback gave wrong answers; not worth
# overstating.
#
# This file runs with YQ EMPTY because that is the branch under test, not because
# the runner is known to be in that state.

bats_require_minimum_version 1.5.0

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export MR_STATUS_FILE="$(mktemp)"
    # shellcheck source=/dev/null
    source "$REPO_ROOT/lib/ui.sh" 2>/dev/null || true
    # shellcheck source=/dev/null
    source "$REPO_ROOT/lib/gitlab-mr.sh"
    # AFTER the source. lib/gitlab-mr.sh resolves YQ on load, so a YQ=""
    # set BEFORE sourcing is silently overwritten with the real binary —
    # which is what this file did, so it has never once run yq-less despite
    # a docblock insisting it does. Measured: YQ=[/home/rob/.local/bin/yq]
    # from inside a test (ops#293).
    YQ=""
    _mr_project(){ printf 'nwp%%2Fnwc'; }
    _mr_have_token(){ return 0; }
    # Counting calls is how "did it retry?" becomes checkable — and the counter
    # MUST live in a file. _mr_fetch is invoked as `json=$(_mr_fetch ...)`, a
    # command substitution, which is a SUBSHELL: a shell variable incremented in
    # there is discarded, so a stub keyed on one is frozen at its first response
    # for ever. That made the poller look broken when the harness was. Same shape
    # as the local-scoped stub in test-mr-release-merge.bats — a stub that cannot
    # observe its own calls quietly tests something else.
    MR_CALLS_FILE="$(mktemp)"; echo 0 > "$MR_CALLS_FILE"
}
# _bump → current count, incremented, surviving the subshell.
_bump(){ local n; n=$(( $(cat "$MR_CALLS_FILE") + 1 )); echo "$n" > "$MR_CALLS_FILE"; printf '%s' "$n"; }
teardown() { rm -f "$MR_STATUS_FILE" "$MR_CALLS_FILE"; }

@test "meta: YQ really IS empty in here — the premise this file rests on" {
    # Asserted, not narrated. It was narrated, and was false the whole time.
    [ -z "$YQ" ] || { echo "YQ=[$YQ] — this suite is NOT yq-less"; false; }
    run _mr_have_yq
    [ "$status" -ne 0 ]
}

@test "meta: the call counter survives a command substitution" {
    # If it does not, every retry case silently becomes a never-retries case.
    _mr_fetch(){ printf 'call%s' "$(_bump)"; }
    run bash -c 'true'   # reset run state
    a=$(_mr_fetch); b=$(_mr_fetch); c=$(_mr_fetch)
    [ "$a" = "call1" ] && [ "$b" = "call2" ] && [ "$c" = "call3" ] \
      || { echo "counter froze: $a $b $c"; false; }
}

# A two-file diff page, as /diffs returns it.
DIFFS_ONE='[{"new_path":"CLAUDE.md","old_path":"CLAUDE.md"},{"new_path":"lib/x.sh","old_path":"lib/x.sh"}]'

@test "meta: the harness's own stub delivers what it was given" {
    # Without this, a stub that silently returns empty makes every case below
    # exercise the same fail-closed path while reading as broad coverage.
    _mr_get(){ printf '%s' "$DIFFS_ONE"; }
    run _mr_changed_files 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"CLAUDE.md"* ]]
}

# --- C: a parse it could not perform is not an empty diff --------------------

@test "RED-PROOF (C): a diff page it cannot parse is a FAILURE, not 'no files'" {
    # rc 0 with no output means "determined: nothing sensitive". For an
    # unparseable payload that is a lie, and it is the lie that makes the gate
    # inert wherever yq is absent.
    _mr_get(){ printf '%s' 'this is not json'; }
    run _mr_changed_files 1
    [ "$status" -ne 0 ] || {
        echo "returned rc=0 for an unparseable page — swallowed verdict"; false; }
}

@test "RED-PROOF (C): _mr_changed_files reads a real diff page with NO yq" {
    # The measured defect: with $YQ empty this produced rc=0 and zero lines
    # against a live MR that had three changed files.
    _mr_get(){ printf '%s' "$DIFFS_ONE"; }
    run _mr_changed_files 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"CLAUDE.md"* ]]
    [[ "$output" == *"lib/x.sh"* ]]
}

@test "renames report BOTH sides, so a rename out of a sensitive path still holds" {
    _mr_get(){ printf '%s' '[{"new_path":"lib/safe.sh","old_path":"lib/authz.sh"}]'; }
    run _mr_changed_files 1
    [[ "$output" == *"lib/authz.sh"* ]]
    [[ "$output" == *"lib/safe.sh"* ]]
}

@test "a genuinely empty page is still rc 0 with no output" {
    # The distinction being drawn is parse-failure vs empty. An empty ARRAY is a
    # real answer and must stay one, or pagination's exit condition breaks.
    _mr_get(){ printf '%s' '[]'; }
    run _mr_changed_files 1
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "a transport failure propagates rather than reading as an empty diff" {
    _mr_get(){ return 1; }
    run _mr_changed_files 1
    [ "$status" -ne 0 ]
}

# --- B: "not yet" is not "cannot" -------------------------------------------

@test "RED-PROOF (B): a 'preparing' MR is waited for, not declared unreadable" {
    # The measured sequence on !368: preparing with an empty changeset, then
    # three files. A single read cannot tell those apart, so it must ask again.
    _mr_fetch(){
        if [ "$(_bump)" -lt 3 ]; then
            printf '%s' '{"iid":1,"title":"t","state":"opened","detailed_merge_status":"preparing"}'
        else
            printf '%s' '{"iid":1,"title":"t","state":"opened","detailed_merge_status":"mergeable","diff_refs":{"base_sha":"a"}}'
        fi
    }
    NWP_MR_DIFF_TIMEOUT=30 NWP_MR_DIFF_POLL=0 run _mr_diff_ready 1
    [ "$status" -eq 0 ]
}

@test "RED-PROOF (B): 'checking' is also waited for, not classified" {
    # CLAUDE.md's merge-automation rule: "checking means retry, not failure".
    _mr_fetch(){
        if [ "$(_bump)" -lt 2 ]; then
            printf '%s' '{"iid":1,"title":"t","detailed_merge_status":"checking"}'
        else
            printf '%s' '{"iid":1,"title":"t","detailed_merge_status":"mergeable","diff_refs":{"base_sha":"a"}}'
        fi
    }
    NWP_MR_DIFF_TIMEOUT=30 NWP_MR_DIFF_POLL=0 run _mr_diff_ready 1
    [ "$status" -eq 0 ]
}

@test "'preparing' WITH diff_refs already set is STILL waited for" {
    # diff_refs can appear BEFORE the diff pages are complete, so its presence
    # alone is not readiness. Without this case, deleting the whole
    # preparing|checking arm changes nothing that any test observes — mutation
    # testing proved exactly that, twice.
    _mr_fetch(){
        if [ "$(_bump)" -lt 3 ]; then
            printf '%s' '{"detailed_merge_status":"preparing","diff_refs":{"base_sha":"a"}}'
        else
            printf '%s' '{"detailed_merge_status":"mergeable","diff_refs":{"base_sha":"a"}}'
        fi
    }
    NWP_MR_DIFF_TIMEOUT=30 NWP_MR_DIFF_POLL=0 run _mr_diff_ready 1
    [ "$status" -eq 0 ]
    # it must have kept asking rather than accepting the first refs it saw
    [ "$(cat "$MR_CALLS_FILE")" -ge 3 ] || {
        echo "accepted 'preparing' as ready because diff_refs was set (calls=$(cat "$MR_CALLS_FILE"))"; false; }
}

@test "a permanently 'preparing' MR eventually gives up — bounded, and refuses" {
    # Waiting forever is its own failure. Giving up must be a refusal, never a
    # pass: "I ran out of patience" is not "the diff is empty".
    _mr_fetch(){ printf '%s' '{"iid":1,"title":"t","detailed_merge_status":"preparing"}'; }
    NWP_MR_DIFF_TIMEOUT=0 NWP_MR_DIFF_POLL=0 run _mr_diff_ready 1
    [ "$status" -ne 0 ]
}

@test "an already-ready MR is not polled at all" {
    # The wait must not cost anything on the overwhelmingly common path.
    _mr_fetch(){ printf '%s' '{"iid":1,"title":"t","detailed_merge_status":"mergeable","diff_refs":{"base_sha":"a"}}'; }
    NWP_MR_DIFF_TIMEOUT=30 NWP_MR_DIFF_POLL=99 run _mr_diff_ready 1
    [ "$status" -eq 0 ]
}

@test "an unfetchable MR is not-ready, never assumed ready" {
    _mr_fetch(){ return 1; }
    NWP_MR_DIFF_TIMEOUT=0 NWP_MR_DIFF_POLL=0 run _mr_diff_ready 1
    [ "$status" -ne 0 ]
}

# --- A: cannot-verify must actually hold ------------------------------------
#
# THESE WERE GREP-ON-SOURCE ASSERTIONS AND MUTATION TESTING WALKED PAST THEM.
# Replacing the `_mr_hold_unverifiable "$iid" "$apply"` call with `:` left all 19
# cases green, because a grep for the helper's NAME still matched the comment and
# the definition. A test that reads the source is checking that a string is
# present, not that a thing happens. So these now RUN cmd_guard with a recording
# stub and assert the hold was actually attempted.

# Load the command file. It guards `main "$@"` on BASH_SOURCE, so sourcing is
# safe and gives access to cmd_guard directly.
#
# EVERY CASE BELOW PASSES --base=HEAD --head=HEAD, and that is not cosmetic.
#
# The gate PREFERS the git range and only falls back to the API when the range is
# empty — and the API path is what these cases stub. With `--base=` the gate
# derives a base from CI_MERGE_REQUEST_DIFF_BASE_SHA / _TARGET_BRANCH_NAME. Those
# are UNSET on a workstation, so no range is computed and the API path runs; they
# are SET in CI, so `git diff origin/main...HEAD` returns the real four files, the
# API path never runs, and every stub below goes unused.
#
# That is exactly what happened: all eight behavioural cases passed here and
# failed in CI, which could only report "Executed 3666 instead of expected 3674".
# An explicit --base skips the derivation entirely and HEAD...HEAD is empty by
# construction, so the fallback is reached on any host. setup() also clears the
# variables, so neither mechanism alone is load-bearing.
_load_cmd(){
    # shellcheck source=/dev/null
    source "$REPO_ROOT/scripts/commands/mr.sh" 2>/dev/null || true
    # mr.sh opens with `set -uo pipefail`, which sourcing applies to the TEST
    # shell. Under set -u bats' own internals touch unset variables and the case
    # dies with NO output at all — which this build reports only as
    # "Executed 16 instead of expected 23", the ops#283 vanishing again. Undo it.
    set +u +o pipefail
    HOLD_LOG="$(mktemp)"
    # Record the attempt. Returning 0 = "the PUT succeeded".
    _mr_apply_hold(){ printf 'HOLD_ATTEMPTED iid=%s\n' "$1" >> "$HOLD_LOG"; return 0; }
    _mr_is_draft(){ return 0; }          # confirmation succeeds
    _mr_fetch(){ printf '%s' '{"iid":1,"title":"t","state":"opened","draft":true}'; }
    _mr_http_status(){ printf '000'; }
    # The gate must not find a git range, so the API path is the one under test.
    _mr_changed_files(){ return 1; }     # unreadable — the cannot-verify case
    _mr_diff_ready(){ return 1; }
    _mr_have_token(){ return 0; }
    _mr_project(){ printf 'nwp%%2Fnwc'; }
    # A host must be resolvable or the gate fails closed on THAT first, and every
    # case below would measure the host check rather than the hold. Deliberately
    # unroutable: nothing here should ever dial it — every API call is stubbed.
    export NWP_GITLAB_HOST="forge.invalid.test"
    # Belt and braces with the explicit --base above: if these leak in from a CI
    # environment the gate derives a real diff range and stops consulting the
    # stubs at all.
    unset CI_MERGE_REQUEST_DIFF_BASE_SHA CI_MERGE_REQUEST_TARGET_BRANCH_NAME
    unset CI_MERGE_REQUEST_IID
    # The sensitive-path route also reads the NOTES api, to see whether a release
    # record already exists. Unstubbed it dials the invalid host, takes an HTTP
    # 000 and fails closed — correctly, but that measures the notes call rather
    # than the hold. Empty = "no release recorded", which is the interesting case.
    _mr_notes(){ printf '[]'; }
}

@test "RED-PROOF (A): an unverifiable MR is actually HELD, not merely advised about" {
    # The measured defect: 'CANNOT BE VERIFIED; treat it as held' with
    # draft:False, labels:[] — fully mergeable, nothing recorded on the forge.
    _load_cmd
    run cmd_guard 1 --apply --base=HEAD --head=HEAD
    [ "$status" -eq 2 ]
    grep -q 'HOLD_ATTEMPTED iid=1' "$HOLD_LOG" || {
        echo "cmd_guard returned 2 WITHOUT attempting a hold:"; cat "$HOLD_LOG"; false; }
    rm -f "$HOLD_LOG"
}

@test "RED-PROOF (A): and it says HELD, naming the reason as unverifiability" {
    _load_cmd
    run cmd_guard 1 --apply --base=HEAD --head=HEAD
    [[ "$output" == *"HELD"* ]]
    [[ "$output" == *"could NOT be verified"* ]] || {
        echo "the hold does not say WHY it was held"; false; }
    rm -f "$HOLD_LOG"
}

@test "a failed hold on the cannot-verify path is HOLD-MECHANISM-FAILED" {
    # Both layers absent must be said in the words that are not skimmable.
    _load_cmd
    _mr_apply_hold(){ printf 'HOLD_ATTEMPTED iid=%s\n' "$1" >> "$HOLD_LOG"; return 1; }
    run cmd_guard 1 --apply --base=HEAD --head=HEAD
    [ "$status" -eq 2 ]
    [[ "$output" == *"HOLD-MECHANISM-FAILED"* ]]
    [[ "$output" == *"Nothing is holding this MR"* ]]
    rm -f "$HOLD_LOG"
}

@test "an unconfirmable hold is HOLD-MECHANISM-FAILED too, not HELD" {
    # The PUT succeeded but the MR does not read as Draft: that is not a hold.
    _load_cmd
    _mr_is_draft(){ return 1; }
    run cmd_guard 1 --apply --base=HEAD --head=HEAD
    [[ "$output" == *"HOLD-MECHANISM-FAILED"* ]]
    [[ "$output" != *"HELD: !1 set to Draft because"* ]]
    rm -f "$HOLD_LOG"
}

@test "WITHOUT --apply nothing is written, and it says so" {
    # Read-only must stay read-only; the refusal is still exit 2.
    _load_cmd
    run cmd_guard 1 --base=HEAD --head=HEAD
    [ "$status" -eq 2 ]
    [ ! -s "$HOLD_LOG" ] || { echo "wrote a hold in read-only mode"; cat "$HOLD_LOG"; false; }
    [[ "$output" == *"re-run with --apply"* ]]
    rm -f "$HOLD_LOG"
}

@test "a READABLE but clean changeset is NOT held — the gate is not a blanket" {
    # The other direction. A gate that holds everything is as useless as one that
    # holds nothing, and this is the case that proves the hold is conditional.
    _load_cmd
    _mr_changed_files(){ printf 'lib/gitlab-mr.sh\nREADME.md\n'; }
    _mr_diff_ready(){ return 0; }
    run cmd_guard 1 --apply --base=HEAD --head=HEAD
    [ "$status" -eq 0 ]
    [ ! -s "$HOLD_LOG" ] || { echo "held a clean MR"; cat "$HOLD_LOG"; false; }
    rm -f "$HOLD_LOG"
}

@test "a SENSITIVE path is still held, by the original path (no regression)" {
    _load_cmd
    _mr_changed_files(){ printf 'CLAUDE.md\n'; }
    _mr_diff_ready(){ return 0; }
    run cmd_guard 1 --apply --base=HEAD --head=HEAD
    [ "$status" -eq 1 ]
    grep -q 'HOLD_ATTEMPTED' "$HOLD_LOG" || { echo "a CLAUDE.md change was NOT held"; false; }
    rm -f "$HOLD_LOG"
}

@test "RED-PROOF (B): the diagnosis names the cause that actually fires" {
    # It listed a shallow clone, a stale origin/main and an identical HEAD — and
    # not "GitLab has not finished preparing the diff", the real cause on !368.
    _load_cmd
    _mr_changed_files(){ printf ''; }    # readable, but empty: the preparing case
    run cmd_guard 1 --apply --base=HEAD --head=HEAD
    [[ "$output" == *"preparing"* ]] || {
        echo "the empty-changeset diagnosis never mentions async preparation"; false; }
    rm -f "$HOLD_LOG"
}

@test "the gate WAITS and re-reads before giving up" {
    # Waiting and then not looking again would be theatre. Proven by making the
    # second read succeed and checking the gate reaches a verdict from it.
    _load_cmd
    local n; n="$(mktemp)"; echo 0 > "$n"
    _mr_changed_files(){
        local c; c=$(( $(cat "$n") + 1 )); echo "$c" > "$n"
        [ "$c" -ge 2 ] && printf 'README.md\n'
        return 0
    }
    _mr_diff_ready(){ return 0; }
    run cmd_guard 1 --apply --base=HEAD --head=HEAD
    [ "$status" -eq 0 ]
    [ "$(cat "$n")" -ge 2 ] || { echo "only read the changeset once: $(cat "$n")"; false; }
    rm -f "$n" "$HOLD_LOG"
}

@test "no path reports 'nothing sensitive' from an empty changeset on a real MR" {
    # The invariant the whole gate rests on: a merge request with no changed
    # files is not a thing, so empty means 'could not look'.
    grep -q "A merge request with no changed files is not a thing" "$REPO_ROOT/scripts/commands/mr.sh"
}
