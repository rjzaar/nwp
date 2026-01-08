#!/bin/bash

################################################################################
# NWP Git Library
#
# Git backup and sync functions for NWP scripts
# Source this file: source "$SCRIPT_DIR/lib/git.sh"
#
# Dependencies: lib/ui.sh, lib/common.sh
################################################################################

# Get NWP GitLab URL from cnwp.yml settings.url
# Returns: git.domain.org format
get_gitlab_url() {
    local cnwp_file="${PROJECT_ROOT}/cnwp.yml"

    if [ ! -f "$cnwp_file" ]; then
        echo ""
        return 1
    fi

    # Extract url from settings section
    local url=$(awk '
        /^settings:/ { in_settings = 1; next }
        in_settings && /^[a-zA-Z]/ && !/^  / { in_settings = 0 }
        in_settings && /^  url:/ {
            sub("^  url: *", "")
            sub(/#.*/, "")        # Remove inline comments
            gsub(/["'"'"']/, "")  # Remove quotes
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")  # Trim whitespace
            if (length($0) > 0) print
            exit
        }
    ' "$cnwp_file")

    if [ -n "$url" ]; then
        echo "git.$url"
    else
        echo ""
        return 1
    fi
}

# Get GitLab SSH host from .secrets.yml or derive from settings
# Returns: IP address or hostname for SSH
get_gitlab_ssh_host() {
    local secrets_file="${PROJECT_ROOT}/.secrets.yml"

    if [ -f "$secrets_file" ]; then
        # Try to get IP from secrets
        local ip=$(awk '
            /^gitlab:/ { in_gitlab = 1; next }
            in_gitlab && /^[a-zA-Z]/ && !/^  / { in_gitlab = 0 }
            in_gitlab && /^  server:/ { in_server = 1; next }
            in_server && /^    ip:/ {
                sub("^    ip: *", "")
                gsub(/["'"'"']/, "")
                print
                exit
            }
        ' "$secrets_file")

        if [ -n "$ip" ]; then
            echo "$ip"
            return 0
        fi
    fi

    # Fallback to domain
    get_gitlab_url
}

# Check if git-server SSH alias is configured
check_git_server_alias() {
    if ssh -o BatchMode=yes -o ConnectTimeout=5 git-server exit 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

################################################################################
# Additional Remote Support (P13)
################################################################################

# Get additional remotes from cnwp.yml
# Returns: remote configurations as "name|url|enabled" per line
get_additional_remotes() {
    local cnwp_file="${PROJECT_ROOT}/cnwp.yml"

    if [ ! -f "$cnwp_file" ]; then
        return 1
    fi

    # Parse additional_remotes from git_backup section
    awk '
        /^git_backup:/ { in_git_backup = 1; next }
        in_git_backup && /^[a-zA-Z]/ && !/^  / { in_git_backup = 0 }
        in_git_backup && /^  additional_remotes:/ { in_remotes = 1; next }
        in_remotes && /^  [a-zA-Z]/ && !/^    / { in_remotes = 0 }
        in_remotes && /^    [a-zA-Z_]+:/ {
            remote_name = $0
            gsub(/^    /, "", remote_name)
            gsub(/:.*/, "", remote_name)
            next
        }
        in_remotes && remote_name && /url:/ {
            url = $0
            gsub(/.*url: */, "", url)
            gsub(/["'"'"']/, "", url)
            urls[remote_name] = url
        }
        in_remotes && remote_name && /path:/ {
            path = $0
            gsub(/.*path: */, "", path)
            gsub(/["'"'"']/, "", path)
            paths[remote_name] = path
        }
        in_remotes && remote_name && /enabled:/ {
            enabled = $0
            gsub(/.*enabled: */, "", enabled)
            gsub(/["'"'"']/, "", enabled)
            enableds[remote_name] = enabled
        }
        END {
            for (name in urls) {
                enabled = (enableds[name] == "true" || enableds[name] == "yes") ? "true" : "false"
                print name "|" urls[name] "|" enabled
            }
            for (name in paths) {
                if (!(name in urls)) {
                    enabled = (enableds[name] == "true" || enableds[name] == "yes") ? "true" : "false"
                    print name "|" paths[name] "|" enabled
                }
            }
        }
    ' "$cnwp_file"
}

# Add additional remote to repository
# Usage: git_add_remote "/path/to/repo" "remote-name" "url"
git_add_remote() {
    local repo_path="$1"
    local remote_name="$2"
    local remote_url="$3"

    if [ ! -d "$repo_path/.git" ]; then
        print_error "Not a git repository: $repo_path"
        return 1
    fi

    cd "$repo_path" || return 1

    # Check if remote already exists
    if git remote get-url "$remote_name" &>/dev/null; then
        # Update URL if different
        local current_url=$(git remote get-url "$remote_name")
        if [ "$current_url" != "$remote_url" ]; then
            git remote set-url "$remote_name" "$remote_url"
            ocmsg "Updated remote '$remote_name' URL"
        fi
    else
        # Add new remote
        git remote add "$remote_name" "$remote_url"
        print_status "OK" "Added remote: $remote_name -> $remote_url"
    fi

    cd - > /dev/null
    return 0
}

# Push to all configured remotes
# Usage: git_push_all "/path/to/repo" "branch"
git_push_all() {
    local repo_path="$1"
    local branch="${2:-backup}"
    local project_name="${3:-}"
    local group="${4:-$(get_gitlab_default_group)}"

    # First, push to primary (origin/NWP GitLab)
    if ! git_push "$repo_path" "$branch" "$project_name" "$group"; then
        print_warning "Primary push failed"
    fi

    # Get additional remotes
    local remotes=$(get_additional_remotes)

    if [ -z "$remotes" ]; then
        return 0
    fi

    cd "$repo_path" || return 1

    # Push to each enabled additional remote
    echo "$remotes" | while IFS='|' read -r name url enabled; do
        if [ "$enabled" != "true" ]; then
            ocmsg "Skipping disabled remote: $name"
            continue
        fi

        # Add remote if not exists
        if ! git remote get-url "$name" &>/dev/null; then
            git remote add "$name" "$url"
            ocmsg "Added remote: $name"
        fi

        # Push to remote (continue on failure for additional remotes)
        print_info "Pushing to $name..."
        if git push "$name" "$branch" 2>&1; then
            print_status "OK" "Pushed to $name"
        else
            print_warning "Failed to push to $name (continuing...)"
        fi
    done

    cd - > /dev/null
    return 0
}

# Setup local bare repository for backup
# Usage: git_setup_local_bare "/path/to/bare/repo.git"
git_setup_local_bare() {
    local bare_path="$1"

    if [ -d "$bare_path" ]; then
        if [ -f "$bare_path/HEAD" ]; then
            ocmsg "Bare repository already exists: $bare_path"
            return 0
        fi
    fi

    # Create bare repository
    mkdir -p "$bare_path"
    if git init --bare "$bare_path"; then
        print_status "OK" "Created bare repository: $bare_path"
        return 0
    else
        print_error "Failed to create bare repository"
        return 1
    fi
}

# Configure remotes from cnwp.yml for a repository
# Usage: git_configure_remotes "/path/to/repo" "project-name"
git_configure_remotes() {
    local repo_path="$1"
    local project_name="$2"

    if [ ! -d "$repo_path/.git" ]; then
        print_error "Not a git repository: $repo_path"
        return 1
    fi

    # Get additional remotes
    local remotes=$(get_additional_remotes)

    if [ -z "$remotes" ]; then
        ocmsg "No additional remotes configured"
        return 0
    fi

    echo "$remotes" | while IFS='|' read -r name url enabled; do
        if [ "$enabled" != "true" ]; then
            continue
        fi

        # Replace placeholders in URL
        local final_url="$url"
        final_url="${final_url//\{project\}/$project_name}"
        final_url="${final_url//\{PROJECT\}/$project_name}"

        # If it's a path (local repo), ensure it exists
        if [[ "$final_url" == /* ]]; then
            local bare_path="${final_url%.git}.git"
            if [ ! -d "$bare_path" ]; then
                git_setup_local_bare "$bare_path"
            fi
            final_url="$bare_path"
        fi

        git_add_remote "$repo_path" "$name" "$final_url"
    done

    return 0
}

################################################################################
# Basic Git Operations
################################################################################

# Initialize git repository (wrapper for git_init_repo)
# Usage: git_init "/path/to/repo"
git_init() {
    local repo_path="$1"
    git_init_repo "$repo_path"
}

# Commit changes for backup purposes
# Usage: git_commit_backup "/path/to/repo" "sitename" ["message"]
git_commit_backup() {
    local repo_path="$1"
    local sitename="$2"
    local message="${3:-Backup of $sitename $(date +%Y-%m-%d\ %H:%M:%S)}"

    git_commit "$repo_path" "$message"
}

################################################################################
# GitLab API Automation (P15)
################################################################################

# Get default GitLab group from cnwp.yml
# Returns: group name (default: nwp)
get_gitlab_default_group() {
    local cnwp_file="${PROJECT_ROOT}/cnwp.yml"
    local default_group="nwp"

    if [ ! -f "$cnwp_file" ]; then
        echo "$default_group"
        return
    fi

    # Parse settings.gitlab.default_group
    local group=$(awk '
        /^settings:/ { in_settings = 1; next }
        in_settings && /^[a-zA-Z]/ && !/^  / { in_settings = 0 }
        in_settings && /^  gitlab:/ { in_gitlab = 1; next }
        in_gitlab && /^  [a-zA-Z]/ && !/^    / { in_gitlab = 0 }
        in_gitlab && /^    default_group:/ {
            sub("^    default_group: *", "")
            gsub(/["'"'"']/, "")
            print
            exit
        }
    ' "$cnwp_file")

    if [ -n "$group" ]; then
        echo "$group"
    else
        echo "$default_group"
    fi
}

# Get GitLab API token from .secrets.yml
# Usage: get_gitlab_token
get_gitlab_token() {
    local secrets_file="${PROJECT_ROOT}/.secrets.yml"

    if [ ! -f "$secrets_file" ]; then
        return 1
    fi

    awk '
        /^gitlab:/ { in_gitlab = 1; next }
        in_gitlab && /^[a-zA-Z]/ && !/^  / { in_gitlab = 0 }
        in_gitlab && /^  api_token:/ {
            sub("^  api_token: *", "")
            gsub(/["'"'"']/, "")
            print
            exit
        }
        in_gitlab && /^  token:/ {
            sub("^  token: *", "")
            gsub(/["'"'"']/, "")
            print
            exit
        }
    ' "$secrets_file"
}

# Create GitLab project via API
# Usage: gitlab_api_create_project "project-name" "group" ["description"]
gitlab_api_create_project() {
    local project_name="$1"
    local group="${2:-$(get_gitlab_default_group)}"
    local description="${3:-NWP managed project}"

    local gitlab_url=$(get_gitlab_url)
    local token=$(get_gitlab_token)

    if [ -z "$gitlab_url" ]; then
        print_warning "GitLab URL not configured"
        return 1
    fi

    if [ -z "$token" ]; then
        # Fallback to SSH method
        ocmsg "No API token, using SSH method"
        gitlab_create_project "$project_name" "$group"
        return $?
    fi

    local api_url="https://${gitlab_url}/api/v4"

    # First, get the group ID
    local group_id
    group_id=$(curl -s --header "PRIVATE-TOKEN: $token" \
        "${api_url}/groups?search=${group}" | \
        grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')

    if [ -z "$group_id" ]; then
        print_warning "Group '$group' not found, creating..."
        # Create the group
        local group_response
        group_response=$(curl -s --header "PRIVATE-TOKEN: $token" \
            --header "Content-Type: application/json" \
            --data "{\"name\":\"${group}\",\"path\":\"${group}\",\"visibility\":\"private\"}" \
            "${api_url}/groups")

        group_id=$(echo "$group_response" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')

        if [ -z "$group_id" ]; then
            print_error "Failed to create group: $group"
            return 1
        fi
        print_status "OK" "Created group: $group (ID: $group_id)"
    fi

    # Check if project exists
    local existing
    existing=$(curl -s --header "PRIVATE-TOKEN: $token" \
        "${api_url}/groups/${group_id}/projects?search=${project_name}" | \
        grep -o "\"path\":\"${project_name}\"")

    if [ -n "$existing" ]; then
        ocmsg "Project already exists: ${group}/${project_name}"
        return 0
    fi

    # Create the project
    local response
    response=$(curl -s --header "PRIVATE-TOKEN: $token" \
        --header "Content-Type: application/json" \
        --data "{
            \"name\":\"${project_name}\",
            \"path\":\"${project_name}\",
            \"namespace_id\":${group_id},
            \"visibility\":\"private\",
            \"description\":\"${description}\",
            \"initialize_with_readme\":false
        }" \
        "${api_url}/projects")

    if echo "$response" | grep -q "\"id\":[0-9]*"; then
        local new_id=$(echo "$response" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')
        print_status "OK" "Created project: ${group}/${project_name} (ID: $new_id)"
        return 0
    else
        local error=$(echo "$response" | grep -o '"message":"[^"]*"' | head -1)
        print_error "Failed to create project: $error"
        return 1
    fi
}

# Delete GitLab project via API
# Usage: gitlab_api_delete_project "project-name" "group"
gitlab_api_delete_project() {
    local project_name="$1"
    local group="${2:-$(get_gitlab_default_group)}"

    local gitlab_url=$(get_gitlab_url)
    local token=$(get_gitlab_token)

    if [ -z "$token" ]; then
        print_error "API token required for deletion"
        return 1
    fi

    local api_url="https://${gitlab_url}/api/v4"
    local project_path="${group}/${project_name}"
    local encoded_path=$(echo "$project_path" | sed 's/\//%2F/g')

    local response
    response=$(curl -s --request DELETE \
        --header "PRIVATE-TOKEN: $token" \
        "${api_url}/projects/${encoded_path}")

    if [ -z "$response" ] || echo "$response" | grep -q '"message":"202 Accepted"'; then
        print_status "OK" "Deleted project: ${project_path}"
        return 0
    else
        print_error "Failed to delete project: $response"
        return 1
    fi
}

# List GitLab projects in a group
# Usage: gitlab_api_list_projects "group"
gitlab_api_list_projects() {
    local group="${1:-$(get_gitlab_default_group)}"

    local gitlab_url=$(get_gitlab_url)
    local token=$(get_gitlab_token)

    if [ -z "$token" ]; then
        print_error "API token required"
        return 1
    fi

    local api_url="https://${gitlab_url}/api/v4"

    # Get group ID
    local group_id
    group_id=$(curl -s --header "PRIVATE-TOKEN: $token" \
        "${api_url}/groups?search=${group}" | \
        grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')

    if [ -z "$group_id" ]; then
        print_error "Group not found: $group"
        return 1
    fi

    # List projects
    curl -s --header "PRIVATE-TOKEN: $token" \
        "${api_url}/groups/${group_id}/projects?per_page=100" | \
        grep -o '"path":"[^"]*"' | sed 's/"path":"//g; s/"//g' | sort
}

# Configure GitLab project settings
# Usage: gitlab_api_configure_project "project-name" "group"
gitlab_api_configure_project() {
    local project_name="$1"
    local group="${2:-$(get_gitlab_default_group)}"

    local gitlab_url=$(get_gitlab_url)
    local token=$(get_gitlab_token)

    if [ -z "$token" ]; then
        print_warning "API token required for configuration"
        return 1
    fi

    local api_url="https://${gitlab_url}/api/v4"
    local project_path="${group}/${project_name}"
    local encoded_path=$(echo "$project_path" | sed 's/\//%2F/g')

    # Configure project settings
    local response
    response=$(curl -s --request PUT \
        --header "PRIVATE-TOKEN: $token" \
        --header "Content-Type: application/json" \
        --data '{
            "only_allow_merge_if_pipeline_succeeds": true,
            "remove_source_branch_after_merge": true,
            "auto_devops_enabled": false,
            "ci_config_path": ".gitlab-ci.yml"
        }' \
        "${api_url}/projects/${encoded_path}")

    if echo "$response" | grep -q "\"id\":[0-9]*"; then
        print_status "OK" "Configured project settings"
        return 0
    else
        print_warning "Could not configure project settings"
        return 1
    fi
}

# Unprotect default branch to allow force push for backups
# Usage: gitlab_api_unprotect_branch "project-name" "group" "branch"
gitlab_api_unprotect_branch() {
    local project_name="$1"
    local group="${2:-$(get_gitlab_default_group)}"
    local branch="${3:-main}"

    local gitlab_url=$(get_gitlab_url)
    local token=$(get_gitlab_token)

    if [ -z "$token" ]; then
        return 1
    fi

    local api_url="https://${gitlab_url}/api/v4"
    local project_path="${group}/${project_name}"
    local encoded_path=$(echo "$project_path" | sed 's/\//%2F/g')

    # Remove branch protection
    curl -s --request DELETE \
        --header "PRIVATE-TOKEN: $token" \
        "${api_url}/projects/${encoded_path}/protected_branches/${branch}" > /dev/null 2>&1

    ocmsg "Removed branch protection for $branch"
    return 0
}

# Initialize git repository if not exists
# Usage: git_init_repo "/path/to/repo" "repo-name"
git_init_repo() {
    local repo_path="$1"
    local repo_name="${2:-backup}"

    if [ ! -d "$repo_path" ]; then
        mkdir -p "$repo_path"
    fi

    if [ ! -d "$repo_path/.git" ]; then
        ocmsg "Initializing git repository in $repo_path"
        cd "$repo_path" || return 1
        git init -q
        git config user.email "nwp@localhost"
        git config user.name "NWP Backup"
        print_status "OK" "Git repository initialized"
        cd - > /dev/null
        return 0
    else
        ocmsg "Git repository already exists in $repo_path"
        return 0
    fi
}

# Create standard .gitignore for backup directories
# Usage: git_create_gitignore "/path/to/repo" "db|files|site"
git_create_gitignore() {
    local repo_path="$1"
    local backup_type="${2:-db}"
    local gitignore_file="$repo_path/.gitignore"

    case "$backup_type" in
        db)
            cat > "$gitignore_file" << 'EOF'
# NWP Database Backup .gitignore
# Ignore temporary files
*.tmp
*.temp
*.log

# Keep SQL files
!*.sql
!*.sql.gz
EOF
            ;;
        files)
            cat > "$gitignore_file" << 'EOF'
# NWP Files Backup .gitignore
# Ignore temporary files
*.tmp
*.temp
*.log

# Keep archives
!*.tar.gz
!*.zip
EOF
            ;;
        site)
            cat > "$gitignore_file" << 'EOF'
# NWP Site .gitignore
# Drupal specific
web/sites/*/files/*
web/sites/*/private/*
!web/sites/*/files/.gitkeep
private/*
!private/.gitkeep

# Composer
/vendor/

# DDEV
.ddev/.gitignore
.ddev/db_snapshots/
.ddev/.webimageBuild/
.ddev/.dbimageBuild/
.ddev/mutagen/
.ddev/.homeadditions/
.ddev/sequelpro.spf

# IDE
.idea/
.vscode/
*.sublime-*

# OS
.DS_Store
Thumbs.db

# Temporary
*.tmp
*.temp
*.log
*.cache
EOF
            ;;
    esac

    ocmsg "Created .gitignore for $backup_type backup"
}

# Setup GitLab remote for repository
# Usage: git_setup_remote "/path/to/repo" "project-name" "group"
git_setup_remote() {
    local repo_path="$1"
    local project_name="$2"
    local group="${3:-$(get_gitlab_default_group)}"

    local gitlab_domain=$(get_gitlab_url)

    if [ -z "$gitlab_domain" ]; then
        print_warning "GitLab domain not configured, skipping remote setup"
        return 1
    fi

    cd "$repo_path" || return 1

    # Check if origin remote exists
    if git remote get-url origin &>/dev/null; then
        ocmsg "Remote 'origin' already configured"
    else
        # GitLab uses 'git' user for SSH repo access (not 'gitlab' which is for admin)
        local remote_url="git@${gitlab_domain}:${group}/${project_name}.git"

        git remote add origin "$remote_url"
        print_status "OK" "Remote configured: $remote_url"
    fi

    cd - > /dev/null
    return 0
}

# Add all files and commit
# Usage: git_commit "/path/to/repo" "commit message"
git_commit() {
    local repo_path="$1"
    local message="${2:-Backup $(date +%Y-%m-%d\ %H:%M:%S)}"

    cd "$repo_path" || return 1

    # Add all files
    git add -A

    # Check if there are changes to commit
    if git diff --cached --quiet; then
        print_info "No changes to commit"
        cd - > /dev/null
        return 0
    fi

    # Commit
    if git commit -q -m "$message"; then
        local commit_hash=$(git rev-parse --short HEAD)
        print_status "OK" "Committed: $commit_hash - $message"
    else
        print_error "Failed to commit"
        cd - > /dev/null
        return 1
    fi

    cd - > /dev/null
    return 0
}

# Create GitLab project via rails runner (requires SSH access)
# Usage: gitlab_create_project "project-name" "group"
gitlab_create_project() {
    local project_name="$1"
    local group="${2:-$(get_gitlab_default_group)}"

    ocmsg "Creating GitLab project: $group/$project_name"

    # Check if we can SSH to gitlab server
    if ! ssh -o BatchMode=yes -o ConnectTimeout=5 gitlab@git.nwpcode.org exit 2>/dev/null; then
        print_warning "Cannot SSH to GitLab server to create project"
        return 1
    fi

    # Create project via gitlab-rails runner
    local result=$(ssh gitlab@git.nwpcode.org "sudo gitlab-rails runner \"
        g = Group.find_by(path: '$group')
        if g.nil?
            puts 'GROUP_NOT_FOUND'
        else
            p = Project.find_by(path: '$project_name', namespace_id: g.id)
            if p.nil?
                p = Project.new(name: '$project_name', path: '$project_name', namespace_id: g.id, visibility_level: 0)
                if p.save
                    puts 'CREATED'
                else
                    puts 'ERROR: ' + p.errors.full_messages.join(', ')
                end
            else
                puts 'EXISTS'
            end
        end
    \"" 2>&1)

    case "$result" in
        CREATED)
            print_status "OK" "GitLab project created: $group/$project_name"
            return 0
            ;;
        EXISTS)
            ocmsg "GitLab project already exists: $group/$project_name"
            return 0
            ;;
        GROUP_NOT_FOUND)
            print_error "GitLab group '$group' not found"
            return 1
            ;;
        *)
            print_warning "GitLab project creation result: $result"
            return 1
            ;;
    esac
}

# Push to remote
# Usage: git_push "/path/to/repo" ["branch"] ["project_name"] ["group"]
git_push() {
    local repo_path="$1"
    local branch="${2:-main}"
    local project_name="${3:-}"
    local group="${4:-$(get_gitlab_default_group)}"

    cd "$repo_path" || return 1

    # Check if remote is configured
    if ! git remote get-url origin &>/dev/null; then
        print_warning "No remote configured, skipping push"
        cd - > /dev/null
        return 0
    fi

    # Ensure we're on the right branch
    local current_branch=$(git branch --show-current)
    if [ "$current_branch" != "$branch" ]; then
        # Check if branch exists
        if git show-ref --verify --quiet "refs/heads/$branch"; then
            git checkout -q "$branch"
        else
            git checkout -q -b "$branch"
        fi
    fi

    # Push with set-upstream on first push
    # Use --force for backup repos since local is source of truth
    print_info "Pushing to remote..."
    if git push -u --force origin "$branch" 2>&1; then
        print_status "OK" "Pushed to origin/$branch"
        cd - > /dev/null
        return 0
    fi

    # If push fails, try to create the project first
    if [ -n "$project_name" ]; then
        print_info "Attempting to create GitLab project..."
        if gitlab_create_project "$project_name" "$group"; then
            # Retry push
            if git push -u --force origin "$branch" 2>&1; then
                print_status "OK" "Pushed to origin/$branch"
                cd - > /dev/null
                return 0
            fi
        fi
    fi

    print_warning "Push failed - check GitLab project permissions"
    cd - > /dev/null
    return 1
}

# Full git backup workflow
# Usage: git_backup "/path/to/backup/dir" "sitename" "backup-type" "message"
git_backup() {
    local backup_dir="$1"
    local sitename="$2"
    local backup_type="${3:-db}"  # db, files, or site
    local message="${4:-Backup}"
    local group="backups"

    print_header "Git Backup"

    # Determine project name based on backup type
    local project_name
    case "$backup_type" in
        db)
            project_name="${sitename}-db"
            ;;
        files)
            project_name="${sitename}-files"
            ;;
        site)
            project_name="${sitename}"
            ;;
        *)
            project_name="${sitename}-${backup_type}"
            ;;
    esac

    # Initialize repo if needed
    if ! git_init_repo "$backup_dir" "$project_name"; then
        print_error "Failed to initialize git repository"
        return 1
    fi

    # Create .gitignore if not exists
    if [ ! -f "$backup_dir/.gitignore" ]; then
        git_create_gitignore "$backup_dir" "$backup_type"
    fi

    # Setup remote if not configured
    git_setup_remote "$backup_dir" "$project_name" "$group"

    # Commit changes
    if ! git_commit "$backup_dir" "$message"; then
        return 1
    fi

    # Push to remote (with auto-create project)
    # Use 'backup' branch to avoid GitLab's main branch protection
    git_push "$backup_dir" "backup" "$project_name" "$group"

    return 0
}

################################################################################
# GitLab Composer Package Registry
#
# Enables publishing and consuming Composer packages via GitLab's Package
# Registry. This allows private Drupal profiles, modules, and themes to be
# managed as proper Composer dependencies.
#
# Usage:
#   1. Publish a package:
#      gitlab_composer_publish "/path/to/package" "v1.0.0"
#
#   2. Configure a project to use the registry:
#      gitlab_composer_configure_client "/path/to/project"
#
# See: https://docs.gitlab.com/user/packages/composer_repository/
################################################################################

# Get GitLab group ID by name
# Usage: gitlab_get_group_id "group-name"
gitlab_get_group_id() {
    local group_name="$1"

    local gitlab_url=$(get_gitlab_url)
    local token=$(get_gitlab_token)

    if [ -z "$gitlab_url" ] || [ -z "$token" ]; then
        return 1
    fi

    local api_url="https://${gitlab_url}/api/v4"

    curl -s --header "PRIVATE-TOKEN: $token" \
        "${api_url}/groups?search=${group_name}" | \
        grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*'
}

# Get GitLab project ID by path (e.g., "root/avc")
# Usage: gitlab_get_project_id "group/project"
gitlab_get_project_id() {
    local project_path="$1"

    local gitlab_url=$(get_gitlab_url)
    local token=$(get_gitlab_token)

    if [ -z "$gitlab_url" ] || [ -z "$token" ]; then
        return 1
    fi

    local api_url="https://${gitlab_url}/api/v4"
    local encoded_path=$(echo "$project_path" | sed 's/\//%2F/g')

    curl -s --header "PRIVATE-TOKEN: $token" \
        "${api_url}/projects/${encoded_path}" | \
        grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*'
}

# Publish a Composer package to GitLab Package Registry
# Usage: gitlab_composer_publish "/path/to/package" "tag-or-branch" ["project-path"]
#
# The package must have a valid composer.json with name and version fields.
# If project-path is not provided, it's derived from composer.json name.
#
# Example:
#   gitlab_composer_publish "/home/rob/avcgs" "v1.0.0" "root/avc"
#
gitlab_composer_publish() {
    local package_path="$1"
    local ref="$2"
    local project_path="${3:-}"

    local gitlab_url=$(get_gitlab_url)
    local token=$(get_gitlab_token)

    if [ -z "$gitlab_url" ]; then
        print_error "GitLab URL not configured"
        return 1
    fi

    if [ -z "$token" ]; then
        print_error "GitLab API token required for publishing"
        return 1
    fi

    # Validate composer.json exists
    if [ ! -f "$package_path/composer.json" ]; then
        print_error "No composer.json found in $package_path"
        return 1
    fi

    # Get package name from composer.json
    local package_name=$(grep '"name"' "$package_path/composer.json" | head -1 | \
        sed 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')

    if [ -z "$package_name" ]; then
        print_error "Could not determine package name from composer.json"
        return 1
    fi

    # Derive project path if not provided
    if [ -z "$project_path" ]; then
        # Try to get from git remote
        cd "$package_path" || return 1
        local remote_url=$(git remote get-url origin 2>/dev/null)
        if [[ "$remote_url" == *"$gitlab_url"* ]]; then
            # Extract path from git URL (git@host:path.git or https://host/path.git)
            project_path=$(echo "$remote_url" | sed -E 's/.*[:/]([^/]+\/[^/]+)(\.git)?$/\1/')
        fi
        cd - > /dev/null
    fi

    if [ -z "$project_path" ]; then
        print_error "Could not determine project path. Please provide it explicitly."
        return 1
    fi

    # Get project ID
    local project_id=$(gitlab_get_project_id "$project_path")
    if [ -z "$project_id" ]; then
        print_error "Project not found: $project_path"
        return 1
    fi

    local api_url="https://${gitlab_url}/api/v4"

    print_info "Publishing $package_name ($ref) to GitLab Package Registry..."

    # Determine if ref is a tag or branch
    local ref_type="tag"
    cd "$package_path" || return 1
    if ! git rev-parse "refs/tags/$ref" &>/dev/null; then
        ref_type="branch"
    fi
    cd - > /dev/null

    # Publish to Package Registry
    local response
    response=$(curl -s --fail-with-body \
        --header "PRIVATE-TOKEN: $token" \
        --data "${ref_type}=${ref}" \
        "${api_url}/projects/${project_id}/packages/composer")

    # Check for success - package_id in response or 201 Created status
    if echo "$response" | grep -q '"package_id"'; then
        local pkg_id=$(echo "$response" | grep -o '"package_id":[0-9]*' | grep -o '[0-9]*')
        print_status "OK" "Published $package_name to GitLab Package Registry (ID: $pkg_id)"
        return 0
    elif echo "$response" | grep -q '201 Created'; then
        # Some GitLab versions return just the status message
        print_status "OK" "Published $package_name to GitLab Package Registry"
        return 0
    elif echo "$response" | grep -q '"message"'; then
        local error=$(echo "$response" | grep -o '"message":"[^"]*"' | sed 's/"message":"//' | sed 's/"$//')
        # Check if it's an error or just a status message
        if [[ "$error" == *"Created"* ]] || [[ "$error" == *"success"* ]]; then
            print_status "OK" "Published $package_name to GitLab Package Registry"
            return 0
        fi
        print_error "Failed to publish: $error"
        return 1
    else
        print_error "Failed to publish package: $response"
        return 1
    fi
}

# List packages in GitLab Package Registry
# Usage: gitlab_composer_list ["project-path"]
gitlab_composer_list() {
    local project_path="${1:-}"

    local gitlab_url=$(get_gitlab_url)
    local token=$(get_gitlab_token)

    if [ -z "$gitlab_url" ] || [ -z "$token" ]; then
        print_error "GitLab URL and token required"
        return 1
    fi

    local api_url="https://${gitlab_url}/api/v4"

    if [ -n "$project_path" ]; then
        # List packages for specific project
        local project_id=$(gitlab_get_project_id "$project_path")
        if [ -z "$project_id" ]; then
            print_error "Project not found: $project_path"
            return 1
        fi

        print_info "Packages in $project_path:"
        curl -s --header "PRIVATE-TOKEN: $token" \
            "${api_url}/projects/${project_id}/packages?package_type=composer" | \
            grep -o '"name":"[^"]*","version":"[^"]*"' | \
            sed 's/"name":"//; s/","version":"/:/; s/"$//' | sort -u
    else
        # List all packages in all groups
        print_info "All Composer packages:"
        curl -s --header "PRIVATE-TOKEN: $token" \
            "${api_url}/packages?package_type=composer" | \
            grep -o '"name":"[^"]*","version":"[^"]*"' | \
            sed 's/"name":"//; s/","version":"/:/; s/"$//' | sort -u
    fi
}

# Create a deploy token for Composer registry access
# Usage: gitlab_composer_create_deploy_token "project-path" "token-name"
# Returns: The deploy token value (save it - it won't be shown again!)
gitlab_composer_create_deploy_token() {
    local project_path="$1"
    local token_name="${2:-composer-deploy}"

    local gitlab_url=$(get_gitlab_url)
    local token=$(get_gitlab_token)

    if [ -z "$gitlab_url" ] || [ -z "$token" ]; then
        print_error "GitLab URL and token required"
        return 1
    fi

    local project_id=$(gitlab_get_project_id "$project_path")
    if [ -z "$project_id" ]; then
        print_error "Project not found: $project_path"
        return 1
    fi

    local api_url="https://${gitlab_url}/api/v4"

    # Create deploy token with read_package_registry scope
    local response
    response=$(curl -s --header "PRIVATE-TOKEN: $token" \
        --header "Content-Type: application/json" \
        --data "{
            \"name\": \"${token_name}\",
            \"scopes\": [\"read_package_registry\"]
        }" \
        "${api_url}/projects/${project_id}/deploy_tokens")

    if echo "$response" | grep -q '"token"'; then
        local deploy_token=$(echo "$response" | grep -o '"token":"[^"]*"' | sed 's/"token":"//; s/"$//')
        print_status "OK" "Deploy token created: $token_name"
        echo ""
        echo "Token value (save this - it won't be shown again!):"
        echo "$deploy_token"
        return 0
    else
        local error=$(echo "$response" | grep -o '"message":"[^"]*"' | head -1)
        print_error "Failed to create deploy token: $error"
        return 1
    fi
}

# Configure a Composer project to use GitLab Package Registry
# Usage: gitlab_composer_configure_client "/path/to/project" "group-id-or-name"
#
# This adds the GitLab Composer repository to the project's composer.json
# and configures authentication.
#
gitlab_composer_configure_client() {
    local project_path="$1"
    local group="${2:-root}"

    local gitlab_url=$(get_gitlab_url)
    local token=$(get_gitlab_token)

    if [ -z "$gitlab_url" ]; then
        print_error "GitLab URL not configured"
        return 1
    fi

    if [ ! -f "$project_path/composer.json" ]; then
        print_error "No composer.json found in $project_path"
        return 1
    fi

    # Get group ID if name was provided
    local group_id="$group"
    if ! [[ "$group" =~ ^[0-9]+$ ]]; then
        group_id=$(gitlab_get_group_id "$group")
        if [ -z "$group_id" ]; then
            print_error "Group not found: $group"
            return 1
        fi
    fi

    local repo_url="https://${gitlab_url}/api/v4/group/${group_id}/-/packages/composer/packages.json"

    cd "$project_path" || return 1

    # Check if repository already configured
    if grep -q "$repo_url" composer.json 2>/dev/null; then
        print_status "OK" "GitLab Composer repository already configured"
        cd - > /dev/null
        return 0
    fi

    print_info "Adding GitLab Composer repository to composer.json..."

    # Add repository using composer command
    if command -v composer &>/dev/null; then
        composer config repositories.gitlab composer "$repo_url"
        print_status "OK" "Repository added to composer.json"
    elif command -v ddev &>/dev/null && [ -f ".ddev/config.yaml" ]; then
        ddev composer config repositories.gitlab composer "$repo_url"
        print_status "OK" "Repository added to composer.json (via ddev)"
    else
        print_warning "Composer not available. Add manually to composer.json:"
        echo ""
        echo '  "repositories": {'
        echo '    "gitlab": {'
        echo '      "type": "composer",'
        echo "      \"url\": \"$repo_url\""
        echo '    }'
        echo '  }'
        cd - > /dev/null
        return 1
    fi

    # Configure authentication
    if [ -n "$token" ]; then
        print_info "Configuring authentication..."
        if command -v composer &>/dev/null; then
            composer config --global http-basic.${gitlab_url} __token__ "$token"
        elif command -v ddev &>/dev/null && [ -f ".ddev/config.yaml" ]; then
            # For DDEV, add to auth.json in project
            mkdir -p "$project_path"
            cat > "$project_path/auth.json" << EOF
{
    "http-basic": {
        "${gitlab_url}": {
            "username": "__token__",
            "password": "${token}"
        }
    }
}
EOF
            chmod 600 "$project_path/auth.json"
            print_status "OK" "auth.json created (add to .gitignore!)"
        fi
    fi

    cd - > /dev/null
    print_status "OK" "Project configured to use GitLab Composer registry"
    return 0
}

# Get the Composer repository URL for a GitLab group
# Usage: gitlab_composer_repo_url "group-id-or-name"
gitlab_composer_repo_url() {
    local group="${1:-root}"

    local gitlab_url=$(get_gitlab_url)
    if [ -z "$gitlab_url" ]; then
        return 1
    fi

    # Get group ID if name was provided
    local group_id="$group"
    if ! [[ "$group" =~ ^[0-9]+$ ]]; then
        group_id=$(gitlab_get_group_id "$group")
        if [ -z "$group_id" ]; then
            return 1
        fi
    fi

    echo "https://${gitlab_url}/api/v4/group/${group_id}/-/packages/composer/packages.json"
}

# Check if GitLab Composer registry is configured and accessible
# Usage: gitlab_composer_check
gitlab_composer_check() {
    local gitlab_url=$(get_gitlab_url)
    local token=$(get_gitlab_token)

    if [ -z "$gitlab_url" ]; then
        print_status "FAIL" "GitLab URL not configured"
        return 1
    fi

    if [ -z "$token" ]; then
        print_status "FAIL" "GitLab API token not configured"
        return 1
    fi

    # Try to access the API
    local api_url="https://${gitlab_url}/api/v4"
    local response
    response=$(curl -s --header "PRIVATE-TOKEN: $token" "${api_url}/version")

    if echo "$response" | grep -q '"version"'; then
        local version=$(echo "$response" | grep -o '"version":"[^"]*"' | sed 's/"version":"//; s/"$//')
        print_status "OK" "GitLab $version - Package Registry available"
        return 0
    else
        print_status "FAIL" "Cannot connect to GitLab API"
        return 1
    fi
}

################################################################################
# GitLab User Management
################################################################################

# Create a GitLab user via API
# Usage: gitlab_create_user "username" "email" "name" ["password"]
# Returns: 0 on success, 1 on failure
gitlab_create_user() {
    local username="$1"
    local email="$2"
    local name="$3"
    local password="${4:-}"

    local gitlab_url=$(get_gitlab_url)
    local token=$(get_gitlab_token)

    if [ -z "$gitlab_url" ] || [ -z "$token" ]; then
        print_error "GitLab URL and admin API token required"
        return 1
    fi

    local api_url="https://${gitlab_url}/api/v4"

    # Generate random password if not provided
    if [ -z "$password" ]; then
        password=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
    fi

    # Check if user already exists
    local existing
    existing=$(curl -s --header "PRIVATE-TOKEN: $token" \
        "${api_url}/users?username=${username}" | grep -o '"id":[0-9]*')

    if [ -n "$existing" ]; then
        print_warning "User '$username' already exists"
        return 0
    fi

    # Create the user
    local response
    response=$(curl -s --header "PRIVATE-TOKEN: $token" \
        --header "Content-Type: application/json" \
        --data "{
            \"username\": \"${username}\",
            \"email\": \"${email}\",
            \"name\": \"${name}\",
            \"password\": \"${password}\",
            \"skip_confirmation\": true,
            \"force_random_password\": false
        }" \
        "${api_url}/users")

    if echo "$response" | grep -q '"id":[0-9]*'; then
        local user_id=$(echo "$response" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')
        print_status "OK" "Created GitLab user: $username (ID: $user_id)"
        echo ""
        echo "  Username: $username"
        echo "  Password: $password"
        echo "  Login:    https://${gitlab_url}"
        echo ""
        print_warning "User should change password on first login"
        return 0
    else
        local error=$(echo "$response" | grep -o '"message":{[^}]*}' | head -1)
        [ -z "$error" ] && error=$(echo "$response" | grep -o '"error":"[^"]*"' | head -1)
        print_error "Failed to create user: $error"
        return 1
    fi
}

# Add SSH key to GitLab user
# Usage: gitlab_add_user_ssh_key "username" "ssh_public_key" ["key_title"]
gitlab_add_user_ssh_key() {
    local username="$1"
    local ssh_key="$2"
    local key_title="${3:-nwp-key}"

    local gitlab_url=$(get_gitlab_url)
    local token=$(get_gitlab_token)

    if [ -z "$gitlab_url" ] || [ -z "$token" ]; then
        print_error "GitLab URL and admin API token required"
        return 1
    fi

    local api_url="https://${gitlab_url}/api/v4"

    # Get user ID
    local user_id
    user_id=$(curl -s --header "PRIVATE-TOKEN: $token" \
        "${api_url}/users?username=${username}" | \
        grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')

    if [ -z "$user_id" ]; then
        print_error "User not found: $username"
        return 1
    fi

    # Add SSH key
    local response
    response=$(curl -s --header "PRIVATE-TOKEN: $token" \
        --header "Content-Type: application/json" \
        --data "{
            \"title\": \"${key_title}\",
            \"key\": \"${ssh_key}\"
        }" \
        "${api_url}/users/${user_id}/keys")

    if echo "$response" | grep -q '"id":[0-9]*'; then
        print_status "OK" "Added SSH key to user: $username"
        return 0
    else
        local error=$(echo "$response" | grep -o '"message":"[^"]*"' | head -1)
        print_error "Failed to add SSH key: $error"
        return 1
    fi
}

# Add user to GitLab group
# Usage: gitlab_add_user_to_group "username" "group" ["access_level"]
# Access levels: 10=Guest, 20=Reporter, 30=Developer, 40=Maintainer, 50=Owner
gitlab_add_user_to_group() {
    local username="$1"
    local group="$2"
    local access_level="${3:-30}"  # Default: Developer

    local gitlab_url=$(get_gitlab_url)
    local token=$(get_gitlab_token)

    if [ -z "$gitlab_url" ] || [ -z "$token" ]; then
        print_error "GitLab URL and admin API token required"
        return 1
    fi

    local api_url="https://${gitlab_url}/api/v4"

    # Get user ID
    local user_id
    user_id=$(curl -s --header "PRIVATE-TOKEN: $token" \
        "${api_url}/users?username=${username}" | \
        grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')

    if [ -z "$user_id" ]; then
        print_error "User not found: $username"
        return 1
    fi

    # Get group ID
    local group_id
    group_id=$(curl -s --header "PRIVATE-TOKEN: $token" \
        "${api_url}/groups?search=${group}" | \
        grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')

    if [ -z "$group_id" ]; then
        print_error "Group not found: $group"
        return 1
    fi

    # Add user to group
    local response
    response=$(curl -s --header "PRIVATE-TOKEN: $token" \
        --header "Content-Type: application/json" \
        --data "{
            \"user_id\": ${user_id},
            \"access_level\": ${access_level}
        }" \
        "${api_url}/groups/${group_id}/members")

    if echo "$response" | grep -q '"id":[0-9]*'; then
        print_status "OK" "Added $username to group: $group"
        return 0
    elif echo "$response" | grep -q "already a member"; then
        print_info "User already a member of: $group"
        return 0
    else
        local error=$(echo "$response" | grep -o '"message":"[^"]*"' | head -1)
        print_error "Failed to add to group: $error"
        return 1
    fi
}

# List GitLab users
# Usage: gitlab_list_users
gitlab_list_users() {
    local gitlab_url=$(get_gitlab_url)
    local token=$(get_gitlab_token)

    if [ -z "$gitlab_url" ] || [ -z "$token" ]; then
        print_error "GitLab URL and API token required"
        return 1
    fi

    local api_url="https://${gitlab_url}/api/v4"

    curl -s --header "PRIVATE-TOKEN: $token" \
        "${api_url}/users?per_page=100" | \
        grep -oE '"username":"[^"]*"|"name":"[^"]*"|"state":"[^"]*"' | \
        paste - - - | \
        sed 's/"username":"//g; s/"name":"//g; s/"state":"//g; s/"//g' | \
        awk -F'\t' '{printf "%-20s %-30s %s\n", $1, $2, $3}'
}

################################################################################
# Git Bundle Functions (P12)
################################################################################

# Create a full git bundle containing all history
# Usage: git_bundle_full "/path/to/repo" "/path/to/output.bundle"
git_bundle_full() {
    local repo_path="$1"
    local bundle_path="$2"

    if [ ! -d "$repo_path/.git" ]; then
        print_error "Not a git repository: $repo_path"
        return 1
    fi

    cd "$repo_path" || return 1

    # Create bundle with all refs
    print_info "Creating full git bundle..."
    if git bundle create "$bundle_path" --all 2>&1; then
        local size=$(du -h "$bundle_path" | cut -f1)
        print_status "OK" "Bundle created: $(basename "$bundle_path") ($size)"
        cd - > /dev/null
        return 0
    else
        print_error "Failed to create bundle"
        cd - > /dev/null
        return 1
    fi
}

# Create an incremental git bundle since last bundle tag
# Usage: git_bundle_incremental "/path/to/repo" "/path/to/output.bundle" ["tag-prefix"]
git_bundle_incremental() {
    local repo_path="$1"
    local bundle_path="$2"
    local tag_prefix="${3:-nwp-bundle}"

    if [ ! -d "$repo_path/.git" ]; then
        print_error "Not a git repository: $repo_path"
        return 1
    fi

    cd "$repo_path" || return 1

    # Find the last bundle tag
    local last_tag=$(git tag -l "${tag_prefix}-*" --sort=-creatordate | head -n 1)

    if [ -z "$last_tag" ]; then
        # No previous bundle - create full bundle
        print_info "No previous bundle found, creating full bundle"
        if git bundle create "$bundle_path" --all 2>&1; then
            local size=$(du -h "$bundle_path" | cut -f1)
            print_status "OK" "Full bundle created: $(basename "$bundle_path") ($size)"
        else
            print_error "Failed to create bundle"
            cd - > /dev/null
            return 1
        fi
    else
        # Create incremental bundle from last tag to HEAD
        print_info "Creating incremental bundle since $last_tag"
        if git bundle create "$bundle_path" "${last_tag}..HEAD" --all 2>&1; then
            local size=$(du -h "$bundle_path" | cut -f1)
            print_status "OK" "Incremental bundle created: $(basename "$bundle_path") ($size)"
        else
            print_error "Failed to create incremental bundle"
            cd - > /dev/null
            return 1
        fi
    fi

    # Create a new tag marking this bundle point
    local new_tag="${tag_prefix}-$(date +%Y%m%dT%H%M%S)"
    git tag "$new_tag" -m "Bundle point: $new_tag"
    ocmsg "Created bundle tag: $new_tag"

    cd - > /dev/null
    return 0
}

# Verify a git bundle is valid
# Usage: git_bundle_verify "/path/to/bundle.bundle"
git_bundle_verify() {
    local bundle_path="$1"

    if [ ! -f "$bundle_path" ]; then
        print_error "Bundle not found: $bundle_path"
        return 1
    fi

    print_info "Verifying bundle: $(basename "$bundle_path")"
    if git bundle verify "$bundle_path" 2>&1; then
        print_status "OK" "Bundle is valid"
        return 0
    else
        print_error "Bundle verification failed"
        return 1
    fi
}

# List contents of a git bundle
# Usage: git_bundle_list "/path/to/bundle.bundle"
git_bundle_list() {
    local bundle_path="$1"

    if [ ! -f "$bundle_path" ]; then
        print_error "Bundle not found: $bundle_path"
        return 1
    fi

    print_info "Bundle contents: $(basename "$bundle_path")"
    git bundle list-heads "$bundle_path"
    return $?
}

# Full bundle backup workflow
# Usage: git_bundle_backup "/path/to/backup/dir" "sitename" "backup-type" ["incremental"]
git_bundle_backup() {
    local backup_dir="$1"
    local sitename="$2"
    local backup_type="${3:-db}"
    local incremental="${4:-false}"

    print_header "Git Bundle Backup"

    # Determine bundle filename
    local timestamp=$(date +%Y%m%dT%H%M%S)
    local bundle_dir="${backup_dir}/bundles"
    local bundle_name

    if [ "$incremental" == "true" ]; then
        bundle_name="${sitename}-${backup_type}-incr-${timestamp}.bundle"
    else
        bundle_name="${sitename}-${backup_type}-full-${timestamp}.bundle"
    fi

    # Create bundle directory if needed
    if [ ! -d "$bundle_dir" ]; then
        mkdir -p "$bundle_dir"
    fi

    local bundle_path="${bundle_dir}/${bundle_name}"

    # Initialize repo if needed (for non-git backup dirs)
    if [ ! -d "$backup_dir/.git" ]; then
        print_info "Initializing git repository for bundle..."
        git_init_repo "$backup_dir" "${sitename}-${backup_type}"

        # Add all current files
        cd "$backup_dir" || return 1
        git add -A
        if ! git diff --cached --quiet 2>/dev/null; then
            git commit -q -m "Initial commit for bundle backup"
        fi
        cd - > /dev/null
    fi

    # Create bundle
    if [ "$incremental" == "true" ]; then
        if ! git_bundle_incremental "$backup_dir" "$bundle_path"; then
            return 1
        fi
    else
        if ! git_bundle_full "$backup_dir" "$bundle_path"; then
            return 1
        fi
    fi

    # Verify bundle
    if ! git_bundle_verify "$bundle_path"; then
        print_warning "Bundle created but verification failed"
        return 1
    fi

    print_status "OK" "Bundle saved to: $bundle_path"
    return 0
}
