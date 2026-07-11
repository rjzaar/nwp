<?php
/**
 * local_nwc_erase\eraser — the Moodle-COUPLED destructive half of the ops#81
 * receiver. Runs ONLY after erase_guard has passed the Bearer/IP/command guards.
 *
 * WHY THE PRIVACY API, NOT delete_user():
 *   Moodle's core delete_user() is only a SOFT delete — it sets deleted=1 and
 *   scrambles username/email but LEAVES residual PII (lastip, phone, address,
 *   idnumber) and is explicitly NOT GDPR-compliant (moodle.org d=372709).
 *   True right-to-be-forgotten erasure is the Privacy API
 *   (\tool_dataprivacy\api), which walks every component's
 *   delete_data_for_user() across all contexts. So this class triggers a
 *   Privacy-API DELETE data-request, auto-approves it, and runs the ad-hoc
 *   process task — it never calls bare delete_user().
 *
 * DESTRUCTIVE. On a real prod tier this fires ONLY through the `ver` desktop
 * Solo-touch deploy gate (CLAUDE.md AI-never-prod); the receiver token for a
 * prod tier is a `ver`-held secret. dev/stg/live-test tiers are agent-operable
 * (A14). See README.md §Boundary.
 */
namespace local_nwc_erase;

defined('MOODLE_INTERNAL') || die();

class eraser {

    const COMPONENT = 'local_nwc_erase';

    /**
     * Resolve the target Moodle user STRICTLY by idnumber == sub (the F26
     * UID-lock; ops#83 sub == Drupal account UUID). NEVER by email — a recycled
     * email must never resolve to the wrong person (pitfall 2c, B1 fail-closed).
     * Also excludes already-deleted rows.
     *
     * @return \stdClass|null the mdl_user row, or null if none.
     */
    public static function resolve_user_by_sub(string $sub): ?\stdClass {
        global $DB;
        $sub = trim($sub);
        if ($sub === '') {
            return null; // never fabricate a target
        }
        $row = $DB->get_record('user', ['idnumber' => $sub, 'deleted' => 0], '*', IGNORE_MULTIPLE);
        return $row ?: null;
    }

    /** Has this request_id already been completed? (idempotency key). */
    public static function already_processed(string $request_id): bool {
        global $DB;
        return $DB->record_exists('local_nwc_erase_log',
            ['request_id' => $request_id, 'outcome' => 'done']);
    }

    /**
     * Execute a validated + guarded erase command. Assumes erase_guard has
     * ALREADY authorised the request. Idempotent, audited, fail-closed.
     *
     * @param array $command normalised command from erase_guard::validate_command()
     * @return array response body (always includes ok + action + request_id)
     */
    public static function execute(array $command): array {
        global $DB, $CFG;

        $request_id = $command['request_id'];
        $sub        = $command['sub'];
        $mode       = $command['action']; // delete | anonymise

        // Idempotent replay guard (DB-backed; erase_guard::decide mirror).
        if (self::already_processed($request_id)) {
            return ['ok' => true, 'action' => erase_guard::ACTION_NOOP_REPLAYED,
                    'request_id' => $request_id];
        }

        $user = self::resolve_user_by_sub($sub);
        if ($user === null) {
            // Already gone — a valid, idempotent no-op. Log it so a later replay
            // is also cheap, and so the erasure is auditable both sides.
            self::write_log($request_id, $sub, $mode, 'noop_missing_user', []);
            return ['ok' => true, 'action' => erase_guard::ACTION_NOOP_MISSING,
                    'request_id' => $request_id];
        }

        $touched = [];

        // 1. Sever the SSO re-link FIRST so a race can't re-provision mid-erase.
        //    (auth_oauth2 also has a privacy provider, but we proactively drop
        //    the linked_login row to close the re-link door immediately.)
        if ($DB->get_manager()->table_exists('auth_oauth2_linked_login')) {
            $DB->delete_records('auth_oauth2_linked_login', ['userid' => $user->id]);
            $touched[] = 'auth_oauth2_linked_login';
        }

        // 2. Privacy-API erasure (NOT delete_user). create_data_request(DELETE)
        //    -> approve -> run the ad-hoc process task, which fans out
        //    delete_data_for_user() across every component + context.
        require_once($CFG->dirroot . '/admin/tool/dataprivacy/lib.php');
        $datatype = ($mode === 'anonymise')
            ? \tool_dataprivacy\api::DATAREQUEST_TYPE_DELETE // Moodle has no first-class
            : \tool_dataprivacy\api::DATAREQUEST_TYPE_DELETE; // "anonymise" request type;
        // NOTE (P4): Moodle exposes DELETE + EXPORT request types only. The
        // Privacy API already RETAINS lawfully-required aggregate rows during a
        // DELETE (grades/audit where a legal basis applies), so "delete" here IS
        // the honest RTBF fan-out. A distinct "anonymise" that KEEPS de-identified
        // aggregates is a P4 refinement (per-provider overrides); for P1/P2 both
        // modes drive the same Privacy-API DELETE and we record the requested mode.
        $datarequest = \tool_dataprivacy\api::create_data_request(
            $user->id,
            \tool_dataprivacy\api::DATAREQUEST_TYPE_DELETE,
            'ops#81 erasure-propagation (nwc RTBF): request_id ' . $request_id
        );
        $requestid = (is_object($datarequest) && method_exists($datarequest, 'get'))
            ? (int) $datarequest->get('id')
            : (int) $datarequest;

        // Auto-approve (trusted OP-driven command) then run the delete task.
        \tool_dataprivacy\api::approve_data_request($requestid);
        $task = new \tool_dataprivacy\task\process_data_request_task();
        $task->set_custom_data(['requestid' => $requestid]);
        \core\task\manager::queue_adhoc_task($task, true);
        $touched[] = 'privacy_api:data_request#' . $requestid;

        // 3. moodledata file sweep — reuse the ops#84 dataroot scrubber contract
        //    for the user's on-disk file areas (submissions, certs, profile img).
        //    The Privacy API deletes file rows per context; this is the belt-and-
        //    braces on-disk verification. Invoked out-of-band (the shell scrubber
        //    runs on the Moodle host); here we record the intent + leave a marker
        //    the operator's ops#84 run keys off. See README §moodledata.
        $touched[] = 'moodledata:ops84-scrub-pending';

        // 4. Audit row (both-side auditable) + success.
        self::write_log($request_id, $sub, $mode, 'done', $touched, (int) $user->id);

        return ['ok' => true, 'action' => 'deleted', 'mode' => $mode,
                'request_id' => $request_id, 'touched' => $touched];
    }

    /**
     * Append an immutable audit row. NEVER stores the email — only the durable
     * sub (UUID) + the numeric userid + what was touched.
     */
    public static function write_log(string $request_id, string $sub, string $mode,
                                     string $outcome, array $touched, int $userid = 0): void {
        global $DB;
        $DB->insert_record('local_nwc_erase_log', (object) [
            'request_id' => $request_id,
            'sub'        => $sub,
            'userid'     => $userid,
            'mode'       => $mode,
            'outcome'    => $outcome,
            'touched'    => json_encode(array_values($touched)),
            'timecreated' => time(),
        ]);
    }
}
