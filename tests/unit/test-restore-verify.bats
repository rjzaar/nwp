#!/usr/bin/env bats
# restore.sh integrity verification (report P2 gap).
#
# Before restore.sh extracts/imports a backup artifact it must verify the
# artifact against its `.sha256` sidecar (sha256sum -c) and sanity-check a
# sibling manifest.json — FAIL-CLOSED: a missing or mismatched sidecar aborts.
# --skip-verify (off by default) is the explicit escape hatch.
#
# These tests source restore.sh and exercise the verification helpers directly
# with tiny on-disk fixtures whose sha256 we control.

RESTORE_SH="${BATS_TEST_DIRNAME}/../../scripts/commands/restore.sh"

setup() {
  TEST_TMP=$(mktemp -d)
  # Source the script's functions. It sources lib/ui.sh etc.; main() only runs
  # under direct execution, not when sourced.
  source "$RESTORE_SH" >/dev/null 2>&1
  # Neutralise pipefail noise from the sourced environment for the assertions.
  set +e
}

teardown() {
  rm -rf "${TEST_TMP}"
}

# Build a valid backup artifact + matching .sha256 sidecar in TEST_TMP.
# Echoes the artifact path. Arg1 = filename (default backup.sql.gz).
make_good_artifact() {
  local name="${1:-nwp-remote-20260101T120000.sql.gz}"
  local art="${TEST_TMP}/${name}"
  printf 'fake-backup-payload\n' > "$art"
  ( cd "$TEST_TMP" && sha256sum "$name" > "${name}.sha256" )
  echo "$art"
}

################################################################################
# Sidecar verification
################################################################################

@test "verify passes on a good sidecar" {
  local art
  art=$(make_good_artifact)
  SKIP_VERIFY=false
  run verify_backup_artifact "$art"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Integrity verified"* ]]
}

@test "verify aborts (fail-closed) when the sidecar is missing" {
  local art="${TEST_TMP}/nwp-remote-20260101T120000.sql.gz"
  printf 'payload\n' > "$art"   # note: no .sha256 sidecar
  SKIP_VERIFY=false
  run verify_backup_artifact "$art"
  [ "$status" -ne 0 ]
  [[ "$output" == *"sidecar missing"* ]]
}

@test "verify aborts (fail-closed) on a tampered artifact (sha mismatch)" {
  local art
  art=$(make_good_artifact)
  # Tamper with the payload AFTER the sidecar was written.
  printf 'tampered-evil-payload\n' > "$art"
  SKIP_VERIFY=false
  run verify_backup_artifact "$art"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAILED"* ]] || [[ "$output" == *"mismatch"* ]]
}

@test "verify aborts (fail-closed) on a corrupted sidecar (wrong recorded hash)" {
  local art
  art=$(make_good_artifact)
  # Overwrite the sidecar with a wrong-but-well-formed hash line.
  printf '%064d  %s\n' 0 "$(basename "$art")" > "${art}.sha256"
  SKIP_VERIFY=false
  run verify_backup_artifact "$art"
  [ "$status" -ne 0 ]
}

@test "--skip-verify bypasses the check (loud warning, still returns 0)" {
  local art="${TEST_TMP}/nwp-remote-20260101T120000.sql.gz"
  printf 'payload\n' > "$art"   # deliberately NO sidecar
  SKIP_VERIFY=true
  run verify_backup_artifact "$art"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIPPED"* ]]
}

@test "verify aborts when the artifact itself is missing" {
  SKIP_VERIFY=false
  run verify_backup_artifact "${TEST_TMP}/does-not-exist.sql.gz"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

################################################################################
# Manifest sanity-check
################################################################################

@test "verify passes when a well-formed manifest.json is present" {
  local art
  art=$(make_good_artifact "nwp-remote-20260101T120000.sql.gz")
  printf '{ "site": "nwp", "backup_name": "nwp-remote-20260101T120000" }\n' \
    > "${TEST_TMP}/nwp-remote-20260101T120000.manifest.json"
  SKIP_VERIFY=false
  run verify_backup_artifact "$art"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Manifest sane"* ]]
}

@test "verify aborts (fail-closed) on a corrupt (non-JSON) manifest" {
  local art
  art=$(make_good_artifact "nwp-remote-20260101T120000.sql.gz")
  printf 'this is <<< not json >>>\n' \
    > "${TEST_TMP}/nwp-remote-20260101T120000.manifest.json"
  SKIP_VERIFY=false
  run verify_backup_artifact "$art"
  [ "$status" -ne 0 ]
  [[ "$output" == *"manifest"* ]]
}

@test "verify_backup_manifest accepts valid and rejects invalid JSON" {
  printf '{"a":1}\n' > "${TEST_TMP}/ok.json"
  printf 'nope\n'    > "${TEST_TMP}/bad.json"
  : > "${TEST_TMP}/empty.json"
  run verify_backup_manifest "${TEST_TMP}/ok.json";    [ "$status" -eq 0 ]
  run verify_backup_manifest "${TEST_TMP}/bad.json";   [ "$status" -ne 0 ]
  run verify_backup_manifest "${TEST_TMP}/empty.json"; [ "$status" -ne 0 ]
}

################################################################################
# Backup-set gate (DB + optional files archive)
################################################################################

@test "verify_backup_set validates both the DB and the files archive" {
  local db tar
  db=$(make_good_artifact "nwp-remote-20260101T120000.sql.gz")
  tar=$(make_good_artifact "nwp-remote-20260101T120000.tar.gz")
  SKIP_VERIFY=false
  INTEGRITY_VERIFIED=false
  run verify_backup_set "$db" false
  [ "$status" -eq 0 ]
}

@test "verify_backup_set fails the whole set if the files archive is tampered" {
  local db tar
  db=$(make_good_artifact "nwp-remote-20260101T120000.sql.gz")
  tar=$(make_good_artifact "nwp-remote-20260101T120000.tar.gz")
  printf 'tampered\n' > "$tar"   # break the tar after sidecar written
  SKIP_VERIFY=false
  INTEGRITY_VERIFIED=false
  run verify_backup_set "$db" false
  [ "$status" -ne 0 ]
}

@test "verify_backup_set (db-only) ignores a bad files archive" {
  local db tar
  db=$(make_good_artifact "nwp-remote-20260101T120000.sql.gz")
  tar=$(make_good_artifact "nwp-remote-20260101T120000.tar.gz")
  printf 'tampered\n' > "$tar"   # a broken tar must not matter for db-only
  SKIP_VERIFY=false
  INTEGRITY_VERIFIED=false
  run verify_backup_set "$db" true
  [ "$status" -eq 0 ]
}

################################################################################
# Wiring / static invariants
################################################################################

@test "restore.sh parses (bash -n) with the verification additions" {
  run bash -n "$RESTORE_SH"
  [ "$status" -eq 0 ]
}

@test "--help documents --skip-verify" {
  run bash "$RESTORE_SH" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--skip-verify"* ]]
}

@test "up-front verification runs before the destructive step 2" {
  # The verify_backup_set call must appear before 'Validate Destination'.
  local verify_line del_line
  verify_line=$(grep -n 'verify_backup_set "\$BACKUP_FILE"' "$RESTORE_SH" | head -1 | cut -d: -f1)
  del_line=$(grep -n 'Step 2: Validate Destination' "$RESTORE_SH" | head -1 | cut -d: -f1)
  [ -n "$verify_line" ]
  [ -n "$del_line" ]
  [ "$verify_line" -lt "$del_line" ]
}
