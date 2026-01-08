#!/bin/bash

################################################################################
# NWP Dev to Staging Deployment Script (Enhanced)
#
# Deploys changes from development environment to staging with:
# - Intelligent state detection
# - Auto-create staging if missing
# - Multi-source database routing
# - Multi-tier testing (8 types, 5 presets)
# - Interactive TUI or automated (-y) mode
# - Doctor/preflight checks
#
# Usage: ./dev2stg.sh [OPTIONS] <sitename>
################################################################################

# Get script directory and project root
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

# Script start time
START_TIME=$(date +%s)

################################################################################
# Source Libraries
################################################################################

# Core libraries
source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh" 2>/dev/null || true

# New enhanced libraries
source "$PROJECT_ROOT/lib/state.sh"
source "$PROJECT_ROOT/lib/database-router.sh"
source "$PROJECT_ROOT/lib/testing.sh"
source "$PROJECT_ROOT/lib/preflight.sh"
source "$PROJECT_ROOT/lib/dev2stg-tui.sh"

# YAML library (if available)
if [ -f "$PROJECT_ROOT/lib/yaml-write.sh" ]; then
    source "$PROJECT_ROOT/lib/yaml-write.sh"
fi

################################################################################
# Configuration
################################################################################

# Default values
DEFAULT_TEST_SELECTION="essential"
DEFAULT_DB_SOURCE="auto"
CONFIG_IMPORT_RETRIES=3

################################################################################
# Help
################################################################################

show_help() {
    cat << EOF
${BOLD}NWP Dev to Staging Deployment Script (Enhanced)${NC}

${BOLD}USAGE:${NC}
    ./dev2stg.sh [OPTIONS] <sitename>

${BOLD}OPTIONS:${NC}
    -h, --help              Show this help message
    -d, --debug             Enable debug output
    -y, --yes               Skip confirmation prompts (CI/CD mode)
    -s N, --step=N          Resume from step N

${BOLD}DATABASE OPTIONS:${NC}
    --db-source SOURCE      Database source:
                              auto        - Auto-select best (default)
                              production  - Fresh from production
                              development - Clone dev database
                              /path/file  - Specific backup file
    --fresh-backup          Force fresh backup from production
    --dev-db                Use development database
    --no-sanitize           Skip database sanitization

${BOLD}TESTING OPTIONS:${NC}
    -t, --test SELECTION    Test selection:
                              Presets: quick, essential, functional, full, security-only
                              Types: phpunit,behat,phpstan,phpcs,eslint,stylelint,security,accessibility
                              skip - No tests

${BOLD}STAGING OPTIONS:${NC}
    --create-stg            Create staging site if missing (default: prompt)
    --no-create-stg         Fail if staging doesn't exist
    --preflight             Run preflight checks only (no deployment)

${BOLD}EXAMPLES:${NC}
    # Interactive mode (shows TUI with all options)
    ./dev2stg.sh avc

    # Automated with essential tests
    ./dev2stg.sh avc -y -t essential

    # Specific test types only
    ./dev2stg.sh avc -y -t phpunit,phpstan

    # Fresh production backup, full tests
    ./dev2stg.sh avc -y --fresh-backup -t full

    # Quick syntax check
    ./dev2stg.sh avc -y -t quick

    # Pre-flight check only (no deployment)
    ./dev2stg.sh avc --preflight

    # Resume from step 5
    ./dev2stg.sh avc -s 5

${BOLD}DEPLOYMENT WORKFLOW:${NC}
    1. State detection & preflight checks
    2. Create staging site (if needed)
    3. Export configuration from dev
    4. Sync files from dev to staging
    5. Restore/sync database
    6. Run composer install --no-dev
    7. Run database updates
    8. Import configuration (3x retry)
    9. Set production mode
    10. Run tests
    11. Display staging URL

EOF
}

################################################################################
# Environment Detection
################################################################################

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

get_stg_name() {
    local base=$1
    echo "${base}-stg"
}

get_webroot() {
    local site=$1
    local webroot=$(grep "^docroot:" "$site/.ddev/config.yaml" 2>/dev/null | awk '{print $2}')
    echo "${webroot:-web}"
}

################################################################################
# Step Functions
################################################################################

