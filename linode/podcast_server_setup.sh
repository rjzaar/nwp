#!/bin/bash

################################################################################
# podcast_server_setup.sh - Linode StackScript for Castopod Podcast Hosting
################################################################################
#
# This is a Linode StackScript that provisions an Ubuntu server optimized for
# running Castopod podcast hosting platform via Docker.
#
# Features:
#   - Creates non-root user with sudo privileges
#   - Configures SSH key authentication
#   - Sets up UFW firewall
#   - Installs Docker and Docker Compose
#   - Prepares directory structure for Castopod
#   - Optionally installs monitoring tools
#
# Usage:
#   Upload as a Linode StackScript and use during server provisioning:
#
#   linode-cli linodes create \
#     --stackscript_id <your_stackscript_id> \
#     --stackscript_data '{"ssh_user":"podcast","ssh_pubkey":"ssh-ed25519 AAAA...","hostname":"podcast.example.com"}'
#
################################################################################

# <UDF name="ssh_user" label="SSH Username" default="podcast" example="podcast" />
# <UDF name="ssh_pubkey" label="SSH Public Key" example="ssh-ed25519 AAAA..." />
# <UDF name="hostname" label="Server Hostname" default="podcast-server" example="podcast.nwp.org" />
# <UDF name="email" label="Administrator Email" example="admin@example.com" />
# <UDF name="timezone" label="Timezone" default="America/New_York" example="America/New_York" />
# <UDF name="disable_root" label="Disable Root SSH Login" oneof="yes,no" default="yes" />
# <UDF name="install_monitoring" label="Install Monitoring (htop, netdata)" oneof="yes,no" default="no" />

set -e  # Exit on error
set -x  # Log all commands (for debugging)

# Log everything to a file
exec > >(tee -a /var/log/podcast-setup.log)
exec 2>&1

echo "========================================"
echo "Podcast Server Setup Starting"
echo "========================================"
echo "Date: $(date)"
echo "User: $SSH_USER"
echo "Hostname: $HOSTNAME"
echo "========================================"

################################################################################
# 1. SYSTEM UPDATES
################################################################################

echo "[1/8] Updating system packages..."
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
    lsb-release \
    jq

echo "[OK] System packages updated"

################################################################################
# 2. CREATE NON-ROOT USER WITH SUDO PRIVILEGES
################################################################################

echo "[2/8] Creating user: $SSH_USER"

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

echo "[3/8] Configuring SSH security..."

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

echo "[4/8] Configuring firewall..."

# Install UFW if not present
apt-get install -y ufw

# Default policies
ufw default deny incoming
ufw default allow outgoing

# Allow SSH
ufw allow OpenSSH
ufw allow 22/tcp

# Allow HTTP and HTTPS
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

echo "[5/8] Configuring hostname and timezone..."

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

echo "[6/8] Installing Docker..."

# Add Docker's official GPG key
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

# Add the repository to Apt sources
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install Docker
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Add user to docker group
usermod -aG docker "$SSH_USER"

# Start and enable Docker
systemctl start docker
systemctl enable docker

# Verify installation
docker --version
docker compose version

echo "[OK] Docker installed"

################################################################################
# 7. PREPARE CASTOPOD DIRECTORY
################################################################################

echo "[7/8] Preparing Castopod directory..."

# Create directory structure
mkdir -p /home/$SSH_USER/castopod
mkdir -p /var/log/caddy

# Set ownership
chown -R "$SSH_USER:$SSH_USER" /home/$SSH_USER/castopod
chown -R "$SSH_USER:$SSH_USER" /var/log/caddy

# Create placeholder files (will be replaced by deployment)
cat > /home/$SSH_USER/castopod/README.md << 'README'
# Castopod Podcast Server

This server is configured for Castopod podcast hosting.

## Deployment

Upload the following files to this directory:
- docker-compose.yml
- .env
- Caddyfile

Then run:
```bash
docker compose up -d
```

## Useful Commands

```bash
# View logs
docker compose logs -f

# Restart services
docker compose restart

# Stop all services
docker compose down

# Update images
docker compose pull
docker compose up -d
```

## Access

- Castopod: https://your-domain.com
- Admin: https://your-domain.com/admin

## Support

See NWP documentation: docs/podcast_setup.md
README

chown "$SSH_USER:$SSH_USER" /home/$SSH_USER/castopod/README.md

echo "[OK] Castopod directory prepared"

################################################################################
# 8. INSTALL MONITORING (OPTIONAL)
################################################################################

if [ "$INSTALL_MONITORING" = "yes" ]; then
    echo "[8/8] Installing monitoring tools..."

    # Install Netdata for real-time monitoring
    curl -fsSL https://my-netdata.io/kickstart.sh | bash -s -- --dont-wait

    # Configure Netdata to listen only on localhost (access via SSH tunnel)
    if [ -f /etc/netdata/netdata.conf ]; then
        sed -i 's/# bind to = \*/bind to = 127.0.0.1/' /etc/netdata/netdata.conf
        systemctl restart netdata
    fi

    echo "[OK] Monitoring installed (Netdata on localhost:19999)"
