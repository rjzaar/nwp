#!/bin/bash

################################################################################
# gitlab_harden.sh - Apply security hardening to GitLab instance
#
# This script applies security best practices to a GitLab CE installation.
# It should be run on the GitLab server after initial setup.
#
# Usage:
#   ./gitlab_harden.sh              # Dry-run: show what would be changed
#   ./gitlab_harden.sh --apply      # Apply changes
#   ./gitlab_harden.sh --check      # Check current security status
#   ./gitlab_harden.sh --help       # Show this help
#
# The script modifies /etc/gitlab/gitlab.rb and runs gitlab-ctl reconfigure.
#
################################################################################

set -euo pipefail

# Configuration
GITLAB_CONFIG="/etc/gitlab/gitlab.rb"
GITLAB_CONFIG_BACKUP="${GITLAB_CONFIG}.backup.$(date +%Y%m%d_%H%M%S)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Defaults
DRY_RUN=true
CHECK_ONLY=false

################################################################################
# Functions
################################################################################

print_header() {
    echo -e "\n${BLUE}=== $1 ===${NC}\n"
}

print_ok() {
    echo -e "${GREEN}[OK]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_dryrun() {
    echo -e "${YELLOW}[DRY-RUN]${NC} Would set: $1"
}

show_help() {
    grep "^#" "$0" | grep -v "^#!/" | sed 's/^# //' | sed 's/^#//' | head -20
    exit 0
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        if $DRY_RUN || $CHECK_ONLY; then
            print_warning "Not running as root - some checks may fail"
        else
            print_error "This script must be run as root when applying changes"
            echo "Try: sudo $0 --apply"
            exit 1
        fi
    fi
}

# Check if GitLab is installed
check_gitlab_installed() {
    if [ ! -f "$GITLAB_CONFIG" ]; then
        print_error "GitLab configuration not found at $GITLAB_CONFIG"
        print_info "Is GitLab installed on this server?"
        exit 1
    fi
}

# Update or add a setting in gitlab.rb
update_config() {
    local setting="$1"
    local value="$2"
    local description="${3:-}"

    if $DRY_RUN; then
        print_dryrun "$setting = $value"
        return 0
    fi

    # Check if setting already exists (commented or uncommented)
    if grep -qE "^#?\s*${setting}" "$GITLAB_CONFIG"; then
        # Update existing line
        sed -i "s|^#*\s*${setting}.*|${setting} = ${value}|" "$GITLAB_CONFIG"
    else
        # Add new line before the closing comments
        echo "${setting} = ${value}" >> "$GITLAB_CONFIG"
    fi

    print_ok "Set: $setting = $value"
}

# Check if a setting is configured
check_setting() {
    local setting="$1"
    local expected="$2"
    local description="$3"

    local current=$(grep -E "^${setting}" "$GITLAB_CONFIG" 2>/dev/null | head -1 | cut -d'=' -f2 | tr -d ' ')

    if [ -z "$current" ]; then
        print_warning "$description: Not configured (default)"
        return 1
    elif [ "$current" == "$expected" ]; then
        print_ok "$description: $current"
        return 0
    else
        print_warning "$description: $current (expected: $expected)"
        return 1
    fi
}

################################################################################
# Hardening Functions
################################################################################

harden_signups() {
    print_header "1. Disable Public Sign-ups"
    echo "Prevents unauthorized users from creating accounts"
    echo ""
    update_config "gitlab_rails['gitlab_signup_enabled']" "false" "Disable sign-ups"
}

harden_passwords() {
    print_header "2. Password Security"
    echo "Enforce strong passwords and complexity requirements"
    echo ""
    update_config "gitlab_rails['password_minimum_length']" "12" "Minimum password length"
}

harden_sessions() {
    print_header "3. Session Security"
    echo "Configure session timeout and security"
    echo ""
    update_config "gitlab_rails['session_expire_delay']" "60" "Session timeout (minutes)"
}

harden_audit() {
    print_header "4. Audit Logging"
    echo "Enable comprehensive audit logging"
    echo ""
    update_config "gitlab_rails['audit_events_enabled']" "true" "Audit events"
}

