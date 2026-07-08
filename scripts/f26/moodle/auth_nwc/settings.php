<?php
// auth_nwc settings — F26 nwc<->ss OIDC client.
// GNU GPL v3 or later. Copyright 2026 Narrow Way Project.

defined('MOODLE_INTERNAL') || die();

if ($ADMIN->fulltree) {

    $settings->add(new admin_setting_configtext(
        'auth_nwc/nwc_url',
        get_string('nwc_url', 'auth_nwc'),
        get_string('nwc_url_desc', 'auth_nwc'),
        'https://nwc-dev.ddev.site', PARAM_URL));

    $settings->add(new admin_setting_configtext(
        'auth_nwc/issuerid',
        get_string('issuerid', 'auth_nwc'),
        get_string('issuerid_desc', 'auth_nwc'),
        '', PARAM_INT));

    $settings->add(new admin_setting_configcheckbox(
        'auth_nwc/autoredirect',
        get_string('autoredirect', 'auth_nwc'),
        get_string('autoredirect_desc', 'auth_nwc'), 0));

    // Migration window only. When on, a first OIDC login whose *verified* email
    // matches an existing pre-OIDC Moodle account binds that account to the nwc
    // uid ONCE (sets idnumber). After that, matching is always by idnumber.
    // Leave OFF outside a migration window (F26 § 2, § 3.2).
    $settings->add(new admin_setting_configcheckbox(
        'auth_nwc/link_legacy_by_email',
        get_string('link_legacy_by_email', 'auth_nwc'),
        get_string('link_legacy_by_email_desc', 'auth_nwc'), 0));

    $settings->add(new admin_setting_configcheckbox(
        'auth_nwc/enable_logging',
        get_string('enable_logging', 'auth_nwc'),
        get_string('enable_logging_desc', 'auth_nwc'), 0));
}
