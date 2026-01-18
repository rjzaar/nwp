# sync

**Last Updated:** 2026-01-14

Re-sync an imported site with its remote source server.

## Synopsis

```bash
pl sync <sitename> [options]
```

## Description

The `sync` command pulls fresh database and/or files from a remote server to your local development environment. It's designed for sites that were originally imported using `pl import` and maintains configuration of the source server in `nwp.yml`.

Common use cases:
- Pull latest production data for local development
- Sync staging environment with production
- Refresh local database with recent content
- Update custom code from remote server

The command handles database export, transfer, import, and sanitization automatically. It can sync database only, files only, or both.

## Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `sitename` | Yes | Site slug from nwp.yml |

## Options

| Option | Description |
|--------|-------------|
| `--db-only` | Only sync database (skip files) |
| `--files-only` | Only sync files (skip database) |
| `--no-sanitize` | Skip database sanitization |
| `--backup` | Create backup before syncing |
| `--yes, -y` | Auto-confirm prompts |
| `--help, -h` | Show help message |

## Examples

### Full Sync (Database + Files)

```bash
pl sync avc
```

Syncs both database and files from configured source server.

### Database Only

```bash
pl sync avc --db-only
```

Pulls fresh database dump without touching files.

### Files Only

```bash
pl sync avc --files-only
```

Syncs custom code and configuration without changing database.

### Skip Sanitization

```bash
pl sync avc --no-sanitize
```

Imports database without sanitizing emails/passwords (use cautiously).

### With Backup

```bash
pl sync avc --backup
```

Creates full backup before syncing (recommended for production-like data).

### Auto-Confirm

```bash
pl sync avc --yes
```

Skips all confirmation prompts.

### Database Only with Backup

```bash
pl sync avc --db-only --backup --yes
```

Combines multiple options: backup, database-only, auto-confirm.

## Source Configuration

The sync command reads source server configuration from `nwp.yml`:

```yaml
sites:
  avc:
    directory: /home/rob/nwp/sites/avc
    type: import
    source:
      server: prod1          # Server reference (or "custom")
      ssh_host: 192.0.2.10  # Direct SSH host (if server: custom)
      webroot: /var/www/html/web
```

### Using Named Server

```yaml
linode:
  servers:
    prod1:
      ssh_user: deploy
      ssh_host: 192.0.2.10
      ssh_port: 22
      ssh_key: ~/.ssh/nwp

sites:
  avc:
    source:
      server: prod1  # References server above
      webroot: /var/www/html/web
```

### Using Custom Server

```yaml
sites:
  avc:
    source:
      server: custom
      ssh_host: example.com
      webroot: /var/www/drupal/web
```

Uses `~/.ssh/nwp` as SSH key by default.

## Sync Process

### 1. Connection Test

```
[i] Testing connection...
[✓] Connected
```

Verifies SSH connectivity before proceeding.

### 2. Database Sync

```
[i] Syncing database...
Exporting database from remote...
[✓] Database pulled: 45M

[i] Importing database...
[✓] Database imported

[i] Sanitizing database...
[✓] Database sanitized

[✓] Database sync complete (32s)
```

Steps:
1. SSH to remote server
2. Run `drush sql:dump --gzip`
3. Transfer compressed dump
4. Import to local DDEV database
5. Sanitize (unless `--no-sanitize`)

### 3. File Sync

```
[i] Syncing files...
receiving incremental file list
composer.json
composer.lock
config/sync/core.extension.yml
web/modules/custom/mymodule/mymodule.info.yml
web/themes/custom/mytheme/mytheme.theme

sent 1.2K bytes  received 45K bytes  30.8K bytes/sec
total size is 12M  speedup is 259.43

[✓] Files synced (8s)

[i] Updating dependencies...
Loading composer repositories with package information
Installing dependencies from lock file
```

Files synced:
- `composer.json`, `composer.lock`
- `config/` directory (configuration)
- Custom modules (`web/modules/custom/`)
- Custom themes (`web/themes/custom/`)

Files excluded:
- User files (`web/sites/default/files/`)
- `vendor/` (regenerated via composer)
- `node_modules/`
- `.git/`

### 4. Cache Clear

```
[i] Clearing caches...
[✓] Caches cleared
```

Runs `drush cache:rebuild` to ensure clean state.

### 5. Update Timestamp

Updates `last_sync` field in `nwp.yml`:

```yaml
sites:
  avc:
    last_sync: "2026-01-14T15:30:00Z"
```

## Database Sanitization

By default, the sync sanitizes the database to protect production data:

### What Gets Sanitized

| Data | Action |
|------|--------|
| User emails | Randomized: `user123@example.com` |
| User passwords | Randomized hashes |
| Session data | Cleared |
| Watchdog logs | Optionally truncated |

### Drush sql:sanitize

```bash
ddev drush sql:sanitize -y
```

This makes the database safe for local development without exposing real user data.

### Skip Sanitization

Use `--no-sanitize` when:
- Testing exact production state
- Need real email addresses for testing
- Debugging email-related issues

**Warning**: Be careful with unsanitized production data - contains PII.

## File Sync Details

### rsync Command

```bash
rsync -avz \
  -e "ssh -i ~/.ssh/nwp -o StrictHostKeyChecking=accept-new" \
  --include="composer.json" \
  --include="composer.lock" \
  --include="config/***" \
  --include="web/modules/custom/***" \
  --include="web/themes/custom/***" \
  --include="*/" \
  --exclude="web/sites/default/files/*" \
  --exclude="vendor" \
  --exclude="node_modules" \
  --exclude=".git" \
  --prune-empty-dirs \
  user@server:/var/www/html/ \
  /home/rob/nwp/sites/avc/
```

### What Gets Synced

