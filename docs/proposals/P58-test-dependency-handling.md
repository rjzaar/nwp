# P58: Test Command Dependency Handling

**Status:** IMPLEMENTED
**Created:** 2026-01-18
**Author:** Rob, Claude Opus 4.5
**Priority:** Medium
**Depends On:** P54 (removes grep tests expecting this feature)
**Estimated Effort:** 3-5 days
**Breaking Changes:** No - additive feature

---

## 1. Executive Summary

### 1.1 Problem Statement

The verification tests expect `test.sh` to handle missing dependencies:
```bash
grep -qE 'missing.*depend|not.*installed' scripts/commands/test.sh
```

Currently the script doesn't provide helpful messages when PHPCS, PHPStan, or PHPUnit are missing. Tests fail silently or with cryptic errors.

### 1.2 Proposed Solution

Add dependency checking and helpful error messages to `test.sh`:
1. Dependency check function for each test tool
2. Clear error messages with installation instructions
3. Auto-install option for missing dependencies
4. Combined flags documentation (bonus fix for grep test)

### 1.3 Key Benefits

| Benefit | Description |
|---------|-------------|
| Better DX | Clear guidance when tools missing |
| Self-service | Users can auto-install dependencies |
| Skip gracefully | Tests skip with explanation vs cryptic failures |
| Documentation | Combined flags properly documented |

---

## 2. Proposed Features

### 2.1 Dependency Check Function

```bash
# Check if required testing tools are installed
check_test_dependencies() {
    local missing_deps=()
    local test_type="${1:-all}"

    # Check based on test type
    case "$test_type" in
        lint|-l)
            command -v phpcs >/dev/null 2>&1 || missing_deps+=("phpcs")
            ;;
        stan|-t)
            command -v phpstan >/dev/null 2>&1 || missing_deps+=("phpstan")
            ;;
        unit|-u)
            [[ -f vendor/bin/phpunit ]] || missing_deps+=("phpunit")
            ;;
        all)
            command -v phpcs >/dev/null 2>&1 || missing_deps+=("phpcs")
            command -v phpstan >/dev/null 2>&1 || missing_deps+=("phpstan")
            [[ -f vendor/bin/phpunit ]] || missing_deps+=("phpunit")
            ;;
    esac

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        print_error "Missing dependencies: ${missing_deps[*]}"
        print_info "Install with: composer require --dev ${missing_deps[*]}"
        return 1
    fi

    return 0
}
```

### 2.2 Helpful Error Messages

```bash
# At start of each test function
run_lint_tests() {
    if ! check_test_dependencies "lint"; then
        print_warning "Skipping lint tests - missing dependency: phpcs not installed"
        print_info "To install: composer require --dev squizlabs/php_codesniffer"
        return 1
    fi
    # ... existing lint logic ...
}

run_stan_tests() {
    if ! check_test_dependencies "stan"; then
        print_warning "Skipping static analysis - missing dependency: phpstan not installed"
        print_info "To install: composer require --dev phpstan/phpstan"
        return 1
    fi
    # ... existing stan logic ...
}

run_unit_tests() {
    if ! check_test_dependencies "unit"; then
        print_warning "Skipping unit tests - missing dependency: phpunit not installed"
        print_info "To install: composer require --dev phpunit/phpunit"
        return 1
    fi
    # ... existing unit logic ...
}
```

### 2.3 Auto-Install Option

```bash
install_test_dependencies() {
    local deps=("$@")

    print_info "Installing missing test dependencies..."

    for dep in "${deps[@]}"; do
        case "$dep" in
            phpcs)
                print_info "Installing PHP_CodeSniffer..."
                composer require --dev squizlabs/php_codesniffer
                ;;
            phpstan)
                print_info "Installing PHPStan..."
                composer require --dev phpstan/phpstan phpstan/phpstan-drupal
                ;;
            phpunit)
                print_info "Installing PHPUnit..."
                composer require --dev phpunit/phpunit
                ;;
            *)
                print_warning "Unknown dependency: $dep"
                ;;
        esac
    done

    print_success "Dependencies installed"
}

# In main(), add --install-deps flag handler
case "$1" in
    --install-deps)
        install_test_dependencies phpcs phpstan phpunit
        exit 0
        ;;
    --check-deps)
        check_all_dependencies
        exit $?
        ;;
esac
```

### 2.4 Combined Flags Documentation

Add prominent comment to `test.sh`:

```bash
################################################################################
# Test Flags
#
# Individual flags:
#   -l  Run lint tests (PHPCS)
#   -t  Run static analysis (PHPStan)
#   -u  Run unit tests (PHPUnit)
#   -k  Run kernel tests
#   -f  Run functional tests
#   -b  Run Behat tests
#
# Combined flags: -ltu runs lint+stan+unit tests together
# Example: pl test -ltu mysite
#
# Dependency flags:
#   --check-deps     Check if all dependencies are installed
#   --install-deps   Install missing test dependencies
#   --skip-missing   Skip tests with missing dependencies (don't fail)
#
################################################################################
```

