#!/usr/bin/env bats
# Item 2 — `pl restore --remote`, the missing inverse of `pl backup --remote`.
#
# Before this landed, `grep -c 'ssh ' scripts/commands/restore.sh` returned 0:
# there was no way to put a verified DR artifact back onto a live host, even
# though the consolidation-arc rollback registry named `pl restore <artifact>`
# as the reversal command for CP3 and CP16 (the live nwc and ssc snapshots).
#
# These cases pin the SAFETY ORDERING, which is the part that is easy to get
# wrong and impossible to notice once it is wrong: integrity is checked before
# any gate, prompt, or remote write. A restore from a corrupt artifact is worse
# than no restore — it destroys live state and does not replace it.

setup() {
  REPO_ROOT="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
  PL="${REPO_ROOT}/pl"
  FIX="${BATS_TEST_TMPDIR}/backups"
  mkdir -p "$FIX"
  SITE="zzrrfixture"
  NAME="${SITE}-remote-20260726T094256"
  export NWP_BACKUP_DIR="$FIX"
  export NWP_STATE_DIR="${BATS_TEST_TMPDIR}/state"
}

# Build a well-formed artifact set: tar + dump + sidecars + manifest.
_make_artifact() {
  printf 'webroot-bytes\n' | gzip > "${FIX}/${NAME}.tar.gz"
  printf 'db-bytes\n'      | gzip > "${FIX}/${NAME}.sql.gz"

  local wsha dsha
  wsha=$(sha256sum "${FIX}/${NAME}.tar.gz" | awk '{print $1}')
  dsha=$(sha256sum "${FIX}/${NAME}.sql.gz" | awk '{print $1}')

  printf '%s  %s.tar.gz\n' "$wsha" "$NAME" > "${FIX}/${NAME}.tar.gz.sha256"
  printf '%s  %s.sql.gz\n' "$dsha" "$NAME" > "${FIX}/${NAME}.sql.gz.sha256"

  cat > "${FIX}/${NAME}.manifest.json" <<EOF
{
  "site": "${SITE}",
  "backup_name": "${NAME}",
  "remote": true,
  "remote_host": "gitlab@198.51.100.1",
  "project_type": "moodle",
  "db_only": false,
  "files_only": false,
  "webroot_sha256": "${wsha}",
  "db_sha256": "${dsha}"
}
EOF
}

_run_restore() {
  run "$PL" restore "$SITE" --remote --dry-run \
      --artifact="${FIX}/${NAME}.manifest.json" "$@"
}

################################################################################

@test "a corrupt artifact is refused, and refused BEFORE any plan is offered" {
  _make_artifact
  # Flip the bytes without touching the sidecar — exactly what bit-rot or a
  # truncated transfer looks like.
  printf 'tampered\n' | gzip > "${FIX}/${NAME}.tar.gz"

  _run_restore

  [ "$status" -ne 0 ]
  [[ "$output" == *"MISMATCH"* ]]
  # The operator must never be shown a plan for a restore we cannot safely do.
  [[ "$output" != *"maintenance mode ON"* ]]
  [[ "$output" != *"Re-run with --execute"* ]]
  # And it must STOP, not merely complain on the way past. Asserting only
  # "status != 0" would pass even if the mismatch were downgraded to a warning
  # and the run failed later for an unrelated reason — verified by mutating
  # the sha check to `return 0` and watching this line, not the status line,
  # be the one that holds.
  [[ "$output" != *"verified ${NAME}.tar.gz"* ]]
  [[ "$output" != *"No live server configured"* ]]
}

@test "an artifact with no integrity record at all is refused" {
  _make_artifact
  rm -f "${FIX}/${NAME}.tar.gz.sha256" "${FIX}/${NAME}.sql.gz.sha256" \
        "${FIX}/${NAME}.manifest.json"

  run "$PL" restore "$SITE" --remote --dry-run \
      --artifact="${FIX}/${NAME}.tar.gz"

  [ "$status" -ne 0 ]
  [[ "$output" == *"no sha256 sidecar"* ]] || [[ "$output" == *"refusing"* ]]
}

@test "integrity is checked before the target host is even resolved" {
  _make_artifact
  printf 'tampered\n' | gzip > "${FIX}/${NAME}.sql.gz"

  _run_restore

  [ "$status" -ne 0 ]
  [[ "$output" == *"MISMATCH"* ]]
  # Host resolution failure must NOT be what stopped us — the integrity check
  # must fire first, so ordering regressions are visible.
  [[ "$output" != *"No live server configured"* ]]
}

@test "a verified artifact passes the integrity stage and then fails closed with no target" {
  _make_artifact

  _run_restore

  [[ "$output" == *"verified ${NAME}.tar.gz"* ]]
  [[ "$output" == *"verified ${NAME}.sql.gz"* ]]
  # No live server is configured for a fixture site, so it must refuse rather
  # than invent a target.
  [ "$status" -ne 0 ]
  [[ "$output" == *"No live server configured"* ]]
}

@test "--db-only skips webroot verification but still verifies the dump" {
  _make_artifact
  # Corrupt the tarball only; a --db-only restore never touches it.
  printf 'tampered\n' | gzip > "${FIX}/${NAME}.tar.gz"

  _run_restore --db-only

  [[ "$output" == *"verified ${NAME}.sql.gz"* ]]
  [[ "$output" != *"MISMATCH"* ]]
}

@test "--db-only and --files-only together are rejected" {
  _make_artifact

  _run_restore --db-only --files-only

  [ "$status" -ne 0 ]
  [[ "$output" == *"mutually exclusive"* ]]
}

@test "restore --remote defaults to a dry run (never writes without --execute)" {
  # Guard against a future refactor flipping the default. The verb must not
  # reach any gate or write path without --execute.
  run grep -n 'apply="false"' "${REPO_ROOT}/lib/restore-remote.sh"
  [ "$status" -eq 0 ]
  run grep -n '\-\-execute)    apply="true"' "${REPO_ROOT}/lib/restore-remote.sh"
  [ "$status" -eq 0 ]
}
