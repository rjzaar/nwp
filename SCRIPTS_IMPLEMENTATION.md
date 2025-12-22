# NWP Scripts Implementation (Sections 1.1, 1.2, 2.1, 2.2, 3.1, 3.2, 4.2, 4.3)

## Overview

Implemented comprehensive NWP scripts based on Pleasy functionality, adapted for DDEV environments:

1. **backup.sh** - Full and database-only backups (with `-b` flag)
2. **restore.sh** - Full and database-only restore (with `-b` flag)
3. **copy.sh** - Full site copying (files + database)
4. **copyf.sh** - Files-only copying
5. **make.sh** - Enable development or production mode

All scripts support combined short flags (e.g., `-bfy`, `-yo`) for efficient command-line usage.
All scripts tested successfully with nwp4 and nwp5 test sites.

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

## 3. Full Site Copy (`copy.sh`)

### Features

- Complete site cloning (files + database)
- Automatic DDEV configuration for destination
- Support for destination deletion and recreation
- Converts underscores to hyphens in project names (DDEV requirement)
- Comprehensive 10-step process
- Optional login link generation

### Usage

```bash
# Copy nwp4 to nwp5
./copy.sh nwp4 nwp5

# Copy with auto-confirm
./copy.sh -y nwp4 nwp_backup

# Copy and generate login link
./copy.sh -y -o nwp4 nwp_test
```

### Options

- `-h, --help` - Show help message
- `-d, --debug` - Enable debug output
- `-y, --yes` - Skip confirmation prompts
- `-o, --open` - Generate login link after copy

### Workflow

1. Validate source site exists
2. Prepare destination directory
3. Copy all files from source to destination
4. Export source database
5. Configure DDEV for destination
6. Import database into destination
7. Fix site settings
8. Set permissions
9. Clear cache
10. Generate login link (with `-o` flag)

### What Gets Copied

- Webroot (html/web)
- Private files
- Configuration (cmi)
- Composer files (composer.json/lock)
- Complete database
- Fresh DDEV configuration

### Testing Results

- ✅ Full site copy (nwp4 → nwp5)
- ✅ File copying successful
- ✅ Database export and import successful
- ✅ DDEV configured and started
- ✅ Site accessible at https://nwp5.ddev.site
- ✅ Copy completed in 26 seconds

### Known Issues

- DDEV project names with underscores must be converted to hyphens (handled automatically)
- Destination directory removal requires DDEV to be stopped first (handled automatically)

---

## 4. Files-Only Copy (`copyf.sh`)

### Features

- Copy files only (NO database operations)
- Destination must already exist
- Removes destination files before copying (for clean copy)
- Fixes settings and permissions after copy
- Database remains unchanged

### Usage

```bash
# Copy nwp4 files to nwp5
./copyf.sh nwp4 nwp5

# Copy with auto-confirm
./copyf.sh -y nwp4 nwp_files
```

### Options

- `-h, --help` - Show help message
- `-d, --debug` - Enable debug output
- `-y, --yes` - Skip confirmation prompts

### Workflow

1. Validate source site exists
2. Validate destination exists and has DDEV configured
3. Copy all files from source to destination
4. Fix site settings
5. Set permissions

### What Gets Copied

- Webroot (html/web)
- Private files
- Configuration (cmi)
- Composer files
- **Database is NOT copied**

### Testing Results

- ✅ Files-only copy (nwp4 → nwp5)
- ✅ File copying successful
- ✅ Settings verification
- ✅ Permissions set
- ✅ Database unchanged
- ✅ Copy completed in 1 second

---

## 5. Make Script (`make.sh`)

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
3. **Section 4.1** - Implement dev2stg.sh for deployment workflows
4. **Configuration System** - Add support for dev_modules/dev_composer in nwp.yml
5. **Unified CLI** - Create main `nwp` command wrapper for all scripts

---

## File Summary

| Script | Lines | Purpose | Sections |
|--------|-------|---------|----------|
| backup.sh | 451 | Full and database-only backup (with `-b` flag) | 1.1, 1.2 |
| restore.sh | 698 | Full and database-only restore (with `-b` flag) | 2.1, 2.2 |
| copy.sh | 608 | Full site copy | 3.1 |
| copyf.sh | 405 | Files-only copy | 3.2 |
| make.sh | 742 | Enable dev or prod mode (with `-v`/`-p` flags) | 4.2, 4.3 |
| **TOTAL** | **2,904** | 5 scripts | |

**Key improvements:**
- All scripts support combined short flags (e.g., `-bfy`, `-yo`, `-vy`)
- Unified make.sh script replaces separate makedev.sh and makeprod.sh
- Consistent flag naming: `-b` for database-only, `-v` for dev, `-p` for prod
- Reduced code duplication while maintaining full functionality

---

*Document created: December 2024*
*All scripts tested with DDEV v1.24.8 on Ubuntu Linux*
