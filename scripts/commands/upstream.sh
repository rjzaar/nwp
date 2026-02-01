#!/bin/bash
set -euo pipefail

################################################################################
# NWP Upstream Sync Script
#
# Syncs local repository with upstream git repository in the distributed
# contribution governance model.
#
# Usage: ./upstream.sh <command> [options]
#
# Commands:
#   sync                Sync with upstream repository
#   status              Show upstream sync status
#   configure           Configure upstream repository
#   info                Show upstream configuration
#
# Options:
#   --pull              Pull changes from upstream (default)
#   --merge             Use merge strategy (default)
#   --rebase            Use rebase strategy
#   --dry-run           Show what would happen without making changes
#   --help, -h          Show this help
#
# Examples:
#   ./upstream.sh sync              # Sync with upstream (pull and merge)
#   ./upstream.sh sync --rebase     # Sync with rebase strategy
#   ./upstream.sh status            # Check upstream status
#   ./upstream.sh configure         # Set up upstream repository
#   ./upstream.sh info              # Show upstream configuration
#
# Configuration:
#   Upstream repository is configured in .nwp-upstream.yml
#
# See: docs/DISTRIBUTED_CONTRIBUTION_GOVERNANCE.md
################################################################################

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

################################################################################
# Source Required Libraries
################################################################################

source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh"

################################################################################
# Configuration
################################################################################

UPSTREAM_CONFIG="$PROJECT_ROOT/.nwp-upstream.yml"

# Default options
OPT_COMMAND=""
OPT_STRATEGY="merge"  # merge or rebase
OPT_DRY_RUN="n"
OPT_HELP="n"

################################################################################
# Argument Parsing
################################################################################

parse_arguments() {
    # First argument is the command
    if [[ $# -gt 0 ]] && [[ ! "$1" =~ ^- ]]; then
        OPT_COMMAND="$1"
        shift
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pull)
                # Default behavior, kept for clarity
                shift
                ;;
            --merge)
                OPT_STRATEGY="merge"
                shift
                ;;
            --rebase)
                OPT_STRATEGY="rebase"
                shift
                ;;
            --dry-run)
                OPT_DRY_RUN="y"
                shift
                ;;
            --help|-h)
                OPT_HELP="y"
                shift
                ;;
            -*)
                print_error "Unknown option: $1"
                exit 1
                ;;
            *)
                print_error "Unexpected argument: $1"
                exit 1
                ;;
        esac
    done
}

show_help() {
    head -38 "$0" | tail -33 | sed 's/^# //' | sed 's/^#//'
    exit 0
}

################################################################################
# Configuration Functions
################################################################################

# Check if upstream is configured
has_upstream_config() {
    [ -f "$UPSTREAM_CONFIG" ]
}

# Get upstream configuration
get_upstream_config() {
    if ! has_upstream_config; then
        return 1
    fi

    # Parse YAML (simple parsing for this structure)
    UPSTREAM_URL=$(grep "^[[:space:]]*url:" "$UPSTREAM_CONFIG" | head -1 | sed 's/.*url:[[:space:]]*//' | tr -d '"')
    UPSTREAM_TIER=$(grep "^[[:space:]]*tier:" "$UPSTREAM_CONFIG" | head -1 | sed 's/.*tier:[[:space:]]*//' | tr -d '"')
    UPSTREAM_MAINTAINER=$(grep "^[[:space:]]*maintainer:" "$UPSTREAM_CONFIG" | head -1 | sed 's/.*maintainer:[[:space:]]*//' | tr -d '"')
    AUTO_PULL=$(grep "^[[:space:]]*auto_pull:" "$UPSTREAM_CONFIG" | head -1 | sed 's/.*auto_pull:[[:space:]]*//' | tr -d '"')
    AUTO_PUSH=$(grep "^[[:space:]]*auto_push:" "$UPSTREAM_CONFIG" | head -1 | sed 's/.*auto_push:[[:space:]]*//' | tr -d '"')

    if [ -z "$UPSTREAM_URL" ]; then
        return 1
    fi

    return 0
}

################################################################################
# Command: Configure
################################################################################

