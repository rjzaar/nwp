<?php
// Capabilities for local_nwp_avatars.
//
// local/nwp_avatars:sync gates the set_avatar web-service write. It is granted
// to no archetype by default: the operator binds it to the dedicated nwc WS
// service user only (see db/services.php).

defined('MOODLE_INTERNAL') || die();

$capabilities = [
    // Permission to push avatar choices in over web services (nwc only).
    'local/nwp_avatars:sync' => [
        'riskbitmask'  => RISK_PERSONAL,
        'captype'      => 'write',
        'contextlevel' => CONTEXT_SYSTEM,
        'archetypes'   => [],
    ],
];
