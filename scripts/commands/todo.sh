#!/bin/bash
set -uo pipefail

################################################################################
# NWP Todo Command
#
# Unified todo command that aggregates maintenance tasks from multiple sources
# Usage: pl todo [command] [options]
#
# See docs/proposals/F12-todo-command.md for full specification
################################################################################

# Get script directory and project root
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

# Source shared libraries
source "$PROJECT_ROOT/lib/ui.sh"
if [ -f "$PROJECT_ROOT/lib/common.sh" ]; then
    source "$PROJECT_ROOT/lib/common.sh"
fi
if [ -f "$PROJECT_ROOT/lib/yaml-write.sh" ]; then
    source "$PROJECT_ROOT/lib/yaml-write.sh"
fi
source "$PROJECT_ROOT/lib/todo-checks.sh"

# TUI library (optional - for interactive mode)
if [ -f "$PROJECT_ROOT/lib/todo-tui.sh" ]; then
    source "$PROJECT_ROOT/lib/todo-tui.sh"
    HAS_TUI=true
else
    HAS_TUI=false
fi

# Notification library (optional)
if [ -f "$PROJECT_ROOT/lib/todo-notify.sh" ]; then
    source "$PROJECT_ROOT/lib/todo-notify.sh"
fi

# Configuration
if [ -f "${PROJECT_ROOT}/cnwp.yml" ]; then
    CONFIG_FILE="${PROJECT_ROOT}/cnwp.yml"
elif [ -f "${PROJECT_ROOT}/example.cnwp.yml" ]; then
    CONFIG_FILE="${PROJECT_ROOT}/example.cnwp.yml"
else
    CONFIG_FILE="${PROJECT_ROOT}/cnwp.yml"
fi
export TODO_CONFIG_FILE="$CONFIG_FILE"
export TODO_CHECKS_PROJECT_ROOT="$PROJECT_ROOT"

################################################################################
# Help
################################################################################

show_help() {
    cat << EOF
${BOLD}NWP Todo Command${NC}

Unified view of all maintenance tasks across your NWP environment.

${BOLD}USAGE:${NC}
    pl todo [command] [options]

${BOLD}COMMANDS:${NC}
    (none)              Interactive TUI mode (default if available)
    list                Text-based list view
    check               Run all checks and show results
    resolve <id>        Mark a todo as resolved
    ignore <id>         Ignore a todo (with optional reason)
    unignore <id>       Stop ignoring a todo
    refresh             Force refresh all checks (clear cache)
    schedule install    Install cron schedule for todo checks
    schedule remove     Remove cron schedule
    token <name>        Record token rotation (updates last_rotated)

${BOLD}OPTIONS:${NC}
    -a, --all           Show all details
    -c, --category=CAT  Filter by category (git,test,token,orphan,ghost,etc.)
    -p, --priority=PRI  Filter by priority (high,medium,low)
    -s, --site=SITE     Filter by site name
    -q, --quiet         Only show counts (summary mode)
    -j, --json          Output as JSON
    --no-cache          Skip cache, run fresh checks
    --show-ignored      Include ignored items in output
    -h, --help          Show this help

${BOLD}CATEGORIES:${NC}
    GIT     GitLab issues assigned to you
    TST     Test instances older than threshold
    TOK     API tokens needing rotation
    ORP     Orphaned sites (have .ddev but not in config)
    GHO     Ghost DDEV sites (registered but directory missing)
    INC     Incomplete installations
    BAK     Sites missing recent backups
    SCH     Sites without scheduled backups
    SEC     Security updates available
    VER     Verification test failures
    GWK     Uncommitted git work
    DSK     Disk usage warnings
    SSL     SSL certificates expiring soon

${BOLD}PRIORITY LEVELS:${NC}
    high    Action required within 24 hours
    medium  Action required within 7 days
    low     Informational / when convenient

${BOLD}EXAMPLES:${NC}
    pl todo                          Interactive TUI mode
    pl todo list                     Show all todos as text
    pl todo list --priority=high     Show only high priority items
    pl todo list --category=sec      Show only security updates
    pl todo check --json             Run checks, output JSON
    pl todo resolve SEC-001          Mark security item resolved
    pl todo ignore ORP-001           Ignore orphaned site
    pl todo token linode             Record Linode token rotation
    pl todo refresh                  Clear cache and re-check
    pl todo schedule install         Set up daily todo checks

${BOLD}CONFIGURATION:${NC}
    Configure thresholds and settings in cnwp.yml under settings.todo:

    settings:
      todo:
        enabled: true
        thresholds:
          test_instance_warn_days: 7
          token_rotation_days: 90
          backup_warn_days: 7
        categories:
          security_updates: true
          test_instances: true
          ...

EOF
}

