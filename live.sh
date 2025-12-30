#!/bin/bash
set -euo pipefail

################################################################################
# NWP Live Server Provisioning
#
# Automatically provision live test servers at sitename.nwpcode.org
#
# Usage: ./live.sh [OPTIONS] <sitename>
################################################################################

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Source shared libraries
source "$SCRIPT_DIR/lib/ui.sh"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/linode.sh"

################################################################################
# Help
################################################################################

show_help() {
    cat << EOF
${BOLD}NWP Live Server Provisioning${NC}

${BOLD}USAGE:${NC}
    ./live.sh [OPTIONS] <sitename>

    Note: This script deploys from the staging site to a live server.
    The live URL uses the base name: mysite.nwpcode.org (not mysite_stg)
    Both 'pl live mysite' and 'pl live mysite_stg' deploy mysite_stg.
    If staging is in dev mode, it will be switched to prod mode first.

${BOLD}OPTIONS:${NC}
    -h, --help              Show this help message
    -d, --debug             Enable debug output
    -y, --yes               Auto-confirm prompts
    --delete                Delete live server
    --type=TYPE             Server type: dedicated, shared, temporary
    --expires=DAYS          Days until auto-delete (temporary only)
    --status                Show live server status
    --ssh                   SSH into the live server

${BOLD}EXAMPLES:${NC}
    ./live.sh nwp                      # Deploy on shared GitLab server (default)
    ./live.sh --type=dedicated nwp     # Provision dedicated Linode
    ./live.sh --type=temporary nwp     # Temporary (7 days)
    ./live.sh --delete nwp             # Delete live server
    ./live.sh --status nwp             # Show status
    ./live.sh --ssh nwp                # SSH to server

${BOLD}SERVER TYPES:${NC}
    shared       Deploy on existing GitLab server (default, cost-effective)
    dedicated    One Linode per site (production-like)
    temporary    Auto-delete after N days (PR reviews)

${BOLD}RESULT:${NC}
    Creates: https://sitename.nwpcode.org

EOF
}

################################################################################
# Site Name Helpers
################################################################################

# Get base site name (without env suffix)
get_base_name() {
    local site=$1
    # Remove _stg or _prod suffix
    echo "$site" | sed -E 's/_(stg|prod)$//'
}

# Get staging site name from base or any variant
get_stg_name() {
    local site=$1
    local base=$(get_base_name "$site")
    echo "${base}_stg"
}

# Check if site is in production mode
# Returns 0 if in prod mode, 1 if in dev mode
is_prod_mode() {
    local sitename=$1

    if [ ! -d "$sitename" ]; then
        return 1
    fi

    local original_dir=$(pwd)
    cd "$sitename" || return 1

    # Check CSS preprocessing setting - 1 means prod mode
    local css_preprocess=$(ddev drush config:get system.performance css.preprocess 2>/dev/null | grep -oP "'\K[^']+")

    cd "$original_dir"

    if [ "$css_preprocess" == "1" ] || [ "$css_preprocess" == "true" ]; then
        return 0  # Is in prod mode
    else
        return 1  # Is in dev mode
    fi
}

# Ensure site is in production mode before deployment
ensure_prod_mode() {
    local sitename=$1

    print_info "Checking if $sitename is in production mode..."

    if is_prod_mode "$sitename"; then
        print_status "OK" "$sitename is already in production mode"
        return 0
    fi

    print_warning "$sitename is in development mode"
    print_info "Switching to production mode..."

    # Run make.sh -py to switch to prod mode with auto-confirm
    if "${SCRIPT_DIR}/make.sh" -py "$sitename"; then
        print_status "OK" "$sitename switched to production mode"
        return 0
    else
        print_error "Failed to switch $sitename to production mode"
        return 1
    fi
}

################################################################################
# Configuration
################################################################################

# Get base domain from cnwp.yml
get_base_domain() {
    local cnwp_file="${SCRIPT_DIR}/cnwp.yml"

    if [ -f "$cnwp_file" ]; then
        awk '
            /^settings:/ { in_settings = 1; next }
            in_settings && /^[a-zA-Z]/ && !/^  / { in_settings = 0 }
            in_settings && /^  url:/ {
                sub("^  url: *", "")
                gsub(/["'"'"']/, "")
                print
                exit
            }
        ' "$cnwp_file"
    fi
}

