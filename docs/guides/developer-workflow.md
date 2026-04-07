# NWP Developer Lifecycle Guide

A comprehensive guide for Drupal developers from project initialization to production deployment with automated security updates.

---

## Table of Contents

1. [Overview](#1-overview)
2. [Phase 1: Project Initialization](#2-phase-1-project-initialization)
3. [Phase 2: Local Development](#3-phase-2-local-development)
4. [Phase 3: Version Control & Collaboration](#4-phase-3-version-control--collaboration)
5. [Phase 4: Continuous Integration](#5-phase-4-continuous-integration)
6. [Phase 5: Testing Strategy](#6-phase-5-testing-strategy)
7. [Phase 6: Staging Deployment](#7-phase-6-staging-deployment)
8. [Phase 7: Production Deployment](#8-phase-7-production-deployment)
9. [Phase 8: Automated Security Updates](#9-phase-8-automated-security-updates)
10. [Phase 9: Monitoring & Maintenance](#10-phase-9-monitoring--maintenance)
11. [Quick Reference](#11-quick-reference)

---

## 1. Overview

This guide documents the complete developer lifecycle for NWP-managed Drupal sites, incorporating best practices from:
- [Vortex](https://www.vortextemplate.com/) Drupal project template
- [Drupal.org CI/CD documentation](https://www.drupal.org/docs/develop/git)
- Industry standards for enterprise Drupal development

### The Code Lifecycle

```
Local Development → Git Repository → CI Pipeline → Staging → Production
        ↓                ↓               ↓            ↓          ↓
    Write code      Push/PR        Build/Test    Deploy     Monitor
                                                            ↓
                                              Automated Security Updates
```

---

## 2. Phase 1: Project Initialization

### 2.1 Prerequisites Check

Before starting, ensure your system has:

```bash
# Run NWP setup to check/install prerequisites
./setup.sh
```

Required components:
- Docker (container runtime)
- DDEV (local development environment)
- Composer (PHP dependency management)
- Git (version control)

### 2.2 Create New Project

```bash
# List available recipes
./install.sh --list

# Install using a recipe (e.g., Drupal CMS, OpenSocial)
./install.sh myproject

# Or install with specific recipe
./install.sh -r d myproject      # Standard Drupal
./install.sh -r os myproject     # OpenSocial
./install.sh -r nwp myproject    # NWP custom recipe
```

### 2.3 Initial Configuration

After installation:

1. **Update nwp.yml** with site-specific settings:
   ```yaml
   myproject:
     recipe: d
     php_version: "8.3"
     drupal_version: "^11"
     profile: standard
     dev_modules: devel kint webprofiler stage_file_proxy
   ```

2. **Configure production details** (for later deployment):
   ```yaml
   myproject:
     live:
       server_ip: your.server.ip
       domain: example.com
       ssh_user: deploy
   ```

3. **Initialize Git repository**:
   ```bash
   cd myproject
   git init
   git add .
   git commit -m "Initial commit from NWP recipe"
   ```

---

## 3. Phase 2: Local Development

### 3.1 Daily Development Workflow

```bash
# Start the day
cd myproject
ddev start

# Fetch latest code
git pull origin develop

# Fetch production database (if available)
./backup.sh -d myproject --from-prod  # Creates sanitized backup
./restore.sh -d myproject             # Restores to local

# Run updates
ddev drush updb -y
ddev drush cim -y
ddev drush cr
```

### 3.2 Feature Development

1. **Create feature branch**:
   ```bash
   git checkout -b feature/my-feature develop
   ```

2. **Make changes and test locally**:
   ```bash
   # Run code quality checks
   ddev exec vendor/bin/phpcs web/modules/custom
   ddev exec vendor/bin/phpstan analyse web/modules/custom

   # Run tests
   ddev exec vendor/bin/phpunit
   ```

3. **Export configuration**:
   ```bash
   ddev drush cex -y
   git add config/
   git commit -m "feat: Add my-feature configuration"
   ```

### 3.3 Database Management

```bash
# Export local database
./backup.sh -d myproject

# Import specific backup
./restore.sh myproject sitebackups/myproject/backup-20250105.sql.gz

# Clone database between environments
./copy.sh myproject myproject_stg --db-only
```

### 3.4 Configuration Management Best Practices

- **Always export config** before committing code changes
- **Use config splits** for environment-specific settings
- **Never commit** `settings.local.php` or sensitive config
- **Review config changes** in PRs carefully

---

## 4. Phase 3: Version Control & Collaboration

### 4.1 Branch Strategy

```
production (or main)    ← Production releases
    ↑
  staging               ← Pre-production testing
    ↑
  develop               ← Integration branch
    ↑
feature/*, bugfix/*     ← Development branches
```

### 4.2 Commit Guidelines

```bash
# Good commit messages
git commit -m "feat: Add user registration form"
git commit -m "fix: Resolve login redirect issue"
git commit -m "docs: Update README installation steps"
git commit -m "refactor: Extract validation to service"
git commit -m "test: Add coverage for user service"
```

### 4.3 Pull Request Workflow

1. **Create PR** from feature branch to develop
2. **Ensure CI passes** (all tests green)
3. **Request code review** from team member
4. **Address feedback** and update PR
5. **Merge** when approved and CI passes

### 4.4 Protected Branches

Configure in GitLab/GitHub:
- `main`/`production`: Require PR, CI pass, review approval
- `staging`: Require PR, CI pass
- `develop`: Require CI pass

---

## 5. Phase 4: Continuous Integration

### 5.1 CI Pipeline Structure

A robust CI pipeline has three stages:

```yaml
# .gitlab-ci.yml example structure
stages:
  - database    # Fetch/cache production database
  - build       # Build, test, lint
  - deploy      # Deploy to environment
```

### 5.2 Database Job (Nightly)

Runs on schedule to cache production database:

```yaml
database:nightly:
  stage: database
  rules:
    - if: $CI_PIPELINE_SOURCE == "schedule"
  script:
    - ./backup.sh -d $SITE_NAME --from-prod --sanitize
    - # Cache the sanitized database for 24 hours
```

### 5.3 Build Job

```yaml
build:
  stage: build
  script:
    # Assembly phase
    - ddev start
    - ddev composer install --no-dev
    - ddev exec npm ci && npm run build

    # Provision phase
    - ddev drush sql:cli < .data/db.sql
    - ddev drush deploy

    # Testing phase
    - ddev exec vendor/bin/phpcs
    - ddev exec vendor/bin/phpstan analyse
    - ddev exec vendor/bin/phpunit
    - ddev exec vendor/bin/behat
```

### 5.4 Deployment Triggers

| Branch | Environment | Trigger |
|--------|-------------|---------|
| `feature/*` | None (PR preview only) | On PR |
| `develop` | Development | On merge |
| `staging` | Staging | On merge |
| `production` | Production | On merge/tag |

---

## 6. Phase 5: Testing Strategy

### 6.1 Test Types

| Type | Tool | Purpose | Duration |
|------|------|---------|----------|
| Unit | PHPUnit | Test isolated functions | ~2 min |
| Kernel | PHPUnit | Test with database | ~5 min |
| Functional | PHPUnit | Test with browser | ~10 min |
| BDD | Behat | End-to-end user journeys | ~15 min |
| Static Analysis | PHPStan | Type checking | ~1 min |
| Code Style | PHPCS | Coding standards | ~30 sec |
| Security | composer audit | Vulnerability scan | ~30 sec |

### 6.2 NWP Test Presets

```bash
# Quick checks (for frequent runs)
./dev2stg.sh -t quick myproject    # phpcs, eslint (~1 min)

# Essential tests (recommended for PRs)
./dev2stg.sh -t essential myproject    # phpunit, phpstan, phpcs (~4 min)

# Full test suite (pre-production)
./dev2stg.sh -t full myproject    # All tests (~15 min)

# Security focused
./dev2stg.sh -t security-only myproject    # security, phpstan (~2 min)
```

### 6.3 Test Coverage Requirements

Recommended minimums:
- **Unit tests**: 80% coverage on custom modules
- **Behat tests**: Cover all critical user journeys
- **Static analysis**: PHPStan level 5+ with no errors

### 6.4 Writing Effective Tests

```php
// Example PHPUnit test
class UserServiceTest extends UnitTestCase {
  public function testUserRegistration(): void {
    $user = $this->userService->register('test@example.com');
    $this->assertNotNull($user->id());
    $this->assertEquals('test@example.com', $user->getEmail());
  }
}
```

```gherkin
# Example Behat feature
Feature: User Login
  Scenario: Valid credentials
    Given I am on "/user/login"
    When I fill in "Username" with "admin"
    And I fill in "Password" with "admin"
    And I press "Log in"
    Then I should see "Log out"
```

---

## 7. Phase 6: Staging Deployment

### 7.1 Deploy to Staging

```bash
# Interactive mode (recommended for first deployment)
./dev2stg.sh myproject

# Automated mode (for CI/CD)
./dev2stg.sh -y --db-source=auto -t essential myproject
```

### 7.2 Deployment Steps

The `dev2stg.sh` workflow:

1. **Preflight checks** - Validate environment
2. **State detection** - Analyze source and target
3. **Create staging** - If doesn't exist
4. **Export config** - From development
5. **Sync files** - Rsync with exclusions
6. **Database setup** - From selected source
7. **Composer install** - Production dependencies
8. **Database updates** - `drush updb`
9. **Import config** - `drush cim` with retry
10. **Run tests** - Selected test suite
11. **Finalize** - Clear cache, show URL

### 7.3 Database Sources

| Source | Use Case |
|--------|----------|
| `auto` | Intelligent selection (recommended) |
| `production` | Fresh from live site |
| `backup:/path` | Specific backup file |
| `development` | Clone from dev site |

### 7.4 Post-Deployment Verification

```bash
# Check site status
ddev drush status

# Verify config sync
ddev drush config:status

# Test critical pages
curl -I https://myproject-stg.ddev.site/
```

---

## 8. Phase 7: Production Deployment

### 8.1 Pre-Production Checklist

- [ ] All tests passing on staging
- [ ] Code review approved
- [ ] Configuration exported and committed
- [ ] Database migrations tested
- [ ] Performance testing completed
- [ ] Security scan clean
- [ ] Backup of production database
- [ ] Deployment window scheduled

### 8.2 Deploy to Production

```bash
# Push staging to production
./stg2prod.sh myproject

# Or direct deployment (with full preflight)
./stg2prod.sh --preflight myproject
```

### 8.3 Production Deployment Steps

1. **Maintenance mode** - Enable on production
2. **Database backup** - Full backup before changes
3. **Code sync** - Rsync from staging
4. **Database updates** - `drush updb`
5. **Config import** - `drush cim`
6. **Cache clear** - `drush cr`
7. **Maintenance off** - Disable maintenance mode
8. **Verify** - Health checks

### 8.4 Rollback Procedure

If deployment fails:

```bash
# Restore previous database
./restore.sh myproject sitebackups/myproject/pre-deploy-backup.sql.gz

# Revert code (if using git deployment)
git revert HEAD
git push

# Or restore from backup
./rollback.sh myproject
```

---

## 9. Phase 8: Automated Security Updates

### 9.1 Renovate Integration

Configure Renovate for automated dependency updates:

```json
// renovate.json
{
  "extends": [
    "github>drevops/renovate-drupal"
  ],
  "schedule": {
    "drupal-core": "before 6am on Monday",
    "drupal-contrib": "before 6am on Wednesday"
  },
  "automerge": false,
  "prHourlyLimit": 2
}
```

### 9.2 Update Workflow

```
Renovate detects update → Creates PR → CI runs tests → Review → Merge → Deploy
```

### 9.3 Security Update Priorities

| Priority | Response Time | Update Type |
|----------|---------------|-------------|
| Critical | Same day | Core security, high-severity contrib |
| High | 48 hours | Moderate security issues |
| Normal | 1 week | Regular updates |
| Low | Monthly | Non-critical updates |

### 9.4 Automated Testing of Updates

Configure CI to run full test suite on Renovate PRs:

```yaml
# .gitlab-ci.yml
test:renovate:
  rules:
    - if: $CI_MERGE_REQUEST_SOURCE_BRANCH_NAME =~ /^renovate\//
  script:
    - ./dev2stg.sh -y -t full $SITE_NAME
```

### 9.5 Auto-Merge for Patch Updates

For low-risk patch updates:

```json
// renovate.json
{
  "packageRules": [
    {
      "matchUpdateTypes": ["patch"],
      "matchPackagePatterns": ["^drupal/"],
      "automerge": true,
      "automergeType": "pr"
    }
  ]
}
```

---

## 10. Phase 9: Monitoring & Maintenance

### 10.1 Health Monitoring

Set up monitoring for:
- **Uptime**: Site availability
- **Performance**: Page load times
- **Errors**: PHP errors, Drupal watchdog
- **Security**: Failed login attempts, suspicious activity

### 10.2 Regular Maintenance Tasks

| Frequency | Task |
|-----------|------|
| Daily | Check error logs, verify backups |
| Weekly | Review security advisories, check updates |
| Monthly | Performance audit, dependency review |
| Quarterly | Security audit, infrastructure review |

### 10.3 Backup Strategy

```bash
# Daily database backup
./backup.sh -d myproject

# Weekly full backup
./backup.sh myproject

# Retention: 7 daily, 4 weekly, 12 monthly
```

### 10.4 Documentation Updates

Keep documentation current:
- Update README with new features
- Document configuration changes
- Record deployment procedures
- Maintain change log

---

## 11. Quick Reference

### Common Commands

```bash
# Installation
./install.sh -r d mysite              # New Drupal site
./install.sh -r os mysite             # New OpenSocial site

# Local development
ddev start                            # Start environment
ddev drush cr                         # Clear cache
ddev drush cex                        # Export config
ddev drush cim                        # Import config

# Deployment
./dev2stg.sh mysite                   # Dev to staging (TUI)
./dev2stg.sh -y mysite                # Dev to staging (auto)
./stg2prod.sh mysite                  # Staging to production

# Testing
./dev2stg.sh -t quick mysite          # Quick tests
./dev2stg.sh -t essential mysite      # Essential tests
./dev2stg.sh -t full mysite           # Full test suite

# Backup/Restore
./backup.sh mysite                    # Full backup
./backup.sh -d mysite                 # Database only
./restore.sh mysite backup.sql.gz     # Restore backup

# Maintenance
./make.sh -v mysite                   # Enable dev mode
./make.sh -p mysite                   # Enable prod mode
./security.sh mysite                  # Security check
```

### Environment Variables

```bash
export SITE_NAME=myproject
export DDEV_TLD=ddev.site
export CI_COMMIT_BRANCH=develop
```

### File Locations

```
/home/rob/nwp/
├── myproject/              # Site directory
│   ├── web/               # Drupal webroot
│   ├── config/            # Configuration sync
│   ├── .ddev/             # DDEV configuration
│   └── composer.json      # Dependencies
├── sitebackups/           # Backup storage
│   └── myproject/
├── nwp.yml               # Site configuration
└── .secrets.yml           # API tokens (infrastructure)
```

---

## References

- [Vortex Documentation](https://www.vortextemplate.com/)
- [Drupal CI/CD Best Practices](https://qtatech.com/en/article/automating-drupal-site-deployments-cicd)
- [Renovate for Drupal](https://github.com/drevops/renovate-drupal)
- [Drupal Automatic Updates](https://new.drupal.org/docs/drupal-cms/updates/configure-automatic-updates)
- [CI/CD for Enterprise Drupal 2025](https://www.augustinfotech.com/blogs/ci-cd-for-enterprise-drupal-offshore-implementation-guide-for-2025/)
