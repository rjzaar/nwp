#!/bin/bash
set -euo pipefail

################################################################################
# NWP Unified CLI Wrapper (pl)
#
# Single entry point for all NWP operations
#
# Usage: pl <command> [options] [arguments]
################################################################################

# Get script directory (resolve symlinks)
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
    DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"
    SOURCE="$(readlink "$SOURCE")"
    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"

# Version
VERSION="0.9.0"

################################################################################
# Color Definitions
################################################################################

if [[ -t 1 ]]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'
    BOLD=$'\033[1m'
    NC=$'\033[0m'
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
${BOLD}NWP CLI (pl) v${VERSION} - Unified Command Interface${NC}

${BOLD}USAGE:${NC}
    pl <command> [options] [arguments]

${BOLD}SITE MANAGEMENT:${NC}
    install <recipe> <sitename>     Install a new Drupal site
    delete <sitename>               Delete a site
    make <sitename>                 Switch dev/prod mode (-v dev, -p prod)
    uninstall                       Uninstall NWP completely

${BOLD}BACKUP & RESTORE:${NC}
    backup <sitename> [message]     Create backup (full site)
    backup -b <sitename>            Database-only backup
    backup -g <sitename>            Backup with git commit
    backup --bundle <sitename>      Create git bundle archive
    backup --sanitize <sitename>    Create sanitized backup (no PII)
    restore <sitename> [backup]     Restore from backup
    restore -b <sitename>           Restore database only
    copy <source> <dest>            Copy site to new location

${BOLD}DEPLOYMENT (Local):${NC}
    dev2stg <sitename>              Deploy dev to staging (local)

${BOLD}DEPLOYMENT (Remote):${NC}
    stg2prod <sitename>             Deploy staging to production
    prod2stg <sitename>             Pull production to staging
    stg2live <sitename>             Deploy staging to live server
    live2stg <sitename>             Pull live to staging
    live2prod <sitename>            Deploy live to production

${BOLD}PROVISIONING:${NC}
    live <sitename>                 Provision live test server
    live --type=shared <sitename>   Provision on shared GitLab server
    live --type=temporary <sitename> Temporary server (auto-delete)
    live --delete <sitename>        Delete live server
    live --status <sitename>        Show live server status

${BOLD}TESTING:${NC}
    test <sitename>                 Run all tests
    test -l <sitename>              Lint only (PHPCS, PHPStan)
    test -u <sitename>              Unit tests only
    test -k <sitename>              Kernel tests only
    test -f <sitename>              Functional tests only
    test -s <sitename>              Smoke tests only (Behat @smoke)
    test -b <sitename>              Full Behat tests
    test -p <sitename>              Parallel Behat tests
    testos <sitename>               Open Social specific tests
    test-nwp                        Run NWP infrastructure tests

${BOLD}SCHEDULING:${NC}
    schedule install <sitename>     Install backup schedule (cron)
    schedule remove <sitename>      Remove backup schedule
    schedule list                   List all scheduled backups
    schedule show                   Show cron entries
    schedule run <sitename>         Run scheduled backup now

${BOLD}SECURITY:${NC}
    security check <sitename>       Check for security updates
    security check --all            Check all sites
    security update <sitename>      Apply security updates
    security update --auto <site>   Auto-update with testing
    security audit <sitename>       Full security audit

${BOLD}GIT & GITLAB:${NC}
    gitlab-create <project> [group] Create GitLab project
    gitlab-list [group]             List GitLab projects

${BOLD}MIGRATION:${NC}
    migration <sitename>            Run migration tasks

${BOLD}SETUP & UTILITIES:${NC}
    setup                           Run setup wizard (18 components)
    setup-ssh                       Setup SSH keys for deployment
    list                            List all tracked sites
    status <sitename>               Show site status
    version                         Show NWP version

${BOLD}GLOBAL OPTIONS:${NC}
    -h, --help                      Show this help message
    -v, --version                   Show version
    -d, --debug                     Enable debug output
    -y, --yes                       Auto-confirm prompts

