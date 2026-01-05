#!/bin/bash
set -euo pipefail

################################################################################
# NWP Notification Router
#
# Main notification router that sends alerts to configured channels.
# Supports Slack, email, and generic webhooks.
#
# Usage: ./notify.sh --event <event> --site <site> [options]
#
# Options:
#   --event <name>          Event type (deploy_success, deploy_failed, backup_success, etc.)
#   --site <name>           Site name
#   --url <url>             Optional URL related to the event
#   --message <text>        Optional custom message
#   --channels <list>       Comma-separated channels (slack,email,webhook) - defaults to all
#   --help, -h              Show this help
#
# Events and their mappings:
#   deploy_success          - Rocket emoji, green/good color
#   deploy_failed           - X emoji, red/danger color
#   backup_success          - Floppy disk emoji, green/good color
#   backup_failed           - X emoji, red/danger color
#   sync_success            - Sync emoji, green/good color
#   sync_failed             - X emoji, red/danger color
#   security_alert          - Warning emoji, yellow/warning color
#   update_available        - Bell emoji, blue/info color
#
# Examples:
#   ./notify.sh --event deploy_success --site mysite --url https://mysite.com
#   ./notify.sh --event backup_failed --site mysite --message "Disk full"
#   ./notify.sh --event security_alert --site mysite --channels slack,email
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
OPT_URL=""
OPT_MESSAGE=""
OPT_CHANNELS="slack,email,webhook"

################################################################################
# Event to Emoji/Color Mapping
################################################################################

# Get emoji for event type
get_emoji() {
    local event=$1

    case "$event" in
        deploy_success)
            echo ":rocket:"
            ;;
        deploy_failed)
            echo ":x:"
            ;;
        backup_success)
            echo ":floppy_disk:"
            ;;
        backup_failed)
            echo ":x:"
            ;;
        sync_success)
            echo ":arrows_counterclockwise:"
            ;;
        sync_failed)
            echo ":x:"
            ;;
        security_alert)
            echo ":warning:"
            ;;
        update_available)
            echo ":bell:"
            ;;
        *)
            echo ":information_source:"
            ;;
    esac
}

# Get color for event type (Slack colors)
get_color() {
    local event=$1

    case "$event" in
        deploy_success|backup_success|sync_success)
            echo "good"
            ;;
        deploy_failed|backup_failed|sync_failed)
            echo "danger"
            ;;
        security_alert)
            echo "warning"
            ;;
        update_available)
            echo "#439FE0"
            ;;
        *)
            echo "#808080"
            ;;
    esac
}

# Get human-readable event name
get_event_name() {
    local event=$1

    case "$event" in
        deploy_success)
            echo "Deployment Successful"
            ;;
        deploy_failed)
            echo "Deployment Failed"
            ;;
        backup_success)
            echo "Backup Successful"
            ;;
        backup_failed)
            echo "Backup Failed"
            ;;
        sync_success)
            echo "Sync Successful"
            ;;
        sync_failed)
            echo "Sync Failed"
            ;;
        security_alert)
            echo "Security Alert"
            ;;
        update_available)
            echo "Update Available"
            ;;
        *)
            echo "$event"
            ;;
    esac
}

################################################################################
# Parse Arguments
################################################################################

show_help() {
    cat << EOF
NWP Notification Router

Usage: $0 --event <event> --site <site> [options]

Options:
  --event <name>          Event type (deploy_success, deploy_failed, etc.)
  --site <name>           Site name
  --url <url>             Optional URL related to the event
  --message <text>        Optional custom message
  --channels <list>       Comma-separated channels (slack,email,webhook)
  --help, -h              Show this help

Examples:
  $0 --event deploy_success --site mysite
  $0 --event backup_failed --site mysite --message "Disk full"
  $0 --event security_alert --site mysite --channels slack

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
        --url)
            OPT_URL="$2"
            shift 2
            ;;
        --message)
            OPT_MESSAGE="$2"
            shift 2
            ;;
        --channels)
            OPT_CHANNELS="$2"
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
    show_help
    exit 1
fi

if [[ -z "$OPT_SITE" ]]; then
    print_error "Site name is required (use --site)"
    show_help
    exit 1
fi

################################################################################
# Build Notification Data
################################################################################

EMOJI=$(get_emoji "$OPT_EVENT")
COLOR=$(get_color "$OPT_EVENT")
EVENT_NAME=$(get_event_name "$OPT_EVENT")

# Build the message
if [[ -z "$OPT_MESSAGE" ]]; then
    MESSAGE="$EVENT_NAME for site: $OPT_SITE"
else
    MESSAGE="$OPT_MESSAGE"
fi

# Add URL if provided
if [[ -n "$OPT_URL" ]]; then
    MESSAGE="$MESSAGE - URL: $OPT_URL"
fi

################################################################################
# Route to Channels
################################################################################

info "Sending notifications for event: $OPT_EVENT"

# Convert channels to array
IFS=',' read -ra CHANNELS <<< "$OPT_CHANNELS"

# Track success/failure
SUCCESS_COUNT=0
FAIL_COUNT=0

for channel in "${CHANNELS[@]}"; do
    channel=$(echo "$channel" | xargs) # trim whitespace

    case "$channel" in
        slack)
            info "Routing to Slack..."
            if "$SCRIPT_DIR/notify-slack.sh" \
                --message "$EMOJI $MESSAGE" \
                --color "$COLOR" \
                --site "$OPT_SITE" \
                --event "$EVENT_NAME"; then
                pass "Slack notification sent"
                ((SUCCESS_COUNT++))
            else
                fail "Slack notification failed"
                ((FAIL_COUNT++))
            fi
            ;;
        email)
            info "Routing to Email..."
            if "$SCRIPT_DIR/notify-email.sh" \
                --event "$EVENT_NAME" \
                --site "$OPT_SITE" \
                --message "$MESSAGE"; then
                pass "Email notification sent"
                ((SUCCESS_COUNT++))
            else
                fail "Email notification failed"
                ((FAIL_COUNT++))
            fi
            ;;
        webhook)
            info "Routing to Webhook..."
            if "$SCRIPT_DIR/notify-webhook.sh" \
                --event "$OPT_EVENT" \
                --site "$OPT_SITE" \
                --message "$MESSAGE"; then
                pass "Webhook notification sent"
                ((SUCCESS_COUNT++))
            else
                fail "Webhook notification failed"
                ((FAIL_COUNT++))
            fi
            ;;
        *)
            warn "Unknown channel: $channel"
            ((FAIL_COUNT++))
            ;;
    esac
done

################################################################################
# Summary
################################################################################

echo ""
info "Notification Summary: $SUCCESS_COUNT succeeded, $FAIL_COUNT failed"

if [[ $FAIL_COUNT -gt 0 ]]; then
    exit 1
fi

exit 0