cmd_configure() {
    print_header "Configure Upstream Repository"
    echo ""

    # Check if already configured
    if has_upstream_config; then
        print_warning "Upstream already configured: $UPSTREAM_CONFIG"
        echo ""
        if ! ask_yes_no "Reconfigure?" "n"; then
            exit 0
        fi
        echo ""
    fi

    # Prompt for configuration
    print_info "Enter upstream repository details:"
    echo ""

    read -p "Upstream URL: " url
    if [ -z "$url" ]; then
        print_error "URL is required"
        exit 1
    fi

    read -p "Upstream tier (0-2): " tier
    if [ -z "$tier" ]; then
        tier="1"
    fi

    read -p "Maintainer email: " maintainer
    if [ -z "$maintainer" ]; then
        maintainer="unknown"
    fi

    read -p "Auto pull frequency (never/daily/weekly) [daily]: " auto_pull
    if [ -z "$auto_pull" ]; then
        auto_pull="daily"
    fi

    read -p "Auto push (auto/manual) [manual]: " auto_push
    if [ -z "$auto_push" ]; then
        auto_push="manual"
    fi

    # Create configuration file
    cat > "$UPSTREAM_CONFIG" <<EOF
# NWP Upstream Configuration
# This file configures the upstream repository for distributed development
# See: docs/DISTRIBUTED_CONTRIBUTION_GOVERNANCE.md

upstream:
  url: $url
  tier: $tier
  maintainer: $maintainer

sync:
  auto_pull: $auto_pull
  auto_push: $auto_push

# Optional: downstream repositories (Tier 1/2 maintainers only)
downstream: []
EOF

    print_status "OK" "Configuration saved to $UPSTREAM_CONFIG"
    echo ""

    # Add git remote
    if ! git remote get-url upstream >/dev/null 2>&1; then
        print_info "Adding git remote 'upstream'..."
        if git remote add upstream "$url" 2>/dev/null; then
            print_status "OK" "Remote added"
        else
            print_error "Failed to add git remote"
            exit 1
        fi
    else
        print_info "Updating git remote 'upstream'..."
        if git remote set-url upstream "$url" 2>/dev/null; then
            print_status "OK" "Remote updated"
        else
            print_error "Failed to update git remote"
            exit 1
        fi
    fi

    echo ""
    print_info "Fetching from upstream..."
    if git fetch upstream 2>&1 | grep -v "^From"; then
        print_status "OK" "Fetched successfully"
    else
        print_warning "Fetch had issues (non-fatal)"
    fi

    echo ""
    print_status "OK" "Upstream configured successfully"
    echo ""
    echo "Next steps:"
    echo "  pl upstream sync    # Sync with upstream"
    echo "  pl upstream status  # Check sync status"
}

################################################################################
# Command: Info
################################################################################

cmd_info() {
    print_header "Upstream Configuration"
    echo ""

    if ! has_upstream_config; then
        print_warning "Upstream not configured"
        echo ""
        echo "To configure upstream:"
        echo "  pl upstream configure"
        exit 0
    fi

    if ! get_upstream_config; then
        print_error "Invalid upstream configuration"
        exit 1
    fi

    print_info "Configuration file: $UPSTREAM_CONFIG"
    echo ""
    echo "Upstream Repository:"
    echo "  URL:        $UPSTREAM_URL"
    echo "  Tier:       $UPSTREAM_TIER"
    echo "  Maintainer: $UPSTREAM_MAINTAINER"
    echo ""
    echo "Sync Settings:"
    echo "  Auto Pull:  $AUTO_PULL"
    echo "  Auto Push:  $AUTO_PUSH"
    echo ""

    # Check git remote
    if git remote get-url upstream >/dev/null 2>&1; then
        local remote_url=$(git remote get-url upstream)
        if [ "$remote_url" = "$UPSTREAM_URL" ]; then
            print_status "OK" "Git remote 'upstream' configured correctly"
        else
            print_warning "Git remote 'upstream' URL mismatch:"
            echo "  Config:  $UPSTREAM_URL"
            echo "  Git:     $remote_url"
        fi
    else
        print_warning "Git remote 'upstream' not configured"
        echo ""
        echo "To add remote:"
        echo "  git remote add upstream $UPSTREAM_URL"
    fi
}

################################################################################
# Command: Status
################################################################################

