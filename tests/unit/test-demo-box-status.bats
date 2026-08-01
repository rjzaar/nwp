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
