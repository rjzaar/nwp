#!/usr/bin/env bats
#
# test-mr-ready.bats — `pl mr ready`, the queue readiness gate (ops#383).
#
# WHY THIS VERB HAS TESTS THAT ARE HARD TO SATISFY. Its whole value is that the
# operator trusts it INSTEAD of clicking: a READY it did not earn costs exactly
# the thing it was built to save. So every verdict here is driven from a stubbed
# wire response AND a REAL git fixture — origin bare repo, real branches, real
# conflicting bytes — because the central claim of the verb is that a `conflict`
# is settled by reproduction rather than by the forge's cached word, and a test
# that stubs the reproduction would be testing the stub.
#
# HERMETIC: curl is PATH-stubbed and answers from files under $STATE; git talks
# to a bare repo under $BATS_TEST_TMPDIR. Nothing here reaches a live forge.

setup() {
  ROOT="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
  MR="$ROOT/scripts/commands/mr.sh"

  unset CI_MERGE_REQUEST_IID CI_SERVER_HOST CI_PROJECT_ID CI_API_V4_URL \
        NWP_MR_TOKEN NWP_GITLAB_HOST GITLAB_TOKEN MR_HOLD_TOKEN NWP_REVIEW_MODE

  TMP="$BATS_TEST_TMPDIR/mrready"; mkdir -p "$TMP"
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
# A per-endpoint HTTP status override, so "the API is unreachable" is a state a
# test can put the world in rather than a branch it has to trust.
down() { [ -f "$STATE/down-$1" ] && cat "$STATE/down-$1"; }
case "$meth $path" in
  "GET /user")                    emit '{"username":"a-human","bot":false}' ;;
  "GET "*"/merge_requests?"*)     s=$(down list);   emit "$(cat "$STATE/list.json" 2>/dev/null || echo '[]')" "${s:-200}" ;;
  "GET "*"/pipelines/"*"/jobs"*)  s=$(down jobs);   emit "$(cat "$STATE/jobs.json" 2>/dev/null || echo '[]')" "${s:-200}" ;;
  "GET "*"/pipelines/"*)          s=$(down pipe);   emit "$(cat "$STATE/pipeline.json" 2>/dev/null || echo '{}')" "${s:-200}" ;;
  "GET "*"/merge_requests/"*"/diffs"*)   s=$(down diffs);   emit "$(cat "$STATE/diffs.json" 2>/dev/null || echo '[]')" "${s:-200}" ;;
  "GET "*"/merge_requests/"*"/commits"*) s=$(down commits); emit "$(cat "$STATE/commits.json" 2>/dev/null || echo '[]')" "${s:-200}" ;;
  "GET "*"/merge_requests/"*"/notes"*)   s=$(down notes);   emit "$(cat "$STATE/notes.json" 2>/dev/null || echo '[]')" "${s:-200}" ;;
  "GET "*"/merge_requests/"*)     s=$(down mr);     emit "$(cat "$STATE/mr.json" 2>/dev/null || echo '{}')" "${s:-200}" ;;
  *)                              emit '{}' ;;
esac
STUBEOF
  chmod +x "$STUB/curl"
  export PATH="$STUB:$PATH"

  export NWP_GITLAB_HOST="gitlab.example.invalid"
  export NWP_MR_TOKEN="TOK-TEST"
  export NWP_MR_PROJECT="9"
  export NWP_REVIEW_MODE="solo"

  mk_repo
  mk_pipeline success "$SHA_CLEAN"
  mk_jobs_green
  : > "$STATE/diffs.json"; echo '[]' > "$STATE/diffs.json"
  echo '[]' > "$STATE/commits.json"
  echo '[]' > "$STATE/notes.json"
  mk_mr
}

