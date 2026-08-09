<?php
// ops#278 — recreate the v1 ten-tile "Where would you like to begin?" intent
// view (option C, OPERATOR RULING 2026-08-06) as the ssd front page.
//
// Staged into the Moodle root and run there by scripts/demo/ssd-front-page-tiles.sh:
//   php8.3 ssd-front-page-tiles.php [--probe|--check]
//
// Source of the markup: the rescued sso v1 front page
// (~/central/rescued/sso-v1-front-page-2026-08-06/front-page.html) — the ten
// intent tiles + inline CSS, adapted per the ruling recorded on ops#278:
//   * tile links by SHORTNAME (/course/view.php?name=A1 …), never by id —
//     shortnames survive golden resets and reseeds, ids do not;
//   * below the tiles, the ordered secondary navigation:
//     by ascent (/local/browse?view=ascent) → category view (/course/index.php)
//     → browse everything (/local/browse?view=all);
//   * the v1 "create a free account" signup line is DROPPED — ssd has
//     self-registration off (accounts arrive by SSO from nwd), so the v1
//     signup link would be a dead link;
//   * the v1 footer stats ("49 courses • 267 sessions • ~67 hours") described
//     the v1 catalogue; ssd's restored catalogue is a superset (56 A1–J7
//     courses, probed 2026-08-09), so the stats are COMPUTED from the live
//     rows at apply time — same format, true numbers;
//   * mechanism: the SITE course section-1 summary (the front-page summary
//     block). NOT additionalhtmltopofbody — that config slot is owned by the
//     demo-posture banner (ssd-demo-posture.php) and the posture --check
//     asserts its exact value.
//
// MODES
//   --probe  read-only recon: current frontpage settings, section-1 state
//            (summary as base64 — the rollback value), shortname presence,
//            Category 1 state, /local/browse presence. Writes NOTHING.
//   --check  exit 0 only if the tile page is fully applied (post-apply and
//            post-golden verification). Writes NOTHING.
//   (none)   apply, idempotently. Fail-closed: any missing tile shortname or
//            a NON-EMPTY visible stock "Category 1" refuses before any write.
//
// Rollback (recorded on ops#278): frontpage='6', frontpageloggedin='6',
// section-1 summary was ABSENT (no course_sections row for section 1) before
// the first apply — restore = delete the row again, or blank its summary.

define('CLI_SCRIPT', true);

$root = null;
foreach ([getcwd(), __DIR__] as $cand) {
    if (is_file("$cand/config.php") && is_dir("$cand/lib")) { $root = $cand; break; }
}
if ($root === null) { fwrite(STDERR, "Cannot find Moodle root\n"); exit(2); }
require("$root/config.php");
require_once($CFG->libdir . '/clilib.php');
require_once($CFG->dirroot . '/course/lib.php');

$probe = in_array('--probe', $argv, true);
$checkonly = in_array('--check', $argv, true);

// ---------------------------------------------------------------------------
// The ten tiles, verbatim from the rescued v1 HTML (colour, question, blurb,
// course-code hint, button label), plus the SHORTNAME the ruling substitutes
// for v1's numeric ids.
// ---------------------------------------------------------------------------
$tiles = [
    ['#2E7D32', 'I want to learn the basics of the spiritual life',
     'The essential framework: the universal call to holiness, the Interior Castle, and the three phases of spiritual growth.',
     'Start with A1, A2, or A3 (any order)', 'Start with Foundations', 'A1'],
    ['#1565C0', 'I want to start a prayer life',
     'Why prayer matters, how to set up your prayer time, and the ancient art of praying with Scripture.',
     'B1, then B2, then B3', 'Start Praying', 'B1'],
    ['#6A1B9A', 'I want to understand what&#039;s happening in my prayer',
     'When prayer changes, grows quieter, or goes dry &mdash; something profound may be happening.',
     'C1 or C4', 'Explore Prayer Growth', 'C1'],
    ['#E65100', 'I want to deal with spiritual highs and lows',
     'Understand the battle within and learn Ignatian discernment of consolation and desolation.',
     'D1, then D2', 'Learn Discernment', 'D1'],
    ['#00838F', 'I want to grow in virtue and self-knowledge',
     'Discover your predominant fault, or take the gentle path of St. Therese\'s Little Way.',
     'E1 or E4', 'Know Yourself', 'E1'],
    ['#AD1457', 'I want to understand my suffering',
     'Everything is willed or permitted by God. Your suffering has meaning and redemptive power.',
     'F1, then F2', 'Find Meaning in Suffering', 'F1'],
    ['#C62828', 'I want to strengthen my marriage spiritually',
     'Apply the Interior Castle to married life and learn to resist spiritual attacks on your relationship.',
     'G1, then G2', 'Strengthen Your Marriage', 'G1'],
    ['#F9A825', 'I want to be inspired by a saint',
     'Walk with St. Therese of Lisieux or Fr. Jacques Philippe as your spiritual guide.',
     'H1 (Therese) or H4 (Philippe)', 'Meet the Saints', 'H1'],
    ['#546E7A', 'I want to evaluate a practice someone recommended',
     'Centering Prayer, mindfulness, yoga &mdash; evaluate popular practices in light of Catholic tradition.',
     'I1, I2, or I3', 'Evaluate Practices', 'I1'],
    ['#4E342E', 'I want to take the deep journey through Teresa&#039;s castle',
     'The complete journey through all seven mansions of the Interior Castle. The full spiritual life.',
     'J1 through J7', 'Enter the Castle', 'J1'],
];

