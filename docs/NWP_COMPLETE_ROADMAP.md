# NWP Complete Development & Deployment Roadmap

A unified, numbered, phased proposal for implementing a complete developer lifecycle from project initialization to automated production deployment with security updates.

---

## Executive Summary

This roadmap merges two proposal documents into a single comprehensive plan:
- **Production Deployment Proposal** - Server infrastructure, monitoring, backups
- **NWP Improvement Phases** - CI/CD, dependency automation, code quality

Based on analysis of:
- [Vortex](https://www.vortextemplate.com/) - Drupal project template
- [Pleasy](https://github.com/rjzaar/pleasy) - Deployment system
- Industry CI/CD best practices for Drupal 2025
- Current NWP capabilities

---

## Current State Assessment

### What NWP Already Has

| Component | Status | Location |
|-----------|--------|----------|
| Recipe-based installation | Complete | install.sh, recipes/ |
| DDEV local development | Complete | All sites |
| dev2stg.sh | **Enhanced** | 11-step workflow with TUI, testing, DB routing |
| stg2prod.sh | Complete | 10-step rsync deployment to Linode |
| prod2stg.sh | Complete | Pull from production with sanitization |
| Blue-green deployment | Complete | linode/server_scripts/nwp-swap-prod.sh |
| Rollback mechanism | Complete | nwp-rollback.sh |
| Preflight checks | **New** | lib/preflight.sh |
| Multi-tier testing | **New** | 8 types, 5 presets (lib/testing.sh) |
| Database sanitization | Complete | lib/sanitize.sh |
| Backup/restore | Complete | backup.sh, restore.sh |

### What's Missing (Gap Analysis)

| Gap | Priority | Category |
|-----|----------|----------|
| CI/CD pipeline configuration | CRITICAL | Automation |
| Automated dependency updates (Renovate) | CRITICAL | Security |
| Production health monitoring | CRITICAL | Operations |
| Deployment notifications | HIGH | Visibility |
| Post-deployment verification | HIGH | Reliability |
| Code coverage enforcement | HIGH | Quality |
| Automated scheduled backups | MEDIUM | Data Safety |
| Preview environments for PRs | MEDIUM | Development |
| Performance baseline tracking | LOW | Operations |
| Multi-server deployment | LOW | Scale |

---

## Phase 1: CI/CD Pipeline Foundation

**Priority: CRITICAL**
**Effort: Medium**
**Dependencies: None**

### 1.1 GitLab CI Pipeline Configuration

**New file: `.gitlab-ci.yml`**

```yaml
stages:
  - database
  - build
  - deploy

variables:
  SITE_NAME: ${CI_PROJECT_NAME}
  PHP_VERSION: "8.3"

# Nightly database caching job
database:nightly:
  stage: database
  rules:
    - if: $CI_PIPELINE_SOURCE == "schedule"
  script:
    - ./scripts/ci/fetch-db.sh --sanitize
  artifacts:
    paths:
      - .data/db.sql.gz
    expire_in: 1 day

# Database job - use cache or fetch fresh
database:
  stage: database
  rules:
    - if: $CI_PIPELINE_SOURCE != "schedule"
  script:
    - ./scripts/ci/fetch-db.sh --use-cache
  artifacts:
    paths:
      - .data/db.sql.gz
    expire_in: 1 day

# Main build and test job
build:
  stage: build
  needs: [database]
  script:
    # Assembly phase
    - ddev start
    - ddev composer install --no-dev
    - ddev exec npm ci && npm run build
    # Provision phase
    - ddev drush sql:cli < .data/db.sql
    - ddev drush deploy
    # Testing phase
    - ./scripts/ci/test.sh
  artifacts:
    paths:
      - .logs/
    when: always
    reports:
      junit: .logs/phpunit/junit.xml
      coverage_report:
        coverage_format: cobertura
        path: .logs/coverage/cobertura.xml

# Staging deployment
deploy:staging:
  stage: deploy
  needs: [build]
  rules:
    - if: $CI_COMMIT_BRANCH == "develop"
  script:
    - ./dev2stg.sh -y --db-source=auto -t essential $SITE_NAME
  environment:
    name: staging
    url: https://${SITE_NAME}-stg.ddev.site

# Production deployment (manual approval required)
deploy:production:
  stage: deploy
  needs: [build]
  rules:
    - if: $CI_COMMIT_BRANCH == "main" || $CI_COMMIT_BRANCH == "production"
  script:
    - ./stg2prod.sh -y $SITE_NAME
  environment:
    name: production
    url: https://${PRODUCTION_URL}
  when: manual
```

### 1.2 GitHub Actions Workflow

**New file: `.github/workflows/build-test-deploy.yml`**

```yaml
name: Build, Test, Deploy

on:
  push:
    branches: [main, develop, staging, production]
  pull_request:
    branches: [main, develop]
  schedule:
    - cron: '0 18 * * *'  # Nightly at 6 PM UTC
  workflow_dispatch:
    inputs:
      environment:
        description: 'Target environment'
        type: choice
        options: [staging, production]
      enable_terminal:
        description: 'Enable terminal session'
        type: boolean
        default: false

env:
  SITE_NAME: ${{ github.event.repository.name }}

jobs:
  # Nightly database caching
  database-nightly:
    runs-on: ubuntu-latest
    if: github.event_name == 'schedule'
    steps:
      - uses: actions/checkout@v4
      - name: Fetch and sanitize database
        run: ./scripts/ci/fetch-db.sh --sanitize
      - uses: actions/cache/save@v4
        with:
          path: .data/db.sql.gz
          key: db-nightly-${{ github.run_id }}

  # Build and test
  build:
    runs-on: ubuntu-latest
    needs: [database-nightly]
    if: always()
    steps:
      - uses: actions/checkout@v4

      - name: Restore database cache
        uses: actions/cache/restore@v4
        with:
          path: .data/db.sql.gz
          key: db-nightly-
          restore-keys: db-

      - name: Setup DDEV
        uses: ddev/github-action-setup-ddev@v1

      - name: Build and provision
        run: ./scripts/ci/build.sh

      - name: Run tests
        run: ./scripts/ci/test.sh

      - name: Upload test results
        uses: actions/upload-artifact@v4
        if: always()
        with:
          name: test-results
          path: .logs/

  # Deploy to staging
  deploy-staging:
    runs-on: ubuntu-latest
    needs: [build]
    if: github.ref == 'refs/heads/develop'
    environment: staging
    steps:
      - uses: actions/checkout@v4
      - name: Deploy to staging
        run: ./dev2stg.sh -y --db-source=auto -t essential $SITE_NAME

  # Deploy to production (requires approval)
  deploy-production:
    runs-on: ubuntu-latest
    needs: [build]
    if: github.ref == 'refs/heads/main' || github.ref == 'refs/heads/production'
    environment: production
    steps:
      - uses: actions/checkout@v4
      - name: Deploy to production
        run: ./stg2prod.sh -y $SITE_NAME
```

### 1.3 CI Helper Scripts

**New directory: `scripts/ci/`**

| Script | Purpose |
|--------|---------|
| `fetch-db.sh` | Download and sanitize production database |
| `build.sh` | DDEV start, composer install, asset build |
| `test.sh` | Run test suite with coverage reporting |
| `deploy.sh` | Generic deployment wrapper |

**New file: `scripts/ci/fetch-db.sh`**

```bash
#!/bin/bash
set -e
source "$(dirname "$0")/../../lib/ui.sh"

USE_CACHE=false
SANITIZE=false
while [[ $# -gt 0 ]]; do
  case $1 in
    --use-cache) USE_CACHE=true; shift ;;
    --sanitize) SANITIZE=true; shift ;;
    *) shift ;;
  esac
done

mkdir -p .data

if [ "$USE_CACHE" = true ] && [ -f .data/db.sql.gz ]; then
  info "Using cached database"
  exit 0
fi

info "Fetching production database..."
./backup.sh -d "$SITE_NAME" --from-prod

if [ "$SANITIZE" = true ]; then
  info "Sanitizing database..."
  # Sanitization handled by backup.sh
fi

pass "Database ready"
```

**New file: `scripts/ci/test.sh`**

```bash
#!/bin/bash
set -e
source "$(dirname "$0")/../../lib/ui.sh"

mkdir -p .logs/{phpunit,behat,coverage}

info "Running code quality checks..."
ddev exec vendor/bin/phpcs --standard=Drupal,DrupalPractice web/modules/custom || true
ddev exec vendor/bin/phpstan analyse --no-progress || true

info "Running PHPUnit tests..."
ddev exec vendor/bin/phpunit \
  --coverage-clover=.logs/coverage/clover.xml \
  --coverage-cobertura=.logs/coverage/cobertura.xml \
  --log-junit=.logs/phpunit/junit.xml

info "Checking coverage threshold..."
./scripts/ci/check-coverage.sh 80

info "Running Behat tests..."
ddev exec vendor/bin/behat --format=junit --out=.logs/behat || true

pass "All tests completed"
```

### 1.4 Deliverables - Phase 1

- [ ] `.gitlab-ci.yml` - GitLab CI pipeline
- [ ] `.github/workflows/build-test-deploy.yml` - GitHub Actions workflow
- [ ] `scripts/ci/fetch-db.sh` - Database fetching
- [ ] `scripts/ci/build.sh` - Build script
- [ ] `scripts/ci/test.sh` - Test runner
- [ ] `scripts/ci/check-coverage.sh` - Coverage threshold checker
- [ ] `docs/CI.md` - CI configuration documentation

---

## Phase 2: Automated Dependency Updates

**Priority: CRITICAL**
**Effort: Low**
**Dependencies: Phase 1**

### 2.1 Renovate Configuration

**New file: `renovate.json`**

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": [
    "config:recommended",
    "github>drevops/renovate-drupal"
  ],
  "labels": ["dependencies"],
  "assignees": ["team-lead"],
  "prHourlyLimit": 2,
  "packageRules": [
    {
      "description": "Drupal core - daily security checks",
      "matchPackagePatterns": ["^drupal/core"],
      "schedule": ["before 6am"],
      "groupName": "Drupal Core",
      "prPriority": 10
    },
    {
      "description": "Drupal contrib - weekly updates",
      "matchPackagePatterns": ["^drupal/"],
      "excludePackagePatterns": ["^drupal/core"],
      "schedule": ["before 6am on Monday"],
      "groupName": "Drupal Contrib"
    },
    {
      "description": "Auto-merge patch updates after tests pass",
      "matchUpdateTypes": ["patch"],
      "matchPackagePatterns": ["^drupal/"],
      "automerge": true,
      "automergeType": "pr"
    },
    {
      "description": "Security updates - immediate",
      "matchDepTypes": ["security"],
      "schedule": ["at any time"],
      "prPriority": 100,
      "labels": ["security", "urgent"]
    }
  ],
  "vulnerabilityAlerts": {
    "enabled": true,
    "labels": ["security"]
  }
}
```

### 2.2 Composer Security Configuration

**Update: `composer.json`**

```json
{
  "config": {
    "audit": {
      "abandoned": "report",
      "block-insecure": true,
      "ignore": {}
    }
  }
}
```

### 2.3 CI Rules for Dependency PRs

Add to CI configuration:

```yaml
# Test all dependency update PRs with full suite
test:dependencies:
  rules:
    - if: $CI_MERGE_REQUEST_SOURCE_BRANCH_NAME =~ /^renovate\//
    - if: $CI_MERGE_REQUEST_SOURCE_BRANCH_NAME =~ /^dependabot\//
  script:
    - ./dev2stg.sh -y -t full $SITE_NAME
