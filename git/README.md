# GitLab Deployment on Linode

Automated provisioning and deployment scripts for GitLab CE (Community Edition) with GitLab Runner on Linode servers.

## Overview

This folder contains scripts to provision and manage GitLab servers on Linode infrastructure. It's designed to make it easy to deploy production-ready GitLab instances with security best practices, automated backups, and zero-downtime upgrades.

## Features

- **Automated Server Provisioning**: Create GitLab servers in 10-15 minutes
- **Security Hardened**: SSH key-only authentication, firewall configured, root login disabled
- **GitLab CE + Runner**: Full GitLab installation with CI/CD runner support
- **Backup & Restore**: Built-in backup and restore capabilities
- **Safe Upgrades**: Backup-first upgrade strategy with rollback support
- **Container Registry**: Docker registry included for storing container images
- **Git LFS Support**: Large File Storage enabled for repositories

## Quick Start

### 1. Initial Setup (One-time)

```bash
cd git
./gitlab_setup.sh
```

This will:
- Install Linode CLI
- Configure API authentication
- Generate SSH keys
- Create configuration files

### 2. Upload StackScript

```bash
./gitlab_upload_stackscript.sh
```

This uploads the server provisioning script to your Linode account.

### 3. Create GitLab Server

```bash
./gitlab_create_server.sh \
  --domain gitlab.example.com \
  --email admin@example.com
```

Wait 10-15 minutes for GitLab to install.

### 4. Access GitLab

1. Point your DNS A record for `gitlab.example.com` to the server IP
2. SSH to the server to get the root password:
   ```bash
   ssh gitlab@YOUR_SERVER_IP 'sudo cat /root/gitlab_credentials.txt'
   ```
3. Open `http://gitlab.example.com` in your browser
4. Login with username `root` and the auto-generated password
5. **Change your password immediately!**

## Scripts Overview

### Local Scripts (Run on your machine)

| Script | Purpose |
|--------|---------|
| `gitlab_setup.sh` | One-time local environment setup |
| `gitlab_upload_stackscript.sh` | Upload server provisioning script to Linode |
| `gitlab_create_server.sh` | Create a new GitLab server |
| `validate_stackscript.sh` | Validate StackScript for Linode compatibility |

### Server Scripts (Run on the GitLab server)

| Script | Purpose |
|--------|---------|
| `server_scripts/gitlab-backup.sh` | Backup GitLab data and configuration |
| `server_scripts/gitlab-restore.sh` | Restore GitLab from backup |
| `server_scripts/gitlab-upgrade.sh` | Safely upgrade GitLab with backup/rollback |
| `server_scripts/gitlab-register-runner.sh` | Register GitLab Runner for CI/CD |

## System Requirements

### Local Machine
- Python 3.6+
- SSH client
- Internet connection
- Linode account with API token

### Linode Server
- **Minimum**: 2GB RAM (g6-standard-1)
- **Recommended**: 4GB RAM (g6-standard-2) for teams
- Ubuntu 24.04 LTS
- 10GB+ disk space

## Configuration

Edit `~/.nwp/gitlab.yml` to customize:
- Default Linode region and plan
- GitLab external URL
- Email settings
- Backup retention
- Runner configuration

## Common Tasks

### Create a Backup

```bash
ssh gitlab@YOUR_SERVER 'cd gitlab-scripts && ./gitlab-backup.sh'
```

### Upgrade GitLab

```bash
ssh gitlab@YOUR_SERVER 'cd gitlab-scripts && ./gitlab-upgrade.sh'
```

### Register a Runner

```bash
# Get registration token from GitLab UI: Admin Area > CI/CD > Runners
ssh gitlab@YOUR_SERVER 'cd gitlab-scripts && ./gitlab-register-runner.sh --token YOUR_TOKEN'
```

## Security Features

- SSH key-only authentication (password auth disabled)
- Root login disabled
- UFW firewall configured (ports 22, 80, 443, 5050 only)
- Non-root sudo user for operations
- Automatic security updates
- Let's Encrypt SSL support

## Documentation

- [SETUP_GUIDE.md](docs/SETUP_GUIDE.md) - Detailed setup instructions
- [RUNNER_GUIDE.md](docs/RUNNER_GUIDE.md) - GitLab Runner configuration

## Architecture

```
Local Machine                    Linode Server
┌─────────────┐                 ┌──────────────────┐
│ gitlab_*.sh │ ──SSH/API────> │ GitLab CE        │
│ scripts     │                 │ GitLab Runner    │
└─────────────┘                 │ Docker           │
                                │ PostgreSQL       │
                                │ Redis            │
                                │ Nginx            │
                                └──────────────────┘
```

## Ports

| Port | Service |
|------|---------|
| 22 | SSH |
| 80 | HTTP (GitLab web UI) |
| 443 | HTTPS (with SSL) |
| 5050 | Container Registry |

## Backup Strategy

- **Automatic**: GitLab backups stored in `/var/opt/gitlab/backups/`
- **Configuration**: Separate backup of `/etc/gitlab/`
- **Retention**: 7 days (configurable)
- **Restore**: Full restoration from any backup

## Troubleshooting

### GitLab won't start
```bash
sudo gitlab-ctl status
sudo gitlab-ctl tail
```

### Check installation logs
```bash
sudo tail -f /var/log/gitlab-setup.log
```

### Reset root password
```bash
sudo gitlab-rake "gitlab:password:reset[root]"
```

### Verify GitLab health
```bash
sudo gitlab-rake gitlab:check
```

## Support

- GitLab Documentation: https://docs.gitlab.com/
- Linode Documentation: https://www.linode.com/docs/
- Issues: Check setup logs and GitLab documentation

## License

Same license as the parent NWP project.

## Notes

- GitLab requires **minimum 2GB RAM** for production use
- Initial root password is valid for **24 hours only**
- Blue-green deployment uses backup/restore pattern (not directory swapping like Drupal)
- Runner registration must be done after GitLab is installed
