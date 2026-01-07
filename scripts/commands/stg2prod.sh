#!/bin/bash

################################################################################
# NWP Staging to Production Deployment Script
#
# Deploys changes from staging environment to Linode production server
# Uses SSH/rsync for file transfer and remote drush commands
#
# Usage: ./stg2prod.sh [OPTIONS] <sitename>
################################################################################

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

# Source YAML library
if [ -f "$PROJECT_ROOT/lib/yaml-write.sh" ]; then
    source "$PROJECT_ROOT/lib/yaml-write.sh"
fi

# Script start time
START_TIME=$(date +%s)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

################################################################################
# Helper Functions
################################################################################

print_header() {
    echo -e "\n${BLUE}${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}${BOLD}  $1${NC}"
    echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════════════${NC}\n"
}

print_status() {
    local status=$1
    local message=$2

    if [ "$status" == "OK" ]; then
        echo -e "[${GREEN}✓${NC}] $message"
    elif [ "$status" == "WARN" ]; then
        echo -e "[${YELLOW}!${NC}] $message"
    elif [ "$status" == "FAIL" ]; then
        echo -e "[${RED}✗${NC}] $message"
    else
        echo -e "[${BLUE}i${NC}] $message"
    fi
}

print_error() {
    echo -e "${RED}${BOLD}ERROR:${NC} $1" >&2
}

print_info() {
    echo -e "${BLUE}${BOLD}INFO:${NC} $1"
}

# Conditional debug message
ocmsg() {
    local message=$1
    if [ "$DEBUG" == "true" ]; then
        echo -e "${CYAN}[DEBUG]${NC} $message"
    fi
}

# Display elapsed time
show_elapsed_time() {
    local end_time=$(date +%s)
    local elapsed=$((end_time - START_TIME))
    local hours=$((elapsed / 3600))
    local minutes=$(((elapsed % 3600) / 60))
    local seconds=$((elapsed % 60))

    echo ""
    print_status "OK" "Deployment completed in $(printf "%02d:%02d:%02d" $hours $minutes $seconds)"
}

# Check if we should run a step
should_run_step() {
    local step_num=$1
    local start_step=${2:-1}

    if [ "$step_num" -ge "$start_step" ]; then
        return 0
    else
        return 1
    fi
}

# Build SSH command with optional key
build_ssh_cmd() {
    local ssh_opts=""

    if [ -n "$SSH_KEY" ]; then
        ssh_opts="-i $SSH_KEY"
    fi

    echo "ssh $ssh_opts -p $SSH_PORT $SSH_USER@$SSH_HOST"
}

# Build rsync SSH options
build_rsync_ssh_opts() {
    local opts="-e ssh -p $SSH_PORT"

    if [ -n "$SSH_KEY" ]; then
        opts="-e ssh -i $SSH_KEY -p $SSH_PORT"
    fi

    echo "$opts"
}

