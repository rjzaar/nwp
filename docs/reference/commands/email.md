# email

**Last Updated:** 2026-01-14

Unified interface for email setup, testing, and configuration for NWP sites.

## Overview

The `email` command provides a centralized interface for managing email infrastructure, including server setup, site-specific email accounts, deliverability testing, and development email rerouting.

## Synopsis

```bash
pl email <command> [options]
```

## Commands

| Command | Description |
|---------|-------------|
| `setup` | Setup email infrastructure (Postfix, DKIM, SPF) |
| `add <sitename>` | Add email account for a site |
| `test [sitename]` | Test email deliverability |
| `reroute <sitename>` | Configure email rerouting for development |
| `reroute --disable` | Disable email rerouting |
| `list` | List configured site emails |

## Options

| Option | Description |
|--------|-------------|
| `-h, --help` | Show help message |
| `--disable` | Disable email rerouting (with reroute command) |

## Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `sitename` | Conditional | Site identifier (required for add, test, reroute) |

## Examples

### Initial Server Email Setup

```bash
pl email setup
```

Configures server-wide email infrastructure including Postfix, DKIM signing, and SPF records.

### Add Email Account for Site

```bash
pl email add mysite
```

Creates email configuration for a specific site, typically `noreply@sitedomain.com`.

### Test Email Deliverability

```bash
pl email test mysite
```

Sends test email and checks deliverability, DKIM signing, and SPF validation.

### Test All Email Configuration

```bash
pl email test
```

Runs comprehensive email testing across all configured sites.

### Configure Development Email Rerouting

```bash
pl email reroute mysite
```

Routes all outgoing email to Mailpit for development/staging environments.

### Disable Email Rerouting

```bash
pl email reroute --disable
```

Removes email rerouting configuration, allowing normal email delivery.

### List Configured Emails

```bash
pl email list
```

Display all site-specific email configurations.

## Email Setup Process

The `setup` command configures:

### 1. Postfix MTA

- Installs Postfix if not present
- Configures SMTP relay settings
- Sets up hostname and domain
- Enables TLS encryption

### 2. DKIM Signing

- Generates DKIM keys for domain
- Configures OpenDKIM
- Creates DNS TXT records for verification
- Enables message signing

### 3. SPF Records

- Generates SPF record for domain
- Provides DNS TXT record for publication
- Validates SPF configuration

### 4. DMARC Policy

- Creates DMARC policy record
- Configures reporting addresses
- Sets policy (quarantine/reject)

## Email Testing

The `test` command performs:

### Deliverability Checks

- Sends test message to specified address
- Verifies SMTP connection
- Checks message queue status

### Authentication Verification

- Validates DKIM signature
- Checks SPF record
- Verifies DMARC alignment

### DNS Configuration

- Queries MX records
- Validates DKIM TXT record
- Checks SPF record syntax

### Results Reporting

- Pass/fail status for each check
- Detailed error messages
- Recommendations for fixes

## Email Rerouting (Development)

Rerouting prevents test emails from reaching real users:

### Mailpit Integration

```bash
pl email reroute mysite
```

Configures Drupal to send all email to Mailpit (SMTP capture tool).

### Rerouting Configuration

Sets in Drupal configuration:
- SMTP host: `localhost:1025`
- All emails captured locally
- Original recipients visible in headers
- No external delivery

### Web Interface

Access captured emails:
```
http://localhost:8025
```

### Disabling Rerouting

```bash
pl email reroute --disable
```

Restores normal email delivery for production deployments.

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | General error (configuration failed, test failed) |

## Prerequisites

### For Setup

- Root or sudo access
- Ubuntu/Debian system (uses apt)
- Domain with DNS management access
- Open port 25 (SMTP) on firewall

### For Add

- Email setup completed (`pl email setup`)
- Valid domain configured for site
- DNS A record pointing to server

### For Test

- Email setup completed
- DKIM keys generated
- SPF/DKIM DNS records published
- Test email recipient address

### For Reroute

- Mailpit installed and running
- DDEV environment (typically)
- Drupal SMTP module or reroute module

## Email Infrastructure Files

### Postfix Configuration

```
/etc/postfix/main.cf
/etc/postfix/master.cf
```

### DKIM Keys

```
/etc/opendkim/keys/<domain>/
├── default.private
└── default.txt
```

### OpenDKIM Configuration

```
/etc/opendkim.conf
/etc/opendkim/TrustedHosts
/etc/opendkim/KeyTable
/etc/opendkim/SigningTable
```

### Site Email Configuration

Stored in `cnwp.yml`:

```yaml
sites:
  mysite:
    email:
      from: "noreply@mysite.com"
      smtp_host: "localhost"
      smtp_port: 25
```

## Troubleshooting

### Setup Fails with Permission Error

**Symptom:** Permission denied during setup

**Solution:**
```bash
# Run with sudo
sudo -E pl email setup

# Or as root
su -
pl email setup
```

### DKIM Test Fails

**Symptom:** DKIM signature not valid

