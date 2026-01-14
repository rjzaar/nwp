# schedule

**Last Updated:** 2026-01-14

Manage cron-based backup scheduling for NWP sites.

## Overview

The `schedule` command manages automated backup schedules using cron, allowing you to configure daily database backups, weekly full backups, and monthly bundle backups for your Drupal sites.

## Synopsis

```bash
pl schedule <command> [options] [sitename]
```

## Commands

| Command | Description |
|---------|-------------|
| `install <sitename>` | Install backup schedule for a site |
| `remove <sitename>` | Remove backup schedule for a site |
| `list` | List all scheduled backups |
| `show <sitename>` | Show schedule for a specific site |
| `run <sitename>` | Run scheduled backup now (for testing) |

## Options

| Option | Description | Default |
|--------|-------------|---------|
| `-h, --help` | Show help message | - |
| `-d, --debug` | Enable debug output | - |
| `--db-schedule=CRON` | Database backup schedule | 0 2 * * * |
| `--full-schedule=CRON` | Full backup schedule | 0 3 * * 0 |
| `--bundle-schedule=CRON` | Bundle backup schedule | 0 4 1 * * |
| `--no-db` | Don't schedule database backups | - |
| `--no-full` | Don't schedule full backups | - |
| `--no-bundle` | Don't schedule bundle backups | - |
| `--git` | Include git push in scheduled backups | - |
| `--push-all` | Push to all remotes (with --git) | - |

## Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `sitename` | Yes (except list) | Site identifier for scheduling |

## Default Schedule

| Backup Type | Schedule | Description |
|-------------|----------|-------------|
| Database | `0 2 * * *` | Daily at 2:00 AM |
| Full | `0 3 * * 0` | Weekly Sunday at 3:00 AM |
| Bundle | `0 4 1 * *` | Monthly 1st at 4:00 AM |

## Examples

### Install Default Schedule

```bash
pl schedule install nwp
```

Installs database, full, and bundle backups with default times.

### Install with Custom Database Schedule

```bash
pl schedule install nwp --db-schedule="0 4 * * *"
```

Database backups run daily at 4:00 AM instead of 2:00 AM.

### Install with Git Push

```bash
pl schedule install nwp --git
```

Automatically push backups to git remote after creation.

### Install Database Backups Only

```bash
pl schedule install nwp --no-full --no-bundle
```

Only schedule daily database backups, skip full and bundle backups.

### Remove Schedule

```bash
pl schedule remove nwp
```

Remove all scheduled backups for the site.

### List All Schedules

```bash
pl schedule list
```

Show all NWP backup schedules currently in crontab.

### Show Site-Specific Schedule

```bash
pl schedule show nwp
```

Display backup schedule for a specific site.

### Test Run Schedule

```bash
pl schedule run nwp
```

Manually trigger scheduled backup for testing (runs database backup).

## Cron Schedule Format

Cron schedules use standard 5-field format:

```
* * * * *
│ │ │ │ │
│ │ │ │ └─── Day of week (0-7, 0 and 7 = Sunday)
│ │ │ └───── Month (1-12)
│ │ └─────── Day of month (1-31)
│ └───────── Hour (0-23)
└─────────── Minute (0-59)
```

### Common Schedule Examples

```bash
# Every day at midnight
--db-schedule="0 0 * * *"

# Every 6 hours
--db-schedule="0 */6 * * *"

# Monday-Friday at 3 AM
--db-schedule="0 3 * * 1-5"

# First day of month at 5 AM
--bundle-schedule="0 5 1 * *"

# Every Sunday at 2:30 AM
--full-schedule="30 2 * * 0"
```

## Log Files

Backup logs are written to:

```
/var/log/nwp/backup-<sitename>.log
```

If `/var/log/nwp` is not writable, logs are written to:

```
/tmp/nwp/backup-<sitename>.log
```

### Viewing Logs

```bash
# Tail backup logs
tail -f /var/log/nwp/backup-mysite.log

# View last 50 lines
tail -n 50 /var/log/nwp/backup-mysite.log

# Search for errors
grep -i error /var/log/nwp/backup-mysite.log
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | General error (invalid parameters, missing site) |
| 3 | Programming error (getopt failure) |

## Prerequisites

- Cron must be available on the system
- User account must have crontab access
- Backup script must be executable: `scripts/commands/backup.sh`
- Site directory must exist: `sites/<sitename>/`
- Write access to log directory (`/var/log/nwp` or `/tmp/nwp`)

## Schedule Installation Process

When installing a schedule:

1. **Validates site directory** (warns if not found but continues)
2. **Creates log directory** (`/var/log/nwp` or falls back to `/tmp/nwp`)
3. **Reads current crontab** (empty if none exists)
4. **Removes existing entries** for the same site
5. **Generates new cron entries** based on options
6. **Installs updated crontab** with new schedules
7. **Displays confirmation** with schedule times

## Crontab Entry Format

Generated cron entries look like:

```bash
# NWP Backup Schedule - mysite - Database
0 2 * * * cd /path/to/nwp/scripts/commands && ./backup.sh -b mysite "Scheduled db backup" >> /var/log/nwp/backup-mysite.log 2>&1

