# NWP Data Security Best Practices

A comprehensive guide to data security, backup strategies, and safe AI usage when working with NWP and Drupal sites.

---

## Executive Summary

This document covers three critical security areas:

1. **Production Backup Strategy** - How to safely backup and restore production sites
2. **Database Sanitization** - Protecting PII when syncing production to development
3. **AI Assistant Usage** - What to share (and NOT share) with Claude and other AI tools

---

## 1. Production Backup Strategy

### Backup Frequency

| Site Type | Database Backup | Full Backup | Retention |
|-----------|-----------------|-------------|-----------|
| High-traffic production | Daily | Weekly | 30 days |
| Low-traffic production | Weekly | Monthly | 90 days |
| Staging | Before each deployment | Monthly | 14 days |
| Development | Before major changes | As needed | 7 days |

### NWP Backup Commands

```bash
# Database-only backup (fast, recommended for daily backups)
./backup.sh -by nwp5 "Daily automated backup"

# Full backup (database + files)
./backup.sh -y nwp5 "Weekly full backup"

# Backup with Git integration (for off-site storage)
./backup.sh --git -y nwp5 "Push to GitLab"

# Backup with bundle for offline archival
./backup.sh --bundle -y nwp5 "Offline archive"
```

### Backup Storage Rules

| Rule | Implementation |
|------|----------------|
| **3-2-1 Rule** | 3 copies, 2 different media, 1 off-site |
| **Encryption** | Encrypt backups containing user data |
| **Separate location** | Never store backups only on the same server |
| **Test restores** | Monthly test restore to staging environment |

### Backup Locations

```
Local:     /home/rob/nwp/sitebackups/<sitename>/
Off-site:  GitLab repository (via --git flag)
Archive:   Git bundle files (via --bundle flag)
```

### Pre-Deployment Backup Checklist

Before any production deployment:

- [ ] Run `./backup.sh -by sitename_prod "Pre-deployment backup"`
- [ ] Verify backup file exists and has reasonable size
- [ ] Document the backup filename for rollback reference
- [ ] Test restore procedure is documented

---

## 2. Database Sanitization

### The Golden Rule

> **NEVER use production data in development without sanitization.**

Production databases contain:
- User emails and passwords
- Personal information (names, addresses, phone numbers)
- Payment/commerce data
- Session tokens and authentication data
- Webform submissions with sensitive content

### NWP Sanitization Commands

```bash
# Basic sanitization (emails, passwords, sessions)
./backup.sh --sanitize basic -by nwp5_prod "Sanitized for dev"

# Full sanitization (includes logs, webforms, commerce)
./backup.sh --sanitize full -by nwp5_prod "Fully sanitized"

# Sanitize when syncing production to staging
./prod2stg.sh --sanitize nwp5
```

### What Gets Sanitized

| Level | Data Anonymized |
|-------|-----------------|
| **Basic** | User emails → `user_<uid>@example.com`, passwords reset, sessions cleared |
| **Full** | Basic + watchdog logs, cache tables, webform submissions, commerce orders |

### Sanitization Best Practices

1. **Automate it** - Never rely on manual sanitization
2. **Verify it** - Spot-check sanitized databases for PII leakage
3. **Document it** - Log when sanitization was performed
4. **Never skip it** - No exceptions for "quick tests"

### GDPR Compliance

For EU user data:

```bash
# Always use full sanitization for GDPR compliance
./backup.sh --sanitize full -by production_site

# Consider field-level encryption for sensitive data in production
# Install: drupal/encrypt, drupal/field_encrypt
```

---

## 3. AI Assistant Usage (Claude, Copilot, etc.)

### Critical Rule

> **Treat AI platforms like social media: if you wouldn't post it publicly, don't share it with AI.**

### Data You Must NEVER Share with AI

| Category | Examples | Why |
|----------|----------|-----|
| **Credentials** | API keys, passwords, tokens, SSH keys | Direct security breach |
| **Connection strings** | Database URLs with passwords | System compromise |
| **PII** | Real user emails, names, addresses | Privacy violations, GDPR |
| **Production data** | Real database dumps, user content | Data exposure |
| **Financial data** | Credit cards, bank details | Fraud risk |
| **Health data** | Medical records, PHI | HIPAA violations |
| **Proprietary code** | Trade secrets, algorithms | IP theft |

### What IS Safe to Share with Claude

| Safe | Example |
|------|---------|
| **Anonymized code** | Code with fake credentials: `DB_PASS=example123` |
| **Public patterns** | "How do I implement X in Drupal?" |
| **Error messages** | Stack traces (check for embedded secrets first) |
| **Architecture questions** | "What's the best way to structure Y?" |
| **Documentation** | README files, public API docs |
| **Synthetic examples** | Made-up data that preserves structure |

### NWP-Specific AI Safety Rules

#### NEVER share with Claude:

```bash
# NEVER paste contents of:
.secrets.yml          # Contains API tokens, passwords
cnwp.yml              # May contain server IPs, credentials
keys/*                # SSH private keys
*.sql                 # Database dumps (may contain PII)
.env.local            # Local secrets
settings.php          # Database credentials
```

#### SAFE to share with Claude:

```bash
# SAFE to share:
example.cnwp.yml      # Template with placeholder values
.secrets.example.yml  # Template with empty values
.env.local.example    # Template showing structure
README.md             # Public documentation
lib/*.sh              # Library code (review for secrets first)
recipes/*             # Recipe definitions (public)
```

### Before Pasting Code to Claude

Ask yourself:

