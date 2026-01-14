#!/bin/bash

################################################################################
# NWP Import Library
#
# Core functions for importing sites from remote servers
# Source this file: source "$SCRIPT_DIR/lib/import.sh"
#
# Requires: lib/ui.sh, lib/common.sh, lib/server-scan.sh, lib/import-tui.sh
################################################################################

# Prevent double-sourcing
[[ -n "${_IMPORT_SH_LOADED:-}" ]] && return 0
_IMPORT_SH_LOADED=1

################################################################################
# Import Step Functions
################################################################################

# Step 1: Create local directory structure
# Usage: import_step_create_directory "site_name" "webroot_name"
import_step_create_directory() {
    local site_name="$1"
    local webroot_name="${2:-web}"
    local site_dir="$PWD/$site_name"

    if [ -d "$site_dir" ]; then
        print_error "Directory already exists: $site_dir"
        return 1
    fi

    start_spinner "Creating directory structure..."
    mkdir -p "$site_dir"
    mkdir -p "$site_dir/$webroot_name/sites/default/files"
    mkdir -p "$site_dir/private"
    mkdir -p "$site_dir/config/sync"
    stop_spinner

    print_status "OK" "Created directory: $site_dir"
    return 0
}

# Step 2: Configure DDEV
# Usage: import_step_configure_ddev "site_name" "webroot_name" "php_version" "db_type"
import_step_configure_ddev() {
    local site_name="$1"
    local webroot_name="${2:-web}"
    local php_version="${3:-8.2}"
    local db_type="${4:-mariadb:10.11}"
    local site_dir="$PWD/$site_name"

    cd "$site_dir" || return 1

    start_spinner "Configuring DDEV..."
    ddev config \
        --project-type=drupal \
        --docroot="$webroot_name" \
        --php-version="$php_version" \
        --database="$db_type" \
        --project-name="$site_name" 2>/dev/null
    local result=$?
    stop_spinner

    if [ $result -eq 0 ]; then
        print_status "OK" "DDEV configured"
        return 0
    else
        print_error "Failed to configure DDEV"
        return 1
    fi
}

# Step 3: Pull database from remote
# Usage: import_step_pull_database "site_name" "ssh_target" "ssh_key" "remote_site_dir"
import_step_pull_database() {
    local site_name="$1"
    local ssh_target="$2"
    local ssh_key="$3"
    local remote_site_dir="$4"
    local site_dir="$PWD/$site_name"
    local ssh_opts=$(get_ssh_opts "$ssh_key")

    cd "$site_dir" || return 1

    local start_time=$(date +%s)

    # Dump database from remote
    start_spinner "Pulling database from remote server..."
    if ssh $ssh_opts "$ssh_target" "cd '$remote_site_dir' && vendor/bin/drush sql:dump --gzip 2>/dev/null" > db.sql.gz 2>/dev/null; then
        stop_spinner
        if [ -s db.sql.gz ]; then
            local size=$(du -h db.sql.gz | cut -f1)
            local end_time=$(date +%s)
            local duration=$((end_time - start_time))
            print_status "OK" "Database pulled: $size (${duration}s)"
            return 0
        fi
    fi

    stop_spinner
    print_error "Failed to pull database"
    rm -f db.sql.gz
    return 1
}

