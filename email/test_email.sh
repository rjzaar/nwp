#!/bin/bash

################################################################################
# test_email.sh - Test and monitor NWP email infrastructure
#
# This script implements E11 from EMAIL_POSTFIX_PROPOSAL.md:
#   E11: Email Health Monitoring
#
# Usage:
#   ./test_email.sh                           # Run all tests
#   ./test_email.sh --send <email>            # Send test email
#   ./test_email.sh --send-verify <email>     # Send and verify delivery via Mailpit
#   ./test_email.sh --check-dns               # Verify DNS records
#   ./test_email.sh --check-services          # Check services running
#   ./test_email.sh --check-logs              # Check for errors in logs
#   ./test_email.sh --check-mailpit           # Check Mailpit status and messages
#   ./test_email.sh --mail-tester             # Get mail-tester.com instructions
#   ./test_email.sh --verify-headers <id>     # Verify email headers in Mailpit
#   ./test_email.sh --clear-mailpit           # Clear all Mailpit messages
#   ./test_email.sh --help                    # Show this help
#
# Prerequisites:
#   - Run setup_email.sh first to configure email infrastructure
#
################################################################################

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NWP_DIR="$(dirname "$SCRIPT_DIR")"

# Configuration
DOMAIN="${DOMAIN:-nwpcode.org}"
MAIL_HOSTNAME="${MAIL_HOSTNAME:-git.${DOMAIN}}"
MAIL_IP="${MAIL_IP:-97.107.137.88}"
DKIM_SELECTOR="${DKIM_SELECTOR:-default}"

# Mailpit configuration
MAILPIT_URL="${MAILPIT_URL:-http://localhost:8025}"
MAILPIT_AVAILABLE=false

# Source Mailpit client library if available
if [ -f "${SCRIPT_DIR}/lib/mailpit-client.sh" ]; then
    source "${SCRIPT_DIR}/lib/mailpit-client.sh"
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

################################################################################
# Helper Functions
################################################################################

print_header() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
}

print_ok() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

print_info() {
    echo -e "${BLUE}[i]${NC} $1"
}

show_help() {
    sed -n '3,20p' "$0" | sed 's/^# //' | sed 's/^#//'
    exit 0
}

################################################################################
# DNS Verification
################################################################################

check_dns() {
    print_header "DNS Record Verification"

    local issues=0

    # Check A record
    echo -n "A Record (${MAIL_HOSTNAME}): "
    local a_record=$(dig A "${MAIL_HOSTNAME}" +short 2>/dev/null)
    if [ -n "$a_record" ]; then
        echo -e "${GREEN}${a_record}${NC}"
    else
        echo -e "${RED}MISSING${NC}"
        issues=$((issues + 1))
    fi

    # Check MX record
    echo -n "MX Record (${DOMAIN}): "
    local mx_record=$(dig MX "${DOMAIN}" +short 2>/dev/null)
    if [ -n "$mx_record" ]; then
        echo -e "${GREEN}${mx_record}${NC}"
    else
        echo -e "${RED}MISSING${NC}"
        issues=$((issues + 1))
    fi

    # Check SPF record
    echo -n "SPF Record: "
    local spf=$(dig TXT "${DOMAIN}" +short 2>/dev/null | grep -i "v=spf1" | tr -d '"')
    if [ -n "$spf" ]; then
        echo -e "${GREEN}${spf}${NC}"
        # Validate SPF includes our IP
        if echo "$spf" | grep -q "${MAIL_IP}"; then
            print_ok "  IP ${MAIL_IP} included"
        else
            print_warning "  IP ${MAIL_IP} not explicitly included"
        fi
    else
        echo -e "${RED}MISSING${NC}"
        issues=$((issues + 1))
    fi

    # Check DKIM record
    echo -n "DKIM Record (${DKIM_SELECTOR}._domainkey): "
    local dkim=$(dig TXT "${DKIM_SELECTOR}._domainkey.${DOMAIN}" +short 2>/dev/null | tr -d '"')
    if [ -n "$dkim" ]; then
        echo -e "${GREEN}Present${NC}"
        if echo "$dkim" | grep -q "p="; then
            print_ok "  Public key found"
        else
            print_warning "  Public key might be missing"
        fi
    else
        echo -e "${RED}MISSING${NC}"
        issues=$((issues + 1))
    fi

    # Check DMARC record
    echo -n "DMARC Record: "
    local dmarc=$(dig TXT "_dmarc.${DOMAIN}" +short 2>/dev/null | tr -d '"')
    if [ -n "$dmarc" ]; then
        echo -e "${GREEN}${dmarc}${NC}"
    else
        echo -e "${RED}MISSING${NC}"
        issues=$((issues + 1))
    fi

    # Check PTR record (reverse DNS)
    echo -n "PTR Record (${MAIL_IP}): "
    local ptr=$(dig -x "${MAIL_IP}" +short 2>/dev/null | sed 's/\.$//')
    if [ "$ptr" = "${MAIL_HOSTNAME}" ]; then
        echo -e "${GREEN}${ptr}${NC} (matches hostname)"
    elif [ -n "$ptr" ]; then
        echo -e "${YELLOW}${ptr}${NC} (expected: ${MAIL_HOSTNAME})"
        issues=$((issues + 1))
    else
        echo -e "${RED}MISSING${NC}"
        issues=$((issues + 1))
    fi

    echo ""
    if [ $issues -eq 0 ]; then
        print_ok "All DNS records verified"
    else
        print_warning "${issues} DNS issue(s) found"
    fi

    return $issues
}

