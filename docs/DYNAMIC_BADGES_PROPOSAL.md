# Dynamic Badges Proposal

A proposal for implementing cross-platform dynamic badges that display verification status and test results on both GitHub and NWP GitLab READMEs.

**Status:** PROPOSAL
**Created:** January 2026
**Related:** ROADMAP.md, lib/badges.sh, scripts/commands/verify.sh, scripts/commands/test-nwp.sh

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [What is Shields.io](#what-is-shieldsio)
3. [Current State](#current-state)
4. [Problems Identified](#problems-identified)
5. [Proposed Solutions](#proposed-solutions)
6. [Implementation Details](#implementation-details)
7. [CI Automation](#ci-automation)
8. [Success Criteria](#success-criteria)

---

## Executive Summary

NWP currently has a badge system (`lib/badges.sh`) that generates GitLab-native pipeline and coverage badges. However, these badges:

1. Only work on GitLab (not GitHub mirrors)
2. Only show CI pipeline status and code coverage
3. Don't reflect the verification system or test-nwp results

This proposal adds **dynamic badges** using Shields.io that:

- Work on both GitHub and GitLab READMEs
- Display verification status (% of features verified)
- Display test-nwp results (% tests passing)
- Update automatically via **NWP GitLab CI** (primary)
- Sync to GitHub mirror automatically

**CI Strategy: GitLab-Primary**

NWP GitLab (git.nwpcode.org) is the canonical repository and the only place where badge data is generated:

| Repository | Role | Badge Generation |
|------------|------|------------------|
| NWP GitLab | Canonical | Yes - runs test-nwp, verify.sh |
| GitHub | Mirror | No - receives `.badges.json` via sync |

This approach ensures badges reflect the authoritative test results from the NWP environment.

---

## What is Shields.io

[Shields.io](https://shields.io/) is a free, open-source badge service that creates consistent, legible badges in SVG format. It serves over **1.6 billion images per month** and is used by major projects like VS Code, Vue.js, and Bootstrap.

### Key Features

| Feature | Description |
|---------|-------------|
| **Static Badges** | Pre-defined label, message, and color |
| **Dynamic Badges** | Fetch data from JSON/XML endpoints |
| **Endpoint Badges** | Read custom JSON schema for maximum flexibility |
| **Platform Agnostic** | Works anywhere images are displayed |

### Why Shields.io?

1. **Cross-Platform** - Same badge URL works on GitHub, GitLab, Bitbucket, or any website
2. **Dynamic Updates** - Badges can read from JSON files to display current data
3. **Consistent Style** - Matches the look of existing GitHub/GitLab badges
4. **Free & Open Source** - CC0 licensed, can self-host if needed
5. **No Account Required** - Just construct URLs with your data

### Badge Types

**Static Badge** (hardcoded values):
```
https://img.shields.io/badge/tests-passing-green
```
![Static](https://img.shields.io/badge/tests-passing-green)

**Dynamic Badge** (reads from JSON):
```
https://img.shields.io/badge/dynamic/json?url=<JSON_URL>&query=$.value&label=metric
```

**Endpoint Badge** (custom JSON schema):
```
https://img.shields.io/endpoint?url=<ENDPOINT_URL>
```

### References

- [Shields.io Homepage](https://shields.io/)
- [Shields.io Documentation](https://shields.io/docs/)
- [GitHub Repository](https://github.com/badges/shields)
- [Badge Tutorial](https://github.com/badges/shields/blob/master/doc/TUTORIAL.md)

---

## Current State

### Existing Badge System (`lib/badges.sh`)

The current system generates GitLab-native badges:

```bash
# Pipeline badge
https://git.nwpcode.org/sites/avc/badges/main/pipeline.svg

# Coverage badge
https://git.nwpcode.org/sites/avc/badges/main/coverage.svg
```

**Functions available:**
- `generate_badge_url()` - Single badge URL
- `generate_badge_urls()` - All badge types with markdown
- `generate_readme_badges()` - README-ready markdown
- `add_badges_to_readme()` - Insert badges into README
- `update_readme_badges()` - Update existing badge URLs

**Limitations:**
- Only GitLab-hosted badges
- Only pipeline and coverage metrics
- Don't work on GitHub mirror

### Verification System (`verify.sh`)

Tracks manual verification of 77+ features:

```bash
./verify.sh summary
# Output:
# Total features:  77
# Verified:        45 (58%)
# Unverified:      25
# Modified:        7
```

**Not currently exposed as a badge.**

### Test Suite (`test-nwp.sh`)

Comprehensive test suite with 22+ categories:

```bash
./test-nwp.sh
# Output:
# Total tests run:    142
# Tests passed:       139
# Tests with warnings: 2
# Tests failed:       1
# Success rate: 99%
```

**Not currently exposed as a badge.**

---

## Problems Identified

### Problem 1: GitHub Mirror Has No Badges

**Impact:** HIGH

The NWP GitHub mirror (`github.com/nwp/nwp`) displays README.md without functional badges because GitLab badge URLs return 404 from GitHub's perspective.

### Problem 2: No Verification Visibility

**Impact:** MEDIUM

The verification system tracks important quality metrics, but this information is hidden in `.verification.yml`. Users can't see at a glance how well-tested NWP is.

### Problem 3: Test Results Not Visible

**Impact:** MEDIUM

The test-nwp.sh results are only visible in CI logs. A badge showing "142 tests passing" provides immediate confidence.

### Problem 4: Manual Badge Updates

**Impact:** LOW

Currently, badges must be manually added to READMEs. CI should automate badge data generation.

---

## Proposed Solutions

### Solution Architecture (GitLab-Primary)

```
┌─────────────────────────────────────────────────────────────────┐
│              NWP GITLAB CI (git.nwpcode.org)                     │
│                    [CANONICAL SOURCE]                            │
└─────────────────────────────────┬───────────────────────────────┘
                                  │
         ┌────────────────────────┼────────────────────────────┐
         │                        │                            │
         ▼                        ▼                            ▼
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   verify.sh     │    │   test-nwp.sh   │    │   CI Pipeline   │
│    summary      │    │    results      │    │    status       │
└────────┬────────┘    └────────┬────────┘    └────────┬────────┘
         │                      │                      │
         └──────────────────────┼──────────────────────┘
                                │
                                ▼
                    ┌─────────────────────┐
                    │   .badges.json      │
                    │   (committed to     │
                    │    GitLab repo)     │
                    └──────────┬──────────┘
                               │
                               ▼
                    ┌─────────────────────┐
                    │   GitHub Mirror     │
                    │   (receives sync)   │
                    └──────────┬──────────┘
                               │
              ┌────────────────┼────────────────┐
              │                │                │
              ▼                ▼                ▼
     ┌────────────────┐ ┌────────────────┐ ┌────────────────┐
     │ GitHub README  │ │ GitLab README  │ │ Project Docs   │
     │ (raw.github    │ │ (git.nwpcode   │ │   Website      │
     │  usercontent)  │ │  .org/-/raw)   │ │                │
     └────────────────┘ └────────────────┘ └────────────────┘
```

**Why GitLab-Primary?**

| Reason | Explanation |
|--------|-------------|
| NWP Runner | GitLab has the `nwp` tagged runner with full environment |
| test-nwp.sh | Requires DDEV, sites/, and NWP infrastructure |
| verify.sh | Needs `.verification.yml` and tracked files |
| Canonical Source | GitLab is the source of truth; GitHub is a mirror |

### Badge Data Schema (`.badges.json`)

```json
{
  "schemaVersion": 1,
  "verification": {
    "label": "verified",
    "message": "58%",
    "color": "yellow",
    "verified": 45,
    "total": 77,
    "modified": 7
  },
  "tests": {
    "label": "tests",
    "message": "99% passing",
    "color": "brightgreen",
    "passed": 139,
    "failed": 1,
    "warnings": 2,
    "total": 142
  },
  "lastUpdated": "2026-01-08T10:30:00Z",
  "commit": "abc1234"
}
```

### Badge Types

| Badge | Source | Example Display |
|-------|--------|-----------------|
| Pipeline | GitLab CI native | ![Pipeline](https://img.shields.io/badge/pipeline-passing-brightgreen) |
| Coverage | GitLab CI native | ![Coverage](https://img.shields.io/badge/coverage-85%25-green) |
| **Verification** | .badges.json | ![Verified](https://img.shields.io/badge/verified-58%25-yellow) |
| **Tests** | .badges.json | ![Tests](https://img.shields.io/badge/tests-99%25_passing-brightgreen) |

### Color Thresholds

**Verification:**
| Percentage | Color |
|------------|-------|
| 0-49% | red |
| 50-79% | yellow |
| 80-100% | brightgreen |

**Tests:**
| Pass Rate | Color |
|-----------|-------|
| 0-79% | red |
| 80-94% | yellow |
| 95-100% | brightgreen |

---

## Implementation Details

### 1. New Library: `lib/badges-dynamic.sh`

```bash
#!/bin/bash

################################################################################
# NWP Dynamic Badges Library
#
# Generate JSON badge data for Shields.io endpoint badges
# Source this file: source "$SCRIPT_DIR/lib/badges-dynamic.sh"
################################################################################

# Get color based on percentage and thresholds
get_badge_color() {
    local percentage="$1"
    local type="${2:-default}"

    case "$type" in
        verification)
            if [ "$percentage" -lt 50 ]; then echo "red"
            elif [ "$percentage" -lt 80 ]; then echo "yellow"
            else echo "brightgreen"
            fi
            ;;
        tests)
            if [ "$percentage" -lt 80 ]; then echo "red"
            elif [ "$percentage" -lt 95 ]; then echo "yellow"
            else echo "brightgreen"
            fi
            ;;
        *)
            if [ "$percentage" -lt 50 ]; then echo "red"
            elif [ "$percentage" -lt 80 ]; then echo "yellow"
            else echo "brightgreen"
            fi
            ;;
    esac
}

# Generate verification badge data
generate_verification_data() {
    local output
    output=$(./scripts/commands/verify.sh summary 2>/dev/null)

    local verified=$(echo "$output" | grep "Verified:" | grep -oP '\d+' | head -1)
    local total=$(echo "$output" | grep "Total features:" | grep -oP '\d+')
    local modified=$(echo "$output" | grep "Modified:" | grep -oP '\d+')
    local percentage=$((verified * 100 / total))
    local color=$(get_badge_color "$percentage" "verification")

    cat << EOF
{
  "label": "verified",
  "message": "${percentage}%",
  "color": "${color}",
  "verified": ${verified},
  "total": ${total},
  "modified": ${modified:-0}
}
EOF
}

# Generate test badge data from test-nwp results
generate_test_data() {
    local log_file="$1"

    if [ -z "$log_file" ] || [ ! -f "$log_file" ]; then
        # Return placeholder if no log available
        cat << EOF
{
  "label": "tests",
  "message": "not run",
  "color": "lightgrey"
}
EOF
        return
    fi

    local passed=$(grep "Tests passed:" "$log_file" | grep -oP '\d+')
    local failed=$(grep "Tests failed:" "$log_file" | grep -oP '\d+')
    local warnings=$(grep "Tests with warnings:" "$log_file" | grep -oP '\d+')
    local total=$(grep "Total tests run:" "$log_file" | grep -oP '\d+')

    local success=$((passed + warnings))
    local percentage=$((success * 100 / total))
    local color=$(get_badge_color "$percentage" "tests")

    cat << EOF
{
  "label": "tests",
  "message": "${percentage}% passing",
  "color": "${color}",
  "passed": ${passed},
  "failed": ${failed},
  "warnings": ${warnings},
  "total": ${total}
}
EOF
}

# Generate complete badges.json file
generate_badges_json() {
    local output_file="${1:-.badges.json}"
    local test_log="${2:-}"

    local verification_data=$(generate_verification_data)
    local test_data=$(generate_test_data "$test_log")
    local commit=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    local timestamp=$(date -Iseconds)

    cat > "$output_file" << EOF
{
  "schemaVersion": 1,
  "verification": ${verification_data},
  "tests": ${test_data},
  "lastUpdated": "${timestamp}",
  "commit": "${commit}"
}
EOF

    echo "Generated badge data: $output_file"
}
```

### 2. CLI Command: `pl badges json`

Add to `scripts/commands/badges.sh`:

```bash
json)
    # Generate JSON badge data for Shields.io
    local output_file="${2:-.badges.json}"
    local test_log="${3:-}"

    source "$PROJECT_ROOT/lib/badges-dynamic.sh"
    generate_badges_json "$output_file" "$test_log"
    ;;
```

### 3. README Badge Markdown

For **both GitHub and NWP GitLab READMEs**:

```markdown
# NWP

<!-- GitLab Native Badges -->
[![Pipeline](https://git.nwpcode.org/nwp/nwp/badges/main/pipeline.svg)](https://git.nwpcode.org/nwp/nwp/-/pipelines)
[![Coverage](https://git.nwpcode.org/nwp/nwp/badges/main/coverage.svg)](https://git.nwpcode.org/nwp/nwp/-/graphs/main/charts)

<!-- Shields.io Dynamic Badges -->
[![Verified](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/nwp/nwp/main/.badges.json&query=$.verification.message&label=verified&color=auto)](https://git.nwpcode.org/nwp/nwp/-/blob/main/.verification.yml)
[![Tests](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/nwp/nwp/main/.badges.json&query=$.tests.message&label=tests&color=auto)](https://git.nwpcode.org/nwp/nwp/-/blob/main/scripts/commands/test-nwp.sh)
```

**Alternative: Static badges updated by CI** (if endpoint approach has CORS issues):

```markdown
<!-- These URLs are updated by CI -->
[![Verified](https://img.shields.io/badge/verified-58%25-yellow)](...)
[![Tests](https://img.shields.io/badge/tests-99%25_passing-brightgreen)](...)
```

---

## CI Automation

### GitLab CI Job (Primary - Required)

NWP GitLab is the **only** place where badge data is generated. The `nwp` runner has access to the full NWP environment needed to run `test-nwp.sh` and `verify.sh`.

Add to `.gitlab-ci.yml`:

```yaml
################################################################################
# BADGES STAGE
# Generate dynamic badge data for Shields.io
################################################################################

update-badges:
  stage: build
  needs: []
  rules:
    # Only run on main branch pushes
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
  script:
    - echo "Generating badge data..."

    # Source the dynamic badges library
    - source lib/badges-dynamic.sh

    # Generate verification data
    - ./scripts/commands/verify.sh summary > /tmp/verify-summary.txt || true

    # Run quick test check (or use cached results)
    - |
      if [ -f ".logs/test-nwp-latest.log" ]; then
        TEST_LOG=".logs/test-nwp-latest.log"
      else
        TEST_LOG=""
      fi

    # Generate badges.json
    - generate_badges_json ".badges.json" "$TEST_LOG"

    # Show generated data
    - cat .badges.json

    # Commit if changed (using CI bot)
    - |
      git config user.name "NWP CI Bot"
      git config user.email "ci@nwpcode.org"
      git add .badges.json
      if ! git diff --cached --quiet; then
        git commit -m "Update badge data [skip ci]"
        git push "https://oauth2:${CI_JOB_TOKEN}@${CI_SERVER_HOST}/${CI_PROJECT_PATH}.git" HEAD:${CI_COMMIT_BRANCH}
      else
        echo "No badge changes to commit"
      fi
  artifacts:
    paths:
      - .badges.json
    expire_in: 1 week
  tags:
    - nwp
```

### GitHub Actions (Not Required)

GitHub is a **mirror** of NWP GitLab. Badge data (`.badges.json`) is generated on GitLab and synced to GitHub automatically via the existing mirror process.

**No GitHub Actions workflow is needed for badge generation.**

The GitHub mirror will receive `.badges.json` when it syncs from GitLab, and Shields.io will read from:
- `https://raw.githubusercontent.com/nwp/nwp/main/.badges.json` (GitHub raw)
- `https://git.nwpcode.org/nwp/nwp/-/raw/main/.badges.json` (GitLab raw)

Both URLs will serve the same data since GitHub mirrors GitLab.

**Optional: GitHub workflow for verification-only badges**

If you want GitHub to generate its own verification badges (without test-nwp results, which require the NWP environment), you could add a minimal workflow:

```yaml
# .github/workflows/badges.yml (OPTIONAL - not recommended)
# Only generates verification data, NOT test results
name: Update Verification Badge (Mirror)

on:
  # Only run if GitLab sync fails or for verification-only updates
  workflow_dispatch:

jobs:
  verify-only:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Note
        run: |
          echo "WARNING: GitHub cannot run test-nwp.sh"
          echo "Badge data should come from GitLab CI"
          echo "This workflow is for emergencies only"
```

### Nightly Test Run with Badge Update

Add to existing nightly schedule:

```yaml
# In .gitlab-ci.yml
test-nightly:
  stage: build
  rules:
    - if: $CI_PIPELINE_SOURCE == "schedule"
  script:
    - ./scripts/commands/test-nwp.sh --skip-cleanup 2>&1 | tee .logs/test-nwp-latest.log
    - source lib/badges-dynamic.sh
    - generate_badges_json ".badges.json" ".logs/test-nwp-latest.log"
  after_script:
    # Commit results
    - git add .badges.json .logs/test-nwp-latest.log
    - git commit -m "Nightly test results [skip ci]" || true
    - git push || true
  artifacts:
    paths:
      - .badges.json
      - .logs/test-nwp-latest.log
    expire_in: 1 week
```

---

## Migration Plan

### Phase 1: Core Implementation

- [ ] Create `lib/badges-dynamic.sh` with badge data generation
- [ ] Add `pl badges json` command
- [ ] Create `.badges.json` schema and initial file
- [ ] Test badge generation locally

### Phase 2: GitLab CI Integration

- [ ] Add `update-badges` job to `.gitlab-ci.yml`
- [ ] Add `test-nightly` job with badge update
- [ ] Test CI badge updates on feature branch
- [ ] Merge and verify automatic updates on main

### Phase 3: README Updates

- [ ] Update NWP GitLab README with new badges
- [ ] Verify GitHub mirror receives `.badges.json` via sync
- [ ] Confirm badges display on both platforms
- [ ] Document badge URLs in CICD.md

### Phase 4: Site Badges

- [ ] Extend `pl badges` to generate site-specific dynamic badges
- [ ] Add verification tracking per-site (optional)
- [ ] Document site badge setup

---

## Success Criteria

### Core Functionality

- [ ] `lib/badges-dynamic.sh` generates valid JSON
- [ ] `.badges.json` committed to repository
- [ ] `pl badges json` command works

### GitLab CI Integration (Primary)

- [ ] GitLab CI updates badges on main branch push
- [ ] Nightly job runs test-nwp and updates test results
- [ ] `[skip ci]` prevents infinite loops
- [ ] `.badges.json` syncs to GitHub mirror

### Badge Display

- [ ] Verification badge shows on GitLab README
- [ ] Verification badge shows on GitHub README (via mirror sync)
- [ ] Test badge shows current pass rate
- [ ] Colors reflect actual thresholds

### Documentation

- [ ] CICD.md updated with badge setup
- [ ] Badge URLs documented
- [ ] GitLab-primary architecture explained

---

## Verification Commands

```bash
# Generate badge data locally
source lib/badges-dynamic.sh
generate_badges_json

# View generated data
cat .badges.json

# Test Shields.io endpoint (after commit)
curl "https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/nwp/nwp/main/.badges.json"

# Check verification summary
./scripts/commands/verify.sh summary

# Run tests and generate badge data
./scripts/commands/test-nwp.sh 2>&1 | tee /tmp/test.log
generate_badges_json ".badges.json" "/tmp/test.log"
```

---

## Alternatives Considered

### Alternative 1: Self-Hosted Badge Service

**Pros:** Full control, no external dependencies
**Cons:** Requires hosting, maintenance overhead
**Decision:** Rejected - Shields.io is reliable and free

### Alternative 2: GitLab Custom Badges Only

**Pros:** Native integration
**Cons:** Doesn't work on GitHub, limited customization
**Decision:** Rejected - Need cross-platform support

### Alternative 3: CI Updates README Directly

**Pros:** Simpler implementation
**Cons:** Constant README commits, messy git history
**Decision:** Rejected - JSON file is cleaner

### Alternative 4: GitHub Actions Generates Badges Independently

**Pros:** Badges update even if GitLab sync fails
**Cons:**
- GitHub cannot run `test-nwp.sh` (requires NWP environment, DDEV, sites/)
- Would show different/incomplete data than GitLab
- Duplicates CI effort across platforms
- `.verification.yml` context may differ on mirror
**Decision:** Rejected - GitLab-primary ensures authoritative, consistent data

---

## References

- [Shields.io Documentation](https://shields.io/docs/)
- [Shields.io Endpoint Badges](https://shields.io/endpoint)
- [GitLab Badges](https://docs.gitlab.com/ee/user/project/badges.html)
- [GitHub Actions Badges](https://docs.github.com/en/actions/monitoring-and-troubleshooting-workflows/adding-a-workflow-status-badge)
- [NWP Badges Library](../lib/badges.sh)
- [NWP Verification System](../scripts/commands/verify.sh)

---

*Proposal created: January 2026*
*Updated: January 8, 2026 - Clarified GitLab-primary CI strategy*
*Status: Ready for review*
