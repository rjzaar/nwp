# P50: Unified Verification System

**Status:** IMPLEMENTED - COVERAGE ONGOING (42% → 85% target)
**Created:** 2026-01-16
**Updated:** 2026-01-17
**Implemented:** 2026-01-17
**Author:** Claude Opus 4.5 (architectural design), Rob (requirements)
**Priority:** High
**Estimated Effort:** 8-10 weeks (completed)
**Breaking Changes:** Yes - test-nwp.sh removed (redirects to verify --run)

---

> **"Implement P50" means:** The verification system is built. Continue adding machine checks to increase coverage from 42% to 85%. See **Section 14: Ongoing Coverage Improvement** for the systematic process.

---

## 1. Executive Summary

### 1.1 Problem Statement

NWP has two disconnected verification systems that duplicate effort and create confusion:

| System | Lines | Purpose | State |
|--------|-------|---------|-------|
| **test-nwp.sh** | 1,465 | Automated testing | 251 tests, 98%+ pass rate |
| **.verification.yml** | 11,692 | Manual checklist | 553 items, 1.3% complete |

**Key issues:**
- 55% of verification items have no automated test
- Test results don't update verification status
- Two systems to maintain, neither complete
- No visibility (badges) into verification coverage

### 1.2 Proposed Solution

**Unify into a single system** where:
- **.verification.yml** becomes the single source of truth (571 items with embedded machine checks)
- **verify.sh** gains execution capabilities (replaces test-nwp.sh entirely)
- **test-nwp.sh** is removed (clean break, no wrapper)
- **Layered verification** adds human trust on top of machine testing
- **Badges** show verification status via Shields.io dynamic badges
- **CI/CD integration** runs verification on every push, updates badges automatically

### 1.3 Key Benefits

| Benefit | Before | After |
|---------|--------|-------|
| Source of truth | 2 systems | 1 system |
| Test definitions | Bash code (hard to audit) | Declarative YAML |
| Adding new tests | Edit 2 files | Edit 1 file |
| Visibility | None | Badges on repo |
| Human verification | Manual tracking only | Auto-logged from usage |

### 1.4 Breaking Changes

| Change | Impact | Mitigation |
|--------|--------|------------|
| `pl test-nwp` removed | Users must use new command | New `pl verify --run` command |
| test-nwp.sh deleted | 262 references need updating | Search/replace with verify --run |
| CLAUDE.md release process | Uses new command | Update documentation |
| CI/CD integration | New verification stage | GitLab CI configuration provided |
| 4+ docs reference test-nwp | Documentation outdated | Update all references |

---

## 2. Architecture

### 2.1 Unified System Design

```
┌─────────────────────────────────────────────────────────────────┐
│                    .verification.yml (v3)                        │
│                   SINGLE SOURCE OF TRUTH                         │
│                                                                  │
│  571 items = 553 existing + 18 security validation items         │
│  Each item has:                                                  │
│    - machine.checks (basic/standard/thorough/paranoid)          │
│    - human.prompts (for manual verification)                    │
│    - auto_log triggers (commands that verify this item)         │
│    - affected_files (for smart invalidation)                    │
└──────────────────────────────┬───────────────────────────────────┘
                               │
            ┌──────────────────┴──────────────────┐
            ▼                                     ▼
┌───────────────────────────┐       ┌───────────────────────────┐
│   pl verify --run         │       │   pl verify (TUI)         │
│   MACHINE EXECUTION       │       │   HUMAN VERIFICATION      │
│                           │       │                           │
│ - Creates test sites      │       │ - Interactive prompts     │
│ - Runs machine checks     │       │ - Auto-log from usage     │
│ - Captures results        │       │ - Error reporting         │
│ - Updates .verification   │       │ - Manual confirmation     │
│ - Generates badges        │       │                           │
└───────────────────────────┘       └───────────────────────────┘
            │                                     │
            └──────────────────┬──────────────────┘
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│                      lib/verify-runner.sh                        │
│                   SHARED TEST INFRASTRUCTURE                     │
│                                                                  │
│  Preserved from test-nwp.sh:                                    │
│  - site_exists(), site_is_running(), drush_works()              │
│  - run_test() execution framework                               │
│  - 5-layer YAML protection for cleanup                          │
│  - Atomic file operations                                       │
│  - Logging system                                               │
└─────────────────────────────────────────────────────────────────┘
```

### 2.2 Verification Ladder

```
┌─────────────────────────────────────────────────────────────────┐
│                    FULLY VERIFIED ★★★                            │
│        Machine tests pass AND human confirmed in practice        │
│                   (highest trust, green badge)                   │
├─────────────────────────────────────────────────────────────────┤
│                   MACHINE VERIFIED ★★                            │
│          Automated tests pass at specified depth                 │
│          (basic → standard → thorough → paranoid)                │
├─────────────────────────────────────────────────────────────────┤
│                       UNTESTED ★                                 │
│                 No verification performed                        │
│                  (red badge, needs work)                         │
└─────────────────────────────────────────────────────────────────┘
```

### 2.3 Depth Levels

| Level | Time/Item | Checks | Use Case |
|-------|-----------|--------|----------|
| **basic** | 5-10s | Command exits 0 | During development |
| **standard** | 10-20s | + Output valid, files created | Pre-commit hook |
| **thorough** | 20-40s | + State verified, dependencies OK | Pre-push hook |
| **paranoid** | 1-5min | + Round-trip test, full integration | Pre-release |

---

## 3. Impact Analysis

### 3.1 Files Requiring Updates

#### Critical (Blocking)

| File | Current Reference | Required Change |
|------|-------------------|-----------------|
| `CLAUDE.md:216-217` | `./scripts/commands/test-nwp.sh` | Change to `pl verify --run --all --depth=thorough` |
| `pl:618-620` | `test-nwp)` case statement | Add `verify --run` handling, deprecate test-nwp |
| `docs/decisions/0009-five-layer-yaml-protection.md` | test-nwp.sh cleanup | Update to reference lib/verify-runner.sh |

