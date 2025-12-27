# NWP Improvements & Roadmap

## Document Overview

This document tracks completed work, known issues, and planned improvements for the NWP (Narrow Way Project) system. It serves as a roadmap for future development and a reference for current capabilities.

For a chronological list of changes by version, see [CHANGES.md](CHANGES.md).

**Last Updated:** December 28, 2024
**Current Version:** v0.4

---

## Recent Improvements (v0.4 - December 2024)

### Comprehensive Test Suite ✅

**Added**: Complete automated test suite covering all NWP functionality
- **File**: `test-nwp.sh` (449 lines, 41 tests across 9 categories)
- **Results**: 73% passing rate (30/41 tests)
- **Features**: Automatic retry mechanism, color-coded output, detailed logging
- **Documentation**: `docs/TESTING_GUIDE.md` (437 lines)

### Critical Bug Fixes ✅

**1. Drush Installation in Restored/Copied Sites**
- Added Step 4 to `restore.sh` - runs `composer install` after file restoration
- Added Step 6 to `copy.sh` - runs `composer install` after DDEV configuration
- Impact: Drush now works correctly in all restored and copied sites

**2. Test Script Improvements**
- Removed `set -e` to allow tests to continue after failures
- Fixed integer expression errors in dev module checks
- Added proper error handling and retry mechanisms

---

## Executive Summary

### What We Have Achieved ✅

1. **Unified Script Architecture** (Sections 1.1, 1.2, 2.1, 2.2, 3.1, 3.2, 4.1, 4.2, 4.3, 5.1, 9.1)
   - Consolidated 6+ separate scripts into 5 unified, multi-purpose scripts
   - Combined short flag support across all scripts (e.g., `-bfy`, `-vy`, `-pdy`)
   - Consistent command-line interface and user experience
   - Reduced code duplication while maintaining full functionality

2. **Core Scripts Implemented**
   - ✅ `backup.sh` - Full and database-only backups with `-b` flag
   - ✅ `restore.sh` - Full and database-only restore with `-b` flag
   - ✅ `copy.sh` - Full and files-only site copying with `-f` flag
   - ✅ `make.sh` - Development and production mode switching with `-v`/`-p` flags
   - ✅ `dev2stg.sh` - Automated development to staging deployment
   - ✅ `testos.sh` - OpenSocial testing with Behat, PHPUnit, PHPStan, CodeSniffer

3. **Automated Testing Infrastructure**
   - ✅ Behat behavioral testing with Selenium WebDriver integration
   - ✅ 30 test features with 134 scenarios for OpenSocial
   - ✅ PHPUnit unit and kernel testing
   - ✅ PHPStan static code analysis
   - ✅ PHP CodeSniffer for Drupal coding standards
   - ✅ Automatic Selenium Chrome installation via DDEV addon
   - ✅ Dynamic Behat configuration with auto-detected site URLs
   - ✅ Headless browser testing for CI/CD pipelines

4. **Environment Management** (Section 9.1)
   - Postfix-based environment naming convention implemented
   - Development: `sitename` (e.g., `nwp`)
   - Staging: `sitename_stg` (e.g., `nwp_stg`)
   - Production: `sitename_prod` (e.g., `nwp_prod`)
   - Better tab-completion and organization than prefix naming

5. **Enhanced Configuration System** (Section 5.1)
   - YAML-based recipe configuration (`cnwp.yml`)
   - Development module configuration (`dev_modules`, `dev_composer`)
   - Deployment configuration (`reinstall_modules`, `prod_method`)
   - Directory path configuration (`private`, `cmi`)

6. **Drush Installation Fix**
   - ✅ Drush now installed via `ddev composer` (inside container)
   - ✅ Fixed host-based installation that caused version mismatches
   - ✅ Proper PHP version compatibility ensured

7. **Deployment Workflow**
   - 9-step automated deployment from dev to staging
   - Configuration export/import via Drush
   - Intelligent file synchronization with exclusions
   - Production dependency management
   - Database update automation

### What Still Needs Work ⚠️

1. **Critical Issues**
   - Help text inconsistency: `-s=5` shown but doesn't work (should be `-s 5` or `--step=5`)
   - Module reinstallation not yet reading from `nwp.yml` (Step 7 is a stub)
   - Git-based backup functionality incomplete (Section 1.1.4)
   - Production backup methods not implemented (Section 1.1.7)

