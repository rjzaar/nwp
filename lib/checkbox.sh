#!/bin/bash

################################################################################
# NWP Interactive Checkbox UI Library
#
# Provides interactive checkbox selection for install options
# Source this file: source "$SCRIPT_DIR/lib/checkbox.sh"
################################################################################

# Ensure ui.sh is sourced for colors
if [ -z "$NC" ]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'
    CYAN=$'\033[0;36m'
    NC=$'\033[0m'
    BOLD=$'\033[1m'
    DIM=$'\033[2m'
fi

# Checkbox symbols
CHECKBOX_CHECKED="[${GREEN}✓${NC}]"
CHECKBOX_UNCHECKED="[ ]"
CHECKBOX_CURSOR=">"
CHECKBOX_DISABLED="[${DIM}-${NC}]"

################################################################################
# Option Definition System
################################################################################

# Associative arrays for option metadata
declare -A OPTION_LABELS        # Human-readable labels
declare -A OPTION_DESCRIPTIONS  # Descriptions
declare -A OPTION_ENVIRONMENTS  # Which environment (dev/stage/live/prod)
declare -A OPTION_DEFAULTS      # Default state per environment
declare -A OPTION_DEPENDENCIES  # Dependencies (comma-separated)
declare -A OPTION_CONFLICTS     # Conflicts (comma-separated)
declare -A OPTION_INPUTS        # Required input fields (comma-separated key:label pairs)
declare -A OPTION_CATEGORIES    # Category within environment
declare -A OPTION_SELECTED      # Current selection state
declare -A OPTION_VALUES        # Input values for options requiring input

# List of all options in order
OPTION_LIST=()

# Define a new option
# Usage: define_option "key" "label" "description" "environment" "default" "dependencies" "inputs" "category"
define_option() {
    local key="$1"
    local label="$2"
    local description="$3"
    local environment="$4"           # dev, stage, live, prod, or "all"
    local default="$5"               # y/n or "dev:y,stage:n,live:n,prod:y"
    local dependencies="${6:-}"      # comma-separated option keys
    local inputs="${7:-}"            # comma-separated key:label pairs
    local category="${8:-general}"   # Category within environment

    OPTION_LIST+=("$key")
    OPTION_LABELS["$key"]="$label"
    OPTION_DESCRIPTIONS["$key"]="$description"
    OPTION_ENVIRONMENTS["$key"]="$environment"
    OPTION_DEFAULTS["$key"]="$default"
    OPTION_DEPENDENCIES["$key"]="$dependencies"
    OPTION_INPUTS["$key"]="$inputs"
    OPTION_CATEGORIES["$key"]="$category"
    OPTION_SELECTED["$key"]="n"
}

# Clear all options
clear_options() {
    OPTION_LIST=()
    unset OPTION_LABELS OPTION_DESCRIPTIONS OPTION_ENVIRONMENTS OPTION_DEFAULTS
    unset OPTION_DEPENDENCIES OPTION_INPUTS OPTION_CATEGORIES OPTION_SELECTED OPTION_VALUES
    declare -gA OPTION_LABELS OPTION_DESCRIPTIONS OPTION_ENVIRONMENTS OPTION_DEFAULTS
    declare -gA OPTION_DEPENDENCIES OPTION_INPUTS OPTION_CATEGORIES OPTION_SELECTED OPTION_VALUES
}

################################################################################
# Drupal/OpenSocial Options
################################################################################