# Step 4: Pull files from remote
# Usage: import_step_pull_files "site_name" "ssh_target" "ssh_key" "remote_site_dir" "webroot_name" "full_sync"
import_step_pull_files() {
    local site_name="$1"
    local ssh_target="$2"
    local ssh_key="$3"
    local remote_site_dir="$4"
    local webroot_name="${5:-web}"
    local full_sync="${6:-n}"
    local site_dir="$PWD/$site_name"

    cd "$site_dir" || return 1

    local start_time=$(date +%s)

    if [ "$full_sync" = "y" ]; then
        # Full file sync including public files
        start_spinner "Syncing all files from remote server..."
        rsync -avz --progress \
            -e "ssh -i $ssh_key -o StrictHostKeyChecking=accept-new" \
            --exclude=".git" \
            --exclude="vendor" \
            --exclude="node_modules" \
            "$ssh_target:$remote_site_dir/" \
            "$site_dir/" 2>/dev/null
        local result=$?
        stop_spinner

        if [ $result -eq 0 ]; then
            local end_time=$(date +%s)
            local duration=$((end_time - start_time))
            print_status "OK" "Full file sync complete (${duration}s)"
            return 0
        fi
    else
        # Minimal sync: composer files, config, custom code
        start_spinner "Syncing essential files from remote server..."
        rsync -avz \
            -e "ssh -i $ssh_key -o StrictHostKeyChecking=accept-new" \
            --include="composer.json" \
            --include="composer.lock" \
            --include="config/***" \
            --include="$webroot_name/modules/custom/***" \
            --include="$webroot_name/themes/custom/***" \
            --include="$webroot_name/sites/default/settings.php" \
            --include="$webroot_name/sites/default/settings.local.php" \
            --include="$webroot_name/sites/default/services.yml" \
            --include="$webroot_name/sites/default/.htaccess" \
            --include="*/" \
            --exclude="$webroot_name/sites/default/files/*" \
            --exclude="vendor" \
            --exclude="node_modules" \
            --exclude=".git" \
            --prune-empty-dirs \
            "$ssh_target:$remote_site_dir/" \
            "$site_dir/" 2>/dev/null
        local result=$?
        stop_spinner

        if [ $result -eq 0 ]; then
            local end_time=$(date +%s)
            local duration=$((end_time - start_time))
            print_status "OK" "Essential files synced (${duration}s)"
            return 0
        fi
    fi

    print_error "Failed to sync files"
    return 1
}

# Step 5: Import database locally
# Usage: import_step_import_database "site_name"
import_step_import_database() {
    local site_name="$1"
    local site_dir="$PWD/$site_name"

    cd "$site_dir" || return 1

    # Start DDEV if not running
    if ! ddev describe >/dev/null 2>&1; then
        start_spinner "Starting DDEV..."
        ddev start >/dev/null 2>&1
        stop_spinner
    fi

    local start_time=$(date +%s)

    # Import the database
    if [ -f db.sql.gz ]; then
        start_spinner "Importing database into DDEV..."
        gunzip -c db.sql.gz | ddev mysql 2>/dev/null
        local result=$?
        stop_spinner
        rm -f db.sql.gz

        if [ $result -eq 0 ]; then
            local end_time=$(date +%s)
            local duration=$((end_time - start_time))
            print_status "OK" "Database imported (${duration}s)"
            return 0
        fi
    fi

    print_error "Failed to import database"
    return 1
}

# Step 6: Sanitize database
# Usage: import_step_sanitize_database "site_name" "options"
import_step_sanitize_database() {
    local site_name="$1"
    local site_dir="$PWD/$site_name"

    cd "$site_dir" || return 1

    # Run Drush sanitize
    start_spinner "Sanitizing database..."
    if ddev drush sql:sanitize -y 2>/dev/null; then
        # Additional truncations based on options
        if option_enabled "$site_name" "truncate_cache"; then
            ddev drush sql:query "SHOW TABLES LIKE 'cache%'" 2>/dev/null | while read table; do
                ddev drush sql:query "TRUNCATE TABLE $table" 2>/dev/null
            done
        fi

        if option_enabled "$site_name" "truncate_watchdog"; then
            ddev drush sql:query "TRUNCATE TABLE watchdog" 2>/dev/null || true
        fi

        if option_enabled "$site_name" "truncate_sessions"; then
            ddev drush sql:query "TRUNCATE TABLE sessions" 2>/dev/null || true
        fi

        stop_spinner
        print_status "OK" "Database sanitized"
        return 0
    fi

    stop_spinner
    print_warning "Sanitization had issues (non-fatal)"
    return 0
}

