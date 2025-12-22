# Backup and Restore System Implementation (Section 1.1)

## Overview

Implemented the NWP backup and restore system based on Pleasy's backup/restore functionality, adapted for DDEV environments.

## Features Implemented

### ✅ Tasks Completed (from improvements.md Section 1.1)

| Task | Status | Description |
|------|--------|-------------|
| 1.1.1 | ✅ | Created `backup.sh` script for full site backups (files + database) |
| 1.1.2 | ✅ | Support for backup messages/notes |
| 1.1.3 | ✅ | Support for endpoint specification (`-e` flag) |
| 1.1.4 | 🟡 | Git-based backup option (`-g` flag) - stub implemented |
| 1.1.5 | ✅ | Created `sitebackups/` directory structure |
| 1.1.6 | ✅ | Timer display showing backup duration |
| 1.1.7 | 🟡 | Differentiate prod/non-prod methods - foundation in place |
| 1.1.8 | ✅ | Timestamped backup files (`.sql` and `.tar.gz`) |

## Usage

```bash
# Basic backup
./backup.sh nwp

# Backup with message
./backup.sh nwp 'Fixed login error'

# Backup to different endpoint
./backup.sh -e=nwp_backup nwp 'Test backup'

# Debug mode
./backup.sh -d nwp 'Debug backup'
```

## Naming Convention

Follows Pleasy's naming pattern:

```
YYYYMMDDTHHmmss-branch-commit-message.{sql,tar.gz}
```

Example:
```
20241221T143022-main-a1b2c3d4-fixed_error.sql
20241221T143022-main-a1b2c3d4-fixed_error.tar.gz
```

## Directory Structure

```
sitebackups/
├── nwp/
│   ├── 20241221T143022-main-a1b2c3d4-fixed_error.sql
│   └── 20241221T143022-main-a1b2c3d4-fixed_error.tar.gz
├── nwp4/
│   ├── 20241221T175408-no-git-no-git-Successful_backup_test.sql
│   └── 20241221T175408-no-git-no-git-Successful_backup_test.tar.gz
└── ...
```

## What Gets Backed Up

### Database
- Exported using `ddev export-db`
- Saved as uncompressed `.sql` file

### Files
- Webroot (`html` or `web`)
- `private/` directory (if exists)
- `cmi/` config directory (if exists)
- `composer.json` and `composer.lock`

## Options

- `-h, --help` - Show help message
- `-d, --debug` - Enable debug output
- `-g, --git` - Git-based backup (stub for future)
- `-e, --endpoint=NAME` - Backup to different location

## Technical Details

- Uses DDEV's `export-db` command for database backups
- Creates tar.gz archives for file backups
- Automatically detects webroot from DDEV config
- Supports git-based naming (extracts branch and commit hash)
- Shows elapsed time after completion
- Validates site exists and DDEV is configured

## Next Steps

To complete the backup system:

1. **Section 1.2**: Implement `backupdb.sh` for database-only backups
2. Implement full git backup functionality (`-g` flag)
3. Add production backup methods
4. Add backup rotation/cleanup functionality
5. Implement compression options for large backups

## Testing

Tested with:
- ✅ Basic backup creation
- ✅ Message handling (spaces to underscores)
- ✅ Debug output
- ✅ File size reporting
- ✅ Timer display
- ✅ Directory creation

## Integration with NWP

The backup script works standalone and integrates with the existing NWP structure:
- Respects DDEV configuration
- Uses existing color schemes and output functions
- Follows NWP coding style
- Compatible with recipe-based installations

---

## Restore Script Implementation

Created `restore.sh` based on Pleasy's restore functionality, adapted for DDEV environments.

### Features

- **8-Step Restoration Process**:
  1. Select backup (interactive or auto-select latest with `-f`)
  2. Validate destination (with optional auto-confirm via `-y`)
  3. Extract files from tar.gz archive
  4. Fix site settings (DDEV managed)
  5. Set proper permissions
  6. Restore database using DDEV
  7. Clear Drupal cache
  8. Generate login link (with `-o` flag, requires drush)

- **Backup Selection**: Interactive menu showing backup dates and file sizes
- **Resume Capability**: Use `-s, --step=N` to resume from specific step
- **Auto-confirmation**: Use `-y, --yes` to skip prompts
- **Login Link**: Use `-o, --open` to generate one-time login link after restore

### Usage

```bash
# Basic restore (same site)
./restore.sh nwp4

# Restore to different site name
./restore.sh nwp4 nwp4_test

# Auto-select latest backup and confirm
./restore.sh -f -y nwp4 nwp4_backup

# Restore and generate login link
./restore.sh -f -y -o nwp4 nwp4_test

# Resume from step 6 (database)
./restore.sh -s=6 nwp4 nwp4_test
```

### Options

- `-h, --help` - Show help message
- `-d, --debug` - Enable debug output
- `-f, --first` - Auto-select latest backup
- `-y, --yes` - Skip confirmation prompts
- `-o, --open` - Generate login link after restore
- `-s, --step=N` - Start from specific step (1-8)

### Technical Details

- **DDEV Configuration**: Automatically configures DDEV with proper project name (converts underscores to hyphens for valid hostnames)
- **Database Import**: Uses DDEV's `import-db` command with proper file path handling
- **File Extraction**: Extracts webroot, private, cmi, composer files from tar.gz
- **Permissions**: Sets proper ownership and permissions for Drupal files
- **Error Handling**: Validates backups exist, checks file integrity, handles missing dependencies

### Testing Results

Tested with nwp4 → nwp4_test restoration:
- ✅ Backup selection (interactive and auto-select)
- ✅ File extraction from tar.gz
- ✅ DDEV configuration and startup
- ✅ Database import (1.2MB SQL file)
- ✅ Site accessible at https://nwp4-test.ddev.site
- ⚠️ Cache clear (may fail if drush not available)
- ⚠️ Login link (requires drush installation)

### Known Issues

1. **Cache Clearing**: May fail with "Could not clear cache" if drush is not installed - this is non-fatal
2. **Login Link**: Requires drush to be installed in the site's composer dependencies
