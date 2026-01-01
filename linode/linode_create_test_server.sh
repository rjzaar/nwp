#!/bin/bash

################################################################################
# linode_create_test_server.sh - Create a test Linode server for NWP
################################################################################
#
# Creates a Linode server using the NWP StackScript for testing.
#
# Usage:
#   ./linode_create_test_server.sh [OPTIONS]
#
# Options:
#   --label LABEL        Server label (default: nwp-test-TIMESTAMP)
#   --region REGION      Region (default: us-east)
#   --type TYPE          Linode type (default: g6-nanode-1)
#   --email EMAIL        Admin email (default: test@example.com)
#   -h, --help           Show this help message
#
################################################################################

set -e

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYS_DIR="$SCRIPT_DIR/keys"
CONFIG_DIR="$HOME/.nwp"

# Default configuration
LABEL="nwp-test-$(date +%s)"
REGION="us-east"
TYPE="g6-nanode-1"
EMAIL="test@example.com"
SSH_USER="nwp"
HOSTNAME="nwp-test"

# Helper functions
print_header() {
    echo -e "\n${BLUE}${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}${BOLD}  $1${NC}"
    echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════════════${NC}\n"
}

print_info() {
    echo -e "${BLUE}INFO:${NC} $1"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}ERROR:${NC} $1"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --label)
            LABEL="$2"
            shift 2
            ;;
        --region)
            REGION="$2"
            shift 2
            ;;
        --type)
            TYPE="$2"
            shift 2
            ;;
        --email)
            EMAIL="$2"
            shift 2
            ;;
        -h|--help)
            grep "^#" "$0" | grep -v "^#!/" | sed 's/^# //' | sed 's/^#//'
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

print_header "Create NWP Test Server on Linode"

# Check prerequisites
print_info "Checking prerequisites..."

if ! command -v linode-cli &> /dev/null; then
    print_error "Linode CLI not found"
    print_info "Run: ./linode_setup.sh"
    exit 1
fi

# Check StackScript ID
if [ ! -f "$CONFIG_DIR/stackscript_id" ]; then
    print_error "StackScript ID not found"
    print_info "Run: ./linode_upload_stackscript.sh"
    exit 1
fi

STACKSCRIPT_ID=$(cat "$CONFIG_DIR/stackscript_id")
print_success "StackScript ID: $STACKSCRIPT_ID"

# Check SSH key
if [ -f "$KEYS_DIR/nwp_linode.pub" ]; then
    SSH_PUBKEY=$(cat "$KEYS_DIR/nwp_linode.pub")
    print_success "SSH key found"
elif [ -f "$HOME/.ssh/id_ed25519.pub" ]; then
    SSH_PUBKEY=$(cat "$HOME/.ssh/id_ed25519.pub")
    print_success "Using default SSH key"
elif [ -f "$HOME/.ssh/id_rsa.pub" ]; then
    SSH_PUBKEY=$(cat "$HOME/.ssh/id_rsa.pub")
    print_success "Using default RSA key"
else
    print_error "No SSH key found"
    print_info "Run: ssh-keygen -t ed25519 -f $KEYS_DIR/nwp_linode"
    exit 1
fi

# Display configuration
echo ""
echo "Server Configuration:"
echo "  Label: $LABEL"
echo "  Region: $REGION"
echo "  Type: $TYPE ($(case $TYPE in
    g6-nanode-1) echo '$5/month, 1GB RAM' ;;
    g6-standard-1) echo '$12/month, 2GB RAM' ;;
    g6-standard-2) echo '$24/month, 4GB RAM' ;;
    *) echo 'custom' ;;
esac))"
echo "  Email: $EMAIL"
echo "  SSH User: $SSH_USER"
echo ""

# Generate random root password (won't be used after setup)
ROOT_PASS="TempRoot$(openssl rand -base64 16 | tr -d '=+/')"

print_info "Creating Linode server..."
echo ""

# Create the Linode
RESPONSE=$(linode-cli linodes create \
    --label "$LABEL" \
    --region "$REGION" \
    --type "$TYPE" \
    --image "linode/ubuntu24.04" \
    --root_pass "$ROOT_PASS" \
    --stackscript_id "$STACKSCRIPT_ID" \
    --stackscript_data "{\"ssh_user\":\"$SSH_USER\",\"ssh_pubkey\":\"$SSH_PUBKEY\",\"hostname\":\"$HOSTNAME\",\"email\":\"$EMAIL\",\"timezone\":\"America/New_York\",\"disable_root\":\"yes\"}" \
    --json 2>&1)

# Parse response
LINODE_ID=$(echo "$RESPONSE" | jq -r '.[0].id' 2>/dev/null)

if [ -z "$LINODE_ID" ] || [ "$LINODE_ID" = "null" ]; then
    print_error "Failed to create Linode"
    echo "$RESPONSE"
    exit 1
fi

IP_ADDRESS=$(echo "$RESPONSE" | jq -r '.[0].ipv4[0]' 2>/dev/null)
STATUS=$(echo "$RESPONSE" | jq -r '.[0].status' 2>/dev/null)

print_success "Linode created successfully!"
echo ""
echo "Server Details:"
echo "  ID: $LINODE_ID"
echo "  Label: $LABEL"
echo "  IP Address: $IP_ADDRESS"
echo "  Status: $STATUS"
echo ""