# ── A REAL REPOSITORY, because a reproduced conflict must reproduce ───────────
#
# main advances after both branches are cut, so `feat-clean` is genuinely BEHIND
# its target (the situation in which this instance's cached merge status goes
# stale) and `feat-conflict` genuinely collides on the same line.
mk_repo() {
  ORIGIN="$TMP/origin.git"; WORK="$TMP/work"
  git init -q --bare "$ORIGIN"
  git init -q "$WORK"
  cd "$WORK" || return 1
  git config user.email t@example.invalid; git config user.name T
  git config commit.gpgsign false
  printf 'one\n' > a.txt; git add a.txt; git commit -qm base
  git remote add origin "$ORIGIN"; git push -q -u origin HEAD:main

  git checkout -q -b feat-clean
  printf 'b\n' > b.txt; git add b.txt; git commit -qm "feat: add b"
  git push -q origin feat-clean
  SHA_CLEAN=$(git rev-parse HEAD)

  git checkout -q main 2>/dev/null || git checkout -q -B main origin/main
  git checkout -q -b feat-conflict origin/main
  printf 'two\n' > a.txt; git add a.txt; git commit -qm "feat: a becomes two"
  git push -q origin feat-conflict
  SHA_CONFLICT=$(git rev-parse HEAD)

  git checkout -q -B main origin/main
  printf 'three\n' > a.txt; printf 'c\n' > c.txt
  git add a.txt c.txt; git commit -qm "main moves on"
  git push -q origin main
  export SHA_CLEAN SHA_CONFLICT WORK
}

# mk_mr [key=value ...] — the MR object. Defaults are a clean, green, open MR.
#
# Built with python3, NOT a heredoc. The first cut interpolated the title
# straight into JSON, so the test written to prove that a title containing a
# double quote survives the verb was itself producing invalid JSON — the fixture
# failing in the shape of the thing under test. A fixture that cannot express
# the hostile input cannot test for it.
mk_mr() {
  local kv
  local -a args=()
  for kv in "$@"; do args+=("$kv"); done
  SHA_CLEAN="$SHA_CLEAN" python3 - "$STATE" "${args[@]+"${args[@]}"}" <<'PYEOF'
import json, os, sys
state = sys.argv[1]
f = {"iid": "469", "dms": "unchecked", "src": "feat-clean",
     "sha": os.environ["SHA_CLEAN"], "draft": "false", "labels": "[]",
     "mwps": "false", "pid": "2254", "psha": os.environ["SHA_CLEAN"],
     "title": "feat(server): pl server vhost --create", "author": "a-human"}
for kv in sys.argv[2:]:
    k, _, v = kv.partition("=")
    if k in f: f[k] = v
mr = {"iid": int(f["iid"]), "title": f["title"], "state": "opened",
      "draft": f["draft"] == "true", "work_in_progress": f["draft"] == "true",
      "labels": json.loads(f["labels"]),
      "merge_when_pipeline_succeeds": f["mwps"] == "true",
      "detailed_merge_status": f["dms"], "sha": f["sha"],
      "source_branch": f["src"], "target_branch": "main",
      "author": {"username": f["author"]},
      "head_pipeline": None if f["pid"] == "none" else
          {"id": int(f["pid"]), "sha": f["psha"], "status": "success"}}
json.dump(mr, open(os.path.join(state, "mr.json"), "w"))
json.dump([mr], open(os.path.join(state, "list.json"), "w"))
PYEOF
}

mk_pipeline() { cat > "$STATE/pipeline.json" <<EOF
{"id":2254,"status":"$1","sha":"$2","ref":"refs/merge-requests/469/head"}
EOF
}
mk_jobs_green() { cat > "$STATE/jobs.json" <<'EOF'
[{"id":1,"status":"success","stage":"lint","name":"lint:bash","allow_failure":false}]
EOF
}
mk_jobs_failed() { cat > "$STATE/jobs.json" <<'EOF'
[{"id":1,"status":"success","stage":"lint","name":"lint:bash","allow_failure":false},
 {"id":2,"status":"failed","stage":"lint","name":"lint:doc-truth","allow_failure":false},
 {"id":3,"status":"failed","stage":"preview","name":"cleanup:preview","allow_failure":true}]
EOF
}
mk_sensitive_diff() { cat > "$STATE/diffs.json" <<'EOF'
[{"new_path":".gitlab-ci.yml","old_path":".gitlab-ci.yml"}]
EOF
}
mk_plain_diff() { cat > "$STATE/diffs.json" <<'EOF'
[{"new_path":"lib/gitlab-mr.sh","old_path":"lib/gitlab-mr.sh"}]
EOF
}

