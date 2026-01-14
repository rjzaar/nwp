# avc-moodle-sync

**Last Updated:** 2026-01-14

Manually trigger role and cohort synchronization between AVC and Moodle sites.

## Synopsis

```bash
pl avc-moodle-sync <avc-site> <moodle-site> [OPTIONS]
```

## Description

Manually initiates synchronization of user roles and cohort memberships from an AVC (OpenSocial) site to a Moodle site. This command is used to immediately sync changes without waiting for automatic scheduled synchronization.

The synchronization process:
- Reads guild (group) memberships from AVC
- Maps AVC guilds to Moodle cohorts
- Assigns users to appropriate cohorts in Moodle
- Applies role-based permissions based on cohort membership
- Updates sync statistics and timestamps

This command requires the custom `avc_moodle_sync` Drupal module to be installed and enabled on the AVC site.

## Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `avc-site` | Yes | Name of the AVC/OpenSocial site (source) |
| `moodle-site` | Yes | Name of the Moodle site (destination) |

## Options

| Option | Description | Default |
|--------|-------------|---------|
| `-h, --help` | Show help message and exit | - |
| `-d, --debug` | Enable debug output | false |
| `--full` | Full sync (all users and guilds) | false |
| `--guild=NAME` | Sync specific guild only | - |
| `--user=ID` | Sync specific user only | - |
| `--dry-run` | Show what would be synced without doing it | false |
| `-v, --verbose` | Verbose output showing each operation | false |

## Examples

### Full Synchronization

```bash
pl avc-moodle-sync avc ss --full
```

Synchronizes all users in all guilds from AVC to Moodle.

### Sync Specific Guild

```bash
pl avc-moodle-sync avc ss --guild=web-dev
```

Synchronizes only members of the "web-dev" guild.

### Sync Specific User

```bash
pl avc-moodle-sync avc ss --user=123
```

Synchronizes only the user with ID 123's guild memberships.

### Dry Run

```bash
pl avc-moodle-sync avc ss --full --dry-run
```

Shows what would be synchronized without making any changes. Useful for testing and verification.

### Verbose Sync

```bash
pl avc-moodle-sync avc ss --full --verbose
```

Displays detailed output of each sync operation.

## Sync Modes

### Full Sync (`--full`)

Synchronizes all users across all guilds:
- Reads all guilds from AVC
- Reads all users in each guild
- Creates or updates cohorts in Moodle
- Assigns users to cohorts
- Removes users no longer in guilds

**Use When:**
- Initial setup after installation
- After bulk user imports
- After major guild restructuring
- Recovery from sync errors

**Performance:** Can take several minutes for large user bases.

### Guild Sync (`--guild=NAME`)

Synchronizes only members of a specific guild:
- Reads specified guild from AVC
- Reads users in that guild
- Updates or creates matching cohort in Moodle
- Assigns/removes users for this cohort only

**Use When:**
- A specific guild has membership changes
- Testing sync for one guild
- Guild was just created or restructured

**Performance:** Fast, typically completes in seconds.

### User Sync (`--user=ID`)

Synchronizes only a specific user's guild memberships:
- Reads all guilds for specified user
- Updates user's cohort assignments in Moodle
- Removes user from cohorts they left

**Use When:**
- Single user joins/leaves guilds
- User profile needs immediate sync
- Testing sync for one user

**Performance:** Very fast, completes in under a second.

## Sync Process

### Step 1: Validation
Verifies both sites exist and are accessible, and confirms the sync module is enabled.

### Step 2: Data Collection
Queries AVC database for:
- Guild definitions
- User memberships
- Guild metadata (name, description, roles)

### Step 3: Cohort Management
In Moodle:
- Creates cohorts for new guilds
- Updates cohort metadata
- Archives cohorts for deleted guilds

### Step 4: User Assignment
For each user:
- Adds to new cohorts
- Removes from old cohorts
- Updates role assignments
- Records sync timestamp

### Step 5: Verification
- Counts synchronized users
- Records sync statistics
- Updates last sync timestamp
- Reports any errors or conflicts

### Step 6: Status Display
Shows updated integration status via `avc_moodle_display_status`.

## Output

### Standard Mode

```bash
pl avc-moodle-sync avc ss --full
```

```
================================================================================
AVC-Moodle Sync
================================================================================
AVC Site: avc
Moodle Site: ss
Mode: full

[1/5] Validating sites
  ✓ AVC site validated
  ✓ Moodle site validated

[2/5] Checking sync module status
  ✓ avc_moodle_sync module is enabled

[3/5] Running synchronization
  Syncing all users and guilds...
  ✓ Processed 5 guilds
  ✓ Synchronized 247 users
  ℹ 3 users added to cohorts
  ℹ 1 user removed from cohorts

[4/5] Synchronization completed in 8s

[5/5] Updated integration status

Updated integration status:
[Integration status dashboard from avc-moodle-status]
```

### Verbose Mode

```bash
pl avc-moodle-sync avc ss --guild=web-dev --verbose
```

```
================================================================================
AVC-Moodle Sync
================================================================================
AVC Site: avc
Moodle Site: ss
Mode: guild (web-dev)

[1/5] Validating sites
  ✓ AVC site validated
  ✓ Moodle site validated

[2/5] Checking sync module status
  ✓ avc_moodle_sync module is enabled

[3/5] Running synchronization
  Syncing guild: web-dev

  Guild: web-dev
    Members: 23
    Cohort ID: 42
    Cohort Name: AVC - Web Development

  User sync operations:
    ✓ john.doe (ID: 156) → Added to cohort 42
    ✓ jane.smith (ID: 89) → Already in cohort 42
    ℹ bob.jones (ID: 134) → Removed from cohort 42
    ✓ alice.wong (ID: 201) → Added to cohort 42

  Summary:
    Added: 2
    Removed: 1
    Unchanged: 20
    Total: 23

[4/5] Synchronization completed in 2s

[5/5] Updated integration status
```

