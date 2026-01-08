#!/bin/bash
set -euo pipefail

################################################################################
# NWP Live to Production Deployment Script
#
# Deploys from live test server directly to production server
#
# Usage: ./live2prod.sh [OPTIONS] <sitename>
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

# Source shared libraries
source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh"

# Script start time
START_TIME=$(date +%s)

################################################################################
# Configuration Functions
################################################################################

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
    ' "$PROJECT_ROOT/cnwp.yml"
}

get_prod_config() {
    local sitename="$1"
    local field="$2"

    awk -v site="$sitename" -v field="$field" '
        /^sites:/ { in_sites = 1; next }
        in_sites && /^[a-zA-Z]/ && !/^  / { in_sites = 0 }
        in_sites && $0 ~ "^  " site ":" { in_site = 1; next }
        in_site && /^  [a-zA-Z]/ && !/^    / { in_site = 0 }
        in_site && /^    production:/ { in_prod = 1; next }
        in_prod && /^    [a-zA-Z]/ && !/^      / { in_prod = 0 }
        in_prod && $0 ~ "^      " field ":" {
            sub("^      " field ": *", "")
            gsub(/["'"'"']/, "")
            print
            exit
        }
    ' "$PROJECT_ROOT/cnwp.yml"
}

show_help() {
    cat << EOF
${BOLD}NWP Live to Production Deployment${NC}

${BOLD}USAGE:${NC}
    ./live2prod.sh [OPTIONS] <sitename>

    Deploys directly from live test server to production server.
    This is an advanced workflow for when live has been tested and
    you want to bypass staging.

${BOLD}OPTIONS:${NC}
    -h, --help              Show this help message
    -y, --yes               Skip confirmation prompts
    -s, --step <n>          Start from step n
    --skip-backup           Skip production backup (dangerous!)

${BOLD}WORKFLOW:${NC}
    1. Validate live and production configurations
    2. Backup production database
    3. Export configuration from live
    4. Sync files from live to production
    5. Run composer install on production
    6. Run database updates
    7. Import configuration
    8. Clear caches

${BOLD}EXAMPLES:${NC}
    ./live2prod.sh mysite              # Deploy live to production
    ./live2prod.sh -y mysite           # Deploy without confirmation

${BOLD}RECOMMENDED WORKFLOW:${NC}
    For most deployments, use the safer two-step approach:
    1. pl live2stg mysite    # Pull live changes to staging
    2. pl stg2prod mysite    # Deploy staging to production

EOF
}

################################################################################
# Deployment Functions
################################################################################

validate_deployment() {
    local base_name="$1"

    print_info "Validating deployment configuration..."

    # Check live server config
    local live_ip=$(get_live_config "$base_name" "server_ip")
    local live_user=$(get_live_config "$base_name" "ssh_user")
    local live_path=$(get_live_config "$base_name" "webroot")

    if [ -z "$live_ip" ]; then
        print_error "No live server configured for $base_name"
        print_info "Run 'pl live $base_name' first to provision live server"
        return 1
    fi

    # Check production server config
    local prod_ip=$(get_prod_config "$base_name" "server_ip")
    local prod_user=$(get_prod_config "$base_name" "ssh_user")
    local prod_path=$(get_prod_config "$base_name" "webroot")

    if [ -z "$prod_ip" ]; then
        print_error "No production server configured for $base_name"
        print_info "Configure production section in cnwp.yml first"
        return 1
    fi

    # Test SSH connections
    print_info "Testing SSH connection to live server ($live_ip)..."
    if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "${live_user:-root}@${live_ip}" "echo OK" &>/dev/null; then
        print_error "Cannot connect to live server: ${live_user:-root}@${live_ip}"
        return 1
    fi
    print_status "OK" "Live server accessible"

    print_info "Testing SSH connection to production server ($prod_ip)..."
    if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "${prod_user:-root}@${prod_ip}" "echo OK" &>/dev/null; then
        print_error "Cannot connect to production server: ${prod_user:-root}@${prod_ip}"
        return 1
    fi
    print_status "OK" "Production server accessible"

    # Export variables for other functions
    export LIVE_IP="$live_ip"
    export LIVE_USER="${live_user:-root}"
    export LIVE_PATH="${live_path:-/var/www/$base_name}"
    export PROD_IP="$prod_ip"
    export PROD_USER="${prod_user:-root}"
    export PROD_PATH="${prod_path:-/var/www/$base_name}"

    return 0
}

backup_production() {
    local base_name="$1"

    print_info "Creating production backup before deployment..."

    local backup_name="${base_name}_pre_deploy_$(date +%Y%m%d_%H%M%S)"
    local backup_cmd="cd $PROD_PATH && drush sql-dump --gzip > /tmp/${backup_name}.sql.gz"

    if ssh "${PROD_USER}@${PROD_IP}" "$backup_cmd"; then
        print_status "OK" "Production database backed up: ${backup_name}.sql.gz"
    else
        print_error "Failed to backup production database"
        return 1
    fi
}