# Save server info
mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_DIR/test_server.json" <<EOF
{
  "id": $LINODE_ID,
  "label": "$LABEL",
  "ip": "$IP_ADDRESS",
  "ssh_user": "$SSH_USER",
  "created": "$(date -Iseconds)",
  "stackscript_id": $STACKSCRIPT_ID
}
EOF

print_success "Server info saved to: $CONFIG_DIR/test_server.json"

print_header "Server Provisioning Started"

echo "${BOLD}What happens next:${NC}"
echo "  1. Server is booting (30-60 seconds)"
echo "  2. StackScript runs automatically (3-5 minutes)"
echo "     - Updates system packages"
echo "     - Creates 'nwp' user with sudo"
echo "     - Disables root SSH login"
echo "     - Installs LEMP stack"
echo "     - Configures firewall"
echo "  3. Server will be ready for SSH access"
echo ""
echo "${BOLD}Monitor progress:${NC}"
echo "  Watch status: linode-cli linodes view $LINODE_ID"
echo ""
echo "${BOLD}Once 'running' status (in ~1 minute):${NC}"
echo "  ssh $SSH_USER@$IP_ADDRESS"
echo ""
echo "${BOLD}View setup log on server:${NC}"
echo "  ssh $SSH_USER@$IP_ADDRESS"
echo "  sudo tail -f /var/log/nwp-setup.log"
echo ""
echo "${BOLD}Destroy server when done:${NC}"
echo "  linode-cli linodes delete $LINODE_ID"
echo ""

print_info "Waiting for server to boot..."
sleep 5

# Poll for running status
for i in {1..12}; do
    STATUS=$(linode-cli linodes view $LINODE_ID --json | jq -r '.[0].status')
    if [ "$STATUS" = "running" ]; then
        print_success "Server is running!"
        break
    fi
    echo "  Status: $STATUS (checking again in 10s...)"
    sleep 10
done

if [ "$STATUS" != "running" ]; then
    print_error "Server did not reach 'running' status"
    print_info "Check status: linode-cli linodes view $LINODE_ID"
    exit 1
fi

print_header "Server is Ready!"

# Check SMTP port accessibility (Linode blocks ports 25, 465, 587 by default on new accounts)
print_info "Checking SMTP port accessibility..."
sleep 10  # Give server a moment to fully initialize

SMTP_BLOCKED=false
if ! ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 $SSH_USER@$IP_ADDRESS \
    "timeout 5 bash -c '</dev/tcp/smtp.gmail.com/465' 2>/dev/null" 2>/dev/null; then
    SMTP_BLOCKED=true
fi

if [ "$SMTP_BLOCKED" = true ]; then
    echo ""
    echo -e "${YELLOW}${BOLD}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}${BOLD}  SMTP PORTS BLOCKED${NC}"
    echo -e "${YELLOW}${BOLD}════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}Linode blocks SMTP ports (25, 465, 587) on new accounts by default.${NC}"
    echo "Your server will not be able to send emails until this is resolved."
    echo ""
    echo "${BOLD}To request SMTP port access, submit a support ticket:${NC}"
    echo "  https://cloud.linode.com/support/tickets"
    echo ""
    echo "${BOLD}Suggested ticket content:${NC}"
    echo "────────────────────────────────────────────────────────────────"
    cat << 'SMTP_TICKET'
Subject: Request for Account-Wide SMTP Port Restriction Removal

Hello Linode Support,

I am requesting the removal of SMTP port restrictions (ports 25, 465, and 587) for my entire Linode account.

Current Linode: [YOUR_SERVER_LABEL]

Use Case:
This account will be used to host multiple servers for web development and hosting purposes:

1. Development/Staging Servers - Testing sites in a live environment, including email functionality (notifications, password resets, form submissions)

2. Client Testing - Some sites will allow client access for review and testing, which requires working email notifications

3. Production Hosting - Sites will be hosted through this account, with the number of servers growing over time as our organisation expands

All email sent will be transactional in nature (notifications, alerts, password resets, etc.). Emails will never be used for spam or unsolicited marketing.

Compliance Confirmation:
- I confirm that all email sent from this account will be CAN-SPAM compliant
- I have reviewed and will adhere to Linode's Acceptable Use Policy (Section 2 - Abuse)
- rDNS will be configured for all server IP addresses
- All emails will be sent only to users who have explicitly opted in or registered on the hosted applications

Please let me know if you need any additional information.

Thank you,
[Your Name]
SMTP_TICKET
    echo "────────────────────────────────────────────────────────────────"
    echo ""
    echo -e "${YELLOW}Replace [YOUR_SERVER_LABEL] with: $LABEL${NC}"
    echo ""
fi

echo "${BOLD}Next steps:${NC}"
echo ""
echo "1. ${GREEN}Wait 3-5 minutes${NC} for StackScript to complete setup"
echo ""
echo "2. ${GREEN}Test SSH access:${NC}"
echo "   ssh $SSH_USER@$IP_ADDRESS"
echo ""
echo "3. ${GREEN}Verify setup:${NC}"
echo "   ssh $SSH_USER@$IP_ADDRESS 'sudo tail -100 /var/log/nwp-setup.log'"
echo ""
echo "4. ${GREEN}Test that root is disabled:${NC}"
echo "   ssh root@$IP_ADDRESS  # Should fail"
echo ""
echo "5. ${GREEN}Check services:${NC}"
echo "   ssh $SSH_USER@$IP_ADDRESS 'systemctl status nginx php8.2-fpm mariadb'"
echo ""

print_success "Test server deployment complete!"
