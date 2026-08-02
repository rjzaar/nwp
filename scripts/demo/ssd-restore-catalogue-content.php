<?php
// scripts/demo/ssd-restore-catalogue-content.php — put the CANONICAL quiz items
// (and the audio fallback clips) back into the 55 imported catalogue courses.
//
// ─── WHY THIS EXISTS (the defect, precisely) ────────────────────────────────
// The authoring corpus (~/dir/courses_v3/catalog/*.yaml) has carried quiz_items
// and per-depth video since its initial commit (dir c3cf95c, 2026-05-17).
// The converter that turns catalogue YAML into the per-learning-point JSON that
// mod_depthcontent's populate_courses.php loads — courses_v3/build/build_json.py
// — emitted ONLY the four base keys {id, title, session, depths}. Every other
// learning-point field, quiz_items among them, was silently dropped.
//
// That was fixed upstream in dir e9c596f (2026-07-09):
//   "The per-LP JSON builder emitted only {id,title,session,depths}, silently
//    dropping quiz_items, practice, related_points, catechism_paragraphs and
//    dogmatic_propositions — which is why mod_depthcontent rendered no quizzes.
//    ... Rebuild over the real catalog now emits 1,671 quiz items (was 0)"
//
// The fix landed, but the JSON was never rebuilt and re-imported before the
// 2026-07-11 .mbz export (sites/ss/backups/course-mbz-2026-07-11). So the mbz —
// and therefore the 2026-08-02 ssd 55-course import restored from it — carries
// the pre-fix shape. Proven on live ssd 2026-08-02: all 247 imported
// depthcontent rows decode to EXACTLY {depths, id, session, title}, the literal
// pre-e9c596f base shape, and mdl_quiz/mdl_question are 0 rows.
//
// Video was never lost: `video` lives INSIDE depths.<level>, which the base
// shape always carried. Live ssd already holds 175 youtube_id refs across 48
// courses, exactly matching the corpus. What video lacked was a RENDERER, added
// in dir 5aae249 (2026-07-22) and now deployed (view.php 723 lines, has
// depthcontent_render_video). `audio` (dir 3c88dd8, 2026-07-22) postdates the
// export, so its 18 blocks ARE missing and are restored here too.
//
// ─── WHAT IT DOES ───────────────────────────────────────────────────────────
// PURELY ADDITIVE. It sets two things on a matched row and touches nothing else:
//   * content_json.quiz_items                       (canonical assessment items)
//   * content_json.depths.<level>.audio             (video fallback clip)
// Depth prose (summary/text), video blocks, titles, sessions and ids are never
// read for writing and never modified — which matters, because live depth prose
// carries the ops#90 <details> XSS sanitisation and must not be rolled back.
//
// Rows are matched on content_json.id (the learning-point id, e.g. "A1.01"),
// which every imported row carries. No title or ordinal guessing.
//
// ─── HOW IT IS TRUSTED (one merge, one validator, a hash between them) ──────
// The schema authority is mod/depthcontent's reader, and the ONE implementation
// of it is ssd_seed_validate_content_json() in scripts/demo/ssd-seed-courses.php.
// This file does not reimplement it. Instead the wrapper runs three phases:
//
//   1. --dump           (on the target, READ-ONLY) emit {rowid, lpid, content_json}.
//   2. --merge-local    (no Moodle) apply nwp_dcrestore_merge() to that dump,
//                       write each merged document out, and the wrapper feeds
//                       every one to `ssd-seed-courses.php --validate-file=`.
//                       A single SCHEMA-FAIL aborts before anything is written.
//                       Emits a manifest of rowid → sha256(merged content_json).
//   3. --apply          (on the target) re-runs THE SAME nwp_dcrestore_merge()
//                       on the live row and REFUSES to write unless the result
//                       hashes to the value phase 2 validated.
//
// So the bytes that reach the database are the exact bytes a validator approved,
// and the merge logic exists once. A row whose live content_json changed between
// phase 1 and phase 3 hash-mismatches and is skipped loudly rather than written.
//
// IDEMPOTENT: re-running re-derives the same merged document, so a second apply
// writes nothing (reported as "already-current").
//
// Staged into the Moodle root and run there by
// scripts/demo/ssd-restore-catalogue-content.sh — never by hand.

define('CLI_SCRIPT', true);

// ---------------------------------------------------------------------------
// The merge. THE one place the recovery rule is written. Deterministic:
// same (live document, payload entry) in, same JSON out — that property is what
// the phase-2/phase-3 sha256 gate is checking.
// ---------------------------------------------------------------------------

/**
 * Merge one payload entry into one live content_json document, additively.
 *
 * @param array $live    Decoded live content_json.
 * @param array $entry   Payload entry: {quiz_items?, audio_by_depth?}.
 * @return array The merged document.
 */
