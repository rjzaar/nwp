#!/bin/bash
set -euo pipefail

################################################################################
# NWP Security Script
#
# Check for and apply security updates
#
# Usage: ./security.sh <command> [options] <sitename>
################################################################################

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Source shared libraries
source "$SCRIPT_DIR/lib/ui.sh"
source "$SCRIPT_DIR/lib/common.sh"

################################################################################
# Help
################################################################################

show_help() {
    cat << EOF
${BOLD}NWP Security Script${NC}

${BOLD}USAGE:${NC}
    ./security.sh <command> [options] <sitename>

${BOLD}COMMANDS:${NC}
    check <sitename>        Check for security updates
    update <sitename>       Apply security updates
    audit <sitename>        Run full security audit

${BOLD}OPTIONS:${NC}
    -h, --help              Show this help message
    -d, --debug             Enable debug output
    -y, --yes               Auto-confirm updates
    --auto                  Auto-apply and test (with update)
    --notify                Send notification on completion
    --all                   Check/update all sites

${BOLD}EXAMPLES:${NC}
    ./security.sh check nwp              # Check for updates
    ./security.sh update nwp             # Apply updates
    ./security.sh update --auto nwp      # Apply, test, deploy if pass
    ./security.sh check --all            # Check all sites
    ./security.sh audit nwp              # Full security audit

${BOLD}AUTOMATION:${NC}
    Add to crontab for daily checks:
    0 6 * * * /path/to/security.sh check --all --notify

EOF
}

################################################################################
# Security Check Functions
################################################################################

# Check for Drupal security updates
check_drupal_security() {
    local sitename="$1"

    print_header "Drupal Security Check: $sitename"

    if [ ! -d "$sitename" ]; then
        print_error "Site not found: $sitename"
        return 1
    fi

    cd "$sitename" || return 1

    local updates_found=0

    # Check with drush
    print_info "Checking Drupal security advisories..."
    if ddev drush pm:security 2>/dev/null; then
        if ddev drush pm:security 2>&1 | grep -qE "(SECURITY UPDATE|SA-)"; then
            print_warning "Security updates available!"
            updates_found=1
        else
            print_status "OK" "No Drupal security updates"
        fi
    else
        print_warning "Could not run drush pm:security"
    fi

    cd - > /dev/null
    return $updates_found
}

# Check for Composer security issues
check_composer_security() {
    local sitename="$1"

    print_header "Composer Security Check: $sitename"

    if [ ! -d "$sitename" ]; then
        print_error "Site not found: $sitename"
        return 1
    fi

    cd "$sitename" || return 1

    local issues_found=0

    # Use composer audit
    print_info "Running composer audit..."
    if ddev composer audit 2>&1; then
        if ddev composer audit 2>&1 | grep -q "Found"; then
            print_warning "Composer vulnerabilities found!"
            issues_found=1
        else
            print_status "OK" "No Composer vulnerabilities"
        fi
    else
        print_warning "Could not run composer audit"
    fi

    cd - > /dev/null
    return $issues_found
}

# Full security check
security_check() {
    local sitename="$1"
    local has_issues=0

    print_header "Security Check: $sitename"

    # Drupal security
    if ! check_drupal_security "$sitename"; then
        has_issues=1
    fi

    # Composer security
    if ! check_composer_security "$sitename"; then
        has_issues=1
    fi

    # Summary
    print_header "Security Summary"
    if [ $has_issues -eq 0 ]; then
        print_status "OK" "No security issues found"
        return 0
    else
        print_warning "Security issues found - consider running: ./security.sh update $sitename"
        return 1
    fi
}

################################################################################
# Security Update Functions
################################################################################

# Apply security updates
security_update() {
    local sitename="$1"
    local auto="${2:-false}"
    local yes="${3:-false}"

    print_header "Security Update: $sitename"

    if [ ! -d "$sitename" ]; then
        print_error "Site not found: $sitename"
        return 1
    fi

    cd "$sitename" || return 1

    # Backup first
    print_info "Creating backup before updates..."
    cd - > /dev/null
    "${SCRIPT_DIR}/backup.sh" -b "$sitename" "Pre-security-update"
    cd "$sitename" || return 1

    # Update Drupal core and contrib
    print_info "Updating Drupal packages..."
    if [ "$yes" == "true" ]; then
        ddev composer update "drupal/*" --with-dependencies -n
    else
        ddev composer update "drupal/*" --with-dependencies
    fi

    # Run database updates
    print_info "Running database updates..."
    ddev drush updb -y

    # Clear cache
    ddev drush cr

    # Export config if needed
    print_info "Exporting configuration..."
    ddev drush cex -y 2>/dev/null || true

    cd - > /dev/null

    # Auto mode: run tests
    if [ "$auto" == "true" ]; then
        print_info "Running tests..."
        if "${SCRIPT_DIR}/test.sh" -s "$sitename"; then
            print_status "OK" "Tests passed after security update"

            # Could auto-deploy to staging here
            print_info "Ready for deployment to staging"
        else
            print_error "Tests failed after security update"
            print_warning "Consider running: ./security.sh rollback $sitename"
            return 1
        fi
    fi

    print_status "OK" "Security updates applied"
    return 0
}

################################################################################
# Security Audit
################################################################################

