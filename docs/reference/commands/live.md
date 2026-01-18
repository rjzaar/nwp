# live

Provision and manage live test servers.

**Last Updated:** 2026-01-14

## Overview

The `live` command provisions live test servers at `sitename.nwpcode.org`. It supports three server types: shared (GitLab server), dedicated (one Linode per site), and temporary (auto-delete).

## Usage

```bash
pl live [OPTIONS] <sitename>
```

## Arguments

| Argument | Description |
|----------|-------------|
| `sitename` | Site name (uses base name, not `-stg` suffix) |

## Options

| Flag | Description |
|------|-------------|
| `-h, --help` | Show help message |
| `-d, --debug` | Enable debug output |
| `-y, --yes` | Auto-confirm prompts |
| `--delete` | Delete live server |
| `--type=TYPE` | Server type: `dedicated`, `shared`, `temporary` |
| `--expires=DAYS` | Days until auto-delete (temporary only) |
| `--status` | Show live server status |
| `--ssh` | SSH into the live server |

## Server Types

| Type | Description | Cost | Use Case |
|------|-------------|------|----------|
| `shared` | Deploy on existing GitLab server | Free | Default, cost-effective for testing |
| `dedicated` | One Linode per site | ~$5/month | Production-like environment |
| `temporary` | Dedicated with expiration | ~$5/month | PR reviews, temporary testing |

## Examples

### Deploy on shared GitLab server (default)
```bash
pl live nwp
```

### Provision dedicated Linode
```bash
pl live --type=dedicated nwp
```

### Provision temporary server
```bash
pl live --type=temporary --expires=7 nwp
```

### Delete live server
```bash
pl live --delete nwp
```

### Show status
```bash
pl live --status nwp
```

### SSH to server
```bash
pl live --ssh nwp
```

## Shared Server Provisioning

For shared (GitLab) server deployment:

1. Checks GitLab server access (git.nwpcode.org)
2. Creates site directory (`/var/www/<sitename>`)
3. Configures nginx vhost
4. Adds DNS record (if Linode API token available)
5. Sets up SSL certificate via Let's Encrypt
6. Configures email forwarding
7. Applies server security hardening
8. Calls `stg2live` to deploy staging site

## Dedicated Server Provisioning

For dedicated Linode deployment:

1. Creates Linode instance via API
2. Waits for instance to boot
3. Configures SSH access
4. Adds DNS record
5. Sets up nginx
6. Obtains SSL certificate
7. Configures email forwarding
8. Applies server security hardening (fail2ban, ufw, SSH hardening)
9. Updates nwp.yml with server info
10. Calls `stg2live` to deploy staging site

## Security Hardening

Automatically applies:
- **fail2ban** - Intrusion prevention (SSH, nginx)
- **UFW firewall** - Allow only SSH, HTTP, HTTPS
- **SSH hardening** - Disable password auth, require keys
- **Auto-updates** - Enable unattended security updates

## SSL Certificate

Uses Let's Encrypt via certbot:
- Waits for DNS propagation (up to 5 minutes)
- Obtains wildcard-free certificate for sitename.nwpcode.org
- Configures nginx for HTTPS redirection
- Adds security headers

## Email Configuration

Automatically configures email forwarding:
- Creates `sitename@nwpcode.org` alias
- Forwards to admin email from `settings.email.admin_email`
- Updates Drupal site email configuration

## Production Mode Requirement

The live command ensures the staging site is in production mode before deployment. If staging is in dev mode, it automatically runs `pl make -py <sitename>` to switch.

## Site Naming

Both `pl live mysite` and `pl live mysite-stg` work:
- Live URL always uses base name: `mysite.nwpcode.org`
- Deploys from `mysite-stg` staging site

## Configuration

Stores live server info in `nwp.yml`:

```yaml
sites:
  mysite:
    recipe: nwp
    live:
      server_ip: 192.0.2.10
      domain: mysite.nwpcode.org
      linode_id: 12345678  # (dedicated only)
      type: dedicated  # or shared, temporary
```

## Prerequisites

### For shared servers:
- SSH access to GitLab server (git.nwpcode.org)
- Staging site must exist

### For dedicated servers:
- Linode API token in `.secrets.yml`
- SSH key at `keys/nwp.pub` or `~/.ssh/nwp.pub`
- Staging site must exist

## Troubleshooting

### Cannot access GitLab server
- Verify SSH keys are configured
- Test: `ssh gitlab@git.nwpcode.org`

### Linode API token not found
- Add to `.secrets.yml`:
  ```yaml
  linode:
    api_token: your-token-here
  ```

### DNS not propagating
- Wait 5-10 minutes for DNS changes
- Check: `dig sitename.nwpcode.org`
- SSL will retry if DNS fails

### SSH connectivity lost after security hardening
- Server may need recovery via Linode console (Lish)
- Check firewall rules didn't block your IP

## Exit Codes

- `0` - Provisioning successful
- `1` - Provisioning failed

## Related Commands

- [stg2live](stg2live.md) - Deploy staging to live (called automatically)
- [live2stg](live2stg.md) - Pull live back to staging
- [live2prod](live2prod.md) - Deploy live to production

## See Also

- Linode API documentation
- Let's Encrypt / certbot documentation
- Server security best practices