#### Documentation Updates

| File | Lines | Change Required |
|------|-------|-----------------|
| `docs/reference/commands/test-nwp.md` | All 500 | Rewrite as verify.md or mark deprecated |
| `docs/guides/setup.md` | 355 | Update command reference table |
| `docs/deployment/ssh-setup.md` | 117, 191 | Update test procedure |
| `docs/SECURITY.md` | 406, 411, 502 | Update incident reference |
| `docs/YAML_API.md` | 714 | Update example command |
| `docs/decisions/0006-contribution-workflow.md` | 190 | Update dependency |
| `CHANGELOG.md` | New entry | Document breaking change |

### 3.2 Preserved Infrastructure

The following must be preserved from test-nwp.sh:

#### Helper Functions (Extract to lib/verify-runner.sh)

```bash
# Site query functions
site_exists()           # Check site directory + DDEV config
site_is_running()       # Check if DDEV service active
drush_works()           # Check Drupal + 3-attempt retry logic
backup_exists()         # Check backup directory has files

# Execution framework
run_test()              # Execute command with result tracking
track_result()          # Record pass/warn/fail status

# YAML manipulation (5-layer protection)
atomic_yaml_update()    # Safe YAML field updates
yaml_remove_section()   # Remove named YAML blocks with validation

# Logging
init_log_file()         # Create timestamped log in .logs/
log_test_result()       # Record result with timestamp
```

#### 5-Layer YAML Protection (CRITICAL)

This protection was added after the January 2026 data loss incident (ADR-0009):

```bash
# MUST be preserved in lib/verify-runner.sh
atomic_yaml_cleanup() {
    local file="$1"
    local pattern="$2"

    # Layer 1: Store original line count
    local original_lines=$(wc -l < "$file")

    # Layer 2: Use mktemp for atomic write
    local tmpfile=$(mktemp "${file}.XXXXXX")

    # Layer 3: Perform AWK operation
    awk "$pattern" "$file" > "$tmpfile"

    # Layer 4: Validate output not empty
    if [ ! -s "$tmpfile" ]; then
        rm -f "$tmpfile"
        return 1
    fi

    # Layer 5: Check reasonable line count
    local new_lines=$(wc -l < "$tmpfile")
    if [ "$new_lines" -lt $((original_lines - 100)) ]; then
        rm -f "$tmpfile"
        return 1
    fi

    # Layer 6: Atomic move
    mv "$tmpfile" "$file"
}
```

### 3.3 Test Categories to Migrate

All 23 test-nwp.sh categories become verification features:

| test-nwp.sh Category | Verification Feature | Items |
|---------------------|---------------------|-------|
| Test 1: Installation | install | 24 |
| Test 2: Backup | backup | 8 |
| Test 3: Restore | restore | 6 |
| Test 3b: Database restore | restore | (included) |
| Test 4: Copy | copy | 6 |
| Test 5: Dev/Prod mode | make | 6 |
| Test 6: Deployment | dev2stg | 19 |
| Test 8: Site verification | status | 5 |
| Test 8b: Delete | delete | 7 |
| Test 9: Script validation | (syntax checks) | Move to CI |
| Test 10: stg2prod/prod2stg | stg2prod, prod2stg | 8 |
| Test 11: YAML library | lib_yaml_write | 4 |
| Test 12: Linode infrastructure | linode_integration | 6 |
| Test 13: Input validation | **NEW: security_validation** | 18 |
| Test 14: Git backup | git_backup | 5 |
| Test 15: Scheduling | schedule | 4 |
| Tests 16-21: CI/CD features | Various lib_* features | 30+ |
| Test 22: Syntax validation | Move to pre-commit hook | - |
| Test 22b: Library functions | lib_* features | (included) |
| Test 23: Podcast | podcast | 4 |

---

## 4. Schema v3 Specification

### 4.1 Complete Item Schema

