#!/bin/bash
################################################################################
# mailpit-client.sh - Bash client for Mailpit API
#
# This library provides functions to interact with Mailpit's REST API for
# email testing and verification.
#
# Usage:
#   source /path/to/mailpit-client.sh
#   mailpit_init "http://localhost:8025"
#   mailpit_wait_for_email "test@example.com" "Subject line" 30
#
# API Reference: https://mailpit.axllent.org/docs/api-v1/
################################################################################

# Default configuration
MAILPIT_URL="${MAILPIT_URL:-http://localhost:8025}"
MAILPIT_TIMEOUT="${MAILPIT_TIMEOUT:-30}"

# Colors for output
_MP_RED='\033[0;31m'
_MP_GREEN='\033[0;32m'
_MP_YELLOW='\033[0;33m'
_MP_BLUE='\033[0;34m'
_MP_NC='\033[0m'

################################################################################
# Initialize Mailpit client
# Arguments:
#   $1 - Mailpit URL (optional, defaults to http://localhost:8025)
################################################################################
mailpit_init() {
    MAILPIT_URL="${1:-$MAILPIT_URL}"

    # Test connection
    if ! mailpit_is_available; then
        echo -e "${_MP_RED}[Mailpit]${_MP_NC} Cannot connect to ${MAILPIT_URL}" >&2
        return 1
    fi

    echo -e "${_MP_GREEN}[Mailpit]${_MP_NC} Connected to ${MAILPIT_URL}"
    return 0
}

################################################################################
# Check if Mailpit is available
# Returns: 0 if available, 1 if not
################################################################################
mailpit_is_available() {
    local response
    response=$(curl -s -o /dev/null -w "%{http_code}" "${MAILPIT_URL}/api/v1/info" 2>/dev/null)
    [ "$response" = "200" ]
}

################################################################################
# Get Mailpit info
# Returns: JSON with Mailpit version and stats
################################################################################
mailpit_info() {
    curl -s "${MAILPIT_URL}/api/v1/info"
}

################################################################################
# Get message count
# Returns: Number of messages in Mailpit
################################################################################
mailpit_count() {
    curl -s "${MAILPIT_URL}/api/v1/messages" | jq -r '.messages_count // 0'
}

################################################################################
# List all messages
# Arguments:
#   $1 - Limit (optional, default 50)
# Returns: JSON array of message summaries
################################################################################
mailpit_list() {
    local limit="${1:-50}"
    curl -s "${MAILPIT_URL}/api/v1/messages?limit=${limit}"
}

################################################################################
# Search for messages
# Arguments:
#   $1 - Search query (e.g., "subject:Test" or "to:user@example.com")
# Returns: JSON search results
################################################################################
mailpit_search() {
    local query="$1"
    local encoded_query
    encoded_query=$(echo -n "$query" | jq -sRr @uri)
    curl -s "${MAILPIT_URL}/api/v1/search?query=${encoded_query}"
}

################################################################################
# Get a specific message by ID
# Arguments:
#   $1 - Message ID
# Returns: Full message JSON
################################################################################
mailpit_get_message() {
    local id="$1"
    curl -s "${MAILPIT_URL}/api/v1/message/${id}"
}

################################################################################
# Get message HTML content
# Arguments:
#   $1 - Message ID
# Returns: HTML content
################################################################################
mailpit_get_html() {
    local id="$1"
    curl -s "${MAILPIT_URL}/view/${id}.html"
}

################################################################################
# Get message plain text content
# Arguments:
#   $1 - Message ID
# Returns: Plain text content
################################################################################
mailpit_get_text() {
    local id="$1"
    curl -s "${MAILPIT_URL}/view/${id}.txt"
}

################################################################################
# Get message headers
# Arguments:
#   $1 - Message ID
# Returns: JSON headers
################################################################################
mailpit_get_headers() {
    local id="$1"
    mailpit_get_message "$id" | jq '.Headers'
}

################################################################################
# Delete a specific message
# Arguments:
#   $1 - Message ID
################################################################################
mailpit_delete_message() {
    local id="$1"
    curl -s -X DELETE "${MAILPIT_URL}/api/v1/messages" \
        -H "Content-Type: application/json" \
        -d "{\"IDs\": [\"${id}\"]}"
}

