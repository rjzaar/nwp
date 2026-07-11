<?php
/**
 * POST endpoint for NWC's nwc_moodle_erase module to erase a user on this
 * Moodle when they are deleted on nwc (ops#81 erasure-propagation channel).
 *
 * DESTRUCTIVE + consent-adjacent. Byte-for-byte the same guard rail as
 * local_nwc_copyright_sync/policy_set.php (Bearer + IP allowlist + JSON guard),
 * plus an optional issuer binding and the erasure-command shape check
 * (contracts/erasure.command.schema.json). ALL guards fail-closed: any doubt
 * returns a non-2xx and erases NOTHING.
 *
 * Auth:  Authorization: Bearer <local_nwc_erase/admin_token>
 * Body:  JSON matching contracts/erasure.command.schema.json:
 *   { "sub": "<uuid>", "request_id": "<uuid>", "action": "delete"|"anonymise",
 *     "issuer": "<nwc issuer>", "timestamp": <int> }
 *   `sub` is the DURABLE Drupal account UUID == mdl_user.idnumber (NEVER email).
 *
 * Response:
 *   200 {"ok":true,"action":"deleted"|"noop_missing_user"|"noop_replayed",...}
 *   400 {"ok":false,"error":"bad payload","details":[...]}
 *   401 {"ok":false,"error":"unauthorized"}
 *   403 {"ok":false,"error":"source IP not allowed" | "issuer not allowed"}
 *   405 {"ok":false,"error":"POST required"}
 *   503 {"ok":false,"error":"erasure disabled on this site"}
 *   500 {"ok":false,"error":"server error"}
 *
 * Intentionally NOT a Moodle web service — a plain HTTPS POST with Bearer auth,
 * same family as policy_set.php / CrossSiteFeedbackController.
 *
 * ⚠ PROD BOUNDARY (CLAUDE.md AI-never-prod): on a real prod tier this endpoint's
 * token is a `ver`-held secret and the erase fires only behind the ver desktop
 * Solo-touch gate. dev/stg/live-test tiers are agent-operable (A14). See README.
 */

define('AJAX_SCRIPT', true);
define('NO_MOODLE_COOKIES', true);

require_once(__DIR__ . '/../../config.php');
require_once($CFG->libdir . '/clilib.php');
require_once(__DIR__ . '/classes/erase_guard.php');
require_once(__DIR__ . '/classes/eraser.php');

use local_nwc_erase\erase_guard;
use local_nwc_erase\eraser;

header('Content-Type: application/json; charset=utf-8');

function nwc_erase_respond(int $status, array $payload): void {
    http_response_code($status);
    echo json_encode($payload);
    exit;
}

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    nwc_erase_respond(405, ['ok' => false, 'error' => 'POST required']);
}

// Fail-closed kill switch: erasure is OFF unless explicitly enabled.
if (!get_config('local_nwc_erase', 'enabled')) {
    nwc_erase_respond(503, ['ok' => false, 'error' => 'erasure disabled on this site']);
}

// IP allowlist (optional second factor; empty => not enforced).
$allowed_ips_raw = (string) get_config('local_nwc_erase', 'allowed_ips');
$remote = $_SERVER['REMOTE_ADDR'] ?? '';
if (!erase_guard::ip_allowed($remote, $allowed_ips_raw)) {
    nwc_erase_respond(403, ['ok' => false, 'error' => 'source IP not allowed']);
}

// Bearer auth (constant-time).
$expected = (string) get_config('local_nwc_erase', 'admin_token');
$auth = $_SERVER['HTTP_AUTHORIZATION'] ?? '';
if (!erase_guard::bearer_ok($expected, $auth)) {
    nwc_erase_respond(401, ['ok' => false, 'error' => 'unauthorized']);
}

// Parse + validate the command against the closed erasure schema.
$raw = file_get_contents('php://input');
$body = json_decode($raw, true);
$check = erase_guard::validate_command($body);
if (!$check['ok']) {
    nwc_erase_respond(400, ['ok' => false, 'error' => 'bad payload', 'details' => $check['errors']]);
}
$command = $check['command'];

// Optional issuer binding: if configured, the command issuer must match.
$expected_issuer = (string) get_config('local_nwc_erase', 'allowed_issuer');
if (!erase_guard::issuer_ok($expected_issuer, $command['issuer'])) {
    nwc_erase_respond(403, ['ok' => false, 'error' => 'issuer not allowed']);
}

try {
    $result = eraser::execute($command);
    nwc_erase_respond(200, $result);
}
catch (\Throwable $e) {
    error_log('local_nwc_erase erase.php: ' . $e->getMessage());
    // Fail-closed: on any error, record the failure for audit and return 500.
    try {
        eraser::write_log($command['request_id'], $command['sub'],
            $command['action'], 'error', ['exception' => $e->getMessage()]);
    } catch (\Throwable $ignored) {
        // best-effort audit; never mask the original error
    }
    nwc_erase_respond(500, ['ok' => false, 'error' => 'server error']);
}
