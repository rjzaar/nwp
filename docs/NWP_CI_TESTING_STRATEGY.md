# NWP CI/CD and Testing Strategy

**Document Version:** 1.0
**Date:** December 30, 2024
**Purpose:** Comprehensive CI/CD and testing strategy for NWP with implementation proposals for an NWP-created GitLab instance

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Research Findings](#2-research-findings)
3. [Test Architecture](#3-test-architecture)
4. [Behat Testing Framework](#4-behat-testing-framework)
5. [GitLab CI Implementation](#5-gitlab-ci-implementation)
6. [Local Development Testing](#6-local-development-testing)
7. [Remote Site Testing](#7-remote-site-testing)
8. [Badge and Reporting Configuration](#8-badge-and-reporting-configuration)
9. [NWP Integration](#9-nwp-integration)
10. [Implementation Proposals](#10-implementation-proposals)

---

## 1. Executive Summary

### Objective

Design a comprehensive CI/CD and testing strategy for NWP that enables:
- Running tests locally during development
- Running tests on provisioned staging/production sites
- Running tests through an NWP-created GitLab instance
- Displaying passing badges on repositories

### Key Findings Summary

| Aspect | Vortex (Enterprise) | Pleasy (Lightweight) | NWP Recommendation |
|--------|---------------------|----------------------|---------------------|
| CI Provider | CircleCI + GitHub Actions | GitHub Actions | GitLab CI (self-hosted) |
| Container Strategy | Full Docker Compose | Script-based | Docker Compose |
| Unit/Kernel/Functional | PHPUnit (all suites) | Bash scripts | PHPUnit (all suites) |
| BDD Testing | Behat + Selenium | None | Behat + Chrome |
| Code Quality | 7 tools (PHPCS, PHPStan, etc.) | Minimal | PHPCS, PHPStan, Rector |
| Parallelization | 2-instance matrix | None | 2+ parallel runners |
| Coverage | Codecov + 90% threshold | None | GitLab native + badges |
| Database Caching | Timestamp + fallback | Per-run | Timestamp + fallback |

---

## 2. Research Findings

### 2.1 Codebases Analyzed

| Codebase | Location | Type |
|----------|----------|------|
| Vortex | `/home/rob/tmp/vortex/` | Enterprise Drupal template |
| Pleasy | `/home/rob/tmp/pleasy/` | Lightweight development tool |

### 2.2 Vortex CI/CD Patterns

**Key Configuration Files:**
- `.circleci/config.yml` - CircleCI pipeline (800 lines)
- `.github/workflows/build-test-deploy.yml` - GitHub Actions
- `behat.yml` - BDD test configuration
- `phpunit.xml` - Unit/Kernel/Functional test configuration
- `docker-compose.yml` - Container orchestration

**CI Infrastructure Highlights:**

```yaml
# From Vortex CircleCI - Key patterns
aliases:
  - &runner_config
    docker:
      - image: drevops/ci-runner:25.11.0
    environment:
      VORTEX_CI_DB_CACHE_TIMESTAMP: +%Y%m%d      # Daily cache
      VORTEX_CI_DB_CACHE_FALLBACK: "yes"         # Use previous day
      VORTEX_CI_TEST_RESULTS: /tmp/tests
      VORTEX_CI_CODE_COVERAGE_THRESHOLD: 90

jobs:
  build:
    parallelism: 2  # Parallel test execution
```

**Code Quality Tools (7 total):**

| Tool | Purpose | Config File |
|------|---------|-------------|
| PHPCS | Drupal coding standards | `.phpcs.xml` |
| PHPStan | Static analysis (level 7) | `phpstan.neon` |
| Rector | Automated refactoring | `rector.php` |
| PHPMD | Mess detection | `phpmd.xml` |
| Twig CS Fixer | Template linting | Integrated |
| Gherkin Lint | BDD feature validation | Integrated |
| ESLint/Stylelint | JS/CSS linting | npm config |

**Database Caching Strategy:**
- Cache key: `v25.11.0-db11-{branch}-{fallback}-{timestamp}`
- Daily invalidation with previous-day fallback
- Supports: URL, container registry, Acquia, FTP, Lagoon

### 2.3 Pleasy CI Patterns

Simpler approach focused on basic validation:
- GitHub Actions with `ubuntu-latest`
- Composer-based workflow (init → update → install)
- Script-based testing via `test.sh`, `testsite.sh`
- No parallelization or coverage reporting

### 2.4 Industry Best Practices (2025)

From GitLab CI Drupal templates and industry research:

**Pipeline Structure:**
- Three stages: `build`, `validate`, `test`
- Skip/opt-in variables for flexibility
- Parallel PHPUnit via test splitting

**Key Recommendations:**
1. Create isolated CI environments (teardown after pipeline)
2. Use PHPUnit for unit testing, Behat for BDD
3. Integrate security scanning (Drupal-Check, PHPStan)
4. Target 80-90% code coverage threshold

**Documented Results:**
- Deployment time: 6 hours → 30 minutes
- Test coverage: +40% increase
- Downtime: <1% across quarterly releases

---

## 3. Test Architecture

### 3.1 Test Types and Execution Layers

| Test Type | Local Dev | Provisioned Site | GitLab CI | Speed | DB Required |
|-----------|-----------|------------------|-----------|-------|-------------|
| Unit Tests | Always | No | Always | Fast | No |
| Code Linting | Always | No | Always | Fast | No |
| Kernel Tests | Optional | Yes | Always | Medium | Yes |
| Functional Tests | Optional | Yes | Always | Slow | Yes |
| Behat @api | Targeted | Yes | Always | Medium | Yes |
| Behat @javascript | Targeted | Full | Full | Slow | Yes + Chrome |
| Visual Regression | No | Optional | Full | Slow | Yes + Chrome |

### 3.2 Execution Flow Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                      TEST EXECUTION ARCHITECTURE                    │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  LAYER 1: LOCAL DEVELOPMENT                                         │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  Developer Workstation                                       │   │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────────┐ │   │
│  │  │ Lint     │  │ Unit     │  │ Smoke    │  │ Targeted     │ │   │
│  │  │ (always) │  │ (always) │  │ (before  │  │ Feature      │ │   │
│  │  │          │  │          │  │  push)   │  │ (on change)  │ │   │
│  │  └──────────┘  └──────────┘  └──────────┘  └──────────────┘ │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                              │                                      │
│                              ▼                                      │
│  LAYER 2: GITLAB CI (MERGE REQUEST)                                │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  ┌───────┐   ┌──────────────────┐   ┌────────────────────┐  │   │
│  │  │ BUILD │──▶│     VALIDATE     │──▶│       TEST         │  │   │
│  │  │       │   │ PHPCS, PHPStan   │   │ Unit, Kernel       │  │   │
│  │  │       │   │ Rector, Gherkin  │   │ Functional, Smoke  │  │   │
│  │  └───────┘   └──────────────────┘   └────────────────────┘  │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                              │                                      │
│                              ▼                                      │
│  LAYER 3: GITLAB CI (MAIN BRANCH / NIGHTLY)                        │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  Full Test Suite + Parallel Behat (2 runners)               │   │
│  │  Coverage Threshold Enforcement (80%)                        │   │
│  │  Badge Updates (Pipeline + Coverage)                         │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                              │                                      │
│                              ▼                                      │
│  LAYER 4: REMOTE SITE TESTING (Optional)                           │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  Staging/Production Smoke Tests via Drush Aliases           │   │
│  │  Read-only tests only for production                         │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### 3.3 Docker Service Stack

```yaml
services:
  cli:        # PHP CLI - runs tests, drush, composer
  nginx:      # Web server (port 8080)
  php:        # PHP-FPM for web requests
  database:   # MariaDB/MySQL
  chrome:     # Selenium Chrome for @javascript tests
  redis:      # Optional caching
  solr:       # Optional search
```

---

## 4. Behat Testing Framework

### 4.1 Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                      BEHAT TEST EXECUTION                           │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│   Behat CLI ──▶ Feature Files ──▶ Step Definitions                 │
│       │              │                    │                         │
│       │              │                    ▼                         │
│       │              │         ┌─────────────────────┐              │
│       │              │         │ FeatureContext.php  │              │
│       │              │         │ + DrevOps\BehatSteps│              │
│       │              │         └─────────────────────┘              │
│       │              │                    │                         │
│       ▼              ▼                    ▼                         │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                    MINK DRIVER                               │   │
│  │  ┌─────────────┐        ┌──────────────────────────────┐    │   │
│  │  │ @api tests  │        │ @javascript tests            │    │   │
│  │  │ BrowserKit  │        │ Selenium2 → Chrome Container │    │   │
│  │  │ (headless)  │        │ (real browser)               │    │   │
│  │  └─────────────┘        └──────────────────────────────┘    │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                              │                                      │
│                              ▼                                      │
│                    DRUPAL SITE (nginx:8080)                        │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### 4.2 Test Tags

| Tag | Driver | Speed | Use Case |
|-----|--------|-------|----------|
| `@api` | BrowserKit (headless) | Fast | Content, permissions, drush |
| `@api @javascript` | Selenium + Chrome | Slow | JS interactions, AJAX |
| `@smoke` | Either | Variable | Critical path validation |
| `@p0` | Either | Variable | Parallel group 0 (catch-all) |
| `@p1` | Either | Variable | Parallel group 1 |
| `@skipped` | N/A | N/A | Disabled tests |
| `@destructive` | Either | Variable | Tests that modify data |

### 4.3 Example Feature File

```gherkin
@login @smoke
Feature: Login

  As a site administrator
  I want to log into the system
  So that I can access administrative functions

  @api
  Scenario: Administrator user logs in
    Given I am logged in as a user with the "administrator" role
    When I go to "admin"
    Then the path should be "/admin"
    And I save screenshot

  @api @javascript
  Scenario: Administrator user logs in using a real browser
    Given I am logged in as a user with the "administrator" role
    When I go to "admin"
    Then the path should be "/admin"
    And I save screenshot
```

### 4.4 Behat Configuration (behat.yml)

```yaml
default:
  autoload: ['%paths.base%/tests/behat/bootstrap']

  gherkin:
    cache: ~
    filters:
      tags: '~@skipped'

  suites:
    default:
      paths: ['%paths.base%/tests/behat/features']
      contexts:
        - FeatureContext
        - Drupal\DrupalExtension\Context\MinkContext
        - Drupal\DrupalExtension\Context\MarkupContext
        - Drupal\DrupalExtension\Context\MessageContext
        - Drupal\DrupalExtension\Context\DrushContext
        - DrevOps\BehatScreenshotExtension\Context\ScreenshotContext

  formatters:
    progress_fail: true
    junit:
      output_path: '%paths.base%/.logs/test_results/behat'

  extensions:
    Drupal\MinkExtension:
      browserkit_http: ~
      base_url: http://nginx:8080
      files_path: '%paths.base%/tests/behat/fixtures'
      browser_name: chrome
      javascript_session: selenium2
      selenium2:
        wd_host: 'http://chrome:4444/wd/hub'
        capabilities:
          browser: chrome
          extra_capabilities:
            'goog:chromeOptions':
              args:
                - '--disable-extensions'
                - '--disable-gpu'
                - '--no-first-run'
                - '--test-type'

    Drupal\DrupalExtension:
      blackbox: ~
      api_driver: drupal
      drush_driver: drush
      drupal:
        drupal_root: web
      drush:
        root: web
      region_map:
        header: '#header'
        content: '.region.region--content'
        sidebar: '.region.region--sidebar'
        footer: '.region.region--footer'
      selectors:
        login_form_selector: 'form#user-login,form#user-login-form'
        logged_in_selector: 'body.logged-in,body.user-logged-in'
        message_selector: '.messages'
        error_message_selector: '.messages.error,.messages.messages--error'
        success_message_selector: '.messages.status,.messages.messages--status'

    DrevOps\BehatScreenshotExtension:
      dir: '%paths.base%/.logs/screenshots'
      on_failed: true
      always_fullscreen: true

    DrevOps\BehatFormatProgressFail\FormatExtension: ~

# Parallel testing profiles
p0:
  gherkin:
    cache: '/tmp/behat_gherkin_cache'
    filters:
      tags: '@smoke,~@p1&&~@skipped'

p1:
  gherkin:
    cache: '/tmp/behat_gherkin_cache'
    filters:
      tags: '@smoke,@p1&&~@skipped'

# Remote site profiles
remote:
  extensions:
    Drupal\MinkExtension:
      base_url: https://dev.example.com
    Drupal\DrupalExtension:
      drush:
        alias: '@dev'

staging:
  extensions:
    Drupal\MinkExtension:
      base_url: https://staging.example.com
    Drupal\DrupalExtension:
      drush:
        alias: '@staging'
```

### 4.5 FeatureContext Template

```php
<?php

declare(strict_types=1);

use DrevOps\BehatSteps\ContentTrait;
use DrevOps\BehatSteps\CookieTrait;
use DrevOps\BehatSteps\Drupal\ContentTrait as DrupalContentTrait;
use DrevOps\BehatSteps\Drupal\EmailTrait;
use DrevOps\BehatSteps\Drupal\FileTrait;
use DrevOps\BehatSteps\Drupal\MediaTrait;
use DrevOps\BehatSteps\Drupal\TaxonomyTrait;
use DrevOps\BehatSteps\Drupal\UserTrait;
use DrevOps\BehatSteps\Drupal\WatchdogTrait;
use DrevOps\BehatSteps\ElementTrait;
use DrevOps\BehatSteps\FieldTrait;
use DrevOps\BehatSteps\LinkTrait;
use DrevOps\BehatSteps\PathTrait;
use DrevOps\BehatSteps\ResponseTrait;
use DrevOps\BehatSteps\WaitTrait;
use Drupal\DrupalExtension\Context\DrupalContext;

class FeatureContext extends DrupalContext {

  use ContentTrait;
  use CookieTrait;
  use DrupalContentTrait;
  use ElementTrait;
  use EmailTrait;
  use FieldTrait;
  use FileTrait;
  use LinkTrait;
  use MediaTrait;
  use PathTrait;
  use ResponseTrait;
  use TaxonomyTrait;
  use UserTrait;
  use WaitTrait;
  use WatchdogTrait;

}
```

---

## 5. GitLab CI Implementation

### 5.1 Complete `.gitlab-ci.yml`

```yaml
# .gitlab-ci.yml for NWP-created GitLab

variables:
  # Docker-in-Docker
  DOCKER_HOST: tcp://docker:2376
  DOCKER_TLS_CERTDIR: "/certs"
  DOCKER_DRIVER: overlay2

  # Database caching
  DB_CACHE_KEY: "${CI_COMMIT_REF_SLUG}"

  # Test configuration
  SIMPLETEST_BASE_URL: "http://nginx:8080"
  SIMPLETEST_DB: "mysql://drupal:drupal@database/drupal"

  # Thresholds
  CODE_COVERAGE_THRESHOLD: "80"

  # Skip flags (set to "1" to skip)
  SKIP_PHPCS: "0"
  SKIP_PHPSTAN: "0"
  SKIP_PHPUNIT: "0"
  SKIP_BEHAT: "0"

stages:
  - build
  - validate
  - test
  - deploy

# =============================================================================
# BASE TEMPLATES
# =============================================================================

.docker-stack:
  image: docker:24-cli
  services:
    - docker:24-dind
  before_script:
    - apk add --no-cache docker-compose bash curl
    # Process docker-compose for CI (remove host mounts)
    - sed -i -e '/###/d' -e 's/##//' docker-compose.yml
    - docker compose up -d
    - |
      echo "Waiting for services..."
      for i in $(seq 1 60); do
        docker compose exec -T cli drush status --field=bootstrap 2>/dev/null | grep -q "Successful" && break
        sleep 2
      done
    # Provision site
    - docker compose exec -T cli ./scripts/vortex/provision.sh
  after_script:
    - docker compose logs > docker-compose.log 2>&1 || true
  artifacts:
    when: always
    paths:
      - docker-compose.log
    expire_in: 1 day

# =============================================================================
# BUILD STAGE
# =============================================================================

build:
  stage: build
  image: composer:2
  script:
    - composer install --prefer-dist --no-progress --no-interaction
    - composer validate --strict
  cache:
    key: composer-${CI_COMMIT_REF_SLUG}
    paths:
      - vendor/
  artifacts:
    paths:
      - vendor/
    expire_in: 1 hour

# =============================================================================
# VALIDATE STAGE
# =============================================================================

phpcs:
  stage: validate
  needs: [build]
  image: php:8.3-cli
  script:
    - '[ "$SKIP_PHPCS" = "1" ] && exit 0'
    - vendor/bin/phpcs --standard=Drupal,DrupalPractice web/modules/custom web/themes/custom
  allow_failure: false

phpstan:
  stage: validate
  needs: [build]
  image: php:8.3-cli
  script:
    - '[ "$SKIP_PHPSTAN" = "1" ] && exit 0'
    - vendor/bin/phpstan analyse --memory-limit=-1
  allow_failure: false

rector:
  stage: validate
  needs: [build]
  image: php:8.3-cli
  script:
    - vendor/bin/rector --dry-run --clear-cache
  allow_failure: true

lint:gherkin:
  stage: validate
  needs: [build]
  image: php:8.3-cli
  script:
    - vendor/bin/gherkinlint lint tests/behat/features
  rules:
    - exists:
        - tests/behat/features/**/*.feature

# =============================================================================
# TEST STAGE - PHPUNIT
# =============================================================================

phpunit:unit:
  stage: test
  needs: [build]
  image: php:8.3-cli
  script:
    - '[ "$SKIP_PHPUNIT" = "1" ] && exit 0'
    - vendor/bin/phpunit --testsuite=unit --coverage-cobertura=coverage.xml --log-junit=phpunit.xml
  coverage: '/^\s*Lines:\s*\d+.\d+\%/'
  artifacts:
    when: always
    paths:
      - coverage.xml
    reports:
      junit: phpunit.xml
      coverage_report:
        coverage_format: cobertura
        path: coverage.xml

phpunit:kernel:
  extends: .docker-stack
  stage: test
  needs: [build]
  script:
    - docker compose exec -T cli vendor/bin/phpunit --testsuite=kernel --log-junit=.logs/phpunit.xml
  artifacts:
    when: always
    reports:
      junit: .logs/phpunit.xml

phpunit:functional:
  extends: .docker-stack
  stage: test
  needs: [build]
  script:
    - docker compose exec -T cli vendor/bin/phpunit --testsuite=functional --log-junit=.logs/phpunit.xml
  artifacts:
    when: always
    reports:
      junit: .logs/phpunit.xml

# =============================================================================
# TEST STAGE - BEHAT
# =============================================================================

behat:smoke:
  extends: .docker-stack
  stage: test
  needs: [build, lint:gherkin]
  script:
    - '[ "$SKIP_BEHAT" = "1" ] && exit 0'
    - |
      docker compose exec -T cli vendor/bin/behat \
        --tags=@smoke \
        --colors \
        --format=pretty --out=std \
        --format=junit --out=.logs/behat
  artifacts:
    when: always
    paths:
      - .logs/screenshots/
    reports:
      junit: .logs/behat/*.xml
  rules:
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
    - if: $CI_COMMIT_TAG

behat:api:
  extends: .docker-stack
  stage: test
  needs: [build, lint:gherkin]
  script:
    - '[ "$SKIP_BEHAT" = "1" ] && exit 0'
    - |
      docker compose exec -T cli vendor/bin/behat \
        --tags="@api&&~@javascript&&~@smoke" \
        --colors \
        --format=junit --out=.logs/behat
  artifacts:
    when: always
    reports:
      junit: .logs/behat/*.xml
  rules:
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH

behat:javascript:
  extends: .docker-stack
  stage: test
  needs: [build, lint:gherkin]
  script:
    - '[ "$SKIP_BEHAT" = "1" ] && exit 0'
    # Wait for Chrome
    - |
      for i in $(seq 1 30); do
        docker compose exec -T cli curl -s http://chrome:4444/wd/hub/status 2>/dev/null | grep -q '"ready":true' && break
        sleep 2
      done
    - |
      docker compose exec -T cli php -d memory_limit=-1 vendor/bin/behat \
        --tags=@javascript \
        --colors \
        --format=junit --out=.logs/behat
  artifacts:
    when: always
    paths:
      - .logs/screenshots/
    reports:
      junit: .logs/behat/*.xml
  allow_failure: true
  rules:
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH

behat:full:
  extends: .docker-stack
  stage: test
  needs: [build, lint:gherkin]
  parallel: 2
  script:
    - '[ "$SKIP_BEHAT" = "1" ] && exit 0'
    - |
      PROFILE="p${CI_NODE_INDEX:-0}"
      echo "Running Behat with profile: $PROFILE"
      docker compose exec -T cli php -d memory_limit=-1 vendor/bin/behat \
        --profile=$PROFILE \
        --colors \
        --format=junit --out=.logs/behat \
        || docker compose exec -T cli vendor/bin/behat --profile=$PROFILE --rerun
  artifacts:
    when: always
    paths:
      - .logs/screenshots/
    reports:
      junit: .logs/behat/*.xml
  rules:
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
    - if: $CI_PIPELINE_SOURCE == "schedule"

# =============================================================================
# COVERAGE CHECK
# =============================================================================

coverage:check:
  stage: test
  needs: [phpunit:unit]
  image: alpine:latest
  script:
    - apk add --no-cache bc grep
    - |
      COVERAGE=$(grep -oP 'line-rate="\K[0-9.]+' coverage.xml | head -1)
      PERCENT=$(echo "$COVERAGE * 100" | bc)
      echo "Coverage: ${PERCENT}%"
      if [ $(echo "$PERCENT < $CODE_COVERAGE_THRESHOLD" | bc) -eq 1 ]; then
        echo "FAIL: Coverage ${PERCENT}% below threshold ${CODE_COVERAGE_THRESHOLD}%"
        exit 1
      fi
  coverage: '/Coverage: (\d+.\d+)%/'
```

### 5.2 PHPUnit Configuration (phpunit.xml)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<phpunit xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         bootstrap="web/core/tests/bootstrap.php"
         colors="true"
         stopOnError="true"
         stopOnFailure="true"
         xsi:noNamespaceSchemaLocation="https://schema.phpunit.de/11.5/phpunit.xsd">
    <php>
        <ini name="error_reporting" value="32767"/>
        <ini name="memory_limit" value="-1"/>
        <env name="SIMPLETEST_BASE_URL" value=""/>
        <env name="SIMPLETEST_DB" value=""/>
    </php>
    <testsuites>
        <testsuite name="unit">
            <directory>tests/phpunit</directory>
            <directory>web/modules/custom/**/tests/src/Unit</directory>
            <directory>web/themes/custom/**/tests/src/Unit</directory>
        </testsuite>
        <testsuite name="kernel">
            <directory>web/modules/custom/**/tests/src/Kernel</directory>
            <directory>web/themes/custom/**/tests/src/Kernel</directory>
        </testsuite>
        <testsuite name="functional">
            <directory>web/modules/custom/**/tests/src/Functional</directory>
            <directory>web/themes/custom/**/tests/src/Functional</directory>
        </testsuite>
    </testsuites>
    <logging>
        <junit outputFile=".logs/test_results/phpunit/phpunit.xml"/>
    </logging>
    <coverage includeUncoveredFiles="true">
        <report>
            <html outputDirectory=".logs/coverage/phpunit/.coverage-html"/>
            <cobertura outputFile=".logs/coverage/phpunit/cobertura.xml"/>
            <text outputFile=".logs/coverage/phpunit/coverage.txt"/>
        </report>
    </coverage>
    <source>
        <include>
            <directory>web/modules/custom</directory>
            <directory>web/themes/custom</directory>
        </include>
        <exclude>
            <directory suffix="Test.php">web/modules/custom</directory>
            <directory suffix="Test.php">web/themes/custom</directory>
        </exclude>
    </source>
</phpunit>
```

---

## 6. Local Development Testing

NWP already has a robust scripting infrastructure (`backup.sh`, `restore.sh`, `test-nwp.sh`, etc.). Testing commands should follow the same patterns rather than introducing external tools like Ahoy.

### 6.1 Proposed `test.sh` Script

Create a new `test.sh` following NWP's existing script patterns:

```bash
#!/bin/bash
################################################################################
# NWP Site Test Script
#
# Runs tests for a specific site: linting, PHPUnit, and Behat tests
#
# Usage: ./test.sh [OPTIONS] <sitename>
#
# Options:
#   -l, --lint          Run linting only (PHPCS, PHPStan)
#   -u, --unit          Run PHPUnit unit tests only
#   -k, --kernel        Run PHPUnit kernel tests only
#   -f, --functional    Run PHPUnit functional tests only
#   -s, --smoke         Run Behat smoke tests only
#   -b, --behat         Run all Behat tests
#   -a, --all           Run all tests (default)
#   -p, --parallel      Run Behat with parallel profile
#   -v, --verbose       Verbose output
#   -h, --help          Show this help
#
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh" 2>/dev/null || true

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

# Defaults
RUN_LINT=false
RUN_UNIT=false
RUN_KERNEL=false
RUN_FUNCTIONAL=false
RUN_SMOKE=false
RUN_BEHAT=false
RUN_ALL=true
PARALLEL=false
VERBOSE=false

print_header() {
    echo -e "\n${BLUE}${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}${BOLD}  $1${NC}"
    echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════════════${NC}\n"
}

print_status() {
    local status=$1
    local message=$2
    case "$status" in
        OK)   echo -e "[${GREEN}✓${NC}] $message" ;;
        WARN) echo -e "[${YELLOW}!${NC}] $message" ;;
        FAIL) echo -e "[${RED}✗${NC}] $message" ;;
        *)    echo -e "[${BLUE}i${NC}] $message" ;;
    esac
}

show_help() {
    grep "^#" "$0" | grep -v "^#!/" | sed 's/^# //' | sed 's/^#//'
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -l|--lint)       RUN_LINT=true; RUN_ALL=false; shift ;;
        -u|--unit)       RUN_UNIT=true; RUN_ALL=false; shift ;;
        -k|--kernel)     RUN_KERNEL=true; RUN_ALL=false; shift ;;
        -f|--functional) RUN_FUNCTIONAL=true; RUN_ALL=false; shift ;;
        -s|--smoke)      RUN_SMOKE=true; RUN_ALL=false; shift ;;
        -b|--behat)      RUN_BEHAT=true; RUN_ALL=false; shift ;;
        -a|--all)        RUN_ALL=true; shift ;;
        -p|--parallel)   PARALLEL=true; shift ;;
        -v|--verbose)    VERBOSE=true; shift ;;
        -h|--help)       show_help ;;
        -*)              echo "Unknown option: $1"; exit 1 ;;
        *)               SITENAME="$1"; shift ;;
    esac