# Get Linode domain ID for the base domain
get_domain_id() {
    local base_domain="$1"
    local token="$2"

    local response=$(curl -s -H "Authorization: Bearer $token" \
        "https://api.linode.com/v4/domains")

    # Use jq if available, otherwise fall back to grep/awk
    if command -v jq &> /dev/null; then
        echo "$response" | jq -r ".data[] | select(.domain == \"${base_domain}\") | .id"
    else
        # Parse JSON with awk - find domain and extract corresponding id
        echo "$response" | tr ',' '\n' | tr '{' '\n' | \
            awk -v domain="$base_domain" '
                /"id":/ { gsub(/[^0-9]/, ""); id = $0 }
                /"domain":/ && $0 ~ domain { print id; exit }
            '
    fi
}

# Get StackScript ID
get_stackscript_id() {
    local token="$1"
    local script_name="${2:-NWP Server Setup}"

    local response=$(curl -s -H "Authorization: Bearer $token" \
        "https://api.linode.com/v4/linode/stackscripts?is_public=false")

    echo "$response" | grep -o "\"id\":[0-9]*,\"username\":\"[^\"]*\",\"label\":\"${script_name}\"" | \
        grep -o '"id":[0-9]*' | cut -d: -f2 | head -1
}

################################################################################
# Live Server Functions
################################################################################

# Check if live server exists
live_exists() {
    local sitename="$1"
    local base_domain=$(get_base_domain)
    local domain="${sitename}.${base_domain}"

    # Check DNS
    if host "$domain" > /dev/null 2>&1; then
        return 0
    fi

    return 1
}

# Get live server IP from cnwp.yml
get_live_ip() {
    local sitename="$1"
    local cnwp_file="${SCRIPT_DIR}/cnwp.yml"

    if [ -f "$cnwp_file" ]; then
        awk -v site="$sitename" '
            /^sites:/ { in_sites = 1; next }
            in_sites && /^[a-zA-Z]/ && !/^  / { in_sites = 0 }
            in_sites && $0 ~ "^  " site ":" { in_site = 1; next }
            in_site && /^  [a-zA-Z]/ && !/^    / { in_site = 0 }
            in_site && /^    live:/ { in_live = 1; next }
            in_live && /^    [a-zA-Z]/ && !/^      / { in_live = 0 }
            in_live && /^      server_ip:/ {
                sub("^      server_ip: *", "")
                gsub(/["'"'"']/, "")
                print
                exit
            }
        ' "$cnwp_file"
    fi
}

# Show live server status
live_status() {
    local sitename="$1"
    local base_domain=$(get_base_domain)
    local domain="${sitename}.${base_domain}"

    print_header "Live Server Status: $sitename"

    # Check cnwp.yml for config
    local server_ip=$(get_live_ip "$sitename")

    if [ -n "$server_ip" ]; then
        print_status "OK" "Configured in cnwp.yml"
        echo "  IP: ${server_ip}"
        echo "  Domain: https://${domain}"

        # Check if DNS resolves
        if host "$domain" > /dev/null 2>&1; then
            print_status "OK" "DNS resolves"
        else
            print_warning "DNS not resolving yet"
        fi

        # Check if accessible
        if curl -s --max-time 5 "https://${domain}" > /dev/null 2>&1; then
            print_status "OK" "Site is accessible via HTTPS"
        elif curl -s --max-time 5 "http://${domain}" > /dev/null 2>&1; then
            print_warning "Site accessible via HTTP only (no SSL)"
        else
            print_warning "Site not responding"
        fi

        # Check SSH
        if ssh -o BatchMode=yes -o ConnectTimeout=5 "root@${server_ip}" exit 2>/dev/null; then
            print_status "OK" "SSH accessible"
        else
            print_warning "SSH not accessible"
        fi
    else
        print_info "No live server configured for $sitename"
    fi
}

