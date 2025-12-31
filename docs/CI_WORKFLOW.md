# NWP CI/CD Workflow Guide

## Overview

NWP uses GitLab CI/CD as the primary continuous integration platform. The NWP GitLab instance (`git.<domain>`) serves as the central code repository with optional mirroring to external services like GitHub.

## Architecture

```
Developer Workstation                NWP GitLab                    External Services
┌─────────────────────┐            ┌─────────────────┐            ┌─────────────────┐
│                     │            │                 │            │                 │
│  pl install mysite  │───push────▶│ git.nwpcode.org │───mirror──▶│  GitHub         │
│                     │            │                 │            │  GitLab.com     │
│  Local Development  │            │  GitLab CI/CD   │            │                 │
│                     │            │  ┌───────────┐  │            └─────────────────┘
│  ddev start         │            │  │ Pipeline  │  │
│                     │            │  │ ─────────▶│  │
└─────────────────────┘            │  │ lint      │  │
                                   │  │ test      │  │
                                   │  │ security  │  │
                                   │  │ deploy    │  │
                                   │  └───────────┘  │
                                   │                 │
                                   └─────────────────┘
```

## How Sites Are Included in CI

Sites are tracked for CI through the `cnwp.yml` configuration file. Each site can have its own CI settings that override global defaults.

### Global CI Settings

In `cnwp.yml`, the `settings.ci` section defines default CI behavior:

```yaml
settings:
  ci:
    enabled: true           # Enable CI by default for new sites
    platform: gitlab        # Primary CI platform
    auto_setup: false       # Auto-setup CI during pl install

    stages:
      lint: true            # Run linting (phpcs, shellcheck)
      test: true            # Run tests (phpunit, behat)
      security: true        # Security scanning
      deploy: false         # Auto-deploy (manual by default)

    testing:
      phpcs: true           # PHP CodeSniffer
      phpstan: true         # PHPStan static analysis
      phpstan_level: 5      # PHPStan level (0-9)
      phpunit: true         # PHPUnit tests
      behat: false          # Behat tests
```

### Per-Site CI Configuration

When a site is created with `pl install`, it gets registered in `cnwp.yml` under the `sites:` section. Each site can have its own CI configuration:

```yaml
sites:
  mysite:
    directory: /home/user/nwp/mysite
    recipe: d
    environment: development
    created: 2024-12-28T10:30:00Z
    ci:
      enabled: true                              # Enable CI for this site
      repo: git@git.nwpcode.org:nwp/mysite.git   # GitLab repository URL
      branch: main                               # Branch to run CI on
      stages:
        lint: true
        test: true
        security: true
        deploy: false
      mirrors:
        github: git@github.com:user/mysite.git   # Mirror destination
      notifications:
        email: admin@example.com
```

## Determining Which Sites Have CI

To check which sites have CI enabled:

```bash
# List all sites with CI enabled
grep -A 20 "^sites:" cnwp.yml | grep -B 5 "ci:" | grep "^  [a-z]"

# Or use yq if installed
yq '.sites | to_entries | .[] | select(.value.ci.enabled == true) | .key' cnwp.yml
```

## CI Workflow in Practice

### 1. Site Creation

When you create a new site:

```bash
pl install mysite d
```

The site is registered in `cnwp.yml`. If `settings.ci.auto_setup` is `true`, CI is automatically configured.

### 2. GitLab Repository Setup

Set up the GitLab repository for your site:

```bash
# Navigate to site directory
cd /home/user/nwp/mysite

# Initialize git if not already done
git init

# Add GitLab as origin
git remote add origin git@git.nwpcode.org:nwp/mysite.git

# Add GitHub as mirror (optional)
git remote add github git@github.com:user/mysite.git

# Push to GitLab (triggers CI)
git push -u origin main
```

### 3. .gitlab-ci.yml Configuration

Each site needs a `.gitlab-ci.yml` file in its root directory. Here's a recommended configuration for Drupal sites:

```yaml
stages:
  - lint
  - test
  - security
  - deploy

variables:
  COMPOSER_ALLOW_SUPERUSER: "1"
  PHP_VERSION: "8.2"

# Lint stage - code quality checks
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
    - composer require --dev phpstan/phpstan phpstan/phpstan-deprecation-rules mglaman/phpstan-drupal
    - vendor/bin/phpstan analyse web/modules/custom --level=5
  allow_failure: true

# Test stage - unit and integration tests
phpunit:
  stage: test
  image: php:${PHP_VERSION}-cli
  services:
    - mariadb:10.11
  variables:
    MYSQL_DATABASE: drupal
    MYSQL_ROOT_PASSWORD: root
    SIMPLETEST_DB: mysql://root:root@mariadb/drupal
    SIMPLETEST_BASE_URL: http://localhost
  before_script:
    - apt-get update && apt-get install -y git unzip libpng-dev default-mysql-client
    - docker-php-ext-install gd pdo pdo_mysql
    - curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
    - composer install --no-interaction
  script:
    - vendor/bin/phpunit --configuration phpunit.xml web/modules/custom
  allow_failure: true

# Security stage - vulnerability scanning
security_scan:
  stage: security
  image: php:${PHP_VERSION}-cli
  before_script:
    - curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
  script:
    - composer audit --no-interaction
  allow_failure: false

# Deploy stage - manual deployment trigger
deploy_staging:
  stage: deploy
  when: manual
  only:
    - main
  script:
    - echo "Deploying to staging..."
    # Add deployment commands here
    # - rsync -avz --delete ./web/ user@staging:/var/www/site/web/
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
    # Add deployment commands here
  environment:
    name: production
    url: https://example.com
```

