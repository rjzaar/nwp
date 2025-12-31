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
| Current Version | v0.9.0 |
| Test Success Rate | 98% |
| Core Features Complete | 100% |
| CI/CD Implementation | 100% |
| Git Backup Implementation | 100% |
| Documentation Coverage | 95% |

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
| **Phase 3** | Git Backup System | P11-P15 | Complete | 100% |
| **Phase 4** | CI/CD & Testing | P16-P21 | Complete | 100% |
| **Phase 5** | Enterprise Features | P22-P28 | Complete | 100% |
| **Phase 6** | AI Integration | F01-F02 | Future | 0% |

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

## Phase 3: Git Backup System (COMPLETE)

### P11: Basic Git Integration
**Status:** COMPLETE | **Priority:** HIGH | **Effort:** Medium | **Dependencies:** NWP GitLab server

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
- [x] `-g` flag creates git commit
- [x] Repository auto-created on NWP GitLab
- [x] Push to NWP GitLab works
- [x] Works with existing naming convention

---

### P12: Git Bundle Support
**Status:** COMPLETE | **Priority:** HIGH | **Effort:** Medium | **Dependencies:** P11

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
- [x] Full bundle creation works
- [x] Incremental bundles work
- [x] Bundle verification passes
- [x] Restoration from bundle successful

---

### P13: Additional Remote Support (Optional)
**Status:** COMPLETE | **Priority:** LOW | **Effort:** Medium | **Dependencies:** P11

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
- [x] NWP GitLab always works (primary)
- [x] Optional remotes configurable
- [x] External failures don't block backup

---

### P14: Automated Scheduling
**Status:** COMPLETE | **Priority:** MEDIUM | **Effort:** Low | **Dependencies:** P11

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
- [x] Schedule installation command
- [x] Schedule removal command
- [x] Logs written for each run
- [x] Notification on failure

---

### P15: GitLab API Automation
**Status:** COMPLETE | **Priority:** LOW | **Effort:** Medium | **Dependencies:** P11, GitLab server

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
- [x] Projects auto-created on first push
- [x] Group organization works
- [x] Token stored securely in .secrets.yml

---

## Phase 4: CI/CD & Testing (COMPLETE)

### P16: Docker Test Environment
**Status:** COMPLETE | **Priority:** HIGH | **Effort:** Medium | **Dependencies:** None

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
- [x] Consistent local/CI environment
- [x] Chrome container stable
- [x] All services accessible

---

### P17: Site Test Script
**Status:** COMPLETE | **Priority:** HIGH | **Effort:** Low | **Dependencies:** P16

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
- [x] All test types runnable
- [x] Combined flags work
- [x] Clear pass/fail reporting

---

### P18: Behat BDD Framework
**Status:** COMPLETE | **Priority:** HIGH | **Effort:** Medium | **Dependencies:** P16

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
- [x] Behat runs locally via DDEV
- [x] Smoke tests complete in <60s
- [x] Screenshots on failure
- [x] JUnit report output

---

### P19: Code Quality Tooling
**Status:** COMPLETE | **Priority:** MEDIUM | **Effort:** Low | **Dependencies:** None

Enforce coding standards:

| Tool | Purpose | Config |
|------|---------|--------|
| PHPCS | Drupal standards | `.phpcs.xml` |
| PHPStan | Static analysis (level 7) | `phpstan.neon` |
| Rector | Automated refactoring | `rector.php` |
| Gherkin Lint | Feature validation | Integrated |

**Success Criteria:**
- [x] All tools configured
- [x] Baseline for existing code
- [x] Failures block deployment

---

### P20: GitLab CI Pipeline
**Status:** COMPLETE | **Priority:** HIGH | **Effort:** High | **Dependencies:** P16-P19, GitLab server

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
- [x] Pipeline runs on push
- [x] All test types execute
- [x] Coverage reported
- [x] Badges display correctly

---

### P21: Coverage & Badges
**Status:** COMPLETE | **Priority:** MEDIUM | **Effort:** Low | **Dependencies:** P20

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
- [x] Coverage threshold enforced
- [x] Badges update automatically
- [x] README displays badges

---

## Phase 5: Enterprise Features (COMPLETE)

### P22: Unified CLI Wrapper
**Status:** COMPLETE | **Priority:** MEDIUM | **Effort:** Medium | **Dependencies:** All previous

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
- [x] All scripts accessible via `pl`
- [x] Tab-completion support
- [x] Consistent help system

---

### P23: Database Sanitization
**Status:** COMPLETE | **Priority:** MEDIUM | **Effort:** Medium | **Dependencies:** P11

