# modify

**Last Updated:** 2026-01-14

Interactive modification of installed Drupal site options and configuration.

## Synopsis

```bash
pl modify [site_name] [options]
```

## Description

The `modify` command provides an interactive TUI for managing options on existing Drupal sites. It detects currently installed modules and services (dev modules, XDebug, Redis, Solr, etc.), allows you to enable or disable them, and updates the site configuration in `nwp.yml`.

The command can detect "orphaned" sites (directories with `.ddev` but not in `nwp.yml`) and provides detailed status information about each site including Drupal version, DDEV status, and installation progress.

Unlike `install.sh` which creates new sites, `modify` works with existing sites to change their configuration after installation.

## Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `site_name` | No | Site slug from nwp.yml (prompts if omitted) |

## Options

| Option | Description |
|--------|-------------|
| `-i, --info` | Show site info only (no TUI) |
| `-l, --list` | List all sites (including orphaned) |
| `-h, --help` | Show help message |

## Available Options

### Development Tools

| Option | Description |
|--------|-------------|
| `dev_modules` | Devel, Kint, Webprofiler for debugging |
| `xdebug` | XDebug PHP debugger integration |
| `stage_file_proxy` | Proxy files from remote server (avoid local file sync) |

### Infrastructure Services

| Option | Description |
|--------|-------------|
| `redis` | Redis caching service via DDEV addon |
| `solr` | Apache Solr search via DDEV addon |

### Configuration Management

| Option | Description |
|--------|-------------|
| `config_split` | Environment-specific configuration |

### Security

| Option | Description |
|--------|-------------|
| `security_modules` | Seckit, Honeypot, Login Security, Flood Control |

### Cron

| Option | Description |
|--------|-------------|
| `cron` | Ultimate Cron for advanced scheduling |

### Migration

| Option | Description |
|--------|-------------|
| `migration` | Migration folder structure (source/, database/) |

## Examples

### Interactive Site Selection

```bash
pl modify
```

Shows list of all sites, allows arrow key selection:

```
NWP Modify  |  ↑↓:Navigate  ENTER:Select  q:Quit
═══════════════════════════════════════════════════════════════

   SITE                 RECIPE       ENVIRONMENT  EXISTS DIRECTORY
   -------------------- ------------ ------------ ------ ---------
▸  avc                  nwp          production   Yes    /home/rob/nwp/sites/avc
   nwp5                 d            development  Yes    /home/rob/nwp/sites/nwp5
   testsite             drupal       development  No     /home/rob/nwp/sites/testsite
```

### Modify Specific Site

```bash
pl modify avc
```

Opens TUI directly for the `avc` site with current options pre-selected.

### Show Site Information

```bash
pl modify avc --info
```

Displays detailed site information without opening TUI:

```
Site: avc
Directory: /home/rob/nwp/sites/avc
Recipe: nwp
Purpose: Main production site

Infrastructure Status:
  ✓ Directory exists
  ✓ Code present
  ✓ DDEV configured
  ✓ DDEV running
    PHP: 8.3
    Database: mysql 8.0
  ✓ Drupal installed
    Drupal: 11.1.0

Options (from nwp.yml):
  dev_modules: true
  stage_file_proxy: true
  redis: true

Currently Installed (detected):
  - Development Modules (devel)
  - Stage File Proxy
  - Redis Caching
```

### List All Sites

```bash
pl modify --list
```

Lists all sites including orphaned directories:

```
Sites

  SITE                 RECIPE       ENVIRONMENT  DIRECTORY
  -------------------- ------------ ------------ ---------
  avc                  nwp          production   /home/rob/nwp/sites/avc
  nwp5                 d            development  /home/rob/nwp/sites/nwp5

  Orphaned sites (not in nwp.yml):
  oldsite              drupal       (orphan)     /home/rob/nwp/sites/oldsite
```

Orphaned sites appear in yellow and can be modified but aren't tracked in `nwp.yml`.

## Interactive TUI

### Navigation

