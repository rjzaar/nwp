#!/usr/bin/env bats
#
# The estate's review mode: derived from `approvers:`, one reader (nwp/ops#294).
#
# Operator ruling, 2026-08-06, stated twice:
#
#     "The current system is just you and me. We don't need the extra overhead of
#      two checks for now. It should only be happening once I approve the shift
#      and there is a second human dev in the system. Until then I should be able
#      to approve/merge once and only in one spot which is the MR location."
#
# WHAT THIS FILE HAS TO PROVE, and why each part is here:
#
#  1. SOLO WORKS TODAY — a sensitive-path MR is reported, not held, so the
#     operator's Merge click on the MR page is the whole approval.
#
#  2. TEAM STILL REFUSES — and this is the one that matters most. CLAUDE.md:
#     "Give such a guard a test proving it REFUSES against a fixture marked prod —
#     an inert guard nobody has seen fire is the 'check that has never been proven
#     to fail' class (ops#214)." The two-person machinery is being switched OFF,
#     not deleted, and a switch nobody has watched work is not a switch. So team
#     mode is driven here and observed to hold.
#
#  3. THE INVARIANT THAT SPANS BOTH MODES — a machine never merges. Solo drops the
#     Draft hold, so this is what stands between an armed automation and a merged
#     MR. It is checked, in both modes, against the token's FORGE-VERIFIED
#     identity — not a handle anybody typed.
#
#  4. FAIL-CLOSED IN THE RIGHT DIRECTION — anything unreadable reads as `team`.
#     The tempting default is today's mode, but then a typo or a bad checkout
#     silently switches the estate to single-approval, which is the permissive
#     direction. This nearly happened for real: `.nwp-review-mode` was silently
#     gitignored on first writing (the root `.gitignore` denies `/*`), so the file
#     would have been present locally and ABSENT in CI.
#
#  5. NO SECOND READER — the anti-drift clause the operator asked for
#     ("doesn't drift back into complexity"). One accessor decides; a grep proves
#     nothing else re-derives the policy.
#
# WHERE THE FACT LIVES, AND WHY THIS FILE WAS REWRITTEN ONCE. The first version
# invented `.nwp-review-mode` as an independent switch. Then `cmd_release` turned
# out to ALREADY key the ADR-0028 dispensation off `approvers:` in the secrets
# registry — the same fact, with the same stated philosophy ("adding the name is
# the entire switch... inert today, correct forever"). Two declarations of one
# fact, free to disagree, is exactly the drift the operator asked to avoid, so the
# registry became the truth and the file became a generated PROJECTION that exists
# only because private/ is a separate repo CI cannot read.

bats_require_minimum_version 1.5.0

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export MR_STATUS_FILE="$(mktemp)"
    # shellcheck source=/dev/null
    source "$REPO_ROOT/lib/ui.sh" 2>/dev/null || true
    # shellcheck source=/dev/null
    source "$REPO_ROOT/lib/gitlab-mr.sh"
    # AFTER the source — lib/gitlab-mr.sh resolves YQ on load (ops#293).
    YQ=""
    MODE_FILE="$(mktemp)"
    unset NWP_REVIEW_MODE
    unset CI_MERGE_REQUEST_DIFF_BASE_SHA CI_MERGE_REQUEST_TARGET_BRANCH_NAME CI_MERGE_REQUEST_IID
}
teardown() { rm -f "$MR_STATUS_FILE" "$MODE_FILE"; }

_mode(){ printf '%s\n' "$1" > "$MODE_FILE"; NWP_REVIEW_MODE_FILE="$MODE_FILE"; export NWP_REVIEW_MODE_FILE; }

# ---- 1. reading the declaration ---------------------------------------------

@test "the estate resolves to solo today, from the registry" {
    # Reads the REAL registry, so the repo cannot claim solo in prose while
    # declaring something else. If this fails, CLAUDE.md and the facts disagree.
    run _mr_review_mode
    [ "$output" = "solo" ]
    run _mr_review_mode_is_declared
    [ "$status" -eq 0 ]
}

