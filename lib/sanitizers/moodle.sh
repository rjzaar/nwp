#!/bin/bash
set -euo pipefail
################################################################################
# lib/sanitizers/moodle.sh — Moodle DB sanitizer.
#
#   ****  IMPLEMENTED — prod-native, scratch-DB model (ops#76 / ops#110)  ****
#
# `moodle_sanitize` (below, ~line 487) is the reviewed implementation. It
# conforms to the SAME CLI interface as lib/sanitizers/standard.sh + mayo.sh
# (--site-dir / --output / --verify), so scripts/commands/server-publish.sh can
# invoke it directly (Path A). Per CLAUDE.md the sanitizer is security-critical
# and gets the same human-review treatment as authentication code — every change
# to this file requires explicit human review before merge.
#
# STILL FAIL-CLOSED: any precondition/post-condition failure exits non-zero and
# produces NO "clean" artifact, so a failed sanitize can never yield a dump that
# downstream treats as sanitized (P67's required default: abort rather than pass
# raw PII). ADR-0031 plane 5b = students' learning records + `tool_policy`
# consent acceptances; those are handled explicitly below (never silently dropped).
#
# NOTE (ops#110): the DDEV in-place path in lib/database-router.sh
# (_sanitize_staging_db_moodle, used by pl prod2stg/live2stg) is a SEPARATE
# execution context — it runs `ddev drush`, whereas this script runs bare
# mysql/mysqldump against config.php creds. Wiring that path to this
# implementation is a design decision tracked in ops#110, NOT done here.
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
#     external_tokens         TRUNCATE (live web-service auth tokens = credentials)
#     user_private_key        TRUNCATE (per-user WS/MNet private keys = credentials)
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
# ops#127: DR mode. Default (dev-preview) scrubs ALL real users (id>1, incl. the
# admin) then makes the primary admin loginable with an anonymised identity.
# --preserve-admin (DR) instead PRESERVES the real siteadmins untouched (so a
# restore has usable real admins) and scrubs everyone else. Moodle admins are the
# `siteadmins` set (typically uid 2; uid 1 is guest) — NOT literally uid 1. The
# preserved admins' real emails are captured pre-scrub and allowlisted in pii_sweep.
PRESERVE_ADMIN=false
ADMIN_MAIL=""              # --verify: comma/space-separated preserved admin emails
USER_SCRUB_WHERE="id > 1" # scrub floor; --preserve-admin appends "AND id NOT IN (siteadmins)"
PRESERVE_ADMIN_MAILS=""   # captured from the scratch DB in the main flow (newline-sep)

