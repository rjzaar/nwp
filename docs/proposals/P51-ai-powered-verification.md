# P51: AI-Powered Deep Verification

**Status:** IN PROGRESS
**Created:** 2026-01-17
**Author:** Claude Opus 4.5 (architectural design), Rob (requirements)
**Priority:** High
**Depends On:** P50 (Unified Verification System)
**Estimated Effort:** 7-9 weeks
**Breaking Changes:** No - additive to existing system

---

> **"Implement P51" means:** Build the AI verification infrastructure phase by phase. See **Section 13: Ongoing Implementation** for the systematic process. Current phase: **Phase 2 - Database Verification** (0% complete).

---

## 1. Executive Summary

### 1.1 The Problem with Current Verification

P50 verification checks if code **runs** but not if it **works correctly**:

| Current Approach | What's Missing |
|-----------------|----------------|
| `bash -n backup.sh` | Does backup actually contain data? |
| `type restore_site` | Does restore preserve user counts? |
| `pl backup --help` exits 0 | Does restored site pass Behat tests? |

**Real verification requires:**
- Backup 10 users → Restore → Verify 10 users exist
- Copy site → Run Behat → All tests pass
- `pl status` shows user count → Query database → Numbers match

### 1.2 The Solution: Integrated Verification Scenarios

Instead of testing **individual items**, test **complete workflows** that verify multiple commands together:

```
┌─────────────────────────────────────────────────────────────────┐
│  SCENARIO: Backup-Restore Integrity                             │
├─────────────────────────────────────────────────────────────────┤
│  1. Install site with test content                              │
│  2. Count users: drush sqlq "SELECT COUNT(*) FROM users"        │
│  3. Count nodes: drush sqlq "SELECT COUNT(*) FROM node"         │
│  4. Run pl status - capture metrics                             │
│  5. Create backup: pl backup site                               │
│  6. Verify backup file exists and has content                   │
│  7. Restore to new site: pl restore site site-restored          │
│  8. Count users on restored site - MUST MATCH                   │
│  9. Count nodes on restored site - MUST MATCH                   │
│  10. Run pl status on restored - metrics MUST MATCH             │
│  11. Run Behat smoke tests - ALL MUST PASS                      │
│  12. Compare file checksums - critical files MUST MATCH         │
├─────────────────────────────────────────────────────────────────┤
│  COMMANDS VERIFIED: install, backup, restore, status, test      │
│  COVERAGE: 47 checklist items from 5 features                   │
└─────────────────────────────────────────────────────────────────┘
```

### 1.3 Key Principles

1. **One scenario, many commands** - Test workflows, not isolated functions
2. **State verification** - Count users/nodes before AND after operations
3. **Deep validation** - Behat tests, drush queries, file checksums
4. **Complete coverage** - 17 scenarios cover all 48 commands
5. **Fix as you go** - AI repairs issues encountered during testing
6. **Progressive execution** - Checkpoint after each scenario

---

## 2. Verification Scenario Design

### 2.1 The 17 Core Scenarios

These 17 scenarios provide complete coverage of all 48 commands with minimal redundancy:

| # | Scenario | Commands Tested | Items Covered |
|---|----------|-----------------|---------------|
| S1 | **Foundation Setup** | setup, doctor | 23 |
| S2 | **Site Lifecycle** | install, status, delete | 31 |
| S3 | **Backup-Restore Integrity** | backup, restore, status | 47 |
| S4 | **Site Copy & Clone** | copy, status, test | 28 |
| S5 | **Local Deployment** | dev2stg, make, test | 35 |
| S6 | **Content Import** | import, sync, status | 22 |
| S7 | **Security Hardening** | security, security-check | 18 |
| S8 | **Quality Assurance Suite** | test, run-tests, verify, testos, seo-check, badges | 38 |
| S9 | **Configuration Management** | modify, status | 19 |
| S10 | **Full Production Pipeline** | stg2live, live2stg, live, live2prod, prod2stg, stg2prod | 56 |
| S11 | **Specialized Installs** | podcast, avc-moodle-setup, avc-moodle-status, avc-moodle-sync, avc-moodle-test | 32 |
| S12 | **Maintenance Operations** | rollback, uninstall_nwp | 14 |
| S13 | **Developer Environment** | bootstrap-coder, coders, coder-setup, contribute | 28 |
| S14 | **Infrastructure & Communication** | setup-ssh, email, storage, schedule | 24 |
| S15 | **Migration Pipeline** | migrate-secrets, migration | 18 |
| S16 | **Content & Theming** | produce, report, theme | 22 |
| S17 | **Upstream & Maintenance** | upstream, todo | 16 |
| | **TOTAL** | **48 commands** | **471 items** |

**Remaining 104 items** are library functions tested implicitly through scenarios.

### 2.1.1 Complete Command Coverage Matrix

All 48 commands mapped to their verification scenarios:

| Command | Scenario | Command | Scenario |
|---------|----------|---------|----------|
| avc-moodle-setup | S11 | migrate-secrets | S15 |
| avc-moodle-status | S11 | migration | S15 |
| avc-moodle-sync | S11 | modify | S9 |
| avc-moodle-test | S11 | podcast | S11 |
| backup | S3 | prod2stg | S10 |
| badges | S8 | produce | S16 |
| bootstrap-coder | S13 | report | S16 |
| coders | S13 | restore | S3 |
| coder-setup | S13 | rollback | S12 |
| contribute | S13 | run-tests | S8 |
| copy | S4 | schedule | S14 |
| delete | S2 | security | S7 |
| dev2stg | S5 | security-check | S7 |
| doctor | S1 | seo-check | S8 |
| email | S14 | setup | S1 |
| import | S6 | setup-ssh | S14 |
| install | S2 | status | S2,S3,S4,S6,S9 |
| live | S10 | stg2live | S10 |
| live2prod | S10 | stg2prod | S10 |
| live2stg | S10 | storage | S14 |
| make | S5 | sync | S6 |
| test | S4,S5,S8 | testos | S8 |
| theme | S16 | todo | S17 |
| uninstall_nwp | S12 | upstream | S17 |
| verify | S8 | | |

### 2.2 Scenario Dependency Graph

```
S1: Foundation Setup
 │
 ├──► S2: Site Lifecycle
 │     │
 │     ├──► S3: Backup-Restore ──► S6: Content Import
 │     │     │
 │     │     └──► S15: Migration Pipeline
 │     │
 │     ├──► S4: Site Copy ──► S5: Local Deployment
 │     │                           │
 │     │                           └──► S10: Full Production Pipeline
 │     │
 │     ├──► S7: Security Hardening
 │     │
 │     ├──► S8: Quality Assurance Suite
 │     │
 │     ├──► S9: Configuration
 │     │
 │     └──► S16: Content & Theming
 │
 ├──► S11: Specialized Installs
 │     │
 │     └──► S12: Maintenance ──► S17: Upstream & Maintenance
 │
 ├──► S13: Developer Environment
 │
 └──► S14: Infrastructure & Communication
```

---

## 3. Detailed Scenario Specifications

### S1: Foundation Setup (Pre-requisite Gate)

This scenario MUST pass before any other scenario runs. It validates the development environment using `pl doctor` with full cross-validation.

```yaml
scenario:
  id: S1
  name: Foundation Setup
  description: Verify development environment meets all requirements
  depends_on: []  # No dependencies - this is the foundation
  estimated_duration: 2 minutes
  is_gate: true  # All other scenarios require S1 to pass

  commands_tested:
    - setup.sh
    - doctor.sh

  live_state_commands:
    - command: pl doctor
      cross_validation_ref: section 4.5
      validates:
        - Docker availability and status
        - DDEV version and running projects
        - PHP version
        - Composer availability
        - Git version
        - Disk space available
        - Memory available

  steps:
    - name: Run pl doctor
      cmd: pl doctor --json
      expect_exit: 0
      store_as: doctor_output

    - name: Cross-validate Docker availability
      live_state:
        command: pl doctor --json | jq '.docker.available'
        verify: docker --version >/dev/null 2>&1 && echo "true" || echo "false"
        tolerance: 0
        on_mismatch: critical

    - name: Cross-validate Docker running
      live_state:
        command: pl doctor --json | jq '.docker.running'
        verify: docker info >/dev/null 2>&1 && echo "true" || echo "false"
        tolerance: 0
        on_mismatch: critical

    - name: Cross-validate DDEV version
      live_state:
        command: pl doctor --json | jq -r '.ddev.version'
        verify: ddev version --json-output | jq -r '.raw'
        tolerance: 0
        on_mismatch: warning

    - name: Cross-validate disk space
      live_state:
        command: pl doctor --json | jq '.disk.available_gb'
        verify: df -BG . | tail -1 | awk '{print $4}' | tr -d 'G'
        tolerance: 1
        minimum: 10  # Require at least 10GB free

    - name: Cross-validate memory
      live_state:
        command: pl doctor --json | jq '.memory.available_mb'
        verify: free -m | awk '/^Mem:/{print $7}'
        tolerance: 100
        minimum: 2048  # Require at least 2GB free

    - name: Run pl setup verification
      cmd: pl setup --check
      expect_exit: 0
      validate:
        - NWP installed correctly:
            expect_contains: "NWP"
        - Configuration valid:
            expect_contains: "valid"

  success_criteria:
    all_required:
      - Docker running
      - DDEV available
      - Sufficient disk space (>10GB)
      - Sufficient memory (>2GB)
      - All cross-validations pass

    gate_behavior: |
      If S1 fails, no other scenarios will run.
      The failure report will indicate which
      cross-validation failed and why.
```

### S2: Site Lifecycle (with status cross-validation)

```yaml
scenario:
  id: S2
  name: Site Lifecycle
  description: Verify site install, status reporting, and deletion
  depends_on: [S1]
  estimated_duration: 5 minutes

  commands_tested:
    - install.sh
    - status.sh
    - delete.sh

  live_state_commands:
    - command: pl status
      cross_validation_ref: section 4.3
      validates:
        - User count accuracy
        - Database size accuracy
        - Health status accuracy

  steps:
    - name: Install test site
      cmd: pl install d verify-s2 --auto
      expect_exit: 0
      timeout: 180

    - name: Cross-validate pl status user count
      live_state:
        command: pl status -s verify-s2 --json | jq '.users'
        verify: cd sites/verify-s2 && ddev drush sqlq "SELECT COUNT(*) FROM users_field_data WHERE uid > 0"
        tolerance: 0

    - name: Cross-validate pl status database size
      live_state:
        command: pl status -s verify-s2 --json | jq '.db_size_mb'
        verify: |
          cd sites/verify-s2 && ddev mysql -N -e "SELECT ROUND(SUM(data_length + index_length) / 1024 / 1024, 0) FROM information_schema.tables WHERE table_schema = DATABASE();"
        tolerance: 1

    - name: Cross-validate pl status health
      live_state:
        command: pl status -s verify-s2 --json | jq -r '.health'
        verify_conditions:
          healthy:
            - ddev describe verify-s2 | grep -q "running"
            - cd sites/verify-s2 && ddev drush status --field=db-status | grep -q "Connected"

    - name: Run security baseline check
      cmd: pl security-check verify-s2 --json
      store_as: security_baseline
      validate:
        - Settings protected:
            live_state:
              command: jq '.permissions.settings_protected' <<< "$security_baseline"
              verify: |
                perm=$(stat -c "%a" sites/verify-s2/html/sites/default/settings.php)
                [[ "$perm" =~ ^4[04][04]$ ]] && echo "true" || echo "false"

    - name: Delete test site
      cmd: pl delete verify-s2 --yes
      expect_exit: 0

  cleanup:
    - cmd: pl delete verify-s2 --yes 2>/dev/null || true
```

### S3: Backup-Restore Integrity (Example in Full Detail)

This scenario demonstrates the depth of verification:

