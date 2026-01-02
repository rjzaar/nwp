#!/bin/bash
#
# migrate-secrets.sh - Migrate to two-tier secrets architecture
#
# This script helps migrate existing .secrets.yml files to the new
# infrastructure/data split architecture.
#
# Usage:
#   ./migrate-secrets.sh [--dry-run] [--nwp|--site SITENAME]
#
# Options:
#   --dry-run    Show what would be done without making changes
#   --nwp        Migrate NWP root .secrets.yml
#   --site NAME  Migrate a specific site's secrets
#   --all        Migrate NWP and all sites
#
# See docs/DATA_SECURITY_BEST_PRACTICES.md for architecture details.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=false
TARGET=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }

show_help() {
    cat << 'EOF'
migrate-secrets.sh - Migrate to two-tier secrets architecture

USAGE:
    ./migrate-secrets.sh [OPTIONS]

OPTIONS:
    --dry-run       Show what would be done without making changes
    --nwp           Migrate NWP root .secrets.yml
    --site NAME     Migrate a specific site's secrets
    --all           Migrate NWP and all sites
    --check         Check current secrets for data leakage
    --help          Show this help message

EXAMPLES:
    # Check what would be migrated (safe to run)
    ./migrate-secrets.sh --dry-run --nwp

    # Migrate NWP infrastructure secrets
    ./migrate-secrets.sh --nwp

    # Migrate a specific site
    ./migrate-secrets.sh --site avc

    # Check all secrets files for data secrets
    ./migrate-secrets.sh --check

ARCHITECTURE:
    .secrets.yml       - Infrastructure secrets (API tokens, dev credentials)
                         SAFE for AI assistants

    .secrets.data.yml  - Data secrets (prod DB, SSH, SMTP)
                         BLOCKED from AI assistants

DATA SECRETS TO MIGRATE:
    - Production database passwords
    - Production SSH keys/credentials
    - Production SMTP credentials
    - GitLab admin password and SSH key
    - Encryption keys
    - Production API keys (Stripe, etc.)

See docs/DATA_SECURITY_BEST_PRACTICES.md for full documentation.
EOF
}

# Keys that should be in .secrets.data.yml (data secrets)
DATA_SECRET_PATTERNS=(
    "admin_password"
    "root_password"
    "backup_password"
    "ssh_key.*prod"
    "prod.*ssh"
    "production"
    "stripe_secret"
    "encryption"
    "gitlab.*admin"
    "admin.*password"
)

# Check if a line contains a data secret
contains_data_secret() {
    local line="$1"
    for pattern in "${DATA_SECRET_PATTERNS[@]}"; do
        if echo "$line" | grep -qiE "$pattern"; then
            return 0
        fi
    done
    return 1
}

