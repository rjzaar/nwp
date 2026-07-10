<?php
// local_nwp_avatars — NWP patron-saint avatar system for Moodle (ss).
// Counterpart to the Drupal nwp_avatars / mayo_avatars module. Stores a
// non-PII (saint, colour) choice in two locked custom profile fields, serves
// the matching inline SVG locally, and receives the choice from nwc over WS.
//
// FIRST CUT — untested on a live Moodle instance. See README-nwp-avatars.md.
defined('MOODLE_INTERNAL') || die();

$plugin->component = 'local_nwp_avatars';
$plugin->version   = 2026071100;          // YYYYMMDDXX
$plugin->release   = '0.1.0';
$plugin->requires  = 2024042200;          // Moodle 4.4 (ss is 4.4.12+, branch 404).
$plugin->maturity  = MATURITY_ALPHA;