# NWP Backup Schedule - mysite - Full
0 3 * * 0 cd /path/to/nwp/scripts/commands && ./backup.sh mysite "Scheduled full backup" >> /var/log/nwp/backup-mysite.log 2>&1

# NWP Backup Schedule - mysite - Bundle
0 4 1 * * cd /path/to/nwp/scripts/commands && ./backup.sh --bundle mysite "Scheduled bundle backup" >> /var/log/nwp/backup-mysite.log 2>&1
```

## Troubleshooting

### Schedule Not Running

**Symptom:** Backups not appearing in expected directory

**Solution:**
1. Verify cron service is running: `systemctl status cron`
2. Check crontab installed: `crontab -l | grep NWP`
3. Review logs: `tail /var/log/nwp/backup-<sitename>.log`
4. Test manual run: `pl schedule run <sitename>`
5. Check user permissions for backup directories

### Permission Denied Errors in Logs

**Symptom:** Backup logs show permission errors

**Solution:**
- Ensure backup script is executable: `chmod +x scripts/commands/backup.sh`
- Check site directory permissions
- Verify cron user has access to NWP directory
- Check log directory permissions: `/var/log/nwp`

### Multiple Schedules for Same Site

**Symptom:** Duplicate cron entries for a site

**Solution:**
```bash
# Remove all schedules for site
pl schedule remove mysite

# Reinstall clean schedule
pl schedule install mysite
```

### Logs Growing Too Large

**Symptom:** Log files consuming excessive disk space

**Solution:**
Set up log rotation in `/etc/logrotate.d/nwp`:

```
/var/log/nwp/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
}
```

### Backups Not Pushing to Git

**Symptom:** `--git` flag not working

**Solution:**
- Verify git remote is configured: `git remote -v`
- Check SSH keys for git authentication
- Test git push manually: `git push origin main`
- Review backup logs for git-specific errors

### Schedule Not Found After Install

**Symptom:** `pl schedule show mysite` shows nothing after install

**Solution:**
- Verify install succeeded (check exit code)
- List all schedules: `pl schedule list`
- Check crontab directly: `crontab -l`
- Ensure no cron syntax errors: `crontab -l | grep -v "^#" | grep "."`

## Best Practices

### Stagger Backup Times

Avoid scheduling all sites at the same time:

```bash
pl schedule install site1 --db-schedule="0 2 * * *"
pl schedule install site2 --db-schedule="15 2 * * *"
pl schedule install site3 --db-schedule="30 2 * * *"
```

### Monitor Backup Success

Set up monitoring to alert on backup failures:

```bash
# Add to crontab: Check for errors in last 24 hours
0 9 * * * grep -i error /var/log/nwp/backup-*.log | mail -s "NWP Backup Errors" admin@example.com
```

### Use Git Push for Off-Site Backup

Enable git push for automatic off-site backup:

```bash
pl schedule install mysite --git
```

### Keep Bundle Backups Infrequent

Bundle backups include files and are larger. Use monthly or less:

```bash
pl schedule install mysite --bundle-schedule="0 4 1 * *"
```

### Test Before Deploying

Always test schedule execution before relying on it:

```bash
pl schedule run mysite
# Check logs and backup directory
```

## Automation Examples

### Install Schedule for All Sites

```bash
#!/bin/bash
for site in $(ls sites/); do
  pl schedule install "$site" --git
done
```

### Weekly Schedule Report

```bash
#!/bin/bash
# Email weekly backup schedule report
(
  echo "NWP Backup Schedules"
  echo "===================="
  pl schedule list
) | mail -s "Weekly Backup Schedule Report" admin@example.com
```

## Notes

- Schedules persist across system reboots (stored in crontab)
- Multiple sites can have different schedules
- Cron runs in limited environment (PATH may differ)
- Email notifications depend on system mail configuration
- Bundle backups skip git push even with `--git` flag
- Schedules are user-specific (each user has separate crontab)

## Performance Considerations

- Database backups are fastest (SQL dump only)
- Full backups include files, take longer
- Bundle backups are largest, slowest
- Schedule backups during low-traffic periods
- Large sites may need extended backup windows
- Monitor disk I/O during scheduled backups

## Security Implications

- Cron runs with user's permissions
- Backup logs may contain database passwords (review log output)
- Ensure backup directories have restricted permissions
- Git push may require SSH key authentication
- Consider encrypting backups for sensitive data
- Logs contain site names and backup times (information disclosure)

## Related Commands

- [backup.sh](backup.md) - Manual backup creation
- [restore.sh](restore.md) - Restore from backups
- [rollback.sh](rollback.md) - Rollback deployments
- [git-backup.sh](git-backup.md) - Git-based backups

## See Also

- [Backup & Restore Guide](../../guides/backup-restore.md) - Comprehensive backup documentation
- [Automation Guide](../../guides/automation.md) - Automating NWP tasks
- [Cron Best Practices](../../guides/cron-best-practices.md) - Cron scheduling guidelines
- [Log Management](../../guides/log-management.md) - Managing NWP logs