else
    echo "[8/8] Skipping monitoring installation"
fi

################################################################################
# CREATE HELPER SCRIPTS
################################################################################

echo "Creating helper scripts..."

# Create a welcome script
cat > "/home/$SSH_USER/welcome.sh" << 'WELCOME'
#!/bin/bash

echo "========================================"
echo "Welcome to NWP Podcast Server"
echo "========================================"
echo ""
echo "Server Information:"
echo "  Hostname: $(hostname)"
echo "  IP Address: $(hostname -I | awk '{print $1}')"
echo "  OS: $(lsb_release -d | cut -f2)"
echo "  Docker: $(docker --version 2>/dev/null | cut -d' ' -f3 | tr -d ',')"
echo ""
echo "Castopod Status:"
if docker compose -f ~/castopod/docker-compose.yml ps 2>/dev/null | grep -q "running"; then
    echo "  [OK] Castopod is running"
    docker compose -f ~/castopod/docker-compose.yml ps --format "table {{.Name}}\t{{.Status}}" 2>/dev/null | tail -n +2 | sed 's/^/  /'
else
    echo "  [!] Castopod is not running"
    echo "      Deploy with: cd ~/castopod && docker compose up -d"
fi
echo ""
echo "Useful Commands:"
echo "  docker compose -f ~/castopod/docker-compose.yml logs -f    # View logs"
echo "  docker compose -f ~/castopod/docker-compose.yml restart    # Restart"
echo "  docker compose -f ~/castopod/docker-compose.yml down       # Stop"
echo "  docker compose -f ~/castopod/docker-compose.yml pull       # Update"
echo ""
echo "Documentation: ~/castopod/README.md"
echo "Setup log: /var/log/podcast-setup.log"
echo "========================================"
WELCOME

chmod +x "/home/$SSH_USER/welcome.sh"
chown "$SSH_USER:$SSH_USER" "/home/$SSH_USER/welcome.sh"

# Add welcome script to bashrc
if ! grep -q "welcome.sh" "/home/$SSH_USER/.bashrc"; then
    echo "" >> "/home/$SSH_USER/.bashrc"
    echo "# NWP Podcast Server Welcome" >> "/home/$SSH_USER/.bashrc"
    echo "~/welcome.sh" >> "/home/$SSH_USER/.bashrc"
fi

# Create quick deployment script
cat > "/home/$SSH_USER/castopod/quick-start.sh" << 'QUICKSTART'
#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

if [ ! -f docker-compose.yml ]; then
    echo "ERROR: docker-compose.yml not found!"
    echo "Please upload your configuration files first."
    exit 1
fi

if [ ! -f .env ]; then
    echo "ERROR: .env file not found!"
    echo "Please upload your configuration files first."
    exit 1
fi

echo "Starting Castopod..."

# Load environment
set -a
source .env
set +a

# Pull and start
docker compose pull
docker compose up -d

echo ""
echo "Waiting for services..."
sleep 15

# Check status
docker compose ps

echo ""
echo "Castopod should now be accessible at: ${CP_BASEURL:-https://your-domain}"
echo ""
echo "If this is a fresh install, visit ${CP_BASEURL:-https://your-domain}/admin/install"
echo "to create your admin account."
QUICKSTART

chmod +x "/home/$SSH_USER/castopod/quick-start.sh"
chown "$SSH_USER:$SSH_USER" "/home/$SSH_USER/castopod/quick-start.sh"

################################################################################
# COMPLETION
################################################################################

echo "========================================"
echo "Podcast Server Setup Complete!"
echo "========================================"
echo "Date: $(date)"
echo ""
echo "Server Details:"
echo "  Hostname: $HOSTNAME"
echo "  User: $SSH_USER"
echo "  SSH Key: Configured"
echo "  Root Login: $([ "$DISABLE_ROOT" = "yes" ] && echo "Disabled" || echo "Enabled")"
echo ""
echo "Services:"
systemctl is-active docker && echo "  [OK] Docker" || echo "  [X] Docker"
echo ""
echo "Firewall Status:"
ufw status | grep "Status:" | awk '{print "  " $0}'
echo ""
echo "Castopod Directory: /home/$SSH_USER/castopod"
echo ""
echo "To connect to this server:"
echo "  ssh $SSH_USER@$(hostname -I | awk '{print $1}')"
echo ""
echo "Next steps:"
echo "  1. Upload docker-compose.yml, .env, and Caddyfile to ~/castopod/"
echo "  2. Run: cd ~/castopod && ./quick-start.sh"
echo "  3. Complete Castopod setup at https://your-domain/admin/install"
echo ""
echo "Setup log saved to: /var/log/podcast-setup.log"
echo "========================================"
