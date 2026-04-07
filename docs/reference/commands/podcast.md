# podcast

**Last Updated:** 2026-01-14

Automated setup for Castopod podcast hosting infrastructure using Backblaze B2, Linode VPS, and Cloudflare.

## Synopsis

```bash
pl podcast <command> [options] [arguments]
```

## Description

Automates the deployment of a complete podcast hosting infrastructure using Castopod, an open-source podcast management platform. This command orchestrates cloud resource provisioning, DNS configuration, and Docker deployment.

The `podcast` command supports two deployment modes:
1. **Full mode** - Uses Backblaze B2 for media storage, Cloudflare for DNS
2. **Linode-only mode** - Uses local VPS storage, Linode DNS (simpler, no external dependencies)

Infrastructure components:
- **Linode VPS** - Hosts Castopod application and database
- **Backblaze B2** - Stores podcast media files (optional)
- **Cloudflare DNS** - Manages domain records and CDN (optional)
- **Docker** - Containerizes Castopod, MariaDB, Redis, and Caddy
- **Caddy** - Reverse proxy with automatic HTTPS

## Commands

| Command | Description |
|---------|-------------|
| `setup <domain>` | Full automated infrastructure setup |
| `generate <domain>` | Generate configuration files only (no infrastructure) |
| `deploy <directory>` | Deploy configuration to existing server |
| `teardown <linode-id>` | Remove infrastructure (delete VPS) |
| `status` | Check prerequisites and credentials |

## Global Options

| Option | Description | Default |
|--------|-------------|---------|
| `-h, --help` | Show help message | - |
| `-r, --region` | Linode region | us-east |
| `-m, --media` | Media subdomain | media |
| `-b, --b2-region` | B2 region | us-west-004 |
| `-l, --linode-only` | Use Linode DNS and local storage (no Cloudflare/B2) | false |
| `-y, --yes` | Auto-confirm prompts | false |
| `-v, --verbose` | Enable debug output | false |

## Examples

### Full Automated Setup (Cloudflare + B2)

```bash
pl podcast setup podcast.example.com
```

Creates complete infrastructure with Cloudflare DNS and B2 media storage.

### Linode-Only Setup

```bash
pl podcast setup --linode-only podcast.example.com
```

Simpler setup using only Linode DNS and local VPS storage (no Cloudflare or B2 required).

### Custom Region

```bash
pl podcast setup -r us-west podcast.example.com
```

Deploys to US West region instead of default US East.

### Generate Configuration Only

```bash
pl podcast generate podcast.example.com
```

Creates configuration files without provisioning infrastructure (for manual deployment).

### Generate for Linode-Only

```bash
pl podcast generate --linode-only podcast.example.com
```

Generates configuration for local storage instead of B2.

### Deploy to Existing Server

```bash
pl podcast deploy podcast-setup-20241231-120000
```

Deploys previously generated configuration to server.

### Check Prerequisites

```bash
pl podcast status
```

Verifies credentials, tools, and readiness for setup.

### Teardown Infrastructure

```bash
pl podcast teardown 12345678
```

Deletes the Linode VPS with ID 12345678 (does not delete B2 bucket or DNS records).

## Commands Detail

### setup

Performs full automated infrastructure provisioning and deployment.

**Process:**
1. Validates prerequisites and credentials
2. Creates B2 bucket and application key (if not `--linode-only`)
3. Provisions Linode VPS with Docker
4. Configures DNS records (Cloudflare or Linode)
5. Generates configuration files (.env, docker-compose.yml, Caddyfile)
6. Deploys configuration to server
7. Starts Castopod containers

**Output:** Deployment information including server IP, domain, SSH access, and next steps.

**Flags:**
- `--linode-only` - Skip B2 and Cloudflare, use Linode DNS and local storage
- `-y` - Auto-confirm resource creation
- `-r` - Specify Linode region
- `-b` - Specify B2 region (ignored with `--linode-only`)

### generate

Creates configuration files without provisioning infrastructure.

**Use Cases:**
- Manual deployment to existing servers
- Configuration review before deployment
- Offline configuration preparation
- Custom infrastructure setups

**Output:** Directory containing:
- `.env` - Environment variables
- `docker-compose.yml` - Container definitions
- `Caddyfile` - Reverse proxy configuration
- `deploy.sh` - Deployment script

**Note:** When not using `--linode-only`, you must fill in B2 credentials in `.env` before deployment.

### deploy

Copies configuration files to server and starts containers.

**Prerequisites:**
- Server must exist and be accessible
- SSH key must be configured
- Docker must be installed on server

**Process:**
1. Reads server IP from deployment-info.txt (or prompts)
2. Copies files to server via SCP
3. Runs docker compose pull and up -d
4. Displays container status

