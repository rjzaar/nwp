#!/bin/bash
set -euo pipefail

################################################################################
# NWP AVC-Moodle Status Script
#
# Display integration health dashboard for AVC-Moodle SSO
#
# Usage: pl avc-moodle-status <avc-site> <moodle-site>
################################################################################

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

# Source shared libraries
source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/avc-moodle.sh"

################################################################################
# Main Script Logic
################################################################################

# Show help
show_help() {
    cat << EOF
${BOLD}NWP AVC-Moodle Status Script${NC}

Display integration status and health check for AVC-Moodle SSO.

${BOLD}USAGE:${NC}
    pl avc-moodle-status <avc-site> <moodle-site>

${BOLD}ARGUMENTS:${NC}
    avc-site        Name of the AVC/OpenSocial site
    moodle-site     Name of the Moodle site

${BOLD}OPTIONS:${NC}
    -h, --help      Show this help message
    -d, --debug     Enable debug output

${BOLD}EXAMPLES:${NC}
    pl avc-moodle-status avc ss

${BOLD}OUTPUT:${NC}
    Displays a dashboard showing:
    - SSO status (active/disabled)
    - OAuth2 endpoint health
    - Last sync time
    - Synced user and cohort counts
    - Cache hit rate
    - Site URLs

EOF
}

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

# Validate both sites exist
if ! avc_moodle_validate_avc_site "$AVC_SITE" >/dev/null 2>&1; then
    print_error "AVC site validation failed: $AVC_SITE"
    exit 1
fi

if ! avc_moodle_validate_moodle_site "$MOODLE_SITE" >/dev/null 2>&1; then
    print_error "Moodle site validation failed: $MOODLE_SITE"
    exit 1
fi

# Display status dashboard
avc_moodle_display_status "$AVC_SITE" "$MOODLE_SITE"

exit 0