```

### 2.4 Security Update Automation

**New file: `scripts/security-update.sh`**

```bash
#!/bin/bash
# Automated security update workflow
set -e
source "$(dirname "$0")/../lib/ui.sh"

SITE_NAME="${1:-}"
[ -z "$SITE_NAME" ] && { echo "Usage: $0 <sitename>"; exit 1; }

info "Checking for security updates..."

cd "$SITE_NAME"

# Check Drupal security
DRUPAL_UPDATES=$(ddev drush pm:security --format=json 2>/dev/null || echo "[]")
COMPOSER_AUDIT=$(ddev composer audit --format=json 2>/dev/null || echo "{}")

if [ "$DRUPAL_UPDATES" != "[]" ] || [ "$COMPOSER_AUDIT" != "{}" ]; then
  warn "Security updates available!"

  # Create branch
  BRANCH="security/$(date +%Y%m%d)"
  git checkout -b "$BRANCH" develop

  # Apply updates
  ddev composer update --with-dependencies

  # Run tests
  ./dev2stg.sh -y -t essential "$SITE_NAME"

  if [ $? -eq 0 ]; then
    git add composer.*
    git commit -m "security: Apply security updates $(date +%Y-%m-%d)"
    git push -u origin "$BRANCH"
    pass "Security updates applied and pushed to $BRANCH"
  else
    fail "Tests failed - manual review required"
    git checkout develop
    git branch -D "$BRANCH"
    exit 1
  fi
