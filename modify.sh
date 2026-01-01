#!/bin/bash
set -euo pipefail

################################################################################
# NWP Site Modification Script
#
# Interactive TUI for modifying options on existing sites in cnwp.yml
# Usage: ./modify.sh [site_name]
#
# Examples:
#   ./modify.sh           - Interactive site selection
#   ./modify.sh nwp5      - Modify options for 'nwp5' site
#   ./modify.sh -l        - List all sites
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Source shared libraries
source "$SCRIPT_DIR/lib/ui.sh"
source "$SCRIPT_DIR/lib/common.sh"

# Source YAML library
if [ -f "$SCRIPT_DIR/lib/yaml-write.sh" ]; then
    source "$SCRIPT_DIR/lib/yaml-write.sh"
fi

# Source interactive checkbox library
if [ -f "$SCRIPT_DIR/lib/checkbox.sh" ]; then
    source "$SCRIPT_DIR/lib/checkbox.sh"
fi

CONFIG_FILE="${SCRIPT_DIR}/cnwp.yml"

################################################################################
# Terminal Control Functions
################################################################################

cursor_to() { printf "\033[%d;%dH" "$1" "$2"; }
cursor_hide() { printf "\033[?25l"; }
cursor_show() { printf "\033[?25h"; }
clear_screen() { printf "\033[2J\033[H"; }

read_key() {
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

# Environment list
ENVIRONMENTS=("dev" "stage" "live" "prod")

# Installed status tracking
declare -A OPTION_INSTALLED

# Config status tracking (what cnwp.yml says should be installed)
declare -A OPTION_FROM_CONFIG

# Hierarchy depth tracking (0=parent, 1=child, 2=grandchild)
declare -A OPTION_DEPTH

get_env_index() {
    local env="$1"
    local i=0
    for e in "${ENVIRONMENTS[@]}"; do
        [[ "$e" == "$env" ]] && { echo "$i"; return; }
        ((i++))
    done
    echo "0"
}

get_env_label() {
    local env="$1"
    case "$env" in
        dev) echo "Development" ;;
        stage) echo "Staging" ;;
        live) echo "Live" ;;
        prod) echo "Production" ;;
        *) echo "$env" ;;
    esac
}

################################################################################
# Installation Status Detection
################################################################################

# Check what options are currently installed on the site
check_installed_status() {
    local directory="$1"
    local recipe_type="$2"
    local original_dir="$PWD"

    # Reset installed status
    OPTION_INSTALLED=()

    [ ! -d "$directory" ] && return 0

    cd "$directory" || return 0

    case "$recipe_type" in
        drupal|d|os|nwp|dm|"")
            # Check if DDEV is available
            if [ -d ".ddev" ]; then
                # Check if site is running, start if not
                if ! ddev describe &>/dev/null; then
                    # Site not running - can't check installed status without starting
                    cd "$original_dir"
                    return 0
                fi

                # Get list of enabled modules
                local enabled_modules=""
                enabled_modules=$(ddev drush pm:list --status=enabled --format=list 2>/dev/null) || true

                # Check dev modules
                if echo "$enabled_modules" | grep -qw "devel"; then
                    OPTION_INSTALLED["dev_modules"]="y"
                fi

                # Check stage_file_proxy
                if echo "$enabled_modules" | grep -qw "stage_file_proxy"; then
                    OPTION_INSTALLED["stage_file_proxy"]="y"
                fi

                # Check config_split
                if echo "$enabled_modules" | grep -qw "config_split"; then
                    OPTION_INSTALLED["config_split"]="y"
                fi

                # Check security modules (need at least 2 of the 4)
                local sec_count=0
                echo "$enabled_modules" | grep -qw "seckit" && ((sec_count++)) || true
                echo "$enabled_modules" | grep -qw "honeypot" && ((sec_count++)) || true
                echo "$enabled_modules" | grep -qw "login_security" && ((sec_count++)) || true
                echo "$enabled_modules" | grep -qw "flood_control" && ((sec_count++)) || true
                [ $sec_count -ge 2 ] && OPTION_INSTALLED["security_modules"]="y"

                # Check redis module
                if echo "$enabled_modules" | grep -qw "redis"; then
                    OPTION_INSTALLED["redis"]="y"
                fi

                # Check search_api_solr
                if echo "$enabled_modules" | grep -qw "search_api_solr"; then
                    OPTION_INSTALLED["solr"]="y"
                fi

                # Check ultimate_cron
                if echo "$enabled_modules" | grep -qw "ultimate_cron"; then
                    OPTION_INSTALLED["cron"]="y"
                fi

                # Check XDebug status
                local xdebug_status=""
                xdebug_status=$(ddev xdebug status 2>/dev/null) || true
                if echo "$xdebug_status" | grep -qi "enabled"; then
                    OPTION_INSTALLED["xdebug"]="y"
                fi

                # Check if Redis service is configured in DDEV
                if [ -f ".ddev/docker-compose.redis.yaml" ] || [ -d ".ddev/redis" ]; then
                    OPTION_INSTALLED["redis"]="y"
                fi

                # Check if Solr service is configured in DDEV
                if [ -f ".ddev/docker-compose.solr.yaml" ] || [ -d ".ddev/solr" ]; then
                    OPTION_INSTALLED["solr"]="y"
                fi
            fi
            ;;
        moodle|m)
            # Moodle-specific checks would go here
            ;;
        gitlab)
            # GitLab-specific checks would go here
            ;;
    esac

    cd "$original_dir"
}

