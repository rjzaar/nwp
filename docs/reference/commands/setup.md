# setup

**Last Updated:** 2026-01-14

Interactive TUI for managing NWP prerequisites and component installation.

## Synopsis

```bash
pl setup [options]
```

## Description

The `setup` command provides an interactive terminal user interface (TUI) for managing NWP infrastructure components. It detects currently installed components, allows you to select what to install or remove, and handles dependency resolution automatically.

Components are organized into categories (Core Infrastructure, NWP Tools, Testing, Security, Linode Infrastructure, GitLab Deployment) with priority levels (required, recommended, optional).

The TUI uses arrow keys for navigation and space to toggle selections, making it easy to customize your NWP installation.

## Arguments

None. The command operates entirely through the interactive TUI.

## Options

| Option | Description | Default |
|--------|-------------|---------|
| `--status` | Show current installation status without TUI | - |
| `--auto` | Auto-install all required + recommended components | - |
| `--help` | Show help message | - |

## Components

### Core Infrastructure

| Component | Priority | Description |
|-----------|----------|-------------|
| Docker Engine | Required | Container runtime for DDEV |
| Docker Compose Plugin | Required | Multi-container orchestration |
| Docker Group Membership | Required | Run Docker without sudo |
| PHP CLI | Required | PHP command-line interpreter |
| Composer | Required | PHP dependency manager |
| DDEV | Required | Local development environment |
| DDEV Global Config | Required | Default DDEV settings |
| mkcert | Recommended | Local SSL certificates |
| mkcert CA | Recommended | Root CA for trusted certificates |

### NWP Tools

| Component | Priority | Description |
|-----------|----------|-------------|
| yq | Required | YAML processor for config parsing |
| NWP Configuration | Required | Main nwp.yml config file |
| NWP CLI Command | Recommended | Global `pl` command |
| NWP Secrets | Recommended | Infrastructure secrets file |
| Script Symlinks | Optional | Backward compatibility symlinks |

### Testing Tools

| Component | Priority | Description |
|-----------|----------|-------------|
| BATS | Optional | Bash testing framework |

### Security

| Component | Priority | Description |
|-----------|----------|-------------|
| Claude Code Security Config | Recommended | Restricts AI access to production data |

### Linode Infrastructure

| Component | Priority | Description |
|-----------|----------|-------------|
| Linode CLI | Optional | Manage Linode cloud servers |
| Linode CLI Configuration | Optional | API token and defaults |
| SSH Keys | Optional | SSH keypair for deployments |

### GitLab Infrastructure

| Component | Priority | Description |
|-----------|----------|-------------|
| GitLab SSH Keys | Optional | SSH keys for GitLab provisioning |
| GitLab Server | Optional | Self-hosted GitLab instance |
| GitLab DNS | Optional | DNS record for GitLab |
| GitLab SSH Config | Optional | SSH config entry |
| GitLab Composer Registry | Optional | Private Composer packages |

## TUI Controls

| Key | Action |
|-----|--------|
| `↑` / `↓` | Navigate between components |
| `←` / `→` | Switch between pages |
| `SPACE` | Toggle component selection |
| `a` | Select all required + recommended |
| `n` | Reset to current installation state |
| `d` | Show detailed description |
| `e` | Edit editable values (CLI name, tokens) |
| `ENTER` | Apply changes |
| `q` | Quit without changes |

## Examples

### Interactive Installation

```bash
pl setup
```

Launches the TUI where you can:
1. Navigate with arrow keys
2. Toggle components with SPACE
3. Press ENTER to apply changes

### Check Status

```bash
pl setup --status
```

Shows which components are installed without launching the TUI.

### Auto-Install Recommended

```bash
pl setup --auto
```

Automatically installs all required and recommended components without prompting.

## Output

### Status Display

```
NWP Setup Status

Core Infrastructure
  [✓] ● Docker Engine
  [✓] ● PHP CLI
  [ ] ● Composer

NWP Tools
  [✓] ● yq YAML Processor
  [ ] ● NWP CLI Command
```

Legend:
- `[✓]` - Installed
- `[ ]` - Not installed
- `●` Red - Required
- `●` Yellow - Recommended
- `●` Cyan - Optional

### Interactive Screen

