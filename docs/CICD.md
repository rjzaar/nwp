# NWP CI/CD Guide

This document provides comprehensive CI/CD guidance for the Narrow Way Project, covering architecture, implementation, and best practices.

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [NWP GitLab Server](#nwp-gitlab-server)
- [Local CI Setup](#local-ci-setup)
- [GitLab CI Configuration](#gitlab-ci-configuration)
- [GitHub Actions (Alternative)](#github-actions-alternative)
- [Automated Security Updates](#automated-security-updates)
- [GitLab Hardening](#gitlab-hardening)
- [Troubleshooting](#troubleshooting)

## Architecture Overview

NWP uses a self-hosted GitLab instance as the primary CI/CD platform. The GitLab server at `git.<your-domain>` serves as the central repository with optional mirroring to GitHub.

```
Developer Workstation              NWP GitLab                    External Services
┌─────────────────────┐          ┌─────────────────┐            ┌─────────────────┐
│  Local Development  │──push───▶│ git.domain.org  │───mirror──▶│  GitHub         │
│  (DDEV)             │          │                 │            │  GitLab.com     │
└─────────────────────┘          │  GitLab CI/CD   │            └─────────────────┘
                                 │  ┌───────────┐  │
                                 │  │ Pipeline  │  │
                                 │  │ ─────────▶│  │
                                 │  │ lint      │  │
                                 │  │ test      │  │
                                 │  │ security  │  │
                                 │  │ deploy    │  │
                                 │  └───────────┘  │
                                 └─────────────────┘
```

### Git Remote Strategy

| Remote | URL | Purpose |
|--------|-----|---------|
| `origin` | `git@git.yourdomain.org:nwp/sitename.git` | Primary (CI runs here) |
| `github` | `git@github.com:user/sitename.git` | Mirror (optional) |
| `upstream` | Original project URL | For pulling updates |

### Pipeline Stages

```
build:composer → validate (phpcs, phpstan, security) → test (phpunit, behat) → deploy
```

## NWP GitLab Server

### Installation Methods

**Production (Linode):**
```bash
./linode/gitlab/setup_gitlab_site.sh
# Or with options
./linode/gitlab/setup_gitlab_site.sh --type g6-standard-4 --region us-west
```

**Development (Local Docker):**
```bash
pl install gitlab git
```

### Post-Installation Setup

1. Push NWP itself to GitLab
2. Create projects for each managed site
3. Configure push mirrors to GitHub (optional)
4. Register GitLab Runner for CI jobs

## Local CI Setup

Run validation locally before pushing to catch issues early.

### Makefile (Recommended)

Create a `Makefile` in the project root:

```makefile
.PHONY: test lint build ci help

help:
	@echo "Available targets:"
	@echo "  make test       - Run all tests"
	@echo "  make lint       - Run linting and static analysis"
	@echo "  make ci         - Run full CI pipeline locally"

test:
	./testos.sh -a

lint:
	./testos.sh -p
	./testos.sh -c

build:
	ddev composer install
	ddev drush cr

ci: build lint test
	@echo "✓ All CI checks passed!"
```

**Usage:**
```bash
make ci          # Run full CI pipeline
make lint        # Quick validation
make test        # All tests
```

### Git Hooks

**Pre-push hook** (`.git/hooks/pre-push`):

```bash
#!/bin/bash
set -e
echo "🚀 Running pre-push validation..."
./testos.sh -a || {
    echo "✗ Tests failed - fix before pushing"
    exit 1
}
echo "✓ All tests passed!"
```

Make executable: `chmod +x .git/hooks/pre-push`

### DDEV Hooks

Add to `.ddev/config.yaml`:

```yaml
hooks:
  post-start:
    - exec: composer validate
    - exec: drush status
  pre-commit:
    - exec: ./testos.sh -p  # PHPStan only for speed
```

## GitLab CI Configuration

### Global CI Settings

In `cnwp.yml`, configure default CI behavior:

```yaml
settings:
  ci:
    enabled: true
    platform: gitlab
    auto_setup: false
    stages:
      lint: true
      test: true
      security: true
      deploy: false
    testing:
      phpcs: true
      phpstan: true
      phpstan_level: 5
      phpunit: true
      behat: false
```

### Per-Site Configuration

Each site in `cnwp.yml` can have its own CI settings:

```yaml
sites:
  mysite:
    directory: /home/user/nwp/mysite
    recipe: d
    environment: development
    ci:
      enabled: true
      repo: git@git.nwpcode.org:nwp/mysite.git
      branch: main
      mirrors:
        github: git@github.com:user/mysite.git
```

### .gitlab-ci.yml Template

Create `.gitlab-ci.yml` in site root:

```yaml
stages:
  - lint
  - test
  - security
  - deploy

variables:
  COMPOSER_ALLOW_SUPERUSER: "1"
  PHP_VERSION: "8.2"

# Lint stage
phpcs:
  stage: lint
  image: php:${PHP_VERSION}-cli
  before_script:
    - apt-get update && apt-get install -y git unzip
    - curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
    - composer global require squizlabs/php_codesniffer drupal/coder
    - export PATH="$PATH:$HOME/.composer/vendor/bin"
  script:
    - phpcs --standard=Drupal,DrupalPractice --extensions=php,module,inc,install,theme web/modules/custom
  allow_failure: true

phpstan:
  stage: lint
  image: php:${PHP_VERSION}-cli
  before_script:
    - apt-get update && apt-get install -y git unzip libpng-dev
    - docker-php-ext-install gd
    - curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
    - composer install --no-interaction
  script:
    - composer require --dev phpstan/phpstan mglaman/phpstan-drupal
    - vendor/bin/phpstan analyse web/modules/custom --level=5
  allow_failure: true

# Test stage
phpunit:
  stage: test
  image: php:${PHP_VERSION}-cli
  services:
    - mariadb:10.11
  variables:
    MYSQL_DATABASE: drupal
    MYSQL_ROOT_PASSWORD: root
    SIMPLETEST_DB: mysql://root:root@mariadb/drupal
  before_script:
    - apt-get update && apt-get install -y git unzip libpng-dev default-mysql-client
    - docker-php-ext-install gd pdo pdo_mysql
    - curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
    - composer install --no-interaction
  script:
    - vendor/bin/phpunit --configuration phpunit.xml web/modules/custom
  allow_failure: true

# Security stage
security_scan:
  stage: security
  image: php:${PHP_VERSION}-cli
  before_script:
    - curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
  script:
    - composer audit --no-interaction
  allow_failure: false

# Deploy stage
deploy_staging:
  stage: deploy
  when: manual
  only:
    - main
  script:
    - echo "Deploying to staging..."
  environment:
    name: staging
    url: https://staging.example.com

deploy_production:
  stage: deploy
  when: manual
  only:
    - main
  script:
    - echo "Deploying to production..."
  environment:
    name: production
    url: https://example.com
```

### Running CI on a Site

```bash
# Push to trigger CI
git push origin main

# Manual trigger via API
curl --request POST \
  --header "PRIVATE-TOKEN: <your-token>" \
  "https://git.nwpcode.org/api/v4/projects/<project-id>/pipeline" \
  --form "ref=main"
```

## GitHub Actions (Alternative)

If using GitHub instead of self-hosted GitLab:

### .github/workflows/ci.yml

```yaml
name: CI

on:
  pull_request: {}
  push:
    branches: [main, develop]

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: ${{ github.head_ref != '' }}

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

      - name: PHPCS
        run: ./testos.sh -c

      - name: PHPStan
        run: ./testos.sh -p

  behat-tests:
    name: Behat Tests
    runs-on: ubuntu-latest
    needs: code-quality
    steps:
      - uses: actions/checkout@v4

      - name: Setup DDEV
        uses: ddev/github-action-setup-ddev@v1

      - name: Install site
        run: ./install.sh nwp -y

      - name: Run Behat tests
        run: |
          cd nwp
          ../testos.sh -b

      - name: Upload artifacts on failure
        if: failure()
        uses: actions/upload-artifact@v3
        with:
          name: behat-output
          path: nwp/tests/behat/logs/

  update-path-test:
    name: Update Path Testing
    runs-on: ubuntu-latest
    needs: code-quality
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Setup DDEV
        uses: ddev/github-action-setup-ddev@v1

      - name: Install previous version
        run: |
          PREVIOUS_TAG=$(git describe --tags --abbrev=0 HEAD^)
          git checkout $PREVIOUS_TAG
          ./install.sh nwp -y

      - name: Update to current version
        run: |
          git checkout ${{ github.ref_name }}
          cd nwp
          ddev composer install
          ddev drush updatedb -y

      - name: Run tests after update
        run: |
          cd nwp
          ../testos.sh -a
```

## Automated Security Updates

Automatically detect, test, and deploy Drupal security updates.

### Security Update Script

Create `/var/www/scripts/security-updates.sh`:

```bash
#!/bin/bash
set -e

SITE_NAME="${SITE_NAME:-nwp_test}"
SITE_DIR="/var/www/$SITE_NAME"
LOG_DIR="/var/log/security-updates"
AUTO_MERGE_SECURITY="${AUTO_MERGE_SECURITY:-false}"
AUTO_DEPLOY_PRODUCTION="${AUTO_DEPLOY_PRODUCTION:-false}"

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/update-$(date +%Y%m%d-%H%M%S).log"
exec 1> >(tee -a "$LOG_FILE") 2>&1

cd "$SITE_DIR"

# Check for security updates
echo "Checking for security updates..."
SECURITY_JSON=$(ddev composer outdated --direct --format=json 2>/dev/null || echo '{"installed":[]}')
SECURITY_UPDATES=$(echo "$SECURITY_JSON" | jq -r '.installed[] | select(.warning != null) | .name' 2>/dev/null || echo "")

if [ -z "$SECURITY_UPDATES" ]; then
    echo "No security updates available"
    exit 0
fi

echo "Security updates found:"
echo "$SECURITY_UPDATES"

# Create backup
BACKUP_NAME="before-security-update-$(date +%Y%m%d-%H%M%S)"
./backup.sh -y "$SITE_NAME" "$BACKUP_NAME"

# Create update branch
BRANCH_NAME="security-update-$(date +%Y%m%d-%H%M%S)"
git checkout main
git pull origin main
git checkout -b "$BRANCH_NAME"

# Apply updates
echo "$SECURITY_UPDATES" | while read -r package; do
    echo "Updating $package..."
    ddev composer update "$package" --with-all-dependencies
done

# Database updates and cache clear
ddev drush updatedb -y
ddev drush config-export -y
ddev drush cr

# Run tests
echo "Running test suite..."
if ! ./testos.sh -a; then
    echo "Tests failed - rolling back"
    git checkout main
    git branch -D "$BRANCH_NAME"
    ./restore.sh -fy "$SITE_NAME"
    exit 1
fi

# Commit changes
git add .
git commit -m "Security updates: $(date +%Y-%m-%d)"

# Deploy based on configuration
if [ "$AUTO_MERGE_SECURITY" = "true" ]; then
    git checkout main
    git merge "$BRANCH_NAME" --no-ff -m "Merge security updates"
    git push origin main
    echo "Auto-deployed to test server"

    if [ "$AUTO_DEPLOY_PRODUCTION" = "true" ]; then
        ./linode_deploy.sh --target prod --site "$SITE_NAME"
        echo "Auto-deployed to production"
    fi
else
    git push origin "$BRANCH_NAME"
    echo "Branch pushed for manual review"
fi
```

### Cron Configuration

```bash
# Daily at 2 AM
0 2 * * * /var/www/scripts/security-updates.sh

# Or twice daily (business hours)
0 9,14 * * 1-5 /var/www/scripts/security-updates.sh
```

### Safety Levels

| Level | AUTO_MERGE_SECURITY | AUTO_DEPLOY_PRODUCTION | Use Case |
|-------|---------------------|------------------------|----------|
| 1 - Manual | false | false | Production sites |
| 2 - Auto-Test | true | false | Test/staging servers |
| 3 - Fully Auto | true | true | Low-risk sites only |

## GitLab Hardening

For production GitLab instances, apply security hardening.

### Hardening Script

Create `linode/gitlab/gitlab_harden.sh`:

```bash
#!/bin/bash
set -euo pipefail

GITLAB_CONFIG="/etc/gitlab/gitlab.rb"
DRY_RUN=true
[[ "${1:-}" == "--apply" ]] && DRY_RUN=false

update_config() {
    local setting="$1"
    local value="$2"
    if $DRY_RUN; then
        echo "[DRY-RUN] Would set: $setting = $value"
    else
        if grep -q "^${setting}" "$GITLAB_CONFIG"; then
            sed -i "s|^${setting}.*|${setting} = ${value}|" "$GITLAB_CONFIG"
        else
            echo "${setting} = ${value}" >> "$GITLAB_CONFIG"
        fi
        echo "[OK] Set: $setting = $value"
    fi
}

echo "GitLab Security Hardening"
echo "========================="

echo "1. Disabling public sign-ups..."
update_config "gitlab_rails['gitlab_signup_enabled']" "false"

echo "2. Setting password requirements..."
update_config "gitlab_rails['password_minimum_length']" "12"

echo "3. Setting session timeout..."
update_config "gitlab_rails['session_expire_delay']" "60"

echo "4. Enabling audit logging..."
update_config "gitlab_rails['audit_events_enabled']" "true"

echo "5. Enabling rate limiting..."
update_config "gitlab_rails['throttle_authenticated_api_enabled']" "true"
update_config "gitlab_rails['throttle_authenticated_web_enabled']" "true"

if $DRY_RUN; then
    echo ""
    echo "Run with --apply to make changes"
else
    gitlab-ctl reconfigure
    echo "Hardening applied!"
fi
```

### Security Checklist

**Immediate (Required):**
- [ ] Change default root password
- [ ] Disable public sign-ups
- [ ] Configure SSH key authentication
- [ ] Enable HTTPS with valid certificate
- [ ] Set up firewall rules (UFW)

**Recommended:**
- [ ] Enable two-factor authentication for admins
- [ ] Configure session timeout
- [ ] Enable audit logging
- [ ] Set password complexity requirements
- [ ] Configure rate limiting

**Advanced (Production):**
- [ ] Set up IP allowlist if applicable
- [ ] Enable SAST in CI pipelines
- [ ] Configure container scanning
- [ ] Set up backup encryption
- [ ] Enable secret detection

### SSL Certificate Setup

```bash
# Edit /etc/gitlab/gitlab.rb
external_url 'https://git.yourdomain.org'
letsencrypt['enable'] = true
letsencrypt['contact_emails'] = ['admin@yourdomain.org']
letsencrypt['auto_renew'] = true

# Apply changes
sudo gitlab-ctl reconfigure
```

## Troubleshooting

### Pipeline Fails to Start

1. Validate `.gitlab-ci.yml` syntax:
   ```bash
   gitlab-ci-lint .gitlab-ci.yml
   ```

2. Check GitLab Runner is available:
   - Settings > CI/CD > Runners

### Tests Fail

1. Run tests locally first:
   ```bash
   ddev exec vendor/bin/phpunit web/modules/custom
   ddev exec vendor/bin/phpcs --standard=Drupal web/modules/custom
   ```

2. Check environment differences between local and CI

### Deployment Fails

1. Verify SSH keys are configured in CI/CD variables
2. Check deployment server connectivity
3. Review deployment script output in CI job logs

### Webhook Not Triggering

1. Check GitHub/GitLab webhook deliveries
2. Verify webhook URL is accessible
3. Check server logs: `/var/log/nginx/error.log`

### Security Updates Not Applying

1. Check cron is running: `sudo systemctl status cron`
2. Check script permissions
3. Check logs: `/var/log/security-updates/update-*.log`
4. Run script manually for debugging

## Best Practices

### Testing

1. **Test Coverage** - Aim for >70% code coverage
2. **Fast Feedback** - Local tests < 1 minute, full CI < 10 minutes
3. **Test Pyramid** - Many unit tests, fewer integration, minimal E2E

### Security

1. **Webhook Security** - Always verify signatures
2. **Update Safety** - Always backup before updates
3. **Access Control** - Restrict webhook endpoints and SSH keys

### Deployment

1. **Staging First** - Always test on staging
2. **Rollback Plan** - Keep backups and document rollback procedure
3. **Communication** - Notify team of deployments

## See Also

- [Testing Guide](TESTING.md) - Test suite documentation
- [Production Deployment](PRODUCTION_DEPLOYMENT.md) - Deployment guide
- [GitLab Setup](../linode/gitlab/README.md) - GitLab server setup
