#!/bin/bash
set -euo pipefail

################################################################################
# NWP Production Server Provisioning Script
#
# Provisions production servers with custom domains, SSL, and backups
#
# Usage: ./produce.sh [OPTIONS] <sitename>
################################################################################

# Get script directory (from symlink location, not resolved target)
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

# Source shared libraries
source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh"

################################################################################
# Helper Functions
################################################################################

get_prod_name() {
    local site=$1
    local base=$(get_base_name "$site")
    echo "${base}-prod"
}

get_prod_config() {
    local sitename="$1"
    local field="$2"

    awk -v site="$sitename" -v field="$field" '
        /^sites:/ { in_sites = 1; next }
        in_sites && /^[a-zA-Z]/ && !/^  / { in_sites = 0 }
        in_sites && $0 ~ "^  " site ":" { in_site = 1; next }
        in_site && /^  [a-zA-Z]/ && !/^    / { in_site = 0 }
        in_site && /^    prod:/ { in_prod = 1; next }
        in_prod && /^    [a-zA-Z]/ && !/^      / { in_prod = 0 }
        in_prod && $0 ~ "^      " field ":" {
            sub("^      " field ": *", "")
            gsub(/["'"'"']/, "")
            print
            exit
        }
    ' "$PROJECT_ROOT/nwp.yml"
}

show_help() {
    cat << EOF
${BOLD}NWP Production Server Provisioning${NC}

${BOLD}USAGE:${NC}
    ./produce.sh [OPTIONS] <sitename>

    Provisions a production server for the site.

${BOLD}OPTIONS:${NC}
    -h, --help              Show this help message
    --delete                Remove production server
    --type TYPE             Linode type (default: g6-standard-2)
    --domain DOMAIN         Custom domain for production

  ${BOLD}Security (P56):${NC}
    --no-firewall           Skip UFW firewall setup
    --no-fail2ban           Skip fail2ban setup
    --no-ssl-hardening      Skip SSL hardening
    --security-only         Run only security hardening steps

  ${BOLD}Performance (P57):${NC}
    --cache TYPE            Cache backend: redis|memcache|none (default: redis)
    --memory MB             Server memory in MB (default: 2048)
    --performance-only      Run only performance optimization steps
    --no-performance        Skip all performance optimization

${BOLD}EXAMPLES:${NC}
    ./produce.sh mysite                    # Provision production server
    ./produce.sh --domain mysite.com mysite   # With custom domain
    ./produce.sh --type g6-standard-4 mysite  # Larger server
    ./produce.sh --delete mysite           # Remove production server

${BOLD}WORKFLOW:${NC}
    1. Provision production server:  pl produce mysite
    2. Deploy to production:         pl stg2prod mysite
    3. View production site:         https://mysite.com

${BOLD}NOTE:${NC}
    Production servers include:
    - Dedicated Linode instance
    - Custom domain support
    - Let's Encrypt SSL
    - Automated backups enabled

EOF
}

################################################################################
# Security Hardening (P56)
################################################################################

# Configure UFW firewall on remote server
# Usage: setup_firewall <server_ip>
setup_firewall() {
    local server_ip="$1"

    print_info "Configuring UFW firewall..."

    ssh "root@${server_ip}" << 'REMOTE_SCRIPT'
        # Install ufw if not present
        apt-get install -y ufw

        # Default policies
        ufw default deny incoming
        ufw default allow outgoing

        # Allow essential services
        ufw allow 22/tcp    # SSH
        ufw allow 80/tcp    # HTTP
        ufw allow 443/tcp   # HTTPS

        # Enable firewall
        ufw --force enable

        # Show status
        ufw status verbose
REMOTE_SCRIPT

    print_success "Firewall configured"
}

# Configure fail2ban intrusion prevention on remote server
# Usage: setup_fail2ban <server_ip>
setup_fail2ban() {
    local server_ip="$1"

    print_info "Configuring fail2ban..."

    ssh "root@${server_ip}" << 'REMOTE_SCRIPT'
        # Install fail2ban
        apt-get install -y fail2ban

        # Create local jail config
        cat > /etc/fail2ban/jail.local << 'EOF'
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
EOF

        # Restart fail2ban
        systemctl restart fail2ban
        systemctl enable fail2ban

        # Show status
        fail2ban-client status
REMOTE_SCRIPT

    print_success "Fail2ban configured"
}

# Harden SSL configuration on remote server
# Usage: harden_ssl <server_ip> <domain>
harden_ssl() {
    local server_ip="$1"
    local domain="$2"

    print_info "Hardening SSL configuration..."

    ssh "root@${server_ip}" << 'REMOTE_SCRIPT'
        # Generate strong DH parameters (if not exists)
        if [[ ! -f /etc/ssl/certs/dhparam.pem ]]; then
            openssl dhparam -out /etc/ssl/certs/dhparam.pem 2048
        fi

        # Create security headers config
        cat > /etc/nginx/snippets/security-headers.conf << 'EOF'
# Security Headers
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Content-Type-Options "nosniff" always;
add_header X-XSS-Protection "1; mode=block" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline';" always;
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
EOF

        # Create SSL params config
        cat > /etc/nginx/snippets/ssl-params.conf << 'EOF'
ssl_protocols TLSv1.2 TLSv1.3;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
ssl_prefer_server_ciphers off;
ssl_dhparam /etc/ssl/certs/dhparam.pem;
ssl_session_timeout 1d;
ssl_session_cache shared:SSL:50m;
ssl_stapling on;
ssl_stapling_verify on;
EOF

        nginx -t && systemctl reload nginx
REMOTE_SCRIPT

    print_success "SSL hardened"
}

