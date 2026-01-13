#!/bin/bash
set -euo pipefail

################################################################################
# NWP Status Script
#
# Comprehensive status display and site management for NWP
# Usage: ./status.sh [command] [options]
#
# Commands:
#   (none)           Interactive mode (default) with checkboxes
#   health           Run health checks on all sites
#   info <site>      Show detailed info for a specific site
#   delete <site>    Delete a site (with confirmation)
#   start <site>     Start DDEV for a site
#   stop <site>      Stop DDEV for a site
#   restart <site>   Restart DDEV for a site
#
# Options:
#   -r, --recipes    Show only recipes
#   -s, --sites      Show only sites
#   -v, --verbose    Show detailed information
#   -a, --all        Show all details (health, disk, db, etc.)
#   -h, --help       Show this help
#
# Examples:
#   ./status.sh                  - Interactive mode (default)
#   ./status.sh -s               - Text status view
#   ./status.sh -v               - Verbose text status
#   ./status.sh info avc         - Detailed info for 'avc' site
#   ./status.sh delete test-nwp  - Delete test-nwp site
#   ./status.sh start avc        - Start DDEV for avc
################################################################################

# Get script directory and project root
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

# Source shared libraries
source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh"

# Source YAML library if available
if [ -f "$PROJECT_ROOT/lib/yaml-write.sh" ]; then
    source "$PROJECT_ROOT/lib/yaml-write.sh"
fi

# Source install steps library for progress tracking
if [ -f "$PROJECT_ROOT/lib/install-steps.sh" ]; then
    source "$PROJECT_ROOT/lib/install-steps.sh"
fi

# Source Linode library if available
if [ -f "$PROJECT_ROOT/lib/linode.sh" ]; then
    source "$PROJECT_ROOT/lib/linode.sh"
fi

# Configuration
if [ -f "${PROJECT_ROOT}/cnwp.yml" ]; then
    CONFIG_FILE="${PROJECT_ROOT}/cnwp.yml"
elif [ -f "${PROJECT_ROOT}/example.cnwp.yml" ]; then
    CONFIG_FILE="${PROJECT_ROOT}/example.cnwp.yml"
else
    CONFIG_FILE="${PROJECT_ROOT}/cnwp.yml"
fi

################################################################################
# Orphaned and Ghost Site Detection
################################################################################

# Find ghost DDEV registrations (registered in DDEV but directory missing, within nwp folder)
find_ghost_ddev_sites() {
    local project_root="$1"

    # Get DDEV list as JSON and parse it
    local ddev_json
    ddev_json=$(ddev list --json-output 2>/dev/null | grep -o '"raw":\[.*\]' | sed 's/"raw"://') || return

    # Parse JSON to find ghost sites in nwp folder
    # Looking for: approot starts with project_root AND status contains "missing"
    echo "$ddev_json" | grep -o '{[^}]*}' | while read -r entry; do
        local name=$(echo "$entry" | grep -o '"name":"[^"]*"' | cut -d'"' -f4)
        local approot=$(echo "$entry" | grep -o '"approot":"[^"]*"' | cut -d'"' -f4)
        local status=$(echo "$entry" | grep -o '"status":"[^"]*"' | cut -d'"' -f4)

        # Skip if not in nwp folder
        [[ "$approot" != "$project_root"* ]] && continue

        # Skip Router
        [ "$name" = "Router" ] && continue

        # Check if directory is missing
        if [[ "$status" == *"missing"* ]]; then
            echo "$name:$approot:ghost"
        fi
    done
}

# Find site directories that have .ddev but are not in cnwp.yml
find_orphaned_sites() {
    local config_file="$1"
    local script_dir="$2"

    # Get all directories with .ddev in the sites subdirectory
    local ddev_dirs=()
    while IFS= read -r ddev_path; do
        local site_dir=$(dirname "$ddev_path")
        local site_name=$(basename "$site_dir")
        ddev_dirs+=("$site_name:$site_dir")
    done < <(find "$script_dir/sites" -maxdepth 2 -name ".ddev" -type d 2>/dev/null)

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

    if [ -f "$directory/.ddev/config.yaml" ]; then
        local project_type=$(grep "^type:" "$directory/.ddev/config.yaml" 2>/dev/null | awk '{print $2}')
        case "$project_type" in
            drupal*)
                if [ -d "$directory/html/profiles/contrib/social" ]; then
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
# Installation Progress Tracking
################################################################################

# Get installation status with time-based warnings
# Args: $1 = site name, $2 = config file
# Returns: formatted status string with color codes
get_install_progress_display() {
    local site="$1"
    local config_file="${2:-$CONFIG_FILE}"

    # Check if install_step functions are available
    if ! command -v get_install_step &>/dev/null; then
        echo ""
        return
    fi

    local install_step=$(get_install_step "$site" "$config_file")

    # -1 means complete, empty/missing means no tracking
    if [ "$install_step" = "-1" ] || [ -z "$install_step" ]; then
        echo ""
        return
    fi

    # Get environment and total steps
    local environment=$(get_site_field "$site" "environment" "$config_file")
    local total_steps=$(get_total_steps "${environment:-development}")
    local step_title=$(get_step_title "$install_step" "${environment:-development}" 2>/dev/null || echo "unknown")

    # Get created timestamp and calculate elapsed time
    local created=$(get_site_field "$site" "created" "$config_file")
    local elapsed_mins=0

    if [ -n "$created" ]; then
        # Convert ISO 8601 timestamp to seconds since epoch
        local created_epoch=$(date -d "$created" +%s 2>/dev/null || echo "0")
        local now_epoch=$(date +%s)
        if [ "$created_epoch" != "0" ]; then
            elapsed_mins=$(( (now_epoch - created_epoch) / 60 ))
        fi
    fi

    # Determine warning level based on elapsed time
    local color=""
    local suffix=""

    if [ "$elapsed_mins" -lt 20 ]; then
        # Normal - installation probably still running
        color="${CYAN}"
        suffix=""
    elif [ "$elapsed_mins" -lt 30 ]; then
        # First warning at 20 min
        color="${YELLOW}"
        suffix=" (may be stuck)"
    elif [ "$elapsed_mins" -lt 60 ]; then
        # Second warning at 30-60 min
        color="${YELLOW}"
        suffix=" (likely stuck)"
    else
        # Final warning after 60 min
        color="${RED}"
        local hours=$((elapsed_mins / 60))
        if [ "$hours" -ge 1 ]; then
            suffix=" (stale ${hours}h)"
        else
            suffix=" (stale)"
        fi
    fi

    printf "%b%d/%d %s%s%b" "$color" "$install_step" "$total_steps" "$step_title" "$suffix" "${NC}"
}

# Check if a site has an incomplete installation
# Args: $1 = site name, $2 = config file
# Returns: 0 if incomplete, 1 if complete or not tracked
has_incomplete_install() {
    local site="$1"
    local config_file="${2:-$CONFIG_FILE}"

    if ! command -v get_install_step &>/dev/null; then
        return 1
    fi

    local install_step=$(get_install_step "$site" "$config_file")

    # -1 = complete, empty = not tracked
    if [ "$install_step" = "-1" ] || [ -z "$install_step" ]; then
        return 1
    fi

    # Any other value (0 or positive) means incomplete
    return 0
}

################################################################################
# Recipe Type Descriptions
################################################################################

get_recipe_type_desc() {
    local recipe_type="$1"
    case "$recipe_type" in
        drupal|"")  echo "drupal" ;;
        moodle)     echo "moodle" ;;
        gitlab)     echo "gitlab" ;;
        podcast)    echo "podcast" ;;
        migration)  echo "migrate" ;;
        *)          echo "$recipe_type" ;;
    esac
}

################################################################################
# Recipe Functions
################################################################################