### teardown

Deletes Linode VPS to remove infrastructure.

**Warning:** This is destructive and cannot be undone.

**What it removes:**
- Linode VPS instance
- All data on the VPS (database, local media)

**What it does NOT remove:**
- B2 bucket and files (manual deletion required)
- Cloudflare DNS records (manual deletion required)
- Configuration files on local machine

**Safety:** Prompts for confirmation unless `-y` flag used.

### status

Checks system readiness and credential validity.

**Checks:**
- SSH keys exist
- Linode API token configured and valid
- Cloudflare credentials configured and valid (unless `--linode-only`)
- B2 CLI installed and authenticated (unless `--linode-only`)
- Required tools installed (curl, jq, openssl, docker)

**Exit Codes:**
- 0 - All prerequisites met
- 1 - One or more prerequisites missing

## Prerequisites

### Always Required

| Requirement | Purpose | Install |
|-------------|---------|---------|
| Linode API token | VPS provisioning | Get from https://cloud.linode.com/profile/tokens |
| SSH keys | Server access | `./setup-ssh.sh` |
| curl | HTTP requests | `apt install curl` |
| jq | JSON parsing | `apt install jq` |
| openssl | Key generation | `apt install openssl` |

### Required for Full Mode (not `--linode-only`)

| Requirement | Purpose | Install |
|-------------|---------|---------|
| Cloudflare API token | DNS management | Get from Cloudflare dashboard |
| Cloudflare Zone ID | Domain identification | Get from Cloudflare dashboard |
| B2 account | Media storage | Sign up at backblaze.com |
| B2 CLI | Bucket creation | `pip install b2` |

### Optional

| Tool | Purpose | Install |
|------|---------|---------|
| docker | Local testing | `apt install docker.io` |
| yq | YAML parsing | Download from github.com/mikefarah/yq |

## Configuration Files

### .secrets.yml

Store API credentials:

```yaml
# Linode (always required)
linode:
  api_token: "your-linode-token"

# Cloudflare (skip for --linode-only)
cloudflare:
  api_token: "your-cloudflare-token"
  zone_id: "your-zone-id"

# Backblaze B2 (skip for --linode-only)
b2:
  account_id: "your-b2-account-id"
  application_key: "your-b2-app-key"
```

### Generated .env (Full Mode)

```bash
# Castopod Configuration
CP_BASEURL="https://podcast.example.com"
CP_ADMIN_GATEWAY="admin"
CP_AUTH_GATEWAY="auth"

# Database
CP_DATABASE_HOSTNAME="mariadb"
CP_DATABASE_NAME="castopod"
CP_DATABASE_USERNAME="castopod"
CP_DATABASE_PASSWORD="<generated>"
CP_DATABASE_PREFIX="cp_"

# Cache
CP_CACHE_HANDLER="redis"
CP_REDIS_HOST="redis"

# Media Storage (B2)
CP_MEDIA_BASE_URL="https://media.example.com"
CP_MEDIA_STORAGE_TYPE="s3"
CP_MEDIA_S3_ENDPOINT="https://s3.us-west-004.backblazeb2.com"
CP_MEDIA_S3_KEY="<your-b2-key-id>"
CP_MEDIA_S3_SECRET="<your-b2-app-key>"
CP_MEDIA_S3_BUCKET="podcast-media"
```

### Generated .env (Linode-Only Mode)

```bash
# Castopod Configuration
CP_BASEURL="https://podcast.example.com"
CP_ADMIN_GATEWAY="admin"
CP_AUTH_GATEWAY="auth"

# Database
CP_DATABASE_HOSTNAME="mariadb"
CP_DATABASE_NAME="castopod"
CP_DATABASE_USERNAME="castopod"
CP_DATABASE_PASSWORD="<generated>"
CP_DATABASE_PREFIX="cp_"

# Cache
CP_CACHE_HANDLER="redis"
CP_REDIS_HOST="redis"

# Media Storage (Local)
CP_MEDIA_BASE_URL="https://podcast.example.com"
CP_MEDIA_STORAGE_TYPE="local"
```

### Generated docker-compose.yml

```yaml
services:
  castopod:
    image: castopod/castopod:latest
    container_name: castopod
    volumes:
      - castopod-media:/var/www/castopod/public/media
    environment:
      - CP_BASEURL=${CP_BASEURL}
    depends_on:
      - mariadb
      - redis

  mariadb:
    image: mariadb:10.11
    container_name: castopod-mariadb
    volumes:
      - castopod-db:/var/lib/mysql
    environment:
      - MYSQL_ROOT_PASSWORD=${CP_DATABASE_PASSWORD}

  redis:
    image: redis:7-alpine
    container_name: castopod-redis

  caddy:
    image: caddy:2-alpine
    container_name: castopod-caddy
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - caddy-data:/data
      - caddy-config:/config
```

