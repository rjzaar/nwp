# Email Setup Guide

**Status:** ACTIVE
**Last Updated:** 2026-01-15

Complete guide for configuring email in NWP environments including SMTP, development rerouting, and deliverability testing.

## Overview

NWP provides email management tools for setting up email infrastructure, configuring site-specific email accounts, testing deliverability, and rerouting email in development environments.

## Email Commands

```bash
pl email setup                  # Setup email infrastructure
pl email add <sitename>         # Add email account for site
pl email test [sitename]        # Test email deliverability
pl email reroute <sitename>     # Configure development rerouting
pl email reroute --disable      # Disable email rerouting
pl email list                   # List configured site emails
```

## Initial Email Setup

### Production Server Setup

Set up email infrastructure on production server:

```bash
pl email setup
```

This configures:
- **Postfix** - SMTP server
- **DKIM** - DomainKeys Identified Mail
- **SPF** - Sender Policy Framework
- **DMARC** - Domain-based Message Authentication

## Site Email Configuration

### Add Email Account

Configure email for a specific site:

```bash
pl email add avc
```

Interactive prompts:
```
Site: avc
Domain: example.com
Email: noreply@example.com
Display Name: AVC Community
SMTP Host: smtp.example.com
SMTP Port: 587
SMTP User: noreply@example.com
SMTP Password: ********
Use TLS: yes
```

Configuration stored in `sites/avc/.env.local`:
```bash
SMTP_HOST=smtp.example.com
SMTP_PORT=587
SMTP_USER=noreply@example.com
SMTP_PASS=********
SMTP_TLS=true
SMTP_FROM=noreply@example.com
SMTP_FROM_NAME="AVC Community"
```

### Test Email Delivery

Test email configuration:

```bash
pl email test avc
```

Sends test email and verifies delivery:
```
═══════════════════════════════════════════════════════════════
  Email Test: avc
═══════════════════════════════════════════════════════════════

Sending test email...
  From:    noreply@example.com
  To:      admin@example.com
  Subject: Test Email from AVC

✓ Email sent successfully
✓ SMTP connection verified
✓ Delivery confirmed

Check inbox at: admin@example.com
```

## Development Email Rerouting

### Enable Email Rerouting

Prevent development/staging sites from sending email to real users:

```bash
pl email reroute avc-stg
```

Configures:
- **Mailpit** - Local email testing tool
- **Reroute Email module** - Drupal module for email interception
- **All emails** rerouted to Mailpit

Configuration:
```yaml
# sites/avc-stg/.env.local
MAILPIT_ENABLED=true
SMTP_HOST=127.0.0.1
SMTP_PORT=1025
REROUTE_EMAIL=admin@localhost
```

Access Mailpit:
```
https://avc-stg.ddev.site:8026
```

### Disable Email Rerouting

Re-enable normal email delivery:

```bash
pl email reroute --disable avc-stg
```

## Email Providers

### Common SMTP Providers

#### Gmail
```
SMTP_HOST=smtp.gmail.com
SMTP_PORT=587
SMTP_USER=your-email@gmail.com
SMTP_PASS=app-specific-password
SMTP_TLS=true
```

