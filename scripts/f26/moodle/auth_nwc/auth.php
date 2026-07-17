<?php
// auth_nwc — Moodle OIDC client for F26 nwc<->ss single sign-on.
//
//   AUTH SURFACE — REQUIRES HUMAN REVIEW BEFORE MERGE/ENABLE.
//
// GNU GPL v3 or later. Copyright 2026 Narrow Way Project.
//
// Design (F26 § 3, nwc<->ss extension per P72 § 3.2 shape 1: nwc is issuer):
//
//   * Moodle core OAuth2 (\core\oauth2\api) performs the standard
//     authorization-code + PKCE dance against the nwc issuer. The issuer,
//     its endpoints, client id and secret are configured as a *custom*
//     Moodle OAuth2 service (Site admin > Server > OAuth2 services), NOT
//     hard-coded here — see moodle/INSTALL.md.
//   * This plugin adds the F26 UID-LOCK on top of that dance: it binds each
//     Moodle account to the nwc uid (the `sub` claim) via mdl_user.idnumber,
//     and thereafter resolves the user by idnumber, never by email.
//   * The lock DECISION is pure and unit-tested in classes/uid_lock.php; this
//     file only supplies the Moodle DB rows and executes the chosen action.
//
// TRUST MODEL (ops#82, verified read-only 2026-07-11): Moodle core auth_oauth2
// does NOT verify the id_token RS256 signature against nwc's JWKS — it runs the
// authorization-code + PKCE(S256) grant against the confidential client, then
// reads the `sub` (and other claims) from the /oauth/userinfo endpoint over TLS
// with a bearer access token. The trust anchors are therefore TLS + the
// confidential-client token endpoint + PKCE + the bearer userinfo call, NOT a
// JWT signature. (If a future consumer starts verifying the JWKS signature, the
// key-rotation runbook's hard-swap safety no longer holds — see
// docs/guides/ops82-key-rotation.md.)
//
// NO SHORTCUTS: there is no shared secret, no bearer token in a URL and no
// anonymous auto-create. Every login requires a `sub` obtained from the issuer's
// authenticated userinfo endpoint; an empty/absent sub is a DENY.

defined('MOODLE_INTERNAL') || die();

require_once($CFG->libdir . '/authlib.php');

use auth_nwc\uid_lock;

class auth_plugin_nwc extends auth_plugin_base {

    public function __construct() {
        $this->authtype = 'nwc';
        $this->config = get_config('auth_nwc');
    }

    /** OIDC only — never username/password. */
    public function user_login($username, $password) {
        return false;
    }

    public function can_change_password() { return false; }
    public function can_edit_profile() { return false; }
    public function prevent_local_passwords() { return true; }
    public function is_internal() { return false; }

    /** Password/profile management lives on nwc (Drupal). */
    public function change_password_url() {
        return $this->nwc_url('/user/password');
    }
    public function edit_profile_url() {
        return $this->nwc_url('/user/edit');
    }

    /**
     * Optionally push users straight to nwc for login.
     * Uses Moodle core's /auth/oauth2/login.php against the configured issuer.
     */
    public function loginpage_hook() {
        global $SESSION;
        if (empty($this->config->autoredirect) || empty($this->config->issuerid)) {
            return;
        }
        $issuer = \core\oauth2\api::get_issuer($this->config->issuerid);
        if ($issuer && $issuer->get('enabled')) {
            redirect(new moodle_url('/auth/oauth2/login.php', [
                'id'       => $issuer->get('id'),
                'wantsurl' => $SESSION->wantsurl ?? '',
                'sesskey'  => sesskey(),
            ]));
        }
    }

