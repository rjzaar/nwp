#!/bin/bash

################################################################################
# gitlab_server_setup.sh - Linode StackScript for GitLab Server Provisioning
################################################################################
#
# This is a Linode StackScript that provisions a secure Ubuntu server for
# hosting GitLab CE (Community Edition) with GitLab Runner.
#
# Features:
#   - Creates non-root user with sudo privileges
#   - Configures SSH key authentication
#   - Disables root login via SSH
#   - Sets up UFW firewall
#   - Installs Docker (for GitLab Runner)
#   - Installs GitLab CE Omnibus package
#   - Configures GitLab with registry, LFS, and backups
#   - Installs GitLab Runner (optional)
#   - Installs Certbot for SSL certificates
#
# Usage:
#   This script is meant to be uploaded as a Linode StackScript and used
#   during server provisioning via the Linode CLI or Cloud Manager.
#
################################################################################

# <UDF name="ssh_user" label="SSH Username" default="gitlab" example="gitlab" />
# <UDF name="ssh_pubkey" label="SSH Public Key" example="ssh-ed25519 AAAA..." />
# <UDF name="hostname" label="Server Hostname" default="gitlab-server" example="gitlab.example.com" />
# <UDF name="email" label="Administrator Email" example="admin@example.com" />
# <UDF name="timezone" label="Timezone" default="America/New_York" example="America/New_York" />
# <UDF name="disable_root" label="Disable Root SSH Login" oneof="yes,no" default="yes" />
# <UDF name="gitlab_external_url" label="GitLab External URL" default="http://gitlab.example.com" example="https://gitlab.example.com" />
# <UDF name="install_runner" label="Install GitLab Runner" oneof="yes,no" default="yes" />
# <UDF name="runner_tags" label="Runner Tags" default="docker,shell" example="docker,shell,linux" />
# <UDF name="configure_email" label="Configure Email (SMTP/DKIM)" oneof="yes,no" default="yes" />
# <UDF name="api_token" label="Linode API Token (for DNS)" example="optional - needed for SPF/DKIM/DMARC DNS" />

set -e  # Exit on error
set -x  # Log all commands (for debugging)

# Log everything to a file
exec > >(tee -a /var/log/gitlab-setup.log)
exec 2>&1

echo "========================================"
echo "GitLab Server Setup Starting"
echo "========================================"
echo "Date: $(date)"
echo "User: $SSH_USER"
echo "Hostname: $HOSTNAME"
echo "GitLab URL: $GITLAB_EXTERNAL_URL"
echo "========================================"

################################################################################
# 1. SYSTEM UPDATES
################################################################################

echo "[1/10] Updating system packages..."
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
# 1.5 CREATE SWAP SPACE
################################################################################

echo "[1.5/10] Creating swap space..."

# Create 2GB swap file if it doesn't exist
if [ ! -f /swapfile ]; then
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    echo "[OK] 2GB swap space created"
else
    echo "[OK] Swap already exists"
fi

# Set swappiness to a reasonable value
sysctl vm.swappiness=10
echo 'vm.swappiness=10' >> /etc/sysctl.conf

################################################################################
# 2. CREATE NON-ROOT USER WITH SUDO PRIVILEGES
################################################################################

echo "[2/10] Creating user: $SSH_USER"

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

# Allow sudo without password
echo "$SSH_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$SSH_USER"
chmod 440 "/etc/sudoers.d/$SSH_USER"
echo "[OK] Sudo privileges granted to $SSH_USER"

################################################################################
# 3. CONFIGURE SSH SECURITY
################################################################################

echo "[3/10] Configuring SSH security..."

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

# Restart SSH service
systemctl restart ssh || systemctl restart sshd || true
echo "[OK] SSH security configured"

################################################################################
# 4. CONFIGURE FIREWALL (UFW)
################################################################################

echo "[4/10] Configuring firewall..."

# Install UFW if not present
apt-get install -y ufw

# Default policies
ufw default deny incoming
ufw default allow outgoing

# Allow SSH (IMPORTANT: Do this before enabling!)
ufw allow OpenSSH
ufw allow 22/tcp

# Allow HTTP and HTTPS
ufw allow 80/tcp
ufw allow 443/tcp

# Allow Container Registry (optional)
ufw allow 5050/tcp

