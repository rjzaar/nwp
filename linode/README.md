# NWP Linode Deployment Infrastructure

Complete infrastructure for deploying NWP/OpenSocial sites to Linode cloud servers.

---

## Quick Start

### 1. Initial Setup (One-time)

Set up your local machine for Linode deployment:

```bash
cd linode
./linode_setup.sh
```

This will:
- Install Linode CLI (using pipx for modern Python)
- Configure API authentication
- Generate SSH keys
- Create configuration files

### 2. Upload StackScript

Upload the server provisioning script to Linode:

```bash
./linode_upload_stackscript.sh
```

This creates a StackScript in your Linode account for automated server provisioning.

### 3. Create Your First Server

Provision a test server in ~7 minutes:

```bash
./linode_create_test_server.sh
```

Or create a production server with custom options:

```bash
./linode_create_test_server.sh --type g6-standard-2 --email admin@example.com
```

### 4. Deploy Your Site

Deploy your local DDEV site to the server:

```bash
./linode_deploy.sh --server 45.33.94.133 --target test
```

For production with SSL:

```bash
./linode_deploy.sh --server nwp.org --target prod --ssl
```

---

## Directory Structure

```
linode/
├── README.md                       # This file
├── .gitignore                      # Protects SSH keys and sensitive files
│
├── linode_setup.sh                 # Local environment setup
├── linode_server_setup.sh          # Server provisioning StackScript
├── linode_upload_stackscript.sh    # Upload StackScript to Linode
├── linode_create_test_server.sh    # Create test servers
├── linode_deploy.sh                # Deploy DDEV site to server
├── validate_stackscript.sh         # Validate StackScript before upload
│
├── docs/
│   ├── SETUP_GUIDE.md              # Complete setup guide
│   └── TESTING_RESULTS.md          # Testing documentation and lessons learned
│
├── keys/
│   └── (SSH keys stored here - ignored by Git)
│
└── server_scripts/                 # Scripts that run ON the Linode server
    ├── README.md                   # Server scripts documentation
    ├── nwp-createsite.sh           # Create new site on server
    ├── nwp-swap-prod.sh            # Blue-green deployment
    ├── nwp-rollback.sh             # Rollback deployment
    └── nwp-backup.sh               # Backup site
```

---

## Scripts Overview

### Local Scripts (Run on your machine)

| Script | Purpose | Usage |
|--------|---------|-------|
| **linode_setup.sh** | Set up local environment for Linode | `./linode_setup.sh` |
| **linode_server_setup.sh** | Server provisioning StackScript | Upload to Linode as StackScript |
| **linode_upload_stackscript.sh** | Upload/update StackScript to Linode | `./linode_upload_stackscript.sh` |
| **linode_create_test_server.sh** | Create test server with one command | `./linode_create_test_server.sh` |
| **linode_deploy.sh** | Deploy DDEV site to Linode server | `./linode_deploy.sh --server IP` |
| **validate_stackscript.sh** | Validate StackScript before upload | `./validate_stackscript.sh FILE` |

### Server Scripts (Run on Linode server)

| Script | Purpose | Usage |
|--------|---------|-------|
| **nwp-createsite.sh** | Create site with DB and Nginx | `./nwp-createsite.sh example.com` |
| **nwp-swap-prod.sh** | Zero-downtime deployment | `./nwp-swap-prod.sh` |
| **nwp-rollback.sh** | Rollback to previous version | `./nwp-rollback.sh` |
| **nwp-backup.sh** | Backup database and files | `./nwp-backup.sh` |

---

## Deployment Architecture

### Three-Tier Environment Model

```
┌─────────────────────────────────────────────────────────────┐
│                    LOCAL DEVELOPMENT                         │
│  DDEV Container (nwp4, nwp4_stg, nwp4_prod)                 │
└─────────────────────────────────────────────────────────────┘
                         ↓
              (Future: linode_deploy.sh)
                         ↓
┌─────────────────────────────────────────────────────────────┐
│                LINODE TEST/STAGING SERVER                    │
│  Ubuntu 24.04 + Nginx + PHP 8.2 + MariaDB                  │
└─────────────────────────────────────────────────────────────┘
                         ↓
              (nwp-swap-prod.sh on server)
                         ↓
┌─────────────────────────────────────────────────────────────┐
│                  LINODE PRODUCTION SERVER                    │
│  Blue-green deployment ready                                │
└─────────────────────────────────────────────────────────────┘
```