**Solution:**
1. Verify DNS TXT record published: `dig TXT default._domainkey.mysite.com`
2. Wait for DNS propagation (up to 48 hours)
3. Check OpenDKIM service: `systemctl status opendkim`
4. Review logs: `tail /var/log/mail.log`
5. Validate DKIM key permissions: `ls -la /etc/opendkim/keys/`

### SPF Test Fails

**Symptom:** SPF validation fails

**Solution:**
1. Check SPF record: `dig TXT mysite.com`
2. Ensure SPF includes server IP: `v=spf1 ip4:1.2.3.4 ~all`
3. Validate syntax at: https://www.kitterman.com/spf/validate.html
4. Remove duplicate SPF records (only one allowed)

### Email Not Sending

**Symptom:** Test email never arrives

**Solution:**
1. Check mail queue: `mailq`
2. Review mail logs: `tail -f /var/log/mail.log`
3. Verify Postfix running: `systemctl status postfix`
4. Test Postfix: `echo "Test" | sendmail user@example.com`
5. Check firewall: `sudo ufw status | grep 25`

### Mailpit Not Capturing Email

**Symptom:** Email not appearing in Mailpit interface

**Solution:**
1. Verify Mailpit running: `ddev describe`
2. Check SMTP configuration in Drupal
3. Review Drupal error logs: `pl drush mysite watchdog-show`
4. Test SMTP connection: `telnet localhost 1025`
5. Ensure reroute configuration active

### Reroute Not Disabling

**Symptom:** Emails still going to Mailpit after disable

**Solution:**
1. Clear Drupal config cache: `pl drush mysite cr`
2. Verify reroute module disabled: `pl drush mysite pml | grep reroute`
3. Check SMTP settings manually in Drupal admin
4. Export config: `pl drush mysite cex -y`

### DNS Records Not Propagating

**Symptom:** DKIM/SPF tests fail despite adding records

**Solution:**
1. Wait 24-48 hours for full propagation
2. Check from multiple locations: https://dnschecker.org/
3. Verify record syntax (no typos)
4. Flush local DNS cache: `sudo systemd-resolve --flush-caches`
5. Query authoritative nameserver directly

## Best Practices

### Use Separate Domain for Email

```bash
# Instead of noreply@mysite.com
# Use mysite.com email subdomain
noreply@mail.mysite.com
```

### Implement DMARC Monitoring

Add DMARC record with reporting:

```
_dmarc.mysite.com TXT "v=DMARC1; p=quarantine; rua=mailto:dmarc@mysite.com"
```

### Test Regularly

```bash
# Weekly cron job
0 8 * * 1 /path/to/nwp/pl email test | mail -s "Weekly Email Test" admin@example.com
```

### Use Rerouting for All Non-Production

```bash
# Development and staging
pl email reroute mysite-dev
pl email reroute mysite-stg

# Production only - no rerouting
# pl email reroute mysite-prod  # DON'T DO THIS
```

### Monitor Email Reputation

- Use online tools: mail-tester.com, mxtoolbox.com
- Monitor bounce rates
- Check spam complaint rates
- Watch for blacklist inclusion

## Automation Examples

### Setup Email for All Sites

```bash
#!/bin/bash
# Setup email infrastructure once
pl email setup

# Add email for each site
for site in $(ls sites/); do
  pl email add "$site"
done
```

### Daily Email Health Check

```bash
#!/bin/bash
# Test email and alert if fails
if ! pl email test mysite > /tmp/email-test.log 2>&1; then
  mail -s "Email Test Failed" admin@example.com < /tmp/email-test.log
fi
```

## Notes

- Email setup requires root/sudo access
- DKIM keys are generated per domain
- DNS changes may take 24-48 hours to propagate
- Mailpit is for development only (not production)
- Email commands delegate to scripts in `email/` directory
- Multiple sites can share domain email configuration
- Rerouting affects all email, including admin notifications

## Performance Considerations

- Email sending is asynchronous (queued)
- Large email volumes may require mail relay service
- DKIM signing adds minimal overhead
- Mailpit has no volume limits for development
- Production should use dedicated email service for high volume

## Security Implications

- DKIM prevents email spoofing
- SPF prevents unauthorized sending
- DMARC enforces authentication policies
- Postfix should restrict relay to localhost
- Email logs may contain sensitive data
- Mailpit captures all email content (development only)
- Production email should use TLS encryption
- Store SMTP credentials in `.secrets.data.yml` (not `.secrets.yml`)

## Related Commands

- [config.sh](config.md) - Configure Drupal email settings
- [drush.sh](drush.md) - Manage Drupal via drush
- [test.sh](test.md) - Run test suite

## See Also

- [Email Setup Guide](../../guides/email-setup.md) - Detailed email configuration
- [DKIM/SPF/DMARC Guide](../../guides/email-authentication.md) - Email authentication
- [Mailpit Documentation](https://github.com/axllent/mailpit) - Mailpit SMTP capture
- [Postfix Configuration](../../deployment/postfix-setup.md) - Postfix MTA setup
- [Email Testing Guide](../../testing/email-testing.md) - Testing email deliverability
