#!/bin/bash
################################################################################
# install-steps.sh - Installation step definitions and tracking
#
# Defines installation steps for each environment and provides functions
# to track, query, and display installation progress.
#
# Usage:
#   source "$SCRIPT_DIR/lib/install-steps.sh"
#   get_step_title 4
#   get_install_status "sitename" "/path/to/cnwp.yml"
################################################################################

# Base installation steps (all environments)
# Format: "step_number:key:title:description"
declare -a BASE_STEPS=(
    "1:dir:Directory:Create site directory structure"
    "2:code:Codebase:Download code via Composer or Git"
    "3:ddev:DDEV Config:Generate .ddev/config.yaml"
    "4:start:DDEV Start:Start DDEV containers"
    "5:db:Database:Create or import database"
    "6:install:Site Install:Run drush site:install"
    "7:modules:Modules:Install recipe modules"
    "8:config:Config Import:Import CMI configuration"
)

# Development environment steps (after base)
declare -a DEV_STEPS=(
    "9:dev_mods:Dev Modules:Enable devel, webprofiler, kint"
    "10:dev_settings:Dev Settings:Disable caching, show errors"
)

# Staging environment steps (after base)
declare -a STAGE_STEPS=(
    "9:sync:Sync:Pull database/files from production"
    "10:sanitize:Sanitize:Anonymize user data"
    "11:proxy:File Proxy:Enable stage_file_proxy"
)

# Live/Production environment steps (after base)
declare -a LIVE_STEPS=(
    "9:security:Security:Install security modules"
    "10:cache:Caching:Enable Redis/page cache"
    "11:cron:Cron:Configure automated cron"
    "12:ssl:SSL/HTTPS:Verify SSL certificates"
    "13:backup:Backup:Configure automated backups"
)

# Prod is alias for live
declare -a PROD_STEPS=("${LIVE_STEPS[@]}")

################################################################################
# Step Information Functions
################################################################################

# Get all steps for an environment
# Args: $1 = environment (dev|stage|live|prod)
# Returns: Combined base + environment steps
get_steps_for_env() {
    local env="${1:-dev}"
    local -a all_steps=("${BASE_STEPS[@]}")

    case "$env" in
        dev|development)
            all_steps+=("${DEV_STEPS[@]}")
            ;;
        stage|staging)
            all_steps+=("${STAGE_STEPS[@]}")
            ;;
        live)
            all_steps+=("${LIVE_STEPS[@]}")
            ;;
        prod|production)
            all_steps+=("${PROD_STEPS[@]}")
            ;;
    esac

    printf '%s\n' "${all_steps[@]}"
}

