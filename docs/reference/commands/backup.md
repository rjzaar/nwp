# backup

**Status:** ACTIVE
**Last Updated:** 2026-01-14

Create backups of Drupal sites including database and files with flexible backup strategies.

## Synopsis

```bash
pl backup [OPTIONS] <sitename> [message]
```

## Description

The `backup` command creates comprehensive backups of DDEV-managed Drupal sites. It supports both full backups (database + files) and database-only backups, with optional git integration for version control and GDPR-compliant sanitization.

Backups are stored in timestamped files with contextual metadata (git branch, commit hash, and optional message) for easy identification and restore operations.

## Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `sitename` | Yes | Name of the DDEV site to backup (e.g., `avc`, `nwp`) |
| `message` | No | Optional description of the backup (spaces converted to underscores) |

## Options

| Option | Description | Default |
|--------|-------------|---------|
| `-h, --help` | Show help message | - |
| `-d, --debug` | Enable debug output for troubleshooting | false |
| `-b, --db-only` | Create database-only backup (skip files) | false (full backup) |
| `-g, --git` | Create supplementary git backup | false |
| `--bundle` | Create git bundle for offline/archival backup | false |
| `--incremental` | Create incremental bundle (use with `--bundle`) | false |
| `--push-all` | Push to all configured git remotes (with `-g`) | false |
| `-e, --endpoint=NAME` | Backup to different endpoint directory | sitename |
| `--sanitize` | Sanitize database backup (remove PII) | false |
| `--sanitize-level=LEVEL` | Sanitization level: `basic`, `full` | basic |

## Backup Types

### Full Backup (Default)

Creates both database and files backups:
- **Database** - Complete SQL dump of the site database
- **Files** - Compressed archive of the webroot directory

```bash
pl backup avc
```

Output:
- `sitebackups/avc/20260114T143022-main-a1b2c3d4.sql`
- `sitebackups/avc/20260114T143022-main-a1b2c3d4.tar.gz`

### Database-Only Backup

Faster backup containing only the database (useful for quick snapshots before updates):

```bash
pl backup -b avc
```

Output:
- `sitebackups/avc/20260114T143022-main-a1b2c3d4.sql`

**When to use:**
- Before database schema changes
- Before module updates
- Before configuration imports
- Quick daily backups
- When files haven't changed

### Sanitized Backup (GDPR-Compliant)

Creates backup with personally identifiable information (PII) removed:

```bash
pl backup --sanitize avc
pl backup --sanitize --sanitize-level=full avc
```

**Sanitization levels:**
- **basic** - Removes user emails, passwords, session data
- **full** - Removes all PII including names, comments, logs

**Use cases:**
- Sharing backups with developers
- Creating development datasets
- GDPR compliance requirements
- Public documentation/training

## Examples

### Basic Backups

```bash
# Full backup of 'avc' site
pl backup avc

# Database-only backup
pl backup -b avc

# Backup with descriptive message
pl backup avc "Before security update"
pl backup -b avc "After content migration"
```

### Combined Flags

```bash
# Database-only backup with debug output
pl backup -bd avc

# Database-only backup with message
pl backup -b avc "Pre-deployment snapshot"
```

### Git Integration

```bash
# Create git backup (commits changes)
pl backup -g avc

# Create git bundle (offline backup)
pl backup --bundle avc

# Create incremental bundle (only new commits since last bundle)
pl backup --bundle --incremental avc

# Push to all configured remotes
pl backup -g --push-all avc
```

### Custom Endpoints

```bash
# Backup to different endpoint directory
pl backup -e=avc_archive avc "Monthly archive"

# Useful for organizing backups by purpose
pl backup -e=pre_migration avc "Before D7 to D10 migration"
```

### Sanitized Backups

```bash
# Basic sanitization (remove sensitive PII)
pl backup --sanitize avc

# Full sanitization (remove all PII)
pl backup --sanitize --sanitize-level=full avc "Dev dataset"
```

## Backup Naming Convention

Backups use a standardized naming format for easy identification:

```
YYYYMMDDTHHmmss-branch-commit-message.{sql,tar.gz}
```

**Components:**
- **Timestamp** - ISO 8601 format: `20260114T143022`
- **Git branch** - Current branch name: `main`, `develop`, `feature-xyz`
- **Commit hash** - Short git commit: `a1b2c3d4`
- **Message** - User-provided description (optional): `before_update`
- **Extension** - File type: `.sql` (database), `.tar.gz` (files)

**Examples:**
```
20260114T143022-main-a1b2c3d4.sql
20260114T143022-main-a1b2c3d4-before_security_update.sql
20260114T143022-develop-f5e6d7c8-after_migration.tar.gz
```

## Backup Storage

Backups are stored in the `sitebackups/` directory:

```
nwp/
└── sitebackups/
    ├── avc/
    │   ├── 20260114T143022-main-a1b2c3d4.sql
    │   ├── 20260114T143022-main-a1b2c3d4.tar.gz
    │   ├── 20260113T092015-main-b2c3d4e5.sql
    │   └── ...
    ├── nwp/
    │   └── ...
    └── custom_endpoint/
        └── ...
```

