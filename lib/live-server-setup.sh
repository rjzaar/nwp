#!/bin/bash

################################################################################
# NWP Live Server Infrastructure Setup Library
#
# Functions for remote server provisioning on Ubuntu 22.04/24.04 Linode instances
# Integrates with GitLab's bundled nginx (uses gitlab-www group)
#
# Dependencies: lib/ui.sh, lib/common.sh
# Usage: source "$SCRIPT_DIR/lib/live-server-setup.sh"
################################################################################

# Guard against multiple sourcing
if [ "${_LIVE_SERVER_SETUP_LOADED:-}" = "1" ]; then
    return 0
fi
_LIVE_SERVER_SETUP_LOADED=1

# Source dependencies
if [ -z "${_UI_LOADED:-}" ]; then
    SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
    source "$SCRIPT_DIR/lib/ui.sh"
fi

################################################################################
# Helper Functions
################################################################################

# Execute command on remote server via SSH
# Usage: remote_ssh "server_ip" "command" ["ssh_user"] ["ssh_key"]
remote_ssh() {
    local server_ip="$1"
    local command="$2"
    local ssh_user="${3:-root}"
    local ssh_key="${4:-}"

    local ssh_opts="-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"

    if [ -n "$ssh_key" ]; then
        ssh_opts="$ssh_opts -i $ssh_key"
    fi

    ssh $ssh_opts "${ssh_user}@${server_ip}" "$command"
}

# Check if a package is installed on remote server
# Usage: remote_package_installed "server_ip" "package_name" ["ssh_user"]
# Returns: 0 if installed, 1 if not
remote_package_installed() {
    local server_ip="$1"
    local package_name="$2"
    local ssh_user="${3:-root}"

    if remote_ssh "$server_ip" "dpkg -l $package_name 2>/dev/null | grep -q '^ii'" "$ssh_user"; then
        return 0
    fi
    return 1
}

# Check if a service is running on remote server
# Usage: remote_service_running "server_ip" "service_name" ["ssh_user"]
# Returns: 0 if running, 1 if not
remote_service_running() {
    local server_ip="$1"
    local service_name="$2"
    local ssh_user="${3:-root}"

    if remote_ssh "$server_ip" "systemctl is-active --quiet $service_name" "$ssh_user"; then
        return 0
    fi
    return 1
}

################################################################################
# Infrastructure Setup Functions
################################################################################

# Install and configure PHP-FPM with correct socket permissions for nginx
# Usage: ensure_php_fpm "server_ip" ["php_version"] ["nginx_user"] ["ssh_user"]
# Returns: 0 on success, 1 on failure
ensure_php_fpm() {
    local server_ip="$1"
    local php_version="${2:-8.2}"
    local nginx_user="${3:-www-data}"
    local ssh_user="${4:-root}"

    print_info "Ensuring PHP-FPM $php_version is installed and configured..."

    # Check if already installed
    if remote_package_installed "$server_ip" "php${php_version}-fpm" "$ssh_user"; then
        print_status "OK" "PHP-FPM $php_version already installed"
    else
        print_info "Installing PHP-FPM $php_version and extensions..."

        # Install PHP-FPM and common extensions
        if ! remote_ssh "$server_ip" "
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq
            apt-get install -y -qq \
                php${php_version}-fpm \
                php${php_version}-mysql \
                php${php_version}-xml \
                php${php_version}-gd \
                php${php_version}-mbstring \
                php${php_version}-curl \
                php${php_version}-zip \
                php${php_version}-intl \
                php${php_version}-opcache \
                > /dev/null 2>&1
        " "$ssh_user"; then
            print_error "Failed to install PHP-FPM $php_version"
            return 1
        fi

        print_status "OK" "PHP-FPM $php_version installed"
    fi

    # Configure socket permissions for nginx
    # If using GitLab's nginx (gitlab-www group), update socket permissions
    print_info "Configuring PHP-FPM socket permissions for nginx user: $nginx_user..."

    local pool_config="/etc/php/${php_version}/fpm/pool.d/www.conf"

    if ! remote_ssh "$server_ip" "
        # Backup original config if not already backed up
        if [ ! -f ${pool_config}.backup ]; then
            cp ${pool_config} ${pool_config}.backup
        fi

        # Update listen.owner and listen.group for nginx compatibility
        sed -i 's/^listen.owner = .*/listen.owner = ${nginx_user}/' ${pool_config}
        sed -i 's/^listen.group = .*/listen.group = ${nginx_user}/' ${pool_config}

        # Ensure socket permissions are correct
        sed -i 's/^;listen.mode = .*/listen.mode = 0660/' ${pool_config}
        sed -i 's/^listen.mode = .*/listen.mode = 0660/' ${pool_config}

        # Restart PHP-FPM to apply changes
        systemctl restart php${php_version}-fpm
        systemctl enable php${php_version}-fpm
    " "$ssh_user"; then
        print_error "Failed to configure PHP-FPM socket permissions"
        return 1
    fi

    # Verify service is running
    if remote_service_running "$server_ip" "php${php_version}-fpm" "$ssh_user"; then
        print_status "OK" "PHP-FPM $php_version running with correct socket permissions"
        return 0
    else
        print_error "PHP-FPM $php_version is not running"
        return 1
    fi
}