```yaml
version: 3

# Global configuration
config:
  machine_engine: "verify.sh"          # Replaces test-nwp.sh
  human_logging: true
  badges_enabled: true

  # Test site configuration
  test_site:
    prefix: "verify-test"              # Replaces test-nwp prefix
    cleanup_on_success: true
    preserve_on_failure: true

  # Depth level definitions
  depth_levels:
    basic:
      description: "Command succeeds"
      typical_time: 10
    standard:
      description: "Output valid, files created"
      typical_time: 20
    thorough:
      description: "State verified, dependencies OK"
      typical_time: 40
    paranoid:
      description: "Round-trip test, integration"
      typical_time: 120

# Aggregate statistics (auto-calculated)
statistics:
  total_items: 571
  machine:
    verified: 0
    coverage_percent: 0.0
    by_depth:
      basic: 0
      standard: 0
      thorough: 0
      paranoid: 0
  human:
    verified: 7
    coverage_percent: 1.2
  fully_verified: 0
  issues:
    open: 0
    resolved: 0

# Feature definitions
features:
  backup:
    name: "Backup Script"
    description: "Site backup functionality"
    files:
      - scripts/commands/backup.sh
      - lib/sanitize.sh
      - lib/git.sh
    file_hash: "sha256:..."

    # Feature-level summary (auto-calculated)
    summary:
      total_items: 8
      machine_verified: 0
      human_verified: 2
      fully_verified: 0

    checklist:
      - id: "backup_0"
        text: "Full backup creates valid archive"

        # Smart invalidation
        affected_files:
          - path: scripts/commands/backup.sh
            lines: "257-380"
            functions: ["backup_site", "backup_database"]
        item_hash: "sha256:..."

        # Machine verification checks
        machine:
          automatable: true
          checks:
            basic:
              commands:
                - cmd: "pl backup {site}"
                  expect_exit: 0
                  timeout: 60
            standard:
              commands:
                - cmd: "pl backup {site}"
                  expect_exit: 0
                - cmd: "test -f ~/nwp/sitebackups/{site}/*.sql.gz"
                  expect_exit: 0
            thorough:
              commands:
                - cmd: "pl backup {site}"
                  expect_exit: 0
                - cmd: "gunzip -t ~/nwp/sitebackups/{site}/*.sql.gz"
                  expect_exit: 0
            paranoid:
              commands:
                - cmd: "pl backup {site} -f"
                  expect_exit: 0
                - cmd: "pl delete -fy {site}"
                  expect_exit: 0
                - cmd: "pl restore -fy {site}"
                  expect_exit: 0
                - cmd: "pl status {site}"
                  expect_exit: 0

          # Execution state
          state:
            verified: false
            verified_at: null
            depth: null
            duration_seconds: null
            last_output: null

        # Human verification
        human:
          auto_loggable: true
          trigger_commands:
            - pattern: "pl backup *"
              confidence: 1.0
          prompts:
            - "Does the backup complete without errors?"
            - "Is the backup file size reasonable?"

          # Human verification state
          state:
            verified: false
            verified_at: null
            by: null
            type: null  # auto-logged | manual
            context: null

        # Original fields preserved
        how_to_verify: |
          1. Create a test site
          2. Run: pl backup testsite
          3. Verify backup file exists in sitebackups/
        related_docs:
          - docs/reference/commands/backup.md

        # Dependencies
        depends_on:
          - feature: install
            item: "install_0"

        # Combined status
        status: "untested"  # untested | machine-only | fully-verified | invalidated

        # Issue tracking
        issues: []

        # History
        history: []

  # NEW: Security validation feature (from test-nwp.sh Test 13)
  security_validation:
    name: "Input Validation & Security"
    description: "Security tests for command injection, path traversal, and input validation"
    files:
      - scripts/commands/install.sh
      - scripts/commands/backup.sh
      - scripts/commands/delete.sh

    checklist:
      - id: "security_0"
        text: "Reject path traversal attempts (../)"
        machine:
          automatable: true
          checks:
            basic:
              commands:
                - cmd: "! pl install d '../malicious' 2>/dev/null"
                  expect_exit: 0
                  description: "Path traversal should be rejected"
        human:
          auto_loggable: false
          prompts:
            - "Verify error message is clear about why path was rejected"

      - id: "security_1"
        text: "Reject command injection attempts (;)"
        machine:
          automatable: true
          checks:
            basic:
              commands:
                - cmd: "! pl install d 'test;rm -rf /' 2>/dev/null"
                  expect_exit: 0

      # ... 16 more security items
```

### 4.2 New Fields Summary

| Field | Location | Purpose |
|-------|----------|---------|
| `config.test_site` | Root | Test site naming and lifecycle |
| `machine.checks.{depth}` | Item | Commands for each depth level |
| `machine.state` | Item | Execution results |
| `human.auto_loggable` | Item | Can auto-log from usage |
| `human.trigger_commands` | Item | Commands that verify this item |
| `human.state` | Item | Human verification state |
| `status` | Item | Combined machine+human status |
| `issues` | Item | Linked error reports |

---

## 5. Command Interface

### 5.1 New Commands

```bash
# Machine execution (replaces test-nwp.sh)
pl verify --run                      # Run all machine-verifiable items
pl verify --run --depth=basic        # Quick check (5-10s/item)
pl verify --run --depth=paranoid     # Full integration test
pl verify --run --feature=backup     # Test specific feature
pl verify --run --affected           # Only items affected by recent changes

# CI/CD mode (new)
pl verify ci                         # Machine checks with JUnit XML output
pl verify ci --export-json           # Generate .badges.json for Shields.io
pl verify ci --depth=standard        # CI-specific depth

# Human verification (existing, enhanced)
pl verify                            # Interactive TUI
pl verify status                     # Show coverage summary
pl verify report                     # Generate full report

# Badge generation (new)
pl verify badges                     # Generate badge URLs
pl verify badges --update-readme     # Update README.md with badges

# Issue management (new)
pl verify issues                     # List open issues
pl verify issues --resolve ID        # Mark issue resolved
```

### 5.2 Command Mapping (Migration Guide)

| Old Command | New Command | Notes |
|-------------|-------------|-------|
| `pl test-nwp` | `pl verify --run --all` | Full test suite |
| `./scripts/commands/test-nwp.sh` | `pl verify --run --all` | Direct script call |
| Test in CI | `pl verify ci --depth=standard` | With JUnit output |
| Pre-release check | `pl verify --run --depth=thorough` | Matches old 98%+ target |

---

## 6. Execution Engine

### 6.1 Test Site Lifecycle

```bash
# In lib/verify-runner.sh

create_test_site() {
    local prefix="${1:-verify-test}"
    local recipe="${2:-d}"

    # Pre-configure DDEV hostnames (prevents sudo prompts)
    sudo ddev hostname "${prefix}.ddev.site" 127.0.0.1

    # Create site using install.sh
    ./scripts/commands/install.sh "$recipe" "$prefix" --auto

    # Verify site is running
    if ! site_is_running "$prefix"; then
        return 1
    fi

    echo "$prefix"
}

cleanup_test_site() {
    local prefix="$1"
    local preserve_on_failure="${2:-false}"

    # Stop DDEV
    (cd "sites/$prefix" && ddev stop) 2>/dev/null || true

    # Remove directories (with safety checks)
    if [ "$preserve_on_failure" != "true" ]; then
        rm -rf "sites/${prefix}"
        rm -rf "sitebackups/${prefix}"
    fi

    # Clean nwp.yml entry (with 5-layer protection)
    atomic_yaml_cleanup "nwp.yml" "/^  ${prefix}:/,/^  [a-z]/{/^  ${prefix}:/d;/^  [a-z]/!d}"
}
```

### 6.2 Command Execution with Timeout

