#!/bin/bash
set -euo pipefail

################################################################################
# NWP Site Modification Script
#
# Modifies options for existing sites listed in cnwp.yml
# Usage: ./modify.sh [site_name] [options]
#
# Arguments:
#   site_name                    - Name of site from cnwp.yml (optional, will prompt)
#
# Examples:
#   ./modify.sh                  - List all sites and select one
#   ./modify.sh nwp5             - Modify options for 'nwp5' site
#   ./modify.sh nwp5 --apply     - Apply options without interactive mode
#
# Options:
#   -l, --list                   - List all sites in cnwp.yml
#   -a, --apply                  - Apply current options without interactive mode
#   -h, --help                   - Show this help message
################################################################################

# Get script directory
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

################################################################################
# Site Listing Functions
################################################################################

# List all sites from cnwp.yml
list_sites() {
    local config_file="${1:-cnwp.yml}"

    if [ ! -f "$config_file" ]; then
        print_error "Config file not found: $config_file"
        return 1
    fi

    # Extract site names and info
    awk '
        /^sites:/ { in_sites = 1; next }
        in_sites && /^[a-zA-Z]/ && !/^  / { in_sites = 0 }
        in_sites && /^  [a-zA-Z0-9_-]+:/ {
            name = $0
            sub(/^  /, "", name)
            sub(/:.*/, "", name)
            sites[++count] = name
        }
        in_sites && /^    directory:/ {
            dir = $0
            sub(/^    directory: */, "", dir)
            dirs[count] = dir
        }
        in_sites && /^    recipe:/ {
            rec = $0
            sub(/^    recipe: */, "", rec)
            recipes[count] = rec
        }
        in_sites && /^    environment:/ {
            env = $0
            sub(/^    environment: */, "", env)
            envs[count] = env
        }
        END {
            for (i = 1; i <= count; i++) {
                printf "%s|%s|%s|%s\n", sites[i], recipes[i], envs[i], dirs[i]
            }
        }
    ' "$config_file"
}

# Display sites in a formatted table
display_sites() {
    local config_file="${1:-cnwp.yml}"

    print_header "Sites in cnwp.yml"
    echo ""
    echo -e "  ${BOLD}#    Site Name            Recipe          Environment     Directory${NC}"
    echo "  ────────────────────────────────────────────────────────────────────────────────"

    local idx=1
    while IFS='|' read -r name recipe env dir; do
        if [ -n "$name" ]; then
            # Check if directory exists
            local status="${GREEN}●${NC}"
            if [ ! -d "$dir" ]; then
                status="${RED}○${NC}"
            fi
            printf "  [%d]  %-20s %-15s %-15s " "$idx" "$name" "$recipe" "$env"
            echo -e "$status $dir"
            ((idx++))
        fi
    done < <(list_sites "$config_file")

    echo ""
    echo -e "  ${GREEN}●${NC} = directory exists  ${RED}○${NC} = directory not found"
    echo ""
}

# Get site details by name
get_site_info() {
    local site_name="$1"
    local config_file="${2:-cnwp.yml}"

    awk -v site="$site_name" '
        /^sites:/ { in_sites = 1; next }
        in_sites && /^[a-zA-Z]/ && !/^  / { in_sites = 0 }
        in_sites && $0 ~ "^  " site ":" { in_site = 1; next }
        in_site && /^  [a-zA-Z0-9_-]+:/ && $0 !~ "^    " { in_site = 0 }
        in_site && /^    directory:/ {
            dir = $0; sub(/^    directory: */, "", dir); print "DIRECTORY=" dir
        }
        in_site && /^    recipe:/ {
            rec = $0; sub(/^    recipe: */, "", rec); print "RECIPE=" rec
        }
        in_site && /^    environment:/ {
            env = $0; sub(/^    environment: */, "", env); print "ENVIRONMENT=" env
        }
        in_site && /^    purpose:/ {
            pur = $0; sub(/^    purpose: */, "", pur); print "PURPOSE=" pur
        }
    ' "$config_file"
}

# Get site name by index
get_site_by_index() {
    local index="$1"
    local config_file="${2:-cnwp.yml}"

    list_sites "$config_file" | sed -n "${index}p" | cut -d'|' -f1
}

# Count total sites
count_sites() {
    local config_file="${1:-cnwp.yml}"
    list_sites "$config_file" | wc -l
}

################################################################################
# Option Application for Existing Sites
################################################################################

