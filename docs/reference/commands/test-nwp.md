# test-nwp

> **DEPRECATED:** This command has been replaced by `pl verify --run` as part of the layered verification system (P50). This documentation is maintained for historical reference only.
>
> **Use instead:** `pl verify --run` - See [verify.md](verify.md) for current documentation.

**Status:** DEPRECATED (as of v0.26.0)
**Last Updated:** 2026-01-16
**Replaced By:** [verify.md](verify.md)

Comprehensive end-to-end test suite for NWP that validates all core functionality, workflows, and infrastructure components across 22+ test categories.

## Synopsis

```bash
./scripts/commands/test-nwp.sh [OPTIONS]
```

## Description

The `test-nwp` script is the master test suite for the NWP project. It performs comprehensive end-to-end testing of all NWP functionality by creating real test sites, executing operations, and validating results. This is the primary quality assurance tool used before releases and for continuous integration.

Unlike `test.sh` which tests individual Drupal sites, `test-nwp` validates the NWP tooling itself including installation, backup/restore, deployment, git operations, scheduling, and live server provisioning.

The test suite is designed to be non-destructive, using isolated test sites with unique names, and includes automatic cleanup functionality.

## Arguments

None. The script creates its own test sites and cleans them up afterward.

## Options

| Option | Description |
|--------|-------------|
| `--skip-cleanup` | Don't delete test sites after completion |
| `--verbose` | Show detailed output from all commands |
| `--podcast` | Include optional podcast infrastructure tests |
| `-h, --help` | Show help message |

## Examples

### Run Full Test Suite

Standard test run with automatic cleanup:
```bash
./scripts/commands/test-nwp.sh
```

### Keep Test Sites for Inspection

Run tests but preserve test sites for debugging:
```bash
./scripts/commands/test-nwp.sh --skip-cleanup
```

### Verbose Output

Show all command output for debugging:
```bash
./scripts/commands/test-nwp.sh --verbose
```

### Include Podcast Tests

Run with optional podcast infrastructure tests:
```bash
./scripts/commands/test-nwp.sh --podcast
```

### Pre-Release Validation

Complete validation before creating a release tag:
```bash
./scripts/commands/test-nwp.sh --verbose
```

## Test Categories

The test suite runs 22+ categories of tests organized by functionality:

### Test 1: Installation
- Creates test site from recipe
- Validates directory structure
- Checks DDEV configuration
- Verifies Drush functionality

### Test 1b: Environment Variable Generation
- Validates `.env` file creation
- Checks Vortex integration
- Verifies service configuration (Redis, Solr)
- Validates DDEV config generation

### Test 2: Backup Functionality
- Creates full site backups
- Validates backup directory structure
- Checks backup file integrity

### Test 3: Restore Functionality
- Restores from full backups
- Validates database restoration
- Verifies files restoration

### Test 3b: Database-Only Backup/Restore
- Creates database-only backups
- Restores from DB-only backups
- Validates selective restoration

### Test 4: Copy Functionality
- Full site copy with database
- Files-only copy operations
- Validates copied site integrity

### Test 5: Dev/Prod Mode Switching
- Enables development mode
- Validates dev modules enabled
- Switches to production mode
- Verifies dev modules disabled

### Test 6: Deployment (dev2stg)
- Deploys development to staging
- Validates staging environment
- Checks configuration import

### Test 7: Testing Infrastructure
- Validates testos.sh functionality
- Runs PHPStan analysis
- Executes CodeSniffer checks

### Test 8: Site Verification
- Health checks on all created sites
- Validates DDEV status
- Checks Drush functionality

### Test 8b: Delete Functionality
- Deletes sites with backup
- Validates backup preservation
- Tests keep-backups flag

### Test 9: Script Validation
- Checks all scripts exist
- Validates executability
- Verifies help text

### Test 10: Deployment Scripts
- Tests stg2prod validation
- Tests prod2stg validation
- Validates dry-run mode

### Test 11: YAML Library Functions
- Validates YAML library
- Tests site registration
- Checks integration tests

### Test 12: Linode Production Testing
- Provisions test Linode instance (if API token available)
- Tests SSH connectivity
- Validates server setup
- Cleans up test instances

### Test 13: Input Validation & Error Handling
- Tests sitename validation
- Validates path traversal rejection
- Checks special character rejection
- Validates required arguments