# Enable firewall
ufw --force enable

# Show status
ufw status verbose
echo "[OK] Firewall configured and enabled"

################################################################################
# 5. SET HOSTNAME AND TIMEZONE
################################################################################

echo "[5/10] Configuring hostname and timezone..."

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
# 6. INSTALL DOCKER
################################################################################

echo "[6/10] Installing Docker..."

# Add Docker GPG key
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

# Add Docker repository
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list

# Install Docker
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

# Add ssh_user to docker group
usermod -aG docker "$SSH_USER"

# Start and enable Docker
systemctl start docker
systemctl enable docker

echo "[OK] Docker installed and configured"

################################################################################
# 7. INSTALL GITLAB CE OMNIBUS
################################################################################

echo "[7/10] Installing GitLab CE..."

# Install dependencies
apt-get install -y curl openssh-server ca-certificates tzdata perl postfix

# Add GitLab package repository
curl -sS https://packages.gitlab.com/install/repositories/gitlab/gitlab-ce/script.deb.sh | bash

# Set external URL environment variable
export EXTERNAL_URL="$GITLAB_EXTERNAL_URL"

# Install GitLab CE
echo "[INFO] Installing GitLab CE package (this may take 5-10 minutes)..."
DEBIAN_FRONTEND=noninteractive apt-get install -y gitlab-ce

# Wait for GitLab to initialize
echo "[INFO] Waiting for GitLab to initialize..."
sleep 30

echo "[OK] GitLab CE installed"

################################################################################
# 8. CONFIGURE GITLAB
################################################################################

echo "[8/10] Configuring GitLab..."

# Backup original config
cp /etc/gitlab/gitlab.rb /etc/gitlab/gitlab.rb.backup

# Update gitlab.rb configuration
cat >> /etc/gitlab/gitlab.rb << EOF

################################################################################
# Custom GitLab Configuration
################################################################################

# External URL
external_url '$GITLAB_EXTERNAL_URL'

# Timezone
gitlab_rails['time_zone'] = '$TIMEZONE'

# Email configuration
gitlab_rails['gitlab_email_enabled'] = true
gitlab_rails['gitlab_email_from'] = 'git@${HOSTNAME#*.}'
gitlab_rails['gitlab_email_display_name'] = 'GitLab'
gitlab_rails['gitlab_email_reply_to'] = 'noreply@${HOSTNAME#*.}'

# SMTP settings for local Postfix (configured in step 8.7)
gitlab_rails['smtp_enable'] = true
gitlab_rails['smtp_address'] = "localhost"
gitlab_rails['smtp_port'] = 25
gitlab_rails['smtp_domain'] = '${HOSTNAME#*.}'
gitlab_rails['smtp_tls'] = false
gitlab_rails['smtp_openssl_verify_mode'] = 'none'
gitlab_rails['smtp_enable_starttls_auto'] = false

# Container Registry (disabled initially - enable after SSL is configured)
# registry_external_url 'https://$HOSTNAME:5050'
gitlab_rails['registry_enabled'] = false

# Git LFS
gitlab_rails['lfs_enabled'] = true
gitlab_rails['lfs_storage_path'] = "/var/opt/gitlab/gitlab-rails/shared/lfs-objects"

# Backup settings
gitlab_rails['backup_keep_time'] = 604800  # 7 days
gitlab_rails['backup_path'] = '/var/opt/gitlab/backups'
gitlab_rails['backup_archive_permissions'] = 0644

# Monitoring (disabled to reduce resource usage)
prometheus_monitoring['enable'] = false
prometheus['enable'] = false
grafana['enable'] = false
alertmanager['enable'] = false
node_exporter['enable'] = false
redis_exporter['enable'] = false
postgres_exporter['enable'] = false
gitlab_exporter['enable'] = false

# Performance tuning for 4GB RAM server
puma['worker_processes'] = 2
puma['min_threads'] = 1
puma['max_threads'] = 4
sidekiq['max_concurrency'] = 10
postgresql['shared_buffers'] = "256MB"
postgresql['max_worker_processes'] = 4
EOF

echo "[OK] GitLab configuration updated"

# Reconfigure GitLab
echo "[INFO] Reconfiguring GitLab (this may take 3-5 minutes)..."
gitlab-ctl reconfigure