# Install and configure MariaDB
# Usage: ensure_mariadb "server_ip" ["ssh_user"]
# Returns: 0 on success, 1 on failure
ensure_mariadb() {
    local server_ip="$1"
    local ssh_user="${2:-root}"

    print_info "Ensuring MariaDB is installed and configured..."

    # Check if already installed
    if remote_package_installed "$server_ip" "mariadb-server" "$ssh_user"; then
        print_status "OK" "MariaDB already installed"
    else
        print_info "Installing MariaDB server..."

        if ! remote_ssh "$server_ip" "
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq
            apt-get install -y -qq mariadb-server mariadb-client > /dev/null 2>&1
        " "$ssh_user"; then
            print_error "Failed to install MariaDB"
            return 1
        fi

        print_status "OK" "MariaDB installed"
    fi

    # Ensure service is running
    if ! remote_service_running "$server_ip" "mariadb" "$ssh_user"; then
        print_info "Starting MariaDB service..."

        if ! remote_ssh "$server_ip" "
            systemctl start mariadb
            systemctl enable mariadb
        " "$ssh_user"; then
            print_error "Failed to start MariaDB service"
            return 1
        fi
    fi

    # Verify service is running
    if remote_service_running "$server_ip" "mariadb" "$ssh_user"; then
        print_status "OK" "MariaDB running"
        return 0
    else
        print_error "MariaDB is not running"
        return 1
    fi
}

# Create database, user, and grants for a site
# Usage: create_site_database "server_ip" "site_name" "db_password" ["ssh_user"]
# Returns: 0 on success, 1 on failure
# Note: Database name and user derived from site_name (hyphens converted to underscores)
create_site_database() {
    local server_ip="$1"
    local site_name="$2"
    local db_password="$3"
    local ssh_user="${4:-root}"

    # Sanitize site name for database (replace hyphens with underscores)
    local db_name="${site_name//-/_}"
    local db_user="${db_name}_user"

    print_info "Creating database for site: $site_name"
    print_info "Database: $db_name, User: $db_user"

    # Create database and user
    if ! remote_ssh "$server_ip" "
        # Create database if it doesn't exist
        mysql -e \"CREATE DATABASE IF NOT EXISTS \\\`${db_name}\\\`;\" 2>/dev/null || {
            echo 'Failed to create database' >&2
            exit 1
        }

        # Create user if it doesn't exist (or update password if exists)
        mysql -e \"CREATE USER IF NOT EXISTS '${db_user}'@'localhost' IDENTIFIED BY '${db_password}';\" 2>/dev/null || {
            # User exists, update password
            mysql -e \"ALTER USER '${db_user}'@'localhost' IDENTIFIED BY '${db_password}';\" 2>/dev/null
        }

        # Grant privileges
        mysql -e \"GRANT ALL PRIVILEGES ON \\\`${db_name}\\\`.* TO '${db_user}'@'localhost';\" 2>/dev/null || {
            echo 'Failed to grant privileges' >&2
            exit 1
        }

        # Flush privileges
        mysql -e \"FLUSH PRIVILEGES;\" 2>/dev/null || {
            echo 'Failed to flush privileges' >&2
            exit 1
        }
    " "$ssh_user"; then
        print_error "Failed to create database and user"
        return 1
    fi

    print_status "OK" "Database created: $db_name (user: $db_user)"
    return 0
}

