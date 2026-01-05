#!/bin/bash

################################################################################
# nwp-healthcheck.sh - NWP Site Health Check Script
################################################################################
#
# Performs comprehensive health checks on deployed Drupal/OpenSocial sites.
# This script runs ON the Linode server and checks:
#   - HTTP response codes
#   - Drupal bootstrap status
#   - Database connectivity
#   - Cache functionality
#   - Cron status
#   - SSL certificate validity
#   - Disk space
#
# Usage:
#   ./nwp-healthcheck.sh [OPTIONS] [SITE_DIR]
#
# Arguments:
#   SITE_DIR             Site directory to check (default: /var/www/prod)
#
# Options:
#   --domain DOMAIN      Domain to check (for HTTP/SSL checks)
#   --quick              Quick check only (HTTP + Drupal bootstrap)
#   --json               Output results in JSON format
#   -v, --verbose        Verbose output
#   -h, --help           Show this help message
#
# Exit Codes:
#   0 - All checks passed
#   1 - One or more checks failed
#   2 - Invalid arguments or configuration error
#
################################################################################

set -e  # Exit on error

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

# Default configuration
SITE_DIR="/var/www/prod"
DOMAIN=""
QUICK_CHECK=false
JSON_OUTPUT=false
VERBOSE=false

# Check results tracking
CHECKS_PASSED=0
CHECKS_FAILED=0
CHECKS_TOTAL=0

# Helper functions
print_header() {
    if [ "$JSON_OUTPUT" != true ]; then
        echo -e "\n${BLUE}${BOLD}═══════════════════════════════════════════════════════════════${NC}"
        echo -e "${BLUE}${BOLD}  $1${NC}"
        echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════════════${NC}\n"
    fi
}

print_info() {
    if [ "$JSON_OUTPUT" != true ]; then
        echo -e "${BLUE}INFO:${NC} $1"
    fi
}

print_success() {
    if [ "$JSON_OUTPUT" != true ]; then
        echo -e "${GREEN}✓${NC} $1"
    fi
}

print_warning() {
    if [ "$JSON_OUTPUT" != true ]; then
        echo -e "${YELLOW}!${NC} $1"
    fi
}

print_error() {
    if [ "$JSON_OUTPUT" != true ]; then
        echo -e "${RED}✗${NC} $1"
    fi
}

# Check result tracking
pass_check() {
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
    CHECKS_TOTAL=$((CHECKS_TOTAL + 1))
    print_success "$1"
}

fail_check() {
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
    CHECKS_TOTAL=$((CHECKS_TOTAL + 1))
    print_error "$1"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --domain)
            DOMAIN="$2"
            shift 2
            ;;
        --quick)
            QUICK_CHECK=true
            shift
            ;;
        --json)
            JSON_OUTPUT=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            grep "^#" "$0" | grep -v "^#!/" | sed 's/^# //' | sed 's/^#//'
            exit 0
            ;;
        -*)
            print_error "Unknown option: $1"
            exit 2
            ;;
        *)
            SITE_DIR="$1"
            shift
            ;;
    esac
done

# Validate site directory
if [ ! -d "$SITE_DIR" ]; then
    print_error "Site directory not found: $SITE_DIR"
    exit 2
fi

# Detect domain from Nginx config if not specified
if [ -z "$DOMAIN" ]; then
    NGINX_CONF="/etc/nginx/sites-enabled/default"
    if [ -f "$NGINX_CONF" ]; then
        DOMAIN=$(grep -m 1 "server_name" "$NGINX_CONF" | awk '{print $2}' | sed 's/;//')
    fi

    if [ -z "$DOMAIN" ]; then
        DOMAIN="localhost"
        print_warning "No domain specified, using localhost"
    fi
fi

if [ "$JSON_OUTPUT" != true ]; then
    print_header "NWP Health Check"
    echo "Site: $SITE_DIR"
    echo "Domain: $DOMAIN"
    echo "Time: $(date)"
    echo ""
fi

################################################################################
# 1. HTTP RESPONSE CHECK
################################################################################

print_header "HTTP Response Check"

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://$DOMAIN" 2>/dev/null || echo "000")

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "301" ] || [ "$HTTP_CODE" = "302" ]; then
    pass_check "HTTP Response: $HTTP_CODE"
else
    fail_check "HTTP Response: $HTTP_CODE (Expected 200, 301, or 302)"
fi

