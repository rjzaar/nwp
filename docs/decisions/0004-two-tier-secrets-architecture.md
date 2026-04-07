# ADR-0004: Two-Tier Secrets Architecture

**Status:** Accepted
**Date:** 2026-01-08
**Decision Makers:** Rob
**Related Issues:** N/A (security architecture)

## Context

NWP handles two types of sensitive information:
1. **Infrastructure secrets** - API tokens for Linode, Cloudflare, GitLab
2. **Data secrets** - Database passwords, SSH keys, production credentials

AI assistants (Claude Code) should be able to help with infrastructure automation but must never access production data credentials.

## Options Considered

### Option 1: Two-Tier Separation
- **Pros:**
  - Clear separation of concerns
  - AI can safely access infrastructure tier
  - Data tier protected by file-level deny rules
  - Simple to understand and audit
- **Cons:**
  - Two files to manage
  - Must remember which secrets go where

### Option 2: Single Secrets File with Sections
- **Pros:**
  - Single file to manage
- **Cons:**
  - Harder to apply differential access rules
  - Risk of AI accessing wrong section

### Option 3: External Secrets Manager (Vault)
- **Pros:**
  - Enterprise-grade security
  - Audit logging
  - Dynamic secrets
- **Cons:**
  - Significant infrastructure overhead
  - Complexity for small teams

## Decision

Implement two-tier secrets architecture:

| Tier | File | Contents | AI Access |
|------|------|----------|-----------|
| **Infrastructure** | `.secrets.yml` | API tokens (Linode, Cloudflare, GitLab) | Allowed |
| **Data** | `.secrets.data.yml` | DB passwords, SSH keys, SMTP credentials | Blocked |

## Rationale

This architecture allows AI assistants to help with infrastructure automation (server provisioning, DNS management, GitLab API calls) while protecting production data access. The separation is enforced at the file level, making it easy to audit and configure in CLAUDE.md deny rules.

## Consequences

### Positive
- AI can safely help with infrastructure tasks
- Production data credentials are protected
- Clear, auditable separation

### Negative
- Two files to maintain
- Developers must understand which tier to use

### Neutral
- Both files gitignored
- Example files provided for structure

## Implementation Notes

```bash
# Access infrastructure secrets (AI-safe)
token=$(get_infra_secret "linode.api_token" "")

# Access data secrets (AI-blocked)
db_pass=$(get_data_secret "production.db_password" "")
```

CLAUDE.md deny rules:
```
.secrets.data.yml
keys/prod_*
*.sql
*.sql.gz
```

## Review

**30-day review date:** 2026-02-08
**Review outcome:** Pending
