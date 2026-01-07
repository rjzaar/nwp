#!/bin/bash

################################################################################
# linode_deploy.sh - Deploy NWP site from local DDEV to Linode server
################################################################################
#
# This script deploys a local DDEV site to a Linode server:
#   - Exports database and files from local DDEV
#   - Transfers to Linode server
#   - Creates database
#   - Imports data
#   - Configures Nginx
#   - Sets permissions
#   - Optionally sets up SSL
#
# Usage:
#   ./linode_deploy.sh [OPTIONS]
#
# Options:
#   --server IP        Server IP address or hostname (required)
#   --site NAME        Site name (default: current directory name)
#   --target DIR       Target directory: prod, test, or old (default: test)
#   --domain DOMAIN    Domain name for Nginx (default: SERVER_IP)
#   --ssl              Set up SSL with Let's Encrypt
#   --ddev-project DIR Local DDEV project directory (default: current dir)
#   -h, --help         Show this help message
#
# Examples:
#   ./linode_deploy.sh --server 45.33.94.133 --target test
#   ./linode_deploy.sh --server nwp.org --target prod --ssl
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

# Script directory and defaults
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KEYS_DIR="$PROJECT_ROOT/keys"
CURRENT_DIR="$(pwd)"
SITE_NAME="$(basename "$CURRENT_DIR")"
TARGET="test"
DDEV_PROJECT="$CURRENT_DIR"
SSH_USER="nwp"
SSH_KEY="$KEYS_DIR/nwp_linode"
SERVER=""
DOMAIN=""
SETUP_SSL=false

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
        --server)
            SERVER="$2"
            shift 2
            ;;
        --site)
            SITE_NAME="$2"
            shift 2
            ;;
        --target)
            TARGET="$2"
            shift 2
            ;;
        --domain)
            DOMAIN="$2"
            shift 2
            ;;
        --ssl)
            SETUP_SSL=true
            shift
            ;;
        --ddev-project)
            DDEV_PROJECT="$2"
            shift 2
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

print_header "Deploy NWP Site to Linode"

# Validate parameters
if [ -z "$SERVER" ]; then
    print_error "Server IP/hostname is required"
    print_info "Usage: $0 --server SERVER_IP [options]"
    exit 1
fi

if [[ ! "$TARGET" =~ ^(prod|test|old)$ ]]; then
    print_error "Target must be 'prod', 'test', or 'old'"
    exit 1
fi

# Set domain if not specified
if [ -z "$DOMAIN" ]; then
    DOMAIN="$SERVER"
fi

# Check prerequisites
print_info "Checking prerequisites..."

if [ ! -d "$DDEV_PROJECT" ]; then
    print_error "DDEV project directory not found: $DDEV_PROJECT"
    exit 1
fi

if [ ! -f "$SSH_KEY" ]; then
    print_warning "SSH key not found: $SSH_KEY"
    print_info "Will attempt to use default SSH key"
    SSH_KEY=""
else
    SSH_KEY="-i $SSH_KEY"
fi

# Check if DDEV is running
cd "$DDEV_PROJECT"
if ! ddev status > /dev/null 2>&1; then
    print_error "DDEV project is not running in $DDEV_PROJECT"
    print_info "Run: ddev start"
    exit 1
fi

print_success "Prerequisites checked"

# Display deployment configuration
echo ""
echo "Deployment Configuration:"
echo "  Site Name: $SITE_NAME"
echo "  Server: $SERVER"
echo "  Target: /var/www/$TARGET"
echo "  Domain: $DOMAIN"
echo "  SSL: $([ "$SETUP_SSL" = true ] && echo "Yes" || echo "No")"
echo "  DDEV Project: $DDEV_PROJECT"
echo ""

# Confirm deployment
read -p "Continue with deployment? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    print_info "Deployment cancelled"
    exit 0
fi

# Create temporary directory for export
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

print_header "Step 1: Export from DDEV"

# Export database
print_info "Exporting database..."
ddev export-db --file="$TEMP_DIR/${SITE_NAME}.sql" --gzip=false
print_success "Database exported: ${SITE_NAME}.sql"

