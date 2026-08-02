#!/usr/bin/env bats
#
# test-mr-merge.bats — ops#216's OTHER half: `pl mr merge`, plus the three
# `pl mr create` preconditions that !339 does not carry.
#
# This file deliberately does NOT re-test what tests/unit/test-mr-create.bats
# already pins (unpushed branch, remote divergence, source==target, unknown
# flags, title/body defaulting). Two agents implemented `pl mr create` in
# parallel on 2026-08-02 — !339 and !341, fourteen minutes apart — and this
# branch is the reconciliation: it builds ON !339 rather than competing with it.
# That collision is also why one of the new cases below exists.
#
# WHY `pl mr merge` — the issue's own words: "the merge-status poke logic has
# nowhere to live". Two facts about THIS instance, previously carried in a
# session's shell loop:
#
#   * `detailed_merge_status` goes STALE and reports `conflict` for branches
#     that merge cleanly. `PUT /rebase` forces a recompute; `checking` means
#     ask again, not no.
#   * a rebase pushes a new head, which CANCELS the running pipeline. A loop
#     that rebases every round destroys the work it is waiting for — ten
#     cancelled pipelines on one MR, and from the log it looked like healthy
#     activity (report §11.11). Hence AT MOST ONE rebase per run, asserted here
#     by COUNTING the rebase calls rather than by reading stdout.
#
# HERMETIC: curl is PATH-stubbed against a real throwaway git repo with a real
# remote, and every call is logged, so "did not merge" and "rebased exactly
# once" are assertions about the wire. CI variables are scrubbed for the reason
# test-mr-hold.bats scrubs them: an MR pipeline exports CI_MERGE_REQUEST_IID /
# CI_SERVER_HOST / CI_PROJECT_ID / NWP_MR_TOKEN, and a test that reads those
# passes locally and fails only on the runner.

setup() {
  ROOT="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
  MR="$ROOT/scripts/commands/mr.sh"
  # SCRUB THE RUNNER'S ENVIRONMENT — including CI_MERGE_REQUEST_DIFF_BASE_SHA,
  # which cost two CI-only failures before it was in this list.
  #
  # `cmd_guard` prefers a GIT RANGE over the API, and it derives that range from
  # CI_MERGE_REQUEST_DIFF_BASE_SHA when set. On the runner that variable points
  # at the REAL merge request's base, and the checkout is the real repo — so the
  # gate graded THIS MR's own diff instead of the stubbed one, and two cases that
  # pass on a laptop failed only in CI (pipeline 1827, job 13834).
  #
  # That is precisely the shape recorded in §6c, reproduced here in my own test:
  # a test that reads its environment is testing the environment. Reproduced
  # locally by exporting the one variable, which is how it was found rather than
  # guessed — and the last case in this file exports it deliberately and asserts
  # the suite is now immune, so this cannot rot back.
  unset CI_MERGE_REQUEST_IID CI_MERGE_REQUEST_TARGET_BRANCH_NAME \
        CI_MERGE_REQUEST_DIFF_BASE_SHA CI_MERGE_REQUEST_SOURCE_BRANCH_SHA \
        CI_MERGE_REQUEST_TARGET_BRANCH_SHA \
        CI_SERVER_HOST CI_PROJECT_ID CI_API_V4_URL \
        NWP_MR_TOKEN NWP_GITLAB_HOST GITLAB_TOKEN MR_HOLD_TOKEN

  TMP="$BATS_TEST_TMPDIR/mrcm"; mkdir -p "$TMP"
  export STATE="$TMP/state"; mkdir -p "$STATE"
  export CURL_LOG="$TMP/curl.log"

  # ---- a real throwaway git repo with a real "remote" --------------------
  export REPO="$TMP/repo" REMOTE="$TMP/remote.git"
  git init -q --bare "$REMOTE"
  git init -q -b main "$REPO"
  git -C "$REPO" config user.email t@example.invalid
  git -C "$REPO" config user.name  Tester
  git -C "$REPO" remote add origin "$REMOTE"
  echo hello > "$REPO/README.md"
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m "initial"
  git -C "$REPO" push -q -u origin main

  # ---- curl stub ----------------------------------------------------------
  # Answers from files under $STATE so a test can set the scenario, and logs
  # METHOD + path so call COUNTS can be asserted.
  STUB="$TMP/bin"; mkdir -p "$STUB"
  cat > "$STUB/curl" <<'STUBEOF'
#!/bin/bash
cfg=""
while [ $# -gt 0 ]; do case "$1" in -K) cfg="$2"; shift 2 ;; *) shift ;; esac; done
url=$(sed -n 's/^url = "\(.*\)"$/\1/p' "$cfg")
meth=$(sed -n 's/^request = "\(.*\)"$/\1/p' "$cfg"); meth="${meth:-GET}"
path="${url#*/api/v4}"
echo "$meth $path" >> "$CURL_LOG"
emit() { printf '%s\n%s' "$1" "${2:-200}"; }     # body \n http_code (write-out)
case "$meth $path" in
  "GET "*"/merge_requests?state=opened&source_branch="*)
      emit "$(cat "$STATE/existing.json" 2>/dev/null || echo '[]')" ;;
  "GET "*"/merge_requests?state=opened&per_page="*)
      emit "$(cat "$STATE/all_open.json" 2>/dev/null || echo '[]')" ;;
  "POST "*"/merge_requests")
      emit '{"iid":900,"web_url":"https://x/900"}' 201 ;;
  "GET "*"/merge_requests/"*"/diffs"*)
      emit "$(cat "$STATE/diffs.json" 2>/dev/null || echo '[]')" ;;
  "GET "*"/merge_requests/"*"/notes"*)
      emit '[]' ;;
  "PUT "*"/rebase")
      # A rebase makes the forge re-evaluate; the scenario says what it becomes.
      cp "$STATE/after_rebase.json" "$STATE/mr.json" 2>/dev/null || true
      emit '{"rebase_in_progress":true}' 202 ;;
  "PUT "*"/merge")
      emit '{"iid":900,"state":"merged"}' ;;
  "GET "*"/pipelines/"*"/jobs"*)
      emit "$(cat "$STATE/jobs.json" 2>/dev/null || echo '[]')" ;;
  "POST "*"/jobs/"*"/retry")
      # A retry makes the forge re-evaluate; the scenario says what it becomes.
      cp "$STATE/after_retry.json" "$STATE/mr.json" 2>/dev/null || true
      emit '{"id":1,"status":"pending"}' 201 ;;
  "GET "*"/merge_requests/"*)
      emit "$(cat "$STATE/mr.json")" ;;
  *)  emit '{}' ;;