# Apply options to an existing Drupal site
apply_options_to_drupal_site() {
    local site_dir="$1"

    if [ ! -d "$site_dir" ]; then
        print_error "Site directory not found: $site_dir"
        return 1
    fi

    cd "$site_dir"

    if [[ ${#OPTION_LIST[@]} -eq 0 ]]; then
        print_info "No options defined"
        return 0
    fi

    local applied=0

    print_header "Applying Options to Existing Site"

    # Check if DDEV is running
    if ! ddev describe &>/dev/null; then
        print_info "Starting DDEV..."
        ddev start || {
            print_error "Failed to start DDEV"
            return 1
        }
    fi

    # Development Modules
    if [[ "${OPTION_SELECTED[dev_modules]:-}" == "y" ]]; then
        print_info "Installing development modules..."
        if ddev drush pm:enable devel kint webprofiler -y 2>/dev/null; then
            print_status "OK" "Development modules installed"
            ((applied++))
        else
            # Try installing first
            ddev composer require drupal/devel drupal/kint 2>/dev/null || true
            ddev drush pm:enable devel -y 2>/dev/null && ((applied++)) || print_warning "Some dev modules may not be available"
        fi
    elif [[ "${OPTION_SELECTED[dev_modules]:-}" == "n" ]]; then
        # Check if modules are enabled and disable them
        if ddev drush pm:list --status=enabled 2>/dev/null | grep -q "devel"; then
            print_info "Disabling development modules..."
            ddev drush pm:uninstall devel kint webprofiler -y 2>/dev/null || true
            print_status "OK" "Development modules disabled"
        fi
    fi

    # XDebug
    if [[ "${OPTION_SELECTED[xdebug]:-}" == "y" ]]; then
        print_info "Enabling XDebug..."
        if ddev xdebug on 2>/dev/null; then
            print_status "OK" "XDebug enabled"
            ((applied++))
        else
            print_warning "XDebug may need manual configuration"
        fi
    elif [[ "${OPTION_SELECTED[xdebug]:-}" == "n" ]]; then
        print_info "Disabling XDebug..."
        ddev xdebug off 2>/dev/null || true
        print_status "OK" "XDebug disabled"
    fi

    # Stage File Proxy
    if [[ "${OPTION_SELECTED[stage_file_proxy]:-}" == "y" ]]; then
        print_info "Installing Stage File Proxy..."
        if ddev composer require drupal/stage_file_proxy 2>/dev/null && ddev drush pm:enable stage_file_proxy -y 2>/dev/null; then
            print_status "OK" "Stage File Proxy installed"
            ((applied++))
        else
            print_warning "Stage File Proxy installation may need manual steps"
        fi
    fi

    # Config Split
    if [[ "${OPTION_SELECTED[config_split]:-}" == "y" ]]; then
        print_info "Installing Config Split..."
        if ddev composer require drupal/config_split 2>/dev/null && ddev drush pm:enable config_split -y 2>/dev/null; then
            print_status "OK" "Config Split installed"
            ((applied++))
        else
            print_warning "Config Split installation may need manual steps"
        fi
    fi

    # Security Modules
    if [[ "${OPTION_SELECTED[security_modules]:-}" == "y" ]]; then
        print_info "Installing security modules..."
        local security_mods="seckit honeypot login_security flood_control"
        for mod in $security_mods; do
            ddev composer require "drupal/$mod" 2>/dev/null || true
            ddev drush pm:enable "$mod" -y 2>/dev/null || true
        done
        print_status "OK" "Security modules installed"
        ((applied++))
    fi

    # Redis
    if [[ "${OPTION_SELECTED[redis]:-}" == "y" ]]; then
        print_info "Enabling Redis..."
        if ddev get ddev/ddev-redis 2>/dev/null; then
            ddev restart 2>/dev/null
            ddev composer require drupal/redis 2>/dev/null || true
            ddev drush pm:enable redis -y 2>/dev/null || true
            print_status "OK" "Redis enabled (configure settings.php manually)"
            ((applied++))
        else
            print_warning "Redis installation may need manual steps"
        fi
    fi

    # Solr
    if [[ "${OPTION_SELECTED[solr]:-}" == "y" ]]; then
        print_info "Enabling Solr..."
        if ddev get ddev/ddev-solr 2>/dev/null; then
            local core="${OPTION_VALUES[solr_core]:-drupal}"
            ddev restart 2>/dev/null
            ddev solr create -c "$core" 2>/dev/null || true
            ddev composer require drupal/search_api_solr 2>/dev/null || true
            print_status "OK" "Solr enabled with core: $core"
            ((applied++))
        else
            print_warning "Solr installation may need manual steps"
        fi
    fi

    if [[ $applied -gt 0 ]]; then
        print_info "Clearing cache..."
        ddev drush cr 2>/dev/null || true
        print_status "OK" "Applied $applied options"
    else
        print_info "No changes applied"
    fi

    return 0
}

# Apply options to an existing Moodle site
apply_options_to_moodle_site() {
    local site_dir="$1"

    if [ ! -d "$site_dir" ]; then
        print_error "Site directory not found: $site_dir"
        return 1
    fi

    cd "$site_dir"

    if [[ ${#OPTION_LIST[@]} -eq 0 ]]; then
        print_info "No options defined"
        return 0
    fi

    local applied=0

    print_header "Applying Options to Existing Moodle Site"

    # Check if DDEV is running
    if ! ddev describe &>/dev/null; then
        print_info "Starting DDEV..."
        ddev start || {
            print_error "Failed to start DDEV"
            return 1
        }
    fi

    # Debug Mode
    if [[ "${OPTION_SELECTED[debug_mode]:-}" == "y" ]]; then
        print_info "Enabling debug mode..."
        if [ -f "config.php" ] && ! grep -q "Debug settings (added by" config.php; then
            cat >> config.php << 'MOODLE_DEBUG'

// Debug settings (added by modify script)
@error_reporting(E_ALL | E_STRICT);
@ini_set('display_errors', '1');
$CFG->debug = (E_ALL | E_STRICT);
$CFG->debugdisplay = 1;
MOODLE_DEBUG
            print_status "OK" "Debug mode enabled"
            ((applied++))
        else
            print_info "Debug mode already configured"
        fi
    fi

    # Redis
    if [[ "${OPTION_SELECTED[redis]:-}" == "y" ]]; then
        print_info "Configuring Redis..."
        if ddev get ddev/ddev-redis 2>/dev/null; then
            ddev restart 2>/dev/null
            print_status "OK" "Redis container added (configure config.php manually)"
            ((applied++))
        else
            print_warning "Redis installation may need manual steps"
        fi
    fi

    if [[ $applied -gt 0 ]]; then
        print_status "OK" "Applied $applied options"
    else
        print_info "No changes applied"
    fi

    return 0
}

################################################################################
# Main Modification Flow
################################################################################

# Run modification for a site
modify_site() {
    local site_name="$1"
    local config_file="${2:-cnwp.yml}"
    local apply_only="${3:-n}"

    # Get site info
    local site_info
    site_info=$(get_site_info "$site_name" "$config_file")

    if [ -z "$site_info" ]; then
        print_error "Site '$site_name' not found in $config_file"
        return 1
    fi

    # Parse site info
    local site_dir=""
    local recipe=""
    local environment=""
    local purpose=""

    while IFS='=' read -r key value; do
        case "$key" in
            DIRECTORY) site_dir="$value" ;;
            RECIPE) recipe="$value" ;;
            ENVIRONMENT) environment="$value" ;;
            PURPOSE) purpose="$value" ;;
        esac
    done <<< "$site_info"

    # Map environment to short form
    local env_short="dev"
    case "$environment" in
        staging) env_short="stage" ;;
        production) env_short="prod" ;;
        live) env_short="live" ;;
        *) env_short="dev" ;;
    esac

    # Determine recipe type
    local recipe_type="drupal"
    case "$recipe" in
        moodle|m) recipe_type="moodle" ;;
        gitlab) recipe_type="gitlab" ;;
        *) recipe_type="drupal" ;;
    esac

    print_header "Modify Site: $site_name"
    echo ""
    echo -e "  Directory:   ${BLUE}$site_dir${NC}"
    echo -e "  Recipe:      ${BLUE}$recipe${NC}"
    echo -e "  Environment: ${BLUE}$environment${NC}"
    echo -e "  Purpose:     ${BLUE}${purpose:-indefinite}${NC}"
    echo ""

    # Check if directory exists
    if [ ! -d "$site_dir" ]; then
        print_error "Site directory not found: $site_dir"
        print_info "The site may have been moved or deleted."
        return 1
    fi

    # Run interactive option selection (unless apply_only)
    if [ "$apply_only" != "y" ]; then
        # Load options for recipe type
        case "$recipe_type" in
            moodle)
                define_moodle_options
                ;;
            gitlab)
                define_gitlab_options
                ;;
            *)
                define_drupal_options
                ;;
        esac

        # Load existing config
        load_existing_config "$site_name" "$config_file"

        # Run interactive selection
        interactive_select_options "$env_short" "$recipe_type" "$site_name"

        # Show summary
        echo ""
        print_header "Selected Options Summary"
        local selected_count=0
        for key in "${OPTION_LIST[@]}"; do
            if [[ "${OPTION_SELECTED[$key]}" == "y" ]]; then
                echo -e "  ${GREEN}✓${NC} ${OPTION_LABELS[$key]}"
                ((selected_count++))
            fi
        done

        if [[ $selected_count -eq 0 ]]; then
            echo -e "  ${DIM}No options selected${NC}"
        fi
        echo ""
        echo "Total: $selected_count options selected"
        echo ""

        read -p "Apply these options? [Y/n]: " confirm
        if [[ "$confirm" =~ ^[Nn]$ ]]; then
            print_info "Modification cancelled"
            return 0
        fi
    fi

    # Update cnwp.yml with options
    if command -v yaml_site_exists &> /dev/null && yaml_site_exists "$site_name" "$config_file" 2>/dev/null; then
        # Check if any options are selected
        local has_options=false
        for key in "${OPTION_LIST[@]}"; do
            if [[ "${OPTION_SELECTED[$key]}" == "y" ]]; then
                has_options=true
                break
            fi
        done

        if [[ "$has_options" == "true" ]]; then
            print_info "Updating options in cnwp.yml..."
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
            ' "$config_file" > "${config_file}.tmp"

            if mv "${config_file}.tmp" "$config_file"; then
                print_status "OK" "Options saved to cnwp.yml"
            else
                print_warning "Failed to update cnwp.yml"
            fi
        else
            print_info "Removing options from cnwp.yml (none selected)..."
            awk -v site="$site_name" '
                BEGIN { in_site = 0; in_sites = 0; in_options = 0 }
                /^sites:/ { in_sites = 1; print; next }
                in_sites && /^[a-zA-Z]/ && !/^  / && !/^#/ { in_sites = 0 }
                in_sites && $0 ~ "^  " site ":" { in_site = 1; print; next }
                in_site && /^    options:/ { in_options = 1; next }
                in_options && /^      / { next }
                in_options && !/^      / { in_options = 0 }
                in_site && (/^  [a-zA-Z0-9_-]+:/ || (/^[a-zA-Z]/ && !/^  / && !/^#/)) { in_site = 0 }
                { print }
            ' "$config_file" > "${config_file}.tmp"

            if mv "${config_file}.tmp" "$config_file"; then
                print_status "OK" "Options removed from cnwp.yml"
            fi
        fi
    fi

    # Apply options to site
    case "$recipe_type" in
        moodle)
            apply_options_to_moodle_site "$site_dir"
            ;;
        gitlab)
            print_info "GitLab options require manual configuration"
            ;;
        *)
            apply_options_to_drupal_site "$site_dir"
            ;;
    esac

    # Show manual steps guide
    if command -v generate_manual_steps &> /dev/null; then
        generate_manual_steps "$site_name" "$env_short"
    fi

    print_header "Modification Complete"
    echo ""
    echo -e "Site ${GREEN}$site_name${NC} has been updated."
    echo ""

    return 0
}

