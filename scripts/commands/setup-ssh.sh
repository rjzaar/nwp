#!/bin/bash

################################################################################
# NWP SSH Key Setup Script
#
# Generates project-specific SSH keys for Linode deployment
# - Creates keys/ directory (gitignored)
# - Generates nwp and nwp.pub keypair
# - Installs private key to ~/.ssh/nwp
# - Public key must be manually added to Linode account
#
# Usage: ./setup-ssh.sh
################################################################################

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

# Source shared libraries
source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh"

# Get list of Linode servers from cnwp.yml
get_linode_servers() {
    awk '
        /^linode:/ { in_linode=1 }
        in_linode && /^  servers:/ { in_servers=1; next }
        in_servers && /^    [a-z_]+:/ {
            server=$1
            sub(/:$/, "", server)
            print server
        }
        in_servers && /^  [a-z]/ && !/^  servers:/ { in_servers=0; in_linode=0 }
    ' "$PROJECT_ROOT/cnwp.yml" 2>/dev/null
}

# Get server details from cnwp.yml
get_server_detail() {
    local server_name=$1
    local detail=$2

    awk -v server="$server_name" -v detail="$detail" '
        /^linode:/ { in_linode=1 }
        in_linode && /^  servers:/ { in_servers=1 }
        in_servers && $0 ~ "^    " server ":" { in_server=1; next }
        in_server && $0 ~ "^      " detail ": " {
            value=$0
            sub(/^      [^:]+: /, "", value)
            sub(/#.*$/, "", value)
            gsub(/^[ \t]+|[ \t]+$/, "", value)
            print value
            exit
        }
        in_server && /^    [a-z]/ { in_server=0 }
    ' "$PROJECT_ROOT/cnwp.yml" 2>/dev/null
}

# Push SSH key to specific Linode server
push_key_to_server() {
    local server_name=$1
    local public_key_file=$2

    local ssh_user=$(get_server_detail "$server_name" "ssh_user")
    local ssh_host=$(get_server_detail "$server_name" "ssh_host")
    local ssh_port=$(get_server_detail "$server_name" "ssh_port")
    local ssh_key=$(get_server_detail "$server_name" "ssh_key")

    if [ -z "$ssh_user" ] || [ -z "$ssh_host" ]; then
        print_warning "Incomplete configuration for server: $server_name"
        return 1
    fi

    print_info "Pushing key to $server_name ($ssh_user@$ssh_host)..."

    # Build SSH command
    local ssh_cmd="ssh"
    if [ -n "$ssh_port" ] && [ "$ssh_port" != "22" ]; then
        ssh_cmd="$ssh_cmd -p $ssh_port"
    fi

    # If there's an existing key, use it for the connection
    if [ -n "$ssh_key" ]; then
        ssh_key_expanded="${ssh_key/#\~/$HOME}"
        if [ -f "$ssh_key_expanded" ]; then
            ssh_cmd="$ssh_cmd -i $ssh_key_expanded"
        fi
    fi

    # Add options for non-interactive
    # SECURITY NOTE: StrictHostKeyChecking=accept-new automatically accepts new host keys.
    # This is convenient but enables MITM attacks on first connection.
    # For high-security environments, pre-populate known_hosts or use StrictHostKeyChecking=yes
    ssh_cmd="$ssh_cmd -o StrictHostKeyChecking=accept-new -o BatchMode=no"

    # Read public key from file
    local public_key
    public_key=$(cat "$public_key_file")

    # Push the key by piping through stdin to avoid command injection
    # SECURITY FIX: Previously embedded $public_key in command string which allowed
    # malicious keys containing shell metacharacters to execute arbitrary commands
    if echo "$public_key" | $ssh_cmd "$ssh_user@$ssh_host" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && echo 'Key added successfully'"; then
        print_status "Key pushed to $server_name"
        return 0
    else
        print_warning "Failed to push key to $server_name (may need manual setup)"
        return 1
    fi
}

show_help() {
    cat << EOF
NWP SSH Key Setup Script

Generates project-specific SSH keys for Linode deployment.

USAGE:
    $0 [OPTIONS]

OPTIONS:
    -f, --force         Overwrite existing keys
    -t, --type TYPE     Key type (ed25519, rsa) [default: ed25519]
    -b, --bits BITS     Key size for RSA (2048, 4096) [default: 4096]
    -e, --email EMAIL   Email for key comment
    -h, --help          Show this help message

EXAMPLES:
    # Generate default ed25519 key
    ./setup-ssh.sh

    # Generate with email
    ./setup-ssh.sh -e user@example.com

    # Generate RSA 4096 key
    ./setup-ssh.sh -t rsa -b 4096

    # Overwrite existing keys
    ./setup-ssh.sh -f

WHAT THIS DOES:
    1. Creates keys/ directory in NWP root (gitignored)
    2. Generates SSH keypair: nwp (private) and nwp.pub (public)
    3. Installs private key to ~/.ssh/nwp with correct permissions (600)
    4. Displays public key for manual addition to Linode

NEXT STEPS (Manual - Required):
    1. Add public key to Linode Cloud Manager:
       - Go to https://cloud.linode.com/profile/keys
       - Click "Add SSH Key"
       - Paste the public key displayed by this script
       - Label it (e.g., "nwp-deployment")

    2. For existing servers, also add key manually:
       ssh-copy-id -i ~/.ssh/nwp user@your-server

    3. Configure deployment in cnwp.yml:
       linode:
         servers:
           linode_primary:
             ssh_user: deploy
             ssh_host: YOUR_SERVER_IP
             ssh_key: ~/.ssh/nwp

NOTE:
    Once the SSH key is added to your Linode account:
    - New Linode instances will automatically include this key
    - Tests can provision temporary Linode nodes for production testing
    - Deployment scripts (stg2prod.sh, prod2stg.sh) will work automatically

EOF
}

# Parse arguments
FORCE=false
KEY_TYPE="ed25519"
KEY_BITS=4096
EMAIL=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -f|--force)
            FORCE=true
            shift
            ;;
        -t|--type)
            KEY_TYPE="$2"
            shift 2
            ;;
        -b|--bits)
            KEY_BITS="$2"
            shift 2
            ;;
        -e|--email)
            EMAIL="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Validate key type
