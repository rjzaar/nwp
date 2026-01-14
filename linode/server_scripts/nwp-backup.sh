#!/bin/bash

################################################################################
# nwp-backup.sh - Backup NWP Site on Linode Server
################################################################################
#
# Creates a backup of a Drupal/OpenSocial site (database and files).
# This script runs ON the Linode server.
#
# Usage:
#   ./nwp-backup.sh [OPTIONS] [SITE_DIR]
#
# Arguments:
#   SITE_DIR             Site directory to backup (default: /var/www/prod)
#
# Options:
#   --db-only            Backup database only (skip files)
#   --files-only         Backup files only (skip database)
#   --output DIR         Output directory (default: /var/backups/nwp)
#   --name NAME          Backup name prefix (default: derived from site)
#   -v, --verbose        Verbose output
#   -h, --help           Show this help message
#
################################################################################

set -e  # Exit on error

# Color output
# Respects NO_COLOR standard (https://no-color.org/)
if [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
    RED=''
    GREEN=''
    BLUE=''
    YELLOW=''
    BOLD=''
    NC=''
else
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    BLUE='\033[0;34m'
    YELLOW='\033[1;33m'
    BOLD='\033[1m'
    NC='\033[0m'
fi

# Default configuration
SITE_DIR="/var/www/prod"
OUTPUT_DIR="/var/backups/nwp"
BACKUP_NAME=""
DB_ONLY=false
FILES_ONLY=false
VERBOSE=false

# Helper functions
print_header() {
    echo -e "\n${BLUE}${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}${BOLD}  $1${NC}"
    echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════════════${NC}\n"
}

print_info() {
    echo -e "${BLUE}INFO:${NC} $1"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}ERROR:${NC} $1"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --db-only)
            DB_ONLY=true
            shift
            ;;
        --files-only)
            FILES_ONLY=true
            shift
            ;;
        --output)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --name)
            BACKUP_NAME="$2"
            shift 2
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
            exit 1
            ;;
        *)
            SITE_DIR="$1"
            shift
            ;;
    esac
done

# Validate site directory
if [ ! -d "$SITE_DIR" ]; then
    print_error "Site directory not found: $SITE_DIR"
    exit 1
fi

# Generate backup name
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
if [ -z "$BACKUP_NAME" ]; then
    BACKUP_NAME=$(basename "$SITE_DIR")
fi

# Create output directory
sudo mkdir -p "$OUTPUT_DIR"

print_header "Backing Up: $BACKUP_NAME"

echo "Configuration:"
echo "  Site: $SITE_DIR"
echo "  Output: $OUTPUT_DIR"
echo "  Timestamp: $TIMESTAMP"
echo "  Database: $([ "$FILES_ONLY" = true ] && echo "Skip" || echo "Include")"
echo "  Files: $([ "$DB_ONLY" = true ] && echo "Skip" || echo "Include")"
echo ""

# Backup database
if [ "$FILES_ONLY" != true ]; then
    print_info "Backing up database..."

    # Extract database credentials from settings.php
    SETTINGS_FILE="$SITE_DIR/web/sites/default/settings.php"

    if [ ! -f "$SETTINGS_FILE" ]; then
        print_error "Settings file not found: $SETTINGS_FILE"
        exit 1
    fi

    # Extract DB name (crude but works for standard Drupal settings.php)
    DB_NAME=$(grep "^\s*'database'" "$SETTINGS_FILE" | head -n1 | sed "s/.*'\(.*\)'.*/\1/")
    DB_USER=$(grep "^\s*'username'" "$SETTINGS_FILE" | head -n1 | sed "s/.*'\(.*\)'.*/\1/")
    DB_PASS=$(grep "^\s*'password'" "$SETTINGS_FILE" | head -n1 | sed "s/.*'\(.*\)'.*/\1/")

    if [ -z "$DB_NAME" ]; then
        print_error "Could not extract database name from settings.php"
        exit 1
    fi

    print_info "Database: $DB_NAME"

    # Perform backup
    DB_BACKUP="$OUTPUT_DIR/${BACKUP_NAME}_db_${TIMESTAMP}.sql.gz"

    if [ -n "$DB_PASS" ]; then
        mysqldump -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" | gzip > "$DB_BACKUP"
    else
        mysqldump -u "$DB_USER" "$DB_NAME" | gzip > "$DB_BACKUP"
    fi

    DB_SIZE=$(du -h "$DB_BACKUP" | cut -f1)
    print_success "Database backup created: $DB_BACKUP ($DB_SIZE)"