################################################################################
# Service Check
################################################################################

check_services() {
    print_header "Service Status"

    local issues=0

    # Check Postfix
    echo -n "Postfix: "
    if systemctl is-active postfix &> /dev/null; then
        echo -e "${GREEN}RUNNING${NC}"
        local queue=$(mailq 2>/dev/null | tail -1)
        print_info "  Queue: ${queue}"
    else
        echo -e "${RED}NOT RUNNING${NC}"
        issues=$((issues + 1))
    fi

    # Check OpenDKIM
    echo -n "OpenDKIM: "
    if systemctl is-active opendkim &> /dev/null; then
        echo -e "${GREEN}RUNNING${NC}"
        # Test socket connectivity
        if nc -z localhost 8891 2>/dev/null; then
            print_ok "  Socket responsive on port 8891"
        else
            print_warning "  Socket not responding on port 8891"
        fi
    else
        echo -e "${YELLOW}NOT RUNNING${NC}"
        issues=$((issues + 1))
    fi

    # Check Dovecot (optional)
    echo -n "Dovecot: "
    if command -v dovecot &> /dev/null; then
        if systemctl is-active dovecot &> /dev/null; then
            echo -e "${GREEN}RUNNING${NC}"
        else
            echo -e "${YELLOW}NOT RUNNING${NC}"
        fi
    else
        echo -e "${CYAN}NOT INSTALLED${NC} (optional)"
    fi

    # Check ports
    echo ""
    print_info "Port Status:"
    for port in 25 587 993 143; do
        echo -n "  Port ${port}: "
        if ss -tlnp | grep -q ":${port} " 2>/dev/null; then
            case $port in
                25)  echo -e "${GREEN}OPEN${NC} (SMTP)" ;;
                587) echo -e "${GREEN}OPEN${NC} (Submission)" ;;
                993) echo -e "${GREEN}OPEN${NC} (IMAPS)" ;;
                143) echo -e "${GREEN}OPEN${NC} (IMAP)" ;;
            esac
        else
            case $port in
                25|587) echo -e "${RED}CLOSED${NC}"; issues=$((issues + 1)) ;;
                *)      echo -e "${CYAN}CLOSED${NC} (Dovecot not configured)" ;;
            esac
        fi
    done

    echo ""
    if [ $issues -eq 0 ]; then
        print_ok "All critical services running"
    else
        print_warning "${issues} service issue(s) found"
    fi

    return $issues
}

################################################################################
# Log Check
################################################################################