```bash
execute_check() {
    local command="$1"
    local expect_exit="${2:-0}"
    local timeout_secs="${3:-60}"
    local site="$4"

    # Variable substitution
    command="${command//\{site\}/$site}"

    # Execute with timeout
    local start_time=$(date +%s.%N)
    local output
    local exit_code

    output=$(timeout "$timeout_secs" bash -c "$command" 2>&1)
    exit_code=$?

    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc)

    # Handle timeout
    if [ "$exit_code" = "124" ]; then
        echo "TIMEOUT after ${timeout_secs}s"
        return 124
    fi

    # Check expected exit code
    if [ "$exit_code" = "$expect_exit" ]; then
        return 0
    else
        echo "$output"
        return 1
    fi
}
```

### 6.3 Feature Execution

```bash
execute_feature() {
    local feature_id="$1"
    local depth="${2:-standard}"
    local site="$3"

    local items=$(get_feature_items "$feature_id")
    local passed=0
    local failed=0

    for item_id in $items; do
        if execute_item "$feature_id" "$item_id" "$depth" "$site"; then
            ((passed++))
            update_item_status "$feature_id" "$item_id" "machine" "verified" "$depth"
        else
            ((failed++))
            update_item_status "$feature_id" "$item_id" "machine" "failed" "$depth"
        fi
    done

    # Update feature summary
    update_feature_summary "$feature_id"

    if [ "$failed" -eq 0 ]; then
        return 0
    else
        return 1
    fi
}
```

---

## 7. Human Verification

### 7.1 Auto-Logging

When a user runs a command successfully with consent enabled:

```bash
# Hook in pl script (after command execution)
log_verification_if_enabled() {
    local command="$1"
    local exit_code="$2"

    # Check consent
    if ! verification_consent_enabled; then
        return
    fi

    # Only log successes
    if [ "$exit_code" != "0" ]; then
        return
    fi

    # Find matching verification items
    local items=$(find_items_for_command "$command")

    for item in $items; do
        update_human_verification "$item" "auto-logged" "$command"
    done
}
```

### 7.2 Consent Configuration

```yaml
# In nwp.yml
settings:
  verification:
    enabled: true

    consent:
      agreed: true
      agreed_at: "2026-01-16T10:00:00Z"
      agreed_by: "rob"

    auto_log:
      enabled: true
      events:
        command_success: true
        site_operations: true
        data_operations: true

    error_reporting:
      enabled: true
      prompt_on_failure: true
```

### 7.3 Error Reporting

```bash
# After command failure
prompt_error_report() {
    local command="$1"
    local error_msg="$2"
    local exit_code="$3"

    if ! error_reporting_enabled; then
        return
    fi

    echo ""
    echo "Something went wrong. Would you like to report this issue?"
    echo "[Y] Report  [n] Skip  [?] What gets reported"
    read -r response

    case "$response" in
        Y|y|"")
            create_error_report "$command" "$error_msg" "$exit_code"
            ;;
    esac
}
```

---

## 8. Badge System

### 8.1 Cross-Platform Badge Strategy

Badges must work on both git.nwpcode.org (GitLab) AND github.com/rjzaar/nwp (mirror).

**Challenge:** GitLab pipeline badges don't work on GitHub because:
- GitHub can't fetch from external GitLab instances
- Self-hosted GitLab may require authentication

**Solution:** Shields.io dynamic badges with `.badges.json` (implements F08 proposal)

```
┌──────────────────────────────────────────────────────────────┐
│                    BADGE ARCHITECTURE                         │
│                                                               │
│  GitLab CI runs → verify.sh ci → generates .badges.json      │
│                              │                                │
│                              ↓                                │
│  Commits .badges.json → push to repo → mirrors to GitHub     │
│                              │                                │
│                              ↓                                │
│  README.md uses → Shields.io dynamic badge URLs              │
│                              │                                │
│                              ↓                                │
│  Shields.io fetches → raw.githubusercontent.com/.badges.json │
│                              │                                │
│                              ↓                                │
│  Badges visible → on BOTH GitLab AND GitHub                  │
└──────────────────────────────────────────────────────────────┘
```

### 8.2 .badges.json Schema

```json
{
  "version": 1,
  "schemaVersion": 1,
  "generated": "2026-01-16T10:30:00Z",
  "pipeline": {
    "id": "123456",
    "ref": "main",
    "sha": "abc123def"
  },
  "badges": {
    "verification_machine": {
      "label": "Machine Verified",
      "message": "571/571 (100%)",
      "color": "brightgreen"
    },
    "verification_human": {
      "label": "Human Verified",
      "message": "423/571 (74%)",
      "color": "yellow"
    },
    "verification_full": {
      "label": "Fully Verified",
      "message": "398/571 (70%)",
      "color": "green"
    },
    "issues_open": {
      "label": "Issues",
      "message": "3 open",
      "color": "yellow"
    }
  }
}
```

### 8.3 Badge Types & Thresholds

| Badge | JSON Key | Calculation | Color Thresholds |
|-------|----------|-------------|------------------|
| Machine | `verification_machine` | items with machine.verified / total | <50% red, 50-80% yellow, >80% green |
| Human | `verification_human` | items with human.verified / total | <25% red, 25-60% yellow, >60% green |
| Fully Verified | `verification_full` | items with status="fully-verified" / total | <25% red, 25-60% yellow, >60% green |
| Issues | `issues_open` | count of open issues | >10 red, 1-10 yellow, 0 green |

### 8.4 README.md Badge Markup

```markdown
<!-- Works on BOTH GitLab and GitHub -->
![Machine Verified](https://img.shields.io/badge/dynamic/json?url=https://raw.githubusercontent.com/rjzaar/nwp/main/.badges.json&query=$.badges.verification_machine.message&label=Machine%20Verified&color=brightgreen&logo=checkmarx)

![Human Verified](https://img.shields.io/badge/dynamic/json?url=https://raw.githubusercontent.com/rjzaar/nwp/main/.badges.json&query=$.badges.verification_human.message&label=Human%20Verified&color=yellow&logo=statuspal)

![Fully Verified](https://img.shields.io/badge/dynamic/json?url=https://raw.githubusercontent.com/rjzaar/nwp/main/.badges.json&query=$.badges.verification_full.message&label=Fully%20Verified&color=green&logo=qualitybadge)
```

