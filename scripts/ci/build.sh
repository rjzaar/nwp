#!/usr/bin/env bash
set -e

# CI/CD Build Operations
# Handles container startup, dependency installation, database import, and deployment

# Source UI library for consistent output
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$PROJECT_ROOT/lib/ui.sh"

info "Starting CI/CD build process..."

# Start DDEV if not running
info "Checking DDEV status..."
if ! ddev describe >/dev/null 2>&1; then
    info "Starting DDEV..."
    ddev start
    pass "DDEV started"
else
    pass "DDEV already running"
fi

# Install composer dependencies
info "Installing Composer dependencies (production mode)..."
ddev composer install --no-dev
pass "Composer dependencies installed"

# Handle npm build if package.json exists
if [ -f "$PROJECT_ROOT/package.json" ]; then
    info "Found package.json, installing npm dependencies..."
    ddev npm ci
    pass "npm dependencies installed"

    info "Running npm build..."
    ddev npm run build
    pass "npm build completed"
else
    info "No package.json found, skipping npm steps"
fi

# Import database if dump exists
DB_DUMP="$PROJECT_ROOT/.data/db.sql.gz"
if [ -f "$DB_DUMP" ]; then
    info "Found database dump at .data/db.sql.gz, importing..."
    ddev import-db --src="$DB_DUMP"
    pass "Database imported"
else
    info "No database dump found at .data/db.sql.gz, skipping import"
fi

# Run Drupal deployment tasks
info "Running Drupal deployment (updb, cim, cr)..."
ddev drush deploy
pass "Drupal deployment completed"

pass "CI/CD build process completed successfully"
