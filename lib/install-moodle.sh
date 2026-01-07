#!/bin/bash
################################################################################
# NWP Moodle Installation Library
#
# Handles Moodle LMS installations
# This file is lazy-loaded by install.sh when recipe type is "moodle"
################################################################################

# Guard against multiple sourcing
if [ "${_INSTALL_MOODLE_LOADED:-}" = "1" ]; then
    return 0
fi
_INSTALL_MOODLE_LOADED=1

################################################################################
# Main Moodle Installation Function
################################################################################

install_moodle() {
    local recipe=$1
    local install_dir=$2
    local start_step=$3
    local purpose=${4:-indefinite}
    local base_dir=$(pwd)

    print_header "Installing Moodle using recipe: $recipe"

    if [ -n "$start_step" ]; then
        print_info "Starting from step $start_step (skipping earlier steps)"
        echo ""
    fi

    # Setup installation directory
    local project_dir=""

    if [ -n "$start_step" ]; then
        # When resuming, directory must already exist
        if [ ! -d "$install_dir" ]; then
            print_error "Installation directory '$install_dir' does not exist. Cannot resume from step $start_step"
            print_info "To resume an installation, the directory must already exist"
            return 1
        fi

        if ! cd "$install_dir"; then
            print_error "Failed to enter directory: $install_dir"
            return 1
        fi

        project_dir=$(pwd)
        print_status "INFO" "Using existing directory: $project_dir"
    else
        # Fresh installation - create directory
        print_info "Installation directory: $install_dir"

        # Create and enter the installation directory using absolute path
        local abs_install_dir="$base_dir/$install_dir"
        if ! mkdir -p "$abs_install_dir"; then
            print_error "Failed to create directory: $abs_install_dir"
            return 1
        fi

        # Change to absolute path to avoid Docker mount issues
        if ! cd "$abs_install_dir"; then
            print_error "Failed to enter directory: $abs_install_dir"
            return 1
        fi

        project_dir=$(pwd)
        print_status "OK" "Created installation directory: $project_dir"
    fi

    # Extract configuration values from YAML
    local source=$(get_recipe_value "$recipe" "source" "$base_dir/cnwp.yml")
    local branch=$(get_recipe_value "$recipe" "branch" "$base_dir/cnwp.yml")
    local webroot=$(get_recipe_value "$recipe" "webroot" "$base_dir/cnwp.yml")
    local sitename=$(get_recipe_value "$recipe" "sitename" "$base_dir/cnwp.yml")

    # Get PHP and database: recipe overrides settings, settings overrides defaults
    local php_version=$(get_recipe_value "$recipe" "php" "$base_dir/cnwp.yml")
    local database=$(get_recipe_value "$recipe" "database" "$base_dir/cnwp.yml")

    # Fall back to settings if not in recipe
    if [ -z "$php_version" ]; then
        php_version=$(get_settings_value "php" "$base_dir/cnwp.yml")
    fi
    if [ -z "$database" ]; then
        database=$(get_settings_value "database" "$base_dir/cnwp.yml")
    fi

    # Set defaults if still not specified (Moodle has different defaults)
    if [ -z "$php_version" ]; then
        php_version="8.1"  # Moodle 4.x default
        print_info "No PHP version specified, using default: 8.1"
    fi
    if [ -z "$database" ]; then
        database="mariadb"  # Moodle default
        print_info "No database specified, using default: mariadb"
    fi

    if [ -z "$webroot" ]; then
        webroot="."
        print_info "No webroot specified, using default: . (current directory)"
    fi

    if [ -z "$sitename" ]; then
        sitename="My Moodle Site"
    fi

    if [ -z "$branch" ]; then
        branch="MOODLE_404_STABLE"
        print_info "No branch specified, using default: MOODLE_404_STABLE"
    fi

    # Validate required values
    if [ -z "$source" ]; then
        print_error "Recipe '$recipe' does not specify 'source'"
        return 1
    fi

    print_info "Configuration:"
    echo "  Source:   $source"
    echo "  Branch:   $branch"
    echo "  Webroot:  $webroot"
    echo "  Database: $database"
    echo "  PHP:      $php_version"
    echo "  Sitename: $sitename"
    echo ""

    # Step 1: Clone Moodle from Git
    if should_run_step 1 "$start_step"; then
        print_header "Step 1: Clone Moodle Repository"
        print_info "This may take several minutes..."

        if ! git clone --branch "$branch" --depth 1 "$source" .; then
            print_error "Failed to clone Moodle repository"
            return 1
        fi
        print_status "OK" "Moodle cloned successfully"
    else
        print_status "INFO" "Skipping Step 1: Moodle already cloned"
    fi

    # Step 2: Configure DDEV
    if should_run_step 2 "$start_step"; then
        print_header "Step 2: Configure DDEV"

        # Map database type to DDEV database type
        local ddev_database="$database"
        if [ "$database" == "mysql" ]; then
            ddev_database="mysql:8.0"
        elif [ "$database" == "mariadb" ]; then
            ddev_database="mariadb:10.11"
        fi

        # Moodle uses php project type
        if ! ddev config --project-type=php --docroot="$webroot" --php-version="$php_version" --database="$ddev_database"; then
            print_error "Failed to configure DDEV"
            return 1
        fi
        print_status "OK" "DDEV configured (Database: $ddev_database)"
    else
        print_status "INFO" "Skipping Step 2: DDEV already configured"
    fi

    # Step 3: Memory Configuration
    if should_run_step 3 "$start_step"; then
        print_header "Step 3: Memory Configuration"

        # Get PHP settings from cnwp.yml (with defaults)
        local php_memory=$(get_setting "php_settings.memory_limit" "512M")
        local php_max_exec=$(get_setting "php_settings.max_execution_time" "600")
        local php_upload_max=$(get_setting "php_settings.upload_max_filesize" "100M")
        local php_post_max=$(get_setting "php_settings.post_max_size" "100M")

        mkdir -p .ddev/php
        cat > .ddev/php/memory.ini << EOF
memory_limit = ${php_memory}
max_execution_time = ${php_max_exec}
post_max_size = ${php_post_max}
upload_max_filesize = ${php_upload_max}
EOF
        print_status "OK" "Memory limits configured"
    else
        print_status "INFO" "Skipping Step 3: Memory already configured"
    fi

    # Step 4: Launch Services
    if should_run_step 4 "$start_step"; then
        print_header "Step 4: Launch DDEV Services"

        if ! ddev start; then
            print_error "Failed to start DDEV"
            return 1
        fi
        print_status "OK" "DDEV services started"
    else
        print_status "INFO" "Skipping Step 4: DDEV already started"
    fi

    # Step 5: Create Moodledata Directory (outside web root for security)
    if should_run_step 5 "$start_step"; then
        print_header "Step 5: Create Moodledata Directory"

        # Moodle requires dataroot to be OUTSIDE the web root
        # Create it as a sibling directory and add a DDEV mount
        # Use absolute path for docker-compose volume mount
        local moodledata_abs="${base_dir}/${install_dir}_moodledata"
        mkdir -p "$moodledata_abs"
        chmod 777 "$moodledata_abs"

        # Create DDEV docker-compose override to mount moodledata
        # Use absolute path to ensure Docker can find it
        cat > .ddev/docker-compose.moodledata.yaml << MOODLEDATA_EOF
# Moodle dataroot mount - outside web root for security
services:
  web:
    volumes:
      - "${moodledata_abs}:/var/www/moodledata:rw"
MOODLEDATA_EOF

        # Restart DDEV to apply the new mount
        print_info "Restarting DDEV to apply moodledata mount..."
        ddev restart

        print_status "OK" "Moodledata directory created at $moodledata_abs"
    else
        print_status "INFO" "Skipping Step 5: Moodledata already exists"
    fi

    # Step 6: Install Moodle
    if should_run_step 6 "$start_step"; then
        print_header "Step 6: Install Moodle"
        print_info "This will take 5-10 minutes..."

        # Verify DDEV is running and restart to ensure proper mount
        print_info "Verifying DDEV status..."
        if ! ddev describe >/dev/null 2>&1; then
            print_error "DDEV is not running. Starting DDEV..."
            if ! ddev start; then
                print_error "Failed to start DDEV"
                return 1
            fi
        else
            # Restart DDEV to ensure proper container mount context
            print_info "Restarting DDEV to ensure proper container configuration..."
            if ! ddev restart >/dev/null 2>&1; then
                print_error "Failed to restart DDEV"
                return 1
            fi
        fi

        # Verify current directory is accessible
        print_info "Working directory: $(pwd)"
        print_info "Verifying container access..."
        if ! ddev exec pwd >/dev/null 2>&1; then
            print_error "Container cannot access current directory"
            print_error "This is likely a Docker AppArmor/SELinux issue"
            print_info "Try running: sudo aa-status | grep docker"
            return 1
        fi

        # Determine database driver
        local db_driver="mariadb"
        if [ "$database" == "mysql" ]; then
            db_driver="mysqli"
        elif [ "$database" == "mariadb" ]; then
            db_driver="mariadb"
        fi

        # Get the site URL - try multiple methods
        local site_url=""

        # Method 1: Try to get primary_url from JSON
        site_url=$(ddev describe -j 2>/dev/null | grep -o '"primary_url":"[^"]*' | cut -d'"' -f4)

        # Method 2: If that fails, try httpurl
        if [ -z "$site_url" ]; then
            site_url=$(ddev describe -j 2>/dev/null | grep -o '"httpurl":"[^"]*' | cut -d'"' -f4)
        fi

        # Method 3: If that fails, try httpsurl
        if [ -z "$site_url" ]; then
            site_url=$(ddev describe -j 2>/dev/null | grep -o '"httpsurl":"[^"]*' | cut -d'"' -f4)
        fi

        # Method 4: Fallback to hostname-based URL
        if [ -z "$site_url" ]; then
            local hostname=$(ddev describe -j 2>/dev/null | grep -o '"hostname":"[^"]*' | cut -d'"' -f4)
            if [ -n "$hostname" ]; then
                site_url="https://$hostname"
            fi
        fi

        if [ -z "$site_url" ]; then
            print_error "Failed to get site URL from DDEV"
            ddev describe 2>&1 | head -10
            return 1
        fi

        print_info "Site URL: $site_url"

        # Get Moodle admin credentials from secrets (with defaults)
        local moodle_admin_user=$(get_secret "moodle.admin_user" "admin")
        local moodle_admin_pass=$(get_secret "moodle.admin_password" "Admin123!")
        local moodle_admin_email=$(get_secret "moodle.admin_email" "admin@example.com")
        local moodle_shortname=$(get_secret "moodle.shortname" "moodle")

        # Run Moodle installation
        if ! ddev exec php admin/cli/install.php \
            --lang=en \
            --wwwroot="$site_url" \
            --dataroot=/var/www/moodledata \
            --dbtype="$db_driver" \
            --dbhost=db \
            --dbname=db \
            --dbuser=db \
            --dbpass=db \
            --fullname="$sitename" \
            --shortname="$moodle_shortname" \
            --adminuser="$moodle_admin_user" \
            --adminpass="$moodle_admin_pass" \
            --adminemail="$moodle_admin_email" \
            --non-interactive \
            --agree-license; then
            print_error "Failed to install Moodle"
            return 1
        fi
        print_status "OK" "Moodle site installed"
    else
        print_status "INFO" "Skipping Step 6: Moodle already installed"
    fi

    # Step 7: Post-installation configuration
    if should_run_step 7 "$start_step"; then
        print_header "Step 7: Post-Installation Configuration"

        # Set up cron (optional)
        print_info "Moodle installed successfully"
        print_status "OK" "Installation complete"
    else
        print_status "INFO" "Skipping Step 7: Already configured"
    fi

    # Apply selected options from interactive checkbox
    apply_moodle_options

    # Success message
    print_header "Installation Complete!"

    # Get credentials again for display (in case they weren't set in step 6)
    local display_user=$(get_secret "moodle.admin_user" "admin")
    local display_pass=$(get_secret "moodle.admin_password" "Admin123!")

    echo -e "${GREEN}${BOLD}✓ Moodle has been successfully installed!${NC}\n"
    echo -e "${BOLD}Login credentials:${NC}"
    echo -e "  Username: ${GREEN}${display_user}${NC}"
    echo -e "  Password: ${GREEN}${display_pass}${NC}\n"

    # Open site
    print_info "Opening site in browser..."

    if command -v xdg-open &> /dev/null; then
        local site_url=$(ddev describe -j 2>/dev/null | grep -o '"url":"[^"]*' | cut -d'"' -f4)
        if [ -n "$site_url" ]; then
            xdg-open "$site_url" &>/dev/null &
            print_status "OK" "Site opened in browser: $site_url"
        fi
    elif command -v open &> /dev/null; then
        local site_url=$(ddev describe -j 2>/dev/null | grep -o '"url":"[^"]*' | cut -d'"' -f4)
        if [ -n "$site_url" ]; then
            open "$site_url" &>/dev/null &
            print_status "OK" "Site opened in browser: $site_url"
        fi
    fi

    echo ""
    echo -e "${BOLD}Useful commands:${NC}"
    echo -e "  ${BLUE}ddev launch${NC}      - Open site in browser"
    echo -e "  ${BLUE}ddev ssh${NC}          - SSH into container"
    echo -e "  ${BLUE}ddev exec php admin/cli/cron.php${NC} - Run Moodle cron\n"

    # Register site in cnwp.yml (if YAML library is available)
    if command -v yaml_add_site &> /dev/null; then
        print_info "Registering site in cnwp.yml..."

        # Get full directory path
        local site_dir=$(pwd)
        local site_name=$(basename "$site_dir")

        # Determine environment type from directory suffix
        local environment="development"
        if [[ "$site_name" =~ -stg$ ]]; then
            environment="staging"
        elif [[ "$site_name" =~ _prod$ ]]; then
            environment="production"
        elif [[ "$site_name" =~ _dev$ ]]; then
            environment="development"
        fi

        # Register the site (Moodle doesn't have install_modules typically)
        if yaml_add_site "$site_name" "$site_dir" "$recipe" "$environment" "$purpose" "$PROJECT_ROOT/cnwp.yml" 2>/dev/null; then
            print_status "OK" "Site registered in cnwp.yml (purpose: $purpose)"

            # Update site with selected options
            update_site_options "$site_name" "$PROJECT_ROOT/cnwp.yml"
        else
            # Site already exists or registration failed - not critical
            print_info "Site registration skipped (may already exist)"

            # Still try to update options if site exists
            if yaml_site_exists "$site_name" "$PROJECT_ROOT/cnwp.yml" 2>/dev/null; then
                update_site_options "$site_name" "$PROJECT_ROOT/cnwp.yml"
            fi
        fi

        # Pre-register DNS for live site (if shared server is configured)
        pre_register_live_dns "$site_name"

        # Show manual steps guide for selected options
        show_installation_guide "$site_name" "$environment"
    fi

    return 0
}