################################################################################
# Todo Parsing and Filtering
################################################################################

# Parse JSON items into arrays for easier processing
# Sets: TODO_IDS, TODO_PRIORITIES, TODO_TITLES, TODO_DESCRIPTIONS, TODO_SITES, TODO_ACTIONS, TODO_CATEGORIES
parse_todo_items() {
    local json_data="$1"

    TODO_IDS=()
    TODO_PRIORITIES=()
    TODO_TITLES=()
    TODO_DESCRIPTIONS=()
    TODO_SITES=()
    TODO_ACTIONS=()
    TODO_CATEGORIES=()

    # Simple JSON parsing without jq
    while IFS= read -r line; do
        [[ "$line" == "["* ]] || [[ "$line" == "]"* ]] || [[ -z "$line" ]] && continue

        local id=$(echo "$line" | grep -o '"id":"[^"]*"' | cut -d'"' -f4)
        local priority=$(echo "$line" | grep -o '"priority":"[^"]*"' | cut -d'"' -f4)
        local title=$(echo "$line" | grep -o '"title":"[^"]*"' | cut -d'"' -f4)
        local description=$(echo "$line" | grep -o '"description":"[^"]*"' | cut -d'"' -f4)
        local site=$(echo "$line" | grep -o '"site":"[^"]*"' | cut -d'"' -f4)
        local action=$(echo "$line" | grep -o '"action":"[^"]*"' | cut -d'"' -f4)
        local category=$(echo "$line" | grep -o '"category":"[^"]*"' | cut -d'"' -f4)

        [ -z "$id" ] && continue

        TODO_IDS+=("$id")
        TODO_PRIORITIES+=("$priority")
        TODO_TITLES+=("$title")
        TODO_DESCRIPTIONS+=("$description")
        TODO_SITES+=("$site")
        TODO_ACTIONS+=("$action")
        TODO_CATEGORIES+=("$category")
    done <<< "$json_data"
}

# Filter items based on options
# Args: uses global filter variables
filter_items() {
    local -a filtered_indices=()

    for i in "${!TODO_IDS[@]}"; do
        local include=true

        # Filter by priority
        if [ -n "$FILTER_PRIORITY" ] && [ "${TODO_PRIORITIES[$i]}" != "$FILTER_PRIORITY" ]; then
            include=false
        fi

        # Filter by category
        if [ -n "$FILTER_CATEGORY" ]; then
            local cat_upper=$(echo "$FILTER_CATEGORY" | tr '[:lower:]' '[:upper:]')
            [[ "${TODO_CATEGORIES[$i]}" != "$cat_upper"* ]] && include=false
        fi

        # Filter by site
        if [ -n "$FILTER_SITE" ] && [ "${TODO_SITES[$i]}" != "$FILTER_SITE" ]; then
            include=false
        fi

        # Check if ignored (unless showing ignored)
        if [ "$SHOW_IGNORED" != "true" ] && is_ignored "${TODO_IDS[$i]}"; then
            include=false
        fi

        [ "$include" = true ] && filtered_indices+=("$i")
    done

    # Rebuild arrays with filtered items
    local -a new_ids=() new_priorities=() new_titles=() new_descriptions=() new_sites=() new_actions=() new_categories=()
    for i in "${filtered_indices[@]}"; do
        new_ids+=("${TODO_IDS[$i]}")
        new_priorities+=("${TODO_PRIORITIES[$i]}")
        new_titles+=("${TODO_TITLES[$i]}")
        new_descriptions+=("${TODO_DESCRIPTIONS[$i]}")
        new_sites+=("${TODO_SITES[$i]}")
        new_actions+=("${TODO_ACTIONS[$i]}")
        new_categories+=("${TODO_CATEGORIES[$i]}")
    done

    TODO_IDS=("${new_ids[@]}")
    TODO_PRIORITIES=("${new_priorities[@]}")
    TODO_TITLES=("${new_titles[@]}")
    TODO_DESCRIPTIONS=("${new_descriptions[@]}")
    TODO_SITES=("${new_sites[@]}")
    TODO_ACTIONS=("${new_actions[@]}")
    TODO_CATEGORIES=("${new_categories[@]}")
}

