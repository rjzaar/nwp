# install

**Status:** ACTIVE
**Last Updated:** 2026-01-14

Install new Drupal, Moodle, GitLab, or Podcast sites using recipe-based configurations.

## Synopsis

```bash
pl install [OPTIONS] <recipe> [target]
```

## Description

The `install` command creates new site installations based on recipes defined in `nwp.yml`. It automates the complete setup process including DDEV configuration, Composer project creation, Drupal/Moodle installation, and optional test content generation.

Supports multiple platform types:
- **Drupal** - Standard Drupal and OpenSocial distributions
- **Moodle** - Moodle LMS installations
- **GitLab** - GitLab CE server installations
- **Podcast** - Castopod podcast hosting platforms

The installation is resumable - if any step fails, you can restart from that step using the `s=N` option.

## Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `recipe` | Yes | Recipe name from `nwp.yml` (e.g., `d`, `os`, `avc`, `m`) |
| `target` | No | Custom directory/site name (defaults to recipe name) |

## Options

| Option | Description | Default |
|--------|-------------|---------|
| `-l, --list` | List all available recipes from `nwp.yml` | - |
| `-h, --help` | Show help message and usage information | - |
| `c, --create-content` | Create test content after installation | false |
| `s=N, --step=N` | Resume installation from step N | - |
| `-p=X, --purpose=X` | Set site purpose (t/i/p/m) | i (indefinite) |

### Purpose Values

| Value | Purpose | Description | Deletion Policy |
|-------|---------|-------------|-----------------|
| `t` | Testing | Temporary test sites | Can be freely deleted |
| `i` | Indefinite | Normal development sites (default) | Can be deleted manually |
| `p` | Permanent | Production or critical sites | Requires purpose change in `nwp.yml` before deletion |
| `m` | Migration | Migration stub for imports | Creates directory structure only, no installation |

## Installation Steps

The install script performs these steps in sequence:

1. **Initialize Project** - Create Composer project with base dependencies
2. **Environment Configuration** - Generate `.env` files from recipe
3. **DDEV Setup** - Configure DDEV with PHP, database, and services
4. **Memory Settings** - Configure PHP memory limits
5. **Start Services** - Launch DDEV containers
6. **Verify Drush** - Ensure Drush is available
7. **Private Files** - Configure private file system directory
8. **Install Profile** - Run Drupal/Moodle installation
9. **Additional Modules** - Install and enable extra modules (if specified)
10. **Test Content** - Generate sample content (if `-c` flag used)

## Examples

### Basic Installation

```bash
# Install using 'd' recipe (standard Drupal)
pl install d

# Install using 'os' recipe (OpenSocial)
pl install os

# Install using 'avc' recipe
pl install avc
```

### Custom Target Names

```bash
# Install 'nwp' recipe in 'client1' directory
pl install nwp client1

# Install 'd' recipe in 'mysite' directory
pl install d mysite
```

### With Options

```bash
# Install with test content creation
pl install nwp mysite c

# Install as permanent site (protected from deletion)
pl install os community -p=p

# Create migration stub (directory structure only)
pl install d oldsite -p=m

# Install as testing site (can be freely deleted)
pl install d test-feature -p=t
```

### Resume After Failure

```bash
# Resume from step 5 (Start DDEV services)
pl install nwp mysite s=5

# Resume from step 8 (Install Drupal profile)
pl install d client s=8
```

### List Available Recipes

```bash
# Show all recipes defined in nwp.yml
pl install --list
```

## Output

The installation provides detailed progress output:

```
═══════════════════════════════════════════════════════════════
  Installing: nwp → mysite
═══════════════════════════════════════════════════════════════

[1/9] Initialize project with Composer
✓ Composer project created

[2/9] Generate environment configuration
✓ Environment files generated

[3/9] Configure DDEV
✓ DDEV configured: PHP 8.2, MariaDB 10.11

[4/9] Configure memory settings
✓ Memory limits set: 512M

[5/9] Start DDEV services
✓ DDEV started: https://mysite.ddev.site

[6/9] Verify Drush is available
✓ Drush available

[7/9] Configure private file system
✓ Private files directory created

[8/9] Install Drupal profile
✓ Drupal installed: social profile

[9/9] Install additional modules
✓ Modules installed and enabled

═══════════════════════════════════════════════════════════════
  Installation Complete!
═══════════════════════════════════════════════════════════════

Site URL: https://mysite.ddev.site
Login:    https://mysite.ddev.site/user/login
Username: admin
Password: admin
```

## Test Content Creation

When using the `c` or `--create-content` flag, the installer creates:

- **5 test users** - `testuser1` through `testuser5` (password: `test123`)
- **5 test documents** - Basic page nodes with sample content
- **5 workflow assignments** - Sample workflow tasks (OpenSocial only)
- **Auto-login** - Automatically opens browser to workflow tab

