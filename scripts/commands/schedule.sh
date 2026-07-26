#!/bin/bash
set -euo pipefail

################################################################################
# NWP Schedule Script
#
# Manage cron-based backup scheduling for NWP sites
#
# Usage: ./schedule.sh [OPTIONS] <command> [sitename]
################################################################################

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

# Source shared libraries
source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh"

################################################################################
# Configuration
################################################################################

# Cron configuration
CRON_COMMENT="# NWP Backup Schedule"
CRON_DB_DEFAULT="0 2 * * *"       # Daily at 2 AM
CRON_FULL_DEFAULT="0 3 * * 0"     # Weekly Sunday at 3 AM
CRON_BUNDLE_DEFAULT="0 4 1 * *"   # Monthly 1st at 4 AM
CRON_SWEEP_DEFAULT="0 2 * * *"    # Daily at 2 AM (before the 04:30 rag-sync)
LOG_DIR="/var/log/nwp"
SWEEP_LOG_DIR="$PROJECT_ROOT/logs"

################################################################################
# Help
################################################################################

show_help() {
    cat << EOF
${BOLD}NWP Schedule Script${NC}

${BOLD}USAGE:${NC}
    ./schedule.sh [OPTIONS] <command> [sitename]

${BOLD}COMMANDS:${NC}
    install <sitename>      Install backup schedule for a site
    remove <sitename>       Remove backup schedule for a site
    install-sweep           Install nightly 'pl backup sweep' cron (all sites)
    remove-sweep            Remove the backup-sweep cron entry
    list                    List all scheduled backups
    show <sitename>         Show schedule for a specific site
    run <sitename>          Run scheduled backup now (for testing)

${BOLD}CROSS-HOST:${NC}
    where                   Which HOST owns each schedule (local + every server;
                            an unreachable host reports UNREACHABLE, never "none")
    host <target> list      List cron on a remote role/server over ssh
    host <target> install --name=<id> --schedule="<expr>" --command=<abs-path>
    host <target> remove  --name=<id>
                            Remote cron, idempotent, dry-run by default

${BOLD}OPTIONS:${NC}
    -h, --help              Show this help message
    -d, --debug             Enable debug output
    --db-schedule=CRON      Database backup schedule (default: 0 2 * * *)
    --full-schedule=CRON    Full backup schedule (default: 0 3 * * 0)
    --bundle-schedule=CRON  Bundle backup schedule (default: 0 4 1 * *)
    --schedule=CRON         Sweep schedule for install-sweep (default: 0 2 * * *)
    --no-db                 Don't schedule database backups
    --no-full               Don't schedule full backups
    --no-bundle             Don't schedule bundle backups
    --git                   Include git push in scheduled backups
    --push-all              Push to all remotes (with --git)

${BOLD}EXAMPLES:${NC}
    ./schedule.sh install nwp                    # Install default schedule
    ./schedule.sh install nwp --git              # With git push
    ./schedule.sh install nwp --db-schedule="0 4 * * *"  # Custom time
    ./schedule.sh remove nwp                     # Remove schedule
    ./schedule.sh install-sweep                  # Nightly sweep of all sites
    ./schedule.sh install-sweep --schedule="30 1 * * *"  # Custom sweep time
    ./schedule.sh remove-sweep                   # Remove sweep entry
    ./schedule.sh list                           # List all schedules
    ./schedule.sh run nwp                        # Test run now

${BOLD}DEFAULT SCHEDULE:${NC}
    Database:  Daily at 2:00 AM
    Full:      Weekly Sunday at 3:00 AM
    Bundle:    Monthly 1st at 4:00 AM

${BOLD}LOG FILES:${NC}
    Backup logs are written to: /var/log/nwp/backup-<sitename>.log

EOF
}

################################################################################
# Schedule Functions
################################################################################

