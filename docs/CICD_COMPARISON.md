# CI/CD Comparison: OpenSocial vs Varbase

**Last Updated:** December 2024
**Status:** Analysis and Recommendations for NWP

## Table of Contents

- [Executive Summary](#executive-summary)
- [OpenSocial Analysis](#opensocial-analysis)
- [Varbase Analysis](#varbase-analysis)
- [Feature Comparison Matrix](#feature-comparison-matrix)
- [Recommendations for NWP](#recommendations-for-nwp)
- [Implementation Roadmap](#implementation-roadmap)
- [Example Configurations](#example-configurations)

## Executive Summary

### Quick Comparison

| Aspect | OpenSocial | Varbase | Recommended for NWP |
|--------|-----------|---------|---------------------|
| **CI Platform** | GitHub Actions | CircleCI (+ GitLab templates) | GitHub Actions |
| **Complexity** | High (matrix testing) | Medium-High (full env setup) | Medium (start simple) |
| **Test Strategy** | Feature-based, parallel | Grouped by category | Hybrid approach |
| **Environment** | Docker containers | VM with full stack | DDEV containers |
| **Build Tool** | None (bash scripts) | Phing/Ant + npm scripts | Makefile + npm scripts |
| **Code Quality** | Custom best practices | npm scripts (lint/format) | Both approaches |
| **Update Testing** | Yes (install vs update) | No | Yes (critical for NWP) |
| **Best for NWP** | ⭐⭐⭐⭐ | ⭐⭐⭐ | **Hybrid (best of both)** |

### Key Findings

**OpenSocial Strengths:**
- ✅ Sophisticated matrix testing (install vs update)
- ✅ Dynamic feature discovery
- ✅ Database snapshot isolation
- ✅ Custom best practices enforcement
- ✅ Update path testing (critical!)

**Varbase Strengths:**
- ✅ npm scripts for code quality
- ✅ Organized test grouping
- ✅ Multi-platform support (CircleCI + GitLab)
- ✅ Phing build automation
- ✅ Testing user management scripts

**Recommended for NWP:**
- Use GitHub Actions (already using GitHub)
- Adopt OpenSocial's matrix testing strategy
- Use npm scripts for code quality (like Varbase)
- Add update path testing (from OpenSocial)
- Keep DDEV for consistency with local dev

## OpenSocial Analysis

### CI/CD Architecture

**Platform:** GitHub Actions exclusively

**Repository:** https://github.com/goalgorilla/open_social

### Workflow Files

#### 1. behat.yml - Comprehensive Testing Workflow

**Key Features:**
- **Matrix Strategy:** Tests multiple combinations
  - Fresh install vs major version update
  - With optional modules vs without
  - All feature combinations
- **Dynamic Feature Discovery:** Automatically finds test features
- **Database Snapshots:** Each test runs against clean database
- **Parallel Execution:** Multiple jobs run simultaneously
- **Docker Services:** MariaDB, Redis, Solr, Chrome, Mailpit

**Workflow Structure:**
```yaml
jobs:
  feature_discovery:
    # Dynamically discovers all feature directories
    # Creates matrix of features to test

  install_previous_open_social:
    # Installs previous major version
    # Creates database snapshot
    # Tests upgrade path

  install_open_social:
    # Installs current version (HEAD)
    # Two paths: fresh install OR update from previous
    # Creates database snapshots

  tests:
    # Runs all features in parallel
    # Matrix: feature × update × optional_modules
    # Restores clean database for each test
```

**Testing Matrix:**
- **Dimensions:** `feature` × `update` × `with_optional`
- **Total Combinations:** ~120 test jobs (30 features × 2 × 2)
- **Parallelization:** All run concurrently (limited by GitHub runners)

**Example Test Execution:**
```bash
# For EACH feature directory:
# - Test with fresh install
# - Test with fresh install + optional modules
# - Test after update from previous major
# - Test after update from previous major + optional modules

# Tests restore database before each .feature file
for test in tests/behat/features/capabilities/FEATURE/*.feature; do
  drush sqlc < installation.sql  # Fresh database
  vendor/bin/behat $test
done
```

**Validation Checks:**
- ✅ No warnings in Drush install output
- ✅ No errors in Drush update output
- ✅ Database dumps on failure for debugging
- ✅ Behat logs and mail spool artifacts

#### 2. bestPractices.yml - Custom Code Quality Checks

**Purpose:** Enforce Open Social coding standards

**Checks:**
1. **No Config Overrides:** Prevents `config.factory.override` in services.yml
2. **No Helper Classes:** Prevents creation of Helper classes (anti-pattern)

**Implementation:**
```yaml
# Check for config overrides
- run: "! git diff BASE SHA -- '**/*.services.yml' | grep config.factory.override"

# Check for helper classes
- run: "! git diff BASE SHA --name-only --diff-filter=A | grep Helper"
```

**Feedback Mechanism:**
- Runs on PRs only (not blocking on main)
- Posts comments on PR if violations found
- Allows exceptions with justification

**Key Insight:** Custom checks enforce architectural decisions

#### 3. prManager.yml - PR Workflow Automation

**Purpose:** Automated PR management and testing

**Features:**
- Node.js testing for PR manager code
- Only runs when PR manager files change
- Fast feedback loop

#### 4. translations.yml - Automated i18n

**Purpose:** Extract and update translation strings

**Workflow:**
1. Install Open Social
2. Extract translation strings with custom tool
3. Compare with existing translations
4. Create PR with changes if found

**Key Features:**
- Automatic translation template updates
- Diff summary in PR description
- Runs on main branch push only

### Docker Images

**Custom Images Used:**
- `goalgorilla/open_social_docker:ci-drupal10-php8.3-v2` - Main CI image
- `ghcr.io/goalgorilla/ci-solr:8.11` - Solr search
- `kingdutch/social-docker-chrome` - Chrome for Behat

**Benefits:**
- Consistent environment
- Pre-configured with all dependencies
- Fast startup time

### Strengths

1. **Comprehensive Update Testing**
   - Tests upgrade from previous major version
   - Critical for production stability
   - Catches breaking changes early

2. **Database Isolation**
   - Each test gets clean database
   - No test pollution
   - Reproducible failures

3. **Dynamic Scaling**
   - Automatically discovers new features
   - No workflow updates needed
   - Scales with test growth

4. **Custom Validations**
   - Enforces architectural decisions
   - Prevents anti-patterns
   - Team-specific rules

5. **Matrix Testing**
   - Tests all combinations
   - Finds edge cases
   - Comprehensive coverage

### Weaknesses

1. **High Resource Usage**
   - ~120 parallel jobs
   - Expensive on paid CI
   - Long queue times on free tier

2. **Complex Setup**
   - Steep learning curve
   - Hard to debug locally
   - Requires deep GitHub Actions knowledge

3. **Tightly Coupled to GitHub**
   - Can't easily switch CI providers
   - No local execution option
   - GitHub-specific features

4. **No Code Quality Tools**
   - No PHPStan, PHPCS by default
   - Only custom checks
   - Missing standard linting

## Varbase Analysis

### CI/CD Architecture

**Platforms:**
- CircleCI (primary)
- GitLab CI (templates available)

**Repository:** https://github.com/vardot/varbase

### Configuration Files

#### 1. .circleci/config.yml - Main CI Pipeline

**Approach:** Full environment setup in VM (not containers)

**Setup Steps:**
1. Install system dependencies (50+ packages)
2. Install Apache + PHP 8.4
3. Install and configure MySQL
4. Install Chrome + ChromeDriver
5. Install Java (for Selenium)
6. Install Composer + Node.js + Yarn
7. Build Varbase with Composer
8. Configure Apache virtual host
9. Install site with Drush
10. Configure testing environment
11. Run Behat tests

**Test Organization:**
```yaml
jobs:
  varbase-testing-01-website-base-requirements:
    # Tests: Installation, homepage, admin access, etc.

  varbase-testing-02-user-management:
    # Tests: User creation, roles, permissions, etc.

  varbase-testing-03-admin-management:
    # Tests: Content management, config, etc.

  varbase-testing-04-content-structure:
    # Tests: Content types, fields, taxonomies, etc.

  varbase-testing-05-content-management:
    # Tests: Creating/editing content, media, etc.
```

**Each Job:**
- Runs full varbase-build command
- Fresh install every time
- Runs subset of Behat tests
- 30-minute timeout
- Independent and parallel

**Configuration Details:**
```bash
# PHP Configuration
memory_limit = -1
max_execution_time = 1200
max_input_vars = 10000
post_max_size = 64M
upload_max_filesize = 32M

# Drupal Installation
drush site-install varbase --yes \
  --account-name="webmaster" \
  --account-pass="dD.123123ddd" \
  --db-url="mysql://root:rootpw@127.0.0.1/test_varbase" \
  varbase_multilingual_configuration.enable_multilingual=true \
  varbase_extra_components.varbase_demo=true \
  # ... many more components

# Disable Antibot for testing
drush pm:uninstall antibot --yes

# Disable CSS/JS aggregation for debugging
drush config:set system.performance css.preprocess 0 --yes
drush config:set system.performance js.preprocess 0 --yes
```

**Workflow Filtering:**
```yaml
workflows:
  varbase-workflow:
    jobs:
      - varbase-testing-01-*:
          filters:
            tags:
              only: /^10.1.*/
            branches:
              only: /^10.1.x/
```

**Key Characteristics:**
- Branch-specific workflows
- Tag-based releases
- Only runs on stable branch

#### 2. build.xml - Phing Build Automation

**Purpose:** Phing (PHP build tool, like Ant) for common tasks

**Available Targets:**
```xml
<target name="env">
  <!-- Find tools: drush, composer, npm, rsync -->

<target name="push">
  <!-- Sync profile to Drupal installation -->
  <!-- Useful for active development -->

<target name="pull">
  <!-- Sync from Drupal installation back to profile -->
  <!-- Useful for extracting changes -->

<target name="code-quality-check">
  <!-- Run phpqa (PHP Quality Assurance tools) -->

<target name="preinstall">
  <!-- Prepare for UI installation -->
  <!-- Copy settings.php, create files dir -->

<!-- Additional targets for install, test, etc. -->
```

**Usage:**
```bash
# Run code quality checks
vendor/bin/phing code-quality-check

# Sync profile to installation
vendor/bin/phing push

# Pull changes back
vendor/bin/phing pull
```

**Benefits:**
- Reusable build commands
- Standardized workflows
- Platform-agnostic (runs locally and CI)

#### 3. package.json - npm Scripts

**Purpose:** JavaScript/CSS tooling and code quality

**Available Scripts:**
```json
{
  "scripts": {
    "phpcs": "phpcs --standard=./.phpcs.xml .",
    "phpcbf": "phpcbf --standard=./.phpcs.xml .",
    "lint:js": "eslint .",
    "lint:css": "stylelint \"**/*.css\"",
    "lint:yaml": "eslint --ext .yml .",
    "spellcheck": "cspell lint ."
  }
}
```

**Usage:**
```bash
# Check PHP code style
yarn phpcs

# Fix PHP code style
yarn phpcbf

# Lint JavaScript
yarn lint:js

# Lint CSS
yarn lint:css

# Lint YAML
yarn lint:yaml

# Spell check
yarn spellcheck
```

**Code Quality Tools:**
- **PHPCS/PHPCBF:** Drupal coding standards
- **ESLint:** JavaScript linting (.eslintrc.json)
- **Stylelint:** CSS linting (.stylelintrc.json)
- **CSpell:** Spell checking (.cspell.json)
- **Prettier:** Code formatting (.prettierrc.json)

#### 4. Testing Scripts

**scripts/add-testing-users.sh:**
```bash
# Creates test users via Drush
# Different roles: authenticated, editor, content_admin, etc.
# Used in CI for Behat tests
```

**scripts/delete-testing-users.sh:**
```bash
# Cleanup test users
# Useful for local development
```

### Strengths

1. **Comprehensive Code Quality**
   - PHPCS for Drupal standards
   - ESLint for JavaScript
   - Stylelint for CSS
   - Spell checking
   - Multiple linters

2. **Organized Test Groups**
   - Logical feature grouping
   - Easy to understand
   - Clear test ownership
   - Manageable test runs

3. **Build Automation**
   - Phing for PHP tasks
   - npm for JS/CSS tasks
   - Reusable locally and CI
   - Standardized commands

4. **Multi-Platform Support**
   - CircleCI configuration
   - GitLab templates available
   - Not locked to one provider
   - Migration flexibility

5. **Development Tools**
   - Testing user management
   - Profile sync (push/pull)
   - Local development helpers
   - Team productivity

### Weaknesses

1. **Heavy Environment Setup**
   - 50+ system packages
   - Long build times (~10-15 min)
   - Resource intensive
   - Expensive on CI

2. **No Update Testing**
   - Only fresh installs
   - No upgrade path validation
   - Risky for production updates
   - Missing critical tests

3. **Repetitive Builds**
   - Each job rebuilds everything
   - No caching between jobs
   - Inefficient resource use
   - Slow feedback

4. **Complex Dependencies**
   - Many moving parts
   - Hard to reproduce locally
   - Fragile setup scripts
   - High maintenance

## Feature Comparison Matrix

### Testing Approach

| Feature | OpenSocial | Varbase | Best for NWP |
|---------|-----------|---------|--------------|
| **Fresh Install Testing** | ✅ Yes | ✅ Yes | ✅ Essential |
| **Update Path Testing** | ✅ Yes (from previous major) | ❌ No | ✅ Critical for NWP |
| **Optional Modules Testing** | ✅ Yes (matrix) | ✅ Yes (all enabled) | ✅ Useful |
| **Test Isolation** | ✅ Database snapshots | ⚠️ Fresh install per group | ✅ Database snapshots |
| **Parallel Execution** | ✅ Feature-level | ✅ Group-level | ✅ Hybrid |
| **Dynamic Discovery** | ✅ Auto-finds features | ❌ Manual config | ⚠️ Optional |

### Code Quality

| Tool | OpenSocial | Varbase | Best for NWP |
|------|-----------|---------|--------------|
| **PHPStan** | ❌ No | ❌ No | ✅ Add (NWP has it!) |
| **PHPCS** | ❌ No | ✅ Yes | ✅ Essential |
| **ESLint** | ❌ No | ✅ Yes | ⚠️ If using JS |
| **Stylelint** | ❌ No | ✅ Yes | ⚠️ If using CSS |
| **Custom Rules** | ✅ Best practices | ❌ No | ⚠️ For mature projects |
| **Spell Check** | ❌ No | ✅ Yes | ⚠️ Nice to have |

### Build Tools

| Aspect | OpenSocial | Varbase | Best for NWP |
|--------|-----------|---------|--------------|
| **Build System** | Bash scripts | Phing + npm | **Makefile + npm** |
| **Local Execution** | ❌ Hard | ✅ Easy | ✅ Essential |
| **Reusability** | ❌ CI-specific | ✅ Local + CI | ✅ Essential |
| **Complexity** | Low | Medium | **Low (Makefile)** |
| **Maintainability** | Medium | Medium | **High (Makefile)** |

### Infrastructure

| Aspect | OpenSocial | Varbase | Best for NWP |
|--------|-----------|---------|--------------|
| **Environment** | Docker containers | VM with full stack | **DDEV (existing)** |
| **Setup Time** | Fast (~2 min) | Slow (~10 min) | **Fast with DDEV** |
| **Resource Usage** | Low per job | High per job | **Low (containers)** |
| **Reproducibility** | High | Medium | **High (DDEV)** |
| **Debugging** | Medium | Hard | **Easy (local DDEV)** |

## Recommendations for NWP

### Core Recommendations

#### 1. Use GitHub Actions (like OpenSocial)

**Rationale:**
- ✅ Already using GitHub for NWP
- ✅ Free for public repos (2,000 min/month for private)
- ✅ Good documentation and community
- ✅ Tight integration with GitHub features
- ✅ Marketplace with reusable actions

**Advantages over CircleCI:**
- No additional account needed
- Unified workflow in GitHub
- Better for open source

#### 2. Adopt Hybrid Testing Strategy

**Combine best of both approaches:**

```yaml
# From OpenSocial:
- Matrix testing (install vs update)
- Database snapshots for isolation
- Dynamic feature discovery (if needed)

# From Varbase:
- Organized test groups
- npm scripts for code quality
- Clear job naming

# From NWP existing:
- DDEV for environment
- testos.sh for test execution
- PHPStan static analysis
```

**Example Workflow Structure:**
```yaml
jobs:
  code-quality:
    # PHP: PHPStan, PHPCS
    # JS: ESLint (if applicable)
    # YAML: yamllint

  install-test:
    # Fresh install + all tests
    # Matrix: with/without optional modules

  update-test:
    # Install previous version
    # Update to current
    # Run all tests

  behat-tests:
    # Parallel execution by feature group
    # Use database snapshots
```

#### 3. Use Makefile + npm Scripts (Hybrid Build System)

**Makefile for PHP/Drupal tasks:**
```makefile
.PHONY: install test lint ci

install:
	ddev composer install

test:
	./testos.sh -a

lint:
	./testos.sh -p
	./testos.sh -c

ci: install lint test
```

**package.json for code quality:**
```json
{
  "scripts": {
    "phpcs": "phpcs --standard=Drupal,DrupalPractice",
    "phpcbf": "phpcbf --standard=Drupal,DrupalPractice",
    "phpstan": "./testos.sh -p",
    "test": "./testos.sh -a",
    "lint": "yarn phpcs && yarn phpstan"
  }
}
```

**Benefits:**
- Simple and familiar (Make is standard)
- Works locally and CI
- Easy to understand and modify
- No complex build tool needed

#### 4. Leverage Existing NWP Infrastructure

**Keep what's working:**
- ✅ DDEV for local and CI environments
- ✅ testos.sh for test orchestration
- ✅ PHPStan for static analysis
- ✅ Behat for functional testing
- ✅ dev2stg.sh deployment workflow

**Enhance with:**
- ✅ GitHub Actions workflows
- ✅ PHPCS for coding standards
- ✅ Update path testing
- ✅ Automated security updates

#### 5. Implement Update Path Testing (Critical!)

**Why it matters for NWP:**
- Multiple environments (dev, stg, prod)
- Need to validate updates before production
- Drupal updates can break sites
- Security updates must be tested

**Implementation:**
```yaml
jobs:
  test-update-path:
    steps:
      - name: Install previous version
        run: |
          # Install from previous tag
          composer require goalgorilla/open_social:~12.0
          drush site-install social

      - name: Create database snapshot
        run: drush sql-dump > pre-update.sql

      - name: Update to current
        run: |
          composer require goalgorilla/open_social:dev-main
          drush updatedb -y

      - name: Run tests
        run: ./testos.sh -a
```

### Implementation Priorities

#### Phase 1: Foundation (Week 1-2)
✅ **Priority: HIGH**

1. Create GitHub Actions workflow
2. Add PHPCS configuration
3. Set up code quality job
4. Configure npm scripts

**Deliverables:**
- `.github/workflows/ci.yml`
- `.phpcs.xml`
- `package.json` with scripts
- Updated documentation

#### Phase 2: Testing (Week 3-4)
✅ **Priority: HIGH**

1. Add Behat testing job
2. Implement database snapshots
3. Add update path testing
4. Configure test matrix

**Deliverables:**
- Behat workflow in GitHub Actions
- Update testing script
- Test database management
- Matrix strategy configuration

#### Phase 3: Automation (Week 5-6)
✅ **Priority: MEDIUM**

1. Automated security updates (from CICD.md)
2. Deployment automation
3. Notifications (Slack/email)
4. Performance monitoring

**Deliverables:**
- Security update workflow
- Deployment automation
- Notification system
- Monitoring dashboards

#### Phase 4: Optimization (Ongoing)
✅ **Priority: LOW**

1. Caching strategies
2. Parallel optimization
3. Custom validations
4. Advanced features

## Example Configurations

### Example 1: GitHub Actions Workflow for NWP

**File: `.github/workflows/ci.yml`**

```yaml
name: CI

on:
  pull_request: {}
  push:
    branches:
      - main
      - develop

# Cancel in-progress runs for PRs
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: ${{ github.head_ref != '' }}

env:
  # Use current branch or PR source branch
  BRANCH_NAME: ${{ github.head_ref || github.ref_name }}

jobs:
  code-quality:
    name: Code Quality
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v4

      - name: Setup PHP
        uses: shivammathur/setup-php@v2
        with:
          php-version: '8.2'
          tools: composer:v2

      - name: Setup DDEV
        uses: ddev/github-action-setup-ddev@v1

      - name: Install npm dependencies
        run: npm ci

      - name: PHPCS
        run: npm run phpcs

      - name: PHPStan
        run: ./testos.sh -p

      - name: CodeSniffer
        run: ./testos.sh -c

  behat-tests:
    name: Behat Tests
    runs-on: ubuntu-latest
    needs: code-quality

    strategy:
      fail-fast: false
      matrix:
        test-group:
          - basic
          - content
          - users
          - workflow

    steps:
      - uses: actions/checkout@v4

      - name: Setup DDEV
        uses: ddev/github-action-setup-ddev@v1

      - name: Install site
        run: |
          ./install.sh nwp -y

      - name: Run Behat tests
        run: |
          cd nwp
          ../testos.sh -b

      - name: Upload artifacts on failure
        if: failure()
        uses: actions/upload-artifact@v3
        with:
          name: behat-output-${{ matrix.test-group }}
          path: nwp/tests/behat/logs/

  update-path-test:
    name: Update Path Testing
    runs-on: ubuntu-latest
    needs: code-quality

    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0  # Need full history for previous versions

      - name: Setup DDEV
        uses: ddev/github-action-setup-ddev@v1

      - name: Install previous version
        run: |
          # Get previous tag
          PREVIOUS_TAG=$(git describe --tags --abbrev=0 HEAD^)
          git checkout $PREVIOUS_TAG
          ./install.sh nwp -y

      - name: Create database snapshot
        run: |
          cd nwp
          ddev drush sql-dump > pre-update.sql

      - name: Update to current version
        run: |
          git checkout ${{ env.BRANCH_NAME }}
          cd nwp
          ddev composer install
          ddev drush updatedb -y
          ddev drush cr

      - name: Run tests after update
        run: |
          cd nwp
          ../testos.sh -a

      - name: Upload database on failure
        if: failure()
        uses: actions/upload-artifact@v3
        with:
          name: update-test-database
          path: nwp/pre-update.sql
```

### Example 2: Enhanced Makefile

**File: `Makefile`**

```makefile
.PHONY: help install test lint ci clean update deploy

# Default target
.DEFAULT_GOAL := help

# Colors for output
BLUE := \033[0;34m
GREEN := \033[0;32m
RED := \033[0;31m
NC := \033[0m # No Color

help: ## Show this help message
	@echo "$(BLUE)NWP Makefile Commands:$(NC)"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(GREEN)%-20s$(NC) %s\n", $$1, $$2}'

install: ## Install a new NWP instance
	@echo "$(BLUE)Installing NWP...$(NC)"
	./install.sh nwp

test: ## Run all tests
	@echo "$(BLUE)Running all tests...$(NC)"
	./testos.sh -a

test-behat: ## Run Behat tests only
	@echo "$(BLUE)Running Behat tests...$(NC)"
	./testos.sh -b

test-phpunit: ## Run PHPUnit tests only
	@echo "$(BLUE)Running PHPUnit tests...$(NC)"
	./testos.sh -u

lint: ## Run linting (PHPStan + CodeSniffer)
	@echo "$(BLUE)Running linters...$(NC)"
	./testos.sh -p
	./testos.sh -c

lint-fix: ## Fix auto-fixable linting issues
	@echo "$(BLUE)Fixing code style issues...$(NC)"
	yarn phpcbf

phpstan: ## Run PHPStan static analysis
	@echo "$(BLUE)Running PHPStan...$(NC)"
	./testos.sh -p

phpcs: ## Run PHP CodeSniffer
	@echo "$(BLUE)Running PHPCS...$(NC)"
	yarn phpcs

ci: install lint test ## Run full CI pipeline locally
	@echo "$(GREEN)✓ All CI checks passed!$(NC)"

clean: ## Clean up build artifacts
	@echo "$(BLUE)Cleaning up...$(NC)"
	rm -rf vendor/ node_modules/ .ddev/.global_commands/

update: ## Update dependencies
	@echo "$(BLUE)Updating dependencies...$(NC)"
	ddev composer update
	yarn install

backup: ## Create backup of current site
	@echo "$(BLUE)Creating backup...$(NC)"
	./backup.sh -y nwp

restore: ## Restore latest backup
	@echo "$(BLUE)Restoring backup...$(NC)"
	./restore.sh -fy nwp

deploy-staging: ## Deploy to staging
	@echo "$(BLUE)Deploying to staging...$(NC)"
	./dev2stg.sh -y nwp

watch: ## Watch for changes and run quick tests
	@echo "$(BLUE)Watching for changes...$(NC)"
	@while true; do \
		inotifywait -q -e modify -r web/modules/custom/ 2>/dev/null && \
		make phpstan; \
	done
```

**Usage:**
```bash
make help          # Show all commands
make ci            # Run full CI pipeline
make test          # Run all tests
make lint          # Run linters
make deploy-staging  # Deploy to staging
```

### Example 3: package.json for NWP

**File: `package.json`**

```json
{
  "name": "nwp",
  "version": "1.0.0",
  "description": "Narrow Way Project - Drupal/Moodle Installation System",
  "private": true,
  "scripts": {
    "phpcs": "phpcs --standard=Drupal,DrupalPractice --extensions=php,module,inc,install,test,profile,theme,css,info,txt,md,yml web/modules/custom",
    "phpcbf": "phpcbf --standard=Drupal,DrupalPractice --extensions=php,module,inc,install,test,profile,theme,css,info,txt,md,yml web/modules/custom",
    "phpstan": "./testos.sh -p",
    "codesniffer": "./testos.sh -c",
    "behat": "./testos.sh -b",
    "phpunit": "./testos.sh -u",
    "test": "./testos.sh -a",
    "test:quick": "./testos.sh -p",
    "lint": "npm run phpcs && npm run phpstan",
    "lint:fix": "npm run phpcbf",
    "ci": "npm run lint && npm run test"
  },
  "devDependencies": {
    "cspell": "^8.0.0"
  },
  "engines": {
    "node": ">=18.0.0",
    "npm": ">=9.0.0"
  }
}
```

**Usage:**
```bash
npm run lint       # Run all linters
npm run lint:fix   # Fix code style
npm test           # Run all tests
npm run test:quick # Quick validation
npm run ci         # Full CI
```

### Example 4: PHPCS Configuration

**File: `.phpcs.xml`**

```xml
<?xml version="1.0"?>
<ruleset name="NWP">
  <description>PHP CodeSniffer configuration for NWP</description>

  <!-- What to scan -->
  <file>web/modules/custom</file>
  <file>web/themes/custom</file>

  <!-- How to scan -->
  <arg name="extensions" value="php,module,inc,install,test,profile,theme,css,info,txt,md,yml"/>
  <arg name="colors"/>
  <arg value="sp"/> <!-- Show sniff codes and progress -->

  <!-- Use Drupal and DrupalPractice Standards -->
  <rule ref="Drupal"/>
  <rule ref="DrupalPractice"/>

  <!-- Exclude third-party code -->
  <exclude-pattern>*/vendor/*</exclude-pattern>
  <exclude-pattern>*/node_modules/*</exclude-pattern>
  <exclude-pattern>*/contrib/*</exclude-pattern>

  <!-- Ignore specific rules if needed -->
  <!-- <rule ref="Drupal.Commenting.FunctionComment.Missing">
    <severity>0</severity>
  </rule> -->
</ruleset>
```

## Summary: Best Practices for NWP

### 1. Start Simple, Scale Up

**Phase 1 (Week 1-2):**
- GitHub Actions with basic workflow
- Code quality checks (PHPCS, PHPStan)
- Behat tests on fresh install

**Phase 2 (Week 3-4):**
- Matrix testing (with/without optional)
- Update path testing
- Database snapshots

**Phase 3 (Month 2+):**
- Automated security updates
- Custom validations
- Performance testing

### 2. Hybrid Approach Works Best

**Take from OpenSocial:**
- GitHub Actions platform
- Matrix testing strategy
- Update path validation
- Database snapshot isolation

**Take from Varbase:**
- npm scripts for code quality
- Organized test grouping
- Build automation (Phing → Makefile)
- Multi-platform flexibility

**Keep from NWP:**
- DDEV environment
- testos.sh orchestration
- Existing test infrastructure
- Management scripts

### 3. Prioritize What Matters

**Must Have (Phase 1):**
- ✅ Code quality checks (PHPCS, PHPStan)
- ✅ Automated testing on every commit
- ✅ Fast feedback (<5 min for basic checks)

**Should Have (Phase 2):**
- ✅ Update path testing
- ✅ Matrix testing
- ✅ Database snapshots

**Nice to Have (Phase 3):**
- ✅ Automated security updates
- ✅ Custom validations
- ✅ Advanced monitoring

### 4. Make it Reproducible

**Local = CI:**
- Same DDEV environment
- Same test commands
- Same validation tools
- Easy debugging

**Key Principle:**
> "If it doesn't work locally, don't run it in CI"

### 5. Document Everything

**For each workflow:**
- What it does
- When it runs
- How to run locally
- How to debug failures

**For each script:**
- Purpose
- Usage examples
- Common issues
- Troubleshooting

## Next Steps

1. **Review CICD.md** for detailed implementation guide
2. **Choose Phase 1 tasks** from recommendations
3. **Create GitHub Actions workflow** using examples
4. **Test locally** with Make and npm scripts
5. **Iterate and improve** based on results

---

**Need Help?**
- See [CICD.md](CICD.md) for implementation details
- Check examples above for starting points
- Start simple and add complexity as needed
- Test everything locally first!
