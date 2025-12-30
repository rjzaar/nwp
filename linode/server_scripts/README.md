# NWP Server Scripts

These scripts run **on the Linode server** to manage NWP/OpenSocial Drupal sites.

## Scripts Overview

| Script | Purpose | Usage |
|--------|---------|-------|
| `nwp-createsite.sh` | Create a new site with database and Nginx config | `./nwp-createsite.sh example.com` |
| `nwp-swap-prod.sh` | Blue-green deployment swap | `./nwp-swap-prod.sh` |
| `nwp-rollback.sh` | Rollback last deployment | `./nwp-rollback.sh` |
| `nwp-backup.sh` | Backup site database and files | `./nwp-backup.sh` |

## Installation

These scripts should be copied to the Linode server during provisioning or manually:

```bash
# From your local machine
scp linode/server_scripts/*.sh nwp@your-server:~/nwp-scripts/

# On the server
chmod +x ~/nwp-scripts/*.sh
```

## Usage Examples

### Create a New Site

```bash
./nwp-createsite.sh \
  --domain example.com \
  --email admin@example.com \
  --enable-ssl \
  example.com
```

This will:
- Create a database and user
- Configure Nginx virtual host
- Set up SSL certificate (if --enable-ssl)
- Set proper file permissions

### Blue-Green Deployment

```bash
# Deploy new version to test directory first
# (via linode_deploy.sh from local machine)

# Then swap on server
./nwp-swap-prod.sh --maintenance --yes
```

This performs:
- Zero-downtime swap: test → prod, prod → old
- Maintenance mode during swap
- Permission fixes
- Cache clear

### Rollback Deployment

```bash
./nwp-rollback.sh --yes
```

Instantly reverts to the previous production version.

### Backup Site

```bash
# Full backup
./nwp-backup.sh /var/www/prod

# Database only
./nwp-backup.sh --db-only /var/www/prod

# Custom output location
./nwp-backup.sh --output /home/nwp/backups /var/www/prod
```

## Directory Structure

These scripts expect this directory structure on the server:

```
/var/www/
├── prod/          # Current production site
├── test/          # Test/staging environment
├── old/           # Previous production (for rollback)
└── backups/       # Local backups (optional)
```

This structure is created automatically by the `linode_server_setup.sh` provisioning script.

## Blue-Green Deployment Flow

1. **Deploy to test:**
   - From local: `./linode_deploy.sh nwp4_prod test.example.com`
   - This updates `/var/www/test`

2. **Verify test site:**
   - Visit `https://test.example.com`
   - Run tests and QA

3. **Swap to production:**
   - On server: `./nwp-swap-prod.sh`
   - This atomically swaps directories

4. **Rollback if needed:**
   - On server: `./nwp-rollback.sh`
   - Previous version is restored instantly

## Security Notes

- These scripts should be owned by the `nwp` user
- Database credentials are extracted from Drupal's `settings.php`
- Backups include sensitive data - protect them!
- Use `--maintenance` flag for production swaps
- Always verify test site before swapping

## Permissions

The scripts set these permissions automatically:
- Directories: `755` (www-data:www-data)
- Files: `644` (www-data:www-data)
- settings.php: `440` (read-only for web server)

## Troubleshooting

**Swap fails:**
- Check directory exists: `ls -la /var/www/`
- Verify permissions: `sudo chown -R www-data:www-data /var/www/`

**Can't clear cache:**
- Run manually: `cd /var/www/prod && sudo -u www-data ./vendor/bin/drush cr`

**Nginx config errors:**
- Test config: `sudo nginx -t`
- View error log: `sudo tail -f /var/log/nginx/error.log`

**Database backup fails:**
- Verify credentials in settings.php
- Check MySQL is running: `sudo systemctl status mariadb`

## Logs

Deployment actions are logged to:
- `/var/log/nwp-deployments.log` - Swap/rollback history
- `/var/log/nwp-setup.log` - Initial server setup log

## See Also

- [LINODE_DEPLOYMENT.md](../../docs/LINODE_DEPLOYMENT.md) - Full deployment architecture
- [SETUP_GUIDE.md](../docs/SETUP_GUIDE.md) - Initial Linode setup guide
- [Pleasy Server Scripts](https://github.com/rjzaar/pleasy/tree/master/server) - Original inspiration

---

*These scripts are adapted from the Pleasy project for NWP/OpenSocial on Linode.*