This is useful for:
- Testing workflow features
- Demonstrating functionality
- Development and debugging
- Training and documentation

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Installation successful |
| 1 | General installation error |
| 2 | Missing required recipe argument |
| 3 | Recipe not found in `nwp.yml` |
| 4 | Recipe validation failed |
| 5 | Directory already exists |

## Prerequisites

- **DDEV** - Must be installed and running
- **Docker** - Required by DDEV
- **Composer** - PHP dependency manager
- **Git** - Version control system
- **nwp.yml** - Valid configuration file with recipe definitions

Run `pl setup` or `./setup.sh` to install missing prerequisites.

## Recipe Configuration

Recipes are defined in `nwp.yml`. Example:

```yaml
recipes:
  mysite:
    source: drupal/recommended-project:^11
    profile: standard
    webroot: web
    install_modules: drupal/admin_toolbar drupal/pathauto
    auto: y
```

Required fields vary by platform type:

### Drupal/OpenSocial Recipes

- `source` - Composer package (e.g., `drupal/recommended-project:^11`)
- `profile` - Installation profile (e.g., `standard`, `social`, `minimal`)
- `webroot` - Web root directory (e.g., `web`, `html`)

### Moodle Recipes

- `type: moodle` - Identifies as Moodle installation
- `source` - Git repository URL
- `branch` - Git branch (e.g., `MOODLE_404_STABLE`)
- `webroot` - Web root directory (usually `.`)

See `example.nwp.yml` for complete recipe examples.

## Directory Structure

Installations are created in the `sites/` directory:

```
nwp/
└── sites/
    ├── mysite/          # Target name used for directory
    │   ├── .ddev/       # DDEV configuration
    │   ├── .env         # Environment variables
    │   ├── composer.json
    │   ├── web/         # Webroot (varies by recipe)
    │   ├── vendor/
    │   └── private/     # Private files directory
    └── client1/         # Another installation
```

## Troubleshooting

### Recipe Not Found

**Symptom:**
```
ERROR: Recipe 'mysite' not found in nwp.yml
```

**Solution:**
- Check recipe name spelling: `pl install --list`
- Verify `nwp.yml` exists in NWP root
- Ensure recipe is properly defined in `nwp.yml`

### Directory Already Exists

**Symptom:**
```
ERROR: Directory 'sites/mysite' already exists
```

**Solution:**
- Use a different target name: `pl install mysite mysite2`
- Delete existing directory: `pl delete mysite`
- Resume if installation was incomplete: `pl install mysite mysite s=5`

### Composer Installation Failed

**Symptom:**
```
ERROR: Could not find package drupal/module_name
```

**Solution:**
- Verify package name is correct
- Check Composer repository configuration
- For custom packages, add repository to `composer.json`
- Try with different version constraint

### DDEV Won't Start

**Symptom:**
```
ERROR: Failed to start DDEV
```

**Solution:**
- Check Docker is running: `docker ps`
- Verify DDEV status: `ddev describe`
- Check port conflicts: `ddev stop --all && ddev start`
- Review DDEV logs: `ddev logs`

### Memory Limit Errors

**Symptom:**
```
PHP Fatal error: Allowed memory size exhausted
```

**Solution:**
- Increase memory limit in recipe: `memory_limit: 1024M`
- Edit `.ddev/php/php.ini` after installation
- Restart DDEV: `ddev restart`

### Module Installation Fails

**Symptom:**
```
ERROR: Could not enable module 'module_name'
```

**Solution:**
- Verify module is installed via Composer
- Check module compatibility with Drupal version
- Review module dependencies
- Check installation logs in `sites/mysite/`

## Notes

- **Auto-numbering**: If target name exists, install adds number suffix (e.g., `mysite` → `mysite1` → `mysite2`)
- **Resume capability**: Installation tracks progress - resume from any step if interrupted
- **Recipe validation**: Recipes are validated before installation begins
- **Backup recommendation**: No backup needed for new installations
- **Multiple installations**: Can install same recipe multiple times with different target names

## Related Commands

- [delete](./delete.md) - Delete installed sites
- [copy](./copy.md) - Clone existing sites
- [status](./status.md) - Check installation status
- [verify](./verify.md) - Verify installation integrity
- [backup](./backup.md) - Backup installed sites

## See Also

- [Installation Guide](../../guides/quickstart.md) - Step-by-step installation tutorial
- [Recipe Format](../../reference/recipe-format.md) - Complete recipe configuration reference
- [DDEV Documentation](https://ddev.readthedocs.io/) - DDEV official documentation
- [Configuration Hierarchy](../../../README.md#recipe-configuration-hierarchy) - Understanding recipe defaults and overrides
