#!/bin/bash
set -euo pipefail

################################################################################
# NWP SEO Check Script
#
# Comprehensive SEO monitoring and sitemap verification
#
# Usage: ./seo-check.sh <command> [options] <sitename>
#
# Commands:
#   check <sitename>       Full SEO check (robots.txt, headers, sitemap)
#   staging <sitename>     Verify staging site is protected from indexing
#   production <sitename>  Verify production site is optimized for SEO
#   sitemap <sitename>     Check sitemap.xml configuration
#   headers <sitename>     Check HTTP headers for SEO directives
#
# Based on: docs/SEO_ROBOTS_PROPOSAL.md
################################################################################

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

# Source shared libraries
source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh"

################################################################################
# Configuration
################################################################################

# Config file
if [ -f "${PROJECT_ROOT}/nwp.yml" ]; then
    CONFIG_FILE="${PROJECT_ROOT}/nwp.yml"
elif [ -f "${PROJECT_ROOT}/example.nwp.yml" ]; then
    CONFIG_FILE="${PROJECT_ROOT}/example.nwp.yml"
else
    CONFIG_FILE="${PROJECT_ROOT}/nwp.yml"
fi

# HTTP timeout for requests
HTTP_TIMEOUT=10

################################################################################
# Help
################################################################################

show_help() {
    cat << EOF
${BOLD}NWP SEO Check Script${NC}

${BOLD}USAGE:${NC}
    ./seo-check.sh <command> [options] <sitename>

${BOLD}COMMANDS:${NC}
    check <sitename>       Full SEO check (robots.txt, headers, sitemap)
    staging <sitename>     Verify staging site is protected from indexing
    production <sitename>  Verify production site is optimized for SEO
    sitemap <sitename>     Check sitemap.xml configuration
    headers <sitename>     Check HTTP headers for SEO directives
    index-risk <domain>    Check if a domain might be indexed (simulates Google check)

${BOLD}OPTIONS:${NC}
    -h, --help            Show this help message
    -d, --debug           Enable debug output
    -q, --quiet           Only show errors and warnings
    -v, --verbose         Show detailed output
    --domain <domain>     Override domain for checks (default: auto-detect)

${BOLD}EXAMPLES:${NC}
    ./seo-check.sh check avc              # Full SEO check for site 'avc'
    ./seo-check.sh staging avc-stg        # Verify staging protection
    ./seo-check.sh production avc         # Verify production SEO
    ./seo-check.sh sitemap avc            # Check sitemap configuration
    ./seo-check.sh index-risk avc-stg.nwpcode.org  # Check indexation risk

${BOLD}ENVIRONMENT DETECTION:${NC}
    - Sites ending in '-stg' or '_stg' are treated as staging
    - Sites ending in '-prod', '_prod', '-live', '_live' are treated as production
    - Other sites are treated as development/local

${BOLD}SEE ALSO:${NC}
    docs/SEO_ROBOTS_PROPOSAL.md   - Full SEO specification
    docs/SEO_SETUP.md             - SEO setup guide
    templates/robots-staging.txt  - Staging robots.txt template
    templates/robots-production.txt - Production robots.txt template

EOF
}

################################################################################
# Site Information Functions
################################################################################

