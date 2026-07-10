<?php
// local_nwp_avatars — library / helper API.
//
// Public helpers used by the theme override (theme_ss_avatars) and any other
// code that needs a user's avatar. Kept as plain functions so themes and core
// callers can use them without instantiating the class directly.

defined('MOODLE_INTERNAL') || die();

/**
 * Return the (saint, colour) choice for a user, falling back to the default
 * avatar when the profile fields are empty/unknown.
 *
 * Reads the two custom profile fields populated by the WS sync
 * (profile_field_avatar_saint / _colour).
 *
 * @param int|\stdClass $userorid A user id or a user record.
 * @return array{saint:string, colour:string}
 */
function local_nwp_avatars_get_user_choice($userorid): array {
    global $CFG;
    require_once($CFG->dirroot . '/user/profile/lib.php');

    if (is_object($userorid)) {
        $user = $userorid;
    } else {
        $user = \core_user::get_user((int) $userorid);
    }

    $saint = '';
    $colour = '';
    if ($user) {
        // profile_load_data() populates $user->profile_field_* keys.
        if (!isset($user->profile_field_avatar_saint) || !isset($user->profile_field_avatar_colour)) {
            profile_load_data($user);
        }
        $saint  = (string) ($user->profile_field_avatar_saint ?? '');
        $colour = (string) ($user->profile_field_avatar_colour ?? '');
    }

    $mgr = new \local_nwp_avatars\avatar_manager();
    return $mgr->normalise_selection($saint, $colour);
}

/**
 * Return the URL of a user's avatar SVG (served by avatar.php).
 *
 * @param int|\stdClass $userorid A user id or a user record.
 * @param int $size Pixel size hint.
 * @return \moodle_url
 */
function local_nwp_avatars_url($userorid, int $size = 100): \moodle_url {
    $choice = local_nwp_avatars_get_user_choice($userorid);
    return new \moodle_url('/local/nwp_avatars/avatar.php', [
        'saint'  => $choice['saint'],
        'colour' => $choice['colour'],
        'size'   => $size,
    ]);
}

/**
 * Return a user's avatar as an inline SVG string.
 *
 * Convenience helper named per the ops#86 spec (get_user_avatar_svg). Useful
 * for contexts that want the vector inline rather than an <img src>.
 *
 * @param int|\stdClass $userorid A user id or a user record.
 * @param int $size Pixel size.
 * @return string Inline SVG markup.
 */
function get_user_avatar_svg($userorid, int $size = 100): string {
    $choice = local_nwp_avatars_get_user_choice($userorid);
    $mgr = new \local_nwp_avatars\avatar_manager();
    return $mgr->render($choice['saint'], $choice['colour'], $size);
}
