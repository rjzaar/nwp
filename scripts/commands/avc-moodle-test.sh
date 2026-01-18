#!/bin/bash
set -euo pipefail

################################################################################
# NWP AVC-Moodle Test Script
#
# Test OAuth2 SSO and integration functionality
#
# Usage: pl avc-moodle-test <avc-site> <moodle-site>
################################################################################

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

# Source shared libraries
source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/avc-moodle.sh"

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0
TOTAL_TESTS=0

################################################################################
# Test Functions
################################################################################

# Run a test and track results
run_test() {
    local test_name=$1
    local test_command=$2

    TOTAL_TESTS=$((TOTAL_TESTS + 1))

    printf "  %-50s" "$test_name..."

    if eval "$test_command" >/dev/null 2>&1; then
        echo -e "${GREEN}✓ PASS${NC}"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "${RED}✗ FAIL${NC}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

# Test OAuth2 endpoint accessibility
test_oauth_endpoints() {
    local avc_url=$1

    print_section "Testing OAuth2 Endpoints"

    run_test "OAuth2 authorize endpoint" \
        "avc_moodle_test_oauth_endpoint '$avc_url' '/oauth/authorize'"

    run_test "OAuth2 token endpoint" \
        "avc_moodle_test_oauth_endpoint '$avc_url' '/oauth/token'"

    run_test "OAuth2 userinfo endpoint" \
        "avc_moodle_test_oauth_endpoint '$avc_url' '/oauth/userinfo'"
}

# Test AVC Drupal configuration
test_avc_config() {
    local avc_dir=$1

    print_section "Testing AVC Configuration"

    cd "$avc_dir" || return 1

    run_test "Simple OAuth module enabled" \
        "ddev drush pm:list --status=enabled 2>/dev/null | grep -q simple_oauth"

    run_test "OAuth private key exists" \
        "test -f '$avc_dir/private/keys/oauth_private.key'"

    run_test "OAuth public key exists" \
        "test -f '$avc_dir/private/keys/oauth_public.key'"

    run_test "OAuth private key has correct permissions" \
        "test \$(stat -c '%a' '$avc_dir/private/keys/oauth_private.key') = '600'"
}

# Test Moodle configuration
test_moodle_config() {
    local moodle_dir=$1

    print_section "Testing Moodle Configuration"

    cd "$moodle_dir" || return 1

    run_test "Moodle config.php exists" \
        "test -f '$moodle_dir/config.php'"

    run_test "Moodle wwwroot configured" \
        "grep -q 'wwwroot' '$moodle_dir/config.php'"
}

# Test nwp.yml configuration
test_cnwp_config() {
    local avc_site=$1
    local moodle_site=$2

    print_section "Testing nwp.yml Configuration"

    run_test "nwp.yml exists" \
        "test -f '$PROJECT_ROOT/nwp.yml'"

    run_test "AVC site configured in nwp.yml" \
        "yq eval '.sites.$avc_site' '$PROJECT_ROOT/nwp.yml' | grep -q '.'"

    run_test "Moodle site configured in nwp.yml" \
        "yq eval '.sites.$moodle_site' '$PROJECT_ROOT/nwp.yml' | grep -q '.'"
}

# Test network connectivity
test_connectivity() {
    local avc_url=$1
    local moodle_url=$2

    print_section "Testing Network Connectivity"

    run_test "AVC site reachable" \
        "curl -s -o /dev/null -w '%{http_code}' --max-time 10 '$avc_url' | grep -qE '^(200|302|303)$'"

    run_test "Moodle site reachable" \
        "curl -s -o /dev/null -w '%{http_code}' --max-time 10 '$moodle_url' | grep -qE '^(200|302|303)$'"

    run_test "AVC site uses HTTPS" \
        "echo '$avc_url' | grep -q '^https://'"

    run_test "Moodle site uses HTTPS" \
        "echo '$moodle_url' | grep -q '^https://'"
}

################################################################################
# Main Script Logic
################################################################################

# Show help
show_help() {
    cat << EOF
${BOLD}NWP AVC-Moodle Test Script${NC}

Test OAuth2 SSO and integration functionality between AVC and Moodle.

${BOLD}USAGE:${NC}
    pl avc-moodle-test <avc-site> <moodle-site>

${BOLD}ARGUMENTS:${NC}
    avc-site        Name of the AVC/OpenSocial site
    moodle-site     Name of the Moodle site

${BOLD}OPTIONS:${NC}
    -h, --help      Show this help message
    -d, --debug     Enable debug output

${BOLD}EXAMPLES:${NC}
    pl avc-moodle-test avc ss

${BOLD}TESTS PERFORMED:${NC}
    1. OAuth2 endpoint accessibility
    2. AVC Drupal configuration
    3. Moodle configuration
    4. nwp.yml configuration
    5. Network connectivity
    6. HTTPS enforcement

EOF
}

# Parse options
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -d|--debug)
            DEBUG=true
            shift
            ;;
        -*)
            print_error "Unknown option: $1"
            show_help
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

# Check required arguments
if [[ $# -lt 2 ]]; then
    print_error "Missing required arguments"
    show_help
    exit 1
fi

AVC_SITE=$1
MOODLE_SITE=$2

# Validate site names
if ! validate_sitename "$AVC_SITE" "AVC site name"; then
    exit 1
fi

if ! validate_sitename "$MOODLE_SITE" "Moodle site name"; then
    exit 1
fi

# Display header
print_header "AVC-Moodle Integration Tests"
print_info "AVC Site: $AVC_SITE"
print_info "Moodle Site: $MOODLE_SITE"
echo ""

# Validate both sites
if ! avc_moodle_validate_avc_site "$AVC_SITE" >/dev/null 2>&1; then
    print_error "AVC site validation failed: $AVC_SITE"
    exit 1
fi

if ! avc_moodle_validate_moodle_site "$MOODLE_SITE" >/dev/null 2>&1; then
    print_error "Moodle site validation failed: $MOODLE_SITE"
    exit 1
fi

# Get site info
AVC_DIR=$(get_site_directory "$AVC_SITE")
MOODLE_DIR=$(get_site_directory "$MOODLE_SITE")
AVC_URL=$(avc_moodle_get_site_url "$AVC_SITE")
MOODLE_URL=$(avc_moodle_get_site_url "$MOODLE_SITE")

# Run tests
test_oauth_endpoints "$AVC_URL"
test_avc_config "$AVC_DIR"
test_moodle_config "$MOODLE_DIR"
test_cnwp_config "$AVC_SITE" "$MOODLE_SITE"
test_connectivity "$AVC_URL" "$MOODLE_URL"

# Display results
echo ""
print_section "Test Results"

if [[ $TESTS_FAILED -eq 0 ]]; then
    print_success "All tests passed! ($TESTS_PASSED/$TOTAL_TESTS)"
    EXIT_CODE=0
else
    print_error "Some tests failed: $TESTS_PASSED passed, $TESTS_FAILED failed (Total: $TOTAL_TESTS)"
    EXIT_CODE=1
fi

echo ""
print_info "Test Summary:"
echo "  Total Tests:  $TOTAL_TESTS"
echo "  Passed:       $TESTS_PASSED"
echo "  Failed:       $TESTS_FAILED"
echo "  Success Rate: $(( TESTS_PASSED * 100 / TOTAL_TESTS ))%"

exit $EXIT_CODE