if [[ "$KEY_TYPE" != "ed25519" && "$KEY_TYPE" != "rsa" ]]; then
    print_error "Invalid key type: $KEY_TYPE (must be ed25519 or rsa)"
    exit 1
fi

# Validate RSA bits
if [[ "$KEY_TYPE" == "rsa" && "$KEY_BITS" != "2048" && "$KEY_BITS" != "4096" ]]; then
    print_error "Invalid RSA key size: $KEY_BITS (must be 2048 or 4096)"
    exit 1
fi

print_header "NWP SSH Key Setup"

################################################################################
# Configuration
################################################################################

PRIVATE_KEY_PATH="$PROJECT_ROOT/keys/nwp"
SSH_PRIVATE_KEY_PATH="$HOME/.ssh/nwp"
PUBLIC_KEY="$PROJECT_ROOT/keys/nwp.pub"

################################################################################
# Step 1: Create keys directory
################################################################################

print_header "Step 1: Create Keys Directory"

KEYS_DIR="$PROJECT_ROOT/keys"

if [ -d "$KEYS_DIR" ]; then
    print_status "Keys directory exists: $KEYS_DIR"
else
    mkdir -p "$KEYS_DIR"
    chmod 700 "$KEYS_DIR"
    print_status "Created keys directory: $KEYS_DIR"
fi

################################################################################
# Step 2: Check for existing keys
################################################################################

print_header "Step 2: Check Existing Keys"

PRIVATE_KEY="$KEYS_DIR/nwp"
PUBLIC_KEY="$KEYS_DIR/nwp.pub"
SSH_PRIVATE_KEY="$HOME/.ssh/nwp"

if [ -f "$PRIVATE_KEY" ] || [ -f "$PUBLIC_KEY" ] || [ -f "$SSH_PRIVATE_KEY" ]; then
    if [ "$FORCE" = false ]; then
        print_warning "SSH keys already exist:"
        [ -f "$PRIVATE_KEY" ] && echo "  - $PRIVATE_KEY"
        [ -f "$PUBLIC_KEY" ] && echo "  - $PUBLIC_KEY"
        [ -f "$SSH_PRIVATE_KEY" ] && echo "  - $SSH_PRIVATE_KEY"
        echo ""
        read -p "Overwrite existing keys? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_info "Setup cancelled"
            exit 0
        fi
        FORCE=true
    fi
    print_info "Will overwrite existing keys"
