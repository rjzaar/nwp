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
# The email tooling moved into the per-server config tree (F17 Phase 8):
# servers/nwpcode/email/ is the checked-in home (the box carries an installed
# copy under /opt/nwp/email/). The old top-level email/ is kept as a fallback
# for pre-migration checkouts.
EMAIL_DIR="$PROJECT_ROOT/servers/nwpcode/email"
[ -d "$EMAIL_DIR" ] || EMAIL_DIR="$PROJECT_ROOT/email"

# Called by every dispatching branch (help works without the tooling present).
require_email_dir() {
    if [ ! -d "$EMAIL_DIR" ]; then
        print_error "Email tooling not found (looked in servers/nwpcode/email/ and email/)"
        exit 1
    fi
}

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
        require_email_dir
        "$EMAIL_DIR/setup_email.sh" "$@"
        ;;
    add)
        shift
        require_email_dir
        "$EMAIL_DIR/add_site_email.sh" "$@"
        ;;
    test)
        shift
        require_email_dir
        "$EMAIL_DIR/test_email.sh" "$@"
        ;;
    reroute)
        shift
        require_email_dir
        "$EMAIL_DIR/configure_reroute.sh" "$@"
        ;;
    list)
        shift
        require_email_dir
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
