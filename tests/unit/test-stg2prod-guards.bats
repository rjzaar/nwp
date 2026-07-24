#!/usr/bin/env bats
# Prod-leg safety guard-stack ported from stg2live into stg2prod (comparison
# report Gap#10.1). The stg2prod prod leg was v1-era: bare destructive
# `rsync --delete` with NO pre-deploy snapshot, NO maintenance wrap,
# composer/updatedb failures demoted to warnings, backup skipped under -y, and a
# deploy-gate summary that mis-claimed "files + DB".
#
# Static assertions (grep/awk/sed on the script), same style as
# test-stg2live-p0-safety.bats.

CMD="${BATS_TEST_DIRNAME}/../../scripts/commands/stg2prod.sh"

# ---------------------------------------------------------------------------
# Pre-deploy snapshot — fail-closed, BEFORE the destructive rsync
# ---------------------------------------------------------------------------

@test "snapshot: a prod_host_snapshot helper exists" {
  run grep -E '^prod_host_snapshot\(\) \{' "$CMD"
  [ "$status" -eq 0 ]
}

@test "snapshot: the webroot snapshot is fail-closed (return 1 without override)" {
  # In the webroot branch, a failed/empty tar with OVERRIDE_SNAPSHOT not set
  # must `return 1` (refuse the --delete).
  run bash -c "sed -n '/^prod_host_snapshot() {/,/^}/p' '$CMD' | awk '/Refusing the destructive rsync --delete without a webroot snapshot/{f=1} f&&/return 1/{print \"ok\"; exit}'"
  [ "$output" = "ok" ]
}

@test "snapshot: --override-snapshot use is ledgered" {
  run bash -c "sed -n '/^prod_host_snapshot() {/,/^}/p' '$CMD' | grep -E '_snapshot_override_ledger'"
  [ "$status" -eq 0 ]
  run grep -E '^_snapshot_override_ledger\(\) \{' "$CMD"
  [ "$status" -eq 0 ]
}

@test "snapshot: the snapshot runs BEFORE the destructive rsync --delete" {
  # Inside sync_files: prod_host_snapshot call precedes the rsync_cmd with --delete.
  run bash -c "sed -n '/^sync_files() {/,/^}/p' '$CMD' | awk '/prod_host_snapshot /{s=NR} /rsync .*--delete/{d=NR} END{print (s && d && s<d) ? \"ok\" : \"bad\"}'"
  [ "$output" = "ok" ]
}

@test "snapshot: a failed snapshot aborts sync_files (return 1)" {
  run bash -c "sed -n '/^sync_files() {/,/^}/p' '$CMD' | awk '/if ! prod_host_snapshot/{f=1} f&&/return 1/{print \"ok\"; exit}'"
  [ "$output" = "ok" ]
}

@test "snapshot: the snapshot + maintenance-enable are dry-run guarded" {
  run bash -c "sed -n '/^sync_files() {/,/^}/p' '$CMD' | awk '/DRY_RUN.*!=.*\"true\"/{f=1} f&&/prod_host_snapshot /{print \"ok\"; exit}'"
  [ "$output" = "ok" ]
}

# ---------------------------------------------------------------------------
# Maintenance-mode wrap — ON before rsync, OFF only after updatedb + cr succeed
# ---------------------------------------------------------------------------

@test "maint: a prod_maintenance_set helper exists using state:set --input-format=integer" {
  run bash -c "sed -n '/^prod_maintenance_set() {/,/^}/p' '$CMD' | grep -E 'drush state:set system.maintenance_mode .* --input-format=integer'"
  [ "$status" -eq 0 ]
}

@test "maint: maintenance is enabled (prod_maintenance_set 1) BEFORE the rsync --delete" {
  run bash -c "sed -n '/^sync_files() {/,/^}/p' '$CMD' | awk '/prod_maintenance_set 1/{on=NR} /rsync .*--delete/{d=NR} END{print (on && d && on<d) ? \"ok\" : \"bad\"}'"
  [ "$output" = "ok" ]
}

