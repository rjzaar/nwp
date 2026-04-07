# NWP Architecture Analysis & Research

**Document Version:** 1.0
**Purpose:** Consolidated research reference for architectural decisions
**Last Updated:** January 2026

This document consolidates research conducted during NWP development, comparing it with DrevOps Vortex, Pleasy, and industry best practices.

---

## Table of Contents

1. [Vortex Comparison](#1-vortex-comparison)
2. [Environment Variables & Configuration](#2-environment-variables--configuration)
3. [Deployment Workflow Analysis](#3-deployment-workflow-analysis)
4. [Key Architectural Decisions](#4-key-architectural-decisions)

---

# 1. Vortex Comparison

*Original research: December 2024*

## Executive Summary

**DrevOps Vortex** is a comprehensive Drupal DevOps template with **4,561 lines** of automation scripts covering deployment to multiple platforms, extensive testing, and sophisticated CI/CD pipelines.

**NWP** focuses on Linode deployment with strong LEMP stack automation and blue-green deployment capabilities.

**Key Insight:** Vortex is a **horizontal platform** (supports many hosting providers), while NWP is **vertical** (deep Linode integration). Both approaches have merit.

## Architecture Comparison

| Feature | Vortex | NWP |
|---------|--------|-----|
| **Primary Focus** | Platform-agnostic template | Linode-specific deployment |
| **Local Development** | Docker Compose | DDEV |
| **Hosting Platforms** | Lagoon, Acquia, Generic, Container Registry | Linode |
| **Task Runner** | Ahoy CLI (30+ commands) | `pl` CLI wrapper |
| **Configuration** | `.env` files | `nwp.yml` + `.env` |

## Vortex Scripts (30+ scripts)

### Deployment
- `deploy.sh` - Generic deployment
- `deploy-lagoon.sh` - Lagoon platform
- `deploy-acquia.sh` - Acquia platform
- `deploy-container-registry.sh` - Docker registry
- `deploy-artifact.sh` - Artifact-based deployment

### Database Operations
- `download-db.sh` - Generic DB download
- `export-db.sh` - Export database
- `provision.sh` - Site provisioning (348 lines)
- `provision-sanitize-db.sh` - Sanitize database

### Operations
- `doctor.sh` - Diagnose setup issues (293 lines)
- `info.sh` - Display project information
- `login.sh` - Generate admin login

## Patterns Adopted by NWP

| Vortex Pattern | NWP Implementation |
|----------------|-------------------|
| `doctor.sh` diagnostics | `status.sh` with health checks |
| Database sanitization | `--sanitize` flag in backup.sh |
| Unified CLI | `pl` command wrapper |
| Environment files | `.env` generation during install |
| Config management | Drush cex/cim in deployment scripts |

---

# 2. Environment Variables & Configuration

*Original research: December 2024*

## Three Main Approaches

1. **Vortex**: Comprehensive `.env` file + `docker-compose.yml`
2. **DDEV**: `config.yaml` with `web_environment`
3. **NWP nwp.yml**: Custom YAML configuration for project recipes

## Vortex Environment Structure

```bash
# General
VORTEX_PROJECT=your_site
WEBROOT=web
TZ=UTC

# Drupal
DRUPAL_PROFILE=standard
DRUPAL_CONFIG_PATH=../config/default
DRUPAL_REDIS_ENABLED=1

# Provisioning
VORTEX_PROVISION_TYPE=database
VORTEX_PROVISION_SANITIZE_DB_SKIP=0
```

## NWP Configuration Hierarchy

```
1. Recipe-specific settings (highest priority)
   ↓
2. Global settings defaults
   ↓
3. Profile-based defaults
   ↓
4. Hardcoded defaults (lowest priority)
```

## NWP Implementation

NWP adopted a hybrid approach:

```yaml
# nwp.yml
settings:
  environment:
    development:
      debug: true
    staging:
      debug: false
      stage_file_proxy: true
    production:
      debug: false

  services:
    redis:
      enabled: false
    solr:
      enabled: false
```

Generated `.env` files during installation with profile-specific templates.

---

# 3. Deployment Workflow Analysis

*Original research: December 2024 - January 2026*

## The Question

Should staging be production-like (`make prod`) or development-like (with dev tools)?

## The Answer

**Staging should run in PRODUCTION MODE**, mirroring the live environment as closely as possible. This is the consensus from Vortex, Pleasy, and industry best practices.

## Comparison Matrix

| Aspect | Vortex | Pleasy | NWP |
|--------|--------|--------|-----|
| **Staging Mode** | Production-like | Production mode | Production mode |
| **Dev Modules in Staging** | Separate config split | Uninstalled | Uninstalled |
| **Composer in Staging** | Standard | `--no-dev` | `--no-dev` |
| **Database Source** | Production (sanitized) | Production (sanitized) | Configurable |

## Vortex Environment Detection

```php
define('ENVIRONMENT_LOCAL', 'local');   // Local development
define('ENVIRONMENT_CI', 'ci');         // Continuous Integration
define('ENVIRONMENT_DEV', 'dev');       // Development server
define('ENVIRONMENT_STAGE', 'stage');   // Staging server
define('ENVIRONMENT_PROD', 'prod');     // Production
```

## NWP Four-State Workflow

```
┌─────────┐      ┌─────────┐      ┌─────────┐      ┌─────────┐
│   DEV   │ ───► │   STG   │ ───► │  LIVE   │ ───► │  PROD   │
│ (local) │ ◄─── │ (local) │ ◄─── │ (cloud) │ ◄─── │ (cloud) │
└─────────┘      └─────────┘      └─────────┘      └─────────┘
  DDEV            DDEV clone      sitename.url     sitename.com
```

| State | Location | Purpose |
|-------|----------|---------|
| **dev** | Local DDEV | Active development |
| **stg** | Local DDEV | Testing (production mode) |
| **live** | Linode | Client preview / UAT |
| **prod** | Linode | Production |

## Workflow Scripts

```bash
# Forward deployment
pl dev2stg mysite     # Dev → Staging
pl stg2live mysite    # Staging → Live
pl stg2prod mysite    # Staging → Production

# Backward sync
pl prod2stg mysite    # Production → Staging
pl live2stg mysite    # Live → Staging
```

---

# 4. Key Architectural Decisions

## Decisions Made Based on Research

### 1. Staging Runs Production Mode
**Decision:** `dev2stg.sh` automatically enables production mode on staging.
**Rationale:** Catches production-only bugs before they reach users.

### 2. DDEV Over Docker Compose
**Decision:** Use DDEV for local development.
**Rationale:** Better developer experience, automatic SSL, simpler configuration.

### 3. Unified CLI Wrapper
**Decision:** Implement `pl` command.
**Rationale:** Mirrors Vortex's Ahoy CLI pattern for discoverability.

### 4. Two-Tier Secrets
**Decision:** Separate `.secrets.yml` (infrastructure) from `.secrets.data.yml` (production).
**Rationale:** Allows AI assistants to help with infrastructure while protecting user data.

### 5. Recipe-Based Configuration
**Decision:** Use `nwp.yml` with recipe inheritance.
**Rationale:** Define once, use many times. Simpler than per-project configuration.

### 6. GitLab as Default Remote
**Decision:** NWP GitLab server as primary git backup destination.
**Rationale:** Self-hosted, full data sovereignty, built-in CI/CD.

### 7. Linode-First Strategy
**Decision:** Deep Linode integration rather than platform-agnostic.
**Rationale:** Better UX for target audience. Abstraction layer can be added later.

---

## Archived Research Documents

The full original research documents are available in `docs/archive/`:

- `VORTEX_COMPARISON.md` - Complete Vortex analysis (932 lines)
- `environment-variables-comparison.md` - Full env var comparison (893 lines)
- `DEPLOYMENT_WORKFLOW_ANALYSIS.md` - Detailed workflow research (334 lines)

---

*This document consolidates research conducted December 2024 - January 2026*
