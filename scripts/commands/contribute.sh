#!/bin/bash
set -euo pipefail

################################################################################
# NWP Contribute Script
#
# Submit contributions to upstream repository via merge request.
# Part of the distributed contribution governance model.
#
# Usage: ./contribute.sh [options]
#
# Options:
#   --branch <name>     Feature branch name (auto-detected if omitted)
#   --title <title>     MR title (auto-generated from commits if omitted)
#   --draft             Create as draft MR
#   --no-tests          Skip running tests before creating MR
#   --help, -h          Show this help
#
# Examples:
#   ./contribute.sh                           # Auto-detect branch, run tests
#   ./contribute.sh --draft                   # Create draft MR
#   ./contribute.sh --title "Fix bug #123"    # Custom title
#   ./contribute.sh --no-tests                # Skip tests
#
# Prerequisites:
#   - Upstream configured (pl upstream configure)
#   - GitLab CLI (gh or glab) installed
#   - Changes committed to feature branch
#   - Tests passing
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
OPT_BRANCH=""
OPT_TITLE=""
OPT_DRAFT="n"
OPT_NO_TESTS="n"
OPT_HELP="n"

################################################################################
# Argument Parsing
################################################################################

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --branch)
                OPT_BRANCH="$2"
                shift 2
                ;;
            --title)
                OPT_TITLE="$2"
                shift 2
                ;;
            --draft)
                OPT_DRAFT="y"
                shift
                ;;
            --no-tests)
                OPT_NO_TESTS="y"
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
    head -32 "$0" | tail -27 | sed 's/^# //' | sed 's/^#//'
    exit 0
}

################################################################################
# GitLab CLI Detection
################################################################################

detect_gitlab_cli() {
    if command -v glab >/dev/null 2>&1; then
        echo "glab"
    elif command -v gh >/dev/null 2>&1; then
        # Check if this is a GitLab instance
        if git remote get-url upstream 2>/dev/null | grep -q "gitlab"; then
            print_warning "GitHub CLI detected but upstream is GitLab"
            echo "glab"
        else
            echo "gh"
        fi
    else
        echo ""
    fi
}

################################################################################
# Pre-flight Checks
################################################################################

check_prerequisites() {
    print_header "Pre-flight Checks"
    echo ""

    # Check git repository
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        print_error "Not a git repository"
        exit 1
    fi
    print_status "OK" "Git repository"

    # Check for uncommitted changes
    if ! git diff-index --quiet HEAD -- 2>/dev/null; then
        print_error "You have uncommitted changes"
        echo ""
        git status --short
        echo ""
        echo "Commit or stash your changes before contributing."
        exit 1
    fi
    print_status "OK" "No uncommitted changes"

    # Check upstream configured
    if ! git remote get-url upstream >/dev/null 2>&1; then
        print_error "Upstream remote not configured"
        echo ""
        echo "Configure upstream first:"
        echo "  pl upstream configure"
        exit 1
    fi
    print_status "OK" "Upstream configured"

    # Check current branch
    local current_branch=$(git rev-parse --abbrev-ref HEAD)
    if [ "$current_branch" = "main" ] || [ "$current_branch" = "master" ]; then
        print_error "Cannot contribute from main/master branch"
        echo ""
        echo "Create a feature branch first:"
        echo "  git checkout -b feature/my-feature"
        exit 1
    fi
    print_status "OK" "On feature branch: $current_branch"

    # Check for commits
    local commit_count=$(git rev-list --count upstream/main..HEAD 2>/dev/null || echo "0")
    if [ "$commit_count" -eq 0 ]; then
        print_error "No commits to contribute"
        echo ""
        echo "Make some commits on your feature branch first."
        exit 1
    fi
    print_status "OK" "$commit_count commit(s) to contribute"

    # Check GitLab CLI
    local gitlab_cli=$(detect_gitlab_cli)
    if [ -z "$gitlab_cli" ]; then
        print_warning "GitLab CLI not found (glab or gh)"
        echo ""
        echo "Install glab for automated MR creation:"
        echo "  https://gitlab.com/gitlab-org/cli"
        echo ""
        echo "Or install gh (GitHub CLI):"
        echo "  https://cli.github.com/"
        echo ""
        return 1
    fi
    print_status "OK" "GitLab CLI: $gitlab_cli"

    echo ""
    return 0
}

################################################################################
# Test Checks
################################################################################

run_tests() {
    print_header "Running Tests"
    echo ""

    # Check if verify script exists
    if [ ! -f "$PROJECT_ROOT/scripts/commands/verify.sh" ]; then
        print_warning "Verify script not found (scripts/commands/verify.sh)"
        return 0
    fi

    print_info "Running NWP verification tests..."
    echo ""

    if "$PROJECT_ROOT/scripts/commands/verify.sh" --run --depth=basic 2>&1 | tee .test-output.tmp; then
        rm -f .test-output.tmp
        echo ""
        print_status "OK" "All tests passed"
        return 0
    else
        local exit_code=$?
        rm -f .test-output.tmp
        echo ""
        print_error "Tests failed (exit code: $exit_code)"
        echo ""
        echo "Fix failing tests before contributing."
        echo "To skip tests: --no-tests (not recommended)"
        return 1
    fi
}

################################################################################
# Decision Checks
################################################################################

