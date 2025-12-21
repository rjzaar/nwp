# Backup System Implementation (Section 1.1)

## Overview

Implemented the NWP backup system based on Pleasy's backup functionality, adapted for DDEV environments.

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
