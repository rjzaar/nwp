#!/bin/bash
set -euo pipefail

################################################################################
# NWP Delete Script
#
# Gracefully deletes DDEV sites (Drupal, Moodle, or any type)
# Stops containers, removes DDEV project, and cleans up directories
#
# Usage: ./delete.sh [OPTIONS] <sitename>
################################################################################

# Get script directory and project root
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
# Script-specific Functions
################################################################################

# Show help
show_help() {
    cat << EOF
${BOLD}NWP Delete Script${NC}

${BOLD}USAGE:${NC}
    ./delete.sh [OPTIONS] <sitename>

${BOLD}OPTIONS:${NC}
    -h, --help              Show this help message
    -d, --debug             Enable debug output
    -y, --yes               Skip all confirmation prompts
    -b, --backup            Create backup before deletion
    -k, --keep-backups      Keep existing backups (default: ask)
    -f, --force             Force deletion (bypass name validation for cleanup)
    --keep-yml              Keep site entry in nwp.yml (default: remove)

${BOLD}ARGUMENTS:${NC}
    sitename                Name of the DDEV site to delete

${BOLD}EXAMPLES:${NC}
    ./delete.sh os                      # Delete 'os' site (with confirmation)
    ./delete.sh -y nwp5                 # Delete with auto-confirm
    ./delete.sh -b nwp4                 # Backup before deletion
    ./delete.sh -by nwp_test            # Backup + auto-confirm deletion
    ./delete.sh -bky old_site           # Backup + keep backups + auto-confirm

${BOLD}COMBINED FLAGS:${NC}
    Multiple short flags can be combined: -bky = -b -k -y
    Example: ./delete.sh -bky site is the same as ./delete.sh -b -k -y site

${BOLD}DELETION PROCESS:${NC}
    1. Validate site exists
    2. Create backup (if -b flag used)
    3. Stop DDEV containers
    4. Delete DDEV project
    5. Remove site directory
    6. Handle backups (delete or keep based on -k flag)
    7. Display summary

${BOLD}BACKUP BEHAVIOR:${NC}
    - Without -y: Asks to delete existing backups (default: No)
    - With -y: Keeps existing backups (safer default for auto-confirm)
    - With -k: Always keeps backups regardless of -y flag
    - With -by: Creates backup then keeps it (recommended safe delete)

${BOLD}SITE TYPES SUPPORTED:${NC}
    - Drupal (all versions)
    - Moodle
    - OpenSocial
    - Any DDEV-managed site

${BOLD}NOTE:${NC}
    This operation cannot be undone unless you create a backup first (-b flag).
    When using auto-confirm (-y), backups are preserved by default for safety.
    Use with caution!

EOF
}

################################################################################
# Validation Functions
################################################################################

# Check if site directory exists
site_exists() {
    local sitename=$1
    local site_dir="sites/$sitename"
    if [ ! -d "$site_dir" ]; then
        return 1
    fi
    return 0
}

# Check if DDEV is running for this site
ddev_is_running() {
    local sitename=$1
    local site_dir="sites/$sitename"
    if cd "$site_dir" 2>/dev/null; then
        if ddev status 2>/dev/null | grep -q "OK"; then
            cd - > /dev/null
            return 0
        fi
        cd - > /dev/null
    fi
    return 1
}

################################################################################
# Main Deletion Functions
################################################################################

# Step 1: Validate site
validate_site() {
    local sitename=$1

    print_header "Step 1: Validate Site"

    if ! site_exists "$sitename"; then
        print_error "Site not found: $sitename"
        print_info "Use 'ddev list' to see available sites"
        return 1
    fi

    print_status "OK" "Site exists: $sitename"

    # Show site information
    local site_dir="sites/$sitename"
    if cd "$site_dir" 2>/dev/null; then
        if ddev describe 2>/dev/null | grep -q "Name:"; then
            local site_url=$(ddev describe 2>/dev/null | grep "Primary URL:" | awk '{print $3}')
            local site_type=$(ddev describe 2>/dev/null | grep "Type:" | awk '{print $2}')

            if [ -n "$site_type" ]; then
                print_status "INFO" "Type: $site_type"
            fi
            if [ -n "$site_url" ]; then
                print_status "INFO" "URL: $site_url"
            fi
        fi
        cd - > /dev/null
    fi

    return 0
}

