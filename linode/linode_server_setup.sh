#!/bin/bash

################################################################################
# linode_server_setup.sh - Linode StackScript for NWP Server Provisioning
################################################################################
#
# This is a Linode StackScript that provisions a secure Ubuntu server for
# hosting NWP (Narrow Way Project) Drupal/OpenSocial sites.
#
# It implements security best practices from:
# https://www.digitalocean.com/community/tutorials/initial-server-setup-with-ubuntu-20-04
#
# Features:
#   - Creates non-root user with sudo privileges
#   - Configures SSH key authentication
#   - Disables root login via SSH
#   - Sets up UFW firewall
#   - Installs LEMP stack (Nginx, MariaDB, PHP 8.2)
#   - Configures server for Drupal hosting
#   - Installs Certbot for SSL certificates
#
# Usage:
#   This script is meant to be uploaded as a Linode StackScript and used
#   during server provisioning via the Linode CLI or Cloud Manager.
#
#   linode-cli linodes create \
#     --stackscript_id <your_stackscript_id> \
#     --stackscript_data '{"ssh_user":"nwp","ssh_pubkey":"ssh-ed25519 AAAA...","hostname":"test.example.com","email":"admin@example.com"}'
#
################################################################################

# <UDF name="ssh_user" label="SSH Username" default="nwp" example="nwp" />
# <UDF name="ssh_pubkey" label="SSH Public Key" example="ssh-ed25519 AAAA..." />
# <UDF name="hostname" label="Server Hostname" default="nwp-server" example="test.nwp.org" />
# <UDF name="email" label="Administrator Email" example="admin@example.com" />
# <UDF name="timezone" label="Timezone" default="America/New_York" example="America/New_York" />
# <UDF name="disable_root" label="Disable Root SSH Login" oneof="yes,no" default="yes" />

set -e  # Exit on error
set -x  # Log all commands (for debugging)

# Log everything to a file
exec > >(tee -a /var/log/nwp-setup.log)
exec 2>&1

echo "========================================"
echo "NWP Server Setup Starting"
echo "========================================"
echo "Date: $(date)"
echo "User: $SSH_USER"
echo "Hostname: $HOSTNAME"
echo "========================================"

################################################################################
# 1. SYSTEM UPDATES
################################################################################

echo "[1/9] Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get upgrade -y
apt-get install -y \
    curl \
    wget \
    git \
    unzip \
    vim \
    htop \
    net-tools \
    software-properties-common \
    apt-transport-https \
    ca-certificates \
    gnupg \
    lsb-release

echo "[OK] System packages updated"

################################################################################
# 2. CREATE NON-ROOT USER WITH SUDO PRIVILEGES
################################################################################

echo "[2/9] Creating user: $SSH_USER"

# Create user if it doesn't exist
if ! id "$SSH_USER" &>/dev/null; then
    useradd -m -s /bin/bash -G sudo "$SSH_USER"
    echo "[OK] User $SSH_USER created"
else
    echo "[OK] User $SSH_USER already exists"
fi

# Set up SSH directory and authorized_keys
mkdir -p "/home/$SSH_USER/.ssh"
chmod 700 "/home/$SSH_USER/.ssh"

# Add SSH public key
if [ -n "$SSH_PUBKEY" ]; then
    echo "$SSH_PUBKEY" > "/home/$SSH_USER/.ssh/authorized_keys"
    chmod 600 "/home/$SSH_USER/.ssh/authorized_keys"
    chown -R "$SSH_USER:$SSH_USER" "/home/$SSH_USER/.ssh"
    echo "[OK] SSH key configured for $SSH_USER"
else
    echo "[!] Warning: No SSH public key provided!"
fi

# Allow sudo without password (optional - can be removed for more security)
echo "$SSH_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$SSH_USER"
chmod 440 "/etc/sudoers.d/$SSH_USER"
echo "[OK] Sudo privileges granted to $SSH_USER"

################################################################################
# 3. CONFIGURE SSH SECURITY
################################################################################

echo "[3/9] Configuring SSH security..."

# Backup original SSH config
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup

# Disable root login if requested
if [ "$DISABLE_ROOT" = "yes" ]; then
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
    echo "[OK] Root login disabled"
else
    echo "[!] Root login still enabled (not recommended for production)"
fi

# Disable password authentication (force key-based auth)
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#*ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config

# Restart SSH service (try both names for compatibility)
systemctl restart ssh || systemctl restart sshd || true
echo "[OK] SSH security configured"

################################################################################
# 4. CONFIGURE FIREWALL (UFW)
################################################################################

echo "[4/9] Configuring firewall..."

