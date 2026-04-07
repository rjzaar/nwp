# NWP Setup Guide

This guide provides step-by-step instructions to set up and manage the Narrow Way Project (NWP).

## Table of Contents

- [Quick Start](#quick-start)
- [What Gets Installed](#what-gets-installed)
- [Prerequisites](#prerequisites)
- [Setup Process](#setup-process)
- [Configuration](#configuration)
- [CLI Installation](#cli-installation)
- [Uninstallation](#uninstallation)
- [Troubleshooting](#troubleshooting)

## Quick Start

```bash
# Clone repository
git clone git@github.com:rjzaar/nwp.git ~/nwp
cd ~/nwp

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

## What Gets Installed

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
| NWP CLI | Global `pl` command for running scripts (recommended) |
| NWP Config | Creates `nwp.yml` from example |
| NWP Secrets | Creates `.secrets.yml` template |
| Script Symlinks | Optional: Create `./install.sh` symlinks for backward compatibility |

### Linode Infrastructure (Server Provisioning)

| Component | What It Does |
|-----------|--------------|
| Linode CLI | Command-line tool for Linode API |
| Linode Config | Configures CLI with your API token |
| SSH Keys | Generates deployment SSH keys |

### GitLab Deployment (Self-Hosted Git)

| Component | What It Does |
|-----------|--------------|
| GitLab SSH Keys | Generates keys for GitLab access |
| GitLab Server | Provisions 4GB Linode server with GitLab CE |
| GitLab DNS | Creates DNS records in Linode |
| GitLab SSH Config | Configures `ssh git-server` alias |

## Prerequisites

### Before Running Setup

1. **Get a Linode API Token** (if using Linode/GitLab)
   - Go to https://cloud.linode.com/profile/tokens
   - Create token with Read/Write for: Linodes, StackScripts, Domains
   - Save the token - you'll enter it during setup

2. **Set Your Domain** (if deploying GitLab)
   - Edit `nwp.yml` after it's created
   - Add your domain under settings:
     ```yaml
     settings:
       url: yourdomain.org
     ```

### After Running Setup

1. **Update Domain Nameservers** (if using Linode DNS)
   - Go to your domain registrar
   - Change nameservers to:
     - ns1.linode.com
     - ns2.linode.com
     - ns3.linode.com
     - ns4.linode.com
     - ns5.linode.com

2. **Change GitLab Root Password** (if GitLab installed)
   - Wait 10-15 minutes for GitLab to initialize
   - Get initial password: `ssh git-server 'sudo cat /root/gitlab_credentials.txt'`
   - Login at https://git.yourdomain.org
   - Change password immediately
   - Update `.secrets.yml` with new password

## Setup Process

### Step 1: Clone and Run Setup

```bash
git clone git@github.com:rjzaar/nwp.git ~/nwp
cd ~/nwp
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
[✗] NWP Configuration (nwp.yml)
[✗] NWP Secrets (.secrets.yml)
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
```

## Configuration

### nwp.yml (Site Configuration)

```yaml
settings:
  url: yourdomain.org       # Required for GitLab
  database: mariadb
  php: 8.2
  cli: y                    # Enable CLI feature
  cliprompt: pl             # CLI command name

recipes:
  myrecipe:
    source: drupal/recommended-project:^10.2
    profile: standard
    webroot: web
```

### Two-Tier Secrets Architecture

NWP uses a two-tier secrets system for AI assistant safety:

| File | Contains | AI Access |
|------|----------|-----------|
| `.secrets.yml` | Infrastructure (API tokens) | Allowed |
| `.secrets.data.yml` | Production data (DB, SSH) | Blocked |

### .secrets.yml (Infrastructure Secrets)

```yaml
# Infrastructure secrets - safe for AI assistants
linode:
  api_token: "your-token-here"

cloudflare:
  api_token: "your-token-here"
  zone_id: "your-zone-id"

gitlab:
  server:
    domain: git.yourdomain.org
    ip: 1.2.3.4
    linode_id: 12345678
  api_token: "gitlab-api-token"
```

### .secrets.data.yml (Data Secrets - AI Blocked)

```yaml
# Data secrets - NEVER share with AI assistants
production_ssh:
  key_path: "keys/prod_deploy"
  user: "deploy"
  host: "prod.example.com"

production_database:
  host: "db.example.com"
  password: "production-password"

gitlab_admin:
  password: "gitlab-root-password"
```

### Migrating Existing Secrets

If you have an existing `.secrets.yml` with mixed secrets:

```bash
# Check for data secrets in wrong files
./migrate-secrets.sh --check

# Migrate to two-tier architecture
./migrate-secrets.sh --nwp
```

See [DATA_SECURITY_BEST_PRACTICES.md](DATA_SECURITY_BEST_PRACTICES.md) for full documentation.

## CLI Installation

### Enabling the CLI

In `nwp.yml`:

```yaml
settings:
  cli: y
  cliprompt: pl  # Command name (default: pl)
```

### CLI Registration System

NWP uses a symlink-based CLI registration system that:
- Creates commands in `/usr/local/bin/` for global access
- Automatically detects conflicts with existing commands
- Supports multiple NWP installations with unique names

During `./setup.sh`, the TUI shows the "NWP CLI Command" row where you can:
- Press **Enter** to accept the suggested command name
- Press **e** to edit and choose a custom name
- The system suggests `pl`, then `pl1`, `pl2`, etc. if conflicts exist

### Multiple NWP Installations

If you have multiple NWP installations (e.g., different projects), each gets a unique CLI command:

| Installation | Command |
|--------------|---------|
| First (default) | `pl` |
| Second | `pl1` |
| Third | `pl2` |
| Custom | Any name you choose |

**Checking which installation a command points to:**
```bash
readlink /usr/local/bin/pl
# Output: /home/user/nwp/pl
```

**Changing the command name:**
1. Run `./setup.sh` from the NWP installation
2. Navigate to "NWP CLI Command"
3. Press 'e' to edit and enter a new name

### Using the CLI

Once installed, use the CLI from anywhere:

```bash
# List available recipes
pl --list

# Install a site
pl install d

# Backup a site
pl backup mysite

# Frontend theming
pl theme watch mysite

# Show all available commands
pl
```

### Available CLI Commands

| Command | Script | Description |
|---------|--------|-------------|
| `pl install <recipe>` | install.sh | Install a new site |
| `pl backup <site>` | backup.sh | Backup a site |
| `pl restore <site>` | restore.sh | Restore from backup |
| `pl copy <from> <to>` | copy.sh | Copy a site |
| `pl delete <site>` | delete.sh | Delete a site |
| `pl dev2stg <dev>` | dev2stg.sh | Copy dev to staging |
| `pl status` | status.sh | Show site status |
| `pl theme <cmd> <site>` | theme.sh | Frontend build tooling |
| `pl setup` | setup.sh | Run prerequisites check |
| `pl verify --run` | verify.sh | Run verification system |

### CLI Aliases

Short aliases are supported:
- `pl i` = `pl install`
- `pl b` = `pl backup`
- `pl r` = `pl restore`
- `pl cp` = `pl copy`
- `pl del` = `pl delete`

## Uninstallation

### Running Uninstall

```bash
cd ~/nwp
./uninstall_nwp.sh
```

### Smart Uninstall

The uninstaller uses the system state snapshot to intelligently remove only what NWP installed:

| What Was There | What Happens |
|----------------|--------------|
| Docker existed before NWP | Docker is kept |
| NWP installed Docker | Docker is removed |
| User was in docker group | User stays in group |
| NWP added user to docker group | User is removed from group |

### What Uninstall Does

1. **Checks State File** - Uses snapshot to know what NWP installed
2. **Removes CLI** - Removes global CLI command (e.g., `/usr/local/bin/pl`)
3. **Removes DDEV** - Stops projects, removes binary and config
4. **Removes mkcert** - Uninstalls CA and binary
5. **Removes Docker Group** - If NWP added user
6. **Removes Docker** - If NWP installed it
7. **Restores Shell Config** - Original `~/.bashrc` from backup
8. **Removes Configuration** - Optionally removes `nwp.yml` and `~/.nwp`

### Confirmation Prompts

The uninstaller asks for confirmation before:
- Removing Docker (if installed by NWP)
- Removing user from docker group
- Removing mkcert
- Removing DDEV
- Removing ~/.ddev configuration
- Restoring ~/.bashrc
- Removing nwp.yml
- Removing ~/.nwp directory

### Manual Uninstall (No State File)

If no state file exists, the uninstaller will:
- Prompt before removing each component
- Allow selective uninstallation
- Cannot differentiate between NWP-installed and pre-existing tools

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

### CLI Command Not Found

```bash
# Check if CLI is in PATH
which pl
ls -la /usr/local/bin/pl

# Make executable
sudo chmod +x /usr/local/bin/pl

# Verify CLI setting in config
grep "cli:" nwp.yml
```

### Reset Setup State

```bash
# Remove state files to start fresh
rm -rf ~/.nwp/setup_state

# Run setup again
./setup.sh
```

### State File Location

Setup state is stored in `~/.nwp/setup_state/`:

| File | Purpose |
|------|---------|
| `original_state.json` | What was installed before NWP |
| `current_state.json` | Current installation state |
| `install.log` | Log of all setup actions |
| `bashrc.backup` | Backup of ~/.bashrc |

### Check Current State

```bash
# View state file
cat ~/.nwp/setup_state/pre_setup_state.json

# Check setup status
./setup.sh --status
```

## Setup Profiles

### Local Development Only

For just local Drupal/Moodle development:

```bash
./setup.sh --auto
```

This installs:
- Docker, DDEV, mkcert
- NWP CLI (`pl` command) and config files

### Full Infrastructure

For complete setup including GitLab:

```bash
./setup.sh
# Select all components in the UI
```

### Script Organization

Scripts are located in `scripts/commands/` and accessed via the `pl` CLI:

```bash
# Default: use the pl CLI (works from anywhere)
pl install nwp
pl backup mysite
pl status

# Alternative: direct path
./scripts/commands/install.sh nwp
```

Sites are installed to `~/nwp/sites/<sitename>/` directory.

**Optional symlinks for backward compatibility:**

```bash
./setup.sh --symlinks      # Create ./install.sh etc. in root
./setup.sh --no-symlinks   # Remove symlinks
```

The interactive setup UI includes "Script Symlinks" as an optional component.

## File Locations

| Item | Location |
|------|----------|
| Setup script | `~/nwp/setup.sh` |
| Uninstall script | `~/nwp/uninstall_nwp.sh` |
| Configuration | `~/nwp/nwp.yml` |
| Example config | `~/nwp/example.nwp.yml` |
| State directory | `~/.nwp/setup_state/` |
| Install log | `~/.nwp/setup_state/install.log` |
| CLI command | `/usr/local/bin/<cliprompt>` |

## Security Considerations

### Sudo Access

Both scripts require sudo for:
- Installing packages (Docker, mkcert, DDEV)
- Installing CLI to `/usr/local/bin/`
- Removing packages and system files

### State File Security

The state file contains:
- Username and hostname
- Installation dates
- Which tools were installed

It does NOT contain:
- Passwords or API tokens
- SSH keys
- Personal data

### Backup Recommendations

Before running setup:
```bash
cp ~/.bashrc ~/.bashrc.pre-nwp
dpkg -l > ~/packages-before-nwp.txt
```

Before running uninstall:
```bash
ddev export-db --all
./backup.sh mysite
```

## See Also

- [Testing Guide](../testing/testing.md) - Test suite documentation
- [CI/CD Guide](../deployment/cicd.md) - CI/CD implementation
- [Production Deployment](../deployment/production-deployment.md) - Deployment guide
- [SSH Setup](../deployment/ssh-setup.md) - SSH key setup
- [GitLab Setup](../../linode/gitlab/README.md) - GitLab server setup
