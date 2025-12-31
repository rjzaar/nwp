# CLI Tools Setup Guide

Before running the automated setup script, you need to install and authenticate each CLI tool.

---

## 1. Linode CLI

**Install:**
```bash
pip install linode-cli --upgrade
```

**Authenticate:**
```bash
linode-cli configure
```

You'll need a Personal Access Token from:
https://cloud.linode.com/profile/tokens

Required scopes: Linodes (Read/Write), Domains (Read/Write)

**Verify:**
```bash
linode-cli account view
```

**Useful commands:**
```bash
linode-cli regions list              # See available regions
linode-cli linodes types             # See available plans
linode-cli linodes list              # List your Linodes
linode-cli linodes ssh <linode-id>   # SSH directly to a Linode
```

---

## 2. Backblaze B2 CLI

**Install:**
```bash
pip install b2 --upgrade
```

**Authenticate:**
```bash
b2 account authorize
```

You'll need your Account ID and Application Key from:
https://secure.backblaze.com/app_keys.htm

Use your master application key for initial setup, or create one with all capabilities.

**Verify:**
```bash
b2 account get
```

**Useful commands:**
```bash
b2 bucket list                       # List buckets
b2 bucket create <name> allPublic    # Create public bucket
b2 key create --bucket <bucket> <keyname> "listBuckets,listFiles,readFiles,writeFiles"
b2 file upload <bucket> <local> <remote>
b2 ls <bucket>
```

---

## 3. Cloudflare API

Cloudflare doesn't have an official CLI that covers all features we need, so the script uses `curl` with their API directly.

**Get API Token:**

1. Go to: https://dash.cloudflare.com/profile/api-tokens
2. Click "Create Token"
3. Use "Custom token" template
4. Set permissions:
   - Zone > DNS > Edit
   - Zone > Zone > Read  
   - Zone > Cache Purge > Purge (optional)
   - Zone > Zone Settings > Edit (optional)
5. Set zone resources: Include > Specific zone > yourdomain.com
6. Create and copy the token

**Get Zone ID:**

1. Go to your domain in Cloudflare dashboard
2. On the Overview page, scroll down right sidebar
3. Copy the "Zone ID"

**Test with curl:**
```bash
curl -s "https://api.cloudflare.com/client/v4/zones/<zone-id>" \
  -H "Authorization: Bearer <your-token>" | jq '.result.name'
```

**Alternative: flarectl (optional)**

If you prefer a CLI:
```bash
# Install (requires Go)
go install github.com/cloudflare/cloudflare-go/cmd/flarectl@latest

# Or download binary from:
# https://github.com/cloudflare/cloudflare-go/releases

# Configure
export CF_API_TOKEN="your-token"

# Use
flarectl zone list
flarectl dns list --zone yourdomain.com
```

---

## 4. Additional Tools

The script also requires:

```bash
# jq - JSON processor
sudo apt install jq

# openssl - for generating passwords (usually pre-installed)
sudo apt install openssl
```

---

## Running the Setup Script

1. **Edit the script configuration:**
   ```bash
   nano castopod-automated-setup.sh
   ```
   
   Update these variables at the top:
   ```bash
   DOMAIN="yourdomain.com"
   PODCAST_SUBDOMAIN="podcast"
   MEDIA_SUBDOMAIN="media"
   LINODE_REGION="us-east"
   CF_API_TOKEN="your-cloudflare-token"
   CF_ZONE_ID="your-zone-id"
   ```

2. **Make executable and run:**
   ```bash
   chmod +x castopod-automated-setup.sh
   ./castopod-automated-setup.sh
   ```

3. **Deploy to server:**
   ```bash
   cd castopod-setup-<timestamp>
   ./deploy-to-server.sh
   ```

---

## What the Script Does

| Phase | Actions |
|-------|---------|
| **B2 Setup** | Creates bucket, generates application key |
| **Cloudflare Setup** | Creates DNS records, transform rules, cache rules |
| **Linode Setup** | Creates VPS with Docker pre-installed via cloud-init |
| **File Generation** | Creates docker-compose.yml, .env, Caddyfile |

---

## Manual Verification

After running, verify each component:

**B2:**
```bash
b2 bucket list
b2 key list
```

**Cloudflare:**
```bash
# Check DNS
dig podcast.yourdomain.com
dig media.yourdomain.com

# Or via API
curl -s "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" \
  -H "Authorization: Bearer $CF_API_TOKEN" | jq '.result[] | {name, type, content}'
```

**Linode:**
```bash
linode-cli linodes list
ssh root@<linode-ip> "docker ps"
```

---

## Teardown

To remove everything:

```bash
# Delete Linode
linode-cli linodes delete <linode-id>

# Delete B2 bucket (must be empty first)
b2 file delete <bucket> --all-versions  # if files exist
b2 bucket delete <bucket-name>

# Delete B2 key
b2 key delete <key-id>

# Cloudflare DNS records (via dashboard or API)
curl -X DELETE "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/<record-id>" \
  -H "Authorization: Bearer $CF_API_TOKEN"
```