# Check a secrets file for data secrets
check_secrets_file() {
    local file="$1"
    local found_issues=false

    if [ ! -f "$file" ]; then
        return 0
    fi

    log_info "Checking: $file"

    local line_num=0
    while IFS= read -r line; do
        ((line_num++))
        # Skip comments and empty lines
        if [[ "$line" =~ ^[[:space:]]*# ]] || [[ -z "${line// }" ]]; then
            continue
        fi

        if contains_data_secret "$line"; then
            log_warn "  Line $line_num may contain data secret: ${line:0:60}..."
            found_issues=true
        fi
    done < "$file"

    if [ "$found_issues" = false ]; then
        log_success "  No data secrets found"
    fi

    return 0
}

# Check all secrets files
check_all_secrets() {
    log_info "Checking for data secrets in .secrets.yml files..."
    echo ""

    # Check NWP root
    if [ -f "$SCRIPT_DIR/.secrets.yml" ]; then
        check_secrets_file "$SCRIPT_DIR/.secrets.yml"
    fi

    # Check site directories
    for dir in "$SCRIPT_DIR"/*/; do
        if [ -f "${dir}.secrets.yml" ]; then
            check_secrets_file "${dir}.secrets.yml"
        fi
    done

    echo ""
    log_info "Check complete. Review any warnings above."
    log_info "Data secrets should be moved to .secrets.data.yml"
}

# Migrate NWP root secrets
migrate_nwp() {
    local secrets_file="$SCRIPT_DIR/.secrets.yml"
    local data_file="$SCRIPT_DIR/.secrets.data.yml"

    if [ ! -f "$secrets_file" ]; then
        log_warn "No .secrets.yml found at NWP root"
        return 0
    fi

    log_info "Migrating NWP root secrets..."

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would analyze: $secrets_file"
        check_secrets_file "$secrets_file"
        return 0
    fi

    # Create backup
    cp "$secrets_file" "${secrets_file}.bak.$(date +%Y%m%d_%H%M%S)"
    log_success "Created backup of .secrets.yml"

    # Create .secrets.data.yml from template if it doesn't exist
    if [ ! -f "$data_file" ]; then
        if [ -f "$SCRIPT_DIR/.secrets.data.example.yml" ]; then
            cp "$SCRIPT_DIR/.secrets.data.example.yml" "$data_file"
            log_success "Created .secrets.data.yml from template"
        else
            log_error "No .secrets.data.example.yml template found"
            return 1
        fi
    fi

    log_info ""
    log_info "MANUAL STEPS REQUIRED:"
    log_info "1. Review $secrets_file for data secrets"
    log_info "2. Move the following to $data_file:"
    log_info "   - gitlab.admin.password"
    log_info "   - gitlab.server.ssh_key (if for prod access)"
    log_info "   - Any production database passwords"
    log_info "   - Any production SSH credentials"
    log_info "3. Remove moved values from $secrets_file"
    log_info "4. Run: ./migrate-secrets.sh --check"
    log_info ""

    check_secrets_file "$secrets_file"
}

# Migrate site secrets
migrate_site() {
    local site="$1"
    local site_dir="$SCRIPT_DIR/$site"
    local secrets_file="$site_dir/.secrets.yml"
    local data_file="$site_dir/.secrets.data.yml"

    if [ ! -d "$site_dir" ]; then
        log_error "Site directory not found: $site_dir"
        return 1
    fi

    log_info "Migrating site: $site"

    if [ ! -f "$secrets_file" ]; then
        log_warn "No .secrets.yml found for site $site"
        return 0
    fi

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would analyze: $secrets_file"
        check_secrets_file "$secrets_file"
        return 0
    fi

    # Create backup
    cp "$secrets_file" "${secrets_file}.bak.$(date +%Y%m%d_%H%M%S)"
    log_success "Created backup of $site/.secrets.yml"

    # Create .secrets.data.yml from template
    if [ ! -f "$data_file" ]; then
        if [ -f "$SCRIPT_DIR/vortex/templates/.secrets.data.example.yml" ]; then
            cp "$SCRIPT_DIR/vortex/templates/.secrets.data.example.yml" "$data_file"
            log_success "Created $site/.secrets.data.yml from template"
        fi
    fi

    log_info ""
    log_info "MANUAL STEPS for $site:"
    log_info "1. Move production credentials to $data_file"
    log_info "2. Keep only dev/staging credentials in $secrets_file"
    log_info ""

    check_secrets_file "$secrets_file"
}

# Migrate all
migrate_all() {
    log_info "Migrating all secrets files..."
    echo ""

    # Migrate NWP root
    migrate_nwp
    echo ""

    # Migrate each site
    for dir in "$SCRIPT_DIR"/*/; do
        site=$(basename "$dir")
        # Skip non-site directories
        if [[ "$site" == "lib" || "$site" == "vortex" || "$site" == "docs" ||
              "$site" == "git" || "$site" == "email" || "$site" == "sitebackups" ]]; then
            continue
        fi

        if [ -f "${dir}.secrets.yml" ] || [ -f "${dir}.secrets.example.yml" ]; then
            migrate_site "$site"
            echo ""
        fi
    done
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --nwp)
            TARGET="nwp"
            shift
            ;;
        --site)
            TARGET="site"
            SITE_NAME="$2"
            shift 2
            ;;
        --all)
            TARGET="all"
            shift
            ;;
        --check)
            TARGET="check"
            shift
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Main
if [ -z "$TARGET" ]; then
    show_help
    exit 0
fi

echo ""
echo "============================================"
echo "  NWP Secrets Migration Tool"
echo "============================================"
echo ""

if [ "$DRY_RUN" = true ]; then
    log_info "Running in DRY RUN mode - no changes will be made"
    echo ""
fi

case $TARGET in
    nwp)
        migrate_nwp
        ;;
    site)
        if [ -z "$SITE_NAME" ]; then
            log_error "Site name required with --site"
            exit 1
        fi
        migrate_site "$SITE_NAME"
        ;;
    all)
        migrate_all
        ;;
    check)
        check_all_secrets
        ;;
esac

echo ""
log_info "Migration script complete."
log_info "Remember to update ~/.claude/settings.json deny rules."
log_info "Run: ./setup.sh and select 'Claude Code Security Config'"