# Check HTTPS if available
if curl -s -o /dev/null "https://$DOMAIN" 2>/dev/null; then
    HTTPS_CODE=$(curl -s -o /dev/null -w "%{http_code}" "https://$DOMAIN" 2>/dev/null || echo "000")
    if [ "$HTTPS_CODE" = "200" ] || [ "$HTTPS_CODE" = "301" ] || [ "$HTTPS_CODE" = "302" ]; then
        pass_check "HTTPS Response: $HTTPS_CODE"
    else
        fail_check "HTTPS Response: $HTTPS_CODE"
    fi
fi

################################################################################
# 2. DRUPAL BOOTSTRAP CHECK
################################################################################

print_header "Drupal Bootstrap Check"

DRUSH_PATH="$SITE_DIR/vendor/bin/drush"

if [ -f "$DRUSH_PATH" ]; then
    cd "$SITE_DIR"

    # Check Drupal status
    if sudo -u www-data "$DRUSH_PATH" status --format=json > /tmp/drush-status.json 2>/dev/null; then
        pass_check "Drupal bootstrap successful"

        if [ "$VERBOSE" = true ]; then
            DRUPAL_VERSION=$(sudo -u www-data "$DRUSH_PATH" status --field=drupal-version 2>/dev/null || echo "unknown")
            print_info "Drupal version: $DRUPAL_VERSION"
        fi
    else
        fail_check "Drupal bootstrap failed"
    fi
else
    fail_check "Drush not found: $DRUSH_PATH"
fi

################################################################################
# 3. DATABASE CONNECTIVITY CHECK
################################################################################

print_header "Database Connectivity Check"

if [ -f "$SITE_DIR/web/sites/default/settings.php" ]; then
    SETTINGS_FILE="$SITE_DIR/web/sites/default/settings.php"

    # Extract database credentials
    DB_NAME=$(grep "^\s*'database'" "$SETTINGS_FILE" | head -n1 | sed "s/.*'\(.*\)'.*/\1/" || echo "")
    DB_USER=$(grep "^\s*'username'" "$SETTINGS_FILE" | head -n1 | sed "s/.*'\(.*\)'.*/\1/" || echo "")
    DB_PASS=$(grep "^\s*'password'" "$SETTINGS_FILE" | head -n1 | sed "s/.*'\(.*\)'.*/\1/" || echo "")

    if [ -n "$DB_NAME" ]; then
        if [ -n "$DB_PASS" ]; then
            if mysql -u "$DB_USER" -p"$DB_PASS" -e "USE $DB_NAME; SELECT 1;" > /dev/null 2>&1; then
                pass_check "Database connection: $DB_NAME"

                if [ "$VERBOSE" = true ]; then
                    TABLE_COUNT=$(mysql -u "$DB_USER" -p"$DB_PASS" -e "USE $DB_NAME; SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DB_NAME';" -N 2>/dev/null || echo "0")
                    print_info "Tables: $TABLE_COUNT"
                fi
            else
                fail_check "Database connection failed: $DB_NAME"
            fi
        else
            if mysql -u "$DB_USER" -e "USE $DB_NAME; SELECT 1;" > /dev/null 2>&1; then
                pass_check "Database connection: $DB_NAME"
            else
                fail_check "Database connection failed: $DB_NAME"
            fi
        fi
    else
        fail_check "Could not extract database name from settings.php"
    fi
else
    fail_check "Settings file not found: $SITE_DIR/web/sites/default/settings.php"
fi

if [ "$QUICK_CHECK" = true ]; then
    # Skip remaining checks for quick mode
    print_header "Quick Check Complete"
    echo "Passed: $CHECKS_PASSED / $CHECKS_TOTAL"
    [ $CHECKS_FAILED -eq 0 ] && exit 0 || exit 1
fi

################################################################################
# 4. CACHE CHECK
################################################################################

print_header "Cache Check"

if [ -f "$DRUSH_PATH" ]; then
    cd "$SITE_DIR"

    # Try to clear cache
    if sudo -u www-data "$DRUSH_PATH" cache:rebuild > /dev/null 2>&1; then
        pass_check "Cache rebuild successful"
    else
        fail_check "Cache rebuild failed"
    fi
else
    print_warning "Drush not available, skipping cache check"
fi

################################################################################
# 5. CRON CHECK
################################################################################

print_header "Cron Status Check"

if [ -f "$DRUSH_PATH" ]; then
    cd "$SITE_DIR"

    # Check last cron run
    LAST_CRON=$(sudo -u www-data "$DRUSH_PATH" state:get system.cron_last --format=string 2>/dev/null || echo "0")
    CURRENT_TIME=$(date +%s)
    CRON_AGE=$((CURRENT_TIME - LAST_CRON))

    # Warn if cron hasn't run in 24 hours (86400 seconds)
    if [ "$LAST_CRON" = "0" ]; then
        fail_check "Cron has never run"
    elif [ $CRON_AGE -gt 86400 ]; then
        HOURS=$((CRON_AGE / 3600))
        fail_check "Cron last ran $HOURS hours ago (>24h)"
    else
        HOURS=$((CRON_AGE / 3600))
        pass_check "Cron last ran $HOURS hours ago"
    fi