```yaml
scenario:
  id: S3
  name: Backup-Restore Integrity
  description: Verify backup captures all data and restore preserves it exactly
  depends_on: [S2]  # Needs working install
  estimated_duration: 8 minutes

  commands_tested:
    - backup.sh
    - restore.sh
    - status.sh

  live_state_commands:
    - command: pl status
      cross_validation_ref: section 4.3
      validates:
        - User count accuracy (pre/post restore)
        - Database size accuracy
        - Health status accuracy
      usage: |
        Used before backup to establish baseline metrics,
        then after restore to verify data integrity.
        Mismatch indicates data loss during backup/restore cycle.

    - command: pl storage
      cross_validation_ref: section 4.6
      validates:
        - Backup file size
        - Total site size comparison
      usage: |
        Verifies backup file exists and has appropriate size
        relative to source site.

  checklist_items_covered:
    - backup.0: Test backup creation
    - backup.1: Test backup with sanitization
    - backup.2: Test database-only backup
    - backup.3: Verify backup file structure
    - restore.0: Test restore from backup
    - restore.1: Test restore to new site
    - restore.2: Verify restored site runs
    - status.0: Shows correct user count
    - status.1: Shows correct database size
    # ... (47 items total)

  setup:
    - Create test site with known content:
        cmd: pl install d verify-s3 --auto
        timeout: 180
    - Add test users:
        cmd: |
          ddev drush user:create testuser1 --mail="test1@example.com" --password="test123"
          ddev drush user:create testuser2 --mail="test2@example.com" --password="test123"
          ddev drush user:create testuser3 --mail="test3@example.com" --password="test123"
    - Add test content:
        cmd: |
          ddev drush node:create --type=article --title="Test Article 1"
          ddev drush node:create --type=article --title="Test Article 2"

  capture_baseline:
    user_count:
      cmd: ddev drush sqlq "SELECT COUNT(*) FROM users_field_data WHERE uid > 0"
      store_as: baseline_users
      expected: 4  # admin + 3 test users

    node_count:
      cmd: ddev drush sqlq "SELECT COUNT(*) FROM node_field_data"
      store_as: baseline_nodes
      expected: 2

    db_size:
      cmd: ddev mysql -N -e "SELECT ROUND(SUM(data_length + index_length) / 1024 / 1024, 1) FROM information_schema.tables WHERE table_schema = DATABASE();"
      store_as: baseline_db_size

    status_output:
      cmd: pl status -s verify-s3 --json 2>/dev/null
      store_as: baseline_status

    file_checksums:
      cmd: find sites/verify-s3/html/sites/default/files -type f -exec md5sum {} \; | sort
      store_as: baseline_checksums

  steps:
    - name: Create full backup
      cmd: pl backup verify-s3 "s3-test-backup"
      expect_exit: 0
      timeout: 60
      validate:
        - Backup file exists:
            cmd: ls -la sitebackups/verify-s3-*s3-test-backup*.tar.gz
            expect_exit: 0
        - Backup has content:
            cmd: tar -tzf sitebackups/verify-s3-*s3-test-backup*.tar.gz | head -20
            expect_contains:
              - "database.sql"
              - "files/"
              - ".env"

    - name: Create sanitized backup
      cmd: pl backup verify-s3 "s3-sanitized" --sanitize
      expect_exit: 0
      validate:
        - Sanitized backup exists:
            cmd: ls -la sitebackups/verify-s3-*s3-sanitized*-sanitized.tar.gz
            expect_exit: 0
        - User emails anonymized:
            cmd: |
              tar -xzf sitebackups/verify-s3-*s3-sanitized*-sanitized.tar.gz -O database.sql 2>/dev/null |
              grep -c "example.com"
            expect_output: "0"  # No real emails

    - name: Restore to new site
      cmd: pl restore verify-s3 verify-s3-restored --yes
      expect_exit: 0
      timeout: 120
      validate:
        - New site directory exists:
            cmd: test -d sites/verify-s3-restored
            expect_exit: 0
        - DDEV running:
            cmd: ddev describe verify-s3-restored 2>/dev/null | grep -q "running"
            expect_exit: 0

    - name: Verify user count preserved
      cmd: cd sites/verify-s3-restored && ddev drush sqlq "SELECT COUNT(*) FROM users_field_data WHERE uid > 0"
      expect_output: "{baseline_users}"
      on_failure:
        severity: critical
        message: "User count mismatch: expected {baseline_users}, got {actual}"

    - name: Verify node count preserved
      cmd: cd sites/verify-s3-restored && ddev drush sqlq "SELECT COUNT(*) FROM node_field_data"
      expect_output: "{baseline_nodes}"
      on_failure:
        severity: critical
        message: "Node count mismatch: expected {baseline_nodes}, got {actual}"

    - name: Verify pl status shows correct metrics
      cmd: pl status -s verify-s3-restored --json 2>/dev/null
      validate:
        - User count matches:
            extract: .users
            expect: "{baseline_users}"
        - Site is healthy:
            extract: .health
            expect: "healthy"

    - name: Run Behat smoke tests on restored site
      cmd: cd sites/verify-s3-restored && pl test -t behat:smoke
      expect_exit: 0
      timeout: 300
      on_failure:
        severity: high
        message: "Behat tests failed on restored site"
        capture_output: true

    - name: Compare file checksums
      cmd: find sites/verify-s3-restored/html/sites/default/files -type f -exec md5sum {} \; | sort
      validate:
        - Critical files match:
            compare_to: "{baseline_checksums}"
            tolerance: 0.95  # 95% of files must match

  cleanup:
    - cmd: pl delete verify-s3 --yes
    - cmd: pl delete verify-s3-restored --yes
    - cmd: rm -f sitebackups/verify-s3-*s3-*.tar.gz

  success_criteria:
    all_required:
      - User count preserved exactly
      - Node count preserved exactly
      - Behat smoke tests pass
      - pl status shows healthy

    confidence_scoring:
      - 100%: All checks pass, Behat full suite passes
      - 90%: All checks pass, Behat smoke passes
      - 75%: Counts match but Behat has failures
      - 50%: Partial data preservation
      - 0%: Critical data loss
```

### S5: Local Deployment (dev2stg Integration)

```yaml
scenario:
  id: S5
  name: Local Deployment Pipeline
  description: Verify dev→stg deployment preserves functionality
  depends_on: [S4]  # Needs working copy
  estimated_duration: 12 minutes

  commands_tested:
    - dev2stg.sh
    - make.sh
    - test.sh
    - status.sh

  steps:
    - name: Setup dev site with content
      cmd: pl install d verify-s5-dev --auto

    - name: Add development content
      cmd: |
        cd sites/verify-s5-dev
        ddev drush en devel_generate -y
        ddev drush devel-generate-content 10 --types=article
        ddev drush devel-generate-users 5

    - name: Capture dev state
      capture:
        user_count: ddev drush sqlq "SELECT COUNT(*) FROM users_field_data WHERE uid > 0"
        node_count: ddev drush sqlq "SELECT COUNT(*) FROM node_field_data"
        module_list: ddev drush pm:list --status=enabled --format=list

    - name: Deploy to staging
      cmd: pl dev2stg verify-s5-dev --yes
      expect_exit: 0
      validate:
        - Staging site created:
            cmd: test -d sites/verify-s5-dev-stg
        - Database imported:
            cmd: cd sites/verify-s5-dev-stg && ddev drush status --field=db-status
            expect_contains: "Connected"

    - name: Verify staging has same content
      validate:
        - User count matches:
            cmd: cd sites/verify-s5-dev-stg && ddev drush sqlq "SELECT COUNT(*) FROM users_field_data WHERE uid > 0"
            expect: "{user_count}"
        - Node count matches:
            cmd: cd sites/verify-s5-dev-stg && ddev drush sqlq "SELECT COUNT(*) FROM node_field_data"
            expect: "{node_count}"

    - name: Toggle production mode
      cmd: pl make verify-s5-dev-stg prod
      validate:
        - CSS aggregation enabled:
            cmd: cd sites/verify-s5-dev-stg && ddev drush config:get system.performance css.preprocess
            expect_contains: "true"
        - JS aggregation enabled:
            cmd: cd sites/verify-s5-dev-stg && ddev drush config:get system.performance js.preprocess
            expect_contains: "true"

    - name: Run full test suite on staging
      cmd: cd sites/verify-s5-dev-stg && pl test -t full
      expect_exit: 0
      on_failure:
        auto_fix:
          - pattern: "Module .* not found"
            fix: ddev drush en {module} -y
          - pattern: "Cache .* stale"
            fix: ddev drush cr
```

### S7: Security Hardening (with security-check cross-validation)

```yaml
scenario:
  id: S7
  name: Security Hardening
  description: Verify security configurations and vulnerability status
  depends_on: [S2]
  estimated_duration: 8 minutes

  commands_tested:
    - security.sh
    - security-check.sh

  live_state_commands:
    - command: pl security-check
      cross_validation_ref: section 4.8
      validates:
        - Core update availability
        - Security updates count
        - Outdated modules count
        - Files directory permissions
        - Settings.php protection
        - Debug mode status
        - HTTPS enforcement
        - User registration restrictions

  steps:
    - name: Setup test site
      cmd: pl install d verify-s7 --auto
      timeout: 180

    - name: Run security hardening
      cmd: pl security verify-s7
      expect_exit: 0

    - name: Cross-validate settings.php protection
      live_state:
        command: pl security-check verify-s7 --json | jq '.permissions.settings_protected'
        verify: |
          perm=$(stat -c "%a" sites/verify-s7/html/sites/default/settings.php 2>/dev/null)
          [[ "$perm" == "444" || "$perm" == "440" || "$perm" == "400" ]] && echo "true" || echo "false"
        tolerance: 0

    - name: Cross-validate files directory writable
      live_state:
        command: pl security-check verify-s7 --json | jq '.permissions.files_writable'
        verify: test -w sites/verify-s7/html/sites/default/files && echo "true" || echo "false"
        tolerance: 0

    - name: Cross-validate debug mode disabled
      live_state:
        command: pl security-check verify-s7 --json | jq '.config.debug_disabled'
        verify: |
          cd sites/verify-s7 && ddev drush config:get system.logging error_level --format=string 2>/dev/null | grep -q "hide" && echo "true" || echo "false"
        tolerance: 0

    - name: Cross-validate security updates count
      live_state:
        command: pl security-check verify-s7 --json | jq '.updates.security_count'
        verify: |
          cd sites/verify-s7 && ddev drush pm:security --format=json 2>/dev/null | jq 'length'
        tolerance: 0

    - name: Cross-validate outdated modules count
      live_state:
        command: pl security-check verify-s7 --json | jq '.updates.outdated_count'
        verify: |
          cd sites/verify-s7 && ddev composer outdated --direct --format=json 2>/dev/null | jq '.installed | length'
        tolerance: 0

    - name: Cross-validate user registration restrictions
      live_state:
        command: pl security-check verify-s7 --json | jq '.config.registration_restricted'
        verify: |
          cd sites/verify-s7 && ddev drush config:get user.settings register --format=string 2>/dev/null | grep -qv "visitors" && echo "true" || echo "false"
        tolerance: 0

  cleanup:
    - cmd: pl delete verify-s7 --yes 2>/dev/null || true

  success_criteria:
    all_required:
      - Settings.php properly protected
      - Debug mode disabled
      - All cross-validations pass
```

### S8: Quality Assurance Suite (with testos, seo-check, badges cross-validation)

