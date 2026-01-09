#!/bin/bash
set -euo pipefail

################################################################################
# NWP HTTP Security Headers Check
#
# Tests HTTP security headers on any URL, similar to Mozilla Observatory
#
# Usage: ./security-check.sh <url>
################################################################################

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

# Source shared libraries
source "$PROJECT_ROOT/lib/ui.sh"

################################################################################
# Configuration
################################################################################

# Timeout for curl requests (seconds)
CURL_TIMEOUT=10

# User agent for requests
USER_AGENT="NWP-Security-Check/1.0"

################################################################################
# Help
################################################################################

show_help() {
    cat << EOF
${BOLD}NWP HTTP Security Headers Check${NC}

${BOLD}USAGE:${NC}
    pl security-check <url>
    ./security-check.sh <url>

${BOLD}DESCRIPTION:${NC}
    Tests HTTP security headers on any URL to identify security
    misconfigurations. Similar to Mozilla Observatory but as a local CLI tool.

${BOLD}HEADERS CHECKED:${NC}
    - Strict-Transport-Security (HSTS)
    - Content-Security-Policy (CSP)
    - X-Frame-Options
    - X-Content-Type-Options
    - Referrer-Policy
    - Permissions-Policy
    - Server token exposure (server_tokens)

${BOLD}OPTIONS:${NC}
    -h, --help              Show this help message
    -v, --verbose           Show detailed header values
    -j, --json              Output results as JSON

${BOLD}EXAMPLES:${NC}
    pl security-check https://example.com
    pl security-check https://mysite.ddev.site
    pl security-check -v https://drupal.org

${BOLD}EXIT CODES:${NC}
    0   All headers pass
    1   One or more headers fail/missing
    2   Connection error or invalid URL

EOF
}

################################################################################
# Header Check Functions
################################################################################

# Global variables to store results
declare -A HEADERS
declare -A RESULTS
declare -A RECOMMENDATIONS

PASSED=0
WARNED=0
FAILED=0

# Fetch headers from URL
fetch_headers() {
    local url="$1"
    local response

    # Make request and capture headers
    if ! response=$(curl -sS -I -L --max-time "$CURL_TIMEOUT" \
        -A "$USER_AGENT" \
        "$url" 2>&1); then
        print_error "Failed to connect to $url"
        print_info "Error: $response"
        return 2
    fi

    # Store headers in associative array (lowercase keys for consistency)
    while IFS=': ' read -r key value; do
        # Skip empty lines and HTTP status lines
        [[ -z "$key" || "$key" =~ ^HTTP/ ]] && continue
        # Remove carriage return if present
        value="${value%$'\r'}"
        key="${key,,}"  # Convert to lowercase
        HEADERS["$key"]="$value"
    done <<< "$response"

    return 0
}

# Check Strict-Transport-Security (HSTS)
check_hsts() {
    local header="${HEADERS[strict-transport-security]:-}"

    if [[ -z "$header" ]]; then
        RESULTS[hsts]="FAIL"
        RECOMMENDATIONS[hsts]="Add 'Strict-Transport-Security: max-age=31536000; includeSubDomains' header"
        ((FAILED++))
        return 1
    fi

    # Check for minimum max-age (at least 6 months = 15768000 seconds)
    if [[ "$header" =~ max-age=([0-9]+) ]]; then
        local max_age="${BASH_REMATCH[1]}"
        if [[ $max_age -lt 15768000 ]]; then
            RESULTS[hsts]="WARN"
            RECOMMENDATIONS[hsts]="Increase max-age to at least 15768000 (6 months), recommend 31536000 (1 year)"
            ((WARNED++))
            return 0
        fi
    fi

    # Check for includeSubDomains
    if [[ ! "$header" =~ includeSubDomains ]]; then
        RESULTS[hsts]="WARN"
        RECOMMENDATIONS[hsts]="Consider adding 'includeSubDomains' directive"
        ((WARNED++))
        return 0
    fi

    RESULTS[hsts]="PASS"
    ((PASSED++))
    return 0
}

