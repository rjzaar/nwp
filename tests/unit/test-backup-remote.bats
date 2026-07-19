#!/usr/bin/env bats
# PL-STG2LIVE-INTEGRATION-DESIGN-2026-07-19 §6 P0-3 —
# `pl backup <site> --remote`: guarded remote pre-deploy snapshot.
#
# A mix of behavioural assertions (cheap paths that need no live host) and
# static grep/awk assertions on the script text (the guard invariants that
# only fire against a real live host), in the style of the repo's other
# hardening tests (tests/unit/test-*.bats).

BACKUP_SH="${BATS_TEST_DIRNAME}/../../scripts/commands/backup.sh"

setup() {
  TEST_TMP=$(mktemp -d)
}

teardown() {
  rm -rf "${TEST_TMP}"
}

################################################################################
# Behavioural — reachable without a live host
################################################################################

@test "script parses (bash -n) with the --remote additions" {
  run bash -n "$BACKUP_SH"
  [ "$status" -eq 0 ]
}

@test "--help documents the --remote pre-deploy snapshot" {
  run bash "$BACKUP_SH" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--remote"* ]]
  [[ "$output" == *"PRE-DEPLOY"* ]]
}

@test "--remote refuses an empty server_ip (no provisioned live host)" {
  # An unknown site resolves no live.server_ip → must REFUSE, not proceed.
  run bash "$BACKUP_SH" --remote "no-such-site-xyz-$$"
  [ "$status" -ne 0 ]
  [[ "$output" == *"No live server configured"* ]] || [[ "$output" == *"Refusing --remote"* ]]
}

@test "--remote --db-only --files-only is rejected as mutually exclusive" {
  run bash "$BACKUP_SH" --remote --db-only --files-only "no-such-site-xyz-$$"
  [ "$status" -ne 0 ]
  [[ "$output" == *"mutually exclusive"* ]]
}

################################################################################
# Static — guard invariants that only fire against a real live host
################################################################################

@test "--remote dispatches to backup_remote, skipping resolve_project/DDEV" {
  # The remote branch in main() must run before any DDEV-local logic.
  grep -Eq 'if \[ "\$REMOTE" == "true" \]; then' "$BACKUP_SH"
  grep -q 'backup_remote "\$SITENAME"' "$BACKUP_SH"
  # backup_remote must NOT call resolve_project (that is the DDEV-local path).
  ! awk '/^backup_remote\(\)/{f=1} f&&/resolve_project/{print} /^backup_site\(\)/{f=0}' "$BACKUP_SH" | grep -q resolve_project
}

@test "backup_remote refuses on empty server_ip (fail-closed guard present)" {
  awk '/^backup_remote\(\)/{f=1} /^# Main backup function/{f=0} f' "$BACKUP_SH" \
    | grep -q 'if \[ -z "\$server_ip" \]'
  awk '/^backup_remote\(\)/{f=1} /^# Main backup function/{f=0} f' "$BACKUP_SH" \
    | grep -q 'Refusing --remote'
}

@test "backup_remote honours live.enabled == false" {
  awk '/^backup_remote\(\)/{f=1} /^# Main backup function/{f=0} f' "$BACKUP_SH" \
    | grep -q 'live_enabled" == "false"'
}

@test "files tar EXCLUDES uploads (files/ + private) but INCLUDES oauth-keys/auth.json" {
  local body
  body=$(awk '/^backup_remote\(\)/{f=1} /^# Main backup function/{f=0} f' "$BACKUP_SH")
  # excludes the huge uploads
  echo "$body" | grep -q 'sites/default/files'
  echo "$body" | grep -q -- '--exclude=./private'
  # the point of a pre-deploy backup: oauth-keys + auth.json are NOT excluded
  ! echo "$body" | grep -q -- '--exclude=.*oauth-keys'
  ! echo "$body" | grep -q -- '--exclude=.*auth.json'
  # and they are named as deliberately-kept in the impact/comment surface
  echo "$body" | grep -q 'oauth-keys'
  echo "$body" | grep -q 'auth.json'
}

@test "tar runs under sudo and -C remote_path (whole webroot)" {
  awk '/^backup_remote\(\)/{f=1} /^# Main backup function/{f=0} f' "$BACKUP_SH" \
    | grep -Eq '\$\{sudo_prefix\} tar czf ~/\$\{backup_name\}\.tar\.gz.*-C \$\{remote_path\} \.'
}

