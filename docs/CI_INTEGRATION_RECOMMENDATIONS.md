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

### Current Configuration Structure

NWP uses a two-file configuration system with clear separation of concerns:

1. **`cnwp.yml`** - Non-sensitive settings (stack config, PHP settings, recipes)
2. **`.secrets.yml`** - Sensitive credentials (API tokens, passwords, SSH keys)

Both files support reading via library functions in `lib/common.sh`:
- `get_setting "section.key" "default"` - Read from cnwp.yml
- `get_secret "section.key" "default"` - Read from .secrets.yml
- `get_secret_nested "section.subsection.key" "default"` - Read deeply nested secrets

### Current `example.cnwp.yml` Structure

The configuration file uses status markers to indicate implementation status:
- `[ACTIVE]` - Currently used by NWP scripts
- `[PLANNED]` - Documented but not yet implemented
- `[DEFAULT]` - Value shown is the hardcoded default if not specified

```yaml
################################################################################
# SETTINGS - Global NWP Configuration
################################################################################
settings:
  # === STACK SETTINGS [ACTIVE] ===
  database: mariadb                # [ACTIVE] Database type: mariadb, mysql, postgres
  database_version: "10.11"        # [ACTIVE] Database version for DDEV
  php: 8.2                         # [ACTIVE] PHP version for DDEV

  # === STACK SETTINGS [PLANNED] ===
  # webserver: nginx               # [PLANNED] Always nginx in DDEV currently
  # os: ubuntu                     # [PLANNED] Always ubuntu for Linode currently

  # === CLI SETTINGS [PLANNED] ===
  # cli: y                         # [PLANNED] Install universal CLI wrapper
  # cliprompt: pl                  # [PLANNED] CLI command name (hardcoded as 'pl')

  # === DEPLOYMENT SETTINGS [ACTIVE] ===
  linodeuse:                       # [ACTIVE] When to use Linode: testing, gitlab, all, or blank
  urluse:                          # [ACTIVE] When to use custom URL
  url:                             # [ACTIVE] Base domain for live sites (e.g., nwpcode.org)

  # === PHP SETTINGS [ACTIVE] ===
  # These override hardcoded defaults in install.sh
  php_settings:
    memory_limit: 512M             # [ACTIVE] PHP memory limit
    max_execution_time: 600        # [ACTIVE] Max script execution time (seconds)
    upload_max_filesize: 100M      # [ACTIVE] Max upload file size
    post_max_size: 100M            # [ACTIVE] Max POST data size

  # === TIMEOUT SETTINGS [ACTIVE] ===
  timeouts:
    dns_propagation: 300           # [ACTIVE] DNS propagation wait (seconds)
    ssh_connection: 600            # [ACTIVE] SSH connection timeout (seconds)
    health_check: 10               # [ACTIVE] Health check interval (seconds)

  # === GITLAB LOCAL SETTINGS [ACTIVE] ===
  gitlab:
    ports:
      ssh: 2222                    # [ACTIVE] GitLab SSH port
      http: 8080                   # [ACTIVE] GitLab HTTP port
      https: 8443                  # [ACTIVE] GitLab HTTPS port

  # === ENVIRONMENT CONFIGURATION [PLANNED] ===
  environment:
    development:
      debug: true                  # [PLANNED]
      xdebug: false                # [PLANNED]
    staging:
      debug: false                 # [PLANNED]
      stage_file_proxy: true       # [PLANNED]
    production:
      debug: false                 # [PLANNED]
      redis: true                  # [PLANNED]

  # === SERVICES CONFIGURATION [PLANNED] ===
  services:
    redis:
      enabled: false               # [PLANNED]
    solr:
      enabled: false               # [PLANNED]

  # === SITE MANAGEMENT [ACTIVE] ===
  delete_site_yml: true            # [ACTIVE] Remove site from cnwp.yml when deleted

  # === LIVE SITE SECURITY [ACTIVE] ===
  live_security:
    enabled: true                  # [ACTIVE] Enable security hardening
    modules:                       # [ACTIVE] Core security modules
      - seckit
      - honeypot
      - flood_control
      - login_security
      - username_enumeration_prevention

################################################################################
# LINODE - Production Server Configuration
################################################################################
linode:
  # Default settings for new Linode instances [ACTIVE]
  defaults:
    image: linode/ubuntu22.04      # [ACTIVE] Default OS image
    region: us-east                # [ACTIVE] Default region
    type: g6-nanode-1              # [ACTIVE] Default instance type (1GB)
    gitlab_type: g6-standard-1     # [ACTIVE] GitLab needs 2GB minimum

  # Server configurations [ACTIVE]
  servers:
    linode_primary:
      ssh_user: deploy             # [ACTIVE]
      ssh_host: 203.0.113.10       # [ACTIVE]
      ssh_port: 22                 # [ACTIVE]
      ssh_key: ~/.ssh/nwp          # [ACTIVE]
      api_token: ${LINODE_API_TOKEN}

################################################################################
# SITES - Auto-populated Site Registry
################################################################################
sites:
  # Automatically populated when sites are created with install.sh
  # mysite:
  #   directory: /home/user/nwp/mysite    # [ACTIVE]
  #   recipe: d                            # [ACTIVE]
  #   environment: development             # [ACTIVE]
  #   created: 2024-12-28T10:30:00Z       # [ACTIVE]
  #   live:                                # [ACTIVE] Live deployment config
  #     enabled: true
  #     domain: mysite.example.com
```