```yaml
scenario:
  id: S8
  name: Quality Assurance Suite
  description: Complete testing and quality verification across all QA tools
  depends_on: [S2]
  estimated_duration: 15 minutes

  commands_tested:
    - test.sh
    - run-tests.sh
    - verify.sh
    - testos.sh
    - seo-check.sh
    - badges.sh

  live_state_commands:
    - command: pl testos
      cross_validation_ref: section 4.10
      validates:
        - Docker container running
        - Docker container healthy
        - Files directory permissions
        - PHP memory limit
        - MySQL running

    - command: pl seo-check
      cross_validation_ref: section 4.9
      validates:
        - Meta title present
        - Meta description present
        - Sitemap accessible
        - Robots.txt accessible
        - Canonical URL present

    - command: pl badges
      cross_validation_ref: section 4.11
      validates:
        - Machine coverage percentage
        - AI coverage percentage
        - Badge files exist

  steps:
    - name: Setup test site
      cmd: pl install d verify-s8 --auto
      timeout: 180

    - name: Run standard test suite
      cmd: pl test verify-s8
      expect_exit: 0
      validate:
        - PHPUnit passes:
            cmd: cd sites/verify-s8 && ddev exec vendor/bin/phpunit --testsuite=unit
            expect_exit: 0

    - name: Run extended tests
      cmd: pl run-tests verify-s8 --all
      expect_exit: 0
      capture:
        test_count: grep -c "test" output
        pass_count: grep -c "pass" output

    # testos cross-validation
    - name: Cross-validate Docker container running
      live_state:
        command: pl testos verify-s8 --json | jq '.docker.container_running'
        verify: |
          docker ps --filter "name=ddev-verify-s8" --format "{{.Status}}" | grep -q "Up" && echo "true" || echo "false"
        tolerance: 0

    - name: Cross-validate Docker container healthy
      live_state:
        command: pl testos verify-s8 --json | jq '.docker.container_healthy'
        verify: |
          docker ps --filter "name=ddev-verify-s8-web" --format "{{.Status}}" | grep -q "healthy" && echo "true" || echo "false"
        tolerance: 0

    - name: Cross-validate files directory permissions
      live_state:
        command: pl testos verify-s8 --json | jq -r '.filesystem.files_permissions'
        verify: stat -c "%a" sites/verify-s8/html/sites/default/files 2>/dev/null
        tolerance: 0

    - name: Cross-validate PHP memory limit
      live_state:
        command: pl testos verify-s8 --json | jq -r '.php.memory_limit'
        verify: cd sites/verify-s8 && ddev exec "php -r 'echo ini_get(\"memory_limit\");'"
        tolerance: 0

    - name: Cross-validate MySQL running
      live_state:
        command: pl testos verify-s8 --json | jq '.database.mysql_running'
        verify: cd sites/verify-s8 && ddev mysql -e "SELECT 1" >/dev/null 2>&1 && echo "true" || echo "false"
        tolerance: 0

    # seo-check cross-validation
    - name: Cross-validate meta title present
      live_state:
        command: pl seo-check verify-s8 --json | jq '.meta.title_present'
        verify: curl -s https://verify-s8.ddev.site 2>/dev/null | grep -q "<title>" && echo "true" || echo "false"
        tolerance: 0

    - name: Cross-validate meta description present
      live_state:
        command: pl seo-check verify-s8 --json | jq '.meta.description_present'
        verify: curl -s https://verify-s8.ddev.site 2>/dev/null | grep -qi 'name="description"' && echo "true" || echo "false"
        tolerance: 0

    - name: Cross-validate sitemap accessible
      live_state:
        command: pl seo-check verify-s8 --json | jq '.sitemap.accessible'
        verify: curl -s -o /dev/null -w "%{http_code}" https://verify-s8.ddev.site/sitemap.xml 2>/dev/null | grep -q "200" && echo "true" || echo "false"
        tolerance: 0

    - name: Cross-validate robots.txt accessible
      live_state:
        command: pl seo-check verify-s8 --json | jq '.robots.accessible'
        verify: curl -s -o /dev/null -w "%{http_code}" https://verify-s8.ddev.site/robots.txt 2>/dev/null | grep -q "200" && echo "true" || echo "false"
        tolerance: 0

    - name: Cross-validate page load time
      live_state:
        command: pl seo-check verify-s8 --json | jq '.performance.load_time_ms'
        verify: curl -s -o /dev/null -w "%{time_total}" https://verify-s8.ddev.site 2>/dev/null | awk '{printf "%.0f", $1 * 1000}'
        tolerance: 500

    # badges cross-validation
    - name: Generate and verify badges
      cmd: pl badges
      expect_exit: 0

    - name: Cross-validate machine coverage
      live_state:
        command: pl badges --json | jq '.machine.coverage'
        verify: |
          total=$(yq '.checklist | length' lib/verification-checklist.yml 2>/dev/null || echo "575")
          passed=$(grep -c "status: passed" .logs/verification/latest.log 2>/dev/null || echo "0")
          echo "scale=0; $passed * 100 / $total" | bc
        tolerance: 1

    - name: Cross-validate badge files exist
      live_state:
        command: pl badges --json | jq '.files.machine_svg'
        verify: test -f .verification-badges/machine.svg && echo "true" || echo "false"
        tolerance: 0

    - name: Run verification system
      cmd: pl verify --run --depth=basic
      expect_exit: 0
      validate:
        - Results logged:
            cmd: ls -la .logs/verification/verify-*.log | tail -1
            expect_exit: 0

  cleanup:
    - cmd: pl delete verify-s8 --yes 2>/dev/null || true

  success_criteria:
    all_required:
      - All testos cross-validations pass
      - All seo-check cross-validations pass
      - All badges cross-validations pass
      - Verification system runs successfully
```

### S10: Full Production Pipeline (Expanded)

```yaml
scenario:
  id: S10
  name: Full Production Pipeline
  description: Complete deployment workflow across all environments
  depends_on: [S5]
  estimated_duration: 25 minutes

  commands_tested:
    - stg2live.sh
    - live2stg.sh
    - live.sh
    - live2prod.sh
    - prod2stg.sh
    - stg2prod.sh

  setup:
    - Create dev site:
        cmd: pl install d verify-s10-dev --auto
    - Create staging site:
        cmd: pl copy verify-s10-dev verify-s10-stg
    - Add test content:
        cmd: |
          cd sites/verify-s10-dev
          ddev drush user:create produser --mail="prod@example.com" --password="test123"

  capture_baseline:
    dev_users:
      cmd: cd sites/verify-s10-dev && ddev drush sqlq "SELECT COUNT(*) FROM users_field_data WHERE uid > 0"
      store_as: baseline_users

  steps:
    - name: Test stg2live deployment
      cmd: pl stg2live verify-s10-stg --dry-run
      expect_exit: 0
      validate:
        - Deployment plan shown:
            expect_contains: "deployment plan"

    - name: Test live2stg sync
      cmd: pl live2stg verify-s10-stg --yes
      expect_exit: 0
      validate:
        - Database synced:
            cmd: cd sites/verify-s10-stg && ddev drush status --field=db-status
            expect_contains: "Connected"

    - name: Test live command
      cmd: pl live verify-s10-stg --status
      expect_exit: 0
      validate:
        - Status reported:
            expect_contains: "live"

    - name: Test live2prod workflow
      cmd: pl live2prod verify-s10-stg --dry-run
      expect_exit: 0
      validate:
        - Production target identified:
            expect_contains: "production"

    - name: Test prod2stg sync
      cmd: pl prod2stg verify-s10-stg --dry-run
      expect_exit: 0
      validate:
        - Staging sync planned:
            expect_contains: "staging"

    - name: Test stg2prod deployment
      cmd: pl stg2prod verify-s10-stg --dry-run
      expect_exit: 0
      validate:
        - Production deployment planned:
            expect_contains: "deploy"

    - name: Verify pl status reflects deployment state
      cmd: pl status -s verify-s10-stg --json
      validate:
        - Environment shown:
            extract: .environment
            expect: "staging"
```

### S13: Developer Environment & Contribution

```yaml
scenario:
  id: S13
  name: Developer Environment & Contribution
  description: Verify developer tooling and contribution workflows
  depends_on: [S1]
  estimated_duration: 12 minutes

  commands_tested:
    - bootstrap-coder.sh
    - coders.sh
    - coder-setup.sh
    - contribute.sh

  steps:
    - name: Bootstrap coder environment
      cmd: pl bootstrap-coder
      expect_exit: 0
      validate:
        - PHPCS installed:
            cmd: which phpcs || ddev exec which phpcs
            expect_exit: 0
        - Drupal standards available:
            cmd: phpcs -i | grep -i drupal || ddev exec phpcs -i | grep -i drupal
            expect_exit: 0

    - name: Setup coder for site
      cmd: pl install d verify-s13 --auto && pl coder-setup verify-s13
      expect_exit: 0
      timeout: 180
      validate:
        - Coder module enabled:
            cmd: cd sites/verify-s13 && ddev drush pm:list --status=enabled | grep -i coder
            expect_exit: 0

    - name: Run coders analysis
      cmd: pl coders verify-s13
      timeout: 300
      validate:
        - Analysis completes:
            expect_exit: 0
        - Report generated:
            expect_contains: "coding standards"

    - name: Test contribution workflow
      cmd: pl contribute --help
      expect_exit: 0
      validate:
        - Help shown:
            expect_contains: "contribute"
        - Options listed:
            expect_contains: "patch"

    - name: Verify contribution setup
      cmd: pl contribute verify-s13 --check
      expect_exit: 0
      validate:
        - Git configured:
            cmd: cd sites/verify-s13 && git config user.email
            expect_exit: 0
```

### S11: Specialized Installs (with avc-moodle-status cross-validation)

```yaml
scenario:
  id: S11
  name: Specialized Installs
  description: Verify podcast and AVC Moodle integration installations
  depends_on: [S1]
  estimated_duration: 15 minutes

  commands_tested:
    - podcast.sh
    - avc-moodle-setup.sh
    - avc-moodle-status.sh
    - avc-moodle-sync.sh
    - avc-moodle-test.sh

  live_state_commands:
    - command: pl avc-moodle-status
      cross_validation_ref: section 4.12
      validates:
        - Moodle connection status
        - Last sync timestamp
        - Users synced count
        - Courses synced count
        - Pending enrollments
        - Sync errors count

  steps:
    - name: Test podcast installation
      cmd: pl podcast --help
      expect_exit: 0
      validate:
        - Help displayed:
            expect_contains: "podcast"

    - name: Setup AVC Moodle integration
      cmd: pl avc-moodle-setup --check
      expect_exit: 0
      validate:
        - Setup check passes:
            expect_exit: 0

    # avc-moodle-status cross-validation
    - name: Cross-validate Moodle connection status
      live_state:
        command: pl avc-moodle-status --json | jq -r '.connection.status'
        verify: |
          source .secrets.yml 2>/dev/null
          if [[ -n "${MOODLE_URL:-}" && -n "${MOODLE_TOKEN:-}" ]]; then
            curl -s -o /dev/null -w "%{http_code}" "${MOODLE_URL}/webservice/rest/server.php?wstoken=${MOODLE_TOKEN}&wsfunction=core_webservice_get_site_info&moodlewsrestformat=json" 2>/dev/null | grep -q "200" && echo "connected" || echo "disconnected"
          else
            echo "not_configured"
          fi
        tolerance: 0

    - name: Cross-validate users synced count
      live_state:
        command: pl avc-moodle-status --json | jq '.sync.users_synced'
        verify: |
          if [[ -d sites/avc ]]; then
            cd sites/avc && ddev drush sqlq "SELECT COUNT(*) FROM user__field_moodle_id WHERE field_moodle_id_value IS NOT NULL" 2>/dev/null || echo "0"
          else
            echo "0"
          fi
        tolerance: 0

    - name: Cross-validate courses synced count
      live_state:
        command: pl avc-moodle-status --json | jq '.sync.courses_synced'
        verify: |
          if [[ -d sites/avc ]]; then
            cd sites/avc && ddev drush sqlq "SELECT COUNT(*) FROM node_field_data WHERE type='moodle_course'" 2>/dev/null || echo "0"
          else
            echo "0"
          fi
        tolerance: 0

    - name: Cross-validate pending enrollments
      live_state:
        command: pl avc-moodle-status --json | jq '.queue.pending_enrollments'
        verify: |
          if [[ -d sites/avc ]]; then
            cd sites/avc && ddev drush sqlq "SELECT COUNT(*) FROM queue WHERE name='moodle_enrollment'" 2>/dev/null || echo "0"
          else
            echo "0"
          fi
        tolerance: 0

    - name: Cross-validate sync errors count
      live_state:
        command: pl avc-moodle-status --json | jq '.errors.count'
        verify: |
          grep -c "ERROR" .logs/moodle/sync-*.log 2>/dev/null | tail -1 || echo "0"
        tolerance: 0

    - name: Test Moodle sync (dry-run)
      cmd: pl avc-moodle-sync --dry-run
      expect_exit: 0
      validate:
        - Sync plan shown:
            expect_contains: "sync"

    - name: Test Moodle integration tests
      cmd: pl avc-moodle-test --quick
      validate:
        - Tests run:
            expect_exit: 0

  success_criteria:
    all_required:
      - All avc-moodle-status cross-validations pass
      - Moodle connection verified (if configured)
```

### S14: Infrastructure & Communication (with storage cross-validation)

