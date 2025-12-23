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
- Install Linode CLI
- Configure API authentication
- Set up SSH keys
- Create configuration files

### 2. Create Your First Server

After setup, provision a test server:

```bash
# Manual method via Linode Cloud Manager
# Upload linode_server_setup.sh as a StackScript first
# Then create a server using that StackScript

# See docs/SETUP_GUIDE.md for detailed instructions
```

### 3. Deploy Your Site

Coming soon - deployment automation scripts are in development.

---

## Directory Structure

```
linode/
├── README.md                    # This file
├── linode_setup.sh             # Local environment setup script
├── linode_server_setup.sh      # Server provisioning StackScript
│
├── docs/
│   └── SETUP_GUIDE.md          # Complete setup guide
│
├── keys/
│   └── (SSH keys stored here)
│
└── server_scripts/             # Scripts that run ON the Linode server
    ├── README.md               # Server scripts documentation
    ├── nwp-createsite.sh       # Create new site on server
    ├── nwp-swap-prod.sh        # Blue-green deployment
    ├── nwp-rollback.sh         # Rollback deployment
    └── nwp-backup.sh           # Backup site
```

---

## Scripts Overview

### Local Scripts (Run on your machine)

| Script | Purpose | Usage |
|--------|---------|-------|
| **linode_setup.sh** | Set up local environment for Linode | `./linode_setup.sh` |
| **linode_server_setup.sh** | Server provisioning StackScript | Upload to Linode as StackScript |

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
#    - Log into Linode Cloud Manager
#    - Go to StackScripts → Create
#    - Paste contents of linode_server_setup.sh
#    - Label: "NWP Server Setup"

# 2. Create server via CLI
linode-cli linodes create \
  --label "nwp-test-01" \
  --region us-east \
  --type g6-standard-2 \
  --image linode/ubuntu24.04 \
  --root_pass "TempPassword123!" \
  --stackscript_id <your_stackscript_id>

# 3. Wait for provisioning (3-5 minutes)
linode-cli linodes list

# 4. Connect via SSH
ssh nwp@<server-ip>
```

### Deploying a Site (Manual - for now)

```bash
# On local machine: Export site
cd nwp4_stg
ddev export-db --file=~/export.sql
tar -czf ~/export-files.tar.gz html/

# Transfer to server
scp ~/export.sql nwp@server-ip:~/
scp ~/export-files.tar.gz nwp@server-ip:~/

# On server: Create site
cd ~/nwp-scripts
./nwp-createsite.sh \
  --email admin@example.com \
  --enable-ssl \
  example.com

# Import database
mysql -u example_com -p example_com < ~/export.sql

# Extract files
sudo tar -xzf ~/export-files.tar.gz -C /var/www/prod/
sudo chown -R www-data:www-data /var/www/prod
```

### Blue-Green Deployment

```bash
# 1. Deploy to test (via future linode_deploy.sh)
./linode_deploy.sh nwp4_prod test.example.com

# 2. Verify test site works
curl -I https://test.example.com

# 3. Swap to production (on server)
ssh nwp@prod-server
cd ~/nwp-scripts
./nwp-swap-prod.sh --maintenance --yes

# 4. Verify production
curl -I https://example.com

# 5. Rollback if needed
./nwp-rollback.sh --yes
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

### ✅ Completed (Phase 1)
- [x] Local setup automation (`linode_setup.sh`)
- [x] Server provisioning script (`linode_server_setup.sh`)
- [x] Server management scripts (create, swap, rollback, backup)
- [x] Comprehensive documentation

### 🚧 In Progress (Phase 2)
- [ ] Upload StackScript to Linode
- [ ] Test server provisioning
- [ ] Verify LEMP stack installation
- [ ] Test SSH access and security

### 📋 Planned (Phase 3+)
- [ ] `linode_deploy.sh` - Automated deployment from local to Linode
- [ ] `linode_provision.sh` - CLI wrapper for creating servers
- [ ] Integration with NWP tools (`make.sh`, `dev2stg.sh`)
- [ ] Automated testing on Linode servers
- [ ] Multi-site support
- [ ] Backup automation with rotation
- [ ] Monitoring and alerting

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

*Last updated: 2024-12-23*
*Branch: linode*
