#!/bin/bash
set -e

################################################################################
# CI/CD Database Fetch Script
#
# Fetches production database for CI/CD testing environments
# Supports caching and sanitization for faster builds
#
# Usage: ./scripts/ci/fetch-db.sh [OPTIONS]
################################################################################

# Get script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source UI library for consistent output
source "$PROJECT_ROOT/lib/ui.sh"

################################################################################
# Parse command-line arguments
################################################################################

USE_CACHE=false
SANITIZE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --use-cache)
            USE_CACHE=true
            shift
            ;;
        --sanitize)
            SANITIZE=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--use-cache] [--sanitize]"
            exit 1
            ;;
    esac
done

################################################################################
# Detect or use SITE_NAME
################################################################################

# Try to get SITE_NAME from environment variable (CI sets this)
if [ -z "$SITE_NAME" ]; then
    # Fallback: use current directory basename
    SITE_NAME=$(basename "$PROJECT_ROOT")
    info "SITE_NAME not set, using directory name: $SITE_NAME"
else
    info "Using SITE_NAME from environment: $SITE_NAME"
fi

################################################################################
# Create .data directory if needed
################################################################################

mkdir -p "$PROJECT_ROOT/.data"

################################################################################
# Check cache
################################################################################

DB_CACHE="$PROJECT_ROOT/.data/db.sql.gz"

if [ "$USE_CACHE" = true ] && [ -f "$DB_CACHE" ]; then
    info "Using cached database from .data/db.sql.gz"
    pass "Cached database ready"
    exit 0
fi

################################################################################
# Fetch production database using backup.sh
################################################################################

info "Fetching production database..."

# Build backup.sh command
BACKUP_CMD="$PROJECT_ROOT/backup.sh -b"

# Add sanitize flag if requested
if [ "$SANITIZE" = true ]; then
    info "Sanitization enabled"
    BACKUP_CMD="$BACKUP_CMD --sanitize"
fi

# Add site name
BACKUP_CMD="$BACKUP_CMD $SITE_NAME"

# Execute backup
info "Running: $BACKUP_CMD"
if $BACKUP_CMD; then
    pass "Database backup created"
else
    fail "Failed to create database backup"
    exit 1
fi

################################################################################
# Move backup to .data directory
################################################################################

# Find the most recent backup file
BACKUP_DIR="$PROJECT_ROOT/sitebackups/$SITE_NAME"

if [ ! -d "$BACKUP_DIR" ]; then
    fail "Backup directory not found: $BACKUP_DIR"
    exit 1
fi

# Find the most recent .sql file
LATEST_SQL=$(find "$BACKUP_DIR" -name "*.sql" -type f -printf '%T@ %p\n' | sort -nr | head -1 | cut -d' ' -f2-)

if [ -z "$LATEST_SQL" ] || [ ! -f "$LATEST_SQL" ]; then
    fail "No database backup found in $BACKUP_DIR"
    exit 1
fi

info "Found database backup: $(basename "$LATEST_SQL")"

# Compress and move to .data directory
info "Compressing and moving to .data/db.sql.gz..."
gzip -c "$LATEST_SQL" > "$DB_CACHE"

if [ -f "$DB_CACHE" ]; then
    # Show file size
    SIZE=$(du -h "$DB_CACHE" | cut -f1)
    pass "Database ready at .data/db.sql.gz ($SIZE)"
else
    fail "Failed to create .data/db.sql.gz"
    exit 1
fi

################################################################################
# Cleanup
################################################################################

# Optionally keep the original backup or remove it
# For now, we'll keep it in sitebackups/
info "Original backup retained at: $LATEST_SQL"

pass "Database fetch completed successfully"