    /**
     * Apply the F26 UID-lock for a verified OIDC login.
     *
     * Call this with the userinfo claims core OAuth2 fetched after the
     * authorization-code + PKCE grant (bearer call to /oauth/userinfo over TLS
     * — core does NOT verify a JWKS/RS256 id_token signature; see the trust-model
     * note at the top of this file). Returns the decision (see uid_lock) and
     * mutates $DB accordingly.
     *
     * @param array $claims verified OIDC claims: sub, email, email_verified, name, ...
     * @param bool  $nwc_active whether userinfo resolved (nwc account still exists)
     * @return array the uid_lock decision (action/idnumber/reason)
     */
    public function resolve_and_lock(array $claims, bool $nwc_active = true): array {
        global $DB, $CFG;

        $sub = isset($claims['sub']) ? trim((string) $claims['sub']) : '';
        $email = isset($claims['email']) ? trim((string) $claims['email']) : '';
        $emailverified = !empty($claims['email_verified']);
        $linkbyemail = !empty($this->config->link_legacy_by_email) && $emailverified;

        $byid = $sub !== ''
            ? $DB->get_record('user', ['idnumber' => $sub, 'mnethostid' => $CFG->mnet_localhost_id, 'deleted' => 0])
            : false;
        $byemail = ($email !== '' && $linkbyemail)
            ? $DB->get_record('user', ['email' => $email, 'mnethostid' => $CFG->mnet_localhost_id, 'deleted' => 0])
            : false;

        $decision = uid_lock::decide([
            'sub'                  => $sub,
            'nwc_active'           => $nwc_active,
            'row_by_idnumber'      => $byid ?: null,
            'row_by_email'         => $byemail ?: null,
            'link_legacy_by_email' => $linkbyemail,
        ]);

        $this->log('uid_lock decision: ' . $decision['action'] . ' (' . $decision['reason'] . ') sub=' . $sub);

        switch ($decision['action']) {
            case uid_lock::ACTION_REUSE_LOCKED:
                // Refresh mutable fields; NEVER touch idnumber.
                $this->refresh_user_fields($byid, $claims);
                return $decision + ['userid' => $byid->id];

            case uid_lock::ACTION_LOCK_EXISTING:
                // One-time migration bind of a verified-email legacy account.
                $byemail->idnumber = $sub;
                $this->refresh_user_fields($byemail, $claims, /*save*/ true);
                return $decision + ['userid' => $byemail->id];

            case uid_lock::ACTION_SUSPEND:
                if ($byid) {
                    $DB->set_field('user', 'suspended', 1, ['id' => $byid->id]);
                    return $decision + ['userid' => $byid->id];
                }
                return $decision;

            case uid_lock::ACTION_CREATE:
                // New users are created by core auth_oauth2 itself (via the required
                // sub->idnumber issuer field-mapping) BEFORE this executor runs from
                // the \auth_nwc\observer::user_loggedin seam, so by the time we see
                // the login the row already exists and resolves as REUSE_LOCKED.
                // Nothing to create here. (Removed the never-implemented
                // locked_idnumber() indirection referenced in the old comment — F26 B1.)
                return $decision;

            case uid_lock::ACTION_DENY:
            default:
                return $decision;
        }
    }

    /** Update email/name from claims without ever changing idnumber. */
    protected function refresh_user_fields(\stdClass $user, array $claims, bool $save = false) {
        global $DB;
        $dirty = false;
        if (!empty($claims['email']) && $user->email !== $claims['email']) {
            $user->email = $claims['email']; $dirty = true;
        }
        if (!empty($claims['given_name']) && $user->firstname !== $claims['given_name']) {
            $user->firstname = $claims['given_name']; $dirty = true;
        }
        if (!empty($claims['family_name']) && $user->lastname !== $claims['family_name']) {
            $user->lastname = $claims['family_name']; $dirty = true;
        }
        if (($save || $dirty)) {
            $DB->update_record('user', $user);
        }
    }

    protected function nwc_url($path) {
        if (!empty($this->config->nwc_url)) {
            return new moodle_url(rtrim($this->config->nwc_url, '/') . $path);
        }
        return null;
    }

