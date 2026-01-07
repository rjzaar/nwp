#!/bin/bash

################################################################################
# NWP Database Router Library
#
# Multi-source database download and management inspired by Vortex
# Source this file: source "$SCRIPT_DIR/lib/database-router.sh"
#
# Requires: lib/ui.sh, lib/state.sh, lib/sanitize.sh to be sourced first
################################################################################

# Database source types
DB_SOURCE_AUTO="auto"
DB_SOURCE_PRODUCTION="production"
DB_SOURCE_BACKUP="backup"
DB_SOURCE_DEVELOPMENT="development"
DB_SOURCE_URL="url"

################################################################################
# Main Router Function
################################################################################

# Download/restore database from various sources
# Usage: download_database "sitename" "source" ["target_site"]
#   source can be:
#     auto                  - Intelligent source selection
#     production            - Fresh from production server
#     backup:/path/to/file  - Specific backup file
#     development           - Clone from dev site
#     url:https://...       - Download from URL
#
# Returns: 0 on success, 1 on failure
download_database() {
    local sitename="$1"
    local source="$2"
    local target_site="${3:-$sitename}"
    local script_dir="${PROJECT_ROOT:-$(dirname "${BASH_SOURCE[0]}")/..}"

    case "$source" in
        auto|"")
            download_db_auto "$sitename" "$target_site"
            ;;
        production)
            download_db_production "$sitename" "$target_site"
            ;;
        backup:*)
            local file="${source#backup:}"
            download_db_backup "$file" "$target_site"
            ;;
        development)
            download_db_development "$sitename" "$target_site"
            ;;
        url:*)
            local url="${source#url:}"
            download_db_url "$url" "$target_site"
            ;;
        *)
            # Assume it's a file path
            if [ -f "$source" ]; then
                download_db_backup "$source" "$target_site"
            else
                fail "Unknown database source: $source"
                return 1
            fi
            ;;
    esac
}

################################################################################
# Source-Specific Handlers
################################################################################

# Auto-select best database source
download_db_auto() {
    local sitename="$1"
    local target_site="$2"
    local script_dir="${PROJECT_ROOT:-$(dirname "${BASH_SOURCE[0]}")/..}"

    info "Auto-selecting database source for $sitename..."

    # Priority 1: Recent sanitized backup (< 24 hours)
    local sanitized_backup=$(find_sanitized_backup "$sitename" 24)
    if [ -n "$sanitized_backup" ]; then
        task "Found recent sanitized backup"
        note "$(basename "$sanitized_backup") - $(backup_age_human "$sanitized_backup")"
        download_db_backup "$sanitized_backup" "$target_site"
        return $?
    fi

    # Priority 2: Recent regular backup (< 24 hours)
    local recent_backup=$(find_recent_backup "$sitename" 24)
    if [ -n "$recent_backup" ]; then
        task "Found recent backup (will sanitize)"
        note "$(basename "$recent_backup") - $(backup_age_human "$recent_backup")"
        download_db_backup "$recent_backup" "$target_site"
        sanitize_staging_db "$target_site"
        return $?
    fi

    # Priority 3: Production (if accessible)
    if has_live_config "$sitename" && check_prod_ssh "$sitename"; then
        task "Production accessible - creating fresh backup"
        download_db_production "$sitename" "$target_site"
        return $?
    fi

    # Priority 4: Clone from development
    if site_exists "$sitename" && [ "$sitename" != "$target_site" ]; then
        task "Using development database"
        download_db_development "$sitename" "$target_site"
        return $?
    fi

    fail "No database source available"
    note "Options: Create a backup, configure production SSH, or use --dev-db"
    return 1
}

# Download from production server
download_db_production() {
    local sitename="$1"
    local target_site="$2"
    local script_dir="${PROJECT_ROOT:-$(dirname "${BASH_SOURCE[0]}")/..}"
    local config_file="$script_dir/cnwp.yml"

    info "Downloading database from production..."

    # Get SSH details from config
    local server_ip=$(grep -A 30 "^  $sitename:" "$config_file" 2>/dev/null | \
        grep -A 10 "live:" | grep "server_ip:" | head -1 | awk '{print $2}')
    local domain=$(grep -A 30 "^  $sitename:" "$config_file" 2>/dev/null | \
        grep -A 10 "live:" | grep "domain:" | head -1 | awk '{print $2}')

    if [ -z "$server_ip" ]; then
        fail "No server_ip configured for $sitename"
        return 1
    fi

    # Create backup directory
    local backup_dir="$script_dir/sitebackups/$sitename"
    mkdir -p "$backup_dir"

    local timestamp=$(date +%Y%m%dT%H%M%S)
    local backup_file="$backup_dir/prod-${timestamp}.sql.gz"

    task "Connecting to $server_ip..."

    # Try to dump database from production
    # Assumes drush is available on production server
    local remote_path="/var/www/$sitename"

    if ssh -o ConnectTimeout=10 "$server_ip" "cd $remote_path && drush sql:dump --gzip" > "$backup_file" 2>/dev/null; then
        pass "Database downloaded from production"
        note "Saved to: $backup_file"

        # Import to target
        download_db_backup "$backup_file" "$target_site"

        # Sanitize after import
        sanitize_staging_db "$target_site"

        return 0
    else
        fail "Could not download database from production"
        rm -f "$backup_file"
        return 1
    fi
}

