#!/bin/bash
################################################################################
# NWP Install Common Library
#
# Shared functions for all installation types (Drupal, Moodle, GitLab, Podcast)
# This file is sourced by install.sh before loading type-specific installers.
################################################################################

# Guard against multiple sourcing
if [ "${_INSTALL_COMMON_LOADED:-}" = "1" ]; then
    return 0
fi
_INSTALL_COMMON_LOADED=1

################################################################################
# Interactive Option Selection
################################################################################

# Run interactive option selection using TUI (with checkbox fallback)
# Returns selected options in OPTION_SELECTED associative array
run_interactive_options() {
    local recipe="$1"
    local site_name="$2"
    local recipe_type="$3"
    local config_file="${4:-cnwp.yml}"

    # Check if TUI library is available
    if ! command -v run_tui &> /dev/null; then
        # Fall back to checkbox library
        if command -v interactive_select_options &> /dev/null; then
            local environment="dev"
            [[ "$site_name" =~ _stg$ ]] && environment="stage"
            [[ "$site_name" =~ _live$ ]] && environment="live"
            [[ "$site_name" =~ _prod$ ]] && environment="prod"
            interactive_select_options "$environment" "$recipe_type" ""
            return $?
        fi
        print_warning "Interactive options not available"
        return 0
    fi

    # Determine environment from site name suffix
    local environment="dev"
    if [[ "$site_name" =~ _stg$ ]]; then
        environment="stage"
    elif [[ "$site_name" =~ _live$ ]]; then
        environment="live"
    elif [[ "$site_name" =~ _prod$ ]]; then
        environment="prod"
    fi

    # Load options for recipe type
    case "$recipe_type" in
        moodle|m) define_moodle_options ;;
        gitlab) define_gitlab_options ;;
        *) define_drupal_options ;;
    esac

    # Load defaults with recipe pre-selections
    load_tui_defaults "install" "$site_name" "$recipe" "$environment" "$config_file"

    # Run interactive TUI (goes directly to options like modify.sh)
    if run_tui "install" "$site_name" "$environment" "$recipe_type" "$config_file"; then
        # User confirmed - show summary
        echo ""
        print_header "Selected Options Summary"
        local selected_count=0
        for key in "${OPTION_LIST[@]}"; do
            if [[ "${OPTION_SELECTED[$key]}" == "y" ]]; then
                local recipe_hint=""
                [[ "${OPTION_FROM_RECIPE[$key]:-n}" == "y" ]] && recipe_hint=" ${DIM}(recipe)${NC}"
                echo -e "  ${GREEN}✓${NC} ${OPTION_LABELS[$key]}${recipe_hint}"
                ((selected_count++))
            fi
        done

        if [[ $selected_count -eq 0 ]]; then
            echo -e "  ${DIM}No options selected${NC}"
        fi
        echo ""
        echo "Total: $selected_count options selected"
        echo ""
        return 0
    else
        # User cancelled
        print_warning "Installation cancelled"
        return 1
    fi
}

