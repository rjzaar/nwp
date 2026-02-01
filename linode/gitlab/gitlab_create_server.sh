#!/bin/bash

################################################################################
# gitlab_create_server.sh - Create a GitLab server on Linode
################################################################################
#
# Creates a Linode server with GitLab CE + Runner using the GitLab StackScript.
#
# Usage:
#   ./gitlab_create_server.sh --domain gitlab.example.com --email admin@example.com [OPTIONS]
#
# Required Options:
#   --domain DOMAIN      GitLab domain name (e.g., gitlab.example.com)
#   --email EMAIL        Administrator email for SSL and notifications
#
# Optional:
#   --label LABEL          Server label (default: gitlab-TIMESTAMP)
#   --region REGION        Region (default: us-east)
#   --type TYPE            Linode type (default: g6-standard-1, 2GB RAM)
#   --no-runner            Don't install GitLab Runner
#   --runner-tags TAGS     Runner tags (default: docker,shell)
#   --no-email             Skip email configuration (default: configured)
#   --linode-api-token T   Linode API token for automatic DNS setup
#   -h, --help             Show this help message
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
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
KEYS_DIR="$PROJECT_ROOT/keys"
CONFIG_DIR="$HOME/.nwp"

# Default configuration
LABEL="gitlab-$(date +%s)"
REGION="us-east"
TYPE="g6-standard-1"  # 2GB RAM minimum for GitLab
DOMAIN=""
EMAIL=""
SSH_USER="gitlab"
INSTALL_RUNNER="yes"
RUNNER_TAGS="docker,shell"
ROOT_PASS=""
AUTO_YES="no"
CONFIGURE_EMAIL="yes"  # Default: configure email automatically
LINODE_API_TOKEN=""    # Optional: for automatic DNS configuration

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

print_warning() {
    echo -e "${YELLOW}!${NC} $1"
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
        --domain)
            DOMAIN="$2"
            shift 2
            ;;
        --email)
            EMAIL="$2"
            shift 2
            ;;
        --no-runner)
            INSTALL_RUNNER="no"
            shift
            ;;
        --runner-tags)
            RUNNER_TAGS="$2"
            shift 2
            ;;
        --no-email)
            CONFIGURE_EMAIL="no"
            shift
            ;;
        --linode-api-token)
            LINODE_API_TOKEN="$2"
            shift 2
            ;;
        -y|--yes)
            AUTO_YES="yes"
            shift
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

print_header "Create GitLab Server on Linode"

# Validate required arguments
if [ -z "$DOMAIN" ]; then
    print_error "Domain is required"
    print_info "Usage: $0 --domain gitlab.example.com --email admin@example.com"
    exit 1
fi

if [ -z "$EMAIL" ]; then
    print_error "Email is required"
    print_info "Usage: $0 --domain gitlab.example.com --email admin@example.com"
    exit 1
fi

# Set GitLab external URL and hostname
GITLAB_EXTERNAL_URL="http://$DOMAIN"
HOSTNAME="$DOMAIN"

# Check prerequisites
print_info "Checking prerequisites..."

if ! command -v linode-cli &> /dev/null; then
    print_error "Linode CLI not found"
    print_info "Run: ./gitlab_setup.sh"
    exit 1
fi

print_success "Linode CLI found"

# Check StackScript ID
STACKSCRIPT_ID_FILE="$CONFIG_DIR/gitlab_stackscript_id"
if [ ! -f "$STACKSCRIPT_ID_FILE" ]; then
    print_error "StackScript ID not found"
    print_info "Run: ./gitlab_upload_stackscript.sh"
    exit 1
fi

STACKSCRIPT_ID=$(cat "$STACKSCRIPT_ID_FILE")
print_success "StackScript ID found: $STACKSCRIPT_ID"

# Get SSH public key
if [ -f "$KEYS_DIR/gitlab_linode.pub" ]; then
    SSH_PUBKEY=$(cat "$KEYS_DIR/gitlab_linode.pub")
    print_success "SSH key found: $KEYS_DIR/gitlab_linode.pub"
elif [ -f "$HOME/.ssh/id_ed25519.pub" ]; then
    SSH_PUBKEY=$(cat "$HOME/.ssh/id_ed25519.pub")
    print_success "Using default SSH key: ~/.ssh/id_ed25519.pub"
elif [ -f "$HOME/.ssh/id_rsa.pub" ]; then
    SSH_PUBKEY=$(cat "$HOME/.ssh/id_rsa.pub")
    print_success "Using default SSH key: ~/.ssh/id_rsa.pub"