################################################################################
# Ignored Items Management
################################################################################

# Check if an item is ignored
is_ignored() {
    local item_id="$1"

    if command -v yq &>/dev/null && [ -f "$CONFIG_FILE" ]; then
        local ignored
        ignored=$(yq eval ".settings.todo.ignored[] | select(.id == \"$item_id\")" "$CONFIG_FILE" 2>/dev/null)
        [ -n "$ignored" ] && return 0
    fi

    return 1
}

# Check if item is in ignored list
is_item_ignored() {
    local item_id="$1"
    local config_file="${CONFIG_FILE:-$PROJECT_ROOT/cnwp.yml}"

    [ ! -f "$config_file" ] && return 1

    if command -v yq &>/dev/null; then
        local found=$(yq eval ".settings.todo.ignored[] | select(.id == \"$item_id\") | .id" "$config_file" 2>/dev/null)
        [ -n "$found" ] && return 0
    fi
    return 1
}

# Add item to ignored/processed list
add_to_ignored() {
    local item_id="$1"
    local reason="${2:-Manual ignore}"
    local expires="${3:-}"

    if ! command -v yq &>/dev/null; then
        print_error "yq is required for this functionality"
        return 1
    fi

    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local user=$(whoami)

    # Create the ignored entry
    local entry="{\"id\": \"$item_id\", \"reason\": \"$reason\", \"ignored_at\": \"$timestamp\", \"ignored_by\": \"$user\""
    [ -n "$expires" ] && entry="$entry, \"expires\": \"$expires\""
    entry="$entry}"

    # Add to ignored array
    yq eval -i ".settings.todo.ignored += [$entry]" "$CONFIG_FILE" 2>/dev/null

    # Show appropriate message based on reason
    if [ "$reason" = "Processed" ]; then
        print_status "OK" "Item '$item_id' marked as processed"
    else
        print_status "OK" "Item '$item_id' ignored"
    fi
}

# Remove item from ignored list
remove_from_ignored() {
    local item_id="$1"

    if ! command -v yq &>/dev/null; then
        print_error "yq is required for unignore functionality"
        return 1
    fi

    yq eval -i "del(.settings.todo.ignored[] | select(.id == \"$item_id\"))" "$CONFIG_FILE" 2>/dev/null

    print_status "OK" "Item '$item_id' removed from ignored list"
}

################################################################################
# Output Functions
################################################################################

