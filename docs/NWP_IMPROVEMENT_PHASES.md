# NWP Improvement Phases

A numbered, phased proposal for enhancing NWP to match industry best practices for Drupal CI/CD and automated deployment workflows.

---

## Executive Summary

Based on analysis of:
- [Vortex](https://www.vortextemplate.com/) Drupal project template
- [Pleasy](https://github.com/rjzaar/pleasy) deployment system
- Industry CI/CD best practices for Drupal 2025
- Current NWP capabilities

This document proposes 6 phases of improvements to achieve a complete developer lifecycle from project initialization to automated production security updates.

---

## Current NWP Capabilities

### What NWP Already Has

| Feature | Status | Notes |
|---------|--------|-------|
| Recipe-based installation | Complete | Multiple CMS support |
| DDEV local development | Complete | Docker-based |
| Backup/Restore | Complete | Full and DB-only |
| Dev to Staging (dev2stg.sh) | **Enhanced** | TUI, multi-source DB, testing |
| Multi-tier testing | **New** | 8 types, 5 presets |
| Preflight checks | **New** | Doctor-style validation |
| State detection | **New** | Intelligent defaults |
| Production deployment | Partial | stg2prod.sh exists |
| GitLab integration | Partial | Basic support |
| Security updates | Missing | Not automated |
| Renovate/Dependabot | Missing | No automated deps |
| GitHub Actions | Missing | No workflow files |
| Nightly DB caching | Missing | No scheduled jobs |
| Code coverage | Missing | No threshold enforcement |
| Notifications | Missing | No Slack/email |

---

## Phase 1: CI/CD Foundation

**Priority: Critical**
**Dependencies: None**

### 1.1 GitLab CI Pipeline Configuration

Create `.gitlab-ci.yml` with proper pipeline structure:

```yaml
# Target file: .gitlab-ci.yml
stages:
  - database
  - build
  - deploy

variables:
  SITE_NAME: ${CI_PROJECT_NAME}
  PHP_VERSION: "8.3"

# Nightly database job
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

# Main build job
build:
  stage: build
  script:
    - ./scripts/ci/build.sh
    - ./scripts/ci/test.sh
  artifacts:
    paths:
      - .logs/
    when: always

# Deployment jobs per environment
deploy:staging:
  stage: deploy
  rules:
    - if: $CI_COMMIT_BRANCH == "develop"
  script:
    - ./scripts/ci/deploy.sh staging

deploy:production:
  stage: deploy
  rules:
    - if: $CI_COMMIT_BRANCH == "production"
  script:
    - ./scripts/ci/deploy.sh production
```

### 1.2 GitHub Actions Workflow

Create `.github/workflows/build-test-deploy.yml`:

```yaml
# Target file: .github/workflows/build-test-deploy.yml
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
      enable_terminal:
        description: 'Enable terminal session for debugging'
        type: boolean
        default: false

jobs:
  database:
    runs-on: ubuntu-latest
    if: github.event_name == 'schedule'
    steps:
      - uses: actions/checkout@v4
      - name: Fetch and cache database
        run: ./scripts/ci/fetch-db.sh --sanitize
      - uses: actions/cache/save@v4
        with:
          path: .data/db.sql.gz
          key: db-${{ github.run_id }}

  build:
    runs-on: ubuntu-latest
    needs: [database]
    if: always()
    steps:
      - uses: actions/checkout@v4
      - name: Restore database cache
        uses: actions/cache/restore@v4
        with:
          path: .data/db.sql.gz
          key: db-
          restore-keys: db-
      - name: Build and test
        run: |
          ./scripts/ci/build.sh
          ./scripts/ci/test.sh
      - uses: actions/upload-artifact@v4
        with:
          name: test-results
          path: .logs/
```

### 1.3 CI Helper Scripts

Create `scripts/ci/` directory with helper scripts:

| Script | Purpose |
|--------|---------|
| `fetch-db.sh` | Download and sanitize production DB |
| `build.sh` | Composer install, asset compilation |
| `test.sh` | Run test suite with coverage |
| `deploy.sh` | Deploy to specified environment |

### 1.4 Deliverables

- [ ] `.gitlab-ci.yml` - GitLab pipeline configuration
- [ ] `.github/workflows/build-test-deploy.yml` - GitHub Actions workflow
- [ ] `scripts/ci/fetch-db.sh` - Database fetching script
- [ ] `scripts/ci/build.sh` - Build script
- [ ] `scripts/ci/test.sh` - Test runner script
- [ ] `scripts/ci/deploy.sh` - Deployment script
- [ ] `docs/CI.md` - CI configuration documentation

---

## Phase 2: Automated Dependency Updates

**Priority: High**
**Dependencies: Phase 1**

### 2.1 Renovate Configuration

Create `renovate.json` based on Vortex's Drupal configuration:

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": [
    "config:recommended",
    "github>drevops/renovate-drupal"
  ],
  "labels": ["dependencies"],
  "assignees": ["team-lead"],
  "schedule": ["before 6am on Monday"],
  "packageRules": [
    {
      "description": "Drupal core - daily checks",
      "matchPackagePatterns": ["^drupal/core"],
      "schedule": ["before 6am"],
      "groupName": "Drupal Core"
    },
    {
      "description": "Drupal contrib - weekly checks",
      "matchPackagePatterns": ["^drupal/"],
      "schedule": ["before 6am on Monday"],
      "groupName": "Drupal Contrib"
    },
    {
      "description": "Auto-merge patch updates",
      "matchUpdateTypes": ["patch"],
      "automerge": true,
      "automergeType": "pr"
    }
  ],
  "vulnerabilityAlerts": {
    "enabled": true,
    "labels": ["security"]
  }
}
```

### 2.2 Composer Security Auditing

Update `composer.json` with security configuration:

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

### 2.3 Automated PR Testing

Configure CI to run full tests on Renovate PRs:

```yaml
# In .gitlab-ci.yml
test:dependencies:
  rules:
    - if: $CI_MERGE_REQUEST_SOURCE_BRANCH_NAME =~ /^renovate\//
    - if: $CI_MERGE_REQUEST_SOURCE_BRANCH_NAME =~ /^dependabot\//
  script:
    - ./dev2stg.sh -y -t full $SITE_NAME