else
  pass "No security updates needed"
fi
```

### 2.5 Deliverables - Phase 2

- [ ] `renovate.json` - Renovate configuration
- [ ] Update `composer.json` with audit config
- [ ] `scripts/security-update.sh` - Security automation
- [ ] CI rules for dependency PRs
- [ ] `docs/DEPENDENCY_UPDATES.md` - Documentation

---

## Phase 3: Production Infrastructure

**Priority: CRITICAL**
**Effort: Medium**
**Dependencies: None (can run parallel to Phase 1-2)**

### 3.1 Production Server Bootstrap

**New file: `linode/server_scripts/nwp-bootstrap.sh`**

```bash
#!/bin/bash
# Bootstrap production server with NWP infrastructure
set -e

echo "=== NWP Production Server Bootstrap ==="

# Verify required packages
REQUIRED="php8.2 php8.2-cli php8.2-mysql php8.2-xml php8.2-mbstring php8.2-curl \
          php8.2-gd php8.2-zip composer mariadb-server nginx rsync git"

for pkg in $REQUIRED; do
  if ! dpkg -l | grep -q "^ii  $pkg"; then
    echo "Installing $pkg..."
    apt-get install -y "$pkg"
  fi
done

# Create directory structure
mkdir -p /var/www/{prod,test,old}
mkdir -p /var/backups/nwp/{hourly,daily,weekly,monthly}
mkdir -p /var/log/nwp/{deployments,health,metrics}

# Set permissions
chown -R www-data:www-data /var/www
chmod -R 755 /var/www

