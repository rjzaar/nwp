#!/bin/bash
set -euo pipefail
################################################################################
# lib/sanitizers/moodle.sh — Moodle DB sanitizer.
#
#   ****  FAIL-CLOSED STUB — NOT YET IMPLEMENTED  ****
#
# ADR-0031 Phase D (ops#76) ships the promotion-pipeline TYPE DISPATCH and this
# placeholder ONLY. The actual anonymisation SQL is deliberately NOT written
# here: per CLAUDE.md the sanitizer is security-critical and gets the same
# human-review treatment as authentication code. ADR-0031 plane 5b is students'
# learning records + `tool_policy` consent acceptances, so an AI must not author
# it. THE OPERATOR authors the body of `moodle_sanitize` under human review.
#
# Until then this script REFUSES to run (exits non-zero), so no Moodle DB can be
# promoted un-sanitized. This mirrors P67's required default: abort rather than
# pass raw PII.
#
# ── PARALLELS lib/sanitizers/standard.sh + lib/sanitizers/mayo.sh ─────────────
# When implemented, this MUST follow the same security model as those two:
#   - The LIVE database is treated as READ-ONLY. Dump it once, load that dump
#     into a throwaway SCRATCH database, run every mutation against the scratch
#     copy, and export a dump of the scratch copy. Live Moodle user data is
#     never modified and never leaves the prod host un-sanitized.
#   - Run ON the Moodle prod server (never on dev / a mirror / an AI host).
#   - Read DB creds into a 0600 option file (password never on argv/ps). Moodle
#     has no drush; read creds from the Moodle root's `config.php`
#     ($CFG->dbname/dbuser/dbpass/dbhost/prefix) instead — e.g. via
#     `php -r 'define("CLI_SCRIPT",true); require "config.php"; echo ...;'`.
#   - The table prefix is CONFIGURABLE ($CFG->prefix, default `mdl_`); resolve
#     it from config.php and never hardcode `mdl_`.
#
################################################################################
# INTERFACE CONTRACT (what the operator must implement)
# ─────────────────────────────────────────────────────────────────────────────
# INPUTS (CLI, kept parallel to standard.sh so the pipeline can call either):
#   --site-dir DIR   Moodle root (contains config.php + version.php).  REQUIRED.
#   --output FILE    Path for the sanitized gzipped dump (default below).
#   --verify         PII-sweep an existing --output dump only; write nothing.
#   -h | --help      Usage.
# (No --drush: Moodle has no drush. Creds come from config.php.)
#
# PRECONDITIONS the implementation must assert (fail-closed if any is false):
#   - $CFG->prefix resolved; scratch DB `<dbname>_sanitize_scratch` creatable.
#   - version.php present (confirms this really is a Moodle root, not Drupal).
#
# TABLES TO COVER — ADR-0031 plane 5b "Moodle learning/user state"
# (names are UNPREFIXED; prepend the resolved $CFG->prefix). This is the
# minimum inventory the operator must classify (DROP / TRUNCATE / ANONYMISE);
# it is NOT exhaustive — audit the live schema, and a plugin that adds PII-
# bearing tables must extend this list:
#
#   Accounts / identity (ANONYMISE — the core PII surface):
#     user                    firstname,lastname,email,username,idnumber,
#                             phone1,phone2,address,city,country,lastip,
#                             secret,picture,description,alternatename,
#                             middlename,firstnamephonetic,lastnamephonetic,
#                             imagealt, auth-provider fields, and password
#                             (set to a known bcrypt hash / "not cached")
#     user_info_data          free-text custom profile field values (PII)
#     user_preferences        may hold tokens / message provider settings
#     user_devices            mobile push tokens (PII / secrets)
#     user_password_history   TRUNCATE (hashes)
#     user_password_resets    TRUNCATE (reset tokens)
#     user_lastaccess         TRUNCATE or keep (attainment metadata, low PII)
#
#   Auth / SSO linkage (ANONYMISE, but PRESERVE the OIDC join — see below):
#     auth_oauth2_linked_login  external OIDC subject/email ↔ user mapping
#     (any auth-nwc-oauth2 plugin tables that store the external subject/email)
#
#   Enrolments / learning state (student attainment — treat as PII per plane 5b):
#     user_enrolments, role_assignments,
#     course_completions, course_modules_completion,
#     grade_grades, grade_grades_history,
#     quiz_attempts, quiz_grades,
#     question_attempts, question_attempt_steps, question_attempt_step_data,
#     scorm_scoes_track, lesson_attempts, assign_submission, assign_grades,
#     badge_issued, certificate/customcert issues
#
#   Consent (IRREVERSIBLE acceptance rows — handle explicitly, do NOT silently
#   drop; ADR-0031 D5/plane 5b call these out by name):
#     tool_policy_acceptances   (+ tool_policy / tool_policy_versions context)
#
#   Communications / logs (TRUNCATE — free-text PII):
#     messages, message*, notifications,
#     logstore_standard_log, log, sessions, events_queue
#
#   moodledata (SEPARATE surface, NOT in the DB): user/private files,
#     sessions, temp, trashdir, and profile pictures under filedir may carry
#     PII. ADR-0031 D8 notes moodledata "joins the backup surface (it is in
#     zero backups today)". The sanitizer (or a sibling step) must scrub/omit
#     user-uploaded files; it is out of scope for the SQL pass but MUST be
#     handled before any Moodle backup is treated as sanitized.
#
# SHARED OIDC EMAIL RULE (deterministic cross-stack linkage):
#   AVC (Drupal) and SS (Moodle) share one OIDC identity. To keep the SSO join
#   working in dev/preview, anonymise emails via the SHARED-SALT primitive, NOT
#   a random rewrite, so the same real email hashes to the same fake email on
#   both stacks:
#     source "$PROJECT_ROOT/lib/sanitizers/oidc-email.sh"
#     oidc_email_sanitize <real_email>   # → deterministic fake email
#     oidc_email_batch <file> <col>      # batch-rewrite a dumped column
#   (F26 §3.3; salt in .secrets.data.yml:oidc.sanitizer_salt, never rotated.)
#
# POST-CONDITION CONTRACT (assert before writing/handing off the dump — any
# failure is fail-closed, exit non-zero, produce NO "clean" artifact):
#   1. Zero rows in `<prefix>user` (id > 1, i.e. excluding the guest/admin
#      convention the operator chooses) retain a non-sanitized email, real
#      username, idnumber, or phone.
#   2. The consent (`tool_policy_acceptances`) handling decision is applied
#      and recorded — never left as raw real-user acceptance rows.
#   3. A PII sweep of the OUTPUT dump is clean (reuse pii_sweep below / the
#      independent lib/pii-gate.sh backstop, which re-scans after the artifact
#      crosses the prod boundary).
#   4. moodledata scrubbing/omission is confirmed (or explicitly deferred to a
#      documented sibling step) — a Moodle backup is not "sanitized" until it is.
#
# Exit: 0 sanitized dump written (and, with --verify, no PII found); non-zero on
#       any failure OR while unimplemented — fail-closed (a failed/absent
#       sanitize must never yield a dump that downstream treats as clean).
################################################################################