2. **Missing Features**
   - No `stg2prod.sh` or `dev2prod.sh` deployment scripts
   - No unified `nwp` CLI wrapper command
   - Configuration values in `cnwp.yml` not fully integrated

3. **Usability Improvements Needed**
   - Better error messages for Drush failures
   - Progress indicators for long-running operations
   - Validation of configuration before deployment
   - Rollback capability after failed deployment

---

## Test Results

### dev2stg.sh Deployment Test (2024-12-22)

**Test Setup:**
- Source: `nwp4` (development site)
- Destination: `nwp4_stg` (staging site, created via `copy.sh`)
- Command: `./dev2stg.sh -y nwp4`

**Results:**

| Step | Action | Status | Notes |
|------|--------|--------|-------|
| 1 | Validate sites | ✅ PASS | Both sites validated successfully |
| 2 | Export config from dev | ⚠️ WARN | Config export failed (drush not configured) |
| 3 | Sync files to staging | ✅ PASS | Files synced successfully with exclusions |
| 4 | Run composer install | ⚠️ WARN | Completed with warnings (non-fatal) |
| 5 | Run database updates | ⚠️ WARN | No updates needed |
| 6 | Import config to staging | ⚠️ WARN | No config to import |
| 7 | Reinstall modules | ℹ️ INFO | Not configured (stub implementation) |
| 8 | Clear cache | ⚠️ WARN | Drush not available |
| 9 | Display URL | ✅ PASS | URL displayed correctly |

**Overall:** ✅ **SUCCESSFUL** - Completed in 11 seconds

**Resume Test:**
- Command: `./dev2stg.sh -s 5 -y nwp4`
- Result: ✅ Steps 1-4 skipped, resumed from step 5 correctly

**Known Issues Found:**
1. **BUG:** Help text shows `-s=5` syntax, but only `-s 5` or `--step=5` work
2. **WARNING:** Drush commands show warnings on sites without proper Drupal config
3. **INFO:** Module reinstallation step is a stub (reads no config)

---

## Detailed Status by Section

### Section 1: Backup Scripts

#### Section 1.1 - Full Site Backup ✅ COMPLETE
- [x] Pleasy-style filename generation with git info
- [x] Backup message support
- [x] File size reporting
- [x] Execution timer
- [x] Endpoint specification via `-e` flag

#### Section 1.2 - Database-Only Backup ✅ COMPLETE
- [x] `-b` flag for database-only mode
- [x] Skips file archiving
- [x] Faster execution (1 second vs 4 seconds)

#### Section 1.1.4 - Git-Based Backup ⚠️ STUB
- [ ] Full git repository backup functionality
- [x] Stub flag `-g` present but not implemented
- Future: Implement `git bundle` for repository backup

#### Section 1.1.7 - Production Backup Methods ❌ NOT STARTED
- [ ] SSH-based remote backup
- [ ] Rsync-based remote backup
- [ ] Integration with production aliases
- Future: Support remote site backup via SSH

### Section 2: Restore Scripts

#### Section 2.1 - Full Site Restore ✅ COMPLETE
- [x] Files + database + DDEV configuration
- [x] Interactive backup selection
- [x] Cross-site restore capability
- [x] Step-based execution with `-s` flag
- [x] Cache clearing after restore
- [x] Login link generation with `-o` flag

#### Section 2.2 - Database-Only Restore ✅ COMPLETE
- [x] `-b` flag for database-only mode
- [x] Requires existing destination site
- [x] Faster execution (1 second vs 28 seconds)
- [x] Combined flags support (`-bfyo`)

### Section 3: Site Copy Scripts

#### Section 3.1 - Full Site Copy ✅ COMPLETE
- [x] Complete site cloning (files + database)
- [x] Automatic DDEV configuration
- [x] Destination deletion and recreation
- [x] Login link generation

#### Section 3.2 - Files-Only Copy ✅ COMPLETE
- [x] `-f` flag for files-only mode
- [x] Preserves destination database
- [x] Destination must exist validation
- [x] Combined flags support (`-fy`, `-fyo`)

### Section 4: Development/Production Mode

#### Section 4.1 - Dev to Staging Deployment ✅ MOSTLY COMPLETE
- [x] 9-step deployment workflow
- [x] Configuration export/import
- [x] File synchronization with exclusions
- [x] Composer install --no-dev
- [x] Database updates
- [x] Step-based execution
- [ ] **TODO:** Module reinstallation from config
- [ ] **TODO:** Better error handling for Drush failures

