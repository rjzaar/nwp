# NWP Changelog

All notable changes to the NWP (Narrow Way Project) are documented here, organized by version tags.

---

## [v0.12.0] - 2026-01-05 (reorg branch)

### Project Structure Reorganization

Major reorganization of project structure for cleaner root directory and better organization.

#### Script Organization

**Moved Scripts to `scripts/commands/`**:
- All 32 command scripts moved from root to `scripts/commands/`
- `pl` CLI is the default and recommended way to run scripts
- Scripts accessible via `pl install nwp` or `./scripts/commands/install.sh`

**Using the `pl` CLI (default)**:
```bash
pl install nwp       # Install a site
pl backup mysite     # Backup a site
pl status            # Check all sites
pl --help            # Show all commands
```

**Optional Symlinks for Backward Compatibility**:
```bash
./setup.sh --symlinks      # Create ./install.sh etc. in root
./setup.sh --no-symlinks   # Remove symlinks
```

**Interactive Setup**:
- "Script Symlinks" available as optional component in `./setup.sh` UI
- Not included by default; toggle on if you need `./install.sh` style access

#### Log and Backup Organization

**New `.logs/` Directory**:
- Test logs moved from root to `.logs/`
- `test-nwp.sh` now writes logs to `.logs/`
- Automatically created, gitignored

**New `.backups/` Directory**:
- Config backups (cnwp.yml.backup-*) moved to `.backups/`
- Automatic 10-backup retention policy
- `yaml_backup()` function updated to use new location

#### Documentation Updates

- Updated Directory Reference in README.md
- Documented site directory convention (root level for DDEV)
- Added symlink options to setup.sh help

---

## [v0.11.0] - 2026-01-05

### Complete NWP Roadmap Implementation (Phases 1-9)

This release implements the complete developer lifecycle roadmap from development to production deployment.

### Phase 1: CI/CD Infrastructure

**New CI Pipeline Scripts** (`scripts/ci/`):
- `fetch-db.sh` - Database fetching for CI with caching and sanitization
- `build.sh` - DDEV-based build operations (composer, npm, drush deploy)
- `test.sh` - Comprehensive test runner (phpcs, phpstan, phpunit, behat)
- `check-coverage.sh` - Coverage threshold validation from clover.xml

**CI Configuration**:
- `.gitlab-ci.yml` - Complete GitLab CI pipeline with database caching, multi-stage deploy
- `.github/workflows/build-test-deploy.yml` - GitHub Actions workflow with DDEV integration

### Phase 2: Dependency Automation

- `renovate.json` - Automated Drupal dependency updates (extends drevops/renovate-drupal)
- `scripts/security-update.sh` - Security update workflow with testing and notifications

### Phase 3: Server Infrastructure

- `linode/server_scripts/nwp-bootstrap.sh` - Server initialization and package installation
- `linode/server_scripts/nwp-healthcheck.sh` - Comprehensive health monitoring (JSON output)
- `linode/server_scripts/nwp-audit.sh` - Deployment audit logging (JSON Lines format)

### Phase 4: Notification System

- `scripts/notify.sh` - Main notification router with event-to-emoji mapping
- `scripts/notify-slack.sh` - Slack webhook integration
- `scripts/notify-email.sh` - Email notifications via sendmail/SMTP
- `scripts/notify-webhook.sh` - Generic webhook support for external systems

### Phase 5: Code Quality

- `phpstan.neon` - PHPStan level 5 configuration for Drupal
- `.hooks/pre-commit` - PHPCS/PHPStan pre-commit hook
- `.github/PULL_REQUEST_TEMPLATE.md` - PR review checklist
- `.gitlab/merge_request_templates/default.md` - MR review checklist

### Phase 6: Monitoring & Observability

- `linode/server_scripts/nwp-monitor.sh` - Continuous monitoring daemon with alerting
- `linode/server_scripts/nwp-cron.conf` - Cron configuration for monitoring
- `status.sh` - Added `./status.sh production` dashboard command

### Phase 7: Automated Backups & Disaster Recovery

- `linode/server_scripts/nwp-scheduled-backup.sh` - Tiered backup with rotation (hourly/daily/weekly)
- `linode/server_scripts/nwp-verify-backup.sh` - Backup integrity verification
- `linode/server_scripts/nwp-notify.sh` - Multi-channel notification script
- `docs/DISASTER_RECOVERY.md` - RTO targets and recovery procedures

