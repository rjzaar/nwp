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
# canonical.sh: canonicality-phase stamping (nwp/ops#33)
source "$PROJECT_ROOT/lib/canonical.sh"

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

${BOLD}SUBCOMMANDS:${NC}
    sweep                   Sweep all sites: back up any with stale/missing
                            backups (see: ./backup.sh sweep --help)

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
    Backups are stored in: sites/<sitename>/backups/
    (Legacy location sitebackups/<sitename>/ is still honored for unmigrated sites.)

    Naming convention: YYYYMMDDTHHmmss-branch-commit-message.{sql.gz,tar.gz}
    Example: 20241221T143022-main-a1b2c3d4-fixed_error.sql.gz

${BOLD}FILES CREATED:${NC}
    - Database backup (.sql.gz, gzip compressed)
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
        # Slashed branches (feat/foo) would put a subdirectory in the
        # backup filename and break ddev export-db.
        branch="${branch//\//-}"

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
    local db_file="${abs_backup_dir}/${backup_name}.sql.gz"

    ocmsg "Exporting database to: $db_file"

    # Change to site directory
    local original_dir=$(pwd)
    cd "$site_dir" || {
        print_error "Site directory not found: $site_dir"
        return 1
    }

    # Export database using DDEV with gzip compression
    local temp_file=".ddev/${backup_name}.sql.gz"
    start_spinner "Exporting database..."
    if ddev export-db --file="$temp_file" --gzip > /dev/null 2>&1; then
        stop_spinner
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
        stop_spinner
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
    start_spinner "Creating archive..."
    tar -czf "$files_archive" -C "$site_dir" "${backup_paths[@]}" 2>&1 | grep -v "Removing leading" || true
    stop_spinner

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

