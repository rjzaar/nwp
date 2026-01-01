#!/bin/bash
################################################################################
# NWP Terminal UI Library
#
# Shared TUI functions for install.sh and modify.sh
# Provides unified option selection interface with mode-specific behavior.
#
# Usage:
#   source "$SCRIPT_DIR/lib/tui.sh"
#   run_tui "install" "$site_name" "$environment" "$recipe_type" "$config_file"
#   run_tui "modify" "$site_name" "$environment" "$recipe_type" "$config_file"
#
# Modes:
#   install - New site installation (no env tabs, [+] for selections)
#   modify  - Modify existing site (env tabs, 5-state checkboxes)
################################################################################

# Prevent double-sourcing
[[ -n "${_TUI_SH_LOADED:-}" ]] && return 0
_TUI_SH_LOADED=1

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

################################################################################
# Environment Management
################################################################################

# Environment list
ENVIRONMENTS=("dev" "stage" "live" "prod")

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
# State Tracking
################################################################################

# Installed status tracking (what's currently on the site)
declare -A OPTION_INSTALLED

# Config status tracking (what cnwp.yml says should be installed)
declare -A OPTION_FROM_CONFIG

# Recipe status tracking (what recipe pre-selects)
declare -A OPTION_FROM_RECIPE

# Hierarchy depth tracking (0=parent, 1=child, 2=grandchild)
declare -A OPTION_DEPTH

# Visible options for current environment
VISIBLE_OPTIONS=()

################################################################################
# First Option Setup (Install Action / Install Status)
################################################################################

# Setup install action pseudo-option for install mode
setup_install_action_option() {
    local site_name="$1"
    local recipe="$2"

    OPTION_LABELS["install_action"]="Install: Ready to install ${site_name}"
    OPTION_DESCRIPTIONS["install_action"]="Begin installation of this site using the ${recipe} recipe. Press ENTER to start installation with the selected options."
    OPTION_ENVIRONMENTS["install_action"]="all"
    OPTION_CATEGORIES["install_action"]="system"
    OPTION_DEPENDENCIES["install_action"]=""
    OPTION_INPUTS["install_action"]=""
    OPTION_DOCS["install_action"]=""
    OPTION_SELECTED["install_action"]="y"
    OPTION_INSTALLED["install_action"]="n"
    OPTION_FROM_RECIPE["install_action"]="y"
}

# Setup install status pseudo-option for modify mode
# Args: $1 = site_name, $2 = config_file, $3 = environment
setup_install_status_option() {
    local site_name="$1"
    local config_file="$2"
    local environment="$3"

    # Get the site's configured environment from cnwp.yml
    local site_env
    if command -v get_site_field &>/dev/null; then
        site_env=$(get_site_field "$site_name" "environment" "$config_file" 2>/dev/null)
    fi
    site_env="${site_env:-development}"

    # Normalize environment names for comparison
    local normalized_site_env="$site_env"
    local normalized_tab_env="$environment"
    case "$site_env" in
        dev|development) normalized_site_env="dev" ;;
        stage|staging) normalized_site_env="stage" ;;
        live|production|prod) normalized_site_env="live" ;;
    esac
    case "$environment" in
        dev|development) normalized_tab_env="dev" ;;
        stage|staging) normalized_tab_env="stage" ;;
        live|production) normalized_tab_env="live" ;;
        prod) normalized_tab_env="live" ;;
    esac

    # Check if current tab matches site's environment
    if [ "$normalized_site_env" != "$normalized_tab_env" ]; then
        OPTION_LABELS["install_status"]="Install: N/A (site is ${site_env})"
        OPTION_DESCRIPTIONS["install_status"]="This site is configured for ${site_env} environment. Switch to the ${site_env^^} tab to see installation status, or create a separate site for ${environment}."
    elif command -v get_install_status_display &>/dev/null; then
        local install_status=$(get_install_status_display "$site_name" "$config_file" "$environment")
        OPTION_LABELS["install_status"]="Install: $install_status"
        OPTION_DESCRIPTIONS["install_status"]="Installation progress tracking for this site. Shows which installation steps have been completed and which remain. Press 's' or 'd' to see detailed step information."
    else
        OPTION_LABELS["install_status"]="Install: Status unavailable"
        OPTION_DESCRIPTIONS["install_status"]="Installation step tracking is not available."
    fi
    OPTION_ENVIRONMENTS["install_status"]="all"
    OPTION_CATEGORIES["install_status"]="system"
    OPTION_DEPENDENCIES["install_status"]=""
    OPTION_INPUTS["install_status"]=""
    OPTION_DOCS["install_status"]=""
    OPTION_SELECTED["install_status"]="n"
    OPTION_INSTALLED["install_status"]="n"
}