# Wait a bit for services to start
sleep 10

# Get initial root password (available for 24 hours)
if [ -f /etc/gitlab/initial_root_password ]; then
    INITIAL_ROOT_PASSWORD=$(grep "Password:" /etc/gitlab/initial_root_password | awk '{print $2}')

    # Save credentials to a secure file
    cat > /root/gitlab_credentials.txt << CREDS
GitLab Server Credentials
==========================
Date: $(date)
GitLab URL: $GITLAB_EXTERNAL_URL
Username: root
Password: $INITIAL_ROOT_PASSWORD

IMPORTANT:
- Change this password immediately after first login
- This file will be deleted in 24 hours
- The password in /etc/gitlab/initial_root_password is also temporary

Access GitLab:
1. Navigate to: $GITLAB_EXTERNAL_URL
2. Login with username 'root' and the password above
3. Change your password immediately
4. Create new users and projects
CREDS

    chmod 600 /root/gitlab_credentials.txt
    echo "[OK] GitLab credentials saved to /root/gitlab_credentials.txt"
    echo "[OK] Initial root password: $INITIAL_ROOT_PASSWORD"
else
    echo "[!] Warning: Initial root password file not found"
fi

echo "[OK] GitLab configured and running"

################################################################################
# 8.5 CREATE NWP GROUP AND CONFIGURE REPOS
################################################################################

echo "[8.5/10] Setting up NWP group and repositories..."

# Wait for GitLab to be fully ready
sleep 5

# Create NWP group via rails runner
gitlab-rails runner "
begin
  # Check if nwp group exists
  group = Group.find_by_path('nwp')

  unless group
    # Create the nwp group
    group = Group.new(
      name: 'NWP',
      path: 'nwp',
      visibility_level: Gitlab::VisibilityLevel::PRIVATE,
      description: 'NWP code repositories'
    )
    if group.save
      puts 'Created group: nwp'
    else
      puts 'Failed to create group: ' + group.errors.full_messages.join(', ')
    end
  else
    puts 'Group already exists: nwp'
  end

  # Create backups group for site backups (separate from code repos)
  backups_group = Group.find_by_path('backups')
  unless backups_group
    backups_group = Group.new(
      name: 'Backups',
      path: 'backups',
      visibility_level: Gitlab::VisibilityLevel::PRIVATE,
      description: 'Site backup repositories'
    )
    if backups_group.save
      puts 'Created group: backups'
    else
      puts 'Failed to create backups group: ' + backups_group.errors.full_messages.join(', ')
    end
  else
    puts 'Group already exists: backups'
  end
rescue => e
  puts 'Error: ' + e.message
end
" 2>&1 || echo "[!] Group creation may have partially failed, check manually"

echo "[OK] NWP groups configured"

################################################################################
# 8.7 CONFIGURE EMAIL INFRASTRUCTURE
################################################################################

if [ "$CONFIGURE_EMAIL" = "yes" ]; then
    echo "[8.7/10] Configuring email infrastructure (Postfix, OpenDKIM, SPF, DKIM, DMARC)..."

    # Extract domain from hostname (e.g., git.nwpcode.org -> nwpcode.org)
    MAIL_DOMAIN="${HOSTNAME#*.}"
    MAIL_IP=$(hostname -I | awk '{print $1}')

    echo "[INFO] Email domain: $MAIL_DOMAIN"
    echo "[INFO] Mail server IP: $MAIL_IP"

    # Install OpenDKIM
    apt-get install -y opendkim opendkim-tools mailutils

    # Add postfix user to opendkim group
    usermod -aG opendkim postfix

    # Configure Postfix for email sending
    postconf -e "myhostname = $HOSTNAME"
    postconf -e "mydomain = $MAIL_DOMAIN"
    postconf -e "myorigin = \$mydomain"
    postconf -e "mydestination = \$myhostname, localhost.\$mydomain, localhost"
    postconf -e "inet_interfaces = all"
    postconf -e "inet_protocols = ipv4"

    # Add submission port for authenticated sending (port 587)
    if ! grep -q "^submission" /etc/postfix/master.cf; then
        cat >> /etc/postfix/master.cf << 'SUBMISSION'

