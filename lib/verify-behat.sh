#!/bin/bash
################################################################################
# NWP Behat Integration Library
#
# Part of P51: AI-Powered Deep Verification (Phase 3)
#
# This library provides Behat functional test integration for AI verification.
# It runs Behat tests against sites, captures failures, handles retries for
# flaky tests, and saves screenshots on failure.
#
# Key Functions:
#   - behat_run_suite() - Run a Behat test suite
#   - behat_run_smoke() - Run quick smoke tests
#   - behat_run_full() - Run complete test suite
#   - behat_capture_failure() - Save failure details
#   - behat_retry() - Retry failed tests with backoff
#
# Source this file: source "$PROJECT_ROOT/lib/verify-behat.sh"
#
# Dependencies:
#   - Behat installed in site (vendor/bin/behat)
#   - Drupal Behat extension
#   - DDEV for site execution
#
# Reference:
#   - P51: AI-Powered Deep Verification
#   - docs/proposals/P51-ai-powered-verification.md
################################################################################

# Determine paths
BEHAT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BEHAT_PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$BEHAT_LIB_DIR/.." && pwd)}"

# Make PROJECT_ROOT available if not set
PROJECT_ROOT="${PROJECT_ROOT:-$BEHAT_PROJECT_ROOT}"

# Configuration
BEHAT_LOG_DIR="${BEHAT_LOG_DIR:-$BEHAT_PROJECT_ROOT/.logs/behat}"
BEHAT_SCREENSHOTS_DIR="${BEHAT_SCREENSHOTS_DIR:-$BEHAT_LOG_DIR/screenshots}"
BEHAT_FINDINGS_FILE="${BEHAT_FINDINGS_FILE:-$BEHAT_LOG_DIR/behat-findings.json}"
BEHAT_MAX_RETRIES="${BEHAT_MAX_RETRIES:-3}"
BEHAT_RETRY_DELAY="${BEHAT_RETRY_DELAY:-5}"
BEHAT_DEFAULT_TIMEOUT="${BEHAT_DEFAULT_TIMEOUT:-300}"

# State tracking
declare -A BEHAT_RESULTS=()
BEHAT_TOTAL_TESTS=0
BEHAT_PASSED_TESTS=0
BEHAT_FAILED_TESTS=0
BEHAT_SKIPPED_TESTS=0
BEHAT_RETRIED_TESTS=0

################################################################################
# SECTION 1: Initialization and Utilities
################################################################################

#######################################
# Initialize Behat logging directories
#######################################
behat_init() {
    mkdir -p "$BEHAT_LOG_DIR"
    mkdir -p "$BEHAT_SCREENSHOTS_DIR"

    # Initialize findings file
    cat > "$BEHAT_FINDINGS_FILE" << 'EOF'
{
  "generated_at": "",
  "suites_run": [],
  "failures": [],
  "screenshots": [],
  "summary": {
    "total": 0,
    "passed": 0,
    "failed": 0,
    "skipped": 0,
    "retried": 0
  }
}
EOF

    # Update timestamp
    local timestamp
    timestamp=$(date -Iseconds)
    if command -v jq &>/dev/null; then
        jq ".generated_at = \"$timestamp\"" "$BEHAT_FINDINGS_FILE" > "${BEHAT_FINDINGS_FILE}.tmp" && \
        mv "${BEHAT_FINDINGS_FILE}.tmp" "$BEHAT_FINDINGS_FILE"
    fi

    # Reset counters
    BEHAT_RESULTS=()
    BEHAT_TOTAL_TESTS=0
    BEHAT_PASSED_TESTS=0
    BEHAT_FAILED_TESTS=0
    BEHAT_SKIPPED_TESTS=0
    BEHAT_RETRIED_TESTS=0
}

