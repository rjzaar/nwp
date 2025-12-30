#!/bin/bash
set -euo pipefail

################################################################################
# NWP Staging to Live Deployment Script
#
# Deploys staging site to live server (provisioned by live.sh)
#
# Usage: ./stg2live.sh [OPTIONS] <sitename>
################################################################################

# Get script directory (resolve symlinks)
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
    DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"
    SOURCE="$(readlink "$SOURCE")"
    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"

# Source shared libraries
source "$SCRIPT_DIR/lib/ui.sh"
source "$SCRIPT_DIR/lib/common.sh"

# Script start time
START_TIME=$(date +%s)

################################################################################
# Helper Functions
################################################################################

# Get base name (remove _stg or _prod suffix)
get_base_name() {
    local site=$1
    echo "$site" | sed -E 's/_(stg|prod)$//'
}

# Get staging name
get_stg_name() {
    local site=$1
    local base=$(get_base_name "$site")
    echo "${base}_stg"
}

# Get base domain from cnwp.yml settings
get_base_domain() {
    awk '
        /^settings:/ { in_settings = 1; next }
        in_settings && /^[a-zA-Z]/ && !/^  / { in_settings = 0 }
        in_settings && /^  url:/ {
            sub("^  url: *", "")
            gsub(/["'"'"']/, "")
            print
            exit
        }
    ' "$SCRIPT_DIR/cnwp.yml"
}

# Get live server config from cnwp.yml
get_live_config() {
    local sitename="$1"
    local field="$2"

    awk -v site="$sitename" -v field="$field" '
        /^sites:/ { in_sites = 1; next }
        in_sites && /^[a-zA-Z]/ && !/^  / { in_sites = 0 }
        in_sites && $0 ~ "^  " site ":" { in_site = 1; next }
        in_site && /^  [a-zA-Z]/ && !/^    / { in_site = 0 }
        in_site && /^    live:/ { in_live = 1; next }
        in_live && /^    [a-zA-Z]/ && !/^      / { in_live = 0 }
        in_live && $0 ~ "^      " field ":" {
            sub("^      " field ": *", "")
            gsub(/["'"'"']/, "")
            print
            exit
        }
    ' "$SCRIPT_DIR/cnwp.yml"
}

