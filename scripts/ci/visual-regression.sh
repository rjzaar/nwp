#!/bin/bash

################################################################################
# CI/CD Visual Regression Testing Script
#
# Integration script for visual regression testing using BackstopJS or similar.
# Captures screenshots of critical pages and compares against baseline images
# to detect unintended visual changes during deployments.
#
# Features:
# - Configurable test scenarios
# - Baseline image management
# - Automated screenshot capture
# - Visual diff generation
# - HTML report generation
# - CI/CD pipeline integration
#
# Usage: scripts/ci/visual-regression.sh [options]
#
# Options:
#   --site-dir <dir>        Site directory (default: current directory)
#   --base-url <url>        Base URL to test (required)
#   --config <file>         BackstopJS config file (default: backstop.json)
#   --reference             Capture reference/baseline images
#   --test                  Run visual regression tests
#   --approve               Approve current test images as new baseline
#   --scenarios <file>      Scenarios config file (default: auto-detect)
#   --viewports <list>      Comma-separated viewport sizes (e.g., "phone,tablet,desktop")
#   --output-dir <dir>      Output directory (default: .logs/visual)
#   --threshold <N>         Mismatch threshold percentage (default: 0.1)
#   --engine <name>         Screenshot engine: puppeteer|playwright (default: puppeteer)
#   --format <fmt>          Report format: html|json|junit (default: html)
#   --fail-on-diff          Exit with error if differences found
#
# Exit codes:
#   0 - All visual tests passed
#   1 - Visual differences detected
#   2 - Critical error (missing dependencies, etc.)
################################################################################

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source UI library for output functions
source "$PROJECT_ROOT/lib/ui.sh"

################################################################################
# Configuration and defaults
################################################################################

SITE_DIR="${PWD}"
BASE_URL=""
CONFIG_FILE=""
COMMAND=""
SCENARIOS_FILE=""
VIEWPORTS="phone,tablet,desktop"
OUTPUT_DIR=""
THRESHOLD="0.1"
ENGINE="puppeteer"
REPORT_FORMAT="html"
FAIL_ON_DIFF=false

# Logs directory
LOGS_DIR="${SITE_DIR}/.logs/visual"

# BackstopJS configuration
BACKSTOP_CONFIG="${SITE_DIR}/backstop.json"
BACKSTOP_SCENARIOS="${SITE_DIR}/backstop-scenarios.json"

################################################################################
# Helper Functions
################################################################################

# Print script usage
usage() {
    cat << EOF
Usage: $(basename "$0") [command] [options]

Visual regression testing for Drupal/OpenSocial sites

Commands:
  reference          Capture reference/baseline images
  test              Run visual regression tests
  approve           Approve current test images as new baseline
  init              Initialize BackstopJS configuration

Options:
  --site-dir <dir>        Site directory (default: current directory)
  --base-url <url>        Base URL to test (required)
  --config <file>         BackstopJS config file
  --scenarios <file>      Scenarios config file
  --viewports <list>      Comma-separated viewports
  --output-dir <dir>      Output directory
  --threshold <N>         Mismatch threshold (default: 0.1)
  --engine <name>         puppeteer|playwright (default: puppeteer)
  --format <fmt>          html|json|junit (default: html)
  --fail-on-diff          Exit with error on differences
  -h, --help              Show this help message

Examples:
  # Initialize configuration
  scripts/ci/visual-regression.sh init --base-url http://localhost

  # Capture baseline images
  scripts/ci/visual-regression.sh reference --base-url http://test.example.com

  # Run visual regression tests
  scripts/ci/visual-regression.sh test --base-url http://test.example.com

  # Approve changes as new baseline
  scripts/ci/visual-regression.sh approve
EOF
}

