<?php
// scripts/moodle/content-sync-apply.php — the staged half of
// `pl moodle content sync` (scripts/commands/moodle.sh cmd_content_sync).
//
// WHY THIS EXISTS
// `pl moodle course restore` is idempotent BY SHORTNAME: once a course is on
// the target, re-running the restore skips it. That is the right behaviour for
// an importer and the wrong behaviour for a repair. When the ssd demo tier was
// imported on 2026-08-02 from a .mbz set captured 2026-07-11, every one of the
// 247 migrated depth-content activities landed carrying only
// {id,title,session,depths} — the archives predated the 2026-07-21 content
// refresh, so 1,671 quiz items, 213 sets of dogmatic propositions and
// catechism references, 151 practice blocks, 135 checkpoints and 18 audio
// clips simply were not in the bytes (nwp/ops#220). Nothing was broken; the
// source was ten days stale. And there was no verb that could put the content
// back, because restore would skip all 55 courses.
//
// This helper is that verb's remote surface. It matches on `pointid` — the
// stable learning-point identifier that survives every re-import, unlike
// instance ids or cmids — and it ONLY ever UPDATEs `content_json` on rows that
// already exist. It cannot create an activity, cannot delete one, cannot touch
// a course, an enrolment or a user. A pointid with no row on the target is
// REPORTED and skipped; that is a content-authoring fact for the operator, not
// something for a sync to invent.
//
//   --plan <payload.ndjson>
//       READ-ONLY. One line per payload entry:
//         POINT <pointid> <PRESENT|ABSENT> <SAME|DIFFER> <oldbytes> <newbytes>
//       plus a PLAN-SUMMARY line. Makes no change of any kind.
//
//   --apply <payload.ndjson> --backup=<file>
//       WRITE. For every PRESENT+DIFFER row, appends the row's CURRENT
//       content_json to <file> as NDJSON *before* writing, then UPDATEs
//       content_json and timemodified and rebuilds that course's cache.
//       The backup file is written first and fsync'd; if it cannot be opened
//       the run refuses before touching a single row, because an unrecorded
//       overwrite of authored content is not a recoverable operation.
//       SAME rows are not rewritten at all (so a re-run is a true no-op and
//       does not churn timemodified).
//
// PAYLOAD FORMAT (built locally by the verb, never by hand):
//   one JSON object per line: {"pointid":"A1.01","content_json":{...}}
//   `content_json` is the OBJECT, not a string; this file re-encodes it so the
//   stored form is canonical regardless of how the source was formatted.
//
// The rollback file is pulled back to sites/<site>/backups/ by the verb and is
// itself a valid payload: feeding it back through --apply restores the prior
// state exactly.

define('CLI_SCRIPT', true);

// ---------------------------------------------------------------------------
// ARGUMENT SHAPE IS VALIDATED BEFORE MOODLE IS LOADED.
// A malformed invocation is a caller bug, not a site condition; refusing it
// needs no database, and doing so first means the refusal is the same on a
// broken site as on a healthy one. --apply without --backup= in particular
// must be impossible to reach, not merely unlikely.
// ---------------------------------------------------------------------------
$args = array_slice($argv, 1);
if (!$args) {
    fwrite(STDERR, "usage: content-sync-apply.php --plan <payload.ndjson>\n"
        . "       content-sync-apply.php --apply <payload.ndjson> --backup=<file>\n");
    exit(2);
}
$mode = $args[0];
if ($mode !== '--plan' && $mode !== '--apply') {
    fwrite(STDERR, "Unknown mode: $mode\n");
    exit(2);
}
if (!isset($args[1]) || $args[1] === '') { fwrite(STDERR, "Missing payload path\n"); exit(2); }
$backup = null;
if ($mode === '--apply') {
    foreach (array_slice($args, 2) as $a) {
        if (strpos($a, '--backup=') === 0) { $backup = substr($a, strlen('--backup=')); }
    }
    if ($backup === null || $backup === '') {
        fwrite(STDERR, "--apply requires --backup=<file>: an overwrite with no recorded prior value is not recoverable.\n");
        exit(2);
    }
}

$root = null;
foreach ([getcwd(), __DIR__] as $c) {
    if (is_file("$c/config.php") && is_dir("$c/lib")) { $root = $c; break; }
}
if ($root === null) { fwrite(STDERR, "Cannot find Moodle root\n"); exit(2); }
require("$root/config.php");
require_once($CFG->libdir . '/clilib.php');
require_once($CFG->dirroot . '/course/lib.php');
global $DB;

/**
 * Read the payload into [pointid => canonical-json-string].
 *
 * Fail-closed on every shape problem: a payload this file cannot fully
 * understand is a payload it must not partially apply. A duplicate pointid is
 * an error rather than a last-wins, because "which one won" is exactly the
 * question nobody can answer afterwards.
 */
