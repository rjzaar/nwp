<?php
// scripts/moodle/course-restore-check.php — the staged half of
// `pl moodle course restore` (scripts/commands/moodle.sh cmd_course_restore).
//
// Staged onto the target with the sha256-verified push (same fail-closed
// contract as demo_push_verified) and run there as www-data through the
// resolved Moodle CLI php. It is the ONLY remote surface the verb adds; each
// mode is single-purpose so the read-only path stays read-only:
//
//   --list-shortnames            READ-ONLY. One `SHORTNAME <sn>` line per
//                                course (site course excluded). The verb's
//                                idempotency check: shortnames already present
//                                are skipped, so re-runs are safe.
//   --ensure-category=NAME       Get-or-create a top-level course category by
//                                name; prints `CATID <id>`. WRITE (create),
//                                idempotent — an existing category is reused.
//   --assert-enterable <sn>...   READ-ONLY post-pass. Generalises the
//                                scripts/demo/ssd-seed-courses.php --check
//                                logic: every named course must be visible=1
//                                and carry an ENABLED, KEYLESS self-enrolment
//                                (a hidden course rejects a student's
//                                require_login; a keyed/disabled self-enrol
//                                strands an SSO'd tester at the door).
//                                Prints ENTER-OK / ENTER-FAIL per course and
//                                exits 1 on any failure.
//
// IDEMPOTENT by construction; nothing here deletes anything.

define('CLI_SCRIPT', true);

$root = null;
foreach ([getcwd(), __DIR__] as $c) {
    if (is_file("$c/config.php") && is_dir("$c/lib")) { $root = $c; break; }
}
if ($root === null) { fwrite(STDERR, "Cannot find Moodle root\n"); exit(2); }
require("$root/config.php");
require_once($CFG->libdir . '/clilib.php');
require_once($CFG->libdir . '/enrollib.php');
global $DB;

$args = array_slice($argv, 1);
if (!$args) {
    fwrite(STDERR, "usage: course-restore-check.php --list-shortnames | --ensure-category=NAME | --assert-enterable <shortname>...\n");
    exit(2);
}

// ---------------------------------------------------------------------------
// --list-shortnames (read-only)
// ---------------------------------------------------------------------------
if ($args[0] === '--list-shortnames') {
    $rs = $DB->get_records_select('course', 'id > 1', [], 'shortname ASC', 'id, shortname');
    foreach ($rs as $c) {
        cli_writeln('SHORTNAME ' . $c->shortname);
    }
    exit(0);
}

// ---------------------------------------------------------------------------
// --ensure-category=NAME (idempotent create)
// ---------------------------------------------------------------------------
if (strpos($args[0], '--ensure-category=') === 0) {
    $name = trim(substr($args[0], strlen('--ensure-category=')));
    if ($name === '') { fwrite(STDERR, "empty category name\n"); exit(2); }
    $cat = $DB->get_record('course_categories', ['name' => $name, 'parent' => 0]);
    if (!$cat) {
        // Same API the ssd seeder uses; visible top-level category.
        $cat = \core_course_category::create(['name' => $name]);
        cli_writeln('CATID ' . $cat->id . ' created');
    } else {
        cli_writeln('CATID ' . $cat->id);
    }
    exit(0);
}

// ---------------------------------------------------------------------------
// --assert-enterable <shortname>... (read-only, fail on any gap)
// ---------------------------------------------------------------------------
if ($args[0] === '--assert-enterable') {
    $shortnames = array_slice($args, 1);
    if (!$shortnames) { fwrite(STDERR, "no shortnames given\n"); exit(2); }
    $bad = 0;
    foreach ($shortnames as $sn) {
        $problems = [];
        $course = $DB->get_record('course', ['shortname' => $sn]);
        if (!$course) {
            cli_writeln('ENTER-FAIL ' . $sn . ':missing');
            $bad++;
            continue;
        }
        if (empty($course->visible)) {
            $problems[] = 'hidden';
        }
        $self = $DB->get_record('enrol', ['courseid' => $course->id, 'enrol' => 'self']);
        if (!$self || (int) $self->status !== ENROL_INSTANCE_ENABLED) {
            $problems[] = 'no-self-enrol';
        } else if ((string) $self->password !== '') {
            $problems[] = 'self-enrol-keyed';
        }
        if ($problems) {
            cli_writeln('ENTER-FAIL ' . $sn . ':' . implode(',', $problems));
            $bad++;
        } else {
            cli_writeln('ENTER-OK ' . $sn);
        }
    }
    exit($bad ? 1 : 0);
}

fwrite(STDERR, "unknown mode: {$args[0]}\n");
exit(2);
