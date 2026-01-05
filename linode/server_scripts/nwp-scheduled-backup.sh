#!/bin/bash

################################################################################
# nwp-scheduled-backup.sh - NWP Scheduled Backup Script
################################################################################
#
# Automated backup script with retention policies for different backup types.
# Designed to be run from cron jobs for hourly, daily, and weekly backups.
# This script runs ON the Linode server.
#
# Usage:
#   ./nwp-scheduled-backup.sh [OPTIONS] SITE BACKUP_TYPE
#
# Arguments:
#   SITE                 Site directory to backup (e.g., prod, test)
#   BACKUP_TYPE          Type of backup: database, files, or full
#
# Options:
#   --webroot DIR        Web root parent directory (default: /var/www)
#   --verify             Verify backup after creation
#   -v, --verbose        Verbose output
#   -h, --help           Show this help message
#
# Backup Types and Retention:
#   database - Database only backup
#              Location: /var/backups/nwp/hourly
#              Retention: 24 backups (approximately 1 day at hourly intervals)
#
#   files    - Files only backup (no database)
#              Location: /var/backups/nwp/daily
#              Retention: 7 backups (1 week of daily backups)
#
#   full     - Complete backup (database + files)
#              Location: /var/backups/nwp/weekly
#              Retention: 4 backups (1 month of weekly backups)
#
# Exit Codes:
#   0 - Backup successful
#   1 - Backup failed
#   2 - Invalid arguments
#
# Examples:
#   ./nwp-scheduled-backup.sh prod database
#   ./nwp-scheduled-backup.sh prod files --verify
#   ./nwp-scheduled-backup.sh prod full -v
#
################################################################################

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

# Default configuration
WEBROOT_PARENT="/var/www"
BACKUP_BASE="/var/backups/nwp"
VERIFY_BACKUP=false
VERBOSE=false
SITE=""
BACKUP_TYPE=""

# Retention policies (number of backups to keep)
RETENTION_HOURLY=24
RETENTION_DAILY=7
RETENTION_WEEKLY=4

# Script paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY_SCRIPT="$SCRIPT_DIR/nwp-verify-backup.sh"
AUDIT_SCRIPT="$SCRIPT_DIR/nwp-audit.sh"
NOTIFY_SCRIPT="$SCRIPT_DIR/nwp-notify.sh"

# Helper functions
print_header() {
    echo -e "\n${BLUE}${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}${BOLD}  $1${NC}"
    echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════════════${NC}\n"
}

print_info() {
    if [ "$VERBOSE" = true ]; then
        echo -e "${BLUE}INFO:${NC} $1"
    fi
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}!${NC} $1"
}

print_error() {
    echo -e "${RED}ERROR:${NC} $1" >&2
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --webroot)
            WEBROOT_PARENT="$2"
            shift 2
            ;;
        --verify)
            VERIFY_BACKUP=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            grep "^#" "$0" | grep -v "^#!/" | sed 's/^# //' | sed 's/^#//'
            exit 0
            ;;
        -*)
            print_error "Unknown option: $1"
            exit 2
            ;;
        *)
            if [ -z "$SITE" ]; then
                SITE="$1"
            elif [ -z "$BACKUP_TYPE" ]; then
                BACKUP_TYPE="$1"
            else
                print_error "Too many arguments: $1"
                exit 2
            fi
            shift
            ;;
    esac
done

# Validate required arguments
if [ -z "$SITE" ]; then
    print_error "Site argument is required"
    echo "Usage: $0 [OPTIONS] SITE BACKUP_TYPE"
    exit 2
fi

if [ -z "$BACKUP_TYPE" ]; then
    print_error "Backup type argument is required (database, files, or full)"
    echo "Usage: $0 [OPTIONS] SITE BACKUP_TYPE"
    exit 2
fi

# Validate backup type
case "$BACKUP_TYPE" in
    database|files|full)
        ;;
    *)
        print_error "Invalid backup type: $BACKUP_TYPE"
        echo "Valid types: database, files, full"
        exit 2
        ;;
esac

# Determine output directory and retention based on backup type
case "$BACKUP_TYPE" in
    database)
        OUTPUT_DIR="$BACKUP_BASE/hourly"
        RETENTION=$RETENTION_HOURLY
        ;;
    files)
        OUTPUT_DIR="$BACKUP_BASE/daily"
        RETENTION=$RETENTION_DAILY
        ;;
    full)
        OUTPUT_DIR="$BACKUP_BASE/weekly"
        RETENTION=$RETENTION_WEEKLY
        ;;
