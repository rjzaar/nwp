#!/usr/bin/env bats
# =============================================================================
# tests/unit/test-pair-reconcile.bats — `pl pair reconcile` (ops#83 / item 5)
# =============================================================================
# docs/guides/ops83-dr-restore.md §3 serviced a severed UID-lock with raw SQL
# typed against mdl_user over ssh, under DR time pressure. There was no verb:
# `pl pair` had list|show|status|check|record|rag|anchor|restore-check and
# nothing that could detect, let alone repair, an orphaned lock. Every case
# below was run against the pre-fix tree and observed RED
# ("Unknown subcommand: reconcile").
#
# The vacuity guards:
#   * a missing ledger or a missing join snapshot must be CANNOT-VERIFY and
#     non-zero — an empty corpus reporting "0 orphans, clean" is the exact
#     failure class this programme exists to remove;
#   * --apply with no repair executor must refuse rather than print success;
#   * an UNREPAIRABLE orphan (no ledger row at all) must never be repaired by
#     falling back to email — ops#83 makes email a human-gated last resort.
# =============================================================================

PAIR_SH="${BATS_TEST_DIRNAME}/../../scripts/commands/pair.sh"

setup() {
  TMP="$(mktemp -d)"
  export PROJECT_ROOT="${BATS_TEST_DIRNAME}/../.."
  export NWP_PAIR_CONTRACT_DIR="${TMP}/pairs"
  export NWP_PAIR_STATE_DIR="${TMP}/state"
  export NWP_PAIR_LEDGER_DIR="${TMP}/state/ledger"
  mkdir -p "$NWP_PAIR_CONTRACT_DIR" "$NWP_PAIR_STATE_DIR" "$NWP_PAIR_LEDGER_DIR"

  U_OK="11111111-1111-4111-8111-111111111111"
  U_LEGACY_UUID="22222222-2222-4222-8222-222222222222"
  U_GONE="33333333-3333-4333-8333-333333333333"

  cat > "${NWP_PAIR_CONTRACT_DIR}/cons.pair-contract.yml" <<YML
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
YML

  LEDGER="${NWP_PAIR_LEDGER_DIR}/cons.provider-identity.jsonl"
  SNAP="${NWP_PAIR_STATE_DIR}/cons.live.join-snapshot.tsv"
}

teardown() { rm -rf "${TMP}"; }

# One ledger snapshot: U_OK (uuid intact) and a legacy row whose serial uid is
# 4210 and whose durable uuid is U_LEGACY_UUID.
_write_ledger() {
  {
    printf '{"t":"rec","snap":1,"uuid":"%s","uid":17,"created":"1","email":"ok@example.test"}\n' "$U_OK"
    printf '{"t":"rec","snap":1,"uuid":"%s","uid":4210,"created":"1","email":"legacy@example.test"}\n' "$U_LEGACY_UUID"
    printf '{"t":"snap","snap":1,"at":"2026-07-26T00:00:00Z","who":"t@t","rows":2,"prev":"GENESIS","sha256":"deadbeef"}\n'
  } > "$LEDGER"
}

# Consumer join snapshot: mdl_id <TAB> locked_sub <TAB> email <TAB> deleted
_write_snapshot() {
  {
    printf 'mdl_id\tlocked_sub\temail\tdeleted\n'
    printf '5\t%s\tok@example.test\t0\n' "$U_OK"
    printf '6\t4210\tlegacy@example.test\t0\n'
    printf '7\t%s\tgone@example.test\t0\n' "$U_GONE"
  } > "$SNAP"
}

# =============================================================================
# fail-closed inputs
# =============================================================================

@test "pair reconcile: no provider ledger is CANNOT-VERIFY, not clean" {
  _write_snapshot
  run bash "$PAIR_SH" reconcile cons --tier=live
  [ "$status" -ne 0 ]
  [[ "$output" == *"CANNOT-VERIFY"* ]]
  [[ "$output" != *"intact"* ]] || [[ "$output" == *"CANNOT-VERIFY"* ]]
}

@test "pair reconcile: no consumer join snapshot is CANNOT-VERIFY, not clean" {
  _write_ledger
  run bash "$PAIR_SH" reconcile cons --tier=live
  [ "$status" -ne 0 ]
  [[ "$output" == *"CANNOT-VERIFY"* ]]
}