while [ $# -gt 0 ]; do
    case "$1" in
        --output)     OUTPUT="$2"; shift 2 ;;
        --output=*)   OUTPUT="${1#*=}"; shift ;;
        --site-dir)   SITE_DIR="$2"; shift 2 ;;
        --site-dir=*) SITE_DIR="${1#*=}"; shift ;;
        --preserve-admin) PRESERVE_ADMIN=true; shift ;;
        --admin-mail) ADMIN_MAIL="$2"; shift 2 ;;
        --admin-mail=*) ADMIN_MAIL="${1#*=}"; shift ;;
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
    # FAIL-CLOSED on an unreadable/corrupt/truncated gzip: a swallowed zcat error
    # must NEVER read as "clean". Integrity-check + assert a non-empty stream
    # BEFORE the sweep (else `hits` is empty for the wrong reason → false clean).
    gzip -t -- "$f" 2>/dev/null || { log_error "PII sweep: '$f' is not a valid gzip (corrupt/truncated) — refusing (fail-closed)"; return 2; }
    [ "$(zcat -- "$f" 2>/dev/null | head -c1 | wc -c)" -gt 0 ] || { log_error "PII sweep: '$f' decompresses to empty — refusing (fail-closed)"; return 2; }
    # ops#127: with --preserve-admin, the real siteadmin emails are legitimately
    # retained — allowlist exactly those (fixed-string, one per line) so the sweep
    # stays fail-closed on every other address. Sources: captured scratch values
    # (PRESERVE_ADMIN_MAILS) or the --verify-passed ADMIN_MAIL (comma/space list).
    local admin_allow="" _amf=""
    if [ "$PRESERVE_ADMIN" = true ]; then
        admin_allow="${PRESERVE_ADMIN_MAILS:-$(printf '%s' "$ADMIN_MAIL" | tr ', ' '\n\n')}"
    fi
    local hits
    if [ -n "$admin_allow" ]; then
        _amf="$(mktemp)"; printf '%s\n' "$admin_allow" | grep -E '.@.' > "$_amf" || true
    fi
    hits=$(zcat -- "$f" 2>/dev/null \
        | grep -E -- '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' 2>/dev/null \
        | grep -Ev -- '@(example\.(com|org|net)|sanitized\.test|drupal\.org|nwpcode\.org)|noreply@|no-reply@' \
        | { if [ -n "$_amf" ] && [ -s "$_amf" ]; then grep -Fvf "$_amf"; else cat; fi; } \
        | head -5 || true)
    [ -n "$_amf" ] && rm -f "$_amf"
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
# moodle_sanitize — IMPLEMENTED (ops#76 / ADR-0031 plane 5b).
#
# Security model — identical to lib/sanitizers/standard.sh + mayo.sh:
#   The LIVE DB is READ-ONLY. Dump it once → load that dump into a throwaway
#   SCRATCH DB → run every mutation against the scratch copy → export the
#   scratch copy. Live Moodle user data is never modified and never leaves this
#   host un-sanitized. Run this ON the Moodle prod server, never on dev/AI hosts.
#
#   Creds come from the Moodle root's config.php ($CFG->*), NOT drush (Moodle
#   ships none). The table prefix ($CFG->prefix) is RESOLVED from config.php and
#   used for every table name — never hardcoded 'mdl_'.
#
#   Emails are anonymised with the SHARED-SALT OIDC primitive (oidc-email.sh) so
#   the same real email hashes to the same fake email on both AVC (Drupal) and
#   SS (Moodle), preserving the SSO join in dev/preview (F26 §3.3).
#
#   Injection safety: real PII values (emails/usernames) are ONLY fed to
#   sha256sum to compute the deterministic fake; they are never interpolated
#   into SQL. Row keys are integer `id` columns, validated `^[0-9]+$` before use.
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/oidc-email.sh"
# Fail-closed guard: every mutation must target a SCRATCH DB distinct from live.
source "$SCRIPT_DIR/../prod-guard.sh"

# Module-level DB handles, populated by _moodle_init_db_access.
MYSQL_CNF=""
SCRATCH_DB=""
LIVE_DB=""
PREFIX=""
LIVE_DUMP=""

mysql_cli() { mysql --defaults-extra-file="$MYSQL_CNF" "$@"; }
sq()        { mysql_cli -N -B "$SCRATCH_DB" -e "$1"; }

_moodle_cleanup() {
    if [ -n "${SCRATCH_DB:-}" ] && [ -n "${MYSQL_CNF:-}" ] && [ -f "${MYSQL_CNF:-}" ]; then
        mysql_cli -e "DROP DATABASE IF EXISTS \`${SCRATCH_DB}\`" 2>/dev/null || true
    fi
    [ -n "${MYSQL_CNF:-}" ] && rm -f "$MYSQL_CNF"
    [ -n "${LIVE_DUMP:-}" ] && rm -f "$LIVE_DUMP"
    return 0
}

