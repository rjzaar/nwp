# SSH Key Setup for Linode Deployment

This guide explains how to set up SSH keys for NWP Linode deployment.

## Overview

NWP uses SSH keys for secure, passwordless deployment to Linode servers. The setup process involves:

1. Generating an SSH keypair locally
2. Manually adding the public key to your Linode account
3. Configuring servers in `nwp.yml`

Once configured, all deployment scripts (`stg2prod.sh`, `prod2stg.sh`) will work automatically.

## Quick Start

```bash
# 1. Generate SSH keys
./setup-ssh.sh

# 2. Follow on-screen instructions to add public key to Linode
# 3. Configure servers in nwp.yml
```

## Step-by-Step Instructions

### Step 1: Generate SSH Keys

Run the setup script:

```bash
./setup-ssh.sh
```

This will:
- Create `keys/` directory (gitignored)
- Generate `keys/nwp` (private key) and `keys/nwp.pub` (public key)
- Install private key to `~/.ssh/nwp` with correct permissions (600)
- Display the public key for manual addition

### Step 2: Add Public Key to Linode (Optional)

> **NOTE:** This step is optional for NWP. When NWP provisions servers via StackScripts, SSH keys are passed directly during creation - they don't need to be in your Linode profile.

You only need to add keys to your Linode profile if you want to:
- Create servers manually via the Linode web UI with auto-added keys
- Use Linode's rescue mode or LISH features with your keys

**To add keys to your Linode profile (optional):**

1. **Log in to Linode Cloud Manager:**
   - Go to https://cloud.linode.com

2. **Navigate to SSH Keys:**
   - Click your profile (top right)
   - Select "SSH Keys"
   - Or go directly to: https://cloud.linode.com/profile/keys

3. **Add the key:**
   - Click "Add SSH Key"
   - Enter a label (e.g., `nwp-deployment-2025`)
   - Paste the public key displayed by `setup-ssh.sh`
   - Click "Add Key"

### Step 3: Configure Servers in nwp.yml

Add your Linode server configuration:

```yaml
linode:
  servers:
    linode_primary:
      ssh_user: deploy                     # SSH username
      ssh_host: 203.0.113.10               # Server IP
      ssh_port: 22                         # SSH port (default: 22)
      ssh_key: ~/.ssh/nwp                  # Path to private key
      domains:
        - example.com
```

### Step 4: (Optional) Add Key to Existing Servers

For servers that already exist, also add the key directly:

**Option 1 - Using ssh-copy-id:**
```bash
ssh-copy-id -i ~/.ssh/nwp deploy@203.0.113.10
```

**Option 2 - Manual copy:**
```bash
cat keys/nwp.pub
# Copy the output

ssh deploy@203.0.113.10
mkdir -p ~/.ssh
chmod 700 ~/.ssh
echo "PASTE_PUBLIC_KEY_HERE" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

## Testing the Setup

Test your SSH connection:

```bash
ssh -i ~/.ssh/nwp deploy@203.0.113.10
```

If successful, you should connect without a password prompt.

## How This Enables Automated Testing

Once your SSH key is added to your Linode account:

1. **New instances get the key automatically**: When provisioning new Linode instances via the API, they will include your SSH key
2. **Tests can use real nodes**: The verification system can provision temporary Linode instances for production deployment testing
3. **Deployments work automatically**: Scripts like `stg2prod.sh` and `prod2stg.sh` can deploy without password prompts

## File Locations

| File | Location | Purpose | Git Tracked? |
|------|----------|---------|--------------|
| Private key | `~/.ssh/nwp` | SSH authentication | No |
| Private key (backup) | `keys/nwp` | Backup copy | No (gitignored) |
| Public key | `keys/nwp.pub` | For adding to servers | No (gitignored) |
| Directory marker | `keys/.gitkeep` | Track directory structure | Yes |

## Security Notes

- **Never commit private keys to git**: The `keys/` directory contents are gitignored
- **Private key permissions**: Must be 600 (read/write for owner only)
- **Public key permissions**: 644 (read for all, write for owner)
- **Keep backups**: Store your private key securely (password manager, encrypted backup)

## Troubleshooting

### Permission denied (publickey)

**Problem**: SSH connection fails with "Permission denied (publickey)"

**Solutions**:
1. Verify key is added to Linode account
2. Check private key permissions: `chmod 600 ~/.ssh/nwp`
3. Test with verbose output: `ssh -vvv -i ~/.ssh/nwp user@host`
4. Ensure public key is in server's `~/.ssh/authorized_keys`

### Key not found

**Problem**: `setup-ssh.sh` says key already exists

**Solutions**:
1. Use `-f` flag to overwrite: `./setup-ssh.sh -f`
2. Or manually remove old keys: `rm keys/nwp* ~/.ssh/nwp`

### Wrong user or host

**Problem**: Connection works but can't deploy

**Solutions**:
1. Verify `ssh_user` in `nwp.yml` matches actual server username
2. Verify `ssh_host` is correct IP or hostname
3. Test connection manually: `ssh -i ~/.ssh/nwp user@host`

## Advanced Options

Generate different key types:

```bash
# RSA 4096-bit key
./setup-ssh.sh -t rsa -b 4096

# Ed25519 key with email comment
./setup-ssh.sh -e you@example.com

# Force overwrite existing keys
./setup-ssh.sh -f

# Show help
./setup-ssh.sh -h
```

## Next Steps

After SSH setup is complete:

1. **Configure Linode API token**: Add to `.secrets.yml` for automated testing
2. **Install a site**: Run `./install.sh` to create a Drupal site
3. **Test deployments**: Use `./dev2stg.sh` to deploy to staging
4. **Deploy to production**: Use `./stg2prod.sh` when ready
5. **Run tests**: Use `pl verify --run` to test all functionality

## See Also

- [Production Deployment Guide](PRODUCTION_DEPLOYMENT.md)
- [README.md](../README.md)
- [Linode SSH Keys Documentation](https://www.linode.com/docs/products/tools/cloud-manager/guides/manage-ssh-keys/)