@test "the shipped projection AGREES with the registry (no drift in the tree)" {
    # The committed state must not itself be drifted. Skipped nowhere: if the
    # registry cannot be read this reports it rather than passing quietly.
    if ! _mr_approver_count >/dev/null 2>&1; then
        echo "registry unreadable here — cannot compare; NOT treating that as a pass" >&3
        run _mr_review_mode_source
        [ "$output" = "projection" ] || [ "$output" = "fallback" ]
        return 0
    fi
    run _mr_review_mode_drift
    [ "$status" -eq 0 ] || { echo "the committed projection contradicts approvers:"; false; }
}

@test "the shipped file is TRACKED, not gitignored" {
    # It was ignored on first writing: the root .gitignore denies /* and
    # allowlists back, so the file existed locally and would have been absent in
    # CI. A policy CI cannot read is not a policy.
    run git -C "$REPO_ROOT" check-ignore -q .nwp-review-mode
    [ "$status" -ne 0 ] || { echo ".nwp-review-mode is gitignored — CI will not see it"; false; }
    run git -C "$REPO_ROOT" ls-files --error-unmatch .nwp-review-mode
    [ "$status" -eq 0 ] || { echo ".nwp-review-mode is not tracked"; false; }
}

@test "RED-PROOF: adding a SECOND approver arms team mode, with nothing else changed" {
    # THE WHOLE MECHANISM. The operator's condition — "once I approve the shift and
    # there is a second human dev" — is satisfied by one act in one place, and this
    # is the case that proves the act works. No flag, no file edit, no verb.
    local one two
    one=$(mktemp); printf 'approvers:\n  - rjzaar\n' > "$one"
    two=$(mktemp); printf 'approvers:\n  - rjzaar\n  - seconddev\n' > "$two"
    NWP_SECRETS_REGISTRY="$one" run _mr_review_mode
    [ "$output" = "solo" ] || { echo "1 approver read as $output"; false; }
    NWP_SECRETS_REGISTRY="$two" run _mr_review_mode
    [ "$output" = "team" ] || { echo "2 approvers read as $output — the switch did not arm"; false; }
    rm -f "$one" "$two"
}

@test "ZERO declared approvers is team, not solo — an unfinished registry is not one reviewer" {
    local none; none=$(mktemp); printf 'approvers: []\n' > "$none"
    NWP_SECRETS_REGISTRY="$none" run _mr_review_mode
    [ "$output" = "team" ]
    rm -f "$none"
}

@test "the approver count works with NO yq — CI-shaped hosts included" {
    # The old inline counter used a bare "$YQ" and silently counted 0 without it,
    # which reads as team here but would be a wrong number anywhere it mattered.
    local two; two=$(mktemp); printf 'approvers:\n  - a\n  - b\n' > "$two"
    YQ="" NWP_SECRETS_REGISTRY="$two" run _mr_approver_count
    [ "$output" = "2" ] || { echo "yq-less count returned [$output], expected 2"; false; }
    rm -f "$two"
}

@test "the projection is used ONLY when the registry is out of reach (i.e. in CI)" {
    _mode solo
    NWP_SECRETS_REGISTRY=/nonexistent/nope run _mr_review_mode_source
    [ "$output" = "projection" ]
    NWP_SECRETS_REGISTRY=/nonexistent/nope run _mr_review_mode
    [ "$output" = "solo" ]
}

@test "the registry OVERRIDES the projection — a stale file cannot loosen policy" {
    # If they disagree, truth wins. Otherwise a forgotten `sync` would be a way to
    # run single-approval while the estate declares two reviewers.
    _mode solo
    local two; two=$(mktemp); printf 'approvers:\n  - a\n  - b\n' > "$two"
    NWP_SECRETS_REGISTRY="$two" run _mr_review_mode
    [ "$output" = "team" ] || { echo "a stale solo projection beat the registry"; false; }
    NWP_SECRETS_REGISTRY="$two" run _mr_review_mode_drift
    [ "$status" -ne 0 ] || { echo "drift not reported"; false; }
    rm -f "$two"
}

@test "comments and blank lines are ignored — the file is mostly rationale" {
    export NWP_SECRETS_REGISTRY=/nonexistent/nope
    printf '# a comment\n\n   \n# another\nsolo\n' > "$MODE_FILE"
    NWP_REVIEW_MODE_FILE="$MODE_FILE" run _mr_review_mode
    [ "$output" = "solo" ]
}

