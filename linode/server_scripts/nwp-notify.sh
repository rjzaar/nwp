#!/bin/bash

################################################################################
# nwp-notify.sh - NWP Notification Script
################################################################################
#
# Sends notifications for NWP events (failures, alerts, etc.).
# This script runs ON the Linode server.
#
# Usage:
#   ./nwp-notify.sh [OPTIONS]
#
# Options:
#   --event TYPE         Event type (backup_failure, deploy_failure, etc.)
#   --site NAME          Site name or directory
#   --message TEXT       Notification message
#   --severity LEVEL     Severity level: info, warning, error, critical (default: error)
#   --method METHOD      Notification method: log, email, slack, all (default: log)
#   -v, --verbose        Verbose output
#   -h, --help           Show this help message
#
# Notification Methods:
#   log    - Write to system log (syslog)
#   email  - Send email (requires mail command configured)
#   slack  - Send to Slack webhook (requires SLACK_WEBHOOK_URL env var)
#   all    - Use all available methods
#
# Exit Codes:
#   0 - Notification sent successfully
#   1 - Notification failed
#   2 - Invalid arguments
#
# Examples:
#   ./nwp-notify.sh --event backup_failure --site prod --message "Database backup failed"
#   ./nwp-notify.sh --event deploy_failure --site test --severity critical
#
################################################################################

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

# Default configuration
EVENT_TYPE=""
SITE="unknown"
MESSAGE=""
SEVERITY="error"
METHOD="log"
VERBOSE=false

# Notification configuration
LOG_TAG="nwp-notify"
EMAIL_TO="${NWP_ALERT_EMAIL:-}"
SLACK_WEBHOOK="${SLACK_WEBHOOK_URL:-}"

# Helper functions
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

print_error() {
    echo -e "${RED}ERROR:${NC} $1" >&2
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --event)
            EVENT_TYPE="$2"
            shift 2
            ;;
        --site)
            SITE="$2"
            shift 2
            ;;
        --message)
            MESSAGE="$2"
            shift 2
            ;;
        --severity)
            SEVERITY="$2"
            shift 2
            ;;
        --method)
            METHOD="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            grep "^#" "$0" | grep -v "^#!/" | sed 's/^# //' | sed 's/^#//'
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            exit 2
            ;;
    esac
done

# Validate required fields
if [ -z "$EVENT_TYPE" ]; then
    print_error "Event type is required (--event)"
    exit 2
fi

# Build notification content
HOSTNAME=$(hostname)
TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
TIMESTAMP_ISO=$(date -Iseconds)

# Build notification message
if [ -z "$MESSAGE" ]; then
    MESSAGE="Event: $EVENT_TYPE for site: $SITE"
fi

FULL_MESSAGE="[$HOSTNAME] [$SEVERITY] $EVENT_TYPE - $SITE: $MESSAGE"

print_info "Sending notification: $EVENT_TYPE ($SEVERITY)"

################################################################################
# NOTIFICATION: SYSLOG
################################################################################

send_to_syslog() {
    print_info "Logging to syslog..."

    # Map severity to syslog priority
    case "$SEVERITY" in
        info)
            PRIORITY="info"
            ;;
        warning)
            PRIORITY="warning"
            ;;
        error)
            PRIORITY="err"
            ;;
        critical)
            PRIORITY="crit"
            ;;
        *)
            PRIORITY="notice"
            ;;
    esac

    # Send to syslog
    logger -t "$LOG_TAG" -p "user.$PRIORITY" "$FULL_MESSAGE"

    print_success "Logged to syslog"
}

################################################################################
# NOTIFICATION: EMAIL
################################################################################

