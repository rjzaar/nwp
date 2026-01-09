#!/bin/bash

################################################################################
# nwp-createsite.sh - Create a new Drupal/OpenSocial site on Linode server
################################################################################
#
# This script runs ON the Linode server to set up a new site.
# Adapted from pleasy's createsite.sh for NWP/OpenSocial.
#
# Usage:
#   ./nwp-createsite.sh [OPTIONS] DOMAIN
#
# Arguments:
#   DOMAIN               Domain name for the site (e.g., example.com)
#
# Options:
#   --db-name NAME       Database name (default: derived from domain)
#   --db-user USER       Database user (default: same as db-name)
#   --db-pass PASS       Database password (default: auto-generated)
#   --webroot DIR        Web root directory (default: /var/www/prod)
#   --enable-ssl         Automatically configure SSL with Let's Encrypt
#   --email EMAIL        Email for SSL certificate
#   -v, --verbose        Verbose output
#   -h, --help           Show this help message
#
################################################################################

set -e  # Exit on error

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

# Default configuration
WEBROOT="/var/www/prod"
DB_NAME=""
DB_USER=""
DB_PASS=""
ENABLE_SSL=false
EMAIL=""
VERBOSE=false

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
        --db-name)
            DB_NAME="$2"
            shift 2
            ;;
        --db-user)
            DB_USER="$2"
            shift 2
            ;;
        --db-pass)
            DB_PASS="$2"
            shift 2
            ;;
        --webroot)
            WEBROOT="$2"
            shift 2
            ;;
        --enable-ssl)
            ENABLE_SSL=true
            shift
            ;;
        --email)
            EMAIL="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            grep "^#" "$0" | grep -v "^#!/" | sed 's/^# //' | sed 's/^#//'
            exit 0
            ;;
        -*)
            print_error "Unknown option: $1"
            exit 1
            ;;
        *)
            DOMAIN="$1"
            shift
            ;;
    esac
done

# Validate domain
if [ -z "$DOMAIN" ]; then
    print_error "Domain is required"
    echo "Usage: $0 [OPTIONS] DOMAIN"
    exit 1
fi

# Derive database name from domain if not specified
if [ -z "$DB_NAME" ]; then
    DB_NAME=$(echo "$DOMAIN" | sed 's/\./_/g' | sed 's/-/_/g')
fi

# Set database user to db name if not specified
if [ -z "$DB_USER" ]; then
    DB_USER="$DB_NAME"
fi

# Generate random password if not specified
if [ -z "$DB_PASS" ]; then
    DB_PASS=$(openssl rand -base64 24 | tr -d "=+/" | cut -c1-32)
fi

print_header "Creating Site: $DOMAIN"

echo "Configuration:"
echo "  Domain: $DOMAIN"
echo "  Webroot: $WEBROOT"
echo "  Database: $DB_NAME"
echo "  DB User: $DB_USER"
echo "  SSL: $([ "$ENABLE_SSL" = true ] && echo "Enabled" || echo "Disabled")"
echo ""

