<?php
defined('MOODLE_INTERNAL') || die();

$capabilities = [
    // Only admins manage the bearer token / kill switch. The erase itself is
    // driven by the Bearer-guarded endpoint, not a UI capability.
    'local/nwc_erase:manage' => [
        'riskbitmask'  => RISK_CONFIG | RISK_DATALOSS,
        'captype'      => 'write',
        'contextlevel' => CONTEXT_SYSTEM,
        'archetypes'   => [
            'manager' => CAP_ALLOW,
        ],
    ],
];
