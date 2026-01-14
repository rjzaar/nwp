#!/bin/bash

################################################################################
# NWP Import TUI Library
#
# Terminal UI components for the import system
# Provides server selection, site selection, and options configuration interfaces
#
# Source this file: source "$SCRIPT_DIR/lib/import-tui.sh"
#
# Requires: lib/ui.sh, lib/tui.sh, lib/checkbox.sh
################################################################################

# Prevent double-sourcing
[[ -n "${_IMPORT_TUI_SH_LOADED:-}" ]] && return 0
_IMPORT_TUI_SH_LOADED=1

# Ensure colors are available
# Respect NO_COLOR standard
if [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
    DIM="${DIM:-}"
else
    DIM="${DIM:-$'\033[2m'}"
fi

################################################################################
# Data Structures
################################################################################

# Arrays to hold discovered sites
declare -a DISCOVERED_SITES=()         # JSON lines of discovered sites
declare -a DISCOVERED_SITE_NAMES=()    # Just the names for display
declare -a SELECTED_SITES=()           # Indices of selected sites

# Import options per site (associative arrays)
declare -A IMPORT_OPTIONS=()           # site_name:option_key = value

# Default import options
declare -A IMPORT_DEFAULTS=(
    [sanitize]="y"
    [truncate_cache]="y"
    [truncate_watchdog]="y"
    [truncate_sessions]="y"
    [stage_file_proxy]="y"
    [full_file_sync]="n"
    [exclude_generated]="y"
    [environment_indicator]="y"
    [dev_modules]="n"
    [config_split]="y"
)

################################################################################
# Terminal Control
################################################################################

tui_cursor_to() { printf "\033[%d;%dH" "$1" "$2"; }
tui_cursor_hide() { printf "\033[?25l"; }
tui_cursor_show() { printf "\033[?25h"; }
tui_clear_screen() { printf "\033[2J\033[H"; }
tui_clear_line() { printf "\033[2K"; }

# Read a single keypress
tui_read_key() {
    local key
    IFS= read -rsn1 key
    if [[ $key == $'\x1b' ]]; then
        read -rsn2 -t 0.1 rest || true
        case "$rest" in
            '[A') echo "UP" ;;
            '[B') echo "DOWN" ;;
            '[C') echo "RIGHT" ;;
            '[D') echo "LEFT" ;;
            *) echo "ESC" ;;
        esac
    elif [[ $key == "" ]]; then
        echo "ENTER"
    elif [[ $key == " " ]]; then
        echo "SPACE"
    else
        echo "$key"
    fi
}

################################################################################
# Screen Drawing Functions
################################################################################

# Draw a box border
# Usage: draw_box $row $col $height $width "title"
draw_box() {
    local row=$1 col=$2 height=$3 width=$4 title="${5:-}"

    # Top border
    tui_cursor_to $row $col
    printf "┌"
    printf "─%.0s" $(seq 1 $((width - 2)))
    printf "┐"

    # Title if provided
    if [ -n "$title" ]; then
        tui_cursor_to $row $((col + 2))
        printf " %s " "$title"
    fi

    # Sides
    for ((i = 1; i < height - 1; i++)); do
        tui_cursor_to $((row + i)) $col
        printf "│"
        tui_cursor_to $((row + i)) $((col + width - 1))
        printf "│"
    done

    # Bottom border
    tui_cursor_to $((row + height - 1)) $col
    printf "└"
    printf "─%.0s" $(seq 1 $((width - 2)))
    printf "┘"
}

# Draw header bar
draw_header() {
    local title="$1"
    local subtitle="${2:-}"

    echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  NWP Import - $title${NC}"
    if [ -n "$subtitle" ]; then
        echo -e "  ${DIM}$subtitle${NC}"
    fi
    echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════════════${NC}"
    echo ""
}

# Draw footer with key hints
draw_footer() {
    local hints="$1"
    echo ""
    echo -e "${DIM}$hints${NC}"
}

################################################################################
# Server Selection Screen
################################################################################

