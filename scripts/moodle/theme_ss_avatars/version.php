<?php
// theme_ss_avatars — child theme whose only job is to route every user
// picture through the NWP avatar (local_nwp_avatars). It overrides
// core_renderer::render_user_picture() so forums, participant lists, profiles,
// course pages, etc. all show the chosen patron-saint SVG instead of a photo.
//
// FIRST CUT — untested on a live Moodle instance. See README-nwp-avatars.md.
defined('MOODLE_INTERNAL') || die();

$plugin->component = 'theme_ss_avatars';
$plugin->version   = 2026071100;          // YYYYMMDDXX
$plugin->release   = '0.1.0';
$plugin->requires  = 2024042200;          // Moodle 4.4.
$plugin->maturity  = MATURITY_ALPHA;
$plugin->dependencies = [
    'local_nwp_avatars' => ANY_VERSION,
];
