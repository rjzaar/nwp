# Linode Deployment Infrastructure

**Status:** Implementation Guide (Complete)
**Created:** 2024-12-23
**Updated:** January 2026

> This infrastructure has been implemented. See `linode/` directory for scripts
> and `lib/linode.sh` for API functions.

---

## Table of Contents

- [Executive Summary](#executive-summary)
- [Architecture Overview](#architecture-overview)
- [Linode CLI Integration](#linode-cli-integration)
- [Server Provisioning Strategy](#server-provisioning-strategy)
- [Deployment Workflow](#deployment-workflow)
- [Staged Implementation Plan](#staged-implementation-plan)
- [Script Specifications](#script-specifications)
- [Configuration Management](#configuration-management)
- [Security Considerations](#security-considerations)
- [Testing Strategy](#testing-strategy)
- [References](#references)

---

## Executive Summary

### Purpose

This document proposes a comprehensive Linode-based deployment infrastructure for NWP (Narrow Way Project) that enables:

1. **Automated Server Provisioning** - Create and configure Linode instances via CLI
2. **Live Testing Environment** - Deploy OpenSocial sites to real production-like servers
3. **Production Deployment** - Push local/staging sites to production on Linode
4. **Blue-Green Deployment** - Zero-downtime deployment using directory swapping
5. **Backup & Restore** - Remote backup and restoration capabilities

### Key Benefits

- ✅ **Cost-Effective Testing** - Spin up test servers on-demand, destroy when done
- ✅ **Production-Ready** - Test on identical infrastructure before going live
- ✅ **Automated Provisioning** - No manual server configuration required
- ✅ **Security Hardened** - SSH keys, firewalls, SSL/TLS out of the box
- ✅ **Drupal Optimized** - Pre-configured for OpenSocial/Drupal sites

### Approach

The implementation adapts the proven [Pleasy server scripts](https://github.com/rjzaar/pleasy/tree/master/server) approach, modernizing it for:
- DDEV-based local development (vs traditional LAMP)
- Linode infrastructure (vs DigitalOcean)
- OpenSocial distribution (vs generic Drupal)
- NWP tooling integration

---

## Architecture Overview

### Three-Tier Environment Model

```
┌─────────────────────────────────────────────────────────────┐
│                    LOCAL DEVELOPMENT                         │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  DDEV Container (nwp4, nwp4_stg, nwp4_prod)         │   │
│  │  - Development mode                                  │   │
│  │  - Full dev dependencies                            │   │
│  │  - Testing via testos.sh                            │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
                              ↓
                    ./linode-deploy.sh --test
                              ↓
┌─────────────────────────────────────────────────────────────┐
│                LINODE TEST/STAGING SERVER                    │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  Ubuntu 24.04 + Nginx + PHP 8.2 + MariaDB          │   │
│  │  - Production-like environment                      │   │
│  │  - Live URL testing                                 │   │
│  │  - Performance testing                              │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
                              ↓
                    ./linode-deploy.sh --prod
                              ↓
┌─────────────────────────────────────────────────────────────┐
│                  LINODE PRODUCTION SERVER                    │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  Ubuntu 24.04 + Nginx + PHP 8.2 + MariaDB          │   │
│  │  - Blue-green deployment ready                      │   │
│  │  - SSL/TLS via Let's Encrypt                        │   │
│  │  - Automated backups                                │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### Component Breakdown

| Component | Technology | Purpose |
|-----------|-----------|---------|
| **Local Dev** | DDEV + Docker | Development and testing |
| **Provisioning** | Linode CLI | Server creation and management |
| **Web Server** | Nginx | HTTP server and reverse proxy |
| **Database** | MariaDB 10.11+ | Database server |
| **PHP Runtime** | PHP 8.2-FPM | Application server |
| **SSL/TLS** | Let's Encrypt (Certbot) | Certificate management |
| **Security** | UFW + SSH Keys | Firewall and authentication |
| **Deployment** | Custom Bash Scripts | Automation layer |

---

## Linode CLI Integration

### Installation & Configuration

**Prerequisites:**
```bash
# Install Linode CLI
pip3 install linode-cli

# Configure with API token
linode-cli configure
# Enter API token when prompted
# Set default region (e.g., us-east)
# Set default image (e.g., linode/ubuntu24.04)
# Set default type (e.g., g6-standard-2)
```

**API Token Setup:**
1. Log into Linode Cloud Manager: https://cloud.linode.com/
2. Navigate to: Profile → API Tokens → Create Personal Access Token
3. Grant required permissions: `linodes:read_write`, `stackscripts:read_write`, `images:read_write`
4. Save token securely (it won't be shown again)

### Key CLI Commands

**List available plans/types:**
```bash
linode-cli linodes types
```

**List available regions:**
```bash
linode-cli regions list
```

**List available images:**
```bash
linode-cli images list
```

**Create a new Linode:**
```bash
linode-cli linodes create \
  --label "nwp-test-server" \
  --region us-east \
  --type g6-standard-2 \
  --image linode/ubuntu24.04 \
  --root_pass "SecurePassword123!" \
  --authorized_keys "$(cat ~/.ssh/id_rsa.pub)" \
  --stackscript_id <stackscript_id> \
  --stackscript_data '{"hostname":"test.example.com","email":"admin@example.com"}'
```

**List Linodes:**
```bash
linode-cli linodes list
```

**Delete a Linode:**
```bash
linode-cli linodes delete <linode_id>
```

### StackScript Approach

**What are StackScripts?**
- Bash scripts that run during Linode provisioning
- Automate server setup (users, packages, configuration)
- Support User Defined Fields (UDF) for parameterization

**NWP StackScript Structure:**
```bash
#!/bin/bash
# <UDF name="hostname" label="Server Hostname" />
# <UDF name="email" label="Admin Email" />
# <UDF name="ssh_user" label="SSH Username" default="nwpadmin" />

# System updates
apt-get update && apt-get upgrade -y

# Install base packages
apt-get install -y nginx mariadb-server php8.2-fpm php8.2-mysql \
  php8.2-gd php8.2-xml php8.2-mbstring php8.2-curl certbot \
  python3-certbot-nginx git unzip

# Configure firewall
ufw allow OpenSSH
ufw allow 'Nginx Full'
ufw --force enable

# Create admin user
useradd -m -s /bin/bash -G sudo $SSH_USER
mkdir -p /home/$SSH_USER/.ssh
# ... (additional setup)
```

---

## Server Provisioning Strategy

### Adapted from Pleasy Architecture

The [Pleasy server scripts](https://github.com/rjzaar/pleasy/tree/master/server) provide a proven foundation:

**Original Pleasy Approach:**
- `initserverroot.sh` - Root-level server initialization
- `initserver.sh` - User-level setup
- `createsite.sh` - Site provisioning
- `updateprod.sh` - Blue-green deployment

**NWP Adaptations:**

| Pleasy Script | NWP Equivalent | Key Changes |
|--------------|----------------|-------------|
| `initserverroot.sh` | StackScript | Runs during Linode provisioning |
| `initserver.sh` | `linode-init.sh` | Executed via SSH after provisioning |
| `createsite.sh` | `linode-createsite.sh` | OpenSocial-specific configuration |
| `updateprod.sh` | `linode-deploy.sh` | Integrated with NWP tools |

### Two-Phase Provisioning

**Phase 1: Linode Creation (Automated)**
```bash
./linode-provision.sh \
  --label nwp-test-01 \
  --plan g6-standard-2 \
  --region us-east \
  --domain test.example.com
```

This script:
1. Creates Linode instance via CLI
2. Applies NWP StackScript for base configuration
3. Waits for instance to boot
4. Retrieves IP address
5. Configures DNS (optional)

**Phase 2: Site Deployment (Automated)**
```bash
./linode-deploy.sh \
  --source nwp4_stg \
  --target test.example.com \
  --type test
```

This script:
1. Exports site from local DDEV
2. Transfers files to Linode via rsync
3. Configures Nginx virtual host
4. Creates database and imports data
5. Configures SSL/TLS certificate
6. Runs Drupal updates
7. Clears cache

---

## Deployment Workflow

### Local to Test Server

```bash
# Step 1: Provision test server (one-time)
./linode-provision.sh --label nwp-test --domain test.nwp.org

# Step 2: Deploy local staging to test server
./linode-deploy.sh --source nwp4_stg --target test.nwp.org --type test

# Step 3: Test on live server
# Visit https://test.nwp.org
# Run tests: ./testos.sh -b test.nwp.org (if configured for remote)

# Step 4: Destroy test server when done (optional)
./linode-destroy.sh --label nwp-test
```

### Test to Production (Blue-Green)

```bash
# Prepare production directories on Linode server
/var/www/
├── prod/              # Current production (main)
├── test/              # Staging/test environment
└── old/               # Previous production (rollback)

# Deploy sequence
./linode-deploy.sh --source nwp4_prod --target prod.nwp.org --type prod

# Behind the scenes:
# 1. Updates test/ directory with new code
# 2. Runs database updates in test/
# 3. Tests basic functionality
# 4. Swaps: prod → old, test → prod, old → test
# 5. Swaps settings.php files to match environments
# 6. Updates file permissions

# Rollback if needed (within 24 hours)
./linode-rollback.sh --target prod.nwp.org
```

### Directory Swap Mechanism

```bash
# Before swap
/var/www/prod/     → Live site (v1.0)
/var/www/test/     → Updated site (v1.1)

# Atomic swap operation (from updateprod.sh pattern)
mv /var/www/prod /var/www/old
mv /var/www/test /var/www/prod
mv /var/www/old /var/www/test

# After swap
/var/www/prod/     → Live site (v1.1) ✨ NEW
/var/www/test/     → Previous version (v1.0)
```

**Benefits:**
- Zero downtime (Nginx serves from directory name, swap is atomic)
- Instant rollback available (reverse the swap)
- Previous version ready for testing/comparison

---

## Staged Implementation Plan

### Phase 1: Foundation (Week 1-2)

**Goal:** Basic Linode provisioning working

**Tasks:**
- [x] Research Linode CLI capabilities ✅
- [x] Analyze Pleasy server scripts ✅
- [ ] Install and configure Linode CLI locally
- [ ] Create NWP StackScript for base server setup
- [ ] Create `linode-provision.sh` script
- [ ] Test: Provision a basic Ubuntu server
- [ ] Test: SSH access with key authentication
- [ ] Document Linode API token setup

**Deliverables:**
- `server/stackscript.sh` - Linode StackScript for server initialization
- `linode-provision.sh` - CLI wrapper for creating Linodes
- `docs/LINODE_SETUP.md` - Setup and configuration guide

**Success Criteria:**
- Can create a Linode server with one command
- Server is accessible via SSH with keys
- Basic security hardening applied (firewall, user accounts)

---

### Phase 2: Server Configuration (Week 2-3)

**Goal:** LEMP stack configured and ready for Drupal

**Tasks:**
- [ ] Create `linode-init.sh` - Post-provisioning configuration
- [ ] Install and configure Nginx
- [ ] Install and configure MariaDB
- [ ] Install and configure PHP 8.2-FPM
- [ ] Configure PHP for Drupal (memory, upload limits, etc.)
- [ ] Install Certbot for SSL/TLS
- [ ] Create database initialization script
- [ ] Test: Serve a basic PHP site

**Deliverables:**
- `server/linode-init.sh` - Server initialization script
- `server/nginx-site.conf.template` - Nginx virtual host template
- `server/php.ini.template` - PHP configuration template

**Success Criteria:**
- LEMP stack running and functional
- Can create virtual hosts dynamically
- PHP meets Drupal system requirements
- SSL certificates can be obtained

---

### Phase 3: Site Deployment (Week 3-4)

**Goal:** Deploy OpenSocial sites from local to Linode

**Tasks:**
- [ ] Create `linode-createsite.sh` - OpenSocial site setup
- [ ] Implement database export from DDEV
- [ ] Implement file transfer via rsync
- [ ] Configure Nginx for Drupal (clean URLs, security)
- [ ] Generate settings.php with correct credentials
- [ ] Implement database import on remote
- [ ] Configure file permissions correctly
- [ ] Test: Deploy nwp4_stg to test server

**Deliverables:**
- `linode-createsite.sh` - Site creation on Linode
- `linode-deploy.sh` - Full deployment script
- `templates/settings.php.template` - Drupal settings template

**Success Criteria:**
- Can deploy a site from DDEV to Linode with one command
- Site is accessible and functional
- Database is imported correctly
- Files have correct permissions

---

### Phase 4: Production Deployment (Week 4-5)

**Goal:** Blue-green deployment to production

**Tasks:**
- [ ] Implement directory structure (prod/test/old)
- [ ] Create `linode-swap.sh` - Blue-green swap logic
- [ ] Implement settings.php swapping
- [ ] Create pre-deployment validation
- [ ] Create post-deployment verification
- [ ] Implement rollback mechanism
- [ ] Add deployment logging
- [ ] Test: Full deployment cycle with rollback

**Deliverables:**
- `linode-swap.sh` - Directory swap implementation
- `linode-rollback.sh` - Rollback script
- `linode-verify.sh` - Deployment verification

**Success Criteria:**
- Zero-downtime deployment working
- Rollback mechanism tested and functional
- Logs capture deployment history
- Can deploy to production safely

---

### Phase 5: Backup & Recovery (Week 5-6)

**Goal:** Remote backup and restoration

**Tasks:**
- [ ] Create `linode-backup.sh` - Remote site backup
- [ ] Implement database backup via mysqldump
- [ ] Implement file backup via rsync/tar
- [ ] Create backup rotation (keep last N backups)
- [ ] Create `linode-restore.sh` - Restore from backup
- [ ] Integrate with existing NWP backup scripts
- [ ] Test: Full backup and restore cycle

**Deliverables:**
- `linode-backup.sh` - Remote backup script
- `linode-restore.sh` - Remote restore script
- Integration with `backup.sh` and `restore.sh`

**Success Criteria:**
- Can backup production sites on Linode
- Can restore from backup
- Backups stored locally and/or in Linode Backups service
- Integration with NWP backup workflow

---

### Phase 6: Integration & Polish (Week 6-7)

**Goal:** Integrate with existing NWP tools

**Tasks:**
- [ ] Update `nwp.yml` recipe format for Linode config
- [ ] Integrate with `dev2stg.sh` workflow
- [ ] Add Linode deployment to `make.sh` production mode
- [ ] Create `linode-list.sh` - List and manage Linodes
- [ ] Create `linode-destroy.sh` - Clean up servers
- [ ] Add verbose/debug modes to all scripts
- [ ] Comprehensive error handling
- [ ] Update documentation

**Deliverables:**
- Updated `nwp.yml` schema
- Integration with existing NWP scripts
- `linode-list.sh` and `linode-destroy.sh`
- Updated documentation

**Success Criteria:**
- Linode deployment feels like native NWP workflow
- All scripts follow NWP conventions
- Comprehensive documentation complete
- Ready for production use

---

### Phase 7: Advanced Features (Future)

**Goal:** Production-grade features

**Tasks:**
- [ ] Multi-site support (multiple sites on one Linode)
- [ ] Automated SSL renewal via cron
- [ ] Monitoring and alerting integration
- [ ] Performance optimization (OpCache, Redis)
- [ ] CDN integration (Cloudflare)
- [ ] Database replication for high availability
- [ ] Load balancing for high traffic
- [ ] Automated scaling based on load

---

## Script Specifications

### 1. linode-provision.sh

**Purpose:** Create and initialize a Linode server

**Usage:**
```bash
./linode-provision.sh [OPTIONS]

Options:
  --label NAME          Server label (e.g., nwp-test-01)
  --plan TYPE          Linode plan (default: g6-standard-2)
  --region REGION      Region (default: us-east)
  --domain FQDN        Domain name for the server
  --stackscript ID     Custom StackScript ID (optional)
  -y, --yes            Auto-confirm all prompts
  -v, --verbose        Verbose output
  -h, --help           Show help message
```

**Key Operations:**
1. Validate Linode CLI is installed and configured
2. Check if label already exists
3. Create Linode instance with StackScript
4. Wait for instance to boot (polls status)
5. Retrieve and display IP address
6. Test SSH connectivity
7. Save server details to `~/.nwp/linode-servers.json`
8. Display next steps

**Example:**
```bash
./linode-provision.sh \
  --label nwp-test-01 \
  --plan g6-standard-2 \
  --region us-east \
  --domain test.nwp.org
```

**Output:**
```
Creating Linode instance...
✓ Linode created (ID: 12345678)
✓ Waiting for boot... (30s)
✓ Server is running
✓ IP Address: 192.0.2.100
✓ SSH access confirmed

Next steps:
  1. Configure DNS: test.nwp.org → 192.0.2.100
  2. Deploy site: ./linode-deploy.sh --target test.nwp.org
```

---

### 2. linode-deploy.sh

**Purpose:** Deploy a site from local DDEV to Linode

**Usage:**
```bash
./linode-deploy.sh [OPTIONS] SOURCE TARGET

Arguments:
  SOURCE               Local DDEV site name (e.g., nwp4_stg)
  TARGET               Target domain on Linode (e.g., test.nwp.org)

Options:
  --type TYPE          Deployment type: test|prod (default: test)
  --skip-db            Skip database export/import
  --skip-files         Skip file transfer
  --skip-ssl           Skip SSL certificate setup
  -y, --yes            Auto-confirm all prompts
  -v, --verbose        Verbose output
  -h, --help           Show help message
```

**Key Operations:**
1. Validate source DDEV site exists
2. Validate target server is reachable
3. Export database from DDEV
4. Create tar archive of files
5. Transfer to Linode via rsync
6. Create/update Nginx virtual host
7. Create database and user on remote
8. Import database
9. Extract files
10. Generate settings.php
11. Set file permissions
12. Obtain SSL certificate (if requested)
13. Run Drupal updates (drush updb, cr)
14. Display site URL

**Example:**
```bash
./linode-deploy.sh nwp4_stg test.nwp.org --type test
```

---

### 3. linode-swap.sh

**Purpose:** Blue-green deployment swap

**Usage:**
```bash
./linode-swap.sh [OPTIONS] TARGET

Arguments:
  TARGET               Target domain (e.g., prod.nwp.org)

Options:
  --verify             Run verification checks before swap
  --no-backup          Skip backup before swap
  -y, --yes            Auto-confirm swap
  -v, --verbose        Verbose output
  -h, --help           Show help message
```

**Key Operations:**
1. Validate directories exist (prod, test)
2. Run pre-swap verification (test site works)
3. Create backup of current prod (optional)
4. Put site in maintenance mode
5. Perform atomic directory swap
6. Swap settings.php files
7. Clear caches
8. Run post-swap verification
9. Take site out of maintenance mode
10. Log deployment

**Example:**
```bash
./linode-swap.sh prod.nwp.org --verify
```

---

### 4. linode-rollback.sh

**Purpose:** Rollback to previous deployment

**Usage:**
```bash
./linode-rollback.sh [OPTIONS] TARGET

Arguments:
  TARGET               Target domain (e.g., prod.nwp.org)

Options:
  -y, --yes            Auto-confirm rollback
  -v, --verbose        Verbose output
  -h, --help           Show help message
```

**Key Operations:**
1. Verify test directory contains previous version
2. Put site in maintenance mode
3. Reverse the directory swap (test → prod)
4. Reverse settings.php swap
5. Clear caches
6. Verify site is working
7. Take site out of maintenance mode
8. Log rollback

---

### 5. linode-backup.sh

**Purpose:** Backup a remote Linode site

**Usage:**
```bash
./linode-backup.sh [OPTIONS] TARGET

Arguments:
  TARGET               Target domain (e.g., prod.nwp.org)

Options:
  -b, --db-only        Database only (skip files)
  -m, --message MSG    Backup message/description
  -y, --yes            Auto-confirm
  -v, --verbose        Verbose output
  -h, --help           Show help message
```

**Key Operations:**
1. Connect to Linode via SSH
2. Export database via mysqldump
3. Create tar archive of files (if not db-only)
4. Compress with gzip
5. Transfer to local machine via rsync
6. Store in `sitebackups/<sitename>/`
7. Display backup info (size, location)

---

## Configuration Management

### linode.yml Configuration File

**Location:** `~/.nwp/linode.yml`

**Structure:**
```yaml
# Linode API Configuration
api:
  token: "your-api-token-here"
  default_region: "us-east"
  default_plan: "g6-standard-2"
  default_image: "linode/ubuntu24.04"

# Server Defaults
server:
  ssh_user: "nwpadmin"
  ssh_port: 22
  timezone: "America/New_York"

# Email for SSL certificates
email: "admin@example.com"

# Deployment Settings
deployment:
  backup_before_deploy: true
  verify_before_swap: true
  maintenance_mode: true

# Backup Settings
backup:
  retention_days: 30
  compression: "gzip"
  remote_path: "/var/backups/nwp"
  local_path: "~/sitebackups/linode"

# Servers (managed by scripts)
servers:
  - label: "nwp-test-01"
    ip: "192.0.2.100"
    domain: "test.nwp.org"
    type: "test"
    created: "2024-12-23"

  - label: "nwp-prod-01"
    ip: "192.0.2.101"
    domain: "prod.nwp.org"
    type: "prod"
    created: "2024-12-23"
```

### Integration with nwp.yml

**Extended recipe configuration:**
```yaml
name: "My OpenSocial Site"
recipe: "social"
version: "12.3.2"

# Existing configuration...
dev_modules:
  - devel
  - webprofiler

# NEW: Linode deployment configuration
linode:
  enabled: true
  test_server: "test.nwp.org"
  prod_server: "prod.nwp.org"
  deployment_method: "blue-green"
  auto_backup: true
```

---

## Security Considerations

### Authentication

**SSH Key Management:**
- Only SSH key authentication allowed (no passwords)
- Keys managed via `~/.ssh/config`
- Different keys for test vs production (optional)

**Example ~/.ssh/config:**
```
Host nwp-test
    HostName test.nwp.org
    User nwpadmin
    IdentityFile ~/.ssh/nwp_test_rsa

Host nwp-prod
    HostName prod.nwp.org
    User nwpadmin
    IdentityFile ~/.ssh/nwp_prod_rsa
```

### Firewall Rules

**UFW Configuration (via StackScript):**
```bash
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw allow 'Nginx Full'
ufw --force enable
```

### SSL/TLS Certificates

**Let's Encrypt via Certbot:**
```bash
certbot --nginx -d example.com -d www.example.com \
  --non-interactive --agree-tos --email admin@example.com
```

**Auto-renewal via cron:**
```cron
0 0,12 * * * certbot renew --quiet
```

### Database Security

- Root access disabled remotely
- Unique database credentials per site
- Random 32-character passwords generated
- Credentials stored in settings.php (not in repo)

### File Permissions

```bash
# Web root
chown -R www-data:www-data /var/www/prod
find /var/www/prod -type d -exec chmod 755 {} \;
find /var/www/prod -type f -exec chmod 644 {} \;

# Settings files
chmod 440 /var/www/prod/sites/*/settings.php
```

---

## Testing Strategy

### Local Testing (Phase 1-3)

**Before Linode deployment:**
```bash
# Test locally with DDEV
cd nwp4_stg
ddev start

# Run all tests
./testos.sh -a nwp4_stg

# Export and verify
ddev export-db --file=test.sql
tar -czf test-files.tar.gz html/

# Verify archives
gunzip -t test.sql.gz
tar -tzf test-files.tar.gz | head
```

### Remote Testing (Phase 4-5)

**On Linode test server:**
```bash
# Deploy to test server
./linode-deploy.sh nwp4_stg test.nwp.org --type test

# SSH to server and verify
ssh nwp-test
cd /var/www/prod
drush status
drush cst  # Configuration status
exit

# Run remote tests (if configured)
./testos.sh -b -f login test.nwp.org
```

### Production Testing (Phase 6+)

**Blue-green deployment test:**
```bash
# 1. Deploy to test directory
./linode-deploy.sh nwp4_prod prod.nwp.org --type test

# 2. Verify test works (manual testing)
curl -I https://prod.nwp.org/test/

# 3. Perform swap
./linode-swap.sh prod.nwp.org --verify

# 4. Verify production
curl -I https://prod.nwp.org/

# 5. Test rollback
./linode-rollback.sh prod.nwp.org

# 6. Verify rollback worked
curl -I https://prod.nwp.org/
```

---

## References

### Documentation Sources

- **Linode CLI Documentation**: [Official Linode CLI Guide](https://www.linode.com/docs/products/tools/cli/guides/linode-instances/)
- **Linode CLI GitHub**: [linode/linode-cli](https://github.com/linode/linode-cli)
- **Create Linode Instance**: [Linode Instance Creation Guide](https://www.linode.com/docs/products/compute/compute-instances/guides/create/)
- **StackScripts Guide**: [Linode StackScripts Documentation](https://www.linode.com/docs/products/tools/stackscripts/)
- **Pleasy Server Scripts**: [rjzaar/pleasy/server](https://github.com/rjzaar/pleasy/tree/master/server)

### Related NWP Documentation

- **README.md** - Main NWP documentation
- **TESTING.md** - Testing infrastructure
- **ROADMAP.md** - Project roadmap
- **SCRIPTS_IMPLEMENTATION.md** - Script implementation details

### External Tutorials

- DigitalOcean: Initial Server Setup with Ubuntu 20.04
- DigitalOcean: How To Install Nginx on Ubuntu 20.04
- DigitalOcean: How To Install MariaDB on Ubuntu 20.04
- DigitalOcean: How To Secure Nginx with Let's Encrypt on Ubuntu 20.04

---

## Next Steps

1. **Review this proposal** - Provide feedback on approach and scope
2. **Approve Phase 1** - Begin implementation of basic provisioning
3. **Set up Linode account** - Create API token for testing
4. **Install Linode CLI** - Configure local development machine
5. **Create test server** - Provision first Linode for testing

---

## Questions for Discussion

1. **Server Sizing**: What Linode plan should we use for test vs production?
   - Suggested test: `g6-standard-2` (2 GB RAM, 1 CPU, 50 GB storage) - $12/mo
   - Suggested prod: `g6-standard-4` (8 GB RAM, 4 CPU, 160 GB storage) - $48/mo

2. **Region Selection**: Where should servers be located?
   - Suggested: `us-east` (Newark, NJ) for lowest latency to US East Coast

3. **Backup Strategy**: Local only, Linode Backups, or both?
   - Suggested: Both (local backups + Linode Backups service)

4. **SSL Certificates**: Let's Encrypt (free) or commercial?
   - Suggested: Let's Encrypt for testing, optional commercial for production

5. **Deployment Frequency**: How often will production be updated?
   - Influences backup retention and rollback window

---

*Last updated: 2024-12-23*
*Next review: After Phase 1 completion*
