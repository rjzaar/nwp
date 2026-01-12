# NWP Scripts Implementation (Sections 1.1, 1.2, 2.1, 2.2, 3.1, 3.2, 4.1, 4.2, 4.3, 5.1, 9.1)

## Overview

Implemented comprehensive NWP scripts based on Pleasy functionality, adapted for DDEV environments:

1. **backup.sh** - Full and database-only backups (with `-b` flag)
2. **restore.sh** - Full and database-only restore (with `-b` flag)
3. **copy.sh** - Full and files-only site copying (with `-f` flag)
4. **make.sh** - Enable development or production mode (with `-v`/`-p` flags)
5. **dev2stg.sh** - Deploy from development to staging environment

All scripts support combined short flags (e.g., `-bfy`, `-fy`, `-yo`) for efficient command-line usage.
All scripts tested successfully with nwp4 and nwp5 test sites.

**Environment Naming Convention (Section 9.1):**
- Development: `sitename` (e.g., `nwp`)
- Staging: `sitename-stg` (e.g., `nwp-stg`)
- Production: `sitename-prod` (e.g., `nwp-prod`)

Postfix naming is used instead of prefix for better organization and tab-completion.

---

## 1. Backup Script (`backup.sh`)

Combined backup script supporting both full site backups and database-only backups.

### Features

- **Full backups**: Database + files (default)
- **Database-only backups**: Use `-b` flag to skip file archiving
- Pleasy-style naming convention: `YYYYMMDDTHHmmss-branch-commit-message.sql`
- Support for backup messages
- Support for endpoint specification via `-e` flag
- Stored in `sitebackups/<sitename>/` directory
- Timer showing backup duration
- **Combined flags**: All short flags can be combined (e.g., `-bd` for database-only with debug)

### Usage

```bash
# Full backup (database + files)
./backup.sh nwp4
./backup.sh nwp4 'Before major update'

# Database-only backup
./backup.sh -b nwp4
./backup.sh -b nwp4 'Before schema change'

# Combined flags: database-only with debug
./backup.sh -bd nwp4 'Test backup'

# Backup to different endpoint
./backup.sh -e=nwp_backup nwp4 'Test backup'
```

### Options

- `-h, --help` - Show help message
- `-d, --debug` - Enable debug output
- `-b, --db-only` - Database-only backup (skip files)
- `-g, --git` - Create supplementary git backup (stub)
- `-e, --endpoint=NAME` - Backup to different endpoint

### Testing Results

- ✅ Full backup (database + files) - completed in 4 seconds
- ✅ Database-only backup - completed in 1 second
- ✅ Message handling (spaces to underscores)
- ✅ File size reporting
- ✅ Timer display
- ✅ Endpoint specification

---

## 2. Restore Script (`restore.sh`)

Combined restore script supporting both full site restoration and database-only restoration.

### Features

- **Full restore**: Files + database + DDEV configuration (default)
- **Database-only restore**: Use `-b` flag to skip file operations
- Interactive backup selection with size display
- Support for `-f` flag to auto-select latest backup
- Support for cross-site restore (restore from one site to another)
- Step-based execution with resume capability (`-s` flag)
- Cache clearing after restore
- Optional login link generation with `-o` flag
- Automatic DDEV configuration for full restores
- **Combined flags**: All short flags can be combined (e.g., `-bfyo` for database-only + auto-select + auto-confirm + open)

### Usage

```bash
# Full restore (files + database)
./restore.sh nwp4
./restore.sh nwp4 nwp4_copy

# Database-only restore
./restore.sh -b nwp4
./restore.sh -b nwp4 nwp5

# Combined flags: auto-select + auto-confirm
./restore.sh -fy nwp4

# Combined flags: database-only + auto-select + auto-confirm + open
./restore.sh -bfyo nwp4

# Resume from step 5
./restore.sh -s=5 nwp4
```

### Options

- `-h, --help` - Show help message
- `-d, --debug` - Enable debug output
- `-b, --db-only` - Database-only restore (skip files)
- `-s, --step=N` - Resume from step N
- `-f, --first` - Auto-select latest backup
- `-y, --yes` - Skip confirmation prompts
- `-o, --open` - Generate login link after restore

### Full Restore Workflow

1. Select backup
2. Validate destination (delete if exists)
3. Extract files
4. Fix settings
5. Set permissions
6. Configure DDEV and start
7. Restore database
8. Clear cache
9. Generate login link (if `-o`)

### Database-Only Restore Workflow