################################################################################
# Performance Optimization (P57)
################################################################################

# Configure Redis caching on remote server
# Usage: setup_redis <server_ip>
setup_redis() {
    local server_ip="$1"

    print_info "Setting up Redis cache..."

    ssh "root@${server_ip}" << 'REMOTE_SCRIPT'
        apt-get install -y redis-server

        # Configure Redis
        sed -i 's/^bind .*/bind 127.0.0.1/' /etc/redis/redis.conf
        sed -i 's/^# maxmemory .*/maxmemory 256mb/' /etc/redis/redis.conf
        sed -i 's/^# maxmemory-policy .*/maxmemory-policy allkeys-lru/' /etc/redis/redis.conf

        systemctl restart redis-server
        systemctl enable redis-server

        redis-cli ping
REMOTE_SCRIPT

    print_success "Redis configured"
}

# Configure Memcached on remote server
# Usage: setup_memcache <server_ip>
setup_memcache() {
    local server_ip="$1"

    print_info "Setting up Memcached..."

    ssh "root@${server_ip}" << 'REMOTE_SCRIPT'
        apt-get install -y memcached libmemcached-tools

        # Configure Memcached
        sed -i 's/^-m .*/-m 256/' /etc/memcached.conf
        sed -i 's/^-l .*/-l 127.0.0.1/' /etc/memcached.conf

        systemctl restart memcached
        systemctl enable memcached
REMOTE_SCRIPT

    print_success "Memcached configured"
}

# Tune PHP-FPM for performance on remote server
# Usage: tune_php_fpm <server_ip> [memory_mb]
tune_php_fpm() {
    local server_ip="$1"
    local memory_mb="${2:-2048}"
    local max_children=$(( memory_mb / 64 ))

    print_info "Tuning PHP-FPM (${memory_mb}MB RAM, ${max_children} workers)..."

    ssh "root@${server_ip}" << REMOTE_SCRIPT
        PHP_VERSION=\$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')

        # Update PHP-FPM pool config
        cat > /etc/php/\${PHP_VERSION}/fpm/pool.d/www.conf << 'EOF'
[www]
user = www-data
group = www-data
listen = /run/php/php-fpm.sock
listen.owner = www-data
listen.group = www-data
pm = dynamic
pm.max_children = ${max_children}
pm.start_servers = $(( max_children / 4 ))
pm.min_spare_servers = $(( max_children / 8 ))
pm.max_spare_servers = $(( max_children / 2 ))
pm.max_requests = 500
EOF

        # Enable OPcache
        cat > /etc/php/\${PHP_VERSION}/mods-available/opcache-tuned.ini << 'EOF'
opcache.memory_consumption=256
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=10000
opcache.revalidate_freq=60
opcache.fast_shutdown=1
opcache.enable_cli=0
EOF

        systemctl restart php\${PHP_VERSION}-fpm
REMOTE_SCRIPT

    print_success "PHP-FPM tuned"
}

# Optimize nginx for performance on remote server
# Usage: optimize_nginx <server_ip>
optimize_nginx() {
    local server_ip="$1"

    print_info "Optimizing nginx..."

    ssh "root@${server_ip}" << 'REMOTE_SCRIPT'
        cat > /etc/nginx/conf.d/performance.conf << 'EOF'
# File cache
open_file_cache max=10000 inactive=30s;
open_file_cache_valid 60s;
open_file_cache_min_uses 2;
open_file_cache_errors on;

# Gzip compression
gzip on;
gzip_vary on;
gzip_proxied any;
gzip_comp_level 6;
gzip_types text/plain text/css application/json application/javascript text/xml application/xml text/javascript image/svg+xml;

# Timeouts
client_body_timeout 60;
send_timeout 60;
keepalive_timeout 65;

# Buffer sizes
client_body_buffer_size 128k;
client_max_body_size 100m;
EOF

        # Add static file caching to default site
        cat > /etc/nginx/snippets/static-cache.conf << 'EOF'
location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
    expires 30d;
    add_header Cache-Control "public, immutable";
    access_log off;
}
EOF

        nginx -t && systemctl reload nginx
REMOTE_SCRIPT

    print_success "Nginx optimized"
}

################################################################################
# Main
################################################################################

