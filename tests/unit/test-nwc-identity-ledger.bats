#!/usr/bin/env bats
# nwp/ops#83 — provider identity ledger (scripts/f26/nwc-identity-ledger.sh).
# Offline: rows come from --rows-from TSV fixtures (no drush / DB / network).

LEDGER_SH="${BATS_TEST_DIRNAME}/../../scripts/f26/nwc-identity-ledger.sh"

setup() {
  TEST_TMP=$(mktemp -d)
  LED="${TEST_TMP}/ssc.provider-identity.jsonl"
  R1="${TEST_TMP}/rows1.tsv"
  printf 'uu-a\t2\talice@e.test\t100\nuu-b\t3\tbob@e.test\t200\n' > "$R1"
}
teardown() { rm -rf "${TEST_TMP}"; }

@test "dump writes an append-only, hash-chained snapshot" {
  run bash "$LEDGER_SH" dump --ledger="$LED" --rows-from="$R1"
  [ "$status" -eq 0 ]
  [ -f "$LED" ]
  grep -q '"t":"snap"' "$LED"
  [ "$(grep -c '"t":"rec"' "$LED")" -eq 2 ]
}

@test "verify GREEN when the DB matches the last snapshot" {
  bash "$LEDGER_SH" dump --ledger="$LED" --rows-from="$R1"
  run bash "$LEDGER_SH" verify --ledger="$LED" --rows-from="$R1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"GREEN"* ]]
}

@test "verify flags a uuid→uid divergence (exit 3)" {
  bash "$LEDGER_SH" dump --ledger="$LED" --rows-from="$R1"
  printf 'uu-a\t9\talice@e.test\t100\nuu-b\t3\tbob@e.test\t200\n' > "${TEST_TMP}/r2.tsv"
  run bash "$LEDGER_SH" verify --ledger="$LED" --rows-from="${TEST_TMP}/r2.tsv"
  [ "$status" -eq 3 ]
  [[ "$output" == *"uid changed"* ]]
}

@test "verify flags a uuid→email divergence (exit 3)" {
  bash "$LEDGER_SH" dump --ledger="$LED" --rows-from="$R1"
  printf 'uu-a\t2\tCHANGED@e.test\t100\nuu-b\t3\tbob@e.test\t200\n' > "${TEST_TMP}/r2.tsv"
  run bash "$LEDGER_SH" verify --ledger="$LED" --rows-from="${TEST_TMP}/r2.tsv"
  [ "$status" -eq 3 ]
  [[ "$output" == *"email changed"* ]]
}

@test "verify flags a dropped/orphaned uuid (exit 3)" {
  bash "$LEDGER_SH" dump --ledger="$LED" --rows-from="$R1"
  printf 'uu-a\t2\talice@e.test\t100\n' > "${TEST_TMP}/r2.tsv"
  run bash "$LEDGER_SH" verify --ledger="$LED" --rows-from="${TEST_TMP}/r2.tsv"
  [ "$status" -eq 3 ]
  [[ "$output" == *"MISSING from current DB"* ]]
}

@test "verify FAILS CLOSED on a tampered/truncated chain (exit 2)" {
  bash "$LEDGER_SH" dump --ledger="$LED" --rows-from="$R1"
  sed -i 's/"uid":2/"uid":7/' "$LED"    # tamper a record without re-hashing
  run bash "$LEDGER_SH" verify --ledger="$LED" --no-db
  [ "$status" -eq 2 ]
  [[ "$output" == *"INTEGRITY FAIL"* ]]
}

@test "verify FAILS CLOSED on a missing ledger (exit 2)" {
  run bash "$LEDGER_SH" verify --ledger="${TEST_TMP}/nope.jsonl" --no-db
  [ "$status" -eq 2 ]
}

@test "two dumps chain: second snapshot's prev == first snapshot's sha256" {
  bash "$LEDGER_SH" dump --ledger="$LED" --rows-from="$R1"
  bash "$LEDGER_SH" dump --ledger="$LED" --rows-from="$R1"
  run bash "$LEDGER_SH" verify --ledger="$LED" --no-db
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 snapshot(s)"* ]]
}

@test "--hash-email stores no plaintext email (PII reduction)" {
  bash "$LEDGER_SH" dump --ledger="$LED" --rows-from="$R1" --hash-email
  grep -q 'email_sha256' "$LED"
  ! grep -q 'alice@e.test' "$LED"
}
