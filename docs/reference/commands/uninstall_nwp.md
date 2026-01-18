# uninstall_nwp

**Last Updated:** 2026-01-14

Reverse all changes made by NWP setup, restoring the system to its pre-NWP state based on installation snapshot.

## Synopsis

```bash
pl uninstall_nwp
```

## Description

Intelligently removes NWP and related tools from the system, using installation state snapshots to determine what should be removed versus what existed before NWP setup.

This command:
- Reads installation state captured during `setup.sh`
- Skips removing tools that existed before NWP
- Removes only what NWP installed
- Restores modified configuration files
- Preserves user data when requested
- Provides detailed confirmation prompts

The uninstaller is designed to be safe and conservative, always confirming destructive actions and preserving pre-existing configurations.

## Arguments

No arguments required. All operations are interactive with confirmation prompts.

## Options

All operations are controlled via interactive prompts. There are no command-line flags.

## Examples

### Standard Uninstall

```bash
pl uninstall_nwp
```

Runs the interactive uninstaller with prompts for each component.

### Non-Interactive Alternative

Not supported. The uninstaller requires confirmation for safety. To script uninstall:
1. Manually remove components in order
2. Use component-specific uninstallers (e.g., `ddev poweroff`)

## Uninstall Process

The script performs these steps in reverse dependency order:

### Step 1: Verification

**What it checks:**
- Installation state file exists (`~/.nwp/setup_state/original_state.json`)
- State file format (new or legacy)
- Installation date from state

**Output:**
```
✓ Found installation state from: 2024-12-15 14:23:45
ℹ State file: /home/john/.nwp/setup_state/original_state.json

ℹ The uninstaller will:
  - Skip removing tools that existed before NWP setup
  - Remove only what NWP installed
  - Restore modified configuration files
```

**If state missing:**
```
⚠ No installation state file found

ℹ Without a state file, the uninstaller cannot determine what was
ℹ installed by NWP vs. what was already on your system.

Continue with uninstall anyway (will prompt for each action)? [y/N]:
```

### Step 2: Remove SSH Keys

**What it removes:**
- `<project-root>/keys/nwp` and `nwp.pub`
- `~/.ssh/nwp` and `nwp.pub`

**Prompt:**
```
Remove NWP SSH keys? [y/N]:
```

**Default:** No (preserves keys for potential reuse)

### Step 3: Remove CLI Command

**What it removes:**
- Symlink in `/usr/local/bin/<cli-command>` (e.g., `/usr/local/bin/pl`)
- Uses CLI registration library if available
- Falls back to manual removal based on `nwp.yml` config

**Prompt:**
```
Remove NWP CLI command? [y/N]:
```

**Default:** Yes

### Step 4: Remove Linode CLI

**What it removes:**
- `linode-cli` installed via pipx

**State check:**
- If Linode CLI existed before NWP: Skips removal
- If NWP installed it: Prompts for removal

**Prompt:**
```
Remove Linode CLI? [y/N]:
```

**Default:** Yes (if NWP installed it)

### Step 5: Remove DDEV

**What it removes:**
- DDEV binary (`/usr/local/bin/ddev` or `/usr/bin/ddev`)
- Optionally: DDEV global configuration (`~/.ddev/`)

**State check:**
- If DDEV existed before NWP: Skips removal
- If NWP installed it: Prompts for removal

**Prompts:**
```
Remove DDEV? [y/N]:
Remove DDEV global configuration (~/.ddev)? [y/N]:
```

**Actions:**
1. Stops all DDEV projects: `ddev poweroff`
2. Removes DDEV binary
3. Optionally removes `~/.ddev/` directory

**Default:** Yes for binary, No for config

### Step 6: Remove mkcert

**What it removes:**
- mkcert binary (`/usr/local/bin/mkcert`)
- mkcert CA (certificate authority)

**State check:**
- If mkcert existed before NWP: Skips removal
- If NWP installed it: Prompts for removal