# Install NWP server scripts
cp -r /tmp/nwp-scripts/* /usr/local/bin/
chmod +x /usr/local/bin/nwp-*.sh

echo "=== Bootstrap Complete ==="
```

### 3.2 Post-Deployment Health Check

**New file: `linode/server_scripts/nwp-healthcheck.sh`**

```bash
#!/bin/bash
# Verify site health after deployment
set -e

SITE="${1:-prod}"
SITE_PATH="/var/www/$SITE"
SITE_URL="${2:-https://$(hostname)}"

CHECKS_PASSED=0
CHECKS_FAILED=0

check() {
  local name="$1"
  local result="$2"
  if [ "$result" = "0" ]; then
    echo "[ OK ] $name"
    ((CHECKS_PASSED++))
  else
    echo "[FAIL] $name"
    ((CHECKS_FAILED++))
  fi
}

echo "=== NWP Health Check: $SITE ==="

# 1. HTTP Response
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$SITE_URL" 2>/dev/null || echo "000")
check "HTTP Response (200)" "$([ "$HTTP_CODE" = "200" ] && echo 0 || echo 1)"

# 2. Drupal Bootstrap
cd "$SITE_PATH"
BOOTSTRAP=$(drush status --field=bootstrap 2>/dev/null | grep -c "Successful" || echo 0)
check "Drupal Bootstrap" "$([ "$BOOTSTRAP" = "1" ] && echo 0 || echo 1)"

# 3. Database Connectivity
DB_CHECK=$(drush sql:query "SELECT 1" 2>/dev/null | grep -c "1" || echo 0)
check "Database Connectivity" "$([ "$DB_CHECK" = "1" ] && echo 0 || echo 1)"

# 4. Cache Status
check "Cache Rebuild" "$(drush cr 2>/dev/null; echo $?)"

# 5. Cron Status
CRON_LAST=$(drush state:get system.cron_last 2>/dev/null || echo 0)
CRON_AGE=$(($(date +%s) - CRON_LAST))
check "Cron (last < 24h)" "$([ "$CRON_AGE" -lt 86400 ] && echo 0 || echo 1)"

# 6. SSL Certificate
SSL_EXPIRY=$(echo | openssl s_client -servername "$(echo $SITE_URL | sed 's|https://||')" \
  -connect "$(echo $SITE_URL | sed 's|https://||'):443" 2>/dev/null | \
  openssl x509 -noout -dates 2>/dev/null | grep notAfter | cut -d= -f2)
if [ -n "$SSL_EXPIRY" ]; then
  EXPIRY_EPOCH=$(date -d "$SSL_EXPIRY" +%s)
  DAYS_LEFT=$(( (EXPIRY_EPOCH - $(date +%s)) / 86400 ))
  check "SSL Certificate (>7 days)" "$([ "$DAYS_LEFT" -gt 7 ] && echo 0 || echo 1)"
fi

# 7. Disk Space
DISK_USED=$(df /var/www | awk 'NR==2 {print $5}' | tr -d '%')
check "Disk Space (<90%)" "$([ "$DISK_USED" -lt 90 ] && echo 0 || echo 1)"

# Summary
echo ""
echo "=== Health Check Summary ==="
echo "Passed: $CHECKS_PASSED"
echo "Failed: $CHECKS_FAILED"

[ "$CHECKS_FAILED" -eq 0 ] && exit 0 || exit 1
```

### 3.3 Deployment Audit Log

**New file: `linode/server_scripts/nwp-audit.sh`**

```bash
#!/bin/bash
# Log deployment events in structured format

EVENT="${1:-unknown}"
SITE="${2:-unknown}"
DETAILS="${3:-}"

LOG_DIR="/var/log/nwp"
JSON_LOG="$LOG_DIR/deployments.jsonl"
TEXT_LOG="$LOG_DIR/deployments.log"

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
USER=$(whoami)
GIT_COMMIT=$(cd /var/www/prod 2>/dev/null && git rev-parse --short HEAD 2>/dev/null || echo "unknown")
GIT_BRANCH=$(cd /var/www/prod 2>/dev/null && git branch --show-current 2>/dev/null || echo "unknown")

# JSON log entry
cat >> "$JSON_LOG" << EOF
{"timestamp":"$TIMESTAMP","event":"$EVENT","site":"$SITE","user":"$USER","git_commit":"$GIT_COMMIT","git_branch":"$GIT_BRANCH","details":"$DETAILS"}
EOF

# Human-readable log entry
echo "[$TIMESTAMP] $EVENT - Site: $SITE, User: $USER, Commit: $GIT_COMMIT ($GIT_BRANCH) $DETAILS" >> "$TEXT_LOG"
```

### 3.4 Enhanced stg2prod.sh Integration

**Update: `stg2prod.sh`** - Add new steps after deployment:

```bash
# Step 11: Post-deployment health check
step 11 13 "Running health checks"
if ssh_cmd "/usr/local/bin/nwp-healthcheck.sh prod $PROD_URL"; then
  pass "Health checks passed"
else
  fail "Health checks failed"
  if [ "$ROLLBACK_ON_FAILURE" = "true" ]; then
    warn "Initiating automatic rollback..."
    ssh_cmd "/usr/local/bin/nwp-rollback.sh"
  fi
  exit 1
fi

# Step 12: Audit logging
step 12 13 "Logging deployment"
ssh_cmd "/usr/local/bin/nwp-audit.sh deploy_success $SITE_NAME"

# Step 13: Send notifications (Phase 4)
step 13 13 "Sending notifications"
./scripts/notify.sh --event=deploy_success --site=$SITE_NAME --url=$PROD_URL
```

### 3.5 Deliverables - Phase 3

- [ ] `linode/server_scripts/nwp-bootstrap.sh`
- [ ] `linode/server_scripts/nwp-healthcheck.sh`
- [ ] `linode/server_scripts/nwp-audit.sh`
- [ ] Updated `stg2prod.sh` with health checks and audit
- [ ] `docs/PRODUCTION_SERVER_SETUP.md`

---

## Phase 4: Notifications & Alerting

**Priority: HIGH**
**Effort: Low**
**Dependencies: Phase 3**

### 4.1 Multi-Channel Notification Router

**New file: `scripts/notify.sh`**

```bash
#!/bin/bash
# Notification router for deployment events
set -e
source "$(dirname "$0")/../lib/ui.sh"

# Parse arguments
EVENT=""
SITE=""
URL=""
MESSAGE=""
CHANNELS="${NOTIFY_CHANNELS:-slack}"

while [[ $# -gt 0 ]]; do
  case $1 in
    --event=*) EVENT="${1#*=}"; shift ;;
    --site=*) SITE="${1#*=}"; shift ;;
    --url=*) URL="${1#*=}"; shift ;;
    --message=*) MESSAGE="${1#*=}"; shift ;;
    --channels=*) CHANNELS="${1#*=}"; shift ;;
    *) shift ;;
  esac
done

# Event emoji mapping
case $EVENT in
  deploy_success) EMOJI=":rocket:" COLOR="good" ;;
  deploy_failed) EMOJI=":x:" COLOR="danger" ;;
  rollback) EMOJI=":rewind:" COLOR="warning" ;;
  health_check_failed) EMOJI=":warning:" COLOR="danger" ;;
  security_update) EMOJI=":shield:" COLOR="warning" ;;
  backup_completed) EMOJI=":floppy_disk:" COLOR="good" ;;
  *) EMOJI=":bell:" COLOR="#439FE0" ;;
esac

# Build message
[ -z "$MESSAGE" ] && MESSAGE="$EMOJI $EVENT for $SITE"
[ -n "$URL" ] && MESSAGE="$MESSAGE\nURL: $URL"

# Route to channels
for channel in $(echo "$CHANNELS" | tr ',' ' '); do
  case $channel in
    slack)
      ./scripts/notify-slack.sh "$MESSAGE" "$COLOR"
      ;;
    email)
      ./scripts/notify-email.sh "$EVENT" "$SITE" "$MESSAGE"
      ;;
    webhook)
      ./scripts/notify-webhook.sh "$EVENT" "$SITE" "$MESSAGE"
      ;;
  esac
done
```

### 4.2 Slack Notification

**New file: `scripts/notify-slack.sh`**

```bash
#!/bin/bash
MESSAGE="$1"
COLOR="${2:-good}"
WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"

[ -z "$WEBHOOK_URL" ] && { echo "SLACK_WEBHOOK_URL not set"; exit 0; }

curl -s -X POST "$WEBHOOK_URL" \
  -H 'Content-type: application/json' \
  -d "{\"attachments\":[{\"color\":\"$COLOR\",\"text\":\"$MESSAGE\",\"mrkdwn_in\":[\"text\"]}]}"
```

### 4.3 Email Notification

**New file: `scripts/notify-email.sh`**

```bash
#!/bin/bash
EVENT="$1"
SITE="$2"
MESSAGE="$3"
RECIPIENTS="${EMAIL_RECIPIENTS:-}"

[ -z "$RECIPIENTS" ] && { echo "EMAIL_RECIPIENTS not set"; exit 0; }

SUBJECT="[NWP] $EVENT - $SITE"

echo -e "$MESSAGE" | mail -s "$SUBJECT" "$RECIPIENTS"
```

### 4.4 Configuration Schema

**Update: `example.cnwp.yml`**

```yaml
# Notification settings
notifications:
  enabled: true
  channels: slack,email
  slack_webhook: ""  # Set in .secrets.yml
  email_recipients: "team@example.com"
  on_events:
    - deploy_success
    - deploy_failed
    - rollback
    - health_check_failed
    - security_update
    - backup_completed
```

### 4.5 Deliverables - Phase 4

- [ ] `scripts/notify.sh` - Notification router
- [ ] `scripts/notify-slack.sh` - Slack integration
- [ ] `scripts/notify-email.sh` - Email integration
- [ ] `scripts/notify-webhook.sh` - Generic webhook
- [ ] `linode/server_scripts/nwp-notify.sh` - Server-side notifications
- [ ] Update `example.cnwp.yml` with notification config
- [ ] `docs/NOTIFICATIONS.md`

---

## Phase 5: Code Quality & Coverage

**Priority: HIGH**
**Effort: Medium**
**Dependencies: Phase 1**

### 5.1 Coverage Threshold Enforcement

**New file: `scripts/ci/check-coverage.sh`**

```bash
#!/bin/bash
# Check code coverage meets minimum threshold
THRESHOLD="${1:-80}"
COVERAGE_FILE="${2:-.logs/coverage/clover.xml}"

if [ ! -f "$COVERAGE_FILE" ]; then
  echo "Coverage file not found: $COVERAGE_FILE"
  exit 1
fi

# Extract coverage percentage from clover.xml
COVERAGE=$(grep -oP 'elements="(\d+)".*coveredelements="(\d+)"' "$COVERAGE_FILE" | head -1 | \
  awk -F'"' '{print int(($4/$2)*100)}')

echo "Code coverage: ${COVERAGE}%"
echo "Threshold: ${THRESHOLD}%"

if [ "$COVERAGE" -lt "$THRESHOLD" ]; then
  echo "FAIL: Coverage below threshold"
  exit 1
else
  echo "PASS: Coverage meets threshold"
  exit 0
fi
```

### 5.2 PHPStan Configuration

**New file: `phpstan.neon`**

```neon
parameters:
  level: 5
  paths:
    - web/modules/custom
    - web/themes/custom
  excludePaths:
    - web/modules/custom/*/tests
  checkMissingIterableValueType: false
  reportUnmatchedIgnoredErrors: false
