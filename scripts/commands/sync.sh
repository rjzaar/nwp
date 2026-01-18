#!/bin/bash
set -euo pipefail

################################################################################
# NWP Sync Script
#
# Re-syncs an imported site with its remote source.
# Pulls fresh database and/or files from the original server.
#
# Usage: ./sync.sh <sitename> [options]
#
# Options:
#   --db-only               Only sync database (skip files)
#   --files-only            Only sync files (skip database)
#   --no-sanitize           Skip database sanitization
#   --backup                Create backup before syncing
#   --yes, -y               Auto-confirm prompts
#   --help, -h              Show this help
#
# Examples:
#   ./sync.sh site1                    # Full sync (database + files if configured)
#   ./sync.sh site1 --db-only          # Only sync database
#   ./sync.sh site1 --backup           # Backup before sync
#   ./sync.sh site1 --no-sanitize      # Sync without sanitizing
################################################################################

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

################################################################################
# Source Required Libraries
################################################################################

source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/server-scan.sh"
source "$PROJECT_ROOT/lib/import-tui.sh"
source "$PROJECT_ROOT/lib/import.sh"

################################################################################
# Configuration
################################################################################

CONFIG_FILE="$PROJECT_ROOT/nwp.yml"

# Default options
OPT_SITE_NAME=""
OPT_DB_ONLY="n"
OPT_FILES_ONLY="n"
OPT_NO_SANITIZE="n"
OPT_BACKUP="n"
OPT_YES="n"
OPT_HELP="n"

################################################################################
# Argument Parsing
################################################################################

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --db-only)
                OPT_DB_ONLY="y"
                shift
                ;;
            --files-only)
                OPT_FILES_ONLY="y"
                shift
                ;;
            --no-sanitize)
                OPT_NO_SANITIZE="y"
                shift
                ;;
            --backup)
                OPT_BACKUP="y"
                shift
                ;;
            --yes|-y)
                OPT_YES="y"
                shift
                ;;
            --help|-h)
                OPT_HELP="y"
                shift
                ;;
            -*)
                print_error "Unknown option: $1"
                exit 1
                ;;
            *)
                if [ -z "$OPT_SITE_NAME" ]; then
                    OPT_SITE_NAME="$1"
                else
                    print_error "Unexpected argument: $1"
                    exit 1
                fi
                shift
                ;;
        esac
    done
}

show_help() {
    head -30 "$0" | tail -25 | sed 's/^# //' | sed 's/^#//'
    exit 0
}

################################################################################
# Site Configuration Functions
################################################################################

# Get site configuration from nwp.yml
# Usage: get_site_import_config "site_name"
# Sets: SITE_SSH_HOST, SITE_SSH_KEY, SITE_WEBROOT, SITE_SERVER, etc.
get_site_import_config() {
    local site_name="$1"
    local config_file="$CONFIG_FILE"

    if [ ! -f "$config_file" ]; then
        return 1
    fi

    # Parse site entry from nwp.yml
    local in_sites=0
    local in_site=0
    local in_source=0

    while IFS= read -r line; do
        # Detect sections
        if [[ "$line" =~ ^sites: ]]; then
            in_sites=1
            continue
        fi

        if [ $in_sites -eq 1 ]; then
            # Check for our site
            if [[ "$line" =~ ^[[:space:]]{2}${site_name}: ]]; then
                in_site=1
                continue
            fi

            # Exiting our site section
            if [ $in_site -eq 1 ] && [[ "$line" =~ ^[[:space:]]{2}[a-zA-Z] ]] && [[ ! "$line" =~ ^[[:space:]]{4} ]]; then
                in_site=0
            fi

            if [ $in_site -eq 1 ]; then
                # Check for source section
                if [[ "$line" =~ ^[[:space:]]{4}source: ]]; then
                    in_source=1
                    continue
                fi

                # Exiting source section
                if [ $in_source -eq 1 ] && [[ "$line" =~ ^[[:space:]]{4}[a-zA-Z] ]] && [[ ! "$line" =~ ^[[:space:]]{6} ]]; then
                    in_source=0
                fi

                if [ $in_source -eq 1 ]; then
                    if [[ "$line" =~ ssh_host: ]]; then
                        SITE_SSH_HOST=$(echo "$line" | sed 's/.*ssh_host:[[:space:]]*//' | tr -d '"'"'")
                    fi
                    if [[ "$line" =~ webroot: ]]; then
                        SITE_WEBROOT=$(echo "$line" | sed 's/.*webroot:[[:space:]]*//' | tr -d '"'"'")
                    fi
                    if [[ "$line" =~ server: ]]; then
                        SITE_SERVER=$(echo "$line" | sed 's/.*server:[[:space:]]*//' | tr -d '"'"'")
                    fi
                fi

                # Other site fields
                if [[ "$line" =~ ^[[:space:]]{4}directory: ]]; then
                    SITE_DIRECTORY=$(echo "$line" | sed 's/.*directory:[[:space:]]*//' | tr -d '"'"'")
                fi
                if [[ "$line" =~ ^[[:space:]]{4}type: ]]; then
                    SITE_TYPE=$(echo "$line" | sed 's/.*type:[[:space:]]*//' | tr -d '"'"'")
                fi
            fi
        fi
    done < "$config_file"

    # Get SSH key from server config if server is specified
    if [ -n "$SITE_SERVER" ] && [ "$SITE_SERVER" != "custom" ]; then
        eval "$(get_server_config "$SITE_SERVER" "$config_file")"
        SITE_SSH_KEY="${SERVER_SSH_KEY:-$HOME/.ssh/nwp}"
    else
        SITE_SSH_KEY="$HOME/.ssh/nwp"
    fi

    # Validate we got what we need
    if [ -z "$SITE_SSH_HOST" ] || [ -z "$SITE_WEBROOT" ]; then
        return 1
    fi

    return 0
}