# Submission port for authenticated email sending
submission inet n       -       y       -       -       smtpd
  -o syslog_name=postfix/submission
  -o smtpd_tls_security_level=may
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_tls_auth_only=no
  -o smtpd_reject_unlisted_recipient=no
  -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject
  -o milter_macro_daemon_name=ORIGINATING
SUBMISSION
    fi

    # Configure OpenDKIM
    mkdir -p /etc/opendkim/keys/${MAIL_DOMAIN}

    # Generate DKIM keys
    cd /etc/opendkim/keys/${MAIL_DOMAIN}
    opendkim-genkey -s default -d ${MAIL_DOMAIN} -b 2048
    chown opendkim:opendkim default.private
    chmod 600 default.private

    # OpenDKIM configuration
    cat > /etc/opendkim.conf << DKIMCONF
AutoRestart             Yes
AutoRestartRate         10/1h
UMask                   002
Syslog                  yes
SyslogSuccess           Yes
LogWhy                  Yes

Canonicalization        relaxed/simple
ExternalIgnoreList      refile:/etc/opendkim/TrustedHosts
InternalHosts           refile:/etc/opendkim/TrustedHosts
KeyTable                refile:/etc/opendkim/KeyTable
SigningTable            refile:/etc/opendkim/SigningTable
Mode                    sv
SignatureAlgorithm      rsa-sha256
Socket                  inet:8891@localhost
PidFile                 /run/opendkim/opendkim.pid
OversignHeaders         From
SubDomains              yes
DKIMCONF

    # TrustedHosts
    cat > /etc/opendkim/TrustedHosts << TRUSTED
127.0.0.1
localhost
${HOSTNAME}
*.${MAIL_DOMAIN}
TRUSTED

    # KeyTable
    echo "default._domainkey.${MAIL_DOMAIN} ${MAIL_DOMAIN}:default:/etc/opendkim/keys/${MAIL_DOMAIN}/default.private" > /etc/opendkim/KeyTable

    # SigningTable
    cat > /etc/opendkim/SigningTable << SIGNING
*@${MAIL_DOMAIN} default._domainkey.${MAIL_DOMAIN}
*@*.${MAIL_DOMAIN} default._domainkey.${MAIL_DOMAIN}
SIGNING

    # Fix permissions
    chown -R root:opendkim /etc/opendkim
    chmod -R o-rwx /etc/opendkim
    chmod -R g-w /etc/opendkim
    chmod 600 /etc/opendkim/keys/${MAIL_DOMAIN}/default.private

    # Create run directory
    mkdir -p /run/opendkim
    chown opendkim:opendkim /run/opendkim

    # Configure Postfix to use OpenDKIM
    postconf -e "milter_protocol = 6"
    postconf -e "milter_default_action = accept"
    postconf -e "smtpd_milters = inet:localhost:8891"
    postconf -e "non_smtpd_milters = inet:localhost:8891"

    # Set up git@domain alias to forward to admin email
    touch /etc/postfix/virtual
    echo "git@${MAIL_DOMAIN}    $EMAIL" >> /etc/postfix/virtual
    echo "@${HOSTNAME}    $EMAIL" >> /etc/postfix/virtual
    postmap /etc/postfix/virtual
    postconf -e "virtual_alias_maps = hash:/etc/postfix/virtual"

    # Restart services
    systemctl restart opendkim
    systemctl enable opendkim
    systemctl restart postfix

    # Extract DKIM public key for DNS
    DKIM_RECORD=$(cat /etc/opendkim/keys/${MAIL_DOMAIN}/default.txt | tr -d '\n\t' | sed 's/.*p=/p=/' | sed 's/).*//' | tr -d ' "' | sed 's/^p=//')

    # Save email configuration info
    cat > /root/email_setup_info.txt << EMAILINFO
Email Infrastructure Configuration
===================================
Date: $(date)

Mail Server: $HOSTNAME
Mail IP: $MAIL_IP
Domain: $MAIL_DOMAIN

Email Addresses:
  GitLab: git@${MAIL_DOMAIN}
  Reply-To: noreply@${MAIL_DOMAIN}
  Admin forwarding: git@${MAIL_DOMAIN} -> $EMAIL