# Display server selection menu
# Usage: select_server "config_file"
# Sets: SELECTED_SERVER_NAME, SELECTED_SSH_HOST, SELECTED_SSH_KEY
select_server() {
    local config_file="${1:-cnwp.yml}"
    local servers=()
    local cursor=0

    # Load servers from config
    while IFS='|' read -r name host label; do
        servers+=("$name|$host|$label")
    done < <(list_configured_servers "$config_file")

    # Add custom option
    servers+=("_custom|Enter manually...|Custom SSH connection")

    local total=${#servers[@]}

    if [ $total -eq 1 ]; then
        # Only custom option, go straight to manual entry
        read -p "Enter SSH connection (user@host): " SELECTED_SSH_HOST
        read -p "Enter SSH key path [~/.ssh/nwp]: " SELECTED_SSH_KEY
        SELECTED_SSH_KEY="${SELECTED_SSH_KEY:-$HOME/.ssh/nwp}"
        SELECTED_SSH_KEY="${SELECTED_SSH_KEY/#\~/$HOME}"
        SELECTED_SERVER_NAME="custom"
        return 0
    fi

    tui_cursor_hide
    trap 'tui_cursor_show' EXIT INT TERM

    while true; do
        tui_clear_screen
        draw_header "Server Selection"

        echo "  Select a Linode server to scan for sites:"
        echo ""

        local idx=0
        for server in "${servers[@]}"; do
            IFS='|' read -r name host label <<< "$server"

            if [ $idx -eq $cursor ]; then
                echo -e "  ${CYAN}▸${NC} ${BOLD}[$((idx + 1))]${NC} ${BOLD}$name${NC}"
                echo -e "      ${DIM}$host${NC}  $label"
            else
                echo -e "    [$((idx + 1))] $name"
                echo -e "      ${DIM}$host${NC}  ${DIM}$label${NC}"
            fi
            echo ""
            ((idx++))
        done

        draw_footer "↑↓: Navigate   Enter: Select   q: Quit"

        local key=$(tui_read_key)
        case "$key" in
            UP|k)
                ((cursor > 0)) && ((cursor--))
                ;;
            DOWN|j)
                ((cursor < total - 1)) && ((cursor++))
                ;;
            ENTER)
                IFS='|' read -r name host label <<< "${servers[$cursor]}"
                if [ "$name" = "_custom" ]; then
                    tui_cursor_show
                    echo ""
                    read -p "Enter SSH connection (user@host): " SELECTED_SSH_HOST
                    read -p "Enter SSH key path [~/.ssh/nwp]: " SELECTED_SSH_KEY
                    SELECTED_SSH_KEY="${SELECTED_SSH_KEY:-$HOME/.ssh/nwp}"
                    SELECTED_SSH_KEY="${SELECTED_SSH_KEY/#\~/$HOME}"
                    SELECTED_SERVER_NAME="custom"
                else
                    SELECTED_SERVER_NAME="$name"
                    SELECTED_SSH_HOST="$host"
                    # Get SSH key from config
                    eval "$(get_server_config "$name" "$config_file")"
                    SELECTED_SSH_KEY="${SERVER_SSH_KEY:-$HOME/.ssh/nwp}"
                fi
                tui_cursor_show
                return 0
                ;;
            q|Q|ESC)
                tui_cursor_show
                return 1
                ;;
            [1-9])
                if [ "$key" -le "$total" ]; then
                    cursor=$((key - 1))
                fi
                ;;
        esac
    done
}

################################################################################
# Site Discovery Screen
################################################################################

# Show scanning progress
# Usage: show_scanning_progress "server_name" "ssh_host"
show_scanning_progress() {
    local server_name="$1"
    local ssh_host="$2"

    tui_clear_screen
    draw_header "Scanning Server" "$server_name"

    echo "  Connecting to $ssh_host..."
    echo ""
    echo -e "  ${DIM}Scanning /var/www/ for Drupal sites...${NC}"
    echo ""
}

