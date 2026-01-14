# dev2stg

**Status:** ACTIVE
**Last Updated:** 2026-01-14

Deploy development to staging with integrated testing, flexible database sourcing, and interactive TUI.

## Synopsis

```bash
pl dev2stg [OPTIONS] <sitename>
```

## Description

The `dev2stg` command deploys development code to a staging environment, complete with database synchronization, configuration management, automated testing, and production mode optimization. It provides an interactive TUI for selecting options or can run fully automated for CI/CD pipelines.

Key features:
- **Interactive TUI** - Select database source, test presets, and options
- **Multi-source database** - Choose from production, development, or custom backup
- **Integrated testing** - Run test suites with configurable presets
- **Auto-staging** - Creates staging site automatically if needed
- **Resumable** - Restart from any step if interrupted
- **Production-ready** - Configures site for production mode

## Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `sitename` | Yes | Base site name (e.g., `avc`, `nwp`) - staging site is `sitename-stg` |

## Options

| Option | Description | Default |
|--------|-------------|---------|
| `-h, --help` | Show help message | - |
| `-d, --debug` | Enable debug output | false |
| `-y, --yes` | Skip confirmation prompts (CI/CD mode) | false |
| `-s N, --step=N` | Resume from step N | - |

### Database Options

| Option | Description | Default |
|--------|-------------|---------|
| `--db-source SOURCE` | Database source: `auto`, `production`, `development`, `/path/file` | auto |
| `--fresh-backup` | Force fresh backup from production | false |
| `--dev-db` | Use development database | false |
| `--no-sanitize` | Skip database sanitization | false |

### Testing Options

| Option | Description |
|--------|-------------|
| `-t, --test SELECTION` | Test selection (see Test Presets below) |

**Test Presets:**
- `quick` - Fast syntax checks (PHPStan, PHPCS)
- `essential` - Core quality checks (PHPUnit, PHPStan, PHPCS)
- `functional` - Essential + Behat tests
- `full` - All tests (Unit, Functional, Static Analysis, Frontend)
- `security-only` - Security-focused tests
- `skip` - No tests

**Individual Test Types:**
- `phpunit` - PHP unit tests
- `behat` - Behavioral tests
- `phpstan` - Static analysis
- `phpcs` - Coding standards
- `eslint` - JavaScript linting
- `stylelint` - CSS linting
- `security` - Security checks
- `accessibility` - A11y tests

### Staging Options

| Option | Description | Default |
|--------|-------------|---------|
| `--create-stg` | Create staging site if missing | prompt |
| `--no-create-stg` | Fail if staging doesn't exist | false |
| `--preflight` | Run preflight checks only (no deployment) | false |

## Deployment Workflow

The deployment process follows these steps:

1. **State Detection & Preflight** - Validate environments and requirements
2. **Create Staging Site** - Auto-create `sitename-stg` if needed
3. **Export Configuration** - Export config from development
4. **Sync Files** - Copy codebase from dev to staging
5. **Restore/Sync Database** - Load database from selected source
6. **Composer Install** - Install dependencies with `--no-dev`
7. **Database Updates** - Run pending database updates
8. **Import Configuration** - Import config (with 3× retry)
9. **Set Production Mode** - Enable caching, aggregation
10. **Run Tests** - Execute selected test suite
11. **Display Staging URL** - Show staging site URL and login

## Examples

### Interactive Mode (Default)

```bash
# Launch interactive TUI
pl dev2stg avc
```

Shows interactive menu to select:
- Database source (auto/production/development/custom)
- Test preset (quick/essential/full/skip)
- Additional options

### Automated Deployment (CI/CD)

```bash
# Auto-deploy with essential tests
pl dev2stg -y -t essential avc

# Auto-deploy with specific tests
pl dev2stg -y -t phpunit,phpstan avc

# Quick deployment, skip tests
pl dev2stg -y -t skip avc
```

### Database Sourcing

```bash
# Use fresh production backup
pl dev2stg --fresh-backup avc

# Use development database
pl dev2stg --dev-db avc

# Use specific backup file
pl dev2stg --db-source=/path/to/backup.sql avc

# Auto-select best database source (default)
pl dev2stg avc
```

### Testing Options

```bash
# Quick syntax check before deployment
pl dev2stg -y -t quick avc

# Full test suite
pl dev2stg -y -t full avc

# Security tests only
pl dev2stg -y -t security-only avc

# Skip all tests
pl dev2stg -y -t skip avc
```

### Advanced Options

```bash
# Preflight checks only (dry-run)
pl dev2stg --preflight avc

# Resume from step 5
pl dev2stg -s 5 avc

# Create staging, fresh DB, full tests
pl dev2stg --create-stg --fresh-backup -t full avc
```