list_recipes() {
    local config_file="$1"
    [ ! -f "$config_file" ] && return 1

    awk '
        /^recipes:/ { in_recipes = 1; next }
        in_recipes && /^[a-zA-Z]/ && !/^  / { exit }
        in_recipes && /^  [a-zA-Z_][a-zA-Z0-9_-]*:/ && !/^    / {
            if ($0 ~ /^  #/) next
            name = $0
            gsub(/:.*/, "", name)
            gsub(/^  /, "", name)
            if (name !~ /^#/ && name != "") print name
        }
    ' "$config_file"
}

get_recipe_type() {
    local recipe="$1"
    local config_file="$2"

    local type=$(awk -v recipe="$recipe" '
        /^recipes:/ { in_recipes = 1; next }
        in_recipes && /^[a-zA-Z]/ && !/^  / { exit }
        in_recipes && $0 ~ "^  " recipe ":" { in_recipe = 1; next }
        in_recipe && /^  [a-zA-Z]/ && !/^    / { exit }
        in_recipe && /^    type:/ {
            sub(/^    type: */, "")
            gsub(/["'"'"']/, "")
            sub(/ *#.*$/, "")
            gsub(/^[ \t]+|[ \t]+$/, "")
            print
            exit
        }
    ' "$config_file")

    echo "${type:-drupal}"
}

show_recipes() {
    local config_file="$1"
    local verbose="${2:-false}"

    [ ! -f "$config_file" ] && { print_error "Config not found: $config_file"; return 1; }

    local recipes=$(list_recipes "$config_file")
    [ -z "$recipes" ] && { print_warning "No recipes found"; return 0; }

    echo -e "${BOLD}Recipes:${NC}"

    if [ "$verbose" == "true" ]; then
        echo ""
        while read -r recipe; do
            local type=$(get_recipe_type "$recipe" "$config_file")
            local type_desc=$(get_recipe_type_desc "$type")
            printf "  ${CYAN}%-15s${NC} %s\n" "$recipe" "($type_desc)"
        done <<< "$recipes"
    else
        local first=true
        printf "  "
        while read -r recipe; do
            local type=$(get_recipe_type "$recipe" "$config_file")
            local type_desc=$(get_recipe_type_desc "$type")
            if [ "$first" = true ]; then
                first=false
            else
                printf " | "
            fi
            printf "%b%s%b %s" "$CYAN" "$recipe" "$NC" "$type_desc"
        done <<< "$recipes"
        echo ""
    fi
}

################################################################################
# Site Functions
################################################################################

list_sites() {
    local config_file="$1"
    [ ! -f "$config_file" ] && return 1

    # Use consolidated yaml_get_all_sites function
    yaml_get_all_sites "$config_file"
}

get_site_field() {
    local site="$1"
    local field="$2"
    local config_file="$3"

    # Use consolidated yaml_get_site_field function
    yaml_get_site_field "$site" "$field" "$config_file"
}

get_site_nested_field() {
    local site="$1"
    local section="$2"
    local field="$3"
    local config_file="$4"

    awk -v site="$site" -v section="$section" -v field="$field" '
        /^sites:/ { in_sites = 1; next }
        in_sites && /^[a-zA-Z]/ && !/^  / { exit }
        in_sites && $0 ~ "^  " site ":" { in_site = 1; next }
        in_site && /^  [a-zA-Z]/ && !/^    / { exit }
        in_site && $0 ~ "^    " section ":" { in_section = 1; next }
        in_section && /^    [a-zA-Z]/ && !/^      / { in_section = 0 }
        in_section && $0 ~ "^      " field ":" {
            sub("^      " field ": *", "")
            gsub(/["'"'"']/, "")
            sub(/ *#.*$/, "")
            gsub(/^[ \t]+|[ \t]+$/, "")
            print
            exit
        }
    ' "$config_file"
}

################################################################################
# Status Check Functions
################################################################################

# Get site stages
get_site_stages() {
    local site="$1"
    local config_file="$2"
    local stages=""
    local directory=$(get_site_field "$site" "directory" "$config_file")

    # Dev
    if [ -n "$directory" ] && [ -d "$directory" ]; then
        stages="${stages}${GREEN}d${NC}"
    fi

    # Staging (support both -stg and legacy _stg during migration)
    if [ -d "${directory}-stg" ] || [ -d "${directory}_stg" ]; then
        stages="${stages}${YELLOW}s${NC}"
    fi

    # Live
    local live_enabled=$(get_site_nested_field "$site" "live" "enabled" "$config_file")
    if [ "$live_enabled" == "true" ]; then
        stages="${stages}${BLUE}l${NC}"
    fi

    # Prod (support both -prod and legacy _prod during migration)
    if [ -d "${directory}-prod" ] || [ -d "${directory}_prod" ]; then
        stages="${stages}${RED}p${NC}"
    fi

    echo "${stages:--}"
}

# Get DDEV status for a site
get_ddev_status() {
    local directory="$1"

    if [ ! -d "$directory" ]; then
        echo "${RED}missing${NC}"
        return
    fi

    if [ ! -d "$directory/.ddev" ]; then
        echo "${YELLOW}no-ddev${NC}"
        return
    fi

    # Check if DDEV is running
    local site_name=$(basename "$directory")
    if ddev list 2>/dev/null | grep -q "^${site_name}.*running"; then
        echo "${GREEN}running${NC}"
    elif ddev list 2>/dev/null | grep -q "^${site_name}"; then
        echo "${YELLOW}stopped${NC}"
    else
        echo "${YELLOW}stopped${NC}"
    fi
}

# Get disk usage for a directory
get_disk_usage() {
    local directory="$1"

    if [ ! -d "$directory" ]; then
        echo "-"
        return
    fi

    du -sh "$directory" 2>/dev/null | awk '{print $1}' || echo "?"
}

# Get database size for a site
get_db_size() {
    local directory="$1"
    local site_name=$(basename "$directory")

    if [ ! -d "$directory/.ddev" ]; then
        echo "-"
        return
    fi

    # Check if DDEV is running
    if ! ddev list 2>/dev/null | grep -q "^${site_name}.*running"; then
        echo "-"
        return
    fi

    # Get database size
    local db_size=$(cd "$directory" && ddev mysql -e "SELECT ROUND(SUM(data_length + index_length) / 1024 / 1024, 1) AS 'Size (MB)' FROM information_schema.tables WHERE table_schema = DATABASE();" 2>/dev/null | tail -1)

    if [ -n "$db_size" ] && [ "$db_size" != "NULL" ]; then
        echo "${db_size}M"
    else
        echo "-"
    fi
}

# Get last git commit date
get_last_activity() {
    local directory="$1"

    if [ ! -d "$directory/.git" ] && [ ! -f "$directory/.git" ]; then
        echo "-"
        return
    fi

    local last_commit=$(cd "$directory" && git log -1 --format="%ar" 2>/dev/null)
    echo "${last_commit:-?}"
}

# Health check - ping site URL
check_site_health() {
    local directory="$1"
    local site_name=$(basename "$directory")

    if [ ! -d "$directory/.ddev" ]; then
        echo "${YELLOW}N/A${NC}"
        return
    fi

    # Check if DDEV is running
    if ! ddev list 2>/dev/null | grep -q "^${site_name}.*running"; then
        echo "${YELLOW}stopped${NC}"
        return
    fi

    # Try to curl the site
    local url="https://${site_name}.ddev.site"
    local http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$url" 2>/dev/null || echo "000")

    case "$http_code" in
        200|301|302|303) echo "${GREEN}OK${NC}" ;;
        401|403) echo "${YELLOW}auth${NC}" ;;
        404) echo "${YELLOW}404${NC}" ;;
        500|502|503) echo "${RED}error${NC}" ;;
        000) echo "${RED}down${NC}" ;;
        *) echo "${YELLOW}${http_code}${NC}" ;;
    esac
}

# Check SSL certificate expiry for live sites
check_ssl_expiry() {
    local domain="$1"

    if [ -z "$domain" ]; then
        echo "-"
        return
    fi

    local expiry=$(echo | openssl s_client -servername "$domain" -connect "${domain}:443" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)

    if [ -z "$expiry" ]; then
        echo "${RED}?${NC}"
        return
    fi

    local expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null)
    local now_epoch=$(date +%s)
    local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

    if [ "$days_left" -lt 0 ]; then
        echo "${RED}expired${NC}"
    elif [ "$days_left" -lt 7 ]; then
        echo "${RED}${days_left}d${NC}"
    elif [ "$days_left" -lt 30 ]; then
        echo "${YELLOW}${days_left}d${NC}"
    else
        echo "${GREEN}${days_left}d${NC}"
    fi
}

# Get user count for a site (checks prod, live, stg, dev in order)
get_user_count() {
    local site="$1"
    local config_file="$2"

    local directory=$(get_site_field "$site" "directory" "$config_file")
    local recipe=$(get_site_field "$site" "recipe" "$config_file")

    # Determine which directory to check (prod > live > stg > dev)
    # Support both hyphen and legacy underscore formats during migration
    local check_dir=""
    local env_label=""

    if [ -d "${directory}-prod" ]; then
        check_dir="${directory}-prod"
        env_label="p"
    elif [ -d "${directory}_prod" ]; then
        check_dir="${directory}_prod"
        env_label="p"
    elif [ -d "${directory}-live" ]; then
        check_dir="${directory}-live"
        env_label="l"
    elif [ -d "${directory}_live" ]; then
        check_dir="${directory}_live"
        env_label="l"
    elif [ -d "${directory}-stg" ]; then
        check_dir="${directory}-stg"
        env_label="s"
    elif [ -d "${directory}_stg" ]; then
        check_dir="${directory}_stg"
        env_label="s"
    elif [ -d "$directory" ]; then
        check_dir="$directory"
        env_label="d"
    else
        echo "-"
        return
    fi

    # Check if DDEV is available and running for this directory
    if [ ! -d "$check_dir/.ddev" ]; then
        echo "-"
        return
    fi

    local site_basename=$(basename "$check_dir")
    if ! ddev list 2>/dev/null | grep -q "^${site_basename}.*running"; then
        echo "-"
        return
    fi

    # Get user count based on recipe type
    local count=""
    case "$recipe" in
        drupal|nwp|"")
            # Drupal: count users from database
            count=$(cd "$check_dir" && ddev drush sqlq "SELECT COUNT(*) FROM users_field_data WHERE status=1" 2>/dev/null | tail -1)
            ;;
        moodle)
            # Moodle: count users from database
            count=$(cd "$check_dir" && ddev mysql -N -e "SELECT COUNT(*) FROM mdl_user WHERE deleted=0 AND suspended=0" 2>/dev/null | tail -1)
            ;;
        *)
            echo "-"
            return
            ;;
    esac

    if [ -n "$count" ] && [[ "$count" =~ ^[0-9]+$ ]]; then
        echo "${count}"
    else
        echo "-"
    fi
}

# Get CI status from GitLab
get_ci_status() {
    local site="$1"
    local config_file="$2"

    local ci_enabled=$(get_site_nested_field "$site" "ci" "enabled" "$config_file")

    if [ "$ci_enabled" != "true" ]; then
        echo "-"
        return
    fi

    # Would need GitLab API token to actually check
    echo "${CYAN}enabled${NC}"
}

################################################################################
# Site Display Functions
################################################################################

