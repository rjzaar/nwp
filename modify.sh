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
    elif [[ $key == "<" || $key == "," ]]; then
        echo "PREV_ENV"
    elif [[ $key == ">" || $key == "." ]]; then
        echo "NEXT_ENV"
    else
        echo "$key"
    fi
}

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
    printf "<"
    for env in "${ENVIRONMENTS[@]}"; do
        if [[ "$env" == "$environment" ]]; then
            printf " ${GREEN}${BOLD}[%s]${NC} " "${env^^}"
        else
            printf " ${DIM}%s${NC} " "${env^^}"
        fi
    done
    printf ">\n"

    printf "${DIM}↑↓:Navigate  SPACE:Toggle  </>:Environment  e:Edit  a:All  n:None  ENTER:Apply  q:Cancel${NC}\n"
    printf "═══════════════════════════════════════════════════════════════════════════════\n"

    if [ "$total" -eq 0 ]; then
        printf "\n${DIM}  No options for this environment${NC}\n"
    else
        local row=0

        for key in "${VISIBLE_OPTIONS[@]}"; do
            local opt_env="${OPTION_ENVIRONMENTS[$key]}"
            local label="${OPTION_LABELS[$key]}"
            local selected="${OPTION_SELECTED[$key]:-n}"
            local inputs="${OPTION_INPUTS[$key]:-}"
            local deps="${OPTION_DEPENDENCIES[$key]:-}"

            # Checkbox
            local checkbox="${DIM}[ ]${NC}"
            [ "$selected" = "y" ] && checkbox="${GREEN}[✓]${NC}"

            # Cursor
            local pointer="  "
            if [ $row -eq $current_row ]; then
                pointer="${CYAN}▸${NC} "
            fi

            # Indicators
            local ind=""
            [ -n "$inputs" ] && ind="${YELLOW}*${NC}"
            if [ -n "$deps" ]; then
                local missing=$(check_dependencies "$key" 2>/dev/null) || true
                [ -n "$missing" ] && ind="${ind}${RED}!${NC}"
            fi

            printf "%b%b %-32s %b\n" "$pointer" "$checkbox" "${label:0:32}" "$ind"

            ((row++))
        done
    fi

    # Footer
    local sel_count=0
    for k in "${OPTION_LIST[@]}"; do
        [ "${OPTION_SELECTED[$k]:-n}" = "y" ] && ((sel_count++)) || true
    done

    printf "\n"
    printf "───────────────────────────────────────────────────────────────────────────────\n"
    printf "Selected: %d/%d  ${YELLOW}*${NC}=input  ${RED}!${NC}=missing dep  Environment: ${GREEN}%s${NC}\n" "$sel_count" "${#OPTION_LIST[@]}" "$(get_env_label "$environment")"
}

build_env_option_list() {
    local environment="$1"

    VISIBLE_OPTIONS=()

    for key in "${OPTION_LIST[@]}"; do
        local opt_env="${OPTION_ENVIRONMENTS[$key]}"
        # Show options for this environment or 'all'
        if [[ "$opt_env" == "$environment" || "$opt_env" == "all" ]]; then
            VISIBLE_OPTIONS+=("$key")
        fi
    done
}

run_options_tui() {
    local site_name="$1"
    local environment="$2"
    local recipe_type="$3"

    # Load options
    case "$recipe_type" in
        drupal|d|os|nwp|dm|"") define_drupal_options ;;
        moodle|m) define_moodle_options ;;
        gitlab) define_gitlab_options ;;
        *) define_drupal_options ;;
    esac

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
            PREV_ENV|LEFT)
                # Previous environment
                env_index=$(( (env_index - 1 + 4) % 4 ))
                environment="${ENVIRONMENTS[$env_index]}"
                build_env_option_list "$environment"
                current_row=0
                ;;
            NEXT_ENV|RIGHT)
                # Next environment
                env_index=$(( (env_index + 1) % 4 ))
                environment="${ENVIRONMENTS[$env_index]}"
                build_env_option_list "$environment"
                current_row=0
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
            e|E)
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

    # Save to cnwp.yml
    if command -v yaml_site_exists &>/dev/null && yaml_site_exists "$site_name" "$CONFIG_FILE" 2>/dev/null; then
        local has_options=false
        for key in "${OPTION_LIST[@]}"; do
            [ "${OPTION_SELECTED[$key]:-n}" = "y" ] && { has_options=true; break; }
        done

        if [ "$has_options" = true ]; then
            print_info "Saving options to cnwp.yml..."
            local options_yaml=$(generate_options_yaml "      ")

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
            print_status "OK" "Options saved"
        fi
    fi

    # Apply options based on recipe type
    cd "$directory"

    print_header "Applying Options"

    local applied=0

    case "$recipe_type" in
        drupal|d|os|nwp|dm|"")
            # Check if DDEV is available
            if [ -d ".ddev" ]; then
                if ! ddev describe &>/dev/null; then
                    print_info "Starting DDEV..."
                    ddev start || true
                fi

                # Dev modules
                if [ "${OPTION_SELECTED[dev_modules]:-n}" = "y" ]; then
                    print_info "Installing dev modules..."
                    ddev drush pm:enable devel -y 2>/dev/null && ((applied++)) || true
                fi

                # XDebug
                if [ "${OPTION_SELECTED[xdebug]:-n}" = "y" ]; then
                    print_info "Enabling XDebug..."
                    ddev xdebug on 2>/dev/null && ((applied++)) || true
                elif [ "${OPTION_SELECTED[xdebug]:-n}" = "n" ]; then
                    ddev xdebug off 2>/dev/null || true
                fi

                # Redis
                if [ "${OPTION_SELECTED[redis]:-n}" = "y" ]; then
                    print_info "Adding Redis..."
                    ddev get ddev/ddev-redis 2>/dev/null && ((applied++)) || true
                fi

                # Solr
                if [ "${OPTION_SELECTED[solr]:-n}" = "y" ]; then
                    print_info "Adding Solr..."
                    ddev get ddev/ddev-solr 2>/dev/null && ((applied++)) || true
                fi

                if [ $applied -gt 0 ]; then
                    print_info "Restarting DDEV..."
                    ddev restart 2>/dev/null || true
                fi
            fi
            ;;
    esac

    print_status "OK" "Applied $applied options"

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
    if run_options_tui "$site_name" "$env_short" "$recipe"; then
        echo ""
        apply_site_options "$site_name" "$directory" "$recipe"
        echo ""
        print_status "OK" "Modification complete for '$site_name'"
    else
        print_info "Modification cancelled"
    fi
}

main "$@"