#######################################
# Check if Behat is available for a site
# Arguments:
#   $1 - Site name
# Returns: 0 if available, 1 if not
#######################################
behat_check_available() {
    local site="$1"
    local site_path="$PROJECT_ROOT/sites/$site"

    if [[ ! -d "$site_path" ]]; then
        echo "ERROR: Site $site does not exist" >&2
        return 1
    fi

    # Check for Behat binary
    if [[ -f "$site_path/vendor/bin/behat" ]]; then
        return 0
    fi

    # Check if available via DDEV
    if cd "$site_path" && ddev exec "test -f vendor/bin/behat" &>/dev/null; then
        return 0
    fi

    echo "ERROR: Behat not found in $site" >&2
    echo "Install with: ddev composer require --dev drupal/drupal-extension behat/behat" >&2
    return 1
}

#######################################
# Get the Behat configuration file path for a site
# Arguments:
#   $1 - Site name
# Outputs: Path to behat.yml
#######################################
behat_get_config() {
    local site="$1"
    local site_path="$PROJECT_ROOT/sites/$site"

    # Check common locations
    for config in "behat.yml" "behat.yaml" "behat.local.yml" "tests/behat.yml"; do
        if [[ -f "$site_path/$config" ]]; then
            echo "$site_path/$config"
            return 0
        fi
    done

    return 1
}

#######################################
# Generate a timestamp-based log filename
# Arguments:
#   $1 - Site name
#   $2 - Suite name (optional)
# Outputs: Log file path
#######################################
behat_log_filename() {
    local site="$1"
    local suite="${2:-default}"
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)

    echo "$BEHAT_LOG_DIR/behat-${site}-${suite}-${timestamp}.log"
}

################################################################################
# SECTION 2: Test Execution
################################################################################

#######################################
# Run Behat tests for a site
# Arguments:
#   $1 - Site name (required)
#   $2 - Suite or tags (optional, default: smoke)
#   $3 - Additional options (optional)
# Returns: 0 if all tests pass, 1 if any fail
#######################################
behat_run_suite() {
    local site="$1"
    local suite="${2:-smoke}"
    local options="${3:-}"

    if [[ -z "$site" ]]; then
        echo "ERROR: behat_run_suite requires a site name" >&2
        return 1
    fi

    # Initialize if not done
    [[ ! -d "$BEHAT_LOG_DIR" ]] && behat_init

    # Check Behat is available
    if ! behat_check_available "$site"; then
        return 1
    fi

    local site_path="$PROJECT_ROOT/sites/$site"
    local log_file
    log_file=$(behat_log_filename "$site" "$suite")
    local config_file
    config_file=$(behat_get_config "$site")

    echo ""
    echo "Running Behat: $site [$suite]"
    echo "─────────────────────────────────────────"
    echo "Log file: $log_file"

    # Build command
    local behat_cmd="vendor/bin/behat"

    # Add configuration file if found
    if [[ -n "$config_file" ]]; then
        behat_cmd="$behat_cmd --config=\"$(basename "$config_file")\""
    fi

    # Handle suite vs tags
    if [[ "$suite" == "smoke" ]]; then
        behat_cmd="$behat_cmd --tags=@smoke"
    elif [[ "$suite" == "full" ]]; then
        # Run all tests
        :
    elif [[ "$suite" =~ ^@ ]]; then
        # It's a tag
        behat_cmd="$behat_cmd --tags=$suite"
    else
        # It's a suite name
        behat_cmd="$behat_cmd --suite=$suite"
    fi

    # Add formatting options
    behat_cmd="$behat_cmd --format=pretty --format=junit --out=,behat-results.xml"

    # Add additional options
    [[ -n "$options" ]] && behat_cmd="$behat_cmd $options"

    # Run Behat via DDEV
    local start_time exit_code output
    start_time=$(date +%s)

    echo "Command: ddev exec $behat_cmd"
    echo ""

    cd "$site_path"
    output=$(timeout "$BEHAT_DEFAULT_TIMEOUT" ddev exec "$behat_cmd" 2>&1) || exit_code=$?
    exit_code=${exit_code:-0}

    local end_time duration
    end_time=$(date +%s)
    duration=$((end_time - start_time))

    # Log output
    {
        echo "# Behat Test Run"
        echo "# Site: $site"
        echo "# Suite: $suite"
        echo "# Date: $(date -Iseconds)"
        echo "# Duration: ${duration}s"
        echo "# Exit code: $exit_code"
        echo ""
        echo "$output"
    } > "$log_file"

    # Parse results
    local scenarios_total scenarios_passed scenarios_failed
    scenarios_total=$(echo "$output" | grep -oP '\d+(?= scenarios?)' | head -1 || echo "0")
    scenarios_passed=$(echo "$output" | grep -oP '\d+(?= passed)' | head -1 || echo "0")
    scenarios_failed=$(echo "$output" | grep -oP '\d+(?= failed)' | head -1 || echo "0")

    # Update counters
    BEHAT_TOTAL_TESTS=$((BEHAT_TOTAL_TESTS + scenarios_total))
    BEHAT_PASSED_TESTS=$((BEHAT_PASSED_TESTS + scenarios_passed))
    BEHAT_FAILED_TESTS=$((BEHAT_FAILED_TESTS + scenarios_failed))

    # Store result
    BEHAT_RESULTS["${site}::${suite}"]="$exit_code"

    # Display summary
    echo ""
    if [[ $exit_code -eq 0 ]]; then
        echo -e "\033[0;32m✓\033[0m All tests passed ($scenarios_passed scenarios)"
    else
        echo -e "\033[0;31m✗\033[0m Tests failed: $scenarios_failed of $scenarios_total scenarios"

        # Capture failure details
        behat_capture_failure "$site" "$suite" "$output" "$log_file"
    fi
    echo "  Duration: ${duration}s"
    echo ""

    # Record in findings
    behat_record_suite "$site" "$suite" "$exit_code" "$duration" "$scenarios_total" "$scenarios_passed" "$scenarios_failed"

    cd "$PROJECT_ROOT"
    return $exit_code
}