show_sites() {
    local config_file="$1"
    local verbose="${2:-false}"
    local show_all="${3:-false}"

    [ ! -f "$config_file" ] && { print_error "Config not found: $config_file"; return 1; }

    local sites=$(list_sites "$config_file")
    local orphaned=$(find_orphaned_sites "$config_file" "$PROJECT_ROOT")

    if [ -z "$sites" ] && [ -z "$orphaned" ]; then
        print_info "No sites configured"
        return 0
    fi

    echo -e "\n${BOLD}Sites:${NC}"
    echo ""

    if [ "$show_all" == "true" ]; then
        # Full view with all details
        printf "  ${BOLD}%-16s %-10s %-10s %-12s %-8s %-6s %-6s %-8s %s${NC}\n" \
            "NAME" "RECIPE" "PURPOSE" "STAGES" "DDEV" "DISK" "DB" "HEALTH" "ACTIVITY"
        printf "  %-16s %-10s %-10s %-12s %-8s %-6s %-6s %-8s %s\n" \
            "----------------" "----------" "----------" "------------" "--------" "------" "------" "--------" "--------"

        while read -r site; do
            local recipe=$(get_site_field "$site" "recipe" "$config_file")
            local purpose=$(get_site_field "$site" "purpose" "$config_file")
            local directory=$(get_site_field "$site" "directory" "$config_file")
            local stages=$(get_site_stages "$site" "$config_file")
            local ddev_status=$(get_ddev_status "$directory")
            local disk=$(get_disk_usage "$directory")
            local db_size=$(get_db_size "$directory")
            local health=$(check_site_health "$directory")
            local activity=$(get_last_activity "$directory")

            printf "  ${CYAN}%-16s${NC} %-10s %-10s %-20b %-14b %-6s %-6s %-14b %s\n" \
                "$site" "${recipe:-?}" "${purpose:--}" "$stages" "$ddev_status" "$disk" "$db_size" "$health" "$activity"
        done <<< "$sites"

    elif [ "$verbose" == "true" ]; then
        # Verbose view with purpose and domain
        printf "  ${BOLD}%-18s %-10s %-12s %-15s %s${NC}\n" "NAME" "RECIPE" "PURPOSE" "STATUS" "DOMAIN"
        printf "  %-18s %-10s %-12s %-15s %s\n" "------------------" "----------" "------------" "---------------" "------"

        while read -r site; do
            local recipe=$(get_site_field "$site" "recipe" "$config_file")
            local purpose=$(get_site_field "$site" "purpose" "$config_file")
            local stages=$(get_site_stages "$site" "$config_file")
            local domain=$(get_site_nested_field "$site" "live" "domain" "$config_file")

            # Check for incomplete installation
            local status_display="$stages"
            if has_incomplete_install "$site" "$config_file"; then
                status_display=$(get_install_progress_display "$site" "$config_file")
            fi

            printf "  ${CYAN}%-18s${NC} %-10s %-12s %-30b %s\n" \
                "$site" "${recipe:-?}" "${purpose:--}" "$status_display" "${domain:-}"
        done <<< "$sites"

    else
        # Default compact view with purpose
        printf "  ${BOLD}%-18s %-10s %-12s %s${NC}\n" "NAME" "RECIPE" "PURPOSE" "STAGES"
        printf "  %-18s %-10s %-12s %s\n" "------------------" "----------" "------------" "------"

        while read -r site; do
            local recipe=$(get_site_field "$site" "recipe" "$config_file")
            local purpose=$(get_site_field "$site" "purpose" "$config_file")
            local stages=$(get_site_stages "$site" "$config_file")

            # Check for incomplete installation
            local install_progress=""
            if has_incomplete_install "$site" "$config_file"; then
                install_progress=$(get_install_progress_display "$site" "$config_file")
            fi

            if [ -n "$install_progress" ]; then
                # Show incomplete installation status
                printf "  ${CYAN}%-18s${NC} %-10s %-12s %b\n" "$site" "${recipe:-?}" "${purpose:--}" "$install_progress"
            else
                printf "  ${CYAN}%-18s${NC} %-10s %-12s %b\n" "$site" "${recipe:-?}" "${purpose:--}" "$stages"
            fi
        done <<< "$sites"
    fi

    # Show orphaned sites
    if [ -n "$orphaned" ]; then
        printf "\n  ${YELLOW}Orphaned sites (not in cnwp.yml):${NC}\n"
        while IFS=':' read -r name dir; do
            [ -z "$name" ] && continue
            local recipe=$(detect_recipe_from_site "$dir")
            local stages=""
            [ -d "$dir" ] && stages="${GREEN}d${NC}"
            printf "  ${YELLOW}%-18s${NC} %-10s %-12s %b\n" "$name" "${recipe:-?}" "(orphan)" "$stages"
        done <<< "$orphaned"
    fi

    # Check for incomplete installations and show hint
    local incomplete_count=0
    while read -r site; do
        [ -z "$site" ] && continue
        if has_incomplete_install "$site" "$config_file"; then
            ((incomplete_count++)) || true
        fi
    done <<< "$sites"

    if [ "$incomplete_count" -gt 0 ]; then
        echo ""
        printf "  ${DIM}Tip: Resume stuck installations with: pl setup <site> --resume${NC}\n"
        printf "  ${DIM}     Or delete with: pl delete <site>${NC}\n"
    fi
}

################################################################################
# Detailed Site Info
################################################################################

show_site_info() {
    local site="$1"
    local config_file="$2"

    local directory=$(get_site_field "$site" "directory" "$config_file")

    if [ -z "$directory" ]; then
        print_error "Site '$site' not found in configuration"
        return 1
    fi

    print_header "Site Info: $site"

    echo -e "${BOLD}Basic Info:${NC}"
    printf "  %-20s %s\n" "Name:" "$site"
    printf "  %-20s %s\n" "Recipe:" "$(get_site_field "$site" "recipe" "$config_file")"
    printf "  %-20s %s\n" "Purpose:" "$(get_site_field "$site" "purpose" "$config_file")"
    printf "  %-20s %s\n" "Directory:" "$directory"
    printf "  %-20s %s\n" "Created:" "$(get_site_field "$site" "created" "$config_file")"
    printf "  %-20s %s\n" "Environment:" "$(get_site_field "$site" "environment" "$config_file")"

    echo ""
    echo -e "${BOLD}Stages:${NC}"
    printf "  %-20s %b\n" "Configured:" "$(get_site_stages "$site" "$config_file")"

    # Show installation progress if incomplete
    if has_incomplete_install "$site" "$config_file"; then
        local install_progress=$(get_install_progress_display "$site" "$config_file")
        echo ""
        echo -e "${BOLD}Installation Progress:${NC}"
        printf "  %-20s %b\n" "Status:" "$install_progress"
        printf "  %-20s %s\n" "Resume:" "pl setup $site --resume"
    fi

    echo ""
    echo -e "${BOLD}DDEV Status:${NC}"
    printf "  %-20s %b\n" "Status:" "$(get_ddev_status "$directory")"

    if [ -d "$directory/.ddev" ]; then
        local site_name=$(basename "$directory")
        if ddev list 2>/dev/null | grep -q "^${site_name}.*running"; then
            printf "  %-20s %s\n" "URL:" "https://${site_name}.ddev.site"
        fi
    fi

    echo ""
    echo -e "${BOLD}Storage:${NC}"
    printf "  %-20s %s\n" "Disk Usage:" "$(get_disk_usage "$directory")"
    printf "  %-20s %s\n" "Database Size:" "$(get_db_size "$directory")"

    echo ""
    echo -e "${BOLD}Git:${NC}"
    if [ -d "$directory/.git" ] || [ -f "$directory/.git" ]; then
        local git_branch=$(cd "$directory" && git branch --show-current 2>/dev/null || echo "unknown")
        local git_commit=$(cd "$directory" && git log -1 --format="%ar" 2>/dev/null || echo "unknown")
        printf "  %-20s %s\n" "Branch:" "$git_branch"
        printf "  %-20s %s\n" "Last Commit:" "$git_commit"
    else
        printf "  %-20s %s\n" "Status:" "Not initialized"
    fi

    echo ""
    echo -e "${BOLD}Health:${NC}"
    printf "  %-20s %b\n" "Site Status:" "$(check_site_health "$directory")"

    # Live site info
    local live_enabled=$(get_site_nested_field "$site" "live" "enabled" "$config_file")
    if [ "$live_enabled" == "true" ]; then
        local domain=$(get_site_nested_field "$site" "live" "domain" "$config_file")
        local server_ip=$(get_site_nested_field "$site" "live" "server_ip" "$config_file")

        echo ""
        echo -e "${BOLD}Live Deployment:${NC}"
        printf "  %-20s %s\n" "Enabled:" "Yes"
        printf "  %-20s %s\n" "Domain:" "${domain:-N/A}"
        printf "  %-20s %s\n" "Server IP:" "${server_ip:-N/A}"
        printf "  %-20s %b\n" "SSL Expiry:" "$(check_ssl_expiry "$domain")"
    fi

    # CI info
    local ci_enabled=$(get_site_nested_field "$site" "ci" "enabled" "$config_file")
    if [ "$ci_enabled" == "true" ]; then
        local ci_repo=$(get_site_nested_field "$site" "ci" "repo" "$config_file")
        echo ""
        echo -e "${BOLD}CI/CD:${NC}"
        printf "  %-20s %s\n" "Enabled:" "Yes"
        printf "  %-20s %s\n" "Repository:" "${ci_repo:-N/A}"
    fi

    echo ""
}

################################################################################
# Health Check Command
################################################################################

