# NWP Changelog

All notable changes to the NWP (Narrow Way Project) are documented here, organized by version tags.

---

## [v0.4] - 2025-12-28

### Major Changes

#### Comprehensive Test Suite
- **Added** `test-nwp.sh` - Complete automated test suite (449 lines)
- **Coverage**: 41 tests across 9 categories
  - Installation tests (4)
  - Backup functionality (2)
  - Restore functionality (4)
  - Copy functionality (6)
  - Dev/Prod mode switching (4)
  - Deployment (4)
  - Testing infrastructure (3)
  - Site verification (4)
  - Script validation (12)

#### Test Suite Features
- Automatic retry mechanism for drush availability (3 retries, 2-second delays)
- Continues testing after failures (removed `set -e`)
- Color-coded output for easy reading
- Detailed logging to timestamped log files
- Optional cleanup of test sites (`--skip-cleanup` flag)
- Verbose mode for debugging (`--verbose` flag)
- **Results**: 73% passing rate (30/41 tests)

#### New Documentation
- **Added** `docs/TESTING_GUIDE.md` (437 lines)
  - Complete usage instructions
  - Test coverage details
  - Troubleshooting guide
  - CI/CD integration examples

### Critical Bug Fixes

#### Drush Installation in Restored/Copied Sites
**Problem**: After restore or copy operations, drush was not available because the `vendor/` directory wasn't being rebuilt.

**Solution**:
- `restore.sh`: Added Step 4 "Install Dependencies" - runs `ddev composer install --no-interaction` after files are restored
- `copy.sh`: Added Step 6 "Install Dependencies" - runs `ddev composer install --no-interaction` after DDEV is configured

**Impact**:
- ✅ Drush now works correctly in all restored sites
- ✅ Drush now works correctly in all copied sites
- ✅ All composer dependencies properly installed after site operations

#### Test Script Exit-on-Failure
**Problem**: Test script was exiting on first test failure, preventing full test suite execution.

**Solution**: Removed `set -e` and added proper error handling within the `run_test()` function.

**Impact**: Tests now continue through all 41 tests even when some fail.

#### Integer Expression Errors
**Problem**: Dev module verification tests were producing bash errors.

**Solution**: Added proper error handling and default values in grep operations.

**Impact**: No more bash syntax errors in test output.

### Technical Improvements

#### Step Numbering Updates

**restore.sh**:
- Step 3: Restore Files (unchanged)
- Step 4: Install Dependencies (NEW)
- Step 5: Fix Site Settings (was Step 4)
- Step 6: Set Permissions (was Step 5)
- Step 7: Restore Database (was Step 6)
- Step 8: Clear Cache (was Step 7)
- Step 9: Generate Login Link (was Step 8)

**copy.sh**:
- Steps 1-5: Unchanged
- Step 6: Install Dependencies (NEW)
- Step 7: Import Database (was Step 6)
- Step 8: Fix Settings (was Step 7)
- Step 9: Set Permissions (was Step 8)
- Step 10: Clear Cache (was Step 9)
- Step 11: Generate Login Link (was Step 10)

### Files Changed
- **New**: `test-nwp.sh`
- **New**: `docs/TESTING_GUIDE.md`
- **Modified**: `restore.sh`
- **Modified**: `copy.sh`

### Breaking Changes
None. All changes are backward compatible.

### Known Issues
The following test "failures" are expected behaviors, not bugs:
1. Files-only copy - Requires destination site to already exist (by design)
2. Deployment to staging - Requires staging site to already exist (by design)
3. Site health after production mode - Production mode correctly removes drush for security
4. PHPStan/CodeSniffer - May legitimately fail on fresh OpenSocial installations

---

## [v0.3] - 2025-12-24

### Major Changes

#### Expanded Phase 3+ Roadmap
- Added comprehensive substeps for all Phase 3+ planned features
- Total: 60+ detailed substeps providing clear roadmap

### Detailed Implementation Substeps

#### Integration with Existing NWP Tools
- Make.sh integration with Linode deployment options
- Dev2stg workflow extension to support Linode
- NWP CLI commands (linode:setup, linode:deploy, etc.)

#### Automated Testing Pipeline
- linode_test.sh for automated deployment testing
- CI/CD integration (GitHub Actions)
- Test result reporting and performance benchmarking

#### Multi-Site Management
- linode_multisite.sh management tool
- Per-site resource allocation and isolation
- Automated domain and SSL management

#### Backup Automation with Rotation
- Enhanced backup rotation (daily/weekly/monthly)
- Off-site storage (Linode Object Storage, S3)
- Automated restore verification

#### Server Monitoring and Alerting
- Prometheus + Grafana monitoring stack
- Application-level monitoring (PHP, Nginx, MariaDB)
- Multi-channel alerting (email, Slack, SMS)

#### Load Balancing
- Linode NodeBalancer integration
- Session handling with Redis
- Auto-scaling automation

#### Database Replication
- MariaDB primary-replica setup
- Automated failover configuration
- Connection routing optimization

#### SSL Certificate Management
- Wildcard and SAN certificate support
- Zero-downtime certificate rotation
- Certificate backup and inventory tracking

---

## [v0.2] - 2025-12-22

### Bug Fixes

#### Git Tracking Cleanup
**Issue**: `nwp_test` directory was tracked by git before .gitignore was updated

**Fix**:
- Removed `nwp_test/` from git tracking using `git rm --cached`
- Local files preserved (only removed from git index)
- Directory now properly ignored by .gitignore pattern: `*_test/`

### Verification
- ✅ `nwp_test/` matched by .gitignore line 26: `*_test/`
- ✅ `nwp4_stg/` matched by .gitignore line 24: `*_stg/`
- ✅ `nwp4_test/` matched by .gitignore line 26: `*_test/`
- ✅ `nwp4_prod/` matched by .gitignore line 25: `*_prod/`
- ✅ All environment-specific directories now properly ignored

### Technical Note
Git only ignores untracked files. Files already tracked before .gitignore was updated must be manually removed from git's index.

---

## [v0.1] - 2025-12-21

### Major Features

#### Git Repository Support for Custom Modules
**Added**: Functionality to clone custom modules directly from git repositories

**Features**:
- New helper functions to detect and parse git URLs
- Automatic separation of git modules from composer packages
- Creates `modules/custom` directory and clones git repos
- Supports both SSH (`git@...`) and HTTPS (`https://...`) formats
- Allows mixing git and composer modules in the same recipe

### Documentation Updates

#### README Enhancements
- Git clone command as first step in Quick Start
- Clarified setup script behavior (checks then installs)
- Comprehensive documentation on both git and composer module methods
- Examples for each installation method

#### Recipe Updates
- Updated dm recipe to use git URL format for divine_mercy module

### Example Usage
```yaml
modules:
  - git@github.com:username/custom-module.git
  - https://github.com/username/another-module.git
  - drupal/admin_toolbar  # Composer package
```

---

## Version History Summary

| Version | Date | Key Changes |
|---------|------|-------------|
| v0.4 | 2025-12-28 | Comprehensive test suite, drush installation fixes |
| v0.3 | 2025-12-24 | Expanded roadmap with 60+ implementation substeps |
| v0.2 | 2025-12-22 | Git tracking cleanup for test directories |
| v0.1 | 2025-12-21 | Git repository support for custom modules |

---

*For detailed improvement plans and roadmap, see [IMPROVEMENTS.md](IMPROVEMENTS.md)*

*Last Updated: December 28, 2024*
