#!/bin/bash
set -euo pipefail

################################################################################
# NWP Staging to Live Deployment Script
#
# Deploys staging site to live server (provisioned by live.sh)
#
# Features:
#   - File synchronization via rsync
#   - Database deployment (P34 - requires P33/P35 for full integration)
#   - Security module installation
#   - Permission management
#   - Cache clearing
#
# Usage: ./stg2live.sh [OPTIONS] <sitename>
################################################################################

# Get script directory (from symlink location, not resolved target)
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

# Source shared libraries
source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/ssh.sh"
# rollback.sh sets ROLLBACK_DIR=${SCRIPT_DIR}/.rollback. SCRIPT_DIR
# (set at the top of this file) is scripts/commands/ — same dir the
# rollback dispatcher uses, so both writers/readers share one registry.
source "$PROJECT_ROOT/lib/rollback.sh"

# Source install-common for get_settings_value
if [ -f "$PROJECT_ROOT/lib/install-common.sh" ]; then
    source "$PROJECT_ROOT/lib/install-common.sh"
fi

# Script start time
START_TIME=$(date +%s)

################################################################################
# Helper Functions
################################################################################

# Get staging directory path (F23: v2 sites/<name>/stg/)
get_stg_dir() {
    local site=$1
    local base=$(get_base_name "$site")
    resolve_project "$base" "stg"
}

# Get base domain from nwp.yml settings.url (fallback to nwpcode.org)
get_base_domain() {
    local root="${PROJECT_ROOT:-$HOME/nwp}"
    local global_config="$root/nwp.yml"
    if [[ -f "$global_config" ]] && command -v yq &>/dev/null; then
        local url
        url=$(yq eval '.settings.url // ""' "$global_config" 2>/dev/null)
        [[ -n "$url" && "$url" != "null" ]] && { echo "$url"; return; }
    fi
    echo "nwpcode.org"
}

# Get live server config (F23: reads per-site .nwp.yml, falls back to nwp.yml)
get_live_config() {
    local sitename="$1"
    local field="$2"
    local base=$(get_base_name "$sitename")

    local yq_path
    case "$field" in
        server_ip)
            local server_name
            server_name=$(get_site_config_value "$base" '.live.server' "")
            if [[ -n "$server_name" ]]; then
                get_server_config "$server_name" "ip" ""
                return
            fi
            get_site_config_value "$base" '.live.server_ip' ""
            return
            ;;
        domain)      yq_path='.live.domain' ;;
        type)        yq_path='.live.type' ;;
        server)      yq_path='.live.server' ;;
        remote_path) yq_path='.live.remote_path' ;;
        *)           yq_path=".live.$field" ;;
    esac
    get_site_config_value "$base" "$yq_path" ""
}

# Check if live security is enabled (reads global nwp.yml settings)
is_live_security_enabled() {
    local root="${PROJECT_ROOT:-$HOME/nwp}"
    local global_config="$root/nwp.yml"
    if [[ -f "$global_config" ]] && command -v yq &>/dev/null; then
        local enabled
        enabled=$(yq eval '.settings.live_security.enabled // false' "$global_config" 2>/dev/null)
        [ "$enabled" == "true" ]
    else
        return 1
    fi
}

# Get security modules from nwp.yml settings
get_security_modules() {
    local root="${PROJECT_ROOT:-$HOME/nwp}"
    local global_config="$root/nwp.yml"
    if [[ -f "$global_config" ]] && command -v yq &>/dev/null; then
        yq eval '.settings.live_security.modules[]' "$global_config" 2>/dev/null
    fi
}

