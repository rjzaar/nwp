#!/usr/bin/env bats
# ops#235 — `pl issue close`'s open-MR guard was INERT for its entire life.
#
# THE BUG. The guard asked nwp/ops (project 21) for an issue's related merge
# requests using `gitlab.ops_note_token`, a Reporter token walled to project 21.
# The implementing MRs live in nwp/nwp (project 9). GitLab does NOT 403 the
# cross-project half — it silently FILTERS OUT the merge requests the token
# cannot see and returns `[]`. So the only reachable answer was "0 open MRs",
# and a guard whose whole job is refusing could never refuse.
#
# Measured live on 2026-08-02 against nwp/ops#204, which had four related MRs:
#     ops_note_token -> []
#     api_token      -> !306 merged · !327 merged · !334 merged · !337 OPENED
# and the old two lines, run verbatim against that same issue, printed n=0 and
# "would ALLOW THE CLOSE".
#
# A 403 would have been loud. `[]` reads as a clean bill of health.
#
# WHAT IS PINNED HERE
#   * the escalation: this READ uses a token that can see the code projects
#   * FAIL CLOSED on blindness — rc 3, never rc 0 (the `pl server health`
#     convention: "could not look" is its own answer)
#   * a RED-PROOF of the original defect: the same fixture that made the old
#     code return 0 must now refuse
#
# Hermetic by construction: curl is PATH-stubbed and answers from the URL and
# the PRIVATE-TOKEN in the 0600 config, so the token-scope asymmetry that caused
# the bug is REPRODUCED rather than described. Nothing here reaches a network,
# and nothing here depends on a token this machine happens to hold.

setup() {
  TEST_TMP=$(mktemp -d)
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  ISSUE="$ROOT/scripts/commands/issue.sh"

  STUB="$TEST_TMP/bin"; mkdir -p "$STUB"
  export CURL_LOG="$TEST_TMP/curl.log"
  export FIXTURE_DIR="$TEST_TMP/fx"; mkdir -p "$FIXTURE_DIR"

  # curl stub. Reads the 0600 config curl was given, extracts the URL and the
  # token, and answers the way the real forge does:
  #   * the WALLED token 404s on project 9 and gets [] for cross-project MRs
  #   * the WIDE token sees project 9 and gets the real related-MR list
  cat > "$STUB/curl" <<'STUBEOF'
#!/bin/bash
cfg=""
while [ $# -gt 0 ]; do case "$1" in -K) cfg="$2"; shift 2 ;; *) shift ;; esac; done
url=$(sed -n 's/^url = "\(.*\)"$/\1/p' "$cfg")
tok=$(sed -n 's/^header = "PRIVATE-TOKEN: \(.*\)"$/\1/p' "$cfg")
meth=$(sed -n 's/^request = "\(.*\)"$/\1/p' "$cfg")
echo "${meth:-GET} $tok $url" >> "$CURL_LOG"
case "$url" in
  */projects/9)
      if [ "$tok" = "TOK-WIDE" ]; then echo '{"id":9,"path_with_namespace":"nwp/nwp"}'
      else echo '{"message":"404 Project Not Found"}'; fi ;;
  *related_merge_requests*)
      # The read is PAGINATED, so the URL now carries ?per_page=100&page=N. The
      # fixture may be a directory of pages (related.p<N>.json) or a single
      # related.json served as page 1 with an empty page 2.
      page=$(printf '%s' "$url" | sed -n 's/.*[?&]page=\([0-9]*\).*/\1/p'); page="${page:-1}"
      if [ "$tok" = "TOK-WIDE" ]; then
        if [ -f "$FIXTURE_DIR/related.p$page.json" ]; then cat "$FIXTURE_DIR/related.p$page.json"
        elif [ "$page" = "1" ]; then cat "$FIXTURE_DIR/related.json"
        else echo '[]'; fi
      else echo '[]'; fi ;;                    # <- THE BUG: filtered, not refused
  *"/issues?state=all"*)
      # page 1 has one CLOSED issue; page 2 is empty so pagination terminates.
      case "$url" in
        *"page=1"*) echo '[{"iid":204,"state":"closed","title":"a closed issue","description":"no refs here"}]' ;;
        *)          echo '[]' ;;
      esac ;;
  */notes*)
      echo '[]' ;;
  */issues/[0-9]*)
      echo '{"iid":204,"state":"closed"}' ;;
  *)  echo '{}' ;;