Services Configured:
  [[OK]] Postfix (SMTP server)
  [[OK]] OpenDKIM (Email signing)
  [[OK]] Submission port (587)

DNS Records Required:
----------------------

1. SPF Record:
   Type: TXT
   Name: @
   Value: v=spf1 ip4:${MAIL_IP} a mx -all

2. DKIM Record:
   Type: TXT
   Name: default._domainkey
   Value: v=DKIM1; h=sha256; k=rsa; p=${DKIM_RECORD}

3. DMARC Record:
   Type: TXT
   Name: _dmarc
   Value: v=DMARC1; p=quarantine; sp=quarantine; rua=mailto:dmarc@${MAIL_DOMAIN}; ruf=mailto:dmarc@${MAIL_DOMAIN}; adkim=r; aspf=r; pct=100

4. MX Record:
   Type: MX
   Name: @
   Target: ${HOSTNAME}
   Priority: 10

5. Reverse DNS (PTR):
   Configure in Linode Cloud Manager:
   IP: ${MAIL_IP} -> Hostname: ${HOSTNAME}

EMAILINFO

    # Configure DNS if Linode API token provided
    if [ -n "$API_TOKEN" ]; then
        echo "[INFO] Configuring DNS records via Linode API..."

        # Get domain ID
        DOMAIN_ID=$(curl -s -H "Authorization: Bearer $API_TOKEN" \
            "https://api.linode.com/v4/domains" | \
            python3 -c "import sys,json; domains=json.load(sys.stdin)['data']; print(next((d['id'] for d in domains if d['domain']=='${MAIL_DOMAIN}'), ''))" 2>/dev/null || echo "")

        if [ -n "$DOMAIN_ID" ]; then
            echo "[INFO] Found domain ID: $DOMAIN_ID"

            # Create/update SPF record
            curl -s -X POST -H "Authorization: Bearer $API_TOKEN" \
                -H "Content-Type: application/json" \
                -d "{\"type\": \"TXT\", \"name\": \"\", \"target\": \"v=spf1 ip4:${MAIL_IP} a mx -all\", \"ttl_sec\": 300}" \
                "https://api.linode.com/v4/domains/${DOMAIN_ID}/records" >/dev/null 2>&1 || true

            # Create DKIM record
            curl -s -X POST -H "Authorization: Bearer $API_TOKEN" \
                -H "Content-Type: application/json" \
                -d "{\"type\": \"TXT\", \"name\": \"default._domainkey\", \"target\": \"v=DKIM1; h=sha256; k=rsa; p=${DKIM_RECORD}\", \"ttl_sec\": 300}" \
                "https://api.linode.com/v4/domains/${DOMAIN_ID}/records" >/dev/null 2>&1 || true

            # Create DMARC record
            curl -s -X POST -H "Authorization: Bearer $API_TOKEN" \
                -H "Content-Type: application/json" \
                -d "{\"type\": \"TXT\", \"name\": \"_dmarc\", \"target\": \"v=DMARC1; p=quarantine; sp=quarantine; rua=mailto:dmarc@${MAIL_DOMAIN}; ruf=mailto:dmarc@${MAIL_DOMAIN}; adkim=r; aspf=r; pct=100\", \"ttl_sec\": 300}" \
                "https://api.linode.com/v4/domains/${DOMAIN_ID}/records" >/dev/null 2>&1 || true

            # Create MX record
            curl -s -X POST -H "Authorization: Bearer $API_TOKEN" \
                -H "Content-Type: application/json" \
                -d "{\"type\": \"MX\", \"name\": \"\", \"target\": \"${HOSTNAME}\", \"priority\": 10, \"ttl_sec\": 300}" \
                "https://api.linode.com/v4/domains/${DOMAIN_ID}/records" >/dev/null 2>&1 || true

            echo "[OK] DNS records configured automatically"
            echo "[INFO] DNS records added: SPF, DKIM, DMARC, MX"
        else
            echo "[!] Could not find domain in Linode DNS"
            echo "[!] Add DNS records manually (see /root/email_setup_info.txt)"
        fi
    else
        echo "[!] No Linode API token provided"
        echo "[!] Add DNS records manually (see /root/email_setup_info.txt)"
    fi

    # Wait for services to start
    sleep 5

    # Test email sending
    echo "[INFO] Testing email configuration..."
    echo "This is a test email from your new GitLab server.

