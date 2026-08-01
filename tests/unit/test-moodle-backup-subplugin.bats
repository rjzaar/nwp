#!/usr/bin/env bats
# ─────────────────────────────────────────────────────────────────────────────
# A MODULE THAT ADVERTISES BACKUP SUPPORT MUST SHIP THE BACKUP TASK CLASS
#
# The bug this pins, found 2026-08-02 on live ssd and then on live ssc and rgs:
#
#   mod/depthcontent's lib.php has always answered
#       case FEATURE_BACKUP_MOODLE2: return true;
#   while shipping no backup/moodle2/ directory at all.
#
# Moodle's backup_plan_builder does not verify that claim. It does a bare
# file_exists() on backup/moodle2/backup_<name>_activity_task.class.php and,
# when the file is missing, takes an `else` branch that SKIPS the activity —
# no warning, no error, exit 0. So a course backup of a 55-course catalogue
# produced 55 courses containing ZERO activities, and the restore looked
# entirely successful. Data loss with a green tick is the worst failure shape
# there is, and nothing in the estate could see it:
#
#   `pl moodle plugin drift` compared $plugin->version across every copy and
#   reported "every compared copy agrees" — which was TRUE and useless, because
#   version.php is identical whether or not backup/moodle2/ exists beside it.
#
# So the verb that exists to answer "are these copies the same?" was blind to
# the one difference that silently destroyed data. These cases make the claim
# checkable: advertise the capability, ship the class, or drift goes red.
# ─────────────────────────────────────────────────────────────────────────────

setup() {
  TEST_TMP=$(mktemp -d)
  LIB="${BATS_TEST_DIRNAME}/../../lib"
  # shellcheck disable=SC1090
  source "${LIB}/moodle-deploy.sh" >/dev/null 2>&1 || true
  ROOT="${TEST_TMP}/tree"
  mkdir -p "$ROOT/mod/demo"
  cat > "$ROOT/mod/demo/version.php" <<'PHP'
<?php
$plugin->component = 'mod_demo';
$plugin->version   = 2026080200;
PHP
}

teardown() { rm -rf "$TEST_TMP"; }

# Helper: write a lib.php that answers FEATURE_BACKUP_MOODLE2 the given way.
_lib_with_backup() {
  cat > "$ROOT/mod/demo/lib.php" <<PHP
<?php
function demo_supports(\$feature) {
    switch (\$feature) {
        case FEATURE_MOD_INTRO:       return true;
        case FEATURE_BACKUP_MOODLE2:  return $1;
        default: return null;
    }
}
PHP
}

_ship_task_class() {
  mkdir -p "$ROOT/mod/demo/backup/moodle2"
  echo '<?php class backup_demo_activity_task {}' \
    > "$ROOT/mod/demo/backup/moodle2/backup_demo_activity_task.class.php"
}

@test "1 THE BUG: advertises backup support, ships no task class → blind" {
  _lib_with_backup true
  run moodle_plugin_backup_capable_local "$ROOT" "mod/demo"
  [ "$status" -eq 0 ]
  [ "$output" = "blind" ]
}

@test "2 advertises backup support and ships the task class → ok" {
  _lib_with_backup true
  _ship_task_class
  run moodle_plugin_backup_capable_local "$ROOT" "mod/demo"
  [ "$output" = "ok" ]
}

@test "3 NEGATIVE CONTROL: honestly declines backup support → n/a, not blind" {
  # A module that says false and ships nothing is CORRECT. If this reads as a
  # problem the check cries wolf on every such module in Moodle core.
  _lib_with_backup false
  run moodle_plugin_backup_capable_local "$ROOT" "mod/demo"
  [ "$output" = "n/a" ]
}

@test "4 NEGATIVE CONTROL: non-mod plugin types are not activity modules" {
  # auth/, local/, course/format/ have no activity backup task by design.
  mkdir -p "$ROOT/auth/demo"
  run moodle_plugin_backup_capable_local "$ROOT" "auth/demo"
  [ "$output" = "n/a" ]
}

@test "5 NEGATIVE CONTROL: absent plugin is unknown, never 'ok'" {
  # "I could not look" must not be reported as a pass — the vacuous-pass class.
  run moodle_plugin_backup_capable_local "$ROOT" "mod/nosuch"
  [ "$output" != "ok" ]
  [ "$output" = "unknown" ]
}

@test "6 no lib.php at all → unknown, never 'ok'" {
  run moodle_plugin_backup_capable_local "$ROOT" "mod/demo"
  [ "$output" = "unknown" ]
}

@test "7 THE REAL SHAPE: the depthcontent posture is what goes red" {
  # Reproduce the exact live posture: 9-table plugin, FEATURE_BACKUP_MOODLE2
  # true, full plugin tree, everything present EXCEPT backup/moodle2/.
  _lib_with_backup true
  mkdir -p "$ROOT/mod/demo/classes/privacy" "$ROOT/mod/demo/db" "$ROOT/mod/demo/lang/en"
  touch "$ROOT/mod/demo/db/install.xml" "$ROOT/mod/demo/view.php"
  run moodle_plugin_backup_capable_local "$ROOT" "mod/demo"
  [ "$output" = "blind" ]

  # And the fix — dropping the four classes in — clears it.
  _ship_task_class
  run moodle_plugin_backup_capable_local "$ROOT" "mod/demo"
  [ "$output" = "ok" ]
}

@test "8 the task class must match the module name, not just exist" {
  # A copy-pasted task class from another module is not support for THIS one.
  _lib_with_backup true
  mkdir -p "$ROOT/mod/demo/backup/moodle2"
  echo '<?php' > "$ROOT/mod/demo/backup/moodle2/backup_other_activity_task.class.php"
  run moodle_plugin_backup_capable_local "$ROOT" "mod/demo"
  [ "$output" = "blind" ]
}
