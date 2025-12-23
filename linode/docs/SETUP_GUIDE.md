# NWP Linode Setup Guide

**Complete guide for setting up NWP deployment infrastructure on Linode**

---

## Table of Contents

1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [Local Environment Setup](#local-environment-setup)
4. [Linode Account Setup](#linode-account-setup)
5. [Creating Your First Server](#creating-your-first-server)
6. [Server Access and Verification](#server-access-and-verification)
7. [Deploying a Site](#deploying-a-site)
8. [Troubleshooting](#troubleshooting)
9. [Security Best Practices](#security-best-practices)

---

## Overview

This guide will walk you through the complete process of:
- Setting up your local machine for Linode deployment
- Creating a Linode account and API token
- Provisioning secure Ubuntu servers
- Deploying NWP/OpenSocial sites to Linode
- Managing production deployments

**Time required:** 30-60 minutes for initial setup

---

## Prerequisites

Before starting, ensure you have:

- [ ] A Linux/Mac machine with terminal access (or WSL on Windows)
- [ ] Python 3.6 or higher installed
- [ ] SSH client installed
- [ ] A Linode account (free to create)
- [ ] A payment method for Linode (servers start at ~$5/month)
- [ ] A working NWP local development environment (DDEV)

---

## Local Environment Setup

### Step 1: Run the Setup Script

The easiest way to set up your local environment is to run the automated setup script:

```bash
cd /path/to/nwp/linode
./linode_setup.sh
```

This script will:
- Install Linode CLI
- Configure API authentication
- Set up SSH keys
- Create configuration files

### Step 2: Verify Prerequisites

The script will check for required software. If anything is missing, install it:

**Ubuntu/Debian:**
```bash
sudo apt-get update
sudo apt-get install -y python3 python3-pip openssh-client
```

**macOS:**
```bash
brew install python@3
```

### Step 3: Install Linode CLI Manually (if needed)

If the setup script fails or you prefer manual installation:

```bash
pip3 install linode-cli
```

Make sure `~/.local/bin` is in your PATH:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

Verify installation:

```bash
linode-cli --version
```

---

## Linode Account Setup

### Step 1: Create a Linode Account

1. Go to [https://www.linode.com/](https://www.linode.com/)
2. Click "Sign Up"
3. Complete registration with email and payment method
4. Verify your email address

**Note:** Linode offers a $100 credit for new users (as of 2024)

### Step 2: Generate an API Token

The API token allows the CLI to manage servers on your behalf.

1. Log into the [Linode Cloud Manager](https://cloud.linode.com/)
2. Click on your username (top right) → **API Tokens**
3. Click **Create Personal Access Token**
4. Configure the token:
   - **Label:** `NWP Deployment`
   - **Expiration:** 6 months (or "Never" if you prefer)
   - **Access:**
     - ✅ Linodes: **Read/Write**
     - ✅ StackScripts: **Read/Write**
     - ✅ Images: **Read/Write**
     - ❌ Leave others as default (No Access)
5. Click **Create Token**
6. **IMPORTANT:** Copy the token immediately - it won't be shown again!

### Step 3: Configure Linode CLI

Run the configuration wizard:

```bash
linode-cli configure
```

You'll be prompted for:

- **API Token:** Paste the token from Step 2
- **Default Region:** `us-east` (Newark, NJ - recommended for US East Coast)
- **Default Type:** `g6-standard-2` (2GB RAM, good for testing)
- **Default Image:** `linode/ubuntu24.04`

### Step 4: Verify API Connection

Test that everything is working:

```bash
linode-cli linodes list
```

You should see an empty list (or any existing Linodes). If you get an error, double-check your API token.

---

## SSH Key Setup

SSH keys are required for secure, password-less authentication to your servers.

### Option 1: Use Existing SSH Key

Check if you already have an SSH key:

```bash
ls -la ~/.ssh/id_*.pub
```

If you see `id_rsa.pub` or `id_ed25519.pub`, you're all set!

View your public key:

```bash
cat ~/.ssh/id_ed25519.pub
# or
cat ~/.ssh/id_rsa.pub
```

### Option 2: Generate a New SSH Key

If you don't have a key or want a dedicated one for NWP:

```bash
ssh-keygen -t ed25519 -C "nwp-linode" -f ~/.nwp/linode/keys/nwp_linode
```

Press Enter to accept defaults (or set a passphrase for extra security).

Your keys will be created:
- Private key: `~/.nwp/linode/keys/nwp_linode`
- Public key: `~/.nwp/linode/keys/nwp_linode.pub`

**Display your public key:**

```bash
cat ~/.nwp/linode/keys/nwp_linode.pub
```

**IMPORTANT:** Keep your private key secure! Never share it or commit it to Git.

### Step 3: Configure SSH Client

Add NWP servers to your SSH config for easier access:

```bash
nano ~/.ssh/config
```

Add this configuration:

```
# NWP Linode Servers
Host nwp-*
    User nwp
    IdentityFile ~/.nwp/linode/keys/nwp_linode
    StrictHostKeyChecking accept-new

Host nwp-test
    HostName # Will be set after server creation
    User nwp

Host nwp-prod
    HostName # Will be set after server creation
    User nwp
```

Save and close (Ctrl+X, Y, Enter in nano).

---

## Creating Your First Server

### Manual Method: Using Linode Cloud Manager

1. **Log into Cloud Manager:** [https://cloud.linode.com/](https://cloud.linode.com/)

2. **Create a Linode:**
   - Click **Create** → **Linode**
   - **Choose a Distribution:** Ubuntu 24.04 LTS
   - **Region:** Select closest to your users (e.g., Newark, NJ for US East)
   - **Linode Plan:** Shared CPU → Linode 2GB ($12/month for testing)

3. **Configure the Linode:**
   - **Linode Label:** `nwp-test-01`
   - **Root Password:** Set a strong password (won't be used after setup)
   - **SSH Keys:** Click "Add an SSH Key" and paste your public key
   - **Add-ons:** ✅ Backups (optional, +$2/month)

4. **Deploy with StackScript (Recommended):**
   - Instead of basic deployment, scroll to **StackScripts**
   - Upload `linode_server_setup.sh` as a StackScript first:
     - Go to **StackScripts** → **Create StackScript**
     - Paste contents of `linode/linode_server_setup.sh`
     - Label: "NWP Server Setup"
     - Save
   - Select your NWP StackScript
   - Fill in User Defined Fields:
     - **ssh_user:** `nwp`
     - **ssh_pubkey:** (paste your public key)
     - **hostname:** `test.nwp.org`
     - **email:** `your-email@example.com`
     - **disable_root:** `yes`

5. **Create the Linode:**
   - Click **Create Linode**
   - Wait 2-5 minutes for provisioning

6. **Note the IP Address:**
   - Once running, copy the IPv4 address (e.g., `192.0.2.100`)

### Automated Method: Using Linode CLI

Once you've uploaded the StackScript, you can create servers with one command:

```bash
linode-cli linodes create \
  --label "nwp-test-01" \
  --region us-east \
  --type g6-standard-2 \
  --image linode/ubuntu24.04 \
  --root_pass "TemporaryRootPassword123!" \
  --authorized_keys "$(cat ~/.nwp/linode/keys/nwp_linode.pub)" \
  --stackscript_id <your_stackscript_id> \
  --stackscript_data '{"ssh_user":"nwp","ssh_pubkey":"'$(cat ~/.nwp/linode/keys/nwp_linode.pub)'","hostname":"test.nwp.org","email":"admin@example.com","timezone":"America/New_York","disable_root":"yes"}'
```

Replace `<your_stackscript_id>` with the ID from uploading the StackScript.

**Find your StackScript ID:**

```bash
linode-cli stackscripts list | grep "NWP Server Setup"
```

---

## Server Access and Verification

### Step 1: Wait for Provisioning

After creating the Linode, wait 3-5 minutes for the StackScript to complete.

Monitor progress:

```bash
linode-cli linodes list
```

Look for status: `running`

### Step 2: Configure DNS (Optional but Recommended)

Before accessing your server, configure DNS:

1. Go to your domain registrar (e.g., Namecheap, GoDaddy)
2. Add an **A record:**
   - **Host:** `test` (or `@` for root domain)
   - **Value:** Your Linode IP address
   - **TTL:** 300 (5 minutes)

Wait a few minutes for DNS propagation.

### Step 3: Connect via SSH

Using the IP address directly:

```bash
ssh nwp@192.0.2.100
```

Or using the hostname (if DNS is configured):

```bash
ssh nwp@test.nwp.org
```

Or using the SSH config alias (update HostName first):

```bash
nano ~/.ssh/config
# Set: HostName 192.0.2.100 (under Host nwp-test)

ssh nwp-test
```

**First time connecting:**
You'll see a message about authenticity. Type `yes` to continue.

### Step 4: Verify Server Setup

Once connected, you should see the NWP welcome message.

Verify services are running:

```bash
sudo systemctl status nginx
sudo systemctl status php8.2-fpm
sudo systemctl status mariadb
```

All should show `active (running)`.

Check the setup log:

```bash
sudo tail -100 /var/log/nwp-setup.log
```

### Step 5: Verify Root Access is Disabled

This is critical for security. Try to SSH as root:

```bash
ssh root@192.0.2.100
```

You should get `Permission denied (publickey)` - this is correct!

Only the `nwp` user should have access.

---

## Deploying a Site

**Coming Soon:** Deployment scripts are being developed.

For now, you can manually deploy by:

1. **Exporting your local site:**
   ```bash
   cd nwp4_stg
   ddev export-db --file=~/export.sql
   tar -czf ~/export-files.tar.gz html/
   ```

2. **Transferring to server:**
   ```bash
   scp ~/export.sql nwp@test.nwp.org:~/
   scp ~/export-files.tar.gz nwp@test.nwp.org:~/
   ```

3. **On the server, set up the site:**
   ```bash
   # Create database
   sudo mysql -e "CREATE DATABASE nwp;"
   sudo mysql -e "CREATE USER 'nwp'@'localhost' IDENTIFIED BY 'secure_password';"
   sudo mysql -e "GRANT ALL ON nwp.* TO 'nwp'@'localhost';"

   # Import database
   mysql -u nwp -p nwp < ~/export.sql

   # Extract files
   sudo tar -xzf ~/export-files.tar.gz -C /var/www/prod/
   sudo chown -R www-data:www-data /var/www/prod
   ```

4. **Configure Nginx:**
   Create `/etc/nginx/sites-available/nwp`:
   ```nginx
   server {
       listen 80;
       server_name test.nwp.org;
       root /var/www/prod/html/web;

       index index.php index.html;

       location / {
           try_files $uri $uri/ /index.php?$query_string;
       }

       location ~ \.php$ {
           include fastcgi_params;
           fastcgi_pass unix:/var/run/php/php8.2-fpm.sock;
           fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
       }
   }
   ```

   Enable the site:
   ```bash
   sudo ln -s /etc/nginx/sites-available/nwp /etc/nginx/sites-enabled/
   sudo nginx -t
   sudo systemctl reload nginx
   ```

5. **Set up SSL:**
   ```bash
   sudo certbot --nginx -d test.nwp.org
   ```

---

## Troubleshooting

### Can't Connect to Server

**Problem:** `ssh: connect to host X.X.X.X port 22: Connection refused`

**Solutions:**
1. Wait 3-5 minutes - server may still be provisioning
2. Check server status: `linode-cli linodes list`
3. Verify firewall allows SSH: `linode-cli linodes view <linode_id>`

### Permission Denied (publickey)

**Problem:** `Permission denied (publickey)` or `Load key: Permission denied`

**Root Cause:** SSH key ownership or permissions are incorrect.

**Solutions:**
1. Verify you're using the correct key: `ssh -i ~/.nwp/linode/keys/nwp_linode nwp@X.X.X.X`
2. Fix key permissions:
   ```bash
   # Fix ownership (replace 'rob' with your username)
   sudo chown $USER:$USER ~/.nwp/linode/keys/nwp_linode*

   # Set correct permissions
   chmod 600 ~/.nwp/linode/keys/nwp_linode
   chmod 644 ~/.nwp/linode/keys/nwp_linode.pub
   ```
3. Verify public key was added during provisioning
4. Check server logs: Use Linode LISH console in Cloud Manager

### StackScript Upload Fails with "Invalid special character"

**Problem:** `Request failed: 400 - Invalid special character at position XXXX`

**Root Cause:** Linode StackScripts only support ASCII characters. Unicode characters (✓, ⚠, emojis) are rejected.

**Solution:**
1. Run the validation script before uploading:
   ```bash
   ./validate_stackscript.sh linode_server_setup.sh
   ```

2. The upload script (`linode_upload_stackscript.sh`) automatically fixes Unicode characters, but you can manually fix them:
   ```bash
   sed -i 's/✓/[OK]/g; s/⚠/[!]/g; s/✗/[X]/g' linode_server_setup.sh
   ```

3. Use only ASCII characters in StackScripts:
   - ✓ → `[OK]`
   - ⚠ → `[!]`
   - ✗ → `[X]`
   - • → `*`

**Prevention:** The `linode_upload_stackscript.sh` script includes automatic Unicode detection and conversion.

### StackScript Upload Fails with "script is required"

**Problem:** `Request failed: 400 - script is required`

**Root Cause:** Incorrect command substitution syntax. Linode CLI requires backticks, not `$()` or heredocs.

**Solution:**
Use backticks for the `--script` parameter:

```bash
# WRONG:
linode-cli stackscripts create --script "$(cat file.sh)" ...

# CORRECT:
linode-cli stackscripts create --script "`cat file.sh`" ...
```

**Note:** The `linode_upload_stackscript.sh` script uses the correct syntax automatically.

### StackScript Stops Early - SSH Service Failure

**Problem:** StackScript exits at step 3/9 with error:
```
Failed to restart sshd.service: Unit sshd.service not found.
```

**Root Cause:** Ubuntu 24.04 uses `ssh.service` not `sshd.service`. The StackScript's `set -e` caused it to exit on this error.

**Solution:** This has been fixed in the latest version of `linode_server_setup.sh`. The fix uses a fallback approach:

```bash
# Works on all Ubuntu versions
systemctl restart ssh || systemctl restart sshd || true
```

**If you encounter this:**
1. Re-upload the StackScript: `./linode_upload_stackscript.sh --update`
2. Create a new server with the updated script

### StackScript Didn't Run

**Problem:** Server created but LEMP stack not installed

**Solutions:**
1. Check StackScript logs via LISH console in Linode Cloud Manager:
   - Log into Cloud Manager
   - Go to your Linode
   - Click "Launch LISH Console"
   - Log in as root with the root password you set
   - View logs: `cat /var/log/nwp-setup.log`

2. Review the setup log if you can SSH in:
   ```bash
   ssh nwp@SERVER_IP
   sudo tail -100 /var/log/nwp-setup.log
   ```

3. Look for errors in the log. Common issues:
   - SSH service name error (see above)
   - Unicode characters (see above)
   - Network/package installation failures

### Root Login Not Disabled

**Problem:** Can still SSH as root

**Solutions:**
1. Manually disable: `sudo nano /etc/ssh/sshd_config`
2. Set: `PermitRootLogin no`
3. Set: `PasswordAuthentication no`
4. Restart SSH: `sudo systemctl restart ssh || sudo systemctl restart sshd`

### Linode CLI Not Found After Installation

**Problem:** `linode-cli: command not found` after running `linode_setup.sh`

**Root Cause:** The `~/.local/bin` directory is not in your PATH.

**Solution:**
1. Add to your PATH:
   ```bash
   echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
   source ~/.bashrc
   ```

2. Or use the full path:
   ```bash
   ~/.local/bin/linode-cli --version
   ```

3. The setup script should handle this automatically, but if it asks, answer "yes" to add to PATH.

### PEP 668 Error When Installing Linode CLI

**Problem:**
```
error: externally-managed-environment
× This environment is externally managed
```

**Root Cause:** Ubuntu 23.04+ and Debian 12+ prevent `pip install` to protect system Python (PEP 668).

**Solution:** The setup script automatically uses `pipx` instead of `pip3`. If you need to install manually:

```bash
# Install pipx
sudo apt-get update
sudo apt-get install -y pipx

# Install Linode CLI via pipx
pipx install linode-cli

# Ensure ~/.local/bin is in PATH
pipx ensurepath
source ~/.bashrc
```

### Can't Delete Test Servers

**Problem:** Want to clean up test servers to avoid charges

**Solution:**
1. List all servers:
   ```bash
   linode-cli linodes list
   ```

2. Delete by ID:
   ```bash
   linode-cli linodes delete <linode_id>
   ```

3. Confirm deletion when prompted.

**Cost Note:** Nanodes ($5/month) cost about $0.0075/hour. Testing for 1 hour costs less than 1 cent.

---

## Security Best Practices

### 1. SSH Key Management

- ✅ Use different keys for test vs production servers
- ✅ Set a passphrase on your private keys
- ✅ Keep private keys secure (never commit to Git)
- ✅ Regularly rotate keys (every 6-12 months)
- ❌ Never use password authentication for SSH

### 2. Firewall Configuration

Verify firewall is active and properly configured:

```bash
sudo ufw status verbose
```

Should show:
- `Status: active`
- SSH (22), HTTP (80), HTTPS (443) allowed
- All other ports blocked

### 3. Keep Software Updated

Regularly update system packages:

```bash
sudo apt-get update
sudo apt-get upgrade -y
```

Set up automatic security updates:

```bash
sudo apt-get install unattended-upgrades
sudo dpkg-reconfigure --priority=low unattended-upgrades
```

### 4. Database Security

- Use strong, unique passwords for each database
- Never use `root` user for applications
- Limit database user permissions to specific databases
- Disable remote root access (already done by setup script)

### 5. SSL/TLS Certificates

Always use HTTPS in production:

```bash
sudo certbot --nginx -d yourdomain.com
```

Certificates auto-renew via cron. Verify renewal works:

```bash
sudo certbot renew --dry-run
```

### 6. File Permissions

Ensure proper ownership and permissions:

```bash
sudo chown -R www-data:www-data /var/www/prod
sudo find /var/www/prod -type d -exec chmod 755 {} \;
sudo find /var/www/prod -type f -exec chmod 644 {} \;
sudo chmod 440 /var/www/prod/html/web/sites/*/settings.php
```

### 7. Monitor Server Logs

Regularly check logs for suspicious activity:

```bash
sudo tail -f /var/log/auth.log        # SSH login attempts
sudo tail -f /var/log/nginx/error.log # Web server errors
sudo journalctl -u php8.2-fpm -f      # PHP errors
```

### 8. Backup Regularly

- Enable Linode Backups ($2-10/month)
- Create manual backups before major changes
- Test restore procedures periodically

---

## Next Steps

Now that your server is set up, you can:

1. **Deploy your first site** using the deployment scripts
2. **Set up a production server** following the same process
3. **Configure DNS** for your domains
4. **Set up SSL certificates** with Let's Encrypt
5. **Automate backups** using NWP backup scripts
6. **Monitor performance** and optimize as needed

For more information, see:
- [LINODE_DEPLOYMENT.md](../../docs/LINODE_DEPLOYMENT.md) - Complete deployment architecture
- [Linode Documentation](https://www.linode.com/docs/)
- [DigitalOcean Tutorials](https://www.digitalocean.com/community/tutorials) - Many apply to Linode too

---

## Getting Help

If you run into issues:

1. Check the [Troubleshooting](#troubleshooting) section above
2. Review server logs: `/var/log/nwp-setup.log`
3. Check Linode's status page: [https://status.linode.com/](https://status.linode.com/)
4. Contact Linode support (24/7 available)
5. Open an issue in the NWP repository

---

*Last updated: 2024-12-23*
