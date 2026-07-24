#!/usr/bin/env bats
# Guard-stack port for live2prod.sh (mirror of stg2live.sh's F2/P0-2 snapshot +
# G3 maintenance wrap + §3.6 fail-loud updatedb). live2prod is server→server
# (live → prod), so every destructive op targets the PROD host.
#
# Invariants asserted (static grep/awk on the script, same style as
# test-stg2live-p0-safety.bats):
#   S  — fail-closed pre-deploy PRODUCTION snapshot (DBs + nginx + webroot)
#   G3 — maintenance mode ON before the rsync --delete, OFF only after updatedb
#   FL — fail-loud updatedb + composer (abort, leave maintenance ON)
#   V2 — v2 resolve_project for docroot resolution
#   Y  — no silent -y / --skip-backup bypass of the snapshot

CMD="${BATS_TEST_DIRNAME}/../../scripts/commands/live2prod.sh"

# ---------------------------------------------------------------------------
# S — fail-closed pre-deploy production snapshot
# ---------------------------------------------------------------------------

@test "S: a prod_host_snapshot helper exists" {
  run grep -E '^prod_host_snapshot\(\) \{' "$CMD"
  [ "$status" -eq 0 ]
}

@test "S: the snapshot captures databases + nginx + webroot" {
  run bash -c "sed -n '/^prod_host_snapshot() {/,/^}/p' '$CMD'"
  [[ "$output" == *"mysqldump --all-databases"* ]]
  [[ "$output" == *"/etc/nginx/conf.d/"* ]]
  [[ "$output" == *"webroot"* ]]
}

@test "S: a webroot-snapshot failure ABORTS (return 1) unless --override-snapshot" {
  # Inside prod_host_snapshot: an OVERRIDE_SNAPSHOT escape, else return 1.
  run bash -c "sed -n '/^prod_host_snapshot() {/,/^}/p' '$CMD' | awk '/OVERRIDE_SNAPSHOT:-false/{o=NR} /return 1/{r=NR} END{print (o && r) ? \"ok\" : \"bad\"}'"
  [ "$output" = "ok" ]
}

@test "S: the snapshot is idempotent within the last hour (webroot tar keyed)" {
  run bash -c "sed -n '/^prod_host_snapshot() {/,/^}/p' '$CMD' | grep -F -- '-mmin -60'"
  [ "$status" -eq 0 ]
}

@test "S: backup_production delegates to the fail-closed prod_host_snapshot" {
  run bash -c "sed -n '/^backup_production() {/,/^}/p' '$CMD' | grep -E 'prod_host_snapshot '"
  [ "$status" -eq 0 ]
}

@test "S: the old DB-only 'drush sql-dump > /tmp' backup is gone" {
  run grep -F 'drush sql-dump' "$CMD"
  [ "$status" -ne 0 ]
}

@test "S: the snapshot runs BEFORE the file sync in main" {
  run bash -c "awk '/backup_production \"\\\$BASE_NAME\"/{b=NR} /sync_files \"/{s=NR} END{print (b && s && b<s) ? \"ok\" : \"bad\"}' '$CMD'"
  [ "$output" = "ok" ]
}

