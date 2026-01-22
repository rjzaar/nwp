#!/bin/bash

################################################################################
# podcast.sh - NWP Podcast Hosting Setup
################################################################################
#
# Automated setup for Castopod podcast hosting infrastructure.
# This script orchestrates:
#   - Backblaze B2 bucket and application key creation
#   - Linode VPS provisioning with Docker
#   - Cloudflare DNS configuration
#   - Docker Compose configuration generation
#
# Prerequisites:
#   - .secrets.yml configured with Linode, Cloudflare, and B2 credentials
#   - SSH keys generated (run ./setup-ssh.sh if needed)
#   - b2 CLI installed and authorized (pip install b2 && b2 account authorize)
#
# Usage:
#   ./podcast.sh setup podcast.example.com    # Full automated setup
#   ./podcast.sh generate podcast.example.com # Generate config files only
#   ./podcast.sh deploy <output_dir>          # Deploy to existing server
#   ./podcast.sh teardown <linode_id>         # Remove infrastructure
#   ./podcast.sh status                       # Check prerequisites
#
################################################################################

set -euo pipefail

# Get script directory (from symlink location, not resolved target)
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

# Source libraries
source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/linode.sh"
source "$PROJECT_ROOT/lib/cloudflare.sh"
source "$PROJECT_ROOT/lib/b2.sh"
source "$PROJECT_ROOT/lib/podcast.sh"

# Track execution time
START_TIME=$(date +%s)

# Default values
LINODE_REGION="us-east"
MEDIA_SUBDOMAIN="media"
B2_REGION="us-west-004"
AUTO_CONFIRM=false
DEBUG=false
LINODE_ONLY=false  # When true, use Linode DNS and local storage (no Cloudflare/B2)
SERVER_IP=""       # When set, use existing server instead of creating new Linode

################################################################################
# Help
################################################################################

show_help() {
    cat << 'EOF'
NWP Podcast Setup - Automated Castopod Hosting

USAGE:
    ./podcast.sh <command> [options] [arguments]

COMMANDS:
    setup <domain>      Full automated setup (B2 + Linode + Cloudflare + files)
    generate <domain>   Generate configuration files only (no infrastructure)
    deploy <dir>        Deploy configuration files to server
    teardown <id>       Remove infrastructure (requires Linode ID)
    status              Check prerequisites and credentials

OPTIONS:
    -r, --region        Linode region (default: us-east)
    -m, --media         Media subdomain (default: media)
    -b, --b2-region     B2 region (default: us-west-004)
    -s, --server <IP>   Use existing server instead of creating new Linode
    -l, --linode-only   Use Linode DNS and local storage (no Cloudflare/B2)
    -y, --yes           Auto-confirm prompts
    -v, --verbose       Enable debug output
    -h, --help          Show this help message

EXAMPLES:
    # Full automated setup (with Cloudflare + B2)
    ./podcast.sh setup podcast.example.com

    # Setup on existing server (no new Linode created)
    ./podcast.sh setup --server 192.168.1.100 podcast.example.com

    # Linode-only setup (uses Linode DNS and local storage)
    ./podcast.sh setup --linode-only podcast.example.com

    # Setup with custom region
    ./podcast.sh setup -r us-west podcast.example.com

    # Generate files only (for existing server)
    ./podcast.sh generate podcast.example.com

    # Generate files for Linode-only (local storage)
    ./podcast.sh generate --linode-only podcast.example.com

    # Deploy to server
    ./podcast.sh deploy podcast-setup-20241231-120000

    # Check status
    ./podcast.sh status

PREREQUISITES:
    1. Configure credentials in .secrets.yml:
       - Linode API token (required)
       - Cloudflare API token and Zone ID (optional with --linode-only)
       - B2 account ID and application key (optional with --linode-only)

    2. Generate SSH keys:
       ./setup-ssh.sh

    3. Install and authorize b2 CLI (skip for --linode-only):
       pip install b2
       b2 account authorize

    4. Ensure domain exists in Linode DNS Manager (for --linode-only)

DOCUMENTATION:
    See docs/podcast_setup.md for detailed instructions.
EOF
}

################################################################################
# DNS Provider Availability Check
################################################################################