################################################################################
# Option List Building
################################################################################

build_env_option_list() {
    local environment="$1"
    local mode="${2:-modify}"
    local first_option="${3:-}"

    VISIBLE_OPTIONS=()
    OPTION_DEPTH=()  # Reset hierarchy depth

    # Add first option (install_action for install mode, install_status for modify mode)
    if [ -n "$first_option" ]; then
        VISIBLE_OPTIONS+=("$first_option")
        OPTION_DEPTH["$first_option"]=0
    fi

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

################################################################################
# Checkbox Display
################################################################################

# Get checkbox display for an option based on mode
get_checkbox_display() {
    local key="$1"
    local mode="$2"

    local selected="${OPTION_SELECTED[$key]:-n}"
    local installed="${OPTION_INSTALLED[$key]:-n}"
    local from_config="${OPTION_FROM_CONFIG[$key]:-n}"
    local from_recipe="${OPTION_FROM_RECIPE[$key]:-n}"

    if [[ "$mode" == "install" ]]; then
        # Install mode: simpler states
        if [[ "$selected" == "y" ]]; then
            echo "${YELLOW}[+]${NC}"  # Will install
        else
            echo "${DIM}[ ]${NC}"     # Won't install
        fi
    else
        # Modify mode: full 5-state model
        if [[ "$installed" == "y" ]]; then
            if [[ "$selected" == "y" ]]; then
                echo "${GREEN}[✓]${NC}"   # Installed, keep it
            else
                echo "${RED}[x]${NC}"     # Installed, will remove
            fi
        else
            if [[ "$selected" == "y" ]]; then
                echo "${YELLOW}[+]${NC}"  # Will install
            elif [[ "$from_config" == "y" ]]; then
                echo "${RED}[!]${NC}"     # Config mismatch
            else
                echo "${DIM}[ ]${NC}"     # Not installed, not wanted
            fi
        fi
    fi
}

################################################################################
# Screen Drawing
################################################################################

draw_tui_screen() {
    local mode="$1"
    local site_name="$2"
    local environment="$3"
    local current_row="$4"
    local config_file="${5:-cnwp.yml}"
    local total="${#VISIBLE_OPTIONS[@]}"

    clear_screen

    # Header
    if [[ "$mode" == "install" ]]; then
        printf "${BOLD}Install: ${CYAN}%s${NC}  |  " "$site_name"
        printf "Environment: ${GREEN}%s${NC}\n" "$(get_env_label "$environment")"
    else
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
    fi

    # Controls help line
    printf "${DIM}↑↓:Navigate  "
    [[ "$mode" == "modify" ]] && printf "←→:Environment  "
    printf "SPACE:Toggle  e:Edit  d:Docs  "
    [[ "$mode" == "modify" ]] && printf "s:Steps  "
    printf "a:All  n:None  ENTER:Apply  q:Cancel${NC}\n"
    printf "═══════════════════════════════════════════════════════════════════════════════\n"

    if [ "$total" -eq 0 ]; then
        printf "\n${DIM}  No options for this environment${NC}\n"
    else
        local row=0

        for key in "${VISIBLE_OPTIONS[@]}"; do
            local label="${OPTION_LABELS[$key]}"
            local inputs="${OPTION_INPUTS[$key]:-}"
            local depth="${OPTION_DEPTH[$key]:-0}"

            # Cursor
            local pointer="  "
            local is_current=false
            if [ $row -eq $current_row ]; then
                pointer="${CYAN}▸${NC} "
                is_current=true
            fi

            # Special handling for install_action/install_status pseudo-options
            if [[ "$key" == "install_action" || "$key" == "install_status" ]]; then
                local status_icon
                if [[ "$key" == "install_action" ]]; then
                    status_icon="${GREEN}[+]${NC}"
                else
                    local status_color="dim"
                    if command -v get_install_status_color &>/dev/null; then
                        status_color=$(get_install_status_color "$site_name" "$config_file" "$environment")
                    fi
                    case "$status_color" in
                        green) status_icon="${GREEN}[✓]${NC}" ;;
                        yellow) status_icon="${YELLOW}[!]${NC}" ;;
                        *) status_icon="${DIM}[○]${NC}" ;;
                    esac
                fi
                local hint=""
                if [ "$is_current" = true ]; then
                    if [[ "$key" == "install_action" ]]; then
                        hint="${DIM}ENTER:start${NC}"
                    else
                        hint="${DIM}d:details s:steps${NC}"
                    fi
                fi
                printf "%b%b ${BOLD}%s${NC} %b\n" "$pointer" "$status_icon" "$label" "$hint"
                ((row++))
                continue
            fi

            # Hierarchical indentation
            local indent=""
            if [ "$depth" -eq 1 ]; then
                indent="  └─ "
            elif [ "$depth" -eq 2 ]; then
                indent="      └─ "
            fi

            # Get checkbox
            local checkbox=$(get_checkbox_display "$key" "$mode")

            # Recipe indicator
            local recipe_hint=""
            if [[ "${OPTION_FROM_RECIPE[$key]:-n}" == "y" ]] && [[ "${OPTION_SELECTED[$key]:-n}" == "y" ]]; then
                recipe_hint="${DIM}(recipe)${NC} "
            fi

            # Adjust label length based on depth
            local max_label_len=$((24 - ${#indent}))
            [ $max_label_len -lt 10 ] && max_label_len=10

            # Build value display for options with inputs
            local value_display=""
            if [ -n "$inputs" ]; then
                local first_input="${inputs%%,*}"
                local ikey="${first_input%%:*}"
                local vkey="${key}_${ikey}"
                local val="${OPTION_VALUES[$vkey]:-}"
                if [ -n "$val" ]; then
                    value_display="${DIM}[${NC}${CYAN}${val:0:20}${NC}${DIM}]${NC}"
                else
                    value_display="${DIM}[          ]${NC}"
                fi
                if [ "$is_current" = true ]; then
                    value_display="${value_display} ${DIM}e:edit${NC}"
                fi
            fi

            printf "%b%s%b %-${max_label_len}s %b%b\n" "$pointer" "$indent" "$checkbox" "${label:0:$max_label_len}" "$recipe_hint" "$value_display"

            ((row++))
        done
    fi

    # Footer
    draw_tui_footer "$mode" "$environment"
}

draw_tui_footer() {
    local mode="$1"
    local environment="$2"

    local sel_count=0
    local installed_count=0
    local recipe_count=0

    for k in "${OPTION_LIST[@]}"; do
        [ "${OPTION_SELECTED[$k]:-n}" = "y" ] && ((sel_count++)) || true
        [ "${OPTION_INSTALLED[$k]:-n}" = "y" ] && ((installed_count++)) || true
        [ "${OPTION_FROM_RECIPE[$k]:-n}" = "y" ] && ((recipe_count++)) || true
    done

    printf "\n"
    printf "───────────────────────────────────────────────────────────────────────────────\n"

    if [[ "$mode" == "install" ]]; then
        printf "${YELLOW}[+]${NC}=will install  ${DIM}[ ]${NC}=skip\n"
        printf "Selected: %d" "$sel_count"
        [ "$recipe_count" -gt 0 ] && printf "  (from recipe: %d)" "$recipe_count"
        printf "  Environment: ${GREEN}%s${NC}\n" "$(get_env_label "$environment")"
    else
        printf "${GREEN}[✓]${NC}=installed  ${RED}[x]${NC}=remove  ${YELLOW}[+]${NC}=install  ${RED}[!]${NC}=config mismatch  ${DIM}[ ]${NC}=none\n"
        printf "Selected: %d  Installed: %d  Environment: ${GREEN}%s${NC}\n" "$sel_count" "$installed_count" "$(get_env_label "$environment")"
    fi
}

################################################################################
# Option Documentation Display
################################################################################

show_option_docs() {
    local opt_key="$1"

    printf "\n${BOLD}═══════════════════════════════════════════════════════════════${NC}\n"
    printf "${BOLD}${CYAN}%s${NC}\n" "${OPTION_LABELS[$opt_key]}"
    printf "${BOLD}═══════════════════════════════════════════════════════════════${NC}\n\n"

    # Show description
    printf "${BOLD}Description:${NC}\n"
    printf "%s\n\n" "${OPTION_DESCRIPTIONS[$opt_key]}"

    # Show environment
    printf "${BOLD}Environment:${NC} %s\n" "${OPTION_ENVIRONMENTS[$opt_key]}"

    # Show category
    printf "${BOLD}Category:${NC} %s\n" "${OPTION_CATEGORIES[$opt_key]}"

    # Show dependencies
    local deps="${OPTION_DEPENDENCIES[$opt_key]:-}"
    if [ -n "$deps" ]; then
        printf "${BOLD}Requires:${NC} %s\n" "$deps"
    fi

    # Show documentation links
    local docs="${OPTION_DOCS[$opt_key]:-}"
    if [ -n "$docs" ]; then
        printf "\n${BOLD}Documentation:${NC}\n"
        IFS=',' read -ra doc_urls <<< "$docs"
        for url in "${doc_urls[@]}"; do
            printf "  ${BLUE}→${NC} %s\n" "$url"
        done
    fi

    printf "\n${BOLD}═══════════════════════════════════════════════════════════════${NC}\n"
    printf "\nPress any key to continue..."
    read -rsn1
}

################################################################################
# Input Editing
################################################################################

edit_option_inputs() {
    local opt_key="$1"
    local inputs="${OPTION_INPUTS[$opt_key]:-}"

    [ -z "$inputs" ] && return

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
}

################################################################################
# Main TUI Loop
################################################################################

run_tui() {
    local mode="$1"
    local site_name="$2"
    local environment="$3"
    local recipe_type="$4"
    local config_file="${5:-cnwp.yml}"

    # Determine first option based on mode
    local first_option
    if [[ "$mode" == "install" ]]; then
        first_option="install_action"
    else
        first_option="install_status"
    fi

    # Build option list for current environment
    build_env_option_list "$environment" "$mode" "$first_option"

    # Setup first option
    if [[ "$mode" == "install" ]]; then
        setup_install_action_option "$site_name" "$recipe_type"
    else
        setup_install_status_option "$site_name" "$config_file" "$environment"
    fi

    local current_row=0
    local env_index=$(get_env_index "$environment")

    cursor_hide
    trap 'cursor_show' EXIT INT TERM

    while true; do
        local total="${#VISIBLE_OPTIONS[@]}"
        draw_tui_screen "$mode" "$site_name" "$environment" "$current_row" "$config_file"

        local key=$(read_key)

        case "$key" in
            UP|k|K)
                [ $current_row -gt 0 ] && ((current_row--)) || true
                ;;
            DOWN|j|J)
                [ "$total" -gt 0 ] && [ $current_row -lt $((total - 1)) ] && ((current_row++)) || true
                ;;
            LEFT)
                # Previous environment (modify mode only)
                if [[ "$mode" == "modify" ]]; then
                    env_index=$(( (env_index - 1 + 4) % 4 ))
                    environment="${ENVIRONMENTS[$env_index]}"
                    build_env_option_list "$environment" "$mode" "$first_option"
                    setup_install_status_option "$site_name" "$config_file" "$environment"
                    current_row=0
                fi
                ;;
            RIGHT)
                # Next environment (modify mode only)
                if [[ "$mode" == "modify" ]]; then
                    env_index=$(( (env_index + 1) % 4 ))
                    environment="${ENVIRONMENTS[$env_index]}"
                    build_env_option_list "$environment" "$mode" "$first_option"
                    setup_install_status_option "$site_name" "$config_file" "$environment"
                    current_row=0
                fi
                ;;
            e|E)
                # Edit value
                if [ "$total" -gt 0 ]; then
                    local opt_key="${VISIBLE_OPTIONS[$current_row]}"
                    edit_option_inputs "$opt_key"
                fi
                ;;
            SPACE)
                if [ "$total" -gt 0 ]; then
                    local opt_key="${VISIBLE_OPTIONS[$current_row]}"
                    # Skip toggle for pseudo-options
                    [[ "$opt_key" == "install_action" || "$opt_key" == "install_status" ]] && continue
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
                build_env_option_list "$environment" "$mode" "$first_option"
                ;;
            n|N)
                for k in "${OPTION_LIST[@]}"; do
                    OPTION_SELECTED["$k"]="n"
                done
                ;;
            d|D)
                # Show option details/documentation
                if [ "$total" -gt 0 ]; then
                    local opt_key="${VISIBLE_OPTIONS[$current_row]}"
                    cursor_show
                    clear_screen

                    # Special handling for install_status - show steps detail
                    if [[ "$opt_key" == "install_status" ]]; then
                        if command -v show_steps_detail &>/dev/null; then
                            show_steps_detail "$site_name" "$config_file" "$environment"
                        else
                            printf "\n${YELLOW}Installation step tracking not available${NC}\n"
                        fi
                        printf "\nPress any key to continue..."
                        read -rsn1
                        cursor_hide
                        continue
                    fi

                    show_option_docs "$opt_key"
                    cursor_hide
                fi
                ;;
            s|S)
                # Show installation steps details (modify mode)
                if [[ "$mode" == "modify" ]]; then
                    cursor_show
                    clear_screen
                    if command -v show_steps_detail &>/dev/null; then
                        show_steps_detail "$site_name" "$config_file" "$environment"
                    else
                        printf "\n${YELLOW}Installation step tracking not available${NC}\n"
                    fi
                    printf "\nPress any key to continue..."
                    read -rsn1
                    cursor_hide
                fi
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
# Recipe Loading
################################################################################

