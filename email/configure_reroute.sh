#!/bin/bash
################################################################################
# configure_reroute.sh - Configure email rerouting for NWP sites
#
# This script configures email rerouting to prevent accidental emails to
# real users during development and testing.
#
# Usage:
#   ./configure_reroute.sh <sitename> [reroute_email]
#   ./configure_reroute.sh --status <sitename>
#   ./configure_reroute.sh --mailpit <sitename>
#   ./configure_reroute.sh --disable <sitename>
#   ./configure_reroute.sh --help
#
# Examples:
#   ./configure_reroute.sh mysite dev@nwpcode.org
#   ./configure_reroute.sh --mailpit mysite
#   ./configure_reroute.sh --status mysite
################################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NWP_DIR="$(dirname "$SCRIPT_DIR")"

# Source the reroute library
source "${SCRIPT_DIR}/lib/email-reroute.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_header() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
}

print_ok() { echo -e "${GREEN}[✓]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1" >&2; }
print_info() { echo -e "${BLUE}[i]${NC} $1"; }

show_help() {
    cat << EOF
Configure email rerouting for NWP development sites.

USAGE:
  $(basename "$0") <sitename> [reroute_email]   Configure rerouting
  $(basename "$0") --mailpit <sitename>         Configure for Mailpit
  $(basename "$0") --status <sitename>          Check current status
  $(basename "$0") --disable <sitename>         Disable rerouting
  $(basename "$0") --list                       List configured sites
  $(basename "$0") --help                       Show this help

OPTIONS:
  --mailpit     Configure site to use Mailpit for email capture
  --status      Show current reroute configuration
  --disable     Remove reroute configuration
  --list        List all sites with reroute config

EXAMPLES:
  # Reroute all emails to dev@nwpcode.org
  $(basename "$0") mysite dev@nwpcode.org

  # Use Mailpit for email capture (DDEV)
  $(basename "$0") --mailpit mysite

  # Check status
  $(basename "$0") --status mysite

SAFETY:
  Email rerouting prevents accidental emails to real users during
  development. All emails are redirected to a test address or
  captured by Mailpit.

EOF
    exit 0
}

configure_reroute() {
    local site_name="$1"
    local reroute_to="${2:-$REROUTE_DEFAULT_EMAIL}"
    local site_dir="${NWP_DIR}/${site_name}"

    print_header "Configure Email Rerouting: $site_name"

    if [ ! -d "$site_dir" ]; then
        print_error "Site not found: $site_dir"
        exit 1
    fi

    print_info "Site: $site_name"
    print_info "Reroute to: $reroute_to"
    print_info "Whitelist: $REROUTE_WHITELIST"
    echo ""

    # Check for and apply reroute
    apply_drupal_reroute "$site_dir" "$reroute_to" "$REROUTE_WHITELIST"

    if [ $? -eq 0 ]; then
        print_ok "Email rerouting configured!"
        echo ""
        echo "All emails from $site_name will now be sent to: $reroute_to"
        echo ""
        echo "To test: ddev drush php:eval \"\\Drupal::service('plugin.manager.mail')->mail('system', 'test', 'test@example.com', 'en');\""
    fi
}

configure_mailpit() {
    local site_name="$1"
    local site_dir="${NWP_DIR}/${site_name}"
    local settings_file="${site_dir}/html/sites/default/settings.local.php"

    print_header "Configure Mailpit: $site_name"

    if [ ! -d "$site_dir" ]; then
        print_error "Site not found: $site_dir"
        exit 1
    fi

    # Check for DDEV
    if [ ! -d "${site_dir}/.ddev" ]; then
        print_error "Not a DDEV site"
        echo "Mailpit configuration requires DDEV"
        exit 1
    fi

    # Check if Mailpit docker-compose exists
    if [ ! -f "${site_dir}/.ddev/docker-compose.mailpit.yaml" ]; then
        print_info "Installing Mailpit docker-compose..."
        cp "${NWP_DIR}/templates/ddev/docker-compose.mailpit.yaml" "${site_dir}/.ddev/"
        print_ok "Installed docker-compose.mailpit.yaml"
    else
        print_ok "Mailpit docker-compose already installed"
    fi

    # Add settings
    print_info "Adding Mailpit settings..."
    if ! grep -q "mailpit" "$settings_file" 2>/dev/null; then
        echo "" >> "$settings_file"
        generate_ddev_mailpit_settings >> "$settings_file"
        print_ok "Added Mailpit settings to settings.local.php"
    else
        print_warning "Mailpit settings already present"
    fi

    echo ""
    print_info "Restarting DDEV..."
    (cd "$site_dir" && ddev restart)

    echo ""
    print_ok "Mailpit configured!"
    echo ""
    echo "Access Mailpit UI: ddev describe | grep mailpit"
    echo "Or: https://${site_name}.ddev.site:8026"
}

