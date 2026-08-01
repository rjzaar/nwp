<?php
// scripts/demo/ssd-purge-stripped-courses.php — remove the STRIPPED course rows
// left behind by admin/cli/delete_course.php on this 4.4.12 build.
//
// WHY: stock admin/cli/delete_course.php requires only config.php + clilib.php,
// but remove_course_contents() (lib/moodlelib.php:4931) calls
// course_get_format(), which lives in course/format/lib.php and is only loaded
// via course/lib.php — which the CLI never requires. Every CLI delete therefore
// tears down ALL course content and then throws
//   "Call to undefined function course_get_format()"
// leaving a stripped course row behind (proven on live ssd 2026-08-02, 54 rows).
//
// This script requires course/lib.php FIRST (the one-line fix the CLI is
// missing) and then deletes ONLY courses that are provably the wreckage:
//   * in one of the four import rail categories, AND
//   * shortname matches the prod set (letter+digit), AND
//   * zero course_modules remain (a course with content is NEVER touched).
//
// Idempotent: once the rails hold no stripped rows it prints PURGE-OK 0.
// Staged + run by scripts/demo/ssd-purge-stripped-courses.sh (the ops#146
// demo-wrapper gate), never by hand.

define('CLI_SCRIPT', true);

$root = null;
foreach ([getcwd(), __DIR__] as $cand) {
    if (is_file("$cand/config.php") && is_dir("$cand/lib")) { $root = $cand; break; }
}
if ($root === null) { fwrite(STDERR, "Cannot find Moodle root\n"); exit(2); }
require("$root/config.php");
require_once($CFG->libdir . '/clilib.php');
require_once($CFG->dirroot . '/course/lib.php');   // defines course_get_format() — the fix.

$rails = ['Your Yes', 'Prayer & Recollection', 'Ascesis', 'Sacraments'];
$checkonly = in_array('--check', $argv, true);

list($insql, $inparams) = $DB->get_in_or_equal($rails);
$cats = $DB->get_records_select('course_categories', "name $insql", $inparams);
if (!$cats) { cli_writeln('PURGE-OK 0 (no rail categories)'); exit(0); }
$catids = array_keys($cats);

list($catsql, $catparams) = $DB->get_in_or_equal($catids);
$courses = $DB->get_records_select('course', "category $catsql AND id > 1", $catparams, 'id ASC');

$purged = 0; $skipped = [];
foreach ($courses as $course) {
    if (!preg_match('/^[a-j][0-9]$/i', $course->shortname)) {
        $skipped[] = "{$course->shortname}:name-not-in-import-set";
        continue;
    }
    $mods = $DB->count_records('course_modules', ['course' => $course->id]);
    if ($mods > 0) {
        $skipped[] = "{$course->shortname}:has-{$mods}-modules";
        continue;
    }
    if ($checkonly) { $purged++; continue; }
    cli_writeln("purging stripped course {$course->shortname} (id {$course->id})");
    delete_course($course, false);
    $purged++;
}

if (!$checkonly) { fix_course_sortorder(); }
foreach ($skipped as $s) { cli_writeln("SKIPPED $s"); }
cli_writeln(($checkonly ? 'PURGE-WOULD ' : 'PURGE-OK ') . $purged);
exit(0);
