#!/bin/bash
set -euo pipefail

################################################################################
# NWP Backup Script
#
# Backs up DDEV sites (database + files or database only) with pleasy-style naming convention
# Based on pleasy backup.sh adapted for DDEV environments
#
# Usage: ./backup.sh [OPTIONS] <sitename> [message]
################################################################################

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

# Source shared libraries
source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/git.sh"
source "$PROJECT_ROOT/lib/sanitize.sh"

# Script start time
START_TIME=$(date +%s)

################################################################################
# Script-specific Functions
################################################################################

# Show help
show_help() {
    cat << EOF
${BOLD}NWP Backup Script${NC}

${BOLD}USAGE:${NC}
    ./backup.sh [OPTIONS] <sitename> [message]

${BOLD}OPTIONS:${NC}
    -h, --help              Show this help message
    -d, --debug             Enable debug output
    -b, --db-only           Database-only backup (skip files)
    -g, --git               Create supplementary git backup
    -e, --endpoint=NAME     Backup to different endpoint (default: sitename)
    --bundle                Create git bundle for offline/archival backup
    --incremental           Create incremental bundle (use with --bundle)
    --push-all              Push to all configured remotes (with -g)
    --sanitize              Sanitize database backup (remove PII)
    --sanitize-level=LEVEL  Sanitization level: basic, full (default: basic)

${BOLD}ARGUMENTS:${NC}
    sitename                Name of the DDEV site to backup
    message                 Optional backup description (spaces converted to underscores)

${BOLD}EXAMPLES:${NC}
    ./backup.sh nwp                              # Backup 'nwp' site (full)
    ./backup.sh -b nwp                           # Database-only backup
    ./backup.sh nwp 'Fixed error'                # Backup with message
    ./backup.sh -b nwp 'Before update'           # DB-only backup with message
    ./backup.sh -e=nwp_backup nwp 'Test backup'  # Backup to different endpoint
    ./backup.sh -bd nwp                          # DB-only backup with debug output
    ./backup.sh --bundle nwp                     # Create git bundle (full)
    ./backup.sh --bundle --incremental nwp       # Create incremental bundle
    ./backup.sh -g --push-all nwp                # Push to all remotes
    ./backup.sh --sanitize nwp                   # Sanitized backup (GDPR)

${BOLD}COMBINED FLAGS:${NC}
    Multiple short flags can be combined: -bd = -b -d
    Example: ./backup.sh -bd nwp is the same as ./backup.sh -b -d nwp

${BOLD}OUTPUT:${NC}
    Backups are stored in: sitebackups/<sitename>/

    Naming convention: YYYYMMDDTHHmmss-branch-commit-message.{sql,tar.gz}
    Example: 20241221T143022-main-a1b2c3d4-fixed_error.sql

${BOLD}FILES CREATED:${NC}
    - Database backup (.sql)
    - Files backup (.tar.gz)

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
    local site_dir=$1
    local backup_dir=$2
    local backup_name=$3

    print_header "Backing Up Database"

    # Use absolute path for backup directory
    local abs_backup_dir=$(cd "$(dirname "$backup_dir")" && pwd)/$(basename "$backup_dir")
    local db_file="${abs_backup_dir}/${backup_name}.sql"

    ocmsg "Exporting database to: $db_file"

    # Change to site directory
    local original_dir=$(pwd)
    cd "$site_dir" || {
        print_error "Site directory not found: $site_dir"
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

# Backup files
backup_files() {
    local site_dir=$1
    local backup_dir=$2
    local backup_name=$3
    local webroot=$4

    print_header "Backing Up Files"

    # Use absolute path for backup directory
    local abs_backup_dir=$(cd "$(dirname "$backup_dir")" && pwd)/$(basename "$backup_dir")
    local files_archive="${abs_backup_dir}/${backup_name}.tar.gz"

    ocmsg "Creating file archive: $files_archive"

    # Check if site directory exists
    if [ ! -d "$site_dir" ]; then
        print_error "Site directory not found: $site_dir"
        return 1
    fi

    # Determine what to backup (webroot + other important dirs)
    # SECURITY FIX: Use array to properly handle paths (prevents word splitting issues)
    local -a backup_paths=()

    if [ -d "$site_dir/$webroot" ]; then
        backup_paths+=("$webroot")
    fi

    if [ -d "$site_dir/private" ]; then
        backup_paths+=("private")
    fi

    if [ -d "$site_dir/cmi" ]; then
        backup_paths+=("cmi")
    fi

    if [ -f "$site_dir/composer.json" ]; then
        backup_paths+=("composer.json")
        if [ -f "$site_dir/composer.lock" ]; then
            backup_paths+=("composer.lock")
        fi
    fi

    if [ ${#backup_paths[@]} -eq 0 ]; then
        print_error "No files found to backup"
        return 1
    fi

    ocmsg "Backing up: ${backup_paths[*]}"

    # Create tar.gz archive (suppress "Removing leading" warnings)
    # SECURITY FIX: Use array expansion "${backup_paths[@]}" to properly quote each path
    tar -czf "$files_archive" -C "$site_dir" "${backup_paths[@]}" 2>&1 | grep -v "Removing leading" || true

    # Check if archive was created successfully
    if [ -f "$files_archive" ] && [ -s "$files_archive" ]; then
        print_status "OK" "Files backed up: $(basename "$files_archive")"

        # Show file size
        local size=$(du -h "$files_archive" | cut -f1)
        ocmsg "Files backup size: $size"

        return 0
    else
        print_error "Failed to create file archive"
        return 1
    fi
}

# Main backup function
backup_site() {
    local sitename=$1
    local endpoint=$2
    local message=$3
    local db_only=${4:-false}
    local git_backup=${5:-false}
    local bundle=${6:-false}
    local incremental=${7:-false}
    local push_all=${8:-false}
    local sanitize=${9:-false}
    local sanitize_level=${10:-basic}

    if [ "$db_only" == "true" ]; then
        print_header "NWP Database Backup: $sitename"
    else
        print_header "NWP Site Backup: $sitename"
    fi

    # Check if site directory exists
    local site_dir="sites/$sitename"
    if [ ! -d "$site_dir" ]; then
        print_error "Site directory not found: $site_dir"
        echo "Current directory: $(pwd)"
        echo "Looking for: $site_dir"
        return 1
    fi

    # Check if DDEV is configured
    if [ ! -f "$site_dir/.ddev/config.yaml" ]; then
        print_error "DDEV not configured in $site_dir"
        return 1
    fi

    # Get webroot from DDEV config
    local webroot=$(grep "^docroot:" "$site_dir/.ddev/config.yaml" 2>/dev/null | awk '{print $2}')
    if [ -z "$webroot" ]; then
        webroot="web"  # Default fallback
    fi

    ocmsg "Using webroot: $webroot"

    # Create backup directory structure
    local backup_base="sitebackups/$endpoint"
    if [ ! -d "$backup_base" ]; then
        mkdir -p "$backup_base"
        print_status "OK" "Created backup directory: $backup_base"
    fi

    # Generate backup name
    local backup_name=$(create_backup_name "$site_dir" "$message")

    print_info "Backup name: ${BOLD}$backup_name${NC}"
    print_info "Backup location: ${BOLD}$backup_base${NC}"

    # Backup database
    if ! backup_database "$site_dir" "$backup_base" "$backup_name"; then
        print_error "Database backup failed"
        return 1
    fi

    # Backup files (skip if database-only)
    if [ "$db_only" != "true" ]; then
        if ! backup_files "$site_dir" "$backup_base" "$backup_name" "$webroot"; then
            print_error "Files backup failed"
            return 1
        fi
    fi

    # Sanitize database backup if requested
    if [ "$sanitize" == "true" ]; then
        local sql_file="${backup_base}/${backup_name}.sql"
        if [ -f "$sql_file" ]; then
            sanitize_database "$site_dir" "$sql_file" "$sanitize_level"
            echo -e "${GREEN}✓${NC} Sanitized: Level $sanitize_level"
        fi
    fi

    # Summary
    print_header "Backup Summary"
    echo -e "${GREEN}✓${NC} Database: ${backup_base}/${backup_name}.sql"
    if [ "$db_only" != "true" ]; then
        echo -e "${GREEN}✓${NC} Files:    ${backup_base}/${backup_name}.tar.gz"
    fi

    # Determine backup type for git operations
    local backup_type="db"
    if [ "$db_only" != "true" ]; then
        backup_type="files"
    fi

    # Git backup if requested
    if [ "$git_backup" == "true" ]; then
        local commit_msg="Backup: $backup_name"
        if [ -n "$message" ]; then
            commit_msg="$message ($backup_name)"
        fi

        if git_backup "$backup_base" "$endpoint" "$backup_type" "$commit_msg"; then
            echo -e "${GREEN}✓${NC} Git:      Committed and pushed to GitLab"

            # Push to additional remotes if requested
            if [ "$push_all" == "true" ]; then
                print_info "Pushing to additional remotes..."
                git_push_all "$backup_base" "backup" "${endpoint}-${backup_type}" "backups"
            fi
        else
            print_warning "Git backup completed with warnings"
        fi
    fi

    # Bundle backup if requested
    if [ "$bundle" == "true" ]; then
        if git_bundle_backup "$backup_base" "$endpoint" "$backup_type" "$incremental"; then
            echo -e "${GREEN}✓${NC} Bundle:   Created offline backup bundle"
        else
            print_warning "Bundle creation completed with warnings"
        fi
    fi

    return 0
}

################################################################################
# Main Script
################################################################################

main() {
    # Parse options
    local DEBUG=false
    local DB_ONLY=false
    local GIT_BACKUP=false
    local BUNDLE=false
    local INCREMENTAL=false
    local PUSH_ALL=false
    local SANITIZE=false
    local SANITIZE_LEVEL="basic"
    local ENDPOINT=""
    local SITENAME=""
    local MESSAGE=""

    # Use getopt for option parsing
    local OPTIONS=hdbge:
    local LONGOPTS=help,debug,db-only,git,endpoint:,bundle,incremental,push-all,sanitize,sanitize-level:

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
            -g|--git)
                GIT_BACKUP=true
                shift
                ;;
            -e|--endpoint)
                ENDPOINT="$2"
                shift 2
                ;;
            --bundle)
                BUNDLE=true
                shift
                ;;
            --incremental)
                INCREMENTAL=true
                shift
                ;;
            --push-all)
                PUSH_ALL=true
                shift
                ;;
            --sanitize)
                SANITIZE=true
                shift
                ;;
            --sanitize-level)
                SANITIZE_LEVEL="$2"
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

    # Rest of arguments are the message
    if [ $# -ge 1 ]; then
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
    ocmsg "Database-only: $DB_ONLY"
    ocmsg "Git backup: $GIT_BACKUP"
    ocmsg "Bundle: $BUNDLE"
    ocmsg "Incremental: $INCREMENTAL"
    ocmsg "Push all: $PUSH_ALL"
    ocmsg "Sanitize: $SANITIZE"
    ocmsg "Sanitize level: $SANITIZE_LEVEL"

    # Run backup
    if backup_site "$SITENAME" "$ENDPOINT" "$MESSAGE" "$DB_ONLY" "$GIT_BACKUP" "$BUNDLE" "$INCREMENTAL" "$PUSH_ALL" "$SANITIZE" "$SANITIZE_LEVEL"; then
        show_elapsed_time "Backup"
        exit 0
    else
        print_error "Backup failed for site: $SITENAME"
        exit 1
    fi
}

# Run main
main "$@"