export_live_config() {
    local base_name="$1"

    print_info "Exporting configuration from live server..."

    local export_cmd="cd $LIVE_PATH && drush config:export -y"

    if ssh "${LIVE_USER}@${LIVE_IP}" "$export_cmd"; then
        print_status "OK" "Configuration exported on live"
    else
        print_error "Failed to export configuration"
        return 1
    fi
}

sync_files() {
    local base_name="$1"

    print_info "Syncing files from live to production..."

    # Rsync from live to production (server to server)
    local rsync_cmd="rsync -avz --delete \
        --exclude='.git' \
        --exclude='sites/*/files' \
        --exclude='sites/*/private' \
        --exclude='vendor' \
        ${LIVE_USER}@${LIVE_IP}:${LIVE_PATH}/ \
        ${PROD_PATH}/"

    if ssh "${PROD_USER}@${PROD_IP}" "$rsync_cmd"; then
        print_status "OK" "Files synced to production"
    else
        print_error "Failed to sync files"
        return 1
    fi
}

run_composer() {
    local base_name="$1"

    print_info "Running composer install on production..."

    local composer_cmd="cd $PROD_PATH && composer install --no-dev --optimize-autoloader"

    if ssh "${PROD_USER}@${PROD_IP}" "$composer_cmd"; then
        print_status "OK" "Composer dependencies installed"
    else
        print_error "Composer install failed"
        return 1
    fi
}

run_db_updates() {
    local base_name="$1"

    print_info "Running database updates on production..."

    local update_cmd="cd $PROD_PATH && drush updatedb -y"

    if ssh "${PROD_USER}@${PROD_IP}" "$update_cmd"; then
        print_status "OK" "Database updates complete"
    else
        print_warning "Database updates returned non-zero (may be OK)"
    fi
}

import_config() {
    local base_name="$1"

    print_info "Importing configuration on production..."

    local import_cmd="cd $PROD_PATH && drush config:import -y"

    if ssh "${PROD_USER}@${PROD_IP}" "$import_cmd"; then
        print_status "OK" "Configuration imported"
    else
        print_error "Configuration import failed"
        return 1
    fi
}

clear_caches() {
    local base_name="$1"

    print_info "Clearing caches on production..."

    local cache_cmd="cd $PROD_PATH && drush cache:rebuild"

    if ssh "${PROD_USER}@${PROD_IP}" "$cache_cmd"; then
        print_status "OK" "Caches cleared"
    else
        print_warning "Cache clear returned non-zero"
    fi
}

################################################################################
# Main
################################################################################

main() {
    local YES=false
    local SKIP_BACKUP=false
    local START_STEP=1
    local SITENAME=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help) show_help; exit 0 ;;
            -y|--yes) YES=true; shift ;;
            -s|--step) START_STEP="$2"; shift 2 ;;
            --skip-backup) SKIP_BACKUP=true; shift ;;
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

    print_header "Live to Production Deployment: $BASE_NAME"

    # Validate configuration
    if ! validate_deployment "$BASE_NAME"; then
        exit 1
    fi

    # Confirmation
    if [ "$YES" != "true" ]; then
        print_warning "This will deploy LIVE directly to PRODUCTION"
        echo ""
        echo "  Live server:       ${LIVE_USER}@${LIVE_IP}"
        echo "  Production server: ${PROD_USER}@${PROD_IP}"
        echo ""
        read -p "Are you sure you want to continue? [y/N]: " confirm
        if [[ ! "$confirm" =~ ^[yY] ]]; then
            print_info "Deployment cancelled"
            exit 0
        fi
    fi

    # Execute deployment steps
    local step=1

    if [ $step -ge $START_STEP ] && [ "$SKIP_BACKUP" != "true" ]; then
        print_info "Step $step: Backup production"
        backup_production "$BASE_NAME"
    fi
    ((step++))

    if [ $step -ge $START_STEP ]; then
        print_info "Step $step: Export live configuration"
        export_live_config "$BASE_NAME"
    fi
    ((step++))

    if [ $step -ge $START_STEP ]; then
        print_info "Step $step: Sync files"
        sync_files "$BASE_NAME"
    fi
    ((step++))

    if [ $step -ge $START_STEP ]; then
        print_info "Step $step: Run composer"
        run_composer "$BASE_NAME"
    fi
    ((step++))

    if [ $step -ge $START_STEP ]; then
        print_info "Step $step: Database updates"
        run_db_updates "$BASE_NAME"
    fi
    ((step++))

    if [ $step -ge $START_STEP ]; then
        print_info "Step $step: Import configuration"
        import_config "$BASE_NAME"
    fi
    ((step++))

    if [ $step -ge $START_STEP ]; then
        print_info "Step $step: Clear caches"
        clear_caches "$BASE_NAME"
    fi

    # Show elapsed time
    show_elapsed_time "Deployment"

    print_header "Deployment Complete"
    print_status "OK" "Live deployed to production successfully"
    echo ""
    print_info "Production URL: https://$(get_prod_config "$BASE_NAME" "domain")"
}

main "$@"