# Create database and user
print_info "Creating database..."
sudo mysql -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\`;"
sudo mysql -e "CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';"
sudo mysql -e "GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';"
sudo mysql -e "FLUSH PRIVILEGES;"
print_success "Database created: $DB_NAME"

# Create Nginx configuration
print_info "Creating Nginx virtual host..."

NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"

sudo tee "$NGINX_CONF" > /dev/null << EOF
server {
    listen 80;
    server_name $DOMAIN www.$DOMAIN;

    root $WEBROOT/web;
    index index.php index.html;

    # Drupal-specific configuration
    location = /favicon.ico {
        log_not_found off;
        access_log off;
    }

    location = /robots.txt {
        allow all;
        log_not_found off;
        access_log off;
    }

    # Very rarely should these ever be accessed outside of your lan
    location ~* \.(txt|log)$ {
        deny all;
    }

    location ~ \..*/.*\.php$ {
        return 403;
    }

    location ~ ^/sites/.*/private/ {
        return 403;
    }

    # Block access to scripts in site files directory
    location ~ ^/sites/[^/]+/files/.*\.php$ {
        deny all;
    }

    # Allow "Well-Known URIs" as per RFC 5785
    location ~* ^/.well-known/ {
        allow all;
    }

    # Block access to "hidden" files and directories
    location ~ (^|/)\. {
        return 403;
    }

    location / {
        try_files \$uri /index.php?\$query_string;
    }

    location @rewrite {
        rewrite ^/(.*)$ /index.php?q=\$1;
    }

    # Don't allow direct access to PHP files in the vendor directory.
    location ~ /vendor/.*\.php$ {
        deny all;
        return 404;
    }

    location ~ '\.php$|^/update.php' {
        fastcgi_split_path_info ^(.+?\.php)(|/.*)$;
        include fastcgi_params;
        fastcgi_param HTTP_PROXY "";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$fastcgi_path_info;
        fastcgi_param QUERY_STRING \$query_string;
        fastcgi_intercept_errors on;
        fastcgi_pass unix:/var/run/php/php8.2-fpm.sock;
    }

    # Fighting with Styles? This little gem is amazing.
    location ~ ^/sites/.*/files/styles/ {
        try_files \$uri @rewrite;
    }

    # Handle private files through Drupal
    location ~ ^(/[a-z\-]+)?/system/files/ {
        try_files \$uri /index.php?\$query_string;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg)$ {
        try_files \$uri @rewrite;
        expires max;
        log_not_found off;
    }

    # Security headers
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; font-src 'self' data:; connect-src 'self'; frame-ancestors 'self';" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;

    # Hide server information
    server_tokens off;
    fastcgi_hide_header X-Generator;
    fastcgi_hide_header X-Powered-By;
    fastcgi_hide_header X-Drupal-Cache;
    fastcgi_hide_header X-Drupal-Dynamic-Cache;

    # SEO: Block staging sites from search engine indexing
    # Detects staging sites by -stg or _stg in domain name
    # This is a CRITICAL layer of defense against accidental indexing
    set \$is_staging 0;
    if (\$host ~* "([-_]stg|staging)") {
        set \$is_staging 1;
    }
    if (\$is_staging = 1) {
        add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet" always;
    }

    # Gzip compression
    gzip on;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml text/javascript application/javascript application/x-javascript application/xml+rss application/json;
}
EOF

# Enable the site
sudo ln -sf "$NGINX_CONF" "/etc/nginx/sites-enabled/$DOMAIN"

# Test Nginx configuration
if sudo nginx -t; then
    print_success "Nginx configuration created"
else
    print_error "Nginx configuration test failed"
    exit 1
fi

# Reload Nginx
sudo systemctl reload nginx
print_success "Nginx reloaded"

# Set up SSL if requested
if [ "$ENABLE_SSL" = true ]; then
    print_info "Setting up SSL certificate..."

    if [ -z "$EMAIL" ]; then
        print_error "Email is required for SSL certificates"
        print_info "Use --email your@email.com"
        exit 1
    fi

    sudo certbot --nginx -d "$DOMAIN" -d "www.$DOMAIN" \
        --non-interactive --agree-tos --email "$EMAIL" \
        --redirect

    print_success "SSL certificate installed"
fi

# Set proper permissions
sudo chown -R www-data:www-data "$WEBROOT"
sudo find "$WEBROOT" -type d -exec chmod 755 {} \;
sudo find "$WEBROOT" -type f -exec chmod 644 {} \;
print_success "Permissions set"

# Deploy appropriate robots.txt based on environment
print_info "Deploying robots.txt..."
if echo "$DOMAIN" | grep -qE "([-_]stg|staging)"; then
    # Staging site - block all crawlers
    print_info "Detected staging site - deploying blocking robots.txt"
    sudo tee "$WEBROOT/robots.txt" > /dev/null << 'EOF'
# robots.txt - Staging Site
# This staging site should NOT be indexed by search engines

User-agent: *
Disallow: /

# Block AI crawlers
User-agent: GPTBot
Disallow: /

User-agent: ClaudeBot
Disallow: /

User-agent: Google-Extended
Disallow: /

User-agent: CCBot
Disallow: /

# Block Internet Archive
User-agent: ia_archiver
Disallow: /
EOF
else
    # Production site - allow crawlers with sitemap
    print_info "Detected production site - deploying optimized robots.txt"
    sudo tee "$WEBROOT/robots.txt" > /dev/null << EOF
# robots.txt - Production Site

User-agent: *

# Allow CSS, JS, and images
Allow: /core/*.css$
Allow: /core/*.js$
Allow: /themes/*.css$
Allow: /themes/*.js$

# Block admin paths
Disallow: /admin/
Disallow: /user/
Disallow: /node/add/

# Crawl rate limiting
Crawl-delay: 1

# Sitemap location
Sitemap: http$([ "$ENABLE_SSL" = true ] && echo "s" || echo "")://$DOMAIN/sitemap.xml
EOF
fi
sudo chown www-data:www-data "$WEBROOT/robots.txt"
sudo chmod 644 "$WEBROOT/robots.txt"
print_success "robots.txt deployed"

# Save database credentials
CREDS_FILE="/home/$(whoami)/.nwp-site-credentials"
echo "" >> "$CREDS_FILE"
echo "# $DOMAIN - Created $(date)" >> "$CREDS_FILE"
echo "DB_NAME_${DB_NAME}='$DB_NAME'" >> "$CREDS_FILE"
echo "DB_USER_${DB_NAME}='$DB_USER'" >> "$CREDS_FILE"
echo "DB_PASS_${DB_NAME}='$DB_PASS'" >> "$CREDS_FILE"
chmod 600 "$CREDS_FILE"
print_success "Credentials saved to: $CREDS_FILE"

print_header "Site Created Successfully!"

echo "Site Information:"
echo "  Domain: $DOMAIN"
echo "  URL: http$([ "$ENABLE_SSL" = true ] && echo "s" || echo "")://$DOMAIN"
echo "  Webroot: $WEBROOT"
echo ""
echo "Database Information:"
echo "  Database: $DB_NAME"
echo "  User: $DB_USER"
echo "  Password: $DB_PASS"
echo ""
echo "Next Steps:"
echo "  1. Import your database:"
echo "     mysql -u $DB_USER -p'$DB_PASS' $DB_NAME < /path/to/dump.sql"
echo ""
echo "  2. Update Drupal settings.php with these credentials"
echo ""
echo "  3. Clear cache:"
echo "     cd $WEBROOT && drush cr"
echo ""
if [ "$ENABLE_SSL" != true ]; then
    echo "  4. (Optional) Set up SSL:"
    echo "     sudo certbot --nginx -d $DOMAIN"
    echo ""
fi