done

if [ -z "$SITENAME" ]; then
    echo "Usage: ./test.sh [OPTIONS] <sitename>"
    exit 1
fi

if [ ! -d "$SITENAME" ]; then
    echo "Site not found: $SITENAME"
    exit 1
fi

cd "$SITENAME"

# Run tests
TESTS_PASSED=0
TESTS_FAILED=0

run_test() {
    local name="$1"
    local cmd="$2"
    print_status "INFO" "Running: $name"
    if eval "$cmd"; then
        print_status "OK" "$name passed"
        ((TESTS_PASSED++))
    else
        print_status "FAIL" "$name failed"
        ((TESTS_FAILED++))
    fi
}

if [ "$RUN_ALL" = true ] || [ "$RUN_LINT" = true ]; then
    print_header "Linting"
    run_test "PHPCS" "ddev exec vendor/bin/phpcs --standard=Drupal,DrupalPractice web/modules/custom web/themes/custom"
    run_test "PHPStan" "ddev exec vendor/bin/phpstan analyse --memory-limit=-1"
fi

if [ "$RUN_ALL" = true ] || [ "$RUN_UNIT" = true ]; then
    print_header "PHPUnit Unit Tests"
    run_test "Unit Tests" "ddev exec vendor/bin/phpunit --testsuite=unit"
