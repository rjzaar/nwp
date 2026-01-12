# NWP Comprehensive Testing Documentation & Proposal

**Last Updated:** January 9, 2026
**Status:** PROPOSAL
**Priority:** HIGH

This document provides complete documentation of NWP's current testing infrastructure and proposes comprehensive automated testing using Linode infrastructure.

---

## Table of Contents

1. [Current Testing Infrastructure](#current-testing-infrastructure)
2. [Test-NWP Test Catalog](#test-nwp-test-catalog)
3. [NWP Feature Inventory](#nwp-feature-inventory)
4. [TUI Testing Requirements](#tui-testing-requirements)
5. [Testing Gaps Analysis](#testing-gaps-analysis)
6. [Proposed Linode Testing Infrastructure](#proposed-linode-testing-infrastructure)
7. [Implementation Plan](#implementation-plan)
8. [Success Criteria](#success-criteria)

---

## Current Testing Infrastructure

### Overview

| Metric | Value |
|--------|-------|
| Test Script | `scripts/commands/test-nwp.sh` |
| Test Categories | 23+ |
| Individual Assertions | 200+ |
| Scripts Validated | 14 core + 9 libraries |
| Estimated Runtime | 15-30 minutes (local) |
| Success Threshold | 98% |

### Test Framework Architecture

```
test-nwp.sh
├── Test Runner (run_test function)
├── Site Verification Helpers
│   ├── site_exists()
│   ├── site_is_running()
│   ├── drush_works()
│   └── backup_exists()
├── Logging (.logs/test-nwp-TIMESTAMP.log)
└── Results Summary (pass/fail/warn counts)
```

### Test Results Classification

| Status | Meaning | Exit Impact |
|--------|---------|-------------|
| **PASS** | Test succeeded as expected | None |
| **WARN** | Expected failure or conditional skip | Counted toward success |
| **FAIL** | Unexpected failure | Exit code 1 |

**Success Rate Formula:** `(PASSED + WARNING) / TOTAL * 100%`

---

## Test-NWP Test Catalog

### Test 1: Site Installation

**Purpose:** Validates core site installation functionality

| Check | Description | Pass Criteria |
|-------|-------------|---------------|
| Install command | Execute `./install.sh` with test recipe | Exit code 0 |
| Site directory | Verify `sites/test-nwp/` created | Directory exists |
| DDEV config | Verify `.ddev/config.yaml` present | File exists |
| DDEV running | Verify container is started | `ddev describe` succeeds |
| Drush functional | Execute `ddev drush status` | Returns Drupal info |

**Dependencies:** None (first test)
**Failure Impact:** Critical - all subsequent tests depend on this

---

### Test 1b: Environment Variable Generation

**Purpose:** Validates Vortex-compatible environment configuration

| Check | Description | Pass Criteria |
|-------|-------------|---------------|
| `.env` creation | Environment file generated | File exists |
| `.env.local.example` | Local example created | File exists |
| `.secrets.example.yml` | Secrets template created | File exists |
| PROJECT_NAME | Set in `.env` | Variable defined |
| NWP_RECIPE | Recipe identifier set | Variable defined |
| DRUPAL_PROFILE | Installation profile set | Variable defined |
| DRUPAL_WEBROOT | Webroot path (web/html) | Variable defined |
| REDIS_ENABLED | For social profile | =1 when applicable |
| SOLR_ENABLED | For social profile | =1 when applicable |
| DDEV web_environment | Config includes vars | Array populated |

---

### Test 2: Backup Functionality

**Purpose:** Validates full site backup creation

| Check | Description | Pass Criteria |
|-------|-------------|---------------|
| Backup command | Execute `./backup.sh test-nwp` | Exit code 0 |
| Backup directory | `sitebackups/test-nwp/` created | Directory exists |
| Backup content | Tarball created | Files present |

**Backup Naming:** `YYYYMMDDTHHmmss-branch-commit-message.tar.gz`

---

### Test 3: Restore Functionality

**Purpose:** Validates site restoration from backup

| Check | Description | Pass Criteria |
|-------|-------------|---------------|
| Modify site | Change site name via Drush | Setting changed |
| Full restore | Restore from backup | Exit code 0 |
| Verify restoration | Site name restored | Original value |

---

### Test 3b: Database-Only Backup/Restore

**Purpose:** Validates `-b` flag for database-only operations

| Check | Description | Pass Criteria |
|-------|-------------|---------------|
| DB backup | `./backup.sh -b test-nwp` | Creates .sql file |
| DB restore | `./restore.sh -bfy ...` | Exit code 0 |
| Verify data | Site name matches | Original value |

---

### Test 4: Copy Functionality

**Purpose:** Validates site cloning

| Check | Description | Pass Criteria |
|-------|-------------|---------------|
| Full copy | `./copy.sh -y test-nwp test-nwp_copy` | Exit code 0 |
| Copy exists | Directory created | Site present |
| Copy running | DDEV started | Container up |
| Drush works | Execute Drush on copy | Returns status |
| Files-only | `./copy.sh -f` (expected warn) | Warn status |

---

### Test 5: Dev/Prod Mode Switching

**Purpose:** Validates environment mode toggling

| Check | Description | Pass Criteria |
|-------|-------------|---------------|
| Enable dev mode | `./make.sh -vy test-nwp` | Exit code 0 |
| Devel enabled | Check module status | Module active |
| Enable prod mode | `./make.sh -py test-nwp` | Exit code 0 |
| Devel disabled | Check module status | Module inactive |

**Known Issue:** OpenSocial profile may have outdated Drush

---

### Test 6: Deployment (dev2stg)

**Purpose:** Validates local staging deployment

| Check | Description | Pass Criteria |
|-------|-------------|---------------|
| Deploy command | `./dev2stg.sh test-nwp` | Exit/warn |
| Staging exists | `test-nwp-stg` created | Directory exists |
| Staging running | DDEV started | Container up |
| Config imported | Drush config:import | Success |

**Note:** Expected to warn if staging doesn't pre-exist

---

### Test 7: Testing Infrastructure

**Purpose:** Validates testing tools

| Check | Description | Pass Criteria |
|-------|-------------|---------------|
| testos.sh exists | Script present | File exists |
| testos.sh executable | Permissions set | +x flag |
| PHPStan runs | Static analysis | Exit/warn |
| PHPCS runs | Code style check | Exit/warn |

---

### Test 8: Site Verification

**Purpose:** Validates all created test sites

| Sites Checked | Verification |
|---------------|--------------|
| test-nwp | Running + Drush |
| test-nwp_copy | Running + Drush |
| test-nwp_files | Running + Drush |
| test-nwp-stg | Running + Drush |

---

### Test 8b: Delete Functionality

**Purpose:** Validates site deletion with options

| Check | Description | Pass Criteria |
|-------|-------------|---------------|
| Create temp site | Install for deletion | Site created |
| Delete with backup | `-by` flags | Site removed + backup exists |
| Create second site | For preservation test | Site created |
| Delete keep backups | `-bky` flags | Site removed + backups preserved |

---

### Test 9: Script Validation

**Purpose:** Validates all core scripts exist with help

| Script | Required Elements |
|--------|-------------------|
| install.sh | Executable + --help |
| backup.sh | Executable + --help |
| restore.sh | Executable + --help |
| copy.sh | Executable + --help |
| make.sh | Executable + --help |
| dev2stg.sh | Executable + --help |
| stg2prod.sh | Executable + --help |
| prod2stg.sh | Executable + --help |
| delete.sh | Executable + --help |

---

### Test 10: Deployment Scripts Validation

**Purpose:** Validates deployment script error handling

| Check | Description | Pass Criteria |
|-------|-------------|---------------|
| stg2prod no args | Rejects missing sitename | Error message |
| stg2prod dry-run | `--dry-run` works | Exit code 0 |
| prod2stg no args | Rejects missing sitename | Error message |
| prod2stg dry-run | `--dry-run` works | Exit code 0 |

---

### Test 11: YAML Library Functions

**Purpose:** Validates YAML manipulation

| Check | Description | Pass Criteria |
|-------|-------------|---------------|
| Library exists | `lib/yaml-write.sh` present | File exists |
| Test script | `tests/test-yaml-write.sh` | Pass if exists |
| Integration tests | `tests/test-integration.sh` | Pass if exists |
| Site registered | Test site in cnwp.yml | Entry present |

---

### Test 12: Linode Production Testing

**Purpose:** Validates production server provisioning (conditional)

**Prerequisites:**
- `lib/linode.sh` exists
- Linode API token in `.secrets.yml`
- SSH key at `~/.ssh/nwp`

| Check | Description | Pass Criteria |
|-------|-------------|---------------|
| Provision instance | Create test Linode | Instance running |
| Add to config | Register in cnwp.yml | Entry present |
| SSH connection | Connect to instance | SSH succeeds |
| Server setup | apt-get update | Command succeeds |
| Scripts exist | stg2prod.sh, prod2stg.sh | Files present |
| Cleanup | Delete instance | Instance removed |

---

### Test 13: Input Validation & Error Handling

**Purpose:** Negative tests for security

| Category | Test Cases |
|----------|------------|
| Path Traversal | Reject `../`, `./`, absolute paths |
| Special Characters | Reject `;`, `&`, spaces |
| Missing Arguments | Reject empty sitename |
| Non-existent Sites | Fail gracefully |
| Mode Validation | make.sh requires `-v` or `-p` |

**Note:** These are "negative tests" - failures are expected/correct behavior

---

### Test 14: Git Backup Features (P11-P13)

**Purpose:** Validates git-based backup functionality

| Check | Description |
|-------|-------------|
| Library exists | `lib/git.sh` present |
| `-g` flag | backup.sh supports git backup |
| `--bundle` flag | Full bundle support |
| `--incremental` flag | Incremental bundle support |
| `--push-all` flag | Push to all remotes |
| git_init() | Function available |
| git_commit_backup() | Function available |
| git_bundle_full() | Function available |
| git_bundle_incremental() | Function available |
| git_push_all() | Function available |
| gitlab_api_create_project() | Function available |
| gitlab_api_list_projects() | Function available |

---

### Test 15: Scheduling Features (P14)

**Purpose:** Validates backup scheduling

| Check | Description | Pass Criteria |
|-------|-------------|---------------|
| Script exists | `schedule.sh` present | File exists |
| Help available | `--help` works | Output shown |
| install command | Subcommand available | Recognized |
| remove command | Subcommand available | Recognized |
| list command | Lists schedules | Output shown |
| show command | Shows details | Output shown |

---

### Test 16: CI/CD & Testing Templates (P16-P21)

**Purpose:** Validates testing infrastructure and CI/CD

| Check | Description |
|-------|-------------|
| Docker compose template | Template exists |
| test.sh exists | Script present and executable |
| test.sh `-l` flag | Lint support |
| test.sh `-u` flag | Unit test support |
| test.sh `-s` flag | Smoke test support |
| test.sh `-b` flag | Behat support |
| Behat template | Template exists |
| Behat features | smoke, auth, content features |
| PHPCS config | phpcs.xml.dist exists |
| PHPStan config | phpstan.neon.dist exists |
| Rector config | rector.php exists |
| GrumPHP config | grumphp.yml.dist exists |
| GitLab CI template | .gitlab-ci.yml exists |
| CI stages | build, validate, test, deploy |
| Coverage reporting | CI has coverage config |
| Badges library | lib/badges.sh exists |
| generate_badge_url() | Function available |
| update_readme_badges() | Function available |

---

### Test 17: Unified CLI Wrapper (P22)

**Purpose:** Validates `pl` CLI command

| Check | Description | Pass Criteria |
|-------|-------------|---------------|
| pl exists | Command present | File exists |
| pl executable | Permissions set | +x flag |
| pl-completion.bash | Completion script exists | File exists |
| pl --help | Help works | Output shown |
| pl install | Subcommand available | Recognized |
| pl backup | Subcommand available | Recognized |
| pl restore | Subcommand available | Recognized |
| pl copy | Subcommand available | Recognized |
| pl test | Subcommand available | Recognized |
| pl delete | Subcommand available | Recognized |
| Completion syntax | bash -n passes | Valid bash |

---

### Test 18: Database Sanitization (P23)

**Purpose:** Validates database sanitization for GDPR compliance

| Check | Description |
|-------|-------------|
| Library exists | `lib/sanitize.sh` present |
| sanitize_database() | Function available |
| sanitize_sql_file() | Function available |
| sanitize_with_drush() | Function available |
| `--sanitize` flag | backup.sh supports flag |
| `--sanitize-level` flag | Level option available |

---

### Test 19: Rollback Capability (P24)

**Purpose:** Validates deployment rollback

| Check | Description |
|-------|-------------|
| Library exists | `lib/rollback.sh` present |
| rollback_init() | Function available |
| rollback_record() | Function available |
| rollback_execute() | Function available |
| rollback_verify() | Function available |
| rollback_list() | Function available + works |
| rollback_quick() | Function available |

---

### Test 20: Remote Site Support (P25)

**Purpose:** Validates remote site management

| Check | Description |
|-------|-------------|
| Library exists | `lib/remote.sh` present |
| parse_remote_target() | Function available |
| get_remote_config() | Function available |
| remote_exec() | Function available |
| remote_drush() | Function available |
| remote_backup() | Function available |
| remote_test() | Function available |

---

### Test 21: Live Server & Security Scripts (P26-P28)

**Purpose:** Validates live server provisioning and security

| Check | Description |
|-------|-------------|
| live.sh exists | Script present |
| live.sh executable | Permissions set |
| live.sh --help | Help available |
| `--type` flag | dedicated/shared/temporary |
| `--delete` flag | Deletion support |
| `--status` flag | Status checking |
| security.sh exists | Script present |
| security.sh executable | Permissions set |
| security.sh --help | Help available |
| check command | Security checking |
| update command | Security updates |
| audit command | Security audit |
| `--all` flag | All sites |
| `--auto` flag | Auto-apply |

---

### Test 22: Script Syntax Validation

**Purpose:** Validates bash syntax of all scripts

**Core Scripts Validated:**
- install.sh, backup.sh, restore.sh, copy.sh
- make.sh, dev2stg.sh, stg2prod.sh, prod2stg.sh
- delete.sh, schedule.sh, live.sh, security.sh
- test.sh, pl

**Libraries Validated:**
- lib/ui.sh, lib/common.sh, lib/terminal.sh
- lib/yaml-write.sh, lib/git.sh, lib/linode.sh
- lib/sanitize.sh, lib/rollback.sh, lib/remote.sh

**Method:** `bash -n <file>` syntax check

---

### Test 22b: Library Loading and Function Tests

**Purpose:** Validates library sourcing and utility functions

| Library | Tests |
|---------|-------|
| lib/terminal.sh | Can be sourced |
| lib/ui.sh | Can be sourced |
| lib/common.sh | Can be sourced |

**Function Tests:**

| Function | Test Case | Expected |
|----------|-----------|----------|
| get_base_name | mysite-stg | mysite |
| get_base_name | mysite_prod | mysite |
| get_env_label | prod | PRODUCTION |
| get_env_label | stg | STAGING |
| get_env_display_label | prod | Production |
| get_env_display_label | live | Live |
| UI functions | print_error, print_warning, print_info | Execute without error |
| Terminal functions | cursor_to, cursor_hide, cursor_show | Execute without error |

---

### Test 22c: New Command Help Tests

**Purpose:** Validates new pl subcommands

| Command | Test |
|---------|------|
| pl badges --help | Help output |
| pl storage --help | Help output |
| pl rollback --help | Help output |
| pl email --help | Help output |

---

### Test 23: Podcast Infrastructure (Optional)

**Purpose:** Validates Castopod podcast features

**Activation:** Requires `--podcast` flag

| Check | Description |
|-------|-------------|
| Test script exists | `tests/test-podcast.sh` |
| Test suite runs | All podcast tests pass |

---

## NWP Feature Inventory

### Command Scripts (38 Total)

#### Site Management (4)

| Command | Description | Tested |
|---------|-------------|--------|
| `pl install` | Install new sites | Yes |
| `pl delete` | Remove sites | Yes |
| `pl make` | Dev/prod mode | Yes |
| `uninstall_nwp.sh` | Remove NWP | No |

#### Backup & Restore (3)

| Command | Description | Tested |
|---------|-------------|--------|
| `pl backup` | Create backups | Yes |
| `pl restore` | Restore from backup | Yes |
| `pl copy` | Clone sites | Yes |

#### Local Deployment (1)

| Command | Description | Tested |
|---------|-------------|--------|
| `pl dev2stg` | Deploy to staging | Yes |

#### Remote Deployment (5)

| Command | Description | Tested |
|---------|-------------|--------|
| `pl stg2prod` | Staging to production | Partial |
| `pl prod2stg` | Production to staging | Partial |
| `pl stg2live` | Staging to live | No |
| `pl live2stg` | Live to staging | No |
| `pl live2prod` | Live to production | No |

#### Testing (4)

| Command | Description | Tested |
|---------|-------------|--------|
| `pl test` | Run tests | Yes |
| `testos.sh` | OpenSocial tests | Partial |
| `test-nwp.sh` | Infrastructure tests | Yes |
| `theme.sh` | Frontend builds | No |

#### Scheduling (1)

| Command | Description | Tested |
|---------|-------------|--------|
| `pl schedule` | Backup scheduling | Yes |

#### Security (1)

| Command | Description | Tested |
|---------|-------------|--------|
| `pl security` | Security management | Yes |

#### Import & Sync (3)

| Command | Description | Tested |
|---------|-------------|--------|
| `pl import` | Import remote sites | No |
| `pl sync` | Resync imported sites | No |
| `pl modify` | Modify site options | No |

#### Migration (1)

| Command | Description | Tested |
|---------|-------------|--------|
| `pl migration` | Migrate from legacy | No |

#### Provisioning (2)

| Command | Description | Tested |
|---------|-------------|--------|
| `pl live` | Live server provisioning | Yes |
| `produce.sh` | Production provisioning | No |

#### Podcast (1)

| Command | Description | Tested |
|---------|-------------|--------|
| `pl podcast` | Castopod setup | Optional |

#### Email (1)

| Command | Description | Tested |
|---------|-------------|--------|
| `pl email` | Email management | Partial |

#### Storage (1)

| Command | Description | Tested |
|---------|-------------|--------|
| `pl storage` | B2 cloud storage | Partial |

#### Rollback (1)

| Command | Description | Tested |
|---------|-------------|--------|
| `pl rollback` | Deployment rollback | Yes |

#### CI/CD (1)

| Command | Description | Tested |
|---------|-------------|--------|
| `pl badges` | Badge management | Partial |

#### Developer Tools (3)

| Command | Description | Tested |
|---------|-------------|--------|
| `coder-setup.sh` | Multi-coder setup | No |
| `coders.sh` | Coder management TUI | No |
| `pl verify` | Feature verification | No |

#### Setup & Configuration (2)

| Command | Description | Tested |
|---------|-------------|--------|
| `pl setup` | Interactive setup | No |
| `setup-ssh.sh` | SSH key setup | No |

#### Status & Reporting (2)

| Command | Description | Tested |
|---------|-------------|--------|
| `pl status` | Site status | No |
| `report.sh` | Error reporting | No |

---

### Library Functions (36 Libraries, 150+ Functions)

| Library | Functions | Tested |
|---------|-----------|--------|
| common.sh | 50+ | Partial |
| linode.sh | 30+ | Partial |
| git.sh | 15+ | Yes |
| yaml-write.sh | 10+ | Yes |
| sanitize.sh | 5+ | Yes |
| rollback.sh | 6+ | Yes |
| remote.sh | 6+ | Yes |
| ui.sh | 15+ | Yes |
| terminal.sh | 10+ | Yes |
| b2.sh | 10+ | No |
| cloudflare.sh | 10+ | No |
| frontend.sh | 5+ | No |
| tui.sh | 10+ | No |
| checkbox.sh | 15+ | No |
| developer.sh | 8+ | No |
| safe-ops.sh | 5+ | No |

---

## TUI Testing Requirements

### 1. setup.sh TUI

**Components to Test:**

| Component | Test Type | Current Status |
|-----------|-----------|----------------|
| Arrow navigation | Interactive | Not tested |
| Space toggle | Interactive | Not tested |
| Page switching | Interactive | Not tested |
| Dependency auto-select | Unit | Not tested |
| Component installation | Integration | Not tested |
| Edit mode | Interactive | Not tested |
| All/None selection | Interactive | Not tested |

**Keyboard Shortcuts:**
- `↑/↓/←/→` and `hjkl` navigation
- `Space` toggle
- `a/A` select all, `n/N` select none
- `d/D` describe, `e/E` edit
- `Enter` apply, `q/Q/ESC` quit

---

### 2. coders.sh TUI

**Components to Test:**

| Component | Test Type | Current Status |
|-----------|-----------|----------------|
| Coder list rendering | Unit | Not tested |
| Arrow navigation | Interactive | Not tested |
| Space selection | Interactive | Fixed (was crashing) |
| Bulk selection | Interactive | Not tested |
| Details view | Interactive | Not tested |
| Promote workflow | Integration | Not tested |
| Delete workflow | Integration | Not tested |
| GitLab sync | Integration | Not tested |

**Keyboard Shortcuts:**
- `↑/↓` navigation, `PgUp/PgDn` scroll
- `Space` select, `Enter` details
- `M` modify, `P` promote, `D` delete
- `A` add, `S` sync, `V` verify
- `R` reload, `Q` quit

---

### 3. checkbox.sh Library

**Components to Test:**

| Component | Test Type | Current Status |
|-----------|-----------|----------------|
| Option rendering | Unit | Not tested |
| Toggle behavior | Interactive | Not tested |
| Dependency checking | Unit | Not tested |
| Conflict detection | Unit | Not tested |
| Environment defaults | Unit | Not tested |
| Input collection | Interactive | Not tested |

---

### 4. dev2stg.sh TUI

**Components to Test:**

| Component | Test Type | Current Status |
|-----------|-----------|----------------|
| Database source menu | Interactive | Not tested |
| Test type selection | Interactive | Not tested |
| Preset selection | Interactive | Not tested |
| Progress display | Interactive | Not tested |

---

### 5. import.sh TUI

**Components to Test:**

| Component | Test Type | Current Status |
|-----------|-----------|----------------|
| Server discovery | Integration | Not tested |
| Site selection | Interactive | Not tested |
| Import progress | Interactive | Not tested |

---

## Testing Gaps Analysis

### Critical Gaps (High Priority)

| Feature | Gap Description | Risk |
|---------|-----------------|------|
| Remote deployment | stg2live, live2stg, live2prod untested | Production failures |
| Import/sync | No automated tests | Data loss risk |
| Migration | No tests for legacy migration | Failed migrations |
| TUI components | No automated testing | UX regressions |
| Cloudflare API | No integration tests | DNS failures |
| B2 storage | No integration tests | Backup failures |

### Moderate Gaps (Medium Priority)

| Feature | Gap Description | Risk |
|---------|-----------------|------|
| theme.sh | No frontend build tests | Theme breakage |
| setup.sh | No component install tests | Setup failures |
| coder-setup.sh | No provisioning tests | Onboarding failures |
| Email | No delivery tests | Communication failures |

### Minor Gaps (Low Priority)

| Feature | Gap Description | Risk |
|---------|-----------------|------|
| verify.sh | No tracking tests | Documentation gaps |
| status.sh | No output validation | Confusing output |
| report.sh | No error capture tests | Missing diagnostics |

---

## Proposed Linode Testing Infrastructure

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    NWP AUTOMATED TESTING INFRASTRUCTURE                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐        │
│  │  TEST RUNNER    │    │  LINODE POOL    │    │  RESULTS DB     │        │
│  │  (GitLab CI)    │───▶│  (3-5 nodes)    │───▶│  (PostgreSQL)   │        │
│  └─────────────────┘    └─────────────────┘    └─────────────────┘        │
│           │                      │                      │                  │
│           ▼                      ▼                      ▼                  │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐        │
│  │  TEST SUITES    │    │  ENVIRONMENTS   │    │  DASHBOARDS     │        │
│  │  - Unit         │    │  - Fresh Ubuntu │    │  - Pass rates   │        │
│  │  - Integration  │    │  - With sites   │    │  - Trends       │        │
│  │  - E2E          │    │  - Production   │    │  - Coverage     │        │
│  │  - TUI          │    │  - Multi-coder  │    │  - Alerts       │        │
│  └─────────────────┘    └─────────────────┘    └─────────────────┘        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Linode Test Environment Types

#### Type 1: Fresh Install Testing

**Purpose:** Test NWP installation on clean servers

```yaml
fresh-install-test:
  name: "nwp-test-fresh-${CI_JOB_ID}"
  type: g6-nanode-1  # $5/month
  image: linode/ubuntu22.04
  region: us-east
  lifetime: 2 hours (auto-delete)

  tests:
    - NWP clone and setup.sh
    - DDEV installation
    - Docker configuration
    - First site creation
    - Basic operations
```

#### Type 2: Pre-configured Testing

**Purpose:** Test operations on existing sites

```yaml
preconfigured-test:
  name: "nwp-test-preconfig-${CI_JOB_ID}"
  type: g6-standard-1  # $10/month
  image: nwp-test-image-v1  # Pre-built image
  region: us-east
  lifetime: 4 hours (auto-delete)

  preinstalled:
    - NWP with all components
    - 3 test sites (d, os, nwp recipes)
    - GitLab runner
    - Full testing tools

  tests:
    - All test-nwp.sh tests
    - Backup/restore workflows
    - Deployment pipelines
    - Performance benchmarks
```

#### Type 3: Production Simulation

**Purpose:** Test production deployment scenarios

```yaml
production-test:
  nodes:
    staging:
      name: "nwp-test-stg-${CI_JOB_ID}"
      type: g6-standard-2  # $20/month
      region: us-east

    production:
      name: "nwp-test-prod-${CI_JOB_ID}"
      type: g6-standard-2
      region: us-west

  lifetime: 6 hours (auto-delete)

  tests:
    - stg2prod deployment
    - prod2stg sync
    - stg2live deployment
    - Rollback scenarios
    - Multi-region sync
```

#### Type 4: Multi-Coder Testing

**Purpose:** Test multi-developer scenarios

```yaml
multi-coder-test:
  nodes:
    primary:
      name: "nwp-test-primary-${CI_JOB_ID}"
      type: g6-standard-2
      services: [gitlab, nwp]

    coder1:
      name: "nwp-test-coder1-${CI_JOB_ID}"
      type: g6-nanode-1
      subdomain: coder1.test.nwpcode.org

    coder2:
      name: "nwp-test-coder2-${CI_JOB_ID}"
      type: g6-nanode-1
      subdomain: coder2.test.nwpcode.org

  lifetime: 4 hours (auto-delete)

  tests:
    - coder-setup.sh add
    - NS delegation
    - GitLab user creation
    - Cross-coder collaboration
    - Promotion workflow
    - Offboarding cleanup
```

---

### Test Suite Definitions

#### Suite 1: Unit Tests (Local, No Linode)

```bash
# Run time: ~2 minutes
# Trigger: Every commit

tests/unit/
├── test-yaml-write.sh      # YAML manipulation
├── test-common.sh          # Utility functions
├── test-sanitize.sh        # Sanitization logic
├── test-rollback.sh        # Rollback functions
├── test-validation.sh      # Input validation
└── test-env-generate.sh    # Environment generation
```

#### Suite 2: Integration Tests (Local DDEV)

```bash
# Run time: ~15 minutes
# Trigger: PR merge to main

tests/integration/
├── test-install.sh         # Site installation
├── test-backup-restore.sh  # Backup/restore cycle
├── test-copy.sh            # Site cloning
├── test-dev-prod.sh        # Mode switching
├── test-dev2stg.sh         # Local deployment
└── test-delete.sh          # Site deletion
```

#### Suite 3: E2E Tests (Linode Required)

```bash
# Run time: ~45 minutes
# Trigger: Nightly, release branches

tests/e2e/
├── test-fresh-install.sh   # Clean server setup
├── test-production.sh      # Production deployment
├── test-multi-region.sh    # Cross-region sync
├── test-multi-coder.sh     # Multi-developer setup
├── test-disaster-recovery.sh # Backup/restore E2E
└── test-security.sh        # Security hardening
```

#### Suite 4: TUI Tests (Expect/BATS)

```bash
# Run time: ~10 minutes
# Trigger: PR affecting TUI files

tests/tui/
├── test-setup-tui.exp      # setup.sh navigation
├── test-coders-tui.exp     # coders.sh operations
├── test-checkbox.exp       # checkbox.sh selection
├── test-import-tui.exp     # import.sh discovery
└── test-dev2stg-tui.exp    # dev2stg.sh menus
```

---

### TUI Testing with Expect

**Purpose:** Automated testing of interactive interfaces

```tcl
#!/usr/bin/expect -f
# test-coders-tui.exp

set timeout 30

# Start coders TUI
spawn ./scripts/commands/coders.sh

# Wait for initial display
expect "NWP CODER MANAGEMENT"

# Test arrow navigation
send "\033\[B"  ;# Down arrow
expect ">"      ;# Selection moved

# Test space selection
send " "        ;# Space
expect "\[x\]"  ;# Checkbox marked

# Test details view
send "\r"       ;# Enter
expect "CODER DETAILS"

# Return to list
send "q"
expect "NWP CODER MANAGEMENT"

# Exit
send "q"
expect eof

puts "TUI test passed"
```

---

### GitLab CI Pipeline

```yaml
# .gitlab-ci.yml additions for comprehensive testing

stages:
  - lint
  - unit
  - integration
  - e2e
  - tui
  - cleanup

variables:
  LINODE_TEST_REGION: "us-east"
  LINODE_TEST_TYPE: "g6-nanode-1"
  TEST_TIMEOUT: "7200"  # 2 hours

# Stage 1: Linting (every commit)
lint:
  stage: lint
  script:
    - ./scripts/commands/test.sh -l
  rules:
    - if: $CI_PIPELINE_SOURCE == "push"

# Stage 2: Unit tests (every commit)
unit:
  stage: unit
  script:
    - bats tests/unit/
  rules:
    - if: $CI_PIPELINE_SOURCE == "push"

# Stage 3: Integration tests (main branch)
integration:
  stage: integration
  script:
    - ./scripts/commands/test-nwp.sh --skip-cleanup
  artifacts:
    paths:
      - .logs/
    expire_in: 1 week
  rules:
    - if: $CI_COMMIT_BRANCH == "main"

# Stage 4: E2E tests (nightly)
e2e:fresh-install:
  stage: e2e
  script:
    - ./tests/e2e/provision-and-test.sh fresh
  timeout: 2h
  rules:
    - if: $CI_PIPELINE_SOURCE == "schedule"
  after_script:
    - ./tests/e2e/cleanup.sh

e2e:production:
  stage: e2e
  script:
    - ./tests/e2e/provision-and-test.sh production
  timeout: 3h
  rules:
    - if: $CI_PIPELINE_SOURCE == "schedule"
  after_script:
    - ./tests/e2e/cleanup.sh

e2e:multi-coder:
  stage: e2e
  script:
    - ./tests/e2e/provision-and-test.sh multi-coder
  timeout: 2h
  rules:
    - if: $CI_PIPELINE_SOURCE == "schedule"
  after_script:
    - ./tests/e2e/cleanup.sh

# Stage 5: TUI tests (when TUI files change)
tui:
  stage: tui
  script:
    - apt-get update && apt-get install -y expect
    - ./tests/tui/run-all.sh
  rules:
    - if: $CI_COMMIT_BRANCH == "main"
      changes:
        - scripts/commands/setup.sh
        - scripts/commands/coders.sh
        - lib/checkbox.sh
        - lib/tui.sh

# Cleanup: Ensure test resources deleted
cleanup:
  stage: cleanup
  script:
    - ./tests/e2e/cleanup.sh --force
  when: always
  rules:
    - if: $CI_PIPELINE_SOURCE == "schedule"
```

---

### Cost Management

#### Estimated Monthly Costs

| Test Type | Frequency | Instance | Duration | Monthly Cost |
|-----------|-----------|----------|----------|--------------|
| Fresh Install | Nightly | Nanode ($5) | 2h | $5 |
| Pre-configured | Nightly | Standard-1 ($10) | 4h | $7 |
| Production | Weekly | 2x Standard-2 ($40) | 6h | $12 |
| Multi-coder | Weekly | 1x Std-2 + 2x Nanode | 4h | $8 |
| **Total** | | | | **~$32/month** |

#### Cost Controls

```bash
# Auto-delete instances older than max lifetime
linode_cleanup_old_test_instances() {
    local max_age_hours=8

    # Find instances with "nwp-test" prefix older than max age
    linode-cli linodes list --json | jq -r \
        ".[] | select(.label | startswith(\"nwp-test\")) |
         select(.created | fromdateiso8601 < (now - ${max_age_hours}*3600)) |
         .id" | while read id; do
        echo "Deleting stale test instance: $id"
        linode-cli linodes delete "$id"
    done
}
```

---

### Test Results Storage

```sql
-- PostgreSQL schema for test results

CREATE TABLE test_runs (
    id SERIAL PRIMARY KEY,
    run_id VARCHAR(64) UNIQUE,
    pipeline_id INTEGER,
    branch VARCHAR(128),
    commit_sha VARCHAR(40),
    started_at TIMESTAMP,
    completed_at TIMESTAMP,
    status VARCHAR(20),  -- running, passed, failed, cancelled
    total_tests INTEGER,
    passed INTEGER,
    failed INTEGER,
    warnings INTEGER,
    success_rate DECIMAL(5,2)
);

CREATE TABLE test_results (
    id SERIAL PRIMARY KEY,
    run_id VARCHAR(64) REFERENCES test_runs(run_id),
    test_name VARCHAR(256),
    category VARCHAR(64),
    status VARCHAR(20),  -- pass, fail, warn, skip
    duration_ms INTEGER,
    error_message TEXT,
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE test_artifacts (
    id SERIAL PRIMARY KEY,
    run_id VARCHAR(64) REFERENCES test_runs(run_id),
    artifact_type VARCHAR(64),  -- log, screenshot, coverage
    file_path VARCHAR(512),
    size_bytes BIGINT,
    created_at TIMESTAMP DEFAULT NOW()
);

-- Indexes for common queries
CREATE INDEX idx_test_runs_branch ON test_runs(branch);
CREATE INDEX idx_test_runs_status ON test_runs(status);
CREATE INDEX idx_test_results_status ON test_results(status);
CREATE INDEX idx_test_results_category ON test_results(category);
```

---

### Dashboard & Alerting

```yaml
# Grafana dashboard configuration

dashboards:
  nwp-testing:
    panels:
      - title: "Test Success Rate (7 days)"
        type: graph
        query: |
          SELECT date_trunc('day', completed_at), AVG(success_rate)
          FROM test_runs
          WHERE completed_at > NOW() - INTERVAL '7 days'
          GROUP BY 1 ORDER BY 1

      - title: "Failed Tests by Category"
        type: pie
        query: |
          SELECT category, COUNT(*)
          FROM test_results
          WHERE status = 'fail'
          AND created_at > NOW() - INTERVAL '24 hours'
          GROUP BY category

      - title: "Test Duration Trend"
        type: graph
        query: |
          SELECT date_trunc('hour', completed_at),
                 AVG(EXTRACT(EPOCH FROM (completed_at - started_at)))
          FROM test_runs
          WHERE completed_at > NOW() - INTERVAL '7 days'
          GROUP BY 1 ORDER BY 1

alerts:
  - name: "Test Failure Alert"
    condition: "success_rate < 95"
    channels: [slack, email]
    message: "NWP test success rate dropped below 95%"

  - name: "E2E Test Timeout"
    condition: "duration > 3600 AND status = 'running'"
    channels: [slack]
    message: "E2E test running longer than 1 hour"
```

---

## Implementation Plan

### Phase 1: Foundation (Week 1-2)

- [ ] Create `tests/` directory structure
- [ ] Write unit tests for core libraries
- [ ] Set up BATS testing framework
- [ ] Create test helper functions
- [ ] Document test writing guidelines

**Deliverables:**
- `tests/unit/` with 20+ unit tests
- `tests/helpers/` with test utilities
- `docs/WRITING_TESTS.md`

### Phase 2: Integration Tests (Week 3-4)

- [ ] Convert test-nwp.sh to modular tests
- [ ] Add missing integration tests
- [ ] Implement test fixtures
- [ ] Create CI job for integration tests

**Deliverables:**
- `tests/integration/` with full coverage
- Updated `.gitlab-ci.yml`
- Test fixtures and data

### Phase 3: Linode Infrastructure (Week 5-6)

- [ ] Create Linode test provisioning scripts
- [ ] Build pre-configured test images
- [ ] Implement auto-cleanup
- [ ] Set up cost monitoring

**Deliverables:**
- `tests/e2e/provision-and-test.sh`
- `tests/e2e/cleanup.sh`
- Linode image: `nwp-test-image-v1`

### Phase 4: TUI Testing (Week 7-8)

- [ ] Install and configure Expect
- [ ] Write TUI test scripts
- [ ] Implement screenshot capture
- [ ] Add TUI tests to CI

**Deliverables:**
- `tests/tui/` with all TUI tests
- TUI testing documentation
- CI integration

### Phase 5: Monitoring & Alerting (Week 9-10)

- [ ] Set up PostgreSQL for results
- [ ] Create Grafana dashboards
- [ ] Configure alerts
- [ ] Document monitoring

**Deliverables:**
- Results database schema
- Grafana dashboard
- Alert configurations
- Runbook for failures

---

## Success Criteria

### Test Coverage Goals

| Category | Current | Target |
|----------|---------|--------|
| Unit tests | ~20% | 80% |
| Integration tests | ~60% | 95% |
| E2E tests | ~30% | 80% |
| TUI tests | 0% | 70% |
| **Overall** | **~40%** | **85%** |

### Quality Metrics

| Metric | Target |
|--------|--------|
| Test success rate | >98% |
| False positive rate | <2% |
| Test flakiness | <5% |
| E2E test duration | <1 hour |
| Unit test duration | <2 minutes |

### Infrastructure Metrics

| Metric | Target |
|--------|--------|
| Monthly test cost | <$50 |
| Instance cleanup rate | 100% |
| Dashboard uptime | 99.9% |
| Alert response time | <15 minutes |

---

## References

- [Testing](../testing/testing.md) - Current testing documentation
- [CI/CD](../deployment/cicd.md) - CI/CD pipeline setup
- [Roadmap](../governance/roadmap.md) - Project roadmap
- [test-nwp.sh](../../scripts/commands/test-nwp.sh) - Current test script
- [Linode API Documentation](https://www.linode.com/docs/api/)
- [BATS Documentation](https://bats-core.readthedocs.io/)
- [Expect Documentation](https://core.tcl-lang.org/expect/)

---

*Document created: January 9, 2026*
*Status: Ready for review*
