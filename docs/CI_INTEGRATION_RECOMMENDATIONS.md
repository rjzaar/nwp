# CI Integration Recommendations for NWP

This document provides comprehensive recommendations for integrating Continuous Integration (CI) setup automation into the Narrow Way Project (NWP). Based on analysis of existing CI/CD frameworks, current NWP infrastructure, and 2025 best practices.

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Research Findings](#research-findings)
3. [Current NWP CI Infrastructure](#current-nwp-ci-infrastructure)
4. [Best Practices (2025)](#best-practices-2025)
5. [Recommendations](#recommendations)
6. [Configuration Changes](#configuration-changes)
7. [Implementation Plan](#implementation-plan)
8. [File Reference](#file-reference)

---

## Executive Summary

NWP already has substantial CI infrastructure including a GitLab CI template, comprehensive testing scripts, and detailed documentation. The recommendations focus on:

1. **Automating CI setup** - One-command CI configuration during site installation
2. **Shell script quality** - Adding ShellCheck and shfmt for NWP's own scripts
3. **Test framework enhancement** - Converting to BATS for better CI integration
4. **Configuration-driven CI** - New `settings.ci` section in cnwp.yml
5. **Multi-platform support** - GitHub Actions templates alongside GitLab CI

---

## Research Findings

### Analysis of ~/tmp Directory

The ~/tmp directory contains mature Drupal CI/CD examples that inform these recommendations:

#### Pleasy (~/tmp/pleasy)
- Bash-based DevOps framework for Drupal
- CircleCI and GitHub Actions configurations
- ~80 shell scripts with modular library structure
- Pattern: Recipe-based site management (similar to NWP)

#### Vortex (~/tmp/vortex)
- Advanced CI/CD template with sophisticated pipelines
- **Key features to adopt:**
  - Database caching strategy (timestamp-based with fallback)
  - Parallel Behat execution with @p0, @p1 tags
  - Coverage threshold enforcement (90% default)
  - Renovate for automated dependency updates
  - Docker layer caching for faster builds

#### Varbase (~/tmp/varbase)
- CircleCI configuration for comprehensive Behat testing
- 5 parallel test jobs with 30-minute timeouts
- Chrome/Selenium integration pattern

#### Open Social (~/tmp/social)
- Tugboat preview system for PR previews
- Branch-aware deployment configuration
- Solr integration for search testing

### Key Patterns Identified

| Pattern | Source | Recommendation |
|---------|--------|----------------|
| Database caching | Vortex | Implement timestamp-based DB cache |
| Parallel testing | Vortex, Varbase | Add @p0, @p1 Behat tags |
| Coverage thresholds | Vortex | Enforce 80% minimum |
| PR previews | Social | Consider Tugboat integration |
| Shell script structure | Pleasy | Already followed by NWP |

---

## Current NWP CI Infrastructure

### Existing Components

| Component | Location | Status |
|-----------|----------|--------|
| GitLab CI template | `templates/.gitlab-ci.yml` | Complete (417 lines) |
| OpenSocial testing | `testos.sh` | Complete (955 lines) |
| NWP test suite | `test-nwp.sh` | Complete (1,135 lines, 98% pass rate) |
| CI documentation | `docs/CICD.md` | Comprehensive (1,077 lines) |
| CI strategy | `docs/NWP_CI_TESTING_STRATEGY.md` | Complete (1,374 lines) |

### Current GitLab CI Pipeline Stages

```
build:composer → validate (phpcs, phpstan, rector, security) → test (phpunit, behat) → deploy
```

### Gaps Identified

1. **No CI for NWP itself** - NWP's shell scripts lack CI validation
2. **Manual CI setup** - Users must manually copy templates to sites
3. **No GitHub Actions** - Only GitLab CI templates available
4. **Configuration not centralized** - CI settings scattered across files
5. **Custom test format** - Tests not in standard TAP/JUnit format

---

## Best Practices (2025)

### Shell Script CI

| Tool | Purpose | Priority |
|------|---------|----------|
| **ShellCheck** | Static analysis for shell scripts | Mandatory |
| **shfmt** | Automatic formatting | Recommended |
| **BATS** | Bash testing framework with TAP output | Recommended |

#### ShellCheck Integration

```bash
# Recommended flags
shellcheck -e SC1091 lib/*.sh *.sh

# SC1091: Can't follow non-constant source (common in modular scripts)
```

#### shfmt Configuration

```bash
# Recommended options
shfmt -i 2 -ci -s  # 2-space indent, case indent, simplify
```

### Testing Framework Comparison

| Framework | Syntax | CI Integration | Recommendation |
|-----------|--------|----------------|----------------|
| **BATS** | Custom DSL | TAP output, JUnit XML | Best for Bash |
| shUnit2 | xUnit style | Manual JUnit | Alternative |
| ShellSpec | BDD DSL | Built-in mocking | Complex projects |

### Pipeline Best Practices

1. **Build once, deploy everywhere** - Tag artifacts with git commit hash
2. **Test pyramid** - Many unit tests, fewer integration, minimal E2E
3. **Shift-left security** - Vulnerability scanning early in pipeline
4. **Parallel execution** - Split test suites across runners
5. **Caching** - Cache dependencies and database snapshots

### GitHub Actions vs GitLab CI

| Aspect | GitHub Actions | GitLab CI |
|--------|---------------|-----------|
| Configuration | Multiple YAML files | Single `.gitlab-ci.yml` |
| Marketplace | Extensive pre-built actions | Build your own |
| Self-hosting | Paid only | Free tier available |
| Deployment | Manual setup | Built-in environments |

**Recommendation:** Support both platforms to maximize flexibility.

---

## Recommendations

### 1. New Scripts to Create

#### CI Helper Scripts (`ci/` directory)

| Script | Purpose | Priority |
|--------|---------|----------|
| `ci/setup-ci.sh` | One-command CI setup for sites | High |
| `ci/lint.sh` | Run ShellCheck + shfmt on NWP scripts | High |
| `ci/run-tests.sh` | Unified test runner for CI pipelines | High |
| `ci/validate-config.sh` | Validate cnwp.yml and .secrets.yml | Medium |
| `ci/notify.sh` | Send notifications via configured channels | Low |

#### BATS Test Suite (`tests/bats/` directory)

| File | Purpose |
|------|---------|
| `tests/bats/yaml-write.bats` | YAML library tests |
| `tests/bats/install.bats` | Installation tests |
| `tests/bats/backup.bats` | Backup/restore tests |
| `tests/bats/common.bats` | Common library tests |

#### CI Configuration for NWP Itself

| File | Purpose |
|------|---------|
| `.gitlab-ci.yml` | CI pipeline for NWP repository |
| `.github/workflows/nwp.yml` | GitHub Actions for NWP repository |

#### Template Files

| File | Purpose |
|------|---------|
| `templates/.github/workflows/drupal.yml` | GitHub Actions for Drupal sites |
| `templates/Makefile` | Local CI shortcuts |
| `templates/.pre-commit-config.yaml` | Pre-commit hooks |

### 2. Scripts to Modify

| Script | Modification | Reason |
|--------|--------------|--------|
| `install.sh` | Add `--ci` flag | Auto-setup CI during install |
| `setup.sh` | Install CI tools | Prerequisites for CI |
| `templates/.gitlab-ci.yml` | Add shell linting stage | Better coverage |
| `test-nwp.sh` | Add TAP output format | CI integration |
| `lib/common.sh` | Add `ci_config_get()` | Read CI settings |

### 3. Directory Structure

```
nwp_autotest/
├── ci/                              # NEW: CI helper scripts
│   ├── setup-ci.sh                  # One-command CI setup
│   ├── lint.sh                      # Shell linting
│   ├── run-tests.sh                 # Unified test runner
│   ├── validate-config.sh           # Config validation
│   └── notify.sh                    # Notifications
├── tests/
│   ├── bats/                        # NEW: BATS test suite
│   │   ├── test_helper/             # BATS helper libraries
│   │   ├── yaml-write.bats
│   │   ├── install.bats
│   │   └── ...
│   ├── test-integration.sh          # Existing
│   └── test-yaml-write.sh           # Existing (to convert)
├── templates/
│   ├── .gitlab-ci.yml               # ENHANCE: Add shell linting
│   ├── .github/                     # NEW: GitHub Actions
│   │   └── workflows/
│   │       └── drupal.yml
│   ├── Makefile                     # NEW: Local CI shortcuts
│   └── .pre-commit-config.yaml      # NEW: Pre-commit hooks
├── .gitlab-ci.yml                   # NEW: CI for NWP repo
└── .github/workflows/nwp.yml        # NEW: GitHub Actions for NWP
```

---

## Configuration Changes

### Changes to `example.cnwp.yml`

Add a new `ci` section under `settings`:

```yaml
settings:
  # ... existing settings ...

  # CI/CD Configuration
  ci:
    # CI platform: github, gitlab, or both
    platform: gitlab

    # Enable CI setup during install (pl install --ci)
    auto_setup: false

    # Shell script linting
    shellcheck:
      enabled: true
      severity: warning          # error, warning, info, style
      exclude:                   # ShellCheck codes to ignore
        - SC1091                 # Can't follow non-constant source

    # Shell script formatting
    shfmt:
      enabled: true
      indent: 2                  # Indentation width
      check_only: true           # Don't auto-fix, just check

    # Test configuration
    testing:
      # Skip flags (can be overridden per recipe or via environment)
      skip_phpcs: false
      skip_phpstan: false
      skip_phpunit: false
      skip_behat: false

      # Coverage thresholds
      coverage:
        enabled: true
        threshold: 80            # Minimum coverage percentage
        format: cobertura        # cobertura, clover, html

      # Behat configuration
      behat:
        parallel: 2              # Number of parallel runners
        profile: default         # default, smoke, full
        browser: chrome          # chrome, firefox

      # PHPStan level (0-9)
      phpstan_level: 5

    # Deployment configuration
    deploy:
      # Require tests to pass before deployment
      require_tests: true

      # Auto-deploy branches
      staging_branch: develop
      production_branch: main

      # Manual approval required for production
      production_manual: true

      # Backup before deployment
      backup_before_deploy: true

    # Notifications
    notifications:
      enabled: false
      # Channels: slack, email, or both
      channels:
        - slack
      # Events to notify on
      on_success: false
      on_failure: true
      on_deploy: true

    # Local development hooks
    hooks:
      pre_commit:
        enabled: true
        run:
          - shellcheck
          - phpstan
      pre_push:
        enabled: true
        run:
          - phpcs
          - phpunit_unit
```

#### Per-Recipe CI Options

Add CI configuration to individual recipes:

```yaml
recipes:
  os:
    source: goalgorilla/social_template:dev-master
    # ... existing config ...

    # CI configuration (overrides settings.ci)
    ci:
      enabled: true              # Enable CI for this recipe
      platform: gitlab           # Override default platform

      # Test profiles for this recipe
      testing:
        behat_profile: social    # Recipe-specific Behat profile
        phpstan_level: 4         # Lower level for this recipe
        skip_behat: false

        # Additional test tags
        behat_tags: "@social"
        phpunit_groups: "unit,kernel"

      # Coverage requirements
      coverage:
        threshold: 70            # Lower threshold for this recipe

      # Recipe-specific skip conditions
      skip_on:
        - "docs/*"               # Skip CI for docs-only changes
        - "*.md"
```

### Changes to `.secrets.example.yml`

Add CI/CD service tokens:

```yaml
# NWP Infrastructure Secrets Configuration
# Copy this file to .secrets.yml and add your actual credentials
# NEVER commit .secrets.yml to version control!

# Linode API Configuration
linode:
  api_token: YOUR_LINODE_API_TOKEN_HERE

# CI/CD Platform Tokens
ci:
  # GitHub Configuration
  # Used for GitHub Actions, PR comments, status checks
  # Create token at: https://github.com/settings/tokens
  # Required scopes: repo, workflow (for private repos)
  github:
    api_token: YOUR_GITHUB_TOKEN_HERE

  # GitLab Configuration
  # Used for GitLab CI, API access, container registry
  # Create token at: https://gitlab.com/-/profile/personal_access_tokens
  # Required scopes: api, read_repository, write_repository
  gitlab:
    api_token: YOUR_GITLAB_TOKEN_HERE
    # Self-hosted GitLab URL (leave blank for gitlab.com)
    url: ""

# Notification Services
notifications:
  # Slack webhook for CI notifications
  # Create at: https://api.slack.com/messaging/webhooks
  slack:
    webhook_url: YOUR_SLACK_WEBHOOK_URL_HERE

  # Email notifications (SMTP)
  email:
    smtp_host: smtp.example.com
    smtp_port: 587
    smtp_user: notifications@example.com
    smtp_password: YOUR_SMTP_PASSWORD_HERE
    from_address: nwp-ci@example.com
    recipients:
      - dev@example.com

# Code Quality Services
code_quality:
  # Codecov.io for coverage reporting
  codecov:
    token: YOUR_CODECOV_TOKEN_HERE

# Note: Site-specific secrets should be stored in each site's
# .secrets.yml file, not here.
```

---

## Implementation Plan

### Phase 1: Shell Script CI for NWP (High Priority)

**Goal:** Add CI validation for NWP's own shell scripts.

#### Tasks

1. Create `ci/lint.sh`:
   ```bash
   #!/bin/bash
   set -euo pipefail

   # Lint all NWP shell scripts
   echo "Running ShellCheck..."
   find . -name "*.sh" -not -path "./vendor/*" | xargs shellcheck -e SC1091

   echo "Checking formatting with shfmt..."
   shfmt -i 2 -ci -d .

   echo "All checks passed!"
   ```

2. Create `.gitlab-ci.yml` for NWP repository:
   ```yaml
   stages:
     - validate
     - test

   shellcheck:
     stage: validate
     image: koalaman/shellcheck-alpine
     script:
       - shellcheck lib/*.sh *.sh linode/*.sh git/*.sh tests/*.sh
     allow_failure: false

   shfmt:
     stage: validate
     image: mvdan/shfmt
     script:
       - shfmt -i 2 -ci -d .
     allow_failure: true  # Warning only initially

   nwp_tests:
     stage: test
     image: ubuntu:22.04
     before_script:
       - apt-get update && apt-get install -y bash curl git
     script:
       - ./test-nwp.sh --ci
   ```

3. Create `.github/workflows/nwp.yml`:
   ```yaml
   name: NWP CI

   on:
     push:
       branches: [main, develop]
     pull_request:
       branches: [main]

   jobs:
     lint:
       runs-on: ubuntu-latest
       steps:
         - uses: actions/checkout@v4

         - name: ShellCheck
           uses: ludeeus/action-shellcheck@master
           with:
             scandir: '.'
             ignore_paths: vendor

         - name: shfmt
           uses: mvdan/sh@v0.7
           with:
             shfmt-version: 'latest'

     test:
       runs-on: ubuntu-latest
       needs: lint
       steps:
         - uses: actions/checkout@v4

         - name: Run NWP tests
           run: ./test-nwp.sh --ci
   ```

### Phase 2: CI Setup Command (High Priority)

**Goal:** One-command CI configuration during site installation.

#### Tasks

1. Create `ci/setup-ci.sh`:
   ```bash
   #!/bin/bash
   # Setup CI for a site based on cnwp.yml configuration

   set -euo pipefail
   source "$(dirname "$0")/../lib/common.sh"

   site_name="$1"
   platform="${2:-$(ci_config_get 'platform' 'gitlab')}"

   # Copy appropriate CI template
   case "$platform" in
     gitlab)
       cp templates/.gitlab-ci.yml "$site_dir/.gitlab-ci.yml"
       ;;
     github)
       mkdir -p "$site_dir/.github/workflows"
       cp templates/.github/workflows/drupal.yml "$site_dir/.github/workflows/ci.yml"
       ;;
     both)
       cp templates/.gitlab-ci.yml "$site_dir/.gitlab-ci.yml"
       mkdir -p "$site_dir/.github/workflows"
       cp templates/.github/workflows/drupal.yml "$site_dir/.github/workflows/ci.yml"
       ;;
   esac

   # Copy additional templates
   cp templates/Makefile "$site_dir/Makefile"
   cp templates/.pre-commit-config.yaml "$site_dir/.pre-commit-config.yaml"

   echo "CI configured for $site_name using $platform"
   ```

2. Modify `install.sh` to add `--ci` flag:
   ```bash
   # Add to argument parsing
   --ci)
     SETUP_CI=true
     shift
     ;;

   # Add after site installation
   if [[ "$SETUP_CI" == "true" ]]; then
     ./ci/setup-ci.sh "$site_name"
   fi
   ```

3. Modify `setup.sh` to install CI tools:
   ```bash
   # Add CI tools installation
   install_ci_tools() {
     echo "Installing CI tools..."

     # ShellCheck
     if ! command -v shellcheck &> /dev/null; then
       sudo apt-get install -y shellcheck
     fi

     # shfmt
     if ! command -v shfmt &> /dev/null; then
       GO111MODULE=on go install mvdan.cc/sh/v3/cmd/shfmt@latest
     fi

     # BATS
     if ! command -v bats &> /dev/null; then
       git clone https://github.com/bats-core/bats-core.git /tmp/bats
       sudo /tmp/bats/install.sh /usr/local
     fi
   }
   ```

### Phase 3: BATS Test Conversion (Medium Priority)

**Goal:** Convert existing tests to BATS format for better CI integration.

#### Example Conversion

**Before** (`tests/test-yaml-write.sh`):
```bash
run_test() {
    local test_name="$1"
    shift
    local test_command="$@"
    # custom test logic
}
run_test "Add a site" test_add_site
```

**After** (`tests/bats/yaml-write.bats`):
```bash
#!/usr/bin/env bats

setup() {
    load 'test_helper/bats-support/load'
    load 'test_helper/bats-assert/load'
    source "$BATS_TEST_DIRNAME/../../lib/yaml-write.sh"
}

@test "yaml_add_site creates new site entry" {
    run yaml_add_site "testsite" "/tmp/testsite" "test_recipe" "development"
    assert_success
    assert_output --partial "added"
}

@test "yaml_site_exists returns true for existing site" {
    # Setup
    yaml_add_site "existingsite" "/tmp/existingsite" "recipe" "dev"

    # Test
    run yaml_site_exists "existingsite"
    assert_success
}
```

### Phase 4: Template Enhancement (Medium Priority)

**Goal:** Improve existing templates with best practices from Vortex.

#### Tasks

1. Update `templates/.gitlab-ci.yml`:
   - Add shell linting stage
   - Implement database caching
   - Add parallel Behat execution
   - Add coverage threshold enforcement

2. Create `templates/Makefile`:
   ```makefile
   .PHONY: test lint ci quick-test

   # Quick validation (pre-commit)
   quick-test:
   	vendor/bin/phpstan analyse --memory-limit=2G

   # Full linting
   lint:
   	vendor/bin/phpcs
   	vendor/bin/phpstan analyse

   # Full test suite
   test: lint
   	vendor/bin/phpunit
   	vendor/bin/behat --profile=default

   # CI simulation
   ci: lint test
   	@echo "CI simulation complete"
   ```

3. Create `templates/.pre-commit-config.yaml`:
   ```yaml
   repos:
     - repo: https://github.com/koalaman/shellcheck-precommit
       rev: v0.9.0
       hooks:
         - id: shellcheck

     - repo: local
       hooks:
         - id: phpstan
           name: PHPStan
           entry: vendor/bin/phpstan analyse --memory-limit=2G
           language: system
           types: [php]
           pass_filenames: false
   ```

### Phase 5: Library Functions (Medium Priority)

**Goal:** Add CI configuration reading to common library.

Add to `lib/common.sh`:

```bash
# Read CI configuration from cnwp.yml
# Usage: ci_config_get "testing.coverage.threshold" "80"
ci_config_get() {
    local key="$1"
    local default="${2:-}"
    local value

    value=$(yaml_get_value "settings.ci.${key}" "$CNWP_CONFIG" 2>/dev/null)

    if [[ -z "$value" || "$value" == "null" ]]; then
        echo "$default"
    else
        echo "$value"
    fi
}

# Check if CI feature is enabled
# Usage: ci_enabled "shellcheck" && shellcheck *.sh
ci_enabled() {
    local feature="$1"
    local enabled

    enabled=$(ci_config_get "${feature}.enabled" "false")
    [[ "$enabled" == "true" ]]
}

# Get CI platform from config
# Usage: platform=$(ci_platform)
ci_platform() {
    ci_config_get "platform" "gitlab"
}

# Check if we're running in CI environment
# Usage: if is_ci; then ...; fi
is_ci() {
    [[ -n "${CI:-}" || -n "${GITLAB_CI:-}" || -n "${GITHUB_ACTIONS:-}" ]]
}
```

---

## File Reference

### New Files Summary

| File | Lines (est.) | Priority | Description |
|------|--------------|----------|-------------|
| `ci/setup-ci.sh` | 100 | High | One-command CI setup |
| `ci/lint.sh` | 50 | High | Shell script linting |
| `ci/run-tests.sh` | 150 | High | Unified test runner |
| `ci/validate-config.sh` | 80 | Medium | Config validation |
| `ci/notify.sh` | 100 | Low | Notification sender |
| `.gitlab-ci.yml` | 50 | High | NWP repo CI |
| `.github/workflows/nwp.yml` | 60 | Medium | NWP GitHub Actions |
| `templates/.github/workflows/drupal.yml` | 150 | Medium | Site template |
| `templates/Makefile` | 40 | Medium | Local CI shortcuts |
| `templates/.pre-commit-config.yaml` | 30 | Medium | Pre-commit hooks |
| `tests/bats/*.bats` | 500+ | Medium | BATS test suite |

### Modified Files Summary

| File | Changes | Priority |
|------|---------|----------|
| `example.cnwp.yml` | Add `settings.ci` section (~80 lines) | High |
| `.secrets.example.yml` | Add CI tokens section (~50 lines) | High |
| `install.sh` | Add `--ci` flag handling (~20 lines) | High |
| `setup.sh` | Add CI tool installation (~40 lines) | Medium |
| `lib/common.sh` | Add CI helper functions (~50 lines) | Medium |
| `templates/.gitlab-ci.yml` | Add shell linting, caching (~30 lines) | Medium |
| `test-nwp.sh` | Add TAP output, `--ci` flag (~30 lines) | Medium |

---

## Usage Examples

After implementation:

```bash
# Install site with CI auto-configured
pl install os mysite --ci

# Run CI locally based on cnwp.yml config
pl ci lint              # Run configured linting
pl ci test              # Run configured tests
pl ci validate          # Validate configuration

# Override config via environment
SKIP_BEHAT=true pl ci test

# Setup CI for existing site
pl ci setup mysite --platform=github

# Run specific test suites
pl ci test --quick      # Lint only
pl ci test --full       # All tests including Behat
```

---

## References

### External Resources

- [ShellCheck](https://github.com/koalaman/shellcheck) - Shell script static analysis
- [shfmt](https://github.com/mvdan/sh) - Shell script formatter
- [BATS](https://github.com/bats-core/bats-core) - Bash Automated Testing System
- [GitLab CI Documentation](https://docs.gitlab.com/ee/ci/)
- [GitHub Actions Documentation](https://docs.github.com/en/actions)

### Internal Documentation

- `docs/CICD.md` - Existing CI/CD implementation guide
- `docs/NWP_CI_TESTING_STRATEGY.md` - Testing strategy research
- `docs/TESTING.md` - Testing framework documentation
- `templates/.gitlab-ci.yml` - Existing GitLab CI template

---

## Changelog

| Date | Version | Changes |
|------|---------|---------|
| 2025-12-31 | 1.0 | Initial recommendations document |