1. Select backup
2. Validate destination (must exist)
3. Restore database
4. Clear cache
5. Generate login link (if `-o`)

### Testing Results

- ✅ Full restore (nwp4 → nwp_test) - completed in 28 seconds
- ✅ Database-only restore (nwp4 → nwp5) - completed in 1 second
- ✅ Backup selection (interactive and auto-select)
- ✅ Cross-site restore capability
- ✅ DDEV configuration and startup
- ✅ Database import successful
- ✅ Cache clear attempted
- ✅ Site accessible after restoration

---

## 3. Site Copy Script (`copy.sh`)

Combined script for copying sites with full or files-only modes.

### Features

- **Full copy** (default): Complete site cloning (files + database)
- **Files-only copy** (`-f` flag): Copy files only, preserve destination database
- Automatic DDEV configuration for full copy
- Support for destination deletion and recreation (full copy)
- Destination validation for files-only copy (must exist)
- Converts underscores to hyphens in project names (DDEV requirement)
- Optional login link generation
- **Combined flags**: All short flags can be combined (e.g., `-fy` for files-only with auto-confirm)

### Usage

```bash
# Full copy (files + database)
./copy.sh nwp4 nwp5

# Files-only copy
./copy.sh -f nwp4 nwp5

# Full copy with auto-confirm
./copy.sh -y nwp4 nwp_backup

# Files-only with auto-confirm
./copy.sh -fy nwp4 nwp5

# Full copy with auto-confirm + login link
./copy.sh -yo nwp4 nwp_test
```

### Options

- `-h, --help` - Show help message
- `-d, --debug` - Enable debug output
- `-f, --files-only` - Copy files only (skip database operations)
- `-y, --yes` - Skip confirmation prompts
- `-o, --open` - Generate login link after copy

### Full Copy Workflow

1. Validate source site exists
2. Prepare destination directory (delete if exists)
3. Copy all files from source to destination
4. Export source database
5. Configure DDEV for destination
6. Import database into destination
7. Fix site settings
8. Set permissions
9. Clear cache
10. Generate login link (with `-o` flag)

### Files-Only Workflow

1. Validate source site exists
2. Validate destination exists and has DDEV configured
3. Copy all files from source to destination
4. Fix site settings
5. Set permissions

### What Gets Copied

**Full copy:**
- Webroot (html/web)
- Private files
- Configuration (cmi)
- Composer files (composer.json/lock)
- Complete database
- Fresh DDEV configuration

**Files-only copy:**
- Webroot (html/web)
- Private files
- Configuration (cmi)
- Composer files
- **Database is NOT copied** (preserved from destination)

### Testing Results

- ✅ Full site copy (nwp4 → nwp5) - completed in 26 seconds
- ✅ Files-only copy (nwp4 → nwp5) - completed in 1 second
- ✅ File copying successful
- ✅ Database operations (full copy only)
- ✅ DDEV configured and started (full copy only)
- ✅ Site accessible after copy
- ✅ Combined flags working (`-fy`, `-yo`)

### Known Issues

- DDEV project names with underscores must be converted to hyphens (handled automatically)
- Destination directory removal requires DDEV to be stopped first (handled automatically)
- For files-only copy, destination must already exist with DDEV configured

---

## 4. Make Script (`make.sh`)

Combined script for enabling development or production mode on a Drupal site.

### Features

- **Development mode** (`-v` or `--dev`): Install dev packages, enable dev modules, disable caching
- **Production mode** (`-p` or `--prod`): Remove dev packages, disable dev modules, enable caching
- Mode selection required via `-v` or `-p` flag
- **Combined flags**: All short flags can be combined (e.g., `-vy` for dev mode with auto-confirm)
- Comprehensive validation and error handling
- Execution timers and status updates

### Usage

```bash
# Enable development mode
./make.sh -v nwp4
./make.sh --dev nwp5

# Enable production mode
./make.sh -p nwp4
./make.sh --prod nwp5

# Combined flags: dev mode with auto-confirm
./make.sh -vy nwp4

# Combined flags: prod mode with debug and auto-confirm
./make.sh -pdy nwp5
```

### Options

- `-h, --help` - Show help message
- `-d, --debug` - Enable debug output
- `-v, --dev` - Enable development mode
- `-p, --prod` - Enable production mode
- `-y, --yes` - Skip confirmation prompts

### Development Mode Actions

1. Install dev packages: `drupal/devel`
2. Enable dev modules: `devel`, `webprofiler`, `kint`
3. Disable CSS/JS aggregation
4. Disable page cache
5. Fix file permissions
6. Clear cache

