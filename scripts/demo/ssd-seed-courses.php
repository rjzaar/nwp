<?php
// ops#133 Phase 2 — seed the ssd demo Moodle with courses a tester can
// actually walk into.
//
// Staged into the Moodle root and run there by scripts/demo/ssd-seed-courses.sh:
//   php8.3 ssd_seed_courses.php [--check] [--bind-cohorts]
//
// Standalone (no Moodle needed — used by tests/unit/test-ssd-seed-courses.bats):
//   php ssd-seed-courses.php --validate-file=<content_json file>
//   php ssd-seed-courses.php --schema-selftest
//
// IDEMPOTENT AND SELF-REPAIRING — re-running refreshes rather than duplicates
// (everything is keyed on course shortname / activity name), and an existing
// depthcontent row whose content_json fails schema validation is UPDATED IN
// PLACE. A schema-valid row is left untouched. The old seeder skipped every
// existing row unconditionally, which is how the 2026-08 broken rows got baked
// into the golden image with no way to reseed them out.
//
// SCHEMA IS DERIVED FROM THE MODULE'S READER, not from guesswork. Authority is
// ss-moodle-plugins mod/depthcontent (deployed at <moodle>/mod/depthcontent):
//   * view.php:89-97   — content_json decodes to {depths, quiz_items, practice}.
//   * view.php:352-366 — each depths.<level> must be an OBJECT: 'short' is read
//     via $ddata['summary'] (line 358), every other level via $ddata['text']
//     (line 362). A bare string renders NO section, so the page comes up blank.
//   * lib.php:28-33, 65-73 — the six levels: short, standard, longer, detailed,
//     advanced, scholar.
//   * view.php:529-537 — multichoice options must each be an OBJECT
//     {text, correct, feedback?}: line 533 reads $opt['correct'] with no guard,
//     which on a bare-string option is a PHP 8 TypeError (fatal page).
//   * view.php:103-113 — quiz item 'difficulty' maps to a depth section and
//     must be one of standard|longer|detailed|advanced.
// The 55 production courses (sites/ss/backups/course-mbz-2026-07-11) carry the
// same depths shape; none of them ships quiz_items, so the reader code above is
// the only authority for the quiz item schema.
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
//   * COMPLETION that can actually move: course enablecompletion=1 and the
//     module tracked with completion=2/completionview=1, exactly as every one
//     of the 55 prod courses is configured (course.xml <enablecompletion>1</>,
//     module.xml <completion>2</> <completionview>1</>); mod/depthcontent
//     declares FEATURE_COMPLETION_TRACKS_VIEWS (lib.php:83) and marks viewed
//     in depthcontent_view() (lib.php:156-157);
//   * with --bind-cohorts, an enrol_cohort instance for every auth_nwc-managed
//     guild cohort (idnumber prefix `nwcguild:`), so a guild-leader tester
//     arrives PRE-enrolled and can see the leader views immediately.
//
// NOTE: tests/e2e/ssc_setup.php (ss-moodle-plugins) still carries the old
// bare-string options shape this file used to copy — that fixture only ever
// proved enrolment wiring, never a rendered view.php, which is how the broken
// shape survived. Fix tracked separately in that repo.

define('CLI_SCRIPT', true);

// ---------------------------------------------------------------------------
// Schema: builder + validator. Defined BEFORE the Moodle bootstrap so the
// standalone modes (--validate-file / --schema-selftest) run on bare php-cli.
// ---------------------------------------------------------------------------

/** The six depth levels, in order. Mirrors mod/depthcontent/lib.php:65-73. */
function ssd_seed_depth_levels(): array {
    return ['short', 'standard', 'longer', 'detailed', 'advanced', 'scholar'];
}

/** Valid quiz item difficulties. Mirrors mod/depthcontent/view.php:103-108. */
function ssd_seed_quiz_difficulties(): array {
    return ['standard', 'longer', 'detailed', 'advanced'];
}

