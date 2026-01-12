# Production Deployment Guide

## Overview

This guide covers deploying NWP sites to Linode production servers using the `stg2prod.sh` script.

The production deployment system supports:
- ✅ Staging-to-production workflow
- ✅ SSH/rsync-based file transfer
- ✅ Remote drush command execution
- ✅ Module reinstallation on production
- ✅ Configuration import and database updates
- ✅ Dry-run mode for safety
- ✅ Step-by-step resumable deployment

## Prerequisites

### Local Environment
- ✅ Staging site created and working (e.g., `mysite-stg`)
- ✅ DDEV installed and configured
- ✅ SSH key configured for passwordless access to production server

### Production Server (Linode)
- ✅ Ubuntu/Debian Linux
- ✅ Nginx or Apache configured
- ✅ PHP 8.2+ installed
- ✅ MySQL/MariaDB configured
- ✅ Composer installed globally
- ✅ Drush available (via composer or globally)
- ✅ SSH access configured

### Configuration Requirements
- ✅ Linode server defined in `cnwp.yml` under `linode:` section
- ✅ Production config in recipe or sites: section
- ✅ SSH keys added to server's `authorized_keys`

## Configuration

### 1. Configure Linode Server

Add your production server to `cnwp.yml`:

```yaml
linode:
  servers:
    linode_primary:
      ssh_user: deploy           # SSH username (not root!)
      ssh_host: 203.0.113.10     # Your Linode IP or hostname
      ssh_port: 22               # SSH port (default: 22)
      api_token: ${LINODE_API_TOKEN}  # Optional: for Linode API access
      server_ips:
        - 203.0.113.10           # Primary IP
      domains:
        - example.com            # Domain(s) pointing to this server
        - www.example.com
```

**Security Note**: Store sensitive tokens in environment variables, not directly in cnwp.yml.

### 2. Configure Production Deployment in Recipe

Add production configuration to your recipe:

```yaml
recipes:
  mysite:
    source: goalgorilla/social_template:dev-master
    profile: social
    webroot: html
    auto: y

    # Module reinstallation (optional)
    reinstall_modules: custom_module workflow_assignment

    # Production deployment configuration
    prod_method: rsync              # Deployment method (only rsync supported)
    prod_server: linode_primary     # Reference to linode.servers entry
    prod_domain: example.com        # Production domain
    prod_path: /var/www/mysite      # Remote path on server
```

**Alternative**: Site-specific production config in `sites:` section overrides recipe config.

### 3. SSH Key Setup

Configure passwordless SSH access:

```bash
# Generate SSH key if you don't have one
ssh-keygen -t ed25519 -C "your_email@example.com"

# Copy to production server
ssh-copy-id deploy@203.0.113.10

# Test connection
ssh deploy@203.0.113.10 echo "Connection successful"
```

## Email Configuration (v0.19.1+)

**Auto-configured during `pl live` deployment:**

When deploying with `pl live`, the system automatically configures site emails:

```yaml
# In cnwp.yml settings section:
settings:
  url: nwpcode.org
  email:
    auto_configure: true          # Enable auto-config (default: true)
    site_email_pattern: "{site}@{domain}"  # Pattern for site email
    admin_forward_to: admin@nwpcode.org    # Admin emails forwarded here
```

**What happens automatically:**
1. Site email set to `sitename@nwpcode.org`
2. Admin account email set to `admin-sitename@nwpcode.org`
3. Email forwarding configured for admin notifications

**Verification Step (v0.19.1+):**

During `stg2live` and `stg2prod` deployments, you'll see:

```
Email Configuration Verification
─────────────────────────────────
  Site Email: mysite@nwpcode.org
  Admin Email: admin-mysite@nwpcode.org

✓ Email addresses validated
! Make sure these email addresses are configured in your mail server
```

**To skip email auto-configuration:**

```yaml
settings:
  email:
    auto_configure: false
```

Or use command line:
```bash
pl live mysite --no-email-config
```

**Email Server Setup** (separate from NWP):
- Configure mail forwarding in your DNS/mail provider
- Set up SPF, DKIM, DMARC records
- Test with `drush email:test` after deployment

## Deployment Workflow

### Complete 10-Step Process

1. **Validate Deployment** - Check configuration and staging site
2. **Test SSH Connection** - Verify access to production server
3. **Export Config** - Export configuration from staging
4. **Backup Production** - Optional backup before deployment
5. **Sync Files** - Transfer files via rsync over SSH
6. **Composer Install** - Install dependencies on production
7. **Database Updates** - Run `drush updatedb` remotely
8. **Import Config** - Import configuration to production
9. **Reinstall Modules** - Reinstall configured modules
10. **Clear Cache** - Clear Drupal cache and display URL

## Usage Examples

### Basic Deployment

```bash
# Deploy mysite-stg to production
./stg2prod.sh mysite

# Or specify staging site directly
./stg2prod.sh mysite-stg
```

### Dry Run (Recommended First Time)

