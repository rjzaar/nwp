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

# Source install steps tracking
if [ -f "$SCRIPT_DIR/lib/install-steps.sh" ]; then
    source "$SCRIPT_DIR/lib/install-steps.sh"
fi

# Source TUI library (provides terminal control, TUI functions)
if [ -f "$SCRIPT_DIR/lib/tui.sh" ]; then
    source "$SCRIPT_DIR/lib/tui.sh"
fi

CONFIG_FILE="${SCRIPT_DIR}/cnwp.yml"

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
# Orphaned Site Detection
################################################################################

# Find site directories that have .ddev but are not in cnwp.yml
find_orphaned_sites() {
    local config_file="$1"
    local script_dir="$2"

    # Get all directories with .ddev in the script directory
    local ddev_dirs=()
    while IFS= read -r ddev_path; do
        local site_dir=$(dirname "$ddev_path")
        local site_name=$(basename "$site_dir")
        ddev_dirs+=("$site_name:$site_dir")
    done < <(find "$script_dir" -maxdepth 2 -name ".ddev" -type d 2>/dev/null)

    # Get list of sites from cnwp.yml
    local yml_sites=()
    if [ -f "$config_file" ]; then
        while read -r site; do
            [ -n "$site" ] && yml_sites+=("$site")
        done < <(list_sites "$config_file")
    fi

    # Find orphaned sites (have .ddev but not in cnwp.yml)
    for entry in "${ddev_dirs[@]}"; do
        local name="${entry%%:*}"
        local dir="${entry#*:}"
        local found=false

        for yml_site in "${yml_sites[@]}"; do
            if [ "$name" = "$yml_site" ]; then
                found=true
                break
            fi
        done

        if [ "$found" = false ]; then
            echo "$name:$dir"
        fi
    done
}

# Detect recipe type from an orphaned site's structure
detect_recipe_from_site() {
    local directory="$1"

    # Check for various indicators
    if [ -f "$directory/.ddev/config.yaml" ]; then
        local project_type=$(grep "^type:" "$directory/.ddev/config.yaml" 2>/dev/null | awk '{print $2}')
        case "$project_type" in
            drupal*)
                # Try to determine specific Drupal recipe
                if [ -f "$directory/web/profiles/contrib/social" ] || [ -d "$directory/html/profiles/contrib/social" ]; then
                    echo "os"
                elif [ -d "$directory/html" ]; then
                    echo "nwp"
                else
                    echo "d"
                fi
                ;;
            wordpress) echo "wp" ;;
            php) echo "php" ;;
            *) echo "?" ;;
        esac
    else
        echo "?"
    fi
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

    # Add sites from cnwp.yml
    while read -r site; do
        [ -z "$site" ] && continue
        SITE_NAMES+=("$site")
        local recipe=$(get_site_field "$site" "recipe" "$config_file")
        local directory=$(get_site_field "$site" "directory" "$config_file")
        local environment=$(get_site_field "$site" "environment" "$config_file")
        local exists="N"
        [ -d "$directory" ] && exists="Y"
        # Last field indicates source: "yml" = from cnwp.yml, "orphan" = orphaned
        SITE_DATA+=("${recipe:-?}|${environment:-dev}|${exists}|${directory:-}|yml")
    done < <(list_sites "$config_file")

    # Add orphaned sites (have .ddev but not in cnwp.yml)
    while IFS=':' read -r name dir; do
        [ -z "$name" ] && continue
        SITE_NAMES+=("$name")
        local recipe=$(detect_recipe_from_site "$dir")
        # Orphaned sites have no environment in yml, mark as "orphan"
        SITE_DATA+=("${recipe:-?}|orphan|Y|${dir}|orphan")
    done < <(find_orphaned_sites "$config_file" "$SCRIPT_DIR")
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
    local has_orphans=false
    for site in "${SITE_NAMES[@]}"; do
        IFS='|' read -r recipe env exists dir source <<< "${SITE_DATA[$row]}"

        local exists_color="${RED}No${NC}"
        [ "$exists" = "Y" ] && exists_color="${GREEN}Yes${NC}"

        if [ $row -eq $current_row ]; then
            printf "${BOLD}${CYAN}▸${NC} "
        else
            printf "  "
        fi

        # Display orphaned sites with distinct styling
        if [ "$source" = "orphan" ]; then
            has_orphans=true
            printf "${YELLOW}%-20s${NC} %-12s ${DIM}(orphan)${NC}     " "$site" "$recipe"
        else
            printf "%-20s %-12s %-12s " "$site" "$recipe" "$env"
        fi
        printf "%b" "$exists_color"
        printf "     %s\n" "$dir"

        ((row++))
    done

    printf "\n"
    printf "───────────────────────────────────────────────────────────────────────────────\n"
    if [ "$has_orphans" = true ]; then
        printf "Select a site to modify. ${YELLOW}Yellow${NC} sites are not in cnwp.yml.\n"
    else
        printf "Select a site to modify its options.\n"
    fi
}

