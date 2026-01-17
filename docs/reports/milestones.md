# NWP Milestones - Completed Implementation History

**Last Updated:** January 17, 2026

A summary of all completed development phases and their key achievements.

---

## Overview

| Phase | Focus | Proposals | Completed |
|-------|-------|-----------|-----------|
| Phase 1 | Foundation & Polish | P01-P05 | Dec 2025 |
| Phase 2 | Production & Tracking | P06-P10 | Dec 2025 |
| Phase 3 | Git Backup System | P11-P15 | Dec 2025 |
| Phase 4 | CI/CD & Testing | P16-P21 | Dec 2025 |
| Phase 5 | Enterprise Features | P22-P28 | Dec 2025 |
| Phase 5b | Infrastructure & Import | P29-P31 | Jan 2026 |
| Phase 5c | Live Deployment Automation | P32-P35 | Jan 2026 |
| Phase 6-7 | Governance, Security & Testing | F04, F05, F07, F09 | Jan 2026 |
| Phase 8 | Unified Verification | P50 | Jan 2026 |
| AVC | Profile Enhancements | Email Reply | Jan 2026 |

**Total: 40 proposals implemented** (P01-P35 + F04, F05, F07, F09, P50) + AVC Profile Enhancements

---

## Phase 1: Foundation & Polish

### P01: Unified Script Architecture
Consolidated 6+ scripts into 5 unified, multi-purpose scripts with consistent CLI.
- `backup.sh`, `restore.sh`, `copy.sh`, `make.sh`, `dev2stg.sh`
- Combined flags support (e.g., `-bfyo`)

### P02: Environment Naming Convention
Hyphenated postfix-based naming for DDEV compatibility: `sitename`, `sitename-stg`, `sitename-prod`

### P03: Enhanced Error Messages
Specific diagnostics replacing generic messages. Users can self-diagnose 80% of issues.

### P04: Combined Flags Documentation
Help texts include combined flag examples for all scripts.

### P05: Test Suite Infrastructure
`test-nwp.sh` with 77 tests, 98% pass rate, automatic retry, color-coded output.

---

## Phase 2: Production & Tracking

### P06: Sites Tracking System
Automatic site registration in `cnwp.yml` with `lib/yaml-write.sh` (9 YAML functions).

### P07: Module Reinstallation
Reads `reinstall_modules` from recipe config for automated module management.

### P08: Production Deployment Script
`stg2prod.sh` (~750 lines) with 10-step workflow, dry-run, resume capability.

### P09: Setup Automation
Enhanced `setup.sh` with 18 components, rollback support, GitLab provisioning.

### P10: Configuration System Enhancement
Extended `cnwp.yml` schema with settings, recipes, sites, and linode sections.

---

## Phase 3: Git Backup System

### P11: Basic Git Integration
`-g` flag in `backup.sh` with NWP GitLab as default remote. Auto-creates repos.

### P12: Git Bundle Support
Offline/archival backups via `--bundle` flag. Full and incremental bundles.

### P13: Additional Remote Support
Optional external remotes (GitHub, local) for 3-2-1 backup rule compliance.

### P14: Automated Scheduling
Cron-based backup automation with email notifications on failure.

### P15: GitLab API Automation
API-driven project auto-creation, group organization, token management.

---

## Phase 4: CI/CD & Testing

### P16: Docker Test Environment
Standardized test environment: cli, nginx, php, database, chrome containers.

### P17: Site Test Script
`test.sh` with flags: `-l` (lint), `-u` (unit), `-s` (smoke), `-b` (behat), `-p` (parallel).

### P18: Behat BDD Framework
Behavior-driven testing with profiles, tags (@smoke, @api, @javascript), JUnit output.

### P19: Code Quality Tooling
PHPCS (Drupal standards), PHPStan (level 7), Rector, Gherkin Lint.

### P20: GitLab CI Pipeline
Three-stage pipeline (BUILD → VALIDATE → TEST) with database caching, parallel Behat.

### P21: Coverage & Badges
80% coverage threshold, auto-updating badges, README integration.