# Step 2: Create backup (optional)
create_backup() {
    local sitename=$1

    print_header "Step 2: Create Backup"

    if [ -f "$SCRIPT_DIR/backup.sh" ]; then
        ocmsg "Running backup script..."
        if "$SCRIPT_DIR/backup.sh" "$sitename" "Pre-deletion backup"; then
            print_status "OK" "Backup created successfully"
            return 0
        else
            print_error "Backup failed"
            return 1
        fi
    else
        print_error "backup.sh script not found"
        print_info "Cannot create backup - proceeding without it"
        return 1
    fi
}

# Step 3: Stop DDEV
stop_ddev() {
    local sitename=$1

    print_header "Step 3: Stop DDEV"

    local site_dir="sites/$sitename"
    local original_dir=$(pwd)
    cd "$site_dir" || {
        print_error "Cannot access site directory: $site_dir"
        return 1
    }

    if ddev_is_running "$sitename"; then
        ocmsg "Stopping DDEV containers..."
        if ddev stop > /dev/null 2>&1; then
            print_status "OK" "DDEV stopped"
        else
            print_warning "Could not stop DDEV (may already be stopped)"
        fi
    else
        print_status "INFO" "DDEV not running"
    fi

    cd "$original_dir"
    return 0
}

# Step 4: Delete DDEV project
delete_ddev_project() {
    local sitename=$1

    print_header "Step 4: Delete DDEV Project"

    local site_dir="sites/$sitename"
    local original_dir=$(pwd)
    cd "$site_dir" || {
        print_error "Cannot access site directory: $site_dir"
        return 1
    }

    ocmsg "Deleting DDEV project..."
    if ddev delete -Oy > /dev/null 2>&1; then
        print_status "OK" "DDEV project deleted"
    else
        print_warning "Could not delete DDEV project (may not be configured)"
    fi

    cd "$original_dir"
    return 0
}

# Step 5: Remove site directory
remove_site_directory() {
    local sitename=$1
    local force="${2:-false}"

    print_header "Step 5: Remove Site Directory"

    # Validate site name before destructive operation (skip if force mode)
    if [[ "$force" != "true" ]]; then
        if ! validate_sitename "$sitename" "site directory"; then
            print_info "Tip: Use --force flag to delete sites with invalid names"
            print_info "Example: pl delete --force -- $sitename"
            return 1
        fi
    else
        print_warning "Force mode: skipping name validation for cleanup"
    fi

    local site_dir="sites/$sitename"
    ocmsg "Removing directory: $site_dir"

    # Get directory size for reporting
    local dir_size=$(du -sh "$site_dir" 2>/dev/null | awk '{print $1}')

    if rm -rf "$site_dir" 2>/dev/null; then
        print_status "OK" "Directory removed: $site_dir (${dir_size:-unknown size})"
        return 0
    else
        print_error "Failed to remove directory: $site_dir"
        print_info "You may need to manually remove it with: sudo rm -rf $site_dir"
        return 1
    fi
}