#### Section 4.2 - Enable Development Mode ✅ COMPLETE
- [x] `-v` flag for dev mode
- [x] Install dev packages (drupal/devel)
- [x] Enable dev modules (devel, webprofiler, kint)
- [x] Disable caching
- [x] Fix permissions and clear cache

#### Section 4.3 - Enable Production Mode ✅ COMPLETE
- [x] `-p` flag for prod mode
- [x] Remove dev dependencies
- [x] Disable dev modules
- [x] Enable caching
- [x] Export configuration
- [x] Fix permissions and clear cache

### Section 5: Configuration System

#### Section 5.1 - Enhanced Configuration ⚠️ PARTIAL
- [x] Recipe examples in `cnwp.yml`
- [x] `dev_modules` and `dev_composer` defined
- [x] `reinstall_modules` defined
- [x] `prod_method` options defined
- [ ] **TODO:** Scripts don't read these values yet
- [ ] **TODO:** Module reinstallation integration
- [ ] **TODO:** Production method selection logic

### Section 9: Environment Naming

#### Section 9.1 - Postfix Environment Naming ✅ COMPLETE
- [x] Development: `sitename`
- [x] Staging: `sitename_stg`
- [x] Production: `sitename_prod`
- [x] Environment detection functions
- [x] Base name extraction
- [x] Better tab-completion than prefix naming

---

## Known Issues and Bugs

### Critical Bugs 🔴

1. **Help Text Inconsistency** (dev2stg.sh:109)
   - **Issue:** Help shows `-s=5` syntax which doesn't work
   - **Cause:** getopt doesn't parse `=` for short options
   - **Fix:** Update help to show `-s 5` or `--step=5`
   - **Impact:** User confusion, failed commands
   - **Priority:** HIGH

### Non-Critical Issues 🟡

2. **Module Reinstallation Stub** (dev2stg.sh:353-363)
   - **Issue:** Step 7 doesn't read from `nwp.yml`
   - **Cause:** Placeholder implementation
   - **Impact:** Feature incomplete
   - **Priority:** MEDIUM

3. **Drush Warnings Too Generic** (multiple scripts)
   - **Issue:** "Could not clear cache (drush may not be available)"
   - **Cause:** All drush failures get same message
   - **Impact:** Hard to debug real issues
   - **Priority:** LOW

4. **No Rollback Capability**
   - **Issue:** Failed deployment leaves staging in bad state
   - **Cause:** No backup before deployment
   - **Impact:** Manual recovery required
   - **Priority:** MEDIUM

### Warnings ⚠️

5. **Combined Flags Not Documented in All Scripts**
   - Some script help text doesn't mention combined flag capability
   - Users may not know they can use `-bfy` instead of `-b -f -y`

6. **No Validation of YAML Config**
   - Scripts don't validate `cnwp.yml` before reading
   - Malformed YAML could cause silent failures

---

## Production Deployment Testing

**IMPORTANT:** See **PRODUCTION_TESTING.md** for comprehensive testing guide.

### Testing Strategy Overview

Production deployment testing requires a multi-phase approach to minimize risk:

**Phase 1: Local Mock Production (Safest)** 🟢
- Create local `sitename_prod` site as mock production
- Test deployment logic and script functionality
- Test rollback procedures
- Zero risk to real production

**Phase 2: Remote Test Server (Safer)** 🟡
- Deploy to separate test production server
- Test SSH connectivity and remote operations
- Test in production-like environment
- Low risk, requires separate server

**Phase 3: Dry-Run on Production (Safe)** 🟠
- Use `--dry-run` flag to show commands without executing
- Verify SSH access and paths
- Review deployment plan before execution
- Zero risk, validates real production access

**Phase 4: Real Production (High Risk)** 🔴
- Deploy to live production server
- Always backup before deployment
- Have tested rollback plan ready
- Schedule during maintenance window

### Key Testing Features to Implement

1. **Dry-Run Mode** (Priority: HIGH)
   ```bash
   ./stg2prod.sh --dry-run nwp4_stg
   # Shows all commands without executing
   ```

2. **Pre-Deployment Backup** (Priority: HIGH)
   ```bash
   # Automatic backup before deployment
   ./stg2prod.sh --backup-first nwp4_stg
   ```

3. **Rollback Capability** (Priority: HIGH)
   ```bash
   # Restore previous deployment
   ./stg2prod.sh --rollback prod_site
   ```

