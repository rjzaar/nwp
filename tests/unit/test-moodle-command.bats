#!/usr/bin/env bats
# PL-STG2LIVE §4 / P1-2 — the `pl moodle` family (lib/moodle-deploy.sh +
# scripts/commands/moodle.sh). Exercises the pure guards on throwaway fixtures:
# sub-router dispatch/help, the AMD freshness gate, the deploy-set assertion
# (refuse config.php/moodledata), live-default-dry-run, and the moodle-remote
# rollback-record shape. NO ddev / ssh / network / secrets.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TEST_TMP="$(mktemp -d)"

  # ui.sh (print_*) then the lib under test.
  source "${REPO_ROOT}/lib/ui.sh"
  source "${REPO_ROOT}/lib/moodle-promote.sh"   # _mp_cfg, _mp_yq (soft deps)
  source "${REPO_ROOT}/lib/moodle-deploy.sh"

  # A fake plugin with a FRESH amd build (2 src ⇒ 2 build, build newer).
  FRESH="${TEST_TMP}/fresh"
  mkdir -p "${FRESH}/amd/src" "${FRESH}/amd/build"
  echo "// a" > "${FRESH}/amd/src/a.js"
  echo "// b" > "${FRESH}/amd/src/b.js"
  echo "<?php \$plugin->version=2026010100;" > "${FRESH}/version.php"
  sleep 1
  echo "min" > "${FRESH}/amd/build/a.min.js"
  echo "min" > "${FRESH}/amd/build/b.min.js"

  # A fake plugin with a STALE build (build older than src).
  STALE="${TEST_TMP}/stale"
  mkdir -p "${STALE}/amd/src" "${STALE}/amd/build"
  echo "min" > "${STALE}/amd/build/a.min.js"
  sleep 1
  echo "// a" > "${STALE}/amd/src/a.js"      # src NEWER than build → stale

  # A fake plugin with a MISSING build (1 src, 0 build).
  MISSING="${TEST_TMP}/missing"
  mkdir -p "${MISSING}/amd/src"
  echo "// a" > "${MISSING}/amd/src/a.js"

  # A plugin with no amd tree at all (trivially fresh).
  NOAMD="${TEST_TMP}/noamd"
  mkdir -p "${NOAMD}"
  echo "<?php" > "${NOAMD}/version.php"
}

teardown() { rm -rf "${TEST_TMP}"; }

# --- sub-router dispatch + help ---------------------------------------------

@test "moodle.sh with no args prints usage and exits non-zero" {
  run bash "${REPO_ROOT}/scripts/commands/moodle.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"USAGE:"* ]]
}

@test "moodle.sh help lists the subcommands" {
  run bash "${REPO_ROOT}/scripts/commands/moodle.sh" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"plugin build"* ]]
  [[ "$output" == *"plugin deploy"* ]]
  [[ "$output" == *"backup"* ]]
  [[ "$output" == *"rollback"* ]]
}

@test "moodle.sh rejects an unknown subcommand" {
  run bash "${REPO_ROOT}/scripts/commands/moodle.sh" frobnicate
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown moodle subcommand"* ]]
}

@test "moodle.sh plugin rejects an unknown plugin subcommand" {
  run bash "${REPO_ROOT}/scripts/commands/moodle.sh" plugin wibble
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown 'plugin' subcommand"* ]]
}

# --- freshness gate ----------------------------------------------------------

@test "freshness gate PASSES when every src has a newer build (equal counts)" {
  run moodle_amd_freshness_check "${FRESH}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "freshness gate REFUSES a build older than its src" {
  run moodle_amd_freshness_check "${STALE}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"OLDER"* || "$output" == *"stale"* ]]
}

@test "freshness gate REFUSES a missing build (count mismatch)" {
  run moodle_amd_freshness_check "${MISSING}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"NO amd/build"* || "$output" == *"mismatch"* ]]
}

