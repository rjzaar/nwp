<?php
// Creates the two locked, admin-managed custom profile fields that hold each
// user's avatar choice:
//     profile_field_avatar_saint   (text)
//     profile_field_avatar_colour  (text)
//
// These are the WS sync target (nwc → Moodle) and what the theme's
// render_user_picture() override reads. They are created:
//   - locked        (users cannot edit — the choice comes from nwc over WS)
//   - not visible on the public profile (visible = admin-only)
//   - not required   (users without a choice fall back to the default avatar)
//
// Idempotent: skips creation if a field of the same shortname already exists
// (e.g. if a prior nwc sync or a re-install already made it).
//
// TODO(build-host): confirm the shortnames used by the *existing* nwc sync so
// this does not clash. The design doc (§3) names them avatar_saint /
// avatar_colour; verify against the live user_info_field table on ss.

defined('MOODLE_INTERNAL') || die();

/**
 * Plugin install hook.
 */
function xmldb_local_nwp_avatars_install() {
    global $DB;

    // Ensure a category to hang the fields under. Reuse "NWP" if present.
    $categoryname = 'NWP';
    $categoryid = $DB->get_field('user_info_category', 'id', ['name' => $categoryname]);
    if (!$categoryid) {
        $cat = (object) [
            'name'      => $categoryname,
            'sortorder' => ($DB->get_field_sql('SELECT MAX(sortorder) FROM {user_info_category}') ?: 0) + 1,
        ];
        $categoryid = $DB->insert_record('user_info_category', $cat);
    }

    $fields = [
        'avatar_saint'  => 'Avatar saint',
        'avatar_colour' => 'Avatar colour',
    ];

    $sortorder = ($DB->get_field_sql(
        'SELECT MAX(sortorder) FROM {user_info_field} WHERE categoryid = ?',
        [$categoryid]
    ) ?: 0);

    foreach ($fields as $shortname => $name) {
        if ($DB->record_exists('user_info_field', ['shortname' => $shortname])) {
            // Already present (perhaps created by the nwc sync). Leave as-is.
            continue;
        }
        $sortorder++;
        $field = (object) [
            'shortname'    => $shortname,
            'name'         => $name,
            'datatype'     => 'text',
            'description'  => 'Set by nwc over web services; not user-editable.',
            'descriptionformat' => FORMAT_HTML,
            'categoryid'   => $categoryid,
            'sortorder'    => $sortorder,
            'required'     => 0,
            'locked'       => 1,   // Users cannot change it.
            'visible'      => 0,   // Admin-only (PROFILE_VISIBLE_NONE).
            'forceunique'  => 0,
            'signup'       => 0,
            'defaultdata'  => '',
            'defaultdataformat' => FORMAT_HTML,
            'param1'       => 64,  // Display size.
            'param2'       => 64,  // Max length.
        ];
        $DB->insert_record('user_info_field', $field);
    }
}
