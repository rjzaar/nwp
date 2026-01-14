# Rollback Procedures

**Status:** ACTIVE
**Last Updated:** 2026-01-14

Complete guide for rolling back failed deployments and recovering from production issues using NWP's automated rollback system.

## Overview

NWP provides automated rollback capabilities for quickly recovering from failed deployments. Rollback points are automatically created before each deployment, enabling safe recovery to the last known-good state.

## Rollback Commands

```bash
pl rollback list [sitename]              # List available rollback points
pl rollback execute <sitename> [env]     # Rollback to last deployment
pl rollback verify <sitename>            # Verify site after rollback
pl rollback cleanup [--keep=N]           # Remove old rollback points
```

## Automatic Rollback Points

Rollback points are automatically created before:
- Production deployments (`pl stg2prod`)
- Live deployments (`pl live deploy`)
- Major updates (`pl security update`)
- Configuration imports

Each rollback point contains:
- Database snapshot
- Files snapshot
- Git commit hash
- Configuration state
- Timestamp and deployment metadata

## Rollback Workflow

### Step 1: List Available Rollback Points

View available rollback points:

```bash
pl rollback list avc
```

Output:
```
═══════════════════════════════════════════════════════════════
  Rollback Points: avc (production)
═══════════════════════════════════════════════════════════════

1. 2026-01-14 14:30:22 - Before deployment (commit: a1b2c3d4)
   Environment: production
   Database: 245 MB
   Files: 1.2 GB
   Status: Healthy
   Age: 2 hours ago

2. 2026-01-13 09:15:10 - Before security update (commit: b2c3d4e5)
   Environment: production
   Database: 243 MB
   Files: 1.2 GB
   Status: Healthy
   Age: 1 day ago

3. 2026-01-10 16:45:33 - Before deployment (commit: c3d4e5f6)
   Environment: production
   Database: 240 MB
   Files: 1.1 GB
   Status: Healthy
   Age: 4 days ago

4. 2026-01-07 11:20:15 - Before deployment (commit: d4e5f6a7)
   Environment: production
   Database: 238 MB
   Files: 1.1 GB
   Status: Healthy
   Age: 1 week ago

5. 2026-01-01 08:00:00 - Before deployment (commit: e5f6a7b8)
   Environment: production
   Database: 235 MB
   Files: 1.0 GB
   Status: Healthy
   Age: 2 weeks ago
```

### Step 2: Execute Rollback

Rollback to the most recent rollback point:

```bash
pl rollback execute avc prod
```

Interactive confirmation:
```
═══════════════════════════════════════════════════════════════
  Rollback: avc (production)
═══════════════════════════════════════════════════════════════

Rolling back to:
  Date:     2026-01-14 14:30:22
  Commit:   a1b2c3d4
  Database: 245 MB
  Files:    1.2 GB

WARNING: This will overwrite current production state
Continue? [y/N]: y

[1/8] Validate rollback point
✓ Rollback point valid

[2/8] Create safety backup
✓ Current state backed up

[3/8] Stop site
✓ Site stopped

[4/8] Restore database
✓ Database restored (245 MB)

[5/8] Restore files
✓ Files restored (1.2 GB)

[6/8] Restore configuration
✓ Configuration restored

[7/8] Clear cache
✓ Cache cleared

[8/8] Start site
✓ Site started

═══════════════════════════════════════════════════════════════
  Rollback Complete
═══════════════════════════════════════════════════════════════

Site: https://example.com
Status: Online
Rollback time: 2 minutes 15 seconds

Next steps:
  1. Verify site functionality
  2. Check error logs
  3. Notify team
```

### Step 3: Verify Site

Verify site is functioning correctly:

```bash
pl rollback verify avc
```

Verification checks:
```
═══════════════════════════════════════════════════════════════
  Post-Rollback Verification: avc
═══════════════════════════════════════════════════════════════

Site Health:
  ✓ Site accessible (HTTP 200)
  ✓ Database connection
  ✓ Redis connection
  ✓ File system accessible
  ✓ Cron functional

Content Integrity:
  ✓ User count: 245 (expected)
  ✓ Node count: 1,234 (expected)
  ✓ Files accessible: 1,856 (expected)

Performance:
  ✓ Response time: 245ms (normal)
  ✓ Database queries: 15 (normal)
  ✓ Cache hit rate: 95% (good)

Configuration:
  ✓ Configuration in sync
  ✓ Production mode enabled
  ✓ Security settings correct

═══════════════════════════════════════════════════════════════
  Verification: PASSED ✓
═══════════════════════════════════════════════════════════════

Site is healthy and functioning normally.
```

## Rollback Scenarios

### Scenario 1: Failed Deployment

**Symptom:** Deployment completed but site is broken

```bash
# List rollback points
pl rollback list avc

# Rollback to pre-deployment state
pl rollback execute avc prod

# Verify
pl rollback verify avc
```

### Scenario 2: Bad Update

**Symptom:** Security update caused issues

