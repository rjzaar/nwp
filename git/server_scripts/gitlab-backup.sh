#!/bin/bash

################################################################################
# gitlab-backup.sh - Backup GitLab Server
################################################################################
#
# Creates a backup of GitLab using built-in backup commands.
# This script runs ON the GitLab server.
#
# Usage:
#   ./gitlab-backup.sh [OPTIONS]
#
# Options:
#   --output DIR         Output directory (default: /var/backups/gitlab)
#   --skip-registry      Skip container registry backup
#   --skip-artifacts     Skip CI artifacts backup
#   --skip-uploads       Skip uploads backup
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
OUTPUT_DIR="/var/backups/gitlab"
SKIP_OPTIONS=""
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
    echo -e "${GREEN}[OK]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_error() {
    echo -e "${RED}ERROR:${NC} $1"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --output)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --skip-registry)
            SKIP_OPTIONS="${SKIP_OPTIONS},registry"
            shift
            ;;
        --skip-artifacts)
            SKIP_OPTIONS="${SKIP_OPTIONS},artifacts"
            shift
            ;;
        --skip-uploads)
            SKIP_OPTIONS="${SKIP_OPTIONS},uploads"
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

# Remove leading comma from SKIP_OPTIONS
SKIP_OPTIONS=$(echo "$SKIP_OPTIONS" | sed 's/^,//')

print_header "GitLab Backup"

# Check if running as root or with sudo
if [ "$EUID" -ne 0 ] && ! sudo -n true 2>/dev/null; then
    print_error "This script requires sudo privileges"
    print_info "Run with: sudo ./gitlab-backup.sh"
    exit 1
fi

TIMESTAMP=$(date +%Y%m%d_%H%M%S)

echo "Configuration:"
echo "  Output: $OUTPUT_DIR"
echo "  Timestamp: $TIMESTAMP"
if [ -n "$SKIP_OPTIONS" ]; then
    echo "  Skipping: $SKIP_OPTIONS"
fi
echo ""

# Create output directory
sudo mkdir -p "$OUTPUT_DIR"

# Backup GitLab data
print_info "Backing up GitLab data..."

if [ -n "$SKIP_OPTIONS" ]; then
    print_info "Skip options: $SKIP_OPTIONS"
    sudo gitlab-backup create SKIP="$SKIP_OPTIONS"
else
    sudo gitlab-backup create
fi

# Get the latest backup filename
BACKUP_FILE=$(sudo ls -t /var/opt/gitlab/backups/*.tar | head -n1)

if [ -f "$BACKUP_FILE" ]; then
    BACKUP_SIZE=$(sudo du -h "$BACKUP_FILE" | cut -f1)
    print_success "GitLab data backup created: $(basename "$BACKUP_FILE") ($BACKUP_SIZE)"
else
    print_error "Backup file not found in /var/opt/gitlab/backups/"
    exit 1
fi

# Backup GitLab configuration
print_info "Backing up GitLab configuration..."

CONFIG_BACKUP="$OUTPUT_DIR/gitlab-config-$TIMESTAMP.tar.gz"
sudo tar -czf "$CONFIG_BACKUP" \
    /etc/gitlab/gitlab.rb \
    /etc/gitlab/gitlab-secrets.json \
    2>/dev/null || true

if [ -f "$CONFIG_BACKUP" ]; then
    CONFIG_SIZE=$(sudo du -h "$CONFIG_BACKUP" | cut -f1)
    print_success "Configuration backup created: $(basename "$CONFIG_BACKUP") ($CONFIG_SIZE)"
fi

# Copy data backup to output directory
if [ "$(dirname "$BACKUP_FILE")" != "$OUTPUT_DIR" ]; then
    print_info "Copying data backup to output directory..."
    sudo cp "$BACKUP_FILE" "$OUTPUT_DIR/"
    print_success "Backup copied to: $OUTPUT_DIR/$(basename "$BACKUP_FILE")"
fi

# Set permissions
sudo chmod 644 "$OUTPUT_DIR"/*.tar* 2>/dev/null || true

# Create backup manifest
MANIFEST="$OUTPUT_DIR/backup-manifest-$TIMESTAMP.txt"
sudo tee "$MANIFEST" > /dev/null << EOF
GitLab Backup Manifest
======================
Date: $(date)
Timestamp: $TIMESTAMP
Hostname: $(hostname)

Files:
  - Data: $(basename "$BACKUP_FILE") ($BACKUP_SIZE)
  - Config: $(basename "$CONFIG_BACKUP") ($CONFIG_SIZE)

GitLab Version:
$(sudo gitlab-rake gitlab:env:info | grep "GitLab information" -A 5)

Restore Instructions:
  1. Copy backups to new server
  2. Place data backup in /var/opt/gitlab/backups/
  3. Extract config backup to /etc/gitlab/
  4. Run: gitlab-backup restore BACKUP=<timestamp>
  5. Reconfigure: gitlab-ctl reconfigure
  6. Restart: gitlab-ctl restart
EOF

print_success "Manifest created: $(basename "$MANIFEST")"

# Calculate total size
TOTAL_SIZE=$(sudo du -sh "$OUTPUT_DIR" | cut -f1)

print_header "Backup Complete!"

echo "Backup Summary:"
echo "  Location: $OUTPUT_DIR"
echo "  Total Size: $TOTAL_SIZE"
echo ""
echo "Files created:"
echo "  - $(basename "$BACKUP_FILE")"
echo "  - $(basename "$CONFIG_BACKUP")"
echo "  - $(basename "$MANIFEST")"
echo ""
echo "To restore this backup:"
echo "  sudo gitlab-backup restore BACKUP=$(basename "$BACKUP_FILE" | sed 's/_gitlab_backup.tar$//')"
echo ""
print_success "Backup successful!"