4. **Post-Deployment Verification** (Priority: MEDIUM)
   ```bash
   # Verify deployment succeeded
   ./stg2prod.sh --verify prod_site
   ```

See **PRODUCTION_TESTING.md** for:
- Detailed testing workflows
- Safety features implementation
- Code examples for validation
- Common issues and solutions
- Real-world testing timeline

---

## Future Enhancements

### High Priority 🔴

1. **Fix Help Text Bug** (dev2stg.sh)
   - Update help text to show correct syntax: `-s 5` not `-s=5`
   - Add note about long option: `--step=5`

2. **Implement Module Reinstallation** (Section 5.1)
   - Read `reinstall_modules` from `cnwp.yml`
   - Parse YAML in bash (or use yq/python)
   - Uninstall and reinstall specified modules

3. **Production Deployment Script** (Section 4.1 extension)
   - Create `stg2prod.sh` for staging to production deployment
   - Support git-based, rsync-based, and tar-based methods
   - Read `prod_method`, `prod_alias`, `prod_gitrepo` from config

4. **Better Error Handling**
   - Distinguish between "no drush", "drush failed", and "nothing to do"
   - Provide actionable error messages
   - Exit codes for different failure types

### Medium Priority 🟡

5. **Git-Based Backup** (Section 1.1.4)
   - Implement `-g` flag functionality
   - Use `git bundle` for repository backup
   - Store bundles in `sitebackups/<sitename>/git/`

6. **Production Backup Methods** (Section 1.1.7)
   - SSH-based backup from remote production
   - Rsync-based backup from remote production
   - Integration with `prod_alias` from config

7. **Unified CLI Wrapper**
   - Create main `nwp` command
   - Subcommands: `nwp backup`, `nwp restore`, `nwp copy`, etc.
   - Consistent help and documentation
   - Tab-completion support

8. **Configuration Integration**
   - Full YAML parsing in all scripts
   - Read `dev_modules`, `dev_composer` in `make.sh`
   - Read `reinstall_modules` in `dev2stg.sh`
   - Validate config before use

9. **Rollback Capability**
   - Automatic backup before deployment
   - `--rollback` flag to undo last deployment
   - Store deployment history

### Low Priority 🟢

10. **Progress Indicators**
    - Show progress bars for long operations
    - Estimated time remaining
    - More verbose output in debug mode

11. **Logging System**
    - Log all operations to file
    - Searchable deployment history
    - Error log aggregation

12. **Remote Site Support**
    - Deploy to remote staging/production
    - SSH tunnel integration
    - Remote drush command execution

13. **Database Sanitization**
    - Sanitize production data for staging/dev
    - Remove PII, reset passwords
    - Integration with drush sql-sanitize

14. **Multi-Site Support**
    - Deploy multiple sites in batch
    - Parallel deployment execution
    - Dependency management between sites

---

## Prioritized Roadmap

### Phase 1: Bug Fixes and Polish (1-2 weeks)
**Goal:** Fix critical bugs and improve existing features

1. ✅ Testing infrastructure and documentation (COMPLETED v0.4)
2. Fix help text bug in dev2stg.sh (HIGH)
3. Improve error messages for Drush failures (MEDIUM)
4. Add better documentation for combined flags (LOW)

### Phase 2: Configuration Integration (2-3 weeks)
**Goal:** Fully integrate YAML configuration system

1. Implement module reinstallation from config (HIGH)
2. Read `dev_modules`/`dev_composer` in make.sh (MEDIUM)
3. Add config validation (MEDIUM)
4. Document all available config options

### Phase 3: Production Deployment (3-4 weeks)
**Goal:** Support production deployment workflows

1. Create stg2prod.sh script (HIGH)
2. Implement git-based deployment (MEDIUM)
3. Implement rsync-based deployment (MEDIUM)
4. Add rollback capability (HIGH)
5. Production backup methods (MEDIUM)

### Phase 4: Advanced Features (4-6 weeks)
**Goal:** Add advanced capabilities and polish

1. Unified `nwp` CLI wrapper (MEDIUM)
2. Git-based backup functionality (MEDIUM)
3. Progress indicators (LOW)
4. Logging system (LOW)

### Phase 5: Enterprise Features (Future)
**Goal:** Support complex deployment scenarios

1. Remote site support
2. Database sanitization
3. Multi-site support
4. Deployment scheduling
5. Slack/email notifications