### Blue-Green Deployment

The server uses a three-directory structure for zero-downtime deployments:

```
/var/www/
├── prod/    # Current production (what users see)
├── test/    # Staging/next version
└── old/     # Previous production (for rollback)
```

**Deployment flow:**
1. Deploy new version to `test/`
2. Verify it works
3. Atomic swap: `test` → `prod`, `prod` → `old`
4. Rollback available instantly if needed

---

## Security Features

### SSH Security
- ✅ SSH key authentication only (passwords disabled)
- ✅ Root login disabled via SSH
- ✅ Non-root user (`nwp`) with sudo privileges
- ✅ Separate keys for test vs production (recommended)

### Server Hardening
- ✅ UFW firewall (only SSH, HTTP, HTTPS allowed)
- ✅ Automatic security updates
- ✅ Secure database configuration
- ✅ File permissions hardening

### SSL/TLS
- ✅ Let's Encrypt integration (free SSL certificates)
- ✅ Automatic certificate renewal
- ✅ HTTPS by default in production

---

## Documentation

### Main Guides
- **[docs/SETUP_GUIDE.md](docs/SETUP_GUIDE.md)** - Complete setup walkthrough
- **[../docs/LINODE_DEPLOYMENT.md](../docs/LINODE_DEPLOYMENT.md)** - Full architecture documentation
- **[server_scripts/README.md](server_scripts/README.md)** - Server scripts reference