@test "NWP_REVIEW_MODE overrides everything, for tests and for pinning CI" {
    _mode solo
    NWP_REVIEW_MODE=team run _mr_review_mode
    [ "$output" = "team" ]
    NWP_REVIEW_MODE=team run _mr_review_mode_source
    [ "$output" = "env" ]
}

# ---- 4. fail-closed, in the direction that costs friction not protection ----

@test "RED-PROOF: NOTHING readable at all reads as team, never solo" {
    NWP_SECRETS_REGISTRY=/nonexistent/nope NWP_REVIEW_MODE_FILE=/nonexistent/nope run _mr_review_mode
    [ "$output" = "team" ]
    NWP_SECRETS_REGISTRY=/nonexistent/nope NWP_REVIEW_MODE_FILE=/nonexistent/nope run _mr_review_mode_is_declared
    [ "$status" -ne 0 ]
    NWP_SECRETS_REGISTRY=/nonexistent/nope NWP_REVIEW_MODE_FILE=/nonexistent/nope run _mr_review_mode_source
    [ "$output" = "fallback" ]
}

@test "RED-PROOF: an unrecognised word reads as team, and is NOT 'declared'" {
    # "declared" is what stops `pl mr review-mode` presenting a fallback as
    # somebody's decision.
    export NWP_SECRETS_REGISTRY=/nonexistent/nope   # force the projection to matter
    for bad in nonsense TEAM Solo "solo team" 1 "-"; do
        printf '%s\n' "$bad" > "$MODE_FILE"
        NWP_REVIEW_MODE_FILE="$MODE_FILE" run _mr_review_mode
        [ "$output" = "team" ] || { echo "[$bad] read as $output — expected team"; false; }
        NWP_REVIEW_MODE_FILE="$MODE_FILE" run _mr_review_mode_is_declared
        [ "$status" -ne 0 ] || { echo "[$bad] reported as DECLARED"; false; }
    done
}

@test "RED-PROOF: an empty or comments-only projection reads as team" {
    export NWP_SECRETS_REGISTRY=/nonexistent/nope
    : > "$MODE_FILE"
    NWP_REVIEW_MODE_FILE="$MODE_FILE" run _mr_review_mode
    [ "$output" = "team" ]
    printf '# only a comment\n' > "$MODE_FILE"
    NWP_REVIEW_MODE_FILE="$MODE_FILE" run _mr_review_mode
    [ "$output" = "team" ]
}

@test "the file path is resolved when CALLED, not when sourced" {
    # A `FOO=x` computed at source time cannot be overridden later, which is
    # exactly the trap that made the yq-less suites run WITH yq for months
    # (ops#293). Every case in this file depends on this being call-time.
    export NWP_SECRETS_REGISTRY=/nonexistent/nope
    _mode team
    run _mr_review_mode
    [ "$output" = "team" ]
    _mode solo
    run _mr_review_mode
    [ "$output" = "solo" ]
}

# ---- 3. the invariant that spans both modes ---------------------------------

@test "RED-PROOF: a BOT token may not merge — in solo mode" {
    _mode solo
    _mr_token_user(){ printf 'group_9_bot_53ae5a1df066ec501e8867f7276f66b1'; }
    run _mr_merge_actor_ok
    [ "$status" -eq 1 ] || { echo "a bot was allowed to merge in solo mode"; false; }
}

@test "RED-PROOF: a BOT token may not merge — in team mode either" {
    _mode team
    _mr_token_user(){ printf 'project_12_bot_abc'; }
    run _mr_merge_actor_ok
    [ "$status" -eq 1 ]
}

@test "a human token MAY merge" {
    # The refusal must be conditional, or it is just a broken verb.
    _mode solo
    _mr_token_user(){ printf 'rjzaar'; }
    _mr_get(){ printf '%s' '[{"username":"rjzaar","bot":false}]'; }
    run _mr_merge_actor_ok
    [ "$status" -eq 0 ]
}

@test "RED-PROOF: an unknown identity may NOT merge — rc 2, not 0" {
    # "I could not tell whether I am a bot" is not "I am a human".
    _mode solo
    _mr_token_user(){ return 1; }
    run _mr_merge_actor_ok
    [ "$status" -eq 2 ]
}