@test "S: --override-snapshot is parsed" {
  run grep -E '\-\-override-snapshot\) OVERRIDE_SNAPSHOT=true' "$CMD"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# G3 — maintenance-mode wrap
# ---------------------------------------------------------------------------

@test "G3: a prod_maintenance_set helper exists using state:set --input-format=integer" {
  run bash -c "sed -n '/^prod_maintenance_set() {/,/^}/p' '$CMD' | grep -E 'state:set system.maintenance_mode .* --input-format=integer'"
  [ "$status" -eq 0 ]
}

@test "G3: maintenance is enabled (state 1) BEFORE the file sync in main" {
  # The ON call is fail-closed: `if ! prod_maintenance_set ... 1; then exit`.
  run bash -c "awk '/prod_maintenance_set .* 1; then/{on=NR} /sync_files \"/{s=NR} END{print (on && s && on<s) ? \"ok\" : \"bad\"}' '$CMD'"
  [ "$output" = "ok" ]
}

@test "G3: maintenance is disabled (state 0) AFTER the updatedb step in main" {
  # The OFF call tolerates its own non-zero: `prod_maintenance_set ... 0 || true`.
  run bash -c "awk '/run_db_updates \"/{u=NR} /prod_maintenance_set .* 0 \\|\\| true/{off=NR} END{print (u && off && u<off) ? \"ok\" : \"bad\"}' '$CMD'"
  [ "$output" = "ok" ]
}

@test "G3: a failed maintenance-OFF is reported loudly (503 risk)" {
  run bash -c "sed -n '/^prod_maintenance_set() {/,/^}/p' '$CMD' | grep -F 'STUCK IN MAINTENANCE'"
  [ "$status" -eq 0 ]
}

@test "G3: an abort in the destructive region leaves maintenance ON" {
  run bash -c "grep -E 'maintenance (mode )?left ON' '$CMD'"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# FL — fail-loud updatedb + composer
# ---------------------------------------------------------------------------

@test "FL: run_db_updates returns 1 on updatedb failure (no WARN-and-continue)" {
  run bash -c "sed -n '/^run_db_updates() {/,/^}/p' '$CMD' | awk '/updatedb -y/{f=1} f&&/return 1/{print \"ok\"; exit}'"
  [ "$output" = "ok" ]
}

@test "FL: the old 'may be OK' updatedb demotion is gone" {
  run grep -F 'may be OK' "$CMD"
  [ "$status" -ne 0 ]
}

@test "FL: run_db_updates resolves drush explicitly (no bare PATH reliance)" {
  run bash -c "sed -n '/^run_db_updates() {/,/^}/p' '$CMD' | grep -E 'for D in .*vendor/bin/drush'"
  [ "$status" -eq 0 ]
}

@test "FL: a failed updatedb aborts the deploy in main" {
  run bash -c "awk '/if ! run_db_updates /{f=1} f&&/exit 1/{print \"ok\"; exit}' '$CMD'"
  [ "$output" = "ok" ]
}

@test "FL: a failed composer aborts the deploy in main" {
  run bash -c "awk '/if ! run_composer /{f=1} f&&/exit 1/{print \"ok\"; exit}' '$CMD'"
  [ "$output" = "ok" ]
}

# ---------------------------------------------------------------------------
# V2 — v2 resolve_project
# ---------------------------------------------------------------------------

@test "V2: get_deploy_webroot resolves the docroot via resolve_project" {
  run bash -c "sed -n '/^get_deploy_webroot() {/,/^}/p' '$CMD' | grep -E 'resolve_project '"
  [ "$status" -eq 0 ]
}

@test "V2: the resolved webroot is exported for the snapshot/maintenance/updatedb path" {
  run grep -E 'export PROD_WEBROOT' "$CMD"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Y — no silent -y / --skip-backup bypass
# ---------------------------------------------------------------------------

@test "Y: --skip-backup is ledgered, not a silent bypass" {
  run bash -c "awk '/SKIP_BACKUP.*==.*true/{f=1} f&&/_snapshot_override_ledger/{print \"ok\"; exit}' '$CMD'"
  [ "$output" = "ok" ]
}

@test "Y: the snapshot step is NOT gated on the -y/YES confirmation flag" {
  # The snapshot's own guard is the step/START_STEP + SKIP_BACKUP check, never YES.
  run bash -c "awk '/Step \\\$step: Pre-deploy production snapshot/{start=NR} start&&/backup_production \"/{print \"reached\"; exit}' '$CMD'"
  [ "$output" = "reached" ]
  # And there is no YES gate between the step loop start and the snapshot call.
  run bash -c "awk '/# Execute deployment steps/{f=1} f&&/backup_production \"/{exit} f&&/YES.*!=.*true/{print \"leak\"; exit}' '$CMD'"
  [ "$output" != "leak" ]
}

# ---------------------------------------------------------------------------
# R — resume-safety: a fresh snapshot is asserted BEFORE the rsync --delete,
#     REGARDLESS of --step (the CRITICAL fail-open fix). A `-s N` resume that
#     jumps past the snapshot step must re-take it or refuse — never silently
#     --delete without a backstop.
# ---------------------------------------------------------------------------

@test "R: a require_prod_snapshot gate helper exists" {
  run grep -E '^require_prod_snapshot\(\) \{' "$CMD"
  [ "$status" -eq 0 ]
}

@test "R: main gates the destructive sync on require_prod_snapshot BEFORE sync_files" {
  run bash -c "awk '/require_prod_snapshot \"/{g=NR} /sync_files \"/{s=NR} END{print (g && s && g<s) ? \"ok\" : \"bad\"}' '$CMD'"
  [ "$output" = "ok" ]
}

@test "R: the require_prod_snapshot gate is NOT itself START_STEP-gated (runs on any resume)" {
  # The gate must sit inside the SAME block as sync_files (the step-3 block), so
  # a -s 3 resume that skipped step 1 still hits it. Assert no bare
  # 'START_STEP' comparison sits between the gate call and the sync call.
  run bash -c "awk '/require_prod_snapshot \"/{f=1} f&&/START_STEP/{print \"leak\"; exit} f&&/sync_files \"/{print \"clean\"; exit}' '$CMD'"
  [ "$output" = "clean" ]
}

@test "R: require_prod_snapshot re-takes via backup_production when absent" {
  run bash -c "sed -n '/^require_prod_snapshot() {/,/^}/p' '$CMD' | grep -E 'backup_production '"
  [ "$status" -eq 0 ]
}

@test "R: functional — require_prod_snapshot RE-TAKES and proceeds when the re-take lands" {
  run bash -c '
    set +e; exec 2>&1
    source "'"$CMD"'" >/dev/null 2>&1
    set +e   # the sourced script re-enables set -e; disable so we can read $?
    _prod_snapshot_present() { [ "${SNAP:-absent}" = present ]; }
    backup_production() { SNAP=present; echo RETOOK; return 0; }
    SKIP_BACKUP=false; OVERRIDE_SNAPSHOT=false
    require_prod_snapshot testsite; echo "RC=$?"
  '
  [[ "$output" == *"RETOOK"* ]]
  [[ "$output" == *"RC=0"* ]]
}

@test "R: functional — require_prod_snapshot does NOT double-snapshot when one is fresh" {
  run bash -c '
    set +e; exec 2>&1
    source "'"$CMD"'" >/dev/null 2>&1
    set +e   # the sourced script re-enables set -e; disable so we can read $?
    _prod_snapshot_present() { return 0; }
    backup_production() { echo SHOULD_NOT_RUN; return 0; }
    SKIP_BACKUP=false; OVERRIDE_SNAPSHOT=false
    require_prod_snapshot testsite; echo "RC=$?"
  '
  [[ "$output" != *"SHOULD_NOT_RUN"* ]]
  [[ "$output" == *"RC=0"* ]]
}

@test "R: functional — require_prod_snapshot REFUSES (rc=1) when absent and re-take fails" {
  run bash -c '
    set +e; exec 2>&1
    source "'"$CMD"'" >/dev/null 2>&1
    set +e   # the sourced script re-enables set -e; disable so we can read $?
    _prod_snapshot_present() { return 1; }
    backup_production() { return 1; }
    SKIP_BACKUP=false; OVERRIDE_SNAPSHOT=false
    require_prod_snapshot testsite; echo "RC=$?"
  '
  [[ "$output" == *"REFUSING the destructive rsync --delete"* ]]
  [[ "$output" == *"RC=1"* ]]
}

@test "R: functional — --override-snapshot proceeds + ledgers when absent (no re-take)" {
  run bash -c '
    set +e; exec 2>&1
    source "'"$CMD"'" >/dev/null 2>&1
    set +e   # the sourced script re-enables set -e; disable so we can read $?
    _prod_snapshot_present() { return 1; }
    backup_production() { echo SHOULD_NOT_RUN; return 0; }
    _snapshot_override_ledger() { echo LEDGERED; }
    SKIP_BACKUP=false; OVERRIDE_SNAPSHOT=true
    require_prod_snapshot testsite; echo "RC=$?"
  '
  [[ "$output" == *"LEDGERED"* ]]
  [[ "$output" != *"SHOULD_NOT_RUN"* ]]
  [[ "$output" == *"RC=0"* ]]
}

@test "R: functional — 'pl live2prod -s 3' does NOT reach rsync without a snapshot" {
  marker="$BATS_TEST_TMPDIR/synced"
  run bash -c '
    set +e; exec 2>&1
    source "'"$CMD"'" >/dev/null 2>&1
    set +e   # the sourced script re-enables set -e; disable so we can read $?
    # Neutralise every guard/gate main runs before the destructive region.
    get_base_name() { printf "%s" "$1"; }
    canonical_guard_content_push() { return 0; }
    canonical_enforce_branch_policy() { return 0; }
    maturity_guard_deploy() { return 0; }
    resolve_project() { printf ""; }
    pair_guard() { return 0; }
    pair_guard_record_success() { return 0; }
    deploy_gate_require() { return 0; }
    get_deploy_webroot() { printf "web"; }
    validate_deployment() {
      export PROD_IP=203.0.113.9 PROD_USER=gitlab PROD_PATH=/var/www/testsite
      export LIVE_IP=203.0.113.8 LIVE_USER=gitlab LIVE_PATH=/var/www/testsite
      return 0
    }
    prod_maintenance_set() { return 0; }   # ON succeeds so we reach the gate
    _prod_snapshot_present() { return 1; }  # NO snapshot on the host
    backup_production() { return 1; }       # and a re-take FAILS
    export_live_config() { return 0; }
    sync_files() { echo REACHED_RSYNC > "'"$marker"'"; return 0; }
    main -s 3 -y testsite
  '
  # The destructive rsync must NEVER have been reached.
  [ ! -f "$marker" ]
  [[ "$output" == *"REFUSING the destructive rsync --delete"* ]]
}

# ---------------------------------------------------------------------------
# M — maintenance-ON failure is fail-closed (refuse the --delete, not WARN)
# ---------------------------------------------------------------------------

@test "M: prod_maintenance_set returns non-zero on any failure" {
  # Both the OFF-failure and the ON-failure branches must 'return 1'.
  run bash -c "sed -n '/^prod_maintenance_set() {/,/^}/p' '$CMD' | grep -c 'return 1'"
  [ "$output" -ge 2 ]
}

@test "M: a failed maintenance-ON ABORTS before the destructive rsync in main" {
  run bash -c "awk '/if ! prod_maintenance_set .* 1; then/{f=1} f&&/exit 1/{print \"ok\"; exit} f&&/sync_files \"/{print \"leak\"; exit}' '$CMD'"
  [ "$output" = "ok" ]
}

# ---------------------------------------------------------------------------
# sanity
# ---------------------------------------------------------------------------

@test "live2prod.sh parses with bash -n" {
  run bash -n "$CMD"
  [ "$status" -eq 0 ]
}