# Install UFW if not present
apt-get install -y ufw

# Default policies
ufw default deny incoming
ufw default allow outgoing

# Allow SSH (IMPORTANT: Do this before enabling!)
ufw allow OpenSSH
ufw allow 22/tcp

# Allow HTTP and HTTPS
ufw allow 'Nginx Full' || true  # May not exist until Nginx is installed
ufw allow 80/tcp
ufw allow 443/tcp

# Enable firewall
ufw --force enable

# Show status
ufw status verbose
echo "[OK] Firewall configured and enabled"

################################################################################
# 5. SET HOSTNAME AND TIMEZONE
################################################################################

echo "[5/9] Configuring hostname and timezone..."

# Set hostname
if [ -n "$HOSTNAME" ]; then
    hostnamectl set-hostname "$HOSTNAME"
    echo "127.0.1.1 $HOSTNAME" >> /etc/hosts
    echo "[OK] Hostname set to: $HOSTNAME"
fi

# Set timezone
if [ -n "$TIMEZONE" ]; then
    timedatectl set-timezone "$TIMEZONE"
    echo "[OK] Timezone set to: $TIMEZONE"
fi

################################################################################
# 6. INSTALL NGINX
################################################################################

echo "[6/9] Installing Nginx..."

apt-get install -y nginx

# Start and enable Nginx
systemctl start nginx
systemctl enable nginx

# Create directory structure for sites
mkdir -p /var/www/prod
mkdir -p /var/www/test
mkdir -p /var/www/old
mkdir -p /var/www/html

# Set permissions
chown -R www-data:www-data /var/www
chmod -R 755 /var/www

echo "[OK] Nginx installed and configured"

################################################################################
# 7. INSTALL MARIADB
################################################################################

echo "[7/9] Installing MariaDB..."

apt-get install -y mariadb-server mariadb-client

# Start and enable MariaDB
systemctl start mariadb
systemctl enable mariadb

# Basic security: Remove test database and anonymous users
mysql -e "DELETE FROM mysql.user WHERE User='';"
mysql -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
mysql -e "DROP DATABASE IF EXISTS test;"
mysql -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';"
mysql -e "FLUSH PRIVILEGES;"

echo "[OK] MariaDB installed and secured"

################################################################################
# 8. INSTALL PHP 8.2 AND EXTENSIONS
################################################################################

echo "[8/9] Installing PHP 8.2..."

# Add PHP repository
add-apt-repository -y ppa:ondrej/php
apt-get update

# Install PHP 8.2 and required extensions for Drupal
apt-get install -y \
    php8.2-fpm \
    php8.2-mysql \
    php8.2-gd \
    php8.2-xml \
    php8.2-mbstring \
    php8.2-curl \
    php8.2-zip \
    php8.2-intl \
    php8.2-bcmath \
    php8.2-opcache \
    php8.2-apcu \
    php8.2-imagick

# Configure PHP for Drupal
PHP_INI="/etc/php/8.2/fpm/php.ini"
sed -i 's/^memory_limit.*/memory_limit = 512M/' "$PHP_INI"
sed -i 's/^upload_max_filesize.*/upload_max_filesize = 64M/' "$PHP_INI"
sed -i 's/^post_max_size.*/post_max_size = 64M/' "$PHP_INI"
sed -i 's/^max_execution_time.*/max_execution_time = 300/' "$PHP_INI"
sed -i 's/^max_input_time.*/max_input_time = 300/' "$PHP_INI"

# Enable OPcache for performance
cat >> "$PHP_INI" << 'EOF'

; OPcache configuration for production
opcache.enable=1
opcache.memory_consumption=256
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=10000
opcache.validate_timestamps=0
opcache.save_comments=1
opcache.fast_shutdown=1
EOF

# Start and enable PHP-FPM
systemctl start php8.2-fpm
systemctl enable php8.2-fpm

echo "[OK] PHP 8.2 installed and configured"

################################################################################
# 9. INSTALL COMPOSER AND DRUSH
################################################################################

echo "[9/9] Installing Composer and Drush..."

# Install Composer
EXPECTED_CHECKSUM="$(php -r 'copy("https://composer.github.io/installer.sig", "php://stdout");')"
php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
ACTUAL_CHECKSUM="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"

if [ "$EXPECTED_CHECKSUM" != "$ACTUAL_CHECKSUM" ]; then
    echo "ERROR: Invalid Composer installer checksum"
    rm composer-setup.php
    exit 1
fi

php composer-setup.php --quiet --install-dir=/usr/local/bin --filename=composer
rm composer-setup.php

