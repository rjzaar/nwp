# NWP Improvements v2.0 - Unified Roadmap

**Document Version:** 2.0
**Date:** December 30, 2025
**Purpose:** Consolidated roadmap with numbered proposals based on research from Vortex, Pleasy, Open Social, Varbase, and industry best practices

---

## Executive Summary

This document consolidates all improvement recommendations for NWP into a single prioritized roadmap with **25 numbered proposals** organized into **5 phases**. Each proposal includes effort estimates, dependencies, and success criteria.

### Current Status

| Metric | Value |
|--------|-------|
| Current Version | v0.8.1 |
| Test Success Rate | 98% |
| Core Features Complete | 85% |
| CI/CD Implementation | 20% |
| Git Backup Implementation | 10% |
| Documentation Coverage | 90% |

### Research Sources

| Source | Key Patterns Extracted |
|--------|----------------------|
| **Vortex** | Docker CI, 7 code quality tools, parallel testing, database caching |
| **Pleasy** | Git database backup, maintenance mode, SSH key management |
| **Open Social** | Behat testing (30 features, 134 scenarios), testos.sh patterns |
| **Varbase** | CI/CD comparison, configuration management |
| **Industry** | 3-2-1 backup rule, 80% coverage threshold, GitLab CI patterns |

---

## Phase Overview

| Phase | Focus | Proposals | Timeline | Status |
|-------|-------|-----------|----------|--------|
| **Phase 1** | Foundation & Polish | P01-P05 | Complete | 100% |
| **Phase 2** | Production & Tracking | P06-P10 | Complete | 100% |
| **Phase 3** | Git Backup System | P11-P15 | Ready | 0% |
| **Phase 4** | CI/CD & Testing | P16-P21 | Ready | 0% |
| **Phase 5** | Enterprise Features | P22-P25 | Future | 0% |

---

## Phase 1: Foundation & Polish (COMPLETE)

### P01: Unified Script Architecture
**Status:** COMPLETE

Consolidated 6+ scripts into 5 unified, multi-purpose scripts with consistent CLI.

| Script | Purpose | Flags |
|--------|---------|-------|
| `backup.sh` | Full/database backup | `-b`, `-g`, `-e` |
| `restore.sh` | Full/database restore | `-b`, `-f`, `-o` |
| `copy.sh` | Full/files-only copy | `-f`, `-y`, `-o` |
| `make.sh` | Dev/prod mode switch | `-v`, `-p`, `-d` |
| `dev2stg.sh` | Dev to staging deploy | `-s`, `-y`, `-d` |

**Success Criteria:** All scripts support combined flags (e.g., `-bfyo`)

---

### P02: Environment Naming Convention
**Status:** COMPLETE

Implemented postfix-based naming for better tab-completion:

| Environment | Pattern | Example |
|-------------|---------|---------|
| Development | `sitename` | `nwp` |
| Staging | `sitename_stg` | `nwp_stg` |
| Production | `sitename_prod` | `nwp_prod` |

**Success Criteria:** All scripts detect and handle environments correctly

---

### P03: Enhanced Error Messages
**Status:** COMPLETE

Replaced generic messages with specific diagnostics:
- Drush not installed → suggests `ddev composer require drush/drush`
- Database not configured → specific DB error
- Site not configured → Drupal installation check
- First 60 chars of actual error for unknown failures

**Success Criteria:** Users can self-diagnose 80% of issues

---

### P04: Combined Flags Documentation
**Status:** COMPLETE

Added "COMBINED FLAGS" section to all script help texts explaining `-bfyo` = `-b -f -y -o`.

**Success Criteria:** Help text includes examples for each script

---

### P05: Test Suite Infrastructure
**Status:** COMPLETE

Created `test-nwp.sh` with 77 tests across 9 categories:
- 98% pass rate (63 passed + 13 warnings, 1 known failure)
- Automatic retry mechanism
- Color-coded output
- Detailed logging