# Step 6: Handle backups
handle_backups() {
    local sitename=$1
    local keep_backups=$2

    print_header "Step 6: Handle Backups"

    local backup_dir="sitebackups/$sitename"

    if [ ! -d "$backup_dir" ]; then
        print_status "INFO" "No backups found for $sitename"
        return 0
    fi

    # Get backup directory size
    local backup_size=$(du -sh "$backup_dir" 2>/dev/null | awk '{print $1}')
    local backup_count=$(find "$backup_dir" -maxdepth 1 -name "*.tar.gz" 2>/dev/null | wc -l)

    print_status "INFO" "Found $backup_count backup(s) in $backup_dir (${backup_size})"

    if [ "$keep_backups" == "true" ]; then
        print_status "OK" "Keeping backups (--keep-backups flag)"
        return 0
    fi

    # Ask user if they want to delete backups
    if [ "$AUTO_CONFIRM" != "true" ]; then
        echo ""
        read -p "Delete backups for $sitename? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_status "OK" "Keeping backups"
            return 0
        fi
    else
        # When auto-confirm is enabled, keep backups by default
        # User must explicitly use -k to delete them with -y
        print_status "INFO" "Keeping backups (auto-confirm mode)"
        return 0
    fi

    ocmsg "Removing backup directory: $backup_dir"
    if rm -rf "$backup_dir" 2>/dev/null; then
        print_status "OK" "Backups removed: ${backup_size}"
    else
        print_warning "Could not remove backups directory"
    fi

    return 0
}

# Step 7: Remove from nwp.yml
remove_from_cnwp() {
    local sitename=$1
    local keep_yml=$2

    print_header "Step 7: Remove from nwp.yml"

    # Check if YAML library is available
    if ! command -v yaml_remove_site &> /dev/null; then
        print_status "INFO" "YAML library not available, skipping nwp.yml cleanup"
        return 0
    fi

    # Read default setting from nwp.yml
    local delete_site_yml=$(awk '
        /^settings:/ { in_settings = 1; next }
        in_settings && /^[a-zA-Z]/ && !/^  / { in_settings = 0 }
        in_settings && /^  delete_site_yml:/ {
            sub("^  delete_site_yml: *", "")
            sub(" *#.*$", "")  # Strip trailing comments
            print
            exit
        }
    ' "$PROJECT_ROOT/nwp.yml")

    # Default to true if not set
    delete_site_yml=${delete_site_yml:-true}

    ocmsg "delete_site_yml setting: $delete_site_yml"
    ocmsg "keep_yml flag: $keep_yml"

    # If --keep-yml flag is set, skip removal
    if [ "$keep_yml" == "true" ]; then
        print_status "INFO" "Keeping site entry in nwp.yml (--keep-yml flag)"
        return 0
    fi

    # If delete_site_yml is false, skip removal
    if [ "$delete_site_yml" == "false" ]; then
        print_status "INFO" "Keeping site entry in nwp.yml (delete_site_yml: false in settings)"
        return 0
    fi

    # Check if site exists in nwp.yml
    if ! yaml_site_exists "$sitename" "$PROJECT_ROOT/nwp.yml"; then
        print_status "INFO" "Site not found in nwp.yml"
        return 0
    fi

    ocmsg "Removing site '$sitename' from nwp.yml"

    # FIX 3: Remove error suppression - show errors to user
    # Remove the site (errors are now visible and informative)
    if yaml_remove_site "$sitename" "$PROJECT_ROOT/nwp.yml"; then
        print_status "OK" "Site removed from nwp.yml"
    else
        print_error "Failed to remove site from nwp.yml"
        return 1
    fi

    return 0
}

################################################################################
# Main Script
################################################################################

# Default values
DEBUG=false
AUTO_CONFIRM=false
CREATE_BACKUP=false
KEEP_BACKUPS=false
KEEP_YML=false
FORCE_DELETE=false

# Parse command-line options
TEMP=$(getopt -o hdbykf --long help,debug,backup,yes,keep-backups,keep-yml,force -n 'delete.sh' -- "$@")

if [ $? != 0 ]; then
    echo "Error parsing options. Use --help for usage information." >&2
    exit 1
fi

eval set -- "$TEMP"

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
        -b|--backup)
            CREATE_BACKUP=true
            shift
            ;;
        -y|--yes)
            AUTO_CONFIRM=true
            shift
            ;;
        -k|--keep-backups)
            KEEP_BACKUPS=true
            shift
            ;;
        --keep-yml)
            KEEP_YML=true
            shift
            ;;
        -f|--force)
            FORCE_DELETE=true
            shift
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "Internal error!"
            exit 1
            ;;
    esac
done