### Proposed CI Section for `example.cnwp.yml`

Add a new `ci` section under `settings` (all `[PLANNED]`):

```yaml
settings:
  # === CI/CD CONFIGURATION [PLANNED] ===
  ci:
    platform: gitlab               # [PLANNED] CI platform: github, gitlab, or both
    auto_setup: false              # [PLANNED] Enable CI setup during install

    shellcheck:
      enabled: true                # [PLANNED]
      severity: warning            # [PLANNED] error, warning, info, style

    testing:
      skip_phpcs: false            # [PLANNED]
      skip_phpstan: false          # [PLANNED]
      coverage:
        enabled: true              # [PLANNED]
        threshold: 80              # [PLANNED]

    deploy:
      require_tests: true          # [PLANNED]
      backup_before_deploy: true   # [PLANNED]
```

### Current `.secrets.example.yml` Structure

The secrets file contains sensitive credentials organized by service:

```yaml
# NWP Infrastructure Secrets Configuration
# Copy this file to .secrets.yml and fill in your values
# NEVER commit .secrets.yml to version control!

# === LINODE API ===
# Get your API token from: https://cloud.linode.com/profile/tokens
linode:
  api_token: ""

# === GITLAB SERVER ===
# Populated automatically when GitLab server is created
gitlab:
  server:
    domain: ""                     # e.g., git.yourdomain.org
    ip: ""                         # Server IP address
    linode_id: ""                  # Linode instance ID
    ssh_user: gitlab               # SSH username for server access
    ssh_key: ~/.ssh/gitlab         # Path to SSH private key
  api_token: ""                    # GitLab API token for project creation

# === DRUPAL DEFAULTS ===
# Used by install.sh when creating Drupal sites
drupal:
  admin_user: admin                # Drupal admin username
  admin_password: ""               # Empty = generate random password
  admin_email: admin@localhost     # Admin email address

# === MOODLE DEFAULTS ===
# Used by install.sh when creating Moodle sites
moodle:
  admin_user: admin                # Moodle admin username
  admin_password: ""               # Empty = use Admin123!
  admin_email: admin@example.com   # Admin email address
  shortname: moodle                # Site short name

# === SMTP CONFIGURATION ===
# For sites that need email functionality
smtp:
  host: ""                         # SMTP server hostname
  port: 587                        # SMTP port (usually 587 for TLS)
  username: ""                     # SMTP username
  password: ""                     # SMTP password
  from_email: ""                   # Default from email address

# === DEPLOYMENT DEFAULTS ===
# Default SSH settings for production deployments
deployment:
  ssh_key: ~/.ssh/id_rsa           # Default SSH private key
  ssh_user: ""                     # Default SSH username
  ssh_port: 22                     # Default SSH port

# === THIRD-PARTY SERVICES ===
# API keys for optional integrations
services:
  sendgrid_key: ""                 # SendGrid API key
  mailchimp_key: ""                # Mailchimp API key
  cloudflare_api_key: ""           # Cloudflare API key
  cloudflare_zone_id: ""           # Cloudflare zone ID
  ga_tracking_id: ""               # Google Analytics tracking ID
```

