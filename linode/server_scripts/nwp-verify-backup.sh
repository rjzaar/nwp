#!/bin/bash

################################################################################
# nwp-verify-backup.sh - NWP Backup Verification Script
################################################################################
#
# Verifies the integrity of NWP backup files.
# This script runs ON the Linode server.
#
# Usage:
#   ./nwp-verify-backup.sh [OPTIONS] BACKUP_FILE
#
# Arguments:
#   BACKUP_FILE          Path to backup file to verify
#
# Options:
#   --min-size SIZE      Minimum acceptable size in bytes (default: 1024)
#   -v, --verbose        Verbose output
#   -h, --help           Show this help message
#
# Verification Checks:
#   - File exists and is readable
#   - File size is reasonable (not empty, not suspiciously small)
#   - For .sql.gz files: validates gzip integrity and SQL content
#   - For .tar.gz files: validates tar archive integrity
#
# Exit Codes:
#   0 - Backup is valid
#   1 - Backup is invalid or verification failed
#   2 - Invalid arguments
#
# Examples:
#   ./nwp-verify-backup.sh /var/backups/nwp/hourly/prod_database_20260105_120000_db.sql.gz
#   ./nwp-verify-backup.sh /var/backups/nwp/weekly/prod_full_20260105_030000_files.tar.gz
#
################################################################################

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Default configuration
MIN_SIZE=1024  # 1 KB minimum
VERBOSE=false
BACKUP_FILE=""

# Helper functions
print_info() {
    if [ "$VERBOSE" = true ]; then
        echo -e "${BLUE}INFO:${NC} $1"
    fi
}

print_success() {
    if [ "$VERBOSE" = true ]; then
        echo -e "${GREEN}✓${NC} $1"
    fi
}

print_error() {
    echo -e "${RED}ERROR:${NC} $1" >&2
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --min-size)
            MIN_SIZE="$2"
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
            exit 2
            ;;
        *)
            if [ -z "$BACKUP_FILE" ]; then
                BACKUP_FILE="$1"
            else
                print_error "Too many arguments: $1"
                exit 2
            fi
            shift
            ;;
    esac
done

# Validate required arguments
if [ -z "$BACKUP_FILE" ]; then
    print_error "Backup file argument is required"
    echo "Usage: $0 [OPTIONS] BACKUP_FILE"
    exit 2
fi

# Check if file exists
if [ ! -f "$BACKUP_FILE" ]; then
    print_error "Backup file not found: $BACKUP_FILE"
    exit 1
fi

# Check if file is readable
if [ ! -r "$BACKUP_FILE" ]; then
    print_error "Backup file not readable: $BACKUP_FILE"
    exit 1
fi

print_info "Verifying backup: $(basename "$BACKUP_FILE")"

################################################################################
# CHECK FILE SIZE
################################################################################

print_info "Checking file size..."

FILE_SIZE=$(stat -c%s "$BACKUP_FILE" 2>/dev/null || echo "0")

if [ "$FILE_SIZE" -lt "$MIN_SIZE" ]; then
    print_error "File is too small ($FILE_SIZE bytes, minimum $MIN_SIZE bytes)"
    exit 1
fi

print_success "File size OK: $FILE_SIZE bytes"

################################################################################
# CHECK FILE TYPE AND INTEGRITY
################################################################################

FILENAME=$(basename "$BACKUP_FILE")

# Check if it's a gzipped SQL database backup
if [[ "$FILENAME" == *_db.sql.gz ]]; then
    print_info "Detected database backup (SQL gzip)"

    # Verify gzip integrity
    print_info "Testing gzip integrity..."
    if ! gzip -t "$BACKUP_FILE" 2>/dev/null; then
        print_error "Gzip integrity check failed"
        exit 1
    fi
    print_success "Gzip integrity OK"

    # Verify SQL content (check for common SQL statements)
    print_info "Verifying SQL content..."

    # Extract first few lines and check for SQL patterns
    SQL_SAMPLE=$(gunzip -c "$BACKUP_FILE" 2>/dev/null | head -n 100)

    if [ -z "$SQL_SAMPLE" ]; then
        print_error "Failed to extract SQL content"
        exit 1
    fi

    # Check for common SQL patterns (tables, inserts, creates, etc.)
    if echo "$SQL_SAMPLE" | grep -qiE '(CREATE TABLE|INSERT INTO|DROP TABLE|-- MySQL|-- PostgreSQL|-- Dumping)'; then
        print_success "SQL content verified"
    else
        print_error "File does not contain valid SQL content"
        exit 1
    fi

# Check if it's a gzipped tar archive (files or uploads backup)
elif [[ "$FILENAME" == *_files.tar.gz ]] || [[ "$FILENAME" == *_uploads.tar.gz ]]; then
    print_info "Detected files backup (tar gzip)"

    # Verify gzip integrity
    print_info "Testing gzip integrity..."
    if ! gzip -t "$BACKUP_FILE" 2>/dev/null; then
        print_error "Gzip integrity check failed"
        exit 1
    fi
    print_success "Gzip integrity OK"

    # Verify tar archive integrity
    print_info "Testing tar archive integrity..."
    if ! tar -tzf "$BACKUP_FILE" >/dev/null 2>&1; then
        print_error "Tar archive integrity check failed"
        exit 1
    fi
    print_success "Tar archive integrity OK"

    # Count files in archive
    FILE_COUNT=$(tar -tzf "$BACKUP_FILE" 2>/dev/null | wc -l)
    print_success "Archive contains $FILE_COUNT files/directories"

    # Verify archive is not empty
    if [ "$FILE_COUNT" -eq 0 ]; then
        print_error "Archive is empty"
        exit 1
    fi

# Unknown file type
else
    print_error "Unknown backup file type: $FILENAME"
    print_error "Expected: *_db.sql.gz, *_files.tar.gz, or *_uploads.tar.gz"
    exit 1
fi

################################################################################
# FINAL VERIFICATION
################################################################################

print_success "Backup verification passed!"

if [ "$VERBOSE" = true ]; then
    echo ""
    echo "Verification Summary:"
    echo "  File: $(basename "$BACKUP_FILE")"
    echo "  Size: $FILE_SIZE bytes ($(du -h "$BACKUP_FILE" | cut -f1))"
    echo "  Type: $(file -b "$BACKUP_FILE")"
    echo "  Status: Valid"
fi

exit 0