# Export files
print_info "Exporting files..."
cd "$DDEV_PROJECT"
tar -czf "$TEMP_DIR/${SITE_NAME}-files.tar.gz" \
    --exclude='*/files/css/*' \
    --exclude='*/files/js/*' \
    --exclude='*/files/php/*' \
    --exclude='*/files/styles/*' \
    -C . .
print_success "Files exported: ${SITE_NAME}-files.tar.gz"

# Show export sizes
DB_SIZE=$(du -h "$TEMP_DIR/${SITE_NAME}.sql" | cut -f1)
FILES_SIZE=$(du -h "$TEMP_DIR/${SITE_NAME}-files.tar.gz" | cut -f1)
print_info "Export sizes: Database=$DB_SIZE, Files=$FILES_SIZE"

print_header "Step 2: Transfer to Server"

# Transfer files
print_info "Transferring files to server..."
scp -o StrictHostKeyChecking=no $SSH_KEY \
    "$TEMP_DIR/${SITE_NAME}.sql" \
    "$TEMP_DIR/${SITE_NAME}-files.tar.gz" \
    ${SSH_USER}@${SERVER}:/tmp/
print_success "Files transferred"

print_header "Step 3: Deploy on Server"

# Run deployment commands on server
print_info "Running deployment on server..."

ssh -o StrictHostKeyChecking=no $SSH_KEY ${SSH_USER}@${SERVER} "bash -s" << REMOTE_SCRIPT
set -e

# Colors for remote output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "\${BLUE}Creating database...${NC}"
DB_NAME="${SITE_NAME//-/_}"
DB_USER="${SITE_NAME//-/_}_user"
DB_PASS=\$(openssl rand -base64 24 | tr -d "=+/" | cut -c1-32)

sudo mysql -e "CREATE DATABASE IF NOT EXISTS \\\`\${DB_NAME}\\\`;"
sudo mysql -e "CREATE USER IF NOT EXISTS '\${DB_USER}'@'localhost' IDENTIFIED BY '\${DB_PASS}';"
sudo mysql -e "GRANT ALL PRIVILEGES ON \\\`\${DB_NAME}\\\`.* TO '\${DB_USER}'@'localhost';"
sudo mysql -e "FLUSH PRIVILEGES;"

echo -e "\${GREEN}✓${NC} Database created: \${DB_NAME}"
echo -e "\${BLUE}Database credentials:${NC}"
echo "  Database: \${DB_NAME}"
echo "  User: \${DB_USER}"
echo "  Password: \${DB_PASS}"
echo ""

echo -e "\${BLUE}Importing database...${NC}"
mysql -u "\${DB_USER}" -p"\${DB_PASS}" "\${DB_NAME}" < /tmp/${SITE_NAME}.sql
echo -e "\${GREEN}✓${NC} Database imported"

echo -e "\${BLUE}Extracting files to /var/www/$TARGET...${NC}"
sudo mkdir -p /var/www/$TARGET
sudo tar -xzf /tmp/${SITE_NAME}-files.tar.gz -C /var/www/$TARGET/
echo -e "\${GREEN}✓${NC} Files extracted"

echo -e "\${BLUE}Setting permissions...${NC}"
sudo chown -R www-data:www-data /var/www/$TARGET
sudo find /var/www/$TARGET -type d -exec chmod 755 {} \;
sudo find /var/www/$TARGET -type f -exec chmod 644 {} \;

# Set settings.php permissions
if [ -f "/var/www/$TARGET/web/sites/default/settings.php" ]; then
    sudo chmod 440 /var/www/$TARGET/web/sites/default/settings.php
fi

echo -e "\${GREEN}✓${NC} Permissions set"

# Update settings.php with database credentials
if [ -f "/var/www/$TARGET/web/sites/default/settings.php" ]; then
    echo -e "\${BLUE}Updating database settings...${NC}"

    # Create database settings block
    cat > /tmp/db_settings.php << 'DBEOF'
