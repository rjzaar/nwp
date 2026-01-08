# New Coder Onboarding Guide

This guide walks you through setting up your own NWP development environment with a dedicated subdomain under nwpcode.org.

## Overview

As a new coder, you'll receive:

- **GitLab account** on the central NWP GitLab server (`git.nwpcode.org`)
- A delegated subdomain: `<yourname>.nwpcode.org`
- Full DNS control via your own Linode account
- Ability to create services like:
  - `git.<yourname>.nwpcode.org` - Your own GitLab instance (optional)
  - `nwp.<yourname>.nwpcode.org` - Your NWP sites
  - `*.yourname.nwpcode.org` - Any other subdomains you need

## Prerequisites

Before starting, you need:

1. **Contact the NWP administrator** to request access (see Step 1)
2. **Your email address** for GitLab account
3. **A Linode account** (or create one during setup)
4. **Basic command line knowledge**
5. **SSH key pair** for server access

## Requesting Access

### Who to Contact

Contact the NWP administrator:
- **Email**: [administrator email]
- **GitHub**: Open an issue at https://github.com/rjzaar/nwp/issues

### What to Provide

When requesting access, include:
1. Your desired **coder name** (e.g., "john", "dev1") - alphanumeric, starts with letter
2. Your **email address** for GitLab account
3. Your **full name** (for GitLab profile)
4. Brief description of your intended use

## Step 1: Administrator Sets Up Your Access

The NWP administrator will run:

```bash
./coder-setup.sh add <yourname> --email "you@example.com" --fullname "Your Name"
```

This automatically:
1. Creates NS delegation for `<yourname>.nwpcode.org`
2. Creates your GitLab account on `git.nwpcode.org`
3. Adds you to the `nwp` group with Developer access

You'll receive:
- GitLab login credentials (username + temporary password)
- Confirmation that your subdomain is ready

**Note:** DNS propagation takes 24-48 hours. You can proceed with GitLab and Linode setup while waiting.

## Step 1b: Log into GitLab

1. Go to https://git.nwpcode.org
2. Log in with the credentials provided by the administrator
3. **Change your password** immediately (Profile → Password)
4. Add your SSH public key (Profile → SSH Keys)

You now have access to the NWP codebase and can clone repositories.

## Step 2: Create Your Linode Account

