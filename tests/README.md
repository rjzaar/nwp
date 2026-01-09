# NWP Testing Infrastructure

Complete testing infrastructure for NWP with unit, integration, and E2E tests.

## Overview

NWP uses a multi-tier testing approach:

1. **Unit Tests** (BATS) - Fast tests for library functions
2. **Integration Tests** (BATS) - Tests for complete workflows
3. **E2E Tests** (Bash + Linode) - End-to-end tests on real infrastructure

## Quick Start

### Run All Tests
```bash
./scripts/commands/run-tests.sh
```

### Run Specific Test Suites
```bash
./scripts/commands/run-tests.sh -u    # Unit tests only
./scripts/commands/run-tests.sh -i    # Integration tests only
./scripts/commands/run-tests.sh -e    # E2E tests only (requires Linode)
./scripts/commands/run-tests.sh -ui   # Unit + Integration
```

### Run Tests in CI Mode
```bash
./scripts/commands/run-tests.sh --ci
```

## Test Structure

```
tests/
├── README.md                      # This file
├── helpers/
│   └── test-helpers.bash         # Common BATS test helpers
├── unit/
│   ├── test-common.bats          # Tests for lib/common.sh
│   └── test-ui.bats              # Tests for lib/ui.sh
├── integration/
│   ├── 01-install.bats           # Site installation tests
│   ├── 02-backup-restore.bats    # Backup/restore tests
│   ├── 03-copy.bats              # Site copy tests
│   ├── 04-delete.bats            # Site deletion tests
│   ├── 05-deployment.bats        # Deployment workflow tests
│   └── 06-scripts-validation.bats # Script validation tests
└── e2e/
    ├── README.md                 # E2E testing documentation
    ├── test-fresh-install.sh     # Fresh install E2E tests
    └── helpers/                  # E2E-specific helpers
```

## Unit Tests (BATS)

### Purpose
Test individual functions in isolation without external dependencies.

### Location
`tests/unit/*.bats`

### What's Tested
- Input validation functions
- String manipulation utilities
- Password generation
- Environment detection
- Output formatting functions

### Running Unit Tests
```bash
# All unit tests
bats tests/unit/

# Specific test file
bats tests/unit/test-common.bats

# Via test runner
./scripts/commands/run-tests.sh -u
```

### Example Test
```bash
@test "validate_sitename: accepts valid names" {
    run validate_sitename "mysite"
    [ "$status" -eq 0 ]
}

@test "validate_sitename: rejects path traversal" {
    run validate_sitename "../dangerous"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Path traversal not allowed"* ]]
}
```

### Speed
~1-2 minutes for all unit tests

## Integration Tests (BATS)

### Purpose
Test complete workflows and script interactions.

### Location
`tests/integration/*.bats`

### What's Tested
- Script existence and executability
- Bash syntax validation
- Help message availability
- Command-line argument validation
- Full workflows (with DDEV: install, backup, restore, copy)

### Running Integration Tests
```bash
# All integration tests
bats tests/integration/

# Specific test file
bats tests/integration/06-scripts-validation.bats

# Via test runner
./scripts/commands/run-tests.sh -i
```

### DDEV vs Non-DDEV Tests
Some integration tests require DDEV:
- Tests marked with `skip "Requires DDEV..."` are skipped in CI
- Validation tests (syntax, help messages) run everywhere
- Full workflow tests require local DDEV environment

### Speed
- ~30 seconds for validation tests (no DDEV)
- ~5-10 minutes for full tests (with DDEV)

## E2E Tests (Linode)

### Purpose
Test complete deployment scenarios on real infrastructure.

### Location
`tests/e2e/*.sh`

### What's Tested
- Fresh NWP installation on clean server
- Production deployment workflows
- Multi-coder environment setup
- Disaster recovery scenarios

### Running E2E Tests
```bash
# Requires Linode API access
./scripts/commands/run-tests.sh -e

# Or run specific E2E test
./tests/e2e/test-fresh-install.sh
```

### Prerequisites
- Linode API token in `.secrets.yml`
- SSH key at `~/.ssh/nwp`

### Cost
~$0.01-$0.10 per test run (auto-cleanup after completion)

### Speed
~30-60 minutes per test suite

## Test Helpers

### BATS Helpers (`tests/helpers/test-helpers.bash`)

Common helper functions for all BATS tests:

```bash
# Setup/teardown
test_setup()              # Initialize test environment
test_teardown()           # Clean up test resources

# Assertions
assert_file_exists "path"
assert_dir_exists "path"
assert_contains "haystack" "needle"
assert_equals "expected" "actual"
assert_success $?
assert_failure $?

# Mock utilities
mock_command "cmd" "output" [exit_code]
unmock_commands

# Test utilities
create_temp_file "content"
create_temp_dir
create_mock_site "$dir" "$webroot"
```

## CI/CD Integration

### GitLab CI Pipeline

Tests run automatically in GitLab CI:

```yaml
stages:
  - lint      # Bash syntax validation
  - test      # Unit and integration tests
  - e2e       # E2E tests (nightly/manual)
```

