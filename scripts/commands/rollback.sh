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
    list [sitename]              List available rollback points
    execute <sitename> [env]     Rollback to last deployment
    verify <sitename>            Verify site after rollback
    cleanup [--keep=N]           Remove old rollback points (keep last N)

${BOLD}OPTIONS:${NC}
    --env <environment>          Environment (prod, stage, live)
    --keep <count>               Number of rollback points to keep (default: 5)

${BOLD}EXAMPLES:${NC}
    pl rollback list                     # Show all rollback points
    pl rollback list mysite              # Show rollback points for mysite
    pl rollback execute mysite prod      # Rollback mysite production
    pl rollback cleanup --keep=3         # Keep only last 3 rollback points

${BOLD}AUTOMATIC ROLLBACK:${NC}
    Rollback points are automatically created before each deployment.
    If a deployment fails, you'll be prompted to rollback.

EOF
}

cmd_list() {
    local sitename="${1:-}"
    rollback_list "$sitename"
}

cmd_execute() {
    local sitename="$1"
    local environment="${2:-prod}"

    if [ -z "$sitename" ]; then
        print_error "Sitename required"
        exit 1
    fi

    rollback_quick "$sitename" "$environment"
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
    -h|--help|help|"") show_help ;;
    *) print_error "Unknown command: $COMMAND"; show_help; exit 1 ;;
esac