## Database Source Selection

### Auto (Default)

Automatically selects the best database source:
1. Production backup if available (< 24 hours old)
2. Development database if no recent backup
3. Prompts if ambiguous

### Production

Creates fresh backup from production server:
- **Pros**: Latest production data, real-world testing
- **Cons**: Slower (requires backup), may contain PII

### Development

Clones current development database:
- **Pros**: Fast, includes recent test data
- **Cons**: May not reflect production state

### Custom File

Use a specific backup file:
```bash
pl dev2stg --db-source=/path/to/backup.sql avc
```

## Test Presets

### Quick
**Duration:** ~30 seconds
- PHPStan (static analysis)
- PHPCS (coding standards)

**Use case:** Pre-commit checks, fast validation

### Essential
**Duration:** ~2-5 minutes
- PHPUnit (unit tests)
- PHPStan (static analysis)
- PHPCS (coding standards)

**Use case:** Regular deployments, merge requests

### Functional
**Duration:** ~5-10 minutes
- Essential tests +
- Behat (behavioral tests)

**Use case:** Feature deployments, pre-release testing

### Full
**Duration:** ~15-30 minutes
- Unit tests (PHPUnit)
- Functional tests (Behat)
- Static analysis (PHPStan)
- Coding standards (PHPCS)
- Frontend linting (ESLint, Stylelint)
- Security checks
- Accessibility tests

**Use case:** Major releases, production deployments

## Output

Interactive TUI shows real-time progress:

```
═══════════════════════════════════════════════════════════════
  Dev → Staging Deployment: avc
═══════════════════════════════════════════════════════════════

[1/11] State detection & preflight checks
✓ Development site exists: avc
✓ Prerequisites met

[2/11] Create staging site
✓ Staging site exists: avc-stg

[3/11] Export configuration from dev
✓ Configuration exported (234 files)

[4/11] Sync files from dev to staging
✓ Files synchronized (12,450 files)

[5/11] Restore/sync database
✓ Database restored from production (245 MB)

[6/11] Composer install --no-dev
✓ Dependencies installed

[7/11] Run database updates
✓ Database updated (3 updates applied)

[8/11] Import configuration (retry: 3×)
✓ Configuration imported successfully

[9/11] Set production mode
✓ Caching enabled, aggregation enabled

[10/11] Run tests: essential
  ✓ PHPUnit (15 tests, 42 assertions)
  ✓ PHPStan (Level 6, 0 errors)
  ✓ PHPCS (Drupal standards, 0 errors)

[11/11] Display staging URL
✓ Deployment complete

═══════════════════════════════════════════════════════════════
  Staging Ready
═══════════════════════════════════════════════════════════════

Staging URL: https://avc-stg.ddev.site
Login:       https://avc-stg.ddev.site/user/login

Next steps:
  1. Review staging site
  2. Run acceptance tests
  3. Deploy to production: pl stg2prod avc
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Deployment successful |
| 1 | Deployment failed |
| 2 | Missing required sitename argument |
| 3 | Development site not found |
| 4 | Preflight checks failed |
| 5 | Tests failed |

## Prerequisites

- **Development site** - `sitename` must exist and be running
- **DDEV** - Both dev and staging must use DDEV
- **Drush** - For database operations and config management
- **Test tools** - PHPUnit, PHPStan, etc. (auto-installed if missing)

## Troubleshooting

### Staging Site Not Found

**Symptom:**
```
ERROR: Staging site 'avc-stg' not found
```

**Solution:**
- Use `--create-stg` flag to auto-create
- Manually install: `pl install avc avc-stg`

### Configuration Import Fails

**Symptom:**
```
ERROR: Configuration import failed
```

**Solution:**
- Check for schema mismatches
- Review config files: `sites/avc/config/sync/`
- Try manual import: `ddev drush cim`
- Check logs: `ddev drush watchdog:show`

### Tests Fail

**Symptom:**
```
ERROR: 5 PHPUnit tests failed
```

**Solution:**
- Review test output
- Fix failing tests in development
- Use `--preflight` to validate before deploying
- Skip tests temporarily: `-t skip` (not recommended)

### Database Sync Fails

**Symptom:**
```
ERROR: Failed to restore database
```

**Solution:**
- Check database backup exists
- Verify production connection (if using `--fresh-backup`)
- Try different source: `--dev-db`
- Check disk space: `df -h`

## See Also

- [stg2prod](./stg2prod.md) - Deploy staging to production
- [backup](./backup.md) - Create backups
- [restore](./restore.md) - Restore from backups
- [status](./status.md) - Check site status
- [Deployment Guide](../../deployment/production-deployment.md) - Complete deployment workflow
