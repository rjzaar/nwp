#!/bin/bash

################################################################################
# NWP Database Sanitization Library
#
# Sanitize production data for development use (GDPR compliance)
# Source this file: source "$SCRIPT_DIR/lib/sanitize.sh"
#
# Dependencies: lib/ui.sh, lib/common.sh
################################################################################

# Default sanitization SQL commands
# NOTE: Password reset is now handled by sanitize_with_drush() with secure random passwords
# This SQL fallback anonymizes user data but does NOT reset passwords to a known value
# (that would be a security risk if the dump were exposed)
SANITIZE_SQL_USERS='
-- Sanitize user data (GDPR compliant)
UPDATE users_field_data
SET
    mail = CONCAT("user", uid, "@example.com"),
    init = CONCAT("user", uid, "@example.com"),
    name = CONCAT("user_", uid)
WHERE uid > 1;

-- SECURITY: Do NOT reset passwords to a known value in SQL dumps
-- Passwords are randomized by sanitize_with_drush() instead
-- If using SQL fallback, passwords remain as-is (still hashed, but original)
'

SANITIZE_SQL_SESSIONS='
-- Clear all sessions (force re-login)
TRUNCATE TABLE sessions;
'

SANITIZE_SQL_WATCHDOG='
-- Clear watchdog logs
TRUNCATE TABLE watchdog;
'

SANITIZE_SQL_CACHE='
-- Clear all cache tables
SET @tables = NULL;
SELECT GROUP_CONCAT(table_name) INTO @tables
FROM information_schema.tables
WHERE table_schema = DATABASE()
AND table_name LIKE "cache_%";

SET @sql = IF(@tables IS NOT NULL,
    CONCAT("TRUNCATE TABLE ", REPLACE(@tables, ",", "; TRUNCATE TABLE "), ";"),
    "SELECT 1");
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;
'

SANITIZE_SQL_WEBFORM='
-- Clear webform submissions (contains PII)
TRUNCATE TABLE webform_submission;
TRUNCATE TABLE webform_submission_data;
TRUNCATE TABLE webform_submission_log;
'

SANITIZE_SQL_COMMERCE='
-- Sanitize commerce data
UPDATE commerce_order
SET
    mail = CONCAT("order", order_id, "@example.com"),
    ip_address = "127.0.0.1";

UPDATE commerce_payment
SET
    remote_id = CONCAT("test_", payment_id);
'

# Generate a unique sanitized password per user
# Uses a deterministic but non-guessable format: sanitized_<uid>_<random>
generate_sanitized_password() {
    local uid="$1"
    # Generate 8 random alphanumeric chars
    local random_part=$(openssl rand -base64 12 | tr -d '/=+' | cut -c -8)
    echo "Sanitized${uid}_${random_part}"
}

# Run Drush sql-sanitize with secure random passwords
# Usage: sanitize_with_drush "/path/to/site"
sanitize_with_drush() {
    local site_path="$1"
    # Use a secure random password instead of "password"
    local secure_pass=$(openssl rand -base64 16 | tr -d '/=+' | cut -c -12)
    local options="${2:---sanitize-password=$secure_pass --sanitize-email=user%uid@example.com}"

    cd "$site_path" || return 1

    print_info "Running drush sql-sanitize with secure passwords..."

    if ddev drush sql-sanitize $options -y 2>&1; then
        print_status "OK" "Drush sanitization complete (passwords set to random value)"
        print_info "Sanitized password for all users: $secure_pass"
        cd - > /dev/null
        return 0
    else
        print_warning "Drush sanitization failed, using fallback"
        cd - > /dev/null
        return 1
    fi
}

