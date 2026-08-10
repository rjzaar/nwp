#!/usr/bin/env bats
#
# test-demo-box-status.bats — nwp/ops#198: `pl demo status` must tell the truth
# about BOX-SIDE resets.
#
# THE DEFECT THIS PINS (observed 2026-08-01)
#   Both unattended resets ran perfectly — nwd at 15:00 and ssd at 15:15,
#   Melbourne — and `pl demo status` reported "last reset 06:32".
#
#   It was not lying about its data; it was wrong about whose data it was.
#   `cmd_status` read `sites/<site>/demo-reset.log` via `demo_log_file`, which
#   — unlike its sibling `demo_golden_dir` — ignores the tier completely. That
#   file is written only by THIS checkout. The box writes somewhere else, in a
#   different format, on a different machine:
#
#     local  sites/<site>/demo-reset.log             space-separated
#     box    /var/log/nwp-demo/<site>-demo-reset.log PIPE-separated
#     box    /var/lib/nwp-demo/<site>/last-reset     the idempotence stamp
#
#   `grep -rn '/var/log/nwp-demo' scripts/ lib/ pl` matched nothing. No code
#   path had ever read the box's record.
#
# THE PROPERTY THAT MATTERS
#   THREE outcomes, never two. "I could not reach the box" must never render as
#   "no resets" — that is how a silently dead nightly stays silent.
#
#   Verified against the real box on 2026-08-02 (read-only, `status` action
#   word): `last box reset: 2026-08-02 1785596453`, where the old code showed
#   only this checkout's own golden-capture lines.

setup() {
  ROOT="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
  LIB="$ROOT/lib/demo-box-status.sh"
  TEST_TMP=$(mktemp -d)
  export PROJECT_ROOT="${TEST_TMP}/nwp"
  mkdir -p "${PROJECT_ROOT}/sites/demo1"
  DEMO_CMD="$ROOT/scripts/commands/demo.sh"
  # Real output of `<site>-demo-reset-restricted status`, captured from the box.
  RAW='2026-08-01T19:43:14Z|invoked|action=status client=203.0.113.9 original=status
site:        nwd (nwd.example)
golden dir:  /var/lib/nwp-demo/nwd/golden
golden:      captured 2026-08-01T17:06:34Z
last reset:  2026-08-02 1785596453
--- last 15 log lines ---
2026-08-01T16:30:04Z|invoked|action=nightly client=203.0.113.9 original=nightly
2026-08-01T16:30:05Z|skip-already-reset|date=2026-08-02
2026-08-01T17:00:05Z|reset-ok|took=131s action=nightly'
}

teardown() { rm -rf "$TEST_TMP"; unset PROJECT_ROOT; }

_lib() { bash -c "source '$LIB'; $1"; }

# ─────────────────────────────────────────────────────────────────────────────
# Parsing the box's own words
# ─────────────────────────────────────────────────────────────────────────────

@test "the box's last-reset stamp is read out of its status block" {
  run _lib "demo_box_last_reset '$RAW'"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-08-02 1785596453" ]
}

@test "'none' — a box that has NEVER reset — is distinguishable from a stamp" {
  local none_raw='site:        nwd (nwd.example)
last reset:  none
--- last 15 log lines ---'
  run _lib "demo_box_last_reset '$none_raw'"
  [ "$output" = "none" ]
}

@test "an unparseable block yields EMPTY, so the caller can say UNKNOWN" {
  # A wrapper format change must degrade to "I do not know", never to "never".
  run _lib "demo_box_last_reset 'site: nwd
some other shape entirely'"
  [ -z "$output" ]
}

@test "only PIPE-format box records are tailed — local lines cannot leak in" {
  run _lib "demo_box_log_tail '$RAW' 10"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 3 ]
  [[ "$output" == *"reset-ok|took=131s"* ]]
  # The space-separated LOCAL format must never be picked up by this parser.
  run _lib "demo_box_log_tail '2026-08-01T06:32:11Z reset-ok tier=live took=214s' 10"
  [ -z "$output" ]
}