# SSH into live server
live_ssh() {
    local sitename="$1"
    local server_ip=$(get_live_ip "$sitename")

    if [ -z "$server_ip" ]; then
        # Try GitLab server as fallback for shared sites
        local base_domain=$(get_base_domain)
        local gitlab_host="git.${base_domain}"
        print_info "Connecting to shared server ($gitlab_host)..."
        ssh "gitlab@${gitlab_host}"
        return $?
    fi

    # Determine SSH user
    local ssh_user="root"
    if ssh -o BatchMode=yes -o ConnectTimeout=2 "gitlab@${server_ip}" exit 2>/dev/null; then
        ssh_user="gitlab"
    fi

    print_info "Connecting to $sitename live server ($server_ip)..."
    ssh "${ssh_user}@${server_ip}"
}

# Add DNS record for the site
add_dns_record() {
    local sitename="$1"
    local ip="$2"
    local token="$3"
    local base_domain=$(get_base_domain)

    print_info "Adding DNS record: ${sitename}.${base_domain} -> ${ip}"

    local domain_id=$(get_domain_id "$base_domain" "$token")

    if [ -z "$domain_id" ]; then
        print_error "Could not find domain ID for $base_domain"
        print_info "Please add DNS record manually:"
        print_info "  ${sitename}.${base_domain} A ${ip}"
        return 1
    fi

    # Check if record already exists
    local records_response=$(curl -s -H "Authorization: Bearer $token" \
        "https://api.linode.com/v4/domains/${domain_id}/records")

    local existing=""
    if command -v jq &> /dev/null; then
        existing=$(echo "$records_response" | jq -r ".data[] | select(.name == \"${sitename}\" and .type == \"A\") | .id" 2>/dev/null)
    else
        existing=$(echo "$records_response" | grep -o "\"name\":\"${sitename}\"" || true)
    fi

    if [ -n "$existing" ]; then
        print_status "OK" "DNS record already exists"
        return 0
    fi

    # Create A record
    local response=$(curl -s -X POST \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        "https://api.linode.com/v4/domains/${domain_id}/records" \
        -d "{
            \"type\": \"A\",
            \"name\": \"${sitename}\",
            \"target\": \"${ip}\",
            \"ttl_sec\": 300
        }")

    if echo "$response" | grep -q '"id"'; then
        print_status "OK" "DNS record created"
        return 0
    elif echo "$response" | grep -q 'already exists'; then
        print_status "OK" "DNS record already exists"
        return 0
    else
        print_error "Failed to create DNS record"
        echo "$response"
        return 1
    fi
}

# Setup nginx vhost on server
setup_nginx_vhost() {
    local sitename="$1"
    local ip="$2"
    local base_domain=$(get_base_domain)
    local domain="${sitename}.${base_domain}"

    # Determine SSH user
    local ssh_user="root"
    if [[ "$ip" == *"git."* ]] || ssh -o BatchMode=yes -o ConnectTimeout=2 "gitlab@${ip}" exit 2>/dev/null; then
        ssh_user="gitlab"
    fi

    # Check if nginx config already exists
    if ssh -o BatchMode=yes "${ssh_user}@${ip}" "test -f /etc/nginx/sites-available/${sitename}" 2>/dev/null; then
        print_status "OK" "Nginx vhost already configured for ${domain}"
        return 0
    fi

    print_info "Configuring nginx for ${domain}..."

    # Create nginx config
    local nginx_config="server {
    listen 80;
    server_name ${domain};
    root /var/www/${sitename};
    index index.php index.html;

    location / {
        try_files \\\$uri /index.php\\\$is_args\\\$args;
    }

    location ~ \\.php\$ {
        fastcgi_pass unix:/var/run/php/php8.2-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \\\$document_root\\\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\\.ht {
        deny all;
    }
}"

    # SSH to server and configure
    ssh -T "${ssh_user}@${ip}" << REMOTE
set -e

# Check if nginx is installed
if ! command -v nginx &> /dev/null; then
    echo "Installing nginx..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq nginx
fi

# Ensure nginx directories exist
sudo mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

# Create site directory
sudo mkdir -p /var/www/${sitename}
sudo chown -R www-data:www-data /var/www/${sitename}

# Create nginx config
sudo tee /etc/nginx/sites-available/${sitename} > /dev/null << 'NGINX'
${nginx_config}
NGINX

# Enable site
sudo ln -sf /etc/nginx/sites-available/${sitename} /etc/nginx/sites-enabled/

# Test and reload nginx
sudo nginx -t && sudo systemctl reload nginx

echo "Nginx configured for ${domain}"
REMOTE

    if [ $? -eq 0 ]; then
        print_status "OK" "Nginx configured"
        return 0
    else
        print_error "Failed to configure nginx"
        return 1
    fi
}