# Write a sidecar manifest next to the backup artifacts (nwp/ops#33).
# Records the canonical phase the backup was taken under plus the code
# anchors (git branch/commit, composer.lock sha256) so a restore/build can
# match a content snapshot to the code that produced it (P65 item 4 is the
# runtime counterpart).
write_backup_manifest() {
    local site_dir=$1
    local backup_dir=$2
    local backup_name=$3
    local sitename=$4
    local endpoint=$5
    local db_only=$6
    local sanitized=$7

    local abs_backup_dir=$(cd "$(dirname "$backup_dir")" && pwd)/$(basename "$backup_dir")
    local manifest="${abs_backup_dir}/${backup_name}.manifest.json"

    local git_branch="" git_commit=""
    if [ -d "$site_dir/.git" ]; then
        git_branch=$(git -C "$site_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
        git_commit=$(git -C "$site_dir" rev-parse HEAD 2>/dev/null || true)
    fi
    local lock_sha=""
    if [ -f "$site_dir/composer.lock" ]; then
        lock_sha=$(sha256sum "$site_dir/composer.lock" 2>/dev/null | awk '{print $1}')
    fi

    {
        printf '{\n'
        printf '  "site": "%s",\n' "$sitename"
        printf '  "endpoint": "%s",\n' "$endpoint"
        printf '  "backup_name": "%s",\n' "$backup_name"
        printf '  "canonical_phase": "%s",\n' "$(canonical_get_phase "$sitename")"
        printf '  "created": "%s",\n' "$(date -u +%FT%TZ)"
        printf '  "by": "%s",\n' "$(canonical_actor)"
        printf '  "git_branch": "%s",\n' "$git_branch"
        printf '  "git_commit": "%s",\n' "$git_commit"
        printf '  "composer_lock_sha256": "%s",\n' "$lock_sha"
        printf '  "db_only": %s,\n' "$db_only"
        printf '  "sanitized": %s\n' "$sanitized"
        printf '}\n'
    } > "$manifest"

    echo "$manifest"
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

    # Clean up spinner on exit/error
    trap 'stop_spinner' EXIT INT TERM

    if [ "$db_only" == "true" ]; then
        print_header "NWP Database Backup: $sitename"
    else
        print_header "NWP Site Backup: $sitename"
    fi

    # Resolve the DDEV project dir: v2 layout keeps it under
    # sites/<name>/dev/, v1 is the flat sites/<name>/ (resolve_project
    # handles both, plus explicit paths like <name>/stg).
    local site_dir
    if ! site_dir=$(resolve_project "$sitename"); then
        print_error "Site not found: $sitename"
        echo "Looked under: ${NWP_DIR:-${PROJECT_ROOT:-$HOME/nwp}}/sites/"
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
    # F23 Phase 4: prefer sites/<name>/backups/, fall back to legacy sitebackups/<name>/
    local backup_base
    backup_base=$(get_backup_dir "$endpoint")
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
        local sql_gz_file="${backup_base}/${backup_name}.sql.gz"
        if [ -f "$sql_gz_file" ]; then
            # Decompress, sanitize, recompress
            gunzip "$sql_gz_file"
            local sql_file="${backup_base}/${backup_name}.sql"
            sanitize_database "$site_dir" "$sql_file" "$sanitize_level"
            gzip "$sql_file"
            echo -e "${GREEN}✓${NC} Sanitized: Level $sanitize_level"
        fi
    fi

    # Sidecar manifest with the canonical phase + code anchors (nwp/ops#33)
    local manifest_file
    manifest_file=$(write_backup_manifest "$site_dir" "$backup_base" "$backup_name" \
        "$sitename" "$endpoint" "$db_only" "$sanitize" 2>/dev/null) || true

    # Summary
    print_header "Backup Summary"
    echo -e "${GREEN}✓${NC} Database: ${backup_base}/${backup_name}.sql.gz"
    if [ "$db_only" != "true" ]; then
        echo -e "${GREEN}✓${NC} Files:    ${backup_base}/${backup_name}.tar.gz"
    fi
    if [ -n "$manifest_file" ]; then
        echo -e "${GREEN}✓${NC} Manifest: ${manifest_file} (canonical: $(canonical_get_phase "$sitename"))"
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
# Sweep (nwp/ops#87 Part A) — self-driving backups
#
# `pl backup sweep` iterates every discovered site and backs up any whose
# newest backup is older than settings.todo.thresholds.backup_warn_days
# (default 7 — the SAME threshold and directory logic as
# check_missing_backups in lib/todo-checks.sh, so sweep and `pl todo`/
# `pl rag` always agree on what "stale" means).
################################################################################

show_sweep_help() {
    cat << EOF
${BOLD}NWP Backup Sweep${NC}

Back up every site whose newest backup is stale or missing.

${BOLD}USAGE:${NC}
    ./backup.sh sweep [OPTIONS]

${BOLD}OPTIONS:${NC}
    -h, --help          Show this help message
    --dry-run           List the decision for each site; take no backups
    --start-stopped     Start stopped DDEV projects, back up, stop them again
    --site NAME         Sweep a single site (for testing)

${BOLD}BEHAVIOR:${NC}
    - Freshness threshold: settings.todo.thresholds.backup_warn_days
      (default 7) — identical to the 'pl todo' missing-backups check.
    - Sweep backups are database-only (-b) with message "sweep automated backup".
    - Sites whose DDEV project is not running are skipped unless
      --start-stopped is given (prior stopped state is restored afterwards).
    - Sites without a dev DDEV project are noted and skipped.

${BOLD}SCHEDULING:${NC}
    pl schedule install-sweep       # nightly cron (default 0 2 * * *)

EOF
}

# Epoch mtime of the newest backup artifact for a site, or fail if none.
# Mirrors check_missing_backups in lib/todo-checks.sh exactly:
# candidates are <site-dir>/backups then \$ROOT/backups/<site>, and only
# *.sql.gz / *.tar.gz files count.
sweep_latest_backup_epoch() {
    local site="$1"
    local root="${NWP_DIR:-$PROJECT_ROOT}"

    local backup_dir="$root/sites/$site/backups"
    if [ ! -d "$backup_dir" ]; then
        backup_dir="$root/backups/$site"
    fi
    [ -d "$backup_dir" ] || return 1

    local latest
    latest=$(find "$backup_dir" -type f \( -name "*.sql.gz" -o -name "*.tar.gz" \) -printf '%T@\n' 2>/dev/null | sort -n | tail -1)
    [ -z "$latest" ] && return 1

    echo "${latest%.*}"
}

# DDEV project state for a project dir: running | stopped | unknown.
# `ddev describe` is read-only. "unknown" = ddev binary unavailable.
sweep_ddev_state() {
    local proj_dir="$1"

    if ! command -v ddev &>/dev/null; then
        echo "unknown"
        return 0
    fi

    local desc
    if ! desc=$(cd "$proj_dir" && ddev describe -j 2>/dev/null); then
        echo "stopped"
        return 0
    fi

    if echo "$desc" | grep -q '"status": *"running"'; then
        echo "running"
    else
        echo "stopped"
    fi
}

sweep_main() {
    local DRY_RUN=false
    local START_STOPPED=false
    local ONLY_SITE=""

    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help)
                show_sweep_help
                exit 0
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --start-stopped)
                START_STOPPED=true
                shift
                ;;
            --site)
                ONLY_SITE="${2:-}"
                if [ -z "$ONLY_SITE" ]; then
                    print_error "--site requires a site name"
                    exit 1
                fi
                shift 2
                ;;
            --site=*)
                ONLY_SITE="${1#*=}"
                shift
                ;;
            *)
                print_error "Unknown sweep option: $1"
                echo ""
                show_sweep_help
                exit 1
                ;;
        esac
    done

    # Stale threshold — read via the todo library so sweep and `pl todo`
    # can never drift apart on the definition of "stale".
    local warn_days=7
    if [ -f "$PROJECT_ROOT/lib/todo-checks.sh" ]; then
        # shellcheck source=/dev/null
        source "$PROJECT_ROOT/lib/todo-checks.sh"
        warn_days=$(get_todo_setting "thresholds.backup_warn_days" "7")
    fi

    local now_epoch warn_seconds
    now_epoch=$(date +%s)
    warn_seconds=$((warn_days * 86400))

    print_header "NWP Backup Sweep"
    print_info "Stale threshold: ${warn_days} days"
    if [ "$DRY_RUN" = true ]; then
        print_info "Dry run — no backups will be taken"
    fi

    # Collect sites up-front (array, not a pipe: backup/ddev calls below
    # must not eat the site list from stdin).
    local -a sweep_sites=()
    if [ -n "$ONLY_SITE" ]; then
        sweep_sites=("$ONLY_SITE")
    else
        mapfile -t sweep_sites < <(discover_sites)
    fi

    if [ ${#sweep_sites[@]} -eq 0 ]; then
        print_warning "No sites discovered under ${NWP_DIR:-$PROJECT_ROOT}/sites/"
        exit 0
    fi

    local total=0 fresh=0 backed_up=0 skipped=0 noproj=0 failed=0
    local site

    for site in "${sweep_sites[@]}"; do
        [ -z "$site" ] && continue
        total=$((total + 1))

        # Locate the dev DDEV project (v2 nested dev/, v1 flat).
        local proj_dir=""
        proj_dir=$(resolve_project "$site" dev 2>/dev/null) || proj_dir=""
        if [ -z "$proj_dir" ] || [ ! -d "$proj_dir/.ddev" ]; then
            echo -e "  ${DIM}- $site: no dev DDEV project — skipping${NC}"
            noproj=$((noproj + 1))
            continue
        fi

        # Freshness check (same logic as check_missing_backups).
        local latest_epoch="" age_desc="no backups found"
        if latest_epoch=$(sweep_latest_backup_epoch "$site"); then
            local age=$((now_epoch - latest_epoch))
            if [ "$age" -le "$warn_seconds" ]; then
                echo -e "  ${GREEN}✓${NC} $site: fresh (last backup $((age / 86400))d old)"
                fresh=$((fresh + 1))
                continue
            fi
            age_desc="last backup $((age / 86400))d old"
        fi

        # Stale or missing — decide based on DDEV state.
        local state
        state=$(sweep_ddev_state "$proj_dir")

        if [ "$DRY_RUN" = true ]; then
            case "$state" in
                running)
                    echo -e "  ${YELLOW}→${NC} $site: would back up ($age_desc; project running)"
                    backed_up=$((backed_up + 1))
                    ;;
                stopped)
                    if [ "$START_STOPPED" = true ]; then
                        echo -e "  ${YELLOW}→${NC} $site: would start, back up, stop ($age_desc)"
                        backed_up=$((backed_up + 1))
                    else
                        echo -e "  ${DIM}- $site: skipped — not running ($age_desc; use --start-stopped)${NC}"
                        skipped=$((skipped + 1))
                    fi
                    ;;
                *)
                    echo -e "  ${DIM}- $site: skipped — ddev not available${NC}"
                    skipped=$((skipped + 1))
                    ;;
            esac
            continue
        fi

        if [ "$state" = "unknown" ]; then
            print_warning "$site: ddev not available — skipped"
            skipped=$((skipped + 1))
            continue
        fi

        local was_stopped=false
        if [ "$state" = "stopped" ]; then
            if [ "$START_STOPPED" != true ]; then
                echo -e "  ${DIM}- $site: skipped — not running ($age_desc; use --start-stopped)${NC}"
                skipped=$((skipped + 1))
                continue
            fi
            was_stopped=true
            print_info "$site: starting DDEV project ($age_desc)..."
            if ! (cd "$proj_dir" && ddev start -y >/dev/null 2>&1); then
                print_error "$site: ddev start failed — skipped"
                failed=$((failed + 1))
                continue
            fi
        fi

        # Reuse the standard backup path (db-only) — no duplicated export logic.
        if backup_site "$site" "$site" "sweep automated backup" true false false false false false basic < /dev/null; then
            backed_up=$((backed_up + 1))
        else
            print_error "$site: backup failed"
            failed=$((failed + 1))
        fi

        # Restore prior state: stop only what we started.
        if [ "$was_stopped" = true ]; then
            print_info "$site: stopping DDEV project (was stopped before sweep)"
            (cd "$proj_dir" && ddev stop >/dev/null 2>&1) || true
        fi
    done

    print_header "Sweep Summary"
    local summary="swept $total sites: $fresh fresh, $backed_up backed up, $skipped skipped-not-running, $noproj no-project"
    if [ "$failed" -gt 0 ]; then
        summary="$summary, $failed FAILED"
    fi
    if [ "$DRY_RUN" = true ]; then
        summary="$summary (dry run)"
    fi
    echo "$summary"

    if [ "$failed" -gt 0 ]; then
        exit 1
    fi
    exit 0
}

################################################################################
# Main Script
################################################################################

main() {
    # Subcommand dispatch: `backup sweep [flags]` (sitename-first args
    # otherwise — sweep is reserved and cannot be a site name).
    if [[ "${1:-}" == "sweep" ]]; then
        shift
        sweep_main "$@"
    fi

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
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