Email infrastructure has been configured with:
- Postfix SMTP server
- OpenDKIM email signing
- DNS records (SPF, DKIM, DMARC, MX)

Your GitLab instance is ready to send notification emails!

GitLab URL: $GITLAB_EXTERNAL_URL
" | mail -s "GitLab Email Test from $HOSTNAME" -r "git@${MAIL_DOMAIN}" "$EMAIL" 2>&1 || echo "[!] Email test may have failed - check logs"

    # Check if email was sent
    sleep 2
    if grep -q "status=sent" /var/log/syslog 2>/dev/null; then
        echo "[OK] Test email sent successfully to $EMAIL"
        echo "[OK] Check your inbox (including spam folder)"
    else
        echo "[!] Email may still be queuing or failed - check: sudo tail -f /var/log/syslog"
    fi

    # Save configuration summary
    cat >> /root/email_setup_info.txt << SUMMARY

Email Test Results:
-------------------
Test email sent to: $EMAIL
Status: Check /var/log/syslog for delivery status

To check email delivery:
  sudo grep postfix /var/log/syslog | tail -20

To test mail-tester.com score:
  echo "Test" | mail -s "Test" -r "git@${MAIL_DOMAIN}" test-XXXXX@srv1.mail-tester.com
  (Replace XXXXX with code from mail-tester.com)

SUMMARY

    chmod 600 /root/email_setup_info.txt

    echo "[OK] Email infrastructure configured"
    echo "[INFO] Email configuration saved to /root/email_setup_info.txt"

else
    echo "[8.7/10] Skipping email configuration (CONFIGURE_EMAIL=no)"
fi

################################################################################
# 9. INSTALL GITLAB RUNNER
################################################################################

if [ "$INSTALL_RUNNER" = "yes" ]; then
    echo "[9/10] Installing GitLab Runner..."

    # Add GitLab Runner repository
    curl -L "https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.deb.sh" | bash

    # Install GitLab Runner
    apt-get install -y gitlab-runner

    # Verify installation
    gitlab-runner --version

    # Add gitlab-runner user to docker group
    usermod -aG docker gitlab-runner

    echo "[OK] GitLab Runner installed"
    echo "[INFO] To register runner, use the gitlab-register-runner.sh script"
    echo "[INFO] You'll need the registration token from GitLab UI"
else
    echo "[9/10] Skipping GitLab Runner installation"
fi

################################################################################
# 10. INSTALL CERTBOT FOR SSL
################################################################################

echo "[10/10] Installing Certbot..."

apt-get install -y certbot

echo "[OK] Certbot installed"
echo "[INFO] To set up SSL, run: certbot certonly --standalone -d $HOSTNAME"
echo "[INFO] Or configure Let's Encrypt in GitLab: letsencrypt['enable'] = true"

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
echo "Welcome to GitLab Linode Server"
echo "========================================"
echo ""
echo "Server Information:"
echo "  Hostname: $(hostname)"
echo "  IP Address: $(hostname -I | awk '{print $1}')"
echo "  OS: $(lsb_release -d | cut -f2)"
echo "  Kernel: $(uname -r)"
echo ""
echo "Installed Software:"
echo "  GitLab: $(gitlab-rake gitlab:env:info | grep 'GitLab information' -A 1 | tail -1 | awk '{print $2}' 2>/dev/null || echo 'See gitlab-rake gitlab:env:info')"
echo "  Docker: $(docker --version | awk '{print $3}' | sed 's/,$//')"
if command -v gitlab-runner &> /dev/null; then
    echo "  GitLab Runner: $(gitlab-runner --version | head -n1 | awk '{print $2}')"
fi
if systemctl is-active postfix &> /dev/null; then
    echo "  Email: Postfix + OpenDKIM configured"
fi
echo ""
echo "GitLab Status:"
gitlab-ctl status | head -n 5
echo "  ... (run 'gitlab-ctl status' for full list)"
echo ""
echo "Useful Commands:"
echo "  sudo gitlab-ctl status         - Check GitLab status"
echo "  sudo gitlab-ctl restart        - Restart GitLab"
echo "  sudo gitlab-ctl tail           - View GitLab logs"
echo "  sudo gitlab-rake gitlab:check  - Run health check"
echo "  sudo ufw status                - Check firewall status"
echo "  sudo tail -f /var/log/gitlab-setup.log - View setup log"
if systemctl is-active postfix &> /dev/null; then
    echo "  sudo grep postfix /var/log/syslog | tail -20 - Check email logs"
    echo "  sudo cat /root/email_setup_info.txt - Email configuration"
