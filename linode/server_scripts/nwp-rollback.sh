#!/bin/bash

################################################################################
# nwp-rollback.sh - Rollback Production Deployment
################################################################################
#
# Reverts the last blue-green deployment by swapping directories back.
# This restores the previous production version.
#
# Usage:
#   ./nwp-rollback.sh [OPTIONS]
#
# Options:
#   --webroot DIR        Web root parent directory (default: /var/www)
#   -y, --yes            Auto-confirm rollback
#   -v, --verbose        Verbose output
#   -h, --help           Show this help message
#
################################################################################

set -e  # Exit on error

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

# Default configuration
WEBROOT_PARENT="/var/www"
AUTO_YES=false
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

print_warning() {
    echo -e "${YELLOW}!${NC} $1"
}

print_error() {
    echo -e "${RED}ERROR:${NC} $1"
}

confirm() {
    if [ "$AUTO_YES" = true ]; then
        return 0
    fi

    local prompt="$1"
    local response
    read -p "$prompt [y/N]: " response
    case "$response" in
        [yY][eE][sS]|[yY])
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --webroot)
            WEBROOT_PARENT="$2"
            shift 2
            ;;
        -y|--yes)
            AUTO_YES=true
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
        *)
            print_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Directory paths
PROD_DIR="$WEBROOT_PARENT/prod"
TEST_DIR="$WEBROOT_PARENT/test"
OLD_DIR="$WEBROOT_PARENT/old"

print_header "Production Rollback"

# Verify directories exist
print_info "Verifying directory structure..."

if [ ! -d "$PROD_DIR" ]; then
    print_error "Production directory not found: $PROD_DIR"
    exit 1
fi

if [ ! -d "$TEST_DIR" ]; then
    print_error "Test directory not found: $TEST_DIR"
    print_warning "Nothing to rollback to!"
    exit 1
fi

print_success "Directory structure verified"

# Show current state
echo ""
echo "Current State:"
echo "  Production: $PROD_DIR"
echo "  Test: $TEST_DIR (contains previous production)"
echo ""

# Confirm rollback
print_warning "This will restore the previous production version!"
echo ""
echo "After rollback:"
echo "  Production will serve: $TEST_DIR (previous production)"
echo "  Test will contain: $PROD_DIR (current production)"
echo ""

if ! confirm "Continue with rollback?"; then
    echo "Rollback cancelled."
    exit 0
fi

# Put site in maintenance mode
print_info "Enabling maintenance mode..."
if [ -f "$PROD_DIR/vendor/bin/drush" ]; then
    cd "$PROD_DIR"
    ./vendor/bin/drush state:set system.maintenance_mode 1 -y 2>/dev/null || true
fi

# Perform the reverse swap
print_header "Performing Rollback Swap"

# Swap test back to prod
TEMP_DIR="$WEBROOT_PARENT/.rollback_temp_$$"
sudo mv "$PROD_DIR" "$TEMP_DIR"
sudo mv "$TEST_DIR" "$PROD_DIR"
sudo mv "$TEMP_DIR" "$TEST_DIR"

print_success "Directories swapped!"

# Restore settings files
print_info "Restoring settings files..."

if [ -f "$PROD_DIR/web/sites/default/settings.prod.php" ]; then
    sudo cp "$PROD_DIR/web/sites/default/settings.prod.php" "$PROD_DIR/web/sites/default/settings.php"
    print_success "Production settings restored"
fi

# Fix permissions
print_info "Setting permissions..."
sudo chown -R www-data:www-data "$PROD_DIR"
sudo chown -R www-data:www-data "$TEST_DIR"
print_success "Permissions updated"

# Clear caches
print_info "Clearing caches..."
if [ -f "$PROD_DIR/vendor/bin/drush" ]; then
    cd "$PROD_DIR"
    sudo -u www-data ./vendor/bin/drush cr || print_warning "Cache clear failed (check manually)"
    print_success "Cache cleared"
fi

# Disable maintenance mode
print_info "Disabling maintenance mode..."
if [ -f "$PROD_DIR/vendor/bin/drush" ]; then
    cd "$PROD_DIR"
    ./vendor/bin/drush state:set system.maintenance_mode 0 -y 2>/dev/null || true
    print_success "Site is live"
fi

# Verify rollback
print_info "Verifying production site..."
if [ -f "$PROD_DIR/web/index.php" ]; then
    print_success "Production site verified"
else
    print_error "Production site verification failed!"
fi

# Log the rollback
LOG_FILE="/var/log/nwp-deployments.log"
echo "$(date -Iseconds) - ROLLBACK: Restored previous production version" | sudo tee -a "$LOG_FILE" > /dev/null

print_header "Rollback Complete!"

echo "Previous production version has been restored."
echo ""
print_success "Rollback successful!"
echo ""
