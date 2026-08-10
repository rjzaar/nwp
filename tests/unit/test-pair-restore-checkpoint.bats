#!/usr/bin/env bats
# nwp/ops#83 — the PAIRED-RESTORE half of the both-or-forward invariant.
#
# test-pair-restore-guard.bats covers "forward". This file covers the two things
# that were missing, and the hole between them:
#
#   1. ABSENCE OF AN ANCHOR IS NOT CONSENT. `pair_anchor_set` has no production
#      caller — no promotion, no ledger dump, no SSO lock ever records one — so
#      on every real pair the counterpart anchor is empty. The old step 6 read
#      that as "no lock to orphan" and PASSED. Same shape as the membership bug
#      it sits behind: unreadable read as unpaired, unpaired read as consent.
#      Worse here, because the pre-checks the DR runbook makes you satisfy
#      (ledger + join-snapshot) are exactly what stops refusing first.
#
#   2. "BOTH" HAD NO REPRESENTATION. The invariant is named both-or-forward, but
#      only forward was expressible. A legitimate paired restore to one cut and
#      an illegitimate single-half restore had to use the SAME blanket
#      --override-pair, so the audit trail could not tell them apart.
#      --paired-restore-ack CP-<id> is the "both" branch, and it is checked
#      against a RECORDED joint checkpoint, not taken as a promise.
#
# Fixtures are self-contained; the coupled member-paired shape (the REAL
# pair's shape — its contract lives in the private overlay since ops#326) is
# pinned by the cons/prov fixture, and the SHIPPED sample pair (ssd↔nwd) is
# pinned as the committed corpus. No network, no site, no secrets.

setup() {
  TEST_TMP=$(mktemp -d)
  export PROJECT_ROOT="${TEST_TMP}/nwp"
  mkdir -p "${PROJECT_ROOT}"
  export NWP_YML="${PROJECT_ROOT}/nwp.yml"
  export NWP_PAIR_CONTRACT_DIR="${PROJECT_ROOT}/pairs"
  export NWP_PAIR_STATE_DIR="${PROJECT_ROOT}/private/pairs"
  export NWP_PAIR_LEDGER_DIR="${PROJECT_ROOT}/private/pairs/ledger"
  mkdir -p "${NWP_PAIR_CONTRACT_DIR}" "${NWP_PAIR_STATE_DIR}" "${NWP_PAIR_LEDGER_DIR}"

  cat > "${NWP_YML}" <<'EOF'
sites:
  prov:
    recipe: d
  cons:
    recipe: d
    paired_with: prov
EOF

  cat > "${NWP_PAIR_CONTRACT_DIR}/cons.pair-contract.yml" <<'EOF'
pair: cons-prov
contract_version: 2
provider: prov
consumer: cons
identity:
  uid_lock: true
  coupled_tiers: [live, prod]
  sub_stability: uuid
  restore:
    invariant: both-or-forward
    ledger: provider
    reconcile: from-ledger
    pre_check_required: true
EOF

  source "${BATS_TEST_DIRNAME}/../../lib/ui.sh"
  source "${BATS_TEST_DIRNAME}/../../lib/pair.sh"

  # The two artifacts the DR runbook tells an operator to capture before a
  # coupled-tier restore. Satisfying them is what USED to disarm the last check.
  _prechecks_ok() {
    echo '{"t":"snap","snap":1,"sha256":"x"}' > "${NWP_PAIR_LEDGER_DIR}/cons.provider-identity.jsonl"
    echo 'row' > "${NWP_PAIR_STATE_DIR}/cons.live.join-snapshot.tsv"
  }
}

teardown() {
  rm -rf "${TEST_TMP}"
  unset NWP_YML PROJECT_ROOT NWP_PAIR_CONTRACT_DIR NWP_PAIR_STATE_DIR NWP_PAIR_LEDGER_DIR
}

# --- 1. absence of an anchor is CANNOT-VERIFY, not consent -------------------

@test "CASE 1: single-half DB restore, counterpart anchor NEVER recorded → REFUSE" {
  # The hole. Pre-checks satisfied (so step 5 cannot be what refuses), no anchor
  # anywhere (which is the state of every real pair), coupled tier, DB-touching.
  _prechecks_ok
  run pair_guard_restore prov live restore 5 false "" false ""
  [ "$status" -ne 0 ]
  [[ "$output" == *"REFUSED"* ]]
  [[ "$output" == *"CANNOT VERIFY"* ]]
}

@test "CASE 1b: same for the CONSUMER half" {
  _prechecks_ok
  run pair_guard_restore cons live restore 5 false "" false ""
  [ "$status" -ne 0 ]
  [[ "$output" == *"REFUSED"* ]]
}

@test "an uncoupled tier is still untouched by the anchor rule" {
  run pair_guard_restore prov dev restore 5 false "" false ""
  [ "$status" -eq 0 ]
}

