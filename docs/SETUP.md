# NWP Complete Setup Guide

This guide provides step-by-step instructions to set up the Narrow Way Project (NWP). The setup process is mostly automated - you just need to provide a few pieces of information.

## Table of Contents

- [Quick Start](#quick-start)
- [What Gets Automated](#what-gets-automated)
- [Manual Steps Required](#manual-steps-required)
- [Detailed Setup Process](#detailed-setup-process)
- [Setup Profiles](#setup-profiles)
- [Rollback and Uninstall](#rollback-and-uninstall)
- [Configuration Reference](#configuration-reference)
- [Troubleshooting](#troubleshooting)

## Quick Start

```bash
# Clone repository
git clone git@github.com:rjzaar/nwp.git
cd nwp

# Run interactive setup
./setup.sh

# Or auto-install core components only
./setup.sh --auto
```

The setup script will:
1. Show current installation status
2. Let you select which components to install
3. Collect required information (API tokens, domain) once
4. Automatically install everything selected
5. Configure all services and connections

## What Gets Automated

The setup script automates the following:

### Core Infrastructure (Local Development)
| Component | What It Does |
|-----------|--------------|
| Docker Engine | Container runtime for DDEV |
| Docker Compose | Multi-container orchestration |
| Docker Group | Adds user to docker group |
| DDEV | Local development environment |
| DDEV Config | Global DDEV configuration |
| mkcert | Local SSL certificate tool |
| mkcert CA | Certificate authority setup |

### NWP Tools
| Component | What It Does |
|-----------|--------------|
| NWP CLI | Global `pl` command for running scripts |
| NWP Config | Creates `cnwp.yml` from example |
| NWP Secrets | Creates `.secrets.yml` template |

### Linode Infrastructure (Server Provisioning)
| Component | What It Does |
|-----------|--------------|
| Linode CLI | Command-line tool for Linode API |
| Linode Config | Configures CLI with your API token |
| SSH Keys | Generates deployment SSH keys |

**Note:** SSH key upload to Linode is intentionally NOT automated for security reasons. You must manually add SSH keys to your Linode profile.

### GitLab Deployment (Self-Hosted Git)
| Component | What It Does |
|-----------|--------------|
| GitLab SSH Keys | Generates keys for GitLab access |
| GitLab Server | Provisions 4GB Linode server with GitLab CE |
| GitLab DNS | Creates DNS records in Linode |
| GitLab SSH Config | Configures `ssh git-server` alias |

## Manual Steps Required

Some steps cannot be automated and require your action:

### Before Running Setup

1. **Get a Linode API Token** (if using Linode/GitLab)
   - Go to https://cloud.linode.com/profile/tokens
   - Create token with Read/Write for: Linodes, StackScripts, Domains
   - Save the token - you'll enter it during setup

2. **Set Your Domain** (if deploying GitLab)
   - Edit `cnwp.yml` after it's created
   - Add your domain under settings:
     ```yaml
     settings:
       url: yourdomain.org
     ```

### After Running Setup

1. **Add SSH Key to Linode** (REQUIRED for server provisioning)
   - This step is intentionally manual for security reasons
   - Copy your public key: `cat ~/.ssh/nwp.pub`
   - Go to https://cloud.linode.com/profile/keys
   - Click "Add SSH Key" and paste the key
   - This key will be used for all new Linode servers

2. **Update Domain Nameservers** (if using Linode DNS)
   - Go to your domain registrar
   - Change nameservers to:
     - ns1.linode.com
     - ns2.linode.com
     - ns3.linode.com
     - ns4.linode.com
     - ns5.linode.com

3. **Change GitLab Root Password** (if GitLab installed)
   - Wait 10-15 minutes for GitLab to initialize
   - Get initial password: `ssh git-server 'sudo cat /root/gitlab_credentials.txt'`
   - Login at https://git.yourdomain.org
   - Change password immediately
   - Update `.secrets.yml` with new password

## Detailed Setup Process

### Step 1: Clone and Run Setup

```bash
git clone git@github.com:rjzaar/nwp.git
cd nwp
./setup.sh
```

### Step 2: Review Current Status

The setup script shows what's currently installed:

```
Current System Status
═══════════════════════════════════════════════════════════════

Core Infrastructure:
[✓] Docker Engine
[✓] Docker Compose Plugin
  [✓] Docker Group Membership
[✓] DDEV Development Environment
  [✓] DDEV Global Configuration
[✗] mkcert SSL Tool
  [✗] mkcert Certificate Authority

NWP Tools:
[✗] NWP CLI Command
[✗] NWP Configuration (cnwp.yml)
[✗] NWP Secrets (.secrets.yml)
...
```

### Step 3: Select Components

Use the interactive checkbox UI to select what you want:

- **Space** - Toggle selection
- **Enter** - Confirm selection
- Components with `└─` depend on their parent

The script automatically:
- Selects parent components when you select a child
- Deselects children when you deselect a parent

### Step 4: Provide Required Information

When installing components that need configuration, you'll be prompted:

```
Configuring Linode CLI
═══════════════════════════════════════════════════════════════

[!] No Linode API token found

To configure Linode CLI, you need an API token.
Get one from: https://cloud.linode.com/profile/tokens

Enter your Linode API token (or press Enter to skip):
```

Information you provide is:
- Saved to `.secrets.yml` for future use
- Used to configure all related components
- Never asked twice in the same session

### Step 5: Automatic Installation

The script installs selected components in dependency order:

```
Installing Components
═══════════════════════════════════════════════════════════════

Installing Linode CLI
═══════════════════════════════════════════════════════════════
Installing pipx...
Installing linode-cli...
[✓] Linode CLI installed

Configuring Linode CLI
═══════════════════════════════════════════════════════════════
[✓] Linode CLI configured successfully

Adding SSH Key to Linode Profile
═══════════════════════════════════════════════════════════════
[i] Adding SSH key to Linode profile...
[✓] SSH key added to Linode profile
```

### Step 6: Complete Manual Steps

After setup completes, you'll see reminders for manual steps:

```
Setup Complete
═══════════════════════════════════════════════════════════════

Manual steps remaining:

1. Update nameservers at your domain registrar:
   ns1.linode.com, ns2.linode.com, ns3.linode.com, ns4.linode.com, ns5.linode.com

2. After GitLab initializes (~10-15 minutes):
   - Get password: ssh git-server 'sudo cat /root/gitlab_credentials.txt'
   - Login and change password at https://git.yourdomain.org
   - Update .secrets.yml with new password
```

## Setup Profiles

### Local Development Only

For just local Drupal/Moodle development:

```bash
./setup.sh --auto
```

This installs:
- Docker, DDEV, mkcert
- NWP CLI and config files

### Full Infrastructure

For complete setup including GitLab:

```bash
./setup.sh
# Select all components in the UI
```

### Check Current Status

```bash
./setup.sh --status
```

## Rollback and Uninstall

### Removing Components

Run setup again and deselect components:

```bash
./setup.sh
# Deselect unwanted components
# Script will remove them
```

### What Gets Preserved

The script tracks what was installed before NWP:
- **Pre-existing components** are never removed
- Only components installed by NWP can be uninstalled
- Original state is saved on first run

### GitLab Server Deletion

When deselecting GitLab Server, you'll be prompted:

```
[!] This will DELETE the GitLab server (Linode ID: 12345678)
[!] All data on the server will be PERMANENTLY LOST

Are you SURE you want to delete the GitLab server? [y/N]:
```

### State Files

Setup state is stored in `~/.nwp/setup_state/`:

| File | Purpose |
|------|---------|
| `original_state.json` | What was installed before NWP |
| `current_state.json` | Current installation state |
| `install.log` | Log of all setup actions |
| `*.backup.*` | Backups of removed config files |

## Configuration Reference

### cnwp.yml (Site Configuration)

```yaml
settings:
  url: yourdomain.org       # Required for GitLab
  database: mariadb
  php: 8.2

recipes:
  myrecipe:
    source: drupal/recommended-project:^10.2
    profile: standard
    webroot: web
```

### .secrets.yml (Credentials)

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

## Troubleshooting

### Docker Permission Denied

```bash
# Add user to docker group
sudo usermod -aG docker $USER
# Log out and back in
```

### Linode CLI Authentication Failed

```bash
# Reconfigure with correct token
rm ~/.config/linode-cli
./setup.sh
# Re-enter token when prompted
```

### GitLab Server Not Accessible

```bash
# Check server status
ssh git-server 'sudo gitlab-ctl status'

# View logs
ssh git-server 'sudo tail -100 /var/log/gitlab-setup.log'

# Reconfigure GitLab
ssh git-server 'sudo gitlab-ctl reconfigure'
```

### DNS Not Resolving

```bash
# Check propagation (may take up to 48 hours)
dig git.yourdomain.org +short

# Verify nameservers are updated
dig yourdomain.org NS +short
```

### Reset Setup State

```bash
# Remove state files to start fresh
rm -rf ~/.nwp/setup_state

# Run setup again
./setup.sh
```

## See Also

- [README.md](../README.md) - Main documentation
- [SSH_SETUP.md](SSH_SETUP.md) - Detailed SSH key setup
- [PRODUCTION_DEPLOYMENT.md](PRODUCTION_DEPLOYMENT.md) - Production deployment guide
- [git/README.md](../git/README.md) - GitLab deployment details
