# migration

**Last Updated:** 2026-01-14

Manage migrations from legacy CMS platforms to Drupal 11.

## Synopsis

```bash
pl migration <command> <sitename> [options]
```

## Description

The `migration` command provides a complete workflow for migrating content from legacy systems to Drupal 11. It supports Drupal 7/8/9, static HTML, WordPress, Joomla, and custom sources.

The migration workflow consists of four phases:
1. **Analyze** - Detect source type and analyze content structure
2. **Prepare** - Create target Drupal 11 site with migration modules
3. **Run** - Execute the migration process
4. **Verify** - Check migration completeness and quality

## Commands

| Command | Description |
|---------|-------------|
| `analyze` | Analyze source site structure and recommend migration path |
| `prepare` | Set up target Drupal 11 site with migration modules |
| `run` | Execute the migration (may run multiple times) |
| `verify` | Verify migration completeness and integrity |
| `status` | Show current migration status |

## Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `command` | Yes | Migration command to execute |
| `sitename` | Yes | Migration site name (stub created with `pl install d site -p=m`) |

## Options

| Option | Description |
|--------|-------------|
| `-h, --help` | Show help message |
| `-d, --debug` | Enable debug output |
| `-y, --yes` | Auto-confirm prompts |
| `--dry-run` | Show what would be done without making changes |

## Supported Source Types

### Drupal 7

- **Status**: End of Life (January 5, 2025)
- **Migration Path**: No direct upgrade - content migration required
- **Modules Used**: migrate, migrate_drupal, migrate_drupal_ui
- **Method**: Database migration using Migrate Drupal module

### Drupal 8/9/10

- **Status**: Supported upgrade paths
- **Migration Path**: Composer upgrade or content migration
- **Modules Used**: migrate, migrate_drupal (or in-place composer upgrade)
- **Method**: Incremental composer upgrade or full migration

### Static HTML

- **Migration Path**: Parse HTML and create nodes
- **Modules Used**: migrate_source_html
- **Method**: HTML parsing and field mapping

### WordPress

- **Migration Path**: Database migration
- **Modules Used**: wordpress_migrate
- **Method**: WordPress database to Drupal content types

### Joomla

- **Migration Path**: Custom migration configuration
- **Modules Used**: migrate_plus, custom configuration
- **Method**: Database mapping and content migration

### Other

- **Migration Path**: Custom migration configuration required
- **Modules Used**: migrate, migrate_plus
- **Method**: Custom source plugins and configuration

## Workflow

### 1. Create Migration Stub

```bash
pl install d mysite -p=m
```

Creates a migration stub with:
- `sites/mysite/` - Migration workspace
- `sites/mysite/source/` - Place source files here
- `sites/mysite/database/` - Place database dumps here

### 2. Copy Source Files

```bash
cp -r /old/site/files/* sites/mysite/source/
cp /old/site/database.sql.gz sites/mysite/database/
```

### 3. Analyze Source

```bash
pl migration analyze mysite
```

Detects source type, analyzes content, provides recommendations.

### 4. Prepare Target

```bash
pl migration prepare mysite
```

Creates `mysite_target` Drupal 11 site with migration modules.

### 5. Run Migration

```bash
pl migration run mysite
```

Provides instructions for running migration (UI or drush commands).

### 6. Verify Results

```bash
pl migration verify mysite
```

Checks migration status, errors, and site health.

## Examples

### Drupal 7 Migration

```bash
# Create migration stub
pl install d oldsite -p=m

# Copy source files
rsync -avz /var/www/oldsite/sites/default/files/ sites/oldsite/source/

# Export D7 database
ssh oldserver 'drush sql:dump --gzip' > sites/oldsite/database/d7.sql.gz

# Analyze
pl migration analyze oldsite
# Output:
#   Detected: drupal7
#   Tables: ~150
#   Files: 2.3GB
#   Custom modules: 5

# Prepare target
pl migration prepare oldsite
# Creates: oldsite_target with Drupal 11

# Configure source DB in sites/oldsite_target/web/sites/default/settings.php
# Add:
#   $databases['migrate']['default'] = [
#     'database' => 'oldsite_d7',
#     'username' => 'root',
#     'password' => '',
#     'host' => 'db',
#     'driver' => 'mysql',
#   ];

# Import source database to DDEV
cd sites/oldsite_target
gunzip < ../oldsite/database/d7.sql.gz | ddev mysql -D oldsite_d7

# Run migration via UI
ddev launch /upgrade

# Or via drush
ddev drush migrate:upgrade --legacy-db-key=migrate
ddev drush migrate:import --all

# Verify
pl migration verify oldsite
```

### Static HTML Migration

```bash
# Create stub
pl install d htmlsite -p=m

# Copy HTML files
cp -r /old/html/site/* sites/htmlsite/source/

# Analyze
pl migration analyze htmlsite
# Output:
#   Detected: html
#   HTML pages: 45
#   Images: 120
#   CSS files: 8

# Prepare target
pl migration prepare htmlsite
# Creates: htmlsite_target with migrate_source_html

# Configure migration in sites/htmlsite_target
# Create custom migration YAML in config/sync/migrate_plus.migration.html_pages.yml

# Run migration
cd sites/htmlsite_target
ddev drush migrate:import html_pages

# Verify
pl migration verify htmlsite
```