```bash
# See what would happen without making changes
./stg2prod.sh --dry-run mysite
```

### Auto-Confirm Deployment

```bash
# Skip confirmation prompts
./stg2prod.sh --yes mysite
./stg2prod.sh -y mysite
```

### Debug Mode

```bash
# Enable detailed debug output
./stg2prod.sh --debug mysite
./stg2prod.sh -d mysite
```

### Resume from Specific Step

```bash
# Resume from step 5 (useful if deployment was interrupted)
./stg2prod.sh --step=5 mysite
./stg2prod.sh -s 5 mysite
```

### Combined Flags

```bash
# Debug + auto-confirm
./stg2prod.sh -dy mysite

# Dry-run + debug
./stg2prod.sh --dry-run --debug mysite
```

## Step-by-Step Guide

### First Deployment

**Step 1: Prepare Staging Site**

```bash
# Ensure staging site is up-to-date
cd mysite-stg
ddev start
ddev drush cst   # Check status
ddev drush cex -y  # Export config
```

**Step 2: Run Dry Run**

```bash
cd /home/rob/nwp
./stg2prod.sh --dry-run mysite
```

Review the output carefully. It should show:
- ✅ Staging site exists
- ✅ Production configuration found
- ✅ SSH connection successful
- ✅ All steps would execute successfully

**Step 3: Actual Deployment**

```bash
# Deploy with confirmation
./stg2prod.sh mysite

# Or skip confirmation if confident
./stg2prod.sh -y mysite
```

**Step 4: Verify Production**

```bash
# SSH to production
ssh deploy@203.0.113.10

# Check site
cd /var/www/mysite
drush status
drush config:status
drush cache:rebuild

# Visit site
# https://example.com
```

### Subsequent Deployments

For updates after the initial deployment:

```bash
# 1. Update staging
cd mysite-stg
ddev drush cex -y

# 2. Test staging
ddev drush cst
ddev launch

# 3. Deploy to production
cd /home/rob/nwp
./stg2prod.sh -y mysite
```

## File Exclusions

The following are excluded from sync to protect production:

- `.git/` - Git repository
- `.ddev/` - DDEV configuration
- `*/settings.php` - Environment-specific settings
- `*/settings.local.php` - Local development settings
- `*/services.yml` - Services configuration
- `*/files/*` - User-uploaded files (managed separately)
- `private/*` - Private files
- `node_modules/` - Node dependencies
- `.env` - Environment variables

**Important**: User files (`sites/default/files/`) should be managed separately via rsync or Linode Object Storage.

## Module Reinstallation

Modules listed in `reinstall_modules` are uninstalled then re-enabled during deployment:

```yaml
recipes:
  mysite:
    reinstall_modules: custom_module workflow_assignment
```

This is useful for:
- ✅ Custom modules that need clean reinstallation
- ✅ Modules with update hooks that may not run properly
- ✅ Ensuring module configurations are rebuilt

**Process**:
1. Check if module is enabled
2. If enabled: `drush pm:uninstall -y module`
3. Re-enable: `drush pm:enable -y module`
4. Report status

## Troubleshooting

### SSH Connection Fails

**Error**: `SSH connection failed to deploy@203.0.113.10`

**Solutions**:
```bash
# Test SSH manually
ssh -v deploy@203.0.113.10

# Check SSH key
ssh-add -l

# Verify server in known_hosts
ssh-keyscan -H 203.0.113.10 >> ~/.ssh/known_hosts
```

### Configuration Not Found

**Error**: `No production deployment method configured`

**Solutions**:
```bash
# Check recipe configuration
grep -A 5 "prod_" cnwp.yml | grep myrecipe

# Verify linode server exists
grep -A 10 "linode:" cnwp.yml
```

### Composer Install Fails

**Error**: `Composer install failed`

**Solutions**:
```bash
# SSH to server and check
ssh deploy@203.0.113.10
cd /var/www/mysite

# Check composer
composer --version

# Check disk space
df -h

# Check permissions
ls -la

# Run composer manually
composer install --no-dev --optimize-autoloader
```

### Drush Commands Fail

**Error**: `drush: command not found`

**Solutions**:
```bash
# SSH to server
ssh deploy@203.0.113.10

# Check drush
which drush
drush --version

# If not found, install via composer
cd /var/www/mysite
composer require drush/drush

# Or install globally
composer global require drush/drush
```

### File Sync Takes Too Long

**Issue**: Large files directory causing slow deployment

**Solution**: Exclude files directory and sync separately:

```bash
# Manual file sync (one-time or periodic)
rsync -avz --progress \
  mysite-stg/html/sites/default/files/ \
  deploy@203.0.113.10:/var/www/mysite/html/sites/default/files/
```

### Permission Issues

**Error**: Permission denied errors on production

