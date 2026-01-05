#!/bin/bash
set -euo pipefail

################################################################################
# NWP Site Copy Script
#
# Copies one DDEV site to another (files + database or files-only)
# Based on pleasy copy.sh adapted for DDEV environments
#
# Usage: ./copy.sh [OPTIONS] <from_site> <to_site>
################################################################################

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Source shared libraries
source "$SCRIPT_DIR/lib/ui.sh"
source "$SCRIPT_DIR/lib/common.sh"

# Script start time
START_TIME=$(date +%s)

################################################################################
# Script-specific Functions
################################################################################

# Show help
show_help() {
    cat << EOF
${BOLD}NWP Site Copy Script${NC}

${BOLD}USAGE:${NC}
    ./copy.sh [OPTIONS] <from_site> <to_site>

${BOLD}OPTIONS:${NC}
    -h, --help              Show this help message
    -d, --debug             Enable debug output
    -f, --files-only        Copy files only (skip database operations)
    -y, --yes               Skip confirmation prompts
    -o, --open              Generate login link after copy (requires drush)

${BOLD}ARGUMENTS:${NC}
    from_site               Source site to copy from
    to_site                 Destination site name

${BOLD}EXAMPLES:${NC}
    ./copy.sh nwp4 nwp5                  # Full copy (files + database)
    ./copy.sh -f nwp4 nwp5               # Files-only copy
    ./copy.sh -y nwp4 nwp_backup         # Full copy with auto-confirm
    ./copy.sh -fy nwp4 nwp5              # Files-only with auto-confirm
    ./copy.sh -yo nwp4 nwp_test          # Full copy with auto-confirm + login link

${BOLD}COMBINED FLAGS:${NC}
    Multiple short flags can be combined: -fyo = -f -y -o
    Example: ./copy.sh -fyo nwp4 nwp5 is the same as ./copy.sh -f -y -o nwp4 nwp5

${BOLD}WORKFLOW (Full Copy):${NC}
    1. Validate source site exists
    2. Prepare destination directory
    3. Copy all files from source to destination
    4. Export source database
    5. Configure DDEV for destination
    6. Import database into destination
    7. Fix site settings
    8. Set permissions
    9. Clear cache
    10. Generate login link (with -o flag)

${BOLD}WORKFLOW (Files-Only with -f):${NC}
    1. Validate source site exists
    2. Validate destination exists (must already be configured)
    3. Copy all files from source to destination
    4. Fix site settings
    5. Set permissions

${BOLD}NOTE:${NC}
    Full copy creates a complete clone including database and DDEV configuration.
    Files-only copy (-f) updates files only, preserving the destination database.

    For files-only copy, the destination site must already exist with DDEV configured.

EOF
}

################################################################################
# Copy Functions
################################################################################

# Get webroot from DDEV config
get_webroot() {
    local sitename=$1
    local site_dir="sites/$sitename"
    local webroot=$(grep "^docroot:" "$site_dir/.ddev/config.yaml" 2>/dev/null | awk '{print $2}')
    if [ -z "$webroot" ]; then
        webroot="web"  # Default fallback
    fi
    echo "$webroot"
}