fi

if [ "$RUN_ALL" = true ] || [ "$RUN_KERNEL" = true ]; then
    print_header "PHPUnit Kernel Tests"
    run_test "Kernel Tests" "ddev exec vendor/bin/phpunit --testsuite=kernel"
fi

if [ "$RUN_ALL" = true ] || [ "$RUN_FUNCTIONAL" = true ]; then
    print_header "PHPUnit Functional Tests"
    run_test "Functional Tests" "ddev exec vendor/bin/phpunit --testsuite=functional"
fi

if [ "$RUN_ALL" = true ] || [ "$RUN_SMOKE" = true ]; then
    print_header "Behat Smoke Tests"
    run_test "Smoke Tests" "ddev exec vendor/bin/behat --tags=@smoke"
fi

if [ "$RUN_ALL" = true ] || [ "$RUN_BEHAT" = true ]; then
    print_header "Behat Full Suite"
    if [ "$PARALLEL" = true ]; then
        run_test "Behat (p0)" "ddev exec vendor/bin/behat --profile=p0"
        run_test "Behat (p1)" "ddev exec vendor/bin/behat --profile=p1"
    else
        run_test "Behat" "ddev exec php -d memory_limit=-1 vendor/bin/behat"
    fi
fi

# Summary
print_header "Results"
echo "Passed: $TESTS_PASSED"
echo "Failed: $TESTS_FAILED"