esac
STUBEOF
  chmod +x "$STUB/curl"
  export PATH="$STUB:$PATH"

  export NWP_GITLAB_HOST="gitlab.example.invalid"
  export NWP_SECRETS_FILE="$TEST_TMP/secrets.yml"
  export NWP_ISSUE_CODE_PROJECTS="9"

  # Default fixture: one OPEN MR in the CODE project, mirroring the live shape.
  cat > "$FIXTURE_DIR/related.json" <<'EOF'
[{"iid":337,"state":"opened","title":"REVIEW: fix(todo): the check registry","references":{"full":"nwp/nwp!337"}},
 {"iid":334,"state":"merged","title":"earlier work","references":{"full":"nwp/nwp!334"}}]
EOF
}

teardown() { rm -rf "$TEST_TMP"; }

################################################################################
# refute / refute_grep — a NEGATIVE assertion that actually fails the test.
#
# `! cmd` inside a bats test is a NO-OP unless it happens to be the last line.
# bash exempts a negated command from errexit ("the shell does not exit ... if
# the command's return value is being inverted with !"), and bats grades a test
# by the status of its final command. Measured 2026-08-03: with the row
# separator deliberately broken, `! printf '%s\n' "$output" | grep -qF '\t'`
# matched — and the test still reported `ok`.
#
# Every negative assertion in this file is one of "no write happened" or "the
# walled token was not used". Those are the assertions that make the positive
# ones mean anything, and they were the ones not running.
################################################################################
refute()       { if "$@"; then echo "refute: '$*' unexpectedly SUCCEEDED" >&2; return 1; fi; }
refute_grep()  { if printf '%s\n' "$output" | grep -qE "$1"; then echo "refute_grep: output matched /$1/" >&2; return 1; fi; }
refute_grepf() { if printf '%s\n' "$output" | grep -qF "$1"; then echo "refute_grepf: output contained '$1'" >&2; return 1; fi; }


_secrets_both()   { printf 'gitlab:\n  ops_note_token: TOK-WALLED\n  api_token: TOK-WIDE\n' > "$NWP_SECRETS_FILE"; }
_secrets_walled() { printf 'gitlab:\n  ops_note_token: TOK-WALLED\n' > "$NWP_SECRETS_FILE"; }

################################################################################
# RED-PROOF OF THE ORIGINAL DEFECT.
#
# Run the ORIGINAL two lines against the SAME stub. If this ever stops saying 0,
# the fixture no longer reproduces the bug and every test below is meaningless.
################################################################################

@test "RED-PROOF: the ORIGINAL guard expression returns 0 on a fixture with an open MR" {
  _secrets_both
  run bash -c '
    set -uo pipefail
    export PROJECT_ROOT="'"$ROOT"'" SECRETS_FILE="'"$NWP_SECRETS_FILE"'" PROJECT_ID=21
    YQ=$(command -v yq)
    source "'"$ROOT"'/lib/gitlab-issues.sh"
    open_mrs=$(_api_get "/projects/21/issues/204/related_merge_requests" 2>/dev/null || echo "[]")
    printf "%s" "$open_mrs" | "$YQ" e -p=json "[.[] | select(.state == \"opened\")] | length" -
  '
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]     # <- the inert guard. This is the bug, reproduced.
}

################################################################################
# THE FIX — issue_open_mrs, three distinguishable answers.
################################################################################

_open_mrs() { # $1 = iid
  bash -c '
    set -uo pipefail
    export PROJECT_ROOT="'"$ROOT"'" SECRETS_FILE="'"$NWP_SECRETS_FILE"'" PROJECT_ID=21
    YQ=$(command -v yq)
    source "'"$ROOT"'/lib/gitlab-issues.sh"
    rc=0; issue_open_mrs "'"$1"'" || rc=$?
    echo "RC=$rc"
  '
}

@test "rc 1 + the MR is NAMED, when an open MR exists in the code project" {
  _secrets_both
  run _open_mrs 204
  [[ "$output" == *"RC=1"* ]]
  [[ "$output" == *"nwp/nwp!337"* ]]
  [[ "$output" != *"nwp/nwp!334"* ]]     # merged ones are not "open"
}

