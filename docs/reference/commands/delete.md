# delete

**Status:** ACTIVE
**Last Updated:** 2026-01-14

Safely delete DDEV sites with optional backup creation and confirmation prompts.

## Synopsis

```bash
pl delete [OPTIONS] <sitename>
```

## Description

The `delete` command removes DDEV sites including containers, files, and optionally backups. Includes safety confirmations and supports automatic backup before deletion.

## Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `sitename` | Yes | Name of the DDEV site to delete |

## Options

| Option | Description | Default |
|--------|-------------|---------|
| `-h, --help` | Show help message | - |
| `-d, --debug` | Enable debug output | false |
| `-y, --yes` | Skip all confirmation prompts | false |
| `-b, --backup` | Create backup before deletion | false |
| `-k, --keep-backups` | Keep existing backups | prompt or true with `-y` |
| `-f, --force` | Force deletion (bypass validation) | false |
| `--keep-yml` | Keep site entry in cnwp.yml | false (removes entry) |

## Deletion Process

1. Validate site exists
2. Create backup (if `-b` used)
3. Stop DDEV containers
4. Delete DDEV project
5. Remove site directory
6. Handle backups (delete or keep)
7. Remove from cnwp.yml (unless `--keep-yml`)
8. Display summary

## Examples

```bash
# Delete with confirmation
pl delete old-site

# Delete with auto-confirm
pl delete -y test-site

# Backup before deletion
pl delete -b production-site

# Backup + auto-confirm
pl delete -by test-site

# Backup + keep backups + auto-confirm
pl delete -bky archive-site

# Force deletion (bypass checks)
pl delete -f broken-site
```

## Safety Features

### Confirmation Prompts

Without `-y`, prompts for:
- Deletion confirmation
- Backup deletion (if backups exist)

With `-y`:
- Auto-confirms deletion
- Keeps backups by default (safer)

With `-k`:
- Always keeps backups

### Purpose Protection

Sites with `purpose: permanent` in `cnwp.yml` require:
1. Manual purpose change in `cnwp.yml` first
2. Or use `-f` flag to force (not recommended)

## Output

```
═══════════════════════════════════════════════════════════════
  Delete: test-site
═══════════════════════════════════════════════════════════════

WARNING: This will permanently delete 'test-site'
Continue? [y/N]: y

[1/7] Validate site exists
✓ Site found: test-site

[2/7] Create backup
✓ Backup created: sitebackups/test-site/20260114T143022.sql

[3/7] Stop DDEV containers
✓ DDEV stopped

[4/7] Delete DDEV project
✓ DDEV project deleted

[5/7] Remove site directory
✓ Directory removed: sites/test-site/

[6/7] Handle backups
Keep backups? [Y/n]: y
✓ Backups preserved: sitebackups/test-site/

[7/7] Display summary
✓ Deletion complete

═══════════════════════════════════════════════════════════════
  Site Deleted
═══════════════════════════════════════════════════════════════

Deleted: sites/test-site/
Backups: sitebackups/test-site/ (preserved)
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Deletion successful |
| 1 | Deletion failed |
| 2 | Missing sitename argument |
| 3 | Site not found |
| 4 | User cancelled operation |
| 5 | Permanent site (requires purpose change) |

## See Also

- [backup](./backup.md) - Create backups
- [install](./install.md) - Install new sites
- [copy](./copy.md) - Clone sites
- [status](./status.md) - Check site status