# Read $CFG->* from config.php WITHOUT bootstrapping Moodle. Uses Moodle's own
# ABORT_AFTER_CONFIG guard so lib/setup.php returns before any DB connection is
# made. Emits TSV: key<TAB>value for dbname/dbuser/dbpass/dbhost/dbport/dbsocket/
# prefix. The password reaches only this TSV → a 0600 option file (never argv).
_moodle_read_config() {
    local site_dir="$1"
    local cfg="$site_dir/config.php"
    [ -f "$cfg" ] || { log_error "config.php not found in Moodle root: $cfg"; return 1; }
    command -v php >/dev/null 2>&1 || { log_error "php required to read Moodle config.php"; return 1; }
    php -d error_reporting=0 -d display_errors=0 -r '
        define("CLI_SCRIPT", true);
        define("ABORT_AFTER_CONFIG", true);       // Moodle returns from setup.php before DB init
        require($argv[1]);
        $o = (isset($CFG->dboptions) && is_array($CFG->dboptions)) ? $CFG->dboptions : array();
        $g = function($k) use ($CFG) { return isset($CFG->$k) ? $CFG->$k : ""; };
        printf("dbname\t%s\n",   $g("dbname"));
        printf("dbuser\t%s\n",   $g("dbuser"));
        printf("dbpass\t%s\n",   $g("dbpass"));
        printf("dbhost\t%s\n",   $g("dbhost"));
        printf("dbport\t%s\n",   isset($o["dbport"])   ? $o["dbport"]   : "");
        printf("dbsocket\t%s\n", isset($o["dbsocket"]) ? $o["dbsocket"] : "");
        printf("prefix\t%s\n",   $g("prefix"));
    ' "$cfg" 2>/dev/null
}

# Resolve DB creds + prefix from config.php into module globals + a 0600 option
# file. Fail-closed if creds or $CFG->prefix are missing (never guess 'mdl_').
_moodle_init_db_access() {
    local site_dir="$1"
    local creds
    creds=$(_moodle_read_config "$site_dir") || return 1
    local db user pass host port sock prefix
    db=$(awk   -F'\t' '$1=="dbname"{print $2}'   <<<"$creds")
    user=$(awk -F'\t' '$1=="dbuser"{print $2}'   <<<"$creds")
    pass=$(awk -F'\t' '$1=="dbpass"{print $2}'   <<<"$creds")
    host=$(awk -F'\t' '$1=="dbhost"{print $2}'   <<<"$creds")
    port=$(awk -F'\t' '$1=="dbport"{print $2}'   <<<"$creds")
    sock=$(awk -F'\t' '$1=="dbsocket"{print $2}' <<<"$creds")
    prefix=$(awk -F'\t' '$1=="prefix"{print $2}' <<<"$creds")

    [ -n "$db" ] && [ -n "$user" ] || { log_error "incomplete DB credentials from config.php"; return 1; }
    # The prefix is configurable; refusing to guess 'mdl_' is fail-closed — a
    # wrong prefix would silently anonymise nothing.
    [ -n "$prefix" ] || { log_error "\$CFG->prefix is empty in config.php (refusing to assume 'mdl_')"; return 1; }
    # Defense-in-depth: the prefix becomes a backticked SQL identifier for every
    # table. config.php is operator-controlled (trusted), but a stray backtick/
    # space would be an identifier-injection foothold — refuse anything but the
    # Moodle-legal charset. Fail-closed.
    [[ "$prefix" =~ ^[A-Za-z0-9_]+$ ]] || { log_error "\$CFG->prefix '${prefix}' has unexpected characters — refusing (identifier-injection guard)"; return 1; }
    # Same guard for the DB name: it becomes `${db}_sanitize_scratch` (a backticked
    # identifier) and a `table_schema='...'` literal. Same trust level as prefix.
    [[ "$db" =~ ^[A-Za-z0-9_]+$ ]] || { log_error "\$CFG->dbname '${db}' has unexpected characters — refusing (identifier-injection guard)"; return 1; }

    LIVE_DB="$db"; PREFIX="$prefix"
    SCRATCH_DB="${db}${SCRATCH_SUFFIX}"
    MYSQL_CNF="$(mktemp)"; chmod 600 "$MYSQL_CNF"
    {
        echo "[client]"
        echo "user=${user}"
        echo "password=${pass}"
        [ -n "$host" ] && echo "host=${host}"
        [ -n "$port" ] && echo "port=${port}"
        [ -n "$sock" ] && echo "socket=${sock}"
    } > "$MYSQL_CNF"
    log "resolved Moodle DB '${LIVE_DB}', table prefix '${PREFIX}'"
    return 0
}