# Display text list view
show_list() {
    local json_data="$1"

    parse_todo_items "$json_data"
    filter_items

    # Count by priority
    local high_count=0 medium_count=0 low_count=0
    for priority in "${TODO_PRIORITIES[@]}"; do
        case "$priority" in
            high) ((high_count++)) ;;
            medium) ((medium_count++)) ;;
            low) ((low_count++)) ;;
        esac
    done

    local total=$((high_count + medium_count + low_count))

    # Quiet mode - just show counts
    if [ "$QUIET_MODE" = true ]; then
        echo "Total: $total (High: $high_count, Medium: $medium_count, Low: $low_count)"
        return 0
    fi

    # Full display
    echo ""
    echo -e "${BOLD}${BLUE}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${BLUE}                      NWP Todo List${NC}"
    echo -e "${BOLD}${BLUE}                    $(date '+%Y-%m-%d %H:%M:%S')${NC}"
    echo -e "${BOLD}${BLUE}════════════════════════════════════════════════════════════════${NC}"

    # Show high priority items
    if [ "$high_count" -gt 0 ]; then
        echo ""
        echo -e "${RED}${BOLD}HIGH PRIORITY ($high_count items)${NC}"
        echo -e "────────────────────────────────────────────────────────────────────"
        for i in "${!TODO_IDS[@]}"; do
            [ "${TODO_PRIORITIES[$i]}" != "high" ] && continue
            echo -e "  ${RED}[${TODO_IDS[$i]}]${NC} ${TODO_TITLES[$i]}"
            [ -n "${TODO_DESCRIPTIONS[$i]}" ] && echo -e "            ${DIM}${TODO_DESCRIPTIONS[$i]}${NC}"
            [ -n "${TODO_ACTIONS[$i]}" ] && echo -e "            ${CYAN}Run: ${TODO_ACTIONS[$i]}${NC}"
            echo ""
        done
    fi

    # Show medium priority items
    if [ "$medium_count" -gt 0 ]; then
        echo -e "${YELLOW}${BOLD}MEDIUM PRIORITY ($medium_count items)${NC}"
        echo -e "────────────────────────────────────────────────────────────────────"
        for i in "${!TODO_IDS[@]}"; do
            [ "${TODO_PRIORITIES[$i]}" != "medium" ] && continue
            echo -e "  ${YELLOW}[${TODO_IDS[$i]}]${NC} ${TODO_TITLES[$i]}"
            [ -n "${TODO_DESCRIPTIONS[$i]}" ] && echo -e "            ${DIM}${TODO_DESCRIPTIONS[$i]}${NC}"
            [ -n "${TODO_ACTIONS[$i]}" ] && echo -e "            ${CYAN}Run: ${TODO_ACTIONS[$i]}${NC}"
            echo ""
        done
    fi

    # Show low priority items
    if [ "$low_count" -gt 0 ]; then
        echo -e "${DIM}${BOLD}LOW PRIORITY ($low_count items)${NC}"
        echo -e "────────────────────────────────────────────────────────────────────"
        for i in "${!TODO_IDS[@]}"; do
            [ "${TODO_PRIORITIES[$i]}" != "low" ] && continue
            echo -e "  ${DIM}[${TODO_IDS[$i]}]${NC} ${TODO_TITLES[$i]}"
            [ -n "${TODO_DESCRIPTIONS[$i]}" ] && echo -e "            ${DIM}${TODO_DESCRIPTIONS[$i]}${NC}"
            [ -n "${TODO_ACTIONS[$i]}" ] && echo -e "            ${CYAN}Run: ${TODO_ACTIONS[$i]}${NC}"
            echo ""
        done
    fi

    # Summary
    echo -e "════════════════════════════════════════════════════════════════════"
    echo -e "Summary: ${BOLD}$total items${NC} total (${RED}$high_count high${NC}, ${YELLOW}$medium_count medium${NC}, $low_count low)"

    # Count ignored items
    local ignored_count=0
    if command -v yq &>/dev/null && [ -f "$CONFIG_FILE" ]; then
        ignored_count=$(yq eval '.settings.todo.ignored | length' "$CONFIG_FILE" 2>/dev/null || echo "0")
    fi
    [ "$ignored_count" -gt 0 ] && echo -e "         ${DIM}$ignored_count item(s) ignored (use --show-ignored to display)${NC}"

    echo ""
    echo -e "Run '${CYAN}pl todo${NC}' for interactive mode or '${CYAN}pl todo resolve <ID>${NC}'"
}

# Output as JSON
show_json() {
    local json_data="$1"
    parse_todo_items "$json_data"
    filter_items

    echo "{"
    echo "  \"timestamp\": \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\","
    echo "  \"summary\": {"

    local high_count=0 medium_count=0 low_count=0
    for priority in "${TODO_PRIORITIES[@]}"; do
        case "$priority" in
            high) ((high_count++)) ;;
            medium) ((medium_count++)) ;;
            low) ((low_count++)) ;;
        esac
    done

    echo "    \"total\": $((high_count + medium_count + low_count)),"
    echo "    \"high\": $high_count,"
    echo "    \"medium\": $medium_count,"
    echo "    \"low\": $low_count"
    echo "  },"
    echo "  \"items\": ["

    local first=true
    for i in "${!TODO_IDS[@]}"; do
        [ "$first" = true ] && first=false || echo ","
        printf '    {"id":"%s","category":"%s","priority":"%s","title":"%s","description":"%s","site":"%s","action":"%s"}' \
            "${TODO_IDS[$i]}" "${TODO_CATEGORIES[$i]}" "${TODO_PRIORITIES[$i]}" \
            "${TODO_TITLES[$i]}" "${TODO_DESCRIPTIONS[$i]}" "${TODO_SITES[$i]}" "${TODO_ACTIONS[$i]}"
    done

    echo ""
    echo "  ]"
    echo "}"
}

