# NWP Setup and Uninstall System

This document describes the enhanced setup and uninstall system for the Narrow Way Project.

## Overview

The NWP setup system now includes:
- **Configuration-driven installation** - Reads settings from `cnwp.yml` or `example.cnwp.yml`
- **System state snapshots** - Records system state before making changes
- **CLI feature installation** - Optional CLI for running NWP commands from anywhere
- **Complete uninstallation** - Ability to restore system to pre-NWP state

## Setup Process

### Running Setup

```bash
cd ~/nwp
./setup.sh
```

### What Setup Does

1. **Creates System State Snapshot** (first run only)
   - Records what tools are already installed
   - Backs up shell configuration files
   - Saves package list
   - Creates restore point at `~/.nwp/setup_state/`

2. **Checks Prerequisites**
   - Docker Engine
   - Docker Compose
   - mkcert (SSL certificates)
   - DDEV (local development)

3. **Installs Missing Components**
   - Only installs what's missing
   - Tracks what NWP installed vs. what existed

4. **Creates Configuration File**
   - On first run: copies `example.cnwp.yml` → `cnwp.yml`
   - On subsequent runs: uses existing `cnwp.yml`

5. **Sets Up CLI (if configured)**
   - Reads `cli` and `cliprompt` settings from config
   - Installs global command (e.g., `pl`)
   - Allows running NWP scripts from any directory

## Configuration Options

### CLI Settings

In `cnwp.yml` (or `example.cnwp.yml` on first run):

```yaml
settings:
  # Enable CLI feature
  cli: y

  # CLI command name (default: pl)
  cliprompt: pl
```

### CLI Options

- `cli: y` - Enable CLI installation
- `cli: n` - Disable CLI installation
- `cliprompt: <name>` - Set CLI command name (default: `pl`)

## Using the CLI

Once installed, you can use the CLI command from anywhere:

```bash
# List available recipes
pl --list

# Install a site
pl install d

# Backup a site
pl backup mysite

# Show all available commands
pl
```

### Available CLI Commands

| Command | Script | Description |
|---------|--------|-------------|
| `pl install <recipe>` | install.sh | Install a new site |
| `pl make <site>` | make.sh | Run drush make |
| `pl backup <site>` | backup.sh | Backup a site |
| `pl restore <site>` | restore.sh | Restore from backup |
| `pl copy <from> <to>` | copy.sh | Copy a site |
| `pl delete <site>` | delete.sh | Delete a site |
| `pl dev2stg <dev>` | dev2stg.sh | Copy dev to staging |
| `pl setup` | setup.sh | Run prerequisites check |
| `pl test-nwp` | test-nwp.sh | Run tests |

### CLI Aliases

Short aliases are supported:
- `pl i` = `pl install`
- `pl b` = `pl backup`
- `pl r` = `pl restore`
- `pl cp` = `pl copy`
- `pl del` = `pl delete`
- `pl d2s` = `pl dev2stg`

## System State Snapshot

### Location

```
~/.nwp/setup_state/
├── pre_setup_state.json    # System state before NWP
├── bashrc.backup            # Backup of ~/.bashrc
├── packages_before.txt      # Installed packages list
└── install.log              # Installation log
```

### State File Contents

```json
{
  "setup_date": "2025-12-28T14:30:00+00:00",
  "user": "rob",
  "hostname": "myserver",
  "had_docker": true,
  "had_docker_compose": false,
  "was_in_docker_group": false,
  "had_mkcert": false,
  "had_mkcert_ca": false,
  "had_ddev": false,
  "had_ddev_config": false,
  "had_linode_cli": false,
  "bashrc_exists": true,
  "modified_bashrc": false,
  "installed_cli": true,
  "cli_prompt": "pl"
}
```

## Uninstallation

### Running Uninstall

```bash
cd ~/nwp
./uninstall_nwp.sh
```

### What Uninstall Does

The uninstaller uses the system state snapshot to intelligently remove only what NWP installed:

1. **Checks State File**
   - If state file exists: smart uninstall (only removes NWP additions)
   - If no state file: prompts for each action

2. **Removes CLI**
   - Removes global CLI command (e.g., `/usr/local/bin/pl`)
   - Only if installed by NWP

3. **Removes DDEV**
   - Stops all DDEV projects
   - Removes DDEV binary
   - Optionally removes `~/.ddev` config

4. **Removes mkcert**
   - Uninstalls certificate authority
   - Removes mkcert binary

5. **Removes Docker Group**
   - Removes user from docker group
   - Only if NWP added them

6. **Removes Docker**
   - Stops Docker daemon
   - Removes Docker packages
   - Removes Docker repository
   - Only if Docker was installed by NWP

7. **Restores Shell Config**
   - Restores original `~/.bashrc` from backup
   - Or removes NWP-specific lines

8. **Removes Configuration**
   - Optionally removes `cnwp.yml`
   - Optionally removes `~/.nwp` directory

### Smart Uninstall Examples

#### Example 1: Docker Already Existed
```
State: had_docker = true
Action: Skip Docker removal (keep existing installation)
```

#### Example 2: NWP Installed Docker
```
State: had_docker = false
Action: Remove Docker (it was installed by NWP)
```