#######################################
# Run smoke tests (quick sanity check)
# Arguments:
#   $1 - Site name
# Returns: 0 if passed, 1 if failed
#######################################
behat_run_smoke() {
    local site="$1"
    behat_run_suite "$site" "smoke" "--stop-on-failure"
}

#######################################
# Run full test suite
# Arguments:
#   $1 - Site name
# Returns: 0 if all passed, 1 if any failed
#######################################
behat_run_full() {
    local site="$1"
    behat_run_suite "$site" "full"
}

#######################################
# Run tests with retry logic for flaky tests
# Arguments:
#   $1 - Site name
#   $2 - Suite (optional)
#   $3 - Max retries (optional, default: BEHAT_MAX_RETRIES)
# Returns: 0 if eventually passes, 1 if fails after retries
#######################################
behat_retry() {
    local site="$1"
    local suite="${2:-smoke}"
    local max_retries="${3:-$BEHAT_MAX_RETRIES}"
    local attempt=1
    local exit_code=1

    echo ""
    echo "Running Behat with retry (max $max_retries attempts)"
    echo "═══════════════════════════════════════════════════"

    while [[ $attempt -le $max_retries ]]; do
        echo ""
        echo "Attempt $attempt of $max_retries"

        if behat_run_suite "$site" "$suite"; then
            exit_code=0
            break
        fi

        if [[ $attempt -lt $max_retries ]]; then
            echo ""
            echo "Test failed. Retrying in ${BEHAT_RETRY_DELAY}s..."
            sleep "$BEHAT_RETRY_DELAY"

            # Exponential backoff
            BEHAT_RETRY_DELAY=$((BEHAT_RETRY_DELAY * 2))
            ((BEHAT_RETRIED_TESTS++))
        fi

        ((attempt++))
    done

    if [[ $exit_code -eq 0 ]]; then
        if [[ $attempt -gt 1 ]]; then
            echo ""
            echo "Tests passed after $attempt attempts (flaky test detected)"
        fi
    else
        echo ""
        echo "Tests failed after $max_retries attempts"
    fi

    return $exit_code
}

