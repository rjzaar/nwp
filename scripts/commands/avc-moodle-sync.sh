#!/bin/bash
set -euo pipefail

################################################################################
# NWP AVC-Moodle Sync Script
#
# Manually trigger role/cohort synchronization between AVC and Moodle
#
# Usage: pl avc-moodle-sync <avc-site> <moodle-site> [OPTIONS]
################################################################################

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

# Source shared libraries
source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/avc-moodle.sh"

# Script start time
START_TIME=$(date +%s)

################################################################################
# Main Script Logic
################################################################################

# Show help
show_help() {
    cat << EOF
${BOLD}NWP AVC-Moodle Sync Script${NC}

Manually trigger role and cohort synchronization from AVC to Moodle.

${BOLD}USAGE:${NC}
    pl avc-moodle-sync <avc-site> <moodle-site> [OPTIONS]

${BOLD}ARGUMENTS:${NC}
    avc-site        Name of the AVC/OpenSocial site
    moodle-site     Name of the Moodle site

${BOLD}OPTIONS:${NC}
    -h, --help          Show this help message
    -d, --debug         Enable debug output
    --full              Full sync (all users and guilds)
    --guild=NAME        Sync specific guild only
    --user=ID           Sync specific user only
    --dry-run           Show what would be synced without doing it
    -v, --verbose       Verbose output

${BOLD}EXAMPLES:${NC}
    pl avc-moodle-sync avc ss --full
    pl avc-moodle-sync avc ss --guild=web-dev
    pl avc-moodle-sync avc ss --user=123
    pl avc-moodle-sync avc ss --full --dry-run

${BOLD}SYNC MODES:${NC}
    --full              Synchronize all users in all guilds
    --guild=NAME        Synchronize only members of specified guild
    --user=ID           Synchronize only specified user's guild memberships

EOF
}

# Parse command line arguments
DRY_RUN=false
VERBOSE=false
SYNC_MODE="full"
GUILD_NAME=""
USER_ID=""

# Parse options
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -d|--debug)
            DEBUG=true
            shift
            ;;
        --full)
            SYNC_MODE="full"
            shift
            ;;
        --guild=*)
            SYNC_MODE="guild"
            GUILD_NAME="${1#*=}"
            shift
            ;;
        --user=*)
            SYNC_MODE="user"
            USER_ID="${1#*=}"
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -*)
            print_error "Unknown option: $1"
            show_help
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

# Check required arguments
if [[ $# -lt 2 ]]; then
    print_error "Missing required arguments"
    show_help
    exit 1
fi

AVC_SITE=$1
MOODLE_SITE=$2

# Validate site names
if ! validate_sitename "$AVC_SITE" "AVC site name"; then
    exit 1
fi

if ! validate_sitename "$MOODLE_SITE" "Moodle site name"; then
    exit 1
fi

# Display header
print_header "AVC-Moodle Sync"
print_info "AVC Site: $AVC_SITE"
print_info "Moodle Site: $MOODLE_SITE"
print_info "Mode: $SYNC_MODE"

if [[ "$DRY_RUN" == "true" ]]; then
    print_warning "DRY RUN MODE - No changes will be made"
fi
echo ""

# Validate both sites
print_section "Validating sites"
if ! avc_moodle_validate_avc_site "$AVC_SITE"; then
    print_error "AVC site validation failed"
    exit 1
fi

if ! avc_moodle_validate_moodle_site "$MOODLE_SITE"; then
    print_error "Moodle site validation failed"
    exit 1
fi

# Get site directory
AVC_DIR=$(get_site_directory "$AVC_SITE")
cd "$AVC_DIR" || exit 1

# Check if sync module is enabled
print_section "Checking sync module status"

if ! ddev drush pm:list --status=enabled 2>/dev/null | grep -q "avc_moodle_sync"; then
    print_error "avc_moodle_sync module is not enabled"
    print_info "Run: ddev drush en -y avc_moodle_sync"
    exit 1
fi

print_success "avc_moodle_sync module is enabled"

# Run sync based on mode
print_section "Running synchronization"

DRUSH_CMD="ddev drush avc-moodle:sync"

if [[ "$DRY_RUN" == "true" ]]; then
    DRUSH_CMD="$DRUSH_CMD --dry-run"
fi

if [[ "$VERBOSE" == "true" ]]; then
    DRUSH_CMD="$DRUSH_CMD --verbose"
fi

case $SYNC_MODE in
    full)
        print_info "Syncing all users and guilds..."
        $DRUSH_CMD --full
        ;;
    guild)
        print_info "Syncing guild: $GUILD_NAME"
        $DRUSH_CMD --guild="$GUILD_NAME"
        ;;
    user)
        print_info "Syncing user: $USER_ID"
        $DRUSH_CMD --user="$USER_ID"
        ;;
esac

# Display results
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo ""
print_success "Synchronization completed in ${DURATION}s"

# Show updated status
echo ""
print_info "Updated integration status:"
avc_moodle_display_status "$AVC_SITE" "$MOODLE_SITE"

exit 0
