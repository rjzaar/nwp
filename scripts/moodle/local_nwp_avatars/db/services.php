<?php
// Web-service definitions for local_nwp_avatars.
//
// local_nwp_avatars_set_avatar is the nwc → Moodle sync receiver. It is
// exposed as an external function and bundled into a named service so nwc can
// be issued a dedicated, minimally-scoped token.
//
// TODO(build-host): create the WS token bound to a service user that holds
// ONLY local/nwp_avatars:sync (see db/access.php), and enable
// 'Web services' + a protocol (REST). Confirm the token/role with the operator
// — mirror whatever the existing nwc → ss sync uses.

defined('MOODLE_INTERNAL') || die();

$functions = [
    'local_nwp_avatars_set_avatar' => [
        'classname'   => 'local_nwp_avatars\\external\\set_avatar',
        'methodname'  => 'execute',
        'description' => 'Set a user\'s patron-saint avatar choice (saint + colour), pushed from nwc.',
        'type'        => 'write',
        'capabilities' => 'local/nwp_avatars:sync',
        'ajax'        => false,
    ],
];

$services = [
    'NWP avatar sync' => [
        'functions'       => ['local_nwp_avatars_set_avatar'],
        'restrictedusers' => 1,
        'enabled'         => 0, // Operator enables + binds the nwc token on the build host.
        'shortname'       => 'local_nwp_avatars_sync',
        'downloadfiles'   => 0,
        'uploadfiles'     => 0,
    ],
];
