<?php
// ops#133 Phase 2 — seed the ssd demo Moodle with courses a tester can
// actually walk into.
//
// Staged into the Moodle root and run there by scripts/demo/ssd-seed-courses.sh:
//   php8.3 ssd_seed_courses.php [--check] [--bind-cohorts]
//
// IDEMPOTENT — re-running refreshes rather than duplicates (everything is
// keyed on course shortname / activity name).
//
// What a tester needs in order for the demo to be worth their time:
//   * VISIBLE courses (a hidden course rejects a student's require_login);
//   * SELF ENROLMENT with no key, so an SSO'd tester can walk straight in
//     without an admin enrolling them — this is the load-bearing bit for a
//     site whose entire user population is wiped nightly;
//   * a depthcontent activity carrying a real quiz item, so "do something that
//     writes formation data" is a click, and the Art.9 consent gate is
//     genuinely exercised (mod_depthcontent_record_response is one of the
//     gated write paths);
//   * with --bind-cohorts, an enrol_cohort instance for every auth_nwc-managed
//     guild cohort (idnumber prefix `nwcguild:`), so a guild-leader tester
//     arrives PRE-enrolled and can see the leader views immediately.
//
// The fixture shape is deliberately the same one the ops#93 browser e2e proved
// on ssc (tests/e2e/ssc_setup.php) — same content_json, same enrol wiring —
// so ssd's courses are exercised by machinery that is already known good.

define('CLI_SCRIPT', true);

$root = null;
foreach ([getcwd(), __DIR__] as $c) {
    if (is_file("$c/config.php") && is_dir("$c/lib")) { $root = $c; break; }
}
if ($root === null) { fwrite(STDERR, "Cannot find Moodle root\n"); exit(2); }
require("$root/config.php");
require_once($CFG->dirroot . '/course/lib.php');
require_once($CFG->dirroot . '/lib/enrollib.php');
require_once($CFG->libdir . '/clilib.php');
global $DB;

$checkonly    = in_array('--check', $argv, true);
$bindcohorts  = in_array('--bind-cohorts', $argv, true);

const CATNAME = 'Demo courses';
const GUILD_COHORT_PREFIX = 'nwcguild:';   // must match auth_nwc guild_cohort_map

/**
 * The demo catalogue. `point` is the depthcontent catalog id (pointid column,
 * char(20) NOT NULL — keep these short).
 */
$CATALOGUE = [
    [
        'shortname' => 'demo_prayer',
        'fullname'  => 'Beginning Prayer',
        'summary'   => 'A short walk through the shape of Christian prayer. Demo content — everything here is erased nightly.',
        'activity'  => 'Praying with Scripture',
        'point'     => 'demo.prayer.1',
        'question'  => 'Which of these is a form of prayer the Church has always practised?',
        'options'   => ['Lectio divina', 'Sitting quietly until you feel nothing at all'],
        'answer'    => 0,
        'body'      => '<p>Prayer is the raising of the mind and heart to God. This demo activity exists so you can click something and see what happens.</p>',
    ],
    [
        'shortname' => 'demo_creed',
        'fullname'  => 'The Creed, Line by Line',
        'summary'   => 'What we say we believe, one line at a time. Demo content — erased nightly.',
        'activity'  => 'I believe in one God',
        'point'     => 'demo.creed.1',
        'question'  => 'The Nicene Creed begins with which word?',
        'options'   => ['I believe', 'Perhaps'],
        'answer'    => 0,
        'body'      => '<p>The Creed is a summary of the faith. This is demo content for testing.</p>',
    ],
    [
        'shortname' => 'demo_discern',
        'fullname'  => 'Discernment Basics',
        'summary'   => 'Noticing what moves you, and where it is going. Demo content — erased nightly.',
        'activity'  => 'Consolation and desolation',
        'point'     => 'demo.discern.1',
        'question'  => 'Consolation, in the Ignatian sense, chiefly means…',
        'options'   => ['A movement toward God', 'Feeling pleased with yourself'],
        'answer'    => 0,
        'body'      => '<p>Discernment begins with attention. Demo content for testing.</p>',
    ],
];

// ---------------------------------------------------------------------------
// --check: report whether the catalogue is present and enterable.
// ---------------------------------------------------------------------------
if ($checkonly) {
    $bad = [];
    foreach ($CATALOGUE as $spec) {
        $course = $DB->get_record('course', ['shortname' => $spec['shortname']]);
        if (!$course)              { $bad[] = $spec['shortname'] . ':missing';  continue; }
        if (empty($course->visible)) { $bad[] = $spec['shortname'] . ':hidden'; }
        $self = $DB->get_record('enrol', ['courseid' => $course->id, 'enrol' => 'self']);
        if (!$self || (int) $self->status !== ENROL_INSTANCE_ENABLED) {
            $bad[] = $spec['shortname'] . ':no-self-enrol';
        }
        if (!$DB->record_exists('depthcontent', ['course' => $course->id])) {
            $bad[] = $spec['shortname'] . ':no-activity';
        }
    }
    if ($bad) { cli_writeln('SEED-FAIL: ' . implode(',', $bad)); exit(1); }
    cli_writeln('SEED-OK courses=' . count($CATALOGUE));
    exit(0);
}

// ---------------------------------------------------------------------------
// Category
// ---------------------------------------------------------------------------
$cat = $DB->get_record('course_categories', ['name' => CATNAME]);
if (!$cat) {
    $cat = \core_course_category::create(['name' => CATNAME, 'description' => 'Demo tier (ops#133) — wiped nightly.']);
    $catid = $cat->id;
    cli_writeln('created category: ' . CATNAME);
} else {
    $catid = (int) $cat->id;
}