```

### 5.3 Pre-commit Hooks

**New file: `.hooks/pre-commit`**

```bash
#!/bin/bash
# Pre-commit hook for code quality
set -e

echo "Running pre-commit checks..."

# PHPCS on staged PHP files
STAGED_PHP=$(git diff --cached --name-only --diff-filter=ACM | grep '\.php$' | grep -E '^web/(modules|themes)/custom' || true)
if [ -n "$STAGED_PHP" ]; then
  echo "Checking PHP coding standards..."
  ddev exec vendor/bin/phpcs --standard=Drupal,DrupalPractice $STAGED_PHP
fi

# PHPStan
echo "Running static analysis..."
ddev exec vendor/bin/phpstan analyse --memory-limit=1G --no-progress

echo "Pre-commit checks passed!"
```

### 5.4 PR/MR Templates

**New file: `.github/PULL_REQUEST_TEMPLATE.md`**

```markdown
## Description
<!-- Brief description of changes -->

## Type of Change
- [ ] Bug fix
- [ ] New feature
- [ ] Breaking change
- [ ] Documentation update

## Checklist
- [ ] Tests pass locally (`./dev2stg.sh -t essential`)
- [ ] Code follows Drupal coding standards
- [ ] Configuration exported (`drush cex`)
- [ ] Documentation updated (if needed)
- [ ] No security vulnerabilities introduced
- [ ] Reviewed own code for obvious issues