# Update last_sync timestamp in nwp.yml
update_last_sync() {
    local site_name="$1"
    local timestamp=$(date -Iseconds)

    if [ ! -f "$CONFIG_FILE" ]; then
        return 1
    fi

    # Use sed to update the last_sync field
    # This is a simple approach that works for our YAML structure
    sed -i "/^  ${site_name}:/,/^  [a-zA-Z]/ s/last_sync:.*/last_sync: \"$timestamp\"/" "$CONFIG_FILE"
}

################################################################################
# Sync Functions
################################################################################

sync_database() {
    local site_name="$1"
    local ssh_target="$2"
    local ssh_key="$3"
    local remote_site_dir="$4"
    local site_dir="$SITE_DIRECTORY"

    print_info "Syncing database..."

    cd "$site_dir" || return 1

    # Pull fresh database
    local start_time=$(date +%s)
    local ssh_opts=$(get_ssh_opts "$ssh_key")

    if ssh $ssh_opts "$ssh_target" "cd '$remote_site_dir' && vendor/bin/drush sql:dump --gzip 2>/dev/null" > db.sql.gz 2>/dev/null; then
        if [ -s db.sql.gz ]; then
            local size=$(du -h db.sql.gz | cut -f1)
            print_status "OK" "Database pulled: $size"
        else
            print_error "Database dump is empty"
            rm -f db.sql.gz
            return 1
        fi
    else
        print_error "Failed to pull database"
        rm -f db.sql.gz
        return 1
    fi

    # Import database
    print_info "Importing database..."
    if ! ddev describe >/dev/null 2>&1; then
        ddev start >/dev/null 2>&1
    fi

    if gunzip -c db.sql.gz | ddev mysql 2>/dev/null; then
        rm -f db.sql.gz
        print_status "OK" "Database imported"
    else
        print_error "Failed to import database"
        rm -f db.sql.gz
        return 1
    fi

    # Sanitize if enabled
    if [ "$OPT_NO_SANITIZE" != "y" ]; then
        print_info "Sanitizing database..."
        if ddev drush sql:sanitize -y 2>/dev/null; then
            print_status "OK" "Database sanitized"
        else
            print_warning "Sanitization had issues (non-fatal)"
        fi
    else
        print_info "Sanitization skipped"
    fi

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    print_status "OK" "Database sync complete (${duration}s)"

    return 0
}

sync_files() {
    local site_name="$1"
    local ssh_target="$2"
    local ssh_key="$3"
    local remote_site_dir="$4"
    local site_dir="$SITE_DIRECTORY"
    local webroot_name=$(basename "$SITE_WEBROOT")

    print_info "Syncing files..."

    local start_time=$(date +%s)

    # Incremental rsync of custom code and config
    rsync -avz \
        -e "ssh -i $ssh_key -o StrictHostKeyChecking=accept-new" \
        --include="composer.json" \
        --include="composer.lock" \
        --include="config/***" \
        --include="$webroot_name/modules/custom/***" \
        --include="$webroot_name/themes/custom/***" \
        --include="*/" \
        --exclude="$webroot_name/sites/default/files/*" \
        --exclude="vendor" \
        --exclude="node_modules" \
        --exclude=".git" \
        --prune-empty-dirs \
        "$ssh_target:$remote_site_dir/" \
        "$site_dir/" 2>/dev/null

    if [ $? -eq 0 ]; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        print_status "OK" "Files synced (${duration}s)"

        # Run composer install to update dependencies
        cd "$site_dir" || return 1
        print_info "Updating dependencies..."
        ddev composer install --no-interaction 2>/dev/null || true

        return 0
    else
        print_error "File sync failed"
        return 1
    fi
}

