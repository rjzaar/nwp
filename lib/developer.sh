#!/bin/bash

################################################################################
# NWP Developer Identity Library
#
# Provides functions for detecting and managing developer roles and levels.
# Uses .nwp-developer.yml for local identity configuration.
#
# Usage:
#   source lib/developer.sh
#
#   # Get current developer role
#   role=$(get_developer_role)
#
#   # Check if developer can perform action
#   if can_developer "merge"; then
#       git merge main
#   fi
#
# Role Hierarchy:
#   newcomer (0)    - Fork-based contributions only
#   contributor (30) - Developer access, feature branches
#   core (40)        - Maintainer access, merge to main
#   steward (50)     - Owner access, full admin
#
################################################################################

# Determine project root
if [[ -z "$PROJECT_ROOT" ]]; then
    PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

# Developer config file
DEVELOPER_CONFIG="${PROJECT_ROOT}/.nwp-developer.yml"
DEVELOPER_CONFIG_EXAMPLE="${PROJECT_ROOT}/.nwp-developer.example.yml"

################################################################################
# Core Functions
################################################################################

# Check if developer config exists
has_developer_config() {
    [[ -f "$DEVELOPER_CONFIG" ]]
}

# Get developer name
get_developer_name() {
    if has_developer_config && command -v yq &>/dev/null; then
        yq -r '.developer.name // "unknown"' "$DEVELOPER_CONFIG" 2>/dev/null
    else
        echo "unknown"
    fi
}

# Get developer email
get_developer_email() {
    if has_developer_config && command -v yq &>/dev/null; then
        yq -r '.developer.email // ""' "$DEVELOPER_CONFIG" 2>/dev/null
    else
        echo ""
    fi
}

# Get developer role (newcomer, contributor, core, steward)
get_developer_role() {
    if has_developer_config && command -v yq &>/dev/null; then
        yq -r '.developer.role // "newcomer"' "$DEVELOPER_CONFIG" 2>/dev/null
    else
        echo "newcomer"
    fi
}

# Get developer level (numeric GitLab access level)
get_developer_level() {
    if has_developer_config && command -v yq &>/dev/null; then
        yq -r '.developer.level // 0' "$DEVELOPER_CONFIG" 2>/dev/null
    else
        echo "0"
    fi
}

# Get developer subdomain
get_developer_subdomain() {
    if has_developer_config && command -v yq &>/dev/null; then
        yq -r '.developer.subdomain // ""' "$DEVELOPER_CONFIG" 2>/dev/null
    else
        echo ""
    fi
}

# Convert role name to numeric level
role_to_level() {
    local role="$1"
    case "$role" in
        newcomer)    echo 0 ;;
        contributor) echo 30 ;;
        core)        echo 40 ;;
        steward)     echo 50 ;;
        *)           echo 0 ;;
    esac
}

# Convert numeric level to role name
level_to_role() {
    local level="$1"
    if [[ "$level" -ge 50 ]]; then
        echo "steward"
    elif [[ "$level" -ge 40 ]]; then
        echo "core"
    elif [[ "$level" -ge 30 ]]; then
        echo "contributor"
    else
        echo "newcomer"
    fi
}

################################################################################
# Permission Checks
################################################################################

# Check if developer has at least the specified level
has_level() {
    local required_level="$1"
    local current_level=$(get_developer_level)
    [[ "$current_level" -ge "$required_level" ]]
}

# Check if developer can perform a specific action
can_developer() {
    local action="$1"
    local level=$(get_developer_level)

    case "$action" in
        # Actions requiring Steward (50)
        "admin"|"delete_project"|"manage_members"|"standing_orders")
            [[ "$level" -ge 50 ]]
            ;;
        # Actions requiring Core Developer (40)
        "merge"|"push_main"|"approve_mr"|"release"|"protected_vars")
            [[ "$level" -ge 40 ]]
            ;;
        # Actions requiring Contributor (30)
        "push"|"create_branch"|"create_mr"|"review"|"pipeline")
            [[ "$level" -ge 30 ]]
            ;;
        # Actions available to all
        "fork"|"comment"|"read"|"issue")
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Get human-readable description of what developer can do
get_developer_capabilities() {
    local role=$(get_developer_role)

    case "$role" in
        steward)
            echo "Full admin access, standing orders, architecture decisions"
            ;;
        core)
            echo "Merge to main, approve MRs, releases, protected variables"
            ;;
        contributor)
            echo "Push branches, create MRs, run pipelines, own subdomain"
            ;;
        newcomer)
            echo "Fork-based contributions, issues, comments"
            ;;
        *)
            echo "Unknown role"
            ;;
    esac
}