#### Example 3: User Already in Docker Group
```
State: was_in_docker_group = true
Action: Keep user in docker group
```

### Manual Uninstall (No State File)

If no state file exists, the uninstaller will:
- Prompt before removing each component
- Allow selective uninstallation
- Cannot differentiate between NWP-installed and pre-existing tools

### Confirmation Prompts

The uninstaller asks for confirmation before:
- Removing Docker (if installed by NWP)
- Removing user from docker group
- Removing mkcert
- Removing DDEV
- Removing ~/.ddev configuration
- Restoring ~/.bashrc
- Removing cnwp.yml
- Removing ~/.nwp directory

## First Run vs. Subsequent Runs

### First Run

1. Reads settings from `example.cnwp.yml`
2. Creates system state snapshot
3. Copies `example.cnwp.yml` → `cnwp.yml`
4. Installs prerequisites
5. Sets up CLI (if enabled in config)

### Subsequent Runs

1. Uses existing state snapshot
2. Reads settings from `cnwp.yml`
3. Re-checks prerequisites
4. Installs any missing components
5. Updates CLI if settings changed

## File Locations

| Item | Location |
|------|----------|
| Setup script | `~/nwp/setup.sh` |
| Uninstall script | `~/nwp/uninstall_nwp.sh` |
| Configuration | `~/nwp/cnwp.yml` |
| Example config | `~/nwp/example.cnwp.yml` |
| State directory | `~/.nwp/setup_state/` |
| State file | `~/.nwp/setup_state/pre_setup_state.json` |
| Install log | `~/.nwp/setup_state/install.log` |
| CLI command | `/usr/local/bin/<cliprompt>` (e.g., `/usr/local/bin/pl`) |

## Logs

All setup operations are logged to:
```
~/.nwp/setup_state/install.log
```

View the log:
```bash
less ~/.nwp/setup_state/install.log

# Or during uninstall, it will offer to show the log
```

## Troubleshooting

### State File Missing

**Problem:** Running uninstall without a state file

**Solution:**
```bash
# The uninstaller will prompt for each action
./uninstall_nwp.sh

# Or manually remove components
```

### CLI Command Not Found After Install

**Problem:** `pl: command not found`

**Solutions:**
1. Check if CLI is in PATH:
   ```bash
   which pl
   ls -la /usr/local/bin/pl
   ```

2. CLI command should be executable:
   ```bash
   sudo chmod +x /usr/local/bin/pl
   ```

3. Verify CLI setting in config:
   ```bash
   grep "cli:" cnwp.yml
   ```

### Docker Still Present After Uninstall

**Problem:** Docker remains installed

**Reason:** Docker existed before NWP setup

**Solution:** This is expected behavior. Check state file:
```bash
grep "had_docker" ~/.nwp/setup_state/pre_setup_state.json
```

If `had_docker: true`, Docker will not be removed by uninstaller.

### Cannot Remove ~/.nwp Directory

**Problem:** Permission denied or directory in use

**Solutions:**
```bash
# Stop any running processes
ddev poweroff

# Remove manually
sudo rm -rf ~/.nwp

# Or keep Linode/GitLab configs
rm -rf ~/.nwp/setup_state
```

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
# Backup your shell config
cp ~/.bashrc ~/.bashrc.pre-nwp

# Backup package list
dpkg -l > ~/packages-before-nwp.txt
```

Before running uninstall:
```bash
# Backup DDEV projects
ddev export-db --all

# Backup site files
./backup.sh mysite
```

## Advanced Usage

### Customize CLI Command Name

```yaml
settings:
  cli: y
  cliprompt: nwp  # Use 'nwp' instead of 'pl'
```

Then use:
```bash
nwp install d
nwp backup mysite
```

### Disable CLI

```yaml
settings:
  cli: n
```

### Change CLI After Installation

1. Edit `cnwp.yml`:
   ```yaml
   cliprompt: newcommand
   ```

2. Remove old CLI:
   ```bash
   sudo rm /usr/local/bin/pl
   ```

3. Run setup again:
   ```bash
   ./setup.sh
   ```

### View State Without Uninstalling

```bash
cat ~/.nwp/setup_state/pre_setup_state.json
```

### Partial Uninstall

Run uninstaller and selectively choose what to remove:
```bash
./uninstall_nwp.sh

# Answer 'n' to keep specific components
```

## Integration with NWP Workflow

### Recommended Setup Flow

```bash
# 1. Clone NWP repository
git clone <repo> ~/nwp
cd ~/nwp

# 2. Run setup (reads example.cnwp.yml on first run)
./setup.sh

# 3. Customize your configuration
nano cnwp.yml

# 4. Use NWP (with or without CLI)
./install.sh d
# or
pl install d
```

### Before Deployment

Setup automatically creates a state snapshot, so you can always roll back:

```bash
# Install and configure NWP
./setup.sh

# ... use NWP for development ...

# If needed, completely uninstall
./uninstall_nwp.sh
```

## See Also

- [Main README](../README.md) - General NWP documentation
- [Installation Guide](../README.md#installation) - Basic installation
- [URL Setup](../url/README.md) - URL and GitLab configuration
- [Linode Deployment](LINODE_DEPLOYMENT.md) - Production deployment
