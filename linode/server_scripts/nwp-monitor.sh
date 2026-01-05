#!/bin/bash

################################################################################
# nwp-monitor.sh - NWP Site Monitoring Script
################################################################################
#
# Continuous monitoring daemon for deployed Drupal/OpenSocial sites.
# Runs via cron (typically every 5 minutes) to collect metrics and detect issues.
#
# This script runs ON the Linode server and monitors:
#   - HTTP response codes and response times
#   - Disk usage
#   - Site availability
#   - Performance metrics
#
# Metrics are logged to /var/log/nwp/metrics/ in JSON format for analysis.
# Alerts are triggered when thresholds are exceeded.
#
# Usage:
#   ./nwp-monitor.sh [OPTIONS] [SITE_DIR]
#
# Arguments:
#   SITE_DIR             Site directory to monitor (default: /var/www/prod)
#
# Options:
#   --domain DOMAIN      Domain to monitor (required for HTTP checks)
#   --alert-http         Enable HTTP status code alerts (!=200)
#   --alert-time SECS    Alert if response time > SECS (default: 5)
#   --alert-disk PCT     Alert if disk usage > PCT% (default: 90)
#   --notify SCRIPT      Path to notification script (default: nwp-notify.sh)
#   --no-log             Don't write metrics to log files
#   -v, --verbose        Verbose output
#   -h, --help           Show this help message
#
# Exit Codes:
#   0 - Monitoring completed successfully
#   1 - One or more alerts triggered
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
ALERT_HTTP=false
ALERT_TIME_THRESHOLD=5
ALERT_DISK_THRESHOLD=90
NOTIFY_SCRIPT=""
NO_LOG=false
VERBOSE=false

# Metrics
METRIC_TIMESTAMP=""
METRIC_HTTP_CODE="000"
METRIC_HTTPS_CODE="000"
METRIC_RESPONSE_TIME=0
METRIC_DISK_USAGE=0
METRIC_DISK_AVAIL=""

# Alert tracking
ALERTS_TRIGGERED=0

# Log directory
LOG_DIR="/var/log/nwp/metrics"
LOG_FILE=""

################################################################################
# Helper Functions
################################################################################

print_info() {
    if [ "$VERBOSE" = true ]; then
        echo -e "${BLUE}INFO:${NC} $1"
    fi
}

print_success() {
    if [ "$VERBOSE" = true ]; then
        echo -e "${GREEN}✓${NC} $1"
    fi
}

print_warning() {
    if [ "$VERBOSE" = true ]; then
        echo -e "${YELLOW}!${NC} $1"
    fi
}

print_error() {
    echo -e "${RED}ERROR:${NC} $1" >&2
}

# Trigger alert via notification script
trigger_alert() {
    local alert_type=$1
    local message=$2

    ALERTS_TRIGGERED=$((ALERTS_TRIGGERED + 1))
    print_warning "ALERT: $message"

    # Call notification script if available
    if [ -n "$NOTIFY_SCRIPT" ] && [ -x "$NOTIFY_SCRIPT" ]; then
        print_info "Sending alert notification..."

        if "$NOTIFY_SCRIPT" \
            --event "monitoring_alert" \
            --site "$(basename "$SITE_DIR")" \
            --message "[$alert_type] $message" \
            --domain "$DOMAIN" 2>/dev/null; then
            print_success "Alert notification sent"
        else
            print_warning "Failed to send alert notification"
        fi
    fi
}

################################################################################
# Parse Arguments
################################################################################

while [[ $# -gt 0 ]]; do
    case $1 in
        --domain)
            DOMAIN="$2"
            shift 2
            ;;
        --alert-http)
            ALERT_HTTP=true
            shift
            ;;
        --alert-time)
            ALERT_TIME_THRESHOLD="$2"
            shift 2
            ;;
        --alert-disk)
            ALERT_DISK_THRESHOLD="$2"
            shift 2
            ;;
        --notify)
            NOTIFY_SCRIPT="$2"
            shift 2
            ;;
        --no-log)
            NO_LOG=true
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

################################################################################
# Validation
################################################################################

# Validate site directory
if [ ! -d "$SITE_DIR" ]; then
    print_error "Site directory not found: $SITE_DIR"
    exit 2