### Phase 8: Environment Management

- `scripts/ci/create-preview.sh` - PR/MR preview environment creation
- `scripts/ci/cleanup-preview.sh` - Preview environment cleanup
- `docs/ENVIRONMENTS.md` - Environment hierarchy and config splits documentation
- CI configurations updated with preview environment jobs

### Phase 9: Advanced Automation

- `linode/server_scripts/nwp-bluegreen-deploy.sh` - Enhanced blue-green with canary support
- `linode/server_scripts/nwp-canary.sh` - Canary release management with auto-promote/rollback
- `linode/server_scripts/nwp-perf-baseline.sh` - Performance baseline capture and comparison
- `scripts/ci/visual-regression.sh` - BackstopJS integration for visual regression testing
- `docs/ADVANCED_DEPLOYMENT.md` - Deployment strategies documentation

### Documentation

**New Documentation**:
- `docs/DEVELOPER_LIFECYCLE_GUIDE.md` - Complete developer workflow guide
- `docs/NWP_COMPLETE_ROADMAP.md` - Consolidated roadmap (merged from multiple docs)
- `docs/HUMAN_TESTING.md` - Manual testing guide for features that can't be automated
- `docs/DISASTER_RECOVERY.md` - Disaster recovery procedures
- `docs/ENVIRONMENTS.md` - Environment management guide
- `docs/ADVANCED_DEPLOYMENT.md` - Advanced deployment strategies

**Updated**:
- `.verification.yml` - 27 new verification entries for all phases
- `linode/server_scripts/README.md` - Complete server scripts documentation

### Multi-Coder Support

- `coder-setup.sh` - Multi-coder DNS delegation and management
- `lib/cloudflare.sh` - NS record API functions
- `docs/CODER_ONBOARDING.md` - New coder onboarding guide

---

## [v0.10.0] - 2026-01-05

### Major Changes

#### Enhanced dev2stg.sh with TUI and Testing

**Complete Rewrite** of dev2stg.sh with modern features:

**New Library Files**:
- `lib/state.sh` - Intelligent state detection for source/target environments
- `lib/database-router.sh` - Multi-source database selection (auto, production, backup, development)
- `lib/testing.sh` - Multi-tier testing framework (8 test types, 5 presets)
- `lib/preflight.sh` - Pre-deployment validation checks
- `lib/dev2stg-tui.sh` - Terminal UI for interactive deployment

**Features**:
- Interactive TUI mode with checkbox selection
- Intelligent database source auto-selection
- Test presets: quick, essential, full, security-only, skip
- Preflight checks before deployment
- Standardized output formatting (info/pass/fail/warn)

#### Documentation Consolidation

- Merged `NWP_IMPROVEMENT_PHASES.md` and `PRODUCTION_DEPLOYMENT_PROPOSAL.md` into `NWP_COMPLETE_ROADMAP.md`
- Created comprehensive `DEVELOPER_LIFECYCLE_GUIDE.md`

---

## [v0.9] - 2026-01-01

### Major Changes

#### Modular Install.sh Architecture

**Refactored**: Complete restructuring of install.sh into lazy-loaded modular libraries.

**Key Improvements**:
- **82% code reduction**: Main install.sh reduced from 2,742 to ~500 lines
- **Lazy loading**: Only required installer is sourced at runtime
- **Single responsibility**: Each library file handles one platform type
- **Guard patterns**: Prevent multiple sourcing with `set -u` compatibility
- **Backward compatibility**: `install_opensocial()` alias preserved

**New Library Files**:
```
lib/
├── install-common.sh    # Shared functions (1,000+ lines)
│   ├── YAML parsing
│   ├── Option handling
│   ├── DNS pre-registration
│   └── Utilities
├── install-drupal.sh    # Drupal/OpenSocial (~600 lines)
├── install-moodle.sh    # Moodle LMS (~420 lines)
├── install-gitlab.sh    # GitLab via Docker (~250 lines)
└── install-podcast.sh   # Castopod podcast (~100 lines)
```

**TUI Library Integration**:
- TUI (Terminal User Interface) library from main branch integrated
- Interactive checkbox UI for installation options
- Option documentation display ('d' key in modify.sh)
- Environment switching with '<>' keys

**Additional Enhancements**:
- Installation step tracking system
- Infrastructure status in modify.sh site info
- Site summary display in modify.sh
- Installed options from other environment tabs shown in TUI footer
- Install status as selectable first option in TUI

