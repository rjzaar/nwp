<?php
// Saint School local_browse — "all courses" browse page that lists every
// visible course grouped by Paradigm-rail category, with summaries + cards.
// Replaces Moodle's default /course/index.php which only shows category
// names (Moodle has no built-in "show every course in one place" view).
defined('MOODLE_INTERNAL') || die();

$plugin->component = 'local_browse';
$plugin->version   = 2026051700;
$plugin->release   = '0.1.0';
$plugin->requires  = 2024042200;   // Moodle 4.4
$plugin->maturity  = MATURITY_STABLE;
