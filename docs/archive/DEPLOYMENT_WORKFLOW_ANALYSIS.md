# Deployment Workflow Analysis: Dev → Staging → Production

> **NOTE: Superseded by `docs/ARCHITECTURE_ANALYSIS.md`**
>
> This research has been consolidated into the main architecture analysis document.
> Recommendations were implemented in dev2stg.sh, stg2prod.sh, and lib/preflight.sh.

A comparative analysis of Vortex, Pleasy, and industry best practices for environment management.

---

## Executive Summary

**The Question:** Should staging be production-like (make prod) or development-like (for testing with dev tools)?

**The Answer:** **Staging should run in PRODUCTION MODE**, mirroring the live environment as closely as possible. This is the consensus from both Vortex, Pleasy, and industry best practices.

However, you may want an additional **testing/QA environment** that runs in development mode for debugging.

---

## Comparison Matrix

| Aspect | Vortex | Pleasy | Industry Best Practice |
|--------|--------|--------|------------------------|
| **Staging Mode** | Production-like (own config split) | Production mode (dev modules removed) | Production mode |
| **Dev Modules in Staging** | Separate config split | Explicitly uninstalled | Should not be present |
| **Composer in Staging** | Standard install | `--no-dev` flag | `--no-dev` flag |
| **Database Source** | Production (sanitized) | Production (sanitized) | Production (sanitized) |
| **Config Management** | Config Split module | Drush cex/cim | Config in code, DB down |
| **Deployment Method** | Artifact/Container | Tar/Git | CI/CD artifacts |

---

## Vortex Approach

### Environment Detection

Vortex defines 5 environments in `settings.php`:

```php
define('ENVIRONMENT_LOCAL', 'local');   // Local development
define('ENVIRONMENT_CI', 'ci');         // Continuous Integration
define('ENVIRONMENT_DEV', 'dev');       // Development server
define('ENVIRONMENT_STAGE', 'stage');   // Staging server
define('ENVIRONMENT_PROD', 'prod');     // Production
```

### Branch-to-Environment Mapping

| Branch Pattern | Environment |
|----------------|-------------|
| `main` | Production |
| `develop` | Development |
| `release/*`, `hotfix/*` | Staging |
| `feature/*`, PRs | Development |

### Key Characteristics

**Staging in Vortex:**
- Gets its **own config split** (`/config/stage/`)
- Uses **production database** (downloaded and sanitized)
- Database can be overwritten (unlike production)
- Admin can be unlocked for testing
- Has staging-specific environment indicator (yellow)

**Production in Vortex:**
- Database is **never overwritten** - only backed up
- Database sanitization is **skipped**
- Admin user remains **blocked**
- Has production config split