```
NWP Setup Manager  |  ←→:Page ↑↓:Nav SPACE:Toggle d:Desc e:Edit a:All n:None ENTER:Apply q:Quit
═══════════════════════════════════════════════════════════════════════════════

  [Core & Tools]  Infrastructure

  ● Required  ● Recommended  ● Optional    [✓] Installed  [ ] Not Installed
───────────────────────────────────────────────────────────────────────────────

  Core Infrastructure
    [✓] ● Docker Engine
    [✓] ● Docker Compose Plugin
    [✓] ● PHP CLI
>   [ ] ● Composer

───────────────────────────────────────────────────────────────────────────────
  12 selected  |  8/25 installed
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | General error (installation failed, component unavailable) |

## Prerequisites

- Ubuntu/Debian-based Linux distribution
- sudo privileges for system-level installations
- Internet connectivity for downloading components
- At least 2GB free disk space for core components

## Editable Components

Some components allow inline editing of values:

| Component | Editable Value | Purpose |
|-----------|----------------|---------|
| NWP CLI Command | Command name | Customize CLI command (pl, pl1, pl2, etc.) |
| Linode Configuration | API token | Set Linode API token for cloud operations |

Press `e` when highlighting these components to edit their values.

## State Management

The setup script maintains state in `~/.nwp/setup_state/`:

- `original_state.json` - Installation state when first run
- `current_state.json` - Current installation state
- `install.log` - Installation activity log

## Installation Methods

Different components use different installation methods:

| Method | Components | Notes |
|--------|-----------|-------|
| APT | Docker, PHP, BATS | System package manager |
| snap | yq | Cleanest on Ubuntu |
| Direct download | Composer, mkcert, DDEV | Official installers |
| pipx | Linode CLI | Isolated Python environment |
| File creation | NWP Config, Secrets | Config file setup |
| Symlinks | NWP CLI, Script Symlinks | Convenience aliases |

## Dependency Resolution

The setup script automatically resolves dependencies:

- Installing a child component automatically selects its parent
- Deselecting a parent automatically deselects its children
- Example: Selecting "Docker Compose Plugin" automatically selects "Docker Engine"

## Post-Installation Steps

Some components require manual steps after installation:

### Docker Group Membership

```
User added to docker group
⚠ Log out and back in to take effect
```

You must log out and back in before Docker commands work without sudo.

### Linode CLI Configuration

After installing Linode CLI, configure with:

```bash
pl setup
# Navigate to Linode CLI Configuration
# Press 'e' to edit API token
# Or manually edit ~/.config/linode-cli
```

### SSH Keys

After generating SSH keys:

1. Add public key to Linode Cloud Manager
2. Visit: https://cloud.linode.com/profile/keys
3. Paste contents of `keys/nwp.pub`

See [setup-ssh.md](./setup-ssh.md) for details.

## Notes

- **Docker requires logout**: After adding user to docker group, log out and back in
- **DDEV requires Docker**: DDEV installation will fail if Docker isn't running
- **mkcert CA trust**: The mkcert CA is trusted system-wide for local HTTPS
- **yq version**: Installs yq v4.x (YAML processor, not YQ the music app)
- **Component detection**: Automatically detects already-installed components
- **Safe to re-run**: Running setup multiple times is safe - it detects existing components

## Troubleshooting

### Docker Installation Fails

**Symptom:** Docker installation returns errors

**Solution:**
1. Remove conflicting packages: `sudo apt remove docker docker-engine docker.io`
2. Update package lists: `sudo apt update`
3. Re-run: `pl setup --auto`

### Cannot Run Docker Commands

**Symptom:** `permission denied while trying to connect to the Docker daemon socket`

**Solution:**
1. Verify group membership: `groups | grep docker`
2. If not in docker group, re-run setup
3. **Log out and back in** (required for group changes)
4. Test: `docker ps`

### DDEV Installation Fails

**Symptom:** DDEV install script fails

**Solution:**
1. Ensure Docker is running: `sudo systemctl status docker`
2. Check internet connectivity
3. Manually install: `curl -fsSL https://ddev.com/install.sh | bash`

### yq Command Not Found After Installation

**Symptom:** `yq: command not found` after snap installation

**Solution:**
1. Add snap to PATH: `export PATH="/snap/bin:$PATH"`
2. Add to shell profile: `echo 'export PATH="/snap/bin:$PATH"' >> ~/.bashrc`
3. Re-login or source: `source ~/.bashrc`

### Setup Shows Wrong State

**Symptom:** Components show as not installed when they are

**Solution:**
1. Delete state files: `rm -rf ~/.nwp/setup_state/`
2. Re-run: `pl setup`
3. State will be re-detected

### Linode CLI Installation Fails

**Symptom:** pipx or linode-cli installation fails

**Solution:**
1. Install pipx manually: `sudo apt install pipx`
2. Ensure path: `pipx ensurepath`
3. Restart shell
4. Re-run setup

## Related Commands

- [setup-ssh.md](./setup-ssh.md) - Generate SSH keys for deployment
- [install.sh](../scripts/install.sh) - Install new Drupal sites

## See Also

- [Getting Started Guide](../../guides/getting-started.md) - Initial NWP setup walkthrough
- [DDEV Documentation](https://ddev.readthedocs.io/) - DDEV usage and configuration
- [Linode Setup Guide](../../deployment/linode-setup.md) - Linode cloud deployment
