# NWP Developer Training Booklet

**Narrow Way Project - Complete Developer Guide**

Version 1.0 | January 2026

---

## Table of Contents

1. [Introduction](#1-introduction)
2. [Prerequisites](#2-prerequisites)
3. [Setup & Installation](#3-setup--installation)
4. [Core Operations](#4-core-operations)
   - 4.1 [Backup Operations](#41-backup-operations)
   - 4.2 [Restore Operations](#42-restore-operations)
   - 4.3 [Copy Operations](#43-copy-operations)
   - 4.4 [Delete Operations](#44-delete-operations)
   - 4.5 [Development Modes](#45-development-modes)
   - 4.6 [Status & Monitoring](#46-status--monitoring)
5. [Deployment Pipeline](#5-deployment-pipeline)
   - 5.1 [Environment Concepts](#51-environment-concepts)
   - 5.2 [Dev to Staging](#52-dev-to-staging)
   - 5.3 [Staging to Production](#53-staging-to-production)
   - 5.4 [Production to Staging Sync](#54-production-to-staging-sync)
   - 5.5 [Live Server Deployment](#55-live-server-deployment)
   - 5.6 [Security Hardening](#56-security-hardening)
6. [Advanced Topics](#6-advanced-topics)
   - 6.1 [GitLab Infrastructure](#61-gitlab-infrastructure)
   - 6.2 [Linode Deployment](#62-linode-deployment)
   - 6.3 [Podcast Infrastructure](#63-podcast-infrastructure)
   - 6.4 [Custom Development](#64-custom-development)
7. [Quick Reference](#7-quick-reference)
8. [Troubleshooting](#8-troubleshooting)
9. [Glossary](#9-glossary)

---

# 1. Introduction

## What is NWP?

The Narrow Way Project (NWP) is a streamlined installation and management system for Drupal and Moodle projects. It uses DDEV for local development environments and a recipe-based configuration system that makes setting up and managing multiple sites simple and repeatable.

## Key Benefits

- **Recipe-based configuration**: Define project templates in a single YAML file
- **Automated setup**: One command installs all prerequisites
- **Multiple CMS support**: Drupal, OpenSocial, and Moodle
- **Complete lifecycle management**: Install, backup, restore, copy, deploy
- **Environment pipeline**: Dev → Staging → Production workflow
- **Infrastructure automation**: GitLab, Linode, and Cloudflare integration

## Architecture Overview

```
NWP Directory Structure
========================

nwp/
├── Core Scripts
│   ├── setup.sh          # Install prerequisites
│   ├── install.sh        # Create new sites
│   ├── backup.sh         # Backup sites
│   ├── restore.sh        # Restore from backups
│   ├── copy.sh           # Duplicate sites
│   ├── delete.sh         # Remove sites
│   ├── make.sh           # Toggle dev/prod mode
│   └── status.sh         # Check site health
│
├── Deployment Scripts
│   ├── dev2stg.sh        # Dev → Staging
│   ├── stg2prod.sh       # Staging → Production
│   ├── prod2stg.sh       # Production → Staging sync
│   ├── live.sh           # Deploy to live server
│   └── security.sh       # Security hardening
│
├── Configuration
│   ├── cnwp.yml          # Your site configurations (gitignored)
│   ├── example.cnwp.yml  # Configuration template
│   └── .secrets.yml      # API keys and passwords (gitignored)
│
├── Libraries
│   └── lib/              # Shared bash functions
│
├── Infrastructure
│   ├── linode/           # Linode deployment scripts
│   ├── git/              # GitLab infrastructure
│   └── templates/        # Site templates
│
└── Site Directories
    ├── nwp1/             # Installed site
    ├── nwp2/             # Another site
    └── mysite_stg/       # Staging environment
```

## How NWP Works

1. **Configuration**: Define sites in `cnwp.yml` using recipes
2. **Installation**: Run `./install.sh <recipe>` to create a site
3. **Development**: Use DDEV commands to work on the site
4. **Management**: Use NWP scripts for backup, restore, copy
5. **Deployment**: Promote through dev → staging → production

---

# 2. Prerequisites

## Required Knowledge

Before using NWP, you should be comfortable with:

### Linux Command Line
- Navigating directories (`cd`, `ls`, `pwd`)
- File operations (`cp`, `mv`, `rm`, `mkdir`)
- Viewing files (`cat`, `less`, `head`, `tail`)
- Permissions (`chmod`, `chown`)
- Environment variables (`export`, `echo $VAR`)

### Docker Basics
- Understanding containers vs images
- Basic commands (`docker ps`, `docker logs`)
- Docker Compose concepts
- Port mapping and volumes

### Git Fundamentals
- Cloning repositories
- Basic commands (`status`, `add`, `commit`, `push`, `pull`)
- Branching concepts
- Understanding `.gitignore`

## Self-Assessment Questions

Test your readiness:

1. How do you list all files including hidden ones?
   <details><summary>Answer</summary>ls -la</details>

2. How do you view running Docker containers?
   <details><summary>Answer</summary>docker ps</details>

3. How do you check the current Git branch?
   <details><summary>Answer</summary>git branch or git status</details>

4. What does `chmod 755 script.sh` do?
   <details><summary>Answer</summary>Makes script.sh executable by owner, readable/executable by others</details>

## Required Software

NWP requires:
- Docker
- DDEV
- Composer
- Git
- mkcert (for local HTTPS)

**Don't worry!** The `setup.sh` script will install any missing prerequisites automatically.

---

# 3. Setup & Installation

## 3.1 Initial Setup

### Clone the Repository

```bash
git clone git@github.com:rjzaar/nwp.git
cd nwp
```

### Run Setup Script

```bash
./setup.sh
```

The setup script will:
1. Check which prerequisites are already installed
2. Install only the missing ones
3. Configure your system for DDEV
4. Verify everything is working

### Expected Output

```
NWP Setup Script
================

Checking prerequisites...
  [✓] Docker installed (version 24.0.7)
  [✓] DDEV installed (version 1.22.4)
  [✗] mkcert not installed

Installing mkcert...
  [✓] mkcert installed successfully

All prerequisites installed!
```

## 3.2 Understanding cnwp.yml

The `cnwp.yml` file is the heart of NWP. It defines all your sites and their configurations.

### Creating Your Configuration

```bash
cp example.cnwp.yml cnwp.yml
```

### Configuration Structure

```yaml
# Global settings (apply to all recipes)
settings:
  database: mariadb
  php: "8.2"

# Recipe definitions
recipes:
  # Standard Drupal site
  d:
    source: drupal/recommended-project:^10.2
    profile: standard
    webroot: web
    auto: y

  # OpenSocial site
  os:
    source: goalgorilla/social_template:dev-master
    profile: social
    webroot: html
    auto: y

  # Custom site with modules
  mysite:
    source: drupal/recommended-project:^10.2
    profile: standard
    webroot: web
    install_modules: drupal/admin_toolbar drupal/pathauto
    auto: y
```

### Required Fields

| Field | Description | Example |
|-------|-------------|---------|
| `source` | Composer package | `drupal/recommended-project:^10.2` |
| `profile` | Installation profile | `standard`, `social` |
| `webroot` | Web root directory | `web`, `html` |

### Optional Fields

| Field | Description | Example |
|-------|-------------|---------|
| `install_modules` | Additional modules | `drupal/admin_toolbar` |
| `auto` | Skip confirmations | `y` |
| `sitename` | Custom site name | `"My Project"` |

## 3.3 Installing Your First Site

### List Available Recipes

```bash
./install.sh --list
```

Output:
```
Available Recipes
=================

  d      Standard Drupal 10
  os     OpenSocial
  nwp    OpenSocial with workflow
  dm     Drupal with Divine Mercy
  m      Moodle LMS
```

### Install a Site

```bash
./install.sh d
```

This creates a new Drupal site in `./d/` (or `./d1/` if `d` exists).

### Install with Custom Name

```bash
./install.sh d myproject
```

Creates the site in `./myproject/`.

### Install with Test Content

```bash
./install.sh d c
```

The `c` flag creates test users and content for development.

### Resume Failed Installation

If installation fails at step 5:

```bash
./install.sh d s=5
```

### Installation Steps

1. DDEV configuration
2. Composer project creation
3. Drush installation
4. Additional modules (if specified)
5. Site installation
6. Cache clear and rebuild
7. Login URL generation
8. Test content creation (if requested)

## 3.4 Accessing Your Site

After installation:

```bash
cd myproject
ddev launch      # Opens site in browser
ddev drush uli   # Generates admin login link
```

Your site is available at: `https://myproject.ddev.site`

---

# 4. Core Operations

## 4.1 Backup Operations

The `backup.sh` script creates complete backups of your sites including database and files.

### Basic Backup

```bash
./backup.sh nwp5
```

This creates:
- Full backup in `./sitebackups/nwp5/`
- Includes database dump and all files
- Timestamped backup directory

### Database-Only Backup

```bash
./backup.sh -b nwp5
```

The `-b` flag creates a database-only backup (faster, smaller).

### Backup with Description

```bash
./backup.sh -b nwp5 "Before major update"
```

Add a description to identify the backup later.

### Auto-Confirm Backup

```bash
./backup.sh -y nwp5
```

The `-y` flag skips confirmation prompts.

### Combined Flags

```bash
./backup.sh -by nwp5 "Pre-release backup"
```

Combines database-only (`-b`) with auto-confirm (`-y`).

### Backup Directory Structure

```
sitebackups/
└── nwp5/
    └── 2026-01-03_14-30-00_Pre-release-backup/
        ├── database.sql.gz
        ├── files.tar.gz (full backup only)
        └── backup.info
```

### Practice Exercises

1. Create a full backup of site `test1`
2. Create a database-only backup with description "Before migration"
3. Create an auto-confirmed database backup

<details>
<summary>Solutions</summary>

```bash
# Exercise 1
./backup.sh test1

# Exercise 2
./backup.sh -b test1 "Before migration"

# Exercise 3
./backup.sh -by test1
```
</details>

---

## 4.2 Restore Operations

The `restore.sh` script restores sites from backups.

### Basic Restore

```bash
./restore.sh nwp5
```

Presents a list of available backups to choose from.

### Auto-Select Latest Backup

```bash
./restore.sh -f nwp5
```

The `-f` flag automatically selects the most recent backup.

### Database-Only Restore

```bash
./restore.sh -b nwp5
```

Restores only the database (keeps current files).

### Open Login Link After Restore

```bash
./restore.sh -o nwp5
```

Opens a one-time login link after restoration.

### Combined Restore

```bash
./restore.sh -bfyo nwp5
```

Database-only, latest backup, auto-confirm, open login.

### Cross-Site Restoration

Restore a backup to a different site:

```bash
./restore.sh -s nwp5_backup nwp5
```

This restores from `nwp5_backup` to `nwp5`.

### Restore Process

1. Lists available backups with timestamps
2. Confirms restoration (unless `-y`)
3. Stops the site
4. Restores database and/or files
5. Clears caches
6. Restarts the site
7. Generates login link (if `-o`)

### Practice Exercises

1. Restore site `test1` from its latest backup
2. Restore only the database with auto-confirm
3. Restore and open login link

<details>
<summary>Solutions</summary>

```bash
# Exercise 1
./restore.sh -f test1

# Exercise 2
./restore.sh -bfy test1

# Exercise 3
./restore.sh -fyo test1
```
</details>

---

## 4.3 Copy Operations

The `copy.sh` script duplicates sites.

### Full Copy

```bash
./copy.sh nwp5 nwp6
```

Creates an exact copy including:
- All files
- Complete database
- DDEV configuration

### Files-Only Copy

```bash
./copy.sh -f nwp5 nwp6
```

Copies only files, preserving the destination database.

Use this when:
- You want to update code without losing data
- Testing new features on existing content
- Syncing code between environments

### Auto-Confirm Copy

```bash
./copy.sh -y nwp5 nwp6
```

### Copy to New Site

If the destination doesn't exist, it will be created:

```bash
./copy.sh nwp5 newsite
```

### Copy Process

1. Verifies source site exists
2. Creates destination if needed
3. Stops both sites
4. Copies files and/or database
5. Updates DDEV configuration
6. Restarts destination site

### Practice Exercises

1. Create a full copy of `test1` to `test2`
2. Copy only files from `dev` to `staging`
3. Create an auto-confirmed copy

<details>
<summary>Solutions</summary>

```bash
# Exercise 1
./copy.sh test1 test2

# Exercise 2
./copy.sh -f dev staging

# Exercise 3
./copy.sh -y test1 test2
```
</details>

---

## 4.4 Delete Operations

The `delete.sh` script safely removes sites.

### Basic Delete

```bash
./delete.sh nwp5
```

Prompts for confirmation before deleting.

### Backup Before Delete

```bash
./delete.sh -b nwp5
```

Creates a backup before deletion (recommended).

### Auto-Confirm Delete

```bash
./delete.sh -y nwp5
```

**Use with caution!** Skips confirmation.

### Combined Delete

```bash
./delete.sh -by nwp5
```

Backup and delete with auto-confirm.

### Safety Features

1. **Confirmation prompt**: Requires typing the site name
2. **Backup option**: Create safety backup first
3. **Purpose protection**: Permanent sites require config change
4. **Staging protection**: Warns about related environments

### Site Purpose

Sites can have a purpose that affects deletion:

| Purpose | Behavior |
|---------|----------|
| `testing` | Can be freely deleted |
| `indefinite` | Normal deletion (default) |
| `permanent` | Must change purpose in cnwp.yml first |

### Practice Exercises

1. Delete site `test1` with backup
2. Delete site `temp` with auto-confirm

<details>
<summary>Solutions</summary>

```bash
# Exercise 1
./delete.sh -b test1

# Exercise 2
./delete.sh -y temp
```
</details>

---

## 4.5 Development Modes

The `make.sh` script toggles between development and production modes.

### Enable Development Mode

```bash
./make.sh -v nwp5
```

Development mode enables:
- Error display
- Debugging tools
- Cache disabled
- Twig debugging
- Verbose logging

### Enable Production Mode

```bash
./make.sh -p nwp5
```

Production mode enables:
- Error hiding
- Full caching
- Optimized assets
- Security hardening

### Auto-Confirm Mode Change

```bash
./make.sh -vy nwp5   # Dev mode, auto-confirm
./make.sh -py nwp5   # Prod mode, auto-confirm
```

### When to Use Each Mode

| Mode | Use When |
|------|----------|
| Development | Active coding, debugging, testing |
| Production | Staging review, performance testing, live sites |

### What Changes

**Development Mode:**
```php
$settings['container_yamls'][] = 'development.services.yml';
$config['system.logging']['error_level'] = 'verbose';
$config['system.performance']['css']['preprocess'] = FALSE;
$config['system.performance']['js']['preprocess'] = FALSE;
```

**Production Mode:**
```php
$config['system.logging']['error_level'] = 'hide';
$config['system.performance']['css']['preprocess'] = TRUE;
$config['system.performance']['js']['preprocess'] = TRUE;
```

### Practice Exercises

1. Enable development mode on `test1`
2. Switch `staging` to production mode
3. Toggle dev mode with auto-confirm

<details>
<summary>Solutions</summary>

```bash
# Exercise 1
./make.sh -v test1

# Exercise 2
./make.sh -p staging

# Exercise 3
./make.sh -vy test1
```
</details>

---

## 4.6 Status & Monitoring

The `status.sh` script shows the health and status of your sites.

### Check All Sites

```bash
./status.sh
```

Shows:
- Running/stopped status
- URLs
- Database connection
- Disk usage

### Check Specific Site

```bash
./status.sh nwp5
```

Detailed information for one site.

### Status Output

```
NWP Site Status
===============

Site: nwp5
  Status:     Running
  URL:        https://nwp5.ddev.site
  Webroot:    html
  PHP:        8.2
  Database:   mariadb

  Health Checks:
    [✓] DDEV container running
    [✓] Database connected
    [✓] Web server responding
    [✓] Drupal bootstrap OK

  Disk Usage:
    Files:     245 MB
    Database:  18 MB
    Total:     263 MB
```

### Health Check Details

| Check | What It Tests |
|-------|---------------|
| DDEV container | Is Docker container running? |
| Database | Can connect to MySQL/MariaDB? |
| Web server | Does nginx/Apache respond? |
| Drupal bootstrap | Can Drupal initialize? |

### Troubleshooting with Status

If a check fails:

```
[✗] Database connected
    Error: Can't connect to MySQL server

    Try: ddev restart
```

### Practice Exercises

1. Check status of all sites
2. Check detailed status of `test1`
3. Identify which health check is failing

<details>
<summary>Solutions</summary>

```bash
# Exercise 1
./status.sh

# Exercise 2
./status.sh test1

# Exercise 3 - Look for [✗] in output
./status.sh test1 | grep "✗"
```
</details>

---

# 5. Deployment Pipeline

## 5.1 Environment Concepts

### The Three Environments

```
┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│ Development │───▶│   Staging   │───▶│ Production  │
│   (local)   │    │   (local)   │    │  (server)   │
└─────────────┘    └─────────────┘    └─────────────┘
     nwp5           nwp5_stg           nwp5_prod
```

### Environment Purposes

| Environment | Purpose | Mode | Location |
|-------------|---------|------|----------|
| **Development** | Active coding, experimentation | Dev mode | Local |
| **Staging** | Testing, review, pre-production | **Production mode** | Local or server |
| **Production** | Live site, real users | Production mode | Server |

> **Important**: Staging runs in production mode to mirror the live environment. This catches production-only bugs before they reach users.

### Naming Convention

NWP uses postfix naming:

| Environment | Naming Pattern | Example |
|-------------|---------------|---------|
| Development | `sitename` | `nwp5` |
| Staging | `sitename_stg` | `nwp5_stg` |
| Production | `sitename_prod` | `nwp5_prod` |

### Deployment Flow

```
Development ──dev2stg──▶ Staging ──stg2prod──▶ Production
     ▲                       │                      │
     │                       │                      │
     └───────────────────────┴──────────────────────┘
              prod2stg (sync content back)
```

---

## 5.2 Dev to Staging

The `dev2stg.sh` script deploys from development to staging.

### Basic Deployment

```bash
./dev2stg.sh nwp5
```

This creates/updates `nwp5_stg`.

### What Happens (10 Steps)

1. Validates dev and staging sites exist
2. Exports configuration from dev
3. Syncs files to staging (excludes settings, .git, files/)
4. Runs `composer install --no-dev` (removes dev packages)
5. Runs database updates
6. Imports configuration
7. Reinstalls specified modules (if configured)
8. Clears caches
9. **Enables production mode** (disables dev modules, enables caching)
10. Displays staging URL

> **Key Point**: Staging automatically runs in production mode to mirror the live environment. This catches production-only bugs before they reach users.

### Auto-Confirm Deployment

```bash
./dev2stg.sh -y nwp5
```

### Deployment Checklist

Before deploying to staging:
- [ ] All code changes committed
- [ ] Tests passing locally
- [ ] No debug code left in
- [ ] Database migrations ready

### Staging Best Practices

1. **Always test in staging** before production
2. **Share staging URL** with stakeholders for review
3. **Run full test suite** in staging
4. **Check mobile/responsive** behavior

### Practice Exercises

1. Deploy `test1` to staging
2. Deploy with auto-confirm
3. Verify staging site is running

<details>
<summary>Solutions</summary>

```bash
# Exercise 1
./dev2stg.sh test1

# Exercise 2
./dev2stg.sh -y test1

# Exercise 3
./status.sh test1_stg
```
</details>

---

## 5.3 Staging to Production

The `stg2prod.sh` script deploys from staging to production.

### Basic Deployment

```bash
./stg2prod.sh nwp5
```

Deploys `nwp5_stg` to `nwp5_prod`.

### Pre-Deployment Backup

```bash
./stg2prod.sh -b nwp5
```

Creates a backup of production before deploying.

### Production Deployment Process

1. **Backup** production (if `-b`)
2. **Maintenance mode** on production
3. **Copy files** from staging
4. **Database sync** (configurable)
5. **Run updates** (`drush updb`)
6. **Clear caches**
7. **Disable maintenance** mode
8. **Verify** site is working

### Database Handling Options

| Option | Behavior |
|--------|----------|
| Default | Copy staging database (overwrites production) |
| `-f` | Files only, keep production database |
| `-m` | Run migrations only |

### Production Safety Checklist

Before deploying to production:
- [ ] Staging fully tested
- [ ] Stakeholder approval received
- [ ] Backup of production exists
- [ ] Rollback plan ready
- [ ] Maintenance window scheduled
- [ ] Team notified

### Rollback Procedure

If something goes wrong:

```bash
# Restore from backup
./restore.sh -f nwp5_prod

# Or sync back from a known good state
./prod2stg.sh nwp5  # If staging is still good
```

### Practice Exercises

1. Deploy staging to production with backup
2. Deploy files only (preserve production database)

<details>
<summary>Solutions</summary>

```bash
# Exercise 1
./stg2prod.sh -b test1

# Exercise 2
./stg2prod.sh -f test1
```
</details>

---

## 5.4 Production to Staging Sync

The `prod2stg.sh` script syncs production content back to staging.

### Why Sync Back?

- Get real user content for testing
- Debug production issues locally
- Verify fixes against real data

### Basic Sync

```bash
./prod2stg.sh nwp5
```

Copies production database to staging.

### What Gets Synced

| Content | Synced |
|---------|--------|
| Database | Yes |
| User-uploaded files | Yes (optional) |
| Code | No (staging has dev code) |

### Sanitization

Production data may contain sensitive information:

```bash
./prod2stg.sh -s nwp5
```

The `-s` flag sanitizes:
- User emails → `user1@example.com`
- Passwords → reset to test password
- Personal data → anonymized

### Practice Exercises

1. Sync production to staging
2. Sync with sanitization

<details>
<summary>Solutions</summary>

```bash
# Exercise 1
./prod2stg.sh test1

# Exercise 2
./prod2stg.sh -s test1
```
</details>

---

## 5.5 Live Server Deployment

The `live.sh` script deploys sites to live servers (Linode).

### Prerequisites

1. Linode account configured
2. SSH keys set up (`./setup-ssh.sh`)
3. Domain configured in Cloudflare

### Basic Live Deployment

```bash
./live.sh nwp5
```

Creates a live site at `nwp5.nwpcode.org`.

### What Happens

1. Provisions Linode server (if needed)
2. Configures DNS via Cloudflare
3. Sets up SSL certificate
4. Deploys site files and database
5. Configures web server
6. Runs security hardening

### Live Deployment Options

| Option | Effect |
|--------|--------|
| `-n` | New server (don't reuse existing) |
| `-s` | Skip DNS setup |
| `-h` | Harden security |

### Staging to Live

```bash
./stg2live.sh nwp5
```

Promotes staging to live server.

### Live to Staging

```bash
./live2stg.sh nwp5
```

Syncs live content back to local staging.

---

## 5.6 Security Hardening

The `security.sh` script applies security hardening.

### Run Security Hardening

```bash
./security.sh nwp5
```

### What Gets Hardened

| Category | Actions |
|----------|---------|
| **Drupal modules** | seckit, security_review, paranoia |
| **File permissions** | Correct ownership, no world-writable |
| **Settings** | Trusted host patterns, secure cookies |
| **Headers** | CSP, X-Frame-Options, HSTS |

### Security Checklist

- [ ] Security modules installed
- [ ] File permissions correct
- [ ] Trusted hosts configured
- [ ] HTTPS enforced
- [ ] Admin paths protected
- [ ] Error messages hidden
- [ ] Updates applied

### Practice Exercises

1. Run security hardening on `test1`
2. Verify security modules are installed

<details>
<summary>Solutions</summary>

```bash
# Exercise 1
./security.sh test1

# Exercise 2
cd test1 && ddev drush pm:list | grep security
```
</details>

---

# 6. Advanced Topics

## 6.1 GitLab Infrastructure

NWP includes automated GitLab server deployment.

### Quick GitLab Setup

```bash
cd git
./setup_gitlab_site.sh
```

Creates a GitLab instance at `git.<your-domain>`.

### GitLab Features

- Self-hosted Git repositories
- CI/CD pipelines
- Issue tracking
- Container registry

### Connecting Sites to GitLab

```bash
./git/setup_gitlab_repo.sh nwp5
```

Creates a repository and configures the site.

---

## 6.2 Linode Deployment

### Linode Setup

```bash
./linode/linode_setup.sh
```

Configures Linode API access.

### Server Provisioning

```bash
./linode/linode_create_test_server.sh
```

Creates a test server for deployment testing.

### StackScripts

NWP uses StackScripts for automated server setup:

```bash
./linode/linode_upload_stackscript.sh
```

---

## 6.3 Podcast Infrastructure

NWP supports Castopod podcast hosting.

### Podcast Setup

```bash
./podcast.sh
```

Configures Castopod infrastructure.

### Features

- Podcast hosting
- RSS feed generation
- Episode management
- Analytics

---

## 6.4 Custom Development

### Creating Custom Recipes

Add to `cnwp.yml`:

```yaml
recipes:
  myrecipe:
    source: drupal/recommended-project:^10.2
    profile: standard
    webroot: web
    install_modules: >
      drupal/admin_toolbar
      drupal/pathauto
      drupal/metatag
    auto: y
```

### Using Git Repositories for Modules

```yaml
recipes:
  myrecipe:
    source: drupal/recommended-project:^10.2
    profile: standard
    webroot: web
    install_modules: git@github.com:username/my_module.git
```

### Contributing to NWP

1. Fork the repository
2. Create a feature branch
3. Make changes
4. Write tests
5. Submit pull request

### Library Functions

NWP's `lib/` directory contains reusable functions:

| Library | Purpose |
|---------|---------|
| `common.sh` | Shared utilities |
| `tui.sh` | Terminal UI |
| `yaml-write.sh` | YAML manipulation |
| `git.sh` | Git operations |
| `cloudflare.sh` | DNS management |

---

# 7. Quick Reference

## Command Summary

### Installation & Setup

| Command | Description |
|---------|-------------|
| `./setup.sh` | Install prerequisites |
| `./install.sh --list` | List available recipes |
| `./install.sh <recipe>` | Install a site |
| `./install.sh <recipe> <name>` | Install with custom name |
| `./install.sh <recipe> c` | Install with test content |
| `./install.sh <recipe> s=N` | Resume from step N |

### Site Management

| Command | Description |
|---------|-------------|
| `./backup.sh <site>` | Full backup |
| `./backup.sh -b <site>` | Database-only backup |
| `./restore.sh <site>` | Restore from backup |
| `./restore.sh -f <site>` | Restore latest backup |
| `./copy.sh <src> <dst>` | Copy site |
| `./copy.sh -f <src> <dst>` | Copy files only |
| `./delete.sh <site>` | Delete site |
| `./delete.sh -b <site>` | Backup then delete |

### Development

| Command | Description |
|---------|-------------|
| `./make.sh -v <site>` | Enable dev mode |
| `./make.sh -p <site>` | Enable prod mode |
| `./status.sh` | Check all sites |
| `./status.sh <site>` | Check specific site |

### Deployment

| Command | Description |
|---------|-------------|
| `./dev2stg.sh <site>` | Dev → Staging (auto-enables prod mode) |
| `./stg2prod.sh <site>` | Staging → Production |
| `./prod2stg.sh <site>` | Production → Staging |
| `./live.sh <site>` | Deploy to live server |
| `./security.sh <site>` | Security hardening |

## Common Flag Combinations

| Flags | Meaning |
|-------|---------|
| `-y` | Auto-confirm (skip prompts) |
| `-b` | Database-only (backup/restore) |
| `-f` | Files-only (copy) or latest (restore) |
| `-o` | Open login link after |
| `-by` | Database-only + auto-confirm |
| `-bfy` | Database-only + latest + auto-confirm |
| `-bfyo` | All flags combined |

## DDEV Commands

Within a site directory:

| Command | Description |
|---------|-------------|
| `ddev start` | Start the site |
| `ddev stop` | Stop the site |
| `ddev restart` | Restart the site |
| `ddev launch` | Open in browser |
| `ddev drush <cmd>` | Run Drush command |
| `ddev ssh` | SSH into container |
| `ddev logs` | View logs |
| `ddev describe` | Show site info |

---

# 8. Troubleshooting

## Common Issues

### Site Won't Start

**Symptom:** `ddev start` fails

**Solutions:**
```bash
# Check Docker is running
docker ps

# Restart Docker
sudo systemctl restart docker

# Remove and recreate
ddev delete -O
ddev start
```

### Database Connection Failed

**Symptom:** "Can't connect to MySQL server"

**Solutions:**
```bash
# Restart the site
ddev restart

# Check database container
ddev describe

# Import database manually
ddev import-db --file=backup.sql.gz
```

### Permission Denied

**Symptom:** Can't write files

**Solutions:**
```bash
# Fix permissions
ddev exec chmod -R 755 sites/default/files

# Run as root in container
ddev ssh -s web
```

### Port Already in Use

**Symptom:** Port 80/443 conflict

**Solutions:**
```bash
# Find what's using the port
sudo lsof -i :80

# Stop conflicting service
sudo systemctl stop apache2

# Use different ports in DDEV
ddev config --http-port=8080 --https-port=8443
```

### Composer Memory Error

**Symptom:** "Allowed memory size exhausted"

**Solutions:**
```bash
# Increase PHP memory in DDEV
ddev config --php-version=8.2 --web-environment="COMPOSER_MEMORY_LIMIT=-1"
ddev restart
```

## Getting Help

1. **Check logs:** `ddev logs`
2. **Describe site:** `ddev describe`
3. **NWP help:** `./install.sh --help`
4. **DDEV docs:** https://ddev.readthedocs.io

---

# 9. Glossary

| Term | Definition |
|------|------------|
| **DDEV** | Docker-based local development environment |
| **Drush** | Drupal command-line tool |
| **Recipe** | Pre-defined site configuration in cnwp.yml |
| **Webroot** | Directory containing index.php (`web` or `html`) |
| **Profile** | Drupal installation profile (standard, social, etc.) |
| **Staging** | Pre-production testing environment |
| **Sanitization** | Removing sensitive data from database |
| **StackScript** | Linode automated server setup script |
| **Composer** | PHP dependency manager |
| **Container** | Isolated Docker environment |

---

# Certification Path

## NWP Fundamentals (Bronze)
- Complete: Introduction, Prerequisites, Setup, Basic Operations
- Pass: 80% on Fundamentals assessment
- Skills: Install sites, basic backup/restore

## NWP Practitioner (Silver)
- Complete: All Core Operations + Deployment Pipeline
- Pass: 85% on Practitioner assessment
- Skills: Full site lifecycle, deployment workflow

## NWP Expert (Gold)
- Complete: All modules including Advanced Topics
- Pass: 90% on Expert certification exam
- Complete: Capstone project
- Skills: Infrastructure automation, custom development

---

*End of NWP Developer Training Booklet*

**Version:** 1.0
**Last Updated:** January 2026
**License:** CC0 1.0 Universal