show_status() {
    local site_name="$1"
    local site_dir="${NWP_DIR}/${site_name}"

    print_header "Email Reroute Status: $site_name"

    if [ ! -d "$site_dir" ]; then
        print_error "Site not found: $site_dir"
        exit 1
    fi

    check_reroute_status "$site_dir"

    # Check for Mailpit
    echo ""
    if [ -f "${site_dir}/.ddev/docker-compose.mailpit.yaml" ]; then
        echo "Mailpit: CONFIGURED"
        if ddev describe 2>/dev/null | grep -q mailpit; then
            echo "Mailpit Status: RUNNING"
        else
            echo "Mailpit Status: NOT RUNNING (run: ddev restart)"
        fi
    else
        echo "Mailpit: NOT CONFIGURED"
    fi
}

disable_reroute() {
    local site_name="$1"
    local site_dir="${NWP_DIR}/${site_name}"
    local settings_file="${site_dir}/html/sites/default/settings.local.php"

    print_header "Disable Email Rerouting: $site_name"

    if [ ! -d "$site_dir" ]; then
        print_error "Site not found: $site_dir"
        exit 1
    fi

    if [ -f "$settings_file" ]; then
        # Remove reroute configuration
        if grep -q "reroute_email" "$settings_file"; then
            # Create backup
            cp "$settings_file" "${settings_file}.backup.$(date +%Y%m%d_%H%M%S)"

            # Remove reroute lines
            sed -i '/reroute_email/d' "$settings_file"
            sed -i '/Email rerouting configuration/d' "$settings_file"
            sed -i '/Generated by NWP email-reroute.sh/d' "$settings_file"

            print_ok "Removed reroute configuration"
        else
            print_info "No reroute configuration found"
        fi
    fi

    print_warning "Email rerouting is now DISABLED for $site_name"
    print_warning "Emails will be sent to REAL recipients!"
}

list_configured() {
    print_header "Sites with Email Rerouting"

    for site_dir in "${NWP_DIR}"/*/; do
        local site_name=$(basename "$site_dir")
        local settings_file="${site_dir}/html/sites/default/settings.local.php"

        # Skip non-sites
        [ ! -d "${site_dir}/html" ] && continue

        local status=""
        local mailpit=""

        if [ -f "$settings_file" ] && grep -q "reroute_email" "$settings_file" 2>/dev/null; then
            local reroute_to=$(grep "reroute_email.settings.*address" "$settings_file" 2>/dev/null | grep -oP "'[^']+'" | tail -1 | tr -d "'")
            status="Reroute: ${reroute_to:-configured}"
        fi

        if [ -f "${site_dir}/.ddev/docker-compose.mailpit.yaml" ]; then
            mailpit="Mailpit: yes"
        fi

        if [ -n "$status" ] || [ -n "$mailpit" ]; then
            echo -e "${GREEN}${site_name}${NC}"
            [ -n "$status" ] && echo "  $status"
            [ -n "$mailpit" ] && echo "  $mailpit"
        fi
    done
}

# Main
main() {
    local action="configure"
    local site_name=""
    local reroute_email=""

    if [ $# -eq 0 ]; then
        show_help
    fi

    while [[ $# -gt 0 ]]; do
        case $1 in
            --help|-h)
                show_help
                ;;
            --status|-s)
                action="status"
                site_name="$2"
                shift 2
                ;;
            --mailpit|-m)
                action="mailpit"
                site_name="$2"
                shift 2
                ;;
            --disable|-d)
                action="disable"
                site_name="$2"
                shift 2
                ;;
            --list|-l)
                action="list"
                shift
                ;;
            *)
                if [ -z "$site_name" ]; then
                    site_name="$1"
                elif [ -z "$reroute_email" ]; then
                    reroute_email="$1"
                fi
                shift
                ;;
        esac
    done

    case "$action" in
        configure)
            if [ -z "$site_name" ]; then
                print_error "Site name required"
                exit 1
            fi
            configure_reroute "$site_name" "$reroute_email"
            ;;
        mailpit)
            configure_mailpit "$site_name"
            ;;
        status)
            show_status "$site_name"
            ;;
        disable)
            disable_reroute "$site_name"
            ;;
        list)
            list_configured
            ;;
    esac
}

main "$@"
