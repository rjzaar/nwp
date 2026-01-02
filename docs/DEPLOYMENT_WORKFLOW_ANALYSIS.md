# Deployment Workflow Analysis: Dev → Staging → Production

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

## Recommendations for NWP

### Current NWP Workflow

```bash
./dev2stg.sh nwp5      # Creates nwp5_stg (copies everything)
./stg2prod.sh nwp5     # Promotes to nwp5_prod
```

### Recommended Changes

#### 1. Add Explicit `makeprod` Step (Like Pleasy)

```bash
# Option A: Separate command
./dev2stg.sh nwp5       # Copy to staging (still dev mode)
./makeprod.sh nwp5_stg  # Convert to production mode
./stg2prod.sh nwp5      # Deploy to production

# Option B: Flag on dev2stg
./dev2stg.sh -p nwp5    # Copy AND convert to prod mode
```

#### 2. What `makeprod` Should Do

```bash
makeprod() {
    local site=$1

    # 1. Switch Drupal to production mode
    ddev drush @$site config:set system.performance css.preprocess 1
    ddev drush @$site config:set system.performance js.preprocess 1
    ddev drush @$site config:set system.logging error_level hide

    # 2. Uninstall dev modules
    ddev drush @$site pm:uninstall devel views_ui field_ui dblog -y

    # 3. Remove dev Composer dependencies
    cd $site && ddev composer install --no-dev

    # 4. Export clean config
    ddev drush @$site cex -y

    # 5. Clear all caches
    ddev drush @$site cr
}
```

#### 3. Database Flow

```
Production DB
     │
     ▼ (download + sanitize)
Staging DB ←─────────────────── Use for testing
     │
     ▼ (optional: copy for dev)
Development DB ←─────────────── Can be anything
```

#### 4. Recommended NWP Workflow

```bash
# DEVELOPMENT PHASE
./install.sh nwp mysite          # Create dev site
./make.sh -v mysite              # Ensure dev mode
# ... develop features ...

# STAGING PHASE
./dev2stg.sh mysite              # Copy to mysite_stg
./prod2stg.sh mysite             # (optional) Get production DB
./makeprod.sh mysite_stg         # Convert to production mode
# ... test in production-like environment ...
# ... stakeholder review ...

# PRODUCTION PHASE
./stg2prod.sh -b mysite          # Deploy with backup
./security.sh mysite_prod        # Harden security
```

### Environment Configuration

Update `cnwp.yml` to track environment modes:

```yaml
sites:
  mysite:
    recipe: nwp
    mode: dev              # dev | prod
    environment: dev       # dev | stg | prod

  mysite_stg:
    recipe: nwp
    mode: prod             # Staging runs in prod mode
    environment: stg
    source_db: mysite_prod # Where to get DB from
    sanitize: true         # Sanitize DB on sync

  mysite_prod:
    recipe: nwp
    mode: prod
    environment: prod
    purpose: permanent     # Protect from deletion
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

### Proposed NWP Terminology

| Environment | Command | Mode | Purpose |
|-------------|---------|------|---------|
| **dev** | `./install.sh` | Dev | Active development |
| **stg** | `./dev2stg.sh` + `./makeprod.sh` | Prod | Pre-production validation |
| **prod** | `./stg2prod.sh` | Prod | Live site |

Or with a simplified workflow:

```bash
./dev2stg.sh -p mysite   # -p flag = also run makeprod
```

---

## References

- [Vortex Template](https://github.com/drevops/vortex) - Drupal project scaffold
- [Drupal Best Practices - Dev/Staging/Prod](https://groups.drupal.org/node/297083)
- [Drupalize.me - Deployment Workflows](https://drupalize.me/topic/deployment-workflows)
- [Environment Management Best Practices](https://northflank.com/blog/what-are-dev-qa-preview-test-staging-and-production-environments)
- [Staging Environment Best Practices](https://www.statsig.com/perspectives/staging-environment-best-practices)
- [The DropTimes - Managing Drupal Environments](https://www.thedroptimes.com/40998/best-practices-managing-drupal-environments-development-production)