# Restore from backup file
download_db_backup() {
    local backup_file="$1"
    local target_site="$2"
    local script_dir="${PROJECT_ROOT:-$(dirname "${BASH_SOURCE[0]}")/..}"

    if [ ! -f "$backup_file" ]; then
        fail "Backup file not found: $backup_file"
        return 1
    fi

    info "Restoring database from backup..."
    task "File: $(basename "$backup_file")"

    local original_dir=$(pwd)
    cd "$script_dir/sites/$target_site" || {
        fail "Cannot access target site: $target_site"
        return 1
    }

    # Ensure DDEV is running
    if ! ddev describe &>/dev/null; then
        task "Starting DDEV..."
        ddev start || {
            fail "Could not start DDEV"
            cd "$original_dir"
            return 1
        }
    fi

    # Drop existing database
    task "Dropping existing database..."
    ddev drush sql:drop -y &>/dev/null

    # Import based on file type
    task "Importing database..."
    if [[ "$backup_file" == *.gz ]]; then
        if gunzip -c "$backup_file" | ddev drush sql:cli 2>/dev/null; then
            pass "Database restored from backup"
        else
            fail "Database import failed"
            cd "$original_dir"
            return 1
        fi
    else
        if ddev drush sql:cli < "$backup_file" 2>/dev/null; then
            pass "Database restored from backup"
        else
            fail "Database import failed"
            cd "$original_dir"
            return 1
        fi
    fi

    cd "$original_dir"
    return 0
}

# Clone from development site
download_db_development() {
    local source_site="$1"
    local target_site="$2"
    local script_dir="${PROJECT_ROOT:-$(dirname "${BASH_SOURCE[0]}")/..}"

    if [ "$source_site" = "$target_site" ]; then
        fail "Source and target cannot be the same"
        return 1
    fi

    info "Cloning database from $source_site to $target_site..."

    local original_dir=$(pwd)

    # Ensure source is running
    cd "$script_dir/sites/$source_site" || {
        fail "Cannot access source site: $source_site"
        return 1
    }

    if ! ddev describe &>/dev/null; then
        task "Starting source DDEV..."
        ddev start || {
            fail "Could not start source DDEV"
            cd "$original_dir"
            return 1
        }
    fi

    # Create temporary dump
    local temp_dump=$(mktemp --suffix=.sql)
    task "Exporting from $source_site..."

    if ! ddev drush sql:dump > "$temp_dump" 2>/dev/null; then
        fail "Could not export database from $source_site"
        rm -f "$temp_dump"
        cd "$original_dir"
        return 1
    fi

    # Ensure target is running
    cd "$script_dir/sites/$target_site" || {
        fail "Cannot access target site: $target_site"
        rm -f "$temp_dump"
        cd "$original_dir"
        return 1
    }

    if ! ddev describe &>/dev/null; then
        task "Starting target DDEV..."
        ddev start || {
            fail "Could not start target DDEV"
            rm -f "$temp_dump"
            cd "$original_dir"
            return 1
        }
    fi

    # Drop and import
    task "Dropping target database..."
    ddev drush sql:drop -y &>/dev/null

    task "Importing to $target_site..."
    if ddev drush sql:cli < "$temp_dump" 2>/dev/null; then
        pass "Database cloned from development"
    else
        fail "Database import failed"
        rm -f "$temp_dump"
        cd "$original_dir"
        return 1
    fi

    rm -f "$temp_dump"
    cd "$original_dir"
    return 0
}

# Download from URL
download_db_url() {
    local url="$1"
    local target_site="$2"
    local script_dir="${PROJECT_ROOT:-$(dirname "${BASH_SOURCE[0]}")/..}"

    info "Downloading database from URL..."
    task "URL: $url"

    # Create temp file
    local temp_file=$(mktemp --suffix=.sql.gz)

    # Download
    if command -v curl &>/dev/null; then
        if ! curl -sL -o "$temp_file" "$url"; then
            fail "Download failed"
            rm -f "$temp_file"
            return 1
        fi
    elif command -v wget &>/dev/null; then
        if ! wget -q -O "$temp_file" "$url"; then
            fail "Download failed"
            rm -f "$temp_file"
            return 1
        fi
    else
        fail "Neither curl nor wget available"
        rm -f "$temp_file"
        return 1
    fi

    pass "Download complete"

    # Import
    download_db_backup "$temp_file" "$target_site"
    local result=$?

    rm -f "$temp_file"
    return $result
}

################################################################################
# Database Sanitization
################################################################################