# Setup SSL with certbot
setup_ssl() {
    local sitename="$1"
    local ip="$2"
    local base_domain=$(get_base_domain)
    local domain="${sitename}.${base_domain}"

    # Determine SSH user
    local ssh_user="root"
    if [[ "$ip" == *"git."* ]] || ssh -o BatchMode=yes -o ConnectTimeout=2 "gitlab@${ip}" exit 2>/dev/null; then
        ssh_user="gitlab"
    fi

    # Check if SSL cert already exists
    if ssh -o BatchMode=yes "${ssh_user}@${ip}" "test -d /etc/letsencrypt/live/${domain}" 2>/dev/null; then
        print_status "OK" "SSL certificate already exists for ${domain}"
        return 0
    fi

    print_info "Setting up SSL for ${domain}..."

    # Function to check if DNS resolves (try multiple methods)
    dns_resolves() {
        local check_domain="$1"
        # Try dig with Google DNS first (bypasses local cache)
        if command -v dig &> /dev/null; then
            dig +short "@8.8.8.8" "$check_domain" 2>/dev/null | grep -q .
            return $?
        fi
        # Fall back to host command
        host "$check_domain" > /dev/null 2>&1
    }

    # Check if DNS already resolves
    if dns_resolves "$domain"; then
        print_status "OK" "DNS already propagated"
    else
        # Wait for DNS propagation
        print_info "Waiting for DNS propagation..."
        local attempts=0
        while [ $attempts -lt 30 ]; do
            if dns_resolves "$domain"; then
                print_status "OK" "DNS propagated"
                break
            fi
            sleep 10
            attempts=$((attempts + 1))
            echo -n "."
        done
        echo ""

        if [ $attempts -ge 30 ]; then
            print_warning "DNS not propagated yet, skipping SSL"
            print_info "Run certbot manually later: sudo certbot --nginx -d ${domain}"
            return 0
        fi
    fi

    # Get SSL certificate
    ssh "${ssh_user}@${ip}" "sudo certbot --nginx -d ${domain} --non-interactive --agree-tos --email admin@${base_domain} || true"

    print_status "OK" "SSL setup attempted"
}