# --- 2. code-only is the negative control ------------------------------------

@test "CASE 2: code-only restore at a coupled tier → ALLOWED" {
  # A restore that loads no DB cannot renumber an identity set. This must stay
  # green, or the suite could be satisfied by a guard that refuses everything.
  _prechecks_ok
  run pair_guard_restore prov live restore "" false "" true ""
  [ "$status" -eq 0 ]
}

@test "CASE 2b: code-only is allowed even with NO ledger and NO snapshot" {
  run pair_guard_restore prov live restore "" false "" true ""
  [ "$status" -eq 0 ]
}

@test "code-only must be POSITIVELY asserted — the default is gated" {
  _prechecks_ok
  run pair_guard_restore prov live restore 5 false "" "" ""
  [ "$status" -ne 0 ]
}

# --- 3. the paired-restore ack: "both", checked against a record -------------

@test "CASE 3: ack naming a recorded matching checkpoint → ALLOWED" {
  _prechecks_ok
  pair_checkpoint_record cons live CP-7 11 11
  run pair_guard_restore prov live restore 11 false "" false CP-7
  [ "$status" -eq 0 ]
  [[ "$output" == *"PAIRED RESTORE"* ]]
}

@test "CASE 3b: the ack is ledgered with the checkpoint id" {
  _prechecks_ok
  pair_checkpoint_record cons live CP-7 11 11
  pair_guard_restore prov live restore 11 false "" false CP-7
  grep -q "action=restore-paired-ack" "${NWP_PAIR_STATE_DIR}/cons.log"
  grep -q "cp=CP-7" "${NWP_PAIR_STATE_DIR}/cons.log"
}

@test "CASE 4: ack naming an UNKNOWN checkpoint → REFUSE (never falls through)" {
  # The whole failure family this issue exists for: an input the guard cannot
  # resolve must not degrade into "no input was given".
  _prechecks_ok
  run pair_guard_restore prov live restore 11 false "" false CP-nope
  [ "$status" -ne 0 ]
  [[ "$output" == *"REFUSED"* ]]
  [[ "$output" == *"CP-nope"* ]]
}

@test "CASE 5: ack whose recorded anchor disagrees with the restore target → REFUSE" {
  _prechecks_ok
  pair_checkpoint_record cons live CP-7 11 11
  run pair_guard_restore prov live restore 9 false "" false CP-7
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not match"* ]]
}

@test "a checkpoint recorded for another TIER does not satisfy an ack at this one" {
  _prechecks_ok
  pair_checkpoint_record cons prod CP-7 11 11
  run pair_guard_restore prov live restore 11 false "" false CP-7
  [ "$status" -ne 0 ]
}

@test "a duplicate checkpoint id with DIFFERENT anchors is ambiguous → REFUSE" {
  _prechecks_ok
  pair_checkpoint_record cons live CP-7 11 11
  pair_checkpoint_record cons live CP-7 12 12
  run pair_guard_restore prov live restore 11 false "" false CP-7
  [ "$status" -ne 0 ]
  [[ "$output" == *"ambiguous"* ]]
}

@test "an ack with no counterpart anchor in the record is not a PAIRED cut → REFUSE" {
  _prechecks_ok
  pair_checkpoint_record cons live CP-8 11 ""
  run pair_guard_restore prov live restore 11 false "" false CP-8
  [ "$status" -ne 0 ]
}

@test "re-recording the SAME checkpoint with the same anchors is idempotent" {
  _prechecks_ok
  pair_checkpoint_record cons live CP-7 11 11
  pair_checkpoint_record cons live CP-7 11 11
  run pair_guard_restore prov live restore 11 false "" false CP-7
  [ "$status" -eq 0 ]
}

# --- 4. the escape hatch still works, and is still loud ----------------------

@test "typed --override-pair still passes where the ack is absent" {
  _prechecks_ok
  run pair_guard_restore prov live restore 5 true RESTORE-OVERRIDE false ""
  [ "$status" -eq 0 ]
}

@test "an untyped override still REFUSES under the new anchor rule" {
  _prechecks_ok
  run pair_guard_restore prov live restore 5 true "" false ""
  [ "$status" -ne 0 ]
}

# --- 5. THE SHIPPED SAMPLE. ops#326: the real pair's contract lives in the
# private overlay; the committed corpus is the sample pair. CI pins that the
# sample contract still parses into this gate's vocabulary, and that the
# coupled refusals above are carried by the member-paired fixture shape.

