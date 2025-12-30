#!/bin/bash

################################################################################
# url_setup.sh - URL and GitLab Setup for NWP
################################################################################
#
# This script checks the 'urluse' and 'url' values in cnwp.yml and:
#   1. Checks if the URL points to Linode
#   2. Checks if it has an IP associated with it
#   3. Reports on the findings
#   4. Offers to set up GitLab at git.[url] on Linode
#
# Usage:
#   ./url_setup.sh [OPTIONS]
#
# Options:
#   -h, --help       Show this help message
#   -v, --verbose    Enable verbose output
#   -y, --yes        Skip confirmation prompts
#   -c, --config FILE  Specify config file (default: ../cnwp.yml)
#
################################################################################

set -e

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NWP_ROOT="$(dirname "$SCRIPT_DIR")"
GIT_DIR="$NWP_ROOT/git"
CONFIG_FILE="$NWP_ROOT/cnwp.yml"

# Options
VERBOSE=false
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
    echo -e "${GREEN}✓${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}!${NC} $1"
}

print_error() {
    echo -e "${RED}ERROR:${NC} $1"
}

log_verbose() {
    if [ "$VERBOSE" = true ]; then
        echo -e "${BLUE}[DEBUG]${NC} $1"
    fi
}

confirm() {
    if [ "$AUTO_YES" = true ]; then
        return 0
    fi

    local prompt="$1"
    local default="${2:-n}"
    local response

    if [ "$default" = "y" ]; then
        read -p "$prompt [Y/n]: " response
        response=${response:-y}
    else
        read -p "$prompt [y/N]: " response
        response=${response:-n}
    fi

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
        -h|--help)
            grep "^#" "$0" | grep -v "^#!/" | sed 's/^# //' | sed 's/^#//'
            exit 0
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -y|--yes)
            AUTO_YES=true
            shift
            ;;
        -c|--config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        *)
            print_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

################################################################################
# Configuration Parsing Functions
################################################################################