# Setup server security hardening
setup_server_security() {
    local sitename="$1"
    local ip="$2"

    print_header "Server Security Hardening"

    # Determine SSH user
    local ssh_user="root"
    if [[ "$ip" == *"git."* ]] || ssh -o BatchMode=yes -o ConnectTimeout=2 "gitlab@${ip}" exit 2>/dev/null; then
        ssh_user="gitlab"
    fi

    # Check and apply security features
    ssh -T "${ssh_user}@${ip}" << 'SECURITY'
set -e

echo "Checking server security..."

# Track what was already configured
ALREADY_DONE=""
NEWLY_APPLIED=""

# 1. Check/Install fail2ban
if dpkg -l fail2ban 2>/dev/null | grep -q "^ii"; then
    ALREADY_DONE="${ALREADY_DONE}fail2ban "
else
    echo "Installing fail2ban..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq fail2ban
    sudo systemctl enable fail2ban
    sudo systemctl start fail2ban
    NEWLY_APPLIED="${NEWLY_APPLIED}fail2ban "
fi

# 2. Check/Configure UFW firewall
if sudo ufw status | grep -q "Status: active"; then
    ALREADY_DONE="${ALREADY_DONE}ufw "
else
    echo "Configuring firewall (ufw)..."
    sudo apt-get install -y -qq ufw
    sudo ufw default deny incoming
    sudo ufw default allow outgoing
    sudo ufw allow ssh
    sudo ufw allow http
    sudo ufw allow https
    sudo ufw --force enable
    NEWLY_APPLIED="${NEWLY_APPLIED}ufw "
fi

# 3. Check/Configure fail2ban for nginx
if [ -f /etc/fail2ban/jail.local ] && grep -q "nginx-http-auth" /etc/fail2ban/jail.local 2>/dev/null; then
    ALREADY_DONE="${ALREADY_DONE}fail2ban-nginx "
else
    echo "Configuring fail2ban for nginx..."
    sudo tee /etc/fail2ban/jail.local > /dev/null << 'F2B'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3

[nginx-http-auth]
enabled = true
port = http,https
filter = nginx-http-auth
logpath = /var/log/nginx/error.log

[nginx-botsearch]
enabled = true
port = http,https
filter = nginx-botsearch
logpath = /var/log/nginx/access.log
maxretry = 2
F2B
    sudo systemctl restart fail2ban
    NEWLY_APPLIED="${NEWLY_APPLIED}fail2ban-nginx "
fi

# 4. Check/Secure SSH configuration
if grep -q "^PasswordAuthentication no" /etc/ssh/sshd_config 2>/dev/null; then
    ALREADY_DONE="${ALREADY_DONE}ssh-hardening "
else
    echo "Hardening SSH configuration..."
    sudo sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    sudo sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
    sudo systemctl reload sshd
    NEWLY_APPLIED="${NEWLY_APPLIED}ssh-hardening "
fi

# 5. Check/Install unattended-upgrades
if dpkg -l unattended-upgrades 2>/dev/null | grep -q "^ii"; then
    ALREADY_DONE="${ALREADY_DONE}auto-updates "
else
    echo "Enabling automatic security updates..."
    sudo apt-get install -y -qq unattended-upgrades
    echo 'APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";' | sudo tee /etc/apt/apt.conf.d/20auto-upgrades > /dev/null
    NEWLY_APPLIED="${NEWLY_APPLIED}auto-updates "
fi

# Summary
echo ""
if [ -n "$ALREADY_DONE" ]; then
    echo "Already configured: $ALREADY_DONE"
fi
if [ -n "$NEWLY_APPLIED" ]; then
    echo "Newly applied: $NEWLY_APPLIED"
fi
if [ -z "$NEWLY_APPLIED" ]; then
    echo "All security features already in place"
fi
SECURITY

    if [ $? -eq 0 ]; then
        print_status "OK" "Server security configured"
        return 0
    else
        print_warning "Some security features may not have been applied"
        return 1
    fi
}

# Update cnwp.yml with live server info
update_cnwp_live() {
    local sitename="$1"
    local ip="$2"
    local linode_id="$3"
    local type="$4"
    local base_domain=$(get_base_domain)
    local domain="${sitename}.${base_domain}"

    print_info "Updating cnwp.yml..."

    # Source yaml-write library
    source "$SCRIPT_DIR/lib/yaml-write.sh"

    # Update site with live configuration
    yaml_set_nested_value "${SCRIPT_DIR}/cnwp.yml" "sites" "$sitename" "live" "enabled" "true"
    yaml_set_nested_value "${SCRIPT_DIR}/cnwp.yml" "sites" "$sitename" "live" "domain" "$domain"
    yaml_set_nested_value "${SCRIPT_DIR}/cnwp.yml" "sites" "$sitename" "live" "server_ip" "$ip"
    yaml_set_nested_value "${SCRIPT_DIR}/cnwp.yml" "sites" "$sitename" "live" "linode_id" "$linode_id"
    yaml_set_nested_value "${SCRIPT_DIR}/cnwp.yml" "sites" "$sitename" "live" "type" "$type"

    print_status "OK" "cnwp.yml updated"
}