################################################################################
# Delete all messages
################################################################################
mailpit_delete_all() {
    curl -s -X DELETE "${MAILPIT_URL}/api/v1/messages"
    echo -e "${_MP_GREEN}[Mailpit]${_MP_NC} All messages deleted"
}

################################################################################
# Mark message timestamp for later filtering
# This allows you to only check emails received after this point
# Returns: Timestamp in RFC3339 format
################################################################################
mailpit_mark_timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

################################################################################
# Wait for an email matching criteria
# Arguments:
#   $1 - Recipient email (or "" to match any)
#   $2 - Subject contains (or "" to match any)
#   $3 - Timeout in seconds (optional, default 30)
#   $4 - After timestamp (optional, RFC3339 format)
# Returns: Message ID if found, empty if not
################################################################################
mailpit_wait_for_email() {
    local recipient="${1:-}"
    local subject="${2:-}"
    local timeout="${3:-$MAILPIT_TIMEOUT}"
    local after="${4:-}"

    local query=""
    [ -n "$recipient" ] && query="to:${recipient}"
    [ -n "$subject" ] && query="${query:+$query }subject:${subject}"

    local elapsed=0
    local interval=2

    echo -e "${_MP_BLUE}[Mailpit]${_MP_NC} Waiting for email (timeout: ${timeout}s)..."
    [ -n "$recipient" ] && echo "  To: $recipient"
    [ -n "$subject" ] && echo "  Subject contains: $subject"

    while [ $elapsed -lt $timeout ]; do
        local result
        if [ -n "$query" ]; then
            result=$(mailpit_search "$query")
        else
            result=$(mailpit_list 1)
        fi

        # Check if we got any messages
        local count
        count=$(echo "$result" | jq -r '.messages_count // .total // 0')

        if [ "$count" -gt 0 ]; then
            local message_id
            message_id=$(echo "$result" | jq -r '.messages[0].ID // empty')

            # If we have an after timestamp, check if message is newer
            if [ -n "$after" ] && [ -n "$message_id" ]; then
                local msg_date
                msg_date=$(mailpit_get_message "$message_id" | jq -r '.Created')
                if [[ "$msg_date" < "$after" ]]; then
                    # Message is older than our timestamp, keep waiting
                    sleep $interval
                    elapsed=$((elapsed + interval))
                    continue
                fi
            fi

            if [ -n "$message_id" ]; then
                echo -e "${_MP_GREEN}[Mailpit]${_MP_NC} Email found! ID: ${message_id}"
                echo "$message_id"
                return 0
            fi
        fi

        sleep $interval
        elapsed=$((elapsed + interval))
        echo -ne "\r  Waiting... ${elapsed}s / ${timeout}s"
    done

    echo ""
    echo -e "${_MP_RED}[Mailpit]${_MP_NC} Timeout waiting for email" >&2
    return 1
}

################################################################################
# Assert email was received
# Arguments:
#   $1 - Recipient email
#   $2 - Expected subject
#   $3 - Expected body contains (optional)
# Returns: 0 if found and matches, 1 if not
################################################################################
mailpit_assert_email() {
    local recipient="$1"
    local expected_subject="$2"
    local expected_body="${3:-}"

    local message_id
    message_id=$(mailpit_wait_for_email "$recipient" "$expected_subject" 10)

    if [ -z "$message_id" ]; then
        echo -e "${_MP_RED}[Assert]${_MP_NC} Email not found" >&2
        return 1
    fi

    # Get full message
    local message
    message=$(mailpit_get_message "$message_id")

    # Check subject
    local actual_subject
    actual_subject=$(echo "$message" | jq -r '.Subject')
    if [[ "$actual_subject" != *"$expected_subject"* ]]; then
        echo -e "${_MP_RED}[Assert]${_MP_NC} Subject mismatch" >&2
        echo "  Expected: $expected_subject"
        echo "  Actual: $actual_subject"
        return 1
    fi
    echo -e "${_MP_GREEN}[Assert]${_MP_NC} Subject matches: $actual_subject"

    # Check body if specified
    if [ -n "$expected_body" ]; then
        local body
        body=$(mailpit_get_text "$message_id")
        if [[ "$body" != *"$expected_body"* ]]; then
            echo -e "${_MP_RED}[Assert]${_MP_NC} Body does not contain expected text" >&2
            echo "  Expected to contain: $expected_body"
            return 1
        fi
        echo -e "${_MP_GREEN}[Assert]${_MP_NC} Body contains expected text"
    fi

    return 0
}

