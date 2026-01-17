#!/bin/bash
################################################################################
# NWP Todo Checks Library
#
# Individual check functions for the unified todo system
# See docs/proposals/F12-todo-command.md for full specification
################################################################################

# Get the directory where this script is located
TODO_CHECKS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
TODO_CHECKS_PROJECT_ROOT="${TODO_CHECKS_PROJECT_ROOT:-$( cd "$TODO_CHECKS_DIR/.." && pwd )}"

# Cache settings
TODO_CACHE_DIR="${TODO_CACHE_DIR:-/tmp/nwp-todo-cache}"
TODO_CACHE_TTL="${TODO_CACHE_TTL:-300}"  # 5 minutes default

# Todo item storage (arrays for building results)
TODO_ITEMS=()
TODO_ITEM_ID=0

################################################################################
# Cache Management
################################################################################

# Check if cache file is valid (exists and not expired)
# Args: $1 = cache_file
# Returns: 0 if valid, 1 if expired or missing
todo_cache_valid() {
    local cache_file="$1"
    local ttl="${2:-$TODO_CACHE_TTL}"

    [ ! -f "$cache_file" ] && return 1

    local file_age
    if [[ "$(uname)" == "Darwin" ]]; then
        file_age=$(($(date +%s) - $(stat -f%m "$cache_file" 2>/dev/null)))
    else
        file_age=$(($(date +%s) - $(stat -c%Y "$cache_file" 2>/dev/null)))
    fi

    [ "$file_age" -lt "$ttl" ] && return 0
    return 1
}

# Ensure cache directory exists
todo_cache_init() {
    mkdir -p "$TODO_CACHE_DIR"
}

# Clear all cache files
todo_cache_clear() {
    rm -rf "$TODO_CACHE_DIR"
    todo_cache_init
}

################################################################################
# Todo Item Builder Functions
################################################################################

# Add a todo item to the results
# Args: $1=category $2=id $3=priority $4=title $5=description $6=site $7=action
todo_add_item() {
    local category="$1"
    local id="$2"
    local priority="$3"
    local title="$4"
    local description="$5"
    local site="${6:-}"
    local action="${7:-}"

    ((TODO_ITEM_ID++))
    local full_id="${category}-$(printf '%03d' $TODO_ITEM_ID)"
    [ -n "$id" ] && full_id="${category}-${id}"

    # Store as JSON-like format for easy parsing
    local item="{\"id\":\"$full_id\",\"category\":\"$category\",\"priority\":\"$priority\",\"title\":\"$title\",\"description\":\"$description\",\"site\":\"$site\",\"action\":\"$action\"}"
    TODO_ITEMS+=("$item")
}

# Output all collected items as JSON array
todo_output_items() {
    echo "["
    local first=true
    for item in "${TODO_ITEMS[@]}"; do
        if [ "$first" = true ]; then
            first=false
        else
            echo ","
        fi
        echo "  $item"
    done
    echo "]"
}

# Clear items array (for fresh check)
todo_clear_items() {
    TODO_ITEMS=()
    TODO_ITEM_ID=0
}

################################################################################
# Configuration Reading Helpers
################################################################################

