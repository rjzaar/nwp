#!/bin/bash
set -euo pipefail

################################################################################
# setup_gitlab_site.sh - Set up a permanent GitLab site
#
# Creates a GitLab server on Linode at git.<url> where <url> comes from
# cnwp.yml settings.url
#
# Usage:
#   ./setup_gitlab_site.sh [OPTIONS]
#
# Options:
#   -h, --help       Show this help message
#   -y, --yes        Skip confirmation prompts
#   -e, --email      Admin email (default: admin@<url>)
#   --type TYPE      Linode type (default: g6-standard-2, 4GB RAM)
#   --region REGION  Linode region (default: us-east)
#
# Prerequisites:
#   - Linode CLI configured with API token
#   - SSH keys generated (will create if missing)
#   - StackScript uploaded (will upload if missing)
#
################################################################################

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NWP_ROOT="$(dirname "$SCRIPT_DIR")"
CNWP_FILE="$NWP_ROOT/cnwp.yml"
SECRETS_FILE="$NWP_ROOT/.secrets.yml"

# Source UI library if available
if [ -f "$NWP_ROOT/lib/ui.sh" ]; then
    source "$NWP_ROOT/lib/ui.sh"
else
    # Fallback functions
    print_header() { echo -e "\n=== $1 ===\n"; }
    print_info() { echo "[INFO] $1"; }
    print_error() { echo "[ERROR] $1" >&2; }
    print_status() { echo "[$1] $2"; }
    print_warning() { echo "[WARNING] $1"; }
fi

# Default configuration
AUTO_YES="no"
ADMIN_EMAIL=""
LINODE_TYPE="g6-standard-2"  # 4GB RAM recommended for GitLab
LINODE_REGION="us-east"

# Show help
show_help() {
    grep "^#" "$0" | grep -v "^#!/" | sed 's/^# //' | sed 's/^#//' | head -25
}

# Parse command line options
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -y|--yes)
            AUTO_YES="yes"
            shift
            ;;
        -e|--email)
            ADMIN_EMAIL="$2"
            shift 2
            ;;
        --type)
            LINODE_TYPE="$2"
            shift 2
            ;;
        --region)
            LINODE_REGION="$2"
            shift 2
            ;;
        *)
            print_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

################################################################################
# Functions
################################################################################

