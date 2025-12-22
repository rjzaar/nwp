#!/bin/bash

################################################################################
# NWP Database-Only Restore Script
#
# Restores DDEV site databases from backups
# Based on pleasy restoredb.sh adapted for DDEV environments
#
# Usage: ./restoredb.sh [OPTIONS] <from_site> [to_site]
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
    print_status "OK" "Database restore completed in $(printf "%02d:%02d:%02d" $hours $minutes $seconds)"
}

# Show help
show_help() {
    cat << EOF
${BOLD}NWP Database Restore Script${NC}

${BOLD}USAGE:${NC}
    ./restoredb.sh [OPTIONS] <from_site> [to_site]

${BOLD}OPTIONS:${NC}
    -h, --help              Show this help message
    -d, --debug             Enable debug output
    -f, --first             Auto-select latest (first) backup
    -y, --yes               Skip confirmation prompts
    -o, --open              Generate login link after restore (requires drush)

${BOLD}ARGUMENTS:${NC}
    from_site               Site to restore from (backup source)
    to_site                 Site to restore to (defaults to from_site)

${BOLD}EXAMPLES:${NC}
    ./restoredb.sh nwp4                     # Restore nwp4 database (interactive)
    ./restoredb.sh nwp4 nwp4_copy           # Restore nwp4 DB to nwp4_copy
    ./restoredb.sh -f nwp4                  # Auto-select latest backup
    ./restoredb.sh -f -y nwp4 nwp5          # Auto-select and skip prompts
    ./restoredb.sh -f -y -o nwp4            # Restore and generate login link

${BOLD}WORKFLOW:${NC}
    1. Select database backup (or auto-select with -f)
    2. Confirm restoration (or skip with -y)
    3. Import database to destination site
    4. Clear cache (if drush available)
    5. Generate login link (with -o flag)

${BOLD}NOTE:${NC}
    This script only restores the database. For full site restore (files + database),
    use restore.sh instead.

    The destination site must already exist and have DDEV configured.

EOF
}

################################################################################
# Backup Selection Functions
################################################################################

# List available database backups for a site
list_backups() {
    local sitename=$1
    local backup_dir="sitebackups/$sitename"

    if [ ! -d "$backup_dir" ]; then
        return 1
    fi

    # Find all .sql files, sort by name (newest first due to timestamp)
    find "$backup_dir" -maxdepth 1 -name "*.sql" -type f 2>/dev/null | sort -r
}

# Interactive backup selection
select_backup() {
    local sitename=$1
    local use_first=${2:-false}

    local backup_dir="sitebackups/$sitename"

    if [ ! -d "$backup_dir" ]; then
        print_error "No backups found for site: $sitename"
        print_info "Backup directory should be: $backup_dir"
        return 1
    fi

    # Get list of backups
    local backups=($(list_backups "$sitename"))

    if [ ${#backups[@]} -eq 0 ]; then
        print_error "No database backups found in: $backup_dir"
        return 1
    fi

    # If --first flag, return the first (newest) backup
    if [ "$use_first" == "true" ]; then
        echo "${backups[0]}"
        return 0
    fi

    # Interactive selection
    echo -e "${BOLD}Available backups for $sitename:${NC}\n"

    local i=1
    for backup in "${backups[@]}"; do
        local basename=$(basename "$backup" .sql)
        local size_sql=$(du -h "$backup" 2>/dev/null | cut -f1)
        echo -e "${BLUE}$i)${NC} $basename"
        echo -e "   Size: $size_sql"
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

restore_database() {
    local backup_file=$1
    local dest_site=$2

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

    # Check if DDEV is configured
    if [ ! -f ".ddev/config.yaml" ]; then
        print_error "DDEV not configured in $dest_site"
        print_info "Run 'ddev config' in the site directory first"
        cd "$original_dir"
        return 1
    fi

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

clear_cache() {
    local dest_site=$1

    local original_dir=$(pwd)
    cd "$dest_site" || return 1

    # Try to clear cache using drush
    if ddev drush cr > /dev/null 2>&1; then
        print_status "OK" "Cache cleared"
    else
        print_status "WARN" "Could not clear cache (drush may not be available)"
    fi

    cd "$original_dir"
}

generate_login_link() {
    local dest_site=$1

    local original_dir=$(pwd)
    cd "$dest_site" || return 1

    print_header "Generate Login Link"

    # Try to generate login link
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
# Main Restore Function
################################################################################

restore_site_database() {
    local from_site=$1
    local to_site=$2
    local use_first=$3
    local auto_yes=$4
    local open_after=$5

    print_header "NWP Database Restore: $from_site → $to_site"

    # Step 1: Select backup
    print_header "Step 1: Select Database Backup"

    local backup_file=$(select_backup "$from_site" "$use_first")
    if [ $? -ne 0 ] || [ -z "$backup_file" ]; then
        return 1
    fi

    local backup_name=$(basename "$backup_file" .sql)
    print_info "Selected backup: ${BOLD}$backup_name${NC}"

    # Step 2: Confirm restoration
    print_header "Step 2: Confirm Restoration"

    if [ ! -d "$to_site" ]; then
        print_error "Destination site not found: $to_site"
        print_info "Site must exist before restoring database"
        return 1
    fi

    if [ "$auto_yes" != "true" ]; then
        echo -e "${YELLOW}This will replace the database in ${BOLD}$to_site${NC}${YELLOW} with backup from ${BOLD}$from_site${NC}"
        echo -n "Continue? [y/N]: "
        read confirm
        if [[ ! "$confirm" =~ ^[Yy] ]]; then
            print_info "Restore cancelled"
            return 1
        fi
    else
        echo -e "Auto-confirmed: Replace database in ${BOLD}$to_site${NC}"
    fi

    # Step 3: Restore database
    print_header "Step 3: Restore Database"

    if ! restore_database "$backup_file" "$to_site"; then
        print_error "Database restoration failed"
        return 1
    fi

    # Step 4: Clear cache
    print_header "Step 4: Clear Cache"
    clear_cache "$to_site"

    # Step 5: Generate login link (if requested)
    if [ "$open_after" == "true" ]; then
        generate_login_link "$to_site"
    fi

    # Summary
    print_header "Restore Summary"
    echo -e "${GREEN}✓${NC} Source: $from_site"
    echo -e "${GREEN}✓${NC} Destination: $to_site"
    echo -e "${GREEN}✓${NC} Backup: $backup_name"

    # Get site URL
    local site_url=$(cd "$to_site" && ddev describe 2>/dev/null | grep -oP 'https://[^ ,]+' | head -1)
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
    local USE_FIRST=false
    local AUTO_YES=false
    local OPEN_AFTER=false
    local FROM_SITE=""
    local TO_SITE=""

    # Use getopt for option parsing
    local OPTIONS=hd,f,y,o
    local LONGOPTS=help,debug,first,yes,open

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

    # Run restore
    if restore_site_database "$FROM_SITE" "$TO_SITE" "$USE_FIRST" "$AUTO_YES" "$OPEN_AFTER"; then
        show_elapsed_time
        exit 0
    else
        print_error "Database restore failed"
        exit 1
    fi
}

# Run main
main "$@"
