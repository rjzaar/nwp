# stg2live

Deploy staging site to live test server.

**Last Updated:** 2026-01-14

## Overview

The `stg2live` command deploys a local staging site to a provisioned live test server. It handles file synchronization, database deployment, security module installation, SSL certificate setup, and email configuration.

## Usage

```bash
pl stg2live [OPTIONS] <sitename>
```

## Arguments

| Argument | Description |
|----------|-------------|
| `sitename` | Site name (with or without `-stg` suffix) |

## Options

| Flag | Description |
|------|-------------|
| `-h, --help` | Show help message |
| `-d, --debug` | Enable debug output |
| `-y, --yes` | Skip confirmation prompts |
| `-v, --verbose` | Show detailed rsync output |
| `--no-security` | Skip security module installation |
| `--no-password-reset` | Skip password security (admin regeneration, weak password reset) |
| `--no-provision` | Skip auto-provisioning (internal use) |

## Examples

### Basic deployment
```bash
pl stg2live mysite
```

### Deploy without confirmation
```bash
pl stg2live -y mysite
```

### Deploy without security modules
```bash
pl stg2live --no-security mysite
```

### Deploy without password reset
```bash
pl stg2live --no-password-reset mysite
```

## Password Security

Before deployment, this script automatically:
- **Regenerates admin password** to a secure 16-character random value
- **Detects weak passwords** (password, admin, test123, etc.)
- **Resets weak passwords** to secure random values
- **Displays new admin password** - SAVE IT!

Disable with `--no-password-reset` flag.

## Security Hardening

By default, security modules are installed from `cnwp.yml` `settings.live_security`:

### Example configuration
```yaml
settings:
  live_security:
    enabled: true
    modules:
      - seckit
      - honeypot
      - flood_control
      - login_security
```

Disable with `--no-security` flag or set `enabled: false` in cnwp.yml.

## Deployment Steps

1. **Check Staging Site** - Verify staging site exists
2. **Secure Passwords** - Regenerate admin password, reset weak passwords
3. **Install Security Modules** - Install and enable configured security modules
4. **Test SSH Connection** - Verify live server access
5. **Sync Files** - Rsync files to `/var/www/<sitename>/`
6. **Deploy Database** - Create database, generate settings.local.php, import data
7. **Setup SSL Certificate** - Configure Let's Encrypt SSL via certbot
8. **Deploy Production robots.txt** - Replace staging robots.txt with production version
9. **Clear Cache** - Run `drush cache:rebuild`
10. **Configure Email** - Setup email forwarding and verify Drupal site email

## Database Deployment

The script automatically:
1. Creates MySQL database if it doesn't exist
2. Creates database user with secure random password
3. Generates `settings.local.php` with database credentials
4. Exports database from staging (DDEV)
5. Imports database to live server

## SSL Certificate

The script uses certbot to obtain free Let's Encrypt SSL certificates:
- Waits for DNS propagation (up to 5 minutes)
- Obtains certificate via webroot method
- Updates nginx config for HTTPS redirection
- Adds security headers to nginx config

## Production robots.txt

The script deploys a production-ready `robots.txt` from `templates/robots-production.txt`:
- Allows search engine indexing
- Includes sitemap.xml reference
- Replaces `[DOMAIN]` placeholder with actual domain

## Auto-Provisioning

If no live server is configured, `stg2live` automatically calls `pl live` to provision one first.

## Prerequisites

- Staging site must exist and be in production mode
- Live server must be provisioned (or auto-provision enabled)
- SSH access configured to live server

## Exit Codes

- `0` - Deployment successful
- `1` - Deployment failed

## Related Commands

- [live](live.md) - Provision live test server
- [live2stg](live2stg.md) - Pull live server back to staging
- [live2prod](live2prod.md) - Deploy live directly to production
- [stg2prod](stg2prod.md) - Deploy staging to production

## See Also

- Live server architecture: `docs/architecture/live-servers.md`
- SSL certificate management: `docs/setup/ssl.md`
- Security hardening: `docs/security/`