### WordPress Migration

```bash
# Create stub
pl install d wpsite -p=m

# Export WordPress database
ssh wpserver 'mysqldump wordpress | gzip' > sites/wpsite/database/wp.sql.gz

# Analyze
pl migration analyze wpsite
# Output:
#   Detected: wordpress
#   Themes: 3
#   Plugins: 15

# Prepare
pl migration prepare wpsite
# Creates: wpsite_target with wordpress_migrate

# Configure WordPress source DB
# Import WP database to DDEV
cd sites/wpsite_target
gunzip < ../wpsite/database/wp.sql.gz | ddev mysql -D wordpress_source

# Run migration
ddev drush migrate:import --group=wordpress

# Verify
pl migration verify wpsite
```

### Check Status

```bash
pl migration status mysite
```

Output:
```
Migration Status: mysite

Site: mysite
Source type: drupal7
Status: prepared
Created: 2026-01-10T15:30:00Z

Directories:
  Migration stub: EXISTS
  Source files: EXISTS
  Database dumps: EXISTS
  Target site: EXISTS
```

## Output

### Analyze Command

```
═══════════════════════════════════════════════════════════════
  Analyzing Migration Source: oldsite
═══════════════════════════════════════════════════════════════

[i] Detecting source type...
  Detected: drupal7

Content Analysis:
  PHP files: 1250
  Custom modules: 5
  Custom themes: 2
  Files: 3500 (2.3G)

Database Analysis:
  Found: database.sql.gz (45M)
    Tables: ~150

═══════════════════════════════════════════════════════════════
  Migration Recommendations
═══════════════════════════════════════════════════════════════

Source: Drupal 7 (EOL: January 5, 2025)

Recommended approach:
  1. Create fresh Drupal 11 site with: ./migration.sh prepare oldsite
  2. Install migration modules: migrate_drupal, migrate_drupal_ui
  3. Configure source database connection
  4. Run migration via UI at /upgrade or drush migrate commands

Key modules needed:
  - migrate (core)
  - migrate_drupal (core)
  - migrate_drupal_ui (core)
  - migrate_plus (contrib - for advanced migrations)
  - migrate_tools (contrib - for drush commands)

[✓] Analysis complete
```

### Prepare Command

```
═══════════════════════════════════════════════════════════════
  Preparing Target Site: oldsite
═══════════════════════════════════════════════════════════════

[i] Source type: drupal7
[i] Creating target Drupal 11 site: oldsite_target
[i] Installing migration modules...

[✓] Target site prepared: oldsite_target

Next steps:
  1. Configure source database in sites/oldsite_target/web/sites/default/settings.php
  2. Run: ./migration.sh run oldsite
```

### Run Command

```
═══════════════════════════════════════════════════════════════
  Running Migration: oldsite
═══════════════════════════════════════════════════════════════

[i] Migration type: drupal7

For Drupal 7 migration, use the UI at:
  https://oldsite-target.ddev.site/upgrade

Or use drush commands:
  ddev drush migrate:upgrade --legacy-db-key=migrate
  ddev drush migrate:import --all
```

### Verify Command

```
═══════════════════════════════════════════════════════════════
  Verifying Migration: oldsite
═══════════════════════════════════════════════════════════════

[i] Checking migration status...

 ----------- -------- ------- ------- ---------- ---------------
  Group       Status   Total   Imported  Unprocessed  Last Imported
 ----------- -------- ------- ------- ---------- ---------------
  default     Idle     0       0         0
  migrate_drupal_7    Idle     1250    1250      0         2026-01-14 10:30
 ----------- -------- ------- ------- ---------- ---------------

[i] Checking for migration errors...
No migration logs found

[i] Checking site health...
  Drupal version         : 11.1.0
  Database               : Connected
  PHP version            : 8.3.0

[✓] Verification complete

Manual verification recommended:
  1. Browse the target site and verify content
  2. Check user accounts migrated correctly
  3. Verify media and files are accessible
  4. Test site functionality
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Error (site not found, migration failed, invalid command) |

## Prerequisites

- Migration stub created with `pl install d site -p=m`
- Source files copied to `sites/sitename/source/`
- Database dump in `sites/sitename/database/` (for DB migrations)
- DDEV installed and running
- Internet connectivity for module downloads

## Migration Directory Structure

```
sites/mysite/
  ├── source/          # Source site files
  │   ├── index.php
  │   ├── sites/
  │   │   └── default/
  │   │       └── files/  # User-uploaded files
  │   └── modules/
  │       └── custom/     # Custom code
  ├── database/        # Database dumps
  │   └── source.sql.gz
  └── README.md        # Migration notes

sites/mysite_target/  # Created by 'prepare' command
  ├── web/            # Drupal 11 installation
  ├── config/         # Drupal configuration
  └── .ddev/          # DDEV configuration