# Step: Create staging site
create_staging_site() {
    local dev_site=$1
    local stg_site=$2

    step 1 11 "Creating staging site: $stg_site"

    # Create directory
    if [ -d "$PROJECT_ROOT/sites/$stg_site" ]; then
        warn "Staging directory already exists"
        return 0
    fi

    task "Copying codebase from $PROJECT_ROOT/sites/$dev_site..."
    rsync -av --exclude='.ddev' --exclude='vendor' \
          --exclude='node_modules' --exclude='*.sql*' \
          --exclude='private/' \
          "$PROJECT_ROOT/sites/$dev_site/" "$PROJECT_ROOT/sites/$stg_site/" > /dev/null 2>&1 || {
        fail "Failed to copy codebase"
        return 1
    }

    task "Creating DDEV configuration..."
    mkdir -p "$PROJECT_ROOT/sites/$stg_site/.ddev"

    # Copy and modify DDEV config
    local webroot=$(get_webroot "$PROJECT_ROOT/sites/$dev_site")
    local dev_name=$(basename "$dev_site")
    local stg_name=$(basename "$stg_site")

    # Create new DDEV config
    cat > "$PROJECT_ROOT/sites/$stg_site/.ddev/config.yaml" << DDEVEOF
name: $stg_name
type: drupal
docroot: $webroot
php_version: "8.2"
webserver_type: nginx-fpm
database:
  type: mariadb
  version: "10.11"
DDEVEOF

    task "Starting DDEV..."
    (cd "$PROJECT_ROOT/sites/$stg_site" && ddev start) || {
        fail "Failed to start DDEV"
        return 1
    }

    pass "Staging site created"
    return 0
}

# Step: Export configuration from dev
export_config_dev() {
    local dev_site=$1

    step 2 11 "Export configuration from dev"

    local original_dir=$(pwd)
    cd "$PROJECT_ROOT/sites/$dev_site" || {
        fail "Cannot access dev site: $PROJECT_ROOT/sites/$dev_site"
        return 1
    }

    task "Exporting configuration..."
    if ddev drush config:export -y > /dev/null 2>&1; then
        pass "Configuration exported"
    else
        warn "Could not export configuration (may not be needed)"
    fi

    cd "$original_dir"
    return 0
}

# Step: Sync files
sync_files() {
    local dev_site=$1
    local stg_site=$2

    step 3 11 "Sync files from dev to staging"

    local webroot=$(get_webroot "$PROJECT_ROOT/sites/$dev_site")

    task "Syncing files with rsync..."

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

    if rsync -av --delete "${excludes[@]}" "$PROJECT_ROOT/sites/$dev_site/" "$PROJECT_ROOT/sites/$stg_site/" > /dev/null 2>&1; then
        pass "Files synced to staging"
    else
        fail "File sync failed"
        return 1
    fi

    return 0
}

# Step: Database sync
sync_database() {
    local dev_site=$1
    local stg_site=$2
    local db_source=$3
    local sanitize=$4

    step 4 11 "Restore/sync database"

    # Use the database router
    download_database "$(basename "$dev_site")" "$db_source" "$(basename "$stg_site")" || {
        fail "Database sync failed"
        return 1
    }

    # Sanitize if not already sanitized
    if [ "$sanitize" = "true" ] && [[ ! "$db_source" =~ sanitized ]]; then
        sanitize_staging_db "$(basename "$stg_site")"
    fi

    pass "Database synced"
    return 0
}

# Step: Composer install
run_composer_staging() {
    local stg_site=$1

    step 5 11 "Run composer install --no-dev"

    local original_dir=$(pwd)
    cd "$PROJECT_ROOT/sites/$stg_site" || {
        fail "Cannot access staging site"
        return 1
    }

    task "Installing dependencies..."
    if ddev composer install --no-dev > /dev/null 2>&1; then
        pass "Composer dependencies installed"
    else
        warn "Composer install had warnings (non-fatal)"
    fi

    cd "$original_dir"
    return 0
}

# Step: Database updates
run_db_updates() {
    local stg_site=$1

    step 6 11 "Run database updates"

    local original_dir=$(pwd)
    cd "$PROJECT_ROOT/sites/$stg_site" || {
        fail "Cannot access staging site"
        return 1
    }

    task "Running drush updatedb..."
    if ddev drush updatedb -y > /dev/null 2>&1; then
        pass "Database updates completed"
    else
        warn "Database updates had warnings"
    fi

    cd "$original_dir"
    return 0
}

# Step: Import configuration with retry
import_config_staging() {
    local stg_site=$1

    step 7 11 "Import configuration (${CONFIG_IMPORT_RETRIES}x retry)"

    local original_dir=$(pwd)
    cd "$PROJECT_ROOT/sites/$stg_site" || {
        fail "Cannot access staging site"
        return 1
    }

    local success=false
    for i in $(seq 1 $CONFIG_IMPORT_RETRIES); do
        task "Config import attempt $i of $CONFIG_IMPORT_RETRIES..."
        if ddev drush config:import -y > /dev/null 2>&1; then
            success=true
            break
        fi
        note "Retrying due to dependency ordering..."
    done

    if [ "$success" = "true" ]; then
        pass "Configuration imported"
    else
        warn "Configuration import had issues"
    fi

    cd "$original_dir"
    return 0
}