# Provision dedicated live server
provision_dedicated() {
    local sitename="$1"
    local auto_yes="${2:-false}"
    local base_domain=$(get_base_domain)
    local domain="${sitename}.${base_domain}"
    local label="live-${sitename}"

    print_header "Provisioning Dedicated Live Server"
    print_info "Domain: ${domain}"

    # Check prerequisites
    local token=$(get_linode_token "$SCRIPT_DIR")
    if [ -z "$token" ]; then
        print_error "Linode API token not found"
        print_info "Add to .secrets.yml:"
        print_info "  linode:"
        print_info "    api_token: your-token-here"
        return 1
    fi

    # Check for SSH key
    local ssh_key_path=""
    if [ -f "${SCRIPT_DIR}/keys/nwp.pub" ]; then
        ssh_key_path="${SCRIPT_DIR}/keys/nwp.pub"
    elif [ -f "$HOME/.ssh/nwp.pub" ]; then
        ssh_key_path="$HOME/.ssh/nwp.pub"
    else
        print_error "SSH public key not found"
        print_info "Run: ./setup-ssh.sh"
        return 1
    fi

    # Check if already exists
    local existing=$(curl -s -H "Authorization: Bearer $token" \
        "https://api.linode.com/v4/linode/instances" | \
        grep -o "\"id\":[0-9]*,\"label\":\"${label}\"" || true)

    if [ -n "$existing" ]; then
        print_warning "Server already exists: $label"
        local instance_id=$(echo "$existing" | grep -o '"id":[0-9]*' | cut -d: -f2)
        local ip=$(get_linode_ip "$token" "$instance_id")
        print_info "IP: $ip"
        print_info "Use --status to check or --delete to remove"
        return 0
    fi

    # Get SSH public key
    local ssh_public_key=$(cat "$ssh_key_path")

    print_info "Creating Linode instance..."

    # Create instance
    local instance_id=$(create_linode_instance "$token" "$label" "$ssh_public_key" "us-east" "g6-nanode-1")

    if [ -z "$instance_id" ]; then
        print_error "Failed to create instance"
        return 1
    fi

    print_status "OK" "Instance created: $instance_id"

    # Wait for instance to boot
    if ! wait_for_linode "$token" "$instance_id" 300; then
        print_error "Instance failed to boot"
        return 1
    fi

    # Get IP address
    local ip=$(get_linode_ip "$token" "$instance_id")
    print_status "OK" "IP Address: $ip"

    # Wait for SSH
    print_info "Waiting for SSH (this may take 2-5 minutes)..."
    if ! wait_for_ssh "$ip" "${ssh_key_path%.pub}" 600; then
        print_warning "SSH not ready yet, server may still be initializing"
        print_info "Try again in a few minutes: ssh root@${ip}"
    fi

    # Add DNS record (has its own idempotency check)
    add_dns_record "$sitename" "$ip" "$token" || true

    # Setup nginx (has its own idempotency check)
    setup_nginx_vhost "$sitename" "$ip" || true

    # Setup SSL (has its own idempotency check)
    setup_ssl "$sitename" "$ip" || true

    # Setup server security (has its own idempotency checks)
    setup_server_security "$sitename" "$ip" || true

    # Check if already in cnwp.yml
    local existing_ip=$(get_live_ip "$sitename")
    if [ -n "$existing_ip" ]; then
        print_status "OK" "cnwp.yml already configured for $sitename"
    else
        # Update cnwp.yml
        update_cnwp_live "$sitename" "$ip" "$instance_id" "dedicated" || true
    fi

    print_header "Live Server Ready"
    print_status "OK" "Server provisioned successfully"
    echo ""
    echo "  Domain:  https://${domain}"
    echo "  IP:      ${ip}"
    echo "  SSH:     ssh root@${ip}"
    echo ""

    # Deploy staging site to live
    print_header "Deploying Site"
    "${SCRIPT_DIR}/stg2live.sh" --no-provision "$sitename" || {
        print_warning "Deployment had issues - you can retry with: pl stg2live $sitename"
    }

    return 0
}