// ---------------------------------------------------------------------------
// Facts read off the site.
// ---------------------------------------------------------------------------
$site = $DB->get_record('course', ['id' => SITEID], '*', MUST_EXIST);
$section1 = $DB->get_record('course_sections', ['course' => SITEID, 'section' => 1]);
$format = course_get_format($site);
$fopts = $format->get_format_options();
$numsections = isset($fopts['numsections']) ? (int) $fopts['numsections'] : null;

$missing = [];
$found = [];
foreach ($tiles as $t) {
    $sn = $t[5];
    $c = $DB->get_record('course', ['shortname' => $sn], 'id,shortname,visible,category');
    if ($c) { $found[$sn] = $c; } else { $missing[] = $sn; }
}

// The A1–J7 DIR catalogue the footer stats describe.
$dircourses = [];
$dircourseids = [];
foreach ($DB->get_records_select('course', "id <> ?", [SITEID], '', 'id,shortname,visible') as $c) {
    if (preg_match('/^[A-J]\d+$/', trim((string) $c->shortname))) {
        $dircourses[] = trim((string) $c->shortname);
        $dircourseids[] = (int) $c->id;
    }
}
sort($dircourses);
$dircount = count($dircourses);

// Sessions = depthcontent activities across the DIR courses (each is one
// ~15-minute daily session — the same unit the v1 footer counted).
$sessions = 0;
$depthmoduleid = $DB->get_field('modules', 'id', ['name' => 'depthcontent']);
if ($depthmoduleid && $dircourseids) {
    [$insql, $inparams] = $DB->get_in_or_equal($dircourseids);
    $sessions = (int) $DB->count_records_select('course_modules',
        "module = ? AND deletioninprogress = 0 AND course $insql",
        array_merge([$depthmoduleid], $inparams));
}
$hours = (int) round($sessions * 15 / 60);

$cat1 = $DB->get_record('course_categories', ['name' => 'Category 1']);
$cat1state = 'absent';
if ($cat1) {
    $ncourses = (int) $DB->count_records('course', ['category' => $cat1->id]);
    $nsubcats = (int) $DB->count_records('course_categories', ['parent' => $cat1->id]);
    $cat1state = sprintf('id=%d visible=%d courses=%d subcats=%d',
        $cat1->id, (int) $cat1->visible, $ncourses, $nsubcats);
}

$browse_present = is_file($CFG->dirroot . '/local/browse/index.php') ? 'yes' : 'NO';

// ---------------------------------------------------------------------------
// The summary block: v1 inline CSS + hero + tiles + footer. One rule added so
// the three secondary-nav buttons in the footer do not touch (v1's footer had
// a single button).
// ---------------------------------------------------------------------------
$style = '<style>'
    . '.dir-hero { text-align:center; padding:30px 20px 10px; }'
    . '.dir-hero h2 { font-size:1.8em; color:#333; margin-bottom:10px; }'
    . '.dir-hero p { font-size:1.1em; color:#555; max-width:700px; margin:0 auto; line-height:1.6; }'
    . '.dir-tiles { display:grid; grid-template-columns:repeat(auto-fill,minmax(280px,1fr)); gap:20px; padding:20px; max-width:1200px; margin:0 auto; }'
    . '.dir-tile { background:#fff; border-radius:12px; padding:24px; box-shadow:0 2px 8px rgba(0,0,0,0.1); transition:transform 0.2s,box-shadow 0.2s; }'
    . '.dir-tile:hover { transform:translateY(-3px); box-shadow:0 6px 20px rgba(0,0,0,0.15); }'
    . '.dir-tile .tq { font-style:italic; font-size:1.05em; margin-bottom:10px; font-weight:600; }'
    . '.dir-tile .tc { font-size:0.9em; color:#666; margin-bottom:12px; }'
    . '.dir-tile .tb { display:inline-block; color:#fff; padding:8px 18px; border-radius:6px; text-decoration:none; font-size:0.9em; }'
    . '.dir-tile .tb:hover { opacity:0.9; color:#fff; text-decoration:none; }'
    . '.dir-footer { text-align:center; padding:20px; margin-top:10px; }'
    . '.dir-footer .dir-browse { display:inline-block; background:#333; color:#fff; padding:10px 24px; border-radius:6px; text-decoration:none; margin:4px 6px; }'
    . '.dir-footer .dir-browse:hover { background:#555; color:#fff; text-decoration:none; }'
    . '</style>';