@test "freshness gate PASSES a plugin with no amd tree" {
  run moodle_amd_freshness_check "${NOAMD}"
  [ "$status" -eq 0 ]
}

# --- plugin id split / deploy-set assertion ----------------------------------

@test "plugin split accepts a two-segment type/name" {
  run moodle_plugin_split "mod/depthcontent"
  [ "$status" -eq 0 ]
  [ "$output" = "mod depthcontent" ]
}

@test "plugin split rejects absolute, traversal, and 3-segment paths" {
  run moodle_plugin_split "/etc/passwd";           [ "$status" -ne 0 ]
  run moodle_plugin_split "mod/../config.php";      [ "$status" -ne 0 ]
  run moodle_plugin_split "a/b/c";                  [ "$status" -ne 0 ]
  run moodle_plugin_split "single";                 [ "$status" -ne 0 ]
}

@test "deploy-set assertion REFUSES config.php in the set" {
  run moodle_deploy_assert_set "mod/depthcontent" "config.php"
  [ "$status" -ne 0 ]
  [[ "$output" == *"config.php"* ]]
}

@test "deploy-set assertion REFUSES a moodledata path" {
  run moodle_deploy_assert_set "moodledata/filedir"
  [ "$status" -ne 0 ]
  [[ "$output" == *"moodledata"* ]]
}

@test "deploy-set assertion REFUSES an absolute path" {
  run moodle_deploy_assert_set "/var/www/ssc/config.php"
  [ "$status" -ne 0 ]
}

@test "deploy-set assertion ACCEPTS a set of plain plugin subdirs" {
  run moodle_deploy_assert_set "mod/depthcontent" "local/nwc_copyright_sync"
  [ "$status" -eq 0 ]
}

# --- live deploy defaults to dry-run ----------------------------------------
# We drive cmd_plugin_deploy far enough to prove that WITHOUT --apply it never
# reaches an --apply branch. Using a fixture PROJECT_ROOT with a moodle site
# whose live server is unreachable would still require ssh; instead we assert the
# structural guard: the deploy command's mode defaults to dry-run (no --apply)
# by checking the source: 'mode="dry-run"' is the initial value and --apply is
# the only thing that flips it.

@test "plugin deploy source defaults mode to dry-run (never live-writes without --apply)" {
  run grep -n 'local site="" tier="" mode="dry-run"' "${REPO_ROOT}/scripts/commands/moodle.sh"
  [ "$status" -eq 0 ]
  # and the only flip to apply is behind --apply
  run bash -c "grep -n 'mode=\"apply\"' '${REPO_ROOT}/scripts/commands/moodle.sh' | grep -c -- '--apply'"
  [ "$output" -ge 1 ]
}

@test "plugin deploy refuses a bad --tier" {
  run bash "${REPO_ROOT}/scripts/commands/moodle.sh" plugin deploy somesite mod/depthcontent --tier=prod
  [ "$status" -ne 0 ]
  [[ "$output" == *"--tier must be stg or live"* ]]
}

# --- moodle-remote rollback record shape -------------------------------------

@test "rollback_record_moodle_remote writes a type:moodle-remote entry with the right fields" {
  source "${REPO_ROOT}/lib/rollback.sh"
  source "${REPO_ROOT}/lib/rollback-remote.sh"
  export ROLLBACK_DIR="${TEST_TMP}/.rollback"
  rollback_init 2>/dev/null || mkdir -p "$ROLLBACK_DIR"

  run rollback_record_moodle_remote "ssc" "live" "gitlab" "10.0.0.1" "20260719-101010" \
      "/home/gitlab/nwp-snapshot-ssc-moodledb-20260719-101010.sql.gz" \
      "/home/gitlab/nwp-snapshot-ssc-plugins-20260719-101010.tar.gz" \
      "/var/www/ssc" "mod/depthcontent local/nwc_copyright_sync" "abc123"
  [ "$status" -eq 0 ]

  entry="${ROLLBACK_DIR}/ssc_live_20260719-101010.json"
  [ -f "$entry" ]
  grep -q '"type": "moodle-remote"' "$entry"
  grep -q '"snapshot_db"' "$entry"
  grep -q '"snapshot_plugins"' "$entry"
  grep -q '"moodle_root": "/var/www/ssc"' "$entry"
  grep -q '"plugins": "mod/depthcontent local/nwc_copyright_sync"' "$entry"
  grep -q '"status": "active"' "$entry"
}

