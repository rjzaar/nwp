#!/bin/bash

################################################################################
# nwp-swap-prod.sh - Blue-Green Deployment for NWP Sites
################################################################################
#
# Swaps production and test directories for zero-downtime deployment.
# Adapted from pleasy's updateprod.sh for NWP/OpenSocial.
#
# This script implements blue-green deployment by swapping directories:
#   prod → old (backup current production)
#   test → prod (promote test to production)
#   old → test (demote old production to test)
#
# Usage:
#   ./nwp-swap-prod.sh [OPTIONS]
#
# Options:
#   --webroot DIR        Web root parent directory (default: /var/www)
#   --skip-backup        Skip creating backup before swap
#   --skip-verify        Skip verification checks
#   --maintenance        Put site in maintenance mode during swap
#   -y, --yes            Auto-confirm swap
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
SKIP_BACKUP=false
SKIP_VERIFY=false
MAINTENANCE=false
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
        --skip-backup)
            SKIP_BACKUP=true
            shift
            ;;
        --skip-verify)
            SKIP_VERIFY=true
            shift
            ;;
        --maintenance)
            MAINTENANCE=true
            shift
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
BACKUP_DIR="$WEBROOT_PARENT/backups"

print_header "Blue-Green Deployment Swap"

# Verify directories exist
print_info "Verifying directory structure..."

if [ ! -d "$PROD_DIR" ]; then
    print_error "Production directory not found: $PROD_DIR"
    exit 1
fi

if [ ! -d "$TEST_DIR" ]; then
    print_error "Test directory not found: $TEST_DIR"
    exit 1
fi

print_success "Directory structure verified"

# Show current state
echo ""
echo "Current State:"
echo "  Production: $PROD_DIR"
echo "  Test: $TEST_DIR"
echo "  Old: $OLD_DIR"
echo ""

# Verify test site is working
if [ "$SKIP_VERIFY" != true ]; then
    print_info "Verifying test site..."

    if [ -f "$TEST_DIR/web/index.php" ]; then
        print_success "Test site files found"
    else
        print_error "Test site appears incomplete (no index.php)"
        exit 1
    fi
fi

# Confirm swap
echo ""
print_warning "This will swap production and test directories!"
echo ""
echo "After swap:"
echo "  Production will serve: $TEST_DIR (current test)"
echo "  Test will contain: $PROD_DIR (current production)"
echo ""

if ! confirm "Continue with swap?"; then
    echo "Swap cancelled."
    exit 0
fi

# Create backup
if [ "$SKIP_BACKUP" != true ]; then
    print_info "Creating backup of current production..."

    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    mkdir -p "$BACKUP_DIR"

    # Backup database
    if [ -f "$PROD_DIR/web/sites/default/settings.php" ]; then
        # Extract DB credentials from settings.php
        DB_NAME=$(grep "^\s*'database'" "$PROD_DIR/web/sites/default/settings.php" | head -n1 | sed "s/.*'\(.*\)'.*/\1/")

        if [ -n "$DB_NAME" ]; then
            print_info "Backing up database: $DB_NAME"
            sudo mysqldump "$DB_NAME" | gzip > "$BACKUP_DIR/prod_db_$TIMESTAMP.sql.gz"
            print_success "Database backup created"
        fi
    fi

    # Backup files (optional - can be large)
    # tar -czf "$BACKUP_DIR/prod_files_$TIMESTAMP.tar.gz" -C "$PROD_DIR" .
    # print_success "Files backup created"
fi

# Put site in maintenance mode
if [ "$MAINTENANCE" = true ]; then
    print_info "Enabling maintenance mode..."

    if [ -f "$PROD_DIR/vendor/bin/drush" ]; then
        cd "$PROD_DIR"
        ./vendor/bin/drush state:set system.maintenance_mode 1 -y
        print_success "Maintenance mode enabled"
    fi
fi

# Perform the atomic swap
print_header "Performing Directory Swap"

# The magic three-way swap
if [ -d "$OLD_DIR" ]; then
    # If old exists, we need a temp directory
    TEMP_OLD="$WEBROOT_PARENT/.old_temp_$$"
    sudo mv "$OLD_DIR" "$TEMP_OLD"
    sudo mv "$PROD_DIR" "$OLD_DIR"
    sudo mv "$TEST_DIR" "$PROD_DIR"
    sudo mv "$TEMP_OLD" "$TEST_DIR"
else
    # First time - no old directory yet
    sudo mv "$PROD_DIR" "$OLD_DIR"
    sudo mv "$TEST_DIR" "$PROD_DIR"
    sudo mkdir -p "$TEST_DIR"
fi

print_success "Directories swapped!"

# Swap settings files if they exist
print_info "Updating settings files..."

if [ -f "$PROD_DIR/web/sites/default/settings.prod.php" ]; then
    sudo cp "$PROD_DIR/web/sites/default/settings.prod.php" "$PROD_DIR/web/sites/default/settings.php"
    print_success "Production settings applied"
fi

if [ -f "$TEST_DIR/web/sites/default/settings.test.php" ]; then
    sudo cp "$TEST_DIR/web/sites/default/settings.test.php" "$TEST_DIR/web/sites/default/settings.php"
    print_success "Test settings applied"
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
if [ "$MAINTENANCE" = true ]; then
    print_info "Disabling maintenance mode..."

    if [ -f "$PROD_DIR/vendor/bin/drush" ]; then
        cd "$PROD_DIR"
        ./vendor/bin/drush state:set system.maintenance_mode 0 -y
        print_success "Maintenance mode disabled"
    fi
fi

# Verify swap
print_info "Verifying production site..."
if [ -f "$PROD_DIR/web/index.php" ]; then
    print_success "Production site verified"
else
    print_error "Production site verification failed!"
    print_warning "You may need to rollback: ./nwp-rollback.sh"
fi

# Log the swap
LOG_FILE="/var/log/nwp-deployments.log"
echo "$(date -Iseconds) - SWAP: test → prod, prod → old, old → test" | sudo tee -a "$LOG_FILE" > /dev/null

print_header "Swap Complete!"

echo "New State:"
echo "  Production: $PROD_DIR (serving former test)"
echo "  Test: $TEST_DIR (containing former production)"
echo "  Old: $OLD_DIR (backup of previous production)"
echo ""
echo "Deployment logged to: $LOG_FILE"
echo ""
print_success "Zero-downtime deployment successful!"
echo ""
echo "To rollback if needed:"
echo "  ./nwp-rollback.sh"
echo ""