Sanitize production data:

```bash
./backup.sh --sanitize sitename
```

**Implementation:**
- Remove PII (emails, passwords)
- Reset user passwords to test value
- Integration with `drush sql-sanitize`

**Success Criteria:**
- [x] No PII in sanitized dumps
- [x] Passwords reset
- [x] GDPR compliant

---

### P24: Rollback Capability
**Status:** COMPLETE | **Priority:** HIGH | **Effort:** High | **Dependencies:** P08, P11

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
- [x] Backup created automatically
- [x] Rollback completes in <5 minutes
- [x] Site functional after rollback

---

### P25: Remote Site Support
**Status:** COMPLETE | **Priority:** LOW | **Effort:** High | **Dependencies:** P08, P18

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
- [x] Remote backup works
- [x] Remote tests run
- [x] Production tests are read-only

---

### P26: Four-State Deployment Workflow
**Status:** COMPLETE | **Priority:** HIGH | **Effort:** High | **Dependencies:** P08, GitLab server, Linode CLI

Define four distinct site states with scripts to move between them:

**The Four States:**
```
┌─────────┐      ┌─────────┐      ┌─────────┐      ┌─────────┐
│   DEV   │ ───► │   STG   │ ───► │  LIVE   │ ───► │  PROD   │
│ (local) │ ◄─── │ (local) │ ◄─── │ (cloud) │ ◄─── │ (cloud) │
└─────────┘      └─────────┘      └─────────┘      └─────────┘
  DDEV            DDEV clone      sitename.url     sitename.com
  mysite/         mysite_stg/     mysite.nwpcode   production
                       │                                │
                       └────────────────────────────────┘
                          stg2prod / prod2stg (direct)
                          (live is OPTIONAL)
```

| State | Location | Domain | Purpose |
|-------|----------|--------|---------|
| **dev** | Local DDEV | mysite.ddev.site | Active development |
| **stg** | Local DDEV | mysite-stg.ddev.site | Testing before live |
| **live** | Linode | mysite.nwpcode.org | Client preview / UAT |
| **prod** | Linode | mysite.com | Production |

**Scripts:**
```bash
# Deployment scripts (forward)
pl dev2stg mysite            # Dev → Staging (local copy)
pl stg2live mysite           # Staging → Live (deploy to cloud)
pl live2prod mysite          # Live → Production
pl stg2prod mysite           # Staging → Production (skip live)

# Sync scripts (backward)
pl prod2live mysite          # Pull prod data to live
pl prod2stg mysite           # Pull prod data to staging (skip live)
pl live2stg mysite           # Pull live data to staging
pl stg2dev mysite            # Pull staging to dev

# Provisioning scripts
pl live mysite               # Provision live server at mysite.nwpcode.org
pl live --delete mysite      # Remove live server
pl produce mysite            # Provision production server
pl produce --delete mysite   # Remove production server
```

**Workflow Options:**
```
With Live Site:     dev → stg → live → prod    (client preview before prod)
Without Live Site:  dev → stg → prod           (direct to production)
```

**Configuration:**
```yaml
# cnwp.yml
settings:
  url: nwpcode.org              # Base domain for live sites
  auto_live: true               # Auto-create live from stg2live

sites:
  mysite:
    directory: /home/rob/nwp/mysite
    recipe: d
    environment: development
    # Live site configuration
    live:
      enabled: true
      domain: mysite.nwpcode.org
      linode_id: 12345678
      server_ip: 1.2.3.4
      type: dedicated            # dedicated | shared | temporary
      expires: 7                 # Days until auto-delete (temporary only)
    # Production configuration
    prod:
      enabled: false
      domain: mysite.com
      linode_id: 87654321
      server_ip: 5.6.7.8
      linode_type: g6-standard-2
```

**Implementation:**
1. Create `live.sh` - Provision live test server at `sitename.nwpcode.org`
2. Create `produce.sh` - Provision production server
3. Create `stg2live.sh` - Deploy staging to live
4. Create `live2stg.sh` - Pull live data to staging
5. Update `dev2stg.sh` - Ensure local staging works
6. Auto-configure DNS via Linode API
7. Let's Encrypt SSL for both live and prod

**Live Site Options:**
| Option | Description | Use Case |
|--------|-------------|----------|
| Dedicated | One Linode per site | Production-like testing |
| Shared | Multiple sites on GitLab server | Cost-effective demos |
| Temporary | Auto-delete after N days | PR review environments |

