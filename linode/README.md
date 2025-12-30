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

#### 1. Integration with Existing NWP Tools
1.1. Integrate `linode_deploy.sh` with `make.sh`
- [ ] 1.1.1. Add Linode deployment option to make menu
- [ ] 1.1.2. Pass configuration from make.sh to deployment scripts
- [ ] 1.1.3. Unified environment variable handling

1.2. Integrate with `dev2stg.sh` workflow
- [ ] 1.2.1. Extend dev2stg to support `dev2linode` deployment
- [ ] 1.2.2. Add staging → production promotion via Linode
- [ ] 1.2.3. Maintain compatibility with existing DDEV workflow

1.3. Add Linode commands to main NWP CLI
- [ ] 1.3.1. `nwp linode:setup` - Run initial setup
- [ ] 1.3.2. `nwp linode:deploy` - Deploy current project
- [ ] 1.3.3. `nwp linode:provision` - Create new server
- [ ] 1.3.4. `nwp linode:status` - Check server status

#### 2. Automated Testing Pipeline on Linode Servers
2.1. Create `linode_test.sh` script
- [ ] 2.1.1. Deploy site to test server
- [ ] 2.1.2. Run automated tests (Behat, PHPUnit)
- [ ] 2.1.3. Verify SSL certificate installation
- [ ] 2.1.4. Check all services are running
- [ ] 2.1.5. Performance benchmarking

2.2. CI/CD Integration
- [ ] 2.2.1. GitHub Actions workflow for Linode deployment
- [ ] 2.2.2. Automated testing before production deployment
- [ ] 2.2.3. Rollback on test failure
- [ ] 2.2.4. Slack/email notifications

2.3. Test result reporting
- [ ] 2.3.1. Generate test reports
- [ ] 2.3.2. Store results in `/var/log/nwp-tests/`
- [ ] 2.3.3. Compare performance across deployments

#### 3. Multi-Site Management on Single Server
3.1. Create `linode_multisite.sh` management tool
- [ ] 3.1.1. Add new sites without conflicts
- [ ] 3.1.2. Manage per-site Nginx configurations
- [ ] 3.1.3. Isolate site databases and users
- [ ] 3.1.4. Per-site PHP-FPM pools for resource isolation

3.2. Resource allocation
- [ ] 3.2.1. Configure PHP memory limits per site
- [ ] 3.2.2. Set database connection limits
- [ ] 3.2.3. Monitor per-site resource usage

3.3. Domain management
- [ ] 3.3.1. Automated DNS verification
- [ ] 3.3.2. Bulk SSL certificate setup
- [ ] 3.3.3. Subdomain handling (site1.nwp.org, site2.nwp.org)

#### 4. Backup Automation with Rotation
4.1. Enhance `nwp-backup.sh` with rotation
- [ ] 4.1.1. Daily incremental backups
- [ ] 4.1.2. Weekly full backups
- [ ] 4.1.3. Monthly archives
- [ ] 4.1.4. Automatic old backup deletion (keep last N backups)

4.2. Off-site backup storage
- [ ] 4.2.1. Linode Object Storage integration
- [ ] 4.2.2. Amazon S3 support
- [ ] 4.2.3. Encrypted backup archives
- [ ] 4.2.4. Backup verification/integrity checks

4.3. Restore testing
- [ ] 4.3.1. Automated restore verification
- [ ] 4.3.2. Document restore procedures
- [ ] 4.3.3. Test restore time benchmarks

#### 5. Server Monitoring and Alerting
5.1. Install monitoring stack
- [ ] 5.1.1. Prometheus for metrics collection
- [ ] 5.1.2. Grafana for visualization
- [ ] 5.1.3. Alert manager for notifications
- [ ] 5.1.4. Node exporter for system metrics

5.2. Application monitoring
- [ ] 5.2.1. PHP-FPM status monitoring
- [ ] 5.2.2. Nginx request metrics
- [ ] 5.2.3. MariaDB query performance
- [ ] 5.2.4. Drupal watchdog integration

5.3. Alerting rules
- [ ] 5.3.1. Disk space < 10% → alert
- [ ] 5.3.2. CPU usage > 80% for 5 min → alert
- [ ] 5.3.3. Memory usage > 90% → alert
- [ ] 5.3.4. Site downtime → immediate alert
- [ ] 5.3.5. SSL certificate expiring < 30 days → alert

5.4. Notification channels
- [ ] 5.4.1. Email alerts
- [ ] 5.4.2. Slack integration
- [ ] 5.4.3. SMS for critical alerts (via Twilio)

#### 6. Load Balancing for High-Traffic Sites
6.1. Linode NodeBalancer integration
- [ ] 6.1.1. Create `linode_loadbalancer.sh` setup script
- [ ] 6.1.2. Configure multiple backend servers
- [ ] 6.1.3. Health check configuration
- [ ] 6.1.4. SSL termination at load balancer

6.2. Session handling
- [ ] 6.2.1. Redis for shared session storage
- [ ] 6.2.2. Database session handler configuration
- [ ] 6.2.3. Sticky sessions configuration

6.3. Scaling automation
- [ ] 6.3.1. Auto-scale based on traffic
- [ ] 6.3.2. Create servers from StackScript template
- [ ] 6.3.3. Add/remove from load balancer pool

#### 7. Database Replication for Production
7.1. MariaDB primary-replica setup
- [ ] 7.1.1. Configure primary database server
- [ ] 7.1.2. Set up read replicas
- [ ] 7.1.3. Automated failover configuration
- [ ] 7.1.4. Replication monitoring

7.2. Backup from replica
- [ ] 7.2.1. Offload backups to replica server
- [ ] 7.2.2. Prevent production performance impact
- [ ] 7.2.3. Point-in-time recovery setup

7.3. Database connection routing
- [ ] 7.3.1. Write operations → primary
- [ ] 7.3.2. Read operations → replicas
- [ ] 7.3.3. Load balancing across read replicas

#### 8. Automated SSL Certificate Management
8.1. Enhanced certificate automation
- [ ] 8.1.1. Pre-deployment certificate validation
- [ ] 8.1.2. Wildcard certificate support
- [ ] 8.1.3. Multi-domain SAN certificates
- [ ] 8.1.4. Certificate monitoring dashboard

8.2. Renewal improvements
- [ ] 8.2.1. Test renewal process in staging
- [ ] 8.2.2. Zero-downtime certificate rotation
- [ ] 8.2.3. Automatic Nginx reload on renewal
- [ ] 8.2.4. Renewal failure notifications

8.3. Certificate backup
- [ ] 8.3.1. Store certificates in secure backup
- [ ] 8.3.2. Certificate inventory tracking
- [ ] 8.3.3. Expiration calendar/reminders

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
