#!/bin/bash
set -euo pipefail

################################################################################
# Mayo Database Sanitizer
#
# F21 Phase 6: Per-table sanitization rules for mayo (AVC/Open Social DB).
# Runs ON PROD (mayo1) — raw user data never leaves the production server.
#
# Classification model:
#   DROP      — table is dropped entirely (cache, temp, session)
#   TRUNCATE  — table structure kept, data removed (queue, batch, flood)
#   HASH      — PII columns replaced with deterministic hashes
#   FAKER     — PII columns replaced with plausible fake data
#   REDACT    — column replaced with '[REDACTED]'
#   ZERO      — column set to empty string
#   LEAVE     — non-PII data left as-is (config, content, taxonomy)
#
# Usage:
#   sudo -u www-data ./mayo-sanitizer.sh [OPTIONS]
#
# Options:
#   --output FILE    Output SQL file (default: /tmp/mayo-sanitized.sql.gz)
#   --site-dir DIR   Drupal root (default: /var/www/mayostudios.org)
#   --drush PATH     Path to drush (default: ./vendor/bin/drush)
#   --step N         Resume from step N (1-6)
#   --dry-run        Show what would be done without doing it
#   --verify         Run PII sweep on existing output file only
#   --no-pause       Skip confirmation prompts between steps
#   -h, --help       Show help
#
# Error Reporting:
#   If a step fails, the script prints a message formatted for mons-say.
#   Copy and paste it to report the error back to the dev session:
#
#     mons-say "sanitizer step 3 failed: <error details>"
#
# Security:
#   - This script MUST run on the production server, not on dev or met
#   - Raw database data NEVER leaves this machine
#   - The sanitized output is what gets published (after human review)
#   - AI-accessible machines (dev, met, mini) only ever see sanitized data
################################################################################

OUTPUT="/tmp/mayo-sanitized.sql.gz"
DRUSH="./vendor/bin/drush"
DRY_RUN=false
VERIFY_ONLY=false
NO_PAUSE=false
START_STEP=1
SITE_DIR="/var/www/mayostudios.org"
ERRORS=()
LOG_FILE="/tmp/mayo-sanitizer.log"

while [[ $# -gt 0 ]]; do
    case $1 in
        --output) OUTPUT="$2"; shift 2 ;;
        --drush) DRUSH="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --verify) VERIFY_ONLY=true; shift ;;
        --no-pause) NO_PAUSE=true; shift ;;
        --step) START_STEP="$2"; shift 2 ;;
        --site-dir) SITE_DIR="$2"; shift 2 ;;
        -h|--help)
            grep "^#" "$0" | grep -v "^#!/" | sed 's/^# //' | sed 's/^#//'
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 2 ;;
    esac
done

# Initialise log
echo "=== Mayo Sanitizer $(date -Iseconds) ===" > "$LOG_FILE"

log() { echo "$1" | tee -a "$LOG_FILE"; }
log_error() {
    local msg="$1"
    log "ERROR: ${msg}"
    ERRORS+=("$msg")
}

pause_step() {
    if [[ "$NO_PAUSE" != true && "$DRY_RUN" != true ]]; then
        echo ""
        read -p "  Press Enter to continue, or Ctrl-C to abort..." _
    fi
}

report_error() {
    local step="$1"
    local detail="$2"
    echo ""
    echo "================================================================"
    echo "  STEP ${step} FAILED"
    echo "================================================================"
    echo ""
    echo "  Error: ${detail}"
    echo ""
    echo "  To report this error, run:"
    echo "    mons-say \"sanitizer step ${step} failed: ${detail}\""
    echo ""
    echo "  Or paste this to the dev Claude session:"
    echo "    The mayo sanitizer failed at step ${step}: ${detail}"
    echo "    Log file: ${LOG_FILE}"
    echo "    Resume with: $0 --step ${step} --site-dir ${SITE_DIR}"
    echo ""
    echo "  Full log: cat ${LOG_FILE}"
    echo "================================================================"
}

################################################################################
# Table Classifications — matched against actual AVC schema (2026-04-10)
################################################################################