### Test 14: Git Backup Features
- Validates git library
- Tests backup flags
- Checks git functions

### Test 15: Scheduling Features
- Tests schedule.sh commands
- Validates cron integration
- Checks schedule listing

### Test 16: CI/CD & Testing Templates
- Validates Docker test templates
- Checks Behat configuration
- Verifies code quality configs
- Tests GitLab CI templates

### Test 17: Unified CLI Wrapper
- Tests pl command
- Validates completion script
- Checks command routing

### Test 18: Database Sanitization
- Validates sanitize library
- Tests sanitization functions
- Checks backup integration

### Test 19: Rollback Capability
- Tests rollback library
- Validates rollback functions
- Checks rollback listing

### Test 20: Remote Site Support
- Tests remote library
- Validates remote functions
- Checks SSH operations

### Test 21: Live Server & Security Scripts
- Tests live.sh provisioning
- Validates security.sh checks
- Checks server types

### Test 22: Script Syntax Validation
- Validates bash syntax for all scripts
- Checks library files
- Verifies function definitions

### Test 22b: Library Loading and Function Tests
- Tests library sourcing
- Validates function existence
- Checks function behavior

### Test 22c: New Command Help Tests
- Tests pl command help
- Validates command options
- Checks help text

### Test 23: Podcast Infrastructure (Optional)
- Tests podcast deployment (with --podcast flag)
- Validates audio processing
- Checks podcast templates

## Output

### Standard Output

Color-coded test results with progress indicators:

```
═══════════════════════════════════════════════════════════════
  NWP Comprehensive Test Suite
═══════════════════════════════════════════════════════════════

Log file: .logs/test-nwp-20260114-143022.log

ℹ Cleaning up any existing test sites from previous runs...
ℹ Pre-configuring DDEV hostnames...

═══════════════════════════════════════════════════════════════
  Test 1: Installation
═══════════════════════════════════════════════════════════════

TEST: Install test site
✓ PASSED

TEST: Site directory created
✓ PASSED

...

═══════════════════════════════════════════════════════════════
  Test Results Summary
═══════════════════════════════════════════════════════════════

Total tests run:    147
Tests passed:       145
Tests with warnings:2
Tests failed:       0

Success rate: 100% (passed + expected warnings)

✓ All tests passed!
```

### Log File

Detailed log saved to `.logs/test-nwp-<timestamp>.log` containing:
- Full command output
- Timestamps for each test
- Debug information
- Error details

### Test Status Indicators

- `✓` Green checkmark - Test passed
- `✗` Red X - Test failed
- `!` Yellow exclamation - Warning (expected behavior)
- `ℹ` Blue info - Informational message

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | All tests passed (warnings allowed) |
| 1 | One or more tests failed unexpectedly |

## Prerequisites

### Required Tools

- DDEV installed and running
- Composer available
- Git installed
- Bash 4.0 or later
- sudo access (for DDEV hostname configuration)

### System Requirements

- Minimum 8GB RAM (16GB recommended)
- 20GB free disk space
- Active internet connection
- Docker running

### Configuration Files

- `cnwp.yml` must exist in project root
- `lib/` directory with all libraries
- `scripts/commands/` with all command scripts
- `templates/` directory for test templates

## Test Sites Created

The test suite creates several test sites with the prefix `test-nwp`:

- `sites/test-nwp` - Primary test site
- `sites/test-nwp_copy` - Copy functionality test
- `sites/test-nwp_files` - Files-only copy test
- `sites/test-nwp-stg` - Staging deployment test
- `sites/test-nwp1`, `test-nwp2`, etc. - Deletion tests

All test sites are automatically cleaned up unless `--skip-cleanup` is used.

## Performance

### Typical Run Time

- **Fast run** (no Linode tests): 15-20 minutes
- **Full run** (with Linode): 25-35 minutes
- **With --podcast**: +10 minutes

### Resource Usage

- **Disk**: ~5GB during testing
- **RAM**: ~4GB for DDEV containers
- **CPU**: 2-4 cores recommended

## Success Criteria

The test suite considers a run successful when:

1. **Pass rate ≥ 98%** - At least 98% of tests pass
2. **No unexpected failures** - All failures are expected warnings
3. **All critical paths work** - Install, backup, restore, copy, delete
4. **Libraries load correctly** - All shared libraries source without errors
5. **Scripts have valid syntax** - No bash syntax errors

### Expected Warnings