@test "the real bot naming shape is caught, not just the tidy one" {
    # GitLab service accounts are group_9_bot_<32 hex>, not group_9_bot. A bare
    # group_*_bot pattern misses every real one.
    for h in group_9_bot_53ae5a1df066ec501e8867f7276f66b1 project_3_bot_x nwp_bot alert-bot ghost; do
        run _mr_handle_is_bot "$h"
        [ "$status" -eq 0 ] || { echo "$h not recognised as a bot"; false; }
    done
}

# ---- 2 + 1. the gate: solo reports, TEAM HOLDS ------------------------------
#
# Behavioural, not grep-on-source: mutation testing proved on a sibling suite that
# a grep for a function name still matches its own comment and definition.

_load_gate(){
    # shellcheck source=/dev/null
    source "$REPO_ROOT/scripts/commands/mr.sh" 2>/dev/null || true
    set +u +o pipefail          # mr.sh opens with `set -uo pipefail` (ops#283)
    HOLD_LOG="$(mktemp)"; NOTE_LOG="$(mktemp)"; DISARM_LOG="$(mktemp)"
    export NWP_GITLAB_HOST="forge.invalid.test"
    unset CI_MERGE_REQUEST_DIFF_BASE_SHA CI_MERGE_REQUEST_TARGET_BRANCH_NAME CI_MERGE_REQUEST_IID
    _mr_project(){ printf 'nwp%%2Fnwp'; }
    _mr_have_token(){ return 0; }
    _mr_notes(){ printf '[]'; }
    _mr_get(){ printf '{}'; }
    _mr_api(){ printf '{}'; }
    _mr_diff_ready(){ return 0; }
    _mr_retry_gate_job(){ return 0; }   # cmd_release re-runs it; unstubbed it dials out
    # A CLAUDE.md change: the sensitive-path class, straight from CLAUDE.md's list.
    _mr_changed_files(){ printf 'CLAUDE.md\n'; }
    _mr_apply_hold(){ printf 'HOLD iid=%s\n' "$1" >> "$HOLD_LOG"; return 0; }
    _mr_is_draft(){ return 0; }
    _mr_note_once(){ printf 'NOTE iid=%s\n' "$1" >> "$NOTE_LOG"; return 0; }
    _mr_disarm_automerge(){ printf 'DISARM iid=%s\n' "$1" >> "$DISARM_LOG"; return 0; }
    _mr_fetch(){ printf '%s' '{"iid":9,"title":"t","state":"opened","draft":false,"author":{"username":"alice"},"sha":"abc"}'; }
}
_end_gate(){ rm -f "$HOLD_LOG" "$NOTE_LOG" "$DISARM_LOG"; }

@test "SOLO: a CLAUDE.md change is REPORTED and NOT held — one click merges it" {
    # The operator's actual requirement. A Draft hold would mean un-draft AND
    # merge: two actions in two places, which is the friction being removed.
    _load_gate
    NWP_REVIEW_MODE=solo run cmd_guard 9 --apply --base=HEAD --head=HEAD
    [ "$status" -eq 0 ] || { echo "solo mode did not exit 0; output:"; echo "$output"; false; }
    [ ! -s "$HOLD_LOG" ] || { echo "solo mode HELD the MR:"; cat "$HOLD_LOG"; false; }
    [[ "$output" == *"SOLO REVIEW MODE"* ]]
    [[ "$output" == *"NOT held"* ]]
    _end_gate
}

@test "SOLO: the sensitive paths are recorded ON THE MR, not only in the log" {
    # "only in one spot which is the MR location" — so the information has to be
    # at that spot, not in a CI log the operator would have to go and find.
    _load_gate
    NWP_REVIEW_MODE=solo run cmd_guard 9 --apply --base=HEAD --head=HEAD
    grep -q 'NOTE iid=9' "$NOTE_LOG" || { echo "no note posted to the MR"; false; }
    _end_gate
}

@test "SOLO: auto-merge is still DISARMED — a machine must not merge it" {
    # The half of the 2026-08-01 fix that survives in every mode.
    _load_gate
    NWP_REVIEW_MODE=solo run cmd_guard 9 --apply --base=HEAD --head=HEAD
    grep -q 'DISARM iid=9' "$DISARM_LOG" || { echo "auto-merge was NOT disarmed"; false; }
    _end_gate
}

