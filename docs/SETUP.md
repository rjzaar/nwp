# NWP Complete Setup Guide

This guide provides step-by-step instructions to set up the Narrow Way Project (NWP) from scratch, including all automated and manual steps.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Quick Start (5 minutes)](#quick-start-5-minutes)
- [Complete Setup (30-60 minutes)](#complete-setup-30-60-minutes)
  - [Step 1: Clone the Repository](#step-1-clone-the-repository)
  - [Step 2: Install Prerequisites](#step-2-install-prerequisites)
  - [Step 3: Configuration Files](#step-3-configuration-files)
  - [Step 4: SSH Key Setup](#step-4-ssh-key-setup)
  - [Step 5: Linode API Setup (Optional)](#step-5-linode-api-setup-optional)
  - [Step 6: GitLab Server Setup (Optional)](#step-6-gitlab-server-setup-optional)
  - [Step 7: Verify Installation](#step-7-verify-installation)
- [Manual Steps Summary](#manual-steps-summary)
- [Post-Setup Tasks](#post-setup-tasks)
- [Troubleshooting](#troubleshooting)

## Prerequisites

NWP requires the following software. Don't worry if they're not installed - the setup script handles most of this automatically.

| Software | Purpose | Installation |
|----------|---------|--------------|
| Docker | Container runtime | Automatic via setup.sh |
| DDEV | Local dev environment | Automatic via setup.sh |
| Composer | PHP dependency manager | Automatic via setup.sh |
| Git | Version control | Automatic via setup.sh |
| yq | YAML processing | Automatic via setup.sh |
| Linode CLI | Server management | Optional, manual |

## Quick Start (5 minutes)

For a basic local development setup:

```bash
# Clone repository
git clone git@github.com:rjzaar/nwp.git
cd nwp

# Install prerequisites (Docker, DDEV, Composer, etc.)
./setup.sh

# View available recipes
./install.sh --list

# Install a site
./install.sh nwp mysite
```

That's it for basic usage! Continue reading for complete infrastructure setup.

## Complete Setup (30-60 minutes)

### Step 1: Clone the Repository

```bash
git clone git@github.com:rjzaar/nwp.git
cd nwp
```

**Manual step**: If you don't have SSH keys for GitHub, either:
- Generate them: `ssh-keygen -t ed25519 -C "your.email@example.com"`
- Add to GitHub: https://github.com/settings/keys
- Or use HTTPS: `git clone https://github.com/rjzaar/nwp.git`

### Step 2: Install Prerequisites

```bash
./setup.sh
```

This automatically installs:
- Docker (if missing)
- DDEV (if missing)
- Composer (if missing)
- yq (if missing)

**Manual steps required**:

1. **Add user to docker group** (if prompted):
   ```bash
   sudo usermod -aG docker $USER
   newgrp docker  # Or log out and back in
   ```

2. **Verify Docker is running**:
   ```bash
   docker ps
   ```

### Step 3: Configuration Files

NWP uses two main configuration files:

#### 3.1 Create cnwp.yml

Copy the example configuration:

```bash
cp example.cnwp.yml cnwp.yml
```

Edit `cnwp.yml` to configure your domain:

```yaml
settings:
  url: yourdomain.org    # Your primary domain
  database: mariadb
  php: 8.2

recipes:
  # Your site recipes here
```

**Important**: `cnwp.yml` is gitignored - it contains environment-specific settings.

#### 3.2 Create .secrets.yml

Copy the example secrets file:

```bash
cp .secrets.example.yml .secrets.yml
chmod 600 .secrets.yml
```

Add your credentials:

```yaml
# Linode API token (required for server provisioning)
linode:
  api_token: "your-linode-api-token-here"

# GitLab credentials (added automatically by setup scripts)
gitlab:
  server:
    domain: git.yourdomain.org
    ip: 0.0.0.0
    linode_id: 0
    ssh_user: gitlab
    ssh_key: git/keys/gitlab_linode
  admin:
    url: https://git.yourdomain.org
    username: root
    initial_password: ""
    password: ""
```

**Manual step**: Get a Linode API token:
1. Go to https://cloud.linode.com/profile/tokens
2. Create a Personal Access Token with Read/Write permissions for:
   - Linodes
   - StackScripts
   - Domains
3. Copy the token to `.secrets.yml`

### Step 4: SSH Key Setup

For deployment to production servers:

```bash
./setup-ssh.sh
```

This creates:
- `keys/nwp` - Private key (gitignored)
- `keys/nwp.pub` - Public key (gitignored)
- `~/.ssh/nwp` - Installed private key

**Manual step**: Add public key to Linode:
1. Copy the displayed public key
2. Go to https://cloud.linode.com/profile/keys
3. Click "Add SSH Key"
4. Paste the key and save

See [SSH_SETUP.md](SSH_SETUP.md) for detailed instructions.

### Step 5: Linode API Setup (Optional)

If you want to provision servers via command line:

```bash
# Install Linode CLI
pip3 install linode-cli

# Configure with your API token
linode-cli configure
```

**Manual step**: When prompted:
- Enter your API token
- Choose default region (e.g., `us-east`)
- Choose default type (e.g., `g6-standard-2`)

Verify installation:

```bash
linode-cli linodes list
```

### Step 6: GitLab Server Setup (Optional)

To set up a self-hosted GitLab server:

```bash
cd git
./setup_gitlab_site.sh
```

This automatically:
- Reads domain from `cnwp.yml` (uses `git.<url>`)
- Generates SSH keys for GitLab access
- Uploads provisioning StackScript to Linode
- Creates a 4GB Linode server
- Installs GitLab CE with SSL
- Configures SSH access (`ssh git-server`)
- Stores credentials in `.secrets.yml`

**Manual steps required**:

1. **Configure DNS** (before or after server creation):

   Option A - Using Linode DNS:
   ```bash
   # Create domain (if not exists)
   linode-cli domains create --domain yourdomain.org --type master --soa_email admin@yourdomain.org

   # Create A record for git subdomain
   linode-cli domains records-create DOMAIN_ID --type A --name git --target SERVER_IP
   ```

   Option B - External DNS provider:
   - Log into your DNS provider
   - Create an A record: `git.yourdomain.org` -> `SERVER_IP`

2. **Update nameservers** (if using Linode DNS):
   - Go to your domain registrar
   - Set nameservers to:
     - ns1.linode.com
     - ns2.linode.com
     - ns3.linode.com
     - ns4.linode.com
     - ns5.linode.com

3. **Wait for provisioning** (~10-15 minutes):
   ```bash
   # Check server status
   ssh git-server

   # View setup log (once connected)
   sudo tail -f /var/log/gitlab-setup.log
   ```

4. **Get GitLab root password**:
   ```bash
   ssh git-server 'sudo cat /root/gitlab_credentials.txt'
   ```

   Update `.secrets.yml` with the password.

5. **First login and password change**:
   - Navigate to https://git.yourdomain.org
   - Login with username `root` and the initial password
   - **Change the password immediately** (expires after 24 hours)
   - Update `.secrets.yml` with the new password

### Step 7: Verify Installation

Run the test suite to verify everything works:

```bash
./test-nwp.sh
```

Expected results:
- All prerequisite checks pass
- Site installation works
- Backup/restore works
- Copy operations work

## Manual Steps Summary

Here's a quick checklist of all required manual steps:

### Required for Basic Setup

- [ ] Generate GitHub SSH key (if not using HTTPS)
- [ ] Add user to docker group (if prompted)

### Required for Server Provisioning

- [ ] Create Linode API token
- [ ] Add token to `.secrets.yml`
- [ ] Configure Linode CLI
- [ ] Add SSH public key to Linode profile

### Required for GitLab

- [ ] Configure DNS for git.yourdomain.org
- [ ] Update nameservers (if using Linode DNS)
- [ ] Get and save GitLab root password
- [ ] Change GitLab root password on first login
- [ ] Update `.secrets.yml` with new password

## Post-Setup Tasks

### Install Your First Site

```bash
# List available recipes
./install.sh --list

# Install a site
./install.sh nwp mysite

# Access the site
# URL will be displayed, typically https://mysite.ddev.site
```

### Configure SSH for Easy Access

After GitLab setup, SSH config is automatically added:

```bash
# Connect to GitLab server
ssh git-server

# Equivalent to:
ssh -i ~/.ssh/gitlab_linode gitlab@git.yourdomain.org
```

To add more hosts, edit `~/.ssh/config`:

```
Host production
    HostName your-production-ip
    User deploy
    IdentityFile ~/.ssh/nwp
    IdentitiesOnly yes
```

### Set Up Deployment Workflow

```bash
# Create staging from development
./dev2stg.sh mysite

# Test on staging
./testos.sh mysite_stg

# Deploy staging to production (when ready)
./stg2prod.sh mysite_stg
```

## Troubleshooting

### Docker not running

```bash
# Check status
systemctl status docker

# Start Docker
sudo systemctl start docker

# Enable on boot
sudo systemctl enable docker
```

### Permission denied (docker)

```bash
# Add user to docker group
sudo usermod -aG docker $USER

# Log out and back in, or run:
newgrp docker
```

### SSH connection refused

```bash
# Check key permissions
chmod 600 ~/.ssh/nwp
chmod 600 ~/.ssh/gitlab_linode

# Test with verbose output
ssh -vvv git-server
```

### GitLab not accessible

```bash
# Check server status
ssh git-server 'sudo gitlab-ctl status'

# View logs
ssh git-server 'sudo gitlab-ctl tail'

# Reconfigure if needed
ssh git-server 'sudo gitlab-ctl reconfigure'
```

### DNS not resolving

```bash
# Check DNS propagation
dig git.yourdomain.org +short

# Check nameservers
dig yourdomain.org NS +short
```

### Linode CLI errors

```bash
# Reconfigure
linode-cli configure

# Check token permissions
linode-cli account view
```

## Configuration Reference

### cnwp.yml Structure

```yaml
settings:
  url: yourdomain.org       # Base domain
  database: mariadb         # mariadb or mysql
  php: 8.2                  # PHP version
  services:
    redis:
      enabled: false
    solr:
      enabled: false

recipes:
  myrecipe:
    source: drupal/recommended-project:^10.2
    profile: standard
    webroot: web
    install_modules: module1 module2
    auto: y

sites:
  mysite:
    directory: /path/to/site
    recipe: myrecipe
    environment: development
    purpose: indefinite
    created: 2025-01-01T00:00:00Z
```

### .secrets.yml Structure

```yaml
linode:
  api_token: "your-token-here"

gitlab:
  server:
    domain: git.yourdomain.org
    ip: 1.2.3.4
    linode_id: 12345678
    ssh_user: gitlab
    ssh_key: git/keys/gitlab_linode
  admin:
    url: https://git.yourdomain.org
    username: root
    initial_password: "from-server"
    password: "your-changed-password"
```

## See Also

- [README.md](../README.md) - Main documentation
- [SSH_SETUP.md](SSH_SETUP.md) - Detailed SSH key setup
- [PRODUCTION_DEPLOYMENT.md](PRODUCTION_DEPLOYMENT.md) - Production deployment guide
- [SCRIPTS_IMPLEMENTATION.md](SCRIPTS_IMPLEMENTATION.md) - Script documentation
- [git/README.md](../git/README.md) - GitLab deployment details