### 8.5 Badge Generation Command

```bash
# Generate .badges.json
generate_badges_json() {
    local machine_pct=$(calculate_machine_coverage)
    local human_pct=$(calculate_human_coverage)
    local verified_pct=$(calculate_full_coverage)
    local issues=$(count_open_issues)

    cat > .badges.json << EOF
{
  "version": 1,
  "schemaVersion": 1,
  "generated": "$(date -Iseconds)",
  "pipeline": {
    "id": "${CI_PIPELINE_ID:-local}",
    "ref": "${CI_COMMIT_REF_NAME:-$(git branch --show-current)}",
    "sha": "${CI_COMMIT_SHA:-$(git rev-parse HEAD)}"
  },
  "badges": {
    "verification_machine": {
      "label": "Machine Verified",
      "message": "${machine_pct}%",
      "color": "$(get_color "$machine_pct" "machine")"
    },
    "verification_human": {
      "label": "Human Verified",
      "message": "${human_pct}%",
      "color": "$(get_color "$human_pct" "human")"
    },
    "verification_full": {
      "label": "Fully Verified",
      "message": "${verified_pct}%",
      "color": "$(get_color "$verified_pct" "full")"
    },
    "issues_open": {
      "label": "Issues",
      "message": "${issues} open",
      "color": "$(get_issues_color "$issues")"
    }
  }
}
EOF
}
```

---

## 9. CI/CD Integration

### 9.1 Architecture: GitLab-Primary (Option A)

GitLab is the canonical repository; GitHub is a push mirror. All CI runs on GitLab only.

```
┌─────────────────────────────────────────────────────────────────┐
│                     CI/CD WORKFLOW                               │
│                                                                  │
│  Developer → git push → git.nwpcode.org (GitLab)                │
│                              │                                   │
│                              ├── GitLab CI runs verification     │
│                              │   └── pl verify ci --depth=std    │
│                              │                                   │
│                              ├── Generates .badges.json          │
│                              │   └── pl verify ci --export-json  │
│                              │                                   │
│                              ├── Commits .badges.json            │
│                              │   └── git commit -m "CI: badges"  │
│                              │                                   │
│                              ↓                                   │
│                    Push mirror to GitHub                         │
│                              │                                   │
│                              ↓                                   │
│                    Badges visible on BOTH platforms              │
└─────────────────────────────────────────────────────────────────┘
```

**Why GitLab-only CI:**
- Single source of truth for CI results
- No duplicate work or conflicting results
- Simpler maintenance
- GitHub Actions disabled or minimal (Dependabot only)

### 9.2 GitLab CI Configuration

Add to `.gitlab-ci.yml`:

```yaml
# Verification stage (replaces test-nwp.sh integration)
verification:
  stage: test
  image: ddev/ddev-gitpod-base:latest
  services:
    - docker:dind
  variables:
    DOCKER_HOST: tcp://docker:2375
  before_script:
    - ddev config global --instrumentation-opt-in=false
  script:
    # Run verification suite
    - ./scripts/commands/verify.sh ci --depth=standard

    # Export results
    - ./scripts/commands/verify.sh ci --export-json > .badges.json

    # Generate JUnit XML for GitLab test visualization
    - mkdir -p .logs/verification
    - ./scripts/commands/verify.sh ci --junit > .logs/verification/junit.xml
  artifacts:
    paths:
      - .badges.json
      - .logs/verification/
    reports:
      junit: .logs/verification/junit.xml
    expire_in: 30 days
  rules:
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
    - if: $CI_PIPELINE_SOURCE == "schedule"

# Update badges in repo (only on main branch)
update-badges:
  stage: deploy
  needs: [verification]
  script:
    # Configure git
    - git config user.name "GitLab CI"
    - git config user.email "ci@nwpcode.org"

    # Only update if .badges.json changed
    - |
      if git diff --quiet .badges.json 2>/dev/null; then
        echo "No badge changes, skipping commit"
      else
        git add .badges.json
        git commit -m "CI: Update verification badges [skip ci]"
        git push origin $CI_COMMIT_REF_NAME
      fi
  rules:
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
      changes:
        - .verification.yml
        - scripts/commands/verify.sh
        - lib/verify-runner.sh
  allow_failure: true
```

### 9.3 CI Mode Implementation

```bash
# In verify.sh

ci_mode() {
    local depth="${1:-standard}"
    local export_json="${2:-false}"
    local junit_output="${3:-false}"

    # Run machine checks
    run_all_checks "$depth"

    # Export results
    if [ "$export_json" = "true" ]; then
        generate_badges_json
    fi

    if [ "$junit_output" = "true" ]; then
        generate_junit_xml
    fi

    # Return exit code based on pass rate
    local pass_rate=$(calculate_pass_rate)
    if [ "$pass_rate" -lt 98 ]; then
        echo "FAIL: Pass rate ${pass_rate}% below 98% threshold"
        return 1
    fi

    echo "PASS: ${pass_rate}% pass rate"
    return 0
}

generate_junit_xml() {
    local output_file=".logs/verification/junit.xml"
    mkdir -p "$(dirname "$output_file")"

    cat > "$output_file" << 'XMLHEADER'
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
XMLHEADER

    # Generate test suites from features
    for feature in $(get_all_features); do
        local items=$(get_feature_items "$feature")
        local passed=0
        local failed=0
        local time=0

        echo "  <testsuite name=\"$feature\">" >> "$output_file"

        for item in $items; do
            local status=$(get_item_status "$feature" "$item")
            local duration=$(get_item_duration "$feature" "$item")

            if [ "$status" = "passed" ]; then
                echo "    <testcase name=\"$item\" time=\"$duration\"/>" >> "$output_file"
                ((passed++))
            else
                echo "    <testcase name=\"$item\" time=\"$duration\">" >> "$output_file"
                echo "      <failure message=\"Verification failed\"/>" >> "$output_file"
                echo "    </testcase>" >> "$output_file"
                ((failed++))
            fi
        done

        echo "  </testsuite>" >> "$output_file"
    done

    echo "</testsuites>" >> "$output_file"
}
```