esac
STUBEOF
  chmod +x "$STUB/curl"
  export PATH="$STUB:$PATH"

  export NWP_GITLAB_HOST="gitlab.example.invalid"
  export NWP_MR_TOKEN="TOK-TEST"
  export NWP_MR_PROJECT="9"

  # Every real MR changes at least one file, and the guard treats an EMPTY diff
  # list as "cannot verify" (rc 2 → held), which is correct fail-closed
  # behaviour but is not the default a merge test wants to exercise. Give the
  # fixture a harmless changed file; the two gate cases below override it.
  echo '[{"new_path":"docs/x.md","old_path":"docs/x.md"}]' > "$STATE/diffs.json"
}

_mr_json() { # $1=detailed_merge_status  $2=draft(true|false)  [$3=file]
  cat > "${3:-$STATE/mr.json}" <<EOF
{"iid":900,"state":"opened","title":"$([ "$2" = true ] && printf 'Draft: ')a change",
 "draft":$2,"sha":"deadbeefcafe","detailed_merge_status":"$1",
 "head_pipeline":{"id":1865,"sha":"deadbeefcafe"},
 "author":{"username":"someone"},"labels":[],"merge_when_pipeline_succeeds":false}
EOF
}

_jobs_json() { # each arg "name:status"; allow_failure false throughout
  { printf '['
    local first=1 a n st
    for a in "$@"; do
      n="${a%:*}"; st="${a##*:}"   # job names contain colons; split on the LAST one
      [ $first -eq 1 ] || printf ','
      first=0
      printf '{"id":%s,"name":"%s","status":"%s","allow_failure":false}' \
             "$((RANDOM + 1000))" "$n" "$st"
    done
    printf ']'
  } > "$STATE/jobs.json"
}

_branch() { # make + push a feature branch, leave the repo on it
  git -C "$REPO" checkout -q -b "$1"
  echo "$1" > "$REPO/f.txt"; git -C "$REPO" add -A
  git -C "$REPO" commit -q -m "${2:-feat: a change}" -m "${3:-body line}"
  [ "${4:-push}" = push ] && git -C "$REPO" push -q -u origin "$1"
  return 0
}

_run_in_repo() { ( cd "$REPO" && bash "$MR" "$@" ); }

################################################################################
# pl mr create — the three preconditions, each proven to REFUSE and each paired
# with a case that must SUCCEED. A gate that refuses everything protects nothing.
################################################################################

