# Narrow Way Project (NWP)

A streamlined installation system for Drupal and Moodle projects using DDEV and recipe-based configurations.

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Management Scripts](#management-scripts)
- [How It Works](#how-it-works)
- [Using the Install Script](#using-the-install-script)
- [Available Recipes](#available-recipes)
- [Configuration File](#configuration-file)
- [Creating Custom Recipes](#creating-custom-recipes)
- [Advanced Features](#advanced-features)
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
   - Verify everything is working correctly

3. **View available recipes**:
   ```bash
   ./install.sh --list
   ```

4. **Install a project using a recipe**:
   ```bash
   ./install.sh nwp
   ```

5. **Access your site**:
   - The script will display the URL when installation completes
   - Typically: `https://<recipe-name>.ddev.site`

## Management Scripts

NWP includes a comprehensive set of management scripts for working with your sites after installation:

### Available Scripts

| Script | Purpose | Key Features |
|--------|---------|--------------|
| `backup.sh` | Backup sites | Full and database-only backups with `-b` flag |
| `restore.sh` | Restore sites | Full and database-only restore, cross-site support |
| `copy.sh` | Copy sites | Full copy or files-only with `-f` flag |
| `make.sh` | Toggle dev/prod mode | Enable development (`-v`) or production (`-p`) mode |
| `dev2stg.sh` | Deploy to staging | Automated deployment from dev to staging |
| `delete.sh` | Delete sites | Graceful site deletion with optional backup (`-b`) |
| `testos.sh` | Test OpenSocial sites | Behat, PHPUnit, PHPStan testing with auto-setup |

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

# Deploy development to staging
./dev2stg.sh nwp4  # Creates nwp4_stg

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
├── nwp/              # First installation
├── nwp1/             # Second installation
├── nwp2/             # Third installation
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
./install.sh <recipe>
```

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

## Documentation

Comprehensive documentation is available in the `docs/` directory:

### Core Documentation

- **[SCRIPTS_IMPLEMENTATION.md](docs/SCRIPTS_IMPLEMENTATION.md)** - Detailed implementation documentation for all management scripts
  - Script features and usage
  - Testing results
  - Implementation details
  - File structure and line counts

- **[IMPROVEMENTS.md](docs/IMPROVEMENTS.md)** - Roadmap and improvement tracking
  - What has been achieved
  - Known issues and bugs
  - Future enhancements prioritized by phase
  - Metrics and statistics
  - Contributing guidelines

- **[PRODUCTION_TESTING.md](docs/PRODUCTION_TESTING.md)** - Production deployment testing guide
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
- See `docs/IMPROVEMENTS.md`

**For production deployment:**
- See `docs/PRODUCTION_TESTING.md`

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
├── install.sh            # Main installation script
├── setup.sh              # Prerequisites setup script
├── README.md             # This file
├── nwp.yml              # Site-specific config (if exists)
├── docs/                 # Documentation directory
│   ├── SCRIPTS_IMPLEMENTATION.md   # Script implementation docs
│   ├── IMPROVEMENTS.md             # Roadmap and improvements
│   ├── PRODUCTION_TESTING.md       # Production testing guide
│   └── BACKUP_IMPLEMENTATION.md    # Backup system details
├── backup.sh             # Backup script (full and database-only)
├── restore.sh            # Restore script (full and database-only)
├── copy.sh               # Site copy script (full and files-only)
├── make.sh               # Dev/prod mode toggle script
├── dev2stg.sh            # Development to staging deployment
├── sitebackups/          # Backup storage (auto-created, gitignored)
└── <recipe-dirs>/        # Installed project directories
    ├── .ddev/            # DDEV configuration
    ├── composer.json     # PHP dependencies
    ├── web/ or html/     # Webroot (varies by recipe)
    ├── vendor/           # Composer packages
    └── private/          # Private files directory
```

### Environment-Specific Directories (gitignored)

These directories are created by management scripts and automatically ignored by git:

```
nwp/
├── <sitename>_stg/       # Staging environment sites
├── <sitename>_prod/      # Production environment sites
├── <sitename>_test/      # Test environment sites
└── <sitename>_backup/    # Backup copies
```

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
- `.secrets.example.yml` - Template for credentials

### Customizing Your Environment

1. **Local overrides**: Copy `.env.local.example` to `.env.local`
   ```bash
   cp .env.local.example .env.local
   # Edit .env.local with your settings
   ```

2. **Secrets**: Copy `.secrets.example.yml` to `.secrets.yml`
   ```bash
   cp .secrets.example.yml .secrets.yml
   # Add your API keys, passwords, etc.
   ```

3. **Never commit**: `.env.local` and `.secrets.yml` are automatically gitignored

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