```bash
# Rollback to before update
pl rollback execute avc prod

# Verify site works
pl rollback verify avc

# Investigate update issues
pl doctor
```

### Scenario 3: Configuration Problem

**Symptom:** Configuration import broke site

```bash
# Quick rollback
pl rollback execute avc prod

# Verify configuration
pl rollback verify avc

# Fix configuration issues before redeploying
```

### Scenario 4: Database Corruption

**Symptom:** Database issues after deployment

```bash
# Rollback database only (faster)
pl restore -b avc

# Or full rollback
pl rollback execute avc prod

# Verify database integrity
pl rollback verify avc
```

## Automatic Prompt After Failed Deployment

When a deployment fails, NWP automatically prompts for rollback:

```
═══════════════════════════════════════════════════════════════
  Deployment Failed
═══════════════════════════════════════════════════════════════

ERROR: Configuration import failed

Rollback available:
  Point: 2026-01-14 14:30:22 (2 hours ago)
  Commit: a1b2c3d4

Rollback now? [Y/n]: y

Rolling back...
✓ Rollback complete (2 minutes 15 seconds)

Site restored to working state.
```

## Rollback Point Management

### List All Rollback Points

```bash
# All sites
pl rollback list

# Specific site
pl rollback list avc

# Show details
pl rollback list avc --verbose
```

### Cleanup Old Rollback Points

Remove old rollback points to free disk space:

```bash
# Keep last 5 rollback points (default)
pl rollback cleanup

# Keep last 3
pl rollback cleanup --keep=3

# Keep last 10
pl rollback cleanup --keep=10

# Cleanup specific site
pl rollback cleanup avc --keep=5
```

## Rollback Point Storage

Rollback points are stored in:
```
sitebackups/avc/rollback/
├── 20260114T143022/
│   ├── database.sql
│   ├── files.tar.gz
│   ├── config/
│   └── metadata.yml
├── 20260113T091510/
└── ...
```

Metadata includes:
```yaml
# metadata.yml
timestamp: 2026-01-14T14:30:22Z
commit: a1b2c3d4
environment: production
database_size: 245MB
files_size: 1.2GB
deployment_type: stg2prod
status: healthy
```

## Best Practices

### Pre-Deployment

- [ ] Verify rollback point exists
- [ ] Test rollback in staging first
- [ ] Document deployment changes
- [ ] Schedule maintenance window
- [ ] Notify team of deployment

### During Deployment

- [ ] Monitor deployment progress
- [ ] Watch for errors in logs
- [ ] Test critical functionality immediately
- [ ] Have rollback command ready

### Post-Deployment

- [ ] Verify all functionality
- [ ] Check error logs
- [ ] Monitor performance
- [ ] Keep rollback point for 24-48 hours
- [ ] Document any issues

### Rollback Decision Criteria

**Rollback if:**
- Site is completely broken
- Critical functionality lost
- Data corruption detected
- Security vulnerability introduced
- Performance severely degraded

**Don't rollback if:**
- Minor visual issues (fixable with hotfix)
- Non-critical feature broken
- Known issue with workaround
- Issue affects <5% of users

## Recovery Time Objectives (RTO)

| Scenario | Target RTO | Actual (Typical) |
|----------|-----------|------------------|
| Database rollback only | 2 minutes | 1-2 minutes |
| Full rollback (DB + files) | 5 minutes | 3-5 minutes |
| Rollback + verification | 10 minutes | 5-10 minutes |
| Complex rollback | 15 minutes | 10-15 minutes |

## Troubleshooting

### Rollback Point Not Found

**Symptom:**
```
ERROR: No rollback point found for avc
```

**Solution:**
- Check backup directory: `ls sitebackups/avc/rollback/`
- Create manual backup: `pl backup avc`
- Use restore instead: `pl restore avc`

### Rollback Fails - Disk Space

**Symptom:**
```
ERROR: Insufficient disk space for rollback
```

**Solution:**
```bash
# Check disk space
df -h

# Cleanup old rollback points
pl rollback cleanup --keep=3

# Free up space
pl delete old-unused-sites
```

### Rollback Incomplete

**Symptom:**
Site partially restored but not working

**Solution:**
```bash
# Complete the rollback manually
ddev import-db --src=sitebackups/avc/rollback/.../database.sql
ddev drush cr
ddev drush cim -y

# Or try full restore
pl restore avc
```

## Related Commands

- [backup](../reference/commands/backup.md) - Create manual backups
- [restore](../reference/commands/restore.md) - Restore from backups
- [dev2stg](../reference/commands/dev2stg.md) - Deploy to staging
- [stg2prod](../reference/commands/stg2prod.md) - Deploy to production (creates rollback points)

## See Also

- [Disaster Recovery](./disaster-recovery.md) - Complete disaster recovery procedures
- [Production Deployment](./production-deployment.md) - Safe deployment practices
- [Backup Implementation](../reference/backup-implementation.md) - Backup system architecture