@test "pair reconcile: an EMPTY join snapshot is CANNOT-VERIFY, not 'zero orphans'" {
  _write_ledger
  printf 'mdl_id\tlocked_sub\temail\tdeleted\n' > "$SNAP"
  run bash "$PAIR_SH" reconcile cons --tier=live
  [ "$status" -ne 0 ]
  [[ "$output" == *"CANNOT-VERIFY"* ]]
}

@test "pair reconcile: an unknown pair fails closed" {
  run bash "$PAIR_SH" reconcile nosuchpair --tier=live
  [ "$status" -ne 0 ]
}

# =============================================================================
# classification
# =============================================================================

@test "pair reconcile: classifies intact / repairable / orphaned and exits non-zero" {
  _write_ledger; _write_snapshot
  run bash "$PAIR_SH" reconcile cons --tier=live
  [ "$status" -ne 0 ]
  [[ "$output" == *"intact"* ]]
  [[ "$output" == *"repairable"* ]]
  [[ "$output" == *"orphaned"* ]]
  # The repairable row must name the durable uuid it would be repointed to.
  [[ "$output" == *"$U_LEGACY_UUID"* ]]
}

@test "pair reconcile: a fully intact estate exits zero" {
  _write_ledger
  {
    printf 'mdl_id\tlocked_sub\temail\tdeleted\n'
    printf '5\t%s\tok@example.test\t0\n' "$U_OK"
  } > "$SNAP"
  run bash "$PAIR_SH" reconcile cons --tier=live
  [ "$status" -eq 0 ]
  [[ "$output" == *"JOIN INTACT"* ]]
}

@test "pair reconcile: deleted consumer rows are not counted as orphans" {
  _write_ledger
  {
    printf 'mdl_id\tlocked_sub\temail\tdeleted\n'
    printf '5\t%s\tok@example.test\t0\n' "$U_OK"
    printf '9\t%s\tgone@example.test\t1\n' "$U_GONE"
  } > "$SNAP"
  run bash "$PAIR_SH" reconcile cons --tier=live
  [ "$status" -eq 0 ]
}

@test "pair reconcile: --json emits a machine-readable classification" {
  _write_ledger; _write_snapshot
  run bash "$PAIR_SH" reconcile cons --tier=live --json
  [ "$status" -ne 0 ]
  line="$(printf '%s\n' "$output" | grep -m1 '^{')"
  run bash -c "printf '%s' '$line' | jq -r '.orphaned'"
  [ "$output" = "1" ]
}

# =============================================================================
# --apply guards
# =============================================================================

@test "pair reconcile --apply: no repair executor is refused" {
  _write_ledger; _write_snapshot
  run bash "$PAIR_SH" reconcile cons --tier=live --apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"NO-REPAIR-EXECUTOR"* ]]
}

@test "pair reconcile --apply: repairs only the repairable, never the orphan" {
  _write_ledger; _write_snapshot
  LOG="${TMP}/repairs.log"
  run bash "$PAIR_SH" reconcile cons --tier=live --apply \
      --repair-cmd="echo >> ${LOG}" --confirm=RECONCILE-APPLY
  # Still non-zero: an unrepairable orphan remains (human-gated).
  [ "$status" -ne 0 ]
  [ -f "$LOG" ]
  [ "$(wc -l < "$LOG")" -eq 1 ]
}

@test "pair reconcile --apply: a coupled tier without the typed confirm is refused" {
  _write_ledger; _write_snapshot
  run bash "$PAIR_SH" reconcile cons --tier=live --apply --repair-cmd="true"
  [ "$status" -ne 0 ]
  [[ "$output" == *"CONFIRM"* ]]
}

@test "pair reconcile --apply: a failing repair executor is reported, not swallowed" {
  _write_ledger; _write_snapshot
  run bash "$PAIR_SH" reconcile cons --tier=live --apply \
      --repair-cmd="exit 4" --confirm=RECONCILE-APPLY
  [ "$status" -ne 0 ]
  [[ "$output" == *"REPAIR-FAILED"* ]]
}

@test "pair reconcile: dry-run is the default and writes nothing" {
  _write_ledger; _write_snapshot
  before="$(find "$NWP_PAIR_STATE_DIR" -type f | LC_ALL=C sort | md5sum)"
  run bash "$PAIR_SH" reconcile cons --tier=live
  [ "$status" -ne 0 ]
  after="$(find "$NWP_PAIR_STATE_DIR" -type f | LC_ALL=C sort | md5sum)"
  [ "$before" = "$after" ]
}
