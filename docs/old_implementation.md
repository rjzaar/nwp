# NWP Improvements Based on Pleasy

A comprehensive plan to enhance NWP (Narrow Way Project) by incorporating functionality from the Pleasy library.

## Overview

**Pleasy** is a mature, comprehensive Drupal site management library with extensive backup, restore, copy, and deployment features.

**NWP** is a newer, more focused installation tool using DDEV for local development environments.

This document outlines the improvements needed to bring Pleasy's functionality into NWP.

---

## Table of Contents

1. [Backup System](#1-backup-system)
2. [Restore System](#2-restore-system)
3. [Site Copy/Clone System](#3-site-copyclone-system)
4. [Development Workflow Scripts](#4-development-workflow-scripts)
5. [Configuration System Enhancements](#5-configuration-system-enhancements)
6. [Shared Helper Functions Library](#6-shared-helper-functions-library)
7. [Drush Integration](#7-drush-integration)
8. [Installation Enhancements](#8-installation-enhancements)
9. [Multi-Environment Support](#9-multi-environment-support)
10. [Command-Line Interface Improvements](#10-command-line-interface-improvements)
11. [Utility Scripts](#11-utility-scripts)
12. [Error Handling & Validation](#12-error-handling--validation)
13. [Priority Implementation Order](#priority-implementation-order)

---

## 1. Backup System

### 1.1 Site and Database Backup (`backup.sh`)

| # | Task | Status | Description |
|---|------|--------|-------------|
| 1.1.1 | Create `backup.sh` script | ⬜ | Full site backups (files + database) |
| 1.1.2 | Support backup messages/notes | ⬜ | Identify backups with descriptions |
| 1.1.3 | Support endpoint specification | ⬜ | Remote/different backup locations |
| 1.1.4 | Add git-based backup option | ⬜ | `-g` flag for git backups |
| 1.1.5 | Create `sitebackups/` directory structure | ⬜ | Organized backup storage |
| 1.1.6 | Add timer display | ⬜ | Show backup duration |
| 1.1.7 | Differentiate prod/non-prod methods | ⬜ | Different backup strategies |
| 1.1.8 | Create timestamped backup files | ⬜ | `.sql` and `.tar.gz` with timestamps |

**Reference from Pleasy:**
```bash
# Usage examples from backup.sh
pl backup dev 'Fixed error'
pl backup tim -e=fred 'First tim backup'
```

### 1.2 Database-Only Backup (`backupdb.sh`)

| # | Task | Status | Description |
|---|------|--------|-------------|
| 1.2.1 | Create `backupdb.sh` script | ⬜ | Database-only backups |
| 1.2.2 | Support optional message parameter | ⬜ | `-m` flag for messages |
| 1.2.3 | Integrate with DDEV | ⬜ | Use `ddev export-db` command |

**Reference from Pleasy:**
```bash
# Usage examples from backupdb.sh
pl backupdb dev
pl backupdb tim -m 'First tim backup'
```

---

## 2. Restore System

### 2.1 Full Site Restore (`restore.sh`)

| # | Task | Status | Description |
|---|------|--------|-------------|
| 2.1.1 | Create `restore.sh` script | ⬜ | Restore from backups |
| 2.1.2 | Support restoring to different site | ⬜ | FROM → TO functionality |
| 2.1.3 | Interactive backup selection menu | ⬜ | List available backups by date |
| 2.1.4 | Support `--first` flag | ⬜ | Auto-select latest backup |
| 2.1.5 | Support git-based production restore | ⬜ | Git-based restore method |
| 2.1.6 | Support tar-based restore | ⬜ | Tarball restore method |
| 2.1.7 | Step-based restoration | ⬜ | Resume capability |
| 2.1.8 | Handle `settings.php` preservation | ⬜ | Protect settings during restore |
| 2.1.9 | Fix site settings after restore | ⬜ | Auto-configure settings |
| 2.1.10 | Set proper permissions | ⬜ | File permission correction |

**Reference from Pleasy:**
```bash
# Usage examples from restore.sh
pl restore d9
pl restore d9 stg_d9 -fy
pl restore d9_prod stg_d9
```

### 2.2 Database-Only Restore (`restoredb.sh`)

| # | Task | Status | Description |
|---|------|--------|-------------|
| 2.2.1 | Create `restoredb.sh` script | ⬜ | Database-only restore |
| 2.2.2 | Interactive database backup selection | ⬜ | Choose from available backups |
| 2.2.3 | Support cross-site restore | ⬜ | Restore from one site to another |

---

## 3. Site Copy/Clone System

### 3.1 Full Site Copy (`copy.sh`)

| # | Task | Status | Description |
|---|------|--------|-------------|
| 3.1.1 | Create `copy.sh` script | ⬜ | Clone one site to another |
| 3.1.2 | Copy all files from source | ⬜ | Full file copy |
| 3.1.3 | Backup source database | ⬜ | Pre-copy database backup |
| 3.1.4 | Import database into destination | ⬜ | Database migration |
| 3.1.5 | Fix site settings for destination | ⬜ | Update settings.php |
| 3.1.6 | Set proper permissions | ⬜ | Permission correction |

**Reference from Pleasy:**
```bash
# From copy.sh
echo "This will copy the site from $from to $sitename_var and then try to import the database"
```

### 3.2 Files-Only Copy (`copyf.sh`)

| # | Task | Status | Description |
|---|------|--------|-------------|
| 3.2.1 | Create `copyf.sh` script | ⬜ | File-only copying |
| 3.2.2 | Skip database operations | ⬜ | Files only, no DB |
| 3.2.3 | Fix site settings | ⬜ | Update configuration |
| 3.2.4 | Set permissions | ⬜ | Correct file permissions |

### 3.3 Production to Test Copy (`copypt.sh`)

| # | Task | Status | Description |
|---|------|--------|-------------|
| 3.3.1 | Create `copypt.sh` script | ⬜ | Prod → Test workflow |
| 3.3.2 | Specialized production handling | ⬜ | Safe production copy |

---

## 4. Development Workflow Scripts

### 4.1 Dev to Stage Deployment (`dev2stg.sh`)

| # | Task | Status | Description |
|---|------|--------|-------------|
| 4.1.1 | Create `dev2stg.sh` script | ⬜ | Dev → Stage deployment |
| 4.1.2 | Export config before sync | ⬜ | `drush cex` integration |
| 4.1.3 | Rsync with intelligent exclusions | ⬜ | See exclusion list below |
| 4.1.4 | Run `composer install --no-dev` | ⬜ | Production dependencies |
| 4.1.5 | Run database updates | ⬜ | `drush updb` |
| 4.1.6 | Import config | ⬜ | `drush cim` |
| 4.1.7 | Handle module reinstallation | ⬜ | Reinstall specified modules |
| 4.1.8 | Maintenance/readonly mode handling | ⬜ | Toggle site modes |
| 4.1.9 | Clear cache | ⬜ | `drush cr` |
| 4.1.10 | Step-based execution | ⬜ | Resume capability |
| 4.1.11 | Support `--yes` flag | ⬜ | Non-interactive mode |

**Rsync Exclusions:**
```bash
--exclude 'docroot/sites/default/settings.*'
--exclude 'docroot/sites/default/services.yml'
--exclude 'docroot/sites/default/files/'
--exclude '.git/'
--exclude '.gitignore'
--exclude 'private/'
--exclude '*/node_modules/'
--exclude 'node_modules/'
--exclude 'dev/'
```

### 4.2 Make Dev Mode (`makedev.sh`)

| # | Task | Status | Description |
|---|------|--------|-------------|
| 4.2.1 | Create `makedev.sh` script | ⬜ | Enable development mode |
| 4.2.2 | Install dev composer packages | ⬜ | `composer require --dev` |
| 4.2.3 | Enable dev Drupal modules | ⬜ | `drush en` |
| 4.2.4 | Turn on dev settings | ⬜ | `drupal site:mode dev` |
| 4.2.5 | Rebuild permissions | ⬜ | Fix file permissions |
| 4.2.6 | Clear cache | ⬜ | Cache rebuild |

**Reference from Pleasy:**
```bash
# From makedev.sh
drush @$sitename_var en -y $dev_modules
drupal site:mode dev
```

### 4.3 Make Production Mode (`makeprod.sh`)

| # | Task | Status | Description |
|---|------|--------|-------------|
| 4.3.1 | Create `makeprod.sh` script | ⬜ | Enable production mode |
| 4.3.2 | Turn on production settings | ⬜ | `drupal site:mode prod` |
| 4.3.3 | Uninstall dev modules | ⬜ | `drush pm-uninstall` |
| 4.3.4 | Run `composer install --no-dev` | ⬜ | Production dependencies only |
| 4.3.5 | Remove and re-export config | ⬜ | Clean config export |
| 4.3.6 | Rebuild permissions | ⬜ | Fix file permissions |
| 4.3.7 | Clear cache | ⬜ | Cache rebuild |

---

## 5. Configuration System Enhancements

### 5.1 Enhanced YAML Configuration

Add the following configuration options to `cnwp.yml`:

| # | Configuration Key | Type | Description |
|---|-------------------|------|-------------|
| 5.1.1 | `site_path` | string | Custom installation paths |
| 5.1.2 | `private` | string | Private directory path |
| 5.1.3 | `cmi` | string | Config management directory |
| 5.1.4 | `dev_modules` | list | Development Drupal modules |
| 5.1.5 | `dev_composer` | list | Dev composer packages |
| 5.1.6 | `reinstall_modules` | list | Modules to reinstall during sync |
| 5.1.7 | `prod_method` | string | Production method (git, tar, rsync) |
| 5.1.8 | `prod_gitrepo` | string | Production git repository |
| 5.1.9 | `prod_gitdb` | string | Production database git repo |
| 5.1.10 | `prod_alias` | string | SSH alias for production |
| 5.1.11 | `git_upstream` | string | Upstream repository |
| 5.1.12 | `theme` | string | Theme for npm/gulp setup |
| 5.1.13 | `force` | boolean | Force config imports |
| 5.1.14 | `lando` | boolean | Use Lando instead of DDEV |

**Example Enhanced Configuration:**
```yaml
recipes:
  mysite:
    source: goalgorilla/social_template:dev-master
    profile: social
    webroot: html
    site_path: /var/www/sites
    private: ../private
    cmi: ../cmi
    dev_modules: devel kint webprofiler
    dev_composer: drupal/devel drupal/stage_file_proxy
    reinstall_modules: custom_module
    prod_method: git
    prod_gitrepo: git@github.com:user/prod-site.git
    prod_alias: user@production.server.com
    theme: flavor
```

### 5.2 Configuration Parsing

| # | Task | Status | Description |
|---|------|--------|-------------|
| 5.2.1 | Create `parse_pl_yml` equivalent | ⬜ | Parse full configuration |
| 5.2.2 | Create `import_site_config` function | ⬜ | Load recipe-specific settings |
| 5.2.3 | Support variable inheritance/defaults | ⬜ | Default value handling |

---

## 6. Shared Helper Functions Library

### 6.1 Core Functions

Create a `functions.sh` or `lib/helpers.sh` file with:

| # | Function | Description |
|---|----------|-------------|
| 6.1.1 | `backup_db` | Database backup function |
| 6.1.2 | `backup_site` | Full site backup function |
| 6.1.3 | `backup_prod` | Production backup function |
| 6.1.4 | `restore_db` | Database restore function |
| 6.1.5 | `fix_site_settings` | Fix settings.php for a site |
| 6.1.6 | `set_site_permissions` | Set proper file permissions |
| 6.1.7 | `copy_site_files` | Copy site files between locations |
| 6.1.8 | `db_defaults` | Set database default values |
| 6.1.9 | `site_info` | Display site information |
| 6.1.10 | `ocmsg` | Output conditional message (debug mode) |

### 6.2 Output/Messaging Functions

| # | Function | Description |
|---|----------|-------------|
| 6.2.1 | `ocmsg` | Conditional debug output |
| 6.2.2 | Color variables | `$Cyan`, `$Color_Off`, etc. (partially exists) |
| 6.2.3 | Timer display | Show execution duration (already exists) |

**Example Implementation:**
```bash
# Conditional debug message
ocmsg() {
    local message=$1
    local level=${2:-info}
    
    if [[ "$verbose" == "debug" ]] || [[ "$level" != "debug" ]]; then
        echo -e "$message"
    fi
}
```

---

## 7. Drush Integration

### 7.1 Drush Aliases

| # | Task | Status | Description |
|---|------|--------|-------------|
| 7.1.1 | Auto-generate Drush aliases | ⬜ | Create `@sitename` aliases |
| 7.1.2 | Support for remote aliases | ⬜ | `@prod` remote access |
| 7.1.3 | `drush core:init` integration | ⬜ | Initialize Drush config |

### 7.2 Drush Commands Integration

| # | Command | Purpose |
|---|---------|---------|
| 7.2.1 | `drush cex` | Config export |
| 7.2.2 | `drush cim` | Config import |
| 7.2.3 | `drush updb` | Database updates |
| 7.2.4 | `drush cr` | Cache rebuild |
| 7.2.5 | `drush uli` | User login (already exists) |
| 7.2.6 | `drush sset system.maintenance_mode` | Maintenance mode |
| 7.2.7 | `drush cset readonlymode.settings enabled` | Read-only mode |

---

## 8. Installation Enhancements

### 8.1 Additional Installation Methods

| # | Task | Status | Description |
|---|------|--------|-------------|
| 8.1.1 | Add `file` installation method | ⬜ | Download tarball |
| 8.1.2 | Support `git` installation method | ⬜ | SSH key handling |
| 8.1.3 | Support git upstream configuration | ⬜ | Track upstream repos |
| 8.1.4 | Add Lando installation support | ⬜ | Alternative to DDEV |

**Reference from Pleasy install.sh:**
```bash
if [ "$install_method" == "git" ]; then
    # Git installation with SSH key
elif [ "$install_method" == "composer" ]; then
    # Composer installation
elif [ "$install_method" == "file" ]; then
    # Tarball download
fi
```

### 8.2 Post-Installation Features

| # | Task | Status | Description |
|---|------|--------|-------------|
| 8.2.1 | npm/yarn/bower installation | ⬜ | Theme dependencies |
| 8.2.2 | Gulp support setup | ⬜ | Task runner configuration |
| 8.2.3 | Custom theme directory detection | ⬜ | `themes/custom` vs `themes/contrib` |
| 8.2.4 | Sudo URI setup | ⬜ | Local development URLs |

---

## 9. Multi-Environment Support

### 9.1 Environment Types

| # | Task | Status | Description |
|---|------|--------|-------------|
| 9.1.1 | Support `stg_` prefix convention | ⬜ | Staging environment naming |
| 9.1.2 | Support `prod` suffix convention | ⬜ | Production environment naming |
| 9.1.3 | Environment-specific configuration | ⬜ | Per-environment settings |

### 9.2 Production Management

| # | Task | Status | Description |
|---|------|--------|-------------|
| 9.2.1 | SSH-based production operations | ⬜ | Remote command execution |
| 9.2.2 | Git-based production deployment | ⬜ | Deploy via git |
| 9.2.3 | Production database sync | ⬜ | Pull/push database |
| 9.2.4 | Production file sync | ⬜ | Sync files to/from prod |

---

## 10. Command-Line Interface Improvements

### 10.1 Unified CLI (`pl` equivalent)

| # | Task | Status | Description |
|---|------|--------|-------------|
| 10.1.1 | Create main `nwp` command wrapper | ⬜ | Single entry point |
| 10.1.2 | Subcommand routing | ⬜ | e.g., `nwp backup dev` |
| 10.1.3 | Consistent argument parsing | ⬜ | Unified across scripts |
| 10.1.4 | Global `--debug` flag | ⬜ | Debug mode everywhere |
| 10.1.5 | Global `--yes` flag | ⬜ | Non-interactive mode |

**Example Usage:**
```bash
nwp install os          # Install using 'os' recipe
nwp backup dev          # Backup dev site
nwp restore prod stg    # Restore prod to stg
nwp copy dev stg        # Copy dev to stg
nwp makedev loc         # Enable dev mode on loc
nwp makeprod stg        # Enable prod mode on stg
nwp dev2stg d9          # Deploy d9 to stg_d9
```

### 10.2 Help System

| # | Task | Status | Description |
|---|------|--------|-------------|
| 10.2.1 | Consistent `--help` output format | ⬜ | Uniform help messages |
| 10.2.2 | Examples in all help messages | ⬜ | Usage examples |
| 10.2.3 | Man page generation (optional) | ⬜ | System documentation |

---

## 11. Utility Scripts

| # | Script | Status | Description |
|---|--------|--------|-------------|
| 11.1 | `list.sh` | ⬜ | List all installed sites |
| 11.2 | `status.sh` | ⬜ | Show site status (DDEV, DB, files) |
| 11.3 | `delete.sh` | ⬜ | Clean removal of a site |
| 11.4 | `update.sh` | ⬜ | Update Drupal core/modules |
| 11.5 | `sync.sh` | ⬜ | Sync between environments |

---

## 12. Error Handling & Validation

| # | Task | Status | Description |
|---|------|--------|-------------|
| 12.1 | Directory existence validation | ⬜ | Check before operations |
| 12.2 | Database connection validation | ⬜ | Verify DB access |
| 12.3 | Improved error messages | ⬜ | Suggested fixes |
| 12.4 | Add `set -e` or proper error handling | ⬜ | Fail-safe execution |
| 12.5 | Rollback capability | ⬜ | Undo failed operations |

---

## Priority Implementation Order

### Phase 1: Essential Backup/Restore (Critical)

**Priority: HIGH** | **Estimated Effort: 2-3 days**

| # | Task | Status |
|---|------|--------|
| P1.1 | Backup system (`backup.sh`, `backupdb.sh`) | ⬜ |
| P1.2 | Restore system (`restore.sh`, `restoredb.sh`) | ⬜ |
| P1.3 | Shared functions library (`functions.sh`) | ⬜ |

### Phase 2: Site Management

**Priority: HIGH** | **Estimated Effort: 2 days**

| # | Task | Status |
|---|------|--------|
| P2.1 | Copy scripts (`copy.sh`, `copyf.sh`) | ⬜ |
| P2.2 | Delete/cleanup script | ⬜ |
| P2.3 | Enhanced configuration system | ⬜ |

### Phase 3: Development Workflow

**Priority: MEDIUM** | **Estimated Effort: 2-3 days**

| # | Task | Status |
|---|------|--------|
| P3.1 | Dev/prod mode scripts (`makedev.sh`, `makeprod.sh`) | ⬜ |
| P3.2 | Dev to stage deployment (`dev2stg.sh`) | ⬜ |
| P3.3 | Drush alias integration | ⬜ |

### Phase 4: Advanced Features

**Priority: LOW** | **Estimated Effort: 3-4 days**

| # | Task | Status |
|---|------|--------|
| P4.1 | Multi-environment support | ⬜ |
| P4.2 | Production management | ⬜ |
| P4.3 | Unified CLI wrapper | ⬜ |

---

## Summary Statistics

| Section | Total Tasks |
|---------|-------------|
| 1. Backup System | 11 |
| 2. Restore System | 13 |
| 3. Site Copy/Clone System | 12 |
| 4. Development Workflow Scripts | 24 |
| 5. Configuration System Enhancements | 17 |
| 6. Shared Helper Functions Library | 13 |
| 7. Drush Integration | 10 |
| 8. Installation Enhancements | 8 |
| 9. Multi-Environment Support | 7 |
| 10. Command-Line Interface Improvements | 8 |
| 11. Utility Scripts | 5 |
| 12. Error Handling & Validation | 5 |
| **TOTAL** | **133** |

---

## File Structure After Implementation

```
nwp/
├── cnwp.yml                    # Configuration file
├── install.sh                  # Main installation script
├── setup.sh                    # Prerequisites setup
├── nwp                         # Main CLI wrapper (new)
├── README.md                   # Documentation
├── LICENSE                     # License file
│
├── scripts/                    # All operational scripts (new)
│   ├── backup.sh               # Full backup
│   ├── backupdb.sh             # Database backup
│   ├── restore.sh              # Full restore
│   ├── restoredb.sh            # Database restore
│   ├── copy.sh                 # Full site copy
│   ├── copyf.sh                # Files-only copy
│   ├── copypt.sh               # Prod to test copy
│   ├── dev2stg.sh              # Dev to stage deployment
│   ├── makedev.sh              # Enable dev mode
│   ├── makeprod.sh             # Enable prod mode
│   ├── delete.sh               # Delete site
│   ├── status.sh               # Site status
│   ├── list.sh                 # List sites
│   ├── update.sh               # Update site
│   └── sync.sh                 # Sync environments
│
├── lib/                        # Shared libraries (new)
│   ├── functions.sh            # Core helper functions
│   ├── colors.sh               # Color definitions
│   ├── config.sh               # Configuration parsing
│   └── drush.sh                # Drush integration
│
├── sitebackups/                # Backup storage (new)
│   ├── dev/
│   ├── stg/
│   └── prod/
│
└── <recipe-dirs>/              # Installed projects
    ├── .ddev/
    ├── composer.json
    ├── web/ or html/
    ├── vendor/
    ├── private/
    └── cmi/
```

---

## Notes

- All scripts should follow the existing NWP coding style
- Maintain DDEV compatibility throughout
- Preserve backwards compatibility with existing `cnwp.yml` format
- Add comprehensive logging for all operations
- Include dry-run mode where applicable

---

## Contributing

When implementing these improvements:

1. Create feature branches for each phase
2. Include tests using BATS framework
3. Update README.md with new features
4. Add inline documentation
5. Follow existing code conventions

---

*Document created: December 2024*
*Based on comparison of Pleasy and NWP codebases*
