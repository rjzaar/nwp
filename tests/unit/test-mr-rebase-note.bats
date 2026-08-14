#!/usr/bin/env bats
#
# test-mr-rebase-note.bats — `pl mr rebase` and `pl mr note` (nwp/ops#356).
#
# WHY THESE TWO VERBS EXIST, AND WHY THEIR TESTS ARE ABOUT REFUSALS.
#
# Both gaps bit twice in two days, and both were routed around by hand:
#
#   * !441 sat on a head sha that predated the fix its pipeline was failing on.
#     The pipeline was COMPLETE, so its result could never change, and the same
#     red was reported three times. Unsticking it means a rebase — a WRITE, so
#     the read-only-reconnaissance exception does not cover it — and there was
#     no verb, only a hand-rolled `PUT /rebase` or a local `git push --force`.
#   * `pl issue comment` has existed for months; the MR equivalent had not, so
#     corrections on !431 and !441 went unrecorded rather than onto the page the
#     reviewer is actually reading.
#
# The interesting behaviour of `pl mr rebase` is entirely in what it REFUSES to
# conclude, so that is what is pinned here:
#
#   * a `conflict` verdict is NOT terminal — on this instance
#     detailed_merge_status is a cached computation that reports `conflict` for
#     branches that merge cleanly (CLAUDE.md, verified 2026-08-02). Only a
#     conflict a real local test-merge REPRODUCES is a conflict.
#   * when the forge and a real test-merge DISAGREE, that is CANNOT VERIFY —
#     never a clean bill and never a conflict.
#   * a rebase cancels the pipeline it supersedes, so the report must name the
#     NEW pipeline id. Naming the old one is what confused three reports in a row.
#   * `rebase_in_progress` still true is exit 3, "ask again" — never 0.
#
# HERMETIC: curl is PATH-stubbed and answers from files under $STATE, over a
# REAL throwaway git repo with a REAL remote — the local test-merge has to merge
# actual commits, so a fake git would prove nothing about it.

