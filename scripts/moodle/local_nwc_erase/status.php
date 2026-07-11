<?php
/**
 * Smoke endpoint for the ops#81 erasure channel — pair_guard / pair-smoke hits
 * GET /local/nwc_erase/status.php and expects 200. It NEVER exercises a real
 * erase (see pairs/ssc.pair-contract.yml: "never exercise a real delete in
 * smoke"). It reports only whether the plugin is installed + whether the kill
 * switch is on — no user data, no token, no PII.
 */

define('AJAX_SCRIPT', true);
define('NO_MOODLE_COOKIES', true);

require_once(__DIR__ . '/../../config.php');

header('Content-Type: application/json; charset=utf-8');
http_response_code(200);
echo json_encode([
    'ok'        => true,
    'plugin'    => 'local_nwc_erase',
    'enabled'   => (bool) get_config('local_nwc_erase', 'enabled'),
    'has_token' => ((string) get_config('local_nwc_erase', 'admin_token')) !== '',
]);
