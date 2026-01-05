#!/bin/bash
set -euo pipefail

################################################################################
# NWP Email Notification Script
#
# Sends email notifications using the mail command.
# Requires EMAIL_RECIPIENTS environment variable to be set.
#
# Usage: ./notify-email.sh --event <event> --site <site> --message <message>
#
# Options:
#   --event <name>          Event name
#   --site <name>           Site name
#   --message <text>        Message to send
#   --help, -h              Show this help
#
# Environment Variables:
#   EMAIL_RECIPIENTS        Comma-separated list of email addresses (required)
#   EMAIL_FROM              From address (optional, defaults to nwp@hostname)
#
# Examples:
#   export EMAIL_RECIPIENTS="admin@example.com,ops@example.com"
#   ./notify-email.sh --event "Deployment" --site mysite --message "Deploy successful"
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
NWP Email Notification Script

Usage: $0 --event <event> --site <site> --message <message>

Options:
  --event <name>          Event name
  --site <name>           Site name
  --message <text>        Message to send
  --help, -h              Show this help

Environment Variables:
  EMAIL_RECIPIENTS        Comma-separated list of email addresses (required)
  EMAIL_FROM              From address (optional)

Examples:
  $0 --event "Deployment" --site mysite --message "Deploy successful"

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

if [[ -z "${EMAIL_RECIPIENTS:-}" ]]; then
    warn "EMAIL_RECIPIENTS not set, skipping email notification"
    exit 0
fi

# Check if mail command is available
if ! command -v mail &> /dev/null; then
    warn "mail command not found, skipping email notification"
    note "Install mailutils package: sudo apt-get install mailutils"
    exit 0
fi

################################################################################
# Build Email
################################################################################

HOSTNAME=$(hostname -f 2>/dev/null || hostname)
FROM_ADDRESS="${EMAIL_FROM:-nwp@$HOSTNAME}"
TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S %Z")

# Email subject
SUBJECT="[NWP] $OPT_EVENT - $OPT_SITE"

# Email body
BODY=$(cat <<EOF
NWP Notification
================

Event:     $OPT_EVENT
Site:      $OPT_SITE
Time:      $TIMESTAMP
Host:      $HOSTNAME

Message:
--------
$OPT_MESSAGE

---
This is an automated notification from NWP (Network WordPress)
EOF
)

################################################################################
# Send Email
################################################################################

task "Sending email to: $EMAIL_RECIPIENTS"

# Convert comma-separated recipients to space-separated for mail command
RECIPIENTS=$(echo "$EMAIL_RECIPIENTS" | tr ',' ' ')

# Send email
if echo "$BODY" | mail -s "$SUBJECT" -a "From: $FROM_ADDRESS" $RECIPIENTS 2>&1; then
    pass "Email sent successfully"
    exit 0
else
    EXIT_CODE=$?
    print_error "Failed to send email (exit code: $EXIT_CODE)"
    exit 1
fi
