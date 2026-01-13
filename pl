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
VERSION="0.20.0"

################################################################################
# Color Definitions
################################################################################

if [[ -t 1 ]]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'
    CYAN=$'\033[0;36m'
    BOLD=$'\033[1m'
    NC=$'\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
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

${BOLD}THEMING:${NC}
    theme setup <sitename>          Install theme Node.js dependencies
    theme watch <sitename>          Start dev mode with live reload
    theme build <sitename>          Production build (minified)
    theme lint <sitename>           Run ESLint/Stylelint
    theme info <sitename>           Show theme build tool info

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
    security-check <url>            Check HTTP security headers on URL
    headers <url>                   Alias for security-check (headers check)

${BOLD}GIT & GITLAB:${NC}
    gitlab-create <project> [group] Create GitLab project
    gitlab-list [group]             List GitLab projects

${BOLD}IMPORT & SYNC:${NC}
    import <server>                 Import sites from remote server
    sync <sitename>                 Sync database/files from source
    modify <sitename>               Modify site options interactively

${BOLD}MIGRATION:${NC}
    migration <sitename>            Run migration tasks

${BOLD}PODCASTING:${NC}
    podcast <sitename>              Setup Castopod podcast infrastructure

${BOLD}EMAIL:${NC}
    email setup                     Setup email infrastructure
    email add <sitename>            Add email account for site
    email test <sitename>           Test email deliverability
    email reroute <sitename>        Route email to Mailpit (dev)

${BOLD}CI/CD:${NC}
    badges show <sitename>          Show GitLab badge URLs
    badges add <sitename>           Add badges to README.md
    badges coverage <sitename>      Check test coverage threshold

${BOLD}CLOUD STORAGE:${NC}
    storage auth                    Authenticate with Backblaze B2
    storage list                    List B2 buckets
    storage upload <file> <bucket>  Upload file to B2
    storage files <bucket>          List files in bucket

${BOLD}ROLLBACK:${NC}
    rollback list [sitename]        List available rollback points
    rollback execute <sitename>     Rollback to pre-deployment state
    rollback cleanup                Remove old rollback points

${BOLD}DEVELOPER TOOLS:${NC}
    coder add <name>                Add developer coder environment
    coder list                      List configured coders
    verify <sitename>               Verify site features and changes
    report                          Generate bug report

${BOLD}SETUP & UTILITIES:${NC}
    setup                           Run setup wizard (18 components)
    setup-ssh                       Setup SSH keys for deployment
    list                            List all tracked sites
    status [options] [sitename]     Show site status (-f for fast text)
    version                         Show NWP version

${BOLD}MAINTENANCE:${NC}
    migrate-secrets                 Migrate secrets to new format

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

# Check if a script exists (checks root and scripts/commands/)
script_exists() {
    local script="$1"
    if [ -f "${SCRIPT_DIR}/${script}" ] && [ -x "${SCRIPT_DIR}/${script}" ]; then
        return 0
    elif [ -f "${SCRIPT_DIR}/scripts/commands/${script}" ] && [ -x "${SCRIPT_DIR}/scripts/commands/${script}" ]; then
        return 0
    fi
    return 1
}

# Get the full path to a script
get_script_path() {
    local script="$1"
    if [ -f "${SCRIPT_DIR}/${script}" ] && [ -x "${SCRIPT_DIR}/${script}" ]; then
        echo "${SCRIPT_DIR}/${script}"
    elif [ -f "${SCRIPT_DIR}/scripts/commands/${script}" ] && [ -x "${SCRIPT_DIR}/scripts/commands/${script}" ]; then
        echo "${SCRIPT_DIR}/scripts/commands/${script}"
    fi
}

# Run a script with arguments
run_script() {
    local script="$1"
    shift

    local script_path=$(get_script_path "$script")
    if [ -z "$script_path" ]; then
        print_error "Script not found: $script"
        return 1
    fi

    "$script_path" "$@"
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
        in_sites && /^  [a-zA-Z0-9_-]+:/ {
            name = $0
            gsub(/^  /, "", name)
            gsub(/:.*/, "", name)
            printf "  %s\n", name
        }
    ' "$cnwp_file"
}