@test "REFUSES a duplicate and points at the existing MR" {
  _branch feat/dup
  echo '[{"iid":42,"state":"opened"}]' > "$STATE/existing.json"
  run _run_in_repo create
  [ "$status" -eq 1 ]
  [[ "$output" == *"!42 is already open"* ]]
  ! grep -q '^POST ' "$CURL_LOG"        # positively: nothing was created
}

@test "--closes appends the tracker reference exactly once (idempotent)" {
  _branch feat/closes "feat: y" "already says Closes nwp/ops#216 here"
  run _run_in_repo create --closes=216 --dry-run
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c 'Closes nwp/ops#216')" -eq 1 ]

  _branch feat/closes2 "feat: z" "no reference at all"
  run _run_in_repo create --closes=216 --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Closes nwp/ops#216"* ]]
}

@test "--closes refuses a non-numeric issue reference" {
  _branch feat/badcloses
  run _run_in_repo create --closes=banana --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"wants an issue number"* ]]
}

@test "--dry-run sends nothing at all" {
  _branch feat/dry
  run _run_in_repo create --dry-run
  [ "$status" -eq 0 ]
  [ ! -f "$CURL_LOG" ] || ! grep -q '^POST ' "$CURL_LOG"
}

################################################################################
# pl mr merge — the knowledge that had nowhere to live.
################################################################################

@test "REFUSES a HELD (draft) MR — a hold is a refusal, not a wait" {
  _mr_json draft_status true
  run bash "$MR" merge 900
  [ "$status" -eq 1 ]
  [[ "$output" == *"HELD"* ]]
  ! grep -q '/merge$' "$CURL_LOG"
}

@test "the DRAFT FLAG alone refuses, even if merge status disagrees (two layers)" {
  # Mutation-found gap: deleting the `_mr_is_draft` check changed NOTHING,
  # because the `draft_status` case arm caught it too. Two layers is the right
  # design, but a test satisfied by either one cannot tell you which is gone.
  # This case puts them in disagreement, so it can only pass via the flag.
  _mr_json mergeable true
  run bash "$MR" merge 900
  [ "$status" -eq 1 ]
  [[ "$output" == *"HELD (draft)"* ]]
  ! grep -q 'PUT .*/merge$' "$CURL_LOG"
}

@test "'conflict' is NOT believed until one recompute — and the recompute is honoured" {
  _mr_json conflict false
  _mr_json mergeable false "$STATE/after_rebase.json"    # the poke clears it
  run bash "$MR" merge 900
  [ "$status" -eq 0 ]
  [[ "$output" == *"forcing ONE recompute"* ]]
  grep -q 'PUT .*/rebase$' "$CURL_LOG"
  grep -q 'PUT .*/merge$'  "$CURL_LOG"
}

@test "AT MOST ONE rebase per run — a rebase cancels the pipeline it waits for" {
  # The §11.11 bug: re-requesting a rebase each round cancelled ten pipelines on
  # one MR and the queue never moved. Asserted by COUNTING wire calls, because
  # the log of the buggy version looked like healthy activity.
  _mr_json conflict false
  _mr_json conflict false "$STATE/after_rebase.json"     # the poke does NOT clear it
  run bash "$MR" merge 900
  [ "$status" -eq 2 ]
  [[ "$output" == *"confirmed after a recompute"* ]]
  [ "$(grep -c 'PUT .*/rebase$' "$CURL_LOG")" -eq 1 ]
  ! grep -q 'PUT .*/merge$' "$CURL_LOG"
}

@test "--no-rebase believes the forge and refuses to poke" {
  _mr_json conflict false
  run bash "$MR" merge 900 --no-rebase
  [ "$status" -eq 2 ]
  ! grep -q '/rebase$' "$CURL_LOG"
}

@test "'ci_still_running' is exit 3 (not ready), not a failure and not a merge" {
  _mr_json ci_still_running false
  run bash "$MR" merge 900
  [ "$status" -eq 3 ]
  ! grep -q '/merge$' "$CURL_LOG"
}

@test "an unreadable MR is exit 4 CANNOT VERIFY — never a merge" {
  rm -f "$STATE/mr.json"
  printf '' > "$STATE/mr.json"
  run bash "$MR" merge 900
  [ "$status" -eq 4 ]
  ! grep -q '/merge$' "$CURL_LOG"
}

@test "PASSES: a plainly mergeable MR merges" {
  _mr_json mergeable false
  run bash "$MR" merge 900
  [ "$status" -eq 0 ]
  grep -q 'PUT .*/merge$' "$CURL_LOG"
}

@test "--dry-run on a mergeable MR reports ready and merges NOTHING" {
  _mr_json mergeable false
  run bash "$MR" merge 900 --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY RUN"* ]]
  ! grep -q 'PUT .*/merge$' "$CURL_LOG"
}