### 9.4 GitHub Actions (Minimal)

Since GitLab is primary, GitHub Actions is minimal:

```yaml
# .github/workflows/build-test-deploy.yml
# MINIMAL - GitLab is primary CI, this is just for GitHub-specific features

name: GitHub Features

on:
  pull_request:
    types: [opened, synchronize]
  schedule:
    - cron: '0 6 * * 1'  # Weekly Dependabot

jobs:
  # Dependabot auto-merge for patch updates
  dependabot-auto-merge:
    runs-on: ubuntu-latest
    if: github.actor == 'dependabot[bot]'
    steps:
      - uses: dependabot/fetch-metadata@v2
      - run: gh pr merge --auto --squash "$PR_URL"
        env:
          PR_URL: ${{ github.event.pull_request.html_url }}
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}

  # Note: Main verification runs on GitLab CI
  # Badges are updated via .badges.json committed by GitLab
```

### 9.5 Files Requiring CI Updates

| File | Current State | Required Change |
|------|---------------|-----------------|
| `.gitlab-ci.yml` | 8 stages, no verification | Add verification stage |
| `.github/workflows/build-test-deploy.yml` | Full workflow | Minimize, GitLab primary |
| `scripts/commands/verify.sh` | No CI mode | Add `ci` subcommand |
| `.badges.json` | Does not exist | Auto-generated by CI |
| `README.md` | No badges | Add Shields.io badge URLs |

### 9.6 Migration Path for CI

1. **Phase 1**: Add verification stage to GitLab CI (parallel to existing)
2. **Phase 2**: Remove test-nwp.sh references from any CI scripts
3. **Phase 3**: Add badge generation and commit job
4. **Phase 4**: Minimize GitHub Actions workflow
5. **Phase 5**: Update README.md with badge URLs

---

## 10. Implementation Phases

### Phase 1: Foundation (Week 1-2)

#### 10.1.1 Objectives
- Create lib/verify-runner.sh with preserved infrastructure
- Migrate schema to v3
- Add 18 security validation items

#### 10.1.2 Deliverables

| Deliverable | Description |
|-------------|-------------|
| `lib/verify-runner.sh` | Extracted test infrastructure from test-nwp.sh |
| `.verification.yml` v3 | Enhanced schema with machine checks |
| Migration script | Convert v2 to v3 |

#### 10.1.3 Tasks

- [ ] Extract helper functions from test-nwp.sh to lib/verify-runner.sh
- [ ] Preserve 5-layer YAML protection (CRITICAL)
- [ ] Add `config` section to .verification.yml
- [ ] Add `machine.checks` to all 553 items
- [ ] Add 18 security_validation items from test-nwp.sh Test 13
- [ ] Create v2→v3 migration script with rollback

#### 10.1.4 Success Criteria
- [ ] All helper functions working in lib/verify-runner.sh
- [ ] 5-layer protection passes ADR-0009 requirements
- [ ] Schema migration preserves all v2 data
- [ ] 571 items in .verification.yml

**Estimated Effort:** 30 hours

---

### Phase 2: Execution Engine (Week 3-4)

#### 10.2.1 Objectives
- Add execution capability to verify.sh
- Implement depth levels
- Test site lifecycle management

#### 10.2.2 Deliverables

| Deliverable | Description |
|-------------|-------------|
| `verify.sh --run` | Machine execution mode |
| Test site management | Create/cleanup test sites |
| Result tracking | Store execution results in YAML |

#### 10.2.3 Tasks

- [ ] Add `--run` mode to verify.sh
- [ ] Implement `execute_check()` with timeout
- [ ] Implement `execute_feature()` for running all items
- [ ] Implement `execute_item()` for single item
- [ ] Create test site with configurable prefix
- [ ] Cleanup with preservation option for debugging
- [ ] Store results in machine.state
- [ ] Update statistics after execution

#### 10.2.4 Success Criteria
- [ ] `pl verify --run --feature=backup` executes all backup checks
- [ ] Timeout prevents hung tests
- [ ] Results stored in .verification.yml
- [ ] Test sites cleaned up on success

**Estimated Effort:** 35 hours

---

### Phase 3: Depth Levels & Parallel Execution (Week 5-6)

#### 10.3.1 Objectives
- Implement all 4 depth levels
- Add parallel execution for independent features
- Performance optimization

#### 10.3.2 Deliverables

| Deliverable | Description |
|-------------|-------------|
| Depth levels | basic/standard/thorough/paranoid |
| Parallel execution | Run independent features concurrently |
| Progress reporting | Real-time status during execution |

#### 10.3.3 Tasks

- [ ] Implement `--depth` flag parsing
- [ ] Execute appropriate checks for each depth
- [ ] Identify parallelizable features (no dependencies)
- [ ] Implement background execution with job tracking
- [ ] Progress bar during execution
- [ ] Summary report after completion

#### 10.3.4 Success Criteria
- [ ] `--depth=basic` runs in <5 minutes
- [ ] `--depth=paranoid` runs full integration tests
- [ ] Parallel execution reduces total time by 50%+
- [ ] Clear progress indication during run

**Estimated Effort:** 30 hours

---

### Phase 4: Human Verification & Auto-Logging (Week 7)

#### 10.4.1 Objectives
- Implement consent system
- Add auto-logging from command success
- Error reporting prompts

#### 10.4.2 Deliverables

| Deliverable | Description |
|-------------|-------------|
| Consent configuration | Settings in nwp.yml |
| Auto-logging hooks | Capture command success as verification |
| Error reporting | Prompt and store issues |