else
    print_warning "Drush not available, skipping cron check"
fi

################################################################################
# 6. SSL CERTIFICATE CHECK
################################################################################

print_header "SSL Certificate Check"

if [ "$DOMAIN" != "localhost" ]; then
    CERT_FILE="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"

    if [ -f "$CERT_FILE" ]; then
        # Check certificate expiry
        EXPIRY_DATE=$(openssl x509 -enddate -noout -in "$CERT_FILE" | cut -d= -f2)
        EXPIRY_EPOCH=$(date -d "$EXPIRY_DATE" +%s 2>/dev/null || echo "0")
        CURRENT_EPOCH=$(date +%s)
        DAYS_LEFT=$(( (EXPIRY_EPOCH - CURRENT_EPOCH) / 86400 ))

        if [ $DAYS_LEFT -gt 30 ]; then
            pass_check "SSL certificate valid ($DAYS_LEFT days remaining)"
        elif [ $DAYS_LEFT -gt 0 ]; then
            print_warning "SSL certificate expires in $DAYS_LEFT days"
            fail_check "SSL certificate expiring soon"
        else
            fail_check "SSL certificate expired"
        fi
    else
        print_warning "SSL certificate not found: $CERT_FILE"
    fi
else
    print_warning "Skipping SSL check for localhost"
fi

################################################################################
# 7. DISK SPACE CHECK
################################################################################

print_header "Disk Space Check"

DISK_USAGE=$(df -h / | awk 'NR==2 {print $5}' | sed 's/%//')
DISK_AVAIL=$(df -h / | awk 'NR==2 {print $4}')

if [ "$DISK_USAGE" -lt 80 ]; then
    pass_check "Disk usage: ${DISK_USAGE}% (${DISK_AVAIL} available)"
elif [ "$DISK_USAGE" -lt 90 ]; then
    print_warning "Disk usage: ${DISK_USAGE}% (${DISK_AVAIL} available)"
    fail_check "Disk usage high"
else
    fail_check "Disk usage critical: ${DISK_USAGE}% (${DISK_AVAIL} available)"
fi

################################################################################
# 8. FILE PERMISSIONS CHECK
################################################################################

print_header "File Permissions Check"

# Check that web directory is owned by www-data
OWNER=$(stat -c '%U' "$SITE_DIR" 2>/dev/null || echo "unknown")

if [ "$OWNER" = "www-data" ]; then
    pass_check "Site directory owner: www-data"
else
    fail_check "Site directory owner: $OWNER (expected www-data)"
fi

# Check that settings.php is readable
SETTINGS_PERMS=$(stat -c '%a' "$SITE_DIR/web/sites/default/settings.php" 2>/dev/null || echo "000")

if [ "$SETTINGS_PERMS" = "440" ] || [ "$SETTINGS_PERMS" = "444" ] || [ "$SETTINGS_PERMS" = "644" ]; then
    pass_check "settings.php permissions: $SETTINGS_PERMS"
else
    print_warning "settings.php permissions: $SETTINGS_PERMS (expected 440 or 444)"
fi

################################################################################
# SUMMARY
################################################################################

if [ "$JSON_OUTPUT" = true ]; then
    # Output JSON summary
    cat << EOF
{
  "timestamp": "$(date -Iseconds)",
  "site": "$SITE_DIR",
  "domain": "$DOMAIN",
  "checks": {
    "total": $CHECKS_TOTAL,
    "passed": $CHECKS_PASSED,
    "failed": $CHECKS_FAILED
  },
  "status": "$([ $CHECKS_FAILED -eq 0 ] && echo "PASS" || echo "FAIL")"
}
EOF
else
    print_header "Health Check Summary"

    echo "Total Checks: $CHECKS_TOTAL"
    echo "Passed: ${GREEN}$CHECKS_PASSED${NC}"
    echo "Failed: ${RED}$CHECKS_FAILED${NC}"
    echo ""

    if [ $CHECKS_FAILED -eq 0 ]; then
        print_success "All health checks passed!"
        echo ""
        echo "Status: HEALTHY"
    else
        print_error "$CHECKS_FAILED check(s) failed"
        echo ""
        echo "Status: UNHEALTHY"
    fi
fi

# Exit with appropriate code
[ $CHECKS_FAILED -eq 0 ] && exit 0 || exit 1