    protected function log($msg) {
        if (!empty($this->config->enable_logging) && debugging('', DEBUG_DEVELOPER)) {
            mtrace('[auth_nwc] ' . $msg);
        }
    }

    /**
     * Reconcile a member's Moodle cohorts to match their nwc `guilds` claim.
     *
     * Claims-pull at login (ops#93): each managed cohort mirrors one nwc guild,
     * bound by the guild's STABLE uuid — cohort.idnumber = 'nwcguild:'.uuid —
     * never by the serial group id (which renumbers on a DB rebuild) and never
     * by label. The pure decision lives in \auth_nwc\guild_cohort_map; this only
     * executes it against $DB.
     *
     * Only ever touches membership of cohorts whose idnumber carries the managed
     * prefix, so operator-created cohorts are never modified. Best-effort: any
     * failure is logged and swallowed — guild sync must never break a login.
     *
     * @param int   $userid Moodle user id.
     * @param array $guilds The `guilds` claim: [{uuid, label, type, roles[]}, …].
     * @return array{joined: string[], left: string[], created: string[]}
     */
    public function sync_guilds(int $userid, array $guilds): array {
        global $DB, $CFG;
        require_once($CFG->dirroot . '/cohort/lib.php');

        $result = ['joined' => [], 'left' => [], 'created' => []];

        try {
            // The guild uuids the member is CURRENTLY in via managed cohorts.
            $sql = "SELECT c.idnumber
                      FROM {cohort} c
                      JOIN {cohort_members} cm ON cm.cohortid = c.id
                     WHERE cm.userid = :userid";
            $current = [];
            foreach ($DB->get_fieldset_sql($sql, ['userid' => $userid]) as $idnumber) {
                if (\auth_nwc\guild_cohort_map::is_managed((string) $idnumber)) {
                    $current[] = \auth_nwc\guild_cohort_map::uuid_from((string) $idnumber);
                }
            }

            $plan = \auth_nwc\guild_cohort_map::decide($guilds, $current);

            // JOIN / CREATE. Cohorts live in the system context.
            $systemctx = \context_system::instance();
            foreach ($plan['ensure'] as $g) {
                $idnumber = \auth_nwc\guild_cohort_map::idnumber_for($g['uuid']);
                $cohort = $DB->get_record('cohort', ['idnumber' => $idnumber]);
                if (!$cohort) {
                    $cohort = (object) [
                        'contextid'   => $systemctx->id,
                        'name'        => $g['label'],
                        'idnumber'    => $idnumber,
                        'description' => 'Auto-managed by auth_nwc; mirrors an nwc guild. Do not edit membership by hand.',
                        'descriptionformat' => FORMAT_PLAIN,
                        'visible'     => 1,
                    ];
                    $cohort->id = cohort_add_cohort($cohort);
                    $result['created'][] = $g['label'];
                }
                if (!$DB->record_exists('cohort_members', ['cohortid' => $cohort->id, 'userid' => $userid])) {
                    cohort_add_member($cohort->id, $userid);
                    $result['joined'][] = $g['label'];
                }
            }

            // LEAVE — only managed cohorts the member is no longer entitled to.
            foreach ($plan['leave'] as $uuid) {
                $idnumber = \auth_nwc\guild_cohort_map::idnumber_for($uuid);
                $cohort = $DB->get_record('cohort', ['idnumber' => $idnumber]);
                if ($cohort && $DB->record_exists('cohort_members', ['cohortid' => $cohort->id, 'userid' => $userid])) {
                    cohort_remove_member($cohort->id, $userid);
                    $result['left'][] = $cohort->name;
                }
            }

            $this->log(sprintf('guild sync uid=%d joined=[%s] left=[%s] created=[%s]',
                $userid, implode(',', $result['joined']), implode(',', $result['left']), implode(',', $result['created'])));
        } catch (\Throwable $e) {
            // Never let guild sync break a login.
            $this->log('guild sync FAILED uid=' . $userid . ': ' . $e->getMessage());
        }

        return $result;
    }
}
