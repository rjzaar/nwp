#!/bin/bash

################################################################################
# NWP State Detection Library
#
# Functions for detecting the current state of sites, backups, and environments
# Source this file: source "$SCRIPT_DIR/lib/state.sh"
#
# Requires: lib/ui.sh to be sourced first
################################################################################

# Check if a site directory exists and has DDEV config
# Usage: site_exists "sitename"
# Returns: 0 if exists, 1 if not
site_exists() {
    local sitename="$1"
    local script_dir="${PROJECT_ROOT:-$(dirname "${BASH_SOURCE[0]}")/..}"

    if [ -d "$script_dir/sites/$sitename" ] && [ -f "$script_dir/sites/$sitename/.ddev/config.yaml" ]; then
        return 0
    fi
    return 1
}

# Check if a site's DDEV is running
# Usage: site_running "sitename"
# Returns: 0 if running, 1 if not
site_running() {
    local sitename="$1"
    local script_dir="${PROJECT_ROOT:-$(dirname "${BASH_SOURCE[0]}")/..}"

    if ! site_exists "$sitename"; then
        return 1
    fi

    local status=$(cd "$script_dir/sites/$sitename" && ddev describe 2>/dev/null | grep -c "running")
    if [ "$status" -gt 0 ]; then
        return 0
    fi
    return 1
}

# Get the staging site name from base name
# Usage: get_staging_name "sitename"
get_staging_name() {
    local sitename="$1"
    # Remove any existing -stg or _stg suffix first (support both for migration)
    local base="${sitename%-stg}"
    base="${base%_stg}"
    echo "${base}-stg"
}

# Find recent backup files
# Usage: find_recent_backup "sitename" [max_hours]
# Returns: path to most recent backup or empty string
find_recent_backup() {
    local sitename="$1"
    local max_hours="${2:-24}"
    local script_dir="${PROJECT_ROOT:-$(dirname "${BASH_SOURCE[0]}")/..}"
    local backup_dir="$script_dir/sitebackups/$sitename"

    if [ ! -d "$backup_dir" ]; then
        return 1
    fi

    # Find most recent .sql.gz file within max_hours
    local recent_backup=$(find "$backup_dir" -name "*.sql.gz" -mmin -$((max_hours * 60)) -type f 2>/dev/null | \
        xargs -r ls -t 2>/dev/null | head -1)

    if [ -n "$recent_backup" ]; then
        echo "$recent_backup"
        return 0
    fi
    return 1
}

# Find recent sanitized backup
# Usage: find_sanitized_backup "sitename" [max_hours]
find_sanitized_backup() {
    local sitename="$1"
    local max_hours="${2:-24}"
    local script_dir="${PROJECT_ROOT:-$(dirname "${BASH_SOURCE[0]}")/..}"
    local backup_dir="$script_dir/sitebackups/$sitename/sanitized"

    if [ ! -d "$backup_dir" ]; then
        # Check for sanitized marker in main backup dir
        backup_dir="$script_dir/sitebackups/$sitename"
        local recent_backup=$(find "$backup_dir" -name "*sanitized*.sql.gz" -mmin -$((max_hours * 60)) -type f 2>/dev/null | \
            xargs -r ls -t 2>/dev/null | head -1)
        if [ -n "$recent_backup" ]; then
            echo "$recent_backup"
            return 0
        fi
        return 1
    fi

    local recent_backup=$(find "$backup_dir" -name "*.sql.gz" -mmin -$((max_hours * 60)) -type f 2>/dev/null | \
        xargs -r ls -t 2>/dev/null | head -1)

    if [ -n "$recent_backup" ]; then
        echo "$recent_backup"
        return 0
    fi
    return 1
}

# Get backup age in human-readable format
# Usage: backup_age_human "/path/to/backup.sql.gz"
backup_age_human() {
    local backup_file="$1"

    if [ ! -f "$backup_file" ]; then
        echo "not found"
        return 1
    fi

    local file_time=$(stat -c %Y "$backup_file" 2>/dev/null || stat -f %m "$backup_file" 2>/dev/null)
    local now=$(date +%s)
    local age_seconds=$((now - file_time))

    if [ $age_seconds -lt 60 ]; then
        echo "${age_seconds} seconds ago"
    elif [ $age_seconds -lt 3600 ]; then
        echo "$((age_seconds / 60)) minutes ago"
    elif [ $age_seconds -lt 86400 ]; then
        echo "$((age_seconds / 3600)) hours ago"
    else
        echo "$((age_seconds / 86400)) days ago"
    fi
}

# Check if production is accessible via SSH
# Usage: check_prod_ssh "sitename"
# Returns: 0 if accessible, 1 if not
check_prod_ssh() {
    local sitename="$1"
    local script_dir="${PROJECT_ROOT:-$(dirname "${BASH_SOURCE[0]}")/..}"
    local config_file="$script_dir/nwp.yml"

    # Get live config from nwp.yml
    if [ ! -f "$config_file" ]; then
        return 1
    fi

    # Check if site has live configuration
    local has_live=$(grep -A 20 "^  $sitename:" "$config_file" 2>/dev/null | grep -c "live:")
    if [ "$has_live" -eq 0 ]; then
        return 1
    fi

    # Get SSH details - simplified check
    local server_ip=$(grep -A 30 "^  $sitename:" "$config_file" 2>/dev/null | \
        grep -A 10 "live:" | grep "server_ip:" | head -1 | awk '{print $2}')

    if [ -z "$server_ip" ]; then
        return 1
    fi

    # Try SSH connection with timeout
    if ssh -o ConnectTimeout=5 -o BatchMode=yes "$server_ip" exit 2>/dev/null; then
        return 0
    fi
    return 1
}

