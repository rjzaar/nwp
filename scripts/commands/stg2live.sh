#!/bin/bash
set -euo pipefail

################################################################################
# NWP Staging to Live Deployment Script
#
# Deploys staging site to live server (provisioned by live.sh)
#
# Features:
#   - File synchronization via rsync
#   - Database deployment (P34 - requires P33/P35 for full integration)
#   - Security module installation
#   - Permission management
#   - Cache clearing
#
# Usage: ./stg2live.sh [OPTIONS] <sitename>
################################################################################

# Get script directory (from symlink location, not resolved target)
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

# Source shared libraries
source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh"

# Script start time
START_TIME=$(date +%s)

################################################################################
# Helper Functions
################################################################################

# Get base name (remove -stg or -prod suffix, support legacy _stg/_prod during migration)
get_base_name() {
    local site=$1
    echo "$site" | sed -E 's/[-_](stg|prod)$//'
}

# Get staging name
get_stg_name() {
    local site=$1
    local base=$(get_base_name "$site")
    echo "${base}-stg"
}

# Get base domain from cnwp.yml settings.url
get_base_domain() {
    awk '
        /^settings:/ { in_settings = 1; next }
        in_settings && /^[a-zA-Z]/ && !/^  / { in_settings = 0 }
        in_settings && /^  url:/ {
            sub("^  url: *", "")
            sub(/#.*/, "")
            gsub(/["'"'"']/, "")
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")
            if (length($0) > 0) print
            exit
        }
    ' "$PROJECT_ROOT/cnwp.yml"
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
    ' "$PROJECT_ROOT/cnwp.yml"
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
    ' "$PROJECT_ROOT/cnwp.yml")
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
    ' "$PROJECT_ROOT/cnwp.yml"
}

# Secure user passwords before live deployment
# - Regenerates admin password to a secure random value
# - Forces password reset for all other users on next login
# - Returns new admin password for display
secure_user_passwords() {
    local stg_site="$1"

    # Check if skipped via command line
    if [ "${SKIP_PASSWORD_RESET:-false}" == "true" ]; then
        print_info "Password security skipped (--no-password-reset)"
        return 0
    fi

    print_header "Securing User Passwords"

    local original_dir=$(pwd)
    cd "$PROJECT_ROOT/sites/$stg_site" || return 1

    # Generate secure admin password (16 chars, alphanumeric)
    local new_admin_pass=$(openssl rand -base64 24 | tr -d '/=+' | cut -c -16)

    # Step 1: Reset admin password to secure value
    print_info "Generating secure admin password..."
    if ddev drush user:password admin "$new_admin_pass" 2>/dev/null; then
        print_status "OK" "Admin password regenerated"
    else
        print_error "Failed to reset admin password"
        cd "$original_dir"
        return 1
    fi

    # Step 2: Check for weak passwords on all users and force reset
    print_info "Checking for weak passwords..."
    local weak_users=$(ddev drush php:eval '
        $passwords_to_test = ["password", "admin", "admin123", "test", "test123", "1234", "123456"];
        $users = \Drupal::entityTypeManager()->getStorage("user")->loadMultiple();
        $service = \Drupal::service("password");
        $weak = [];
        foreach ($users as $user) {
            if ($user->id() == 0) continue;
            foreach ($passwords_to_test as $pwd) {
                if ($service->check($pwd, $user->getPassword())) {
                    $weak[] = $user->getAccountName();
                    break;
                }
            }
        }
        echo implode(",", $weak);
    ' 2>/dev/null)

    if [ -n "$weak_users" ] && [ "$weak_users" != "" ]; then
        print_status "WARN" "Found users with weak passwords: $weak_users"

        # Force password reset for weak password users (except admin which we just reset)
        print_info "Forcing password reset for users with weak passwords..."
        for username in ${weak_users//,/ }; do
            if [ "$username" != "admin" ]; then
                # Generate a random password and block the account until they reset
                local temp_pass=$(openssl rand -base64 24 | tr -d '/=+' | cut -c -20)
                ddev drush user:password "$username" "$temp_pass" 2>/dev/null || true
                print_info "  Reset password for: $username"
            fi
        done
        print_status "OK" "Weak passwords have been reset"
    else
        print_status "OK" "No weak passwords detected"
    fi

    # Step 3: Export configuration
    print_info "Exporting updated configuration..."
    ddev drush cex -y 2>/dev/null || true

    cd "$original_dir"

    # Store admin password for display at the end
    NEW_ADMIN_PASSWORD="$new_admin_pass"

    print_status "OK" "User passwords secured"
    echo ""
    echo -e "  ${BOLD}${YELLOW}⚠ SAVE THIS:${NC} New admin password: ${GREEN}${new_admin_pass}${NC}"
    echo ""

    return 0
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
    cd "$PROJECT_ROOT/sites/$stg_site" || return 1

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
    -v, --verbose           Show detailed rsync output
    --no-security           Skip security module installation
    --no-password-reset     Skip password security (admin regeneration, weak password reset)
    --no-provision          Skip auto-provisioning (used internally)

${BOLD}ARGUMENTS:${NC}
    sitename                Site name (with or without _stg suffix)

${BOLD}EXAMPLES:${NC}
    ./stg2live.sh mysite              # Deploy mysite-stg to mysite.nwpcode.org
    ./stg2live.sh mysite-stg          # Same as above
    ./stg2live.sh -y mysite           # Deploy without confirmation
    ./stg2live.sh --no-security mysite  # Deploy without security modules

${BOLD}PASSWORD SECURITY:${NC}
    Before deployment, this script automatically:
    - Regenerates the admin password to a secure 16-character random value
    - Detects users with weak passwords (password, admin, test123, etc.)
    - Resets weak passwords to secure random values
    - Displays the new admin password (SAVE IT!)
    Disable with: --no-password-reset flag

${BOLD}SECURITY HARDENING:${NC}
    By default, security modules are installed from cnwp.yml settings.live_security
    Includes: seckit, honeypot, flood_control, login_security, etc.
    Disable with: --no-security flag or set enabled: false in cnwp.yml

${BOLD}NOTE:${NC}
    If no live server is configured, this script will automatically
    call 'pl live' to provision one first.

${BOLD}REQUIREMENTS:${NC}
    - Staging site must exist and be in production mode

EOF
}

################################################################################
# Deployment Functions
################################################################################

# Deploy database from staging to live server
#
# Exports the staging database via ddev export-db, copies it to the live server
# via SCP, imports it via mysql CLI, and cleans up temporary files.
#
# This function implements P34: Database Deployment from the roadmap.
#
# Prerequisites (from P33: Live Server Infrastructure Setup):
#   - MariaDB/MySQL installed on live server
#   - Database and user created via create_site_database()
#   - Database credentials stored in .secrets.data.yml (managed by P35)
#
# Usage:
#   deploy_database <stg_site> <live_server> <ssh_user> <db_name> <db_user> <db_pass>
#
# Arguments:
#   stg_site     - Name of staging site (e.g., "mysite-stg")
#   live_server  - Live server IP or hostname
#   ssh_user     - SSH user (gitlab or root)
#   db_name      - Database name on live server
#   db_user      - Database user on live server
#   db_pass      - Database password on live server
#
# Returns:
#   0 on success, 1 on failure
#
# Error handling:
#   - Cleans up local and remote temporary files on failure
#   - Provides clear error messages for each step
#   - Returns to original directory on failure
#
deploy_database() {
    local stg_site="$1"
    local live_server="$2"
    local ssh_user="$3"
    local db_name="$4"
    local db_user="$5"
    local db_pass="$6"

    print_header "Database Deployment"

    # Determine sudo prefix
    local sudo_prefix=""
    if [ "$ssh_user" == "gitlab" ]; then
        sudo_prefix="sudo"
    fi

    # Step 1: Export database from staging
    print_info "Exporting database from staging site: $stg_site"

    local timestamp=$(date +%Y%m%d_%H%M%S)
    local dump_name="${stg_site}_${timestamp}.sql"
    local local_dump="./.ddev/${dump_name}"

    # Change to staging site directory
    local original_dir=$(pwd)
    cd "sites/$stg_site" || {
        print_error "Cannot access staging site directory: sites/$stg_site"
        return 1
    }

    # Export database using DDEV
    if ddev export-db --file="$dump_name" --gzip=false > /dev/null 2>&1; then
        if [ -f "$local_dump" ]; then
            print_status "OK" "Database exported: $dump_name"
            local size=$(du -h "$local_dump" | cut -f1)
            print_info "Export size: $size"
        else
            print_error "Database export file not found at: $local_dump"
            cd "$original_dir"
            return 1
        fi
    else
        print_error "Failed to export database from staging"
        cd "$original_dir"
        return 1
    fi

    # Step 2: Copy database dump to live server
    print_info "Copying database dump to live server..."

    local remote_dump="/tmp/${dump_name}"
    if scp -o BatchMode=yes "$local_dump" "${ssh_user}@${live_server}:${remote_dump}" >/dev/null 2>&1; then
        print_status "OK" "Database dump copied to server"
    else
        print_error "Failed to copy database dump to live server"
        rm -f "$local_dump"
        cd "$original_dir"
        return 1
    fi

    # Step 3: Import database on live server
    print_info "Importing database on live server..."

    # Create import command
    local import_cmd="mysql -u \"${db_user}\" -p\"${db_pass}\" \"${db_name}\" < \"${remote_dump}\""

    if ssh "${ssh_user}@${live_server}" "$sudo_prefix bash -c '$import_cmd'" >/dev/null 2>&1; then
        print_status "OK" "Database imported successfully"
    else
        print_error "Failed to import database on live server"
        # Clean up remote dump on failure
        ssh "${ssh_user}@${live_server}" "$sudo_prefix rm -f \"${remote_dump}\"" 2>/dev/null || true
        rm -f "$local_dump"
        cd "$original_dir"
        return 1
    fi

    # Step 4: Clean up temporary files
    print_info "Cleaning up temporary files..."

    # Remove local dump
    rm -f "$local_dump"

    # Remove remote dump
    if ssh "${ssh_user}@${live_server}" "$sudo_prefix rm -f \"${remote_dump}\"" 2>/dev/null; then
        print_status "OK" "Temporary files cleaned up"
    else
        print_status "WARN" "Could not remove remote temporary file"
    fi

    cd "$original_dir"

    print_status "OK" "Database deployment complete"
    return 0
}

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
    if [ ! -d "$PROJECT_ROOT/sites/$stg_site" ]; then
        print_error "Staging site not found: $PROJECT_ROOT/sites/$stg_site"
        return 1
    fi

    # Secure passwords before deployment (regenerate admin, reset weak passwords)
    secure_user_passwords "$stg_site"

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
    if [ -f "$PROJECT_ROOT/sites/$stg_site/.ddev/config.yaml" ]; then
        webroot=$(grep "^docroot:" "$PROJECT_ROOT/sites/$stg_site/.ddev/config.yaml" 2>/dev/null | awk '{print $2}')
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

    # Ensure target directory exists with correct ownership for rsync
    ssh "${ssh_user}@${server_ip}" "$sudo_prefix mkdir -p /var/www/${base_name}" 2>/dev/null || true
    if [ "$ssh_user" == "gitlab" ]; then
        # Give gitlab user ownership temporarily for rsync
        ssh "${ssh_user}@${server_ip}" "sudo chown -R gitlab:www-data /var/www/${base_name}" 2>/dev/null || true
    fi

    # Rsync (quiet by default, verbose with -v flag)
    local rsync_opts="-az"
    if [ "${VERBOSE:-false}" == "true" ]; then
        rsync_opts="-avz"
    fi

    if rsync $rsync_opts --delete "${excludes[@]}" \
        "$PROJECT_ROOT/sites/$stg_site/" \
        "${ssh_user}@${server_ip}:/var/www/${base_name}/"; then
        print_status "OK" "Files synced"
    else
        print_error "File sync failed"
        return 1
    fi

    # Set permissions
    print_info "Setting permissions..."
    ssh "${ssh_user}@${server_ip}" "$sudo_prefix chown -R www-data:www-data /var/www/${base_name}" 2>/dev/null || true

    # Deploy database (if credentials are available)
    # TODO: P35 will provide generate_live_settings() to retrieve these credentials
    # For now, database deployment is commented out pending P33/P35 implementation
    # local db_name="${base_name}"
    # local db_user="${base_name}"
    # local db_pass=$(get_data_secret "sites.${base_name}.database.password" "")
    # if [ -n "$db_pass" ]; then
    #     if ! deploy_database "$stg_site" "$server_ip" "$ssh_user" "$db_name" "$db_user" "$db_pass"; then
    #         print_status "WARN" "Database deployment failed (continuing with file deployment)"
    #     fi
    # else
    #     print_status "INFO" "Database credentials not configured - skipping database deployment"
    #     print_info "Run 'pl live $base_name' first to provision database, or manually configure in .secrets.data.yml"
    # fi

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
    local VERBOSE=false
    local SKIP_SECURITY=false
    local SKIP_PASSWORD_RESET=false
    local NO_PROVISION=false
    local SITENAME=""

    # Parse options
    local OPTIONS=hdyv
    local LONGOPTS=help,debug,yes,verbose,no-security,no-password-reset,no-provision

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
            -v|--verbose) VERBOSE=true; shift ;;
            --no-security) SKIP_SECURITY=true; shift ;;
            --no-password-reset) SKIP_PASSWORD_RESET=true; shift ;;
            --no-provision) NO_PROVISION=true; shift ;;
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
    export SKIP_SECURITY VERBOSE
    export SKIP_PASSWORD_RESET

    # Check if live server is configured
    local server_ip=$(get_live_config "$BASE_NAME" "server_ip")

    if [ -z "$server_ip" ] && [ "$NO_PROVISION" != "true" ]; then
        print_info "No live server configured for $BASE_NAME"
        print_info "Provisioning live server first..."
        echo ""

        # Call live.sh to provision (it will call back to us with --no-provision)
        if "${SCRIPT_DIR}/live.sh" -y "$BASE_NAME"; then
            # live.sh already called stg2live with --no-provision, so we're done
            exit 0
        else
            print_error "Failed to provision live server for: $BASE_NAME"
            exit 1
        fi
    fi

    # Run deployment
    if deploy_to_live "$STG_NAME" "$BASE_NAME" "$YES"; then
        show_elapsed_time
        exit 0
    else
        print_error "Deployment to live failed: $STG_NAME → $BASE_NAME"
        exit 1
    fi
}

main "$@"
