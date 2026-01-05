# Live Site Import System for NWP

> **STATUS: IMPLEMENTED (January 2026)**
>
> This proposal has been fully implemented. Key components:
> - `scripts/commands/import.sh` - Main import script with TUI
> - `lib/import.sh` - Shared import functions
> - `lib/import-tui.sh` - TUI components for site/option selection
> - `scripts/commands/sync.sh` - Re-sync existing imported site from live
>
> See `docs/ROADMAP.md` P29 for implementation details.
>
> Archived for historical reference.

## Overview

This proposal outlines a system to import existing live Drupal sites from Linode servers into NWP's local development environment. The import system provides:

1. **Server Discovery Mode** - SSH into a Linode server, scan `/var/www/` to discover all sites
2. **Interactive TUI** - Select which sites to import with full option configuration
3. **Automated Import** - Pull database, files, configure DDEV, and register in cnwp.yml

## Goals

1. **Server scanning** - Discover all Drupal sites on a Linode server automatically
2. **Interactive selection** - TUI to choose sites and configure import options
3. **Safe by default** - Database sanitization enabled unless explicitly disabled
4. **Incremental updates** - Re-sync from live without full reimport
5. **Integration** - Works with existing NWP workflows (dev2stg, backup, restore)

---

## Proposed Architecture

### New Files

| File | Purpose |
|------|---------|
| `import.sh` | Main import script with TUI |
| `lib/import.sh` | Shared import functions |
| `lib/import-tui.sh` | TUI components for site/option selection |
| `lib/server-scan.sh` | Remote server scanning functions |
| `sync.sh` | Re-sync existing imported site from live |

### Configuration Extension (example.cnwp.yml)

```yaml
settings:
  # Existing settings...

linode:
  servers:
    production:
      ssh_host: root@203.0.113.10
      ssh_key: ~/.ssh/nwp
      label: "Production Server"
    staging:
      ssh_host: root@203.0.113.20
      ssh_key: ~/.ssh/nwp
      label: "Staging Server"

import_defaults:
  sanitize: true
  stage_file_proxy: true
  environment_indicator: true
  exclude_patterns:
    - "*.log"
    - "js/*"
    - "css/*"
    - "php/*"
    - "styles/*"
```

---

## Server Discovery Workflow

### Step 1: Connect to Server

```bash
./import.sh --server=production
# OR
./import.sh --ssh=root@203.0.113.10
```

### Step 2: Scan /var/www/ for Sites

The system SSHs into the server and scans for Drupal installations:

```bash
# Remote commands executed:
find /var/www -maxdepth 3 -name "settings.php" 2>/dev/null
find /var/www -maxdepth 3 -name "composer.json" -exec grep -l drupal {} \; 2>/dev/null
```

### Step 3: Analyze Each Discovered Site

For each potential site found:

```bash
# Detect Drupal version
grep "VERSION" /var/www/site1/web/core/lib/Drupal.php

# Get database size
drush sql:query "SELECT ROUND(SUM(data_length + index_length) / 1024 / 1024, 1)
                 FROM information_schema.tables WHERE table_schema = DATABASE();"

# Get files size
du -sh /var/www/site1/web/sites/default/files/

# Count modules
drush pm:list --status=enabled --format=count
```

---

## TUI Interface Design

### Screen 1: Server Selection

```
┌─────────────────────────────────────────────────────────────────────┐
│  NWP Import - Server Selection                                      │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  Select a Linode server to scan for sites:                          │
│                                                                     │
│  ▸ [1] production    root@203.0.113.10    Production Server         │
│    [2] staging       root@203.0.113.20    Staging Server            │
│    [3] Custom...     Enter SSH connection manually                  │
│                                                                     │
│  ↑↓: Navigate   Enter: Select   q: Quit                             │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### Screen 2: Site Discovery (Loading)

```
┌─────────────────────────────────────────────────────────────────────┐
│  NWP Import - Scanning Server                                       │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  Connecting to production (root@203.0.113.10)...                    │
│                                                                     │
│  [████████████░░░░░░░░] Scanning /var/www/                          │
│                                                                     │
│  Found so far:                                                      │
│    ✓ /var/www/site1/web         Drupal 10.3.2                       │
│    ✓ /var/www/site2/html        Drupal 10.2.1                       │
│    ○ /var/www/static-site       (not Drupal)                        │
│    ... scanning ...                                                 │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### Screen 3: Site Selection