### Dry Run Mode

```bash
pl avc-moodle-sync avc ss --user=123 --dry-run
```

```
================================================================================
AVC-Moodle Sync
================================================================================
AVC Site: avc
Moodle Site: ss
Mode: user (123)
⚠ DRY RUN MODE - No changes will be made

[1/5] Validating sites
  ✓ AVC site validated
  ✓ Moodle site validated

[2/5] Checking sync module status
  ✓ avc_moodle_sync module is enabled

[3/5] Running synchronization (DRY RUN)
  Syncing user: 123

  User: john.doe (ID: 123)
    Current guilds: web-dev, content-team
    Current cohorts: 42, 67

  Would perform:
    ✓ Add to cohort 42 (web-dev) - Already present
    ✓ Add to cohort 67 (content-team) - Already present
    ✗ Remove from cohort 89 (design-team) - User left guild

  Summary (DRY RUN):
    Would add: 0
    Would remove: 1
    Would leave unchanged: 2

[4/5] Synchronization completed in 1s

⚠ DRY RUN completed - no changes were made
Run without --dry-run to apply changes
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Synchronization completed successfully |
| 1 | Site validation failed |
| 1 | Sync module not enabled |
| 1 | Sync command failed (see error output) |

## Prerequisites

### AVC Site
- `avc_moodle_sync` Drupal module must be installed and enabled
- OAuth2 integration must be configured
- Site must be accessible via DDEV

### Moodle Site
- OAuth2 issuer must be configured
- `local_cohortrole` plugin recommended (for automatic role assignment)
- Site must be accessible via DDEV

### System
- Drush available in AVC site
- Moodle CLI tools available
- Database access for both platforms

## Guild to Cohort Mapping

Guilds in AVC are mapped to Cohorts in Moodle using this convention:

| AVC Guild | Moodle Cohort |
|-----------|---------------|
| `web-dev` | `AVC - Web Development` |
| `content-team` | `AVC - Content Team` |
| `administrators` | `AVC - Administrators` |

The mapping:
- Preserves guild machine names as cohort IDs
- Uses guild display names for cohort names
- Prefixes cohorts with "AVC -" for clarity
- Maintains sync metadata in both systems

## Troubleshooting

### Sync Module Not Enabled

**Symptom:**
```
avc_moodle_sync module is not enabled
Run: ddev drush en -y avc_moodle_sync
```

**Solution:**
```bash
cd sites/avc
ddev drush en -y avc_moodle_sync
```

If the module doesn't exist, it needs to be installed first (custom module pending development).

### User Not Found

**Symptom:**
```
Error: User ID 123 not found in AVC
```

**Solution:**
1. Verify the user ID exists: `ddev drush user:information 123`
2. Check for typos in the user ID
3. Confirm the user hasn't been deleted

### Guild Not Found

**Symptom:**
```
Error: Guild 'web-dev' not found
```

**Solution:**
1. List available guilds: `ddev drush avc-guilds:list`
2. Check for typos in the guild name
3. Use the guild machine name, not the display name

### Cohort Creation Failed

**Symptom:**
```
Error: Failed to create cohort in Moodle
```

**Solution:**
1. Check Moodle permissions (admin access required)
2. Verify Moodle CLI tools are working: `cd sites/ss && ddev exec php admin/cli/list_cohorts.php`
3. Check Moodle database connectivity
4. Review Moodle error logs

### Sync Takes Too Long

**Symptom:** Full sync runs for more than 10 minutes

**Solution:**
1. Use `--guild` option to sync incrementally
2. Schedule automated syncs for off-peak hours
3. Consider increasing PHP memory limit
4. Check database query performance
5. Enable query caching in both platforms

## Performance Considerations

### Sync Duration Estimates

| Sync Type | Users | Guilds | Est. Time |
|-----------|-------|--------|-----------|
| User sync | 1 | 1-5 | 1-2s |
| Guild sync | 10-50 | 1 | 2-5s |
| Guild sync | 100-500 | 1 | 10-30s |
| Full sync | 100 | 10 | 30-60s |
| Full sync | 1000 | 50 | 5-10m |

### Optimization Tips

**For large user bases:**
1. Sync incrementally by guild
2. Use `--user` sync for individual updates
3. Schedule full syncs during maintenance windows
4. Enable database query caching
5. Use Redis for session management

**For frequent syncs:**
1. Set up automated cron jobs
2. Use event-based triggers (when modules support it)
3. Monitor sync logs for performance degradation

## Automation

### Cron Job Example

Sync all guilds nightly at 2 AM:
```bash
0 2 * * * /usr/local/bin/pl avc-moodle-sync avc ss --full >> /var/log/nwp/avc-moodle-sync.log 2>&1
```

Sync specific high-activity guild every hour:
```bash
0 * * * * /usr/local/bin/pl avc-moodle-sync avc ss --guild=web-dev >> /var/log/nwp/avc-moodle-sync-web-dev.log 2>&1
```

## Related Commands

- [avc-moodle-setup](avc-moodle-setup.md) - Initial integration setup
- [avc-moodle-status](avc-moodle-status.md) - Check integration health
- [avc-moodle-test](avc-moodle-test.md) - Test integration functionality

## See Also

- AVC-Moodle Integration Library: `/home/rob/nwp/lib/avc-moodle.sh`
- Moodle Cohorts Documentation: https://docs.moodle.org/en/Cohorts
- Drupal Group Module: https://www.drupal.org/project/group
- OAuth2 User Provisioning Best Practices