# Get site domain from nwp.yml
get_site_domain() {
    local site="$1"

    # Try to get live domain from config
    local domain=$(awk -v site="$site" '
        /^sites:/ { in_sites = 1; next }
        in_sites && /^[a-zA-Z]/ && !/^  / { exit }
        in_sites && $0 ~ "^  " site ":" { in_site = 1; next }
        in_site && /^  [a-zA-Z]/ && !/^    / { exit }
        in_site && /^    live:/ { in_live = 1; next }
        in_live && /^    [a-zA-Z]/ && !/^      / { in_live = 0 }
        in_live && /^      domain:/ {
            sub("^      domain: *", "")
            gsub(/["'"'"']/, "")
            sub(/ *#.*$/, "")
            gsub(/^[ \t]+|[ \t]+$/, "")
            print
            exit
        }
    ' "$CONFIG_FILE")

    if [ -n "$domain" ]; then
        echo "$domain"
        return
    fi

    # Fallback: try ddev site URL
    local directory=$(get_site_directory "$site")
    if [ -n "$directory" ] && [ -d "$directory/.ddev" ]; then
        echo "${site}.ddev.site"
        return
    fi

    echo ""
}

# Get site directory from nwp.yml
get_site_directory() {
    local site="$1"

    local directory=$(awk -v site="$site" '
        /^sites:/ { in_sites = 1; next }
        in_sites && /^[a-zA-Z]/ && !/^  / { exit }
        in_sites && $0 ~ "^  " site ":" { in_site = 1; next }
        in_site && /^  [a-zA-Z]/ && !/^    / { exit }
        in_site && /^    directory:/ {
            sub("^    directory: *", "")
            gsub(/["'"'"']/, "")
            sub(/ *#.*$/, "")
            gsub(/^[ \t]+|[ \t]+$/, "")
            print
            exit
        }
    ' "$CONFIG_FILE")

    # Handle relative paths
    if [ -n "$directory" ]; then
        if [[ "$directory" != /* ]]; then
            directory="$PROJECT_ROOT/$directory"
        fi
        echo "$directory"
    else
        # Fallback to sites/ directory
        if [ -d "$PROJECT_ROOT/sites/$site" ]; then
            echo "$PROJECT_ROOT/sites/$site"
        fi
    fi
}

# Detect environment from site name
get_environment() {
    local site="$1"

    if [[ "$site" =~ (-stg|_stg)$ ]]; then
        echo "staging"
    elif [[ "$site" =~ (-prod|_prod|-live|_live)$ ]]; then
        echo "production"
    else
        echo "development"
    fi
}

################################################################################
# HTTP Check Functions
################################################################################

# Check robots.txt content
check_robots_txt() {
    local url="$1"
    local expected_env="$2"  # staging or production
    local verbose="${3:-false}"

    print_info "Checking robots.txt at: $url/robots.txt"

    local robots_content
    local http_code

    # Fetch robots.txt
    robots_content=$(curl -sL --max-time "$HTTP_TIMEOUT" "$url/robots.txt" 2>/dev/null || echo "")
    http_code=$(curl -sL -o /dev/null -w "%{http_code}" --max-time "$HTTP_TIMEOUT" "$url/robots.txt" 2>/dev/null || echo "000")

    if [ "$http_code" = "000" ] || [ "$http_code" = "404" ]; then
        print_status "WARN" "robots.txt not found or unreachable (HTTP $http_code)"
        return 1
    fi

    if [ "$verbose" = "true" ]; then
        echo ""
        echo "--- robots.txt content ---"
        echo "$robots_content" | head -20
        echo "..."
        echo "--- end ---"
        echo ""
    fi

    local issues=0

    if [ "$expected_env" = "staging" ]; then
        # Staging should block all crawlers
        if echo "$robots_content" | grep -q "^Disallow: /$"; then
            print_status "OK" "robots.txt blocks all crawlers (Disallow: /)"
        else
            print_status "FAIL" "robots.txt does NOT block all crawlers"
            print_warning "Staging sites should have 'Disallow: /' in robots.txt"
            issues=$((issues + 1))
        fi
    else
        # Production should allow crawlers and have sitemap
        if echo "$robots_content" | grep -qi "^Sitemap:"; then
            local sitemap_url=$(echo "$robots_content" | grep -i "^Sitemap:" | head -1 | sed 's/^Sitemap: *//')
            print_status "OK" "robots.txt references sitemap: $sitemap_url"
        else
            print_status "WARN" "robots.txt does not reference a sitemap"
            issues=$((issues + 1))
        fi

        # Check if admin paths are blocked
        if echo "$robots_content" | grep -q "Disallow: /admin/"; then
            print_status "OK" "robots.txt blocks /admin/"
        else
            print_status "INFO" "robots.txt does not explicitly block /admin/"
        fi

        # Check if it's blocking everything (bad for production)
        if echo "$robots_content" | grep -q "^Disallow: /$"; then
            print_status "WARN" "robots.txt is blocking ALL crawlers - is this intentional for production?"
            issues=$((issues + 1))
        fi
    fi

    return $issues
}

# Check X-Robots-Tag header
check_x_robots_tag() {
    local url="$1"
    local expected_env="$2"

    print_info "Checking X-Robots-Tag header for: $url"

    local headers
    headers=$(curl -sI --max-time "$HTTP_TIMEOUT" "$url" 2>/dev/null || echo "")

    if [ -z "$headers" ]; then
        print_status "WARN" "Could not fetch headers (site unreachable)"
        return 1
    fi

    local x_robots=$(echo "$headers" | grep -i "^x-robots-tag:" | head -1 || echo "")

    local issues=0

    if [ "$expected_env" = "staging" ]; then
        if [ -n "$x_robots" ]; then
            if echo "$x_robots" | grep -qi "noindex"; then
                print_status "OK" "X-Robots-Tag header contains 'noindex'"
                if echo "$x_robots" | grep -qi "nofollow"; then
                    print_status "OK" "X-Robots-Tag header also contains 'nofollow'"
                fi
            else
                print_status "WARN" "X-Robots-Tag present but missing 'noindex'"
                issues=$((issues + 1))
            fi
        else
            print_status "FAIL" "Missing X-Robots-Tag header on staging site"
            print_warning "Staging sites should have: X-Robots-Tag: noindex, nofollow"
            issues=$((issues + 1))
        fi
    else
        # Production shouldn't have noindex
        if [ -n "$x_robots" ] && echo "$x_robots" | grep -qi "noindex"; then
            print_status "WARN" "Production site has X-Robots-Tag: noindex - this blocks indexing!"
            issues=$((issues + 1))
        else
            print_status "OK" "No blocking X-Robots-Tag header (production can be indexed)"
        fi
    fi

    return $issues
}

# Check sitemap.xml
check_sitemap() {
    local url="$1"
    local verbose="${2:-false}"

    print_info "Checking sitemap.xml at: $url/sitemap.xml"

    local http_code
    local content_type
    local sitemap_content

    http_code=$(curl -sL -o /dev/null -w "%{http_code}" --max-time "$HTTP_TIMEOUT" "$url/sitemap.xml" 2>/dev/null || echo "000")

    if [ "$http_code" = "000" ]; then
        print_status "FAIL" "Could not reach sitemap.xml (connection failed)"
        return 1
    fi

    if [ "$http_code" = "404" ]; then
        print_status "WARN" "sitemap.xml not found (404)"
        print_info "Consider installing Simple XML Sitemap module:"
        print_info "  ddev composer require drupal/simple_sitemap"
        print_info "  ddev drush en simple_sitemap -y"
        return 1
    fi

    if [ "$http_code" != "200" ]; then
        print_status "WARN" "sitemap.xml returned HTTP $http_code"
        return 1
    fi

    # Check content type
    content_type=$(curl -sI --max-time "$HTTP_TIMEOUT" "$url/sitemap.xml" 2>/dev/null | grep -i "^content-type:" | head -1 || echo "")

    if echo "$content_type" | grep -qi "xml"; then
        print_status "OK" "sitemap.xml returns XML content type"
    else
        print_status "WARN" "sitemap.xml content type may be incorrect: $content_type"
    fi

    # Check if it's valid XML
    sitemap_content=$(curl -sL --max-time "$HTTP_TIMEOUT" "$url/sitemap.xml" 2>/dev/null || echo "")

    if echo "$sitemap_content" | grep -q "<urlset\|<sitemapindex"; then
        print_status "OK" "sitemap.xml contains valid sitemap XML structure"

        # Count URLs
        local url_count=$(echo "$sitemap_content" | grep -c "<url>" || echo "0")
        if [ "$url_count" -gt 0 ]; then
            print_status "INFO" "sitemap.xml contains $url_count URL entries"
        fi

        # Check for sitemap index
        if echo "$sitemap_content" | grep -q "<sitemapindex"; then
            print_status "INFO" "sitemap.xml is a sitemap index (links to multiple sitemaps)"
        fi
    else
        print_status "WARN" "sitemap.xml does not appear to be valid XML sitemap"
    fi

    if [ "$verbose" = "true" ]; then
        echo ""
        echo "--- sitemap.xml preview ---"
        echo "$sitemap_content" | head -20
        echo "..."
        echo "--- end ---"
        echo ""
    fi

    return 0
}

# Simulate checking if site is indexed (checks for indexation risk indicators)
check_index_risk() {
    local domain="$1"

    print_header "Indexation Risk Check: $domain"

    local issues=0

    # Check if domain resolves
    print_info "Checking DNS resolution..."
    if host "$domain" > /dev/null 2>&1; then
        print_status "OK" "Domain resolves - site is publicly accessible"
    else
        print_status "INFO" "Domain does not resolve publicly"
        echo ""
        print_info "Site is not publicly accessible, low indexation risk"
        return 0
    fi

    # Check robots.txt
    print_info "Checking robots.txt..."
    local robots=$(curl -sL --max-time "$HTTP_TIMEOUT" "https://$domain/robots.txt" 2>/dev/null || echo "")

    if [ -n "$robots" ]; then
        if echo "$robots" | grep -q "^Disallow: /$"; then
            print_status "OK" "robots.txt blocks all crawlers"
        else
            print_status "WARN" "robots.txt does NOT block all crawlers"
            issues=$((issues + 1))
        fi
    else
        print_status "WARN" "No robots.txt found"
        issues=$((issues + 1))
    fi

    # Check X-Robots-Tag
    print_info "Checking X-Robots-Tag header..."
    local headers=$(curl -sI --max-time "$HTTP_TIMEOUT" "https://$domain/" 2>/dev/null || echo "")

    if echo "$headers" | grep -qi "x-robots-tag.*noindex"; then
        print_status "OK" "X-Robots-Tag: noindex header present"
    else
        print_status "WARN" "No X-Robots-Tag: noindex header found"
        issues=$((issues + 1))
    fi

    # Check meta robots tag in HTML
    print_info "Checking meta robots tag..."
    local html=$(curl -sL --max-time "$HTTP_TIMEOUT" "https://$domain/" 2>/dev/null || echo "")

    if echo "$html" | grep -qi 'meta.*name="robots".*noindex\|meta.*content="noindex'; then
        print_status "OK" "Meta robots noindex tag found in HTML"
    else
        print_status "WARN" "No meta robots noindex tag found in HTML"
        issues=$((issues + 1))
    fi

    # Summary
    echo ""
    print_header "Summary"

    if [ $issues -eq 0 ]; then
        print_status "OK" "Site appears well-protected from indexation"
    elif [ $issues -eq 1 ]; then
        print_status "WARN" "Site has some indexation protection but could be improved"
    elif [ $issues -eq 2 ]; then
        print_status "WARN" "Site has minimal indexation protection"
    else
        print_status "FAIL" "Site has NO indexation protection - likely to be indexed!"
        echo ""
        print_warning "Recommendations:"
        echo "  1. Deploy staging robots.txt: cp templates/robots-staging.txt to webroot"
        echo "  2. Add X-Robots-Tag header in nginx/Apache config"
        echo "  3. Configure meta robots tag in Drupal metatag module"
        echo ""
        print_info "See: docs/SEO_ROBOTS_PROPOSAL.md for implementation details"
    fi

    return $issues
}

################################################################################
# Main Check Functions
################################################################################

# Full SEO check for a site
do_full_check() {
    local site="$1"
    local domain="${2:-}"
    local verbose="${3:-false}"

    local env=$(get_environment "$site")
    local total_issues=0

    print_header "SEO Check: $site (Environment: $env)"

    # Get domain
    if [ -z "$domain" ]; then
        domain=$(get_site_domain "$site")
    fi

    if [ -z "$domain" ]; then
        print_error "Could not determine domain for site '$site'"
        print_info "Use --domain to specify manually"
        return 1
    fi

    local url="https://$domain"
    print_info "Checking domain: $domain"
    echo ""

    # Check robots.txt
    if ! check_robots_txt "$url" "$env" "$verbose"; then
        total_issues=$((total_issues + 1))
    fi
    echo ""

    # Check X-Robots-Tag
    if ! check_x_robots_tag "$url" "$env"; then
        total_issues=$((total_issues + 1))
    fi
    echo ""

    # Check sitemap (production only)
    if [ "$env" != "staging" ]; then
        if ! check_sitemap "$url" "$verbose"; then
            total_issues=$((total_issues + 1))
        fi
        echo ""
    fi

    # Summary
    print_header "Summary"

    if [ $total_issues -eq 0 ]; then
        if [ "$env" = "staging" ]; then
            print_status "OK" "Staging site is properly protected from search engine indexing"
        else
            print_status "OK" "Production site SEO configuration looks good"
        fi
        return 0
    else
        print_status "WARN" "Found $total_issues issue(s) - see above for details"
        return 1
    fi
}

# Staging-specific check
do_staging_check() {
    local site="$1"
    local domain="${2:-}"
    local verbose="${3:-false}"

    local env=$(get_environment "$site")

    if [ "$env" != "staging" ]; then
        print_warning "Site '$site' does not appear to be a staging site (no -stg suffix)"
        if ! ask_yes_no "Check anyway?" "n"; then
            return 0
        fi
    fi

    print_header "Staging Protection Check: $site"

    # Get domain
    if [ -z "$domain" ]; then
        domain=$(get_site_domain "$site")
    fi

    if [ -z "$domain" ]; then
        print_error "Could not determine domain for site '$site'"
        return 1
    fi

    local url="https://$domain"
    local issues=0

    print_info "Checking: $url"
    echo ""

    # Check all protection layers
    print_info "Layer 1: X-Robots-Tag Header"
    if ! check_x_robots_tag "$url" "staging"; then
        issues=$((issues + 1))
    fi
    echo ""

    print_info "Layer 2: robots.txt"
    if ! check_robots_txt "$url" "staging" "$verbose"; then
        issues=$((issues + 1))
    fi
    echo ""

    # Summary
    print_header "Staging Protection Summary"

    if [ $issues -eq 0 ]; then
        print_status "OK" "Staging site has proper indexation protection"
    else
        print_status "FAIL" "Staging site is NOT properly protected"
        echo ""
        print_info "To fix, ensure:"
        echo "  1. X-Robots-Tag header is set in nginx/Apache"
        echo "  2. robots.txt blocks all crawlers"
        echo ""
        print_info "See: docs/SEO_SETUP.md for implementation guide"
    fi

    return $issues
}

# Production-specific check
do_production_check() {
    local site="$1"
    local domain="${2:-}"
    local verbose="${3:-false}"

    local env=$(get_environment "$site")

    if [ "$env" = "staging" ]; then
        print_warning "Site '$site' appears to be a staging site (has -stg suffix)"
        if ! ask_yes_no "Check as production anyway?" "n"; then
            return 0
        fi
    fi

    print_header "Production SEO Check: $site"

    # Get domain
    if [ -z "$domain" ]; then
        domain=$(get_site_domain "$site")
    fi

    if [ -z "$domain" ]; then
        print_error "Could not determine domain for site '$site'"
        return 1
    fi

    local url="https://$domain"
    local issues=0

    print_info "Checking: $url"
    echo ""

    # Check robots.txt
    print_info "Robots.txt Configuration"
    if ! check_robots_txt "$url" "production" "$verbose"; then
        issues=$((issues + 1))
    fi
    echo ""

    # Check sitemap
    print_info "Sitemap Configuration"
    if ! check_sitemap "$url" "$verbose"; then
        issues=$((issues + 1))
    fi
    echo ""

    # Check headers (shouldn't block indexing)
    print_info "HTTP Headers"
    if ! check_x_robots_tag "$url" "production"; then
        issues=$((issues + 1))
    fi
    echo ""

    # Summary
    print_header "Production SEO Summary"

    if [ $issues -eq 0 ]; then
        print_status "OK" "Production site SEO looks well configured"
    else
        print_status "WARN" "Found $issues SEO issue(s) to address"
        echo ""
        print_info "Recommendations:"
        echo "  1. Install Simple XML Sitemap module for sitemap.xml"
        echo "  2. Update robots.txt to reference sitemap"
        echo "  3. Verify no blocking headers are set"
        echo ""
        print_info "See: docs/SEO_SETUP.md for setup guide"
    fi

    return $issues
}

# Sitemap-only check
do_sitemap_check() {
    local site="$1"
    local domain="${2:-}"
    local verbose="${3:-false}"

    print_header "Sitemap Check: $site"

    # Get domain
    if [ -z "$domain" ]; then
        domain=$(get_site_domain "$site")
    fi

    if [ -z "$domain" ]; then
        print_error "Could not determine domain for site '$site'"
        return 1
    fi

    local url="https://$domain"
    print_info "Checking: $url"
    echo ""

    check_sitemap "$url" "$verbose"

    return $?
}

# Headers-only check
do_headers_check() {
    local site="$1"
    local domain="${2:-}"

    local env=$(get_environment "$site")

    print_header "HTTP Headers Check: $site"

    # Get domain
    if [ -z "$domain" ]; then
        domain=$(get_site_domain "$site")
    fi

    if [ -z "$domain" ]; then
        print_error "Could not determine domain for site '$site'"
        return 1
    fi

    local url="https://$domain"
    print_info "Checking: $url"
    echo ""

    # Get all headers
    local headers
    headers=$(curl -sI --max-time "$HTTP_TIMEOUT" "$url" 2>/dev/null || echo "")

    if [ -z "$headers" ]; then
        print_error "Could not fetch headers (site unreachable)"
        return 1
    fi

    print_info "SEO-related headers:"
    echo ""

    # X-Robots-Tag
    local x_robots=$(echo "$headers" | grep -i "^x-robots-tag:" || echo "")
    if [ -n "$x_robots" ]; then
        printf "  %-25s %s\n" "X-Robots-Tag:" "$(echo "$x_robots" | cut -d: -f2-)"
    else
        printf "  %-25s %s\n" "X-Robots-Tag:" "(not set)"
    fi

    # Link (canonical)
    local link=$(echo "$headers" | grep -i "^link:" | grep -i canonical || echo "")
    if [ -n "$link" ]; then
        printf "  %-25s %s\n" "Link (canonical):" "$(echo "$link" | cut -d: -f2-)"
    else
        printf "  %-25s %s\n" "Link (canonical):" "(not set)"
    fi

    # Cache-Control
    local cache=$(echo "$headers" | grep -i "^cache-control:" || echo "")
    if [ -n "$cache" ]; then
        printf "  %-25s %s\n" "Cache-Control:" "$(echo "$cache" | cut -d: -f2-)"
    fi

    echo ""
    check_x_robots_tag "$url" "$env"

    return 0
}

################################################################################
# Main
################################################################################

main() {
    local COMMAND=""
    local SITENAME=""
    local DOMAIN=""
    local DEBUG=false
    local QUIET=false
    local VERBOSE=false

    # Parse options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -d|--debug)
                DEBUG=true
                shift
                ;;
            -q|--quiet)
                QUIET=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            --domain)
                DOMAIN="$2"
                shift 2
                ;;
            check|staging|production|sitemap|headers|index-risk)
                COMMAND="$1"
                shift
                ;;
            *)
                if [ -z "$SITENAME" ]; then
                    SITENAME="$1"
                fi
                shift
                ;;
        esac
    done

    # Validate
    if [ -z "$COMMAND" ]; then
        print_error "No command specified"
        echo ""
        show_help
        exit 1
    fi

    if [ -z "$SITENAME" ] && [ "$COMMAND" != "index-risk" ]; then
        print_error "No sitename specified"
        echo ""
        show_help
        exit 1
    fi

    # Execute command
    case "$COMMAND" in
        check)
            do_full_check "$SITENAME" "$DOMAIN" "$VERBOSE"
            ;;
        staging)
            do_staging_check "$SITENAME" "$DOMAIN" "$VERBOSE"
            ;;
        production)
            do_production_check "$SITENAME" "$DOMAIN" "$VERBOSE"
            ;;
        sitemap)
            do_sitemap_check "$SITENAME" "$DOMAIN" "$VERBOSE"
            ;;
        headers)
            do_headers_check "$SITENAME" "$DOMAIN"
            ;;
        index-risk)
            if [ -z "$SITENAME" ]; then
                print_error "No domain specified for index-risk check"
                exit 1
            fi
            check_index_risk "$SITENAME"
            ;;
        *)
            print_error "Unknown command: $COMMAND"
            show_help
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
