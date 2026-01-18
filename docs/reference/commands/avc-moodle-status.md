# avc-moodle-status

**Last Updated:** 2026-01-14

Display integration status and health check dashboard for AVC-Moodle SSO integration.

## Synopsis

```bash
pl avc-moodle-status <avc-site> <moodle-site>
```

## Description

Displays a comprehensive status dashboard showing the health and configuration of the OAuth2 Single Sign-On integration between an AVC (OpenSocial) site and a Moodle site.

This command provides at-a-glance monitoring of:
- SSO activation status
- OAuth2 endpoint health
- Last synchronization time
- Synced user and cohort counts
- Cache performance metrics
- Site URLs and connectivity

Use this command to verify integration health, troubleshoot issues, and monitor ongoing operations.

## Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `avc-site` | Yes | Name of the AVC/OpenSocial site |
| `moodle-site` | Yes | Name of the Moodle site |

## Options

| Option | Description | Default |
|--------|-------------|---------|
| `-h, --help` | Show help message and exit | - |
| `-d, --debug` | Enable debug output | false |

## Examples

### Basic Status Check

```bash
pl avc-moodle-status avc ss
```

Displays the integration status dashboard for the AVC and Moodle sites.

### Debug Mode

```bash
pl avc-moodle-status --debug avc ss
```

Shows detailed debug information along with the status dashboard.

## Output

The command displays a formatted dashboard with the following sections:

```
================================================================================
AVC-Moodle Integration Status
================================================================================

Sites:
  AVC Site:    avc (https://avc.example.com)
  Moodle Site: ss (https://ss.example.com)

SSO Status:
  Integration:  ✓ Enabled
  OAuth2:       ✓ Active
  Last Test:    2026-01-14 10:23:45

OAuth2 Endpoints:
  Authorize:    ✓ https://avc.example.com/oauth/authorize
  Token:        ✓ https://avc.example.com/oauth/token
  UserInfo:     ✓ https://avc.example.com/oauth/userinfo

Synchronization:
  Status:       ✓ Active
  Last Sync:    2026-01-14 09:15:30 (1h 8m ago)
  Synced Users: 247
  Synced Cohorts: 12

Performance:
  Cache Status: ✓ Enabled
  Cache Hit Rate: 94.2%
  Avg Response: 145ms

Configuration:
  Role Sync:    ✓ Enabled
  Badge Display: ✓ Enabled
  Token Lifetime: 300s (5 minutes)

Quick Actions:
  Test SSO:     pl avc-moodle-test avc ss
  Sync Now:     pl avc-moodle-sync avc ss
  Setup Again:  pl avc-moodle-setup avc ss

================================================================================
```

## Status Indicators

### Integration Status

| Indicator | Meaning |
|-----------|---------|
| ✓ Enabled | Integration is configured and active |
| ✗ Disabled | Integration is not configured |
| ⚠ Partial | Integration partially configured (manual steps needed) |

### OAuth2 Health

| Indicator | Meaning |
|-----------|---------|
| ✓ Active | All OAuth2 endpoints responding correctly |
| ⚠ Degraded | Some endpoints responding slowly or intermittently |
| ✗ Failed | OAuth2 endpoints not accessible |

### Synchronization Status

| Indicator | Meaning |
|-----------|---------|
| ✓ Active | Recent sync completed successfully |
| ⚠ Stale | No sync in last 24 hours |
| ✗ Failed | Last sync attempt failed |

## Dashboard Sections

### Sites Section
Shows the configured site names and their URLs. Verifies that both sites are accessible via HTTPS.

### SSO Status Section
Displays whether the integration is enabled and when OAuth2 was last tested successfully.

### OAuth2 Endpoints Section
Lists the three critical OAuth2 endpoints and their reachability status:
- **Authorize Endpoint** - Used for login redirects
- **Token Endpoint** - Used for token exchange
- **UserInfo Endpoint** - Used for user profile retrieval