### Production Mode Actions

1. Disable dev modules: `webprofiler`, `kint`, `stage_file_proxy`, `devel`
2. Remove dev dependencies: `composer install --no-dev`
3. Enable CSS/JS aggregation
4. Enable page cache (600 seconds)
5. Export configuration
6. Fix permissions
7. Clear cache

### Development Modules

Enabled if available:
- devel
- webprofiler
- kint
- stage_file_proxy (noted for manual enabling)

### Notes

**For Development Mode:**
- For full Twig debugging, manually edit `development.services.yml`
- Configure `settings.local.php` for additional dev settings
- Consider enabling `stage_file_proxy` module for file syncing

**For Production Mode:**
- For actual production, deploy to a production server
- Lock down file permissions on production
- Remove `development.services.yml` from production
- Ensure `settings.local.php` is not deployed

---

## 5. Dev to Staging Deployment Script (`dev2stg.sh`)

Enhanced deployment script with intelligent state detection, multi-source database routing, integrated testing, and interactive TUI.

### Features

- **Interactive TUI Mode**: Visual interface for reviewing state and selecting options (default)
- **Intelligent State Detection**: Automatically detects site status, available backups, and production access
- **Multi-Source Database Routing**: Choose from auto, production, backup, development, or URL sources
- **Auto-Staging Creation**: Creates staging site if it doesn't exist
- **Multi-Tier Testing**: 8 test types with 5 presets (quick, essential, functional, full, security-only)
- **Preflight Checks**: Doctor-style validation before deployment
- **Automated Mode**: Full automation with `-y` flag for CI/CD
- **Step-Based Execution**: Resume from any step with `-s` flag
- **Production Mode**: Automatically enables production settings on staging

### Usage

```bash
# Interactive TUI mode (default)
./dev2stg.sh nwp

# Automated mode (skip all prompts)
./dev2stg.sh -y nwp

# With preflight checks only
./dev2stg.sh --preflight nwp

# With specific database source
./dev2stg.sh --db-source=production nwp
./dev2stg.sh --db-source=backup:/path/to/file.sql.gz nwp

# With fresh production backup
./dev2stg.sh --fresh-backup nwp

# Use development database (clone from dev)
./dev2stg.sh --dev-db nwp

# With specific test preset
./dev2stg.sh -t essential nwp
./dev2stg.sh -t phpunit,phpstan nwp

# Skip tests
./dev2stg.sh -t skip nwp

# Resume from step 5
./dev2stg.sh -s 5 nwp
```

### Options

| Option | Description |
|--------|-------------|
| `-h, --help` | Show help message |
| `-d, --debug` | Enable debug output |
| `-y, --yes` | Skip all prompts (automated mode) |
| `-s, --step=N` | Resume from step N |
| `--db-source=SRC` | Database source (auto, production, backup:FILE, development, url:URL) |
| `--fresh-backup` | Force fresh backup from production |
| `--dev-db` | Use development database (clone) |
| `--no-sanitize` | Skip database sanitization |
| `-t, --test=SEL` | Test selection (preset name or comma-separated types) |
| `--create-stg` | Force staging creation |
| `--no-create-stg` | Never create staging |
| `--preflight` | Run preflight checks only |

### Test Presets

| Preset | Tests Included | Duration |
|--------|----------------|----------|
| `quick` | phpcs, eslint | ~1 min |
| `essential` | phpunit, phpstan, phpcs | ~4 min |
| `functional` | behat | ~10 min |
| `full` | All except accessibility | ~15 min |
| `security-only` | security, phpstan | ~2 min |
| `skip` | No tests | 0 min |

### Available Test Types

- `phpunit` - PHPUnit unit/integration tests
- `behat` - Behat BDD scenario tests
- `phpstan` - PHPStan static analysis
- `phpcs` - PHP CodeSniffer style checks
- `eslint` - JavaScript/TypeScript linting
- `stylelint` - CSS/SCSS linting
- `security` - Security vulnerability scan
- `accessibility` - WCAG accessibility checks

### Database Sources

| Source | Description |
|--------|-------------|
| `auto` | Intelligent selection: sanitized backup → recent backup → production → development |
| `production` | Fresh backup from production server |
| `backup:/path` | Specific backup file |
| `development` | Clone database from development site |
| `url:https://...` | Download from URL |

### Deployment Workflow (11 Steps)