# Update cnwp.yml with selected options (or remove options section if none selected)
update_site_options() {
    local site_name="$1"
    local config_file="${2:-cnwp.yml}"

    # Check if option system is loaded
    if [[ ${#OPTION_LIST[@]} -eq 0 ]]; then
        return 0
    fi

    # Check if site exists in config
    if ! yaml_site_exists "$site_name" "$config_file" 2>/dev/null; then
        return 0
    fi

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
        # Create options section with selected options only
        local options_yaml=$(generate_options_yaml "      ")
    else
        print_info "Removing options from cnwp.yml (none selected)..."
        # Empty options to trigger removal
        local options_yaml=""
    fi

    # Use awk to add/replace/remove options section in site entry
    awk -v site="$site_name" -v options="$options_yaml" '
        BEGIN { in_site = 0; in_sites = 0; in_options = 0; added = 0 }

        /^sites:/ {
            in_sites = 1
            print
            next
        }

        in_sites && /^[a-zA-Z]/ && !/^  / && !/^#/ {
            in_sites = 0
        }

        in_sites && $0 ~ "^  " site ":" {
            in_site = 1
            print
            next
        }

        # Skip existing options section (will be replaced or removed)
        in_site && /^    options:/ {
            in_options = 1
            next
        }

        in_options && /^      / {
            next
        }

        in_options && !/^      / {
            in_options = 0
        }

        # End of site, add options before next site (if we have any)
        in_site && (/^  [a-zA-Z0-9_-]+:/ || (/^[a-zA-Z]/ && !/^  / && !/^#/)) {
            if (!added && options != "") {
                print options
            }
            added = 1
            in_site = 0
        }

        { print }

        END {
            if (in_site && !added && options != "") {
                print options
            }
        }
    ' "$config_file" > "${config_file}.tmp"

    if mv "${config_file}.tmp" "$config_file"; then
        if [[ "$has_options" == "true" ]]; then
            print_status "OK" "Options saved to cnwp.yml"
        else
            print_status "OK" "Options removed from cnwp.yml"
        fi
    else
        print_warning "Failed to update cnwp.yml with options"
    fi
}

# Show manual steps guide at installation end
show_installation_guide() {
    local site_name="$1"
    local environment="$2"

    if command -v generate_manual_steps &> /dev/null && [[ ${#OPTION_LIST[@]} -gt 0 ]]; then
        generate_manual_steps "$site_name" "$environment"
    fi
}

################################################################################
# Apply Selected Options
################################################################################

# Apply selected options during Drupal/OpenSocial installation
apply_drupal_options() {
    if [[ ${#OPTION_LIST[@]} -eq 0 ]]; then
        return 0
    fi

    local applied=0

    print_header "Applying Selected Options"

    # Development Modules
    if [[ "${OPTION_SELECTED[dev_modules]}" == "y" ]]; then
        print_info "Installing development modules..."
        if ddev drush pm:enable devel kint webprofiler -y 2>/dev/null; then
            print_status "OK" "Development modules installed"
            ((applied++))
        else
            print_warning "Some dev modules may not be available"
        fi
    fi

    # XDebug
    if [[ "${OPTION_SELECTED[xdebug]}" == "y" ]]; then
        print_info "Enabling XDebug..."
        if ddev xdebug on 2>/dev/null; then
            print_status "OK" "XDebug enabled"
            ((applied++))
        else
            print_warning "XDebug may need manual configuration"
        fi
    fi

    # Stage File Proxy
    if [[ "${OPTION_SELECTED[stage_file_proxy]}" == "y" ]]; then
        print_info "Installing Stage File Proxy..."
        if ddev composer require drupal/stage_file_proxy && ddev drush pm:enable stage_file_proxy -y 2>/dev/null; then
            print_status "OK" "Stage File Proxy installed"
            ((applied++))
        else
            print_warning "Stage File Proxy installation may need manual steps"
        fi
    fi

    # Config Split
    if [[ "${OPTION_SELECTED[config_split]}" == "y" ]]; then
        print_info "Installing Config Split..."
        if ddev composer require drupal/config_split && ddev drush pm:enable config_split -y 2>/dev/null; then
            print_status "OK" "Config Split installed"
            ((applied++))
        else
            print_warning "Config Split installation may need manual steps"
        fi
    fi

    # Security Modules
    if [[ "${OPTION_SELECTED[security_modules]}" == "y" ]]; then
        print_info "Installing security modules..."
        local security_mods="seckit honeypot login_security flood_control"
        for mod in $security_mods; do
            if ddev composer require "drupal/$mod" 2>/dev/null; then
                ddev drush pm:enable "$mod" -y 2>/dev/null || true
            fi
        done
        print_status "OK" "Security modules installed"
        ((applied++))
    fi

    # Redis
    if [[ "${OPTION_SELECTED[redis]}" == "y" ]]; then
        print_info "Enabling Redis..."
        if ddev get ddev/ddev-redis 2>/dev/null; then
            ddev restart 2>/dev/null
            ddev composer require drupal/redis 2>/dev/null
            ddev drush pm:enable redis -y 2>/dev/null
            print_status "OK" "Redis enabled (configure settings.php manually)"
            ((applied++))
        else
            print_warning "Redis installation may need manual steps"
        fi
    fi

    # Solr
    if [[ "${OPTION_SELECTED[solr]}" == "y" ]]; then
        print_info "Enabling Solr..."
        if ddev get ddev/ddev-solr 2>/dev/null; then
            local core="${OPTION_VALUES[solr_core]:-drupal}"
            ddev restart 2>/dev/null
            ddev solr create -c "$core" 2>/dev/null || true
            ddev composer require drupal/search_api_solr 2>/dev/null
            print_status "OK" "Solr enabled with core: $core"
            ((applied++))
        else
            print_warning "Solr installation may need manual steps"
        fi
    fi

    if [[ $applied -gt 0 ]]; then
        print_info "Clearing cache after option application..."
        ddev drush cr 2>/dev/null || true
        print_status "OK" "Applied $applied options"
    else
        print_info "No automated options to apply"
    fi

    return 0
}

# Apply selected options during Moodle installation
apply_moodle_options() {
    if [[ ${#OPTION_LIST[@]} -eq 0 ]]; then
        return 0
    fi

    local applied=0

    print_header "Applying Selected Options"

    # Debug Mode
    if [[ "${OPTION_SELECTED[debug_mode]}" == "y" ]]; then
        print_info "Enabling debug mode..."
        # Add debug settings to config.php
        if [ -f "config.php" ]; then
            cat >> config.php << 'MOODLE_DEBUG'

// Debug settings (added by install script)
@error_reporting(E_ALL | E_STRICT);
@ini_set('display_errors', '1');
$CFG->debug = (E_ALL | E_STRICT);
$CFG->debugdisplay = 1;
MOODLE_DEBUG
            print_status "OK" "Debug mode enabled"
            ((applied++))
        fi
    fi

    # Redis Session Store
    if [[ "${OPTION_SELECTED[redis]}" == "y" ]]; then
        print_info "Configuring Redis for sessions..."
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
        print_info "No automated options to apply"
    fi

    return 0
}

# Apply selected options during GitLab installation
apply_gitlab_options() {
    if [[ ${#OPTION_LIST[@]} -eq 0 ]]; then
        return 0
    fi

    local applied=0

    print_header "Applying Selected Options"

    # Reduced Memory Mode
    if [[ "${OPTION_SELECTED[reduced_memory]}" == "y" ]]; then
        print_info "Reduced memory mode already configured in docker-compose.yml"
        ((applied++))
    fi

    # Disable Signups
    if [[ "${OPTION_SELECTED[disable_signups]}" == "y" ]]; then
        print_info "Note: Disable signups in GitLab Admin > Settings > General > Sign-up restrictions"
        ((applied++))
    fi

    if [[ $applied -gt 0 ]]; then
        print_status "OK" "Applied $applied options"
    else
        print_info "No automated options to apply"
    fi

    return 0
}

################################################################################
# DNS Pre-registration for Live Sites
################################################################################

# Pre-register DNS entry for future live site deployment
# This eliminates DNS propagation wait time when running pl live
pre_register_live_dns() {
    local site_name="$1"

    # Get base name (strip _stg or _prod suffix)
    local base_name=$(echo "$site_name" | sed -E 's/_(stg|prod|dev)$//')

    # Get base domain from settings
    local base_domain=$(get_settings_value "url" "$SCRIPT_DIR/cnwp.yml")
    if [ -z "$base_domain" ]; then
        print_info "DNS pre-registration skipped: No 'url' in cnwp.yml settings"
        return 0
    fi

    # Get Linode API token
    local token=""
    if command -v get_linode_token &> /dev/null; then
        token=$(get_linode_token "$SCRIPT_DIR")
    fi

    if [ -z "$token" ]; then
        print_info "DNS pre-registration skipped: No Linode API token in .secrets.yml"
        return 0
    fi

    # Get shared GitLab server IP
    local gitlab_host="git.${base_domain}"
    local server_ip=""

    # Try to get IP via SSH first
    if ssh -o BatchMode=yes -o ConnectTimeout=3 "gitlab@${gitlab_host}" "hostname -I" 2>/dev/null | awk '{print $1}' | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        server_ip=$(ssh -o BatchMode=yes -o ConnectTimeout=3 "gitlab@${gitlab_host}" "hostname -I" 2>/dev/null | awk '{print $1}')
    else
        # Fall back to DNS lookup
        server_ip=$(dig +short "$gitlab_host" 2>/dev/null | head -1)
    fi

    if [ -z "$server_ip" ]; then
        print_info "DNS pre-registration skipped: Cannot reach shared server ${gitlab_host}"
        return 0
    fi

    # Get domain ID
    local domain_id=""
    local response=$(curl -s -H "Authorization: Bearer $token" "https://api.linode.com/v4/domains")

    if command -v jq &> /dev/null; then
        domain_id=$(echo "$response" | jq -r ".data[] | select(.domain == \"${base_domain}\") | .id")
    fi

    if [ -z "$domain_id" ]; then
        print_info "DNS pre-registration skipped: Domain ${base_domain} not found in Linode"
        return 0
    fi

    # Check if DNS record already exists
    local existing=$(curl -s -H "Authorization: Bearer $token" \
        "https://api.linode.com/v4/domains/${domain_id}/records" | \
        grep -o "\"name\":\"${base_name}\"" || true)

    if [ -n "$existing" ]; then
        print_info "DNS record already exists: ${base_name}.${base_domain}"
        return 0
    fi

    # Create A record
    print_info "Pre-registering DNS for future live site: ${base_name}.${base_domain}"

    local create_response=$(curl -s -X POST \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        "https://api.linode.com/v4/domains/${domain_id}/records" \
        -d "{
            \"type\": \"A\",
            \"name\": \"${base_name}\",
            \"target\": \"${server_ip}\",
            \"ttl_sec\": 300
        }")

    if echo "$create_response" | grep -q '"id"'; then
        print_status "OK" "DNS pre-registered: ${base_name}.${base_domain} -> ${server_ip}"
    fi

    return 0
}

################################################################################
# YAML Parsing Functions
################################################################################

# Parse YAML file and extract value for a given recipe and key
get_recipe_value() {
    local recipe=$1
    local key=$2
    local config_file="${3:-cnwp.yml}"

    # Use awk to extract the value
    awk -v recipe="$recipe" -v key="$key" '
        BEGIN { in_recipe = 0; found = 0 }
        /^  [a-zA-Z0-9_-]+:/ {
            if ($1 == recipe":") {
                in_recipe = 1
            } else if (in_recipe && /^  [a-zA-Z0-9_-]+:/) {
                in_recipe = 0
            }
        }
        in_recipe && $0 ~ "^    " key ":" {
            sub("^    " key ": *", "")
            print
            found = 1
            exit
        }
    ' "$config_file"
}

# Parse YAML file and extract root-level value
get_root_value() {
    local key=$1
    local config_file="${2:-cnwp.yml}"

    # Use awk to extract root-level values (not indented)
    awk -v key="$key" '
        /^[a-zA-Z0-9_-]+:/ && $1 == key":" {
            sub("^" key ": *", "")
            print
            exit
        }
    ' "$config_file"
}

# Get value from settings section
get_settings_value() {
    local key=$1
    local config_file="${2:-cnwp.yml}"

    # Use awk to extract values from settings section (indented under settings:)
    awk -v key="$key" '
        BEGIN { in_settings = 0 }
        /^settings:/ {
            in_settings = 1
            next
        }
        in_settings && /^[a-zA-Z0-9_-]+:/ {
            # Exited settings section
            in_settings = 0
        }
        in_settings && /^  [a-zA-Z0-9_-]+:/ && $1 == key":" {
            sub("^  " key ": *", "")
            print
            exit
        }
    ' "$config_file"
}

# Check if recipe exists in config file
recipe_exists() {
    local recipe=$1
    local config_file="${2:-cnwp.yml}"

    grep -q "^  ${recipe}:" "$config_file"
    return $?
}

# List all available recipes with their descriptions
list_recipes() {
    local config_file="${1:-cnwp.yml}"

    print_header "Available Recipes"

    echo -e "${BOLD}Recipes defined in $config_file:${NC}\n"

    # Extract recipe names only from the recipes: section
    local recipes=$(awk '
        /^recipes:/ { in_recipes = 1; next }
        /^[a-zA-Z]/ { in_recipes = 0 }
        in_recipes && /^  [a-zA-Z0-9_-]+:/ {
            match($0, /^  ([a-zA-Z0-9_-]+):/, arr)
            if (arr[1]) print arr[1]
        }
    ' "$config_file")

    for recipe in $recipes; do
        local recipe_type=$(get_recipe_value "$recipe" "type" "$config_file")
        local source=$(get_recipe_value "$recipe" "source" "$config_file")
        local profile=$(get_recipe_value "$recipe" "profile" "$config_file")
        local branch=$(get_recipe_value "$recipe" "branch" "$config_file")

        # Default to drupal if type not specified
        if [ -z "$recipe_type" ]; then
            recipe_type="drupal"
        fi

        echo -e "${BLUE}${BOLD}$recipe${NC} (${recipe_type})"

        if [ "$recipe_type" == "moodle" ]; then
            echo -e "  Source: $source"
            [ -n "$branch" ] && echo -e "  Branch: $branch"
        else
            echo -e "  Source: $source"
            [ -n "$profile" ] && echo -e "  Profile: $profile"
        fi

        echo ""
    done

    echo -e "${BOLD}Usage:${NC}"
    echo -e "  ./install.sh <recipe>           Install the specified recipe"
    echo -e "  ./install.sh <recipe> c         Install with test content creation"
    echo -e "  ./install.sh <recipe> s=N       Start from step N"
    echo ""
}

# Validate that a recipe has all required fields
validate_recipe() {
    local recipe=$1
    local config_file="${2:-cnwp.yml}"
    local errors=0

    local recipe_type=$(get_recipe_value "$recipe" "type" "$config_file")

    # Default to drupal if type not specified
    if [ -z "$recipe_type" ]; then
        recipe_type="drupal"
    fi

    # Check required fields based on type
    if [ "$recipe_type" == "moodle" ]; then
        # Moodle required fields
        local source=$(get_recipe_value "$recipe" "source" "$config_file")
        local branch=$(get_recipe_value "$recipe" "branch" "$config_file")
        local webroot=$(get_recipe_value "$recipe" "webroot" "$config_file")

        if [ -z "$source" ]; then
            print_error "Recipe '$recipe': Missing required field 'source'"
            errors=$((errors + 1))
        fi

        if [ -z "$branch" ]; then
            print_error "Recipe '$recipe': Missing required field 'branch'"
            errors=$((errors + 1))
        fi

        if [ -z "$webroot" ]; then
            print_error "Recipe '$recipe': Missing required field 'webroot'"
            errors=$((errors + 1))
        fi
    elif [ "$recipe_type" == "gitlab" ]; then
        # GitLab required fields - uses Docker, minimal requirements
        local source=$(get_recipe_value "$recipe" "source" "$config_file")
        # GitLab only needs source (git URL) - everything else has defaults
        if [ -z "$source" ]; then
            print_error "Recipe '$recipe': Missing required field 'source'"
            errors=$((errors + 1))
        fi
    elif [ "$recipe_type" == "podcast" ]; then
        # Podcast required fields - uses podcast.sh for Castopod setup
        local domain=$(get_recipe_value "$recipe" "domain" "$config_file")
        # Podcast needs domain - everything else has defaults
        if [ -z "$domain" ]; then
            print_error "Recipe '$recipe': Missing required field 'domain'"
            errors=$((errors + 1))
        fi
    elif [ "$recipe_type" == "migration" ]; then
        # Migration type has no required fields - just creates stub
        :
    else
        # Drupal required fields
        local source=$(get_recipe_value "$recipe" "source" "$config_file")
        local profile=$(get_recipe_value "$recipe" "profile" "$config_file")
        local webroot=$(get_recipe_value "$recipe" "webroot" "$config_file")

        if [ -z "$source" ]; then
            print_error "Recipe '$recipe': Missing required field 'source'"
            errors=$((errors + 1))
        fi

        if [ -z "$profile" ]; then
            print_error "Recipe '$recipe': Missing required field 'profile'"
            errors=$((errors + 1))
        fi

        if [ -z "$webroot" ]; then
            print_error "Recipe '$recipe': Missing required field 'webroot'"
            errors=$((errors + 1))
        fi
    fi

    return $errors
}

# Show help information
show_help() {
    local config_file="${1:-cnwp.yml}"

    echo -e "${BOLD}Narrow Way Project Installation Script${NC}"
    echo ""
    echo -e "${BOLD}USAGE:${NC}"
    echo -e "  ./install.sh [OPTIONS] <recipe> [target]"
    echo ""
    echo -e "${BOLD}ARGUMENTS:${NC}"
    echo -e "  recipe                  Recipe name from cnwp.yml (required)"
    echo -e "  target                  Custom directory/site name (optional)"
    echo ""
    echo -e "${BOLD}OPTIONS:${NC}"
    echo -e "  -l, --list              List all available recipes"
    echo -e "  -h, --help              Show this help message"
    echo -e "  c, --create-content     Create test content after installation"
    echo -e "  s=N, --step=N           Start installation from step N"
    echo -e "  -p=X, --purpose=X       Set site purpose (t=testing, i=indefinite, p=permanent, m=migration)"
    echo ""
    echo -e "${BOLD}PURPOSE VALUES:${NC}"
    echo -e "  testing (t)             Site can be deleted freely (default for test sites)"
    echo -e "  indefinite (i)          Site not auto-deleted but can be manually deleted (default)"
    echo -e "  permanent (p)           Site requires manual change in cnwp.yml before deletion"
    echo -e "  migration (m)           Migration site - creates folder stub only for importing"
    echo ""
    echo -e "${BOLD}EXAMPLES:${NC}"
    echo -e "  ./install.sh --list              List available recipes"
    echo -e "  ./install.sh nwp                 Install nwp recipe in 'nwp' directory"
    echo -e "  ./install.sh nwp client1         Install nwp recipe in 'client1' directory"
    echo -e "  ./install.sh nwp mysite c        Install nwp as 'mysite' with test content"
    echo -e "  ./install.sh nwp site2 s=3       Resume 'site2' from step 3"
    echo -e "  ./install.sh nwp prod -p=p       Install with permanent purpose"
    echo -e "  ./install.sh d oldsite -p=m      Create migration stub for importing old site"
    echo ""
    echo -e "${BOLD}TARGET NAMES:${NC}"
    echo -e "  The target parameter allows you to create multiple sites from the same recipe."
    echo -e "  If not specified, the recipe name is used as the directory/site name."
    echo -e "  Examples:"
    echo -e "    ./install.sh nwp          -> Creates site in directory 'nwp'"
    echo -e "    ./install.sh nwp client1  -> Creates site in directory 'client1'"
    echo -e "    ./install.sh nwp client2  -> Creates site in directory 'client2'"
    echo ""
    echo -e "${BOLD}AVAILABLE RECIPES:${NC}"
    local recipes=$(awk '
        /^recipes:/ { in_recipes = 1; next }
        /^[a-zA-Z]/ { in_recipes = 0 }
        in_recipes && /^  [a-zA-Z0-9_-]+:/ {
            match($0, /^  ([a-zA-Z0-9_-]+):/, arr)
            if (arr[1]) print arr[1]
        }
    ' "$config_file")
    for recipe in $recipes; do
        echo -e "  - $recipe"
    done
    echo ""
    echo -e "For detailed recipe information, use: ./install.sh --list"
    echo ""
}

################################################################################
# Utility Functions
################################################################################

# Extract module name from git URL
get_module_name_from_git_url() {
    local git_url=$1
    # Extract last part of path and remove .git extension
    # Handles both git@github.com:user/repo.git and https://github.com/user/repo.git
    echo "$git_url" | sed -e 's/.*[:/]\([^/]*\)\.git$/\1/' -e 's/.*\/\([^/]*\)\.git$/\1/'
}

# Check if a string is a git URL
is_git_url() {
    local url=$1
    if [[ "$url" =~ ^git@ ]] || [[ "$url" =~ \.git$ ]]; then
        return 0
    fi
    return 1
}

# Install modules from git repositories
install_git_modules() {
    local git_modules=$1
    local webroot=$2
    local custom_dir="${webroot}/modules/custom"

    print_info "Installing modules from git repositories..."

    # Create custom modules directory if it doesn't exist
    if [ ! -d "$custom_dir" ]; then
        mkdir -p "$custom_dir"
        print_status "OK" "Created custom modules directory: $custom_dir"
    fi

    # Process each git module
    for git_url in $git_modules; do
        local module_name=$(get_module_name_from_git_url "$git_url")
        local module_path="${custom_dir}/${module_name}"

        if [ -d "$module_path" ]; then
            print_status "WARN" "Module $module_name already exists, skipping clone"
            continue
        fi

        print_info "Cloning $module_name from $git_url..."
        if git clone "$git_url" "$module_path"; then
            print_status "OK" "Module $module_name cloned successfully"
        else
            print_error "Failed to clone module $module_name from $git_url"
            return 1
        fi
    done

    return 0
}

# Find available directory name for recipe installation
get_available_dirname() {
    local recipe=$1
    local dirname="$recipe"
    local counter=1

    # If directory doesn't exist, return it
    if [ ! -d "$dirname" ]; then
        echo "$dirname"
        return 0
    fi

    # Otherwise, find the next available numbered directory
    while [ -d "${recipe}${counter}" ]; do
        counter=$((counter + 1))
    done

    echo "${recipe}${counter}"
    return 0
}

################################################################################
# Installation Step Functions
################################################################################

# Check if current step should be executed
should_run_step() {
    local current_step=$1
    local start_step=$2

    if [ -z "$start_step" ] || [ "$current_step" -ge "$start_step" ]; then
        return 0  # true - run this step
    else
        return 1  # false - skip this step
    fi
}

################################################################################
# Test Content Creation (Drupal-specific but used by main install flow)
################################################################################

# Create test content for workflow_assignment module
create_test_content() {
    print_header "Creating Test Content"

    print_info "Enabling workflow_assignment module..."
    if ! ddev drush pm:enable workflow_assignment -y 2>&1 | grep -v "Deprecated"; then
        print_error "Failed to enable workflow_assignment module"
        return 1
    fi

    print_info "Enabling page content type for workflow support and clearing cache..."
    if ! ddev drush php:eval "
        \$config = \Drupal::configFactory()->getEditable('workflow_assignment.settings');
        \$enabled_types = \$config->get('enabled_content_types') ?: [];
        if (!in_array('page', \$enabled_types)) {
            \$enabled_types[] = 'page';
            \$config->set('enabled_content_types', \$enabled_types);
            \$config->save();
        }
        drupal_flush_all_caches();
    " 2>&1 | grep -v "Deprecated" >/dev/null; then
        print_warning "Could not configure workflow settings (may already be configured)"
    fi

    print_info "Creating 5 test users..."
    local users=()
    for i in {1..5}; do
        local username="testuser$i"
        local email="testuser$i@example.com"

        if ddev drush user:info "$username" &>/dev/null; then
            print_info "User $username already exists, skipping..."
        else
            if ddev drush user:create "$username" --mail="$email" --password="${TEST_PASSWORD:-test123}" 2>&1 | grep -v "Deprecated" >/dev/null; then
                print_info "Created user: $username"
            else
                print_warning "Failed to create user: $username"
            fi
        fi
        users+=("$username")
    done

    print_info "Creating 5 test documents..."
    local doc_nids=()
    for i in {1..5}; do
        local title="Test Document $i"
        local body="This is test document number $i for workflow assignment testing."

        local nid=$(ddev drush php:eval "
            \$node = \Drupal\node\Entity\Node::create([
                'type' => 'page',
                'title' => '$title',
                'body' => [
                    'value' => '$body',
                    'format' => 'basic_html',
                ],
                'uid' => 1,
                'status' => 1,
            ]);
            \$node->save();
            echo \$node->id();
        " 2>/dev/null | tail -1)

        if [ -n "$nid" ]; then
            doc_nids+=("$nid")
            print_info "Created document: $title (NID: $nid)"
        fi
    done

    print_info "Creating 5 workflow assignments..."
    local workflow_ids=()
    for i in {1..5}; do
        local user_index=$((i - 1))
        local username="${users[$user_index]}"
        local wf_id="test_workflow_$i"

        if ddev drush php:eval "
            \$users = \Drupal::entityTypeManager()
                ->getStorage('user')
                ->loadByProperties(['name' => '$username']);
            \$user = reset(\$users);

            if (\$user) {
                \$workflow = \Drupal::entityTypeManager()
                    ->getStorage('workflow_list')
                    ->create([
                        'id' => '${wf_id}',
                        'label' => 'Workflow Task $i',
                        'description' => 'This is test workflow assignment $i for testing purposes.',
                        'assigned_type' => 'user',
                        'assigned_id' => \$user->id(),
                        'comments' => 'Test comment for workflow $i',
                    ]);
                \$workflow->save();
                echo 'OK';
            } else {
                echo 'USER_NOT_FOUND';
            }
        " 2>/dev/null | grep -q "OK"; then
            workflow_ids+=("$wf_id")
            print_info "Created workflow: Workflow Task $i (assigned to $username)"
        else
            print_warning "Failed to create workflow: Workflow Task $i"
        fi
    done

    # Link workflows to the first document
    if [ ${#doc_nids[@]} -gt 0 ] && [ ${#workflow_ids[@]} -gt 0 ]; then
        local target_nid="${doc_nids[0]}"

        print_info "Linking workflows to document (NID: $target_nid)..."
        # Build workflow IDs string safely
        local wf_ids_str=""
        for wf_id in "${workflow_ids[@]}"; do
            [ -n "$wf_ids_str" ] && wf_ids_str+=", "
            wf_ids_str+="'$wf_id'"
        done

        if ddev drush php:eval "
            \$node = \Drupal\node\Entity\Node::load($target_nid);
            if (\$node && \$node->hasField('field_workflow_list')) {
                \$workflow_ids = [$wf_ids_str];
                \$node->set('field_workflow_list', \$workflow_ids);
                \$node->save();
                echo 'OK';
            } else {
                echo 'FIELD_NOT_FOUND';
            }
        " 2>/dev/null | grep -q "OK"; then
            print_status "OK" "Test content created successfully"
        else
            print_warning "Could not link workflows to document (field may not exist)"
            print_status "OK" "Test content partially created"
        fi

        # Get one-time login URL and append workflow tab destination
        local uli_url=$(ddev drush uli --uri=default 2>/dev/null | tail -n 1)
        local workflow_url="${uli_url%/login}/login?destination=/node/${target_nid}/workflow"

        echo ""
        echo -e "${BOLD}Test Content Summary:${NC}"
        echo -e "  ${GREEN}✓${NC} ${#users[@]} users created (testuser1-${#users[@]}, password: ${TEST_PASSWORD:-test123})"
        echo -e "  ${GREEN}✓${NC} ${#doc_nids[@]} documents created (NIDs: ${doc_nids[*]})"
        echo -e "  ${GREEN}✓${NC} ${#workflow_ids[@]} workflow assignments linked to document $target_nid"
        echo ""
        echo -e "${BOLD}Login and view workflow assignments:${NC}"
        echo -e "  ${BLUE}${workflow_url}${NC}"
        echo ""

        # Try to open in browser with login URL that redirects to workflow tab
        if command -v xdg-open &> /dev/null; then
            xdg-open "$workflow_url" &>/dev/null &
            print_status "OK" "Browser opened with login to workflow tab"
        elif command -v open &> /dev/null; then
            open "$workflow_url" &>/dev/null &
            print_status "OK" "Browser opened with login to workflow tab"
        fi
    else
        print_error "No documents or workflows were created"
        return 1
    fi

    return 0
}
