#!/bin/bash

################################################################################
# NWP Testing Library
#
# Multi-tier testing system with 8 test types and 5 presets
# Source this file: source "$SCRIPT_DIR/lib/testing.sh"
#
# Requires: lib/ui.sh to be sourced first
################################################################################

################################################################################
# Test Type Definitions
################################################################################

# Available test types and their descriptions
declare -A TEST_TYPES=(
    ["phpunit"]="PHPUnit unit/integration tests"
    ["behat"]="Behat BDD scenario tests"
    ["phpstan"]="PHPStan static analysis"
    ["phpcs"]="PHP CodeSniffer style checks"
    ["eslint"]="JavaScript/TypeScript linting"
    ["stylelint"]="CSS/SCSS linting"
    ["security"]="Security vulnerability scan"
    ["accessibility"]="WCAG accessibility checks"
)

# Test presets - predefined combinations
declare -A TEST_PRESETS=(
    ["quick"]="phpcs,eslint"
    ["essential"]="phpunit,phpstan,phpcs"
    ["functional"]="behat"
    ["full"]="phpunit,behat,phpstan,phpcs,eslint,stylelint,security"
    ["security-only"]="security,phpstan"
)

# Estimated durations for each test type (in seconds)
declare -A TEST_DURATIONS=(
    ["phpunit"]=120
    ["behat"]=600
    ["phpstan"]=60
    ["phpcs"]=30
    ["eslint"]=30
    ["stylelint"]=20
    ["security"]=30
    ["accessibility"]=60
)

################################################################################
# Test Runner Functions
################################################################################

# Run tests based on selection (preset or comma-separated types)
# Usage: run_tests "sitename" "selection" [stop_on_failure]
#   selection: preset name OR comma-separated test types
#   stop_on_failure: "true" to stop on first failure (default: false)
# Returns: number of failed tests (0 = all passed)
run_tests() {
    local sitename="$1"
    local selection="$2"
    local stop_on_failure="${3:-false}"
    local script_dir="${SCRIPT_DIR:-$(dirname "${BASH_SOURCE[0]}")/..}"

    # Resolve selection to test types
    local test_types
    if [ "$selection" = "skip" ] || [ -z "$selection" ]; then
        info "Skipping tests as requested"
        return 0
    elif [ -n "${TEST_PRESETS[$selection]}" ]; then
        test_types="${TEST_PRESETS[$selection]}"
        info "Running '$selection' test preset"
    else
        test_types="$selection"
        info "Running custom test selection"
    fi

    # Calculate estimated duration
    local total_duration=0
    for test_type in $(echo "$test_types" | tr ',' '\n'); do
        total_duration=$((total_duration + ${TEST_DURATIONS[$test_type]:-60}))
    done
    local est_minutes=$((total_duration / 60))
    note "Estimated duration: ~${est_minutes} minutes"
    echo ""

    # Track results
    local total=0
    local passed=0
    local failed=0
    local skipped=0
    local failed_tests=""

    # Run each test type
    for test_type in $(echo "$test_types" | tr ',' '\n'); do
        ((total++))

        # Check if test type exists
        if [ -z "${TEST_TYPES[$test_type]}" ]; then
            warn "Unknown test type: $test_type (skipping)"
            ((skipped++))
            continue
        fi

        task "Running $test_type: ${TEST_TYPES[$test_type]}"

        # Run the specific test
        local result
        case "$test_type" in
            phpunit)
                run_phpunit "$sitename"
                result=$?
                ;;
            behat)
                run_behat "$sitename"
                result=$?
                ;;
            phpstan)
                run_phpstan "$sitename"
                result=$?
                ;;
            phpcs)
                run_phpcs "$sitename"
                result=$?
                ;;
            eslint)
                run_eslint "$sitename"
                result=$?
                ;;
            stylelint)
                run_stylelint "$sitename"
                result=$?
                ;;
            security)
                run_security "$sitename"
                result=$?
                ;;
            accessibility)
                run_accessibility "$sitename"
                result=$?
                ;;
            *)
                warn "No runner for test type: $test_type"
                ((skipped++))
                continue
                ;;
        esac

        if [ $result -eq 0 ]; then
            pass "$test_type passed"
            ((passed++))
        else
            fail "$test_type failed"
            ((failed++))
            failed_tests="$failed_tests $test_type"

            if [ "$stop_on_failure" = "true" ]; then
                warn "Stopping due to test failure (--stop-on-failure)"
                break
            fi
        fi

        echo ""
    done

    # Print summary
    echo ""
    info "Test Summary"
    echo "  Total:   $total"
    echo -e "  ${GREEN}Passed:  $passed${NC}"
    if [ $skipped -gt 0 ]; then
        echo -e "  ${YELLOW}Skipped: $skipped${NC}"
    fi
    if [ $failed -gt 0 ]; then
        echo -e "  ${RED}Failed:  $failed${NC}"
        note "Failed tests:$failed_tests"
    fi

    return $failed
}