################################################################################
# Site Functions
################################################################################

list_sites() {
    local config_file="$1"
    [ ! -f "$config_file" ] && return 1

    awk '
        /^sites:/ { in_sites = 1; next }
        in_sites && /^[a-zA-Z]/ && !/^  / { exit }
        in_sites && /^  [a-zA-Z_][a-zA-Z0-9_-]*:/ && !/^    / {
            gsub(/:.*/, "")
            gsub(/^  /, "")
            if ($0 !~ /^#/) print
        }
    ' "$config_file"
}

get_site_field() {
    local site="$1"
    local field="$2"
    local config_file="$3"

    awk -v site="$site" -v field="$field" '
        /^sites:/ { in_sites = 1; next }
        in_sites && /^[a-zA-Z]/ && !/^  / { exit }
        in_sites && $0 ~ "^  " site ":" { in_site = 1; next }
        in_site && /^  [a-zA-Z]/ && !/^    / { exit }
        in_site && $0 ~ "^    " field ":" {
            sub("^    " field ": *", "")
            gsub(/["'"'"']/, "")
            sub(/ *#.*$/, "")
            gsub(/^[ \t]+|[ \t]+$/, "")
            print
            exit
        }
    ' "$config_file"
}

################################################################################
# Site Selection TUI
################################################################################

SITE_NAMES=()
SITE_DATA=()

build_site_list() {
    local config_file="$1"
    SITE_NAMES=()
    SITE_DATA=()

    while read -r site; do
        [ -z "$site" ] && continue
        SITE_NAMES+=("$site")
        local recipe=$(get_site_field "$site" "recipe" "$config_file")
        local directory=$(get_site_field "$site" "directory" "$config_file")
        local environment=$(get_site_field "$site" "environment" "$config_file")
        local exists="N"
        [ -d "$directory" ] && exists="Y"
        SITE_DATA+=("${recipe:-?}|${environment:-dev}|${exists}|${directory:-}")
    done < <(list_sites "$config_file")
}

draw_site_selection() {
    local current_row="$1"

    clear_screen

    printf "${BOLD}NWP Modify${NC}  |  ↑↓:Navigate  ENTER:Select  q:Quit\n"
    printf "═══════════════════════════════════════════════════════════════════════════════\n"
    printf "\n"
    printf "${BOLD}   %-20s %-12s %-12s %-6s %s${NC}\n" "SITE" "RECIPE" "ENVIRONMENT" "EXISTS" "DIRECTORY"
    printf "   %-20s %-12s %-12s %-6s %s\n" "--------------------" "------------" "------------" "------" "---------"

    local row=0
    for site in "${SITE_NAMES[@]}"; do
        IFS='|' read -r recipe env exists dir <<< "${SITE_DATA[$row]}"

        local exists_color="${RED}No${NC}"
        [ "$exists" = "Y" ] && exists_color="${GREEN}Yes${NC}"

        if [ $row -eq $current_row ]; then
            printf "${BOLD}${CYAN}▸${NC} "
        else
            printf "  "
        fi

        printf "%-20s %-12s %-12s " "$site" "$recipe" "$env"
        printf "%b" "$exists_color"
        printf "     %s\n" "$dir"

        ((row++))
    done

    printf "\n"
    printf "───────────────────────────────────────────────────────────────────────────────\n"
    printf "Select a site to modify its options.\n"
}

select_site_interactive() {
    local config_file="$1"

    build_site_list "$config_file"

    if [ ${#SITE_NAMES[@]} -eq 0 ]; then
        print_error "No sites found in cnwp.yml"
        return 1
    fi

    local num_sites=${#SITE_NAMES[@]}
    local current_row=0

    cursor_hide
    trap 'cursor_show' EXIT

    while true; do
        draw_site_selection $current_row

        local key=$(read_key)

        case "$key" in
            UP|k|K)
                [ $current_row -gt 0 ] && ((current_row--)) || true
                ;;
            DOWN|j|J)
                [ $current_row -lt $((num_sites - 1)) ] && ((current_row++)) || true
                ;;
            ENTER)
                cursor_show
                echo "${SITE_NAMES[$current_row]}"
                return 0
                ;;
            q|Q|ESC)
                cursor_show
                return 1
                ;;
        esac
    done
}

################################################################################
# Options TUI
################################################################################

draw_options_screen() {
    local site_name="$1"
    local environment="$2"
    local current_row="$3"
    local total="${#VISIBLE_OPTIONS[@]}"

    clear_screen

    # Header with environment selector
    printf "${BOLD}Modify: ${CYAN}%s${NC}  |  " "$site_name"

    # Environment tabs
    for env in "${ENVIRONMENTS[@]}"; do
        if [[ "$env" == "$environment" ]]; then
            printf "${GREEN}${BOLD}[%s]${NC} " "${env^^}"
        else
            printf "${DIM}%s${NC} " "${env^^}"
        fi
    done
    printf "\n"

    printf "${DIM}↑↓:Navigate  ←→:Environment  SPACE:Toggle  e:Edit  a:All  n:None  ENTER:Apply  q:Cancel${NC}\n"
    printf "═══════════════════════════════════════════════════════════════════════════════\n"

    if [ "$total" -eq 0 ]; then
        printf "\n${DIM}  No options for this environment${NC}\n"
    else
        local row=0

        for key in "${VISIBLE_OPTIONS[@]}"; do
            local opt_env="${OPTION_ENVIRONMENTS[$key]}"
            local label="${OPTION_LABELS[$key]}"
            local selected="${OPTION_SELECTED[$key]:-n}"
            local installed="${OPTION_INSTALLED[$key]:-n}"
            local inputs="${OPTION_INPUTS[$key]:-}"
            local deps="${OPTION_DEPENDENCIES[$key]:-}"
            local depth="${OPTION_DEPTH[$key]:-0}"

            # Hierarchical indentation
            local indent=""
            if [ "$depth" -eq 1 ]; then
                indent="  └─ "
            elif [ "$depth" -eq 2 ]; then
                indent="      └─ "
            fi

            # Checkbox with state indicators:
            # [✓] green  - Installed (inherently selected/kept)
            # [x] red    - Installed but selected for removal
            # [+] yellow - Not installed, selected to be installed
            # [!] red    - In cnwp.yml but not installed (mismatch)
            # [ ] dim    - Not installed, not selected
            local checkbox
            local from_config="${OPTION_FROM_CONFIG[$key]:-n}"

            if [ "$installed" = "y" ]; then
                if [ "$selected" = "y" ]; then
                    checkbox="${GREEN}[✓]${NC}"       # Installed, keep it
                else
                    checkbox="${RED}[x]${NC}"         # Installed, will be removed
                fi
            else
                if [ "$selected" = "y" ]; then
                    checkbox="${YELLOW}[+]${NC}"      # Not installed, will be installed
                elif [ "$from_config" = "y" ]; then
                    checkbox="${RED}[!]${NC}"         # Config mismatch - should be installed
                else
                    checkbox="${DIM}[ ]${NC}"         # Not installed, not wanted
                fi
            fi

            # Cursor
            local pointer="  "
            local is_current=false
            if [ $row -eq $current_row ]; then
                pointer="${CYAN}▸${NC} "
                is_current=true
            fi

            # Adjust label length based on depth
            local max_label_len=$((24 - ${#indent}))
            [ $max_label_len -lt 10 ] && max_label_len=10

            # Build value display for options with inputs
            local value_display=""
            if [ -n "$inputs" ]; then
                # Get the first input's value
                local first_input="${inputs%%,*}"
                local ikey="${first_input%%:*}"
                local vkey="${key}_${ikey}"
                local val="${OPTION_VALUES[$vkey]:-}"
                if [ -n "$val" ]; then
                    value_display="${DIM}[${NC}${CYAN}${val:0:20}${NC}${DIM}]${NC}"
                else
                    value_display="${DIM}[          ]${NC}"
                fi
                # Show edit hint if current row
                if [ "$is_current" = true ]; then
                    value_display="${value_display} ${DIM}e:edit${NC}"
                fi
            fi

            printf "%b%s%b %-${max_label_len}s %b\n" "$pointer" "$indent" "$checkbox" "${label:0:$max_label_len}" "$value_display"

            ((row++))
        done
    fi

    # Footer
    local sel_count=0
    local installed_count=0
    for k in "${OPTION_LIST[@]}"; do
        [ "${OPTION_SELECTED[$k]:-n}" = "y" ] && ((sel_count++)) || true
        [ "${OPTION_INSTALLED[$k]:-n}" = "y" ] && ((installed_count++)) || true
    done

    printf "\n"
    printf "───────────────────────────────────────────────────────────────────────────────\n"
    printf "${GREEN}[✓]${NC}=installed  ${RED}[x]${NC}=remove  ${YELLOW}[+]${NC}=install  ${RED}[!]${NC}=config mismatch  ${DIM}[ ]${NC}=none\n"
    printf "Selected: %d  Installed: %d  Environment: ${GREEN}%s${NC}\n" "$sel_count" "$installed_count" "$(get_env_label "$environment")"
}

build_env_option_list() {
    local environment="$1"

    VISIBLE_OPTIONS=()
    OPTION_DEPTH=()  # Reset hierarchy depth

    # First pass: find all options for this environment
    local env_options=()
    for key in "${OPTION_LIST[@]}"; do
        local opt_env="${OPTION_ENVIRONMENTS[$key]}"
        if [[ "$opt_env" == "$environment" || "$opt_env" == "all" ]]; then
            env_options+=("$key")
        fi
    done

    # Second pass: build hierarchical list
    # First add options with no dependencies (parents)
    for key in "${env_options[@]}"; do
        local deps="${OPTION_DEPENDENCIES[$key]:-}"
        if [[ -z "$deps" ]]; then
            VISIBLE_OPTIONS+=("$key")
            OPTION_DEPTH["$key"]=0

            # Add children of this option
            for child in "${env_options[@]}"; do
                local child_deps="${OPTION_DEPENDENCIES[$child]:-}"
                if [[ -n "$child_deps" ]]; then
                    # Check if this child depends directly on current parent
                    IFS=',' read -ra dep_arr <<< "$child_deps"
                    for dep in "${dep_arr[@]}"; do
                        if [[ "$dep" == "$key" ]]; then
                            # Check if child not already added
                            local already_added=false
                            for v in "${VISIBLE_OPTIONS[@]}"; do
                                [[ "$v" == "$child" ]] && already_added=true
                            done
                            if [[ "$already_added" != "true" ]]; then
                                VISIBLE_OPTIONS+=("$child")
                                OPTION_DEPTH["$child"]=1

                                # Add grandchildren (depth 2)
                                for grandchild in "${env_options[@]}"; do
                                    local gc_deps="${OPTION_DEPENDENCIES[$grandchild]:-}"
                                    if [[ -n "$gc_deps" && "$gc_deps" == *"$child"* ]]; then
                                        local gc_added=false
                                        for v in "${VISIBLE_OPTIONS[@]}"; do
                                            [[ "$v" == "$grandchild" ]] && gc_added=true
                                        done
                                        if [[ "$gc_added" != "true" ]]; then
                                            VISIBLE_OPTIONS+=("$grandchild")
                                            OPTION_DEPTH["$grandchild"]=2
                                        fi
                                    fi
                                done
                            fi
                            break
                        fi
                    done
                fi
            done
        fi
    done

    # Final pass: add any remaining options that weren't placed (orphans with missing parents)
    for key in "${env_options[@]}"; do
        local found=false
        for v in "${VISIBLE_OPTIONS[@]}"; do
            [[ "$v" == "$key" ]] && found=true
        done
        if [[ "$found" != "true" ]]; then
            VISIBLE_OPTIONS+=("$key")
            OPTION_DEPTH["$key"]=0
        fi
    done
}

run_options_tui() {
    local site_name="$1"
    local environment="$2"
    local recipe_type="$3"
    local directory="$4"

    # Load options
    case "$recipe_type" in
        drupal|d|os|nwp|dm|"") define_drupal_options ;;
        moodle|m) define_moodle_options ;;
        gitlab) define_gitlab_options ;;
        *) define_drupal_options ;;
    esac

    # Check what's currently installed on the site (silent)
    if [ -n "$directory" ] && [ -d "$directory" ]; then
        check_installed_status "$directory" "$recipe_type"
    fi

    # Load existing config
    load_existing_config "$site_name" "$CONFIG_FILE" 2>/dev/null || true

    # Build option list for current environment
    build_env_option_list "$environment"

    local current_row=0
    local env_index=$(get_env_index "$environment")

    cursor_hide
    trap 'cursor_show' EXIT INT TERM

    while true; do
        local total="${#VISIBLE_OPTIONS[@]}"
        draw_options_screen "$site_name" "$environment" "$current_row"

        local key=$(read_key)

        case "$key" in
            UP|k|K)
                [ $current_row -gt 0 ] && ((current_row--)) || true
                ;;
            DOWN|j|J)
                [ "$total" -gt 0 ] && [ $current_row -lt $((total - 1)) ] && ((current_row++)) || true
                ;;
            LEFT)
                # Previous environment
                env_index=$(( (env_index - 1 + 4) % 4 ))
                environment="${ENVIRONMENTS[$env_index]}"
                build_env_option_list "$environment"
                current_row=0
                ;;
            RIGHT)
                # Next environment
                env_index=$(( (env_index + 1) % 4 ))
                environment="${ENVIRONMENTS[$env_index]}"
                build_env_option_list "$environment"
                current_row=0
                ;;
            e|E)
                # Edit value
                if [ "$total" -gt 0 ]; then
                    local opt_key="${VISIBLE_OPTIONS[$current_row]}"
                    local inputs="${OPTION_INPUTS[$opt_key]:-}"
                    if [ -n "$inputs" ]; then
                        cursor_show
                        printf "\n${BOLD}Edit: %s${NC}\n" "${OPTION_LABELS[$opt_key]}"
                        IFS=',' read -ra iarr <<< "$inputs"
                        for inp in "${iarr[@]}"; do
                            local ikey="${inp%%:*}"
                            local ilabel="${inp#*:}"
                            local vkey="${opt_key}_${ikey}"
                            local curr="${OPTION_VALUES[$vkey]:-}"
                            read -rp "  $ilabel [$curr]: " newval
                            OPTION_VALUES["$vkey"]="${newval:-$curr}"
                        done
                        cursor_hide
                    fi
                fi
                ;;
            SPACE)
                if [ "$total" -gt 0 ]; then
                    local opt_key="${VISIBLE_OPTIONS[$current_row]}"
                    if [ "${OPTION_SELECTED[$opt_key]:-n}" = "y" ]; then
                        OPTION_SELECTED["$opt_key"]="n"
                    else
                        OPTION_SELECTED["$opt_key"]="y"
                        # Prompt for inputs
                        local inputs="${OPTION_INPUTS[$opt_key]:-}"
                        if [ -n "$inputs" ]; then
                            cursor_show
                            printf "\n"
                            IFS=',' read -ra iarr <<< "$inputs"
                            for inp in "${iarr[@]}"; do
                                local ikey="${inp%%:*}"
                                local ilabel="${inp#*:}"
                                local vkey="${opt_key}_${ikey}"
                                local curr="${OPTION_VALUES[$vkey]:-}"
                                read -rp "  $ilabel [$curr]: " newval
                                OPTION_VALUES["$vkey"]="${newval:-$curr}"
                            done
                            cursor_hide
                        fi
                    fi
                fi
                ;;
            a|A)
                apply_environment_defaults "$environment"
                build_env_option_list "$environment"
                ;;
            n|N)
                for k in "${OPTION_LIST[@]}"; do
                    OPTION_SELECTED["$k"]="n"
                done
                ;;
            ENTER)
                cursor_show
                return 0
                ;;
            q|Q|ESC)
                cursor_show
                return 1
                ;;
        esac
    done
}

