#!/bin/bash
set -euo pipefail

################################################################################
# NWP Webhook Notification Script
#
# Sends JSON notifications to a generic webhook endpoint.
# Requires WEBHOOK_URL environment variable to be set.
#
# Usage: ./notify-webhook.sh --event <event> --site <site> --message <message>
#
# Options:
#   --event <name>          Event name
#   --site <name>           Site name
#   --message <text>        Message to send
#   --help, -h              Show this help
#
# Environment Variables:
#   WEBHOOK_URL             Webhook URL to POST to (required)
#   WEBHOOK_AUTH_HEADER     Optional Authorization header value
#
# JSON Payload Format:
#   {
#     "event": "event_name",
#     "site": "site_name",
#     "message": "message text",
#     "timestamp": "2026-01-05T12:34:56Z",
#     "hostname": "server.example.com"
#   }
#
# Examples:
#   export WEBHOOK_URL="https://api.example.com/webhooks/nwp"
#   ./notify-webhook.sh --event deploy_success --site mysite --message "Deployed"
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
OPT_EVENT=""
OPT_SITE=""
OPT_MESSAGE=""

################################################################################
# Parse Arguments
################################################################################

show_help() {
    cat << EOF
NWP Webhook Notification Script

Usage: $0 --event <event> --site <site> --message <message>

Options:
  --event <name>          Event name
  --site <name>           Site name
  --message <text>        Message to send
  --help, -h              Show this help

Environment Variables:
  WEBHOOK_URL             Webhook URL to POST to (required)
  WEBHOOK_AUTH_HEADER     Optional Authorization header value

Examples:
  $0 --event deploy_success --site mysite --message "Deployed"

EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --event)
            OPT_EVENT="$2"
            shift 2
            ;;
        --site)
            OPT_SITE="$2"
            shift 2
            ;;
        --message)
            OPT_MESSAGE="$2"
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

if [[ -z "$OPT_EVENT" ]]; then
    print_error "Event is required (use --event)"
    exit 1
fi

if [[ -z "$OPT_SITE" ]]; then
    print_error "Site name is required (use --site)"
    exit 1
fi

if [[ -z "$OPT_MESSAGE" ]]; then
    print_error "Message is required (use --message)"
    exit 1
fi

if [[ -z "${WEBHOOK_URL:-}" ]]; then
    warn "WEBHOOK_URL not set, skipping webhook notification"
    exit 0
fi

################################################################################
# Build JSON Payload
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

EVENT_ESCAPED=$(escape_json "$OPT_EVENT")
SITE_ESCAPED=$(escape_json "$OPT_SITE")
MESSAGE_ESCAPED=$(escape_json "$OPT_MESSAGE")
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
HOSTNAME=$(hostname -f 2>/dev/null || hostname)
HOSTNAME_ESCAPED=$(escape_json "$HOSTNAME")

# Build JSON payload
PAYLOAD=$(cat <<EOF
{
  "event": "$EVENT_ESCAPED",
  "site": "$SITE_ESCAPED",
  "message": "$MESSAGE_ESCAPED",
  "timestamp": "$TIMESTAMP",
  "hostname": "$HOSTNAME_ESCAPED"
}
EOF
)

################################################################################
# Send to Webhook
################################################################################

task "Sending to webhook: $WEBHOOK_URL"

# Build curl command
CURL_CMD=(curl -s -w "\n%{http_code}" -X POST)
CURL_CMD+=(-H "Content-Type: application/json")

# Add auth header if provided
if [[ -n "${WEBHOOK_AUTH_HEADER:-}" ]]; then
    CURL_CMD+=(-H "Authorization: $WEBHOOK_AUTH_HEADER")
fi

CURL_CMD+=(-d "$PAYLOAD")
CURL_CMD+=("$WEBHOOK_URL")

# Execute curl and capture response
HTTP_RESPONSE=$("${CURL_CMD[@]}" 2>&1) || {
    print_error "Failed to send webhook notification: $HTTP_RESPONSE"
    exit 1
}

# Extract HTTP status code (last line)
HTTP_CODE=$(echo "$HTTP_RESPONSE" | tail -n1)

# Check if successful (2xx status code)
if [[ "$HTTP_CODE" =~ ^2[0-9]{2}$ ]]; then
    pass "Webhook notification sent successfully (HTTP $HTTP_CODE)"
    exit 0
else
    print_error "Webhook returned HTTP $HTTP_CODE"
    # Show response body (all lines except last)
    RESPONSE_BODY=$(echo "$HTTP_RESPONSE" | head -n -1)
    if [[ -n "$RESPONSE_BODY" ]]; then
        note "Response: $RESPONSE_BODY"
    fi
    exit 1
fi
