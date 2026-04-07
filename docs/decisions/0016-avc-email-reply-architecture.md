# ADR-0016: AVC Email Reply Architecture

**Status:** Accepted
**Date:** 2026-01-15
**Decision Makers:** Development Team
**Related Issues:** AVC Email Reply Implementation

## Context

AVC group members receive notification emails about content updates, comments, and workflow changes. To increase engagement and reduce friction, we want users to be able to reply directly to these emails to post comments without logging into the site.

Key challenges:
1. **Security**: Email replies must be authenticated to prevent spoofing
2. **Reliability**: Email delivery is asynchronous and can be delayed
3. **Spam Prevention**: Must filter spam and prevent abuse
4. **Provider Independence**: Should work with multiple email providers
5. **Testing**: Must be testable in development without external email infrastructure

## Options Considered

### Option 1: Direct Email Processing via Drupal Mail

- **Pros:**
  - Simple implementation
  - No external dependencies
  - No token management needed
- **Cons:**
  - Requires direct SMTP access to receive mail
  - Difficult to scale
  - No spam filtering
  - Hard to test in development

### Option 2: Email Provider Webhooks with Token Authentication

- **Pros:**
  - Uses proven email infrastructure (SendGrid, Mailgun)
  - Built-in spam filtering
  - Webhook-based (no SMTP receive needed)
  - HMAC-SHA256 tokens prevent spoofing
  - Queue-based processing for reliability
  - Easy to test with simulation tools
- **Cons:**
  - Requires email provider account
  - Tokens can expire
  - More complex implementation

### Option 3: Third-Party Email Reply Service

- **Pros:**
  - Ready-made solution
  - Handles all complexity
- **Cons:**
  - Vendor lock-in
  - Recurring costs
  - Less control over security
  - Data privacy concerns

## Decision

We chose **Option 2: Email Provider Webhooks with Token Authentication**.

The architecture follows this flow:
```
Outbound: Notification → Reply-To: reply+{token}@domain → User Inbox
Inbound:  User Reply → Email Provider → Webhook /api/email/inbound → Queue → Comment
```

Key components:
- **HMAC-SHA256 tokens** embedded in Reply-To addresses with 30-day expiration
- **Webhook endpoint** at `/api/email/inbound` receives parsed emails
- **Queue worker** processes emails asynchronously
- **Rate limiting** prevents abuse (10/hr, 50/day per user; 100/hr per group)
- **Spam filtering** rejects high spam score emails

## Rationale

1. **Security First**: HMAC-SHA256 tokens with user email verification prevents email spoofing. Even if an attacker obtains a token, they cannot use it without the correct email address.

2. **Queue-Based Reliability**: Processing via Drupal's queue system ensures emails are processed even if there are temporary failures. Failed items are automatically retried.

3. **Provider Flexibility**: The webhook endpoint accepts standard email parsing data from SendGrid, Mailgun, or similar services. Provider-specific handling is isolated.

4. **Testability**: The architecture includes comprehensive testing tools:
   - DDEV command for simulating emails
   - Web UI for token generation and reply simulation
   - Drush commands for end-to-end testing

5. **Recipe Integration**: Auto-configuration via NWP recipe system enables email reply on new installations without manual setup.

## Consequences

### Positive
- Users can engage with content without logging in
- Secure token-based authentication prevents spoofing
- Spam filtering reduces abuse
- Queue-based processing ensures reliability
- Easy to test in development environments
- Auto-configured on new AVC installations

### Negative
- Requires email provider with inbound parsing support
- Tokens expire after 30 days (replies to old emails fail)
- MX record configuration required for reply domain
- Additional infrastructure cost (email provider)

### Neutral
- Another Drupal module to maintain
- Drush commands add to command surface area
- Documentation required for email provider setup

## Implementation Notes

### Files Structure

```
avc_email_reply/
├── src/
│   ├── Controller/
│   │   ├── InboundEmailController.php   # Webhook endpoint
│   │   └── EmailReplyTestController.php # Test UI
│   ├── Commands/
│   │   └── EmailReplyCommands.php       # Drush commands
│   ├── Plugin/QueueWorker/
│   │   └── EmailReplyWorker.php         # Queue processor
│   └── Service/
│       ├── ReplyTokenService.php        # Token generation/validation
│       ├── EmailReplyProcessor.php      # Email processing logic
│       ├── ReplyContentExtractor.php    # Extract reply from email
│       └── EmailRateLimiter.php         # Rate limiting
├── scripts/
│   └── configure_email_reply.php        # Post-install configuration
└── config/
    └── install/
        └── avc_email_reply.settings.yml # Default settings
```

### Token Format

```
Token = base64(node_id:user_id:expiry:signature)
Signature = HMAC-SHA256(node_id:user_id:expiry, secret_key)
```

### Rate Limiting

| Limit | Value | Purpose |
|-------|-------|---------|
| Per user/hour | 10 | Prevent individual abuse |
| Per user/day | 50 | Daily cap |
| Per group/hour | 100 | Group-level throttling |

### Email Provider Setup

**SendGrid:**
1. Create Inbound Parse webhook
2. Configure MX record: `reply.example.com → mx.sendgrid.net`
3. Set webhook URL: `https://site.com/api/email/inbound`

**Mailgun:**
1. Create route in Mailgun dashboard
2. Configure MX record to Mailgun servers
3. Set webhook URL: `https://site.com/api/email/inbound`

### Recipe Configuration

```yaml
email_reply:
  enabled: true
  reply_domain: "reply.example.com"
  email_provider: sendgrid
  token_expiry_days: 30
  debug_mode: false
```

## Review

**30-day review date:** 2026-02-15
**Review outcome:** Pending
