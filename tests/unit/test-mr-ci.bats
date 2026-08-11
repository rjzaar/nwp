#!/usr/bin/env bats
#
# test-mr-ci.bats — `pl mr ci`, the verb that answers "why is #2254 red?".
#
# WHY THIS VERB HAS TESTS BEFORE IT HAS USERS. It was written on 2026-08-11 in
# the middle of a triage session that had just hand-rolled a curl loop against
# /pipelines and /jobs/:id/trace because no `pl` verb could read CI state — the
# third session to do so. The standing order says fix the verb, not the session,
# so the loop became this. Its whole value is that it is TRUSTED without being
# re-derived, which means each of its verdicts must be observable going wrong.
#
# HERMETIC: curl is PATH-stubbed and answers from files under $STATE, so every
# assertion below is about what the verb does with a given wire response, not
# about any live forge.

setup() {
  ROOT="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
  MR="$ROOT/scripts/commands/mr.sh"

  # An MR pipeline exports these; a test that reads the runner's environment is
  # testing the environment (test-mr-hold.bats, test-mr-merge.bats).
  unset CI_MERGE_REQUEST_IID CI_SERVER_HOST CI_PROJECT_ID CI_API_V4_URL \
        NWP_MR_TOKEN NWP_GITLAB_HOST GITLAB_TOKEN MR_HOLD_TOKEN

  TMP="$BATS_TEST_TMPDIR/mrci"; mkdir -p "$TMP"
  export STATE="$TMP/state"; mkdir -p "$STATE"
  export CURL_LOG="$TMP/curl.log"; : > "$CURL_LOG"

  STUB="$TMP/bin"; mkdir -p "$STUB"
  cat > "$STUB/curl" <<'STUBEOF'
#!/bin/bash
cfg=""
while [ $# -gt 0 ]; do case "$1" in -K) cfg="$2"; shift 2 ;; *) shift ;; esac; done
url=$(sed -n 's/^url = "\(.*\)"$/\1/p' "$cfg")
meth=$(sed -n 's/^request = "\(.*\)"$/\1/p' "$cfg"); meth="${meth:-GET}"
path="${url#*/api/v4}"
echo "$meth $path" >> "$CURL_LOG"
emit() { printf '%s\n%s' "$1" "${2:-200}"; }
case "$meth $path" in
  "GET /user")                      emit '{"username":"a-human","bot":false}' ;;
  "GET "*"/pipelines/"*"/jobs"*)    emit "$(cat "$STATE/jobs.json")" ;;
  "GET "*"/jobs/"*"/trace")         emit "$(cat "$STATE/trace.txt" 2>/dev/null)" ;;
  "GET "*"/pipelines/"*)            emit "$(cat "$STATE/pipeline.json")" ;;
  "GET "*"/merge_requests/"*)       emit "$(cat "$STATE/mr.json" 2>/dev/null || echo '{}')" ;;
  *)                                emit '{}' ;;
esac
STUBEOF
  chmod +x "$STUB/curl"
  export PATH="$STUB:$PATH"

  export NWP_GITLAB_HOST="gitlab.example.invalid"
  export NWP_MR_TOKEN="TOK-TEST"
  export NWP_MR_PROJECT="9"

  mk_pipeline failed
  mk_jobs_green
}

# $1 = status, $2 = ref (defaults to a merge-request ref for iid 437)
mk_pipeline() {
  cat > "$STATE/pipeline.json" <<EOF
{"id":2254,"status":"$1","sha":"c5a821c9152c05e6c0ad0d25ae9b8280ddfd5eef",
 "ref":"${2:-refs/merge-requests/437/head}",
 "web_url":"https://gitlab.example.invalid/nwp/nwp/-/pipelines/2254"}
EOF
}

mk_jobs_green() {
  cat > "$STATE/jobs.json" <<'EOF'
[{"id":19437,"status":"success","stage":"lint","name":"lint:bash","allow_failure":false},
 {"id":19450,"status":"success","stage":"test","name":"test:unit","allow_failure":false}]
EOF
}

mk_jobs_one_failed() {
  cat > "$STATE/jobs.json" <<'EOF'
[{"id":19437,"status":"success","stage":"lint","name":"lint:bash","allow_failure":false},
 {"id":19444,"status":"failed","stage":"lint","name":"lint:doc-truth","allow_failure":false},
 {"id":19450,"status":"skipped","stage":"test","name":"test:unit","allow_failure":false},
 {"id":19456,"status":"failed","stage":"preview","name":"cleanup:preview","allow_failure":true}]
EOF
}

# ── 1. the number → branch mapping that did not exist ─────────────────────────
#
# A failure is reported as a NUMBER. If the verb cannot answer "which MR is
# that?", the session goes back to hand-rolling curl, which is what it is here
# to stop.
@test "a bare pipeline number names the merge request it belongs to" {
  run bash "$MR" ci --pipeline=2254 --no-log
  [[ "$output" == *"pipeline #2254"* ]]
  [[ "$output" == *"merge request:"*"!437"* ]]
}

