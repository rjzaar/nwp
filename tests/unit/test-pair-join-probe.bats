#!/usr/bin/env bats
# nwp/ops#83 — join-integrity probe (pl pair-smoke --join). Offline: provider
# side resolved from a ledger fixture, consumer side from a literal idnumber.
# Uses the REAL ssc pair contract (coupled) shipped in pairs/.

SMOKE_SH="${BATS_TEST_DIRNAME}/../../scripts/commands/pair-smoke.sh"
LEDGER_SH="${BATS_TEST_DIRNAME}/../../scripts/f26/nwc-identity-ledger.sh"

setup() {
  TEST_TMP=$(mktemp -d)
  export NWP_PAIR_STATE_DIR="${TEST_TMP}/state"
  mkdir -p "${NWP_PAIR_STATE_DIR}"
  LED="${TEST_TMP}/l.jsonl"
  printf 'ff1e2312\t2\talice@e.test\t100\n' > "${TEST_TMP}/r.tsv"
  bash "$LEDGER_SH" dump --ledger="$LED" --rows-from="${TEST_TMP}/r.tsv" >/dev/null
}
teardown() { rm -rf "${TEST_TMP}"; unset NWP_PAIR_STATE_DIR; }

@test "GREEN when nwc holds the uuid AND mdl idnumber == uuid" {
  run bash "$SMOKE_SH" ssc --tier=live --join-uuid=ff1e2312 --nwc-ledger="$LED" --mdl-idnumber=ff1e2312
  [ "$status" -eq 0 ]
  [[ "$output" == *"JOIN-integrity GREEN"* ]]
  [ "$(cat "${NWP_PAIR_STATE_DIR}/ssc.live.rag")" = "green" ]
}

@test "RED when the Moodle idnumber does not match the uuid (broken join)" {
  run bash "$SMOKE_SH" ssc --tier=live --join-uuid=ff1e2312 --nwc-ledger="$LED" --mdl-idnumber=WRONG
  [ "$status" -ne 0 ]
  [[ "$output" == *"does NOT resolve"* || "$output" == *"UID-lock does NOT resolve"* ]]
  [ "$(cat "${NWP_PAIR_STATE_DIR}/ssc.live.rag")" = "red" ]
}

@test "RED when the uuid is absent on the provider (severed identity)" {
  run bash "$SMOKE_SH" ssc --tier=live --join-uuid=NOPE --nwc-ledger="$LED" --mdl-idnumber=NOPE
  [ "$status" -ne 0 ]
  [[ "$output" == *"does NOT resolve to any nwc account"* ]]
  [ "$(cat "${NWP_PAIR_STATE_DIR}/ssc.live.rag")" = "red" ]
}

@test "AMBER (not GREEN) when no Moodle resolver is supplied — half check only" {
  run bash "$SMOKE_SH" ssc --tier=live --join-uuid=ff1e2312 --nwc-ledger="$LED"
  [ "$status" -eq 0 ]
  [[ "$output" == *"half-verified"* ]]
  [ "$(cat "${NWP_PAIR_STATE_DIR}/ssc.live.rag")" = "amber" ]
}

@test "--join without a uuid is refused" {
  run bash "$SMOKE_SH" ssc --tier=live --join
  [ "$status" -ne 0 ]
  [[ "$output" == *"needs a known uuid"* ]]
}