### Lint Stage
```bash
# Runs on every push
lint:bash:
  script:
    - find scripts lib -name "*.sh" -exec bash -n {} \;
```

### Test Stage
```bash
# Unit tests - every push
test:unit:
  script:
    - bats tests/unit/

# Integration tests - every push (validation only)
test:integration:
  script:
    - bats tests/integration/06-scripts-validation.bats
```

### E2E Stage
```bash
# E2E tests - nightly/manual only
e2e:fresh-install:
  rules:
    - if: $CI_PIPELINE_SOURCE == "schedule"
      when: manual
  script:
    - ./tests/e2e/test-fresh-install.sh
```

## Writing New Tests

### Unit Test Template
```bash
#!/usr/bin/env bats

load ../helpers/test-helpers

setup() {
    test_setup
    source_lib "your-library.sh"
}

teardown() {
    test_teardown
}

@test "your_function: does what it should" {
    run your_function "arg1" "arg2"
    [ "$status" -eq 0 ]
    [[ "$output" == *"expected"* ]]
}
```

### Integration Test Template
```bash
#!/usr/bin/env bats

load ../helpers/test-helpers

setup() {
    test_setup
    export PROJECT_ROOT="${BATS_TEST_DIRNAME}/../.."
}

teardown() {
    test_teardown
}

@test "script: validates input" {
    cd "${PROJECT_ROOT}"
    run ./scripts/commands/your-script.sh --bad-input
    [ "$status" -ne 0 ]
}
```

## Test Coverage

### Current Coverage

| Category | Coverage | Tests |
|----------|----------|-------|
| lib/common.sh | 60% | 43 tests |
| lib/ui.sh | 80% | 33 tests |
| Scripts validation | 100% | 25 tests |
| Full workflows | 40% | Partial |
| E2E scenarios | 0% | Planned |

### Coverage Goals

- Unit tests: 80% of library functions
- Integration tests: 95% of core workflows
- E2E tests: 80% of deployment scenarios

## Test Naming Conventions

### BATS Tests
- File: `test-<library>.bats` or `NN-<feature>.bats`
- Test: `@test "function: description"`
- Use descriptive names that explain what's being tested

### E2E Tests
- File: `test-<scenario>.sh`
- Use kebab-case for file names
- Include cleanup in every test script

## Troubleshooting

### BATS Not Installed
```bash
apt-get install bats
# or
brew install bats-core
```

### Tests Failing Locally
```bash
# Run with verbose output
./scripts/commands/run-tests.sh -v -u

# Run specific test
bats tests/unit/test-common.bats

# Debug single test
bats --verbose-run tests/unit/test-common.bats --filter "validate_sitename"
```

### DDEV Tests Skipped
Integration tests requiring DDEV are automatically skipped. To run them:
1. Ensure DDEV is installed and running
2. Create a test site first
3. Run full test suite

### E2E Tests Cost Concerns
E2E tests auto-cleanup instances. If concerned about costs:
```bash
# Disable cleanup for inspection
CLEANUP=false ./tests/e2e/test-fresh-install.sh

# Check for orphaned instances
./tests/e2e/helpers/cleanup-helpers.sh --check

# Force cleanup
./tests/e2e/helpers/cleanup-helpers.sh --force
```

## Performance

### Test Suite Timing

| Suite | Duration | When to Run |
|-------|----------|-------------|
| lint:bash | ~10s | Every push |
| test:unit | ~2min | Every push |
| test:integration (validation) | ~30s | Every push |
| test:integration (full) | ~10min | Pre-merge |
| test:e2e | ~45min | Nightly |

### Optimization Tips
- Use `--bail` to stop on first failure
- Run only changed test files during development
- Use CI for full test runs
- E2E tests are opt-in only

## Future Enhancements

### Planned Features
- [ ] TUI testing with Expect
- [ ] Performance benchmarking tests
- [ ] Security vulnerability scanning
- [ ] Accessibility testing
- [ ] Visual regression testing
- [ ] Load testing for multi-site scenarios

### Planned Coverage
- [ ] Complete unit tests for all lib/*.sh files
- [ ] Full integration tests for all commands
- [ ] E2E tests for all deployment scenarios
- [ ] TUI workflow testing
- [ ] Multi-coder collaboration tests

## References

- [COMPREHENSIVE_TESTING_PROPOSAL.md](../docs/COMPREHENSIVE_TESTING_PROPOSAL.md) - Full testing specification
- [TESTING.md](../docs/TESTING.md) - Testing documentation
- [BATS Documentation](https://bats-core.readthedocs.io/)
- [GitLab CI Testing](https://docs.gitlab.com/ee/ci/testing/)

## Contributing

When adding new features to NWP:

1. **Write Unit Tests First**
   - Test individual functions
   - Cover edge cases
   - Include negative tests

2. **Add Integration Tests**
   - Test command-line interface
   - Test error handling
   - Test help messages

3. **Update Test Documentation**
   - Add examples to this README
   - Update test coverage table
   - Document any new helpers

4. **Ensure CI Passes**
   - All lint checks pass
   - All unit tests pass
   - Integration validation tests pass

## License

Same as NWP project.