# Get recipe value from cnwp.yml
get_recipe_value() {
    local recipe=$1
    local key=$2
    local config_file="${3:-cnwp.yml}"

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

# Get Linode server configuration
get_linode_config() {
    local server_name=$1
    local field=$2
    local config_file="${3:-cnwp.yml}"

    awk -v server="$server_name" -v field="$field" '
        BEGIN { in_servers = 0; in_server = 0 }
        /^linode:/ { in_linode = 1; next }
        in_linode && /^  servers:/ { in_servers = 1; next }
        in_servers && $0 ~ "^    " server ":" { in_server = 1; next }
        in_server && /^    [a-zA-Z]/ && !/^      / { in_server = 0 }
        in_server && $0 ~ "^      " field ":" {
            sub("^      " field ": *", "")
            print
            exit
        }
    ' "$PROJECT_ROOT/cnwp.yml"
}

# Get base name (remove -stg or -prod suffix, support legacy _stg/_prod during migration)
get_base_name() {
    local site=$1
    echo "$site" | sed -E 's/[-_](stg|prod)$//'
}

# Check if site is in production mode
# Returns 0 if in prod mode, 1 if in dev mode
is_prod_mode() {
    local sitename=$1

    if [ ! -d "$PROJECT_ROOT/sites/$sitename" ]; then
        return 1
    fi

    local original_dir=$(pwd)
    cd "$PROJECT_ROOT/sites/$sitename" || return 1

    # Check CSS preprocessing setting - 1 means prod mode
    local css_preprocess=$(ddev drush config:get system.performance css.preprocess 2>/dev/null | grep -oP "'\K[^']+")

    cd "$original_dir"

    if [ "$css_preprocess" == "1" ] || [ "$css_preprocess" == "true" ]; then
        return 0  # Is in prod mode
    else
        return 1  # Is in dev mode
    fi
}

# Ensure site is in production mode before deployment
ensure_prod_mode() {
    local sitename=$1

    print_info "Checking if $sitename is in production mode..."

    if is_prod_mode "$sitename"; then
        print_status "OK" "$sitename is already in production mode"
        return 0
    fi

    print_status "WARN" "$sitename is in development mode"
    print_info "Switching to production mode..."

    # Run make.sh -py to switch to prod mode with auto-confirm
    if "${SCRIPT_DIR}/make.sh" -py "$sitename"; then
        print_status "OK" "$sitename switched to production mode"
        return 0
    else
        print_error "Failed to switch $sitename to production mode"
        return 1
    fi
}

# Show help
show_help() {
    cat << EOF
${BOLD}NWP Staging to Production Deployment Script${NC}

${BOLD}USAGE:${NC}
    ./stg2prod.sh [OPTIONS] <sitename>

${BOLD}OPTIONS:${NC}
    -h, --help              Show this help message
    -d, --debug             Enable debug output
    -y, --yes               Skip confirmation prompts
    -v, --verbose           Show detailed rsync output
    -s N, --step=N          Resume from step N
    --dry-run               Show what would be done without making changes

${BOLD}ARGUMENTS:${NC}
    sitename                Base name of the staging site (production will be configured in cnwp.yml)

${BOLD}EXAMPLES:${NC}
    ./stg2prod.sh nwp                     # Deploy nwp-stg to production
    ./stg2prod.sh -y nwp                  # Deploy with auto-confirm
    ./stg2prod.sh --dry-run nwp           # Dry run - show what would happen
    ./stg2prod.sh -s 5 nwp                # Resume from step 5

${BOLD}ENVIRONMENT NAMING:${NC}
    Staging site: <sitename>-stg         (e.g., nwp-stg)
    Production:   Configured in cnwp.yml linode: section

${BOLD}DEPLOYMENT WORKFLOW:${NC}
    1. Validate deployment configuration
    2. Test SSH connection to production server
    3. Export configuration from staging
    4. Backup production (optional)
    5. Sync files to production via rsync
    6. Run composer install on production
    7. Run database updates on production
    8. Import configuration to production
    9. Reinstall modules on production (if configured)
   10. Clear cache and display production URL

${BOLD}CONFIGURATION:${NC}
    Production deployment configuration is stored in cnwp.yml:
    - linode: section defines server credentials
    - Recipe prod_server, prod_domain, prod_path define deployment target
    - Or sites: section can override recipe-level settings

${BOLD}NOTE:${NC}
    - Staging site must exist with DDEV configured
    - SSH access to production server must be configured
    - Production server must have composer and drush installed

EOF
}

################################################################################
# Deployment Steps
################################################################################

# Step 1: Validate deployment configuration
validate_deployment() {
    local stg_site=$1
    local base_name=$2

    print_header "Step 1: Validate Deployment Configuration"

    # Check if staging site exists
    if [ ! -d "$PROJECT_ROOT/sites/$stg_site" ]; then
        print_error "Staging site not found: $PROJECT_ROOT/sites/$stg_site"
        return 1
    fi
    print_status "OK" "Staging site exists: $PROJECT_ROOT/sites/$stg_site"

    # Get recipe from sites: or use base_name
    local recipe=""
    if command -v yaml_get_site_field &> /dev/null; then
        recipe=$(yaml_get_site_field "$base_name" "recipe" "$PROJECT_ROOT/cnwp.yml" 2>/dev/null)
    fi

    if [ -z "$recipe" ]; then
        recipe="$base_name"
        ocmsg "Using base name as recipe: $recipe"
    else
        ocmsg "Recipe from sites: $recipe"
    fi

    # Try to read production config from sites: first, then fall back to recipe
    local prod_server prod_domain prod_path prod_method

    if command -v yaml_get_site_field &> /dev/null; then
        # Check if site has production_config
        prod_method=$(awk -v site="$base_name" '
            BEGIN { in_site = 0; in_prod = 0 }
            /^sites:/ { in_sites = 1; next }
            in_sites && $0 ~ "^  " site ":" { in_site = 1; next }
            in_site && /^  [a-zA-Z]/ { in_site = 0 }
            in_site && /^    production_config:/ { in_prod = 1; next }
            in_prod && /^    [a-zA-Z]/ && !/^      / { in_prod = 0 }
            in_prod && /^      method:/ {
                sub("^      method: *", "")
                print
                exit
            }
        ' "$PROJECT_ROOT/cnwp.yml")
    fi

    # If not in sites:, read from recipe
    if [ -z "$prod_method" ]; then
        prod_method=$(get_recipe_value "$recipe" "prod_method" "$PROJECT_ROOT/cnwp.yml")
        prod_server=$(get_recipe_value "$recipe" "prod_server" "$PROJECT_ROOT/cnwp.yml")
        prod_domain=$(get_recipe_value "$recipe" "prod_domain" "$PROJECT_ROOT/cnwp.yml")
        prod_path=$(get_recipe_value "$recipe" "prod_path" "$PROJECT_ROOT/cnwp.yml")
    fi

    if [ -z "$prod_method" ]; then
        print_error "No production deployment method configured for recipe '$recipe'"
        echo "Add 'prod_method: rsync' to the recipe in cnwp.yml"
        return 1
    fi

    if [ "$prod_method" != "rsync" ]; then
        print_error "Only rsync deployment method is supported (found: $prod_method)"
        return 1
    fi

    print_status "OK" "Deployment method: $prod_method"

    # Validate server configuration
    if [ -z "$prod_server" ]; then
        print_error "No prod_server configured for recipe '$recipe'"
        return 1
    fi

    # Get server details from linode: section
    local ssh_user=$(get_linode_config "$prod_server" "ssh_user" "$PROJECT_ROOT/cnwp.yml")
    local ssh_host=$(get_linode_config "$prod_server" "ssh_host" "$PROJECT_ROOT/cnwp.yml")
    local ssh_port=$(get_linode_config "$prod_server" "ssh_port" "$PROJECT_ROOT/cnwp.yml")
    local ssh_key=$(get_linode_config "$prod_server" "ssh_key" "$PROJECT_ROOT/cnwp.yml")

    if [ -z "$ssh_user" ] || [ -z "$ssh_host" ]; then
        print_error "Server '$prod_server' not found in linode: section of cnwp.yml"
        return 1
    fi

    print_status "OK" "Server: $prod_server ($ssh_user@$ssh_host:${ssh_port:-22})"

    if [ -n "$ssh_key" ]; then
        # Expand ~ to home directory
        ssh_key="${ssh_key/#\~/$HOME}"
        if [ ! -f "$ssh_key" ]; then
            print_error "SSH key not found: $ssh_key"
            return 1
        fi
        print_status "OK" "SSH key: $ssh_key"
    fi

    if [ -z "$prod_path" ]; then
        print_error "No prod_path configured for recipe '$recipe'"
        return 1
    fi

    print_status "OK" "Remote path: $prod_path"

    if [ -n "$prod_domain" ]; then
        print_status "OK" "Domain: $prod_domain"
    fi

    # Export for use in other functions
    export PROD_RECIPE="$recipe"
    export PROD_SERVER="$prod_server"
    export PROD_DOMAIN="$prod_domain"
    export PROD_PATH="$prod_path"
    export SSH_USER="$ssh_user"
    export SSH_HOST="$ssh_host"
    export SSH_PORT="${ssh_port:-22}"
    export SSH_KEY="$ssh_key"

    return 0
}

# Step 2: Test SSH connection
test_ssh_connection() {
    print_header "Step 2: Test SSH Connection"

    local ssh_cmd=$(build_ssh_cmd)

    ocmsg "Testing SSH: $ssh_cmd"

    if $ssh_cmd "echo 'SSH connection successful'" >/dev/null 2>&1; then
        print_status "OK" "SSH connection to $SSH_USER@$SSH_HOST successful"
    else
        print_error "SSH connection failed to $SSH_USER@$SSH_HOST"
        echo "Please ensure:"
        echo "  1. SSH keys are configured"
        echo "  2. Server is reachable"
        echo "  3. User has appropriate permissions"
        return 1
    fi

    return 0
}

# Step 3: Export configuration from staging
export_config_staging() {
    local stg_site=$1

    print_header "Step 3: Export Configuration from Staging"

    local original_dir=$(pwd)
    cd "$PROJECT_ROOT/sites/$stg_site" || {
        print_error "Cannot access staging site: $PROJECT_ROOT/sites/$stg_site"
        return 1
    }

    ocmsg "Exporting configuration..."
    if ddev drush config:export -y >/dev/null 2>&1; then
        print_status "OK" "Configuration exported from staging"
    else
        print_status "WARN" "Configuration export had warnings (may be no changes)"
    fi

    cd "$original_dir"
    return 0
}

# Step 4: Backup production (optional)
backup_production() {
    print_header "Step 4: Backup Production (Optional)"

    if [ "$AUTO_YES" == "true" ]; then
        print_status "INFO" "Skipping production backup (auto-yes mode)"
        return 0
    fi

    echo -n "Create production backup before deployment? [y/N]: "
    read do_backup

    if [[ ! "$do_backup" =~ ^[Yy] ]]; then
        print_status "INFO" "Skipping production backup"
        return 0
    fi

    local backup_name="backup-$(date +%Y%m%d-%H%M%S)"
    local ssh_cmd=$(build_ssh_cmd)

    ocmsg "Creating backup: $backup_name"

    if $ssh_cmd "cd $(dirname $PROD_PATH) && cp -r $(basename $PROD_PATH) ${backup_name}" 2>&1; then
        print_status "OK" "Backup created: $backup_name"
    else
        print_status "WARN" "Backup creation failed (continuing anyway)"
    fi

    return 0
}

# Step 5: Sync files to production
sync_files() {
    local stg_site=$1

    print_header "Step 5: Sync Files to Production"

    # Build rsync exclude list
    local excludes=(
        "--exclude=.git"
        "--exclude=.ddev"
        "--exclude=*/settings.php"
        "--exclude=*/settings.local.php"
        "--exclude=*/services.yml"
        "--exclude=*/files/*"
        "--exclude=private/*"
        "--exclude=node_modules"
        "--exclude=.env"
    )

    # Build SSH options for rsync
    local ssh_opts="ssh -p $SSH_PORT"
    if [ -n "$SSH_KEY" ]; then
        ssh_opts="ssh -i $SSH_KEY -p $SSH_PORT"
    fi

    # Rsync (quiet by default, verbose with -v flag)
    local rsync_opts="-az"
    if [ "${VERBOSE:-false}" == "true" ]; then
        rsync_opts="-avz"
    fi

    local rsync_cmd="rsync $rsync_opts --delete -e \"$ssh_opts\" ${excludes[@]} $PROJECT_ROOT/sites/$stg_site/ $SSH_USER@$SSH_HOST:$PROD_PATH/"

    ocmsg "Rsync command: $rsync_cmd"

    if [ "$DRY_RUN" == "true" ]; then
        print_status "INFO" "DRY RUN: Would execute: $rsync_cmd"
        return 0
    fi

    echo -e "${CYAN}Syncing files to production...${NC}"
    if eval "$rsync_cmd"; then
        print_status "OK" "Files synced to production"
    else
        print_error "File sync failed"
        return 1
    fi

    return 0
}

# Step 6: Run composer install on production
run_composer_production() {
    print_header "Step 6: Run Composer Install on Production"

    local ssh_cmd=$(build_ssh_cmd)

    if [ "$DRY_RUN" == "true" ]; then
        print_status "INFO" "DRY RUN: Would run composer install on production"
        return 0
    fi

    ocmsg "Running composer install..."
    if $ssh_cmd "cd $PROD_PATH && composer install --no-dev --optimize-autoloader" 2>&1 | tail -10; then
        print_status "OK" "Composer install completed on production"
    else
        print_status "WARN" "Composer install had warnings"
    fi

    return 0
}

# Step 7: Run database updates on production
run_db_updates_production() {
    print_header "Step 7: Run Database Updates on Production"

    local ssh_cmd=$(build_ssh_cmd)

    if [ "$DRY_RUN" == "true" ]; then
        print_status "INFO" "DRY RUN: Would run database updates on production"
        return 0
    fi

    ocmsg "Running database updates..."
    if $ssh_cmd "cd $PROD_PATH && drush updatedb -y" 2>&1 | tail -10; then
        print_status "OK" "Database updates completed on production"
    else
        print_status "WARN" "Database updates had warnings"
    fi

    return 0
}

# Step 8: Import configuration to production
import_config_production() {
    print_header "Step 8: Import Configuration to Production"

    local ssh_cmd=$(build_ssh_cmd)

    if [ "$DRY_RUN" == "true" ]; then
        print_status "INFO" "DRY RUN: Would import configuration on production"
        return 0
    fi

    ocmsg "Importing configuration..."
    if $ssh_cmd "cd $PROD_PATH && drush config:import -y" 2>&1 | tail -10; then
        print_status "OK" "Configuration imported to production"
    else
        print_status "WARN" "Configuration import had warnings"
    fi

    return 0
}

# Step 9: Reinstall modules on production
reinstall_modules_production() {
    print_header "Step 9: Reinstall Modules (if configured)"

    if [ "$DRY_RUN" == "true" ]; then
        print_status "INFO" "DRY RUN: Would reinstall modules on production"
        return 0
    fi

    # Read reinstall_modules from recipe configuration
    local reinstall_modules=$(get_recipe_value "$PROD_RECIPE" "reinstall_modules" "$PROJECT_ROOT/cnwp.yml")

    if [ -z "$reinstall_modules" ]; then
        print_status "INFO" "No modules configured for reinstallation in recipe '$PROD_RECIPE'"
        return 0
    fi

    ocmsg "Modules to reinstall: $reinstall_modules"

    local module_array=($reinstall_modules)
    local total_modules=${#module_array[@]}
    local success_count=0
    local fail_count=0

    echo -e "Found ${BOLD}$total_modules${NC} module(s) to reinstall: ${BOLD}$reinstall_modules${NC}"
    echo ""

    local ssh_cmd=$(build_ssh_cmd)

    for module in "${module_array[@]}"; do
        echo -e "${CYAN}Processing module: ${BOLD}$module${NC}"

        # Check if enabled
        local is_enabled=$($ssh_cmd "cd $PROD_PATH && drush pm:list --filter=\"$module\" --status=enabled --format=list 2>/dev/null | grep -c \"^$module$\"")

        if [ "$is_enabled" -eq 0 ]; then
            print_status "INFO" "Module '$module' not enabled, skipping"
            echo ""
            continue
        fi

        # Uninstall
        if $ssh_cmd "cd $PROD_PATH && drush pm:uninstall -y $module" >/dev/null 2>&1; then
            print_status "OK" "Uninstalled '$module'"
        else
            print_status "FAIL" "Failed to uninstall '$module'"
            fail_count=$((fail_count + 1))
            echo ""
            continue
        fi

        # Re-enable
        if $ssh_cmd "cd $PROD_PATH && drush pm:enable -y $module" >/dev/null 2>&1; then
            print_status "OK" "Re-enabled '$module'"
            success_count=$((success_count + 1))
        else
            print_status "FAIL" "Failed to re-enable '$module'"
            fail_count=$((fail_count + 1))
        fi

        echo ""
    done

    echo -e "${BOLD}Module Reinstallation Summary:${NC}"
    echo -e "  Total:    $total_modules"
    echo -e "  ${GREEN}Success:  $success_count${NC}"
    if [ $fail_count -gt 0 ]; then
        echo -e "  ${RED}Failed:   $fail_count${NC}"
    fi
    echo ""

    return 0
}

# Step 10: Clear cache and display URL
clear_cache_and_display() {
    print_header "Step 10: Clear Cache and Display Production URL"

    local ssh_cmd=$(build_ssh_cmd)

    if [ "$DRY_RUN" == "true" ]; then
        print_status "INFO" "DRY RUN: Would clear cache on production"
    else
        ocmsg "Clearing cache..."
        if $ssh_cmd "cd $PROD_PATH && drush cache:rebuild" >/dev/null 2>&1; then
            print_status "OK" "Cache cleared on production"
        else
            print_status "WARN" "Cache clear had warnings"
        fi
    fi

    echo ""
    if [ -n "$PROD_DOMAIN" ]; then
        print_status "OK" "Production site: ${BOLD}https://$PROD_DOMAIN${NC}"
    else
        print_status "OK" "Production site deployed to: ${BOLD}$SSH_HOST:$PROD_PATH${NC}"
    fi

    return 0
}

################################################################################
# Main Deployment Function
################################################################################

deploy_stg2prod() {
    local stg_site=$1
    local auto_yes=$2
    local start_step=${3:-1}
    local dry_run=${4:-false}

    local base_name=$(get_base_name "$stg_site")

    print_header "NWP Staging to Production Deployment"
    echo -e "${BOLD}Staging:${NC}    $stg_site"
    echo -e "${BOLD}Site:${NC}       $base_name"
    echo ""

    # Validate first to get configuration
    if should_run_step 1 "$start_step"; then
        if ! validate_deployment "$stg_site" "$base_name"; then
            return 1
        fi
    fi

    # Confirm deployment
    if [ "$auto_yes" != "true" ] && [ "$dry_run" != "true" ] && [ "$start_step" -eq 1 ]; then
        echo -e "${YELLOW}${BOLD}WARNING: This will deploy to PRODUCTION!${NC}"
        echo -e "${YELLOW}Server: ${BOLD}$SSH_USER@$SSH_HOST${NC}"
        echo -e "${YELLOW}Path:   ${BOLD}$PROD_PATH${NC}"
        if [ -n "$PROD_DOMAIN" ]; then
            echo -e "${YELLOW}Domain: ${BOLD}$PROD_DOMAIN${NC}"
        fi
        echo ""
        echo -n "Continue with production deployment? [y/N]: "
        read confirm
        if [[ ! "$confirm" =~ ^[Yy] ]]; then
            print_info "Deployment cancelled"
            return 1
        fi
    fi

    # Execute deployment steps
    if should_run_step 2 "$start_step"; then
        if ! test_ssh_connection; then
            return 1
        fi
    fi

    if should_run_step 3 "$start_step"; then
        export_config_staging "$stg_site"
    fi

    if should_run_step 4 "$start_step"; then
        backup_production
    fi

    if should_run_step 5 "$start_step"; then
        if ! sync_files "$stg_site"; then
            return 1
        fi
    fi

    if should_run_step 6 "$start_step"; then
        run_composer_production
    fi

    if should_run_step 7 "$start_step"; then
        run_db_updates_production
    fi

    if should_run_step 8 "$start_step"; then
        import_config_production
    fi

    if should_run_step 9 "$start_step"; then
        reinstall_modules_production
    fi

    if should_run_step 10 "$start_step"; then
        clear_cache_and_display
    fi

    return 0
}

################################################################################
# Main Function
################################################################################

main() {
    # Parse options
    local DEBUG=false
    local AUTO_YES=false
    local DRY_RUN=false
    local VERBOSE=false
    local START_STEP=1
    local SITENAME=""

    # Export for use in functions
    export DEBUG AUTO_YES DRY_RUN VERBOSE

    local OPTIONS=hdyvs:
    local LONGOPTS=help,debug,yes,verbose,step:,dry-run

    if ! PARSED=$(getopt --options=$OPTIONS --longoptions=$LONGOPTS --name "$0" -- "$@"); then
        show_help
        exit 1
    fi

    eval set -- "$PARSED"

    while true; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -d|--debug)
                DEBUG=true
                shift
                ;;
            -y|--yes)
                AUTO_YES=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            -s|--step)
                START_STEP="$2"
                shift 2
                ;;
            --)
                shift
                break
                ;;
            *)
                echo "Programming error"
                exit 3
                ;;
        esac
    done

    # Get sitename
    if [ $# -lt 1 ]; then
        print_error "Missing site name"
        echo ""
        show_help
        exit 1
    fi

    SITENAME="$1"

    # Add -stg suffix if not present (support legacy _stg during migration)
    if [[ ! "$SITENAME" =~ [-_]stg$ ]]; then
        SITENAME="${SITENAME}-stg"
    fi

    ocmsg "Staging site: $SITENAME"
    ocmsg "Auto yes: $AUTO_YES"
    ocmsg "Dry run: $DRY_RUN"
    ocmsg "Start step: $START_STEP"

    # Ensure staging site is in production mode before deploying to prod
    if [ "$DRY_RUN" != "true" ] && [ -d "$PROJECT_ROOT/sites/$SITENAME" ]; then
        if ! ensure_prod_mode "$SITENAME"; then
            print_error "Cannot deploy to production without staging site in production mode"
            exit 1
        fi
    fi

    # Run deployment
    if deploy_stg2prod "$SITENAME" "$AUTO_YES" "$START_STEP" "$DRY_RUN"; then
        show_elapsed_time
        exit 0
    else
        print_error "Deployment to production failed: $SITENAME"
        exit 1
    fi
}

# Run main
main "$@"