else
    print_error "No SSH public key found"
    print_info "Run: ssh-keygen -t ed25519 -f $KEYS_DIR/gitlab_linode"
    exit 1
fi

# Check server type RAM requirements
print_info "Checking server type: $TYPE"
TYPE_INFO=$(linode-cli linodes types --label "$TYPE" --json 2>/dev/null | jq -r '.[0]' 2>/dev/null)

if [ -n "$TYPE_INFO" ] && [ "$TYPE_INFO" != "null" ]; then
    TYPE_RAM=$(echo "$TYPE_INFO" | jq -r '.memory')
    TYPE_LABEL=$(echo "$TYPE_INFO" | jq -r '.label')

    print_info "Selected: $TYPE_LABEL (${TYPE_RAM}MB RAM)"

    # GitLab requires minimum 2GB (2048MB) RAM
    if [ "$TYPE_RAM" -lt 2048 ]; then
        print_warning "GitLab requires minimum 2GB RAM for production use"
        print_warning "Selected type has only ${TYPE_RAM}MB RAM"
        print_info "Recommended: g6-standard-1 (2GB) or larger"
        echo ""
        if [ "$AUTO_YES" != "yes" ]; then
            read -p "Continue anyway? [y/N]: " response
            if [[ ! "$response" =~ ^[yY]$ ]]; then
                print_info "Cancelled. Use --type g6-standard-1 or larger"
                exit 1
            fi
        fi
    fi
else
    print_warning "Could not verify server type RAM"
fi

# Generate root password
ROOT_PASS=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)

print_header "Server Configuration"

echo "Configuration:"
echo "  Label: $LABEL"
echo "  Region: $REGION"
echo "  Type: $TYPE"
echo "  Domain: $DOMAIN"
echo "  GitLab URL: $GITLAB_EXTERNAL_URL"
echo "  Email: $EMAIL"
echo "  SSH User: $SSH_USER"
echo "  Install Runner: $INSTALL_RUNNER"
if [ "$INSTALL_RUNNER" = "yes" ]; then
    echo "  Runner Tags: $RUNNER_TAGS"
fi
echo "  Configure Email: $CONFIGURE_EMAIL"
if [ "$CONFIGURE_EMAIL" = "yes" ]; then
    if [ -n "$LINODE_API_TOKEN" ]; then
        echo "  DNS Configuration: Automatic (via Linode API)"
    else
        echo "  DNS Configuration: Manual (no API token)"
    fi
fi
echo ""

if [ "$AUTO_YES" = "yes" ]; then
    response="y"
else
    read -p "Create server with this configuration? [Y/n]: " response
    response=${response:-y}
fi
if [[ ! "$response" =~ ^[yY]$ ]]; then
    print_info "Cancelled"
    exit 0
fi