################################################################################
# SECTION 3: Failure Handling
################################################################################

#######################################
# Capture and record test failure details
# Arguments:
#   $1 - Site name
#   $2 - Suite name
#   $3 - Test output
#   $4 - Log file path
#######################################
behat_capture_failure() {
    local site="$1"
    local suite="$2"
    local output="$3"
    local log_file="$4"

    echo ""
    echo "Capturing failure details..."

    # Extract failed scenarios
    local failed_scenarios
    failed_scenarios=$(echo "$output" | grep -E "^\s+Scenario:" | head -10)

    # Extract error messages
    local error_messages
    error_messages=$(echo "$output" | grep -A 3 "Failed\|Error\|Exception" | head -20)

    # Try to capture screenshot if available
    behat_capture_screenshot "$site" "$suite"

    # Record failure in findings
    local timestamp
    timestamp=$(date -Iseconds)

    if command -v jq &>/dev/null && [[ -f "$BEHAT_FINDINGS_FILE" ]]; then
        local failure
        failure=$(jq -n \
            --arg ts "$timestamp" \
            --arg site "$site" \
            --arg suite "$suite" \
            --arg scenarios "$failed_scenarios" \
            --arg errors "$error_messages" \
            --arg log "$log_file" \
            '{
                timestamp: $ts,
                site: $site,
                suite: $suite,
                failed_scenarios: $scenarios,
                error_messages: $errors,
                log_file: $log
            }')

        jq ".failures += [$failure]" "$BEHAT_FINDINGS_FILE" > "${BEHAT_FINDINGS_FILE}.tmp" && \
        mv "${BEHAT_FINDINGS_FILE}.tmp" "$BEHAT_FINDINGS_FILE"
    fi

    # Print failure summary
    if [[ -n "$failed_scenarios" ]]; then
        echo ""
        echo "Failed scenarios:"
        echo "$failed_scenarios" | head -5
    fi

    if [[ -n "$error_messages" ]]; then
        echo ""
        echo "Errors:"
        echo "$error_messages" | head -10
    fi
}

#######################################
# Capture screenshot on failure
# Arguments:
#   $1 - Site name
#   $2 - Suite/test identifier
# Returns: Path to screenshot if captured
#######################################
behat_capture_screenshot() {
    local site="$1"
    local identifier="${2:-failure}"
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local screenshot_path="$BEHAT_SCREENSHOTS_DIR/${site}-${identifier}-${timestamp}.png"

    local site_path="$PROJECT_ROOT/sites/$site"

    # Check if there's a failed screenshot from Behat
    local behat_screenshot
    behat_screenshot=$(find "$site_path" -name "*.png" -newer "$BEHAT_FINDINGS_FILE" -type f 2>/dev/null | head -1)

    if [[ -n "$behat_screenshot" ]]; then
        cp "$behat_screenshot" "$screenshot_path"
        echo "Screenshot saved: $screenshot_path"

        # Record in findings
        if command -v jq &>/dev/null && [[ -f "$BEHAT_FINDINGS_FILE" ]]; then
            jq ".screenshots += [\"$screenshot_path\"]" "$BEHAT_FINDINGS_FILE" > "${BEHAT_FINDINGS_FILE}.tmp" && \
            mv "${BEHAT_FINDINGS_FILE}.tmp" "$BEHAT_FINDINGS_FILE"
        fi

        echo "$screenshot_path"
        return 0
    fi

    # Try to take screenshot via DDEV/drush if available
    if cd "$site_path" 2>/dev/null; then
        if ddev exec "which wkhtmltopdf" &>/dev/null; then
            local site_url
            site_url=$(ddev describe -j 2>/dev/null | jq -r '.raw.primary_url // empty')
            if [[ -n "$site_url" ]]; then
                ddev exec "wkhtmltoimage --quality 75 $site_url /tmp/screenshot.png" &>/dev/null
                if ddev exec "test -f /tmp/screenshot.png" &>/dev/null; then
                    ddev exec "cat /tmp/screenshot.png" > "$screenshot_path" 2>/dev/null
                    echo "Screenshot captured: $screenshot_path"
                    return 0
                fi
            fi
        fi
    fi

    cd "$PROJECT_ROOT"
    return 1
}