**Success Criteria:** >95% pass rate on clean environment

---

## Phase 2: Production & Tracking (COMPLETE)

### P06: Sites Tracking System
**Status:** COMPLETE

Automatic site registration in `cnwp.yml`:

```yaml
sites:
  mysite:
    directory: /path/to/mysite
    recipe: nwp
    environment: development
    purpose: indefinite
    created: 2025-12-30T00:00:00Z
```

**Components:**
- `lib/yaml-write.sh` - 9 YAML manipulation functions
- Automatic registration on install
- Automatic cleanup on delete (configurable)
- Purpose tracking: testing, indefinite, permanent, migration

**Success Criteria:** 100% of sites tracked automatically

---

### P07: Module Reinstallation
**Status:** COMPLETE

Reads `reinstall_modules` from recipe configuration:

```yaml
recipes:
  myrecipe:
    reinstall_modules: social_event social_group
```

Implemented in:
- `dev2stg.sh` Step 7
- `stg2prod.sh` Step 9

**Success Criteria:** Modules reinstall without manual intervention

---

### P08: Production Deployment Script
**Status:** COMPLETE

Created `stg2prod.sh` (~750 lines) with 10-step workflow:

1. Validate deployment configuration
2. Test SSH connection
3. Export configuration
4. Backup production (optional)
5. Sync files via rsync
6. Run composer install
7. Run database updates
8. Import configuration
9. Reinstall modules
10. Clear cache

**Features:** dry-run, auto-yes, resume from step N

**Success Criteria:** Zero-downtime deployment possible

---

### P09: Setup Automation
**Status:** COMPLETE

Enhanced `setup.sh` with:
- 18 components across 4 categories
- Color-coded priorities (Required/Recommended/Optional)
- Rollback support for all components
- GitLab server provisioning
- DNS configuration via Linode API

**Success Criteria:** New developer setup in <30 minutes

---

### P10: Configuration System Enhancement
**Status:** COMPLETE

Extended `cnwp.yml` schema:

```yaml
settings:
  url: yourdomain.org
  database: mariadb
  php: 8.2

recipes:
  # Site recipes

sites:
  # Tracked sites

linode:
  # Server configuration
```

**Success Criteria:** All deployment config in single file

---

## Phase 3: Git Backup System (READY)

### P11: Basic Git Integration
**Priority:** HIGH | **Effort:** Medium | **Dependencies:** NWP GitLab server

Implement functional `-g` flag in `backup.sh` using **NWP GitLab as the default remote**:

```bash
# Usage
./backup.sh -g sitename "Backup message"
./backup.sh -bg sitename "DB backup with git"
```

**Architecture (Simplified):**
```
Site Directory                      NWP GitLab (git.nwpcode.org)
──────────────                      ────────────────────────────
mysite/.git ──────────────────────► sites/mysite.git
                                    (auto-created on first push)

sitebackups/mysite/db/.git ───────► backups/mysite-db.git
                                    (auto-created on first push)
```

**Why NWP GitLab as default:**
- Already created and configured by setup.sh
- Self-hosted (full data sovereignty)
- No external accounts needed
- Built-in CI/CD for testing
- SSH access already configured (`ssh git-server`)

**Implementation:**
1. Git add/commit after backup creation
2. Initialize repository if needed
3. Auto-create project on NWP GitLab via API
4. Push to NWP GitLab as default remote
5. Configure standard `.gitignore`

**Configuration:**
```yaml
git_backup:
  enabled: true
  auto_commit: true
  auto_push: true                    # Push to NWP GitLab by default
  gitlab_url: https://git.nwpcode.org  # From settings.url
```

**Success Criteria:**
- [ ] `-g` flag creates git commit
- [ ] Repository auto-created on NWP GitLab
- [ ] Push to NWP GitLab works
- [ ] Works with existing naming convention

---