```yaml
scenario:
  id: S14
  name: Infrastructure & Communication
  description: Verify SSH setup, email, storage, and scheduling
  depends_on: [S1]
  estimated_duration: 10 minutes

  commands_tested:
    - setup-ssh.sh
    - email.sh
    - storage.sh
    - schedule.sh

  live_state_commands:
    - command: pl storage
      cross_validation_ref: section 4.6
      validates:
        - Site files size
        - Site files count
        - Database size
        - Total site size
        - Backup count
        - Available disk space

  steps:
    - name: Test SSH setup
      cmd: pl setup-ssh --check
      expect_exit: 0
      validate:
        - SSH keys detected:
            cmd: ls ~/.ssh/id_* 2>/dev/null | head -1
            expect_exit: 0
        - SSH config exists:
            cmd: test -f ~/.ssh/config
            expect_exit: 0

    - name: Install test site for storage verification
      cmd: pl install d verify-s14 --auto
      timeout: 180

    - name: Test email configuration
      cmd: pl email verify-s14 --test
      validate:
        - SMTP configured:
            cmd: cd sites/verify-s14 && ddev drush config:get smtp.settings smtp_on 2>/dev/null || echo "not configured"
        - Test email sent:
            expect_contains: "test"

    # storage cross-validation
    - name: Cross-validate site files size
      live_state:
        command: pl storage verify-s14 --json | jq '.files_mb'
        verify: du -sm sites/verify-s14/html/sites/default/files 2>/dev/null | cut -f1
        tolerance: 1

    - name: Cross-validate site files count
      live_state:
        command: pl storage verify-s14 --json | jq '.files_count'
        verify: find sites/verify-s14/html/sites/default/files -type f 2>/dev/null | wc -l
        tolerance: 0

    - name: Cross-validate database size
      live_state:
        command: pl storage verify-s14 --json | jq '.database_mb'
        verify: |
          cd sites/verify-s14 && ddev mysql -N -e "SELECT ROUND(SUM(data_length + index_length) / 1024 / 1024, 0) FROM information_schema.tables WHERE table_schema = DATABASE();"
        tolerance: 1

    - name: Cross-validate total site size
      live_state:
        command: pl storage verify-s14 --json | jq '.total_mb'
        verify: du -sm sites/verify-s14 2>/dev/null | cut -f1
        tolerance: 5

    - name: Cross-validate available disk space
      live_state:
        command: pl storage --json | jq '.available_gb'
        verify: df -BG . | tail -1 | awk '{print $4}' | tr -d 'G'
        tolerance: 1

    - name: Test scheduling system
      cmd: pl schedule --list
      expect_exit: 0
      validate:
        - Schedule displayed:
            expect_exit: 0
        - Cron jobs listed:
            cmd: crontab -l 2>/dev/null | grep -c "pl" || echo "0"

    - name: Verify scheduled tasks
      cmd: pl schedule verify-s14 --status
      expect_exit: 0
      validate:
        - Site cron configured:
            cmd: cd sites/verify-s14 && ddev drush cron:status 2>/dev/null || ddev drush status
            expect_exit: 0

  cleanup:
    - cmd: pl delete verify-s14 --yes 2>/dev/null || true

  success_criteria:
    all_required:
      - All storage cross-validations pass
      - SSH setup verified
      - Email configuration verified
```

### S15: Migration Pipeline

```yaml
scenario:
  id: S15
  name: Migration Pipeline
  description: Verify secrets migration and data migration workflows
  depends_on: [S3]
  estimated_duration: 8 minutes

  commands_tested:
    - migrate-secrets.sh
    - migration.sh

  steps:
    - name: Test secrets migration check
      cmd: pl migrate-secrets --check
      expect_exit: 0
      validate:
        - Secrets file detected:
            cmd: test -f .secrets.yml || test -f .secrets.example.yml
            expect_exit: 0
        - Migration status shown:
            expect_contains: "secret"

    - name: Test secrets migration dry-run
      cmd: pl migrate-secrets --dry-run
      validate:
        - No actual changes:
            cmd: md5sum .secrets.yml 2>/dev/null || echo "no secrets"
            store_as: secrets_hash_before

    - name: Setup migration test
      cmd: pl install d verify-s15-source --auto
      timeout: 180

    - name: Add migration source data
      cmd: |
        cd sites/verify-s15-source
        ddev drush user:create miguser1 --mail="mig1@example.com" --password="test123"
        ddev drush user:create miguser2 --mail="mig2@example.com" --password="test123"

    - name: Capture pre-migration state
      capture:
        source_users:
          cmd: cd sites/verify-s15-source && ddev drush sqlq "SELECT COUNT(*) FROM users_field_data WHERE uid > 0"
          store_as: source_user_count

    - name: Test migration command
      cmd: pl migration verify-s15-source --status
      expect_exit: 0
      validate:
        - Migration status shown:
            expect_contains: "migration"

    - name: Verify migration tooling
      cmd: pl migration --help
      expect_exit: 0
      validate:
        - Help displayed:
            expect_contains: "migration"
        - Options listed:
            expect_contains: "source"
```

### S16: Content & Theming (with report cross-validation)

```yaml
scenario:
  id: S16
  name: Content & Theming
  description: Verify content production, reporting, and theme management
  depends_on: [S2]
  estimated_duration: 12 minutes

  commands_tested:
    - produce.sh
    - report.sh
    - theme.sh

  live_state_commands:
    - command: pl report
      cross_validation_ref: section 4.7
      validates:
        - Total nodes
        - Nodes by type
        - Published nodes
        - Total users
        - Active users
        - Users by role
        - Total comments
        - Total files
        - Enabled modules count
        - Last cron run

    - command: pl status
      cross_validation_ref: section 4.3
      validates:
        - Node count accuracy
        - User count accuracy

  steps:
    - name: Setup test site
      cmd: pl install d verify-s16 --auto
      timeout: 180

    - name: Test content production
      cmd: pl produce verify-s16 --help
      expect_exit: 0
      validate:
        - Help shown:
            expect_contains: "produce"

    - name: Generate test content
      cmd: pl produce verify-s16 --demo
      validate:
        - Content created:
            cmd: cd sites/verify-s16 && ddev drush sqlq "SELECT COUNT(*) FROM node_field_data"
            expect_min: 1

    # report cross-validation
    - name: Cross-validate total nodes
      live_state:
        command: pl report verify-s16 --json | jq '.content.nodes.total'
        verify: cd sites/verify-s16 && ddev drush sqlq "SELECT COUNT(*) FROM node_field_data"
        tolerance: 0

    - name: Cross-validate published nodes
      live_state:
        command: pl report verify-s16 --json | jq '.content.nodes.published'
        verify: cd sites/verify-s16 && ddev drush sqlq "SELECT COUNT(*) FROM node_field_data WHERE status=1"
        tolerance: 0

    - name: Cross-validate total users
      live_state:
        command: pl report verify-s16 --json | jq '.users.total'
        verify: cd sites/verify-s16 && ddev drush sqlq "SELECT COUNT(*) FROM users_field_data WHERE uid > 0"
        tolerance: 0

    - name: Cross-validate active users
      live_state:
        command: pl report verify-s16 --json | jq '.users.active'
        verify: cd sites/verify-s16 && ddev drush sqlq "SELECT COUNT(*) FROM users_field_data WHERE uid > 0 AND status = 1"
        tolerance: 0

    - name: Cross-validate total files
      live_state:
        command: pl report verify-s16 --json | jq '.files.total'
        verify: cd sites/verify-s16 && ddev drush sqlq "SELECT COUNT(*) FROM file_managed"
        tolerance: 0

    - name: Cross-validate enabled modules count
      live_state:
        command: pl report verify-s16 --json | jq '.modules.enabled'
        verify: cd sites/verify-s16 && ddev drush pm:list --status=enabled --format=list | wc -l
        tolerance: 0

    - name: Cross-validate last cron run
      live_state:
        command: pl report verify-s16 --json | jq -r '.cron.last_run'
        verify: cd sites/verify-s16 && ddev drush state:get system.cron_last --format=string
        tolerance: 60

    - name: Export report
      cmd: pl report verify-s16 --export
      validate:
        - Export file created:
            cmd: ls reports/verify-s16-*.* 2>/dev/null | head -1 || echo "inline"

    - name: Test theme management
      cmd: pl theme verify-s16 --list
      expect_exit: 0
      validate:
        - Themes listed:
            cmd: cd sites/verify-s16 && ddev drush theme:list --status=enabled
            expect_exit: 0

    - name: Verify active theme
      cmd: pl theme verify-s16 --status
      expect_exit: 0
      validate:
        - Theme status shown:
            expect_contains: "theme"
        - Default theme identified:
            cmd: cd sites/verify-s16 && ddev drush config:get system.theme default
            expect_exit: 0

    # status cross-validation for content metrics
    - name: Cross-validate pl status node count
      live_state:
        command: pl status -s verify-s16 --json | jq '.nodes'
        verify: cd sites/verify-s16 && ddev drush sqlq "SELECT COUNT(*) FROM node_field_data"
        tolerance: 0

    - name: Cross-validate pl status user count
      live_state:
        command: pl status -s verify-s16 --json | jq '.users'
        verify: cd sites/verify-s16 && ddev drush sqlq "SELECT COUNT(*) FROM users_field_data WHERE uid > 0"
        tolerance: 0

  cleanup:
    - cmd: pl delete verify-s16 --yes 2>/dev/null || true

  success_criteria:
    all_required:
      - All report cross-validations pass
      - All status cross-validations pass
      - Content generation successful
      - Theme management verified
```

### S17: Upstream & Maintenance

```yaml
scenario:
  id: S17
  name: Upstream & Maintenance
  description: Verify upstream management and internal maintenance tools
  depends_on: [S12]
  estimated_duration: 8 minutes

  commands_tested:
    - upstream.sh
    - todo.sh

  steps:
    - name: Setup test site
      cmd: pl install d verify-s17 --auto
      timeout: 180

    - name: Test upstream check
      cmd: pl upstream verify-s17 --check
      expect_exit: 0
      validate:
        - Upstream status shown:
            expect_contains: "upstream"
        - Drupal core version:
            cmd: cd sites/verify-s17 && ddev drush status --field=drupal-version
            expect_exit: 0

    - name: Test upstream update check
      cmd: pl upstream verify-s17 --updates
      validate:
        - Updates listed:
            cmd: cd sites/verify-s17 && ddev composer outdated --direct 2>/dev/null || echo "up to date"
            expect_exit: 0

    - name: Test upstream sync
      cmd: pl upstream verify-s17 --dry-run
      expect_exit: 0
      validate:
        - Sync plan shown:
            expect_contains: "sync"

    - name: Test todo management
      cmd: pl todo --list
      expect_exit: 0
      validate:
        - Todo list displayed:
            expect_exit: 0

    - name: Add and verify todo item
      cmd: pl todo --add "Test verification task"
      validate:
        - Item added:
            cmd: pl todo --list | grep -c "Test verification"
            expect_min: 1

    - name: Complete todo item
      cmd: pl todo --done "Test verification task"
      validate:
        - Item marked done:
            expect_exit: 0

    - name: Verify pl status integration
      cmd: pl status --json | jq '.pending_todos // 0'
      validate:
        - Todo count accessible:
            expect_type: number
```

---

## 4. Deep Verification Techniques

### 4.1 Database State Verification

```yaml
database_checks:
  # Count-based verification
  user_integrity:
    query: |
      SELECT
        (SELECT COUNT(*) FROM users_field_data WHERE uid > 0) as users,
        (SELECT COUNT(*) FROM users_field_data WHERE status = 1) as active,
        (SELECT COUNT(*) FROM users_roles) as role_assignments
    validate:
      - users >= active  # Can't have more active than total
      - role_assignments >= users  # Every user has at least one role

  # Relational integrity
  content_integrity:
    query: |
      SELECT
        (SELECT COUNT(*) FROM node_field_data) as nodes,
        (SELECT COUNT(*) FROM node__body) as bodies,
        (SELECT COUNT(DISTINCT nid) FROM node__body) as nodes_with_body
    validate:
      - nodes >= nodes_with_body  # Not all nodes need body
      - bodies >= nodes_with_body  # Can have revisions

  # Configuration state
  config_integrity:
    cmd: ddev drush config:export --destination=/tmp/config-check -y && ls /tmp/config-check/*.yml | wc -l
    store_as: config_file_count
    min_expected: 100  # Drupal has ~100+ config files minimum
```

### 4.2 Behat Integration

```yaml
behat_verification:
  smoke_tests:
    cmd: cd {site} && ddev drush behat --tags=@smoke
    timeout: 120
    success_threshold: 100%  # All smoke tests must pass

  functional_tests:
    cmd: cd {site} && ddev drush behat --tags=@functional
    timeout: 600
    success_threshold: 95%  # Allow 5% flaky tests

  critical_paths:
    - Login as admin:
        feature: features/authentication.feature
        scenario: "Admin can log in"
    - Create content:
        feature: features/content.feature
        scenario: "Create article"
    - User management:
        feature: features/users.feature
        scenario: "Create user account"

  on_failure:
    capture:
      - screenshots/
      - logs/behat.log
    report_to: verification_findings
```

### 4.3 pl status Cross-Validation

```yaml
status_verification:
  # Run pl status and verify against actual database
  cross_validate:
    - name: User count accuracy
      status_cmd: pl status -s {site} --json | jq '.users'
      verify_cmd: ddev drush sqlq "SELECT COUNT(*) FROM users_field_data WHERE uid > 0"
      tolerance: 0  # Must match exactly

    - name: Database size accuracy
      status_cmd: pl status -s {site} --json | jq '.db_size_mb'
      verify_cmd: |
        ddev mysql -N -e "SELECT ROUND(SUM(data_length + index_length) / 1024 / 1024, 0)
        FROM information_schema.tables WHERE table_schema = DATABASE();"
      tolerance: 1  # Allow 1MB difference (rounding)

    - name: Health status accuracy
      status_cmd: pl status -s {site} --json | jq '.health'
      verify_conditions:
        healthy:
          - DDEV running: ddev describe {site} | grep -q "running"
          - DB connected: ddev drush status --field=db-status | grep -q "Connected"
          - Drupal bootstrapped: ddev drush status --field=bootstrap | grep -q "Successful"
```