1. Go to [https://www.linode.com/](https://www.linode.com/)
2. Sign up for a new account
3. Complete email verification
4. Add a payment method

## Step 3: Generate Linode API Token

1. Log into [Linode Cloud Manager](https://cloud.linode.com/)
2. Click your profile icon → **API Tokens**
3. Click **Create a Personal Access Token**
4. Configure the token:
   - **Label:** `nwp-infrastructure`
   - **Expiry:** 6 months or longer
   - **Permissions:**
     - Domains: Read/Write
     - Linodes: Read/Write
     - Images: Read Only
     - All others: No Access
5. Click **Create Token**
6. **IMPORTANT:** Copy and save the token immediately (shown only once)

## Step 4: Create Your DNS Zone

### Via Linode Dashboard

1. Go to [Domains](https://cloud.linode.com/domains) in Linode Cloud Manager
2. Click **Create Domain**
3. Fill in:
   - **Domain:** `<yourname>.nwpcode.org`
   - **SOA Email:** Your email address
   - **Insert Default Records:** No
4. Click **Create Domain**

### Via Linode CLI (Alternative)

```bash
# Install Linode CLI
pip install linode-cli

# Configure with your token
linode-cli configure

# Create the domain
linode-cli domains create \
  --domain <yourname>.nwpcode.org \
  --type master \
  --soa_email your@email.com
```

## Step 5: Create Your Linode Server

### Via Dashboard

1. Go to [Linodes](https://cloud.linode.com/linodes)
2. Click **Create Linode**
3. Configure:
   - **Image:** Ubuntu 22.04 LTS
   - **Region:** Choose closest to you (e.g., us-east)
   - **Plan:** Nanode 1 GB ($5/month) or Linode 2 GB ($12/month)
   - **Label:** `<yourname>-nwp`
   - **Root Password:** Strong password
   - **SSH Keys:** Add your public key
4. Click **Create Linode**
5. Note the **IP address** once provisioned

### Via CLI

```bash
# Create the Linode
linode-cli linodes create \
  --label <yourname>-nwp \
  --region us-east \
  --type g6-nanode-1 \
  --image linode/ubuntu22.04 \
  --authorized_keys "$(cat ~/.ssh/id_rsa.pub)"
```

## Step 6: Configure DNS Records

Once your server has an IP address, add DNS records.

### Via Dashboard

1. Go to **Domains** → click your domain
2. Add records:

| Type | Name | Value | TTL |
|------|------|-------|-----|
| A | (empty) | Your server IP | 300 |
| A | git | Your server IP | 300 |
| A | * | Your server IP | 300 |

### Via CLI

```bash
# Get your domain ID
DOMAIN_ID=$(linode-cli domains list --json | jq -r '.[] | select(.domain=="<yourname>.nwpcode.org") | .id')

# Add root A record
linode-cli domains records-create $DOMAIN_ID \
  --type A --name "" --target YOUR_SERVER_IP --ttl_sec 300

# Add git subdomain
linode-cli domains records-create $DOMAIN_ID \
  --type A --name git --target YOUR_SERVER_IP --ttl_sec 300

# Add wildcard for all other subdomains
linode-cli domains records-create $DOMAIN_ID \
  --type A --name "*" --target YOUR_SERVER_IP --ttl_sec 300
```

## Step 7: Verify DNS Resolution

Test that your DNS is working:

```bash
# Check NS delegation (may take up to 48 hours)
dig NS <yourname>.nwpcode.org

# Should return ns1-ns5.linode.com

# Check A record
dig A <yourname>.nwpcode.org

# Should return your server IP

# Check git subdomain
dig A git.<yourname>.nwpcode.org

# Should return your server IP
```

## Step 8: Set Up Your Server

SSH into your new server:

```bash
ssh root@<yourname>.nwpcode.org
# Or use the IP if DNS hasn't propagated:
ssh root@YOUR_SERVER_IP
```

### Install Dependencies

```bash
# Update system
apt update && apt upgrade -y

# Install required packages
apt install -y git curl wget unzip nginx certbot python3-certbot-nginx

# Install Docker
curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh
rm get-docker.sh

# Install Docker Compose
apt install -y docker-compose-plugin
```

### Clone NWP

```bash
cd /root
git clone https://github.com/rjzaar/nwp.git
cd nwp
```

### Configure NWP

```bash
# Copy example config
cp example.cnwp.yml cnwp.yml
cp .secrets.example.yml .secrets.yml

# Edit configuration
nano cnwp.yml
```

Update `cnwp.yml` with your settings:

```yaml
settings:
  url: <yourname>.nwpcode.org
  # ... other settings
```

Update `.secrets.yml`:

```yaml
linode:
  api_token: "your_linode_api_token_here"
```

## Step 9: Install GitLab (Optional)

If you want your own GitLab instance:

```bash
# Run GitLab installer
./linode/gitlab/setup_gitlab_site.sh
```

This will set up GitLab at `git.<yourname>.nwpcode.org`.

## Step 10: Create Your First Site

```bash
# Create a Drupal site
./install.sh d mysite

# Or create an Open Social site
./install.sh os mysite

# Or create an AVC site
./install.sh avc mysite
```

Access your site at: `https://mysite.<yourname>.nwpcode.org`

## SSL Certificates

Let's Encrypt certificates are automatically configured. If you need to manually obtain:

```bash
# Single domain
certbot --nginx -d <yourname>.nwpcode.org

# Multiple domains
certbot --nginx -d <yourname>.nwpcode.org -d git.<yourname>.nwpcode.org
```

## Configuration Reference

### Your `.secrets.yml`

```yaml
# Linode API for server management
linode:
  api_token: "your_token_here"

# GitLab (after installation)
gitlab:
  server:
    domain: git.<yourname>.nwpcode.org
    ip: YOUR_SERVER_IP
  api_token: "gitlab_api_token"

# Development defaults
dev_defaults:
  drupal:
    admin_user: admin
    admin_email: admin@<yourname>.nwpcode.org
```

### Your `cnwp.yml`

```yaml
settings:
  url: <yourname>.nwpcode.org

  gitlab:
    default_group: nwp
    repos:
      nwp: nwp/nwp

# Your sites will appear here after creation
sites:
  # mysite:
  #   directory: /root/nwp/mysite
  #   recipe: d
  #   ...
```

## Troubleshooting

### DNS Not Resolving

1. Wait 24-48 hours for propagation
2. Check NS delegation: `dig NS <yourname>.nwpcode.org`
3. Verify zone exists in Linode: `linode-cli domains list`
4. Check records: `linode-cli domains records-list $DOMAIN_ID`

### Cannot Connect to Server

1. Check Linode is running in Cloud Manager
2. Verify firewall allows SSH: `ufw status`
3. Check SSH key is added
4. Try connecting by IP instead of hostname

### SSL Certificate Issues

```bash
# Check certificate status
certbot certificates

# Renew manually
certbot renew

# Debug issues
certbot --nginx -d <yourname>.nwpcode.org --dry-run
```

### GitLab Not Starting

```bash
# Check container status
docker ps -a

# View logs
docker logs gitlab

# Restart
docker restart gitlab
```

## Getting Help

- **NWP Documentation:** Check the `docs/` folder
- **Issues:** Report at [GitHub Issues](https://github.com/rjzaar/nwp/issues)
- **Administrator:** Contact the main NWP administrator

## Administrator Tools

Administrators can manage coders using the interactive TUI:

```bash
# Launch interactive coders management TUI
./scripts/commands/coders.sh
```

**TUI Features:**
- Arrow-key navigation through all coders
- Auto-sync contribution data from GitLab
- Bulk selection with Space for mass operations
- Detailed stats view with Enter
- Promote, modify, or delete coders

**TUI Controls:**
| Key | Action |
|-----|--------|
| ↑/↓ | Navigate coders |
| Space | Select for bulk actions |
| Enter | View detailed stats |
| P | Promote selected |
| D | Delete selected |
| S | Sync from GitLab |
| Q | Quit |

**Other admin commands:**
```bash
# Add a new coder
./scripts/commands/coder-setup.sh add <name> --email "email" --fullname "Name"

# Provision Linode infrastructure for coder
./scripts/commands/coder-setup.sh provision <name>

# Remove a coder (with GitLab access revocation)
./scripts/commands/coder-setup.sh remove <name>

# List all coders
./scripts/commands/coders.sh list
```

## Quick Reference

| Service | URL |
|---------|-----|
| Your Domain | `<yourname>.nwpcode.org` |
| GitLab | `git.<yourname>.nwpcode.org` |
| Sites | `sitename.<yourname>.nwpcode.org` |

| Command | Description |
|---------|-------------|
| `./install.sh d sitename` | Create Drupal site |
| `./install.sh os sitename` | Create Open Social site |
| `./delete.sh sitename` | Delete a site |
| `./status.sh` | Show all sites |
| `./backup.sh sitename` | Backup a site |

## Related Documentation

- [ROLES.md](ROLES.md) - Developer role definitions and access levels
- [CONTRIBUTING.md](../CONTRIBUTING.md) - How to contribute to NWP
- [CORE_DEVELOPER_ONBOARDING_PROPOSAL.md](CORE_DEVELOPER_ONBOARDING_PROPOSAL.md) - Full onboarding automation proposal
- [DISTRIBUTED_CONTRIBUTION_GOVERNANCE.md](DISTRIBUTED_CONTRIBUTION_GOVERNANCE.md) - Governance framework