$moduleid = $DB->get_field('modules', 'id', ['name' => 'depthcontent'], MUST_EXIST);
$studentrole = $DB->get_field('role', 'id', ['shortname' => 'student'], MUST_EXIST);
$manual = enrol_get_plugin('manual');
$selfplugin = enrol_get_plugin('self');

foreach ($CATALOGUE as $spec) {
    // -- course (visible; hidden courses reject a student's require_login) ----
    $course = $DB->get_record('course', ['shortname' => $spec['shortname']]);
    if (!$course) {
        $course = create_course((object) [
            'fullname'  => $spec['fullname'],
            'shortname' => $spec['shortname'],
            'category'  => $catid,
            'summary'   => $spec['summary'],
            'visible'   => 1,
            'format'    => 'topics',
            'numsections' => 1,
        ]);
        cli_writeln('created course: ' . $spec['shortname']);
    } else if (empty($course->visible)) {
        $DB->set_field('course', 'visible', 1, ['id' => $course->id]);
        $course->visible = 1;
    }

    // -- depthcontent activity with a real quiz item -------------------------
    $dc = $DB->get_record('depthcontent', ['course' => $course->id, 'name' => $spec['activity']]);
    if (!$dc) {
        $content = json_encode([
            'depths' => ['standard' => $spec['body']],
            'quiz_items' => [[
                'id' => 'q1', 'depth' => 'standard', 'difficulty' => 'standard',
                'type' => 'multichoice', 'question' => $spec['question'],
                'options' => $spec['options'], 'answer' => $spec['answer'],
            ]],
            'practice' => null,
        ]);
        $dcid = $DB->insert_record('depthcontent', (object) [
            'course' => $course->id, 'name' => $spec['activity'], 'intro' => '',
            'introformat' => 1, 'pointid' => $spec['point'],
            'content_json' => $content, 'timemodified' => time(),
        ]);
        $cmid = add_course_module((object) [
            'course' => $course->id, 'module' => $moduleid, 'instance' => $dcid,
            'section' => 0, 'visible' => 1, 'added' => time(),
        ]);
        course_add_cm_to_section($course->id, $cmid, 0);
        \context_module::instance($cmid);
        rebuild_course_cache($course->id, true);
        cli_writeln('  + activity: ' . $spec['activity'] . ' (cmid=' . $cmid . ')');
    }

    // -- manual enrolment instance (for fixtures/admin) ----------------------
    if (!$DB->record_exists('enrol', ['courseid' => $course->id, 'enrol' => 'manual'])) {
        $manual->add_instance((object) $course);
    }

    // -- SELF enrolment, no key, enabled: the tester's way in ----------------
    $self = $DB->get_record('enrol', ['courseid' => $course->id, 'enrol' => 'self']);
    if (!$self) {
        $selfid = $selfplugin->add_instance((object) $course, [
            'status'          => ENROL_INSTANCE_ENABLED,
            'password'        => '',
            'customint1'      => 0,   // no group key
            'customint6'      => 1,   // allow new enrolments
            'roleid'          => $studentrole,
        ]);
        $self = $DB->get_record('enrol', ['id' => $selfid]);
        cli_writeln('  + self-enrolment enabled');
    } else if ((int) $self->status !== ENROL_INSTANCE_ENABLED || (int) $self->customint6 !== 1) {
        $DB->set_field('enrol', 'status', ENROL_INSTANCE_ENABLED, ['id' => $self->id]);
        $DB->set_field('enrol', 'customint6', 1, ['id' => $self->id]);
        $DB->set_field('enrol', 'password', '', ['id' => $self->id]);
    }
}

// ---------------------------------------------------------------------------
// --bind-cohorts: enrol every auth_nwc-managed guild cohort into every demo
// course, so a guild-leader tester arrives already inside.
//
// The cohorts themselves are created by auth_nwc at login from the `guilds`
// claim, so this is run AFTER at least one SSO login has happened — and the
// binding is then baked into the golden image, where it survives every reset
// (the guild UUIDs come back unchanged with the provider's own restore).
// ---------------------------------------------------------------------------
if ($bindcohorts) {
    $cohortplugin = enrol_get_plugin('cohort');
    $cohorts = $DB->get_records_sql(
        "SELECT * FROM {cohort} WHERE " . $DB->sql_like('idnumber', ':pref'),
        ['pref' => GUILD_COHORT_PREFIX . '%']);
    if (!$cohorts) {
        cli_writeln('no ' . GUILD_COHORT_PREFIX . ' cohorts yet (they appear after the first SSO login) — nothing bound');
    }
    foreach ($CATALOGUE as $spec) {
        $course = $DB->get_record('course', ['shortname' => $spec['shortname']]);
        if (!$course) { continue; }
        foreach ($cohorts as $cohort) {
            $exists = $DB->record_exists('enrol', [
                'courseid' => $course->id, 'enrol' => 'cohort', 'customint1' => $cohort->id]);
            if ($exists) { continue; }
            $cohortplugin->add_instance((object) $course, [
                'customint1' => $cohort->id,
                'roleid'     => $studentrole,
                'status'     => ENROL_INSTANCE_ENABLED,
            ]);
            cli_writeln('  + cohort enrol: ' . $cohort->idnumber . ' -> ' . $spec['shortname']);
        }
    }
    // Make the new cohort bindings take effect immediately rather than at cron.
    if ($cohorts && file_exists($CFG->dirroot . '/enrol/cohort/locallib.php')) {
        require_once($CFG->dirroot . '/enrol/cohort/locallib.php');
        enrol_cohort_sync(new \null_progress_trace());
    }
}

purge_all_caches();
cli_writeln('OK: ' . count($CATALOGUE) . ' demo courses seeded (visible, self-enrolable, one depthcontent activity each)');