################################################################################
# Individual Test Runners
################################################################################

# Run PHPUnit tests
run_phpunit() {
    local sitename="$1"
    local script_dir="${SCRIPT_DIR:-$(dirname "${BASH_SOURCE[0]}")/..}"
    local site_path="$script_dir/$sitename"

    cd "$site_path" || return 1

    # Check for PHPUnit config
    if [ ! -f "phpunit.xml" ] && [ ! -f "phpunit.xml.dist" ]; then
        note "No phpunit.xml found, checking vendor..."
    fi

    # Try to run PHPUnit
    if [ -f "vendor/bin/phpunit" ]; then
        ddev exec vendor/bin/phpunit --colors=always 2>&1
        return $?
    elif ddev exec which phpunit &>/dev/null; then
        ddev exec phpunit --colors=always 2>&1
        return $?
    else
        note "PHPUnit not found, skipping"
        return 0
    fi
}

# Run Behat tests
run_behat() {
    local sitename="$1"
    local script_dir="${SCRIPT_DIR:-$(dirname "${BASH_SOURCE[0]}")/..}"
    local site_path="$script_dir/$sitename"

    cd "$site_path" || return 1

    # Check for Behat config
    if [ ! -f "behat.yml" ] && [ ! -f "behat.yml.dist" ]; then
        note "No behat.yml found"
        return 0
    fi

    # Try to run Behat
    if [ -f "vendor/bin/behat" ]; then
        ddev exec vendor/bin/behat --colors 2>&1
        return $?
    else
        note "Behat not found, skipping"
        return 0
    fi
}

# Run PHPStan static analysis
run_phpstan() {
    local sitename="$1"
    local script_dir="${SCRIPT_DIR:-$(dirname "${BASH_SOURCE[0]}")/..}"
    local site_path="$script_dir/$sitename"

    cd "$site_path" || return 1

    # Try to run PHPStan
    if [ -f "vendor/bin/phpstan" ]; then
        if [ -f "phpstan.neon" ] || [ -f "phpstan.neon.dist" ]; then
            ddev exec vendor/bin/phpstan analyse --no-progress 2>&1
        else
            ddev exec vendor/bin/phpstan analyse --level=5 web/modules/custom 2>&1
        fi
        return $?
    else
        note "PHPStan not found, skipping"
        return 0
    fi
}

# Run PHP CodeSniffer
run_phpcs() {
    local sitename="$1"
    local script_dir="${SCRIPT_DIR:-$(dirname "${BASH_SOURCE[0]}")/..}"
    local site_path="$script_dir/$sitename"

    cd "$site_path" || return 1

    # Get webroot
    local webroot=$(grep "^docroot:" ".ddev/config.yaml" 2>/dev/null | awk '{print $2}')
    webroot="${webroot:-web}"

    # Try to run PHPCS
    if [ -f "vendor/bin/phpcs" ]; then
        if [ -f "phpcs.xml" ] || [ -f "phpcs.xml.dist" ]; then
            ddev exec vendor/bin/phpcs 2>&1
        else
            ddev exec vendor/bin/phpcs --standard=Drupal,DrupalPractice "$webroot/modules/custom" 2>&1
        fi
        return $?
    else
        note "PHP CodeSniffer not found, skipping"
        return 0
    fi
}