## Testing Instructions
<!-- How to test these changes -->
```

### 5.5 Deliverables - Phase 5

- [ ] `scripts/ci/check-coverage.sh`
- [ ] `phpstan.neon`
- [ ] `.hooks/pre-commit`
- [ ] `.github/PULL_REQUEST_TEMPLATE.md`
- [ ] `.gitlab/merge_request_templates/default.md`
- [ ] `docs/CODE_QUALITY.md`

---

## Phase 6: Monitoring & Observability

**Priority: MEDIUM**
**Effort: Medium**
**Dependencies: Phase 3**

### 6.1 Continuous Monitoring Script

**New file: `linode/server_scripts/nwp-monitor.sh`**

```bash
#!/bin/bash
# Continuous monitoring daemon
# Run via cron: */5 * * * * /usr/local/bin/nwp-monitor.sh

SITES="${1:-prod}"
LOG_DIR="/var/log/nwp/metrics"
ALERT_SCRIPT="/usr/local/bin/nwp-notify.sh"

mkdir -p "$LOG_DIR"

for SITE in $(echo "$SITES" | tr ',' ' '); do
  SITE_PATH="/var/www/$SITE"
  SITE_URL="https://$(hostname)"
  METRICS_FILE="$LOG_DIR/$(date +%Y-%m-%d).json"

  # Collect metrics
  RESPONSE_TIME=$(curl -s -o /dev/null -w "%{time_total}" "$SITE_URL" 2>/dev/null || echo "0")
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$SITE_URL" 2>/dev/null || echo "000")
  DISK_USED=$(df /var/www | awk 'NR==2 {print $5}' | tr -d '%')

  TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Log metrics
  echo "{\"timestamp\":\"$TIMESTAMP\",\"site\":\"$SITE\",\"response_time\":$RESPONSE_TIME,\"http_code\":$HTTP_CODE,\"disk_used\":$DISK_USED}" >> "$METRICS_FILE"

  # Alert on thresholds
  if [ "$HTTP_CODE" != "200" ]; then
    $ALERT_SCRIPT --event=site_down --site=$SITE
  fi

  if (( $(echo "$RESPONSE_TIME > 5" | bc -l) )); then
    $ALERT_SCRIPT --event=slow_response --site=$SITE --message="Response time: ${RESPONSE_TIME}s"
  fi

  if [ "$DISK_USED" -gt 90 ]; then
    $ALERT_SCRIPT --event=disk_warning --site=$SITE --message="Disk usage: ${DISK_USED}%"
  fi
done
```

### 6.2 Status Dashboard

**Update: `status.sh`** - Add production status section:

```bash
#!/bin/bash
# Production status dashboard

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║                    NWP Production Status                       ║"
echo "╠═══════════════════════════════════════════════════════════════╣"
printf "║ %-10s │ %-6s │ %-9s │ %-12s │ %-10s ║\n" "Site" "Status" "Response" "Last Deploy" "Backup Age"
echo "╠═══════════════════════════════════════════════════════════════╣"

