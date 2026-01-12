# import

Import live Drupal sites from remote servers into local DDEV development environment.

## Overview

The `import` command scans remote Linode servers for Drupal sites and imports them into your local NWP development environment using DDEV. It provides both interactive TUI and non-interactive modes for bulk importing.

## Usage

```bash
pl import [options]
pl import <sitename> --server=<name> --source=<path> [options]
```

## Interactive Mode (default)

```bash
pl import                          # Select server from cnwp.yml
pl import --server=production      # Use specific server
pl import --ssh=root@example.com   # Use custom SSH connection
```

## Non-Interactive Mode

```bash
pl import site1 --server=prod --source=/var/www/site1/web
pl import --server=prod --all --yes
```

## Options

| Flag | Description |
|------|-------------|
| `--server=NAME` | Use server from cnwp.yml linode.servers |
| `--ssh=USER@HOST` | Custom SSH connection string |
| `--key=PATH` | SSH private key path (default: ~/.ssh/nwp) |
| `--source=PATH` | Remote webroot path (skip discovery) |
| `--all` | Import all discovered sites |
| `--dry-run` | Analyze only, don't import |
| `-y, --yes` | Auto-confirm all prompts |
| `--sanitize` | Enable database sanitization (default) |
| `--no-sanitize` | Disable database sanitization |
| `--stage-file-proxy` | Enable stage file proxy (default) |
| `--full-files` | Download all files instead of stage proxy |
| `-s=N, --step=N` | Resume from step N |
| `--help, -h` | Show help message |

## Examples

### Interactive TUI (recommended)
```bash
pl import
```

### Scan production server
```bash
pl import --server=production
```

### Import specific site
```bash
pl import site1 --server=prod --source=/var/www/site1/web
```

### Import all sites from server
```bash
pl import --server=prod --all --yes
```

### Dry run to see what would be imported
```bash
pl import --server=prod --dry-run
```

## Import Process

The import command performs these steps:

1. **Connect to Server**: Test SSH connection
2. **Scan for Sites**: Discover Drupal installations
3. **Select Sites**: Choose which sites to import (interactive)
4. **Configure Options**: Set sanitization, file proxy options
5. **Import Sites**: For each site:
   - Create DDEV project
   - Download database dump
   - Import database
   - Sync files (or configure stage file proxy)
   - Run database updates
   - Configure development settings

## Database Sanitization

When enabled (default), sanitization:
- Removes sensitive user data
- Resets admin password
- Clears email addresses
- Removes API keys and tokens
- Preserves test data

## Stage File Proxy

Instead of downloading all files, stage file proxy:
- Serves images/media from production on-demand
- Saves local disk space
- Speeds up import process
- Ideal for large media libraries

Use `--full-files` if you need all files locally.

## Server Configuration

Configure servers in `cnwp.yml`:

```yaml
linode:
  servers:
    production:
      ssh_host: "root@prod.example.com"
      ssh_key: "~/.ssh/production"
      description: "Production server"
```

## Prerequisites

- DDEV installed and running
- rsync and ssh installed
- SSH key configured for remote server
- Adequate local disk space

## Discovered Site Information

For each discovered site, the scanner provides:
- Site name (from directory)
- Drupal version
- Database size (MB)
- Files directory size
- Web root path
- Site configuration

## Related Commands

- [backup.sh](backup.md) - Create backups before importing
- [restore.sh](restore.md) - Restore from backups
- [sync.sh](sync.md) - Sync files between environments
- [setup-ssh.sh](setup-ssh.md) - Configure SSH keys

## See Also

- DDEV documentation: https://ddev.readthedocs.io/
- `lib/import.sh` - Import core functions
- `lib/server-scan.sh` - Server scanning functions