setup() {
  ROOT="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
  MR="$ROOT/scripts/commands/mr.sh"

  # A merge-request pipeline exports these; a test that reads the runner's
  # environment is testing the environment (test-mr-hold/-merge/-ci all scrub).
  unset CI_MERGE_REQUEST_IID CI_MERGE_REQUEST_TARGET_BRANCH_NAME \
        CI_MERGE_REQUEST_DIFF_BASE_SHA CI_SERVER_HOST CI_PROJECT_ID \
        CI_API_V4_URL NWP_MR_TOKEN NWP_GITLAB_HOST GITLAB_TOKEN MR_HOLD_TOKEN

  TMP="$BATS_TEST_TMPDIR/mrrn"; mkdir -p "$TMP"
  export STATE="$TMP/state"; mkdir -p "$STATE"
  export CURL_LOG="$TMP/curl.log"; : > "$CURL_LOG"
  export BODY_LOG="$TMP/body.log"; : > "$BODY_LOG"

  # ---- a real throwaway git repo with a real "remote" ---------------------
  # main and a clean branch that merges; `mk_conflicting_branch` adds one that
  # genuinely does not, so the conflict case is a REPRODUCED conflict and not a
  # stubbed claim about one.
  export REPO="$TMP/repo" REMOTE="$TMP/remote.git"
  git init -q --bare "$REMOTE"
  git init -q -b main "$REPO"
  git -C "$REPO" config user.email t@example.invalid
  git -C "$REPO" config user.name  Tester
  git -C "$REPO" remote add origin "$REMOTE"
  printf 'one\n' > "$REPO/README.md"
  git -C "$REPO" add -A && git -C "$REPO" commit -q -m initial
  git -C "$REPO" push -q -u origin main
  git -C "$REPO" checkout -q -b feature
  printf 'one\ntwo\n' > "$REPO/NEW.md"
  git -C "$REPO" add -A && git -C "$REPO" commit -q -m feature
  git -C "$REPO" push -q -u origin feature
  git -C "$REPO" checkout -q main
  # MAIN MOVES AFTER THE BRANCH IS CUT. This is !441's own shape — the fix the
  # branch needs landed on the target — and it is what makes a rebase a real
  # rebase here rather than a no-op.
  printf 'later\n' > "$REPO/ON-MAIN.md"
  git -C "$REPO" add -A && git -C "$REPO" commit -q -m "moved on"
  git -C "$REPO" push -q origin main

  STUB="$TMP/bin"; mkdir -p "$STUB"
  cat > "$STUB/curl" <<'STUBEOF'
#!/bin/bash
cfg=""
while [ $# -gt 0 ]; do case "$1" in -K) cfg="$2"; shift 2 ;; *) shift ;; esac; done
url=$(sed -n 's/^url = "\(.*\)"$/\1/p' "$cfg")
meth=$(sed -n 's/^request = "\(.*\)"$/\1/p' "$cfg"); meth="${meth:-GET}"
bodyf=$(sed -n 's/^data = "@\(.*\)"$/\1/p' "$cfg")
path="${url#*/api/v4}"
echo "$meth $path" >> "$CURL_LOG"
[ -n "$bodyf" ] && [ -f "$bodyf" ] && cat "$bodyf" >> "$BODY_LOG"
emit() { printf '%s\n%s' "$1" "${2:-200}"; }
case "$meth $path" in
  "GET /user")
      emit '{"username":"group_9_bot_53ae","bot":true}' ;;
  "PUT "*"/rebase")
      touch "$STATE/rebased"
      emit '{"rebase_in_progress":true}' "$(cat "$STATE/rebase_http" 2>/dev/null || echo 202)" ;;
  "POST "*"/notes")
      emit '{"id":7}' "$(cat "$STATE/note_http" 2>/dev/null || echo 201)" ;;
  "GET "*"include_rebase_in_progress"*)
      # Answers may be a SEQUENCE: mr_rebase.<n>.json for the nth read, falling
      # back to mr_rebase.json. A rebase is asynchronous, so "what the first read
      # said" and "what the third read said" are different facts and the suite
      # has to be able to express both.
      n=$(( $(cat "$STATE/rbcount" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STATE/rbcount"
      f="$STATE/mr_rebase.$n.json"; [ -f "$f" ] || f="$STATE/mr_rebase.json"
      emit "$(cat "$f")" "$(cat "$STATE/mr_http" 2>/dev/null || echo 200)" ;;
  "GET "*"/merge_requests/"*)
      if [ -e "$STATE/rebased" ] && [ -f "$STATE/mr_after.json" ]; then
        emit "$(cat "$STATE/mr_after.json")" "$(cat "$STATE/mr_http" 2>/dev/null || echo 200)"
      else
        emit "$(cat "$STATE/mr.json")" "$(cat "$STATE/mr_http" 2>/dev/null || echo 200)"
      fi ;;
  *)  emit '{}' ;;
esac
STUBEOF
  chmod +x "$STUB/curl"
  export PATH="$STUB:$PATH"

  export NWP_GITLAB_HOST="gitlab.example.invalid"
  export NWP_MR_TOKEN="TOK-TEST"
  export NWP_MR_PROJECT="9"
  # Bounded by ATTEMPTS, so the suite never sleeps.
  export NWP_MR_REBASE_POLL=0
  export NWP_MR_REBASE_TIMEOUT=3

  mk_mr conflict
  mk_mr_rebase false ""
  mk_mr_after
}