select_site_interactive() {
    local config_file="$1"

    build_site_list "$config_file"

    if [ ${#SITE_NAMES[@]} -eq 0 ]; then
        print_error "No sites found in cnwp.yml or as orphaned directories"
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
# Site Summary Display
################################################################################

show_site_summary() {
    local site_name="$1"
    local directory="$2"
    local recipe_type="$3"
    local config_file="$4"

    printf "\n${BOLD}Site: ${CYAN}%s${NC}\n" "$site_name"
    printf "Directory: %s\n" "$directory"
    printf "Recipe: %s\n" "$recipe_type"

    # Show purpose if set
    local purpose=$(awk -v site="$site_name" '
        /^sites:/ { in_sites = 1; next }
        in_sites && /^[a-zA-Z]/ && !/^  / { in_sites = 0 }
        in_sites && $0 ~ "^  " site ":" { in_site = 1; next }
        in_site && /^  [a-zA-Z]/ && !/^    / { in_site = 0 }
        in_site && /^    purpose:/ { sub(/^    purpose: */, ""); gsub(/["'"'"']/, ""); print }
    ' "$config_file")
    [ -n "$purpose" ] && printf "Purpose: %s\n" "$purpose"

    # Show live deployment info
    local live_enabled=$(awk -v site="$site_name" '
        /^sites:/ { in_sites = 1; next }
        in_sites && /^[a-zA-Z]/ && !/^  / { in_sites = 0 }
        in_sites && $0 ~ "^  " site ":" { in_site = 1; next }
        in_site && /^  [a-zA-Z]/ && !/^    / { in_site = 0 }
        in_site && /^    live:/ { in_live = 1; next }
        in_live && /^    [a-zA-Z]/ && !/^      / { in_live = 0 }
        in_live && /^      enabled:/ { sub(/^      enabled: */, ""); print }
    ' "$config_file")

    if [ "$live_enabled" = "true" ]; then
        local live_domain=$(awk -v site="$site_name" '
            /^sites:/ { in_sites = 1; next }
            in_sites && /^[a-zA-Z]/ && !/^  / { in_sites = 0 }
            in_sites && $0 ~ "^  " site ":" { in_site = 1; next }
            in_site && /^  [a-zA-Z]/ && !/^    / { in_site = 0 }
            in_site && /^    live:/ { in_live = 1; next }
            in_live && /^    [a-zA-Z]/ && !/^      / { in_live = 0 }
            in_live && /^      domain:/ { sub(/^      domain: */, ""); gsub(/["'"'"']/, ""); print }
        ' "$config_file")
        local live_ip=$(awk -v site="$site_name" '
            /^sites:/ { in_sites = 1; next }
            in_sites && /^[a-zA-Z]/ && !/^  / { in_sites = 0 }
            in_sites && $0 ~ "^  " site ":" { in_site = 1; next }
            in_site && /^  [a-zA-Z]/ && !/^    / { in_site = 0 }
            in_site && /^    live:/ { in_live = 1; next }
            in_live && /^    [a-zA-Z]/ && !/^      / { in_live = 0 }
            in_live && /^      server_ip:/ { sub(/^      server_ip: */, ""); print }
        ' "$config_file")
        printf "${GREEN}Live:${NC} %s (%s)\n" "$live_domain" "$live_ip"
    fi
    printf "\n"

    # Infrastructure status
    printf "${BOLD}Infrastructure Status:${NC}\n"

    # Check directory exists
    if [ -d "$directory" ]; then
        printf "  ${GREEN}✓${NC} Directory exists\n"

        # Check for code (composer.json or index.php)
        if [ -f "$directory/composer.json" ] || [ -f "$directory/index.php" ]; then
            printf "  ${GREEN}✓${NC} Code present\n"
        else
            printf "  ${RED}✗${NC} No code found\n"
        fi

        # Check DDEV configured
        if [ -d "$directory/.ddev" ]; then
            printf "  ${GREEN}✓${NC} DDEV configured\n"

            # Check DDEV running
            if (cd "$directory" && ddev describe &>/dev/null 2>&1); then
                printf "  ${GREEN}✓${NC} DDEV running\n"

                # Get additional info from DDEV
                local ddev_info=$(cd "$directory" && ddev describe -j 2>/dev/null)
                if [ -n "$ddev_info" ]; then
                    local php_ver=$(echo "$ddev_info" | grep -o '"php_version":"[^"]*"' | head -1 | cut -d'"' -f4)
                    local db_type=$(echo "$ddev_info" | grep -o '"database_type":"[^"]*"' | head -1 | cut -d'"' -f4)
                    local db_ver=$(echo "$ddev_info" | grep -o '"database_version":"[^"]*"' | head -1 | cut -d'"' -f4)
                    [ -n "$php_ver" ] && printf "    PHP: %s\n" "$php_ver"
                    [ -n "$db_type" ] && [ -n "$db_ver" ] && printf "    Database: %s %s\n" "$db_type" "$db_ver"
                fi

                # Check Drupal installed (bootstrap works)
                local drupal_status=$(cd "$directory" && ddev drush status --field=bootstrap 2>/dev/null | grep -v "^PHP\|^Deprecated" | tail -1)
                if [[ "$drupal_status" == *"Successful"* ]]; then
                    printf "  ${GREEN}✓${NC} Drupal installed\n"
                    # Get Drupal version
                    local drupal_ver=$(cd "$directory" && ddev drush status --field=drupal-version 2>/dev/null | grep -v "^PHP\|^Deprecated" | tail -1)
                    [ -n "$drupal_ver" ] && printf "    Drupal: %s\n" "$drupal_ver"
                else
                    printf "  ${YELLOW}○${NC} Drupal not bootstrapped\n"
                fi
            else
                printf "  ${YELLOW}○${NC} DDEV not running\n"
            fi
        else
            printf "  ${DIM}○${NC} DDEV not configured\n"
        fi
    else
        printf "  ${RED}✗${NC} Directory missing\n"
    fi
    printf "\n"

    # Show installation progress
    if command -v get_install_status_display &>/dev/null; then
        local env_for_steps="dev"
        # Determine environment for step count
        local site_env=$(awk -v site="$site_name" '
            /^sites:/ { in_sites = 1; next }
            in_sites && /^[a-zA-Z]/ && !/^  / { in_sites = 0 }
            in_sites && $0 ~ "^  " site ":" { in_site = 1; next }
            in_site && /^  [a-zA-Z]/ && !/^    / { in_site = 0 }
            in_site && /^    environment:/ { sub(/^    environment: */, ""); gsub(/["'"'"']/, ""); print }
        ' "$config_file")
        case "$site_env" in
            staging) env_for_steps="stage" ;;
            production) env_for_steps="prod" ;;
            live) env_for_steps="live" ;;
            *) env_for_steps="dev" ;;
        esac

        local install_status=$(get_install_status_display "$site_name" "$config_file" "$env_for_steps")
        local status_color=$(get_install_status_color "$site_name" "$config_file" "$env_for_steps")
        local status_icon
        case "$status_color" in
            green) status_icon="${GREEN}✓${NC}" ;;
            yellow) status_icon="${YELLOW}!${NC}" ;;
            *) status_icon="${DIM}○${NC}" ;;
        esac
        printf "${BOLD}Installation Status:${NC} %b %s\n\n" "$status_icon" "$install_status"
    fi

    # Show installed_modules from cnwp.yml
    local installed_modules=$(awk -v site="$site_name" '
        /^sites:/ { in_sites = 1; next }
        in_sites && /^[a-zA-Z]/ && !/^  / { in_sites = 0 }
        in_sites && $0 ~ "^  " site ":" { in_site = 1; next }
        in_site && /^  [a-zA-Z]/ && !/^    / { in_site = 0 }
        in_site && /^    installed_modules:/ { in_mods = 1; next }
        in_mods && /^      - / {
            sub(/^      - /, "")
            gsub(/["'"'"']/, "")
            print
        }
        in_mods && /^    [a-zA-Z]/ && !/^      / { in_mods = 0 }
    ' "$config_file")

    if [ -n "$installed_modules" ]; then
        printf "${BOLD}Installed Modules (from cnwp.yml):${NC}\n"
        while read -r mod; do
            printf "  - %s\n" "$mod"
        done <<< "$installed_modules"
        printf "\n"
    fi

    # Show options from cnwp.yml
    local options_list=$(awk -v site="$site_name" '
        /^sites:/ { in_sites = 1; next }
        in_sites && /^[a-zA-Z]/ && !/^  / { in_sites = 0 }
        in_sites && $0 ~ "^  " site ":" { in_site = 1; next }
        in_site && /^  [a-zA-Z]/ && !/^    / { in_site = 0 }
        in_site && /^    options:/ { in_options = 1; next }
        in_options && /^      [a-zA-Z_]+:/ {
            sub(/^      /, "")
            print
        }
        in_options && /^    [a-zA-Z]/ && !/^      / { in_options = 0 }
    ' "$config_file")

    if [ -n "$options_list" ]; then
        printf "${BOLD}Options (from cnwp.yml):${NC}\n"
        while read -r opt; do
            printf "  %s\n" "$opt"
        done <<< "$options_list"
        printf "\n"
    fi

    # Show currently installed (from site detection)
    local installed_items=""
    for key in "${!OPTION_INSTALLED[@]}"; do
        if [ "${OPTION_INSTALLED[$key]}" = "y" ]; then
            local label="${OPTION_LABELS[$key]:-$key}"
            installed_items="${installed_items}  - ${label}\n"
        fi
    done

    if [ -n "$installed_items" ]; then
        printf "${BOLD}Currently Installed (detected):${NC}\n"
        printf "%b" "$installed_items"
        printf "\n"
    elif [ -d "$directory/.ddev" ]; then
        # Check if DDEV is running
        if ! (cd "$directory" && ddev describe &>/dev/null); then
            printf "${DIM}(Site not running - start with 'ddev start' to detect installed options)${NC}\n\n"
        else
            printf "${DIM}(No options currently installed)${NC}\n\n"
        fi
    fi
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

    # Show summary before TUI
    show_site_summary "$site_name" "$directory" "$recipe_type" "$CONFIG_FILE"
    printf "Press any key to continue to options menu..."
    read -rsn1

    # Use shared TUI from lib/tui.sh
    if command -v run_tui &>/dev/null; then
        run_tui "modify" "$site_name" "$environment" "$recipe_type" "$CONFIG_FILE"
    else
        print_error "TUI library not available"
        return 1
    fi
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
  -i, --info         Show site info only (no TUI)
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
    local info_only=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) show_help; exit 0 ;;
            -l|--list) list_only=true; shift ;;
            -i|--info) info_only=true; shift ;;
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
        print_header "Sites"
        printf "\n  %-20s %-12s %-12s %s\n" "SITE" "RECIPE" "ENVIRONMENT" "DIRECTORY"
        printf "  %-20s %-12s %-12s %s\n" "--------------------" "------------" "------------" "---------"

        # Sites from cnwp.yml
        while read -r site; do
            [ -z "$site" ] && continue
            local recipe=$(get_site_field "$site" "recipe" "$CONFIG_FILE")
            local env=$(get_site_field "$site" "environment" "$CONFIG_FILE")
            local dir=$(get_site_field "$site" "directory" "$CONFIG_FILE")
            printf "  %-20s %-12s %-12s %s\n" "$site" "${recipe:-?}" "${env:-dev}" "$dir"
        done < <(list_sites "$CONFIG_FILE")

        # Orphaned sites
        local orphaned=$(find_orphaned_sites "$CONFIG_FILE" "$SCRIPT_DIR")
        if [ -n "$orphaned" ]; then
            printf "\n  ${YELLOW}Orphaned sites (not in cnwp.yml):${NC}\n"
            while IFS=':' read -r name dir; do
                [ -z "$name" ] && continue
                local recipe=$(detect_recipe_from_site "$dir")
                printf "  ${YELLOW}%-20s${NC} %-12s %-12s %s\n" "$name" "${recipe:-?}" "(orphan)" "$dir"
            done <<< "$orphaned"
        fi
        echo ""
        exit 0
    fi

    # Interactive site selection if none specified
    if [ -z "$site_name" ]; then
        site_name=$(select_site_interactive "$CONFIG_FILE") || exit 0
    fi

    # Get site info - first try cnwp.yml, then check if orphaned
    local directory=$(get_site_field "$site_name" "directory" "$CONFIG_FILE")
    local recipe=$(get_site_field "$site_name" "recipe" "$CONFIG_FILE")
    local environment=$(get_site_field "$site_name" "environment" "$CONFIG_FILE")
    local is_orphan=false

    if [ -z "$directory" ]; then
        # Check if it's an orphaned site
        local orphan_dir="$SCRIPT_DIR/$site_name"
        if [ -d "$orphan_dir/.ddev" ]; then
            directory="$orphan_dir"
            recipe=$(detect_recipe_from_site "$directory")
            environment="development"
            is_orphan=true
            print_warning "Site '$site_name' is orphaned (not in cnwp.yml)"
        else
            print_error "Site '$site_name' not found in cnwp.yml or as orphaned directory"
            exit 1
        fi
    fi

    # Map environment
    local env_short="dev"
    case "$environment" in
        staging) env_short="stage" ;;
        production) env_short="prod" ;;
        live) env_short="live" ;;
    esac

    # Info-only mode: just show summary and exit
    if [ "$info_only" = true ]; then
        # Load options for the recipe type
        case "$recipe" in
            drupal|d|os|nwp|dm|"") define_drupal_options ;;
            moodle|m) define_moodle_options ;;
            gitlab) define_gitlab_options ;;
            *) define_drupal_options ;;
        esac

        # Check what's currently installed
        if [ -n "$directory" ] && [ -d "$directory" ]; then
            check_installed_status "$directory" "$recipe"
        fi

        # Show the summary
        show_site_summary "$site_name" "$directory" "$recipe" "$CONFIG_FILE"
        exit 0
    fi

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