# Check Content-Security-Policy (CSP)
check_csp() {
    local header="${HEADERS[content-security-policy]:-}"
    local report_only="${HEADERS[content-security-policy-report-only]:-}"

    if [[ -z "$header" && -z "$report_only" ]]; then
        RESULTS[csp]="FAIL"
        RECOMMENDATIONS[csp]="Add Content-Security-Policy header to prevent XSS attacks"
        ((FAILED++))
        return 1
    fi

    if [[ -z "$header" && -n "$report_only" ]]; then
        RESULTS[csp]="WARN"
        RECOMMENDATIONS[csp]="CSP is in report-only mode. Consider enforcing the policy."
        ((WARNED++))
        return 0
    fi

    # Check for unsafe directives
    if [[ "$header" =~ unsafe-inline ]] || [[ "$header" =~ unsafe-eval ]]; then
        RESULTS[csp]="WARN"
        RECOMMENDATIONS[csp]="CSP contains 'unsafe-inline' or 'unsafe-eval' which weaken protection"
        ((WARNED++))
        return 0
    fi

    # Check for default-src
    if [[ ! "$header" =~ default-src ]]; then
        RESULTS[csp]="WARN"
        RECOMMENDATIONS[csp]="CSP should include 'default-src' directive as a fallback"
        ((WARNED++))
        return 0
    fi

    RESULTS[csp]="PASS"
    ((PASSED++))
    return 0
}

# Check X-Frame-Options
check_xframe() {
    local header="${HEADERS[x-frame-options]:-}"

    if [[ -z "$header" ]]; then
        # Check if CSP has frame-ancestors (modern replacement)
        local csp="${HEADERS[content-security-policy]:-}"
        if [[ "$csp" =~ frame-ancestors ]]; then
            RESULTS[xframe]="PASS"
            RECOMMENDATIONS[xframe]="Using CSP frame-ancestors (preferred over X-Frame-Options)"
            ((PASSED++))
            return 0
        fi

        RESULTS[xframe]="FAIL"
        RECOMMENDATIONS[xframe]="Add 'X-Frame-Options: DENY' or 'SAMEORIGIN' to prevent clickjacking"
        ((FAILED++))
        return 1
    fi

    # Validate value
    local upper_header="${header^^}"
    if [[ "$upper_header" != "DENY" && "$upper_header" != "SAMEORIGIN" && ! "$upper_header" =~ ^ALLOW-FROM ]]; then
        RESULTS[xframe]="WARN"
        RECOMMENDATIONS[xframe]="Invalid X-Frame-Options value. Use 'DENY' or 'SAMEORIGIN'"
        ((WARNED++))
        return 0
    fi

    RESULTS[xframe]="PASS"
    ((PASSED++))
    return 0
}

# Check X-Content-Type-Options
check_xcontent() {
    local header="${HEADERS[x-content-type-options]:-}"

    if [[ -z "$header" ]]; then
        RESULTS[xcontent]="FAIL"
        RECOMMENDATIONS[xcontent]="Add 'X-Content-Type-Options: nosniff' to prevent MIME type sniffing"
        ((FAILED++))
        return 1
    fi

    if [[ "${header,,}" != "nosniff" ]]; then
        RESULTS[xcontent]="WARN"
        RECOMMENDATIONS[xcontent]="X-Content-Type-Options should be 'nosniff'"
        ((WARNED++))
        return 0
    fi

    RESULTS[xcontent]="PASS"
    ((PASSED++))
    return 0
}

# Check Referrer-Policy
check_referrer() {
    local header="${HEADERS[referrer-policy]:-}"

    if [[ -z "$header" ]]; then
        RESULTS[referrer]="WARN"
        RECOMMENDATIONS[referrer]="Add 'Referrer-Policy: strict-origin-when-cross-origin' or stricter"
        ((WARNED++))
        return 0
    fi

    # Check for secure policies
    local lower_header="${header,,}"
    local secure_policies="no-referrer strict-origin strict-origin-when-cross-origin same-origin no-referrer-when-downgrade"
    local is_secure=false

    for policy in $secure_policies; do
        if [[ "$lower_header" == "$policy" || "$lower_header" =~ (^|,\ ?)$policy(,|$) ]]; then
            is_secure=true
            break
        fi
    done

    if [[ "$is_secure" != "true" ]]; then
        RESULTS[referrer]="WARN"
        RECOMMENDATIONS[referrer]="Referrer-Policy '$header' may leak sensitive information"
        ((WARNED++))
        return 0
    fi

    RESULTS[referrer]="PASS"
    ((PASSED++))
    return 0
}

# Check Permissions-Policy (formerly Feature-Policy)
check_permissions() {
    local header="${HEADERS[permissions-policy]:-}"
    local feature_header="${HEADERS[feature-policy]:-}"

    if [[ -z "$header" && -z "$feature_header" ]]; then
        RESULTS[permissions]="WARN"
        RECOMMENDATIONS[permissions]="Add Permissions-Policy to control browser features (camera, microphone, etc.)"
        ((WARNED++))
        return 0
    fi

    if [[ -n "$feature_header" && -z "$header" ]]; then
        RESULTS[permissions]="WARN"
        RECOMMENDATIONS[permissions]="Migrate from Feature-Policy to Permissions-Policy (modern syntax)"
        ((WARNED++))
        return 0
    fi

    RESULTS[permissions]="PASS"
    ((PASSED++))
    return 0
}

