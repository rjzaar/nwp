<?php
/**
 * scripts/demo/ssd-completion-criteria.php
 *
 * Give ssd demo courses a COURSE-level completion criterion.
 *
 * WHY THIS EXISTS. Measured on ssd live 2026-08-02: 58 of 59 courses have
 * `enablecompletion = 1`, every depthcontent activity carries automatic
 * activity completion (`completion = 2`, `completionview = 1`) — and
 * `{course_completion_criteria}` has ZERO rows, site-wide. Activity completion
 * without a course criterion produces the exact state observed over the web
 * service:
 *
 *     demo_discern   completed=False   progress=100
 *
 * i.e. a member finishes every activity in the course and the course still
 * never completes, because nothing was ever declared to BE the completion
 * condition. No amount of wiring on the Drupal side can fix that: there is no
 * completion event to carry. This is the upstream half of "finishing a course
 * cannot move your community progress".
 *
 * WHAT IT DECLARES. One `COMPLETION_CRITERIA_TYPE_ACTIVITY` row per
 * completion-tracked activity, aggregated ALL — "complete every activity that
 * tracks completion, and the course is complete". That is the reading a tester
 * already expects from the checkboxes the theme is showing them.
 *
 * SCOPE IS EXPLICIT AND NARROW. --courses is REQUIRED; there is no "all"
 * shortcut, because course content on ssd is owned elsewhere and a blanket
 * rewrite of 58 courses is not this bridge's business to make.
 *
 * USAGE (via ssd-completion-criteria.sh)
 *   --courses=B1,B2,B3,B4   shortnames, required
 *   --check | --apply
 */

define('CLI_SCRIPT', true);
require(getcwd() . '/config.php');
global $DB, $CFG;
require_once($CFG->libdir . '/clilib.php');
require_once($CFG->libdir . '/completionlib.php');
require_once($CFG->dirroot . '/completion/criteria/completion_criteria_activity.php');

list($opts) = cli_get_params([
    'courses' => '', 'check' => false, 'apply' => false, 'help' => false,
], []);

if ($opts['help'] || $opts['courses'] === '' || (!$opts['check'] && !$opts['apply'])) {
    cli_writeln('usage: --courses=B1,B2 --check|--apply');
    exit($opts['help'] ? 0 : 2);
}

$apply    = (bool) $opts['apply'];
$wanted   = array_filter(array_map('trim', explode(',', $opts['courses'])), 'strlen');
$problems = [];
$did      = [];

foreach ($wanted as $shortname) {
    $course = $DB->get_record('course', ['shortname' => $shortname]);
    if (!$course) {
        $problems[] = "$shortname: no such course";
        cli_writeln("$shortname: MISSING course");
        continue;
    }
    if ((int) $course->enablecompletion !== 1) {
        $problems[] = "$shortname: enablecompletion is off";
        cli_writeln("$shortname: MISSING enablecompletion=1");
        continue;
    }

    // Every activity in the course that actually tracks completion.
    $cms = $DB->get_records_sql(
        "SELECT cm.id, cm.instance, m.name AS modname
           FROM {course_modules} cm
           JOIN {modules} m ON m.id = cm.module
          WHERE cm.course = ? AND cm.completion > 0 AND cm.deletioninprogress = 0
          ORDER BY cm.id", [$course->id]);

    if (!$cms) {
        $problems[] = "$shortname: no completion-tracked activities to build a criterion from";
        cli_writeln("$shortname: MISSING trackable activities");
        continue;
    }

    $have = $DB->get_records('course_completion_criteria',
        ['course' => $course->id, 'criteriatype' => COMPLETION_CRITERIA_TYPE_ACTIVITY]);
    $havecm = array_map(static fn($r) => (int) $r->moduleinstance, $have);

    $missing = [];
    foreach ($cms as $cm) {
        if (!in_array((int) $cm->id, $havecm, true)) {
            $missing[] = $cm;
        }
    }

    cli_writeln(sprintf('%s (id=%d): %d trackable activities, %d criteria present, %d missing',
        $shortname, $course->id, count($cms), count($have), count($missing)));

    if (!$missing) {
        continue;
    }
    if (!$apply) {
        $problems[] = "$shortname: " . count($missing) . ' criteria missing';
        continue;
    }

    foreach ($missing as $cm) {
        $c = new completion_criteria_activity();
        $c->course         = $course->id;
        $c->criteriatype   = COMPLETION_CRITERIA_TYPE_ACTIVITY;
        $c->module         = $cm->modname;
        $c->moduleinstance = $cm->id;   // course_modules.id, per core's own usage
        $c->insert();
        $did[] = "$shortname:{$cm->modname}#{$cm->id}";
    }

    // Aggregation ALL — every tracked activity must be done. Default, but set
    // it explicitly so the criterion cannot be read two ways later.
    $aggr = $DB->get_record('course_completion_aggr_methd',
        ['course' => $course->id, 'criteriatype' => COMPLETION_CRITERIA_TYPE_ACTIVITY]);
    if (!$aggr) {
        $DB->insert_record('course_completion_aggr_methd', (object) [
            'course' => $course->id,
            'criteriatype' => COMPLETION_CRITERIA_TYPE_ACTIVITY,
            'method' => COMPLETION_AGGREGATION_ALL,
            'value' => null,
        ]);
    }
    cli_writeln("  added " . count($missing) . " criteria (aggregation ALL)");
}

if ($did)      { cli_writeln('CHANGED: ' . count($did) . ' criteria added'); }
if ($problems) { cli_writeln('INCOMPLETE: ' . implode('; ', $problems)); exit(1); }
cli_writeln($apply ? 'APPLY-OK' : 'CHECK-OK');
exit(0);