fi

# Detect domain from Nginx config if not specified
if [ -z "$DOMAIN" ]; then
    NGINX_CONF="/etc/nginx/sites-enabled/default"
    if [ -f "$NGINX_CONF" ]; then
        DOMAIN=$(grep -m 1 "server_name" "$NGINX_CONF" | awk '{print $2}' | sed 's/;//' 2>/dev/null || echo "")
    fi

    if [ -z "$DOMAIN" ]; then
        DOMAIN="localhost"
        print_warning "No domain specified, using localhost"
    fi
fi

# Try to locate nwp-notify.sh if not specified
if [ -z "$NOTIFY_SCRIPT" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # Check common locations
    for path in \
        "$SCRIPT_DIR/nwp-notify.sh" \
        "/usr/local/bin/nwp-notify.sh" \
        "$SCRIPT_DIR/../../scripts/notify.sh"; do
        if [ -x "$path" ]; then
            NOTIFY_SCRIPT="$path"
            print_info "Found notification script: $NOTIFY_SCRIPT"
            break
        fi
    done

    if [ -z "$NOTIFY_SCRIPT" ]; then
        print_warning "Notification script not found, alerts will be logged only"
    fi
fi

# Ensure log directory exists
if [ "$NO_LOG" != true ]; then
    if [ ! -d "$LOG_DIR" ]; then
        print_info "Creating metrics directory: $LOG_DIR"
        sudo mkdir -p "$LOG_DIR"
        sudo chmod 755 "$LOG_DIR"
    fi

    # Create date-based log file
    LOG_FILE="$LOG_DIR/metrics-$(date +%Y-%m-%d).jsonl"
fi

print_info "Starting monitoring for $DOMAIN (site: $SITE_DIR)"

################################################################################
# Collect Metrics - Timestamp
################################################################################

METRIC_TIMESTAMP=$(date -Iseconds)
print_info "Timestamp: $METRIC_TIMESTAMP"

################################################################################
# Collect Metrics - HTTP Response
################################################################################

print_info "Checking HTTP response..."

# Measure HTTP response time and code
HTTP_START=$(date +%s%N)
METRIC_HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://$DOMAIN" 2>/dev/null || echo "000")
HTTP_END=$(date +%s%N)
HTTP_TIME_NS=$((HTTP_END - HTTP_START))
HTTP_TIME_MS=$((HTTP_TIME_NS / 1000000))

print_info "HTTP Response: $METRIC_HTTP_CODE (${HTTP_TIME_MS}ms)"

# Check HTTPS if available
if curl -s -k -o /dev/null "https://$DOMAIN" 2>/dev/null; then
    HTTPS_START=$(date +%s%N)
    METRIC_HTTPS_CODE=$(curl -s -k -o /dev/null -w "%{http_code}" "https://$DOMAIN" 2>/dev/null || echo "000")
    HTTPS_END=$(date +%s%N)
    HTTPS_TIME_NS=$((HTTPS_END - HTTPS_START))
    HTTPS_TIME_MS=$((HTTPS_TIME_NS / 1000000))

    print_info "HTTPS Response: $METRIC_HTTPS_CODE (${HTTPS_TIME_MS}ms)"

    # Use HTTPS response time if available
    METRIC_RESPONSE_TIME=$((HTTPS_TIME_MS))
else
    METRIC_RESPONSE_TIME=$((HTTP_TIME_MS))
fi

# Convert to seconds for threshold comparison
METRIC_RESPONSE_TIME_SEC=$(echo "scale=2; $METRIC_RESPONSE_TIME / 1000" | bc -l 2>/dev/null || echo "0")

print_success "Response time: ${METRIC_RESPONSE_TIME}ms (${METRIC_RESPONSE_TIME_SEC}s)"

################################################################################
# Collect Metrics - Disk Usage
################################################################################

print_info "Checking disk usage..."

METRIC_DISK_USAGE=$(df / | awk 'NR==2 {print $5}' | sed 's/%//')
METRIC_DISK_AVAIL=$(df -h / | awk 'NR==2 {print $4}')

print_success "Disk usage: ${METRIC_DISK_USAGE}% (${METRIC_DISK_AVAIL} available)"

################################################################################
# Evaluate Alerts - HTTP Status
################################################################################

if [ "$ALERT_HTTP" = true ]; then
    if [ "$METRIC_HTTP_CODE" != "200" ] && [ "$METRIC_HTTP_CODE" != "301" ] && [ "$METRIC_HTTP_CODE" != "302" ]; then
        trigger_alert "HTTP_ERROR" "HTTP status code $METRIC_HTTP_CODE (expected 200, 301, or 302) for http://$DOMAIN"
    fi

    if [ "$METRIC_HTTPS_CODE" != "000" ]; then
        if [ "$METRIC_HTTPS_CODE" != "200" ] && [ "$METRIC_HTTPS_CODE" != "301" ] && [ "$METRIC_HTTPS_CODE" != "302" ]; then
            trigger_alert "HTTPS_ERROR" "HTTPS status code $METRIC_HTTPS_CODE (expected 200, 301, or 302) for https://$DOMAIN"
        fi
    fi
fi

################################################################################
# Evaluate Alerts - Response Time
################################################################################

RESPONSE_TIME_EXCEEDED=0
if command -v bc >/dev/null 2>&1; then
    RESPONSE_TIME_EXCEEDED=$(echo "$METRIC_RESPONSE_TIME_SEC > $ALERT_TIME_THRESHOLD" | bc -l)
else
    # Fallback to integer comparison (convert threshold to ms)
    THRESHOLD_MS=$((ALERT_TIME_THRESHOLD * 1000))
    if [ "$METRIC_RESPONSE_TIME" -gt "$THRESHOLD_MS" ]; then
        RESPONSE_TIME_EXCEEDED=1
    fi
fi

if [ "$RESPONSE_TIME_EXCEEDED" -eq 1 ]; then
    trigger_alert "SLOW_RESPONSE" "Response time ${METRIC_RESPONSE_TIME_SEC}s exceeds threshold of ${ALERT_TIME_THRESHOLD}s for $DOMAIN"
fi

################################################################################
# Evaluate Alerts - Disk Usage
################################################################################

if [ "$METRIC_DISK_USAGE" -gt "$ALERT_DISK_THRESHOLD" ]; then
    trigger_alert "DISK_SPACE" "Disk usage ${METRIC_DISK_USAGE}% exceeds threshold of ${ALERT_DISK_THRESHOLD}% (${METRIC_DISK_AVAIL} available)"
fi

################################################################################
# Write Metrics to Log
################################################################################

if [ "$NO_LOG" != true ]; then
    print_info "Writing metrics to log..."

    # Build JSON metrics entry
    JSON_ENTRY=$(cat <<EOF
{
  "timestamp": "$METRIC_TIMESTAMP",
  "domain": "$DOMAIN",
  "site": "$SITE_DIR",
  "http": {
    "code": $METRIC_HTTP_CODE,
    "response_time_ms": $METRIC_RESPONSE_TIME
  },
  "https": {
    "code": $METRIC_HTTPS_CODE
  },
  "disk": {
    "usage_percent": $METRIC_DISK_USAGE,
    "available": "$METRIC_DISK_AVAIL"
  },
  "alerts": $ALERTS_TRIGGERED
}
EOF
)

    # Append to JSON Lines log file
    echo "$JSON_ENTRY" | sudo tee -a "$LOG_FILE" > /dev/null
    print_success "Metrics logged to $LOG_FILE"
fi

################################################################################
# Summary
################################################################################

if [ "$VERBOSE" = true ]; then
    echo ""
    echo "Monitoring Summary:"
    echo "  Domain: $DOMAIN"
    echo "  HTTP Code: $METRIC_HTTP_CODE"
    echo "  HTTPS Code: $METRIC_HTTPS_CODE"
    echo "  Response Time: ${METRIC_RESPONSE_TIME}ms"
    echo "  Disk Usage: ${METRIC_DISK_USAGE}%"
    echo "  Alerts: $ALERTS_TRIGGERED"
    echo ""
fi

# Exit with appropriate code
if [ $ALERTS_TRIGGERED -gt 0 ]; then
    print_warning "$ALERTS_TRIGGERED alert(s) triggered"
    exit 1
else
    print_success "Monitoring completed successfully"
    exit 0
fi