### P12: Git Bundle Support
**Priority:** HIGH | **Effort:** Medium | **Dependencies:** P11

Enable offline/archival backups via git bundles:

```bash
# Usage
./backup.sh --bundle sitename "Full bundle"
./backup.sh --bundle --incremental sitename "Incremental"
```

**Implementation:**
1. Full bundle: `git bundle create backup.bundle --all`
2. Incremental: Track via tags, create differential bundles
3. Verification: `git bundle verify`
4. Restoration: `git clone backup.bundle`

**Success Criteria:**
- [ ] Full bundle creation works
- [ ] Incremental bundles work
- [ ] Bundle verification passes
- [ ] Restoration from bundle successful

---

### P13: Additional Remote Support (Optional)
**Priority:** LOW | **Effort:** Medium | **Dependencies:** P11

Add **optional** external remotes for offsite backup (3-2-1 rule). NWP GitLab is already the primary.

```yaml
git_backup:
  # Primary is always NWP GitLab (automatic)
  additional_remotes:              # Optional external backups
    github:
      url: git@github.com:user/site.git
      enabled: false               # Opt-in
    local:
      path: /srv/git/site.git
      enabled: false
```

**Architecture:**
```
                                    ┌─► NWP GitLab (PRIMARY - automatic)
mysite/.git ────────────────────────┤
                                    ├─► GitHub (optional)
                                    └─► Local bare repo (optional)
```

**Implementation:**
1. NWP GitLab always primary (from P11)
2. Additional remotes are opt-in
3. Sequential push with error handling
4. Continue on external remote failure

**Success Criteria:**
- [ ] NWP GitLab always works (primary)
- [ ] Optional remotes configurable
- [ ] External failures don't block backup

---

### P14: Automated Scheduling
**Priority:** MEDIUM | **Effort:** Low | **Dependencies:** P11

Cron-based backup automation:

```yaml
git_backup:
  schedule:
    enabled: true
    database: "0 2 * * *"      # Daily 2 AM
    full: "0 3 * * 0"          # Weekly Sunday
    bundle: "0 4 1 * *"        # Monthly 1st
```

**Implementation:**
1. Generate cron entries from config
2. Support systemd timers as alternative
3. Log all scheduled operations
4. Email notification on failure

**Success Criteria:**
- [ ] Schedule installation command
- [ ] Schedule removal command
- [ ] Logs written for each run
- [ ] Notification on failure

---

### P15: GitLab API Automation
**Priority:** LOW | **Effort:** Medium | **Dependencies:** P11, GitLab server

Enhance GitLab integration with API-driven automation (P11 already uses NWP GitLab as default):

```yaml
git_backup:
  gitlab_api:
    auto_create_project: true    # Create repo if doesn't exist
    group: sites                 # Organize in GitLab groups
    visibility: private          # Default visibility
    cleanup_branches: true       # Prune old backup branches
```

**Implementation:**
1. API-based project auto-creation (no manual repo setup)
2. Organize repos into GitLab groups (sites/, backups/)
3. Personal access token management
4. Automatic `.gitignore` configuration

**Success Criteria:**
- [ ] Projects auto-created on first push
- [ ] Group organization works
- [ ] Token stored securely in .secrets.yml

---

## Phase 4: CI/CD & Testing (READY)

### P16: Docker Test Environment
**Priority:** HIGH | **Effort:** Medium | **Dependencies:** None

Standardized test execution environment:

```yaml
services:
  cli:        # PHP CLI - tests, drush, composer
  nginx:      # Web server (port 8080)
  php:        # PHP-FPM
  database:   # MariaDB
  chrome:     # Selenium for @javascript tests
```

**Implementation:**
1. Create `docker-compose.test.yml`
2. Include `shm_size: '1gb'` for Chrome stability
3. Service naming for Behat (`nginx:8080`, `chrome:4444`)
4. CI-specific volume handling