# Configure nginx vhost for Drupal site
# Usage: configure_nginx_drupal "server_ip" "site_name" "domain" "webroot" ["php_version"] ["ssh_user"]
# Returns: 0 on success, 1 on failure
configure_nginx_drupal() {
    local server_ip="$1"
    local site_name="$2"
    local domain="$3"
    local webroot="${4:-web}"
    local php_version="${5:-8.2}"
    local ssh_user="${6:-root}"

    local site_path="/var/www/${site_name}"
    local document_root="${site_path}/${webroot}"
    local config_file="/etc/nginx/sites-available/${site_name}"

    print_info "Configuring nginx vhost for: $domain"
    print_info "Document root: $document_root"

    # Create nginx configuration
    if ! remote_ssh "$server_ip" "
        # Ensure sites-available and sites-enabled directories exist
        mkdir -p /etc/nginx/sites-available
        mkdir -p /etc/nginx/sites-enabled

        # Create nginx vhost configuration
        cat > ${config_file} << 'NGINXEOF'
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};

    root ${document_root};
    index index.php index.html index.htm;

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
    location ~* \.(txt|log)\$ {
        deny all;
    }

    location ~ \..*/.*\.php\$ {
        return 403;
    }

    location ~ ^/sites/.*/private/ {
        return 403;
    }

    # Block access to scripts in site files directory
    location ~ ^/sites/[^/]+/files/.*\.php\$ {
        deny all;
    }

    # Allow \"Well-Known URIs\" as per RFC 5785
    location ~* ^/.well-known/ {
        allow all;
    }

    # Block access to \"hidden\" files and directories
    location ~ (^|/)\. {
        return 403;
    }

    location / {
        try_files \$uri /index.php?\$query_string;
    }

    location @rewrite {
        rewrite ^ /index.php;
    }

    # Don't allow direct access to PHP files in the vendor directory
    location ~ /vendor/.*\.php\$ {
        deny all;
        return 404;
    }

    # Protect files and directories from prying eyes
    location ~* \.(engine|inc|install|make|module|profile|po|sh|.*sql|theme|twig|tpl(\.php)?|xtmpl|yml)(~|\.sw[op]|\.bak|\.orig|\.save)?\$ |
        ^(\.(?!well-known).*|Entries.*|Repository|Root|Tag|Template|composer\.(json|lock)|web\.config)\$ |
        ^#.*#\$ |
        \.php(~|\.sw[op]|\.bak|\.orig|\.save)\$ {
        deny all;
        return 404;
    }

    location ~ '\.php\$|^/update.php' {
        fastcgi_split_path_info ^(.+?\.php)(|/.*)\$;
        include fastcgi_params;
        fastcgi_param HTTP_PROXY \"\";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$fastcgi_path_info;
        fastcgi_param QUERY_STRING \$query_string;
        fastcgi_intercept_errors on;
        fastcgi_pass unix:/run/php/php${php_version}-fpm.sock;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)\$ {
        try_files \$uri @rewrite;
        expires max;
        log_not_found off;
    }

    # SEO: Block staging sites from search engine indexing
    # Detects staging sites by -stg, _stg, or "staging" in domain name
    set \$is_staging 0;
    if \(\$host ~* \"([-_]stg|staging)\"\) {
        set \$is_staging 1;
    }
    if \(\$is_staging = 1\) {
        add_header X-Robots-Tag \"noindex, nofollow, noarchive, nosnippet\" always;
    }

    # Sitemap support for production sites
    location = /sitemap.xml {
        try_files \$uri @rewrite;
    }

    # Fighting with Styles? This little gem is amazing.
    location ~ ^/sites/.*/files/styles/ {
        try_files \$uri @rewrite;
    }

    # Handle private files through Drupal
    location ~ ^(/[a-z\-]+)?/system/files/ {
        try_files \$uri /index.php?\$query_string;
    }

    # Enforce clean URLs
    location ~ ^/([a-z_]+/)?(index|update|install|cron|xmlrpc)\.php\$ {
        fastcgi_split_path_info ^(.+?\.php)(|/.*)\$;
        include fastcgi_params;
        fastcgi_param HTTP_PROXY \"\";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$fastcgi_path_info;
        fastcgi_param QUERY_STRING \$query_string;
        fastcgi_intercept_errors on;
        fastcgi_pass unix:/run/php/php${php_version}-fpm.sock;
    }
}
NGINXEOF

        # Enable site by creating symlink
        ln -sf ${config_file} /etc/nginx/sites-enabled/${site_name}

        # Test nginx configuration
        nginx -t 2>&1
    " "$ssh_user"; then
        print_error "Failed to configure nginx vhost"
        return 1
    fi

    # Reload nginx to apply changes
    print_info "Reloading nginx..."

    if ! remote_ssh "$server_ip" "systemctl reload nginx" "$ssh_user"; then
        print_error "Failed to reload nginx"
        return 1
    fi

    print_status "OK" "Nginx vhost configured: $domain"
    return 0
}

