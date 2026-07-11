<?php
/**
 * local_nwc_erase — external services declaration.
 *
 * INTENTIONALLY EMPTY. Like local_nwc_copyright_sync, this plugin does NOT
 * expose a Moodle web service. The erasure command arrives at the plain
 * Bearer-guarded endpoint erase.php (NOT /webservice/rest/server.php), so no
 * external function is registered here. This file exists so the plugin's
 * service surface is explicit + auditable: there is deliberately no WS attack
 * surface — the only ingress is the fail-closed erase.php guard rail.
 */
defined('MOODLE_INTERNAL') || die();

$functions = [];
$services  = [];