# $1 = detailed_merge_status ; $2 = source branch (default: feature)
mk_mr() {
  cat > "$STATE/mr.json" <<EOF
{"iid":441,"state":"opened","title":"REVIEW: a thing","sha":"c733a54f9615aaaa",
 "author":{"username":"group_9_bot_53ae"},"draft":false,"labels":[],
 "source_branch":"${2:-feature}","target_branch":"main",
 "detailed_merge_status":"$1","head_pipeline":{"id":2275,"status":"failed"}}
EOF
}
# $1 = rebase_in_progress ; $2 = merge_error
mk_mr_rebase() {
  cat > "$STATE/mr_rebase.json" <<EOF
{"iid":441,"state":"opened","title":"REVIEW: a thing","sha":"9f9f9f9f9f9faaaa",
 "author":{"username":"group_9_bot_53ae"},"draft":false,"labels":[],
 "source_branch":"feature","target_branch":"main",
 "rebase_in_progress":$1,"merge_error":"$2",
 "head_pipeline":{"id":2281,"status":"running"}}
EOF
}
mk_mr_after() {
  cat > "$STATE/mr_after.json" <<'EOF'
{"iid":441,"state":"opened","title":"REVIEW: a thing","sha":"9f9f9f9f9f9faaaa",
 "author":{"username":"group_9_bot_53ae"},"draft":false,"labels":[],
 "source_branch":"feature","target_branch":"main",
 "detailed_merge_status":"ci_still_running",
 "head_pipeline":{"id":2281,"status":"running"}}
EOF
}
# A branch that genuinely does not merge into main.
mk_conflicting_branch() {
  git -C "$REPO" checkout -q -b clash main
  printf 'THEIRS\n' > "$REPO/README.md"
  git -C "$REPO" add -A && git -C "$REPO" commit -q -m clash
  git -C "$REPO" push -q -u origin clash
  git -C "$REPO" checkout -q main
  printf 'OURS\n' > "$REPO/README.md"
  git -C "$REPO" add -A && git -C "$REPO" commit -q -m ours
  git -C "$REPO" push -q origin main
  mk_mr conflict clash
}

run_in_repo() { ( cd "$REPO" && bash "$MR" "$@" ); }

################################################################################
# pl mr rebase — the refusals
################################################################################

# 1. THE ONE THAT MATTERS MOST. CLAUDE.md: "Never trust `conflict` on its own."
#    A verb that refused here would be permanently unable to unstick the exact
#    MR it was written for, because a stale target branch is precisely when this
#    instance reports a phantom conflict.
@test "a STALE 'conflict' verdict is not terminal — the rebase proceeds" {
  run run_in_repo rebase 441
  [ "$status" -eq 0 ]
  [[ "$output" == *"cached"* ]]
  grep -q '^PUT /projects/9/merge_requests/441/rebase$' "$CURL_LOG"
}

# 2. The corollary: a conflict claim the forge makes AFTER the rebase is still
#    only a claim until a real merge of real commits reproduces it.
@test "a reported conflict that a local test-merge REPRODUCES is exit 1" {
  mk_conflicting_branch
  mk_mr_rebase false "Rebase failed: merge conflict in README.md"
  run run_in_repo rebase 441
  [ "$status" -eq 1 ]
  [[ "$output" == *"CONFLICT CONFIRMED"* ]]
  [[ "$output" == *"README.md"* ]]
}

# 3. And the shape CLAUDE.md actually recorded: the field says conflict, the
#    bytes say otherwise. Neither answer is available, so neither is given.
@test "forge says conflict but the local test-merge is CLEAN — exit 2, not 0 and not 1" {
  mk_mr_rebase false "Rebase failed: merge conflict"
  run run_in_repo rebase 441
  [ "$status" -eq 2 ]
  [[ "$output" == *"CANNOT VERIFY"* ]]
  [[ "$output" == *"CLEAN"* ]]
}

# 4. "checking means retry, not failure" — its rebase-shaped twin. A rebase that
#    has not finished is not a rebase that failed, and it is certainly not one
#    that succeeded.
@test "still rebasing when the wait runs out is exit 3, never 0" {
  mk_mr_rebase true ""
  run run_in_repo rebase 441
  [ "$status" -eq 3 ]
  [[ "$output" == *"has not landed"* ]]
}