# Check Server header exposure (server_tokens)
check_server() {
    local header="${HEADERS[server]:-}"
    local powered_by="${HEADERS[x-powered-by]:-}"
    local drupal="${HEADERS[x-drupal-cache]:-}"
    local generator="${HEADERS[x-generator]:-}"

    local issues=""

    # Check Server header for version info
    if [[ -n "$header" ]]; then
        if [[ "$header" =~ [0-9]+\.[0-9]+ ]]; then
            issues+="Server header exposes version info. "
        fi
    fi

    # Check X-Powered-By
    if [[ -n "$powered_by" ]]; then
        issues+="X-Powered-By header exposes technology stack. "
    fi

    # Check X-Generator
    if [[ -n "$generator" ]]; then
        issues+="X-Generator header exposes CMS info. "
    fi

    if [[ -n "$issues" ]]; then
        RESULTS[server]="WARN"
        RECOMMENDATIONS[server]="${issues}Remove or minimize these headers"
        ((WARNED++))
        return 0
    fi

    RESULTS[server]="PASS"
    ((PASSED++))
    return 0
}

################################################################################
# Output Functions
################################################################################

# Print result line
print_result() {
    local name="$1"
    local display_name="$2"
    local result="${RESULTS[$name]:-UNKNOWN}"
    local recommendation="${RECOMMENDATIONS[$name]:-}"

    case "$result" in
        PASS)
            pass "$display_name"
            ;;
        WARN)
            warn "$display_name"
            if [[ -n "$recommendation" && "$VERBOSE" == "true" ]]; then
                note "  $recommendation"
            fi
            ;;
        FAIL)
            fail "$display_name"
            if [[ -n "$recommendation" ]]; then
                note "  $recommendation"
            fi
            ;;
        *)
            info "$display_name - Unknown"
            ;;
    esac
}

# Print verbose header value
print_header_value() {
    local key="$1"
    local display_name="$2"
    local value="${HEADERS[$key]:-Not set}"

    echo -e "  ${CYAN}$display_name:${NC} $value"
}

# Print summary
print_summary() {
    local total=$((PASSED + WARNED + FAILED))

    echo ""
    print_header "Summary"

    echo -e "  ${GREEN}Passed:${NC}  $PASSED"
    echo -e "  ${YELLOW}Warnings:${NC} $WARNED"
    echo -e "  ${RED}Failed:${NC}  $FAILED"
    echo ""

    # Calculate grade
    local grade
    if [[ $FAILED -eq 0 && $WARNED -eq 0 ]]; then
        grade="A+"
        echo -e "  ${GREEN}${BOLD}Grade: $grade${NC} - Excellent security headers!"
    elif [[ $FAILED -eq 0 && $WARNED -le 2 ]]; then
        grade="A"
        echo -e "  ${GREEN}${BOLD}Grade: $grade${NC} - Good security headers"
    elif [[ $FAILED -le 1 && $WARNED -le 3 ]]; then
        grade="B"
        echo -e "  ${YELLOW}${BOLD}Grade: $grade${NC} - Acceptable, but improvements recommended"
    elif [[ $FAILED -le 2 ]]; then
        grade="C"
        echo -e "  ${YELLOW}${BOLD}Grade: $grade${NC} - Several issues to address"
    elif [[ $FAILED -le 4 ]]; then
        grade="D"
        echo -e "  ${RED}${BOLD}Grade: $grade${NC} - Multiple security headers missing"
    else
        grade="F"
        echo -e "  ${RED}${BOLD}Grade: $grade${NC} - Critical security headers missing"
    fi

    echo ""
}

# Print recommendations
print_recommendations() {
    local has_recommendations=false

    for key in "${!RECOMMENDATIONS[@]}"; do
        local result="${RESULTS[$key]:-}"
        if [[ "$result" == "FAIL" || "$result" == "WARN" ]]; then
            has_recommendations=true
            break
        fi
    done

    if [[ "$has_recommendations" == "true" ]]; then
        print_header "Recommendations"

        for key in hsts csp xframe xcontent referrer permissions server; do
            local result="${RESULTS[$key]:-}"
            local recommendation="${RECOMMENDATIONS[$key]:-}"
            if [[ -n "$recommendation" && ("$result" == "FAIL" || "$result" == "WARN") ]]; then
                local icon="!"
                [[ "$result" == "FAIL" ]] && icon="x"
                echo -e "  ${YELLOW}[$icon]${NC} $recommendation"
            fi
        done

        echo ""
        echo -e "  ${CYAN}Resources:${NC}"
        echo "    - Mozilla Observatory: https://observatory.mozilla.org/"
        echo "    - Security Headers: https://securityheaders.com/"
        echo "    - OWASP Secure Headers: https://owasp.org/www-project-secure-headers/"
        echo ""
    fi
}

