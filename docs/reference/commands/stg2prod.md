# stg2prod

**Last Updated:** 2026-01-14

Deploy staging site to production server via rsync.

## Synopsis

```bash
pl stg2prod [OPTIONS] <sitename>
```

## Description

The `stg2prod` command deploys a staging site to a remote Linode production server using SSH and rsync. It exports configuration from staging, syncs files to production, runs composer install, applies database updates, imports configuration, and optionally reinstalls specified modules.

This command automatically ensures the staging site is in production mode before deployment. If the staging site is in development mode, it will run `make.sh -py` to switch to production mode first.

## Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `sitename` | Yes | Base name of the staging site (e.g., `nwp` for `nwp-stg`) |

The command automatically appends `-stg` to the site name if not present.

## Options

| Option | Description | Default |
|--------|-------------|---------|
| `-h, --help` | Show help message | - |
| `-d, --debug` | Enable debug output | false |
| `-y, --yes` | Skip confirmation prompts | false |
| `-v, --verbose` | Show detailed rsync output | false |
| `-s N, --step=N` | Resume from step N (1-11) | 1 |
| `--dry-run` | Show what would be done without making changes | false |

## Examples

### Basic Deployment

```bash
pl stg2prod nwp
```

Deploys `nwp-stg` to production server configured in `nwp.yml`.

### Auto-Confirm Deployment

```bash
pl stg2prod -y nwp
```

Deploy without confirmation prompts.

### Dry Run

```bash
pl stg2prod --dry-run nwp
```

Preview deployment without making changes.

### Resume from Step

```bash
pl stg2prod -s 5 nwp
```

Resume deployment from step 5 (useful if a previous deployment failed).

### Verbose Output

```bash
pl stg2prod -v nwp
```

Show detailed rsync file transfer output.

## Output

The command displays progress for each step with status indicators:

```
[OK] Staging site exists: /home/rob/nwp/sites/nwp-stg
[OK] Deployment method: rsync
[OK] Server: prod1 (root@192.0.2.10:22)
[OK] SSH key: /home/rob/.ssh/id_rsa_linode
[OK] Remote path: /var/www/nwp
[OK] Domain: example.com

WARNING: This will deploy to PRODUCTION!
Server: root@192.0.2.10
Path:   /var/www/nwp
Domain: example.com

Continue with production deployment? [y/N]: y

[OK] SSH connection to root@192.0.2.10 successful
[OK] Configuration exported from staging
[INFO] Skipping production backup (auto-yes mode)
Syncing files to production...
[OK] Files synced to production
[OK] Composer install completed on production
[OK] Database updates completed on production
[OK] Configuration imported to production
[OK] Email forwarding configured: nwp@example.com -> admin@example.com
[OK] Drupal site email correct: nwp@example.com
[OK] Module reinstalled: webform
[OK] Cache cleared on production

[OK] Production site: https://example.com
[OK] Deployment completed in 00:02:34
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Deployment successful |
| 1 | Deployment failed (validation, SSH, rsync, or drush error) |

## Configuration

Production deployment configuration is stored in `nwp.yml`:

### Recipe-level configuration
```yaml
recipes:
  nwp:
    prod_method: rsync
    prod_server: prod1
    prod_domain: example.com
    prod_path: /var/www/nwp
    reinstall_modules:
      - webform
```

### Site-level configuration (overrides recipe)
```yaml
sites:
  nwp:
    recipe: nwp
    production_config:
      method: rsync
      server: prod1
      domain: example.com
      remote_path: /var/www/nwp
```

### Linode server configuration
```yaml
linode:
  servers:
    prod1:
      ssh_user: root
      ssh_host: 192.0.2.10
      ssh_port: 22
      ssh_key: ~/keys/nwp