### External References
- [Linode CLI Documentation](https://www.linode.com/docs/products/tools/cli/)
- [Linode StackScripts Guide](https://www.linode.com/docs/products/tools/stackscripts/)
- [DigitalOcean Server Setup Tutorial](https://www.digitalocean.com/community/tutorials/initial-server-setup-with-ubuntu-20-04)
- [Pleasy Server Scripts](https://github.com/rjzaar/pleasy/tree/master/server) (inspiration)

---

## Workflow Examples

### Creating a Test Server

```bash
# 1. Upload StackScript (one-time)
./linode_upload_stackscript.sh

# 2. Create server with one command
./linode_create_test_server.sh

# 3. Wait for provisioning (~5-7 minutes total)
# The script monitors boot status automatically

# 4. Connect via SSH
ssh nwp@<server-ip>

# Server is ready with:
# - Nginx 1.24.0
# - PHP 8.2
# - MariaDB 10.11
# - UFW firewall configured
# - Root login disabled
```

### Deploying a Site

```bash
# Deploy from your local DDEV project
cd /path/to/your/ddev/project
../linode/linode_deploy.sh \
  --server 45.33.94.133 \
  --target test \
  --domain test.example.com

# The script automatically:
# - Exports database and files from DDEV
# - Transfers to server via SCP
# - Creates database with secure password
# - Imports data
# - Configures Nginx
# - Sets correct permissions
# - Updates Drupal settings.php

# For production with SSL:
../linode/linode_deploy.sh \
  --server nwp.org \
  --target prod \
  --domain nwp.org \
  --ssl
```

### Blue-Green Deployment

```bash
# 1. Deploy to test environment
./linode_deploy.sh --server SERVER_IP --target test --domain test.example.com

# 2. Verify test site works
curl -I http://test.example.com

# 3. Deploy to production (atomic swap)
ssh nwp@SERVER_IP
cd ~/nwp-scripts
./nwp-swap-prod.sh

# This swaps:
# test → prod (new version goes live)
# prod → old (previous version saved for rollback)

# 4. Verify production
curl -I https://example.com

# 5. Rollback if needed (instant)
./nwp-rollback.sh
```

---

## Configuration

### Main Config File

Location: `~/.nwp/linode.yml`

```yaml
# Linode API Configuration
api:
  token: "your-api-token"
  default_region: "us-east"
  default_plan: "g6-standard-2"

# Server Defaults
server:
  ssh_user: "nwp"
  ssh_key_path: "~/.nwp/linode/keys/nwp_linode.pub"

# Email for SSL certificates
email: "admin@example.com"
```

### SSH Config

Location: `~/.ssh/config`

```
Host nwp-*
    User nwp
    IdentityFile ~/.nwp/linode/keys/nwp_linode

Host nwp-test
    HostName <test-server-ip>

Host nwp-prod
    HostName <prod-server-ip>
```

---

## Troubleshooting

### Can't Connect to Server
```bash
# Check server status
linode-cli linodes list

# Verify SSH key
ssh -i ~/.nwp/linode/keys/nwp_linode nwp@server-ip

# Check firewall
ssh nwp@server-ip
sudo ufw status
```

### StackScript Didn't Run
```bash
# Check logs via Linode LISH console, or:
ssh nwp@server-ip
sudo tail -100 /var/log/nwp-setup.log
```

### Deployment Issues
```bash
# On server, check service status
sudo systemctl status nginx
sudo systemctl status php8.2-fpm
sudo systemctl status mariadb

# Check Nginx logs
sudo tail -f /var/log/nginx/error.log
```

---

## Roadmap

### ✅ Completed (Phase 1 & 2)
- [x] Local setup automation (`linode_setup.sh`)
- [x] Server provisioning script (`linode_server_setup.sh`)
- [x] Server management scripts (create, swap, rollback, backup)
- [x] Comprehensive documentation
- [x] StackScript upload automation (`linode_upload_stackscript.sh`)
- [x] Test server creation script (`linode_create_test_server.sh`)
- [x] LEMP stack installation verified (Nginx, PHP 8.2, MariaDB)
- [x] SSH security tested (root disabled, key-only auth)
- [x] Site deployment automation (`linode_deploy.sh`)
- [x] Validation tools (`validate_stackscript.sh`)

### 📋 Planned (Phase 3+)

#### Integration with Existing NWP Tools
- [ ] Integrate `linode_deploy.sh` with `make.sh`
  - [ ] Add Linode deployment option to make menu
  - [ ] Pass configuration from make.sh to deployment scripts
  - [ ] Unified environment variable handling
- [ ] Integrate with `dev2stg.sh` workflow
  - [ ] Extend dev2stg to support `dev2linode` deployment
  - [ ] Add staging → production promotion via Linode
  - [ ] Maintain compatibility with existing DDEV workflow
- [ ] Add Linode commands to main NWP CLI
  - [ ] `nwp linode:setup` - Run initial setup
  - [ ] `nwp linode:deploy` - Deploy current project
  - [ ] `nwp linode:provision` - Create new server
  - [ ] `nwp linode:status` - Check server status

#### Automated Testing Pipeline on Linode Servers
- [ ] Create `linode_test.sh` script
  - [ ] Deploy site to test server
  - [ ] Run automated tests (Behat, PHPUnit)
  - [ ] Verify SSL certificate installation
  - [ ] Check all services are running
  - [ ] Performance benchmarking
- [ ] CI/CD Integration
  - [ ] GitHub Actions workflow for Linode deployment
  - [ ] Automated testing before production deployment
  - [ ] Rollback on test failure
  - [ ] Slack/email notifications
- [ ] Test result reporting
  - [ ] Generate test reports
  - [ ] Store results in `/var/log/nwp-tests/`
  - [ ] Compare performance across deployments

#### Multi-Site Management on Single Server
- [ ] Create `linode_multisite.sh` management tool
  - [ ] Add new sites without conflicts
  - [ ] Manage per-site Nginx configurations
  - [ ] Isolate site databases and users
  - [ ] Per-site PHP-FPM pools for resource isolation
- [ ] Resource allocation
  - [ ] Configure PHP memory limits per site
  - [ ] Set database connection limits
  - [ ] Monitor per-site resource usage
- [ ] Domain management
  - [ ] Automated DNS verification
  - [ ] Bulk SSL certificate setup
  - [ ] Subdomain handling (site1.nwp.org, site2.nwp.org)

#### Backup Automation with Rotation
- [ ] Enhance `nwp-backup.sh` with rotation
  - [ ] Daily incremental backups
  - [ ] Weekly full backups
  - [ ] Monthly archives
  - [ ] Automatic old backup deletion (keep last N backups)
- [ ] Off-site backup storage
  - [ ] Linode Object Storage integration
  - [ ] Amazon S3 support
  - [ ] Encrypted backup archives
  - [ ] Backup verification/integrity checks
- [ ] Restore testing
  - [ ] Automated restore verification
  - [ ] Document restore procedures
  - [ ] Test restore time benchmarks

#### Server Monitoring and Alerting
- [ ] Install monitoring stack
  - [ ] Prometheus for metrics collection
  - [ ] Grafana for visualization
  - [ ] Alert manager for notifications
  - [ ] Node exporter for system metrics
- [ ] Application monitoring
  - [ ] PHP-FPM status monitoring
  - [ ] Nginx request metrics
  - [ ] MariaDB query performance
  - [ ] Drupal watchdog integration
- [ ] Alerting rules
  - [ ] Disk space < 10% → alert
  - [ ] CPU usage > 80% for 5 min → alert
  - [ ] Memory usage > 90% → alert
  - [ ] Site downtime → immediate alert
  - [ ] SSL certificate expiring < 30 days → alert
- [ ] Notification channels
  - [ ] Email alerts
  - [ ] Slack integration
  - [ ] SMS for critical alerts (via Twilio)

#### Load Balancing for High-Traffic Sites
- [ ] Linode NodeBalancer integration
  - [ ] Create `linode_loadbalancer.sh` setup script
  - [ ] Configure multiple backend servers
  - [ ] Health check configuration
  - [ ] SSL termination at load balancer
- [ ] Session handling
  - [ ] Redis for shared session storage
  - [ ] Database session handler configuration
  - [ ] Sticky sessions configuration
- [ ] Scaling automation
  - [ ] Auto-scale based on traffic
  - [ ] Create servers from StackScript template
  - [ ] Add/remove from load balancer pool

#### Database Replication for Production
- [ ] MariaDB primary-replica setup
  - [ ] Configure primary database server
  - [ ] Set up read replicas
  - [ ] Automated failover configuration
  - [ ] Replication monitoring
- [ ] Backup from replica
  - [ ] Offload backups to replica server
  - [ ] Prevent production performance impact
  - [ ] Point-in-time recovery setup
- [ ] Database connection routing
  - [ ] Write operations → primary
  - [ ] Read operations → replicas
  - [ ] Load balancing across read replicas

#### Automated SSL Certificate Management
- [ ] Enhanced certificate automation
  - [ ] Pre-deployment certificate validation
  - [ ] Wildcard certificate support
  - [ ] Multi-domain SAN certificates
  - [ ] Certificate monitoring dashboard
- [ ] Renewal improvements
  - [ ] Test renewal process in staging
  - [ ] Zero-downtime certificate rotation
  - [ ] Automatic Nginx reload on renewal
  - [ ] Renewal failure notifications
- [ ] Certificate backup
  - [ ] Store certificates in secure backup
  - [ ] Certificate inventory tracking
  - [ ] Expiration calendar/reminders

---

## Getting Help

1. **Read the docs:** Start with [docs/SETUP_GUIDE.md](docs/SETUP_GUIDE.md)
2. **Check script help:** All scripts have `--help` flag
3. **Review logs:**
   - Setup: `/var/log/nwp-setup.log`
   - Deployments: `/var/log/nwp-deployments.log`
4. **Linode support:** Available 24/7 at [https://cloud.linode.com/support](https://cloud.linode.com/support)

---

## Contributing

This is part of the NWP (Narrow Way Project). For questions or issues:
- Review the main project README
- Check existing documentation
- Open an issue in the repository

---

## Credits

These scripts are adapted from:
- **[Pleasy Server Scripts](https://github.com/rjzaar/pleasy/tree/master/server)** by rjzaar
- **[DigitalOcean Tutorials](https://www.digitalocean.com/community/tutorials)** for server hardening best practices

Built for the **Narrow Way Project (NWP)** - Drupal/OpenSocial distribution for church and ministry websites.

---

*Last updated: 2025-12-24*
*Branch: linode*
*Status: Phase 1 & 2 Complete - Ready for Production Use*