[ "$TESTS_FAILED" -eq 0 ] && exit 0 || exit 1
```

### 6.2 Usage Examples

```bash
# Run all tests for a site
./test.sh mysite

# Quick lint check before commit
./test.sh -l mysite

# Unit tests only (fast, no DB)
./test.sh -u mysite

# Smoke tests before push (~30 seconds)
./test.sh -s mysite

# Full Behat suite
./test.sh -b mysite

# Behat with parallel profiles
./test.sh -b -p mysite

# Kernel + functional tests
./test.sh -k -f mysite
```

### 6.3 Integration with Existing Scripts

The new `test.sh` complements existing NWP scripts:

| Script | Purpose |
|--------|---------|
| `install.sh` | Create new site |
| `backup.sh` | Backup site |
| `restore.sh` | Restore site |
| `copy.sh` | Copy site |
| `delete.sh` | Delete site |
| `make.sh` | Dev/prod mode |
| `test-nwp.sh` | Test NWP itself |
| `testos.sh` | OpenSocial testing |
| **`test.sh`** | **Test a specific site** |

---

## 7. Remote Site Testing

### 7.1 Profile Configuration

Add to `behat.yml`:

```yaml
remote:
  extensions:
    Drupal\MinkExtension:
      base_url: https://dev.example.com
    Drupal\DrupalExtension:
      api_driver: drush
      drush:
        alias: '@dev'