**Note:** Requires [app-specific password](https://support.google.com/accounts/answer/185833)

#### SendGrid
```
SMTP_HOST=smtp.sendgrid.net
SMTP_PORT=587
SMTP_USER=apikey
SMTP_PASS=your-sendgrid-api-key
SMTP_TLS=true
```

#### Mailgun
```
SMTP_HOST=smtp.mailgun.org
SMTP_PORT=587
SMTP_USER=postmaster@your-domain.mailgun.org
SMTP_PASS=your-mailgun-password
SMTP_TLS=true
```

#### AWS SES
```
SMTP_HOST=email-smtp.us-east-1.amazonaws.com
SMTP_PORT=587
SMTP_USER=your-ses-smtp-username
SMTP_PASS=your-ses-smtp-password
SMTP_TLS=true
```

## Drupal Email Configuration

### SMTP Module

NWP automatically configures the SMTP module:

```bash
# Install SMTP module (if not already)
ddev drush pm:install smtp

# Configure via environment variables
# (automatic via .env.local)
```

### Test Email from Drupal

```bash
# Send test email via Drush
ddev drush smtp:test admin@example.com
```

## Email Best Practices

### Development
- Always use email rerouting
- Use Mailpit for testing
- Never send to real users from dev/staging
- Test all email templates in Mailpit

### Production
- Use dedicated SMTP service (SendGrid, Mailgun, SES)
- Configure SPF, DKIM, DMARC
- Monitor email delivery rates
- Set up bounce handling
- Use queue for bulk emails

### Security
- Never commit email credentials to git
- Use `.env.local` for credentials (gitignored)
- Rotate passwords regularly
- Use app-specific passwords when available
- Enable TLS for all SMTP connections

## Email Reply System (AVC)

The AVC profile includes an email reply system that allows users to respond to notification emails and have their replies posted as comments on content.

### Overview

When users receive notification emails about group content (workflow updates, comments, etc.), they can reply directly to the email to post a comment. The reply is processed through a secure webhook and creates a comment on the original content.

### Architecture

```
Outbound: Notification → Reply-To: reply+{token}@domain → User Inbox
Inbound:  User Reply → Webhook /api/email/inbound → Queue → Comment
```

### Configuration

#### Via Recipe (nwp.yml)

```yaml
recipes:
  avc-dev:
    email_reply:
      enabled: true
      reply_domain: "reply.example.com"
      email_provider: sendgrid
      token_expiry_days: 30
      debug_mode: true
```

#### Via Drush

```bash
# Check status
ddev drush email-reply:status

# Enable with domain
ddev drush email-reply:enable --domain=reply.example.com

# Configure settings
ddev drush email-reply:configure --domain=reply.example.com --provider=sendgrid
```

#### Via Admin UI

Navigate to `/admin/config/avc/email-reply` to configure:
- Enable/disable email reply
- Set reply domain
- Configure rate limits
- Set spam score threshold

### Email Provider Setup

#### SendGrid Inbound Parse

1. Create Inbound Parse webhook in SendGrid dashboard
2. Configure MX record: `reply.example.com → mx.sendgrid.net`
3. Set webhook URL: `https://yoursite.com/api/email/inbound`
4. Copy webhook verification key to settings

#### Mailgun Routes

1. Create a route in Mailgun dashboard
2. Configure MX record to Mailgun servers
3. Set webhook URL: `https://yoursite.com/api/email/inbound`
4. Configure webhook signing key

### Testing in DDEV

DDEV environments include built-in email reply testing:

```bash
# Quick start
ddev email-reply-test setup    # Create test data
ddev email-reply-test test     # Run automated test

# Manual testing
ddev email-reply-test simulate <node_id> <user_id> "My reply"
ddev email-reply-test webhook <token> <email> "Reply text"

# Management
ddev email-reply-test status   # Check status
ddev email-reply-test queue    # Process queue
```

Web UI testing: `/admin/config/avc/email-reply/test`

### Security Features

- **Token Authentication**: HMAC-SHA256 signed tokens with 30-day expiration
- **Email Verification**: Sender email must match user in token
- **Group Membership**: Verifies user is still a group member
- **Spam Filtering**: Rejects emails with spam score > 5.0
- **Rate Limiting**: 10/hour, 50/day per user; 100/hour per group
- **Content Sanitization**: HTML filtering before comment creation

### Email Reply Commands

| Command | Description |
|---------|-------------|
| `email-reply:status` | Check system status |
| `email-reply:enable` | Enable email reply |
| `email-reply:disable` | Disable email reply |
| `email-reply:configure` | Configure settings |
| `email-reply:generate-token` | Generate test token |
| `email-reply:simulate` | Simulate email reply |
| `email-reply:process-queue` | Process queue manually |
| `email-reply:test` | Run end-to-end test |

### Troubleshooting Email Reply

#### Replies Not Being Processed

1. Check if enabled: `ddev drush email-reply:status`
2. Check queue: `ddev drush queue:list`
3. Process manually: `ddev drush queue:run avc_email_reply`
4. Check logs: `ddev drush watchdog:show --type=avc_email_reply`

#### Invalid Token Errors

- Token may have expired (default: 30 days)
- User email doesn't match token
- Token was tampered with

#### Rate Limiting

Check remaining quota in status output and adjust limits if needed for testing.

## Troubleshooting

### Email Not Sending

**Symptom:**
```
ERROR: Failed to send email
```

**Solution:**
1. Check SMTP credentials
2. Verify SMTP host/port
3. Test connection: `telnet smtp.example.com 587`
4. Check firewall rules
5. Review Drupal logs: `ddev drush watchdog:show`

### Emails Going to Spam

**Symptom:**
Emails delivered but marked as spam

**Solution:**
- Configure SPF record for domain
- Enable DKIM signing
- Set up DMARC policy
- Use authenticated SMTP service
- Avoid spam trigger words

### Mailpit Not Accessible

**Symptom:**
```
Cannot access https://avc-stg.ddev.site:8026
```

**Solution:**
```bash
# Restart DDEV
ddev restart

# Check Mailpit container
docker ps | grep mailpit

# View Mailpit logs
ddev logs -s mailpit
```

### SMTP Authentication Failed

**Symptom:**
```
ERROR: SMTP authentication failed
```

**Solution:**
- Verify username/password
- Check for app-specific password requirement (Gmail)
- Confirm account is not locked
- Try different SMTP port (587, 465, 2525)

## Configuration Files

### Site Email Config

`sites/avc/.env.local`:
```bash
# SMTP Configuration
SMTP_HOST=smtp.example.com
SMTP_PORT=587
SMTP_USER=noreply@example.com
SMTP_PASS=********
SMTP_TLS=true

# From Address
SMTP_FROM=noreply@example.com
SMTP_FROM_NAME="AVC Community"

# Development: Mailpit
MAILPIT_ENABLED=false
```

### Global Email Settings

`nwp.yml`:
```yaml
settings:
  email:
    provider: sendgrid
    from_domain: example.com
    reroute_dev: true
```

## Related Commands

- [email](../reference/commands/email.md) - Email command reference
- [dev2stg](../reference/commands/dev2stg.md) - Staging deployment (auto-configures email rerouting)

## See Also

- [Drupal SMTP Module](https://www.drupal.org/project/smtp) - SMTP module documentation
- [Mailpit](https://github.com/axllent/mailpit) - Email testing tool
- [SPF Record](https://www.spf-record.com/) - SPF configuration tool
- [DMARC Guide](https://dmarc.org/) - DMARC documentation
- [AVC Email Reply Module](../../sites/avc/html/profiles/custom/avc/modules/avc_features/avc_email_reply/README.md) - Detailed email reply documentation
- [SendGrid Inbound Parse](https://docs.sendgrid.com/for-developers/parsing-email/setting-up-the-inbound-parse-webhook) - SendGrid webhook setup
- [Mailgun Routes](https://documentation.mailgun.com/en/latest/api-routes.html) - Mailgun routing configuration