1. **Preflight Checks** - Validate DDEV, Docker, disk space, sites
2. **State Detection** - Analyze source, target, backups, production access
3. **TUI or Auto Selection** - Configure database source and tests
4. **Create Staging** - Auto-create staging site if needed
5. **Export Configuration** - Export config from development
6. **Sync Files** - Rsync files with smart exclusions
7. **Database Setup** - Route database from selected source
8. **Composer Install** - Run `composer install --no-dev`
9. **Database Updates** - Apply pending updates with `drush updb`
10. **Import Configuration** - Import config with retry logic
11. **Run Tests** - Execute selected test suite
12. **Finalize** - Enable production mode, clear cache, show URL

### File Exclusions

Excluded from rsync:
- `settings.php` and `services.yml`
- `sites/default/files/` directory
- `.git/` directory and `.gitignore`
- `private/` directory
- `node_modules/`
- `dev/` directory

### TUI Interface

When run without `-y`, the script launches an interactive TUI that:

1. Shows current state (site status, backups, production access)
2. Recommends optimal database source
3. Allows database source selection
4. Allows test preset selection
5. Shows deployment plan for review
6. Allows modifications before proceeding

### Environment Detection

- `get_env_type()` - Detects development, staging, or production
- `get_base_name()` - Extracts base name without suffix
- `get_staging_name()` - Generates staging name (e.g., `nwp` → `nwp-stg`)

### Configuration (cnwp.yml)

```yaml
enhanced_example:
  # Development configuration
  dev_modules: devel kint webprofiler stage_file_proxy
  dev_composer: drupal/devel drupal/stage_file_proxy
  # Deployment configuration
  reinstall_modules: custom_module
  prod_method: rsync
  # Directory paths
  private: ../private
  cmi: ../cmi
  # Live server for production backups
  live:
    server_ip: 1.2.3.4
    domain: example.com
```

### CI/CD Integration

```yaml
# GitLab CI example
deploy_staging:
  script:
    - ./dev2stg.sh -y --db-source=auto -t essential $SITE_NAME
  only:
    - develop
```

### Testing Results

- ✅ Interactive TUI mode working
- ✅ Preflight checks comprehensive
- ✅ Database routing from multiple sources
- ✅ Auto-staging creation
- ✅ Test preset execution
- ✅ Configuration import with retry
- ✅ Production mode enabled on staging

### Notes

- Uses intelligent defaults for fully automated operation with `-y`
- Database sanitization automatically anonymizes user data
- Config import uses 3x retry for resilience
- Staging inherits settings from development DDEV config

---

## Integration with NWP

All scripts:
- Follow NWP coding style and conventions
- Use consistent color schemes and output functions
- Integrate with DDEV commands
- Support debug mode for troubleshooting
- Include comprehensive help messages
- Display execution timers
- Provide clear error messages and status updates

---

## Next Steps

Future enhancements could include:

1. **Section 1.1.4** - Implement full git-based backup functionality
2. **Section 1.1.7** - Add production backup methods (SSH/rsync)
3. **Configuration System** - Full integration of dev_modules/dev_composer/reinstall_modules from nwp.yml
4. **Unified CLI** - Create main `nwp` command wrapper for all scripts
5. **Production Deployment** - Create stg2prod.sh or dev2prod.sh for production deployment

---

## File Summary

| Script | Lines | Purpose | Sections |
|--------|-------|---------|----------|
| backup.sh | 451 | Full and database-only backup (with `-b` flag) | 1.1, 1.2 |
| restore.sh | 698 | Full and database-only restore (with `-b` flag) | 2.1, 2.2 |
| copy.sh | 658 | Full and files-only site copy (with `-f` flag) | 3.1, 3.2 |
| make.sh | 742 | Enable dev or prod mode (with `-v`/`-p` flags) | 4.2, 4.3 |
| dev2stg.sh | 584 | Deploy dev to staging environment | 4.1 |
| **TOTAL** | **3,133** | 5 scripts | |

**Key improvements:**
- All scripts support combined short flags (e.g., `-bfy`, `-fy`, `-yo`, `-vy`)
- Unified make.sh replaces makedev.sh and makeprod.sh
- Unified copy.sh replaces copy.sh and copyf.sh
- Added dev2stg.sh for automated deployment workflows
- Consistent flag naming: `-b` for database-only, `-f` for files-only, `-v` for dev, `-p` for prod
- Postfix environment naming: `nwp-stg`, `nwp-prod` (instead of `stg_nwp`, `prod_nwp`)
- Reduced code duplication while maintaining full functionality
- Streamlined script management (5 scripts instead of 6 separate ones)

---

*Document created: December 2024*
*All scripts tested with DDEV v1.24.8 on Ubuntu Linux*