**Success Criteria:**
- [ ] Consistent local/CI environment
- [ ] Chrome container stable
- [ ] All services accessible

---

### P17: Site Test Script
**Priority:** HIGH | **Effort:** Low | **Dependencies:** P16

Create `test.sh` following NWP patterns:

```bash
# Usage
./test.sh mysite              # All tests
./test.sh -l mysite           # Lint only
./test.sh -u mysite           # Unit tests
./test.sh -s mysite           # Smoke tests (~30s)
./test.sh -b mysite           # Full Behat
./test.sh -b -p mysite        # Parallel Behat
```

**Flags:**
| Flag | Test Type | Speed |
|------|-----------|-------|
| `-l` | PHPCS, PHPStan | Fast |
| `-u` | PHPUnit Unit | Fast |
| `-k` | PHPUnit Kernel | Medium |
| `-f` | PHPUnit Functional | Slow |
| `-s` | Behat Smoke | Medium |
| `-b` | Behat Full | Slow |

**Success Criteria:**
- [ ] All test types runnable
- [ ] Combined flags work
- [ ] Clear pass/fail reporting

---

### P18: Behat BDD Framework
**Priority:** HIGH | **Effort:** Medium | **Dependencies:** P16

Behavior-driven testing setup:

**Configuration (`behat.yml`):**
- Default profile for local testing
- `p0`, `p1` profiles for parallel execution
- `remote`, `staging`, `production` profiles
- DrevOps BehatSteps integration

**Tags:**
| Tag | Use Case |
|-----|----------|
| `@smoke` | Critical path validation |
| `@api` | Headless tests (fast) |
| `@javascript` | Browser tests (slow) |
| `@p0`, `@p1` | Parallel groups |
| `@destructive` | Data-modifying tests |

**Success Criteria:**
- [ ] Behat runs locally via DDEV
- [ ] Smoke tests complete in <60s
- [ ] Screenshots on failure
- [ ] JUnit report output

---

### P19: Code Quality Tooling
**Priority:** MEDIUM | **Effort:** Low | **Dependencies:** None

Enforce coding standards:

| Tool | Purpose | Config |
|------|---------|--------|
| PHPCS | Drupal standards | `.phpcs.xml` |
| PHPStan | Static analysis (level 7) | `phpstan.neon` |
| Rector | Automated refactoring | `rector.php` |
| Gherkin Lint | Feature validation | Integrated |

**Success Criteria:**
- [ ] All tools configured
- [ ] Baseline for existing code
- [ ] Failures block deployment

---

### P20: GitLab CI Pipeline
**Priority:** HIGH | **Effort:** High | **Dependencies:** P16-P19, GitLab server

Three-stage pipeline:

```
BUILD → VALIDATE → TEST
  │         │         │
  │         │         ├── phpunit:unit
  │         │         ├── phpunit:kernel
  │         │         ├── behat:smoke
  │         │         └── behat:full (parallel)
  │         │
  │         ├── phpcs
  │         ├── phpstan
  │         └── rector
  │
  └── composer install
```

**Features:**
- Database caching with timestamp
- Parallel Behat (2+ runners)
- Skip flags (`SKIP_PHPCS`, etc.)
- JUnit report collection
- 80% coverage threshold

**Success Criteria:**
- [ ] Pipeline runs on push
- [ ] All test types execute
- [ ] Coverage reported
- [ ] Badges display correctly

---

### P21: Coverage & Badges
**Priority:** MEDIUM | **Effort:** Low | **Dependencies:** P20

Visibility into test health:

**Badge URLs:**
```
Pipeline: https://git.<url>/project/badges/main/pipeline.svg
Coverage: https://git.<url>/project/badges/main/coverage.svg
```
Where `<url>` comes from `cnwp.yml` settings (e.g., `git.nwpcode.org`).

**README Integration:**
```markdown
[![Pipeline](url)](link) [![Coverage](url)](link)
```