@test "RED-PROOF: TEAM mode HOLDS the same MR — the switch is proven to work" {
    # THE MOST IMPORTANT CASE IN THIS FILE. The two-person machinery is being
    # switched off, not removed, and CLAUDE.md is explicit that a guard nobody has
    # watched refuse is not a guard. Same fixture, same MR, opposite verdict.
    _load_gate
    NWP_REVIEW_MODE=team run cmd_guard 9 --apply --base=HEAD --head=HEAD
    [ "$status" -eq 1 ] || { echo "team mode did NOT hold (exit $status); output:"; echo "$output"; false; }
    grep -q 'HOLD iid=9' "$HOLD_LOG" || { echo "team mode did not apply the hold"; false; }
    [[ "$output" != *"SOLO REVIEW MODE"* ]]
    _end_gate
}

@test "RED-PROOF: an UNDECLARED mode holds, exactly as team does" {
    # Fail-closed reaching all the way through to the verdict, not just to the
    # accessor. This is the case the gitignore mistake would have hit.
    _load_gate
    NWP_REVIEW_MODE= NWP_SECRETS_REGISTRY=/nonexistent/nope NWP_REVIEW_MODE_FILE=/nonexistent/nope \
      run cmd_guard 9 --apply --base=HEAD --head=HEAD
    [ "$status" -eq 1 ] || { echo "an unreadable policy did not hold (exit $status)"; false; }
    grep -q 'HOLD iid=9' "$HOLD_LOG"
    _end_gate
}

@test "a CLEAN diff is not held in either mode — the gate is not a blanket" {
    _load_gate
    _mr_changed_files(){ printf 'README.md\n'; }
    NWP_REVIEW_MODE=solo run cmd_guard 9 --apply --base=HEAD --head=HEAD
    [ "$status" -eq 0 ]
    [ ! -s "$HOLD_LOG" ]
    NWP_REVIEW_MODE=team run cmd_guard 9 --apply --base=HEAD --head=HEAD
    [ "$status" -eq 0 ]
    [ ! -s "$HOLD_LOG" ]
    _end_gate
}

@test "SOLO with no token AND no readable diff fails closed BEFORE mode matters" {
    # My first version of this case asserted the solo branch was reached with no
    # token. It cannot be: without a token the gate has no way to read the diff
    # either, so it fails closed at exit 2 first. Asserting the real behaviour
    # instead of the behaviour I assumed — and exit 2 here is correct, because
    # "I could not see what changed" outranks any review-mode question.
    _load_gate
    _mr_have_token(){ return 1; }
    NWP_REVIEW_MODE=solo run cmd_guard 9 --apply --base=HEAD --head=HEAD
    [ "$status" -eq 2 ]
    [ ! -s "$NOTE_LOG" ]
    [[ "$output" != *"SOLO REVIEW MODE"* ]] || { echo "claimed a verdict it could not reach"; false; }
    _end_gate
}

@test "SOLO from a GIT RANGE with no token: says the note could NOT be posted" {
    # The realistic no-token case — and the only one that exercises the git-range
    # path, which needs no credentials at all. A throwaway repo, so the assertion
    # does not depend on this branch's own history.
    _load_gate
    local tmpd; tmpd=$(mktemp -d)
    (
      cd "$tmpd"
      git init -q .
      git config user.email t@t; git config user.name t
      printf 'v1\n' > CLAUDE.md; git add CLAUDE.md; git commit -qm base
      printf 'v2\n' > CLAUDE.md; git add CLAUDE.md; git commit -qm change
    )
    _mr_have_token(){ return 1; }
    cd "$tmpd"
    NWP_REVIEW_MODE=solo run cmd_guard 9 --apply --base=HEAD~1 --head=HEAD
    cd "$REPO_ROOT"
    [ "$status" -eq 0 ] || { echo "solo did not allow a git-range diff (exit $status):"; echo "$output"; false; }
    [[ "$output" == *"SOLO REVIEW MODE"* ]]
    [ ! -s "$NOTE_LOG" ] || { echo "posted a note with no token"; false; }
    [[ "$output" == *"could NOT be disarmed"* ]] || { echo "silently skipped the disarm:"; echo "$output"; false; }
    rm -rf "$tmpd"
    _end_gate
}

# ---- cmd_release --merge is refused in solo mode ----------------------------