# Check which DNS providers are available
# Usage: check_dns_providers "base_domain"
# Sets: DNS_CLOUDFLARE_OK, DNS_LINODE_OK
# Returns: 0 if at least one provider is available
check_dns_providers() {
    local base_domain=$1
    DNS_CLOUDFLARE_OK=false
    DNS_LINODE_OK=false

    local linode_token=$(get_linode_token "$PROJECT_ROOT")
    local cf_token=$(get_cloudflare_token "$PROJECT_ROOT")
    local cf_zone_id=$(get_cloudflare_zone_id "$PROJECT_ROOT")

    # Check Cloudflare (use || true to prevent pipefail exits)
    if [ -n "$cf_token" ] && [ -n "$cf_zone_id" ]; then
        if verify_cloudflare_auth "$cf_token" "$cf_zone_id" 2>/dev/null; then
            DNS_CLOUDFLARE_OK=true
        fi
    fi

    # Check Linode DNS (if domain exists in Linode DNS Manager)
    # Use || true because linode_get_domain_id uses grep which fails with pipefail when not found
    if [ -n "$linode_token" ] && [ -n "$base_domain" ]; then
        local domain_id
        domain_id=$(linode_get_domain_id "$linode_token" "$base_domain" 2>/dev/null) || true
        if [ -n "$domain_id" ]; then
            DNS_LINODE_OK=true
        fi
    fi

    # Return success if at least one provider is available
    if $DNS_CLOUDFLARE_OK || $DNS_LINODE_OK; then
        return 0
    else
        return 1
    fi
}

################################################################################
# Status Check
################################################################################

check_status() {
    print_header "NWP Podcast Setup - Status Check"

    if $LINODE_ONLY; then
        echo "Mode: Linode-only (Linode DNS + local storage)"
    else
        echo "Mode: Full (Cloudflare + B2 + Linode)"
    fi
    echo ""

    local all_ok=true

    # Check SSH keys
    echo "SSH Keys:"
    if [ -f "$PROJECT_ROOT/keys/nwp.pub" ]; then
        print_status "OK" "SSH keys found in keys/nwp"
    elif [ -f "$HOME/.ssh/nwp.pub" ]; then
        print_status "OK" "SSH keys found in ~/.ssh/nwp"
    else
        print_status "FAIL" "SSH keys not found (run ./setup-ssh.sh)"
        all_ok=false
    fi

    # Check Linode token
    echo ""
    echo "Linode:"
    local linode_token=$(get_linode_token "$PROJECT_ROOT")
    if [ -n "$linode_token" ]; then
        print_status "OK" "API token configured"
        # Verify token works
        if curl -s -H "Authorization: Bearer $linode_token" \
            "https://api.linode.com/v4/account" | grep -q '"email"'; then
            print_status "OK" "API token valid"
        else
            print_status "WARN" "API token may be invalid"
        fi
    else
        print_status "FAIL" "API token not found in .secrets.yml"
        all_ok=false
    fi

    # Check Cloudflare (skip in Linode-only mode)
    if ! $LINODE_ONLY; then
        echo ""
        echo "Cloudflare:"
        local cf_token=$(get_cloudflare_token "$PROJECT_ROOT")
        local cf_zone=$(get_cloudflare_zone_id "$PROJECT_ROOT")
        local cf_available=false
        if [ -n "$cf_token" ] && [ -n "$cf_zone" ]; then
            print_status "OK" "API token and Zone ID configured"
            if verify_cloudflare_auth "$cf_token" "$cf_zone" 2>/dev/null; then
                print_status "OK" "Credentials valid"
                cf_available=true
            else
                print_status "WARN" "Credentials may be invalid"
            fi
        else
            print_status "FAIL" "Credentials not found in .secrets.yml"
        fi

        # Show Linode DNS as fallback option if Cloudflare is not available
        if ! $cf_available; then
            echo ""
            echo "Linode DNS (fallback):"
            local linode_token=$(get_linode_token "$PROJECT_ROOT")
            if [ -n "$linode_token" ]; then
                print_status "INFO" "Linode API configured - can use Linode DNS as fallback"
                print_info "Add your domain to Linode DNS Manager to enable auto-fallback"
            else
                print_status "FAIL" "Linode API not configured - no DNS fallback available"
                all_ok=false
            fi
        fi
    else
        echo ""
        echo "Cloudflare: (skipped - using Linode DNS)"
        print_status "SKIP" "Not required in --linode-only mode"
    fi

    # Check B2 (skip in Linode-only mode)
    if ! $LINODE_ONLY; then
        echo ""
        echo "Backblaze B2:"
        if command -v b2 &>/dev/null; then
            print_status "OK" "b2 CLI installed"
            if b2 account get &>/dev/null; then
                print_status "OK" "b2 authenticated"
            else
                local b2_id=$(get_b2_account_id "$SCRIPT_DIR")
                if [ -n "$b2_id" ]; then
                    print_status "WARN" "Credentials in .secrets.yml but not authorized"
                    print_info "Run: b2 account authorize"
                else
                    print_status "FAIL" "Not authenticated (run: b2 account authorize)"
                    all_ok=false
                fi
            fi
        else
            print_status "FAIL" "b2 CLI not installed (run: pip install b2)"
            all_ok=false
        fi
    else
        echo ""
        echo "Backblaze B2: (skipped - using local storage)"
        print_status "SKIP" "Not required in --linode-only mode"
    fi

    # Check other tools
    echo ""
    echo "Required Tools:"
    for tool in curl jq openssl docker; do
        if command -v $tool &>/dev/null; then
            print_status "OK" "$tool installed"
        else
            print_status "WARN" "$tool not installed"
        fi
    done

    echo ""
    if $all_ok; then
        print_status "OK" "All prerequisites met - ready for podcast setup!"
        return 0
    else
        print_status "FAIL" "Some prerequisites missing - see above"
        return 1
    fi
}

