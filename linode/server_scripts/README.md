# NWP Server Scripts

These scripts run **on the Linode server** to manage NWP/OpenSocial Drupal sites.

## Scripts Overview

### Core Scripts

| Script | Purpose | Usage |
|--------|---------|-------|
| `nwp-bootstrap.sh` | Bootstrap server with required packages and directories | `./nwp-bootstrap.sh` |
| `nwp-createsite.sh` | Create a new site with database and Nginx config | `./nwp-createsite.sh example.com` |
| `nwp-swap-prod.sh` | Blue-green deployment swap | `./nwp-swap-prod.sh` |
| `nwp-rollback.sh` | Rollback last deployment | `./nwp-rollback.sh` |
| `nwp-backup.sh` | Backup site database and files | `./nwp-backup.sh` |

### Monitoring & Health

| Script | Purpose | Usage |
|--------|---------|-------|
| `nwp-healthcheck.sh` | Check site health (HTTP, Drupal, DB, cache, SSL) | `./nwp-healthcheck.sh [--json] /var/www/prod` |
| `nwp-monitor.sh` | Continuous monitoring with metrics and alerting | `./nwp-monitor.sh --domain example.com` |
| `nwp-audit.sh` | Log deployment events in JSON and text format | `./nwp-audit.sh --event deploy --site prod` |

### Backup & Recovery

| Script | Purpose | Usage |
|--------|---------|-------|
| `nwp-scheduled-backup.sh` | Automated backup with tiered rotation | `./nwp-scheduled-backup.sh prod database` |
| `nwp-verify-backup.sh` | Verify backup file integrity | `./nwp-verify-backup.sh backup.sql.gz` |
| `nwp-notify.sh` | Multi-channel notifications (log, email, Slack) | `./nwp-notify.sh "Message" warning` |

### Advanced Deployment

| Script | Purpose | Usage |
|--------|---------|-------|
| `nwp-bluegreen-deploy.sh` | Enhanced blue-green with canary support | `./nwp-bluegreen-deploy.sh --domain example.com` |
| `nwp-canary.sh` | Canary release management | `./nwp-canary.sh deploy --domain example.com` |
| `nwp-perf-baseline.sh` | Performance baseline tracking | `./nwp-perf-baseline.sh capture --domain example.com` |

### Configuration

| File | Purpose |
|------|---------|
| `nwp-cron.conf` | Example cron configuration for monitoring and backups |

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

### Bootstrap Server

```bash
# Initial server setup (run once)
sudo ./nwp-bootstrap.sh

# Reinstall all packages
sudo ./nwp-bootstrap.sh --reinstall

# Verbose output
sudo ./nwp-bootstrap.sh --verbose
```

This will:
- Verify/install required packages (PHP 8.2, Nginx, MariaDB, etc.)
- Create directory structure (/var/www/prod, /var/www/test, /var/www/old)
- Create backup and log directories (/var/backups/nwp, /var/log/nwp)
- Set proper permissions
- Install NWP server scripts to /usr/local/bin

### Health Check

```bash
# Check production site
./nwp-healthcheck.sh /var/www/prod

# Check with domain for SSL verification
./nwp-healthcheck.sh --domain example.com /var/www/prod

# Quick check (HTTP + Drupal bootstrap only)
./nwp-healthcheck.sh --quick /var/www/prod

# JSON output for monitoring systems
./nwp-healthcheck.sh --json /var/www/prod
```

Health checks include:
- HTTP/HTTPS response codes
- Drupal bootstrap status
- Database connectivity
- Cache functionality
- Cron status
- SSL certificate validity
- Disk space usage
- File permissions

### Audit Logging

```bash
# Log a deployment event
./nwp-audit.sh \
  --event deploy \
  --site prod \
  --user nwp \
  --commit abc123def456 \
  --branch main \
  --message "Deploy version 2.0"

# Log a swap event
./nwp-audit.sh --event swap --site prod --status success

# Log a failure
./nwp-audit.sh --event deploy --site test --status failure --message "Build failed"
```

Logs are written to:
- `/var/log/nwp/deployments.jsonl` - JSON Lines format (machine-readable)
- `/var/log/nwp/deployments.log` - Human-readable text format

### Monitoring

```bash
# Monitor production site with full alerting
./nwp-monitor.sh \
  --domain example.com \
  --alert-http \
  --alert-time 5 \
  --alert-disk 90 \
  /var/www/prod

# Monitor without alerts (metrics only)
./nwp-monitor.sh --domain example.com /var/www/prod

# Verbose output for debugging
./nwp-monitor.sh --domain example.com --verbose /var/www/prod
```

The monitoring script:
- Collects HTTP/HTTPS response codes and times
- Monitors disk usage
- Logs metrics to `/var/log/nwp/metrics/` in JSON format
- Triggers alerts when thresholds are exceeded:
  - HTTP status != 200/301/302
  - Response time > 5 seconds (configurable)
  - Disk usage > 90% (configurable)
- Sends notifications via `nwp-notify.sh` if configured

To set up automated monitoring via cron, see `nwp-cron.conf` for example configurations.

## Directory Structure

These scripts expect this directory structure on the server:

```
/var/www/
├── prod/          # Current production site
├── test/          # Test/staging environment
├── old/           # Previous production (for rollback)
└── html/          # Default Nginx welcome page

/var/backups/
└── nwp/           # NWP backup storage

/var/log/
└── nwp/           # NWP deployment and monitoring logs
    ├── deployments.log      # Human-readable deployment log
    ├── deployments.jsonl    # JSON Lines deployment log
    └── metrics/             # Monitoring metrics (JSON Lines)
        ├── metrics-2026-01-05.jsonl
        └── metrics-2026-01-06.jsonl
```

