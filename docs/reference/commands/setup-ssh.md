# setup-ssh

**Last Updated:** 2026-01-14

Generate project-specific SSH keys for Linode deployment and server access.

## Synopsis

```bash
pl setup-ssh [options]
```

## Description

The `setup-ssh` command generates SSH keypairs specifically for NWP deployments to Linode servers. It creates keys in the `keys/` directory, installs them to `~/.ssh/`, and provides instructions for adding them to your Linode account.

By default, it generates Ed25519 keys (modern, secure, fast) but supports RSA for compatibility with older systems.

The script includes automated key distribution to configured servers in `nwp.yml` via SSH, making it easy to provision access to existing servers.

## Arguments

None. All configuration is through options.

## Options

| Option | Description | Default |
|--------|-------------|---------|
| `-f, --force` | Overwrite existing keys without prompting | false |
| `-t, --type TYPE` | Key type: `ed25519` or `rsa` | `ed25519` |
| `-b, --bits BITS` | Key size for RSA: `2048` or `4096` | `4096` |
| `-e, --email EMAIL` | Email address for key comment | `nwp-deployment` |
| `-h, --help` | Show help message | - |

## Key Types

### Ed25519 (Recommended)

- **Modern**: Based on elliptic curve cryptography
- **Secure**: Equivalent to RSA 3072-bit security
- **Fast**: Faster key generation and authentication
- **Compact**: Smaller key size (68 characters vs 544+)
- **Support**: OpenSSH 6.5+ (2014), GitHub, GitLab, Linode

### RSA

- **Compatible**: Works with older SSH implementations
- **Proven**: Long track record of security
- **Larger**: 2048-bit minimum, 4096-bit recommended
- **Slower**: Slower operations than Ed25519
- **Use When**: Legacy systems or specific compatibility requirements

## Examples

### Generate Default Ed25519 Key

```bash
pl setup-ssh
```

Creates Ed25519 keypair:
- Private: `keys/nwp` and `~/.ssh/nwp`
- Public: `keys/nwp.pub`

### Generate with Email

```bash
pl setup-ssh -e alice@example.com
```

Key comment will be `alice@example.com` instead of `nwp-deployment`.

### Generate RSA 4096 Key

```bash
pl setup-ssh -t rsa -b 4096
```

Creates RSA 4096-bit keypair for maximum compatibility.

### Force Overwrite Existing Keys

```bash
pl setup-ssh -f
```

Overwrites existing keys without prompting.

### Generate RSA with Email

```bash
pl setup-ssh -t rsa -e deploy@company.com
```

Combines RSA type with custom email comment.

## Output

### Step 1: Create Keys Directory

```
═══════════════════════════════════════════════════════════════
  Step 1: Create Keys Directory
═══════════════════════════════════════════════════════════════

[✓] Keys directory exists: /home/rob/nwp/keys
```

### Step 2: Check Existing Keys

```
═══════════════════════════════════════════════════════════════
  Step 2: Check Existing Keys
═══════════════════════════════════════════════════════════════

[!] SSH keys already exist:
  - /home/rob/nwp/keys/nwp
  - /home/rob/nwp/keys/nwp.pub
  - /home/rob/.ssh/nwp

Overwrite existing keys? (y/N)
```

### Step 3: Generate SSH Keypair

```
═══════════════════════════════════════════════════════════════
  Step 3: Generate SSH Keypair
═══════════════════════════════════════════════════════════════

[i] Generating Ed25519 key (modern, secure, fast)
Generating public/private ed25519 key pair.
Your identification has been saved in /home/rob/nwp/keys/nwp
Your public key has been saved in /home/rob/nwp/keys/nwp.pub

[✓] Keypair generated successfully
[i] Private key: /home/rob/nwp/keys/nwp
[i] Public key: /home/rob/nwp/keys/nwp.pub
```

### Step 4: Set Permissions

```
═══════════════════════════════════════════════════════════════
  Step 4: Set Permissions
═══════════════════════════════════════════════════════════════

[✓] Key permissions set (private: 600, public: 644)
```

### Step 5: Install Private Key

```
═══════════════════════════════════════════════════════════════
  Step 5: Install Private Key
═══════════════════════════════════════════════════════════════

[✓] Private key installed to: /home/rob/.ssh/nwp
```

### Setup Complete

```
═══════════════════════════════════════════════════════════════
  Setup Complete!
═══════════════════════════════════════════════════════════════

✓ SSH keys generated and installed

Public key for deployment:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILx... nwp-deployment
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### Step 7: Add SSH Key to Linode

```
═══════════════════════════════════════════════════════════════
  Step 7: Add SSH Key to Linode
═══════════════════════════════════════════════════════════════

IMPORTANT: You must manually add this SSH key to your Linode account

Follow these steps:

1. Log in to Linode Cloud Manager:
   https://cloud.linode.com

2. Go to your Profile → SSH Keys:
   https://cloud.linode.com/profile/keys

3. Click "Add SSH Key"

4. Enter a label (e.g., "nwp-deployment-20260114")

5. Paste your public key:

   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
   ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILx... nwp-deployment
   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

6. Click "Add Key"

[✓] Once added, the key will be available for all new Linode instances
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success - keys generated and installed |
| 1 | Error - invalid options, key generation failed, or user cancelled |

## Prerequisites

- `ssh-keygen` command (part of OpenSSH, pre-installed on most systems)
- Write access to project `keys/` directory
- Write access to `~/.ssh/` directory

## File Locations

### Project Keys

Keys are created in the project `keys/` directory (gitignored):

```
/home/rob/nwp/keys/
  ├── nwp         # Private key (600)
  └── nwp.pub     # Public key (644)
```

### User SSH Directory

