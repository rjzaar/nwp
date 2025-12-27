#!/bin/bash

################################################################################
# NWP Dev to Staging Deployment Script
#
# Deploys changes from development environment to staging
# Based on pleasy dev2stg.sh adapted for DDEV environments
#
# Usage: ./dev2stg.sh [OPTIONS] <sitename>
################################################################################

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

# Show help
show_help() {
    cat << EOF
${BOLD}NWP Dev to Staging Deployment Script${NC}

${BOLD}USAGE:${NC}
    ./dev2stg.sh [OPTIONS] <sitename>

${BOLD}OPTIONS:${NC}
    -h, --help              Show this help message
    -d, --debug             Enable debug output
    -y, --yes               Skip confirmation prompts
    -s N, --step=N          Resume from step N (use -s 5 or --step=5)

${BOLD}ARGUMENTS:${NC}
    sitename                Base name of the dev site (staging will be sitename_stg)

${BOLD}EXAMPLES:${NC}
    ./dev2stg.sh nwp                     # Deploy nwp to nwp_stg
    ./dev2stg.sh -y nwp                  # Deploy with auto-confirm
    ./dev2stg.sh -s 5 nwp                # Resume from step 5
    ./dev2stg.sh --step=5 nwp            # Resume from step 5 (long form)
    ./dev2stg.sh -dy nwp                 # Deploy with debug output and auto-confirm

${BOLD}COMBINED FLAGS:${NC}
    Multiple short flags can be combined: -dy = -d -y
    Example: ./dev2stg.sh -dy nwp is the same as ./dev2stg.sh -d -y nwp

${BOLD}ENVIRONMENT NAMING:${NC}
    Dev site:     <sitename>             (e.g., nwp)
    Staging site: <sitename>_stg         (e.g., nwp_stg)
    Production:   <sitename>_prod        (e.g., nwp_prod)

${BOLD}DEPLOYMENT WORKFLOW:${NC}
    1. Validate dev and staging sites exist
    2. Export configuration from dev
    3. Sync files from dev to staging (with exclusions)
    4. Run composer install --no-dev on staging
    5. Run database updates on staging
    6. Import configuration to staging
    7. Reinstall specified modules (if configured)
    8. Clear cache on staging
    9. Display staging URL

${BOLD}FILE EXCLUSIONS:${NC}
    The following are excluded from sync:
    - settings.php and services.yml
    - files/ directory
    - .git/ directory
    - private/ directory
    - node_modules/

${BOLD}NOTE:${NC}
    Both dev and staging sites must already exist with DDEV configured.
    Use './copy.sh dev_site stg_site' to create staging initially if needed.

EOF
}

################################################################################
# Environment Detection
################################################################################

# Get environment type from site name
get_env_type() {
    local site=$1

    if [[ "$site" =~ _stg$ ]]; then
        echo "staging"
    elif [[ "$site" =~ _prod$ ]]; then
        echo "production"
    else
        echo "development"
    fi
}

# Get base site name (without env suffix)
get_base_name() {
    local site=$1

    # Remove _stg or _prod suffix
    echo "$site" | sed -E 's/_(stg|prod)$//'
}

# Get staging site name from base name
get_stg_name() {
    local base=$1
    echo "${base}_stg"
}

# Get webroot from DDEV config
get_webroot() {
    local site=$1
    local webroot=$(grep "^docroot:" "$site/.ddev/config.yaml" 2>/dev/null | awk '{print $2}')
    if [ -z "$webroot" ]; then
        echo "web"
    else
        echo "$webroot"
    fi
}

################################################################################
# Deployment Steps
################################################################################

# Step 1: Validate sites
validate_sites() {
    local dev_site=$1
    local stg_site=$2

    print_header "Step 1: Validate Sites"

    # Check dev site
    if [ ! -d "$dev_site" ]; then
        print_error "Dev site not found: $dev_site"
        return 1
    fi

    if [ ! -f "$dev_site/.ddev/config.yaml" ]; then
        print_error "Dev site is not a DDEV site: $dev_site"
        return 1
    fi

    print_status "OK" "Dev site validated: $dev_site"

    # Check staging site
    if [ ! -d "$stg_site" ]; then
        print_error "Staging site not found: $stg_site"
        print_info "Create staging site first: ./copy.sh $dev_site $stg_site"
        return 1
    fi

    if [ ! -f "$stg_site/.ddev/config.yaml" ]; then
        print_error "Staging site is not a DDEV site: $stg_site"
        return 1
    fi

    print_status "OK" "Staging site validated: $stg_site"

    return 0
}