@test "maint: maintenance OFF (prod_maintenance_set 0) lives ONLY in clear_cache_and_display" {
  # Exactly one maintenance-OFF call in the whole script, and it is inside
  # clear_cache_and_display (step 11 — after the fail-loud updatedb at step 7).
  run bash -c "grep -c 'prod_maintenance_set 0' '$CMD'"
  [ "$output" = "1" ]
  run bash -c "sed -n '/^clear_cache_and_display() {/,/^}/p' '$CMD' | grep -E 'prod_maintenance_set 0'"
  [ "$status" -eq 0 ]
}

@test "maint: maintenance OFF is gated on a SUCCESSFUL cache:rebuild" {
  # Inside clear_cache_and_display: the cache:rebuild success branch is what
  # calls prod_maintenance_set 0 (it appears after cache:rebuild, before the
  # failure branch's return 1).
  run bash -c "sed -n '/^clear_cache_and_display() {/,/^}/p' '$CMD' | awk '/drush cache:rebuild/{c=NR} /prod_maintenance_set 0/{o=NR} END{print (c && o && c<o) ? \"ok\" : \"bad\"}'"
  [ "$output" = "ok" ]
}

@test "maint: a failed maintenance-disable is loud (503 warning)" {
  run bash -c "grep -F 'STUCK IN MAINTENANCE' '$CMD'"
  [ "$status" -eq 0 ]
}