ready() { cd "$WORK" && run bash "$MR" ready "$@"; }

# verdict_line — the ONE line that carries !469's verdict word.
#
# Asserting `[[ "$output" != *BLOCKED* ]]` on the whole output is a check that
# cannot pass: the summary footer always prints "N BLOCKED". Two tests were
# written that way and both failed for that reason and not for any reason about
# the verb — an assertion loose enough to be wrong about its own subject.
verdict_line() { printf '%s\n' "$output" | grep -- '!469' | head -1; }

# ── 1. THE HEADLINE CLAIM: a stale `conflict` is not a conflict ───────────────
#
# CLAUDE.md, verified 2026-08-02: this instance reports detailed_merge_status
# `conflict` for branches that merge cleanly, because the value is cached and is
# not recomputed when the target branch moves. `feat-clean` here IS behind main
# and DOES merge cleanly. A verb that believed the forge would refuse the one MR
# in the queue that is actually ready.
@test "a STALE 'conflict' is settled by a real test-merge and the MR is READY" {
  mk_mr dms=conflict
  mk_plain_diff
  ready 469
  [ "$status" -eq 0 ]
  [[ "$(verdict_line)" == *"READY"* ]]
  [[ "$(verdict_line)" != *"BLOCKED"* ]]
  [[ "$output" == *"stale-merge-cache"* ]]
}

@test "the stale-cache advisory names the reproduction, not an opinion" {
  mk_mr dms=conflict
  mk_plain_diff
  ready 469 --json
  [ "$status" -eq 0 ]
  local rep
  rep=$(printf '%s' "$output" | python3 -c 'import json,sys;d=json.load(sys.stdin);m=d["merge_requests"][0];print(m["checks"]["merge_status"]["reproduced"], m["checks"]["merge_status"]["method"], m["checks"]["merge_status"]["forge_value"])')
  [ "$rep" = "clean local-test-merge conflict" ]
}

# ── 2. A REPRODUCED conflict IS a conflict, and it names the file ────────────
@test "a REPRODUCED conflict is BLOCKED and names the conflicted path" {
  mk_mr src=feat-conflict sha="$SHA_CONFLICT" psha="$SHA_CONFLICT" dms=mergeable
  mk_pipeline success "$SHA_CONFLICT"
  mk_plain_diff
  ready 469
  [ "$status" -eq 1 ]
  [[ "$output" == *"BLOCKED"* ]]
  [[ "$output" == *"conflict"* ]]
  [[ "$output" == *"a.txt"* ]]
}

# A conflict reproduced against a forge that says `mergeable` is the cache going
# stale in the OTHER direction. The reproduction outranks the cached word in both
# directions or it is not a reproduction, it is a tie-breaker.
@test "'mergeable' does not overrule a reproduced conflict" {
  mk_mr src=feat-conflict sha="$SHA_CONFLICT" psha="$SHA_CONFLICT" dms=mergeable
  mk_pipeline success "$SHA_CONFLICT"
  mk_plain_diff
  ready 469 --json
  local v
  v=$(printf '%s' "$output" | python3 -c 'import json,sys;print(json.load(sys.stdin)["merge_requests"][0]["checks"]["merge_status"]["verdict"])')
  [ "$v" = "blocked" ]
}

# ── 3. THE API IS UNREACHABLE — "I could not look" is not "nothing is wrong" ──
@test "an unreachable API is CANNOT-VERIFY and exit 2, never READY" {
  echo "000" > "$STATE/down-mr"
  ready 469
  [ "$status" -eq 2 ]
  [[ "$(verdict_line)" == *"CANNOT-VERIFY"* ]]
  [[ "$(verdict_line)" != *"READY"* ]]
  [[ "$output" == *"could not look"* ]]
}

@test "a 401 on the MR read is CANNOT-VERIFY, not a policy verdict" {
  echo "401" > "$STATE/down-mr"
  ready 469 --json
  [ "$status" -eq 2 ]
  [[ "$output" == *'"cause": "api-unreadable"'* ]]
}