fi

# Backup files
if [ "$DB_ONLY" != true ]; then
    print_info "Backing up files..."

    FILES_BACKUP="$OUTPUT_DIR/${BACKUP_NAME}_files_${TIMESTAMP}.tar.gz"

    # Backup everything except sites/default/files (can be huge)
    # Include sites/default/files separately if needed
    sudo tar -czf "$FILES_BACKUP" \
        -C "$(dirname "$SITE_DIR")" \
        --exclude='*/sites/default/files' \
        --exclude='*/node_modules' \
        --exclude='*/.git' \
        "$(basename "$SITE_DIR")"

    FILES_SIZE=$(du -h "$FILES_BACKUP" | cut -f1)
    print_success "Files backup created: $FILES_BACKUP ($FILES_SIZE)"

    # Optionally backup sites/default/files separately
    if [ -d "$SITE_DIR/web/sites/default/files" ]; then
        print_info "Backing up uploaded files..."

        UPLOADS_BACKUP="$OUTPUT_DIR/${BACKUP_NAME}_uploads_${TIMESTAMP}.tar.gz"
        sudo tar -czf "$UPLOADS_BACKUP" \
            -C "$SITE_DIR/web/sites/default" \
            files

        UPLOADS_SIZE=$(du -h "$UPLOADS_BACKUP" | cut -f1)
        print_success "Uploads backup created: $UPLOADS_BACKUP ($UPLOADS_SIZE)"
    fi
fi

# Set permissions
sudo chown -R $(whoami):$(whoami) "$OUTPUT_DIR"

# Create backup manifest
MANIFEST="$OUTPUT_DIR/${BACKUP_NAME}_manifest_${TIMESTAMP}.txt"
cat > "$MANIFEST" << EOF
NWP Backup Manifest
===================
Site: $BACKUP_NAME
Directory: $SITE_DIR
Date: $(date)
Timestamp: $TIMESTAMP

Files:
EOF

if [ "$FILES_ONLY" != true ] && [ -f "$DB_BACKUP" ]; then
    echo "  - Database: $(basename "$DB_BACKUP") ($DB_SIZE)" >> "$MANIFEST"
fi

if [ "$DB_ONLY" != true ] && [ -f "$FILES_BACKUP" ]; then
    echo "  - Files: $(basename "$FILES_BACKUP") ($FILES_SIZE)" >> "$MANIFEST"
fi

if [ -f "$UPLOADS_BACKUP" ]; then
    echo "  - Uploads: $(basename "$UPLOADS_BACKUP") ($UPLOADS_SIZE)" >> "$MANIFEST"
fi

print_success "Manifest created: $MANIFEST"

# Calculate total size
TOTAL_SIZE=$(du -sh "$OUTPUT_DIR" | cut -f1)

print_header "Backup Complete!"

echo "Backup Summary:"
echo "  Location: $OUTPUT_DIR"
echo "  Total Size: $TOTAL_SIZE"
echo ""
echo "Files created:"
[ "$FILES_ONLY" != true ] && [ -f "$DB_BACKUP" ] && echo "  - $DB_BACKUP"
[ "$DB_ONLY" != true ] && [ -f "$FILES_BACKUP" ] && echo "  - $FILES_BACKUP"
[ -f "$UPLOADS_BACKUP" ] && echo "  - $UPLOADS_BACKUP"
echo "  - $MANIFEST"
echo ""
print_success "Backup successful!"