# Step 7: Configure local settings.php
# Usage: import_step_configure_settings "site_name" "webroot_name"
import_step_configure_settings() {
    local site_name="$1"
    local webroot_name="${2:-web}"
    local site_dir="$PWD/$site_name"
    local settings_file="$site_dir/$webroot_name/sites/default/settings.php"

    # Ensure settings.php is writable
    if [ -f "$settings_file" ]; then
        chmod 644 "$settings_file"
    fi

    # Create settings.local.php for DDEV
    local local_settings="$site_dir/$webroot_name/sites/default/settings.local.php"

    cat > "$local_settings" << 'SETTINGS_LOCAL'
<?php

/**
 * @file
 * Local development settings - auto-generated by NWP import.
 */

// Disable CSS/JS aggregation for development
$config['system.performance']['css']['preprocess'] = FALSE;
$config['system.performance']['js']['preprocess'] = FALSE;

// Enable verbose error reporting
$config['system.logging']['error_level'] = 'verbose';

// Private file path
$settings['file_private_path'] = '../private';

// Trusted host patterns for DDEV
$settings['trusted_host_patterns'] = [
  '^.+\.ddev\.site$',
  '^localhost$',
];

// Skip file system permissions hardening
$settings['skip_permissions_hardening'] = TRUE;
SETTINGS_LOCAL

    # Ensure settings.php includes settings.local.php
    if ! grep -q "settings.local.php" "$settings_file" 2>/dev/null; then
        cat >> "$settings_file" << 'INCLUDE_LOCAL'

// Include local settings if available
if (file_exists($app_root . '/' . $site_path . '/settings.local.php')) {
  include $app_root . '/' . $site_path . '/settings.local.php';
}
INCLUDE_LOCAL
    fi

    print_status "OK" "Settings configured"
    return 0
}

# Step 8: Configure Stage File Proxy
# Usage: import_step_configure_stage_file_proxy "site_name" "origin_url"
import_step_configure_stage_file_proxy() {
    local site_name="$1"
    local origin_url="$2"
    local site_dir="$PWD/$site_name"

    cd "$site_dir" || return 1

    # Install stage_file_proxy module
    start_spinner "Configuring Stage File Proxy module..."
    if ! ddev drush pm:list --status=enabled --format=list 2>/dev/null | grep -q "stage_file_proxy"; then
        # Check if module is already available
        if ddev drush pm:list --format=list 2>/dev/null | grep -q "stage_file_proxy"; then
            ddev drush pm:install stage_file_proxy -y 2>/dev/null
        else
            # Try to require it via composer
            ddev composer require drupal/stage_file_proxy --no-interaction 2>/dev/null
            ddev drush pm:install stage_file_proxy -y 2>/dev/null
        fi
    fi

    # Configure the origin URL
    if [ -n "$origin_url" ]; then
        ddev drush config:set stage_file_proxy.settings origin "$origin_url" -y 2>/dev/null
        ddev drush config:set stage_file_proxy.settings hotlink 0 -y 2>/dev/null
        stop_spinner
        print_status "OK" "Stage File Proxy configured: $origin_url"
    else
        stop_spinner
        print_warning "Stage File Proxy installed but origin URL unknown"
    fi

    return 0
}

# Step 9: Clear caches
# Usage: import_step_clear_caches "site_name"
import_step_clear_caches() {
    local site_name="$1"
    local site_dir="$PWD/$site_name"

    cd "$site_dir" || return 1

    start_spinner "Clearing Drupal caches..."
    if ddev drush cache:rebuild 2>/dev/null; then
        stop_spinner
        print_status "OK" "Caches cleared"
        return 0
    fi

    stop_spinner
    print_warning "Cache clear had issues (non-fatal)"
    return 0
}

# Step 10: Verify site boots
# Usage: import_step_verify_site "site_name"
# Returns: 0 if site boots, 1 if not
import_step_verify_site() {
    local site_name="$1"
    local site_dir="$PWD/$site_name"

    cd "$site_dir" || return 1

    # Check Drupal bootstrap status
    start_spinner "Verifying site boots..."
    local status=$(ddev drush status --field=bootstrap 2>/dev/null)
    stop_spinner

    if echo "$status" | grep -qi "successful"; then
        print_status "OK" "Site boots successfully"
        return 0
    else
        print_warning "Site may need attention"
        return 0  # Non-fatal
    fi
}