@test "a 404 is a DEFINITE negative — BLOCKED no-such-mr, not CANNOT-VERIFY" {
  echo "404" > "$STATE/down-mr"
  ready 469 --json
  [ "$status" -eq 1 ]
  [[ "$output" == *'"cause": "no-such-mr"'* ]]
}

@test "an unreadable OPEN-MR LIST is CANNOT-VERIFY, not an empty queue" {
  echo "500" > "$STATE/down-list"
  ready
  [ "$status" -eq 2 ]
  [[ "$output" == *"not an empty queue"* ]]
}

# ── 4. A GREEN PIPELINE ON A SUPERSEDED COMMIT IS NOT READINESS ──────────────
@test "a SUCCESS pipeline on an older sha is BLOCKED, not READY" {
  mk_mr psha="0000000000000000000000000000000000000000"
  mk_pipeline success "0000000000000000000000000000000000000000"
  mk_plain_diff
  ready 469
  [ "$status" -eq 1 ]
  [[ "$(verdict_line)" == *"BLOCKED"* ]]
  [[ "$(verdict_line)" != *"READY"* ]]
  [[ "$output" == *"pipeline-superseded"* ]]
  [[ "$output" == *"superseded bytes"* ]]
}

@test "the superseded verdict names BOTH shas so the operator can see the gap" {
  mk_mr psha="0000000000000000000000000000000000000000"
  mk_pipeline success "0000000000000000000000000000000000000000"
  mk_plain_diff
  ready 469
  [[ "$output" == *"000000000000"* ]]
  [[ "$output" == *"${SHA_CLEAN:0:12}"* ]]
}

@test "on_head_sha is false in the JSON when the run is superseded" {
  mk_mr psha="0000000000000000000000000000000000000000"
  mk_pipeline success "0000000000000000000000000000000000000000"
  mk_plain_diff
  ready 469 --json
  local v
  v=$(printf '%s' "$output" | python3 -c 'import json,sys;print(json.load(sys.stdin)["merge_requests"][0]["checks"]["pipeline"]["on_head_sha"])')
  [ "$v" = "False" ]
}

# ── 5. THE REST OF THE PIPELINE VERDICTS ────────────────────────────────────
@test "a FAILED pipeline names the blocking job and ignores allow_failure ones" {
  mk_pipeline failed "$SHA_CLEAN"
  mk_jobs_failed
  mk_plain_diff
  ready 469
  [ "$status" -eq 1 ]
  [[ "$output" == *"ci-failed"* ]]
  [[ "$output" == *"lint:doc-truth"* ]]
  [[ "$output" != *"cleanup:preview"* ]]
}

@test "a RUNNING pipeline is BLOCKED — not a pass and not a failure" {
  mk_pipeline running "$SHA_CLEAN"
  mk_plain_diff
  ready 469
  [ "$status" -eq 1 ]
  [[ "$output" == *"ci-running"* ]]
}

@test "a CANCELED pipeline is BLOCKED — a cancelled run is not a green one" {
  mk_pipeline canceled "$SHA_CLEAN"
  mk_plain_diff
  ready 469
  [ "$status" -eq 1 ]
  [[ "$output" == *"ci-canceled"* ]]
}

@test "an UNRECOGNISED pipeline status is CANNOT-VERIFY, never a pass" {
  mk_pipeline wibble "$SHA_CLEAN"
  mk_plain_diff
  ready 469
  [ "$status" -eq 2 ]
  [[ "$output" == *"ci-status-unknown"* ]]
}

@test "no pipeline at all is BLOCKED, not READY" {
  mk_mr pid=none
  mk_plain_diff
  ready 469
  [ "$status" -eq 1 ]
  [[ "$output" == *"no-pipeline"* ]]
}

@test "an unreadable pipeline is CANNOT-VERIFY, not green" {
  echo "500" > "$STATE/down-pipe"
  mk_plain_diff
  ready 469
  [ "$status" -eq 2 ]
  [[ "$output" == *"pipeline-unreadable"* ]]
}