---

## 3. CLI Options

### 3.1 New Flags

| Flag | Description |
|------|-------------|
| `--check-deps` | Check if all dependencies are installed |
| `--install-deps` | Install missing test dependencies |
| `--skip-missing` | Skip tests with missing dependencies (don't fail) |

### 3.2 Example Usage

```bash
# Check what's missing
pl test --check-deps mysite

# Auto-install missing tools
pl test --install-deps mysite

# Run tests, skip if deps missing
pl test -ltu mysite --skip-missing

# Combined flags example
pl test -ltu mysite  # Runs lint + stan + unit
```

### 3.3 Error Message Examples

```
$ pl test -l mysite
ERROR: Missing dependency: phpcs not installed
INFO: To install: composer require --dev squizlabs/php_codesniffer
INFO: Or run: pl test --install-deps

$ pl test -ltu mysite
WARNING: Skipping lint tests - phpcs not installed
Running static analysis...
WARNING: Skipping unit tests - phpunit not installed
INFO: 1 of 3 test suites ran. Install missing dependencies with: pl test --install-deps

$ pl test --check-deps mysite
Checking test dependencies...
  phpcs:    INSTALLED (3.7.2)
  phpstan:  MISSING
  phpunit:  INSTALLED (10.5.1)
  behat:    MISSING

Missing: phpstan, behat
Run 'pl test --install-deps' to install
```

---

## 4. Implementation Details

### 4.1 Dependency Detection

```bash
check_all_dependencies() {
    local all_ok=true

    print_info "Checking test dependencies..."

    # PHPCS
    if command -v phpcs >/dev/null 2>&1; then
        local version=$(phpcs --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
        print_success "  phpcs:    INSTALLED ($version)"
    else
        print_error "  phpcs:    MISSING"
        all_ok=false
    fi

    # PHPStan
    if command -v phpstan >/dev/null 2>&1; then
        local version=$(phpstan --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
        print_success "  phpstan:  INSTALLED ($version)"
    else
        print_error "  phpstan:  MISSING"
        all_ok=false
    fi

    # PHPUnit
    if [[ -f vendor/bin/phpunit ]]; then
        local version=$(vendor/bin/phpunit --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
        print_success "  phpunit:  INSTALLED ($version)"
    else
        print_error "  phpunit:  MISSING"
        all_ok=false
    fi

    # Behat (optional)
    if [[ -f vendor/bin/behat ]]; then
        local version=$(vendor/bin/behat --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
        print_success "  behat:    INSTALLED ($version)"
    else
        print_warning "  behat:    NOT INSTALLED (optional)"
    fi

    echo ""
    if $all_ok; then
        print_success "All required dependencies installed"
        return 0
    else
        print_error "Missing dependencies detected"
        print_info "Run 'pl test --install-deps' to install"
        return 1
    fi
}
```

### 4.2 Skip Mode Implementation

```bash
# Global flag
SKIP_MISSING_DEPS=false

# Parse in main
case "$1" in
    --skip-missing)
        SKIP_MISSING_DEPS=true
        shift
        ;;
esac

# Use in test functions
run_lint_tests() {
    if ! check_test_dependencies "lint"; then
        if $SKIP_MISSING_DEPS; then
            print_warning "Skipping lint tests - dependency missing"
            return 0  # Don't fail, just skip
        else
            return 1  # Fail
        fi
    fi
    # ... run tests ...
}
```

---

## 5. Verification

### 5.1 Machine Tests

```yaml
# Add to .verification.yml test: section
- text: "Dependency checking implemented"
  machine:
    automatable: true
    checks:
      thorough:
        commands:
          - cmd: grep -qE 'missing.*depend|not.*installed' scripts/commands/test.sh
            expect_exit: 0
          - cmd: grep -q 'check_test_dependencies' scripts/commands/test.sh
            expect_exit: 0
          - cmd: grep -qE 'Combined flags.*-ltu' scripts/commands/test.sh
            expect_exit: 0
```

### 5.2 Functional Tests

```bash
# Test --check-deps flag
pl test --check-deps mysite
# Should exit 0 if all present, 1 if missing

# Test --install-deps in isolated environment
# (Would need docker/nix for clean test)

# Test combined flags comment exists
grep -E 'Combined flags' scripts/commands/test.sh
```

---

## 6. Success Criteria

- [ ] `grep -qE 'missing.*depend|not.*installed' test.sh` passes
- [ ] Clear error messages for each missing tool
- [ ] `--check-deps` shows status of all test dependencies
- [ ] `--install-deps` installs missing dependencies
- [ ] `--skip-missing` allows partial test runs
- [ ] Combined flags comment satisfies grep test
- [ ] Documentation updated with new flags

---

## 7. Related Proposals

| Proposal | Relationship |
|----------|--------------|
| P54 | Removes grep test that expects this feature |
| P50 | Verification system test.sh integrates with |
| F09 | Comprehensive testing proposal (broader scope) |