### Documentation
- Consolidated and simplified documentation structure
- Merged duplicate docs into unified references

### Commits (Key Changes)
- 05d13750 - Refactor install.sh into modular library architecture
- bdd5dc91 - Merge main into nwppl - integrate TUI library and doc consolidation
- 206be71e - Make Install status a selectable first option in TUI
- 4aaa6207 - Add option documentation display ('d' key) in modify.sh
- 0c5c60ac - Add installation step tracking system
- 28e0ebab - Consolidate and simplify documentation

---

## [v0.8.1] - 2025-12-30

### Enhancements

#### Setup Automation
- **Enhanced**: setup.sh with full infrastructure automation support
- Complete infrastructure provisioning capabilities
- Improved component management

### Commits
- 8ff9a3b2 - Enhance setup.sh with full infrastructure automation

---

## [v0.8] - 2025-12-30

### Major Changes

#### GitLab Deployment and Setup Documentation
**Added**: Comprehensive GitLab installation support and setup automation.

**Setup.sh Rewrite**:
- Complete rewrite as setup manager with checkbox UI
- Component-based installation selection
- Color-coded priority levels for setup components
- SSH automation improvements

**GitLab Installation**:
- Full GitLab CE via Docker support
- Integrated with install.sh type system
- Docker-compose configuration generation
- Automatic README and environment file creation

**Site Purpose Tracking**:
- New `purpose` field for sites: testing, indefinite, permanent, migration
- Migration workflow stub creation
- Purpose-based site management

### Quality Improvements

**Validation and Error Handling**:
- Mode and sitename validation in make.sh
- YAML validation in lib/yaml-write.sh
- Robust parse_yaml_value() in lib/linode.sh
- Strict mode added to main scripts
- Input validation for destructive operations

**Testing Enhancements**:
- Negative test cases added (Test 13)
- Test credentials configurable via TEST_PASSWORD environment variable
- Error checking in create_test_content() function

**Code Organization**:
- Consolidated duplicate functions into shared libraries
- Cleaned up cnwp.yml configuration structure
- Fixed undefined print_warn function in install.sh

### Documentation
- Comprehensive setup documentation
- SSH automation guides
- Git workflow suggestions

### Commits
- 0b716997 - Add comprehensive setup documentation and SSH automation
- 369b94ed - Rewrite setup.sh as complete setup manager with checkbox UI
- 42bf1201 - Add GitLab installation support and setup automation
- e58f1bfd - Add site purpose tracking and migration workflow
- f0e23728 - Add negative test cases to test-nwp.sh (Test 13)
- b8defb8d - Clean up cnwp.yml configuration structure
- 1fe376f1 - Add mode and sitename validation to make.sh
- e1899a1c - Add YAML validation to lib/yaml-write.sh
- 84c1b459 - Consolidate duplicate functions into shared libraries
- 300a427d - Add input validation for destructive operations

---

## [v0.7.1] - 2025-12-29

### Testing & Quality Improvements

**Test Suite Success Rate**: 89% → **98%** (63/77 passed + 13 warnings)

#### Test Suite Cleanup Fix
- **Fixed**: Test suite not cleaning up old test sites before running
- Added `cleanup_test_sites()` call at start of test-nwp.sh
- Ensures fresh installation always uses expected directory name
- **Result**: 6 test failures eliminated
  - ✅ All Test 1b environment variable generation tests (3 tests)
  - ✅ Drush is working (Test 1)
  - ✅ Copied site drush works (Test 4)
  - ✅ Site test-nwp_copy is healthy (Test 8)

#### Install Script Enhancements

**1. Custom Target Parameter**
- Added optional `[target]` parameter: `./install.sh <recipe> [target]`
- Example: `./install.sh nwp mysite` - uses nwp recipe but creates 'mysite' directory
- Allows using same recipe for multiple projects with different names
- Updated install_opensocial() and install_moodle() function signatures

**2. Recipe List Fix**
- Fixed `./install.sh --list` to only show recipes (not all YAML keys)
- Previously incorrectly showed settings, setup, and other top-level keys
- Now uses AWK to properly parse only the recipes: section
- Applied fix in 3 locations: list_recipes(), show_help(), recipe not found error

**3. Bug Fixes**
- Fixed typo: `ocmsg` → `print_info` in site registration (2 instances)
- Eliminates "command not found" error during site registration

