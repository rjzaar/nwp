#!/bin/bash

################################################################################
# NWP Restore Script
#
# Restores DDEV sites from backups created by backup.sh
# Based on pleasy restore.sh adapted for DDEV environments
#
# Usage: ./restore.sh [FROM] [TO] [OPTIONS]
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

ocmsg() {
    local message=$1
    if [ "$DEBUG" == "true" ]; then
        echo -e "${CYAN}[DEBUG]${NC} $message"
    fi
}

show_elapsed_time() {
    local end_time=$(date +%s)
    local elapsed=$((end_time - START_TIME))
    local hours=$((elapsed / 3600))
    local minutes=$(((elapsed % 3600) / 60))
    local seconds=$((elapsed % 60))

    echo ""
    print_status "OK" "Restore completed in $(printf "%02d:%02d:%02d" $hours $minutes $seconds)"
}

ask_yes_no() {
    local prompt=$1
    local default=${2:-n}

    if [ "$AUTO_YES" == "true" ]; then
        echo "Auto-confirmed: $prompt"
        return 0
    fi

    if [ "$default" == "y" ]; then
        prompt="$prompt [Y/n]: "
    else
        prompt="$prompt [y/N]: "
    fi

    read -p "$prompt" response
    response=${response:-$default}

    if [[ "$response" =~ ^[Yy]$ ]]; then
        return 0
    else
        return 1
    fi
}

should_run_step() {
    local step_num=$1
    local start_step=${2:-1}

    if [ "$step_num" -ge "$start_step" ]; then
        return 0
    else
        return 1
    fi
}

show_help() {
    cat << EOF
${BOLD}NWP Restore Script${NC}

${BOLD}USAGE:${NC}
    ./restore.sh [OPTIONS] <from> [to]

${BOLD}OPTIONS:${NC}
    -h, --help              Show this help message
    -d, --debug             Enable debug output
    -b, --db-only           Database-only restore (skip files)
    -s, --step=N            Resume from step N
    -f, --first             Use latest backup without prompting
    -y, --yes               Auto-confirm deletion of existing content
    -o, --open              Generate login link after restoration

${BOLD}ARGUMENTS:${NC}
    from                    Source site name (backup to restore from)
    to                      Destination site name (optional, defaults to 'from')

${BOLD}EXAMPLES:${NC}
    ./restore.sh nwp                         # Restore nwp from latest backup (full)
    ./restore.sh -b nwp                      # Database-only restore
    ./restore.sh nwp nwp2                    # Restore nwp backup to nwp2 site
    ./restore.sh -b nwp nwp2                 # Database-only restore to different site
    ./restore.sh -fy nwp                     # Auto-select latest + auto-confirm
    ./restore.sh -bfyo nwp                   # DB-only + auto-select + confirm + open
    ./restore.sh -s=5 nwp                    # Resume from step 5

${BOLD}RESTORATION STEPS:${NC}
    Full restore:
      1. Select backup
      2. Validate destination
      3. Extract files
      4. Fix settings
      5. Set permissions
      6. Restore database
      7. Clear cache
      8. Generate login link (if -o)

    Database-only restore (-b):
      1. Select backup
      2. Confirm restoration
      3. Restore database
      4. Clear cache
      5. Generate login link (if -o)

${BOLD}BACKUP LOCATION:${NC}
    Backups are read from: sitebackups/<sitename>/

EOF
}

################################################################################
# Backup Selection Functions
################################################################################

list_backups() {
    local sitename=$1
    local backup_dir="sitebackups/$sitename"

    if [ ! -d "$backup_dir" ]; then
        return 1
    fi

    # List SQL files (sorted by date, newest first)
    find "$backup_dir" -name "*.sql" -type f | sort -r
}

