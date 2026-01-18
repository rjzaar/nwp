# security

Check for and apply security updates to Drupal sites.

## Overview

The `security` command manages Drupal security updates, including checking for vulnerabilities, applying updates, and running security audits. It integrates with Drupal's security advisories and Composer's audit functionality.

## Usage

```bash
pl security <command> [options] <sitename>
```

## Commands

| Command | Description |
|---------|-------------|
| `check <sitename>` | Check for security updates |
| `update <sitename>` | Apply security updates |
| `audit <sitename>` | Run full security audit |

## Options

| Flag | Description |
|------|-------------|
| `-h, --help` | Show help message |
| `-d, --debug` | Enable debug output |
| `-y, --yes` | Auto-confirm updates |
| `--auto` | Auto-apply and test (with update) |
| `--notify` | Send notification on completion |
| `--all` | Check/update all sites |

## Examples

### Check for updates
```bash
pl security check nwp
```

### Apply updates
```bash
pl security update nwp
```

### Auto-apply, test, and deploy if tests pass
```bash
pl security update --auto nwp
```

### Check all sites
```bash
pl security check --all
```

### Full security audit
```bash
pl security audit nwp
```

## Security Check

The `check` command examines:

1. **Drupal Security Advisories**:
   - Runs `drush pm:security`
   - Checks for SA-CORE and SA-CONTRIB advisories
   - Reports any security updates available

2. **Composer Vulnerabilities**:
   - Runs `composer audit`
   - Checks PHP dependencies for known vulnerabilities
   - Reports packages with security issues

## Security Update

The `update` command process:

1. **Pre-update Backup**: Creates automatic backup
2. **Update Packages**: `composer update drupal/* --with-dependencies`
3. **Database Updates**: `drush updb -y`
4. **Cache Clear**: `drush cr`
5. **Config Export**: `drush cex -y` (if needed)
6. **Optional Testing**: Runs tests if `--auto` flag used

### Auto Mode

With `--auto` flag:
- Applies updates automatically
- Runs test suite
- Reports test results
- Suggests deployment if tests pass
- Suggests rollback if tests fail

## Security Audit

The `audit` command checks:

### File Permissions
- Verifies settings.php is 444 or 440
- Warns if permissions are too permissive

### Development Modules
- Checks for enabled dev modules:
  - devel
  - webprofiler
  - kint
  - stage_file_proxy
- Warns if found in production

### Error Display Settings
- Checks error_level configuration
- Warns if verbose or all errors displayed

### Exposed Sensitive Files
- Checks webroot for:
  - .env
  - .secrets.yml
  - composer.lock
- Warns if sensitive files are exposed

## Automation

Add to crontab for daily security checks:

```bash
0 6 * * * /path/to/nwp/pl security check --all --notify
```

This runs at 6 AM daily and sends notifications if issues found.

## Check All Sites

With `--all` flag:
- Reads sites from nwp.yml
- Checks each site directory (sites/ or root)
- Reports issues found per site
- Provides summary of total sites and issues

## Related Commands

- [backup.sh](backup.md) - Create backups before updates
- [test.sh](test.md) - Run tests after security updates
- [rollback.sh](rollback.md) - Rollback if updates cause issues
- [security-check.sh](security-check.md) - HTTP security headers check

## See Also

- Drupal Security Advisories: https://www.drupal.org/security
- Composer Audit: https://getcomposer.org/doc/03-cli.md#audit
- Security best practices documentation