# Dump live (read-only) → throwaway scratch DB. All mutations run on scratch.
_moodle_build_scratch() {
    LIVE_DUMP="$(mktemp --suffix=.sql.gz)"
    log "dumping live Moodle DB (read-only) → scratch copy"
    mysqldump --defaults-extra-file="$MYSQL_CNF" --no-tablespaces --single-transaction \
        --skip-lock-tables --quick "$LIVE_DB" 2>/dev/null | gzip > "$LIVE_DUMP" \
        || { log_error "live dump failed"; return 1; }
    mysql_cli -e "DROP DATABASE IF EXISTS \`${SCRATCH_DB}\`; CREATE DATABASE \`${SCRATCH_DB}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;" \
        || { log_error "scratch create failed (DB user needs CREATE on ${SCRATCH_DB})"; return 1; }
    zcat "$LIVE_DUMP" | mysql_cli "$SCRATCH_DB" || { log_error "scratch load failed"; return 1; }
    return 0
}

_moodle_table_exists() {
    [ -n "$(sq "SELECT 1 FROM information_schema.tables WHERE table_schema='${SCRATCH_DB}' AND table_name='$1' LIMIT 1;")" ]
}

_moodle_column_exists() { # $1 table  $2 column
    [ -n "$(sq "SELECT 1 FROM information_schema.columns WHERE table_schema='${SCRATCH_DB}' AND table_name='$1' AND column_name='$2' LIMIT 1;")" ]
}

_moodle_truncate_if_exists() {
    if _moodle_table_exists "$1"; then
        log "  truncate $1"
        sq "TRUNCATE \`$1\`;" || { log_error "truncate $1 failed"; return 1; }
    fi
    return 0
}

# Deterministically rewrite an email-bearing column via the SHARED OIDC rule.
# Only rows whose value is email-shaped (contains '@') are touched; the row key
# is the integer `id` PK (validated). Table/column absence is a no-op (return 0).
#   $1 table   $2 column   [$3 extra WHERE clause]
_moodle_oidc_rewrite_column() {
    local t="$1" c="$2" extra="${3:-}"
    _moodle_table_exists "$t"       || return 0
    _moodle_column_exists "$t" "$c" || return 0
    local where="\`${c}\` IS NOT NULL AND \`${c}\` LIKE '%@%'"
    [ -n "$extra" ] && where="${where} AND ${extra}"
    local rows sqlfile id val fake
    rows=$(sq "SELECT id, \`${c}\` FROM \`${t}\` WHERE ${where};")
    sqlfile="$(mktemp)"
    while IFS=$'\t' read -r id val; do
        [ -n "$id" ] || continue
        [[ "$id" =~ ^[0-9]+$ ]] || { log_error "non-numeric id from ${t}.${c} — refusing (fail-closed)"; rm -f "$sqlfile"; return 1; }
        fake=$(oidc_email_sanitize "$val") || { log_error "oidc rewrite failed on ${t}.${c}"; rm -f "$sqlfile"; return 1; }
        [ -n "$fake" ] || continue
        printf "UPDATE \`%s\` SET \`%s\`='%s' WHERE id=%s;\n" "$t" "$c" "$fake" "$id" >> "$sqlfile"
    done <<< "$rows"
    if [ -s "$sqlfile" ]; then
        mysql_cli "$SCRATCH_DB" < "$sqlfile" || { log_error "apply oidc rewrite ${t}.${c} failed"; rm -f "$sqlfile"; return 1; }
    fi
    rm -f "$sqlfile"
    return 0
}

