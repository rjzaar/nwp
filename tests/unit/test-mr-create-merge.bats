#!/usr/bin/env bats
#
# test-mr-create-merge.bats — ops#216: `pl mr create` / `pl mr merge`.
#
# WHY THE VERB EXISTS. On 2026-08-01/02 thirty-plus merge requests were created
# and merged with raw curl. It kept tokens out of argv, and it still violated
# the pl-first standing order — and, more concretely, it meant the hard-won
# merge-status knowledge had nowhere to live. Three preconditions were
# re-invented (or missed) that night:
#
#   * a branch committed but never pushed → the MR reviewed a stale remote head
#   * a second MR opened for a branch that already had one
#   * a description with no `Closes nwp/ops#N` → the tracker learnt nothing
#
# and two facts about THIS instance:
#
#   * `detailed_merge_status` goes STALE and says `conflict` about branches that
#     merge cleanly. `PUT /rebase` forces a recompute; `checking` means retry.
#   * a rebase pushes a new head, which CANCELS the running pipeline. A loop
#     that rebases every round destroys the work it is waiting for — ten
#     cancelled pipelines on a single MR (report §11.11). Hence: AT MOST ONE
#     rebase per run, asserted here by COUNTING the rebase calls.
#
# HERMETIC: curl is PATH-stubbed and every call is logged, so "did not merge"
# and "rebased exactly once" are positive assertions about the wire, not
# inferences from stdout. The CI environment is scrubbed for the same reason
# test-mr-hold.bats scrubs it: an MR pipeline exports CI_MERGE_REQUEST_IID /
# CI_SERVER_HOST / CI_PROJECT_ID / NWP_MR_TOKEN, and a test that reads those
# passes locally and fails only on the runner.

setup() {
  ROOT="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
  MR="$ROOT/scripts/commands/mr.sh"
  unset CI_MERGE_REQUEST_IID CI_MERGE_REQUEST_TARGET_BRANCH_NAME \
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
 "author":{"username":"someone"},"labels":[],"merge_when_pipeline_succeeds":false}
EOF
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

@test "REFUSES an unpushed branch — the MR would review code nobody sent" {
  _branch feat/unpushed "feat: x" "body" nopush
  run _run_in_repo create --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"has never been pushed"* ]]
  [ ! -f "$CURL_LOG" ]                  # refused before any API call
}

@test "REFUSES a branch that differs from its remote, and says both shas" {
  _branch feat/ahead
  echo more >> "$REPO/f.txt"; git -C "$REPO" commit -qam "local only"
  run _run_in_repo create --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"differs from origin/feat/ahead"* ]]
  # The message must name the MISMATCH, not the missing-branch case: an earlier
  # draft used bare `git rev-parse`, which ECHOES its argument for an unknown
  # ref, so an unpushed branch was reported as a mismatch against the literal
  # string "origin/<branch>". Right refusal, wrong reason.
  [[ "$output" != *"has never been pushed"* ]]
}

@test "REFUSES source == target" {
  run _run_in_repo create --source=main --target=main --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"both 'main'"* ]]
}

@test "REFUSES a duplicate and points at the existing MR" {
  _branch feat/dup
  echo '[{"iid":42,"state":"opened"}]' > "$STATE/existing.json"
  run _run_in_repo create
  [ "$status" -eq 1 ]
  [[ "$output" == *"!42 is already open"* ]]
  ! grep -q '^POST ' "$CURL_LOG"        # positively: nothing was created
}

@test "PASSES: a pushed, unduplicated branch is created and the iid is printed" {
  _branch feat/good
  _mr_json mergeable false
  run _run_in_repo create
  [ "$status" -eq 0 ]
  [[ "$output" == *"!900 created"* ]]
  grep -q '^POST .*/merge_requests$' "$CURL_LOG"
}

@test "title and body default to the head commit — one copy of the reasoning" {
  _branch feat/desc "fix(x): the real subject" "the reasoning that must not be retyped"
  run _run_in_repo create --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"fix(x): the real subject"* ]]
  [[ "$output" == *"the reasoning that must not be retyped"* ]]
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

@test "an unknown flag is REFUSED, not swallowed as a positional" {
  _branch feat/flag
  run _run_in_repo create --tittle=oops
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown option"* ]]
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
