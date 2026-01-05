#!/bin/bash

################################################################################
# nwp-bootstrap.sh - NWP Server Bootstrap Script
################################################################################
#
# Verifies and installs required packages for NWP server deployment.
# This script ensures the server has all necessary components for hosting
# Drupal/OpenSocial sites and can be run on a fresh server or to verify
# an existing installation.
#
# This script runs ON the Linode server.
#
# Usage:
#   ./nwp-bootstrap.sh [OPTIONS]
#
# Options:
#   --reinstall          Force reinstall of all packages
#   --skip-packages      Skip package installation (directory setup only)
#   --webroot DIR        Web root parent directory (default: /var/www)
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
REINSTALL=false
SKIP_PACKAGES=false
WEBROOT_PARENT="/var/www"
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

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --reinstall)
            REINSTALL=true
            shift
            ;;
        --skip-packages)
            SKIP_PACKAGES=true
            shift
            ;;
        --webroot)
            WEBROOT_PARENT="$2"
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
        *)
            print_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

print_header "NWP Server Bootstrap"

# Check if running as root or with sudo
if [[ $EUID -ne 0 ]]; then
   print_error "This script must be run as root or with sudo"
   exit 1
fi

################################################################################
# 1. VERIFY/INSTALL REQUIRED PACKAGES
################################################################################