cmd_status() {
    print_header "Upstream Sync Status"
    echo ""

    # Check if we're in a git repository
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        print_error "Not a git repository"
        exit 1
    fi

    # Check if upstream is configured
    if ! git remote get-url upstream >/dev/null 2>&1; then
        print_warning "Upstream remote not configured"
        echo ""
        echo "To configure upstream:"
        echo "  pl upstream configure"
        exit 0
    fi

    # Fetch from upstream (quietly)
    print_info "Fetching from upstream..."
    if ! git fetch upstream >/dev/null 2>&1; then
        print_error "Failed to fetch from upstream"
        exit 1
    fi
    print_status "OK" "Fetched"
    echo ""

    # Get current branch
    local current_branch=$(git rev-parse --abbrev-ref HEAD)
    local upstream_branch="upstream/main"

    # Check if upstream/main exists, fallback to master
    if ! git rev-parse --verify upstream/main >/dev/null 2>&1; then
        if git rev-parse --verify upstream/master >/dev/null 2>&1; then
            upstream_branch="upstream/master"
        else
            print_error "Upstream main/master branch not found"
            exit 1
        fi
    fi

    echo "Current branch: $current_branch"
    echo "Upstream branch: $upstream_branch"
    echo ""

    # Check if we're behind/ahead
    local behind=$(git rev-list --count HEAD..$upstream_branch 2>/dev/null || echo "0")
    local ahead=$(git rev-list --count $upstream_branch..HEAD 2>/dev/null || echo "0")

    if [ "$behind" -eq 0 ] && [ "$ahead" -eq 0 ]; then
        print_status "OK" "Up to date with upstream"
    else
        if [ "$behind" -gt 0 ]; then
            print_warning "Behind upstream by $behind commit(s)"
            echo ""
            echo "Recent upstream commits:"
            git log --oneline HEAD..$upstream_branch | head -5
            echo ""
            echo "To sync:"
            echo "  pl upstream sync"
        fi

        if [ "$ahead" -gt 0 ]; then
            echo ""
            print_info "Ahead of upstream by $ahead commit(s)"
            echo ""
            echo "Recent local commits:"
            git log --oneline $upstream_branch..HEAD | head -5
            echo ""
            echo "To contribute changes:"
            echo "  pl contribute"
        fi
    fi

    echo ""

    # Show last sync time if available
    if has_upstream_config; then
        local last_sync=$(grep "^[[:space:]]*last_sync:" "$UPSTREAM_CONFIG" 2>/dev/null | sed 's/.*last_sync:[[:space:]]*//' | tr -d '"')
        if [ -n "$last_sync" ]; then
            echo "Last sync: $last_sync"
        fi
    fi
}

################################################################################
# Command: Sync
################################################################################

