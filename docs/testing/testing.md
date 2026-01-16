# NWP Testing Guide

This document provides comprehensive testing guidance for the Narrow Way Project, covering local testing, CI integration, and production validation.

## Table of Contents

- [Overview](#overview)
- [Test Scripts](#test-scripts)
- [OpenSocial Testing (testos.sh)](#opensocial-testing-testossh)
- [NWP Verification System](#nwp-verification-system)
- [Behat Framework](#behat-framework)
- [PHPUnit Testing](#phpunit-testing)
- [Code Quality Tools](#code-quality-tools)
- [Production Testing](#production-testing)
- [Troubleshooting](#troubleshooting)

## Overview

NWP provides multiple testing approaches:

| Tool | Purpose | Speed |
|------|---------|-------|
| **testos.sh** | OpenSocial Behat/PHPUnit testing | 5-30 min |
| **pl verify --run** | NWP verification system | 15-20 min |
| **PHPStan** | Static code analysis | 1-2 min |
| **PHPCS** | Drupal coding standards | 30-60 sec |
| **Behat** | Behavioral/functional testing | Variable |
| **PHPUnit** | Unit and kernel testing | Variable |

## Test Scripts

### Quick Reference

```bash
# OpenSocial testing
./testos.sh -b sitename           # Behat tests
./testos.sh -u sitename           # PHPUnit tests
./testos.sh -a sitename           # All tests

# NWP verification system
pl verify --run                   # Full verification suite
pl verify --run --keep            # Keep test sites

# Code quality
./testos.sh -p sitename           # PHPStan
./testos.sh -c sitename           # CodeSniffer
```

## OpenSocial Testing (testos.sh)

The `testos.sh` script provides automated testing for OpenSocial sites using Behat, PHPUnit, and static analysis.

### Command-Line Options

| Option | Description |
|--------|-------------|
| `-b, --behat` | Run Behat behavioral tests |
| `-u, --phpunit` | Run all PHPUnit tests |
| `-U, --unit` | Run PHPUnit unit tests only |
| `-k, --kernel` | Run PHPUnit kernel tests only |
| `-s, --phpstan` | Run PHPStan static analysis |
| `-c, --codesniff` | Run PHP CodeSniffer |
| `-a, --all` | Run all tests |
| `-f, --feature=NAME` | Run specific feature (e.g., groups, events) |
| `-t, --tag=TAG` | Run tests with specific tag |
| `--list-features` | List all available features |
| `-v, --verbose` | Enable verbose output |
| `-y, --yes` | Auto-confirm all prompts |

### Usage Examples

```bash
# List available test features
./testos.sh --list-features sitename

# Run specific feature tests
./testos.sh -b -f groups sitename

# Run tests with specific tag
./testos.sh -b -t @smoke sitename

# Run all tests non-interactively (CI mode)
./testos.sh -a -y sitename
```

### Available Test Features

OpenSocial includes 30 test features:

| Feature | Scenarios | Description |
|---------|-----------|-------------|
| **groups** | 36 | Group functionality |
| **event** | 12 | Event creation and management |
| **profile** | 12 | User profile management |
| **post** | 8 | Post creation and management |
| **comment** | 7 | Comment creation and moderation |
| **account** | 6 | Account management |
| **topic** | 6 | Topic/discussion functionality |
| **search** | 5 | Search functionality |
| **landing-page** | 4 | Landing page functionality |
| **login** | 1 | Login and authentication |

View all features: `./testos.sh --list-features sitename`

### Automatic Setup

The script automatically:
1. Validates the OpenSocial site
2. Installs testing dependencies (Behat, PHPUnit, etc.)
3. Installs Selenium Chrome DDEV addon
4. Creates custom Behat configuration
5. Runs tests

## NWP Verification System

The NWP verification system validates all NWP core functionality.

### Usage

```bash
# Run all verifications
pl verify --run

# Keep test sites for inspection
pl verify --run --keep

# Verbose output
pl verify --run --verbose
```

### Test Coverage

| Category | Tests | Description |
|----------|-------|-------------|
| Installation | 4 | Site installation, DDEV startup, Drush |
| Backup | 3 | Full backup, directory structure, DB-only |
| Restore | 3 | Full restore, DB-only, configuration |
| Copy | 6 | Full copy, files-only, DDEV config |
| Dev/Prod Mode | 4 | Development modules, production mode |
| Deployment | 4 | dev2stg deployment, staging creation |
| Testing Infrastructure | 3 | PHPStan, CodeSniffer, testos.sh |
| Site Verification | 4 | All sites healthy, DDEV running |
| Script Validation | 12 | All scripts exist and executable |

**Expected Results:**
- Total tests: ~37
- Success rate: 100% (target)
- Duration: 15-20 minutes

## Behat Framework

Behat provides behavior-driven testing with browser automation.

### Test Tags

| Tag | Driver | Speed | Use Case |
|-----|--------|-------|----------|
| `@api` | BrowserKit (headless) | Fast | Content, permissions |
| `@javascript` | Selenium + Chrome | Slow | JS interactions, AJAX |
| `@smoke` | Either | Variable | Critical path validation |
| `@destructive` | Either | Variable | Tests that modify data |

### Example Feature File

```gherkin
@login @smoke
Feature: Login

  @api
  Scenario: Administrator user logs in
    Given I am logged in as a user with the "administrator" role
    When I go to "admin"
    Then the path should be "/admin"
```

### Running Behat Tests

```bash
# Via testos.sh
./testos.sh -b sitename

# Directly
cd sitename
ddev exec vendor/bin/behat --tags=@smoke

# With specific profile
ddev exec vendor/bin/behat --profile=p0
```

### Behat Configuration

The script creates `behat.nwp.yml` with:
- Auto-detected site URL
- Selenium WebDriver configuration
- Correct Drupal root path
- Screenshot support for failed tests

## PHPUnit Testing

PHPUnit provides unit, kernel, and functional tests.

### Test Types

| Type | Database | Speed | Purpose |
|------|----------|-------|---------|
| Unit | No | Fast | Isolated function testing |
| Kernel | Yes | Medium | Service integrations |
| Functional | Yes | Slow | Full request simulation |

### Running PHPUnit

```bash
# Via testos.sh
./testos.sh -U sitename    # Unit tests only
./testos.sh -k sitename    # Kernel tests only
./testos.sh -u sitename    # All PHPUnit tests

# Directly
cd sitename
ddev exec vendor/bin/phpunit --testsuite=unit
```

### PHPUnit Configuration

Example `phpunit.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<phpunit bootstrap="web/core/tests/bootstrap.php" colors="true">
    <testsuites>
        <testsuite name="unit">
            <directory>web/modules/custom/**/tests/src/Unit</directory>
        </testsuite>
        <testsuite name="kernel">
            <directory>web/modules/custom/**/tests/src/Kernel</directory>
        </testsuite>
        <testsuite name="functional">
            <directory>web/modules/custom/**/tests/src/Functional</directory>
        </testsuite>
    </testsuites>
</phpunit>
```

## Code Quality Tools

### PHPStan (Static Analysis)

```bash
./testos.sh -s sitename
# or
ddev exec vendor/bin/phpstan analyse --memory-limit=-1
```

Detects:
- Type inconsistencies
- Undefined variables
- Dead code
- Potential bugs

### PHP CodeSniffer (Coding Standards)

```bash
./testos.sh -c sitename
# or
ddev exec vendor/bin/phpcs --standard=Drupal,DrupalPractice web/modules/custom
```

Checks:
- Drupal coding standards
- DrupalPractice standards
- Code formatting

### Pre-Commit Workflow

```bash
# Quick validation before commit
./testos.sh -p sitename    # PHPStan
./testos.sh -c sitename    # CodeSniffer

# Or combine
./testos.sh -p -c sitename
```

## Production Testing

### Testing Strategies

| Strategy | Safety | Use Case |
|----------|--------|----------|
| Local Mock | Safest | Initial development |
| Remote Test Server | Safer | Final validation |
| Dry-Run Mode | Safe | Pre-flight check |
| Blue-Green | Safe | Zero-downtime deploys |

### Local Mock Production

```bash
# Create mock production environment
./copy.sh sitename-stg sitename-prod

# Test deployment locally
./stg2prod.sh -y sitename-stg

# Test rollback
./stg2prod.sh --rollback sitename-prod
```

### Dry-Run Mode

```bash
# Shows what would happen without executing
./stg2prod.sh --dry-run sitename-stg
```

Output shows all commands that would be executed.

### Pre-Deployment Checklist

**Before Deployment:**
- [ ] Backup production database
- [ ] Backup production files
- [ ] Test backup restoration
- [ ] Schedule maintenance window
- [ ] Notify team
- [ ] Have rollback plan ready

**After Deployment:**
- [ ] Site is accessible
- [ ] Login works
- [ ] Database is correct version
- [ ] Configuration is imported
- [ ] Cache is cleared
- [ ] Cron is working

### Remote Testing

```bash
# Deploy to test production server
./stg2prod.sh sitename-stg --target=test-prod.example.com

# Verify deployment
ssh test-prod "drush status"
ssh test-prod "drush cst"
```

## Troubleshooting

### Common Issues

#### Selenium Not Running

```bash
# Check Selenium status
ddev exec curl -s http://chrome:4444/wd/hub/status

# Restart DDEV
ddev restart
```

#### Tests Not Found

```bash
# Check features directory exists
ls -la sitename/html/profiles/contrib/social/tests/behat/features/capabilities/
```

#### Memory Issues

```bash
# Increase PHP memory limit
echo "memory_limit = 512M" > sitename/.ddev/php/memory_override.ini
ddev restart
```

#### Drush Not Available

```bash
ddev composer require drush/drush --dev
```

### Debug Mode

```bash
# Enable debug output
DEBUG=true ./testos.sh -b -f login sitename

# Verbose output
./testos.sh -b -v sitename
```

### Log Files

Test results and screenshots are saved to:
```
html/profiles/contrib/social/tests/reports/behat/
```

### NWP Verification Failures

```bash
# Check log file
cat .logs/verify-*.log

# Run individual commands
./install.sh test_site
./backup.sh test_site
./restore.sh test_site

# Inspect test sites
cd test_site && ddev describe
```

## Best Practices

### Regular Testing

- **Before major changes** - Establish baseline
- **After implementing features** - Verify no regressions
- **Before releases** - Final validation

### Pre-Commit Testing

```bash
# Quick validation
./testos.sh -p sitename    # PHPStan (fast)
./testos.sh -c sitename    # CodeSniffer (fast)

# Before push
./testos.sh -U sitename    # Unit tests
```

### CI/CD Integration

```bash
# Non-interactive mode for CI
./testos.sh -a -y sitename || exit 1
pl verify --run || exit 1
```

### Debug Failed Tests

1. Run with verbose mode: `-v`
2. Check screenshots in reports directory
3. Check DDEV logs: `ddev logs`
4. Run specific test in isolation

## See Also

- [CI/CD Guide](../deployment/cicd.md) - CI/CD implementation
- [Production Deployment](../deployment/production-deployment.md) - Deployment guide
- [Setup Guide](../guides/setup.md) - Initial setup