@test "maint: an abort after the swap leaves maintenance ON (rollback pointer)" {
  run bash -c "grep -F 'maintenance left ON' '$CMD'"
  [ "$status" -eq 0 ]
  run bash -c "grep -F 'pl rollback execute' '$CMD'"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Fail-loud on composer / updatedb (were demoted to warnings)
# ---------------------------------------------------------------------------

@test "fail-loud: updatedb failure returns non-zero (not a WARN)" {
  run bash -c "sed -n '/^run_db_updates_production() {/,/^}/p' '$CMD' | awk '/drush updatedb -y/{f=1} f&&/print_error/{e=1} f&&/return 1/{print (e?\"ok\":\"bad\"); exit}'"
  [ "$output" = "ok" ]
  # the old WARN demotion must be gone from this function
  run bash -c "sed -n '/^run_db_updates_production() {/,/^}/p' '$CMD' | grep -E 'Database updates had warnings'"
  [ "$status" -ne 0 ]
}

@test "fail-loud: composer failure returns non-zero (not a WARN)" {
  run bash -c "sed -n '/^run_composer_production() {/,/^}/p' '$CMD' | awk '/composer install/{f=1} f&&/return 1/{print \"ok\"; exit}'"
  [ "$output" = "ok" ]
  run bash -c "sed -n '/^run_composer_production() {/,/^}/p' '$CMD' | grep -E 'Composer install had warnings'"
  [ "$status" -ne 0 ]
}

@test "fail-loud: the orchestrator aborts on a failed updatedb" {
  run bash -c "grep -E 'if ! run_db_updates_production' '$CMD'"
  [ "$status" -eq 0 ]
}

@test "fail-loud: the orchestrator aborts on a failed composer install" {
  run bash -c "grep -E 'if ! run_composer_production' '$CMD'"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# backup_production — never skipped under -y
# ---------------------------------------------------------------------------

@test "backup: -y mode no longer short-circuits with a skip" {
  # The old `if [ "$AUTO_YES" == "true" ]; then ... Skipping ... return 0`
  # early-out must be gone.
  run bash -c "sed -n '/^backup_production() {/,/^}/p' '$CMD' | grep -F 'Skipping production backup (auto-yes mode)'"
  [ "$status" -ne 0 ]
}

@test "backup: -y mode explicitly runs the backup (never skipped)" {
  run bash -c "sed -n '/^backup_production() {/,/^}/p' '$CMD' | grep -F 'never skipped'"
  [ "$status" -eq 0 ]
}

@test "backup: only an interactive operator can decline the backup" {
  # The decline path is reachable only when AUTO_YES != true (the prompt block).
  run bash -c "sed -n '/^backup_production() {/,/^}/p' '$CMD' | awk '/AUTO_YES.*!=.*true/{f=1} f&&/read do_backup/{print \"ok\"; exit}'"
  [ "$output" = "ok" ]
}

# ---------------------------------------------------------------------------
# v2 staging resolution (F17/F23) + deploy-gate summary correction
# ---------------------------------------------------------------------------

@test "v2: staging is resolved via resolve_project (not flat sites/\$SITENAME)" {
  run bash -c "sed -n '/^get_stg_dir() {/,/^}/p' '$CMD' | grep -E 'resolve_project \"\\\$base\" \"stg\"'"
  [ "$status" -eq 0 ]
}

@test "v2: no awk-yaml legacy staging path parser remains in get_stg_dir" {
  # get_stg_dir must not fall back to an awk-based nwp.yml parse.
  run bash -c "sed -n '/^get_stg_dir() {/,/^}/p' '$CMD' | grep -E 'awk'"
  [ "$status" -ne 0 ]
}

@test "gate: the deploy-gate summary no longer mis-claims 'files + DB'" {
  run bash -c "grep -F 'files + DB' '$CMD'"
  [ "$status" -ne 0 ]
}

@test "gate: the deploy-gate summary states NO database push" {
  run bash -c "grep -F 'NO database push' '$CMD'"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# M — maintenance-ON failure is fail-closed (refuse the --delete, not WARN)
#     Parity with live2prod. The old helper returned 0 ("continuing") on an
#     ON failure and the caller ran it UNCHECKED, so a failed maintenance-ON
#     let the destructive rsync --delete proceed with no 503 — members saw a
#     half-populated webroot mid-deploy.
# ---------------------------------------------------------------------------

@test "M: prod_maintenance_set returns non-zero on any failure (ON and OFF)" {
  # Both the OFF-failure and the ON-failure branches must 'return 1'.
  run bash -c "sed -n '/^prod_maintenance_set() {/,/^}/p' '$CMD' | grep -c 'return 1'"
  [ "$output" -ge 2 ]
}

@test "M: the ON-failure branch no longer returns 0 ('continuing')" {
  run bash -c "sed -n '/^prod_maintenance_set() {/,/^}/p' '$CMD' | grep -F 'continuing'"
  [ "$status" -ne 0 ]
}

@test "M: the maintenance-ON call is gated (if ! prod_maintenance_set 1) not unchecked" {
  run bash -c "sed -n '/^sync_files() {/,/^}/p' '$CMD' | grep -E 'if ! prod_maintenance_set 1; then'"
  [ "$status" -eq 0 ]
}

@test "M: a failed maintenance-ON ABORTS before the destructive rsync in sync_files" {
  # Inside sync_files: the `if ! prod_maintenance_set 1` block must reach its
  # `return 1` before the rsync --delete line.
  run bash -c "sed -n '/^sync_files() {/,/^}/p' '$CMD' | awk '/if ! prod_maintenance_set 1; then/{f=1} f&&/return 1/{print \"ok\"; exit} f&&/rsync_cmd=\"rsync/{print \"leak\"; exit}'"
  [ "$output" = "ok" ]
}

@test "M: functional — sync_files fail-closes (rc=1) and never rsyncs when maintenance-ON fails" {
  marker="$BATS_TEST_TMPDIR/synced"
  run bash -c '
    set +e; exec 2>&1
    source "'"$CMD"'" >/dev/null 2>&1
    set +e   # the sourced script re-enables set -e; disable so we can read $?
    DRY_RUN=false
    prod_host_snapshot() { return 0; }        # snapshot OK so we reach the gate
    prod_maintenance_set() { return 1; }       # maintenance-ON FAILS
    rsync() { echo REACHED_RSYNC > "'"$marker"'"; return 0; }
    sync_files /tmp/nonexistent-stg testsite; echo "RC=$?"
  '
  # The destructive rsync must NEVER have been reached.
  [ ! -f "$marker" ]
  [[ "$output" == *"REFUSING destructive rsync --delete"* ]]
  [[ "$output" == *"RC=1"* ]]
}

# ---------------------------------------------------------------------------
# flag plumbing + sanity
# ---------------------------------------------------------------------------

@test "flag: --override-snapshot is parsed" {
  run grep -E '\-\-override-snapshot\)' "$CMD"
  [ "$status" -eq 0 ]
}

@test "flag: --override-snapshot is declared in longopts" {
  run grep -E 'LONGOPTS=.*override-snapshot' "$CMD"
  [ "$status" -eq 0 ]
}

@test "stg2prod.sh parses with bash -n" {
  run bash -n "$CMD"
  [ "$status" -eq 0 ]
}
