<?php
defined('MOODLE_INTERNAL') || die();

if ($hassiteconfig) {
    $settings = new admin_settingpage(
        'local_nwc_erase',
        new lang_string('pluginname', 'local_nwc_erase')
    );

    $ADMIN->add('localplugins', $settings);

    // Fail-closed kill switch: erasure is OFF until an admin explicitly enables.
    $settings->add(new admin_setting_configcheckbox(
        'local_nwc_erase/enabled',
        new lang_string('setting_enabled', 'local_nwc_erase'),
        new lang_string('setting_enabled_desc', 'local_nwc_erase'),
        0
    ));

    $settings->add(new admin_setting_configpasswordunmask(
        'local_nwc_erase/admin_token',
        new lang_string('setting_admin_token', 'local_nwc_erase'),
        new lang_string('setting_admin_token_desc', 'local_nwc_erase'),
        ''
    ));

    // Optional: restrict to the NWC server's IP.
    $settings->add(new admin_setting_configtext(
        'local_nwc_erase/allowed_ips',
        new lang_string('setting_allowed_ips', 'local_nwc_erase'),
        new lang_string('setting_allowed_ips_desc', 'local_nwc_erase'),
        '',
        PARAM_RAW
    ));

    // Optional: bind accepted commands to a single nwc issuer identity.
    $settings->add(new admin_setting_configtext(
        'local_nwc_erase/allowed_issuer',
        new lang_string('setting_allowed_issuer', 'local_nwc_erase'),
        new lang_string('setting_allowed_issuer_desc', 'local_nwc_erase'),
        '',
        PARAM_RAW
    ));
}