# Display discovered sites and allow selection
# Usage: select_sites_to_import
# Uses: DISCOVERED_SITES array
# Sets: SELECTED_SITES array (indices)
select_sites_to_import() {
    local cursor=0
    local total=${#DISCOVERED_SITES[@]}

    if [ $total -eq 0 ]; then
        print_error "No Drupal sites found on server"
        return 1
    fi

    # Initialize selection (none selected by default)
    SELECTED_SITES=()
    declare -A selected_map=()

    tui_cursor_hide
    trap 'tui_cursor_show' EXIT INT TERM

    while true; do
        tui_clear_screen
        draw_header "Select Sites" "$SELECTED_SERVER_NAME"

        echo "  Found $total Drupal site(s). Select sites to import:"
        echo ""

        local idx=0
        local total_db=0
        local selected_count=0

        for site_json in "${DISCOVERED_SITES[@]}"; do
            eval "$(parse_site_json "$site_json")"

            # Checkbox state
            local checkbox="[ ]"
            if [ "${selected_map[$idx]}" = "1" ]; then
                checkbox="${GREEN}[✓]${NC}"
                ((selected_count++))
            fi

            # Cursor indicator
            local pointer="  "
            if [ $idx -eq $cursor ]; then
                pointer="${CYAN}▸${NC}"
                checkbox="${BOLD}$checkbox${NC}"
            fi

            # Format size display
            local db_display="$SITE_DB_SIZE"
            [ "$db_display" = "unknown" ] && db_display="${DIM}?${NC}"

            # Version display with color
            local version_display="$SITE_VERSION"
            if [[ "$SITE_DRUPAL_MAJOR" -lt "9" ]]; then
                version_display="${YELLOW}$SITE_VERSION${NC}"
            fi

            # Drush indicator
            local drush_indicator=""
            [ "$SITE_HAS_DRUSH" = "n" ] && drush_indicator=" ${RED}(no drush)${NC}"

            printf " %b %b %-18s %-14s DB: %-8s Files: %s%b\n" \
                "$pointer" "$checkbox" "$SITE_NAME" "$version_display" "$db_display MB" "$SITE_FILES_SIZE" "$drush_indicator"

            ((idx++))
        done

        echo ""
        echo -e "  ─────────────────────────────────────────────────────────────────"
        echo -e "  ${BOLD}Selected: $selected_count site(s)${NC}"
        echo ""

        draw_footer "↑↓: Navigate   Space: Toggle   a: All   n: None   Enter: Continue   q: Cancel"

        local key=$(tui_read_key)
        case "$key" in
            UP|k)
                ((cursor > 0)) && ((cursor--))
                ;;
            DOWN|j)
                ((cursor < total - 1)) && ((cursor++))
                ;;
            SPACE)
                if [ "${selected_map[$cursor]}" = "1" ]; then
                    unset selected_map[$cursor]
                else
                    selected_map[$cursor]="1"
                fi
                ;;
            a|A)
                # Select all
                for ((i = 0; i < total; i++)); do
                    selected_map[$i]="1"
                done
                ;;
            n|N)
                # Select none
                selected_map=()
                ;;
            ENTER)
                # Build selected indices array
                SELECTED_SITES=()
                for ((i = 0; i < total; i++)); do
                    if [ "${selected_map[$i]}" = "1" ]; then
                        SELECTED_SITES+=($i)
                    fi
                done

                if [ ${#SELECTED_SITES[@]} -eq 0 ]; then
                    echo ""
                    print_warning "No sites selected. Press any key to continue..."
                    read -rsn1
                else
                    tui_cursor_show
                    return 0
                fi
                ;;
            q|Q|ESC)
                tui_cursor_show
                return 1
                ;;
        esac
    done
}

################################################################################
# Import Options Screen
################################################################################

# Define import options with labels and descriptions
declare -A IMPORT_OPTION_LABELS=(
    [sanitize]="Sanitize user data"
    [truncate_cache]="Truncate cache tables"
    [truncate_watchdog]="Truncate watchdog/logs"
    [truncate_sessions]="Truncate sessions"
    [stage_file_proxy]="Stage File Proxy"
    [full_file_sync]="Full file sync"
    [exclude_generated]="Exclude generated files"
    [environment_indicator]="Environment indicator"
    [dev_modules]="Development modules"
    [config_split]="Config split"
)

declare -A IMPORT_OPTION_DESCRIPTIONS=(
    [sanitize]="Replace emails, reset passwords for GDPR"
    [truncate_cache]="Clear all cache_* tables to reduce size"
    [truncate_watchdog]="Remove log entries"
    [truncate_sessions]="Clear active sessions"
    [stage_file_proxy]="Download files on-demand from production"
    [full_file_sync]="Download all public files (slower)"
    [exclude_generated]="Skip js/*, css/*, styles/*"
    [environment_indicator]="Show dev/stg/prod badge in admin"
    [dev_modules]="Install devel, webprofiler, kint"
    [config_split]="Enable environment-specific config"
)

