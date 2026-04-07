# copy

**Status:** ACTIVE
**Last Updated:** 2026-01-14

Copy or clone Drupal sites with full or files-only modes for creating duplicates and test environments.

## Synopsis

```bash
pl copy [OPTIONS] <from_site> <to_site>
```

## Description

The `copy` command creates a complete duplicate of an existing site, including files, database, and DDEV configuration. Supports files-only mode to preserve the destination database while updating codebase.

## Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `from_site` | Yes | Source site to copy from |
| `to_site` | Yes | Destination site name |

## Options

| Option | Description | Default |
|--------|-------------|---------|
| `-h, --help` | Show help message | - |
| `-d, --debug` | Enable debug output | false |
| `-f, --files-only` | Copy files only (skip database) | false (full copy) |
| `-y, --yes` | Skip confirmation prompts | false |
| `-o, --open` | Generate login link after copy | false |

## Copy Modes

### Full Copy (Default)

Creates complete clone with database and files:
1. Validate source site
2. Prepare destination directory
3. Copy all files
4. Export source database
5. Configure DDEV for destination
6. Import database
7. Fix settings
8. Set permissions
9. Clear cache
10. Generate login link (with `-o`)

```bash
pl copy nwp nwp-backup
```

### Files-Only Copy

Updates codebase while preserving destination database:
1. Validate source and destination exist
2. Copy all files
3. Fix settings
4. Set permissions

```bash
pl copy -f nwp nwp-test
```

**Use cases:**
- Update codebase without affecting data
- Deploy code changes to existing site
- Test code with different database

## Examples

```bash
# Full copy (files + database)
pl copy nwp nwp-backup

# Files-only copy
pl copy -f nwp nwp-test

# Full copy with auto-confirm
pl copy -y nwp client-site

# Files-only with auto-confirm + login
pl copy -fyo nwp nwp-dev

# Create test environment
pl copy production-site test-site
pl copy -y avc avc-test
```

## Output

```
═══════════════════════════════════════════════════════════════
  Copy: nwp → nwp-backup
═══════════════════════════════════════════════════════════════

[1/10] Validate source
✓ Source site exists: nwp

[2/10] Prepare destination
✓ Destination ready: sites/nwp-backup/

[3/10] Copy files
✓ Files copied: 12,450 files (856 MB)

[4/10] Export database
✓ Database exported: 245 MB

[5/10] Configure DDEV
✓ DDEV configured

[6/10] Import database
✓ Database imported

[7/10] Fix settings
✓ Settings updated

[8/10] Set permissions
✓ Permissions applied

[9/10] Clear cache
✓ Cache cleared

[10/10] Generate login link
✓ Login: https://nwp-backup.ddev.site/user/reset/1/...

═══════════════════════════════════════════════════════════════
  Copy Complete
═══════════════════════════════════════════════════════════════

Site URL: https://nwp-backup.ddev.site
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Copy successful |
| 1 | Copy failed |
| 2 | Missing required arguments |
| 3 | Source site not found |
| 4 | Destination already exists (for full copy) |
| 5 | Destination doesn't exist (for files-only) |

## Troubleshooting

### Destination Already Exists

**Symptom:**
```
ERROR: Destination 'nwp-test' already exists
```

**Solution:**
- Delete existing: `pl delete nwp-test`
- Use different name: `pl copy nwp nwp-test2`
- Use files-only mode: `pl copy -f nwp nwp-test`

### Files-Only Requires Existing Destination

**Symptom:**
```
ERROR: Destination 'nwp-test' must exist for files-only copy
```

**Solution:**
- Create destination first: `pl install d nwp-test`
- Use full copy mode: `pl copy nwp nwp-test`

## See Also

- [backup](./backup.md) - Create backups
- [restore](./restore.md) - Restore from backups
- [install](./install.md) - Install new sites
- [delete](./delete.md) - Delete sites
