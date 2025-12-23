# OpenSocial Testing Infrastructure

Comprehensive testing documentation for the NWP OpenSocial testing system.

## Table of Contents

- [Overview](#overview)
- [Testing Script (testos.sh)](#testing-script-testossh)
- [Test Types](#test-types)
- [Installation & Setup](#installation--setup)
- [Usage Examples](#usage-examples)
- [Available Test Features](#available-test-features)
- [Troubleshooting](#troubleshooting)
- [Architecture](#architecture)

## Overview

The NWP testing infrastructure provides automated testing for OpenSocial distributions using industry-standard tools:

- **Behat** - Behavioral/functional testing (30 features, 134 scenarios)
- **PHPUnit** - Unit and kernel testing
- **PHPStan** - Static code analysis
- **PHP CodeSniffer** - Code standards checking
- **Selenium Chrome** - Browser automation (headless)

### Key Features

- ✅ **Zero-configuration setup** - Automatically installs all dependencies
- ✅ **Selenium integration** - Full browser automation via DDEV addon
- ✅ **Dynamic configuration** - Auto-detects site URL, docroot, and paths
- ✅ **30 test features** - Comprehensive OpenSocial test coverage
- ✅ **Flexible execution** - Run all tests or specific features/tags
- ✅ **Detailed reporting** - Screenshots, logs, and test results

## Testing Script (testos.sh)

The `testos.sh` script is the main entry point for all OpenSocial testing operations.

### Location

```
/home/rob/nwp/testos.sh
```

### Quick Start

```bash
# List all available test features
./testos.sh --list-features nwp1

# Run all Behat tests
./testos.sh -b nwp1

# Run specific feature
./testos.sh -b -f groups nwp1

# Run PHPUnit unit tests
./testos.sh -U nwp1

# Run all tests (Behat + PHPUnit + PHPStan)
./testos.sh -a nwp1
```

### Command-Line Options

#### Test Type Options

| Option | Description |
|--------|-------------|
| `-b, --behat` | Run Behat behavioral tests |
| `-u, --phpunit` | Run all PHPUnit tests (unit + kernel) |
| `-U, --unit` | Run PHPUnit unit tests only |
| `-k, --kernel` | Run PHPUnit kernel tests only |
| `-s, --phpstan` | Run PHPStan static analysis |
| `-c, --codesniff` | Run PHP CodeSniffer (code standards) |
| `-a, --all` | Run all tests (behat + phpunit + phpstan) |

#### Behat-Specific Options

| Option | Description |
|--------|-------------|
| `-f, --feature=NAME` | Run specific feature/capability (e.g., groups, events) |
| `-t, --tag=TAG` | Run tests with specific tag |
| `--list-features` | List all available Behat features |
| `--headless` | Run Behat in headless mode (default) |
| `--headed` | Run Behat with visible browser |

#### General Options

| Option | Description |
|--------|-------------|
| `-v, --verbose` | Enable verbose output |
| `-y, --yes` | Auto-confirm all prompts |
| `--stop-on-failure` | Stop on first test failure |
| `-h, --help` | Show help message |

## Test Types

### 1. Behat (Behavioral Testing)

Behat tests simulate real user interactions with the site using a headless Chrome browser.

**What it tests:**
- User workflows (login, posting, groups, events)
- Page rendering and navigation
- Form submissions and validation
- JavaScript functionality
- Access control and permissions

**Example:**
```bash
# Run login tests
./testos.sh -b -f login nwp1

# Run tests with specific tag
./testos.sh -b -t @api nwp1

# Run all behavioral tests
./testos.sh -b nwp1
```

### 2. PHPUnit (Unit & Kernel Testing)

PHPUnit provides unit tests (isolated) and kernel tests (with database).

**What it tests:**
- Individual functions and methods
- Service integrations
- Database operations
- API endpoints

**Example:**
```bash
# Run unit tests only
./testos.sh -U nwp1

# Run kernel tests only
./testos.sh -k nwp1

# Run all PHPUnit tests
./testos.sh -u nwp1
```

### 3. PHPStan (Static Analysis)

PHPStan analyzes code without executing it to find bugs and type errors.

**What it tests:**
- Type consistency
- Undefined variables
- Dead code
- Potential bugs

**Example:**
```bash
./testos.sh -s nwp1
```

### 4. PHP CodeSniffer (Code Standards)

Checks code against Drupal coding standards.

**What it tests:**
- Drupal coding standards
- DrupalPractice standards
- Code formatting
- Best practices

**Example:**
```bash
./testos.sh -c nwp1
```

## Installation & Setup

### Automatic Setup

The testing script automatically handles all setup:

```bash
./testos.sh -b nwp1
```

**What happens automatically:**
1. ✅ Validates OpenSocial site
2. ✅ Installs testing dependencies (Behat, PHPUnit, etc.)
3. ✅ Installs Selenium Chrome DDEV addon
4. ✅ Creates custom Behat configuration
5. ✅ Runs tests

### Manual Setup (if needed)

If you need to set up testing manually:

```bash
cd nwp1

# Install testing dependencies
ddev composer require --dev \
  drupal/drupal-extension \
  behat/behat \
  dmore/behat-chrome-extension \
  friends-of-behat/mink-debug-extension \
  phpunit/phpunit \
  phpstan/phpstan \
  drupal/coder

# Install Selenium
ddev get ddev/ddev-selenium-standalone-chrome
ddev restart
```

### Configuration Files

The script creates a custom Behat configuration:

**Location:** `html/profiles/contrib/social/tests/behat/behat.nwp.yml`

**Features:**
- Auto-detected site URL
- Selenium WebDriver configuration
- Correct Drupal root path
- All OpenSocial context classes
- Screenshot support for failed tests

## Usage Examples

### Basic Testing

```bash
# Test a specific capability
./testos.sh -b -f groups nwp1

# Run with verbose output
./testos.sh -b -f groups -v nwp1

# Auto-confirm all prompts
./testos.sh -b -f groups -y nwp1
```

### Advanced Testing

```bash
# Run multiple test types
./testos.sh -b -u nwp1  # Behat + PHPUnit

# Stop on first failure
./testos.sh -b --stop-on-failure nwp1

# Run specific tag
./testos.sh -b -t @smoke nwp1

# Combine options
./testos.sh -b -f groups -v -y nwp1
```

### CI/CD Integration

```bash
# Run all tests non-interactively
./testos.sh -a -y nwp1

# Exit code 0 = success, 1 = failure
if ./testos.sh -b -y nwp1; then
    echo "Tests passed!"
else
    echo "Tests failed!"
    exit 1
fi
```

## Available Test Features

The OpenSocial distribution includes 30 test features with 134 scenarios:

| Feature | Scenarios | Description |
|---------|-----------|-------------|
| **account** | 6 | Account management and settings |
| **activity-stream** | 2 | Activity stream functionality |
| **administration** | 6 | Admin interface and operations |
| **alternative-frontpage** | 1 | Alternative homepage configuration |
| **book** | 2 | Book content type |
| **comment** | 7 | Comment creation and moderation |
| **contentmanagement** | 3 | Content management operations |
| **embed** | 2 | Embedded content |
| **event** | 12 | Event creation and management |
| **event-an-enroll** | 3 | Event enrollment |
| **event-management** | 1 | Event administrative features |
| **follow-taxonomy** | 1 | Following taxonomy terms |
| **follow-users** | 2 | Following users |
| **gdpr** | 3 | GDPR compliance features |
| **groups** | 36 | Group functionality (largest test suite) |
| **install** | 1 | Installation verification |
| **landing-page** | 4 | Landing page functionality |
| **language** | 1 | Multilingual features |
| **like** | 3 | Like functionality |
| **login** | 1 | Login and authentication |
| **mention** | 2 | User mentions |
| **notifications** | 1 | Notification system |
| **page** | 1 | Page content type |
| **post** | 8 | Post creation and management |
| **private-message** | 1 | Private messaging |
| **profile** | 12 | User profile management |
| **search** | 5 | Search functionality |
| **security** | 1 | Security features |
| **sharing** | 1 | Content sharing |
| **topic** | 6 | Topic/discussion functionality |

### View All Features

```bash
./testos.sh --list-features nwp1
```

## Troubleshooting

### Common Issues

#### 1. Selenium Not Running

**Error:** `Could not fetch version information from http://chrome:4444/wd/hub/status`

**Solution:**
```bash
cd nwp1
ddev restart
ddev exec curl -s http://chrome:4444/wd/hub/status
```

#### 2. Tests Not Found

**Error:** `Features directory not found`

**Check:**
```bash
cd nwp1
ls -la html/profiles/contrib/social/tests/behat/features/capabilities/
```

#### 3. Drush Not Available

**Error:** `drush: command not found`

**Solution:**
```bash
cd nwp1
ddev composer require drush/drush --dev
```

#### 4. Memory Issues

**Error:** `PHP Fatal error: Allowed memory size exhausted`

**Solution:**
```bash
cd nwp1
echo "memory_limit = 512M" > .ddev/php/memory_override.ini
ddev restart
```

### Debug Mode

Enable debug output to see what commands are being executed:

```bash
DEBUG=true ./testos.sh -b -f login nwp1
```

### Log Files

Test results and screenshots are saved to:

```
html/profiles/contrib/social/tests/reports/behat/
```

## Architecture

### Components

```
testos.sh
├── Validation Functions
│   ├── validate_site()          - Verify site exists and is OpenSocial
│   └── get_docroot()             - Detect webroot (html/web)
│
├── Setup Functions
│   ├── install_test_dependencies()  - Install Behat, PHPUnit, etc.
│   ├── install_selenium()           - Install Selenium Chrome addon
│   └── configure_behat()            - Create custom behat.nwp.yml
│
├── Test Execution Functions
│   ├── run_behat_tests()        - Execute Behat scenarios
│   ├── run_phpunit_tests()      - Execute PHPUnit tests
│   ├── run_phpstan()            - Execute static analysis
│   └── run_codesniff()          - Execute code standards check
│
├── Utility Functions
│   ├── list_features()          - Display available test features
│   ├── print_header()           - Formatted section headers
│   ├── print_status()           - Status messages (OK/WARN/FAIL)
│   └── show_elapsed_time()      - Display test duration
│
└── Main Function
    └── run_tests()              - Orchestrate all test operations
```

### Data Flow

```
User Command
    ↓
Parse Options
    ↓
Validate Site → [FAIL] → Exit
    ↓ [OK]
Install Dependencies → Check existing → Install if missing
    ↓
Install Selenium → Check existing → Install if missing
    ↓
Configure Behat → Check existing → Create if missing
    ↓
Execute Tests → Behat/PHPUnit/PHPStan/CodeSniffer
    ↓
Generate Reports → Screenshots, logs, results
    ↓
Display Summary → Passed/Failed, Elapsed time
```

### Technology Stack

| Component | Technology | Purpose |
|-----------|-----------|---------|
| **Test Framework** | Behat 3.x | Behavioral testing (BDD) |
| **Browser Automation** | Selenium WebDriver | Headless Chrome control |
| **Chrome Driver** | DDEV Selenium addon | Chrome in Docker container |
| **Unit Testing** | PHPUnit 9.x | Unit & kernel tests |
| **Static Analysis** | PHPStan | Code quality checks |
| **Code Standards** | PHP CodeSniffer | Drupal coding standards |
| **Drupal Integration** | Drupal Extension | Drupal-specific Behat contexts |
| **Debug Support** | Mink Debug Extension | Screenshots on failure |

### File Structure

```
nwp/
├── testos.sh                           # Main testing script
├── nwp1/                               # Example OpenSocial site
│   ├── .ddev/
│   │   └── selenium-standalone-chrome/  # Selenium addon
│   ├── html/
│   │   └── profiles/contrib/social/
│   │       └── tests/
│   │           ├── behat/
│   │           │   ├── behat.yml           # Original config
│   │           │   ├── behat.nwp.yml       # Custom config (generated)
│   │           │   ├── features/
│   │           │   │   └── capabilities/    # 30 test features
│   │           │   └── fixture/             # Test fixtures
│   │           ├── phpunit/                 # PHPUnit tests
│   │           ├── phpstan/                 # PHPStan tests
│   │           └── reports/                 # Test results
│   │               └── behat/
│   │                   ├── screenshots/     # Failure screenshots
│   │                   └── logs/            # Test logs
│   └── vendor/
│       └── bin/
│           ├── behat                    # Behat executable
│           ├── phpunit                  # PHPUnit executable
│           └── phpstan                  # PHPStan executable
└── docs/
    └── TESTING.md                      # This file
```

## Best Practices

### 1. Regular Testing

Run tests frequently during development:

```bash
# After making changes
./testos.sh -b -f [affected-feature] nwp1
```

### 2. Feature-Specific Testing

Test specific features rather than running all tests:

```bash
# If working on groups
./testos.sh -b -f groups nwp1

# If working on events
./testos.sh -b -f event nwp1
```

### 3. Pre-Commit Testing

Before committing code, run relevant tests:

```bash
# Run unit tests for quick feedback
./testos.sh -U nwp1

# Run static analysis
./testos.sh -s nwp1

# Run code standards
./testos.sh -c nwp1
```

### 4. CI/CD Integration

Integrate testing into your CI/CD pipeline:

```bash
#!/bin/bash
# .gitlab-ci.yml or similar

# Run all tests non-interactively
./testos.sh -a -y nwp1 || exit 1
```

### 5. Debug Failed Tests

When tests fail, use verbose mode and check screenshots:

```bash
# Verbose output
./testos.sh -b -f login -v nwp1

# Check screenshots
ls -la nwp1/html/profiles/contrib/social/tests/reports/behat/screenshots/
```

## Contributing

When adding new test scenarios:

1. Add test to appropriate feature file in `features/capabilities/`
2. Create context methods in appropriate Context class
3. Run and verify: `./testos.sh -b -f [feature] nwp1`
4. Document any new dependencies or setup requirements

## Support

For issues with the testing infrastructure:

1. Check this documentation
2. Run with verbose mode: `-v`
3. Check DDEV status: `ddev describe`
4. Check Selenium status: `ddev exec curl http://chrome:4444/wd/hub/status`
5. Review test logs in `tests/reports/behat/`

## Related Documentation

- [README.md](../README.md) - Main NWP documentation
- [SCRIPTS_IMPLEMENTATION.md](SCRIPTS_IMPLEMENTATION.md) - Management scripts
- [IMPROVEMENTS.md](IMPROVEMENTS.md) - Planned enhancements
- [PRODUCTION_TESTING.md](PRODUCTION_TESTING.md) - Production testing strategies
