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
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

# Source shared libraries
source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh"

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

# Normalize site path — the directory the DDEV project actually lives in.
# Delegates to resolve_project (lib/project-resolver.sh) so the F17/F23 v2
# nested layout (sites/<name>/dev) and the v1 flat layout both work; this
# function previously knew only the flat layout, so every v2 site failed with
# "no .ddev/config.yaml" AFTER the pre-update backup had already run.
get_site_path() {
    local sitename="$1"
    local p

    # An explicit existing path is honoured as-is.
    if [ -d "$sitename" ] && [ -d "$sitename/.ddev" ]; then
        echo "$sitename"
        return 0
    fi

    p="$(resolve_project "$sitename" dev 2>/dev/null)" || return 1
    [ -n "$p" ] && [ -d "$p" ] || return 1
    echo "$p"
}

# Check for Drupal security updates
check_drupal_security() {
    local sitename="$1"
    local site_path

    site_path=$(get_site_path "$sitename") || {
        print_header "Drupal Security Check: $sitename"
        print_error "Site not found: $sitename"
        return 1
    }

    print_header "Drupal Security Check: $sitename"

    cd "$site_path" || return 1

    local updates_found=0

    # Check with drush.
    # IMPORTANT: `drush pm:security` EXITS NON-ZERO when advisories exist. We must
    # capture output+rc ONCE and classify three states, never re-run and never treat
    # a non-zero exit as "clean". Three states:
    #   rc == 0                         -> clean (no advisories)
    #   rc != 0 with advisory content   -> vulnerable (fail, updates_found=1)
    #   rc != 0 without advisory content-> UNKNOWN (fail loud, return non-zero)
    print_info "Checking Drupal security advisories..."
    local drush_output drush_rc
    drush_output=$(ddev drush pm:security 2>&1)
    drush_rc=$?

    if [ $drush_rc -eq 0 ]; then
        print_status "OK" "No Drupal security updates"
    elif echo "$drush_output" | grep -qE "(SECURITY UPDATE|SA-|advisor)"; then
        print_warning "Security updates available!"
        updates_found=1
    else
        print_error "Could not determine Drupal security status (drush pm:security failed with no advisory output)"
        [ -n "$drush_output" ] && print_info "$drush_output"
        cd - > /dev/null
        return 2
    fi

    cd - > /dev/null
    return $updates_found
}

# Check for Composer security issues
check_composer_security() {
    local sitename="$1"
    local site_path

    site_path=$(get_site_path "$sitename") || {
        print_header "Composer Security Check: $sitename"
        print_error "Site not found: $sitename"
        return 1
    }

    print_header "Composer Security Check: $sitename"

    cd "$site_path" || return 1

    local issues_found=0

    # Use composer audit.
    # IMPORTANT: `composer audit` EXITS NON-ZERO when vulnerabilities exist. Capture
    # output+rc ONCE and classify three states; never re-run and never treat a
    # non-zero exit as "clean":
    #   rc == 0                          -> clean
    #   rc != 0 with advisory content    -> vulnerable (fail, issues_found=1)
    #   rc != 0 without advisory content -> UNKNOWN (fail loud, return non-zero)
    print_info "Running composer audit..."
    local audit_output audit_rc
    audit_output=$(ddev composer audit 2>&1)
    audit_rc=$?

    if [ $audit_rc -eq 0 ]; then
        print_status "OK" "No Composer vulnerabilities"
    elif echo "$audit_output" | grep -qiE "(found|advisor|CVE|GHSA)"; then
        print_warning "Composer vulnerabilities found!"
        issues_found=1
    else
        print_error "Could not determine Composer security status (composer audit failed with no advisory output)"
        [ -n "$audit_output" ] && print_info "$audit_output"
        cd - > /dev/null
        return 2
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
    local site_path

    site_path=$(get_site_path "$sitename") || {
        print_header "Security Update: $sitename"
        print_error "Site not found: $sitename"
        return 1
    }

    print_header "Security Update: $sitename"

    cd "$site_path" || return 1

    # Backup first
    print_info "Creating backup before updates..."
    cd - > /dev/null
    "${SCRIPT_DIR}/backup.sh" -b "$sitename" "Pre-security-update"
    cd "$site_path" || return 1

    # Update Drupal core and contrib, plus guzzlehttp — the HTTP stack is as
    # much a security surface as drupal/* and is where the 2026-07 fleet
    # advisories (4× Guzzle) actually lived; drupal/* alone missed it on any
    # site whose core pin didn't happen to drag guzzle forward.
    print_info "Updating Drupal + HTTP-stack packages..."
    if [ "$yes" == "true" ]; then
        ddev composer update "drupal/*" "guzzlehttp/*" --with-dependencies -n
    else
        ddev composer update "drupal/*" "guzzlehttp/*" --with-dependencies
    fi

    # DB steps only make sense against an INSTALLED site. Several dev tiers
    # are uninstalled code shells (near-empty DB, content lives on live);
    # there updb can only fail its bootstrap, which used to turn a successful
    # package update into a failed run. Deferring is honest: updb runs on the
    # tier that owns the database, at deploy.
    local bootstrap
    bootstrap="$(ddev drush status --field=bootstrap 2>/dev/null || true)"
    if printf '%s' "$bootstrap" | grep -qi "successful"; then
        print_info "Running database updates..."
        ddev drush updb -y

        # Clear cache
        ddev drush cr

        # Export config if needed
        print_info "Exporting configuration..."
        ddev drush cex -y 2>/dev/null || true
    else
        print_info "No installed site in this dev tier (bootstrap: '${bootstrap:-none}') —"
        print_info "updb/cr/cex deferred to the tier that owns the database (at deploy)."
    fi

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
    local site_path

    site_path=$(get_site_path "$sitename") || {
        print_header "Security Audit: $sitename"
        print_error "Site not found: $sitename"
        return 1
    }

    print_header "Security Audit: $sitename"

    cd "$site_path" || return 1

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
    local cnwp_file="${PROJECT_ROOT}/nwp.yml"

    if [ ! -f "$cnwp_file" ]; then
        print_error "nwp.yml not found"
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

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