# Anonymise the core PII surface: <prefix>user (+ user_info_data via truncate).
_moodle_anonymise_users() {
    local ut="${PREFIX}user"
    _moodle_table_exists "$ut" || { log_error "table ${ut} not found — is \$CFG->prefix correct?"; return 1; }

    # 1. Non-email identity columns → deterministic, PII-free values. Built only
    #    from columns that actually exist (Moodle schema drifts across versions).
    declare -A scrub=(
        [firstname]="CONCAT('First', id)"
        [lastname]="CONCAT('User', id)"
        [idnumber]="''"
        [phone1]="''"
        [phone2]="''"
        [institution]="''"
        [department]="''"
        [address]="''"
        [city]="''"
        [lastip]="'0.0.0.0'"
        [secret]="''"
        [description]="''"
        [imagealt]="''"
        [lastnamephonetic]="''"
        [firstnamephonetic]="''"
        [middlename]="''"
        [alternatename]="''"
        [moodlenetprofile]="''"
        [url]="''"
        [password]="'not cached'"
    )
    local existing col set_clause=""
    existing=$(sq "SELECT column_name FROM information_schema.columns WHERE table_schema='${SCRATCH_DB}' AND table_name='${ut}';")
    while IFS= read -r col; do
        [ -n "$col" ] || continue
        if [ -n "${scrub[$col]:-}" ]; then
            [ -n "$set_clause" ] && set_clause+=", "
            set_clause+="\`$col\`=${scrub[$col]}"
        fi
    done <<< "$existing"
    if [ -n "$set_clause" ]; then
        sq "UPDATE \`${ut}\` SET ${set_clause} WHERE ${USER_SCRUB_WHERE};" \
            || { log_error "user identity anonymisation failed"; return 1; }
    fi

    # 2. Emails (scrub floor) → deterministic OIDC fake (preserves the AVC↔SS join).
    _moodle_oidc_rewrite_column "$ut" "email" "${USER_SCRUB_WHERE}" || return 1
    # Any malformed non-'@' residue → a safe example.com placeholder.
    sq "UPDATE \`${ut}\` SET email=CONCAT('user', id, '@example.com') WHERE ${USER_SCRUB_WHERE} AND email <> '' AND email NOT LIKE '%@%';" \
        || { log_error "residual-email cleanup failed"; return 1; }

    # 3. Usernames: email-shaped → OIDC (keeps the join when username IS the
    #    email); everything else not-yet-sanitized → deterministic user<id>.
    _moodle_oidc_rewrite_column "$ut" "username" "${USER_SCRUB_WHERE}" || return 1
    sq "UPDATE \`${ut}\` SET username=CONCAT('user', id) WHERE ${USER_SCRUB_WHERE} AND username NOT LIKE '%@sanitized.test';" \
        || { log_error "username anonymisation failed"; return 1; }

    # 4. Guest (id=1): tidy any stray email/idnumber (not real PII, but clean).
    sq "UPDATE \`${ut}\` SET email='', idnumber='' WHERE id = 1;" 2>/dev/null || true
    return 0
}

# Preserve the OIDC linkage table but strip its PII: the external subject email
# / username go through the SAME shared-salt rule as <prefix>user.email, so the
# AVC↔SS dev join still resolves. Tokens are cleared.
_moodle_anonymise_oauth_links() {
    local t="${PREFIX}auth_oauth2_linked_login"
    _moodle_table_exists "$t" || { log "  (${t} absent — no OIDC linkage to anonymise)"; return 0; }
    log "anonymising OIDC linked-login identity (preserving the AVC↔SS join)"
    _moodle_oidc_rewrite_column "$t" "email"    || return 1
    _moodle_oidc_rewrite_column "$t" "username" || return 1
    _moodle_column_exists "$t" "confirmtoken" && \
        { sq "UPDATE \`${t}\` SET confirmtoken='' WHERE confirmtoken IS NOT NULL;" || return 1; }
    return 0
}