################################################################################
# Setup Command
################################################################################

do_setup() {
    local domain=$1

    print_header "NWP Podcast Setup"
    echo "Domain: $domain"
    if [ -n "$SERVER_IP" ]; then
        echo "Server: $SERVER_IP (existing)"
    else
        echo "Linode Region: $LINODE_REGION"
    fi
    if $LINODE_ONLY; then
        echo "Mode: Linode-only (Linode DNS + local storage)"
    else
        echo "B2 Region: $B2_REGION"
        echo "Mode: Full (Cloudflare + B2)"
    fi
    echo ""

    # Validate domain format
    if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$ ]]; then
        print_error "Invalid domain format: $domain"
        exit 1
    fi

    # Extract base domain for DNS checks
    local base_domain="${domain#*.}"

    # Auto-detect DNS provider if not in explicit linode-only mode
    if ! $LINODE_ONLY; then
        echo "Checking DNS providers..."
        # Use || true to prevent set -e from exiting; we check the variables below
        check_dns_providers "$base_domain" || true

        if $DNS_CLOUDFLARE_OK; then
            print_status "OK" "Cloudflare DNS available"
        else
            if $DNS_LINODE_OK; then
                print_warning "Cloudflare not available, falling back to Linode DNS"
                print_info "Domain '$base_domain' found in Linode DNS Manager"
                LINODE_ONLY=true
                echo ""
                echo "Switching to Linode-only mode:"
                echo "  - DNS: Linode DNS Manager"
                echo "  - Storage: Local (on VPS)"
                echo ""
            else
                print_error "No DNS provider available"
                print_info "Either configure Cloudflare in .secrets.yml"
                print_info "Or add '$base_domain' to Linode DNS Manager"
                exit 1
            fi
        fi
    fi

    # Check prerequisites
    echo "Checking prerequisites..."
    if ! check_status >/dev/null 2>&1; then
        print_error "Prerequisites not met. Run './podcast.sh status' for details."
        exit 1
    fi
    print_status "OK" "All prerequisites met"
    echo ""

    # Confirm
    if ! $AUTO_CONFIRM; then
        echo "This will create:"
        echo "  - Linode VPS (~\$5/month for Nanode)"
        if $LINODE_ONLY; then
            echo "  - Linode DNS A record"
            echo "  - Local media storage on VPS"
        else
            echo "  - B2 bucket (free tier: 10GB)"
            echo "  - Cloudflare DNS records (free)"
        fi
        echo ""
        if ! ask_yes_no "Continue with setup?" "n"; then
            echo "Aborted."
            exit 0
        fi
    fi

    echo ""

    # Get credentials
    local linode_token=$(get_linode_token "$PROJECT_ROOT")
    local cf_token=""
    local cf_zone_id=""
    if ! $LINODE_ONLY; then
        cf_token=$(get_cloudflare_token "$PROJECT_ROOT")
        cf_zone_id=$(get_cloudflare_zone_id "$PROJECT_ROOT")
    fi

    local base_domain="${domain#*.}"
    local podcast_subdomain="${domain%%.*}"
    local media_domain="${MEDIA_SUBDOMAIN}.${base_domain}"
    local bucket_name="${podcast_subdomain}-media"

    # Track created resources for potential rollback
    local linode_id=""
    local server_ip=""
    local bucket_id=""
    local b2_key_id=""
    local b2_app_key=""
    local dns_podcast_record=""
    local dns_media_record=""

    # Trap for cleanup on error
    cleanup_on_error() {
        print_error "Setup failed! Cleaning up..."
        if [ -n "$linode_id" ]; then
            echo "Deleting Linode $linode_id..."
            delete_linode_instance "$linode_token" "$linode_id" 2>/dev/null || true
        fi
        if ! $LINODE_ONLY && [ -n "$dns_podcast_record" ]; then
            echo "Deleting DNS record..."
            cf_delete_dns_record "$cf_token" "$cf_zone_id" "$dns_podcast_record" 2>/dev/null || true
        fi
        if ! $LINODE_ONLY && [ -n "$dns_media_record" ]; then
            cf_delete_dns_record "$cf_token" "$cf_zone_id" "$dns_media_record" 2>/dev/null || true
        fi
        # Note: B2 bucket/key cleanup is manual since they might have data
        if ! $LINODE_ONLY; then
            print_error "Partial cleanup complete. Check B2 manually if needed."
        else
            print_error "Partial cleanup complete."
        fi
    }
    trap cleanup_on_error ERR

    # Step 1: Create B2 bucket (skip in Linode-only mode)
    if $LINODE_ONLY; then
        print_header "Step 1: Skipping B2 (using local storage)"
        print_status "SKIP" "Using local storage on VPS instead of B2"
    else
        print_header "Step 1: Creating B2 Bucket"
        bucket_id=$(b2_create_bucket "$bucket_name" "allPublic")
        if [ -z "$bucket_id" ]; then
            print_error "Failed to create B2 bucket"
            exit 1
        fi
        print_status "OK" "Bucket created: $bucket_name ($bucket_id)"

        # Enable CORS
        echo "Enabling CORS..."
        b2_enable_cors "$bucket_name" "*" >/dev/null 2>&1 || true
        print_status "OK" "CORS enabled"

        # Create application key
        echo "Creating application key..."
        local key_output=$(b2_create_app_key "$bucket_name" "${podcast_subdomain}-castopod")
        b2_key_id=$(echo "$key_output" | awk '{print $1}')
        b2_app_key=$(echo "$key_output" | awk '{print $2}')
        if [ -z "$b2_key_id" ]; then
            print_error "Failed to create B2 application key"
            exit 1
        fi
        print_status "OK" "Application key created"
    fi

    # Step 2: Create Linode (or use existing server)
    # Find SSH key (needed for both new and existing servers)
    local ssh_key_path="$PROJECT_ROOT/keys/nwp.pub"
    if [ ! -f "$ssh_key_path" ]; then
        ssh_key_path="$HOME/.ssh/nwp.pub"
    fi
    local ssh_key_private="${ssh_key_path%.pub}"

    if [ -n "$SERVER_IP" ]; then
        # Use existing server
        print_header "Step 2: Using Existing Server"
        server_ip="$SERVER_IP"
        print_status "OK" "Using server: $server_ip"
    else
        # Create new Linode instance
        print_header "Step 2: Creating Linode Instance"

        local ssh_public_key=$(cat "$ssh_key_path")

        echo "Creating Linode in $LINODE_REGION..."
        local label="podcast-${podcast_subdomain}-$(date +%Y%m%d)"
        linode_id=$(create_linode_instance "$linode_token" "$label" "$ssh_public_key" "$LINODE_REGION" "g6-nanode-1" "linode/ubuntu22.04")
        if [ -z "$linode_id" ]; then
            print_error "Failed to create Linode instance"
            exit 1
        fi
        print_status "OK" "Instance created: $linode_id (label: $label)"

        # Wait for boot
        echo "Waiting for instance to boot..."
        if ! wait_for_linode "$linode_token" "$linode_id" 300; then
            print_error "Instance failed to boot"
            exit 1
        fi

        # Get IP
        server_ip=$(get_linode_ip "$linode_token" "$linode_id")
        print_status "OK" "Instance IP: $server_ip"
    fi

    # Wait for SSH (shorter timeout for existing servers)
    if [ -n "$SERVER_IP" ]; then
        echo "Checking SSH connectivity..."
        if ! wait_for_ssh "$server_ip" "$ssh_key_private" 30; then
            print_error "SSH not available on $server_ip"
            print_info "Ensure SSH key is authorized on the server"
            exit 1
        fi
    else
        echo "Waiting for SSH (this may take a few minutes)..."
        if ! wait_for_ssh "$server_ip" "$ssh_key_private" 600; then
            print_error "SSH not available"
            exit 1
        fi
    fi
    print_status "OK" "SSH ready"

    # Install Docker on server (check if already installed for existing servers)
    echo "Checking/Installing Docker on server..."
    ssh -i "$ssh_key_private" -o StrictHostKeyChecking=accept-new -o BatchMode=yes \
        root@$server_ip 'bash -s' << 'DOCKER_INSTALL'
