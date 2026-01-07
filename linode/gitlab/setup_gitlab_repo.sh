#!/bin/bash

################################################################################
# setup_gitlab_repo.sh - Set up a repository on NWP GitLab with GitHub mirroring
#
# This script:
#   1. Creates a project on NWP GitLab (git.nwpcode.org)
#   2. Reconfigures git remotes (GitLab as origin, GitHub as mirror)
#   3. Pushes all branches and tags to GitLab
#   4. Configures automatic push mirroring to GitHub
#   5. Generates SSH key for mirroring (if needed)
#   6. Displays instructions for adding deploy key to GitHub
#
# Usage:
#   ./setup_gitlab_repo.sh                    # Auto-detect from current repo
#   ./setup_gitlab_repo.sh myproject          # Specify project name
#   ./setup_gitlab_repo.sh --check            # Check current configuration
#   ./setup_gitlab_repo.sh --help             # Show this help
#
# Prerequisites:
#   - Git repository with GitHub remote configured
#   - SSH access to GitLab server (ssh git-server)
#   - GitLab API token in .secrets.yml
#
################################################################################

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
GITLAB_DOMAIN="git.nwpcode.org"
GITLAB_SSH_HOST="git-server"
GITLAB_USER="nwp"   # GitLab user for project ownership
GITLAB_GROUP="nwp"  # Default GitLab group/namespace for projects

################################################################################
# Helper Functions
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

show_help() {
    sed -n '3,25p' "$0" | sed 's/^# //' | sed 's/^#//'
    exit 0
}