# Get schedule from nwp.yml for a site
get_site_schedule() {
    local sitename="$1"
    local schedule_type="$2"  # database, full, bundle
    local cnwp_file="${PROJECT_ROOT}/nwp.yml"

    if [ ! -f "$cnwp_file" ]; then
        return 1
    fi

    # Try to get schedule from nwp.yml git_backup section
    awk -v type="$schedule_type" '
        /^git_backup:/ { in_git_backup = 1; next }
        in_git_backup && /^[a-zA-Z]/ && !/^  / { in_git_backup = 0 }
        in_git_backup && /^  schedule:/ { in_schedule = 1; next }
        in_schedule && /^  [a-zA-Z]/ && !/^    / { in_schedule = 0 }
        in_schedule && $0 ~ "^    " type ":" {
            sub("^    " type ": *", "")
            gsub(/["'"'"']/, "")
            print
            exit
        }
    ' "$cnwp_file"
}

# Generate cron entry for a backup type
generate_cron_entry() {
    local sitename="$1"
    local backup_type="$2"  # db, full, bundle
    local schedule="$3"
    local git_flag="$4"
    local push_all="$5"

    local backup_cmd="${SCRIPT_DIR}/backup.sh"
    local flags=""

    case "$backup_type" in
        db)
            flags="-b"
            ;;
        full)
            flags=""
            ;;
        bundle)
            flags="--bundle"
            ;;
    esac

    if [ "$git_flag" == "true" ]; then
        flags="$flags -g"
    fi

    if [ "$push_all" == "true" ]; then
        flags="$flags --push-all"
    fi

    # Create log directory if needed
    mkdir -p "$LOG_DIR" 2>/dev/null || true

    local log_file="${LOG_DIR}/backup-${sitename}.log"

    echo "$schedule cd ${SCRIPT_DIR} && $backup_cmd $flags $sitename \"Scheduled $backup_type backup\" >> $log_file 2>&1"
}

# Install cron schedule for a site
install_schedule() {
    local sitename="$1"
    local db_schedule="$2"
    local full_schedule="$3"
    local bundle_schedule="$4"
    local no_db="$5"
    local no_full="$6"
    local no_bundle="$7"
    local git_flag="$8"
    local push_all="$9"

    print_header "Installing Backup Schedule: $sitename"

    # Validate site exists
    if [ ! -d "$PROJECT_ROOT/sites/$sitename" ]; then
        print_warning "Site directory not found: $PROJECT_ROOT/sites/$sitename (schedule will still be installed)"
    fi

    # Create log directory
    if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
        print_warning "Cannot create log directory: $LOG_DIR (using /tmp instead)"
        LOG_DIR="/tmp/nwp"
        mkdir -p "$LOG_DIR"
    fi

    # Get current crontab
    local current_cron
    current_cron=$(crontab -l 2>/dev/null || echo "")

    # Remove existing entries for this site
    local new_cron
    new_cron=$(echo "$current_cron" | grep -v "NWP.*$sitename" | grep -v "backup.sh.*$sitename" || true)

    # Add new entries
    local entries=""

    if [ "$no_db" != "true" ]; then
        local db_entry=$(generate_cron_entry "$sitename" "db" "$db_schedule" "$git_flag" "$push_all")
        entries="${entries}${CRON_COMMENT} - $sitename - Database\n${db_entry}\n"
        print_status "OK" "Database backup: $db_schedule"
    fi

    if [ "$no_full" != "true" ]; then
        local full_entry=$(generate_cron_entry "$sitename" "full" "$full_schedule" "$git_flag" "$push_all")
        entries="${entries}${CRON_COMMENT} - $sitename - Full\n${full_entry}\n"
        print_status "OK" "Full backup: $full_schedule"
    fi

    if [ "$no_bundle" != "true" ]; then
        local bundle_entry=$(generate_cron_entry "$sitename" "bundle" "$bundle_schedule" "false" "false")
        entries="${entries}${CRON_COMMENT} - $sitename - Bundle\n${bundle_entry}\n"
        print_status "OK" "Bundle backup: $bundle_schedule"
    fi

    # Install new crontab
    if [ -n "$entries" ]; then
        echo -e "${new_cron}\n${entries}" | crontab -
        print_status "OK" "Schedule installed for $sitename"
        print_info "Logs: $LOG_DIR/backup-${sitename}.log"
    else
        print_warning "No schedules enabled"
    fi

    return 0
}