set -e
export DEBIAN_FRONTEND=noninteractive

# Check if Docker is already installed
if command -v docker &>/dev/null && docker compose version &>/dev/null; then
    echo "Docker already installed, skipping installation"
else
    echo "Installing Docker..."
    # Update system
    apt-get update
    apt-get install -y ca-certificates curl gnupg

    # Add Docker repo
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list

    # Install Docker
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    echo "Docker installed successfully"
fi

# Create castopod directory
mkdir -p /root/castopod
DOCKER_INSTALL
    print_status "OK" "Docker ready"

    # Step 3: Create DNS records
    if $LINODE_ONLY; then
        print_header "Step 3: Creating Linode DNS Records"

        echo "Creating A record for $domain..."
        dns_podcast_record=$(linode_create_dns_a_for_domain "$linode_token" "$domain" "$server_ip")
        if [ -z "$dns_podcast_record" ] || [[ "$dns_podcast_record" == ERROR* ]]; then
            print_error "Failed to create DNS record for $domain"
            print_info "Ensure $base_domain exists in Linode DNS Manager"
            exit 1
        fi
        print_status "OK" "DNS: $domain -> $server_ip"
    else
        print_header "Step 3: Creating Cloudflare DNS Records"

        echo "Creating A record for $domain..."
        dns_podcast_record=$(cf_upsert_dns_a "$cf_token" "$cf_zone_id" "$domain" "$server_ip" "true")
        print_status "OK" "DNS: $domain -> $server_ip"

        echo "Creating A record for $media_domain..."
        dns_media_record=$(cf_upsert_dns_a "$cf_token" "$cf_zone_id" "$media_domain" "$server_ip" "true")
        print_status "OK" "DNS: $media_domain -> $server_ip"
    fi

    # Step 4: Generate and deploy configuration
    print_header "Step 4: Generating and Deploying Configuration"

    local output_dir="$SCRIPT_DIR/podcast-setup-$(date +%Y%m%d-%H%M%S)"
    local db_password=$(generate_password 24)

    mkdir -p "$output_dir"

    # Generate .env (use local storage version for Linode-only mode)
    if $LINODE_ONLY; then
        generate_castopod_env_local "$domain" "$db_password" > "$output_dir/.env"
        print_status "OK" "Generated .env (local storage)"
    else
        generate_castopod_env "$domain" "$db_password" "$b2_key_id" "$b2_app_key" "$bucket_name" "$B2_REGION" > "$output_dir/.env"
        print_status "OK" "Generated .env"
    fi

    # Generate docker-compose.yml
    generate_castopod_compose "$domain" > "$output_dir/docker-compose.yml"
    print_status "OK" "Generated docker-compose.yml"

    # Generate Caddyfile
    generate_caddyfile "$domain" "admin@${base_domain}" > "$output_dir/Caddyfile"
    print_status "OK" "Generated Caddyfile"

    # Copy to server
    echo "Deploying to server..."
    scp -i "$ssh_key_private" -o BatchMode=yes \
        "$output_dir/.env" "$output_dir/docker-compose.yml" "$output_dir/Caddyfile" \
        root@$server_ip:/root/castopod/

    # Start Castopod
    echo "Starting Castopod..."
    ssh -i "$ssh_key_private" -o BatchMode=yes root@$server_ip << 'START_CASTOPOD'