1. **Does it contain real credentials?** → Replace with placeholders
2. **Does it contain real user data?** → Use synthetic examples
3. **Does it contain server IPs/domains?** → Replace with `example.com`
4. **Would I post this on Stack Overflow?** → If no, don't share

### Safe Prompt Examples

```
# BAD - Contains real credentials
"Here's my settings.php, why isn't the database connecting?"

# GOOD - Anonymized
"I have a Drupal settings.php with this structure (credentials replaced):
$databases['default']['default'] = [
  'host' => 'db.example.com',
  'username' => 'REDACTED',
  'password' => 'REDACTED',
  ...
];
Why might the database connection fail?"
```

```
# BAD - Real production data
"Here's my user table dump, why are there duplicates?"

# GOOD - Synthetic example
"I have a users table with this structure:
uid | name    | mail
1   | admin   | admin@example.com
2   | user1   | user1@example.com
Why might I see duplicate entries?"
```

---

## 4. Security Hardening Checklist

### Production Server Security

```bash
# Run security audit on production site
./security.sh audit nwp5_prod

# Check for security updates
./security.sh check nwp5_prod

# Apply security updates (creates backup first)
./security.sh update nwp5_prod
```

### What the Security Audit Checks

- [ ] File permissions (settings.php should be 444/440)
- [ ] Development modules disabled (devel, webprofiler, kint)
- [ ] Error display disabled
- [ ] Exposed sensitive files (.env, .secrets.yml in webroot)
- [ ] Security updates available

### Essential Security Modules

Configure in `cnwp.yml`:

```yaml
live_security:
  enabled: true
  modules:
    - seckit          # HTTP security headers
    - honeypot        # Spam bot protection
    - flood_control   # Brute-force protection
    - login_security  # Login attempt limiting
```

### GitLab Server Hardening

```bash
# Review current security settings
./git/gitlab_harden.sh --check

# Preview changes (dry run)
./git/gitlab_harden.sh

# Apply security hardening
./git/gitlab_harden.sh --apply
```

---

## 5. Secrets Management

### Current NWP Secrets Structure

```
.secrets.yml           # Active secrets (NEVER commit)
.secrets.example.yml   # Template for new installations
```

### Required Secrets

| Secret | Location | Purpose |
|--------|----------|---------|
| Linode API token | `.secrets.yml` | Server provisioning |
| GitLab API token | `.secrets.yml` | Repository access |
| Cloudflare token | `.secrets.yml` | DNS management |
| SSH keys | `keys/` directory | Server access |

### Secrets Rotation Schedule

| Secret Type | Rotation Frequency |
|-------------|-------------------|
| API tokens | Every 90 days |
| Admin passwords | Every 90 days |
| SSH keys | Annually or on team changes |
| Database passwords | Every 90 days |

### Emergency Procedures

If credentials are exposed:

1. **Immediately rotate** the exposed credentials
2. **Audit access logs** for unauthorized usage
3. **Update all systems** using those credentials
4. **Document the incident** for future reference

---

## 6. Development Workflow Security

### Safe Development Cycle

```
Production DB ──────────────────────────────────────┐
      │                                              │
      ▼ (sanitize ALWAYS)                           │
Staging DB ◄──── ./prod2stg.sh --sanitize           │
      │                                              │
      ▼ (copy from staging, never production)       │
Development DB                                       │
      │                                              │
      ▼ (code only, config up)                      │
Staging ────────────────────────────────────────────┤
      │                                              │
      ▼ (backup first, then deploy)                 │
Production ◄─────────────────────────────────────────┘
```

### Key Principles

1. **Config goes UP** (dev → staging → production)
2. **Data goes DOWN** (production → staging → dev), always sanitized
3. **Backup before deploy** (always)
4. **Test on staging** (never skip)

---

## 7. Incident Response

### If You Suspect a Breach

1. **Contain** - Take affected systems offline if necessary
2. **Assess** - Determine what was accessed
3. **Notify** - Inform relevant stakeholders
4. **Remediate** - Fix vulnerabilities, rotate credentials
5. **Document** - Record timeline and actions taken
6. **Review** - Update procedures to prevent recurrence

### Security Contacts

Document your security contacts:

```yaml
# Add to your local documentation
security_contacts:
  primary: "security@yourorg.com"
  backup: "admin@yourorg.com"
  incident_response: "Define your process"
```

---

## 8. Quick Reference

### Daily Security Habits

- [ ] Never paste real credentials into AI tools
- [ ] Always sanitize when copying production data
- [ ] Check for security updates weekly
- [ ] Review access logs for anomalies

### Before Each Deployment

- [ ] Backup production database
- [ ] Verify staging tests pass
- [ ] Check for security updates
- [ ] Document the deployment

### Monthly Security Tasks

- [ ] Run full security audit: `./security.sh audit`
- [ ] Test backup restoration
- [ ] Review and rotate old credentials
- [ ] Update this documentation

---

## References

### Drupal Security
- [Drupal Security Best Practices](https://www.drupal.org/docs/security-in-drupal)
- [OWASP Drupal Security Guide](https://owasp.org/www-project-web-security-testing-guide/)

### AI Security
- [OWASP AI Security Guidelines](https://owasp.org/www-project-ai-security/)
- [Enterprise AI Usage Policies](https://www.sans.org/blog/securing-ai-in-2025-a-risk-based-approach-to-ai-controls-and-governance/)

### Data Protection
- [GDPR Compliance for Drupal](https://www.drupal.org/project/gdpr)
- [Database Sanitization Best Practices](https://www.drupal.org/project/advanced_sanitize)

---

## Document History

| Date | Change |
|------|--------|
| 2026-01-03 | Initial version based on security research |

