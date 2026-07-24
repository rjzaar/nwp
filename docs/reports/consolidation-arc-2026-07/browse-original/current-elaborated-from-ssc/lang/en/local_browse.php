<?php
defined('MOODLE_INTERNAL') || die();

$string['pluginname'] = 'Course front-door (tabbed browse)';
$string['title']      = 'Saint School';
$string['tagline']    = 'Find your way into the spiritual life — by intent, by ascent, or browse everything.';
$string['empty']      = 'No courses available yet.';

// Tabs.
$string['tab_curated'] = 'Where to begin';
$string['tab_ascent']  = 'The journey';
$string['tab_browse']  = 'Browse everything';

// Curated (Tab 1).
$string['curated_intro']      = 'Where would you like to begin? Pick the path that fits you now.';
$string['tile_default_action'] = 'Begin';

// Ascent (Tab 2).
$string['ascent_intro']  = 'The catalog by Paradigm rail — take the journey of ascent.';
$string['rail_unknown']  = 'Other';
$string['count_courses_in_rail'] = '{$a} courses';
$string['count_course_in_rail']  = '{$a} course';

// Browse (Tab 3).
$string['browse_intro']       = 'Every course in one place. Filter as you type.';
$string['filter_placeholder'] = 'Filter courses…';
$string['toggle_catalog']     = 'Catalog version';
$string['toggle_content']     = 'Show';
$string['toggle_v3']          = 'v3 (current)';
$string['toggle_v1']          = 'v1 archive';
$string['toggle_courses']     = 'Courses';
$string['toggle_books']       = 'Courses + book studies';
$string['books_heading']      = 'Book studies';
$string['books_none_cleared'] = 'No book studies are available yet — each is copyright-gated and appears once its work has been cleared.';
$string['v1_notice']          = 'The v1 archive is frozen and read-only. Links open the original archive site in a new tab.';
$string['v1_base_unset']      = 'The v1 archive site URL is not configured, so links are disabled. An administrator can set it in the plugin settings (local_browse | v1_base_url).';
$string['v1_open_archive']    = 'Open in v1 archive →';

// Settings.
$string['setting_default_view']        = 'Default tab';
$string['setting_default_view_desc']   = 'Which tab a new visitor sees first. The locked recommendation is "Where to begin" (Curated).';
$string['setting_intent_tiles_json']   = 'Intent-tile data (JSON)';
$string['setting_intent_tiles_json_desc'] = 'The Curated tab\'s intent tiles as JSON (data-contract version 1: {"version":1,"tiles":[{"id","heading","blurb","action_label","order","courses":[shortcode,...]}]}). Leave empty to use the shipped seed. The Theology-Editor authoring / def-sync path overwrites this without a code change.';
$string['setting_v1_base_url']         = 'v1 archive base URL';
$string['setting_v1_base_url_desc']    = 'Base URL of the frozen v1 archive site (ss2), e.g. https://ss2.example.org. Used to build read-only deep-links on the Browse tab\'s v1 toggle. Leave empty to disable the links.';
$string['setting_home_heading']        = 'Making this the site home';
$string['setting_home_desc']           = 'To make this guest-viewable front-door the site home, point the front page at /local/browse/ (e.g. an admin redirect, or set it as the front-page target) and ensure guest access is enabled. Do not change live configuration from this page — see the plugin README.';