/**
 * Validate a content_json string against what mod/depthcontent's reader
 * actually consumes (citations above and inline). Returns [] when valid,
 * otherwise a list of human-readable problems.
 *
 * @param string $json Raw content_json column value.
 * @return string[] Problems; empty array means schema-valid.
 */
function ssd_seed_validate_content_json(string $json): array {
    $bad = [];
    $c = json_decode($json, true);
    if (!is_array($c)) {
        return ['content_json: does not decode to a JSON object'];
    }

    $depths = $c['depths'] ?? null;
    if (!is_array($depths) || $depths === []) {
        $bad[] = 'depths: missing or empty — view.php:95 finds no sections and the page renders blank';
    } else {
        $levels = ssd_seed_depth_levels();
        foreach ($depths as $level => $d) {
            if (!in_array($level, $levels, true)) {
                $bad[] = "depths.$level: unknown level (valid: " . implode('|', $levels) . ', lib.php:65-73)';
                continue;
            }
            if (!is_array($d)) {
                $bad[] = "depths.$level: bare string — the reader takes \$ddata['summary'/'text'] from an object"
                    . ' (view.php:358/362), so a bare string renders nothing';
                continue;
            }
            if ($level === 'short') {
                if (!isset($d['summary']) || !is_string($d['summary']) || trim($d['summary']) === '') {
                    $bad[] = "depths.short.summary: missing/empty string (view.php:358)";
                }
            } else if (!isset($d['text']) || !is_string($d['text']) || trim($d['text']) === '') {
                $bad[] = "depths.$level.text: missing/empty string (view.php:362)";
            }
        }
    }

    $items = $c['quiz_items'] ?? [];
    if (!is_array($items)) {
        $bad[] = 'quiz_items: must be an array (view.php:96)';
        $items = [];
    }
    foreach ($items as $i => $item) {
        if (!is_array($item)) {
            $bad[] = "quiz_items[$i]: must be an object";
            continue;
        }
        if (empty($item['question']) || !is_string($item['question'])) {
            $bad[] = "quiz_items[$i].question: missing (view.php:525)";
        }
        if (isset($item['difficulty']) && !in_array($item['difficulty'], ssd_seed_quiz_difficulties(), true)) {
            $bad[] = "quiz_items[$i].difficulty: '" . $item['difficulty'] . "' not one of "
                . implode('|', ssd_seed_quiz_difficulties()) . ' (view.php:103-108)';
        }
        $type = $item['type'] ?? 'multichoice';
        if ($type === 'multichoice') {
            $opts = $item['options'] ?? null;
            if (!is_array($opts) || $opts === []) {
                $bad[] = "quiz_items[$i].options: missing/empty (view.php:529)";
                continue;
            }
            $ncorrect = 0;
            foreach ($opts as $o => $opt) {
                if (!is_array($opt)) {
                    $bad[] = "quiz_items[$i].options[$o]: bare string — view.php:533 reads \$opt['correct']"
                        . ' unguarded, a PHP 8 TypeError (fatal) on render';
                    continue;
                }
                if (!isset($opt['text']) || !is_string($opt['text']) || trim($opt['text']) === '') {
                    $bad[] = "quiz_items[$i].options[$o].text: missing/empty (view.php:536)";
                }
                if (!array_key_exists('correct', $opt)) {
                    $bad[] = "quiz_items[$i].options[$o].correct: missing (view.php:533)";
                } else if (!empty($opt['correct'])) {
                    $ncorrect++;
                }
            }
            if ($ncorrect === 0) {
                $bad[] = "quiz_items[$i].options: no option marked correct — the quiz can never be answered right"
                    . ' (inline_quiz.js checks data-correct===1)';
            }
        }
    }

    return $bad;
}

/**
 * Build the content_json for one catalogue entry, in exactly the shape the
 * reader consumes (and the same top-level envelope the 55 prod mbz carry:
 * id/title/session/depths, plus quiz_items/practice).
 *
 * Deterministic: same spec in, same JSON out — that is what makes a second
 * seeding run a no-op on a row this builder wrote.
 *
 * @param array $spec One $CATALOGUE entry.
 * @return string JSON.
 */
