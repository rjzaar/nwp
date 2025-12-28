#!/bin/bash

################################################################################
# NWP SSH Key Setup Script
#
# Generates project-specific SSH keys for Linode deployment
# - Creates keys/ directory (gitignored)
# - Generates nwp and nwp.pub keypair
# - Installs private key to ~/.ssh/nwp
# - Public key stays in keys/nwp.pub for easy access
#
# Usage: ./setup-ssh.sh [OPTIONS]
################################################################################

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

print_header() {
    echo -e "\n${BLUE}${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}${BOLD}  $1${NC}"
    echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════════════${NC}\n"
}

print_status() {
    echo -e "[${GREEN}✓${NC}] $1"
}

print_error() {
    echo -e "${RED}${BOLD}ERROR:${NC} $1" >&2
}

print_info() {
    echo -e "${BLUE}${BOLD}INFO:${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}${BOLD}WARNING:${NC} $1"
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
    4. Keeps public key in keys/nwp.pub for easy deployment
    5. Updates cnwp.yml with ssh_key path (if needed)

NEXT STEPS:
    1. Add public key to your Linode server:
       cat keys/nwp.pub
       # Copy output and add to server's ~/.ssh/authorized_keys

    2. Test SSH connection:
       ssh -i ~/.ssh/nwp user@your-server-ip

    3. Update cnwp.yml with server details

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
# Step 1: Create keys directory
################################################################################

print_header "Step 1: Create Keys Directory"

KEYS_DIR="$SCRIPT_DIR/keys"

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

echo -e "${BOLD}Next steps:${NC}"
echo ""
echo "1. Add public key to your Linode server:"
echo "   ${BLUE}ssh user@your-server 'mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys'${NC}"
echo "   Then paste the public key above and press Ctrl+D"
echo ""
echo "2. Or copy the public key manually:"
echo "   ${BLUE}cat $PUBLIC_KEY${NC}"
echo ""
echo "3. Test SSH connection:"
echo "   ${BLUE}ssh -i ~/.ssh/nwp user@your-server-ip${NC}"
echo ""
echo "4. Update cnwp.yml with your server configuration:"
echo "   ${BLUE}nano cnwp.yml${NC}"
echo ""
echo "   Add under linode.servers:"
echo "   ${BLUE}linode:"
echo "     servers:"
echo "       linode_primary:"
echo "         ssh_user: deploy"
echo "         ssh_host: YOUR_SERVER_IP"
echo "         ssh_port: 22"
echo "         ssh_key: ~/.ssh/nwp${NC}"
echo ""

print_status "Setup complete!"

exit 0
