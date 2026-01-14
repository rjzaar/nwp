# migrate-secrets

**Last Updated:** 2026-01-14

Migrate existing `.secrets.yml` files to NWP's two-tier secrets architecture.

## Synopsis

```bash
pl migrate-secrets [options]
```

## Description

The `migrate-secrets` command helps migrate existing NWP installations to the two-tier secrets architecture introduced in NWP v0.13. This architecture separates infrastructure secrets (safe for AI assistants) from data secrets (blocked from AI access).

The command scans `.secrets.yml` files for production credentials that should be moved to `.secrets.data.yml`, creates backups, and provides step-by-step migration guidance.

This is part of NWP's security model to protect production data while allowing AI assistants to help with infrastructure automation.

## Arguments

None. All configuration is through options.

## Options

| Option | Description |
|--------|-------------|
| `--dry-run` | Show what would be done without making changes |
| `--nwp` | Migrate NWP root `.secrets.yml` |
| `--site NAME` | Migrate a specific site's secrets |
| `--all` | Migrate NWP and all sites |
| `--check` | Check all secrets files for data leakage |
| `--help, -h` | Show help message |

## Two-Tier Architecture

### .secrets.yml (Infrastructure Secrets)

**Safe for AI assistants to read**

Contents:
- Linode API token (cloud infrastructure)
- Cloudflare API token (DNS automation)
- GitLab deploy token (repository access)
- Development database passwords
- Staging credentials
- API tokens for non-production services

**Why Safe:**
- No access to user data
- Can't access production databases
- Can't SSH to production servers
- Only automate infrastructure

### .secrets.data.yml (Data Secrets)

**Blocked from AI assistants**

Contents:
- Production database passwords
- Production SSH keys and credentials
- Production SMTP credentials
- GitLab admin password and SSH key
- Encryption keys
- Production API keys (Stripe, payment gateways, etc.)

**Why Blocked:**
- Direct access to user data
- Can read/modify production databases
- Can access production servers
- Real customer information

## Data Secret Patterns

The script identifies these patterns as data secrets:

| Pattern | Examples | Why Data Secret |
|---------|----------|-----------------|
| `admin_password` | GitLab admin, DB root | Administrative access |
| `root_password` | Database root user | Full database access |
| `backup_password` | Backup encryption | Access to data backups |
| `ssh_key.*prod` | Production SSH keys | Server access |
| `production_*` | Any production credential | Production environment |
| `stripe_secret` | Payment API keys | Financial data |
| `encryption` | Encryption keys | Decrypt user data |
| `gitlab.*admin` | GitLab admin credentials | Full GitLab access |

## Examples

### Check for Data Secrets

```bash
pl migrate-secrets --check
```

Scans all `.secrets.yml` files and reports data secrets:

```
[INFO] Checking for data secrets in .secrets.yml files...

[INFO] Checking: /home/rob/nwp/.secrets.yml
[WARN]   Line 12: admin_password: "secretpass123"
[WARN]   Line 18: ssh_key: ~/.ssh/prod_key
[OK]   No data secrets found

[INFO] Checking: /home/rob/nwp/sites/avc/.secrets.yml
[WARN]   Line 8: production_database.password: "dbpass456"
[OK]   No data secrets found

[INFO] Check complete. Review any warnings above.
[INFO] Data secrets should be moved to .secrets.data.yml
```

### Dry Run Migration (NWP Root)

```bash
pl migrate-secrets --dry-run --nwp
```

Shows what would be migrated without making changes:

```
============================================
  NWP Secrets Migration Tool
============================================

[INFO] Running in DRY RUN mode - no changes will be made

[INFO] Migrating NWP root secrets...
[INFO] [DRY RUN] Would analyze: /home/rob/nwp/.secrets.yml
[INFO] Checking: /home/rob/nwp/.secrets.yml
[WARN]   Line 12: admin_password: "secretpass123"
[WARN]   Line 18: ssh_key: ~/.ssh/prod_key
```

### Migrate NWP Root Secrets