# Provision on shared GitLab server
provision_shared() {
    local sitename="$1"
    local auto_yes="${2:-false}"
    local base_domain=$(get_base_domain)
    local domain="${sitename}.${base_domain}"
    local gitlab_host="git.${base_domain}"

    print_header "Provisioning Shared Live Server"
    print_info "Domain: ${domain}"
    print_info "Host: ${gitlab_host}"

    # Check GitLab server access
    if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "gitlab@${gitlab_host}" exit 2>/dev/null; then
        print_error "Cannot access GitLab server: ${gitlab_host}"
        print_info "Ensure SSH access is configured"
        return 1
    fi

    print_status "OK" "GitLab server accessible"

    # Get GitLab server IP
    local ip=$(ssh -o BatchMode=yes "gitlab@${gitlab_host}" "hostname -I | awk '{print \$1}'" 2>/dev/null)

    if [ -z "$ip" ]; then
        print_error "Could not get GitLab server IP"
        return 1
    fi

    # Check if site directory already exists
    if ssh -o BatchMode=yes "gitlab@${gitlab_host}" "test -d /var/www/${sitename}" 2>/dev/null; then
        print_status "OK" "Site directory already exists: /var/www/${sitename}"
    else
        # Setup on GitLab server
        print_info "Creating site directory on GitLab server..."

        ssh "gitlab@${gitlab_host}" << REMOTE
set -e

# Create site directory
sudo mkdir -p /var/www/${sitename}
sudo chown -R www-data:www-data /var/www/${sitename}

# Create placeholder index
echo "<h1>${sitename}</h1><p>Site coming soon</p>" | sudo tee /var/www/${sitename}/index.html > /dev/null
sudo chown www-data:www-data /var/www/${sitename}/index.html

echo "Site directory created"
REMOTE
        print_status "OK" "Site directory created"
    fi

    # Setup nginx vhost (has its own idempotency check)
    setup_nginx_vhost "$sitename" "$gitlab_host" || true

    # Add DNS record if needed (has its own idempotency check)
    local token=$(get_linode_token "$SCRIPT_DIR")
    if [ -n "$token" ]; then
        add_dns_record "$sitename" "$ip" "$token" || true
    else
        print_info "No Linode token - skipping DNS record (add manually if needed)"
    fi

    # Setup SSL (has its own idempotency check)
    setup_ssl "$sitename" "$gitlab_host" || true

    # Setup server security (has its own idempotency checks)
    setup_server_security "$sitename" "$gitlab_host" || true

    # Check if already in cnwp.yml
    local existing_ip=$(get_live_ip "$sitename")
    if [ -n "$existing_ip" ]; then
        print_status "OK" "cnwp.yml already configured for $sitename"
    else
        # Update cnwp.yml
        update_cnwp_live "$sitename" "$ip" "shared" "shared" || true
    fi

    print_header "Shared Live Server Ready"
    print_status "OK" "Site configured on shared server"
    echo ""
    echo "  Domain:  https://${domain}"
    echo "  Server:  ${gitlab_host}"
    echo ""

    # Deploy staging site to live
    print_header "Deploying Site"
    "${SCRIPT_DIR}/stg2live.sh" --no-provision "$sitename" || {
        print_warning "Deployment had issues - you can retry with: pl stg2live $sitename"
    }

    return 0
}

# Delete live server
live_delete() {
    local sitename="$1"
    local type="${2:-dedicated}"
    local auto_yes="${3:-false}"
    local base_domain=$(get_base_domain)
    local label="live-${sitename}"

    print_header "Deleting Live Server: $sitename"

    local token=$(get_linode_token "$SCRIPT_DIR")

    # Confirm
    if [ "$auto_yes" != "true" ]; then
        print_warning "This will permanently delete the live server for $sitename"
        echo -n "Type 'yes' to confirm: "
        read -r confirm
        if [ "$confirm" != "yes" ]; then
            print_info "Cancelled"
            return 0
        fi
    fi

    case "$type" in
        dedicated)
            if [ -z "$token" ]; then
                print_error "Linode API token required"
                return 1
            fi

            # Find instance by label
            local instance=$(curl -s -H "Authorization: Bearer $token" \
                "https://api.linode.com/v4/linode/instances" | \
                grep -o "\"id\":[0-9]*,\"label\":\"${label}\"" || true)

            if [ -z "$instance" ]; then
                print_info "No Linode found with label: $label"
            else
                local instance_id=$(echo "$instance" | grep -o '"id":[0-9]*' | cut -d: -f2)
                print_info "Deleting Linode instance: $instance_id"
                delete_linode_instance "$token" "$instance_id"
            fi

            # Remove DNS record
            local domain_id=$(get_domain_id "$base_domain" "$token")
            if [ -n "$domain_id" ]; then
                print_info "Removing DNS record..."
                local record_id=$(curl -s -H "Authorization: Bearer $token" \
                    "https://api.linode.com/v4/domains/${domain_id}/records" | \
                    grep -o "\"id\":[0-9]*,\"type\":\"A\",\"name\":\"${sitename}\"" | \
                    grep -o '"id":[0-9]*' | cut -d: -f2 | head -1)

                if [ -n "$record_id" ]; then
                    curl -s -X DELETE -H "Authorization: Bearer $token" \
                        "https://api.linode.com/v4/domains/${domain_id}/records/${record_id}"
                    print_status "OK" "DNS record removed"
                fi
            fi
            ;;
        shared)
            local gitlab_host="git.${base_domain}"
            print_info "Removing site from shared server..."

            ssh "gitlab@${gitlab_host}" << REMOTE || true