**Actions:**
1. Uninstalls CA: `mkcert -uninstall`
2. Removes binary

**Prompt:**
```
Remove mkcert and its certificate authority? [y/N]:
```

**Default:** Yes (if NWP installed it)

### Step 7: Remove from Docker Group

**What it removes:**
- Current user from `docker` group

**State check:**
- If user was in docker group before NWP: Skips removal
- If NWP added user: Prompts for removal

**Prompt:**
```
Remove john from docker group? [y/N]:
```

**Warning:** Requires logout/login to take effect

**Default:** Yes (if NWP added user)

### Step 8: Remove Docker

**What it removes:**
- Docker Engine packages
- Docker repository configuration
- Docker APT keyring

**State check:**
- If Docker existed before NWP: Skips removal
- If NWP installed it: Prompts for removal

**Actions:**
1. Stops Docker service: `systemctl stop docker`
2. Disables Docker service: `systemctl disable docker`
3. Removes packages: `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-compose-plugin`
4. Removes repository: `/etc/apt/sources.list.d/docker.list`
5. Removes keyring: `/etc/apt/keyrings/docker-archive-keyring.gpg`
6. Runs autoremove

**Prompt:**
```
Remove Docker Engine and related packages? [y/N]:
```

**Default:** Yes (if NWP installed it)

### Step 9: Restore Shell Configuration

**What it restores:**
- `~/.bashrc` from backup (if available)
- Or removes NWP-added lines

**State check:**
- If `.bashrc` was modified by NWP: Offers restore
- If backup exists: Offers to restore from backup
- If no backup: Offers to remove NWP lines

**Prompts:**
```
Restore original ~/.bashrc? [y/N]:
# Or if no backup:
Remove NWP-related lines from ~/.bashrc? [y/N]:
```

**Lines removed (if no backup):**
- `# Add local bin to PATH for pipx and other local tools`
- `export PATH="$HOME/.local/bin:$PATH"`
- `# NWP CLI`
- `alias pl=...`

**Default:** Yes

### Step 10: Remove Configuration Files

**What it removes:**
- `nwp.yml` (NWP configuration)
- `~/.nwp/` directory (setup state, configs, SSH keys)
- Or just setup state files (preserves other configs)

**Prompts:**
```
Remove nwp.yml configuration file? [y/N]:
Remove entire ~/.nwp directory? [y/N]:
# Or if keeping ~/.nwp:
Remove only setup state files? [y/N]:
```

**What's in `~/.nwp/`:**
- Setup state snapshots
- Linode/GitLab configurations
- SSH keys (if not in project)
- Backup files

**Default:** No for `nwp.yml`, No for `~/.nwp/`, Yes for state files only

## Output

### Successful Uninstall