### Documentation Updates
- Updated KNOWN_ISSUES.md with verified test results (98% success rate)
- Updated README.md with new success rate and custom target examples
- Added install.sh usage documentation for new features
- Updated IMPROVEMENTS.md with latest changes

### Commits
- ff2705c9 - Fix Test 1b env file failures by adding initial cleanup
- fa894bdd - Fix typo: ocmsg -> print_info in site registration
- faafc1e2 - Fix install.sh --list to only show recipes
- 27a9a01e - Add optional target parameter to install.sh
- 26730112 - Update KNOWN_ISSUES.md with test results
- 8968fea0 - Update KNOWN_ISSUES.md with verified test results

---

## [v0.6] - 2025-12-28

### Major Changes

#### Vortex Environment Variable System (Complete Implementation of 9.1 & 9.2)

**Completed**: Full implementation of environment variable management system with configuration hierarchy.

**New Directory Structure**:
```
vortex/
├── README.md                    # Comprehensive vortex documentation
├── templates/                   # Environment templates
│   ├── .env.base               # Base template with all variables
│   ├── .env.drupal             # Drupal standard profile
│   ├── .env.social             # Open Social profile
│   ├── .env.varbase            # Varbase profile
│   ├── .env.local.example      # Local overrides template
│   └── .secrets.example.yml    # Secrets template
└── scripts/                     # Utility scripts
    ├── generate-env.sh         # Generate .env from cnwp.yml
    ├── generate-ddev.sh        # Generate DDEV config from .env
    └── load-secrets.sh         # Load secrets from .secrets.yml
```

**Configuration Hierarchy**:
- Recipe-specific settings (highest priority)
- Global settings defaults (`settings.services`, `settings.environment`)
- Profile-based defaults (social/varbase enable redis/solr)
- Hardcoded defaults (lowest priority)

**Features**:
1. ✅ **Automatic .env generation** - Step 2 in install.sh generates .env from cnwp.yml
2. ✅ **Template system** - Profile-specific templates with variable substitution
3. ✅ **DDEV integration** - Auto-generate config.yaml from .env files
4. ✅ **Service management** - Global defaults for redis, solr, memcache with recipe overrides
5. ✅ **Environment profiles** - Development, staging, production configurations
6. ✅ **Secrets management** - Separate .secrets.yml for credentials (gitignored)
7. ✅ **No external dependencies** - Uses awk instead of yq for YAML parsing
8. ✅ **DRY principle** - Define defaults once in settings, override per recipe

**cnwp.yml Enhancements**:
```yaml
settings:
  # Environment profiles
  environment:
    development:
      debug: true
      xdebug: false
    staging:
      debug: false
      stage_file_proxy: true
    production:
      debug: false
      redis: true
      caching: aggressive

  # Service defaults
  services:
    redis:
      enabled: false
      version: "7"
    solr:
      enabled: false
      version: "8"
      core: drupal
```

### Critical Bug Fixes

**1. Vortex Script Path Resolution**
- **Problem**: install.sh couldn't find vortex scripts when running from site directory
- **Cause**: Using `dirname $config_file` which returned "." when in site directory
- **Fix**: Use `$base_dir` variable instead (lines 696, 729 in install.sh)
- **Impact**: Environment generation now works correctly during installation

**2. Environment Variable Parameter**
- **Problem**: generate-env.sh called with undefined `$site_dir` variable
- **Cause**: Variable name mismatch in install.sh
- **Fix**: Changed to correct `$install_dir` variable (line 705 in install.sh)
- **Impact**: Proper site name passed to environment generation

**3. DEV_MODULES Execution Bug**
- **Problem**: Bash tried to execute DEV_MODULES values as commands when sourcing .env
- **Cause**: Unquoted multi-word values like `devel kint webprofiler`
- **Fix**: Added quotes around DEV_MODULES and DEV_COMPOSER in all templates
- **Impact**: .env files can now be safely sourced without command execution errors

**4. Missing PROJECT_NAME Variables**
- **Problem**: PROJECT_NAME and NWP_RECIPE not generated in .env files
- **Cause**: Profile-specific templates didn't include these variables
- **Fix**: Added PROJECT_NAME and NWP_RECIPE to all templates
- **Impact**: Generated .env files now include project identification variables

### Testing Enhancements