This structure is created automatically by:
- `linode_server_setup.sh` - Initial provisioning script
- `nwp-bootstrap.sh` - Server bootstrap script

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
- `/var/log/nwp/deployments.log` - Human-readable deployment history
- `/var/log/nwp/deployments.jsonl` - JSON Lines format for parsing/monitoring
- `/var/log/nwp-setup.log` - Initial server setup log (root of /var/log)

Monitoring metrics are logged to:
- `/var/log/nwp/metrics/metrics-YYYY-MM-DD.jsonl` - Daily metric logs in JSON Lines format

View recent deployments:
```bash
# View text log
tail -20 /var/log/nwp/deployments.log

# Parse JSON log
cat /var/log/nwp/deployments.jsonl | jq -r '.event + " - " + .site + " (" + .timestamp + ")"'

# Filter by event type
cat /var/log/nwp/deployments.jsonl | jq 'select(.event=="deploy")'
```

View monitoring metrics:
```bash
# View today's metrics
cat /var/log/nwp/metrics/metrics-$(date +%Y-%m-%d).jsonl | jq '.'

# Check response times over the last hour
cat /var/log/nwp/metrics/metrics-$(date +%Y-%m-%d).jsonl | \
  jq -r 'select(.timestamp > (now - 3600 | strftime("%Y-%m-%dT%H:%M:%S"))) |
         "\(.timestamp) - \(.http.response_time_ms)ms"'

# Count alerts triggered today
cat /var/log/nwp/metrics/metrics-$(date +%Y-%m-%d).jsonl | \
  jq -r 'select(.alerts > 0) | .timestamp' | wc -l

# Average response time today
cat /var/log/nwp/metrics/metrics-$(date +%Y-%m-%d).jsonl | \
  jq -s 'map(.http.response_time_ms) | add / length'
```

## Scheduled Backups

```bash
# Database backup (runs hourly, keeps 24)
./nwp-scheduled-backup.sh prod database

# File backup (runs daily, keeps 7)
./nwp-scheduled-backup.sh prod files

# Full backup with verification (runs weekly, keeps 4)
./nwp-scheduled-backup.sh prod full --verify
```

Backup locations:
- `/var/backups/nwp/hourly/` - Database backups (24 retention)
- `/var/backups/nwp/daily/` - File backups (7 retention)
- `/var/backups/nwp/weekly/` - Full backups (4 retention)

## Backup Verification

```bash
# Verify a database backup
./nwp-verify-backup.sh /var/backups/nwp/hourly/prod-database-20260105.sql.gz
# Exit code 0 = valid, 1 = invalid

# Verify a file backup
./nwp-verify-backup.sh /var/backups/nwp/daily/prod-files-20260105.tar.gz
```

## Notifications

```bash
# Log notification
./nwp-notify.sh "Deployment complete" info

# Email notification
NWP_ALERT_EMAIL="admin@example.com" ./nwp-notify.sh "Backup failed" error email

# Slack notification
SLACK_WEBHOOK_URL="https://hooks.slack.com/..." ./nwp-notify.sh "Site down" critical slack

# All channels
./nwp-notify.sh "Server restarted" warning all
```

## Advanced Deployment

### Blue-Green with Canary

```bash
# Standard blue-green deployment
./nwp-bluegreen-deploy.sh --domain example.com

# With canary (10% traffic to new version first)
./nwp-bluegreen-deploy.sh --domain example.com --canary --canary-percent 10

# With automatic rollback on failure
./nwp-bluegreen-deploy.sh --domain example.com --rollback-on-fail
```

### Canary Releases

```bash
# Deploy canary version
./nwp-canary.sh deploy --domain example.com --duration 600

# Check canary status
./nwp-canary.sh status

# Promote canary to full production
./nwp-canary.sh promote

# Rollback canary
./nwp-canary.sh rollback
```

### Performance Baseline

```bash
# Capture performance baseline after deployment
./nwp-perf-baseline.sh capture --domain example.com --set-latest

# Compare current performance to baseline
./nwp-perf-baseline.sh compare --domain example.com --threshold 20

# List all baselines
./nwp-perf-baseline.sh list

# Show specific baseline
./nwp-perf-baseline.sh show 20260105-120000
```

## Cron Configuration

Install the example cron configuration:

```bash
# Copy to cron.d
sudo cp nwp-cron.conf /etc/cron.d/nwp

# Or add to user crontab
crontab -e
```

Example cron entries (from `nwp-cron.conf`):
```cron
# Monitoring every 5 minutes
*/5 * * * * /usr/local/bin/nwp-monitor.sh --domain example.com /var/www/prod

# Database backup every 6 hours
0 */6 * * * /usr/local/bin/nwp-scheduled-backup.sh prod database

# File backup daily at 2 AM
0 2 * * * /usr/local/bin/nwp-scheduled-backup.sh prod files

# Full backup weekly Sunday 3 AM
0 3 * * 0 /usr/local/bin/nwp-scheduled-backup.sh prod full --verify
```

## See Also

- [LINODE_DEPLOYMENT.md](../../docs/LINODE_DEPLOYMENT.md) - Full deployment architecture
- [DISASTER_RECOVERY.md](../../docs/DISASTER_RECOVERY.md) - Disaster recovery procedures
- [ADVANCED_DEPLOYMENT.md](../../docs/ADVANCED_DEPLOYMENT.md) - Advanced deployment strategies
- [ENVIRONMENTS.md](../../docs/ENVIRONMENTS.md) - Environment management
- [Pleasy Server Scripts](https://github.com/rjzaar/pleasy/tree/master/server) - Original inspiration

---

*These scripts are adapted from the Pleasy project for NWP/OpenSocial on Linode.*
*Last Updated: January 5, 2026*