```
================================================================================
NWP Uninstaller
================================================================================

⚠ WARNING: This will remove NWP and potentially Docker, DDEV, and other tools.
⚠ Make sure you have backups of any important data!

✓ Found installation state from: 2024-12-15 14:23:45
ℹ State file: /home/john/.nwp/setup_state/original_state.json

ℹ The uninstaller will:
  - Skip removing tools that existed before NWP setup
  - Remove only what NWP installed
  - Restore modified configuration files

Proceed with uninstall? [y/N]: y

[1/10] Removing SSH Keys
  Remove NWP SSH keys? [y/N]: n
  ℹ Keeping SSH keys

[2/10] Removing CLI Command
  Remove CLI command 'pl'? [y/N]: y
  ✓ CLI command removed

[3/10] Removing Linode CLI
  ℹ Linode CLI was already installed before NWP setup
  ℹ Skipping Linode CLI removal (keeping existing installation)

[4/10] Removing DDEV
  Remove DDEV? [y/N]: y
  ℹ Stopping all DDEV projects...
  ℹ Removing DDEV...
  ✓ DDEV removed

  Remove DDEV global configuration (~/.ddev)? [y/N]: n
  ℹ Keeping DDEV global configuration

[5/10] Removing mkcert
  Remove mkcert and its certificate authority? [y/N]: y
  ℹ Uninstalling mkcert CA...
  ℹ Removing mkcert binary...
  ✓ mkcert removed

[6/10] Removing User from Docker Group
  Remove john from docker group? [y/N]: y
  ✓ User removed from docker group
  ⚠ You need to log out and log back in for this to take effect

[7/10] Removing Docker
  ℹ Docker was already installed before NWP setup
  ℹ Skipping Docker removal (keeping existing installation)

[8/10] Restoring Shell Configuration
  Restore original ~/.bashrc? [y/N]: y
  ✓ ~/.bashrc restored from backup

[9/10] Removing NWP Configuration Files
  Remove nwp.yml configuration file? [y/N]: n
  ℹ Keeping nwp.yml

  ℹ NWP configuration directory: /home/john/.nwp
  ℹ This contains:
    - Setup state snapshots
    - Linode/GitLab configurations
    - SSH keys

  Remove entire ~/.nwp directory? [y/N]: n
  ℹ Keeping ~/.nwp directory

  Remove only setup state files? [y/N]: y
  ✓ Setup state files removed

================================================================================
Uninstall Complete
================================================================================

NWP has been uninstalled from your system.

What was removed/restored:
  - Docker (if installed by NWP)
  - DDEV (if installed by NWP)
  - mkcert (if installed by NWP)
  - Shell configuration changes
  - CLI commands

What you may need to do manually:
  - Log out and log back in (if docker group was modified)
  - Source ~/.bashrc or restart terminal
  - Review ~/.nwp directory if not removed
```

### Uninstall Without State File

```
================================================================================
NWP Uninstaller
================================================================================

⚠ WARNING: This will remove NWP and potentially Docker, DDEV, and other tools.
⚠ Make sure you have backups of any important data!

⚠ No installation state file found
ℹ Checked locations:
  - /home/john/.nwp/setup_state/original_state.json (new format)
  - /home/john/.nwp/setup_state/pre_setup_state.json (legacy format)

ℹ Without a state file, the uninstaller cannot determine what was
ℹ installed by NWP vs. what was already on your system.

Continue with uninstall anyway (will prompt for each action)? [y/N]: y

[1/10] Removing SSH Keys
  Remove NWP SSH keys? [y/N]: y
  ✓ SSH keys removed

[2/10] Removing CLI Command
  Remove CLI command 'pl'? [y/N]: y
  ✓ CLI command removed

[3/10] Removing Linode CLI
  Remove Linode CLI? [y/N]: n
  ℹ Keeping Linode CLI

[4/10] Removing DDEV
  Remove DDEV? [y/N]: n
  ℹ Keeping DDEV

[5/10] Removing mkcert
  Remove mkcert and its certificate authority? [y/N]: n
  ℹ Keeping mkcert

[6/10] Removing User from Docker Group
  Remove john from docker group? [y/N]: n
  ℹ User not in docker group

[7/10] Removing Docker
  Remove Docker Engine and related packages? [y/N]: n
  ℹ Keeping Docker installed

[... continues ...]
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Uninstall completed (user may have kept some components) |
| 0 | User cancelled uninstall |

The script always returns 0 because interactive cancellation is not an error.

## Prerequisites

### Required
- Bash shell
- `sudo` access (for removing system packages and `/usr/local/bin` files)

### Optional
- Installation state file (for intelligent removal)
- Component-specific tools (docker, ddev, etc.) for proper removal

## State File Formats

### New Format (Recommended)

Location: `~/.nwp/setup_state/original_state.json`

```json
{
  "saved_date": "2024-12-15T14:23:45Z",
  "components": {
    "docker": 0,
    "docker_compose": 0,
    "docker_group": 0,
    "mkcert": 0,
    "mkcert_ca": 0,
    "ddev": 0,
    "ddev_config": 0,
    "linode_cli": 1,
    "nwp_cli": 0
  },
  "shell": {
    "bashrc_modified": 1,
    "bashrc_backup": "~/.nwp/setup_state/bashrc.backup"
  }
}
```

**Component values:**
- `0` = Not installed (NWP installed it)
- `1` = Already installed (skip removal)

### Legacy Format

Location: `~/.nwp/setup_state/pre_setup_state.json`

```json
{
  "setup_date": "2024-12-15 14:23:45",
  "had_docker": "false",
  "had_docker_compose": "false",
  "was_in_docker_group": "false",
  "had_mkcert": "false",
  "had_mkcert_ca": "false",
  "had_ddev": "false",
  "had_ddev_config": "false",
  "had_linode_cli": "true",
  "modified_bashrc": "true"
}
```

The uninstaller supports both formats automatically.

## Safety Features

### State-Based Removal
Only removes components that NWP installed, preserving pre-existing installations.

### Confirmation Prompts
Every removal requires explicit confirmation.

### Backup Before Overwrite
Creates timestamped backups before modifying configuration files.

### Conservative Defaults
Defaults to "No" for potentially destructive operations (removing configs, SSH keys, etc.)

### Graceful Degradation
If state file is missing, still allows uninstall with per-component prompts.

### Service Shutdown
Stops services (Docker, DDEV) before removal to prevent issues.

## Manual Cleanup

If the uninstaller doesn't remove everything you want:

### Remove Docker Volumes

```bash
# List volumes
docker volume ls