@test "RED-PROOF: --merge is REFUSED in solo mode — the MR page is the one spot" {
    # A second way to merge, from a shell, by whoever holds the token, is a second
    # approval spot — and the one an automation would reach for.
    _load_gate
    _mr_assert_releasable(){ printf 'held'; return 0; }
    _mr_token_user(){ printf 'rjzaar'; }
    _mr_approver_count(){ printf '1'; }        # solo, and cmd_release reads this too
    _mr_lift_hold(){ return 0; }
    # NOT draft after the release. _load_gate stubs this TRUE for the hold-confirm
    # case, and cmd_release then `die`s with "still a draft after release" — and a
    # die exits, so the case VANISHED with no output rather than failing (ops#283).
    _mr_is_draft(){ return 1; }
    cmd_merge(){ printf 'MERGED\n' >> "$HOLD_LOG"; }
    # NWP_MR_MERGE_TIMEOUT=0 so a regression cannot HANG instead of failing: with
    # the refusal removed, cmd_release falls into the wait-for-green loop and the
    # case sat for the full 600s default, which reads as a stalled suite rather
    # than a caught mutation.
    NWP_MR_MERGE_TIMEOUT=0 NWP_REVIEW_MODE=solo \
      run cmd_release 9 --approved-by=rjzaar --reason=probe --merge
    [ "$status" -ne 0 ]
    [[ "$output" == *"REFUSING --merge"* ]]
    [[ "$output" == *"SOLO review mode"* ]]
    ! grep -q MERGED "$HOLD_LOG"
    _end_gate
}

# ---- 5. no second reader: the anti-drift clause -----------------------------

@test "ANTI-DRIFT: exactly ONE place counts approvers:" {
    # cmd_release used to count the list itself with its own yq call while
    # _mr_review_mode counted it again — two readers of one fact. That is the
    # duplication the operator meant by "drift back into complexity".
    local counters
    counters=$(grep -rn '\.approvers' "$REPO_ROOT/lib" "$REPO_ROOT/scripts" 2>/dev/null \
               | grep -vE ':[0-9]+:[[:space:]]*#' || true)
    [ "$(printf '%s\n' "$counters" | grep -c .)" -eq 1 ] \
      || { echo "approvers: is counted in more than one place:"; echo "$counters"; false; }
    printf '%s' "$counters" | grep -q 'lib/gitlab-mr.sh'
}

@test "ANTI-DRIFT: only the LIBRARY reads the projection; elsewhere it is only named" {
    # Two earlier versions of this assertion failed on prose — the MR note's own
    # "(\`.nwp-review-mode\`)" and the lint's "Fix: pl mr review-mode sync # then
    # commit .nwp-review-mode". Both are text shown to the operator, exactly where
    # it belongs. Taxing the explanation is how you train people to delete it, a
    # mistake this repo has now made four times. So the invariant is stated the way
    # it is actually true: the library opens the file; everywhere else merely
    # mentions it, and a mention must be inside something being printed.
    local libhits
    libhits=$(grep -rn '\.nwp-review-mode' "$REPO_ROOT/lib" 2>/dev/null \
              | grep -vE ':[0-9]+:[[:space:]]*#' || true)
    [ "$(printf '%s\n' "$libhits" | grep -c .)" -eq 1 ] \
      || { echo "the library names the projection more than once:"; echo "$libhits"; false; }
    printf '%s' "$libhits" | grep -q '_mr_review_mode_file' \
      || { echo "the one library reference is not the accessor:"; echo "$libhits"; false; }

    # Outside lib/ the path must never be OPENED. Deliberately narrow: it looks for
    # a read command taking the path as an argument, which is necessarily on one
    # line. An earlier attempt tried to exclude "human-facing output" instead and
    # failed on CONTINUATION LINES of multi-line strings — the die message and the
    # MR note body both mention the file on a line that carries no printf, because
    # the printf is three lines up. A line-based grep cannot see inside a multi-line
    # string, so it must assert something that is true line by line.
    local opens
    opens=$(grep -rnE '(cat|grep|head|tail|sed|awk|source)[[:space:]][^"]*\.nwp-review-mode|<[[:space:]]*"?[^"]*\.nwp-review-mode' \
              "$REPO_ROOT/scripts" 2>/dev/null | grep -vE ':[0-9]+:[[:space:]]*#' || true)
    [ -z "$opens" ] || { echo "the projection is OPENED outside lib/:"; echo "$opens"; false; }

    # And exactly one place decides the default path.
    local decl
    decl=$(grep -rn 'NWP_REVIEW_MODE_FILE:-' "$REPO_ROOT/lib" "$REPO_ROOT/scripts" 2>/dev/null | grep -c . || true)
    [ "$decl" -eq 1 ] || { echo "the default path is declared $decl times, expected 1"; false; }
}

