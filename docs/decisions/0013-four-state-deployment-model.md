# ADR-0013: Four-State Deployment Model (dev/stg/live/prod)

**Status:** Accepted
**Date:** 2025-12-20 (P26), refined 2026-01-05 (P32-P35)
**Decision Makers:** Rob
**Related Issues:** P26 (Four-State Deployment Workflow), P32-P35 (Live Deployment Automation)
**References:** [milestones.md](../reports/milestones.md#phase-5-enterprise-features), [stg2live.sh](../../scripts/commands/stg2live.sh)

## Context

Traditional deployment models use 2-3 environments:
- **Dev → Prod** (simple, risky)
- **Dev → Staging → Prod** (common pattern)

NWP needed to support:
1. **Local development** - DDEV containers
2. **Local staging** - Testing before cloud deployment
3. **Cloud staging** - Live server testing
4. **Cloud production** - Final production

This creates a 4-state model that's uncommon but necessary for NWP's hybrid local+cloud architecture.

## Decision

Implement four-state deployment workflow:

```
DEV (local DDEV)
  ↓ pl dev2stg
STG (local DDEV)
  ↓ pl stg2live
LIVE (cloud server)
  ↓ pl live2prod (or stg2prod)
PROD (cloud server)
```

**State definitions:**
- **DEV** - Active development, sitename (e.g., `mysite`)
- **STG** - Pre-deployment testing, sitename-stg (e.g., `mysite-stg`)
- **LIVE** - Cloud staging/testing, subdomain.example.com
- **PROD** - Final production, example.com or www.example.com

**Naming convention:**
- Dev: `sitename` (no suffix)
- Staging: `sitename-stg` (hyphenated suffix)
- Live: `sitename-live` (cloud, could be different domain)
- Prod: `sitename-prod` (cloud, primary domain)

## Rationale

### Why Four States Instead of Three?

**Problem with traditional 3-state:**
```
Dev (local) → Staging (cloud) → Prod (cloud)
```

Issues:
- Can't test DDEV→Linode deployment until staging
- Expensive (2 cloud servers minimum)
- No local staging for quick tests

**NWP's 4-state solution:**
```
Dev (local) → Stg (local) → Live (cloud) → Prod (cloud)
```

Benefits:
- Test locally first (free, fast)
- Test deployment to cloud (Live = cloud staging)
- Separate production server (security, backup)
- Incremental risk reduction

### Why "Live" Instead of "Staging"?

**Terminology clarifies location:**
- **Staging** = Local DDEV environment
- **Live** = Cloud server (even if not "production" yet)
- **Prod** = Final production

Alternative terms considered:
- "Cloud Staging" - Too verbose
- "Beta" - Implies public access
- "Test" - Confusing with test suite
- "Pre-prod" - Awkward
- "Live" - Clearly indicates "on the internet"

### Deployment Paths

**Primary path (all 4 states):**
```bash
pl dev2stg mysite     # Local dev → local staging
pl stg2live mysite    # Local → cloud (with hardening)
pl live2prod mysite   # Cloud staging → production
```

**Shortcut path (skip staging):**
```bash
pl stg2prod mysite    # Local → production (1 command)
```

**Alternative path (test on Live first):**
```bash
pl stg2live mysite    # Deploy to Live (cloud staging)
# Test on Live, if good:
pl live2prod mysite   # Promote to Prod
```

### Environment-Specific Behavior

| Feature | Dev | Stg | Live | Prod |
|---------|-----|-----|------|------|
| Debug mode | ON | OFF | OFF | OFF |
| XDebug | Optional | OFF | OFF | OFF |
| Caching | Minimal | Normal | Aggressive | Aggressive |
| Security modules | No | No | Yes | Yes |
| Stage File Proxy | Yes | Yes | Optional | No |
| Database sanitize | No | Yes (optional) | Yes (from prod) | No |
| Robots.txt | Allow | Disallow | Disallow | Allow |
| X-Robots-Tag | None | noindex | noindex | None |
| SSL | Local cert | Local cert | Let's Encrypt | Let's Encrypt |
| Monitoring | No | No | Optional | Yes |

### Cloud Server Strategy

**Single server (budget):**
- Live and Prod on same server, different domains
- Use nginx server blocks
- Shared resources

**Dual server (recommended):**
- Live: test.example.com (lower-spec server)
- Prod: example.com (higher-spec server)
- Isolated resources, better security

**Triple server (enterprise):**
- Dev: Local DDEV
- Stg: Local DDEV
- Live: Staging cloud server
- Prod: Production cloud server
- Backup: Hot standby

## Consequences

### Positive
- **Risk reduction** - Test twice before production
- **Cost effective** - 2 local states are free
- **Flexibility** - Can skip states if confident
- **Clear naming** - Environment obvious from name
- **Incremental testing** - Each step adds confidence

### Negative
- **More commands** - 3 deployment commands instead of 1
- **Learning curve** - Users must understand 4 states
- **Naming confusion** - "Live" might seem like production

### Neutral
- **Optional states** - Can skip Stg or Live if desired
- **Compatible with 3-state** - Can ignore Live, use Stg→Prod

## Implementation Notes

### Scripts Implementing 4-State Model

- `scripts/commands/dev2stg.sh` - Dev → Staging
- `scripts/commands/stg2live.sh` - Staging → Live (P32-P35)
- `scripts/commands/live2prod.sh` - Live → Prod
- `scripts/commands/stg2prod.sh` - Staging → Prod (shortcut)
- `scripts/commands/prod2stg.sh` - Prod → Staging (for debugging)
- `scripts/commands/live2stg.sh` - Live → Staging

### Environment Detection

```bash
get_environment() {
    local site_name="$1"
    if [[ "$site_name" == *"-stg" ]]; then
        echo "stg"
    elif [[ "$site_name" == *"-live" ]]; then
        echo "live"
    elif [[ "$site_name" == *"-prod" ]]; then
        echo "prod"
    else
        echo "dev"
    fi
}
```

### P32-P35: Live Deployment Automation

Phase 5c (Jan 2026) automated Live deployments:
- **P32**: Profile module symlink auto-creation
- **P33**: Live server infrastructure setup (nginx, PHP, MariaDB)
- **P34**: Database deployment in stg2live
- **P35**: Production settings generation

This made `pl stg2live` fully automated.

## Review

**30-day review date:** 2026-02-05
**Review outcome:** Pending

**Success Metrics:**
- [x] All 4 states implemented
- [x] Deployment scripts created
- [x] Documentation complete
- [ ] User feedback: Clear vs confusing
- [ ] Adoption: How many users use all 4 states?

## Related Decisions

- **ADR-0002: YAML-Based Configuration** - States defined in nwp.yml
- **ADR-0008: Recipe System Architecture** - Environment-specific options
- **P26: Four-State Deployment Workflow** - Original proposal
