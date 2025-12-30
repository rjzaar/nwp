#!/bin/bash

################################################################################
# gitlab-restore.sh - Restore GitLab from Backup
################################################################################
#
# Restores GitLab from a backup created with gitlab-backup.sh
# This script runs ON the GitLab server.
#
# Usage:
#   ./gitlab-restore.sh --backup TIMESTAMP [OPTIONS]
#
# Arguments:
#   --backup TIMESTAMP   Backup timestamp (e.g., 1703788800_2024_12_28_16.7.2)
#   --config-backup FILE Config backup tar.gz file
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
BACKUP_TIMESTAMP=""
CONFIG_BACKUP=""
AUTO_YES=false

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
        --backup)
            BACKUP_TIMESTAMP="$2"
            shift 2
            ;;
        --config-backup)
            CONFIG_BACKUP="$2"
            shift 2
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

print_header "GitLab Restore"

# Check if running as root or with sudo
if [ "$EUID" -ne 0 ] && ! sudo -n true 2>/dev/null; then
    print_error "This script requires sudo privileges"
    print_info "Run with: sudo ./gitlab-restore.sh"
    exit 1
fi

# Validate backup timestamp
if [ -z "$BACKUP_TIMESTAMP" ]; then
    print_error "Backup timestamp is required"
    print_info "Usage: $0 --backup TIMESTAMP"
    print_info ""
    print_info "Available backups:"
    sudo ls -1 /var/opt/gitlab/backups/*.tar 2>/dev/null | while read backup; do
        basename "$backup" | sed 's/_gitlab_backup.tar$//'
    done
    exit 1
fi

# Check if backup file exists
BACKUP_FILE="/var/opt/gitlab/backups/${BACKUP_TIMESTAMP}_gitlab_backup.tar"
if [ ! -f "$BACKUP_FILE" ]; then
    print_error "Backup file not found: $BACKUP_FILE"
    print_info "Available backups:"
    sudo ls -1 /var/opt/gitlab/backups/*.tar 2>/dev/null | while read backup; do
        basename "$backup" | sed 's/_gitlab_backup.tar$//'
    done
    exit 1
fi

print_success "Backup file found: $BACKUP_FILE"

# Warning
echo ""
print_warning "WARNING: This will replace all current GitLab data!"
print_warning "All repositories, issues, merge requests, etc. will be replaced"
echo ""
echo "Restore details:"
echo "  Backup: $BACKUP_TIMESTAMP"
echo "  File: $BACKUP_FILE"
if [ -n "$CONFIG_BACKUP" ]; then
    echo "  Config: $CONFIG_BACKUP"
fi
echo ""

if ! confirm "Are you sure you want to continue?"; then
    print_info "Restore cancelled"
    exit 0
fi

# Stop GitLab services
print_info "Stopping GitLab services..."
sudo gitlab-ctl stop puma
sudo gitlab-ctl stop sidekiq
print_success "Services stopped"

# Restore data
print_info "Restoring GitLab data..."
print_info "This may take several minutes..."
sudo gitlab-backup restore BACKUP="$BACKUP_TIMESTAMP" force=yes

print_success "Data restored"

# Restore configuration if provided
if [ -n "$CONFIG_BACKUP" ] && [ -f "$CONFIG_BACKUP" ]; then
    print_info "Restoring configuration..."
    sudo tar -xzf "$CONFIG_BACKUP" -C /
    print_success "Configuration restored"
fi

# Reconfigure GitLab
print_info "Reconfiguring GitLab..."
sudo gitlab-ctl reconfigure

# Restart all services
print_info "Restarting GitLab..."
sudo gitlab-ctl restart

# Wait for services to start
print_info "Waiting for services to start..."
sleep 10

# Run health check
print_info "Running health check..."
sudo gitlab-rake gitlab:check SANITIZE=true || true

print_header "Restore Complete!"

echo "GitLab has been restored from backup: $BACKUP_TIMESTAMP"
echo ""
echo "Verification:"
echo "  1. Check GitLab status: sudo gitlab-ctl status"
echo "  2. Access GitLab UI and verify data"
echo "  3. Test repositories and functionality"
echo ""
print_success "Restore successful!"