```

## Prerequisites

- Staging site must exist with DDEV configured
- Staging site must be in **production mode** (script will auto-switch if needed)
- SSH access to production server must be configured
- Production server must have composer and drush installed
- Production configuration must be defined in `nwp.yml`

## Production Mode Requirement

The `stg2prod` command automatically ensures the staging site is in production mode before deployment. Production mode:
- Enables CSS/JS aggregation
- Disables development modules
- Optimizes performance for production

If the staging site is in development mode, the script automatically runs `pl make -py <sitename>` to switch modes.

## Email Configuration

The script automatically:
1. Checks for email forwarding on the mail server (git.domain.org)
2. Creates forwarding aliases if configured in `settings.email.admin_email`
3. Verifies Drupal site email matches expected format (`sitename@domain.org`)
4. Updates Drupal configuration if needed

## Rsync Excludes

The following files/directories are excluded from sync:
- `.git` - Version control
- `.ddev` - Local development environment
- `*/settings.php` - Server-specific settings
- `*/settings.local.php` - Local settings
- `*/services.yml` - Service configuration
- `*/files/*` - User-uploaded files (synced separately)
- `private/*` - Private files
- `node_modules` - Node dependencies
- `.env` - Environment variables

## Notes

### File Exclusions

The following are excluded from sync:
- `.git` - Version control directory
- `.ddev` - Local development configuration
- `settings.php` - Production-specific database credentials
- `settings.local.php` - Local environment overrides
- `services.yml` - Production-specific service configuration
- `*/files/*` - User-uploaded files (persist on production)
- `private/*` - Private file directory
- `node_modules` - Frontend dependencies (rebuild on production if needed)
- `.env` - Environment variables

### SSH Key Setup

If using a custom SSH key:

```bash
# Generate key if needed
ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa_linode

# Add to production server
ssh-copy-id -i ~/.ssh/id_rsa_linode root@prod-server
```

Configure in `nwp.yml`:

```yaml
linode:
  servers:
    prod-server-1:
      ssh_key: ~/.ssh/id_rsa_linode
```

### Module Reinstallation

Some modules need to be reinstalled on deployment to clear cache or rebuild state:

```yaml
recipes:
  mysite:
    reinstall_modules:
      - webform           # Clear webform submissions cache
      - search_api        # Rebuild search indices
      - config_split      # Refresh split configuration
```

The script checks if each module is enabled before attempting reinstall.

## Troubleshooting

### SSH Connection Failed

**Symptom:** `SSH connection failed to user@host`

**Solution:**
1. Verify server is reachable: `ping host`
2. Test SSH manually: `ssh user@host`
3. Check SSH key permissions: `chmod 600 ~/.ssh/id_rsa_linode`
4. Verify SSH key in `nwp.yml` matches the key on server

### Production Path Not Found

**Symptom:** `Production path not found: /var/www/site`

**Solution:**
1. Verify `prod_path` in `nwp.yml` is correct
2. Create directory on production server:
   ```bash
   ssh root@prod-server 'mkdir -p /var/www/site'
   ```

### Rsync Permission Denied

**Symptom:** Rsync fails with permission errors

**Solution:**
1. Check SSH user has write access to `prod_path`
2. Ensure proper ownership:
   ```bash
   ssh root@prod-server 'chown -R www-data:www-data /var/www/site'
   ```

### Composer Install Failed

**Symptom:** `Composer install failed`

**Solution:**
1. Verify composer is installed on production server
2. Check PHP version compatibility
3. Ensure adequate disk space: `df -h`
4. Check composer memory limit:
   ```bash
   ssh root@prod-server 'php -d memory_limit=-1 $(which composer) install --no-dev'
   ```

### Configuration Import Errors

**Symptom:** `Configuration import had warnings`

**Solution:**
1. Review configuration differences:
   ```bash
   ssh root@prod-server 'cd /var/www/site && drush config:status'
   ```
2. Export config on staging first: `ddev drush cex -y`
3. Check for UUID mismatches in `system.site.yml`

### Email Forwarding Not Created

**Symptom:** `Could not create email forwarding`

**Solution:**
1. Verify mail server SSH access: `ssh gitlab@git.example.com`
2. Check email infrastructure: `ssh gitlab@git.example.com 'test -f /etc/postfix/virtual'`
3. Run email setup: `pl email setup` on mail server
4. Manual setup:
   ```bash
   ssh gitlab@git.example.com
   echo "site@example.com admin@example.com" | sudo tee -a /etc/postfix/virtual
   sudo postmap /etc/postfix/virtual
   sudo systemctl reload postfix
   ```

## Exit Codes

- `0` - Deployment successful
- `1` - Deployment failed (validation, SSH, rsync, or deployment step failure)

## Related Commands

- [stg2live](./stg2live.md) - Deploy staging to live test server
- [prod2stg](./prod2stg.md) - Pull production to staging
- [live](./live.md) - Provision live test server
- [make](./make.md) - Switch between dev and production modes

## See Also

- [Deployment Guide](../../guides/deployment.md) - Complete deployment workflows
- [Linode Setup](../../deployment/linode-setup.md) - Production server provisioning
- [Recipe Format](../recipe-format.md) - Recipe configuration reference
- [Security Model](../../security/security-model.md) - Secrets and credential management