run_health_checks() {
    local config_file="$1"

    print_header "Health Checks"

    local sites=$(list_sites "$config_file")
    [ -z "$sites" ] && { print_info "No sites configured"; return 0; }

    printf "  ${BOLD}%-18s %-10s %-10s %-10s %s${NC}\n" "SITE" "DDEV" "HEALTH" "SSL" "NOTES"
    printf "  %-18s %-10s %-10s %-10s %s\n" "------------------" "----------" "----------" "----------" "-----"

    while read -r site; do
        local directory=$(get_site_field "$site" "directory" "$config_file")
        local ddev_status=$(get_ddev_status "$directory")
        local health=$(check_site_health "$directory")
        local domain=$(get_site_nested_field "$site" "live" "domain" "$config_file")
        local ssl_status=$(check_ssl_expiry "$domain")
        local notes=""

        # Add notes for issues
        if [[ "$ddev_status" == *"missing"* ]]; then
            notes="directory missing"
        elif [[ "$health" == *"down"* ]] || [[ "$health" == *"error"* ]]; then
            notes="needs attention"
        fi

        printf "  ${CYAN}%-18s${NC} %-16b %-16b %-16b %s\n" \
            "$site" "$ddev_status" "$health" "$ssl_status" "$notes"
    done <<< "$sites"

    echo ""
}

################################################################################
# Site Management Commands
################################################################################

# Delete a site
delete_site() {
    local site="$1"
    local config_file="$2"
    local force="${3:-false}"

    local directory=$(get_site_field "$site" "directory" "$config_file")
    local delete_success=true

    if [ -z "$directory" ]; then
        print_error "Site '$site' not found in configuration"
        return 1
    fi

    print_header "Delete Site: $site"

    echo -e "${BOLD}Site Details:${NC}"
    printf "  %-15s %s\n" "Name:" "$site"
    printf "  %-15s %s\n" "Directory:" "$directory"
    printf "  %-15s %s\n" "Recipe:" "$(get_site_field "$site" "recipe" "$config_file")"
    printf "  %-15s %s\n" "Purpose:" "$(get_site_field "$site" "purpose" "$config_file")"
    printf "  %-15s %s\n" "Disk Usage:" "$(get_disk_usage "$directory")"
    echo ""

    # Check for related directories (support both -stg/-prod and legacy _stg/_prod)
    local related_dirs=""
    [ -d "${directory}-stg" ] && related_dirs="${related_dirs} ${directory}-stg"
    [ -d "${directory}_stg" ] && related_dirs="${related_dirs} ${directory}_stg"
    [ -d "${directory}-prod" ] && related_dirs="${related_dirs} ${directory}-prod"
    [ -d "${directory}_prod" ] && related_dirs="${related_dirs} ${directory}_prod"

    if [ -n "$related_dirs" ]; then
        print_warning "Related directories found:$related_dirs"
        echo ""
    fi

    if [ "$force" != "true" ]; then
        echo -e "${RED}${BOLD}WARNING: This action cannot be undone!${NC}"
        echo ""
        if ! ask_yes_no "Are you sure you want to delete '$site'?" "n"; then
            print_info "Deletion cancelled"
            return 0
        fi
    fi

    echo ""
    print_info "Deleting site '$site'..."

    # Stop DDEV if running (trap errors to ensure cleanup continues)
    if [ -d "$directory/.ddev" ]; then
        print_status "INFO" "Stopping DDEV..."
        if ! (cd "$directory" && ddev stop 2>/dev/null); then
            print_status "WARN" "DDEV stop failed (continuing anyway)"
        fi
        print_status "INFO" "Removing DDEV project..."
        if ! (cd "$directory" && ddev delete -O -y 2>/dev/null); then
            print_status "WARN" "DDEV delete failed (continuing anyway)"
        fi
    fi

    # Remove directory
    if [ -d "$directory" ]; then
        print_status "INFO" "Removing directory: $directory"
        if rm -rf "$directory"; then
            print_status "OK" "Directory removed"
        else
            print_status "FAIL" "Failed to remove directory"
            delete_success=false
        fi
    else
        print_status "INFO" "Directory already removed"
    fi

    # Always try to remove from cnwp.yml (critical step)
    if command -v yaml_remove_site &>/dev/null; then
        print_status "INFO" "Removing from cnwp.yml..."
        if yaml_remove_site "$site" "$config_file" 2>/dev/null; then
            print_status "OK" "Removed from configuration"
        else
            print_status "WARN" "Site may not exist in configuration"
        fi
    else
        print_warning "Cannot remove from cnwp.yml (yaml-write.sh not available)"
        print_info "Manually remove the '$site' entry from cnwp.yml"
        delete_success=false
    fi

    echo ""
    if [ "$delete_success" = true ]; then
        print_status "OK" "Site '$site' has been deleted"
    else
        print_status "WARN" "Site '$site' deleted with warnings"
    fi
    echo ""
}

# Start DDEV for a site
start_site() {
    local site="$1"
    local config_file="$2"

    local directory=$(get_site_field "$site" "directory" "$config_file")

    if [ -z "$directory" ]; then
        print_error "Site '$site' not found in configuration"
        return 1
    fi

    if [ ! -d "$directory" ]; then
        print_error "Directory does not exist: $directory"
        return 1
    fi

    if [ ! -d "$directory/.ddev" ]; then
        print_error "Not a DDEV project: $directory"
        return 1
    fi

    print_info "Starting DDEV for '$site'..."
    (cd "$directory" && ddev start)
    print_status "OK" "Site '$site' is now running"
    echo ""
    print_info "URL: https://${site}.ddev.site"
}

# Stop DDEV for a site
stop_site() {
    local site="$1"
    local config_file="$2"

    local directory=$(get_site_field "$site" "directory" "$config_file")

    if [ -z "$directory" ]; then
        print_error "Site '$site' not found in configuration"
        return 1
    fi

    if [ ! -d "$directory/.ddev" ]; then
        print_error "Not a DDEV project: $directory"
        return 1
    fi

    print_info "Stopping DDEV for '$site'..."
    (cd "$directory" && ddev stop)
    print_status "OK" "Site '$site' has been stopped"
}

# Restart DDEV for a site
restart_site() {
    local site="$1"
    local config_file="$2"

    local directory=$(get_site_field "$site" "directory" "$config_file")

    if [ -z "$directory" ]; then
        print_error "Site '$site' not found in configuration"
        return 1
    fi

    if [ ! -d "$directory/.ddev" ]; then
        print_error "Not a DDEV project: $directory"
        return 1
    fi

    print_info "Restarting DDEV for '$site'..."
    (cd "$directory" && ddev restart)
    print_status "OK" "Site '$site' has been restarted"
}

################################################################################
# Production Status Dashboard
################################################################################