check_logs() {
    print_header "Recent Log Errors"

    # Check mail log for errors in last hour
    local log_file="/var/log/mail.log"
    if [ ! -f "$log_file" ]; then
        log_file="/var/log/syslog"
    fi

    print_info "Checking ${log_file} for recent errors..."
    echo ""

    # Get errors from last hour
    local errors=$(grep -i "error\|warning\|fatal\|reject" "$log_file" 2>/dev/null | \
        tail -20 | grep -v "warning: dict_nis_init" || true)

    if [ -n "$errors" ]; then
        echo -e "${YELLOW}Recent warnings/errors:${NC}"
        echo "$errors" | while read -r line; do
            if echo "$line" | grep -qi "error\|fatal"; then
                echo -e "${RED}  ${line}${NC}"
            else
                echo -e "${YELLOW}  ${line}${NC}"
            fi
        done
    else
        print_ok "No recent errors in mail log"
    fi

    # Check for bounced emails
    echo ""
    print_info "Checking mail queue..."
    local queue_count=$(mailq 2>/dev/null | grep -c "^[A-F0-9]" || echo "0")
    if [ "$queue_count" -gt 0 ]; then
        print_warning "${queue_count} message(s) in queue"
        echo ""
        mailq 2>/dev/null | head -20
    else
        print_ok "Mail queue is empty"
    fi
}

################################################################################
# Send Test Email
################################################################################

send_test_email() {
    local recipient="$1"
    local sender="test@${DOMAIN}"

    print_header "Sending Test Email"

    print_info "Sending test email to: ${recipient}"
    print_info "From: ${sender}"

    local subject="NWP Email Test - $(date '+%Y-%m-%d %H:%M:%S')"
    local body=$(cat << EOF
This is a test email from NWP Email Infrastructure.

Server: ${MAIL_HOSTNAME}
Domain: ${DOMAIN}
Time: $(date)

If you receive this email, the basic email sending is working.

To verify full email authentication:
1. Go to https://www.mail-tester.com/
2. Copy the test email address shown
3. Run: ./test_email.sh --send <mail-tester-address>
4. Click "Then check your score" on mail-tester.com

--
NWP Email Infrastructure
${MAIL_HOSTNAME}
EOF
)

    # Send email
    echo "$body" | mail -s "$subject" -r "$sender" "$recipient"

    if [ $? -eq 0 ]; then
        print_ok "Test email sent successfully"
        echo ""
        print_info "Check your inbox at: ${recipient}"
        print_info "Also check spam/junk folder"
        echo ""
        print_info "To verify DKIM signature, check email headers for:"
        echo "  dkim=pass"
        echo "  spf=pass"
    else
        print_error "Failed to send test email"
        echo ""
        print_info "Check logs with: ./test_email.sh --check-logs"
    fi
}

################################################################################
# Mail-Tester Instructions
################################################################################

show_mail_tester() {
    print_header "Mail-Tester.com Instructions"

    cat << EOF
To verify your email configuration with mail-tester.com:

1. Visit: ${CYAN}https://www.mail-tester.com/${NC}

2. Copy the unique test email address shown (e.g., test-xxx@srv1.mail-tester.com)

3. Send a test email to that address:
   ${CYAN}echo "Test email for mail-tester" | mail -s "Test" -r git@${DOMAIN} <test-address>${NC}

   Or use this script:
   ${CYAN}./test_email.sh --send <test-address>${NC}

4. Go back to mail-tester.com and click "Then check your score"

5. Review your score and recommendations

Expected score with full configuration: ${GREEN}10/10${NC}

Common issues that reduce score:
  - Missing SPF record (-2)
  - Missing DKIM signature (-2)
  - Missing DMARC record (-1)
  - PTR mismatch (-1)
  - Listed on blacklists (-varies)

Current configuration status:
EOF

    # Quick DNS check
    echo ""
    echo -n "  SPF: "
    dig TXT "${DOMAIN}" +short 2>/dev/null | grep -q "v=spf1" && echo -e "${GREEN}Present${NC}" || echo -e "${RED}Missing${NC}"

    echo -n "  DKIM: "
    dig TXT "${DKIM_SELECTOR}._domainkey.${DOMAIN}" +short 2>/dev/null | grep -q "p=" && echo -e "${GREEN}Present${NC}" || echo -e "${RED}Missing${NC}"

    echo -n "  DMARC: "
    dig TXT "_dmarc.${DOMAIN}" +short 2>/dev/null | grep -q "v=DMARC1" && echo -e "${GREEN}Present${NC}" || echo -e "${RED}Missing${NC}"

    echo -n "  PTR: "
    local ptr=$(dig -x "${MAIL_IP}" +short 2>/dev/null | sed 's/\.$//')
    [ "$ptr" = "${MAIL_HOSTNAME}" ] && echo -e "${GREEN}Correct${NC}" || echo -e "${YELLOW}${ptr:-Missing}${NC}"

    echo ""
}