# ── 6. DRAFT AND HOLD, INCLUDING STALENESS ──────────────────────────────────
@test "an author's Draft is BLOCKED and is not called a guard hold" {
  mk_mr draft=true
  mk_plain_diff
  ready 469
  [ "$status" -eq 1 ]
  [[ "$output" == *"- draft"* ]]
  [[ "$output" != *"held-stale"* ]]
}

@test "a Draft + hold:: label whose condition no longer obtains is held-STALE" {
  # Solo review mode owes no release, and the diff touches nothing sensitive:
  # the hold has nothing left behind it.
  mk_mr draft=true 'labels=["hold::sensitive-path"]'
  mk_plain_diff
  ready 469
  [ "$status" -eq 1 ]
  [[ "$output" == *"held-stale"* ]]
  [[ "$output" == *"NO LONGER OBTAINS"* ]]
}

@test "a hold whose condition DOES still obtain is held, not held-stale" {
  export NWP_REVIEW_MODE=team
  mk_mr draft=true 'labels=["hold::sensitive-path"]' title="REVIEW: touch ci"
  mk_sensitive_diff
  ready 469
  [ "$status" -eq 1 ]
  [[ "$output" == *"- held"* ]]
  [[ "$output" != *"held-stale"* ]]
}

@test "a hold:: label without Draft is still BLOCKED — guard re-applies it" {
  mk_mr 'labels=["hold::manual"]'
  mk_plain_diff
  ready 469
  [ "$status" -eq 1 ]
  [[ "$output" == *"re-applies the Draft"* ]]
}

# ── 7. THE REVIEW: MARKER — the red pipeline you can predict ─────────────────
@test "a sensitive-path MR with no REVIEW: marker is BLOCKED before the click" {
  mk_sensitive_diff
  ready 469
  [ "$status" -eq 1 ]
  [[ "$output" == *"review-marker-missing"* ]]
  [[ "$output" == *".gitlab-ci.yml"* ]] || [[ "$output" == *"sensitive path"* ]]
}

@test "a REVIEW: marker in the TITLE clears the marker check" {
  mk_mr title="REVIEW: fix(ci): tighten the gate"
  mk_sensitive_diff
  ready 469
  [ "$status" -eq 0 ]
  [[ "$output" == *"READY"* ]]
}

@test "a REVIEW: marker in a COMMIT SUBJECT clears it too" {
  mk_sensitive_diff
  cat > "$STATE/commits.json" <<'EOF'
[{"id":"aaa","title":"chore: tidy","message":"chore: tidy\n"},
 {"id":"bbb","title":"REVIEW: fix(ci): tighten","message":"REVIEW: fix(ci): tighten\n\nbody\n"}]
EOF
  ready 469
  [ "$status" -eq 0 ]
  [[ "$output" == *"READY"* ]]
}

@test "an unreadable commit list on a sensitive MR is CANNOT-VERIFY" {
  mk_sensitive_diff
  echo "500" > "$STATE/down-commits"
  ready 469
  [ "$status" -eq 2 ]
  [[ "$output" == *"commits-unreadable"* ]]
}

@test "an unreadable diff is CANNOT-VERIFY — never 'nothing sensitive'" {
  echo "500" > "$STATE/down-diffs"
  ready 469
  [ "$status" -eq 2 ]
  [[ "$output" == *"diff-unreadable"* ]]
  [[ "$(verdict_line)" != *"READY"* ]]
}

# ── 8. REVIEW MODE, AND WHAT IT OWES ────────────────────────────────────────
@test "team mode owes a release record on a sensitive MR" {
  export NWP_REVIEW_MODE=team
  mk_mr title="REVIEW: fix(ci): tighten the gate"
  mk_sensitive_diff
  ready 469
  [ "$status" -eq 1 ]
  [[ "$output" == *"release-record-missing"* ]]
}

@test "solo mode owes nothing but the click" {
  mk_mr title="REVIEW: fix(ci): tighten the gate"
  mk_sensitive_diff
  ready 469 --json
  [ "$status" -eq 0 ]
  [[ "$output" == *"IS the approval"* ]]
}