# Check if live security is enabled
is_live_security_enabled() {
    local enabled=$(awk '
        /^settings:/ { in_settings = 1; next }
        in_settings && /^[a-zA-Z]/ && !/^  / { in_settings = 0 }
        in_settings && /^  live_security:/ { in_security = 1; next }
        in_security && /^  [a-zA-Z]/ && !/^    / { in_security = 0 }
        in_security && /^    enabled:/ {
            sub("^    enabled: *", "")
            gsub(/["'"'"']/, "")
            print
            exit
        }
    ' "$SCRIPT_DIR/cnwp.yml")
    [ "$enabled" == "true" ]
}

# Get security modules from cnwp.yml
get_security_modules() {
    awk '
        /^settings:/ { in_settings = 1; next }
        in_settings && /^[a-zA-Z]/ && !/^  / { in_settings = 0 }
        in_settings && /^  live_security:/ { in_security = 1; next }
        in_security && /^  [a-zA-Z]/ && !/^    / { in_security = 0 }
        in_security && /^    modules:/ { in_modules = 1; next }
        in_modules && /^    [a-zA-Z]/ && !/^      / { in_modules = 0 }
        in_modules && /^      - / {
            sub("^      - *", "")
            gsub(/["'"'"']/, "")
            print
        }
    ' "$SCRIPT_DIR/cnwp.yml"
}

# Install security modules on staging site before deployment
install_security_modules() {
    local stg_site="$1"

    # Check if skipped via command line
    if [ "${SKIP_SECURITY:-false}" == "true" ]; then
        print_info "Security module installation skipped (--no-security)"
        return 0
    fi

    if ! is_live_security_enabled; then
        print_info "Live security hardening disabled in cnwp.yml"
        return 0
    fi

    print_header "Installing Security Modules"

    local modules=$(get_security_modules)
    if [ -z "$modules" ]; then
        print_info "No security modules configured"
        return 0
    fi

    local original_dir=$(pwd)
    cd "$stg_site" || return 1

    # Install each module via composer and enable
    while IFS= read -r module; do
        [ -z "$module" ] && continue

        # Check if already installed
        if ddev composer show "drupal/$module" >/dev/null 2>&1; then
            print_status "OK" "$module already installed"
        else
            print_info "Installing drupal/$module..."
            if ddev composer require "drupal/$module" --no-interaction 2>/dev/null; then
                print_status "OK" "Installed $module"
            else
                print_status "WARN" "Could not install $module (may not exist or have conflicts)"
            fi
        fi

        # Enable module if not already enabled
        if ! ddev drush pm:list --status=enabled --type=module 2>/dev/null | grep -q "^$module "; then
            print_info "Enabling $module..."
            if ddev drush en "$module" -y 2>/dev/null; then
                print_status "OK" "Enabled $module"
            else
                print_status "WARN" "Could not enable $module"
            fi
        fi
    done <<< "$modules"

    # Export config so modules are enabled on live
    print_info "Exporting configuration..."
    ddev drush cex -y 2>/dev/null || true

    cd "$original_dir"
    return 0
}

# Display elapsed time
show_elapsed_time() {
    local end_time=$(date +%s)
    local elapsed=$((end_time - START_TIME))
    local hours=$((elapsed / 3600))
    local minutes=$(((elapsed % 3600) / 60))
    local seconds=$((elapsed % 60))

    echo ""
    print_status "OK" "Deployment completed in $(printf "%02d:%02d:%02d" $hours $minutes $seconds)"
}

# Show help
show_help() {
    cat << EOF
${BOLD}NWP Staging to Live Deployment${NC}

${BOLD}USAGE:${NC}
    ./stg2live.sh [OPTIONS] <sitename>

    Deploys staging site to the live server provisioned by 'pl live'.

${BOLD}OPTIONS:${NC}
    -h, --help              Show this help message
    -d, --debug             Enable debug output
    -y, --yes               Skip confirmation prompts
    --no-security           Skip security module installation

${BOLD}ARGUMENTS:${NC}
    sitename                Site name (with or without _stg suffix)

${BOLD}EXAMPLES:${NC}
    ./stg2live.sh mysite              # Deploy mysite_stg to mysite.nwpcode.org
    ./stg2live.sh mysite_stg          # Same as above
    ./stg2live.sh -y mysite           # Deploy without confirmation
    ./stg2live.sh --no-security mysite  # Deploy without security modules

${BOLD}SECURITY HARDENING:${NC}
    By default, security modules are installed from cnwp.yml settings.live_security
    Includes: seckit, honeypot, flood_control, login_security, etc.
    Disable with: --no-security flag or set enabled: false in cnwp.yml

${BOLD}WORKFLOW:${NC}
    1. Provision live server:  pl live mysite
    2. Deploy to live:         pl stg2live mysite
    3. View live site:         https://mysite.nwpcode.org

${BOLD}REQUIREMENTS:${NC}
    - Staging site must exist and be in production mode
    - Live server must be provisioned (pl live)

EOF
}

################################################################################
# Deployment Functions
################################################################################

deploy_to_live() {
    local stg_site="$1"
    local base_name="$2"
    local auto_yes="$3"

    # Get live server config
    local server_ip=$(get_live_config "$base_name" "server_ip")
    local domain=$(get_live_config "$base_name" "domain")
    local server_type=$(get_live_config "$base_name" "type")

    if [ -z "$server_ip" ]; then
        print_error "No live server configured for $base_name"
        print_info "Run 'pl live $base_name' first to provision a live server"
        return 1
    fi

    local base_domain=$(get_base_domain)
    if [ -z "$domain" ]; then
        domain="${base_name}.${base_domain}"
    fi

    print_header "Deploy Staging to Live"
    echo -e "${BOLD}Staging:${NC}     $stg_site"
    echo -e "${BOLD}Live:${NC}        https://$domain"
    echo -e "${BOLD}Server:${NC}      $server_ip"
    echo -e "${BOLD}Type:${NC}        ${server_type:-shared}"
    echo ""

    # Check staging site exists
    if [ ! -d "$stg_site" ]; then
        print_error "Staging site not found: $stg_site"
        return 1
    fi

    # Install security modules before deployment
    install_security_modules "$stg_site"

    # Determine SSH user
    local ssh_user="gitlab"
    if [ "$server_type" == "dedicated" ]; then
        ssh_user="root"
    fi

    # Test SSH connection
    print_info "Testing SSH connection..."
    if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "${ssh_user}@${server_ip}" "echo ok" >/dev/null 2>&1; then
        # Try alternate user
        if [ "$ssh_user" == "gitlab" ]; then
            ssh_user="root"
        else
            ssh_user="gitlab"
        fi
        if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "${ssh_user}@${server_ip}" "echo ok" >/dev/null 2>&1; then
            print_error "Cannot connect to live server: $server_ip"
            return 1
        fi
    fi
    print_status "OK" "SSH connection successful (user: $ssh_user)"

    # Get webroot from staging site
    local webroot="web"
    if [ -f "$stg_site/.ddev/config.yaml" ]; then
        webroot=$(grep "^docroot:" "$stg_site/.ddev/config.yaml" 2>/dev/null | awk '{print $2}')
        [ -z "$webroot" ] && webroot="web"
    fi

    # Build rsync excludes
    local excludes=(
        "--exclude=.ddev"
        "--exclude=.git"
        "--exclude=$webroot/sites/default/settings.local.php"
        "--exclude=$webroot/sites/default/files"
        "--exclude=private"
        "--exclude=node_modules"
        "--exclude=.env"
        "--exclude=.env.local"
    )

    # Sync files
    print_header "Syncing Files"
    print_info "Source: $stg_site/"
    print_info "Destination: ${ssh_user}@${server_ip}:/var/www/${base_name}/"

    local sudo_prefix=""
    if [ "$ssh_user" == "gitlab" ]; then
        sudo_prefix="sudo"
    fi

    # Ensure target directory exists
    ssh "${ssh_user}@${server_ip}" "$sudo_prefix mkdir -p /var/www/${base_name}" 2>/dev/null || true

    # Rsync
    if rsync -avz --delete "${excludes[@]}" \
        "$stg_site/" \
        "${ssh_user}@${server_ip}:/var/www/${base_name}/"; then
        print_status "OK" "Files synced"
    else
        print_error "File sync failed"
        return 1
    fi

    # Set permissions
    print_info "Setting permissions..."
    ssh "${ssh_user}@${server_ip}" "$sudo_prefix chown -R www-data:www-data /var/www/${base_name}" 2>/dev/null || true

    # Run post-deployment commands
    print_header "Post-Deployment Tasks"

    # Clear cache via drush if available
    print_info "Clearing cache..."
    ssh "${ssh_user}@${server_ip}" "cd /var/www/${base_name} && $sudo_prefix -u www-data drush cr" 2>/dev/null || \
        ssh "${ssh_user}@${server_ip}" "cd /var/www/${base_name}/$webroot && $sudo_prefix -u www-data ../vendor/bin/drush cr" 2>/dev/null || \
        print_status "WARN" "Could not clear cache (drush may not be available)"

    # Success
    print_header "Deployment Complete"
    print_status "OK" "Staging deployed to live server"
    echo ""
    echo -e "  ${BOLD}Live URL:${NC} ${GREEN}https://${domain}${NC}"
    echo ""

    return 0
}

################################################################################
# Main
################################################################################

main() {
    local DEBUG=false
    local YES=false
    local SKIP_SECURITY=false
    local SITENAME=""

    # Parse options
    local OPTIONS=hdy
    local LONGOPTS=help,debug,yes,no-security

    if ! PARSED=$(getopt --options=$OPTIONS --longoptions=$LONGOPTS --name "$0" -- "$@"); then
        show_help
        exit 1
    fi

    eval set -- "$PARSED"

    while true; do
        case "$1" in
            -h|--help) show_help; exit 0 ;;
            -d|--debug) DEBUG=true; shift ;;
            -y|--yes) YES=true; shift ;;
            --no-security) SKIP_SECURITY=true; shift ;;
            --) shift; break ;;
            *) echo "Programming error"; exit 3 ;;
        esac
    done

    # Get sitename
    if [ $# -ge 1 ]; then
        SITENAME="$1"
    else
        print_error "Sitename required"
        show_help
        exit 1
    fi

    # Normalize names
    local BASE_NAME=$(get_base_name "$SITENAME")
    local STG_NAME=$(get_stg_name "$SITENAME")

    # Export for use in deploy function
    export SKIP_SECURITY

    # Run deployment
    if deploy_to_live "$STG_NAME" "$BASE_NAME" "$YES"; then
        show_elapsed_time
        exit 0
    else
        print_error "Deployment failed"
        exit 1
    fi
}

main "$@"