################################################################################
# Apply Options
################################################################################

apply_site_options() {
    local site_name="$1"
    local directory="$2"
    local recipe_type="$3"

    if [ ! -d "$directory" ]; then
        print_error "Directory not found: $directory"
        return 1
    fi

    # Apply options based on recipe type
    cd "$directory"

    print_header "Applying Options"

    local installed=0
    local removed=0
    local needs_restart=false

    case "$recipe_type" in
        drupal|d|os|nwp|dm|"")
            # Check if DDEV is available
            if [ -d ".ddev" ]; then
                if ! ddev describe &>/dev/null; then
                    print_info "Starting DDEV..."
                    ddev start || true
                fi

                # Dev modules
                if [ "${OPTION_SELECTED[dev_modules]:-n}" = "y" ] && [ "${OPTION_INSTALLED[dev_modules]:-n}" != "y" ]; then
                    print_info "Installing dev modules..."
                    ddev drush pm:enable devel -y 2>/dev/null && ((installed++)) || true
                elif [ "${OPTION_SELECTED[dev_modules]:-n}" = "n" ] && [ "${OPTION_INSTALLED[dev_modules]:-n}" = "y" ]; then
                    print_info "Removing dev modules..."
                    ddev drush pm:uninstall devel -y 2>/dev/null && ((removed++)) || true
                fi

                # XDebug
                if [ "${OPTION_SELECTED[xdebug]:-n}" = "y" ] && [ "${OPTION_INSTALLED[xdebug]:-n}" != "y" ]; then
                    print_info "Enabling XDebug..."
                    ddev xdebug on 2>/dev/null && ((installed++)) || true
                elif [ "${OPTION_SELECTED[xdebug]:-n}" = "n" ] && [ "${OPTION_INSTALLED[xdebug]:-n}" = "y" ]; then
                    print_info "Disabling XDebug..."
                    ddev xdebug off 2>/dev/null && ((removed++)) || true
                fi

                # Redis
                if [ "${OPTION_SELECTED[redis]:-n}" = "y" ] && [ "${OPTION_INSTALLED[redis]:-n}" != "y" ]; then
                    print_info "Adding Redis..."
                    ddev get ddev/ddev-redis 2>/dev/null && ((installed++)) && needs_restart=true || true
                elif [ "${OPTION_SELECTED[redis]:-n}" = "n" ] && [ "${OPTION_INSTALLED[redis]:-n}" = "y" ]; then
                    print_info "Removing Redis..."
                    # Disable redis module first if enabled
                    ddev drush pm:uninstall redis -y 2>/dev/null || true
                    # Remove redis addon
                    rm -rf .ddev/redis 2>/dev/null || true
                    rm -f .ddev/docker-compose.redis.yaml 2>/dev/null || true
                    ((removed++))
                    needs_restart=true
                fi

                # Solr
                if [ "${OPTION_SELECTED[solr]:-n}" = "y" ] && [ "${OPTION_INSTALLED[solr]:-n}" != "y" ]; then
                    print_info "Adding Solr..."
                    ddev get ddev/ddev-solr 2>/dev/null && ((installed++)) && needs_restart=true || true
                elif [ "${OPTION_SELECTED[solr]:-n}" = "n" ] && [ "${OPTION_INSTALLED[solr]:-n}" = "y" ]; then
                    print_info "Removing Solr..."
                    ddev drush pm:uninstall search_api_solr -y 2>/dev/null || true
                    rm -rf .ddev/solr 2>/dev/null || true
                    rm -f .ddev/docker-compose.solr.yaml 2>/dev/null || true
                    ((removed++))
                    needs_restart=true
                fi

                # Stage File Proxy
                if [ "${OPTION_SELECTED[stage_file_proxy]:-n}" = "y" ] && [ "${OPTION_INSTALLED[stage_file_proxy]:-n}" != "y" ]; then
                    print_info "Installing Stage File Proxy..."
                    ddev composer require drupal/stage_file_proxy 2>/dev/null || true
                    ddev drush pm:enable stage_file_proxy -y 2>/dev/null && ((installed++)) || true
                elif [ "${OPTION_SELECTED[stage_file_proxy]:-n}" = "n" ] && [ "${OPTION_INSTALLED[stage_file_proxy]:-n}" = "y" ]; then
                    print_info "Removing Stage File Proxy..."
                    ddev drush pm:uninstall stage_file_proxy -y 2>/dev/null && ((removed++)) || true
                fi

                # Config Split
                if [ "${OPTION_SELECTED[config_split]:-n}" = "y" ] && [ "${OPTION_INSTALLED[config_split]:-n}" != "y" ]; then
                    print_info "Installing Config Split..."
                    ddev composer require drupal/config_split 2>/dev/null || true
                    ddev drush pm:enable config_split -y 2>/dev/null && ((installed++)) || true
                elif [ "${OPTION_SELECTED[config_split]:-n}" = "n" ] && [ "${OPTION_INSTALLED[config_split]:-n}" = "y" ]; then
                    print_info "Removing Config Split..."
                    ddev drush pm:uninstall config_split -y 2>/dev/null && ((removed++)) || true
                fi

                # Security modules
                if [ "${OPTION_SELECTED[security_modules]:-n}" = "y" ] && [ "${OPTION_INSTALLED[security_modules]:-n}" != "y" ]; then
                    print_info "Installing security modules..."
                    ddev composer require drupal/seckit drupal/honeypot drupal/login_security drupal/flood_control 2>/dev/null || true
                    ddev drush pm:enable seckit honeypot login_security flood_control -y 2>/dev/null && ((installed++)) || true
                elif [ "${OPTION_SELECTED[security_modules]:-n}" = "n" ] && [ "${OPTION_INSTALLED[security_modules]:-n}" = "y" ]; then
                    print_info "Removing security modules..."
                    ddev drush pm:uninstall seckit honeypot login_security flood_control -y 2>/dev/null && ((removed++)) || true
                fi

                if [ "$needs_restart" = true ]; then
                    print_info "Restarting DDEV..."
                    ddev restart 2>/dev/null || true
                fi
            fi
            ;;
    esac

    print_status "OK" "Installed: $installed  Removed: $removed"

    # Always update cnwp.yml with current selections
    if command -v yaml_site_exists &>/dev/null && yaml_site_exists "$site_name" "$CONFIG_FILE" 2>/dev/null; then
        print_info "Updating cnwp.yml..."
        local options_yaml=$(generate_options_yaml "      ")

        # Remove existing options section and add new one
        awk -v site="$site_name" -v options="$options_yaml" '
            BEGIN { in_site = 0; in_sites = 0; in_options = 0; added = 0 }
            /^sites:/ { in_sites = 1; print; next }
            in_sites && /^[a-zA-Z]/ && !/^  / && !/^#/ { in_sites = 0 }
            in_sites && $0 ~ "^  " site ":" { in_site = 1; print; next }
            in_site && /^    options:/ { in_options = 1; next }
            in_options && /^      / { next }
            in_options && !/^      / { in_options = 0 }
            in_site && (/^  [a-zA-Z0-9_-]+:/ || (/^[a-zA-Z]/ && !/^  / && !/^#/)) {
                if (!added && options != "") { print options; added = 1 }
                in_site = 0
            }
            { print }
            END { if (in_site && !added && options != "") { print options } }
        ' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp"

        mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
        print_status "OK" "cnwp.yml updated"
    fi

    # Show manual steps
    if command -v generate_manual_steps &>/dev/null; then
        generate_manual_steps "$site_name" "$environment"
    fi
}