# Step 11: Register site in cnwp.yml
# Usage: import_step_register_site "site_name" "ssh_target" "remote_webroot" "drupal_version"
import_step_register_site() {
    local site_name="$1"
    local ssh_target="$2"
    local remote_webroot="$3"
    local drupal_version="${4:-unknown}"
    local config_file="${5:-cnwp.yml}"
    local site_dir="$PWD/$site_name"

    # Build the site entry
    local timestamp=$(date -Iseconds)

    # Check if sites section exists
    if ! grep -q "^sites:" "$config_file" 2>/dev/null; then
        echo "" >> "$config_file"
        echo "sites:" >> "$config_file"
    fi

    # Add site entry
    cat >> "$config_file" << SITE_ENTRY

  $site_name:
    directory: $site_dir
    type: import
    source:
      server: ${SELECTED_SERVER_NAME:-custom}
      ssh_host: $ssh_target
      webroot: $remote_webroot
    drupal_version: "$drupal_version"
    environment: development
    imported: "$timestamp"
    last_sync: "$timestamp"
    options:
      sanitize: $(get_import_option "$site_name" "sanitize")
      stage_file_proxy: $(get_import_option "$site_name" "stage_file_proxy")
SITE_ENTRY

    print_status "OK" "Registered in cnwp.yml"
    return 0
}

################################################################################
# Main Import Function
################################################################################

# Import a single site
# Usage: import_site "site_name" "ssh_target" "ssh_key" "remote_site_dir" "remote_webroot" "drupal_version"
import_site() {
    local site_name="$1"
    local ssh_target="$2"
    local ssh_key="$3"
    local remote_site_dir="$4"
    local remote_webroot="$5"
    local drupal_version="${6:-unknown}"
    local webroot_name=$(basename "$remote_webroot")

    local start_time=$(date +%s)
    local step=0
    local total_steps=11

    # Get import options
    local full_sync=$(get_import_option "$site_name" "full_file_sync")
    local do_sanitize=$(get_import_option "$site_name" "sanitize")
    local do_stage_proxy=$(get_import_option "$site_name" "stage_file_proxy")

    # Determine PHP version from remote (or use default)
    local php_version="8.2"

    # Get origin URL for stage file proxy
    local origin_url=""
    if [ "$do_stage_proxy" = "y" ]; then
        origin_url=$(get_remote_site_url "$ssh_target" "$ssh_key" "$remote_site_dir")
    fi

    # Step 1: Create directory
    show_import_progress "$site_name" 0 1 1
    show_step 1 $total_steps "Creating local directory structure"
    if ! import_step_create_directory "$site_name" "$webroot_name"; then
        return 1
    fi
    ((step++))

    # Step 2: Configure DDEV
    show_import_progress "$site_name" 1 1 1
    show_step 2 $total_steps "Configuring DDEV environment"
    if ! import_step_configure_ddev "$site_name" "$webroot_name" "$php_version"; then
        return 1
    fi
    ((step++))

    # Step 3: Pull database
    show_import_progress "$site_name" 2 1 1
    show_step 3 $total_steps "Pulling database from remote server"
    if ! import_step_pull_database "$site_name" "$ssh_target" "$ssh_key" "$remote_site_dir"; then
        return 1
    fi
    ((step++))

    # Step 4: Pull files
    show_import_progress "$site_name" 3 1 1
    show_step 4 $total_steps "Syncing files from remote server"
    if ! import_step_pull_files "$site_name" "$ssh_target" "$ssh_key" "$remote_site_dir" "$webroot_name" "$full_sync"; then
        return 1
    fi
    ((step++))

    # Run composer install if we did minimal sync
    if [ "$full_sync" != "y" ]; then
        cd "$PWD/$site_name" || return 1
        start_spinner "Installing dependencies via Composer..."
        ddev start >/dev/null 2>&1
        ddev composer install --no-interaction 2>/dev/null || true
        stop_spinner
    fi

    # Step 5: Import database
    show_import_progress "$site_name" 4 1 1
    show_step 5 $total_steps "Importing database into DDEV"
    if ! import_step_import_database "$site_name"; then
        return 1
    fi
    ((step++))

    # Step 6: Sanitize (if enabled)
    show_import_progress "$site_name" 5 1 1
    show_step 6 $total_steps "Sanitizing database"
    if [ "$do_sanitize" = "y" ]; then
        import_step_sanitize_database "$site_name"
    else
        print_status "INFO" "Sanitization skipped"
    fi
    ((step++))

    # Step 7: Configure settings
    show_import_progress "$site_name" 6 1 1
    show_step 7 $total_steps "Configuring local settings"
    import_step_configure_settings "$site_name" "$webroot_name"
    ((step++))

    # Step 8: Configure Stage File Proxy (if enabled)
    show_import_progress "$site_name" 7 1 1
    show_step 8 $total_steps "Configuring Stage File Proxy"
    if [ "$do_stage_proxy" = "y" ]; then
        import_step_configure_stage_file_proxy "$site_name" "$origin_url"
    else
        print_status "INFO" "Stage File Proxy skipped"
    fi
    ((step++))

    # Step 9: Clear caches
    show_import_progress "$site_name" 8 1 1
    show_step 9 $total_steps "Clearing caches"
    import_step_clear_caches "$site_name"
    ((step++))

    # Step 10: Verify site
    show_import_progress "$site_name" 9 1 1
    show_step 10 $total_steps "Verifying site functionality"
    import_step_verify_site "$site_name"
    ((step++))

    # Step 11: Register in cnwp.yml
    show_import_progress "$site_name" 10 1 1
    show_step 11 $total_steps "Registering site in configuration"
    import_step_register_site "$site_name" "$ssh_target" "$remote_webroot" "$drupal_version"
    ((step++))

    # Calculate duration
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local minutes=$((duration / 60))
    local seconds=$((duration % 60))

    print_status "OK" "Import complete in ${minutes}m ${seconds}s"

    return 0
}