################################################################################
# Token Rotation Command
################################################################################

record_token_rotation() {
    local token_name="$1"

    if [ -z "$token_name" ]; then
        print_error "Token name required"
        echo "Usage: pl todo token <name>"
        echo "Valid names: linode, cloudflare, gitlab, b2"
        return 1
    fi

    if ! command -v yq &>/dev/null; then
        print_error "yq is required for token tracking"
        return 1
    fi

    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Update the token's last_rotated timestamp
    yq eval -i ".settings.todo.tokens.${token_name}.last_rotated = \"$timestamp\"" "$CONFIG_FILE" 2>/dev/null

    if [ $? -eq 0 ]; then
        print_status "OK" "Token '$token_name' rotation recorded at $timestamp"
    else
        print_error "Failed to update token rotation"
        return 1
    fi
}

################################################################################
# Schedule Management
################################################################################

install_schedule() {
    local cron_expr=$(get_todo_setting "schedule.cron" "0 8 * * *")
    local log_file=$(get_todo_setting "schedule.log_file" "/var/log/nwp/todo.log")

    # Create log directory if needed
    local log_dir=$(dirname "$log_file")
    if [ ! -d "$log_dir" ]; then
        mkdir -p "$log_dir" 2>/dev/null || {
            log_file="/tmp/nwp-todo.log"
            print_warning "Using fallback log location: $log_file"
        }
    fi

    # Build cron entry
    local cron_entry="$cron_expr $PROJECT_ROOT/pl todo check --quiet >> $log_file 2>&1"

    # Check if already installed
    if crontab -l 2>/dev/null | grep -q "pl todo check"; then
        print_warning "Todo schedule already installed"
        return 0
    fi

    # Add to crontab
    (crontab -l 2>/dev/null; echo "$cron_entry") | crontab -

    if [ $? -eq 0 ]; then
        print_status "OK" "Todo schedule installed: $cron_expr"
        print_info "Log file: $log_file"
    else
        print_error "Failed to install schedule"
        return 1
    fi
}

remove_schedule() {
    if ! crontab -l 2>/dev/null | grep -q "pl todo check"; then
        print_warning "No todo schedule found"
        return 0
    fi

    crontab -l 2>/dev/null | grep -v "pl todo check" | crontab -

    if [ $? -eq 0 ]; then
        print_status "OK" "Todo schedule removed"
    else
        print_error "Failed to remove schedule"
        return 1
    fi
}

################################################################################
# Resolve Command
################################################################################

resolve_item() {
    local item_id="$1"

    if [ -z "$item_id" ]; then
        print_error "Item ID required"
        echo "Usage: pl todo resolve <ID>"
        return 1
    fi

    # For now, resolving an item adds it to the ignored list with "resolved" reason
    # Auto-resolve will automatically remove items when conditions are met
    add_to_ignored "$item_id" "Manually resolved"
}

################################################################################
# Main
################################################################################