# Parse command line arguments
parse_args() {
    # First argument is the command
    if [[ $# -gt 0 ]] && [[ ! "$1" =~ ^-- ]]; then
        COMMAND="$1"
        shift
    fi

    while [[ $# -gt 0 ]]; do
        case $1 in
            --site-dir)
                SITE_DIR="$2"
                shift 2
                ;;
            --base-url)
                BASE_URL="$2"
                shift 2
                ;;
            --config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            --scenarios)
                SCENARIOS_FILE="$2"
                shift 2
                ;;
            --viewports)
                VIEWPORTS="$2"
                shift 2
                ;;
            --output-dir)
                OUTPUT_DIR="$2"
                shift 2
                ;;
            --threshold)
                THRESHOLD="$2"
                shift 2
                ;;
            --engine)
                ENGINE="$2"
                shift 2
                ;;
            --format)
                REPORT_FORMAT="$2"
                shift 2
                ;;
            --fail-on-diff)
                FAIL_ON_DIFF=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                usage
                exit 2
                ;;
        esac
    done

    # Set default output directory
    if [ -z "$OUTPUT_DIR" ]; then
        OUTPUT_DIR="${SITE_DIR}/.logs/visual"
    fi

    # Update paths
    LOGS_DIR="$OUTPUT_DIR"
    BACKSTOP_CONFIG="${CONFIG_FILE:-${SITE_DIR}/backstop.json}"
}

# Check if BackstopJS is installed
check_backstop() {
    if ! command -v backstop >/dev/null 2>&1; then
        fail "BackstopJS not found"
        echo ""
        info "Install BackstopJS globally:"
        note "npm install -g backstopjs"
        echo ""
        info "Or install locally in your project:"
        note "npm install --save-dev backstopjs"
        echo ""
        exit 2
    fi

    pass "BackstopJS found: $(backstop --version)"
}

# Initialize BackstopJS configuration
init_config() {
    print_header "Initializing Visual Regression Testing"

    if [ -z "$BASE_URL" ]; then
        print_error "Base URL required for initialization"
        echo "Use: --base-url http://example.com"
        exit 2
    fi

    info "Creating BackstopJS configuration"

    # Create scenarios file
    cat > "$BACKSTOP_SCENARIOS" <<'EOF'
{
  "scenarios": [
    {
      "label": "Homepage",
      "url": "/",
      "referenceUrl": "",
      "readyEvent": "",
      "readySelector": "",
      "delay": 500,
      "hideSelectors": [],
      "removeSelectors": [],
      "hoverSelector": "",
      "clickSelector": "",
      "postInteractionWait": 0,
      "selectors": ["document"],
      "selectorExpansion": true,
      "expect": 0,
      "misMatchThreshold": 0.1,
      "requireSameDimensions": true
    },
    {
      "label": "Login Page",
      "url": "/user/login",
      "selectors": ["document"],
      "delay": 500
    },
    {
      "label": "User Registration",
      "url": "/user/register",
      "selectors": ["document"],
      "delay": 500
    }
  ]
}
EOF

    # Create main BackstopJS config
    cat > "$BACKSTOP_CONFIG" <<EOF
{
  "id": "nwp_visual_regression",
  "viewports": [
    {
      "label": "phone",
      "width": 375,
      "height": 667
    },
    {
      "label": "tablet",
      "width": 768,
      "height": 1024
    },
    {
      "label": "desktop",
      "width": 1920,
      "height": 1080
    }
  ],
  "onBeforeScript": "puppet/onBefore.js",
  "onReadyScript": "puppet/onReady.js",
  "scenarios": $(cat "$BACKSTOP_SCENARIOS" | jq '.scenarios'),
  "paths": {
    "bitmaps_reference": "$OUTPUT_DIR/backstop_data/bitmaps_reference",
    "bitmaps_test": "$OUTPUT_DIR/backstop_data/bitmaps_test",
    "engine_scripts": "$OUTPUT_DIR/backstop_data/engine_scripts",
    "html_report": "$OUTPUT_DIR/backstop_data/html_report",
    "ci_report": "$OUTPUT_DIR/backstop_data/ci_report"
  },
  "report": ["browser", "CI"],
  "engine": "$ENGINE",
  "engineOptions": {
    "args": ["--no-sandbox"]
  },
  "asyncCaptureLimit": 5,
  "asyncCompareLimit": 50,
  "debug": false,
  "debugWindow": false
}
EOF

    # Update base URL in scenarios
    if command -v jq >/dev/null 2>&1; then
        # Add base URL to each scenario
        jq --arg url "$BASE_URL" '.scenarios[] |= . + {url: ($url + .url)}' "$BACKSTOP_SCENARIOS" > "${BACKSTOP_SCENARIOS}.tmp"
        mv "${BACKSTOP_SCENARIOS}.tmp" "$BACKSTOP_SCENARIOS"

        # Regenerate main config with updated scenarios
        jq --arg url "$BASE_URL" --slurpfile scenarios "$BACKSTOP_SCENARIOS" '.scenarios = $scenarios[0].scenarios' "$BACKSTOP_CONFIG" > "${BACKSTOP_CONFIG}.tmp"
        mv "${BACKSTOP_CONFIG}.tmp" "$BACKSTOP_CONFIG"
    else
        warn "jq not installed - manual URL configuration required"
    fi

    # Create output directories
    mkdir -p "$OUTPUT_DIR/backstop_data"

    pass "BackstopJS configuration created"
    note "Config: $BACKSTOP_CONFIG"
    note "Scenarios: $BACKSTOP_SCENARIOS"
    echo ""

    info "Next steps:"
    note "1. Edit scenarios in: $BACKSTOP_SCENARIOS"
    note "2. Capture baseline: scripts/ci/visual-regression.sh reference --base-url $BASE_URL"
    note "3. Run tests: scripts/ci/visual-regression.sh test --base-url $BASE_URL"
    echo ""
}