################################################################################
# Full Test Suite
################################################################################

run_all_tests() {
    print_header "NWP Email Infrastructure Test"

    echo "Domain:       ${DOMAIN}"
    echo "Mail Host:    ${MAIL_HOSTNAME}"
    echo "Mail IP:      ${MAIL_IP}"
    echo "DKIM Selector: ${DKIM_SELECTOR}"

    local total_issues=0

    # Run tests
    check_dns
    total_issues=$((total_issues + $?))

    check_services
    total_issues=$((total_issues + $?))

    check_logs

    echo ""
    print_header "Summary"

    if [ $total_issues -eq 0 ]; then
        echo -e "${GREEN}"
        echo "  ╔═══════════════════════════════════════════════════════╗"
        echo "  ║  All tests passed! Email infrastructure is healthy.   ║"
        echo "  ╚═══════════════════════════════════════════════════════╝"
        echo -e "${NC}"
        echo ""
        echo "Next steps:"
        echo "  1. Send test email: ./test_email.sh --send your@email.com"
        echo "  2. Verify score:    ./test_email.sh --mail-tester"
    else
        echo -e "${YELLOW}"
        echo "  ╔═══════════════════════════════════════════════════════╗"
        echo "  ║  ${total_issues} issue(s) found. Review the output above.        ║"
        echo "  ╚═══════════════════════════════════════════════════════╝"
        echo -e "${NC}"
        echo ""
        echo "To fix issues, run:"
        echo "  ./setup_email.sh       # Reconfigure email infrastructure"
        echo "  ./setup_email.sh --check  # Check current status"
    fi
}

################################################################################
# Blacklist Check
################################################################################

check_blacklists() {
    print_header "Blacklist Check"

    print_info "Checking if ${MAIL_IP} is listed on common blacklists..."
    echo ""

    local blacklists=(
        "zen.spamhaus.org"
        "bl.spamcop.net"
        "b.barracudacentral.org"
        "dnsbl.sorbs.net"
        "spam.dnsbl.sorbs.net"
    )

    # Reverse IP for DNSBL query
    local reversed_ip=$(echo "$MAIL_IP" | awk -F. '{print $4"."$3"."$2"."$1}')
    local listed=0

    for bl in "${blacklists[@]}"; do
        echo -n "${bl}: "
        if dig +short "${reversed_ip}.${bl}" 2>/dev/null | grep -q "127."; then
            echo -e "${RED}LISTED${NC}"
            listed=$((listed + 1))
        else
            echo -e "${GREEN}Clean${NC}"
        fi
    done

    echo ""
    if [ $listed -eq 0 ]; then
        print_ok "IP is not listed on checked blacklists"
    else
        print_warning "IP is listed on ${listed} blacklist(s)"
        echo ""
        echo "To request delisting, visit each blacklist's website"
    fi
}

################################################################################
# Mailpit Integration
################################################################################

check_mailpit_available() {
    if mailpit_is_available 2>/dev/null; then
        MAILPIT_AVAILABLE=true
        return 0
    else
        MAILPIT_AVAILABLE=false
        return 1
    fi
}

