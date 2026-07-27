<?php
/**
 * ops#139 — DONE-WHEN acceptance check.
 *
 * "A fresh log dump for a test member contains no doctrine or practice title."
 * (REMEDIATION-PLAN R1.4 / DPIA-v2 risk R4.)
 *
 * READ-ONLY. This script performs no INSERT, UPDATE or DELETE of any kind. It
 * reads logstore_standard_log for one user, reads the known doctrine/practice
 * titles, and reports any title found anywhere in the dump.
 *
 * Usage (from the Moodle root):
 *   php verify_logstore_declassified.php --userid=123
 *   php verify_logstore_declassified.php --username=testmember --limit=5000
 *
 * Exit 0 = clean (no title found). Exit 1 = leak found. Exit 2 = usage / not
 * runnable. It never exits 0 because it could not look: an unresolvable user
 * or an unreadable table is exit 2, not a pass.
 *
 * @package   ops139
 * @copyright NWP
 */

define('CLI_SCRIPT', true);

require(__DIR__ . '/../../../config.php');
require_once($CFG->libdir . '/clilib.php');
require_once(__DIR__ . '/leakcheck.php');

list($options, $unrecognised) = cli_get_params([
    'userid'   => 0,
    'username' => '',
    'limit'    => 20000,
    'help'     => false,
], ['h' => 'help']);

if ($options['help']) {
    cli_writeln("ops#139 logstore declassification check (read-only).");
    cli_writeln("  --userid=N | --username=NAME   the test member to dump");
    cli_writeln("  --limit=N                      max rows to read (default 20000)");
    exit(0);
}

global $DB;

// --- resolve the member; refuse to guess -----------------------------------
$userid = (int) $options['userid'];
if (!$userid && $options['username'] !== '') {
    $rec = $DB->get_record('user', ['username' => $options['username']], 'id', IGNORE_MISSING);
    if (!$rec) {
        cli_error("CANNOT-VERIFY: no user with username '{$options['username']}'.", 2);
    }
    $userid = (int) $rec->id;
}
if (!$userid) {
    cli_error("CANNOT-VERIFY: pass --userid or --username. Refusing to scan every user.", 2);
}
if (!$DB->record_exists('user', ['id' => $userid])) {
    cli_error("CANNOT-VERIFY: no user with id {$userid}.", 2);
}

// --- collect the known titles ----------------------------------------------
// These are the strings that must NOT appear in the log. Read from the DB
// rather than guessed, so the check cannot pass by failing to recognise one.
$titles = [];

if ($DB->get_manager()->table_exists('depthcontent')) {
    foreach ($DB->get_fieldset_sql('SELECT name FROM {depthcontent}') as $t) {
        $titles[] = $t;
    }
} else {
    cli_writeln("NOTE: table 'depthcontent' absent — no doctrine titles to assert against.");
}

if ($DB->get_manager()->table_exists('local_practice_def')) {
    foreach ($DB->get_fieldset_sql('SELECT title FROM {local_practice_def}') as $t) {
        $titles[] = $t;
    }
} else {
    cli_writeln("NOTE: table 'local_practice_def' absent — no practice titles to assert against.");
}

$meaningful = ops139_meaningful_titles($titles);
if (empty($meaningful)) {
    cli_error("CANNOT-VERIFY: zero known titles were loaded. A check with nothing to look "
        . "for would report clean for the wrong reason.", 2);
}

// --- dump the member's log rows --------------------------------------------
if (!$DB->get_manager()->table_exists('logstore_standard_log')) {
    cli_error("CANNOT-VERIFY: logstore_standard_log does not exist on this site.", 2);
}

$rows = $DB->get_records('logstore_standard_log', ['userid' => $userid], 'id ASC', '*',
    0, (int) $options['limit']);

// Rows where this member is the OBJECT rather than the actor also name them.
$related = $DB->get_records('logstore_standard_log', ['relateduserid' => $userid], 'id ASC', '*',
    0, (int) $options['limit']);

$all = [];
foreach ($rows as $r)    { $all[$r->id] = (array) $r; }
foreach ($related as $r) { $all[$r->id] = (array) $r; }

// logstore stores `other` as a serialised/JSON blob. Decode where we can, and
// keep the raw text as well so an undecodable blob is still searched.
foreach ($all as $id => $row) {
    if (!empty($row['other']) && is_string($row['other'])) {
        $decoded = @json_decode($row['other'], true);
        if ($decoded === null) {
            $decoded = @unserialize($row['other']);
        }
        if (is_array($decoded)) {
            $all[$id]['other_decoded'] = $decoded;
        }
    }
}

cli_writeln(sprintf("Scanned %d log row(s) for user %d against %d known title(s).",
    count($all), $userid, count($meaningful)));

// --- the assertion ----------------------------------------------------------
$findings = ops139_find_title_leaks(array_values($all), $titles);

if (empty($findings)) {
    cli_writeln("");
    cli_writeln("CLEAN — no doctrine or practice title appears in this member's log dump.");
    cli_writeln("ops#139 DONE-WHEN satisfied for this member; DPIA risk R4 can be re-rated.");
    exit(0);
}

cli_writeln("");
cli_writeln(sprintf("LEAK — %d finding(s). The native log names doctrine/practice for this member.",
    count($findings)));
cli_writeln("");

$byevent = [];
foreach ($findings as $f) {
    $key = $f['eventname'] . ' :: ' . $f['column'];
    $byevent[$key][] = $f['title'];
}
foreach ($byevent as $key => $titlelist) {
    $uniq = array_unique($titlelist);
    cli_writeln(sprintf("  %-70s %d row-hit(s), %d distinct title(s)",
        $key, count($titlelist), count($uniq)));
}

cli_writeln("");
cli_writeln("See docs/guides/ops139-logstore-declassification.md — the literal leak is");
cli_writeln("other['name'] on course_module_created/updated, whose origin is the course");
cli_writeln("module NAME being the doctrine title (populate_courses.php:187).");
exit(1);