# Check for required argument
if [ $# -lt 1 ]; then
    print_error "Missing required argument: sitename"
    echo ""
    echo "Usage: ./delete.sh [OPTIONS] <sitename>"
    echo "Use --help for more information"
    exit 1
fi

SITENAME=$1

# Show header
print_header "NWP Site Deletion: $SITENAME"

# Validate site exists (in force mode, just check directory exists)
if [[ "$FORCE_DELETE" == "true" ]]; then
    if [ ! -d "sites/$SITENAME" ]; then
        print_error "Site directory not found: sites/$SITENAME"
        exit 1
    fi
    print_warning "Force mode: skipping normal validation"
elif ! validate_site "$SITENAME"; then
    exit 1
fi

# Check site purpose before deletion
SITE_PURPOSE=""
if [ -f "$PROJECT_ROOT/lib/yaml-write.sh" ] && command -v yaml_get_site_purpose &> /dev/null; then
    SITE_PURPOSE=$(yaml_get_site_purpose "$SITENAME" "$PROJECT_ROOT/nwp.yml" 2>/dev/null)
fi

# Handle purpose-based deletion restrictions
case "$SITE_PURPOSE" in
    permanent)
        print_error "Site '$SITENAME' has purpose 'permanent' and cannot be deleted"
        echo ""
        print_info "To delete this site, first change its purpose in nwp.yml:"
        echo "  1. Edit nwp.yml"
        echo "  2. Find the site entry for '$SITENAME'"
        echo "  3. Change 'purpose: permanent' to 'purpose: indefinite' or 'purpose: testing'"
        echo "  4. Run delete.sh again"
        exit 1
        ;;
    migration)
        print_warning "Site '$SITENAME' is a migration site (may contain work in progress)"
        ;;
    testing)
        print_info "Site '$SITENAME' is a testing site (safe to delete)"
        ;;
    indefinite|"")
        # Default - allow deletion with normal confirmation
        ;;
esac

# Confirmation prompt
if [ "$AUTO_CONFIRM" != "true" ]; then
    echo ""
    print_warning "This will permanently delete the site: $SITENAME"
    if [ "$CREATE_BACKUP" != "true" ]; then
        print_warning "No backup will be created (use -b flag to create backup)"
    fi
    echo ""
    read -p "Are you sure you want to continue? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Deletion cancelled"
        exit 0
    fi
fi

# Create backup if requested
if [ "$CREATE_BACKUP" == "true" ]; then
    if ! create_backup "$SITENAME"; then
        if [ "$AUTO_CONFIRM" != "true" ]; then
            echo ""
            read -p "Backup failed. Continue with deletion anyway? (y/N) " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                print_info "Deletion cancelled"
                exit 1
            fi
        else
            print_warning "Backup failed but continuing (auto-confirm enabled)"
        fi
    fi
else
    print_status "INFO" "Skipping backup (use -b flag to create backup)"
fi

# Stop DDEV
if ! stop_ddev "$SITENAME"; then
    print_warning "Failed to stop DDEV, continuing..."
fi

# Delete DDEV project
if ! delete_ddev_project "$SITENAME"; then
    print_warning "Failed to delete DDEV project, continuing..."
fi

# Remove site directory
if ! remove_site_directory "$SITENAME" "$FORCE_DELETE"; then
    print_error "Failed to remove site directory: $SITENAME"
    exit 1
fi

# Handle backups
handle_backups "$SITENAME" "$KEEP_BACKUPS"

# Remove from nwp.yml
remove_from_cnwp "$SITENAME" "$KEEP_YML"

# Show summary
print_header "Deletion Summary"

print_status "OK" "Site deleted: $SITENAME"

if [ "$CREATE_BACKUP" == "true" ]; then
    print_status "INFO" "Backup created before deletion"
fi

if [ -d "sitebackups/$SITENAME" ]; then
    print_status "INFO" "Backups preserved in: sitebackups/$SITENAME"
fi

# Show elapsed time
show_elapsed_time "Site deletion"

echo ""
exit 0
