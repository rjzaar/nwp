<?php
/**
 * ops#139 — standalone red-green test for the logstore leak-detection logic.
 *
 * No Moodle, no DB, no network:  php canonical_id_test.php
 *
 * Why this test exists in this shape: the acceptance criterion for ops#139 is
 * "a fresh log dump for a test member contains no doctrine or practice title".
 * A checker that answers that question wrongly is worse than none, because it
 * would be used to re-rate DPIA risk R4 from High. So the RED cases here are
 * the point — each one is a leak that a naive checker would miss.
 */

require_once __DIR__ . '/leakcheck.php';

$passed = 0;
$failed = 0;

function ops139_assert(string $name, bool $ok, string $detail = '') {
    global $passed, $failed;
    if ($ok) {
        $passed++;
        printf("ok   %s\n", $name);
    } else {
        $failed++;
        printf("FAIL %s%s\n", $name, $detail !== '' ? "  — {$detail}" : '');
    }
}

// The titles as they really sit in mdl_depthcontent.name / local_practice_def.title.
$titles = ['Confession', 'The Examen', 'Sacrament of Penance', 'B5.03'];

// ---------------------------------------------------------------------------
// RED — leaks that must be caught
// ---------------------------------------------------------------------------

// L1: the literal leak. other['name'] holds the doctrine title on
// course_module_created (core mandates the field; see design §0).
$rows = [[
    'id'        => 41,
    'eventname' => '\\core\\event\\course_module_created',
    'objectid'  => 7,
    'other'     => 'a:3:{s:10:"modulename";s:12:"depthcontent";s:10:"instanceid";i:7;s:4:"name";s:10:"Confession";}',
]];
$f = ops139_find_title_leaks($rows, $titles);
ops139_assert('RED: serialised other[name] with a doctrine title is caught', count($f) === 1);
ops139_assert('RED: the finding names the leaking column', ($f[0]['column'] ?? '') === 'other');
ops139_assert('RED: the finding names the leaking title', ($f[0]['title'] ?? '') === 'Confession');
ops139_assert('RED: the finding names the event', ($f[0]['eventname'] ?? '') === '\\core\\event\\course_module_created');

// Already-unserialised array form must be searched too — a checker that only
// handled the raw string would silently pass on a dump that arrived decoded.
$rows = [[
    'id'        => 42,
    'eventname' => '\\core\\event\\course_module_updated',
    'other'     => ['modulename' => 'depthcontent', 'instanceid' => 7, 'name' => 'The Examen'],
]];
ops139_assert('RED: an unserialised other[] array is searched, not skipped',
    count(ops139_find_title_leaks($rows, $titles)) === 1);

// Case difference is still re-identifying.
$rows = [['id' => 43, 'eventname' => 'x', 'other' => 'name:confession']];
ops139_assert('RED: a case-different title still leaks',
    count(ops139_find_title_leaks($rows, $titles)) === 1);

// A title embedded in a free-text description column.
$rows = [['id' => 44, 'eventname' => 'x', 'description' => "The user viewed 'Sacrament of Penance'."]];
ops139_assert('RED: a title in any other column is caught',
    count(ops139_find_title_leaks($rows, $titles)) === 1);

// An unserialisable blob must be searched as raw text, never skipped as
// "can't parse, assume clean".
$rows = [['id' => 45, 'eventname' => 'x', 'other' => '{{corrupt Confession blob']];
ops139_assert('RED: an unparseable blob is searched as text, not assumed clean',
    count(ops139_find_title_leaks($rows, $titles)) === 1);

// Multiple leaks across rows are all reported, not just the first.
$rows = [
    ['id' => 46, 'eventname' => 'x', 'other' => 'name:Confession'],
    ['id' => 47, 'eventname' => 'y', 'other' => 'name:The Examen'],
];
ops139_assert('RED: every leaking row is reported',
    count(ops139_find_title_leaks($rows, $titles)) === 2);

// ---------------------------------------------------------------------------
// GREEN — the shape the fix produces must NOT be reported
// ---------------------------------------------------------------------------

// The declassified row: opaque instance id + canonical pointid, no title.
// This is what mod_depthcontent's own view event already emits (design §0).
$rows = [[
    'id'                => 50,
    'eventname'         => '\\mod_depthcontent\\event\\course_module_viewed',
    'objecttable'       => 'depthcontent',
    'objectid'          => 7,
    'contextinstanceid' => 19,
    'other'             => '',
]];
ops139_assert('GREEN: an opaque view row is clean',
    count(ops139_find_title_leaks($rows, $titles)) === 0);

// The canonical id itself must never be reported as a leak — it is the fix.
// A checker that flagged B5.03 would report success as failure.
$rows = [['id' => 51, 'eventname' => 'x', 'other' => 'a:1:{s:7:"pointid";s:5:"B5.03";}']];
ops139_assert('GREEN: the canonical id B5.03 is not treated as a title',
    count(ops139_find_title_leaks($rows, $titles)) === 0);

$rows = [['id' => 52, 'eventname' => 'x', 'other' => 'item:A1.01.q4']];
ops139_assert('GREEN: a canonical quiz item id is not treated as a title',
    count(ops139_find_title_leaks($rows, $titles)) === 0);

// cmidnumber carrying the pointid (the 2a patch) is clean.
$rows = [['id' => 53, 'eventname' => 'x', 'other' => 'a:1:{s:10:"cmidnumber";s:5:"B5.03";}']];
ops139_assert('GREEN: cmidnumber=pointid (the 2a patch output) is clean',
    count(ops139_find_title_leaks($rows, $titles)) === 0);

// An empty log is clean, and an empty title list cannot manufacture findings.
ops139_assert('GREEN: an empty log is clean', count(ops139_find_title_leaks([], $titles)) === 0);
ops139_assert('GREEN: no known titles yields no findings',
    count(ops139_find_title_leaks([['id' => 1, 'other' => 'Confession']], [])) === 0);

// Junk-short titles must not match everything.
ops139_assert('GREEN: a 1-2 char title is ignored rather than matching the whole log',
    count(ops139_find_title_leaks([['id' => 1, 'other' => 'aXb']], ['a', 'X'])) === 0);

// ---------------------------------------------------------------------------

printf("\n%d passed, %d failed\n", $passed, $failed);
exit($failed === 0 ? 0 : 1);