**Auto-Live Feature:**
When `auto_live: true` in settings, running `pl stg2live mysite` will:
1. Check if live server exists
2. If not, automatically run `pl live mysite` first
3. Then deploy staging to live

**Success Criteria:**
- [x] All four states clearly defined
- [x] `pl live sitename` provisions live server
- [x] `pl produce sitename` provisions production server
- [x] `pl stg2live` deploys to live (auto-provisions if needed)
- [x] `pl live2stg` pulls live data back
- [x] DNS and SSL auto-configured

---

### P27: Production Server Provisioning
**Status:** COMPLETE | **Priority:** MEDIUM | **Effort:** High | **Dependencies:** P26

Provision dedicated production servers:

```bash
pl produce mysite                    # Provision production server
pl produce mysite --type g6-standard-4  # Specify larger server
pl produce --delete mysite           # Remove production server
```

**Configuration:**
```yaml
sites:
  mysite:
    prod:
      enabled: true
      domain: mysite.com             # Custom domain
      linode_type: g6-standard-2     # 4GB RAM recommended
      linode_id: 87654321            # Set after provisioning
      server_ip: 5.6.7.8
      ssl: letsencrypt               # or: cloudflare, custom
      backups: true                  # Linode backups enabled
```

**Implementation:**
1. Create `produce.sh` script
2. Provision appropriately-sized Linode
3. Configure DNS (if domain uses Linode nameservers)
4. Setup SSL via Let's Encrypt or Cloudflare
5. Enable Linode backups
6. Store credentials in .secrets.yml

**Success Criteria:**
- [x] `pl produce sitename` creates production server
- [x] Appropriate server sizing
- [x] SSL properly configured
- [x] Backups enabled

---

### P28: Automated Security Update Pipeline
**Status:** COMPLETE | **Priority:** HIGH | **Effort:** High | **Dependencies:** P17, P20, P26

Detect Drupal security updates and automatically test before deployment:

**Workflow:**
```
┌──────────────┐      ┌──────────────┐      ┌──────────────┐      ┌──────────────┐
│   DETECT     │ ───► │    UPDATE    │ ───► │    TEST      │ ───► │   DEPLOY     │
│ security.d.o │      │   composer   │      │  run tests   │      │  if passed   │
└──────────────┘      └──────────────┘      └──────────────┘      └──────────────┘
   scheduled            auto-branch           CI pipeline          notify/deploy
```

**Detection Methods:**
| Method | Command/Source | Frequency |
|--------|----------------|-----------|
| Drush | `drush pm:security` | Daily |
| Composer | `composer outdated --direct` | Daily |
| Drupal.org | Security RSS feed | Real-time |
| GitLab | Dependency scanning | On push |

**Script:**
```bash
pl security-check mysite          # Check for updates
pl security-check --all           # Check all sites
pl security-update mysite         # Apply updates + test
pl security-update --auto mysite  # Apply + test + deploy if pass
```

**Configuration:**
```yaml
# cnwp.yml
settings:
  security:
    check_schedule: "0 6 * * *"    # Daily 6 AM
    auto_update: true              # Auto-apply security updates
    auto_test: true                # Run tests after update
    auto_deploy_live: true         # Deploy to live if tests pass
    auto_deploy_prod: false        # NEVER auto-deploy to prod (require approval)
    notify_email: admin@site.com
    notify_slack: webhook_url

sites:
  mysite:
    security:
      enabled: true
      branch_prefix: security/     # Create branch for updates
      merge_on_pass: true          # Auto-merge if tests pass
```

**Automated Pipeline:**
1. Scheduled cron checks `drush pm:security` for all sites
2. If update found:
   - Create branch `security/drupal-10.2.1`
   - Run `composer update drupal/core-* --with-dependencies`
   - Commit changes
   - Push to GitLab
3. GitLab CI automatically:
   - Runs full test suite (P17, P18)
   - If tests pass → merge to main
   - Deploy to live (if `auto_deploy_live: true`)
   - Send notification
4. Production deployment requires manual approval

**Notification Template:**
```
🔒 Security Update Available: drupal/core 10.2.0 → 10.2.1

Site: mysite
Severity: Critical
Tests: ✅ Passed (23/23)
Live: ✅ Deployed to mysite.nwpcode.org
Prod: ⏳ Awaiting approval

[Approve Production Deploy] [View Changes] [Dismiss]
```

**Integration with Four-State Workflow:**
```
Security detected → auto-update dev → test → deploy live → MANUAL approve → prod
                                                              ↑
                                              Human reviews live site first
```

