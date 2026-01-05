# Advanced Deployment Strategies for NWP

This document covers advanced deployment strategies implemented in NWP for zero-downtime deployments, gradual rollouts, and continuous performance monitoring.

## Table of Contents

1. [Blue-Green Deployment](#blue-green-deployment)
2. [Canary Releases](#canary-releases)
3. [Performance Baseline Tracking](#performance-baseline-tracking)
4. [Visual Regression Testing](#visual-regression-testing)
5. [Complete Deployment Workflow](#complete-deployment-workflow)
6. [Configuration Examples](#configuration-examples)
7. [Troubleshooting](#troubleshooting)

---

## Blue-Green Deployment

Blue-green deployment is a release strategy that reduces downtime and risk by running two identical production environments (blue and green). At any time, only one environment serves production traffic.

### How It Works

1. **Blue (Current Production)**: Serves all production traffic
2. **Green (New Version)**: Deploy and test new version
3. **Validation**: Run comprehensive tests on green environment
4. **Switch**: Instantly switch traffic from blue to green
5. **Rollback**: If issues arise, instantly switch back to blue

### Basic Blue-Green Deployment

```bash
# Deploy to test environment (green)
cd /var/www/test
git pull origin main
composer install --no-dev --optimize-autoloader
vendor/bin/drush updatedb -y
vendor/bin/drush cr

# Run health checks on test
/root/nwp-healthcheck.sh --domain example.com /var/www/test

# Swap test to production
/root/nwp-swap-prod.sh --webroot /var/www
```

### Enhanced Blue-Green with Traffic Shifting

The `nwp-bluegreen-deploy.sh` script extends basic blue-green with advanced features:

```bash
# Full deployment with all checks
/root/nwp-bluegreen-deploy.sh \
  --domain example.com \
  --webroot /var/www

# Skip backup (faster, but riskier)
/root/nwp-bluegreen-deploy.sh \
  --domain example.com \
  --skip-backup

# Auto-confirm deployment (CI/CD pipelines)
/root/nwp-bluegreen-deploy.sh \
  --domain example.com \
  --yes \
  --rollback-on-fail
```

### Blue-Green with Canary Mode

Combine blue-green deployment with canary testing:

```bash
# Deploy with 10% canary traffic for 5 minutes
/root/nwp-bluegreen-deploy.sh \
  --domain example.com \
  --canary \
  --canary-percent 10 \
  --canary-duration 300
```

### Deployment Steps

The enhanced blue-green deployment performs these steps:

1. **Pre-Deployment Validation**
   - Verify directory structure
   - Check test environment readiness
   - Validate Drupal installation

2. **Smoke Tests on Test Environment**
   - Run health checks
   - Test Drupal bootstrap
   - Verify database connectivity

3. **Backup Creation**
   - Database backup
   - Deployment log entry
   - Backup retention

4. **Canary Phase (Optional)**
   - Route percentage of traffic to test
   - Monitor for errors
   - Auto-rollback on failures

5. **Blue-Green Swap**
   - Atomic directory swap
   - Apply production settings
   - Fix permissions
   - Clear caches

6. **Post-Deployment Health Checks**
   - Comprehensive validation
   - Auto-rollback on failure
   - Performance verification

7. **Deployment Logging**
   - Log all deployment events
   - Track success/failure rates
   - Maintain audit trail

---

## Canary Releases

Canary releases minimize deployment risk by exposing changes to a small subset of users or servers first, then gradually increasing exposure if no issues are detected.

### Canary Deployment Strategy

```
Production Traffic (100%)
     ↓
┌────┴────┐
│ Router  │ (Load Balancer / Nginx)
└────┬────┘
     │
     ├─ 90% → Stable Version (prod)
     │
     └─ 10% → Canary Version (canary)
                  ↓
            Monitor for:
            - Error rates
            - Performance
            - User feedback
```

### Deploying a Canary

```bash
# 1. Prepare canary deployment at /var/www/canary
cd /var/www/canary
git pull origin main
composer install --no-dev
vendor/bin/drush updatedb -y
vendor/bin/drush cr

# 2. Deploy canary with 10% traffic for 5 minutes
/root/nwp-canary.sh deploy \
  --domain example.com \
  --percent 10 \
  --duration 300

# 3. Check canary status
/root/nwp-canary.sh status

# 4. Promote to full production (if successful)
/root/nwp-canary.sh promote

# Or rollback (if issues detected)
/root/nwp-canary.sh rollback
```

### Auto-Promotion

Automatically promote canary if all checks pass:

```bash
/root/nwp-canary.sh deploy \
  --domain example.com \
  --percent 10 \
  --duration 600 \
  --auto-promote \
  --auto-rollback
```

### Canary Monitoring

During the canary phase, the script monitors:

- **Health Checks**: HTTP responses, Drupal bootstrap
- **Error Rates**: Threshold-based failure detection
- **Performance**: Comparison against baseline metrics
- **Duration**: Configurable observation period

### Canary Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `--percent` | 10 | Percentage of traffic to canary |
| `--duration` | 300 | Monitoring duration (seconds) |
| `--check-interval` | 30 | Health check interval (seconds) |
| `--error-threshold` | 3 | Max errors before rollback |
| `--perf-threshold` | 20 | Max performance degradation (%) |

### Traffic Splitting Implementation

**Note**: The canary script provides the framework for canary deployments. Actual traffic splitting requires infrastructure configuration:

#### Option 1: Nginx Split Clients

```nginx
# /etc/nginx/sites-available/default

split_clients "${remote_addr}${http_user_agent}" $backend {
    10%     canary;
    *       production;
}

upstream production {
    server unix:/var/run/php/php8.1-fpm-prod.sock;
}

upstream canary {
    server unix:/var/run/php/php8.1-fpm-canary.sock;
}

server {
    location ~ \.php$ {
        fastcgi_pass $backend;
        # ... other fastcgi settings
    }
}
```

#### Option 2: Load Balancer Weighted Pools

```
Load Balancer:
  - Pool A (90%): Production Servers
  - Pool B (10%): Canary Servers
```

#### Option 3: Service Mesh (Istio/Linkerd)

For Kubernetes deployments, use service mesh traffic splitting:

```yaml
apiVersion: split.smi-spec.io/v1alpha1
kind: TrafficSplit
metadata:
  name: drupal-canary
spec:
  service: drupal
  backends:
  - service: drupal-stable
    weight: 90
  - service: drupal-canary
    weight: 10
```

---

## Performance Baseline Tracking

Performance baseline tracking captures and stores performance metrics after each deployment to detect performance regressions.

### Capturing a Baseline

After a successful deployment:

```bash
# Capture performance baseline
/root/nwp-perf-baseline.sh capture \
  --domain example.com \
  --site-dir /var/www/prod \
  --set-latest \
  --samples 5
```

This captures:
- **Time to First Byte (TTFB)**: Server response time
- **Total Request Time**: Complete page load time
- **Database Query Time**: Database performance
- **Response Sizes**: Payload sizes
- **Statistical Data**: Min, max, average, standard deviation

### Comparing Performance

Before promoting a deployment:

```bash
# Compare current performance to baseline
/root/nwp-perf-baseline.sh compare \
  --domain example.com \
  --threshold 20
```

Exit codes:
- `0`: Performance within threshold
- `1`: Performance regression detected (>20% slower)

### Viewing Baselines

```bash
# List all stored baselines
/root/nwp-perf-baseline.sh list

# Show specific baseline
/root/nwp-perf-baseline.sh show --baseline 20260105_120000

# Show as JSON
/root/nwp-perf-baseline.sh show \
  --baseline 20260105_120000 \
  --output json
```

### Performance Metrics

Baselines are stored in `/var/log/nwp/baselines/` as JSON:

```json
{
  "name": "20260105_120000",
  "timestamp": "2026-01-05T12:00:00Z",
  "domain": "example.com",
  "samples": 5,
  "metrics": {
    "ttfb": 234,
    "ttfb_min": 201,
    "ttfb_max": 289,
    "total_time": 456,
    "download_size": 52341,
    "db_query_time": 12
  }
}
```

### Integration with Deployments

Integrate performance tracking into deployment workflow:

```bash
#!/bin/bash
# deploy-with-perf.sh

DOMAIN="example.com"

# 1. Deploy to test
/root/nwp-bluegreen-deploy.sh --domain $DOMAIN

# 2. Capture new baseline
/root/nwp-perf-baseline.sh capture \
  --domain $DOMAIN \
  --set-latest

# 3. Compare to previous baseline
if ! /root/nwp-perf-baseline.sh compare \
      --domain $DOMAIN \
      --threshold 20; then
    echo "Performance regression detected!"
    # Optionally rollback
    /root/nwp-rollback.sh
    exit 1
fi

echo "Deployment successful with acceptable performance"
```

---

## Visual Regression Testing

Visual regression testing detects unintended visual changes by comparing screenshots of critical pages against baseline images.

### Setup

Install BackstopJS:

```bash
# Global installation
npm install -g backstopjs

# Or project-local
cd /path/to/site
npm install --save-dev backstopjs
```

### Initialize Configuration

```bash
# Create BackstopJS configuration
scripts/ci/visual-regression.sh init \
  --base-url http://test.example.com \
  --site-dir /path/to/site
```

This creates:
- `backstop.json`: Main configuration
- `backstop-scenarios.json`: Test scenarios
- `.logs/visual/`: Output directory

### Customize Scenarios

Edit `backstop-scenarios.json` to add pages to test:

```json
{
  "scenarios": [
    {
      "label": "Homepage",
      "url": "/",
      "selectors": ["document"],
      "delay": 500
    },
    {
      "label": "User Profile",
      "url": "/user/1",
      "selectors": ["document"],
      "delay": 500,
      "requireSameDimensions": true
    },
    {
      "label": "Article Page",
      "url": "/node/123",
      "selectors": [".main-content"],
      "hideSelectors": [".dynamic-ad", ".timestamp"],
      "delay": 1000
    }
  ]
}
```

### Capture Baseline Images

Before making changes:

```bash
# Capture reference/baseline images
scripts/ci/visual-regression.sh reference \
  --base-url http://test.example.com
```

### Run Visual Tests

After deployment:

```bash
# Run visual regression tests
scripts/ci/visual-regression.sh test \
  --base-url http://test.example.com \
  --fail-on-diff
```

### Review Differences

If differences are detected:

```bash
# Open HTML report
open .logs/visual/backstop_data/html_report/index.html
```

### Approve Changes

If visual changes are intentional:

```bash
# Approve new images as baseline
scripts/ci/visual-regression.sh approve
```

### Viewport Testing

Test multiple screen sizes:

```json
{
  "viewports": [
    {
      "label": "phone",
      "width": 375,
      "height": 667
    },
    {
      "label": "tablet",
      "width": 768,
      "height": 1024
    },
    {
      "label": "desktop",
      "width": 1920,
      "height": 1080
    }
  ]
}
```

### Selective Testing

Test specific elements instead of full pages:

```json
{
  "label": "Navigation Menu",
  "url": "/",
  "selectors": ["nav.main-menu"],
  "hideSelectors": [".user-menu"],
  "misMatchThreshold": 0.1
}
```

---

## Complete Deployment Workflow

Combining all advanced deployment strategies:

### Full Production Deployment

```bash
#!/bin/bash
################################################################################
# production-deploy.sh - Complete Production Deployment Workflow
################################################################################

set -e

DOMAIN="example.com"
SITE_DIR="/var/www"
CANARY_PERCENT=10
CANARY_DURATION=300
PERF_THRESHOLD=20

echo "========================================="
echo "Production Deployment Workflow"
echo "========================================="
echo ""

# Step 1: Capture current performance baseline
echo "Step 1: Capturing current performance baseline..."
/root/nwp-perf-baseline.sh capture \
  --domain $DOMAIN \
  --site-dir $SITE_DIR/prod \
  --baseline pre_deploy_$(date +%Y%m%d_%H%M%S)

# Step 2: Capture visual baseline (if not exists)
if [ ! -d "$SITE_DIR/../.logs/visual/backstop_data/bitmaps_reference" ]; then
    echo "Step 2: Capturing visual baseline..."
    cd $SITE_DIR/..
    scripts/ci/visual-regression.sh reference \
      --base-url https://$DOMAIN
fi

# Step 3: Deploy with canary testing
echo "Step 3: Deploying with canary testing..."
/root/nwp-bluegreen-deploy.sh \
  --domain $DOMAIN \
  --webroot $SITE_DIR \
  --canary \
  --canary-percent $CANARY_PERCENT \
  --canary-duration $CANARY_DURATION \
  --rollback-on-fail

# Step 4: Run visual regression tests
echo "Step 4: Running visual regression tests..."
cd $SITE_DIR/..
if ! scripts/ci/visual-regression.sh test \
      --base-url https://$DOMAIN; then
    echo "Visual regression detected!"
    read -p "Continue anyway? [y/N]: " confirm
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        echo "Deployment aborted"
        /root/nwp-rollback.sh --webroot $SITE_DIR -y
        exit 1
    fi
fi

# Step 5: Check performance regression
echo "Step 5: Checking performance..."
/root/nwp-perf-baseline.sh capture \
  --domain $DOMAIN \
  --site-dir $SITE_DIR/prod \
  --set-latest

if ! /root/nwp-perf-baseline.sh compare \
      --domain $DOMAIN \
      --threshold $PERF_THRESHOLD; then
    echo "Performance regression detected!"
    read -p "Continue anyway? [y/N]: " confirm
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        echo "Deployment aborted"
        /root/nwp-rollback.sh --webroot $SITE_DIR -y
        exit 1
    fi
fi

# Step 6: Final health check
echo "Step 6: Final health check..."
/root/nwp-healthcheck.sh --domain $DOMAIN $SITE_DIR/prod

echo ""
echo "========================================="
echo "Deployment Complete!"
echo "========================================="
echo ""
echo "Deployment Summary:"
echo "  - Blue-Green Swap: ✓"
echo "  - Canary Testing: ✓ ($CANARY_PERCENT% for ${CANARY_DURATION}s)"
echo "  - Visual Tests: ✓"
echo "  - Performance: ✓"
echo "  - Health Checks: ✓"
echo ""
echo "Logs: /var/log/nwp/deployments.log"
echo ""
```

### CI/CD Pipeline Integration

GitLab CI example:

```yaml
# .gitlab-ci.yml

stages:
  - test
  - deploy-staging
  - visual-test
  - deploy-canary
  - deploy-production

# Run tests
test:
  stage: test
  script:
    - scripts/ci/test.sh --coverage-threshold 80

# Deploy to staging
deploy_staging:
  stage: deploy-staging
  script:
    - ssh staging "/root/nwp-bluegreen-deploy.sh --domain staging.example.com --yes"

# Visual regression tests on staging
visual_regression:
  stage: visual-test
  script:
    - scripts/ci/visual-regression.sh reference --base-url https://staging.example.com
    - scripts/ci/visual-regression.sh test --base-url https://staging.example.com --fail-on-diff

# Canary deployment to production
deploy_canary:
  stage: deploy-canary
  when: manual
  script:
    - ssh prod "/root/nwp-canary.sh deploy --domain example.com --percent 10 --duration 600 --auto-promote --auto-rollback"

# Full production deployment
deploy_production:
  stage: deploy-production
  when: manual
  script:
    - ssh prod "/root/nwp-bluegreen-deploy.sh --domain example.com --yes --rollback-on-fail"
    - ssh prod "/root/nwp-perf-baseline.sh capture --domain example.com --set-latest"
```

---

## Configuration Examples

### Nginx Configuration for Blue-Green

```nginx
# /etc/nginx/sites-available/default

upstream php_prod {
    server unix:/var/run/php/php8.1-fpm.sock;
}

server {
    listen 80;
    server_name example.com;

    # Document root points to current production
    root /var/www/prod/web;

    location / {
        try_files $uri /index.php$is_args$args;
    }

    location ~ \.php$ {
        fastcgi_pass php_prod;
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
    }
}
```

### Health Check Automation

Add to crontab:

```cron
# Run health checks every 5 minutes
*/5 * * * * /root/nwp-healthcheck.sh --domain example.com --quick /var/www/prod || mail -s "Health Check Failed" admin@example.com

# Capture performance baseline daily at 2 AM
0 2 * * * /root/nwp-perf-baseline.sh capture --domain example.com --set-latest

# Compare current performance to baseline every hour
0 * * * * /root/nwp-perf-baseline.sh compare --domain example.com --threshold 30 || mail -s "Performance Degradation" admin@example.com
```

### Rollback Configuration

Auto-rollback settings in deployment script:

```bash
# Auto-rollback if health checks fail
ROLLBACK_ON_FAIL=true

# Error threshold for automatic rollback
ERROR_THRESHOLD=3

# Performance degradation threshold
PERF_THRESHOLD=20
```

---

## Troubleshooting

### Blue-Green Deployment Issues

**Issue**: Swap fails with permission error

```bash
# Fix permissions
sudo chown -R www-data:www-data /var/www/prod
sudo chown -R www-data:www-data /var/www/test
```

**Issue**: Database connection fails after swap

```bash
# Verify settings files are swapped correctly
ls -la /var/www/prod/web/sites/default/settings*.php

# Manually copy production settings
sudo cp /var/www/prod/web/sites/default/settings.prod.php \
        /var/www/prod/web/sites/default/settings.php
```

**Issue**: Cache clear fails

```bash
# Clear cache manually
cd /var/www/prod
sudo -u www-data vendor/bin/drush cr

# Or use direct database cache clear
sudo -u www-data vendor/bin/drush sqlq "TRUNCATE cache_bootstrap;"
```

### Canary Deployment Issues

**Issue**: Canary routing not working

- Check Nginx configuration for split_clients
- Verify load balancer weighted pools
- Test with curl: `curl -H "User-Agent: test-$$" https://example.com`

**Issue**: Health checks failing during canary

```bash
# Check canary logs
tail -f /var/log/nwp/deployments.log

# Manual health check
/root/nwp-healthcheck.sh --domain example.com /var/www/canary

# Check canary state
/root/nwp-canary.sh status
```

**Issue**: Auto-rollback triggered incorrectly

```bash
# Increase error threshold
/root/nwp-canary.sh deploy \
  --error-threshold 5 \
  --perf-threshold 30

# Disable auto-rollback
/root/nwp-canary.sh deploy \
  --duration 600
  # Then manually promote/rollback
```

### Performance Baseline Issues

**Issue**: No baseline found

```bash
# List available baselines
/root/nwp-perf-baseline.sh list

# Capture new baseline
/root/nwp-perf-baseline.sh capture \
  --domain example.com \
  --set-latest
```

**Issue**: Performance comparison fails

```bash
# Check baseline directory
ls -la /var/log/nwp/baselines/

# Verify latest symlink
ls -la /var/log/nwp/baselines/latest.json

# Use specific baseline
/root/nwp-perf-baseline.sh compare \
  --baseline 20260105_120000 \
  --threshold 20
```

### Visual Regression Issues

**Issue**: BackstopJS not found

```bash
# Install globally
npm install -g backstopjs

# Or use npx
npx backstopjs reference --config=backstop.json
```

**Issue**: Screenshots failing

```bash
# Install Chrome/Chromium dependencies
sudo apt-get install -y chromium-browser

# Or use Puppeteer bundled Chrome
npm install puppeteer
```

**Issue**: Too many false positives

```bash
# Increase mismatch threshold in backstop.json
{
  "scenarios": [{
    "misMatchThreshold": 0.5  // 0.1 to 10.0
  }]
}

# Hide dynamic elements
{
  "scenarios": [{
    "hideSelectors": [".timestamp", ".dynamic-content"]
  }]
}
```

---

## Best Practices

### 1. Always Test Before Deploying

- Run comprehensive tests on test environment
- Capture and review visual baselines
- Validate performance before going live

### 2. Use Canary for High-Risk Changes

- Database schema changes
- Major version upgrades
- New feature releases
- API changes

### 3. Monitor Everything

- Set up continuous health checks
- Track performance trends
- Monitor error rates
- Review deployment logs

### 4. Have a Rollback Plan

- Test rollback procedures regularly
- Keep database backups current
- Document rollback steps
- Set clear rollback criteria

### 5. Automate Where Possible

- Automate health checks
- Auto-capture performance baselines
- Auto-rollback on critical failures
- Integrate with CI/CD pipelines

### 6. Document Everything

- Log all deployments
- Track performance baselines
- Document configuration changes
- Maintain runbooks

---

## Additional Resources

- [NWP Deployment Guide](DEPLOYMENT.md)
- [Server Management](SERVER_MANAGEMENT.md)
- [Health Check Documentation](../linode/server_scripts/nwp-healthcheck.sh)
- [BackstopJS Documentation](https://github.com/garris/BackstopJS)

---

**Last Updated**: 2026-01-05
