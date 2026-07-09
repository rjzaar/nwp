#!/bin/bash
set -euo pipefail

################################################################################
# NWP Delete Script — the single site-deletion engine (nwp/ops#47)
#
# Two modes:
#   delete (default)  Remove the RUNTIME — DDEV projects + volumes (dev/stg),
#                     the site tree, the nwp.yml entry, the cron schedule —
#                     but ALWAYS preserve the recovery path: backups stored
#                     inside the tree are archived to sitebackups/<name>/
#                     (the legacy location get_backup_dir already honors, so
#                     `pl restore` keeps finding them). Resurrection:
#                     `pl install <name>` + `pl restore <name>`.
#   --purge           Remove EVERYTHING including all backups (both
#                     locations). Destroys the last recovery path, so the
#                     interactive confirmation requires typing the site name.
#
# Impact contract (lib/impact.sh): before acting, a fate manifest of every
# affected component — DELETE / ARCHIVE / KEEP — computed live from the
# system. -y skips the prompt, never the report.
#
# The status.sh TUI delete action delegates here — do not grow a parallel
# implementation there (that duplication is how the v2 bugs happened).
#
# Usage: ./delete.sh [OPTIONS] <sitename>
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

# Source shared libraries
source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/impact.sh"
# canonical.sh: phase-aware severity in the impact report + deletion ledger
source "$PROJECT_ROOT/lib/canonical.sh"

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
    pl delete [OPTIONS] <sitename>

${BOLD}MODES:${NC}
    (default)               DELETE the site runtime, KEEP the recovery path:
                            backups inside sites/<name>/backups/ are archived
                            to sitebackups/<name>/ where 'pl restore' still
                            finds them. Resurrect with:
                              pl install <name> && pl restore <name>
    --purge                 Delete EVERYTHING including all backups (both
                            locations). No recovery path remains. Interactive
                            confirmation requires typing the site name.

${BOLD}OPTIONS:${NC}
    -h, --help              Show this help message
    -d, --debug             Enable debug output
    -y, --yes               Skip the confirmation prompt (the impact report
                            is still printed — it is never skipped)
    -b, --backup            Create a fresh backup before deletion (it is
                            archived with the rest; incompatible with --purge)
    -f, --force             Force deletion (bypass name validation for cleanup)
    --purge                 See MODES above
    --keep-yml              Keep site entry in nwp.yml (default: remove)
    -k, --keep-backups      DEPRECATED no-op: keeping backups is now the
                            default behavior of plain delete

${BOLD}EXAMPLES:${NC}
    pl delete os                        # Delete runtime, archive backups
    pl delete -by old_site              # Fresh backup, then delete (archived)
    pl delete --purge scratch-site      # Everything gone — type name to confirm
    pl delete --purge -y ci-fixture     # Scriptable purge (report still prints)

${BOLD}WHAT EACH MODE TOUCHES:${NC}
    component                          delete      --purge
    DDEV projects + volumes (dev/stg)  delete      delete
    site tree / code                   delete      delete
    backups in sites/<name>/backups/   archive     delete
    legacy sitebackups/<name>/         keep        delete
    nwp.yml entry                      delete*     delete*
    cron backup schedule               delete      delete
    canonical ledger / deploy records  keep        keep
    live server / GitLab remote        never       never
    (* unless --keep-yml)

    The full, live-computed fate manifest is printed before every run.

EOF
}

################################################################################
# Helpers
################################################################################

# DDEV project name for a directory: the name: field in .ddev/config.yaml
# (basename is wrong for the v2 layout — sites/<name>/dev → "dev").
# NOTE: status.sh carries get_ddev_project_name with the same logic; when a
# third consumer appears, promote this to lib/common.sh.
_ddev_project_name() {
    local directory="$1"
    local name=""
    if [ -f "$directory/.ddev/config.yaml" ]; then
        name=$(awk '/^name:/ {print $2; exit}' "$directory/.ddev/config.yaml")
    fi
    [ -n "$name" ] && echo "$name" || basename "$directory" 2>/dev/null
}

# Check if site directory exists
site_exists() {
    local sitename=$1
    [ -d "$PROJECT_ROOT/sites/$sitename" ]
}

################################################################################
# Impact report (the contract: computed, complete, always printed)
################################################################################