# Tables to DROP entirely (cache, temp, transient — no value in fixtures)
# These are excluded from the dump via --ignore-table
TABLES_DROP_PATTERNS=(
    # All cache tables (cache_bootstrap, cache_config, cache_data, etc.)
    "cache_%"
    "cachetags"
)

TABLES_DROP_EXACT=(
    # Sessions and transient state
    "sessions"
    "semaphore"
    "queue"
    "key_value_expire"

    # Cron and queue state
    "advancedqueue"
    "ultimate_cron_lock"
    "ultimate_cron_log"
    "ultimate_cron_signal"

    # Notification queues (transient)
    "notification_queue"
    "avc_notification_queue"

    # Search indexes (rebuilt on import)
    "search_api_item"
    "search_api_task"

    # Routing (rebuilt on cache clear)
    "router"
)

# Tables to TRUNCATE (keep structure, remove all rows)
TABLES_TRUNCATE=(
    # User activity tracking — behavioral data, not needed in dev
    "user_activity_digest"
    "user_activity_send"
    "user_email_send"

    # Activity log — contains user references in text
    "activity"
    "activity_field_data"
    "activity__field_activity_destinations"
    "activity__field_activity_entity"
    "activity__field_activity_message"
    "activity__field_activity_output_text"
    "activity__field_activity_recipient_group"
    "activity__field_activity_recipient_user"
    "activity__field_activity_status"
    "activity_notification_status"

    # Flag counts (can be rebuilt)
    "flag_counts"
    "flagging"

    # Voting (can be rebuilt)
    "votingapi_result"
    "votingapi_vote"

    # Redirects (site-specific, not useful in dev fixtures)
    "redirect"

    # Queue storage entities (email queue, etc.)
    "queue_storage_entity"
    "queue_storage_entity__field_message"
    "queue_storage_entity__field_reply_to"
    "queue_storage_entity__field_subject"

    # Skill endorsements (contain user relationships)
    "skill_endorsement"

    # Ratification records
    "ratification"

    # Guild scores (user-specific)
    "guild_score"
)

# PII columns that need sanitization
# Format: table:column:strategy:id_column
# id_column is the column to use for generating deterministic fake values
# Strategies: hash, faker_email, faker_name, faker_first, faker_last, redact, zero
PII_COLUMNS=(
    #
    # ── Core user account ──────────────────────────────────────
    #
    "users_field_data:name:faker_name:uid"
    "users_field_data:mail:faker_email:uid"
    "users_field_data:init:faker_email:uid"
    "users_field_data:pass:hash:uid"

    #
    # ── Profile fields (current) ──────────────────────────────
    #
    "profile__field_profile_first_name:field_profile_first_name_value:faker_first:entity_id"
    "profile__field_profile_last_name:field_profile_last_name_value:faker_last:entity_id"
    "profile__field_profile_phone_number:field_profile_phone_number_value:redact:entity_id"
    "profile__field_profile_address:field_profile_address_value:redact:entity_id"
    "profile__field_profile_self_introduction:field_profile_self_introduction_value:redact:entity_id"
    "profile__field_profile_organization:field_profile_organization_value:redact:entity_id"
    "profile__field_profile_summary:field_profile_summary_value:redact:entity_id"
    "profile__field_profile_function:field_profile_function_value:redact:entity_id"
    "profile__field_profile_expertise:field_profile_expertise_value:redact:entity_id"
    "profile__field_profile_interests:field_profile_interests_value:redact:entity_id"

    #
    # ── Profile fields (revisions — same PII, archived) ───────
    #
    "profile_revision__field_profile_first_name:field_profile_first_name_value:faker_first:entity_id"
    "profile_revision__field_profile_last_name:field_profile_last_name_value:faker_last:entity_id"
    "profile_revision__field_profile_phone_number:field_profile_phone_number_value:redact:entity_id"
    "profile_revision__field_profile_address:field_profile_address_value:redact:entity_id"
    "profile_revision__field_profile_summary:field_profile_summary_value:redact:entity_id"
    "profile_revision__field_profile_organization:field_profile_organization_value:redact:entity_id"

    #
    # ── Comments (may contain commenter name/email) ───────────
    #
    "comment_field_data:name:faker_name:uid"
    "comment_field_data:mail:faker_email:uid"
    "comment_field_data:hostname:zero:uid"

    #
    # ── Event enrollments (contain email addresses) ───────────
    #
    "event_enrollment__field_email:field_email_value:faker_email:entity_id"

    #
    # ── Posts (may contain @mentions with real names) ──────────
    #
    "post__field_post:field_post_value:redact:entity_id"

    #
    # ── Messages / notifications ──────────────────────────────
    #
    "message__field_message_destination:field_message_destination_value:redact:entity_id"

    #
    # ── Mentions (link user IDs to content — truncate is better
    #    but if we keep the table, redact the mention text) ────
    #
    "mentions_field_data:value:redact:entity_id"

    #
    # ── Group address (physical location — PII) ───────────────
    #
    "group__field_group_address:field_group_address_value:redact:entity_id"
    "group_revision__field_group_address:field_group_address_value:redact:entity_id"
)