# Remove cron schedule for a site
remove_schedule() {
    local sitename="$1"

    print_header "Removing Backup Schedule: $sitename"

    # Get current crontab
    local current_cron
    current_cron=$(crontab -l 2>/dev/null || echo "")

    if [ -z "$current_cron" ]; then
        print_info "No cron entries found"
        return 0
    fi

    # Remove entries for this site
    local new_cron
    new_cron=$(echo "$current_cron" | grep -v "NWP.*$sitename" | grep -v "backup.sh.*$sitename" || true)

    # Install updated crontab
    if [ -n "$new_cron" ]; then
        echo "$new_cron" | crontab -
    else
        crontab -r 2>/dev/null || true
    fi

    print_status "OK" "Schedule removed for $sitename"
    return 0
}

# Install the fleet-wide backup-sweep cron entry (nwp/ops#87 Part A).
# One user-crontab line runs `pl backup sweep` nightly; the sweep itself
# decides per-site whether a backup is needed (stale threshold shared with
# `pl todo`). Uses the same CRON_COMMENT marker family as per-site entries
# so `schedule list` sees it.
install_sweep_schedule() {
    local schedule="$1"

    print_header "Installing Backup Sweep Schedule"

    # Sweep logs live under the project (matches logs/rag-sync.log et al.).
    mkdir -p "$SWEEP_LOG_DIR" 2>/dev/null || true
    local log_file="$SWEEP_LOG_DIR/backup-sweep.log"

    # Get current crontab
    local current_cron
    current_cron=$(crontab -l 2>/dev/null || echo "")

    # Remove any existing sweep entries (idempotent re-install)
    local new_cron
    new_cron=$(echo "$current_cron" | grep -v "${CRON_COMMENT} - sweep" | grep -v "pl backup sweep" || true)

    local sweep_entry="$schedule ${PROJECT_ROOT}/pl backup sweep >> $log_file 2>&1"

    echo -e "${new_cron}\n${CRON_COMMENT} - sweep\n${sweep_entry}\n" | crontab -

    print_status "OK" "Backup sweep scheduled: $schedule"
    print_info "Command: ${PROJECT_ROOT}/pl backup sweep"
    print_info "Logs: $log_file"
    return 0
}

# Remove the backup-sweep cron entry
remove_sweep_schedule() {
    print_header "Removing Backup Sweep Schedule"

    local current_cron
    current_cron=$(crontab -l 2>/dev/null || echo "")

    if [ -z "$current_cron" ]; then
        print_info "No cron entries found"
        return 0
    fi

    if ! echo "$current_cron" | grep -q "pl backup sweep"; then
        print_info "No backup sweep entry found"
        return 0
    fi

    local new_cron
    new_cron=$(echo "$current_cron" | grep -v "${CRON_COMMENT} - sweep" | grep -v "pl backup sweep" || true)

    if [ -n "$new_cron" ]; then
        echo "$new_cron" | crontab -
    else
        crontab -r 2>/dev/null || true
    fi

    print_status "OK" "Backup sweep schedule removed"
    return 0
}

# List all scheduled backups
list_schedules() {
    print_header "NWP Scheduled Backups"

    local cron
    cron=$(crontab -l 2>/dev/null || echo "")

    if [ -z "$cron" ]; then
        print_info "No scheduled backups found"
        return 0
    fi

    local nwp_entries
    nwp_entries=$(echo "$cron" | grep -E "(NWP|backup\.sh|pl backup sweep)" || true)

    if [ -z "$nwp_entries" ]; then
        print_info "No NWP scheduled backups found"
        return 0
    fi

    echo "$nwp_entries"
    return 0
}

