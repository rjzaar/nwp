# Narrow Way Project (NWP)

A streamlined installation system for Drupal and Moodle projects using DDEV and recipe-based configurations.

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Security Architecture](#security-architecture)
- [Quick Start](#quick-start)
- [Security Architecture Details](#security-architecture-details)
- [Management Scripts](#management-scripts)
- [Feature Verification Tracking](#feature-verification-tracking)
- [How It Works](#how-it-works)
- [Using the Install Script](#using-the-install-script)
- [Available Recipes](#available-recipes)
- [Configuration File](#configuration-file)
- [Creating Custom Recipes](#creating-custom-recipes)
- [Advanced Features](#advanced-features)
- [GitLab Deployment](#gitlab-deployment)
- [Site Purpose and Migration](#site-purpose-and-migration)
- [Documentation](#documentation)
- [Troubleshooting](#troubleshooting)

## Overview

The Narrow Way Project (NWP) simplifies the process of setting up local development environments for Drupal and Moodle projects. Instead of manually configuring each project, NWP uses a recipe-based system where you define your project requirements in a simple YAML configuration file (`cnwp.yml`), and the installation script handles the rest.

### Key Features

- **Recipe-based configuration**: Define multiple project templates in a single config file
- **Automatic DDEV setup**: Handles all DDEV configuration automatically
- **Composer integration**: Manages PHP dependencies seamlessly
- **Multiple CMS support**: Works with Drupal (including OpenSocial) and Moodle
- **Test content creation**: Optional test data generation for development
- **Resumable installations**: Start from any step if something fails
- **Validation**: Automatic recipe validation before installation

## Prerequisites

NWP requires the following software:

- **Docker**: Container platform for DDEV
- **DDEV**: Local development environment
- **Composer**: PHP dependency manager
- **Git**: Version control system

**Don't worry if you don't have these installed yet!** The setup script will check for each prerequisite and automatically install any that are missing.

## Security Architecture

NWP uses a **two-tier secrets system** to protect sensitive data while allowing safe collaboration with AI assistants like Claude Code. The full details are in **Complete Guide**: See [`docs/DATA_SECURITY_BEST_PRACTICES.md`](docs/DATA_SECURITY_BEST_PRACTICES.md)

### AI Assistant Safety Rules

> **Critical Rule**: **Treat AI platforms like social media — if you wouldn't post it publicly, don't share it with AI.**

### Why Two Tiers?

Modern development often involves AI assistants that can help with infrastructure automation, deployment, and debugging. However, these tools should never have access to production user data or credentials. NWP's two-tier architecture enables AI to help with infrastructure while protecting your users.

More information about security below.

## Quick Start

1. **Clone the repository**:
   ```bash
   git clone git@github.com:rjzaar/nwp.git
   cd nwp
   ```

2. **Run the setup script** (installs missing prerequisites):
   ```bash
   ./setup.sh
   ```

   The setup script will:
   - Check which prerequisites are already installed
   - Install only the missing prerequisites
   - Configure your system for DDEV
   - Install the `pl` CLI command for running NWP scripts

3. **View available recipes**:
   ```bash
   pl --list
   ```

4. **Install a project using a recipe**:
   ```bash
   pl install nwp
   ```

5. **Access your site**:
   - The script will display the URL when installation completes
   - Typically: `https://<recipe-name>.ddev.site`

6. **(Optional) Set up SSH keys for production deployment**:
   ```bash
   pl setup-ssh
   ```

## Using the `pl` CLI

After setup, the `pl` command is the primary way to run NWP scripts:

```bash
pl install d mysite    # Install a Drupal site
pl backup mysite       # Backup a site
pl restore mysite      # Restore from backup
pl copy mysite newsite # Copy a site
pl status              # Check all sites
pl --help              # Show all commands
```

The `pl` command works from any directory and provides tab completion for commands.

## Security Architecture Details

NWP uses a two-tier security system.

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

When you run `./setup.sh`, it automatically configures the two-tier security system. For manual setup:

```bash
# Infrastructure secrets (AI can help with these)
cp .secrets.example.yml .secrets.yml

# Data secrets (AI cannot access these)
cp .secrets.data.example.yml .secrets.data.yml
```

### What Goes Where?

**`.secrets.yml`** (Infrastructure - safe for AI):
- Linode API token (server provisioning)
- Cloudflare API token (DNS management)
- GitLab API token (repository management)
- Development/staging credentials
- CI/CD tokens

**`.secrets.data.yml`** (Data - blocked from AI):
- Production database passwords
- Production SSH keys
- Production SMTP credentials
- Encryption keys
- Admin account passwords

### Key Principle

> AI assistants can help provision servers, configure DNS, set up CI/CD pipelines, and debug infrastructure without ever seeing production user data.

### Using Secrets in Scripts

NWP provides separate functions for accessing each tier:

```bash
source lib/common.sh

# Infrastructure secrets (AI can see these operations)
token=$(get_infra_secret "linode.api_token" "")

# Data secrets (blocked from AI)
db_pass=$(get_data_secret "production_database.password" "")
```

### Safe Operations

For operations that need data secrets but should return sanitized output, use the safe-ops library:

```bash
source lib/safe-ops.sh

# Get server status (no credentials exposed)
safe_server_status prod1

# Get database info (no actual data)
safe_db_status avc

# Check for security updates
safe_security_check avc
```

These functions use data secrets internally but only return sanitized information that's safe to share.

### Protected Files

NWP automatically blocks AI access to sensitive files:

| File Pattern | Why Blocked |
|--------------|-------------|
| `.secrets.data.yml` | Production credentials |
| `keys/prod_*` | Production SSH keys |
| `*.sql`, `*.sql.gz` | Database dumps with user data |
| `settings.php` | Drupal production credentials |
| `cnwp.yml` | May contain site-specific credentials |

**Note:** `cnwp.yml` is protected because it may contain user-specific site configurations. Use `example.cnwp.yml` for templates and documentation.

### AI Safety Rules

> **Critical Rule**: **Treat AI platforms like social media — if you wouldn't post it publicly, don't share it with AI.**

#### NEVER Share with AI

| Category | Examples | Risk |
|----------|----------|------|
| **Credentials** | API keys, passwords, tokens, SSH keys | Direct security breach |
| **Connection strings** | Database URLs with passwords | System compromise |
| **PII** | Real user emails, names, addresses | Privacy violations, GDPR |
| **Production data** | Real database dumps, user content | Data exposure |
| **Proprietary code** | Trade secrets, algorithms | IP theft |

**NWP-specific files to NEVER share:**
- `.secrets.yml` or `.secrets.data.yml` contents
- `cnwp.yml` (contains user-specific site data)
- `keys/*` (SSH private keys)
- `*.sql`, `*.sql.gz` (database dumps)
- `settings.php` (Drupal credentials)
- `.env.local` (local secrets)

#### SAFE to Share with AI

| Safe | Example |
|------|---------|
| **Anonymized code** | Code with fake credentials: `DB_PASS=example123` |
| **Public patterns** | "How do I implement X in Drupal?" |
| **Error messages** | Stack traces (check for embedded secrets first) |
| **Architecture questions** | "What's the best way to structure Y?" |
| **Templates** | `example.cnwp.yml`, `.secrets.example.yml` |
| **Documentation** | README files, public API docs |

#### Before Pasting Code to AI

Ask yourself:
1. **Does it contain real credentials?** → Replace with placeholders
2. **Does it contain real user data?** → Use synthetic examples
3. **Does it contain server IPs/domains?** → Replace with `example.com`
4. **Would I post this on Stack Overflow?** → If no, don't share

### Verification

Check your security setup:

```bash
# Verify Claude deny rules are in place
jq '.permissions.deny' ~/.claude/settings.json

# Check for data secrets in wrong files
./migrate-secrets.sh --check

# Test that secrets are properly separated
grep -l "password" .secrets*.yml  # Should only be in .secrets.data.yml
```

### Learn More

- **Complete Guide**: See [`docs/DATA_SECURITY_BEST_PRACTICES.md`](docs/DATA_SECURITY_BEST_PRACTICES.md)
- **Training Material**: See [`docs/NWP_TRAINING_BOOKLET.md`](docs/NWP_TRAINING_BOOKLET.md)
- **Migration Guide**: See [`docs/SETUP.md`](docs/SETUP.md) for two-tier setup

## Management Scripts

NWP includes a comprehensive set of management scripts for working with your sites after installation:

### Available Scripts

| Script | Purpose | Key Features |
|--------|---------|--------------|
| `backup.sh` | Backup sites | Full and database-only backups with `-b` flag |
| `restore.sh` | Restore sites | Full and database-only restore, cross-site support |
| `copy.sh` | Copy sites | Full copy or files-only with `-f` flag |
| `make.sh` | Toggle dev/prod mode | Enable development (`-v`) or production (`-p`) mode |
| `dev2stg.sh` | Deploy to staging | Interactive TUI, multi-source DB, integrated testing, auto-staging |
| `stg2prod.sh` | Deploy to production | Push staging to production server |
| `prod2stg.sh` | Sync from production | Pull production data to local staging |
| `delete.sh` | Delete sites | Graceful site deletion with optional backup (`-b`) |
| `status.sh` | Site status | Interactive site management, `production` dashboard |
| `testos.sh` | Test OpenSocial sites | Behat, PHPUnit, PHPStan testing with auto-setup |
| `setup.sh` | Setup prerequisites | Install DDEV, configure Claude security, manage symlinks |
| `security.sh` | Security audits | Run security audits, check for updates |
| `coder-setup.sh` | Multi-coder setup | DNS delegation for team members |
| `migrate-secrets.sh` | Two-tier secrets | Migrate to infrastructure/data secrets split |
| `verify.sh` | Feature verification | Track which features need manual re-verification |
| `report.sh` | Error reporting | Wrapper to report errors to GitLab with captured output |

### Notification Scripts

| Script | Purpose |
|--------|---------|
| `scripts/notify.sh` | Main notification router (routes to Slack, email, webhook) |
| `scripts/notify-slack.sh` | Slack webhook notifications |
| `scripts/notify-email.sh` | Email notifications via sendmail/SMTP |
| `scripts/notify-webhook.sh` | Generic webhook notifications |

### CI/CD Scripts

| Script | Purpose |
|--------|---------|
| `scripts/ci/fetch-db.sh` | Fetch database for CI with caching |
| `scripts/ci/build.sh` | CI build operations (composer, npm, drush) |
| `scripts/ci/test.sh` | Comprehensive test runner |
| `scripts/ci/check-coverage.sh` | Validate coverage thresholds |
| `scripts/ci/create-preview.sh` | Create PR preview environment |
| `scripts/ci/cleanup-preview.sh` | Clean up preview environment |
| `scripts/ci/visual-regression.sh` | Visual regression testing |
| `scripts/security-update.sh` | Automated security updates |

### Script Organization

Scripts live in `scripts/commands/` and are accessed via the `pl` CLI (default):

```bash
pl install nwp       # Recommended - works from anywhere
pl backup mysite
pl status
```

**Alternative access methods:**

```bash
# Direct path (no CLI needed)
./scripts/commands/install.sh nwp

# Traditional symlinks (optional - for backward compatibility)
./setup.sh --symlinks    # Creates ./install.sh etc. in root
./install.sh nwp         # Then works like before
```

The interactive `./setup.sh` also includes a "Script Symlinks" component for backward compatibility.

### Quick Examples

```bash
# Backup a site (full backup)
./backup.sh nwp4

# Database-only backup
./backup.sh -b nwp4 "Before schema change"

# Restore a site
./restore.sh nwp4

# Copy a site
./copy.sh nwp4 nwp5

# Files-only copy (preserves destination database)
./copy.sh -f nwp4 nwp5

# Enable development mode
./make.sh -v nwp4

# Enable production mode
./make.sh -p nwp4

# Deploy development to staging (interactive TUI)
./dev2stg.sh nwp4  # Interactive mode - select DB source and tests

# Deploy with automated mode (CI/CD friendly)
./dev2stg.sh -y nwp4  # Auto-selects best DB source, skips tests

# Deploy with specific database source
./dev2stg.sh --db-source=production nwp4  # Fresh from production
./dev2stg.sh --dev-db nwp4                # Clone from development

# Deploy with specific test preset
./dev2stg.sh -t essential nwp4  # Run phpunit, phpstan, phpcs
./dev2stg.sh -t skip nwp4       # Skip all tests

# Run preflight checks only
./dev2stg.sh --preflight nwp4

# Delete a site (with confirmation)
./delete.sh nwp5

# Delete with backup and auto-confirm
./delete.sh -by old_site

# Test OpenSocial site
./testos.sh -b -f groups nwp4  # Run Behat tests for groups feature

# List available test features
./testos.sh --list-features nwp4

# Run all tests
./testos.sh -a nwp4  # Behat + PHPUnit + PHPStan

# Run security audit
./security.sh audit nwp4

# Check for security updates
./security.sh check nwp4

# Migrate to two-tier secrets
./migrate-secrets.sh --check  # Preview what needs migration
./migrate-secrets.sh --nwp    # Migrate NWP root secrets
./migrate-secrets.sh --all    # Migrate all secrets

# Check verification status
./verify.sh status             # Show all feature statuses
./verify.sh check              # Check for invalidated verifications
./verify.sh details backup     # Show details about a specific feature

# Error reporting - wrap any command to capture and report errors
./report.sh backup.sh mysite   # Run backup, offer to report on failure
./report.sh install.sh d test  # Run install with error capture
./report.sh -c backup.sh site  # Copy error report URL to clipboard

# Production status dashboard
./status.sh production         # Show all production sites with status

# Send notifications
./scripts/notify.sh --event deploy_success --site mysite --url https://mysite.com

# Run security updates
./scripts/security-update.sh mysite --check   # Check for updates
./scripts/security-update.sh mysite --apply   # Apply updates with testing
```

### Combined Flags

All scripts support combined short flags for efficient usage:

```bash
# Database-only backup with auto-confirm
./backup.sh -by nwp4

# Database-only restore with auto-select latest and open login link
./restore.sh -bfyo nwp4

# Files-only copy with auto-confirm
./copy.sh -fy nwp4 nwp5

# Dev mode with auto-confirm
./make.sh -vy nwp4

# Run Behat tests with auto-confirm and verbose
./testos.sh -bvy nwp4
```

### Environment Naming Convention

NWP uses postfix naming for different environments:

- **Development**: `sitename` (e.g., `nwp4`)
- **Staging**: `sitename_stg` (e.g., `nwp4_stg`)
- **Production**: `sitename_prod` (e.g., `nwp4_prod`)

For detailed documentation on each script, see the [Documentation](#documentation) section.

## Feature Verification Tracking

NWP includes a verification tracking system to ensure all features have been manually tested by a human. When code is modified, verifications are automatically invalidated.

### Quick Start

```bash
# View verification status
./verify.sh

# See summary with progress bar
./verify.sh summary

# List all feature IDs
./verify.sh list

# Mark a feature as verified
./verify.sh verify setup

# Mark verified by a specific person
./verify.sh verify install rob
```

### Commands

| Command | Description |
|---------|-------------|
| `./verify.sh` | Show full verification status with checkboxes |
| `./verify.sh summary` | Show progress statistics and progress bar |
| `./verify.sh list` | List all feature IDs with current status |
| `./verify.sh details <id>` | Show what changed and verification checklist |
| `./verify.sh verify <id>` | Mark a feature as verified by you |
| `./verify.sh verify <id> <name>` | Mark verified by a specific person |
| `./verify.sh unverify <id>` | Mark a feature as unverified |
| `./verify.sh check` | Detect modified files and invalidate verifications |
| `./verify.sh reset` | Reset all verifications |
| `./verify.sh help` | Show help message |

### How It Works

1. **Verification**: When you verify a feature, the script stores a SHA256 hash of all associated source files
2. **Change Detection**: Running `./verify.sh check` compares current file hashes against stored hashes
3. **Auto-Invalidation**: If any tracked file has changed, the verification is automatically cleared
4. **Status Display**: Shows `[✓]` verified, `[ ]` unverified, `[!]` modified since verification

### Tracked Features

The system tracks 42 features across 10 categories:

- **Core Scripts** (12): setup, install, status, backup, restore, etc.
- **Deployment** (8): dev2stg, stg2prod, live, etc.
- **Infrastructure** (5): podcast, schedule, security, etc.
- **CLI & Testing** (2): pl_cli, test_nwp
- **Libraries** (12): tui, checkbox, yaml_write, git, cloudflare, etc.
- **Moodle** (1): moodle installation support
- **GitLab** (4): setup, hardening, repo management
- **Linode** (3): setup, deploy, test server
- **Configuration** (2): example configs
- **Tests** (1): integration tests

### Example Workflow

```bash
# Before release, check what needs verification
./verify.sh summary

# Run through and verify each feature
./verify.sh verify setup
./verify.sh verify install
./verify.sh verify backup

# After code changes, check for invalidations
./verify.sh check

# See what changed and what to verify for a specific feature
./verify.sh details dev2stg

# See what still needs verification
./verify.sh status
```

### When Verification is Invalidated

When code changes invalidate a verification, use the `details` command to see:
- Which files were modified
- Recent git commits for those files
- A specific checklist of what to test

```bash
# Check for invalidations (shows which files changed)
./verify.sh check

# Get detailed checklist for a modified feature
./verify.sh details dev2stg

# After testing, re-verify
./verify.sh verify dev2stg
```

The verification state is stored in `.verification.yml` and tracked in git, so the team can share verification progress.

## How It Works

### The Installation Process

NWP automates the following steps:

1. **Configuration Reading**: Reads recipe configuration from `cnwp.yml`
2. **Validation**: Ensures all required fields are present
3. **Directory Creation**: Creates a numbered directory for the installation
4. **DDEV Setup**: Configures and starts the DDEV container
5. **Composer Project**: Creates the base project using Composer
6. **Drush Installation**: Installs Drush for Drupal management
7. **Module Installation**: Installs additional modules if specified
8. **Site Installation**: Runs the Drupal/Moodle installer
9. **Post-Install Tasks**: Handles caching, permissions, etc.
10. **Test Content** (optional): Creates sample content for testing

### Directory Structure

When you run `./install.sh nwp`, it creates:

```
nwp/
└── sites/
    ├── nwp/          # First installation
    ├── nwp1/         # Second installation
    ├── nwp2/         # Third installation
    └── ...
```

Each directory is a complete, isolated DDEV project with its own:
- Database
- Web server
- Configuration
- Codebase

## Using the Install Script

### Basic Usage

```bash
./install.sh <recipe> [target]
```

- `<recipe>`: The recipe name from cnwp.yml
- `[target]`: Optional custom directory/site name (defaults to recipe name with auto-numbering)

### Command-Line Options

| Option | Description |
|--------|-------------|
| `-h, --help` | Show help message and usage information |
| `-l, --list` | List all available recipes with details |
| `c, --create-content` | Create test content after installation |
| `s=N, --step=N` | Resume installation from step N |

### Examples

**Install the nwp recipe:**
```bash
./install.sh nwp
```

**Install with custom directory name:**
```bash
./install.sh nwp mysite    # Uses nwp recipe but creates 'mysite' directory
```

**Install with test content creation:**
```bash
./install.sh nwp c
```

**Resume from step 5:**
```bash
./install.sh nwp s=5
```

**View all available recipes:**
```bash
./install.sh --list
```

**Show help:**
```bash
./install.sh --help
```

## Available Recipes

NWP comes with several pre-configured recipes:

### `os` - OpenSocial

A full OpenSocial installation (social networking platform built on Drupal).

- **Source**: `goalgorilla/social_template:dev-master`
- **Profile**: social
- **Webroot**: html
- **Best for**: Community and social networking sites

### `d` - Standard Drupal

A standard Drupal 10 installation with the standard profile.

- **Source**: `drupal/recommended-project:^10.2`
- **Profile**: standard
- **Webroot**: web
- **Best for**: Basic Drupal projects

### `nwp` - NWP with Workflow

OpenSocial with custom workflow management modules.

- **Source**: `goalgorilla/social_template:dev-master`
- **Profile**: social
- **Webroot**: html
- **Modules**: workflow_assignment, ultimate_cron
- **Best for**: Projects requiring workflow management

### `dm` - Divine Mercy

Standard Drupal 10 with the Divine Mercy custom module.

- **Source**: `drupal/recommended-project:^10.2`
- **Profile**: standard
- **Webroot**: web
- **Modules**: divine_mercy
- **Best for**: Divine Mercy specific projects

### `m` - Moodle

Moodle LMS installation.

- **Source**: https://github.com/moodle/moodle.git
- **Branch**: MOODLE_404_STABLE
- **Type**: moodle
- **Best for**: E-learning platforms

## Configuration File

The `cnwp.yml` file defines all your recipes. Here's the structure:

```yaml
# Root-level settings (apply to all recipes)
database: mariadb
php: 8.2

recipes:
  recipe_name:
    # Required for Drupal recipes
    source: composer/package:version
    profile: profile_name
    webroot: web_directory

    # Optional fields
    install_modules: module1 module2
    auto: y

  # For Moodle recipes
  moodle_recipe:
    type: moodle
    source: git_repository_url
    branch: branch_name
    webroot: .
    sitename: "Site Name"
    auto: y
```

### Required Fields

**For Drupal recipes:**
- `source`: Composer package (e.g., `drupal/recommended-project:^10.2`)
- `profile`: Installation profile (e.g., `standard`, `social`)
- `webroot`: Web root directory (e.g., `web`, `html`)

**For Moodle recipes:**
- `type`: Must be `moodle`
- `source`: Git repository URL
- `branch`: Git branch to use
- `webroot`: Web root directory (usually `.`)

### Optional Fields

- `install_modules`: Space-separated list of additional modules/packages
- `auto`: Set to `y` to skip confirmation prompts
- `sitename`: Custom site name (defaults to recipe name)

## Creating Custom Recipes

You can easily create your own recipes by adding them to `cnwp.yml`:

### Example: Custom Drupal Recipe

```yaml
recipes:
  my_project:
    source: drupal/recommended-project:^10.2
    profile: standard
    webroot: web
    install_modules: drupal/admin_toolbar drupal/pathauto
    auto: y
```

### Example: Custom OpenSocial Recipe

```yaml
recipes:
  my_social:
    source: goalgorilla/social_template:dev-master
    profile: social
    webroot: html
    install_modules: rjzaar/my_custom_module:dev-main
    auto: y
```

### Using Custom Modules

NWP supports two methods for installing custom modules:

#### Method 1: Git Repository (Recommended for development)

For custom modules hosted on GitHub or other git repositories, you can clone them directly:

```yaml
recipes:
  my_project:
    source: drupal/recommended-project:^10.2
    profile: standard
    webroot: web
    install_modules: git@github.com:username/my_module.git
    auto: y
```

The install script will:
- Create the `web/modules/custom` directory
- Clone the module into `web/modules/custom/my_module`
- Support both SSH (`git@github.com:...`) and HTTPS (`https://github.com/...`) URLs

#### Method 2: Composer Package

For modules available as Composer packages:

```yaml
recipes:
  my_project:
    source: drupal/recommended-project:^10.2
    profile: standard
    webroot: web
    install_modules: vendor/module_name:dev-branch_name
    auto: y
```

Requirements:
1. Module must have a `composer.json` with the correct package name
2. For `rjzaar/*` packages, the repository is configured automatically
3. For other packages, add the repository configuration

#### Mixing Both Methods

You can use both git and composer modules in the same recipe:

```yaml
recipes:
  my_project:
    source: drupal/recommended-project:^10.2
    profile: standard
    webroot: web
    install_modules: git@github.com:user/custom_module.git drupal/admin_toolbar
    auto: y
```

The install script will automatically:
- Clone git modules to `modules/custom/`
- Install composer modules via `composer require`

## Advanced Features

### Test Content Creation

The `c` flag creates test content for workflow development:

```bash
./install.sh nwp c
```

This creates:
- 5 test users (testuser1-5, password: test123)
- 5 test documents (basic page nodes)
- 5 workflow assignments
- Automatically logs you in and navigates to the workflow tab

### Resumable Installations

If an installation fails, you can resume from a specific step:

```bash
./install.sh nwp s=5
```

Installation steps:
1. DDEV configuration
2. Composer project creation
3. Drush installation
4. Additional modules (if specified)
5. Site installation
6. Cache clear and rebuild
7. Login URL generation
8. Test content creation (if requested)

### Recipe Validation

The install script automatically validates recipes before installation:

```bash
./install.sh my_recipe
```

If validation fails, you'll see helpful error messages:
```
ERROR: Recipe 'my_recipe': Missing required field 'profile'
ERROR: Recipe 'my_recipe': Missing required field 'webroot'

Please check your cnwp.yml and ensure all required fields are present:
  For Drupal recipes: source, profile, webroot
  For Moodle recipes: source, branch, webroot
```

## GitLab Deployment

NWP includes automated GitLab server deployment on Linode infrastructure.

### Quick Setup

```bash
# Set up a permanent GitLab site at git.<your-domain>
cd git
./setup_gitlab_site.sh
```

This will:
- Read your domain from `cnwp.yml` settings
- Create a 4GB Linode server
- Install GitLab CE with SSL
- Configure SSH keys and access
- Register the site as permanent in `cnwp.yml`
- Store credentials in `.secrets.yml`

### Manual GitLab Setup

For more control over the installation:

```bash
# 1. Set up local environment
./git/gitlab_setup.sh

# 2. Upload StackScript to Linode
./git/gitlab_upload_stackscript.sh

# 3. Create GitLab server
./git/gitlab_create_server.sh --domain git.example.com --email admin@example.com
```

### Accessing GitLab

After setup, SSH config is automatically configured:

```bash
# Connect to GitLab server
ssh git-server

# Get root password
ssh git-server 'sudo cat /root/gitlab_credentials.txt'
```

See `git/README.md` for complete GitLab documentation.

## Site Purpose and Migration

NWP supports site lifecycle management through purpose tracking and migration workflows.

### Site Purpose

When installing a site, you can specify its purpose:

```bash
./install.sh nwp mysite -p=t    # Testing - can be freely deleted
./install.sh nwp mysite -p=i    # Indefinite - default, manual deletion allowed
./install.sh nwp mysite -p=p    # Permanent - requires config change to delete
./install.sh nwp mysite -p=m    # Migration - creates stub for importing sites
```

Purpose values:
- **testing**: Safe to delete, used for temporary test sites
- **indefinite**: Default for normal sites, can be deleted manually
- **permanent**: Protected sites, must change purpose in `cnwp.yml` before deletion
- **migration**: Creates directory structure for migrating external sites

### Migration Workflow

For importing existing sites (Drupal 7, WordPress, static HTML, etc.):

```bash
# Create migration stub
./install.sh d oldsite -p=m

# Analyze the source
./migration.sh analyze oldsite

# Prepare target Drupal site
./migration.sh prepare oldsite

# Run migration
./migration.sh run oldsite

# Verify results
./migration.sh verify oldsite
```

The migration workflow supports:
- Drupal 7/8/9 sites
- WordPress sites
- Static HTML sites
- Joomla sites

See `docs/MIGRATION_SITES_TRACKING.md` for site migration and `docs/MIGRATION_GUIDE_ENV.md` for environment variable migration.

## Documentation

Comprehensive documentation is available in the `docs/` directory:

### Core Documentation

- **[SCRIPTS_IMPLEMENTATION.md](docs/SCRIPTS_IMPLEMENTATION.md)** - Detailed implementation documentation for all management scripts
  - Script features and usage
  - Testing results
  - Implementation details
  - File structure and line counts

- **[ROADMAP.md](docs/ROADMAP.md)** - Development roadmap and improvement tracking
  - What has been achieved
  - Known issues and bugs
  - Future enhancements prioritized by phase
  - Metrics and statistics
  - Contributing guidelines

- **[KNOWN_ISSUES.md](KNOWN_ISSUES.md)** - Current known issues and test failures
  - Active issues with investigation status
  - Test failure details and workarounds
  - Resolved issues history
  - Current test suite success rate (98%)

- **[PRODUCTION_DEPLOYMENT.md](docs/PRODUCTION_DEPLOYMENT.md)** - Production deployment and testing guide
  - Safe testing strategies (local mock → remote test → dry-run → production)
  - Implementation examples for safety features
  - Testing checklists and workflows
  - Configuration examples
  - Troubleshooting guide

- **[BACKUP_IMPLEMENTATION.md](docs/BACKUP_IMPLEMENTATION.md)** - Backup system implementation details
  - Backup strategy and architecture
  - File formats and naming conventions
  - Restoration procedures

- **[TESTING.md](docs/TESTING.md)** - OpenSocial testing infrastructure documentation
  - Testing script (testos.sh) usage and options
  - Behat, PHPUnit, PHPStan, CodeSniffer integration
  - Selenium Chrome browser automation
  - 30 test features with 134 scenarios
  - Automatic dependency installation and configuration

- **[DATA_SECURITY_BEST_PRACTICES.md](docs/DATA_SECURITY_BEST_PRACTICES.md)** - Security and AI usage guide
  - Two-tier secrets architecture (infrastructure vs data secrets)
  - Production backup strategies and schedules
  - Database sanitization for GDPR compliance
  - What to share (and NOT share) with AI assistants like Claude
  - Security hardening checklists
  - Secrets management and rotation

- **[NWP_TRAINING_BOOKLET.md](docs/NWP_TRAINING_BOOKLET.md)** - Comprehensive training documentation
  - Complete 8-phase training journey for new users
  - NWP philosophy and architecture overview
  - Step-by-step tutorials for all major operations
  - Troubleshooting guides and best practices
  - Two-tier secrets architecture introduction

- **[DEPLOYMENT_WORKFLOW_ANALYSIS.md](docs/DEPLOYMENT_WORKFLOW_ANALYSIS.md)** - Deployment workflow research
  - Comparison with Vortex, Pleasy, and industry best practices
  - Analysis of production mode on staging environments
  - Recommended deployment patterns for Drupal sites

- **[QUICKSTART.md](docs/QUICKSTART.md)** - Quick start guide for getting started fast

- **[SETUP.md](docs/SETUP.md)** - Detailed setup and configuration guide
  - Prerequisites and installation
  - SSH key setup
  - Configuration file setup
  - Two-tier secrets setup

- **[CICD.md](docs/CICD.md)** - CI/CD pipeline documentation
  - GitLab CI/CD integration
  - Automated testing and deployment

- **[DEVELOPER_LIFECYCLE_GUIDE.md](docs/DEVELOPER_LIFECYCLE_GUIDE.md)** - Complete developer workflow
  - From project initialization to production
  - All 9 phases of development lifecycle

- **[NWP_COMPLETE_ROADMAP.md](docs/NWP_COMPLETE_ROADMAP.md)** - Consolidated roadmap
  - All phases of NWP development
  - Implementation details and status

- **[LINODE_DEPLOYMENT.md](docs/LINODE_DEPLOYMENT.md)** - Linode server deployment guide
  - Server provisioning
  - StackScripts usage
  - Production deployment checklist

- **[DISASTER_RECOVERY.md](docs/DISASTER_RECOVERY.md)** - Disaster recovery procedures
  - Recovery Time Objectives (RTO)
  - Rollback and restore procedures
  - Server rebuild procedures

- **[ENVIRONMENTS.md](docs/ENVIRONMENTS.md)** - Environment management
  - Environment hierarchy (local → dev → staging → production)
  - Configuration splits
  - Preview environments for PRs

- **[ADVANCED_DEPLOYMENT.md](docs/ADVANCED_DEPLOYMENT.md)** - Advanced deployment strategies
  - Blue-green deployment
  - Canary releases
  - Performance baseline tracking
  - Visual regression testing

- **[HUMAN_TESTING.md](docs/HUMAN_TESTING.md)** - Manual testing guide
  - Tests that require human verification
  - Comprehensive checklists for each feature

### Quick Reference

**For script usage:**
```bash
# All scripts have built-in help
./backup.sh --help
./restore.sh --help
./copy.sh --help
./make.sh --help
./dev2stg.sh --help
```

**For detailed implementation:**
- See `docs/SCRIPTS_IMPLEMENTATION.md`

**For roadmap and planned features:**
- See `docs/ROADMAP.md`

**For SSH setup and production deployment:**
- **SSH Key Setup**: `./setup-ssh.sh` - See `docs/SSH_SETUP.md`
- **Production Deployment**: See `docs/PRODUCTION_DEPLOYMENT.md`

## Error Reporting

NWP includes an error reporting system that helps you submit bug reports to GitLab with full context.

### Using the Error Reporter

Wrap any NWP command with `report.sh` to capture errors and offer to report them:

```bash
# Run a command with error reporting enabled
./report.sh backup.sh mysite

# If the command fails, you'll see:
# ═══════════════════════════════════════════════════════════════
#   Running: backup.sh mysite
# ═══════════════════════════════════════════════════════════════
#
# [✗] Site directory not found: mysite
#
# ───────────────────────────────────────────────────────────────
# Command failed with exit code 1
# ───────────────────────────────────────────────────────────────
#
# Report this error? [y/N/c] (c=continue):
```

### Options

| Response | Action |
|----------|--------|
| `y` | Opens GitLab with pre-filled issue (system info, command output) |
| `N` | Exit without reporting (default) |
| `c` | Continue without exiting (useful for batch operations) |

### Examples

```bash
# Report errors from backup
./report.sh backup.sh mysite

# Report errors from install
./report.sh install.sh d newsite

# Copy issue URL to clipboard instead of opening browser
./report.sh -c backup.sh mysite

# Direct report (without running a command)
./report.sh --report "Description of the issue"
./report.sh --report -s backup.sh "Error message"
```

### What Gets Included

The error report automatically includes:
- **Command output**: Full captured output (sanitized)
- **Exit code**: The command's exit status
- **System info**: NWP version, OS, DDEV version, Docker version
- **Sanitization**: Removes IPs, passwords, and API tokens

## Troubleshooting

### Common Issues

**Problem: "Recipe not found"**
```bash
ERROR: Recipe 'myrecipe' not found in cnwp.yml
```
**Solution**: Check the recipe name spelling or run `./install.sh --list` to see available recipes.

---

**Problem: "Missing required field"**
```bash
ERROR: Recipe 'myrecipe': Missing required field 'profile'
```
**Solution**: Add the missing field to your recipe in `cnwp.yml`.

---

**Problem: DDEV won't start**
```bash
Failed to start project
```
**Solution**:
- Ensure Docker is running: `docker ps`
- Check DDEV status: `ddev describe`
- Restart Docker and try again

---

**Problem: Composer installation fails**
```bash
Could not find package...
```
**Solution**:
- Check that the package name is correct
- For custom modules, ensure the repository is accessible
- Check that the version constraint is valid

---

**Problem: Installation hangs**

**Solution**:
- Press Ctrl+C to cancel
- Check the last step that completed
- Resume from the next step: `./install.sh recipe s=N`

### Getting Help

1. **View available recipes and their configuration:**
   ```bash
   ./install.sh --list
   ```

2. **Check DDEV logs:**
   ```bash
   ddev logs
   ```

3. **Verify DDEV status:**
   ```bash
   ddev describe
   ```

4. **Test configuration:**
   ```bash
   ./install.sh recipe s=99
   ```
   (Uses an invalid step number to test validation without installing)

## Directory Reference

```
nwp/
├── cnwp.yml              # Configuration file with all recipes
├── *.sh                  # Command symlinks (→ scripts/commands/)
├── .verification.yml     # Verification status tracking
├── .gitlab-ci.yml        # GitLab CI pipeline configuration
├── renovate.json         # Automated dependency updates
├── phpstan.neon          # PHPStan configuration
├── README.md             # This file
│
├── .logs/                # Test logs (gitignored)
├── .backups/             # Config backups with retention (gitignored)
│
├── sites/                # Site installations directory (gitignored)
│
├── docs/                 # Documentation directory
│   ├── QUICKSTART.md                   # Quick start guide
│   ├── SETUP.md                        # Setup and configuration
│   ├── DEVELOPER_LIFECYCLE_GUIDE.md    # Complete developer workflow
│   ├── NWP_COMPLETE_ROADMAP.md         # Consolidated roadmap
│   ├── NWP_TRAINING_BOOKLET.md         # Comprehensive training guide
│   ├── DATA_SECURITY_BEST_PRACTICES.md # Security and AI usage
│   ├── DISASTER_RECOVERY.md            # Disaster recovery procedures
│   ├── ENVIRONMENTS.md                 # Environment management
│   ├── ADVANCED_DEPLOYMENT.md          # Advanced deployment strategies
│   ├── HUMAN_TESTING.md                # Manual testing guide
│   ├── CICD.md                         # CI/CD documentation
│   ├── LINODE_DEPLOYMENT.md            # Linode deployment guide
│   ├── TESTING.md                      # Testing infrastructure
│   └── CODER_ONBOARDING.md             # Multi-coder onboarding
│
├── scripts/              # Scripts directory
│   ├── commands/                       # Core command scripts (actual files)
│   │   ├── install.sh                  # Main installation
│   │   ├── backup.sh                   # Backup script
│   │   ├── restore.sh                  # Restore script
│   │   ├── status.sh                   # Site status dashboard
│   │   ├── verify.sh                   # Verification tracking
│   │   ├── dev2stg.sh                  # Dev to staging
│   │   ├── stg2prod.sh                 # Staging to production
│   │   └── ...                         # All other command scripts
│   ├── ci/                             # CI/CD helper scripts
│   │   ├── fetch-db.sh                 # Fetch database for CI
│   │   ├── build.sh                    # CI build operations
│   │   ├── test.sh                     # Comprehensive test runner
│   │   ├── check-coverage.sh           # Coverage threshold check
│   │   ├── create-preview.sh           # Create PR preview
│   │   ├── cleanup-preview.sh          # Cleanup preview
│   │   └── visual-regression.sh        # Visual regression testing
│   ├── notify.sh                       # Main notification router
│   ├── notify-slack.sh                 # Slack notifications
│   ├── notify-email.sh                 # Email notifications
│   ├── notify-webhook.sh               # Webhook notifications
│   └── security-update.sh              # Security update automation
│
├── linode/               # Linode deployment
│   └── server_scripts/                 # Production server scripts
│       ├── nwp-bootstrap.sh            # Server initialization
│       ├── nwp-healthcheck.sh          # Health monitoring
│       ├── nwp-monitor.sh              # Continuous monitoring
│       ├── nwp-scheduled-backup.sh     # Automated backups
│       ├── nwp-verify-backup.sh        # Backup verification
│       ├── nwp-bluegreen-deploy.sh     # Blue-green deployment
│       ├── nwp-canary.sh               # Canary releases
│       ├── nwp-perf-baseline.sh        # Performance baselines
│       └── nwp-cron.conf               # Cron configuration
│
├── .github/              # GitHub configuration
│   ├── workflows/
│   │   └── build-test-deploy.yml       # GitHub Actions workflow
│   └── PULL_REQUEST_TEMPLATE.md        # PR template
│
├── .gitlab/              # GitLab configuration
│   └── merge_request_templates/
│       └── default.md                  # MR template
│
├── .hooks/               # Git hooks
│   └── pre-commit                      # Pre-commit quality checks
│
├── lib/                  # Shared libraries
│   ├── common.sh                       # Common functions
│   ├── ui.sh                           # UI formatting
│   ├── state.sh                        # State detection
│   ├── database-router.sh              # Database routing
│   ├── testing.sh                      # Testing framework
│   ├── preflight.sh                    # Preflight checks
│   └── cloudflare.sh                   # Cloudflare API
│
├── sitebackups/          # Backup storage (auto-created, gitignored)
└── sites/                # Installed project directories
    └── <sitename>/       # Individual site installations
        ├── .ddev/        # DDEV configuration
        ├── composer.json # PHP dependencies
        ├── web/ or html/ # Webroot (varies by recipe)
        ├── vendor/       # Composer packages
        └── private/      # Private files directory
```

### Site Directories (gitignored)

Site directories are created in the `sites/` subdirectory to keep the root directory clean and organized. DDEV projects work at any filesystem level.

```
nwp/
└── sites/
    ├── nwp1/             # Installed sites (base from recipe name)
    ├── nwp2/             # Multiple installs get numbered
    ├── avc/              # Custom-named sites
    ├── avc_stg/          # Staging environment version
    ├── avc_prod/         # Production environment version
    └── avc_backup/       # Backup copies
```

All site directory contents are automatically gitignored (via `sites/*/` in .gitignore).

## Best Practices

1. **Use version constraints** in your recipes for stability
2. **Test recipes** with the `s=99` flag before full installation
3. **Keep backups** of your `cnwp.yml` configuration
4. **Use meaningful recipe names** that describe the project
5. **Document custom recipes** with comments in `cnwp.yml`
6. **Validate before installing** - the script does this automatically
7. **Use `--list`** to review available recipes regularly

## Contributing

To add new recipes or improve the installation script:

1. Edit `cnwp.yml` to add new recipes
2. Test with `./install.sh recipe_name`
3. Commit your changes
4. Share your recipes with the community

## License

This project is dedicated to the public domain under the CC0 1.0 Universal (CC0 1.0) Public Domain Dedication.

You can copy, modify, distribute and perform the work, even for commercial purposes, all without asking permission. See the [LICENSE](LICENSE) file for details.

## Support

For issues, questions, or contributions, please refer to the project repository or contact the maintainer.

## Environment Variables (New in v0.2)

NWP now includes comprehensive environment variable management:

### Quick Start

Environment configuration is automatic when creating new sites:

```bash
./install.sh d mysite
```

This generates:
- `.env` - Main environment configuration (auto-generated, don't edit)
- `.env.local.example` - Template for local overrides
- `.secrets.example.yml` - Template for infrastructure credentials
- `.secrets.data.example.yml` - Template for production credentials

### Customizing Your Environment

1. **Local overrides**: Copy `.env.local.example` to `.env.local`
   ```bash
   cp .env.local.example .env.local
   # Edit .env.local with your settings
   ```

2. **Infrastructure secrets**: Copy `.secrets.example.yml` to `.secrets.yml`
   ```bash
   cp .secrets.example.yml .secrets.yml
   # Add API tokens (Linode, Cloudflare, GitLab)
   # These are safe for AI assistants to help with
   ```

3. **Data secrets** (production): Copy `.secrets.data.example.yml` to `.secrets.data.yml`
   ```bash
   cp .secrets.data.example.yml .secrets.data.yml
   # Add production DB passwords, SSH keys, SMTP credentials
   # These are BLOCKED from AI assistants
   ```

4. **Never commit**: `.secrets.yml` and `.secrets.data.yml` are automatically gitignored

### Two-Tier Secrets Architecture

NWP uses a two-tier secrets system for AI assistant safety:

| File | Contains | AI Access |
|------|----------|-----------|
| `.secrets.yml` | API tokens, dev credentials | Allowed |
| `.secrets.data.yml` | Production passwords, SSH keys | Blocked |

See [DATA_SECURITY_BEST_PRACTICES.md](docs/DATA_SECURITY_BEST_PRACTICES.md) for details.

### Manual Generation

For existing sites or custom setups:

```bash
# Generate .env from recipe
./vortex/scripts/generate-env.sh [recipe] [sitename] [path]

# Generate DDEV config from .env
./vortex/scripts/generate-ddev.sh [path]
```

### Documentation

- **Templates**: See `vortex/templates/` for available templates
- **Full Guide**: See `vortex/README.md`
- **Migration**: See `docs/MIGRATION_GUIDE_ENV.md`
- **Comparison**: See `docs/environment-variables-comparison.md`


### Configuration Hierarchy

NWP uses a flexible configuration hierarchy for environment variables and services:

```
1. Recipe-specific settings (highest priority)
   ↓
2. Global settings defaults
   ↓
3. Profile-based defaults
   ↓
4. Hardcoded defaults (lowest priority)
```

**Example:**
```yaml
# cnwp.yml
settings:
  services:
    redis:
      enabled: false      # Global default
    solr:
      enabled: false

recipes:
  mysite:
    profile: social
    services:
      redis:
        enabled: true     # Override for this recipe only
      # solr uses global default (false)
```

This allows you to:
- Set common defaults once in `settings`
- Override per recipe only when needed
- Keep recipe definitions minimal and focused

See `example.cnwp.yml` for the complete structure and `enhanced_example` recipe for override examples.