@test "a review mode that could not be READ is CANNOT-VERIFY, never solo" {
  unset NWP_REVIEW_MODE
  export NWP_SECRETS_REGISTRY="$TMP/no-such-registry.yml"
  export NWP_REVIEW_MODE_FILE="$TMP/no-such-projection"
  mk_plain_diff
  ready 469
  [ "$status" -eq 2 ]
  [[ "$output" == *"review-mode-not-declared"* ]]
}

@test "unreadable notes in team mode is CANNOT-VERIFY, not 'no release exists'" {
  export NWP_REVIEW_MODE=team
  mk_mr title="REVIEW: fix(ci): tighten the gate"
  mk_sensitive_diff
  echo "500" > "$STATE/down-notes"
  ready 469
  [ "$status" -eq 2 ]
  [[ "$output" == *"notes-unreadable"* ]]
}

# ── 9. THE OPS#361 PROPERTY: a truthful exit from every blocker ──────────────
#
# "A required field that can only be satisfied by fabricating a human act is a
# design defect, not a workflow." Two agents recorded approvals nobody gave in
# order to clear a stale hold. Nothing this verb prints may point that way.
@test "EVERY blocker carries a recheck, and no recheck asks for an attestation" {
  local case_setup
  for case_setup in plain sensitive draft superseded failed; do
    case "$case_setup" in
      plain)      mk_mr dms=conflict; mk_plain_diff ;;
      sensitive)  mk_mr; mk_sensitive_diff ;;
      draft)      mk_mr draft=true 'labels=["hold::manual"]'; mk_plain_diff ;;
      superseded) mk_mr psha=0000000000000000000000000000000000000000
                  mk_pipeline success 0000000000000000000000000000000000000000
                  mk_plain_diff ;;
      failed)     mk_pipeline failed "$SHA_CLEAN"; mk_jobs_failed; mk_plain_diff ;;
    esac
    ready 469 --json
    printf '%s' "$output" | python3 -c '
import json,sys
d=json.load(sys.stdin)
for m in d["merge_requests"]:
    for b in m["blockers"]:
        assert b.get("recheck"), "blocker %s has no recheck" % b["cause"]
        assert "--approved-by" not in b["recheck"], b["cause"]
        assert "approved-by" not in b["recheck"], b["cause"]
' || {
      echo "FAILED for case: $case_setup"
      echo "$output"
      return 1
    }
  done
}

# ── 10. THE JSON CONTRACT the console pane consumes ─────────────────────────
@test "--json emits the versioned schema and a well-formed document" {
  mk_plain_diff
  ready 469 --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert d["schema"]=="nwp.mr.ready/1", d["schema"]
for k in ("generated","project","review_mode","review_mode_source","exit","counts","merge_requests"):
    assert k in d, k
for k in ("ready","blocked","cannot_verify","total"):
    assert isinstance(d["counts"][k], int), k
m=d["merge_requests"][0]
for k in ("iid","title","author","state","source_branch","target_branch",
          "head_sha","url","verdict","blockers","advisories","checks"):
    assert k in m, k
assert isinstance(m["iid"], int)
for k in ("merge_status","pipeline","hold","review_marker","review_mode"):
    assert k in m["checks"], k
    assert m["checks"][k]["verdict"] in ("ok","blocked","cannot-verify"), k
'
}

@test "the JSON's own exit field equals the process exit code" {
  mk_pipeline failed "$SHA_CLEAN"; mk_jobs_failed; mk_plain_diff
  ready 469 --json
  [ "$status" -eq 1 ]
  local e
  e=$(printf '%s' "$output" | python3 -c 'import json,sys;print(json.load(sys.stdin)["exit"])')
  [ "$e" -eq "$status" ]
}

@test "a title containing a double quote does not break the JSON" {
  mk_mr 'title=fix: the "cached" merge status'
  mk_plain_diff
  ready 469 --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c 'import json,sys;json.load(sys.stdin)'
}

# ── 11. WHOLE-QUEUE BEHAVIOUR AND EXIT PRECEDENCE ───────────────────────────
@test "with no arguments it reports on the whole open queue" {
  mk_plain_diff
  ready
  [ "$status" -eq 0 ]
  [[ "$output" == *"!469"* ]]
  [[ "$output" == *"(of 1)"* ]]
}

