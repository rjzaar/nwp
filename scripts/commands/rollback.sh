#!/bin/bash
set -euo pipefail

################################################################################
# NWP Deployment Rollback
#
# Manages deployment rollback points and recovery
#
# Usage: pl rollback <command> [options] <sitename>
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

# Source shared libraries
source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/rollback.sh"

show_help() {
    cat << EOF
${BOLD}NWP Deployment Rollback${NC}

${BOLD}USAGE:${NC}
    pl rollback <command> [options] <sitename>

${BOLD}COMMANDS:${NC}
    list [sitename]                          List available rollback points
    execute <sitename> [env] [--dry-run]     Rollback to last deployment
                                             (env defaults to prod; --dry-run
                                              prints what would happen)
    verify <sitename>                        Verify site after rollback
    cleanup [--keep=N]                       Remove old rollback points
    backfill <sitename>                      Scan the live host for existing
                                             snapshots and register them

${BOLD}OPTIONS:${NC}
    --env <environment>          Environment (prod, stage, live)
    --keep <count>               Number of rollback points to keep (default: 5)
    --dry-run                    Print commands without executing them

${BOLD}EXAMPLES:${NC}
    pl rollback list                          # Show all rollback points
    pl rollback list mysite                   # Show rollback points for mysite
    pl rollback execute mysite prod --dry-run # Preview what a rollback would do
    pl rollback execute mysite prod           # Rollback mysite production (prompts)
    pl rollback backfill nwc                  # Register snapshots already on live
    pl rollback cleanup --keep=3              # Keep only last 3 rollback points

${BOLD}AUTOMATIC ROLLBACK:${NC}
    Rollback points are automatically created before each deployment by
    pl stg2live (via live_host_snapshot → rollback_record_remote). Remote
    points point at \`~/nwp-snapshot-<site>-<dbs|nginx>-<ts>\` on the live
    host. Local points (legacy) reference paths inside this checkout.

EOF
}

cmd_list() {
    local sitename="${1:-}"
    rollback_list "$sitename"
}

cmd_execute() {
    local sitename="$1"
    local environment="${2:-prod}"
    local extra="${3:-}"

    # Accept "pl rollback execute nwc --dry-run" (env defaulted).
    if [ "$environment" = "--dry-run" ]; then
        extra="--dry-run"; environment="prod"
    fi

    if [ -z "$sitename" ]; then
        print_error "Sitename required"
        exit 1
    fi

    # Dry-run delegates straight to rollback_execute (skips verify step).
    if [ "$extra" = "--dry-run" ]; then
        rollback_execute "$sitename" "$environment" "--dry-run"
    else
        rollback_quick "$sitename" "$environment"
    fi
}

cmd_backfill() {
    local sitename="$1"

    if [ -z "$sitename" ]; then
        print_error "Sitename required"
        exit 1
    fi

    rollback_backfill_remote "$sitename"
}

cmd_verify() {
    local sitename="$1"

    if [ -z "$sitename" ]; then
        print_error "Sitename required"
        exit 1
    fi

    rollback_verify "$sitename"
}

cmd_cleanup() {
    local keep="${KEEP:-5}"

    print_info "Cleaning up old rollback points (keeping last $keep)..."
    rollback_cleanup "$keep"
    print_status "OK" "Cleanup complete"
}

# Parse options
KEEP=""
ENV=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --keep=*) KEEP="${1#*=}"; shift ;;
        --keep) KEEP="$2"; shift 2 ;;
        --env=*) ENV="${1#*=}"; shift ;;
        --env) ENV="$2"; shift 2 ;;
        -h|--help) show_help; exit 0 ;;
        *) break ;;
    esac
done

COMMAND="${1:-}"
shift || true

case "$COMMAND" in
    list) cmd_list "$@" ;;
    execute) cmd_execute "$@" ;;
    verify) cmd_verify "$@" ;;
    cleanup) cmd_cleanup ;;
    backfill) cmd_backfill "$@" ;;
    -h|--help|help|"") show_help ;;
    *) print_error "Unknown command: $COMMAND"; show_help; exit 1 ;;
esac