function nwp_dcrestore_merge(array $live, array $entry): array {
    if (!empty($entry['quiz_items']) && is_array($entry['quiz_items'])) {
        $live['quiz_items'] = $entry['quiz_items'];
    }
    if (!empty($entry['audio_by_depth']) && is_array($entry['audio_by_depth'])) {
        foreach ($entry['audio_by_depth'] as $level => $audio) {
            // Only attach to a depth level the row actually has, and never
            // overwrite prose or an existing video block.
            if (isset($live['depths'][$level]) && is_array($live['depths'][$level])) {
                $live['depths'][$level]['audio'] = $audio;
            }
        }
    }
    return $live;
}

/**
 * Canonical encoding. Both phases must agree byte-for-byte for the hash gate
 * to mean anything, so the flags are fixed here and nowhere else.
 *
 * @param array $doc Merged document.
 * @return string JSON.
 */
function nwp_dcrestore_encode(array $doc): string {
    return json_encode($doc, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
}

/**
 * Read and decode the payload, failing loudly on anything unusable.
 *
 * @param string $path Payload file path.
 * @return array {_meta, content}
 */
function nwp_dcrestore_load_payload(string $path): array {
    $raw = @file_get_contents($path);
    if ($raw === false) { fwrite(STDERR, "cannot read payload $path\n"); exit(2); }
    $p = json_decode($raw, true);
    if (!is_array($p) || !isset($p['content']) || !is_array($p['content'])) {
        fwrite(STDERR, "payload $path is not {_meta, content}\n"); exit(2);
    }
    return $p;
}

/**
 * Pull a named --opt=value out of argv.
 *
 * @param array  $argv Argument vector.
 * @param string $name Option name without leading dashes.
 * @return string|null Value, or null when absent.
 */
function nwp_dcrestore_opt(array $argv, string $name): ?string {
    foreach ($argv as $a) {
        if (preg_match('/^--' . preg_quote($name, '/') . '=(.*)$/s', $a, $m)) { return $m[1]; }
    }
    return null;
}

// ---------------------------------------------------------------------------
// Standalone mode (no Moodle): phase 2. MUST run before the config.php
// bootstrap — the wrapper runs this on the workstation, not on the box.
// ---------------------------------------------------------------------------
$argv = $argv ?? [];
$mergelocal = nwp_dcrestore_opt($argv, 'merge-local');
if ($mergelocal !== null) {
    $payloadpath = nwp_dcrestore_opt($argv, 'payload');
    $outdir      = nwp_dcrestore_opt($argv, 'out-dir');
    $manifest    = nwp_dcrestore_opt($argv, 'manifest');
    if ($payloadpath === null || $outdir === null || $manifest === null) {
        fwrite(STDERR, "--merge-local needs --payload= --out-dir= --manifest=\n"); exit(2);
    }
    $payload = nwp_dcrestore_load_payload($payloadpath);
    $rawdump = @file_get_contents($mergelocal);
    if ($rawdump === false) { fwrite(STDERR, "cannot read dump $mergelocal\n"); exit(2); }
    $dump = json_decode($rawdump, true);
    if (!is_array($dump)) { fwrite(STDERR, "dump $mergelocal is not JSON\n"); exit(2); }
    if (!is_dir($outdir) && !mkdir($outdir, 0700, true)) {
        fwrite(STDERR, "cannot create $outdir\n"); exit(2);
    }

    $rows = [];
    $changed = 0; $unchanged = 0; $nopayload = 0;
    foreach ($dump as $row) {
        $lpid = $row['lpid'] ?? null;
        if ($lpid === null || !isset($payload['content'][$lpid])) { $nopayload++; continue; }
        $live = json_decode((string) $row['content_json'], true);
        if (!is_array($live)) {
            fwrite(STDERR, "row {$row['id']} ({$lpid}): live content_json does not decode — skipped\n");
            continue;
        }
        $merged = nwp_dcrestore_merge($live, $payload['content'][$lpid]);
        $json   = nwp_dcrestore_encode($merged);
        if ($json === (string) $row['content_json']) { $unchanged++; continue; }
        $changed++;
        // One file per row for the wrapper to hand to the seeder's validator.
        file_put_contents($outdir . '/row-' . (int) $row['id'] . '.json', $json);
        $rows[] = [
            'id'    => (int) $row['id'],
            'lpid'  => $lpid,
            'sha256' => hash('sha256', $json),
            'quiz_items' => count($merged['quiz_items'] ?? []),
        ];
    }
    file_put_contents($manifest, json_encode([
        '_meta' => [
            'payload_meta' => $payload['_meta'] ?? null,
            'changed'      => $changed,
            'unchanged'    => $unchanged,
            'no_payload'   => $nopayload,
        ],
        'rows' => $rows,
    ], JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES));
    echo "MERGE-LOCAL changed=$changed already-current=$unchanged no-payload-entry=$nopayload\n";
    exit(0);
}

// Payload is spliced in by the wrapper for the on-box phases (see the .sh).
// Absent it, the on-box phases cannot run — fail closed rather than write.
$PAYLOAD_INLINE = null;
// __NWP_PAYLOAD_HEREDOC__
$MANIFEST_INLINE = null;
// __NWP_MANIFEST_HEREDOC__

// ---------------------------------------------------------------------------
// Moodle bootstrap (phases 1 and 3).
// ---------------------------------------------------------------------------
$root = null;
foreach ([getcwd(), __DIR__] as $c) {
    if (is_file("$c/config.php") && is_dir("$c/lib")) { $root = $c; break; }
}
if ($root === null) { fwrite(STDERR, "Cannot find Moodle root\n"); exit(2); }
require("$root/config.php");
require_once($CFG->libdir . '/clilib.php');
global $DB;

// ---------------------------------------------------------------------------
// Phase 1: --dump. READ-ONLY. Emits the rows a merge could apply to.
// ---------------------------------------------------------------------------
if (in_array('--dump', $argv, true)) {
    $rs = $DB->get_records('depthcontent', null, 'id ASC', 'id,course,name,content_json');
    $out = [];
    foreach ($rs as $r) {
        $j = json_decode((string) $r->content_json, true);
        $out[] = [
            'id'   => (int) $r->id,
            'lpid' => is_array($j) ? ($j['id'] ?? null) : null,
            'content_json' => (string) $r->content_json,
        ];
    }
    // Sentinel-delimited so the wrapper can lift it out of ssh chatter.
    echo "NWPDUMP-BEGIN\n" . json_encode($out, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES) . "\nNWPDUMP-END\n";
    exit(0);
}

// ---------------------------------------------------------------------------
// Phase 3: --apply / --check. Re-derives each merge and gates on the hash the
// validated phase-2 run recorded.
// ---------------------------------------------------------------------------
$checkonly = in_array('--check', $argv, true);

if ($PAYLOAD_INLINE === null || $MANIFEST_INLINE === null) {
    cli_error('REFUSED: no payload/manifest spliced in — run via scripts/demo/ssd-restore-catalogue-content.sh');
}
$payload = json_decode($PAYLOAD_INLINE, true);
$manifest = json_decode($MANIFEST_INLINE, true);
if (!is_array($payload) || !is_array($manifest) || !isset($manifest['rows'])) {
    cli_error('REFUSED: spliced payload/manifest did not decode');
}

$expected = [];
foreach ($manifest['rows'] as $r) { $expected[(int) $r['id']] = $r; }

$written = 0; $current = 0; $mismatch = 0; $missing = 0; $quizrows = 0; $quizitems = 0;
foreach ($expected as $rowid => $exp) {
    $row = $DB->get_record('depthcontent', ['id' => $rowid], 'id,course,name,content_json');
    if (!$row) { $missing++; cli_writeln("MISSING row $rowid ({$exp['lpid']})"); continue; }
    $live = json_decode((string) $row->content_json, true);
    if (!is_array($live)) { $mismatch++; cli_writeln("UNPARSEABLE row $rowid ({$exp['lpid']})"); continue; }

    $entry = $payload['content'][$exp['lpid']] ?? null;
    if ($entry === null) { $missing++; cli_writeln("NO-PAYLOAD row $rowid ({$exp['lpid']})"); continue; }

    $json = nwp_dcrestore_encode(nwp_dcrestore_merge($live, $entry));
    if ($json === (string) $row->content_json) { $current++; continue; }

    $got = hash('sha256', $json);
    if (!hash_equals((string) $exp['sha256'], $got)) {
        // The live row is not what phase 2 validated against. Writing here would
        // put unvalidated bytes in the database, so refuse this row.
        $mismatch++;
        cli_writeln("HASH-MISMATCH row $rowid ({$exp['lpid']}) — live content changed since the validated plan; skipped");
        continue;
    }
    if ($checkonly) { $written++; $quizrows += $exp['quiz_items'] > 0 ? 1 : 0; $quizitems += (int) $exp['quiz_items']; continue; }
    $DB->set_field('depthcontent', 'content_json', $json, ['id' => $rowid]);
    $written++;
    if ((int) $exp['quiz_items'] > 0) { $quizrows++; $quizitems += (int) $exp['quiz_items']; }
}

if (!$checkonly && $written > 0) {
    rebuild_course_cache(0, true);
}

cli_writeln(($checkonly ? 'RESTORE-WOULD ' : 'RESTORE-OK ')
    . "$written  already-current=$current  hash-mismatch=$mismatch  missing=$missing"
    . "  (quiz rows=$quizrows, quiz items=$quizitems)");
exit($mismatch > 0 ? 1 : 0);