fi

################################################################################
# Step 3: Generate SSH keypair
################################################################################

print_header "Step 3: Generate SSH Keypair"

# Build ssh-keygen command
SSH_COMMENT="${EMAIL:-nwp-deployment}"

if [ "$KEY_TYPE" = "ed25519" ]; then
    print_info "Generating Ed25519 key (modern, secure, fast)"
    ssh-keygen -t ed25519 -C "$SSH_COMMENT" -f "$PRIVATE_KEY" -N ""
else
    print_info "Generating RSA $KEY_BITS key"
    ssh-keygen -t rsa -b "$KEY_BITS" -C "$SSH_COMMENT" -f "$PRIVATE_KEY" -N ""
fi

print_status "Keypair generated successfully"
print_info "Private key: $PRIVATE_KEY"
print_info "Public key: $PUBLIC_KEY"

################################################################################
# Step 4: Set correct permissions
################################################################################

print_header "Step 4: Set Permissions"

chmod 600 "$PRIVATE_KEY"
chmod 644 "$PUBLIC_KEY"
print_status "Key permissions set (private: 600, public: 644)"

################################################################################
# Step 5: Install private key to ~/.ssh
################################################################################

print_header "Step 5: Install Private Key"

# Ensure ~/.ssh exists
if [ ! -d "$HOME/.ssh" ]; then
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    print_status "Created ~/.ssh directory"
fi

# Copy private key
cp "$PRIVATE_KEY" "$SSH_PRIVATE_KEY"
chmod 600 "$SSH_PRIVATE_KEY"
print_status "Private key installed to: $SSH_PRIVATE_KEY"

################################################################################
# Step 6: Display public key
################################################################################

print_header "Setup Complete!"

echo -e "${GREEN}${BOLD}✓ SSH keys generated and installed${NC}\n"

echo -e "${BOLD}Public key for deployment:${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
cat "$PUBLIC_KEY"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

################################################################################
# Step 7: Add SSH Key to Linode (Manual)
################################################################################

print_header "Step 7: Add SSH Key to Linode"

echo -e "${BOLD}IMPORTANT:${NC} You must manually add this SSH key to your Linode account"
echo ""
echo "Follow these steps:"
echo ""
echo "1. Log in to Linode Cloud Manager:"
echo "   ${BLUE}https://cloud.linode.com${NC}"
echo ""
echo "2. Go to your Profile → SSH Keys:"
echo "   ${BLUE}https://cloud.linode.com/profile/keys${NC}"
echo ""
echo "3. Click ${BOLD}\"Add SSH Key\"${NC}"
echo ""
echo "4. Enter a label (e.g., \"nwp-deployment-$(date +%Y%m%d)\")"
echo ""
echo "5. Paste your public key:"
echo ""
echo "   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "   $(cat "$PUBLIC_KEY")"
echo "   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "6. Click ${BOLD}\"Add Key\"${NC}"
echo ""
print_status "Once added, the key will be available for all new Linode instances"
echo ""

################################################################################
# Final Instructions
################################################################################

print_header "Next Steps"

echo -e "${BOLD}Additional setup for existing servers:${NC}"
echo ""
echo "If you need to add the key to existing Linode servers manually:"
echo ""
echo "Option 1 - Using ssh-copy-id:"
echo "  ${BLUE}ssh-copy-id -i ~/.ssh/nwp user@your-server${NC}"
echo ""
echo "Option 2 - Manual copy:"
echo "  ${BLUE}ssh user@your-server 'mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys'${NC}"
echo "  Then paste the public key and press Ctrl+D"
echo ""
echo "Option 3 - Copy from this file:"
echo "  ${BLUE}cat $PUBLIC_KEY${NC}"
echo ""
echo -e "${BOLD}Configure deployment in cnwp.yml:${NC}"
echo ""
echo "  ${BLUE}linode:"
echo "    servers:"
echo "      linode_primary:"
echo "        ssh_user: deploy"
echo "        ssh_host: YOUR_SERVER_IP"
echo "        ssh_port: 22"
echo "        ssh_key: ~/.ssh/nwp${NC}"
echo ""
print_status "SSH key setup complete!"

exit 0