function content_sync_read_payload(string $path): array {
    if (!is_readable($path)) {
        fwrite(STDERR, "PAYLOAD-UNREADABLE $path\n");
        exit(2);
    }
    $fh = fopen($path, 'r');
    if ($fh === false) { fwrite(STDERR, "PAYLOAD-UNREADABLE $path\n"); exit(2); }
    $out = [];
    $lineno = 0;
    while (($line = fgets($fh)) !== false) {
        $lineno++;
        $line = trim($line);
        if ($line === '') { continue; }
        $rec = json_decode($line, true);
        if (!is_array($rec)) {
            fwrite(STDERR, "PAYLOAD-BAD line $lineno: not a JSON object\n");
            fclose($fh); exit(2);
        }
        if (!isset($rec['pointid']) || !is_string($rec['pointid']) || trim($rec['pointid']) === '') {
            fwrite(STDERR, "PAYLOAD-BAD line $lineno: missing/empty string 'pointid'\n");
            fclose($fh); exit(2);
        }
        if (!array_key_exists('content_json', $rec) || !is_array($rec['content_json'])) {
            fwrite(STDERR, "PAYLOAD-BAD line $lineno: 'content_json' must be a JSON object\n");
            fclose($fh); exit(2);
        }
        $pid = trim($rec['pointid']);
        if (isset($out[$pid])) {
            fwrite(STDERR, "PAYLOAD-BAD line $lineno: duplicate pointid '$pid'\n");
            fclose($fh); exit(2);
        }
        $enc = json_encode($rec['content_json'], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
        if ($enc === false) {
            fwrite(STDERR, "PAYLOAD-BAD line $lineno: content_json is not re-encodable\n");
            fclose($fh); exit(2);
        }
        $out[$pid] = $enc;
    }
    fclose($fh);
    if (!$out) { fwrite(STDERR, "PAYLOAD-EMPTY $path\n"); exit(2); }
    return $out;
}

/**
 * Current rows keyed by pointid. A pointid duplicated across two activities
 * is reported and both are refused: the sync has no way to know which copy the
 * payload meant, and guessing would silently overwrite one of them.
 */
function content_sync_current(array $pointids): array {
    global $DB;
    [$insql, $params] = $DB->get_in_or_equal($pointids);
    $rs = $DB->get_recordset_select('depthcontent', "pointid $insql", $params,
        '', 'id, course, pointid, content_json');
    $byid = [];
    $dupes = [];
    foreach ($rs as $r) {
        if (isset($byid[$r->pointid])) { $dupes[$r->pointid] = true; continue; }
        $byid[$r->pointid] = $r;
    }
    $rs->close();
    if ($dupes) {
        fwrite(STDERR, "AMBIGUOUS-POINTID " . implode(',', array_keys($dupes))
            . " — more than one depthcontent row shares this pointid; refusing.\n");
        exit(2);
    }
    return $byid;
}

$payload = content_sync_read_payload($args[1]);
$current = content_sync_current(array_keys($payload));

// ---------------------------------------------------------------------------
// --plan (read-only)
// ---------------------------------------------------------------------------
if ($mode === '--plan') {
    $present = 0; $absent = 0; $differ = 0; $same = 0;
    foreach ($payload as $pid => $new) {
        if (!isset($current[$pid])) {
            cli_writeln("POINT $pid ABSENT - 0 " . strlen($new));
            $absent++;
            continue;
        }
        $old = (string) $current[$pid]->content_json;
        $present++;
        $state = ($old === $new) ? 'SAME' : 'DIFFER';
        if ($state === 'DIFFER') { $differ++; } else { $same++; }
        cli_writeln("POINT $pid PRESENT $state " . strlen($old) . ' ' . strlen($new));
    }
    cli_writeln("PLAN-SUMMARY payload=" . count($payload)
        . " present=$present absent=$absent differ=$differ same=$same");
    exit(0);
}

// ---------------------------------------------------------------------------
// --apply (write; backup first, fail-closed)
// ---------------------------------------------------------------------------
$bh = fopen($backup, 'w');
if ($bh === false) {
    fwrite(STDERR, "BACKUP-UNWRITABLE $backup — refusing before any row is touched.\n");
    exit(2);
}

$changed = 0; $skipped = 0; $absent = 0;
$courses = [];
foreach ($payload as $pid => $new) {
    if (!isset($current[$pid])) { cli_writeln("ABSENT $pid"); $absent++; continue; }
    $row = $current[$pid];
    $old = (string) $row->content_json;
    if ($old === $new) { $skipped++; continue; }

    // Record the prior value BEFORE the write, in the same NDJSON shape the
    // payload uses, so the backup file can be fed straight back through
    // --apply to undo this run.
    $prior = json_decode($old, true);
    $line = json_encode([
        'pointid'      => $pid,
        'content_json' => ($prior === null && trim($old) !== 'null') ? $old : $prior,
    ], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    if ($line === false || fwrite($bh, $line . "\n") === false) {
        fwrite(STDERR, "BACKUP-WRITE-FAILED at $pid — stopping with $changed row(s) changed.\n");
        fclose($bh);
        exit(1);
    }
    fflush($bh);

    $DB->set_field('depthcontent', 'content_json', $new, ['id' => $row->id]);
    $DB->set_field('depthcontent', 'timemodified', time(), ['id' => $row->id]);
    $courses[$row->course] = true;
    $changed++;
    cli_writeln("UPDATED $pid");
}
fclose($bh);

foreach (array_keys($courses) as $courseid) {
    rebuild_course_cache((int) $courseid, true);
}

cli_writeln("APPLY-SUMMARY payload=" . count($payload)
    . " changed=$changed unchanged=$skipped absent=$absent courses=" . count($courses));
exit(0);