function ssd_seed_build_content_json(array $spec): string {
    $body = $spec['body'];
    $note = 'Demo content — everything here is erased nightly.';
    $depths = [
        'short'    => ['summary' => $spec['short'] . ' ' . $note],
        'standard' => ['text' => $body . "\n\n" . $note],
    ];
    // Deeper levels carry visibly longer demo treatments so the depth selector
    // has something real to switch between at every one of the six levels.
    foreach (['longer', 'detailed', 'advanced', 'scholar'] as $level) {
        $depths[$level] = ['text' => $body . "\n\n"
            . 'At the **' . $level . '** depth a real course carries a fuller treatment '
            . '(sources, doctrinal notes, primary texts). This demo level exists so the '
            . 'depth selector can be exercised end to end. ' . $note];
    }
    $content = [
        'id'      => $spec['point'],
        'title'   => $spec['activity'],
        'session' => 1,
        'depths'  => $depths,
        'quiz_items' => [[
            'id'         => 'q1',
            'difficulty' => 'standard',
            'type'       => 'multichoice',
            'question'   => $spec['question'],
            'options'    => $spec['options'],
        ]],
        'practice' => null,
    ];
    return json_encode($content, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
}

/**
 * The demo catalogue. `point` is the depthcontent catalog id (pointid column,
 * char(20) NOT NULL — keep these short). `options` are reader-shaped:
 * {text, correct, feedback} per view.php:529-537.
 */
$CATALOGUE = [
    [
        'shortname' => 'demo_prayer',
        'fullname'  => 'Beginning Prayer',
        'summary'   => 'A short walk through the shape of Christian prayer. Demo content — everything here is erased nightly.',
        'activity'  => 'Praying with Scripture',
        'point'     => 'demo.prayer.1',
        'short'     => 'Prayer is the raising of the mind and heart to God.',
        'question'  => 'Which of these is a form of prayer the Church has always practised?',
        'options'   => [
            ['text' => 'Lectio divina', 'correct' => true,
             'feedback' => 'Yes — praying with Scripture is ancient and constant practice.'],
            ['text' => 'Sitting quietly until you feel nothing at all', 'correct' => false,
             'feedback' => 'Christian prayer seeks God, not emptiness for its own sake.'],
        ],
        'body'      => 'Prayer is the raising of the mind and heart to God. This demo activity exists so you can click something and see what happens.',
    ],
    [
        'shortname' => 'demo_creed',
        'fullname'  => 'The Creed, Line by Line',
        'summary'   => 'What we say we believe, one line at a time. Demo content — erased nightly.',
        'activity'  => 'I believe in one God',
        'point'     => 'demo.creed.1',
        'short'     => 'The Creed is a summary of the faith.',
        'question'  => 'The Nicene Creed begins with which word?',
        'options'   => [
            ['text' => 'I believe', 'correct' => true,
             'feedback' => 'Credo — the Creed opens with an act of personal faith.'],
            ['text' => 'Perhaps', 'correct' => false,
             'feedback' => 'The Creed is a confession, not a hedge.'],
        ],
        'body'      => 'The Creed is a summary of the faith. This is demo content for testing.',
    ],
    [
        'shortname' => 'demo_discern',
        'fullname'  => 'Discernment Basics',
        'summary'   => 'Noticing what moves you, and where it is going. Demo content — erased nightly.',
        'activity'  => 'Consolation and desolation',
        'point'     => 'demo.discern.1',
        'short'     => 'Discernment begins with attention.',
        'question'  => 'Consolation, in the Ignatian sense, chiefly means…',
        'options'   => [
            ['text' => 'A movement toward God', 'correct' => true,
             'feedback' => 'Yes — consolation is whatever draws the soul toward God.'],
            ['text' => 'Feeling pleased with yourself', 'correct' => false,
             'feedback' => 'Pleasant feelings can accompany either movement; the direction is what matters.'],
        ],
        'body'      => 'Discernment begins with attention. Demo content for testing.',
    ],
];

// ---------------------------------------------------------------------------
// Standalone modes (no Moodle): exercised by tests/unit/test-ssd-seed-courses.bats.
// These MUST run before the config.php bootstrap.
// ---------------------------------------------------------------------------
foreach (($argv ?? []) as $arg) {
    if (preg_match('/^--validate-file=(.+)$/', $arg, $m)) {
        $raw = @file_get_contents($m[1]);
        if ($raw === false) { fwrite(STDERR, "cannot read {$m[1]}\n"); exit(2); }
        $problems = ssd_seed_validate_content_json($raw);
        if ($problems) {
            foreach ($problems as $p) { echo "SCHEMA-FAIL: $p\n"; }
            exit(1);
        }
        echo "SCHEMA-OK\n";
        exit(0);
    }
}
if (in_array('--schema-selftest', $argv ?? [], true)) {
    // Every catalogue entry the builder produces must pass the validator —
    // which is precisely the property that makes the self-repair loop
    // idempotent: a row this builder wrote validates clean, so a second run
    // leaves it untouched. Output is deterministic (asserted byte-for-byte
    // by the bats test running this twice).
    $fail = 0;
    foreach ($CATALOGUE as $spec) {
        $json = ssd_seed_build_content_json($spec);
        $problems = ssd_seed_validate_content_json($json);
        if ($problems) {
            $fail = 1;
            foreach ($problems as $p) { echo "SELFTEST-FAIL {$spec['shortname']}: $p\n"; }
        } else {
            echo "SELFTEST-OK {$spec['shortname']} sha1=" . sha1($json)
                . ' depths=' . count(json_decode($json, true)['depths']) . "\n";
        }
    }
    exit($fail);
}

// ---------------------------------------------------------------------------
// Moodle bootstrap.
// ---------------------------------------------------------------------------
$root = null;
foreach ([getcwd(), __DIR__] as $c) {
    if (is_file("$c/config.php") && is_dir("$c/lib")) { $root = $c; break; }
}
if ($root === null) { fwrite(STDERR, "Cannot find Moodle root\n"); exit(2); }
require("$root/config.php");
require_once($CFG->dirroot . '/course/lib.php');
require_once($CFG->dirroot . '/lib/enrollib.php');
require_once($CFG->libdir . '/completionlib.php');
require_once($CFG->libdir . '/clilib.php');
global $DB;

$checkonly    = in_array('--check', $argv, true);
$bindcohorts  = in_array('--bind-cohorts', $argv, true);

const CATNAME = 'Demo courses';
const GUILD_COHORT_PREFIX = 'nwcguild:';   // must match auth_nwc guild_cohort_map

// ---------------------------------------------------------------------------
// --check: report whether the catalogue is present, enterable AND renderable.
// A schema-invalid content_json row is a FAILURE here — view.php renders it
// blank (depths) or fatals (bare-string quiz options), which is exactly the
// state that reached testers in 2026-08 while --check stayed green.
// ---------------------------------------------------------------------------
if ($checkonly) {
    $bad = [];
    foreach ($CATALOGUE as $spec) {
        $course = $DB->get_record('course', ['shortname' => $spec['shortname']]);
        if (!$course)              { $bad[] = $spec['shortname'] . ':missing';  continue; }
        if (empty($course->visible)) { $bad[] = $spec['shortname'] . ':hidden'; }
        if (empty($course->enablecompletion)) { $bad[] = $spec['shortname'] . ':completion-off'; }
        $self = $DB->get_record('enrol', ['courseid' => $course->id, 'enrol' => 'self']);
        if (!$self || (int) $self->status !== ENROL_INSTANCE_ENABLED) {
            $bad[] = $spec['shortname'] . ':no-self-enrol';
        }
        $dc = $DB->get_record('depthcontent', ['course' => $course->id, 'name' => $spec['activity']]);
        if (!$dc) {
            $bad[] = $spec['shortname'] . ':no-activity';
            continue;
        }
        $problems = ssd_seed_validate_content_json((string) $dc->content_json);
        if ($problems) {
            $bad[] = $spec['shortname'] . ':bad-schema(' . $problems[0] . ')';
        }
        $cm = get_coursemodule_from_instance('depthcontent', $dc->id, $course->id);
        if (!$cm || (int) $cm->completion !== COMPLETION_TRACKING_AUTOMATIC
                || (int) $cm->completionview !== 1) {
            $bad[] = $spec['shortname'] . ':cm-completion-off';
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
    // -- course (visible; hidden courses reject a student's require_login;
    //    enablecompletion=1 as on every prod course, else progress never moves)
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
            'enablecompletion' => 1,
        ]);
        cli_writeln('created course: ' . $spec['shortname']);
    } else {
        if (empty($course->visible)) {
            $DB->set_field('course', 'visible', 1, ['id' => $course->id]);
            $course->visible = 1;
        }
        if (empty($course->enablecompletion)) {
            $DB->set_field('course', 'enablecompletion', 1, ['id' => $course->id]);
            $course->enablecompletion = 1;
            rebuild_course_cache($course->id, true);
            cli_writeln('  ~ repaired course: enablecompletion=1');
        }
    }

    // -- depthcontent activity with a real quiz item -------------------------
    $expectedjson = ssd_seed_build_content_json($spec);
    $dc = $DB->get_record('depthcontent', ['course' => $course->id, 'name' => $spec['activity']]);
    if (!$dc) {
        $dcid = $DB->insert_record('depthcontent', (object) [
            'course' => $course->id, 'name' => $spec['activity'], 'intro' => '',
            'introformat' => 1, 'pointid' => $spec['point'],
            'content_json' => $expectedjson, 'timemodified' => time(),
        ]);
        $cmid = add_course_module((object) [
            'course' => $course->id, 'module' => $moduleid, 'instance' => $dcid,
            'section' => 0, 'visible' => 1, 'added' => time(),
            // Track-by-view, as module.xml carries for all 55 prod courses.
            'completion' => COMPLETION_TRACKING_AUTOMATIC, 'completionview' => 1,
        ]);
        course_add_cm_to_section($course->id, $cmid, 0);
        \context_module::instance($cmid);
        rebuild_course_cache($course->id, true);
        cli_writeln('  + activity: ' . $spec['activity'] . ' (cmid=' . $cmid . ')');
    } else {
        // SELF-REPAIR: a row that fails the reader-derived schema is updated in
        // place; a valid row is untouched (second run is a no-op — the builder
        // is deterministic and its output validates, see --schema-selftest).
        $problems = ssd_seed_validate_content_json((string) $dc->content_json);
        if ($problems) {
            $DB->update_record('depthcontent', (object) [
                'id' => $dc->id, 'content_json' => $expectedjson, 'timemodified' => time(),
            ]);
            rebuild_course_cache($course->id, true);
            cli_writeln('  ~ repaired activity content_json: ' . $spec['activity']
                . ' (' . implode('; ', $problems) . ')');
        }
        $cm = get_coursemodule_from_instance('depthcontent', $dc->id, $course->id);
        if ($cm && ((int) $cm->completion !== COMPLETION_TRACKING_AUTOMATIC
                || (int) $cm->completionview !== 1)) {
            $DB->set_field('course_modules', 'completion', COMPLETION_TRACKING_AUTOMATIC, ['id' => $cm->id]);
            $DB->set_field('course_modules', 'completionview', 1, ['id' => $cm->id]);
            rebuild_course_cache($course->id, true);
            cli_writeln('  ~ repaired activity completion tracking: ' . $spec['activity']);
        }
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
cli_writeln('OK: ' . count($CATALOGUE) . ' demo courses seeded (visible, self-enrolable, completion-tracked, one depthcontent activity each)');