**Success Criteria:**
- [ ] Coverage threshold enforced
- [ ] Badges update automatically
- [ ] README displays badges

---

## Phase 5: Enterprise Features (FUTURE)

### P22: Unified CLI Wrapper
**Priority:** MEDIUM | **Effort:** Medium | **Dependencies:** All previous

Enhance existing `pl` command as unified interface:

```bash
pl install recipe sitename
pl backup sitename
pl restore sitename
pl copy source dest
pl test sitename
pl deploy sitename
```

**Success Criteria:**
- [ ] All scripts accessible via `pl`
- [ ] Tab-completion support
- [ ] Consistent help system

---

### P23: Database Sanitization
**Priority:** MEDIUM | **Effort:** Medium | **Dependencies:** P11

Sanitize production data:

```bash
./backup.sh --sanitize sitename
```

**Implementation:**
- Remove PII (emails, passwords)
- Reset user passwords to test value
- Integration with `drush sql-sanitize`

**Success Criteria:**
- [ ] No PII in sanitized dumps
- [ ] Passwords reset
- [ ] GDPR compliant

---

### P24: Rollback Capability
**Priority:** HIGH | **Effort:** High | **Dependencies:** P08, P11

Automatic recovery from failed deployments:

```bash
./stg2prod.sh --rollback sitename
```

**Implementation:**
1. Automatic backup before deployment
2. Store deployment history
3. One-command rollback
4. Verification after rollback

**Success Criteria:**
- [ ] Backup created automatically
- [ ] Rollback completes in <5 minutes
- [ ] Site functional after rollback

---

### P25: Remote Site Support
**Priority:** LOW | **Effort:** High | **Dependencies:** P08, P18

Operations on remote servers:

```bash
./backup.sh @prod sitename
./test.sh --profile=production sitename
```

**Implementation:**
- SSH tunnel integration
- Remote drush execution
- Behat remote profiles
- Read-only production tests

**Success Criteria:**
- [ ] Remote backup works
- [ ] Remote tests run
- [ ] Production tests are read-only

---

## Implementation Priority Matrix

| Proposal | Priority | Effort | Dependencies | Phase |
|----------|----------|--------|--------------|-------|
| P01-P05 | - | - | - | 1 (DONE) |
| P06-P10 | - | - | - | 2 (DONE) |
| **P11** | HIGH | Medium | None | 3 |
| **P12** | HIGH | Medium | P11 | 3 |
| P13 | MEDIUM | Medium | P11 | 3 |
| P14 | MEDIUM | Low | P11, P13 | 3 |
| P15 | LOW | High | P11-P14 | 3 |
| **P16** | HIGH | Medium | None | 4 |
| **P17** | HIGH | Low | P16 | 4 |
| **P18** | HIGH | Medium | P16 | 4 |
| P19 | MEDIUM | Low | None | 4 |
| **P20** | HIGH | High | P16-P19 | 4 |
| P21 | MEDIUM | Low | P20 | 4 |
| P22 | MEDIUM | Medium | All | 5 |
| P23 | MEDIUM | Medium | P11 | 5 |
| **P24** | HIGH | High | P08, P11 | 5 |
| P25 | LOW | High | P08, P18 | 5 |

**Bold** = Critical path items

---

## Recommended Implementation Order

### Immediate (Next Sprint)

1. **P11: Basic Git Integration** - Foundation for all git backup features
2. **P16: Docker Test Environment** - Foundation for all CI/CD features
3. **P17: Site Test Script** - Enables developer testing workflow

### Short-term (1-2 months)

4. **P12: Git Bundle Support** - Complete offline backup capability
5. **P18: Behat BDD Framework** - Enable behavior testing
6. **P19: Code Quality Tooling** - Enforce standards

### Medium-term (2-4 months)

