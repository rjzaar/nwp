#!/bin/bash
################################################################################
# NWP Todo Auto-Resolution Library
#
# Automatically resolves todo items when conditions are met
# Hooks into other NWP commands via the pl wrapper
# See docs/proposals/F12-todo-command.md for specification
################################################################################

# Get the directory where this script is located
TODO_AUTOLOG_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
TODO_AUTOLOG_PROJECT_ROOT="${TODO_AUTOLOG_PROJECT_ROOT:-$( cd "$TODO_AUTOLOG_DIR/.." && pwd )}"

################################################################################
# Configuration
################################################################################

# Get auto-resolve setting
# Args: $1=category_name $2=default
get_autoresolve_setting() {
    local category="$1"
    local default="${2:-true}"
    local config_file="${TODO_CONFIG_FILE:-$TODO_AUTOLOG_PROJECT_ROOT/nwp.yml}"

    if [ ! -f "$config_file" ]; then
        config_file="$TODO_AUTOLOG_PROJECT_ROOT/example.nwp.yml"
    fi

    local value=""
    if command -v yq &>/dev/null; then
        # Check master switch first
        local master=$(yq eval '.settings.todo.auto_resolve.enabled // "true"' "$config_file" 2>/dev/null | grep -v '^null$')
        [ "$master" != "true" ] && { echo "false"; return; }

        # Check specific category
        value=$(yq eval ".settings.todo.auto_resolve.${category} // \"$default\"" "$config_file" 2>/dev/null | grep -v '^null$')
    fi

    [ -z "$value" ] && value="$default"
    echo "$value"
}

# Check if auto-resolve is enabled for a category
is_autoresolve_enabled() {
    local category="$1"
    local enabled=$(get_autoresolve_setting "$category" "true")
    [ "$enabled" = "true" ] || [ "$enabled" = "yes" ] || [ "$enabled" = "1" ]
}

################################################################################
# Ignored Items Management (for auto-resolve)
################################################################################

# Add item to resolved list (same as ignored, but with auto-resolved reason)
todo_autoresolve_item() {
    local item_id="$1"
    local reason="${2:-Auto-resolved}"
    local config_file="${TODO_CONFIG_FILE:-$TODO_AUTOLOG_PROJECT_ROOT/nwp.yml}"

    if ! command -v yq &>/dev/null; then
        return 1
    fi

    [ ! -f "$config_file" ] && return 1

    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Create the ignored entry
    local entry="{\"id\": \"$item_id\", \"reason\": \"$reason\", \"ignored_at\": \"$timestamp\", \"ignored_by\": \"auto\"}"

    # Add to ignored array
    yq eval -i ".settings.todo.ignored += [$entry]" "$config_file" 2>/dev/null

    return $?
}

# Remove matching items from ignored (when re-opening)
todo_autoresolve_remove() {
    local pattern="$1"
    local config_file="${TODO_CONFIG_FILE:-$TODO_AUTOLOG_PROJECT_ROOT/nwp.yml}"

    if ! command -v yq &>/dev/null; then
        return 1
    fi

    [ ! -f "$config_file" ] && return 1

    # Remove items matching pattern
    yq eval -i "del(.settings.todo.ignored[] | select(.id | test(\"$pattern\")))" "$config_file" 2>/dev/null

    return $?
}

################################################################################
# Resolve Functions for Specific Categories
################################################################################

# Resolve items for a specific site by categories
# Args: $1=site_name $2+=categories (TST, ORP, BAK, etc.)
todo_resolve_for_site() {
    local site="$1"
    shift
    local categories=("$@")

    for category in "${categories[@]}"; do
        local category_setting=""
        case "$category" in
            TST) category_setting="test_instances" ;;
            ORP) category_setting="orphaned_sites" ;;
            BAK) category_setting="missing_backups" ;;
            SCH) category_setting="missing_schedules" ;;
            INC) category_setting="incomplete_installs" ;;
            GWK) category_setting="uncommitted_work" ;;
            *)   category_setting="" ;;
        esac

        [ -z "$category_setting" ] && continue
        is_autoresolve_enabled "$category_setting" || continue

        # Pattern to match: CATEGORY-*-sitename or CATEGORY-sitename
        local site_clean=$(echo "$site" | tr '[:upper:]' '[:lower:]' | tr -d '-_')
        todo_autoresolve_item "${category}-${site}" "Auto-resolved: site operation completed"
    done
}

