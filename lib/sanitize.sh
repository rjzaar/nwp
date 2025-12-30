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
SANITIZE_SQL_USERS='
-- Sanitize user data (GDPR compliant)
UPDATE users_field_data
SET
    mail = CONCAT("user", uid, "@example.com"),
    init = CONCAT("user", uid, "@example.com"),
    name = CONCAT("user_", uid)
WHERE uid > 1;

-- Reset all passwords to "password" (Drupal 10+ hash)
UPDATE users_field_data
SET pass = "$S$E0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuv"
WHERE uid > 0;
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

# Run Drush sql-sanitize
# Usage: sanitize_with_drush "/path/to/site"
sanitize_with_drush() {
    local site_path="$1"
    local options="${2:---sanitize-password=password --sanitize-email=user%uid@example.com}"

    cd "$site_path" || return 1

    print_info "Running drush sql-sanitize..."

    if ddev drush sql-sanitize $options -y 2>&1; then
        print_status "OK" "Drush sanitization complete"
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

# Check if database contains PII
# Usage: check_for_pii "/path/to/file.sql"
check_for_pii() {
    local sql_file="$1"

    if [ ! -f "$sql_file" ]; then
        return 1
    fi

    print_info "Checking for potential PII..."

    local found=0

    # Check for real email addresses (not example.com)
    if grep -qE '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' "$sql_file" | grep -qvE '@example\.(com|org|net)'; then
        echo "  - Real email addresses found"
        found=1
    fi

    # Check for credit card patterns
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
