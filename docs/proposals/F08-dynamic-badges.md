# Dynamic Badges Proposal

A proposal for implementing cross-platform dynamic badges that display verification status and test results on both GitHub and NWP GitLab READMEs.

**Status:** PROPOSAL
**Created:** January 2026
**Related:** [Roadmap](../governance/roadmap.md), lib/badges.sh, scripts/commands/verify.sh, scripts/commands/test-nwp.sh

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [What is Shields.io](#what-is-shieldsio)
3. [Current State](#current-state)
4. [Problems Identified](#problems-identified)
5. [Proposed Solutions](#proposed-solutions)
6. [Implementation Details](#implementation-details)
7. [CI Automation](#ci-automation)
8. [Self-Hosted GitLab Integration](#self-hosted-gitlab-integration)
9. [Migration Plan](#migration-plan)
10. [Success Criteria](#success-criteria)

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
- **Support self-hosted GitLab instances** via setup.sh automation

**CI Strategy: GitLab-Primary**

NWP GitLab (git.nwpcode.org) is the canonical repository and the only place where badge data is generated:

| Repository | Role | Badge Generation |
|------------|------|------------------|
| NWP GitLab | Canonical | Yes - runs test-nwp, verify.sh |
| GitHub | Mirror | No - receives `.badges.json` via sync |

This approach ensures badges reflect the authoritative test results from the NWP environment.

**Self-Hosted GitLab Support**

NWP already has automated GitLab provisioning via Linode StackScripts. This proposal extends that infrastructure to automatically configure badge generation on any self-hosted GitLab instance:

```bash
# Option 1: During initial NWP setup
./setup.sh --gitlab --with-badges

# Option 2: Add badges to existing GitLab
./setup.sh gitlab-badges --domain git.example.org
```

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

## Self-Hosted GitLab Integration

NWP already has comprehensive GitLab self-hosting automation. This section extends that infrastructure to include automatic badge configuration.

### Existing GitLab Infrastructure

NWP provides automated GitLab provisioning via Linode:

| Component | Location | Status |
|-----------|----------|--------|
| Server provisioning | `linode/gitlab/gitlab_create_server.sh` | Complete |
| StackScript (automated install) | `linode/gitlab/gitlab_server_setup.sh` | Complete |
| SSL certificates | Certbot in StackScript | Complete |
| CI Runner registration | `server_scripts/gitlab-register-runner.sh` | Complete |
| User management API | `lib/git.sh:gitlab_create_user()` | Complete |
| Project creation API | `lib/git.sh:gitlab_api_create_project()` | Complete |
| Backup/restore | `server_scripts/gitlab-backup.sh` | Complete |

### New Badge Integration Points

#### 1. Setup Script Options

Add badge configuration to `setup.sh`:

```bash
# Full GitLab setup with badges
./setup.sh gitlab --domain git.example.org --with-badges

# Add badges to existing GitLab installation
./setup.sh gitlab-badges

# Configure badges for a specific project
./setup.sh gitlab-badges --project mysite
```

#### 2. New Functions in `lib/git.sh`

```bash
# Configure badge generation for a GitLab project
gitlab_configure_badges() {
    local project_name="$1"
    local group="${2:-sites}"
    local gitlab_domain=$(get_gitlab_url)

    # Add .badges.json generation to project CI
    gitlab_api_add_ci_include "$project_name" "$group" \
        "templates/gitlab-ci-badges.yml"

    # Create scheduled pipeline for nightly badge updates
    gitlab_api_create_schedule "$project_name" "$group" \
        --description "Nightly badge update" \
        --cron "0 3 * * *" \
        --ref "main"

    # Update project README with badge URLs
    local badge_urls=$(generate_readme_badges "$project_name" "$group")
    echo "Badge URLs for $project_name:"
    echo "$badge_urls"
}

# Configure badges for all projects in a group
gitlab_configure_badges_all() {
    local group="${1:-sites}"
    local projects=$(gitlab_api_list_projects "$group")

    for project in $projects; do
        gitlab_configure_badges "$project" "$group"
    done
}
```

#### 3. CI Template for Badge Generation

Create `templates/gitlab-ci-badges.yml`:

```yaml
# NWP Badge Generation CI Template
# Include this in your .gitlab-ci.yml:
#   include:
#     - local: 'templates/gitlab-ci-badges.yml'

.badges-template:
  stage: build
  script:
    - source lib/badges-dynamic.sh
    - generate_badges_json ".badges.json" "${TEST_LOG:-}"
    - |
      git config user.name "NWP CI Bot"
      git config user.email "ci@${CI_SERVER_HOST}"
      git add .badges.json
      if ! git diff --cached --quiet; then
        git commit -m "Update badge data [skip ci]"
        git push "https://oauth2:${CI_JOB_TOKEN}@${CI_SERVER_HOST}/${CI_PROJECT_PATH}.git" HEAD:${CI_COMMIT_BRANCH}
      fi
  artifacts:
    paths:
      - .badges.json
    expire_in: 1 week

update-badges:
  extends: .badges-template
  rules:
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
  tags:
    - nwp

update-badges-nightly:
  extends: .badges-template
  rules:
    - if: $CI_PIPELINE_SOURCE == "schedule"
  before_script:
    # Run tests first to get latest results
    - ./scripts/commands/test-nwp.sh --skip-cleanup 2>&1 | tee .logs/test-nwp-latest.log || true
    - export TEST_LOG=".logs/test-nwp-latest.log"
  tags:
    - nwp
```

#### 4. README Template with Dynamic Badges

Create `templates/README.badges.md` (update existing):

```markdown
# ${PROJECT_NAME}

<!-- Badges - Auto-configured by NWP -->
[![Pipeline](https://${GITLAB_DOMAIN}/${GROUP}/${PROJECT}/badges/main/pipeline.svg)](https://${GITLAB_DOMAIN}/${GROUP}/${PROJECT}/-/pipelines)
[![Coverage](https://${GITLAB_DOMAIN}/${GROUP}/${PROJECT}/badges/main/coverage.svg)](https://${GITLAB_DOMAIN}/${GROUP}/${PROJECT}/-/graphs/main/charts)
[![Verified](https://img.shields.io/endpoint?url=https://${GITLAB_DOMAIN}/${GROUP}/${PROJECT}/-/raw/main/.badges.json&query=$.verification.message&label=verified)](https://${GITLAB_DOMAIN}/${GROUP}/${PROJECT}/-/blob/main/.verification.yml)
[![Tests](https://img.shields.io/endpoint?url=https://${GITLAB_DOMAIN}/${GROUP}/${PROJECT}/-/raw/main/.badges.json&query=$.tests.message&label=tests)](https://${GITLAB_DOMAIN}/${GROUP}/${PROJECT}/-/blob/main/scripts/commands/test-nwp.sh)

## Description
...
```

#### 5. Configuration in cnwp.yml

Add badge settings to `example.cnwp.yml`:

```yaml
settings:
  gitlab:
    # ... existing settings ...

    badges:
      enabled: true                    # Enable badge generation
      include_verification: true       # Include verification % badge
      include_tests: true              # Include test pass rate badge
      nightly_schedule: "0 3 * * *"    # Cron for nightly updates
      auto_readme: true                # Auto-update README with badges
```

### Integration with Existing Scripts

#### A. Extend `linode/gitlab/gitlab_server_setup.sh`

Add badge configuration to the GitLab StackScript:

```bash
# After GitLab installation, configure badge infrastructure
configure_badges() {
    # Create badge generation CI template
    mkdir -p /opt/nwp/templates
    curl -o /opt/nwp/templates/gitlab-ci-badges.yml \
        https://raw.githubusercontent.com/nwp/nwp/main/templates/gitlab-ci-badges.yml

    # Install badges-dynamic.sh library
    curl -o /opt/nwp/lib/badges-dynamic.sh \
        https://raw.githubusercontent.com/nwp/nwp/main/lib/badges-dynamic.sh

    echo "Badge infrastructure configured"
}

# Call during setup if --with-badges flag is set
if [ "$WITH_BADGES" = "true" ]; then
    configure_badges
fi
```

#### B. Extend `coder-setup.sh`

Add badge setup when creating new coder environments:

```bash
# In coder-setup.sh add command
setup_coder_badges() {
    local coder_name="$1"
    local coder_domain="${coder_name}.${BASE_DOMAIN}"

    # Configure badges for coder's GitLab projects
    gitlab_configure_badges_all "sites"

    print_success "Badges configured for ${coder_name}"
}
```

#### C. Extend `install.sh`

Auto-configure badges when installing new sites:

```bash
# After site installation
if [ "$BADGES_ENABLED" = "true" ]; then
    gitlab_configure_badges "$SITE_NAME" "sites"
    add_badges_to_readme "$SITE_DIR/README.md" "$SITE_NAME" "sites"
fi
```

### Self-Hosted Badge URL Considerations

When using a self-hosted GitLab, Shields.io endpoint badges need access to the raw JSON file. Options:

#### Option A: Public GitLab Projects (Recommended for Open Source)

If projects are public, Shields.io can fetch directly:
```
https://img.shields.io/endpoint?url=https://git.example.org/group/project/-/raw/main/.badges.json
```

#### Option B: GitLab Pages (For Private Projects)

Host `.badges.json` on GitLab Pages for public access:
```yaml
# Add to .gitlab-ci.yml
pages:
  stage: deploy
  script:
    - mkdir -p public
    - cp .badges.json public/
  artifacts:
    paths:
      - public
  only:
    - main
```
Badge URL: `https://group.pages.git.example.org/project/badges.json`

#### Option C: Static Badges (No External Access Needed)

If external access is not possible, use static badges updated by CI:
```bash
# CI script updates README directly with current values
VERIFIED_PCT=$(jq -r '.verification.message' .badges.json)
sed -i "s|verified-[0-9]*%25|verified-${VERIFIED_PCT}|g" README.md
```

### Firewall Considerations

For Shields.io to fetch badge data, ensure GitLab raw file access is allowed:

```bash
# In gitlab_server_setup.sh or UFW configuration
# Allow HTTPS access to GitLab (required for badge fetching)
ufw allow 443/tcp comment 'GitLab HTTPS (badges)'
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

### Phase 5: Self-Hosted GitLab Integration

- [ ] Create `templates/gitlab-ci-badges.yml` CI template
- [ ] Add `gitlab_configure_badges()` function to `lib/git.sh`
- [ ] Add `--with-badges` option to GitLab setup scripts
- [ ] Add `settings.gitlab.badges` to `example.cnwp.yml`
- [ ] Integrate badge setup into `install.sh`
- [ ] Update `coder-setup.sh` with badge configuration
- [ ] Document self-hosted badge URL options (public/pages/static)

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

### Self-Hosted GitLab Integration

- [ ] `./setup.sh gitlab --with-badges` provisions GitLab with badge support
- [ ] `./setup.sh gitlab-badges` adds badges to existing GitLab
- [ ] `templates/gitlab-ci-badges.yml` works on any NWP GitLab instance
- [ ] Badge URLs auto-configured based on `settings.url` domain
- [ ] New site installs include badge configuration when enabled
- [ ] Coder environments have badges pre-configured

---

## Verification Commands

### Local Badge Generation

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

### Self-Hosted GitLab

```bash
# Configure badges for a project on your GitLab
source lib/git.sh
gitlab_configure_badges "mysite" "sites"

# Configure badges for all projects
gitlab_configure_badges_all "sites"

# Test badge URL on self-hosted GitLab
GITLAB_DOMAIN=$(get_gitlab_url)
curl -s "https://${GITLAB_DOMAIN}/sites/mysite/-/raw/main/.badges.json" | jq .

# Test Shields.io can reach your GitLab
curl "https://img.shields.io/endpoint?url=https://${GITLAB_DOMAIN}/sites/mysite/-/raw/main/.badges.json"

# Setup GitLab with badges from scratch
./setup.sh gitlab --domain git.example.org --with-badges

# Add badges to existing GitLab installation
./setup.sh gitlab-badges
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

### External Documentation
- [Shields.io Documentation](https://shields.io/docs/)
- [Shields.io Endpoint Badges](https://shields.io/endpoint)
- [GitLab Badges](https://docs.gitlab.com/ee/user/project/badges.html)
- [GitLab CI/CD Schedules](https://docs.gitlab.com/ee/ci/pipelines/schedules.html)
- [GitLab Pages](https://docs.gitlab.com/ee/user/project/pages/)

### NWP Internal References
- [NWP Badges Library](../lib/badges.sh)
- [NWP Verification System](../scripts/commands/verify.sh)
- [NWP GitLab Setup](../linode/gitlab/)
- [NWP Git Library](../lib/git.sh) - GitLab API functions
- [Coder Setup](../scripts/commands/coder-setup.sh) - Developer onboarding

---

*Proposal created: January 2026*
*Updated: January 8, 2026 - Clarified GitLab-primary CI strategy*
*Updated: January 8, 2026 - Added self-hosted GitLab integration section*
*Status: Ready for review*