### Backup Rotation

Backups are automatically rotated to prevent disk space issues:
- **Keep count** - Configurable number of backups to retain
- **Age-based** - Remove backups older than specified days
- **Size-based** - Remove oldest when total size exceeds limit

Configure in `nwp.yml`:
```yaml
settings:
  backup:
    retention_days: 30
    max_backups: 10
```

## Output

Typical backup output:

```
═══════════════════════════════════════════════════════════════
  Backup: avc
═══════════════════════════════════════════════════════════════

Detecting site state...
✓ Site running: avc (https://avc.ddev.site)

Creating database backup...
✓ Database exported: 245 MB

Creating files backup...
✓ Files archived: 1.2 GB

═══════════════════════════════════════════════════════════════
  Backup Complete
═══════════════════════════════════════════════════════════════

Location: sitebackups/avc/
Files:
  - 20260114T143022-main-a1b2c3d4.sql (245 MB)
  - 20260114T143022-main-a1b2c3d4.tar.gz (1.2 GB)
```

Database-only output:

```
═══════════════════════════════════════════════════════════════
  Backup: avc (database only)
═══════════════════════════════════════════════════════════════

Detecting site state...
✓ Site running: avc

Creating database backup...
✓ Database exported: 245 MB

═══════════════════════════════════════════════════════════════
  Backup Complete
═══════════════════════════════════════════════════════════════

Location: sitebackups/avc/20260114T143022-main-a1b2c3d4.sql
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Backup successful |
| 1 | Backup failed |
| 2 | Missing required sitename argument |
| 3 | Site not found or not running |
| 4 | Insufficient disk space |

## Prerequisites

- **DDEV** - Site must be running under DDEV
- **Site exists** - Target site must be installed
- **Disk space** - Sufficient space in `sitebackups/` directory
- **Drush** - For Drupal database exports

## Best Practices

### When to Create Backups

**Always backup before:**
- Security updates
- Major module updates
- Database schema changes
- Configuration imports
- Content migrations
- Production deployments

**Regular schedule:**
- Daily: Database-only backups
- Weekly: Full backups
- Monthly: Archived backups with `--bundle`

### Backup Strategies

**Development workflow:**
```bash
# Quick checkpoint before risky changes
pl backup -b avc "Before trying new approach"

# Full backup before major updates
pl backup avc "Before Drupal 11 upgrade"

# Git-integrated backup for version control
pl backup -g avc "Stable checkpoint"
```

**Production workflow:**
```bash
# Automated daily backups
0 2 * * * /path/to/nwp/pl backup -b production-site

# Weekly full backups
0 3 * * 0 /path/to/nwp/pl backup production-site "Weekly backup"

# Pre-deployment backup
pl backup --sanitize production-site "Before deployment"
```

## Troubleshooting

### Backup Fails - Disk Space

**Symptom:**
```
ERROR: Insufficient disk space
```

**Solution:**
- Check available space: `df -h`
- Remove old backups: `rm sitebackups/avc/old-backup-*`
- Increase disk quota
- Use database-only backups: `pl backup -b avc`

### Site Not Running

**Symptom:**
```
ERROR: Site 'avc' is not running
```

**Solution:**
- Start DDEV: `ddev start`
- Check site exists: `pl status avc`
- Verify site directory: `ls sites/avc/`

### Permission Denied

**Symptom:**
```
ERROR: Permission denied writing to sitebackups/
```

**Solution:**
- Check directory permissions: `ls -la sitebackups/`
- Fix permissions: `chmod 755 sitebackups/`
- Check disk quotas: `quota -s`

### Database Export Fails

**Symptom:**
```
ERROR: drush sql-dump failed
```

**Solution:**
- Verify Drush is available: `ddev drush status`
- Check database connection: `ddev mysql`
- Review Drush logs
- Try manual export: `ddev drush sql-dump > test.sql`

## Notes

- **Atomic operations** - Backups are created atomically to prevent corruption
- **Safe interruption** - Can be interrupted with Ctrl+C safely
- **Concurrent backups** - Can run multiple backup operations simultaneously
- **Compression** - Files are compressed with gzip for efficiency
- **Git metadata** - Automatically includes git branch and commit information
- **Message sanitization** - Messages are sanitized (spaces → underscores, special chars removed)

## Related Commands

- [restore](./restore.md) - Restore from backups
- [copy](./copy.md) - Copy sites (uses backup mechanism internally)
- [dev2stg](./dev2stg.md) - Deploy to staging (creates automatic backup)
- [rollback](./rollback.md) - Rollback deployments using backups

## See Also

- [Backup Implementation](../../reference/backup-implementation.md) - Technical implementation details
- [Disaster Recovery](../../deployment/disaster-recovery.md) - Recovery procedures
- [Data Security Best Practices](../../security/data-security-best-practices.md) - Backup security and GDPR compliance
- [Production Deployment](../../deployment/production-deployment.md) - Production backup strategies