# Get URL from cnwp.yml settings
get_base_url() {
    if [ ! -f "$CNWP_FILE" ]; then
        print_error "cnwp.yml not found at $CNWP_FILE"
        exit 1
    fi

    local url=$(awk '
        /^settings:/ { in_settings = 1; next }
        in_settings && /^[a-zA-Z]/ && !/^  / { in_settings = 0 }
        in_settings && /^  url:/ {
            sub("^  url: *", "")
            gsub(/["\047]/, "")  # Remove quotes
            print
            exit
        }
    ' "$CNWP_FILE")

    if [ -z "$url" ]; then
        print_error "No 'url' found in cnwp.yml settings section"
        print_info "Add 'url: yourdomain.org' under settings in cnwp.yml"
        exit 1
    fi

    echo "$url"
}

# Check if GitLab site already exists
check_existing_site() {
    local domain="$1"

    # Check cnwp.yml for existing git site
    if grep -q "^  git:" "$CNWP_FILE" 2>/dev/null; then
        print_warning "A 'git' site already exists in cnwp.yml"
        if [ "$AUTO_YES" != "yes" ]; then
            read -p "Continue anyway? [y/N]: " response
            if [[ ! "$response" =~ ^[yY]$ ]]; then
                print_info "Cancelled"
                exit 0
            fi
        fi
    fi

    # Check Linode for existing server with similar name
    if linode-cli linodes list --text --no-headers 2>/dev/null | grep -q "gitlab"; then
        print_warning "Existing GitLab server(s) found on Linode:"
        linode-cli linodes list --text 2>/dev/null | grep gitlab
        echo ""
        if [ "$AUTO_YES" != "yes" ]; then
            read -p "Continue with new server? [y/N]: " response
            if [[ ! "$response" =~ ^[yY]$ ]]; then
                print_info "Cancelled"
                exit 0
            fi
        fi
    fi
}

# Ensure SSH keys exist
ensure_ssh_keys() {
    local keys_dir="$SCRIPT_DIR/keys"
    local key_file="$keys_dir/gitlab_linode"

    mkdir -p "$keys_dir"

    if [ ! -f "$key_file" ]; then
        print_info "Generating SSH keys..."
        ssh-keygen -t ed25519 -f "$key_file" -N "" -C "gitlab@$BASE_URL"
        print_status "OK" "SSH keys generated: $key_file"
    else
        print_status "OK" "SSH keys exist: $key_file"
    fi
}

# Ensure StackScript is uploaded
ensure_stackscript() {
    local stackscript_id_file="$HOME/.nwp/gitlab_stackscript_id"

    if [ -f "$stackscript_id_file" ]; then
        local stored_id=$(cat "$stackscript_id_file")
        # Verify it still exists
        if linode-cli stackscripts view "$stored_id" --text --no-headers 2>/dev/null | grep -q "GitLab"; then
            print_status "OK" "StackScript exists: $stored_id"
            echo "$stored_id"
            return 0
        fi
    fi

    # Upload new StackScript
    print_info "Uploading GitLab StackScript..."
    if [ -f "$SCRIPT_DIR/gitlab_upload_stackscript.sh" ]; then
        "$SCRIPT_DIR/gitlab_upload_stackscript.sh" > /dev/null 2>&1
        if [ -f "$stackscript_id_file" ]; then
            cat "$stackscript_id_file"
            return 0
        fi
    fi

    print_error "Failed to upload StackScript"
    exit 1
}

# Create the GitLab server
create_gitlab_server() {
    local domain="$1"
    local email="$2"
    local stackscript_id="$3"

    print_header "Creating GitLab Server"

    # Generate label
    local label="gitlab-$(echo "$domain" | cut -d. -f1)"

    # Get SSH public key
    local ssh_pubkey=$(cat "$SCRIPT_DIR/keys/gitlab_linode.pub")

    # Generate root password
    local root_pass=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)

    echo "Configuration:"
    echo "  Label:    $label"
    echo "  Domain:   $domain"
    echo "  Email:    $email"
    echo "  Region:   $LINODE_REGION"
    echo "  Type:     $LINODE_TYPE"
    echo ""

    if [ "$AUTO_YES" != "yes" ]; then
        read -p "Create server? [Y/n]: " response
        response=${response:-y}
        if [[ ! "$response" =~ ^[yY]$ ]]; then
            print_info "Cancelled"
            exit 0
        fi
    fi

    # Create StackScript data
    local stackscript_data=$(cat <<EOF
{
    "ssh_user": "gitlab",
    "ssh_pubkey": "$ssh_pubkey",
    "hostname": "$domain",
    "email": "$email",
    "timezone": "America/New_York",
    "disable_root": "yes",
    "gitlab_external_url": "https://$domain",
    "install_runner": "yes",
    "runner_tags": "docker,shell"
}
EOF
)

    print_info "Creating Linode server..."

    # Create the server
    local response=$(linode-cli linodes create \
        --label "$label" \
        --region "$LINODE_REGION" \
        --type "$LINODE_TYPE" \
        --image "linode/ubuntu24.04" \
        --root_pass "$root_pass" \
        --stackscript_id "$stackscript_id" \
        --stackscript_data "$stackscript_data" \
        --booted true \
        --json 2>&1)

    if [ $? -ne 0 ]; then
        print_error "Failed to create server"
        echo "$response"
        exit 1
    fi

    # Extract server info
    local server_id=$(echo "$response" | jq -r '.[0].id')
    local server_ip=$(echo "$response" | jq -r '.[0].ipv4[0]')

    if [ -z "$server_id" ] || [ "$server_id" = "null" ]; then
        print_error "Failed to get server ID from response"
        echo "$response"
        exit 1
    fi

    print_status "OK" "Server created: $server_id"
    print_info "IP Address: $server_ip"

    # Wait for server to boot
    print_info "Waiting for server to boot..."
    for i in {1..30}; do
        local status=$(linode-cli linodes view "$server_id" --text --no-headers --format status 2>/dev/null)
        if [ "$status" = "running" ]; then
            print_status "OK" "Server is running"
            break
        fi
        sleep 10
    done

    # Return server info
    echo "$server_id:$server_ip:$label"
}

# Register site in cnwp.yml
register_site() {
    local server_id="$1"
    local server_ip="$2"
    local domain="$3"

    print_info "Registering site in cnwp.yml..."

    # Check if sites section exists
    if ! grep -q "^sites:" "$CNWP_FILE"; then
        echo -e "\nsites:" >> "$CNWP_FILE"
    fi

    # Add site entry
    cat >> "$CNWP_FILE" << EOF
  git:
    directory: $SCRIPT_DIR
    recipe: gitlab
    environment: production
    purpose: permanent
    created: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
    linode_id: $server_id
    server_ip: $server_ip
    domain: $domain
EOF

    print_status "OK" "Site registered with purpose: permanent"
}

# Store secrets
store_secrets() {
    local server_id="$1"
    local server_ip="$2"
    local domain="$3"

    print_info "Storing secrets in .secrets.yml..."

    # Create secrets file if it doesn't exist
    if [ ! -f "$SECRETS_FILE" ]; then
        cat > "$SECRETS_FILE" << 'EOF'
# NWP Infrastructure Secrets Configuration
# NEVER commit this file to version control!

EOF
        chmod 600 "$SECRETS_FILE"
    fi

    # Check if gitlab section already exists
    if grep -q "^gitlab:" "$SECRETS_FILE"; then
        print_warning "GitLab section already exists in .secrets.yml - not overwriting"
        return 0
    fi

    # Add GitLab secrets
    cat >> "$SECRETS_FILE" << EOF

# GitLab Server ($domain)
gitlab:
  server:
    domain: $domain
    ip: $server_ip
    linode_id: $server_id
    ssh_user: gitlab
    ssh_key: git/keys/gitlab_linode
    # Root password: ssh -i git/keys/gitlab_linode gitlab@$server_ip 'sudo cat /root/gitlab_credentials.txt'
EOF

    print_status "OK" "Secrets stored"
}

################################################################################
# Main
################################################################################

print_header "GitLab Site Setup"

# Get base URL from cnwp.yml
BASE_URL=$(get_base_url)
GITLAB_DOMAIN="git.$BASE_URL"

# Set default email if not provided
if [ -z "$ADMIN_EMAIL" ]; then
    ADMIN_EMAIL="admin@$BASE_URL"
fi

print_info "Base URL: $BASE_URL"
print_info "GitLab Domain: $GITLAB_DOMAIN"
print_info "Admin Email: $ADMIN_EMAIL"
echo ""

# Check for existing site
check_existing_site "$GITLAB_DOMAIN"

# Ensure prerequisites
print_header "Prerequisites"
ensure_ssh_keys
STACKSCRIPT_ID=$(ensure_stackscript)
print_status "OK" "StackScript ID: $STACKSCRIPT_ID"

# Create the server
SERVER_INFO=$(create_gitlab_server "$GITLAB_DOMAIN" "$ADMIN_EMAIL" "$STACKSCRIPT_ID")
SERVER_ID=$(echo "$SERVER_INFO" | cut -d: -f1)
SERVER_IP=$(echo "$SERVER_INFO" | cut -d: -f2)
SERVER_LABEL=$(echo "$SERVER_INFO" | cut -d: -f3)

# Register and store
print_header "Registration"
register_site "$SERVER_ID" "$SERVER_IP" "$GITLAB_DOMAIN"
store_secrets "$SERVER_ID" "$SERVER_IP" "$GITLAB_DOMAIN"

# Summary
print_header "GitLab Site Created"

echo "Server Details:"
echo "  Domain:    $GITLAB_DOMAIN"
echo "  IP:        $SERVER_IP"
echo "  Linode ID: $SERVER_ID"
echo "  Purpose:   permanent"
echo ""
echo "Next Steps:"
echo "  1. Configure DNS: $GITLAB_DOMAIN -> $SERVER_IP"
echo "  2. Wait 10-15 minutes for GitLab installation"
echo "  3. Get root password:"
echo "     ssh -i $SCRIPT_DIR/keys/gitlab_linode gitlab@$SERVER_IP 'sudo cat /root/gitlab_credentials.txt'"
echo "  4. Access: https://$GITLAB_DOMAIN"
echo ""
print_status "OK" "Setup complete"