# Capture reference images
capture_reference() {
    print_header "Capturing Reference Images"

    if [ -z "$BASE_URL" ]; then
        print_error "Base URL required"
        exit 2
    fi

    if [ ! -f "$BACKSTOP_CONFIG" ]; then
        print_error "BackstopJS config not found: $BACKSTOP_CONFIG"
        info "Initialize first: scripts/ci/visual-regression.sh init --base-url $BASE_URL"
        exit 2
    fi

    info "Base URL: $BASE_URL"
    info "Config: $BACKSTOP_CONFIG"
    echo ""

    task "Capturing baseline screenshots..."

    if backstop reference --config="$BACKSTOP_CONFIG"; then
        pass "Reference images captured successfully"

        # Count captured images
        local ref_dir="$OUTPUT_DIR/backstop_data/bitmaps_reference"
        if [ -d "$ref_dir" ]; then
            local count=$(find "$ref_dir" -type f -name "*.png" | wc -l)
            note "Captured $count reference images"
            note "Location: $ref_dir"
        fi

        echo ""
        print_success "Baseline images ready for comparison"
    else
        fail "Failed to capture reference images"
        exit 2
    fi
}

# Run visual regression tests
run_tests() {
    print_header "Running Visual Regression Tests"

    if [ -z "$BASE_URL" ]; then
        print_error "Base URL required"
        exit 2
    fi

    if [ ! -f "$BACKSTOP_CONFIG" ]; then
        print_error "BackstopJS config not found: $BACKSTOP_CONFIG"
        exit 2
    fi

    # Check if reference images exist
    local ref_dir="$OUTPUT_DIR/backstop_data/bitmaps_reference"
    if [ ! -d "$ref_dir" ] || [ -z "$(ls -A "$ref_dir" 2>/dev/null)" ]; then
        print_error "No reference images found"
        info "Capture reference images first:"
        note "scripts/ci/visual-regression.sh reference --base-url $BASE_URL"
        exit 2
    fi

    info "Base URL: $BASE_URL"
    info "Config: $BACKSTOP_CONFIG"
    echo ""

    task "Running visual comparison tests..."

    # Run BackstopJS test
    local test_exit_code=0
    backstop test --config="$BACKSTOP_CONFIG" || test_exit_code=$?

    # Generate reports
    local report_dir="$OUTPUT_DIR/backstop_data/html_report"
    local ci_report="$OUTPUT_DIR/backstop_data/ci_report"

    echo ""

    if [ $test_exit_code -eq 0 ]; then
        pass "All visual regression tests passed"

        if [ -f "$report_dir/index.html" ]; then
            note "Report: $report_dir/index.html"
        fi

        echo ""
        print_success "No visual differences detected"
        exit 0
    else
        fail "Visual differences detected"

        if [ -f "$report_dir/index.html" ]; then
            warn "Review differences in report:"
            note "$report_dir/index.html"
        fi

        if [ -f "$ci_report/backstop.json" ]; then
            # Parse results
            local total=$(jq '.tests | length' "$ci_report/backstop.json" 2>/dev/null || echo "0")
            local passed=$(jq '[.tests[] | select(.status == "pass")] | length' "$ci_report/backstop.json" 2>/dev/null || echo "0")
            local failed=$(jq '[.tests[] | select(.status == "fail")] | length' "$ci_report/backstop.json" 2>/dev/null || echo "0")

            echo ""
            info "Test Results:"
            note "Total: $total"
            note "Passed: $passed"
            note "Failed: $failed"
        fi

        echo ""
        info "To approve changes as new baseline:"
        note "scripts/ci/visual-regression.sh approve"
        echo ""

        if [ "$FAIL_ON_DIFF" = true ]; then
            exit 1
        else
            exit 0
        fi
    fi
}