@test "rc 0 only when the projects were VISIBLE and the list really was empty" {
  _secrets_both
  echo '[]' > "$FIXTURE_DIR/related.json"
  run _open_mrs 204
  [[ "$output" == *"RC=0"* ]]
}

@test "rc 3 BLIND when no token can see the code project — NOT rc 0" {
  _secrets_walled                      # only the walled token exists
  run _open_mrs 204
  [[ "$output" == *"RC=3"* ]]
  [[ "$output" != *"RC=0"* ]]
}

@test "rc 3 when the MR endpoint returns an error OBJECT rather than an array" {
  _secrets_both
  echo '{"message":"403 Forbidden"}' > "$FIXTURE_DIR/related.json"
  run _open_mrs 204
  [[ "$output" == *"RC=3"* ]]
}

@test "the read ESCALATES: the walled token is tried first, then the wide one" {
  _secrets_both
  _open_mrs 204 >/dev/null
  # Both tokens were used to probe; the MR read went out under the WIDE one.
  grep -q "GET TOK-WALLED .*/projects/9$" "$CURL_LOG"
  grep -q "GET TOK-WIDE .*/projects/9$" "$CURL_LOG"
  grep -q "GET TOK-WIDE .*related_merge_requests" "$CURL_LOG"
  refute grep -q "TOK-WALLED .*related_merge_requests" "$CURL_LOG"
}

@test "least privilege is preserved: a walled token that CAN see the project is used" {
  # Guards against 'escalate unconditionally'. If the low-privilege token can
  # answer, it must be the one that does.
  _secrets_both
  cat > "$STUB/curl" <<'STUBEOF'
#!/bin/bash
cfg=""; while [ $# -gt 0 ]; do case "$1" in -K) cfg="$2"; shift 2 ;; *) shift ;; esac; done
url=$(sed -n 's/^url = "\(.*\)"$/\1/p' "$cfg")
tok=$(sed -n 's/^header = "PRIVATE-TOKEN: \(.*\)"$/\1/p' "$cfg")
echo "GET $tok $url" >> "$CURL_LOG"
case "$url" in
  */projects/9)               echo '{"id":9}' ;;          # BOTH tokens can see it now
  *related_merge_requests*)   cat "$FIXTURE_DIR/related.json" ;;
  *)                          echo '{}' ;;
esac
STUBEOF
  chmod +x "$STUB/curl"
  _open_mrs 204 >/dev/null
  grep -q "TOK-WALLED .*related_merge_requests" "$CURL_LOG"
  refute grep -q "TOK-WIDE .*related_merge_requests" "$CURL_LOG"
}

################################################################################
# PAGINATION (2026-08-03, !320 rebase). The guard's read was a single GET, and
# GitLab's DEFAULT page size for related_merge_requests is 20 — not 100. So an
# issue with a long MR history whose one OPEN merge request happened to sort
# onto page 2 read as "0 open MRs" and the close was allowed. Same failure mode
# as ops#235, one page further in.
################################################################################

_fixture_open_mr_on_page_2() {
  # page 1: a full page of MERGED MRs, so the walk cannot stop here
  python3 - "$FIXTURE_DIR/related.p1.json" <<'PY'
import json,sys
json.dump([{"iid":i,"state":"merged","title":"old work %d"%i,
            "references":{"full":"nwp/nwp!%d"%i}} for i in range(1,101)],
          open(sys.argv[1],"w"))
PY
  cat > "$FIXTURE_DIR/related.p2.json" <<'EOF'
[{"iid":999,"state":"opened","title":"the unlanded one","references":{"full":"nwp/nwp!999"}}]
EOF
  echo '[]' > "$FIXTURE_DIR/related.p3.json"
}

@test "RED-PROOF: a SINGLE-PAGE read misses an open MR that sits on page 2" {
  _secrets_both
  _fixture_open_mr_on_page_2
  # The pre-2026-08-03 expression, verbatim, against the very same fixture.
  run bash -c '
    set -uo pipefail
    export PROJECT_ROOT="'"$ROOT"'" SECRETS_FILE="'"$NWP_SECRETS_FILE"'" PROJECT_ID=21
    YQ=$(command -v yq)
    source "'"$ROOT"'/lib/gitlab-issues.sh"
    json=$(_api_get_as .gitlab.api_token "/projects/21/issues/204/related_merge_requests" 2>/dev/null || true)
    printf "%s" "$json" | "$YQ" e -p=json "[.[] | select(.state == \"opened\")] | length" -
  '
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]     # <- the truncation, reproduced. 0 open, on a fixture with one.
}