# Loginability restore (independent review 2026-07-11): anonymising the admin sets
# its password to 'not cached' + a fake email, which on a manual-auth staging site
# leaves NO usable admin login. Zero-secret fix: set the primary site admin back to
# auth='manual' on the SCRATCH copy so the operator can `admin/cli/reset_password.php`
# after load. Identity stays anonymised (no PII regression; the sweep still passes).
# The primary admin uid comes from <prefix>config `siteadmins` (a comma-list, can be
# non-2/multiple), fallback 2. Guest (id=1) is untouched.
_moodle_restore_dev_admin() {
    local cfg="${PREFIX}config"
    local admin_uid=""
    if _moodle_table_exists "$cfg"; then
        local list
        list=$(sq "SELECT value FROM \`${cfg}\` WHERE name='siteadmins' LIMIT 1;")
        admin_uid="${list%%,*}"           # first uid in the comma list
    fi
    [[ "$admin_uid" =~ ^[0-9]+$ ]] || admin_uid=2   # Moodle default primary admin
    _moodle_column_exists "${PREFIX}user" "auth" || return 0
    sq "UPDATE \`${PREFIX}user\` SET auth='manual' WHERE id=${admin_uid} AND deleted=0;" \
        || { log_error "could not restore admin loginability on scratch"; return 1; }
    log "admin loginability: uid ${admin_uid} set auth='manual' (identity stays anonymised)."
    log "  → after loading this dump on staging, run: php admin/cli/reset_password.php"
    return 0
}

# Consent (tool_policy_acceptances) — handled EXPLICITLY, never silently dropped
# (ADR-0031 D5). The anonymised fixture users never accepted any policy, so the
# per-user acceptance rows are TRUNCATED and the action is logged. The policy
# DEFINITIONS (<prefix>tool_policy / <prefix>tool_policy_versions) are site
# config, not PII, and are KEPT so the staging site still has its policy set.
_moodle_handle_consent() {
    local t="${PREFIX}tool_policy_acceptances"
    if _moodle_table_exists "$t"; then
        local n
        n=$(sq "SELECT COUNT(*) FROM \`${t}\`;")
        log "consent: ${t} holds ${n} real-user acceptance row(s) → TRUNCATE (fixture users never consented)."
        log "consent: policy definitions in ${PREFIX}tool_policy / ${PREFIX}tool_policy_versions are KEPT (site config, not PII)."
        sq "TRUNCATE \`${t}\`;" || { log_error "consent acceptance truncate failed"; return 1; }
        n=$(sq "SELECT COUNT(*) FROM \`${t}\`;")
        [ "$n" = "0" ] || { log_error "consent post-condition FAIL: ${n} acceptance row(s) remain"; return 1; }
    else
        log "consent: ${t} not present — nothing to handle"
    fi
    return 0
}

# POST-CONDITION (fail-closed): zero <prefix>user rows (id>1) may retain a real
# email, real username, or idnumber. A non-numeric count (query failed) is also
# a failure. Callable standalone so it can be unit-tested against a scratch DB.
_moodle_assert_no_pii() {
    local ut="${PREFIX}user" bad
    # Emails: must be @sanitized.test (OIDC rule) or an @example.* placeholder.
    bad=$(sq "SELECT COUNT(*) FROM \`${ut}\` WHERE id>1 AND email<>'' AND email NOT LIKE '%@sanitized.test' AND email NOT LIKE '%@example.%';")
    [[ "$bad" =~ ^[0-9]+$ ]] || { log_error "post-condition email query failed — fail-closed"; return 1; }
    [ "$bad" = "0" ] || { log_error "post-condition FAIL: ${bad} user row(s) retain a non-sanitized email"; return 1; }
    # Usernames: must be user<n> or the @sanitized.test OIDC form.
    bad=$(sq "SELECT COUNT(*) FROM \`${ut}\` WHERE id>1 AND username<>'' AND username NOT LIKE '%@sanitized.test' AND username NOT REGEXP '^user[0-9]+\$';")
    [[ "$bad" =~ ^[0-9]+$ ]] || { log_error "post-condition username query failed — fail-closed"; return 1; }
    [ "$bad" = "0" ] || { log_error "post-condition FAIL: ${bad} user row(s) retain a non-sanitized username"; return 1; }
    # idnumber (external student id): must be blank for id>1.
    bad=$(sq "SELECT COUNT(*) FROM \`${ut}\` WHERE id>1 AND idnumber<>'';")
    [[ "$bad" =~ ^[0-9]+$ ]] || { log_error "post-condition idnumber query failed — fail-closed"; return 1; }
    [ "$bad" = "0" ] || { log_error "post-condition FAIL: ${bad} user row(s) retain an idnumber"; return 1; }
    log "post-condition: 0 residual real email / username / idnumber for id>1"
    return 0
}