---

## Phase 5: Enterprise Features

### P22: Unified CLI Wrapper
Enhanced `pl` command: `pl install`, `pl backup`, `pl test`, `pl deploy`, etc.

### P23: Database Sanitization
`--sanitize` flag removes PII, resets passwords, GDPR compliant.

### P24: Rollback Capability
Automatic backup before deployment, one-command rollback, verification.

### P25: Remote Site Support
`@prod` alias for remote operations, SSH tunnel integration, read-only production tests.

### P26: Four-State Deployment Workflow
```
DEV (local) → STG (local) → LIVE (cloud) → PROD (cloud)
```
Scripts: `dev2stg`, `stg2live`, `live2prod`, `stg2prod`, `prod2stg`, `live2stg`

### P27: Production Server Provisioning
`pl produce mysite` provisions dedicated production servers with SSL and backups.

### P28: Automated Security Update Pipeline
Daily security checks, auto-update branches, CI testing, live auto-deploy, prod manual approval.

---

## Phase 5b: Infrastructure & Import

### P29: Live Site Import System
`import.sh` with server discovery, TUI site selection, database sanitization, Stage File Proxy.

### P30: Modular Install Architecture
82% code reduction in install.sh. Lazy-loaded libraries: drupal, moodle, gitlab, podcast.

### P31: Enhanced Site Management TUI
`modify.sh` with option documentation (`d` key), environment switching (`<>` keys), orphaned site detection.

---

## Phase 5c: Live Deployment Automation

### P32: Profile Module Symlink Auto-Creation
`_create_profile_symlinks()` in `lib/install-common.sh` automatically creates module/theme symlinks for custom profiles during `install_git_profile()`.

### P33: Live Server Infrastructure Setup
`lib/live-server-setup.sh` (503 lines) with functions: `ensure_php_fpm()`, `ensure_mariadb()`, `create_site_database()`, `configure_nginx_drupal()`, `provision_drupal_stack()`. Ubuntu 22.04/24.04 support, idempotent execution.

### P34: Database Deployment in stg2live.sh
`deploy_database()` function exports via `ddev export-db`, SCP transfers to live server, imports via mysql CLI. Automatic cleanup of temporary files.

### P35: Production Settings Generation
`generate_live_settings()` in `lib/install-common.sh` generates `settings.local.php` with production database credentials, hash_salt, performance settings, trusted host patterns.

---

## Phase 6-7: Governance, Security & Testing

### F05: Security Headers & Hardening
Comprehensive security header configuration for nginx deployments, protecting sites from common web vulnerabilities.

**Headers Implemented:**
- `Strict-Transport-Security` (HSTS) - 1 year with includeSubDomains
- `Content-Security-Policy` - Drupal-compatible CSP
- `Referrer-Policy` - strict-origin-when-cross-origin
- `Permissions-Policy` - Disable geolocation, microphone, camera
- `server_tokens off` - Hide nginx version
- `fastcgi_hide_header` - Remove X-Generator, X-Powered-By

**Implementation:**
- Security headers in `stg2live.sh` nginx config generation
- Security headers in `linode_deploy.sh` templates
- Server version hiding
- CMS fingerprinting header removal

### F04: Distributed Contribution Governance (Phases 1-5)
Established governance framework for distributed NWP development, enabling secure collaboration across multiple developers.

**Key Components:**
- Multi-tier repository topology (Canonical → Primary → Developer)
- Architecture Decision Records (ADRs) for tracking design decisions
- Issue queue categories following Drupal's model (Bug, Task, Feature, Support, Plan)
- Developer role system (Newcomer → Contributor → Core → Steward)
- CLAUDE.md as "standing orders" for AI-assisted governance

**Phases 1-5 Complete:**
1. **Foundation** - Decision records, ADR templates, `docs/decisions/` directory
2. **Developer Roles** - `docs/ROLES.md`, access level definitions
3. **Onboarding Automation** - `coder-setup.sh provision/remove`, full lifecycle management
4. **Developer Level Detection** - `lib/developer.sh` library for role detection
5. **Coders TUI** - `scripts/commands/coders.sh` with arrow navigation, bulk actions, SSH status tracking

