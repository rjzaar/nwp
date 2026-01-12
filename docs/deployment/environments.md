# NWP Environment Management

This document describes the environment hierarchy, configuration splits, and preview environment setup for NWP-managed Drupal sites.

## Table of Contents

- [Environment Hierarchy](#environment-hierarchy)
- [Configuration Splits](#configuration-splits)
- [Preview Environments](#preview-environments)
- [CI/CD Preview Configuration](#cicd-preview-configuration)
- [Deployment Scripts](#deployment-scripts)
- [Best Practices](#best-practices)

## Environment Hierarchy

NWP supports a four-tier environment hierarchy for managing Drupal sites:

```
┌─────────────┐
│    Local    │  Developer workstations (DDEV)
└──────┬──────┘
       │
┌──────▼──────┐
│     Dev     │  Development server (optional, shared dev environment)
└──────┬──────┘
       │
┌──────▼──────┐
│   Staging   │  Pre-production testing (mirrors production)
└──────┬──────┘
       │
┌──────▼──────┐
│ Production  │  Live site serving traffic
└─────────────┘
```

### Local Environment

- **Purpose**: Individual developer workspaces
- **Technology**: DDEV containerized environment
- **Database**: Sanitized copy from production or staging
- **Domain**: `*.ddev.site` (automatically managed by DDEV)
- **Access**: Localhost only

**Setup**:
```bash
# Start local environment
ddev start

# Import sanitized database
ddev import-db --src=.data/db.sql.gz

# Access site
ddev launch
```

### Dev Environment (Optional)

- **Purpose**: Shared development server for team collaboration
- **Technology**: DDEV or traditional LAMP stack
- **Database**: Sanitized production data, refreshed periodically
- **Domain**: `*-dev.example.com`
- **Access**: Internal network or VPN

**Typical Use Cases**:
- Testing integrations before staging
- Demonstrating features to stakeholders
- QA testing before staging deployment

### Staging Environment

- **Purpose**: Pre-production testing that mirrors production
- **Technology**: Identical to production (DDEV or server environment)
- **Database**: Recent copy of production data (sanitized)
- **Domain**: `*-stg.example.com` or `staging.example.com`
- **Access**: Protected by basic auth or IP whitelist

**Key Characteristics**:
- Configuration identical to production
- Same modules, themes, and versions
- Performance testing environment
- Final validation before production deployment

**Deployment**:
```bash
# Using NWP deployment script
./dev2stg.sh -y --db-source=auto -t essential <site-name>
```

### Production Environment

- **Purpose**: Live site serving end users
- **Technology**: Optimized server environment or DDEV
- **Database**: Production data
- **Domain**: `example.com` or `www.example.com`
- **Access**: Public (or membership-restricted)

**Key Characteristics**:
- Highly available and optimized for performance
- Automated backups before deployments
- Comprehensive monitoring and alerting
- Restricted access to deployment tools

**Deployment**:
```bash
# Using NWP deployment script (with manual approval)
./stg2prod.sh -y <site-name>
```

## Configuration Splits

NWP uses Drupal's Configuration Split module to manage environment-specific configurations. This allows different settings per environment while maintaining a shared base configuration.

### Directory Structure

```
config/
├── default/          # Base configuration (shared across all environments)
│   ├── core.extension.yml
│   ├── system.site.yml
│   └── ...
├── dev/              # Development-specific overrides
│   ├── system.performance.yml
│   ├── devel.settings.yml
│   └── ...
├── staging/          # Staging-specific overrides
│   ├── system.performance.yml
│   ├── environment_indicator.settings.yml
│   └── ...
└── production/       # Production-specific overrides
    ├── system.performance.yml
    ├── shield.settings.yml
    └── ...
```

### Configuration Workflow

1. **Export Base Configuration**:
   ```bash
   ddev drush config:export -y
   ```

2. **Export Environment Split**:
   ```bash
   # Export staging-specific config
   ddev drush config-split:export staging
   ```

3. **Import Configuration**:
   ```bash
   # Import all configuration (base + environment split)
   ddev drush deploy
   ```

### Common Split Configurations

#### Development Environment (`config/dev/`)

- **Development modules**: Enabled (Devel, Stage File Proxy, etc.)
- **Caching**: Disabled or minimal
- **Error reporting**: Verbose
- **CSS/JS aggregation**: Disabled
- **Test mail**: Enabled (prevents sending real emails)

Example `config/dev/system.performance.yml`:
```yaml
cache:
  page:
    max_age: 0
css:
  preprocess: false
js:
  preprocess: false
```

#### Staging Environment (`config/staging/`)

- **Development modules**: Disabled
- **Caching**: Enabled (matching production)
- **Error reporting**: Production-level
- **Environment indicator**: Yellow/Orange banner
- **Shield**: Optional password protection

Example `config/staging/environment_indicator.settings.yml`:
```yaml
name: 'Staging'
bg_color: '#FFA500'
fg_color: '#000000'
```

#### Production Environment (`config/production/`)

- **Development modules**: Disabled
- **Caching**: Fully enabled and optimized
- **Error reporting**: Log only (no display)
- **Environment indicator**: Red banner (if used)
- **Security modules**: Enabled (Shield, Security Kit, etc.)

Example `config/production/system.performance.yml`:
```yaml
cache:
  page:
    max_age: 3600
css:
  preprocess: true
js:
  preprocess: true
fast_404:
  enabled: true
```

### Setting Up Configuration Splits

1. **Install Config Split**:
   ```bash
   ddev composer require drupal/config_split
   ddev drush en config_split -y
   ```

2. **Create Split Configurations**:
   - Navigate to `/admin/config/development/configuration/config-split`
   - Create splits for: `dev`, `staging`, `production`
   - Configure which modules/configs belong to each split

3. **Configure settings.php**:
   ```php
   // Set the active config split based on environment
   if (getenv('DDEV_PROJECT')) {
     // Local/Dev environment
     $config['config_split.config_split.dev']['status'] = TRUE;
     $config['config_split.config_split.staging']['status'] = FALSE;
     $config['config_split.config_split.production']['status'] = FALSE;
   } elseif (getenv('ENVIRONMENT') === 'staging') {
     // Staging environment
     $config['config_split.config_split.dev']['status'] = FALSE;
     $config['config_split.config_split.staging']['status'] = TRUE;
     $config['config_split.config_split.production']['status'] = FALSE;
   } else {
     // Production environment
     $config['config_split.config_split.dev']['status'] = FALSE;
     $config['config_split.config_split.staging']['status'] = FALSE;
     $config['config_split.config_split.production']['status'] = TRUE;
   }
   ```

## Preview Environments

Preview environments are ephemeral, isolated environments created for pull requests and merge requests. They allow developers and reviewers to test changes in a live environment before merging code.

### Characteristics

- **Ephemeral**: Created on-demand, destroyed after PR/MR closes
- **Isolated**: Each PR gets its own environment
- **Automated**: Created and destroyed by CI/CD pipeline
- **Sanitized**: Uses sanitized production database
- **Accessible**: Unique URL for each preview

### Preview Environment Naming

Preview environments follow a consistent naming pattern:
- **Pull Request**: `pr-123` (GitHub)
- **Merge Request**: `mr-456` (GitLab)
- **Branch**: `feature-new-component` (fallback)

### Creating Preview Environments

**Manual Creation**:
```bash
./scripts/ci/create-preview.sh pr-123
```

**Automated (CI/CD)**:
- Automatically triggered when PR/MR is opened
- Uses cached database from nightly builds
- Deploys latest code from the branch
- Returns preview URL in CI/CD output

**What Gets Created**:
1. New DDEV project with unique name
2. Imported and sanitized database
3. Deployed code from PR/MR branch
4. Environment-specific configuration
5. Accessible URL for testing

### Cleaning Up Preview Environments

**Manual Cleanup**:
```bash
./scripts/ci/cleanup-preview.sh pr-123
```

**Automated Cleanup**:
- Automatically triggered when PR/MR is closed
- Can be manually triggered from CI/CD interface
- Removes DDEV project and all data
- Cleans up DNS/routing if configured

**Auto-Stop**:
- Preview environments auto-stop after 1 week of inactivity
- Prevents resource waste from forgotten PRs

### Preview Environment Workflow

```
┌──────────────────┐
│  Open PR/MR      │
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│  CI creates      │
│  preview env     │
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│  Post URL to     │
│  PR/MR comments  │
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│  Review & test   │
│  in preview      │
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│  Merge or close  │
│  PR/MR           │
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│  CI destroys     │
│  preview env     │
└──────────────────┘
```

## CI/CD Preview Configuration

### GitLab CI/CD

Add preview environment jobs to `.gitlab-ci.yml`:

```yaml
################################################################################
# PREVIEW ENVIRONMENTS
# Create isolated preview environments for merge requests
################################################################################

deploy:preview:
  stage: deploy
  needs: ["build"]
  rules:
    # Only run for merge requests
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
  script:
    - echo "Creating preview environment for MR $CI_MERGE_REQUEST_IID..."
    - ./scripts/ci/create-preview.sh "mr-$CI_MERGE_REQUEST_IID"
  environment:
    name: preview/mr-$CI_MERGE_REQUEST_IID
    url: https://mr-$CI_MERGE_REQUEST_IID.ddev.site
    on_stop: cleanup:preview
    auto_stop_in: 1 week
  artifacts:
    reports:
      dotenv: preview.env
  tags:
    - nwp
  allow_failure: false

cleanup:preview:
  stage: deploy
  rules:
    # Run when merge request is closed or on manual trigger
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
      when: manual
  script:
    - echo "Cleaning up preview environment for MR $CI_MERGE_REQUEST_IID..."
    - ./scripts/ci/cleanup-preview.sh "mr-$CI_MERGE_REQUEST_IID"
  environment:
    name: preview/mr-$CI_MERGE_REQUEST_IID
    action: stop
  tags:
    - nwp
  allow_failure: true
```

**GitLab Environment Features**:
- Preview URL shown in merge request
- "View Deployment" button in MR interface
- Manual cleanup via GitLab UI
- Auto-stop after 1 week

### GitHub Actions

Add preview environment job to `.github/workflows/build-test-deploy.yml`:

```yaml
  # Preview environment for pull requests
  deploy-preview:
    name: Deploy Preview Environment
    runs-on: ubuntu-latest
    needs: [build]
    if: github.event_name == 'pull_request'
    environment:
      name: preview/pr-${{ github.event.pull_request.number }}
      url: https://pr-${{ github.event.pull_request.number }}.ddev.site
    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Setup DDEV
        uses: ddev/github-action-setup-ddev@v1

      - name: Create preview environment
        id: preview
        run: |
          ./scripts/ci/create-preview.sh "pr-${{ github.event.pull_request.number }}"

      - name: Comment PR with preview URL
        uses: actions/github-script@v7
        with:
          script: |
            github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: '## Preview Environment Ready\n\nYour preview environment is ready for testing:\n\n**Preview URL:** https://pr-${{ github.event.pull_request.number }}.ddev.site\n\nThis environment will be automatically cleaned up when the PR is closed.'
            })

  # Cleanup preview when PR is closed
  cleanup-preview:
    name: Cleanup Preview Environment
    runs-on: ubuntu-latest
    if: github.event_name == 'pull_request' && github.event.action == 'closed'
    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Setup DDEV
        uses: ddev/github-action-setup-ddev@v1

      - name: Cleanup preview environment
        run: |
          ./scripts/ci/cleanup-preview.sh "pr-${{ github.event.pull_request.number }}"

      - name: Comment PR
        uses: actions/github-script@v7
        with:
          script: |
            github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: 'Preview environment has been cleaned up.'
            })
```

**GitHub Environment Features**:
- Preview URL in PR "Deployments" section
- Automatic comment with preview URL
- Cleanup triggered on PR close
- Environment protection rules support

## Deployment Scripts

NWP provides automated deployment scripts for moving code and data between environments:

### dev2stg.sh - Deploy to Staging

Promotes code and optionally data from development to staging environment.

**Usage**:
```bash
./dev2stg.sh [OPTIONS] <site-name>
```

**Options**:
- `-y`: Auto-confirm (skip prompts)
- `--db-source=auto|dev|prod`: Database source
- `-t essential|full`: Test suite to run

**Example**:
```bash
# Deploy with essential tests
./dev2stg.sh -y --db-source=auto -t essential mysite

# Deploy with full test suite
./dev2stg.sh --db-source=prod -t full mysite
```

**Process**:
1. Validates staging environment
2. Creates pre-deployment backup
3. Syncs code from dev/local
4. Optionally refreshes database
5. Runs `drush deploy` (updb, cim, cr)
6. Executes test suite
7. Reports results

### stg2prod.sh - Deploy to Production

Promotes validated code from staging to production environment.

**Usage**:
```bash
./stg2prod.sh [OPTIONS] <site-name>
```

**Options**:
- `-y`: Auto-confirm (requires manual approval in most cases)

**Example**:
```bash
# Deploy to production (with confirmation)
./stg2prod.sh mysite

# Auto-confirm (use with caution)
./stg2prod.sh -y mysite
```

**Process**:
1. Verifies staging is clean and tested
2. Creates production backup
3. Enables maintenance mode
4. Syncs code from staging
5. Runs `drush deploy` (updb, cim, cr)
6. Runs smoke tests
7. Disables maintenance mode
8. Creates deployment tag

**Safety Features**:
- Requires manual confirmation
- Automatic rollback on failure
- Pre-deployment backups
- Health checks after deployment

## Best Practices

### Database Management

1. **Use Sanitized Data**: Never use production data with PII in dev/preview environments
   ```bash
   ./scripts/ci/fetch-db.sh --sanitize
   ```

2. **Refresh Regularly**: Keep dev/staging databases reasonably current
   - Nightly automated refresh recommended
   - Cache for CI/CD to avoid repeated downloads

3. **Test with Production-Like Data**: Staging should mirror production data volume

### Configuration Management

1. **Always Use Config Splits**: Avoid hardcoding environment differences
2. **Version Control Config**: Commit all configuration to git
3. **Test Config Import**: Verify `drush deploy` works in all environments
4. **Document Overrides**: Comment any manual config changes

### Preview Environments

1. **Keep PRs Small**: Large PRs create large preview environments
2. **Close Stale PRs**: Auto-cleanup prevents resource waste
3. **Test Before Merging**: Always test in preview before approving
4. **Sanitize Data**: Preview environments should never contain real user data

### Deployment

1. **Test in Staging First**: Never skip staging
2. **Deploy During Low Traffic**: Schedule production deployments appropriately
3. **Have a Rollback Plan**: Know how to revert quickly
4. **Monitor After Deployment**: Watch logs and metrics post-deployment
5. **Use Feature Flags**: For gradual rollouts and easy rollbacks

### Security

1. **Protect Non-Production**: Use basic auth, VPN, or IP whitelisting
2. **Sanitize Databases**: Remove PII, reset passwords, disable outbound email
3. **Secure Credentials**: Use environment variables, never commit secrets
4. **Review Permissions**: Restrict production access to authorized personnel

### Performance

1. **Enable Caching in Staging**: Match production performance settings
2. **Test Under Load**: Use staging for performance testing
3. **Monitor Resource Usage**: Track preview environment resource consumption
4. **Optimize Database Dumps**: Compress and cache for faster imports

## Troubleshooting

### Preview Environment Won't Start

**Problem**: DDEV fails to start preview environment

**Solution**:
```bash
# Check DDEV status
ddev describe

# View DDEV logs
ddev logs

# Restart Docker
sudo systemctl restart docker

# Clean up and retry
./scripts/ci/cleanup-preview.sh pr-123
./scripts/ci/create-preview.sh pr-123
```

### Configuration Import Fails

**Problem**: `drush deploy` fails with configuration errors

**Solution**:
```bash
# Check configuration status
ddev drush config:status

# Clear cache first
ddev drush cr

# Import config with verbose output
ddev drush config:import -y -v

# Check for override conflicts
ddev drush config-split:status
```

### Database Import Timeout

**Problem**: Large database import times out in CI/CD

**Solution**:
- Use nightly database caching
- Reduce database size (sanitize more aggressively)
- Increase CI/CD timeout settings
- Consider partial database import for preview environments

### Preview URL Not Accessible

**Problem**: Preview environment created but URL doesn't work

**Solution**:
```bash
# Verify DDEV is running
ddev describe

# Check DDEV router
ddev router-status

# Restart DDEV router
ddev router restart

# Check /etc/hosts (if using custom domains)
cat /etc/hosts | grep ddev
```

## Related Documentation

- [CI/CD Pipeline Configuration](CICD.md)
- [Deployment Guide](LINODE_DEPLOYMENT.md)
- [Developer Lifecycle Guide](DEVELOPER_LIFECYCLE_GUIDE.md)
- [GitLab CI/CD Configuration](../.gitlab-ci.yml)
- [GitHub Actions Workflow](../.github/workflows/build-test-deploy.yml)