$hero = '<div class="dir-hero">'
    . '<h2>Divine Intimacy Radio: Spiritual Life Courses</h2>'
    . '<p>' . $dircount . ' self-contained mini-courses on the spiritual life. Each takes just 15 minutes per day, completable in one week.</p>'
    . '<p><strong>Where would you like to begin?</strong></p>'
    . '</div>';

$tilehtml = '<div class="dir-tiles">';
foreach ($tiles as [$colour, $q, $blurb, $hint, $btn, $shortname]) {
    $url = '/course/view.php?name=' . rawurlencode($shortname);
    $tilehtml .= '<div class="dir-tile" style="border-left:5px solid ' . $colour . ';">'
        . '<p class="tq" style="color:' . $colour . ';">&ldquo;' . $q . '&rdquo;</p>'
        . '<p>' . $blurb . '</p>'
        . '<p class="tc">' . $hint . '</p>'
        . '<a href="' . $url . '" class="tb" style="background:' . $colour . ';">' . $btn . '</a>'
        . '</div>';
}
$tilehtml .= '</div>';

// Footer stats in the v1 format with numbers computed above; then the ordered
// secondary navigation per the ruling: by ascent → category view → browse
// everything.
$stats = '<strong>' . $dircount . ' courses</strong>';
if ($sessions > 0) {
    $stats .= ' &bull; <strong>' . $sessions . ' sessions</strong>'
        . ' &bull; <strong>~' . $hours . ' hours of learning</strong>';
}
$stats .= ' &bull; <strong>15 minutes per day</strong>';

$footer = '<div class="dir-footer">'
    . '<p style="color:#666;">' . $stats . '</p>'
    . '<p style="color:#888;font-size:0.9em;">Based on the teachings of Divine Intimacy Radio.</p>'
    . '<p style="margin-top:10px;">'
    . '<a href="/local/browse/?view=ascent" class="dir-browse">Browse by Ascent</a> '
    . '<a href="/course/index.php" class="dir-browse">Category View</a> '
    . '<a href="/local/browse/?view=browse" class="dir-browse">Browse Everything</a>'
    . '</p></div>';

$want_summary = '<div id="dir-frontpage-tiles">' . $style . $hero . $tilehtml . $footer . '</div>';
$want_frontpage = '';          // summary block only — the tile page IS the landing
$want_frontpageloggedin = '';

// ---------------------------------------------------------------------------
// --probe: report and exit. Writes nothing.
// ---------------------------------------------------------------------------
if ($probe) {
    cli_writeln('PROBE ssd front page (ops#278)');
    cli_writeln('moodle_release        = ' . $CFG->release);
    cli_writeln('wwwroot               = ' . $CFG->wwwroot);
    cli_writeln('frontpage             = ' . var_export($CFG->frontpage ?? null, true));
    cli_writeln('frontpageloggedin     = ' . var_export($CFG->frontpageloggedin ?? null, true));
    cli_writeln('forcelogin            = ' . var_export($CFG->forcelogin ?? null, true));
    cli_writeln('site.format           = ' . $site->format);
    cli_writeln('numsections           = ' . var_export($numsections, true));
    cli_writeln('section1.exists       = ' . ($section1 ? 'yes' : 'NO'));
    if ($section1) {
        cli_writeln('section1.name         = ' . var_export($section1->name, true));
        cli_writeln('section1.sequence     = ' . var_export($section1->sequence, true));
        cli_writeln('section1.summaryformat= ' . var_export($section1->summaryformat, true));
        cli_writeln('section1.summary.b64  = ' . base64_encode((string) $section1->summary));
        cli_writeln('section1.applied      = ' . ((string) $section1->summary === $want_summary ? 'yes' : 'no'));
    }
    cli_writeln('local_browse          = ' . $browse_present);
    cli_writeln('category1             = ' . $cat1state);
    cli_writeln('dir_course_count      = ' . $dircount . ' (shortnames ^[A-J]digit+$)');
    cli_writeln('dir_courses           = ' . implode(',', $dircourses));
    cli_writeln('dir_sessions          = ' . $sessions . ' (depthcontent activities) → ~' . $hours . 'h');
    foreach ($found as $sn => $c) {
        cli_writeln(sprintf('tile %-3s → course id=%d visible=%d category=%d', $sn, $c->id, (int) $c->visible, (int) $c->category));
    }
    foreach ($missing as $sn) {
        cli_writeln("tile $sn → MISSING");
    }
    exit($missing ? 1 : 0);
}

