#!/usr/bin/env bats
# Item 2 — recovery-path-repair.
#
# These tests exist because `pl rollback` ADVERTISED a recovery point it could
# not use. `pl rollback list ssc` showed today's two live Art.9 snapshots;
# `pl rollback execute ssc live --dry-run` answered "ERROR: Backup not found:".
# The generic recovery verb was structurally unable to restore the live Moodle
# instance carrying the consent gate.
#
# Every case below was observed RED against the pre-fix tree. See the MR
# description for the captured red output.

setup() {
  REPO_ROOT="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
  PL="${REPO_ROOT}/pl"

  # Post-fix the ledger lives under NWP_STATE_DIR; pre-fix it was pinned to
  # scripts/commands/.rollback inside whatever checkout ran the command. The
  # fixture is written to BOTH so this same file is runnable against either
  # tree — that is what makes the recorded RED trustworthy.
  export NWP_STATE_DIR="${BATS_TEST_TMPDIR}/state"
  NEW_LEDGER="${NWP_STATE_DIR}/rollback"
  OLD_LEDGER="${REPO_ROOT}/scripts/commands/.rollback"
  mkdir -p "$NEW_LEDGER" "$OLD_LEDGER"

  SITE="zzrbfixture"
  # Never prompt, never touch a real host.
  export AUTO_CONFIRM=false
}

teardown() {
  # Remove only what this test created, by exact site prefix.
  rm -f "${OLD_LEDGER}/${SITE}_"*.json
  rm -rf "${NWP_STATE_DIR}"
}

# Write a rollback entry of an arbitrary type into both ledger locations.
_write_entry() {
  local env="$1" ts="$2" type="$3"
  local body
  body=$(cat <<EOF
{
    "sitename": "${SITE}",
    "environment": "${env}",
    "timestamp": "${ts}",
    "type": "${type}",
    "remote": {
        "host": "198.51.100.1",
        "ssh_user": "gitlab",
        "snapshot_db": "/home/gitlab/nwp-snapshot-${SITE}-moodledb-${ts}.sql.gz",
        "snapshot_plugins": "/home/gitlab/nwp-snapshot-${SITE}-plugins-${ts}.tar.gz",
        "moodle_root": "/var/www/${SITE}",
        "plugins": "mod/depthcontent"
    },
    "commit": "",
    "status": "active"
}
EOF
)
  printf '%s\n' "$body" > "${NEW_LEDGER}/${SITE}_${env}_${ts}.json"
  printf '%s\n' "$body" > "${OLD_LEDGER}/${SITE}_${env}_${ts}.json"
}

################################################################################
# Case 1 — the real defect: a moodle-remote entry must reach the Moodle arm.
################################################################################

@test "moodle-remote entry dispatches to the Moodle rollback arm, not the local-DDEV branch" {
  _write_entry live 20260726-131526 moodle-remote

  run "$PL" rollback execute "$SITE" live --dry-run

  # RED (pre-fix): status 1, output contains "Backup not found:" because the
  # dispatcher only matched type == "remote" and fell through to the legacy
  # local branch, which read a backup_path key that moodle-remote never has.
  [ "$status" -eq 0 ]
  [[ "$output" != *"Backup not found"* ]]
  # The Moodle arm prints its restore plan.
  [[ "$output" == *"maintenance --enable"* ]]
  [[ "$output" == *"purge_caches.php"* ]]
}

################################################################################
# Case 2 — fail closed. An unknown type must never silently take a code path
# that was written for a different artifact shape.
################################################################################

@test "unknown rollback type fails closed instead of falling through to the local branch" {
  _write_entry live 20260726-140000 zzz-unknown

  run "$PL" rollback execute "$SITE" live --dry-run

  # RED (pre-fix): the else-branch ran the legacy local-DDEV restore against an
  # entry it did not understand.
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown rollback type"* ]]
  # It must name the types it does know, so the operator can act.
  [[ "$output" == *"moodle-remote"* ]]
}

################################################################################
# Case 3 — the documented --env flag must actually do something.
################################################################################

