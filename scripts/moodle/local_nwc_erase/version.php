<?php
// local_nwc_erase — receives a signed right-to-be-forgotten erase command from
// NWC's nwc_moodle_erase module and performs a Privacy-API erasure (NOT a soft
// delete_user()) of the matching user, resolved by idnumber == sub (the F26
// UID-lock; ops#83 sub == Drupal account UUID). ops#81, DESTRUCTIVE, phased.
defined('MOODLE_INTERNAL') || die();

$plugin->component = 'local_nwc_erase';
$plugin->version   = 2026071100;
$plugin->release   = '1.0.0';
$plugin->requires  = 2024042200;        // Moodle 4.4
$plugin->maturity  = MATURITY_ALPHA;    // ops#81 P1 — not yet prod-gated
$plugin->dependencies = [
    'tool_dataprivacy' => ANY_VERSION,  // the Privacy-API erasure engine
];