```

### 2.4 Security Alert Workflow

Create `./security-update.sh`:

```bash
#!/bin/bash
# Automated security update workflow
# 1. Create branch from develop
# 2. Run composer update for security packages
# 3. Run full test suite
# 4. Create PR if tests pass
# 5. Notify team via Slack/email
```

### 2.5 Deliverables

- [ ] `renovate.json` - Renovate configuration
- [ ] `scripts/security-update.sh` - Security update automation
- [ ] Update `composer.json` with audit configuration
- [ ] CI rules for dependency PR testing
- [ ] `docs/DEPENDENCY_UPDATES.md` - Documentation

---

## Phase 3: Code Quality & Coverage

**Priority: High**
**Dependencies: Phase 1**

### 3.1 Code Coverage Enforcement

Add coverage threshold checking:

```yaml
# In CI configuration
test:coverage:
  script:
    - ddev exec vendor/bin/phpunit --coverage-clover=.logs/coverage.xml
    - ./scripts/ci/check-coverage.sh 80  # Fail if below 80%
```

### 3.2 Static Analysis Baseline

Create PHPStan configuration with increasing levels:

```yaml
# phpstan.neon
parameters:
  level: 5
  paths:
    - web/modules/custom
    - web/themes/custom
  baseline: phpstan-baseline.neon