# Show schedule for a specific site
show_schedule() {
    local sitename="$1"

    print_header "Schedule: $sitename"

    local cron
    cron=$(crontab -l 2>/dev/null || echo "")

    if [ -z "$cron" ]; then
        print_info "No scheduled backups found"
        return 0
    fi

    local site_entries
    site_entries=$(echo "$cron" | grep -E "$sitename" || true)

    if [ -z "$site_entries" ]; then
        print_info "No scheduled backups found for $sitename"
        return 0
    fi

    echo "$site_entries"
    return 0
}

# Run scheduled backup now (for testing)
run_backup_now() {
    local sitename="$1"
    local git_flag="$2"
    local push_all="$3"

    print_header "Running Backup Now: $sitename"

    local flags="-b"  # Default to database backup
    if [ "$git_flag" == "true" ]; then
        flags="$flags -g"
    fi
    if [ "$push_all" == "true" ]; then
        flags="$flags --push-all"
    fi

    "${SCRIPT_DIR}/backup.sh" $flags "$sitename" "Manual scheduled backup test"
}

################################################################################
# Main Script
################################################################################

################################################################################
# Remote / cross-host scheduling (fix-programme item 6)
#
# `pl demo schedule` has been printing "the production schedule belongs on met
# (pl schedule host)" while `pl schedule host` DID NOT EXIST — the handover was
# a 5-step scp/ssh ritual against a LAN alias that is unreachable off-LAN. And
# nothing could answer "which machine owns this cron?", so a reset schedule sat
# on a travelling laptop for weeks without anyone noticing.
################################################################################

# pl schedule host <target> ...  — thin, deliberate delegation to `pl host
# schedule`, which owns the remote-cron implementation.
cmd_schedule_host() {
    exec "$PROJECT_ROOT/scripts/commands/host.sh" schedule "$@"
}

# pl schedule where — which HOST owns each schedule.
cmd_schedule_where() {
    # shellcheck source=/dev/null
    source "$PROJECT_ROOT/lib/server-resolver.sh"
    # shellcheck source=/dev/null
    source "$PROJECT_ROOT/lib/host-capture.sh"

    printf '%-18s %-12s %s\n' "HOST" "STATE" "SCHEDULE"
    printf '%-18s %-12s %s\n' "----" "-----" "--------"

    local me; me="$(hostname -s 2>/dev/null || hostname)"
    local local_entries
    local_entries="$(crontab -l 2>/dev/null | grep -E '^[0-9*].*(nwp|pl |agent-loop|rag-sync|demo)' || true)"
    if [ -n "$local_entries" ]; then
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            printf '%-18s %-12s %s\n' "$me" "local" "$(printf '%s' "$line" | cut -c1-90)"
        done <<< "$local_entries"
    else
        printf '%-18s %-12s %s\n' "$me" "local" "(no NWP cron entries on this machine)"
    fi

    local servers; servers="$(discover_servers 2>/dev/null || true)"
    local name prefix out rc
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        if ! prefix="$(host_resolve_dest "$name" 2>/dev/null)"; then
            printf '%-18s %-12s %s\n' "$name" "UNKNOWN" "(no ssh route resolved — cannot say)"
            continue
        fi
        rc=0
        out="$(host_run "$prefix" 'ls -1 /etc/cron.d 2>/dev/null | grep -E "nwp|demo|dr-pull" || true' 2>/dev/null)" || rc=$?
        if [ "$rc" -ne 0 ]; then
            # Blindness is reported as blindness, never as "no schedules".
            printf '%-18s %-12s %s\n' "$name" "UNREACHABLE" "(could not read cron — this is NOT 'none')"
            continue
        fi
        if [ -z "$out" ]; then
            printf '%-18s %-12s %s\n' "$name" "remote" "(no /etc/cron.d NWP entries)"
        else
            while IFS= read -r f; do
                [ -n "$f" ] || continue
                printf '%-18s %-12s %s\n' "$name" "remote" "/etc/cron.d/$f"
            done <<< "$out"
        fi
    done <<< "$servers"

    echo ""
    printf '  detail on one host:  pl host schedule <target> list\n'
    printf '  install/remove:      pl schedule host <target> install|remove ...\n'
    return 0
}