################################################################################
# SECTION 4: Results Recording
################################################################################

#######################################
# Record suite run in findings
# Arguments:
#   $1 - Site name
#   $2 - Suite name
#   $3 - Exit code
#   $4 - Duration
#   $5 - Total scenarios
#   $6 - Passed scenarios
#   $7 - Failed scenarios
#######################################
behat_record_suite() {
    local site="$1"
    local suite="$2"
    local exit_code="$3"
    local duration="$4"
    local total="$5"
    local passed="$6"
    local failed="$7"

    if command -v jq &>/dev/null && [[ -f "$BEHAT_FINDINGS_FILE" ]]; then
        local timestamp
        timestamp=$(date -Iseconds)
        local status
        [[ $exit_code -eq 0 ]] && status="passed" || status="failed"

        local suite_record
        suite_record=$(jq -n \
            --arg ts "$timestamp" \
            --arg site "$site" \
            --arg suite "$suite" \
            --arg status "$status" \
            --argjson duration "$duration" \
            --argjson total "${total:-0}" \
            --argjson passed "${passed:-0}" \
            --argjson failed "${failed:-0}" \
            '{
                timestamp: $ts,
                site: $site,
                suite: $suite,
                status: $status,
                duration_seconds: $duration,
                scenarios: {
                    total: $total,
                    passed: $passed,
                    failed: $failed
                }
            }')

        jq ".suites_run += [$suite_record]" "$BEHAT_FINDINGS_FILE" > "${BEHAT_FINDINGS_FILE}.tmp" && \
        mv "${BEHAT_FINDINGS_FILE}.tmp" "$BEHAT_FINDINGS_FILE"

        # Update summary
        jq ".summary.total = $BEHAT_TOTAL_TESTS |
            .summary.passed = $BEHAT_PASSED_TESTS |
            .summary.failed = $BEHAT_FAILED_TESTS |
            .summary.skipped = $BEHAT_SKIPPED_TESTS |
            .summary.retried = $BEHAT_RETRIED_TESTS" \
            "$BEHAT_FINDINGS_FILE" > "${BEHAT_FINDINGS_FILE}.tmp" && \
        mv "${BEHAT_FINDINGS_FILE}.tmp" "$BEHAT_FINDINGS_FILE"
    fi
}

#######################################
# Get Behat test summary
# Outputs: Summary of test results
#######################################
behat_summary() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "                    Behat Test Summary"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    echo "  Total scenarios: $BEHAT_TOTAL_TESTS"
    echo "  Passed:          $BEHAT_PASSED_TESTS"
    echo "  Failed:          $BEHAT_FAILED_TESTS"
    echo "  Skipped:         $BEHAT_SKIPPED_TESTS"
    echo "  Retried:         $BEHAT_RETRIED_TESTS"
    echo ""

    if [[ $BEHAT_FAILED_TESTS -gt 0 ]]; then
        echo "  Status: FAILED"
    else
        echo "  Status: PASSED"
    fi

    echo ""
    echo "  Findings: $BEHAT_FINDINGS_FILE"
    echo "  Screenshots: $BEHAT_SCREENSHOTS_DIR"
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
}

#######################################
# Get findings as JSON
# Outputs: JSON findings object
#######################################
behat_get_findings() {
    if [[ -f "$BEHAT_FINDINGS_FILE" ]]; then
        cat "$BEHAT_FINDINGS_FILE"
    else
        echo '{"findings": [], "summary": {"total": 0}}'
    fi
}

