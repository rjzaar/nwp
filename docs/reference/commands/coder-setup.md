# coder-setup

Manage NS delegation and infrastructure for additional NWP coders.

## Overview

The `coder-setup` command manages DNS delegation for additional coders who have their own subdomains under the base domain (e.g., nwpcode.org). Each coder gets full DNS autonomy and can create their own subdomains like git.coder.nwpcode.org.

## Usage

```bash
pl coder-setup <command> [options] <name>
```

## Commands

| Command | Description |
|---------|-------------|
| `add <name>` | Add NS delegation and optionally GitLab account for new coder |
| `remove <name>` | Remove NS delegation and revoke access for coder |
| `provision <name>` | Provision Linode server and DNS for coder |
| `list` | List all configured coders |
| `verify <name>` | Verify DNS delegation is working |
| `gitlab-users` | List all GitLab users |

## Options for 'add'

| Flag | Description |
|------|-------------|
| `--notes "text"` | Add a description when adding coder |
| `--email "addr"` | Email address for GitLab account (enables GitLab user creation) |
| `--fullname "nm"` | Full name for GitLab account (default: coder name) |
| `--gitlab-group` | GitLab group to add user to (default: nwp) |
| `--no-gitlab` | Skip GitLab user creation even if email provided |
| `--dry-run` | Show what would be done without making changes |

## Options for 'provision'

| Flag | Description |
|------|-------------|
| `--region` | Linode region (default: us-east) |
| `--plan` | Linode plan type (default: g6-nanode-1) |
| `--dry-run` | Show what would be done without making changes |

## Options for 'remove'

| Flag | Description |
|------|-------------|
| `--keep-gitlab` | Don't revoke GitLab access |
| `--archive` | Archive contribution history before removal |
| `--dry-run` | Show what would be done without making changes |

## Examples

### Add coder with notes
```bash
pl coder-setup add coder2 --notes "John's dev environment"
```

### Add coder with GitLab account
```bash
pl coder-setup add john --email "john@example.com" --fullname "John Smith"
```

### Provision server infrastructure
```bash
pl coder-setup provision john --region us-west --plan g6-standard-1
```

### Remove coder
```bash
pl coder-setup remove coder2
```

### List all coders
```bash
pl coder-setup list
```

### Verify DNS delegation
```bash
pl coder-setup verify coder2
```

### List GitLab users
```bash
pl coder-setup gitlab-users
```

## What Each Coder Gets

When you add a coder, they receive:

1. **NS Delegation**: coder.nwpcode.org → Linode nameservers
2. **Full DNS Autonomy**: Can create any subdomain via their own Linode account
3. **GitLab Account**: (if --email provided) Access to NWP repository
4. **Subdomain Examples**: git.coder.nwpcode.org, nwp.coder.nwpcode.org

## DNS Provider Support

The command supports multiple DNS providers:

- **Cloudflare**: Automatic if configured in .secrets.yml
- **Linode**: Fallback or primary if Cloudflare not available
- **Manual**: Shows instructions if no provider configured

## Coder Name Requirements

Coder names must:
- Start with a letter
- Contain only alphanumeric, underscore, or hyphen characters
- Be max 32 characters
- Not be reserved names (www, git, mail, smtp, etc.)

## Provisioning Workflow

When using `provision`, the command:

1. Creates Linode VPS with Ubuntu 22.04
2. Creates DNS zone for coder subdomain
3. Adds A records (@, git, *)
4. Updates coder config with server info
5. Provides SSH access instructions

## Removal Workflow

When using `remove`, the command:

1. Removes NS delegation from base domain
2. Blocks GitLab user account (unless --keep-gitlab)
3. Removes from nwp group
4. Removes from nwp.yml configuration
5. Logs offboarding action
6. Optionally archives contribution history (--archive)

## Prerequisites

- Cloudflare or Linode API credentials in .secrets.yml
- For GitLab features: GitLab admin token configured
- For provisioning: linode-cli installed (pip install linode-cli)
- SSH keys generated (./setup-ssh.sh)

## Related Commands

- [coders.sh](coders.md) - Interactive TUI for managing coders
- [setup-ssh.sh](setup-ssh.md) - Generate SSH keys
- [upstream.sh](upstream.md) - Configure upstream repository

## See Also

- [Coder Onboarding Guide](../../guides/coder-onboarding.md) - Complete setup instructions
- [Distributed Contribution Governance](../../governance/distributed-contribution-governance.md) - Governance model
- `nwp.yml` - Coder configuration file