# Copy site files
copy_files() {
    local from_site=$1
    local to_site=$2
    local webroot=$3

    print_header "Step 3: Copy Files"

    local from_dir="sites/$from_site"
    local to_dir="sites/$to_site"

    # Paths to copy
    local copy_paths=()

    if [ -d "$from_dir/$webroot" ]; then
        copy_paths+=("$webroot")
    fi

    if [ -d "$from_dir/private" ]; then
        copy_paths+=("private")
    fi

    if [ -d "$from_dir/cmi" ]; then
        copy_paths+=("cmi")
    fi

    if [ -f "$from_dir/composer.json" ]; then
        copy_paths+=("composer.json")
        if [ -f "$from_dir/composer.lock" ]; then
            copy_paths+=("composer.lock")
        fi
    fi

    if [ ${#copy_paths[@]} -eq 0 ]; then
        print_error "No files found to copy"
        return 1
    fi

    ocmsg "Copying: ${copy_paths[*]}"

    # Copy each path
    for path in "${copy_paths[@]}"; do
        ocmsg "Copying $path..."
        if [ -d "$from_dir/$path" ]; then
            # Copy directory
            cp -r "$from_dir/$path" "$to_dir/" || {
                print_error "Failed to copy $path"
                return 1
            }
        elif [ -f "$from_dir/$path" ]; then
            # Copy file
            cp "$from_dir/$path" "$to_dir/" || {
                print_error "Failed to copy $path"
                return 1
            }
        fi
    done

    print_status "OK" "Files copied successfully"
    return 0
}

# Export database from source
export_database() {
    local from_site=$1

    print_header "Step 4: Export Database" >&2

    local from_dir="sites/$from_site"
    local original_dir=$(pwd)
    cd "$from_dir" || {
        print_error "Cannot access source site: $from_dir" >&2
        return 1
    }

    # Create temporary database export
    local temp_db=".ddev/copy_temp.sql"
    ocmsg "Exporting database from $from_site..." >&2

    if ddev export-db --file="$temp_db" --gzip=false > /dev/null 2>&1; then
        if [ -f "$temp_db" ]; then
            # Get absolute path before changing directories
            local abs_temp=$(pwd)/$temp_db
            print_status "OK" "Database exported" >&2
            # Return to original directory but leave temp file in place
            cd "$original_dir"
            echo "$abs_temp"
            return 0
        else
            print_error "Database export file not found" >&2
            cd "$original_dir"
            return 1
        fi
    else
        print_error "Failed to export database" >&2
        cd "$original_dir"
        return 1
    fi
}

# Configure DDEV for destination
configure_ddev() {
    local to_site=$1
    local webroot=$2

    print_header "Step 5: Configure DDEV"

    local to_dir="sites/$to_site"
    local original_dir=$(pwd)
    cd "$to_dir" || {
        print_error "Cannot access destination site: $to_dir"
        return 1
    }

    # Get project name (convert underscores to hyphens for valid hostname)
    local project_name=$(basename "$to_site" | tr '_' '-')

    ocmsg "Configuring DDEV with project name: $project_name"

    # Configure DDEV
    if ddev config --project-name="$project_name" --project-type=drupal --docroot="$webroot" --php-version="8.2" --database="mariadb:10.11" > /dev/null 2>&1; then
        print_status "OK" "DDEV configured"
    else
        print_error "Failed to configure DDEV"
        cd "$original_dir"
        return 1
    fi

    # Start DDEV
    ocmsg "Starting DDEV..."
    if ddev start > /dev/null 2>&1; then
        print_status "OK" "DDEV started"
    else
        print_error "Failed to start DDEV"
        cd "$original_dir"
        return 1
    fi

    cd "$original_dir"
    return 0
}

# Import database to destination
import_database() {
    local to_site=$1
    local db_export=$2

    print_header "Step 6: Import Database"

    if [ ! -f "$db_export" ]; then
        print_error "Database export not found: $db_export"
        return 1
    fi

    local to_dir="sites/$to_site"
    local original_dir=$(pwd)
    cd "$to_dir" || {
        print_error "Cannot access destination site: $to_dir"
        return 1
    }

    # Get absolute path to database export
    local abs_db_export=$(cd "$(dirname "$db_export")" && pwd)/$(basename "$db_export")

    # Ensure .ddev directory exists
    mkdir -p .ddev

    # Copy database to .ddev for import
    local temp_import=".ddev/import.sql"
    cp "$abs_db_export" "$temp_import"

    ocmsg "Importing database to $to_site..."

    # Import database
    if ddev import-db --file="$temp_import" > /dev/null 2>&1; then
        rm -f "$temp_import"
        print_status "OK" "Database imported"
        cd "$original_dir"
        return 0
    else
        rm -f "$temp_import"
        print_error "Failed to import database"
        cd "$original_dir"
        return 1
    fi
}

# Fix site settings
fix_settings() {
    local to_site=$1
    local webroot=$2

    print_header "Step 8: Fix Site Settings"

    local to_dir="sites/$to_site"
    local settings_file="$to_dir/$webroot/sites/default/settings.php"

    if [ -f "$settings_file" ]; then
        # DDEV manages settings, so we just verify they exist
        print_status "OK" "Settings verified (DDEV managed)"
    else
        print_status "WARN" "Settings file not found (will be managed by DDEV)"
    fi

    return 0
}

# Set permissions
set_permissions() {
    local to_site=$1
    local webroot=$2

    print_header "Step 9: Set Permissions"

    local to_dir="sites/$to_site"

    # Set sites/default writable
    if [ -d "$to_dir/$webroot/sites/default" ]; then
        chmod u+w "$to_dir/$webroot/sites/default"
        ocmsg "Set sites/default writable"
    fi

    # Set settings.php writable
    if [ -f "$to_dir/$webroot/sites/default/settings.php" ]; then
        chmod u+w "$to_dir/$webroot/sites/default/settings.php"
        ocmsg "Set settings.php writable"
    fi

    print_status "OK" "Permissions set"
    return 0
}

# Install dependencies
install_dependencies() {
    local to_site=$1

    print_header "Step 6: Install Dependencies"

    local to_dir="sites/$to_site"
    local original_dir=$(pwd)
    cd "$to_dir" || return 1

    ocmsg "Running composer install to rebuild vendor directory..."
    if ddev composer install --no-interaction > /dev/null 2>&1; then
        print_status "OK" "Dependencies installed"
    else
        print_status "WARN" "Could not install dependencies (may need manual intervention)"
    fi

    cd "$original_dir"
}

# Clear cache
clear_cache() {
    local to_site=$1

    print_header "Step 10: Clear Cache"

    local to_dir="sites/$to_site"
    local original_dir=$(pwd)
    cd "$to_dir" || return 1

    # Try to clear cache and capture error
    local error_msg=$(ddev drush cr 2>&1)
    local exit_code=$?

    if [ $exit_code -eq 0 ]; then
        print_status "OK" "Cache cleared"
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
}

# Generate login link
generate_login_link() {
    local to_site=$1

    print_header "Step 11: Generate Login Link"

    local to_dir="sites/$to_site"
    local original_dir=$(pwd)
    cd "$to_dir" || return 1

    local login_url=$(ddev drush uli 2>&1)

    if [ $? -eq 0 ]; then
        print_status "OK" "Login link generated"
        echo ""
        echo -e "${GREEN}${BOLD}Login URL:${NC} $login_url"
        echo ""
    else
        print_status "WARN" "Could not generate login link"
        echo -e "${YELLOW}${BOLD}Login URL:${NC} $login_url"
        echo ""
    fi

    cd "$original_dir"
}

################################################################################
# Main Copy Function
################################################################################

copy_site() {
    local from_site=$1
    local to_site=$2
    local auto_yes=$3
    local open_after=$4
    local files_only=${5:-false}

    if [ "$files_only" == "true" ]; then
        print_header "NWP Files-Only Copy: $from_site → $to_site"
    else
        print_header "NWP Site Copy: $from_site → $to_site"
    fi

    # Step 1: Validate source
    print_header "Step 1: Validate Source"

    local from_dir="sites/$from_site"

    if [ ! -d "$from_dir" ]; then
        print_error "Source site not found: $from_dir"
        return 1
    fi

    if [ ! -f "$from_dir/.ddev/config.yaml" ]; then
        print_error "Source site is not a DDEV site: $from_dir"
        return 1
    fi

    local webroot=$(get_webroot "$from_site")
    ocmsg "Source webroot: $webroot"
    print_status "OK" "Source site validated: $from_dir"

    # Step 2: Prepare destination
    print_header "Step 2: Prepare Destination"

    local to_dir="sites/$to_site"

    if [ "$files_only" == "true" ]; then
        # Files-only mode: destination must already exist
        if [ ! -d "$to_dir" ]; then
            print_error "Destination site not found: $to_dir"
            print_info "For files-only copy, destination must already exist"
            return 1
        fi

        if [ ! -f "$to_dir/.ddev/config.yaml" ]; then
            print_error "Destination is not a DDEV site: $to_dir"
            print_info "Run 'ddev config' in the destination directory first"
            return 1
        fi

        if [ "$auto_yes" != "true" ]; then
            print_status "WARN" "This will overwrite files in: $to_dir"
            echo -n "Continue with files-only copy? [y/N]: "
            read confirm
            if [[ ! "$confirm" =~ ^[Yy] ]]; then
                print_info "Copy cancelled"
                return 1
            fi
        else
            print_status "WARN" "Overwriting files in: $to_dir"
            echo "Auto-confirmed: Files-only copy"
        fi

        print_status "OK" "Destination validated: $to_dir"
    else
        # Full copy mode: delete and recreate destination
        if [ -d "$to_dir" ]; then
            if [ "$auto_yes" != "true" ]; then
                print_status "WARN" "Destination site already exists: $to_dir"
                echo -n "Delete existing site and create fresh copy? [y/N]: "
                read confirm
                if [[ ! "$confirm" =~ ^[Yy] ]]; then
                    print_info "Copy cancelled"
                    return 1
                fi
            else
                print_status "WARN" "Destination site already exists: $to_dir"
                echo "Auto-confirmed: Delete and recreate"
            fi

            # Validate before destructive operation
            if ! validate_sitename "$to_site" "destination site"; then
                return 1
            fi

            # Stop DDEV if running
            ocmsg "Stopping DDEV for $to_site"
            (cd "$to_dir" && ddev stop > /dev/null 2>&1) || true

            # Remove existing site
            ocmsg "Removing existing site: $to_dir"
            rm -rf "$to_dir"
            print_status "OK" "Existing site removed"
        fi

        # Create destination directory
        mkdir -p "$to_dir"
        print_status "OK" "Destination prepared: $to_dir"
    fi

    # Step 3: Copy files
    if ! copy_files "$from_site" "$to_site" "$webroot"; then
        print_error "File copy failed"
        return 1
    fi

    # Remove .ddev if it was copied (we'll recreate it for full copy)
    local to_dir="sites/$to_site"
    if [ "$files_only" != "true" ] && [ -d "$to_dir/.ddev" ]; then
        ocmsg "Removing copied .ddev directory"
        rm -rf "$to_dir/.ddev"
    fi

    # Skip database operations for files-only mode
    if [ "$files_only" != "true" ]; then
        # Step 4: Export database
        local db_export=$(export_database "$from_site")
        if [ $? -ne 0 ] || [ -z "$db_export" ]; then
            print_error "Database export failed"
            return 1
        fi

        # Step 5: Configure DDEV
        if ! configure_ddev "$to_site" "$webroot"; then
            print_error "DDEV configuration failed"
            return 1
        fi

        # Step 6: Install dependencies
        install_dependencies "$to_site"

        # Step 7: Import database
        if ! import_database "$to_site" "$db_export"; then
            print_error "Database import failed"
            return 1
        fi

        # Clean up temporary database export
        rm -f "$db_export"
    fi

    # Step 8: Fix settings
    fix_settings "$to_site" "$webroot"

    # Step 9: Set permissions
    set_permissions "$to_site" "$webroot"

    # Step 10: Clear cache
    clear_cache "$to_site"

    # Step 11: Generate login link (if requested)
    if [ "$open_after" == "true" ]; then
        generate_login_link "$to_site"
    fi

    # Summary
    print_header "Copy Summary"
    echo -e "${GREEN}✓${NC} Source: $from_site"
    echo -e "${GREEN}✓${NC} Destination: $to_site"

    # Get site URL
    local to_dir="sites/$to_site"
    local site_url=$(cd "$to_dir" && ddev describe 2>/dev/null | grep -oP 'https://[^ ,]+' | head -1)
    if [ -n "$site_url" ]; then
        echo ""
        echo -e "${BOLD}Site URL:${NC} $site_url"
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
    local OPEN_AFTER=false
    local FILES_ONLY=false
    local FROM_SITE=""
    local TO_SITE=""

    # Use getopt for option parsing
    local OPTIONS=hdfyo
    local LONGOPTS=help,debug,files-only,yes,open

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
            -f|--files-only)
                FILES_ONLY=true
                shift
                ;;
            -y|--yes)
                AUTO_YES=true
                shift
                ;;
            -o|--open)
                OPEN_AFTER=true
                shift
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

    # Get from_site and to_site from remaining arguments
    if [ $# -lt 2 ]; then
        print_error "Missing required arguments"
        echo ""
        show_help
        exit 1
    fi

    FROM_SITE="$1"
    TO_SITE="$2"

    ocmsg "From: $FROM_SITE"
    ocmsg "To: $TO_SITE"
    ocmsg "Auto yes: $AUTO_YES"
    ocmsg "Open after: $OPEN_AFTER"
    ocmsg "Files only: $FILES_ONLY"

    # Run copy
    if copy_site "$FROM_SITE" "$TO_SITE" "$AUTO_YES" "$OPEN_AFTER" "$FILES_ONLY"; then
        show_elapsed_time "Copy"
        exit 0
    else
        print_error "Site copy failed: $FROM_SITE → $TO_SITE"
        exit 1
    fi
}

# Run main
main "$@"