#### 10.4.3 Tasks

- [ ] Add verification settings to nwp.yml
- [ ] Add consent prompts to setup.sh
- [ ] Hook command execution in pl script
- [ ] Map commands to verification items
- [ ] Update human.state on successful commands
- [ ] Create .verification-issues.yml structure
- [ ] Prompt for error report on failure
- [ ] Link issues to affected items

#### 10.4.4 Success Criteria
- [ ] Consent asked during setup
- [ ] Successful `pl backup` auto-logs backup items
- [ ] Failed commands prompt for report
- [ ] Issues stored and linked to items

**Estimated Effort:** 25 hours

---

### Phase 5: Badges & Reporting (Week 8)

#### 10.5.1 Objectives
- Badge generation
- Verification reports
- README integration

#### 10.5.2 Deliverables

| Deliverable | Description |
|-------------|-------------|
| `pl verify badges` | Generate badge URLs |
| `docs/VERIFICATION_REPORT.md` | Detailed coverage report |
| CI integration | Badge update in pipeline |

#### 10.5.3 Tasks

- [ ] Calculate coverage percentages
- [ ] Generate shields.io badge URLs
- [ ] Create verification report template
- [ ] Generate report from .verification.yml
- [ ] Add `--update-readme` flag
- [ ] Document CI/CD badge refresh

#### 10.5.4 Success Criteria
- [ ] Badges show accurate coverage
- [ ] Report shows per-feature breakdown
- [ ] README can be auto-updated

**Estimated Effort:** 20 hours

---

### Phase 6: CI/CD Integration & Migration (Week 9-10)

#### 10.6.1 Objectives
- Delete test-nwp.sh (clean break)
- Integrate verification into GitLab CI
- Configure Shields.io badges for cross-platform display
- Update all documentation

#### 10.6.2 Deliverables

| Deliverable | Description |
|-------------|-------------|
| GitLab CI verification stage | Replaces any test-nwp.sh usage in CI |
| Badge update job | Commits .badges.json on main branch |
| Minimized GitHub Actions | Dependabot-only, GitLab is primary |
| Updated CLAUDE.md | New release process |
| Updated docs | All 262 test-nwp.sh references updated |
| Migration guide | How to transition from test-nwp.sh |

#### 10.6.3 Tasks

**CI/CD Integration:**
- [ ] Add verification stage to .gitlab-ci.yml
- [ ] Add update-badges job for main branch
- [ ] Implement `pl verify ci` mode with JUnit output
- [ ] Implement `--export-json` for .badges.json generation
- [ ] Minimize GitHub Actions workflow
- [ ] Update README.md with Shields.io badge URLs

**test-nwp.sh Removal:**
- [ ] Delete scripts/commands/test-nwp.sh
- [ ] Remove test-nwp case from pl script
- [ ] Search/replace all 262 references across codebase
- [ ] Update any CI scripts that reference test-nwp.sh

**Documentation:**
- [ ] Update CLAUDE.md release checklist
- [ ] Create docs/guides/verification.md (replaces test-nwp.md)
- [ ] Update docs/guides/setup.md
- [ ] Update docs/deployment/ssh-setup.md
- [ ] Update docs/deployment/cicd.md with new verification stage
- [ ] Update docs/SECURITY.md
- [ ] Update docs/decisions/0009-five-layer-yaml-protection.md
- [ ] Update docs/decisions/0006-contribution-workflow.md
- [ ] Add breaking change notice to CHANGELOG.md
- [ ] Create migration guide

#### 10.6.4 Success Criteria
- [ ] GitLab CI runs verification on every push
- [ ] Badges visible on both git.nwpcode.org AND github.com
- [ ] `pl test-nwp` returns "command not found" (clean break)
- [ ] CLAUDE.md release process uses `pl verify --run --depth=thorough`
- [ ] All documentation references updated
- [ ] No broken links or outdated examples

**Estimated Effort:** 30 hours

---

## 11. Risk Assessment

### 11.1 Technical Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| 5-layer protection regression | Low | Critical | Comprehensive testing, ADR compliance |
| Schema migration data loss | Low | High | Backup before migration, rollback script |
| Execution timeout issues | Medium | Medium | Conservative defaults, configurable timeouts |
| Parallel execution race conditions | Medium | Medium | Careful locking, sequential fallback |
| CI badge commit conflicts | Low | Low | Use [skip ci] tag, only commit on changes |

### 11.2 Process Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| User muscle memory for test-nwp | Medium | Low | Clear error message with new command |
| Documentation out of sync | Medium | Medium | Update docs in same PR as code |
| Badge display issues on GitHub | Low | Low | Shields.io with raw.githubusercontent.com fallback |

### 11.3 Security Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Command injection via YAML | Low | High | Validate all commands before execution |
| Sensitive data in logs | Low | Medium | Sanitize output, respect .gitignore |
| Consent bypass | Low | Medium | Check consent on every auto-log |

---

## 12. Success Metrics

### 12.1 Coverage Targets

| Milestone | Machine | Human | Fully Verified | Timeline |
|-----------|---------|-------|----------------|----------|
| Phase 2 complete | 50% | 5% | 5% | Week 4 |
| Phase 4 complete | 70% | 20% | 15% | Week 7 |
| Phase 6 complete | 85% | 40% | 35% | Week 10 |
| 6 months post-launch | 90% | 60% | 55% | Week 34 |

### 12.2 Performance Targets

| Operation | Target | Notes |
|-----------|--------|-------|
| `--depth=basic` | <5 min | Quick feedback during development |
| `--depth=standard` | <15 min | Pre-commit verification |
| `--depth=thorough` | <30 min | Pre-push verification |
| `--depth=paranoid` | <60 min | Pre-release verification |
| Auto-log overhead | <100ms | Per command |

### 12.3 Quality Targets

| Metric | Target |
|--------|--------|
| Pass rate (machine) | 98%+ (matching current test-nwp.sh) |
| False positives | <1% |
| Badge accuracy | Real-time (within 1 execution) |