declare -a IMPORT_OPTION_ORDER=(
    "sanitize"
    "truncate_cache"
    "truncate_watchdog"
    "truncate_sessions"
    "stage_file_proxy"
    "full_file_sync"
    "exclude_generated"
    "environment_indicator"
    "dev_modules"
    "config_split"
)

declare -A IMPORT_OPTION_CATEGORIES=(
    [sanitize]="database"
    [truncate_cache]="database"
    [truncate_watchdog]="database"
    [truncate_sessions]="database"
    [stage_file_proxy]="files"
    [full_file_sync]="files"
    [exclude_generated]="files"
    [environment_indicator]="environment"
    [dev_modules]="environment"
    [config_split]="environment"
)

# Configure import options for a site
# Usage: configure_import_options "site_name"
# Uses/Sets: IMPORT_OPTIONS array
configure_import_options() {
    local site_name="$1"
    local cursor=0
    local total=${#IMPORT_OPTION_ORDER[@]}

    # Initialize options with defaults if not set
    for opt in "${IMPORT_OPTION_ORDER[@]}"; do
        local key="${site_name}:${opt}"
        if [ -z "${IMPORT_OPTIONS[$key]}" ]; then
            IMPORT_OPTIONS[$key]="${IMPORT_DEFAULTS[$opt]}"
        fi
    done

    tui_cursor_hide
    trap 'tui_cursor_show' EXIT INT TERM

    while true; do
        tui_clear_screen
        draw_header "Import Options" "$site_name"

        local current_category=""
        local idx=0

        for opt in "${IMPORT_OPTION_ORDER[@]}"; do
            local category="${IMPORT_OPTION_CATEGORIES[$opt]}"
            local label="${IMPORT_OPTION_LABELS[$opt]}"
            local desc="${IMPORT_OPTION_DESCRIPTIONS[$opt]}"
            local key="${site_name}:${opt}"
            local value="${IMPORT_OPTIONS[$key]}"

            # Category header
            if [ "$category" != "$current_category" ]; then
                current_category="$category"
                local cat_label=$(echo "$category" | tr '[:lower:]' '[:upper:]')
                echo ""
                echo -e "  ${BOLD}── $cat_label ──${NC}"
            fi

            # Checkbox state
            local checkbox="[ ]"
            if [ "$value" = "y" ]; then
                checkbox="${GREEN}[✓]${NC}"
            fi

            # Cursor indicator
            local pointer="  "
            if [ $idx -eq $cursor ]; then
                pointer="${CYAN}▸${NC}"
            fi

            printf " %b %b %-28s ${DIM}%s${NC}\n" "$pointer" "$checkbox" "$label" "$desc"

            ((idx++))
        done

        echo ""
        draw_footer "↑↓: Navigate   Space: Toggle   g: Apply to all sites   Enter: Confirm   q: Cancel"

        local key=$(tui_read_key)
        case "$key" in
            UP|k)
                ((cursor > 0)) && ((cursor--))
                ;;
            DOWN|j)
                ((cursor < total - 1)) && ((cursor++))
                ;;
            SPACE)
                local opt="${IMPORT_OPTION_ORDER[$cursor]}"
                local opt_key="${site_name}:${opt}"
                if [ "${IMPORT_OPTIONS[$opt_key]}" = "y" ]; then
                    IMPORT_OPTIONS[$opt_key]="n"

                    # Handle conflicts: stage_file_proxy and full_file_sync
                    if [ "$opt" = "full_file_sync" ]; then
                        IMPORT_OPTIONS["${site_name}:stage_file_proxy"]="y"
                    fi
                else
                    IMPORT_OPTIONS[$opt_key]="y"

                    # Handle conflicts
                    if [ "$opt" = "stage_file_proxy" ]; then
                        IMPORT_OPTIONS["${site_name}:full_file_sync"]="n"
                    elif [ "$opt" = "full_file_sync" ]; then
                        IMPORT_OPTIONS["${site_name}:stage_file_proxy"]="n"
                    fi
                fi
                ;;
            g|G)
                # Apply current site's options to all selected sites
                tui_cursor_show
                echo ""
                read -p "Apply these options to all selected sites? [Y/n]: " confirm
                if [[ ! "$confirm" =~ ^[Nn]$ ]]; then
                    for site_idx in "${SELECTED_SITES[@]}"; do
                        eval "$(parse_site_json "${DISCOVERED_SITES[$site_idx]}")"
                        local other_name="$SITE_NAME"
                        if [ "$other_name" != "$site_name" ]; then
                            for opt in "${IMPORT_OPTION_ORDER[@]}"; do
                                IMPORT_OPTIONS["${other_name}:${opt}"]="${IMPORT_OPTIONS["${site_name}:${opt}"]}"
                            done
                        fi
                    done
                    print_status "OK" "Options applied to all sites"
                    sleep 1
                fi
                tui_cursor_hide
                ;;
            ENTER)
                tui_cursor_show
                return 0
                ;;
            q|Q|ESC)
                tui_cursor_show
                return 1
                ;;
        esac
    done
}

