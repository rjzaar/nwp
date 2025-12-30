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
    local cnwp_file="${SCRIPT_DIR}/cnwp.yml"

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
            gsub(/["'"'"']/, "")  # Remove quotes
            print
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
    local secrets_file="${SCRIPT_DIR}/.secrets.yml"

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
    local group="${3:-backups}"

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
    local group="${2:-backups}"

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
    local group="${4:-backups}"

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