harden_rate_limiting() {
    print_header "5. Rate Limiting"
    echo "Protect against brute force and DoS attacks"
    echo ""
    update_config "gitlab_rails['rate_limiting_response_text']" "'Retry later'" "Rate limit message"
    update_config "gitlab_rails['throttle_authenticated_api_enabled']" "true" "API throttling"
    update_config "gitlab_rails['throttle_authenticated_web_enabled']" "true" "Web throttling"
    update_config "gitlab_rails['throttle_unauthenticated_enabled']" "true" "Unauthenticated throttling"
}

harden_privacy() {
    print_header "6. Privacy Settings"
    echo "Reduce external data leakage"
    echo ""
    update_config "gitlab_rails['gravatar_enabled']" "false" "Disable Gravatar"
}

harden_protected_paths() {
    print_header "7. Protected Paths"
    echo "Enable rack-attack protection for sensitive endpoints"
    echo ""
    update_config "gitlab_rails['rack_attack_git_basic_auth']['enabled']" "true" "Git auth protection"
}

harden_ssh() {
    print_header "8. SSH Security"
    echo "Configure secure SSH settings"
    echo ""
    # Note: These require specific SSH configuration
    print_info "SSH hardening should be configured at the OS level"
    print_info "Ensure password authentication is disabled in /etc/ssh/sshd_config"
}

check_security_status() {
    print_header "GitLab Security Status Check"

    local issues=0

    echo "Checking security configuration..."
    echo ""

    # Check sign-ups
    if ! check_setting "gitlab_rails['gitlab_signup_enabled']" "false" "Sign-ups disabled"; then
        ((issues++))
    fi

    # Check password length
    if ! check_setting "gitlab_rails['password_minimum_length']" "12" "Password minimum length"; then
        ((issues++))
    fi

    # Check session timeout
    if ! check_setting "gitlab_rails['session_expire_delay']" "60" "Session timeout"; then
        ((issues++))
    fi

    # Check audit logging
    if ! check_setting "gitlab_rails['audit_events_enabled']" "true" "Audit logging"; then
        ((issues++))
    fi

    # Check rate limiting
    if ! check_setting "gitlab_rails['throttle_authenticated_api_enabled']" "true" "API rate limiting"; then
        ((issues++))
    fi

    # Check Gravatar
    if ! check_setting "gitlab_rails['gravatar_enabled']" "false" "Gravatar disabled"; then
        ((issues++))
    fi

    echo ""
    if [ $issues -eq 0 ]; then
        print_ok "All security checks passed!"
    else
        print_warning "$issues security issue(s) found"
        echo ""
        echo "Run '$0 --apply' to fix these issues"
    fi

    return $issues
}

################################################################################
# Main
################################################################################

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --apply)
            DRY_RUN=false
            shift
            ;;
        --check)
            CHECK_ONLY=true
            shift
            ;;
        -h|--help)
            show_help
            ;;
        *)
            print_error "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

echo "========================================"
echo "  GitLab Security Hardening"
echo "========================================"
echo ""

# Checks
check_gitlab_installed
check_root

if $CHECK_ONLY; then
    check_security_status
    exit $?
fi

if $DRY_RUN; then
    print_warning "DRY-RUN MODE - No changes will be made"
    print_info "Run with --apply to make actual changes"
    echo ""
fi

# Backup config before changes
if ! $DRY_RUN; then
    print_info "Backing up configuration to: $GITLAB_CONFIG_BACKUP"
    cp "$GITLAB_CONFIG" "$GITLAB_CONFIG_BACKUP"
fi

# Apply hardening
harden_signups
harden_passwords
harden_sessions
harden_audit
harden_rate_limiting
harden_privacy
harden_protected_paths
harden_ssh

echo ""
echo "========================================"

if $DRY_RUN; then
    echo ""
    print_info "This was a dry-run. To apply changes, run:"
    echo "  sudo $0 --apply"
    echo ""
    print_info "To check current security status, run:"
    echo "  $0 --check"
else
    echo ""
    print_info "Reconfiguring GitLab (this may take a few minutes)..."
    gitlab-ctl reconfigure

    echo ""
    print_ok "Security hardening applied successfully!"
    echo ""
    print_info "Configuration backed up to: $GITLAB_CONFIG_BACKUP"
    print_info "Run '$0 --check' to verify settings"
fi

echo "========================================"
