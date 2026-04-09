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
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

# Source shared libraries
source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/ssh.sh"

# Trap handler to ensure spinners are stopped
trap 'stop_spinner' EXIT INT TERM

# Script start time
START_TIME=$(date +%s)

################################################################################
# Helper Functions
################################################################################

get_stg_dir() {
    local site=$1
    local base=$(get_base_name "$site")
    resolve_project "$base" "stg"
}

get_live_config() {
    local sitename="$1"
    local field="$2"
    local base=$(get_base_name "$sitename")

    # F23: read from per-site .nwp.yml via layered config reader.
    # Maps legacy field names to yq paths in the new per-site schema.
    local yq_path
    case "$field" in
        server_ip)
            # Resolve via server name → server-resolver
            local server_name
            server_name=$(get_site_config_value "$base" '.live.server' "")
            if [[ -n "$server_name" ]]; then
                get_server_config "$server_name" "ip" ""
                return
            fi
            # Direct IP fallback (legacy)
            get_site_config_value "$base" '.live.server_ip' ""
            return
            ;;
        domain)    yq_path='.live.domain' ;;
        type)      yq_path='.live.type' ;;
        server)    yq_path='.live.server' ;;
        remote_path) yq_path='.live.remote_path' ;;
        *)         yq_path=".live.$field" ;;
    esac
    get_site_config_value "$base" "$yq_path" ""
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
    ./live2stg.sh mysite              # Pull live to mysite/stg/
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

    # F23: resolve stg directory (v2: sites/<name>/stg/, v1: sites/<name>-stg/)
    local STG_DIR
    STG_DIR=$(get_stg_dir "$SITENAME")
    if [ -z "$STG_DIR" ]; then
        print_error "Cannot resolve staging directory for $BASE_NAME"
        exit 1
    fi

    # Get live server config (reads per-site .nwp.yml, falls back to nwp.yml)
    local server_ip=$(get_live_config "$BASE_NAME" "server_ip")
    local server_type=$(get_live_config "$BASE_NAME" "type")

    if [ -z "$server_ip" ]; then
        print_error "No live server configured for $BASE_NAME"
        exit 1
    fi

    print_header "Pull Live to Staging"
    echo -e "${BOLD}Live:${NC}     $BASE_NAME @ $server_ip"
    echo -e "${BOLD}Staging:${NC} $STG_DIR"
    echo ""

    # Check staging exists
    if [ ! -d "$STG_DIR" ]; then
        print_error "Staging site not found: $STG_DIR"
        exit 1
    fi

    # Determine SSH user via resolution chain
    local ssh_user
    ssh_user=$(get_ssh_user "$BASE_NAME")

    # Test SSH
    show_step 1 4 "Testing SSH connection to live server"
    start_spinner "Connecting to ${server_ip}"
    if ! ssh $(nwp_ssh_opts "$BASE_NAME") -o BatchMode=yes -o ConnectTimeout=5 "${ssh_user}@${server_ip}" "echo ok" >/dev/null 2>&1; then
        stop_spinner
        print_error "Cannot connect to live server"
        exit 1
    fi
    stop_spinner
    print_status "OK" "SSH connection successful"

    local sudo_prefix=""
    [ "$ssh_user" == "gitlab" ] && sudo_prefix="sudo"

    # F23: read remote_path from per-site config, default to /var/www/<name>
    local remote_path
    remote_path=$(get_live_config "$BASE_NAME" "remote_path")
    [ -z "$remote_path" ] && remote_path="/var/www/${BASE_NAME}"

    # Pull files
    if [ "$DB_ONLY" != "true" ]; then
        show_step 2 4 "Pulling files from live server"
        start_spinner "Syncing files via rsync"
        rsync -e "ssh $(nwp_ssh_opts "$BASE_NAME")" -avz --delete \
            --exclude=".ddev" \
            --exclude=".git" \
            --exclude=".nwp.yml" \
            --exclude="web/sites/default/files" \
            --exclude="private" \
            "${ssh_user}@${server_ip}:${remote_path}/" \
            "$STG_DIR/" 2>&1 | grep -v "^sending incremental file list$" | grep -v "^$" || true
        stop_spinner
        print_status "OK" "Files pulled"
    fi

    # Pull database
    if [ "$FILES_ONLY" != "true" ]; then
        local step_num=2
        [ "$DB_ONLY" != "true" ] && step_num=3
        show_step $step_num 4 "Pulling database from live server"
        local tmp_sql="/tmp/live2stg_${BASE_NAME}_$(date +%s).sql.gz"

        # Export from live
        start_spinner "Exporting database from live"
        ssh $(nwp_ssh_opts "$BASE_NAME") "${ssh_user}@${server_ip}" "$sudo_prefix -u www-data sh -c 'cd ${remote_path} && drush sql:dump --gzip'" > "$tmp_sql" 2>/dev/null || \
            ssh $(nwp_ssh_opts "$BASE_NAME") "${ssh_user}@${server_ip}" "$sudo_prefix -u www-data sh -c 'cd ${remote_path}/web && ../vendor/bin/drush sql:dump --gzip'" > "$tmp_sql"
        stop_spinner

        # Import to staging
        start_spinner "Importing database to staging"
        cd "$STG_DIR"
        ddev import-db --file="$tmp_sql" >/dev/null 2>&1
        rm -f "$tmp_sql"
        cd "$PROJECT_ROOT"
        stop_spinner
        print_status "OK" "Database imported"
    fi

    # Clear cache
    show_step 4 4 "Clearing Drupal cache"
    start_spinner "Running drush cache:rebuild"
    cd "$STG_DIR"
    ddev drush cr 2>/dev/null || true
    cd "$PROJECT_ROOT"
    stop_spinner

    print_header "Pull Complete"
    print_status "OK" "Live pulled to staging: $STG_NAME"
    show_elapsed_time
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
