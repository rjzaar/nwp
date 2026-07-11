<?php
// auth_nwc observer — wires the F26 UID-lock EXECUTOR into the real post-auth
// path for core-OAuth2 logins (fixes F26 B1: resolve_and_lock() was dead code).
//
//   AUTH SURFACE — REQUIRES HUMAN REVIEW BEFORE MERGE/ENABLE.
//   UNTESTED ON MOODLE — draft for two-person review.
//
// GNU GPL v3 or later. Copyright 2026 Narrow Way Project.
//
// WHY AN EVENT OBSERVER (not user_authenticated_hook):
//   \auth_oauth2\auth::complete_login() calls complete_user_login() DIRECTLY and
//   deliberately bypasses authenticate_user_login() (core comment: "We used to
//   call authenticate_user - but that won't work if the current user has a
//   different default authentication type."). authenticate_user_login() is the
//   ONLY caller of auth_plugin_base::user_authenticated_hook(), so that hook never
//   fires on the OAuth2 path. \core\event\user_loggedin DOES fire (from
//   complete_user_login()) for every successful login regardless of auth path.
//
// LIMITATION (flagged for the 2-person review):
//   This observer runs AFTER core has already created/linked and logged the user
//   in. It enforces the lock as a GUARD + REPAIR (assert idnumber==sub; DENY and
//   kill the session on a broken/empty sub). It does NOT pre-empt core's own
//   email-based linking. The durable happy-path lock remains the REQUIRED issuer
//   field-mapping sub->idnumber (INSTALL.md §2): core writes idnumber at account
//   creation and never rewrites it. Faithfully running the migration LOCK_EXISTING
//   branch (needs mid-flow email_verified + the pre-link row) or the SUSPEND branch
//   (needs a live userinfo probe) requires, respectively, owning the callback and a
//   scheduled reconcile task — see TODO(build-host) markers below.

namespace auth_nwc;

defined('MOODLE_INTERNAL') || die();

class observer {

    /**
     * Runs on every successful login; acts only for logins through OUR nwc issuer.
     *
     * @param \core\event\user_loggedin $event
     */
    public static function user_loggedin(\core\event\user_loggedin $event): void {
        global $DB;

        $config = get_config('auth_nwc');

        // 0. Do nothing unless the plugin is enabled AND pointed at an issuer.
        //    Enabling/disabling auth_nwc is the operator's on/off switch for
        //    lock ENFORCEMENT (core still uses authtype 'oauth2' for the dance).
        if (empty($config->issuerid) || !is_enabled_auth('nwc')) {
            return;
        }

        $userid = (int) ($event->objectid ?? $event->userid);
        if (empty($userid)) {
            return;
        }
        $user = $DB->get_record('user', ['id' => $userid]);
        if (!$user) {
            return;
        }

        // 1. GUARD: only touch logins that actually came through our nwc issuer.
        //    Core stamps auth='oauth2' (not 'nwc') and owns the linked-login row
        //    keyed by issuerid — that row is the reliable "this was our SSO" signal.
        //    TODO(build-host): confirm the linked_login row already exists when
        //    user_loggedin fires (it is created earlier, inside complete_login()).
        $islinked = $DB->record_exists('auth_oauth2_linked_login', [
            'userid'   => $user->id,
            'issuerid' => (int) $config->issuerid,
        ]);
        if (!$islinked) {
            return; // manual / admin / other-issuer login — not ours.
        }

        // 2. Obtain the nwc uid (`sub`). Core wrote it to mdl_user.idnumber via the
        //    REQUIRED issuer field-mapping sub->idnumber at account creation, and
        //    does not rewrite it on later logins — so that mapped value IS the sub.
        //    TODO(build-host): if sub is ALSO mapped to username, corroborate
        //    $user->idnumber against auth_oauth2_linked_login.username here.
        //    TODO(build-host): if idnumber is empty, the mapping is not configured
        //    -> decision is DENY -> ALL logins are rejected. Verify the mapping is
        //    in place BEFORE enabling auth_nwc.
        $claims = [
            'sub'            => (string) $user->idnumber,
            'email'          => $user->email,
            // email_verified is asserted by the issuer MID-FLOW and is not available
            // at this post-login event; we pass false so the observer never performs
            // an email-based re-link. The migration LOCK_EXISTING branch is therefore
            // out of scope for the observer — see LIMITATION above.
            'email_verified' => false,
            'given_name'     => $user->firstname,
            'family_name'    => $user->lastname,
        ];

        // 3. At a successful login the nwc account, by definition, just resolved,
        //    so nwc_active=true here. The SUSPEND-on-nwc-deletion branch needs a
        //    LIVE userinfo probe and belongs in a scheduled reconcile task, NOT the
        //    login hook. TODO(build-host): add \auth_nwc\task\reconcile_locks
        //    (db/tasks.php) to walk locked rows, call userinfo, and SUSPEND rows
        //    whose nwc account is gone (uid_lock already returns ACTION_SUSPEND).
        $nwcactive = true;

        // 4. Run the pure, unit-tested decision + its $DB executor.
        $auth = get_auth_plugin('nwc'); // auth_plugin_nwc
        $decision = $auth->resolve_and_lock($claims, $nwcactive);

        // 5. SESSION-level enforcement (resolve_and_lock only mutates $DB rows).
        switch ($decision['action']) {
            case uid_lock::ACTION_DENY:
            case uid_lock::ACTION_SUSPEND:
                // Broken/empty sub, or a lock that must not stand: tear the session
                // down and bounce to the login page with a neutral error.
                // TODO(build-host): review UX + whether redirect() from inside an
                //   observer is acceptable on your Moodle version (observers run
                //   synchronously within complete_user_login()); an alternative is
                //   to set a session flag and redirect at the next require_login().
                \core\session\manager::kill_user_sessions($user->id);
                if (!during_initial_install() && !CLI_SCRIPT) {
                    redirect(new \moodle_url('/login/index.php'),
                        get_string('locked_denied', 'auth_nwc'), null,
                        \core\output\notification::NOTIFY_ERROR);
                }
                break;

            case uid_lock::ACTION_REUSE_LOCKED:
            case uid_lock::ACTION_LOCK_EXISTING:
            case uid_lock::ACTION_CREATE:
            default:
                // Happy path: the lock is intact / was just (re)applied by the
                // executor. Nothing further to enforce at the session level.
                break;
        }
    }
}