```

## Source Database Configuration

For Drupal 7/8/9 migrations, configure source database in target site's `settings.php`:

```php
// sites/mysite_target/web/sites/default/settings.php

$databases['migrate']['default'] = [
  'database' => 'source_db_name',
  'username' => 'db',
  'password' => 'db',
  'host' => 'db',
  'port' => 3306,
  'driver' => 'mysql',
  'prefix' => '',
];
```

Import source database:

```bash
cd sites/mysite_target
gunzip < ../mysite/database/source.sql.gz | ddev mysql -D source_db_name
```

## Migration Modules

### Core Modules (Drupal 11)

- **migrate** - Core migration framework
- **migrate_drupal** - Drupal-to-Drupal migrations
- **migrate_drupal_ui** - Web UI for migration at `/upgrade`

### Contrib Modules

- **migrate_plus** - Advanced migration features, configuration entities
- **migrate_tools** - Drush commands for migration management
- **migrate_source_html** - Parse HTML sources
- **wordpress_migrate** - WordPress content migration

## Drush Commands

### Check Migration Status

```bash
ddev drush migrate:status
```

### Run Specific Migration

```bash
ddev drush migrate:import migration_name
```

### Run All Migrations

```bash
ddev drush migrate:import --all
```

### Rollback Migration

```bash
ddev drush migrate:rollback migration_name
```

### Reset Migration

```bash
ddev drush migrate:reset-status migration_name
```

## Notes

- **Drupal 7 EOL**: Drupal 7 reached end of life January 5, 2025
- **No direct upgrade**: Drupal 7 to 11 requires content migration, not code upgrade
- **Multiple runs**: Migrations can be run multiple times (rollback and re-import)
- **Incremental**: Can migrate in stages (users first, then content, then files)
- **Custom code**: Custom modules must be manually ported to Drupal 11
- **Configuration**: Drupal 7 configuration must be manually reconfigured in Drupal 11
- **Testing**: Always test migration on copy before running on production

## Troubleshooting

### Source Type Not Detected

**Symptom:** Analyze shows "unknown" source type

**Solution:**
1. Verify source files are in `sites/sitename/source/`
2. Check for index.php or other identifying files
3. Manually specify source_type in nwp.yml:
   ```yaml
   sites:
     mysite:
       source_type: drupal7
   ```

### Database Import Fails

**Symptom:** Cannot import source database to DDEV

**Solution:**
1. Check database dump format: `gunzip -c db.sql.gz | head`
2. Verify DDEV is running: `ddev describe`
3. Check database exists: `ddev mysql -e "SHOW DATABASES;"`
4. Create database manually: `ddev mysql -e "CREATE DATABASE source_db;"`
5. Import again: `gunzip < db.sql.gz | ddev mysql -D source_db`

### Migration Stuck or Failing

**Symptom:** Migration shows errors or stops mid-process

**Solution:**
1. Check migration status: `ddev drush migrate:status`
2. View errors: `ddev drush migrate:messages migration_name`
3. Reset stuck migration: `ddev drush migrate:reset-status migration_name`
4. Check DDEV logs: `ddev logs`
5. Increase PHP memory: Edit `.ddev/config.yaml`, add `php_memory_limit: 512M`

### Files Not Migrating

**Symptom:** Content migrated but files missing

**Solution:**
1. Verify files in source: `ls sites/mysite/source/sites/default/files/`
2. Copy files to target:
   ```bash
   rsync -av sites/mysite/source/sites/default/files/ \
            sites/mysite_target/web/sites/default/files/
   ```
3. Fix permissions: `ddev exec chmod -R 755 web/sites/default/files`
4. Re-run file migration if using Migrate API

### Custom Modules Won't Work

**Symptom:** Custom D7 modules don't work in D11

**Solution:**
1. Custom modules must be manually ported
2. Check Drupal 11 API changes
3. Rewrite custom code for Drupal 11
4. Consider if functionality exists in D11 core or contrib

### Memory Exhausted During Migration

**Symptom:** "Allowed memory size exhausted" error

**Solution:**
1. Increase PHP memory in `.ddev/config.yaml`:
   ```yaml
   php_version: "8.3"
   php_memory_limit: 1024M
   ```
2. Restart DDEV: `ddev restart`
3. Run migration in batches:
   ```bash
   ddev drush migrate:import migration_name --limit=100
   ```

## Related Commands

- [install.sh](../scripts/install.sh) - Create sites and migration stubs
- [sync.md](./sync.md) - Sync from remote servers
- [import.sh](../scripts/import.sh) - Import existing sites

## See Also

- [Drupal Migration Guide](https://www.drupal.org/docs/upgrading-drupal) - Official migration documentation
- [Migrate API](https://www.drupal.org/docs/drupal-apis/migrate-api) - Migrate API documentation
- [Migrate Plus](https://www.drupal.org/project/migrate_plus) - Advanced migration features
- [Migrate Tools](https://www.drupal.org/project/migrate_tools) - Drush commands
- [Drupal 7 EOL](https://www.drupal.org/psa-2023-06-07) - End of life announcement
