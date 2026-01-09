#!/bin/bash
################################################################################
# Test Fixtures Setup Script
#
# Prepares the test environment with fixture data.
# This script can be run standalone or sourced by test scripts.
#
# Usage:
#   ./tests/fixtures/setup.bash              # Set up fixtures
#   ./tests/fixtures/setup.bash --cleanup    # Clean up fixtures
#   source ./tests/fixtures/setup.bash       # Source for functions only
################################################################################

set -euo pipefail

# Script directory
FIXTURES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${FIXTURES_DIR}/../.." && pwd)"

# Fixture paths (exported for use by tests)
export FIXTURE_CNWP="${FIXTURES_DIR}/cnwp.yml"
export FIXTURE_SECRETS="${FIXTURES_DIR}/secrets.yml"
export FIXTURE_SAMPLE_SITE="${FIXTURES_DIR}/sample-site"

################################################################################
# Functions
################################################################################

# Verify that all required fixtures exist
verify_fixtures() {
    local missing=0

    echo "Verifying test fixtures..."

    if [ ! -f "${FIXTURE_CNWP}" ]; then
        echo "  [MISSING] cnwp.yml"
        missing=$((missing + 1))
    else
        echo "  [OK] cnwp.yml"
    fi

    if [ ! -f "${FIXTURE_SECRETS}" ]; then
        echo "  [MISSING] secrets.yml"
        missing=$((missing + 1))
    else
        echo "  [OK] secrets.yml"
    fi

    if [ ! -d "${FIXTURE_SAMPLE_SITE}" ]; then
        echo "  [MISSING] sample-site/"
        missing=$((missing + 1))
    else
        echo "  [OK] sample-site/"

        # Check sample site contents
        if [ -f "${FIXTURE_SAMPLE_SITE}/composer.json" ]; then
            echo "    [OK] composer.json"
        else
            echo "    [MISSING] composer.json"
            missing=$((missing + 1))
        fi

        if [ -d "${FIXTURE_SAMPLE_SITE}/.ddev" ]; then
            echo "    [OK] .ddev/"
        else
            echo "    [MISSING] .ddev/"
            missing=$((missing + 1))
        fi

        if [ -d "${FIXTURE_SAMPLE_SITE}/html/sites/default" ]; then
            echo "    [OK] html/sites/default/"
        else
            echo "    [MISSING] html/sites/default/"
            missing=$((missing + 1))
        fi
    fi

    if [ ${missing} -gt 0 ]; then
        echo ""
        echo "ERROR: ${missing} fixture(s) missing"
        return 1
    fi

    echo ""
    echo "All fixtures verified successfully"
    return 0
}

# Create a temporary test environment with fixtures
# Usage: setup_test_environment "$temp_dir"
setup_test_environment() {
    local temp_dir="${1:-$(mktemp -d -t nwp-test-XXXXXX)}"

    echo "Setting up test environment in: ${temp_dir}"

    # Create directory structure
    mkdir -p "${temp_dir}/sites"
    mkdir -p "${temp_dir}/lib"
    mkdir -p "${temp_dir}/backups"

    # Copy fixtures
    cp "${FIXTURE_CNWP}" "${temp_dir}/cnwp.yml"
    cp "${FIXTURE_SECRETS}" "${temp_dir}/.secrets.yml"
    cp -r "${FIXTURE_SAMPLE_SITE}" "${temp_dir}/sites/testsite"

    # Copy libraries (for sourcing)
    cp "${PROJECT_ROOT}/lib/"*.sh "${temp_dir}/lib/" 2>/dev/null || true

    # Export paths
    export TEST_ENV_DIR="${temp_dir}"
    export TEST_CNWP="${temp_dir}/cnwp.yml"
    export TEST_SECRETS="${temp_dir}/.secrets.yml"
    export TEST_SITE="${temp_dir}/sites/testsite"

    echo "Test environment ready:"
    echo "  TEST_ENV_DIR=${TEST_ENV_DIR}"
    echo "  TEST_CNWP=${TEST_CNWP}"
    echo "  TEST_SECRETS=${TEST_SECRETS}"
    echo "  TEST_SITE=${TEST_SITE}"

    echo "${temp_dir}"
}

# Clean up test environment
# Usage: cleanup_test_environment "$temp_dir"
cleanup_test_environment() {
    local temp_dir="${1:-${TEST_ENV_DIR:-}}"

    if [ -z "${temp_dir}" ]; then
        echo "No test environment to clean up"
        return 0
    fi

    # Safety check - only remove directories in /tmp or BATS temp dirs
    if [[ "${temp_dir}" == /tmp/* ]] || [[ "${temp_dir}" == */bats-run-* ]]; then
        echo "Cleaning up test environment: ${temp_dir}"
        rm -rf "${temp_dir}"
    else
        echo "WARNING: Refusing to remove non-temp directory: ${temp_dir}"
        return 1
    fi

    unset TEST_ENV_DIR TEST_CNWP TEST_SECRETS TEST_SITE
}

# Create additional test site
# Usage: create_test_site "$name" "$recipe"
create_test_site() {
    local name="$1"
    local recipe="${2:-test}"
    local base_dir="${TEST_ENV_DIR:-${FIXTURES_DIR}}"
    local site_dir="${base_dir}/sites/${name}"

    echo "Creating test site: ${name} (recipe: ${recipe})"

    # Copy sample site structure
    cp -r "${FIXTURE_SAMPLE_SITE}" "${site_dir}"

    # Update DDEV config name
    if [ -f "${site_dir}/.ddev/config.yaml" ]; then
        sed -i "s/^name:.*/name: ${name}/" "${site_dir}/.ddev/config.yaml"
    fi

    echo "${site_dir}"
}

# Display fixture information
show_fixtures_info() {
    echo "NWP Test Fixtures"
    echo "================="
    echo ""
    echo "Location: ${FIXTURES_DIR}"
    echo ""
    echo "Available fixtures:"
    echo "  - cnwp.yml        : Minimal test configuration"
    echo "  - secrets.yml     : Mock secrets (no real credentials)"
    echo "  - sample-site/    : Minimal Drupal site structure"
    echo ""
    echo "Environment variables when sourced:"
    echo "  FIXTURE_CNWP        = ${FIXTURE_CNWP}"
    echo "  FIXTURE_SECRETS     = ${FIXTURE_SECRETS}"
    echo "  FIXTURE_SAMPLE_SITE = ${FIXTURE_SAMPLE_SITE}"
    echo ""
    echo "Functions available:"
    echo "  verify_fixtures           - Check all fixtures exist"
    echo "  setup_test_environment    - Create temp test environment"
    echo "  cleanup_test_environment  - Clean up temp environment"
    echo "  create_test_site          - Create additional test site"
}

################################################################################
# Main (when run as script, not sourced)
################################################################################

# Only run main if not being sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        --verify)
            verify_fixtures
            ;;
        --setup)
            setup_test_environment "${2:-}"
            ;;
        --cleanup)
            cleanup_test_environment "${2:-}"
            ;;
        --info|--help)
            show_fixtures_info
            ;;
        "")
            # Default: verify fixtures
            verify_fixtures
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--verify|--setup [dir]|--cleanup [dir]|--info]"
            exit 1
            ;;
    esac
fi
