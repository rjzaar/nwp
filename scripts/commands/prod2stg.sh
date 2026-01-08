#!/bin/bash

################################################################################
# NWP Production to Staging Pull Script
#
# Pulls code and database from Linode production server to local staging
# Uses SSH/rsync for file transfer and remote/local drush commands
#
# Usage: ./prod2stg.sh [OPTIONS] <sitename>
################################################################################

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

# Source shared libraries
source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh"

# Source YAML library
if [ -f "$PROJECT_ROOT/lib/yaml-write.sh" ]; then
    source "$PROJECT_ROOT/lib/yaml-write.sh"
fi

# Script start time
START_TIME=$(date +%s)

################################################################################
# Helper Functions
################################################################################

# Display elapsed time
show_elapsed_time() {
    local end_time=$(date +%s)
    local elapsed=$((end_time - START_TIME))
    local hours=$((elapsed / 3600))
    local minutes=$(((elapsed % 3600) / 60))
    local seconds=$((elapsed % 60))

    echo ""
    print_status "OK" "Pull completed in $(printf "%02d:%02d:%02d" $hours $minutes $seconds)"
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

# Get recipe value from cnwp.yml
get_recipe_value() {
    local recipe=$1
    local key=$2

    awk -v recipe="$recipe" -v key="$key" '
        /^  [a-z_]+:/ { current_recipe = $1; sub(/:$/, "", current_recipe) }
        current_recipe == recipe && $0 ~ "^    " key ": " {
            value = $0
            sub(/^    [^:]+: /, "", value)
            print value
            exit
        }
    ' "$PROJECT_ROOT/cnwp.yml"
}

# Get site value from cnwp.yml
get_site_value() {
    local site=$1
    local key=$2

    awk -v site="$site" -v key="$key" '
        /^  [a-z_0-9]+:/ && $0 !~ /^    / {
            current_site = $1
            sub(/:$/, "", current_site)
        }
        $0 ~ /^sites:/ { in_sites=1 }
        in_sites && current_site == site && $0 ~ "^    " key ": " {
            value = $0
            sub(/^    [^:]+: /, "", value)
            print value
            exit
        }
    ' "$PROJECT_ROOT/cnwp.yml"
}

# Get production config from site or recipe
get_prod_config() {
    local sitename=$1
    local key=$2

    # First try site-specific config
    local value=$(get_site_value "$sitename" "production_config.$key")

    # If not found, try recipe default
    if [ -z "$value" ]; then
        local recipe=$(get_site_value "$sitename" "recipe")
        if [ -n "$recipe" ]; then
            value=$(get_recipe_value "$recipe" "prod_$key")
        fi
    fi

    echo "$value"
}

# Get Linode server config
get_linode_server() {
    local server_name=$1
    local key=$2

    awk -v server="$server_name" -v key="$key" '
        /^linode:/ { in_linode=1 }
        in_linode && /^  servers:/ { in_servers=1 }
        in_servers && $0 ~ "^    " server ":" { current_server=server; in_server_block=1 }
        in_server_block && $0 ~ "^      " key ": " {
            value = $0
            sub(/^      [^:]+: /, "", value)
            print value
            exit
        }
        in_server_block && /^    [a-z]/ && $0 !~ "^    " server ":" { in_server_block=0 }
    ' "$PROJECT_ROOT/cnwp.yml"
}

# Get SSH connection string
get_ssh_connection() {
    local server_name=$1

    local ssh_user=$(get_linode_server "$server_name" "ssh_user")
    local ssh_host=$(get_linode_server "$server_name" "ssh_host")
    local ssh_port=$(get_linode_server "$server_name" "ssh_port")
    local ssh_key=$(get_linode_server "$server_name" "ssh_key")

    if [ -z "$ssh_user" ] || [ -z "$ssh_host" ]; then
        return 1
    fi

    # Expand ~ to home directory in ssh_key
    if [ -n "$ssh_key" ]; then
        ssh_key="${ssh_key/#\~/$HOME}"
        if [ ! -f "$ssh_key" ]; then
            print_error "SSH key not found: $ssh_key"
            return 1
        fi
        # Store for use with rsync
        export SSH_KEY="$ssh_key"
    fi

    # Build connection string
    local conn="${ssh_user}@${ssh_host}"

    # Add port if not default
    if [ -n "$ssh_port" ] && [ "$ssh_port" != "22" ]; then
        conn="$conn -p ${ssh_port}"
    fi

    # Add key if specified
    if [ -n "$ssh_key" ]; then
        conn="$conn -i $ssh_key"
    fi

    echo "$conn"
}

################################################################################
# Main Functions
################################################################################

show_help() {
    cat << EOF
NWP Production to Staging Pull Script

Pulls code and database from Linode production server to local staging environment.

USAGE:
    $0 [OPTIONS] <sitename>

OPTIONS:
    -y, --yes           Auto-confirm (skip all prompts)
    -d, --debug         Enable debug output
    --step=N            Start from step N (1-10)
    --dry-run           Show what would be done without making changes
    --files-only        Pull only files, skip database
    --db-only           Pull only database, skip files
    -h, --help          Show this help message

ARGUMENTS:
    <sitename>          Name of the staging site to pull production data into

STEPS:
    1. Validate Pull Configuration
    2. Test SSH Connection
    3. Backup Local Staging
    4. Pull Files from Production
    5. Export Production Database
    6. Import Database to Staging
    7. Update Database
    8. Import Configuration
    9. Reinstall Modules
    10. Clear Cache

EXAMPLES:
    # Pull production to nwp-stg
    ./prod2stg.sh nwp-stg

    # Pull with auto-confirm
    ./prod2stg.sh -y nwp-stg

    # Pull only files
    ./prod2stg.sh --files-only nwp-stg

    # Pull only database
    ./prod2stg.sh --db-only nwp-stg

    # Dry run (show what would happen)
    ./prod2stg.sh --dry-run nwp-stg

CONFIGURATION:
    Production configuration is read from cnwp.yml:
    - Site-specific: sites.<sitename>.production_config
    - Recipe default: recipes.<recipe>.prod_*
    - Linode server: linode.servers.<server_name>

EOF
}

################################################################################
# Parse Arguments
################################################################################

AUTO_CONFIRM=false
DEBUG=false
START_STEP=1
DRY_RUN=false
FILES_ONLY=false
DB_ONLY=false
SITENAME=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -y|--yes)
            AUTO_CONFIRM=true
            shift
            ;;
        -d|--debug)
            DEBUG=true
            shift
            ;;
        --step=*)
            START_STEP="${1#*=}"
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --files-only)
            FILES_ONLY=true
            shift
            ;;
        --db-only)
            DB_ONLY=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        -*)
            print_error "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
        *)
            if [ -z "$SITENAME" ]; then
                SITENAME="$1"
            else
                print_error "Multiple site names provided: $SITENAME and $1"
                exit 1
            fi
            shift
            ;;
    esac