# Populate lib/impact.sh collectors for this deletion. Sets the globals
# DDEV_DIRS (projects to tear down) and ARCHIVE_SRC (backups dir to relocate,
# empty when nothing to archive) for the execution phase, so what we DO is
# exactly what we REPORTED.
DDEV_DIRS=()
ARCHIVE_SRC=""

build_impact_report() {
    local sitename="$1"
    local purge="$2"

    local site_dir="$PROJECT_ROOT/sites/$sitename"
    local archive_dst="$PROJECT_ROOT/sitebackups/$sitename"

    impact_reset

    # --- files ---
    impact_delete "Files" "$site_dir ($(du -sh "$site_dir" 2>/dev/null | awk '{print $1}'))"

    # --- DDEV projects + their Docker volumes ---
    DDEV_DIRS=()
    local ddev_status_lines
    ddev_status_lines=$(ddev list -j 2>/dev/null | "${YQ:-yq}" e -p=json '.raw[] | .name + " " + .status' - 2>/dev/null) || ddev_status_lines=""
    local d project vols pstate
    for d in "$site_dir" "$site_dir/dev" "$site_dir/stg"; do
        [ -d "$d/.ddev" ] || continue
        DDEV_DIRS+=("$d")
        project=$(_ddev_project_name "$d")
        pstate="stopped"
        grep -q "^${project} running$" <<< "$ddev_status_lines" && pstate="running"
        vols=$(docker volume ls --format '{{.Name}}' 2>/dev/null | grep "^${project}-" | paste -sd ',' - | sed 's/,/, /g') || vols=""
        impact_delete "DDEV" "$project ($pstate) — containers + Docker volumes: ${vols:-none found}"
    done

    # --- backups: the delete/purge fork ---
    ARCHIVE_SRC=""
    local in_tree="$site_dir/backups"
    if [ -d "$in_tree" ]; then
        local bk_count bk_size
        bk_count=$(find "$in_tree" -type f 2>/dev/null | wc -l)
        bk_size=$(du -sh "$in_tree" 2>/dev/null | awk '{print $1}')
        if [ "$purge" = "true" ]; then
            impact_delete "Backups" "$bk_count file(s), ${bk_size:-?} in $in_tree — NO copy will remain"
        else
            ARCHIVE_SRC="$in_tree"
            impact_archive "Backups" "$bk_count file(s), ${bk_size:-?} → $archive_dst ('pl restore $sitename' keeps working)"
        fi
    fi
    if [ -d "$archive_dst" ]; then
        local lg_count lg_size
        lg_count=$(find "$archive_dst" -type f 2>/dev/null | wc -l)
        lg_size=$(du -sh "$archive_dst" 2>/dev/null | awk '{print $1}')
        if [ "$purge" = "true" ]; then
            impact_delete "Backups" "$lg_count file(s), ${lg_size:-?} in $archive_dst — NO copy will remain"
        else
            impact_keep "Existing backups at $archive_dst ($lg_count file(s), ${lg_size:-?})"
        fi
    fi

    # --- registry + schedule ---
    if [ "$KEEP_YML" = "true" ]; then
        impact_keep "nwp.yml entry ('--keep-yml')"
    else
        impact_delete "Config" "'$sitename' entry removed from nwp.yml (timestamped copy kept in .backups/)"
    fi
    if crontab -l 2>/dev/null | grep -qw "$sitename"; then
        impact_delete "Schedule" "cron backup schedule entries mentioning '$sitename'"
    fi

    # --- data-loss warnings: work that exists only here ---
    local repo rel dirty unpushed remotes
    for repo in "$site_dir" "$site_dir/dev" "$site_dir/stg"; do
        [ -d "$repo/.git" ] || continue
        rel="${repo#"$site_dir"}"; rel="${rel#/}"; [ -z "$rel" ] && rel="(root)"
        remotes=$(git -C "$repo" remote 2>/dev/null | wc -l)
        dirty=$(git -C "$repo" status --porcelain 2>/dev/null | wc -l)
        unpushed=$(git -C "$repo" log --branches --not --remotes --oneline 2>/dev/null | wc -l)
        if [ "$remotes" -eq 0 ]; then
            impact_warn "git repo $rel: NO remote configured — this directory holds the ONLY copy of its history"
        elif [ "$unpushed" -gt 0 ]; then
            impact_warn "git repo $rel: $unpushed commit(s) not pushed to any remote — they will be lost"
        fi
        if [ "$dirty" -gt 0 ]; then
            impact_warn "git repo $rel: $dirty uncommitted change(s) — they will be lost"
        fi
    done

    # --- canonicality-aware severity (ops#33) ---
    local phase
    phase=$(canonical_get_phase "$sitename")
    case "$phase" in
        dev)
            impact_warn "canonical: dev — the LOCAL content being deleted IS the source of truth; any live copy is disposable and will NOT restore it"
            ;;
        live|prod)
            impact_keep "Canonical content — the site is canonical: $phase; the source of truth lives on $phase, untouched by this deletion"
            ;;
    esac
    if [ "$purge" = "true" ] && [ "$phase" = "dev" ]; then
        impact_warn "PURGE of a dev-canonical site = the content ceases to exist anywhere"
    fi

    # --- what survives ---
    local live_domain
    live_domain=$(yaml_get_site_field "$sitename" "live_domain" "$PROJECT_ROOT/nwp.yml" 2>/dev/null) || live_domain=""
    if [ -z "$live_domain" ] && command -v get_site_config_value >/dev/null 2>&1; then
        live_domain=$(get_site_config_value "$sitename" '.live.domain' "" 2>/dev/null) || live_domain=""
    fi
    if [ -n "$live_domain" ]; then
        impact_keep "The live server (https://$live_domain) — its files, database and certificates stay"
    fi
    impact_keep "Anything already pushed to a git remote (GitLab keeps those commits)"
    impact_keep "Deletion audit: recorded in private/canonical/${sitename}.log (survives the site)"
    impact_keep "Other sites' DDEV projects, volumes and directories"
}