## Deployment Modes

### Full Mode (Default)

**Infrastructure:**
- Linode VPS (Nanode 1GB recommended, ~$5/month)
- Backblaze B2 bucket (free tier: 10GB storage, 1GB download/day)
- Cloudflare DNS (free tier)

**Advantages:**
- Scalable media storage
- CDN for media delivery
- Lower VPS costs (no media storage)
- Cloudflare DDoS protection

**Best For:**
- Podcasts with large media files
- High download traffic
- Multiple podcasts
- Long-term growth

### Linode-Only Mode

**Infrastructure:**
- Linode VPS (larger instance recommended for media storage)
- Linode DNS (included with Linode account)
- Local VPS storage for media files

**Advantages:**
- Simpler setup (one provider)
- No external dependencies
- Faster initial deployment
- Lower complexity

**Best For:**
- Small podcasts (<10GB media)
- Low-moderate traffic
- Simplified infrastructure
- Testing and evaluation

**Considerations:**
- Media files stored on VPS (larger instance may be needed)
- No CDN for media delivery
- VPS backups should include media files

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Command completed successfully |
| 1 | Prerequisites not met |
| 1 | Infrastructure creation failed |
| 1 | Deployment failed |
| 1 | Invalid domain format |
| 0 | Status check passed |
| 1 | Status check failed |

## Output

### Setup Success

```
================================================================================
NWP Podcast Setup
================================================================================
Domain: podcast.example.com
Linode Region: us-east
Mode: Full (Cloudflare + B2)

✓ All prerequisites met

[1/4] Creating B2 Bucket
  ✓ Bucket created: podcast-media (abc123)
  ✓ CORS enabled
  ✓ Application key created

[2/4] Creating Linode Instance
  ✓ Instance created: 12345678 (label: podcast-example-20241231)
  ✓ Instance IP: 192.0.2.100
  ✓ SSH ready

[3/4] Creating Cloudflare DNS Records
  ✓ DNS: podcast.example.com -> 192.0.2.100
  ✓ DNS: media.example.com -> 192.0.2.100

[4/4] Generating and Deploying Configuration
  ✓ Generated .env
  ✓ Generated docker-compose.yml
  ✓ Generated Caddyfile
  ✓ Deployed to server
  ✓ Castopod started

================================================================================
Setup Complete!
================================================================================

Your podcast infrastructure is ready!

Server: 192.0.2.100
Domain: https://podcast.example.com
Media:  https://media.example.com

SSH Access:
  ssh -i /home/rob/.ssh/nwp root@192.0.2.100

Complete Castopod setup at:
  https://podcast.example.com/admin/install

Configuration saved to: podcast-setup-20241231-120000

⚠ DNS propagation may take a few minutes.
⚠ Save deployment-info.txt for teardown reference.
```

### Linode-Only Setup Success

```
================================================================================
NWP Podcast Setup
================================================================================
Domain: podcast.example.com
Linode Region: us-east
Mode: Linode-only (Linode DNS + local storage)

✓ All prerequisites met

[1/3] Skipping B2 (using local storage)
  ✓ Using local storage on VPS instead of B2

[2/3] Creating Linode Instance
  ✓ Instance created: 12345678 (label: podcast-example-20241231)
  ✓ Instance IP: 192.0.2.100
  ✓ SSH ready

[3/3] Creating Linode DNS Records
  ✓ DNS: podcast.example.com -> 192.0.2.100

[4/4] Generating and Deploying Configuration
  ✓ Generated .env (local storage)
  ✓ Generated docker-compose.yml
  ✓ Generated Caddyfile
  ✓ Deployed to server
  ✓ Castopod started

================================================================================
Setup Complete!
================================================================================

Your podcast infrastructure is ready!

Server: 192.0.2.100
Domain: https://podcast.example.com
Storage: Local (on VPS)

SSH Access:
  ssh -i /home/rob/.ssh/nwp root@192.0.2.100

Complete Castopod setup at:
  https://podcast.example.com/admin/install
```

## Post-Setup Steps

After successful deployment:

### 1. Complete Castopod Installation

Visit `https://podcast.example.com/admin/install` and:
1. Create admin account
2. Configure podcast settings
3. Set up podcast metadata

### 2. Upload Podcast Content

1. Log in to Castopod admin
2. Create a podcast show
3. Upload episodes
4. Configure RSS feed

### 3. Configure DNS (if needed)

For custom domains not managed by Cloudflare/Linode:
1. Point A record to server IP
2. Wait for DNS propagation
3. Verify HTTPS certificate generation

