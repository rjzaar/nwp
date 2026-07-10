<?php
// Language strings for local_nwp_avatars.

defined('MOODLE_INTERNAL') || die();

$string['pluginname'] = 'NWP Avatars';

// Capability.
$string['nwp_avatars:sync'] = 'Receive avatar-choice pushes from nwc over web services';

// Web service.
$string['ws_set_avatar'] = 'Set a user\'s patron-saint avatar choice';

// Posture notices.
$string['posture_disableuserimages'] = 'No photo uploads';
$string['posture_gravatar'] = 'Gravatar disabled';
$string['posture_ok'] = 'OK: {$a} is set correctly for the no-photo policy.';
$string['posture_warn'] = 'WARNING: {$a} is NOT set for the no-photo policy. Pin it in config.php (see README-nwp-avatars.md).';

// Rasterise fallback.
$string['setting_rasterise'] = 'Rasterise avatar to PNG user icon on sync (fallback)';
$string['setting_rasterise_desc'] = 'Also write a PNG copy of the chosen avatar into the native user icon on each sync, so contexts that bypass the theme renderer (emails, mobile app, some web services) still show it. Requires disableuserimages OFF and uploads blocked by capability instead. Not yet implemented — see README.';

// Privacy.
$string['privacy:metadata:profilefields'] = 'The avatar choice (saint and colour) is stored in the standard Moodle user profile fields avatar_saint and avatar_colour. These are non-personal design tokens, not photographs.';
