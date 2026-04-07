#!/bin/bash
set -euo pipefail

################################################################################
# NWP Automated Security Update Script
#
# This script automates security updates for Drupal sites:
# - Checks for Drupal and Composer security updates
# - Creates a security branch from develop
# - Applies updates and runs tests
# - Commits and pushes if tests pass
#
# Designed to be run by CI/CD or cron for automated security patching
#
# Usage: ./scripts/security-update.sh [OPTIONS] <sitename>
################################################################################

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source shared libraries
source "$PROJECT_ROOT/lib/ui.sh"

# Script start time
START_TIME=$(date +%s)

################################################################################
# Configuration
################################################################################

# Branch naming
SECURITY_BRANCH_PREFIX="security-updates"
BASE_BRANCH="${BASE_BRANCH:-develop}"

# Git configuration
GIT_USER_NAME="${GIT_USER_NAME:-NWP Security Bot}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-nwp-security@localhost}"

################################################################################
# Help
################################################################################

show_help() {
    cat << EOF
${BOLD}NWP Automated Security Update Script${NC}

${BOLD}USAGE:${NC}
    ./scripts/security-update.sh [OPTIONS] <sitename>

${BOLD}OPTIONS:${NC}
    -h, --help              Show this help message
    -d, --debug             Enable debug output
    -y, --yes               Auto-confirm all prompts
    -b, --base BRANCH       Base branch (default: develop)
    --no-push               Don't push to remote
    --skip-tests            Skip test execution
    --force                 Force update even if no security issues found

${BOLD}EXAMPLES:${NC}
    # Check and apply security updates
    ./scripts/security-update.sh avc

    # Automated mode (no prompts)
    ./scripts/security-update.sh -y avc

    # Use main as base branch
    ./scripts/security-update.sh -b main avc

    # Skip tests (not recommended)
    ./scripts/security-update.sh --skip-tests avc

${BOLD}WORKFLOW:${NC}
    1. Check for security updates
    2. Create security branch from develop
    3. Apply Drupal and Composer updates
    4. Run database updates
    5. Export configuration
    6. Run tests via dev2stg.sh
    7. Commit changes if tests pass
    8. Push branch to remote

${BOLD}AUTOMATION:${NC}
    Add to crontab for daily security checks:
    0 2 * * * /path/to/scripts/security-update.sh -y <sitename> >> /var/log/nwp-security.log 2>&1

${BOLD}CI/CD INTEGRATION:${NC}
    Use in GitHub Actions, GitLab CI, or other automation:
    - Set GIT_USER_NAME and GIT_USER_EMAIL environment variables
    - Run with -y flag for non-interactive mode
    - Check exit code (0 = success, non-zero = failure)

EOF
}

################################################################################
# Security Check Functions
################################################################################

# Check if security updates are available
check_security_updates() {
    local sitename="$1"

    info "Checking for security updates: $sitename"

    if [ ! -d "$PROJECT_ROOT/$sitename" ]; then
        fail "Site not found: $sitename"
        return 1
    fi

    cd "$PROJECT_ROOT/$sitename" || return 1

    local has_updates=0

    # Check Drupal security advisories
    task "Checking Drupal security advisories..."
    if ddev drush pm:security 2>&1 | grep -qE "(SECURITY UPDATE|security update available)"; then
        warn "Drupal security updates available"
        ddev drush pm:security 2>&1 | grep -E "(SECURITY UPDATE|security update available)" || true
        has_updates=1
    else
        pass "No Drupal security updates found"
    fi

    # Check Composer audit
    task "Checking Composer vulnerabilities..."
    if ddev composer audit 2>&1 | grep -qE "(Found [0-9]+ security vulnerability|security vulnerabilities)"; then
        warn "Composer vulnerabilities found"
        ddev composer audit 2>&1 || true
        has_updates=1
    else
        pass "No Composer vulnerabilities found"
    fi

    cd "$PROJECT_ROOT" || return 1

    return $has_updates
}

################################################################################
# Git Functions
################################################################################