# Get total steps for an environment
# Args: $1 = environment
get_total_steps() {
    local env="${1:-dev}"
    local count=${#BASE_STEPS[@]}

    case "$env" in
        dev|development) count=$((count + ${#DEV_STEPS[@]})) ;;
        stage|staging) count=$((count + ${#STAGE_STEPS[@]})) ;;
        live) count=$((count + ${#LIVE_STEPS[@]})) ;;
        prod|production) count=$((count + ${#PROD_STEPS[@]})) ;;
    esac

    echo "$count"
}

# Get step info by number
# Args: $1 = step number, $2 = environment
# Returns: "key:title:description"
get_step_info() {
    local step_num="$1"
    local env="${2:-dev}"

    while IFS= read -r step; do
        local num="${step%%:*}"
        if [ "$num" = "$step_num" ]; then
            echo "${step#*:}"
            return 0
        fi
    done < <(get_steps_for_env "$env")

    return 1
}

# Get step title by number
# Args: $1 = step number, $2 = environment
get_step_title() {
    local info
    info=$(get_step_info "$1" "$2") || return 1
    echo "$info" | cut -d: -f2
}

# Get step key by number
# Args: $1 = step number, $2 = environment
get_step_key() {
    local info
    info=$(get_step_info "$1" "$2") || return 1
    echo "$info" | cut -d: -f1
}

# Get step description by number
# Args: $1 = step number, $2 = environment
get_step_description() {
    local info
    info=$(get_step_info "$1" "$2") || return 1
    echo "$info" | cut -d: -f3
}

################################################################################
# Progress Tracking Functions
################################################################################

# Get installation status from cnwp.yml
# Args: $1 = site name, $2 = config file
# Returns: step number (0 = not started, -1 = complete)
get_install_step() {
    local site="$1"
    local config_file="${2:-cnwp.yml}"

    [ ! -f "$config_file" ] && echo "0" && return

    local step=$(awk -v site="$site" '
        /^sites:/ { in_sites = 1; next }
        in_sites && /^[a-zA-Z]/ && !/^  / { in_sites = 0 }
        in_sites && $0 ~ "^  " site ":" { in_site = 1; next }
        in_site && /^  [a-zA-Z]/ && !/^    / { in_site = 0 }
        in_site && /^    install_step:/ {
            sub(/^    install_step: */, "")
            gsub(/["'"'"']/, "")
            print
            exit
        }
    ' "$config_file")

    echo "${step:-0}"
}

# Check if installation is complete
# Args: $1 = site name, $2 = config file, $3 = environment
is_install_complete() {
    local site="$1"
    local config_file="${2:-cnwp.yml}"
    local env="${3:-dev}"

    local step=$(get_install_step "$site" "$config_file")
    local total=$(get_total_steps "$env")

    [ "$step" = "-1" ] || [ "$step" -ge "$total" ]
}

# Set installation step in cnwp.yml
# Args: $1 = site name, $2 = step number, $3 = config file
set_install_step() {
    local site="$1"
    local step="$2"
    local config_file="${3:-cnwp.yml}"

    [ ! -f "$config_file" ] && return 1

    # Check if install_step already exists for this site
    if grep -q "^  ${site}:" "$config_file" && \
       awk -v site="$site" '
           /^sites:/ { in_sites = 1; next }
           in_sites && $0 ~ "^  " site ":" { in_site = 1; next }
           in_site && /^  [a-zA-Z]/ && !/^    / { exit 1 }
           in_site && /^    install_step:/ { exit 0 }
       ' "$config_file"; then
        # Update existing install_step
        awk -v site="$site" -v step="$step" '
            /^sites:/ { in_sites = 1; print; next }
            in_sites && /^[a-zA-Z]/ && !/^  / { in_sites = 0 }
            in_sites && $0 ~ "^  " site ":" { in_site = 1; print; next }
            in_site && /^  [a-zA-Z]/ && !/^    / { in_site = 0 }
            in_site && /^    install_step:/ {
                print "    install_step: " step
                next
            }
            { print }
        ' "$config_file" > "${config_file}.tmp" && mv "${config_file}.tmp" "$config_file"
    else
        # Add install_step after other site fields
        awk -v site="$site" -v step="$step" '
            /^sites:/ { in_sites = 1; print; next }
            in_sites && /^[a-zA-Z]/ && !/^  / { in_sites = 0 }
            in_sites && $0 ~ "^  " site ":" { in_site = 1; print; next }
            in_site && /^  [a-zA-Z]/ && !/^    / {
                print "    install_step: " step
                in_site = 0
            }
            { print }
            END {
                if (in_site) print "    install_step: " step
            }
        ' "$config_file" > "${config_file}.tmp" && mv "${config_file}.tmp" "$config_file"
    fi
}

# Mark installation as complete
# Args: $1 = site name, $2 = config file
mark_install_complete() {
    set_install_step "$1" "-1" "$2"
}

################################################################################
# Display Functions
################################################################################

# Check if a site appears to be installed (has DDEV and code)
# Args: $1 = site name, $2 = config file
is_site_actually_installed() {
    local site="$1"
    local config_file="${2:-cnwp.yml}"

    # Get directory from cnwp.yml
    local directory=""
    if command -v get_site_field &>/dev/null; then
        directory=$(get_site_field "$site" "directory" "$config_file" 2>/dev/null)
    fi

    # Fallback to standard location
    if [ -z "$directory" ]; then
        local script_dir="${SCRIPT_DIR:-$(dirname "${BASH_SOURCE[0]}")/..}"
        directory="${script_dir}/sites/${site}"
    fi

    # Check if site has DDEV configured and appears installed
    if [ -d "$directory/.ddev" ] && [ -f "$directory/.ddev/config.yaml" ]; then
        # Check for Drupal installation markers
        if [ -f "$directory/html/sites/default/settings.php" ] || \
           [ -f "$directory/web/sites/default/settings.php" ]; then
            return 0
        fi
    fi
    return 1
}

# Get install status display string
# Args: $1 = site name, $2 = config file, $3 = environment
get_install_status_display() {
    local site="$1"
    local config_file="${2:-cnwp.yml}"
    local env="${3:-dev}"

    local step=$(get_install_step "$site" "$config_file")
    local total=$(get_total_steps "$env")

    if [ "$step" = "-1" ] || [ "$step" -ge "$total" ]; then
        echo "Complete ($total/$total steps)"
    elif [ "$step" = "0" ]; then
        # Check if site is actually installed despite no tracking
        if is_site_actually_installed "$site" "$config_file"; then
            echo "Complete (untracked)"
        else
            echo "Not started"
        fi
    else
        local title=$(get_step_title "$step" "$env")
        echo "Stopped at step $step ($title)"
    fi
}

# Get install status color code
# Args: $1 = site name, $2 = config file, $3 = environment
# Returns: green (complete), yellow (in progress), dim (not started)
get_install_status_color() {
    local site="$1"
    local config_file="${2:-cnwp.yml}"
    local env="${3:-dev}"

    local step=$(get_install_step "$site" "$config_file")
    local total=$(get_total_steps "$env")

    if [ "$step" = "-1" ] || [ "$step" -ge "$total" ]; then
        echo "green"
    elif [ "$step" = "0" ]; then
        # Check if site is actually installed despite no tracking
        if is_site_actually_installed "$site" "$config_file"; then
            echo "green"
        else
            echo "dim"
        fi
    else
        echo "yellow"
    fi
}

# Show detailed steps list
# Args: $1 = site name, $2 = config file, $3 = environment
show_steps_detail() {
    local site="$1"
    local config_file="${2:-cnwp.yml}"
    local env="${3:-dev}"

    local current_step=$(get_install_step "$site" "$config_file")
    local total=$(get_total_steps "$env")

    printf "\n${BOLD:-}Installation Steps for %s (%s):${NC:-}\n" "$site" "$env"
    printf "═══════════════════════════════════════════════════════════════\n"

    local step_num=0
    while IFS= read -r step; do
        step_num="${step%%:*}"
        local rest="${step#*:}"
        local key="${rest%%:*}"
        rest="${rest#*:}"
        local title="${rest%%:*}"
        local desc="${rest#*:}"

        local status_icon
        local status_color

        if [ "$current_step" = "-1" ] || [ "$current_step" -ge "$total" ]; then
            # All complete
            status_icon="✓"
            status_color="${GREEN:-}"
        elif [ "$step_num" -lt "$current_step" ]; then
            # Completed step
            status_icon="✓"
            status_color="${GREEN:-}"
        elif [ "$step_num" = "$current_step" ]; then
            # Current step (stopped here)
            status_icon="▸"
            status_color="${YELLOW:-}"
        else
            # Future step
            status_icon="○"
            status_color="${DIM:-}"
        fi

        printf "%b%s%b %2d. %-15s %s\n" "$status_color" "$status_icon" "${NC:-}" "$step_num" "$title" "$desc"
    done < <(get_steps_for_env "$env")

    printf "═══════════════════════════════════════════════════════════════\n"

    if [ "$current_step" = "-1" ] || [ "$current_step" -ge "$total" ]; then
        printf "${GREEN:-}Installation complete!${NC:-}\n"
    elif [ "$current_step" = "0" ]; then
        printf "${DIM:-}Installation not started${NC:-}\n"
    else
        printf "${YELLOW:-}Stopped at step %d. Resume with: ./install.sh -s=%d %s${NC:-}\n" "$current_step" "$current_step" "$site"
    fi
    printf "\n"
}

# Export functions
export -f get_steps_for_env get_total_steps get_step_info get_step_title
export -f get_step_key get_step_description get_install_step is_install_complete
export -f set_install_step mark_install_complete get_install_status_display
export -f get_install_status_color show_steps_detail is_site_actually_installed