check_mailpit() {
    print_header "Mailpit Status"

    echo -n "Mailpit Service: "
    if check_mailpit_available; then
        echo -e "${GREEN}AVAILABLE${NC} (${MAILPIT_URL})"

        # Get info
        local info
        info=$(mailpit_info)
        local version
        version=$(echo "$info" | jq -r '.Version // "unknown"')
        echo "  Version: $version"

        # Get message count
        local count
        count=$(mailpit_count)
        echo "  Messages: $count"

        # Show recent messages
        if [ "$count" -gt 0 ]; then
            echo ""
            print_info "Recent messages:"
            mailpit_list 5 | jq -r '.messages[] | "  \(.Created | split("T")[0]) | \(.From.Address) → \(.To[0].Address) | \(.Subject)"' 2>/dev/null || true
        fi
    else
        echo -e "${YELLOW}NOT AVAILABLE${NC}"
        echo ""
        echo "To enable Mailpit for development email testing:"
        echo "  1. Start Mailpit: docker-compose -f email/docker-compose.mailpit.yml up -d"
        echo "  2. Or for DDEV sites: copy templates/ddev/docker-compose.mailpit.yaml to .ddev/"
        echo "  3. Access UI at: ${MAILPIT_URL}"
    fi
}

send_and_verify_email() {
    local recipient="$1"
    local sender="test@${DOMAIN}"

    print_header "Send and Verify Email"

    # Check Mailpit availability
    if ! check_mailpit_available; then
        print_error "Mailpit not available at ${MAILPIT_URL}"
        print_info "Start Mailpit first or use --send for basic sending"
        return 1
    fi

    # Mark timestamp before sending
    local timestamp
    timestamp=$(mailpit_mark_timestamp)

    local subject="NWP Email Test - $(date '+%Y-%m-%d %H:%M:%S')"
    local body=$(cat << EOF
This is a verified test email from NWP Email Infrastructure.

Server: ${MAIL_HOSTNAME}
Domain: ${DOMAIN}
Time: $(date)
Test ID: $(uuidgen 2>/dev/null || echo "test-$$")

This email was sent and verified via Mailpit.
EOF
)

    print_info "Sending test email to: ${recipient}"
    print_info "From: ${sender}"
    print_info "Subject: ${subject}"

    # Send email (using SMTP to Mailpit)
    if command -v swaks &> /dev/null; then
        # Use swaks for more control
        swaks --to "$recipient" \
              --from "$sender" \
              --server "${MAILPIT_URL##*://}" \
              --port 1025 \
              --header "Subject: $subject" \
              --body "$body" \
              --silent 2>/dev/null
    else
        # Fallback to mail command (requires Postfix config pointing to Mailpit)
        echo "$body" | mail -s "$subject" -r "$sender" "$recipient" 2>/dev/null
    fi

    echo ""
    print_info "Waiting for email in Mailpit..."

    # Wait for email
    local message_id
    message_id=$(mailpit_wait_for_email "$recipient" "NWP Email Test" 15 "$timestamp")

    if [ -n "$message_id" ]; then
        print_ok "Email delivered successfully!"
        echo ""

        # Verify content
        print_info "Verifying email content..."
        local message
        message=$(mailpit_get_message "$message_id")

        # Check basic fields
        local actual_to
        actual_to=$(echo "$message" | jq -r '.To[0].Address')
        local actual_from
        actual_from=$(echo "$message" | jq -r '.From.Address')
        local actual_subject
        actual_subject=$(echo "$message" | jq -r '.Subject')

        echo "  From: $actual_from"
        echo "  To: $actual_to"
        echo "  Subject: $actual_subject"

        # Check authentication headers
        echo ""
        print_info "Checking email headers..."
        mailpit_check_auth "$message_id"

        # Save artifacts
        echo ""
        print_info "Saving email artifacts..."
        local artifact_dir="${NWP_DIR}/email/test-artifacts"
        mkdir -p "$artifact_dir"
        mailpit_save_artifacts "$message_id" "$artifact_dir"

        echo ""
        print_ok "Verification complete!"
        echo "  View in Mailpit: ${MAILPIT_URL}"
        echo "  Artifacts saved: ${artifact_dir}/"
    else
        print_error "Email not received within timeout"
        echo ""
        echo "Troubleshooting:"
        echo "  1. Check mail logs: ./test_email.sh --check-logs"
        echo "  2. Verify SMTP is pointing to Mailpit (localhost:1025)"
        echo "  3. Check Mailpit UI: ${MAILPIT_URL}"
        return 1
    fi
}