OUTPUT="/tmp/moodle-sanitized.sql.gz"
SITE_DIR=""
VERIFY_ONLY=false
# SCRATCH_SUFFIX is part of the future contract (parallel to standard.sh); the
# operator's implementation uses it when creating the throwaway scratch DB.
SCRATCH_SUFFIX="_sanitize_scratch"

while [ $# -gt 0 ]; do
    case "$1" in
        --output)     OUTPUT="$2"; shift 2 ;;
        --output=*)   OUTPUT="${1#*=}"; shift ;;
        --site-dir)   SITE_DIR="$2"; shift 2 ;;
        --site-dir=*) SITE_DIR="${1#*=}"; shift ;;
        --verify)     VERIFY_ONLY=true; shift ;;
        -h|--help)    sed -n '3,/^###/{/^###/d;p}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "moodle-sanitizer: unknown arg: $1" >&2; exit 2 ;;
    esac
done

log()       { echo "[moodle-sanitizer] $*"; }
log_error() { echo "[moodle-sanitizer] ERROR: $*" >&2; }

# ── built-in PII sweep (mirrors standard.sh / lib/pii-gate.sh; the gate is the
#    real backstop). Left ready for the operator's --verify path; it scans an
#    artifact and never touches live data, so it is safe to keep implemented.
pii_sweep() { # $1 = gz dump
    local f="$1"
    command -v zcat >/dev/null 2>&1 || { log_error "zcat missing"; return 2; }
    local hits
    hits=$(zcat -- "$f" 2>/dev/null \
        | grep -E -- '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' 2>/dev/null \
        | grep -Ev -- '@(example\.(com|org|net)|sanitized\.test|drupal\.org|nwpcode\.org)|noreply@|no-reply@' \
        | head -5 || true)
    [ -z "$hits" ] && { log "PII sweep: clean"; return 0; }
    log_error "PII sweep FAIL — residual email-like values remain:"
    printf '%s\n' "$hits" | sed -E 's/[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/[REDACTED]/g' | sed 's/^/    /' >&2
    return 1
}

# --verify is a read-only sweep of an existing artifact and is safe to run now.
if [ "$VERIFY_ONLY" = true ]; then
    [ -f "$OUTPUT" ] || { log_error "no output file to verify: $OUTPUT"; exit 2; }
    pii_sweep "$OUTPUT"; exit $?
fi

################################################################################
# moodle_sanitize — THE OPERATOR IMPLEMENTS THIS.
#
# Fill in per the INTERFACE CONTRACT above: read config.php creds → 0600 option
# file → dump live (read-only) → scratch → anonymise the plane-5b tables →
# export scratch → post-condition asserts → pii_sweep. Until then it MUST keep
# refusing (return non-zero). DO NOT weaken this without human review.
################################################################################
moodle_sanitize() {
    log_error "Moodle sanitizer not yet implemented — operator must author the mdl_user* / consent anonymisation"
    log_error "See the INTERFACE CONTRACT header (plane-5b table inventory + post-condition contract)."
    log_error "Refusing to produce a Moodle dump un-sanitized (fail-closed)."
    return 1
}

[ -n "$SITE_DIR" ] || { log_error "--site-dir DIR is required"; exit 2; }

# FAIL-CLOSED: the sanitize body is unimplemented, so we never write OUTPUT.
moodle_sanitize
exit $?
