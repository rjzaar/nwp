# Human Testing Guide

This document outlines tests that require human verification because they cannot be fully automated. Use this guide alongside the automated test suites to ensure complete coverage.

---

## Table of Contents

1. [CI/CD Pipeline Tests](#1-cicd-pipeline-tests)
2. [Notification System Tests](#2-notification-system-tests)
3. [Server Infrastructure Tests](#3-server-infrastructure-tests)
4. [Security Update Workflow Tests](#4-security-update-workflow-tests)
5. [TUI Interface Tests](#5-tui-interface-tests)
6. [Database Router Tests](#6-database-router-tests)
7. [Pre-commit Hook Tests](#7-pre-commit-hook-tests)
8. [Integration Tests](#8-integration-tests)
9. [Test Checklist Template](#9-test-checklist-template)

---

## 1. CI/CD Pipeline Tests

### 1.1 GitLab CI Pipeline (.gitlab-ci.yml)

**Prerequisite:** GitLab repository with CI/CD enabled

| Test | Steps | Expected Result |
|------|-------|-----------------|
| Pipeline triggers on push | Push a commit to any branch | Pipeline starts automatically |
| Database nightly job | Check scheduled pipeline (after 3 AM) | Database cached in CI artifacts |
| Build job passes | Push code with no errors | Build stage completes green |
| Test job runs | Push code with tests | All test types execute |
| Coverage report | View pipeline artifacts | clover.xml generated in coverage/ |
| Deploy to staging | Merge to `staging` branch | Staging environment updated |
| Deploy to production | Merge to `production` branch | Production environment updated |
| Manual deployment | Click "Deploy" button | Deployment executes correctly |

**Verify in GitLab UI:**
```bash
# Check pipeline status
open https://git.nwpcode.org/<project>/-/pipelines

# Check environments
open https://git.nwpcode.org/<project>/-/environments
```

### 1.2 GitHub Actions Workflow (.github/workflows/build-test-deploy.yml)

**Prerequisite:** GitHub repository with Actions enabled

| Test | Steps | Expected Result |
|------|-------|-----------------|
| Workflow triggers on push | Push a commit | Workflow starts in Actions tab |
| DDEV starts in CI | Check "Build" job logs | DDEV container starts successfully |
| Database caching | Run workflow twice | Second run uses cached DB |
| Test results | Check job summary | All tests listed with status |
| Staging deploy | Merge PR to main | Staging deployment runs |
| Production deploy | Tag release | Production deployment runs |

**Verify in GitHub UI:**
```bash
# Check workflow runs
open https://github.com/<org>/<repo>/actions
```

### 1.3 CI Scripts (scripts/ci/)

| Script | Manual Test | Expected Result |
|--------|-------------|-----------------|
| `fetch-db.sh` | Run locally with site | Creates `.data/db.sql.gz` |
| `build.sh` | Run locally with site | Site builds without errors |
| `test.sh` | Run locally with site | Test results in `.logs/` |
| `check-coverage.sh` | Run with coverage report | Returns pass/fail for threshold |

```bash
# Test fetch-db.sh
./scripts/ci/fetch-db.sh avc --sanitize

# Test build.sh
./scripts/ci/build.sh avc

# Test test.sh
./scripts/ci/test.sh avc --coverage-threshold=60

# Test check-coverage.sh
./scripts/ci/check-coverage.sh 80 .logs/coverage/clover.xml
```

---

## 2. Notification System Tests

### 2.1 Slack Notifications (scripts/notify-slack.sh)

**Prerequisite:** Slack webhook URL configured

| Test | Steps | Expected Result |
|------|-------|-----------------|
| Success notification | Send deploy_success event | Green message in Slack |
| Failure notification | Send deploy_failed event | Red message with details |
| Test notification | Send test_failed event | Message with test output |
| Link formatting | Include URL | Clickable link in message |

```bash
# Set webhook URL
export SLACK_WEBHOOK_URL="https://hooks.slack.com/services/YOUR/WEBHOOK/URL"

# Test success
./scripts/notify-slack.sh "Deployment successful" "success" "https://avc.nwpcode.org"

# Test failure
./scripts/notify-slack.sh "Deployment failed: config import error" "error" ""
```

**Visual verification:** Check Slack channel for properly formatted messages.

### 2.2 Email Notifications (scripts/notify-email.sh)

**Prerequisite:** SMTP configured or local mail working

| Test | Steps | Expected Result |
|------|-------|-----------------|
| Success email | Send success notification | Email received |
| Failure email | Send failure notification | Email with error details |
| Multiple recipients | Configure EMAIL_RECIPIENTS | All recipients receive email |
| Subject formatting | Check email subject | Contains site name and event |

```bash
# Set recipients
export EMAIL_RECIPIENTS="dev@example.com,ops@example.com"

# Test email
./scripts/notify-email.sh "Build completed successfully" "success" "https://avc.nwpcode.org"
```

**Visual verification:** Check email inbox for properly formatted messages.

### 2.3 Webhook Notifications (scripts/notify-webhook.sh)

**Prerequisite:** Webhook endpoint (e.g., requestbin.com for testing)

| Test | Steps | Expected Result |
|------|-------|-----------------|
| JSON payload | Send to webhook | Valid JSON received |
| Event types | Send different events | Correct event field in JSON |
| Metadata | Include extra data | Metadata in payload |

```bash
# Set webhook URL (use requestbin for testing)
export WEBHOOK_URL="https://requestbin.com/r/YOUR_BIN"

# Test webhook
./scripts/notify-webhook.sh "Deployment complete" "success" "https://avc.nwpcode.org"

# Verify JSON payload at webhook endpoint
```

### 2.4 Main Notification Router (scripts/notify.sh)

| Test | Steps | Expected Result |
|------|-------|-----------------|
| Route to Slack | Set SLACK_WEBHOOK_URL | Message sent to Slack |
| Route to email | Set EMAIL_RECIPIENTS | Email sent |
| Route to webhook | Set WEBHOOK_URL | Webhook called |
| Multiple channels | Set all three | All channels receive |
| Event emoji mapping | Use deploy_success | Correct emoji in message |

```bash
# Test with all channels configured
export SLACK_WEBHOOK_URL="..."
export EMAIL_RECIPIENTS="..."
export WEBHOOK_URL="..."

./scripts/notify.sh --event deploy_success --site avc --url "https://avc.nwpcode.org"
```

---

## 3. Server Infrastructure Tests

### 3.1 Bootstrap Script (linode/server_scripts/nwp-bootstrap.sh)

**Prerequisite:** Fresh Ubuntu server or test VM

| Test | Steps | Expected Result |
|------|-------|-----------------|
| Fresh install | Run on new server | All packages installed |
| Directory creation | Check `/var/www/` | prod/, test/, old/ created |
| Backup directory | Check `/var/backups/nwp/` | Directory exists |
| Log directory | Check `/var/log/nwp/` | Directory exists |
| Idempotent | Run twice | No errors on second run |

```bash
# SSH to server
ssh root@your-server

# Run bootstrap
./nwp-bootstrap.sh

# Verify directories
ls -la /var/www/
ls -la /var/backups/nwp/
ls -la /var/log/nwp/
```

### 3.2 Health Check Script (linode/server_scripts/nwp-healthcheck.sh)

| Test | Steps | Expected Result |
|------|-------|-----------------|
| HTTP check | Run with site URL | Site responds with 200 |
| Drupal status | Check drush status | Drupal reports healthy |
| Database check | Check MySQL connection | Connection successful |
| Cache check | Check cache backends | Cache working |
| Cron check | Verify cron last run | Cron ran recently |
| SSL check | Check certificate | Valid certificate shown |
| Disk check | Check disk usage | Usage percentage shown |
| JSON output | Run with --json | Valid JSON returned |
| Failing check | Stop database | Reports failure correctly |

```bash
# Run health check
./nwp-healthcheck.sh avc

# Run with JSON output
./nwp-healthcheck.sh avc --json | jq .

# Test failure detection (stop MySQL temporarily)
systemctl stop mysql
./nwp-healthcheck.sh avc  # Should report database failure
systemctl start mysql
```

### 3.3 Audit Script (linode/server_scripts/nwp-audit.sh)

| Test | Steps | Expected Result |
|------|-------|-----------------|
| Log deployment | Record a deployment | Entry in deployments.jsonl |
| JSON format | Check log format | Valid JSON per line |
| Text format | Check .log file | Human-readable format |
| Timestamp | Check recorded time | Correct timestamp |
| Metadata | Pass extra metadata | Metadata in log entry |

```bash
# Log a deployment
./nwp-audit.sh deploy avc "v1.2.3" "Deploy completed successfully"

# Check JSON log
tail /var/log/nwp/deployments.jsonl | jq .

# Check text log
tail /var/log/nwp/deployments.log
```

---

## 4. Security Update Workflow Tests

### 4.1 Security Update Script (scripts/security-update.sh)

**Prerequisite:** Site with available Drupal security updates

| Test | Steps | Expected Result |
|------|-------|-----------------|
| Check for updates | Run with --check | Lists available updates |
| Dry run | Run without --apply | Shows what would change |
| Create branch | Run update | security/YYYYMMDD branch created |
| Apply updates | Run with --apply | Composer.lock updated |
| Run tests | Updates applied | Tests pass |
| Commit changes | Tests pass | Commit created |
| Push branch | Commit successful | Branch pushed to remote |
| Summary report | Workflow complete | Summary shows all steps |

```bash
# Check for updates
./scripts/security-update.sh avc --check

# Dry run
./scripts/security-update.sh avc

# Apply updates (creates branch, runs tests, commits)
./scripts/security-update.sh avc --apply

# Verify branch
git branch -a | grep security/
```

---

## 5. TUI Interface Tests

### 5.1 dev2stg.sh TUI Mode

| Test | Steps | Expected Result |
|------|-------|-----------------|
| TUI launches | Run without -y | Interactive menu appears |
| Arrow navigation | Press up/down arrows | Selection moves |
| Database menu | Navigate to DB source | Options shown |
| Test menu | Navigate to tests | Test checkboxes shown |
| Checkbox toggle | Press space on test | Checkbox toggles |
| Confirm selection | Press Enter | Selection confirmed |
| Cancel | Press Escape | Returns to previous menu |
| Plan display | Select options | Summary shown before deploy |
| Modify plan | Choose modify | Can change selections |

```bash
# Launch TUI
./dev2stg.sh avc

# Expected flow:
# 1. See preflight results
# 2. Select database source (auto/production/backup/development)
# 3. Select test preset (quick/essential/full/security/skip)
# 4. Review deployment plan
# 5. Confirm or modify
# 6. Watch deployment progress
```

### 5.2 Terminal Compatibility

| Terminal | Test | Expected Result |
|----------|------|-----------------|
| gnome-terminal | Run TUI | Colors display correctly |
| iTerm2 | Run TUI | Colors and navigation work |
| VS Code terminal | Run TUI | Basic functionality works |
| tmux | Run TUI | Navigation works in panes |
| SSH session | Run remotely | TUI functions properly |

---

## 6. Database Router Tests

### 6.1 Auto Selection Logic

| Scenario | Expected Source |
|----------|-----------------|
| Fresh staging, prod backup exists | Production backup |
| Staging exists with data | Existing staging DB |
| No backups, no staging | Prompt for source |
| --fresh-backup flag | Fresh production backup |
| --dev-db flag | Clone from development |

```bash
# Test auto selection
./dev2stg.sh avc -y --db-source=auto

# Test fresh backup
./dev2stg.sh avc -y --fresh-backup

# Test dev database
./dev2stg.sh avc -y --dev-db
```

### 6.2 Backup Source Selection

| Test | Steps | Expected Result |
|------|-------|-----------------|
| List backups | Select backup:/ | Shows available backups |
| Select specific | Choose backup file | Uses selected backup |
| Invalid backup | Choose non-existent | Error message shown |
| Sanitized backup | Select sanitized | Uses sanitized version |

---

## 7. Pre-commit Hook Tests

### 7.1 Hook Installation

| Test | Steps | Expected Result |
|------|-------|-----------------|
| Install hook | Copy to .git/hooks/ | Hook file exists |
| Executable | Check permissions | Has execute permission |
| Symlink method | Use symlink instead | Hook works via symlink |

```bash
# Install hook
cp .hooks/pre-commit .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit

# Or symlink
ln -sf ../../.hooks/pre-commit .git/hooks/pre-commit
```

### 7.2 Hook Behavior

| Test | Steps | Expected Result |
|------|-------|-----------------|
| Clean code | Commit valid PHP | Commit succeeds |
| PHPCS errors | Commit code with style issues | Commit blocked |
| PHPStan errors | Commit code with type errors | Commit blocked |
| Bypass | Use --no-verify | Commit proceeds |
| Non-PHP files | Commit CSS/JS | No PHP checks run |

```bash
# Test with clean code
git add web/modules/custom/clean_module.php
git commit -m "Add clean module"  # Should succeed

# Test with bad code
echo "<?php echo 'test'" > test_bad.php
git add test_bad.php
git commit -m "Add bad code"  # Should fail

# Bypass if needed
git commit -m "Bypass" --no-verify
```

---

## 8. Integration Tests

### 8.1 End-to-End Deployment Flow

| Step | Test | Verify |
|------|------|--------|
| 1 | Make code change | Feature branch created |
| 2 | Run local tests | Tests pass |
| 3 | Create PR | PR appears in GitLab/GitHub |
| 4 | CI runs | Pipeline passes |
| 5 | Merge to develop | Develop updated |
| 6 | Deploy to staging | `./dev2stg.sh site -y` succeeds |
| 7 | Verify staging | Site works at staging URL |
| 8 | Deploy to production | `./stg2prod.sh site` succeeds |
| 9 | Verify production | Site works at production URL |
| 10 | Receive notifications | Slack/email received |

### 8.2 Security Update Flow

| Step | Test | Verify |
|------|------|--------|
| 1 | Renovate creates PR | PR appears for dependency update |
| 2 | CI runs on PR | Tests pass |
| 3 | Review changes | Changelog reviewed |
| 4 | Merge PR | Changes merged |
| 5 | Deploy to staging | Update tested on staging |
| 6 | Deploy to production | Update live on production |

---

## 9. Test Checklist Template

Use this template when performing human testing:

```
# Human Testing Session
Date: YYYY-MM-DD
Tester: [Name]
NWP Version: [version]

## Environment
- OS: [Ubuntu 22.04 / macOS / etc.]
- Docker: [version]
- DDEV: [version]
- Shell: [bash / zsh]
- Terminal: [gnome-terminal / iTerm2 / etc.]

## Tests Performed

### [Feature Name]
- [ ] Test 1: [description]
  - Result: PASS / FAIL
  - Notes: [any observations]

- [ ] Test 2: [description]
  - Result: PASS / FAIL
  - Notes: [any observations]

## Issues Found
1. [Issue description]
   - Steps to reproduce: [steps]
   - Expected: [expected behavior]
   - Actual: [actual behavior]
   - Severity: Critical / High / Medium / Low

## Sign-off
All critical and high-severity tests: PASS / FAIL
Ready for release: YES / NO
```

---

## Running After Updates

When updating NWP code, run through relevant sections of this guide:

1. **CI/CD changes** → Test pipelines
2. **Notification changes** → Test all channels
3. **Server script changes** → Test on staging server
4. **TUI changes** → Test interactive flows
5. **Hook changes** → Test commit workflow

After testing, update `.verification.yml` with results:

```bash
./verify.sh mark <feature> --verified
```

---

## References

- [Developer Lifecycle Guide](./DEVELOPER_LIFECYCLE_GUIDE.md)
- [NWP Complete Roadmap](./NWP_COMPLETE_ROADMAP.md)
- [Verification Tracking](./.verification.yml)