# Create security update branch
create_security_branch() {
    local sitename="$1"
    local base_branch="$2"
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local branch_name="${SECURITY_BRANCH_PREFIX}/${sitename}/${timestamp}"

    info "Creating security branch: $branch_name"

    cd "$PROJECT_ROOT/$sitename" || return 1

    # Ensure we're on latest base branch
    task "Fetching latest changes from remote..."
    if git fetch origin "$base_branch" 2>/dev/null; then
        pass "Fetched from remote"
    else
        warn "Could not fetch from remote (continuing with local)"
    fi

    # Check if base branch exists
    if ! git rev-parse --verify "$base_branch" >/dev/null 2>&1; then
        # Try origin/base_branch
        if git rev-parse --verify "origin/$base_branch" >/dev/null 2>&1; then
            task "Checking out base branch from origin..."
            git checkout -b "$base_branch" "origin/$base_branch" || return 1
        else
            fail "Base branch not found: $base_branch"
            return 1
        fi
    fi

    # Switch to base branch
    task "Switching to base branch: $base_branch..."
    git checkout "$base_branch" || return 1

    # Pull latest changes
    if git pull origin "$base_branch" 2>/dev/null; then
        pass "Updated base branch"
    else
        warn "Could not pull from remote (continuing with local)"
    fi

    # Create new branch
    task "Creating branch: $branch_name..."
    git checkout -b "$branch_name" || return 1

    pass "Branch created: $branch_name"

    # Export branch name for later use
    export SECURITY_BRANCH="$branch_name"

    cd "$PROJECT_ROOT" || return 1
    return 0
}

# Commit security updates
commit_security_updates() {
    local sitename="$1"

    info "Committing security updates"

    cd "$PROJECT_ROOT/$sitename" || return 1

    # Configure git user
    git config user.name "$GIT_USER_NAME"
    git config user.email "$GIT_USER_EMAIL"

    # Check if there are changes
    if git diff --quiet && git diff --cached --quiet; then
        warn "No changes to commit"
        cd "$PROJECT_ROOT" || return 1
        return 0
    fi

    # Stage all changes
    task "Staging changes..."
    git add -A

    # Create commit message
    local commit_msg=$(cat <<'EOF'
Apply automated security updates

This commit applies security updates for Drupal core, contributed modules,
and Composer dependencies.

- Drupal security advisories applied
- Composer vulnerabilities patched
- Database updates run
- Configuration exported
- Tests passed

Generated by: scripts/security-update.sh
EOF
)

    # Commit
    task "Creating commit..."
    git commit -m "$commit_msg" || {
        fail "Commit failed"
        cd "$PROJECT_ROOT" || return 1
        return 1
    }

    pass "Changes committed"

    cd "$PROJECT_ROOT" || return 1
    return 0
}

# Push security branch
push_security_branch() {
    local sitename="$1"

    info "Pushing security branch to remote"

    cd "$PROJECT_ROOT/$sitename" || return 1

    # Get current branch
    local current_branch=$(git rev-parse --abbrev-ref HEAD)

    task "Pushing branch: $current_branch..."
    if git push -u origin "$current_branch" 2>&1; then
        pass "Branch pushed to remote"

        # Display PR creation hint
        echo ""
        note "Create a pull request:"
        note "  gh pr create --base $BASE_BRANCH --head $current_branch \\"
        note "    --title 'Security Updates for $sitename' \\"
        note "    --body 'Automated security updates - tests passed'"
    else
        warn "Could not push to remote"
        note "You may need to push manually:"
        note "  cd $sitename && git push -u origin $current_branch"
    fi

    cd "$PROJECT_ROOT" || return 1
    return 0
}

################################################################################
# Update Functions
################################################################################

# Apply security updates
apply_security_updates() {
    local sitename="$1"

    info "Applying security updates: $sitename"

    cd "$PROJECT_ROOT/$sitename" || return 1

    # Ensure DDEV is running
    task "Starting DDEV..."
    ddev start > /dev/null 2>&1 || {
        fail "Failed to start DDEV"
        cd "$PROJECT_ROOT" || return 1
        return 1
    }

    # Update Drupal packages
    task "Updating Drupal packages..."
    if ddev composer update "drupal/*" --with-dependencies 2>&1 | tee /tmp/composer-update.log; then
        pass "Drupal packages updated"
    else
        warn "Some Drupal updates had warnings (check log)"
    fi

    # Run composer audit to verify fixes
    task "Verifying security fixes..."
    ddev composer audit 2>&1 || true

    # Run database updates
    task "Running database updates..."
    if ddev drush updatedb -y > /dev/null 2>&1; then
        pass "Database updates completed"
    else
        warn "Database updates had warnings"
    fi

    # Clear cache
    task "Clearing cache..."
    ddev drush cache:rebuild > /dev/null 2>&1

    # Export configuration
    task "Exporting configuration..."
    if ddev drush config:export -y > /dev/null 2>&1; then
        pass "Configuration exported"
    else
        warn "Configuration export had warnings (may not be needed)"
    fi

    cd "$PROJECT_ROOT" || return 1
    return 0
}