show_production_dashboard() {
    local config_file="$1"

    echo ""
    echo "╔═══════════════════════════════════════════════════════════════════════════════╗"
    echo "║                           NWP Production Status                                ║"
    echo "╠═══════════════════════════════════════════════════════════════════════════════╣"
    printf "║ %-12s │ %-8s │ %-10s │ %-14s │ %-12s │ %-10s ║\n" \
        "Site" "Status" "Response" "Last Deploy" "Backup Age" "SSL"
    echo "╠═══════════════════════════════════════════════════════════════════════════════╣"

    local sites=$(list_sites "$config_file")
    local has_production=false

    while read -r site; do
        local live_enabled=$(get_site_nested_field "$site" "live" "enabled" "$config_file")
        [ "$live_enabled" != "true" ] && continue

        has_production=true

        local domain=$(get_site_nested_field "$site" "live" "domain" "$config_file")
        local server_ip=$(get_site_nested_field "$site" "live" "server_ip" "$config_file")

        # Status check
        local status="${RED}DOWN${NC}"
        local response="-"
        if [ -n "$domain" ]; then
            local http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "https://${domain}" 2>/dev/null || echo "000")
            local response_time=$(curl -s -o /dev/null -w "%{time_total}" --max-time 5 "https://${domain}" 2>/dev/null || echo "0")

            case "$http_code" in
                200|301|302) status="${GREEN}UP${NC}" ;;
                401|403) status="${YELLOW}AUTH${NC}" ;;
                500|502|503) status="${RED}ERROR${NC}" ;;
                000) status="${RED}DOWN${NC}" ;;
                *) status="${YELLOW}${http_code}${NC}" ;;
            esac

            response="${response_time}s"
        fi

        # Last deploy (from audit log if available)
        local last_deploy="-"
        if [ -n "$server_ip" ]; then
            # Would need SSH access to check /var/log/nwp/deployments.jsonl
            last_deploy="N/A"
        fi

        # Backup age
        local backup_age="-"
        local backup_dir="${PROJECT_ROOT}/sitebackups/${site}"
        if [ -d "$backup_dir" ]; then
            local latest_backup=$(ls -t "$backup_dir"/*.sql.gz 2>/dev/null | head -1)
            if [ -n "$latest_backup" ]; then
                local backup_time=$(stat -c %Y "$latest_backup" 2>/dev/null || stat -f %m "$latest_backup" 2>/dev/null)
                if [ -n "$backup_time" ]; then
                    local now=$(date +%s)
                    local age_hours=$(( (now - backup_time) / 3600 ))
                    if [ $age_hours -lt 24 ]; then
                        backup_age="${age_hours}h"
                    else
                        local age_days=$(( age_hours / 24 ))
                        backup_age="${age_days}d"
                    fi
                fi
            fi
        fi

        # SSL expiry
        local ssl_status=$(check_ssl_expiry "$domain")

        printf "║ %-12s │ %-14b │ %-10s │ %-14s │ %-12s │ %-16b ║\n" \
            "$site" "$status" "$response" "$last_deploy" "$backup_age" "$ssl_status"
    done <<< "$sites"

    if [ "$has_production" = false ]; then
        printf "║ %-78s ║\n" "No production sites configured (add live.enabled: true to cnwp.yml)"
    fi

    echo "╚═══════════════════════════════════════════════════════════════════════════════╝"
    echo ""

    # Quick stats
    echo -e "${BOLD}Quick Stats:${NC}"
    local total_sites=$(echo "$sites" | wc -l)
    local prod_sites=$(echo "$sites" | while read -r s; do
        local enabled=$(get_site_nested_field "$s" "live" "enabled" "$config_file")
        [ "$enabled" = "true" ] && echo "$s"
    done | wc -l)
    printf "  Total sites: %d | Production sites: %d\n" "$total_sites" "$prod_sites"

    # Check for recent backups
    local backup_count=0
    local stale_backup_count=0
    for site in $(echo "$sites"); do
        local backup_dir="${PROJECT_ROOT}/sitebackups/${site}"
        if [ -d "$backup_dir" ]; then
            local latest=$(ls -t "$backup_dir"/*.sql.gz 2>/dev/null | head -1)
            if [ -n "$latest" ]; then
                backup_count=$((backup_count + 1))
                local backup_time=$(stat -c %Y "$latest" 2>/dev/null || stat -f %m "$latest" 2>/dev/null)
                local now=$(date +%s)
                local age_hours=$(( (now - backup_time) / 3600 ))
                [ $age_hours -gt 48 ] && stale_backup_count=$((stale_backup_count + 1))
            fi
        fi
    done
    printf "  Sites with backups: %d | Stale backups (>48h): %d\n" "$backup_count" "$stale_backup_count"
    echo ""
}

################################################################################
# Linode Server Stats
################################################################################

show_server_stats() {
    local config_file="$1"

    print_header "Server Statistics"

    # Check if we have Linode API access
    local token=""
    if command -v get_linode_token &>/dev/null; then
        token=$(get_linode_token "$PROJECT_ROOT")
    fi

    if [ -z "$token" ]; then
        print_warning "Linode API token not configured"
        print_info "Add linode.api_token to .secrets.yml for server stats"
        return 0
    fi

    print_info "Fetching Linode stats..."

    # Get list of instances
    local response=$(curl -s -H "Authorization: Bearer $token" \
        "https://api.linode.com/v4/linode/instances" 2>/dev/null)

    if ! echo "$response" | grep -q '"data"'; then
        print_error "Failed to fetch Linode data"
        return 1
    fi

    echo ""
    printf "  ${BOLD}%-20s %-12s %-10s %-15s %s${NC}\n" "LABEL" "STATUS" "REGION" "IP" "TYPE"
    printf "  %-20s %-12s %-10s %-15s %s\n" "--------------------" "------------" "----------" "---------------" "----"

    echo "$response" | grep -o '{[^{}]*"label"[^{}]*}' | while read -r instance; do
        local label=$(echo "$instance" | grep -o '"label":"[^"]*"' | cut -d'"' -f4)
        local status=$(echo "$instance" | grep -o '"status":"[^"]*"' | cut -d'"' -f4)
        local region=$(echo "$instance" | grep -o '"region":"[^"]*"' | cut -d'"' -f4)
        local ip=$(echo "$instance" | grep -o '"ipv4":\["[^"]*"' | cut -d'"' -f4)
        local type=$(echo "$instance" | grep -o '"type":"[^"]*"' | cut -d'"' -f4)

        local status_color="${YELLOW}"
        [ "$status" == "running" ] && status_color="${GREEN}"
        [ "$status" == "offline" ] && status_color="${RED}"

        printf "  ${CYAN}%-20s${NC} ${status_color}%-12s${NC} %-10s %-15s %s\n" \
            "$label" "$status" "$region" "$ip" "$type"
    done

    echo ""
}

################################################################################
# Interactive Mode - Single Screen TUI
################################################################################

# Actions available
ACTIONS=("info" "start" "stop" "restart" "health" "delete" "refresh" "setup")
ACTION_LABELS=("Info" "Start" "Stop" "Restart" "Health" "Delete" "Refresh" "Setup")

# Column definitions: key|header|min_width
# Available columns for display
ALL_COLUMNS=(
    "name|NAME|4"
    "recipe|RECIPE|6"
    "stages|STG|3"
    "ddev|DDEV|4"
    "purpose|PURPOSE|7"
    "disk|DISK|4"
    "domain|DOMAIN|6"
    "users|USERS|5"
    "db|DB|2"
    "health|HEALTH|6"
    "activity|ACTIVITY|8"
    "ssl|SSL|3"
    "ci|CI|2"
)

# Default visible columns
DEFAULT_COLUMNS=("name" "recipe" "stages" "ddev" "purpose" "disk" "domain")

# Current visible columns (will be populated from settings or defaults)
VISIBLE_COLUMNS=()

# Column widths (calculated dynamically)
declare -A COLUMN_WIDTHS

# Settings file
SETTINGS_FILE="${PROJECT_ROOT}/.status-settings"

# Load column settings
load_column_settings() {
    VISIBLE_COLUMNS=()
    if [ -f "$SETTINGS_FILE" ]; then
        while IFS= read -r col; do
            [ -n "$col" ] && VISIBLE_COLUMNS+=("$col")
        done < "$SETTINGS_FILE"
    fi

    # Use defaults if no settings or empty
    if [ ${#VISIBLE_COLUMNS[@]} -eq 0 ]; then
        VISIBLE_COLUMNS=("${DEFAULT_COLUMNS[@]}")
    fi
}

# Save column settings
save_column_settings() {
    printf "%s\n" "${VISIBLE_COLUMNS[@]}" > "$SETTINGS_FILE"
}

# Get column header by key
get_column_header() {
    local key="$1"
    for col in "${ALL_COLUMNS[@]}"; do
        IFS='|' read -r k header min <<< "$col"
        [ "$k" = "$key" ] && { echo "$header"; return; }
    done
    echo "$key"
}

# Get column min width by key
get_column_min_width() {
    local key="$1"
    for col in "${ALL_COLUMNS[@]}"; do
        IFS='|' read -r k header min <<< "$col"
        [ "$k" = "$key" ] && { echo "$min"; return; }
    done
    echo "4"
}

# Calculate column widths based on data
calculate_column_widths() {
    COLUMN_WIDTHS=()

    # Start with header widths
    for key in "${VISIBLE_COLUMNS[@]}"; do
        local header=$(get_column_header "$key")
        local min=$(get_column_min_width "$key")
        local header_len=${#header}
        [ $header_len -gt $min ] && COLUMN_WIDTHS[$key]=$header_len || COLUMN_WIDTHS[$key]=$min
    done

    # Check each site's data
    local row=0
    for site in "${SITE_NAMES[@]}"; do
        # Parse all fields: recipe|stages|ddev|purpose|disk|domain|users|db|health|activity|ssl|ci
        IFS='|' read -r recipe stages ddev purpose disk domain users db health activity ssl ci <<< "${SITE_DATA[$row]}"

        # Update widths based on data values
        for key in "${VISIBLE_COLUMNS[@]}"; do
            local value=""
            case "$key" in
                name) value="$site" ;;
                recipe) value="$recipe" ;;
                stages) value="$stages" ;;
                ddev) value="$ddev" ;;
                purpose) value="$purpose" ;;
                disk) value="$disk" ;;
                domain) value="$domain" ;;
                users) value="$users" ;;
                db) value="$db" ;;
                health) value="$health" ;;
                activity) value="$activity" ;;
                ssl) value="$ssl" ;;
                ci) value="$ci" ;;
            esac

            local val_len=${#value}
            [ $val_len -gt ${COLUMN_WIDTHS[$key]} ] && COLUMN_WIDTHS[$key]=$val_len
        done

        row=$((row + 1))
    done

    # Add padding
    for key in "${!COLUMN_WIDTHS[@]}"; do
        COLUMN_WIDTHS[$key]=$((${COLUMN_WIDTHS[$key]} + 1))
    done
}

# Read single keypress
read_key() {
    local key
    IFS= read -rsn1 key
    if [[ $key == $'\x1b' ]]; then
        read -rsn2 -t 0.1 rest
        case "$rest" in
            '[A') echo "UP" ;;
            '[B') echo "DOWN" ;;
            '[C') echo "RIGHT" ;;
            '[D') echo "LEFT" ;;
            *) echo "ESC" ;;
        esac
    elif [[ $key == $'\t' ]]; then
        echo "TAB"
    elif [[ $key == "" ]]; then
        echo "ENTER"
    elif [[ $key == " " ]]; then
        echo "SPACE"
    else
        echo "$key"
    fi
}

# Move cursor
cursor_to() { printf "\033[%d;%dH" "$1" "$2"; }
cursor_hide() { printf "\033[?25l"; }
cursor_show() { printf "\033[?25h"; }
clear_screen() { printf "\033[2J\033[H"; }
clear_line() { printf "\033[2K"; }

# Draw the interactive screen
draw_screen() {
    local current_row="$1"
    local current_action="$2"

    clear_screen

    # Header
    printf "${BOLD}NWP Status${NC}  |  "
    printf "↑↓:Sites  ←→:Action  SPACE:Select  ENTER:Run  a:All  n:None  r:Refresh  s:Setup  q:Quit\n"
    printf "═══════════════════════════════════════════════════════════════════════════════\n"

    # Build dynamic column header
    printf "${BOLD}   "
    for key in "${VISIBLE_COLUMNS[@]}"; do
        local header=$(get_column_header "$key")
        local width=${COLUMN_WIDTHS[$key]:-8}
        printf "%-${width}s " "$header"
    done
    printf "${NC}\n"

    # Dynamic separator line
    local sep_len=3  # For "   " prefix
    for key in "${VISIBLE_COLUMNS[@]}"; do
        local width=${COLUMN_WIDTHS[$key]:-8}
        sep_len=$((sep_len + width + 1))
    done
    printf "%0.s─" $(seq 1 $sep_len)
    printf "\n"

    # Sites
    local row=0
    for site in "${SITE_NAMES[@]}"; do
        # Parse cached data: recipe|stages|ddev|purpose|disk|domain|users|db|health|activity|ssl|ci
        IFS='|' read -r recipe stages ddev purpose disk domain users db health activity ssl ci <<< "${SITE_DATA[$row]}"

        # Colorize stages
        local colored_stages=""
        [[ "$stages" == *d* ]] && colored_stages="${colored_stages}${GREEN}d${NC}"
        [[ "$stages" == *s* ]] && colored_stages="${colored_stages}${YELLOW}s${NC}"
        [[ "$stages" == *l* ]] && colored_stages="${colored_stages}${BLUE}l${NC}"
        [[ "$stages" == *p* ]] && colored_stages="${colored_stages}${RED}p${NC}"
        [ -z "$colored_stages" ] && colored_stages="-"

        # Colorize DDEV
        local colored_ddev="$ddev"
        [ "$ddev" = "run" ] && colored_ddev="${GREEN}run${NC}"
        [ "$ddev" = "stop" ] && colored_ddev="${YELLOW}stop${NC}"
        [ "$ddev" = "ghost" ] && colored_ddev="${RED}ghost${NC}"

        # Colorize health
        local colored_health="$health"
        [ "$health" = "OK" ] && colored_health="${GREEN}OK${NC}"
        [[ "$health" == "down"* ]] && colored_health="${RED}${health}${NC}"
        [[ "$health" == "error"* ]] && colored_health="${RED}${health}${NC}"

        # Colorize CI
        local colored_ci="$ci"
        [ "$ci" = "on" ] && colored_ci="${GREEN}on${NC}"

        # Checkbox
        local checkbox="[ ]"
        [ "${SITE_SELECTED[$row]}" = "1" ] && checkbox="[${GREEN}✓${NC}]"

        # Highlight current row
        if [ $row -eq $current_row ]; then
            printf "${BOLD}>${NC}"
        else
            printf " "
        fi

        printf "%b " "$checkbox"

        # Print each visible column dynamically
        for key in "${VISIBLE_COLUMNS[@]}"; do
            local width=${COLUMN_WIDTHS[$key]:-8}
            local value=""
            local use_color=false
            local color_value=""

            case "$key" in
                name)
                    value="$site"
                    ;;
                recipe)
                    value="$recipe"
                    ;;
                stages)
                    value="$stages"
                    use_color=true
                    color_value="$colored_stages"
                    ;;
                ddev)
                    value="$ddev"
                    use_color=true
                    color_value="$colored_ddev"
                    ;;
                purpose)
                    value="$purpose"
                    ;;
                disk)
                    value="$disk"
                    ;;
                domain)
                    value="$domain"
                    ;;
                users)
                    value="$users"
                    ;;
                db)
                    value="$db"
                    ;;
                health)
                    value="$health"
                    use_color=true
                    color_value="$colored_health"
                    ;;
                activity)
                    value="$activity"
                    ;;
                ssl)
                    value="$ssl"
                    ;;
                ci)
                    value="$ci"
                    use_color=true
                    color_value="$colored_ci"
                    ;;
            esac

            if [ "$use_color" = true ]; then
                # Calculate padding for colored output (ANSI codes don't count toward width)
                local plain_len=${#value}
                local pad=$((width - plain_len))
                printf "%b%*s " "$color_value" "$pad" ""
            else
                printf "%-${width}s " "$value"
            fi
        done
        printf "\n"

        row=$((row + 1))
    done

    # Footer separator
    printf "%0.s─" $(seq 1 $sep_len)
    printf "\n"

    # Actions
    printf "Action: "
    local i=0
    for label in "${ACTION_LABELS[@]}"; do
        if [ $i -eq $current_action ]; then
            printf "${BOLD}${GREEN}[%s]${NC} " "$label"
        else
            printf " %s  " "$label"
        fi
        i=$((i + 1))
    done

    # Count selected
    local selected_count=0
    for sel in "${SITE_SELECTED[@]}"; do
        if [ "$sel" = "1" ]; then
            selected_count=$((selected_count + 1))
        fi
    done
    printf "  (${CYAN}%d selected${NC})\n" "$selected_count"
}

# Draw the setup screen for column selection
draw_setup_screen() {
    local current_row="$1"

    clear_screen

    printf "${BOLD}Column Setup${NC}  |  "
    printf "↑↓:Navigate  SPACE:Toggle  a:All  n:None  ENTER:Save  q:Cancel\n"
    printf "═══════════════════════════════════════════════════════════════════════════════\n"
    printf "\n"
    printf "Select which columns to display:\n\n"

    local row=0
    for col_def in "${ALL_COLUMNS[@]}"; do
        IFS='|' read -r key header min <<< "$col_def"

        # Check if column is currently visible
        local is_visible=false
        for vcol in "${VISIBLE_COLUMNS[@]}"; do
            [ "$vcol" = "$key" ] && { is_visible=true; break; }
        done

        # Checkbox
        local checkbox="[ ]"
        [ "$is_visible" = true ] && checkbox="[${GREEN}✓${NC}]"

        # Highlight current row
        if [ $row -eq $current_row ]; then
            printf "  ${BOLD}>${NC} "
        else
            printf "    "
        fi

        printf "%b %s (%s)\n" "$checkbox" "$header" "$key"

        row=$((row + 1))
    done

    printf "\n"
    printf "───────────────────────────────────────────────────────────────────────────────\n"
    printf "${CYAN}Tip:${NC} At least one column must remain visible.\n"
}

# Run setup mode for column selection
run_setup_mode() {
    local num_cols=${#ALL_COLUMNS[@]}
    local current_row=0

    # Create working copy of visible columns
    local -a temp_visible=("${VISIBLE_COLUMNS[@]}")

    while true; do
        # Temporarily set VISIBLE_COLUMNS for display check
        VISIBLE_COLUMNS=("${temp_visible[@]}")

        draw_setup_screen $current_row

        local key=$(read_key)

        case "$key" in
            "UP"|"k")
                [ $current_row -gt 0 ] && current_row=$((current_row - 1)) || true
                ;;
            "DOWN"|"j")
                [ $current_row -lt $((num_cols - 1)) ] && current_row=$((current_row + 1)) || true
                ;;
            "SPACE")
                # Get current column key
                IFS='|' read -r col_key col_header col_min <<< "${ALL_COLUMNS[$current_row]}"

                # Check if column is in temp_visible
                local found_idx=-1
                local idx=0
                for vcol in "${temp_visible[@]}"; do
                    if [ "$vcol" = "$col_key" ]; then
                        found_idx=$idx
                        break
                    fi
                    idx=$((idx + 1))
                done

                if [ $found_idx -ge 0 ]; then
                    # Remove column (but ensure at least one remains)
                    if [ ${#temp_visible[@]} -gt 1 ]; then
                        unset 'temp_visible[found_idx]'
                        # Rebuild array to remove gap
                        temp_visible=("${temp_visible[@]}")
                    fi
                else
                    # Add column
                    temp_visible+=("$col_key")
                fi
                ;;
            "a"|"A")
                # Select all columns
                temp_visible=()
                for col_def in "${ALL_COLUMNS[@]}"; do
                    IFS='|' read -r col_key col_header col_min <<< "$col_def"
                    temp_visible+=("$col_key")
                done
                ;;
            "n"|"N")
                # Select none (keep only first column - name)
                temp_visible=("name")
                ;;
            "ENTER")
                # Save and exit
                VISIBLE_COLUMNS=("${temp_visible[@]}")
                save_column_settings
                return 0
                ;;
            "q"|"Q"|"ESC")
                # Cancel - restore original
                load_column_settings
                return 1
                ;;
        esac
    done
}

# Execute action on selected sites
run_action() {
    local action="$1"
    local config_file="$2"
    shift 2
    local sites=("$@")

    # Setup doesn't need selected sites
    if [ "$action" = "setup" ]; then
        run_setup_mode
        calculate_column_widths
        return
    fi

    # Refresh doesn't need selected sites
    if [ "$action" = "refresh" ]; then
        printf "\n${CYAN}Refreshing...${NC}\n"
        build_site_cache "$config_file"
        calculate_column_widths
        return
    fi

    if [ ${#sites[@]} -eq 0 ]; then
        printf "\n${YELLOW}No sites selected${NC}\n"
        read -p "Press Enter to continue..."
        return
    fi

    printf "\n"

    case "$action" in
        info)
            for site in "${sites[@]}"; do
                show_site_info "$site" "$config_file"
            done
            ;;
        start)
            for site in "${sites[@]}"; do
                print_info "Starting $site..."
                start_site "$site" "$config_file" 2>&1 || true
            done
            ;;
        stop)
            for site in "${sites[@]}"; do
                print_info "Stopping $site..."
                stop_site "$site" "$config_file" 2>&1 || true
            done
            ;;
        restart)
            for site in "${sites[@]}"; do
                print_info "Restarting $site..."
                restart_site "$site" "$config_file" 2>&1 || true
            done
            ;;
        health)
            for site in "${sites[@]}"; do
                local directory=$(get_site_field "$site" "directory" "$config_file")
                printf "${BOLD}%s:${NC} " "$site"
                printf "DDEV=%b " "$(get_ddev_status "$directory")"
                printf "Health=%b " "$(check_site_health "$directory")"
                local domain=$(get_site_nested_field "$site" "live" "domain" "$config_file")
                [ -n "$domain" ] && printf "SSL=%b" "$(check_ssl_expiry "$domain")"
                printf "\n"
            done
            ;;
        delete)
            print_warning "About to delete: ${sites[*]}"
            if ask_yes_no "Are you sure?" "n"; then
                for site in "${sites[@]}"; do
                    # Find site type from global array
                    local site_idx=-1
                    for i in "${!SITE_NAMES[@]}"; do
                        if [ "${SITE_NAMES[$i]}" = "$site" ]; then
                            site_idx=$i
                            break
                        fi
                    done

                    local site_type="${SITE_TYPE[$site_idx]:-0}"

                    if [ "$site_type" = "2" ]; then
                        # Ghost site - just unlist from DDEV
                        print_info "Unlisting ghost DDEV project: $site"
                        ddev stop --unlist "$site" 2>&1 || true
                        print_status "OK" "Ghost site '$site' removed from DDEV"
                    else
                        # Normal or orphan site - use full delete
                        delete_site "$site" "$config_file" "true"
                    fi
                done
            else
                print_info "Cancelled"
            fi
            ;;
    esac

    printf "\n"
    read -p "Press Enter to continue..."
}

# Global arrays for interactive mode
SITE_NAMES=()
SITE_SELECTED=()
SITE_TYPE=()  # 0=normal, 1=orphan, 2=ghost
SITE_DATA=()  # Cached display data

# Build cached site data
build_site_cache() {
    local config_file="$1"
    SITE_DATA=()

    # Get DDEV list once for all sites (expensive operation)
    local ddev_list=""
    ddev_list=$(ddev list 2>/dev/null) || true

    local idx=0
    for site in "${SITE_NAMES[@]}"; do
        local site_type="${SITE_TYPE[$idx]:-0}"
        local recipe=""
        local purpose=""
        local directory=""
        local domain=""

        if [ "$site_type" = "2" ]; then
            # Ghost site - registered in DDEV but directory missing
            directory=""
            recipe="?"
            purpose="(ghost)"
        elif [ "$site_type" = "1" ]; then
            # Orphaned site - get info from filesystem
            directory="$PROJECT_ROOT/sites/$site"
            recipe=$(detect_recipe_from_site "$directory")
            purpose="(orphan)"
        else
            # Normal site - get info from cnwp.yml
            recipe=$(get_site_field "$site" "recipe" "$config_file")
            purpose=$(get_site_field "$site" "purpose" "$config_file")
            directory=$(get_site_field "$site" "directory" "$config_file")
            # If directory is not absolute and doesn't start with sites/, prefix with sites/
            if [[ "$directory" != /* ]] && [[ "$directory" != sites/* ]]; then
                directory="sites/$directory"
            fi
            domain=$(get_site_nested_field "$site" "live" "domain" "$config_file")
        fi

        # Stages (support both hyphen and legacy underscore formats during migration)
        local stages=""
        if [ "$site_type" = "2" ]; then
            stages="-"
        else
            [ -n "$directory" ] && [ -d "$directory" ] && stages="${stages}d"
            [ -d "${directory}-stg" ] || [ -d "${directory}_stg" ] && stages="${stages}s"
            if [ "$site_type" = "0" ]; then
                local live_enabled=$(get_site_nested_field "$site" "live" "enabled" "$config_file")
                [ "$live_enabled" == "true" ] && stages="${stages}l"
            fi
            [ -d "${directory}-prod" ] || [ -d "${directory}_prod" ] && stages="${stages}p"
            [ -z "$stages" ] && stages="-"
        fi

        # DDEV status (use cached list)
        local ddev="-"
        if [ "$site_type" = "2" ]; then
            ddev="ghost"
        elif [ -n "$directory" ] && [ -d "$directory/.ddev" ]; then
            local site_basename=$(basename "$directory")
            if echo "$ddev_list" | grep -q "^${site_basename}.*running"; then
                ddev="run"
            else
                ddev="stop"
            fi
        fi

        # Disk usage
        local disk="-"
        [ -n "$directory" ] && [ -d "$directory" ] && disk=$(du -sh "$directory" 2>/dev/null | awk '{print $1}')

        # Database size (only if DDEV running and column visible)
        local db="-"
        for vcol in "${VISIBLE_COLUMNS[@]}"; do
            if [ "$vcol" = "db" ]; then
                if [ -d "$directory/.ddev" ]; then
                    local site_basename=$(basename "$directory")
                    if echo "$ddev_list" | grep -q "^${site_basename}.*running"; then
                        db=$(cd "$directory" && ddev mysql -N -e "SELECT ROUND(SUM(data_length + index_length) / 1024 / 1024, 1) FROM information_schema.tables WHERE table_schema = DATABASE();" 2>/dev/null | tail -1)
                        [ -n "$db" ] && [ "$db" != "NULL" ] && db="${db}M" || db="-"
                    fi
                fi
                break
            fi
        done

        # Health check (only if DDEV running and column visible)
        local health="-"
        for vcol in "${VISIBLE_COLUMNS[@]}"; do
            if [ "$vcol" = "health" ]; then
                if [ -d "$directory/.ddev" ]; then
                    local site_basename=$(basename "$directory")
                    if echo "$ddev_list" | grep -q "^${site_basename}.*running"; then
                        local url="https://${site_basename}.ddev.site"
                        local http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "$url" 2>/dev/null || echo "000")
                        case "$http_code" in
                            200|301|302|303) health="OK" ;;
                            401|403) health="auth" ;;
                            404) health="404" ;;
                            500|502|503) health="err" ;;
                            000) health="down" ;;
                            *) health="$http_code" ;;
                        esac
                    fi
                fi
                break
            fi
        done

        # Last activity (git commit)
        local activity="-"
        for vcol in "${VISIBLE_COLUMNS[@]}"; do
            if [ "$vcol" = "activity" ]; then
                if [ -d "$directory/.git" ] || [ -f "$directory/.git" ]; then
                    activity=$(cd "$directory" && git log -1 --format="%ar" 2>/dev/null | sed 's/ ago//' | sed 's/ /-/g') || activity="-"
                fi
                break
            fi
        done

        # SSL expiry (only if live domain exists and column visible)
        local ssl="-"
        for vcol in "${VISIBLE_COLUMNS[@]}"; do
            if [ "$vcol" = "ssl" ]; then
                if [ -n "$domain" ]; then
                    local expiry=$(echo | timeout 3 openssl s_client -servername "$domain" -connect "${domain}:443" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
                    if [ -n "$expiry" ]; then
                        local expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null)
                        local now_epoch=$(date +%s)
                        local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
                        if [ "$days_left" -lt 0 ]; then
                            ssl="exp"
                        elif [ "$days_left" -lt 30 ]; then
                            ssl="${days_left}d"
                        else
                            ssl="${days_left}d"
                        fi
                    fi
                fi
                break
            fi
        done

        # CI status
        local ci="-"
        for vcol in "${VISIBLE_COLUMNS[@]}"; do
            if [ "$vcol" = "ci" ]; then
                local ci_enabled=$(get_site_nested_field "$site" "ci" "enabled" "$config_file")
                [ "$ci_enabled" == "true" ] && ci="on"
                break
            fi
        done

        # User count (expensive - only calculate if column is visible)
        local users="-"
        for vcol in "${VISIBLE_COLUMNS[@]}"; do
            if [ "$vcol" = "users" ]; then
                users=$(get_user_count "$site" "$config_file")
                break
            fi
        done

        # Store as pipe-delimited string (order must match column key order in draw_screen)
        # recipe|stages|ddev|purpose|disk|domain|users|db|health|activity|ssl|ci
        SITE_DATA+=("${recipe:-?}|${stages}|${ddev}|${purpose:--}|${disk:-?}|${domain:-}|${users}|${db}|${health}|${activity}|${ssl}|${ci}")

        idx=$((idx + 1))
    done
}

# Main interactive loop
run_interactive() {
    local config_file="$1"

    # Load column settings
    load_column_settings

    # Get sites
    local sites_str=$(list_sites "$config_file")
    if [ -z "$sites_str" ]; then
        print_error "No sites configured"
        return 1
    fi

    # Build arrays from cnwp.yml sites
    SITE_NAMES=()
    SITE_SELECTED=()
    SITE_TYPE=()  # 0=normal, 1=orphan, 2=ghost
    while read -r site; do
        SITE_NAMES+=("$site")
        SITE_SELECTED+=("0")
        SITE_TYPE+=("0")
    done <<< "$sites_str"

    # Add orphaned sites (have .ddev dir but not in cnwp.yml)
    while IFS=':' read -r name dir; do
        [ -z "$name" ] && continue
        SITE_NAMES+=("$name")
        SITE_SELECTED+=("0")
        SITE_TYPE+=("1")
    done < <(find_orphaned_sites "$config_file" "$PROJECT_ROOT")

    # Add ghost DDEV sites (registered in DDEV but directory missing)
    while IFS=':' read -r name dir type; do
        [ -z "$name" ] && continue
        # Skip if already in list
        local skip=false
        for existing in "${SITE_NAMES[@]}"; do
            [ "$existing" = "$name" ] && { skip=true; break; }
        done
        [ "$skip" = true ] && continue
        SITE_NAMES+=("$name")
        SITE_SELECTED+=("0")
        SITE_TYPE+=("2")
    done < <(find_ghost_ddev_sites "$PROJECT_ROOT")

    # Cache site data
    build_site_cache "$config_file"

    # Calculate column widths based on data
    calculate_column_widths

    local num_sites=${#SITE_NAMES[@]}
    local current_row=0
    local current_action=0
    local num_actions=${#ACTIONS[@]}

    # Setup terminal
    cursor_hide
    trap 'cursor_show; clear_screen' EXIT

    while true; do
        draw_screen $current_row $current_action

        local key=$(read_key)

        case "$key" in
            "UP"|"k") # Up (with wrap-around)
                current_row=$(( (current_row - 1 + num_sites) % num_sites ))
                ;;
            "DOWN"|"j") # Down (with wrap-around)
                current_row=$(( (current_row + 1) % num_sites ))
                ;;
            "SPACE") # Toggle selection
                if [ "${SITE_SELECTED[$current_row]}" = "0" ]; then
                    SITE_SELECTED[$current_row]="1"
                else
                    SITE_SELECTED[$current_row]="0"
                fi
                ;;
            "LEFT"|"TAB") # Previous action
                current_action=$(( (current_action - 1 + num_actions) % num_actions ))
                ;;
            "RIGHT") # Next action
                current_action=$(( (current_action + 1) % num_actions ))
                ;;
            "ENTER") # Execute action
                local selected_sites=()
                for i in "${!SITE_SELECTED[@]}"; do
                    [ "${SITE_SELECTED[$i]}" = "1" ] && selected_sites+=("${SITE_NAMES[$i]}")
                done

                cursor_show
                run_action "${ACTIONS[$current_action]}" "$config_file" "${selected_sites[@]}"
                cursor_hide

                # Refresh site list (in case of deletes)
                sites_str=$(list_sites "$config_file")

                # Rebuild arrays from cnwp.yml sites
                SITE_NAMES=()
                SITE_SELECTED=()
                SITE_TYPE=()
                if [ -n "$sites_str" ]; then
                    while read -r site; do
                        SITE_NAMES+=("$site")
                        SITE_SELECTED+=("0")
                        SITE_TYPE+=("0")
                    done <<< "$sites_str"
                fi

                # Add orphaned sites
                while IFS=':' read -r name dir; do
                    [ -z "$name" ] && continue
                    SITE_NAMES+=("$name")
                    SITE_SELECTED+=("0")
                    SITE_TYPE+=("1")
                done < <(find_orphaned_sites "$config_file" "$PROJECT_ROOT")

                # Add ghost DDEV sites
                while IFS=':' read -r name dir type; do
                    [ -z "$name" ] && continue
                    local skip=false
                    for existing in "${SITE_NAMES[@]}"; do
                        [ "$existing" = "$name" ] && { skip=true; break; }
                    done
                    [ "$skip" = true ] && continue
                    SITE_NAMES+=("$name")
                    SITE_SELECTED+=("0")
                    SITE_TYPE+=("2")
                done < <(find_ghost_ddev_sites "$PROJECT_ROOT")

                if [ ${#SITE_NAMES[@]} -eq 0 ]; then
                    print_info "No more sites"
                    break
                fi

                # Rebuild cache
                build_site_cache "$config_file"

                # Recalculate column widths
                calculate_column_widths

                num_sites=${#SITE_NAMES[@]}
                [ $current_row -ge $num_sites ] && current_row=$((num_sites - 1)) || true
                ;;
            "a"|"A") # Select all
                for i in "${!SITE_SELECTED[@]}"; do
                    SITE_SELECTED[$i]="1"
                done
                ;;
            "n"|"N") # Select none
                for i in "${!SITE_SELECTED[@]}"; do
                    SITE_SELECTED[$i]="0"
                done
                ;;
            "r"|"R") # Quick refresh shortcut
                build_site_cache "$config_file"
                calculate_column_widths
                ;;
            "s"|"S") # Quick setup shortcut
                run_setup_mode
                calculate_column_widths
                ;;
            "q"|"Q") # Quit
                break
                ;;
        esac
    done

    cursor_show
    clear_screen
}

################################################################################
# Help
################################################################################

show_help() {
    cat << EOF
${BOLD}NWP Status - System Overview and Site Management${NC}

${BOLD}USAGE:${NC}
    ./status.sh [command] [options]

${BOLD}COMMANDS:${NC}
    (none)              Interactive mode (default) - select sites with checkboxes
    health              Run health checks on all sites
    production          Show production status dashboard
    info <site>         Show detailed info for a specific site
    delete <site>       Delete a site (with confirmation)
    start <site>        Start DDEV for a site
    stop <site>         Stop DDEV for a site
    restart <site>      Restart DDEV for a site
    servers             Show Linode server statistics

${BOLD}OPTIONS:${NC}
    -r, --recipes       Show only recipes
    -s, --sites         Show only sites
    -v, --verbose       Show detailed information (purpose, domain)
    -a, --all           Show all details (health, disk, db, activity)
    -y, --yes           Skip confirmation prompts
    -h, --help          Show this help

${BOLD}EXAMPLES:${NC}
    ./status.sh                  Interactive mode (default)
    ./status.sh -s               Text status view (sites only)
    ./status.sh -v               Verbose text status with domains
    ./status.sh -a               Full status with health, disk, db info
    ./status.sh health           Run health checks on all sites
    ./status.sh info avc         Show detailed info for 'avc' site
    ./status.sh delete test-nwp  Delete test-nwp site
    ./status.sh start avc        Start DDEV for avc
    ./status.sh servers          Show Linode server stats

${BOLD}INTERACTIVE MODE (default):${NC}
    ↑/↓         Navigate sites
    ←/→         Select action (Info/Start/Stop/Restart/Health/Delete/Setup)
    SPACE       Toggle site selection
    ENTER       Execute action on selected sites
    a           Select all sites
    n           Deselect all sites
    r           Refresh data (DDEV status, disk usage, etc.)
    s           Setup - configure visible columns
    q           Quit

${BOLD}COLUMNS (configurable via Setup):${NC}
    NAME        Site name from cnwp.yml
    RECIPE      Recipe used to create the site
    STG         Stages: ${GREEN}d${NC}=dev ${YELLOW}s${NC}=stg ${BLUE}l${NC}=live ${RED}p${NC}=prod
    DDEV        Container status
    PURPOSE     Site purpose
    DISK        Directory size
    DOMAIN      Live domain
    USERS       Active user count (from prod/live/stg/dev)
    DB          Database size
    HEALTH      Site health check status
    ACTIVITY    Last git commit time
    SSL         SSL certificate expiry
    CI          CI/CD enabled status

EOF
}

################################################################################
# Main
################################################################################

main() {
    local command=""
    local show_recipes_only=false
    local show_sites_only=false
    local verbose=false
    local show_all=false
    local force=false
    local interactive=false
    local site_arg=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            health|info|delete|start|stop|restart|servers|production|prod)
                command="$1"
                shift
                [ $# -gt 0 ] && [ "${1:0:1}" != "-" ] && { site_arg="$1"; shift; }
                ;;
            -i|--interactive)
                interactive=true
                shift
                ;;
            -r|--recipes)
                show_recipes_only=true
                shift
                ;;
            -s|--sites)
                show_sites_only=true
                shift
                ;;
            -v|--verbose)
                verbose=true
                shift
                ;;
            -a|--all)
                show_all=true
                shift
                ;;
            -y|--yes)
                force=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                # Could be a site name for quick info
                if [ -z "$command" ]; then
                    site_arg="$1"
                    command="info"
                fi
                shift
                ;;
        esac
    done

    # Check config file exists
    if [ ! -f "$CONFIG_FILE" ]; then
        print_error "Configuration file not found"
        print_info "Copy example.cnwp.yml to cnwp.yml to get started"
        exit 1
    fi

    # Interactive mode is default when no command specified
    if [ -z "$command" ] && [ "$show_recipes_only" = false ] && [ "$show_sites_only" = false ] && [ "$verbose" = false ] && [ "$show_all" = false ]; then
        run_interactive "$CONFIG_FILE"
        exit 0
    fi

    # Execute command
    case "$command" in
        health)
            run_health_checks "$CONFIG_FILE"
            ;;
        info)
            if [ -z "$site_arg" ]; then
                print_error "Site name required"
                echo "Usage: ./status.sh info <site>"
                exit 1
            fi
            show_site_info "$site_arg" "$CONFIG_FILE"
            ;;
        delete)
            if [ -z "$site_arg" ]; then
                print_error "Site name required"
                echo "Usage: ./status.sh delete <site>"
                exit 1
            fi
            delete_site "$site_arg" "$CONFIG_FILE" "$force"
            ;;
        start)
            if [ -z "$site_arg" ]; then
                print_error "Site name required"
                echo "Usage: ./status.sh start <site>"
                exit 1
            fi
            start_site "$site_arg" "$CONFIG_FILE"
            ;;
        stop)
            if [ -z "$site_arg" ]; then
                print_error "Site name required"
                echo "Usage: ./status.sh stop <site>"
                exit 1
            fi
            stop_site "$site_arg" "$CONFIG_FILE"
            ;;
        restart)
            if [ -z "$site_arg" ]; then
                print_error "Site name required"
                echo "Usage: ./status.sh restart <site>"
                exit 1
            fi
            restart_site "$site_arg" "$CONFIG_FILE"
            ;;
        servers)
            show_server_stats "$CONFIG_FILE"
            ;;
        production|prod)
            show_production_dashboard "$CONFIG_FILE"
            ;;
        *)
            # Default status display
            print_header "NWP Status"

            if [[ "$CONFIG_FILE" == *"example.cnwp.yml" ]]; then
                print_info "Using example.cnwp.yml (copy to cnwp.yml for your configuration)"
                echo ""
            fi

            if [ "$show_sites_only" != "true" ]; then
                show_recipes "$CONFIG_FILE" "$verbose"
            fi

            if [ "$show_recipes_only" != "true" ]; then
                show_sites "$CONFIG_FILE" "$verbose" "$show_all"
            fi

            echo ""
            ;;
    esac
}

main "$@"
