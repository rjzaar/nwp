#!/bin/bash
set -euo pipefail

################################################################################
# NWP Email Management Wrapper
#
# Provides unified interface for email setup, testing, and configuration
#
# Usage: pl email <command> [options]
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
EMAIL_DIR="$PROJECT_ROOT/email"

# Source shared libraries
source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh"

show_help() {
    cat << EOF
${BOLD}NWP Email Management${NC}

${BOLD}USAGE:${NC}
    pl email <command> [options]

${BOLD}COMMANDS:${NC}
    setup                   Setup email infrastructure (Postfix, DKIM, SPF)
    add <sitename>          Add email account for a site
    test [sitename]         Test email deliverability
    reroute <sitename>      Configure email rerouting for development
    reroute --disable       Disable email rerouting
    list                    List configured site emails

${BOLD}EXAMPLES:${NC}
    pl email setup                  # Initial server email setup
    pl email add mysite             # Add email for mysite
    pl email test mysite            # Test mysite email delivery
    pl email reroute mysite         # Route mysite email to Mailpit

EOF
}

case "${1:-}" in
    setup)
        shift
        "$EMAIL_DIR/setup_email.sh" "$@"
        ;;
    add)
        shift
        "$EMAIL_DIR/add_site_email.sh" "$@"
        ;;
    test)
        shift
        "$EMAIL_DIR/test_email.sh" "$@"
        ;;
    reroute)
        shift
        "$EMAIL_DIR/configure_reroute.sh" "$@"
        ;;
    list)
        shift
        "$EMAIL_DIR/add_site_email.sh" --list "$@"
        ;;
    -h|--help|help|"")
        show_help
        ;;
    *)
        print_error "Unknown email command: $1"
        show_help
        exit 1
        ;;
esac
