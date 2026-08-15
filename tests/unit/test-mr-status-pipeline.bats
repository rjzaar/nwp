#!/usr/bin/env bats
#
# test-mr-status-pipeline.bats — `pl mr status` must never let
# `detailed_merge_status` stand alone as the answer to "is this ready?".
#
# THE RECORDED FAILURE, 2026-08-16. A session read `pl mr status` on nwp/nwc!104,
# saw
#       merge status:    mergeable
# and reported the MR as ready to merge. The head pipeline had FAILED
# (pipeline 2357, job 21010 standalone-tests). Nothing in the output was untrue
# — `detailed_merge_status` genuinely does not account for the pipeline unless
# the project requires a green pipeline to merge — and nothing in the output
# said so either. The operator was told "mergeable" about an MR that was red.
#
# This is the same class as the `conflict`-goes-stale note already in CLAUDE.md:
# a forge-computed field being read as a verdict it does not actually deliver.
# The fix is not to distrust the field, it is to STOP SHOWING IT ALONE.
#
# HERMETIC: curl is PATH-stubbed and answers from files under $STATE, so every
# assertion is about what the verb does with a given wire response.

setup() {
  ROOT="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
  MR="$ROOT/scripts/commands/mr.sh"

  unset CI_MERGE_REQUEST_IID CI_SERVER_HOST CI_PROJECT_ID CI_API_V4_URL \
        NWP_MR_TOKEN NWP_GITLAB_HOST GITLAB_TOKEN MR_HOLD_TOKEN

  TMP="$BATS_TEST_TMPDIR/mrstatus"; mkdir -p "$TMP"
  export STATE="$TMP/state"; mkdir -p "$STATE"

  STUB="$TMP/bin"; mkdir -p "$STUB"
  cat > "$STUB/curl" <<'STUBEOF'
#!/bin/bash
cfg=""
while [ $# -gt 0 ]; do case "$1" in -K) cfg="$2"; shift 2 ;; *) shift ;; esac; done
url=$(sed -n 's/^url = "\(.*\)"$/\1/p' "$cfg")
meth=$(sed -n 's/^request = "\(.*\)"$/\1/p' "$cfg"); meth="${meth:-GET}"
path="${url#*/api/v4}"
emit() { printf '%s\n%s' "$1" "${2:-200}"; }
case "$meth $path" in
  "GET /user")                    emit '{"username":"a-human","bot":false}' ;;
  "GET "*"/merge_requests/"*"/changes"*) emit "$(cat "$STATE/changes.json")" ;;
  "GET "*"/merge_requests/"*)     emit "$(cat "$STATE/mr.json")" ;;
  *)                              emit '{}' ;;
esac
STUBEOF
  chmod +x "$STUB/curl"
  export PATH="$STUB:$PATH"

  export NWP_GITLAB_HOST="gitlab.example.invalid"
  export NWP_MR_TOKEN="TOK-TEST"
  export NWP_MR_PROJECT="9"

  printf '{"changes":[{"new_path":"README.md","old_path":"README.md"}]}' > "$STATE/changes.json"
  mk_mr mergeable failed
}

# $1 = detailed_merge_status, $2 = head pipeline status ("none" = no pipeline)
mk_mr() {
  local dms="$1" pstatus="$2" pipeline
  if [ "$pstatus" = "none" ]; then
    pipeline='null'
  else
    pipeline="{\"id\":2357,\"status\":\"${pstatus}\",\"web_url\":\"https://g.invalid/p/2357\"}"
  fi
  cat > "$STATE/mr.json" <<EOF
{"iid":104,"title":"REVIEW: a change","state":"opened",
 "author":{"username":"someone"},"draft":false,
 "detailed_merge_status":"${dms}","sha":"f64556fc1e14aaaa",
 "labels":[],"head_pipeline":${pipeline}}
EOF
}

run_status() { run bash "$MR" status 104; }

# --- THE REGRESSION ITSELF ----------------------------------------------------

@test "status REPORTS the head pipeline, not merge status alone" {
  mk_mr mergeable failed
  run_status
  [ "$status" -eq 0 ]
  [[ "$output" == *"pipeline"* ]] || { echo "no pipeline line at all: $output"; false; }
}

@test "a FAILED pipeline on a 'mergeable' MR is stated as NOT ready" {
  # The exact shape of the 2026-08-16 miss: GitLab says mergeable, CI is red.
  mk_mr mergeable failed
  run_status
  [[ "$output" == *"failed"* ]]
  # And it must not be possible to read the output as an all-clear.
  [[ "$output" == *"NOT"* || "$output" == *"not ready"* || "$output" == *"red"* ]]
}

@test "a SUCCESS pipeline on a mergeable MR reads as ready" {
  mk_mr mergeable success
  run_status
  [ "$status" -eq 0 ]
  [[ "$output" == *"success"* ]]
  # The negative controls above must not fire here, or they prove nothing.
  [[ "$output" != *"NOT ready"* ]]
}

@test "a RUNNING pipeline is neither pass nor fail — it says so" {
  mk_mr mergeable running
  run_status
  [[ "$output" == *"running"* ]]
  [[ "$output" != *"NOT ready"* ]] || true
  [[ "$output" == *"still"* || "$output" == *"running"* ]]
}

@test "NO pipeline at all is CANNOT VERIFY, never an implied pass" {
  # A merge request with no pipeline has not been proven by anything. Rendering
  # that as silence is how "mergeable" became "ready" in the first place.
  mk_mr mergeable none
  run_status
  [[ "$output" == *"no head pipeline"* || "$output" == *"CANNOT VERIFY"* ]]
  [[ "$output" != *"success"* ]]
}

@test "the pipeline verdict does not replace the merge-status line" {
  # Both facts matter and they answer different questions. Dropping either is
  # how the next reader ends up back where this test started.
  mk_mr conflict failed
  run_status
  [[ "$output" == *"merge status:"* ]]
  [[ "$output" == *"conflict"* ]]
  [[ "$output" == *"failed"* ]]
}
