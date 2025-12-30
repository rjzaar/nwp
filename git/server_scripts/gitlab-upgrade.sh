#!/bin/bash

################################################################################
# gitlab-upgrade.sh - Safely Upgrade GitLab
################################################################################
#
# Performs a safe GitLab upgrade with automatic backup and rollback capability.
# This script runs ON the GitLab server.
#
# Usage:
#   ./gitlab-upgrade.sh [OPTIONS]
#
# Options:
#   --target-version VER Target GitLab version (optional)
#   --skip-backup        Skip pre-upgrade backup (not recommended)
#   --yes                Skip confirmation prompts
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
TARGET_VERSION=""
SKIP_BACKUP=false
AUTO_YES=false
BACKUP_TIMESTAMP=""

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
    echo -e "${GREEN}[OK]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_error() {
    echo -e "${RED}ERROR:${NC} $1"
}

confirm() {
    if [ "$AUTO_YES" = true ]; then
        return 0
    fi

    local prompt="$1"
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
        --target-version)
            TARGET_VERSION="$2"
            shift 2
            ;;
        --skip-backup)
            SKIP_BACKUP=true
            shift
            ;;
        --yes)
            AUTO_YES=true
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

print_header "GitLab Upgrade"

# Check if running as root or with sudo
if [ "$EUID" -ne 0 ] && ! sudo -n true 2>/dev/null; then
    print_error "This script requires sudo privileges"
    print_info "Run with: sudo ./gitlab-upgrade.sh"
    exit 1
fi

# Get current version
print_info "Checking current GitLab version..."
CURRENT_VERSION=$(sudo gitlab-rake gitlab:env:info | grep "GitLab:" | awk '{print $2}' | head -n1)

if [ -z "$CURRENT_VERSION" ]; then
    print_error "Could not determine current GitLab version"
    exit 1
fi

print_success "Current version: $CURRENT_VERSION"

# Check available updates
print_info "Checking for available updates..."
sudo apt-get update

AVAILABLE_VERSION=$(apt-cache policy gitlab-ce | grep "Candidate:" | awk '{print $2}')
print_info "Available version: $AVAILABLE_VERSION"

if [ "$CURRENT_VERSION" = "$AVAILABLE_VERSION" ]; then
    print_success "GitLab is already up to date!"
    exit 0
fi

echo ""
print_warning "Upgrade Information:"
echo "  From: $CURRENT_VERSION"
echo "  To: $AVAILABLE_VERSION"
echo ""
print_warning "IMPORTANT: Review the upgrade path at:"
echo "  https://docs.gitlab.com/ee/update/"
echo ""

if ! confirm "Continue with upgrade?"; then
    print_info "Upgrade cancelled"
    exit 0
fi

# Create backup unless skipped
if [ "$SKIP_BACKUP" = false ]; then
    print_header "Creating Backup"

    print_info "Creating pre-upgrade backup..."
    print_info "This may take several minutes..."

    # Use the backup script if available
    if [ -f "./gitlab-backup.sh" ]; then
        ./gitlab-backup.sh
    else
        sudo gitlab-backup create
    fi

    # Get backup timestamp
    BACKUP_FILE=$(sudo ls -t /var/opt/gitlab/backups/*.tar | head -n1)
    BACKUP_TIMESTAMP=$(basename "$BACKUP_FILE" | sed 's/_gitlab_backup.tar$//')

    print_success "Backup created: $BACKUP_TIMESTAMP"
    print_info "Backup location: $BACKUP_FILE"
else
    print_warning "Skipping backup (not recommended!)"
fi

# Perform upgrade
print_header "Upgrading GitLab"

print_info "Upgrading GitLab CE..."
print_info "This may take 10-15 minutes..."

if [ -n "$TARGET_VERSION" ]; then
    print_info "Installing specific version: $TARGET_VERSION"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "gitlab-ce=$TARGET_VERSION"
else
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y gitlab-ce
fi

print_success "Package installed"

# Reconfigure GitLab
print_info "Reconfiguring GitLab..."
sudo gitlab-ctl reconfigure

# Restart services
print_info "Restarting GitLab..."
sudo gitlab-ctl restart

# Wait for services to start
print_info "Waiting for services to start..."
sleep 15

# Verify upgrade
print_header "Verifying Upgrade"

print_info "Running health check..."
if sudo gitlab-rake gitlab:check SANITIZE=true; then
    print_success "Health check passed!"

    # Get new version
    NEW_VERSION=$(sudo gitlab-rake gitlab:env:info | grep "GitLab:" | awk '{print $2}' | head -n1)
    print_success "Upgraded to version: $NEW_VERSION"

    print_header "Upgrade Complete!"

    echo "Upgrade Summary:"
    echo "  Previous: $CURRENT_VERSION"
    echo "  Current: $NEW_VERSION"
    if [ -n "$BACKUP_TIMESTAMP" ]; then
        echo "  Backup: $BACKUP_TIMESTAMP"
    fi
    echo ""
    echo "Verification:"
    echo "  1. Access GitLab UI and verify functionality"
    echo "  2. Test repositories, CI/CD, and other features"
    echo "  3. Check for any errors in logs: sudo gitlab-ctl tail"
    echo ""
    if [ -n "$BACKUP_TIMESTAMP" ]; then
        echo "If issues occur, rollback with:"
        echo "  sudo ./gitlab-restore.sh --backup $BACKUP_TIMESTAMP"
        echo ""
    fi
    print_success "Upgrade successful!"
else
    print_error "Health check failed!"
    print_warning "GitLab may not be functioning correctly"
    echo ""

    if [ -n "$BACKUP_TIMESTAMP" ]; then
        print_warning "A backup was created before upgrade: $BACKUP_TIMESTAMP"
        echo ""
        if confirm "Do you want to rollback to the previous version?"; then
            print_info "Rolling back..."

            if [ -f "./gitlab-restore.sh" ]; then
                ./gitlab-restore.sh --backup "$BACKUP_TIMESTAMP" --yes
            else
                print_error "gitlab-restore.sh not found"
                print_info "Manual rollback:"
                echo "  1. sudo gitlab-backup restore BACKUP=$BACKUP_TIMESTAMP"
                echo "  2. sudo gitlab-ctl reconfigure"
                echo "  3. sudo gitlab-ctl restart"
            fi
        fi
    else
        print_error "No backup available for rollback"
        print_info "Check logs for errors: sudo gitlab-ctl tail"
    fi

    exit 1
fi
