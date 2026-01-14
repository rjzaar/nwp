# run-tests

**Status:** ACTIVE
**Last Updated:** 2026-01-14

Unified test runner for BATS unit tests, integration tests, and end-to-end tests with support for CI/CD pipelines.

## Synopsis

```bash
./scripts/commands/run-tests.sh [OPTIONS]
```

## Description

The `run-tests` command is a comprehensive test orchestrator that runs multiple levels of tests using the BATS (Bash Automated Testing System) framework. It provides a unified interface for executing unit tests, integration tests, and end-to-end tests with support for various output formats and execution modes.

This command is designed for both local development (with human-readable output) and CI/CD pipelines (with TAP/JUnit output). It coordinates BATS test execution across different test suites and provides consolidated reporting.

## Arguments

None. Test selection is controlled via options.

## Options

### Test Selection

| Option | Description | Speed |
|--------|-------------|-------|
| `-u, --unit` | Run unit tests only (BATS) | Fast (~1-2 min) |
| `-i, --integration` | Run integration tests only (BATS) | Medium (~5-10 min) |
| `-e, --e2e` | Run E2E tests only (requires Linode) | Slow (~30-60 min) |
| `-a, --all` | Run all tests (default: unit + integration) | Medium (~10-15 min) |

### Execution Options

| Option | Description |
|--------|-------------|
| `-v, --verbose` | Show verbose output |
| `--ci` | CI mode: stricter validation, TAP output |
| `--bail` | Stop on first failure |
| `-d, --debug` | Enable debug output (set -x) |
| `-h, --help` | Show help message |

## Examples

### Run All Tests

Default behavior runs unit and integration tests:
```bash
./scripts/commands/run-tests.sh
```

### Unit Tests Only

Fast feedback loop for library development:
```bash
./scripts/commands/run-tests.sh -u
```

### Integration Tests Only

Test full workflows with DDEV:
```bash
./scripts/commands/run-tests.sh -i
```

### CI/CD Mode

TAP output for CI systems:
```bash
./scripts/commands/run-tests.sh --ci
```

### Verbose Output

Detailed test execution information:
```bash
./scripts/commands/run-tests.sh -v
```

### Stop on First Failure

Fast failure for debugging:
```bash
./scripts/commands/run-tests.sh --bail -u
```

## Test Suites

### Unit Tests (-u)

Location: `tests/unit/*.bats`

**What they test:**
- Library function behavior (lib/*.sh)
- Pure logic without external dependencies
- Input validation
- Error handling
- Return values and exit codes

**Requirements:**
- BATS installed
- No DDEV required
- No network required

**Speed:** ~1-2 minutes

### Integration Tests (-i)

Location: `tests/integration/*.bats`

**What they test:**
- Full command workflows
- DDEV interactions
- File system operations
- Multi-step processes
- Cross-script integration

**Requirements:**
- BATS installed
- DDEV running
- Test sites available
- Network access

**Speed:** ~5-10 minutes

### E2E Tests (-e)

Location: `tests/e2e/*.sh` (future implementation)

**What they test:**
- Production deployment workflows
- Linode server provisioning
- Live server operations
- Full system integration

**Requirements:**
- Linode API access
- SSH keys configured
- .secrets.yml configured
- Network access

**Speed:** ~30-60 minutes

**Status:** Planned for future implementation

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | All test suites passed |
| 1 | One or more test suites failed |

## Prerequisites

### Required Tools

- **BATS** - Bash Automated Testing System
  ```bash
  # Ubuntu/Debian
  apt-get install bats

  # macOS
  brew install bats-core
  ```

### For Integration Tests

- DDEV installed and running
- Test sites created in `sites/` directory
- Network connectivity

### For E2E Tests

- Linode API token in `.secrets.yml`
- SSH keys configured (`~/.ssh/nwp`)
- Linode SSH key uploaded to cloud manager

## Troubleshooting

### "BATS is not installed"

**Symptom:** Error that bats command not found

**Solution:**
```bash
# Ubuntu/Debian
sudo apt-get install bats

# macOS
brew install bats-core
```

### "Unit test directory not found"

**Symptom:** Error that tests/unit/ doesn't exist

**Solution:** Ensure you're running from project root:
```bash
cd /home/rob/nwp
./scripts/commands/run-tests.sh
```

### "DDEV not available - some integration tests will be skipped"

**Symptom:** Warning during integration tests

**Solution:**
```bash
# Install DDEV
curl -fsSL https://ddev.com/install.sh | bash

# Start DDEV
ddev start
```

## See Also

- [test.md](test.md) - Test individual Drupal sites
- [test-nwp.md](test-nwp.md) - Comprehensive NWP system tests
- [testos.md](testos.md) - OpenSocial-specific testing
- [BATS Documentation](https://bats-core.readthedocs.io/) - BATS testing framework
- [TAP Protocol](https://testanything.org/) - Test Anything Protocol