# Run ESLint
run_eslint() {
    local sitename="$1"
    local script_dir="${SCRIPT_DIR:-$(dirname "${BASH_SOURCE[0]}")/..}"
    local site_path="$script_dir/$sitename"

    cd "$site_path" || return 1

    # Check for ESLint config
    local has_eslint=false
    for config in .eslintrc .eslintrc.json .eslintrc.js .eslintrc.yml eslint.config.js; do
        if [ -f "$config" ]; then
            has_eslint=true
            break
        fi
    done

    if [ "$has_eslint" = "false" ]; then
        note "No ESLint config found, skipping"
        return 0
    fi

    # Try to run ESLint via npm
    if [ -f "package.json" ]; then
        if grep -q '"lint:js"' package.json 2>/dev/null; then
            ddev exec npm run lint:js 2>&1
            return $?
        elif grep -q '"lint"' package.json 2>/dev/null; then
            ddev exec npm run lint 2>&1
            return $?
        fi
    fi

    # Try direct eslint
    if ddev exec which eslint &>/dev/null; then
        ddev exec eslint . 2>&1
        return $?
    fi

    note "ESLint not available, skipping"
    return 0
}

# Run Stylelint
run_stylelint() {
    local sitename="$1"
    local script_dir="${SCRIPT_DIR:-$(dirname "${BASH_SOURCE[0]}")/..}"
    local site_path="$script_dir/$sitename"

    cd "$site_path" || return 1

    # Check for Stylelint config
    local has_stylelint=false
    for config in .stylelintrc .stylelintrc.json .stylelintrc.js stylelint.config.js; do
        if [ -f "$config" ]; then
            has_stylelint=true
            break
        fi
    done

    if [ "$has_stylelint" = "false" ]; then
        note "No Stylelint config found, skipping"
        return 0
    fi

    # Try to run Stylelint via npm
    if [ -f "package.json" ]; then
        if grep -q '"lint:css"' package.json 2>/dev/null; then
            ddev exec npm run lint:css 2>&1
            return $?
        elif grep -q '"lint:styles"' package.json 2>/dev/null; then
            ddev exec npm run lint:styles 2>&1
            return $?
        fi
    fi

    note "Stylelint not available, skipping"
    return 0
}

# Run security checks
run_security() {
    local sitename="$1"
    local script_dir="${SCRIPT_DIR:-$(dirname "${BASH_SOURCE[0]}")/..}"
    local site_path="$script_dir/$sitename"

    cd "$site_path" || return 1

    # Run Drupal security check
    local output=$(ddev drush pm:security 2>&1)
    local result=$?

    echo "$output"

    # Also check composer audit if available
    if ddev exec composer audit --help &>/dev/null; then
        echo ""
        note "Running Composer security audit..."
        ddev exec composer audit 2>&1
    fi

    return $result
}

# Run accessibility checks
run_accessibility() {
    local sitename="$1"
    local script_dir="${SCRIPT_DIR:-$(dirname "${BASH_SOURCE[0]}")/..}"
    local site_path="$script_dir/$sitename"

    cd "$site_path" || return 1

    # Try to run accessibility tests via npm
    if [ -f "package.json" ]; then
        if grep -q '"test:a11y"' package.json 2>/dev/null; then
            ddev exec npm run test:a11y 2>&1
            return $?
        elif grep -q '"a11y"' package.json 2>/dev/null; then
            ddev exec npm run a11y 2>&1
            return $?
        fi
    fi

    # Try pa11y if available
    if ddev exec which pa11y &>/dev/null; then
        local site_url=$(ddev describe 2>/dev/null | grep -oP 'https://[^ ,]+' | head -1)
        if [ -n "$site_url" ]; then
            ddev exec pa11y "$site_url" 2>&1
            return $?
        fi
    fi

    note "Accessibility testing not configured, skipping"
    return 0
}

