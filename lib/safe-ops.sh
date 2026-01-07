#!/bin/bash
#
# safe-ops.sh - Safe operations proxy for AI assistants
#
# These functions can be called by Claude Code and return sanitized output.
# They internally use data secrets but never expose them in output.
#
# Usage:
#   source lib/safe-ops.sh
#   safe_server_status prod1
#
# See docs/DATA_SECURITY_BEST_PRACTICES.md for the security architecture.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source required libraries
source "$SCRIPT_DIR/lib/ui.sh" 2>/dev/null || true
source "$SCRIPT_DIR/lib/common.sh"

################################################################################
# Server Status Operations
################################################################################

# Get sanitized server status (no credentials or user data)
# Usage: safe_server_status <server_name>
# Returns: Status, CPU, Memory, Disk (no IPs, no credentials)
safe_server_status() {
    local server="${1:-}"

    if [ -z "$server" ]; then
        echo "Usage: safe_server_status <server_name>"
        return 1
    fi

    # Get credentials from data secrets (not exposed)
    local ssh_key=$(get_data_secret_nested "production_ssh.${server}.key_path" "")
    local ssh_user=$(get_data_secret_nested "production_ssh.${server}.user" "")
    local ssh_host=$(get_data_secret_nested "production_ssh.${server}.host" "")

    if [ -z "$ssh_host" ]; then
        echo "Server not configured: $server"
        return 1
    fi

    # Expand ~ in key path
    ssh_key="${ssh_key/#\~/$HOME}"

    # Execute remote command and sanitize output
    local status_output
    status_output=$(ssh -i "$ssh_key" -o StrictHostKeyChecking=no -o BatchMode=yes \
        "${ssh_user}@${ssh_host}" \
        'echo "Status: $(systemctl is-system-running 2>/dev/null || echo unknown)"; \
         echo "Uptime: $(uptime -p 2>/dev/null || echo unknown)"; \
         echo "Load: $(cat /proc/loadavg | cut -d" " -f1-3)"; \
         echo "Memory: $(free -h | awk "/^Mem:/ {print \$3\"/\"\$2}")"; \
         echo "Disk: $(df -h / | awk "NR==2 {print \$3\"/\"\$2\" (\"\$5\" used)\"}")"' \
        2>/dev/null) || {
        echo "Status: unreachable"
        return 1
    }

    # Output sanitized status (no IPs, no paths with user data)
    echo "=== Server: $server ==="
    echo "$status_output"
}

# Get sanitized site status
# Usage: safe_site_status <sitename>
# Returns: Drupal status without credentials
safe_site_status() {
    local site="${1:-}"

    if [ -z "$site" ]; then
        echo "Usage: safe_site_status <sitename>"
        return 1
    fi

    local site_dir="$PROJECT_ROOT/$site"

    if [ ! -d "$site_dir" ]; then
        echo "Site not found: $site"
        return 1
    fi

    # Check if DDEV is running
    local ddev_status
    ddev_status=$(cd "$site_dir" && ddev describe 2>/dev/null | grep -E "^(OK|Router)" | head -1) || ddev_status="DDEV not running"

    echo "=== Site: $site ==="
    echo "DDEV: $ddev_status"

    # Get Drupal status if available (sanitized)
    if [ -d "$site_dir/html" ]; then
        local drupal_status
        drupal_status=$(cd "$site_dir" && ddev drush status --format=list 2>/dev/null | \
            grep -E "^(Drupal version|Site URI|PHP|Database driver)" | \
            head -5) || drupal_status="Drupal status unavailable"
        echo "$drupal_status"
    fi
}

################################################################################
# Database Operations (Sanitized)
################################################################################