staging:
  extensions:
    Drupal\MinkExtension:
      base_url: https://staging.example.com
    Drupal\DrupalExtension:
      drush:
        alias: '@staging'

production:
  gherkin:
    filters:
      tags: '@smoke&&~@destructive&&~@skipped'
  extensions:
    Drupal\MinkExtension:
      base_url: https://www.example.com
    Drupal\DrupalExtension:
      drush:
        alias: '@prod'
```

### 7.2 Commands

```bash
# Run against dev
vendor/bin/behat --profile=remote

# Run against staging
vendor/bin/behat --profile=staging --tags=@smoke

# Production (read-only tests only)
vendor/bin/behat --profile=production
```

### 7.3 Considerations

| Environment | Test Types | Cautions |
|-------------|------------|----------|
| Development | All | None |
| Staging | All | Coordinate with QA |
| Production | `@smoke&&~@destructive` | Read-only only |

---

## 8. Badge and Reporting Configuration

### 8.1 GitLab Badge URLs

For self-hosted GitLab:

```
# Pipeline status
https://gitlab.local/<namespace>/<project>/badges/<branch>/pipeline.svg

# Coverage
https://gitlab.local/<namespace>/<project>/badges/<branch>/coverage.svg

# Coverage from specific job
https://gitlab.local/<namespace>/<project>/badges/<branch>/coverage.svg?job=phpunit:unit