@test "sha256 sidecar: computed remote, pulled, re-verified local, fail-closed on mismatch" {
  local body
  body=$(awk '/^backup_pull_verified\(\)/{f=1} /^# Remote pre-deploy backup entry point/{f=0} f' "$BACKUP_SH")
  echo "$body" | grep -q 'sha256sum ~/'          # remote sha
  echo "$body" | grep -q 'sha256sum "\$local_path"'  # local re-verify
  echo "$body" | grep -q 'local_sha" != "\$remote_sha"'  # compare
  echo "$body" | grep -q 'MISMATCH'              # fail-closed message
  # mismatch removes the corrupt pull and returns non-zero
  echo "$body" | grep -q 'rm -f "\$local_path"'
  echo "$body" | grep -q 'return 1'
  # sidecar written in sha256sum -c compatible format
  echo "$body" | grep -q '\.sha256'
}

@test "manifest carries remote:true + remote_host + webroot_sha256 + db_sha256 + taken_at" {
  local body
  body=$(awk '/^write_remote_backup_manifest\(\)/{f=1} /^# Detect the remote docroot/{f=0} f' "$BACKUP_SH")
  echo "$body" | grep -q '"remote": true'
  echo "$body" | grep -q '"remote_host"'
  echo "$body" | grep -q '"webroot_sha256"'
  echo "$body" | grep -q '"db_sha256"'
  echo "$body" | grep -q '"taken_at"'
}

@test "Drupal vs Moodle DB dump path selection" {
  local body
  body=$(awk '/^backup_remote\(\)/{f=1} /^# Main backup function/{f=0} f' "$BACKUP_SH")
  # Moodle branch: dbname read via ABORT_AFTER_CONFIG, credential-free mysqldump
  echo "$body" | grep -q 'project_type" == "moodle"'
  echo "$body" | grep -q 'ABORT_AFTER_CONFIG'
  echo "$body" | grep -q 'mysqldump'
  # Drupal branch: drush sql:dump --gzip with the vendor/bin/drush fallback
  echo "$body" | grep -q 'drush sql:dump --gzip'
  echo "$body" | grep -q 'vendor/bin/drush'
}

@test "disk gate is fail-closed (<1GB refuses, unlike live_host_snapshot's WARN)" {
  local body
  body=$(awk '/^backup_remote\(\)/{f=1} /^# Main backup function/{f=0} f' "$BACKUP_SH")
  echo "$body" | grep -q '1048576'          # 1GB in KB
  echo "$body" | grep -q 'refusing remote backup'
}

@test "IMPACT report is rendered before the remote tar on a non-dry-run" {
  local body
  body=$(awk '/^backup_remote\(\)/{f=1} /^# Main backup function/{f=0} f' "$BACKUP_SH")
  echo "$body" | grep -q 'impact_render'
  echo "$body" | grep -q 'impact_confirm standard'
  # render/confirm must precede the mkdir + tar (line-order check)
  local render_line tar_line
  render_line=$(echo "$body" | grep -n 'impact_render' | head -1 | cut -d: -f1)
  tar_line=$(echo "$body" | grep -n 'tar czf ~/' | head -1 | cut -d: -f1)
  [ -n "$render_line" ] && [ -n "$tar_line" ] && [ "$render_line" -lt "$tar_line" ]
}

@test "--dry-run writes nothing: returns before mkdir/tar/scp" {
  local body
  body=$(awk '/^backup_remote\(\)/{f=1} /^# Main backup function/{f=0} f' "$BACKUP_SH")
  # dry-run block returns 0 with the 'nothing written' promise
  echo "$body" | grep -q 'nothing written remote or local'
  # the dry-run guard's return must precede mkdir + the real tar
  local dry_line mkdir_line tar_line
  dry_line=$(echo "$body" | grep -n 'nothing written remote or local' | head -1 | cut -d: -f1)
  mkdir_line=$(echo "$body" | grep -n 'mkdir -p "\$backup_base"' | head -1 | cut -d: -f1)
  # the REAL tar (appends ${excl_str}), not the dry-run echo (which has a space)
  tar_line=$(echo "$body" | grep -n 'tar czf ~/\${backup_name}.tar.gz\${excl_str}' | head -1 | cut -d: -f1)
  [ "$dry_line" -lt "$mkdir_line" ]
  [ "$dry_line" -lt "$tar_line" ]
}

@test "read-only against live: NO deploy_gate_require in the remote path" {
  ! awk '/^backup_remote\(\)/{f=1} /^# Main backup function/{f=0} f' "$BACKUP_SH" \
    | grep -q 'deploy_gate_require'
}

@test "never prints secret values: DB dump does not echo dbpass/password" {
  local body
  body=$(awk '/^backup_remote\(\)/{f=1} /^# Main backup function/{f=0} f' "$BACKUP_SH")
  # Moodle path reads only dbname; must not echo dbpass anywhere.
  ! echo "$body" | grep -q 'echo.*dbpass'
  ! echo "$body" | grep -Eiq 'CFG->dbpass'
}