@test "CANNOT-VERIFY dominates BLOCKED in the overall exit code" {
  # One MR that cannot be read at all: 2 must win over any number of 1s.
  echo "500" > "$STATE/down-pipe"
  mk_pipeline failed "$SHA_CLEAN"; mk_jobs_failed; mk_plain_diff
  ready 469
  [ "$status" -eq 2 ]
}

@test "auto-merge armed is an ADVISORY, not a blocker — it does not block READY" {
  mk_mr mwps=true
  mk_plain_diff
  ready 469
  [ "$status" -eq 0 ]
  [[ "$output" == *"auto-merge-armed"* ]]
  [[ "$output" == *"READY"* ]]
}

@test "a closed MR is BLOCKED not-open, not silently skipped" {
  python3 - "$STATE/mr.json" <<'EOF'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d["state"]="merged"; json.dump(d, open(p,"w"))
EOF
  ready 469
  [ "$status" -eq 1 ]
  [[ "$output" == *"not-open"* ]]
}

# ── 12. IT IS A READ VERB ───────────────────────────────────────────────────
#
# The operator's click is the approval. A "readiness" command that quietly
# rebased, retried or held would be spending that decision for him.
@test "it writes NOTHING — every request is a GET" {
  mk_mr dms=conflict
  mk_sensitive_diff
  ready 469
  local writes
  writes=$(grep -cvE '^GET ' "$CURL_LOG" || true)
  [ "$writes" -eq 0 ]
}

@test "no usable token is CANNOT-VERIFY with no request made" {
  unset NWP_MR_TOKEN
  export MR_SECRETS_FILE="$TMP/no-such-secrets.yml"
  ready 469
  [ "$status" -eq 2 ]
  [[ "$output" == *"No request was made"* ]]
}

# ── 13. THE CONFLICTED-PATH LIST IS A LIST OF PATHS ─────────────────────────
#
# `git merge-tree --name-only` prints the conflicted names, a BLANK LINE, and
# then its own commentary ("Auto-merging x", "CONFLICT (content): …").
# `_mr_local_testmerge` was returning the commentary as though it were more
# paths, so the live reproduction of !469 read:
#
#   conflicts in — scripts/commands/server.sh Auto-merging scripts/commands/server.sh
#   CONFLICT (content): Merge conflict in scripts/commands/server.sh
#
# — one real path wearing two impostors. A verb whose whole job is to name the
# cause must name the cause exactly; padding it with prose is how a reader stops
# reading the field.
@test "conflicted paths are PATHS — not git's commentary about them" {
  mk_mr src=feat-conflict sha="$SHA_CONFLICT" psha="$SHA_CONFLICT" dms=mergeable
  mk_pipeline success "$SHA_CONFLICT"
  mk_plain_diff
  ready 469 --json
  printf '%s' "$output" | python3 -c '
import json,sys
p=json.load(sys.stdin)["merge_requests"][0]["checks"]["merge_status"]["conflicted_paths"]
assert p == ["a.txt"], p
'
}

# ── 14. AN MR MAY NOT VANISH FROM ITS OWN REPORT ────────────────────────────
#
# `_ready_arr` drops empty members, which is right for an absent advisory and
# wrong for an absent merge request: the counts would say 9 and the array hold 8,
# and the missing MR is invisible exactly because it is missing. Driven here by
# shadowing the assessor so it returns success and nothing — the shape a failed
# nested JSON build would take.
@test "a record that could not be BUILT is CANNOT-VERIFY, not a vanished MR" {
  cd "$WORK"
  run bash -c 'source "$1"; _ready_assess(){ printf ""; return 0; }; cmd_ready 469' _ "$MR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"record-unbuildable"* ]]
  [[ "$output" == *"not a verdict on the MR"* ]]
}

@test "counts.total always equals the number of records emitted" {
  cd "$WORK"
  run bash -c 'source "$1"; _ready_assess(){ printf ""; return 0; }; cmd_ready 469 --json' _ "$MR"
  printf '%s' "$output" | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert d["counts"]["total"] == len(d["merge_requests"]), (d["counts"], len(d["merge_requests"]))
'
}