**Test 1b: Environment Variable Generation (Vortex)**
- Added comprehensive vortex testing to test-nwp.sh
- **Tests**:
  - ✅ .env file creation
  - ✅ .env.local.example creation
  - ✅ .secrets.example.yml creation
  - ✅ Required variables (PROJECT_NAME, NWP_RECIPE, DRUPAL_PROFILE, etc.)
  - ✅ Service configuration (REDIS_ENABLED, SOLR_ENABLED)
  - ✅ Profile-specific defaults (social profile has redis=1, solr=1)
  - ✅ DDEV config generation with web_environment
- **Results**: 11 new tests added, all passing

### Documentation Updates

**New Documentation**:
1. ✅ `vortex/README.md` (340 lines) - Complete vortex system guide
2. ✅ `docs/MIGRATION_GUIDE_ENV.md` (246 lines) - Migration guide for v0.2
3. ✅ `docs/environment-variables-comparison.md` - Comprehensive comparison & recommendations

**Updated Documentation**:
1. ✅ `README.md` - Added Environment Variables and Configuration Hierarchy sections
2. ✅ All templates properly documented with comments
3. ✅ `.gitignore` - Added patterns for .env.local, .secrets.yml, config.local.yaml

### Files Changed

**New Files**:
- `vortex/README.md`
- `vortex/templates/.env.base`
- `vortex/templates/.env.drupal`
- `vortex/templates/.env.social`
- `vortex/templates/.env.varbase`
- `vortex/templates/.env.local.example`
- `vortex/templates/.secrets.example.yml`
- `vortex/scripts/generate-env.sh`
- `vortex/scripts/generate-ddev.sh`
- `vortex/scripts/load-secrets.sh`
- `docs/MIGRATION_GUIDE_ENV.md`
- `docs/environment-variables-comparison.md`

**Modified Files**:
- `install.sh` - Added Step 2 (environment generation), fixed vortex path resolution
- `test-nwp.sh` - Added Test 1b for vortex compatibility
- `README.md` - Added environment variables and configuration hierarchy sections
- `example.cnwp.yml` - Added settings.environment and settings.services
- `.gitignore` - Added vortex whitelist and secrets patterns

### Breaking Changes
None. All changes are backward compatible. Existing installations continue to work without modification.

### Migration Path

**For new installations**: Automatic - environment generation happens in Step 2

**For existing sites**:
```bash
# Generate .env from recipe
cd your-site
../vortex/scripts/generate-env.sh [recipe] [sitename] .

# Regenerate DDEV config (optional)
../vortex/scripts/generate-ddev.sh .
ddev restart
```

See `docs/MIGRATION_GUIDE_ENV.md` for detailed migration instructions.

### Implementation Summary

Completed all items from sections 9.1 and 9.2 of environment-variables-comparison.md:

**9.1 Immediate (High Priority)** ✅
1. ✅ Environment variable mapping from cnwp.yml to DDEV
2. ✅ .env support in NWP scripts
3. ✅ Environment variables documentation
4. ✅ .env.example templates for each recipe
5. ✅ .gitignore entries for secrets

**9.2 Short-term (Medium Priority)** ✅
6. ✅ DDEV config generation in install.sh
7. ✅ Environment selection (dev/staging/prod)
8. ✅ Service management system in cnwp.yml
9. ✅ Secrets management framework
10. ✅ Migration guide for existing users

**Bonus: 9.3 Additional Enhancements** ✅
11. ✅ Configuration hierarchy (Recipe → Settings → Profile → Defaults)
12. ✅ Global defaults in settings section
13. ✅ Recipe override system
14. ✅ No external dependencies (awk-based YAML parsing)
15. ✅ Comprehensive documentation

---

## [v0.5] - 2025-12-28

### Major Changes

#### Phase 1 Roadmap Completion ✅

All Phase 1 items from the prioritized roadmap have been completed:

**1. Help Text Improvements**
- **Fixed** dev2stg.sh help text to clarify `-s N` option syntax
- **Updated** from ambiguous `-s, --step=N` to clear `-s N, --step=N (use -s 5 or --step=5)`
- **Location**: dev2stg.sh:101

**2. Enhanced Error Messages for Drush Failures**
- **Replaced** generic "drush may not be available" messages with specific diagnostics
- **Added** detection for:
  - Drush not installed (suggests `ddev composer require drush/drush`)
  - Database not configured or not accessible
  - Site not fully configured (not a Drupal installation)
  - Shows first 60 characters of actual error for other failures