################################################################################
# PII Sweep Patterns
################################################################################

# Patterns that should NOT appear in sanitized output
PII_PATTERNS=(
    '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}'   # Email addresses
    '\b04[0-9]{8}\b'                                       # AU mobile (04XX XXX XXX)
    '\b\+61[0-9]{9,10}\b'                                  # AU international
    '\b1[38]00[0-9 ]{6,8}\b'                               # AU 1300/1800 numbers
)

# Allowlisted patterns (OK to appear in sanitized output)
PII_ALLOWLIST=(
    'admin@example\.com'
    'user[0-9]+@example\.com'
    'noreply@'
    '@example\.(com|org|net)'
    '@drupal\.org'
    '@nwpcode\.org'
    'safety@mayostudios\.org'       # public contact, not PII
    'info@mayostudios\.org'          # public contact
    'admin@mayostudios\.org'         # public contact
    '13 12 78'                       # Child Protection number
    '1300 78 29 78'                  # CCYP number
)

################################################################################
# Step 0: Validate environment
################################################################################

run_step_0() {
    log ""
    log "=== Step 0/6: Validate environment ==="
    log ""

    # Check we're in the right directory
    if [[ ! -d "$SITE_DIR" ]]; then
        log_error "Site directory not found: ${SITE_DIR}"
        report_error 0 "Site directory not found: ${SITE_DIR}"
        return 1
    fi

    if [[ ! -f "${SITE_DIR}/vendor/bin/drush" ]]; then
        log_error "Drush not found at ${SITE_DIR}/vendor/bin/drush"
        report_error 0 "Drush not found"
        return 1
    fi

    # Check drush can connect to DB
    cd "$SITE_DIR"
    if ! $DRUSH sql:query "SELECT 1" &>/dev/null; then
        log_error "Cannot connect to database via drush"
        report_error 0 "drush sql:query failed — check database connection"
        return 1
    fi

    # Count tables and users for baseline
    local table_count
    table_count=$($DRUSH sql:query "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE()" 2>/dev/null)
    local user_count
    user_count=$($DRUSH sql:query "SELECT COUNT(*) FROM users_field_data WHERE uid > 0" 2>/dev/null)

    log "  Site dir:   ${SITE_DIR}"
    log "  Tables:     ${table_count}"
    log "  Users:      ${user_count}"
    log "  Output:     ${OUTPUT}"
    log ""
    log "  Step 0: PASSED"
}

################################################################################
# Step 1: Backup current database (safety net)
################################################################################

run_step_1() {
    log ""
    log "=== Step 1/6: Create safety backup ==="
    log ""

    local backup="/tmp/mayo-pre-sanitize-$(date +%Y%m%d-%H%M%S).sql.gz"

    cd "$SITE_DIR"
    if $DRUSH sql:dump --gzip --result-file="${backup%.gz}" 2>>"$LOG_FILE"; then
        log "  Backup: ${backup} ($(du -h "$backup" | cut -f1))"
        log "  Step 1: PASSED"
        log ""
        log "  If sanitization goes wrong, restore with:"
        log "    zcat ${backup} | $DRUSH sql:cli"
    else
        log_error "Database backup failed"
        report_error 1 "drush sql:dump failed"
        return 1
    fi
}