# Sanitize SQL dump file directly
# Usage: sanitize_sql_file "/path/to/file.sql" [level]
# Levels: basic, full
sanitize_sql_file() {
    local sql_file="$1"
    local level="${2:-basic}"

    if [ ! -f "$sql_file" ]; then
        print_error "SQL file not found: $sql_file"
        return 1
    fi

    print_info "Sanitizing SQL file: $(basename "$sql_file")"

    # Create temp file
    local temp_file=$(mktemp)

    # Combine sanitization SQL
    local sanitize_sql=""

    case "$level" in
        basic)
            sanitize_sql="${SANITIZE_SQL_USERS}${SANITIZE_SQL_SESSIONS}"
            ;;
        full)
            sanitize_sql="${SANITIZE_SQL_USERS}${SANITIZE_SQL_SESSIONS}${SANITIZE_SQL_WATCHDOG}${SANITIZE_SQL_CACHE}${SANITIZE_SQL_WEBFORM}${SANITIZE_SQL_COMMERCE}"
            ;;
        *)
            sanitize_sql="${SANITIZE_SQL_USERS}${SANITIZE_SQL_SESSIONS}"
            ;;
    esac

    # Append sanitization SQL to end of dump
    cat "$sql_file" > "$temp_file"
    echo "" >> "$temp_file"
    echo "-- NWP Sanitization" >> "$temp_file"
    echo "$sanitize_sql" >> "$temp_file"

    mv "$temp_file" "$sql_file"

    print_status "OK" "Sanitization SQL appended ($level level)"
    return 0
}

