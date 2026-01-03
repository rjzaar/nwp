# NWP Installation & Deployment Improvement Proposal

## Executive Summary

This proposal addresses automation gaps discovered during the AVC recipe installation and live deployment. The current workflow requires significant manual intervention that should be automated.

## Issues Encountered

### 1. Profile Module Discovery (CRITICAL)
**Problem:** When `profile_source` clones a profile to `profiles/custom/avc_profile/`, Drupal doesn't automatically discover modules in that profile's `modules/` directory because the install profile is `social`, not `avc_profile`.

**Manual Workaround Used:**
```bash
cd html/modules/custom
ln -s ../../profiles/custom/avc_profile/modules/avc_content avc_content
# ... repeated for each module
```

**Root Cause:** `install_git_profile()` in `lib/install-common.sh` clones the profile but doesn't create symlinks.

### 2. Live Server Infrastructure (CRITICAL)
**Problem:** `live.sh` assumes the target server has:
- MariaDB installed and running
- PHP-FPM configured with correct socket permissions
- nginx configured for PHP sites
- Database created for the site

**Manual Steps Required:**
```bash
# On live server
sudo apt install mariadb-server php8.2-fpm
sudo mysql -e "CREATE DATABASE avctest; CREATE USER 'avctest'@'localhost'..."
# Update settings.php with credentials
# Configure nginx vhost
# Configure PHP-FPM socket permissions
```

### 3. Database Deployment (HIGH)
**Problem:** `stg2live.sh` syncs files but not the database. Database must be exported from staging, copied to live, and imported manually.

### 4. Settings.php Production Configuration (HIGH)
**Problem:** The DDEV settings.php references `db` as the hostname, which doesn't exist on live servers. Live requires localhost credentials.

---

## Proposed Solutions

### Solution 1: Auto-Create Module Symlinks After Profile Clone

**File:** `lib/install-common.sh`

**Change:** Modify `install_git_profile()` to create symlinks after cloning.

```bash
# Add after line 871 (after successful git clone)
install_git_profile() {
    local git_url=$1
    local profile_name=$2
    local webroot=$3
    local profiles_dir="${webroot}/profiles/custom"
    local profile_path="${profiles_dir}/${profile_name}"
    local modules_custom="${webroot}/modules/custom"

    # ... existing clone logic ...

    # NEW: Create symlinks for profile modules
    if [ -d "$profile_path/modules" ]; then
        print_info "Creating symlinks for profile modules..."
        mkdir -p "$modules_custom"

        for module_dir in "$profile_path/modules"/*/; do
            if [ -d "$module_dir" ]; then
                local module_name=$(basename "$module_dir")
                local symlink_path="$modules_custom/$module_name"
                local relative_target="../../profiles/custom/${profile_name}/modules/${module_name}"

                if [ ! -e "$symlink_path" ]; then
                    ln -sf "$relative_target" "$symlink_path"
                    print_status "OK" "Symlinked module: $module_name"
                fi
            fi
        done
    fi

    # NEW: Create symlinks for profile themes
    if [ -d "$profile_path/themes" ]; then
        local themes_custom="${webroot}/themes/custom"
        mkdir -p "$themes_custom"

        for theme_dir in "$profile_path/themes"/*/; do
            if [ -d "$theme_dir" ]; then
                local theme_name=$(basename "$theme_dir")
                local symlink_path="$themes_custom/$theme_name"
                local relative_target="../../profiles/custom/${profile_name}/themes/${theme_name}"

                if [ ! -e "$symlink_path" ]; then
                    ln -sf "$relative_target" "$symlink_path"
                    print_status "OK" "Symlinked theme: $theme_name"
                fi
            fi
        done
    fi
}
```

### Solution 2: Automated Live Server Setup

**New File:** `lib/live-server-setup.sh`

Create functions for remote server provisioning:

```bash
#!/bin/bash
# Live server setup functions for shared deployments

# Ensure PHP-FPM is installed and configured
ensure_php_fpm() {
    local server=$1
    local ssh_user=$2

    ssh "${ssh_user}@${server}" bash << 'REMOTE_SCRIPT'
        # Check if PHP-FPM is installed
        if ! command -v php-fpm8.2 &>/dev/null; then
            sudo add-apt-repository -y ppa:ondrej/php
            sudo apt update
            sudo apt install -y php8.2-fpm php8.2-mysql php8.2-gd php8.2-xml \
                php8.2-mbstring php8.2-curl php8.2-zip php8.2-intl php8.2-opcache
        fi

        # Configure socket permissions for nginx (gitlab-www user)
        sudo sed -i 's/listen.group = www-data/listen.group = gitlab-www/' \
            /etc/php/8.2/fpm/pool.d/www.conf
        sudo systemctl restart php8.2-fpm
REMOTE_SCRIPT
}

# Ensure MariaDB is installed
ensure_mariadb() {
    local server=$1
    local ssh_user=$2

    ssh "${ssh_user}@${server}" bash << 'REMOTE_SCRIPT'
        if ! command -v mariadb &>/dev/null; then
            sudo apt install -y mariadb-server mariadb-client
            sudo systemctl enable mariadb
            sudo systemctl start mariadb
        fi
REMOTE_SCRIPT
}

# Create database for site
create_site_database() {
    local server=$1
    local ssh_user=$2
    local db_name=$3
    local db_user=$4
    local db_pass=$5

    ssh "${ssh_user}@${server}" << REMOTE_SCRIPT
        sudo mysql -e "CREATE DATABASE IF NOT EXISTS ${db_name};"
        sudo mysql -e "CREATE USER IF NOT EXISTS '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';"
        sudo mysql -e "GRANT ALL PRIVILEGES ON ${db_name}.* TO '${db_user}'@'localhost';"
        sudo mysql -e "FLUSH PRIVILEGES;"
REMOTE_SCRIPT
}

# Configure nginx for Drupal site (for GitLab's nginx)
configure_nginx_drupal() {
    local server=$1
    local ssh_user=$2
    local site_name=$3
    local domain=$4
    local webroot=$5

    ssh "${ssh_user}@${server}" sudo bash << REMOTE_SCRIPT
        cat > /etc/nginx/conf.d/${site_name}.conf << 'NGINX_CONF'
server {
    listen 80;
    server_name ${domain};
    root ${webroot};
    index index.php index.html;

    location / {
        try_files \$uri /index.php\$is_args\$args;
    }

    location ~ \.php$ {
        fastcgi_pass unix:/var/run/php/php8.2-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param QUERY_STRING \$query_string;
        fastcgi_param REQUEST_METHOD \$request_method;
        fastcgi_param CONTENT_TYPE \$content_type;
        fastcgi_param CONTENT_LENGTH \$content_length;
        fastcgi_param SCRIPT_NAME \$fastcgi_script_name;
        fastcgi_param REQUEST_URI \$request_uri;
        fastcgi_param DOCUMENT_URI \$document_uri;
        fastcgi_param DOCUMENT_ROOT \$document_root;
        fastcgi_param SERVER_PROTOCOL \$server_protocol;
        fastcgi_param GATEWAY_INTERFACE CGI/1.1;
        fastcgi_param SERVER_SOFTWARE nginx/\$nginx_version;
        fastcgi_param REMOTE_ADDR \$remote_addr;
        fastcgi_param REMOTE_PORT \$remote_port;
        fastcgi_param SERVER_ADDR \$server_addr;
        fastcgi_param SERVER_PORT \$server_port;
        fastcgi_param SERVER_NAME \$server_name;
        fastcgi_param HTTPS \$https if_not_empty;
    }

    location ~ /\.ht {
        deny all;
    }

    location ~ /sites/.*/files/styles/ {
        try_files \$uri @rewrite;
    }

    location @rewrite {
        rewrite ^/(.*)$ /index.php?q=\$1;
    }
}
NGINX_CONF
        gitlab-ctl restart nginx
REMOTE_SCRIPT
}
```

### Solution 3: Database Deployment in stg2live.sh

**File:** `stg2live.sh`

Add database sync functionality:

```bash
# Add new function for database deployment
deploy_database() {
    local stg_site=$1
    local live_server=$2
    local ssh_user=$3
    local db_name=$4
    local db_user=$5
    local db_pass=$6
    local stg_dir="/home/rob/nwp/${stg_site}"

    print_header "Database Deployment"

    # Export from staging
    print_info "Exporting database from staging..."
    local db_dump="/tmp/${stg_site}_$(date +%Y%m%d_%H%M%S).sql.gz"

    if ! (cd "$stg_dir" && ddev export-db --gzip --file="$db_dump"); then
        print_error "Failed to export staging database"
        return 1
    fi
    print_status "OK" "Database exported to $db_dump"

    # Copy to live server
    print_info "Copying database to live server..."
    if ! scp "$db_dump" "${ssh_user}@${live_server}:/tmp/"; then
        print_error "Failed to copy database to live server"
        return 1
    fi
    print_status "OK" "Database copied to live server"

    # Import on live server
    print_info "Importing database on live server..."
    local remote_dump="/tmp/$(basename $db_dump)"
    if ! ssh "${ssh_user}@${live_server}" "gunzip -c '$remote_dump' | mysql -u'$db_user' -p'$db_pass' '$db_name'"; then
        print_error "Failed to import database on live server"
        return 1
    fi
    print_status "OK" "Database imported on live server"

    # Cleanup
    rm -f "$db_dump"
    ssh "${ssh_user}@${live_server}" "rm -f '$remote_dump'"

    return 0
}
```

### Solution 4: Production Settings.php Configuration

**File:** `lib/install-common.sh`

Add function to generate production settings:

```bash
# Generate production settings.php configuration
generate_live_settings() {
    local site_dir=$1
    local webroot=$2
    local db_name=$3
    local db_user=$4
    local db_pass=$5
    local db_host=${6:-localhost}

    local settings_file="${site_dir}/${webroot}/sites/default/settings.php"
    local settings_local="${site_dir}/${webroot}/sites/default/settings.local.php"

    # Create settings.local.php for production
    cat > "$settings_local" << EOF
<?php
/**
 * Production settings for live deployment.
 * Generated by NWP on $(date)
 */

// Production database settings
\$databases['default']['default'] = [
  'database' => '${db_name}',
  'username' => '${db_user}',
  'password' => '${db_pass}',
  'host' => '${db_host}',
  'port' => '3306',
  'driver' => 'mysql',
  'prefix' => '',
  'collation' => 'utf8mb4_general_ci',
];

// Production settings
\$settings['hash_salt'] = '$(openssl rand -hex 32)';
\$settings['update_free_access'] = FALSE;
\$settings['file_private_path'] = '../private';

// Disable development modules in production
\$config['system.performance']['css']['preprocess'] = TRUE;
\$config['system.performance']['js']['preprocess'] = TRUE;
\$config['system.logging']['error_level'] = 'hide';

// Trusted host patterns (update with actual domain)
\$settings['trusted_host_patterns'] = [
  '^${db_name}\.nwpcode\.org$',
  '^www\.${db_name}\.nwpcode\.org$',
];
EOF

    # Ensure settings.php includes settings.local.php
    if ! grep -q "settings.local.php" "$settings_file"; then
        cat >> "$settings_file" << 'EOF'

// Load local settings if present
if (file_exists($app_root . '/' . $site_path . '/settings.local.php')) {
  include $app_root . '/' . $site_path . '/settings.local.php';
}
EOF
    fi
}
```

### Solution 5: Unified Live Deployment Function

**File:** `stg2live.sh`

Enhance `deploy_to_live()` to handle full deployment:

```bash
deploy_to_live_full() {
    local stg_site=$1
    local base_name=$(get_base_name "$stg_site")
    local live_server=$(get_live_server "$base_name")
    local ssh_user=$(get_ssh_user "$live_server")
    local domain="${base_name}.nwpcode.org"
    local webroot="/var/www/${base_name}/html"
    local db_name="$base_name"
    local db_user="$base_name"
    local db_pass=$(generate_password 16)

    print_header "Full Live Deployment: $base_name"

    # Step 1: Ensure server infrastructure
    print_step "1" "Checking server infrastructure"
    ensure_php_fpm "$live_server" "$ssh_user"
    ensure_mariadb "$live_server" "$ssh_user"

    # Step 2: Create database
    print_step "2" "Creating database"
    create_site_database "$live_server" "$ssh_user" "$db_name" "$db_user" "$db_pass"

    # Step 3: Configure nginx
    print_step "3" "Configuring nginx"
    configure_nginx_drupal "$live_server" "$ssh_user" "$base_name" "$domain" "$webroot"

    # Step 4: Generate production settings
    print_step "4" "Generating production settings"
    generate_live_settings "/home/rob/nwp/${stg_site}" "html" "$db_name" "$db_user" "$db_pass"

    # Step 5: Sync files
    print_step "5" "Syncing files to live server"
    sync_files_to_live "$stg_site" "$live_server" "$ssh_user" "$webroot"

    # Step 6: Deploy database
    print_step "6" "Deploying database"
    deploy_database "$stg_site" "$live_server" "$ssh_user" "$db_name" "$db_user" "$db_pass"

    # Step 7: Set permissions and clear cache
    print_step "7" "Finalizing deployment"
    ssh "${ssh_user}@${live_server}" "cd $webroot && ../vendor/bin/drush cr"

    # Step 8: Setup SSL
    print_step "8" "Setting up SSL"
    setup_ssl "$live_server" "$domain"

    print_status "OK" "Deployment complete: https://${domain}"

    # Store credentials securely
    store_live_credentials "$base_name" "$db_user" "$db_pass"
}
```

---

## Implementation Priority

### Phase 1: Critical Fixes (Implement First)
1. **Module symlink creation in `install_git_profile()`** - Fixes AVC and similar recipes
2. **YAML comment stripping** - Already fixed in this session

### Phase 2: Live Deployment Automation
3. **Server infrastructure setup functions** - New `lib/live-server-setup.sh`
4. **Database deployment function** - Add to `stg2live.sh`
5. **Production settings generation** - Add to `lib/install-common.sh`

### Phase 3: Integration
6. **Unified `deploy_to_live_full()`** - Orchestrates all steps
7. **Update `live.sh`** - Call new functions for shared server deployments
8. **Credential management** - Store/retrieve live database credentials securely

---

## Testing Plan

### Test 1: Profile Module Symlinks
```bash
# Delete existing avctest
./delete.sh avctest -y

# Reinstall with updated install_git_profile()
./install.sh avc avctest

# Verify symlinks created
ls -la avctest/html/modules/custom/
# Should show: avc_content -> ../../profiles/custom/avc_profile/modules/avc_content

# Verify modules are enabled
cd avctest && ddev drush pm:list | grep avc
# Should show all AVC modules as Enabled
```

### Test 2: Live Deployment
```bash
# Copy to staging
./copy.sh avctest avctest_stg

# Deploy to live with new automation
./stg2live.sh avctest

# Verify site accessible
curl -I https://avctest.nwpcode.org
# Should return HTTP 200
```

---

## Files to Modify

| File | Changes |
|------|---------|
| `lib/install-common.sh` | Add symlink creation in `install_git_profile()`, add `generate_live_settings()` |
| `lib/live-server-setup.sh` | New file with server provisioning functions |
| `stg2live.sh` | Add `deploy_database()`, enhance `deploy_to_live()` |
| `live.sh` | Integrate server setup for shared deployments |

---

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Breaking existing recipes | Test with `d`, `os`, `nwp` recipes before merging |
| Database credential exposure | Use `.secrets.data.yml` for storage, never log passwords |
| SSH connection failures | Add retry logic and clear error messages |
| Nginx config conflicts | Check for existing configs before overwriting |

---

## Appendix: Current vs Proposed Workflow

### Current Manual Workflow (AVC Recipe)
1. `./install.sh avc avctest` - Creates site but modules not discoverable
2. Manually clone profile to profiles/custom/
3. Manually create symlinks for each module
4. Manually run `ddev drush pm:enable avc_content ...`
5. `./copy.sh avctest avctest_stg` - Works
6. `./live.sh avctest` - Fails at file sync (no DB, no PHP)
7. Manually SSH to server and install MariaDB
8. Manually create database
9. Manually export/import database
10. Manually update settings.php
11. Manually configure nginx for PHP

### Proposed Automated Workflow
1. `./install.sh avc avctest` - Creates site, clones profile, creates symlinks, enables modules
2. `./copy.sh avctest avctest_stg` - Works (unchanged)
3. `./live.sh avctest` - Provisions server, creates DB, syncs files+DB, configures nginx, sets up SSL

**Reduction:** 11 manual steps → 3 commands