# Check if site has live configuration
# Usage: has_live_config "sitename"
has_live_config() {
    local sitename="$1"
    local script_dir="${PROJECT_ROOT:-$(dirname "${BASH_SOURCE[0]}")/..}"
    local config_file="$script_dir/nwp.yml"

    if [ ! -f "$config_file" ]; then
        return 1
    fi

    local has_live=$(grep -A 30 "^  $sitename:" "$config_file" 2>/dev/null | grep -c "live:")
    if [ "$has_live" -gt 0 ]; then
        return 0
    fi
    return 1
}

# Get live domain for a site
# Usage: get_live_domain "sitename"
get_live_domain() {
    local sitename="$1"
    local script_dir="${PROJECT_ROOT:-$(dirname "${BASH_SOURCE[0]}")/..}"
    local config_file="$script_dir/nwp.yml"

    if [ ! -f "$config_file" ]; then
        return 1
    fi

    local domain=$(grep -A 30 "^  $sitename:" "$config_file" 2>/dev/null | \
        grep -A 10 "live:" | grep "domain:" | head -1 | awk '{print $2}')

    if [ -n "$domain" ]; then
        echo "$domain"
        return 0
    fi
    return 1
}

# Detect available test suites for a site
# Usage: detect_test_suites "sitename"
# Returns: comma-separated list of available test types
detect_test_suites() {
    local sitename="$1"
    local script_dir="${PROJECT_ROOT:-$(dirname "${BASH_SOURCE[0]}")/..}"
    local site_path="$script_dir/sites/$sitename"
    local available=""

    if [ ! -d "$site_path" ]; then
        echo ""
        return 1
    fi

    # Check for PHPUnit
    if [ -f "$site_path/phpunit.xml" ] || [ -f "$site_path/phpunit.xml.dist" ]; then
        available="${available}phpunit,"
    fi

    # Check for Behat
    if [ -f "$site_path/behat.yml" ] || [ -f "$site_path/behat.yml.dist" ]; then
        available="${available}behat,"
    fi

    # Check for PHPStan
    if [ -f "$site_path/phpstan.neon" ] || [ -f "$site_path/phpstan.neon.dist" ]; then
        available="${available}phpstan,"
    fi

    # Check for PHPCS
    if [ -f "$site_path/phpcs.xml" ] || [ -f "$site_path/phpcs.xml.dist" ]; then
        available="${available}phpcs,"
    fi

    # Check for ESLint (in theme or root)
    if [ -f "$site_path/.eslintrc.json" ] || [ -f "$site_path/.eslintrc.js" ] || \
       find "$site_path" -maxdepth 3 -name ".eslintrc*" -type f 2>/dev/null | grep -q .; then
        available="${available}eslint,"
    fi

    # Check for Stylelint
    if [ -f "$site_path/.stylelintrc" ] || [ -f "$site_path/.stylelintrc.json" ] || \
       find "$site_path" -maxdepth 3 -name ".stylelintrc*" -type f 2>/dev/null | grep -q .; then
        available="${available}stylelint,"
    fi

    # Security check is always available (drush pm:security)
    available="${available}security,"

    # Remove trailing comma
    echo "${available%,}"
}

# Get comprehensive state for a site
# Usage: get_site_state "sitename"
# Outputs state variables to stdout as key=value pairs
get_site_state() {
    local sitename="$1"
    local stg_name=$(get_staging_name "$sitename")

    echo "SITENAME=$sitename"
    echo "STG_NAME=$stg_name"

    # Check dev site
    if site_exists "$sitename"; then
        echo "DEV_EXISTS=true"
        if site_running "$sitename"; then
            echo "DEV_RUNNING=true"
        else
            echo "DEV_RUNNING=false"
        fi
    else
        echo "DEV_EXISTS=false"
        echo "DEV_RUNNING=false"
    fi

    # Check staging site
    if site_exists "$stg_name"; then
        echo "STG_EXISTS=true"
        if site_running "$stg_name"; then
            echo "STG_RUNNING=true"
        else
            echo "STG_RUNNING=false"
        fi
    else
        echo "STG_EXISTS=false"
        echo "STG_RUNNING=false"
    fi

    # Check backups
    local recent_backup=$(find_recent_backup "$sitename" 24)
    if [ -n "$recent_backup" ]; then
        echo "RECENT_BACKUP=$recent_backup"
        echo "BACKUP_AGE=$(backup_age_human "$recent_backup")"
    else
        echo "RECENT_BACKUP="
        echo "BACKUP_AGE="
    fi

    local sanitized_backup=$(find_sanitized_backup "$sitename" 24)
    if [ -n "$sanitized_backup" ]; then
        echo "SANITIZED_BACKUP=$sanitized_backup"
        echo "SANITIZED_AGE=$(backup_age_human "$sanitized_backup")"
    else
        echo "SANITIZED_BACKUP="
        echo "SANITIZED_AGE="
    fi

    # Check production
    if has_live_config "$sitename"; then
        echo "HAS_LIVE_CONFIG=true"
        echo "LIVE_DOMAIN=$(get_live_domain "$sitename")"
        if check_prod_ssh "$sitename"; then
            echo "PROD_ACCESSIBLE=true"
        else
            echo "PROD_ACCESSIBLE=false"
        fi
    else
        echo "HAS_LIVE_CONFIG=false"
        echo "LIVE_DOMAIN="
        echo "PROD_ACCESSIBLE=false"
    fi

    # Check available tests
    local tests=$(detect_test_suites "$sitename")
    echo "AVAILABLE_TESTS=$tests"
}

# Load state into current shell environment
# Usage: eval "$(load_site_state "sitename")"
load_site_state() {
    get_site_state "$1"
}