```
NWP Modify: avc

  ↑↓: Navigate  SPACE: Toggle  e: Edit  a: Select defaults  ENTER: Apply  q: Quit
  ═══════════════════════════════════════════════════════════════════════════════

  Development Tools
    [✓] ● Development Modules (devel, kint, webprofiler)
    [ ] ○ XDebug Debugger
    [✓] ● Stage File Proxy (avoid local file sync)

  Infrastructure Services
    [✓] ○ Redis Caching
    [ ] ○ Apache Solr Search

  Configuration
    [ ] ○ Config Split (environment-specific config)

  Security
    [ ] ○ Security Modules (seckit, honeypot, login_security, flood_control)

  ───────────────────────────────────────────────────────────────────────────────
  5 selected  |  4 changes pending
```

### Controls

| Key | Action |
|-----|--------|
| `↑` / `↓` | Navigate options |
| `SPACE` | Toggle option on/off |
| `e` | Edit input values (if applicable) |
| `a` | Select all recommended defaults |
| `n` | Deselect all (reset to current state) |
| `ENTER` | Apply changes |
| `q` | Cancel without changes |

## Site Detection

The modify command detects:

### Infrastructure Status

- Directory exists
- Code present (composer.json or index.php)
- DDEV configured (.ddev/ directory)
- DDEV running (ddev describe succeeds)
- Drupal installed (drush status succeeds)

### Installed Options

| Detection Method | Options Detected |
|------------------|------------------|
| `drush pm:list --status=enabled` | Modules (devel, redis, config_split, etc.) |
| `ddev xdebug status` | XDebug state |
| `.ddev/docker-compose.*.yaml` | DDEV services (redis, solr) |
| Directory structure | Migration folders |

### Site Must Be Running

To detect installed options, the site must be running. If DDEV is stopped:

```
(Site not running - start with 'ddev start' to detect installed options)
```

The script will not automatically start DDEV to avoid unexpected resource usage.

## Orphaned Site Detection

Orphaned sites are directories with `.ddev/` but not in `nwp.yml`:

```
/home/rob/nwp/sites/
  ├── avc/          # In nwp.yml ✓
  │   └── .ddev/
  ├── nwp5/         # In nwp.yml ✓
  │   └── .ddev/
  └── oldtest/      # NOT in nwp.yml ✗ (orphaned)
      └── .ddev/
```

Orphaned sites:
- Show in yellow in site list
- Can be modified via TUI
- Don't update `nwp.yml` (not tracked)
- Useful for cleanup or migration

### Recipe Detection

For orphaned sites, the script detects recipe type from:

| Indicator | Detected Recipe |
|-----------|----------------|
| `.ddev/config.yaml` type: drupal | `d` (generic Drupal) |
| `html/` directory | `nwp` (NWP Drupal) |
| `profiles/contrib/social` | `os` (Open Social) |
| `.ddev/config.yaml` type: wordpress | `wp` |
| Other | `?` (unknown) |

## Applying Changes

When you press ENTER, the script:

1. Shows a confirmation summary:
   ```
   Changes to apply:
     Install: +2 (redis, solr)
     Remove: -1 (xdebug)

   Proceed? (y/N)
   ```

2. Executes changes:
   ```
   Applying Options

   [i] Installing Redis...
   [✓] Redis service added
   [i] Restarting DDEV...
   [✓] DDEV restarted
   [i] Installing Solr...
   [✓] Solr service added
   [i] Disabling XDebug...
   [✓] XDebug disabled

   [✓] Installed: 2  Removed: 1
   ```

3. Updates `nwp.yml`:
   ```
   [i] Updating nwp.yml...
   [✓] nwp.yml updated
   ```

## nwp.yml Updates

Changes are saved to `nwp.yml` under the site's `options:` section:

```yaml
sites:
  avc:
    directory: /home/rob/nwp/sites/avc
    recipe: nwp
    options:
      dev_modules: true
      stage_file_proxy: true
      redis: true
      solr: false
      xdebug: false
      security_modules: false
      config_split: false
      migration: false
```

This allows options to persist across installations and be shared with team members.

## Service Restarts

Some changes require DDEV restart:

| Change | Requires Restart |
|--------|------------------|
| Add/remove Redis | Yes |
| Add/remove Solr | Yes |
| Enable/disable dev modules | No |
| Enable/disable XDebug | No |
| Add/remove Stage File Proxy | No |

The script automatically restarts DDEV when needed:

```
[i] Restarting DDEV...
[✓] DDEV restarted
```

## Option Implementation

### Development Modules

**Install:**
```bash
ddev drush pm:enable devel -y
```

**Remove:**
```bash
ddev drush pm:uninstall devel -y
```

