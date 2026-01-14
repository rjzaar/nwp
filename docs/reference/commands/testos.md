# testos

**Status:** ACTIVE
**Last Updated:** 2026-01-14

Comprehensive testing suite specifically designed for OpenSocial Drupal distributions, including Behat behavioral tests, PHPUnit tests, PHPStan analysis, and code quality checks.

## Synopsis

```bash
./scripts/commands/testos.sh [OPTIONS] <sitename>
```

## Description

The `testos` (Test OpenSocial) command provides specialized testing infrastructure for OpenSocial-based Drupal sites. It automatically configures and runs the complete OpenSocial test suite, including behavioral tests with Selenium, unit/kernel tests, static analysis, and code quality checks.

This script handles the complexity of OpenSocial testing by automatically:
- Installing required testing dependencies
- Configuring Selenium Chrome for browser automation
- Setting up Behat with proper OpenSocial context and feature paths
- Running PHPUnit tests against the social profile
- Executing static analysis and code quality tools

Unlike the generic `test.sh` command, `testos.sh` is optimized for the OpenSocial profile structure and test organization.

## Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `sitename` | Yes | Name of the OpenSocial site to test (e.g., nwp, avc) |

## Options

### Test Type Options

| Option | Description |
|--------|-------------|
| `-b, --behat` | Run Behat behavioral tests |
| `-u, --phpunit` | Run all PHPUnit tests (unit + kernel) |
| `-U, --unit` | Run PHPUnit unit tests only |
| `-k, --kernel` | Run PHPUnit kernel tests only |
| `-s, --phpstan` | Run PHPStan static analysis |
| `-c, --codesniff` | Run PHP CodeSniffer (code standards) |
| `-a, --all` | Run all tests (behat + phpunit + phpstan) |

### Behat-Specific Options

| Option | Description |
|--------|-------------|
| `-f, --feature=NAME` | Run specific feature/capability (e.g., groups, events) |
| `-t, --tag=TAG` | Run tests with specific tag (e.g., @api, @smoke) |
| `--list-features` | List all available Behat features |
| `--headless` | Run Behat in headless mode (default) |
| `--headed` | Run Behat with visible browser |

### PHPUnit-Specific Options

| Option | Description |
|--------|-------------|
| `--group=NAME` | Run specific PHPUnit test group |
| `--coverage` | Generate code coverage report |
| `--testdox` | Output results in testdox format |

### General Options

| Option | Description |
|--------|-------------|
| `-h, --help` | Show help message |
| `-d, --debug` | Enable debug output |
| `-y, --yes` | Skip confirmation prompts |
| `-v, --verbose` | Verbose test output |
| `--stop-on-failure` | Stop on first test failure |

## Examples

### Run All Behat Tests

Execute complete behavioral test suite:
```bash
./scripts/commands/testos.sh -b nwp
```

### Run Specific Feature

Test only the groups feature:
```bash
./scripts/commands/testos.sh -b -f groups nwp
```

### Run Tests with Tag

Execute all API tests:
```bash
./scripts/commands/testos.sh -b -t @api nwp
```

### PHPUnit Unit Tests

Fast unit tests without database:
```bash
./scripts/commands/testos.sh -U nwp
```

### PHPUnit Kernel Tests

Integration tests with database:
```bash
./scripts/commands/testos.sh -k nwp
```

### Static Analysis

Run PHPStan on OpenSocial code:
```bash
./scripts/commands/testos.sh -s nwp
```

### Code Standards Check

Check coding standards compliance:
```bash
./scripts/commands/testos.sh -c nwp
```

### Complete Test Suite

Run all tests (behavioral, unit, static analysis):
```bash
./scripts/commands/testos.sh -a nwp
```

### List Available Features

See all testable OpenSocial features:
```bash
./scripts/commands/testos.sh --list-features nwp
```

## OpenSocial Features

The script supports testing these OpenSocial capabilities:

| Feature | Description |
|---------|-------------|
| `account` | Account management tests |
| `activity-stream` | Activity stream functionality |
| `administration` | Admin interface tests |
| `book` | Book functionality |
| `comment` | Comment system tests |
| `event` | Event creation and management |
| `groups` | Group functionality |
| `login` | Login/authentication |

And many more. Use `--list-features` to see the complete list.

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | All tests passed |
| 1 | One or more tests failed |

## Prerequisites

### Required

- DDEV installed and running
- Site must be OpenSocial-based (social profile installed)
- Site must exist in `sites/<sitename>` or current directory
- Internet connection (for dependency installation)

### Installed Automatically

The script auto-installs these if missing:
- Behat and required extensions
- PHPUnit
- PHPStan
- PHP CodeSniffer
- Selenium Chrome DDEV addon

## Troubleshooting

### "This may not be an OpenSocial site"

**Symptom:** Warning that OpenSocial profile not found

**Solution:** This script is designed for OpenSocial distributions. For other Drupal sites, use `test.sh` instead.

### "Testing dependencies not found"

**Symptom:** Script offers to install dependencies

**Solution:** Answer 'y' to install automatically, or install manually:
```bash
cd sites/nwp
ddev composer require --dev drupal/drupal-extension behat/behat phpunit/phpunit
```

### "Selenium Chrome not found"

**Symptom:** Script offers to install Selenium addon

**Solution:** Answer 'y' to install automatically, or:
```bash
cd sites/nwp
ddev get ddev/ddev-selenium-standalone-chrome
ddev restart
```

## See Also

- [test.md](test.md) - Generic Drupal site testing
- [test-nwp.md](test-nwp.md) - NWP system testing
- [run-tests.md](run-tests.md) - BATS test runner
- [OpenSocial Documentation](https://www.drupal.org/project/social) - OpenSocial project
- [Behat Documentation](https://behat.org/) - Behat testing framework
