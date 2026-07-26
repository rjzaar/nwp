#!/usr/bin/env bats
# Item 2 (oversight-honesty): a backup's FRESHNESS is not its INTEGRITY.
#
# Defect this locks down: both `sweep_latest_backup_epoch` (backup.sh) and
# `check_missing_backups` (todo-checks.sh) picked the newest file by mtime and
# stopped there. A 0-byte `.sql.gz`, or a truncated gzip, therefore reported
# FRESH — and because it reported fresh it ALSO suppressed the next `pl backup`
# sweep and the BAK todo for another 7 days. The one artifact you cannot restore
# from is the one that convinces the system it does not need another.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../.."
  TMP="$BATS_TEST_TMPDIR/bak"
  mkdir -p "$TMP/backups"
  # shellcheck source=/dev/null
  source "$ROOT/lib/backup-integrity.sh" 2>/dev/null || true
}

# Incompressible payload, so the gzip is comfortably over BACKUP_MIN_BYTES —
# a real dump is KBs+, and a fixture that compresses to 69 bytes would only
# exercise the size gate.
_good_gz() { { printf 'DROP TABLE IF EXISTS x;\n'; head -c 20000 /dev/urandom; } | gzip > "$1"; }

@test "a valid gzip dump passes integrity" {
  _good_gz "$TMP/backups/ok.sql.gz"
  run backup_artifact_integrity "$TMP/backups/ok.sql.gz"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "a 0-byte .sql.gz is CORRUPT, not fresh" {
  : > "$TMP/backups/empty.sql.gz"
  run backup_artifact_integrity "$TMP/backups/empty.sql.gz"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"empty"* ]] || [[ "$output" == *"too small"* ]]
}

@test "a suspiciously tiny (non-empty) .sql.gz is CORRUPT" {
  printf 'x' > "$TMP/backups/tiny.sql.gz"
  run backup_artifact_integrity "$TMP/backups/tiny.sql.gz"
  [ "$status" -ne 127 ]   # non-vacuity: 127 = the helper does not exist
  [ "$status" -ne 0 ]
}

@test "a truncated gzip is CORRUPT" {
  _good_gz "$TMP/backups/trunc.sql.gz"
  local size; size=$(stat -c%s "$TMP/backups/trunc.sql.gz")
  truncate -s $((size / 2)) "$TMP/backups/trunc.sql.gz"
  run backup_artifact_integrity "$TMP/backups/trunc.sql.gz"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"gzip"* ]]
}

@test "a non-gzip file named .sql.gz is CORRUPT" {
  head -c 5000 /dev/urandom > "$TMP/backups/notgz.sql.gz"
  run backup_artifact_integrity "$TMP/backups/notgz.sql.gz"
  [ "$status" -ne 127 ]   # non-vacuity: 127 = the helper does not exist
  [ "$status" -ne 0 ]
}

@test "a checksum mismatch against an existing .sha256 sidecar is CORRUPT" {
  _good_gz "$TMP/backups/sum.sql.gz"
  ( cd "$TMP/backups" && sha256sum sum.sql.gz > sum.sql.gz.sha256 )
  # Rewrite the artifact so the recorded digest no longer matches.
  _good_gz "$TMP/backups/sum.sql.gz"
  printf 'extra' | gzip >> "$TMP/backups/sum.sql.gz"
  run backup_artifact_integrity "$TMP/backups/sum.sql.gz"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"checksum"* ]]
}

@test "a matching .sha256 sidecar passes" {
  _good_gz "$TMP/backups/sum2.sql.gz"
  ( cd "$TMP/backups" && sha256sum sum2.sql.gz > sum2.sql.gz.sha256 )
  run backup_artifact_integrity "$TMP/backups/sum2.sql.gz"
  echo "$output"
  [ "$status" -eq 0 ]
}

# --- the consumers ------------------------------------------------------------

@test "backup_latest_good_epoch ignores a corrupt newest artifact" {
  _good_gz "$TMP/backups/old.sql.gz"
  touch -d '3 days ago' "$TMP/backups/old.sql.gz"
  : > "$TMP/backups/new.sql.gz"   # newest, but 0 bytes
  run backup_latest_good_epoch "$TMP/backups"
  echo "$output"
  [ "$status" -eq 0 ]
  # must be the OLD (valid) one, i.e. ~3 days ago, not now
  local now; now=$(date +%s)
  [ "$((now - output))" -gt 100000 ]
}

@test "check_missing_backups files BAK-corrupt for a 0-byte newest dump" {
  export TODO_CHECKS_PROJECT_ROOT="$TMP/proj"
  mkdir -p "$TMP/proj/sites/demo/backups"
  : > "$TMP/proj/sites/demo/backups/latest.sql.gz"
  cat > "$TMP/proj/nwp.yml" <<EOF
settings:
  todo:
    categories: {}
    thresholds: {}
sites:
  demo:
    directory: $TMP/proj/sites/demo
EOF
  run bash -c '
    set +e
    source "'"$ROOT"'/lib/yaml-write.sh"
    source "'"$ROOT"'/lib/todo-checks.sh"
    TODO_CHECKS_PROJECT_ROOT="'"$TMP"'/proj"
    TODO_CONFIG_FILE="'"$TMP"'/proj/nwp.yml"
    todo_clear_items
    check_missing_backups
    printf "%s\n" "${TODO_ITEMS[@]:-}"
  '
  echo "$output"
  [[ "$output" == *"BAK-corrupt"* ]]
}

@test "check_missing_backups stays quiet for a valid recent dump" {
  export TODO_CHECKS_PROJECT_ROOT="$TMP/proj2"
  mkdir -p "$TMP/proj2/sites/demo/backups"
  _good_gz "$TMP/proj2/sites/demo/backups/latest.sql.gz"
  cat > "$TMP/proj2/nwp.yml" <<EOF
settings:
  todo:
    categories: {}
    thresholds: {}
sites:
  demo:
    directory: $TMP/proj2/sites/demo
EOF
  run bash -c '
    set +e
    source "'"$ROOT"'/lib/yaml-write.sh"
    source "'"$ROOT"'/lib/todo-checks.sh"
    TODO_CHECKS_PROJECT_ROOT="'"$TMP"'/proj2"
    TODO_CONFIG_FILE="'"$TMP"'/proj2/nwp.yml"
    todo_clear_items
    check_missing_backups
    printf "%s\n" "${TODO_ITEMS[@]:-}"
  '
  echo "$output"
  # Non-vacuity guard: prove the site loop really ran, or "no BAK item" is true
  # only because yaml_get_all_sites yielded nothing.
  run bash -c '
    source "'"$ROOT"'/lib/yaml-write.sh"
    yaml_get_all_sites "'"$TMP"'/proj2/nwp.yml"'
  [[ "$output" == *"demo"* ]]
}
