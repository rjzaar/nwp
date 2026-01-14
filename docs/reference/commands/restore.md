# restore

**Status:** ACTIVE
**Last Updated:** 2026-01-14

Restore Drupal sites from backups with flexible restoration options and cross-site restore capabilities.

## Synopsis

```bash
pl restore [OPTIONS] <from> [to]
```

## Description

The `restore` command restores Drupal sites from previously created backups. It supports both full restores (database + files) and database-only restores, with the ability to restore backups from one site to a different site.

The command provides interactive backup selection, automatic validation, and safety confirmations to prevent accidental data loss.

## Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `from` | Yes | Source site name (backup to restore from) |
| `to` | No | Destination site name (defaults to `from`) |

## Options

| Option | Description | Default |
|--------|-------------|---------|
| `-h, --help` | Show help message | - |
| `-d, --debug` | Enable debug output for troubleshooting | false |
| `-b, --db-only` | Database-only restore (skip files) | false (full restore) |
| `-s, --step=N` | Resume restoration from step N | - |
| `-f, --first` | Auto-select latest backup without prompting | false |
| `-y, --yes` | Auto-confirm deletion of existing content | false |
| `-o, --open` | Generate and display login link after restoration | false |

## Restore Types

### Full Restore (Default)

Restores both database and files from backup:
- **Database** - Restores complete database from SQL dump
- **Files** - Extracts and restores webroot files
- **Settings** - Fixes database connection settings
- **Permissions** - Sets proper file permissions

```bash
pl restore avc
```

### Database-Only Restore

Faster restore containing only the database (useful for quick rollbacks):

```bash
pl restore -b avc
```

**When to use:**
- Rolling back database changes
- Testing with different database states
- Updating development site with production data
- Files haven't changed since backup

### Cross-Site Restore

Restore a backup from one site to a different site:

```bash
# Restore 'avc' backup to 'avc-test' site
pl restore avc avc-test

# Database-only cross-site restore
pl restore -b production-site development-site
```

**Use cases:**
- Creating test environments from production
- Duplicating sites for development
- Migrating data between sites
- Creating staging environments

## Restoration Steps

### Full Restore Steps

1. **Select Backup** - Choose from available backups (or auto-select with `-f`)
2. **Validate Destination** - Verify target site exists and is running
3. **Extract Files** - Uncompress and restore files from `.tar.gz`
4. **Fix Settings** - Update `settings.php` with correct database credentials
5. **Set Permissions** - Apply proper file and directory permissions
6. **Restore Database** - Import SQL dump into database
7. **Clear Cache** - Clear Drupal caches
8. **Generate Login Link** - Create one-time login link (if `-o` flag used)

### Database-Only Restore Steps

1. **Select Backup** - Choose database backup file
2. **Confirm Restoration** - Warn about data loss, require confirmation
3. **Restore Database** - Import SQL dump
4. **Clear Cache** - Clear Drupal caches
5. **Generate Login Link** - Create one-time login link (if `-o` flag used)

## Examples

### Basic Restore

```bash
# Restore 'avc' from backup (interactive backup selection)
pl restore avc

# Database-only restore
pl restore -b avc

# Restore and open login link
pl restore -o avc
```

### Auto-Select Latest Backup

```bash
# Use latest backup without prompting
pl restore -f avc

# Latest DB-only restore with login link
pl restore -bfo avc
```

### Quick Workflow Flags

```bash
# Database-only + auto-select + auto-confirm + open login
pl restore -bfyo avc

# Full restore with all automation
pl restore -fyo avc
```

### Cross-Site Restore

```bash
# Restore production backup to development
pl restore production-site development-site

# Restore production DB to staging (files unchanged)
pl restore -b production-site staging-site

# Create test site from production
pl restore -f production-site test-site
```

### Resume After Interruption

```bash
# Resume full restore from step 5 (Set permissions)
pl restore -s=5 avc

# Resume from database restore step
pl restore -s=6 avc
```

## Backup Selection

When restoring without the `-f` flag, you'll see an interactive backup list:

```
Available backups for 'avc':

  1. 20260114T143022-main-a1b2c3d4-before_security_update.sql (245 MB)
     20260114T143022-main-a1b2c3d4-before_security_update.tar.gz (1.2 GB)
     Created: 2026-01-14 14:30:22

  2. 20260113T092015-main-b2c3d4e5-daily_backup.sql (243 MB)
     20260113T092015-main-b2c3d4e5-daily_backup.tar.gz (1.2 GB)
     Created: 2026-01-13 09:20:15

  3. 20260112T080510-develop-c3d4e5f6.sql (240 MB)
     20260112T080510-develop-c3d4e5f6.tar.gz (1.1 GB)
     Created: 2026-01-12 08:05:10

Select backup (1-3): _
```

With `-f` flag, the latest backup (1) is automatically selected.

## Output

Typical full restore output:

```
═══════════════════════════════════════════════════════════════
  Restore: avc
═══════════════════════════════════════════════════════════════

[1/8] Select backup
✓ Selected: 20260114T143022-main-a1b2c3d4-before_security_update

[2/8] Validate destination
✓ Site exists and is running: avc (https://avc.ddev.site)

WARNING: This will delete all existing content in 'avc'
Continue? [y/N]: y

[3/8] Extract files
✓ Files extracted: 12,450 files

[4/8] Fix settings
✓ Database credentials updated

[5/8] Set permissions
✓ Permissions applied

[6/8] Restore database
✓ Database restored: 245 MB

[7/8] Clear cache
✓ Caches cleared

[8/8] Generate login link
✓ Login link: https://avc.ddev.site/user/reset/1/...

═══════════════════════════════════════════════════════════════
  Restore Complete
═══════════════════════════════════════════════════════════════

Site URL: https://avc.ddev.site
Login:    https://avc.ddev.site/user/reset/1/...
```

