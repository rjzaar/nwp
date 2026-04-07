#!/bin/bash
set -euo pipefail

################################################################################
# NWP GitLab Badge Management
#
# Manages GitLab CI/CD badges for project READMEs
#
# Usage: pl badges <command> [options] <sitename>
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

# Source shared libraries
source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/badges.sh"

show_help() {
    cat << EOF
${BOLD}NWP Badge Management${NC}

${BOLD}USAGE:${NC}
    pl badges <command> [options] <sitename>

${BOLD}COMMANDS:${NC}
    show <sitename>              Show all badge URLs for a site
    markdown <sitename>          Generate markdown badge snippet
    add <sitename>               Add badges to site's README.md
    update <sitename>            Update existing badges in README
    coverage <sitename>          Check test coverage threshold

${BOLD}OPTIONS:${NC}
    --group <group>              GitLab group (default: sites)
    --branch <branch>            Git branch (default: main)
    --threshold <percent>        Coverage threshold (default: 80)

${BOLD}EXAMPLES:${NC}
    pl badges show mysite                    # Show badge URLs
    pl badges markdown mysite --branch=dev   # Markdown for dev branch
    pl badges add mysite                     # Add to README.md
    pl badges coverage mysite --threshold=90 # Check 90% coverage

EOF
}

cmd_show() {
    local sitename="$1"
    local group="${GROUP:-sites}"
    local branch="${BRANCH:-main}"

    generate_badge_urls "$sitename" "$group" "$branch"
}

cmd_markdown() {
    local sitename="$1"
    local group="${GROUP:-sites}"
    local branch="${BRANCH:-main}"

    generate_readme_badges "$sitename" "$group" "$branch"
}

cmd_add() {
    local sitename="$1"
    local group="${GROUP:-sites}"
    local readme="${PROJECT_ROOT}/sites/${sitename}/README.md"

    if [ ! -f "$readme" ]; then
        print_error "README.md not found: $readme"
        exit 1
    fi

    add_badges_to_readme "$readme" "$sitename" "$group"
}

cmd_update() {
    local sitename="$1"
    local group="${GROUP:-sites}"
    local branch="${BRANCH:-main}"
    local readme="${PROJECT_ROOT}/sites/${sitename}/README.md"

    if [ ! -f "$readme" ]; then
        print_error "README.md not found: $readme"
        exit 1
    fi

    update_readme_badges "$readme" "$sitename" "$group" "$branch"
}

cmd_coverage() {
    local sitename="$1"
    local threshold="${THRESHOLD:-80}"
    local coverage_file="${PROJECT_ROOT}/sites/${sitename}/coverage.xml"

    if [ ! -f "$coverage_file" ]; then
        # Try alternate locations
        coverage_file="${PROJECT_ROOT}/sites/${sitename}/build/coverage.xml"
    fi

    check_coverage_threshold "$threshold" "$coverage_file"
}

# Parse options
GROUP=""
BRANCH=""
THRESHOLD=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --group=*) GROUP="${1#*=}"; shift ;;
        --group) GROUP="$2"; shift 2 ;;
        --branch=*) BRANCH="${1#*=}"; shift ;;
        --branch) BRANCH="$2"; shift 2 ;;
        --threshold=*) THRESHOLD="${1#*=}"; shift ;;
        --threshold) THRESHOLD="$2"; shift 2 ;;
        -h|--help) show_help; exit 0 ;;
        *) break ;;
    esac
done

COMMAND="${1:-}"
SITENAME="${2:-}"

case "$COMMAND" in
    show) cmd_show "$SITENAME" ;;
    markdown) cmd_markdown "$SITENAME" ;;
    add) cmd_add "$SITENAME" ;;
    update) cmd_update "$SITENAME" ;;
    coverage) cmd_coverage "$SITENAME" ;;
    -h|--help|help|"") show_help ;;
    *) print_error "Unknown command: $COMMAND"; show_help; exit 1 ;;
esac
