# GitLab Setup Guide

Complete step-by-step guide for deploying GitLab CE on Linode.

## Prerequisites

### What You Need

1. **Linode Account**
   - Active Linode account
   - API token with Linodes + StackScripts permissions
   - Get token at: https://cloud.linode.com/profile/tokens

2. **Local Machine Requirements**
   - Python 3.6 or newer
   - SSH client
   - Basic command line knowledge
   - Internet connection

3. **Domain Name** (recommended)
   - DNS A record pointing to your server
   - Example: gitlab.example.com

## Step 1: Local Environment Setup

### Run the Setup Script

```bash
cd git
./gitlab_setup.sh
```

This script will:
1. Check for Python 3, pip3, and SSH
2. Install missing prerequisites (with your permission)
3. Install Linode CLI via pipx
4. Configure Linode API authentication
5. Generate SSH keys
6. Create configuration files

### What You'll Be Asked

**Linode API Token:**
- Visit: https://cloud.linode.com/profile/tokens
- Click "Create Personal Access Token"
- Label: "GitLab Deployment"
- Permissions: Linodes (Read/Write), StackScripts (Read/Write)
- Copy the token and paste when prompted

**Configuration Prompts:**
- Default region: `us-east` (or your preferred region)
- Default type: `g6-standard-1` (2GB RAM for GitLab)
- Default image: `linode/ubuntu24.04`

**SSH Key:**
- Accept creating a dedicated SSH key for GitLab servers
- This improves security by separating keys

### Verify Setup

The script will verify:
- ✓ Linode CLI installed
- ✓ API connection working
- ✓ SSH keys created
- ✓ Configuration file created

### Manual Configuration (Optional)

Edit `~/.nwp/gitlab.yml` to customize:

```yaml
gitlab:
  external_url: "http://gitlab.example.com"
  letsencrypt_email: "admin@example.com"
  enable_registry: true  # Container registry
  enable_lfs: true       # Git LFS

runner:
  install_by_default: true
  default_executor: "docker"
  default_tags: "docker,linux,shell"

backup:
  retention_days: 7
  backup_path: "/var/backups/gitlab"
```

## Step 2: Upload StackScript

The StackScript is the automated server provisioning script.

```bash
./gitlab_upload_stackscript.sh
```

**What This Does:**
- Validates the server setup script for Linode compatibility
- Uploads `gitlab_server_setup.sh` to your Linode account
- Saves the StackScript ID for future use

**Output:**
```
StackScript Details:
  ID: 123456
  Label: GitLab CE Server Setup

StackScript ID saved to: ~/.nwp/gitlab_stackscript_id
```

You only need to do this once (unless you update the StackScript).

## Step 3: Create GitLab Server

### Basic Server Creation

```bash
./gitlab_create_server.sh \
  --domain gitlab.example.com \
  --email admin@example.com
```

### Advanced Options

```bash
./gitlab_create_server.sh \
  --domain gitlab.example.com \
  --email admin@example.com \
  --label my-gitlab-prod \
  --region us-west \
  --type g6-standard-2 \
  --no-runner
```

**Options:**
- `--domain`: Your GitLab domain (required)
- `--email`: Admin email for SSL and notifications (required)
- `--label`: Server label in Linode (default: gitlab-TIMESTAMP)
- `--region`: Linode region (default: us-east)
- `--type`: Server size (default: g6-standard-1)
- `--no-runner`: Skip GitLab Runner installation
- `--runner-tags`: Custom runner tags (default: docker,shell)

### Server Sizes

| Type | RAM | CPU | Disk | Use Case |
|------|-----|-----|------|----------|
| g6-standard-1 | 2GB | 1 | 50GB | Small teams (1-5 users) |
| g6-standard-2 | 4GB | 2 | 80GB | Medium teams (5-20 users) - **Recommended** |
| g6-standard-4 | 8GB | 4 | 160GB | Large teams (20+ users) |

**Important:** GitLab requires minimum 2GB RAM.

### What Happens During Creation

1. **Linode Created** (~30 seconds)
   - Server provisioned with Ubuntu 24.04
   - IP address assigned

2. **Server Boots** (~1 minute)
   - StackScript begins execution

3. **System Setup** (~2 minutes)
   - Updates packages
   - Creates non-root user
   - Configures SSH security
   - Sets up firewall

4. **Docker Installation** (~2 minutes)
   - Installs Docker for GitLab Runner

5. **GitLab Installation** (~10 minutes)
   - Downloads and installs GitLab CE Omnibus
   - Configures GitLab
   - Generates initial root password

6. **GitLab Runner Installation** (~1 minute)
   - Installs GitLab Runner (if not skipped)

**Total Time:** 10-15 minutes

### Monitor Installation

SSH to the server and watch the installation:

```bash
ssh gitlab@YOUR_SERVER_IP
sudo tail -f /var/log/gitlab-setup.log
```

Look for:
```
[OK] GitLab CE installed
[OK] GitLab configured and running
[OK] GitLab Runner installed
GitLab Server Setup Complete!
```

## Step 4: Configure DNS

Point your domain's A record to the server IP:

```
Type: A
Name: gitlab
Value: YOUR_SERVER_IP
TTL: 300
```

Wait 5-15 minutes for DNS propagation.

Verify: `nslookup gitlab.example.com`

## Step 5: Get Root Credentials

