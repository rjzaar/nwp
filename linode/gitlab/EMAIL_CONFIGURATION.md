# GitLab Email Configuration

## Overview

Email is now **automatically configured** during GitLab server installation.

## Quick Start

### Create GitLab Server with Email

```bash
# Basic - email configured, DNS manual
./gitlab_create_server.sh --domain git.example.com --email admin@example.com

# With automatic DNS (recommended)
./gitlab_create_server.sh --domain git.example.com --email admin@example.com --linode-api-token "YOUR_TOKEN"

# Skip email configuration
./gitlab_create_server.sh --domain git.example.com --email admin@example.com --no-email
```

## What Gets Configured

✅ **Postfix** - SMTP server (ports 25, 587)
✅ **OpenDKIM** - DKIM email signing
✅ **SPF Record** - Sender authentication
✅ **DKIM Record** - Public key for verification
✅ **DMARC Record** - Email policy (quarantine)
✅ **MX Record** - Email routing
✅ **GitLab SMTP** - Configured to use local Postfix
✅ **Test Email** - Sent to admin during setup

## Email Addresses

- `git@yourdomain.com` - GitLab notifications (forwards to admin)
- `noreply@yourdomain.com` - Reply-to address

## After Installation

### Check Status
```bash
ssh git-server
~/welcome.sh  # Shows email configuration status
```

### View Configuration
```bash
sudo cat /root/email_setup_info.txt
```

### Test Email
```bash
echo "Test" | mail -s "Test" -r "git@yourdomain.com" your@email.com
```

### Check Logs
```bash
sudo grep postfix /var/log/syslog | tail -20
```

## GitLab Email Features

With email configured, GitLab can now send:

- ✅ Password reset emails
- ✅ Issue notifications
- ✅ Merge request notifications
- ✅ Pipeline status emails
- ✅ Account confirmation emails
- ✅ Security alerts

## Automatic vs Manual DNS

### With API Token (Automatic)
```bash
--linode-api-token "YOUR_TOKEN"
```
DNS records (SPF, DKIM, DMARC, MX) created automatically.

### Without API Token (Manual)
DNS records must be added manually from `/root/email_setup_info.txt`.

### Using .secrets.yml
Add to `.secrets.yml` for auto-detection:
```yaml
linode:
  api_token: "YOUR_TOKEN"
```

## Upgrade Existing Servers

For GitLab servers without email:

```bash
# Copy setup script
scp email/setup_email.sh git-server:~/

# Run on server
ssh git-server
sudo ./setup_email.sh

# Reconfigure GitLab
sudo gitlab-ctl reconfigure
```

## Troubleshooting

### Services Not Running
```bash
sudo systemctl status postfix
sudo systemctl status opendkim
sudo systemctl restart postfix opendkim
```

### Email Not Delivered
```bash
# Check logs
sudo grep postfix /var/log/syslog | tail -50

# Check queue
mailq

# Test DKIM
sudo opendkim-testkey -d yourdomain.com -s default -vvv
```

### Low mail-tester.com Score
1. Wait 5-10 minutes for DNS propagation
2. Check all DNS records are configured
3. Verify PTR (reverse DNS) is set
4. Test: `echo "Test" | mail -s "Test" -r "git@yourdomain.com" test-XXXXX@srv1.mail-tester.com`

## Files

- `/root/email_setup_info.txt` - Configuration summary and DNS records
- `/root/gitlab_credentials.txt` - GitLab login credentials
- `/var/log/syslog` - Email delivery logs
- `/etc/postfix/main.cf` - Postfix configuration
- `/etc/opendkim.conf` - OpenDKIM configuration

## Command Reference

```bash
# Server creation with email
./gitlab_create_server.sh --domain git.example.com --email admin@example.com

# Upload updated stackscript
./gitlab_upload_stackscript.sh

# Check email on server
ssh git-server "sudo grep postfix /var/log/syslog | tail -20"

# Test email sending
ssh git-server "echo 'Test' | mail -s 'Test' -r 'git@yourdomain.com' your@email.com"

# View email configuration
ssh git-server "sudo cat /root/email_setup_info.txt"
```

## See Also

- `EMAIL_POSTFIX_PROPOSAL.md` - Full email infrastructure design
- `email/setup_email.sh` - Standalone email setup script
- `gitlab_server_setup.sh` - StackScript with email configuration (section 8.7)