```bash
pl migrate-secrets --nwp
```

Migrates the main `.secrets.yml`:

```
============================================
  NWP Secrets Migration Tool
============================================

[INFO] Migrating NWP root secrets...
[OK] Created backup of .secrets.yml
[OK] Created .secrets.data.yml from template

[INFO]
[INFO] MANUAL STEPS REQUIRED:
[INFO] 1. Review /home/rob/nwp/.secrets.yml for data secrets
[INFO] 2. Move the following to /home/rob/nwp/.secrets.data.yml:
[INFO]    - gitlab.admin.password
[INFO]    - gitlab.server.ssh_key (if for prod access)
[INFO]    - Any production database passwords
[INFO]    - Any production SSH credentials
[INFO] 3. Remove moved values from /home/rob/nwp/.secrets.yml
[INFO] 4. Run: ./migrate-secrets.sh --check

[INFO] Checking: /home/rob/nwp/.secrets.yml
[WARN]   Line 12: admin_password: "secretpass123"
```

### Migrate Specific Site

```bash
pl migrate-secrets --site avc
```

Migrates a site's secrets:

```
[INFO] Migrating site: avc
[OK] Created backup of avc/.secrets.yml
[OK] Created avc/.secrets.data.yml from template

[INFO]
[INFO] MANUAL STEPS for avc:
[INFO] 1. Move production credentials to .secrets.data.yml
[INFO] 2. Keep only dev/staging credentials in .secrets.yml

[INFO] Checking: /home/rob/nwp/sites/avc/.secrets.yml
[WARN]   Line 8: production_database.password: "dbpass456"
```

### Migrate All Secrets

```bash
pl migrate-secrets --all
```

Migrates NWP root and all site secrets:

```
[INFO] Migrating all secrets files...

[INFO] Migrating NWP root secrets...
[OK] Created backup of .secrets.yml
[OK] Created .secrets.data.yml from template

[INFO] Migrating site: avc
[OK] Created backup of avc/.secrets.yml
[OK] Created avc/.secrets.data.yml from template

[INFO] Migrating site: nwp5
[WARN] No .secrets.yml found for site nwp5
```

## Migration Process

### Automatic Steps

1. **Create backup**: `.secrets.yml.bak.YYYYMMDD_HHMMSS`
2. **Create template**: `.secrets.data.yml` from `.secrets.data.example.yml`
3. **Scan for data secrets**: Report potential data secrets
4. **Log actions**: Record in installation log

### Manual Steps (Required)

1. **Review `.secrets.yml`**: Identify data secrets
2. **Move to `.secrets.data.yml`**: Copy production credentials
3. **Remove from `.secrets.yml`**: Delete moved values
4. **Verify**: Run `pl migrate-secrets --check`
5. **Update Claude config**: Ensure `.secrets.data.yml` is denied

## Template Files

### .secrets.data.example.yml

Located at project root, provides template structure:

```yaml
# NWP Data Secrets - BLOCKED from AI assistants
# Contains production database, SSH, SMTP credentials

production_database:
  host: ""
  port: 3306
  username: ""
  password: ""
  database: ""

production_ssh:
  user: ""
  key_path: ""
  host: ""
  port: 22

production_smtp:
  host: ""
  port: 587
  username: ""
  password: ""
  encryption: tls

gitlab:
  admin:
    username: ""
    password: ""
    ssh_key: ""

# Add other production/sensitive credentials below
```

## Claude Code Configuration

After migration, ensure Claude Code is restricted from `.secrets.data.yml`:

### ~/.claude/settings.json

```json
{
  "permissions": {
    "deny": [
      "**/.secrets.data.yml",
      "**/keys/prod_*",
      "~/.ssh/*",
      "**/*.sql",
      "**/settings.php"
    ]
  }
}
```

This is automatically configured by `pl setup` when selecting "Claude Code Security Config".

## Backup Files

Backups are created with timestamps:

```
/home/rob/nwp/
  ├── .secrets.yml
  ├── .secrets.yml.bak.20260114_103045  # Backup
  ├── .secrets.data.yml                 # New file
  └── .secrets.data.example.yml         # Template
```

Backups are **not gitignored** intentionally - they contain the same secrets as the original and serve as recovery points.

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success or check complete |
| 1 | Error (site not found, template missing) |

## Prerequisites

- `.secrets.yml` file exists
- `.secrets.data.example.yml` template exists (for NWP root)
- Write permissions to create `.secrets.data.yml`

## Security Model

### Safe Operations (Infrastructure)

Using `lib/secrets.sh`:

```bash
source lib/secrets.sh

# Safe: AI can help with these
token=$(get_infra_secret "linode.api_token" "")
cf_token=$(get_infra_secret "cloudflare.api_token" "")
```

### Blocked Operations (Data)

```bash
# Blocked: AI cannot access these
db_pass=$(get_data_secret "production_database.password" "")
ssh_key=$(get_data_secret "production_ssh.key_path" "")
```

### Proxy Functions

For AI-assisted operations needing data secrets, use proxy functions that return sanitized output:

```bash
source lib/safe-ops.sh

# Returns status without credentials
safe_server_status prod1

# Returns table count without data
safe_db_status avc
```

## What Gets Moved

### Production Credentials → .secrets.data.yml

- Production database passwords
- Production SSH keys (`~/.ssh/prod_*`, `keys/prod_*`)
- Production SMTP credentials
- GitLab admin password
- GitLab server SSH key (if used for production)
- Encryption keys
- Payment gateway API keys (Stripe, PayPal)
- Any credential with "production" or "prod" in the name

### Development Credentials → .secrets.yml (Keep)

- Linode API token (infrastructure automation)
- Cloudflare API token (DNS automation)
- GitLab deploy token (read-only repo access)
- Development database passwords
- Staging credentials
- Test API keys
- Non-production service tokens

## Notes

- **Idempotent**: Safe to run multiple times
- **Non-destructive**: Creates backups before changes
- **Manual completion**: Requires manual steps to complete migration
- **Check before migrate**: Use `--check` first to see what will be flagged
- **Dry run recommended**: Use `--dry-run` before actual migration
- **Template required**: NWP root migration needs `.secrets.data.example.yml`

## Troubleshooting

### Template Not Found

**Symptom:** "No .secrets.data.example.yml template found"

**Solution:**
1. Create template manually in project root
2. Or copy from another NWP installation
3. Or download from NWP repository

### No Secrets File Found

**Symptom:** "No .secrets.yml found at NWP root"

**Solution:**
1. This is OK if you don't have infrastructure secrets yet
2. Create manually: `cp .secrets.example.yml .secrets.yml`
3. Add your secrets, then migrate

### Site Not Found

**Symptom:** "Site directory not found"

**Solution:**
1. Check site name: `pl modify --list`
2. Verify directory exists: `ls sites/`
3. Use correct site slug (not full path)

### Migration Shows No Data Secrets

**Symptom:** Check shows "No data secrets found" but you know they exist

**Solution:**
1. Pattern may not match - review file manually
2. Add custom patterns if needed
3. Manually move any production credentials
4. Re-run `--check` to verify

### Can't Access .secrets.data.yml After Migration

**Symptom:** Scripts fail to read `.secrets.data.yml`

**Solution:**
1. Check file permissions: `ls -la .secrets.data.yml`
2. Should be 600: `chmod 600 .secrets.data.yml`
3. Check ownership: `chown $USER:$USER .secrets.data.yml`

## Related Commands

- [setup.md](./setup.md) - Configure Claude Code security
- [security.md](./security.md) - Security checking and updates

## See Also

- [Data Security Best Practices](../../security/data-security-best-practices.md) - Complete security architecture
- [Secrets Architecture](../../decisions/0001-two-tier-secrets.md) - ADR for two-tier design
- [Safe Operations Guide](../../security/safe-operations.md) - Using proxy functions
- [CLAUDE.md](../../../CLAUDE.md) - AI assistant security restrictions
