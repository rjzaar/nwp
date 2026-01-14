#!/bin/bash

################################################################################
# NWP Remote Site Operations Library
#
# Support for operations on remote servers
# Source this file: source "$SCRIPT_DIR/lib/remote.sh"
#
# Dependencies: lib/ui.sh, lib/common.sh, lib/ssh.sh
################################################################################

# Source SSH library for security controls
# Only source if not already loaded
if [ -z "$(type -t get_ssh_host_key_checking)" ]; then
    # Try to find and source lib/ssh.sh
    if [ -n "${PROJECT_ROOT:-}" ] && [ -f "$PROJECT_ROOT/lib/ssh.sh" ]; then
        source "$PROJECT_ROOT/lib/ssh.sh"
    elif [ -f "$(dirname "${BASH_SOURCE[0]}")/ssh.sh" ]; then
        source "$(dirname "${BASH_SOURCE[0]}")/ssh.sh"
    fi
fi

# Parse remote notation (@env sitename)
# Usage: parse_remote_target "@prod sitename" -> returns "prod sitename"
parse_remote_target() {
    local target="$1"

    if [[ "$target" == @* ]]; then
        local env="${target#@}"
        echo "$env"
        return 0
    fi

    echo ""
    return 1
}

# Get remote configuration from cnwp.yml
# Usage: get_remote_config "sitename" "environment"
get_remote_config() {
    local sitename="$1"
    local environment="$2"
    local cnwp_file="${PROJECT_ROOT}/cnwp.yml"

    if [ ! -f "$cnwp_file" ]; then
        return 1
    fi

    # Parse site configuration for the environment
    awk -v site="$sitename" -v env="$environment" '
        /^sites:/ { in_sites = 1; next }
        in_sites && /^[a-zA-Z]/ && !/^  / { in_sites = 0 }
        in_sites && $0 ~ "^  " site ":" { in_site = 1; next }
        in_site && /^  [a-zA-Z]/ && !/^    / { in_site = 0 }
        in_site && $0 ~ "^    " env ":" { in_env = 1; next }
        in_env && /^    [a-zA-Z]/ && !/^      / { in_env = 0 }
        in_env && /^      / {
            key = $0
            gsub(/^      /, "", key)
            gsub(/:.*/, "", key)
            val = $0
            gsub(/.*: */, "", val)
            gsub(/["'"'"']/, "", val)
            print key "=" val
        }
    ' "$cnwp_file"
}

# Execute command on remote server
# Usage: remote_exec "sitename" "environment" "command"
# SECURITY: This function executes commands on remote servers. Input validation
# is performed but callers should ensure commands are safe.
remote_exec() {
    local sitename="$1"
    local environment="$2"
    local command="$3"

    # Input validation - prevent path traversal and injection in sitename/environment
    if [[ "$sitename" =~ [^a-zA-Z0-9._-] ]]; then
        print_error "Invalid sitename: contains unsafe characters"
        return 1
    fi
    if [[ "$environment" =~ [^a-zA-Z0-9._-] ]]; then
        print_error "Invalid environment: contains unsafe characters"
        return 1
    fi

    # Get remote config
    local config
    config=$(get_remote_config "$sitename" "$environment")

    if [ -z "$config" ]; then
        print_error "No configuration found for ${sitename}@${environment}"
        return 1
    fi

    # Parse config
    local server_ip=""
    local ssh_user="root"
    local site_path="/var/www/html"

    while IFS='=' read -r key val; do
        case "$key" in
            server_ip|ip) server_ip="$val" ;;
            ssh_user|user) ssh_user="$val" ;;
            path|site_path) site_path="$val" ;;
        esac
    done <<< "$config"

    if [ -z "$server_ip" ]; then
        print_error "No server IP configured for ${sitename}@${environment}"
        return 1
    fi

    # Validate site_path - must be absolute path without dangerous characters
    if [[ ! "$site_path" =~ ^/[a-zA-Z0-9./_-]+$ ]]; then
        print_error "Invalid site_path: must be absolute path with safe characters"
        return 1
    fi

    ocmsg "Executing on ${ssh_user}@${server_ip}..."
    # SECURITY FIX: Properly quote variables in SSH command to prevent injection
    # The site_path is validated above; command is passed as-is (caller's responsibility)
    ssh -o BatchMode=yes -o ConnectTimeout=10 "${ssh_user}@${server_ip}" \
        "cd '${site_path}' && ${command}"
}

# Run drush on remote server
# Usage: remote_drush "sitename" "environment" "drush-command"
remote_drush() {
    local sitename="$1"
    local environment="$2"
    shift 2
    local drush_cmd="$*"

    remote_exec "$sitename" "$environment" "drush ${drush_cmd}"
}

# Backup remote site
# Usage: remote_backup "sitename" "environment" "local_path"
remote_backup() {
    local sitename="$1"
    local environment="$2"
    local local_path="${3:-.}"

    print_header "Remote Backup: ${sitename}@${environment}"

    # Get remote config
    local config=$(get_remote_config "$sitename" "$environment")
    local server_ip=""
    local ssh_user="root"
    local site_path="/var/www/html"

    while IFS='=' read -r key val; do
        case "$key" in
            server_ip|ip) server_ip="$val" ;;
            ssh_user|user) ssh_user="$val" ;;
            path|site_path) site_path="$val" ;;
        esac
    done <<< "$config"

    if [ -z "$server_ip" ]; then
        print_error "No server IP configured"
        return 1
    fi

    local timestamp
    timestamp=$(date +%Y%m%dT%H%M%S)
    # SECURITY: backup_name uses validated sitename/environment + timestamp (safe characters only)
    local backup_name="${sitename}-${environment}-${timestamp}"

    # Export database on remote
    print_info "Exporting database on remote..."
    # SECURITY FIX: Quote backup_name in remote command
    remote_exec "$sitename" "$environment" \
        "drush sql-dump --gzip > '/tmp/${backup_name}.sql.gz'"

    # Download
    print_info "Downloading backup..."
    # SECURITY FIX: Quote paths properly in scp command
    scp "${ssh_user}@${server_ip}:/tmp/${backup_name}.sql.gz" "${local_path}/"

    # Cleanup remote
    # SECURITY FIX: Quote path in remote rm command
    remote_exec "$sitename" "$environment" "rm '/tmp/${backup_name}.sql.gz'"

    if [ -f "${local_path}/${backup_name}.sql.gz" ]; then
        print_status "OK" "Remote backup saved: ${local_path}/${backup_name}.sql.gz"
        return 0
    fi

    print_error "Backup download failed"
    return 1
}

# Test remote connection
# Usage: remote_test "sitename" "environment"
remote_test() {
    local sitename="$1"
    local environment="$2"

    print_info "Testing connection to ${sitename}@${environment}..."

    if remote_exec "$sitename" "$environment" "echo 'Connection OK'"; then
        print_status "OK" "Remote connection successful"
        return 0
    else
        print_error "Remote connection failed"
        return 1
    fi
}

# Run Behat tests on remote (read-only)
# Usage: remote_test_behat "sitename" "environment" ["tags"]
remote_test_behat() {
    local sitename="$1"
    local environment="$2"
    local tags="${3:-@smoke}"

    print_header "Remote Behat Tests: ${sitename}@${environment}"

    # Only run non-destructive tests on production
    if [ "$environment" == "prod" ]; then
        tags="~@destructive and ${tags}"
    fi

    remote_exec "$sitename" "$environment" \
        "vendor/bin/behat --tags='${tags}' --format=progress"
}