# Get value from .secrets.yml
get_secret() {
    local path="$1"
    local default="${2:-}"
    local secrets_file="${PROJECT_ROOT}/.secrets.yml"

    if [ ! -f "$secrets_file" ]; then
        echo "$default"
        return
    fi

    # Simple YAML parsing for gitlab.api_token format
    local section="${path%%.*}"
    local key="${path#*.}"

    local value=$(awk -v section="$section" -v key="$key" '
        $0 ~ "^" section ":" { in_section = 1; next }
        in_section && /^[a-zA-Z]/ && !/^  / { in_section = 0 }
        in_section && $0 ~ "^  " key ":" {
            sub("^  " key ": *", "")
            gsub(/["'"'"']/, "")
            sub(/ *#.*$/, "")
            gsub(/^[ \t]+|[ \t]+$/, "")
            print
            exit
        }
    ' "$secrets_file")

    if [ -n "$value" ]; then
        echo "$value"
    else
        echo "$default"
    fi
}

################################################################################
# Validation Functions
################################################################################

check_prerequisites() {
    print_header "Checking Prerequisites"

    # Check if in a git repository
    if ! git rev-parse --git-dir > /dev/null 2>&1; then
        print_error "Not in a git repository"
        exit 1
    fi
    print_ok "Git repository detected"

    # Check SSH access to GitLab server
    if ! ssh -o ConnectTimeout=5 "$GITLAB_SSH_HOST" "hostname" > /dev/null 2>&1; then
        print_error "Cannot SSH to GitLab server ($GITLAB_SSH_HOST)"
        print_info "Ensure SSH config has entry for 'git-server' or '$GITLAB_DOMAIN'"
        exit 1
    fi
    print_ok "SSH access to GitLab server"

    # Check for GitLab API token
    GITLAB_TOKEN=$(get_secret "gitlab.api_token" "")
    if [ -z "$GITLAB_TOKEN" ]; then
        print_warning "No GitLab API token in .secrets.yml"
        print_info "Some features (mirroring) may require manual setup"
    else
        print_ok "GitLab API token found"
    fi

    # Check for GitHub remote
    GITHUB_URL=$(git remote get-url origin 2>/dev/null || git remote get-url github 2>/dev/null || echo "")
    if [ -z "$GITHUB_URL" ]; then
        print_warning "No GitHub remote found"
    elif [[ "$GITHUB_URL" == *"github.com"* ]]; then
        print_ok "GitHub remote found: $GITHUB_URL"
    fi
}

################################################################################
# Main Functions
################################################################################

detect_project_name() {
    local name="$1"

    if [ -n "$name" ]; then
        echo "$name"
        return
    fi

    # Try to get from directory name
    name=$(basename "$(pwd)")

    # Or from GitHub remote
    local github_url=$(git remote get-url origin 2>/dev/null || git remote get-url github 2>/dev/null || echo "")
    if [[ "$github_url" == *"github.com"* ]]; then
        name=$(echo "$github_url" | sed 's/.*github.com[:/]\([^/]*\)\/\([^.]*\).*/\2/')
    fi

    echo "$name"
}

create_gitlab_project() {
    local project_name="$1"
    local group="${2:-$GITLAB_GROUP}"

    print_header "Creating GitLab Project"

    # Check if project already exists in the group
    local exists=$(ssh "$GITLAB_SSH_HOST" "sudo gitlab-rails runner \"puts Project.find_by_full_path('${group}/${project_name}')&.full_path || 'not_found'\"" 2>/dev/null)

    if [ "$exists" != "not_found" ] && [ -n "$exists" ]; then
        print_ok "Project already exists: $exists"
        echo "$exists"
        return 0
    fi

    # Ensure group exists
    print_info "Ensuring group exists: $group"
    ssh "$GITLAB_SSH_HOST" "sudo gitlab-rails runner \"
group = Group.find_by_path('$group')
unless group
  group = Group.new(name: '$group', path: '$group', visibility_level: Gitlab::VisibilityLevel::PRIVATE)
  group.save!
  puts 'Created group: $group'
else
  puts 'Group exists: $group'
end
\"" 2>/dev/null

    # Create project in group
    print_info "Creating project: ${group}/${project_name}"
    local result=$(ssh "$GITLAB_SSH_HOST" "sudo gitlab-rails runner \"
user = User.find_by(username: '$GITLAB_USER') || User.find_by(admin: true)
group = Group.find_by_path('$group')
project = Projects::CreateService.new(user, {
  name: '$project_name',
  path: '$project_name',
  namespace_id: group.id,
  visibility_level: Gitlab::VisibilityLevel::PRIVATE,
  description: 'Mirrored from GitHub'
}).execute
puts project.persisted? ? project.full_path : 'ERROR:' + project.errors.full_messages.join(', ')
\"" 2>/dev/null)

    if [[ "$result" == ERROR:* ]]; then
        print_error "Failed to create project: ${result#ERROR:}"
        exit 1
    fi

    print_ok "Created project: $result"
    echo "$result"
}

configure_remotes() {
    local project_path="$1"

    print_header "Configuring Git Remotes"

    local gitlab_url="git@${GITLAB_DOMAIN}:${project_path}.git"
    local current_origin=$(git remote get-url origin 2>/dev/null || echo "")

    # Check if origin is already GitLab
    if [[ "$current_origin" == *"$GITLAB_DOMAIN"* ]]; then
        print_ok "Origin is already GitLab: $current_origin"

        # Check for github remote
        if git remote get-url github > /dev/null 2>&1; then
            print_ok "GitHub remote exists: $(git remote get-url github)"
        fi
        return 0
    fi

    # Check if origin is GitHub
    if [[ "$current_origin" == *"github.com"* ]]; then
        print_info "Current origin is GitHub: $current_origin"

        # Check if github remote already exists
        if git remote get-url github > /dev/null 2>&1; then
            print_warning "Remote 'github' already exists, removing it first"
            git remote remove github
        fi

        # Rename origin to github
        print_info "Renaming 'origin' to 'github'"
        git remote rename origin github
        print_ok "GitHub remote: $(git remote get-url github)"
    fi

    # Add GitLab as origin
    if git remote get-url origin > /dev/null 2>&1; then
        print_info "Updating origin to GitLab"
        git remote set-url origin "$gitlab_url"
    else
        print_info "Adding GitLab as origin"
        git remote add origin "$gitlab_url"
    fi
    print_ok "GitLab origin: $gitlab_url"

    # Show final configuration
    echo ""
    print_info "Remote configuration:"
    git remote -v | sed 's/^/  /'
}

push_to_gitlab() {
    print_header "Pushing to GitLab"

    local current_branch=$(git branch --show-current)

    # Push current branch
    print_info "Pushing branch: $current_branch"
    if GIT_SSH_COMMAND="ssh -o ConnectTimeout=30" git push -u origin "$current_branch" 2>&1; then
        print_ok "Pushed $current_branch"
    else
        print_error "Failed to push $current_branch"
        exit 1
    fi

    # Push all tags
    print_info "Pushing tags"
    if git push origin --tags 2>&1; then
        print_ok "Pushed all tags"
    else
        print_warning "Some tags may have failed to push"
    fi
}

setup_github_mirror() {
    local project_path="$1"
    local github_url="$2"

    print_header "Setting Up GitHub Mirror"

    if [ -z "$GITLAB_TOKEN" ]; then
        print_warning "No GitLab API token - skipping mirror setup"
        print_info "Configure mirror manually at: https://$GITLAB_DOMAIN/$project_path/-/settings/repository"
        return 0
    fi

    if [ -z "$github_url" ]; then
        print_warning "No GitHub URL - skipping mirror setup"
        return 0
    fi

    # Get project ID
    local project_id=$(curl -s --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        "https://$GITLAB_DOMAIN/api/v4/projects?search=$(basename "$project_path")" | \
        python3 -c "import sys, json; projects = json.load(sys.stdin); print(next((p['id'] for p in projects if p['path'] == '$(basename "$project_path")'), ''))" 2>/dev/null)

    if [ -z "$project_id" ]; then
        print_warning "Could not find project ID - skipping mirror setup"
        return 0
    fi

    print_info "Project ID: $project_id"

    # Check for existing mirrors
    local existing=$(curl -s --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        "https://$GITLAB_DOMAIN/api/v4/projects/$project_id/remote_mirrors" 2>/dev/null)

    if [[ "$existing" == *"github.com"* ]]; then
        print_ok "GitHub mirror already configured"
        return 0
    fi

    # Convert GitHub URL to SSH format for mirroring
    local mirror_url="$github_url"
    if [[ "$mirror_url" == git@github.com:* ]]; then
        mirror_url="ssh://git@github.com/${mirror_url#git@github.com:}"
        mirror_url="${mirror_url%.git}.git"
    fi

    # Create push mirror
    print_info "Creating push mirror to: $mirror_url"
    local result=$(curl -s --request POST --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        --header "Content-Type: application/json" \
        --data "{
            \"url\": \"$mirror_url\",
            \"enabled\": true,
            \"only_protected_branches\": false,
            \"keep_divergent_refs\": false
        }" \
        "https://$GITLAB_DOMAIN/api/v4/projects/$project_id/remote_mirrors" 2>/dev/null)

    if [[ "$result" == *"\"id\":"* ]]; then
        print_ok "Push mirror configured"
    else
        print_warning "Mirror setup may have failed: $result"
    fi
}

setup_mirror_ssh_key() {
    print_header "Setting Up Mirror SSH Key"

    # Check if key exists
    local key_exists=$(ssh "$GITLAB_SSH_HOST" "sudo -u git cat /var/opt/gitlab/.ssh/id_ed25519.pub 2>/dev/null || echo 'not_found'")

    if [ "$key_exists" == "not_found" ]; then
        print_info "Generating SSH key for mirroring"
        ssh "$GITLAB_SSH_HOST" "sudo -u git ssh-keygen -t ed25519 -C 'gitlab-mirror@nwpcode.org' -f /var/opt/gitlab/.ssh/id_ed25519 -N '' 2>/dev/null" || true
        key_exists=$(ssh "$GITLAB_SSH_HOST" "sudo -u git cat /var/opt/gitlab/.ssh/id_ed25519.pub 2>/dev/null")
    fi

    # Ensure GitHub is in known_hosts
    ssh "$GITLAB_SSH_HOST" "sudo -u git bash -c 'mkdir -p ~/.ssh && grep -q github.com ~/.ssh/known_hosts 2>/dev/null || ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null'" || true

    print_ok "SSH key ready for GitHub"

    # Display the key
    echo ""
    echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}ACTION REQUIRED: Add this deploy key to GitHub${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "1. Go to your GitHub repository settings:"
    echo -e "   ${BLUE}https://github.com/YOUR_USER/YOUR_REPO/settings/keys${NC}"
    echo ""
    echo "2. Click 'Add deploy key' and enter:"
    echo -e "   Title: ${GREEN}GitLab Mirror ($GITLAB_DOMAIN)${NC}"
    echo ""
    echo "3. Paste this SSH key:"
    echo -e "${GREEN}$key_exists${NC}"
    echo ""
    echo -e "4. ${YELLOW}✓ Check 'Allow write access'${NC}"
    echo ""
    echo "5. Click 'Add key'"
    echo ""
    echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
}

show_status() {
    print_header "Current Configuration"

    echo "Git Remotes:"
    git remote -v | sed 's/^/  /'

    echo ""
    echo "Current Branch: $(git branch --show-current)"

    local token=$(get_secret "gitlab.api_token" "")
    if [ -n "$token" ]; then
        echo ""
        echo "GitLab API: Configured"
    else
        echo ""
        echo "GitLab API: Not configured (add gitlab.api_token to .secrets.yml)"
    fi
}

save_gitlab_token() {
    local token="$1"
    local secrets_file="${PROJECT_ROOT}/.secrets.yml"

    if [ ! -f "$secrets_file" ]; then
        print_warning "No .secrets.yml file found"
        return 1
    fi

    # Check if gitlab.api_token already exists
    if grep -q "api_token:" "$secrets_file" && grep -B5 "api_token:" "$secrets_file" | grep -q "gitlab:"; then
        print_info "Updating existing GitLab API token"
        # This is a simple replacement - for complex YAML, use a proper parser
        sed -i "s|api_token:.*|api_token: \"$token\"|" "$secrets_file"
    else
        print_info "Adding GitLab API token to .secrets.yml"
        # Append to gitlab section
        sed -i "/^gitlab:/a\\  api_token: \"$token\"" "$secrets_file"
    fi

    print_ok "GitLab API token saved"
}

create_gitlab_token() {
    print_header "Creating GitLab API Token"

    local existing_token=$(get_secret "gitlab.api_token" "")
    if [ -n "$existing_token" ]; then
        print_ok "GitLab API token already exists"
        GITLAB_TOKEN="$existing_token"
        return 0
    fi

    print_info "Creating new API token via GitLab Rails console"

    local token=$(ssh "$GITLAB_SSH_HOST" "sudo gitlab-rails runner \"
user = User.find_by(username: '$GITLAB_USER')
existing = user.personal_access_tokens.find_by(name: 'nwp-api')
if existing
  puts 'EXISTS'
else
  token = user.personal_access_tokens.create!(
    name: 'nwp-api',
    scopes: ['api', 'read_api', 'read_repository', 'write_repository'],
    expires_at: 1.year.from_now
  )
  puts token.token
end
\"" 2>/dev/null)

    if [ "$token" == "EXISTS" ]; then
        print_warning "Token 'nwp-api' already exists but value not retrievable"
        print_info "Create a new token manually at: https://$GITLAB_DOMAIN/-/user_settings/personal_access_tokens"
        return 1
    elif [ -n "$token" ]; then
        print_ok "Created API token"
        save_gitlab_token "$token"
        GITLAB_TOKEN="$token"
    else
        print_error "Failed to create API token"
        return 1
    fi
}

################################################################################
# Main
################################################################################

main() {
    local project_name=""
    local check_only=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --check|-c)
                check_only=true
                shift
                ;;
            --help|-h)
                show_help
                ;;
            *)
                project_name="$1"
                shift
                ;;
        esac
    done

    echo "========================================"
    echo "  GitLab Repository Setup"
    echo "========================================"

    if $check_only; then
        show_status
        exit 0
    fi

    # Run setup
    check_prerequisites

    # Detect project name
    project_name=$(detect_project_name "$project_name")
    print_info "Project name: $project_name"

    # Get GitHub URL before we modify remotes
    GITHUB_URL=$(git remote get-url origin 2>/dev/null || git remote get-url github 2>/dev/null || echo "")
    if [[ "$GITHUB_URL" != *"github.com"* ]]; then
        GITHUB_URL=""
    fi

    # Create or get GitLab API token
    create_gitlab_token || true

    # Create GitLab project
    local project_path=$(create_gitlab_project "$project_name")

    # Configure remotes
    configure_remotes "$project_path"

    # Push to GitLab
    push_to_gitlab

    # Setup GitHub mirroring
    if [ -n "$GITHUB_URL" ]; then
        setup_github_mirror "$project_path" "$GITHUB_URL"
        setup_mirror_ssh_key
    else
        print_warning "No GitHub remote found - skipping mirror setup"
    fi

    # Final status
    echo ""
    echo "========================================"
    echo -e "  ${GREEN}Setup Complete!${NC}"
    echo "========================================"
    echo ""
    echo "GitLab URL: https://$GITLAB_DOMAIN/$project_path"
    echo ""
    echo "Workflow:"
    echo "  git push origin main     # Push to GitLab (auto-mirrors to GitHub)"
    echo "  git push github main     # Push directly to GitHub"
    echo ""

    if [ -n "$GITHUB_URL" ]; then
        echo -e "${YELLOW}Remember: Add the deploy key to GitHub to enable auto-mirroring${NC}"
    fi
}

main "$@"