@test "merge is refused when the sensitive-path gate does not pass" {
  # A sensitive path with no release record must block the merge, not merely
  # colour the status output.
  _mr_json mergeable false
  echo '[{"new_path":".gitlab-ci.yml","old_path":".gitlab-ci.yml"}]' > "$STATE/diffs.json"
  run bash "$MR" merge 900
  [ "$status" -eq 1 ]
  [[ "$output" == *"sensitive-path gate"* ]]
  ! grep -q 'PUT .*/merge$' "$CURL_LOG"
}

@test "NEGATIVE CONTROL: the same MR with a harmless diff DOES merge" {
  # Without this, the case above is satisfied by a gate that blocks everything.
  _mr_json mergeable false
  echo '[{"new_path":"docs/readme.md","old_path":"docs/readme.md"}]' > "$STATE/diffs.json"
  run bash "$MR" merge 900
  [ "$status" -eq 0 ]
  grep -q 'PUT .*/merge$' "$CURL_LOG"
}

@test "an EMPTY diff list is CANNOT VERIFY (held), not 'nothing sensitive'" {
  # Recorded rather than worked around: the guard cannot tell an MR with no
  # files from an MR whose diff it could not read, so it holds. That is the
  # right call, and a merge test that silently relied on it would have been
  # green for the wrong reason.
  _mr_json mergeable false
  echo '[]' > "$STATE/diffs.json"
  run bash "$MR" merge 900
  [ "$status" -eq 1 ]
  [[ "$output" == *"guard exit 2"* ]]
  ! grep -q 'PUT .*/merge$' "$CURL_LOG"
}

@test "pl mr --help advertises create and merge" {
  run bash "$MR" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"pl mr create"* ]]
  [[ "$output" == *"pl mr merge"* ]]
}

@test "the merge loop TERMINATES even if the once-only rebase flag is defeated" {
  # Found by mutating this function: removing `rebased=true` made the loop
  # non-terminating, because the `conflict` arm `continue`s BEFORE the
  # wall-clock deadline test, so --wait never bounded it. The flag is the
  # correct fix; a hard round cap is the belt, and this pins the belt.
  _mr_json conflict false
  _mr_json conflict false "$STATE/after_rebase.json"
  run timeout 60 bash "$MR" merge 900 --wait=20
  [ "$status" -ne 124 ]                 # 124 = timeout killed it
  ! grep -q 'PUT .*/merge$' "$CURL_LOG"
}

@test "--closes REFUSES when another OPEN MR already claims to close that issue" {
  # This case exists because it happened. On 2026-08-02 two agents working the
  # same ops queue opened !339 and !341 for ops#216 fourteen minutes apart. The
  # source-branch check cannot catch that — the branches differ — so the only
  # way to see it is to ask which open MRs already say `Closes nwp/ops#N`.
  _branch feat/parallel
  echo '[]' > "$STATE/existing.json"
  cat > "$STATE/all_open.json" <<'JSON'
[{"iid":339,"title":"REVIEW: feat(mr): pl mr create","description":"work\n\nCloses nwp/ops#216"}]
JSON
  run _run_in_repo create --closes=216
  [ "$status" -eq 1 ]
  [[ "$output" == *"!339 already claims to close nwp/ops#216"* ]]
  ! grep -q '^POST ' "$CURL_LOG"
}

@test "NEGATIVE CONTROL: a DIFFERENT issue number is not a collision" {
  # Without this the check above is satisfied by one that refuses every --closes.
  _branch feat/parallel2
  echo '[]' > "$STATE/existing.json"
  cat > "$STATE/all_open.json" <<'JSON'
[{"iid":339,"title":"other work","description":"Closes nwp/ops#216"}]
JSON
  _mr_json mergeable false
  run _run_in_repo create --closes=204 --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY RUN"* ]]
}

@test "HERMETIC PROOF: the sensitive-path cases survive the runner's own environment" {
  # Sets the variable that broke them in CI (pipeline 1827) and asserts the
  # outcome is unchanged. Without this the unset above is an unproven claim —
  # and an unproven claim about hermeticity is exactly how these two cases came
  # to pass on a laptop and fail only where it mattered.
  export CI_MERGE_REQUEST_DIFF_BASE_SHA="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo deadbeef)"
  export CI_MERGE_REQUEST_TARGET_BRANCH_NAME=main
  _mr_json mergeable false
  echo '[{"new_path":".gitlab-ci.yml","old_path":".gitlab-ci.yml"}]' > "$STATE/diffs.json"
  run bash "$MR" merge 900
  [ "$status" -eq 1 ]
  [[ "$output" == *"sensitive-path gate"* ]]
  ! grep -q 'PUT .*/merge$' "$CURL_LOG"
}