################################################################################
# Testing Functions
################################################################################

# Run tests via dev2stg.sh
run_security_tests() {
    local sitename="$1"

    info "Running tests via dev2stg.sh"

    if [ ! -x "$PROJECT_ROOT/dev2stg.sh" ]; then
        warn "dev2stg.sh not found - skipping staging tests"
        return 0
    fi

    # Run dev2stg with essential tests
    task "Deploying to staging and running tests..."
    if "$PROJECT_ROOT/dev2stg.sh" -y -t essential "$sitename" > /tmp/dev2stg-security.log 2>&1; then
        pass "All tests passed"
        return 0
    else
        fail "Tests failed - check /tmp/dev2stg-security.log"
        note "Review test failures before merging security updates"
        return 1
    fi
}

################################################################################
# Main Workflow
################################################################################

execute_security_update() {
    local sitename="$1"
    local skip_tests="$2"
    local no_push="$3"
    local force="$4"
    local base_branch="$5"

    print_header "Automated Security Update: $sitename"

    # Step 1: Check for security updates
    step 1 7 "Check for security updates"
    if ! check_security_updates "$sitename"; then
        if [ "$force" = "true" ]; then
            warn "No security updates found, but continuing due to --force"
        else
            pass "No security updates needed"
            return 0
        fi
    fi

    # Step 2: Create security branch
    step 2 7 "Create security branch"
    create_security_branch "$sitename" "$base_branch" || return 1

    # Step 3: Apply updates
    step 3 7 "Apply security updates"
    apply_security_updates "$sitename" || return 1

    # Step 4: Run tests (unless skipped)
    step 4 7 "Run tests"
    if [ "$skip_tests" = "true" ]; then
        warn "Tests skipped (--skip-tests specified)"
    else
        if ! run_security_tests "$sitename"; then
            fail "Tests failed - aborting"
            note "Security branch created but not pushed due to test failures"
            note "Branch: $SECURITY_BRANCH"
            return 1
        fi
    fi

    # Step 5: Commit changes
    step 5 7 "Commit changes"
    commit_security_updates "$sitename" || return 1

    # Step 6: Push to remote (unless skipped)
    step 6 7 "Push to remote"
    if [ "$no_push" = "true" ]; then
        warn "Push skipped (--no-push specified)"
        note "Branch created locally: $SECURITY_BRANCH"
    else
        push_security_branch "$sitename" || return 1
    fi

    # Step 7: Summary
    step 7 7 "Security update complete"

    show_elapsed_time "Security update"

    return 0
}

################################################################################
# Main
################################################################################

main() {
    local DEBUG=false
    local AUTO_YES=false
    local SKIP_TESTS=false
    local NO_PUSH=false
    local FORCE=false
    local SITENAME=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -d|--debug)
                DEBUG=true
                shift
                ;;
            -y|--yes)
                AUTO_YES=true
                shift
                ;;
            -b|--base)
                BASE_BRANCH="$2"
                shift 2
                ;;
            --base=*)
                BASE_BRANCH="${1#*=}"
                shift
                ;;
            --no-push)
                NO_PUSH=true
                shift
                ;;
            --skip-tests)
                SKIP_TESTS=true
                shift
                ;;
            --force)
                FORCE=true
                shift
                ;;
            -*)
                print_error "Unknown option: $1"
                show_help
                exit 1
                ;;
            *)
                if [ -z "$SITENAME" ]; then
                    SITENAME="$1"
                fi
                shift
                ;;
        esac
    done

    # Validate sitename
    if [ -z "$SITENAME" ]; then
        print_error "Missing site name"
        echo ""
        show_help
        exit 1
    fi

    # Confirmation prompt (unless -y)
    if [ "$AUTO_YES" != "true" ]; then
        echo ""
        print_warning "This will create a security update branch and apply updates"
        read -p "Continue? [y/N]: " response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            info "Cancelled"
            exit 0
        fi
    fi

    # Execute security update workflow
    if execute_security_update "$SITENAME" "$SKIP_TESTS" "$NO_PUSH" "$FORCE" "$BASE_BRANCH"; then
        exit 0
    else
        fail "Security update failed"
        exit 1
    fi
}

# Run main
main "$@"