@test "a BRANCH pipeline reports its ref and claims no merge request" {
  mk_pipeline failed "main"
  mk_jobs_one_failed
  run bash "$MR" ci --pipeline=2254 --no-log
  [[ "$output" == *"main"* ]]
  # The absence must be silence, not a wrong MR number.
  [[ "$output" != *"merge request:"* ]]
}

# ── 2. the verdicts, each observed ────────────────────────────────────────────

@test "a green pipeline exits 0" {
  mk_pipeline success
  run bash "$MR" ci --pipeline=2254 --no-log
  [ "$status" -eq 0 ]
  [[ "$output" == *"succeeded"* ]]
}

@test "a failed pipeline exits 1 and counts only the BLOCKING jobs" {
  mk_jobs_one_failed
  run bash "$MR" ci --pipeline=2254 --no-log
  [ "$status" -eq 1 ]
  # Two jobs are `failed`; one is allow_failure and does not block a merge.
  [[ "$output" == *"1 blocking job(s)"* ]] || [[ "$output" == *"FAILED — 1 "* ]]
  [[ "$output" == *"allow_failure"* ]]
}

@test "a RUNNING pipeline is exit 3 — not a pass and not a failure" {
  mk_pipeline running
  run bash "$MR" ci --pipeline=2254 --no-log
  [ "$status" -eq 3 ]
  [[ "$output" == *"not a verdict yet"* ]]
}

@test "a CANCELED pipeline is CANNOT VERIFY (exit 2), never a pass" {
  mk_pipeline canceled
  run bash "$MR" ci --pipeline=2254 --no-log
  [ "$status" -eq 2 ]
  [[ "$output" == *"CANNOT VERIFY"* ]]
}

# ── 3. fail-closed, the estate rule ───────────────────────────────────────────

@test "an EMPTY job list is CANNOT VERIFY, not a clean pipeline" {
  mk_pipeline success
  echo '[]' > "$STATE/jobs.json"
  run bash "$MR" ci --pipeline=2254 --no-log
  [ "$status" -eq 2 ]
  [[ "$output" == *"not a clean pipeline"* ]]
}

@test "an MR with NO head pipeline is CANNOT VERIFY, not a green tick" {
  echo '{"iid":438,"state":"opened","title":"x","sha":"deadbeef","head_pipeline":null}' \
    > "$STATE/mr.json"
  run bash "$MR" ci 438 --no-log
  [ "$status" -eq 2 ]
  [[ "$output" == *"absence of one"* ]]
}

# ── 4. the log is the point ───────────────────────────────────────────────────

@test "the tail of a FAILED job's log is printed, ANSI and section markers stripped" {
  mk_jobs_one_failed
  printf '%b' 'section_start:1786480979:step_script\n\x1b[0;31mERROR: [dead-command-ref] docs/x.md → ./run_redproof.sh\x1b[0m\nERROR: Job failed: exit status 1\n' \
    > "$STATE/trace.txt"
  run bash "$MR" ci --pipeline=2254 --log=10
  [ "$status" -eq 1 ]
  [[ "$output" == *"dead-command-ref"* ]]
  [[ "$output" == *"job 19444 (lint:doc-truth)"* ]]
  # stripped, not merely present
  [[ "$output" != *"section_start"* ]]
  [[ "$output" != *$'\x1b['* ]]
}

@test "an allow_failure job's log is NOT fetched — it did not block anything" {
  mk_jobs_one_failed
  : > "$CURL_LOG"
  printf 'irrelevant\n' > "$STATE/trace.txt"
  run bash "$MR" ci --pipeline=2254 --log=10
  grep -q '/jobs/19444/trace' "$CURL_LOG"
  ! grep -q '/jobs/19456/trace' "$CURL_LOG"
}

# ── 5. what it must NOT do ────────────────────────────────────────────────────
#
# "A retry that goes green is not a diagnosis." A read verb that quietly retries
# would manufacture exactly the habit CLAUDE.md records as the reason a red
# pipeline is the weaker half of the D13 hold.
@test "NEVER retries: no POST reaches the wire, even on a red pipeline" {
  mk_jobs_one_failed
  : > "$CURL_LOG"
  run bash "$MR" ci --pipeline=2254 --log=5
  [ "$status" -eq 1 ]
  ! grep -q '^POST ' "$CURL_LOG"
  ! grep -q '^PUT ' "$CURL_LOG"
  ! grep -qi 'retry' "$CURL_LOG"
}

# ── 6. argument hygiene — assert the MESSAGE, never a bare non-zero ──────────

@test "a non-numeric pipeline id is refused by name" {
  run bash "$MR" ci --pipeline=abc --no-log
  [ "$status" -ne 0 ]
  [[ "$output" == *"numeric id"* ]]
}

@test "no argument at all prints the usage rather than guessing" {
  run bash "$MR" ci
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage: pl mr ci"* ]]
}

@test "an unknown flag is refused, and says which one" {
  run bash "$MR" ci --pipeline=2254 --retry-until-green
  [ "$status" -ne 0 ]
  [[ "$output" == *"--retry-until-green"* ]]
}

@test "mr.sh parses (bash -n) and pl dispatches the verb" {
  run bash -n "$MR"
  [ "$status" -eq 0 ]
  run grep -qE '^\s+ci\)\s+cmd_ci' "$MR"
  [ "$status" -eq 0 ]
}