### 4. Backup Configuration

Save the generated deployment directory:
```bash
tar -czf podcast-backup.tar.gz podcast-setup-20241231-120000/
```

## Troubleshooting

### B2 Authentication Failed

**Symptom:**
```
b2 CLI not authenticated (run: b2 account authorize)
```

**Solution:**
```bash
pip install b2
b2 account authorize
# Enter B2 account ID and application key when prompted
```

### Linode API Token Invalid

**Symptom:**
```
API token may be invalid
```

**Solution:**
1. Generate new token: https://cloud.linode.com/profile/tokens
2. Update .secrets.yml
3. Ensure token has permissions: Domains (Read/Write), Linodes (Read/Write)

### DNS Not Propagating

**Symptom:** Domain not resolving after 10+ minutes

**Solution:**
```bash
# Check DNS propagation
dig podcast.example.com

# If using Cloudflare, check DNS records in dashboard
# If using Linode DNS, verify domain exists in Linode DNS Manager
```

### Docker Not Starting on Server

**Symptom:**
```
Container castopod is not running
```

**Solution:**
```bash
# SSH to server
ssh -i ~/.ssh/nwp root@<server-ip>

# Check container logs
cd /root/castopod
docker compose logs castopod

# Restart containers
docker compose restart

# Check for port conflicts
netstat -tuln | grep -E ':(80|443)'
```

### HTTPS Certificate Not Generated

**Symptom:** Site shows "Your connection is not private"

**Solution:**
1. Wait 2-5 minutes for Caddy to generate certificate
2. Check Caddy logs: `docker compose logs caddy`
3. Verify domain points to correct IP: `dig podcast.example.com`
4. Ensure ports 80 and 443 are open in firewall

### Linode DNS Domain Not Found

**Symptom:**
```
Failed to create DNS record for podcast.example.com
Ensure example.com exists in Linode DNS Manager
```

**Solution:**
1. Create base domain in Linode: https://cloud.linode.com/domains
2. Add domain: `example.com`
3. Run setup again

## Cost Estimates

### Full Mode (Cloudflare + B2)

| Component | Cost |
|-----------|------|
| Linode Nanode 1GB | $5/month |
| Backblaze B2 (10GB storage) | Free tier |
| Backblaze B2 (1GB download/day) | Free tier |
| Cloudflare DNS | Free tier |
| **Total** | **~$5/month** |

### Linode-Only Mode

| Component | Cost |
|-----------|------|
| Linode 2GB (for media storage) | $12/month |
| Linode DNS | Included |
| **Total** | **~$12/month** |

### Cost Optimization Tips

**Full Mode:**
- Use B2 free tier (10GB storage, 1GB download/day)
- Start with Nanode, upgrade if needed
- Monitor B2 usage to stay within free tier

**Linode-Only Mode:**
- Start with smaller instance, monitor disk usage
- Use compression for media files
- Archive old episodes to reduce storage

## Security Considerations

### SSH Access
- Uses SSH keys (not passwords)
- Keys stored in `keys/nwp` or `~/.ssh/nwp`
- Root access only (configure sudo users as needed)

### Secrets Management
- B2 credentials stored in `.env` on server
- `.secrets.yml` contains API tokens (never commit to git)
- Database password auto-generated (24 characters)

### HTTPS
- Automatic via Caddy and Let's Encrypt
- Forces HTTPS for all connections
- Auto-renewal of certificates

### Backblaze B2
- Public bucket for podcast media
- Application key limited to single bucket
- CORS enabled for web players

## Automation

### Scheduled Backups

Add to server crontab:
```bash
0 2 * * * docker exec castopod-mariadb mysqldump -u root -p${CP_DATABASE_PASSWORD} castopod | gzip > /backup/castopod-$(date +\%Y\%m\%d).sql.gz
```

### Monitoring

Check site availability:
```bash
*/5 * * * * curl -f https://podcast.example.com || mail -s "Podcast Site Down" admin@example.com
```

## Related Commands

- [setup-ssh](../../../setup-ssh.sh) - Generate SSH keys for server access
- Podcast library: `/home/rob/nwp/lib/podcast.sh`
- Linode library: `/home/rob/nwp/lib/linode.sh`
- Cloudflare library: `/home/rob/nwp/lib/cloudflare.sh`
- B2 library: `/home/rob/nwp/lib/b2.sh`

## See Also

- Castopod Documentation: https://docs.castopod.org/
- Linode VPS: https://www.linode.com/
- Backblaze B2: https://www.backblaze.com/b2/cloud-storage.html
- Cloudflare DNS: https://www.cloudflare.com/dns/
- Caddy Web Server: https://caddyserver.com/
- Docker Compose: https://docs.docker.com/compose/