################################################################################
# Main Sync Function
################################################################################

do_sync() {
    local site_name="$OPT_SITE_NAME"
    local site_dir="$SITE_DIRECTORY"
    local remote_site_dir=$(dirname "$SITE_WEBROOT")

    print_header "Syncing: $site_name"

    print_info "Source: $SITE_SSH_HOST:$SITE_WEBROOT"
    print_info "Local:  $site_dir"
    echo ""

    # Test SSH connection
    print_info "Testing connection..."
    if ! test_ssh_connection "$SITE_SSH_HOST" "$SITE_SSH_KEY"; then
        print_error "Cannot connect to $SITE_SSH_HOST"
        exit 1
    fi
    print_status "OK" "Connected"

    # Create backup if requested
    if [ "$OPT_BACKUP" = "y" ]; then
        print_info "Creating backup..."
        if [ -x "$SCRIPT_DIR/backup.sh" ]; then
            "$SCRIPT_DIR/backup.sh" "$site_name" -y 2>/dev/null || true
            print_status "OK" "Backup created"
        else
            print_warning "backup.sh not found, skipping backup"
        fi
    fi

    local sync_success=0

    # Sync database
    if [ "$OPT_FILES_ONLY" != "y" ]; then
        if sync_database "$site_name" "$SITE_SSH_HOST" "$SITE_SSH_KEY" "$remote_site_dir"; then
            sync_success=1
        else
            print_error "Database sync failed"
            exit 1
        fi
    fi

    # Sync files
    if [ "$OPT_DB_ONLY" != "y" ]; then
        if sync_files "$site_name" "$SITE_SSH_HOST" "$SITE_SSH_KEY" "$remote_site_dir"; then
            sync_success=1
        else
            print_warning "File sync failed (non-fatal)"
        fi
    fi

    # Clear caches
    print_info "Clearing caches..."
    cd "$site_dir" || exit 1
    if ddev drush cache:rebuild 2>/dev/null; then
        print_status "OK" "Caches cleared"
    else
        print_warning "Cache clear had issues"
    fi

    # Update last_sync timestamp
    update_last_sync "$site_name"

    echo ""
    print_status "OK" "Sync complete for $site_name"
    echo ""
    echo "Next steps:"
    echo "  cd $site_name && ddev launch"
}

################################################################################
# Main
################################################################################

main() {
    parse_arguments "$@"

    if [ "$OPT_HELP" = "y" ]; then
        show_help
    fi

    if [ -z "$OPT_SITE_NAME" ]; then
        print_error "Site name required"
        echo "Usage: ./sync.sh <sitename> [options]"
        exit 1
    fi

    # Validate site name
    if ! validate_sitename "$OPT_SITE_NAME"; then
        exit 1
    fi

    # Get site configuration
    SITE_SSH_HOST=""
    SITE_SSH_KEY=""
    SITE_WEBROOT=""
    SITE_SERVER=""
    SITE_DIRECTORY=""
    SITE_TYPE=""

    if ! get_site_import_config "$OPT_SITE_NAME"; then
        print_error "Site not found or not an imported site: $OPT_SITE_NAME"
        print_info "Check nwp.yml for site configuration"
        exit 1
    fi

    # Verify it's an imported site
    if [ "$SITE_TYPE" != "import" ]; then
        print_warning "Site '$OPT_SITE_NAME' is not marked as imported (type: ${SITE_TYPE:-unknown})"
        if [ "$OPT_YES" != "y" ]; then
            if ! ask_yes_no "Continue anyway?" "n"; then
                exit 0
            fi
        fi
    fi

    # Verify local directory exists
    if [ ! -d "$SITE_DIRECTORY" ]; then
        print_error "Site directory not found: $SITE_DIRECTORY"
        exit 1
    fi

    # Confirm
    if [ "$OPT_YES" != "y" ]; then
        echo ""
        echo "This will sync $OPT_SITE_NAME from $SITE_SSH_HOST"
        if [ "$OPT_DB_ONLY" = "y" ]; then
            echo "Mode: Database only"
        elif [ "$OPT_FILES_ONLY" = "y" ]; then
            echo "Mode: Files only"
        else
            echo "Mode: Full sync (database + files)"
        fi
        if [ "$OPT_NO_SANITIZE" = "y" ]; then
            echo "Sanitization: Disabled"
        else
            echo "Sanitization: Enabled"
        fi
        echo ""

        if ! ask_yes_no "Continue?" "y"; then
            echo "Cancelled."
            exit 0
        fi
    fi

    do_sync
}

main "$@"