@test "SHIPPED: the sample ssd contract carries its ops#83 restore block" {
  export NWP_PAIR_CONTRACT_DIR="${BATS_TEST_DIRNAME}/../../pairs"
  export NWP_PAIR_OVERLAY_DIR="${TEST_TMP}/no-overlay"
  local c; c="$(pair_contract_file ssd)"
  [ "$(pair_contract_get "$c" '.identity.restore.invariant')" = "both-or-nothing" ]
  [ "$(pair_contract_get "$c" '.identity.restore.reconcile')" = "recapture" ]
  [ "$(pair_contract_get "$c" '.identity.sub_stability')" = "uuid" ]
}

@test "SHIPPED: the sample pair is UNCOUPLED, so a live DB restore passes this gate" {
  # The demo pair's both-or-nothing invariant is enforced by the pair-cut
  # manifest at reset time (lib/demo-pair.sh), not by pair_guard_restore. This
  # is the committed-corpus negative control: the gate READS the sample
  # contract and correctly leaves an uncoupled pair alone.
  export PROJECT_ROOT="${TEST_TMP}/bare"; mkdir -p "${PROJECT_ROOT}"
  export NWP_YML="${PROJECT_ROOT}/nwp.yml"
  export NWP_PAIR_CONTRACT_DIR="${BATS_TEST_DIRNAME}/../../pairs"
  export NWP_PAIR_OVERLAY_DIR="${PROJECT_ROOT}/no-overlay"
  export NWP_PAIR_STATE_DIR="${PROJECT_ROOT}/state"
  export NWP_PAIR_LEDGER_DIR="${PROJECT_ROOT}/state/ledger"
  mkdir -p "${NWP_PAIR_STATE_DIR}" "${NWP_PAIR_LEDGER_DIR}"
  run pair_guard_restore ssd live restore 5 false "" false ""
  [ "$status" -eq 0 ]
}

# --- 6. checkpoint store tri-state ------------------------------------------

@test "pair_checkpoint_get is tri-state: 0 found / 1 absent / 2 ambiguous" {
  pair_checkpoint_record cons live CP-1 4 4
  run pair_checkpoint_get cons live CP-1
  [ "$status" -eq 0 ]
  run pair_checkpoint_get cons live CP-404
  [ "$status" -eq 1 ]
  pair_checkpoint_record cons live CP-1 9 9
  run pair_checkpoint_get cons live CP-1
  [ "$status" -eq 2 ]
}

@test "pair_checkpoint_record rejects a malformed checkpoint id" {
  run pair_checkpoint_record cons live "CP with spaces" 4 4
  [ "$status" -ne 0 ]
}

@test "pair_checkpoint_record rejects a non-integer anchor" {
  run pair_checkpoint_record cons live CP-2 abc 4
  [ "$status" -ne 0 ]
}

# --- 7. SIDE DOORS onto the same DB-loading executors -----------------------
#
# A choke point is only a choke point if it is the ONLY door. These two reached
# a live DB load past the gate: one by not calling it, one by calling it with an
# argument that made it ask about the wrong tier. Static assertions, because the
# behaviour they pin is "this call site exists at all".

@test "STATIC: pl moodle rollback execute calls pair_guard_restore before the DB load" {
  # moodle_remote_rollback_execute gunzips a dump into the LIVE Moodle DB. It
  # has two callers; this one used to have neither gate.
  local f="${BATS_TEST_DIRNAME}/../../scripts/commands/moodle.sh"
  grep -q 'pair_guard_restore' "$f"
  # ...and the guard must come BEFORE the executor, not after it.
  local g x
  g=$(grep -n 'pair_guard_restore' "$f" | head -1 | cut -d: -f1)
  x=$(grep -n 'moodle_remote_rollback_execute "\$entry"' "$f" | head -1 | cut -d: -f1)
  [ -n "$g" ] && [ -n "$x" ] && [ "$g" -lt "$x" ]
}

@test "STATIC: pl moodle rollback also requires the hardware deploy gate" {
  grep -q 'deploy_gate_require "\$BASE" "\$_mr_tier"' \
    "${BATS_TEST_DIRNAME}/../../scripts/commands/moodle.sh"
}

@test "STATIC: the local rollback arm passes --tier to restore.sh" {
  # Without it, restore.sh defaults to TIER=dev and pair_guard_restore evaluates
  # an UNCOUPLED tier — the gate answers a question nobody asked.
  grep -q 'restore_opts="\$restore_opts --tier \$_rb_tier"' \
    "${BATS_TEST_DIRNAME}/../../lib/rollback.sh"
}

@test "STATIC: pl restore has NO --code-only flag" {
  # Every path in that verb loads a DB, so such a flag could only silence the
  # gate without changing the operation. code_only is derived, never asserted.
  local f="${BATS_TEST_DIRNAME}/../../scripts/commands/restore.sh"
  ! grep -qE '^\s+LONGOPTS=.*code-only' "$f"
  grep -q 'pair_guard_restore "\$to_site" "\$tier" "restore" "\$anchor" "\$override_pair" "" false' "$f"
}