```

### 3.3 Pre-commit Hooks

Create `.hooks/pre-commit`:

```bash
#!/bin/bash
# Run quick checks before commit
ddev exec vendor/bin/phpcs --standard=Drupal web/modules/custom
ddev exec vendor/bin/phpstan analyse --memory-limit=1G
```

### 3.4 Code Review Checklist

Add PR template with checklist:

```markdown
<!-- .github/PULL_REQUEST_TEMPLATE.md -->
## Checklist
- [ ] Tests pass locally
- [ ] Code follows Drupal coding standards
- [ ] Configuration exported
- [ ] Documentation updated
- [ ] No security vulnerabilities introduced
```

### 3.5 Deliverables

- [ ] `scripts/ci/check-coverage.sh` - Coverage threshold script
- [ ] `phpstan.neon` - Static analysis configuration
- [ ] `.hooks/pre-commit` - Pre-commit hook
- [ ] `.github/PULL_REQUEST_TEMPLATE.md` - PR template
- [ ] `.gitlab/merge_request_templates/default.md` - GitLab MR template
- [ ] `docs/CODE_QUALITY.md` - Standards documentation

---

## Phase 4: Notifications & Monitoring

**Priority: Medium**
**Dependencies: Phase 1**

### 4.1 Deployment Notifications

Create notification system for:
- Deployment success/failure
- Security update availability
- Test failures
- Coverage drops

### 4.2 Slack Integration

Create `scripts/notify.sh`:

```bash
#!/bin/bash
# Send notifications to Slack
send_slack() {
  local webhook_url="${SLACK_WEBHOOK_URL}"
  local message="$1"
  local color="$2"  # good, warning, danger

  curl -X POST "$webhook_url" \
    -H 'Content-type: application/json' \
    -d "{\"attachments\":[{\"color\":\"$color\",\"text\":\"$message\"}]}"
}
```

### 4.3 Email Notifications

Integrate with existing mail systems for critical alerts.

### 4.4 New Relic Integration

For performance monitoring and deployment markers:

```bash
# Mark deployment in New Relic
./scripts/newrelic-deploy.sh "$CI_COMMIT_SHA" "$CI_COMMIT_MESSAGE"
```

### 4.5 Deliverables

- [ ] `scripts/notify.sh` - Notification dispatcher
- [ ] `scripts/notify-slack.sh` - Slack notifications
- [ ] `scripts/notify-email.sh` - Email notifications
- [ ] `scripts/newrelic-deploy.sh` - New Relic integration
- [ ] `lib/notifications.sh` - Notification library
- [ ] `docs/NOTIFICATIONS.md` - Configuration guide

---

## Phase 5: Environment Management

**Priority: Medium**
**Dependencies: Phases 1-3**

### 5.1 Preview Environments

Auto-create preview environments for PRs:

```yaml
# In CI configuration
deploy:preview:
  rules:
    - if: $CI_MERGE_REQUEST_ID
  script:
    - ./scripts/ci/create-preview.sh "pr-${CI_MERGE_REQUEST_IID}"
  environment:
    name: preview/$CI_MERGE_REQUEST_IID
    url: https://pr-${CI_MERGE_REQUEST_IID}.preview.example.com
    on_stop: cleanup:preview
```

### 5.2 Environment Cleanup

Auto-cleanup preview environments:

```yaml
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

### 5.3 Database Sync Options

Enhance database routing with:
- Scheduled production sync
- On-demand sync via CI
- Sanitization profiles

### 5.4 Configuration Splits

Support for environment-specific config:

```
config/
├── default/          # Shared config
├── dev/              # Development overrides
├── staging/          # Staging overrides
└── production/       # Production overrides
```

### 5.5 Deliverables

- [ ] `scripts/ci/create-preview.sh` - Preview environment creation
- [ ] `scripts/ci/cleanup-preview.sh` - Preview cleanup
- [ ] Update `dev2stg.sh` for preview support
- [ ] Config split documentation
- [ ] `docs/ENVIRONMENTS.md` - Environment guide

---

## Phase 6: Advanced Automation

**Priority: Low**
**Dependencies: Phases 1-5**

### 6.1 Blue-Green Deployments

Implement zero-downtime deployments:

```bash
# scripts/blue-green-deploy.sh
# 1. Deploy to inactive environment
# 2. Run smoke tests
# 3. Switch traffic
# 4. Keep old environment for rollback
```

### 6.2 Canary Releases

Gradual rollout for production:

```bash
# scripts/canary-deploy.sh
# 1. Deploy to canary (10% traffic)
# 2. Monitor for 1 hour
# 3. If healthy, deploy to 100%
# 4. If issues, rollback canary
```

### 6.3 Automated Rollback

Trigger rollback on failure detection:

```bash
# scripts/auto-rollback.sh
# Monitor production health
# Detect anomalies (error rate, latency)
# Automatically rollback if thresholds exceeded
```

### 6.4 Performance Budgets

Fail CI if performance degrades:

```yaml
test:performance:
  script:
    - ./scripts/ci/lighthouse-test.sh
    - ./scripts/ci/check-performance-budget.sh
```

### 6.5 Visual Regression Testing

Integrate with tools like BackstopJS or Diffy:

```yaml
test:visual:
  script:
    - ./scripts/ci/visual-regression.sh
```

### 6.6 Deliverables

- [ ] `scripts/blue-green-deploy.sh` - Zero-downtime deployment
- [ ] `scripts/canary-deploy.sh` - Canary releases
- [ ] `scripts/auto-rollback.sh` - Automated rollback
- [ ] `scripts/ci/lighthouse-test.sh` - Performance testing
- [ ] `scripts/ci/visual-regression.sh` - Visual testing
- [ ] `docs/ADVANCED_DEPLOYMENT.md` - Advanced deployment guide

---

## Implementation Timeline

| Phase | Description | Priority | Dependencies |
|-------|-------------|----------|--------------|
| 1 | CI/CD Foundation | Critical | None |
| 2 | Automated Dependency Updates | High | Phase 1 |
| 3 | Code Quality & Coverage | High | Phase 1 |
| 4 | Notifications & Monitoring | Medium | Phase 1 |
| 5 | Environment Management | Medium | Phases 1-3 |
| 6 | Advanced Automation | Low | Phases 1-5 |

---

## Comparison with Vortex

| Feature | Vortex | NWP Current | NWP After Phases |
|---------|--------|-------------|------------------|
| Local development | Docker Compose + Ahoy | DDEV | DDEV |
| CI providers | CircleCI, GitHub Actions | GitLab (partial) | GitLab, GitHub |
| Nightly DB cache | Yes | No | Phase 1 |
| Multi-tier testing | Yes | Yes | Yes |
| Renovate | Yes | No | Phase 2 |
| Code coverage | Yes (threshold) | No | Phase 3 |
| Notifications | Yes (Slack, email, NR) | No | Phase 4 |
| Preview environments | Yes | No | Phase 5 |
| Blue-green deploy | Partial | No | Phase 6 |
| Hosting integrations | Acquia, Lagoon | Linode, custom | Linode, custom |

---

## Quick Wins

These can be implemented immediately with minimal effort:

1. **Add `renovate.json`** - Automated dependency PRs
2. **Add PR template** - Consistent code reviews
3. **Add pre-commit hook** - Catch issues early
4. **Update `composer.json`** - Enable security auditing
5. **Create `scripts/ci/` directory** - Prepare for Phase 1

---

## References

- [Vortex Documentation](https://www.vortextemplate.com/)
- [Renovate for Drupal](https://github.com/drevops/renovate-drupal)
- [CI/CD for Enterprise Drupal 2025](https://www.augustinfotech.com/blogs/ci-cd-for-enterprise-drupal-offshore-implementation-guide-for-2025/)
- [Drupal Automatic Updates](https://new.drupal.org/docs/drupal-cms/updates/configure-automatic-updates)
- [GitHub Actions Documentation](https://docs.github.com/en/actions)
- [GitLab CI/CD Documentation](https://docs.gitlab.com/ee/ci/)