send_to_email() {
    if [ -z "$EMAIL_TO" ]; then
        print_info "Email notification skipped (NWP_ALERT_EMAIL not set)"
        return 0
    fi

    print_info "Sending email to $EMAIL_TO..."

    # Check if mail command is available
    if ! command -v mail >/dev/null 2>&1; then
        print_error "mail command not found (install mailutils)"
        return 1
    fi

    # Prepare email
    SUBJECT="[NWP Alert] $SEVERITY: $EVENT_TYPE - $SITE"
    EMAIL_BODY=$(cat <<EOF
NWP Notification Alert
======================

Event: $EVENT_TYPE
Site: $SITE
Severity: $SEVERITY
Hostname: $HOSTNAME
Time: $TIMESTAMP

Message:
$MESSAGE

---
This is an automated notification from NWP.
EOF
)

    # Send email
    echo "$EMAIL_BODY" | mail -s "$SUBJECT" "$EMAIL_TO" 2>/dev/null || {
        print_error "Failed to send email"
        return 1
    }

    print_success "Email sent to $EMAIL_TO"
}

################################################################################
# NOTIFICATION: SLACK
################################################################################

send_to_slack() {
    if [ -z "$SLACK_WEBHOOK" ]; then
        print_info "Slack notification skipped (SLACK_WEBHOOK_URL not set)"
        return 0
    fi

    print_info "Sending to Slack..."

    # Check if curl is available
    if ! command -v curl >/dev/null 2>&1; then
        print_error "curl command not found"
        return 1
    fi

    # Map severity to Slack color
    case "$SEVERITY" in
        info)
            COLOR="#36a64f"  # Green
            EMOJI=":information_source:"
            ;;
        warning)
            COLOR="#ffcc00"  # Yellow
            EMOJI=":warning:"
            ;;
        error)
            COLOR="#ff6600"  # Orange
            EMOJI=":x:"
            ;;
        critical)
            COLOR="#ff0000"  # Red
            EMOJI=":rotating_light:"
            ;;
        *)
            COLOR="#999999"  # Gray
            EMOJI=":bell:"
            ;;
    esac

    # Build Slack payload
    SLACK_PAYLOAD=$(cat <<EOF
{
  "attachments": [
    {
      "color": "$COLOR",
      "title": "$EMOJI NWP Alert: $EVENT_TYPE",
      "fields": [
        {
          "title": "Site",
          "value": "$SITE",
          "short": true
        },
        {
          "title": "Severity",
          "value": "$SEVERITY",
          "short": true
        },
        {
          "title": "Hostname",
          "value": "$HOSTNAME",
          "short": true
        },
        {
          "title": "Time",
          "value": "$TIMESTAMP",
          "short": true
        },
        {
          "title": "Message",
          "value": "$MESSAGE",
          "short": false
        }
      ],
      "footer": "NWP Notification System",
      "ts": $(date +%s)
    }
  ]
}
EOF
)

    # Send to Slack
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST \
        -H 'Content-Type: application/json' \
        -d "$SLACK_PAYLOAD" \
        "$SLACK_WEBHOOK")

    if [ "$HTTP_CODE" = "200" ]; then
        print_success "Slack notification sent"
    else
        print_error "Slack notification failed (HTTP $HTTP_CODE)"
        return 1
    fi
}

################################################################################
# SEND NOTIFICATIONS
################################################################################

SUCCESS=true

case "$METHOD" in
    log)
        send_to_syslog || SUCCESS=false
        ;;
    email)
        send_to_email || SUCCESS=false
        ;;
    slack)
        send_to_slack || SUCCESS=false
        ;;
    all)
        send_to_syslog || true
        send_to_email || true
        send_to_slack || true
        ;;
    *)
        print_error "Invalid notification method: $METHOD"
        echo "Valid methods: log, email, slack, all"
        exit 2
        ;;
esac

################################################################################
# SUMMARY
################################################################################

if [ "$SUCCESS" = true ]; then
    if [ "$VERBOSE" = true ]; then
        echo ""
        echo "Notification Summary:"
        echo "  Event: $EVENT_TYPE"
        echo "  Site: $SITE"
        echo "  Severity: $SEVERITY"
        echo "  Method: $METHOD"
        echo "  Status: Sent"
    fi
    exit 0
else
    print_error "Notification failed"
    exit 1
fi