GitLab auto-generates a root password during installation:

```bash
ssh gitlab@YOUR_SERVER_IP 'sudo cat /root/gitlab_credentials.txt'
```

**Output:**
```
GitLab Server Credentials
==========================
GitLab URL: http://gitlab.example.com
Username: root
Password: ABC123xyz789...

IMPORTANT:
- Change this password immediately after first login
- This password is valid for 24 hours only
```

**Save this password immediately!**

## Step 6: First Login

1. Open your browser to: `http://gitlab.example.com`
2. You'll see the GitLab sign-in page
3. Username: `root`
4. Password: (from gitlab_credentials.txt)
5. Click "Sign in"

### Immediate Actions

1. **Change Root Password**
   - Click root avatar (top right) > Edit Profile > Password
   - Set a strong new password

2. **Disable Sign-ups** (if not needed)
   - Admin Area > Settings > General > Sign-up restrictions
   - Uncheck "Sign-up enabled"

3. **Create Your User Account**
   - Admin Area > Users > New User
   - Fill in details
   - Make admin if needed

4. **Create First Project**
   - Click "New project"
   - Create blank project or import existing

## Step 7: Set Up SSL (Recommended)

### Option A: GitLab Built-in Let's Encrypt (Easiest)

1. SSH to server:
   ```bash
   ssh gitlab@YOUR_SERVER
   ```

2. Edit GitLab config:
   ```bash
   sudo nano /etc/gitlab/gitlab.rb
   ```

3. Update these lines:
   ```ruby
   external_url 'https://gitlab.example.com'  # Change http to https
   letsencrypt['enable'] = true
   letsencrypt['contact_emails'] = ['admin@example.com']
   ```

4. Reconfigure:
   ```bash
   sudo gitlab-ctl reconfigure
   ```

5. Wait 2-3 minutes for certificate

6. Access: `https://gitlab.example.com`

### Option B: Manual Certbot

```bash
ssh gitlab@YOUR_SERVER
sudo certbot certonly --standalone -d gitlab.example.com
```

Follow prompts, then update GitLab config to use the certificates.

## Step 8: Register GitLab Runner (for CI/CD)

See [RUNNER_GUIDE.md](RUNNER_GUIDE.md) for detailed instructions.

Quick version:
1. Get registration token from GitLab UI: Admin Area > CI/CD > Runners
2. SSH to server
3. Run:
   ```bash
   cd gitlab-scripts
   ./gitlab-register-runner.sh --token YOUR_TOKEN
   ```

## Troubleshooting

### GitLab Not Accessible

**Check if GitLab is running:**
```bash
ssh gitlab@YOUR_SERVER 'sudo gitlab-ctl status'
```

All services should show `run:`.

**Check logs:**
```bash
ssh gitlab@YOUR_SERVER 'sudo gitlab-ctl tail'
```

### Installation Failed

Check setup log:
```bash
ssh gitlab@YOUR_SERVER 'sudo cat /var/log/gitlab-setup.log'
```

Look for errors marked `[X]` or `ERROR:`.

### Forgot Root Password

Reset it:
```bash
ssh gitlab@YOUR_SERVER 'sudo gitlab-rake "gitlab:password:reset[root]"'
```

### Low Memory Warnings

GitLab needs 2GB minimum. Upgrade server:
```bash
# In Linode Cloud Manager:
# 1. Power off server
# 2. Resize to larger plan
# 3. Power on
```

### DNS Not Resolving

Check DNS:
```bash
nslookup gitlab.example.com
```

Should return your server IP. If not, check your DNS provider settings.

## Post-Installation

### Recommended Settings

1. **Email Notifications**
   - Configure SMTP in `/etc/gitlab/gitlab.rb`
   - Example for Gmail:
     ```ruby
     gitlab_rails['smtp_enable'] = true
     gitlab_rails['smtp_address'] = "smtp.gmail.com"
     gitlab_rails['smtp_port'] = 587
     gitlab_rails['smtp_user_name'] = "your.email@gmail.com"
     gitlab_rails['smtp_password'] = "app-password"
     gitlab_rails['smtp_domain'] = "smtp.gmail.com"
     gitlab_rails['smtp_authentication'] = "login"
     gitlab_rails['smtp_enable_starttls_auto'] = true
     ```
   - Reconfigure: `sudo gitlab-ctl reconfigure`

2. **Backups**
   - Set up automated backups (cron job)
   - Test restore process

3. **Monitoring**
   - Enable Prometheus (already enabled by default)
   - Set up alerting if desired

### Security Hardening

1. **Two-Factor Authentication**
   - Enable for all admin accounts
   - Require for all users (optional)

2. **SSH Key Only**
   - Already configured (password auth disabled)

3. **Firewall**
   - Already configured with UFW
   - Only ports 22, 80, 443, 5050 open

4. **Regular Updates**
   - Use `gitlab-upgrade.sh` monthly
   - Subscribe to GitLab security notices

## Next Steps

- Read [RUNNER_GUIDE.md](RUNNER_GUIDE.md) to set up CI/CD
- Create your first project
- Invite team members
- Set up webhooks and integrations
- Configure backup schedule

## Support Resources

- GitLab Documentation: https://docs.gitlab.com/
- GitLab Community Forum: https://forum.gitlab.com/
- Linode Documentation: https://www.linode.com/docs/