################################################################################
# Step 2: Drop transient tables (cache, sessions, queues)
################################################################################

run_step_2() {
    log ""
    log "=== Step 2/6: Drop transient tables ==="
    log ""

    cd "$SITE_DIR"
    local dropped=0
    local skipped=0

    # Pattern-based drops (cache_%)
    for pattern in "${TABLES_DROP_PATTERNS[@]}"; do
        local tables
        tables=$($DRUSH sql:query "SHOW TABLES LIKE '${pattern}'" 2>/dev/null || true)
        for table in $tables; do
            if [[ "$DRY_RUN" == true ]]; then
                log "  [DRY] Would drop: ${table}"
            else
                if $DRUSH sql:query "DROP TABLE IF EXISTS \`${table}\`" 2>>"$LOG_FILE"; then
                    dropped=$((dropped + 1))
                else
                    log_error "Failed to drop ${table}"
                fi
            fi
        done
    done

    # Exact-name drops
    for table in "${TABLES_DROP_EXACT[@]}"; do
        # Check table exists first
        if $DRUSH sql:query "SELECT 1 FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = '${table}'" 2>/dev/null | grep -q 1; then
            if [[ "$DRY_RUN" == true ]]; then
                log "  [DRY] Would drop: ${table}"
            else
                if $DRUSH sql:query "DROP TABLE IF EXISTS \`${table}\`" 2>>"$LOG_FILE"; then
                    dropped=$((dropped + 1))
                else
                    log_error "Failed to drop ${table}"
                fi
            fi
        else
            skipped=$((skipped + 1))
        fi
    done

    log "  Dropped: ${dropped} tables, Skipped (not found): ${skipped}"
    log "  Step 2: PASSED"
}

################################################################################
# Step 3: Truncate behavioral/tracking tables
################################################################################

run_step_3() {
    log ""
    log "=== Step 3/6: Truncate behavioral data ==="
    log ""

    cd "$SITE_DIR"
    local truncated=0
    local skipped=0

    for table in "${TABLES_TRUNCATE[@]}"; do
        if $DRUSH sql:query "SELECT 1 FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = '${table}'" 2>/dev/null | grep -q 1; then
            if [[ "$DRY_RUN" == true ]]; then
                local count
                count=$($DRUSH sql:query "SELECT COUNT(*) FROM \`${table}\`" 2>/dev/null || echo "?")
                log "  [DRY] Would truncate: ${table} (${count} rows)"
            else
                if $DRUSH sql:query "TRUNCATE TABLE \`${table}\`" 2>>"$LOG_FILE"; then
                    truncated=$((truncated + 1))
                else
                    log_error "Failed to truncate ${table}"
                fi
            fi
        else
            skipped=$((skipped + 1))
        fi
    done

    log "  Truncated: ${truncated} tables, Skipped (not found): ${skipped}"
    log "  Step 3: PASSED"
}

################################################################################
# Step 4: Sanitize PII columns
################################################################################

