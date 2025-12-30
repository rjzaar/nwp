#!/bin/bash
set -euo pipefail

################################################################################
# NWP Unified CLI Wrapper (pl)
#
# Single entry point for all NWP operations
#
# Usage: pl <command> [options] [arguments]
################################################################################

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Version
VERSION="0.8.2"

################################################################################
# Color Definitions
################################################################################

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    BOLD=''
    NC=''
fi

################################################################################
# Help
################################################################################

show_help() {
    cat << EOF
${BOLD}NWP CLI (pl) - Unified Command Interface${NC}

${BOLD}USAGE:${NC}
    pl <command> [options] [arguments]

${BOLD}SITE MANAGEMENT:${NC}
    install <recipe> <sitename>     Install a new Drupal site
    delete <sitename>               Delete a site
    make <sitename>                 Switch dev/prod mode

${BOLD}BACKUP & RESTORE:${NC}
    backup <sitename> [message]     Backup a site
    restore <sitename> [backup]     Restore a site
    copy <source> <dest>            Copy site to new location

${BOLD}DEPLOYMENT:${NC}
    dev2stg <sitename>              Deploy dev to staging
    stg2prod <sitename>             Deploy staging to production
    prod2stg <sitename>             Pull production to staging
    stg2live <sitename>             Deploy staging to live
    live2stg <sitename>             Pull live to staging
    live2prod <sitename>            Deploy live to production

${BOLD}PROVISIONING:${NC}
    live <sitename>                 Provision live server
    produce <sitename>              Provision production server

${BOLD}TESTING:${NC}
    test <sitename>                 Run all tests
    test -l <sitename>              Run linting only
    test -u <sitename>              Run unit tests only
    test -s <sitename>              Run smoke tests only

${BOLD}SCHEDULING:${NC}
    schedule install <sitename>    Install backup schedule
    schedule remove <sitename>     Remove backup schedule
    schedule list                  List all schedules

${BOLD}SECURITY:${NC}
    security-check <sitename>      Check for security updates
    security-update <sitename>     Apply security updates

${BOLD}GIT:${NC}
    gitlab-create <project> [group]   Create GitLab project
    gitlab-list [group]               List GitLab projects

${BOLD}UTILITIES:${NC}
    setup                          Run setup wizard
    list                           List all sites
    status <sitename>              Show site status
    version                        Show version

${BOLD}OPTIONS:${NC}
    -h, --help                     Show this help message
    -v, --version                  Show version
    -d, --debug                    Enable debug output
    -y, --yes                      Auto-confirm prompts

${BOLD}EXAMPLES:${NC}
    pl install d mysite            Install Drupal site 'mysite'
    pl backup mysite "Before update"   Backup with message
    pl test -s mysite              Run smoke tests
    pl dev2stg mysite              Deploy to staging
    pl schedule install mysite     Setup scheduled backups

${BOLD}TAB COMPLETION:${NC}
    Add to ~/.bashrc:
    source ${SCRIPT_DIR}/pl-completion.bash

EOF
}

################################################################################
# Utility Functions
################################################################################

print_error() {
    echo -e "${RED}ERROR:${NC} $1" >&2
}