# Step 2: Export configuration from dev
export_config_dev() {
    local dev_site=$1

    print_header "Step 2: Export Configuration from Dev"

    local original_dir=$(pwd)
    cd "$dev_site" || {
        print_error "Cannot access dev site: $dev_site"
        return 1
    }

    ocmsg "Exporting configuration..."
    if ddev drush config:export -y > /dev/null 2>&1; then
        print_status "OK" "Configuration exported from dev"
    else
        print_status "WARN" "Could not export configuration (may not be available)"
    fi

    cd "$original_dir"
    return 0
}

# Step 3: Sync files from dev to staging
sync_files() {
    local dev_site=$1
    local stg_site=$2
    local webroot=$3

    print_header "Step 3: Sync Files from Dev to Staging"

    ocmsg "Syncing files with rsync..."

    # Build rsync exclusions
    local excludes=(
        "--exclude=.ddev/"
        "--exclude=$webroot/sites/default/settings.php"
        "--exclude=$webroot/sites/default/settings.*.php"
        "--exclude=$webroot/sites/default/services.yml"
        "--exclude=$webroot/sites/default/files/"
        "--exclude=.git/"
        "--exclude=.gitignore"
        "--exclude=private/"
        "--exclude=*/node_modules/"
        "--exclude=node_modules/"
        "--exclude=dev/"
    )

    # Rsync from dev to staging
    if rsync -av --delete "${excludes[@]}" "$dev_site/" "$stg_site/" > /dev/null 2>&1; then
        print_status "OK" "Files synced to staging"
    else
        print_error "File sync failed"
        return 1
    fi

    return 0
}

# Step 4: Run composer install on staging
run_composer_staging() {
    local stg_site=$1

    print_header "Step 4: Run Composer Install on Staging"

    local original_dir=$(pwd)
    cd "$stg_site" || {
        print_error "Cannot access staging site: $stg_site"
        return 1
    }

    ocmsg "Running composer install --no-dev..."
    if ddev composer install --no-dev > /dev/null 2>&1; then
        print_status "OK" "Composer dependencies installed (production mode)"
    else
        print_status "WARN" "Composer install had warnings (non-fatal)"
    fi

    cd "$original_dir"
    return 0
}

# Step 5: Run database updates on staging
run_db_updates() {
    local stg_site=$1

    print_header "Step 5: Run Database Updates on Staging"

    local original_dir=$(pwd)
    cd "$stg_site" || {
        print_error "Cannot access staging site: $stg_site"
        return 1
    }

    ocmsg "Running database updates..."
    if ddev drush updatedb -y > /dev/null 2>&1; then
        print_status "OK" "Database updates completed"
    else
        print_status "WARN" "Database updates had warnings (may be none needed)"
    fi

    cd "$original_dir"
    return 0
}

# Step 6: Import configuration to staging
import_config_staging() {
    local stg_site=$1

    print_header "Step 6: Import Configuration to Staging"

    local original_dir=$(pwd)
    cd "$stg_site" || {
        print_error "Cannot access staging site: $stg_site"
        return 1
    }

    ocmsg "Importing configuration..."
    if ddev drush config:import -y > /dev/null 2>&1; then
        print_status "OK" "Configuration imported to staging"
    else
        print_status "WARN" "Configuration import had warnings (may be none to import)"
    fi

    cd "$original_dir"
    return 0
}

# Step 7: Reinstall modules (if configured)
reinstall_modules() {
    local stg_site=$1

    print_header "Step 7: Reinstall Modules (if configured)"

    # TODO: Read from nwp.yml for reinstall_modules list
    # For now, just skip this step
    print_status "INFO" "No modules configured for reinstallation"

    return 0
}

# Step 8: Clear cache on staging
clear_cache_staging() {
    local stg_site=$1

    print_header "Step 8: Clear Cache on Staging"

    local original_dir=$(pwd)
    cd "$stg_site" || {
        print_error "Cannot access staging site: $stg_site"
        return 1
    }

    ocmsg "Clearing cache..."
    # Try to clear cache and capture error
    local error_msg=$(ddev drush cache:rebuild 2>&1)
    local exit_code=$?

    if [ $exit_code -eq 0 ]; then
        print_status "OK" "Cache cleared on staging"
    else
        # Provide specific error message based on the failure
        if echo "$error_msg" | grep -q "command not found\|drush: not found"; then
            print_status "WARN" "Drush not installed - run 'ddev composer require drush/drush'"
        elif echo "$error_msg" | grep -q "could not find driver\|database"; then
            print_status "WARN" "Database not configured or not accessible"
        elif echo "$error_msg" | grep -q "Bootstrap failed\|not a Drupal"; then
            print_status "WARN" "Site not fully configured (not a Drupal installation)"
        else
            print_status "WARN" "Could not clear cache: ${error_msg:0:60}"
        fi
    fi

    cd "$original_dir"
    return 0
}