# Step: Clear cache
clear_cache_staging() {
    local stg_site=$1

    task "Clearing cache..."

    local original_dir=$(pwd)
    cd "$PROJECT_ROOT/sites/$stg_site" || return 1

    ddev drush cache:rebuild > /dev/null 2>&1
    pass "Cache cleared"

    cd "$original_dir"
    return 0
}

# Step: Enable production mode
enable_prod_mode() {
    local stg_site=$1

    step 8 11 "Set production mode"

    # Use make.sh if available
    if [ -x "$SCRIPT_DIR/make.sh" ]; then
        task "Running make.sh -py..."
        if "$SCRIPT_DIR/make.sh" -py "$(basename "$stg_site")" > /dev/null 2>&1; then
            pass "Production mode enabled"
        else
            warn "Could not fully enable production mode"
        fi
    else
        task "Disabling dev modules manually..."
        local original_dir=$(pwd)
        cd "$PROJECT_ROOT/sites/$stg_site" || return 0

        # Disable common dev modules
        for module in devel webprofiler kint stage_file_proxy; do
            ddev drush pm:uninstall -y "$module" 2>/dev/null || true
        done

        # Enable caching
        ddev drush config:set system.performance css.preprocess 1 -y 2>/dev/null
        ddev drush config:set system.performance js.preprocess 1 -y 2>/dev/null
        ddev drush cr 2>/dev/null

        pass "Production mode enabled"
        cd "$original_dir"
    fi

    return 0
}

# Step: Run tests
run_deployment_tests() {
    local stg_site=$1
    local test_selection=$2

    step 9 11 "Run tests: $test_selection"

    if [ "$test_selection" = "skip" ]; then
        note "Tests skipped as requested"
        return 0
    fi

    run_tests "$(basename "$stg_site")" "$test_selection"
    local result=$?

    if [ $result -eq 0 ]; then
        pass "All tests passed"
    else
        warn "$result test(s) failed"
    fi

    return $result
}

# Step: Display staging URL
display_staging_url() {
    local stg_site=$1

    step 10 11 "Deployment complete"

    local original_dir=$(pwd)
    cd "$PROJECT_ROOT/sites/$stg_site" || return 0

    local stg_url=$(ddev describe 2>/dev/null | grep -oP 'https://[^ ,]+' | head -1)

    if [ -n "$stg_url" ]; then
        echo ""
        echo -e "${BOLD}Staging URL:${NC} $stg_url"
    fi

    cd "$original_dir"

    # Show elapsed time
    local end_time=$(date +%s)
    local elapsed=$((end_time - START_TIME))
    local minutes=$((elapsed / 60))
    local seconds=$((elapsed % 60))
    echo ""
    pass "Deployment completed in ${minutes}m ${seconds}s"

    return 0
}

################################################################################
# Main Deployment Function
################################################################################

deploy_dev2stg() {
    local dev_site=$1
    local auto_yes=$2
    local start_step=${3:-1}
    local db_source=$4
    local test_selection=$5
    local create_stg=$6
    local sanitize=$7

    # Determine site names
    local base_name=$(get_base_name "$dev_site")
    local stg_site="${base_name}-stg"

    print_header "NWP Dev to Staging Deployment"
    info "Source: $dev_site (development)"
    info "Target: $stg_site (staging)"
    echo ""

    # Preflight check (quick for -y mode, full otherwise)
    if [ "$auto_yes" = "true" ]; then
        quick_preflight "$dev_site" || return 1
    else
        if ! preflight_check "$dev_site" "$stg_site"; then
            fail "Preflight checks failed"
            return 1
        fi
    fi

    # Check if staging exists
    if [ ! -d "$PROJECT_ROOT/sites/$stg_site" ]; then
        if [ "$create_stg" = "true" ] || [ "$auto_yes" = "true" ]; then
            info "Staging site does not exist - creating..."
            create_staging_site "$dev_site" "$stg_site" || return 1
        elif [ "$create_stg" = "false" ]; then
            fail "Staging site does not exist and --no-create-stg specified"
            return 1
        else
            echo ""
            read -p "Staging site does not exist. Create it? [Y/n]: " response
            if [[ "$response" =~ ^[Nn] ]]; then
                info "Deployment cancelled"
                return 1
            fi
            create_staging_site "$dev_site" "$stg_site" || return 1
        fi
    fi

    # Ensure staging DDEV is running
    if [ -d "$PROJECT_ROOT/sites/$stg_site" ]; then
        task "Ensuring staging DDEV is running..."
        (cd "$PROJECT_ROOT/sites/$stg_site" && ddev start > /dev/null 2>&1)
    fi

    # Execute deployment steps
    local current_step=2

    if [ "$start_step" -le "$current_step" ]; then
        export_config_dev "$dev_site" || return 1
    fi
    ((current_step++))

    if [ "$start_step" -le "$current_step" ]; then
        sync_files "$dev_site" "$stg_site" || return 1
    fi
    ((current_step++))

    if [ "$start_step" -le "$current_step" ]; then
        sync_database "$dev_site" "$stg_site" "$db_source" "$sanitize" || return 1
    fi
    ((current_step++))

    if [ "$start_step" -le "$current_step" ]; then
        run_composer_staging "$stg_site" || return 1
    fi
    ((current_step++))

    if [ "$start_step" -le "$current_step" ]; then
        run_db_updates "$stg_site" || return 1
    fi
    ((current_step++))

    if [ "$start_step" -le "$current_step" ]; then
        import_config_staging "$stg_site" || return 1
    fi
    ((current_step++))

    if [ "$start_step" -le "$current_step" ]; then
        clear_cache_staging "$stg_site"
        enable_prod_mode "$stg_site" || return 1
    fi
    ((current_step++))

    if [ "$start_step" -le "$current_step" ]; then
        run_deployment_tests "$stg_site" "$test_selection"
        # Don't fail deployment on test failures
    fi
    ((current_step++))

    display_staging_url "$stg_site"

    return 0
}

