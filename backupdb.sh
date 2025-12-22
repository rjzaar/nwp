#!/bin/bash

################################################################################
# NWP Database-Only Backup Script
#
# Backs up DDEV site databases with pleasy-style naming convention
# Based on pleasy backupdb.sh adapted for DDEV environments
#
# Usage: ./backupdb.sh [OPTIONS] <sitename> [message]
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
    print_status "OK" "Database backup completed in $(printf "%02d:%02d:%02d" $hours $minutes $seconds)"
}

# Show help
show_help() {
    cat << EOF
${BOLD}NWP Database Backup Script${NC}

${BOLD}USAGE:${NC}
    ./backupdb.sh [OPTIONS] <sitename> [message]

${BOLD}OPTIONS:${NC}
    -h, --help              Show this help message
    -d, --debug             Enable debug output
    -m, --message=TEXT      Backup description message
    -e, --endpoint=NAME     Backup to different endpoint (default: sitename)

${BOLD}ARGUMENTS:${NC}
    sitename                Name of the DDEV site to backup
    message                 Optional backup description (spaces converted to underscores)

${BOLD}EXAMPLES:${NC}
    ./backupdb.sh nwp                              # Backup 'nwp' database
    ./backupdb.sh nwp 'Before updates'             # Backup with message
    ./backupdb.sh -m 'Test backup' nwp             # Backup with -m flag
    ./backupdb.sh -e=nwp_backup nwp 'DB backup'    # Backup to different endpoint
    ./backupdb.sh -d nwp                           # Backup with debug output

${BOLD}OUTPUT:${NC}
    Backups are stored in: sitebackups/<sitename>/

    Naming convention: YYYYMMDDTHHmmss-branch-commit-message.sql
    Example: 20241221T143022-main-a1b2c3d4-before_updates.sql

${BOLD}NOTE:${NC}
    This script only backs up the database. For full site backups (files + database),
    use backup.sh instead.

EOF
}

################################################################################
# Backup Functions
################################################################################

# Get git information for backup naming
get_git_info() {
    local site_dir=$1

    if [ -d "$site_dir/.git" ]; then
        cd "$site_dir" || return 1

        # Get current branch
        local branch=$(git branch 2>/dev/null | grep \* | cut -d ' ' -f2)
        if [ -z "$branch" ]; then
            branch="no-branch"
        fi

        # Get commit hash (first 8 characters)
        local commit=$(git rev-parse HEAD 2>/dev/null | cut -c 1-8)
        if [ -z "$commit" ]; then
            commit="no-commit"
        fi

        echo "${branch}-${commit}"
    else
        echo "no-git-no-git"
    fi
}

# Create backup name following pleasy convention
create_backup_name() {
    local site_dir=$1
    local message=$2

    # Timestamp: YYYYMMDDTHHmmss
    local timestamp=$(date +%Y%m%dT%H%M%S)

    # Git info: branch-commit
    local git_info=$(get_git_info "$site_dir")

    # Message: convert spaces to underscores, remove special characters
    local msg_clean=""
    if [ -n "$message" ]; then
        msg_clean=$(echo "$message" | tr ' ' '_' | tr -cd '[:alnum:]_-')
        msg_clean="-${msg_clean}"
    fi

    # Construct name
    echo "${timestamp}-${git_info}${msg_clean}"
}

# Backup database
backup_database() {
    local sitename=$1
    local backup_dir=$2
    local backup_name=$3

    print_header "Backing Up Database"

    # Use absolute path for backup directory
    local abs_backup_dir=$(cd "$(dirname "$backup_dir")" && pwd)/$(basename "$backup_dir")
    local db_file="${abs_backup_dir}/${backup_name}.sql"

    ocmsg "Exporting database to: $db_file"

    # Change to site directory
    local original_dir=$(pwd)
    cd "$sitename" || {
        print_error "Site directory not found: $sitename"
        return 1
    }

    # Export database using DDEV to .ddev directory first
    local temp_file=".ddev/${backup_name}.sql"
    if ddev export-db --file="$temp_file" --gzip=false > /dev/null 2>&1; then
        # Move from .ddev to backup directory
        if [ -f "$temp_file" ]; then
            mv "$temp_file" "$db_file"
            print_status "OK" "Database backed up: $(basename "$db_file")"

            # Show file size
            local size=$(du -h "$db_file" | cut -f1)
            ocmsg "Database backup size: $size"
        else
            print_error "Database export file not found at: $temp_file"
            cd "$original_dir"
            return 1
        fi
    else
        print_error "Failed to export database"
        cd "$original_dir"
        return 1
    fi

    cd "$original_dir"
    return 0
}

# Main backup function
backup_site_database() {
    local sitename=$1
    local endpoint=$2
    local message=$3

    print_header "NWP Database Backup: $sitename"

    # Check if site directory exists
    if [ ! -d "$sitename" ]; then
        print_error "Site directory not found: $sitename"
        echo "Current directory: $(pwd)"
        echo "Looking for: $sitename"
        return 1
    fi

    # Check if DDEV is configured
    if [ ! -f "$sitename/.ddev/config.yaml" ]; then
        print_error "DDEV not configured in $sitename"
        return 1
    fi

    # Create backup directory structure
    local backup_base="sitebackups/$endpoint"
    if [ ! -d "$backup_base" ]; then
        mkdir -p "$backup_base"
        print_status "OK" "Created backup directory: $backup_base"
    fi

    # Generate backup name
    local backup_name=$(create_backup_name "$sitename" "$message")

    print_info "Backup name: ${BOLD}$backup_name${NC}"
    print_info "Backup location: ${BOLD}$backup_base${NC}"

    # Backup database
    if ! backup_database "$sitename" "$backup_base" "$backup_name"; then
        print_error "Database backup failed"
        return 1
    fi

    # Summary
    print_header "Backup Summary"
    echo -e "${GREEN}✓${NC} Database: ${backup_base}/${backup_name}.sql"

    return 0
}

################################################################################
# Main Script
################################################################################

main() {
    # Parse options
    local DEBUG=false
    local ENDPOINT=""
    local SITENAME=""
    local MESSAGE=""

    # Use getopt for option parsing
    local OPTIONS=hd,m:,e:
    local LONGOPTS=help,debug,message:,endpoint:

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
            -m|--message)
                MESSAGE="$2"
                shift 2
                ;;
            -e|--endpoint)
                ENDPOINT="$2"
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

    # Get sitename and message from remaining arguments
    if [ $# -ge 1 ]; then
        SITENAME="$1"
        shift
    else
        print_error "No site specified"
        echo ""
        show_help
        exit 1
    fi

    # Rest of arguments are the message (if not already set via -m)
    if [ $# -ge 1 ] && [ -z "$MESSAGE" ]; then
        MESSAGE="$*"
    fi

    # Default endpoint to sitename
    if [ -z "$ENDPOINT" ]; then
        ENDPOINT="$SITENAME"
    fi

    ocmsg "Site: $SITENAME"
    ocmsg "Endpoint: $ENDPOINT"
    ocmsg "Message: $MESSAGE"
    ocmsg "Debug: $DEBUG"

    # Run backup
    if backup_site_database "$SITENAME" "$ENDPOINT" "$MESSAGE"; then
        show_elapsed_time
        exit 0
    else
        print_error "Database backup failed"
        exit 1
    fi
}

# Run main
main "$@"