${BOLD}SCRIPT-SPECIFIC OPTIONS:${NC}
    backup:    -b (db-only), -g (git), --bundle, --sanitize, --push-all
    restore:   -b (db-only), -f (force), -o (overwrite)
    copy:      -f (files-only), -y (yes), -o (overwrite)
    delete:    -b (backup first), -k (keep backups), -y (yes)
    make:      -v (dev mode), -p (prod mode)
    test:      -l -u -k -f -s -b -p (see TESTING above)

${BOLD}EXAMPLES:${NC}
    pl install d mysite             Install Drupal site 'mysite'
    pl backup -g mysite "Update"    Backup with git commit
    pl backup --sanitize mysite     GDPR-safe backup (no PII)
    pl test -s mysite               Run smoke tests
    pl dev2stg mysite               Deploy to local staging
    pl stg2prod mysite              Deploy to production server
    pl live mysite                  Provision mysite.nwpcode.org
    pl schedule install mysite      Setup daily backups
    pl security check --all         Check all sites for updates

${BOLD}WORKFLOW:${NC}
    Development:  pl install d mysite
    Testing:      pl test -s mysite
    Staging:      pl dev2stg mysite
    Live Preview: pl live mysite && pl stg2live mysite
    Production:   pl stg2prod mysite

${BOLD}TAB COMPLETION:${NC}
    Add to ~/.bashrc:
    source ${SCRIPT_DIR}/pl-completion.bash

${BOLD}MORE HELP:${NC}
    pl <command> --help             Show help for specific command
    See docs/README.md for full documentation

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
    local site_dir="sites/$sitename"

    if [ -z "$sitename" ]; then
        print_error "Sitename required"
        return 1
    fi

    echo -e "${BOLD}Site Status: $sitename${NC}"
    echo ""

    # Check directory
    if [ -d "$site_dir" ]; then
        print_success "Directory exists: $site_dir"
    else
        print_error "Directory not found: $site_dir"
        return 1
    fi

    # Check DDEV
    if [ -f "$site_dir/.ddev/config.yaml" ]; then
        print_success "DDEV configured"
        local ddev_status=$(cd "$site_dir" && ddev describe 2>/dev/null | grep -E "^[a-z]+" | head -1 || echo "unknown")
        echo "    Status: $ddev_status"
    else
        echo -e "  ${YELLOW}!${NC} DDEV not configured"
    fi

    # Check git
    if [ -d "$site_dir/.git" ]; then
        print_success "Git repository"
        local branch=$(cd "$site_dir" && git branch --show-current 2>/dev/null || echo "unknown")
        local commit=$(cd "$site_dir" && git rev-parse --short HEAD 2>/dev/null || echo "unknown")
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
        uninstall)
            run_script "uninstall_nwp.sh" "$@"
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

        # Deployment (local)
        dev2stg)
            run_script "dev2stg.sh" "$@"
            ;;

        # Deployment (remote)
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
        testos)
            run_script "testos.sh" "$@"
            ;;
        test-nwp)
            run_script "test-nwp.sh" "$@"
            ;;

        # Scheduling
        schedule)
            run_script "schedule.sh" "$@"
            ;;

        # Security - handle both forms
        security)
            run_script "security.sh" "$@"
            ;;
        security-check)
            run_script "security.sh" "check" "$@"
            ;;
        security-update)
            run_script "security.sh" "update" "$@"
            ;;
        security-audit)
            run_script "security.sh" "audit" "$@"
            ;;

        # Migration
        migration)
            run_script "migration.sh" "$@"
            ;;

        # Git
        gitlab-create)
            cmd_gitlab_create "$@"
            ;;
        gitlab-list)
            cmd_gitlab_list "$@"
            ;;

        # Setup & utilities
        setup)
            run_script "setup.sh" "$@"
            ;;
        setup-ssh)
            run_script "setup-ssh.sh" "$@"
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

        # Unknown command - try as script name
        *)
            # Check if it's a script name (with or without .sh)
            if script_exists "${command}.sh"; then
                run_script "${command}.sh" "$@"
            elif script_exists "${command}"; then
                run_script "${command}" "$@"
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