main() {
    # Default values
    local command=""
    local command_arg=""
    local reason=""

    FILTER_PRIORITY=""
    FILTER_CATEGORY=""
    FILTER_SITE=""
    QUIET_MODE=false
    JSON_MODE=false
    SHOW_ALL=false
    SHOW_IGNORED=false
    NO_CACHE=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            list|check|refresh)
                command="$1"
                shift
                ;;
            resolve|ignore|unignore|token)
                command="$1"
                shift
                [ $# -gt 0 ] && [ "${1:0:1}" != "-" ] && { command_arg="$1"; shift; }
                ;;
            schedule)
                command="schedule"
                shift
                [ $# -gt 0 ] && [ "${1:0:1}" != "-" ] && { command_arg="$1"; shift; }
                ;;
            -p|--priority)
                FILTER_PRIORITY="$2"
                shift 2
                ;;
            --priority=*)
                FILTER_PRIORITY="${1#*=}"
                shift
                ;;
            -c|--category)
                FILTER_CATEGORY="$2"
                shift 2
                ;;
            --category=*)
                FILTER_CATEGORY="${1#*=}"
                shift
                ;;
            -s|--site)
                FILTER_SITE="$2"
                shift 2
                ;;
            --site=*)
                FILTER_SITE="${1#*=}"
                shift
                ;;
            --reason)
                reason="$2"
                shift 2
                ;;
            --reason=*)
                reason="${1#*=}"
                shift
                ;;
            -q|--quiet)
                QUIET_MODE=true
                shift
                ;;
            -j|--json)
                JSON_MODE=true
                shift
                ;;
            -a|--all)
                SHOW_ALL=true
                shift
                ;;
            --show-ignored)
                SHOW_IGNORED=true
                shift
                ;;
            --no-cache)
                NO_CACHE=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            -*)
                print_error "Unknown option: $1"
                show_help
                exit 1
                ;;
            *)
                # Positional argument - might be command or command arg
                if [ -z "$command" ]; then
                    command="$1"
                elif [ -z "$command_arg" ]; then
                    command_arg="$1"
                fi
                shift
                ;;
        esac
    done

    # Check if todo is enabled
    local enabled=$(get_todo_setting "enabled" "true")
    if [ "$enabled" != "true" ] && [ "$enabled" != "yes" ] && [ "$enabled" != "1" ]; then
        print_warning "Todo system is disabled in configuration"
        print_info "Enable it with: settings.todo.enabled: true in cnwp.yml"
        exit 0
    fi

    # Execute command
    case "${command:-}" in
        list)
            local results
            results=$(run_all_checks "$NO_CACHE")
            if [ "$JSON_MODE" = true ]; then
                show_json "$results"
            else
                show_list "$results"
            fi
            ;;
        check)
            local results
            results=$(run_all_checks "$NO_CACHE")
            if [ "$JSON_MODE" = true ]; then
                show_json "$results"
            elif [ "$QUIET_MODE" = true ]; then
                parse_todo_items "$results"
                filter_items
                local high_count=0 medium_count=0 low_count=0
                for priority in "${TODO_PRIORITIES[@]}"; do
                    case "$priority" in
                        high) ((high_count++)) ;;
                        medium) ((medium_count++)) ;;
                        low) ((low_count++)) ;;
                    esac
                done
                echo "[$(date -Iseconds)] Total: $((high_count + medium_count + low_count)) (High: $high_count, Medium: $medium_count, Low: $low_count)"
            else
                show_list "$results"
            fi
            ;;
        resolve)
            resolve_item "$command_arg"
            ;;
        ignore)
            [ -z "$command_arg" ] && { print_error "Item ID required"; exit 1; }
            add_to_ignored "$command_arg" "${reason:-Manual ignore}"
            ;;
        unignore)
            [ -z "$command_arg" ] && { print_error "Item ID required"; exit 1; }
            remove_from_ignored "$command_arg"
            ;;
        refresh)
            todo_cache_clear
            print_status "OK" "Cache cleared"
            local results
            results=$(run_all_checks "true")
            if [ "$JSON_MODE" = true ]; then
                show_json "$results"
            else
                show_list "$results"
            fi
            ;;
        token)
            record_token_rotation "$command_arg"
            ;;
        schedule)
            case "$command_arg" in
                install)
                    install_schedule
                    ;;
                remove)
                    remove_schedule
                    ;;
                *)
                    print_error "Unknown schedule command: $command_arg"
                    echo "Usage: pl todo schedule install|remove"
                    exit 1
                    ;;
            esac
            ;;
        "")
            # Default: TUI mode if available, otherwise list
            if [ "$HAS_TUI" = true ] && [ -t 1 ]; then
                todo_tui_main
            else
                local results
                results=$(run_all_checks "$NO_CACHE")
                show_list "$results"
            fi
            ;;
        *)
            print_error "Unknown command: $command"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