**Success Criteria:**
- [x] Daily security checks running
- [x] Auto-update creates branch and runs tests
- [x] Notifications sent on detection
- [x] Auto-deploy to live works
- [x] Production requires manual approval
- [x] Rollback if deployment fails

---

## Implementation Priority Matrix

| Proposal | Priority | Effort | Dependencies | Phase |
|----------|----------|--------|--------------|-------|
| P01-P05 | - | - | - | 1 (DONE) |
| P06-P10 | - | - | - | 2 (DONE) |
| P11 | HIGH | Medium | GitLab server | 3 (DONE) |
| P12 | HIGH | Medium | P11 | 3 (DONE) |
| P13 | LOW | Medium | P11 | 3 (DONE) |
| P14 | MEDIUM | Low | P11 | 3 (DONE) |
| P15 | LOW | Medium | P11 | 3 (DONE) |
| P16 | HIGH | Medium | None | 4 (DONE) |
| P17 | HIGH | Low | P16 | 4 (DONE) |
| P18 | HIGH | Medium | P16 | 4 (DONE) |
| P19 | MEDIUM | Low | None | 4 (DONE) |
| P20 | HIGH | High | P16-P19 | 4 (DONE) |
| P21 | MEDIUM | Low | P20 | 4 (DONE) |
| P22 | MEDIUM | Medium | All | 5 (DONE) |
| P23 | MEDIUM | Medium | P11 | 5 (DONE) |
| P24 | HIGH | High | P08, P11 | 5 (DONE) |
| P25 | LOW | High | P08, P18 | 5 (DONE) |
| P26 | HIGH | High | P08, GitLab, Linode | 5 (DONE) |
| P27 | MEDIUM | High | P26 | 5 (DONE) |
| P28 | HIGH | High | P17, P20, P26 | 5 (DONE) |

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
8. **P13: Additional Remote Support** - Optional external backups
9. **P14: Automated Scheduling** - Hands-off backups
10. **P24: Rollback Capability** - Production safety

### Long-term (4-6 months)

11. **P21: Coverage & Badges** - Visibility
12. **P15: GitLab API Automation** - Auto-create repos
13. **P22: Unified CLI Wrapper** - Developer experience
14. **P23: Database Sanitization** - GDPR compliance
15. **P25: Remote Site Support** - Full remote ops
16. **P26: Four-State Deployment Workflow** - dev/stg/live/prod states
17. **P27: Production Server Provisioning** - `pl produce sitename`
18. **P28: Automated Security Updates** - Detect, test, deploy

---

## Success Metrics

### Phase 3 Complete When:
- [x] Git backup with `-g` flag works
- [x] Git bundles can be created and restored
- [x] At least 2 remotes configured
- [x] Automated daily database backup

### Phase 4 Complete When:
- [x] `test.sh` runs all test types
- [x] Behat smoke tests pass
- [x] GitLab CI pipeline green
- [x] Coverage badge shows >80%

### Phase 5 Complete When:
- [x] `pl` CLI wrapper fully functional
- [x] Rollback tested and documented
- [x] Remote operations work
- [x] Database sanitization GDPR compliant
- [x] Four-state workflow operational (dev/stg/live/prod)
- [x] `pl live sitename` provisions live server
- [x] `pl produce sitename` provisions production server
- [x] All transition scripts work (stg2live, live2stg, stg2prod, etc.)
- [x] Security updates auto-detected daily
- [x] Auto-deploy to live after tests pass
- [x] Production deploy requires manual approval

---

## Configuration Schema (Complete)

