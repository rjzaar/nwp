<?php
/**
 * local_nwc_erase\erase_guard — the PURE, Moodle-free guard + decision core
 * of the ops#81 erasure receiver.
 *
 * Everything in here is a static function with NO Moodle dependency, so the
 * fail-closed guard rail (Bearer / IP / command-shape) and the idempotency
 * decision are unit-testable with plain `php` (tests/erase_guard_logic_test.php),
 * exactly like scripts/f26/moodle/auth_nwc/classes/uid_lock.php.
 *
 * This class NEVER touches the database, NEVER resolves a user, and NEVER
 * deletes anything — it only says yes/no and (for a valid command) hands a
 * normalised command back to eraser.php. The destructive Privacy-API work
 * lives in classes/eraser.php.
 *
 * FAIL-CLOSED CONTRACT: every method refuses on any doubt. There is no code
 * path that erases on a missing/invalid Bearer, a disallowed IP, a malformed
 * command, or an empty/absent `sub`. `sub` is ALWAYS the durable Drupal
 * account UUID (== mdl_user.idnumber, ops#83) — NEVER email.
 */
namespace local_nwc_erase;

defined('MOODLE_INTERNAL') || die();

class erase_guard {

    const COMPONENT = 'local_nwc_erase';

    /** Decision outcomes returned by decide(). */
    const ACTION_PROCEED          = 'proceed';            // resolve + erase
    const ACTION_NOOP_REPLAYED    = 'noop_replayed';      // request_id already processed
    const ACTION_NOOP_MISSING     = 'noop_missing_user';  // no row by idnumber == sub

    /** The only two erase modes the contract allows. */
    const MODES = ['delete', 'anonymise'];

    /**
     * Constant-time Bearer check. Mirrors policy_set.php: refuses unless the
     * configured token is non-empty AND the header is exactly "Bearer <token>"
     * AND hash_equals matches.
     */
    public static function bearer_ok(string $expected, string $auth_header): bool {
        if ($expected === '' || strpos($auth_header, 'Bearer ') !== 0) {
            return false;
        }
        $provided = substr($auth_header, strlen('Bearer '));
        return hash_equals($expected, $provided);
    }

    /**
     * IP allowlist. Empty allowlist config => allow (parity with policy_set.php,
     * where the allowlist is an OPTIONAL second factor on top of the Bearer).
     * A non-empty allowlist => the remote IP must appear exactly.
     */
    public static function ip_allowed(string $remote, string $allowed_ips_raw): bool {
        $allowed_ips_raw = trim($allowed_ips_raw);
        if ($allowed_ips_raw === '') {
            return true;
        }
        $allowed = array_filter(array_map('trim', explode(',', $allowed_ips_raw)));
        return in_array($remote, $allowed, true);
    }

    /**
     * Optional issuer binding. If the plugin is configured with an
     * allowed_issuer, the command's `issuer` MUST match it (fail-closed).
     * Empty config => not enforced (Bearer + IP already gate the channel).
     */
    public static function issuer_ok(string $expected_issuer, string $command_issuer): bool {
        $expected_issuer = trim($expected_issuer);
        if ($expected_issuer === '') {
            return true;
        }
        return hash_equals($expected_issuer, trim($command_issuer));
    }

    /**
     * Validate the decoded JSON body against contracts/erasure.command.schema.json's
     * CLOSED shape: required {sub, request_id, action, issuer, timestamp},
     * additionalProperties:false, action ∈ {delete, anonymise}, timestamp int,
     * the three id/issuer strings non-empty. Returns:
     *   ['ok' => true,  'command' => [normalised fields]]
     *   ['ok' => false, 'errors'  => [ '...' ]]
     */
    public static function validate_command($body): array {
        if (!is_array($body)) {
            return ['ok' => false, 'errors' => ['body is not a json object']];
        }

        $required = ['sub', 'request_id', 'action', 'issuer', 'timestamp'];
        $allowed  = $required; // additionalProperties: false
        $errors   = [];

        foreach ($required as $f) {
            if (!array_key_exists($f, $body)) {
                $errors[] = "missing: $f";
            }
        }
        foreach (array_keys($body) as $k) {
            if (!in_array($k, $allowed, true)) {
                $errors[] = "unexpected property: $k"; // data-minimisation gate
            }
        }
        if ($errors) {
            return ['ok' => false, 'errors' => $errors];
        }

        // Non-empty opaque strings — NEVER treat any of these as an email.
        foreach (['sub', 'request_id', 'issuer'] as $f) {
            if (!is_string($body[$f]) || trim($body[$f]) === '') {
                $errors[] = "$f must be a non-empty string";
            }
        }
        if (!is_string($body['action']) || !in_array($body['action'], self::MODES, true)) {
            $errors[] = 'action must be one of: ' . implode(', ', self::MODES);
        }
        // JSON has no int type distinct from float; reject non-integers + bools.
        if (!is_int($body['timestamp'])
            && !(is_numeric($body['timestamp']) && (string)(int)$body['timestamp'] === (string)$body['timestamp'])) {
            $errors[] = 'timestamp must be an integer (seconds since epoch)';
        }
        if ($errors) {
            return ['ok' => false, 'errors' => $errors];
        }

        return ['ok' => true, 'command' => [
            'sub'        => (string) $body['sub'],
            'request_id' => (string) $body['request_id'],
            'action'     => (string) $body['action'],
            'issuer'     => (string) $body['issuer'],
            'timestamp'  => (int) $body['timestamp'],
        ]];
    }

    /**
     * Idempotency + missing-user decision. PURE: the caller passes booleans it
     * has already looked up (was this request_id logged as done? did a row with
     * idnumber == sub exist?). No DB access here.
     *
     *   already_processed = true            -> ACTION_NOOP_REPLAYED (safe replay)
     *   user_found        = false           -> ACTION_NOOP_MISSING  (already gone)
     *   else                                -> ACTION_PROCEED
     *
     * Both no-ops return HTTP 200 (idempotent success), NOT an error.
     */
    public static function decide(bool $already_processed, bool $user_found): string {
        if ($already_processed) {
            return self::ACTION_NOOP_REPLAYED;
        }
        if (!$user_found) {
            return self::ACTION_NOOP_MISSING;
        }
        return self::ACTION_PROCEED;
    }
}
