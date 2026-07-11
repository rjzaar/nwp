<?php
// This file is part of the auth_nwc plugin for Moodle (F26 nwc<->ss OIDC).
//
// AUTH SURFACE — REQUIRES HUMAN REVIEW BEFORE MERGE/ENABLE.
//
// GNU GPL v3 or later. Copyright 2026 Narrow Way Project.

namespace auth_nwc;

/**
 * Pure UID-lock decision logic for F26 § 3.2.
 *
 * The Moodle account is permanently bound to the nwc (Drupal) user id via
 * mdl_user.idnumber. On first OIDC login, Moodle looks for a row locked to
 * the nwc uid (the ID token `sub`). After lock, lookup is ALWAYS by idnumber,
 * NEVER by email — email and name may change, the lock never does.
 *
 * This class is deliberately free of any Moodle dependency so the decision
 * can be unit-tested with plain PHP (see tests/uid_lock_logic_test.php). The
 * auth plugin (auth.php) supplies the DB rows and executes the returned action.
 *
 * Security notes:
 *  - `sub` is the subject of an ID token signed by the nwc issuer (RS256,
 *    verified against nwc's JWKS). It is NOT user-supplied. An empty/unsigned
 *    sub is a broken token -> DENY (never create, never guess).
 *  - The one-time legacy-email link (ACTION_LOCK_EXISTING) is only reached when
 *    the ID token carries email_verified === true for that email; the caller
 *    MUST enforce that before passing row_by_email. This is why linking a
 *    pre-OIDC Moodle account by email is not an account-takeover vector: the
 *    email is asserted by the trusted issuer, not typed by the client.
 *  - There is NO shared-secret / bearer-in-URL / anonymous path here. Every
 *    action requires a verified `sub`.
 */
final class uid_lock {

    /** New Moodle row must be created, locked to the nwc uid. */
    const ACTION_CREATE = 'create';
    /** Existing row already locked to this nwc uid — reuse, refresh email/name. */
    const ACTION_REUSE_LOCKED = 'reuse_locked';
    /** One-time migration: bind a legacy (email-matched) row to the nwc uid. */
    const ACTION_LOCK_EXISTING = 'lock_existing';
    /** nwc account no longer resolves but a locked row exists — suspend it. */
    const ACTION_SUSPEND = 'suspend';
    /** Cannot establish a trusted identity — refuse the login. */
    const ACTION_DENY = 'deny';

    /**
     * Decide what to do for an OIDC login, per F26 § 3.2.
     *
     * @param array $ctx {
     *   @var string      sub                  nwc uid from the verified ID token (required).
     *   @var bool        nwc_active           true if userinfo resolved (nwc account exists).
     *   @var object|null row_by_idnumber      mdl_user row where idnumber === sub, or null.
     *   @var object|null row_by_email         legacy mdl_user row matching the verified claim email, or null.
     *   @var bool        link_legacy_by_email migration-window flag (default false).
     * }
     * @return array { action: string, idnumber: string, reason: string }
     */
    public static function decide(array $ctx): array {
        $sub = isset($ctx['sub']) ? trim((string) $ctx['sub']) : '';
        $nwc_active = !empty($ctx['nwc_active']);
        $by_idnumber = $ctx['row_by_idnumber'] ?? null;
        $by_email = $ctx['row_by_email'] ?? null;
        $link_email = !empty($ctx['link_legacy_by_email']);

        // 1. No trusted subject -> refuse. Never fabricate an identity.
        if ($sub === '') {
            return self::r(self::ACTION_DENY, '', 'empty sub (untrusted or broken ID token)');
        }

        // 2. nwc account no longer resolves.
        if (!$nwc_active) {
            if ($by_idnumber !== null) {
                // Keep Moodle course history; suspend rather than delete (F26 § 3.2).
                return self::r(self::ACTION_SUSPEND, $sub, 'nwc account gone; suspend locked Moodle user');
            }
            return self::r(self::ACTION_DENY, $sub, 'nwc account unresolvable and no locked Moodle row');
        }

        // 3. Already locked to this nwc uid -> reuse. Lookup is by idnumber only.
        if ($by_idnumber !== null) {
            return self::r(self::ACTION_REUSE_LOCKED, $sub, 'existing idnumber lock');
        }

        // 4. One-time migration link of a legacy row, only if explicitly enabled
        //    and only against a verified-email match (caller enforces verification).
        if ($by_email !== null && $link_email) {
            return self::r(self::ACTION_LOCK_EXISTING, $sub, 'migration: bind legacy email-matched row to nwc uid');
        }

        // 5. Brand-new user -> create, locked to the nwc uid.
        return self::r(self::ACTION_CREATE, $sub, 'new user; create locked row');
    }

    private static function r(string $action, string $idnumber, string $reason): array {
        return ['action' => $action, 'idnumber' => $idnumber, 'reason' => $reason];
    }
}