# Ignore skipped pipelines
https://gitlab.local/<namespace>/<project>/badges/<branch>/pipeline.svg?ignore_skipped=true
```

### 8.2 Badge Setup

Navigate to **Settings → General → Badges**:

| Badge | Name | Link | Image URL |
|-------|------|------|-----------|
| Pipeline | `Pipeline` | `%{project_path}/-/pipelines` | `%{project_path}/badges/%{default_branch}/pipeline.svg` |
| Coverage | `Coverage` | `%{project_path}/-/jobs` | `%{project_path}/badges/%{default_branch}/coverage.svg?job=phpunit:unit` |

### 8.3 Coverage Regex Patterns

```yaml
# PHPUnit
coverage: '/^\s*Lines:\s*(\d+.\d+)\%/'

# Custom output
coverage: '/Coverage: (\d+\.?\d*)%/'

# Behat pass rate
coverage: '/Behat pass rate: (\d+\.?\d*)%/'
```

### 8.4 README Badges

```markdown
# Project Name

[![Pipeline](https://gitlab.local/namespace/project/badges/main/pipeline.svg)](https://gitlab.local/namespace/project/-/pipelines)
[![Coverage](https://gitlab.local/namespace/project/badges/main/coverage.svg)](https://gitlab.local/namespace/project/-/jobs)
```

---

## 9. NWP Integration

### 9.1 Proposed cnwp.yml Configuration

```yaml
# CI/CD Configuration
ci:
  provider: gitlab
  gitlab:
    url: https://gitlab.local
    auto_create_project: true
    runner_tag: nwp

  testing:
    local:
      - phpcs
      - phpstan
      - phpunit-unit
    provisioned:
      - phpunit-kernel
      - phpunit-functional
      - behat
    ci:
      - all

    coverage:
      threshold: 80
      badge: true

  notifications:
    on_failure: true
    email: admin@example.com
```

### 9.2 Project Structure

```
site/
├── .gitlab-ci.yml
├── behat.yml
├── phpunit.xml
├── phpstan.neon
├── docker-compose.yml
├── tests/
│   ├── phpunit/
│   │   └── ExampleTest.php
│   └── behat/
│       ├── bootstrap/
│       │   └── FeatureContext.php
│       ├── features/
│       │   ├── smoke.feature
│       │   ├── login.feature
│       │   └── content.feature
│       └── fixtures/
│           └── image.jpg
└── .logs/
    ├── behat/
    ├── test_results/
    └── screenshots/
```

### 9.3 Dependencies (composer.json)

```json
{
  "require-dev": {
    "behat/behat": "^3.29",
    "drupal/drupal-extension": "^5.1",
    "drevops/behat-steps": "^3.4",
    "drevops/behat-screenshot": "^2.0",
    "drevops/behat-format-progress-fail": "^1.0",
    "phpunit/phpunit": "^11.0",
    "phpstan/phpstan": "^1.10",
    "drupal/coder": "^8.3",
    "rector/rector": "^1.0"
  }
}
```

---

## 10. Implementation Proposals

### Proposal 1: Docker-Based Test Environment

**Objective:** Establish consistent test execution across local and CI environments.

**Actions:**
1. Create standardized `docker-compose.yml` with cli, nginx, database, and chrome services
2. Include `shm_size: '1gb'` for Chrome stability
3. Use service naming compatible with Behat config (`nginx:8080`, `chrome:4444`)
4. Implement CI-specific volume handling via sed processing

**Priority:** HIGH
**Effort:** Medium

---

### Proposal 2: Tiered Test Execution Strategy

**Objective:** Optimize feedback loops by running appropriate tests at each stage.

**Actions:**
1. **Local (always):** Lint + Unit tests before commit
2. **Local (optional):** Smoke tests before push
3. **MR Pipeline:** Lint + Unit + Kernel + Smoke
4. **Main Branch:** Full suite with parallel Behat
5. **Nightly:** Comprehensive with extended timeout

**Priority:** HIGH
**Effort:** Low

---

### Proposal 3: GitLab CI Pipeline Implementation

**Objective:** Automate all testing through NWP-created GitLab.

**Actions:**
1. Implement three-stage pipeline: build → validate → test
2. Configure parallel Behat execution (2 runners minimum)
3. Set up database caching with timestamp-based invalidation
4. Enable skip flags for flexibility (`SKIP_PHPCS`, etc.)
5. Configure JUnit report collection for all test types

**Priority:** HIGH
**Effort:** High

---

### Proposal 4: Behat BDD Framework Setup

**Objective:** Enable behavior-driven testing with browser automation.

**Actions:**
1. Install Behat with DrupalExtension and DrevOps BehatSteps
2. Create `behat.yml` with local, p0, p1, and remote profiles
3. Implement FeatureContext with standard traits
4. Create initial smoke test suite covering critical paths
5. Document tagging strategy (`@smoke`, `@api`, `@javascript`, `@p1`)

**Priority:** HIGH
**Effort:** Medium

---

### Proposal 5: Code Quality Tooling

**Objective:** Enforce coding standards and detect issues early.

**Actions:**
1. Configure PHPCS with Drupal and DrupalPractice standards
2. Set up PHPStan at level 7 with baseline for existing code
3. Add Rector for automated refactoring suggestions
4. Include Gherkin lint for feature file validation
5. Make lint failures block pipeline (non-optional)

**Priority:** MEDIUM
**Effort:** Low

---

### Proposal 6: Coverage Reporting and Badges

**Objective:** Provide visibility into test coverage and pipeline status.

**Actions:**
1. Configure PHPUnit to output Cobertura XML
2. Set coverage threshold at 80% (configurable)
3. Add coverage regex to GitLab CI jobs
4. Configure pipeline and coverage badges in GitLab
5. Add badge markdown to project READMEs

**Priority:** MEDIUM
**Effort:** Low

---

### Proposal 7: Remote Site Testing Profiles

**Objective:** Enable testing against staging and production environments.

**Actions:**
1. Create Behat profiles for dev, staging, production
2. Configure Drush aliases for each environment
3. Implement `@destructive` tag for data-modifying tests
4. Restrict production profile to read-only smoke tests
5. Document SSH key and alias configuration

**Priority:** LOW
**Effort:** Medium

---

### Proposal 8: Developer Workflow Integration

**Objective:** Make testing easy and habitual for developers.

**Actions:**
1. Create `test.sh` script following NWP patterns (not Ahoy)
2. Document recommended pre-push workflow
3. Add `-s/--smoke` flag for quick validation (~30 seconds)
4. Support Chrome VNC debugging for Behat
5. Create onboarding documentation for new developers

**Priority:** MEDIUM
**Effort:** Low

---

### Proposal 9: NWP Configuration Schema

**Objective:** Integrate CI/CD settings into NWP's cnwp.yml.

**Actions:**
1. Define `ci:` section in cnwp.yml schema
2. Support GitLab URL and authentication configuration
3. Allow per-site test customization
4. Enable notification configuration
5. Auto-generate `.gitlab-ci.yml` from configuration

**Priority:** LOW
**Effort:** High

---

### Proposal 10: Documentation and Training

**Objective:** Ensure team adoption and maintainability.

**Actions:**
1. Create this unified strategy document
2. Write developer quick-start guide
3. Document troubleshooting for common issues
4. Create example feature files as templates
5. Record walkthrough video for CI setup

**Priority:** MEDIUM
**Effort:** Medium

---

### Implementation Priority Matrix

| # | Proposal | Priority | Effort | Dependencies |
|---|----------|----------|--------|--------------|
| 1 | Docker Environment | HIGH | Medium | None |
| 2 | Tiered Test Strategy | HIGH | Low | #1 |
| 3 | GitLab CI Pipeline | HIGH | High | #1, #2 |
| 4 | Behat Framework | HIGH | Medium | #1 |
| 5 | Code Quality Tools | MEDIUM | Low | None |
| 6 | Coverage/Badges | MEDIUM | Low | #3 |
| 7 | Remote Testing | LOW | Medium | #4 |
| 8 | Developer Workflow | MEDIUM | Low | #1, #4 |
| 9 | NWP Config Schema | LOW | High | #3 |
| 10 | Documentation | MEDIUM | Medium | All |

### Recommended Implementation Order

1. **Phase 1 (Foundation):** Proposals 1, 2, 4, 5
2. **Phase 2 (Automation):** Proposals 3, 6, 8
3. **Phase 3 (Enhancement):** Proposals 7, 9, 10

---

## References

### Documentation
- [GitLab CI for Drupal 11+](https://mog33.gitlab.io/gitlab-ci-drupal/advanced-usage/)
- [GitLab Badges](https://docs.gitlab.com/user/project/badges/)
- [Drupal Extension for Behat](https://behat-drupal-extension.readthedocs.io/)
- [DrevOps Behat Steps](https://github.com/drevops/behat-steps)

### Codebase References
- Vortex: `/home/rob/tmp/vortex/`
- Pleasy: `/home/rob/tmp/pleasy/`

### Related NWP Documents
- [GIT_BACKUP_RECOMMENDATIONS.md](./GIT_BACKUP_RECOMMENDATIONS.md)

---

*Document created: December 30, 2024*
*Based on analysis of Vortex, Pleasy, and industry best practices*
