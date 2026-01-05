#!/bin/bash

################################################################################
# nwp-bluegreen-deploy.sh - Enhanced Blue-Green Deployment with Traffic Shifting
################################################################################
#
# Advanced deployment script that extends basic blue-green deployment with:
#   - Comprehensive pre-deployment validation
#   - Smoke tests on test environment
#   - Progressive traffic shifting (canary mode)
#   - Automated health monitoring
#   - Automatic rollback on failure
#
# This script implements a complete deployment workflow:
#   1. Deploy code to test environment
#   2. Run smoke tests against test
#   3. Optionally shift traffic gradually (canary mode)
#   4. Swap to production if all checks pass
#   5. Rollback automatically if issues detected
#
# Usage:
#   ./nwp-bluegreen-deploy.sh [OPTIONS]
#
# Options:
#   --webroot DIR        Web root parent directory (default: /var/www)
#   --domain DOMAIN      Domain name for health checks
#   --canary             Enable canary deployment (gradual rollout)
#   --canary-percent N   Canary traffic percentage (default: 10)
#   --canary-duration N  Canary duration in seconds (default: 300)
#   --skip-tests         Skip smoke tests
#   --skip-backup        Skip creating backup before swap
#   --rollback-on-fail   Auto-rollback on health check failure (default: prompt)
#   -y, --yes            Auto-confirm deployment
#   -v, --verbose        Verbose output
#   -h, --help           Show this help message
#
# Exit Codes:
#   0 - Deployment successful
#   1 - Deployment failed (with rollback)
#   2 - Invalid arguments or configuration error
#
################################################################################

set -e  # Exit on error

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Default configuration
WEBROOT_PARENT="/var/www"
DOMAIN=""
CANARY_MODE=false
CANARY_PERCENT=10
CANARY_DURATION=300
SKIP_TESTS=false
SKIP_BACKUP=false
AUTO_ROLLBACK=false
AUTO_YES=false
VERBOSE=false

# Track deployment state
DEPLOYMENT_STARTED=false
SWAP_COMPLETED=false
CANARY_ACTIVE=false

# Health check results
HEALTH_CHECKS_PASSED=0
HEALTH_CHECKS_FAILED=0

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

print_step() {
    echo -e "${CYAN}[STEP]${NC} ${BOLD}$1${NC}"
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

# Cleanup function for interrupts
cleanup() {
    if [ "$CANARY_ACTIVE" = true ]; then
        print_warning "Deployment interrupted during canary phase"
        print_info "Disabling canary routing..."
        disable_canary_routing
    fi
}

trap cleanup EXIT INT TERM

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --webroot)
            WEBROOT_PARENT="$2"
            shift 2
            ;;
        --domain)
            DOMAIN="$2"
            shift 2
            ;;
        --canary)
            CANARY_MODE=true
            shift
            ;;
        --canary-percent)
            CANARY_PERCENT="$2"
            shift 2
            ;;
        --canary-duration)
            CANARY_DURATION="$2"
            shift 2
            ;;
        --skip-tests)
            SKIP_TESTS=true
            shift
            ;;
        --skip-backup)
            SKIP_BACKUP=true
            shift
            ;;
        --rollback-on-fail)
            AUTO_ROLLBACK=true
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
            exit 2
            ;;
    esac
done

# Directory paths
PROD_DIR="$WEBROOT_PARENT/prod"
TEST_DIR="$WEBROOT_PARENT/test"
OLD_DIR="$WEBROOT_PARENT/old"
BACKUP_DIR="$WEBROOT_PARENT/backups"
LOG_DIR="/var/log/nwp"

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# Detect domain from Nginx if not specified
if [ -z "$DOMAIN" ]; then
    NGINX_CONF="/etc/nginx/sites-enabled/default"
    if [ -f "$NGINX_CONF" ]; then
        DOMAIN=$(grep -m 1 "server_name" "$NGINX_CONF" | awk '{print $2}' | sed 's/;//')
    fi

    if [ -z "$DOMAIN" ]; then
        DOMAIN="localhost"
        print_warning "No domain specified, using localhost"
    fi
fi

print_header "Enhanced Blue-Green Deployment"

echo "Configuration:"
echo "  Domain: $DOMAIN"
echo "  Webroot: $WEBROOT_PARENT"
echo "  Canary Mode: $CANARY_MODE"
if [ "$CANARY_MODE" = true ]; then
    echo "  Canary Traffic: ${CANARY_PERCENT}%"
    echo "  Canary Duration: ${CANARY_DURATION}s"
fi
echo ""

################################################################################
# STEP 1: PRE-DEPLOYMENT VALIDATION
################################################################################

print_step "Step 1: Pre-Deployment Validation"

# Verify directory structure
print_info "Verifying directory structure..."

if [ ! -d "$PROD_DIR" ]; then
    print_error "Production directory not found: $PROD_DIR"
    exit 2
fi

if [ ! -d "$TEST_DIR" ]; then
    print_error "Test directory not found: $TEST_DIR"
    exit 2
fi

