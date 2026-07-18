#!/usr/bin/env bats
# P0 hardening of the stg2live destructive deploy path
# (PL-STG2LIVE-INTEGRATION-DESIGN-2026-07-19.md):
#   F2/P0-2 — fail-closed webroot pre-snapshot before the rsync --delete
#   F4      — abort (not WARN-and-continue) on a failed live DB import
#   §3.6    — the missing live `drush updatedb` sequence, before the final cr
# These are static assertions (grep/awk on the script), same style as
# test-adr24-no-ssh-fallback.bats / test-stg2live-excludes.bats.

CMD="${BATS_TEST_DIRNAME}/../../scripts/commands/stg2live.sh"
RB="${BATS_TEST_DIRNAME}/../../lib/rollback-remote.sh"

# ---------------------------------------------------------------------------
# F2 / P0-2 — webroot pre-snapshot, fail-closed
# ---------------------------------------------------------------------------

@test "F2: live_host_snapshot creates a webroot tar" {
  run bash -c "sed -n '/^live_host_snapshot() {/,/^}/p' '$CMD'"
  # webroot_file is the -webroot- tar; the tar czf line archives it -C remote_path.
  [[ "$output" == *'webroot_file="nwp-snapshot-${base_name}-webroot-${ts}.tar.gz"'* ]]
  [[ "$output" == *'tar czf ~/${webroot_file} -C ${remote_path} .'* ]]
}

@test "F2: the webroot tar excludes files/ and private/" {
  run bash -c "sed -n '/^live_host_snapshot() {/,/^}/p' '$CMD'"
  [[ "$output" == *"--exclude=./\${webroot}/sites/default/files"* ]]
  [[ "$output" == *"--exclude=./private"* ]]
}

@test "F2: success requires a non-empty tar (test -s before returning success)" {
  run bash -c "sed -n '/^live_host_snapshot() {/,/^}/p' '$CMD' | grep -E 'test -s ~/\\\$\{webroot_file\}'"
  [ "$status" -eq 0 ]
}

@test "F2: the call site checks the return and exits on snapshot failure" {
  # The bare-statement call (return value ignored) is gone; the call is now
  # guarded by `if ! live_host_snapshot ...; then ... exit 1`.
  run bash -c "awk '/if ! live_host_snapshot /{f=1} f&&/exit 1/{print \"ok\"; exit} f&&/^    fi/{exit}' '$CMD'"
  [ "$output" = "ok" ]
}

@test "F2: no bare (return-ignored) live_host_snapshot call remains" {
  # Any invocation must be inside an `if ! ... ` guard, never a lone statement.
  run bash -c "grep -nE '^[[:space:]]*live_host_snapshot ' '$CMD' || true"
  [ -z "$output" ]
}

@test "F2: the disk-tight branch aborts (return 1) unless --override-snapshot" {
  # Old behaviour was 'return 0' on <1GB free; it must now fail closed.
  run bash -c "awk '/free_kb.*-lt 1048576/{f=1} f&&/OVERRIDE_SNAPSHOT/{o=1} f&&/return 1/{print (o?\"ok\":\"bad\"); exit}' '$CMD'"
  [ "$output" = "ok" ]
}

@test "F2: --override-snapshot flag is parsed" {
  run grep -E '\-\-override-snapshot\) OVERRIDE_SNAPSHOT=true' "$CMD"
  [ "$status" -eq 0 ]
}

@test "F2: --override-snapshot is declared in longopts and exported" {
  run grep -E 'LONGOPTS=.*override-snapshot' "$CMD"
  [ "$status" -eq 0 ]
  run grep -E 'export .*OVERRIDE_SNAPSHOT' "$CMD"
  [ "$status" -eq 0 ]
}

@test "F2: webroot tar path is threaded into rollback_record_remote" {
  # web_remote_abs (resolved from the webroot tar) is passed to the record call.
  run bash -c "sed -n '/^live_host_snapshot() {/,/^}/p' '$CMD' | grep -F '\"\$web_remote_abs\" \"\$remote_path\"'"
  [ "$status" -eq 0 ]
}

@test "F2: rollback restore executes the webroot tar xzf behind the typed confirm" {
  # The typed-timestamp confirm (read -rp ... to confirm) precedes the EXECUTION
  # of the webroot restore command in rollback_execute_remote_from_entry.
  run bash -c "awk '/read -rp .*to confirm/{c=NR} /ssh -n .*\\\$\{restore_web_cmd\}/{w=NR} END{print (c && w && c<w) ? \"ok\" : \"bad\"}' '$RB'"
  [ "$output" = "ok" ]
  # ...and the command itself is a tar xzf of the webroot tar into its target.
  run grep -F "restore_web_cmd=\"\${sudo_prefix}tar xzf '\${web}' -C '\${web_target}'\"" "$RB"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# F4 — abort on failed live DB import
# ---------------------------------------------------------------------------

@test "F4: a failed full_database_deployment aborts (return 1), not a bare WARN" {
  run bash -c "awk '/elif ! full_database_deployment/{f=1} f&&/print_status \"WARN\"/{print \"bad\"; exit} f&&/return 1/{print \"ok\"; exit}' '$CMD'"
  [ "$output" = "ok" ]
}

@test "F4: the old WARN-and-continue import message is gone" {
  run bash -c "grep -F 'Database deployment had issues' '$CMD' || true"
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# §3.6 — updatedb sequence, before the final cr
# ---------------------------------------------------------------------------

@test "§3.6: an updatedb step exists on live" {
  run grep -E 'drush updatedb -y' "$CMD"
  [ "$status" -eq 0 ]
}

@test "§3.6: the updatedb sequence is invoked in the deploy for both modes" {
  run grep -E 'run_live_db_updates ' "$CMD"
  [ "$status" -eq 0 ]
}

@test "§3.6: the updatedb call precedes the final drush cr" {
  # run_live_db_updates must be wired in before the post-deploy `drush cr`.
  run bash -c "awk '/run_live_db_updates /{u=NR} /drush cr\"/{c=NR} END{print (u && c && u<c) ? \"ok\" : \"bad\"}' '$CMD'"
  [ "$output" = "ok" ]
}

@test "§3.6: the updatedb sequence is dry-run guarded" {
  run bash -c "sed -n '/^run_live_db_updates() {/,/^}/p' '$CMD' | grep -E 'DRY_RUN.*==.*true'"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# sanity: the script still parses
# ---------------------------------------------------------------------------

@test "stg2live.sh parses with bash -n" {
  run bash -n "$CMD"
  [ "$status" -eq 0 ]
}

@test "rollback-remote.sh parses with bash -n" {
  run bash -n "$RB"
  [ "$status" -eq 0 ]
}
