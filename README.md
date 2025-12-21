# Narrow Way Project (NWP)

A streamlined installation system for Drupal and Moodle projects using DDEV and recipe-based configurations.

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [How It Works](#how-it-works)
- [Using the Install Script](#using-the-install-script)
- [Available Recipes](#available-recipes)
- [Configuration File](#configuration-file)
- [Creating Custom Recipes](#creating-custom-recipes)
- [Advanced Features](#advanced-features)
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

For custom modules hosted on GitHub:

1. **Ensure your module has a `composer.json`** with the correct package name
2. **Add the repository to the install script** (or it will be added automatically for `rjzaar/*` packages)
3. **Reference it in `install_modules`**:
   ```yaml
   install_modules: vendor/module_name:dev-branch_name
   ```

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
├── nwp.yml              # Legacy config (if exists)
└── <recipe-dirs>/        # Installed project directories
    ├── .ddev/            # DDEV configuration
    ├── composer.json     # PHP dependencies
    ├── web/ or html/     # Webroot (varies by recipe)
    ├── vendor/           # Composer packages
    └── private/          # Private files directory
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
