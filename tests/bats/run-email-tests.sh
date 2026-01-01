#!/bin/bash
################################################################################
# run-email-tests.sh - Run BATS tests for email scripts
#
# Usage:
#   ./run-email-tests.sh           # Run all tests
#   ./run-email-tests.sh setup     # Run setup_email.sh tests only
#   ./run-email-tests.sh test      # Run test_email.sh tests only
#   ./run-email-tests.sh mailpit   # Run mailpit-client.sh tests only
################################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="${SCRIPT_DIR}/email"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Check for bats
if ! command -v bats &> /dev/null; then
    echo -e "${RED}Error: BATS not found${NC}"
    echo ""
    echo "Install BATS:"
    echo "  Ubuntu/Debian: sudo apt-get install bats"
    echo "  macOS:         brew install bats-core"
    echo "  Manual:        https://bats-core.readthedocs.io/en/stable/installation.html"
    exit 1
fi

echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  NWP Email Scripts - BATS Test Suite${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo ""

run_tests() {
    local test_file="$1"
    local test_name="$2"

    echo -e "${YELLOW}Running: ${test_name}${NC}"
    echo "─────────────────────────────────────────"

    if bats "$test_file"; then
        echo -e "${GREEN}✓ ${test_name} passed${NC}"
    else
        echo -e "${RED}✗ ${test_name} failed${NC}"
        return 1
    fi
    echo ""
}

case "${1:-all}" in
    setup)
        run_tests "${TEST_DIR}/setup_email.bats" "setup_email.sh tests"
        ;;
    test)
        run_tests "${TEST_DIR}/test_email.bats" "test_email.sh tests"
        ;;
    mailpit)
        run_tests "${TEST_DIR}/mailpit_client.bats" "mailpit-client.sh tests"
        ;;
    all)
        failed=0

        run_tests "${TEST_DIR}/setup_email.bats" "setup_email.sh tests" || failed=$((failed + 1))
        run_tests "${TEST_DIR}/test_email.bats" "test_email.sh tests" || failed=$((failed + 1))
        run_tests "${TEST_DIR}/mailpit_client.bats" "mailpit-client.sh tests" || failed=$((failed + 1))

        echo "═══════════════════════════════════════════════════════════════"
        if [ $failed -eq 0 ]; then
            echo -e "${GREEN}All test suites passed!${NC}"
        else
            echo -e "${RED}${failed} test suite(s) failed${NC}"
            exit 1
        fi
        ;;
    *)
        echo "Usage: $0 [setup|test|mailpit|all]"
        exit 1
        ;;
esac