done

# Validate sitename provided
if [ -z "$SITENAME" ]; then
    print_error "No site name provided"
    echo "Use --help for usage information"
    exit 1
fi

# Validate mutually exclusive options
if [ "$FILES_ONLY" = true ] && [ "$DB_ONLY" = true ]; then
    print_error "Cannot use --files-only and --db-only together"
    exit 1
fi

################################################################################
# Main Deployment Process
################################################################################

print_header "NWP Production to Staging Pull: $SITENAME"

if [ "$DRY_RUN" = true ]; then
    print_info "DRY RUN MODE - No changes will be made"
fi

if [ "$AUTO_CONFIRM" = true ]; then
    print_status "INFO" "Auto-confirm enabled"
fi

################################################################################
# Step 1: Validate Pull Configuration
################################################################################

if should_run_step 1 "$START_STEP"; then
    print_header "Step 1: Validate Pull Configuration"

    # Check staging site exists
    if [ ! -d "sites/$SITENAME" ]; then
        print_error "Staging site not found: sites/$SITENAME"
        print_info "Create staging site first with: ./install.sh $SITENAME"
        exit 1
    fi
    print_status "OK" "Staging site exists: sites/$SITENAME"

    # Get production config
    PROD_SERVER=$(get_prod_config "$SITENAME" "server")
    PROD_PATH=$(get_prod_config "$SITENAME" "remote_path")
    PROD_DOMAIN=$(get_prod_config "$SITENAME" "domain")

    if [ -z "$PROD_SERVER" ]; then
        print_error "Production server not configured for $SITENAME"
        print_info "Add production config to cnwp.yml under sites.$SITENAME.production_config"
        exit 1
    fi
    print_status "OK" "Production server: $PROD_SERVER"

    if [ -z "$PROD_PATH" ]; then
        print_error "Production path not configured"
        exit 1
    fi
    print_status "OK" "Production path: $PROD_PATH"

    if [ -n "$PROD_DOMAIN" ]; then
        print_status "OK" "Production domain: $PROD_DOMAIN"
    fi

    # Get SSH connection details
    SSH_CONN=$(get_ssh_connection "$PROD_SERVER")
    if [ -z "$SSH_CONN" ]; then
        print_error "Failed to get SSH connection details for server: $PROD_SERVER"
        print_info "Check linode.servers.$PROD_SERVER configuration in cnwp.yml"
        exit 1
    fi
    print_status "OK" "SSH connection: $SSH_CONN"

    # Confirm pull
    if [ "$AUTO_CONFIRM" = false ]; then
        echo ""
        echo -e "${YELLOW}${BOLD}WARNING:${NC} This will pull production data to staging"
        echo "  From: $PROD_SERVER:$PROD_PATH"
        echo "  To:   $SITENAME"
        if [ "$FILES_ONLY" = true ]; then
            echo "  Mode: Files only"
        elif [ "$DB_ONLY" = true ]; then
            echo "  Mode: Database only"
        else
            echo "  Mode: Files and database"
        fi
        echo ""
        read -p "Continue? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_info "Pull cancelled"
            exit 0
        fi
    fi