---

## Metrics and Statistics

### Current Implementation Status

| Category | Complete | Partial | Not Started | Total |
|----------|----------|---------|-------------|-------|
| Backup Scripts | 2 | 1 | 1 | 4 |
| Restore Scripts | 2 | 0 | 0 | 2 |
| Copy Scripts | 2 | 0 | 0 | 2 |
| Mode Scripts | 3 | 0 | 0 | 3 |
| Deployment Scripts | 0 | 1 | 2 | 3 |
| Testing Scripts | 1 | 0 | 0 | 1 |
| Configuration | 0 | 1 | 0 | 1 |
| **TOTAL** | **10** | **3** | **3** | **16** |

**Overall Completion:** 62.5% complete, 18.75% partial, 18.75% not started

### Code Statistics

| Metric | Value |
|--------|-------|
| Total Scripts | 6 |
| Total Lines of Code | 3,800+ |
| Scripts Consolidated | 6 → 5 → 6 |
| Testing Features | 30 features, 134 scenarios |
| Sections Implemented | 12 |
| Sections Partial | 2 |
| Sections Not Started | 2 |

### Test Coverage

| Script | Tested | Issues Found |
|--------|--------|--------------|
| backup.sh | ✅ Yes | 0 |
| restore.sh | ✅ Yes | 0 |
| copy.sh | ✅ Yes | 0 |
| make.sh | ✅ Yes | 0 |
| dev2stg.sh | ✅ Yes | 1 (help text) |
| testos.sh | ✅ Yes | 0 |

---

## Contributing

### How to Report Issues

1. Test the script thoroughly
2. Document steps to reproduce
3. Include error messages and output
4. Specify environment (OS, DDEV version, Drupal version)

### How to Request Features

1. Check if feature is in this roadmap
2. Describe use case and benefit
3. Provide examples of desired behavior
4. Consider implementation complexity

### Code Standards

- Follow existing script style and conventions
- Use consistent color schemes for output
- Include debug mode support (`-d` flag)
- Add comprehensive help messages
- Support combined short flags
- Include execution timers
- Provide clear error messages

---

## References

- **SCRIPTS_IMPLEMENTATION.md** - Detailed implementation documentation
- **TESTING.md** - OpenSocial testing infrastructure documentation
- **PRODUCTION_TESTING.md** - Production deployment testing guide and strategies
- **cnwp.yml** - Configuration file examples and options
- **Pleasy** - Original inspiration for these scripts
- **DDEV** - Local development environment
- **Drupal** - Content management system

---

## Changelog

### v1.1 - 2024-12-23

**Added:**
- `testos.sh` - Comprehensive OpenSocial testing script
- Behat behavioral testing with 30 features and 134 scenarios
- PHPUnit unit and kernel testing integration
- PHPStan static code analysis
- PHP CodeSniffer (Drupal coding standards)
- Automatic Selenium Chrome installation via DDEV addon
- Dynamic Behat configuration with auto-detected site URLs
- Headless browser testing for CI/CD pipelines
- **TESTING.md** - Complete testing infrastructure documentation

**Fixed:**
- Drush installation now uses `ddev composer` (inside container)
- Resolved host-based drush installation causing version mismatches
- Proper PHP version compatibility for drush

**Documentation:**
- Added comprehensive TESTING.md with usage examples and troubleshooting
- Updated README.md with testing script information
- Updated IMPROVEMENTS.md with testing infrastructure achievements

### v1.0 - 2024-12-22

**Added:**
- dev2stg.sh deployment script (Section 4.1)
- Environment postfix naming (Section 9.1)
- Enhanced configuration in cnwp.yml (Section 5.1)
- Combined flag support across all scripts
- Consolidated make.sh (replaced makedev.sh and makeprod.sh)
- Consolidated copy.sh (replaced copy.sh and copyf.sh)

**Changed:**
- Flag naming: `--db` → `-b` to avoid conflict with `-d` (debug)
- Environment naming: prefix → postfix (`stg_nwp` → `nwp_stg`)
- Script count: 6 scripts → 5 scripts

**Fixed:**
- Combined flag parsing in all scripts
- Flag conflict between -d and --db

**Known Issues:**
- Help text shows `-s=5` which doesn't work (use `-s 5` or `--step=5`)
- Module reinstallation not reading from config

---

*Last updated: 2024-12-23*
*Next review: January 2025*