7. **P20: GitLab CI Pipeline** - Full automation
8. **P13: Multiple Remote Support** - 3-2-1 backup rule
9. **P14: Automated Scheduling** - Hands-off backups
10. **P24: Rollback Capability** - Production safety

### Long-term (4-6 months)

11. **P21: Coverage & Badges** - Visibility
12. **P15: NWP GitLab as Backup** - Self-hosted backup
13. **P22: Unified CLI Wrapper** - Developer experience
14. **P23: Database Sanitization** - GDPR compliance
15. **P25: Remote Site Support** - Full remote ops

---

## Success Metrics

### Phase 3 Complete When:
- [ ] Git backup with `-g` flag works
- [ ] Git bundles can be created and restored
- [ ] At least 2 remotes configured
- [ ] Automated daily database backup

### Phase 4 Complete When:
- [ ] `test.sh` runs all test types
- [ ] Behat smoke tests pass
- [ ] GitLab CI pipeline green
- [ ] Coverage badge shows >80%

### Phase 5 Complete When:
- [ ] `nwp` CLI wrapper functional
- [ ] Rollback tested and documented
- [ ] Remote operations work
- [ ] Database sanitization GDPR compliant

---

## Configuration Schema (Complete)

```yaml
# cnwp.yml - Full schema

settings:
  url: yourdomain.org
  database: mariadb
  php: 8.2
  delete_site_yml: true

recipes:
  myrecipe:
    source: drupal/recommended-project:^10.2
    profile: standard
    webroot: web
    dev_modules: devel webprofiler
    dev_composer: drupal/devel:^5.0
    reinstall_modules: module1 module2
    prod_method: rsync
    prod_server: linode1
    prod_domain: example.com
    prod_path: /var/www/html

sites:
  mysite:
    directory: /path/to/site
    recipe: myrecipe
    environment: development
    purpose: indefinite
    created: 2025-01-01T00:00:00Z

linode:
  servers:
    linode1:
      ip: 1.2.3.4
      user: deploy
      ssh_key: ~/.ssh/nwp

git_backup:
  enabled: true
  method: push
  auto_commit: true
  auto_push: false
  remotes:
    primary:
      type: github
      url: git@github.com:user/site.git
    secondary:
      type: nwp_gitlab
      url: git@gitlab.local:backups/site.git
  schedule:
    enabled: false
    database: "0 2 * * *"
    full: "0 3 * * 0"
    bundle: "0 4 1 * *"
  notifications:
    email: admin@example.com
    on_failure: true

ci:
  provider: gitlab
  gitlab:
    url: https://gitlab.local
    runner_tag: nwp
  testing:
    local: [phpcs, phpstan, phpunit-unit]
    provisioned: [phpunit-kernel, behat]
    ci: [all]
  coverage:
    threshold: 80
    badge: true
```

---

## References

### Research Documents
- [GIT_BACKUP_RECOMMENDATIONS.md](./GIT_BACKUP_RECOMMENDATIONS.md) - Git backup analysis
- [NWP_CI_TESTING_STRATEGY.md](./NWP_CI_TESTING_STRATEGY.md) - CI/CD strategy
- [IMPROVEMENTS.md](./IMPROVEMENTS.md) - Original roadmap

### External Sources
- Vortex: Enterprise Drupal patterns
- Pleasy: Lightweight git backup
- Open Social: Behat testing (30 features, 134 scenarios)
- GitLab CI: Pipeline patterns
- Industry: 3-2-1 backup rule, 80% coverage threshold

### NWP Documentation
- [README.md](../README.md) - Main documentation
- [SETUP.md](./SETUP.md) - Setup guide
- [PRODUCTION_DEPLOYMENT.md](./PRODUCTION_DEPLOYMENT.md) - Deployment guide
- [TESTING_GUIDE.md](./TESTING_GUIDE.md) - Testing guide

---

*Document created: December 30, 2025*
*Supersedes: IMPROVEMENTS.md (retained for historical reference)*