@test "--env=live and positional live produce identical dispatch" {
  _write_entry live 20260726-131526 moodle-remote

  run "$PL" rollback execute --env=live "$SITE" --dry-run
  local flag_status="$status"
  local flag_out="$output"

  run "$PL" rollback execute "$SITE" live --dry-run
  local pos_status="$status"
  local pos_out="$output"

  # RED (pre-fix): --env was parsed into $ENV and then referenced nowhere, so
  # the flag form defaulted to the tier "prod", which no site has.
  [ "$flag_status" -eq "$pos_status" ]
  [ "$flag_out" = "$pos_out" ]
  [[ "$flag_out" != *"No rollback point found"* ]]
}

################################################################################
# Case 4 — the tier default must come from reality, not a hardcoded "prod".
################################################################################

@test "execute with no tier uses a tier that has entries rather than defaulting to prod" {
  _write_entry live 20260726-131526 moodle-remote

  run "$PL" rollback execute "$SITE" --dry-run

  # RED (pre-fix): defaulted to "prod"; no site has a prod tier, so the only
  # recovery point present was invisible to the verb.
  [ "$status" -eq 0 ]
  [[ "$output" == *"maintenance --enable"* ]]
}

################################################################################
# Case 6 — the rollback REGISTRY must be mechanically checkable.
#
# The registry is the human-facing "how do I undo checkpoint N" ledger. Nothing
# validated it, so rows drifted: at the time this landed, CP14 quoted a sha256
# that no longer matched the artifact it named, and CP12 named a .bundle with
# no integrity record at all. A recovery ledger nobody checks is wrong exactly
# when it is needed.
################################################################################

@test "registry check flags a row whose recorded sha no longer matches the artifact" {
  local reg="${BATS_TEST_TMPDIR}/reg.md"
  local art="${BATS_TEST_TMPDIR}/thing.tar.gz"
  printf 'contents\n' | gzip > "$art"
  local real; real=$(sha256sum "$art" | awk '{print $1}')
  printf '%s  thing.tar.gz\n' "$real" > "${art}.sha256"

  {
    echo '| # | When | Checkpoint | Artifact(s) + sha | Git ref | Restore command |'
    echo '|---|------|-----------|-------------------|---------|-----------------|'
    echo "| CP99 | 2026-07-26 | fixture | \`${art}\` (sha \`deadbeef…\`) | — | true |"
  } > "$reg"

  NWP_ROLLBACK_REGISTRY="$reg" run "$PL" rollback registry check

  [ "$status" -ne 0 ]
  [[ "$output" == *"STALE"* ]]
}

@test "registry check refuses to report clean when it parsed no rows" {
  local reg="${BATS_TEST_TMPDIR}/empty.md"
  printf '# Registry\n\nNo rows here.\n' > "$reg"

  NWP_ROLLBACK_REGISTRY="$reg" run "$PL" rollback registry check

  # A parser that scans nothing and prints OK is the vacuous pass this whole
  # programme exists to eliminate.
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot verify"* ]]
}

@test "register refuses an artifact that does not resolve" {
  local reg="${BATS_TEST_TMPDIR}/reg2.md"
  {
    echo '| # | When | Checkpoint | Artifact(s) + sha | Git ref | Restore command |'
    echo '|---|------|-----------|-------------------|---------|-----------------|'
  } > "$reg"

  NWP_ROLLBACK_REGISTRY="$reg" run "$PL" rollback register \
      --cp=CP99 --what=fixture --artifact=/nonexistent/nope.tar.gz

  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
  # And nothing may be appended.
  run grep -c '^| CP99' "$reg"
  [ "$output" = "0" ]
}

################################################################################
# Case 5 — the ledger must survive the worktree it was written from.
################################################################################

@test "a rollback point recorded from a worktree is visible from another checkout" {
  _write_entry live 20260726-131526 moodle-remote
  # Simulate the recording checkout going away: only the state-dir copy remains.
  rm -f "${OLD_LEDGER}/${SITE}_live_20260726-131526.json"

  run "$PL" rollback list "$SITE"

  # RED (pre-fix): ROLLBACK_DIR was ${SCRIPT_DIR}/.rollback — 33 such ledgers
  # exist, one per worktree. Deleting the worktree deleted the only pointer to
  # the on-host snapshot.
  [ "$status" -eq 0 ]
  [[ "$output" == *"${SITE}"* ]]
  [[ "$output" != *"No rollback points available"* ]]
}
