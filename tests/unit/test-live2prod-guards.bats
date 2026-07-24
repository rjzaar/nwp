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
  run bash -c "awk '/prod_maintenance_set .* 1\$/{on=NR} /sync_files \"/{s=NR} END{print (on && s && on<s) ? \"ok\" : \"bad\"}' '$CMD'"
  [ "$output" = "ok" ]
}

@test "G3: maintenance is disabled (state 0) AFTER the updatedb step in main" {
  run bash -c "awk '/run_db_updates \"/{u=NR} /prod_maintenance_set .* 0\$/{off=NR} END{print (u && off && u<off) ? \"ok\" : \"bad\"}' '$CMD'"
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
# sanity
# ---------------------------------------------------------------------------

@test "live2prod.sh parses with bash -n" {
  run bash -n "$CMD"
  [ "$status" -eq 0 ]
}