# Orchestrator. Reads config.php → scratch → anonymise → truncate volatile +
# learning-attempt free-text → consent → post-condition → export → PII sweep.
moodle_sanitize() {
    local site_dir="${1:-$SITE_DIR}"
    [ -n "$site_dir" ] || { log_error "--site-dir DIR is required"; return 2; }
    # version.php confirms this is a Moodle root (not a Drupal site handed to us).
    [ -f "$site_dir/version.php" ] || {
        log_error "not a Moodle root (version.php missing): $site_dir — refusing (fail-closed)"; return 1; }

    _moodle_init_db_access "$site_dir" || return 1
    # PROD GUARD (ops#113): never mutate the live DB — scratch must be distinct.
    prod_guard_scratch_distinct "$LIVE_DB" "$SCRATCH_DB" "$SCRATCH_SUFFIX" || return 1
    _moodle_build_scratch || return 1

    # ops#127 --preserve-admin (DR): keep the real siteadmins untouched, scrub the
    # rest. Resolve the siteadmins CSV from <prefix>config (validated: digits+commas
    # only — it flows into an `IN (...)` clause), widen the scrub floor to exclude
    # them, and capture their real emails so pii_sweep can allowlist exactly those.
    if [ "$PRESERVE_ADMIN" = true ]; then
        local _cfg="${PREFIX}config" _sa=""
        _moodle_table_exists "$_cfg" && _sa=$(sq "SELECT value FROM \`${_cfg}\` WHERE name='siteadmins' LIMIT 1;")
        [[ "$_sa" =~ ^[0-9]+(,[0-9]+)*$ ]] || { log_error "--preserve-admin: no valid siteadmins list ('${_sa}') — refusing (fail-closed)"; return 1; }
        USER_SCRUB_WHERE="id > 1 AND id NOT IN (${_sa})"
        PRESERVE_ADMIN_MAILS=$(sq "SELECT email FROM \`${PREFIX}user\` WHERE id IN (${_sa}) AND email LIKE '%@%';")
        log "preserve-admin: siteadmins {${_sa}} retained; scrub floor = ${USER_SCRUB_WHERE}"
    fi

    log "anonymising ${PREFIX}user (identity + OIDC emails, ${USER_SCRUB_WHERE}) and OIDC linkage"
    _moodle_anonymise_users || return 1
    _moodle_anonymise_oauth_links || return 1
    if [ "$PRESERVE_ADMIN" = true ]; then
        log "preserve-admin: real siteadmins kept intact (skipping dev-admin restore)"
    else
        _moodle_restore_dev_admin || return 1
    fi

    # Volatile / log / message / token / free-text-profile tables → TRUNCATE.
    # Names are enumerated (not pattern-matched) so we never blow away messaging
    # CONFIG tables (message_processors / message_providers).
    log "truncating volatile / log / message / token / profile-free-text tables"
    local t
    for t in sessions logstore_standard_log log events_queue \
             user_password_history user_password_resets user_devices \
             external_tokens user_private_key \
             user_preferences user_lastaccess user_info_data \
             messages message message_read message_contacts message_conversations \
             message_conversation_members message_conversation_actions \
             message_user_actions message_popup message_popup_notifications \
             notifications; do
        _moodle_truncate_if_exists "${PREFIX}${t}" || return 1
    done

    # Free-text student CONTENT + learning-attempt tables (plane 5b PII) → TRUNCATE.
    # These carry names/emails/opinions a student TYPED, which the user-table
    # anonymisation never reaches — leaving them would ship real PII in a dump the
    # sanitizer claims is clean. (Independent security review 2026-07-11 + GDPR
    # data-minimisation: a dev/preview fixture needs valid rows, not content.)
    log "truncating free-text content + learning-attempt tables (plane 5b PII)"
    for t in quiz_attempts question_attempts question_attempt_steps \
             question_attempt_step_data lesson_attempts \
             assign_submission assignsubmission_onlinetext assignsubmission_file \
             scorm_scoes_track \
             forum_posts forum_discussions \
             data_content glossary_entries \
             wiki_pages wiki_versions book_chapters \
             comments assignfeedback_comments \
             post feedback_value feedback_valuetmp survey_answers \
             chat_messages workshop_submissions workshop_assessments; do
        _moodle_truncate_if_exists "${PREFIX}${t}" || return 1
    done

    # Numeric attainment (grades / completions / badges). RETENTION-POLICY DIAL:
    # <prefix>user email is rewritten with a DELIBERATELY re-linkable shared salt,
    # so kept grades are pseudonymous — under GDPR still personal data, and
    # singling-out survives in tiny cohorts. A dev/preview copy needs valid rows,
    # not real marks (cf. Moodle local_datacleaner, which fakes/drops them). Also
    # fixes the prior inconsistency (quiz_attempts truncated but quiz_grades kept).
    # DEFAULT = TRUNCATE; to keep realistic marks, delete this loop.
    log "truncating numeric attainment (grades/completions/badges) — retention dial"
    for t in grade_grades grade_grades_history \
             quiz_grades assign_grades \
             course_completions course_modules_completion \
             badge_issued; do
        _moodle_truncate_if_exists "${PREFIX}${t}" || return 1
    done

    # KEPT for fixture usability: user_enrolments / role_assignments / groups_members
    # (structure only; identity already severed). For MINORS, drop these too —
    # export NWP_MOODLE_SANITIZE_MINORS=true.
    if [ "${NWP_MOODLE_SANITIZE_MINORS:-false}" = "true" ]; then
        log "minors mode: truncating enrolment / role / group membership too"
        for t in user_enrolments role_assignments groups_members; do
            _moodle_truncate_if_exists "${PREFIX}${t}" || return 1
        done
    fi

    _moodle_handle_consent || return 1

    log "asserting PII post-condition on scratch copy"
    _moodle_assert_no_pii || return 1

    log "exporting sanitized scratch copy → $OUTPUT"
    mkdir -p "$(dirname "$OUTPUT")"
    mysqldump --defaults-extra-file="$MYSQL_CNF" --no-tablespaces --single-transaction \
        --skip-lock-tables --quick "$SCRATCH_DB" 2>/dev/null | gzip > "$OUTPUT" \
        || { log_error "sanitized export failed"; return 1; }
    [ -s "$OUTPUT" ] || { log_error "sanitized dump is empty"; return 1; }

    # ops#127: emit preserved siteadmin emails as an allowlist SIDECAR for the
    # caller's external lib/pii-gate.sh (defence-in-depth; fail-closed elsewhere).
    if [ "$PRESERVE_ADMIN" = true ] && [ -n "$PRESERVE_ADMIN_MAILS" ]; then
        printf '%s\n' "$PRESERVE_ADMIN_MAILS" | grep -E '.@.' > "${OUTPUT}.admin-allow" || true
        log "wrote admin-allow sidecar → ${OUTPUT}.admin-allow"
    fi

    pii_sweep "$OUTPUT" || { log_error "built-in PII sweep found residue — refusing to hand off"; return 1; }

    # moodledata is a SEPARATE surface (not in the DB): user/private files,
    # profile pictures under filedir, sessions/, temp/, trashdir/. This SQL pass
    # does NOT touch it. A Moodle backup is not "sanitized" until a sibling step
    # scrubs/omits moodledata (ADR-0031 D8). Documented, explicit deferral.
    log "NOTE: moodledata file-scrub (user/private files, filedir profile pics,"
    log "      sessions/temp/trashdir) is OUT OF SCOPE for this SQL pass and MUST be"
    log "      handled by a sibling step before this backup is treated as sanitized."
    log "done: $OUTPUT"
    return 0
}

# ── main (guarded so the file can be sourced by unit tests without executing) ──
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    [ -n "$SITE_DIR" ] || { log_error "--site-dir DIR is required"; exit 2; }
    trap _moodle_cleanup EXIT
    moodle_sanitize "$SITE_DIR"
    exit $?
fi