# Sanitize database on staging site
# Usage: sanitize_staging_db "target_site"
sanitize_staging_db() {
    local target_site="$1"
    local script_dir="${PROJECT_ROOT:-$(dirname "${BASH_SOURCE[0]}")/..}"

    info "Sanitizing database..."

    local original_dir=$(pwd)
    cd "$script_dir/sites/$target_site" || {
        fail "Cannot access target site: $target_site"
        return 1
    }

    # Run sanitization queries
    task "Truncating cache tables..."
    ddev drush sql:query "TRUNCATE TABLE cache_bootstrap" 2>/dev/null
    ddev drush sql:query "TRUNCATE TABLE cache_config" 2>/dev/null
    ddev drush sql:query "TRUNCATE TABLE cache_container" 2>/dev/null
    ddev drush sql:query "TRUNCATE TABLE cache_data" 2>/dev/null
    ddev drush sql:query "TRUNCATE TABLE cache_default" 2>/dev/null
    ddev drush sql:query "TRUNCATE TABLE cache_discovery" 2>/dev/null
    ddev drush sql:query "TRUNCATE TABLE cache_dynamic_page_cache" 2>/dev/null
    ddev drush sql:query "TRUNCATE TABLE cache_entity" 2>/dev/null
    ddev drush sql:query "TRUNCATE TABLE cache_menu" 2>/dev/null
    ddev drush sql:query "TRUNCATE TABLE cache_page" 2>/dev/null
    ddev drush sql:query "TRUNCATE TABLE cache_render" 2>/dev/null

    task "Truncating session and log tables..."
    ddev drush sql:query "TRUNCATE TABLE sessions" 2>/dev/null
    ddev drush sql:query "TRUNCATE TABLE watchdog" 2>/dev/null
    ddev drush sql:query "TRUNCATE TABLE flood" 2>/dev/null

    task "Anonymizing user data..."
    ddev drush sql:query "UPDATE users_field_data SET mail = CONCAT('user', uid, '@example.com'), name = CONCAT('user', uid) WHERE uid > 1" 2>/dev/null

    task "Resetting admin password..."
    ddev drush upwd admin admin 2>/dev/null

    task "Clearing sensitive config..."
    ddev drush cdel system.mail --quiet 2>/dev/null
    ddev drush cdel smtp.settings --quiet 2>/dev/null

    task "Rebuilding cache..."
    ddev drush cr 2>/dev/null

    pass "Database sanitized"

    cd "$original_dir"
    return 0
}

# Create sanitized backup
# Usage: create_sanitized_backup "sitename"
create_sanitized_backup() {
    local sitename="$1"
    local script_dir="${PROJECT_ROOT:-$(dirname "${BASH_SOURCE[0]}")/..}"
    local backup_dir="$script_dir/sitebackups/$sitename/sanitized"

    mkdir -p "$backup_dir"

    local timestamp=$(date +%Y%m%dT%H%M%S)
    local branch=$(cd "$script_dir/sites/$sitename" && git branch --show-current 2>/dev/null || echo "main")
    local commit=$(cd "$script_dir/sites/$sitename" && git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    local backup_file="$backup_dir/${timestamp}-${branch}-${commit}.sql.gz"

    info "Creating sanitized backup..."

    local original_dir=$(pwd)
    cd "$script_dir/sites/$sitename" || {
        fail "Cannot access site: $sitename"
        return 1
    }

    task "Exporting database..."
    if ddev drush sql:dump --gzip > "$backup_file" 2>/dev/null; then
        pass "Sanitized backup created"
        note "File: $backup_file"
        echo "$backup_file"
        cd "$original_dir"
        return 0
    else
        fail "Could not create backup"
        cd "$original_dir"
        return 1
    fi
}

################################################################################
# Utility Functions
################################################################################

# List available backups for a site
# Usage: list_backups "sitename" [limit]
list_backups() {
    local sitename="$1"
    local limit="${2:-10}"
    local script_dir="${PROJECT_ROOT:-$(dirname "${BASH_SOURCE[0]}")/..}"
    local backup_dir="$script_dir/sitebackups/$sitename"

    if [ ! -d "$backup_dir" ]; then
        echo "No backups found for $sitename"
        return 1
    fi

    info "Available backups for $sitename:"
    find "$backup_dir" -name "*.sql*" -type f 2>/dev/null | \
        xargs -r ls -lt 2>/dev/null | \
        head -"$limit" | \
        while read -r line; do
            local file=$(echo "$line" | awk '{print $NF}')
            local size=$(echo "$line" | awk '{print $5}')
            local date=$(echo "$line" | awk '{print $6, $7, $8}')
            echo "  $(basename "$file") - $date - $(numfmt --to=iec $size 2>/dev/null || echo "${size}B")"
        done
}

# Get recommended database source based on state
# Usage: get_recommended_db_source "sitename"
# Returns: recommended source type
get_recommended_db_source() {
    local sitename="$1"

    # Check for recent sanitized backup first
    if find_sanitized_backup "$sitename" 24 &>/dev/null; then
        echo "sanitized_backup"
        return 0
    fi

    # Check for recent regular backup
    if find_recent_backup "$sitename" 24 &>/dev/null; then
        echo "recent_backup"
        return 0
    fi

    # Check production accessibility
    if has_live_config "$sitename" && check_prod_ssh "$sitename" 2>/dev/null; then
        echo "production"
        return 0
    fi

    # Default to development
    echo "development"
}