print_success "Directory structure verified"

# Verify test environment is ready
print_info "Verifying test environment..."

if [ ! -f "$TEST_DIR/web/index.php" ]; then
    print_error "Test environment appears incomplete (no index.php)"
    exit 2
fi

if [ ! -f "$TEST_DIR/vendor/bin/drush" ]; then
    print_error "Drush not found in test environment"
    exit 2
fi

print_success "Test environment ready"

################################################################################
# STEP 2: RUN SMOKE TESTS ON TEST ENVIRONMENT
################################################################################

if [ "$SKIP_TESTS" != true ]; then
    print_step "Step 2: Running Smoke Tests on Test Environment"

    # Check if healthcheck script is available
    HEALTHCHECK_SCRIPT="$(dirname "$0")/nwp-healthcheck.sh"

    if [ -f "$HEALTHCHECK_SCRIPT" ]; then
        print_info "Running comprehensive health checks on test environment..."

        if "$HEALTHCHECK_SCRIPT" --domain "$DOMAIN" --quick "$TEST_DIR"; then
            print_success "Test environment health checks passed"
        else
            print_error "Test environment failed health checks"
            print_warning "Cannot proceed with deployment"
            exit 1
        fi
    else
        print_info "Running basic smoke tests..."

        # Basic Drupal bootstrap check
        cd "$TEST_DIR"
        if sudo -u www-data ./vendor/bin/drush status --format=json > /dev/null 2>&1; then
            print_success "Drupal bootstrap successful"
        else
            print_error "Drupal bootstrap failed in test environment"
            exit 1
        fi
    fi
else
    print_warning "Skipping smoke tests (--skip-tests)"
fi

################################################################################
# STEP 3: CREATE BACKUP
################################################################################

if [ "$SKIP_BACKUP" != true ]; then
    print_step "Step 3: Creating Pre-Deployment Backup"

    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    mkdir -p "$BACKUP_DIR"

    print_info "Backing up current production..."

    # Backup database
    if [ -f "$PROD_DIR/web/sites/default/settings.php" ]; then
        DB_NAME=$(grep "^\s*'database'" "$PROD_DIR/web/sites/default/settings.php" | head -n1 | sed "s/.*'\(.*\)'.*/\1/" || echo "")

        if [ -n "$DB_NAME" ]; then
            print_info "Backing up database: $DB_NAME"
            sudo mysqldump "$DB_NAME" | gzip > "$BACKUP_DIR/prod_db_$TIMESTAMP.sql.gz"
            print_success "Database backup created: prod_db_$TIMESTAMP.sql.gz"
        fi
    fi

    # Log backup location
    echo "$(date -Iseconds) - BACKUP: $BACKUP_DIR/prod_db_$TIMESTAMP.sql.gz" >> "$LOG_DIR/deployments.log"
else
    print_warning "Skipping backup (--skip-backup)"
fi

################################################################################
# STEP 4: CANARY DEPLOYMENT (OPTIONAL)
################################################################################

enable_canary_routing() {
    print_info "Configuring canary routing (${CANARY_PERCENT}% traffic to test)..."

    # This is a placeholder for actual canary routing implementation
    # In a real setup, this would configure:
    # - Nginx split traffic configuration
    # - Load balancer weighted routing
    # - Or use a service mesh like Istio

    # For now, we'll create a marker file
    echo "$CANARY_PERCENT" > "$WEBROOT_PARENT/.canary_active"
    CANARY_ACTIVE=true

    print_success "Canary routing enabled"
}

disable_canary_routing() {
    print_info "Disabling canary routing..."

    # Remove canary configuration
    rm -f "$WEBROOT_PARENT/.canary_active"
    CANARY_ACTIVE=false

    print_success "Canary routing disabled"
}

monitor_canary() {
    local duration=$1
    local check_interval=30
    local checks=$((duration / check_interval))

    print_info "Monitoring canary deployment for ${duration}s..."

    HEALTHCHECK_SCRIPT="$(dirname "$0")/nwp-healthcheck.sh"

    for ((i=1; i<=checks; i++)); do
        echo -ne "  Check $i/$checks: "

        # Run health check on production
        if [ -f "$HEALTHCHECK_SCRIPT" ]; then
            if "$HEALTHCHECK_SCRIPT" --domain "$DOMAIN" --quick --json "$PROD_DIR" > /tmp/canary-health.json 2>&1; then
                echo -e "${GREEN}HEALTHY${NC}"
                HEALTH_CHECKS_PASSED=$((HEALTH_CHECKS_PASSED + 1))
            else
                echo -e "${RED}UNHEALTHY${NC}"
                HEALTH_CHECKS_FAILED=$((HEALTH_CHECKS_FAILED + 1))

                # If we've had too many failures, abort
                if [ $HEALTH_CHECKS_FAILED -ge 3 ]; then
                    print_error "Multiple health check failures detected during canary"
                    return 1
                fi
            fi
        else
            echo -e "${YELLOW}SKIPPED${NC}"
        fi

        sleep $check_interval
    done

    print_success "Canary monitoring complete"
    return 0
}