@test "issue_open_mrs WALKS pages: the page-2 open MR is found and named (rc 1)" {
  _secrets_both
  _fixture_open_mr_on_page_2
  run _open_mrs 204
  [[ "$output" == *"RC=1"* ]]
  [[ "$output" == *"nwp/nwp!999"* ]]
  [[ "$output" != *"RC=0"* ]]
}

@test "pl issue close REFUSES (exit 1) on an open MR reachable only on page 2" {
  _secrets_both
  _fixture_open_mr_on_page_2
  run bash "$ISSUE" close 204
  [ "$status" -eq 1 ]
  [[ "$output" == *"nwp/nwp!999"* ]]
  refute grep -q '^PUT ' "$CURL_LOG"
}

@test "pagination TERMINATES: a short page ends the walk, it does not spin" {
  _secrets_both
  echo '[]' > "$FIXTURE_DIR/related.json"
  run _open_mrs 204
  [[ "$output" == *"RC=0"* ]]
  # exactly one related-MR GET for a single short page — no page 2 probe
  n=$(grep -c "related_merge_requests" "$CURL_LOG")
  [ "$n" -eq 1 ]
}

@test "the visibility probe is memoised — asked once, not once per issue" {
  _secrets_both
  bash -c '
    set -uo pipefail
    export PROJECT_ROOT="'"$ROOT"'" SECRETS_FILE="'"$NWP_SECRETS_FILE"'" PROJECT_ID=21
    YQ=$(command -v yq)
    source "'"$ROOT"'/lib/gitlab-issues.sh"
    for i in 1 2 3 4 5; do issue_open_mrs 204 >/dev/null 2>&1 || true; done
  '
  # 5 issues, 2 probe calls total (walled then wide), not 10.
  n=$(grep -c "/projects/9$" "$CURL_LOG")
  [ "$n" -eq 2 ]
}

################################################################################
# THE VERB — exit codes an operator and a script can act on.
################################################################################

@test "pl issue close REFUSES (exit 1) and names the MR" {
  _secrets_both
  run bash "$ISSUE" close 204
  [ "$status" -eq 1 ]
  [[ "$output" == *"refusing to close nwp/ops#204"* ]]
  [[ "$output" == *"nwp/nwp!337"* ]]
  refute grep -q '^PUT ' "$CURL_LOG"    # positively assert nothing was written
}

@test "pl issue close REFUSES with exit 3 when it CANNOT VERIFY" {
  _secrets_walled
  run bash "$ISSUE" close 204
  [ "$status" -eq 3 ]
  [[ "$output" == *"CANNOT VERIFY"* ]]
  refute grep -q '^PUT ' "$CURL_LOG"
}

@test "pl issue close proceeds when the list is genuinely empty AND visible" {
  _secrets_both
  echo '[]' > "$FIXTURE_DIR/related.json"
  run bash "$ISSUE" close 204
  [ "$status" -eq 0 ]
  grep -q '^PUT ' "$CURL_LOG"          # the write DID happen — guard discriminates
}

@test "--force still overrides, from BOTH the refuse and the blind states" {
  _secrets_both
  run bash "$ISSUE" close 204 --force
  [ "$status" -eq 0 ]
  grep -q '^PUT ' "$CURL_LOG"
  : > "$CURL_LOG"
  _secrets_walled
  run bash "$ISSUE" close 204 --force
  [ "$status" -eq 0 ]
  grep -q '^PUT ' "$CURL_LOG"
}

################################################################################
# pl issue reconcile — the same blindness, in the REPORTING half, and worse:
# it was wrong in BOTH directions. `open_mr_n` was pinned at 0, so
#   * CLOSED-BUT-OPEN-MR was unreachable                      (false negative)
#   * MERGED-BUT-OPEN fired on any issue with a merge in history regardless of
#     open MRs, advising `pl issue close` on work still in flight
#                                                             (false positive,
#                                                              acted on by a human)
################################################################################

