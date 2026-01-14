# rollback

**Last Updated:** 2026-01-14

Manage deployment rollback points and recovery for NWP sites.

## Overview

The `rollback` command manages deployment rollback functionality, allowing you to revert to previous deployment states when issues occur. Rollback points are automatically created before each deployment and can be manually triggered when needed.

## Synopsis

```bash
pl rollback <command> [options] <sitename>
```

## Commands

| Command | Description |
|---------|-------------|
| `list [sitename]` | List available rollback points |
| `execute <sitename> [env]` | Rollback to last deployment |
| `verify <sitename>` | Verify site after rollback |
| `cleanup [--keep=N]` | Remove old rollback points (keep last N) |

## Options

| Option | Description | Default |
|--------|-------------|---------|
| `--env <environment>` | Environment (prod, stage, live) | prod |
| `--keep <count>` | Number of rollback points to keep | 5 |
| `-h, --help` | Show help message | - |

## Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `sitename` | Yes (except list/cleanup) | Site identifier to rollback |
| `environment` | No | Target environment for rollback |

## Examples

### List All Rollback Points

```bash
pl rollback list
```

Lists all available rollback points across all sites.

### List Rollback Points for Specific Site

```bash
pl rollback list mysite
```

Shows rollback points available for a specific site.

### Execute Rollback to Production

```bash
pl rollback execute mysite prod
```

Rollback production environment to the last deployment state.

### Execute Rollback to Staging

```bash
pl rollback execute mysite stage
```

Rollback staging environment to the last deployment state.

### Verify Site After Rollback

```bash
pl rollback verify mysite
```

Run verification checks to ensure the site is functioning correctly after rollback.

### Cleanup Old Rollback Points

```bash
pl rollback cleanup --keep=3
```

Remove old rollback points, keeping only the last 3 for each site.

### Default Cleanup

```bash
pl rollback cleanup
```

Remove old rollback points, keeping the last 5 (default).

## Rollback Point Creation

Rollback points are automatically created:

- **Before each deployment**: When running `pl live deploy` or similar commands
- **Before major updates**: Security updates, module updates
- **Manual creation**: Can be triggered via backup commands

Each rollback point contains:
- Database snapshot
- Code state reference (git commit hash)
- Configuration files
- File assets (if included in backup)

## Rollback Process

When executing a rollback:

1. **Pre-rollback verification**: Check rollback point integrity
2. **Database restore**: Restore database from snapshot
3. **Code revert**: Checkout previous git commit (if applicable)
4. **Configuration restore**: Restore settings and configuration files
5. **Cache clear**: Clear Drupal caches
6. **Verification**: Run basic health checks

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | General error (invalid parameters, missing files) |
| 2 | Rollback point not found |

## Prerequisites

- Site must exist in `sites/` directory
- Rollback points must be available (check with `list` command)
- Sufficient disk space for restoration
- Database must be accessible
- Git repository (for code rollback)

## Automatic Rollback

When a deployment fails, you'll be prompted automatically:

```
Deployment failed!
Rollback points are available. Would you like to rollback? (y/n)
```

This provides immediate recovery without manual intervention.

## Rollback Point Storage

Rollback points are stored in:

```
sites/<sitename>/backups/rollback/
├── rollback-YYYYMMDD-HHMMSS.sql.gz
├── rollback-YYYYMMDD-HHMMSS.info
└── ...
```

The `.info` file contains metadata:
- Timestamp
- Git commit hash
- Environment
- Backup type

## Best Practices

### Regular Cleanup

```bash
# Weekly cron job to cleanup old rollback points
0 2 * * 0 /path/to/nwp/pl rollback cleanup --keep=5
```

### Verify After Rollback

Always verify site functionality after rollback:

```bash
pl rollback execute mysite
pl rollback verify mysite
```

### Monitor Disk Space

Rollback points consume disk space. Monitor and cleanup regularly:

```bash
# Check rollback point sizes
du -sh sites/*/backups/rollback/
```

## Troubleshooting

### No Rollback Points Available

**Symptom:** Error message "No rollback points found"

**Solution:**
- Ensure deployments have been run (rollback points created automatically)
- Check `sites/<sitename>/backups/rollback/` directory exists
- Verify backup process is working correctly

### Rollback Fails with Database Error

**Symptom:** Database restoration fails during rollback

**Solution:**
- Verify database credentials in `.secrets.data.yml`
- Check database server is accessible
- Ensure sufficient database privileges
- Review rollback logs for specific error messages

### Site Not Working After Rollback

**Symptom:** Site inaccessible or errors after rollback

**Solution:**
1. Run verify command: `pl rollback verify mysite`
2. Clear caches: `pl drush mysite cr`
3. Check file permissions
4. Review Apache/Nginx logs
5. Consider rolling back to an earlier point

### Insufficient Disk Space

**Symptom:** Rollback fails with disk space error

**Solution:**
- Run cleanup: `pl rollback cleanup --keep=3`
- Remove unnecessary backups manually
- Increase disk space allocation

### Rollback Point Corrupted

**Symptom:** Error message about invalid or corrupted rollback point

**Solution:**
- List available rollback points: `pl rollback list mysite`
- Use an earlier rollback point
- Create fresh backup before attempting again
- Check filesystem integrity

## Notes

- Rollback points are environment-specific (prod, stage, etc.)
- Git commits are not deleted during rollback (code history preserved)
- File uploads (user content) may not be included in standard rollback points
- Rollback does not affect DNS, SSL certificates, or server configuration
- For production sites, test rollback in staging first when possible

## Performance Considerations

- Rollback time depends on database size
- Large databases (>1GB) may take several minutes
- Rollback points consume disk space (plan for 2-3x database size per point)
- Automatic cleanup prevents excessive disk usage

## Security Implications

- Rollback points may contain sensitive data
- Stored in `.gitignore` (not committed to repository)
- Protected by filesystem permissions
- Consider encrypting rollback points for compliance requirements
- Cleanup removes old data securely

## Related Commands

- [backup.sh](backup.md) - Create backups and rollback points
- [restore.sh](restore.md) - Restore from backups
- [live-deploy.sh](live-deploy.md) - Deploy with automatic rollback points
- [verify.sh](verify.md) - Verify site functionality

## See Also

- [Backup & Restore Guide](../../guides/backup-restore.md) - Comprehensive backup documentation
- [Deployment Guide](../../guides/deployment.md) - Deployment best practices
- [Rollback Architecture](../../decisions/0003-rollback-system.md) - Technical architecture
- [Data Security Best Practices](../../security/data-security-best-practices.md) - Security guidelines