# Get a field from a site in cnwp.yml
get_site_field() {
    local site="$1"
    local field="$2"
    local config_file="${SCRIPT_DIR}/cnwp.yml"

    awk -v site="$site" -v field="$field" '
        /^sites:/ { in_sites = 1; next }
        in_sites && /^[a-zA-Z]/ && !/^  / { exit }
        in_sites && $0 ~ "^  " site ":" { in_site = 1; next }
        in_site && /^  [a-zA-Z]/ && !/^    / { exit }
        in_site && $0 ~ "^    " field ":" {
            sub("^    " field ": *", "")
            gsub(/["'"'"']/, "")
            sub(/ *#.*$/, "")
            gsub(/^[ \t]+|[ \t]+$/, "")
            print
            exit
        }
    ' "$config_file"
}

# Get a nested field (e.g., live.domain) from a site in cnwp.yml
get_site_nested_field() {
    local site="$1"
    local section="$2"
    local field="$3"
    local config_file="${SCRIPT_DIR}/cnwp.yml"

    awk -v site="$site" -v section="$section" -v field="$field" '
        /^sites:/ { in_sites = 1; next }
        in_sites && /^[a-zA-Z]/ && !/^  / { exit }
        in_sites && $0 ~ "^  " site ":" { in_site = 1; next }
        in_site && /^  [a-zA-Z]/ && !/^    / { exit }
        in_site && $0 ~ "^    " section ":" { in_section = 1; next }
        in_section && /^    [a-zA-Z]/ && !/^      / { in_section = 0 }
        in_section && $0 ~ "^      " field ":" {
            sub("^      " field ": *", "")
            gsub(/["'"'"']/, "")
            sub(/ *#.*$/, "")
            gsub(/^[ \t]+|[ \t]+$/, "")
            print
            exit
        }
    ' "$config_file"
}

# Show status for a single site
show_site_status() {
    local sitename="$1"
    local site_dir="sites/$sitename"
    local cnwp_file="${SCRIPT_DIR}/cnwp.yml"
    local ddev_running=false

    echo -e "${BOLD}$sitename${NC}"

    # Get config details
    local recipe=$(get_site_field "$sitename" "recipe")
    local purpose=$(get_site_field "$sitename" "purpose")
    local domain=$(get_site_nested_field "$sitename" "live" "domain")

    # Show recipe and purpose if available
    if [ -n "$recipe" ] || [ -n "$purpose" ]; then
        local info=""
        [ -n "$recipe" ] && info="$recipe"
        [ -n "$purpose" ] && info="${info:+$info, }$purpose"
        echo -e "  ${CYAN}ℹ${NC} Config: $info"
    fi

    # Check directory
    if [ ! -d "$site_dir" ]; then
        echo -e "  ${YELLOW}○${NC} Local: not present (remote only?)"
        echo ""
        return 0
    fi

    # Check DDEV
    if [ -f "$site_dir/.ddev/config.yaml" ]; then
        local ddev_status=$(cd "$site_dir" && ddev describe -j 2>/dev/null | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "unknown")
        if [ "$ddev_status" = "running" ]; then
            echo -e "  ${GREEN}●${NC} DDEV: running"
            ddev_running=true
        elif [ "$ddev_status" = "stopped" ]; then
            echo -e "  ${RED}●${NC} DDEV: stopped"
        else
            echo -e "  ${YELLOW}●${NC} DDEV: $ddev_status"
        fi
    else
        echo -e "  ${YELLOW}○${NC} DDEV: not configured"
    fi

    # Show URL if DDEV running
    if [ "$ddev_running" = true ]; then
        echo -e "  ${CYAN}→${NC} URL: https://${sitename}.ddev.site"
    fi

    # Check git
    if [ -d "$site_dir/.git" ]; then
        local branch=$(cd "$site_dir" && git branch --show-current 2>/dev/null || echo "unknown")
        local last_commit=$(cd "$site_dir" && git log -1 --format="%ar" 2>/dev/null || echo "")
        if [ -n "$last_commit" ]; then
            echo -e "  ${GREEN}●${NC} Git: $branch (${last_commit})"
        else
            echo -e "  ${GREEN}●${NC} Git: $branch"
        fi
    else
        echo -e "  ${YELLOW}○${NC} Git: not initialized"
    fi

    # Check cnwp.yml registration
    if grep -q "^  ${sitename}:" "$cnwp_file" 2>/dev/null; then
        echo -e "  ${GREEN}●${NC} Registered"
    else
        echo -e "  ${YELLOW}○${NC} Not registered"
    fi

    # Disk usage
    local disk_usage=$(du -sh "$site_dir" 2>/dev/null | awk '{print $1}')
    if [ -n "$disk_usage" ]; then
        echo -e "  ${CYAN}◆${NC} Disk: $disk_usage"
    fi

    # Database size (only if DDEV running)
    if [ "$ddev_running" = true ]; then
        local db_size=$(cd "$site_dir" && ddev mysql -N -e "SELECT ROUND(SUM(data_length + index_length) / 1024 / 1024, 1) FROM information_schema.tables WHERE table_schema = DATABASE();" 2>/dev/null | tail -1)
        if [ -n "$db_size" ] && [ "$db_size" != "NULL" ]; then
            echo -e "  ${CYAN}◆${NC} Database: ${db_size}MB"
        fi

        # Health check
        local http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "https://${sitename}.ddev.site" 2>/dev/null || echo "000")
        case "$http_code" in
            200|301|302|303) echo -e "  ${GREEN}●${NC} Health: OK (HTTP $http_code)" ;;
            401|403) echo -e "  ${YELLOW}●${NC} Health: auth required (HTTP $http_code)" ;;
            404) echo -e "  ${YELLOW}●${NC} Health: not found (HTTP 404)" ;;
            500|502|503) echo -e "  ${RED}●${NC} Health: error (HTTP $http_code)" ;;
            000) echo -e "  ${RED}●${NC} Health: unreachable" ;;
            *) echo -e "  ${YELLOW}●${NC} Health: HTTP $http_code" ;;
        esac
    fi

    # Live domain
    if [ -n "$domain" ]; then
        echo -e "  ${BLUE}◆${NC} Domain: $domain"
    fi

    echo ""
}