################################################################################
# Utility Functions
################################################################################

# List available test types
# Usage: list_test_types
list_test_types() {
    info "Available test types:"
    for type in "${!TEST_TYPES[@]}"; do
        echo "  $type - ${TEST_TYPES[$type]}"
    done | sort
}

# List available test presets
# Usage: list_test_presets
list_test_presets() {
    info "Available test presets:"
    for preset in "${!TEST_PRESETS[@]}"; do
        local types="${TEST_PRESETS[$preset]}"
        local duration=0
        for type in $(echo "$types" | tr ',' '\n'); do
            duration=$((duration + ${TEST_DURATIONS[$type]:-60}))
        done
        local minutes=$((duration / 60))
        echo "  $preset (~${minutes}min) - $types"
    done | sort
}

# Estimate test duration
# Usage: estimate_test_duration "selection"
estimate_test_duration() {
    local selection="$1"
    local test_types

    if [ -n "${TEST_PRESETS[$selection]}" ]; then
        test_types="${TEST_PRESETS[$selection]}"
    else
        test_types="$selection"
    fi

    local total_duration=0
    for type in $(echo "$test_types" | tr ',' '\n'); do
        total_duration=$((total_duration + ${TEST_DURATIONS[$type]:-60}))
    done

    echo $((total_duration / 60))
}

# Check which tests are available for a site
# Usage: check_available_tests "sitename"
check_available_tests() {
    local sitename="$1"
    local script_dir="${SCRIPT_DIR:-$(dirname "${BASH_SOURCE[0]}")/..}"
    local site_path="$script_dir/$sitename"
    local available=""

    cd "$site_path" 2>/dev/null || return 1

    # PHPUnit
    if [ -f "vendor/bin/phpunit" ] || [ -f "phpunit.xml" ] || [ -f "phpunit.xml.dist" ]; then
        available="${available}phpunit,"
    fi

    # Behat
    if [ -f "vendor/bin/behat" ] || [ -f "behat.yml" ] || [ -f "behat.yml.dist" ]; then
        available="${available}behat,"
    fi

    # PHPStan
    if [ -f "vendor/bin/phpstan" ]; then
        available="${available}phpstan,"
    fi

    # PHPCS
    if [ -f "vendor/bin/phpcs" ]; then
        available="${available}phpcs,"
    fi

    # ESLint
    for config in .eslintrc .eslintrc.json .eslintrc.js; do
        if [ -f "$config" ]; then
            available="${available}eslint,"
            break
        fi
    done

    # Stylelint
    for config in .stylelintrc .stylelintrc.json; do
        if [ -f "$config" ]; then
            available="${available}stylelint,"
            break
        fi
    done

    # Security is always available
    available="${available}security,"

    # Accessibility
    if [ -f "package.json" ] && grep -qE '"(test:a11y|a11y)"' package.json 2>/dev/null; then
        available="${available}accessibility,"
    fi

    echo "${available%,}"
}

# Validate test selection
# Usage: validate_test_selection "selection"
# Returns: 0 if valid, 1 if invalid
validate_test_selection() {
    local selection="$1"

    # Empty or skip is valid
    if [ -z "$selection" ] || [ "$selection" = "skip" ]; then
        return 0
    fi

    # Preset is valid
    if [ -n "${TEST_PRESETS[$selection]}" ]; then
        return 0
    fi

    # Check individual types
    for type in $(echo "$selection" | tr ',' '\n'); do
        if [ -z "${TEST_TYPES[$type]}" ]; then
            fail "Unknown test type: $type"
            return 1
        fi
    done

    return 0
}
