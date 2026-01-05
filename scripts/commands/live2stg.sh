#!/bin/bash
set -euo pipefail

################################################################################
# NWP Live to Staging Pull Script
#
# Pulls site from live server to local staging
#
# Usage: ./live2stg.sh [OPTIONS] <sitename>
################################################################################

# Get script directory (from symlink location, not resolved target)
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Source shared libraries
source "$SCRIPT_DIR/lib/ui.sh"
source "$SCRIPT_DIR/lib/common.sh"

# Script start time
START_TIME=$(date +%s)

################################################################################
# Helper Functions
################################################################################

get_base_name() {
    local site=$1
    echo "$site" | sed -E 's/_(stg|prod)$//'
}

get_stg_name() {
    local site=$1
    local base=$(get_base_name "$site")
    echo "${base}_stg"
}

get_live_config() {
    local sitename="$1"
    local field="$2"

    awk -v site="$sitename" -v field="$field" '
        /^sites:/ { in_sites = 1; next }
        in_sites && /^[a-zA-Z]/ && !/^  / { in_sites = 0 }
        in_sites && $0 ~ "^  " site ":" { in_site = 1; next }
        in_site && /^  [a-zA-Z]/ && !/^    / { in_site = 0 }
        in_site && /^    live:/ { in_live = 1; next }
        in_live && /^    [a-zA-Z]/ && !/^      / { in_live = 0 }
        in_live && $0 ~ "^      " field ":" {
            sub("^      " field ": *", "")
            gsub(/["'"'"']/, "")
            print
            exit
        }
    ' "$SCRIPT_DIR/cnwp.yml"
}

show_elapsed_time() {
    local end_time=$(date +%s)
    local elapsed=$((end_time - START_TIME))
    local hours=$((elapsed / 3600))
    local minutes=$(((elapsed % 3600) / 60))
    local seconds=$((elapsed % 60))
    echo ""
    print_status "OK" "Pull completed in $(printf "%02d:%02d:%02d" $hours $minutes $seconds)"
}

show_help() {
    cat << EOF
${BOLD}NWP Live to Staging Pull${NC}

${BOLD}USAGE:${NC}
    ./live2stg.sh [OPTIONS] <sitename>

    Pulls site from live server to local staging.

${BOLD}OPTIONS:${NC}
    -h, --help              Show this help message
    -y, --yes               Skip confirmation prompts
    --files-only            Pull files only, skip database
    --db-only               Pull database only, skip files

${BOLD}EXAMPLES:${NC}
    ./live2stg.sh mysite              # Pull live to mysite_stg
    ./live2stg.sh --files-only mysite # Pull files only

EOF
}

################################################################################
# Main
################################################################################

main() {
    local YES=false
    local FILES_ONLY=false
    local DB_ONLY=false
    local SITENAME=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help) show_help; exit 0 ;;
            -y|--yes) YES=true; shift ;;
            --files-only) FILES_ONLY=true; shift ;;
            --db-only) DB_ONLY=true; shift ;;
            -*) print_error "Unknown option: $1"; exit 1 ;;
            *) SITENAME="$1"; shift ;;
        esac
    done

    if [ -z "$SITENAME" ]; then
        print_error "Sitename required"
        show_help
        exit 1
    fi

    local BASE_NAME=$(get_base_name "$SITENAME")
    local STG_NAME=$(get_stg_name "$SITENAME")

    # Get live server config
    local server_ip=$(get_live_config "$BASE_NAME" "server_ip")
    local server_type=$(get_live_config "$BASE_NAME" "type")

    if [ -z "$server_ip" ]; then
        print_error "No live server configured for $BASE_NAME"
        exit 1
    fi

    print_header "Pull Live to Staging"
    echo -e "${BOLD}Live:${NC}     $BASE_NAME @ $server_ip"
    echo -e "${BOLD}Staging:${NC} $STG_NAME"
    echo ""

    # Check staging exists
    if [ ! -d "sites/$STG_NAME" ]; then
        print_error "Staging site not found: sites/$STG_NAME"
        exit 1
    fi

    # Determine SSH user
    local ssh_user="gitlab"
    [ "$server_type" == "dedicated" ] && ssh_user="root"

    # Test SSH
    if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "${ssh_user}@${server_ip}" "echo ok" >/dev/null 2>&1; then
        print_error "Cannot connect to live server"
        exit 1
    fi
    print_status "OK" "SSH connection successful"

    local sudo_prefix=""
    [ "$ssh_user" == "gitlab" ] && sudo_prefix="sudo"

    # Pull files
    if [ "$DB_ONLY" != "true" ]; then
        print_header "Pulling Files"
        rsync -avz --delete \
            --exclude=".ddev" \
            --exclude=".git" \
            --exclude="web/sites/default/files" \
            --exclude="private" \
            "${ssh_user}@${server_ip}:/var/www/${BASE_NAME}/" \
            "sites/$STG_NAME/"
        print_status "OK" "Files pulled"
    fi

    # Pull database
    if [ "$FILES_ONLY" != "true" ]; then
        print_header "Pulling Database"
        local tmp_sql="/tmp/live2stg_${BASE_NAME}_$(date +%s).sql.gz"

        # Export from live
        ssh "${ssh_user}@${server_ip}" "$sudo_prefix -u www-data sh -c 'cd /var/www/${BASE_NAME} && drush sql:dump --gzip'" > "$tmp_sql" 2>/dev/null || \
            ssh "${ssh_user}@${server_ip}" "$sudo_prefix -u www-data sh -c 'cd /var/www/${BASE_NAME}/web && ../vendor/bin/drush sql:dump --gzip'" > "$tmp_sql"

        # Import to staging
        cd "sites/$STG_NAME"
        ddev import-db --file="$tmp_sql"
        rm -f "$tmp_sql"
        cd "$SCRIPT_DIR"
        print_status "OK" "Database imported"
    fi

    # Clear cache
    print_info "Clearing cache..."
    cd "sites/$STG_NAME"
    ddev drush cr 2>/dev/null || true
    cd "$SCRIPT_DIR"

    print_header "Pull Complete"
    print_status "OK" "Live pulled to staging: $STG_NAME"
    show_elapsed_time
}

main "$@"
