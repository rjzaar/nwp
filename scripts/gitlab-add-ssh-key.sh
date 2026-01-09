#!/bin/bash
################################################################################
# GitLab SSH Key Management Script
#
# Adds an SSH public key to a GitLab user account via API.
# Used by admins for fast developer onboarding.
#
# Usage:
#   ./gitlab-add-ssh-key.sh <username> <ssh_public_key> [key_title]
#
# Examples:
#   ./gitlab-add-ssh-key.sh john "ssh-ed25519 AAAA... john@laptop"
#   ./gitlab-add-ssh-key.sh jane "ssh-rsa AAAA... jane@desktop" "jane-desktop-key"
################################################################################

set -e

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"

# Source libraries
source "$PROJECT_ROOT/lib/git.sh"
source "$PROJECT_ROOT/lib/ui.sh"

# Parse arguments
username="$1"
ssh_key="$2"
key_title="${3:-${username}-key}"

# Validate input
if [[ -z "$username" || -z "$ssh_key" ]]; then
    print_error "Usage: $0 <username> <ssh_public_key> [key_title]"
    echo ""
    echo "Examples:"
    echo "  $0 john \"ssh-ed25519 AAAA... john@laptop\""
    echo "  $0 jane \"ssh-rsa AAAA... jane@desktop\" \"jane-work-laptop\""
    exit 1
fi

# Validate SSH key format
if [[ ! "$ssh_key" =~ ^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521)[[:space:]] ]]; then
    print_error "Invalid SSH key format. Must start with ssh-rsa, ssh-ed25519, or ecdsa-sha2-*"
    exit 1
fi

# Get GitLab credentials
gitlab_url=$(get_gitlab_url)
token=$(get_gitlab_token)

if [[ -z "$gitlab_url" || -z "$token" ]]; then
    print_error "GitLab URL and API token required"
    print_info "Configure in .secrets.yml under gitlab.api_token"
    exit 1
fi

print_header "Adding SSH Key to GitLab User"
info "Username: $username"
info "Key title: $key_title"
echo ""

# Get user ID
info "Looking up user..."
user_response=$(curl -s --header "PRIVATE-TOKEN: $token" \
    "https://${gitlab_url}/api/v4/users?username=${username}")

user_id=$(echo "$user_response" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')

if [[ -z "$user_id" ]]; then
    print_error "User not found: $username"
    exit 1
fi
pass "Found user ID: $user_id"

# Check if key already exists
info "Checking for existing keys..."
existing_keys=$(curl -s --header "PRIVATE-TOKEN: $token" \
    "https://${gitlab_url}/api/v4/users/${user_id}/keys")

key_fingerprint=$(echo "$ssh_key" | awk '{print $2}' | head -c 20)
if echo "$existing_keys" | grep -q "$key_fingerprint"; then
    warn "SSH key appears to already exist for this user"
    read -p "Continue anyway? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        info "Cancelled"
        exit 0
    fi
fi

# Add SSH key
info "Adding SSH key..."
result=$(curl -s --header "PRIVATE-TOKEN: $token" \
    --header "Content-Type: application/json" \
    --data "$(cat <<EOF
{
    "title": "${key_title}",
    "key": "${ssh_key}"
}
EOF
)" \
    "https://${gitlab_url}/api/v4/users/${user_id}/keys")

# Check result
if echo "$result" | grep -q '"id":[0-9]*'; then
    key_id=$(echo "$result" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')
    echo ""
    print_header "Success"
    pass "SSH key added for $username"
    info "Key ID: $key_id"
    info "Title: $key_title"
    echo ""
    info "User can now test with:"
    task "ssh -T git@${gitlab_url}"
else
    echo ""
    print_error "Failed to add SSH key"
    warn "API Response:"
    echo "$result" | python3 -m json.tool 2>/dev/null || echo "$result"
    exit 1
fi