define_drupal_options() {
    clear_options

    # === DEVELOPMENT OPTIONS ===
    define_option "dev_modules" \
        "Development Modules" \
        "Install devel, kint, webprofiler for debugging" \
        "dev" "dev:y,stage:n,live:n,prod:n" "" "" "modules"

    define_option "xdebug" \
        "XDebug" \
        "Enable XDebug for step-through debugging" \
        "dev" "dev:n,stage:n,live:n,prod:n" "" "" "tools"
    OPTION_CONFLICTS["xdebug"]="redis"  # XDebug and Redis can conflict in some setups

    define_option "stage_file_proxy" \
        "Stage File Proxy" \
        "Proxy files from production (saves disk space)" \
        "dev" "dev:n,stage:y,live:n,prod:n" "" "" "modules"
    OPTION_CONFLICTS["stage_file_proxy"]="cdn"  # Don't proxy files if using CDN

    define_option "config_split" \
        "Config Split" \
        "Enable environment-specific configuration" \
        "dev" "dev:y,stage:y,live:y,prod:y" "" "" "modules"

    # === STAGING OPTIONS ===
    define_option "db_sanitize" \
        "Database Sanitization" \
        "Sanitize user data when syncing from production" \
        "stage" "dev:y,stage:y,live:n,prod:n" "" "" "database"

    define_option "staging_domain" \
        "Staging Domain" \
        "Configure staging domain for the site" \
        "stage" "dev:n,stage:y,live:n,prod:n" "" \
        "domain:Staging Domain (e.g. site-stg.example.com)" "deployment"

    # === LIVE/PRODUCTION OPTIONS ===
    define_option "security_modules" \
        "Security Modules" \
        "Install seckit, honeypot, login_security, flood_control" \
        "live" "dev:n,stage:n,live:y,prod:y" "" "" "security"

    define_option "redis" \
        "Redis Caching" \
        "Enable Redis for object caching" \
        "live" "dev:n,stage:n,live:y,prod:y" "" "" "performance"

    define_option "solr" \
        "Solr Search" \
        "Enable Apache Solr for advanced search" \
        "live" "dev:n,stage:n,live:n,prod:n" "" \
        "core:Solr Core Name" "search"

    define_option "cron" \
        "Cron Configuration" \
        "Set up automated cron jobs" \
        "live" "dev:n,stage:n,live:y,prod:y" "" \
        "interval:Cron Interval (minutes)" "scheduling"

    define_option "backup" \
        "Automated Backups" \
        "Configure automated backups to B2 storage" \
        "live" "dev:n,stage:n,live:y,prod:y" "" "" "backup"

    define_option "ssl" \
        "SSL Certificate" \
        "Configure Let's Encrypt SSL" \
        "live" "dev:n,stage:y,live:y,prod:y" "" \
        "domain:Domain for SSL" "security"

    define_option "cdn" \
        "CDN Configuration" \
        "Configure Cloudflare CDN" \
        "live" "dev:n,stage:n,live:y,prod:y" "ssl" "" "performance"

    # === PRODUCTION-SPECIFIC OPTIONS ===
    define_option "live_domain" \
        "Production Domain" \
        "Configure the production domain" \
        "prod" "dev:n,stage:n,live:n,prod:y" "" \
        "domain:Production Domain" "deployment"

    define_option "dns_records" \
        "DNS Records" \
        "Auto-configure Linode DNS records" \
        "prod" "dev:n,stage:n,live:n,prod:y" "live_domain" "" "deployment"

    define_option "monitoring" \
        "Uptime Monitoring" \
        "Configure uptime monitoring alerts" \
        "prod" "dev:n,stage:n,live:n,prod:y" "live_domain" \
        "email:Alert Email" "monitoring"

    # === CI/CD OPTIONS ===
    define_option "ci_enabled" \
        "CI/CD Pipeline" \
        "Enable GitLab CI/CD for this site" \
        "all" "dev:y,stage:y,live:y,prod:y" "" "" "cicd"

    define_option "ci_lint" \
        "Linting" \
        "Run PHPCS and code linting in CI" \
        "all" "dev:y,stage:y,live:y,prod:y" "ci_enabled" "" "cicd"

    define_option "ci_tests" \
        "Automated Tests" \
        "Run PHPUnit tests in CI" \
        "all" "dev:y,stage:y,live:y,prod:y" "ci_enabled" "" "cicd"

    define_option "ci_security" \
        "Security Scanning" \
        "Run security scans in CI pipeline" \
        "all" "dev:n,stage:y,live:y,prod:y" "ci_enabled" "" "cicd"

    define_option "ci_deploy" \
        "Auto Deploy" \
        "Automatically deploy on successful CI" \
        "all" "dev:n,stage:n,live:n,prod:n" "ci_enabled" "" "cicd"

    # === EMAIL OPTIONS ===
    define_option "email_enabled" \
        "Email Configuration" \
        "Enable site email functionality" \
        "all" "dev:n,stage:n,live:y,prod:y" "" "" "email"

    define_option "email_send" \
        "Outgoing Email" \
        "Configure SMTP for sending emails" \
        "all" "dev:n,stage:n,live:y,prod:y" "email_enabled" \
        "address:Site Email Address" "email"

    define_option "email_receive" \
        "Incoming Email" \
        "Set up mailbox for receiving emails" \
        "all" "dev:n,stage:n,live:n,prod:n" "email_send" \
        "forward:Forward To Address" "email"
}

################################################################################
# Moodle Options
################################################################################

define_moodle_options() {
    clear_options

    # === DEVELOPMENT OPTIONS ===
    define_option "debug_mode" \
        "Debug Mode" \
        "Enable Moodle debug mode" \
        "dev" "dev:y,stage:n,live:n,prod:n" "" "" "debugging"

    define_option "dev_theme" \
        "Development Theme" \
        "Use development theme with debugging info" \
        "dev" "dev:n,stage:n,live:n,prod:n" "" "" "appearance"

    # === STAGING OPTIONS ===
    define_option "staging_domain" \
        "Staging Domain" \
        "Configure staging domain" \
        "stage" "dev:n,stage:y,live:n,prod:n" "" \
        "domain:Staging Domain" "deployment"

    # === LIVE OPTIONS ===
    define_option "ssl" \
        "SSL Certificate" \
        "Configure Let's Encrypt SSL" \
        "live" "dev:n,stage:y,live:y,prod:y" "" \
        "domain:Domain for SSL" "security"

    define_option "redis" \
        "Redis Session Store" \
        "Use Redis for session storage" \
        "live" "dev:n,stage:n,live:y,prod:y" "" "" "performance"

    define_option "backup" \
        "Automated Backups" \
        "Configure automated backups" \
        "live" "dev:n,stage:n,live:y,prod:y" "" "" "backup"

    define_option "cron" \
        "Cron Configuration" \
        "Set up Moodle cron job" \
        "live" "dev:n,stage:n,live:y,prod:y" "" \
        "interval:Cron Interval (minutes)" "scheduling"

    # === PRODUCTION OPTIONS ===
    define_option "live_domain" \
        "Production Domain" \
        "Configure production domain" \
        "prod" "dev:n,stage:n,live:n,prod:y" "" \
        "domain:Production Domain" "deployment"

    define_option "monitoring" \
        "Uptime Monitoring" \
        "Configure uptime monitoring" \
        "prod" "dev:n,stage:n,live:n,prod:y" "live_domain" \
        "email:Alert Email" "monitoring"
}