@test "age in days is computed from the stamp's epoch, and refuses without one" {
  local epoch; epoch=$(( $(date +%s) - 3 * 86400 ))
  run _lib "demo_box_reset_age_days '2026-01-01 $epoch'"
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]
  run _lib "demo_box_reset_age_days 'none'"
  [ "$status" -ne 0 ]
}

@test "with no key and no route, the probe returns 3 — 'could not look'" {
  # rc 3 is the whole point: it is NOT rc 0 with empty output.
  run _lib "HOME='$TEST_TMP' demo_box_reset_status nosuchsite"
  [ "$status" -eq 3 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# The verb — what an operator actually sees
# ─────────────────────────────────────────────────────────────────────────────

@test "live status says UNKNOWN, not 'no resets', when the box cannot be read" {
  run env HOME="$TEST_TMP" DEMO_STATUS_NO_BOX=0 bash "$DEMO_CMD" status demo1 --tier=live
  [ "$status" -eq 0 ]
  [[ "$output" == *"Box-side (unattended) resets"* ]]
  [[ "$output" == *"UNKNOWN"* ]]
  [[ "$output" == *"could not read the box"* ]]
  # The sentence that stops the next reader repeating the 06:32 mistake.
  [[ "$output" == *"This is NOT 'no resets'"* ]]
}

@test "the local log block now says WHOSE log it is" {
  run env HOME="$TEST_TMP" bash "$DEMO_CMD" status demo1 --tier=live
  [[ "$output" == *"THIS CHECKOUT only"* ]]
  # The old unqualified heading is what made 06:32 read as the site's truth.
  [[ "$output" != *"Recent resets/skips (last 10):"* ]]
}

@test "a local log is reported as local, and does not suppress the box block" {
  mkdir -p "${PROJECT_ROOT}/sites/demo1"
  printf '2026-08-01T06:32:11Z reset-ok tier=live took=214s\n' \
    > "${PROJECT_ROOT}/sites/demo1/demo-reset.log"
  run env HOME="$TEST_TMP" bash "$DEMO_CMD" status demo1 --tier=live
  [[ "$output" == *"06:32"* ]]
  [[ "$output" == *"THIS CHECKOUT only"* ]]
  # Both blocks must be present: the bug was one standing in for the other.
  [[ "$output" == *"Box-side (unattended) resets"* ]]
  [[ "$output" == *"UNKNOWN"* ]]
}

@test "dev/stg status pays no round trip (the fast read-only contract holds)" {
  run env HOME="$TEST_TMP" bash "$DEMO_CMD" status demo1 --tier=dev
  [ "$status" -eq 0 ]
  [[ "$output" != *"Box-side"* ]]
}

@test "DEMO_STATUS_NO_BOX=1 skips the probe and SAYS it skipped" {
  run env HOME="$TEST_TMP" DEMO_STATUS_NO_BOX=1 bash "$DEMO_CMD" status demo1 --tier=live
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIPPED (DEMO_STATUS_NO_BOX=1)"* ]]
  # A skipped probe must not masquerade as a clean one.
  [[ "$output" != *"last box reset"* ]]
}

@test "the box probe asks only for 'status' — no mutating action word, ever" {
  # The restricted key is a forced command whose action word decides whether the
  # box READS or WIPES. This monitoring path must never widen past `status`.
  # Strip comments first: the header legitimately names the other action words.
  code="$(grep -vE '^[[:space:]]*#' "$LIB")"

  # The admin fallback invokes exactly one action word, and it is `status`.
  run bash -c "printf '%s\n' \"\$1\" | grep -cE 'demo-reset-restricted status' -" _ "$code"
  [ "$output" = "1" ]

  # Nothing in the executable body invokes a mutating one.
  run bash -c "printf '%s\n' \"\$1\" | grep -cE 'demo-reset-restricted (nightly|reset|harvest)|\\\$sshcmd (nightly|reset|harvest)' -" _ "$code"
  [ "$output" = "0" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# ops#329 D4/D5 — the return leg + the box's nightly pull backups ride the
# same status word, and `pl demo status` / `pl demo seal-status --json`
# surface them with three-state honesty (value / not-reported / could-not-look)
# plus a STALENESS verdict: the leg is hourly, so a newest event older than
# two cycles is CANNOT VERIFY (stale return leg), never quietly green.
# ─────────────────────────────────────────────────────────────────────────────

# _libarg <snippet> <arg> — like _lib, but hands the snippet a real $1.
_libarg() { bash -c "source '$LIB'; $1" _ "$2"; }

# A box status block carrying the ops#329 D4/D5 lines. $1 = the feedback ts.
_raw_with_extras() {
  printf '%s\n' \
"site:        nwd (nwd.example)
golden dir:  /var/lib/nwp-demo/nwd/golden
golden:      captured 2026-08-01T17:06:34Z
last reset:  2026-08-02 1785596453
last_feedback_status: ${1:-2026-08-09T11:07:06Z}|feedback-status-ok|advanced=2 drafts_captured=1 checked=5
backups: /var/backups/nwp-pull
backup: db|newest=ssd-2026-08-09.sql.gz|bytes=2994050|mtime=${2:-2026-08-09T01:30:00Z}
backup: nginx|newest=nginx-conf-2026-08-09.tgz|bytes=4898|mtime=${2:-2026-08-09T01:30:00Z}
--- last 15 log lines ---
2026-08-01T17:00:05Z|reset-ok|took=131s action=nightly"
}

@test "ops#329 D4: the last_feedback_status record is read out of the status block" {
  run _lib "demo_box_feedback_status \"\$(cat <<'RAW'
last_feedback_status: 2026-08-09T11:07:06Z|feedback-status-ok|advanced=0 drafts_captured=0 checked=0
RAW
)\""
  [ "$status" -eq 0 ]
  [ "$output" = "2026-08-09T11:07:06Z|feedback-status-ok|advanced=0 drafts_captured=0 checked=0" ]
}

@test "ops#329 D4: an old wrapper without the line yields EMPTY, so callers say NOT REPORTED" {
  run _libarg "demo_box_feedback_status \"\$1\"" "$RAW"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ops#329 D4/D5: extras JSON — a fresh ok record parses with counts and stale=false" {
  ts="$(date -u -d '30 minutes ago' '+%Y-%m-%dT%H:%M:%SZ')"
  raw="$(_raw_with_extras "$ts")"
  run _libarg "demo_box_extras_json \"\$1\"" "$raw"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.feedback_status.reported == true and .feedback_status.result == "ok"'
  echo "$output" | jq -e '.feedback_status.advanced == 2 and .feedback_status.drafts_captured == 1 and .feedback_status.checked == 5'
  echo "$output" | jq -e '.feedback_status.stale == false'
  echo "$output" | jq -e '.feedback_status.age_seconds >= 1700 and .feedback_status.age_seconds <= 1900'
}

@test "ops#329 D4: extras JSON — a record older than TWO hourly cycles is stale=true" {
  raw="$(_raw_with_extras "2026-08-01T00:00:00Z")"
  run _libarg "demo_box_extras_json \"\$1\"" "$raw"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.feedback_status.reported == true and .feedback_status.stale == true'
}

@test "ops#329 D4: extras JSON — a box that answered WITHOUT the line is reported=false with a reason" {
  run _libarg "demo_box_extras_json \"\$1\"" "$RAW"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.feedback_status.reported == false and (.feedback_status.reason | test("wrapper"))'
  echo "$output" | jq -e '.backups.reported == false and (.backups.reason | test("wrapper"))'
}

@test "ops#329 D4: extras JSON — an EMPTY read (could not look) is reported=false naming the box" {
  run _lib "demo_box_extras_json ''"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.feedback_status.reported == false and (.feedback_status.reason | test("could not"))'
  echo "$output" | jq -e '.backups.reported == false'
}

@test "ops#329 D4: extras JSON — 'none' (leg never ran) and a FAILED leg keep their identities" {
  raw="last_feedback_status: none"
  run _libarg "demo_box_extras_json \"\$1\"" "$raw"
  echo "$output" | jq -e '.feedback_status.reported == true and .feedback_status.result == "none"'
  raw="last_feedback_status: 2026-08-09T12:07:06Z|feedback-status-failed|rc=3"
  run _libarg "demo_box_extras_json \"\$1\"" "$raw"
  echo "$output" | jq -e '.feedback_status.result == "fail" and .feedback_status.summary == "rc=3"'
}

@test "ops#329 D5: extras JSON — backup entries carry subdir, newest, bytes, mtime and an age" {
  # Spelled in full rather than abbreviated: the two-letter form collides with
  # a private site instance's name, which lint:site-names denies anywhere in
  # the engine tree (ops#326). The old name was a false positive — a local
  # shell variable, not a site reference — but it made the lint red on main,
  # and a lint that is red on main is a lint nobody reads.
  bk_mtime="$(date -u -d '10 hours ago' '+%Y-%m-%dT%H:%M:%SZ')"
  raw="$(_raw_with_extras "2026-08-09T11:07:06Z" "$bk_mtime")"
  run _libarg "demo_box_extras_json \"\$1\"" "$raw"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.backups.reported == true and .backups.state == "ok" and .backups.dir == "/var/backups/nwp-pull"'
  echo "$output" | jq -e '.backups.entries | length == 2'
  echo "$output" | jq -e '.backups.entries[0] | .subdir == "db" and .newest == "ssd-2026-08-09.sql.gz" and .bytes == 2994050'
  echo "$output" | jq -e '.backups.entries[0].age_seconds >= 35000 and .backups.entries[0].age_seconds <= 37000'
}

@test "ops#329 D5: extras JSON — MISSING / UNREADABLE / empty-subdir keep their identities" {
  run _lib "demo_box_extras_json 'backups: /var/backups/nwp-pull MISSING'"
  echo "$output" | jq -e '.backups.reported == true and .backups.state == "missing"'
  run _lib "demo_box_extras_json 'backups: /var/backups/nwp-pull UNREADABLE'"
  echo "$output" | jq -e '.backups.state == "unreadable"'
  run _libarg "demo_box_extras_json \"\$1\"" 'backups: /var/backups/nwp-pull
backup: db|empty'
  echo "$output" | jq -e '.backups.state == "ok" and .backups.entries[0].empty == true'
}

# ── the verb: pl demo status renders the extras with the three states ────────

@test "ops#329: status renders the return leg + backups from a healthy box read" {
  ts="$(date -u -d '30 minutes ago' '+%Y-%m-%dT%H:%M:%SZ')"
  _raw_with_extras "$ts" > "$TEST_TMP/box-status.txt"
  run env HOME="$TEST_TMP" NWP_DEMO_BOX_STATUS_FILE="$TEST_TMP/box-status.txt" \
      bash "$DEMO_CMD" status demo1 --tier=live
  [ "$status" -eq 0 ]
  [[ "$output" == *"advanced=2"* ]]
  [[ "$output" == *"nwp-pull"* ]]
  [[ "$output" == *"ssd-2026-08-09.sql.gz"* ]]
  # fresh leg is not flagged stale
  [[ "$output" != *"stale return leg"* ]]
}

@test "ops#329: a return leg older than two hourly cycles renders CANNOT VERIFY (stale return leg)" {
  _raw_with_extras "2026-08-01T00:00:00Z" > "$TEST_TMP/box-status.txt"
  run env HOME="$TEST_TMP" NWP_DEMO_BOX_STATUS_FILE="$TEST_TMP/box-status.txt" \
      bash "$DEMO_CMD" status demo1 --tier=live
  [ "$status" -eq 0 ]
  [[ "$output" == *"CANNOT VERIFY"* ]]
  [[ "$output" == *"stale return leg"* ]]
}

@test "ops#329: a wrapper that does not report the extras renders NOT REPORTED — never silent" {
  printf '%s\n' "$RAW" > "$TEST_TMP/box-status.txt"
  run env HOME="$TEST_TMP" NWP_DEMO_BOX_STATUS_FILE="$TEST_TMP/box-status.txt" \
      bash "$DEMO_CMD" status demo1 --tier=live
  [ "$status" -eq 0 ]
  [[ "$output" == *"NOT REPORTED"* ]]
}

@test "ops#329: seal-status's live path merges the box extras (contract: one renderer, no drift)" {
  # The live seal-status path cannot run inside bats (it needs a real box for
  # the manifest read), so pin the CALL: the live branch of cmd_seal_status
  # must assemble its extras through demo_box_extras_json — the same parser the
  # status verb uses — and merge them into the JSON document.
  code="$(awk '/^cmd_seal_status\(\)/,/^}/' "$DEMO_CMD")"
  [[ "$code" == *"demo_box_extras_json"* ]]
  # ops#329 D6: the consumer half's document used to be a hand-written JSON
  # literal here, which is why this line used to read `*"feedback_status"*`.
  # It now comes from the shared builder, so assert the BUILDER — a literal
  # would go stale silently the next time the shape changes.
  [[ "$code" == *"demo_box_extras_by_design_json"* ]]
  # and the extras really are merged into the emitted document
  [[ "$code" == *'--argjson extras "$extras"'* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# ops#329 D6 — `pl demo status ssd --tier=live` reported
#   "[!] UNKNOWN — the box answered but named no 'last reset'"
# and stopped there: no return-leg block, no backups block, exit 1.
#
# THREE separate defects hid behind that one vague line, all measured
# 2026-08-10 against the real ssd box:
#
#   1. WRONG ANSWER. The admin fallback asks the box for `status` as a
#      POSITIONAL argument (`sudo …-demo-reset-restricted status`), but the
#      wrapper read its action word only from $SSH_ORIGINAL_COMMAND, which sudo
#      strips. `status` resolved to "" → the `""|nightly)` arm → the box tried
#      to WIPE ssd. What came back was a reset transcript:
#        2026-08-10T12:31:02Z|invoked|action=nightly client=local original=
#        2026-08-10T12:31:02Z|skip-locked|another ssd reset is already running
#      rc was 0, so the probe reported "the box answered". It had answered a
#      different question, destructively. That must be its own state, not
#      UNKNOWN. (The wrapper half is pinned in test-{,ssd-}demo-reset-
#      restricted.bats; this file pins that the READER refuses to accept it.)
#
#   2. SILENT TRUNCATION. demo_box_log_tail's grep finds nothing in such an
#      answer and, under demo.sh's `set -euo pipefail`, its rc 1 killed the
#      verb mid-render. An empty box log is a legitimate reading, not an error.
#
#   3. A FALSE INSTRUCTION. ssd is the pair CONSUMER: D4/D5 gave the return leg
#      and the backup census to nwd's wrapper only, on purpose. Rendering that
#      as "NOT REPORTED — redeploy the wrapper" tells the operator to fix
#      something that is working as designed. seal-status already said
#      by_design here; the text surface did not.
# ─────────────────────────────────────────────────────────────────────────────

# The exact bytes the real ssd box returned on 2026-08-10.
_reset_transcript() {
  printf '%s\n' \
'2026-08-10T12:31:02Z|invoked|action=nightly client=local original=
2026-08-10T12:31:02Z|skip-locked|another ssd reset is already running
Another ssd demo reset is already running — nothing to do.'
}

@test "ops#329 D6: an answer that is NOT a status block is rc 4, never rc 0" {
  local f="${TEST_TMP}/answer.txt"
  _reset_transcript > "$f"
  run _lib "NWP_DEMO_BOX_STATUS_FILE='$f' demo_box_reset_status ssd"
  # rc 4 = "the box answered a different question". Distinct from rc 3 (could
  # not look) and from rc 0 (a real reading), because the three lead to three
  # different actions.
  [ "$status" -eq 4 ]
}

@test "ops#329 D6: a REAL status block is still rc 0 (the check is not a blanket refusal)" {
  local f="${TEST_TMP}/answer.txt"
  printf '%s\n' "$RAW" > "$f"
  run _lib "NWP_DEMO_BOX_STATUS_FILE='$f' demo_box_reset_status nwd"
  [ "$status" -eq 0 ]
  [[ "$output" == *"last reset:  2026-08-02 1785596453"* ]]
}

@test "ops#329 D6: an EMPTY box log tail is rc 0 with no output, not a failure" {
  # UNDER PIPEFAIL, which is the only environment this matters in: demo.sh runs
  # `set -euo pipefail`, so the helper's internal grep returning 1 for "nothing
  # matched" becomes the helper's rc and terminates the verb mid-render.
  # Without `set -o pipefail` here the case cannot fail and would be a check
  # that has never been proven red.
  run bash -c "set -o pipefail; source '$LIB'; demo_box_log_tail 'site: ssd
last reset:  none
--- last 15 log lines ---' 10"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ops#329 D6: live status renders EVERY block even when the box log tail is empty" {
  local f="${TEST_TMP}/answer.txt"
  printf '%s\n' \
'site:        demo1 (demo1.example)
last reset:  2026-08-10 1786000000
--- last 15 log lines ---' > "$f"
  run env HOME="$TEST_TMP" NWP_DEMO_BOX_STATUS_FILE="$f" \
      bash "$DEMO_CMD" status demo1 --tier=live
  [ "$status" -eq 0 ]
  [[ "$output" == *"last box reset: 2026-08-10 1786000000"* ]]
  # The blocks that vanished. Truncation must not be able to look like absence.
  [[ "$output" == *"Return leg"* ]]
  [[ "$output" == *"Live-box nightly backups"* ]]
}

@test "ops#329 D6: a reset transcript is reported AS ONE — never as vague UNKNOWN" {
  local f="${TEST_TMP}/answer.txt"
  _reset_transcript > "$f"
  run env HOME="$TEST_TMP" NWP_DEMO_BOX_STATUS_FILE="$f" \
      bash "$DEMO_CMD" status demo1 --tier=live
  [ "$status" -eq 0 ]
  [[ "$output" == *"CANNOT VERIFY"* ]]
  # It must name what actually happened and what to do about it.
  [[ "$output" == *"not a status block"* ]]
  [[ "$output" == *"install-box.sh"* ]]
  # And it must NOT claim the box merely spoke a dialect we don't parse.
  [[ "$output" != *"wrapper format changed?"* ]]
}

@test "ops#329 D6: the pair CONSUMER's missing return leg is by design, not a redeploy nag" {
  # ssd has no feedback-status word at all (pinned negative in
  # tests/unit/test-ssd-demo-reset-restricted.bats). Telling an operator to
  # redeploy for it is an instruction that can never come true.
  run _lib "demo_box_extras_by_design_json nwd"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.feedback_status.by_design' <<<"$output")" = "true" ]
  [ "$(jq -r '.backups.by_design'         <<<"$output")" = "true" ]
  [ "$(jq -r '.feedback_status.reported'  <<<"$output")" = "false" ]
  [[ "$(jq -r '.feedback_status.reason'   <<<"$output")" == *"nwd"* ]]
}

@test "ops#329 D6: by_design renders as 'not applicable', and never as NOT REPORTED" {
  local extras; extras="$(_lib "demo_box_extras_by_design_json nwd")"
  run env HOME="$TEST_TMP" NWP_DEMO_EXTRAS_PREBUILT="$extras" \
      bash -c "source '$DEMO_CMD'; demo_box_render_extras ssd ''"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not applicable"* ]]
  [[ "$output" == *"nwd"* ]]
  [[ "$output" != *"NOT REPORTED"* ]]
  [[ "$output" != *"install-box.sh"* ]]
}

@test "ops#329 D6: seal-status and the text surface share ONE by_design builder" {
  # Two hand-written copies of the same JSON literal is how the two surfaces
  # drift apart. There must be one producer and both must call it.
  local seal; seal="$(awk '/^cmd_seal_status\(\)/,/^}/' "$DEMO_CMD")"
  [[ "$seal" == *"demo_box_extras_by_design_json"* ]]
  local box; box="$(awk '/^cmd_status_box\(\)/,/^}/' "$DEMO_CMD")"
  [[ "$box" == *"demo_box_extras_by_design_json"* ]]
}
