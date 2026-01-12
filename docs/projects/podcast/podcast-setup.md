# Podcast Hosting Setup Guide

This guide covers setting up Castopod podcast hosting using the NWP automated tools.

---

## Quick Start (Automated)

The fastest way to set up a podcast is using the automated script:

```bash
# 1. Configure credentials (one-time setup)
cp .secrets.example.yml .secrets.yml
# Edit .secrets.yml with your API tokens

# 2. Generate SSH keys (if not already done)
./setup-ssh.sh

# 3. Authorize B2 CLI (one-time setup)
pip install b2
b2 account authorize

# 4. Run the automated setup
./podcast.sh setup podcast.example.com
```

This creates:
- Linode VPS with Docker (~$5/month)
- B2 bucket for media storage (free tier: 10GB)
- Cloudflare DNS records
- All configuration files

---

## Prerequisites

### 1. Linode CLI & API Token

**Get API Token:**
- Go to: https://cloud.linode.com/profile/tokens
- Create a Personal Access Token
- Required scopes: Linodes (Read/Write), Domains (Read/Write)

**Add to .secrets.yml:**
```yaml
linode:
  api_token: YOUR_LINODE_API_TOKEN_HERE
```

**Optional - Install CLI for manual management:**
```bash
pip install linode-cli --upgrade
linode-cli configure
```

**Verify:**
```bash
linode-cli account view
```

---

### 2. Backblaze B2

**Install CLI:**
```bash
pip install b2 --upgrade
```

**Authenticate:**
```bash
b2 account authorize
```

Get your Account ID and Application Key from:
https://secure.backblaze.com/app_keys.htm

**Add to .secrets.yml (optional, for automated setup):**
```yaml
b2:
  account_id: YOUR_B2_ACCOUNT_ID
  app_key: YOUR_B2_APP_KEY
```

**Verify:**
```bash
b2 account get
```

---

### 3. Cloudflare

**Get API Token:**
1. Go to: https://dash.cloudflare.com/profile/api-tokens
2. Click "Create Token"
3. Use "Custom token" template
4. Set permissions:
   - Zone > DNS > Edit
   - Zone > Zone > Read
   - Zone > Cache Purge > Purge (optional)
5. Set zone resources: Include > Specific zone > yourdomain.com
6. Create and copy the token

**Get Zone ID:**
1. Go to your domain in Cloudflare dashboard
2. On the Overview page, scroll down right sidebar
3. Copy the "Zone ID"

**Add to .secrets.yml:**
```yaml
cloudflare:
  api_token: YOUR_CLOUDFLARE_API_TOKEN
  zone_id: YOUR_CLOUDFLARE_ZONE_ID
```

---

## Using the Podcast Script

### Check Status

Verify all prerequisites are configured:

```bash
./podcast.sh status
```

### Full Automated Setup

Creates complete podcast infrastructure:

```bash
./podcast.sh setup podcast.example.com
```

Options:
```bash
# Custom Linode region
./podcast.sh setup -r us-west podcast.example.com

# Custom B2 region
./podcast.sh setup -b eu-central-003 podcast.example.com

# Auto-confirm prompts
./podcast.sh setup -y podcast.example.com
```

### Generate Files Only

If you have an existing server, generate config files without creating infrastructure:

```bash
./podcast.sh generate podcast.example.com
```

Then edit the `.env` file to add your B2 credentials and deploy manually.

### Deploy Configuration

Deploy generated files to a server:

```bash
./podcast.sh deploy podcast-setup-20241231-120000
```

### Teardown

Remove infrastructure (Linode only - B2 and DNS are preserved):

```bash
./podcast.sh teardown <linode_id>
```

---

## What Gets Created

| Component | Service | Cost |
|-----------|---------|------|
| VPS | Linode Nanode | ~$5/month |
| Media Storage | Backblaze B2 | Free up to 10GB |
| DNS & CDN | Cloudflare | Free |
| SSL | Caddy (auto Let's Encrypt) | Free |

---

## Manual Verification

After setup, verify each component:

**Server:**
```bash
# SSH into server
ssh -i keys/nwp root@<server-ip>

# Check Docker containers
docker compose -f ~/castopod/docker-compose.yml ps

# View logs
docker compose -f ~/castopod/docker-compose.yml logs -f
```

**DNS:**
```bash
dig podcast.yourdomain.com
dig media.yourdomain.com
```

**B2:**
```bash
b2 bucket list
b2 key list
```

---

## Complete Setup Workflow

After the automated setup finishes:

1. **Wait for DNS propagation** (usually 1-5 minutes with Cloudflare)

2. **Complete Castopod installation:**
   - Visit: `https://podcast.yourdomain.com/admin/install`
   - Create your admin account
   - Configure your podcast details

3. **Create your first podcast:**
   - Log in to admin panel
   - Create a new podcast
   - Add cover art and description
   - Publish your first episode

4. **Submit to directories:**
   - Copy your RSS feed URL
   - Submit to Apple Podcasts, Spotify, etc.

---

## Troubleshooting

### DNS not resolving

Wait a few minutes for propagation, or check:
```bash
dig podcast.yourdomain.com @1.1.1.1
```

### Container not starting

Check logs:
```bash
ssh root@<server-ip> "docker compose -f ~/castopod/docker-compose.yml logs"
```

### B2 upload issues

Verify B2 configuration in `.env`:
```bash
ssh root@<server-ip> "grep CP_MEDIA ~/castopod/.env"
```

### SSL certificate issues

Caddy auto-obtains certificates. Check logs:
```bash
ssh root@<server-ip> "docker compose -f ~/castopod/docker-compose.yml logs caddy"
```

---

## Teardown (Complete Cleanup)

To remove everything:

```bash
# Delete Linode
./podcast.sh teardown <linode-id>

# Or manually:
linode-cli linodes delete <linode-id>

# Delete B2 bucket (must be empty first)
b2 ls <bucket-name>  # List files
b2 rm <bucket-name>/* --recursive  # Delete files
b2 bucket delete <bucket-name>

# Delete B2 key
b2 key list
b2 key delete <key-id>

# Delete Cloudflare DNS records via dashboard
# Or via API:
curl -X DELETE "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/<record-id>" \
  -H "Authorization: Bearer $CF_API_TOKEN"
```

---

## Configuration Reference

### .secrets.yml

```yaml
linode:
  api_token: YOUR_LINODE_API_TOKEN

cloudflare:
  api_token: YOUR_CLOUDFLARE_API_TOKEN
  zone_id: YOUR_CLOUDFLARE_ZONE_ID

b2:
  account_id: YOUR_B2_ACCOUNT_ID
  app_key: YOUR_B2_APP_KEY
```

### Generated Files

| File | Purpose |
|------|---------|
| `.env` | Environment variables for Castopod |
| `docker-compose.yml` | Container orchestration |
| `Caddyfile` | Reverse proxy with auto-SSL |
| `deploy.sh` | Server deployment script |
| `deployment-info.txt` | Resource IDs for teardown |

---

## Library Reference

The podcast automation uses these NWP libraries:

| Library | Purpose |
|---------|---------|
| `lib/cloudflare.sh` | Cloudflare API operations |
| `lib/b2.sh` | Backblaze B2 operations |
| `lib/podcast.sh` | Podcast-specific functions |
| `lib/linode.sh` | Linode API operations |

Each library can be sourced independently for custom scripts:

```bash
source lib/cloudflare.sh
cf_create_dns_a "$token" "$zone_id" "test" "1.2.3.4" "true"
```