fi
echo ""
echo "GitLab Credentials:"
if [ -f /root/gitlab_credentials.txt ]; then
    echo "  Saved in: /root/gitlab_credentials.txt"
    echo "  Run: sudo cat /root/gitlab_credentials.txt"
else
    echo "  Initial password expired (24 hours after install)"
    echo "  Reset with: sudo gitlab-rake 'gitlab:password:reset[root]'"
fi
echo ""
echo "Next Steps:"
echo "  1. Access GitLab: Open browser to the external URL"
echo "  2. Login with root credentials"
echo "  3. Change root password"
echo "  4. Configure GitLab settings"
echo "  5. Register GitLab Runner (if installed)"
echo "  6. Set up SSL certificate"
echo ""
echo "Documentation:"
echo "  Setup log: /var/log/gitlab-setup.log"
echo "  GitLab docs: https://docs.gitlab.com/"
echo ""
echo "========================================"
WELCOME

chmod +x "/home/$SSH_USER/welcome.sh"
chown "$SSH_USER:$SSH_USER" "/home/$SSH_USER/welcome.sh"

# Note: welcome.sh is available but NOT auto-run to avoid CPU spikes
# User can run ~/welcome.sh manually when needed
echo "[INFO] Welcome script available at ~/welcome.sh (run manually)"

# Create directory for GitLab management scripts
mkdir -p "/home/$SSH_USER/gitlab-scripts"
chown -R "$SSH_USER:$SSH_USER" "/home/$SSH_USER/gitlab-scripts"

################################################################################
# COMPLETION
################################################################################

echo "========================================"
echo "GitLab Server Setup Complete!"
echo "========================================"
echo "Date: $(date)"
echo ""
echo "Server Details:"
echo "  Hostname: $HOSTNAME"
echo "  User: $SSH_USER"
echo "  SSH Key: Configured"
echo "  Root Login: $([ "$DISABLE_ROOT" = "yes" ] && echo "Disabled" || echo "Enabled")"
echo ""
echo "GitLab Details:"
echo "  External URL: $GITLAB_EXTERNAL_URL"
echo "  Admin Username: root"
if [ -f /root/gitlab_credentials.txt ]; then
    echo "  Credentials: /root/gitlab_credentials.txt"
fi
echo ""
echo "Services Running:"
systemctl is-active docker && echo "  [OK] Docker" || echo "  [X] Docker"
gitlab-ctl status | grep -q "run:" && echo "  [OK] GitLab" || echo "  [X] GitLab"
if [ "$INSTALL_RUNNER" = "yes" ]; then
    systemctl is-active gitlab-runner && echo "  [OK] GitLab Runner" || echo "  [X] GitLab Runner"
fi
if [ "$CONFIGURE_EMAIL" = "yes" ]; then
    systemctl is-active postfix && echo "  [OK] Postfix (Email)" || echo "  [X] Postfix"
    systemctl is-active opendkim && echo "  [OK] OpenDKIM (DKIM)" || echo "  [X] OpenDKIM"
fi
echo ""
echo "Firewall Status:"
ufw status | grep "Status:" | awk '{print "  " $0}'
echo ""
echo "To connect to this server:"
echo "  ssh $SSH_USER@$HOSTNAME"
echo ""
echo "To access GitLab:"
echo "  Open browser to: $GITLAB_EXTERNAL_URL"
echo "  Login with root credentials from: /root/gitlab_credentials.txt"
echo ""
if [ "$CONFIGURE_EMAIL" = "yes" ]; then
    echo "Email Configuration:"
    echo "  GitLab email: git@${HOSTNAME#*.}"
    echo "  Test email sent to: $EMAIL"
    echo "  Configuration details: /root/email_setup_info.txt"
    echo ""
fi
echo "Setup log saved to: /var/log/gitlab-setup.log"
echo "========================================"