fi

################################################################################
# Step 2: Test SSH Connection
################################################################################

if should_run_step 2 "$START_STEP"; then
    print_header "Step 2: Test SSH Connection"

    if [ "$DRY_RUN" = false ]; then
        if ssh $SSH_CONN "cd $PROD_PATH && pwd" >/dev/null 2>&1; then
            print_status "OK" "SSH connection successful"
        else
            print_error "SSH connection failed"
            print_info "Check SSH credentials and server access"
            exit 1
        fi

        # Check production path exists
        if ssh $SSH_CONN "[ -d $PROD_PATH ]"; then
            print_status "OK" "Production path exists"
        else
            print_error "Production path not found: $PROD_PATH"
            exit 1
        fi
    else
        print_status "INFO" "Would test SSH connection to $SSH_CONN"
    fi
fi

################################################################################
# Step 3: Backup Local Staging
################################################################################

if should_run_step 3 "$START_STEP"; then
    print_header "Step 3: Backup Local Staging"

    if [ "$DRY_RUN" = false ]; then
        print_info "Creating backup before pull..."
        if "$SCRIPT_DIR/backup.sh" "$SITENAME" "Pre-prod2stg-backup" >/dev/null 2>&1; then
            print_status "OK" "Local backup created"
        else
            print_status "WARN" "Backup failed, but continuing"
        fi
    else
        print_status "INFO" "Would create backup of sites/$SITENAME"
    fi
fi

################################################################################
# Step 4: Pull Files from Production
################################################################################