security_audit() {
    local sitename="$1"

    print_header "Security Audit: $sitename"

    if [ ! -d "$sitename" ]; then
        print_error "Site not found: $sitename"
        return 1
    fi

    cd "$sitename" || return 1

    local issues=0

    # Check file permissions
    print_info "Checking file permissions..."
    if [ -f "web/sites/default/settings.php" ]; then
        local perms=$(stat -c %a "web/sites/default/settings.php" 2>/dev/null || stat -f %OLp "web/sites/default/settings.php")
        if [ "$perms" != "444" ] && [ "$perms" != "440" ]; then
            print_warning "settings.php permissions: $perms (should be 444)"
            issues=$((issues + 1))
        else
            print_status "OK" "settings.php permissions: $perms"
        fi
    fi

    # Check for development modules in production config
    print_info "Checking for dev modules..."
    local dev_modules="devel webprofiler kint stage_file_proxy"
    for mod in $dev_modules; do
        if ddev drush pm:list --status=enabled 2>/dev/null | grep -q "$mod"; then
            print_warning "Development module enabled: $mod"
            issues=$((issues + 1))
        fi
    done

    # Check error display settings
    print_info "Checking error display settings..."
    local error_level=$(ddev drush config:get system.logging error_level 2>/dev/null || echo "unknown")
    if [ "$error_level" == "verbose" ] || [ "$error_level" == "all" ]; then
        print_warning "Verbose error display enabled"
        issues=$((issues + 1))
    fi

    # Check for exposed sensitive files
    print_info "Checking for exposed files..."
    local exposed_files=".env .secrets.yml composer.lock"
    for f in $exposed_files; do
        if [ -f "web/$f" ]; then
            print_warning "Sensitive file in webroot: web/$f"
            issues=$((issues + 1))
        fi
    done

    cd - > /dev/null

    # Summary
    print_header "Audit Summary"
    if [ $issues -eq 0 ]; then
        print_status "OK" "No security issues found"
        return 0
    else
        print_warning "Found $issues security issue(s)"
        return 1
    fi
}

################################################################################
# Check All Sites
################################################################################

check_all_sites() {
    local cnwp_file="${SCRIPT_DIR}/cnwp.yml"

    if [ ! -f "$cnwp_file" ]; then
        print_error "cnwp.yml not found"
        return 1
    fi

    print_header "Checking All Sites"

    local sites=$(awk '
        /^sites:/ { in_sites = 1; next }
        in_sites && /^[a-zA-Z]/ && !/^  / { in_sites = 0 }
        in_sites && /^  [a-zA-Z_-]+:/ {
            name = $0
            gsub(/^  /, "", name)
            gsub(/:.*/, "", name)
            print name
        }
    ' "$cnwp_file")

    local total=0
    local issues=0

    for site in $sites; do
        total=$((total + 1))
        # Check both sites/ subdirectory and root directory
        local site_path=""
        if [ -d "sites/$site" ]; then
            site_path="sites/$site"
        elif [ -d "$site" ]; then
            site_path="$site"
        fi

        if [ -n "$site_path" ]; then
            if ! security_check "$site_path"; then
                issues=$((issues + 1))
            fi
        else
            print_warning "Site directory not found: $site"
        fi
    done

    print_header "Summary"
    echo "Sites checked: $total"
    echo "Sites with issues: $issues"

    return $issues
}

################################################################################
# Main
################################################################################

main() {
    local DEBUG=false
    local YES=false
    local AUTO=false
    local NOTIFY=false
    local ALL=false
    local COMMAND=""
    local SITENAME=""

    # Parse options
    local OPTIONS=hdy
    local LONGOPTS=help,debug,yes,auto,notify,all

    if ! PARSED=$(getopt --options=$OPTIONS --longoptions=$LONGOPTS --name "$0" -- "$@"); then
        show_help
        exit 1
    fi

    eval set -- "$PARSED"

    while true; do
        case "$1" in
            -h|--help) show_help; exit 0 ;;
            -d|--debug) DEBUG=true; shift ;;
            -y|--yes) YES=true; shift ;;
            --auto) AUTO=true; shift ;;
            --notify) NOTIFY=true; shift ;;
            --all) ALL=true; shift ;;
            --) shift; break ;;
            *) echo "Programming error"; exit 3 ;;
        esac
    done

    # Get command
    if [ $# -ge 1 ]; then
        COMMAND="$1"
        shift
    else
        print_error "No command specified"
        show_help
        exit 1
    fi

    # Get sitename
    if [ $# -ge 1 ]; then
        SITENAME="$1"
    fi

    # Execute command
    case "$COMMAND" in
        check)
            if [ "$ALL" == "true" ]; then
                check_all_sites
            elif [ -n "$SITENAME" ]; then
                security_check "$SITENAME"
            else
                print_error "Sitename required"
                exit 1
            fi
            ;;
        update)
            if [ -z "$SITENAME" ]; then
                print_error "Sitename required"
                exit 1
            fi
            security_update "$SITENAME" "$AUTO" "$YES"
            ;;
        audit)
            if [ -z "$SITENAME" ]; then
                print_error "Sitename required"
                exit 1
            fi
            security_audit "$SITENAME"
            ;;
        *)
            print_error "Unknown command: $COMMAND"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