cd /root/castopod
set -a
source .env
set +a
docker compose pull
docker compose up -d
START_CASTOPOD
    print_status "OK" "Castopod started"

    # Remove error trap since we succeeded
    trap - ERR

    # Save deployment info
    if [ -n "$SERVER_IP" ]; then
        # Existing server mode
        cat > "$output_dir/deployment-info.txt" << EOF
NWP Podcast Deployment Info (Existing Server)
==============================================
Date: $(date)
Domain: $domain
Mode: Existing server (shared)

Server:
  IP: $server_ip
  Type: Shared/Existing

DNS:
  Podcast DNS Record: $dns_podcast_record

Storage: Local (on server)

SSH Access:
  ssh -i ${ssh_key_private} root@${server_ip}

Castopod Setup:
  https://${domain}/admin/install

Note: This podcast is hosted on an existing server.
      Teardown requires manual removal of castopod directory.
EOF
    elif $LINODE_ONLY; then
        cat > "$output_dir/deployment-info.txt" << EOF
NWP Podcast Deployment Info (Linode-only mode)
===============================================
Date: $(date)
Domain: $domain
Mode: Linode-only (local storage)

Linode:
  ID: $linode_id
  IP: $server_ip
  Label: $label
  Region: $LINODE_REGION

DNS (Linode):
  Podcast DNS Record: $dns_podcast_record

Storage: Local (on VPS)

SSH Access:
  ssh -i ${ssh_key_private} root@${server_ip}

Castopod Setup:
  https://${domain}/admin/install

Teardown Command:
  ./podcast.sh teardown $linode_id