################################################################################
# Configuration Management
################################################################################

# Initialize developer config with prompts
init_developer_config() {
    if has_developer_config; then
        echo "Developer config already exists at $DEVELOPER_CONFIG"
        return 1
    fi

    local name email subdomain role level

    echo "Initializing developer identity..."
    echo ""

    read -p "Developer name (e.g., john): " name
    read -p "Email address: " email
    read -p "Subdomain (e.g., john.nwpcode.org, or empty if fork-based): " subdomain

    # Determine role from subdomain
    if [[ -n "$subdomain" ]]; then
        role="contributor"
        level=30
    else
        role="newcomer"
        level=0
    fi

    # Create config
    cat > "$DEVELOPER_CONFIG" << EOF
# NWP Developer Identity
# This file identifies you to the local NWP installation.
# It is gitignored and should not be committed.

developer:
  name: $name
  email: $email
  role: $role
  level: $level
  subdomain: $subdomain
  upstream: git.nwpcode.org

  # Registration info (auto-populated)
  registered: $(date -u +%Y-%m-%dT%H:%M:%SZ)
  last_sync: null

  # Contribution stats (synced from GitLab)
  contributions:
    commits: 0
    merge_requests: 0
    reviews: 0
    issues_created: 0
    issues_closed: 0
EOF

    echo ""
    echo "Developer config created at $DEVELOPER_CONFIG"
    echo "Role: $role (level $level)"
}

# Update developer role (admin function)
set_developer_role() {
    local new_role="$1"

    if ! has_developer_config; then
        echo "No developer config found. Run init_developer_config first."
        return 1
    fi

    local new_level=$(role_to_level "$new_role")

    if command -v yq &>/dev/null; then
        yq -i ".developer.role = \"$new_role\"" "$DEVELOPER_CONFIG"
        yq -i ".developer.level = $new_level" "$DEVELOPER_CONFIG"
        echo "Updated role to: $new_role (level $new_level)"
    else
        echo "yq required for updating config"
        return 1
    fi
}

# Sync developer info from GitLab
sync_developer_info() {
    if ! has_developer_config; then
        echo "No developer config found"
        return 1
    fi

    local name=$(get_developer_name)
    local gitlab_url upstream

    # Try to get GitLab URL from config or secrets
    if command -v yq &>/dev/null; then
        upstream=$(yq -r '.developer.upstream // ""' "$DEVELOPER_CONFIG")
        if [[ -z "$upstream" ]]; then
            upstream=$(yq -r '.gitlab.server.domain // ""' "${PROJECT_ROOT}/.secrets.yml" 2>/dev/null)
        fi
    fi

    if [[ -z "$upstream" ]]; then
        echo "No upstream GitLab configured"
        return 1
    fi

    local token
    if command -v yq &>/dev/null; then
        token=$(yq -r '.gitlab.api_token // ""' "${PROJECT_ROOT}/.secrets.yml" 2>/dev/null)
    fi

    if [[ -z "$token" ]]; then
        echo "No GitLab API token available"
        return 1
    fi

    echo "Syncing developer info from $upstream..."

    # Get user info
    local user_info=$(curl -s -H "PRIVATE-TOKEN: $token" \
        "https://${upstream}/api/v4/users?username=${name}" 2>/dev/null)

    local user_id=$(echo "$user_info" | jq -r '.[0].id // empty')

    if [[ -z "$user_id" ]]; then
        echo "User not found on GitLab"
        return 1
    fi

    # Get contribution counts
    local events=$(curl -s -H "PRIVATE-TOKEN: $token" \
        "https://${upstream}/api/v4/users/${user_id}/events?per_page=100" 2>/dev/null)

    local commits=$(echo "$events" | jq '[.[] | select(.action_name=="pushed to")] | length')
    local mrs=$(echo "$events" | jq '[.[] | select(.target_type=="MergeRequest")] | length')

    # Update config
    if command -v yq &>/dev/null; then
        yq -i ".developer.contributions.commits = $commits" "$DEVELOPER_CONFIG"
        yq -i ".developer.contributions.merge_requests = $mrs" "$DEVELOPER_CONFIG"
        yq -i ".developer.last_sync = \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"" "$DEVELOPER_CONFIG"
    fi

    echo "Synced: $commits commits, $mrs merge requests"
}

