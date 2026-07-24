<?php
/**
 * Admin settings for local_browse.
 *
 * @package    local_browse
 * @copyright  2026 Saint School
 * @license    https://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
 */

defined('MOODLE_INTERNAL') || die();

if ($hassiteconfig) {
    $settings = new admin_settingpage('local_browse', get_string('pluginname', 'local_browse'));
    $ADMIN->add('localplugins', $settings);

    // Default landing tab.
    $settings->add(new admin_setting_configselect(
        'local_browse/default_view',
        get_string('setting_default_view', 'local_browse'),
        get_string('setting_default_view_desc', 'local_browse'),
        'curated',
        [
            'curated' => get_string('tab_curated', 'local_browse'),
            'ascent'  => get_string('tab_ascent', 'local_browse'),
            'browse'  => get_string('tab_browse', 'local_browse'),
        ]
    ));

    // Intent-tile data contract (JSON). Empty = use the shipped seed.
    $settings->add(new admin_setting_configtextarea(
        'local_browse/intent_tiles_json',
        get_string('setting_intent_tiles_json', 'local_browse'),
        get_string('setting_intent_tiles_json_desc', 'local_browse'),
        '',
        PARAM_RAW
    ));

    // Base URL of the frozen v1 archive (ss2) for the Browse tab's v1 toggle.
    $settings->add(new admin_setting_configtext(
        'local_browse/v1_base_url',
        get_string('setting_v1_base_url', 'local_browse'),
        get_string('setting_v1_base_url_desc', 'local_browse'),
        '',
        PARAM_URL
    ));

    // Operator note: how to make this page the guest-viewable site home.
    $settings->add(new admin_setting_heading(
        'local_browse/homenote',
        get_string('setting_home_heading', 'local_browse'),
        get_string('setting_home_desc', 'local_browse')
    ));
}