read_config_value() {
    local key="$1"
    local config_file="${2:-$CONFIG_FILE}"

    if [ ! -f "$config_file" ]; then
        log_verbose "Config file not found: $config_file" >&2
        echo ""
        return 1
    fi

    # Read value from YAML (simple parsing using grep/awk)
    # This handles "key: value" format in the settings section
    local value=$(grep "^  $key:" "$config_file" 2>/dev/null | head -1 | awk -F': ' '{print $2}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    log_verbose "Config key '$key' = '$value'" >&2
    echo "$value"
}

################################################################################
# URL Analysis Functions
################################################################################

check_url_dns() {
    local url="$1"

    # Strip protocol if present
    url=$(echo "$url" | sed 's|^https\?://||' | sed 's|/.*$||')

    log_verbose "Checking DNS for: $url"

    # Get IP address
    local ip=$(dig +short "$url" A | tail -1)

    if [ -z "$ip" ]; then
        print_warning "No IP address found for $url"
        return 1
    fi

    echo "$ip"
    return 0
}

check_ip_is_linode() {
    local ip="$1"

    log_verbose "Checking if IP $ip belongs to Linode"

    # Use reverse DNS to check if it's Linode
    local rdns=$(dig +short -x "$ip" | head -1)

    log_verbose "Reverse DNS: $rdns"

    # Check if reverse DNS contains linode
    if echo "$rdns" | grep -qi "linode"; then
        return 0
    fi

    # Also check WHOIS for Linode (requires whois to be installed)
    if command -v whois &> /dev/null; then
        local whois_result=$(whois "$ip" 2>/dev/null | grep -i "linode\|akamai" | head -1)
        if [ -n "$whois_result" ]; then
            log_verbose "WHOIS indicates Linode/Akamai: $whois_result"
            return 0
        fi
    fi

    return 1
}

################################################################################
# GitLab Setup Functions
################################################################################

setup_gitlab_on_linode() {
    local base_url="$1"
    local gitlab_domain="git.$base_url"

    print_header "Setting up GitLab on Linode"

    # Strip protocol if present
    base_url=$(echo "$base_url" | sed 's|^https\?://||' | sed 's|/.*$||')
    gitlab_domain="git.$base_url"

    print_info "GitLab will be set up at: $gitlab_domain"
    echo ""

    # Check if GitLab scripts exist
    if [ ! -f "$GIT_DIR/gitlab_setup.sh" ]; then
        print_error "GitLab setup script not found: $GIT_DIR/gitlab_setup.sh"
        return 1
    fi

    if [ ! -f "$GIT_DIR/gitlab_create_server.sh" ]; then
        print_error "GitLab create server script not found: $GIT_DIR/gitlab_create_server.sh"
        return 1
    fi

    # Ask for email
    local email
    read -p "Enter email address for GitLab admin and SSL certificates: " email

    if [ -z "$email" ]; then
        print_error "Email is required"
        return 1
    fi

    echo ""
    print_info "This will:"
    echo "  1. Set up Linode CLI and environment (if needed)"
    echo "  2. Create a GitLab server at $gitlab_domain"
    echo "  3. Install GitLab CE with Runner"
    echo ""

    if ! confirm "Continue with GitLab setup?" "y"; then
        print_info "GitLab setup cancelled"
        return 0
    fi

    # Run GitLab setup
    print_header "Running GitLab Environment Setup"

    if [ -f "$HOME/.config/linode-cli" ] && command -v linode-cli &> /dev/null; then
        print_success "Linode CLI already configured"
    else
        print_info "Running GitLab setup script..."
        cd "$GIT_DIR"
        bash gitlab_setup.sh

        if [ $? -ne 0 ]; then
            print_error "GitLab setup failed"
            return 1
        fi
    fi

    # Create GitLab server
    print_header "Creating GitLab Server"

    print_info "Creating GitLab server at $gitlab_domain..."
    echo ""

    cd "$GIT_DIR"
    bash gitlab_create_server.sh --domain "$gitlab_domain" --email "$email"

    if [ $? -ne 0 ]; then
        print_error "Failed to create GitLab server"
        return 1
    fi

    print_success "GitLab server creation initiated!"
    echo ""
    print_info "Next steps:"
    echo "  1. Wait 10-15 minutes for GitLab installation to complete"
    echo "  2. Point your DNS A record for $gitlab_domain to the server IP"
    echo "  3. Access GitLab at http://$gitlab_domain"
    echo "  4. Get the initial root password from the server"
    echo ""
}

################################################################################
# Main Script
################################################################################

main() {
    print_header "URL Setup - NWP"

    # Check if config file exists
    if [ ! -f "$CONFIG_FILE" ]; then
        print_error "Configuration file not found: $CONFIG_FILE"
        print_info "Please create cnwp.yml from example.cnwp.yml"
        exit 1
    fi

    print_success "Configuration file found: $CONFIG_FILE"

    # Read urluse setting
    print_header "Checking URL Configuration"

    local urluse=$(read_config_value "urluse")
    local url=$(read_config_value "url")

    print_info "urluse: ${urluse:-<not set>}"
    print_info "url: ${url:-<not set>}"
    echo ""

    # Check if urluse is set to gitlab or all
    if [ -z "$urluse" ]; then
        print_warning "urluse is not set in $CONFIG_FILE"
        print_info "Set urluse to 'gitlab' or 'all' to enable GitLab setup"
        exit 0
    fi

    if [ "$urluse" != "gitlab" ] && [ "$urluse" != "all" ]; then
        print_info "urluse is set to '$urluse' (not 'gitlab' or 'all')"
        print_info "No GitLab setup required"
        exit 0
    fi

    print_success "urluse is set to '$urluse' - GitLab setup is enabled"

    # Check if url is set
    if [ -z "$url" ]; then
        print_error "url is not set in $CONFIG_FILE"
        print_info "Please set the url value in $CONFIG_FILE"
        exit 1
    fi

    print_success "url is set: $url"

    # Check DNS and IP
    print_header "Checking URL DNS and IP"

    local ip=$(check_url_dns "$url")
    local has_ip=false

    if [ -n "$ip" ] && [ "$ip" != "" ]; then
        print_success "IP address found: $ip"
        has_ip=true
    else
        print_warning "URL does not have an IP address assigned"
        print_info "DNS lookup failed for: $url"
        echo ""
        print_info "This could mean:"
        echo "  • The domain doesn't exist yet"
        echo "  • DNS records haven't been created"
        echo "  • DNS hasn't propagated yet"
        echo ""

        if confirm "Do you want to set up GitLab anyway (you'll need to configure DNS later)?" "y"; then
            setup_gitlab_on_linode "$url"
        else
            print_info "Setup cancelled"
        fi
        exit 0
    fi

    # Check if IP belongs to Linode
    print_header "Checking if IP is on Linode"

    if check_ip_is_linode "$ip"; then
        print_success "IP $ip appears to be on Linode!"
        echo ""
        print_info "The URL $url is already pointing to Linode"
        print_warning "A server may already exist at this IP"
        echo ""

        if confirm "Do you want to check or set up GitLab anyway?" "n"; then
            # Check if gitlab subdomain exists
            local gitlab_domain="git.$url"
            gitlab_domain=$(echo "$gitlab_domain" | sed 's|^https\?://||' | sed 's|/.*$||')

            local gitlab_ip=$(check_url_dns "$gitlab_domain" 2>/dev/null)

            if [ -n "$gitlab_ip" ]; then
                print_info "GitLab subdomain already exists at: $gitlab_ip"
                print_success "GitLab may already be set up!"
                echo ""
                print_info "Try accessing: http://$gitlab_domain"
            else
                print_info "GitLab subdomain (git.$url) does not exist yet"
                echo ""
                if confirm "Set up GitLab now?" "y"; then
                    setup_gitlab_on_linode "$url"
                fi
            fi
        fi
    else
        print_warning "IP $ip does NOT appear to be on Linode"
        echo ""
        print_info "The URL $url is pointing to a non-Linode IP: $ip"
        print_info "You may want to:"
        echo "  • Update your DNS to point to a Linode server"
        echo "  • Or set up a new GitLab server on Linode"
        echo ""

        if confirm "Would you like to set up GitLab on Linode (you'll need to update DNS after)?" "y"; then
            setup_gitlab_on_linode "$url"
        else
            print_info "Setup cancelled"
        fi
    fi

    print_header "URL Setup Complete"
}

# Check prerequisites
if ! command -v dig &> /dev/null; then
    print_warning "dig command not found - DNS checking will be limited"
    print_info "Install with: sudo apt-get install dnsutils"
fi

# Run main
main "$@"