# 4b. THE FALSE NEGATIVE THIS VERB SHIPPED WITH, AND WAS CAUGHT COMMITTING
#     AGAINST THE REAL !441 (2026-08-14).
#
# `PUT /rebase` returns 202 and a sidekiq worker does the work, so the FIRST read
# after it still reports rebase_in_progress=false and the OLD head sha. The first
# cut of this verb read that as "finished, nothing changed" and printed
#     SUCCESS: !441 is already up to date with main — head unchanged (c733a54f9615)
# eight seconds before the rebase landed as 9d32e469d656. A literal substituted
# for a measurement not yet takeable, wearing a green tick.
#
# The loop must therefore end on an OBSERVED head change, never on the absence of
# one. Read #1 below is the racing answer; read #2 is the truth.
@test "an unchanged head on the FIRST read is 'not yet', never 'already up to date'" {
  cat > "$STATE/mr_rebase.1.json" <<'EOF'
{"iid":441,"state":"opened","title":"REVIEW: a thing","sha":"c733a54f9615aaaa",
 "source_branch":"feature","target_branch":"main","draft":false,"labels":[],
 "rebase_in_progress":false,"merge_error":"",
 "head_pipeline":{"id":2275,"status":"failed"}}
EOF
  run run_in_repo rebase 441
  [ "$status" -eq 0 ]
  [[ "$output" != *"already up to date"* ]]
  [[ "$output" == *"9f9f9f9f9f9f"* ]]
  [[ "$output" == *"NEW pipeline #2281"* ]]
}

# 4c. …and when the head NEVER moves, that is exit 3, not a success. This is the
# same refusal from the other side: without it, the fix above would just push the
# false SUCCESS out to the end of the loop.
@test "a head that never moves is NOT FINISHED (exit 3), not 'nothing to do'" {
  cat > "$STATE/mr_rebase.json" <<'EOF'
{"iid":441,"state":"opened","title":"REVIEW: a thing","sha":"c733a54f9615aaaa",
 "source_branch":"feature","target_branch":"main","draft":false,"labels":[],
 "rebase_in_progress":false,"merge_error":"",
 "head_pipeline":{"id":2275,"status":"failed"}}
EOF
  run run_in_repo rebase 441
  [ "$status" -eq 3 ]
  [[ "$output" == *"has not landed"* ]]
  # Stronger than grepping for the old wording: no SUCCESS line may appear at
  # all. A verb that cannot tell whether its write landed has nothing to
  # congratulate anyone about.
  [[ "$output" != *"SUCCESS"* ]]
}

# 4d. The other half of the fix: whether the head MUST move is measured against
# the refs, so a genuinely current branch is reported without a write at all.
@test "an MR already on the tip of its target is reported WITHOUT writing" {
  # Cut a branch that already contains origin/main's tip.
  git -C "$REPO" checkout -q -b uptodate origin/main
  printf 'x\n' > "$REPO/X.md"
  git -C "$REPO" add -A && git -C "$REPO" commit -q -m x
  git -C "$REPO" push -q -u origin uptodate
  git -C "$REPO" checkout -q main
  mk_mr ci_must_pass uptodate
  run run_in_repo rebase 441
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALREADY on the tip"* ]]
  [[ "$output" == *"Measured, not assumed"* ]]
  ! grep -qE '^(PUT|POST) ' "$CURL_LOG"
}

# 5. THE REPORT THAT CONFUSED !441 THREE TIMES. The old pipeline is a completed
#    run on a sha the MR no longer has; naming it is how a fixed MR keeps
#    looking broken.
@test "reports the NEW pipeline id and says the old one is superseded" {
  mk_mr mergeable
  run run_in_repo rebase 441
  [ "$status" -eq 0 ]
  [[ "$output" == *"NEW pipeline #2281"* ]]
  [[ "$output" == *"#2275 is SUPERSEDED"* ]]
}

# 6. Fail-closed on the machine, not on the argument.
@test "no usable token is CANNOT VERIFY (exit 2) and sends nothing" {
  run bash -c "cd '$REPO' && NWP_MR_TOKEN= MR_SECRETS_FILE='$TMP/nope.yml' bash '$MR' rebase 441"
  [ "$status" -eq 2 ]
  [[ "$output" == *"CANNOT VERIFY"* ]]
  [[ "$output" == *"No request was made"* ]]
  [ ! -s "$CURL_LOG" ]
}

@test "an unknown iid is a definite negative (non-zero) that names the project" {
  echo 404 > "$STATE/mr_http"
  run run_in_repo rebase 999
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not exist"* ]]
  [[ "$output" == *"PER PROJECT"* ]]
}