# Get todo setting with default
# Args: $1=key_path $2=default
get_todo_setting() {
    local key_path="$1"
    local default="${2:-}"
    local config_file="${TODO_CONFIG_FILE:-$TODO_CHECKS_PROJECT_ROOT/cnwp.yml}"

    if [ ! -f "$config_file" ]; then
        config_file="$TODO_CHECKS_PROJECT_ROOT/example.cnwp.yml"
    fi

    local value=""
    if command -v yq &>/dev/null; then
        value=$(yq eval ".settings.todo.${key_path} // \"\"" "$config_file" 2>/dev/null | grep -v '^null$')
    else
        # Simple AWK fallback for basic paths
        value=$(awk -v path="$key_path" '
            BEGIN { FS=": "; in_todo=0; depth=0 }
            /^  todo:/ { in_todo=1; depth=2; next }
            in_todo && /^[a-zA-Z]/ && !/^  / { exit }
            in_todo {
                # Count leading spaces
                match($0, /^[[:space:]]*/)
                spaces = RLENGTH
                if (spaces <= depth && !/^[[:space:]]*#/) { in_todo=0; next }
            }
        ' "$config_file")
    fi

    [ -z "$value" ] && value="$default"
    echo "$value"
}

# Check if a category is enabled
# Args: $1=category_name
is_category_enabled() {
    local category="$1"
    local value=$(get_todo_setting "categories.${category}" "true")
    [ "$value" = "true" ] || [ "$value" = "yes" ] || [ "$value" = "1" ]
}

################################################################################
# Check Functions
################################################################################

# GIT: Check GitLab issues
check_gitlab_issues() {
    is_category_enabled "git_issues" || return 0

    local secrets_file="$TODO_CHECKS_PROJECT_ROOT/.secrets.yml"

    # Get GitLab token
    local api_token=""
    if [ -f "$secrets_file" ] && command -v yq &>/dev/null; then
        api_token=$(yq eval '.gitlab.api_token // ""' "$secrets_file" 2>/dev/null | grep -v '^null$')
    fi

    if [ -z "$api_token" ]; then
        # No GitLab token configured, skip silently
        return 0
    fi

    # Get GitLab server
    local server=""
    if [ -f "$secrets_file" ] && command -v yq &>/dev/null; then
        server=$(yq eval '.gitlab.server.domain // ""' "$secrets_file" 2>/dev/null | grep -v '^null$')
    fi

    if [ -z "$server" ]; then
        server="git.nwpcode.org"
    fi

    # Get user ID
    local user_info
    user_info=$(curl -sf -H "PRIVATE-TOKEN: $api_token" \
        "https://$server/api/v4/user" 2>/dev/null)

    if [ -z "$user_info" ]; then
        return 0
    fi

    local user_id
    user_id=$(echo "$user_info" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)

    if [ -z "$user_id" ]; then
        return 0
    fi

    # Fetch assigned issues
    local issues
    issues=$(curl -sf -H "PRIVATE-TOKEN: $api_token" \
        "https://$server/api/v4/issues?assignee_id=$user_id&state=opened&per_page=50" 2>/dev/null)

    if [ -z "$issues" ] || [ "$issues" = "[]" ]; then
        return 0
    fi

    # Parse issues and add to items (using process substitution to avoid subshell)
    while read -r iid; do
        [ -z "$iid" ] && continue
        local title=$(echo "$issues" | grep -o "\"iid\":$iid[^}]*\"title\":\"[^\"]*\"" | grep -o '"title":"[^"]*"' | cut -d'"' -f4)
        local web_url=$(echo "$issues" | grep -o "\"iid\":$iid[^}]*\"web_url\":\"[^\"]*\"" | grep -o '"web_url":"[^"]*"' | cut -d'"' -f4)
        todo_add_item "GIT" "$iid" "medium" "GitLab Issue #$iid" "$title" "" "Open: $web_url"
    done < <(echo "$issues" | grep -o '"iid":[0-9]*' | cut -d: -f2)
}

# TST: Check test instances age
check_test_instances() {
    is_category_enabled "test_instances" || return 0

    local config_file="${TODO_CONFIG_FILE:-$TODO_CHECKS_PROJECT_ROOT/cnwp.yml}"
    [ ! -f "$config_file" ] && return 0

    local warn_days=$(get_todo_setting "thresholds.test_instance_warn_days" "7")
    local alert_days=$(get_todo_setting "thresholds.test_instance_alert_days" "14")
    local now_epoch=$(date +%s)

    # Get all sites with purpose=testing
    while read -r site; do
        [ -z "$site" ] && continue

        local purpose=$(yaml_get_site_field "$site" "purpose" "$config_file" 2>/dev/null)
        [ "$purpose" != "testing" ] && continue

        local created=$(yaml_get_site_field "$site" "created" "$config_file" 2>/dev/null)
        [ -z "$created" ] && continue

        # Calculate age in days
        local created_epoch
        created_epoch=$(date -d "$created" +%s 2>/dev/null || echo "0")
        [ "$created_epoch" = "0" ] && continue

        local age_days=$(( (now_epoch - created_epoch) / 86400 ))

        if [ "$age_days" -ge "$alert_days" ]; then
            todo_add_item "TST" "${site}" "high" "Test instance is $age_days days old" "Site: $site | Purpose: testing | Created: ${created%T*}" "$site" "pl delete $site"
        elif [ "$age_days" -ge "$warn_days" ]; then
            todo_add_item "TST" "${site}" "medium" "Test instance is $age_days days old" "Site: $site | Purpose: testing | Created: ${created%T*}" "$site" "pl delete $site"
        fi
    done < <(yaml_get_all_sites "$config_file" 2>/dev/null)
}

# TOK: Check token rotation
check_token_rotation() {
    is_category_enabled "token_rotation" || return 0

    local config_file="${TODO_CONFIG_FILE:-$TODO_CHECKS_PROJECT_ROOT/cnwp.yml}"
    local rotation_days=$(get_todo_setting "thresholds.token_rotation_days" "90")
    local now_epoch=$(date +%s)

    local tokens=("linode" "cloudflare" "gitlab" "b2")

    for token_name in "${tokens[@]}"; do
        local last_rotated=""
        if command -v yq &>/dev/null && [ -f "$config_file" ]; then
            last_rotated=$(yq eval ".settings.todo.tokens.${token_name}.last_rotated // \"\"" "$config_file" 2>/dev/null | grep -v '^null$')
        fi

        if [ -z "$last_rotated" ]; then
            # No rotation date recorded - add as low priority reminder
            todo_add_item "TOK" "$token_name" "low" "Token rotation not tracked: $token_name" "Last rotated: unknown | Threshold: $rotation_days days" "" "pl todo token $token_name"
            continue
        fi

        # Calculate age
        local rotated_epoch
        rotated_epoch=$(date -d "$last_rotated" +%s 2>/dev/null || echo "0")
        [ "$rotated_epoch" = "0" ] && continue

        local age_days=$(( (now_epoch - rotated_epoch) / 86400 ))

        if [ "$age_days" -ge "$rotation_days" ]; then
            todo_add_item "TOK" "$token_name" "medium" "Token rotation due: $token_name ($age_days days old)" "Last rotated: ${last_rotated%T*} | Threshold: $rotation_days days" "" "Rotate token and run: pl todo token $token_name"
        fi
    done
}

# ORP: Check orphaned sites
check_orphaned_sites() {
    is_category_enabled "orphaned_sites" || return 0

    local config_file="${TODO_CONFIG_FILE:-$TODO_CHECKS_PROJECT_ROOT/cnwp.yml}"

    # Reuse find_orphaned_sites from status.sh if available
    if command -v find_orphaned_sites &>/dev/null; then
        while IFS=':' read -r name dir; do
            [ -z "$name" ] && continue
            todo_add_item "ORP" "$name" "low" "Orphaned site (has .ddev, not in config)" "Directory: $dir" "$name" "pl todo ignore ORP-$name OR pl delete $name"
        done < <(find_orphaned_sites "$config_file" "$TODO_CHECKS_PROJECT_ROOT" 2>/dev/null)
    else
        # Fallback: check sites directory manually
        if [ -d "$TODO_CHECKS_PROJECT_ROOT/sites" ]; then
            while IFS= read -r ddev_path; do
                local site_dir=$(dirname "$ddev_path")
                local site_name=$(basename "$site_dir")

                # Check if site is in config
                if ! yaml_site_exists "$site_name" "$config_file" 2>/dev/null; then
                    todo_add_item "ORP" "$site_name" "low" "Orphaned site (has .ddev, not in config)" "Directory: $site_dir" "$site_name" "pl todo ignore ORP-$site_name OR pl delete $site_name"
                fi
            done < <(find "$TODO_CHECKS_PROJECT_ROOT/sites" -maxdepth 2 -name ".ddev" -type d 2>/dev/null)
        fi
    fi
}

# GHO: Check ghost DDEV sites
check_ghost_sites() {
    is_category_enabled "ghost_sites" || return 0

    # Get DDEV list as JSON and parse it
    local ddev_json
    ddev_json=$(ddev list --json-output 2>/dev/null | grep -o '"raw":\[.*\]' | sed 's/"raw"://' 2>/dev/null) || return 0

    [ -z "$ddev_json" ] && return 0

    # Parse JSON to find ghost sites (using process substitution to avoid subshell)
    while read -r entry; do
        [ -z "$entry" ] && continue
        local name=$(echo "$entry" | grep -o '"name":"[^"]*"' | cut -d'"' -f4)
        local approot=$(echo "$entry" | grep -o '"approot":"[^"]*"' | cut -d'"' -f4)
        local status=$(echo "$entry" | grep -o '"status":"[^"]*"' | cut -d'"' -f4)

        # Skip Router
        [ "$name" = "Router" ] && continue

        # Skip if not in nwp folder
        [[ "$approot" != "$TODO_CHECKS_PROJECT_ROOT"* ]] && continue

        # Check if directory is missing
        if [[ "$status" == *"missing"* ]]; then
            todo_add_item "GHO" "$name" "high" "Ghost DDEV site (directory missing)" "Was at: $approot" "$name" "ddev stop --unlist $name"
        fi
    done < <(echo "$ddev_json" | grep -o '{[^}]*}')
}

# INC: Check incomplete installations
check_incomplete_installs() {
    is_category_enabled "incomplete_installs" || return 0

    local config_file="${TODO_CONFIG_FILE:-$TODO_CHECKS_PROJECT_ROOT/cnwp.yml}"
    [ ! -f "$config_file" ] && return 0

    local alert_hours=$(get_todo_setting "thresholds.incomplete_install_hours" "24")
    local now_epoch=$(date +%s)

    while read -r site; do
        [ -z "$site" ] && continue

        local install_step=$(yaml_get_site_field "$site" "install_step" "$config_file" 2>/dev/null)

        # Skip if complete (-1) or not tracked
        [ "$install_step" = "-1" ] || [ -z "$install_step" ] && continue

        local created=$(yaml_get_site_field "$site" "created" "$config_file" 2>/dev/null)
        [ -z "$created" ] && continue

        # Calculate age in hours
        local created_epoch
        created_epoch=$(date -d "$created" +%s 2>/dev/null || echo "0")
        [ "$created_epoch" = "0" ] && continue

        local age_hours=$(( (now_epoch - created_epoch) / 3600 ))

        if [ "$age_hours" -ge "$alert_hours" ]; then
            todo_add_item "INC" "$site" "high" "Incomplete installation (step $install_step, ${age_hours}h old)" "Site: $site | Stalled at step $install_step" "$site" "pl install -s=$((install_step + 1)) $site"
        fi
    done < <(yaml_get_all_sites "$config_file" 2>/dev/null)
}

# BAK: Check missing backups
check_missing_backups() {
    is_category_enabled "missing_backups" || return 0

    local config_file="${TODO_CONFIG_FILE:-$TODO_CHECKS_PROJECT_ROOT/cnwp.yml}"
    [ ! -f "$config_file" ] && return 0

    local warn_days=$(get_todo_setting "thresholds.backup_warn_days" "7")
    local now_epoch=$(date +%s)
    local warn_seconds=$((warn_days * 86400))

    while read -r site; do
        [ -z "$site" ] && continue

        # Skip test sites
        local purpose=$(yaml_get_site_field "$site" "purpose" "$config_file" 2>/dev/null)
        [ "$purpose" = "testing" ] && continue

        local directory=$(yaml_get_site_field "$site" "directory" "$config_file" 2>/dev/null)
        [ -z "$directory" ] && directory="$TODO_CHECKS_PROJECT_ROOT/sites/$site"

        # Check if backup directory exists
        local backup_dir="$directory/backups"
        if [ ! -d "$backup_dir" ]; then
            backup_dir="$TODO_CHECKS_PROJECT_ROOT/backups/$site"
        fi

        if [ ! -d "$backup_dir" ]; then
            todo_add_item "BAK" "$site" "medium" "No backup directory found" "Site: $site | Expected: $backup_dir" "$site" "pl backup $site"
            continue
        fi

        # Find most recent backup file
        local latest_backup
        latest_backup=$(find "$backup_dir" -type f \( -name "*.sql.gz" -o -name "*.tar.gz" \) -printf '%T@\n' 2>/dev/null | sort -n | tail -1)

        if [ -z "$latest_backup" ]; then
            todo_add_item "BAK" "$site" "medium" "No backup files found" "Site: $site | Directory: $backup_dir" "$site" "pl backup $site"
            continue
        fi

        local backup_age=$((now_epoch - ${latest_backup%.*}))

        if [ "$backup_age" -gt "$warn_seconds" ]; then
            local days_ago=$((backup_age / 86400))
            todo_add_item "BAK" "$site" "medium" "Backup is $days_ago days old" "Site: $site | Threshold: $warn_days days" "$site" "pl backup $site"
        fi
    done < <(yaml_get_all_sites "$config_file" 2>/dev/null)
}

# SCH: Check missing backup schedules
check_missing_schedules() {
    is_category_enabled "missing_schedules" || return 0

    local config_file="${TODO_CONFIG_FILE:-$TODO_CHECKS_PROJECT_ROOT/cnwp.yml}"
    [ ! -f "$config_file" ] && return 0

    # Get crontab entries for NWP
    local crontab_entries
    crontab_entries=$(crontab -l 2>/dev/null | grep -E "pl backup|nwp.*backup" || true)

    while read -r site; do
        [ -z "$site" ] && continue

        # Skip test sites
        local purpose=$(yaml_get_site_field "$site" "purpose" "$config_file" 2>/dev/null)
        [ "$purpose" = "testing" ] && continue

        # Check if site has a scheduled backup
        if ! echo "$crontab_entries" | grep -q "$site"; then
            todo_add_item "SCH" "$site" "low" "Site has no scheduled backups" "Site: $site" "$site" "pl schedule install $site"
        fi
    done < <(yaml_get_all_sites "$config_file" 2>/dev/null)
}

# SEC: Check security updates
check_security_updates() {
    is_category_enabled "security_updates" || return 0

    local config_file="${TODO_CONFIG_FILE:-$TODO_CHECKS_PROJECT_ROOT/cnwp.yml}"
    [ ! -f "$config_file" ] && return 0

    while read -r site; do
        [ -z "$site" ] && continue

        local directory=$(yaml_get_site_field "$site" "directory" "$config_file" 2>/dev/null)
        [ -z "$directory" ] && directory="$TODO_CHECKS_PROJECT_ROOT/sites/$site"

        # Check for Drupal webroot
        local webroot=""
        for dir in "web" "html" "docroot" "."; do
            if [ -f "$directory/$dir/core/lib/Drupal.php" ]; then
                webroot="$directory/$dir"
                break
            fi
        done

        [ -z "$webroot" ] && continue

        # Check for security updates using drush (if available)
        if command -v ddev &>/dev/null && [ -d "$directory/.ddev" ]; then
            local updates
            updates=$(cd "$directory" && ddev drush pm:security --format=json 2>/dev/null || echo "[]")

            if [ "$updates" != "[]" ] && [ -n "$updates" ]; then
                # Count security updates
                local count
                count=$(echo "$updates" | grep -c '"name"' 2>/dev/null || echo "0")

                if [ "$count" -gt 0 ]; then
                    todo_add_item "SEC" "$site" "high" "$count security update(s) available" "Site: $site | Run: pl security update $site" "$site" "pl security update $site"
                fi
            fi
        fi
    done < <(yaml_get_all_sites "$config_file" 2>/dev/null)
}

# VER: Check verification failures
check_verification() {
    is_category_enabled "verification_fails" || return 0

    local verification_file="$TODO_CHECKS_PROJECT_ROOT/.verification.yml"
    [ ! -f "$verification_file" ] && return 0

    # Simple check for failed items in verification file
    if command -v yq &>/dev/null; then
        local fail_count
        fail_count=$(yq eval '[.. | select(has("status")) | .status | select(. == "fail")] | length' "$verification_file" 2>/dev/null || echo "0")

        if [ "$fail_count" -gt 0 ]; then
            todo_add_item "VER" "001" "low" "$fail_count verification test(s) failing" "Run: pl verify --run to check" "" "pl verify --run"
        fi
    fi
}

# GWK: Check uncommitted work
check_uncommitted_work() {
    is_category_enabled "uncommitted_work" || return 0

    local config_file="${TODO_CONFIG_FILE:-$TODO_CHECKS_PROJECT_ROOT/cnwp.yml}"
    [ ! -f "$config_file" ] && return 0

    while read -r site; do
        [ -z "$site" ] && continue

        local directory=$(yaml_get_site_field "$site" "directory" "$config_file" 2>/dev/null)
        [ -z "$directory" ] && directory="$TODO_CHECKS_PROJECT_ROOT/sites/$site"
        [ ! -d "$directory/.git" ] && continue

        # Check for uncommitted changes
        local status
        status=$(cd "$directory" && git status --porcelain 2>/dev/null || true)

        if [ -n "$status" ]; then
            local file_count
            file_count=$(echo "$status" | wc -l | tr -d ' ')
            todo_add_item "GWK" "$site" "low" "Uncommitted changes in site ($file_count files)" "Site: $site" "$site" "cd $directory && git status"
        fi
    done < <(yaml_get_all_sites "$config_file" 2>/dev/null)
}

# DSK: Check disk usage
check_disk_usage() {
    is_category_enabled "disk_usage" || return 0

    local warn_percent=$(get_todo_setting "thresholds.disk_warn_percent" "80")
    local alert_percent=$(get_todo_setting "thresholds.disk_alert_percent" "90")

    # Get disk usage for the filesystem containing the project
    local disk_info
    disk_info=$(df -P "$TODO_CHECKS_PROJECT_ROOT" 2>/dev/null | tail -1)

    local usage_percent
    usage_percent=$(echo "$disk_info" | awk '{gsub(/%/,"",$5); print $5}')

    local mount_point
    mount_point=$(echo "$disk_info" | awk '{print $6}')

    if [ "$usage_percent" -ge "$alert_percent" ]; then
        todo_add_item "DSK" "001" "high" "Disk usage critical: ${usage_percent}%" "Mount: $mount_point | Threshold: ${alert_percent}%" "" "df -h $mount_point"
    elif [ "$usage_percent" -ge "$warn_percent" ]; then
        todo_add_item "DSK" "001" "medium" "Disk usage warning: ${usage_percent}%" "Mount: $mount_point | Threshold: ${warn_percent}%" "" "df -h $mount_point"
    fi
}

# SSL: Check SSL certificate expiry
check_ssl_expiry() {
    is_category_enabled "ssl_expiring" || return 0

    local config_file="${TODO_CONFIG_FILE:-$TODO_CHECKS_PROJECT_ROOT/cnwp.yml}"
    local warn_days=$(get_todo_setting "thresholds.ssl_warn_days" "30")
    local alert_days=$(get_todo_setting "thresholds.ssl_alert_days" "7")

    [ ! -f "$config_file" ] && return 0

    while read -r site; do
        [ -z "$site" ] && continue

        # Get live domain if configured
        local domain=""
        if command -v yq &>/dev/null; then
            domain=$(yq eval ".sites.${site}.live.domain // \"\"" "$config_file" 2>/dev/null | grep -v '^null$')
        fi

        [ -z "$domain" ] && continue

        # Check SSL certificate expiry
        local expiry_date
        expiry_date=$(echo | openssl s_client -servername "$domain" -connect "$domain:443" 2>/dev/null | \
            openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)

        [ -z "$expiry_date" ] && continue

        local expiry_epoch
        expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null || echo "0")
        [ "$expiry_epoch" = "0" ] && continue

        local now_epoch=$(date +%s)
        local days_until=$(( (expiry_epoch - now_epoch) / 86400 ))

        if [ "$days_until" -le "$alert_days" ]; then
            todo_add_item "SSL" "$site" "high" "SSL certificate expires in $days_until days" "Domain: $domain" "$site" "certbot renew"
        elif [ "$days_until" -le "$warn_days" ]; then
            todo_add_item "SSL" "$site" "medium" "SSL certificate expires in $days_until days" "Domain: $domain" "$site" "certbot renew"
        fi
    done < <(yaml_get_all_sites "$config_file" 2>/dev/null)
}

################################################################################
# Main Check Runner
################################################################################

# Run all enabled checks and return combined results
run_all_checks() {
    local skip_cache="${1:-false}"

    todo_cache_init
    [ "$skip_cache" = "true" ] && todo_cache_clear

    todo_clear_items

    # Run all checks (they add to TODO_ITEMS)
    check_ghost_sites
    check_incomplete_installs
    check_security_updates
    check_ssl_expiry
    check_test_instances
    check_token_rotation
    check_missing_backups
    check_disk_usage
    check_gitlab_issues
    check_orphaned_sites
    check_missing_schedules
    check_verification
    check_uncommitted_work

    # Output results
    todo_output_items
}

# Export functions
export -f todo_cache_valid
export -f todo_cache_init
export -f todo_cache_clear
export -f todo_add_item
export -f todo_output_items
export -f todo_clear_items
export -f get_todo_setting
export -f is_category_enabled
export -f check_gitlab_issues
export -f check_test_instances
export -f check_token_rotation
export -f check_orphaned_sites
export -f check_ghost_sites
export -f check_incomplete_installs
export -f check_missing_backups
export -f check_missing_schedules
export -f check_security_updates
export -f check_verification
export -f check_uncommitted_work
export -f check_disk_usage
export -f check_ssl_expiry
export -f run_all_checks
