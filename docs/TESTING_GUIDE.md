# NWP Testing Guide

**Last Updated:** December 2024

## Table of Contents

- [Overview](#overview)
- [Test Script](#test-script)
- [Running Tests](#running-tests)
- [Test Coverage](#test-coverage)
- [Troubleshooting](#troubleshooting)

## Overview

The NWP project includes a comprehensive test script (`test-nwp.sh`) that validates all core functionality including installation, backup/restore, copying, deployment, and testing infrastructure.

## Test Script

### Location

```
/home/rob/nwp/test-nwp.sh
```

### Usage

```bash
# Run all tests
./test-nwp.sh

# Run tests and keep test sites for inspection
./test-nwp.sh --skip-cleanup

# Run tests with verbose output
./test-nwp.sh --verbose

# Show help
./test-nwp.sh --help
```

### Prerequisites

1. **DDEV installed and running**
2. **Sudo access** (for hostname configuration - will prompt once at start)
3. **Composer installed**
4. **Git installed**

### First-Time Setup

The test script will prompt for your sudo password once at the beginning to configure DDEV hostnames:

```bash
sudo ddev hostname test_nwp.ddev.site 127.0.0.1
```

This is required only once per test run.

## Test Coverage

### 1. Installation Tests

**What's tested:**
- Fresh site installation using `install.sh`
- Site directory creation
- DDEV container startup
- Drush installation and functionality

**Expected result:** 4/4 tests pass

**Example:**
```bash
✓ Install test site
✓ Site directory created
✓ DDEV is running
✓ Drush is working
```

### 2. Backup Tests

**What's tested:**
- Full backup creation (database + files)
- Backup directory structure
- Database-only backup

**Expected result:** 3/3 tests pass

**Created backups:**
- `sitebackups/test_nwp/YYYYMMDDTHHMMSS-Test_backup.sql`
- `sitebackups/test_nwp/YYYYMMDDTHHMMSS-Test_backup.tar.gz`
- `sitebackups/test_nwp/YYYYMMDDTHHMMSS-DB_only_backup.sql`

### 3. Restore Tests

**What's tested:**
- Full backup restoration (database + files)
- Database-only backup restoration
- Site recreation after deletion
- Configuration persistence

**Expected result:** 3/3 tests pass

**Test process:**
1. Modify site configuration
2. Restore from backup
3. Verify original configuration restored

### 4. Copy Tests

**What's tested:**
- Full site copy (all files + database)
- Files-only copy (preserves destination database)
- DDEV configuration for copied sites
- Drush functionality in copied sites

**Expected result:** 6/6 tests pass

**Created sites:**
- `test_nwp_copy` (full copy)
- `test_nwp_files` (files-only copy)

### 5. Dev/Prod Mode Tests

**What's tested:**
- Development mode activation
- Development modules installation
- Production mode activation
- Development modules removal

**Expected result:** 4/4 tests pass

**Tested modules:**
- devel
- kint
- webprofiler
- stage_file_proxy

### 6. Deployment Tests

**What's tested:**
- Development to staging deployment (`dev2stg.sh`)
- Staging site creation
- Configuration import
- Database synchronization

**Expected result:** 4/4 tests pass

**Created site:**
- `test_nwp_stg` (staging environment)

### 7. Testing Infrastructure Tests

**What's tested:**
- PHPStan static analysis
- PHP CodeSniffer (Drupal coding standards)
- testos.sh script functionality

**Expected result:** 3/3 tests pass

**Note:** These tests can take several minutes each.

### 8. Site Verification Tests

**What's tested:**
- All created sites are healthy
- DDEV containers running
- Drush commands working

**Expected result:** 4/4 tests pass

**Verified sites:**
- test_nwp
- test_nwp_copy
- test_nwp_files
- test_nwp_stg

### 9. Script Validation Tests

**What's tested:**
- All management scripts exist
- Scripts are executable
- Help documentation available

**Expected result:** 12/12 tests pass

**Tested scripts:**
- install.sh
- backup.sh
- restore.sh
- copy.sh
- make.sh
- dev2stg.sh

## Test Results

### Success Criteria

- **All tests pass:** Success rate 100%
- **Most tests pass:** Success rate ≥95% (acceptable)
- **Some tests fail:** Success rate <95% (needs investigation)

### Output

The test script provides:

1. **Real-time progress** - Shows each test as it runs
2. **Summary statistics** - Total/passed/failed counts
3. **Failed test list** - Details of any failures
4. **Log file** - Complete output saved to `test-nwp-TIMESTAMP.log`

### Example Output

```
═══════════════════════════════════════════════════════════════
  Test Results Summary
═══════════════════════════════════════════════════════════════

Total tests run:    37
Tests passed:       37
Tests failed:       0

Success rate: 100%

✓ All tests passed!
```

## Troubleshooting

### Common Issues

#### 1. "sudo: a terminal is required to read the password"

**Problem:** Running in non-interactive mode without sudo privileges

**Solution:** Run the test script from a terminal where you can enter your password:
```bash
./test-nwp.sh
```

**Alternative:** Pre-configure hostnames manually:
```bash
sudo ddev hostname test_nwp.ddev.site 127.0.0.1
sudo ddev hostname test_nwp_copy.ddev.site 127.0.0.1
sudo ddev hostname test_nwp_files.ddev.site 127.0.0.1
sudo ddev hostname test_nwp_stg.ddev.site 127.0.0.1
```

#### 2. "DDEV is not running"

**Problem:** DDEV containers failed to start

**Solution:**
1. Check Docker is running: `docker ps`
2. Check DDEV status: `ddev describe`
3. Restart Docker
4. Check disk space: `df -h`

#### 3. "Drush is not working"

**Problem:** Drush not installed or misconfigured

**Solution:**
1. Check drush exists: `ddev exec ls vendor/bin/drush`
2. Reinstall drush: `ddev composer require drush/drush --dev`
3. Check PHP version compatibility

#### 4. "Backup directory not found"

**Problem:** Backup script failed or wrong directory

**Solution:**
1. Check if backup was created: `ls -la sitebackups/test_nwp/`
2. Check backup script logs
3. Ensure sufficient disk space

#### 5. "Tests are slow"

**Problem:** System resources or network issues

**Expected times:**
- Installation: 3-5 minutes
- Backup: 5-10 seconds each
- Restore: 10-20 seconds
- Copy: 30-60 seconds
- Deploy: 30-60 seconds
- PHPStan: 1-2 minutes
- CodeSniffer: 30-60 seconds

**Total test time:** 15-20 minutes

#### 6. "Test sites still exist after test"

**Behavior:** Normal with `--skip-cleanup` flag

**To clean up manually:**
```bash
cd test_nwp && ddev stop && cd ..
cd test_nwp_copy && ddev stop && cd ..
cd test_nwp_files && ddev stop && cd ..
cd test_nwp_stg && ddev stop && cd ..

rm -rf test_nwp*
rm -rf sitebackups/test_nwp*
```

**Or use the cleanup function:**
```bash
# Edit cnwp.yml to remove test_nwp recipe, then:
ddev poweroff  # Stop all DDEV projects
```

### Debugging Failed Tests

1. **Check the log file:**
   ```bash
   cat test-nwp-TIMESTAMP.log
   ```

2. **Run individual commands manually:**
   ```bash
   ./install.sh test_nwp
   ./backup.sh test_nwp
   ./restore.sh test_nwp
   ```

3. **Inspect test sites:**
   ```bash
   cd test_nwp
   ddev describe
   ddev drush status
   ddev logs
   ```

4. **Check script output:**
   ```bash
   ./test-nwp.sh --verbose
   ```

## Best Practices

### 1. Run Tests Regularly

- **Before major changes** - Establish baseline
- **After implementing features** - Verify no regressions
- **Before releases** - Final validation

### 2. Keep Test Sites Clean

Use `--skip-cleanup` only for debugging. Otherwise:
```bash
./test-nwp.sh  # Will prompt to delete test sites at end
```

### 3. Review Failed Tests

Don't ignore failures. Common causes:
- Configuration changes
- Environment issues
- Script bugs
- Drupal updates

### 4. Update Tests

When adding new features:
1. Add corresponding tests to `test-nwp.sh`
2. Document expected behavior
3. Verify test passes

## Integration with CI/CD

The test script is designed to work in CI/CD pipelines:

### GitHub Actions Example

```yaml
name: NWP Tests

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install DDEV
        uses: ddev/github-action-setup-ddev@v1

      - name: Run NWP Tests
        run: |
          sudo ddev hostname test_nwp.ddev.site 127.0.0.1
          ./test-nwp.sh

      - name: Upload test logs
        if: failure()
        uses: actions/upload-artifact@v3
        with:
          name: test-logs
          path: test-nwp-*.log
```

### Local CI Simulation

```bash
# Simulate CI environment
./test-nwp.sh && echo "✓ CI would pass" || echo "✗ CI would fail"
```

## Contributing

When contributing to NWP:

1. **Run tests before committing:**
   ```bash
   ./test-nwp.sh
   ```

2. **Add tests for new features:**
   - Edit `test-nwp.sh`
   - Add test in appropriate section
   - Follow existing test patterns

3. **Document test changes:**
   - Update this guide
   - Note any new requirements
   - Explain expected behavior

## See Also

- [CICD.md](CICD.md) - CI/CD implementation guide
- [CICD_COMPARISON.md](CICD_COMPARISON.md) - Comparison with other projects
- [TESTING.md](TESTING.md) - OpenSocial testing infrastructure
- [SCRIPTS_IMPLEMENTATION.md](SCRIPTS_IMPLEMENTATION.md) - Script details

---

**Questions or issues?** Check the troubleshooting section or create an issue on GitHub.
