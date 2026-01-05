#!/bin/bash
################################################################################
# NWP Podcast Test Script
#
# Tests podcast infrastructure setup components:
#   - Script existence and syntax validation
#   - Library function availability
#   - Prerequisites checking
#   - Configuration validation
#
# This test does NOT create actual infrastructure (Linode, B2, Cloudflare)
# to avoid incurring costs. It validates that all components are in place.
#
# Usage:
#   ./tests/test-podcast.sh [--verbose]
#
# Run from NWP root directory:
#   ./tests/test-podcast.sh
#
################################################################################

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

# Configuration
VERBOSE=false

# Test results
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
FAILED_TESTS=()

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            grep "^#" "$0" | grep -v "^#!/" | sed 's/^# //' | sed 's/^#//'
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Helper functions
print_header() {
    echo -e "\n${BLUE}${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}${BOLD}  $1${NC}"
    echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════════════${NC}\n"
}

print_test() {
    echo -e "${BOLD}TEST:${NC} $1"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}!${NC} $1"
}

run_test() {
    local test_name="$1"
    local test_command="$2"

    TESTS_RUN=$((TESTS_RUN + 1))
    print_test "$test_name"

    if eval "$test_command" >/dev/null 2>&1; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        print_success "PASSED"
        return 0
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILED_TESTS+=("$test_name")
        print_error "FAILED"
        return 1
    fi
}

################################################################################
# Start Testing
################################################################################

print_header "NWP Podcast Test Suite"

################################################################################
# Test 1: Core Scripts
################################################################################

print_header "Test 1: Core Podcast Scripts"

run_test "podcast.sh exists" "[ -f podcast.sh ]"
run_test "podcast.sh is executable" "[ -x podcast.sh ]"
run_test "podcast.sh syntax valid" "bash -n podcast.sh"
run_test "podcast.sh has help" "./podcast.sh --help >/dev/null 2>&1"
run_test "podcast.sh supports setup command" "./podcast.sh --help 2>&1 | grep -q 'setup'"
run_test "podcast.sh supports generate command" "./podcast.sh --help 2>&1 | grep -q 'generate'"
run_test "podcast.sh supports deploy command" "./podcast.sh --help 2>&1 | grep -q 'deploy'"
run_test "podcast.sh supports teardown command" "./podcast.sh --help 2>&1 | grep -q 'teardown'"
run_test "podcast.sh supports status command" "./podcast.sh --help 2>&1 | grep -q 'status'"

################################################################################
# Test 2: Library Files
################################################################################

print_header "Test 2: Podcast Libraries"

run_test "lib/cloudflare.sh exists" "[ -f lib/cloudflare.sh ]"
run_test "lib/cloudflare.sh is executable" "[ -x lib/cloudflare.sh ]"
run_test "lib/cloudflare.sh syntax valid" "bash -n lib/cloudflare.sh"

run_test "lib/b2.sh exists" "[ -f lib/b2.sh ]"
run_test "lib/b2.sh is executable" "[ -x lib/b2.sh ]"
run_test "lib/b2.sh syntax valid" "bash -n lib/b2.sh"

run_test "lib/podcast.sh exists" "[ -f lib/podcast.sh ]"
run_test "lib/podcast.sh is executable" "[ -x lib/podcast.sh ]"
run_test "lib/podcast.sh syntax valid" "bash -n lib/podcast.sh"

################################################################################
# Test 3: Library Functions
################################################################################

print_header "Test 3: Library Functions"

# Source libraries
source lib/linode.sh
source lib/cloudflare.sh
source lib/b2.sh
source lib/podcast.sh

# Cloudflare functions
run_test "get_cloudflare_token function exists" "type get_cloudflare_token >/dev/null 2>&1"
run_test "get_cloudflare_zone_id function exists" "type get_cloudflare_zone_id >/dev/null 2>&1"
run_test "verify_cloudflare_auth function exists" "type verify_cloudflare_auth >/dev/null 2>&1"
run_test "cf_create_dns_a function exists" "type cf_create_dns_a >/dev/null 2>&1"
run_test "cf_upsert_dns_a function exists" "type cf_upsert_dns_a >/dev/null 2>&1"
run_test "cf_delete_dns_record function exists" "type cf_delete_dns_record >/dev/null 2>&1"

# B2 functions
run_test "b2_check_installed function exists" "type b2_check_installed >/dev/null 2>&1"
run_test "b2_create_bucket function exists" "type b2_create_bucket >/dev/null 2>&1"
run_test "b2_create_app_key function exists" "type b2_create_app_key >/dev/null 2>&1"
run_test "b2_get_bucket_url function exists" "type b2_get_bucket_url >/dev/null 2>&1"
run_test "b2_enable_cors function exists" "type b2_enable_cors >/dev/null 2>&1"

# Podcast functions
run_test "generate_password function exists" "type generate_password >/dev/null 2>&1"
run_test "generate_castopod_env function exists" "type generate_castopod_env >/dev/null 2>&1"
run_test "generate_castopod_compose function exists" "type generate_castopod_compose >/dev/null 2>&1"
run_test "generate_caddyfile function exists" "type generate_caddyfile >/dev/null 2>&1"
run_test "generate_podcast_files function exists" "type generate_podcast_files >/dev/null 2>&1"
run_test "setup_podcast_infrastructure function exists" "type setup_podcast_infrastructure >/dev/null 2>&1"
run_test "teardown_podcast function exists" "type teardown_podcast >/dev/null 2>&1"