print_info() {
    echo -e "${BLUE}INFO:${NC} $1"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

# Check if a script exists
script_exists() {
    local script="$1"
    [ -f "${SCRIPT_DIR}/${script}" ] && [ -x "${SCRIPT_DIR}/${script}" ]
}

# Run a script with arguments
run_script() {
    local script="$1"
    shift

    if ! script_exists "$script"; then
        print_error "Script not found: $script"
        return 1
    fi

    "${SCRIPT_DIR}/${script}" "$@"
}

################################################################################
# Command Handlers
################################################################################

# List all tracked sites
cmd_list() {
    local cnwp_file="${SCRIPT_DIR}/cnwp.yml"

    if [ ! -f "$cnwp_file" ]; then
        print_error "cnwp.yml not found"
        return 1
    fi

    echo -e "${BOLD}Tracked Sites:${NC}"
    echo ""

    awk '
        /^sites:/ { in_sites = 1; next }
        in_sites && /^[a-zA-Z]/ && !/^  / { in_sites = 0 }
        in_sites && /^  [a-zA-Z_-]+:/ {
            name = $0
            gsub(/^  /, "", name)
            gsub(/:.*/, "", name)
            printf "  %s\n", name
        }
    ' "$cnwp_file"
}

# Show site status
cmd_status() {
    local sitename="$1"

    if [ -z "$sitename" ]; then
        print_error "Sitename required"
        return 1
    fi

    echo -e "${BOLD}Site Status: $sitename${NC}"
    echo ""

    # Check directory
    if [ -d "$sitename" ]; then
        print_success "Directory exists: $sitename"
    else
        print_error "Directory not found: $sitename"
        return 1
    fi

    # Check DDEV
    if [ -f "$sitename/.ddev/config.yaml" ]; then
        print_success "DDEV configured"
        local ddev_status=$(cd "$sitename" && ddev describe 2>/dev/null | grep -E "^[a-z]+" | head -1 || echo "unknown")
        echo "    Status: $ddev_status"
    else
        echo -e "  ${YELLOW}!${NC} DDEV not configured"
    fi

    # Check git
    if [ -d "$sitename/.git" ]; then
        print_success "Git repository"
        local branch=$(cd "$sitename" && git branch --show-current 2>/dev/null || echo "unknown")
        local commit=$(cd "$sitename" && git rev-parse --short HEAD 2>/dev/null || echo "unknown")
        echo "    Branch: $branch"
        echo "    Commit: $commit"
    else
        echo -e "  ${YELLOW}!${NC} Not a git repository"
    fi

    # Check cnwp.yml registration
    if grep -q "^  ${sitename}:" "${SCRIPT_DIR}/cnwp.yml" 2>/dev/null; then
        print_success "Registered in cnwp.yml"
    else
        echo -e "  ${YELLOW}!${NC} Not registered in cnwp.yml"
    fi
}

# GitLab create project
cmd_gitlab_create() {
    source "${SCRIPT_DIR}/lib/ui.sh"
    source "${SCRIPT_DIR}/lib/common.sh"
    source "${SCRIPT_DIR}/lib/git.sh"

    local project="$1"
    local group="${2:-sites}"

    if [ -z "$project" ]; then
        print_error "Project name required"
        return 1
    fi

    gitlab_api_create_project "$project" "$group"
}

# GitLab list projects
cmd_gitlab_list() {
    source "${SCRIPT_DIR}/lib/ui.sh"
    source "${SCRIPT_DIR}/lib/common.sh"
    source "${SCRIPT_DIR}/lib/git.sh"

    local group="${1:-sites}"

    gitlab_api_list_projects "$group"
}

################################################################################
# Main
################################################################################

main() {
    # Handle no arguments
    if [ $# -eq 0 ]; then
        show_help
        exit 0
    fi

    # Parse global options
    local DEBUG=false
    local YES=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -v|--version)
                echo "NWP CLI (pl) version $VERSION"
                exit 0
                ;;
            -d|--debug)
                DEBUG=true
                export DEBUG
                shift
                ;;
            -y|--yes)
                YES=true
                shift
                ;;
            *)
                break
                ;;
        esac
    done

    # Get command
    local command="${1:-}"
    shift || true

    # Route to appropriate handler
    case "$command" in
        # Site management
        install)
            run_script "install.sh" "$@"
            ;;
        delete)
            run_script "delete.sh" "$@"
            ;;
        make)
            run_script "make.sh" "$@"
            ;;

        # Backup & restore
        backup)
            run_script "backup.sh" "$@"
            ;;
        restore)
            run_script "restore.sh" "$@"
            ;;
        copy)
            run_script "copy.sh" "$@"
            ;;

        # Deployment
        dev2stg)
            run_script "dev2stg.sh" "$@"
            ;;
        stg2prod)
            run_script "stg2prod.sh" "$@"
            ;;
        prod2stg)
            run_script "prod2stg.sh" "$@"
            ;;
        stg2live)
            run_script "stg2live.sh" "$@"
            ;;
        live2stg)
            run_script "live2stg.sh" "$@"
            ;;
        live2prod)
            run_script "live2prod.sh" "$@"
            ;;

        # Provisioning
        live)
            run_script "live.sh" "$@"
            ;;
        produce)
            run_script "produce.sh" "$@"
            ;;

        # Testing
        test)
            run_script "test.sh" "$@"
            ;;

        # Scheduling
        schedule)
            run_script "schedule.sh" "$@"
            ;;

        # Security
        security-check|security-update)
            run_script "security.sh" "$command" "$@"
            ;;

        # Git
        gitlab-create)
            cmd_gitlab_create "$@"
            ;;
        gitlab-list)
            cmd_gitlab_list "$@"
            ;;

        # Utilities
        setup)
            run_script "setup.sh" "$@"
            ;;
        list)
            cmd_list "$@"
            ;;
        status)
            cmd_status "$@"
            ;;
        version)
            echo "NWP CLI (pl) version $VERSION"
            ;;

        # Help
        help)
            show_help
            ;;

        # Unknown command
        *)
            # Check if it's a script name
            if script_exists "${command}.sh"; then
                run_script "${command}.sh" "$@"
            else
                print_error "Unknown command: $command"
                echo ""
                echo "Run 'pl --help' for usage information."
                exit 1
            fi
            ;;
    esac
}

# Run main
main "$@"
