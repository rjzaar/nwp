<?php
// Web-service external function: local_nwp_avatars_set_avatar.
//
// This is the nwc → Moodle sync target. nwc (the Drupal provider, source of
// truth for the avatar choice) calls this over Moodle web services to push a
// member's (saint, colour) into the two locked custom profile fields. Mirrors
// how local_nwc_copyright_sync receives cross-site writes from nwc — except
// that plugin uses a bearer-token PHP endpoint, whereas the ops#86 design (§3)
// asks for a proper Moodle external function here.
//
// TODO(build-host): confirm transport with the operator — a Moodle external
// function (this file, token+capability gated) OR a bearer-token plain PHP
// endpoint like nwc_copyright_sync/policy_set.php. Both are viable; this cut
// ships the external-function form because it reuses Moodle's own token/role
// machinery. If the bearer-endpoint form is preferred for consistency with
// the sibling plugin, port this logic into a set_avatar.php endpoint.

namespace local_nwp_avatars\external;

defined('MOODLE_INTERNAL') || die();

use core_external\external_api;
use core_external\external_function_parameters;
use core_external\external_single_structure;
use core_external\external_value;

/**
 * Set (or clear) a user's avatar choice from nwc.
 */
class set_avatar extends external_api {

    /**
     * Parameters.
     */
    public static function execute_parameters(): external_function_parameters {
        return new external_function_parameters([
            'usermatch'  => new external_value(
                PARAM_ALPHANUMEXT,
                "How to identify the target user: 'username' or 'idnumber'.",
                VALUE_DEFAULT,
                'username'
            ),
            'useridvalue' => new external_value(
                PARAM_RAW_TRIMMED,
                'The value (username or idnumber) identifying the user. Typically the OIDC sub.'
            ),
            'saint'  => new external_value(
                PARAM_ALPHANUMEXT,
                "Avatar (saint) id, e.g. 'francis'. Empty string clears the choice.",
                VALUE_DEFAULT,
                ''
            ),
            'colour' => new external_value(
                PARAM_ALPHANUMEXT,
                "Colour id, e.g. 'royal-blue'. Empty string uses the default colour.",
                VALUE_DEFAULT,
                ''
            ),
        ]);
    }

    /**
     * Write the avatar choice into the two custom profile fields.
     *
     * @return array{ok:bool, userid:int, saint:string, colour:string}
     */
    public static function execute(string $usermatch, string $useridvalue, string $saint, string $colour): array {
        global $DB, $CFG;
        require_once($CFG->dirroot . '/user/profile/lib.php');

        $params = self::validate_parameters(self::execute_parameters(), [
            'usermatch'   => $usermatch,
            'useridvalue' => $useridvalue,
            'saint'       => $saint,
            'colour'      => $colour,
        ]);

        $context = \context_system::instance();
        self::validate_context($context);
        require_capability('local/nwp_avatars:sync', $context);

        // Resolve the target user by the agreed linkage (design §3/§ item 5:
        // confirm the sub ↔ Moodle user match on the build host).
        $matchfield = ($params['usermatch'] === 'idnumber') ? 'idnumber' : 'username';
        $user = $DB->get_record('user', [
            $matchfield => $params['useridvalue'],
            'deleted'   => 0,
        ], '*', IGNORE_MULTIPLE);
        if (!$user) {
            throw new \invalid_parameter_exception(
                "no user with $matchfield = " . s($params['useridvalue'])
            );
        }

        // Validate the ids against the shared avatar library. Unknown ids are
        // normalised (unknown saint => stored empty => falls back to default).
        $mgr = new \local_nwp_avatars\avatar_manager();
        $avatars = $mgr->get_avatars();
        $colours = $mgr->get_colours();

        $storesaint = ($params['saint'] !== '' && isset($avatars[$params['saint']]))
            ? $params['saint'] : '';
        $storecolour = ($params['colour'] !== '' && isset($colours[$params['colour']]))
            ? $params['colour'] : '';

        // Persist to the custom profile fields. profile_save_data writes the
        // profile_field_* values that render_user_picture() / the helper API
        // read back.
        $data = (object) [
            'id' => $user->id,
            'profile_field_avatar_saint'  => $storesaint,
            'profile_field_avatar_colour' => $storecolour,
        ];
        profile_save_data($data);

        return [
            'ok'     => true,
            'userid' => (int) $user->id,
            'saint'  => $storesaint,
            'colour' => $storecolour,
        ];
    }

    /**
     * Return structure.
     */
    public static function execute_returns(): external_single_structure {
        return new external_single_structure([
            'ok'     => new external_value(PARAM_BOOL, 'Whether the write succeeded.'),
            'userid' => new external_value(PARAM_INT, 'The Moodle user id written to.'),
            'saint'  => new external_value(PARAM_ALPHANUMEXT, 'The stored saint id (empty if cleared/unknown).'),
            'colour' => new external_value(PARAM_ALPHANUMEXT, 'The stored colour id (empty = default).'),
        ]);
    }
}