# Output as JSON
output_json() {
    local url="$1"

    cat << EOF
{
  "url": "$url",
  "checks": {
    "hsts": {"result": "${RESULTS[hsts]:-UNKNOWN}", "recommendation": "${RECOMMENDATIONS[hsts]:-}"},
    "csp": {"result": "${RESULTS[csp]:-UNKNOWN}", "recommendation": "${RECOMMENDATIONS[csp]:-}"},
    "x-frame-options": {"result": "${RESULTS[xframe]:-UNKNOWN}", "recommendation": "${RECOMMENDATIONS[xframe]:-}"},
    "x-content-type-options": {"result": "${RESULTS[xcontent]:-UNKNOWN}", "recommendation": "${RECOMMENDATIONS[xcontent]:-}"},
    "referrer-policy": {"result": "${RESULTS[referrer]:-UNKNOWN}", "recommendation": "${RECOMMENDATIONS[referrer]:-}"},
    "permissions-policy": {"result": "${RESULTS[permissions]:-UNKNOWN}", "recommendation": "${RECOMMENDATIONS[permissions]:-}"},
    "server-tokens": {"result": "${RESULTS[server]:-UNKNOWN}", "recommendation": "${RECOMMENDATIONS[server]:-}"}
  },
  "summary": {
    "passed": $PASSED,
    "warned": $WARNED,
    "failed": $FAILED
  }
}
EOF
}

################################################################################
# Main
################################################################################

main() {
    local URL=""
    VERBOSE=false
    local JSON=false

    # Parse options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -j|--json)
                JSON=true
                shift
                ;;
            -*)
                print_error "Unknown option: $1"
                show_help
                exit 1
                ;;
            *)
                URL="$1"
                shift
                ;;
        esac
    done

    # Validate URL
    if [[ -z "$URL" ]]; then
        print_error "URL is required"
        echo ""
        show_help
        exit 1
    fi

    # Add https:// if no protocol specified
    if [[ ! "$URL" =~ ^https?:// ]]; then
        URL="https://$URL"
    fi

    # Warn if using HTTP
    if [[ "$URL" =~ ^http:// ]]; then
        print_warning "Testing HTTP URL - HTTPS is strongly recommended"
        echo ""
    fi

    # Fetch headers
    if ! fetch_headers "$URL"; then
        exit 2
    fi

    # JSON output mode
    if [[ "$JSON" == "true" ]]; then
        check_hsts || true
        check_csp || true
        check_xframe || true
        check_xcontent || true
        check_referrer || true
        check_permissions || true
        check_server || true
        output_json "$URL"
        exit $([[ $FAILED -eq 0 ]] && echo 0 || echo 1)
    fi

    # Print header
    print_header "HTTP Security Headers Check"
    echo -e "  ${CYAN}URL:${NC} $URL"
    echo ""

    # Verbose mode: show raw headers
    if [[ "$VERBOSE" == "true" ]]; then
        print_header "Response Headers"
        print_header_value "strict-transport-security" "Strict-Transport-Security"
        print_header_value "content-security-policy" "Content-Security-Policy"
        print_header_value "x-frame-options" "X-Frame-Options"
        print_header_value "x-content-type-options" "X-Content-Type-Options"
        print_header_value "referrer-policy" "Referrer-Policy"
        print_header_value "permissions-policy" "Permissions-Policy"
        print_header_value "server" "Server"
        print_header_value "x-powered-by" "X-Powered-By"
        echo ""
    fi

    # Run checks
    print_header "Security Header Checks"

    check_hsts || true
    print_result "hsts" "Strict-Transport-Security (HSTS)"

    check_csp || true
    print_result "csp" "Content-Security-Policy (CSP)"

    check_xframe || true
    print_result "xframe" "X-Frame-Options"

    check_xcontent || true
    print_result "xcontent" "X-Content-Type-Options"

    check_referrer || true
    print_result "referrer" "Referrer-Policy"

    check_permissions || true
    print_result "permissions" "Permissions-Policy"

    check_server || true
    print_result "server" "Server Token Exposure"

    # Print summary
    print_summary

    # Print recommendations if not all passed
    if [[ $FAILED -gt 0 || $WARNED -gt 0 ]]; then
        print_recommendations
    fi

    # Exit with appropriate code
    if [[ $FAILED -gt 0 ]]; then
        exit 1
    fi
    exit 0
}

main "$@"