Includes: devel, kint, webprofiler (if available)

### XDebug

**Enable:**
```bash
ddev xdebug on
```

**Disable:**
```bash
ddev xdebug off
```

Immediate effect, no restart needed.

### Redis

**Add:**
```bash
ddev get ddev/ddev-redis
ddev restart
ddev composer require drupal/redis
ddev drush pm:enable redis -y
```

**Remove:**
```bash
ddev drush pm:uninstall redis -y
rm -rf .ddev/redis .ddev/docker-compose.redis.yaml
ddev restart
```

### Solr

**Add:**
```bash
ddev get ddev/ddev-solr
ddev restart
ddev composer require drupal/search_api_solr
ddev drush pm:enable search_api_solr -y
```

**Remove:**
```bash
ddev drush pm:uninstall search_api_solr -y
rm -rf .ddev/solr .ddev/docker-compose.solr.yaml
ddev restart
```

### Stage File Proxy

**Add:**
```bash
ddev composer require drupal/stage_file_proxy
ddev drush pm:enable stage_file_proxy -y
```

**Remove:**
```bash
ddev drush pm:uninstall stage_file_proxy -y
```

Must be configured in settings.php or config to point to production:

```php
$config['stage_file_proxy.settings']['origin'] = 'https://example.com';
```

### Migration Folder

**Add:**
```bash
mkdir -p migration/source migration/database
```

**Remove:**
Only removes if empty (safety check):
```bash
rm -rf migration/  # Only if source/ and database/ are empty
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success or user cancelled |
| 1 | Error (site not found, invalid argument) |

## Prerequisites

- Site must exist in `sites/` directory
- DDEV should be running to detect current options
- Internet connection for installing new modules/services

## Notes

- **Safe to cancel**: Pressing `q` or `ESC` exits without changes
- **Detection requires running site**: DDEV must be running to detect installed options
- **Services need restart**: Redis and Solr require DDEV restart
- **Migration folder safety**: Only deletes migration folder if completely empty
- **Orphaned sites**: Can modify orphaned sites but changes won't persist in nwp.yml
- **Multiple runs**: Safe to run multiple times; detects current state each time

## Troubleshooting

### Site Not Running - Can't Detect Options

**Symptom:** Message says "(Site not running - start with 'ddev start')"

**Solution:**
```bash
cd sites/sitename
ddev start
pl modify sitename
```

### Changes Don't Take Effect

**Symptom:** Toggled option but nothing changed

**Solution:**
1. Check for errors in output
2. Verify DDEV is running: `ddev describe`
3. Try manual installation:
   ```bash
   cd sites/sitename
   ddev drush pm:enable module_name -y
   ```

### Redis/Solr Won't Start

**Symptom:** Service added but not accessible

**Solution:**
1. Check DDEV logs: `ddev logs`
2. Verify Docker has resources: `docker stats`
3. Restart DDEV: `ddev restart`
4. Check service config: `ls .ddev/docker-compose.*.yaml`

### Site Not in List

**Symptom:** Site exists but doesn't appear in `pl modify --list`

**Solution:**
1. Check `nwp.yml` has site entry
2. Verify site directory exists
3. Look in orphaned sites section (yellow)
4. Create site entry manually in `nwp.yml`

### Can't Remove Migration Folder

**Symptom:** "Migration folder contains files, not removed"

**Solution:**
1. Review contents: `ls -la sites/sitename/migration/`
2. Move important files elsewhere
3. Delete manually if safe: `rm -rf sites/sitename/migration/`

### XDebug Won't Enable

**Symptom:** Toggle XDebug but still shows disabled

**Solution:**
1. Check DDEV XDebug support: `ddev xdebug status`
2. Verify IDE/editor configuration
3. Try manual: `ddev xdebug on && ddev xdebug status`
4. Check DDEV version: `ddev version` (update if old)

## Related Commands

- [install.sh](../scripts/install.sh) - Create new sites
- [status.md](./status.md) - Check site status
- [sync.md](./sync.md) - Sync from remote site

## See Also

- [Site Options Guide](../../guides/site-options.md) - Detailed option explanations
- [DDEV Add-ons](https://ddev.readthedocs.io/en/stable/users/extend/additional-services/) - Available DDEV services
- [Stage File Proxy](https://www.drupal.org/project/stage_file_proxy) - Module documentation
