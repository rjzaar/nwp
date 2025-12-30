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

################################################################################
# Additional Remote Support (P13)
################################################################################

# Get additional remotes from cnwp.yml
# Returns: remote configurations as "name|url|enabled" per line
get_additional_remotes() {
    local cnwp_file="${SCRIPT_DIR}/cnwp.yml"

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
    local group="${4:-backups}"

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