################################################################################
# GitLab Options
################################################################################

define_gitlab_options() {
    clear_options

    # === DEVELOPMENT OPTIONS ===
    define_option "reduced_memory" \
        "Reduced Memory Mode" \
        "Optimize for development (less RAM)" \
        "dev" "dev:y,stage:n,live:n,prod:n" "" "" "performance"

    # === LIVE OPTIONS ===
    define_option "ssl" \
        "SSL Certificate" \
        "Configure Let's Encrypt SSL" \
        "live" "dev:n,stage:n,live:y,prod:y" "" \
        "domain:GitLab Domain" "security"

    define_option "runner" \
        "GitLab Runner" \
        "Install shared GitLab Runner" \
        "live" "dev:n,stage:n,live:y,prod:y" "" "" "cicd"

    define_option "backup" \
        "Automated Backups" \
        "Configure automated GitLab backups" \
        "live" "dev:n,stage:n,live:y,prod:y" "" "" "backup"

    # === SECURITY OPTIONS ===
    define_option "disable_signups" \
        "Disable Public Signups" \
        "Prevent public user registration" \
        "live" "dev:n,stage:n,live:y,prod:y" "" "" "security"

    define_option "require_2fa" \
        "Require 2FA" \
        "Require two-factor authentication" \
        "live" "dev:n,stage:n,live:n,prod:y" "" "" "security"

    define_option "audit_logging" \
        "Audit Logging" \
        "Enable audit event logging" \
        "live" "dev:n,stage:n,live:y,prod:y" "" "" "security"
}

################################################################################
# Selection Logic
################################################################################

# Get default value for an option in a given environment
get_option_default() {
    local key="$1"
    local env="$2"
    local defaults="${OPTION_DEFAULTS[$key]}"

    # Parse defaults string (e.g., "dev:y,stage:n,live:y,prod:y")
    if [[ "$defaults" == *":"* ]]; then
        echo "$defaults" | tr ',' '\n' | while read -r pair; do
            local e="${pair%%:*}"
            local v="${pair#*:}"
            if [[ "$e" == "$env" ]]; then
                echo "$v"
                return
            fi
        done
    else
        # Simple y/n default
        echo "$defaults"
    fi
}

# Check if option should be visible for environment
option_visible_for_env() {
    local key="$1"
    local env="$2"
    local opt_env="${OPTION_ENVIRONMENTS[$key]}"

    [[ "$opt_env" == "all" ]] || [[ "$opt_env" == "$env" ]]
}

# Apply environment defaults
apply_environment_defaults() {
    local env="$1"

    for key in "${OPTION_LIST[@]}"; do
        local default=$(get_option_default "$key" "$env")
        if [[ "$default" == "y" ]]; then
            OPTION_SELECTED["$key"]="y"
        else
            OPTION_SELECTED["$key"]="n"
        fi
    done
}

# Check dependencies for an option
check_dependencies() {
    local key="$1"
    local deps="${OPTION_DEPENDENCIES[$key]}"

    if [[ -z "$deps" ]]; then
        return 0  # No dependencies
    fi

    local missing=()
    IFS=',' read -ra dep_arr <<< "$deps"
    for dep in "${dep_arr[@]}"; do
        if [[ "${OPTION_SELECTED[$dep]}" != "y" ]]; then
            missing+=("${OPTION_LABELS[$dep]}")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "${missing[*]}"
        return 1
    fi
    return 0
}