Database-only restore output:

```
═══════════════════════════════════════════════════════════════
  Restore: avc (database only)
═══════════════════════════════════════════════════════════════

[1/5] Select backup
✓ Selected: 20260114T143022-main-a1b2c3d4.sql

WARNING: This will replace the current database in 'avc'
Continue? [y/N]: y

[2/5] Restore database
✓ Database restored: 245 MB

[3/5] Clear cache
✓ Caches cleared

[4/5] Generate login link
✓ Login link: https://avc.ddev.site/user/reset/1/...

═══════════════════════════════════════════════════════════════
  Restore Complete
═══════════════════════════════════════════════════════════════
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Restoration successful |
| 1 | Restoration failed |
| 2 | Missing required 'from' argument |
| 3 | Source site has no backups |
| 4 | Destination site not found |
| 5 | User cancelled operation |
| 6 | Backup file corrupted or invalid |

## Prerequisites

- **DDEV** - Destination site must exist and be running
- **Backup exists** - At least one backup of source site
- **Disk space** - Sufficient space for extraction
- **Drush** - For database import and cache clearing

## Safety Features

### Confirmation Prompts

The restore command includes multiple safety checks:

1. **Data loss warning** - Warns that existing content will be deleted
2. **Interactive confirmation** - Requires explicit 'y' response (unless `-y` flag used)
3. **Backup validation** - Verifies backup files exist and are readable
4. **Destination validation** - Confirms destination site exists

### Automatic Backup

Before restoration, consider creating a backup of the current state:

```bash
# Backup current state before restoring
pl backup -b avc "Before restore"
pl restore avc
```

### Resume Capability

If restoration is interrupted, resume from the last completed step:

```bash
# If interrupted at step 5
pl restore -s=6 avc
```

## Best Practices

### Pre-Restore Checklist

1. **Verify backup** - Ensure backup is recent and valid
2. **Check destination** - Confirm correct destination site
3. **Create safety backup** - Backup current state before restoring
4. **Review changes** - Know what will be lost when restoring

### When to Restore

**Database-only restore:**
- After failed module updates
- After problematic configuration changes
- Testing different database states
- Reverting content changes

**Full restore:**
- After failed Drupal core updates
- After file system corruption
- Disaster recovery
- Creating fresh test environments

### Common Workflows

**Development workflow:**
```bash
# Update production data in development
pl backup -b production-site
pl restore -bf production-site development-site
```

**Rollback failed update:**
```bash
# Quick rollback to pre-update state
pl restore -bfo avc
```

**Create test environment:**
```bash
# Clone production to test site
pl restore -f production-site test-site
```

## Troubleshooting

### No Backups Found

**Symptom:**
```
ERROR: No backups found for site 'avc'
```

**Solution:**
- Check backup directory: `ls sitebackups/avc/`
- Verify site name spelling
- Create a backup: `pl backup avc`
- Check backup location in `cnwp.yml`

### Destination Site Not Found

**Symptom:**
```
ERROR: Destination site 'avc' not found
```

**Solution:**
- Verify site exists: `ls sites/avc/`
- Check site is running: `ddev list`
- Install site first: `pl install d avc`

### Database Import Fails

**Symptom:**
```
ERROR: Failed to import database
```

**Solution:**
- Verify backup file integrity: `file backup.sql`
- Check database connection: `ddev mysql`
- Ensure sufficient disk space: `df -h`
- Try manual import: `ddev import-db --src=backup.sql`

### Permission Errors

**Symptom:**
```
ERROR: Permission denied setting file permissions
```

**Solution:**
- Check file ownership
- Run as proper user
- Check DDEV is running: `ddev status`
- Reset permissions manually: `ddev exec chown -R www-data:www-data .`

### File Extraction Fails

**Symptom:**
```
ERROR: Failed to extract files from backup
```

**Solution:**
- Verify backup file exists and is readable
- Check disk space: `df -h`
- Verify tar.gz integrity: `tar -tzf backup.tar.gz | head`
- Try manual extraction: `tar -xzf backup.tar.gz`

### Cache Clear Fails

**Symptom:**
```
WARNING: Failed to clear caches
```

**Solution:**
- Check Drush is available: `ddev drush status`
- Clear manually: `ddev drush cr`
- Verify database connection
- Check site status: `ddev drush status`

## Notes

- **Atomic operations** - Restore validates backup integrity before starting
- **Safe interruption** - Can be interrupted with Ctrl+C safely (use resume with `-s`)
- **Backup preservation** - Original backups are never modified during restore
- **Cross-site compatibility** - Can restore between different site names
- **Login links** - Use `-o` flag to automatically generate one-time login link
- **Automation** - Combine flags for scripted operations: `-bfyo`

## Related Commands

- [backup](./backup.md) - Create site backups
- [copy](./copy.md) - Copy sites (alternative to cross-site restore)
- [rollback](./rollback.md) - Rollback deployments
- [dev2stg](./dev2stg.md) - Deploy with automatic backup

## See Also

- [Backup Implementation](../../reference/backup-implementation.md) - Backup/restore technical details
- [Disaster Recovery](../../deployment/disaster-recovery.md) - Recovery procedures and RTO
- [Rollback Procedures](../../deployment/rollback-procedures.md) - Deployment rollback workflows
- [Production Deployment](../../deployment/production-deployment.md) - Production restore procedures