# Configure options for all selected sites
# Usage: configure_all_import_options
configure_all_import_options() {
    for site_idx in "${SELECTED_SITES[@]}"; do
        eval "$(parse_site_json "${DISCOVERED_SITES[$site_idx]}")"
        if ! configure_import_options "$SITE_NAME"; then
            return 1
        fi
    done
    return 0
}

################################################################################
# Confirmation Screen
################################################################################

# Show confirmation screen before import
# Usage: confirm_import
# Returns: 0 to proceed, 1 to cancel
confirm_import() {
    tui_clear_screen
    draw_header "Confirm Import"

    echo "  Ready to import ${#SELECTED_SITES[@]} site(s) from $SELECTED_SERVER_NAME:"
    echo ""

    for site_idx in "${SELECTED_SITES[@]}"; do
        eval "$(parse_site_json "${DISCOVERED_SITES[$site_idx]}")"

        echo -e "  ┌─────────────────────────────────────────────────────────────────┐"
        echo -e "  │ ${BOLD}$SITE_NAME${NC}"
        echo -e "  │   Source: $SITE_WEBROOT"
        echo -e "  │   Local:  $(pwd)/$SITE_NAME"

        # Show enabled options
        local enabled_opts=""
        for opt in "${IMPORT_OPTION_ORDER[@]}"; do
            if [ "${IMPORT_OPTIONS["${SITE_NAME}:${opt}"]}" = "y" ]; then
                [ -n "$enabled_opts" ] && enabled_opts+=", "
                enabled_opts+="$opt"
            fi
        done
        echo -e "  │   Options: ${DIM}$enabled_opts${NC}"
        echo -e "  └─────────────────────────────────────────────────────────────────┘"
        echo ""
    done

    echo ""
    read -p "  Start import? [Y/n]: " confirm

    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        return 1
    fi
    return 0
}

################################################################################
# Progress Screen
################################################################################

# Import step tracking
declare -a IMPORT_STEPS=(
    "Create local directory"
    "Configure DDEV"
    "Pull database"
    "Pull files"
    "Import database"
    "Sanitize database"
    "Configure settings.php"
    "Configure Stage File Proxy"
    "Clear caches"
    "Verify site boots"
    "Register in cnwp.yml"
)

CURRENT_IMPORT_STEP=0
CURRENT_IMPORT_SITE=""

