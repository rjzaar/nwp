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
nwp.yml              # May contain server IPs, credentials
keys/*                # SSH private keys
*.sql                 # Database dumps (may contain PII)
.env.local            # Local secrets
settings.php          # Database credentials
```

#### SAFE to share with Claude:

```bash
# SAFE to share:
example.nwp.yml      # Template with placeholder values
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

### Two-Tier Secrets Architecture

NWP uses a two-tier secrets architecture that allows Claude Code to help manage infrastructure while protecting user data:

| Tier | File | Contents | Claude Access |
|------|------|----------|---------------|
| **Infrastructure** | `.secrets.yml` | API tokens for provisioning | ALLOWED |
| **Data** | `.secrets.data.yml` | Production credentials | BLOCKED |

#### Why Two Tiers?

Claude can be valuable for infrastructure automation (provisioning servers, managing DNS, CI/CD) without needing access to user data (database contents, production logs, user files).

**Infrastructure secrets** (safe for Claude):
- Linode API token (server provisioning)
- Cloudflare API token (DNS management)
- GitLab API token (repo management)
- Development/staging credentials

**Data secrets** (blocked from Claude):
- Production database passwords
- Production SSH keys
- Production SMTP credentials
- Encryption keys
- Admin account passwords

#### File Structure

```
/home/user/nwp/
├── .secrets.yml              # Infrastructure (Claude CAN read)
├── .secrets.data.yml         # Data secrets (Claude CANNOT read)
├── .secrets.example.yml      # Template for infrastructure
├── .secrets.data.example.yml # Template for data secrets
│
└── sitename/
    ├── .secrets.yml          # Site dev/staging secrets (safe)
    └── .secrets.data.yml     # Site production secrets (blocked)
```

#### Install via setup.sh

```bash
# Install Claude security config with two-tier rules
./setup.sh

# Or run migration check
./migrate-secrets.sh --check
```

#### What's ALLOWED (Infrastructure)

| Pattern | Purpose |
|---------|---------|
| `.secrets.yml` | API tokens for provisioning |
| `.env`, `.env.local` | Development environment |
| `nwp.yml` | Site configuration (after removing embedded creds) |

#### What's BLOCKED (Data)

| Pattern | Purpose |
|---------|---------|
| `.secrets.data.yml` | Production credentials |
| `keys/prod_*` | Production SSH keys |
| `*.sql`, `*.sql.gz` | Database dumps |
| `settings.php` | Drupal credentials |
| `~/.ssh/*` | Personal SSH keys |
| `*.pem`, `*.key` | Certificates |

#### Migration from Single-Tier

If you have existing `.secrets.yml` files with mixed secrets:

```bash
# Check for data secrets in infrastructure files
./migrate-secrets.sh --check

# Migrate NWP root secrets
./migrate-secrets.sh --nwp

# Migrate a specific site
./migrate-secrets.sh --site avc

# Migrate all
./migrate-secrets.sh --all
```

The migration script will:
1. Identify data secrets in `.secrets.yml`
2. Create `.secrets.data.yml` from template
3. Guide you to move data secrets manually
4. Validate the split

#### Safe Operations Proxy

For operations that need data secrets but should return sanitized output:

```bash
source lib/safe-ops.sh

# Get server status (no credentials exposed)
safe_server_status prod1

# Get database info (no actual data)
safe_db_status avc

# Check for security updates
safe_security_check avc
```

These functions use data secrets internally but only return sanitized information.

#### Using the New Functions

In your scripts, use the appropriate function:

```bash
source lib/common.sh

# For infrastructure secrets (Claude can see)
token=$(get_infra_secret "linode.api_token" "")

# For data secrets (Claude cannot see)
db_pass=$(get_data_secret "production_database.password" "")
```

#### Tiered Security Approaches

| Tier | Approach | Security | Practicality |
|------|----------|----------|--------------|
| 1 | **Isolated environment** | Highest | Medium |
| 2 | **Two-tier secrets** (this) | High | High |
| 3 | **Deny rules only** | Medium | Highest |

**Tier 1: Isolated Environment**

Run Claude in a VM/container with no secrets at all:
- Clone repo without any secrets
- Use placeholder credentials
- Sync code, never secrets

**Tier 2: Two-Tier Secrets (Recommended)**

Current architecture - separate infrastructure from data:
- `.secrets.yml` = safe for Claude
- `.secrets.data.yml` = blocked from Claude
- Best balance of security and productivity

**Tier 3: Deny Rules Only**

Block all secrets files (original approach):
- Simpler but less flexible
- Claude can't help with infrastructure

#### Production Deployment

For maximum security:

```bash
# Option A: Two-tier with safe-ops
# Claude uses infrastructure secrets
# Production ops through safe_* functions

# Option B: Separate terminal
# Claude in one terminal
# Production commands in another

# Option C: CI/CD pipeline
# Neither machine has prod secrets
# Secrets injected at deploy time
```

#### Verify Your Setup

```bash
# Check Claude deny rules
jq '.permissions.deny' ~/.claude/settings.json

# Check for data secrets in wrong files
./migrate-secrets.sh --check

# List what Claude can/cannot access
grep -l "api_token" *.yml          # Should be in .secrets.yml
grep -l "password" *.yml           # Should be in .secrets.data.yml
```

> **Note:** Even with two-tier architecture, never paste production credentials into Claude. The architecture prevents accidental file reads, but you can still manually share sensitive data.

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

Configure in `nwp.yml`:

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
./linode/gitlab/gitlab_harden.sh --check

# Preview changes (dry run)
./linode/gitlab/gitlab_harden.sh

# Apply security hardening
./linode/gitlab/gitlab_harden.sh --apply
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
- [ ] Verify Claude Code security config is active: `grep -q '"deny"' ~/.claude/settings.json`

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
| 2026-01-03 | Added Claude Code security config section with setup.sh integration |
| 2026-01-03 | Added tiered security approaches for AI assistant usage |
| 2026-01-03 | Implemented two-tier secrets architecture (infrastructure vs data) |

