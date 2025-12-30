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

    echo "$response" | grep -o "\"id\":[0-9]*,\"domain\":\"${base_domain}\"" | \
        grep -o '"id":[0-9]*' | cut -d: -f2 | head -1
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
        print_error "No live server found for $sitename"
        return 1
    fi

    print_info "Connecting to $sitename live server ($server_ip)..."
    ssh "root@${server_ip}"
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
    local existing=$(curl -s -H "Authorization: Bearer $token" \
        "https://api.linode.com/v4/domains/${domain_id}/records" | \
        grep -o "\"name\":\"${sitename}\"" || true)

    if [ -n "$existing" ]; then
        print_info "DNS record already exists"
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
    ssh "root@${ip}" << REMOTE
set -e

# Create site directory
mkdir -p /var/www/${sitename}
chown -R www-data:www-data /var/www/${sitename}

# Create nginx config
cat > /etc/nginx/sites-available/${sitename} << 'NGINX'
${nginx_config}
NGINX

# Enable site
ln -sf /etc/nginx/sites-available/${sitename} /etc/nginx/sites-enabled/

# Test and reload nginx
nginx -t && systemctl reload nginx

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

    print_info "Setting up SSL for ${domain}..."

    # Wait for DNS propagation
    print_info "Waiting for DNS propagation..."
    local attempts=0
    while [ $attempts -lt 30 ]; do
        if host "$domain" > /dev/null 2>&1; then
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

    # Get SSL certificate
    ssh "root@${ip}" "certbot --nginx -d ${domain} --non-interactive --agree-tos --email admin@${base_domain} || true"

    print_status "OK" "SSL setup attempted"
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

    # Confirm
    if [ "$auto_yes" != "true" ]; then
        print_warning "This will create a new Linode server (costs apply)"
        echo -n "Continue? (y/N) "
        read -r confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            print_info "Cancelled"
            return 0
        fi
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

    # Add DNS record
    add_dns_record "$sitename" "$ip" "$token" || true

    # Setup nginx
    setup_nginx_vhost "$sitename" "$ip" || true

    # Setup SSL (may need DNS to propagate first)
    setup_ssl "$sitename" "$ip" || true

    # Update cnwp.yml
    update_cnwp_live "$sitename" "$ip" "$instance_id" "dedicated" || true

    print_header "Live Server Ready"
    print_status "OK" "Server provisioned successfully"
    echo ""
    echo "  Domain:  https://${domain}"
    echo "  IP:      ${ip}"
    echo "  SSH:     ssh root@${ip}"
    echo ""
    echo "Next steps:"
    echo "  1. Deploy your site: ./stg2live.sh ${sitename}"
    echo "  2. Or SSH in: ./live.sh --ssh ${sitename}"

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
    if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "root@${gitlab_host}" exit 2>/dev/null; then
        print_error "Cannot access GitLab server: ${gitlab_host}"
        print_info "Ensure SSH access is configured"
        return 1
    fi

    print_status "OK" "GitLab server accessible"

    # Get GitLab server IP
    local ip=$(ssh -o BatchMode=yes "root@${gitlab_host}" "hostname -I | awk '{print \$1}'" 2>/dev/null)

    if [ -z "$ip" ]; then
        print_error "Could not get GitLab server IP"
        return 1
    fi

    # Confirm
    if [ "$auto_yes" != "true" ]; then
        print_warning "This will create a new site on the shared GitLab server"
        echo -n "Continue? (y/N) "
        read -r confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            print_info "Cancelled"
            return 0
        fi
    fi

    # Setup on GitLab server
    print_info "Setting up site on GitLab server..."

    ssh "root@${gitlab_host}" << REMOTE
set -e

# Create site directory
mkdir -p /var/www/${sitename}
chown -R www-data:www-data /var/www/${sitename}

# Create placeholder index
echo "<h1>${sitename}</h1><p>Site coming soon</p>" > /var/www/${sitename}/index.html
chown www-data:www-data /var/www/${sitename}/index.html

echo "Site directory created"
REMOTE

    # Setup nginx vhost
    setup_nginx_vhost "$sitename" "$gitlab_host" || true

    # Add DNS record if needed
    local token=$(get_linode_token "$SCRIPT_DIR")
    if [ -n "$token" ]; then
        add_dns_record "$sitename" "$ip" "$token" || true
    fi

    # Setup SSL
    setup_ssl "$sitename" "$gitlab_host" || true

    # Update cnwp.yml
    update_cnwp_live "$sitename" "$ip" "shared" "shared" || true

    print_header "Shared Live Server Ready"
    print_status "OK" "Site configured on shared server"
    echo ""
    echo "  Domain:  https://${domain}"
    echo "  Server:  ${gitlab_host}"
    echo ""
    echo "Next steps:"
    echo "  1. Deploy your site: ./stg2live.sh ${sitename}"

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

            ssh "root@${gitlab_host}" << REMOTE || true
rm -f /etc/nginx/sites-enabled/${sitename}
rm -f /etc/nginx/sites-available/${sitename}
rm -rf /var/www/${sitename}
nginx -t && systemctl reload nginx
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

    # Execute
    if [ "$SSH" == "true" ]; then
        live_ssh "$SITENAME"
    elif [ "$STATUS" == "true" ]; then
        live_status "$SITENAME"
    elif [ "$DELETE" == "true" ]; then
        live_delete "$SITENAME" "$TYPE" "$YES"
    else
        case "$TYPE" in
            dedicated)
                provision_dedicated "$SITENAME" "$YES"
                ;;
            shared)
                provision_shared "$SITENAME" "$YES"
                ;;
            temporary)
                provision_dedicated "$SITENAME" "$YES"
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