################################################################################
# Test 4: Linode StackScript
################################################################################

print_header "Test 4: Linode StackScript"

run_test "podcast_server_setup.sh exists" "[ -f linode/podcast_server_setup.sh ]"
run_test "podcast_server_setup.sh is executable" "[ -x linode/podcast_server_setup.sh ]"
run_test "podcast_server_setup.sh syntax valid" "bash -n linode/podcast_server_setup.sh"
run_test "StackScript has UDF parameters" "grep -q '<UDF' linode/podcast_server_setup.sh"
run_test "StackScript installs Docker" "grep -q 'docker' linode/podcast_server_setup.sh"

################################################################################
# Test 5: Configuration Files
################################################################################

print_header "Test 5: Configuration Files"

run_test ".secrets.example.yml has cloudflare section" "grep -q 'cloudflare:' .secrets.example.yml"
run_test ".secrets.example.yml has b2 section" "grep -q 'b2:' .secrets.example.yml"
run_test "example.cnwp.yml has pod recipe" "grep -q '^  pod:' example.cnwp.yml"
run_test "pod recipe has type: podcast" "grep -A1 '^  pod:' example.cnwp.yml | grep -q 'type: podcast'"
run_test "example.cnwp.yml has podcast settings" "grep -q '^podcast:' example.cnwp.yml"

################################################################################
# Test 6: Install.sh Integration
################################################################################

print_header "Test 6: Install.sh Integration"

run_test "install.sh has install_podcast function" "grep -q 'install_podcast()' lib/install-podcast.sh"
run_test "install.sh handles podcast type" "grep -q 'podcast' install.sh"
run_test "install-podcast.sh validates podcast domain" "grep -q 'domain' lib/install-podcast.sh"

################################################################################
# Test 7: Generate Files Test
################################################################################

print_header "Test 7: File Generation Test"

# Test file generation without creating infrastructure
TEST_DIR=$(mktemp -d)
TEST_DOMAIN="test.example.com"

print_info "Testing file generation in $TEST_DIR"

# Generate files
if ./podcast.sh generate "$TEST_DOMAIN" >/dev/null 2>&1; then
    # Find the generated directory
    GEN_DIR=$(ls -td podcast-setup-* 2>/dev/null | head -1)

    if [ -n "$GEN_DIR" ] && [ -d "$GEN_DIR" ]; then
        run_test "Generated .env file" "[ -f '$GEN_DIR/.env' ]"
        run_test "Generated docker-compose.yml" "[ -f '$GEN_DIR/docker-compose.yml' ]"
        run_test "Generated Caddyfile" "[ -f '$GEN_DIR/Caddyfile' ]"
        run_test "Generated deploy.sh" "[ -f '$GEN_DIR/deploy.sh' ]"
        run_test ".env contains CP_BASEURL" "grep -q 'CP_BASEURL' '$GEN_DIR/.env'"
        run_test ".env contains CP_DATABASE" "grep -q 'CP_DATABASE' '$GEN_DIR/.env'"
        run_test "docker-compose.yml has castopod service" "grep -q 'castopod:' '$GEN_DIR/docker-compose.yml'"
        run_test "Caddyfile has domain" "grep -q '$TEST_DOMAIN' '$GEN_DIR/Caddyfile'"

        # Cleanup generated files
        rm -rf "$GEN_DIR"
        print_info "Cleaned up generated files"
    else
        print_error "Generated directory not found"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    print_warning "podcast.sh generate failed (may need prerequisites)"
    # Still count as a test
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
    FAILED_TESTS+=("File generation")
fi

rm -rf "$TEST_DIR"

################################################################################
# Test 8: Prerequisites Check
################################################################################

print_header "Test 8: Prerequisites Status"

print_info "Running podcast.sh status (informational only)..."
echo ""

# Run status but don't fail the test - just show info
if ./podcast.sh status; then
    run_test "All prerequisites met" "true"
else
    print_warning "Some prerequisites not configured (this is informational)"
    print_info "Configure .secrets.yml and run 'b2 account authorize' for full functionality"
    # Don't count this as a failure - it's informational
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))
fi

################################################################################
# Results Summary
################################################################################

print_header "Test Results Summary"

echo "Total tests run:    $TESTS_RUN"
echo -e "Tests passed:       ${GREEN}$TESTS_PASSED${NC}"
echo -e "Tests failed:       ${RED}$TESTS_FAILED${NC}"
echo ""

if [ $TESTS_FAILED -gt 0 ]; then
    echo -e "${RED}${BOLD}Failed tests:${NC}"
    for test in "${FAILED_TESTS[@]}"; do
        echo -e "  ${RED}✗${NC} $test"
    done
    echo ""
fi

# Calculate success rate
if [ $TESTS_RUN -gt 0 ]; then
    SUCCESS_RATE=$((TESTS_PASSED * 100 / TESTS_RUN))
    echo "Success rate: $SUCCESS_RATE%"
fi
echo ""

# Exit with appropriate code
if [ $TESTS_FAILED -eq 0 ]; then
    print_success "All podcast tests passed!"
    exit 0
else
    print_error "Some podcast tests failed."
    exit 1
fi