main() {
    # Cross-host subcommands are handled BEFORE getopt: they take `--kind=` and
    # `--schedule="..."` style arguments that the site-backup getopt spec would
    # reject.
    case "${1:-}" in
        host)  shift; cmd_schedule_host "$@"; exit $? ;;
        where) shift; cmd_schedule_where "$@"; exit $? ;;
    esac

    # Parse options
    local DEBUG=false
    local COMMAND=""
    local SITENAME=""
    local DB_SCHEDULE="$CRON_DB_DEFAULT"
    local FULL_SCHEDULE="$CRON_FULL_DEFAULT"
    local BUNDLE_SCHEDULE="$CRON_BUNDLE_DEFAULT"
    local SWEEP_SCHEDULE="$CRON_SWEEP_DEFAULT"
    local NO_DB=false
    local NO_FULL=false
    local NO_BUNDLE=false
    local GIT_FLAG=false
    local PUSH_ALL=false

    # Use getopt for option parsing
    local OPTIONS=hd
    local LONGOPTS=help,debug,db-schedule:,full-schedule:,bundle-schedule:,schedule:,no-db,no-full,no-bundle,git,push-all

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
            --db-schedule)
                DB_SCHEDULE="$2"
                shift 2
                ;;
            --full-schedule)
                FULL_SCHEDULE="$2"
                shift 2
                ;;
            --bundle-schedule)
                BUNDLE_SCHEDULE="$2"
                shift 2
                ;;
            --schedule)
                SWEEP_SCHEDULE="$2"
                shift 2
                ;;
            --no-db)
                NO_DB=true
                shift
                ;;
            --no-full)
                NO_FULL=true
                shift
                ;;
            --no-bundle)
                NO_BUNDLE=true
                shift
                ;;
            --git)
                GIT_FLAG=true
                shift
                ;;
            --push-all)
                PUSH_ALL=true
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

    # Get command and sitename from remaining arguments
    if [ $# -ge 1 ]; then
        COMMAND="$1"
        shift
    else
        print_error "No command specified"
        echo ""
        show_help
        exit 1
    fi

    if [ $# -ge 1 ]; then
        SITENAME="$1"
        shift
    fi

    # Execute command
    case "$COMMAND" in
        install)
            if [ -z "$SITENAME" ]; then
                print_error "Sitename required for install"
                exit 1
            fi
            install_schedule "$SITENAME" "$DB_SCHEDULE" "$FULL_SCHEDULE" "$BUNDLE_SCHEDULE" \
                "$NO_DB" "$NO_FULL" "$NO_BUNDLE" "$GIT_FLAG" "$PUSH_ALL"
            ;;
        remove)
            if [ -z "$SITENAME" ]; then
                print_error "Sitename required for remove"
                exit 1
            fi
            remove_schedule "$SITENAME"
            ;;
        install-sweep)
            install_sweep_schedule "$SWEEP_SCHEDULE"
            ;;
        remove-sweep)
            remove_sweep_schedule
            ;;
        list)
            list_schedules
            ;;
        show)
            if [ -z "$SITENAME" ]; then
                print_error "Sitename required for show"
                exit 1
            fi
            show_schedule "$SITENAME"
            ;;
        run)
            if [ -z "$SITENAME" ]; then
                print_error "Sitename required for run"
                exit 1
            fi
            run_backup_now "$SITENAME" "$GIT_FLAG" "$PUSH_ALL"
            ;;
        *)
            print_error "Unknown command: $COMMAND"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

# Run main
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