# Sanitize backup directory (all SQL files)
# Usage: sanitize_backup_dir "/path/to/backup/dir" [level]
sanitize_backup_dir() {
    local backup_dir="$1"
    local level="${2:-basic}"

    if [ ! -d "$backup_dir" ]; then
        print_error "Backup directory not found: $backup_dir"
        return 1
    fi

    local count=0
    for sql_file in "$backup_dir"/*.sql; do
        if [ -f "$sql_file" ]; then
            if sanitize_sql_file "$sql_file" "$level"; then
                ((count++))
            fi
        fi
    done

    if [ $count -eq 0 ]; then
        print_warning "No SQL files found to sanitize"
        return 1
    fi

    print_status "OK" "Sanitized $count SQL file(s)"
    return 0
}

# Remove PII patterns from SQL dump
# Usage: sanitize_remove_patterns "/path/to/file.sql"
sanitize_remove_patterns() {
    local sql_file="$1"

    if [ ! -f "$sql_file" ]; then
        print_error "SQL file not found: $sql_file"
        return 1
    fi

    print_info "Removing PII patterns..."

    # Create temp file
    local temp_file=$(mktemp)

    # Remove common PII patterns (conservative approach)
    sed -E '
        # Remove credit card numbers (basic pattern)
        s/[0-9]{4}[- ]?[0-9]{4}[- ]?[0-9]{4}[- ]?[0-9]{4}/XXXX-XXXX-XXXX-XXXX/g

        # Remove SSN-like patterns
        s/[0-9]{3}-[0-9]{2}-[0-9]{4}/XXX-XX-XXXX/g

        # Remove phone numbers (US format)
        s/\([0-9]{3}\)[- ]?[0-9]{3}[- ]?[0-9]{4}/(XXX) XXX-XXXX/g
        s/[0-9]{3}[- ][0-9]{3}[- ][0-9]{4}/XXX-XXX-XXXX/g
    ' "$sql_file" > "$temp_file"

    mv "$temp_file" "$sql_file"

    print_status "OK" "PII patterns removed"
    return 0
}

# Full sanitization workflow
# Usage: sanitize_database "/path/to/site" "/path/to/backup.sql" [level]
sanitize_database() {
    local site_path="$1"
    local sql_file="$2"
    local level="${3:-basic}"

    print_header "Database Sanitization"

    # First try drush
    if sanitize_with_drush "$site_path"; then
        print_info "Database sanitized in-place with drush"

        # Re-export the database
        if [ -n "$sql_file" ]; then
            print_info "Re-exporting sanitized database..."
            cd "$site_path" || return 1
            ddev export-db --file="$sql_file" --gzip=false > /dev/null 2>&1
            cd - > /dev/null
            print_status "OK" "Exported sanitized database"
        fi

        return 0
    fi

    # Fallback: sanitize SQL file directly
    if [ -n "$sql_file" ] && [ -f "$sql_file" ]; then
        if sanitize_sql_file "$sql_file" "$level"; then
            sanitize_remove_patterns "$sql_file"
            return 0
        fi
    fi

    print_error "Sanitization failed"
    return 1
}

# Domains an address may legitimately carry AFTER sanitisation. Anchored at the
# end of the address on purpose: `bob@example.com.attacker.ru` is NOT clean, and
# the unanchored pre-2026-08-02 pattern would have said it was.
NWP_PII_SAFE_EMAIL_RE='@(example|invalid)\.(com|org|net)$'

# Check whether an artifact still contains PII.
#
# Usage:  check_for_pii "/path/to/file.sql"
# Exit:   0 — read the artifact, found nothing
#         1 — read the artifact, FOUND something (details on stdout)
#         2 — CANNOT VERIFY (missing / empty / unreadable). Never a pass.
#
# ---------------------------------------------------------------------------
# THE 2026-08-02 FIX — the email arm could not fire
# ---------------------------------------------------------------------------
#   The arm used to read:
#
#       if grep -qE '<email>' "$sql_file" | grep -qvE '@example\.(com|org|net)'
#
#   `grep -q` prints NOTHING — that is the whole meaning of -q. The downstream
#   `grep -qv` therefore read an empty stdin, found no non-matching line and
#   exited 1. The branch was UNSATISFIABLE: no artifact, however dirty, could
#   take it. Measured on a 3-address file: `found` stayed 0 and the function
#   returned "No obvious PII detected", exit 0.
#
#   Its neighbour, the credit-card arm, is a plain `grep -qE` and always
#   worked. That is exactly how the defect survived: a two-arm detector whose
#   working arm supplied the only evidence anyone ever saw.
#
#   The replacement is a single awk pass, chosen over `grep -o … | grep -v … |
#   wc -l` deliberately: a pipeline whose head is a `grep` returns a non-zero
#   status when the tail finds nothing, and under `set -o pipefail` (which some
#   callers set) that turns "clean artifact" into "command substitution
#   failed". One process, no pipe, always exit 0, verdict carried in the value.
#
#   A missing or empty artifact used to `return 1` — indistinguishable from
#   "PII found" to a caller checking `if check_for_pii`, and worse, an empty
#   file scanned clean. It is now exit 2, CANNOT VERIFY, per the estate rule
#   that an unmeasurable subject is never graded healthy.
check_for_pii() {
    local sql_file="${1:-}"

    if [ -z "$sql_file" ] || [ ! -f "$sql_file" ] || [ ! -r "$sql_file" ]; then
        print_error "CANNOT VERIFY: no readable artifact at '${sql_file:-<none>}'"
        return 2
    fi
    if [ ! -s "$sql_file" ]; then
        print_error "CANNOT VERIFY: artifact is empty: $sql_file"
        return 2
    fi

    print_info "Checking for potential PII..."

    local found=0

    # ---- real email addresses (anything not on the post-sanitisation list) ----
    local real_emails
    real_emails="$(
        awk -v safe="$NWP_PII_SAFE_EMAIL_RE" '
            {
                s = $0
                while (match(s, /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z][A-Za-z]+/)) {
                    addr = substr(s, RSTART, RLENGTH)
                    s    = substr(s, RSTART + RLENGTH)
                    if (addr !~ safe) n++
                }
            }
            END { print n + 0 }
        ' "$sql_file"
    )"
    if [ "${real_emails:-0}" -gt 0 ]; then
        echo "  - Real email addresses found ($real_emails occurrence(s))"
        found=1
    fi

    # ---- credit card patterns ----
    if grep -qE '[0-9]{4}[- ]?[0-9]{4}[- ]?[0-9]{4}[- ]?[0-9]{4}' "$sql_file"; then
        echo "  - Potential credit card numbers found"
        found=1
    fi

    if [ $found -eq 0 ]; then
        print_status "OK" "No obvious PII detected"
        return 0
    else
        print_warning "Potential PII detected - consider running sanitization"
        return 1
    fi
}