# Load option defaults from recipe definition
# Args: $1 = recipe name, $2 = config file
load_recipe_defaults() {
    local recipe="$1"
    local config_file="${2:-cnwp.yml}"

    # Reset recipe tracking
    OPTION_FROM_RECIPE=()

    [[ ! -f "$config_file" ]] && return 0

    # Parse recipe options section
    local recipe_options
    recipe_options=$(awk -v recipe="$recipe" '
        /^recipes:/ { in_recipes = 1; next }
        in_recipes && /^[a-zA-Z]/ && !/^  / { in_recipes = 0 }
        in_recipes && $0 ~ "^  " recipe ":" { in_recipe = 1; next }
        in_recipe && /^  [a-zA-Z]/ && !/^    / { in_recipe = 0 }
        in_recipe && /^    options:/ { in_options = 1; next }
        in_options && /^    [a-zA-Z]/ && !/^      / { in_options = 0 }
        in_options && /^      [a-zA-Z_]+:/ {
            line = $0
            sub(/^      /, "", line)
            key = line
            sub(/:.*/, "", key)
            val = line
            sub(/^[^:]+: */, "", val)
            # Ignore comments and blank values
            sub(/ *#.*$/, "", val)
            gsub(/^[ \t]+|[ \t]+$/, "", val)
            if (val != "" && val != "~" && val != "null") {
                print key "=" val
            }
        }
    ' "$config_file")

    # Apply recipe defaults
    while IFS='=' read -r key val; do
        [[ -z "$key" ]] && continue
        # Only apply if this option is defined
        if [[ -n "${OPTION_LABELS[$key]:-}" ]]; then
            if [[ "$val" == "y" ]]; then
                OPTION_SELECTED["$key"]="y"
                OPTION_FROM_RECIPE["$key"]="y"
            fi
            # Handle input values (non-boolean values)
            if [[ "$val" != "y" && "$val" != "n" && "$val" != "" ]]; then
                local inputs="${OPTION_INPUTS[$key]:-}"
                if [[ -n "$inputs" ]]; then
                    local first_input="${inputs%%,*}"
                    local ikey="${first_input%%:*}"
                    local vkey="${key}_${ikey}"
                    OPTION_VALUES["$vkey"]="$val"
                fi
            fi
        fi
    done <<< "$recipe_options"
}

# Combined loading function for TUI initialization
# Priority: 1. Existing config (modify only), 2. Recipe defaults, 3. Environment defaults
load_tui_defaults() {
    local mode="$1"
    local site_name="$2"
    local recipe="$3"
    local environment="$4"
    local config_file="${5:-cnwp.yml}"

    # Start with environment defaults
    if command -v apply_environment_defaults &>/dev/null; then
        apply_environment_defaults "$environment"
    fi

    # Layer recipe defaults on top
    if [[ -n "$recipe" ]]; then
        load_recipe_defaults "$recipe" "$config_file"
    fi

    # For modify mode, layer existing site config on top
    if [[ "$mode" == "modify" ]]; then
        if command -v load_existing_config &>/dev/null; then
            load_existing_config "$site_name" "$config_file" 2>/dev/null || true
        fi
    fi
}

# Export functions
export -f cursor_to cursor_hide cursor_show clear_screen read_key
export -f get_env_index get_env_label
export -f setup_install_action_option setup_install_status_option
export -f build_env_option_list get_checkbox_display
export -f draw_tui_screen draw_tui_footer show_option_docs edit_option_inputs
export -f run_tui load_recipe_defaults load_tui_defaults