# --- pre-deploy snapshot script: CLI_SCRIPT regression ------------------------
# Moodle's config.php hard-aborts a CLI include with
#   "Command line scripts must define CLI_SCRIPT before requiring config.php"
# unless CLI_SCRIPT is defined FIRST. Without it the generated remote snapshot
# script exits 1, moodle_remote_backup returns 1, and the live deploy refuses
# with "Pre-deploy snapshot failed" — i.e. `pl moodle plugin deploy --tier=live
# --apply` could never take its rollback point. Fails closed, but permanently.

@test "moodle_backup_remote_script defines CLI_SCRIPT before requiring config.php" {
  run moodle_backup_remote_script "/var/www/ssc" "ssc" "20260726-101010" "sudo" \
      "false" "false" "auth/nwc local/practice"
  [ "$status" -eq 0 ]
  [[ "$output" == *'define("CLI_SCRIPT",1)'* ]]
  # …and it must come BEFORE the require, in the same -r program.
  [[ "$output" == *'define("CLI_SCRIPT",1); define("ABORT_AFTER_CONFIG",1); require'* ]]
}

@test "moodle_backup_remote_script still keeps the db password off argv" {
  run moodle_backup_remote_script "/var/www/ssc" "ssc" "20260726-101010" "sudo" \
      "false" "false" "auth/nwc"
  [ "$status" -eq 0 ]
  # password is read into a remote shell var and passed via MYSQL_PWD, never -p
  [[ "$output" == *'MYSQL_PWD='* ]]
  [[ "$output" != *'--password='* ]]
  [[ "$output" != *'-p$DBP'* ]]
}

@test "moodle_remote_rollback_execute (rollback path) also defines CLI_SCRIPT" {
  # The second config.php reader lives in moodle_remote_rollback_execute, which
  # interpolates the snapshot path into its heredoc and so is not callable here
  # without a fixture. This is therefore a SOURCE assertion, not a behavioural
  # one: it pins the count of correctly-ordered call sites at >= 2 so a future
  # edit cannot fix one reader and leave the other broken. Being a grep, it
  # canNOT detect a gutted/stubbed function — tests above cover that for the
  # backup generator; the rollback generator has no behavioural cover yet.
  run grep -c 'define("CLI_SCRIPT",1); define("ABORT_AFTER_CONFIG",1);' \
      "${REPO_ROOT}/lib/moodle-deploy.sh"
  [ "$status" -eq 0 ]
  [ "$output" -ge 2 ]
}

# =============================================================================
# ops#326 (engine/site separation): the engine ships no default site. The two
# verbs that used to default to a REAL private site must now refuse, naming
# what to pass instead.
# =============================================================================

@test "ops#326: gate-status without a site refuses (no engine default site)" {
  run bash "${REPO_ROOT}/scripts/commands/moodle.sh" gate-status
  [ "$status" -ne 0 ]
  [[ "$output" == *"no default site"* ]]
  [[ "$output" == *"gate-status <site>"* ]]
}

@test "ops#326: plugin build without --ddev/--tree refuses (no engine default site)" {
  run bash "${REPO_ROOT}/scripts/commands/moodle.sh" plugin build mod/foo --check-only
  [ "$status" -ne 0 ]
  [[ "$output" == *"--tree"* ]]
  [[ "$output" == *"no default site"* ]]
}