### 4.4 Live State Commands Catalog

Live state commands report on current system state and are critical for verification cross-validation. Each command's output must be verifiable against actual system queries.

```yaml
live_state_commands:
  # Commands that report live state (not perform operations)
  catalog:
    - command: pl status
      purpose: Site health, user/node counts, database size
      scenario: S2, S3, S4, S6, S9, S10, S16, S17
      cross_validation: section 4.3

    - command: pl doctor
      purpose: System dependencies, DDEV health, environment checks
      scenario: S1
      cross_validation: section 4.5

    - command: pl storage
      purpose: Disk usage, file counts, backup sizes
      scenario: S14
      cross_validation: section 4.6

    - command: pl report
      purpose: Site statistics, content metrics, activity logs
      scenario: S16
      cross_validation: section 4.7

    - command: pl security-check
      purpose: Security updates, vulnerability status, permissions
      scenario: S7
      cross_validation: section 4.8

    - command: pl seo-check
      purpose: Meta tags, sitemap, robots.txt, page speed
      scenario: S8
      cross_validation: section 4.9

    - command: pl testos
      purpose: Docker health, filesystem permissions, OS state
      scenario: S8
      cross_validation: section 4.10

    - command: pl badges
      purpose: Verification coverage percentages, test results
      scenario: S8
      cross_validation: section 4.11

    - command: pl avc-moodle-status
      purpose: Moodle integration state, sync status
      scenario: S11
      cross_validation: section 4.12

  verification_principle: |
    Every live state command MUST be cross-validated against the actual
    system state it claims to report. If pl storage says "150MB files",
    we verify with: du -sh sites/{site}/html/sites/default/files
```

### 4.5 pl doctor Cross-Validation

```yaml
doctor_verification:
  # Verify pl doctor accurately reports system state
  cross_validate:
    - name: Docker availability
      doctor_cmd: pl doctor --json | jq '.docker.available'
      verify_cmd: docker --version >/dev/null 2>&1 && echo "true" || echo "false"
      tolerance: 0

    - name: Docker running
      doctor_cmd: pl doctor --json | jq '.docker.running'
      verify_cmd: docker info >/dev/null 2>&1 && echo "true" || echo "false"
      tolerance: 0

    - name: DDEV version
      doctor_cmd: pl doctor --json | jq -r '.ddev.version'
      verify_cmd: ddev version --json-output | jq -r '.raw'
      tolerance: 0

    - name: DDEV running projects
      doctor_cmd: pl doctor --json | jq '.ddev.running_projects'
      verify_cmd: ddev list --json-output 2>/dev/null | jq '[.raw[] | select(.status == "running")] | length'
      tolerance: 0

    - name: PHP version
      doctor_cmd: pl doctor --json | jq -r '.php.version'
      verify_cmd: php -r "echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION;"
      tolerance: 0

    - name: Composer available
      doctor_cmd: pl doctor --json | jq '.composer.available'
      verify_cmd: which composer >/dev/null 2>&1 && echo "true" || echo "false"
      tolerance: 0

    - name: Git version
      doctor_cmd: pl doctor --json | jq -r '.git.version'
      verify_cmd: git --version | grep -oP '\d+\.\d+\.\d+'
      tolerance: 0

    - name: Disk space available
      doctor_cmd: pl doctor --json | jq '.disk.available_gb'
      verify_cmd: df -BG . | tail -1 | awk '{print $4}' | tr -d 'G'
      tolerance: 1  # Allow 1GB variance

    - name: Memory available
      doctor_cmd: pl doctor --json | jq '.memory.available_mb'
      verify_cmd: free -m | awk '/^Mem:/{print $7}'
      tolerance: 100  # Allow 100MB variance (dynamic)
```

### 4.6 pl storage Cross-Validation

```yaml
storage_verification:
  # Verify pl storage accurately reports disk usage
  cross_validate:
    - name: Site files size
      storage_cmd: pl storage {site} --json | jq '.files_mb'
      verify_cmd: |
        du -sm sites/{site}/html/sites/default/files 2>/dev/null | cut -f1
      tolerance: 1  # Allow 1MB difference

    - name: Site files count
      storage_cmd: pl storage {site} --json | jq '.files_count'
      verify_cmd: |
        find sites/{site}/html/sites/default/files -type f 2>/dev/null | wc -l
      tolerance: 0

    - name: Database size
      storage_cmd: pl storage {site} --json | jq '.database_mb'
      verify_cmd: |
        cd sites/{site} && ddev mysql -N -e "SELECT ROUND(SUM(data_length + index_length) / 1024 / 1024, 0) FROM information_schema.tables WHERE table_schema = DATABASE();"
      tolerance: 1

    - name: Total site size
      storage_cmd: pl storage {site} --json | jq '.total_mb'
      verify_cmd: |
        du -sm sites/{site} 2>/dev/null | cut -f1
      tolerance: 5  # Allow 5MB variance (caches, logs)

    - name: Backup count
      storage_cmd: pl storage {site} --json | jq '.backup_count'
      verify_cmd: |
        ls -1 sitebackups/{site}-*.tar.gz 2>/dev/null | wc -l
      tolerance: 0

    - name: Backup total size
      storage_cmd: pl storage {site} --json | jq '.backup_mb'
      verify_cmd: |
        du -cm sitebackups/{site}-*.tar.gz 2>/dev/null | tail -1 | cut -f1
      tolerance: 1

    - name: Available disk space
      storage_cmd: pl storage --json | jq '.available_gb'
      verify_cmd: df -BG . | tail -1 | awk '{print $4}' | tr -d 'G'
      tolerance: 1
```

### 4.7 pl report Cross-Validation

```yaml
report_verification:
  # Verify pl report accurately reports site statistics
  cross_validate:
    - name: Total nodes
      report_cmd: pl report {site} --json | jq '.content.nodes.total'
      verify_cmd: |
        cd sites/{site} && ddev drush sqlq "SELECT COUNT(*) FROM node_field_data"
      tolerance: 0

    - name: Nodes by type
      report_cmd: pl report {site} --json | jq '.content.nodes.by_type.article'
      verify_cmd: |
        cd sites/{site} && ddev drush sqlq "SELECT COUNT(*) FROM node_field_data WHERE type='article'"
      tolerance: 0

    - name: Published nodes
      report_cmd: pl report {site} --json | jq '.content.nodes.published'
      verify_cmd: |
        cd sites/{site} && ddev drush sqlq "SELECT COUNT(*) FROM node_field_data WHERE status=1"
      tolerance: 0

    - name: Total users
      report_cmd: pl report {site} --json | jq '.users.total'
      verify_cmd: |
        cd sites/{site} && ddev drush sqlq "SELECT COUNT(*) FROM users_field_data WHERE uid > 0"
      tolerance: 0

    - name: Active users
      report_cmd: pl report {site} --json | jq '.users.active'
      verify_cmd: |
        cd sites/{site} && ddev drush sqlq "SELECT COUNT(*) FROM users_field_data WHERE uid > 0 AND status = 1"
      tolerance: 0

    - name: Users by role
      report_cmd: pl report {site} --json | jq '.users.by_role.administrator'
      verify_cmd: |
        cd sites/{site} && ddev drush sqlq "SELECT COUNT(*) FROM user__roles WHERE roles_target_id='administrator'"
      tolerance: 0

    - name: Total comments
      report_cmd: pl report {site} --json | jq '.content.comments.total'
      verify_cmd: |
        cd sites/{site} && ddev drush sqlq "SELECT COUNT(*) FROM comment_field_data" 2>/dev/null || echo "0"
      tolerance: 0

    - name: Total files
      report_cmd: pl report {site} --json | jq '.files.total'
      verify_cmd: |
        cd sites/{site} && ddev drush sqlq "SELECT COUNT(*) FROM file_managed"
      tolerance: 0

    - name: Enabled modules count
      report_cmd: pl report {site} --json | jq '.modules.enabled'
      verify_cmd: |
        cd sites/{site} && ddev drush pm:list --status=enabled --format=list | wc -l
      tolerance: 0

    - name: Last cron run
      report_cmd: pl report {site} --json | jq -r '.cron.last_run'
      verify_cmd: |
        cd sites/{site} && ddev drush state:get system.cron_last --format=string
      tolerance: 60  # Allow 60 second variance
```

### 4.8 pl security-check Cross-Validation

```yaml
security_check_verification:
  # Verify pl security-check accurately reports security state
  cross_validate:
    - name: Core update available
      security_cmd: pl security-check {site} --json | jq '.updates.core.available'
      verify_cmd: |
        cd sites/{site} && ddev drush pm:security --format=json 2>/dev/null | jq '.[] | select(.name == "drupal") | .version' | wc -l | xargs -I{} test {} -gt 0 && echo "true" || echo "false"
      tolerance: 0

    - name: Security updates count
      security_cmd: pl security-check {site} --json | jq '.updates.security_count'
      verify_cmd: |
        cd sites/{site} && ddev drush pm:security --format=json 2>/dev/null | jq 'length'
      tolerance: 0

    - name: Outdated modules count
      security_cmd: pl security-check {site} --json | jq '.updates.outdated_count'
      verify_cmd: |
        cd sites/{site} && ddev composer outdated --direct --format=json 2>/dev/null | jq '.installed | length'
      tolerance: 0

    - name: Files directory writable
      security_cmd: pl security-check {site} --json | jq '.permissions.files_writable'
      verify_cmd: |
        test -w sites/{site}/html/sites/default/files && echo "true" || echo "false"
      tolerance: 0

    - name: Settings.php protected
      security_cmd: pl security-check {site} --json | jq '.permissions.settings_protected'
      verify_cmd: |
        perm=$(stat -c "%a" sites/{site}/html/sites/default/settings.php 2>/dev/null)
        [[ "$perm" == "444" || "$perm" == "440" || "$perm" == "400" ]] && echo "true" || echo "false"
      tolerance: 0

    - name: Debug mode disabled
      security_cmd: pl security-check {site} --json | jq '.config.debug_disabled'
      verify_cmd: |
        cd sites/{site} && ddev drush config:get system.logging error_level --format=string 2>/dev/null | grep -q "hide" && echo "true" || echo "false"
      tolerance: 0

    - name: HTTPS enforced
      security_cmd: pl security-check {site} --json | jq '.config.https_enforced'
      verify_cmd: |
        cd sites/{site} && ddev drush config:get seckit.settings seckit_ssl.hsts --format=string 2>/dev/null | grep -q "1" && echo "true" || echo "false"
      tolerance: 0

    - name: User registration restricted
      security_cmd: pl security-check {site} --json | jq '.config.registration_restricted'
      verify_cmd: |
        cd sites/{site} && ddev drush config:get user.settings register --format=string 2>/dev/null | grep -qv "visitors" && echo "true" || echo "false"
      tolerance: 0
```

### 4.9 pl seo-check Cross-Validation