# Get sanitized database info (no credentials, no user data)
# Usage: safe_db_status <sitename>
# Returns: Table count, size, last backup time
safe_db_status() {
    local site="${1:-}"

    if [ -z "$site" ]; then
        echo "Usage: safe_db_status <sitename>"
        return 1
    fi

    local site_dir="$PROJECT_ROOT/$site"

    if [ ! -d "$site_dir" ]; then
        echo "Site not found: $site"
        return 1
    fi

    echo "=== Database: $site ==="

    # Get table count and size via drush (no actual data)
    local db_info
    db_info=$(cd "$site_dir" && ddev drush sql:query \
        "SELECT COUNT(*) as tables FROM information_schema.tables WHERE table_schema = DATABASE(); \
         SELECT ROUND(SUM(data_length + index_length) / 1024 / 1024, 2) as size_mb FROM information_schema.tables WHERE table_schema = DATABASE();" \
        2>/dev/null) || {
        echo "Database status unavailable"
        return 1
    }

    local table_count=$(echo "$db_info" | head -1)
    local size_mb=$(echo "$db_info" | tail -1)

    echo "Tables: $table_count"
    echo "Size: ${size_mb}MB"

    # Check for recent backups
    local backup_dir="$PROJECT_ROOT/sitebackups/$site"
    if [ -d "$backup_dir" ]; then
        local last_backup=$(ls -t "$backup_dir"/*.sql.gz 2>/dev/null | head -1)
        if [ -n "$last_backup" ]; then
            local backup_age=$(( ($(date +%s) - $(stat -c %Y "$last_backup")) / 3600 ))
            echo "Last backup: ${backup_age}h ago"
        else
            echo "Last backup: none found"
        fi
    fi
}

################################################################################
# Deployment Operations (No output of file contents)
################################################################################

# Trigger deployment via script (returns job status, not file contents)
# Usage: safe_deploy <sitename> [environment]
# Returns: Deployment status message only
safe_deploy() {
    local site="${1:-}"
    local env="${2:-staging}"

    if [ -z "$site" ]; then
        echo "Usage: safe_deploy <sitename> [environment]"
        return 1
    fi

    echo "=== Deploy: $site to $env ==="

    # Check prerequisites
    local site_dir="$PROJECT_ROOT/$site"
    if [ ! -d "$site_dir" ]; then
        echo "Error: Site not found"
        return 1
    fi

    # For staging, use standard stg2prod
    if [ "$env" = "staging" ]; then
        echo "Status: Would deploy to staging"
        echo "Command: ./stg2prod.sh $site (run manually)"
        return 0
    fi

    # For production, require explicit confirmation (not automated)
    if [ "$env" = "production" ]; then
        echo "Status: Production deployment requires manual confirmation"
        echo "Command: ./stg2prod.sh --prod $site (run manually)"
        echo "WARNING: Review changes before deploying to production"
        return 0
    fi

    echo "Error: Unknown environment: $env"
    return 1
}

################################################################################
# Backup Operations (Sanitized)
################################################################################

# List recent backups (no file contents)
# Usage: safe_backup_list <sitename>
# Returns: Backup filenames and sizes only
safe_backup_list() {
    local site="${1:-}"

    if [ -z "$site" ]; then
        echo "Usage: safe_backup_list <sitename>"
        return 1
    fi

    local backup_dir="$PROJECT_ROOT/sitebackups/$site"

    echo "=== Backups: $site ==="

    if [ ! -d "$backup_dir" ]; then
        echo "No backup directory found"
        return 0
    fi

    # List backups with sanitized info (no paths that reveal structure)
    ls -lh "$backup_dir"/*.sql.gz 2>/dev/null | \
        awk '{print $9 ": " $5 " (" $6 " " $7 " " $8 ")"}' | \
        sed "s|$backup_dir/||g" | \
        tail -10 || echo "No backups found"
}

# Trigger backup (returns status, not contents)
# Usage: safe_backup_create <sitename>
# Returns: Backup status message
safe_backup_create() {
    local site="${1:-}"

    if [ -z "$site" ]; then
        echo "Usage: safe_backup_create <sitename>"
        return 1
    fi

    echo "=== Create Backup: $site ==="
    echo "Command: ./backup.sh -by $site (run manually)"
    echo "Status: Use backup.sh directly for backup operations"
    return 0
}

################################################################################
# Log Operations (Sanitized - no user data)
################################################################################

# Get recent errors (sanitized, no PII)
# Usage: safe_recent_errors <sitename>
# Returns: Error counts and types, not actual messages
safe_recent_errors() {
    local site="${1:-}"

    if [ -z "$site" ]; then
        echo "Usage: safe_recent_errors <sitename>"
        return 1
    fi

    local site_dir="$PROJECT_ROOT/$site"

    if [ ! -d "$site_dir" ]; then
        echo "Site not found: $site"
        return 1
    fi

    echo "=== Recent Errors: $site ==="

    # Get error summary from watchdog (types and counts, not messages)
    local error_summary
    error_summary=$(cd "$site_dir" && ddev drush sql:query \
        "SELECT type, severity, COUNT(*) as count FROM watchdog WHERE severity <= 3 AND timestamp > UNIX_TIMESTAMP() - 86400 GROUP BY type, severity ORDER BY count DESC LIMIT 10;" \
        2>/dev/null) || {
        echo "Error log unavailable"
        return 1
    }

    if [ -z "$error_summary" ]; then
        echo "No errors in last 24 hours"
    else
        echo "Type | Severity | Count"
        echo "------------------------"
        echo "$error_summary"
    fi
}

################################################################################
# Security Operations
################################################################################

# Check for security updates (no credentials exposed)
# Usage: safe_security_check <sitename>
# Returns: Count of available security updates
safe_security_check() {
    local site="${1:-}"

    if [ -z "$site" ]; then
        echo "Usage: safe_security_check <sitename>"
        return 1
    fi

    local site_dir="$PROJECT_ROOT/$site"

    if [ ! -d "$site_dir" ]; then
        echo "Site not found: $site"
        return 1
    fi

    echo "=== Security Check: $site ==="

    # Check for security updates
    local security_updates
    security_updates=$(cd "$site_dir" && ddev drush pm:security 2>/dev/null) || {
        echo "Security check unavailable"
        return 1
    }

    if echo "$security_updates" | grep -q "No security updates"; then
        echo "Status: All modules up to date"
    else
        local update_count=$(echo "$security_updates" | grep -c "SECURITY UPDATE" || echo "0")
        echo "Status: $update_count security updates available"
        echo "Run: ddev drush pm:security (in $site directory)"
    fi
}

################################################################################
# Export for subshells
################################################################################

export -f safe_server_status
export -f safe_site_status
export -f safe_db_status
export -f safe_deploy
export -f safe_backup_list
export -f safe_backup_create
export -f safe_recent_errors
export -f safe_security_check