# Show site status (all sites or specific site)
cmd_status() {
    local sitename="${1:-}"

    # If first arg is a flag, pass all args to status.sh
    if [[ "$sitename" == -* ]]; then
        exec "${SCRIPT_DIR}/scripts/commands/status.sh" "$@"
    elif [ -z "$sitename" ]; then
        # Launch interactive TUI for overview
        exec "${SCRIPT_DIR}/scripts/commands/status.sh"
    else
        # Show detailed single site view
        echo -e "${BOLD}Site Status:${NC}"
        echo ""
        show_site_status "$sitename"
    fi
}

# GitLab create project
cmd_gitlab_create() {
    source "${SCRIPT_DIR}/lib/ui.sh"
    source "${SCRIPT_DIR}/lib/common.sh"
    source "${SCRIPT_DIR}/lib/git.sh"

    local project="${1:-}"
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

        # Theming
        theme)
            run_script "theme.sh" "$@"
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
            # Check if argument looks like a URL (HTTP security headers check)
            if [[ "${1:-}" =~ ^https?:// ]] || [[ "${1:-}" =~ \. ]]; then
                run_script "security-check.sh" "$@"
            else
                run_script "security.sh" "check" "$@"
            fi
            ;;
        security-update)
            run_script "security.sh" "update" "$@"
            ;;
        security-audit)
            run_script "security.sh" "audit" "$@"
            ;;
        headers)
            # HTTP security headers check (alias for security-check <url>)
            run_script "security-check.sh" "$@"
            ;;

        # Import & Sync
        import)
            run_script "import.sh" "$@"
            ;;
        sync)
            run_script "sync.sh" "$@"
            ;;
        modify)
            run_script "modify.sh" "$@"
            ;;

        # Migration
        migration)
            run_script "migration.sh" "$@"
            ;;

        # Podcasting
        podcast)
            run_script "podcast.sh" "$@"
            ;;

        # Email
        email)
            run_script "email.sh" "$@"
            ;;

        # CI/CD
        badges)
            run_script "badges.sh" "$@"
            ;;

        # Cloud Storage
        storage)
            run_script "storage.sh" "$@"
            ;;

        # Rollback
        rollback)
            run_script "rollback.sh" "$@"
            ;;

        # Developer tools
        coder)
            run_script "coder-setup.sh" "$@"
            ;;
        verify)
            run_script "verify.sh" "$@"
            ;;
        report)
            run_script "report.sh" "$@"
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

        # Maintenance
        migrate-secrets)
            run_script "migrate-secrets.sh" "$@"
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