```yaml
seo_check_verification:
  # Verify pl seo-check accurately reports SEO state
  cross_validate:
    - name: Meta title present
      seo_cmd: pl seo-check {site} --json | jq '.meta.title_present'
      verify_cmd: |
        curl -s https://{site}.ddev.site 2>/dev/null | grep -q "<title>" && echo "true" || echo "false"
      tolerance: 0

    - name: Meta description present
      seo_cmd: pl seo-check {site} --json | jq '.meta.description_present'
      verify_cmd: |
        curl -s https://{site}.ddev.site 2>/dev/null | grep -qi 'name="description"' && echo "true" || echo "false"
      tolerance: 0

    - name: Meta tags count
      seo_cmd: pl seo-check {site} --json | jq '.meta.count'
      verify_cmd: |
        curl -s https://{site}.ddev.site 2>/dev/null | grep -c "<meta" || echo "0"
      tolerance: 2  # Allow variance for dynamic meta

    - name: Sitemap accessible
      seo_cmd: pl seo-check {site} --json | jq '.sitemap.accessible'
      verify_cmd: |
        curl -s -o /dev/null -w "%{http_code}" https://{site}.ddev.site/sitemap.xml 2>/dev/null | grep -q "200" && echo "true" || echo "false"
      tolerance: 0

    - name: Sitemap URL count
      seo_cmd: pl seo-check {site} --json | jq '.sitemap.url_count'
      verify_cmd: |
        curl -s https://{site}.ddev.site/sitemap.xml 2>/dev/null | grep -c "<loc>" || echo "0"
      tolerance: 5  # Allow variance for dynamic content

    - name: Robots.txt accessible
      seo_cmd: pl seo-check {site} --json | jq '.robots.accessible'
      verify_cmd: |
        curl -s -o /dev/null -w "%{http_code}" https://{site}.ddev.site/robots.txt 2>/dev/null | grep -q "200" && echo "true" || echo "false"
      tolerance: 0

    - name: Canonical URL present
      seo_cmd: pl seo-check {site} --json | jq '.meta.canonical_present'
      verify_cmd: |
        curl -s https://{site}.ddev.site 2>/dev/null | grep -qi 'rel="canonical"' && echo "true" || echo "false"
      tolerance: 0

    - name: Open Graph tags present
      seo_cmd: pl seo-check {site} --json | jq '.meta.og_present'
      verify_cmd: |
        curl -s https://{site}.ddev.site 2>/dev/null | grep -qi 'property="og:' && echo "true" || echo "false"
      tolerance: 0

    - name: Page load time
      seo_cmd: pl seo-check {site} --json | jq '.performance.load_time_ms'
      verify_cmd: |
        curl -s -o /dev/null -w "%{time_total}" https://{site}.ddev.site 2>/dev/null | awk '{printf "%.0f", $1 * 1000}'
      tolerance: 500  # Allow 500ms variance
```

### 4.10 pl testos Cross-Validation

```yaml
testos_verification:
  # Verify pl testos accurately reports OS/container state
  cross_validate:
    - name: Docker container running
      testos_cmd: pl testos {site} --json | jq '.docker.container_running'
      verify_cmd: |
        docker ps --filter "name=ddev-{site}" --format "{{.Status}}" | grep -q "Up" && echo "true" || echo "false"
      tolerance: 0

    - name: Docker container healthy
      testos_cmd: pl testos {site} --json | jq '.docker.container_healthy'
      verify_cmd: |
        docker ps --filter "name=ddev-{site}-web" --format "{{.Status}}" | grep -q "healthy" && echo "true" || echo "false"
      tolerance: 0

    - name: Files directory permissions
      testos_cmd: pl testos {site} --json | jq -r '.filesystem.files_permissions'
      verify_cmd: |
        stat -c "%a" sites/{site}/html/sites/default/files 2>/dev/null
      tolerance: 0

    - name: Files directory owner
      testos_cmd: pl testos {site} --json | jq -r '.filesystem.files_owner'
      verify_cmd: |
        stat -c "%U" sites/{site}/html/sites/default/files 2>/dev/null
      tolerance: 0

    - name: Temp directory writable
      testos_cmd: pl testos {site} --json | jq '.filesystem.temp_writable'
      verify_cmd: |
        cd sites/{site} && ddev exec "test -w /tmp && echo true || echo false"
      tolerance: 0

    - name: PHP memory limit
      testos_cmd: pl testos {site} --json | jq -r '.php.memory_limit'
      verify_cmd: |
        cd sites/{site} && ddev exec "php -r 'echo ini_get(\"memory_limit\");'"
      tolerance: 0

    - name: PHP max execution time
      testos_cmd: pl testos {site} --json | jq '.php.max_execution_time'
      verify_cmd: |
        cd sites/{site} && ddev exec "php -r 'echo ini_get(\"max_execution_time\");'"
      tolerance: 0

    - name: MySQL running
      testos_cmd: pl testos {site} --json | jq '.database.mysql_running'
      verify_cmd: |
        cd sites/{site} && ddev mysql -e "SELECT 1" >/dev/null 2>&1 && echo "true" || echo "false"
      tolerance: 0

    - name: Redis available (if configured)
      testos_cmd: pl testos {site} --json | jq '.services.redis_available'
      verify_cmd: |
        cd sites/{site} && ddev redis-cli ping 2>/dev/null | grep -q "PONG" && echo "true" || echo "false"
      tolerance: 0

    - name: Mailpit available
      testos_cmd: pl testos {site} --json | jq '.services.mailpit_available'
      verify_cmd: |
        curl -s -o /dev/null -w "%{http_code}" https://{site}.ddev.site:8026 2>/dev/null | grep -q "200" && echo "true" || echo "false"
      tolerance: 0
```

### 4.11 pl badges Cross-Validation

```yaml
badges_verification:
  # Verify pl badges accurately reports verification coverage
  cross_validate:
    - name: Machine coverage percentage
      badges_cmd: pl badges --json | jq '.machine.coverage'
      verify_cmd: |
        # Recompute from verification checklist
        total=$(yq '.checklist | length' lib/verification-checklist.yml)
        passed=$(grep -c "status: passed" .logs/verification/latest.log 2>/dev/null || echo "0")
        echo "scale=0; $passed * 100 / $total" | bc
      tolerance: 1

    - name: Machine items verified
      badges_cmd: pl badges --json | jq '.machine.items_verified'
      verify_cmd: |
        grep -c "status: passed" .logs/verification/latest.log 2>/dev/null || echo "0"
      tolerance: 0

    - name: AI coverage percentage
      badges_cmd: pl badges --json | jq '.ai.coverage'
      verify_cmd: |
        # Recompute from scenario results
        if [[ -f .verification-checkpoint.yml ]]; then
          scenarios_complete=$(yq '.completed_scenarios | length' .verification-checkpoint.yml)
          total_scenarios=17
          echo "scale=0; $scenarios_complete * 100 / $total_scenarios" | bc
        else
          echo "0"
        fi
      tolerance: 1

    - name: AI scenarios complete
      badges_cmd: pl badges --json | jq '.ai.scenarios_complete'
      verify_cmd: |
        yq '.completed_scenarios | length' .verification-checkpoint.yml 2>/dev/null || echo "0"
      tolerance: 0

    - name: Human coverage percentage
      badges_cmd: pl badges --json | jq '.human.coverage'
      verify_cmd: |
        # Count manual verification entries
        total=$(yq '.checklist | length' lib/verification-checklist.yml)
        manual=$(grep -c "verified_by: human" .logs/verification/manual-*.log 2>/dev/null || echo "0")
        echo "scale=0; $manual * 100 / $total" | bc
      tolerance: 1

    - name: Peak machine coverage
      badges_cmd: pl badges --json | jq '.peaks.machine'
      verify_cmd: |
        yq '.peaks.machine.coverage' .verification-peaks.yml 2>/dev/null || echo "0"
      tolerance: 0

    - name: Peak AI coverage
      badges_cmd: pl badges --json | jq '.peaks.ai'
      verify_cmd: |
        yq '.peaks.ai.coverage' .verification-peaks.yml 2>/dev/null || echo "0"
      tolerance: 0

    - name: Badge files exist
      badges_cmd: pl badges --json | jq '.files.machine_svg'
      verify_cmd: |
        test -f .verification-badges/machine.svg && echo "true" || echo "false"
      tolerance: 0
```

### 4.12 pl avc-moodle-status Cross-Validation

```yaml
avc_moodle_status_verification:
  # Verify pl avc-moodle-status accurately reports Moodle integration state
  cross_validate:
    - name: Moodle connection status
      moodle_cmd: pl avc-moodle-status --json | jq '.connection.status'
      verify_cmd: |
        # Test actual Moodle API connection
        source .secrets.yml 2>/dev/null
        curl -s -o /dev/null -w "%{http_code}" "${MOODLE_URL}/webservice/rest/server.php?wstoken=${MOODLE_TOKEN}&wsfunction=core_webservice_get_site_info&moodlewsrestformat=json" 2>/dev/null | grep -q "200" && echo "connected" || echo "disconnected"
      tolerance: 0

    - name: Last sync timestamp
      moodle_cmd: pl avc-moodle-status --json | jq -r '.sync.last_sync'
      verify_cmd: |
        # Check actual sync log
        stat -c "%Y" .logs/moodle/last-sync.log 2>/dev/null || echo "0"
      tolerance: 60  # Allow 60 second variance

    - name: Users synced count
      moodle_cmd: pl avc-moodle-status --json | jq '.sync.users_synced'
      verify_cmd: |
        # Count users with Moodle ID in Drupal
        cd sites/avc && ddev drush sqlq "SELECT COUNT(*) FROM user__field_moodle_id WHERE field_moodle_id_value IS NOT NULL" 2>/dev/null || echo "0"
      tolerance: 0

    - name: Courses synced count
      moodle_cmd: pl avc-moodle-status --json | jq '.sync.courses_synced'
      verify_cmd: |
        # Count Moodle courses in Drupal
        cd sites/avc && ddev drush sqlq "SELECT COUNT(*) FROM node_field_data WHERE type='moodle_course'" 2>/dev/null || echo "0"
      tolerance: 0

    - name: Pending enrollments
      moodle_cmd: pl avc-moodle-status --json | jq '.queue.pending_enrollments'
      verify_cmd: |
        # Check queue table
        cd sites/avc && ddev drush sqlq "SELECT COUNT(*) FROM queue WHERE name='moodle_enrollment'" 2>/dev/null || echo "0"
      tolerance: 0

    - name: Sync errors count
      moodle_cmd: pl avc-moodle-status --json | jq '.errors.count'
      verify_cmd: |
        # Count recent errors in log
        grep -c "ERROR" .logs/moodle/sync-*.log 2>/dev/null | tail -1 || echo "0"
      tolerance: 0

    - name: API rate limit remaining
      moodle_cmd: pl avc-moodle-status --json | jq '.api.rate_limit_remaining'
      verify_cmd: |
        # Check actual Moodle rate limit (if available)
        source .secrets.yml 2>/dev/null
        curl -s -I "${MOODLE_URL}/webservice/rest/server.php?wstoken=${MOODLE_TOKEN}&wsfunction=core_webservice_get_site_info&moodlewsrestformat=json" 2>/dev/null | grep -i "x-ratelimit-remaining" | awk '{print $2}' || echo "unknown"
      tolerance: 10
```

### 4.13 Live State Command Integration Matrix

This matrix shows how each live state command integrates with verification scenarios:

```
┌─────────────────────┬────────────────────────────────────────────────────────────┐
│ Command             │ Scenario Integration                                        │
├─────────────────────┼────────────────────────────────────────────────────────────┤
│ pl status           │ S2: Baseline capture, S3: Pre/post restore comparison,     │
│                     │ S4: Copy verification, S6: Import verification,            │
│                     │ S9: Config change verification, S10: Deployment state,     │
│                     │ S16: Content metrics, S17: Todo integration                │
├─────────────────────┼────────────────────────────────────────────────────────────┤
│ pl doctor           │ S1: Foundation verification (Docker, DDEV, PHP, Composer)  │
│                     │ Pre-scenario gate: Must pass before any scenario runs      │
├─────────────────────┼────────────────────────────────────────────────────────────┤
│ pl storage          │ S14: Storage verification, S3: Backup size verification,   │
│                     │ Resource monitoring throughout all scenarios               │
├─────────────────────┼────────────────────────────────────────────────────────────┤
│ pl report           │ S16: Content metrics, S3: Node/user counts,                │
│                     │ Post-operation statistics in all content scenarios         │
├─────────────────────┼────────────────────────────────────────────────────────────┤
│ pl security-check   │ S7: Security hardening verification,                       │
│                     │ Post-install security baseline in S2                       │
├─────────────────────┼────────────────────────────────────────────────────────────┤
│ pl seo-check        │ S8: QA suite verification,                                 │
│                     │ Post-deployment SEO state in S5, S10                       │
├─────────────────────┼────────────────────────────────────────────────────────────┤
│ pl testos           │ S8: OS-level verification,                                 │
│                     │ Container health monitoring throughout all scenarios       │
├─────────────────────┼────────────────────────────────────────────────────────────┤
│ pl badges           │ S8: Badge generation verification,                         │
│                     │ Final coverage summary after full verification run         │
├─────────────────────┼────────────────────────────────────────────────────────────┤
│ pl avc-moodle-status│ S11: Moodle integration verification                       │
│                     │ AVC-specific sync state monitoring                         │
└─────────────────────┴────────────────────────────────────────────────────────────┘
```

### 4.14 Cross-Validation Execution Protocol