################################################################################
# Main
################################################################################

show_help() {
    cat << EOF
NWP Site Modification Script

Usage: ./modify.sh [site_name] [options]

Arguments:
  site_name          Name of site from cnwp.yml (optional)

Options:
  -l, --list         List all sites
  -h, --help         Show this help

Interactive Controls:
  ↑/↓                Navigate
  SPACE              Toggle option
  e                  Edit input values
  a                  Select all defaults
  n                  Deselect all
  ENTER              Apply changes
  q                  Cancel/quit

Examples:
  ./modify.sh                  Interactive site selection
  ./modify.sh nwp5             Modify 'nwp5' directly
  ./modify.sh -l               List all sites

EOF
}

main() {
    local site_name=""
    local list_only=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) show_help; exit 0 ;;
            -l|--list) list_only=true; shift ;;
            -*) print_error "Unknown option: $1"; exit 1 ;;
            *) site_name="$1"; shift ;;
        esac
    done

    if [ ! -f "$CONFIG_FILE" ]; then
        print_error "Config file not found: $CONFIG_FILE"
        exit 1
    fi

    # List mode
    if [ "$list_only" = true ]; then
        print_header "Sites in cnwp.yml"
        printf "\n  %-20s %-12s %-12s %s\n" "SITE" "RECIPE" "ENVIRONMENT" "DIRECTORY"
        printf "  %-20s %-12s %-12s %s\n" "--------------------" "------------" "------------" "---------"
        while read -r site; do
            [ -z "$site" ] && continue
            local recipe=$(get_site_field "$site" "recipe" "$CONFIG_FILE")
            local env=$(get_site_field "$site" "environment" "$CONFIG_FILE")
            local dir=$(get_site_field "$site" "directory" "$CONFIG_FILE")
            printf "  %-20s %-12s %-12s %s\n" "$site" "${recipe:-?}" "${env:-dev}" "$dir"
        done < <(list_sites "$CONFIG_FILE")
        echo ""
        exit 0
    fi

    # Interactive site selection if none specified
    if [ -z "$site_name" ]; then
        site_name=$(select_site_interactive "$CONFIG_FILE") || exit 0
    fi

    # Get site info
    local directory=$(get_site_field "$site_name" "directory" "$CONFIG_FILE")
    local recipe=$(get_site_field "$site_name" "recipe" "$CONFIG_FILE")
    local environment=$(get_site_field "$site_name" "environment" "$CONFIG_FILE")

    if [ -z "$directory" ]; then
        print_error "Site '$site_name' not found"
        exit 1
    fi

    # Map environment
    local env_short="dev"
    case "$environment" in
        staging) env_short="stage" ;;
        production) env_short="prod" ;;
        live) env_short="live" ;;
    esac

    # Run options TUI
    if run_options_tui "$site_name" "$env_short" "$recipe" "$directory"; then
        echo ""
        apply_site_options "$site_name" "$directory" "$recipe"
        echo ""
        print_status "OK" "Modification complete for '$site_name'"
    else
        print_info "Modification cancelled"
    fi
}

main "$@"