### Vortex Workflow

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   Local     │────▶│   CI/CD     │────▶│   Deploy    │
│   (dev)     │     │  (test)     │     │             │
└─────────────┘     └─────────────┘     └──────┬──────┘
                                               │
                    ┌──────────────────────────┼──────────────────────────┐
                    ▼                          ▼                          ▼
             ┌─────────────┐           ┌─────────────┐            ┌─────────────┐
             │ Development │           │   Staging   │            │ Production  │
             │   Server    │           │   Server    │            │   Server    │
             │ (develop)   │           │ (release/*) │            │   (main)    │
             └─────────────┘           └─────────────┘            └─────────────┘
                    │                          │                          │
                    │    DB: prod (sanitized)  │     DB: prod (preserved) │
                    │    Config: dev split     │     Config: prod split   │
                    └──────────────────────────┴──────────────────────────┘
```

---

## Pleasy Approach

### Environment Architecture

Pleasy uses a clear three-tier system with explicit mode switching:

```
Dev Site (d9)        →  Staging Site (stg_d9)  →  Production (prod)
- dev mode           →  - production mode      →  - production mode
- dev modules ON     →  - dev modules OFF      →  - dev modules OFF
- composer install   →  - composer --no-dev    →  - composer --no-dev
```

### The `makeprod` Step (Critical)

Pleasy has an explicit step to convert staging to production mode:

```bash
pl makeprod stg_d9
```

This command:
1. Switches Drupal to production mode: `drupal site:mode prod`
2. **Uninstalls all dev modules**: devel, views_ui, dblog, field_ui, etc.
3. Runs `composer install --no-dev` (removes dev dependencies)
4. Exports clean config
5. Clears cache

### Pleasy Workflow

```bash
# Step 1: Develop locally
pl install d9                    # Create dev site
# ... make changes ...
pl gcom d9                       # Git commit with config export

# Step 2: Push to staging (still in dev mode initially)
pl dev2stg d9                    # Copy files, import config

# Step 3: Convert staging to production mode
pl makeprod stg_d9               # Remove dev modules, switch mode

# Step 4: Test in production-like environment
# ... test thoroughly ...

# Step 5: Deploy to production
pl prodow stg_d9                 # Push to production server

# Step 6: Blue-green swap on server
./updateprod.sh                  # Swap test and prod directories
```

### Blue-Green Deployment

Pleasy implements blue-green deployment on the server:

```
Before swap:
  /var/www/opencat.org      ← LIVE (production)
  /var/www/test.opencat.org ← Updated code, tested

After swap:
  /var/www/opencat.org      ← Updated code (now live)
  /var/www/test.opencat.org ← Old production (rollback ready)
```

---

## Industry Best Practices

### The Golden Rule

> **"Configuration goes up, database goes down."**
>
> — [Drupal Community Best Practice](https://groups.drupal.org/node/297083)

- Code and config: Dev → Staging → Production
- Database and files: Production → Staging → Dev (sanitized)

### Environment Purposes

| Environment | Purpose | Mode | Data |
|-------------|---------|------|------|
| **Development** | Active coding, experimentation | Dev mode | Test/fake data |
| **Testing/QA** | Feature testing, bug verification | Dev mode (optional) | Test data or sanitized prod |
| **Staging** | Pre-production validation, dress rehearsal | **Production mode** | Sanitized production data |
| **Production** | Live users | Production mode | Real data |

### Why Staging Must Mirror Production

[According to industry standards](https://northflank.com/blog/what-are-dev-qa-preview-test-staging-and-production-environments):

1. **Catch production-only bugs**: Some issues only appear without dev tools
2. **Validate deployment process**: Test the exact deployment that will run in prod
3. **Performance testing**: Dev mode disables caching, skewing results
4. **Security validation**: Dev modules may have vulnerabilities
5. **Stakeholder review**: Show clients what they'll actually see

### The Four-Environment Model

Many organizations use four environments, not three:

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│ Development │────▶│   Testing   │────▶│   Staging   │────▶│ Production  │
│  (sandbox)  │     │    (QA)     │     │  (pre-prod) │     │   (live)    │
└─────────────┘     └─────────────┘     └─────────────┘     └─────────────┘
      │                   │                   │                   │
   Dev mode           Dev mode*          Prod mode            Prod mode
   Test data          Test data          Prod data            Real data
   Dev modules        Dev modules        No dev modules       No dev modules

* Testing/QA can be either mode depending on needs
```

---

## NWP Implementation

### Current NWP Workflow (Implemented)

NWP now follows best practices with automatic production mode conversion:

```bash
./dev2stg.sh nwp5      # Deploy to staging WITH production mode enabled
./stg2prod.sh nwp5     # Promotes to nwp5_prod (also ensures prod mode)
```

### What dev2stg.sh Does (10 Steps)

1. Validate dev and staging sites exist
2. Export configuration from dev
3. Sync files from dev to staging (with exclusions)
4. Run `composer install --no-dev` on staging
5. Run database updates on staging
6. Import configuration to staging
7. Reinstall specified modules (if configured)
8. Clear cache on staging
9. **Enable production mode** (calls `make.sh -py`)
10. Display staging URL

### What make.sh -p Does (Production Mode)

```bash
# Called automatically by dev2stg.sh step 9
./make.sh -py sitename-stg
```

This command:
1. **Uninstalls dev modules**: devel, webprofiler, kint, stage_file_proxy
2. **Removes dev Composer packages**: `composer install --no-dev`
3. **Enables CSS/JS aggregation**: Performance optimization
4. **Enables page caching**: 10-minute cache lifetime
5. **Exports clean configuration**: Saves production settings
6. **Clears all caches**: Fresh start with new settings

### Database Flow

```
Production DB
     │
     ▼ (download + sanitize via prod2stg.sh)
Staging DB ←─────────────────── Use for testing
     │
     ▼ (optional: copy for dev)
Development DB ←─────────────── Can be anything
```

### Complete NWP Workflow

```bash
# DEVELOPMENT PHASE
./install.sh nwp mysite          # Create dev site
./make.sh -v mysite              # Ensure dev mode (optional, default)
# ... develop features ...

# STAGING PHASE
./dev2stg.sh mysite              # Deploy to mysite-stg (auto-enables prod mode)
./prod2stg.sh mysite             # (optional) Get production DB for testing
# ... test in production-like environment ...
# ... stakeholder review ...

# PRODUCTION PHASE
./stg2prod.sh -b mysite          # Deploy with backup
./security.sh mysite_prod        # Harden security
```

### Manual Mode Switching

If you need to manually switch modes:

```bash
./make.sh -v mysite              # Enable development mode
./make.sh -p mysite              # Enable production mode
```

---

## Summary: Answering Your Question

### Should staging use production mode or development mode?

**Answer: PRODUCTION MODE**

| What to Use | When | Why |
|-------------|------|-----|
| **Production mode in staging** | Always for final pre-prod testing | Mirrors real environment, catches prod-only bugs |
| **Development mode** | Only in dev environment or dedicated QA/testing env | Debugging, feature development |

### The Key Insight

Staging is NOT for development — it's for **validation**.

- In staging, you're not debugging code anymore
- You're verifying that the deployment will work
- You're showing stakeholders the final result
- You're testing with real (sanitized) data

If you need dev tools to debug something found in staging:
1. Reproduce the issue in staging
2. Go back to dev environment to fix it
3. Re-deploy to staging
4. Verify the fix in production mode

### NWP Environment Summary

| Environment | Command | Mode | Purpose |
|-------------|---------|------|---------|
| **dev** | `./install.sh` | Dev | Active development |
| **stg** | `./dev2stg.sh` | **Prod** (automatic) | Pre-production validation |
| **prod** | `./stg2prod.sh` | Prod | Live site |

Staging automatically runs in production mode - no extra steps needed.

---

## References

- [Vortex Template](https://github.com/drevops/vortex) - Drupal project scaffold
- [Drupal Best Practices - Dev/Staging/Prod](https://groups.drupal.org/node/297083)
- [Drupalize.me - Deployment Workflows](https://drupalize.me/topic/deployment-workflows)
- [Environment Management Best Practices](https://northflank.com/blog/what-are-dev-qa-preview-test-staging-and-production-environments)
- [Staging Environment Best Practices](https://www.statsig.com/perspectives/staging-environment-best-practices)
- [The DropTimes - Managing Drupal Environments](https://www.thedroptimes.com/40998/best-practices-managing-drupal-environments-development-production)