main() {
    local DELETE=false
    local LINODE_TYPE="g6-standard-2"
    local CUSTOM_DOMAIN=""
    local SITENAME=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help) show_help; exit 0 ;;
            --delete) DELETE=true; shift ;;
            --type) LINODE_TYPE="$2"; shift 2 ;;
            --domain) CUSTOM_DOMAIN="$2"; shift 2 ;;
            --no-firewall) SKIP_FIREWALL=true; shift ;;
            --no-fail2ban) SKIP_FAIL2BAN=true; shift ;;
            --no-ssl-hardening) SKIP_SSL_HARDENING=true; shift ;;
            --security-only) SECURITY_ONLY=true; shift ;;
            --cache) CACHE_TYPE="$2"; shift 2 ;;
            --memory) SERVER_MEMORY_MB="$2"; shift 2 ;;
            --performance-only) PERFORMANCE_ONLY=true; shift ;;
            --no-performance) SKIP_PERFORMANCE=true; shift ;;
            -*) print_error "Unknown option: $1"; exit 1 ;;
            *) SITENAME="$1"; shift ;;
        esac
    done

    if [ -z "$SITENAME" ]; then
        print_error "Sitename required"
        show_help
        exit 1
    fi

    local BASE_NAME=$(get_base_name "$SITENAME")
    local PROD_NAME=$(get_prod_name "$SITENAME")
    local existing_ip=$(get_prod_config "$BASE_NAME" "server_ip")

    if [ "$DELETE" == "true" ]; then
        print_header "Remove Production Server"

        if [ -z "$existing_ip" ]; then
            print_error "No production server configured for $BASE_NAME"
            exit 1
        fi

        local linode_id=$(get_prod_config "$BASE_NAME" "linode_id")
        if [ -n "$linode_id" ]; then
            print_warning "Would delete Linode $linode_id ($existing_ip)"
            print_info "Manual deletion required via Linode dashboard"
            print_info "Then remove prod: section from nwp.yml"
        fi
        exit 0
    fi

    if [ -n "$existing_ip" ]; then
        print_header "Production Server Status"
        local domain=$(get_prod_config "$BASE_NAME" "domain")
        echo -e "${BOLD}Site:${NC}    $BASE_NAME"
        echo -e "${BOLD}IP:${NC}      $existing_ip"
        echo -e "${BOLD}Domain:${NC} ${domain:-not configured}"
        echo ""
        print_info "Production server already provisioned"
        print_info "Deploy with: pl stg2prod $BASE_NAME"
        print_info "Site directory: sites/${BASE_NAME}_prod"
        exit 0
    fi

    print_header "Production Server Provisioning"
    print_warning "Production servers require dedicated resources"
    echo ""
    echo -e "${BOLD}Site:${NC}   $BASE_NAME"
    echo -e "${BOLD}Type:${NC}   $LINODE_TYPE"
    echo -e "${BOLD}Domain:${NC} ${CUSTOM_DOMAIN:-to be configured}"
    echo ""

    # Production server provisioning would go here
    # This is a stub - full implementation would:
    # 1. Create Linode instance
    # 2. Configure DNS (if domain uses Linode)
    # 3. Setup SSL via Let's Encrypt
    # 4. Enable Linode backups
    # 5. Store config in nwp.yml

    local SERVER_IP="${existing_ip}"
    local DOMAIN="${CUSTOM_DOMAIN:-${BASE_NAME}.com}"

    if [[ -z "$SERVER_IP" ]]; then
        print_info "Production server provisioning not yet implemented"
        print_info "For now, use 'pl live' for shared hosting or provision manually"
        echo ""
        print_info "Manual setup steps:"
        echo "  1. Create Linode at dashboard.linode.com"
        echo "  2. Add prod: section to nwp.yml with server_ip"
        echo "  3. Use 'pl stg2prod $BASE_NAME' to deploy"
        exit 0
    fi

    # Security hardening (P56)
    if [[ "${PERFORMANCE_ONLY:-}" != "true" ]]; then
        if [[ "${SKIP_FIREWALL:-}" != "true" ]]; then
            setup_firewall "$SERVER_IP"
        fi

        if [[ "${SKIP_FAIL2BAN:-}" != "true" ]]; then
            setup_fail2ban "$SERVER_IP"
        fi

        if [[ "${SKIP_SSL_HARDENING:-}" != "true" ]]; then
            harden_ssl "$SERVER_IP" "$DOMAIN"
        fi
    fi

    if [[ "${SECURITY_ONLY:-}" == "true" ]]; then
        print_success "Security hardening complete"
        exit 0
    fi

    # Performance optimization (P57)
    if [[ "${SKIP_PERFORMANCE:-}" != "true" ]]; then
        case "${CACHE_TYPE:-redis}" in
            redis) setup_redis "$SERVER_IP" ;;
            memcache) setup_memcache "$SERVER_IP" ;;
            none) print_info "Skipping cache setup" ;;
        esac

        tune_php_fpm "$SERVER_IP" "${SERVER_MEMORY_MB:-2048}"
        optimize_nginx "$SERVER_IP"
    fi

    if [[ "${PERFORMANCE_ONLY:-}" == "true" ]]; then
        print_success "Performance optimization complete"
        exit 0
    fi

    print_success "Production server provisioning complete"
    exit 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