################################################################################
# Execution steps
################################################################################

# Create a fresh backup first (-b)
create_backup() {
    local sitename=$1
    print_header "Pre-deletion Backup"
    if [ -f "$SCRIPT_DIR/backup.sh" ]; then
        if "$SCRIPT_DIR/backup.sh" "$sitename" "Pre-deletion backup"; then
            print_status "OK" "Backup created"
            return 0
        fi
    fi
    print_error "Backup failed"
    return 1
}

# Tear down every DDEV project recorded in DDEV_DIRS (report = action)
teardown_ddev_projects() {
    print_header "Remove DDEV Projects"
    if [ ${#DDEV_DIRS[@]} -eq 0 ]; then
        print_status "INFO" "No DDEV projects found"
        return 0
    fi
    local d project
    for d in "${DDEV_DIRS[@]}"; do
        project=$(_ddev_project_name "$d")
        print_status "INFO" "Removing DDEV project: $project"
        (cd "$d" && ddev stop >/dev/null 2>&1) || print_warning "ddev stop failed for $project (continuing)"
        if (cd "$d" && ddev delete -Oy >/dev/null 2>&1); then
            print_status "OK" "DDEV project deleted: $project"
        else
            print_warning "ddev delete failed for $project (continuing — volumes may need manual cleanup)"
        fi
    done
    return 0
}

# Archive in-tree backups to sitebackups/<name>/ (delete mode only)
archive_backups() {
    local sitename=$1
    [ -n "$ARCHIVE_SRC" ] && [ -d "$ARCHIVE_SRC" ] || return 0

    print_header "Archive Backups"
    local dst="$PROJECT_ROOT/sitebackups/$sitename"
    mkdir -p "$(dirname "$dst")"
    if [ ! -e "$dst" ]; then
        if mv "$ARCHIVE_SRC" "$dst"; then
            print_status "OK" "Backups archived to $dst"
            return 0
        fi
    else
        # Destination exists (older archived backups) — merge contents.
        if find "$ARCHIVE_SRC" -mindepth 1 -maxdepth 1 -exec mv -t "$dst" {} + 2>/dev/null; then
            rmdir "$ARCHIVE_SRC" 2>/dev/null || true
            print_status "OK" "Backups merged into $dst"
            return 0
        fi
    fi
    print_error "Could not archive backups from $ARCHIVE_SRC — ABORTING before any deletion"
    print_info  "Nothing has been deleted. Move the backups manually, then re-run."
    return 1
}

# Remove the site tree
remove_site_directory() {
    local sitename=$1
    local force="${2:-false}"

    print_header "Remove Site Directory"

    # Non-empty floor applies in BOTH modes. --force relaxes the character policy
    # (so invalid-but-non-empty names can be cleaned up) but must NEVER bypass the
    # empty-name check, which would resolve to `rm -rf $PROJECT_ROOT/sites/`.
    if [[ -z "$sitename" ]]; then
        print_error "Refusing to remove site directory: empty site name (not bypassable with --force)"
        return 1
    fi

    if [[ "$force" != "true" ]]; then
        if ! validate_sitename "$sitename" "site directory"; then
            print_info "Tip: Use --force flag to delete sites with invalid names"
            return 1
        fi
    else
        print_warning "Force mode: skipping name validation for cleanup"
    fi

    local site_dir="${PROJECT_ROOT:?PROJECT_ROOT required}/sites/${sitename:?sitename required}"
    local dir_size=$(du -sh "$site_dir" 2>/dev/null | awk '{print $1}')

    if rm -rf "$site_dir" 2>/dev/null; then
        print_status "OK" "Directory removed: $site_dir (${dir_size:-unknown size})"
        return 0
    fi
    print_error "Failed to remove directory: $site_dir"
    print_info "You may need to manually remove it with: sudo rm -rf $site_dir"
    return 1
}

# Purge mode: remove archived/legacy backups too
purge_backups() {
    local sitename=$1
    print_header "Purge Backups"
    local d removed=false
    for d in "$PROJECT_ROOT/sitebackups/$sitename"; do
        if [ -d "$d" ]; then
            local sz=$(du -sh "$d" 2>/dev/null | awk '{print $1}')
            if rm -rf "$d" 2>/dev/null; then
                print_status "OK" "Backups purged: $d (${sz:-?})"
                removed=true
            else
                print_warning "Could not remove $d"
            fi
        fi
    done
    [ "$removed" = "false" ] && print_status "INFO" "No backup directories remained outside the tree"
    return 0
}

# Remove the site's cron backup schedule
remove_schedule() {
    local sitename=$1
    print_header "Remove Backup Schedule"
    if ! crontab -l 2>/dev/null | grep -qw "$sitename"; then
        print_status "INFO" "No schedule found"
        return 0
    fi
    if [ -f "$SCRIPT_DIR/schedule.sh" ] && "$SCRIPT_DIR/schedule.sh" remove "$sitename" >/dev/null 2>&1; then
        print_status "OK" "Schedule removed"
    else
        print_warning "Could not remove schedule automatically — check: crontab -l | grep $sitename"
    fi
    return 0
}

# Remove from nwp.yml
remove_from_cnwp() {
    local sitename=$1
    local keep_yml=$2

    print_header "Remove from nwp.yml"

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
            sub(" *#.*$", "")
            print
            exit
        }
    ' "$PROJECT_ROOT/nwp.yml")
    delete_site_yml=${delete_site_yml:-true}

    if [ "$keep_yml" == "true" ]; then
        print_status "INFO" "Keeping site entry in nwp.yml (--keep-yml flag)"
        return 0
    fi
    if [ "$delete_site_yml" == "false" ]; then
        print_status "INFO" "Keeping site entry in nwp.yml (delete_site_yml: false in settings)"
        return 0
    fi
    if ! yaml_site_exists "$sitename" "$PROJECT_ROOT/nwp.yml"; then
        print_status "INFO" "Site not found in nwp.yml"
        return 0
    fi

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
KEEP_YML=false
FORCE_DELETE=false
PURGE=false

# Parse command-line options (-k kept as a deprecated no-op)
TEMP=$(getopt -o hdbykf --long help,debug,backup,yes,keep-backups,keep-yml,force,purge -n 'delete.sh' -- "$@")

if [ $? != 0 ]; then
    echo "Error parsing options. Use --help for usage information." >&2
    exit 1
fi

eval set -- "$TEMP"

while true; do
    case "$1" in
        -h|--help) show_help; exit 0 ;;
        -d|--debug) DEBUG=true; shift ;;
        -b|--backup) CREATE_BACKUP=true; shift ;;
        -y|--yes) AUTO_CONFIRM=true; shift ;;
        -k|--keep-backups)
            print_info "-k/--keep-backups is deprecated: plain delete now always preserves backups (archived to sitebackups/<name>/)."
            shift ;;
        --keep-yml) KEEP_YML=true; shift ;;
        -f|--force) FORCE_DELETE=true; shift ;;
        --purge) PURGE=true; shift ;;
        --) shift; break ;;
        *) echo "Internal error!"; exit 1 ;;
    esac