cmd_sync() {
    print_header "Sync with Upstream"
    echo ""

    # Check if we're in a git repository
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        print_error "Not a git repository"
        exit 1
    fi

    # Check for uncommitted changes
    if ! git diff-index --quiet HEAD -- 2>/dev/null; then
        print_warning "You have uncommitted changes"
        echo ""
        git status --short
        echo ""
        if ! ask_yes_no "Continue anyway?" "n"; then
            exit 0
        fi
        echo ""
    fi

    # Check if upstream is configured
    if ! git remote get-url upstream >/dev/null 2>&1; then
        print_error "Upstream remote not configured"
        echo ""
        echo "To configure upstream:"
        echo "  pl upstream configure"
        exit 1
    fi

    # Get current branch
    local current_branch=$(git rev-parse --abbrev-ref HEAD)
    echo "Current branch: $current_branch"
    echo "Strategy: $OPT_STRATEGY"
    if [ "$OPT_DRY_RUN" = "y" ]; then
        echo "Mode: DRY RUN (no changes will be made)"
    fi
    echo ""

    # Fetch from upstream
    print_info "Fetching from upstream..."
    if [ "$OPT_DRY_RUN" = "y" ]; then
        print_info "[DRY RUN] Would fetch from upstream"
    else
        if git fetch upstream 2>&1 | grep -v "^From"; then
            print_status "OK" "Fetched"
        else
            print_error "Failed to fetch from upstream"
            exit 1
        fi
    fi

    # Determine upstream branch
    local upstream_branch="upstream/main"
    if ! git rev-parse --verify upstream/main >/dev/null 2>&1; then
        if git rev-parse --verify upstream/master >/dev/null 2>&1; then
            upstream_branch="upstream/master"
        else
            print_error "Upstream main/master branch not found"
            exit 1
        fi
    fi

    # Check if we're behind
    local behind=$(git rev-list --count HEAD..$upstream_branch 2>/dev/null || echo "0")

    if [ "$behind" -eq 0 ]; then
        print_status "OK" "Already up to date with upstream"
        exit 0
    fi

    echo ""
    print_info "Behind upstream by $behind commit(s)"
    echo ""
    echo "Recent upstream commits:"
    git log --oneline HEAD..$upstream_branch | head -5
    echo ""

    if ! ask_yes_no "Sync with upstream?" "y"; then
        echo "Cancelled."
        exit 0
    fi

    # Sync based on strategy
    echo ""
    if [ "$OPT_STRATEGY" = "rebase" ]; then
        print_info "Rebasing onto upstream..."
        if [ "$OPT_DRY_RUN" = "y" ]; then
            print_info "[DRY RUN] Would run: git rebase $upstream_branch"
        else
            if git rebase "$upstream_branch"; then
                print_status "OK" "Rebased successfully"
            else
                print_error "Rebase failed - resolve conflicts and run: git rebase --continue"
                exit 1
            fi
        fi
    else
        print_info "Merging from upstream..."
        if [ "$OPT_DRY_RUN" = "y" ]; then
            print_info "[DRY RUN] Would run: git merge $upstream_branch"
        else
            if git merge "$upstream_branch" --no-edit; then
                print_status "OK" "Merged successfully"
            else
                print_error "Merge failed - resolve conflicts and commit"
                exit 1
            fi
        fi
    fi

    # Update last_sync timestamp
    if has_upstream_config && [ "$OPT_DRY_RUN" != "y" ]; then
        local timestamp=$(date -Iseconds)
        if grep -q "last_sync:" "$UPSTREAM_CONFIG" 2>/dev/null; then
            sed -i "s/last_sync:.*/last_sync: \"$timestamp\"/" "$UPSTREAM_CONFIG"
        else
            echo "  last_sync: \"$timestamp\"" >> "$UPSTREAM_CONFIG"
        fi
    fi

    # Update CLAUDE.md if it changed
    if [ "$OPT_DRY_RUN" != "y" ] && git diff --name-only HEAD~1 HEAD | grep -q "CLAUDE.md"; then
        echo ""
        print_warning "CLAUDE.md was updated from upstream"
        echo ""
        echo "Review new standing orders:"
        echo "  git diff HEAD~1 HEAD -- CLAUDE.md"
    fi

    # Check for new decisions
    if [ "$OPT_DRY_RUN" != "y" ] && git diff --name-only HEAD~1 HEAD | grep -q "docs/decisions/"; then
        echo ""
        print_info "New decisions from upstream:"
        git diff --name-only HEAD~1 HEAD | grep "docs/decisions/" | sed 's/^/  /'
        echo ""
        echo "Review decisions:"
        echo "  git diff HEAD~1 HEAD -- docs/decisions/"
    fi

    echo ""
    print_status "OK" "Sync complete"
    echo ""
    echo "Current status:"
    git log --oneline -5
}

################################################################################
# Main
################################################################################

main() {
    parse_arguments "$@"

    if [ "$OPT_HELP" = "y" ]; then
        show_help
    fi

    # Ensure we're in project root
    cd "$PROJECT_ROOT" || exit 1

    # Route to command
    case "$OPT_COMMAND" in
        sync)
            cmd_sync
            ;;
        status)
            cmd_status
            ;;
        configure|config)
            cmd_configure
            ;;
        info)
            cmd_info
            ;;
        "")
            print_error "Command required"
            echo ""
            echo "Commands:"
            echo "  sync        Sync with upstream"
            echo "  status      Show upstream status"
            echo "  configure   Configure upstream"
            echo "  info        Show configuration"
            echo ""
            echo "For help: pl upstream --help"
            exit 1
            ;;
        *)
            print_error "Unknown command: $OPT_COMMAND"
            echo ""
            echo "Valid commands: sync, status, configure, info"
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