Private key is copied to user's SSH directory:

```
~/.ssh/
  └── nwp         # Private key (600)
```

This allows the key to be used from any directory:

```bash
ssh -i ~/.ssh/nwp user@server
```

## Security Considerations

### Private Key Protection

- Private keys have `600` permissions (owner read/write only)
- Never share or commit private keys
- Keys in `keys/` directory are gitignored
- Keep backups of private keys in secure storage

### Key Generation

- Uses `/dev/urandom` for entropy (secure random generation)
- No passphrase by default for automation
- Add passphrase manually for extra security:
  ```bash
  ssh-keygen -p -f ~/.ssh/nwp
  ```

### SSH Security Warning

On first use, the script calls `show_ssh_security_warning()` from `lib/ssh.sh`:

```
⚠ SSH Security Warning
```

This reminds users to verify host keys on first connection.

## Manual Key Distribution

### Option 1: ssh-copy-id (Easiest)

```bash
ssh-copy-id -i ~/.ssh/nwp user@your-server
```

Automatically appends public key to remote `~/.ssh/authorized_keys`.

### Option 2: Manual Copy

```bash
ssh user@your-server 'mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys'
# Paste public key contents, then Ctrl+D
```

### Option 3: Copy from File

```bash
cat /home/rob/nwp/keys/nwp.pub
# Copy the output
# Manually append to remote ~/.ssh/authorized_keys
```

## Automated Key Distribution

The script can push keys to servers defined in `nwp.yml`:

```yaml
linode:
  servers:
    prod1:
      ssh_user: deploy
      ssh_host: 192.0.2.10
      ssh_port: 22
      ssh_key: ~/.ssh/old_key  # Used to connect and push new key
```

When servers are configured, the script:

1. Reads server configurations from `nwp.yml`
2. Connects using existing credentials
3. Appends new public key to `~/.ssh/authorized_keys`
4. Verifies successful installation

This is handled by the `push_key_to_server()` function.

## Adding Key to Linode Account

### Web Interface Method

1. Visit https://cloud.linode.com/profile/keys
2. Click "Add SSH Key"
3. Label: `nwp-deployment-YYYYMMDD`
4. Paste contents of `keys/nwp.pub`
5. Click "Add Key"

### CLI Method (if linode-cli installed)

```bash
linode-cli sshkeys create \
  --label "nwp-deployment" \
  --ssh_key "$(cat keys/nwp.pub)"
```

### Effect

- New Linode instances automatically include this key
- Provisioning scripts can access new instances without manual key distribution
- Enables automated deployments and testing on temporary instances

## Configuring for Deployment

After generating keys, update `nwp.yml` for each deployment target:

```yaml
linode:
  servers:
    prod1:
      ssh_user: deploy
      ssh_host: 192.0.2.10
      ssh_port: 22
      ssh_key: ~/.ssh/nwp  # Use new key

sites:
  mysite:
    live:
      enabled: true
      server: prod1  # References server above
```

## Notes

- **Key naming**: Keys are always named `nwp` for consistency
- **Multiple keys**: For multiple NWP installations, use different key names manually
- **Gitignored**: The `keys/` directory is in `.gitignore` - keys never committed
- **Backup keys**: Keep secure backups of private keys (encrypted storage)
- **Rotation**: Rotate keys periodically for security best practices
- **SSH agent**: Add to SSH agent for convenience: `ssh-add ~/.ssh/nwp`

## Troubleshooting

### Permission Denied (publickey)

**Symptom:** Cannot connect to server after adding key

**Solution:**
1. Verify key is on server: `ssh user@server 'cat ~/.ssh/authorized_keys'`
2. Check key permissions: `ls -la ~/.ssh/nwp` (should be 600)
3. Try explicit key: `ssh -i ~/.ssh/nwp user@server`
4. Check server logs: `sudo tail /var/log/auth.log`

### Key Already Exists

**Symptom:** Script finds existing keys

**Solution:**
1. Use `-f` to force overwrite: `pl setup-ssh -f`
2. Or backup existing keys manually:
   ```bash
   mv keys/nwp keys/nwp.backup
   mv ~/.ssh/nwp ~/.ssh/nwp.backup
   ```
3. Re-run: `pl setup-ssh`

### SSH Connection Timeout

**Symptom:** Cannot connect to push key to server

**Solution:**
1. Check server is reachable: `ping server.example.com`
2. Check firewall allows SSH: `telnet server.example.com 22`
3. Verify SSH port in `nwp.yml` is correct
4. Try manual connection first: `ssh user@server`

### Public Key Won't Add to Linode

**Symptom:** Linode rejects public key

**Solution:**
1. Verify key format: Public key should start with `ssh-ed25519` or `ssh-rsa`
2. Check for line breaks: Key must be single line
3. Copy entire key including comment
4. Try pasting in a text editor first to check formatting

### Wrong Key Type Generated

**Symptom:** Generated RSA but wanted Ed25519 (or vice versa)

**Solution:**
1. Delete keys: `rm keys/nwp* ~/.ssh/nwp`
2. Re-run with correct type: `pl setup-ssh -t ed25519`

## Related Commands

- [setup.md](./setup.md) - Install NWP prerequisites
- [live-deploy.md](./live-deploy.md) - Deploy to production using SSH keys

## See Also

- [Linode Setup Guide](../../deployment/linode-setup.md) - Complete Linode deployment workflow
- [SSH Key Management](../../security/ssh-key-management.md) - SSH key security best practices
- [OpenSSH Documentation](https://www.openssh.com/) - SSH protocol and tools
- [Ed25519 vs RSA](https://blog.g3rt.nl/upgrade-your-ssh-keys.html) - Key type comparison