EOF
    else
        cat > "$output_dir/deployment-info.txt" << EOF
NWP Podcast Deployment Info
============================
Date: $(date)
Domain: $domain
Media Domain: $media_domain

Linode:
  ID: $linode_id
  IP: $server_ip
  Label: $label
  Region: $LINODE_REGION

B2:
  Bucket: $bucket_name
  Bucket ID: $bucket_id
  Key ID: $b2_key_id

Cloudflare:
  Podcast DNS Record: $dns_podcast_record
  Media DNS Record: $dns_media_record

SSH Access:
  ssh -i ${ssh_key_private} root@${server_ip}

Castopod Setup:
  https://${domain}/admin/install

Teardown Command:
  ./podcast.sh teardown $linode_id
EOF
    fi

    # Final output
    print_header "Setup Complete!"
    echo ""
    echo "Your podcast infrastructure is ready!"
    echo ""
    echo "Server: $server_ip"
    echo "Domain: https://$domain"
    if ! $LINODE_ONLY; then
        echo "Media:  https://$media_domain"
    else
        echo "Storage: Local (on VPS)"
    fi
    echo ""
    echo "SSH Access:"
    echo "  ssh -i $ssh_key_private root@$server_ip"
    echo ""
    echo "Complete Castopod setup at:"
    echo "  https://$domain/admin/install"
    echo ""
    echo "Configuration saved to: $output_dir"
    echo ""
    print_warning "DNS propagation may take a few minutes."
    print_warning "Save deployment-info.txt for teardown reference."

    show_elapsed_time "Podcast Setup"
}

################################################################################
# Generate Command
################################################################################

do_generate() {
    local domain=$1

    print_header "NWP Podcast - Generate Configuration"
    echo "Domain: $domain"
    if $LINODE_ONLY; then
        echo "Mode: Linode-only (local storage)"
    else
        echo "Mode: Full (B2 storage)"
    fi
    echo ""

    # Validate domain format
    if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$ ]]; then
        print_error "Invalid domain format: $domain"
        exit 1
    fi

    local base_domain="${domain#*.}"
    local podcast_subdomain="${domain%%.*}"
    local bucket_name="${podcast_subdomain}-media"
    local output_dir="$SCRIPT_DIR/podcast-setup-$(date +%Y%m%d-%H%M%S)"
    local db_password=$(generate_password 24)

    mkdir -p "$output_dir"

    # Generate .env based on mode
    if $LINODE_ONLY; then
        # Generate .env for local storage
        generate_castopod_env_local "$domain" "$db_password" > "$output_dir/.env"
        print_status "OK" "Generated .env (local storage)"
    else
        # Generate .env with placeholders for B2 credentials
        cat > "$output_dir/.env" << EOF
# Castopod Environment Configuration
# Generated by NWP Podcast Setup
# IMPORTANT: Fill in the B2 credentials before deploying!

# Application
CP_BASEURL="https://${domain}"
CP_ADMIN_GATEWAY="admin"
CP_AUTH_GATEWAY="auth"

# Database
CP_DATABASE_HOSTNAME="mariadb"
CP_DATABASE_NAME="castopod"
CP_DATABASE_USERNAME="castopod"
CP_DATABASE_PASSWORD="${db_password}"
CP_DATABASE_PREFIX="cp_"

# Cache & Sessions
CP_CACHE_HANDLER="redis"
CP_REDIS_HOST="redis"
CP_REDIS_PORT="6379"

# Media Storage (Backblaze B2)
# TODO: Fill in these values from your B2 setup
CP_MEDIA_BASE_URL="https://${MEDIA_SUBDOMAIN}.${base_domain}"
CP_MEDIA_STORAGE_TYPE="s3"
CP_MEDIA_S3_ENDPOINT="https://s3.${B2_REGION}.backblazeb2.com"
CP_MEDIA_S3_KEY="YOUR_B2_KEY_ID"
CP_MEDIA_S3_SECRET="YOUR_B2_APP_KEY"
CP_MEDIA_S3_BUCKET="${bucket_name}"
CP_MEDIA_S3_REGION="${B2_REGION}"

# Performance
CP_MAX_BODY_SIZE="512M"
PHP_MEMORY_LIMIT="512M"
PHP_MAX_EXECUTION_TIME="300"
EOF
        print_status "OK" "Generated .env"
    fi

    # Generate docker-compose.yml
    generate_castopod_compose "$domain" > "$output_dir/docker-compose.yml"
    print_status "OK" "Generated docker-compose.yml"

    # Generate Caddyfile
    generate_caddyfile "$domain" "admin@${base_domain}" > "$output_dir/Caddyfile"
    print_status "OK" "Generated Caddyfile"

    # Generate deployment script
    if $LINODE_ONLY; then
        cat > "$output_dir/deploy.sh" << 'DEPLOY'