Some tests are expected to produce warnings (not failures):

- **dev2stg without staging site** - Staging doesn't exist yet
- **Files-only copy to non-existent destination** - Expected to fail
- **Non-existent site operations** - Negative tests validating error handling
- **Dev module checks on fresh installs** - May not have dev modules yet

## Cleanup Behavior

### Automatic Cleanup (Default)

When tests complete, you're prompted:
```
Delete test sites? (y/N)
```

If you answer 'y':
1. Stops all test DDEV sites
2. Removes test site directories from `sites/`
3. Removes test backups from `sitebackups/`
4. Removes test-nwp entries from `cnwp.yml`

### Skip Cleanup Mode

With `--skip-cleanup`:
- All test sites preserved
- Backups kept for inspection
- cnwp.yml entries remain
- Manual cleanup required

### Manual Cleanup

If you skip cleanup, manually remove test sites:
```bash
# Stop test sites
cd sites/test-nwp && ddev stop && cd ../..
cd sites/test-nwp_copy && ddev stop && cd ../..

# Remove directories
rm -rf sites/test-nwp*

# Remove backups
rm -rf sitebackups/test-nwp*

# Edit cnwp.yml to remove test-nwp entries
```

## Integration with Release Process

This test suite is mandatory before creating release tags:

### Pre-Release Checklist

1. Run full test suite:
   ```bash
   ./scripts/commands/test-nwp.sh
   ```

2. Verify 98%+ pass rate
3. Review any warnings in log file
4. Check that all core workflows pass
5. Validate syntax checks pass

See [CLAUDE.md Release Tag Process](../../CLAUDE.md#release-tag-process) for complete release workflow.

## Troubleshooting

### "DDEV hostname configuration failed"

**Symptom:** Warning about hostname configuration requiring sudo

**Solution:** Run manually:
```bash
sudo ddev hostname test-nwp.ddev.site 127.0.0.1
```

### "Site installation failed"

**Symptom:** Test 1 fails with installation errors

**Solution:**
1. Check DDEV is running: `ddev version`
2. Verify internet connection (downloads composer packages)
3. Check disk space: `df -h`
4. Review log file for specific errors

### "Drush is not functional"

**Symptom:** Tests show drush warnings

**Solution:** This is expected on some profiles (OpenSocial has known drush issues). Tests account for this with warnings, not failures.

### Test Sites Not Cleaned Up

**Symptom:** Old test sites remain from previous runs

**Solution:** Manual cleanup:
```bash
# Clean up test sites
for site in sites/test-nwp*; do
  cd "$site" && ddev stop
  cd ../..
done
rm -rf sites/test-nwp*

# Clean up backups
rm -rf sitebackups/test-nwp*
```

### "AWK produced empty output"

**Symptom:** Errors during cnwp.yml manipulation

**Solution:** This is a protection mechanism. Check if `cnwp.yml` has duplicate test-nwp entries. The script protects against corrupting the file.

### Low Pass Rate (<98%)

**Symptom:** More failures than expected

**Solution:**
1. Review log file: `.logs/test-nwp-*.log`
2. Check for system resource issues
3. Verify all prerequisites are met
4. Run with `--verbose` for detailed output
5. Report unexpected failures as issues

### Linode Tests Skipped

**Symptom:** "Linode API token not found - skipping production tests"

**Solution:** This is expected if you haven't configured Linode API access. These tests are optional. To enable:
1. Add Linode API token to `.secrets.yml`
2. Run `./setup-ssh.sh` to generate SSH keys
3. Add SSH key to Linode Cloud Manager

## Notes

- Tests use isolated test sites with unique names to avoid conflicts
- Test recipe uses `goalgorilla/social_template:dev-master`
- Tests automatically skip Linode tests if credentials not available
- Negative tests (testing error conditions) are expected to "fail" gracefully
- The test suite is idempotent - can be run multiple times safely
- cnwp.yml is protected with multiple safeguards during cleanup

## See Also

- [test.md](test.md) - Test individual Drupal sites
- [run-tests.md](run-tests.md) - BATS unit/integration test runner
- [testos.md](testos.md) - OpenSocial-specific testing
- [CLAUDE.md](../../CLAUDE.md) - Release process and tag creation
- [ROADMAP.md](../../ROADMAP.md) - Future test coverage plans
- [CI/CD Documentation](../../testing/ci-cd-integration.md) - Integration with pipelines