**Key Features:**
- Automated Linode provisioning via `coder-setup.sh provision`
- Full offboarding with GitLab cleanup via `coder-setup.sh remove`
- SSH status column showing if coder has SSH keys on GitLab
- Onboarding status tracking (GL, GRP, SSH, NS, DNS, SRV, SITE columns)
- Role-based requirement checking for Core/Steward developers

**Phases 6-8 Pending:**
- Phase 6: Issue Queue (GitLab labels, templates)
- Phase 7: Multi-Tier Support (upstream sync, contribute commands)
- Phase 8: Security Review System (malicious code detection)

### F07: SEO & Search Engine Control
Comprehensive search engine control ensuring staging sites are protected while production sites are optimized for discoverability.

**Staging Protection (4 Layers):**
| Layer | Method | Purpose |
|-------|--------|---------|
| 1 | X-Robots-Tag header | `noindex, nofollow` on all responses |
| 2 | robots.txt | `Disallow: /` for all crawlers |
| 3 | Meta robots | noindex on all Drupal pages |
| 4 | HTTP Basic Auth | Optional access control |

**Production Optimization:**
- Sitemap.xml generation via Simple XML Sitemap module
- robots.txt with `Sitemap:` directive
- AI crawler controls (GPTBot, ClaudeBot, etc.)
- Proper canonical URLs and meta tags

**Implementation:**
- X-Robots-Tag header on staging nginx configs
- `templates/robots-staging.txt` for staging environments
- `templates/robots-production.txt` with sitemap reference
- Environment detection in deployment scripts (`stg2live.sh`, `linode_deploy.sh`)
- SEO settings in cnwp.yml schema

### F09: Comprehensive Testing Infrastructure
Automated testing infrastructure using BATS framework with GitLab CI integration, plus interactive verification console.

**Test Suites:**
- Unit tests (BATS) - ~2 minutes, 76 tests, function-level validation
- Integration tests (BATS) - ~5 minutes, 72 tests, workflow validation
- E2E tests (Linode) - Infrastructure ready, tests pending

**Test Structure:**
| Directory | Purpose | Tests |
|-----------|---------|-------|
| `tests/unit/` | Function-level tests | 76 tests |
| `tests/integration/` | Workflow tests | 72 tests |
| `tests/e2e/` | Full deployment tests | Placeholder |
| `tests/helpers/` | Shared test utilities | - |

**Key Components:**
- GitLab CI pipeline with lint, test, e2e stages
- `scripts/commands/run-tests.sh` unified test runner
- Shared utilities in `tests/helpers/test-helpers.bash`

**Verification Console (v0.18.0-v0.19.0):**
- Interactive TUI with arrow navigation (`pl verify`)
- Keyboard shortcuts: v:Verify, i:Checklist, u:Unverify, h:History, n:Notes, p:Preview
- Category and feature navigation with arrow keys
- Interactive checklist editor with Space to toggle items
- Notes editor with auto-detection (nano/vim/vi)
- History timeline showing all verification events
- Auto-verification when all checklist items completed
- Perfect for distributed teams - each person completes different items
- Verification schema v2 with individual checklist item tracking and audit trail

**Coverage Status:**
| Category | Current | Target |
|----------|---------|--------|
| Unit | ~40% | 80% |
| Integration | ~60% | 95% |
| E2E | ~10% | 80% |
| **Overall** | **~45%** | **85%** |

---

## Phase 8: Unified Verification System

### P50: Layered Verification System
Unified verification system combining machine-automated testing with human verification tracking, replacing the deprecated test-nwp.sh script.

**Key Components:**
| Component | Purpose |
|-----------|---------|
| `scripts/commands/verify.sh` | Main verification command (3,600+ lines) |
| `lib/verify-runner.sh` | Shared test infrastructure |
| `.verification.yml` | Verification state tracking (571 items) |
| `.badges.json` | Coverage statistics for README |