#!/bin/bash
set -euo pipefail

echo "Deploying Castopod (local storage mode)..."

# Check for required files
for f in .env docker-compose.yml Caddyfile; do
    if [ ! -f "$f" ]; then
        echo "ERROR: Missing $f"
        exit 1
    fi
done

# Load environment
set -a
source .env
set +a

# Pull latest images
docker compose pull

# Start services
docker compose up -d

# Wait for services
echo "Waiting for services to start..."
sleep 15

# Check status
docker compose ps

echo ""
echo "Castopod is starting up!"
echo "Visit ${CP_BASEURL} to complete setup"
echo ""
echo "First-time setup:"
echo "  1. Create an admin account at ${CP_BASEURL}/admin/install"
echo "  2. Create your first podcast"
echo "  3. Configure podcast settings"
DEPLOY
    else
        cat > "$output_dir/deploy.sh" << 'DEPLOY'
#!/bin/bash
set -euo pipefail

echo "Deploying Castopod..."

# Check for required files
for f in .env docker-compose.yml Caddyfile; do
    if [ ! -f "$f" ]; then
        echo "ERROR: Missing $f"
        exit 1
    fi
done

# Check .env is configured
if grep -q "YOUR_B2_KEY_ID" .env; then
    echo "ERROR: B2 credentials not configured in .env"
    echo "Please fill in CP_MEDIA_S3_KEY and CP_MEDIA_S3_SECRET"
    exit 1
fi

# Load environment
set -a
source .env
set +a

# Pull latest images
docker compose pull

# Start services
docker compose up -d

# Wait for services
echo "Waiting for services to start..."
sleep 15

# Check status
docker compose ps

echo ""
echo "Castopod is starting up!"
echo "Visit ${CP_BASEURL} to complete setup"
echo ""
echo "First-time setup:"
echo "  1. Create an admin account at ${CP_BASEURL}/admin/install"
echo "  2. Create your first podcast"
echo "  3. Configure podcast settings"
DEPLOY
    fi
    chmod +x "$output_dir/deploy.sh"
    print_status "OK" "Generated deploy.sh"

    echo ""
    print_status "OK" "Configuration files generated in: $output_dir"
    echo ""
    echo "Files created:"
    if $LINODE_ONLY; then
        echo "  - .env (environment configuration - local storage)"
    else
        echo "  - .env (environment configuration - EDIT B2 CREDENTIALS)"
    fi
    echo "  - docker-compose.yml (container setup)"
    echo "  - Caddyfile (reverse proxy)"
    echo "  - deploy.sh (deployment script)"
    echo ""
    echo "Next steps:"
    if $LINODE_ONLY; then
        echo "  1. Copy files to your server"
        echo "  2. Run ./deploy.sh on the server"
    else
        echo "  1. Edit $output_dir/.env with your B2 credentials"
        echo "  2. Copy files to your server"
        echo "  3. Run ./deploy.sh on the server"
    fi

    show_elapsed_time "Configuration Generation"
}

################################################################################
# Deploy Command
################################################################################

do_deploy() {
    local dir=$1

    if [ ! -d "$dir" ]; then
        print_error "Directory not found: $dir"
        exit 1
    fi

    print_header "NWP Podcast - Deploy to Server"
    echo "Configuration: $dir"
    echo ""

    # Check for required files
    for f in .env docker-compose.yml Caddyfile; do
        if [ ! -f "$dir/$f" ]; then
            print_error "Missing required file: $dir/$f"
            exit 1
        fi
    done

    # Read server IP from deployment-info.txt if it exists
    local server_ip=""
    if [ -f "$dir/deployment-info.txt" ]; then
        server_ip=$(grep "IP:" "$dir/deployment-info.txt" | head -1 | awk '{print $2}')
    fi

    if [ -z "$server_ip" ]; then
        read -p "Enter server IP address: " server_ip
    fi

    # Find SSH key
    local ssh_key="$PROJECT_ROOT/keys/nwp"
    if [ ! -f "$ssh_key" ]; then
        ssh_key="$HOME/.ssh/nwp"
    fi
    if [ ! -f "$ssh_key" ]; then
        read -p "Enter SSH key path: " ssh_key
    fi

    echo "Deploying to $server_ip..."

    # Ensure directory exists
    ssh -i "$ssh_key" -o BatchMode=yes root@$server_ip "mkdir -p /root/castopod"

    # Copy files
    scp -i "$ssh_key" -o BatchMode=yes \
        "$dir/.env" "$dir/docker-compose.yml" "$dir/Caddyfile" \
        root@$server_ip:/root/castopod/

    print_status "OK" "Files copied"

    # Start containers
    echo "Starting containers..."
    ssh -i "$ssh_key" -o BatchMode=yes root@$server_ip << 'DEPLOY_SCRIPT'
cd /root/castopod
set -a
source .env
set +a
docker compose pull
docker compose up -d
echo ""
docker compose ps
DEPLOY_SCRIPT

    print_status "OK" "Deployment complete"

    # Get domain from .env
    local domain=$(grep "CP_BASEURL" "$dir/.env" | cut -d'"' -f2 | sed 's|https://||')

    echo ""
    echo "Castopod is now running!"
    echo "Complete setup at: https://$domain/admin/install"

    show_elapsed_time "Deployment"
}