################################################################################
# ci_must_pass — the D13 hold is RED BY DESIGN on its first run
################################################################################
#
# `security:mr-hold` runs on push. The release it demands binds to the head
# commit, so it can only be issued AFTER that pipeline has started. Every
# sensitive-path MR therefore lands in the same state: released, un-held, and
# unmergeable behind a job that failed for a reason that has since gone away.
# Observed on !317 (2026-08-03): release bound to the head, `pl mr` showing
# HELD=no, and `pl mr merge` refusing on ci_must_pass with security:mr-hold the
# only red job. Re-running it by hand is the "step around the verb" move this
# estate keeps paying for, so the verb does it — once, and only for that job.

@test "ci_must_pass with ONLY security:mr-hold red: re-run it once, then merge" {
  _mr_json ci_must_pass false
  _jobs_json "security:mr-hold:failed" "test:unit:success"
  _mr_json mergeable false "$STATE/after_retry.json"
  run bash "$MR" merge 900 --wait=30
  [ "$status" -eq 0 ]
  [ "$(grep -c '^POST .*/jobs/[0-9]*/retry$' "$CURL_LOG")" -eq 1 ]
  grep -q 'PUT .*/merge$' "$CURL_LOG"
}

@test "NEGATIVE CONTROL: any OTHER red job is a refusal — never 'retry until green'" {
  _mr_json ci_must_pass false
  _jobs_json "security:mr-hold:failed" "test:unit:failed"
  _mr_json mergeable false "$STATE/after_retry.json"
  run bash "$MR" merge 900 --wait=30
  [ "$status" -eq 1 ]
  [[ "$output" == *"test:unit"* ]]          # it NAMES what is red
  ! grep -q '^POST .*/retry$' "$CURL_LOG"
  ! grep -q 'PUT .*/merge$' "$CURL_LOG"
}

@test "NEGATIVE CONTROL: a hold job that stays red is retried EXACTLY once" {
  # Without the once-only flag this is an infinite loop against a gate that is
  # genuinely refusing — the same shape as the rebase bug this file already
  # pins by counting calls rather than reading stdout.
  _mr_json ci_must_pass false
  _jobs_json "security:mr-hold:failed"
  _mr_json ci_must_pass false "$STATE/after_retry.json"
  run bash "$MR" merge 900 --wait=30
  [ "$status" -eq 1 ]
  [ "$(grep -c '^POST .*/jobs/[0-9]*/retry$' "$CURL_LOG")" -eq 1 ]
  ! grep -q 'PUT .*/merge$' "$CURL_LOG"
}

@test "--dry-run reports ci_must_pass and re-runs NOTHING" {
  # A dry run reports; it does not act. Retrying a job is an action.
  _mr_json ci_must_pass false
  _jobs_json "security:mr-hold:failed"
  run bash "$MR" merge 900 --dry-run --wait=30
  [ "$status" -eq 1 ]
  [ ! -f "$CURL_LOG" ] || ! grep -q '^POST .*/retry$' "$CURL_LOG"
}

@test "the jobs reader does not spell a tab as yq's \"\\t\" — the runner's yq does not expand it" {
  # THE CI-ONLY FAILURE, made catchable on a workstation. ensure-yq.sh pins
  # v4.44.1 onto the runners; this machine has v4.50.1. Measured 2026-08-03
  # against the pinned binary itself:
  #     '(.id|tostring) + "\t" + .name'  ->  12\tsecurity:mr-hold   (two chars)
  #     '... + strenv(TAB) + ...'        ->  12<TAB>security:mr-hold
  # So `awk -F'\t'` split nothing, the failed-job name list came back empty,
  # and all three retry cases above passed here and failed in CI (pipeline
  # 1866). The behaviour cases cannot catch this — they run whatever yq the
  # machine has — so the assertion is on the SOURCE, where it is version-free.
  # Comments are stripped first: this very case, and the comment above the
  # fix, both name the bad spelling on purpose. A guard that its own
  # explanation satisfies is not a guard — the first cut of this case was
  # exactly that, and stayed green against the reintroduced defect.
  code="$(grep -v '^[[:space:]]*#' "$ROOT/lib/gitlab-mr.sh")"
  run grep -c '"\\\\t"' <<<"$code"
  [ "$output" = "0" ]
  run grep -c 'strenv(TAB)' <<<"$code"
  [ "$output" -ge 1 ]
}
