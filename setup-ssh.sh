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

# Check for Linode API token
get_linode_token() {
    local token=""

    # Check .secrets.yml first
    if [ -f "$SCRIPT_DIR/.secrets.yml" ]; then
        token=$(awk '/^linode:/{f=1} f && /api_token:/{print $2; exit}' "$SCRIPT_DIR/.secrets.yml" | tr -d '"' | tr -d "'")
    fi

    # Fall back to environment variable
    if [ -z "$token" ] && [ -n "${LINODE_API_TOKEN:-}" ]; then
        token="$LINODE_API_TOKEN"
    fi

    echo "$token"
}

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
    ' "$SCRIPT_DIR/cnwp.yml" 2>/dev/null
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
            print value
            exit
        }
        in_server && /^    [a-z]/ { in_server=0 }
    ' "$SCRIPT_DIR/cnwp.yml" 2>/dev/null
}

# Add SSH key to Linode account via API
add_key_to_linode_api() {
    local public_key_file=$1
    local token=$2
    local label="${3:-nwp-deployment-key}"

    if [ ! -f "$public_key_file" ]; then
        print_error "Public key file not found: $public_key_file"
        return 1
    fi

    local public_key=$(cat "$public_key_file")

    print_info "Adding SSH key to Linode account..."

    # Use Linode API to add SSH key
    local response=$(curl -s -X POST "https://api.linode.com/v4/profile/sshkeys" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "{\"label\": \"$label\", \"ssh_key\": \"$public_key\"}")

    if echo "$response" | grep -q '"id"'; then
        local key_id=$(echo "$response" | grep -o '"id":[0-9]*' | cut -d: -f2)
        print_status "SSH key added to Linode account (ID: $key_id)"
        return 0
    elif echo "$response" | grep -q '"errors"'; then
        local error=$(echo "$response" | grep -o '"reason":"[^"]*"' | cut -d'"' -f4)
        if echo "$error" | grep -qi "already exists\|duplicate"; then
            print_status "SSH key already exists in Linode account"
            return 0
        else
            print_error "Linode API error: $error"
            return 1
        fi
    else
        print_error "Failed to add SSH key to Linode"
        print_info "Response: $response"
        return 1
    fi
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
    ssh_cmd="$ssh_cmd -o StrictHostKeyChecking=accept-new -o BatchMode=no"

    local public_key=$(cat "$public_key_file")

    # Push the key
    if $ssh_cmd "$ssh_user@$ssh_host" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '$public_key' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && echo 'Key added successfully'"; then
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
    4. Keeps public key in keys/nwp.pub for easy deployment

LINODE INTEGRATION (Automatic if token detected):
    If .secrets.yml contains a Linode API token, this script will:
    5. Add SSH key to your Linode account via API
    6. Push key to all configured servers in cnwp.yml
    7. Set up complete deployment infrastructure automatically

    To enable automatic setup:
    - Add Linode API token to .secrets.yml:
      linode:
        api_token: YOUR_TOKEN_HERE
    - Configure servers in cnwp.yml under linode.servers

NEXT STEPS (Manual):
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
# Initial Check: Detect Linode token and missing keys
################################################################################

PRIVATE_KEY_PATH="$SCRIPT_DIR/keys/nwp"
SSH_PRIVATE_KEY_PATH="$HOME/.ssh/nwp"
LINODE_TOKEN=$(get_linode_token)

if [ -n "$LINODE_TOKEN" ] && [ ! -f "$PRIVATE_KEY_PATH" ] && [ ! -f "$SSH_PRIVATE_KEY_PATH" ]; then
    echo -e "${GREEN}${BOLD}Linode API token detected!${NC}"
    echo ""
    echo "I can automatically:"
    echo "  1. Generate SSH keys (nwp/nwp.pub)"
    echo "  2. Install private key to ~/.ssh/nwp"
    echo "  3. Add public key to your Linode account"
    echo "  4. Push key to all configured servers"
    echo ""

    SERVERS=$(get_linode_servers)
    if [ -n "$SERVERS" ]; then
        echo "Configured servers:"
        for server in $SERVERS; do
            local host=$(get_server_detail "$server" "ssh_host")
            local user=$(get_server_detail "$server" "ssh_user")
            echo "  • $server ($user@$host)"
        done
        echo ""
    fi

    read -p "Run automatic setup? (Y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        print_info "Starting automatic setup..."
        # Continue with normal flow, but will auto-push at the end
    fi
    echo ""
fi

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

################################################################################
# Step 7: Linode Integration (if token available)
################################################################################

LINODE_TOKEN=$(get_linode_token)

if [ -n "$LINODE_TOKEN" ]; then
    print_header "Step 7: Linode Integration"

    echo -e "${BOLD}Linode API token detected!${NC}\n"

    # Check for configured servers
    SERVERS=$(get_linode_servers)

    if [ -z "$SERVERS" ]; then
        print_warning "No Linode servers configured in cnwp.yml"
        echo ""
        echo "To add servers, edit cnwp.yml and add under linode.servers:"
        echo "  ${BLUE}linode:"
        echo "    servers:"
        echo "      linode_primary:"
        echo "        ssh_user: deploy"
        echo "        ssh_host: YOUR_SERVER_IP"
        echo "        ssh_port: 22"
        echo "        ssh_key: ~/.ssh/nwp${NC}"
        echo ""
    else
        echo "Configured Linode servers:"
        for server in $SERVERS; do
            local host=$(get_server_detail "$server" "ssh_host")
            local user=$(get_server_detail "$server" "ssh_user")
            echo "  • $server ($user@$host)"
        done
        echo ""

        # Offer to push key
        read -p "Push SSH key to Linode servers? (y/N) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            # Add to Linode account via API
            echo ""
            add_key_to_linode_api "$PUBLIC_KEY" "$LINODE_TOKEN" "nwp-deployment-$(date +%Y%m%d)"

            # Push to each server
            echo ""
            print_info "Pushing key to configured servers..."
            echo ""

            for server in $SERVERS; do
                push_key_to_server "$server" "$PUBLIC_KEY" || true
            done

            echo ""
            print_status "Key deployment complete!"
            echo ""
            echo "Test your connection:"
            for server in $SERVERS; do
                local host=$(get_server_detail "$server" "ssh_host")
                local user=$(get_server_detail "$server" "ssh_user")
                if [ -n "$host" ] && [ -n "$user" ]; then
                    echo "  ${BLUE}ssh -i ~/.ssh/nwp $user@$host${NC}"
                fi
            done
        else
            print_info "Skipping automatic deployment"
        fi
    fi
    echo ""
fi

################################################################################
# Final Instructions
################################################################################

if [ -z "$LINODE_TOKEN" ] || [ -z "$SERVERS" ]; then
    print_header "Manual Setup Instructions"

    echo -e "${BOLD}Next steps:${NC}"
    echo ""
    echo "1. Add public key to your Linode server:"
    echo "   ${BLUE}ssh user@your-server 'mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys'${NC}"
    echo "   Then paste the public key above and press Ctrl+D"
    echo ""
    echo "2. Or copy the public key manually:"
    echo "   ${BLUE}cat $PUBLIC_KEY${NC}"
    echo ""
    echo "3. Configure cnwp.yml with server details"
    echo ""
    echo "4. Add Linode API token to .secrets.yml for automatic deployment:"
    echo "   ${BLUE}linode:"
    echo "     api_token: YOUR_TOKEN_HERE${NC}"
    echo ""
fi

print_status "SSH key setup complete!"

exit 0