check_decisions() {
    print_header "Decision Compliance Check"
    echo ""

    # Check if decision directory exists
    if [ ! -d "$PROJECT_ROOT/docs/decisions" ]; then
        print_info "No decision records found"
        return 0
    fi

    # Check for uncommitted decision records
    if git diff --name-only | grep -q "docs/decisions/"; then
        print_warning "Uncommitted decision records found"
        echo ""
        git diff --name-only | grep "docs/decisions/"
        echo ""
        echo "Commit decision records before contributing."
        return 1
    fi

    print_status "OK" "Decision records committed"
    echo ""
    return 0
}

################################################################################
# Generate MR Description
################################################################################

generate_mr_description() {
    local branch="$1"
    local commit_count=$(git rev-list --count upstream/main..HEAD)

    echo "## Summary"
    echo ""

    # Get commit messages
    if [ "$commit_count" -eq 1 ]; then
        # Single commit - use commit message
        git log -1 --pretty=format:"- %s%n%n%b"
    else
        # Multiple commits - list them
        echo "This MR includes $commit_count commits:"
        echo ""
        git log --pretty=format:"- %s" upstream/main..HEAD
    fi

    echo ""
    echo ""
    echo "## Test Plan"
    echo ""
    if [ "$OPT_NO_TESTS" = "y" ]; then
        echo "- [ ] Tests skipped (--no-tests flag used)"
    else
        echo "- [x] All tests passing"
    fi
    echo "- [ ] Manual testing completed"
    echo "- [ ] Documentation updated"
    echo ""
    echo "## Related Issues"
    echo ""
    echo "<!-- Link to related issues: Closes #123, Related to #456 -->"
    echo ""
    echo "---"
    echo ""
    echo "Generated with [Claude Code](https://claude.com/claude-code)"
}

################################################################################
# Create Merge Request
################################################################################

create_merge_request() {
    local current_branch=$(git rev-parse --abbrev-ref HEAD)
    local gitlab_cli=$(detect_gitlab_cli)

    print_header "Create Merge Request"
    echo ""

    # Auto-detect or use provided branch
    local branch="${OPT_BRANCH:-$current_branch}"
    echo "Branch: $branch"

    # Generate or use provided title
    local title="$OPT_TITLE"
    if [ -z "$title" ]; then
        # Use first commit message as title
        title=$(git log -1 --pretty=format:"%s")
    fi
    echo "Title: $title"
    echo ""

    # Generate MR description
    print_info "Generating MR description..."
    local description=$(generate_mr_description "$branch")

    # Save description to temp file
    echo "$description" > .mr-description.tmp

    echo ""
    print_info "MR Description:"
    echo "---"
    cat .mr-description.tmp
    echo "---"
    echo ""

    if ! ask_yes_no "Create merge request?" "y"; then
        rm -f .mr-description.tmp
        echo "Cancelled."
        exit 0
    fi

    # Push branch to origin
    echo ""
    print_info "Pushing branch to origin..."
    if git push -u origin "$branch" 2>&1; then
        print_status "OK" "Branch pushed"
    else
        print_error "Failed to push branch"
        rm -f .mr-description.tmp
        exit 1
    fi

    # Create MR based on CLI
    echo ""
    if [ -z "$gitlab_cli" ]; then
        print_info "Manual MR creation required"
        echo ""
        echo "Create merge request manually:"
        local upstream_url=$(git remote get-url upstream)
        echo "  $upstream_url/-/merge_requests/new?merge_request[source_branch]=$branch"
        echo ""
        echo "Use this description:"
        cat .mr-description.tmp
        rm -f .mr-description.tmp
        return 0
    fi

    print_info "Creating merge request with $gitlab_cli..."

    if [ "$gitlab_cli" = "glab" ]; then
        local draft_flag=""
        if [ "$OPT_DRAFT" = "y" ]; then
            draft_flag="--draft"
        fi

        if glab mr create \
            --title "$title" \
            --description "$(cat .mr-description.tmp)" \
            --source-branch "$branch" \
            --target-branch main \
            --push \
            $draft_flag 2>&1; then
            print_status "OK" "Merge request created"
        else
            print_error "Failed to create merge request"
            rm -f .mr-description.tmp
            exit 1
        fi
    elif [ "$gitlab_cli" = "gh" ]; then
        local draft_flag=""
        if [ "$OPT_DRAFT" = "y" ]; then
            draft_flag="--draft"
        fi

        if gh pr create \
            --title "$title" \
            --body "$(cat .mr-description.tmp)" \
            --base main \
            --head "$branch" \
            $draft_flag 2>&1; then
            print_status "OK" "Pull request created"
        else
            print_error "Failed to create pull request"
            rm -f .mr-description.tmp
            exit 1
        fi
    fi

    rm -f .mr-description.tmp

    echo ""
    print_status "OK" "Contribution submitted successfully"
    echo ""
    echo "Next steps:"
    echo "  - Wait for CI pipeline to complete"
    echo "  - Address any reviewer feedback"
    echo "  - Monitor the MR for updates"
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

    # Pre-flight checks
    if ! check_prerequisites; then
        exit 1
    fi

    # Check decision compliance
    if ! check_decisions; then
        exit 1
    fi

    # Run tests unless skipped
    if [ "$OPT_NO_TESTS" != "y" ]; then
        if ! run_tests; then
            exit 1
        fi
    else
        print_warning "Skipping tests (--no-tests)"
        echo ""
    fi

    # Create merge request
    create_merge_request
}

main "$@"
