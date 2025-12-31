#!/bin/bash

################################################################################
# gitlab_harden.sh - Apply security hardening to GitLab instance
#
# This script applies security best practices to a GitLab CE installation.
# It should be run on the GitLab server after initial setup.
#
# Usage:
#   ./gitlab_harden.sh                    # Dry-run all options
#   ./gitlab_harden.sh --apply            # Apply all hardening options
#   ./gitlab_harden.sh --apply 1,2,5      # Apply specific options by number
#   ./gitlab_harden.sh --apply 1-4        # Apply range of options
#   ./gitlab_harden.sh --check            # Check current security status
#   ./gitlab_harden.sh --list             # List available hardening options
#   ./gitlab_harden.sh --help             # Show this help
#
# Hardening Options:
#   1. Disable public sign-ups
#   2. Password security (minimum length)
#   3. Session security (timeout)
#   4. Audit logging
#   5. Rate limiting (brute force protection)
#   6. Privacy settings (disable Gravatar)
#   7. Protected paths (rack-attack)
#   8. SSH security (informational only)
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
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Defaults
DRY_RUN=true
CHECK_ONLY=false
LIST_ONLY=false
SELECTED_OPTIONS=""

# All available hardening options
declare -A HARDEN_OPTIONS=(
    [1]="signups:Disable public sign-ups"
    [2]="passwords:Password security (min length 12)"
    [3]="sessions:Session security (60 min timeout)"
    [4]="audit:Audit logging"
    [5]="rate_limiting:Rate limiting (brute force protection)"
    [6]="privacy:Privacy settings (disable Gravatar)"
    [7]="protected_paths:Protected paths (rack-attack)"
    [8]="ssh:SSH security (informational)"
)

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

print_skip() {
    echo -e "${CYAN}[SKIP]${NC} $1"
}

show_help() {
    head -35 "$0" | grep "^#" | grep -v "^#!/" | sed 's/^# //' | sed 's/^#//'
    exit 0
}

show_list() {
    echo "========================================"
    echo "  GitLab Hardening Options"
    echo "========================================"
    echo ""
    for i in $(seq 1 8); do
        local desc="${HARDEN_OPTIONS[$i]#*:}"
        echo -e "  ${GREEN}$i${NC}. $desc"
    done
    echo ""
    echo "Usage examples:"
    echo "  ./gitlab_harden.sh --apply           # Apply all options"
    echo "  ./gitlab_harden.sh --apply 1,2,5     # Apply options 1, 2, and 5"
    echo "  ./gitlab_harden.sh --apply 1-4       # Apply options 1 through 4"
    echo "  ./gitlab_harden.sh --apply 1,3-5,7   # Mix of individual and ranges"
    echo ""
    exit 0
}

# Parse option selection (e.g., "1,2,5" or "1-4" or "1,3-5,7")
parse_options() {
    local input="$1"
    local result=""

    # Handle "all" or empty (default to all)
    if [ -z "$input" ] || [ "$input" == "all" ]; then
        echo "1,2,3,4,5,6,7,8"
        return
    fi

    # Split by comma
    IFS=',' read -ra parts <<< "$input"
    for part in "${parts[@]}"; do
        if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            # Range (e.g., "1-4")
            local start="${BASH_REMATCH[1]}"
            local end="${BASH_REMATCH[2]}"
            for i in $(seq "$start" "$end"); do
                result="${result}${i},"
            done
        elif [[ "$part" =~ ^[0-9]+$ ]]; then
            # Single number
            result="${result}${part},"
        else
            print_error "Invalid option: $part"
            exit 1
        fi
    done

    # Remove trailing comma
    echo "${result%,}"
}

# Check if option is selected
is_selected() {
    local option="$1"
    [[ ",$SELECTED_OPTIONS," == *",$option,"* ]]
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        if $DRY_RUN || $CHECK_ONLY || $LIST_ONLY; then
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

    # Escape special characters for grep/sed
    local escaped_setting=$(printf '%s' "$setting" | sed 's/[[\.*^$()+?{|]/\\&/g')

    # Check if setting already exists (commented or uncommented)
    if grep -q "^#*\s*${setting}" "$GITLAB_CONFIG" 2>/dev/null; then
        # Update existing line - use different delimiter for sed
        sed -i "/^#*\s*${escaped_setting}/c\\${setting} = ${value}" "$GITLAB_CONFIG"
    else
        # Add new line at end of file
        echo "${setting} = ${value}" >> "$GITLAB_CONFIG"
    fi

    print_ok "Set: $setting = $value"
}

# Check if a setting is configured
check_setting() {
    local setting="$1"
    local expected="$2"
    local description="$3"
    local option_num="${4:-}"

    # Use fgrep (fixed string grep) to match the setting exactly
    local current=$(grep -F "$setting" "$GITLAB_CONFIG" 2>/dev/null | grep -v "^#" | head -1 | sed 's/.*= *//' | tr -d "' ")

    local prefix=""
    [ -n "$option_num" ] && prefix="[$option_num] "

    if [ -z "$current" ]; then
        print_warning "${prefix}$description: Not configured (default)"
        return 1
    elif [ "$current" == "$expected" ]; then
        print_ok "${prefix}$description: $current"
        return 0
    else
        print_warning "${prefix}$description: $current (expected: $expected)"
        return 1
    fi
}

################################################################################
# Hardening Functions
################################################################################