```yaml
cross_validation_protocol:
  # Standard protocol for running cross-validation

  execution_order:
    1. Run live state command with --json flag
    2. Parse JSON output and extract target values
    3. Run corresponding verify_cmd
    4. Compare values within tolerance
    5. Log result (pass/fail/variance)
    6. On failure: flag for investigation

  failure_handling:
    minor_variance:
      # Within 2x tolerance
      action: log_warning
      continue: true
      message: "{command} reported {reported}, actual is {actual} (within tolerance)"

    major_variance:
      # Outside tolerance
      action: log_error
      continue: true
      auto_fix:
        - Retry command after cache clear
        - Check for stale data
      message: "{command} MISMATCH: reported {reported}, actual is {actual}"

    critical_failure:
      # Command fails or returns invalid data
      action: halt_scenario
      continue: false
      escalate: true
      message: "{command} failed cross-validation - manual investigation required"

  timing_considerations:
    # Some values change rapidly
    volatile_fields:
      - memory_available  # Changes constantly
      - load_time_ms      # Varies per request
      - last_cron_run     # Updates periodically

    stable_fields:
      - user_count        # Only changes with user operations
      - node_count        # Only changes with content operations
      - permissions       # Only changes with explicit chmod

    strategy: |
      For volatile fields: use wider tolerances and multiple samples
      For stable fields: use zero tolerance and single verification

  caching_awareness:
    # Commands may cache results
    force_fresh:
      - Add --no-cache flag if available
      - Clear relevant caches before verification
      - Wait 2 seconds after cache clear

    cache_aware_commands:
      - pl status       # May cache for 60s
      - pl storage      # May cache filesystem stats
      - pl seo-check    # May cache HTTP responses
```

---

## 5. Error Detection and Auto-Fix

### 5.1 Common Error Patterns

```yaml
auto_fix_patterns:
  database_errors:
    - pattern: "SQLSTATE.*Connection refused"
      diagnosis: Database container not running
      fix:
        - cmd: ddev restart
        - verify: ddev drush status --field=db-status

    - pattern: "Base table or view not found"
      diagnosis: Missing database tables
      fix:
        - cmd: ddev drush updatedb -y
        - cmd: ddev drush cr

  configuration_errors:
    - pattern: "Config .* does not exist"
      diagnosis: Missing configuration
      fix:
        - cmd: ddev drush config:import -y
        - verify: ddev drush config:status

    - pattern: "Module .* is missing"
      diagnosis: Module not installed
      fix:
        - cmd: ddev composer require drupal/{module}
        - cmd: ddev drush en {module} -y

  permission_errors:
    - pattern: "Permission denied.*sites/default/files"
      diagnosis: Incorrect file permissions
      fix:
        - cmd: chmod -R 775 sites/{site}/html/sites/default/files
        - cmd: chown -R $(whoami):www-data sites/{site}/html/sites/default/files

  cache_errors:
    - pattern: "Cached .* is stale"
      diagnosis: Stale cache
      fix:
        - cmd: ddev drush cr
```

### 5.2 Intelligent Fix Sequencing

```yaml
fix_strategy:
  # Try fixes in order of least to most disruptive
  levels:
    1_cache:
      - ddev drush cr
      - ddev drush cron

    2_database:
      - ddev drush updatedb -y
      - ddev drush config:import -y

    3_restart:
      - ddev restart
      - ddev drush cr

    4_rebuild:
      - ddev composer install
      - ddev drush updatedb -y
      - ddev drush config:import -y
      - ddev drush cr

    5_reinstall:
      - Report to human - requires manual intervention
```

---

## 6. Progressive Execution & Checkpointing

### 6.1 Checkpoint Structure

```yaml
# .verification-checkpoint.yml
checkpoint:
  run_id: "ai-verify-20260117-143052"
  started_at: "2026-01-17T14:30:52+11:00"
  last_updated: "2026-01-17T15:12:33+11:00"

  progress:
    scenarios:
      total: 17
      completed: 4
      in_progress: 1
      remaining: 12

    items:
      total: 471
      verified: 143

  current:
    scenario: S5
    step: 6
    step_name: "Run full test suite on staging"

  test_sites:
    - name: verify-s5-dev
      preserve: true
      reason: "In-progress testing"
    - name: verify-s5-dev-stg
      preserve: true
      reason: "Current test target"

  completed_scenarios:
    - id: S1
      status: passed
      duration: 142
      confidence: 98

    - id: S2
      status: passed
      duration: 267
      confidence: 95

    - id: S3
      status: passed
      duration: 489
      confidence: 97
      items_verified: 47

    - id: S4
      status: passed
      duration: 312
      confidence: 94

  findings:
    - scenario: S3
      step: 7
      type: warning
      message: "Behat test 'comment_reply' flaky - passed on retry"

    - scenario: S4
      step: 4
      type: fixed
      original_error: "Permission denied on files directory"
      fix_applied: "chmod -R 775 sites/default/files"

  errors_fixed: 3
  errors_pending: 0
```

### 6.2 Resume Behavior

```bash
$ pl verify --ai --resume

Resuming AI Verification from checkpoint...
═══════════════════════════════════════════════════════════════

Last run: 2026-01-17 15:12:33 (42 minutes ago)
Progress: 4/17 scenarios complete (24%)

Completed scenarios:
  ✓ S1: Foundation Setup (98% confidence)
  ✓ S2: Site Lifecycle (95% confidence)
  ✓ S3: Backup-Restore Integrity (97% confidence)
  ✓ S4: Site Copy & Clone (94% confidence)

Resuming: S5: Local Deployment Pipeline
  Current step: 6/10 - Run full test suite on staging
  Test sites preserved: verify-s5-dev, verify-s5-dev-stg

Continue? [Y/n]
```

---

## 7. Badge System

### 7.1 Three-Tier Badges with Highest Achieved

Each category displays both **current** coverage and **highest achieved** (peak) coverage:

```
┌─────────────────────────────┐ ┌─────────────────────────────┐ ┌─────────────────────────────┐
│ MACHINE                     │ │ AI                          │ │ HUMAN                       │
│ Current: 90%  █████████░    │ │ Current: 82%  ████████░░    │ │ Current: 25%  ███░░░░░░░    │
│ Peak:    92%                │ │ Peak:    82%                │ │ Peak:    31%                │
└─────────────────────────────┘ └─────────────────────────────┘ └─────────────────────────────┘
```

**Badge Behavior:**
- Peak auto-updates whenever current exceeds previous peak
- Both values displayed for easy comparison

### 7.2 Peak History Storage

Peak values are stored in `.verification-peaks.yml`:

```yaml
# .verification-peaks.yml
# Auto-updated by pl verify - DO NOT EDIT MANUALLY

peaks:
  machine:
    coverage: 92
    achieved_at: "2026-01-15T14:32:00+11:00"
    run_id: "verify-20260115-143200"
    items_verified: 529

  ai:
    coverage: 82
    achieved_at: "2026-01-17T16:45:00+11:00"
    run_id: "ai-verify-20260117-164500"
    scenarios_complete: 17
    items_verified: 471
    average_confidence: 94

  human:
    coverage: 31
    achieved_at: "2026-01-10T09:15:00+11:00"
    run_id: "manual-20260110"
    items_verified: 178

history:
  # Last 10 peak changes for trend analysis
  - type: machine
    from: 88
    to: 92
    date: "2026-01-15"

  - type: ai
    from: 75
    to: 82
    date: "2026-01-17"

  - type: human
    from: 25
    to: 31
    date: "2026-01-10"
```

### 7.3 SVG Badge Generation

Badges are generated as SVG files showing current and peak:

```yaml
badge_templates:
  # Standard badge (current only)
  standard:
    file: .verification-badges/{type}.svg
    format: "![{Type} Verified](https://img.shields.io/badge/{type}-{percent}%25-{color})"

  # Extended badge (current + peak)
  extended:
    file: .verification-badges/{type}-extended.svg
    format: |
      <svg xmlns="http://www.w3.org/2000/svg" width="140" height="40">
        <rect width="140" height="40" rx="4" fill="#555"/>
        <rect x="70" width="70" height="40" rx="4" fill="{color}"/>
        <text x="35" y="15" fill="#fff" font-size="11">{type}</text>
        <text x="105" y="15" fill="#fff" font-size="11">{current}%</text>
        <text x="35" y="30" fill="#aaa" font-size="9">Peak:</text>
        <text x="105" y="30" fill="#fff" font-size="9">{peak}%</text>
      </svg>

  colors:
    green: "#4c1"      # >= 80%
    yellow: "#dfb317"  # >= 60%
    orange: "#fe7d37"  # >= 40%
    red: "#e05d44"     # < 40%
```

### 7.4 Peak Update Logic

```yaml
peak_update_algorithm:
  on_verification_complete:
    for_each_category: [machine, ai, human]
    steps:
      - load_current_peak: peaks.{category}.coverage
      - compare: current_coverage vs current_peak

      - if: current_coverage > current_peak
        then:
          - update_peak:
              coverage: current_coverage
              achieved_at: now()
              run_id: current_run_id
          - log_history:
              type: {category}
              from: current_peak
              to: current_coverage
          - log: "New peak for {category}: {current}%"
```

### 7.5 Badge Commands

```bash
# Badge generation commands
pl verify badges                    # Generate current badges
pl verify badges --extended         # Generate badges with peak indicators
pl verify badges --history          # Show peak history
pl verify badges --reset            # Reset peaks to current (use with caution)

# Peak management
pl verify peaks                     # Show all peak values
pl verify peaks --compare           # Compare current vs peaks
pl verify peaks --trend             # Show peak trend over time
```

### 7.6 README Badge Integration

Recommended README.md badge display:

```markdown
## Verification Status

<!-- Current Coverage -->
![Machine](https://img.shields.io/badge/machine-90%25-green)
![AI](https://img.shields.io/badge/AI-82%25-green)
![Human](https://img.shields.io/badge/human-25%25-orange)

<!-- Peak Coverage -->
![Machine Peak](https://img.shields.io/badge/machine%20peak-92%25-blue)
![AI Peak](https://img.shields.io/badge/AI%20peak-82%25-blue)
![Human Peak](https://img.shields.io/badge/human%20peak-31%25-blue)

<!-- Combined Badge (if supported) -->
![Verification](/.verification-badges/combined-extended.svg)
```

### 7.7 Updated Statistics with Peaks

```yaml
statistics:
  total_items: 575

  machine:
    current:
      verified: 517
      coverage: 90%
    peak:
      verified: 529
      coverage: 92%
      achieved_at: "2026-01-15"

  ai:
    current:
      scenarios_complete: 17
      scenarios_total: 17
      items_verified: 471
      coverage: 82%
      average_confidence: 94%
    peak:
      coverage: 82%
      achieved_at: "2026-01-17"

  human:
    current:
      verified: 144
      coverage: 25%
    peak:
      verified: 178
      coverage: 31%
      achieved_at: "2026-01-10"

  overall:
    current_combined: 66%  # weighted average
    peak_combined: 68%
    fully_verified: 128
    fully_verified_percent: 22%
```

---

## 8. Command Interface

```bash
# Run AI verification scenarios
pl verify --ai                        # Run all scenarios in order
pl verify --ai --scenario=S3          # Run specific scenario
pl verify --ai --from=S5              # Start from scenario S5
pl verify --ai --resume               # Continue from checkpoint

# Control flags
pl verify --ai --fix                  # Auto-fix errors
pl verify --ai --fix --force          # Fix without confirmation
pl verify --ai --verbose              # Detailed output
pl verify --ai --dry-run              # Show plan without executing

# Reporting
pl verify --ai --report               # Generate detailed report
pl verify --ai --findings             # Show errors found/fixed
pl verify --ai --coverage             # Show coverage by scenario

# Scenario analysis
pl verify --scenarios                 # List all scenarios
pl verify --scenario-deps             # Show dependency graph
pl verify --scenario-items S3         # Show items covered by S3
```

---

## 9. Implementation Plan

### Phase 1: Scenario Framework (Week 1-2) - COMPLETE
- [x] Design scenario YAML schema
- [x] Implement scenario parser
- [x] Build dependency resolver
- [x] Create checkpoint system
- [x] Create all 17 scenario YAML files (S01-S17)

### Phase 2: Database Verification (Week 2-3)
- [ ] Implement baseline capture
- [ ] Build comparison engine
- [ ] Add drush query integration
- [ ] Create integrity validators

### Phase 3: Behat Integration (Week 3-4)
- [ ] Integrate Behat test runner
- [ ] Map scenarios to Behat features
- [ ] Implement failure capture
- [ ] Build retry logic

### Phase 4: Auto-Fix Engine (Week 4-5)
- [ ] Implement pattern matching
- [ ] Build fix execution engine
- [ ] Add fix verification
- [ ] Create fix logging

### Phase 5: Progressive Execution (Week 5-6)
- [ ] Implement checkpointing
- [ ] Build resume logic
- [ ] Add test site preservation
- [ ] Create progress reporting