select_backup() {
    local sitename=$1
    local use_first=${2:-false}

    local backup_dir="sitebackups/$sitename"

    if [ ! -d "$backup_dir" ]; then
        print_error "No backups found for site: $sitename"
        print_info "Backup directory does not exist: $backup_dir"
        return 1
    fi

    # Get list of backups
    local backups=($(list_backups "$sitename"))

    if [ ${#backups[@]} -eq 0 ]; then
        print_error "No backups found in: $backup_dir"
        return 1
    fi

    # If --first flag, use latest backup
    if [ "$use_first" == "true" ]; then
        echo "${backups[0]}"
        return 0
    fi

    # Interactive selection
    print_header "Available Backups for $sitename"

    echo -e "${BOLD}Found ${#backups[@]} backup(s):${NC}\n"

    local i=1
    for backup in "${backups[@]}"; do
        local basename=$(basename "$backup" .sql)
        local size_sql=$(du -h "$backup" 2>/dev/null | cut -f1)
        local tar_file="${backup%.sql}.tar.gz"
        local size_tar="N/A"
        if [ -f "$tar_file" ]; then
            size_tar=$(du -h "$tar_file" 2>/dev/null | cut -f1)
        fi

        echo -e "${BLUE}$i)${NC} $basename"
        echo -e "   DB: $size_sql | Files: $size_tar"
        echo ""
        ((i++))
    done

    echo -n "Select backup number [1]: "
    read selection
    selection=${selection:-1}

    if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt ${#backups[@]} ]; then
        print_error "Invalid selection"
        return 1
    fi

    local selected_backup="${backups[$((selection-1))]}"
    echo "$selected_backup"
    return 0
}

################################################################################
# Restore Functions
################################################################################

restore_files() {
    local backup_file=$1
    local dest_site=$2
    local webroot=$3

    print_header "Step 3: Restore Files"

    local tar_file="${backup_file%.sql}.tar.gz"

    if [ ! -f "$tar_file" ]; then
        print_error "Files backup not found: $tar_file"
        return 1
    fi

    ocmsg "Extracting files from: $tar_file"
    ocmsg "Destination: $dest_site"

    # Extract tar.gz to destination
    if tar -xzf "$tar_file" -C "$dest_site" 2>/dev/null; then
        print_status "OK" "Files extracted successfully"
        return 0
    else
        print_error "Failed to extract files"
        return 1
    fi
}

restore_database() {
    local backup_file=$1
    local dest_site=$2

    print_header "Step 7: Restore Database"

    if [ ! -f "$backup_file" ]; then
        print_error "Database backup not found: $backup_file"
        return 1
    fi

    ocmsg "Importing database from: $backup_file"

    # Get absolute path to backup file
    local abs_backup=$(cd "$(dirname "$backup_file")" && pwd)/$(basename "$backup_file")

    # Change to destination site directory
    local original_dir=$(pwd)
    cd "$dest_site" || {
        print_error "Cannot access site directory: $dest_site"
        return 1
    }

    # Ensure .ddev directory exists
    mkdir -p .ddev

    # Copy backup to .ddev directory for import
    local temp_db=".ddev/import.sql"
    cp "$abs_backup" "$temp_db"

    # Import database using DDEV
    if ddev import-db --file="$temp_db" > /dev/null 2>&1; then
        rm -f "$temp_db"
        print_status "OK" "Database restored successfully"
        cd "$original_dir"
        return 0
    else
        rm -f "$temp_db"
        print_error "Failed to import database"
        cd "$original_dir"
        return 1
    fi
}

fix_site_settings() {
    local dest_site=$1
    local webroot=$2

    print_header "Step 5: Fix Site Settings"

    local settings_file="$dest_site/$webroot/sites/default/settings.php"

    if [ ! -f "$settings_file" ]; then
        print_status "WARN" "No settings.php found, DDEV will handle configuration"
        return 0
    fi

    ocmsg "Settings file: $settings_file"

    # DDEV handles database settings automatically, so we just ensure file exists
    print_status "OK" "Settings verified (DDEV managed)"

    return 0
}

set_permissions() {
    local dest_site=$1
    local webroot=$2

    print_header "Step 6: Set Permissions"

    # Ensure sites/default is writable
    if [ -d "$dest_site/$webroot/sites/default" ]; then
        chmod u+w "$dest_site/$webroot/sites/default"
        ocmsg "Set sites/default writable"
    fi

    # Ensure settings.php is writable
    if [ -f "$dest_site/$webroot/sites/default/settings.php" ]; then
        chmod u+w "$dest_site/$webroot/sites/default/settings.php"
        ocmsg "Set settings.php writable"
    fi

    print_status "OK" "Permissions set"

    return 0
}

install_dependencies() {
    local dest_site=$1

    print_header "Step 4: Install Dependencies"

    local original_dir=$(pwd)
    cd "$dest_site" || {
        print_error "Cannot access site directory: $dest_site"
        return 1
    }

    # Install composer dependencies to rebuild vendor/
    ocmsg "Running composer install to rebuild vendor directory..."
    if ddev composer install --no-interaction > /dev/null 2>&1; then
        print_status "OK" "Dependencies installed"
    else
        print_status "WARN" "Could not install dependencies (may need manual intervention)"
    fi

    cd "$original_dir"
    return 0
}

clear_cache() {
    local dest_site=$1

    print_header "Step 8: Clear Cache"

    local original_dir=$(pwd)
    cd "$dest_site" || {
        print_error "Cannot access site directory: $dest_site"
        return 1
    }

    # Clear Drupal cache using drush
    if ddev drush cr > /dev/null 2>&1; then
        print_status "OK" "Cache cleared"
    else
        print_status "WARN" "Could not clear cache (site may not be fully configured)"
    fi

    cd "$original_dir"
    return 0
}

generate_login_link() {
    local dest_site=$1

    print_header "Step 9: Generate Login Link"

    local original_dir=$(pwd)
    cd "$dest_site" || {
        print_error "Cannot access site directory: $dest_site"
        return 1
    }

    # Generate one-time login URL
    local login_url=$(ddev drush uli 2>/dev/null | tail -1)

    if [ -n "$login_url" ]; then
        print_status "OK" "Login link generated"
        echo -e "\n${GREEN}${BOLD}Login URL:${NC} $login_url\n"

        # Try to open in browser
        if command -v xdg-open &> /dev/null; then
            xdg-open "$login_url" &>/dev/null &
        elif command -v open &> /dev/null; then
            open "$login_url" &>/dev/null &
        fi
    else
        print_status "WARN" "Could not generate login link"
    fi

    cd "$original_dir"
    return 0
}

################################################################################
# Main Restore Function
################################################################################

restore_site() {
    local from_site=$1
    local to_site=$2
    local use_first=$3
    local start_step=${4:-1}
    local open_after=${5:-false}
    local db_only=${6:-false}

    if [ "$db_only" == "true" ]; then
        print_header "NWP Database Restore: $from_site → $to_site"
    else
        print_header "NWP Site Restore: $from_site → $to_site"
    fi

    # Step 1: Select backup
    if should_run_step 1 "$start_step"; then
        print_header "Step 1: Select Backup"

        local selected_backup=$(select_backup "$from_site" "$use_first")
        if [ $? -ne 0 ] || [ -z "$selected_backup" ]; then
            print_error "No backup selected"
            return 1
        fi

        BACKUP_FILE="$selected_backup"
        print_info "Selected backup: ${BOLD}$(basename "$BACKUP_FILE" .sql)${NC}"
    else
        print_status "INFO" "Skipping Step 1: Using existing backup selection"
    fi

    # Step 2: Validate destination
    if should_run_step 2 "$start_step"; then
        print_header "Step 2: Validate Destination"

        if [ "$db_only" == "true" ]; then
            # Database-only: destination must exist
            if [ ! -d "$to_site" ]; then
                print_error "Destination site not found: $to_site"
                print_info "Destination must already exist for database-only restore"
                return 1
            fi

            if [ ! -f "$to_site/.ddev/config.yaml" ]; then
                print_error "Destination is not a DDEV site: $to_site"
                print_info "Run 'ddev config' in the destination directory first"
                return 1
            fi

            if ! ask_yes_no "Replace database in $to_site with backup from $from_site?" "n"; then
                print_error "Restoration cancelled"
                return 1
            fi

            print_status "OK" "Destination validated: $to_site"
        else
            # Full restore: delete and recreate destination
            if [ -d "$to_site" ]; then
                print_status "WARN" "Destination site already exists: $to_site"

                if ! ask_yes_no "Delete existing site and restore from backup?" "n"; then
                    print_error "Restoration cancelled"
                    return 1
                fi

                # Stop DDEV if running
                ocmsg "Stopping DDEV for $to_site"
                cd "$to_site" && ddev stop > /dev/null 2>&1
                cd - > /dev/null

                # Remove existing site
                ocmsg "Removing existing site: $to_site"
                rm -rf "$to_site"
                print_status "OK" "Existing site removed"
            fi

            # Create destination directory
            mkdir -p "$to_site"
            print_status "OK" "Destination prepared: $to_site"
        fi
    else
        print_status "INFO" "Skipping Step 2: Destination already prepared"
    fi

    # Get webroot (skip for database-only)
    local webroot="html"
    if [ "$db_only" != "true" ]; then
        # Try to detect from backup archive
        local tar_file="${BACKUP_FILE%.sql}.tar.gz"
        if [ -f "$tar_file" ]; then
            if tar -tzf "$tar_file" | grep -q "^web/" 2>/dev/null; then
                webroot="web"
            fi
        fi
        ocmsg "Using webroot: $webroot"
    fi

    # Step 3: Restore files (skip for database-only)
    if [ "$db_only" != "true" ]; then
        if should_run_step 3 "$start_step"; then
            if ! restore_files "$BACKUP_FILE" "$to_site" "$webroot"; then
                print_error "File restoration failed"
                return 1
            fi
        else
            print_status "INFO" "Skipping Step 3: Files already restored"
        fi
    fi

    # Step 4: Install dependencies (skip for database-only)
    if [ "$db_only" != "true" ]; then
        if should_run_step 4 "$start_step"; then
            install_dependencies "$to_site"
        else
            print_status "INFO" "Skipping Step 4: Dependencies already installed"
        fi
    fi

    # Step 5: Fix settings (skip for database-only)
    if [ "$db_only" != "true" ]; then
        if should_run_step 5 "$start_step"; then
            fix_site_settings "$to_site" "$webroot"
        else
            print_status "INFO" "Skipping Step 5: Settings already fixed"
        fi
    fi

    # Step 6: Set permissions (skip for database-only)
    if [ "$db_only" != "true" ]; then
        if should_run_step 6 "$start_step"; then
            set_permissions "$to_site" "$webroot"
        else
            print_status "INFO" "Skipping Step 6: Permissions already set"
        fi
    fi

    # Configure and start DDEV if not already running (skip for database-only, already validated)
    if [ "$db_only" != "true" ] && [ ! -f "$to_site/.ddev/config.yaml" ]; then
        print_info "Configuring DDEV for $to_site"
        cd "$to_site" || return 1

        # Get project name from directory (convert underscores to hyphens for valid hostname)
        local project_name=$(basename "$to_site" | tr '_' '-')

        ddev config --project-name="$project_name" --project-type=drupal --docroot="$webroot" --php-version="8.2" --database="mariadb:10.11" > /dev/null 2>&1
        ddev start > /dev/null 2>&1

        cd - > /dev/null
        print_status "OK" "DDEV configured and started"
    fi

    # Step 7: Restore database
    if should_run_step 7 "$start_step"; then
        if ! restore_database "$BACKUP_FILE" "$to_site"; then
            print_error "Database restoration failed"
            return 1
        fi
    else
        print_status "INFO" "Skipping Step 7: Database already restored"
    fi

    # Step 8: Clear cache
    if should_run_step 8 "$start_step"; then
        clear_cache "$to_site"
    else
        print_status "INFO" "Skipping Step 8: Cache already cleared"
    fi

    # Step 9: Generate login link (if requested)
    if [ "$open_after" == "true" ]; then
        if should_run_step 9 "$start_step"; then
            generate_login_link "$to_site"
        fi
    fi

    # Summary
    print_header "Restore Summary"
    echo -e "${GREEN}✓${NC} Source: $from_site"
    echo -e "${GREEN}✓${NC} Destination: $to_site"
    echo -e "${GREEN}✓${NC} Backup: $(basename "$BACKUP_FILE" .sql)"
    echo ""
    echo -e "${BOLD}Site URL:${NC}"
    cd "$to_site" && ddev describe 2>/dev/null | grep "^https://" && cd - > /dev/null

    return 0
}

################################################################################
# Main Script
################################################################################

main() {
    local DEBUG=false
    local DB_ONLY=false
    local USE_FIRST=false
    local AUTO_YES=false
    local OPEN_AFTER=false
    local START_STEP=1
    local FROM_SITE=""
    local TO_SITE=""

    # Parse options
    local OPTIONS=hdbfyos:
    local LONGOPTS=help,debug,db-only,first,yes,open,step:

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
            -b|--db-only)
                DB_ONLY=true
                shift
                ;;
            -f|--first)
                USE_FIRST=true
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

    # Get from/to sites
    if [ $# -ge 1 ]; then
        FROM_SITE="$1"
        shift
    else
        print_error "No source site specified"
        echo ""
        show_help
        exit 1
    fi

    # Default TO to FROM if not specified
    if [ $# -ge 1 ]; then
        TO_SITE="$1"
    else
        TO_SITE="$FROM_SITE"
    fi

    ocmsg "From: $FROM_SITE"
    ocmsg "To: $TO_SITE"
    ocmsg "Use first: $USE_FIRST"
    ocmsg "Auto yes: $AUTO_YES"
    ocmsg "Open after: $OPEN_AFTER"
    ocmsg "Database-only: $DB_ONLY"
    ocmsg "Start step: $START_STEP"

    # Run restore
    if restore_site "$FROM_SITE" "$TO_SITE" "$USE_FIRST" "$START_STEP" "$OPEN_AFTER" "$DB_ONLY"; then
        show_elapsed_time
        exit 0
    else
        print_error "Restore failed"
        exit 1
    fi
}

# Run main
main "$@"