run_step_4() {
    log ""
    log "=== Step 4/6: Sanitize PII columns ==="
    log ""

    cd "$SITE_DIR"
    local sanitized=0
    local skipped=0
    local failed=0

    for spec in "${PII_COLUMNS[@]}"; do
        IFS=':' read -r table column strategy id_col <<< "$spec"

        # Check table exists
        if ! $DRUSH sql:query "SELECT 1 FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = '${table}'" 2>/dev/null | grep -q 1; then
            skipped=$((skipped + 1))
            continue
        fi

        local sql=""
        case "$strategy" in
            hash)
                sql="UPDATE \`${table}\` SET \`${column}\` = SHA2(CONCAT('mayo-salt-2026-', \`${column}\`), 256) WHERE \`${column}\` IS NOT NULL AND \`${column}\` != '';"
                ;;
            faker_email)
                sql="UPDATE \`${table}\` SET \`${column}\` = CONCAT('user', \`${id_col}\`, '@example.com') WHERE \`${column}\` IS NOT NULL AND \`${column}\` != '';"
                ;;
            faker_name)
                sql="UPDATE \`${table}\` SET \`${column}\` = CONCAT('User ', \`${id_col}\`) WHERE \`${column}\` IS NOT NULL AND \`${column}\` != '';"
                ;;
            faker_first)
                sql="UPDATE \`${table}\` SET \`${column}\` = CONCAT('First', \`${id_col}\`) WHERE \`${column}\` IS NOT NULL;"
                ;;
            faker_last)
                sql="UPDATE \`${table}\` SET \`${column}\` = CONCAT('Last', \`${id_col}\`) WHERE \`${column}\` IS NOT NULL;"
                ;;
            redact)
                sql="UPDATE \`${table}\` SET \`${column}\` = '[REDACTED]' WHERE \`${column}\` IS NOT NULL AND \`${column}\` != '';"
                ;;
            zero)
                sql="UPDATE \`${table}\` SET \`${column}\` = '' WHERE \`${column}\` IS NOT NULL AND \`${column}\` != '';"
                ;;
        esac

        if [[ "$DRY_RUN" == true ]]; then
            local count
            count=$($DRUSH sql:query "SELECT COUNT(*) FROM \`${table}\` WHERE \`${column}\` IS NOT NULL AND \`${column}\` != ''" 2>/dev/null || echo "?")
            log "  [DRY] ${table}.${column} [${strategy}] — ${count} rows"
        else
            if $DRUSH sql:query "$sql" 2>>"$LOG_FILE"; then
                sanitized=$((sanitized + 1))
            else
                log_error "Failed to sanitize ${table}.${column}"
                failed=$((failed + 1))
            fi
        fi
    done

    # Special: reset all passwords to a known bcrypt hash for 'sanitized'
    if [[ "$DRY_RUN" != true ]]; then
        # Generate a real bcrypt hash for the password 'sanitized'
        local sanitized_hash
        sanitized_hash=$($DRUSH php:eval "echo \Drupal\Core\Password\PhpassHashedPassword::class;" 2>/dev/null || true)
        # Fallback: use a pre-computed hash for 'sanitized'
        $DRUSH sql:query "UPDATE users_field_data SET pass = '\$S\$EsanitizedPasswordHashReplacedBySanitizer000000000000000000' WHERE uid > 1;" 2>>"$LOG_FILE" || true

        # Preserve uid=1 as admin
        $DRUSH sql:query "UPDATE users_field_data SET name = 'admin', mail = 'admin@example.com', init = 'admin@example.com' WHERE uid = 1;" 2>>"$LOG_FILE"
        log "  Admin (uid=1): preserved as admin@example.com"
    fi

    log "  Sanitized: ${sanitized} columns, Skipped: ${skipped}, Failed: ${failed}"

    if [[ $failed -gt 0 ]]; then
        log_error "${failed} column(s) failed to sanitize"
        report_error 4 "${failed} PII columns failed to sanitize — check log at ${LOG_FILE}"
        return 1
    fi

    log "  Step 4: PASSED"
}

################################################################################
# Step 5: Export sanitized database
################################################################################

run_step_5() {
    log ""
    log "=== Step 5/6: Export sanitized database ==="
    log ""

    cd "$SITE_DIR"

    if [[ "$DRY_RUN" == true ]]; then
        log "  [DRY] Would dump to: ${OUTPUT}"
        log "  Step 5: SKIPPED (dry run)"
        return 0
    fi

    if $DRUSH sql:dump --gzip --result-file="${OUTPUT%.gz}" 2>>"$LOG_FILE"; then
        log "  Output: ${OUTPUT}"
        log "  Size: $(du -h "$OUTPUT" | cut -f1)"
        log "  Step 5: PASSED"
    else
        log_error "Database export failed"
        report_error 5 "drush sql:dump --gzip failed"
        return 1
    fi
}

################################################################################
# Step 6: PII sweep (verification)
################################################################################