```
┌─────────────────────────────────────────────────────────────────────┐
│  NWP Import - Select Sites                     production           │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  Found 4 Drupal sites. Select sites to import:                      │
│                                                                     │
│  ▸ [✓] site1          Drupal 10.3.2    DB: 245 MB   Files: 1.2 GB   │
│    [✓] site2          Drupal 10.2.1    DB: 89 MB    Files: 450 MB   │
│    [ ] client-site    Drupal 9.5.11    DB: 1.2 GB   Files: 5.8 GB   │
│    [ ] legacy-app     Drupal 7.98      DB: 340 MB   Files: 890 MB   │
│                                                                     │
│  ───────────────────────────────────────────────────────────────    │
│  Selected: 2 sites   Total: DB 334 MB, Files 1.65 GB                │
│  Estimated time: 12-18 minutes (with stage_file_proxy)              │
│                                                                     │
│  ↑↓: Navigate   Space: Toggle   a: All   n: None                    │
│  Enter: Configure options   q: Cancel                               │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### Screen 4: Import Options (Per-Site or Global)

```
┌─────────────────────────────────────────────────────────────────────┐
│  NWP Import - Options                          site1                │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  Configure import options for: site1 (Drupal 10.3.2)                │
│                                                                     │
│  ── DATABASE ──────────────────────────────────────────────────     │
│  ▸ [✓] Sanitize user data        Remove emails, reset passwords    │
│    [✓] Truncate cache tables     Reduce database size               │
│    [✓] Truncate watchdog         Remove log entries                 │
│                                                                     │
│  ── FILES ─────────────────────────────────────────────────────     │
│    [✓] Stage File Proxy          Download files on-demand           │
│    [ ] Full file sync            Download all files (1.2 GB)        │
│    [✓] Exclude generated files   Skip js/*, css/*, styles/*         │
│                                                                     │
│  ── LOCAL ENVIRONMENT ─────────────────────────────────────────     │
│    [✓] Environment indicator     Show dev/stg/prod badge            │
│    [ ] Development modules       Install devel, webprofiler         │
│    [✓] Config split              Environment-specific config        │
│                                                                     │
│  ── NAMING ────────────────────────────────────────────────────     │
│    Local name: site1             [Edit: e]                          │
│                                                                     │
│  ↑↓: Navigate   Space: Toggle   Enter: Confirm   g: Apply to all   │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### Screen 5: Confirmation

```
┌─────────────────────────────────────────────────────────────────────┐
│  NWP Import - Confirm                                               │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  Ready to import 2 sites from production:                           │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │ site1                                                       │    │
│  │   Source: /var/www/site1/web                                │    │
│  │   Local:  /home/rob/nwp/site1                               │    │
│  │   Options: sanitize, stage_file_proxy, config_split         │    │
│  ├─────────────────────────────────────────────────────────────┤    │
│  │ site2                                                       │    │
│  │   Source: /var/www/site2/html                               │    │
│  │   Local:  /home/rob/nwp/site2                               │    │
│  │   Options: sanitize, stage_file_proxy, environment_indicator│    │
│  └─────────────────────────────────────────────────────────────┘    │
│                                                                     │
│  Estimated time: 12-18 minutes                                      │
│  Disk space required: ~500 MB (with stage_file_proxy)               │
│                                                                     │
│  [Start Import]   [Back to Options]   [Cancel]                      │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### Screen 6: Import Progress

```
┌─────────────────────────────────────────────────────────────────────┐
│  NWP Import - Progress                                              │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  Importing site1 (1/2)                                              │
│                                                                     │
│  [████████████████████░░░░░░░░░░] 65%                               │
│                                                                     │
│  ✓ Step 1:  Create local directory                                  │
│  ✓ Step 2:  Configure DDEV                                          │
│  ✓ Step 3:  Pull database (245 MB)                      2m 34s      │
│  ✓ Step 4:  Pull essential files                        0m 12s      │
│  ✓ Step 5:  Import database                             1m 45s      │
│  ✓ Step 6:  Sanitize user data                          0m 08s      │
│  ● Step 7:  Configure settings.php                      ...         │
│  ○ Step 8:  Configure Stage File Proxy                              │
│  ○ Step 9:  Clear caches                                            │
│  ○ Step 10: Verify site boots                                       │
│  ○ Step 11: Register in cnwp.yml                                    │
│                                                                     │
│  Elapsed: 4m 39s   Remaining: ~2m 30s                               │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### Screen 7: Completion

```
┌─────────────────────────────────────────────────────────────────────┐
│  NWP Import - Complete                                              │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  ✓ Successfully imported 2 sites!                                   │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │ site1                                                       │    │
│  │   URL: https://site1.ddev.site                              │    │
│  │   Admin: https://site1.ddev.site/user/login                 │    │
│  │   Time: 7m 12s                                              │    │
│  ├─────────────────────────────────────────────────────────────┤    │
│  │ site2                                                       │    │
│  │   URL: https://site2.ddev.site                              │    │
│  │   Admin: https://site2.ddev.site/user/login                 │    │
│  │   Time: 5m 48s                                              │    │
│  └─────────────────────────────────────────────────────────────┘    │
│                                                                     │
│  Next steps:                                                        │
│    cd site1 && ddev launch                                          │
│    ./sync.sh site1              # Re-sync from production           │
│    ./backup.sh site1            # Create local backup               │
│                                                                     │
│  [Open site1]   [Open site2]   [Done]                               │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Import Options Reference

### Database Options

| Option | Key | Default | Description |
|--------|-----|---------|-------------|
| Sanitize user data | `sanitize` | `y` | Replace emails with fake, reset passwords |
| Truncate cache tables | `truncate_cache` | `y` | Clear all cache_* tables |
| Truncate watchdog | `truncate_watchdog` | `y` | Remove log entries |
| Truncate sessions | `truncate_sessions` | `y` | Clear active sessions |
| Truncate search index | `truncate_search` | `y` | Clear search_* tables |
| Custom sanitization | `custom_sanitize` | `n` | Run custom SQL script |

### File Options

| Option | Key | Default | Description |
|--------|-----|---------|-------------|
| Stage File Proxy | `stage_file_proxy` | `y` | Download files on-demand from origin |
| Full file sync | `full_file_sync` | `n` | Download all public files |
| Include private files | `private_files` | `n` | Sync private file directory |
| Exclude generated | `exclude_generated` | `y` | Skip js/*, css/*, styles/* |
| Exclude large files | `exclude_large` | `n` | Skip files > 50MB |

### Local Environment Options

| Option | Key | Default | Description |
|--------|-----|---------|-------------|
| Environment indicator | `environment_indicator` | `y` | Show dev badge in admin |
| Development modules | `dev_modules` | `n` | Install devel, webprofiler, kint |
| Config split | `config_split` | `y` | Environment-specific config |
| XDebug | `xdebug` | `n` | Enable XDebug for debugging |
| Redis | `redis` | `n` | Enable Redis caching |
| PHP version | `php_version` | `auto` | Override detected PHP version |
| Database type | `database_type` | `mariadb` | mariadb, mysql, postgres |

---

## CLI Interface

### Interactive Mode (Default)

```bash
# Scan server and launch TUI
./import.sh --server=production

# Scan custom server
./import.sh --ssh=root@example.com

# Scan with SSH key
./import.sh --ssh=root@example.com --key=~/.ssh/custom_key
```

### Non-Interactive Mode

```bash
# Import specific site from server
./import.sh site1 --server=production --source=/var/www/site1/web

# Import with options
./import.sh site1 --server=production --source=/var/www/site1/web \
  --sanitize --stage-file-proxy --no-dev-modules

# Import all sites from server (auto-discovery)
./import.sh --server=production --all --yes

# Dry run (analyze only)
./import.sh --server=production --dry-run
```

### Flags Reference

| Flag | Description |
|------|-------------|
| `--server=NAME` | Use server from cnwp.yml linode.servers |
| `--ssh=USER@HOST` | SSH connection string |
| `--key=PATH` | SSH private key path |
| `--source=PATH` | Remote webroot path (skip discovery) |
| `--all` | Import all discovered sites |
| `--dry-run` | Analyze only, don't import |
| `--yes` / `-y` | Auto-confirm all prompts |
| `--sanitize` / `--no-sanitize` | Control sanitization |
| `--stage-file-proxy` | Enable stage file proxy |
| `--full-files` | Download all files |
| `-s=N` | Resume from step N |

---

## Server Scanning Implementation

### lib/server-scan.sh

```bash
#!/bin/bash

# Scan a remote server for Drupal sites
# Usage: scan_server "user@host" "ssh_key_path"
# Returns: JSON array of discovered sites

scan_server() {
    local ssh_target="$1"
    local ssh_key="${2:-$HOME/.ssh/nwp}"
    local ssh_opts="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"

    # Test SSH connection
    if ! ssh $ssh_opts -i "$ssh_key" "$ssh_target" "exit" 2>/dev/null; then
        echo "ERROR: Cannot connect to $ssh_target" >&2
        return 1
    fi

    # Find Drupal installations
    ssh $ssh_opts -i "$ssh_key" "$ssh_target" bash << 'REMOTE_SCRIPT'
        sites=()

        # Find settings.php files (Drupal indicator)
        while IFS= read -r settings_file; do
            webroot=$(dirname $(dirname $(dirname "$settings_file")))

            # Detect Drupal version
            version=""
            if [ -f "$webroot/core/lib/Drupal.php" ]; then
                version=$(grep "const VERSION" "$webroot/core/lib/Drupal.php" | \
                         grep -oP "'\K[^']+")
            elif [ -f "$webroot/includes/bootstrap.inc" ]; then
                version=$(grep "define('VERSION'" "$webroot/includes/bootstrap.inc" | \
                         grep -oP "'\K[^']+")
            fi

            # Get site name from directory
            site_dir=$(dirname "$webroot")
            site_name=$(basename "$site_dir")

            # Check if Drush is available
            has_drush="n"
            if [ -f "$site_dir/vendor/bin/drush" ]; then
                has_drush="y"
            fi

            # Get database size (if Drush available)
            db_size="unknown"
            if [ "$has_drush" = "y" ]; then
                cd "$site_dir"
                db_size=$(./vendor/bin/drush sql:query \
                    "SELECT ROUND(SUM(data_length + index_length)/1024/1024,1)
                     FROM information_schema.tables
                     WHERE table_schema = DATABASE();" 2>/dev/null || echo "unknown")
            fi

            # Get files size
            files_dir="$webroot/sites/default/files"
            if [ -d "$files_dir" ]; then
                files_size=$(du -sh "$files_dir" 2>/dev/null | cut -f1)
            else
                files_size="0"
            fi

            # Output site info as JSON line
            echo "{\"name\":\"$site_name\",\"webroot\":\"$webroot\",\"version\":\"$version\",\"db_size\":\"$db_size MB\",\"files_size\":\"$files_size\",\"has_drush\":\"$has_drush\"}"

        done < <(find /var/www -maxdepth 4 -name "settings.php" -path "*/sites/default/*" 2>/dev/null)
REMOTE_SCRIPT
}

# Analyze a specific site in detail
# Usage: analyze_site "user@host" "ssh_key" "/var/www/site1/web"
analyze_site() {
    local ssh_target="$1"
    local ssh_key="$2"
    local webroot="$3"
    local ssh_opts="-o StrictHostKeyChecking=accept-new"

    ssh $ssh_opts -i "$ssh_key" "$ssh_target" bash << REMOTE_SCRIPT
        cd "$(dirname "$webroot")"

        # Drupal version
        if [ -f "$webroot/core/lib/Drupal.php" ]; then
            echo "drupal_version=\$(grep 'const VERSION' '$webroot/core/lib/Drupal.php' | grep -oP \"'\\K[^']+\")"
        fi

        # PHP version
        echo "php_version=\$(php -v | head -1 | grep -oP 'PHP \\K[0-9]+\\.[0-9]+')"

        # Module count (if Drush available)
        if [ -f "vendor/bin/drush" ]; then
            echo "modules_enabled=\$(./vendor/bin/drush pm:list --status=enabled --format=count 2>/dev/null)"
            echo "modules_custom=\$(./vendor/bin/drush pm:list --status=enabled --type=custom --format=count 2>/dev/null)"
        fi

        # Theme info
        if [ -f "vendor/bin/drush" ]; then
            echo "default_theme=\$(./vendor/bin/drush config:get system.theme default --format=string 2>/dev/null)"
        fi

        # Database details
        if [ -f "vendor/bin/drush" ]; then
            echo "db_tables=\$(./vendor/bin/drush sql:query 'SHOW TABLES' 2>/dev/null | wc -l)"
        fi

        # Files breakdown
        echo "files_public=\$(du -sh '$webroot/sites/default/files' 2>/dev/null | cut -f1)"
        if [ -d "../private" ]; then
            echo "files_private=\$(du -sh ../private 2>/dev/null | cut -f1)"
        fi
REMOTE_SCRIPT
}
```

---

## Import Process Implementation

### Step-by-Step Import

```bash
import_site() {
    local site_name="$1"
    local ssh_target="$2"
    local ssh_key="$3"
    local remote_webroot="$4"
    local options="$5"  # JSON object of selected options

    local site_dir="$PWD/$site_name"
    local remote_site_dir=$(dirname "$remote_webroot")
    local webroot_name=$(basename "$remote_webroot")

    # Step 1: Create local directory
    print_step 1 "Create local directory"
    mkdir -p "$site_dir"

    # Step 2: Configure DDEV
    print_step 2 "Configure DDEV"
    cd "$site_dir"

    # Detect PHP version from remote
    local php_version=$(get_remote_php_version "$ssh_target" "$ssh_key" "$remote_webroot")

    ddev config \
        --project-type=drupal \
        --docroot="$webroot_name" \
        --php-version="$php_version" \
        --database="mariadb:10.11"

    # Step 3: Pull database
    print_step 3 "Pull database"
    ssh -i "$ssh_key" "$ssh_target" \
        "cd $remote_site_dir && vendor/bin/drush sql:dump --gzip" \
        > db.sql.gz

    # Step 4: Pull files (based on options)
    print_step 4 "Pull files"
    if option_enabled "full_file_sync" "$options"; then
        rsync -avz --progress \
            -e "ssh -i $ssh_key" \
            "$ssh_target:$remote_webroot/" \
            "$site_dir/$webroot_name/"
    else
        # Pull only essential files (composer, config, custom code)
        rsync -avz \
            -e "ssh -i $ssh_key" \
            --include="composer.json" \
            --include="composer.lock" \
            --include="config/***" \
            --include="modules/custom/***" \
            --include="themes/custom/***" \
            --include="sites/default/settings.php" \
            --include="sites/default/services.yml" \
            --exclude="sites/default/files/*" \
            --exclude="vendor/*" \
            "$ssh_target:$remote_site_dir/" \
            "$site_dir/"

        # Run composer install locally
        ddev composer install
    fi

    # Step 5: Import database
    print_step 5 "Import database"
    ddev start
    gunzip -c db.sql.gz | ddev mysql
    rm db.sql.gz

    # Step 6: Sanitize (if enabled)
    if option_enabled "sanitize" "$options"; then
        print_step 6 "Sanitize database"
        ddev drush sql:sanitize -y
    fi

    # Step 7: Configure settings.php
    print_step 7 "Configure settings.php"
    configure_local_settings "$site_dir" "$webroot_name"

    # Step 8: Configure Stage File Proxy (if enabled)
    if option_enabled "stage_file_proxy" "$options"; then
        print_step 8 "Configure Stage File Proxy"
        ddev drush pm:install stage_file_proxy -y

        # Get origin URL from remote
        local origin_url=$(get_remote_site_url "$ssh_target" "$ssh_key" "$remote_webroot")
        ddev drush config:set stage_file_proxy.settings origin "$origin_url" -y
    fi

    # Step 9: Clear caches
    print_step 9 "Clear caches"
    ddev drush cache:rebuild

    # Step 10: Verify site
    print_step 10 "Verify site"
    if ddev drush status --field=bootstrap 2>/dev/null | grep -q "Successful"; then
        print_success "Site is working"
    else
        print_warning "Site may need attention"
    fi

    # Step 11: Register in cnwp.yml
    print_step 11 "Register in cnwp.yml"
    register_imported_site "$site_name" "$ssh_target" "$remote_webroot" "$options"
}
```

---

## cnwp.yml Site Entry (After Import)

```yaml
sites:
  site1:
    directory: /home/rob/nwp/site1
    type: import
    source:
      server: production                  # Reference to linode.servers entry
      ssh_host: root@203.0.113.10
      webroot: /var/www/site1/web
    drupal_version: "10.3.2"
    php_version: "8.2"
    environment: development
    imported: 2024-12-29T10:30:00Z
    last_sync: 2024-12-29T10:30:00Z
    options:
      sanitize: true
      stage_file_proxy: true
      origin_url: "https://site1.example.com"
      environment_indicator: true
      config_split: true
```

---

## Sync Command

Re-sync an imported site with production:

```bash
./sync.sh site1

# Sync options
./sync.sh site1 --db-only          # Only sync database
./sync.sh site1 --files-only       # Only sync files
./sync.sh site1 --no-sanitize      # Skip sanitization this time
./sync.sh site1 --backup           # Backup before sync
```

### Sync Workflow

```
1. Backup current local state (optional)
2. Pull fresh database dump from source
3. Incremental rsync of changed files (if not using stage_file_proxy)
4. Import database
5. Re-apply sanitization
6. Update last_sync timestamp in cnwp.yml
7. Clear caches
```

---

## Error Handling & Rollback

### Pre-import Validation

1. Verify SSH connectivity to server
2. Verify remote site has Drush
3. Check local disk space (estimate from remote sizes)
4. Check for existing local site with same name
5. Verify DDEV is running

### Rollback on Failure

```
If import fails at step N:
  1. Stop DDEV containers
  2. Remove partially created directory
  3. Remove cnwp.yml entry
  4. Display clear error message with diagnostics
  5. Provide resume command: ./import.sh site1 --server=production -s=N
```

---

## Integration with Existing NWP Workflows

After import, all standard NWP commands work:

```bash
./backup.sh site1           # Backup imported site
./restore.sh site1          # Restore from backup
./dev2stg.sh site1          # Create staging copy
./modify.sh site1           # Add/remove options
./status.sh                 # Shows imported sites
./delete.sh site1           # Clean removal
./sync.sh site1             # Re-sync from production
```

---

## Implementation Phases

### Phase 1: Core Import (MVP)

- [ ] Server connection via SSH
- [ ] Basic site discovery (find settings.php)
- [ ] Simple TUI for site selection
- [ ] Database pull and import
- [ ] Essential file sync
- [ ] Basic sanitization
- [ ] DDEV configuration
- [ ] cnwp.yml registration

### Phase 2: Full TUI

- [ ] Server selection screen
- [ ] Site discovery with analysis
- [ ] Multi-site selection
- [ ] Per-site option configuration
- [ ] Global option application
- [ ] Progress display
- [ ] Completion summary

### Phase 3: Advanced Features

- [ ] Stage File Proxy auto-configuration
- [ ] Incremental sync (`sync.sh`)
- [ ] Detailed site analysis
- [ ] Custom sanitization scripts
- [ ] Large file handling
- [ ] Background transfers
- [ ] Resume from failure

### Phase 4: Polish

- [ ] Keyboard shortcuts help
- [ ] Estimated time calculations
- [ ] Disk space warnings
- [ ] Site health checks post-import
- [ ] Integration with `./status.sh`

---

## Technical Notes

### SSH Key Management

Uses existing NWP SSH key infrastructure:

```bash
# Keys stored in
~/.ssh/nwp          # Private key
~/.ssh/nwp.pub      # Public key

# Or project-local
./keys/nwp
./keys/nwp.pub
```

### Linode API Integration

Leverages existing `lib/linode.sh` for:

- Token management from `.secrets.yml`
- SSH key verification
- Server instance lookup

### TUI Framework

Uses existing `lib/tui.sh` patterns:

- `cursor_to()`, `cursor_hide()`, `cursor_show()`
- `read_key()` for arrow key navigation
- Color constants from `lib/ui.sh`
- Checkbox rendering from `lib/checkbox.sh`

---

## Questions for Discussion

1. **Multiple servers** - Should the TUI support scanning multiple servers in one session?

2. **Site naming** - How to handle name conflicts? (e.g., two servers have a site named "site1")

3. **Credentials** - Should we support sites with non-standard database credentials?

4. **Multisite** - Do we need to handle Drupal multisite installations?

5. **Large databases** - For databases > 1GB, should we show a warning or use compression?

6. **Concurrent imports** - Should we support importing multiple sites in parallel?