################################################################################
# Teardown Command
################################################################################

do_teardown() {
    local linode_id=$1

    print_header "NWP Podcast - Teardown Infrastructure"
    print_warning "This will permanently delete resources!"
    echo ""

    local linode_token=$(get_linode_token "$PROJECT_ROOT")
    if [ -z "$linode_token" ]; then
        print_error "Linode token not found"
        exit 1
    fi

    # Get Linode info
    local linode_info=$(curl -s -H "Authorization: Bearer $linode_token" \
        "https://api.linode.com/v4/linode/instances/$linode_id" 2>/dev/null)

    if echo "$linode_info" | grep -q '"errors"'; then
        print_error "Linode $linode_id not found"
        exit 1
    fi

    local label=$(echo "$linode_info" | grep -o '"label":"[^"]*"' | cut -d'"' -f4)
    local ip=$(echo "$linode_info" | grep -o '"ipv4":\["[^"]*"' | cut -d'"' -f4)

    echo "Linode to delete:"
    echo "  ID: $linode_id"
    echo "  Label: $label"
    echo "  IP: $ip"
    echo ""

    if ! $AUTO_CONFIRM; then
        if ! ask_yes_no "Delete this Linode instance?" "n"; then
            echo "Aborted."
            exit 0
        fi
    fi

    echo ""
    echo "Deleting Linode..."
    if delete_linode_instance "$linode_token" "$linode_id"; then
        print_status "OK" "Linode deleted"
    else
        print_error "Failed to delete Linode"
    fi

    echo ""
    print_warning "Note: B2 bucket and Cloudflare DNS records were NOT deleted."
    echo "To fully clean up:"
    echo "  - Delete B2 bucket: b2 bucket delete <bucket-name>"
    echo "  - Delete DNS records via Cloudflare dashboard"

    show_elapsed_time "Teardown"
}

################################################################################
# Main
################################################################################

# Parse arguments
COMMAND=""
ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        -r|--region)
            LINODE_REGION="$2"
            shift 2
            ;;
        -m|--media)
            MEDIA_SUBDOMAIN="$2"
            shift 2
            ;;
        -b|--b2-region)
            B2_REGION="$2"
            shift 2
            ;;
        -s|--server)
            SERVER_IP="$2"
            shift 2
            ;;
        -l|--linode-only)
            LINODE_ONLY=true
            shift
            ;;
        -y|--yes)
            AUTO_CONFIRM=true
            shift
            ;;
        -v|--verbose)
            DEBUG=true
            shift
            ;;
        setup|generate|deploy|teardown|status)
            COMMAND="$1"
            shift
            ;;
        *)
            ARGS+=("$1")
            shift
            ;;
    esac
done

# Execute command
case "$COMMAND" in
    setup)
        if [ ${#ARGS[@]} -lt 1 ]; then
            print_error "Usage: ./podcast.sh setup <domain>"
            exit 1
        fi
        do_setup "${ARGS[0]}"
        ;;
    generate)
        if [ ${#ARGS[@]} -lt 1 ]; then
            print_error "Usage: ./podcast.sh generate <domain>"
            exit 1
        fi
        do_generate "${ARGS[0]}"
        ;;
    deploy)
        if [ ${#ARGS[@]} -lt 1 ]; then
            print_error "Usage: ./podcast.sh deploy <directory>"
            exit 1
        fi
        do_deploy "${ARGS[0]}"
        ;;
    teardown)
        if [ ${#ARGS[@]} -lt 1 ]; then
            print_error "Usage: ./podcast.sh teardown <linode_id>"
            exit 1
        fi
        do_teardown "${ARGS[0]}"
        ;;
    status)
        check_status
        ;;
    "")
        show_help
        exit 0
        ;;
    *)
        print_error "Unknown command: $COMMAND"
        show_help
        exit 1
        ;;
esac