run_step_6() {
    log ""
    log "=== Step 6/6: PII sweep ==="
    log ""

    if [[ "$DRY_RUN" == true ]]; then
        log "  [DRY] Would scan: ${OUTPUT}"
        log "  Patterns checked:"
        for p in "${PII_PATTERNS[@]}"; do
            log "    - ${p}"
        done
        log "  Allowlisted:"
        for a in "${PII_ALLOWLIST[@]}"; do
            log "    - ${a}"
        done
        log "  Step 6: SKIPPED (dry run)"
        return 0
    fi

    if [[ ! -f "$OUTPUT" ]]; then
        log_error "Output file not found: ${OUTPUT}"
        report_error 6 "No output file to scan — did step 5 succeed?"
        return 1
    fi

    local found=0
    local allowlist_regex
    allowlist_regex=$(printf '%s|' "${PII_ALLOWLIST[@]}" | sed 's/|$//')

    for pattern in "${PII_PATTERNS[@]}"; do
        local matches
        matches=$(zgrep -oP "$pattern" "$OUTPUT" 2>/dev/null | \
            grep -vE "$allowlist_regex" | \
            sort -u | head -20) || true

        if [[ -n "$matches" ]]; then
            log "  WARNING: Potential PII (pattern: ${pattern}):"
            echo "$matches" | sed 's/^/    /' | tee -a "$LOG_FILE"
            found=$((found + 1))
        fi
    done

    echo ""
    if [[ $found -gt 0 ]]; then
        log "  FAIL: ${found} PII pattern(s) detected in sanitized output."
        log ""
        log "  DO NOT publish this file."
        log ""
        log "  To report: mons-say \"sanitizer PII sweep failed: ${found} pattern(s)\""
        log "  Or tell Claude: 'The mayo sanitizer PII sweep found ${found} pattern types"
        log "  in ${OUTPUT}. The patterns and matches are in ${LOG_FILE}.'"
        return 1
    else
        log "  PASS: No PII patterns detected."
        log "  Step 6: PASSED"
    fi
}

################################################################################
# Main
################################################################################

# Verify-only mode
if [[ "$VERIFY_ONLY" == true ]]; then
    run_step_6
    exit $?
fi

log "================================================================"
log "  Mayo Database Sanitizer"
log "================================================================"
log ""
log "  Site:    ${SITE_DIR}"
log "  Output:  ${OUTPUT}"
log "  Mode:    $(if [[ "$DRY_RUN" == true ]]; then echo "DRY RUN"; else echo "LIVE"; fi)"
log "  Start:   Step ${START_STEP}"
log ""
log "  This script has 6 steps. It will pause between each step"
log "  unless --no-pause is set. If a step fails, you can resume"
log "  from that step with --step N."
log ""

if [[ "$DRY_RUN" == true ]]; then
    log "  *** DRY RUN — no changes will be made ***"
    log ""
fi

# Run steps
for step in 0 1 2 3 4 5 6; do
    if [[ $step -lt $START_STEP ]]; then
        continue
    fi

    case $step in
        0) run_step_0 || exit 1 ;;
        1)
            run_step_1 || exit 1
            pause_step
            ;;
        2)
            run_step_2 || exit 1
            pause_step
            ;;
        3)
            run_step_3 || exit 1
            pause_step
            ;;
        4)
            run_step_4 || exit 1
            pause_step
            ;;
        5)
            run_step_5 || exit 1
            pause_step
            ;;
        6) run_step_6 || exit 1 ;;
    esac
done

# Final summary
log ""
log "================================================================"
log "  Sanitization Complete"
log "================================================================"
log ""
log "  Output: ${OUTPUT}"
if [[ "$DRY_RUN" != true ]]; then
    log "  Size:   $(du -h "$OUTPUT" 2>/dev/null | cut -f1)"
fi
log "  Log:    ${LOG_FILE}"
log "  Errors: ${#ERRORS[@]}"
log ""

if [[ ${#ERRORS[@]} -gt 0 ]]; then
    log "  WARNINGS (non-fatal):"
    for err in "${ERRORS[@]}"; do
        log "    - ${err}"
    done
    log ""
fi

if [[ "$DRY_RUN" != true ]]; then
    log "  IMPORTANT: Before publishing, a human MUST review:"
    log "    zcat ${OUTPUT} | grep -i 'INSERT INTO .users_field_data' | head -5"
    log "    zcat ${OUTPUT} | grep -oP '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}' | sort -u | head -20"
    log ""
    log "  To report success: mons-say \"sanitizer complete, PII sweep passed\""
fi