### Proposed CI Additions for `.secrets.example.yml`

Add CI/CD service tokens (all `[PLANNED]`):

```yaml
# === CI/CD PLATFORM TOKENS [PLANNED] ===
ci:
  github:
    api_token: ""                  # GitHub personal access token
  gitlab:
    api_token: ""                  # GitLab API token
    url: ""                        # Self-hosted GitLab URL (blank for gitlab.com)

# === NOTIFICATION SERVICES [PLANNED] ===
notifications:
  slack:
    webhook_url: ""                # Slack webhook for CI notifications
  email:
    smtp_host: ""
    smtp_port: 587
    smtp_user: ""
    smtp_password: ""

# === CODE QUALITY SERVICES [PLANNED] ===
code_quality:
  codecov:
    token: ""                      # Codecov.io token for coverage reporting
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

#### Already Implemented in `lib/common.sh`

The following functions are already implemented and available:

```bash
# Get secret value from .secrets.yml with fallback
# Usage: get_secret "section.key" "default_value"
# Example: get_secret "moodle.admin_password" "Admin123!"
get_secret() {
    local path="$1"
    local default="$2"
    local secrets_file="${SCRIPT_DIR}/.secrets.yml"
    # ... parses YAML and returns value or default
}

# Get nested secret value from .secrets.yml (for deeper nesting)
# Usage: get_secret_nested "section.subsection.key" "default_value"
# Example: get_secret_nested "gitlab.server.ip" ""
get_secret_nested() {
    local path="$1"
    local default="$2"
    # ... handles section.subsection.key format
}

# Get setting value from cnwp.yml with fallback
# Usage: get_setting "section.key" "default_value"
# Example: get_setting "php_settings.memory_limit" "512M"
get_setting() {
    local path="$1"
    local default="$2"
    local config_file="${SCRIPT_DIR}/cnwp.yml"
    # ... parses YAML and returns value or default
}
```

#### Proposed CI-Specific Functions (To Be Added)

```bash
# Read CI configuration from cnwp.yml
# Usage: ci_config_get "testing.coverage.threshold" "80"
ci_config_get() {
    get_setting "ci.${1}" "${2:-}"
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

**Already Implemented:**

| File | Changes | Status |
|------|---------|--------|
| `example.cnwp.yml` | Added [ACTIVE]/[PLANNED] markers, php_settings, timeouts, gitlab.ports, linode.defaults | ✓ Done |
| `.secrets.example.yml` | Added Drupal/Moodle credentials, SMTP, deployment, services sections | ✓ Done |
| `lib/common.sh` | Added `get_setting()`, `get_secret()`, `get_secret_nested()` functions | ✓ Done |
| `install.sh` | Uses `get_setting()` for PHP settings, `get_secret()` for Moodle credentials | ✓ Done |

**Proposed Changes (Not Yet Implemented):**

| File | Changes | Priority |
|------|---------|----------|
| `example.cnwp.yml` | Add `settings.ci` section (~40 lines) | High |
| `.secrets.example.yml` | Add CI tokens section (~30 lines) | High |
| `install.sh` | Add `--ci` flag handling (~20 lines) | High |
| `setup.sh` | Add CI tool installation (~40 lines) | Medium |
| `lib/common.sh` | Add CI-specific functions (`ci_config_get`, `ci_enabled`, etc.) | Medium |
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
| 2025-12-31 | 1.1 | Updated with current cnwp.yml and .secrets.yml structure; documented implemented `get_setting()`, `get_secret()`, `get_secret_nested()` functions; added [ACTIVE]/[PLANNED] status markers |
| 2025-12-31 | 1.0 | Initial recommendations document |