# Secure user passwords before live deployment
# - Regenerates admin password to a secure random value
# - Forces password reset for all other users on next login
# - Returns new admin password for display
secure_user_passwords() {
    local stg_site="$1"

    # Check if skipped via command line
    if [ "${SKIP_PASSWORD_RESET:-false}" == "true" ]; then
        print_info "Password security skipped (--no-password-reset)"
        return 0
    fi

    print_header "Securing User Passwords"

    local original_dir=$(pwd)
    cd "$stg_site" || return 1

    # Generate secure admin password (16 chars, alphanumeric)
    local new_admin_pass=$(openssl rand -base64 24 | tr -d '/=+' | cut -c -16)

    # Step 1: Reset admin password to secure value
    print_info "Generating secure admin password..."
    if ddev drush user:password admin "$new_admin_pass" 2>/dev/null; then
        print_status "OK" "Admin password regenerated"
    else
        print_error "Failed to reset admin password"
        cd "$original_dir"
        return 1
    fi

    # Step 2: Check for weak passwords on all users and force reset
    print_info "Checking for weak passwords..."
    local weak_users=$(ddev drush php:eval '
        $passwords_to_test = ["password", "admin", "admin123", "test", "test123", "1234", "123456"];
        $users = \Drupal::entityTypeManager()->getStorage("user")->loadMultiple();
        $service = \Drupal::service("password");
        $weak = [];
        foreach ($users as $user) {
            if ($user->id() == 0) continue;
            foreach ($passwords_to_test as $pwd) {
                if ($service->check($pwd, $user->getPassword())) {
                    $weak[] = $user->getAccountName();
                    break;
                }
            }
        }
        echo implode(",", $weak);
    ' 2>/dev/null)

    if [ -n "$weak_users" ] && [ "$weak_users" != "" ]; then
        print_status "WARN" "Found users with weak passwords: $weak_users"

        # Force password reset for weak password users (except admin which we just reset)
        print_info "Forcing password reset for users with weak passwords..."
        for username in ${weak_users//,/ }; do
            if [ "$username" != "admin" ]; then
                # Generate a random password and block the account until they reset
                local temp_pass=$(openssl rand -base64 24 | tr -d '/=+' | cut -c -20)
                ddev drush user:password "$username" "$temp_pass" 2>/dev/null || true
                print_info "  Reset password for: $username"
            fi
        done
        print_status "OK" "Weak passwords have been reset"
    else
        print_status "OK" "No weak passwords detected"
    fi

    # Step 3: Export configuration
    print_info "Exporting updated configuration..."
    ddev drush cex -y 2>/dev/null || true

    cd "$original_dir"

    # Store admin password for display at the end
    NEW_ADMIN_PASSWORD="$new_admin_pass"

    print_status "OK" "User passwords secured"
    echo ""
    echo -e "  ${BOLD}${YELLOW}⚠ SAVE THIS:${NC} New admin password: ${GREEN}${new_admin_pass}${NC}"
    echo ""

    return 0
}

# Install security modules on staging site before deployment
install_security_modules() {
    local stg_site="$1"

    # Check if skipped via command line
    if [ "${SKIP_SECURITY:-false}" == "true" ]; then
        print_info "Security module installation skipped (--no-security)"
        return 0
    fi

    if ! is_live_security_enabled; then
        print_info "Live security hardening disabled in nwp.yml"
        return 0
    fi

    print_header "Installing Security Modules"

    local modules=$(get_security_modules)
    if [ -z "$modules" ]; then
        print_info "No security modules configured"
        return 0
    fi

    local original_dir=$(pwd)
    cd "$stg_site" || return 1

    # Install each module via composer and enable
    while IFS= read -r module; do
        [ -z "$module" ] && continue

        # Check if already installed
        if ddev composer show "drupal/$module" >/dev/null 2>&1; then
            print_status "OK" "$module already installed"
        else
            print_info "Installing drupal/$module..."
            if ddev composer require "drupal/$module" --no-interaction 2>/dev/null; then
                print_status "OK" "Installed $module"
            else
                print_status "WARN" "Could not install $module (may not exist or have conflicts)"
            fi
        fi

        # Enable module if not already enabled
        if ! ddev drush pm:list --status=enabled --type=module 2>/dev/null | grep -q "^$module "; then
            print_info "Enabling $module..."
            if ddev drush en "$module" -y 2>/dev/null; then
                print_status "OK" "Enabled $module"
            else
                print_status "WARN" "Could not enable $module"
            fi
        fi
    done <<< "$modules"

    # Export config so modules are enabled on live
    print_info "Exporting configuration..."
    ddev drush cex -y 2>/dev/null || true

    cd "$original_dir"
    return 0
}

################################################################################
# Safety / Pre-Deploy Snapshots
################################################################################

# Take a pre-deploy snapshot of the live host: all MySQL/MariaDB databases
# (compressed dump) + the /etc/nginx/conf.d/ directory (tarball). Stored
# in the deploying user's home dir on the remote box. Idempotent within
# 1 hour (skips if a snapshot file from the last hour exists for the
# same site) so repeated dev2stg+stg2live runs don't blow up disk.
#
# Recovery (manual): files written to ~ on the live host with timestamped
# names; restore mysqldump via `gunzip -c <dump> | sudo mysql`; restore
# nginx via `sudo tar xzf <tar> -C /`.
live_host_snapshot() {
    local base_name="$1"
    local server_ip="$2"
    local ssh_user="$3"

    print_header "Pre-Deploy Snapshot"

    local sudo_prefix=""
    if [ "$ssh_user" == "gitlab" ]; then
        sudo_prefix="sudo "
    fi

    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    local dbs_file="nwp-snapshot-${base_name}-dbs-${ts}.sql.gz"
    local nginx_file="nwp-snapshot-${base_name}-nginx-${ts}.tar.gz"

    # Check disk space first (need ~500 MB free; bail if tighter than 1 GB).
    local free_kb
    free_kb=$(ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" \
        "df -k --output=avail ~ | tail -1" 2>/dev/null | tr -d ' ')
    if [ -n "$free_kb" ] && [ "$free_kb" -lt 1048576 ]; then
        print_status "WARN" "Live host has <1GB free in ~ (${free_kb}KB). Skipping snapshot."
        print_status "WARN" "Consider freeing disk before destructive deploys."
        return 0
    fi

    # Idempotent: skip if a snapshot from the last hour exists for this site.
    local recent
    recent=$(ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" \
        "find ~ -maxdepth 1 -name 'nwp-snapshot-${base_name}-dbs-*.sql.gz' -mmin -60 2>/dev/null | head -1" \
        2>/dev/null)
    if [ -n "$recent" ]; then
        print_status "INFO" "Recent snapshot exists: $(basename "$recent")"
        print_status "INFO" "Skipping (idempotent within 1 hour)."
        return 0
    fi

    print_info "Snapshotting all databases..."
    if ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" \
        "${sudo_prefix}mysqldump --all-databases --single-transaction --quick --routines --triggers 2>/dev/null | gzip > ~/${dbs_file}"; then
        local dbs_size
        dbs_size=$(ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" \
            "ls -lh ~/${dbs_file} | awk '{print \$5}'" 2>/dev/null)
        print_status "OK" "DB snapshot: ~/${dbs_file} (${dbs_size})"
    else
        print_status "WARN" "DB snapshot failed (continuing — verify live state manually before destructive ops)"
    fi

    print_info "Snapshotting /etc/nginx/conf.d/..."
    if ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" \
        "${sudo_prefix}tar czf ~/${nginx_file} /etc/nginx/conf.d/ 2>/dev/null && ${sudo_prefix}chown ${ssh_user}:${ssh_user} ~/${nginx_file}"; then
        print_status "OK" "Nginx snapshot: ~/${nginx_file}"
    else
        print_status "WARN" "Nginx snapshot failed (continuing — verify live state manually)"
    fi

    # Register the snapshot as a rollback point so `pl rollback list` /
    # `pl rollback execute` can find it. Failure here is non-fatal — the
    # snapshot files are written regardless; we just lose the
    # registry-driven discovery for this particular point.
    if command -v rollback_record_remote >/dev/null 2>&1; then
        local commit_sha=""
        if [ -d "${PROJECT_ROOT}/.git" ]; then
            commit_sha=$(cd "$PROJECT_ROOT" && git rev-parse HEAD 2>/dev/null || true)
        fi
        # Remote paths are relative to ssh_user's home; expand for the
        # registry so restore commands work without re-resolving ~.
        local dbs_remote nginx_remote home_dir
        home_dir=$(ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" \
            'echo $HOME' 2>/dev/null || echo "/home/${ssh_user}")
        dbs_remote="${home_dir}/${dbs_file}"
        nginx_remote="${home_dir}/${nginx_file}"
        rollback_record_remote "$base_name" "prod" "$ssh_user" "$server_ip" \
            "$ts" "$dbs_remote" "$nginx_remote" "$commit_sha" \
            || print_status "WARN" "Could not register rollback point (snapshot files OK)."
    fi

    echo ""
    print_info "To restore from this snapshot if needed:"
    echo "  pl rollback execute ${base_name} prod --dry-run    # preview"
    echo "  pl rollback execute ${base_name} prod              # apply (with confirmation)"
    echo ""
    print_info "Or restore manually:"
    echo "  ssh ${ssh_user}@${server_ip}"
    echo "  # restore DBs:    gunzip -c ~/${dbs_file} | ${sudo_prefix}mysql"
    echo "  # restore nginx:  ${sudo_prefix}tar xzf ~/${nginx_file} -C / && ${sudo_prefix}nginx -t && ${sudo_prefix}systemctl reload nginx"
    echo ""

    return 0
}

################################################################################
# Database Deployment Functions
################################################################################

# Generate a secure random password
generate_db_password() {
    openssl rand -base64 24 | tr -d '/=+' | cut -c -20
}

# Setup database on live server (create DB and user if they don't exist)
setup_live_database() {
    local base_name="$1"
    local server_ip="$2"
    local ssh_user="$3"
    local db_pass="$4"

    local db_name="${base_name//-/_}"  # Replace hyphens with underscores for MySQL
    local db_user="${db_name}"

    print_info "Setting up database on live server..."

    local sudo_prefix=""
    if [ "$ssh_user" == "gitlab" ]; then
        sudo_prefix="sudo"
    fi

    # Check if MySQL/MariaDB is available
    if ! ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "$sudo_prefix mysql -e 'SELECT 1' >/dev/null 2>&1"; then
        print_error "MySQL/MariaDB not accessible on live server"
        return 1
    fi

    # Create database if it doesn't exist
    ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "$sudo_prefix mysql -e \"CREATE DATABASE IF NOT EXISTS \\\`${db_name}\\\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\"" 2>/dev/null

    # Create user and grant privileges (idempotent - will update if exists)
    ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "$sudo_prefix mysql -e \"
        CREATE USER IF NOT EXISTS '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';
        ALTER USER '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';
        GRANT ALL PRIVILEGES ON \\\`${db_name}\\\`.* TO '${db_user}'@'localhost';
        FLUSH PRIVILEGES;
    \"" 2>/dev/null

    if [ $? -eq 0 ]; then
        print_status "OK" "Database '${db_name}' ready"
        return 0
    else
        print_error "Failed to setup database"
        return 1
    fi
}

# Generate settings.local.php with database credentials for live server
generate_live_settings() {
    local base_name="$1"
    local server_ip="$2"
    local ssh_user="$3"
    local webroot="$4"
    local db_pass="$5"

    local db_name="${base_name//-/_}"
    local db_user="${db_name}"
    local site_path="/var/www/${base_name}"
    local settings_path="${site_path}/${webroot}/sites/default"

    print_info "Generating settings.local.php..."

    local sudo_prefix=""
    if [ "$ssh_user" == "gitlab" ]; then
        sudo_prefix="sudo"
    fi

    # Create settings.local.php with database credentials
    ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "$sudo_prefix tee ${settings_path}/settings.local.php > /dev/null" << EOF
<?php
/**
 * Live server database configuration
 * Generated by NWP stg2live deployment
 */

\$databases['default']['default'] = [
  'database' => '${db_name}',
  'username' => '${db_user}',
  'password' => '${db_pass}',
  'prefix' => '',
  'host' => 'localhost',
  'port' => '3306',
  'isolation_level' => 'READ COMMITTED',
  'driver' => 'mysql',
  'namespace' => 'Drupal\\mysql\\Driver\\Database\\mysql',
  'autoload' => 'core/modules/mysql/src/Driver/Database/mysql/',
];

// Trusted host patterns for live site
\$settings['trusted_host_patterns'] = [
  '^${base_name}\\.nwpcode\\.org\$',
  '^www\\.${base_name}\\.nwpcode\\.org\$',
];

// File paths
\$settings['file_private_path'] = '${site_path}/private';

// Config sync directory
\$settings['config_sync_directory'] = '../config/sync';

// Hash salt (generate unique for this site)
\$settings['hash_salt'] = '$(openssl rand -hex 32)';
EOF

    if [ $? -eq 0 ]; then
        # Ensure settings.local.php is included from settings.php
        ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "$sudo_prefix grep -q 'settings.local.php' ${settings_path}/settings.php || $sudo_prefix bash -c 'echo \"
if (file_exists(\\\$app_root . \\\"/\" . \\\$site_path . \\\"/settings.local.php\\\")) {
  include \\\$app_root . \\\"/\" . \\\$site_path . \\\"/settings.local.php\\\";
}\" >> ${settings_path}/settings.php'" 2>/dev/null

        # Set correct permissions
        ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "$sudo_prefix chown www-data:www-data ${settings_path}/settings.local.php" 2>/dev/null
        ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "$sudo_prefix chmod 440 ${settings_path}/settings.local.php" 2>/dev/null

        # Create private files directory
        ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "$sudo_prefix mkdir -p ${site_path}/private && $sudo_prefix chown www-data:www-data ${site_path}/private && $sudo_prefix chmod 750 ${site_path}/private" 2>/dev/null

        print_status "OK" "settings.local.php created"
        return 0
    else
        print_error "Failed to create settings.local.php"
        return 1
    fi
}

# Export database from staging and import to live
deploy_database() {
    local stg_site="$1"
    local base_name="$2"
    local server_ip="$3"
    local ssh_user="$4"

    local db_name="${base_name//-/_}"

    print_info "Exporting database from staging..."

    local original_dir=$(pwd)
    cd "$stg_site" || return 1

    # Export database from DDEV
    local dump_file="/tmp/${base_name}_stg_live_deploy.sql.gz"
    if ddev export-db --gzip --file="$dump_file" 2>/dev/null; then
        print_status "OK" "Database exported"
    else
        print_error "Failed to export database from staging"
        cd "$original_dir"
        return 1
    fi

    cd "$original_dir"

    # Transfer to live server
    print_info "Transferring database to live server..."
    if scp $(nwp_ssh_opts "$base_name") -o BatchMode=yes "$dump_file" "${ssh_user}@${server_ip}:/tmp/" 2>/dev/null; then
        print_status "OK" "Database transferred"
    else
        print_error "Failed to transfer database"
        rm -f "$dump_file"
        return 1
    fi

    # Import on live server
    print_info "Importing database on live server..."
    local sudo_prefix=""
    if [ "$ssh_user" == "gitlab" ]; then
        sudo_prefix="sudo"
    fi

    local remote_dump="/tmp/${base_name}_stg_live_deploy.sql.gz"
    if ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "gunzip -c $remote_dump | $sudo_prefix mysql ${db_name}" 2>/dev/null; then
        print_status "OK" "Database imported"
        # Cleanup
        ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "rm -f $remote_dump" 2>/dev/null
        rm -f "$dump_file"
        return 0
    else
        print_error "Failed to import database"
        ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "rm -f $remote_dump" 2>/dev/null
        rm -f "$dump_file"
        return 1
    fi
}

# Setup SSL certificate using certbot
setup_ssl_certificate() {
    local base_name="$1"
    local server_ip="$2"
    local ssh_user="$3"
    # Domain resolution chain (same chain used for rsync destination):
    #   .nwp.yml .live.domain → settings.url base → NWP_PROD_DOMAIN env.
    # The previous default ("example.org") produced certbot calls against
    # nonexistent nwc.example.org. Wrong, never going to succeed.
    local domain
    domain=$(get_live_config "$base_name" "domain" 2>/dev/null)
    if [ -z "$domain" ]; then
        local base_domain
        base_domain=$(get_base_domain 2>/dev/null)
        [ -z "$base_domain" ] && base_domain="${NWP_PROD_DOMAIN:-nwpcode.org}"
        domain="${base_name}.${base_domain}"
    fi

    print_info "Setting up SSL certificate for $domain..."

    local sudo_prefix=""
    if [ "$ssh_user" == "gitlab" ]; then
        sudo_prefix="sudo"
    fi

    # Check if certbot is installed
    if ! ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "which certbot >/dev/null 2>&1"; then
        print_info "Installing certbot..."
        ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "$sudo_prefix apt-get update && $sudo_prefix apt-get install -y certbot" 2>/dev/null || {
            print_status "WARN" "Could not install certbot - SSL setup skipped"
            return 1
        }
    fi

    # Check if certificate already exists. If it does, skip cert
    # acquisition but STILL run update_nginx_ssl below so that the
    # per-site nginx config gets written/refreshed. Without this,
    # a re-run after an interrupted previous run leaves the site
    # with an HTTP-only or stale nginx config.
    local cert_exists=0
    if ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "$sudo_prefix test -f /etc/letsencrypt/live/${domain}/fullchain.pem" 2>/dev/null; then
        print_status "OK" "SSL certificate already exists; refreshing nginx config"
        cert_exists=1
        update_nginx_ssl "$base_name" "$server_ip" "$ssh_user" "$domain"
        return $?
    fi

    # Get certificate using webroot method.
    #
    # CHICKEN-AND-EGG: certbot --webroot needs nginx to ALREADY serve
    # /.well-known/acme-challenge/<token> from the webroot. On a first
    # deploy there's no per-site nginx config yet, so requests fall
    # through to the GitLab default (404). Bootstrap a minimal HTTP-only
    # config first — certbot can then place + retrieve its challenge,
    # and update_nginx_ssl below replaces it with the full HTTPS config.
    local webroot="/var/www/${base_name}/html"
    # Auto-detect webroot for Moodle (no /html subdir) and Drupal-with-web.
    if ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "$sudo_prefix test ! -d $webroot" 2>/dev/null; then
        if ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "$sudo_prefix test -d /var/www/${base_name}/web" 2>/dev/null; then
            webroot="/var/www/${base_name}/web"
        else
            webroot="/var/www/${base_name}"
        fi
    fi

    if ! ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "$sudo_prefix test -f /etc/nginx/conf.d/${base_name}.conf" 2>/dev/null; then
        print_info "Writing HTTP-only nginx bootstrap config for ACME challenge..."
        ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "$sudo_prefix tee /etc/nginx/conf.d/${base_name}.conf > /dev/null" << ACMEEOF
server {
    listen 80;
    server_name ${domain};
    root ${webroot};
    location /.well-known/acme-challenge/ { allow all; }
    location / { return 301 https://\$server_name\$request_uri; }
}
ACMEEOF
        if ! ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "$sudo_prefix nginx -t" >/dev/null 2>&1; then
            print_error "Bootstrap nginx config failed validation; removing"
            ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "$sudo_prefix rm -f /etc/nginx/conf.d/${base_name}.conf" 2>/dev/null || true
            return 1
        fi
        ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "$sudo_prefix gitlab-ctl hup nginx" 2>/dev/null || \
            ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "$sudo_prefix systemctl reload nginx" 2>/dev/null || true
    fi

    if ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "$sudo_prefix certbot certonly --webroot -w $webroot -d $domain --non-interactive --agree-tos --email admin@nwpcode.org" 2>/dev/null; then
        print_status "OK" "SSL certificate obtained"

        # Update nginx config to use SSL
        update_nginx_ssl "$base_name" "$server_ip" "$ssh_user" "$domain"
        return 0
    else
        print_status "WARN" "Could not obtain SSL certificate (may need manual setup)"
        return 1
    fi
}

# Deploy robots.txt to live server
# By default, deploys BLOCKING robots.txt (same as staging) to prevent indexing.
# Only deploys permissive robots.txt if robots_allow is set in site live config.
deploy_production_robots() {
    local base_name="$1"
    local server_ip="$2"
    local ssh_user="$3"
    local domain="$4"

    local sudo_prefix=""
    if [ "$ssh_user" == "gitlab" ]; then
        sudo_prefix="sudo"
    fi

    # Check if site has robots_allow enabled in live config
    local robots_allow=$(get_live_config "$base_name" "robots_allow" 2>/dev/null || true)

    local template_path
    if [ "$robots_allow" == "true" ] || [ "$robots_allow" == "yes" ] || [ "$robots_allow" == "y" ]; then
        print_info "Deploying permissive robots.txt (robots_allow enabled)..."
        template_path="$PROJECT_ROOT/templates/robots-production.txt"
    else
        print_info "Deploying blocking robots.txt (default: no indexing)..."
        template_path="$PROJECT_ROOT/templates/robots-staging.txt"
    fi

    if [ ! -f "$template_path" ]; then
        print_status "WARN" "robots.txt template not found at $template_path"
        return 1
    fi

    # Replace [DOMAIN] with actual domain and deploy
    local robots_content=$(sed "s/\[DOMAIN\]/${domain}/g" "$template_path")

    # Deploy to webroot
    local site_path="/var/www/${base_name}"
    local webroot_path="${site_path}/html"

    if ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "$sudo_prefix test -d ${site_path}/web" 2>/dev/null; then
        webroot_path="${site_path}/web"
    fi

    # Write robots.txt to server
    echo "$robots_content" | ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "$sudo_prefix tee ${webroot_path}/robots.txt > /dev/null" 2>/dev/null

    if [ $? -eq 0 ]; then
        # Set correct permissions
        ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "$sudo_prefix chown www-data:www-data ${webroot_path}/robots.txt && $sudo_prefix chmod 644 ${webroot_path}/robots.txt" 2>/dev/null
        print_status "OK" "robots.txt deployed"
        return 0
    else
        print_status "WARN" "Could not deploy robots.txt"
        return 1
    fi
}

# Update nginx config to include SSL
update_nginx_ssl() {
    local base_name="$1"
    local server_ip="$2"
    local ssh_user="$3"
    local domain="$4"

    local sudo_prefix=""
    if [ "$ssh_user" == "gitlab" ]; then
        sudo_prefix="sudo"
    fi

    print_info "Updating nginx config for SSL..."

    # Create updated nginx config with SSL
    ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "$sudo_prefix tee /etc/nginx/conf.d/${base_name}.conf > /dev/null" << EOF
server {
    listen 80;
    server_name ${domain};
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name ${domain};

    ssl_certificate /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;

    # Security headers
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; font-src 'self' data:; connect-src 'self'; frame-ancestors 'self';" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;

    # SEO: Production site - allow indexing
    # (No X-Robots-Tag needed - search engines will index normally)

    # Hide server information
    server_tokens off;
    fastcgi_hide_header X-Generator;
    fastcgi_hide_header X-Powered-By;
    fastcgi_hide_header X-Drupal-Cache;
    fastcgi_hide_header X-Drupal-Dynamic-Cache;

    root /var/www/${base_name}/html;
    index index.php index.html;

    location / {
        try_files \$uri /index.php\$is_args\$args;
    }

    location ~ \\.php\$ {
        fastcgi_pass unix:/var/run/php/php8.2-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include /opt/gitlab/embedded/conf/fastcgi_params;
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

    location = /sitemap.xml {
        try_files \$uri @rewrite;
    }

    location ~* \\.(txt|log)\$ {
        deny all;
    }

    location ~ ^/sites/.*/files/styles/ {
        try_files \$uri @rewrite;
    }

    location @rewrite {
        rewrite ^ /index.php;
    }
}
EOF

    # Validate nginx config BEFORE reload. If broken, restore the snapshot's
    # version of conf.d/<base_name>.conf and bail. Otherwise the reload could
    # leave nginx unreloadable on next config change (sibling sites still
    # work because they're in separate conf.d/ files, but it's a foot-gun).
    if ! ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" \
        "$sudo_prefix nginx -t" >/dev/null 2>&1; then
        print_error "nginx -t failed AFTER writing conf.d/${base_name}.conf."
        print_error "Removing the broken config so nginx remains reloadable."
        ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" \
            "$sudo_prefix rm -f /etc/nginx/conf.d/${base_name}.conf" 2>/dev/null || true
        return 1
    fi

    # Reload nginx (GitLab's nginx)
    ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "$sudo_prefix gitlab-ctl hup nginx" 2>/dev/null || \
        ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "$sudo_prefix systemctl reload nginx" 2>/dev/null || true

    print_status "OK" "Nginx SSL config updated"
}

# Full database deployment (orchestrates all steps)
full_database_deployment() {
    local stg_site="$1"
    local base_name="$2"
    local server_ip="$3"
    local ssh_user="$4"
    local webroot="$5"

    print_header "Database Deployment"

    # Generate a secure password for the database
    local db_pass=$(generate_db_password)

    # Step 1: Setup database on live server
    if ! setup_live_database "$base_name" "$server_ip" "$ssh_user" "$db_pass"; then
        print_error "Database setup failed"
        return 1
    fi

    # Step 2: Generate settings.local.php
    if ! generate_live_settings "$base_name" "$server_ip" "$ssh_user" "$webroot" "$db_pass"; then
        print_error "Settings generation failed"
        return 1
    fi

    # Step 3: Deploy database from staging
    if ! deploy_database "$stg_site" "$base_name" "$server_ip" "$ssh_user"; then
        print_error "Database deployment failed"
        return 1
    fi

    print_status "OK" "Database deployment complete"
    return 0
}

# Display elapsed time
show_elapsed_time() {
    local end_time=$(date +%s)
    local elapsed=$((end_time - START_TIME))
    local hours=$((elapsed / 3600))
    local minutes=$(((elapsed % 3600) / 60))
    local seconds=$((elapsed % 60))

    echo ""
    print_status "OK" "Deployment completed in $(printf "%02d:%02d:%02d" $hours $minutes $seconds)"
}

# Verify and configure site email
verify_site_email() {
    local base_name="$1"
    local server_ip="$2"
    local ssh_user="$3"

    print_header "Verify Site Email Configuration"

    # Check if email auto-configure is enabled
    local auto_configure
    auto_configure=$(get_settings_value "email.auto_configure" "true" 2>/dev/null)
    if [ "$auto_configure" != "true" ]; then
        print_status "INFO" "Email auto-configure disabled in settings"
        return 0
    fi

    # Get email domain and admin email
    local email_domain
    email_domain=$(get_settings_value "email.domain" "" 2>/dev/null)
    if [ -z "$email_domain" ]; then
        email_domain=$(get_settings_value "url" "nwpcode.org" 2>/dev/null)
    fi

    local admin_email
    admin_email=$(get_settings_value "email.admin_email" "" 2>/dev/null)
    if [ -z "$admin_email" ]; then
        print_status "WARN" "No admin_email configured in settings.email"
        print_info "Email verification skipped"
        return 0
    fi

    local site_email="${base_name}@${email_domain}"
    local gitlab_host="git.${email_domain}"
    local mail_ssh_user="gitlab"

    print_info "Expected site email: $site_email"
    print_info "Forward to: $admin_email"

    # Check if email forwarding exists on mail server
    print_info "Checking email forwarding on $gitlab_host..."

    if ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes -o ConnectTimeout=5 "${mail_ssh_user}@${gitlab_host}" \
        "grep -q '^${site_email}' /etc/postfix/virtual 2>/dev/null" 2>/dev/null; then
        print_status "OK" "Email forwarding exists: $site_email"

        # Verify it forwards to the correct address
        local current_forward
        current_forward=$(ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${mail_ssh_user}@${gitlab_host}" \
            "grep '^${site_email}' /etc/postfix/virtual 2>/dev/null | awk '{print \$2}'" 2>/dev/null)

        if [ "$current_forward" != "$admin_email" ] && [ -n "$current_forward" ]; then
            print_status "WARN" "Forward address mismatch: $current_forward (expected: $admin_email)"
            print_info "Updating email forwarding..."

            # F23 Phase 8: email scripts moved to servers/<server>/email/. Legacy fallback retained.
            local email_script="${PROJECT_ROOT}/servers/nwpcode/email/add_site_email.sh"
            [ -f "$email_script" ] || email_script="${PROJECT_ROOT}/email/add_site_email.sh"
            if [ -f "$email_script" ]; then
                if scp $(nwp_ssh_opts "$base_name") -q "$email_script" "${mail_ssh_user}@${gitlab_host}:/tmp/add_site_email.sh" 2>/dev/null; then
                    if ssh $(nwp_ssh_opts "$base_name") "${mail_ssh_user}@${gitlab_host}" \
                        "sudo bash /tmp/add_site_email.sh ${base_name} --forward-only ${admin_email} -y && rm /tmp/add_site_email.sh" 2>/dev/null; then
                        print_status "OK" "Email forwarding updated: $site_email -> $admin_email"
                    else
                        print_status "WARN" "Could not update email forwarding"
                    fi
                fi
            fi
        else
            print_status "OK" "Email forwards to: $current_forward"
        fi
    else
        print_status "WARN" "Email forwarding not configured"
        print_info "Creating email forwarding..."

        # F23 Phase 8: email scripts moved to servers/<server>/email/. Legacy fallback retained.
        local email_script="${PROJECT_ROOT}/servers/nwpcode/email/add_site_email.sh"
        [ -f "$email_script" ] || email_script="${PROJECT_ROOT}/email/add_site_email.sh"
        if [ -f "$email_script" ]; then
            if scp $(nwp_ssh_opts "$base_name") -q "$email_script" "${mail_ssh_user}@${gitlab_host}:/tmp/add_site_email.sh" 2>/dev/null; then
                if ssh $(nwp_ssh_opts "$base_name") "${mail_ssh_user}@${gitlab_host}" \
                    "sudo bash /tmp/add_site_email.sh ${base_name} --forward-only ${admin_email} -y && rm /tmp/add_site_email.sh" 2>/dev/null; then
                    print_status "OK" "Email forwarding created: $site_email -> $admin_email"
                else
                    print_status "WARN" "Could not create email forwarding (may need manual setup)"
                fi
            else
                print_status "WARN" "Could not copy email script to mail server"
            fi
        else
            print_status "WARN" "Email setup script not found: $email_script"
        fi
    fi

    # Verify Drupal site email matches
    print_info "Verifying Drupal site email..."

    local sudo_prefix=""
    if [ "$ssh_user" == "gitlab" ]; then
        sudo_prefix="sudo -u www-data"
    fi

    local current_drupal_email
    current_drupal_email=$(ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" \
        "cd /var/www/${base_name} && $sudo_prefix vendor/bin/drush config:get system.site mail --format=string 2>/dev/null" 2>/dev/null)

    if [ "$current_drupal_email" == "$site_email" ]; then
        print_status "OK" "Drupal site email correct: $current_drupal_email"
    elif [ -n "$current_drupal_email" ]; then
        print_status "WARN" "Drupal site email mismatch: $current_drupal_email (expected: $site_email)"
        print_info "Updating Drupal site email..."

        if ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" \
            "cd /var/www/${base_name} && $sudo_prefix vendor/bin/drush config:set system.site mail '${site_email}' -y" 2>/dev/null; then
            print_status "OK" "Drupal site email updated to: $site_email"
        else
            print_status "WARN" "Could not update Drupal site email"
        fi
    else
        print_info "Could not read current Drupal site email"
    fi

    return 0
}

# Show help
show_help() {
    cat << EOF
${BOLD}NWP Staging to Live Deployment${NC}

${BOLD}USAGE:${NC}
    ./stg2live.sh [OPTIONS] <sitename>

    Deploys staging site to the live server provisioned by 'pl live'.

${BOLD}OPTIONS:${NC}
    -h, --help              Show this help message
    -d, --debug             Enable debug output
    -y, --yes               Skip confirmation prompts
    -v, --verbose           Show detailed rsync output
    --no-security           Skip security module installation
    --no-password-reset     Skip password security (admin regeneration, weak password reset)
    --no-provision          Skip auto-provisioning (used internally)
    --dry-run               Snapshot + rsync preview only; abort before any DB write,
                            permission change, or service reload. Safe to run any time.

${BOLD}ARGUMENTS:${NC}
    sitename                Site name (with or without _stg suffix)

${BOLD}EXAMPLES:${NC}
    ./stg2live.sh mysite              # Deploy mysite/stg/ to mysite.<prod-domain>
    ./stg2live.sh mysite-stg          # Same as above (legacy name accepted)
    ./stg2live.sh -y mysite           # Deploy without confirmation
    ./stg2live.sh --no-security mysite  # Deploy without security modules

${BOLD}PASSWORD SECURITY:${NC}
    Before deployment, this script automatically:
    - Regenerates the admin password to a secure 16-character random value
    - Detects users with weak passwords (password, admin, test123, etc.)
    - Resets weak passwords to secure random values
    - Displays the new admin password (SAVE IT!)
    Disable with: --no-password-reset flag

${BOLD}SECURITY HARDENING:${NC}
    By default, security modules are installed from nwp.yml settings.live_security
    Includes: seckit, honeypot, flood_control, login_security, etc.
    Disable with: --no-security flag or set enabled: false in nwp.yml

${BOLD}NOTE:${NC}
    If no live server is configured, this script will automatically
    call 'pl live' to provision one first.

${BOLD}REQUIREMENTS:${NC}
    - Staging site must exist and be in production mode

EOF
}

################################################################################
# Deployment Functions
################################################################################

deploy_to_live() {
    local stg_site="$1"
    local base_name="$2"
    local auto_yes="$3"

    # Get live server config
    local server_ip=$(get_live_config "$base_name" "server_ip")
    local domain=$(get_live_config "$base_name" "domain")
    local server_type=$(get_live_config "$base_name" "type")

    if [ -z "$server_ip" ]; then
        print_error "No live server configured for $base_name"
        print_info "Run 'pl live $base_name' first to provision a live server"
        return 1
    fi

    local base_domain=$(get_base_domain)
    if [ -z "$domain" ]; then
        domain="${base_name}.${base_domain}"
    fi

    print_header "Deploy Staging to Live"
    echo -e "${BOLD}Staging:${NC}     $stg_site"
    echo -e "${BOLD}Live:${NC}        https://$domain"
    echo -e "${BOLD}Server:${NC}      $server_ip"
    echo -e "${BOLD}Type:${NC}        ${server_type:-shared}"
    echo ""

    # Check staging site exists
    if [ ! -d "$stg_site" ]; then
        print_error "Staging site not found: $stg_site"
        return 1
    fi

    # Secure passwords before deployment (regenerate admin, reset weak passwords).
    # Both of these mutate the staging site, so skip them on dry-run.
    if [ "${DRY_RUN:-false}" != "true" ]; then
        secure_user_passwords "$stg_site"
        install_security_modules "$stg_site"
    else
        print_info "[dry-run] skipping secure_user_passwords + install_security_modules (would mutate staging)"
    fi

    # Determine SSH user via resolution chain (F15)
    local ssh_user
    ssh_user=$(get_ssh_user "$base_name")

    # Test SSH connection
    print_info "Testing SSH connection..."
    if ! ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes -o ConnectTimeout=5 "${ssh_user}@${server_ip}" "echo ok" >/dev/null 2>&1; then
        print_error "Cannot connect to live server: ${ssh_user}@${server_ip}"
        return 1
    fi
    print_status "OK" "SSH connection successful (user: $ssh_user)"

    # Belt-and-suspenders: snapshot the live host's DBs + nginx configs
    # before doing anything destructive. Cheap insurance; recovers from
    # both DB-import gone-wrong and bad nginx config.
    live_host_snapshot "$base_name" "$server_ip" "$ssh_user"

    # Get webroot from staging site
    local webroot="web"
    if [ -f "$stg_site/.ddev/config.yaml" ]; then
        webroot=$(grep "^docroot:" "$stg_site/.ddev/config.yaml" 2>/dev/null | awk '{print $2}')
        [ -z "$webroot" ] && webroot="web"
    fi

    # F23: read remote_path from per-site config, default to /var/www/<name>
    local remote_path
    remote_path=$(get_live_config "$base_name" "remote_path")
    [ -z "$remote_path" ] && remote_path="/var/www/${base_name}"

    # Build rsync excludes
    local excludes=(
        "--exclude=.ddev"
        "--exclude=.git"
        "--exclude=.nwp.yml"
        "--exclude=$webroot/sites/default/settings.local.php"
        "--exclude=$webroot/sites/default/files"
        "--exclude=private"
        "--exclude=node_modules"
        "--exclude=.env"
        "--exclude=.env.local"
    )

    # Sync files
    print_header "Syncing Files"
    print_info "Source: $stg_site/"
    print_info "Destination: ${ssh_user}@${server_ip}:${remote_path}/"

    local sudo_prefix=""
    if [ "$ssh_user" == "gitlab" ]; then
        sudo_prefix="sudo"
    fi

    # Ensure target directory exists with correct ownership for rsync
    ssh $(nwp_ssh_opts "$base_name") "${ssh_user}@${server_ip}" "$sudo_prefix mkdir -p ${remote_path}" 2>/dev/null || true
    if [ "$ssh_user" == "gitlab" ]; then
        # Give gitlab user ownership temporarily for rsync
        ssh $(nwp_ssh_opts "$base_name") "${ssh_user}@${server_ip}" "sudo chown -R gitlab:www-data ${remote_path}" 2>/dev/null || true
    fi

    # Rsync (quiet by default, verbose with -v flag). On dry-run we add
    # --dry-run so rsync prints the planned changes without writing anything;
    # we always print the verbose summary in that mode so the operator
    # actually sees what would change.
    local rsync_opts="-az"
    if [ "${VERBOSE:-false}" == "true" ]; then
        rsync_opts="-avz"
    fi
    local rsync_dryflag=""
    if [ "${DRY_RUN:-false}" == "true" ]; then
        rsync_dryflag="--dry-run"
        rsync_opts="-avz"
        print_info "[dry-run] rsync --dry-run output:"
    fi

    if rsync -e "ssh $(nwp_ssh_opts "$base_name")" $rsync_opts $rsync_dryflag --delete "${excludes[@]}" \
        "$stg_site/" \
        "${ssh_user}@${server_ip}:${remote_path}/"; then
        print_status "OK" "Files synced"
    else
        print_error "File sync failed"
        return 1
    fi

    # Set permissions
    if [ "${DRY_RUN:-false}" == "true" ]; then
        print_info "[dry-run] would chown -R www-data:www-data ${remote_path}"
    else
        print_info "Setting permissions..."
        ssh $(nwp_ssh_opts "$base_name") "${ssh_user}@${server_ip}" "$sudo_prefix chown -R www-data:www-data ${remote_path}" 2>/dev/null || true
    fi

    # Deploy database (creates DB, generates settings.local.php, imports data).
    # Hard stop on dry-run before any DB write: this is the most destructive
    # step in the script, so we don't want to do even read-only DB queries
    # in dry-run beyond what the snapshot already did.
    if [ "${DRY_RUN:-false}" == "true" ]; then
        local stg_db_name="${base_name}_stg"
        local live_db_name="${base_name}"
        print_info "[dry-run] would dump stg DB '${stg_db_name}' and import into live DB '${live_db_name}' on ${server_ip}"
        print_info "[dry-run] would generate fresh settings.local.php for live"
        print_info "[dry-run] would run drush cr on live"
        print_status "OK" "Dry run complete; no destructive ops executed"
        return 0
    fi
    if ! full_database_deployment "$stg_site" "$base_name" "$server_ip" "$ssh_user" "$webroot"; then
        print_status "WARN" "Database deployment had issues (site may need manual database setup)"
    fi

    # Setup SSL certificate
    print_header "SSL Certificate"
    if ! setup_ssl_certificate "$base_name" "$server_ip" "$ssh_user"; then
        print_status "WARN" "SSL setup incomplete - site may not have HTTPS"
    fi

    # Deploy production robots.txt
    print_header "SEO Configuration"
    deploy_production_robots "$base_name" "$server_ip" "$ssh_user" "$domain"

    # Run post-deployment commands
    print_header "Post-Deployment Tasks"

    # Clear cache via drush if available
    print_info "Clearing cache..."
    ssh $(nwp_ssh_opts "$base_name") "${ssh_user}@${server_ip}" "cd ${remote_path} && $sudo_prefix -u www-data drush cr" 2>/dev/null || \
        ssh $(nwp_ssh_opts "$base_name") "${ssh_user}@${server_ip}" "cd ${remote_path}/$webroot && $sudo_prefix -u www-data ../vendor/bin/drush cr" 2>/dev/null || \
        print_status "WARN" "Could not clear cache (drush may not be available)"

    # Verify and configure site email
    verify_site_email "$base_name" "$server_ip" "$ssh_user"

    # Success
    print_header "Deployment Complete"
    print_status "OK" "Staging deployed to live server"
    echo ""
    echo -e "  ${BOLD}Live URL:${NC} ${GREEN}https://${domain}${NC}"
    echo ""

    return 0
}

################################################################################
# Main
################################################################################

main() {
    local DEBUG=false
    local YES=false
    local VERBOSE=false
    local SKIP_SECURITY=false
    local SKIP_PASSWORD_RESET=false
    local NO_PROVISION=false
    local DRY_RUN=false
    local SITENAME=""

    # Parse options
    local OPTIONS=hdyv
    local LONGOPTS=help,debug,yes,verbose,no-security,no-password-reset,no-provision,dry-run

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
            -v|--verbose) VERBOSE=true; shift ;;
            --no-security) SKIP_SECURITY=true; shift ;;
            --no-password-reset) SKIP_PASSWORD_RESET=true; shift ;;
            --no-provision) NO_PROVISION=true; shift ;;
            --dry-run) DRY_RUN=true; shift ;;
            --) shift; break ;;
            *) echo "Programming error"; exit 3 ;;
        esac
    done

    # Export so deploy_to_live and friends can read it.
    export DRY_RUN

    # Get sitename
    if [ $# -ge 1 ]; then
        SITENAME="$1"
    else
        print_error "Sitename required"
        show_help
        exit 1
    fi

    # Normalize names
    local BASE_NAME=$(get_base_name "$SITENAME")

    # F23: resolve stg directory (v2: sites/<name>/stg/, v1: sites/<name>-stg/)
    local STG_DIR
    STG_DIR=$(get_stg_dir "$SITENAME")
    if [ -z "$STG_DIR" ]; then
        print_error "Cannot resolve staging directory for $BASE_NAME"
        exit 1
    fi

    # Honor the per-site live.enabled flag. Without this guard, every site
    # with a `live.server: <known-server>` entry deploys to that server
    # regardless of whether live deployment was intentionally disabled —
    # which is exactly the misfire the "enabled" flag exists to prevent.
    # Found 2026-05-20: a system-test fixture had `live.enabled: false`
    # set explicitly but stg2live still progressed to "Pre-Deploy
    # Snapshot" on the live host because the flag was never checked.
    local live_enabled
    live_enabled=$(get_live_config "$BASE_NAME" "enabled")
    if [ "$live_enabled" = "false" ]; then
        print_error "Live deployment disabled for '$BASE_NAME' (live.enabled: false in sites/$BASE_NAME/.nwp.yml)"
        print_info "To enable: set live.enabled: true in the site's .nwp.yml, or pass --force-enabled (not yet implemented)."
        exit 1
    fi

    # Export for use in deploy function
    export SKIP_SECURITY VERBOSE
    export SKIP_PASSWORD_RESET

    # Check if live server is configured
    local server_ip=$(get_live_config "$BASE_NAME" "server_ip")

    if [ -z "$server_ip" ] && [ "$NO_PROVISION" != "true" ]; then
        print_info "No live server configured for $BASE_NAME"
        print_info "Provisioning live server first..."
        echo ""

        # Call live.sh to provision (it will call back to us with --no-provision)
        if "${SCRIPT_DIR}/live.sh" -y "$BASE_NAME"; then
            # live.sh already called stg2live with --no-provision, so we're done
            exit 0
        else
            print_error "Failed to provision live server for: $BASE_NAME"
            exit 1
        fi
    fi

    # Run deployment
    if deploy_to_live "$STG_DIR" "$BASE_NAME" "$YES"; then
        show_elapsed_time
        exit 0
    else
        print_error "Deployment to live failed: $STG_DIR → $BASE_NAME"
        exit 1
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