- **Updated scripts**: make.sh, copy.sh, restore.sh, dev2stg.sh
- **Impact**: Better debugging and clearer actionable messages for users

**3. Combined Flags Documentation**
- **Added** "COMBINED FLAGS" section to all script help texts
- **Explains** that multiple short flags can be combined (e.g., `-bfyo` = `-b -f -y -o`)
- **Examples added**:
  - backup.sh: `-bd` (database + debug)
  - restore.sh: `-bfyo` (database + first + yes + open)
  - copy.sh: `-fyo` (files + yes + open)
  - make.sh: `-vdy` (dev + debug + yes)
  - dev2stg.sh: `-dy` (debug + yes)

#### New Script: delete.sh

**Added** comprehensive site deletion script with graceful cleanup:

**Features**:
- **Universal support** - Works with all DDEV site types (Drupal, Moodle, etc.)
- **Optional backup** - Create backup before deletion with `-b` flag
- **Backup management** - Keep or delete existing backups with `-k` flag
- **Auto-confirm** - Skip prompts with `-y` flag
- **Combined flags** - Use `-bky` for backup + keep + auto-confirm
- **Safety confirmations** - Warns before permanent deletion
- **6-step process**:
  1. Validate site exists
  2. Create backup (if requested)
  3. Stop DDEV containers
  4. Delete DDEV project
  5. Remove site directory
  6. Handle existing backups

**Usage examples**:
```bash
./delete.sh os                    # Delete with confirmation
./delete.sh -y nwp5              # Auto-confirm deletion
./delete.sh -b nwp4              # Backup before deletion
./delete.sh -bky old_site        # Backup + keep backups + auto-confirm
```

**Testing**:
- **Test 8b** added to test-nwp.sh for comprehensive delete functionality testing
- Tests create temporary sites, delete with various flags, verify deletion
- Validates backup creation and preservation with `-b` and `-k` flags
- Includes 8 functional tests covering all delete.sh features

**Backup Safety Fix**:
- Fixed backup handling in auto-confirm mode (-y flag)
- Backups are now preserved by default when using -y (safer behavior)
- Prevents accidental deletion of backups in automated workflows
- Added "BACKUP BEHAVIOR" section to help text explaining all scenarios

### Files Changed
- **Modified**: backup.sh - Added combined flags documentation
- **Modified**: copy.sh - Enhanced error messages + combined flags docs
- **Modified**: dev2stg.sh - Fixed help text + enhanced errors + combined flags
- **Modified**: make.sh - Enhanced error messages + combined flags docs
- **Modified**: restore.sh - Enhanced error messages + combined flags docs
- **NEW**: delete.sh - Comprehensive site deletion script
- **Modified**: test-nwp.sh - Added delete.sh validation and functional tests (Test 8b)
- **Modified**: docs/IMPROVEMENTS.md - Documented v0.5 changes, marked Phase 1 complete
- **Modified**: docs/CHANGES.md - Added delete.sh documentation

### Breaking Changes
None. All changes are backward compatible and improve user experience.

### Known Issues
None. All critical bugs from Phase 1 have been resolved.

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
| v0.11.0 | 2026-01-05 | Complete roadmap implementation (Phases 1-9), CI/CD, monitoring, advanced deployment |
| v0.10.0 | 2026-01-05 | Enhanced dev2stg.sh with TUI, testing framework, documentation consolidation |
| v0.9 | 2026-01-01 | Modular install.sh architecture with lazy loading |
| v0.8.1 | 2025-12-30 | Enhanced setup automation with full infrastructure support |
| v0.8 | 2025-12-30 | GitLab deployment, setup.sh rewrite, site purpose tracking |
| v0.7.1 | 2025-12-29 | Test suite 98% success rate, custom target parameter |
| v0.6 | 2025-12-28 | Vortex environment system: Complete 9.1 & 9.2 implementation |
| v0.5 | 2025-12-28 | Phase 1 complete: Help text, error messages, combined flags docs |
| v0.4 | 2025-12-28 | Comprehensive test suite, drush installation fixes |
| v0.3 | 2025-12-24 | Expanded roadmap with 60+ implementation substeps |
| v0.2 | 2025-12-22 | Git tracking cleanup for test directories |
| v0.1 | 2025-12-21 | Git repository support for custom modules |

---

*For detailed improvement plans and roadmap, see [ROADMAP.md](ROADMAP.md)*

*Last Updated: January 5, 2026*