verify_email_headers() {
    local message_id="$1"

    print_header "Email Header Verification"

    if ! check_mailpit_available; then
        print_error "Mailpit not available at ${MAILPIT_URL}"
        return 1
    fi

    if [ -z "$message_id" ]; then
        # Get latest message
        print_info "No message ID specified, using latest message..."
        message_id=$(mailpit_list 1 | jq -r '.messages[0].ID // empty')
        if [ -z "$message_id" ]; then
            print_error "No messages in Mailpit"
            return 1
        fi
    fi

    print_info "Message ID: $message_id"
    echo ""

    # Get full message
    local message
    message=$(mailpit_get_message "$message_id")

    # Basic info
    echo "Message Details:"
    echo "================"
    echo "Subject: $(echo "$message" | jq -r '.Subject')"
    echo "From: $(echo "$message" | jq -r '.From.Address')"
    echo "To: $(echo "$message" | jq -r '.To[0].Address')"
    echo "Date: $(echo "$message" | jq -r '.Created')"
    echo ""

    # Headers analysis
    mailpit_check_auth "$message_id"

    echo ""
    echo "All Headers:"
    echo "============"
    mailpit_get_headers "$message_id" | jq -r 'to_entries[] | "\(.key): \(.value)"' | head -30
}

clear_mailpit() {
    print_header "Clear Mailpit Messages"

    if ! check_mailpit_available; then
        print_error "Mailpit not available at ${MAILPIT_URL}"
        return 1
    fi

    local count
    count=$(mailpit_count)

    if [ "$count" -eq 0 ]; then
        print_info "Mailpit is already empty"
        return 0
    fi

    print_info "Deleting $count message(s)..."
    mailpit_delete_all

    print_ok "All messages deleted"
}

################################################################################
# Main
################################################################################

main() {
    local action="all"
    local send_to=""
    local message_id=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            --help|-h)
                show_help
                ;;
            --send|-s)
                action="send"
                if [[ -z "${2:-}" ]]; then
                    echo "Error: --send requires an email address argument" >&2
                    echo "Usage: $0 --send <email>" >&2
                    exit 1
                fi
                send_to="$2"
                shift 2
                ;;
            --send-verify|-sv)
                action="send-verify"
                if [[ -z "${2:-}" ]]; then
                    echo "Error: --send-verify requires an email address argument" >&2
                    echo "Usage: $0 --send-verify <email>" >&2
                    exit 1
                fi
                send_to="$2"
                shift 2
                ;;
            --check-dns|--dns)
                action="dns"
                shift
                ;;
            --check-services|--services)
                action="services"
                shift
                ;;
            --check-logs|--logs)
                action="logs"
                shift
                ;;
            --check-mailpit|--mailpit)
                action="mailpit"
                shift
                ;;
            --mail-tester)
                action="mailtester"
                shift
                ;;
            --blacklist|--bl)
                action="blacklist"
                shift
                ;;
            --verify-headers|--headers)
                action="headers"
                message_id="${2:-}"
                shift
                [ -n "$message_id" ] && shift
                ;;
            --clear-mailpit|--clear)
                action="clear"
                shift
                ;;
            *)
                print_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    case "$action" in
        all)
            run_all_tests
            # Also check Mailpit if available
            check_mailpit_available && check_mailpit
            ;;
        dns)
            check_dns
            ;;
        services)
            check_services
            ;;
        logs)
            check_logs
            ;;
        send)
            if [ -z "$send_to" ]; then
                print_error "Email address required for --send"
                echo "Usage: ./test_email.sh --send your@email.com"
                exit 1
            fi
            send_test_email "$send_to"
            ;;
        send-verify)
            if [ -z "$send_to" ]; then
                print_error "Email address required for --send-verify"
                echo "Usage: ./test_email.sh --send-verify test@example.com"
                exit 1
            fi
            send_and_verify_email "$send_to"
            ;;
        mailpit)
            check_mailpit
            ;;
        mailtester)
            show_mail_tester
            ;;
        blacklist)
            check_blacklists
            ;;
        headers)
            verify_email_headers "$message_id"
            ;;
        clear)
            clear_mailpit
            ;;
    esac
}

main "$@"