### 4. Push and Trigger CI

Every push to GitLab triggers the CI pipeline:

```bash
# Make changes
git add .
git commit -m "Add new feature"

# Push to GitLab (triggers CI)
git push origin main

# Mirror to GitHub (if configured)
git push github main
```

### 5. Monitor Pipeline

View pipeline status:
- **GitLab UI**: Navigate to your project > CI/CD > Pipelines
- **Command line**: `git log --oneline -1` shows the commit that triggered CI

### 6. Mirror to External Services

To set up automatic mirroring from GitLab to GitHub:

1. In GitLab, go to Settings > Repository > Mirroring repositories
2. Add the GitHub repository URL
3. Configure authentication (SSH key or personal access token)
4. Enable "Mirror repository"

Or configure in `cnwp.yml`:

```yaml
sites:
  mysite:
    ci:
      mirrors:
        github: git@github.com:user/mysite.git
```

## Running CI on a Single Site

### Manual Pipeline Trigger

To manually trigger CI for a specific site:

```bash
# Via GitLab UI
# Go to your project > CI/CD > Pipelines > Run pipeline

# Via GitLab API
curl --request POST \
  --header "PRIVATE-TOKEN: <your-token>" \
  "https://git.nwpcode.org/api/v4/projects/<project-id>/pipeline" \
  --form "ref=main"
```

### Running Specific Stages

Run only specific stages by using variables:

```yaml
# In .gitlab-ci.yml, add:
lint:phpcs:
  rules:
    - if: $RUN_LINT == "true"
    - if: $CI_COMMIT_BRANCH
```

Then trigger with:

```bash
curl --request POST \
  --header "PRIVATE-TOKEN: <your-token>" \
  "https://git.nwpcode.org/api/v4/projects/<project-id>/pipeline" \
  --form "ref=main" \
  --form "variables[RUN_LINT]=true"
```

### Local CI Testing

Test CI locally before pushing:

```bash
# Install gitlab-runner locally
brew install gitlab-runner  # macOS
# or
apt-get install gitlab-runner  # Debian/Ubuntu

# Run a specific job
gitlab-runner exec docker phpcs
```

## CI Status Indicators

Sites with CI display status in various places:

1. **GitLab Project Page**: Shows pipeline status badge
2. **Commit History**: Each commit shows CI status
3. **Merge Requests**: CI must pass before merging (if configured)

Add a badge to your README:

```markdown
[![pipeline status](https://git.nwpcode.org/nwp/mysite/badges/main/pipeline.svg)](https://git.nwpcode.org/nwp/mysite/-/commits/main)
```

## Troubleshooting

### Pipeline Fails to Start

1. Check `.gitlab-ci.yml` syntax:
   ```bash
   # Validate locally
   gitlab-ci-lint .gitlab-ci.yml

   # Or use the GitLab API
   curl --header "Content-Type: application/json" \
     "https://git.nwpcode.org/api/v4/ci/lint" \
     --data '{"content": "'"$(cat .gitlab-ci.yml)"'"}'
   ```

2. Ensure GitLab Runner is available:
   - Check Settings > CI/CD > Runners

### Tests Fail

1. Run tests locally first:
   ```bash
   ddev exec vendor/bin/phpunit web/modules/custom
   ddev exec vendor/bin/phpcs --standard=Drupal web/modules/custom
   ```

2. Check environment differences between local and CI

### Deployment Fails

1. Verify SSH keys are configured in GitLab CI/CD variables
2. Check deployment server connectivity
3. Review deployment script output in CI job logs

## Security Considerations

1. **Never commit secrets** - Use GitLab CI/CD variables
2. **Protected branches** - Require CI to pass before merge
3. **Review permissions** - Limit who can trigger deployments
4. **Audit deployments** - Log all production deployments

## Related Documentation

- [CI Integration Recommendations](CI_INTEGRATION_RECOMMENDATIONS.md) - Architecture and setup
- [GitLab Hardening](../git/gitlab_harden.sh) - Security hardening script
- [NWP Configuration](../example.cnwp.yml) - Full configuration reference