\$databases['default']['default'] = [
  'database' => '\${DB_NAME}',
  'username' => '\${DB_USER}',
  'password' => '\${DB_PASS}',
  'prefix' => '',
  'host' => 'localhost',
  'port' => '3306',
  'namespace' => 'Drupal\\\\Core\\\\Database\\\\Driver\\\\mysql',
  'driver' => 'mysql',
];
DBEOF

    # Make settings.php writable temporarily
    sudo chmod 640 /var/www/$TARGET/web/sites/default/settings.php

    # Remove old database settings and add new ones
    sudo sed -i '/^\$databases\[/,/^];/d' /var/www/$TARGET/web/sites/default/settings.php
    echo "" | sudo tee -a /var/www/$TARGET/web/sites/default/settings.php > /dev/null
    cat /tmp/db_settings.php | sudo tee -a /var/www/$TARGET/web/sites/default/settings.php > /dev/null

    # Make read-only again
    sudo chmod 440 /var/www/$TARGET/web/sites/default/settings.php

    rm /tmp/db_settings.php
    echo -e "\${GREEN}✓${NC} Database settings updated"
fi

# Create Nginx configuration
echo -e "\${BLUE}Configuring Nginx...${NC}"
sudo tee /etc/nginx/sites-available/${SITE_NAME} > /dev/null << 'NGINXEOF'
server {
    listen 80;
    server_name $DOMAIN;
    root /var/www/$TARGET/web;

    index index.php index.html index.htm;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \\.php\$ {
        include fastcgi_params;
        fastcgi_pass unix:/var/run/php/php8.2-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$fastcgi_path_info;
        fastcgi_intercept_errors on;
    }

    location ~ /\\.ht {
        deny all;
    }

    location = /favicon.ico {
        log_not_found off;
        access_log off;
    }

    location = /robots.txt {
        allow all;
        log_not_found off;
        access_log off;
    }

    location ~* \\.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)\$ {
        expires max;
        log_not_found off;
    }
}
NGINXEOF

# Enable site
sudo ln -sf /etc/nginx/sites-available/${SITE_NAME} /etc/nginx/sites-enabled/
echo -e "\${GREEN}✓${NC} Nginx configured"

# Test and reload Nginx
echo -e "\${BLUE}Testing Nginx configuration...${NC}"
sudo nginx -t
sudo systemctl reload nginx
echo -e "\${GREEN}✓${NC} Nginx reloaded"

# Cleanup
rm /tmp/${SITE_NAME}.sql /tmp/${SITE_NAME}-files.tar.gz

echo ""
echo -e "\${GREEN}═══════════════════════════════════════════════════${NC}"
echo -e "\${GREEN}Deployment Complete!${NC}"
echo -e "\${GREEN}═══════════════════════════════════════════════════${NC}"
echo ""
echo "Site URL: http://$DOMAIN"
echo "Document Root: /var/www/$TARGET/web"
echo ""
echo "Database Credentials:"
echo "  Database: \${DB_NAME}"
echo "  User: \${DB_USER}"
echo "  Password: \${DB_PASS}"
echo ""
echo "Save these credentials in a secure location!"
echo ""

REMOTE_SCRIPT

print_success "Server deployment complete"

# Set up SSL if requested
if [ "$SETUP_SSL" = true ]; then
    print_header "Step 4: Set up SSL"

    print_info "Setting up Let's Encrypt SSL..."
    ssh -o StrictHostKeyChecking=no $SSH_KEY ${SSH_USER}@${SERVER} \
        "sudo certbot --nginx -d $DOMAIN --non-interactive --agree-tos --email admin@$DOMAIN"

    print_success "SSL certificate installed"
    print_info "Site is now accessible at: https://$DOMAIN"
fi

print_header "Deployment Summary"

echo "Site has been successfully deployed!"
echo ""
echo "URLs:"
if [ "$SETUP_SSL" = true ]; then
    echo "  https://$DOMAIN"
else
    echo "  http://$DOMAIN"
fi
echo ""
echo "Server Paths:"
echo "  Document Root: /var/www/$TARGET/web"
echo "  Nginx Config: /etc/nginx/sites-available/${SITE_NAME}"
echo ""
echo "Next Steps:"
echo "  1. Test the site in your browser"
echo "  2. Clear Drupal cache: ssh ${SSH_USER}@${SERVER} 'cd /var/www/$TARGET && drush cr'"
echo "  3. Update DNS if needed to point to: $SERVER"
if [ "$SETUP_SSL" = false ]; then
    echo "  4. Set up SSL: ./linode_deploy.sh --server $SERVER --domain $DOMAIN --ssl"
fi
echo ""

print_success "All done!"
