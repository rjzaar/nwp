# NWP Disaster Recovery Guide

This guide provides procedures for recovering from various disaster scenarios in the NWP (Nerd Word Plus) deployment system.

## Table of Contents

- [Overview](#overview)
- [Recovery Time Objectives (RTO)](#recovery-time-objectives-rto)
- [Backup System Overview](#backup-system-overview)
- [Disaster Scenarios](#disaster-scenarios)
  - [Scenario 1: Bad Deployment](#scenario-1-bad-deployment)
  - [Scenario 2: Database Corruption](#scenario-2-database-corruption)
  - [Scenario 3: Complete Server Loss](#scenario-3-complete-server-loss)
- [Pre-Disaster Preparation](#pre-disaster-preparation)
- [Post-Recovery Verification](#post-recovery-verification)
- [Contact Information](#contact-information)

## Overview

NWP implements a comprehensive disaster recovery strategy with automated backups and documented recovery procedures. This guide assumes you have:

- SSH access to the Linode server
- Local access to the NWP repository
- Appropriate credentials (stored in `.secrets.data.yml`)

## Recovery Time Objectives (RTO)

The Recovery Time Objective (RTO) is the maximum acceptable time to restore service after a disaster.

| Scenario | RTO | Data Loss (RPO) | Complexity |
|----------|-----|-----------------|------------|
| Bad Deployment | 5-10 minutes | None | Low |
| Database Corruption | 15-30 minutes | Up to 6 hours | Medium |
| File System Corruption | 30-60 minutes | Up to 24 hours | Medium |
| Complete Server Loss | 2-4 hours | Up to 24 hours | High |

**RPO (Recovery Point Objective)**: The maximum acceptable age of files that must be recovered.

## Backup System Overview

NWP uses a tiered backup system with different retention policies:

### Backup Types

| Type | Frequency | Location | Retention | Contents |
|------|-----------|----------|-----------|----------|
| **Database** | Every 6 hours | `/var/backups/nwp/hourly` | 24 backups (~1 day) | Database only (`.sql.gz`) |
| **Files** | Daily at 2 AM | `/var/backups/nwp/daily` | 7 backups (1 week) | Code files (`.tar.gz`) |
| **Full** | Weekly (Sunday 3 AM) | `/var/backups/nwp/weekly` | 4 backups (1 month) | Database + Files + Uploads |

### Backup Naming Convention

```
{site}_{type}_{timestamp}_{component}.{ext}

Examples:
prod_database_20260105_120000_db.sql.gz
prod_files_20260105_020000_files.tar.gz
prod_full_20260105_030000_db.sql.gz
prod_full_20260105_030000_files.tar.gz
prod_full_20260105_030000_uploads.tar.gz
```

### Automated Backup Schedule

Backups are automated via cron (see `/home/rob/nwp/linode/server_scripts/nwp-cron.conf`):

```bash
# Database backups every 6 hours
0 */6 * * * /path/to/nwp-scheduled-backup.sh prod database

# File backups daily at 2 AM
0 2 * * * /path/to/nwp-scheduled-backup.sh prod files

# Full backups weekly on Sunday at 3 AM
0 3 * * 0 /path/to/nwp-scheduled-backup.sh prod full
```

## Disaster Scenarios

---

## Scenario 1: Bad Deployment

**Situation**: A deployment introduced bugs, breaking changes, or performance issues.

**RTO**: 5-10 minutes
**RPO**: None (rollback to previous code)
**Complexity**: Low

### Detection

- Health checks failing
- User reports of errors
- Audit logs showing recent deployment
- Monitoring alerts

### Recovery Procedure

#### Step 1: Verify the Issue

```bash
# On Linode server
ssh nwp-prod

# Check health status
/var/www/prod/vendor/bin/drush status

# View recent deployments
tail -n 50 /var/log/nwp/deployments.log

# Check audit log
tail -n 20 /var/log/nwp/deployments.jsonl
```

#### Step 2: Execute Rollback

The NWP blue-green deployment system maintains the previous production version in `/var/www/test`.

```bash
# On Linode server
cd /path/to/nwp-server-scripts

# Perform rollback (swaps test and prod directories)
sudo ./nwp-rollback.sh --yes

# The script will:
# - Enable maintenance mode
# - Swap /var/www/prod with /var/www/test
# - Restore production settings
# - Clear caches
# - Disable maintenance mode
# - Verify the rollback
```

#### Step 3: Verify Recovery

```bash
# Check site status
curl -I https://your-site.com

# Verify Drupal is working
/var/www/prod/vendor/bin/drush status

# Test critical functionality
# - Login
# - Content display
# - Forms
```

#### Step 4: Investigate the Issue

```bash
# On local machine
cd /home/rob/nwp

# Check what was deployed
git log -5 --oneline

# Review the problematic changes
git diff HEAD~1 HEAD

# Create a bug report or revert the changes
```

### Prevention

- Use `./nwp-test-deploy.sh` before production deployments
- Run automated tests locally
- Monitor health checks after deployment
- Deploy during low-traffic periods

---

## Scenario 2: Database Corruption

**Situation**: Database is corrupted, has bad data, or experienced a failed migration.

**RTO**: 15-30 minutes
**RPO**: Up to 6 hours (hourly database backups)
**Complexity**: Medium

### Detection

- Database connection errors
- Drupal white screen of death (WSOD)
- MySQL errors in logs
- Content missing or corrupted
- Failed Drupal update

### Recovery Procedure

#### Step 1: Assess the Damage

```bash
# On Linode server
ssh nwp-prod

# Check MySQL status
sudo systemctl status mysql

# Test database connectivity
mysql -u drupal_user -p -e "SELECT 1"

# Check Drupal database status
cd /var/www/prod
./vendor/bin/drush status

# Look for database errors
tail -f /var/log/mysql/error.log
```

#### Step 2: Put Site in Maintenance Mode

```bash
# Enable maintenance mode
cd /var/www/prod
./vendor/bin/drush state:set system.maintenance_mode 1 -y

# Or via the web interface if accessible
```

#### Step 3: Select Appropriate Backup

```bash
# List available database backups
ls -lht /var/backups/nwp/hourly/*_db.sql.gz | head -n 10

# Example output:
# prod_database_20260105_180000_db.sql.gz  (6 hours old)
# prod_database_20260105_120000_db.sql.gz  (12 hours old)
# prod_database_20260105_060000_db.sql.gz  (18 hours old)

# Choose the most recent backup before corruption occurred
BACKUP_FILE="/var/backups/nwp/hourly/prod_database_20260105_120000_db.sql.gz"
```

#### Step 4: Verify Backup Integrity

```bash
# Verify the backup is valid
cd /path/to/nwp-server-scripts
./nwp-verify-backup.sh "$BACKUP_FILE" --verbose

# Should output:
# ✓ File size OK: 12345678 bytes
# ✓ Gzip integrity OK
# ✓ SQL content verified
# ✓ Backup verification passed!
```

#### Step 5: Restore Database

```bash
# Extract database credentials
cd /var/www/prod
SETTINGS_FILE="web/sites/default/settings.php"
DB_NAME=$(grep "^\s*'database'" "$SETTINGS_FILE" | head -n1 | sed "s/.*'\(.*\)'.*/\1/")
DB_USER=$(grep "^\s*'username'" "$SETTINGS_FILE" | head -n1 | sed "s/.*'\(.*\)'.*/\1/")
DB_PASS=$(grep "^\s*'password'" "$SETTINGS_FILE" | head -n1 | sed "s/.*'\(.*\)'.*/\1/")

# Create a safety backup of current (corrupted) database
mysqldump -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" | gzip > /tmp/corrupted_db_$(date +%Y%m%d_%H%M%S).sql.gz

# Drop and recreate database
mysql -u "$DB_USER" -p"$DB_PASS" -e "DROP DATABASE IF EXISTS $DB_NAME; CREATE DATABASE $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"

# Restore from backup
gunzip -c "$BACKUP_FILE" | mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME"

# Verify restoration
mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "SHOW TABLES; SELECT COUNT(*) FROM users;"
```

#### Step 6: Run Database Updates

```bash
# Run pending database updates (if any)
cd /var/www/prod
./vendor/bin/drush updatedb -y

# Rebuild cache
./vendor/bin/drush cr

# Check entity updates
./vendor/bin/drush entup -y
```

#### Step 7: Disable Maintenance Mode

```bash
# Disable maintenance mode
./vendor/bin/drush state:set system.maintenance_mode 0 -y

# Verify site is accessible
curl -I https://your-site.com
```

#### Step 8: Verify Recovery

```bash
# Check Drupal status
./vendor/bin/drush status

# Test critical functionality:
# - User login
# - Content display
# - Content creation
# - Search functionality
# - Views rendering

# Check logs for errors
./vendor/bin/drush watchdog:show --severity=Error --count=20
```

### Post-Recovery

- Document what caused the corruption
- Review any data loss (content created between backup and corruption)
- Notify users if significant data loss occurred
- Consider creating an immediate new backup

### Prevention

- Test database migrations in staging environment
- Increase backup frequency for critical periods
- Monitor database health metrics
- Use database replication for high-availability setups

---

## Scenario 3: Complete Server Loss

**Situation**: Server is completely inaccessible, destroyed, or compromised.

**RTO**: 2-4 hours
**RPO**: Up to 24 hours (depends on last successful backup sync)
**Complexity**: High

### Detection

- Server completely unresponsive
- Cannot SSH to server
- Linode console shows system failure
- Hardware failure notifications
- Security breach requiring complete rebuild

### Recovery Procedure

This procedure assumes you need to provision a new Linode server and restore from backups.

#### Step 1: Provision New Linode Server

```bash
# On local machine
cd /home/rob/nwp

# Option A: Use Linode CLI (if configured)
# Create a new Linode with same specs as original

# Option B: Use Linode web interface
# - Create new Linode
# - Same distribution (Ubuntu)
# - Same region
# - Same or larger plan
# - Note the new IP address
```

#### Step 2: Bootstrap New Server

```bash
# On local machine
# Update DNS or /etc/hosts to point to new server IP temporarily
NEW_IP="new.server.ip.address"

# Run bootstrap script to set up new server
./linode/server_scripts/nwp-bootstrap.sh --host $NEW_IP

# This will:
# - Install system dependencies
# - Configure web server (Apache/Nginx)
# - Install PHP and required extensions
# - Install MySQL/MariaDB
# - Set up directory structure
# - Configure SSL certificates
```

#### Step 3: Retrieve Backups

You have several options for retrieving backups:

**Option A: Backups were synced to object storage (recommended)**

```bash
# Download from S3/Linode Object Storage
# (Requires prior setup of backup sync to object storage)
ssh root@$NEW_IP

mkdir -p /var/backups/nwp
cd /var/backups/nwp

# Using s3cmd or similar
s3cmd sync s3://nwp-backups/latest/ /var/backups/nwp/
```

**Option B: Backups were on the old server (use Linode Backup Service)**

```bash
# If you enabled Linode's backup service:
# - Restore the old Linode from backup to a temporary Linode
# - Extract backups from /var/backups/nwp
# - Transfer to new server
# - Destroy temporary Linode

# From old server backup:
scp -r root@old-backup-server:/var/backups/nwp/* root@$NEW_IP:/var/backups/nwp/
```

**Option C: Local backups available**

```bash
# If you've been syncing backups locally
scp -r /local/path/to/backups/* root@$NEW_IP:/var/backups/nwp/
```

#### Step 4: Identify Latest Valid Backup

```bash
# On new server
ssh root@$NEW_IP

cd /var/backups/nwp

# Find the most recent full backup
find . -name "prod_full_*_db.sql.gz" | sort -r | head -n 1
find . -name "prod_full_*_files.tar.gz" | sort -r | head -n 1
find . -name "prod_full_*_uploads.tar.gz" | sort -r | head -n 1

# Example:
LATEST_DB="/var/backups/nwp/weekly/prod_full_20260105_030000_db.sql.gz"
LATEST_FILES="/var/backups/nwp/weekly/prod_full_20260105_030000_files.tar.gz"
LATEST_UPLOADS="/var/backups/nwp/weekly/prod_full_20260105_030000_uploads.tar.gz"
```

#### Step 5: Verify Backup Integrity

```bash
# Verify all backup files
for backup in $LATEST_DB $LATEST_FILES $LATEST_UPLOADS; do
    /path/to/nwp-verify-backup.sh "$backup" --verbose
done
```

#### Step 6: Restore Files

```bash
# Extract code files to /var/www/prod
cd /var/www
sudo tar -xzf "$LATEST_FILES"

# Rename extracted directory to 'prod' if needed
# (depends on how it was backed up)
sudo mv prod_20260105_030000 prod

# Extract uploaded files
cd /var/www/prod/web/sites/default
sudo tar -xzf "$LATEST_UPLOADS"

# Set permissions
sudo chown -R www-data:www-data /var/www/prod
sudo chmod -R 755 /var/www/prod
```

#### Step 7: Restore Database

```bash
# Create database
sudo mysql -e "CREATE DATABASE drupal_prod CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"

# Create database user
sudo mysql -e "CREATE USER 'drupal_user'@'localhost' IDENTIFIED BY 'your_password';"
sudo mysql -e "GRANT ALL PRIVILEGES ON drupal_prod.* TO 'drupal_user'@'localhost';"
sudo mysql -e "FLUSH PRIVILEGES;"

# Restore database from backup
gunzip -c "$LATEST_DB" | sudo mysql drupal_prod

# Verify database
sudo mysql drupal_prod -e "SHOW TABLES; SELECT COUNT(*) FROM users;"
```

#### Step 8: Configure Drupal Settings

```bash
# Update settings.php with new database credentials
cd /var/www/prod/web/sites/default

# Either restore from backup or update manually
sudo nano settings.php

# Update:
# - Database credentials
# - Base URL
# - Trusted host patterns
# - File paths
```

#### Step 9: Install Dependencies

```bash
cd /var/www/prod

# Install Composer dependencies
sudo -u www-data composer install

# Install Node dependencies if needed
sudo -u www-data npm install
```

#### Step 10: Run Drupal Updates

```bash
cd /var/www/prod

# Clear cache
sudo -u www-data ./vendor/bin/drush cr

# Run database updates
sudo -u www-data ./vendor/bin/drush updatedb -y

# Rebuild cache again
sudo -u www-data ./vendor/bin/drush cr
```

#### Step 11: Configure Web Server

```bash
# Enable site in Apache/Nginx
sudo a2ensite nwp-prod.conf
sudo systemctl reload apache2

# Or for Nginx:
sudo ln -s /etc/nginx/sites-available/nwp-prod.conf /etc/nginx/sites-enabled/
sudo systemctl reload nginx
```

#### Step 12: Configure SSL

```bash
# Install certbot if not already done
sudo apt-get install certbot python3-certbot-apache

# Obtain SSL certificate
sudo certbot --apache -d your-site.com -d www.your-site.com

# Or renew existing certificate
sudo certbot renew
```

#### Step 13: Update DNS

```bash
# Update DNS records to point to new server IP
# This depends on your DNS provider (Cloudflare, etc.)

# Update A record for your-site.com to new IP
# Wait for DNS propagation (can take 5-60 minutes)
```

#### Step 14: Verify Full Recovery

```bash
# Test site accessibility
curl -I https://your-site.com

# Test Drupal
cd /var/www/prod
./vendor/bin/drush status

# Comprehensive functionality tests:
# - User login
# - Content display
# - Content creation/editing
# - File uploads
# - Search functionality
# - Forms and submissions
# - Cron jobs
# - Email sending

# Check logs
./vendor/bin/drush watchdog:show --count=50
tail -f /var/log/apache2/error.log
```

#### Step 15: Restore Automated Backups

```bash
# Set up cron jobs for backups
sudo crontab -e

# Add backup schedule (or copy from nwp-cron.conf)
0 */6 * * * /path/to/nwp-scheduled-backup.sh prod database
0 2 * * * /path/to/nwp-scheduled-backup.sh prod files
0 3 * * 0 /path/to/nwp-scheduled-backup.sh prod full

# Set up backup sync to object storage
# (Configure s3cmd or similar to sync /var/backups/nwp)
```

### Post-Recovery Actions

1. **Document the incident**
   - What happened?
   - What was the root cause?
   - How long was the downtime?
   - What data was lost?

2. **Notify stakeholders**
   - Internal team
   - Users (if appropriate)
   - Management

3. **Review and improve**
   - Update disaster recovery plan
   - Improve backup procedures
   - Add monitoring/alerting
   - Consider high-availability setup

### Prevention and Mitigation

- **Enable Linode Backup Service** for automatic server snapshots
- **Sync backups to object storage** (S3, Linode Object Storage)
- **Keep local copies** of critical backups
- **Test recovery procedures** regularly (quarterly)
- **Document custom configurations** that need to be restored
- **Use Infrastructure as Code** for server provisioning
- **Monitor server health** and set up alerts
- **Implement redundancy** for critical sites (load balancers, database replication)

---

## Pre-Disaster Preparation

Preparation significantly reduces recovery time and data loss.

### Backup Verification

Regularly verify backups are being created and are valid:

```bash
# On Linode server
ssh nwp-prod

# Check backup directories
ls -lht /var/backups/nwp/hourly/ | head -n 5
ls -lht /var/backups/nwp/daily/ | head -n 3
ls -lht /var/backups/nwp/weekly/ | head -n 2

# Verify latest backups
find /var/backups/nwp -name "*.gz" -mtime -1 -exec ls -lh {} \;

# Test backup integrity
/path/to/nwp-verify-backup.sh /var/backups/nwp/hourly/latest_db.sql.gz --verbose
```

### Off-Site Backup Sync

Configure automated sync of backups to off-site storage:

```bash
# Install s3cmd or similar
sudo apt-get install s3cmd

# Configure s3cmd
s3cmd --configure

# Create sync script
cat > /usr/local/bin/nwp-backup-sync.sh << 'EOF'
#!/bin/bash
# Sync NWP backups to S3/Object Storage
s3cmd sync /var/backups/nwp/ s3://nwp-backups/$(hostname)/
EOF

chmod +x /usr/local/bin/nwp-backup-sync.sh

# Add to cron (daily at 4 AM)
echo "0 4 * * * /usr/local/bin/nwp-backup-sync.sh" | sudo crontab -
```

### Documentation

Keep up-to-date documentation:

- Server configurations
- Custom modifications
- Third-party integrations
- API keys and credentials (securely stored)
- DNS settings
- SSL certificate details

### Testing

Test recovery procedures regularly:

1. **Monthly**: Verify latest backup integrity
2. **Quarterly**: Perform test restoration to staging environment
3. **Annually**: Full disaster recovery drill (complete server rebuild)

### Monitoring

Set up monitoring and alerts:

- Server uptime monitoring
- Disk space alerts
- Backup job success/failure notifications
- Database health checks
- Application error monitoring

---

## Post-Recovery Verification

After any recovery, perform these verification steps:

### 1. System Health

```bash
# Check system resources
free -h
df -h
top

# Check services
sudo systemctl status apache2
sudo systemctl status mysql
sudo systemctl status php-fpm
```

### 2. Drupal Status

```bash
cd /var/www/prod

# Drupal status report
./vendor/bin/drush status

# Check for errors
./vendor/bin/drush watchdog:show --severity=Error --count=20

# Run status report
./vendor/bin/drush core:requirements
```

### 3. Functional Testing

Test critical site functionality:

- [ ] Homepage loads
- [ ] User login works
- [ ] Content displays correctly
- [ ] Create new content
- [ ] Edit existing content
- [ ] File uploads work
- [ ] Search functionality works
- [ ] Forms submit correctly
- [ ] Email sending works
- [ ] Cron runs successfully
- [ ] Admin interface accessible

### 4. Performance Testing

```bash
# Test page load times
time curl -I https://your-site.com

# Check database performance
./vendor/bin/drush sql:query "SHOW PROCESSLIST;"

# Review caching
./vendor/bin/drush config:get system.performance
```

### 5. Security Verification

```bash
# Check file permissions
ls -la /var/www/prod/web/sites/default/

# Verify SSL certificate
openssl s_client -connect your-site.com:443 -servername your-site.com

# Check for security updates
./vendor/bin/drush pm:security

# Review user accounts
./vendor/bin/drush user:information
```

---

## Contact Information

### Support Resources

- **NWP Repository**: `/home/rob/nwp`
- **Documentation**: `/home/rob/nwp/docs/`
- **Scripts**: `/home/rob/nwp/linode/server_scripts/`

### Related Documentation

- [Production Deployment Guide](production-deployment.md)
- [Linode Deployment Guide](linode-deployment.md)
- [Backup Implementation](../reference/backup-implementation.md)
- [Testing Guide](../testing/testing.md)
- [CI/CD Documentation](cicd.md)

### Emergency Contacts

Document your team's emergency contacts:

- **System Administrator**: [Contact Info]
- **Database Administrator**: [Contact Info]
- **Linode Support**: https://www.linode.com/support/
- **On-Call Rotation**: [Contact Info]

---

## Appendix: Quick Reference Commands

### Check System Status

```bash
# Server status
ssh nwp-prod
sudo systemctl status apache2 mysql

# Drupal status
cd /var/www/prod && ./vendor/bin/drush status

# Recent logs
tail -f /var/log/apache2/error.log
./vendor/bin/drush watchdog:tail
```

### Emergency Rollback

```bash
ssh nwp-prod
sudo /path/to/nwp-rollback.sh --yes
```

### Quick Database Restore

```bash
ssh nwp-prod
BACKUP="/var/backups/nwp/hourly/prod_database_YYYYMMDD_HHMMSS_db.sql.gz"
gunzip -c "$BACKUP" | mysql -u USER -pPASS DATABASE
cd /var/www/prod && ./vendor/bin/drush cr
```

### Verify Backups

```bash
ssh nwp-prod
ls -lht /var/backups/nwp/hourly/ | head -n 5
/path/to/nwp-verify-backup.sh /path/to/backup.sql.gz --verbose
```

---

**Last Updated**: 2026-01-05
**Version**: 1.0
**Maintainer**: NWP DevOps Team