# Show help
show_help() {
    echo "NWP Site Modification Script"
    echo ""
    echo "Usage: ./modify.sh [site_name] [options]"
    echo ""
    echo "Arguments:"
    echo "  site_name          Name of site from cnwp.yml (optional)"
    echo ""
    echo "Options:"
    echo "  -l, --list         List all sites in cnwp.yml"
    echo "  -a, --apply        Apply current options without interactive mode"
    echo "  -h, --help         Show this help message"
    echo ""
    echo "Examples:"
    echo "  ./modify.sh                  List and select a site"
    echo "  ./modify.sh nwp5             Modify options for 'nwp5'"
    echo "  ./modify.sh -l               List all sites"
    echo ""
}

################################################################################
# Main
################################################################################

main() {
    local site_name=""
    local config_file="$SCRIPT_DIR/cnwp.yml"
    local list_only="n"
    local apply_only="n"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -l|--list)
                list_only="y"
                shift
                ;;
            -a|--apply)
                apply_only="y"
                shift
                ;;
            -*)
                print_error "Unknown option: $1"
                show_help
                exit 1
                ;;
            *)
                site_name="$1"
                shift
                ;;
        esac
    done

    # Check config file exists
    if [ ! -f "$config_file" ]; then
        print_error "Config file not found: $config_file"
        exit 1
    fi

    # Check for checkbox library
    if ! command -v interactive_select_options &> /dev/null; then
        print_error "Interactive options library not loaded"
        print_info "Make sure lib/checkbox.sh exists"
        exit 1
    fi

    # List sites if requested
    if [ "$list_only" == "y" ]; then
        display_sites "$config_file"
        exit 0
    fi

    # If no site specified, show list and prompt
    if [ -z "$site_name" ]; then
        local total_sites
        total_sites=$(count_sites "$config_file")

        if [ "$total_sites" -eq 0 ]; then
            print_error "No sites found in cnwp.yml"
            print_info "Use ./install.sh to create a new site first"
            exit 1
        fi

        display_sites "$config_file"

        echo ""
        read -p "Enter site number or name to modify: " selection

        # Check if it's a number
        if [[ "$selection" =~ ^[0-9]+$ ]]; then
            site_name=$(get_site_by_index "$selection" "$config_file")
            if [ -z "$site_name" ]; then
                print_error "Invalid selection: $selection"
                exit 1
            fi
        else
            site_name="$selection"
        fi
    fi

    # Run modification
    modify_site "$site_name" "$config_file" "$apply_only"
}

# Run main
main "$@"