# Approve test images as new baseline
approve_changes() {
    print_header "Approving Visual Changes"

    if [ ! -f "$BACKSTOP_CONFIG" ]; then
        print_error "BackstopJS config not found: $BACKSTOP_CONFIG"
        exit 2
    fi

    local test_dir="$OUTPUT_DIR/backstop_data/bitmaps_test"
    if [ ! -d "$test_dir" ] || [ -z "$(ls -A "$test_dir" 2>/dev/null)" ]; then
        print_error "No test images found"
        info "Run tests first:"
        note "scripts/ci/visual-regression.sh test --base-url <url>"
        exit 2
    fi

    task "Promoting test images to reference baseline..."

    if backstop approve --config="$BACKSTOP_CONFIG"; then
        pass "Test images approved as new baseline"

        # Count approved images
        local ref_dir="$OUTPUT_DIR/backstop_data/bitmaps_reference"
        if [ -d "$ref_dir" ]; then
            local count=$(find "$ref_dir" -type f -name "*.png" | wc -l)
            note "Updated $count reference images"
        fi

        echo ""
        print_success "New baseline established"
    else
        fail "Failed to approve changes"
        exit 2
    fi
}

################################################################################
# Main Execution
################################################################################

main() {
    print_header "Visual Regression Testing"

    # Parse arguments
    parse_args "$@"

    # Display configuration
    info "Configuration:"
    note "Site directory: ${SITE_DIR}"
    if [ -n "$BASE_URL" ]; then
        note "Base URL: ${BASE_URL}"
    fi
    note "Output directory: ${OUTPUT_DIR}"
    note "Config: ${BACKSTOP_CONFIG}"
    echo ""

    # Check if BackstopJS is installed
    check_backstop
    echo ""

    # Execute command
    case "$COMMAND" in
        init)
            init_config
            ;;
        reference)
            capture_reference
            ;;
        test)
            run_tests
            ;;
        approve)
            approve_changes
            ;;
        "")
            print_error "No command specified"
            echo ""
            echo "Usage: $0 {init|reference|test|approve} [OPTIONS]"
            echo "Run '$0 --help' for more information"
            exit 2
            ;;
        *)
            print_error "Unknown command: $COMMAND"
            usage
            exit 2
            ;;
    esac
}

# Run main function
main "$@"