# Check conflicts for an option
check_conflicts() {
    local key="$1"
    local conflicts="${OPTION_CONFLICTS[$key]}"

    if [[ -z "$conflicts" ]]; then
        return 0  # No conflicts
    fi

    local active_conflicts=()
    IFS=',' read -ra conflict_arr <<< "$conflicts"
    for conflict in "${conflict_arr[@]}"; do
        if [[ "${OPTION_SELECTED[$conflict]}" == "y" ]]; then
            active_conflicts+=("${OPTION_LABELS[$conflict]}")
        fi
    done

    if [[ ${#active_conflicts[@]} -gt 0 ]]; then
        echo "${active_conflicts[*]}"
        return 1
    fi
    return 0
}

# Get options that depend on a given option
get_dependents() {
    local key="$1"
    local dependents=()

    for opt in "${OPTION_LIST[@]}"; do
        local deps="${OPTION_DEPENDENCIES[$opt]}"
        if [[ -n "$deps" ]]; then
            IFS=',' read -ra dep_arr <<< "$deps"
            for dep in "${dep_arr[@]}"; do
                if [[ "$dep" == "$key" ]] && [[ "${OPTION_SELECTED[$opt]}" == "y" ]]; then
                    dependents+=("${OPTION_LABELS[$opt]}")
                fi
            done
        fi
    done

    echo "${dependents[*]}"
}

################################################################################
# Interactive UI
################################################################################

# Display options for a specific environment
display_environment_options() {
    local env="$1"
    local env_label="$2"
    local filter_env="$3"  # If set, only show this environment

    echo ""
    echo -e "${BLUE}${BOLD}═══ $env_label ═══${NC}"

    local current_category=""
    local idx=1

    for key in "${OPTION_LIST[@]}"; do
        # Check if option is for this environment
        if ! option_visible_for_env "$key" "$filter_env"; then
            continue
        fi

        local category="${OPTION_CATEGORIES[$key]}"
        local label="${OPTION_LABELS[$key]}"
        local description="${OPTION_DESCRIPTIONS[$key]}"
        local selected="${OPTION_SELECTED[$key]}"
        local deps="${OPTION_DEPENDENCIES[$key]}"
        local inputs="${OPTION_INPUTS[$key]}"

        # Show category header
        if [[ "$category" != "$current_category" ]]; then
            current_category="$category"
            echo ""
            echo -e "  ${CYAN}${BOLD}${category^}${NC}"
        fi

        # Determine checkbox state
        local checkbox
        if [[ "$selected" == "y" ]]; then
            checkbox="$CHECKBOX_CHECKED"
        else
            checkbox="$CHECKBOX_UNCHECKED"
        fi

        # Check dependencies
        local dep_warning=""
        if [[ -n "$deps" ]]; then
            local missing=$(check_dependencies "$key")
            if [[ -n "$missing" ]]; then
                dep_warning=" ${DIM}(requires: $missing)${NC}"
            fi
        fi

        # Check conflicts
        local conflict_warning=""
        local conflicts="${OPTION_CONFLICTS[$key]}"
        if [[ -n "$conflicts" ]] && [[ "$selected" == "y" ]]; then
            local active_conflicts=$(check_conflicts "$key")
            if [[ -n "$active_conflicts" ]]; then
                conflict_warning=" ${RED}⚠ conflicts: $active_conflicts${NC}"
            fi
        fi

        # Show input indicator
        local input_indicator=""
        if [[ -n "$inputs" ]]; then
            input_indicator=" ${YELLOW}[input required]${NC}"
        fi

        printf "    %s %-3s %-30s %s%s%s%s\n" \
            "$checkbox" "[$idx]" "$label" "${DIM}$description${NC}" "$dep_warning" "$conflict_warning" "$input_indicator"

        # Show current input values if selected
        if [[ "$selected" == "y" ]] && [[ -n "$inputs" ]]; then
            IFS=',' read -ra input_arr <<< "$inputs"
            for input in "${input_arr[@]}"; do
                local input_key="${input%%:*}"
                local value_key="${key}_${input_key}"
                local current_value="${OPTION_VALUES[$value_key]:-<not set>}"
                echo -e "        ${DIM}→ ${input_key}: ${current_value}${NC}"
            done
        fi

        ((idx++))
    done
}

# Interactive checkbox menu
# Returns when user confirms selection
interactive_select_options() {
    local environment="$1"      # dev, stage, live, prod
    local recipe_type="$2"      # drupal, moodle, gitlab
    local existing_config="$3"  # JSON string of existing config or empty

    # Load appropriate options
    case "$recipe_type" in
        drupal|d|os|nwp|dm)
            define_drupal_options
            ;;
        moodle|m)
            define_moodle_options
            ;;
        gitlab)
            define_gitlab_options
            ;;
        *)
            define_drupal_options
            ;;
    esac

    # Apply existing configuration if provided
    if [[ -n "$existing_config" ]]; then
        load_existing_config "$existing_config"
    else
        # Apply environment defaults
        apply_environment_defaults "$environment"
    fi

    local done=false

    while [[ "$done" != "true" ]]; do
        clear
        echo -e "${BOLD}NWP Installation Options${NC}"
        echo -e "${DIM}Environment: $environment | Recipe: $recipe_type${NC}"
        echo ""
        echo -e "Use numbers to toggle options. Type ${BOLD}e${NC} to edit inputs."
        echo -e "Type ${BOLD}all${NC} to apply all defaults for environment."
        echo -e "Type ${BOLD}none${NC} to clear all selections."
        echo -e "Type ${BOLD}done${NC} or ${BOLD}d${NC} when finished."
        echo ""

        # Display options grouped by environment
        local env_label
        case "$environment" in
            dev) env_label="Development" ;;
            stage) env_label="Staging" ;;
            live) env_label="Live" ;;
            prod) env_label="Production" ;;
        esac

        # Show all environments with current one highlighted
        for env in dev stage live prod; do
            local show_env_label
            case "$env" in
                dev) show_env_label="Development" ;;
                stage) show_env_label="Staging" ;;
                live) show_env_label="Live" ;;
                prod) show_env_label="Production" ;;
            esac

            if [[ "$env" == "$environment" ]]; then
                show_env_label="${show_env_label} ${GREEN}(current)${NC}"
            fi

            display_environment_options "$env" "$show_env_label" "$env"
        done

        echo ""
        echo -e "${BOLD}Commands:${NC}"
        echo -e "  ${CYAN}1-99${NC}   Toggle option by number"
        echo -e "  ${CYAN}e <n>${NC}  Edit input for option number"
        echo -e "  ${CYAN}all${NC}    Select all defaults for $env_label"
        echo -e "  ${CYAN}none${NC}   Clear all selections"
        echo -e "  ${CYAN}done${NC}   Confirm and continue"
        echo ""

        read -p "Enter command: " cmd arg

        case "$cmd" in
            [0-9]|[0-9][0-9])
                toggle_option_by_index "$cmd"
                ;;
            e|edit)
                if [[ -n "$arg" ]]; then
                    edit_option_inputs "$arg"
                else
                    read -p "Option number to edit: " arg
                    edit_option_inputs "$arg"
                fi
                ;;
            all)
                apply_environment_defaults "$environment"
                echo -e "${GREEN}Applied defaults for $env_label${NC}"
                sleep 1
                ;;
            none)
                for key in "${OPTION_LIST[@]}"; do
                    OPTION_SELECTED["$key"]="n"
                done
                echo -e "${YELLOW}Cleared all selections${NC}"
                sleep 1
                ;;
            done|d|q)
                # Validate dependencies
                local validation_errors=()
                for key in "${OPTION_LIST[@]}"; do
                    if [[ "${OPTION_SELECTED[$key]}" == "y" ]]; then
                        local missing=$(check_dependencies "$key")
                        if [[ -n "$missing" ]]; then
                            validation_errors+=("${OPTION_LABELS[$key]} requires: $missing")
                        fi
                    fi
                done

                if [[ ${#validation_errors[@]} -gt 0 ]]; then
                    echo ""
                    echo -e "${RED}${BOLD}Dependency errors:${NC}"
                    for err in "${validation_errors[@]}"; do
                        echo -e "  ${RED}✗${NC} $err"
                    done
                    echo ""
                    read -p "Press Enter to continue editing..."
                else
                    done=true
                fi
                ;;
            *)
                echo -e "${YELLOW}Unknown command: $cmd${NC}"
                sleep 1
                ;;
        esac
    done
}

# Toggle option by its display index
toggle_option_by_index() {
    local index="$1"
    local idx=1

    for key in "${OPTION_LIST[@]}"; do
        if [[ "$idx" -eq "$index" ]]; then
            if [[ "${OPTION_SELECTED[$key]}" == "y" ]]; then
                # Check for dependents before deselecting
                local dependents=$(get_dependents "$key")
                if [[ -n "$dependents" ]]; then
                    echo ""
                    echo -e "${YELLOW}Warning:${NC} Deselecting '${OPTION_LABELS[$key]}' will affect:"
                    echo -e "  ${dependents}"
                    read -p "Continue? [y/N]: " confirm
                    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                        return
                    fi
                    # Also deselect dependents
                    for opt in "${OPTION_LIST[@]}"; do
                        local deps="${OPTION_DEPENDENCIES[$opt]}"
                        if [[ -n "$deps" ]] && [[ "$deps" == *"$key"* ]]; then
                            OPTION_SELECTED["$opt"]="n"
                        fi
                    done
                fi
                OPTION_SELECTED["$key"]="n"
            else
                # Check conflicts before selecting
                local conflicts=$(check_conflicts "$key")
                if [[ -n "$conflicts" ]]; then
                    echo ""
                    echo -e "${RED}Conflicts with:${NC} $conflicts"
                    read -p "Disable conflicting options? [y/N]: " confirm
                    if [[ "$confirm" =~ ^[Yy]$ ]]; then
                        # Disable conflicting options
                        IFS=',' read -ra conflict_arr <<< "${OPTION_CONFLICTS[$key]}"
                        for conflict in "${conflict_arr[@]}"; do
                            OPTION_SELECTED["$conflict"]="n"
                        done
                    else
                        return
                    fi
                fi

                # Check dependencies before selecting
                local missing=$(check_dependencies "$key")
                if [[ -n "$missing" ]]; then
                    echo ""
                    echo -e "${YELLOW}Missing dependencies:${NC} $missing"
                    read -p "Enable dependencies too? [Y/n]: " confirm
                    if [[ ! "$confirm" =~ ^[Nn]$ ]]; then
                        # Enable dependencies
                        IFS=',' read -ra dep_arr <<< "${OPTION_DEPENDENCIES[$key]}"
                        for dep in "${dep_arr[@]}"; do
                            OPTION_SELECTED["$dep"]="y"
                        done
                    else
                        return
                    fi
                fi
                OPTION_SELECTED["$key"]="y"

                # Check if inputs are required
                local inputs="${OPTION_INPUTS[$key]}"
                if [[ -n "$inputs" ]]; then
                    edit_option_inputs "$index"
                fi
            fi
            return
        fi
        ((idx++))
    done

    echo -e "${YELLOW}Invalid option number: $index${NC}"
    sleep 1
}

# Edit input values for an option
edit_option_inputs() {
    local index="$1"
    local idx=1

    for key in "${OPTION_LIST[@]}"; do
        if [[ "$idx" -eq "$index" ]]; then
            local inputs="${OPTION_INPUTS[$key]}"
            if [[ -z "$inputs" ]]; then
                echo -e "${YELLOW}Option '${OPTION_LABELS[$key]}' has no inputs to edit${NC}"
                sleep 1
                return
            fi

            echo ""
            echo -e "${BOLD}Editing inputs for: ${OPTION_LABELS[$key]}${NC}"

            IFS=',' read -ra input_arr <<< "$inputs"
            for input in "${input_arr[@]}"; do
                local input_key="${input%%:*}"
                local input_label="${input#*:}"
                local value_key="${key}_${input_key}"
                local current="${OPTION_VALUES[$value_key]:-}"

                if [[ -n "$current" ]]; then
                    read -p "  $input_label [$current]: " new_value
                    new_value="${new_value:-$current}"
                else
                    read -p "  $input_label: " new_value
                fi

                OPTION_VALUES["$value_key"]="$new_value"
            done
            return
        fi
        ((idx++))
    done
}

# Load existing configuration from cnwp.yml site entry
load_existing_config() {
    local site_name="$1"
    local config_file="${2:-cnwp.yml}"

    # This would parse existing site configuration and set OPTION_SELECTED accordingly
    # For now, we'll implement basic loading

    if [[ -f "$config_file" ]] && yaml_site_exists "$site_name" "$config_file" 2>/dev/null; then
        echo -e "${BLUE}Loading existing configuration for '$site_name'...${NC}"

        # Get existing options from site entry
        # This is a simplified implementation - expand as needed
        local existing_options=$(awk -v site="$site_name" '
            /^sites:/ { in_sites = 1; next }
            in_sites && /^[a-zA-Z]/ && !/^  / { in_sites = 0 }
            in_sites && $0 ~ "^  " site ":" { in_site = 1; next }
            in_site && /^  [a-zA-Z]/ && !/^    / { in_site = 0 }
            in_site && /^    options:/ { in_options = 1; next }
            in_options && /^    [a-zA-Z]/ && !/^      / { in_options = 0 }
            in_options && /^      [a-zA-Z_]+:/ {
                key = $0
                sub(/^      /, "", key)
                sub(/:.*/, "", key)
                val = $0
                sub(/^[^:]+: */, "", val)
                print key "=" val
            }
        ' "$config_file")

        while IFS='=' read -r key val; do
            if [[ -n "$key" ]] && [[ -n "${OPTION_LABELS[$key]:-}" ]]; then
                OPTION_SELECTED["$key"]="$val"
            fi
        done <<< "$existing_options"
    fi
}

################################################################################
# Output Generation
################################################################################

# Generate YAML for selected options
generate_options_yaml() {
    local indent="${1:-    }"

    echo "${indent}options:"
    for key in "${OPTION_LIST[@]}"; do
        if [[ "${OPTION_SELECTED[$key]}" == "y" ]]; then
            echo "${indent}  ${key}: y"

            # Add input values if present
            local inputs="${OPTION_INPUTS[$key]}"
            if [[ -n "$inputs" ]]; then
                IFS=',' read -ra input_arr <<< "$inputs"
                for input in "${input_arr[@]}"; do
                    local input_key="${input%%:*}"
                    local value_key="${key}_${input_key}"
                    local value="${OPTION_VALUES[$value_key]:-}"
                    if [[ -n "$value" ]]; then
                        echo "${indent}    ${input_key}: ${value}"
                    fi
                done
            fi
        fi
    done
}

# Generate manual steps guide based on selected options
generate_manual_steps() {
    local site_name="$1"
    local environment="$2"

    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  Manual Steps Required${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    local step=1

    # Development Modules
    if [[ "${OPTION_SELECTED[dev_modules]}" == "y" ]]; then
        echo -e "${CYAN}Step $step: Development Modules (Automated)${NC}"
        echo "  Modules will be installed automatically: devel, kint, webprofiler"
        echo "  Access Devel menu at /devel"
        echo ""
        ((step++))
    fi

    # XDebug
    if [[ "${OPTION_SELECTED[xdebug]}" == "y" ]]; then
        echo -e "${CYAN}Step $step: Configure XDebug${NC}"
        echo "  1. Run: ddev xdebug on"
        echo "  2. Configure IDE (PhpStorm/VSCode) with port 9003"
        echo "  3. Set breakpoints and start listening for connections"
        echo "  Docs: https://ddev.readthedocs.io/en/stable/users/debugging-profiling/step-debugging/"
        echo ""
        ((step++))
    fi

    # Staging Domain
    if [[ "${OPTION_SELECTED[staging_domain]}" == "y" ]]; then
        local domain="${OPTION_VALUES[staging_domain_domain]:-site-stg.example.com}"
        echo -e "${CYAN}Step $step: Configure Staging Domain${NC}"
        echo "  1. Update DNS A record for: $domain"
        echo "  2. Configure web server (nginx/apache) for domain"
        echo "  3. Update settings.php with trusted_host_patterns"
        echo ""
        ((step++))
    fi

    # Database Sanitization
    if [[ "${OPTION_SELECTED[db_sanitize]}" == "y" ]]; then
        echo -e "${CYAN}Step $step: Database Sanitization${NC}"
        echo "  When syncing from production, sanitize user data:"
        echo "  ddev drush sql-sanitize --sanitize-password=test123 --sanitize-email=user+%uid@localhost"
        echo "  This is typically automated in CI/CD pipeline"
        echo ""
        ((step++))
    fi

    # Security Modules
    if [[ "${OPTION_SELECTED[security_modules]}" == "y" ]]; then
        echo -e "${CYAN}Step $step: Security Modules (Automated)${NC}"
        echo "  Modules will be installed: seckit, honeypot, login_security, flood_control"
        echo "  Configure at: /admin/config/system/seckit"
        echo "  Review honeypot settings: /admin/config/content/honeypot"
        echo ""
        ((step++))
    fi

    # SSL Certificate
    if [[ "${OPTION_SELECTED[ssl]}" == "y" ]]; then
        local domain="${OPTION_VALUES[ssl_domain]:-example.com}"
        echo -e "${CYAN}Step $step: Configure SSL Certificate${NC}"
        echo "  Run: certbot --nginx -d $domain"
        echo "  Or use Cloudflare SSL if CDN is enabled"
        echo ""
        ((step++))
    fi

    # CDN Configuration
    if [[ "${OPTION_SELECTED[cdn]}" == "y" ]]; then
        echo -e "${CYAN}Step $step: Configure Cloudflare CDN${NC}"
        echo "  1. Log into Cloudflare dashboard"
        echo "  2. Add your domain and update nameservers"
        echo "  3. Configure Page Rules for Drupal:"
        echo "     - /admin/* (bypass cache)"
        echo "     - /user/* (bypass cache)"
        echo "  4. Enable development mode during initial testing"
        echo ""
        ((step++))
    fi

    # Redis Configuration
    if [[ "${OPTION_SELECTED[redis]}" == "y" ]]; then
        echo -e "${CYAN}Step $step: Configure Redis${NC}"
        echo "  1. For DDEV: ddev get ddev/ddev-redis"
        echo "  2. Edit settings.php to add Redis configuration:"
        echo "     \$settings['redis.connection']['host'] = 'redis';"
        echo "     \$settings['redis.connection']['port'] = 6379;"
        echo "     \$settings['cache']['default'] = 'cache.backend.redis';"
        echo "  3. Enable redis module: ddev drush en redis -y"
        echo ""
        ((step++))
    fi

    # Solr Configuration
    if [[ "${OPTION_SELECTED[solr]}" == "y" ]]; then
        local core="${OPTION_VALUES[solr_core]:-drupal}"
        echo -e "${CYAN}Step $step: Configure Solr${NC}"
        echo "  1. Add Solr service to DDEV: ddev get ddev/ddev-solr"
        echo "  2. Create core: ddev solr create -c $core"
        echo "  3. Configure Search API module:"
        echo "     - Enable: ddev drush en search_api_solr -y"
        echo "     - Create server at /admin/config/search/search-api"
        echo ""
        ((step++))
    fi

    # Cron Configuration
    if [[ "${OPTION_SELECTED[cron]}" == "y" ]]; then
        local interval="${OPTION_VALUES[cron_interval]:-15}"
        echo -e "${CYAN}Step $step: Configure Cron${NC}"
        echo "  For production server, add to crontab:"
        echo "  */$interval * * * * cd /path/to/site && vendor/bin/drush cron"
        echo ""
        echo "  For DDEV development:"
        echo "  ddev drush cron (manual execution)"
        echo ""
        ((step++))
    fi

    # Backup Configuration
    if [[ "${OPTION_SELECTED[backup]}" == "y" ]]; then
        echo -e "${CYAN}Step $step: Configure Automated Backups${NC}"
        echo "  1. Configure B2 credentials in .secrets.yml"
        echo "  2. Set up backup script in cron:"
        echo "     0 2 * * * /path/to/backup.sh"
        echo "  3. Test backup and restore procedures"
        echo "  4. Configure retention policy (recommended: 30 days)"
        echo ""
        ((step++))
    fi

    # Production Domain
    if [[ "${OPTION_SELECTED[live_domain]}" == "y" ]]; then
        local domain="${OPTION_VALUES[live_domain_domain]:-example.com}"
        echo -e "${CYAN}Step $step: Configure Production Domain${NC}"
        echo "  1. Update DNS A record for: $domain"
        echo "  2. Configure web server for production"
        echo "  3. Update settings.php with trusted_host_patterns"
        echo "  4. Verify HTTPS is working"
        echo ""
        ((step++))
    fi

    # DNS Records
    if [[ "${OPTION_SELECTED[dns_records]}" == "y" ]]; then
        echo -e "${CYAN}Step $step: Configure DNS Records (Automated)${NC}"
        echo "  DNS records are pre-registered via Linode API"
        echo "  Verify at: linode-cli domains list"
        echo "  TTL is set to 300 seconds for quick updates"
        echo ""
        ((step++))
    fi

    # CI/CD Pipeline
    if [[ "${OPTION_SELECTED[ci_enabled]}" == "y" ]]; then
        echo -e "${CYAN}Step $step: Configure CI/CD Pipeline${NC}"
        echo "  1. Create .gitlab-ci.yml in project root"
        echo "  2. Configure GitLab Runner for the project"
        echo "  3. Set up deployment keys and variables"
        echo "  4. Configure protected branches (main, develop)"
        echo ""
        ((step++))
    fi

    # 2FA for GitLab
    if [[ "${OPTION_SELECTED[require_2fa]}" == "y" ]]; then
        echo -e "${CYAN}Step $step: Enable Required 2FA${NC}"
        echo "  1. Log into GitLab as admin"
        echo "  2. Go to Admin Area > Settings > General"
        echo "  3. Expand 'Sign-in restrictions'"
        echo "  4. Enable 'Require all users to set up two-factor authentication'"
        echo ""
        ((step++))
    fi

    # GitLab Runner
    if [[ "${OPTION_SELECTED[runner]}" == "y" ]]; then
        echo -e "${CYAN}Step $step: Install GitLab Runner${NC}"
        echo "  1. Install runner: curl -L https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.deb.sh | sudo bash"
        echo "  2. sudo apt-get install gitlab-runner"
        echo "  3. Register runner: sudo gitlab-runner register"
        echo "  4. Enter GitLab URL and registration token from Admin > Runners"
        echo ""
        ((step++))
    fi

    # Audit Logging
    if [[ "${OPTION_SELECTED[audit_logging]}" == "y" ]]; then
        echo -e "${CYAN}Step $step: Enable Audit Logging${NC}"
        echo "  1. Go to Admin Area > Settings > General > Visibility"
        echo "  2. Enable audit events"
        echo "  3. View logs at Admin Area > Monitoring > Audit Events"
        echo ""
        ((step++))
    fi

    # Monitoring Setup
    if [[ "${OPTION_SELECTED[monitoring]}" == "y" ]]; then
        local email="${OPTION_VALUES[monitoring_email]:-admin@example.com}"
        echo -e "${CYAN}Step $step: Configure Monitoring${NC}"
        echo "  1. Set up UptimeRobot or Pingdom"
        echo "  2. Add HTTP(s) monitor for your domain"
        echo "  3. Configure alerts to: $email"
        echo "  4. Consider monitoring specific endpoints (/user/login, /api)"
        echo ""
        ((step++))
    fi

    # Email Configuration
    if [[ "${OPTION_SELECTED[email_enabled]}" == "y" ]] || [[ "${OPTION_SELECTED[email_send]}" == "y" ]]; then
        local email="${OPTION_VALUES[email_send_address]:-noreply@example.com}"
        echo -e "${CYAN}Step $step: Configure Email${NC}"
        echo "  1. Verify SMTP credentials in .secrets.yml"
        echo "  2. Install SMTP module: ddev drush en smtp -y"
        echo "  3. Configure at /admin/config/system/smtp"
        echo "  4. Set 'From' address to: $email"
        echo "  5. Test email sending via /admin/config/system/smtp/test"
        echo ""
        ((step++))
    fi

    # Incoming Email
    if [[ "${OPTION_SELECTED[email_receive]}" == "y" ]]; then
        local forward="${OPTION_VALUES[email_receive_forward]:-admin@example.com}"
        echo -e "${CYAN}Step $step: Configure Incoming Email${NC}"
        echo "  1. Configure mailbox via Postfix"
        echo "  2. Set up forwarding to: $forward"
        echo "  3. Configure email processing scripts if needed"
        echo ""
        ((step++))
    fi

    if [[ $step -eq 1 ]]; then
        echo -e "${GREEN}No manual steps required! All selected options will be automated.${NC}"
    else
        echo -e "${BOLD}Total manual steps: $((step-1))${NC}"
    fi
    echo ""
}

# Export functions
export -f define_option clear_options define_drupal_options define_moodle_options define_gitlab_options
export -f get_option_default option_visible_for_env apply_environment_defaults
export -f check_dependencies check_conflicts get_dependents
export -f display_environment_options interactive_select_options toggle_option_by_index edit_option_inputs
export -f load_existing_config generate_options_yaml generate_manual_steps