# Get Linode API token from .secrets.yml if not provided
if [ -z "$LINODE_API_TOKEN" ] && [ -f "$PROJECT_ROOT/.secrets.yml" ]; then
    LINODE_API_TOKEN=$(awk '
        /^linode:/ { in_linode = 1; next }
        in_linode && /^[a-zA-Z]/ && !/^  / { in_linode = 0 }
        in_linode && /^  api_token:/ {
            sub(/^  api_token: */, "")
            gsub(/["'"'"']/, "")
            sub(/ *#.*$/, "")
            gsub(/^[ \t]+|[ \t]+$/, "")
            print
            exit
        }
    ' "$PROJECT_ROOT/.secrets.yml")

    if [ -n "$LINODE_API_TOKEN" ]; then
        print_success "Using Linode API token from .secrets.yml"
    fi
fi

# Create StackScript data JSON
STACKSCRIPT_DATA=$(cat <<EOF
{
    "ssh_user": "$SSH_USER",
    "ssh_pubkey": "$SSH_PUBKEY",
    "hostname": "$HOSTNAME",
    "email": "$EMAIL",
    "timezone": "$(source "$PROJECT_ROOT/lib/timezone.sh" && get_default_timezone "$PROJECT_ROOT/nwp.yml")",
    "disable_root": "yes",
    "gitlab_external_url": "$GITLAB_EXTERNAL_URL",
    "install_runner": "$INSTALL_RUNNER",
    "runner_tags": "$RUNNER_TAGS",
    "configure_email": "$CONFIGURE_EMAIL",
    "api_token": "$LINODE_API_TOKEN"
}
EOF
)

print_header "Creating Linode Server"

print_info "Creating server (this will take a moment)..."

# Create the Linode
RESPONSE=$(linode-cli linodes create \
    --label "$LABEL" \
    --region "$REGION" \
    --type "$TYPE" \
    --image "linode/ubuntu24.04" \
    --root_pass "$ROOT_PASS" \
    --stackscript_id "$STACKSCRIPT_ID" \
    --stackscript_data "$STACKSCRIPT_DATA" \
    --json 2>&1)

LINODE_ID=$(echo "$RESPONSE" | jq -r '.[0].id' 2>/dev/null)

if [ -z "$LINODE_ID" ] || [ "$LINODE_ID" = "null" ]; then
    print_error "Failed to create server"
    echo "$RESPONSE"
    exit 1
fi

print_success "Server created! ID: $LINODE_ID"

# Get server IP
IP_ADDRESS=$(echo "$RESPONSE" | jq -r '.[0].ipv4[0]' 2>/dev/null)
print_success "IP Address: $IP_ADDRESS"

# Wait for server to boot
print_info "Waiting for server to boot..."
print_info "GitLab installation takes 10-15 minutes. Please be patient..."
echo ""

BOOT_TIMEOUT=600  # 10 minutes
ELAPSED=0
while [ $ELAPSED -lt $BOOT_TIMEOUT ]; do
    STATUS=$(linode-cli linodes list --label "$LABEL" --json | jq -r '.[0].status' 2>/dev/null)

    if [ "$STATUS" = "running" ]; then
        print_success "Server is running!"
        break
    fi

    echo -n "."
    sleep 5
    ELAPSED=$((ELAPSED + 5))
done

echo ""

if [ "$STATUS" != "running" ]; then
    print_warning "Server is not yet running (status: $STATUS)"
    print_info "You can check status with: linode-cli linodes list --label $LABEL"
else
    print_success "Server booted successfully"
fi

# Save server information
print_info "Saving server information..."

SERVER_INFO_FILE="$CONFIG_DIR/gitlab_server.json"
cat > "$SERVER_INFO_FILE" << EOF
{
    "id": $LINODE_ID,
    "label": "$LABEL",
    "ip": "$IP_ADDRESS",
    "ssh_user": "$SSH_USER",
    "created": "$(date -Iseconds)",
    "stackscript_id": $STACKSCRIPT_ID,
    "gitlab_url": "$GITLAB_EXTERNAL_URL",
    "runner_installed": $( [ "$INSTALL_RUNNER" = "yes" ] && echo "true" || echo "false" )
}
EOF

print_success "Server info saved to: $SERVER_INFO_FILE"

print_header "Server Created Successfully!"

echo "Server Details:"
echo "  ID: $LINODE_ID"
echo "  Label: $LABEL"
echo "  IP Address: $IP_ADDRESS"
echo "  SSH Command: ssh $SSH_USER@$IP_ADDRESS"
echo ""
echo "GitLab Details:"
echo "  URL: $GITLAB_EXTERNAL_URL"
echo "  Status: Installing (10-15 minutes)"
echo ""
echo "IMPORTANT - Initial Root Password:"
echo "  The GitLab root password will be auto-generated during installation"
echo "  It will be saved on the server at: /root/gitlab_credentials.txt"
echo "  Access it after installation completes with:"
echo "    ssh $SSH_USER@$IP_ADDRESS 'sudo cat /root/gitlab_credentials.txt'"
echo ""
echo "Next Steps:"
echo "  1. Wait 10-15 minutes for GitLab installation to complete"
echo "  2. Check installation progress:"
echo "     ssh $SSH_USER@$IP_ADDRESS 'sudo tail -f /var/log/gitlab-setup.log'"
echo "  3. Get root credentials:"
echo "     ssh $SSH_USER@$IP_ADDRESS 'sudo cat /root/gitlab_credentials.txt'"
echo "  4. Access GitLab: $GITLAB_EXTERNAL_URL"
echo "  5. Login with username 'root' and the auto-generated password"
echo "  6. Change the root password immediately"
if [ "$INSTALL_RUNNER" = "yes" ]; then
    echo "  7. Register GitLab Runner (see docs/RUNNER_GUIDE.md)"
fi
echo ""
echo "View server in Cloud Manager:"
echo "  https://cloud.linode.com/linodes/$LINODE_ID"
echo ""

print_info "Tip: Point your DNS A record for $DOMAIN to $IP_ADDRESS"
print_warning "Remember: The root password is only valid for 24 hours!"