**Features:**
- **Machine Verification**: Automated tests at 4 depth levels (basic, standard, thorough, paranoid)
- **Human Verification**: Interactive TUI for manual confirmation tracking
- **Badges**: Shields.io-compatible JSON for README coverage display
- **CI/CD Integration**: GitLab CI and GitHub Actions examples

**Commands:**
```bash
pl verify                        # Interactive TUI
pl verify --run                  # Run machine tests
pl verify --run --depth=thorough # Full verification
pl verify badges                 # Generate coverage badges
pl verify status                 # Show verification summary
```

**Coverage:**
| Metric | Value |
|--------|-------|
| Total Items | 571 |
| Features | 90+ |
| Machine Verification | 40.7% |
| Depth Levels | 4 |

**Deprecates:**
- `test-nwp.sh` - Removed (no wrapper, clean break)
- `pl test-nwp` - Redirects to `pl verify --run` with deprecation notice

---

## AVC Profile Enhancements

### AVC Email Reply System
Allows group members to reply to notification emails to create comments on content. Users receive notification emails with `Reply-To: reply+{token}@domain` headers and can respond directly via email.

**Architecture:**
```
Outbound: Notification → Reply-To: reply+{token}@domain → User Inbox
Inbound:  User Reply → Webhook /api/email/inbound → Queue → Comment
```

**Key Components:**
- HMAC-SHA256 token generation with 30-day expiration
- Email provider integration (SendGrid Inbound Parse, Mailgun Routes)
- Queue-based async processing for reliability
- Rate limiting (10/hour, 50/day per user; 100/hour per group)
- Spam filtering with configurable score threshold
- Content sanitization before comment creation

**Implementation:**
- `avc_email_reply` module with controller, services, queue worker
- Drush commands: `email-reply:status`, `email-reply:enable`, `email-reply:configure`, etc.
- DDEV testing command: `ddev email-reply-test`
- Web UI testing: `/admin/config/avc/email-reply/test`
- Auto-configuration via recipe system in `cnwp.yml`
- Post-install script for environment-aware setup

**Files:**
| File | Purpose |
|------|---------|
| `InboundEmailController.php` | Webhook endpoint for email providers |
| `EmailReplyTestController.php` | Testing UI |
| `ReplyTokenService.php` | Token generation/validation |
| `EmailReplyProcessor.php` | Email processing logic |
| `EmailReplyWorker.php` | Queue worker |
| `EmailRateLimiter.php` | Rate limiting service |
| `EmailReplyCommands.php` | Drush commands |
| `configure_email_reply.php` | Post-install configuration |

**Testing:**
- DDEV command: `ddev email-reply-test {setup|test|simulate|webhook|queue}`
- Web UI: `/admin/config/avc/email-reply/test`
- End-to-end automated testing via Drush commands

---

## Key Metrics Achieved

| Metric | Value |
|--------|-------|
| Test Success Rate | 98% |
| Code Coverage Threshold | 80% |
| install.sh Code Reduction | 82% |
| Manual Steps Automated | 85%+ |

---

## Implementation Details

For detailed implementation specifications, see:
- [Scripts Implementation](../reference/scripts-implementation.md) - Script architecture
- [Backup Implementation](../reference/backup-implementation.md) - Backup system
- [CI/CD](../deployment/cicd.md) - CI/CD pipeline setup
- [Testing](../testing/testing.md) - Testing framework
- [Developer Workflow](../guides/developer-workflow.md) - Complete workflow

---

## Research Sources

These external projects informed NWP's implementation:

| Source | Key Patterns Adopted |
|--------|---------------------|
| **Vortex** | Docker CI, 7 code quality tools, parallel testing, database caching |
| **Pleasy** | Git database backup, maintenance mode, SSH key management |
| **Open Social** | Behat testing (30 features, 134 scenarios), testos.sh patterns |
| **Industry** | 3-2-1 backup rule, 80% coverage threshold, GitLab CI patterns |

---

*For pending and future work, see [Roadmap](../governance/roadmap.md)*