### Synchronization Section
Shows statistics about role and cohort synchronization:
- **Status** - Whether sync is functioning
- **Last Sync** - Timestamp and relative time of last sync
- **Synced Users** - Count of users synchronized
- **Synced Cohorts** - Count of cohorts (groups) synchronized

### Performance Section
Reports cache and response time metrics:
- **Cache Status** - Whether Redis/cache is enabled
- **Cache Hit Rate** - Percentage of requests served from cache
- **Avg Response** - Average OAuth2 response time

### Configuration Section
Shows enabled features and settings:
- **Role Sync** - Automatic role synchronization status
- **Badge Display** - Badge display on profiles status
- **Token Lifetime** - OAuth2 token expiration time

### Quick Actions Section
Provides command shortcuts for common operations.

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Status displayed successfully |
| 1 | AVC site validation failed |
| 1 | Moodle site validation failed |
| 1 | Could not retrieve status information |

## Prerequisites

- Both AVC and Moodle sites must be installed
- Sites must have been configured via `avc-moodle-setup`
- DDEV must be running for both sites (for detailed metrics)

## Information Sources

The status dashboard retrieves information from:

### nwp.yml Configuration
- Integration enabled/disabled status
- Site URLs and names
- Feature flags (role_sync, badge_display)

### AVC Site (via Drush)
- Simple OAuth module status
- OAuth2 key existence
- Last sync timestamps (when custom modules installed)

### Moodle Site (via CLI)
- OAuth2 issuer configuration
- Cohort and enrollment counts
- Authentication plugin status

### HTTP Checks
- OAuth2 endpoint reachability
- Response times
- SSL/TLS status

### Cache/Database
- Sync statistics (when custom modules installed)
- Performance metrics (when custom modules installed)

## Troubleshooting

### Integration Shows as Disabled

**Symptom:**
```
Integration:  ✗ Disabled
```

**Solution:**
1. Run setup: `pl avc-moodle-setup avc ss`
2. Check nwp.yml for correct configuration
3. Verify both sites exist and are accessible

### OAuth2 Endpoints Failing

**Symptom:**
```
Authorize:    ✗ https://avc.example.com/oauth/authorize
```

**Solution:**
1. Verify AVC site is running: `ddev describe -p avc`
2. Check Simple OAuth is enabled: `cd sites/avc && ddev drush pm:list --status=enabled | grep oauth`
3. Test endpoint manually: `curl -k https://avc.ddev.site/oauth/authorize`
4. Check Apache/Nginx error logs

### Stale Synchronization

**Symptom:**
```
Last Sync:    2026-01-13 09:15:30 (25h ago)
Status:       ⚠ Stale
```

**Solution:**
1. Run manual sync: `pl avc-moodle-sync avc ss --full`
2. Check cron jobs: `crontab -l`
3. Verify custom modules are installed and enabled
4. Check sync error logs in site directories

### No Sync Statistics Available

**Symptom:**
```
Synchronization:
  Status:       ℹ Not Available
  Last Sync:    Never
```

**Solution:** This is normal if custom AVC-Moodle sync modules are not yet installed. Basic OAuth2 SSO will still work, but automated synchronization features are pending module installation.

### Cache Metrics Unavailable

**Symptom:**
```
Performance:
  Cache Status: ℹ Not Configured
```

**Solution:**
1. Enable Redis for AVC: Add to settings.php
2. Install Redis module: `ddev composer require drupal/redis`
3. Clear cache: `ddev drush cr`

## Related Commands

- [avc-moodle-setup](avc-moodle-setup.md) - Initial integration setup
- [avc-moodle-sync](avc-moodle-sync.md) - Manually trigger synchronization
- [avc-moodle-test](avc-moodle-test.md) - Run integration tests

## See Also

- AVC-Moodle Integration Library: `/home/rob/nwp/lib/avc-moodle.sh`
- OAuth2 Monitoring Best Practices
- Moodle Authentication Troubleshooting: https://docs.moodle.org/en/OAuth_2_authentication