### Phase 6: Reporting & Badges (Week 6-8)
- [ ] Update badge generation for current coverage
- [ ] Create scenario reports
- [ ] Build findings export
- [ ] Integration testing

### Phase 7: Peak Badge System (Week 7-8)
- [ ] Create `.verification-peaks.yml` schema and parser
- [ ] Implement peak comparison logic (current vs historical)
- [ ] Add peak update algorithm (auto-update on new peak)
- [ ] Generate extended SVG badges showing current and peak
- [ ] Add `pl verify peaks` command
- [ ] Add `pl verify badges --extended` command
- [ ] Track peak history (last 10 changes)
- [ ] Add README badge integration templates

---

## 10. Success Metrics

| Metric | Current | Target |
|--------|---------|--------|
| Machine Coverage | 42% | 90% |
| AI Coverage | 0% | 82% |
| Scenarios Complete | 0/17 | 17/17 |
| Commands Covered | 0/48 | 48/48 |
| Bugs Found | 0 | 50+ |
| Auto-Fixed Issues | 0 | 40+ |
| Average Confidence | N/A | >90% |
| Full Run Time | N/A | <90 min |
| Peak Tracking | No | Yes |

---

## 11. Example Full Run

```bash
$ pl verify --ai --fix

AI Deep Verification
═══════════════════════════════════════════════════════════════

Scenario Execution Order (17 scenarios, 48 commands):
  S1 → S2 → S3 → S4 → S5 → S6 → S7 → S8 → S9 → S10 → S11 → S12 → S13 → S14 → S15 → S16 → S17

[S1/17] Foundation Setup (23 items)
  ├─ Verifying Docker installation... ✓
  ├─ Verifying DDEV installation... ✓
  ├─ Running pl doctor... ✓
  └─ Confidence: 98%

[S2/17] Site Lifecycle (31 items)
  ├─ Installing test site... ✓
  ├─ Capturing baseline: 1 user, 0 nodes
  ├─ Verifying pl status accuracy... ✓
  ├─ Testing site deletion... ✓
  └─ Confidence: 96%

[S3/17] Backup-Restore Integrity (47 items)
  ├─ Setting up site with test content...
  │   ├─ Created 3 test users
  │   └─ Created 2 test articles
  ├─ Baseline: 4 users, 2 nodes, 12.3 MB database
  ├─ Creating backup... ✓
  ├─ Verifying backup structure... ✓
  ├─ Restoring to new site... ✓
  ├─ Verifying user count: 4 = 4 ✓
  ├─ Verifying node count: 2 = 2 ✓
  ├─ Verifying pl status metrics... ✓
  ├─ Running Behat smoke tests...
  │   ├─ 12 scenarios passed
  │   └─ 0 failures
  └─ Confidence: 97%

[S4/17] Site Copy & Clone (28 items)
  ├─ Copying site... ✓
  ├─ ⚠ Warning: Permission denied on files directory
  │   └─ Auto-fix applied: chmod -R 775
  ├─ Verifying copy integrity... ✓
  └─ Confidence: 94%

[S8/17] Quality Assurance Suite (38 items)
  ├─ Running test suite... ✓
  ├─ Running testos checks... ✓
  ├─ Running SEO checks... ✓
  ├─ Generating badges... ✓
  └─ Confidence: 95%

[S10/17] Full Production Pipeline (56 items)
  ├─ Testing stg2live deployment... ✓
  ├─ Testing live2stg sync... ✓
  ├─ Testing live2prod workflow... ✓
  ├─ Testing prod2stg sync... ✓
  ├─ Testing stg2prod deployment... ✓
  └─ Confidence: 93%

[S13/17] Developer Environment (28 items)
  ├─ Bootstrapping coder... ✓
  ├─ Setting up coder for site... ✓
  ├─ Running coders analysis... ✓
  ├─ Testing contribution workflow... ✓
  └─ Confidence: 96%

[S14/17] Infrastructure & Communication (24 items)
  ├─ Testing SSH setup... ✓
  ├─ Testing email configuration... ✓
  ├─ Testing storage management... ✓
  ├─ Testing scheduling system... ✓
  └─ Confidence: 94%

... (S5, S6, S7, S9, S11, S12, S15, S16, S17 also complete)

═══════════════════════════════════════════════════════════════
                    VERIFICATION COMPLETE
═══════════════════════════════════════════════════════════════

Scenarios: 17/17 passed
Commands: 48/48 covered
Items Verified: 471
Errors Found: 28
Errors Fixed: 24 (4 require human review)
Average Confidence: 95.2%
Duration: 73 minutes

Coverage Summary:
┌───────────────────────────────────┐
│  Category │ Current │ Peak       │
├───────────┼─────────┼────────────┤
│  Machine  │   90%   │   92%      │
│  AI       │   82%   │   82%      │
│  Human    │   25%   │   31%      │
└───────────────────────────────────┘

Coverage Badges:
  Machine: 90% ████████░░  (peak: 92%)
  AI:      82% ████████░░  (peak: 82%)
  Human:   25% ███░░░░░░░  (peak: 31%)

Peak history updated: .verification-peaks.yml
Findings exported to: .verification-findings-20260117.json
Badges generated: .verification-badges/
```

---

## 13. Ongoing Implementation

This section tracks implementation progress and provides instructions for continuing work when resuming with "implement P51".

### 13.1 Current Status

**Last Updated:** 2026-01-17

| Phase | Status | Progress | Notes |
|-------|--------|----------|-------|
| Phase 1: Scenario Framework | COMPLETE | 5/5 | All 17 scenario files created, framework working |
| Phase 2: Database Verification | NOT STARTED | 0/4 | Depends on Phase 1 |
| Phase 3: Behat Integration | NOT STARTED | 0/4 | Depends on Phase 2 |
| Phase 4: Auto-Fix Engine | NOT STARTED | 0/4 | Depends on Phase 3 |
| Phase 5: Progressive Execution | NOT STARTED | 0/4 | Depends on Phase 4 |
| Phase 6: Reporting & Badges | NOT STARTED | 0/4 | Depends on Phase 5 |
| Phase 7: Peak Badge System | NOT STARTED | 0/8 | Can parallel with Phase 6 |

**Overall Progress:** 5/32 tasks (16%)

### 13.2 Implementation Process

When continuing P51 implementation, follow this process:

#### Step 1: Check Current Phase

Review the status table above to identify the current phase. Each phase must complete before the next begins (except Phase 7 which can parallel Phase 6).

#### Step 2: Identify Next Task

Within the current phase, find the first unchecked item in Section 9 (Implementation Plan). Tasks should be completed in order.

#### Step 3: Implementation Pattern

For each task:

1. **Create the file/function** in the appropriate location:
   - Scenario framework → `lib/verify-scenarios.sh`
   - Cross-validation → `lib/verify-cross-validate.sh`
   - Auto-fix → `lib/verify-autofix.sh`
   - CLI integration → `scripts/commands/verify.sh`

2. **Follow existing patterns** from P50's verify system:
   ```bash
   # Source existing infrastructure
   source lib/verify-runner.sh
   source lib/verify-scenarios.sh  # New for P51
   ```

3. **Test the implementation**:
   ```bash
   # Syntax check
   bash -n lib/NEW_FILE.sh

   # Function exists
   source lib/NEW_FILE.sh && type FUNCTION_NAME

   # Basic execution
   pl verify --ai --dry-run
   ```

4. **Update this tracking section** after completing each task.

#### Step 4: Mark Progress

After completing a task:

1. Check the box in Section 9 (change `- [ ]` to `- [x]`)
2. Update the phase progress in Section 13.1
3. Update the "Last Updated" date
4. Update the header instruction's current phase if phase completed

#### Step 5: Commit Changes

```bash
git add lib/verify-*.sh scripts/commands/verify.sh docs/proposals/P51-*.md
git commit -m "P51 Phase X: [description of completed task]"
```

### 13.3 File Structure

P51 implementation should create these files:

```
lib/
├── verify-scenarios.sh      # Scenario parser and executor (Phase 1)
├── verify-cross-validate.sh # Live state cross-validation (Phase 2)
├── verify-behat.sh          # Behat integration (Phase 3)
├── verify-autofix.sh        # Auto-fix engine (Phase 4)
├── verify-checkpoint.sh     # Checkpoint/resume system (Phase 5)
└── verify-badges-ai.sh      # AI badge generation (Phase 6-7)

scripts/commands/
└── verify.sh                # Add --ai flag support

.verification-scenarios/
├── S01-foundation.yml       # Scenario definitions
├── S02-lifecycle.yml
├── ...
└── S17-upstream.yml
```

### 13.4 Phase Completion Criteria

#### Phase 1: Scenario Framework - COMPLETE when:
- [x] `lib/verify-scenarios.sh` exists and passes `bash -n`
- [x] Scenario YAML schema documented in code comments
- [x] `parse_scenario()` function works on S01
- [x] `resolve_dependencies()` orders S1→S17 correctly
- [x] Basic checkpoint file created/read works

#### Phase 2: Database Verification - COMPLETE when:
- [ ] `lib/verify-cross-validate.sh` exists
- [ ] `capture_baseline()` stores user/node counts
- [ ] `compare_values()` with tolerance works
- [ ] All 9 live state commands have working cross-validation
- [ ] Mismatch detection logs errors correctly

#### Phase 3: Behat Integration - COMPLETE when:
- [ ] `lib/verify-behat.sh` exists
- [ ] Can run Behat smoke tests on a site
- [ ] Failure output captured to findings
- [ ] Retry logic handles flaky tests
- [ ] Screenshots saved on failure

#### Phase 4: Auto-Fix Engine - COMPLETE when:
- [ ] `lib/verify-autofix.sh` exists
- [ ] Pattern matching identifies common errors
- [ ] Fix execution runs appropriate commands
- [ ] Fix verification confirms resolution
- [ ] All fixes logged with before/after state

#### Phase 5: Progressive Execution - COMPLETE when:
- [ ] `lib/verify-checkpoint.sh` exists
- [ ] `.verification-checkpoint.yml` created during runs
- [ ] `--resume` flag continues from checkpoint
- [ ] Test sites preserved between runs
- [ ] Progress percentage calculated correctly

#### Phase 6: Reporting & Badges - COMPLETE when:
- [ ] AI coverage badge generated
- [ ] Scenario completion report created
- [ ] Findings exported to JSON
- [ ] `pl verify --ai` runs end-to-end
- [ ] Integration test passes all 17 scenarios

#### Phase 7: Peak Badge System - COMPLETE when:
- [ ] `.verification-peaks.yml` schema implemented
- [ ] Peak comparison detects new highs
- [ ] Extended badges show current + peak
- [ ] `pl verify peaks` command works
- [ ] Peak history tracks last 10 changes

### 13.5 Completed Items

| Date | Phase | Task | Commit |
|------|-------|------|--------|
| 2026-01-17 | Pre-work | Full proposal with cross-validation specs | ceae26b6 |
| 2026-01-17 | Phase 1 | Created `lib/verify-scenarios.sh` (1239 lines) | (pending) |
| 2026-01-17 | Phase 1 | Created all 17 scenario YAML files (S01-S17) | (pending) |
| 2026-01-17 | Phase 1 | Integrated `--ai` flag into verify.sh | (pending) |
| 2026-01-17 | Phase 1 | Tested S1 Foundation scenario (100% confidence) | (pending) |

### 13.6 Known Dependencies

Before starting implementation:

1. **P50 must be working** - `pl verify --run` should execute successfully
2. **DDEV available** - Scenarios create test sites using DDEV
3. **Behat installed** - Phase 3 requires Behat for functional tests
4. **yq installed** - YAML parsing for scenario files

Check dependencies:
```bash
pl verify --run --depth=basic  # P50 works
ddev version                    # DDEV available
which yq || pip install yq      # yq for YAML
```

### 13.7 Quick Start for New Session

When starting a new "implement P51" session:

```bash
# 1. Check current status
head -20 docs/proposals/P51-ai-powered-verification.md | grep "Current phase"

# 2. Find next task
grep -A5 "NOT STARTED\|IN PROGRESS" docs/proposals/P51-ai-powered-verification.md | head -10

# 3. Review the phase requirements
grep -A10 "Phase [X]:.*COMPLETE when" docs/proposals/P51-ai-powered-verification.md

# 4. Start implementing
# ... follow Step 3 above ...
```

---

## 14. Approval

| Role | Name | Date | Signature |
|------|------|------|-----------|
| Author | Claude Opus 4.5 | 2026-01-17 | |
| Requirements | Rob | 2026-01-17 | |
| Reviewer | | | |
| Approver | | | |

---

**End of Proposal**
