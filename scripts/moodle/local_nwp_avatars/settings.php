<?php
// Admin settings for local_nwp_avatars.
//
// Mostly a posture dashboard: it surfaces (and warns about) the two global
// switches this plugin depends on — $CFG->disableuserimages and
// $CFG->enablegravatar — which enforce "ss never has photos". The recommended
// hard enforcement is to pin them in config.php (see README-nwp-avatars.md);
// these read-only notices tell an admin whether the live config matches.

defined('MOODLE_INTERNAL') || die();

if ($hassiteconfig) {
    global $CFG;

    $settings = new admin_settingpage(
        'local_nwp_avatars',
        new lang_string('pluginname', 'local_nwp_avatars')
    );
    $ADMIN->add('localplugins', $settings);

    // Posture: no photo uploads.
    $disableok = !empty($CFG->disableuserimages);
    $settings->add(new admin_setting_description(
        'local_nwp_avatars/posture_disableuserimages',
        new lang_string('posture_disableuserimages', 'local_nwp_avatars'),
        new lang_string(
            $disableok ? 'posture_ok' : 'posture_warn',
            'local_nwp_avatars',
            '$CFG->disableuserimages'
        )
    ));

    // Posture: gravatar off (else external photos re-enter by email hash).
    $gravatarok = empty($CFG->enablegravatar);
    $settings->add(new admin_setting_description(
        'local_nwp_avatars/posture_gravatar',
        new lang_string('posture_gravatar', 'local_nwp_avatars'),
        new lang_string(
            $gravatarok ? 'posture_ok' : 'posture_warn',
            'local_nwp_avatars',
            '$CFG->enablegravatar'
        )
    ));

    // Optional fallback (design path (d)): rasterise the chosen SVG to a PNG
    // user icon on sync, for contexts that bypass the theme renderer
    // (emails / mobile app / some web services). Off by default; requires
    // $CFG->disableuserimages OFF + upload capability blocked instead.
    // TODO(build-host): implement the rasterise-on-sync path once the coverage
    // test on ss shows which surfaces bypass the theme override.
    $settings->add(new admin_setting_configcheckbox(
        'local_nwp_avatars/rasterise_to_icon',
        new lang_string('setting_rasterise', 'local_nwp_avatars'),
        new lang_string('setting_rasterise_desc', 'local_nwp_avatars'),
        0
    ));
}