# Show import progress
# Usage: show_import_progress "site_name" "current_step" "total_sites" "current_site_num"
show_import_progress() {
    local site_name="$1"
    local step="$2"
    local total_sites="$3"
    local site_num="$4"

    CURRENT_IMPORT_SITE="$site_name"
    CURRENT_IMPORT_STEP="$step"

    tui_clear_screen
    draw_header "Import Progress"

    echo "  Importing $site_name ($site_num/$total_sites)"
    echo ""

    # Progress bar
    local total_steps=${#IMPORT_STEPS[@]}
    local progress=$((step * 100 / total_steps))
    local bar_width=50
    local filled=$((progress * bar_width / 100))
    local empty=$((bar_width - filled))

    printf "  ["
    printf "${GREEN}█%.0s${NC}" $(seq 1 $filled) 2>/dev/null || true
    printf "░%.0s" $(seq 1 $empty) 2>/dev/null || true
    printf "] %d%%\n" "$progress"
    echo ""

    # Show steps
    local idx=0
    for step_name in "${IMPORT_STEPS[@]}"; do
        if [ $idx -lt $step ]; then
            echo -e "  ${GREEN}✓${NC} Step $((idx + 1)):  $step_name"
        elif [ $idx -eq $step ]; then
            echo -e "  ${CYAN}●${NC} Step $((idx + 1)):  $step_name ${DIM}...${NC}"
        else
            echo -e "  ${DIM}○ Step $((idx + 1)):  $step_name${NC}"
        fi
        ((idx++))
    done

    echo ""
}

# Mark a step as complete
# Usage: complete_import_step "step_num" "duration"
complete_import_step() {
    local step="$1"
    local duration="${2:-}"

    # Move cursor to the step line and update it
    local line=$((step + 8))  # Account for header lines
    tui_cursor_to $line 1
    tui_clear_line

    local step_name="${IMPORT_STEPS[$step]}"
    if [ -n "$duration" ]; then
        echo -e "  ${GREEN}✓${NC} Step $((step + 1)):  $step_name  ${DIM}${duration}${NC}"
    else
        echo -e "  ${GREEN}✓${NC} Step $((step + 1)):  $step_name"
    fi
}

################################################################################
# Completion Screen
################################################################################

# Show completion summary
# Usage: show_import_complete "results_array"
# results_array format: "site_name|url|duration|status"
show_import_complete() {
    local -n results=$1

    tui_clear_screen
    draw_header "Import Complete"

    local success_count=0
    local fail_count=0

    for result in "${results[@]}"; do
        IFS='|' read -r name url duration status <<< "$result"
        if [ "$status" = "success" ]; then
            ((success_count++))
        else
            ((fail_count++))
        fi
    done

    if [ $fail_count -eq 0 ]; then
        echo -e "  ${GREEN}✓ Successfully imported ${success_count} site(s)!${NC}"
    else
        echo -e "  ${YELLOW}Imported ${success_count} site(s), ${fail_count} failed${NC}"
    fi
    echo ""

    for result in "${results[@]}"; do
        IFS='|' read -r name url duration status <<< "$result"

        echo -e "  ┌─────────────────────────────────────────────────────────────────┐"
        if [ "$status" = "success" ]; then
            echo -e "  │ ${GREEN}✓${NC} ${BOLD}$name${NC}"
            echo -e "  │   URL:   $url"
            echo -e "  │   Admin: ${url}/user/login"
            echo -e "  │   Time:  $duration"
        else
            echo -e "  │ ${RED}✗${NC} ${BOLD}$name${NC}"
            echo -e "  │   ${RED}Import failed${NC}"
        fi
        echo -e "  └─────────────────────────────────────────────────────────────────┘"
        echo ""
    done

    echo "  Next steps:"
    for result in "${results[@]}"; do
        IFS='|' read -r name url duration status <<< "$result"
        if [ "$status" = "success" ]; then
            echo -e "    cd $name && ddev launch"
            break
        fi
    done
    echo -e "    ./sync.sh <sitename>        # Re-sync from production"
    echo -e "    ./backup.sh <sitename>      # Create local backup"
    echo ""

    read -p "  Press Enter to finish..."
}

################################################################################
# Helper Functions
################################################################################

# Get option value for a site
# Usage: get_import_option "site_name" "option_key"
get_import_option() {
    local site_name="$1"
    local option="$2"
    echo "${IMPORT_OPTIONS["${site_name}:${option}"]:-${IMPORT_DEFAULTS[$option]}}"
}

# Check if an option is enabled for a site
# Usage: if option_enabled "site_name" "option_key"; then ...
option_enabled() {
    local site_name="$1"
    local option="$2"
    [ "$(get_import_option "$site_name" "$option")" = "y" ]
}

# Get local site name (with conflict resolution)
# Usage: get_local_site_name "remote_site_name"
get_local_site_name() {
    local name="$1"
    local base_name="$name"
    local counter=1

    while [ -d "$name" ]; do
        name="${base_name}_${counter}"
        ((counter++))
    done

    echo "$name"
}

################################################################################
# Export Functions
################################################################################

export -f select_server
export -f show_scanning_progress
export -f select_sites_to_import
export -f configure_import_options
export -f configure_all_import_options
export -f confirm_import
export -f show_import_progress
export -f complete_import_step
export -f show_import_complete
export -f get_import_option
export -f option_enabled
export -f get_local_site_name