for site in $(get_production_sites); do
  STATUS=$(check_site_status "$site")
  RESPONSE=$(get_response_time "$site")
  DEPLOY=$(get_last_deploy "$site")
  BACKUP=$(get_backup_age "$site")

  printf "║ %-10s │ %-6s │ %-9s │ %-12s │ %-10s ║\n" \
    "$site" "$STATUS" "$RESPONSE" "$DEPLOY" "$BACKUP"
done

echo "╚═══════════════════════════════════════════════════════════════╝"
```

### 6.3 Deliverables - Phase 6

- [ ] `linode/server_scripts/nwp-monitor.sh`
- [ ] Updated `status.sh` with production status
- [ ] Cron configuration for monitoring
- [ ] Alert thresholds in `example.cnwp.yml`
- [ ] `docs/MONITORING.md`

---

## Phase 7: Automated Backups & Disaster Recovery

**Priority: MEDIUM**
**Effort: Medium**
**Dependencies: Phase 3**

### 7.1 Scheduled Backup System

**New file: `linode/server_scripts/nwp-scheduled-backup.sh`**

```bash
#!/bin/bash
# Automated backup with rotation
set -e

SITE="${1:-prod}"
BACKUP_TYPE="${2:-database}"  # database, files, full
BACKUP_DIR="/var/backups/nwp"

case $BACKUP_TYPE in
  database)
    DEST="$BACKUP_DIR/hourly"
    RETENTION=24
    ;;
  files)
    DEST="$BACKUP_DIR/daily"
    RETENTION=7
    ;;
  full)
    DEST="$BACKUP_DIR/weekly"
    RETENTION=4
    ;;
esac

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_FILE="$DEST/${SITE}-${BACKUP_TYPE}-${TIMESTAMP}"

mkdir -p "$DEST"

# Create backup
case $BACKUP_TYPE in
  database)
    cd /var/www/$SITE && drush sql:dump --gzip > "${BACKUP_FILE}.sql.gz"
    ;;
  files)
    tar -czf "${BACKUP_FILE}.tar.gz" -C /var/www/$SITE/web sites/default/files
    ;;
  full)
    tar -czf "${BACKUP_FILE}.tar.gz" -C /var/www "$SITE"
    ;;
esac

# Rotate old backups
find "$DEST" -name "${SITE}-${BACKUP_TYPE}-*" -type f -mtime +$RETENTION -delete

# Verify backup
if [ -f "${BACKUP_FILE}.sql.gz" ] || [ -f "${BACKUP_FILE}.tar.gz" ]; then
  /usr/local/bin/nwp-audit.sh backup_completed "$SITE" "$BACKUP_TYPE"
else
  /usr/local/bin/nwp-notify.sh --event=backup_failed --site=$SITE
  exit 1
fi
```

### 7.2 Cron Configuration

```bash
# /etc/cron.d/nwp-backups

# Database backups every 6 hours
0 */6 * * * root /usr/local/bin/nwp-scheduled-backup.sh prod database

# File backups daily at 2 AM
0 2 * * * root /usr/local/bin/nwp-scheduled-backup.sh prod files

# Full backups weekly Sunday at 3 AM
0 3 * * 0 root /usr/local/bin/nwp-scheduled-backup.sh prod full

# Monitoring every 5 minutes
*/5 * * * * root /usr/local/bin/nwp-monitor.sh prod
```

### 7.3 Disaster Recovery Runbook

**New file: `docs/DISASTER_RECOVERY.md`**

```markdown
# NWP Disaster Recovery Procedures

## Recovery Time Objectives
| Scenario | Target RTO |
|----------|------------|
| Rollback (recent deploy) | < 5 minutes |
| Database restore | < 30 minutes |
| Full server rebuild | < 2 hours |

## Scenario 1: Bad Deployment
1. SSH to server: `ssh prod`
2. Rollback: `/usr/local/bin/nwp-rollback.sh`
3. Verify: `/usr/local/bin/nwp-healthcheck.sh`

## Scenario 2: Database Corruption
1. Enable maintenance mode
2. List backups: `ls /var/backups/nwp/hourly/`
3. Restore: `gunzip -c backup.sql.gz | drush sql:cli`
4. Run updates: `drush updb -y && drush cr`
5. Verify data integrity
6. Disable maintenance mode

## Scenario 3: Complete Server Loss
1. Provision new Linode
2. Run bootstrap: `./linode/linode_server_setup.sh`
3. Deploy code: `./stg2prod.sh <sitename>`
4. Restore database from off-site backup
5. Update DNS records
6. Verify SSL certificate
7. Run health checks
```

### 7.4 Deliverables - Phase 7

- [ ] `linode/server_scripts/nwp-scheduled-backup.sh`
- [ ] `linode/server_scripts/nwp-verify-backup.sh`
- [ ] Cron configuration
- [ ] `docs/DISASTER_RECOVERY.md`
- [ ] Tested recovery procedure

---

## Phase 8: Environment Management

**Priority: MEDIUM**
**Effort: High**
**Dependencies: Phases 1-5**

### 8.1 Preview Environments for PRs

Add to CI configuration:

```yaml
# GitLab CI
deploy:preview:
  stage: deploy
  rules:
    - if: $CI_MERGE_REQUEST_ID
  script:
    - ./scripts/ci/create-preview.sh "pr-${CI_MERGE_REQUEST_IID}"
  environment:
    name: preview/$CI_MERGE_REQUEST_IID
    url: https://pr-${CI_MERGE_REQUEST_IID}.preview.example.com
    on_stop: cleanup:preview
    auto_stop_in: 1 week