esac

# Validate site directory
SITE_DIR="$WEBROOT_PARENT/$SITE"
if [ ! -d "$SITE_DIR" ]; then
    print_error "Site directory not found: $SITE_DIR"
    exit 1
fi

# Create output directory
sudo mkdir -p "$OUTPUT_DIR"

# Generate timestamped backup name
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_PREFIX="${SITE}_${BACKUP_TYPE}_${TIMESTAMP}"

print_header "NWP Scheduled Backup: $BACKUP_TYPE"

echo "Configuration:"
echo "  Site: $SITE ($SITE_DIR)"
echo "  Type: $BACKUP_TYPE"
echo "  Output: $OUTPUT_DIR"
echo "  Retention: $RETENTION backups"
echo "  Timestamp: $TIMESTAMP"
echo ""

################################################################################
# PERFORM BACKUP
################################################################################

BACKUP_SUCCESS=true
BACKUP_FILES=()
BACKUP_MESSAGE=""

# Database backup
if [ "$BACKUP_TYPE" = "database" ] || [ "$BACKUP_TYPE" = "full" ]; then
    print_info "Backing up database..."

    # Extract database credentials from settings.php
    SETTINGS_FILE="$SITE_DIR/web/sites/default/settings.php"

    if [ ! -f "$SETTINGS_FILE" ]; then
        print_error "Settings file not found: $SETTINGS_FILE"
        BACKUP_MESSAGE="Settings file not found"
        BACKUP_SUCCESS=false
    else
        # Extract DB credentials
        DB_NAME=$(grep "^\s*'database'" "$SETTINGS_FILE" | head -n1 | sed "s/.*'\(.*\)'.*/\1/" || echo "")
        DB_USER=$(grep "^\s*'username'" "$SETTINGS_FILE" | head -n1 | sed "s/.*'\(.*\)'.*/\1/" || echo "")
        DB_PASS=$(grep "^\s*'password'" "$SETTINGS_FILE" | head -n1 | sed "s/.*'\(.*\)'.*/\1/" || echo "")

        if [ -z "$DB_NAME" ]; then
            print_error "Could not extract database name from settings.php"
            BACKUP_MESSAGE="Failed to extract database credentials"
            BACKUP_SUCCESS=false
        else
            print_info "Database: $DB_NAME"

            # Perform database dump
            DB_BACKUP="$OUTPUT_DIR/${BACKUP_PREFIX}_db.sql.gz"

            if [ -n "$DB_PASS" ]; then
                mysqldump -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" 2>/dev/null | gzip > "$DB_BACKUP" || {
                    print_error "Database dump failed"
                    BACKUP_MESSAGE="mysqldump failed"
                    BACKUP_SUCCESS=false
                }
            else
                mysqldump -u "$DB_USER" "$DB_NAME" 2>/dev/null | gzip > "$DB_BACKUP" || {
                    print_error "Database dump failed"
                    BACKUP_MESSAGE="mysqldump failed"
                    BACKUP_SUCCESS=false
                }
            fi

            if [ "$BACKUP_SUCCESS" = true ] && [ -f "$DB_BACKUP" ]; then
                DB_SIZE=$(du -h "$DB_BACKUP" | cut -f1)
                print_success "Database backup created: $(basename "$DB_BACKUP") ($DB_SIZE)"
                BACKUP_FILES+=("$DB_BACKUP")
            fi
        fi
    fi
fi

# Files backup
if [ "$BACKUP_SUCCESS" = true ] && ([ "$BACKUP_TYPE" = "files" ] || [ "$BACKUP_TYPE" = "full" ]); then
    print_info "Backing up files..."

    FILES_BACKUP="$OUTPUT_DIR/${BACKUP_PREFIX}_files.tar.gz"

    # Backup code files (excluding large directories)
    sudo tar -czf "$FILES_BACKUP" \
        -C "$(dirname "$SITE_DIR")" \
        --exclude='*/sites/default/files' \
        --exclude='*/node_modules' \
        --exclude='*/.git' \
        "$(basename "$SITE_DIR")" 2>/dev/null || {
        print_error "Files backup failed"
        BACKUP_MESSAGE="tar failed for files"
        BACKUP_SUCCESS=false
    }

    if [ "$BACKUP_SUCCESS" = true ] && [ -f "$FILES_BACKUP" ]; then
        FILES_SIZE=$(du -h "$FILES_BACKUP" | cut -f1)
        print_success "Files backup created: $(basename "$FILES_BACKUP") ($FILES_SIZE)"
        BACKUP_FILES+=("$FILES_BACKUP")
    fi

    # Backup uploaded files separately for full backups
    if [ "$BACKUP_SUCCESS" = true ] && [ "$BACKUP_TYPE" = "full" ] && [ -d "$SITE_DIR/web/sites/default/files" ]; then
        print_info "Backing up uploaded files..."

        UPLOADS_BACKUP="$OUTPUT_DIR/${BACKUP_PREFIX}_uploads.tar.gz"
        sudo tar -czf "$UPLOADS_BACKUP" \
            -C "$SITE_DIR/web/sites/default" \
            files 2>/dev/null || {
            print_warning "Uploads backup failed (non-critical)"
        }

        if [ -f "$UPLOADS_BACKUP" ]; then
            UPLOADS_SIZE=$(du -h "$UPLOADS_BACKUP" | cut -f1)
            print_success "Uploads backup created: $(basename "$UPLOADS_BACKUP") ($UPLOADS_SIZE)"
            BACKUP_FILES+=("$UPLOADS_BACKUP")
        fi
    fi