################################################################################
# Check email authentication headers (DKIM, SPF)
# Arguments:
#   $1 - Message ID
# Returns: Authentication results
################################################################################
mailpit_check_auth() {
    local id="$1"
    local headers
    headers=$(mailpit_get_headers "$id")

    echo "Email Authentication Headers:"
    echo "=============================="

    # DKIM
    local dkim
    dkim=$(echo "$headers" | jq -r '.["Dkim-Signature"] // .["DKIM-Signature"] // "Not present"')
    echo -n "DKIM-Signature: "
    if [ "$dkim" != "Not present" ]; then
        echo -e "${_MP_GREEN}Present${_MP_NC}"
    else
        echo -e "${_MP_YELLOW}Not present${_MP_NC}"
    fi

    # Authentication-Results (if relayed through a server that checks)
    local auth_results
    auth_results=$(echo "$headers" | jq -r '.["Authentication-Results"] // "Not present"')
    if [ "$auth_results" != "Not present" ]; then
        echo "Authentication-Results: $auth_results"
    fi

    # Return-Path
    local return_path
    return_path=$(echo "$headers" | jq -r '.["Return-Path"] // "Not set"')
    echo "Return-Path: $return_path"

    # Message-ID
    local msg_id
    msg_id=$(echo "$headers" | jq -r '.["Message-Id"] // .["Message-ID"] // "Not set"')
    echo "Message-ID: $msg_id"
}

################################################################################
# Save email artifacts for debugging
# Arguments:
#   $1 - Message ID
#   $2 - Output directory
################################################################################
mailpit_save_artifacts() {
    local id="$1"
    local output_dir="${2:-.}"

    mkdir -p "$output_dir"

    local message
    message=$(mailpit_get_message "$id")
    local subject
    subject=$(echo "$message" | jq -r '.Subject' | tr '[:space:]' '_' | tr -cd '[:alnum:]_' | head -c 50)
    local prefix="${output_dir}/${subject}_${id:0:8}"

    # Save full message JSON
    echo "$message" | jq '.' > "${prefix}_message.json"

    # Save HTML
    mailpit_get_html "$id" > "${prefix}.html" 2>/dev/null || true

    # Save text
    mailpit_get_text "$id" > "${prefix}.txt" 2>/dev/null || true

    # Save headers
    mailpit_get_headers "$id" | jq '.' > "${prefix}_headers.json"

    echo -e "${_MP_GREEN}[Mailpit]${_MP_NC} Artifacts saved to ${prefix}_*"
}

################################################################################
# Print usage
################################################################################
mailpit_help() {
    cat << 'EOF'
Mailpit Client Library - Functions for email testing

Initialization:
  mailpit_init [url]              Initialize client (default: http://localhost:8025)
  mailpit_is_available            Check if Mailpit is running

Message Operations:
  mailpit_list [limit]            List messages (default limit: 50)
  mailpit_search "query"          Search messages (e.g., "to:user@example.com")
  mailpit_get_message <id>        Get full message by ID
  mailpit_get_html <id>           Get HTML content
  mailpit_get_text <id>           Get plain text content
  mailpit_get_headers <id>        Get message headers
  mailpit_delete_message <id>     Delete specific message
  mailpit_delete_all              Delete all messages

Testing:
  mailpit_mark_timestamp          Get current timestamp for filtering
  mailpit_wait_for_email <to> <subject> [timeout] [after]
                                  Wait for email matching criteria
  mailpit_assert_email <to> <subject> [body]
                                  Assert email exists with content
  mailpit_check_auth <id>         Check authentication headers
  mailpit_save_artifacts <id> [dir]  Save email for debugging

Examples:
  # Wait for email and verify
  timestamp=$(mailpit_mark_timestamp)
  send_email "test@example.com" "Hello"
  mailpit_wait_for_email "test@example.com" "Hello" 30 "$timestamp"

  # Assert and save on failure
  if ! mailpit_assert_email "user@test.com" "Welcome"; then
      id=$(mailpit_search "to:user@test.com" | jq -r '.messages[0].ID')
      mailpit_save_artifacts "$id" "./failed-tests"
  fi
EOF
}