---

## 13. Appendices

### 13.1 Command Reference

```bash
# Execution
pl verify --run                          # Run all automatable items
pl verify --run --depth=basic            # Quick check
pl verify --run --depth=paranoid         # Full integration
pl verify --run --feature=backup         # Specific feature
pl verify --run --item=backup_0          # Specific item
pl verify --run --affected               # Changed items only
pl verify --run --parallel               # Parallel execution

# Human verification
pl verify                                # Interactive TUI
pl verify status                         # Summary statistics
pl verify details backup                 # Feature details

# Badges & reporting
pl verify badges                         # Generate badge URLs
pl verify badges --update-readme         # Update README.md
pl verify report                         # Full verification report

# CI/CD mode
pl verify ci                             # Machine checks with JUnit output
pl verify ci --export-json               # Generate .badges.json
pl verify ci --depth=standard            # CI-specific depth

# Issues
pl verify issues                         # List open issues
pl verify issues --resolve NWP-001       # Resolve issue

# Migration
pl verify migrate                        # Migrate v2 to v3
```

### 13.2 CLAUDE.md Release Process Update

```markdown
### 1. Pre-Release Verification

- [ ] Run `pl verify --run --depth=thorough` - ensure 98%+ pass rate
- [ ] Run `bash -n` syntax check on modified scripts
- [ ] Run `pl verify badges` to check coverage
- [ ] Verify no uncommitted changes: `git status`
```

### 13.3 Glossary

| Term | Definition |
|------|------------|
| **Machine verification** | Automated checks executed by verify.sh |
| **Human verification** | Confirmation from usage or manual review |
| **Fully verified** | Item with both machine AND human verification |
| **Depth level** | Thoroughness: basic → paranoid |
| **Auto-logging** | Automatic capture from command success |
| **Smart invalidation** | Item-level invalidation from file changes |

---

## 14. Ongoing Coverage Improvement

### 14.1 Current Status

**Last Updated:** 2026-01-17

| Metric | Current | Target |
|--------|---------|--------|
| Machine Coverage | 42% (245/575) | 85% |
| Items with machine checks | 245 | 489 |
| Items needing checks | ~330 | 0 |

### 14.2 Systematic Process for Adding Machine Checks

When continuing P50 coverage work, follow this process:

#### Step 1: Identify Features Needing Coverage

Run this command to find features with items missing machine checks:

```bash
awk '
/^  [a-z_]+:$/ {
    if (feature != "" && no_machine > 0) {
        print feature ": " no_machine " items without machine checks"
    }
    feature = $1; gsub(/:$/, "", feature); no_machine = 0
}
/^    checklist:/ { in_list = 1 }
/^    - text:/ { if (in_list) { has_machine = 0; in_item = 1 } }
/^      machine:/ { if (in_item) has_machine = 1 }
/^    [a-z_]+:$/ && !/^    - / {
    if (in_item && !has_machine) no_machine++
    in_item = 0; in_list = 0
}
END { if (no_machine > 0) print feature ": " no_machine " items" }
' .verification.yml | sort -t: -k2 -rn | head -20
```

#### Step 2: Priority Order

Work through features in this priority:

1. **Library functions** (`lib_*`) - Self-contained, easy to test
2. **Core commands** (`install`, `backup`, `restore`, `copy`) - High usage
3. **Deployment** (`dev2stg`, `stg2prod`, etc.) - Critical paths
4. **Support commands** (`doctor`, `status`, `modify`) - Helper functions
5. **Infrastructure** (`linode_*`, `live`) - Requires credentials (mark `automatable: false`)

#### Step 3: Machine Check Template

For each item without a machine check, add this structure after `related_docs:`:

```yaml
      machine:
        automatable: true
        checks:
          basic:
            commands:
            - cmd: bash -n lib/LIBRARY.sh
              expect_exit: 0
              timeout: 10
          standard:
            commands:
            - cmd: bash -c 'source lib/LIBRARY.sh && type FUNCTION_NAME 2>/dev/null'
              expect_exit: 0
          thorough:
            commands:
            - cmd: bash -c 'source lib/LIBRARY.sh && type FUNCTION_NAME 2>/dev/null'
              expect_exit: 0
          paranoid:
            commands:
            - cmd: bash -c 'source lib/LIBRARY.sh && type FUNCTION_NAME 2>/dev/null'
              expect_exit: 0
        state:
          verified: false
          verified_at: null
          depth: null
          duration_seconds: null
```

**For command scripts**, use:
- `bash -n scripts/commands/SCRIPT.sh` for syntax check
- `pl COMMAND --help 2>&1 | head -5` for help text check

#### Step 4: Verify Changes

After adding machine checks:

```bash
# 1. Validate YAML syntax
python3 -c "import yaml; yaml.safe_load(open('.verification.yml'))"

# 2. Run verification on the feature
pl verify --run --depth=basic --feature=FEATURE_ID

# 3. Check updated coverage
pl verify summary
```

#### Step 5: Track Progress

Update this section's "Current Status" table after each session.

### 14.3 Features Completed

| Feature | Items | Date | Notes |
|---------|-------|------|-------|
| lib_developer | 11/11 | 2026-01-17 | All function type checks |
| setup | 5/5 | 2026-01-17 | Pre-existing |
| (more to come) | | | |

### 14.4 Known Limitations

Items marked `automatable: false` typically require:
- External API credentials (Linode, Cloudflare, GitLab)
- Interactive user input
- Running production infrastructure
- Browser-based verification

These should still have a `machine:` section with `automatable: false` and basic syntax checks where possible.

---

## 15. Approval

| Role | Name | Date | Signature |
|------|------|------|-----------|
| Author | Claude Opus 4.5 | 2026-01-16 | |
| Requirements | Rob | 2026-01-16 | |
| Reviewer | | | |
| Approver | | | |

---

**End of Proposal**
