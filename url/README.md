# URL Setup for NWP

This directory contains scripts for managing URL configuration and GitLab deployment based on the `urluse` and `url` settings in `cnwp.yml`.

## Overview

The URL setup system checks your NWP configuration and helps you:
- Verify if your URL is pointing to Linode
- Check DNS configuration
- Set up GitLab CE at `git.[your-url]` on Linode

## Quick Start

```bash
# Run the URL setup check
./url_setup.sh

# Run with auto-confirm
./url_setup.sh -y

# Verbose output
./url_setup.sh -v
```

## Configuration

The script reads from `cnwp.yml` in the NWP root directory:

```yaml
settings:
  # urluse: testing/gitlab/all. If left blank it means no use.
  urluse: gitlab
  # url is for providing live tests and nwp site.
  url: example.com
```

### urluse Options

- `gitlab` - Enable GitLab setup only
- `all` - Enable all URL-based features (including GitLab)
- `testing` - Enable testing features
- *(blank)* - No URL-based features enabled

## What the Script Does

### 1. Configuration Check
- Reads `urluse` and `url` from `cnwp.yml`
- Validates that both are set appropriately
- Exits early if `urluse` is not `gitlab` or `all`

### 2. DNS Analysis
- Performs DNS lookup on the configured URL
- Gets the IP address (if any)
- Reports whether DNS is configured

### 3. Linode Detection
- Checks if the IP belongs to Linode using:
  - Reverse DNS lookup
  - WHOIS data (if available)
- Reports whether the URL is already pointing to Linode

### 4. GitLab Setup Offer
- If appropriate, offers to set up GitLab on Linode
- Creates GitLab at `git.[your-url]`
- Provides DNS configuration instructions

## Example Scenarios

### Scenario 1: No DNS Yet
```
url: mynwpsite.com
Status: No IP found

Action: Offer to create GitLab server, show IP to configure DNS
```

### Scenario 2: Already on Linode
```
url: mynwpsite.com
Status: IP 172.105.x.x (Linode)

Action: Check if git.mynwpsite.com exists, offer to set up if not
```

### Scenario 3: Pointing Elsewhere
```
url: mynwpsite.com
Status: IP 192.168.x.x (not Linode)

Action: Offer to set up GitLab, note DNS will need updating
```

## GitLab Setup Process

When you choose to set up GitLab, the script will:

1. **Run GitLab Environment Setup** (`git/gitlab_setup.sh`)
   - Install Linode CLI
   - Configure API access
   - Set up SSH keys

2. **Create GitLab Server** (`git/gitlab_create_server.sh`)
   - Create a Linode server
   - Install GitLab CE
   - Install GitLab Runner
   - Configure with your domain

3. **Provide Next Steps**
   - Wait for installation (10-15 minutes)
   - Configure DNS A record
   - Access GitLab
   - Get initial credentials

## DNS Configuration

After GitLab server creation, you'll need to add DNS records:

```
Type: A
Name: git.example.com
Value: [Server IP from script output]
TTL: 300 (or your preference)
```

## Options

```
-h, --help       Show help message
-v, --verbose    Enable verbose output (shows DNS lookups, etc.)
-y, --yes        Skip confirmation prompts
-c, --config     Specify custom config file (default: ../cnwp.yml)
```

## Examples

### Check URL configuration
```bash
./url_setup.sh
```

### Automated setup
```bash
./url_setup.sh -y
```

### Use custom config file
```bash
./url_setup.sh -c /path/to/custom.yml
```

### Debug mode
```bash
./url_setup.sh -v
```

## Requirements

### Required
- `dig` command (DNS lookup)
  ```bash
  sudo apt-get install dnsutils
  ```

### Optional (for better Linode detection)
- `whois` command
  ```bash
  sudo apt-get install whois
  ```

## Integration with NWP Workflow

### 1. Initial Setup
```bash
# Edit configuration
nano cnwp.yml

# Set urluse and url
urluse: gitlab
url: mynwpsite.com

# Run URL setup
cd url
./url_setup.sh
```

### 2. After GitLab Installation
```bash
# Get GitLab credentials
ssh gitlab@[server-ip] 'sudo cat /root/gitlab_credentials.txt'

# Log in to GitLab
# Username: root
# Password: [from credentials file]
```

### 3. Configure Your Projects
```bash
# Add GitLab as remote for your NWP projects
cd ~/nwp/myproject
git remote add gitlab git@git.mynwpsite.com:root/myproject.git
git push gitlab main
```

## Related Scripts

- `../git/gitlab_setup.sh` - Sets up Linode CLI and environment
- `../git/gitlab_create_server.sh` - Creates GitLab server on Linode
- `../git/gitlab_upload_stackscript.sh` - Uploads GitLab StackScript
- `../git/gitlab_server_setup.sh` - Server configuration script (runs on server)

## Troubleshooting

### DNS lookup fails
```
Error: No IP address found for example.com
```
**Solution:** The domain doesn't have DNS records yet. You can still proceed with setup and configure DNS later.

### Linode CLI not found
```
Error: linode-cli not found
```
**Solution:** The script will run `gitlab_setup.sh` to install and configure it.

### Permission denied
```
Error: Permission denied
```
**Solution:** Make sure the script is executable:
```bash
chmod +x url_setup.sh
```

### GitLab subdomain already exists
```
Warning: git.example.com already has an IP
```
**Solution:** Check if GitLab is already running at that address. You may have already set it up.

## Security Notes

- The script performs read-only DNS and WHOIS lookups
- Linode API access requires your token (set up during gitlab_setup.sh)
- SSH keys are created in `git/keys/` directory
- GitLab credentials are stored on the server at `/root/gitlab_credentials.txt`
- Change the initial root password immediately after first login

## Support

For issues or questions:
1. Run with `-v` flag for verbose output
2. Check the GitLab setup logs on the server: `/var/log/gitlab-setup.log`
3. Review the GitLab documentation in `../git/docs/`

## License

Part of the Narrow Way Project (NWP)
