#!/bin/bash

################################################################################
# nwp-audit.sh - NWP Deployment Audit Logging Script
################################################################################
#
# Logs deployment events in both JSON and human-readable text formats.
# This script creates structured audit logs for all deployment activities
# including deploys, swaps, rollbacks, backups, and other operations.
#
# This script runs ON the Linode server.
#
# Usage:
#   ./nwp-audit.sh [OPTIONS]
#
# Options:
#   --event TYPE         Event type (deploy, swap, rollback, backup, etc.)
#   --site NAME          Site name or directory
#   --user USERNAME      User performing the action
#   --commit HASH        Git commit hash (optional)
#   --branch NAME        Git branch name (optional)
#   --message TEXT       Additional message or details
#   --status STATUS      Event status (success, failure, pending)
#   --json-only          Write JSON log only (skip text log)
#   --text-only          Write text log only (skip JSON log)
#   -v, --verbose        Verbose output
#   -h, --help           Show this help message
#
# Log Files:
#   /var/log/nwp/deployments.jsonl - JSON Lines format for parsing
#   /var/log/nwp/deployments.log   - Human-readable text format
#
# Exit Codes:
#   0 - Log entry created successfully
#   1 - Error creating log entry
#   2 - Invalid arguments
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
EVENT_TYPE=""
SITE=""
USER=""
COMMIT=""
BRANCH=""
MESSAGE=""
STATUS="success"
JSON_ONLY=false
TEXT_ONLY=false
VERBOSE=false

# Log file paths
LOG_DIR="/var/log/nwp"
JSON_LOG="$LOG_DIR/deployments.jsonl"
TEXT_LOG="$LOG_DIR/deployments.log"

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
        --user)
            USER="$2"
            shift 2
            ;;
        --commit)
            COMMIT="$2"
            shift 2
            ;;
        --branch)
            BRANCH="$2"
            shift 2
            ;;
        --message)
            MESSAGE="$2"
            shift 2
            ;;
        --status)
            STATUS="$2"
            shift 2
            ;;
        --json-only)
            JSON_ONLY=true
            shift
            ;;
        --text-only)
            TEXT_ONLY=true
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

# Set defaults for optional fields
if [ -z "$USER" ]; then
    USER=$(whoami)
fi

if [ -z "$SITE" ]; then
    SITE="unknown"
fi

# Ensure log directory exists
if [ ! -d "$LOG_DIR" ]; then
    print_info "Creating log directory: $LOG_DIR"
    sudo mkdir -p "$LOG_DIR"
    sudo chmod 755 "$LOG_DIR"
fi

# Get timestamp in ISO 8601 format
TIMESTAMP=$(date -Iseconds)
TIMESTAMP_HUMAN=$(date "+%Y-%m-%d %H:%M:%S")

# Get hostname
HOSTNAME=$(hostname)

# Get IP address
IP_ADDRESS=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "unknown")

################################################################################
# JSON LOG ENTRY
################################################################################

if [ "$TEXT_ONLY" != true ]; then
    print_info "Writing JSON log entry..."

    # Build JSON object
    JSON_ENTRY=$(cat <<EOF
{
  "timestamp": "$TIMESTAMP",
  "hostname": "$HOSTNAME",
  "ip": "$IP_ADDRESS",
  "event": "$EVENT_TYPE",
  "site": "$SITE",
  "user": "$USER",
  "status": "$STATUS"
EOF
)

    # Add optional fields if present
    if [ -n "$COMMIT" ]; then
        JSON_ENTRY="$JSON_ENTRY,
  \"commit\": \"$COMMIT\""
    fi

    if [ -n "$BRANCH" ]; then
        JSON_ENTRY="$JSON_ENTRY,
  \"branch\": \"$BRANCH\""
    fi

    if [ -n "$MESSAGE" ]; then
        # Escape quotes in message for JSON
        MESSAGE_ESCAPED=$(echo "$MESSAGE" | sed 's/"/\\"/g')
        JSON_ENTRY="$JSON_ENTRY,
  \"message\": \"$MESSAGE_ESCAPED\""
    fi

    # Close JSON object
    JSON_ENTRY="$JSON_ENTRY
}"

    # Append to JSON Lines file
    echo "$JSON_ENTRY" | sudo tee -a "$JSON_LOG" > /dev/null
    print_success "JSON log entry written to $JSON_LOG"
fi

################################################################################
# TEXT LOG ENTRY
################################################################################

if [ "$JSON_ONLY" != true ]; then
    print_info "Writing text log entry..."

    # Build human-readable log entry
    TEXT_ENTRY="[$TIMESTAMP_HUMAN] $EVENT_TYPE"

    # Add site if not unknown
    if [ "$SITE" != "unknown" ]; then
        TEXT_ENTRY="$TEXT_ENTRY - $SITE"
    fi

    # Add status if not success
    if [ "$STATUS" != "success" ]; then
        TEXT_ENTRY="$TEXT_ENTRY [$STATUS]"
    fi

    # Add user
    TEXT_ENTRY="$TEXT_ENTRY (user: $USER)"

    # Add commit/branch if present
    if [ -n "$COMMIT" ] && [ -n "$BRANCH" ]; then
        TEXT_ENTRY="$TEXT_ENTRY [${BRANCH}@${COMMIT:0:7}]"
    elif [ -n "$COMMIT" ]; then
        TEXT_ENTRY="$TEXT_ENTRY [commit: ${COMMIT:0:7}]"
    elif [ -n "$BRANCH" ]; then
        TEXT_ENTRY="$TEXT_ENTRY [branch: $BRANCH]"
    fi

    # Add message if present
    if [ -n "$MESSAGE" ]; then
        TEXT_ENTRY="$TEXT_ENTRY - $MESSAGE"
    fi

    # Append to text log file
    echo "$TEXT_ENTRY" | sudo tee -a "$TEXT_LOG" > /dev/null
    print_success "Text log entry written to $TEXT_LOG"
fi

################################################################################
# OUTPUT SUMMARY
################################################################################

if [ "$VERBOSE" = true ]; then
    echo ""
    echo "Audit Log Entry:"
    echo "  Event: $EVENT_TYPE"
    echo "  Site: $SITE"
    echo "  User: $USER"
    echo "  Status: $STATUS"
    [ -n "$COMMIT" ] && echo "  Commit: $COMMIT"
    [ -n "$BRANCH" ] && echo "  Branch: $BRANCH"
    [ -n "$MESSAGE" ] && echo "  Message: $MESSAGE"
    echo "  Time: $TIMESTAMP"
fi

exit 0
