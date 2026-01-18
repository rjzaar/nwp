# NWP Feature Reference

A complete reference of all NWP features organized by category.

**Version:** 1.1 | **Last Updated:** January 2026

---

## Table of Contents

1. [Site Management](#1-site-management)
2. [Backup & Restore](#2-backup--restore)
3. [Deployment Pipeline](#3-deployment-pipeline)
4. [Development Tools](#4-development-tools)
5. [Frontend Theming](#5-frontend-theming)
6. [Infrastructure Automation](#6-infrastructure-automation)
7. [Testing & Verification](#7-testing--verification)
8. [Configuration System](#8-configuration-system)
9. [Security Features](#9-security-features)

---

# 1. Site Management

## install.sh - Create Sites from Recipes

Creates new Drupal/Moodle sites using recipe-based configuration.

| Flag | Description |
|------|-------------|
| `--list`, `-l` | List available recipes |
| `--help`, `-h` | Show help |
| `--create-content`, `c` | Create test content after installation |
| `--step=N`, `s=N` | Resume from step N |
| `-p=t\|i\|p\|m` | Set site purpose (testing/indefinite/permanent/migration) |

**Examples:**
```bash
./install.sh d mysite              # Install Drupal with recipe 'd'
./install.sh nwp c                 # Install with test content
./install.sh nwp mysite s=5        # Resume from step 5
```

## copy.sh - Duplicate Sites

Creates copies of existing sites.

| Flag | Description |
|------|-------------|
| `-f` | Files only (preserve destination database) |
| `-y` | Auto-confirm prompts |
| `-o` | Open login link after |

**Examples:**
```bash
./copy.sh nwp5 nwp6               # Full copy
./copy.sh -f nwp5 nwp6            # Files only
./copy.sh -fyo nwp5 nwp6          # Combined flags
```

## delete.sh - Remove Sites

Safely removes sites with optional backup.

| Flag | Description |
|------|-------------|
| `-b` | Create backup before deletion |
| `-k` | Keep existing backups |
| `-y` | Auto-confirm deletion |

**Examples:**
```bash
./delete.sh testsite              # Delete with confirmation
./delete.sh -by testsite          # Backup first, auto-confirm
```

## modify.sh - Interactive Option Editor

Interactive TUI for modifying site options.

**Features:**
- Arrow key navigation
- Option descriptions and dependencies
- Environment tabs (dev/stg/live/prod)
- Real-time status display

```bash
./modify.sh sitename
```

## status.sh - Check Site Health

Displays status and health checks for sites.

```bash
./status.sh                       # All sites
./status.sh sitename              # Specific site
```

---

# 2. Backup & Restore

## backup.sh - Create Backups

Creates full or database-only backups.

| Flag | Description |
|------|-------------|
| `-b` | Database only |
| `-g` | Git commit after backup |
| `-y` | Auto-confirm |

**Examples:**
```bash
./backup.sh mysite                # Full backup
./backup.sh -b mysite             # Database only
./backup.sh -bg mysite            # DB + git commit
```

**Backup Location:** `sitebackups/<sitename>/`

## restore.sh - Restore from Backups

Restores sites from backup files.

| Flag | Description |
|------|-------------|
| `-b` | Database only |
| `-f` | Use latest backup (first) |
| `-y` | Auto-confirm |
| `-o` | Open login link after |

**Examples:**
```bash
./restore.sh mysite               # Interactive backup selection
./restore.sh -bf mysite           # Restore latest DB backup
./restore.sh -bfyo mysite         # Latest DB + auto-confirm + open
```

---

# 3. Deployment Pipeline

## Environment Flow

```
┌─────────┐      ┌─────────┐      ┌─────────┐      ┌─────────┐
│   DEV   │ ───► │   STG   │ ───► │  LIVE   │ ───► │  PROD   │
│ (local) │ ◄─── │ (local) │ ◄─── │ (cloud) │ ◄─── │ (cloud) │
└─────────┘      └─────────┘      └─────────┘      └─────────┘
```

## dev2stg.sh - Development to Staging

Deploys development site to local staging environment.

| Flag | Description |
|------|-------------|
| `-y` | Auto-confirm |
| `-s N` | Start from step N |
| `-d` | Debug mode |

**Key Feature:** Automatically enables production mode on staging.

```bash
./dev2stg.sh mysite               # Creates mysite-stg
```

## stg2prod.sh - Staging to Production

Deploys staging to production server.

| Flag | Description |
|------|-------------|
| `-b` | Backup production first |
| `-f` | Files only (keep production DB) |
| `-y` | Auto-confirm |
| `--dry-run` | Preview without changes |

```bash
./stg2prod.sh mysite              # Deploy to production
./stg2prod.sh -b mysite           # With backup
```

## prod2stg.sh - Sync from Production

Pulls production data back to staging.

| Flag | Description |
|------|-------------|
| `-s` | Sanitize database |

```bash
./prod2stg.sh mysite              # Sync production data
./prod2stg.sh -s mysite           # With sanitization
```

## live.sh - Deploy to Live Server

Provisions and deploys to a live server (Linode).

```bash
./live.sh mysite                  # Deploy to mysite.nwpcode.org
```

---

# 4. Development Tools

## make.sh - Toggle Dev/Prod Mode

Switches between development and production configurations.

| Flag | Description |
|------|-------------|
| `-v` | Development mode (verbose) |
| `-p` | Production mode |
| `-y` | Auto-confirm |
| `-d` | Debug mode |

**Development Mode:**
- Error display enabled
- Debugging tools active
- Caching disabled
- Twig debugging enabled

**Production Mode:**
- Errors hidden
- Full caching enabled
- Assets optimized
- Security hardened

```bash
./make.sh -v mysite               # Enable dev mode
./make.sh -p mysite               # Enable prod mode
```

---

# 5. Frontend Theming

## theme.sh - Frontend Build Tool Management

Unified frontend tooling supporting Gulp, Grunt, Webpack, and Vite.

| Subcommand | Description |
|------------|-------------|
| `setup <sitename>` | Install Node.js dependencies |
| `watch <sitename>` | Start dev mode with live reload |
| `build <sitename>` | Production build (minified) |
| `dev <sitename>` | Development build (one-time) |
| `lint <sitename>` | Run ESLint/Stylelint |
| `info <sitename>` | Show build tool info |
| `list <sitename>` | List all themes |

| Option | Description |
|--------|-------------|
| `-t, --theme <path>` | Specify theme directory |
| `-d, --debug` | Enable debug output |

**Examples:**
```bash
pl theme setup mysite              # Install dependencies
pl theme watch mysite              # Start gulp/webpack watch
pl theme build mysite              # Production build
pl theme info mysite               # Show detected build tool
pl theme watch mysite -t /path     # Use specific theme path
```

## Auto-Detection

The build tool is automatically detected from project files:

| File | Detected Tool |
|------|--------------|
| `gulpfile.js` | Gulp (OpenSocial, legacy Drupal) |
| `Gruntfile.js` | Grunt (Vortex, Drupal standard) |
| `webpack.config.js` | Webpack (Varbase, modern Drupal) |
| `vite.config.js` | Vite (greenfield projects) |

Package manager is detected from lock files:
- `yarn.lock` → yarn
- `package-lock.json` → npm
- `pnpm-lock.yaml` → pnpm

## Per-Site Configuration

Override auto-detection in `nwp.yml`:

```yaml
sites:
  mysite:
    recipe: os
    frontend:
      build_tool: gulp
      package_manager: yarn
      node_version: "20"
```

---

# 6. Infrastructure Automation

## setup.sh - Install Prerequisites

Interactive setup wizard for NWP prerequisites.

| Flag | Description |
|------|-------------|
| `--auto` | Auto-install all components |
| `--list` | List available components |

**Components:**
- Docker
- DDEV
- mkcert
- NWP CLI (`pl` command)
- Claude Code security
- SSH keys
- GitLab server

```bash
./setup.sh                        # Interactive
./setup.sh --auto                 # Auto-install core
```

## GitLab Server (linode/gitlab/)

Automated GitLab CE deployment on Linode.

```bash
cd linode/gitlab
./setup_gitlab_site.sh            # Full GitLab setup
./gitlab_create_server.sh         # Create server only
```

## Linode Provisioning (linode/)

Linode server management scripts.

```bash
./linode/linode_setup.sh          # Configure Linode API
./linode/linode_create_test_server.sh  # Create test server
```

---

# 7. Testing & Verification

## testos.sh - OpenSocial Testing

Comprehensive testing for OpenSocial sites.

| Flag | Description |
|------|-------------|
| `-a` | All tests (Behat + PHPUnit + PHPStan) |
| `-b` | Behat tests |
| `-u` | PHPUnit tests |
| `-p` | PHPStan analysis |
| `-c` | CodeSniffer |
| `-f <feature>` | Specific Behat feature |

```bash
./testos.sh -a mysite             # All tests
./testos.sh -b mysite             # Behat only
./testos.sh -b -f groups mysite   # Specific feature
```

## pl verify --run - NWP Verification System

Integration verification for NWP itself.

```bash
pl verify --run                   # Full verification suite
pl verify --run --verbose         # With debug output
```

**Verification Coverage:** 77 checks, 98% pass rate

## verify.sh - Feature Verification

Tracks which features have been manually verified.

| Command | Description |
|---------|-------------|
| `status` | Show all feature statuses |
| `check` | Find invalidated verifications |
| `list` | List all 42 trackable features |
| `details <id>` | Show what changed and test checklist |
| `verify <id>` | Mark feature as verified |

```bash
./verify.sh                       # Status overview
./verify.sh check                 # Find invalidated
./verify.sh verify backup         # Mark verified
```

---

# 8. Configuration System

## nwp.yml - Main Configuration

Central configuration file for all NWP settings.

```yaml
settings:
  url: yourdomain.org
  php: 8.2
  database: mariadb

recipes:
  myrecipe:
    source: drupal/recommended-project:^10.2
    profile: standard
    webroot: web
    install_modules: drupal/admin_toolbar

sites:
  mysite:
    directory: /path/to/site
    recipe: myrecipe
    environment: development
```

## Configuration Hierarchy

```
1. Recipe-specific settings (highest priority)
   ↓
2. Global settings defaults
   ↓
3. Profile-based defaults
   ↓
4. Hardcoded defaults (lowest priority)
```

## Available Recipes

| Recipe | Description |
|--------|-------------|
| `d` | Standard Drupal 10 |
| `nwp` | NWP with workflow modules |
| `os` | OpenSocial |
| `dm` | Divine Mercy custom module |
| `m` | Moodle LMS |
| `podcast` | Castopod podcast hosting |
| `git` | GitLab server |

---

# 9. Security Features

## Two-Tier Secrets Architecture

| Tier | File | AI Access | Contains |
|------|------|-----------|----------|
| **Infrastructure** | `.secrets.yml` | Allowed | API tokens, dev credentials |
| **Data** | `.secrets.data.yml` | Blocked | Production passwords, SSH keys |

## security.sh - Security Hardening

Applies security hardening to sites.

```bash
./security.sh mysite
```

**Actions:**
- Install security modules
- Fix file permissions
- Configure trusted hosts
- Set secure headers
- Enable HTTPS

## migrate-secrets.sh - Secrets Migration

Migrates to two-tier secrets architecture.

```bash
./migrate-secrets.sh --check      # Preview migration
./migrate-secrets.sh --nwp        # Migrate NWP secrets
./migrate-secrets.sh --all        # Migrate all
```

---

# CLI Reference (pl command)

If CLI is installed, use the `pl` command from anywhere:

| Command | Equivalent |
|---------|------------|
| `pl install d mysite` | `./install.sh d mysite` |
| `pl backup mysite` | `./backup.sh mysite` |
| `pl restore mysite` | `./restore.sh mysite` |
| `pl copy src dst` | `./copy.sh src dst` |
| `pl delete mysite` | `./delete.sh mysite` |
| `pl dev2stg mysite` | `./dev2stg.sh mysite` |
| `pl test mysite` | `./testos.sh -a mysite` |
| `pl theme watch mysite` | `./theme.sh watch mysite` |
| `pl status` | `./status.sh` |
| `pl --list` | `./install.sh --list` |

## Multiple NWP Installations

If you have multiple NWP installations, each registers a unique command:

| Installation | Command |
|--------------|---------|
| First (default) | `pl` |
| Second | `pl1` |
| Third | `pl2` |
| Custom | `nwp`, `dev`, etc. |

Set during `./setup.sh` - editable with 'e' key on "NWP CLI Command" row.

---

# Combined Flags Reference

All scripts support combined short flags:

| Combined | Meaning |
|----------|---------|
| `-by` | Database-only + auto-confirm |
| `-bfy` | Database + first/latest + auto-confirm |
| `-bfyo` | Database + first + auto-confirm + open |
| `-vy` | Development mode + auto-confirm |
| `-py` | Production mode + auto-confirm |
| `-fyo` | Files + auto-confirm + open |

---

*For detailed implementation documentation, see [Scripts Implementation](scripts-implementation.md)*