// ---------------------------------------------------------------------------
// Shared gate for --check and apply.
// ---------------------------------------------------------------------------
$bad = [];
if ($missing) { $bad[] = 'MISSING-SHORTNAMES:' . implode(',', $missing); }
foreach ($found as $sn => $c) {
    if (!(int) $c->visible) { $bad[] = "TILE-COURSE-HIDDEN:$sn"; }
}
if ($dircount < 10) { $bad[] = "TILE-COUNT:dir_course_count=$dircount — the DIR catalogue is not seeded"; }
if ($browse_present !== 'yes') { $bad[] = 'LOCAL-BROWSE-ABSENT'; }
if ($cat1 && (int) $cat1->visible) {
    $ncourses = (int) $DB->count_records('course', ['category' => $cat1->id]);
    $nsubcats = (int) $DB->count_records('course_categories', ['parent' => $cat1->id]);
    if ($ncourses > 0 || $nsubcats > 0) {
        // Non-empty stock category: where its contents belong is a human call.
        $bad[] = "CATEGORY1-NONEMPTY:courses=$ncourses,subcats=$nsubcats";
    } else if ($checkonly) {
        $bad[] = 'CATEGORY1-VISIBLE-EMPTY';   // apply hides it; check requires hidden
    }
}

if ($checkonly) {
    if (!$section1) { $bad[] = 'NO-SECTION-1'; }
    if ((string) ($section1->summary ?? '') !== $want_summary) { $bad[] = 'SUMMARY-DRIFT'; }
    if ((string) ($CFG->frontpage ?? '6') !== $want_frontpage) { $bad[] = 'FRONTPAGE-SETTING'; }
    if ((string) ($CFG->frontpageloggedin ?? '6') !== $want_frontpageloggedin) { $bad[] = 'FRONTPAGELOGGEDIN-SETTING'; }
    if ($numsections !== null && $numsections < 1) { $bad[] = 'NUMSECTIONS-0'; }
    if ($bad) { cli_writeln('FRONT-PAGE-TILES-FAIL: ' . implode(' ', $bad)); exit(1); }
    cli_writeln('FRONT-PAGE-TILES-OK');
    exit(0);
}

// ---------------------------------------------------------------------------
// Apply. Fail-closed on any gate finding — nothing is written on a bad gate.
// ---------------------------------------------------------------------------
if ($bad) {
    cli_writeln('REFUSED (nothing written): ' . implode(' ', $bad));
    exit(1);
}

// Old values, so the apply log carries its own rollback row.
cli_writeln('old frontpage             = ' . var_export($CFG->frontpage ?? null, true));
cli_writeln('old frontpageloggedin     = ' . var_export($CFG->frontpageloggedin ?? null, true));
cli_writeln('old section1              = ' . ($section1
    ? 'summary.b64:' . base64_encode((string) $section1->summary)
    : 'ABSENT (rollback = delete the section-1 row)'));

// Hide an EMPTY visible stock "Category 1" (this issue's original caveat) so
// the category view the footer links to shows no empty box.
if ($cat1 && (int) $cat1->visible) {
    $cat = core_course_category::get($cat1->id, IGNORE_MISSING, true);
    if ($cat) { $cat->hide(); cli_writeln('hid empty stock category "Category 1" (id=' . $cat1->id . ')'); }
}

// Make sure the front page renders section 1 at all.
if ($numsections !== null && $numsections < 1) {
    $format->update_course_format_options(['numsections' => 1]);
    cli_writeln('set site numsections = 1');
}
if (!$section1) {
    course_create_sections_if_missing($site, 1);
    $section1 = $DB->get_record('course_sections', ['course' => SITEID, 'section' => 1], '*', MUST_EXIST);
    cli_writeln('created site section-1 row (id=' . $section1->id . ')');
}

if ((string) $section1->summary !== $want_summary) {
    course_update_section($site, $section1, [
        'summary' => $want_summary,
        'summaryformat' => FORMAT_HTML,
    ]);
    cli_writeln('wrote section-1 summary (' . strlen($want_summary) . ' bytes, marker div id="dir-frontpage-tiles")');
} else {
    cli_writeln('section-1 summary already applied');
}

foreach (['frontpage' => $want_frontpage, 'frontpageloggedin' => $want_frontpageloggedin] as $name => $value) {
    if ((string) ($CFG->{$name} ?? '6') !== $value) {
        set_config($name, $value);
        cli_writeln("set $name = '" . $value . "'");
    }
}

purge_all_caches();
cli_writeln('OK: v1 ten-tile intent view applied as the ssd front page (ops#278 option C)');