done

# Check for required argument
if [ $# -lt 1 ]; then
    print_error "Missing required argument: sitename"
    echo ""
    echo "Usage: pl delete [OPTIONS] <sitename>"
    echo "Use --help for more information"
    exit 1
fi

SITENAME=$1

if [ "$PURGE" = "true" ] && [ "$CREATE_BACKUP" = "true" ]; then
    print_error "-b and --purge are contradictory: the fresh backup would be purged immediately."
    print_info  "Use plain 'pl delete -b $SITENAME' (backup is archived), or --purge without -b."
    exit 1
fi

# Show header
print_header "NWP Site Deletion: $SITENAME$([ "$PURGE" = "true" ] && echo ' (PURGE — including all backups)')"

# Validate site exists
if ! site_exists "$SITENAME"; then
    print_error "Site directory not found: sites/$SITENAME"
    print_info "Use 'pl status -s' to see registered sites"
    exit 1
fi

# Check site purpose before deletion
SITE_PURPOSE=""
if command -v yaml_get_site_purpose &> /dev/null; then
    SITE_PURPOSE=$(yaml_get_site_purpose "$SITENAME" "$PROJECT_ROOT/nwp.yml" 2>/dev/null) || SITE_PURPOSE=""
fi

case "$SITE_PURPOSE" in
    permanent)
        print_error "Site '$SITENAME' has purpose 'permanent' and cannot be deleted"
        echo ""
        print_info "To delete this site, first change its purpose in nwp.yml:"
        echo "  1. Edit nwp.yml"
        echo "  2. Find the site entry for '$SITENAME'"
        echo "  3. Change 'purpose: permanent' to 'purpose: indefinite' or 'purpose: testing'"
        echo "  4. Run pl delete again"
        exit 1
        ;;
    migration)
        print_warning "Site '$SITENAME' is a migration site (may contain work in progress)"
        ;;