if [ "$SKIP_PACKAGES" != true ]; then
    print_header "Package Installation"

    print_info "Updating package lists..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq

    # Define required packages
    PACKAGES=(
        # Web server
        "nginx"

        # Database
        "mariadb-server"
        "mariadb-client"

        # PHP 8.2 and extensions
        "php8.2-fpm"
        "php8.2-mysql"
        "php8.2-gd"
        "php8.2-xml"
        "php8.2-mbstring"
        "php8.2-curl"
        "php8.2-zip"
        "php8.2-intl"
        "php8.2-bcmath"
        "php8.2-opcache"
        "php8.2-apcu"

        # SSL/TLS
        "certbot"
        "python3-certbot-nginx"

        # Utilities
        "git"
        "unzip"
        "curl"
        "wget"
        "rsync"
        "htop"
    )

    print_info "Checking for required packages..."
    INSTALL_NEEDED=()

    for pkg in "${PACKAGES[@]}"; do
        if [ "$REINSTALL" = true ] || ! dpkg -l | grep -q "^ii  $pkg "; then
            INSTALL_NEEDED+=("$pkg")
        fi
    done

    if [ ${#INSTALL_NEEDED[@]} -gt 0 ]; then
        print_info "Installing ${#INSTALL_NEEDED[@]} package(s)..."

        if [ "$VERBOSE" = true ]; then
            apt-get install -y "${INSTALL_NEEDED[@]}"
        else
            apt-get install -y "${INSTALL_NEEDED[@]}" > /dev/null 2>&1
        fi

        print_success "Packages installed: ${INSTALL_NEEDED[*]}"
    else
        print_success "All required packages already installed"
    fi

    # Verify critical services
    print_info "Verifying services..."

    for service in nginx mariadb php8.2-fpm; do
        if systemctl is-active --quiet "$service"; then
            print_success "$service is running"
        else
            print_info "Starting $service..."
            systemctl start "$service"
            systemctl enable "$service"
            print_success "$service started and enabled"
        fi
    done
fi

################################################################################
# 2. CREATE DIRECTORY STRUCTURE
################################################################################

print_header "Directory Structure"

# Define directories to create
DIRECTORIES=(
    "$WEBROOT_PARENT/prod"
    "$WEBROOT_PARENT/test"
    "$WEBROOT_PARENT/old"
    "/var/backups/nwp"
    "/var/log/nwp"
)

print_info "Creating directory structure..."

for dir in "${DIRECTORIES[@]}"; do
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir"
        print_success "Created: $dir"
    else
        print_info "Already exists: $dir"
    fi
done

################################################################################
# 3. SET PERMISSIONS
################################################################################

print_header "Permissions"

print_info "Setting directory permissions..."

# Web directories owned by www-data
chown -R www-data:www-data "$WEBROOT_PARENT"
chmod -R 755 "$WEBROOT_PARENT"
print_success "Web directories: www-data:www-data (755)"

# Backup directory - allow nwp user to write
if id "nwp" &>/dev/null; then
    chown -R nwp:nwp /var/backups/nwp
    chmod -R 755 /var/backups/nwp
    print_success "Backup directory: nwp:nwp (755)"
else
    chmod -R 755 /var/backups/nwp
    print_success "Backup directory: (755)"
fi

# Log directory
chmod -R 755 /var/log/nwp
print_success "Log directory: (755)"

################################################################################
# 4. INSTALL NWP SERVER SCRIPTS
################################################################################

print_header "NWP Server Scripts"

# Define script installation directory
SCRIPT_DIR="/usr/local/bin"
SCRIPT_SOURCE="/home/nwp/nwp-scripts"

if [ -d "$SCRIPT_SOURCE" ]; then
    print_info "Installing NWP server scripts to $SCRIPT_DIR..."

    # Install server scripts
    SCRIPTS=(
        "nwp-createsite.sh"
        "nwp-swap-prod.sh"
        "nwp-rollback.sh"
        "nwp-backup.sh"
        "nwp-healthcheck.sh"
        "nwp-audit.sh"
        "nwp-bootstrap.sh"
    )

    INSTALLED=0
    for script in "${SCRIPTS[@]}"; do
        if [ -f "$SCRIPT_SOURCE/$script" ]; then
            cp "$SCRIPT_SOURCE/$script" "$SCRIPT_DIR/$script"
            chmod +x "$SCRIPT_DIR/$script"
            INSTALLED=$((INSTALLED + 1))
            print_success "Installed: $script"
        fi
    done

    if [ $INSTALLED -gt 0 ]; then
        print_success "Installed $INSTALLED server script(s)"
    else
        print_warning "No scripts found in $SCRIPT_SOURCE"
    fi
else
    print_warning "Script source directory not found: $SCRIPT_SOURCE"
    print_info "Scripts can be manually copied to $SCRIPT_DIR later"
fi

################################################################################
# 5. VERIFY INSTALLATION
################################################################################

print_header "Installation Verification"

# Check PHP version
PHP_VERSION=$(php -v | head -n1 | cut -d' ' -f2)
print_info "PHP Version: $PHP_VERSION"

# Check Nginx version
NGINX_VERSION=$(nginx -v 2>&1 | cut -d'/' -f2)
print_info "Nginx Version: $NGINX_VERSION"

# Check MariaDB version
MARIADB_VERSION=$(mysql --version | awk '{print $5}' | sed 's/,$//')
print_info "MariaDB Version: $MARIADB_VERSION"

# Check disk space
DISK_USAGE=$(df -h / | awk 'NR==2 {print $5}')
DISK_AVAIL=$(df -h / | awk 'NR==2 {print $4}')
print_info "Disk Usage: $DISK_USAGE used, $DISK_AVAIL available"

# Verify directory structure
print_info "Verifying directory structure..."
for dir in "${DIRECTORIES[@]}"; do
    if [ -d "$dir" ]; then
        print_success "$dir"
    else
        print_error "$dir - MISSING"
    fi
done

################################################################################
# 6. CREATE INITIAL LOG ENTRIES
################################################################################

print_info "Creating initial log entry..."
/usr/local/bin/nwp-audit.sh \
    --event "bootstrap" \
    --site "server" \
    --user "$(whoami)" \
    --message "Server bootstrap completed successfully" \
    2>/dev/null || echo "$(date -Iseconds) - BOOTSTRAP: Server initialized" >> /var/log/nwp/deployments.log

################################################################################
# COMPLETION
################################################################################

print_header "Bootstrap Complete!"

echo "Server Configuration:"
echo "  Web Root: $WEBROOT_PARENT"
echo "  Backup Dir: /var/backups/nwp"
echo "  Log Dir: /var/log/nwp"
echo ""
echo "Directory Structure:"
echo "  Production: $WEBROOT_PARENT/prod"
echo "  Test: $WEBROOT_PARENT/test"
echo "  Old: $WEBROOT_PARENT/old"
echo ""
echo "Installed Services:"
echo "  Nginx: $NGINX_VERSION"
echo "  PHP: $PHP_VERSION"
echo "  MariaDB: $MARIADB_VERSION"
echo ""
echo "Next Steps:"
echo "  1. Deploy a site: linode_deploy.sh"
echo "  2. Create site config: nwp-createsite.sh"
echo "  3. Set up SSL: certbot --nginx -d yourdomain.com"
echo "  4. Run health check: nwp-healthcheck.sh"
echo ""
print_success "Server is ready for NWP deployments!"
