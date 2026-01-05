#!/usr/bin/env bash
set -e

################################################################################
# CI/CD Preview Environment Creation Script
#
# Creates an isolated preview environment for pull requests/merge requests
# Uses DDEV to spin up a fully functional test environment with database
#
# Usage: ./scripts/ci/create-preview.sh <environment-name>
# Example: ./scripts/ci/create-preview.sh pr-123
################################################################################

# Get script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source UI library for consistent output
source "$PROJECT_ROOT/lib/ui.sh"

################################################################################
# Parse command-line arguments
################################################################################

if [ $# -lt 1 ]; then
    fail "Usage: $0 <environment-name>"
    echo ""
    echo "Example: $0 pr-123"
    echo ""
    exit 1
fi

ENV_NAME="$1"

# Validate environment name (alphanumeric, hyphen, underscore only)
if [[ ! "$ENV_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    fail "Invalid environment name: $ENV_NAME"
    echo "Environment name must contain only letters, numbers, hyphens, and underscores"
    exit 1
fi

info "Creating preview environment: $ENV_NAME"

################################################################################
# Set up environment-specific DDEV project
################################################################################

# Generate unique DDEV project name
DDEV_PROJECT="${ENV_NAME}"

info "Setting up DDEV project: $DDEV_PROJECT"

# Check if DDEV is already running
if ddev describe >/dev/null 2>&1; then
    CURRENT_PROJECT=$(ddev describe -j | grep -oP '"name":\s*"\K[^"]+' | head -1 || echo "")

    if [ "$CURRENT_PROJECT" = "$DDEV_PROJECT" ]; then
        pass "DDEV project already exists: $DDEV_PROJECT"
    else
        warn "Different DDEV project is running: $CURRENT_PROJECT"
        info "Stopping current project to avoid conflicts..."
        ddev stop
    fi
fi

# Configure DDEV for this environment
# Create a temporary .ddev/config.yaml override if needed
if [ ! -f "$PROJECT_ROOT/.ddev/config.yaml" ]; then
    info "Initializing DDEV configuration..."
    ddev config --project-type=drupal10 --docroot=web --project-name="$DDEV_PROJECT"
    pass "DDEV configuration created"
else
    # Update project name in existing config
    if [ -f "$PROJECT_ROOT/.ddev/config.yaml" ]; then
        # Use sed to update the project name
        if grep -q "^name:" "$PROJECT_ROOT/.ddev/config.yaml" 2>/dev/null; then
            sed -i "s/^name:.*/name: $DDEV_PROJECT/" "$PROJECT_ROOT/.ddev/config.yaml"
            pass "Updated DDEV project name to: $DDEV_PROJECT"
        fi
    fi
fi

################################################################################
# Start DDEV
################################################################################

info "Starting DDEV environment..."
ddev start
pass "DDEV environment started"

################################################################################
# Install dependencies
################################################################################

info "Installing Composer dependencies (production mode)..."
ddev composer install --no-dev --optimize-autoloader
pass "Composer dependencies installed"

# Handle npm if package.json exists
if [ -f "$PROJECT_ROOT/package.json" ]; then
    info "Installing npm dependencies..."
    ddev npm ci
    pass "npm dependencies installed"

    info "Building frontend assets..."
    ddev npm run build
    pass "Frontend assets built"
else
    info "No package.json found, skipping npm steps"
fi

################################################################################
# Import and prepare database
################################################################################

DB_DUMP="$PROJECT_ROOT/.data/db.sql.gz"

if [ -f "$DB_DUMP" ]; then
    info "Importing database from .data/db.sql.gz..."
    ddev import-db --src="$DB_DUMP"
    pass "Database imported"

    # Run Drupal deployment tasks
    info "Running Drupal deployment tasks (updb, cim, cr)..."
    ddev drush deploy -y
    pass "Drupal deployment completed"

    # Sanitize data for preview environment
    info "Sanitizing preview environment data..."

    # Disable outbound email
    ddev drush config-set system.mail interface.default test_mail_collector -y 2>/dev/null || true

    # Clear caches
    ddev drush cr

    pass "Preview environment sanitized"
else
    warn "No database dump found at .data/db.sql.gz"
    info "Creating fresh Drupal installation..."

    # Install Drupal from scratch
    ddev drush site:install --existing-config -y || \
    ddev drush site:install standard --site-name="Preview $ENV_NAME" -y

    pass "Fresh Drupal installation completed"
fi

################################################################################
# Environment-specific configuration
################################################################################

info "Configuring preview environment settings..."

# Set environment indicator
ddev drush config-set environment_indicator.indicator name "Preview: $ENV_NAME" -y 2>/dev/null || true
ddev drush config-set environment_indicator.indicator bg_color "#FFA500" -y 2>/dev/null || true
ddev drush config-set environment_indicator.indicator fg_color "#000000" -y 2>/dev/null || true

# Disable cron (don't want preview environments running cron)
ddev drush config-set automated_cron.settings interval 0 -y 2>/dev/null || true

# Disable search indexing if using Search API
ddev drush config-set search_api.settings cron_limit 0 -y 2>/dev/null || true

pass "Preview environment configured"

################################################################################
# Get preview URL
################################################################################

info "Retrieving preview environment URL..."

# Get the DDEV URL
PREVIEW_URL=$(ddev describe -j | grep -oP '"url":\s*"\K[^"]+' | head -1 || echo "")

if [ -z "$PREVIEW_URL" ]; then
    # Fallback to constructed URL
    PREVIEW_URL="https://${DDEV_PROJECT}.ddev.site"
fi

################################################################################
# Output summary
################################################################################

echo ""
print_header "Preview Environment Ready"
echo ""
pass "Environment name: $ENV_NAME"
pass "DDEV project: $DDEV_PROJECT"
pass "Preview URL: $PREVIEW_URL"
echo ""

# Export URL for CI/CD systems
if [ -n "$GITHUB_OUTPUT" ]; then
    echo "preview_url=$PREVIEW_URL" >> "$GITHUB_OUTPUT"
fi

if [ -n "$CI_PROJECT_DIR" ]; then
    echo "PREVIEW_URL=$PREVIEW_URL" >> "$CI_PROJECT_DIR/preview.env"
fi

# Create a simple status file
cat > "$PROJECT_ROOT/.preview-env" <<EOF
PREVIEW_ENV_NAME=$ENV_NAME
PREVIEW_DDEV_PROJECT=$DDEV_PROJECT
PREVIEW_URL=$PREVIEW_URL
PREVIEW_CREATED=$(date -Iseconds)
EOF

pass "Preview environment created successfully"

echo ""
info "Access your preview environment at:"
echo "  $PREVIEW_URL"
echo ""
info "To stop this environment later, run:"
echo "  ./scripts/ci/cleanup-preview.sh $ENV_NAME"
echo ""