# Step 9: Display staging URL
display_staging_url() {
    local stg_site=$1

    print_header "Step 9: Deployment Complete"

    # Get staging URL
    local stg_url=$(cd "$stg_site" && ddev describe 2>/dev/null | grep -oP 'https://[^ ,]+' | head -1)

    if [ -n "$stg_url" ]; then
        echo -e "${BOLD}Staging URL:${NC} $stg_url"
    fi

    return 0
}

################################################################################
# Main Deployment Function
################################################################################

deploy_dev2stg() {
    local dev_site=$1
    local auto_yes=$2
    local start_step=${3:-1}

    # Determine staging site name
    local base_name=$(get_base_name "$dev_site")
    local stg_site=$(get_stg_name "$base_name")

    print_header "NWP Dev to Staging Deployment"
    echo -e "${BOLD}Dev:${NC}     $dev_site"
    echo -e "${BOLD}Staging:${NC} $stg_site"
    echo ""

    # Confirm deployment
    if [ "$auto_yes" != "true" ] && [ "$start_step" -eq 1 ]; then
        echo -e "${YELLOW}This will deploy changes from ${BOLD}$dev_site${NC}${YELLOW} to ${BOLD}$stg_site${NC}"
        echo -e "${YELLOW}Actions:${NC}"
        echo -e "  - Export config from dev"
        echo -e "  - Sync files (excluding settings, files, .git)"
        echo -e "  - Run composer install --no-dev"
        echo -e "  - Run database updates"
        echo -e "  - Import configuration"
        echo -e "  - Clear cache"
        echo ""
        echo -n "Continue? [y/N]: "
        read confirm
        if [[ ! "$confirm" =~ ^[Yy] ]]; then
            print_info "Deployment cancelled"
            return 1
        fi
    elif [ "$auto_yes" == "true" ]; then
        echo -e "Auto-confirmed: Deploying ${BOLD}$dev_site${NC} to ${BOLD}$stg_site${NC}"
    fi

    # Get webroot
    local webroot=$(get_webroot "$dev_site")
    ocmsg "Webroot: $webroot"

    # Execute deployment steps
    if should_run_step 1 "$start_step"; then
        if ! validate_sites "$dev_site" "$stg_site"; then
            return 1
        fi
    else
        print_status "INFO" "Skipping Step 1: Sites already validated"
    fi

    if should_run_step 2 "$start_step"; then
        export_config_dev "$dev_site"
    else
        print_status "INFO" "Skipping Step 2: Config already exported"
    fi

    if should_run_step 3 "$start_step"; then
        if ! sync_files "$dev_site" "$stg_site" "$webroot"; then
            return 1
        fi
    else
        print_status "INFO" "Skipping Step 3: Files already synced"
    fi

    if should_run_step 4 "$start_step"; then
        run_composer_staging "$stg_site"
    else
        print_status "INFO" "Skipping Step 4: Composer already run"
    fi

    if should_run_step 5 "$start_step"; then
        run_db_updates "$stg_site"
    else
        print_status "INFO" "Skipping Step 5: Database updates already run"
    fi

    if should_run_step 6 "$start_step"; then
        import_config_staging "$stg_site"
    else
        print_status "INFO" "Skipping Step 6: Config already imported"
    fi

    if should_run_step 7 "$start_step"; then
        reinstall_modules "$stg_site"
    else
        print_status "INFO" "Skipping Step 7: Modules already reinstalled"
    fi

    if should_run_step 8 "$start_step"; then
        clear_cache_staging "$stg_site"
    else
        print_status "INFO" "Skipping Step 8: Cache already cleared"
    fi

    if should_run_step 9 "$start_step"; then
        display_staging_url "$stg_site"
    fi

    return 0
}

################################################################################
# Main Script
################################################################################

main() {
    # Parse options
    local DEBUG=false
    local AUTO_YES=false
    local START_STEP=1
    local SITENAME=""

    # Use getopt for option parsing
    local OPTIONS=hdys:
    local LONGOPTS=help,debug,yes,step:

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

    ocmsg "Site: $SITENAME"
    ocmsg "Auto yes: $AUTO_YES"
    ocmsg "Start step: $START_STEP"

    # Run deployment
    if deploy_dev2stg "$SITENAME" "$AUTO_YES" "$START_STEP"; then
        show_elapsed_time
        exit 0
    else
        print_error "Deployment failed"
        exit 1
    fi
}

# Run main
main "$@"
