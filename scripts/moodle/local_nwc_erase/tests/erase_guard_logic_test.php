<?php
// Standalone unit test for local_nwc_erase\erase_guard — runs with plain `php`,
// no Moodle needed (mirrors scripts/f26/moodle/auth_nwc/tests/uid_lock_logic_test.php).
//
//   php scripts/moodle/local_nwc_erase/tests/erase_guard_logic_test.php
//
// Covers the LOAD-BEARING, destructive-path guard logic of the ops#81 receiver:
//   - the fail-closed Bearer / IP / issuer guards
//   - the CLOSED erasure-command validation (additionalProperties:false, enum,
//     non-empty sub/request_id/issuer, integer timestamp) — NEVER by email
//   - the idempotency / missing-user decision (both no-ops, both HTTP 200)
//
// erase_guard has NO Moodle dependency, so we define the guard so the file
// parses standalone, then require the class.

if (!defined('MOODLE_INTERNAL')) {
    define('MOODLE_INTERNAL', true);
}
require __DIR__ . '/../classes/erase_guard.php';

use local_nwc_erase\erase_guard;

$pass = 0; $fail = 0;
function check($name, $got, $want) {
    global $pass, $fail;
    $g = var_export($got, true); $w = var_export($want, true);
    if ($got === $want) { echo "  ok   $name\n"; $pass++; }
    else { echo "  FAIL $name (got $g, want $w)\n"; $fail++; }
}

// A canonical valid command (sub = a UUID; NEVER an email).
$uuid = '8f14e45f-ceea-467a-9e2b-2c3b0a1d4e5f';
$rid  = 'b1946ac9-2e1a-4c0e-9b2f-0d3e4f5a6b7c';
$valid = ['sub' => $uuid, 'request_id' => $rid, 'action' => 'delete',
          'issuer' => 'https://nwc.example/', 'timestamp' => 1752000000];

// ── Bearer guard (fail-closed) ───────────────────────────────────────────────
check('bearer: correct token', erase_guard::bearer_ok('s3cret', 'Bearer s3cret'), true);
check('bearer: wrong token', erase_guard::bearer_ok('s3cret', 'Bearer nope'), false);
check('bearer: empty expected -> deny', erase_guard::bearer_ok('', 'Bearer s3cret'), false);
check('bearer: missing prefix -> deny', erase_guard::bearer_ok('s3cret', 's3cret'), false);
check('bearer: empty header -> deny', erase_guard::bearer_ok('s3cret', ''), false);

// ── IP allowlist ─────────────────────────────────────────────────────────────
check('ip: empty allowlist -> allow', erase_guard::ip_allowed('10.0.0.9', ''), true);
check('ip: listed -> allow', erase_guard::ip_allowed('10.0.0.9', '10.0.0.9, 10.0.0.1'), true);
check('ip: not listed -> deny', erase_guard::ip_allowed('10.0.0.8', '10.0.0.9, 10.0.0.1'), false);

// ── Issuer binding ───────────────────────────────────────────────────────────
check('issuer: empty config -> allow', erase_guard::issuer_ok('', 'https://x/'), true);
check('issuer: match -> allow', erase_guard::issuer_ok('https://nwc.example/', 'https://nwc.example/'), true);
check('issuer: mismatch -> deny', erase_guard::issuer_ok('https://nwc.example/', 'https://evil/'), false);

// ── Command validation (CLOSED shape, fail-closed) ───────────────────────────
$r = erase_guard::validate_command($valid);
check('cmd: valid accepted', $r['ok'], true);
check('cmd: normalised timestamp is int', $r['command']['timestamp'] === 1752000000, true);

check('cmd: non-array rejected', erase_guard::validate_command('nope')['ok'], false);
check('cmd: missing sub rejected',
    erase_guard::validate_command(array_diff_key($valid, ['sub' => 1]))['ok'], false);
check('cmd: empty sub rejected',
    erase_guard::validate_command(['sub' => '', 'request_id' => $rid, 'action' => 'delete',
        'issuer' => 'i', 'timestamp' => 1])['ok'], false);
check('cmd: whitespace sub rejected',
    erase_guard::validate_command(['sub' => '   ', 'request_id' => $rid, 'action' => 'delete',
        'issuer' => 'i', 'timestamp' => 1])['ok'], false);
check('cmd: bad action enum rejected',
    erase_guard::validate_command(['sub' => $uuid, 'request_id' => $rid, 'action' => 'purge',
        'issuer' => 'i', 'timestamp' => 1])['ok'], false);
check('cmd: anonymise accepted',
    erase_guard::validate_command(['sub' => $uuid, 'request_id' => $rid, 'action' => 'anonymise',
        'issuer' => 'i', 'timestamp' => 1])['ok'], true);
check('cmd: extra property rejected (additionalProperties:false)',
    erase_guard::validate_command($valid + ['email' => 'a@b.test'])['ok'], false);
check('cmd: non-int timestamp rejected',
    erase_guard::validate_command(['sub' => $uuid, 'request_id' => $rid, 'action' => 'delete',
        'issuer' => 'i', 'timestamp' => 'now'])['ok'], false);
check('cmd: bool timestamp rejected',
    erase_guard::validate_command(['sub' => $uuid, 'request_id' => $rid, 'action' => 'delete',
        'issuer' => 'i', 'timestamp' => true])['ok'], false);

// ── Idempotency / missing-user decision (both -> 200 no-op) ──────────────────
check('decide: fresh + user found -> proceed',
    erase_guard::decide(false, true), erase_guard::ACTION_PROCEED);
check('decide: replayed -> noop_replayed',
    erase_guard::decide(true, true), erase_guard::ACTION_NOOP_REPLAYED);
check('decide: missing user -> noop_missing',
    erase_guard::decide(false, false), erase_guard::ACTION_NOOP_MISSING);
check('decide: replayed beats missing (order)',
    erase_guard::decide(true, false), erase_guard::ACTION_NOOP_REPLAYED);

echo "\n$pass passed, $fail failed\n";
exit($fail === 0 ? 0 : 1);