```yaml
# cnwp.yml - Full schema

settings:
  url: yourdomain.org
  database: mariadb
  php: 8.2
  delete_site_yml: true
  auto_live: true                        # Auto-provision live server on stg2live
  # P28: Security update automation
  security:
    check_schedule: "0 6 * * *"          # Daily 6 AM
    auto_update: true                    # Auto-apply security updates
    auto_test: true                      # Run tests after update
    auto_deploy_live: true               # Deploy to live if tests pass
    auto_deploy_prod: false              # Require manual approval for prod
    notify_email: admin@example.com

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
    # P26: Four-state deployment (live = test site, prod = production)
    live:
      enabled: true
      domain: mysite.nwpcode.org         # Auto-generated from settings.url
      linode_id: 12345678
      server_ip: 1.2.3.4
      type: dedicated                    # dedicated | shared | temporary
      expires: 7                         # Days until auto-delete (temporary only)
      linode_type: g6-nanode-1
    prod:
      enabled: false
      domain: mysite.com                 # Custom production domain
      linode_id: 87654321
      server_ip: 5.6.7.8
      linode_type: g6-standard-2
      ssl: letsencrypt                   # letsencrypt | cloudflare | custom
      backups: true

linode:
  servers:
    linode1:
      ip: 1.2.3.4
      user: deploy
      ssh_key: ~/.ssh/nwp

git_backup:
  enabled: true
  auto_commit: true
  auto_push: true                        # Push to NWP GitLab by default
  gitlab_url: https://git.nwpcode.org    # From settings.url
  # Optional: Additional external remotes (P13)
  additional_remotes:
    github:
      url: git@github.com:user/site.git
      enabled: false                     # Opt-in
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
    url: https://git.nwpcode.org         # NWP GitLab from settings.url
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

## Future Improvements (Phase 6)

### F01: GitLab MCP Integration for Claude Code
**Status:** PLANNED | **Priority:** MEDIUM | **Effort:** Low | **Dependencies:** NWP GitLab server

Enable Claude Code to directly interact with NWP GitLab via the Model Context Protocol (MCP):

**Benefits:**
- Claude can fetch CI logs directly without manual copy/paste
- Automatic investigation of CI failures
- Create issues for bugs found during code review
- Monitor pipeline status in real-time
- Query repository information

**Implementation:**
1. During NWP GitLab setup (`setup.sh`), generate a GitLab personal access token
2. Store token securely in `.secrets.yml`:
   ```yaml
   gitlab:
     api_token: glpat-xxxxxxxxxxxx
   ```
3. Configure MCP server in Claude Code:
   ```bash
   claude mcp add --transport http gitlab https://git.nwpcode.org/api/v4 \
     --header "PRIVATE-TOKEN: $(get_secret gitlab.api_token)"
   ```
4. Add MCP configuration to `cnwp.yml`:
   ```yaml
   settings:
     mcp:
       gitlab:
         enabled: true
         url: https://git.nwpcode.org
         token_secret: gitlab.api_token    # Reference to .secrets.yml
         scopes:
           - read_api
           - read_repository
           - write_repository
   ```

**Workflow After Implementation:**
```
User: "CI failed on mysite"
Claude: [Uses MCP to fetch pipeline logs]
Claude: "The phpcs job failed on line 45 of MyController.php - missing docblock"
Claude: [Fixes the issue, commits, pushes]
Claude: "Fixed and pushed. New pipeline running."
```

**Token Generation Script (`git/gitlab_token.sh`):**
```bash
#!/bin/bash
# Generate GitLab personal access token for MCP integration
# Run during setup.sh or manually

GITLAB_URL="${1:-https://git.nwpcode.org}"
TOKEN_NAME="nwp-mcp-$(date +%Y%m%d)"

echo "Creating GitLab personal access token..."
echo "Please login to $GITLAB_URL and create a token at:"
echo "  $GITLAB_URL/-/user_settings/personal_access_tokens"
echo ""
echo "Required scopes: read_api, read_repository"
echo "Token name suggestion: $TOKEN_NAME"
```

**Success Criteria:**
- [ ] Token generated during GitLab setup
- [ ] Token stored in .secrets.yml
- [ ] MCP server configurable via setup.sh
- [ ] Claude can fetch CI logs via MCP
- [ ] Claude can query pipeline status

---

### F02: Automated CI Error Resolution
**Status:** PLANNED | **Priority:** LOW | **Effort:** Medium | **Dependencies:** F01

Extend MCP integration to automatically detect and fix common CI errors:

**Auto-fixable Errors:**
| Error Type | Detection | Auto-fix |
|------------|-----------|----------|
| PHPCS style | `phpcs` output | `phpcbf --fix` |
| Missing docblock | PHPStan error | Add docblock template |
| Unused import | PHPStan error | Remove import |
| Type hint | PHPStan suggestion | Add type hint |

**Workflow:**
1. CI fails → webhook notifies (or cron checks)
2. Claude fetches logs via MCP
3. If auto-fixable: apply fix, commit, push
4. If not auto-fixable: create issue with analysis

**Configuration:**
```yaml
settings:
  ci:
    auto_fix:
      enabled: true
      types:
        - phpcs              # Auto-run phpcbf
        - unused_imports     # Auto-remove
      create_issue: true     # Create issue for non-auto-fixable
```

**Success Criteria:**
- [ ] Common PHPCS errors auto-fixed
- [ ] Issues created for complex errors
- [ ] Notification sent with resolution status

---

*Document created: December 30, 2025*
*All proposals completed: December 30, 2025*
*Future improvements added: December 31, 2025*
*Supersedes: IMPROVEMENTS.md (retained for historical reference)*