# Remove all volumes (WARNING: deletes data)
docker volume prune -a
```

### Remove Docker Images

```bash
# List images
docker images

# Remove all images
docker rmi $(docker images -q)
```

### Remove APT Cache

```bash
sudo apt-get clean
sudo apt-get autoremove
```

### Remove User Data

```bash
# Remove NWP sites
rm -rf ~/nwp/sites/

# Remove Docker data
sudo rm -rf /var/lib/docker/
```

## Troubleshooting

### Permission Denied Removing Files

**Symptom:**
```
rm: cannot remove '/usr/local/bin/pl': Permission denied
```

**Solution:**
```bash
sudo ./scripts/commands/uninstall_nwp.sh
```

### Docker Service Won't Stop

**Symptom:**
```
Failed to stop docker service
```

**Solution:**
1. Stop containers manually: `docker stop $(docker ps -aq)`
2. Kill Docker daemon: `sudo killall dockerd`
3. Try uninstall again

### DDEV Projects Won't Stop

**Symptom:**
```
Failed to poweroff DDEV projects
```

**Solution:**
1. Stop each project: `cd <site> && ddev stop`
2. Force poweroff: `ddev poweroff --force`
3. Remove containers: `docker rm -f $(docker ps -aq -f name=ddev)`

### State File Corrupted

**Symptom:**
```
Error reading state file
```

**Solution:**
1. Continue without state file (prompts for each component)
2. Or restore state from backup: `~/.nwp/setup_state/*.backup`

### Can't Remove Docker Group

**Symptom:**
```
gpasswd: user 'john' is not a member of 'docker'
```

**Solution:** This is harmless. User may have been manually removed from group already. Continue.

## Reinstallation

After uninstalling, to reinstall NWP:

```bash
# Re-run setup
./setup.sh

# Or if you kept the project directory
cd ~/nwp
./setup.sh
```

The reinstallation will create a new state snapshot.

## Related Commands

- `./setup.sh` - Initial NWP installation
- CLI unregistration library: `/home/rob/nwp/lib/cli-register.sh`

## See Also

- [Setup Documentation](../../guides/getting-started.md)
- [Installation State Format](../../proposals/installation-state-snapshot.md)
- [CLI Registration System](../../decisions/cli-registration.md)