################################################################################
# SECTION 5: Scenario Verification Integration
################################################################################

#######################################
# Verify site passes Behat smoke tests
# Arguments:
#   $1 - Site name
# Returns: 0 if passed, 1 if failed
#######################################
behat_verify_site() {
    local site="$1"

    if [[ -z "$site" ]]; then
        echo "ERROR: behat_verify_site requires a site name" >&2
        return 1
    fi

    echo ""
    echo "Verifying site with Behat: $site"

    # Initialize
    behat_init

    # Run smoke tests with retry
    if behat_retry "$site" "smoke" 2; then
        echo ""
        echo -e "\033[0;32m✓\033[0m Site $site passed Behat verification"
        return 0
    else
        echo ""
        echo -e "\033[0;31m✗\033[0m Site $site failed Behat verification"

        # Display summary
        behat_summary

        return 1
    fi
}

#######################################
# Run Behat as part of scenario step
# Arguments:
#   $1 - Site name
#   $2 - Test type (smoke|full|@tag)
# Returns: Exit code with detailed output
#######################################
behat_scenario_step() {
    local site="$1"
    local test_type="${2:-smoke}"

    behat_init

    case "$test_type" in
        smoke)
            behat_run_smoke "$site"
            ;;
        full)
            behat_run_full "$site"
            ;;
        *)
            behat_run_suite "$site" "$test_type"
            ;;
    esac
}

################################################################################
# SECTION 6: Help and CLI Interface
################################################################################

#######################################
# Print Behat integration help
#######################################
behat_help() {
    cat << 'EOF'
NWP Behat Integration Library (P51 Phase 3)

Test Execution:
  behat_run_suite SITE [SUITE] [OPTIONS]   Run a Behat test suite
  behat_run_smoke SITE                     Run smoke tests (quick)
  behat_run_full SITE                      Run complete test suite
  behat_retry SITE [SUITE] [MAX_RETRIES]   Run with retry logic

Failure Handling:
  behat_capture_failure SITE SUITE OUTPUT LOG  Capture failure details
  behat_capture_screenshot SITE [ID]           Save screenshot on failure

Results:
  behat_summary                            Show test summary
  behat_get_findings                       Get findings as JSON

Integration:
  behat_verify_site SITE                   Verify site passes smoke tests
  behat_scenario_step SITE [TYPE]          Run as scenario step

Configuration:
  BEHAT_MAX_RETRIES     Maximum retry attempts (default: 3)
  BEHAT_RETRY_DELAY     Initial retry delay in seconds (default: 5)
  BEHAT_DEFAULT_TIMEOUT Test timeout in seconds (default: 300)

Examples:
  # Run smoke tests
  behat_run_smoke mysite

  # Run full suite with retry
  behat_retry mysite full 3

  # Verify site in scenario
  behat_verify_site mysite
EOF
}

#######################################
# CLI entry point
# Arguments:
#   $@ - Command and arguments
#######################################
behat_main() {
    local cmd="${1:-help}"
    shift || true

    case "$cmd" in
        run)
            behat_run_suite "$@"
            ;;
        smoke)
            behat_run_smoke "$@"
            ;;
        full)
            behat_run_full "$@"
            ;;
        retry)
            behat_retry "$@"
            ;;
        verify)
            behat_verify_site "$@"
            ;;
        summary)
            behat_summary
            ;;
        findings)
            behat_get_findings
            ;;
        help|--help|-h)
            behat_help
            ;;
        *)
            echo "Unknown command: $cmd"
            echo "Run 'behat_main help' for usage"
            return 1
            ;;
    esac
}

# Export functions
export -f behat_init behat_check_available behat_get_config behat_log_filename
export -f behat_run_suite behat_run_smoke behat_run_full behat_retry
export -f behat_capture_failure behat_capture_screenshot
export -f behat_record_suite behat_summary behat_get_findings
export -f behat_verify_site behat_scenario_step
export -f behat_help behat_main