if should_run_step 4 "$START_STEP" && [ "$DB_ONLY" = false ]; then
    print_header "Step 4: Pull Files from Production"

    if [ "$DRY_RUN" = false ]; then
        print_info "Syncing files from production..."
        print_info "Source: $SSH_CONN:$PROD_PATH/"
        print_info "Destination: $SITENAME/"

        # Build SSH options for rsync
        local rsync_ssh="ssh"
        if echo "$SSH_CONN" | grep -q '\-p'; then
            local port=$(echo "$SSH_CONN" | grep -o '\-p [0-9]*' | awk '{print $2}')
            rsync_ssh="$rsync_ssh -p $port"
        fi
        if [ -n "$SSH_KEY" ]; then
            rsync_ssh="$rsync_ssh -i $SSH_KEY"
        fi

        # Extract user@host (first part before any options)
        local user_host=$(echo "$SSH_CONN" | cut -d' ' -f1)

        # Rsync with SSH
        if rsync -avz --delete \
            -e "$rsync_ssh" \
            "$user_host:$PROD_PATH/" \
            "$PROJECT_ROOT/sites/$SITENAME/" \
            --exclude=".ddev" \
            --exclude=".git" \
            --exclude="html/sites/default/files" \
            --exclude="private" \
            ; then
            print_status "OK" "Files synced successfully"
        else
            print_error "File sync failed"
            exit 1
        fi
    else
        print_status "INFO" "Would sync files from production to staging"
    fi
fi

################################################################################
# Step 5: Export Production Database
################################################################################

if should_run_step 5 "$START_STEP" && [ "$FILES_ONLY" = false ]; then
    print_header "Step 5: Export Production Database"

    if [ "$DRY_RUN" = false ]; then
        print_info "Exporting production database..."

        # Create temporary SQL file
        TMP_SQL="/tmp/prod2stg_${SITENAME}_$(date +%s).sql.gz"

        # Build SCP options
        local scp_opts=""
        if echo "$SSH_CONN" | grep -q '\-p'; then
            local port=$(echo "$SSH_CONN" | grep -o '\-p [0-9]*' | awk '{print $2}')
            scp_opts="-P $port"
        fi
        if [ -n "$SSH_KEY" ]; then
            scp_opts="$scp_opts -i $SSH_KEY"
        fi

        # Extract user@host
        local user_host=$(echo "$SSH_CONN" | cut -d' ' -f1)

        # Export database via SSH
        if ssh $SSH_CONN "cd $PROD_PATH && drush sql:dump --gzip --result-file=/tmp/prod_export.sql" && \
           scp $scp_opts "$user_host:/tmp/prod_export.sql.gz" "$TMP_SQL" && \
           ssh $SSH_CONN "rm /tmp/prod_export.sql.gz"; then
            print_status "OK" "Database exported"
            print_info "Temp file: $TMP_SQL"
        else
            print_error "Database export failed"
            exit 1
        fi
    else
        print_status "INFO" "Would export production database"
    fi
fi

################################################################################
# Step 6: Import Database to Staging
################################################################################

if should_run_step 6 "$START_STEP" && [ "$FILES_ONLY" = false ]; then
    print_header "Step 6: Import Database to Staging"

    if [ "$DRY_RUN" = false ]; then
        print_info "Importing database to staging..."

        cd "sites/$SITENAME" || exit 1

        # Import database
        if ddev import-db --file="$TMP_SQL"; then
            print_status "OK" "Database imported"

            # Clean up temp file
            rm -f "$TMP_SQL"
        else
            print_error "Database import failed"
            cd "$PROJECT_ROOT"
            exit 1
        fi

        cd "$PROJECT_ROOT"
    else
        print_status "INFO" "Would import database to staging"
    fi
fi

################################################################################
# Step 7: Update Database
################################################################################

if should_run_step 7 "$START_STEP" && [ "$FILES_ONLY" = false ]; then
    print_header "Step 7: Update Database"

    if [ "$DRY_RUN" = false ]; then
        cd "$PROJECT_ROOT/sites/$SITENAME" || exit 1

        print_info "Running database updates..."
        if ddev drush updatedb -y; then
            print_status "OK" "Database updated"
        else
            print_status "WARN" "Database updates had warnings (may be normal)"
        fi

        cd "$PROJECT_ROOT"
    else
        print_status "INFO" "Would run database updates"
    fi
fi

################################################################################
# Step 8: Import Configuration
################################################################################

