#!/usr/bin/env bash
set -e

################################################################################
# CI/CD Preview Environment Cleanup Script
#
# Cleans up an isolated preview environment created for pull/merge requests
# Stops and removes DDEV project and associated resources
#
# Usage: ./scripts/ci/cleanup-preview.sh <environment-name>
# Example: ./scripts/ci/cleanup-preview.sh pr-123
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

info "Cleaning up preview environment: $ENV_NAME"

################################################################################
# Determine DDEV project name
################################################################################

DDEV_PROJECT="${ENV_NAME}"

info "Target DDEV project: $DDEV_PROJECT"

################################################################################
# Check if environment exists
################################################################################

# Check if this is the current DDEV project
CURRENT_PROJECT=""
if ddev describe >/dev/null 2>&1; then
    CURRENT_PROJECT=$(ddev describe -j | grep -oP '"name":\s*"\K[^"]+' | head -1 || echo "")
fi

if [ "$CURRENT_PROJECT" != "$DDEV_PROJECT" ]; then
    # Try to find the project in DDEV's global list
    if ddev list | grep -q "$DDEV_PROJECT"; then
        info "Found DDEV project in global list"
    else
        warn "DDEV project '$DDEV_PROJECT' not found in current directory or global list"
        info "It may have already been cleaned up or never existed"

        # Clean up any leftover files anyway
        if [ -f "$PROJECT_ROOT/.preview-env" ]; then
            rm -f "$PROJECT_ROOT/.preview-env"
            pass "Removed preview environment metadata"
        fi

        pass "Cleanup completed (no active environment found)"
        exit 0
    fi
fi

################################################################################
# Stop and remove DDEV project
################################################################################

info "Stopping DDEV project..."

# Stop DDEV
if ddev stop >/dev/null 2>&1; then
    pass "DDEV project stopped"
else
    warn "Could not stop DDEV project (it may already be stopped)"
fi

# Delete DDEV project and data
info "Removing DDEV project and databases..."

# Use DDEV delete to remove project completely
# The -O flag omits the snapshot, -y skips confirmation
if ddev delete -O -y >/dev/null 2>&1; then
    pass "DDEV project deleted"
else
    warn "Could not delete DDEV project (it may have already been removed)"
fi

################################################################################
# Clean up environment files
################################################################################

info "Cleaning up environment metadata..."

# Remove preview environment file
if [ -f "$PROJECT_ROOT/.preview-env" ]; then
    rm -f "$PROJECT_ROOT/.preview-env"
    pass "Removed .preview-env file"
fi

# Remove any CI-specific environment files
if [ -f "$PROJECT_ROOT/preview.env" ]; then
    rm -f "$PROJECT_ROOT/preview.env"
    pass "Removed preview.env file"
fi

################################################################################
# Optional: Clean up DNS/routing if configured
################################################################################

# If you have custom DNS or routing configured for preview environments,
# add cleanup commands here. For example:
#
# if command -v cleanup-preview-dns >/dev/null 2>&1; then
#     info "Cleaning up DNS entries..."
#     cleanup-preview-dns "$ENV_NAME"
#     pass "DNS cleanup completed"
# fi

################################################################################
# Optional: Clean up reverse proxy configuration
################################################################################

# If using a reverse proxy (nginx, Traefik, etc.) for preview environments:
#
# if [ -f "/etc/nginx/sites-enabled/${ENV_NAME}.conf" ]; then
#     info "Removing nginx configuration..."
#     sudo rm -f "/etc/nginx/sites-enabled/${ENV_NAME}.conf"
#     sudo nginx -s reload
#     pass "nginx configuration removed"
# fi

################################################################################
# Output summary
################################################################################

echo ""
print_header "Preview Environment Cleanup Complete"
echo ""
pass "Environment name: $ENV_NAME"
pass "DDEV project removed: $DDEV_PROJECT"
echo ""

info "The preview environment has been successfully cleaned up"
echo ""