# Import all selected sites
# Usage: import_selected_sites
# Uses: SELECTED_SITES, DISCOVERED_SITES, SELECTED_SSH_HOST, SELECTED_SSH_KEY
import_selected_sites() {
    local total_sites=${#SELECTED_SITES[@]}
    local current=0
    local results=()

    for site_idx in "${SELECTED_SITES[@]}"; do
        ((current++))

        eval "$(parse_site_json "${DISCOVERED_SITES[$site_idx]}")"

        local local_name=$(get_local_site_name "$SITE_NAME")
        local start_time=$(date +%s)

        show_import_progress "$local_name" 0 "$total_sites" "$current"

        if import_site "$local_name" "$SELECTED_SSH_HOST" "$SELECTED_SSH_KEY" \
            "$SITE_DIR" "$SITE_WEBROOT" "$SITE_VERSION"; then

            local end_time=$(date +%s)
            local duration=$((end_time - start_time))
            local minutes=$((duration / 60))
            local seconds=$((duration % 60))

            local url="https://${local_name}.ddev.site"
            results+=("$local_name|$url|${minutes}m ${seconds}s|success")
        else
            results+=("$local_name|||failed")
        fi
    done

    # Show completion screen
    show_import_complete results
}

################################################################################
# Cleanup Functions
################################################################################

# Rollback a failed import
# Usage: rollback_import "site_name"
rollback_import() {
    local site_name="$1"
    local site_dir="$PWD/$site_name"

    print_warning "Rolling back import for $site_name..."

    # Stop DDEV if running
    if [ -d "$site_dir/.ddev" ]; then
        cd "$site_dir" 2>/dev/null && ddev stop 2>/dev/null && ddev delete -O -y 2>/dev/null
    fi

    # Remove directory
    if [ -d "$site_dir" ]; then
        rm -rf "$site_dir"
        print_status "OK" "Removed directory: $site_dir"
    fi

    # Remove from cnwp.yml (if registered)
    # This is complex YAML manipulation, skip for now

    return 0
}

################################################################################
# Export Functions
################################################################################

export -f import_step_create_directory
export -f import_step_configure_ddev
export -f import_step_pull_database
export -f import_step_pull_files
export -f import_step_import_database
export -f import_step_sanitize_database
export -f import_step_configure_settings
export -f import_step_configure_stage_file_proxy
export -f import_step_clear_caches
export -f import_step_verify_site
export -f import_step_register_site
export -f import_site
export -f import_selected_sites
export -f rollback_import
