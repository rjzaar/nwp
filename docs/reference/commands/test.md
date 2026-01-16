# test

**Status:** ACTIVE
**Last Updated:** 2026-01-14

Run comprehensive tests for DDEV Drupal sites including code quality checks, static analysis, unit tests, and behavioral tests.

## Synopsis

```bash
pl test [OPTIONS] <sitename>
```

## Description

The `test` command provides a comprehensive testing framework for Drupal sites running in DDEV. It orchestrates multiple testing tools including PHPCS (code standards), PHPStan (static analysis), PHPUnit (unit/kernel/functional tests), and Behat (behavioral tests).

This command is designed to run tests on local DDEV sites and can be configured to run specific test suites or all tests. It supports both development mode (verbose output) and CI mode (machine-readable output with JUnit XML).

## Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `sitename` | Yes | Name of the DDEV site to test (e.g., nwp, avc) |

## Options

### Test Selection Options

| Option | Description | Speed |
|--------|-------------|-------|
| `-l, --lint` | Run PHPCS linting only | Fast (~10s) |
| `-t, --stan` | Run PHPStan analysis only | Fast (~20s) |
| `-u, --unit` | Run PHPUnit unit tests only | Fast (~30s) |
| `-k, --kernel` | Run PHPUnit kernel tests only | Medium (~2m) |
| `-f, --functional` | Run PHPUnit functional tests only | Slow (~5m) |
| `-s, --smoke` | Run Behat smoke tests only | Medium (~30s) |
| `-b, --behat` | Run full Behat test suite | Slow (~10m) |
| `-a, --all` | Run all tests (default) | Very Slow (~20m) |

### Execution Options

| Option | Description |
|--------|-------------|
| `-p, --parallel` | Run Behat tests in parallel (2 processes) |
| `--ci` | CI mode: stricter validation, JUnit XML output |
| `-d, --debug` | Enable debug output |
| `-h, --help` | Show help message |

## Examples

### Basic Usage

Run all tests on a site:
```bash
pl test nwp
```

### Quick Code Quality Check

Run linting and static analysis only:
```bash
pl test -lt nwp
```

### Unit Tests Only

Run just the unit tests (fast feedback):
```bash
pl test -u nwp
```

### Smoke Tests Before Deployment

Quick validation before deploying:
```bash
pl test -s nwp
```

### Full Behat Suite

Run complete behavioral test suite:
```bash
pl test -b nwp
```

### Parallel Behat Testing

Run Behat tests in parallel for faster execution:
```bash
pl test -bp nwp
```

### Combined Test Suites

Run linting, static analysis, and unit tests:
```bash
pl test -ltu nwp
```

### CI/CD Pipeline Integration

Run all tests with JUnit output for CI systems:
```bash
pl test --ci nwp
```

## Test Types

### PHPCS Linting (-l)

Checks code against Drupal coding standards.

**What it tests:**
- Coding style compliance (Drupal, DrupalPractice)
- Custom modules in `web/modules/custom` or `html/modules/custom`
- Custom themes in `web/themes/custom` or `html/themes/custom`

**Speed:** ~10 seconds

**Requires:** `drupal/coder` package

### PHPStan Analysis (-t)

Static analysis to detect potential bugs and type errors.

**What it tests:**
- Type safety issues
- Undefined variables and methods
- Dead code detection
- Custom modules and themes

**Speed:** ~20 seconds

**Level:** 5 (configurable)

**Requires:** `phpstan/phpstan` package

### PHPUnit Unit Tests (-u)

Isolated unit tests without database dependencies.

**What it tests:**
- Pure PHP logic
- Service classes
- Utility functions
- No Drupal API dependencies

**Speed:** ~30 seconds

**Test Suite:** `unit`

**Requires:** `phpunit/phpunit` package

### PHPUnit Kernel Tests (-k)

Integration tests with database and Drupal kernel.

**What it tests:**
- Entity CRUD operations
- Database queries
- Service integration
- Drupal API functionality

**Speed:** ~2 minutes

**Test Suite:** `kernel`

**Requires:** `phpunit/phpunit` package

### PHPUnit Functional Tests (-f)

Full functional tests with web requests.

**What it tests:**
- Page rendering
- Form submissions
- User workflows
- Full Drupal bootstrap

**Speed:** ~5 minutes

**Test Suite:** `functional`

**Requires:** `phpunit/phpunit` package

### Behat Smoke Tests (-s)

Quick behavioral tests tagged with @smoke.

**What it tests:**
- Critical user paths
- Basic functionality
- Login/logout
- Core features

**Speed:** ~30 seconds

**Tags:** `@smoke`

**Requires:** `behat/behat`, Selenium Chrome

### Behat Full Suite (-b)

Complete behavioral test suite.

**What it tests:**
- All user scenarios
- Feature capabilities
- Regression tests
- Browser automation

**Speed:** ~10 minutes (5 minutes with `-p`)

**Requires:** `behat/behat`, Selenium Chrome

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | All tests passed |
| 1 | One or more tests failed |

## Prerequisites

### Required

- DDEV installed and configured
- Site must be a valid DDEV project with `.ddev/config.yaml`
- Site must exist in `sites/<sitename>` or current directory

### Testing Dependencies

The script checks for and reports missing dependencies:

- **PHPCS:** `composer require --dev drupal/coder`
- **PHPStan:** `composer require --dev phpstan/phpstan`
- **PHPUnit:** `composer require --dev phpunit/phpunit`
- **Behat:** `composer require --dev drupal/drupal-extension`

### For Behat Tests

- Selenium Chrome DDEV addon: `ddev get ddev/ddev-selenium-standalone-chrome`
- Chrome browser running in DDEV container
- Behat configuration file

## Troubleshooting

### "PHPCS not found"

**Symptom:** Warning that vendor/bin/phpcs is missing

**Solution:**
```bash
cd sites/nwp
ddev composer require --dev drupal/coder
```

### "PHPStan not found"

**Symptom:** Warning that vendor/bin/phpstan is missing

**Solution:**
```bash
cd sites/nwp
ddev composer require --dev phpstan/phpstan
```

### "PHPUnit not found"

**Symptom:** Warning that vendor/bin/phpunit is missing

**Solution:**
```bash
cd sites/nwp
ddev composer require --dev phpunit/phpunit
```

### "Behat not found"

**Symptom:** Warning that vendor/bin/behat is missing

**Solution:**
```bash
cd sites/nwp
ddev composer require --dev drupal/drupal-extension
```

### Behat Tests Fail to Connect

**Symptom:** Selenium connection errors

**Solution:**
```bash
cd sites/nwp
ddev get ddev/ddev-selenium-standalone-chrome
ddev restart
```

## See Also

- [verify.md](verify.md) - Comprehensive NWP system verification suite
- [run-tests.md](run-tests.md) - Test runner for BATS unit/integration tests
- [testos.md](testos.md) - OpenSocial-specific testing script
- [DDEV Documentation](https://ddev.readthedocs.io/) - DDEV container system
