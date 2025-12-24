# CI/CD Implementation Guide

**Last Updated:** December 2024
**Status:** Planning and Implementation Guide

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Local CI/CD Setup](#local-cicd-setup)
- [GitHub Webhook Integration](#github-webhook-integration)
- [Automated Security Updates](#automated-security-updates)
- [Implementation Phases](#implementation-phases)
- [Safety Levels](#safety-levels)
- [Monitoring and Notifications](#monitoring-and-notifications)

## Overview

This document outlines a comprehensive CI/CD strategy for the NWP project, covering local development validation, automated testing on a test server, and automated security update deployment.

### Key Goals

1. **Fast Local Feedback** - Catch issues before pushing (seconds)
2. **Automated Testing** - Full test suite on every commit (minutes)
3. **Security Automation** - Automated Drupal security updates with validation
4. **Safe Deployment** - Layered testing before production deployment

### CI/CD Pipeline Architecture

```
┌─────────────┐      ┌──────────────┐      ┌─────────────┐      ┌──────────────┐
│   Local     │─git─→│   GitHub     │─hook→│ Test Server │─auto→│  Production  │
│   Dev       │      │              │      │   (Linode)  │      │   (Linode)   │
└─────────────┘      └──────────────┘      └─────────────┘      └──────────────┘
      ↓                      ↓                      ↓                    ↓
  Quick lint         Push commits         Full CI/CD           Verified code
  testos.sh -p       Trigger webhook      + Security          + Security
  (30 seconds)       (instant)            (5-10 min)          (stable)
```

## Local CI/CD Setup

### Option 1: Makefile (Recommended)

Create a `Makefile` in the project root for consistent CI tasks:

```makefile
.PHONY: test lint build ci quick-test help

# Default target
help:
	@echo "Available targets:"
	@echo "  make test       - Run all tests (Behat, PHPUnit, PHPStan, CodeSniffer)"
	@echo "  make lint       - Run linting and static analysis only"
	@echo "  make quick-test - Run fast tests only (PHPStan)"
	@echo "  make build      - Build and clear caches"
	@echo "  make ci         - Run full CI pipeline locally"

# Run all tests
test:
	@echo "Running full test suite..."
	./testos.sh -a

# Lint and static analysis
lint:
	@echo "Running PHPStan..."
	./testos.sh -p
	@echo "Running CodeSniffer..."
	./testos.sh -c

# Quick tests (for pre-commit)
quick-test:
	@echo "Running quick validation..."
	./testos.sh -p

# Build
build:
	@echo "Installing dependencies..."
	ddev composer install
	@echo "Clearing caches..."
	ddev drush cr

# Full CI pipeline
ci: build lint test
	@echo "✓ All CI checks passed!"

# Development helpers
watch:
	@echo "Watching for changes..."
	while true; do \
		inotifywait -e modify -r web/modules/custom/; \
		make quick-test; \
	done
```

**Usage:**
```bash
make ci          # Run full CI pipeline
make quick-test  # Fast validation
make test        # All tests
```

### Option 2: DDEV Hooks

Add hooks to `.ddev/config.yaml` for automatic validation:

```yaml
hooks:
  # Run after DDEV starts
  post-start:
    - exec: composer validate
    - exec: drush status

  # Run before commits (if using ddev-provided git)
  pre-commit:
    - exec: ./testos.sh -p  # PHPStan only for speed

  # Custom hook examples
  post-composer:
    - exec: drush cr
```

### Option 3: Git Hooks

Create `.git/hooks/pre-commit` for validation before commits:

```bash
#!/bin/bash
################################################################################
# Pre-commit hook - Validates code before allowing commit
################################################################################

set -e

echo "🔍 Running pre-commit checks..."

# Run PHPStan (fast static analysis)
echo "→ Running PHPStan..."
./testos.sh -p || {
    echo "✗ PHPStan failed - fix errors before committing"
    exit 1
}

# Optional: Run CodeSniffer
# echo "→ Running CodeSniffer..."
# ./testos.sh -c || {
#     echo "✗ CodeSniffer failed - fix coding standards"
#     exit 1
# }

echo "✓ Pre-commit checks passed!"
```

Make executable:
```bash
chmod +x .git/hooks/pre-commit
```

### Option 4: Pre-push Hook (Recommended)

Create `.git/hooks/pre-push` for more thorough validation:

```bash
#!/bin/bash
################################################################################
# Pre-push hook - Run full tests before pushing to remote
################################################################################

set -e

echo "🚀 Running pre-push validation..."

# Run all tests
./testos.sh -a || {
    echo "✗ Tests failed - fix before pushing"
    exit 1
}

echo "✓ All tests passed - pushing to remote!"
```

Make executable:
```bash
chmod +x .git/hooks/pre-push
```

## GitHub Webhook Integration

### Overview

Set up GitHub to automatically trigger CI pipeline on your test server when code is pushed.

### Server Setup

#### 1. Create Webhook Receiver

Create `/var/www/webhook-receiver/deploy.php` on your Linode test server:

```php
<?php
################################################################################
# GitHub Webhook Receiver
# Receives GitHub push events and triggers CI pipeline
################################################################################

// Security: Verify GitHub webhook signature
$secret = getenv('GITHUB_WEBHOOK_SECRET');
if (!$secret) {
    http_response_code(500);
    die('GITHUB_WEBHOOK_SECRET not configured');
}

$payload = file_get_contents('php://input');
$signature = $_SERVER['HTTP_X_HUB_SIGNATURE_256'] ?? '';

$expected = 'sha256=' . hash_hmac('sha256', $payload, $secret);

if (!hash_equals($expected, $signature)) {
    http_response_code(403);
    error_log('Invalid webhook signature');
    die('Invalid signature');
}

// Parse payload
$data = json_decode($payload, true);
if (!$data) {
    http_response_code(400);
    die('Invalid JSON payload');
}

// Log the event
error_log("GitHub webhook received: {$data['ref']} by {$data['pusher']['name']}");

// Only deploy on push to main branch
if ($data['ref'] === 'refs/heads/main') {
    // Trigger deployment in background
    $output = [];
    $return_var = 0;
    exec('/var/www/scripts/ci-pipeline.sh > /dev/null 2>&1 &', $output, $return_var);

    http_response_code(200);
    echo json_encode([
        'status' => 'triggered',
        'branch' => 'main',
        'commit' => substr($data['after'], 0, 7),
        'message' => $data['head_commit']['message'] ?? 'No message'
    ]);
} else {
    http_response_code(200);
    echo json_encode([
        'status' => 'ignored',
        'ref' => $data['ref'],
        'reason' => 'Only main branch triggers deployment'
    ]);
}
?>
```

#### 2. Create CI Pipeline Script

Create `/var/www/scripts/ci-pipeline.sh`:

```bash
#!/bin/bash
################################################################################
# CI Pipeline Script for Test Server
# Triggered by GitHub webhook on push to main
################################################################################

set -e

# Configuration
SITE_NAME="nwp_test"
SITE_DIR="/var/www/$SITE_NAME"
LOG_DIR="/var/log/ci-pipeline"
LOG_FILE="$LOG_DIR/deploy-$(date +%Y%m%d-%H%M%S).log"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"

# Create log directory
mkdir -p "$LOG_DIR"

# Redirect all output to log file
exec 1> >(tee -a "$LOG_FILE")
exec 2>&1

# Helper functions
print_header() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  $1"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
}

send_notification() {
    local message="$1"
    local emoji="${2:-:robot_face:}"

    if [ -n "$SLACK_WEBHOOK" ]; then
        curl -X POST -H 'Content-type: application/json' \
            --data "{\"text\":\"$emoji $message\"}" \
            "$SLACK_WEBHOOK" 2>/dev/null || true
    fi
}

# Start
print_header "CI Pipeline Started at $(date)"
send_notification "CI Pipeline started for $SITE_NAME"

# Change to site directory
cd "$SITE_DIR"

# Step 1: Pull latest code
print_header "Step 1: Pulling latest code from GitHub"
git pull origin main
COMMIT_HASH=$(git rev-parse --short HEAD)
COMMIT_MSG=$(git log -1 --pretty=%B)
echo "Latest commit: $COMMIT_HASH - $COMMIT_MSG"

# Step 2: Update dependencies
print_header "Step 2: Updating Composer dependencies"
ddev composer install --no-dev --optimize-autoloader

# Step 3: Database updates
print_header "Step 3: Running database updates"
ddev drush updatedb -y || {
    echo "Warning: Database updates had issues"
}

# Step 4: Import configuration
print_header "Step 4: Importing configuration"
ddev drush config-import -y || {
    echo "Warning: No configuration changes to import"
}

# Step 5: Clear caches
print_header "Step 5: Clearing caches"
ddev drush cr

# Step 6: Run test suite
print_header "Step 6: Running test suite"

# Track test results
TEST_FAILED=0

# PHPStan
echo "→ Running PHPStan..."
./testos.sh -p || TEST_FAILED=1

# CodeSniffer
echo "→ Running CodeSniffer..."
./testos.sh -c || TEST_FAILED=1

# PHPUnit
echo "→ Running PHPUnit..."
./testos.sh -u || TEST_FAILED=1

# Behat
echo "→ Running Behat..."
./testos.sh -b || TEST_FAILED=1

# Check results
if [ $TEST_FAILED -eq 0 ]; then
    print_header "✓ All Tests Passed!"
    send_notification "CI Pipeline PASSED for commit $COMMIT_HASH" ":white_check_mark:"

    # Optional: Auto-deploy to production
    # Uncomment if you want automatic production deployment
    # if [ "${AUTO_DEPLOY_PRODUCTION:-false}" = "true" ]; then
    #     print_header "Step 7: Deploying to production"
    #     /var/www/scripts/deploy-to-production.sh
    #     send_notification "Auto-deployed to PRODUCTION" ":rocket:"
    # fi

    EXIT_CODE=0
else
    print_header "✗ Tests Failed!"
    send_notification "CI Pipeline FAILED for commit $COMMIT_HASH - Check logs" ":x:"
    EXIT_CODE=1
fi

print_header "CI Pipeline Completed at $(date)"
echo "Log file: $LOG_FILE"

exit $EXIT_CODE
```

Make executable:
```bash
chmod +x /var/www/scripts/ci-pipeline.sh
```

#### 3. Configure Nginx

Add webhook endpoint to Nginx configuration:

```nginx
server {
    listen 80;
    server_name your-test-server.com;

    # Webhook receiver
    location /webhook {
        root /var/www/webhook-receiver;
        index deploy.php;

        location ~ \.php$ {
            fastcgi_pass unix:/var/run/php/php8.2-fpm.sock;
            fastcgi_index deploy.php;
            include fastcgi_params;
            fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        }
    }

    # Existing site configuration...
}
```

Reload Nginx:
```bash
sudo nginx -t
sudo systemctl reload nginx
```

### GitHub Configuration

1. Go to your repository on GitHub
2. Navigate to **Settings → Webhooks → Add webhook**
3. Configure:
   - **Payload URL:** `https://your-test-server.com/webhook/deploy.php`
   - **Content type:** `application/json`
   - **Secret:** Generate a random string (store in server environment)
   - **Events:** Select "Just the push event"
   - **Active:** ✓ Checked

4. Set the secret on your server:
```bash
# Add to /etc/environment or server config
export GITHUB_WEBHOOK_SECRET="your-random-secret-here"
```

### Testing the Webhook

1. Make a commit and push to main:
```bash
git add .
git commit -m "Test webhook"
git push origin main
```

2. Check GitHub webhook deliveries:
   - Go to Settings → Webhooks → Recent Deliveries
   - Check response status (should be 200)

3. Check server logs:
```bash
tail -f /var/log/ci-pipeline/deploy-*.log
```

## Automated Security Updates

### Overview

Automatically detect, test, and deploy Drupal security updates with comprehensive validation.

### Security Update Script

Create `/var/www/scripts/security-updates.sh`:

```bash
#!/bin/bash
################################################################################
# Automated Drupal Security Update System
#
# This script:
#   1. Checks for security updates via Composer
#   2. Creates backup before applying updates
#   3. Applies updates and runs database migrations
#   4. Runs full test suite
#   5. Auto-deploys if configured and tests pass
#   6. Sends notifications at each step
################################################################################

set -e

# Configuration
SITE_NAME="${SITE_NAME:-nwp_test}"
SITE_DIR="/var/www/$SITE_NAME"
LOG_DIR="/var/log/security-updates"
LOG_FILE="$LOG_DIR/update-$(date +%Y%m%d-%H%M%S).log"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_RECIPIENT="${EMAIL_RECIPIENT:-admin@example.com}"

# Safety configuration
AUTO_MERGE_SECURITY="${AUTO_MERGE_SECURITY:-false}"
AUTO_DEPLOY_PRODUCTION="${AUTO_DEPLOY_PRODUCTION:-false}"
PRODUCTION_SERVER="${PRODUCTION_SERVER:-}"

# Create log directory
mkdir -p "$LOG_DIR"

# Redirect output to log
exec 1> >(tee -a "$LOG_FILE")
exec 2>&1

# Helper functions
print_header() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  $1"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
}

print_info() {
    echo "ℹ $1"
}

print_success() {
    echo "✓ $1"
}

print_warning() {
    echo "⚠ $1"
}

print_error() {
    echo "✗ $1"
}

send_notification() {
    local message="$1"
    local emoji="${2:-:robot_face:}"

    # Slack notification
    if [ -n "$SLACK_WEBHOOK" ]; then
        curl -X POST -H 'Content-type: application/json' \
            --data "{\"text\":\"$emoji $message\"}" \
            "$SLACK_WEBHOOK" 2>/dev/null || true
    fi

    # Email notification
    if command -v mail &> /dev/null; then
        echo "$message" | mail -s "NWP Security Update" "$EMAIL_RECIPIENT" 2>/dev/null || true
    fi
}

cleanup() {
    if [ $? -ne 0 ]; then
        print_error "Script failed - see log: $LOG_FILE"
        send_notification "Security update script FAILED - check logs" ":x:"
    fi
}

trap cleanup EXIT

# Start
print_header "Drupal Security Update Check - $(date)"
send_notification "Security update check started for $SITE_NAME"

cd "$SITE_DIR"

# Step 1: Check for security updates
print_header "Step 1: Checking for security updates"

# Get security updates from Composer
SECURITY_JSON=$(ddev composer outdated --direct --format=json 2>/dev/null || echo '{"installed":[]}')
SECURITY_UPDATES=$(echo "$SECURITY_JSON" | jq -r '.installed[] | select(.warning != null) | .name' 2>/dev/null || echo "")

if [ -z "$SECURITY_UPDATES" ]; then
    print_success "No security updates available"
    send_notification "No security updates found - system is up to date" ":white_check_mark:"
    exit 0
fi

print_warning "Security updates found:"
echo "$SECURITY_UPDATES"

# Get details
print_info "Update details:"
echo "$SECURITY_UPDATES" | while read -r package; do
    echo "$SECURITY_JSON" | jq -r ".installed[] | select(.name == \"$package\") | \"  \(.name): \(.version) → \(.latest)\""
done

send_notification "Security updates detected:\n$SECURITY_UPDATES" ":warning:"

# Step 2: Create backup
print_header "Step 2: Creating backup"
BACKUP_NAME="before-security-update-$(date +%Y%m%d-%H%M%S)"
./backup.sh -y "$SITE_NAME" "$BACKUP_NAME"
print_success "Backup created: $BACKUP_NAME"

# Step 3: Create update branch
BRANCH_NAME="security-update-$(date +%Y%m%d-%H%M%S)"
print_header "Step 3: Creating update branch: $BRANCH_NAME"

# Ensure we're on main
git checkout main
git pull origin main

# Create new branch
git checkout -b "$BRANCH_NAME"
print_success "Created branch: $BRANCH_NAME"

# Step 4: Apply security updates
print_header "Step 4: Applying security updates"

UPDATE_LIST=""
echo "$SECURITY_UPDATES" | while read -r package; do
    print_info "Updating $package..."
    ddev composer update "$package" --with-all-dependencies
    UPDATE_LIST="${UPDATE_LIST}\n- ${package}"
done

print_success "All security updates applied"

# Step 5: Database updates
print_header "Step 5: Running database updates"
ddev drush updatedb -y || {
    print_warning "Database updates completed with warnings"
}

# Step 6: Export configuration
print_header "Step 6: Exporting configuration"
ddev drush config-export -y || {
    print_warning "No configuration changes to export"
}

# Step 7: Clear caches
print_header "Step 7: Clearing caches"
ddev drush cr

# Step 8: Run full test suite
print_header "Step 8: Running test suite"
send_notification "Running tests for security updates..." ":mag:"

TEST_RESULT=0

# Run all tests
./testos.sh -a || TEST_RESULT=$?

if [ $TEST_RESULT -ne 0 ]; then
    print_error "Tests failed - rolling back"
    send_notification "Security update FAILED tests - rolling back\nManual review needed" ":x:"

    # Rollback
    print_header "Rolling back changes"
    git checkout main
    git branch -D "$BRANCH_NAME"
    ./restore.sh -fy "$SITE_NAME"

    exit 1
fi

print_success "All tests passed!"

# Step 9: Commit changes
print_header "Step 9: Committing changes"

git add .
git commit -m "Security updates: $(date +%Y-%m-%d)

Applied security updates:
$(echo -e "$UPDATE_LIST")

All tests passed:
- PHPStan: ✓
- CodeSniffer: ✓
- PHPUnit: ✓
- Behat: ✓

Automated by security-updates.sh
"

print_success "Changes committed"

# Step 10: Auto-merge if configured
print_header "Step 10: Deployment decision"

if [ "$AUTO_MERGE_SECURITY" = "true" ]; then
    print_info "AUTO_MERGE_SECURITY=true - merging to main"

    git checkout main
    git merge "$BRANCH_NAME" --no-ff -m "Merge security updates: $(date +%Y-%m-%d)"
    git push origin main

    send_notification "Security updates AUTO-DEPLOYED to test server ✓" ":white_check_mark:"

    # Step 11: Optional production deployment
    if [ "$AUTO_DEPLOY_PRODUCTION" = "true" ] && [ -n "$PRODUCTION_SERVER" ]; then
        print_header "Step 11: Deploying to production"
        print_warning "AUTO_DEPLOY_PRODUCTION=true - deploying to production!"

        ./linode_deploy.sh --server "$PRODUCTION_SERVER" --target prod --site "$SITE_NAME"

        send_notification "Security updates AUTO-DEPLOYED to PRODUCTION ✓" ":rocket:"
    else
        print_info "Production deployment requires manual approval"
        send_notification "Security updates on test server - ready for production deployment (manual approval required)" ":raising_hand:"
    fi
else
    print_info "AUTO_MERGE_SECURITY=false - creating PR for review"

    # Push branch for manual review
    git push origin "$BRANCH_NAME"

    send_notification "Security update branch created: $BRANCH_NAME\nTests passed ✓ - Please review and merge manually" ":mag:"

    print_info "Branch pushed: $BRANCH_NAME"
    print_info "Review and merge when ready"
fi

print_header "Security update process completed successfully"
print_success "Log file: $LOG_FILE"
```

Make executable:
```bash
chmod +x /var/www/scripts/security-updates.sh
```

### Cron Configuration

Set up automated checks via cron:

```bash
# Edit crontab
crontab -e

# Add one of these schedules:

# Option 1: Daily at 2 AM
0 2 * * * /var/www/scripts/security-updates.sh

# Option 2: Twice daily (morning and afternoon)
0 9,14 * * * /var/www/scripts/security-updates.sh

# Option 3: Business hours only (9 AM and 2 PM, weekdays)
0 9,14 * * 1-5 /var/www/scripts/security-updates.sh

# Option 4: Weekly on Sunday night
0 2 * * 0 /var/www/scripts/security-updates.sh
```

### Environment Configuration

Create `/etc/nwp-ci.conf` or add to `/etc/environment`:

```bash
# Site configuration
SITE_NAME="nwp_test"
PRODUCTION_SERVER="45.33.94.133"

# Notification settings
SLACK_WEBHOOK="https://hooks.slack.com/services/YOUR/WEBHOOK/URL"
EMAIL_RECIPIENT="admin@example.com"

# GitHub webhook secret
GITHUB_WEBHOOK_SECRET="your-random-secret-here"

# Security update behavior (see Safety Levels below)
AUTO_MERGE_SECURITY="false"
AUTO_DEPLOY_PRODUCTION="false"
```

## Safety Levels

### Level 1: Manual Review (Recommended for Production Sites)

**Configuration:**
```bash
AUTO_MERGE_SECURITY="false"
AUTO_DEPLOY_PRODUCTION="false"
```

**Behavior:**
1. ✓ Detects security updates
2. ✓ Creates backup
3. ✓ Creates update branch
4. ✓ Applies updates
5. ✓ Runs all tests
6. → **Stops** - Creates PR for manual review
7. ✓ You review and merge when ready
8. ✓ You deploy to production manually

**Best for:** Production sites, critical applications

### Level 2: Auto-Test (Recommended for Test Servers)

**Configuration:**
```bash
AUTO_MERGE_SECURITY="true"
AUTO_DEPLOY_PRODUCTION="false"
```

**Behavior:**
1. ✓ Detects security updates
2. ✓ Creates backup
3. ✓ Applies updates
4. ✓ Runs all tests
5. ✓ Auto-deploys to test server if tests pass
6. ✓ Notifies you
7. → **Stops** - Requires manual production deployment

**Best for:** Test/staging servers, development environments

### Level 3: Fully Automated (HIGH RISK!)

**Configuration:**
```bash
AUTO_MERGE_SECURITY="true"
AUTO_DEPLOY_PRODUCTION="true"
```

**Behavior:**
1. ✓ Detects security updates
2. ✓ Creates backup
3. ✓ Applies updates
4. ✓ Runs all tests
5. ✓ Auto-deploys to test server
6. ✓ Auto-deploys to production
7. ✓ Notifies you after completion

**Best for:** Low-risk sites, personal projects, sites with excellent test coverage

**⚠ WARNING:** Only use this if:
- Your test suite is comprehensive
- Your site has good test coverage (>70%)
- You have quick rollback capability
- You monitor notifications closely
- You're comfortable with automated production changes

## Monitoring and Notifications

### Slack Integration

1. Create a Slack webhook:
   - Go to https://api.slack.com/apps
   - Create New App → Incoming Webhooks
   - Activate and create webhook URL

2. Configure in environment:
```bash
export SLACK_WEBHOOK="https://hooks.slack.com/services/YOUR/WEBHOOK/URL"
```

### Email Notifications

Install mail utility:
```bash
sudo apt-get install mailutils
```

Configure email:
```bash
export EMAIL_RECIPIENT="admin@example.com"
```

### Log Monitoring

View logs:
```bash
# CI pipeline logs
tail -f /var/log/ci-pipeline/deploy-*.log

# Security update logs
tail -f /var/log/security-updates/update-*.log

# Latest log
ls -lt /var/log/ci-pipeline/ | head -n 2
ls -lt /var/log/security-updates/ | head -n 2
```

### Health Check Endpoint

Create `/var/www/webhook-receiver/health.php`:

```php
<?php
// CI/CD health check endpoint
header('Content-Type: application/json');

$status = [
    'status' => 'ok',
    'timestamp' => date('c'),
    'ci_pipeline' => file_exists('/var/www/scripts/ci-pipeline.sh'),
    'security_updates' => file_exists('/var/www/scripts/security-updates.sh'),
    'last_deploy' => null,
    'last_security_check' => null
];

// Check last deploy
$deploy_logs = glob('/var/log/ci-pipeline/deploy-*.log');
if ($deploy_logs) {
    rsort($deploy_logs);
    $status['last_deploy'] = date('c', filemtime($deploy_logs[0]));
}

// Check last security check
$security_logs = glob('/var/log/security-updates/update-*.log');
if ($security_logs) {
    rsort($security_logs);
    $status['last_security_check'] = date('c', filemtime($security_logs[0]));
}

echo json_encode($status, JSON_PRETTY_PRINT);
```

Access at: `https://your-test-server.com/webhook/health.php`

## Implementation Phases

### Phase 1: Local Development (Week 1)

**Tasks:**
1. ✓ Create `Makefile` for local CI tasks
2. ✓ Set up git pre-push hook
3. ✓ Test local CI workflow
4. ✓ Document usage

**Validation:**
- `make ci` runs successfully
- Pre-push hook catches errors
- Team can run tests locally

### Phase 2: GitHub Webhook (Week 2)

**Tasks:**
1. ✓ Set up webhook receiver on test server
2. ✓ Create CI pipeline script
3. ✓ Configure GitHub webhook
4. ✓ Test webhook delivery
5. ✓ Set up notifications

**Validation:**
- Webhook triggers on push
- CI pipeline runs automatically
- Notifications received
- Logs captured correctly

### Phase 3: Security Automation (Week 3-4)

**Tasks:**
1. ✓ Create security update script
2. ✓ Configure cron schedule
3. ✓ Test with Level 1 (Manual Review)
4. ✓ Set up monitoring
5. ✓ Document procedures

**Validation:**
- Script detects updates
- Tests run correctly
- Notifications work
- Rollback works if tests fail

### Phase 4: Optimization (Ongoing)

**Tasks:**
1. Monitor CI performance
2. Optimize test execution time
3. Add more test coverage
4. Consider Level 2 automation
5. Fine-tune notification thresholds

## Best Practices

### Testing

1. **Comprehensive Test Suite**
   - Unit tests (PHPUnit)
   - Integration tests (Behat)
   - Static analysis (PHPStan)
   - Code standards (CodeSniffer)

2. **Test Coverage**
   - Aim for >70% code coverage
   - Test critical paths thoroughly
   - Include regression tests

3. **Fast Feedback**
   - Local tests < 1 minute
   - Full CI < 10 minutes
   - Optimize slow tests

### Security

1. **Webhook Security**
   - Always verify signatures
   - Use strong secrets
   - Log all requests
   - Rate limit requests

2. **Update Safety**
   - Always backup before updates
   - Test thoroughly
   - Monitor after deployment
   - Have rollback plan

3. **Access Control**
   - Restrict webhook endpoint
   - Secure SSH keys
   - Limit script permissions
   - Audit logs regularly

### Deployment

1. **Staging First**
   - Always test on staging
   - Validate in production-like environment
   - Check performance impact

2. **Rollback Plan**
   - Keep backups
   - Document rollback procedure
   - Test rollback process
   - Monitor after deployment

3. **Communication**
   - Notify team of deployments
   - Document changes
   - Track deployment history

## Troubleshooting

### Webhook Not Triggering

1. Check GitHub webhook deliveries
2. Verify webhook URL is accessible
3. Check server logs: `/var/log/nginx/error.log`
4. Test webhook manually with curl

### Tests Failing

1. Check test logs: `/var/log/ci-pipeline/deploy-*.log`
2. Run tests locally: `make test`
3. Check for environment differences
4. Verify test database state

### Security Updates Not Applying

1. Check cron is running: `sudo systemctl status cron`
2. Check script permissions: `ls -la /var/www/scripts/`
3. Check logs: `/var/log/security-updates/update-*.log`
4. Run script manually for debugging

### Notification Issues

1. Verify Slack webhook URL
2. Check email configuration
3. Test notifications manually:
   ```bash
   curl -X POST -H 'Content-type: application/json' \
     --data '{"text":"Test"}' \
     "$SLACK_WEBHOOK"
   ```

## References

- [NWP Testing Documentation](TESTING.md)
- [NWP Scripts Implementation](SCRIPTS_IMPLEMENTATION.md)
- [NWP Production Testing](PRODUCTION_TESTING.md)
- [DDEV Hooks Documentation](https://ddev.readthedocs.io/en/stable/users/configuration/hooks/)
- [GitHub Webhooks](https://docs.github.com/en/webhooks)
- [Drupal Security](https://www.drupal.org/security)

## Support

For issues or questions:
1. Check troubleshooting section above
2. Review logs for error messages
3. Test components individually
4. Consult team or documentation

---

**Next Steps:** See [Implementation Phases](#implementation-phases) for recommended rollout plan.
