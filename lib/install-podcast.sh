#!/bin/bash
################################################################################
# NWP Podcast (Castopod) Installation Library
#
# Handles Castopod podcast platform installations
# This file is lazy-loaded by install.sh when recipe type is "podcast"
################################################################################

# Guard against multiple sourcing
if [ "${_INSTALL_PODCAST_LOADED:-}" = "1" ]; then
    return 0
fi
_INSTALL_PODCAST_LOADED=1

################################################################################
# Main Podcast Installation Function
################################################################################

install_podcast() {
    local recipe=$1
    local install_dir=$2
    local start_step=${3:-1}
    local purpose=${4:-indefinite}
    local config_file="nwp.yml"

    # Determine target name (strip sites/ prefix if present)
    local target_name="${install_dir#sites/}"

    # Get site-specific domain first, then fall back to recipe default
    # Check: sites.<site>.domain, then sites.<site>.live.domain, then recipe base_domain + target, then recipe domain
    local domain=""
    if declare -f yaml_get_site_field &>/dev/null; then
        # Try direct domain field first
        domain=$(yaml_get_site_field "$target_name" "domain" "$config_file" 2>/dev/null) || true
        # Try live.domain if direct domain not found
        if [ -z "$domain" ]; then
            domain=$(yaml_get_site_field "$target_name" "live.domain" "$config_file" 2>/dev/null) || true
        fi
    fi

    # If no site-specific domain, check for recipe base_domain to construct domain
    if [ -z "$domain" ]; then
        local base_domain=$(get_recipe_value "$recipe" "base_domain" "$config_file")
        if [ -n "$base_domain" ]; then
            # Construct domain from target + base_domain (e.g., gm + nwpcode.org = gm.nwpcode.org)
            domain="${target_name}.${base_domain}"
        else
            # Fall back to explicit domain in recipe
            domain=$(get_recipe_value "$recipe" "domain" "$config_file")
        fi
    fi

    # Get other recipe configuration
    local linode_region=$(get_recipe_value "$recipe" "linode_region" "$config_file")
    local b2_region=$(get_recipe_value "$recipe" "b2_region" "$config_file")
    local media_subdomain=$(get_recipe_value "$recipe" "media_subdomain" "$config_file")
    local use_server=$(get_recipe_value "$recipe" "use_server" "$config_file")

    # Defaults
    linode_region="${linode_region:-us-east}"
    b2_region="${b2_region:-us-west-004}"
    media_subdomain="${media_subdomain:-media}"

    # If use_server is specified, look up the server IP from that site's config
    local server_ip=""
    if [ -n "$use_server" ]; then
        if declare -f yaml_get_site_field &>/dev/null; then
            server_ip=$(yaml_get_site_field "$use_server" "live.server_ip" "$config_file" 2>/dev/null) || true
            if [ -z "$server_ip" ]; then
                print_error "Could not find server_ip for site '$use_server' in nwp.yml"
                print_info "Ensure sites.$use_server.live.server_ip is configured"
                return 1
            fi
        else
            print_error "yaml_get_site_field not available"
            return 1
        fi
    fi

    # Allow domain override from install_dir if it looks like a domain
    if [[ "$install_dir" == *.* ]]; then
        domain="$install_dir"
        install_dir="${install_dir%%.*}"  # Use subdomain as dir name
    fi

    if [ -z "$domain" ]; then
        print_error "No domain specified. Use: ./install.sh podcast podcast.example.com"
        return 1
    fi

    print_header "Podcast Installation (Castopod): $domain"
    echo ""
    echo -e "  Domain:       ${BLUE}$domain${NC}"
    echo -e "  Directory:    ${BLUE}$install_dir${NC}"
    if [ -n "$server_ip" ]; then
        echo -e "  Server:       ${BLUE}$server_ip${NC} (shared from $use_server)"
    else
        echo -e "  Linode:       ${BLUE}$linode_region${NC} (new server)"
    fi
    echo -e "  B2 Region:    ${BLUE}$b2_region${NC}"
    echo -e "  Media:        ${BLUE}$media_subdomain${NC}"
    echo -e "  Purpose:      ${BLUE}$purpose${NC}"
    echo ""

    # Check if podcast.sh exists
    if [ ! -f "$SCRIPT_DIR/podcast.sh" ]; then
        print_error "podcast.sh not found in $SCRIPT_DIR"
        return 1
    fi

    # Check prerequisites using podcast.sh status
    print_info "Checking prerequisites..."
    if ! "$SCRIPT_DIR/podcast.sh" status >/dev/null 2>&1; then
        echo ""
        print_warning "Some prerequisites may be missing. Run './podcast.sh status' for details."
        read -p "Continue anyway? [y/N]: " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            print_info "Aborted. Fix prerequisites and try again."
            return 1
        fi
    fi
    print_status "OK" "Prerequisites check passed"

    # Call podcast.sh setup with the domain
    echo ""
    print_info "Calling podcast.sh setup..."
    echo ""

    # Build podcast.sh arguments
    local podcast_args=(-r "$linode_region" -b "$b2_region" -m "$media_subdomain")
    if [ -n "$server_ip" ]; then
        podcast_args+=(--server "$server_ip")
    fi
    podcast_args+=("$domain")

    if "$SCRIPT_DIR/podcast.sh" setup "${podcast_args[@]}"; then

        # Register site in nwp.yml
        local site_dir="$PROJECT_ROOT/$install_dir"

        if command -v yaml_add_site &> /dev/null; then
            if yaml_add_site "$install_dir" "$site_dir" "$recipe" "production" "$purpose" "$PROJECT_ROOT/nwp.yml" 2>/dev/null; then
                print_status "OK" "Site registered in nwp.yml (purpose: $purpose)"
            else
                print_info "Site registration skipped (may already exist)"
            fi
        fi

        return 0
    else
        print_error "Podcast setup failed"
        return 1
    fi
}
