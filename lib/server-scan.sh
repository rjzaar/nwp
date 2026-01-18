#!/bin/bash

################################################################################
# NWP Server Scan Library
#
# Functions for scanning remote Linode servers to discover Drupal sites
# Source this file: source "$SCRIPT_DIR/lib/server-scan.sh"
#
# Requires: lib/ui.sh, lib/common.sh
################################################################################

# Prevent double-sourcing
[[ -n "${_SERVER_SCAN_SH_LOADED:-}" ]] && return 0
_SERVER_SCAN_SH_LOADED=1

################################################################################
# SSH Connection Functions
################################################################################

# Test SSH connection to a remote server
# Usage: test_ssh_connection "user@host" "ssh_key_path"
# Returns: 0 on success, 1 on failure
test_ssh_connection() {
    local ssh_target="$1"
    local ssh_key="${2:-$HOME/.ssh/nwp}"
    local ssh_opts="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes"

    if [ ! -f "$ssh_key" ]; then
        print_error "SSH key not found: $ssh_key"
        return 1
    fi

    if ssh $ssh_opts -i "$ssh_key" "$ssh_target" "exit" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Get SSH options string
# Usage: get_ssh_opts "ssh_key_path"
get_ssh_opts() {
    local ssh_key="${1:-$HOME/.ssh/nwp}"
    echo "-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -i $ssh_key"
}

################################################################################
# Site Discovery Functions
################################################################################

# Scan a remote server for Drupal sites in /var/www
# Usage: scan_server_for_sites "user@host" "ssh_key_path"
# Output: JSON lines, one per site discovered
scan_server_for_sites() {
    local ssh_target="$1"
    local ssh_key="${2:-$HOME/.ssh/nwp}"
    local ssh_opts=$(get_ssh_opts "$ssh_key")

    ssh $ssh_opts "$ssh_target" bash << 'REMOTE_SCAN_SCRIPT'
        # Find all Drupal sites by looking for settings.php
        find /var/www -maxdepth 5 -name "settings.php" -path "*/sites/default/*" 2>/dev/null | while read -r settings_file; do
            # Derive paths
            webroot=$(dirname "$(dirname "$(dirname "$settings_file")")")
            site_dir=$(dirname "$webroot")
            site_name=$(basename "$site_dir")
            webroot_name=$(basename "$webroot")

            # Skip if this looks like a Drupal core directory inside another project
            if [[ "$webroot" == *"/vendor/"* ]] || [[ "$webroot" == *"/core/"* ]]; then
                continue
            fi

            # Detect Drupal version
            version="unknown"
            drupal_major="0"
            if [ -f "$webroot/core/lib/Drupal.php" ]; then
                # Drupal 8/9/10/11
                version=$(grep -oP "const VERSION = '\K[^']+" "$webroot/core/lib/Drupal.php" 2>/dev/null || echo "unknown")
                drupal_major=$(echo "$version" | cut -d. -f1)
            elif [ -f "$webroot/includes/bootstrap.inc" ]; then
                # Drupal 7
                version=$(grep -oP "define\('VERSION', '\K[^']+" "$webroot/includes/bootstrap.inc" 2>/dev/null || echo "7.x")
                drupal_major="7"
            fi

            # Check if Drush is available
            has_drush="n"
            drush_path=""
            if [ -f "$site_dir/vendor/bin/drush" ]; then
                has_drush="y"
                drush_path="$site_dir/vendor/bin/drush"
            elif [ -f "$webroot/vendor/bin/drush" ]; then
                has_drush="y"
                drush_path="$webroot/vendor/bin/drush"
            fi

            # Get database size (if Drush available)
            db_size_mb="unknown"
            if [ "$has_drush" = "y" ]; then
                db_size_mb=$(cd "$site_dir" 2>/dev/null && "$drush_path" sql:query \
                    "SELECT ROUND(SUM(data_length + index_length)/1024/1024,1) FROM information_schema.tables WHERE table_schema = DATABASE();" 2>/dev/null || echo "unknown")
                # Clean up the result
                db_size_mb=$(echo "$db_size_mb" | tr -d '[:space:]')
                [ -z "$db_size_mb" ] && db_size_mb="unknown"
            fi

            # Get files size
            files_dir="$webroot/sites/default/files"
            files_size="0"
            if [ -d "$files_dir" ]; then
                files_size=$(du -sh "$files_dir" 2>/dev/null | cut -f1)
            fi

            # Get private files size if exists
            private_size="0"
            if [ -d "$site_dir/private" ]; then
                private_size=$(du -sh "$site_dir/private" 2>/dev/null | cut -f1)
            fi

            # Check if site appears functional (has database settings)
            is_configured="n"
            if grep -q "database" "$settings_file" 2>/dev/null; then
                is_configured="y"
            fi

            # Output as JSON line
            printf '{"name":"%s","site_dir":"%s","webroot":"%s","webroot_name":"%s","version":"%s","drupal_major":"%s","db_size_mb":"%s","files_size":"%s","private_size":"%s","has_drush":"%s","is_configured":"%s"}\n' \
                "$site_name" "$site_dir" "$webroot" "$webroot_name" "$version" "$drupal_major" "$db_size_mb" "$files_size" "$private_size" "$has_drush" "$is_configured"
        done
REMOTE_SCAN_SCRIPT
}

# Parse JSON site data into bash variables
# Usage: eval "$(parse_site_json "$json_line")"
parse_site_json() {
    local json="$1"

    # Extract values using grep/sed (avoids jq dependency)
    echo "SITE_NAME=$(echo "$json" | grep -oP '"name":"\K[^"]+')"
    echo "SITE_DIR=$(echo "$json" | grep -oP '"site_dir":"\K[^"]+')"
    echo "SITE_WEBROOT=$(echo "$json" | grep -oP '"webroot":"\K[^"]+')"
    echo "SITE_WEBROOT_NAME=$(echo "$json" | grep -oP '"webroot_name":"\K[^"]+')"
    echo "SITE_VERSION=$(echo "$json" | grep -oP '"version":"\K[^"]+')"
    echo "SITE_DRUPAL_MAJOR=$(echo "$json" | grep -oP '"drupal_major":"\K[^"]+')"
    echo "SITE_DB_SIZE=$(echo "$json" | grep -oP '"db_size_mb":"\K[^"]+')"
    echo "SITE_FILES_SIZE=$(echo "$json" | grep -oP '"files_size":"\K[^"]+')"
    echo "SITE_PRIVATE_SIZE=$(echo "$json" | grep -oP '"private_size":"\K[^"]+')"
    echo "SITE_HAS_DRUSH=$(echo "$json" | grep -oP '"has_drush":"\K[^"]+')"
    echo "SITE_IS_CONFIGURED=$(echo "$json" | grep -oP '"is_configured":"\K[^"]+')"
}

################################################################################
# Detailed Site Analysis
################################################################################

# Get detailed information about a specific site
# Usage: analyze_remote_site "user@host" "ssh_key" "/var/www/site1" "/var/www/site1/web"
# Output: Key=value pairs
analyze_remote_site() {
    local ssh_target="$1"
    local ssh_key="$2"
    local site_dir="$3"
    local webroot="$4"
    local ssh_opts=$(get_ssh_opts "$ssh_key")

    ssh $ssh_opts "$ssh_target" bash << REMOTE_ANALYZE
        cd "$site_dir" 2>/dev/null || exit 1

        # PHP version on server
        php_version=\$(php -v 2>/dev/null | head -1 | grep -oP 'PHP \K[0-9]+\.[0-9]+' || echo "unknown")
        echo "php_version=\$php_version"

        # Drupal version
        if [ -f "$webroot/core/lib/Drupal.php" ]; then
            drupal_version=\$(grep -oP "const VERSION = '\K[^']+" "$webroot/core/lib/Drupal.php" 2>/dev/null || echo "unknown")
            echo "drupal_version=\$drupal_version"
        fi

        # Check for Drush and get module info
        if [ -f "vendor/bin/drush" ]; then
            echo "has_drush=y"

            # Module counts
            modules_enabled=\$(./vendor/bin/drush pm:list --status=enabled --format=count 2>/dev/null || echo "0")
            echo "modules_enabled=\$modules_enabled"

            # Custom modules (in modules/custom)
            if [ -d "$webroot/modules/custom" ]; then
                modules_custom=\$(find "$webroot/modules/custom" -maxdepth 1 -type d | wc -l)
                modules_custom=\$((modules_custom - 1))  # Subtract the directory itself
                echo "modules_custom=\$modules_custom"
            else
                echo "modules_custom=0"
            fi

            # Default theme
            default_theme=\$(./vendor/bin/drush config:get system.theme default --format=string 2>/dev/null || echo "unknown")
            echo "default_theme=\$default_theme"

            # Database table count
            db_tables=\$(./vendor/bin/drush sql:query 'SHOW TABLES' 2>/dev/null | wc -l)
            echo "db_tables=\$db_tables"

            # Try to get site URL
            site_url=\$(./vendor/bin/drush config:get system.site mail --format=string 2>/dev/null | grep -oP '@\K.*' || echo "")
            if [ -n "\$site_url" ]; then
                echo "site_domain=\$site_url"
            fi
        else
            echo "has_drush=n"
        fi

        # Files breakdown
        if [ -d "$webroot/sites/default/files" ]; then
            files_public=\$(du -sh "$webroot/sites/default/files" 2>/dev/null | cut -f1)
            echo "files_public=\$files_public"

            # Count files
            files_count=\$(find "$webroot/sites/default/files" -type f 2>/dev/null | wc -l)
            echo "files_count=\$files_count"
        fi

        # Private files
        if [ -d "private" ]; then
            files_private=\$(du -sh private 2>/dev/null | cut -f1)
            echo "files_private=\$files_private"
        fi

        # Check for composer.json
        if [ -f "composer.json" ]; then
            echo "has_composer=y"
        else
            echo "has_composer=n"
        fi

        # Check for custom themes
        if [ -d "$webroot/themes/custom" ]; then
            themes_custom=\$(find "$webroot/themes/custom" -maxdepth 1 -type d | wc -l)
            themes_custom=\$((themes_custom - 1))
            echo "themes_custom=\$themes_custom"
        else
            echo "themes_custom=0"
        fi

        # Check for config export directory
        if [ -d "config/sync" ]; then
            echo "has_config_export=y"
            config_files=\$(find config/sync -name "*.yml" 2>/dev/null | wc -l)
            echo "config_files=\$config_files"
        else
            echo "has_config_export=n"
        fi
REMOTE_ANALYZE
}

# Get the live URL of a remote site
# Usage: get_remote_site_url "user@host" "ssh_key" "site_dir"
get_remote_site_url() {
    local ssh_target="$1"
    local ssh_key="$2"
    local site_dir="$3"
    local ssh_opts=$(get_ssh_opts "$ssh_key")

    ssh $ssh_opts "$ssh_target" bash << REMOTE_URL
        cd "$site_dir" 2>/dev/null || exit 1

        if [ -f "vendor/bin/drush" ]; then
            # Try to get base URL from Drupal config
            base_url=\$(./vendor/bin/drush config:get system.site page.front 2>/dev/null)

            # Try state API
            if [ -z "\$base_url" ]; then
                base_url=\$(./vendor/bin/drush state:get system.base_url 2>/dev/null)
            fi

            # Try to determine from settings.php
            if [ -z "\$base_url" ]; then
                base_url=\$(grep -oP "\\$settings\\['trusted_host_patterns'\\].*?'\\.?\\K[a-zA-Z0-9.-]+(?=\\\\.)" */sites/default/settings.php 2>/dev/null | head -1)
                if [ -n "\$base_url" ]; then
                    base_url="https://\$base_url"
                fi
            fi

            echo "\$base_url"
        fi
REMOTE_URL
}

################################################################################
# Database Operations
################################################################################

# Dump database from remote site
# Usage: dump_remote_database "user@host" "ssh_key" "site_dir" "local_output_file"
dump_remote_database() {
    local ssh_target="$1"
    local ssh_key="$2"
    local site_dir="$3"
    local output_file="$4"
    local ssh_opts=$(get_ssh_opts "$ssh_key")

    print_info "Dumping database from $ssh_target..."

    ssh $ssh_opts "$ssh_target" "cd $site_dir && vendor/bin/drush sql:dump --gzip" > "$output_file"

    if [ -f "$output_file" ] && [ -s "$output_file" ]; then
        local size=$(du -h "$output_file" | cut -f1)
        print_status "OK" "Database dump complete: $size"
        return 0
    else
        print_error "Database dump failed or empty"
        return 1
    fi
}

################################################################################
# Server Configuration
################################################################################

# Get server configuration from nwp.yml
# Usage: get_server_config "server_name" "config_file"
# Output: Key=value pairs for ssh_host, ssh_key, label
get_server_config() {
    local server_name="$1"
    local config_file="${2:-nwp.yml}"

    if [ ! -f "$config_file" ]; then
        return 1
    fi

    awk -v server="$server_name" '
        /^linode:/ { in_linode = 1; next }
        in_linode && /^[a-zA-Z]/ && !/^  / { in_linode = 0 }
        in_linode && /^  servers:/ { in_servers = 1; next }
        in_servers && /^  [a-zA-Z]/ && !/^    / { in_servers = 0 }
        in_servers && $0 ~ "^    " server ":" { in_server = 1; next }
        in_server && /^    [a-zA-Z]/ && !/^      / { in_server = 0 }
        in_server && /^      ssh_host:/ {
            val = $0; sub(/^.*: */, "", val); gsub(/["'\'']/, "", val)
            print "SERVER_SSH_HOST=" val
        }
        in_server && /^      ssh_key:/ {
            val = $0; sub(/^.*: */, "", val); gsub(/["'\'']/, "", val)
            # Expand ~ to home directory
            gsub(/^~/, ENVIRON["HOME"], val)
            print "SERVER_SSH_KEY=" val
        }
        in_server && /^      label:/ {
            val = $0; sub(/^.*: */, "", val); gsub(/["'\'']/, "", val)
            print "SERVER_LABEL=" val
        }
    ' "$config_file"
}

# List all configured servers from nwp.yml
# Usage: list_configured_servers "config_file"
# Output: server_name|ssh_host|label (one per line)
list_configured_servers() {
    local config_file="${1:-nwp.yml}"

    if [ ! -f "$config_file" ]; then
        return 1
    fi

    awk '
        /^linode:/ { in_linode = 1; next }
        in_linode && /^[a-zA-Z]/ && !/^  / { in_linode = 0 }
        in_linode && /^  servers:/ { in_servers = 1; next }
        in_servers && /^  [a-zA-Z]/ && !/^    / { in_servers = 0 }
        in_servers && /^    [a-zA-Z_-]+:/ && !/^      / {
            if (server_name != "") {
                print server_name "|" ssh_host "|" label
            }
            server_name = $0
            sub(/:.*/, "", server_name)
            gsub(/^[ \t]+/, "", server_name)
            ssh_host = ""
            label = ""
        }
        in_servers && /^      ssh_host:/ {
            ssh_host = $0; sub(/^.*: */, "", ssh_host); gsub(/["'\'']/, "", ssh_host)
        }
        in_servers && /^      label:/ {
            label = $0; sub(/^.*: */, "", label); gsub(/["'\'']/, "", label)
        }
        END {
            if (server_name != "") {
                print server_name "|" ssh_host "|" label
            }
        }
    ' "$config_file"
}

################################################################################
# Export Functions
################################################################################

export -f test_ssh_connection
export -f get_ssh_opts
export -f scan_server_for_sites
export -f parse_site_json
export -f analyze_remote_site
export -f get_remote_site_url
export -f dump_remote_database
export -f get_server_config
export -f list_configured_servers