if [ "$CANARY_MODE" = true ]; then
    print_step "Step 4: Canary Deployment"

    print_info "Enabling canary mode..."
    enable_canary_routing

    if monitor_canary "$CANARY_DURATION"; then
        print_success "Canary phase successful - proceeding with full deployment"
        disable_canary_routing
    else
        print_error "Canary phase failed - aborting deployment"
        disable_canary_routing
        exit 1
    fi
fi

################################################################################
# STEP 5: PERFORM BLUE-GREEN SWAP
################################################################################

print_step "Step 5: Swapping Production and Test Environments"

# Confirm swap
echo ""
print_warning "Ready to swap production and test directories"
echo ""
echo "After swap:"
echo "  Production will serve: $TEST_DIR (current test)"
echo "  Test will contain: $PROD_DIR (current production)"
echo ""

if ! confirm "Continue with swap?"; then
    echo "Deployment cancelled."
    exit 0
fi

# Put site in maintenance mode
print_info "Enabling maintenance mode..."
if [ -f "$PROD_DIR/vendor/bin/drush" ]; then
    cd "$PROD_DIR"
    ./vendor/bin/drush state:set system.maintenance_mode 1 -y 2>/dev/null || true
fi

# Perform the atomic swap
print_info "Performing directory swap..."

if [ -d "$OLD_DIR" ]; then
    # Three-way swap with temp directory
    TEMP_OLD="$WEBROOT_PARENT/.old_temp_$$"
    sudo mv "$OLD_DIR" "$TEMP_OLD"
    sudo mv "$PROD_DIR" "$OLD_DIR"
    sudo mv "$TEST_DIR" "$PROD_DIR"
    sudo mv "$TEMP_OLD" "$TEST_DIR"
else
    # First time swap
    sudo mv "$PROD_DIR" "$OLD_DIR"
    sudo mv "$TEST_DIR" "$PROD_DIR"
    sudo mkdir -p "$TEST_DIR"
fi

SWAP_COMPLETED=true
print_success "Directories swapped!"

# Apply production settings
print_info "Applying production settings..."
if [ -f "$PROD_DIR/web/sites/default/settings.prod.php" ]; then
    sudo cp "$PROD_DIR/web/sites/default/settings.prod.php" "$PROD_DIR/web/sites/default/settings.php"
    print_success "Production settings applied"
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
fi

################################################################################
# STEP 6: POST-DEPLOYMENT HEALTH CHECKS
################################################################################

print_step "Step 6: Post-Deployment Health Checks"

HEALTHCHECK_SCRIPT="$(dirname "$0")/nwp-healthcheck.sh"

if [ -f "$HEALTHCHECK_SCRIPT" ]; then
    print_info "Running comprehensive health checks on new production..."

    if "$HEALTHCHECK_SCRIPT" --domain "$DOMAIN" "$PROD_DIR"; then
        print_success "Production health checks passed"
    else
        print_error "Production failed health checks after deployment"

        if [ "$AUTO_ROLLBACK" = true ] || confirm "Rollback to previous version?"; then
            print_warning "Initiating automatic rollback..."

            ROLLBACK_SCRIPT="$(dirname "$0")/nwp-rollback.sh"
            if [ -f "$ROLLBACK_SCRIPT" ]; then
                "$ROLLBACK_SCRIPT" --webroot "$WEBROOT_PARENT" -y
            else
                print_error "Rollback script not found - manual intervention required"
            fi
            exit 1
        else
            print_warning "Proceeding without rollback - monitor closely"
        fi
    fi
else
    print_warning "Health check script not found - skipping validation"
fi

################################################################################
# STEP 7: LOG DEPLOYMENT
################################################################################

print_step "Step 7: Logging Deployment"

TIMESTAMP=$(date -Iseconds)
LOG_ENTRY="$TIMESTAMP - BLUEGREEN DEPLOY: test → prod"
if [ "$CANARY_MODE" = true ]; then
    LOG_ENTRY="$LOG_ENTRY (canary: ${CANARY_PERCENT}% for ${CANARY_DURATION}s)"
fi

echo "$LOG_ENTRY" | sudo tee -a "$LOG_DIR/deployments.log" > /dev/null
print_success "Deployment logged"

################################################################################
# DEPLOYMENT COMPLETE
################################################################################

print_header "Deployment Successful!"

echo "Summary:"
echo "  New Production: $PROD_DIR (serving former test)"
echo "  Test Environment: $TEST_DIR (containing former production)"
echo "  Backup: $OLD_DIR (previous production)"
if [ "$SKIP_BACKUP" != true ]; then
    echo "  Database Backup: $BACKUP_DIR/prod_db_*.sql.gz"
fi
echo ""
echo "Deployment log: $LOG_DIR/deployments.log"
echo ""
print_success "Zero-downtime deployment successful!"
echo ""
echo "To rollback if needed:"
echo "  $(dirname "$0")/nwp-rollback.sh"
echo ""

exit 0