@test "a closed MR is refused rather than rebased" {
  sed -i 's/"state":"opened"/"state":"merged"/' "$STATE/mr.json"
  run run_in_repo rebase 441
  [ "$status" -eq 1 ]
  [[ "$output" == *"nothing to rebase"* ]]
  ! grep -q '/rebase$' "$CURL_LOG"
}

# 7. A MACHINE NEVER MERGES. The token in this suite is a BOT, deliberately:
#    rebasing is exactly what a bot should do, merging is exactly what it must
#    not, and nothing added here may blur that.
@test "NEVER merges: no merge call reaches the wire" {
  mk_mr mergeable
  run run_in_repo rebase 441
  [ "$status" -eq 0 ]
  ! grep -q '/merge$' "$CURL_LOG"
  ! grep -q 'merge_when_pipeline_succeeds' "$CURL_LOG"
}

@test "--dry-run writes nothing" {
  run run_in_repo rebase 441 --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY RUN"* ]]
  ! grep -qE '^(PUT|POST) ' "$CURL_LOG"
}

@test "argument hygiene: a non-numeric iid and an unknown flag are refused BY NAME" {
  run run_in_repo rebase not-a-number
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage: pl mr rebase"* ]]
  run run_in_repo rebase 441 --force-push-please
  [ "$status" -ne 0 ]
  [[ "$output" == *"--force-push-please"* ]]
}

################################################################################
# pl mr note
################################################################################

@test "an EMPTY stdin body is refused, and nothing is posted" {
  run bash -c "cd '$REPO' && printf '' | bash '$MR' note 441"
  [ "$status" -eq 1 ]
  [[ "$output" == *"body is empty"* ]]
  ! grep -q '/notes$' "$CURL_LOG"
}

@test "a whitespace-only body is an empty body" {
  run bash -c "cd '$REPO' && printf '   \n\n  \n' | bash '$MR' note 441"
  [ "$status" -eq 1 ]
  [[ "$output" == *"body is empty"* ]]
  ! grep -q '/notes$' "$CURL_LOG"
}

# THE `pl issue create` SCAR: it accepted --desc and silently discarded piped
# stdin, so heredoc-shaped text vanished under a success message. This asserts
# the text reached the WIRE, not merely that the command exited 0.
@test "a piped multi-line body reaches the wire verbatim" {
  run bash -c "cd '$REPO' && printf 'line one\nline two\n' | bash '$MR' note 441"
  [ "$status" -eq 0 ]
  grep -q '^POST /projects/9/merge_requests/441/notes$' "$CURL_LOG"
  grep -q 'line one' "$BODY_LOG"
  grep -q 'line two' "$BODY_LOG"
}

@test "a one-line body may still be an argument" {
  run run_in_repo note 441 "a short correction"
  [ "$status" -eq 0 ]
  grep -q 'a short correction' "$BODY_LOG"
}

@test "no usable token is CANNOT VERIFY (exit 2), not a silent success" {
  run bash -c "cd '$REPO' && printf 'hi\n' | NWP_MR_TOKEN= MR_SECRETS_FILE='$TMP/nope.yml' bash '$MR' note 441"
  [ "$status" -eq 2 ]
  [[ "$output" == *"CANNOT VERIFY"* ]]
  [ ! -s "$BODY_LOG" ]
}

@test "an unknown iid is refused before anything is posted" {
  echo 404 > "$STATE/mr_http"
  run bash -c "cd '$REPO' && printf 'hi\n' | bash '$MR' note 999"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not exist"* ]]
  ! grep -q '/notes$' "$CURL_LOG"
}

@test "NEVER merges: pl mr note sends no merge call" {
  run bash -c "cd '$REPO' && printf 'hi\n' | bash '$MR' note 441"
  [ "$status" -eq 0 ]
  ! grep -q '/merge$' "$CURL_LOG"
}

################################################################################
# wiring
################################################################################
@test "mr.sh parses (bash -n) and pl dispatches both new verbs" {
  run bash -n "$MR"
  [ "$status" -eq 0 ]
  run grep -qE '^\s+rebase\)\s+cmd_rebase' "$MR"
  [ "$status" -eq 0 ]
  run grep -qE '^\s+note\|comment\)\s+cmd_note' "$MR"
  [ "$status" -eq 0 ]
}