# Show developer status
show_developer_status() {
    if ! has_developer_config; then
        echo "No developer identity configured"
        echo "Run: source lib/developer.sh && init_developer_config"
        return 1
    fi

    local name=$(get_developer_name)
    local email=$(get_developer_email)
    local role=$(get_developer_role)
    local level=$(get_developer_level)
    local subdomain=$(get_developer_subdomain)
    local capabilities=$(get_developer_capabilities)

    echo "Developer Identity"
    echo "=================="
    echo "Name:        $name"
    echo "Email:       $email"
    echo "Role:        $role (level $level)"
    echo "Subdomain:   ${subdomain:-N/A (fork-based)}"
    echo ""
    echo "Capabilities: $capabilities"
    echo ""

    # Show contribution stats if available
    if command -v yq &>/dev/null; then
        local commits=$(yq -r '.developer.contributions.commits // 0' "$DEVELOPER_CONFIG")
        local mrs=$(yq -r '.developer.contributions.merge_requests // 0' "$DEVELOPER_CONFIG")
        local reviews=$(yq -r '.developer.contributions.reviews // 0' "$DEVELOPER_CONFIG")

        echo "Contributions"
        echo "-------------"
        echo "Commits:         $commits"
        echo "Merge Requests:  $mrs"
        echo "Reviews:         $reviews"
    fi
}

################################################################################
# Role-Aware Command Wrappers
################################################################################

# Wrapper for git push that checks permissions
developer_push() {
    local branch="${1:-$(git branch --show-current)}"

    if [[ "$branch" == "main" || "$branch" == "master" ]]; then
        if ! can_developer "push_main"; then
            echo "Error: Your role ($(get_developer_role)) cannot push directly to $branch"
            echo "Create a feature branch and submit a merge request instead:"
            echo "  git checkout -b feature/my-change"
            echo "  git push origin feature/my-change"
            return 1
        fi
    fi

    git push "$@"
}

# Wrapper for merge operations
developer_merge() {
    if ! can_developer "merge"; then
        echo "Error: Your role ($(get_developer_role)) cannot merge to protected branches"
        echo "Submit a merge request for review by a Core Developer or Steward"
        return 1
    fi

    git merge "$@"
}

################################################################################
# Example Config Template
################################################################################

# Create example config if it doesn't exist
create_developer_example() {
    if [[ -f "$DEVELOPER_CONFIG_EXAMPLE" ]]; then
        return 0
    fi

    cat > "$DEVELOPER_CONFIG_EXAMPLE" << 'EOF'
# NWP Developer Identity
#
# Copy this file to .nwp-developer.yml and configure your identity.
# This file is gitignored and should not be committed.
#
# Role Hierarchy:
#   newcomer (0)     - Fork-based contributions only
#   contributor (30) - Developer access, feature branches, own subdomain
#   core (40)        - Maintainer access, merge to main
#   steward (50)     - Owner access, full admin

developer:
  # Your coder name (as registered with NWP)
  name: yourname

  # Your email address
  email: you@example.com

  # Your role (set by admin during onboarding)
  role: contributor

  # GitLab access level (matches role)
  level: 30

  # Your subdomain (if you have one)
  subdomain: yourname.nwpcode.org

  # Upstream GitLab server
  upstream: git.nwpcode.org

  # Auto-populated fields
  registered: null
  last_sync: null

  # Contribution stats (synced from GitLab)
  contributions:
    commits: 0
    merge_requests: 0
    reviews: 0
    issues_created: 0
    issues_closed: 0
EOF

    echo "Created $DEVELOPER_CONFIG_EXAMPLE"
}

# Export functions
export -f has_developer_config
export -f get_developer_name
export -f get_developer_email
export -f get_developer_role
export -f get_developer_level
export -f get_developer_subdomain
export -f role_to_level
export -f level_to_role
export -f has_level
export -f can_developer
export -f get_developer_capabilities
export -f init_developer_config
export -f set_developer_role
export -f sync_developer_info
export -f show_developer_status
export -f developer_push
export -f developer_merge