if should_run_step 8 "$START_STEP" && [ "$FILES_ONLY" = false ]; then
    print_header "Step 8: Import Configuration"

    if [ "$DRY_RUN" = false ]; then
        cd "$PROJECT_ROOT/sites/$SITENAME" || exit 1

        print_info "Importing configuration..."
        if ddev drush config:import -y; then
            print_status "OK" "Configuration imported"
        else
            print_status "WARN" "Configuration import had warnings (may be normal)"
        fi

        cd "$PROJECT_ROOT"
    else
        print_status "INFO" "Would import configuration"
    fi
fi

################################################################################
# Step 9: Reinstall Modules
################################################################################

if should_run_step 9 "$START_STEP" && [ "$FILES_ONLY" = false ]; then
    print_header "Step 9: Reinstall Modules"

    # Get base sitename (remove -stg or _stg suffix, support legacy during migration)
    BASE_NAME="${SITENAME%-stg}"
    BASE_NAME="${BASE_NAME%_stg}"

    # Get recipe
    RECIPE=$(get_site_value "$BASE_NAME" "recipe")
    if [ -z "$RECIPE" ]; then
        RECIPE="$BASE_NAME"
    fi

    # Read reinstall_modules from recipe
    REINSTALL_MODULES=$(awk -v recipe="$RECIPE" '
        /^  [a-z_]+:/ { current_recipe = $1; sub(/:$/, "", current_recipe) }
        current_recipe == recipe && /^    reinstall_modules:/ { in_modules=1; next }
        in_modules && /^      - / { print $2 }
        in_modules && /^    [a-z_]/ { in_modules=0 }
    ' "$PROJECT_ROOT/cnwp.yml")

    if [ -n "$REINSTALL_MODULES" ]; then
        if [ "$DRY_RUN" = false ]; then
            cd "$PROJECT_ROOT/sites/$SITENAME" || exit 1

            for module in $REINSTALL_MODULES; do
                # Check if module is enabled
                if ddev drush pm:list --status=enabled --format=list 2>/dev/null | grep -q "^${module}$"; then
                    print_info "Reinstalling module: $module"

                    # Uninstall
                    if ddev drush pm:uninstall -y "$module" 2>/dev/null; then
                        # Re-enable
                        if ddev drush pm:enable -y "$module" 2>/dev/null; then
                            print_status "OK" "Module reinstalled: $module"
                        else
                            print_status "WARN" "Failed to re-enable: $module"
                        fi
                    else
                        print_status "WARN" "Failed to uninstall: $module"
                    fi
                else
                    print_status "INFO" "Module not enabled, skipping: $module"
                fi
            done

            cd "$PROJECT_ROOT"
        else
            print_status "INFO" "Would reinstall modules: $(echo $REINSTALL_MODULES | tr '\n' ' ')"
        fi
    else
        print_status "INFO" "No modules configured for reinstallation"
    fi
fi

################################################################################
# Step 10: Clear Cache
################################################################################

if should_run_step 10 "$START_STEP"; then
    print_header "Step 10: Clear Cache"

    if [ "$DRY_RUN" = false ]; then
        cd "$PROJECT_ROOT/sites/$SITENAME" || exit 1

        print_info "Clearing cache..."
        if ddev drush cr; then
            print_status "OK" "Cache cleared"
        else
            print_status "WARN" "Cache clear failed"
        fi

        # Get staging URL
        STAGING_URL=$(ddev describe -j | grep -o '"primary_url":"[^"]*"' | cut -d'"' -f4)
        if [ -n "$STAGING_URL" ]; then
            echo ""
            print_status "OK" "Staging site ready: $STAGING_URL"
        fi

        cd "$PROJECT_ROOT"
    else
        print_status "INFO" "Would clear cache"
    fi
fi

################################################################################
# Completion
################################################################################

print_header "Pull Complete"

if [ "$DRY_RUN" = false ]; then
    print_status "OK" "Production data successfully pulled to staging: $SITENAME"
else
    print_status "INFO" "Dry run complete - no changes made"
fi

show_elapsed_time

exit 0