**Solutions**:
```bash
# SSH to server
ssh deploy@203.0.113.10

# Fix ownership
sudo chown -R deploy:www-data /var/www/mysite

# Fix permissions
cd /var/www/mysite
find . -type d -exec chmod 755 {} \;
find . -type f -exec chmod 644 {} \;

# Make settings.php writable during deployment
chmod 644 html/sites/default/settings.php
```

## Best Practices

### Before Deployment

- ✅ Export configuration on staging: `ddev drush cex -y`
- ✅ Test configuration status: `ddev drush cst`
- ✅ Run database updates on staging: `ddev drush updb -y`
- ✅ Clear cache on staging: `ddev drush cr`
- ✅ Test staging thoroughly
- ✅ Run dry-run first: `./stg2prod.sh --dry-run mysite`

### During Deployment

- ✅ Monitor the output for errors
- ✅ Watch for warnings about configuration imports
- ✅ Note any modules that fail to reinstall
- ✅ Keep terminal open until completion

### After Deployment

- ✅ Verify site loads: Visit production URL
- ✅ Check configuration: `drush config:status`
- ✅ Test critical functionality
- ✅ Monitor error logs: `/var/log/nginx/error.log`
- ✅ Check Drupal logs: Admin → Reports → Recent log messages

### Regular Maintenance

- 📅 Schedule regular deployments (e.g., weekly)
- 📅 Keep staging in sync with production database (periodic imports)
- 📅 Monitor production server disk space
- 📅 Review and clean up old backups
- 📅 Update Drupal core and modules on schedule

## Security Considerations

### SSH Security

- ✅ Use SSH keys, not passwords
- ✅ Use a dedicated deploy user, not root
- ✅ Restrict SSH access with firewall rules
- ✅ Use non-standard SSH port if desired
- ✅ Enable fail2ban to prevent brute force

### File Permissions

```bash
# Secure permissions
chown -R deploy:www-data /var/www/mysite
find /var/www/mysite -type d -exec chmod 755 {} \;
find /var/www/mysite -type f -exec chmod 644 {} \;

# Protect settings.php
chmod 444 /var/www/mysite/html/sites/default/settings.php
```

### Database Access

- ✅ Use separate database user for production
- ✅ Grant only necessary privileges
- ✅ Use strong passwords
- ✅ Restrict database access to localhost

### Environment Variables

```bash
# Store sensitive data in environment variables
export LINODE_API_TOKEN="your-token-here"

# Or use .env file (excluded from sync)
echo "LINODE_API_TOKEN=your-token-here" >> .env
chmod 600 .env
```

## Advanced Topics

### Multiple Production Servers

Configure multiple servers in `linode:` section:

```yaml
linode:
  servers:
    linode_prod:
      ssh_user: deploy
      ssh_host: 203.0.113.10
      domains:
        - example.com

    linode_backup:
      ssh_user: deploy
      ssh_host: 203.0.113.20
      domains:
        - backup.example.com
```

Use different `prod_server` in recipes or per-site configuration.

### Database Sync

Sync production database to staging periodically:

```bash
# On production
ssh deploy@203.0.113.10
cd /var/www/mysite
drush sql:dump > /tmp/prod-db.sql
gzip /tmp/prod-db.sql

# Download
scp deploy@203.0.113.10:/tmp/prod-db.sql.gz ./

# Import to staging
cd mysite-stg
gunzip -c prod-db.sql.gz | ddev drush sql:cli
ddev drush cr
ddev drush cex -y  # Export updated config
```

### Blue-Green Deployment

For zero-downtime deployments:

1. Deploy to alternate directory (e.g., `/var/www/mysite-new`)
2. Test new deployment
3. Switch symlink: `ln -sfn /var/www/mysite-new /var/www/mysite`
4. Keep old version for quick rollback

### Automated Deployments

Create cron job or CI/CD pipeline:

```bash
# Example: Deploy on git push to main
# .github/workflows/deploy.yml
on:
  push:
    branches: [main]
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2
      - name: Deploy to production
        run: ./stg2prod.sh -y mysite
```

## Monitoring

### Log Locations

- **Nginx Access**: `/var/log/nginx/access.log`
- **Nginx Error**: `/var/log/nginx/error.log`
- **PHP-FPM**: `/var/log/php8.2-fpm.log`
- **Drupal Watchdog**: Admin → Reports → Recent log messages

### Performance Monitoring

```bash
# Monitor server resources
htop
df -h
free -h

# Monitor PHP-FPM
sudo systemctl status php8.2-fpm

# Monitor Nginx
sudo systemctl status nginx

# Check Drupal status
drush status
drush core:requirements
```

## Related Documentation

- [Migration Guide](../guides/migration-sites-tracking.md) - Migrating to sites tracking
- [Roadmap](../governance/roadmap.md) - Project roadmap
- [Documentation Index](../README.md) - General NWP documentation

## Getting Help

- 📖 Review this documentation
- 🧪 Run tests: `./tests/test-integration.sh`
- 🐛 Check logs on both staging and production
- 💬 Report issues: https://github.com/anthropics/claude-code/issues