################################################################################
# Main
################################################################################

main() {
    # Parse options
    local DEBUG=false
    local AUTO_YES=false
    local START_STEP=1
    local SITENAME=""
    local DB_SOURCE="$DEFAULT_DB_SOURCE"
    local TEST_SELECTION="$DEFAULT_TEST_SELECTION"
    local CREATE_STG="prompt"
    local SANITIZE="true"
    local PREFLIGHT_ONLY=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
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
            --step=*)
                START_STEP="${1#*=}"
                shift
                ;;
            -t|--test)
                TEST_SELECTION="$2"
                shift 2
                ;;
            --test=*)
                TEST_SELECTION="${1#*=}"
                shift
                ;;
            --db-source)
                DB_SOURCE="$2"
                shift 2
                ;;
            --db-source=*)
                DB_SOURCE="${1#*=}"
                shift
                ;;
            --fresh-backup)
                DB_SOURCE="production"
                shift
                ;;
            --dev-db)
                DB_SOURCE="development"
                shift
                ;;
            --no-sanitize)
                SANITIZE="false"
                shift
                ;;
            --create-stg)
                CREATE_STG="true"
                shift
                ;;
            --no-create-stg)
                CREATE_STG="false"
                shift
                ;;
            --preflight)
                PREFLIGHT_ONLY=true
                shift
                ;;
            -*)
                # Handle combined short flags
                local flags="${1#-}"
                shift
                while [ -n "$flags" ]; do
                    local flag="${flags:0:1}"
                    flags="${flags:1}"
                    case "$flag" in
                        d) DEBUG=true ;;
                        y) AUTO_YES=true ;;
                        h) show_help; exit 0 ;;
                        *)
                            print_error "Unknown flag: -$flag"
                            exit 1
                            ;;
                    esac
                done
                ;;
            *)
                if [ -z "$SITENAME" ]; then
                    SITENAME="$1"
                fi
                shift
                ;;
        esac
    done

    # Export DEBUG for libraries
    export DEBUG

    # Validate sitename
    if [ -z "$SITENAME" ]; then
        print_error "Missing site name"
        echo ""
        show_help
        exit 1
    fi

    # Preflight only mode
    if [ "$PREFLIGHT_ONLY" = "true" ]; then
        preflight_check "$SITENAME"
        exit $?
    fi

    # Interactive TUI mode (if not -y and not starting from a step)
    if [ "$AUTO_YES" != "true" ] && [ "$START_STEP" -eq 1 ]; then
        # Run TUI
        if run_dev2stg_tui "$SITENAME"; then
            # TUI sets TUI_DB_SOURCE and TUI_TEST_SELECTION
            DB_SOURCE="$TUI_DB_SOURCE"
            TEST_SELECTION="$TUI_TEST_SELECTION"
        else
            info "Deployment cancelled"
            exit 0
        fi
    fi

    # Validate test selection
    if ! validate_test_selection "$TEST_SELECTION"; then
        exit 1
    fi

    # Run deployment
    if deploy_dev2stg "$SITENAME" "$AUTO_YES" "$START_STEP" "$DB_SOURCE" "$TEST_SELECTION" "$CREATE_STG" "$SANITIZE"; then
        exit 0
    else
        fail "Deployment failed"
        exit 1
    fi
}

# Run main
main "$@"