cleanup:preview:
  stage: deploy
  rules:
    - if: $CI_MERGE_REQUEST_ID
      when: manual
  script:
    - ./scripts/ci/cleanup-preview.sh "pr-${CI_MERGE_REQUEST_IID}"
  environment:
    name: preview/$CI_MERGE_REQUEST_IID
    action: stop
```

### 8.2 Configuration Splits

```
config/
├── default/          # Shared config (committed)
├── dev/              # Development overrides
├── staging/          # Staging overrides
└── production/       # Production overrides
```

### 8.3 Deliverables - Phase 8

- [ ] `scripts/ci/create-preview.sh`
- [ ] `scripts/ci/cleanup-preview.sh`
- [ ] Configuration split setup
- [ ] `docs/ENVIRONMENTS.md`

---

## Phase 9: Advanced Automation

**Priority: LOW**
**Effort: High**
**Dependencies: Phases 1-8**

### 9.1 Blue-Green Deployment Enhancement

Enhance existing `nwp-swap-prod.sh` with:
- Traffic shifting via load balancer
- Automated smoke tests before swap
- Instant rollback capability

### 9.2 Canary Releases

```bash
# Deploy to canary (10% traffic)
# Monitor for errors for 1 hour
# If healthy, deploy to 100%
# If issues, automatic rollback
```

### 9.3 Performance Regression Detection

```bash
# Store baseline metrics after each deploy
# Alert if next deploy shows > 20% regression
# Track: Page load, TTFB, database query time
```

### 9.4 Visual Regression Testing

Integrate with BackstopJS or Diffy:
```yaml
test:visual:
  script:
    - ./scripts/ci/visual-regression.sh
  artifacts:
    paths:
      - .logs/visual/
```

### 9.5 Deliverables - Phase 9

- [ ] Enhanced blue-green deployment
- [ ] Canary release scripts
- [ ] Performance baseline tracking
- [ ] Visual regression integration
- [ ] `docs/ADVANCED_DEPLOYMENT.md`

---

## Implementation Summary

| Phase | Priority | Effort | Key Deliverables |
|-------|----------|--------|------------------|
| **1** | CRITICAL | Medium | GitLab CI, GitHub Actions, CI scripts |
| **2** | CRITICAL | Low | Renovate, security automation |
| **3** | CRITICAL | Medium | Server bootstrap, health checks, audit |
| **4** | HIGH | Low | Slack/email notifications |
| **5** | HIGH | Medium | Coverage thresholds, pre-commit hooks |
| **6** | MEDIUM | Medium | Monitoring daemon, status dashboard |
| **7** | MEDIUM | Medium | Scheduled backups, disaster recovery |
| **8** | MEDIUM | High | Preview environments, config splits |
| **9** | LOW | High | Blue-green, canary, visual regression |

---

## Quick Wins (Implement Immediately)

1. **Add `renovate.json`** - Automated dependency PRs
2. **Add PR template** - Consistent code reviews
3. **Add pre-commit hook** - Catch issues early
4. **Update `composer.json`** - Enable security auditing
5. **Create `scripts/ci/` directory** - Prepare for CI integration

---

## Production Server Structure

```
/var/www/
├── prod/                    # Production webroot
├── test/                    # Blue-green staging
├── old/                     # Previous production (rollback)
└── backups/                 # Local backup storage

/usr/local/bin/
├── nwp-bootstrap.sh         # Server setup
├── nwp-backup.sh            # Backup script
├── nwp-rollback.sh          # Rollback script
├── nwp-swap-prod.sh         # Blue-green swap
├── nwp-healthcheck.sh       # Health verification
├── nwp-audit.sh             # Deployment logging
├── nwp-monitor.sh           # Continuous monitoring
├── nwp-notify.sh            # Alert notifications
└── nwp-scheduled-backup.sh  # Automated backups

/var/log/nwp/
├── deployments.jsonl        # Structured deployment log
├── deployments.log          # Human-readable log
├── health/                  # Health check results
└── metrics/                 # Performance metrics

/var/backups/nwp/
├── hourly/                  # Database backups (keep 24)
├── daily/                   # File backups (keep 7)
├── weekly/                  # Full backups (keep 4)
└── monthly/                 # Archives (keep 12)
```

---

## References

- [Vortex Documentation](https://www.vortextemplate.com/)
- [Renovate for Drupal](https://github.com/drevops/renovate-drupal)
- [CI/CD for Enterprise Drupal 2025](https://www.augustinfotech.com/blogs/ci-cd-for-enterprise-drupal-offshore-implementation-guide-for-2025/)
- [Drupal Automatic Updates](https://new.drupal.org/docs/drupal-cms/updates/configure-automatic-updates)
- [Drupal Best Practices](https://www.thedroptimes.com/40998/best-practices-managing-drupal-environments-development-production)
- [GitHub Actions Documentation](https://docs.github.com/en/actions)
- [GitLab CI/CD Documentation](https://docs.gitlab.com/ee/ci/)