################################################################################
# Convenience Functions
################################################################################

# Provision complete LAMP stack for Drupal hosting
# Usage: provision_drupal_stack "server_ip" ["php_version"] ["nginx_user"] ["ssh_user"]
# Returns: 0 on success, 1 on failure
provision_drupal_stack() {
    local server_ip="$1"
    local php_version="${2:-8.2}"
    local nginx_user="${3:-www-data}"
    local ssh_user="${4:-root}"

    print_header "Provisioning Drupal Stack on $server_ip"

    # Install PHP-FPM
    if ! ensure_php_fpm "$server_ip" "$php_version" "$nginx_user" "$ssh_user"; then
        print_error "Failed to provision PHP-FPM"
        return 1
    fi

    # Install MariaDB
    if ! ensure_mariadb "$server_ip" "$ssh_user"; then
        print_error "Failed to provision MariaDB"
        return 1
    fi

    print_status "OK" "Drupal stack provisioned successfully"
    return 0
}

# Check infrastructure readiness for Drupal site
# Usage: check_infrastructure_ready "server_ip" ["php_version"] ["ssh_user"]
# Returns: 0 if ready, 1 if not
check_infrastructure_ready() {
    local server_ip="$1"
    local php_version="${2:-8.2}"
    local ssh_user="${3:-root}"

    local ready=true

    # Check PHP-FPM
    if ! remote_package_installed "$server_ip" "php${php_version}-fpm" "$ssh_user"; then
        print_status "FAIL" "PHP-FPM $php_version not installed"
        ready=false
    elif ! remote_service_running "$server_ip" "php${php_version}-fpm" "$ssh_user"; then
        print_status "FAIL" "PHP-FPM $php_version not running"
        ready=false
    else
        print_status "OK" "PHP-FPM $php_version ready"
    fi

    # Check MariaDB
    if ! remote_package_installed "$server_ip" "mariadb-server" "$ssh_user"; then
        print_status "FAIL" "MariaDB not installed"
        ready=false
    elif ! remote_service_running "$server_ip" "mariadb" "$ssh_user"; then
        print_status "FAIL" "MariaDB not running"
        ready=false
    else
        print_status "OK" "MariaDB ready"
    fi

    # Check nginx
    if ! remote_service_running "$server_ip" "nginx" "$ssh_user"; then
        print_status "WARN" "Nginx not running (may be expected for GitLab bundled nginx)"
    else
        print_status "OK" "Nginx ready"
    fi

    if [ "$ready" = true ]; then
        return 0
    else
        return 1
    fi
}

# Export functions for use in other scripts
export -f remote_ssh
export -f remote_package_installed
export -f remote_service_running
export -f ensure_php_fpm
export -f ensure_mariadb
export -f create_site_database
export -f configure_nginx_drupal
export -f provision_drupal_stack
export -f check_infrastructure_ready