harden_signups() {
    if ! is_selected 1; then
        print_skip "1. Disable Public Sign-ups (not selected)"
        return 0
    fi
    print_header "1. Disable Public Sign-ups"
    echo "Prevents unauthorized users from creating accounts"
    echo ""
    update_config "gitlab_rails['gitlab_signup_enabled']" "false" "Disable sign-ups"
}

harden_passwords() {
    if ! is_selected 2; then
        print_skip "2. Password Security (not selected)"
        return 0
    fi
    print_header "2. Password Security"
    echo "Enforce strong passwords and complexity requirements"
    echo ""
    update_config "gitlab_rails['password_minimum_length']" "12" "Minimum password length"
}

harden_sessions() {
    if ! is_selected 3; then
        print_skip "3. Session Security (not selected)"
        return 0
    fi
    print_header "3. Session Security"
    echo "Configure session timeout and security"
    echo ""
    update_config "gitlab_rails['session_expire_delay']" "60" "Session timeout (minutes)"
}

harden_audit() {
    if ! is_selected 4; then
        print_skip "4. Audit Logging (not selected)"
        return 0
    fi
    print_header "4. Audit Logging"
    echo "Enable comprehensive audit logging"
    echo ""
    update_config "gitlab_rails['audit_events_enabled']" "true" "Audit events"
}

harden_rate_limiting() {
    if ! is_selected 5; then
        print_skip "5. Rate Limiting (not selected)"
        return 0
    fi
    print_header "5. Rate Limiting"
    echo "Protect against brute force and DoS attacks"
    echo ""
    update_config "gitlab_rails['rate_limiting_response_text']" "'Retry later'" "Rate limit message"
    update_config "gitlab_rails['throttle_authenticated_api_enabled']" "true" "API throttling"
    update_config "gitlab_rails['throttle_authenticated_web_enabled']" "true" "Web throttling"
    update_config "gitlab_rails['throttle_unauthenticated_enabled']" "true" "Unauthenticated throttling"
}

harden_privacy() {
    if ! is_selected 6; then
        print_skip "6. Privacy Settings (not selected)"
        return 0
    fi
    print_header "6. Privacy Settings"
    echo "Reduce external data leakage"
    echo ""
    update_config "gitlab_rails['gravatar_enabled']" "false" "Disable Gravatar"
}

harden_protected_paths() {
    if ! is_selected 7; then
        print_skip "7. Protected Paths (not selected)"
        return 0
    fi
    print_header "7. Protected Paths"
    echo "Enable rack-attack protection for sensitive endpoints"
    echo ""
    update_config "gitlab_rails['rack_attack_git_basic_auth']['enabled']" "true" "Git auth protection"
}

harden_ssh() {
    if ! is_selected 8; then
        print_skip "8. SSH Security (not selected)"
        return 0
    fi
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
    if ! check_setting "gitlab_rails['gitlab_signup_enabled']" "false" "Sign-ups disabled" "1"; then
        issues=$((issues + 1))
    fi

    # Check password length
    if ! check_setting "gitlab_rails['password_minimum_length']" "12" "Password minimum length" "2"; then
        issues=$((issues + 1))
    fi

    # Check session timeout
    if ! check_setting "gitlab_rails['session_expire_delay']" "60" "Session timeout" "3"; then
        issues=$((issues + 1))
    fi

    # Check audit logging
    if ! check_setting "gitlab_rails['audit_events_enabled']" "true" "Audit logging" "4"; then
        issues=$((issues + 1))
    fi

    # Check rate limiting
    if ! check_setting "gitlab_rails['throttle_authenticated_api_enabled']" "true" "API rate limiting" "5"; then
        issues=$((issues + 1))
    fi

    # Check Gravatar
    if ! check_setting "gitlab_rails['gravatar_enabled']" "false" "Gravatar disabled" "6"; then
        issues=$((issues + 1))
    fi

    # Check protected paths
    if ! check_setting "gitlab_rails['rack_attack_git_basic_auth']['enabled']" "true" "Protected paths" "7"; then
        issues=$((issues + 1))
    fi

    echo ""
    if [ $issues -eq 0 ]; then
        print_ok "All security checks passed!"
    else
        print_warning "$issues security issue(s) found"
        echo ""
        echo "Run '$0 --apply' to fix all issues"
        echo "Or specify options: '$0 --apply 1,2,5'"
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
            # Check if next argument is option selection
            if [[ "${2:-}" =~ ^[0-9,-]+$ ]] || [ "${2:-}" == "all" ]; then
                SELECTED_OPTIONS=$(parse_options "$2")
                shift
            else
                SELECTED_OPTIONS=$(parse_options "all")
            fi
            shift
            ;;
        --check)
            CHECK_ONLY=true
            shift
            ;;
        --list|-l)
            LIST_ONLY=true
            shift
            ;;
        -h|--help)
            show_help
            ;;
        *)
            # Check if it's option numbers for dry-run
            if [[ "$1" =~ ^[0-9,-]+$ ]]; then
                SELECTED_OPTIONS=$(parse_options "$1")
                shift
            else
                print_error "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
            fi
            ;;
    esac
done

# Default to all options if none selected
[ -z "$SELECTED_OPTIONS" ] && SELECTED_OPTIONS=$(parse_options "all")

# Show list and exit
if $LIST_ONLY; then
    show_list
fi

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

# Show selected options
echo "Selected options: $SELECTED_OPTIONS"
echo ""

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

# Apply hardening based on selection
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
    echo "  sudo $0 --apply 1,2,5    # Specific options"
    echo ""
    print_info "To check current security status, run:"
    echo "  $0 --check"
    echo ""
    print_info "To list available options, run:"
    echo "  $0 --list"
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