fi

################################################################################
# VERIFY BACKUP
################################################################################

if [ "$BACKUP_SUCCESS" = true ] && [ "$VERIFY_BACKUP" = true ]; then
    print_info "Verifying backup files..."

    if [ -x "$VERIFY_SCRIPT" ]; then
        for backup_file in "${BACKUP_FILES[@]}"; do
            if [ -f "$backup_file" ]; then
                if "$VERIFY_SCRIPT" "$backup_file" >/dev/null 2>&1; then
                    print_success "Verified: $(basename "$backup_file")"
                else
                    print_error "Verification failed: $(basename "$backup_file")"
                    BACKUP_MESSAGE="Backup verification failed"
                    BACKUP_SUCCESS=false
                fi
            fi
        done
    else
        print_warning "Verify script not found: $VERIFY_SCRIPT"
    fi
fi

################################################################################
# ROTATE OLD BACKUPS
################################################################################

if [ "$BACKUP_SUCCESS" = true ]; then
    print_info "Rotating old backups (keeping $RETENTION)..."

    # List all backup files for this site and type, sorted by modification time (oldest first)
    # Pattern matches: {site}_{type}_*
    find "$OUTPUT_DIR" -type f -name "${SITE}_${BACKUP_TYPE}_*" -printf '%T+ %p\n' 2>/dev/null | \
        sort -r | \
        tail -n +$((RETENTION + 1)) | \
        cut -d' ' -f2- | \
        while IFS= read -r old_backup; do
            print_info "Removing old backup: $(basename "$old_backup")"
            sudo rm -f "$old_backup"
        done

    print_success "Backup rotation complete"
fi

# Fix permissions
sudo chown -R $(whoami):$(whoami) "$OUTPUT_DIR" 2>/dev/null || true

################################################################################
# LOGGING AND NOTIFICATIONS
################################################################################

if [ "$BACKUP_SUCCESS" = true ]; then
    # Log success to audit system
    if [ -x "$AUDIT_SCRIPT" ]; then
        "$AUDIT_SCRIPT" \
            --event "backup" \
            --site "$SITE" \
            --status "success" \
            --message "Backup type: $BACKUP_TYPE, files: ${#BACKUP_FILES[@]}" \
            >/dev/null 2>&1 || true
    fi

    print_header "Backup Complete!"
    echo "Backup Summary:"
    echo "  Type: $BACKUP_TYPE"
    echo "  Location: $OUTPUT_DIR"
    echo "  Files created: ${#BACKUP_FILES[@]}"
    for backup_file in "${BACKUP_FILES[@]}"; do
        echo "    - $(basename "$backup_file")"
    done
    echo ""
    print_success "Backup successful!"

    exit 0
else
    # Log failure to audit system
    if [ -x "$AUDIT_SCRIPT" ]; then
        "$AUDIT_SCRIPT" \
            --event "backup" \
            --site "$SITE" \
            --status "failure" \
            --message "$BACKUP_MESSAGE" \
            >/dev/null 2>&1 || true
    fi

    # Send notification
    if [ -x "$NOTIFY_SCRIPT" ]; then
        "$NOTIFY_SCRIPT" \
            --event "backup_failure" \
            --site "$SITE" \
            --message "Backup type: $BACKUP_TYPE - $BACKUP_MESSAGE" \
            >/dev/null 2>&1 || true
    fi

    print_header "Backup Failed!"
    print_error "$BACKUP_MESSAGE"

    exit 1
fi