sudo rm -f /etc/nginx/sites-enabled/${sitename}
sudo rm -f /etc/nginx/sites-available/${sitename}
sudo rm -rf /var/www/${sitename}
sudo nginx -t && sudo systemctl reload nginx
echo "Site removed"
REMOTE
            ;;
    esac

    # Remove from cnwp.yml
    print_info "Updating cnwp.yml..."
    # TODO: Remove live section from cnwp.yml

    print_status "OK" "Live server deleted"
}

################################################################################
# Main
################################################################################

main() {
    local DEBUG=false
    local DELETE=false
    local TYPE="shared"
    local EXPIRES=7
    local STATUS=false
    local SSH=false
    local YES=false
    local SITENAME=""

    # Parse options
    local OPTIONS=hdy
    local LONGOPTS=help,debug,delete,type:,expires:,status,ssh,yes

    if ! PARSED=$(getopt --options=$OPTIONS --longoptions=$LONGOPTS --name "$0" -- "$@"); then
        show_help
        exit 1
    fi

    eval set -- "$PARSED"

    while true; do
        case "$1" in
            -h|--help) show_help; exit 0 ;;
            -d|--debug) DEBUG=true; shift ;;
            -y|--yes) YES=true; shift ;;
            --delete) DELETE=true; shift ;;
            --type) TYPE="$2"; shift 2 ;;
            --expires) EXPIRES="$2"; shift 2 ;;
            --status) STATUS=true; shift ;;
            --ssh) SSH=true; shift ;;
            --) shift; break ;;
            *) echo "Programming error"; exit 3 ;;
        esac
    done

    # Get sitename
    if [ $# -ge 1 ]; then
        SITENAME="$1"
    else
        print_error "Sitename required"
        show_help
        exit 1
    fi

    # Get base name (for live domain) and staging name (for deployment source)
    local BASE_NAME=$(get_base_name "$SITENAME")
    local STG_NAME=$(get_stg_name "$SITENAME")

    if [ "$SITENAME" != "$BASE_NAME" ]; then
        print_info "Live domain will use: $BASE_NAME (deploying from $STG_NAME)"
    fi

    # For provisioning operations, check and ensure staging is in prod mode
    if [ "$SSH" != "true" ] && [ "$STATUS" != "true" ] && [ "$DELETE" != "true" ]; then
        if [ -d "$STG_NAME" ]; then
            if ! ensure_prod_mode "$STG_NAME"; then
                print_error "Cannot proceed without staging site in production mode"
                exit 1
            fi
        fi
    fi

    # Execute - use BASE_NAME for domain/DNS, STG_NAME for deployment source
    if [ "$SSH" == "true" ]; then
        live_ssh "$BASE_NAME"
    elif [ "$STATUS" == "true" ]; then
        live_status "$BASE_NAME"
    elif [ "$DELETE" == "true" ]; then
        live_delete "$BASE_NAME" "$TYPE" "$YES"
    else
        case "$TYPE" in
            dedicated)
                provision_dedicated "$BASE_NAME" "$YES"
                ;;
            shared)
                provision_shared "$BASE_NAME" "$YES"
                ;;
            temporary)
                provision_dedicated "$BASE_NAME" "$YES"
                print_info "Note: Server will NOT auto-delete. Set a reminder for $EXPIRES days."
                ;;
            *)
                print_error "Unknown type: $TYPE"
                exit 1
                ;;
        esac
    fi
}

main "$@"
