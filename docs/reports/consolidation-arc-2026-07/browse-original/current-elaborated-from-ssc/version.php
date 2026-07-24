<?php
// Saint School local_browse — guest-viewable, tabbed course front-door over the
// single catalog: Curated (intent tiles) → Ascent (rail-grouped) → Browse (flat +
// N8 toggles). Replaces Moodle's default /course/index.php (which only shows
// category names) and the flat FRONTPAGEALLCOURSELIST home.
defined('MOODLE_INTERNAL') || die();

$plugin->component = 'local_browse';
$plugin->version   = 2026072100;
$plugin->release   = '0.2.0';
$plugin->requires  = 2024042200;   // Moodle 4.4
$plugin->maturity  = MATURITY_STABLE;