@test "reconcile: CLOSED-BUT-OPEN-MR is now REACHABLE (it never was)" {
  _secrets_both
  export NWP_RECONCILE_REPOS="$TEST_TMP"       # no git repos → no STALE-REF noise
  run bash "$ISSUE" reconcile 204
  [[ "$output" == *"CLOSED-BUT-OPEN-MR"* ]]
  [[ "$output" == *"pl issue reopen 204"* ]]
  [[ "$output" == *"MR visibility: OK"* ]]
}

@test "reconcile: BLIND says so, withholds both MR classes, and exits 3" {
  _secrets_walled
  export NWP_RECONCILE_REPOS="$TEST_TMP"
  run bash "$ISSUE" reconcile 204
  [ "$status" -eq 3 ]
  [[ "$output" == *"MR VISIBILITY: BLIND"* ]]
  # Assert no FINDING ROW for the class, not merely absence of the string: the
  # blindness banner legitimately NAMES the two classes it is withholding, so a
  # bare substring test fails against correct output. (Written the naive way
  # first; it went red on a behaviour that was right. Recorded because the
  # tempting fix is to soften the banner rather than sharpen the assertion.)
  refute_grep '^[[:space:]]+CLOSED-BUT-OPEN-MR[[:space:]]+#'
  refute_grep '^[[:space:]]+MERGED-BUT-OPEN[[:space:]]+#'
  # And crucially: no clean bill of health over data it never read.
  [[ "$output" != *"tracker and code agree"* ]]
  [[ "$output" == *"PARTIAL"* ]]
}

@test "reconcile classifies the LAST row (command substitution eats the final newline)" {
  # REGRESSION, 2026-08-03. Moving the tracker read onto the shared pagination
  # primitive made it `issues_tsv=$(_api_rows …)`, and command substitution
  # strips the trailing newline — so the final row reached `while read`
  # unterminated and was never classified. A de-truncation change that loses the
  # LAST issue instead of the newest 36 is still a truncation.
  #
  # Two issues, and ONLY the last one is a finding, so the assertion cannot pass
  # by accident on the first row.
  _secrets_both
  export NWP_RECONCILE_REPOS="$TEST_TMP"
  cat > "$STUB/curl" <<'STUBEOF'
#!/bin/bash
cfg=""; while [ $# -gt 0 ]; do case "$1" in -K) cfg="$2"; shift 2 ;; *) shift ;; esac; done
url=$(sed -n 's/^url = "\(.*\)"$/\1/p' "$cfg")
tok=$(sed -n 's/^header = "PRIVATE-TOKEN: \(.*\)"$/\1/p' "$cfg")
echo "GET $tok $url" >> "$CURL_LOG"
case "$url" in
  */projects/9)
      if [ "$tok" = "TOK-WIDE" ]; then echo '{"id":9}'; else echo '{"message":"404"}'; fi ;;
  *"/issues/111/related_merge_requests"*) echo '[]' ;;
  *"/issues/222/related_merge_requests"*)
      if [ "$tok" = "TOK-WIDE" ]; then
        echo '[{"iid":999,"state":"opened","title":"still in flight","references":{"full":"nwp/nwp!999"}}]'
      else echo '[]'; fi ;;
  *"/issues?state=all"*)
      case "$url" in
        *"&page=1"*) echo '[{"iid":111,"state":"closed","title":"first, genuinely done","description":"x"},
                            {"iid":222,"state":"closed","title":"LAST, and still has an open MR","description":"x"}]' ;;
        *)           echo '[]' ;;
      esac ;;
  */notes*) echo '[]' ;;
  *) echo '{}' ;;
esac
STUBEOF
  chmod +x "$STUB/curl"
  run bash "$ISSUE" reconcile
  [[ "$output" == *"CLOSED-BUT-OPEN-MR"* ]]
  [[ "$output" == *"#222"* ]]
  [[ "$output" != *"tracker and code agree"* ]]
}

@test "reconcile --json stays parseable when blind (the banner is a real element)" {
  _secrets_walled
  export NWP_RECONCILE_REPOS="$TEST_TMP"
  run bash -c "bash '$ISSUE' reconcile 204 --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0][\"class\"])'"
  [ "$status" -eq 0 ]
  [ "$output" = "MR-VISIBILITY-BLIND" ]
}