- **Configuration**: Drupal config YAML files
- **Custom code**: Modules and themes you developed
- **Dependencies**: composer.json for reproducible builds

### What Gets Excluded

- **User files**: Too large, use Stage File Proxy instead
- **Vendor**: Rebuilt via `composer install`
- **Git**: Avoid mixing repositories
- **Build artifacts**: Regenerated locally

### After File Sync

Automatically runs:

```bash
ddev composer install --no-interaction
```

Updates `vendor/` based on synced `composer.lock`.

## Backup Creation

With `--backup` flag:

```bash
[i] Creating backup...
[✓] Backup created
```

Calls `pl backup sitename` before syncing.

Backup includes:
- Database dump
- Configuration files
- Custom code

Stored in: `backups/sitename/YYYY-MM-DD_HH-MM-SS/`

## Output

### Confirmation Prompt

```
This will sync avc from example.com
Mode: Full sync (database + files)
Sanitization: Enabled

Continue? (Y/n)
```

### Complete Sync Output

```
═══════════════════════════════════════════════════════════════
  Syncing: avc
═══════════════════════════════════════════════════════════════

[i] Source: example.com:/var/www/html/web
[i] Local:  /home/rob/nwp/sites/avc

[i] Testing connection...
[✓] Connected

[i] Syncing database...
[✓] Database pulled: 45M
[✓] Database imported
[✓] Database sanitized
[✓] Database sync complete (32s)

[i] Syncing files...
[✓] Files synced (8s)
[i] Updating dependencies...

[i] Clearing caches...
[✓] Caches cleared

[✓] Sync complete for avc

Next steps:
  cd avc && ddev launch
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success or user cancelled |
| 1 | Error (site not found, connection failed, import failed) |

## Prerequisites

- Site exists and is configured as `type: import` in nwp.yml
- Source server configuration in nwp.yml
- SSH access to remote server
- SSH key configured (~/.ssh/nwp by default)
- DDEV installed and configured
- Drush available on remote server

## Performance

### Database Sync Time

Depends on:
- Database size
- Network speed
- Compression effectiveness

Typical times:
- 10MB database: 5-10 seconds
- 100MB database: 30-60 seconds
- 1GB database: 5-10 minutes

### File Sync Time

Depends on:
- Number of files changed
- rsync efficiency (incremental)
- Network speed

First sync is slower (downloads everything). Subsequent syncs are much faster (only changed files).

## Security

### SSH Key Authentication

Uses key-based authentication (no passwords):

```bash
ssh -i ~/.ssh/nwp user@server
```

### Host Key Checking

On first connection:

```bash
-o StrictHostKeyChecking=accept-new
```

Accepts new host keys but warns on changes.

### Database Sanitization

Protects production data:
- Randomizes user emails
- Randomizes passwords
- Clears sessions

Prevents accidental:
- Email sends to real users
- Login with production credentials
- Session hijacking

## Notes

- **Imported sites only**: Only works with sites configured as `type: import`
- **Incremental sync**: File sync is incremental (only changed files)
- **Idempotent**: Safe to run multiple times
- **DDEV auto-start**: Starts DDEV if not running
- **Composer update**: Runs `composer install` after file sync
- **Timestamp tracking**: Updates `last_sync` in nwp.yml
- **Stage File Proxy**: Consider using for user files instead of syncing

## Troubleshooting

### Site Not Found

**Symptom:** "Site not found or not an imported site"

**Solution:**
1. Check site exists: `pl modify --list`
2. Verify `type: import` in nwp.yml:
   ```yaml
   sites:
     avc:
       type: import
   ```
3. Add source configuration if missing

### Connection Failed

**Symptom:** "Cannot connect to example.com"

**Solution:**
1. Test manual SSH: `ssh -i ~/.ssh/nwp user@server`
2. Check SSH key permissions: `chmod 600 ~/.ssh/nwp`
3. Verify host is reachable: `ping server`
4. Check firewall allows SSH (port 22)

### Database Import Failed

**Symptom:** "Failed to import database"

**Solution:**
1. Check DDEV is running: `ddev describe`
2. Verify disk space: `df -h`
3. Check database dump: `gunzip -t db.sql.gz`
4. Try manual import:
   ```bash
   cd sites/sitename
   gunzip < db.sql.gz | ddev mysql
   ```

### File Sync Failed

**Symptom:** "File sync failed"

**Solution:**
1. Check SSH connectivity
2. Verify remote path exists
3. Check disk space locally: `df -h`
4. Try manual rsync:
   ```bash
   rsync -avz -e "ssh -i ~/.ssh/nwp" \
     user@server:/path/to/files/ \
     sites/sitename/
   ```

### Sanitization Failed

**Symptom:** "Sanitization had issues"

**Solution:**
1. This is often non-fatal
2. Check warnings: Review output
3. Skip if needed: `--no-sanitize`
4. Manually sanitize:
   ```bash
   cd sites/sitename
   ddev drush sql:sanitize -y
   ```

### Composer Install Fails

**Symptom:** Errors during dependency update

**Solution:**
1. Check composer.lock was synced
2. Verify PHP version matches: `ddev php -v`
3. Try manually:
   ```bash
   cd sites/sitename
   ddev composer install
   ```
4. Check for platform requirements

## Related Commands

- [import.sh](../scripts/import.sh) - Initial site import
- [backup.md](./backup.md) - Create backups
- [modify.md](./modify.md) - Modify site options

## See Also

- [Import Guide](../../guides/import-guide.md) - Importing remote sites
- [Stage File Proxy](https://www.drupal.org/project/stage_file_proxy) - Proxy user files instead of syncing
- [Drush sql:sanitize](https://www.drush.org/latest/commands/sql_sanitize/) - Database sanitization
- [rsync Documentation](https://rsync.samba.org/documentation.html) - File synchronization
