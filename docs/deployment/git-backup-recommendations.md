# Git Backup Best Practices and Implementation Recommendations for NWP

**Document Version:** 1.0
**Date:** December 30, 2024
**Purpose:** Comprehensive analysis and staged implementation recommendations for git-based backup strategies in Drupal development workflows

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Current State Analysis](#2-current-state-analysis)
3. [Industry Best Practices](#3-industry-best-practices)
4. [Comparison Matrix](#4-comparison-matrix)
5. [Git Origin Options](#5-git-origin-options)
6. [Staged Implementation Recommendations](#6-staged-implementation-recommendations)
7. [Implementation Details](#7-implementation-details)
8. [Security Considerations](#8-security-considerations)
9. [References and Sources](#9-references-and-sources)

---

## 1. Executive Summary

### Overview

This document provides a systematic comparison of git backup approaches across NWP (Narrow Way Project), Pleasy, and Vortex codebases, evaluated against industry best practices for Drupal and other PHP frameworks. The recommendations follow a staged approach to allow incremental adoption based on project needs.

### Key Findings

| Aspect | NWP Status | Pleasy Status | Industry Best Practice |
|--------|-----------|---------------|----------------------|
| Database in Git | ❌ Not implemented | ✅ Implemented | ⚠️ Conditional (sanitized) |
| Files in Git | ❌ Not implemented | ✅ Implemented | ✅ Essential |
| Config in Git | ✅ Via Drush export | ✅ Manual | ✅ Via CM system |
| Git bundles | ❌ Not implemented | ❌ Not implemented | ✅ Recommended |
| Incremental backups | ❌ Not implemented | ❌ Not implemented | ✅ Recommended |
| Multiple remotes | ❌ Not implemented | ✅ Partial | ✅ Essential (3-2-1 rule) |
| Automated scheduling | ❌ Not implemented | ❌ Manual | ✅ Essential |

### Recommendation Summary

1. **Stage 1:** Implement basic git commit integration with existing backup.sh
2. **Stage 2:** Add git bundle support for complete repository snapshots
3. **Stage 3:** Implement multiple remote support (GitHub, GitLab, local)
4. **Stage 4:** Add automated scheduling and monitoring
5. **Stage 5:** Integrate NWP-created GitLab as a backup destination

---

## 2. Current State Analysis

### 2.1 NWP Implementation (`/home/rob/git/`)

#### Backup Script Analysis (`backup.sh`)

**Current Capabilities:**
- ✅ Full site backup (database + files)
- ✅ Database-only backup (`-b` flag)
- ✅ Pleasy-style naming with git info: `YYYYMMDDTHHmmss-branch-commit-message.sql`
- ✅ Git metadata extraction (branch, commit hash)
- ✅ Endpoint specification (`-e` flag)
- ⚠️ Git backup flag exists (`-g`) but is a stub

**Code Reference:** `/home/rob/git/backup.sh:87-89`
```bash
-g, --git               Create supplementary git backup
```

**Gap Analysis:**
1. The `-g` flag is defined but not implemented
2. No actual git commit/push operations after backup
3. No git bundle creation for offline transfer
4. No support for multiple remotes

#### Configuration (`nwp.yml`)

The configuration includes deployment options but lacks git backup configuration:
```yaml
# Current production method options (line 63-68)
prod_method: rsync                # Production method: git, tar, rsync
# prod_gitrepo: git@github.com:user/site.git
# prod_gitdb: git@github.com:user/site-db.git
```

**Missing Configuration:**
- No `backup_git_remote` specification
- No `backup_git_method` (bundle vs push)
- No `backup_git_schedule` for automation

### 2.2 Pleasy Implementation (`/home/rob/tmp/pleasy/`)

#### Server Git Backup Scripts

**Database Git Backup** (`/home/rob/tmp/pleasy/server/gitbackupdb.sh`):
```bash
# Key operations (lines 32-43):
drush sset system.maintenance_mode TRUE
drush cr
drush sql-dump > /home/$user/$uri/proddb/prod.sql
drush sset system.maintenance_mode FALSE

cd /home/$user/$uri/proddb/
git add .
git commit -m "$2"
git push
```

**Strengths:**
- ✅ Maintenance mode during backup (data consistency)
- ✅ Cache clear before dump (smaller backup)
- ✅ Git commit with message
- ✅ Git push to remote
- ✅ SSH key management

**Weaknesses:**
- ❌ No error handling on git operations
- ❌ Single remote only
- ❌ No bundle creation option
- ❌ No incremental backup support

**Files Git Backup** (`/home/rob/tmp/pleasy/server/gitbackupfiles.sh`):
```bash
# Key operations (lines 30-36):
cd $(dirname $prod_docroot)
git add .
git commit -m "backup$2"
git push
```

**Production Backup** (`/home/rob/tmp/pleasy/server/backupprod.sh`):
```bash
# Naming convention (line 54):
Name=$(date +%Y%m%d\T%H%M%S-)$(git branch | grep \* | cut -d ' ' -f2)...
```

**Git Commit Script** (`/home/rob/tmp/pleasy/scripts/gcom.sh`):
- Combines config export with git operations
- Optional backup after commit (`-b` flag)
- Supports pleasy itself as a target

### 2.3 Vortex Implementation (`/home/rob/tmp/vortex/`)

#### Key Patterns from Vortex

From `.vortex/CLAUDE.md`, Vortex demonstrates:

1. **Multi-environment Deployment:**
   - CI provider integration (GitHub Actions, CircleCI)
   - Multiple deployment types (container registry, webhook, artifact)
   - Hosting provider support (Lagoon, Acquia)

2. **Configuration Management:**
   - Conditional token system for template customization
   - YAML-based configuration
   - Automated testing with multiple frameworks

3. **Relevant Patterns:**
   - Incremental fixture updates via snapshots
   - Environment variable management
   - Multi-platform compatibility

---

## 3. Industry Best Practices

### 3.1 Drupal-Specific Best Practices

Based on [Drupal.org documentation](https://www.drupal.org/docs/develop/git) and community guidelines:

#### What to Version Control

| Component | Git Status | Rationale |
|-----------|-----------|-----------|
| Custom modules | ✅ Yes | Core intellectual property |
| Custom themes | ✅ Yes | Design implementation |
| Composer files | ✅ Yes | Dependency management |
| Configuration (YAML) | ✅ Yes | Site settings, content types, views |
| Database dumps | ⚠️ Conditional | Only sanitized, for testing |
| User uploads | ❌ No | Use file backup, not git |
| Vendor directory | ❌ No | Generated from composer.lock |
| Node modules | ❌ No | Generated from package.json |

#### Configuration Management Workflow

From [Evolving Web](https://evolvingweb.com/blog/using-configuration-management-and-git-drupal) and [Pantheon](https://docs.pantheon.io/drupal-configuration-management):

```
Development → Export Config → Commit → Push → Pull → Import Config → Staging/Production
```

**Key Commands:**
```bash
# Export configuration
drush config-export -y

# Commit configuration
git add config/sync/
git commit -m "Configuration updates"

# Import configuration (on target)
drush config-import -y
```

### 3.2 Git Backup Best Practices

Based on [GitProtect.io](https://gitprotect.io/blog/gitlab-backup-best-practices/) and [SCIMUS](https://thescimus.com/blog/git-backup-best-practices/):

#### The 3-2-1 Rule

| Requirement | Description |
|-------------|-------------|
| **3** copies | Original + 2 backups |
| **2** different media | Local + remote (or different remotes) |
| **1** offsite | Cloud or geographically separate location |

#### Backup Methods

| Method | Use Case | Pros | Cons |
|--------|----------|------|------|
| `git clone --mirror` | Full repository copy | Complete history, all refs | Requires network access |
| `git bundle` | Offline transfer, archival | Single file, portable | Manual process |
| `git push` to multiple remotes | Continuous replication | Real-time, automated | Requires remote setup |
| Repository backup services | Enterprise backup | Metadata included | Cost, vendor lock-in |

#### Git Bundle Best Practices

From [GitHub Gist](https://gist.github.com/xtream1101/fd79f3099f572967605fab24d976b179):

```bash
# Create full bundle
git bundle create backup.bundle --all

# Create incremental bundle (since last backup tag)
git bundle create incremental.bundle last_backup..HEAD

# Verify bundle
git bundle verify backup.bundle

# Restore from bundle
git clone backup.bundle restored-repo
```

### 3.3 GitLab Self-Hosted Best Practices

From [GitLab Docs](https://docs.gitlab.com/administration/backup_restore/backup_gitlab/):

#### Backup Components

| Component | Location | Backup Method |
|-----------|----------|---------------|
| Git repositories | `/var/opt/gitlab/git-data` | `gitlab-backup create` |
| Database | PostgreSQL | Included in backup |
| Configuration | `/etc/gitlab` | `gitlab-ctl backup-etc` |
| Uploads | `/var/opt/gitlab/gitlab-rails/uploads` | Included in backup |
| CI/CD artifacts | `/var/opt/gitlab/gitlab-rails/shared/artifacts` | Included in backup |

#### Backup Scheduling

```bash
# Example crontab entry for GitLab backup
0 2 * * * /opt/gitlab/bin/gitlab-backup create CRON=1

# Configuration backup (separate)
0 3 * * * /usr/bin/gitlab-ctl backup-etc
```

---

## 4. Comparison Matrix

### 4.1 Feature Comparison: NWP vs Pleasy vs Best Practice

| Feature | NWP Current | Pleasy Current | Best Practice | Priority |
|---------|-------------|----------------|---------------|----------|
| **Database Backup** |
| SQL dump to file | ✅ | ✅ | ✅ | HIGH |
| Git commit after dump | ❌ | ✅ | ✅ | HIGH |
| Maintenance mode during dump | ❌ | ✅ | ✅ | MEDIUM |
| Cache clear before dump | ❌ | ✅ | ✅ | MEDIUM |
| Database sanitization | ❌ | ❌ | ✅ | MEDIUM |
| **Files Backup** |
| Tar archive | ✅ | ✅ | ✅ | HIGH |
| Git commit | ❌ | ✅ | ✅ | HIGH |
| Exclude settings.php | ✅ | ✅ | ✅ | HIGH |
| Exclude vendor | ✅ | ✅ | ✅ | HIGH |
| **Git Operations** |
| Git commit | ❌ | ✅ | ✅ | HIGH |
| Git push | ❌ | ✅ | ✅ | HIGH |
| Git bundle | ❌ | ❌ | ✅ | MEDIUM |
| Multiple remotes | ❌ | ❌ | ✅ | MEDIUM |
| SSH key management | ❌ | ✅ | ✅ | HIGH |
| **Configuration** |
| Config export | ✅ | ✅ | ✅ | HIGH |
| Config in version control | ✅ | ✅ | ✅ | HIGH |
| Config validation | ❌ | ❌ | ✅ | LOW |
| **Automation** |
| Manual trigger | ✅ | ✅ | ✅ | HIGH |
| Cron scheduling | ❌ | ❌ | ✅ | MEDIUM |
| CI/CD integration | Partial | ❌ | ✅ | MEDIUM |
| **Error Handling** |
| Validation before backup | ✅ | ⚠️ | ✅ | HIGH |
| Rollback on failure | ❌ | ❌ | ✅ | MEDIUM |
| Notification on failure | ❌ | ❌ | ✅ | LOW |

### 4.2 Gap Analysis Summary

#### Critical Gaps (Must Address)

1. **Git Integration in NWP Backup**
   - The `-g` flag exists but is not implemented
   - No git commit/push after backup creation
   - Impact: Manual intervention required for version control

2. **SSH Key Management**
   - NWP lacks SSH key configuration for remote operations
   - Pleasy has `ssh-add` integration but hardcoded paths
   - Impact: Cannot automate git push operations

3. **Multiple Remote Support**
   - Neither NWP nor Pleasy support the 3-2-1 backup rule natively
   - Impact: Single point of failure for backups

#### Important Gaps (Should Address)

4. **Maintenance Mode During Backup**
   - NWP doesn't enable maintenance mode during database dump
   - Impact: Potential data inconsistency during active writes

5. **Git Bundle Support**
   - No implementation in either codebase
   - Impact: Cannot create offline transferable backups

6. **Incremental Backups**
   - No incremental git bundle support
   - Impact: Inefficient storage use for large repositories

---

## 5. Git Origin Options

### 5.1 GitHub

#### Advantages
- Industry standard, widely adopted
- Free private repositories
- Excellent CI/CD integration (GitHub Actions)
- Large ecosystem of tools and integrations
- Built-in issue tracking, PRs, wikis

#### Disadvantages
- Hosted in USA (data sovereignty concerns)
- Vendor lock-in for advanced features
- Rate limits on API operations
- No self-hosting option

#### Configuration Example
```yaml
# nwp.yml addition
git_remotes:
  github:
    url: git@github.com:username/site.git
    db_url: git@github.com:username/site-db.git
    type: github
    primary: true
```

#### Implementation Notes
```bash
# Add GitHub remote
git remote add github git@github.com:username/site.git

# Push to GitHub
git push github main

# GitHub CLI authentication
gh auth login
```

### 5.2 GitLab (Cloud)

#### Advantages
- Free unlimited private repositories
- Built-in CI/CD with `.gitlab-ci.yml`
- Container registry included
- Better privacy (EU data centers available)
- Self-hosted option available

#### Disadvantages
- Smaller ecosystem than GitHub
- Can be slower for large repositories
- Some features require paid tiers

#### Configuration Example
```yaml
# nwp.yml addition
git_remotes:
  gitlab:
    url: git@gitlab.com:username/site.git
    db_url: git@gitlab.com:username/site-db.git
    type: gitlab
    primary: false
```

### 5.3 Local Git Server (Bare Repository)

#### Advantages
- Complete data sovereignty
- No external dependencies
- Fastest for local operations
- Free, no account required
- Works offline

#### Disadvantages
- No web interface (unless added)
- Manual setup required
- Not offsite (violates 3-2-1 unless replicated)
- No built-in CI/CD

#### Setup Instructions
```bash
# Create bare repository on local server
sudo mkdir -p /srv/git/backups
sudo git init --bare /srv/git/site-backup.git
sudo chown -R git:git /srv/git/

# Add as remote
git remote add local /srv/git/site-backup.git
# or via SSH
git remote add local git@localhost:/srv/git/site-backup.git
```

#### Configuration Example
```yaml
# nwp.yml addition
git_remotes:
  local:
    url: /srv/git/site-backup.git
    # or: git@localhost:/srv/git/site-backup.git
    type: bare
    primary: false
    schedule: "after_each_backup"
```

### 5.4 Custom GitLab Instance (NWP-Created)

#### Advantages
- Complete control over data and features
- Can be configured specifically for Drupal workflows
- Integrates with existing NWP infrastructure
- Can use NWP's recipe system for setup
- All GitLab features available

#### Disadvantages
- Requires server resources (4GB RAM minimum)
- Maintenance overhead
- Initial setup complexity
- Needs regular updates for security

#### NWP Recipe for GitLab

Based on the existing `nwp.yml` structure, a GitLab recipe could be:

```yaml
# nwp.yml - GitLab recipe (as already present at line 79-85)
gitlab:
  type: gitlab
  source: https://gitlab.com/gitlab-org/gitlab-foss.git
  branch: master
  webroot: .
  sitename: "GitLab Instance"
  auto: y
```

#### Enhanced Configuration for Backup Integration

```yaml
# nwp.yml additions for git backup
git_backup:
  enabled: true
  method: push  # or: bundle
  remotes:
    primary:
      type: nwp_gitlab  # Uses NWP-installed GitLab
      url: git@gitlab.local:backups/site.git
      auto_create_repo: true
    secondary:
      type: github
      url: git@github.com:username/site-backup.git
  schedule:
    database: "0 2 * * *"    # Daily at 2 AM
    files: "0 3 * * 0"       # Weekly on Sunday at 3 AM
    bundle: "0 4 1 * *"      # Monthly on 1st at 4 AM
```

### 5.5 Remote Comparison Matrix

| Feature | GitHub | GitLab Cloud | Local Bare | NWP GitLab |
|---------|--------|--------------|------------|------------|
| Cost | Free/Paid | Free/Paid | Free | Free (+ server) |
| Privacy | Medium | Good | Excellent | Excellent |
| Reliability | Excellent | Excellent | Depends | Depends |
| CI/CD | GitHub Actions | GitLab CI | None | GitLab CI |
| Web UI | Yes | Yes | No | Yes |
| Offline Access | No | No | Yes | Depends |
| Setup Complexity | Low | Low | Medium | High |
| Maintenance | None | None | Low | Medium |
| Data Sovereignty | USA | EU/USA | Local | Local |
| Integration | Excellent | Good | Manual | Good |

---

## 6. Staged Implementation Recommendations

### Stage 1: Basic Git Integration (Week 1-2)

**Objective:** Add functional git commit/push to existing backup workflow

#### 6.1.1 Tasks

1. **Implement `-g` flag in `backup.sh`**
   - Add git add/commit after backup creation
   - Support custom commit messages
   - Handle existing vs new repository

2. **Add configuration in `nwp.yml`**
   ```yaml
   git_backup:
     enabled: false  # Enable per-site
     remote: origin  # Default remote name
     auto_commit: true
     auto_push: false  # Require explicit push
   ```

3. **Create `gitbackup.sh` helper script**
   - Modular git operations
   - SSH key setup helper
   - Remote configuration helper

#### 6.1.2 Implementation Reference

Based on Pleasy patterns (`/home/rob/tmp/pleasy/server/gitbackupdb.sh`):

```bash
# backup.sh addition for -g flag implementation
git_backup() {
    local site_dir=$1
    local backup_name=$2
    local message=$3

    cd "$site_dir" || return 1

    # Initialize git if needed
    if [ ! -d ".git" ]; then
        git init
        echo "sitebackups/" >> .gitignore
        echo "vendor/" >> .gitignore
        echo ".ddev/" >> .gitignore
        git add .gitignore
    fi

    # Add and commit
    git add .
    git commit -m "Backup: ${backup_name} - ${message}"

    # Push if remote exists and auto_push enabled
    if git remote | grep -q "origin" && [ "$AUTO_PUSH" == "true" ]; then
        git push origin "$(git branch --show-current)"
    fi
}
```

#### 6.1.3 Success Criteria

- [ ] `-g` flag creates git commit after backup
- [ ] Commit message includes backup name and user message
- [ ] Repository initialized if not exists
- [ ] Proper .gitignore configured
- [ ] Works with existing backup naming convention

---

### Stage 2: Git Bundle Support (Week 3-4)

**Objective:** Enable offline/archival git backups via bundles

#### 6.2.1 Tasks

1. **Add `--bundle` flag to backup.sh**
   - Create complete repository bundle
   - Store in sitebackups directory
   - Verify bundle integrity

2. **Implement incremental bundles**
   - Track last bundle creation (tag-based)
   - Create differential bundles
   - Maintain bundle index

3. **Add bundle restoration**
   - Verify bundle before restore
   - Clone from bundle
   - Reconnect to remotes

#### 6.2.2 Implementation Reference

```bash
# New function in backup.sh
create_git_bundle() {
    local site_dir=$1
    local backup_dir=$2
    local backup_name=$3
    local incremental=${4:-false}

    cd "$site_dir" || return 1

    local bundle_file="${backup_dir}/${backup_name}.bundle"

    if [ "$incremental" == "true" ]; then
        # Get last bundle tag
        local last_tag=$(git tag -l "bundle-*" | sort -r | head -1)
        if [ -n "$last_tag" ]; then
            git bundle create "$bundle_file" "${last_tag}..HEAD" --all
        else
            git bundle create "$bundle_file" --all
        fi
    else
        git bundle create "$bundle_file" --all
    fi

    # Create bundle tag for incremental tracking
    git tag "bundle-${backup_name}"

    # Verify bundle
    if git bundle verify "$bundle_file" > /dev/null 2>&1; then
        print_status "OK" "Bundle created: $(basename "$bundle_file")"
        return 0
    else
        print_error "Bundle verification failed"
        return 1
    fi
}
```

#### 6.2.3 Success Criteria

- [ ] Full bundle creation working
- [ ] Incremental bundle creation working
- [ ] Bundle verification passes
- [ ] Restoration from bundle successful
- [ ] Bundle stored alongside SQL/tar backups

---

### Stage 3: Multiple Remote Support (Week 5-6)

**Objective:** Implement 3-2-1 backup rule with multiple git remotes

#### 6.3.1 Tasks

1. **Configuration for multiple remotes**
   ```yaml
   git_backup:
     remotes:
       - name: github
         url: git@github.com:user/site.git
         primary: true
       - name: gitlab
         url: git@gitlab.com:user/site.git
         primary: false
       - name: local
         url: /srv/git/site.git
         primary: false
   ```

2. **Implement push to all remotes**
   - Sequential push with error handling
   - Partial success reporting
   - Retry logic for transient failures

3. **Add remote status check**
   - Verify remote accessibility
   - Check authentication
   - Report sync status

#### 6.3.2 Implementation Reference

```bash
# Multi-remote push function
push_to_remotes() {
    local site_dir=$1
    shift
    local remotes=("$@")

    cd "$site_dir" || return 1

    local success_count=0
    local fail_count=0

    for remote in "${remotes[@]}"; do
        print_info "Pushing to $remote..."
        if git push "$remote" --all 2>/dev/null; then
            print_status "OK" "Pushed to $remote"
            ((success_count++))
        else
            print_status "FAIL" "Failed to push to $remote"
            ((fail_count++))
        fi
    done

    echo ""
    print_info "Push complete: $success_count succeeded, $fail_count failed"

    # Return failure if any push failed
    [ $fail_count -eq 0 ]
}
```

#### 6.3.3 Success Criteria

- [ ] Multiple remotes configurable in nwp.yml
- [ ] Push to all configured remotes
- [ ] Clear status reporting
- [ ] Handles remote failures gracefully
- [ ] At least 2 remotes configured (satisfies 3-2-1)

---

### Stage 4: Automated Scheduling (Week 7-8)

**Objective:** Enable automated git backups via cron/systemd

#### 6.4.1 Tasks

1. **Create scheduling configuration**
   ```yaml
   git_backup:
     schedule:
       enabled: true
       database: "0 2 * * *"      # Daily 2 AM
       files: "0 3 * * 0"          # Weekly Sunday 3 AM
       full_bundle: "0 4 1 * *"    # Monthly 1st at 4 AM
   ```

2. **Generate cron entries**
   - Install/update crontab
   - Support systemd timers as alternative
   - Log all scheduled operations

3. **Add monitoring/notification**
   - Email on failure
   - Slack webhook integration
   - Health check endpoint

#### 6.4.2 Implementation Reference

```bash
# Schedule installation function
install_backup_schedule() {
    local site=$1
    local db_schedule=$2
    local files_schedule=$3

    # Generate cron entries
    local cron_file="/etc/cron.d/nwp-backup-${site}"

    cat > "$cron_file" << EOF
# NWP Git Backup Schedule for $site
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin

# Database backup (daily)
$db_schedule $USER cd /path/to/nwp && ./backup.sh -bg $site "Scheduled DB backup"

# Full backup (weekly)
$files_schedule $USER cd /path/to/nwp && ./backup.sh -g $site "Scheduled full backup"
EOF

    chmod 644 "$cron_file"
    print_status "OK" "Backup schedule installed: $cron_file"
}
```

#### 6.4.3 Success Criteria

- [ ] Cron schedule configuration in nwp.yml
- [ ] Schedule installation command
- [ ] Schedule removal command
- [ ] Logs written for each scheduled run
- [ ] Email notification on failure

---

### Stage 5: NWP-Created GitLab Integration (Week 9-12)

**Objective:** Use NWP's GitLab recipe as a dedicated backup destination

#### 6.5.1 Tasks

1. **Enhance GitLab recipe**
   - Configure for backup server role
   - Set up backup-specific groups/projects
   - Enable repository mirroring

2. **Auto-create backup repositories**
   - GitLab API integration
   - Automatic project creation per site
   - Access token management

3. **Integrate with backup workflow**
   - Auto-configure as remote
   - Repository initialization
   - Mirror to external services

#### 6.5.2 GitLab API Integration

```bash
# Create backup repository via GitLab API
create_gitlab_backup_repo() {
    local gitlab_url=$1
    local token=$2
    local site_name=$3
    local group_id=${4:-"backups"}

    # Create project via API
    curl --request POST \
        --header "PRIVATE-TOKEN: $token" \
        --data "name=${site_name}-backup" \
        --data "namespace_id=$group_id" \
        --data "visibility=private" \
        "${gitlab_url}/api/v4/projects"
}
```

#### 6.5.3 Configuration

```yaml
# nwp.yml - GitLab backup server configuration
git_backup:
  nwp_gitlab:
    enabled: true
    url: https://gitlab.local
    token_env: GITLAB_BACKUP_TOKEN
    group: backups
    auto_create: true
    mirror_to:
      - github
      - gitlab.com
```

#### 6.5.4 Success Criteria

- [ ] GitLab installed via NWP recipe
- [ ] Backup group/namespace created
- [ ] Auto-repository creation working
- [ ] API integration functional
- [ ] Mirror to external services configured

---

## 7. Implementation Details

### 7.1 Proposed File Structure

```
nwp/
├── backup.sh                    # Enhanced with -g flag
├── restore.sh                   # Enhanced with git restore
├── lib/
│   ├── git-backup.sh           # Git backup functions
│   ├── git-bundle.sh           # Bundle operations
│   └── git-remote.sh           # Multi-remote management
├── nwp.yml                     # Enhanced with git_backup section
├── docs/
│   ├── GIT_BACKUP_RECOMMENDATIONS.md  # This document
│   └── GIT_BACKUP_SETUP.md           # User guide
└── templates/
    └── gitignore.template       # Standard .gitignore for sites
```

### 7.2 Enhanced nwp.yml Schema

```yaml
# Full git_backup configuration schema
git_backup:
  # Global settings
  enabled: true                   # Enable git backup system
  method: push                    # push, bundle, or both

  # Default .gitignore patterns
  ignore_patterns:
    - sitebackups/
    - vendor/
    - node_modules/
    - .ddev/
    - "*.sql"
    - "*.tar.gz"

  # Remote repositories
  remotes:
    primary:
      type: github               # github, gitlab, local, nwp_gitlab
      url: git@github.com:user/site.git
      branch: main
    secondary:
      type: nwp_gitlab
      url: git@gitlab.local:backups/site.git
      branch: backup
    tertiary:
      type: local
      path: /srv/git/backups/site.git

  # Scheduling
  schedule:
    enabled: false
    database: "0 2 * * *"        # Cron expression
    full: "0 3 * * 0"
    bundle: "0 4 1 * *"

  # Notifications
  notifications:
    email: admin@example.com
    slack_webhook: ""
    on_success: false
    on_failure: true

  # Advanced options
  options:
    maintenance_mode: true       # Enable during backup
    cache_clear: true            # Clear cache before dump
    compress_bundle: true        # Compress git bundles
    incremental_bundle: true     # Use incremental bundles
    retention_days: 30           # Bundle retention
```

### 7.3 Database Backup in Git: Best Practice

Based on [Drupal Groups discussion](https://groups.drupal.org/node/227493) and community consensus:

#### Recommended Approach

**DO store in git (separate repository):**
- Sanitized database dumps (no PII)
- Reference databases for testing
- Configuration-only dumps

**DO NOT store in git (same repository as code):**
- Production database with user data
- Large media databases
- Frequently changing content databases

#### Database Repository Pattern

```
site-db/
├── prod.sql                    # Sanitized production snapshot
├── reference.sql               # Clean reference database
└── seeds/
    ├── users.sql               # Test user data
    └── content.sql             # Sample content
```

#### Sanitization Example

```bash
# Sanitize database before git commit
sanitize_database() {
    local sql_file=$1
    local output_file=$2

    # Use drush sql-sanitize equivalent
    drush sql-dump --sanitize \
        --sanitize-password="test123" \
        --sanitize-email="test+%uid@example.com" \
        --result-file="$output_file"
}
```

---

## 8. Security Considerations

### 8.1 SSH Key Management

#### Recommended Setup

```bash
# Generate dedicated backup SSH key
ssh-keygen -t ed25519 -C "nwp-backup@$(hostname)" -f ~/.ssh/nwp_backup_key

# Configure SSH for backup operations
cat >> ~/.ssh/config << EOF
Host github.com-backup
    HostName github.com
    User git
    IdentityFile ~/.ssh/nwp_backup_key
    IdentitiesOnly yes

Host gitlab.com-backup
    HostName gitlab.com
    User git
    IdentityFile ~/.ssh/nwp_backup_key
    IdentitiesOnly yes
EOF
```

#### Key Storage

- Store keys with restricted permissions (600)
- Use ssh-agent for passphrase management
- Consider hardware security keys for production
- Rotate keys annually

### 8.2 Token Management

```bash
# Store tokens in environment, not configuration
export GITLAB_BACKUP_TOKEN="glpat-xxxx"
export GITHUB_BACKUP_TOKEN="ghp_xxxx"

# Or use secure credential storage
git config --global credential.helper store
# Better: use credential manager
git config --global credential.helper cache --timeout=3600
```

### 8.3 Database Security

#### Never Commit
- Production passwords
- API keys
- User personal data (GDPR)
- Session data

#### Always Sanitize
```bash
# Before git operations
drush sql:sanitize --sanitize-password='[REDACTED]' --sanitize-email='[REDACTED]'
```

### 8.4 Configuration File Security

```yaml
# nwp.yml - sensitive data handling
git_backup:
  # Use environment variables for sensitive data
  remotes:
    primary:
      url_env: GIT_BACKUP_PRIMARY_URL   # Read from environment
      token_env: GIT_BACKUP_TOKEN        # Read from environment
```

---

## 9. References and Sources

### Drupal Documentation
- [Git version control system - Drupal.org](https://www.drupal.org/docs/develop/git)
- [Backup your database and files - Drupal.org](https://www.drupal.org/docs/7/site-building-best-practices/backup-your-database-and-files)
- [Configuration Management - Drupal.org](https://www.drupal.org/docs/configuration-management/keeping-your-local-and-remote-sites-synchronized)
- [Database Version Control with Git - Drupal Groups](https://groups.drupal.org/node/227493)

### Git and Backup Best Practices
- [Git Backup Best Practices - SCIMUS](https://thescimus.com/blog/git-backup-best-practices/)
- [Git bundle backup and restore - GitHub Gist](https://gist.github.com/xtream1101/fd79f3099f572967605fab24d976b179)
- [GitProtect.io Git Backup Guide](https://gitprotect.io/git-backup-guide-for-github-bitbucket-and-gitlab-users.html)

### GitLab Documentation
- [Back up GitLab - GitLab Docs](https://docs.gitlab.com/administration/backup_restore/backup_gitlab/)
- [GitLab Backup Best Practices - GitProtect.io](https://gitprotect.io/blog/gitlab-backup-best-practices/)
- [Self-Hosted GitLab Setup - Cycle.io](https://cycle.io/learn/self-hosted-gitlab)

### Configuration Management
- [Using Configuration Management and Git in Drupal - Evolving Web](https://evolvingweb.com/blog/using-configuration-management-and-git-drupal)
- [Configuration Workflow - Pantheon Docs](https://docs.pantheon.io/drupal-configuration-management)
- [Git workflow for managing Drupal 8 configuration - Nuvole](https://nuvole.org/blog/2014/aug/20/git-workflow-managing-drupal-8-configuration)

### Codebase References
- NWP: `/home/rob/git/backup.sh` - Current backup implementation
- Pleasy: `/home/rob/tmp/pleasy/server/gitbackupdb.sh` - Git database backup reference
- Pleasy: `/home/rob/tmp/pleasy/server/gitbackupfiles.sh` - Git files backup reference
- Vortex: `/home/rob/tmp/vortex/.vortex/CLAUDE.md` - Modern Drupal project patterns

---

## Appendix A: Quick Reference Commands

### Git Backup Commands

```bash
# Basic git backup
./backup.sh -g sitename "Backup message"

# Database-only with git
./backup.sh -bg sitename "DB backup message"

# Create git bundle
./backup.sh --bundle sitename "Bundle backup"

# Push to all remotes
./backup.sh -g --push-all sitename "Multi-remote backup"

# Incremental bundle
./backup.sh --bundle --incremental sitename "Incremental"
```

### Git Remote Management

```bash
# Add remote
git remote add github git@github.com:user/site.git
git remote add gitlab git@gitlab.com:user/site.git
git remote add local /srv/git/site.git

# Push to specific remote
git push github main
git push gitlab main

# Push to all remotes
git remote | xargs -L1 git push --all

# Verify remotes
git remote -v
```

### Git Bundle Operations

```bash
# Create bundle
git bundle create site-backup.bundle --all

# Verify bundle
git bundle verify site-backup.bundle

# List bundle contents
git bundle list-heads site-backup.bundle

# Clone from bundle
git clone site-backup.bundle restored-site

# Fetch from bundle (into existing repo)
git fetch site-backup.bundle main:refs/remotes/bundle/main
```

---

## Appendix B: Migration Checklist

### From Manual Backups to Git-Based

- [ ] Audit current backup process
- [ ] Initialize git in existing sites
- [ ] Configure .gitignore properly
- [ ] Set up SSH keys
- [ ] Configure primary remote (GitHub/GitLab)
- [ ] Configure secondary remote (local/NWP GitLab)
- [ ] Test backup with `-g` flag
- [ ] Test restoration process
- [ ] Set up automated schedule
- [ ] Configure notifications
- [ ] Document process for team

### From Pleasy to NWP

- [ ] Review Pleasy git backup scripts
- [ ] Map Pleasy features to NWP equivalents
- [ ] Migrate SSH key configuration
- [ ] Update remote URLs in configuration
- [ ] Test backup/restore cycle
- [ ] Verify database sanitization
- [ ] Update automation scripts

---

*Document created: December 30, 2024*
*Last updated: December 30, 2024*
*Author: Generated via analysis of NWP, Pleasy, and Vortex codebases*