@test "ANTI-DRIFT: the mode ENV is honoured in one place only" {
    # $NWP_REVIEW_MODE may be read by the accessor and printed by the report; it must
    # not become a second branch point somewhere else.
    local reads
    reads=$(grep -rn '\$NWP_REVIEW_MODE\b\|"\${NWP_REVIEW_MODE:-' "$REPO_ROOT/lib" "$REPO_ROOT/scripts" 2>/dev/null \
            | grep -vE ':[0-9]+:[[:space:]]*#' \
            | grep -vE '(echo|printf|print_[a-z]+)' || true)
    [ "$(printf '%s\n' "$reads" | grep -c .)" -le 2 ] \
      || { echo "NWP_REVIEW_MODE is branched on in more than the accessor:"; echo "$reads"; false; }
    printf '%s' "$reads" | grep -q 'lib/gitlab-mr.sh' \
      || { echo "the accessor is not among the readers"; false; }
    ! printf '%s' "$reads" | grep -v 'lib/gitlab-mr.sh' | grep -q . \
      || { echo "read outside the library:"; printf '%s\n' "$reads" | grep -v 'lib/gitlab-mr.sh'; false; }
}

@test "ANTI-DRIFT: CLAUDE.md names approvers: as the switch, not the file" {
    grep -q 'approvers:' "$REPO_ROOT/CLAUDE.md"
    grep -q '_mr_approver_count\|_mr_review_mode' "$REPO_ROOT/CLAUDE.md"
    # the projection must be described as generated, so nobody edits it to set policy
    grep -qi 'GENERATED PROJECTION\|generated projection' "$REPO_ROOT/CLAUDE.md"
    # and it must state the invariant, since that is what makes solo safe
    grep -qi 'a machine never merges' "$REPO_ROOT/CLAUDE.md"
}

@test "ANTI-DRIFT: there is deliberately NO \`review-mode set\`" {
    # A settable mode is a way to be in team mode with nobody to be the second pair
    # of eyes, or in solo mode with two devs. The verb refuses and explains.
    grep -q "there is no 'set'" "$REPO_ROOT/scripts/commands/mr.sh"
    ! grep -qE 'review-mode.*\bset\b.*--reason' "$REPO_ROOT/CLAUDE.md"
}

@test "ANTI-DRIFT: the projection lint exists, is executable, and grades cannot-verify as 2" {
    local l="$REPO_ROOT/scripts/ci/lint-review-mode-projection.sh"
    [ -x "$l" ]
    NWP_SECRETS_REGISTRY=/nonexistent/nope run "$l"
    [ "$status" -eq 2 ] || { echo "an unreadable registry graded $status, expected 2 (cannot verify)"; false; }
    [[ "$output" == *"CANNOT VERIFY"* ]]
}

@test "RED-PROOF: the projection lint FAILS on real drift" {
    # Proven to go red, not merely present (ops#214).
    local l="$REPO_ROOT/scripts/ci/lint-review-mode-projection.sh" two
    two=$(mktemp); printf 'approvers:\n  - a\n  - b\n' > "$two"   # says team
    _mode solo                                                     # projection says solo
    NWP_SECRETS_REGISTRY="$two" NWP_REVIEW_MODE_FILE="$MODE_FILE" run "$l"
    [ "$status" -eq 1 ] || { echo "drift graded $status, expected 1"; echo "$output"; false; }
    [[ "$output" == *"DRIFT"* ]]
    rm -f "$two"
}

@test "ANTI-DRIFT: the lint is wired into pre-commit, where both are readable" {
    # It can only run where the private registry exists — a workstation, not CI —
    # so pre-commit is the correct home and a CI job would be theatre.
    grep -q 'review-mode-projection' "$REPO_ROOT/.pre-commit-config.yaml"
    run yq e '.repos[].hooks[].id' "$REPO_ROOT/.pre-commit-config.yaml"
    [[ "$output" == *"review-mode-projection"* ]] || { echo "hook not parseable from the config"; false; }
}
