# NWP Developer Training Booklet

**Narrow Way Project - Complete Developer Guide**

Version 1.0 | January 2026

---

## Table of Contents

1. [Introduction](#1-introduction)
   - [Security: Two-Tier Secrets](#security-two-tier-secrets-architecture)
2. [Prerequisites](#2-prerequisites)
3. [Setup & Installation](#3-setup--installation)
4. [Core Operations](#4-core-operations)
   - 4.1 [Backup Operations](#41-backup-operations)
   - 4.2 [Restore Operations](#42-restore-operations)
   - 4.3 [Copy Operations](#43-copy-operations)
   - 4.4 [Delete Operations](#44-delete-operations)
   - 4.5 [Development Modes](#45-development-modes)
   - 4.6 [Status & Monitoring](#46-status--monitoring)
   - 4.7 [Feature Verification](#47-feature-verification)
   - 4.8 [Error Reporting](#48-error-reporting)
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
│   ├── nwp.yml              # Your site configurations (gitignored)
│   ├── example.nwp.yml      # Configuration template
│   ├── .secrets.yml          # Infrastructure secrets (gitignored)
│   └── .secrets.data.yml     # Production secrets (gitignored, AI-blocked)
│
├── Libraries
│   └── lib/              # Shared bash functions
│
├── Infrastructure
│   ├── linode/           # Linode deployment scripts
│   │   └── gitlab/       # GitLab infrastructure
│   └── templates/        # Site templates
│
└── Site Directories
    └── sites/            # Site installations directory
        ├── nwp1/         # Installed site
        ├── nwp2/         # Another site
        └── mysite-stg/   # Staging environment
```

## How NWP Works

1. **Configuration**: Define sites in `nwp.yml` using recipes
2. **Installation**: Run `./pl install <recipe>` to create a site
3. **Development**: Use DDEV commands to work on the site
4. **Management**: Use NWP scripts for backup, restore, copy
5. **Deployment**: Promote through dev → staging → production

## Security: Two-Tier Secrets Architecture

NWP uses a **two-tier secrets system** to protect sensitive data, especially when working with AI assistants like Claude.

### Why Two Tiers?

```
┌─────────────────────────────────────────────────────────────┐
│                    SECRETS ARCHITECTURE                      │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  .secrets.yml (Infrastructure)     .secrets.data.yml (Data) │
│  ┌─────────────────────────┐      ┌─────────────────────────┐│
│  │ • API tokens (Linode)   │      │ • Production passwords  ││
│  │ • API tokens (GitLab)   │      │ • Production SSH keys   ││
│  │ • API tokens (Cloudflare│      │ • Database credentials  ││
│  │ • Dev credentials       │      │ • SMTP credentials      ││
│  └─────────────────────────┘      └─────────────────────────┘│
│           ↓                                ↓                 │
│     AI CAN ACCESS                   AI CANNOT ACCESS         │
│  (helps with automation)         (protects user data)        │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

| Tier | File | Contains | AI Access |
|------|------|----------|-----------|
| **Infrastructure** | `.secrets.yml` | API tokens, dev credentials | ✓ Allowed |
| **Data** | `.secrets.data.yml` | Production passwords, SSH keys | ✗ Blocked |

### Quick Setup

```bash
# Infrastructure secrets (AI can help with these)
cp .secrets.example.yml .secrets.yml

# Data secrets (AI cannot access these)
cp .secrets.data.example.yml .secrets.data.yml
```

### What Goes Where?

**`.secrets.yml`** (Infrastructure - safe for AI):
- Linode API token
- Cloudflare API token
- GitLab API token
- Development/staging credentials

**`.secrets.data.yml`** (Data - blocked from AI):
- Production database passwords
- Production SSH keys
- Production SMTP credentials
- Encryption keys

> **Key Principle**: AI assistants can help provision servers and manage infrastructure without ever seeing production user data.

### Migrating Existing Secrets

If you have an existing installation with secrets in a single file:

```bash
# Check what needs migration
pl migrate-secrets --check

# Migrate NWP root secrets
pl migrate-secrets --nwp

# Migrate a specific site
pl migrate-secrets --site avc

# Migrate everything
pl migrate-secrets --all
```

See `docs/DATA_SECURITY_BEST_PRACTICES.md` for complete documentation.

### AI Assistant Safety Rules

> **Critical Rule**: **Treat AI platforms like social media — if you wouldn't post it publicly, don't share it with AI.**

#### NEVER Share with AI

When working with AI assistants (Claude, Copilot, ChatGPT), never share:

| Category | Examples | Risk |
|----------|----------|------|
| **Credentials** | API keys, passwords, tokens, SSH keys | Direct security breach |
| **Connection strings** | Database URLs with passwords | System compromise |
| **PII** | Real user emails, names, addresses | Privacy violations, GDPR |
| **Production data** | Real database dumps, user content | Data exposure |
| **Proprietary code** | Trade secrets, algorithms | IP theft |

**NWP-specific files to NEVER share:**
```bash
.secrets.yml          # Contains API tokens, passwords
.secrets.data.yml     # Production credentials
nwp.yml              # User-specific site configurations
keys/*                # SSH private keys
*.sql, *.sql.gz       # Database dumps (may contain PII)
settings.php          # Drupal credentials
.env.local            # Local secrets
```

#### SAFE to Share with AI

| Safe | Example |
|------|---------|
| **Anonymized code** | Code with fake credentials: `DB_PASS=example123` |
| **Public patterns** | "How do I implement X in Drupal?" |
| **Error messages** | Stack traces (check for embedded secrets first) |
| **Templates** | `example.nwp.yml`, `.secrets.example.yml` |
| **Documentation** | README files, public API docs |
| **Synthetic examples** | Made-up data that preserves structure |

#### Before Pasting Code to AI - 4-Point Checklist

Ask yourself:
1. **Does it contain real credentials?** → Replace with placeholders
2. **Does it contain real user data?** → Use synthetic examples
3. **Does it contain server IPs/domains?** → Replace with `example.com`
4. **Would I post this on Stack Overflow?** → If no, don't share

**Safe prompt example:**
```
# GOOD - Anonymized
"I have a Drupal settings.php with this structure (credentials replaced):
$databases['default']['default'] = [
  'host' => 'db.example.com',
  'username' => 'REDACTED',
  'password' => 'REDACTED',
];
Why might the database connection fail?"
```

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

### Run the Setup Command

```bash
./pl setup
```

The setup command will:
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

## 3.2 Understanding nwp.yml

The `nwp.yml` file is the heart of NWP. It defines all your sites and their configurations.

### Creating Your Configuration

```bash
cp example.nwp.yml nwp.yml
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
./pl install --list
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
./pl install d
```

This creates a new Drupal site in `./sites/d/` (or `./sites/d1/` if `d` exists).

### Install with Custom Name

```bash
./pl install d myproject
```

Creates the site in `./sites/myproject/`.

### Install with Test Content

```bash
./pl install d c
```

The `c` flag creates test users and content for development.

### Resume Failed Installation

If installation fails at step 5:

```bash
./pl install d s=5
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
cd sites/myproject
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
pl backup nwp5
```

This creates:
- Full backup in `./sitebackups/nwp5/`
- Includes database dump and all files
- Timestamped backup directory

### Database-Only Backup

```bash
pl backup -b nwp5
```

The `-b` flag creates a database-only backup (faster, smaller).

### Backup with Description

```bash
pl backup -b nwp5 "Before major update"
```

Add a description to identify the backup later.

### Auto-Confirm Backup

```bash
pl backup -y nwp5
```

The `-y` flag skips confirmation prompts.

### Combined Flags

```bash
pl backup -by nwp5 "Pre-release backup"
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

Note: Backups reference sites by name (e.g., `nwp5`) regardless of their location in the `sites/` directory.

### Practice Exercises

1. Create a full backup of site `test1`
2. Create a database-only backup with description "Before migration"
3. Create an auto-confirmed database backup

<details>
<summary>Solutions</summary>

```bash
# Exercise 1
pl backup test1

# Exercise 2
pl backup -b test1 "Before migration"

# Exercise 3
pl backup -by test1
```
</details>

---

## 4.2 Restore Operations

The `restore.sh` script restores sites from backups.

### Basic Restore

```bash
pl restore nwp5
```

Presents a list of available backups to choose from.

### Auto-Select Latest Backup

```bash
pl restore -f nwp5
```

The `-f` flag automatically selects the most recent backup.

### Database-Only Restore

```bash
pl restore -b nwp5
```

Restores only the database (keeps current files).

### Open Login Link After Restore

```bash
pl restore -o nwp5
```

Opens a one-time login link after restoration.

### Combined Restore

```bash
pl restore -bfyo nwp5
```

Database-only, latest backup, auto-confirm, open login.

### Cross-Site Restoration

Restore a backup to a different site:

```bash
pl restore -s nwp5_backup nwp5
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
pl restore -f test1

# Exercise 2
pl restore -bfy test1

# Exercise 3
pl restore -fyo test1
```
</details>

---

## 4.3 Copy Operations

The `copy.sh` script duplicates sites.

### Full Copy

```bash
pl copy nwp5 nwp6
```

Creates an exact copy including:
- All files
- Complete database
- DDEV configuration

### Files-Only Copy

```bash
pl copy -f nwp5 nwp6
```

Copies only files, preserving the destination database.

Use this when:
- You want to update code without losing data
- Testing new features on existing content
- Syncing code between environments

### Auto-Confirm Copy

```bash
pl copy -y nwp5 nwp6
```

### Copy to New Site

If the destination doesn't exist, it will be created:

```bash
pl copy nwp5 newsite
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
pl copy test1 test2

# Exercise 2
pl copy -f dev staging

# Exercise 3
pl copy -y test1 test2
```
</details>

---

## 4.4 Delete Operations

The `delete.sh` script safely removes sites.

### Basic Delete

```bash
pl delete nwp5
```

Prompts for confirmation before deleting.

### Backup Before Delete

```bash
pl delete -b nwp5
```

Creates a backup before deletion (recommended).

### Auto-Confirm Delete

```bash
pl delete -y nwp5
```

**Use with caution!** Skips confirmation.

### Combined Delete

```bash
pl delete -by nwp5
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
| `permanent` | Must change purpose in nwp.yml first |

### Practice Exercises

1. Delete site `test1` with backup
2. Delete site `temp` with auto-confirm

<details>
<summary>Solutions</summary>

```bash
# Exercise 1
pl delete -b test1

# Exercise 2
pl delete -y temp
```
</details>

---

## 4.5 Development Modes

The `make.sh` script toggles between development and production modes.

### Enable Development Mode

```bash
pl make -v nwp5
```

Development mode enables:
- Error display
- Debugging tools
- Cache disabled
- Twig debugging
- Verbose logging

### Enable Production Mode

```bash
pl make -p nwp5
```

Production mode enables:
- Error hiding
- Full caching
- Optimized assets
- Security hardening

### Auto-Confirm Mode Change

```bash
pl make -vy nwp5   # Dev mode, auto-confirm
pl make -py nwp5   # Prod mode, auto-confirm
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
pl make -v test1

# Exercise 2
pl make -p staging

# Exercise 3
pl make -vy test1
```
</details>

---

## 4.6 Status & Monitoring

The `status.sh` script shows the health and status of your sites.

### Check All Sites

```bash
pl status
```

Shows:
- Running/stopped status
- URLs
- Database connection
- Disk usage

### Check Specific Site

```bash
pl status nwp5
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
pl status

# Exercise 2
pl status test1

# Exercise 3 - Look for [✗] in output
pl status test1 | grep "✗"
```
</details>

---

## 4.7 Feature Verification

The `verify.sh` script tracks which NWP features have been manually verified by a human. When code changes, verification is automatically invalidated.

### Why Verification Tracking?

Automated tests catch many issues, but some things require human verification:
- User interface appearance and usability
- Complex workflows working end-to-end
- Performance under realistic conditions
- Integration with external services

### Check Verification Status

```bash
# Show all feature statuses
pl verify status

# Check for invalidated verifications
pl verify check
```

### When Code Changes

If a file changes, its associated features are marked for re-verification:

```
⚠️  INVALIDATED: backup - Files changed since last verification:
    → backup.sh (3 commits, 45 lines changed)

    Run 'pl verify details backup' for verification checklist
```

### View Feature Details

```bash
pl verify details backup
```

Shows:
- Files that changed and why
- Git commit history for those files
- Verification checklist specific to that feature

### Mark Features as Verified

After manually testing a feature:

```bash
pl verify verify backup
```

### Available Commands

| Command | Purpose |
|---------|---------|
| `pl verify status` | Show all feature statuses |
| `pl verify check` | Check for invalidated verifications |
| `pl verify details <feature>` | Show what changed and verification checklist |
| `pl verify verify <feature>` | Mark feature as verified |
| `pl verify list` | List all tracked features |

### Practice Exercises

1. Check current verification status
2. View details of any invalidated feature
3. Mark a feature as verified after testing

<details>
<summary>Solutions</summary>

```bash
# Exercise 1
pl verify status

# Exercise 2 - Pick any feature shown
pl verify details backup

# Exercise 3 - After testing backup
pl verify verify backup
```
</details>

---

## 4.8 Error Reporting

The `report.sh` script helps you report bugs to GitLab with full context when something goes wrong.

### Why Use Error Reporting?

When an NWP script fails, you can wrap it with `report.sh` to:
- **Capture the full output** of the command
- **Gather system information** (NWP version, OS, DDEV, Docker)
- **Sanitize sensitive data** (removes IPs, passwords, tokens)
- **Generate a pre-filled GitLab issue** with all context

### Basic Usage

Wrap any NWP command with `report.sh`:

```bash
pl report backup.sh mysite
```

If the command succeeds, nothing extra happens. If it fails:

```
═══════════════════════════════════════════════════════════════
  Running: backup.sh mysite
═══════════════════════════════════════════════════════════════

[✗] Site directory not found: mysite

───────────────────────────────────────────────────────────────
Command failed with exit code 1
───────────────────────────────────────────────────────────────

Report this error? [y/N/c] (c=continue):
```

### Response Options

| Response | Action |
|----------|--------|
| `y` (Yes) | Opens GitLab with pre-filled issue in your browser |
| `N` (No) | Exit without reporting (default) |
| `c` (Continue) | Don't exit - useful for batch operations |

### Clipboard Mode

Copy the issue URL to clipboard instead of opening browser:

```bash
pl report -c backup.sh mysite
```

### Direct Report Mode

Report an issue without running a command:

```bash
pl report --report "Description of the problem"
pl report --report -s backup.sh "Error message"
```

### What Gets Included in the Report

| Section | Content |
|---------|---------|
| **Title** | Error in script: exit code |
| **Command Output** | Full captured output (sanitized) |
| **Environment** | NWP version, OS, DDEV, Docker, Bash |
| **Steps to Reproduce** | Template to fill in |

### Automatic Sanitization

The report automatically removes:
- Home directory paths (replaced with `~`)
- IP addresses (replaced with `[IP_REDACTED]`)
- Passwords in URLs (replaced with `[PASS_REDACTED]`)
- API tokens and keys (replaced with `[REDACTED]`)

### When to Use

| Situation | Use Report? |
|-----------|-------------|
| Script fails unexpectedly | Yes - wrap with `report.sh` |
| User error (typo, missing site) | No - fix and retry |
| Need help with a feature | No - use documentation |
| Found a bug | Yes - use `--report` mode |

### Practice Exercises

1. Run a command with error reporting enabled
2. Trigger a failure and choose "continue"
3. Use direct report mode to describe a hypothetical issue

<details>
<summary>Solutions</summary>

```bash
# Exercise 1 - Wrap a command
pl report backup.sh test1

# Exercise 2 - Trigger failure and continue
pl report backup.sh nonexistent
# When prompted, press 'c' to continue

# Exercise 3 - Direct report
pl report --report -s backup.sh "Backup fails when site name has spaces"
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

| Environment | Naming Pattern | Example | Path |
|-------------|----------------|---------|------|
| Development | `sitename` | `nwp5` | `~/nwp/sites/nwp5/` |
| Staging | `sitename-stg` | `nwp5-stg` | `~/nwp/sites/nwp5_stg/` |
| Production | `sitename-prod` | `nwp5-prod` | Server or `~/nwp/sites/nwp5_prod/` |

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
pl dev2stg nwp5
```

This creates/updates `nwp5-stg`.

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
pl dev2stg -y nwp5
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
pl dev2stg test1

# Exercise 2
pl dev2stg -y test1

# Exercise 3
pl status test1_stg
```
</details>

---

## 5.3 Staging to Production

The `stg2prod.sh` script deploys from staging to production.

### Basic Deployment

```bash
pl stg2prod nwp5
```

Deploys `nwp5-stg` to `nwp5-prod`.

### Pre-Deployment Backup

```bash
pl stg2prod -b nwp5
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
pl restore -f nwp5_prod

# Or sync back from a known good state
pl prod2stg nwp5  # If staging is still good
```

### Practice Exercises

1. Deploy staging to production with backup
2. Deploy files only (preserve production database)

<details>
<summary>Solutions</summary>

```bash
# Exercise 1
pl stg2prod -b test1

# Exercise 2
pl stg2prod -f test1
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
pl prod2stg nwp5
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
pl prod2stg -s nwp5
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
pl prod2stg test1

# Exercise 2
pl prod2stg -s test1
```
</details>

---

## 5.5 Live Server Deployment

The `live.sh` script deploys sites to live servers (Linode).

### Prerequisites

1. Linode account configured
2. SSH keys set up (`pl setup-ssh`)
3. Domain configured in Cloudflare

### Basic Live Deployment

```bash
pl live nwp5
```

Creates a live site at `nwp5.<example-prod-domain>`.

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
pl stg2live nwp5
```

Promotes staging to live server.

### Live to Staging

```bash
pl live2stg nwp5
```

Syncs live content back to local staging.

---

## 5.6 Security Hardening

The `security.sh` script applies security hardening.

### Run Security Hardening

```bash
pl security nwp5
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
pl security test1

# Exercise 2
cd sites/test1 && ddev drush pm:list | grep security
```
</details>

---

# 6. Advanced Topics

## 6.1 GitLab Infrastructure

NWP includes automated GitLab server deployment.

> **The `linode/` and `git/` script directories are gone.** Everything below used
> to be a `./linode/*.sh` or `./setup_gitlab_site.sh` one-liner. Those files were <!-- doc-truth:retired -->
> removed when provisioning moved behind `pl`; the verbs are the replacement, and
> they carry the dry-run defaults, the fate manifests and the server resolver
> that the loose scripts never had. Run any of them with `--help` first.

### GitLab Features

- Self-hosted Git repositories
- CI/CD pipelines
- Issue tracking
- Container registry

### Connecting Sites to GitLab

```bash
pl gitlab-create        # create the project on the forge
pl gitlab-list          # what already exists
```

---

## 6.2 Server Provisioning

### Server inventory and health

```bash
pl server list          # every server NWP knows about
pl server show <name>   # one server's identity + bound sites
pl server status        # SSH reachability
```

### Provisioning

```bash
pl live --help          # live-tier server provisioning
pl produce --help       # production server provisioning
```

Linode API credentials live in `.secrets.yml` (`linode.api_token`) and are read
through `get_infra_secret` — never pasted into a script. See
[the secrets registry rules](../../CLAUDE.md).

---

## 6.3 Podcast Infrastructure

NWP supports Castopod podcast hosting.

### Podcast Setup

```bash
pl podcast
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

Add to `nwp.yml`:

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
| `./pl setup` | Install prerequisites |
| `./pl install --list` | List available recipes |
| `./pl install <recipe>` | Install a site |
| `./pl install <recipe> <name>` | Install with custom name |
| `./pl install <recipe> c` | Install with test content |
| `./pl install <recipe> s=N` | Resume from step N |

### Site Management

| Command | Description |
|---------|-------------|
| `pl backup <site>` | Full backup |
| `pl backup -b <site>` | Database-only backup |
| `pl restore <site>` | Restore from backup |
| `pl restore -f <site>` | Restore latest backup |
| `pl copy <src> <dst>` | Copy site |
| `pl copy -f <src> <dst>` | Copy files only |
| `pl delete <site>` | Delete site |
| `pl delete -b <site>` | Backup then delete |

### Development

| Command | Description |
|---------|-------------|
| `pl make -v <site>` | Enable dev mode |
| `pl make -p <site>` | Enable prod mode |
| `pl status` | Check all sites |
| `pl status <site>` | Check specific site |
| `pl verify status` | Check feature verification status |
| `pl verify check` | Check for invalidated verifications |
| `pl verify details <feature>` | View changes and checklist |
| `pl verify verify <feature>` | Mark feature as verified |

### Error Reporting

| Command | Description |
|---------|-------------|
| `pl report <script> [args]` | Run script with error capture |
| `pl report -c <script> [args]` | Copy error URL to clipboard |
| `pl report --report "msg"` | Direct report without running script |
| `pl report --help` | Show help |

### Deployment

| Command | Description |
|---------|-------------|
| `pl dev2stg <site>` | Dev → Staging (auto-enables prod mode) |
| `pl stg2prod <site>` | Staging → Production |
| `pl prod2stg <site>` | Production → Staging |
| `pl live <site>` | Deploy to live server |
| `pl security <site>` | Security hardening |

### Security & Secrets

| Command | Description |
|---------|-------------|
| `pl migrate-secrets --check` | Check what needs secrets migration |
| `pl migrate-secrets --nwp` | Migrate NWP root secrets |
| `pl migrate-secrets --all` | Migrate all secrets |

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

# Remove and recreate (from site directory)
cd sites/mysite
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
3. **NWP help:** `./pl install --help`
4. **DDEV docs:** https://ddev.readthedocs.io

---

# 9. Glossary

| Term | Definition |
|------|------------|
| **DDEV** | Docker-based local development environment |
| **Drush** | Drupal command-line tool |
| **Recipe** | Pre-defined site configuration in nwp.yml |
| **Webroot** | Directory containing index.php (`web` or `html`) |
| **Profile** | Drupal installation profile (standard, social, etc.) |
| **Staging** | Pre-production testing environment |
| **Sanitization** | Removing sensitive data from database |
| **StackScript** | Linode automated server setup script |
| **Composer** | PHP dependency manager |
| **Container** | Isolated Docker environment |
| **Infrastructure Secrets** | API tokens for provisioning (`.secrets.yml`) - safe for AI |
| **Data Secrets** | Production credentials (`.secrets.data.yml`) - blocked from AI |
| **Two-Tier Secrets** | Architecture separating infrastructure from data secrets |

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

---

# Appendix: Automated Training System

For information about building an automated training platform using Moodle and CodeRunner, see the archived planning documents:

- `docs/archive/NWP_TRAINING_SYSTEM.md` - Research on cognitive science and training platforms
- `docs/archive/NWP_TRAINING_IMPLEMENTATION_PLAN.md` - Phased implementation plan for Moodle LMS

These documents outline plans for spaced repetition, microlearning modules, and auto-graded exercises.

---

*End of NWP Developer Training Booklet*

**Version:** 1.1
**Last Updated:** January 2026
**License:** CC0 1.0 Universal