# Resolve all items of a category
# Args: $1=category (SEC, DSK, etc.)
todo_resolve_category() {
    local category="$1"

    local category_setting=""
    case "$category" in
        SEC) category_setting="security_updates" ;;
        DSK) category_setting="disk_usage" ;;
        SSL) category_setting="ssl_expiring" ;;
        VER) category_setting="verification_fails" ;;
        GHO) category_setting="ghost_sites" ;;
        *)   category_setting="" ;;
    esac

    [ -z "$category_setting" ] && return 0
    is_autoresolve_enabled "$category_setting" || return 0

    # Clear cache so next check re-evaluates
    rm -f "/tmp/nwp-todo-cache/${category,,}"*.cache 2>/dev/null || true
}

# Refresh verification status (clear cache, don't auto-resolve)
todo_refresh_verification() {
    rm -f "/tmp/nwp-todo-cache/verification"*.cache 2>/dev/null || true
}

################################################################################
# Main Hook Function
################################################################################

# Called by pl wrapper after command execution
# Args: $1=command $2=args $3=exit_code
todo_check_auto_resolve() {
    local command="$1"
    local args="$2"
    local exit_code="$3"

    # Only process successful commands
    [ "$exit_code" != "0" ] && return 0

    # Check if auto-resolve is globally enabled
    local master_enabled=$(get_autoresolve_setting "enabled" "true")
    [ "$master_enabled" != "true" ] && return 0

    case "$command" in
        delete)
            # Auto-resolve TST-* and ORP-* for deleted site
            local site=$(echo "$args" | awk '{print $1}')
            [ -n "$site" ] && todo_resolve_for_site "$site" "TST" "ORP"
            ;;

        backup)
            # Auto-resolve BAK-* for backed up site
            local site=$(echo "$args" | awk '{print $1}')
            [ -n "$site" ] && todo_resolve_for_site "$site" "BAK"
            ;;

        schedule)
            # Auto-resolve SCH-* when schedule is installed
            if echo "$args" | grep -q "install"; then
                local site=$(echo "$args" | awk '{print $NF}')
                [ -n "$site" ] && todo_resolve_for_site "$site" "SCH"
            fi
            ;;

        security)
            # Auto-resolve SEC-* after security update
            if echo "$args" | grep -q "update"; then
                todo_resolve_category "SEC"
            fi
            ;;

        install)
            # Auto-resolve INC-* when installation completes
            local site=$(echo "$args" | grep -oE '[a-zA-Z][a-zA-Z0-9_-]+' | tail -1)
            [ -n "$site" ] && todo_resolve_for_site "$site" "INC"
            ;;

        verify)
            # Refresh VER-* status after verify runs
            if echo "$args" | grep -q -- "--run"; then
                todo_refresh_verification
            fi
            ;;

        ddev)
            # Auto-resolve GHO-* when DDEV is cleaned
            if echo "$args" | grep -qE "stop.*--unlist|delete"; then
                todo_resolve_category "GHO"
            fi
            ;;
    esac

    return 0
}

################################################################################
# Integration with pl wrapper
################################################################################

# This function can be called from the pl wrapper script after each command
# Example integration in pl:
#
# # After executing command
# if [ -f "$SCRIPT_DIR/lib/todo-autolog.sh" ]; then
#     source "$SCRIPT_DIR/lib/todo-autolog.sh"
#     todo_check_auto_resolve "$command" "$*" "$?"
# fi

################################################################################
# Token Rotation Auto-Tracking
################################################################################

# Record token rotation automatically
# Called when token is used/refreshed
todo_record_token_use() {
    local token_name="$1"
    local config_file="${TODO_CONFIG_FILE:-$TODO_AUTOLOG_PROJECT_ROOT/nwp.yml}"

    if ! command -v yq &>/dev/null; then
        return 1
    fi

    [ ! -f "$config_file" ] && return 1

    # Only update if more than 1 day since last recorded rotation
    # This prevents constant updates but ensures recent activity is tracked
    local last_rotated
    last_rotated=$(yq eval ".settings.todo.tokens.${token_name}.last_rotated // \"\"" "$config_file" 2>/dev/null | grep -v '^null$')

    if [ -n "$last_rotated" ]; then
        local last_epoch=$(date -d "$last_rotated" +%s 2>/dev/null || echo "0")
        local now_epoch=$(date +%s)
        local diff=$((now_epoch - last_epoch))

        # Skip if less than 24 hours since last update
        [ "$diff" -lt 86400 ] && return 0
    fi

    # Note: We don't auto-update token rotation dates
    # Token rotation should be explicitly recorded via `pl todo token <name>`
    # This function exists for potential future use
    return 0
}

################################################################################
# Export Functions
################################################################################

export -f get_autoresolve_setting
export -f is_autoresolve_enabled
export -f todo_autoresolve_item
export -f todo_autoresolve_remove
export -f todo_resolve_for_site
export -f todo_resolve_category
export -f todo_refresh_verification
export -f todo_check_auto_resolve
export -f todo_record_token_use
