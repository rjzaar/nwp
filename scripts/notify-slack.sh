#!/bin/bash
set -euo pipefail

################################################################################
# NWP Slack Notification Script
#
# Sends notifications to Slack via webhook.
# Requires SLACK_WEBHOOK_URL environment variable to be set.
#
# Usage: ./notify-slack.sh --message <message> --color <color> [options]
#
# Options:
#   --message <text>        Message to send
#   --color <color>         Slack color (good, warning, danger, or hex)
#   --site <name>           Optional site name for context
#   --event <name>          Optional event name for title
#   --help, -h              Show this help
#
# Environment Variables:
#   SLACK_WEBHOOK_URL       Slack webhook URL (required)
#
# Examples:
#   export SLACK_WEBHOOK_URL="https://hooks.slack.com/services/YOUR/WEBHOOK/URL"
#   ./notify-slack.sh --message "Deploy successful" --color "good"
#   ./notify-slack.sh --message ":rocket: Site deployed" --color "good" --site mysite
################################################################################

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

################################################################################
# Source Required Libraries
################################################################################

source "$SCRIPT_DIR/../lib/ui.sh"

################################################################################
# Configuration
################################################################################

# Default options
OPT_MESSAGE=""
OPT_COLOR="good"
OPT_SITE=""
OPT_EVENT=""

################################################################################
# Parse Arguments
################################################################################

show_help() {
    cat << EOF
NWP Slack Notification Script

Usage: $0 --message <message> --color <color> [options]

Options:
  --message <text>        Message to send
  --color <color>         Slack color (good, warning, danger, or hex)
  --site <name>           Optional site name for context
  --event <name>          Optional event name for title
  --help, -h              Show this help

Environment Variables:
  SLACK_WEBHOOK_URL       Slack webhook URL (required)

Examples:
  $0 --message "Deploy successful" --color "good"
  $0 --message ":rocket: Deployed" --color "good" --site mysite --event "Deployment"

EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --message)
            OPT_MESSAGE="$2"
            shift 2
            ;;
        --color)
            OPT_COLOR="$2"
            shift 2
            ;;
        --site)
            OPT_SITE="$2"
            shift 2
            ;;
        --event)
            OPT_EVENT="$2"
            shift 2
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

################################################################################
# Validation
################################################################################

if [[ -z "$OPT_MESSAGE" ]]; then
    print_error "Message is required (use --message)"
    exit 1
fi

if [[ -z "${SLACK_WEBHOOK_URL:-}" ]]; then
    warn "SLACK_WEBHOOK_URL not set, skipping Slack notification"
    exit 0
fi

################################################################################
# Build Slack Payload
################################################################################

# Escape JSON strings
escape_json() {
    local str="$1"
    # Escape backslashes, double quotes, and newlines
    str="${str//\\/\\\\}"
    str="${str//\"/\\\"}"
    str="${str//$'\n'/\\n}"
    echo "$str"
}

MESSAGE_ESCAPED=$(escape_json "$OPT_MESSAGE")
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Build the attachment
ATTACHMENT="{"
ATTACHMENT+="\"color\": \"$OPT_COLOR\","
ATTACHMENT+="\"text\": \"$MESSAGE_ESCAPED\","
ATTACHMENT+="\"footer\": \"NWP Notification\","
ATTACHMENT+="\"ts\": $(date +%s)"

# Add fields if site or event provided
if [[ -n "$OPT_SITE" ]] || [[ -n "$OPT_EVENT" ]]; then
    ATTACHMENT+=",\"fields\": ["

    if [[ -n "$OPT_SITE" ]]; then
        SITE_ESCAPED=$(escape_json "$OPT_SITE")
        ATTACHMENT+="{\"title\": \"Site\", \"value\": \"$SITE_ESCAPED\", \"short\": true}"
    fi

    if [[ -n "$OPT_EVENT" ]]; then
        EVENT_ESCAPED=$(escape_json "$OPT_EVENT")
        if [[ -n "$OPT_SITE" ]]; then
            ATTACHMENT+=","
        fi
        ATTACHMENT+="{\"title\": \"Event\", \"value\": \"$EVENT_ESCAPED\", \"short\": true}"
    fi

    ATTACHMENT+="]"
fi

ATTACHMENT+="}"

# Build the full payload
PAYLOAD="{\"attachments\": [$ATTACHMENT]}"

################################################################################
# Send to Slack
################################################################################

task "Sending to Slack webhook..."

HTTP_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
    -H 'Content-Type: application/json' \
    -d "$PAYLOAD" \
    "$SLACK_WEBHOOK_URL" 2>&1) || {
    print_error "Failed to send Slack notification: $HTTP_RESPONSE"
    exit 1
}

# Extract HTTP status code (last line)
HTTP_CODE=$(echo "$HTTP_RESPONSE" | tail -n1)

# Check if successful (2xx status code)
if [[ "$HTTP_CODE" =~ ^2[0-9]{2}$ ]]; then
    pass "Slack notification sent successfully"
    exit 0
else
    print_error "Slack webhook returned HTTP $HTTP_CODE"
    exit 1
fi