# Set environment variable to allow Composer to run as root
export COMPOSER_ALLOW_SUPERUSER=1

# Verify Composer installation
composer --version
echo "[OK] Composer installed"

# Install Drush globally
composer global require drush/drush
ln -sf "$HOME/.config/composer/vendor/bin/drush" /usr/local/bin/drush

echo "[OK] Drush installed"

################################################################################
# 10. INSTALL CERTBOT FOR SSL
################################################################################

echo "[10/10] Installing Certbot..."

apt-get install -y certbot python3-certbot-nginx

echo "[OK] Certbot installed"

################################################################################
# FINAL SETUP
################################################################################

echo "========================================"
echo "Creating helper scripts..."
echo "========================================"

# Create a welcome script for the user
cat > "/home/$SSH_USER/welcome.sh" << 'WELCOME'
#!/bin/bash

echo "========================================"
echo "Welcome to NWP Linode Server"
echo "========================================"
echo ""
echo "Server Information:"
echo "  Hostname: $(hostname)"
echo "  IP Address: $(hostname -I | awk '{print $1}')"
echo "  OS: $(lsb_release -d | cut -f2)"
echo "  Kernel: $(uname -r)"
echo ""
echo "Installed Software:"
echo "  Nginx: $(nginx -v 2>&1 | cut -d'/' -f2)"
echo "  PHP: $(php -v | head -n1 | cut -d' ' -f2)"
echo "  MariaDB: $(mysql --version | awk '{print $5}' | sed 's/,$//')"
echo "  Composer: $(composer --version 2>/dev/null | awk '{print $3}')"
echo ""
echo "Directory Structure:"
echo "  /var/www/prod  - Production site"
echo "  /var/www/test  - Test/staging site"
echo "  /var/www/old   - Previous production (for rollback)"
echo ""
echo "Useful Commands:"
echo "  sudo systemctl status nginx    - Check Nginx status"
echo "  sudo systemctl status php8.2-fpm - Check PHP-FPM status"
echo "  sudo systemctl status mariadb  - Check MariaDB status"
echo "  sudo ufw status                - Check firewall status"
echo "  sudo tail -f /var/log/nwp-setup.log - View setup log"
echo ""
echo "Next Steps:"
echo "  1. Configure DNS to point to this server's IP"
echo "  2. Deploy your site using linode_deploy.sh"
echo "  3. Set up SSL with: sudo certbot --nginx -d yourdomain.com"
echo ""
echo "Documentation:"
echo "  Setup log: /var/log/nwp-setup.log"
echo ""
echo "========================================"
WELCOME

chmod +x "/home/$SSH_USER/welcome.sh"
chown "$SSH_USER:$SSH_USER" "/home/$SSH_USER/welcome.sh"

# Add welcome script to bashrc
if ! grep -q "welcome.sh" "/home/$SSH_USER/.bashrc"; then
    echo "" >> "/home/$SSH_USER/.bashrc"
    echo "# NWP Server Welcome" >> "/home/$SSH_USER/.bashrc"
    echo "~/welcome.sh" >> "/home/$SSH_USER/.bashrc"
fi

# Create directory for NWP scripts
mkdir -p "/home/$SSH_USER/nwp-scripts"
chown -R "$SSH_USER:$SSH_USER" "/home/$SSH_USER/nwp-scripts"

################################################################################
# COMPLETION
################################################################################

echo "========================================"
echo "NWP Server Setup Complete!"
echo "========================================"
echo "Date: $(date)"
echo ""
echo "Server Details:"
echo "  Hostname: $HOSTNAME"
echo "  User: $SSH_USER"
echo "  SSH Key: Configured"
echo "  Root Login: $([ "$DISABLE_ROOT" = "yes" ] && echo "Disabled" || echo "Enabled")"
echo ""
echo "Services Running:"
systemctl is-active nginx && echo "  [OK] Nginx" || echo "  [X] Nginx"
systemctl is-active php8.2-fpm && echo "  [OK] PHP 8.2-FPM" || echo "  [X] PHP 8.2-FPM"
systemctl is-active mariadb && echo "  [OK] MariaDB" || echo "  [X] MariaDB"
echo ""
echo "Firewall Status:"
ufw status | grep "Status:" | awk '{print "  " $0}'
echo ""
echo "To connect to this server:"
echo "  ssh $SSH_USER@$HOSTNAME"
echo ""
echo "Setup log saved to: /var/log/nwp-setup.log"
echo "========================================"

# Reboot to ensure all changes take effect (optional)
# echo "Rebooting server in 30 seconds..."
# shutdown -r +1 "Server setup complete. Rebooting to apply all changes..."