esac

# THE IMPACT CONTRACT: compute + print the fate manifest, then confirm.
# The report is printed even with -y; only the prompt is skipped.
build_impact_report "$SITENAME" "$PURGE"
impact_render

if [ "$PURGE" = "true" ]; then
    impact_confirm typed "$SITENAME" "$AUTO_CONFIRM" || { print_info "Deletion cancelled"; exit 0; }
else
    impact_confirm standard "delete site '$SITENAME'" "$AUTO_CONFIRM" || { print_info "Deletion cancelled"; exit 0; }
fi

# Fresh backup if requested (archived with the rest afterwards)
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
    # A fresh backup landed in sites/<name>/backups/ — pick it up for archiving.
    if [ "$PURGE" != "true" ] && [ -d "$PROJECT_ROOT/sites/$SITENAME/backups" ]; then
        ARCHIVE_SRC="$PROJECT_ROOT/sites/$SITENAME/backups"
    fi
fi

# Archive backups OUT of the tree first — if this fails we abort before
# anything is destroyed (fail-closed: the recovery path outlives mistakes).
if [ "$PURGE" != "true" ]; then
    if ! archive_backups "$SITENAME"; then
        exit 1
    fi
fi

# Tear down DDEV projects (exactly the ones the report listed)
teardown_ddev_projects

# Remove site directory
if ! remove_site_directory "$SITENAME" "$FORCE_DELETE"; then
    print_error "Failed to remove site directory: $SITENAME"
    exit 1
fi

# Purge mode: remove remaining backup locations
if [ "$PURGE" = "true" ]; then
    purge_backups "$SITENAME"
fi

# Remove cron schedule + registry entry
remove_schedule "$SITENAME"
remove_from_cnwp "$SITENAME" "$KEEP_YML"

# Ledger the deletion (append-only, survives the site — audit trail)
canonical_ledger_append "$SITENAME" "action=delete mode=$([ "$PURGE" = "true" ] && echo purge || echo archive)" || true

# Show summary
print_header "Deletion Summary"
print_status "OK" "Site deleted: $SITENAME$([ "$PURGE" = "true" ] && echo ' (purged — no backups remain)')"

if [ "$PURGE" != "true" ]; then
    _remaining_backup_dir="$PROJECT_ROOT/sitebackups/$SITENAME"
    if [ -d "$_remaining_backup_dir" ]; then
        print_status "INFO" "Backups preserved in: $_remaining_backup_dir"
        print_status "INFO" "Resurrect with: pl install $SITENAME && pl restore $SITENAME"
    fi
fi

show_elapsed_time "Site deletion"

echo ""
exit 0
