# NWP Implementation Guide: AVC-Moodle SSO Integration

**Version:** 1.0
**Date:** 2026-01-13
**Status:** PROPOSED
**Related:** `AVC_MOODLE_INTEGRATION_PROPOSAL.md`

---

## Executive Summary

This document provides concrete implementation steps for integrating AVC (Autonomous Village Collaborative) with Moodle LMS using NWP's existing infrastructure. The integration leverages:

- **Existing OAuth2 solution** at `~/opensocial-moodle-sso-integration`
- **NWP's recipe system** for automated deployment
- **DDEV local development** for testing
- **Linode production pipeline** for deployment

---

## Table of Contents

1. [NWP Architecture Overview](#nwp-architecture-overview)
2. [Integration Strategy](#integration-strategy)
3. [Recipe Configuration](#recipe-configuration)
4. [Module Structure](#module-structure)
5. [New Commands](#new-commands)
6. [Installation Workflow](#installation-workflow)
7. [Development Workflow](#development-workflow)
8. [Deployment Pipeline](#deployment-pipeline)
9. [Testing Strategy](#testing-strategy)
10. [Migration from Standalone](#migration-from-standalone)

---

## NWP Architecture Overview

### What is NWP?

**NWP (Narrow Way Project)** is a recipe-based, multi-site management system that automates:
- Site installation (Drupal, OpenSocial, Moodle, GitLab)
- Local development with DDEV
- Backup/restore operations
- Deployment to Linode production servers

### Current State

```
/home/rob/nwp/
├── sites/
│   ├── avc/              ← AVC OpenSocial site (Drupal)
│   │   ├── .ddev/
│   │   ├── html/         ← Webroot
│   │   └── vendor/
│   └── ss/               ← Moodle site (existing)
│       ├── .ddev/
│       ├── .git/         ← Moodle git repo
│       └── moodledata/
├── nwp.yml              ← User config (NEVER commit)
├── example.nwp.yml      ← Template (commit this)
├── pl                    ← CLI wrapper
├── scripts/commands/     ← All commands
└── lib/                  ← Shared libraries
```

**Key Insight:** NWP already supports both Drupal (AVC) and Moodle as separate site types. The integration adds SSO and data sync between them.

---

## Integration Strategy

### Three-Layer Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Layer 1: NWP Infrastructure                                 │
│  - Recipe definitions (example.nwp.yml)                     │
│  - Installation scripts (lib/install-avc-moodle-sso.sh)      │
│  - CLI commands (scripts/commands/avc-moodle-*.sh)           │
└─────────────────────────────────────────────────────────────┘
                           │
┌─────────────────────────▼─────────────────────────────────┐
│  Layer 2: Drupal Modules (AVC Side)                        │
│  - avc_moodle_oauth_provider/ (OAuth2 provider)            │
│  - avc_moodle_sync/ (Role/cohort synchronization)          │
│  - avc_moodle_data/ (Badge/completion display)             │
└─────────────────────────────────────────────────────────────┘
                           │
┌─────────────────────────▼─────────────────────────────────┐
│  Layer 3: Moodle Plugins (Moodle Side)                     │
│  - auth/avc_oauth2/ (OAuth2 authentication)                │
│  - local/cohortrole/ (Cohort→Role sync, existing plugin)   │
└─────────────────────────────────────────────────────────────┘
```

### Why This Approach?

1. **NWP manages infrastructure** - Installation, deployment, backups
2. **Drupal modules handle AVC logic** - Guild management, OAuth provider
3. **Moodle plugins handle LMS logic** - Authentication, user provisioning
4. **Clean separation** - Each layer has clear responsibilities

---

## Recipe Configuration

### Update `example.nwp.yml`

Add new recipe configuration options:

```yaml
# AVC Recipe with Moodle Integration
recipes:
  avc:
    source: nwp/avc-project
    profile: avc
    type: drupal
    webroot: html
    php: 8.2
    database: mariadb
    auto: y

    # NEW: Moodle Integration Options
    options:
      moodle_sso:
        label: "Moodle SSO Integration"
        description: "Enable OAuth2 SSO with Moodle"
        default: n
        requires: moodle_site

      moodle_role_sync:
        label: "Moodle Role Synchronization"
        description: "Auto-sync guild roles to Moodle cohorts"
        default: n
        requires: moodle_sso

      moodle_badge_display:
        label: "Moodle Badge Display"
        description: "Show Moodle badges on AVC profiles"
        default: n
        requires: moodle_sso

    # NEW: Integration Settings
    integration:
      moodle_site: ""           # Linked Moodle site name (e.g., 'ss')
      moodle_url: ""            # Moodle URL (auto-detected if empty)
      oauth2_token_lifetime: 300  # Seconds (5 minutes)
      sync_interval: 3600       # Seconds (1 hour cron)

      # Role Mapping: AVC Guild Role → Moodle Role
      role_mapping:
        guild_admin: manager
        guild_facilitator: teacher
        guild_member: student
        default: student

# Moodle Recipe (existing, with additions)
  m:
    type: moodle
    source: https://github.com/moodle/moodle.git
    branch: MOODLE_404_STABLE
    webroot: .
    sitename: "My Moodle Site"
    php: 8.1
    database: mariadb
    auto: y

    # NEW: AVC Integration Options
    options:
      avc_sso:
        label: "AVC SSO Integration"
        description: "Enable OAuth2 authentication from AVC"
        default: n
        requires: avc_site

    integration:
      avc_site: ""              # Linked AVC site name
      avc_url: ""               # AVC URL (auto-detected)
      default_role: student     # Role for all AVC members
```

### User Configuration in `nwp.yml`

After installation, users configure integration:

```yaml
sites:
  avc:
    directory: /home/rob/nwp/sites/avc
    recipe: avc
    environment: development
    moodle_integration:
      enabled: true
      moodle_site: ss
      options:
        - moodle_sso
        - moodle_role_sync
        - moodle_badge_display

  ss:
    directory: /home/rob/nwp/sites/ss
    recipe: m
    environment: development
    avc_integration:
      enabled: true
      avc_site: avc
      options:
        - avc_sso
```

---

## Module Structure

### Drupal Modules (AVC Side)

Store modules in NWP for distribution:

```
nwp/
├── modules/
│   └── avc_moodle/                    # Parent module
│       ├── avc_moodle.info.yml
│       ├── avc_moodle.module
│       ├── config/
│       │   └── install/
│       │       └── avc_moodle.settings.yml
│       │
│       ├── modules/
│       │   ├── avc_moodle_oauth/      # OAuth2 Provider
│       │   │   ├── avc_moodle_oauth.info.yml
│       │   │   ├── avc_moodle_oauth.routing.yml
│       │   │   └── src/
│       │   │       ├── Controller/
│       │   │       │   └── UserInfoController.php
│       │   │       └── Form/
│       │   │           └── SettingsForm.php
│       │   │
│       │   ├── avc_moodle_sync/       # Role/Cohort Sync
│       │   │   ├── avc_moodle_sync.info.yml
│       │   │   ├── avc_moodle_sync.module
│       │   │   └── src/
│       │   │       ├── MoodleApiClient.php
│       │   │       ├── RoleSyncService.php
│       │   │       ├── EventSubscriber/
│       │   │       │   └── GuildMembershipSubscriber.php
│       │   │       └── Form/
│       │   │           └── SettingsForm.php
│       │   │
│       │   └── avc_moodle_data/       # Badge/Completion Display
│       │       ├── avc_moodle_data.info.yml
│       │       ├── avc_moodle_data.module
│       │       └── src/
│       │           ├── MoodleDataService.php
│       │           ├── CacheManager.php
│       │           └── Plugin/
│       │               └── Block/
│       │                   ├── MoodleBadgesBlock.php
│       │                   └── MoodleCoursesBlock.php
│       │
│       └── templates/
│           ├── avc-moodle-badges.html.twig
│           └── avc-moodle-courses.html.twig
```

### Moodle Plugins (Moodle Side)

```
nwp/
├── moodle_plugins/
│   └── auth/
│       └── avc_oauth2/                # OAuth2 Auth Plugin
│           ├── version.php
│           ├── auth.php               # Authentication class
│           ├── settings.php           # Admin settings
│           ├── lang/
│           │   └── en/
│           │       └── auth_avc_oauth2.php
│           └── classes/
│               └── oauth2_client.php  # OAuth2 client logic
```

**Note:** Use existing `local_cohortrole` plugin for cohort→role mapping (no custom development needed).

---

## New Commands

Add these commands to `scripts/commands/`:

### 1. `avc-moodle-setup.sh` - Initial Configuration

```bash
#!/usr/bin/env bash
# Setup SSO integration between AVC and Moodle sites

# Usage: pl avc-moodle-setup <avc-site> <moodle-site>
# Example: pl avc-moodle-setup avc ss

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/avc-moodle.sh"

# Tasks:
# 1. Validate both sites exist and are correct types
# 2. Generate OAuth2 RSA keys (2048-bit)
# 3. Install avc_moodle modules in Drupal
# 4. Install auth_avc_oauth2 plugin in Moodle
# 5. Create OAuth2 client in AVC
# 6. Configure OAuth2 issuer in Moodle
# 7. Test SSO flow
# 8. Update nwp.yml with integration config
```

### 2. `avc-moodle-sync.sh` - Manual Sync Trigger

```bash
#!/usr/bin/env bash
# Manually trigger role/cohort synchronization

# Usage: pl avc-moodle-sync <avc-site> <moodle-site> [options]
# Options:
#   --full        Full sync (all users)
#   --guild=NAME  Sync specific guild only
#   --user=ID     Sync specific user only
#   --dry-run     Show what would be synced without doing it

# Example: pl avc-moodle-sync avc ss --full
```

### 3. `avc-moodle-test.sh` - Integration Testing

```bash
#!/usr/bin/env bash
# Test SSO and sync functionality

# Usage: pl avc-moodle-test <avc-site> <moodle-site>

# Tests:
# 1. OAuth2 endpoints accessible
# 2. Token generation works
# 3. User info endpoint returns data
# 4. Moodle can authenticate via OAuth2
# 5. Role mapping works correctly
# 6. Badge/completion APIs accessible
# 7. Cache system functioning
```

### 4. `avc-moodle-status.sh` - Integration Health Check

```bash
#!/usr/bin/env bash
# Display integration status and health

# Usage: pl avc-moodle-status <avc-site> <moodle-site>

# Output:
# ┌─────────────────────────────────────────┐
# │ AVC-Moodle Integration Status           │
# ├─────────────────────────────────────────┤
# │ SSO Status:           ✓ Active          │
# │ OAuth2 Endpoints:     ✓ Reachable       │
# │ Last Sync:            2 minutes ago     │
# │ Synced Users:         247               │
# │ Synced Cohorts:       12                │
# │ Failed Syncs:         0                 │
# │ Cache Hit Rate:       94%               │
# └─────────────────────────────────────────┘
```

### 5. `avc-moodle-disable.sh` - Disable Integration

```bash
#!/usr/bin/env bash
# Safely disable SSO integration (reversible)

# Usage: pl avc-moodle-disable <avc-site> <moodle-site>

# Actions:
# 1. Disable OAuth2 authentication in Moodle
# 2. Disable sync cron jobs
# 3. Preserve OAuth2 client (don't delete keys)
# 4. Update nwp.yml
```

---

## Installation Workflow

### Phase 1: Initial Setup (Both Sites Exist)

**Scenario:** You have existing AVC and Moodle sites, want to add SSO.

```bash
# Step 1: Install integration
pl avc-moodle-setup avc ss

# What happens:
# [1/10] Validating sites...
# [2/10] Generating OAuth2 RSA keys...
# [3/10] Installing Drupal modules...
# [4/10] Configuring Simple OAuth...
# [5/10] Creating OAuth2 client...
# [6/10] Installing Moodle plugin...
# [7/10] Configuring OAuth2 issuer...
# [8/10] Testing SSO flow...
# [9/10] Updating nwp.yml...
# [10/10] Complete!
#
# ✓ SSO enabled: https://avc.ddev.site → https://ss.ddev.site
# ✓ Test login: https://ss.ddev.site/login/index.php
# ✓ Admin panel: https://avc.ddev.site/admin/config/services/avc-moodle

# Step 2: Enable role synchronization
pl modify avc
# Interactive TUI:
# [x] Moodle SSO Integration
# [x] Moodle Role Synchronization  ← Enable this
# [ ] Moodle Badge Display

# Step 3: Configure role mapping
vim sites/avc/config/sync/avc_moodle_sync.settings.yml
# Edit role_mapping section

drush cr -l avc  # Clear cache

# Step 4: Test sync
pl avc-moodle-sync avc ss --dry-run
pl avc-moodle-sync avc ss --full

# Step 5: Enable badge display
pl modify avc
# [x] Moodle Badge Display  ← Enable this

drush cr -l avc
```

### Phase 2: Fresh Install with Integration

**Scenario:** Installing new AVC + Moodle with SSO from the start.

```bash
# Step 1: Install AVC with Moodle integration option
pl install avc avc-new

# During installation TUI:
# Options:
# [x] Moodle SSO Integration
# [x] Moodle Role Synchronization
# [x] Moodle Badge Display
#
# Integration Settings:
# Moodle site name: ss-new
# (Moodle will be installed automatically)

# What happens:
# 1. AVC installed normally
# 2. Moodle site 'ss-new' installed
# 3. OAuth2 configured automatically
# 4. Modules enabled
# 5. Default role mapping applied
# 6. Test credentials created

# Step 2: Verify integration
pl avc-moodle-status avc-new ss-new

# Step 3: Test SSO
open https://ss-new.ddev.site
# Click "Login with AVC"
```

---

## Development Workflow

### Local Development with DDEV

Both sites run in separate DDEV containers:

```bash
# Start both sites
cd sites/avc && ddev start
cd sites/ss && ddev start

# Access sites
# AVC:    https://avc.ddev.site
# Moodle: https://ss.ddev.site

# View logs
ddev logs -f -s web     # AVC logs
cd ../ss && ddev logs -f -s web  # Moodle logs

# Run sync manually
ddev exec -d /var/www/html drush avc-moodle:sync --full

# Clear caches
ddev drush cr            # AVC cache
cd ../ss && ddev exec php admin/cli/purge_caches.php  # Moodle
```

### Module Development

```bash
# Edit Drupal module
cd sites/avc/html/modules/contrib/avc_moodle/modules/avc_moodle_sync
vim src/RoleSyncService.php

# Test changes
cd ../../../../../  # Back to site root
ddev drush cr
ddev drush avc-moodle:sync --dry-run

# Run tests
ddev exec vendor/bin/phpunit \
  modules/contrib/avc_moodle/tests/src/Kernel/RoleSyncTest.php

# Commit changes
git add modules/contrib/avc_moodle
git commit -m "Fix: Improve role sync error handling"
```

### Debugging OAuth2 Flow

```bash
# Enable debug logging in AVC
ddev drush config:set avc_moodle_oauth.settings debug_mode 1

# Watch OAuth2 requests
ddev logs -f | grep oauth

# Test token generation
ddev drush avc-moodle:test-token

# Validate token manually
TOKEN="eyJhbGc..."
curl -H "Authorization: Bearer $TOKEN" \
  https://avc.ddev.site/oauth/userinfo
```

---

## Deployment Pipeline

### Development → Staging

```bash
# Create staging copies
pl dev2stg avc
pl dev2stg ss

# What happens:
# 1. Creates avc-stg and ss-stg sites
# 2. Copies OAuth2 keys
# 3. Updates OAuth2 URLs (avc.ddev.site → avc-stg.ddev.site)
# 4. Syncs databases
# 5. Switches to production mode
# 6. Tests SSO flow

# Verify integration
pl avc-moodle-status avc-stg ss-stg

# Test staging
open https://ss-stg.ddev.site
```

### Staging → Production (Linode)

```bash
# Deploy AVC to production
pl stg2prod avc-stg

# Deploy Moodle to production
pl stg2prod ss-stg

# What happens:
# 1. Backs up production (if exists)
# 2. Deploys code to Linode
# 3. Updates OAuth2 URLs for production domains
# 4. Rotates OAuth2 keys (optional, for security)
# 5. Runs database migrations
# 6. Tests SSO flow on production
# 7. Health check

# Monitor deployment
pl avc-moodle-status avc-prod ss-prod

# Rollback if needed
pl restore avc-prod --from-backup=2026-01-13_pre-sso
pl restore ss-prod --from-backup=2026-01-13_pre-sso
```

### Production URL Configuration

OAuth2 requires absolute URLs. NWP handles this automatically:

```yaml
# Development (DDEV)
oauth2_issuer: https://avc.ddev.site
oauth2_authorize_url: https://avc.ddev.site/oauth/authorize

# Staging (DDEV)
oauth2_issuer: https://avc-stg.ddev.site
oauth2_authorize_url: https://avc-stg.ddev.site/oauth/authorize

# Production (Linode)
oauth2_issuer: https://avc.nwpcode.org
oauth2_authorize_url: https://avc.nwpcode.org/oauth/authorize
```

NWP deployment scripts automatically update URLs during `stg2prod`.

---

## Testing Strategy

### Unit Tests

**Drupal Module Tests:**
```bash
# Run in DDEV container
cd sites/avc
ddev exec vendor/bin/phpunit \
  html/modules/contrib/avc_moodle/tests

# Tests:
# - RoleSyncServiceTest.php
# - MoodleApiClientTest.php
# - UserInfoControllerTest.php
# - CacheManagerTest.php
```

**Moodle Plugin Tests:**
```bash
cd sites/ss
ddev exec php admin/tool/phpunit/cli/init.php
ddev exec vendor/bin/phpunit \
  auth/avc_oauth2/tests/oauth2_test.php
```

### Integration Tests

```bash
# Automated integration test suite
pl avc-moodle-test avc ss

# Tests:
# ✓ OAuth2 endpoints reachable
# ✓ Token generation successful
# ✓ User info retrieval works
# ✓ Moodle authentication successful
# ✓ Role mapping correct
# ✓ Cohort sync functional
# ✓ Badge API accessible
# ✓ Completion API accessible
# ✓ Cache hit rate > 80%
#
# Result: 9/9 tests passed
```

### Manual Testing Checklist

```bash
# SSO Flow
[ ] 1. Visit Moodle login page
[ ] 2. Click "Login with AVC"
[ ] 3. Redirected to AVC (login if needed)
[ ] 4. Grant permission (first time)
[ ] 5. Redirected back to Moodle
[ ] 6. Logged in successfully
[ ] 7. User profile populated correctly

# Role Sync
[ ] 1. Create guild in AVC
[ ] 2. Add user as facilitator
[ ] 3. Check Moodle: user in correct cohort
[ ] 4. Check Moodle: user has teacher role
[ ] 5. Remove user from guild
[ ] 6. Check Moodle: user removed from cohort
[ ] 7. Check Moodle: teacher role revoked

# Badge Display
[ ] 1. Award badge in Moodle
[ ] 2. Wait for cache refresh (or clear cache)
[ ] 3. View AVC user profile
[ ] 4. Badge displays correctly
[ ] 5. Badge image loads
[ ] 6. Badge date accurate
```

### Load Testing

```bash
# Simulate 100 concurrent SSO logins
pl avc-moodle-load-test avc ss --users=100

# Monitor performance
ddev exec top                        # AVC CPU/memory
cd ../ss && ddev exec top            # Moodle CPU/memory

# Check logs for errors
ddev logs | grep -i error
cd ../ss && ddev logs | grep -i error

# Verify sync performance
pl avc-moodle-sync avc ss --full --benchmark
# Expected: < 5 seconds per 100 users
```

---

## Migration from Standalone

If you already tested the standalone OAuth2 solution in `~/opensocial-moodle-sso-integration`, migrate to NWP:

### Step 1: Export Configuration

```bash
cd ~/opensocial-moodle-sso-integration

# Export OAuth2 client details
cat opensocial1/.../oauth_client.json > /tmp/oauth_client.json

# Export OAuth2 keys
cp opensocial1/private/keys/oauth_private.key /tmp/
cp opensocial1/private/keys/oauth_public.key /tmp/

# Export role mapping configuration
cat config.yml > /tmp/role_mapping.yml
```

### Step 2: Import to NWP

```bash
cd ~/nwp

# Import OAuth2 keys
mkdir -p sites/avc/private/keys
cp /tmp/oauth_private.key sites/avc/private/keys/
cp /tmp/oauth_public.key sites/avc/private/keys/
chmod 600 sites/avc/private/keys/oauth_private.key
chmod 644 sites/avc/private/keys/oauth_public.key

# Import OAuth2 client to Drupal
cd sites/avc
ddev drush avc-moodle:import-client /tmp/oauth_client.json

# Import role mapping
vim html/config/sync/avc_moodle_sync.settings.yml
# Paste role mapping from /tmp/role_mapping.yml

ddev drush config:import -y
ddev drush cr
```

### Step 3: Reconfigure Moodle

```bash
cd sites/ss

# Get OAuth2 issuer URL from AVC
ISSUER=$(cd ../avc && ddev drush config:get avc_moodle_oauth.settings issuer_url --format=string)

# Reconfigure Moodle OAuth2 issuer
ddev exec php admin/cli/cfg.php --name=auth_avc_oauth2_issuer --set="$ISSUER"

# Test SSO
open https://ss.ddev.site
```

### Step 4: Verify and Clean Up

```bash
# Test integration
pl avc-moodle-test avc ss

# If successful, archive old installation
cd ~
tar czf opensocial-moodle-sso-integration-backup-$(date +%Y%m%d).tar.gz \
  opensocial-moodle-sso-integration/

mv opensocial-moodle-sso-integration-backup-*.tar.gz ~/backups/

# Optional: Remove old directory
rm -rf ~/opensocial-moodle-sso-integration
```

---

## Library Files

Create new library file for shared functions:

### `lib/avc-moodle.sh`

```bash
#!/usr/bin/env bash
# AVC-Moodle integration library functions

# Validate AVC site
avc_moodle_validate_avc_site() {
  local site=$1
  local site_dir=$(get_site_directory "$site")

  if [[ ! -d "$site_dir" ]]; then
    error "AVC site '$site' not found"
    return 1
  fi

  local recipe=$(get_site_recipe "$site")
  if [[ "$recipe" != "avc" && "$recipe" != "os" ]]; then
    error "Site '$site' is not an AVC/OpenSocial site (recipe: $recipe)"
    return 1
  fi

  return 0
}

# Validate Moodle site
avc_moodle_validate_moodle_site() {
  local site=$1
  local site_dir=$(get_site_directory "$site")

  if [[ ! -d "$site_dir" ]]; then
    error "Moodle site '$site' not found"
    return 1
  fi

  local recipe=$(get_site_recipe "$site")
  if [[ "$recipe" != "m" ]]; then
    error "Site '$site' is not a Moodle site (recipe: $recipe)"
    return 1
  fi

  return 0
}

# Generate OAuth2 RSA key pair
avc_moodle_generate_keys() {
  local site=$1
  local key_dir="$SITES_DIR/$site/private/keys"

  mkdir -p "$key_dir"

  info "Generating 2048-bit RSA key pair..."

  openssl genrsa -out "$key_dir/oauth_private.key" 2048
  openssl rsa -in "$key_dir/oauth_private.key" -pubout -out "$key_dir/oauth_public.key"

  chmod 600 "$key_dir/oauth_private.key"
  chmod 644 "$key_dir/oauth_public.key"

  success "Keys generated at $key_dir"
}

# Get OAuth2 issuer URL for site
avc_moodle_get_issuer_url() {
  local site=$1
  local site_dir=$(get_site_directory "$site")

  cd "$site_dir"

  # Get URL from DDEV or production config
  if [[ -f ".ddev/config.yaml" ]]; then
    # DDEV environment
    local primary_url=$(ddev describe -j | jq -r '.raw.primary_url')
    echo "$primary_url"
  else
    # Production environment
    local domain=$(drush config:get system.site base_url --format=string 2>/dev/null)
    echo "$domain"
  fi
}

# Test OAuth2 endpoint accessibility
avc_moodle_test_oauth_endpoint() {
  local url=$1
  local endpoint=$2

  local full_url="$url$endpoint"

  local status=$(curl -s -o /dev/null -w "%{http_code}" "$full_url")

  if [[ "$status" == "200" || "$status" == "302" || "$status" == "401" ]]; then
    # 200 = OK, 302 = redirect (normal for /authorize), 401 = auth required (expected)
    return 0
  else
    return 1
  fi
}

# Display integration status
avc_moodle_display_status() {
  local avc_site=$1
  local moodle_site=$2

  # Get integration config
  local avc_dir=$(get_site_directory "$avc_site")
  local moodle_dir=$(get_site_directory "$moodle_site")

  # Check if integration enabled
  local enabled=$(yq eval ".sites.$avc_site.moodle_integration.enabled" "$CNWP_YML" 2>/dev/null)

  # Get last sync time
  local last_sync=$(cd "$avc_dir" && ddev drush state:get avc_moodle_sync.last_sync 2>/dev/null || echo "Never")

  # Get sync stats
  local synced_users=$(cd "$avc_dir" && ddev drush state:get avc_moodle_sync.synced_users 2>/dev/null || echo "0")
  local failed_syncs=$(cd "$avc_dir" && ddev drush state:get avc_moodle_sync.failed_syncs 2>/dev/null || echo "0")

  # Get cache stats
  local cache_hits=$(cd "$avc_dir" && ddev drush state:get avc_moodle_data.cache_hits 2>/dev/null || echo "0")
  local cache_misses=$(cd "$avc_dir" && ddev drush state:get avc_moodle_data.cache_misses 2>/dev/null || echo "0")
  local cache_total=$((cache_hits + cache_misses))
  local cache_rate=0
  if [[ $cache_total -gt 0 ]]; then
    cache_rate=$((cache_hits * 100 / cache_total))
  fi

  # Display status
  echo ""
  echo "┌─────────────────────────────────────────────────────────┐"
  echo "│ AVC-Moodle Integration Status                           │"
  echo "├─────────────────────────────────────────────────────────┤"

  if [[ "$enabled" == "true" ]]; then
    echo "│ SSO Status:           ✓ Active                          │"
  else
    echo "│ SSO Status:           ✗ Disabled                        │"
  fi

  # Test OAuth2 endpoints
  local avc_url=$(avc_moodle_get_issuer_url "$avc_site")
  if avc_moodle_test_oauth_endpoint "$avc_url" "/oauth/authorize"; then
    echo "│ OAuth2 Endpoints:     ✓ Reachable                       │"
  else
    echo "│ OAuth2 Endpoints:     ✗ Not Reachable                   │"
  fi

  echo "│ Last Sync:            $last_sync                         │"
  echo "│ Synced Users:         $synced_users                      │"
  echo "│ Failed Syncs:         $failed_syncs                      │"
  echo "│ Cache Hit Rate:       $cache_rate%                       │"
  echo "└─────────────────────────────────────────────────────────┘"
  echo ""
}

# Export functions
export -f avc_moodle_validate_avc_site
export -f avc_moodle_validate_moodle_site
export -f avc_moodle_generate_keys
export -f avc_moodle_get_issuer_url
export -f avc_moodle_test_oauth_endpoint
export -f avc_moodle_display_status
```

---

## Security Considerations

### OAuth2 Key Management

```bash
# Keys stored in private directory (not in webroot)
sites/avc/private/keys/
├── oauth_private.key    # 600 permissions (owner read/write only)
└── oauth_public.key     # 644 permissions (world readable)

# Keys never committed to git
# .gitignore includes:
private/keys/*
```

### Secrets Storage

```yaml
# .secrets.yml (infrastructure tier - AI can read)
moodle:
  oauth2:
    client_id: "avc_moodle_client"
    client_secret: "generated_secret_here"
    key_path: "/var/www/html/private/keys/oauth_private.key"

# .secrets.data.yml (data tier - AI cannot read)
# Not used for OAuth2 (only for production DB passwords, etc.)
```

### Production Hardening

When deploying to production, NWP automatically:
1. Switches to production mode (disables dev modules)
2. Enables security modules (security_kit, etc.)
3. Enforces HTTPS
4. Restricts file permissions
5. Enables production caching
6. Disables debug logging

---

## Monitoring and Maintenance

### Cron Jobs

NWP automatically configures cron:

```bash
# AVC site cron (includes role sync)
0 * * * * cd /var/www/avc && drush cron

# Moodle site cron
*/5 * * * * cd /var/www/ss && php admin/cli/cron.php
```

### Log Monitoring

```bash
# Watch integration logs
pl logs avc | grep avc_moodle
pl logs ss | grep avc_oauth2

# Check sync errors
cd sites/avc
ddev drush watchdog:show --type=avc_moodle_sync --severity=error

# Check OAuth2 errors
ddev drush watchdog:show --type=avc_moodle_oauth --severity=error
```

### Health Checks

```bash
# Add to NWP health check script
# lib/healthcheck.sh

check_avc_moodle_integration() {
  local avc_site=$1
  local moodle_site=$2

  # Check if integration enabled
  local enabled=$(yq eval ".sites.$avc_site.moodle_integration.enabled" "$CNWP_YML")

  if [[ "$enabled" != "true" ]]; then
    return 0  # Not enabled, skip check
  fi

  # Test OAuth2 endpoint
  local avc_url=$(avc_moodle_get_issuer_url "$avc_site")
  if ! avc_moodle_test_oauth_endpoint "$avc_url" "/oauth/userinfo"; then
    error "AVC OAuth2 endpoint not reachable"
    return 1
  fi

  # Check last sync time
  local last_sync=$(cd "$(get_site_directory "$avc_site")" && \
    ddev drush state:get avc_moodle_sync.last_sync_timestamp 2>/dev/null || echo "0")

  local now=$(date +%s)
  local age=$((now - last_sync))

  if [[ $age -gt 7200 ]]; then  # 2 hours
    warning "Last sync was $age seconds ago (> 2 hours)"
  fi

  return 0
}
```

---

## Troubleshooting

### Common Issues

#### 1. OAuth2 Token Invalid

```bash
# Symptom: "Invalid token" error in Moodle

# Check token lifetime
cd sites/avc
ddev drush config:get simple_oauth.settings token_expiration

# Regenerate keys
pl avc-moodle-setup avc ss --regenerate-keys

# Clear Moodle cache
cd sites/ss
ddev exec php admin/cli/purge_caches.php
```

#### 2. Role Sync Not Working

```bash
# Check sync logs
cd sites/avc
ddev drush watchdog:show --type=avc_moodle_sync --count=20

# Test Moodle Web Services access
ddev drush avc-moodle:test-api

# Manual sync with verbose output
ddev drush avc-moodle:sync --full --verbose
```

#### 3. Badge Display Empty

```bash
# Clear cache
cd sites/avc
ddev drush cache:rebuild

# Test Moodle API directly
ddev drush avc-moodle:test-badges --user=1

# Check API credentials
ddev drush config:get avc_moodle_data.settings api_token
```

#### 4. HTTPS Redirect Loop

```bash
# Check OAuth2 redirect URIs
cd sites/ss
ddev exec php admin/cli/cfg.php --name=auth_avc_oauth2_redirect_uri

# Should match: https://ss.ddev.site/admin/oauth2callback.php

# Update if wrong
ddev exec php admin/cli/cfg.php \
  --name=auth_avc_oauth2_redirect_uri \
  --set="https://ss.ddev.site/admin/oauth2callback.php"
```

---

## Next Steps

### Immediate Actions

1. **Review this implementation guide** with stakeholders
2. **Answer technical questions** from `AVC_MOODLE_INTEGRATION_PROPOSAL.md`
3. **Choose integration scope** (SSO only? Role sync? Badge display?)
4. **Set up development environment**
   ```bash
   cd ~/nwp
   git checkout -b feature/avc-moodle-sso
   ```

### Development Phases

**Phase 1: Core Infrastructure (Week 1)**
- [ ] Create `lib/avc-moodle.sh` library
- [ ] Update `example.nwp.yml` with integration options
- [ ] Create `scripts/commands/avc-moodle-setup.sh`
- [ ] Test with existing AVC + Moodle sites

**Phase 2: Drupal Modules (Week 2-3)**
- [ ] Port OAuth2 provider from standalone solution
- [ ] Create role sync module
- [ ] Create badge display module
- [ ] Write unit tests

**Phase 3: Moodle Plugin (Week 3-4)**
- [ ] Port OAuth2 auth plugin from standalone solution
- [ ] Configure cohort-role plugin
- [ ] Write integration tests

**Phase 4: Testing & Documentation (Week 4-5)**
- [ ] Full integration testing
- [ ] Load testing
- [ ] User documentation
- [ ] Admin documentation

**Phase 5: Deployment (Week 5-6)**
- [ ] Deploy to staging
- [ ] User acceptance testing
- [ ] Deploy to production
- [ ] Monitor and optimize

---

## Success Criteria

### Phase 1 Complete When:
- [ ] `pl avc-moodle-setup avc ss` works end-to-end
- [ ] SSO login successful in DDEV
- [ ] All configuration stored in `nwp.yml`
- [ ] Commands pass shellcheck

### Phase 2 Complete When:
- [ ] All Drupal modules installed via `pl`
- [ ] OAuth2 provider functional
- [ ] Role sync module passes unit tests
- [ ] Badge display module passes unit tests

### Phase 3 Complete When:
- [ ] Moodle plugin installed via `pl`
- [ ] OAuth2 authentication works
- [ ] Cohort-role sync functional
- [ ] Integration tests pass

### Production Ready When:
- [ ] All phases complete
- [ ] 95%+ test coverage
- [ ] Load tested (100+ concurrent users)
- [ ] Documentation complete
- [ ] Monitoring in place
- [ ] Backup/restore tested

---

## Appendix: File Locations

### NWP Core Files
```
nwp/
├── nwp.yml                          # User config (local only)
├── example.nwp.yml                  # Template (commit)
├── pl                                # CLI wrapper
├── scripts/
│   └── commands/
│       ├── avc-moodle-setup.sh       # NEW
│       ├── avc-moodle-sync.sh        # NEW
│       ├── avc-moodle-test.sh        # NEW
│       ├── avc-moodle-status.sh      # NEW
│       └── avc-moodle-disable.sh     # NEW
└── lib/
    ├── avc-moodle.sh                 # NEW
    ├── install-moodle.sh             # Existing, extend
    └── install-drupal.sh             # Existing, extend
```

### Drupal Modules
```
sites/avc/html/modules/contrib/avc_moodle/
├── avc_moodle.info.yml
├── avc_moodle.module
└── modules/
    ├── avc_moodle_oauth/
    ├── avc_moodle_sync/
    └── avc_moodle_data/
```

### Moodle Plugins
```
sites/ss/auth/avc_oauth2/
├── version.php
├── auth.php
├── settings.php
└── classes/
```

### Configuration Files
```
sites/avc/html/config/sync/
├── avc_moodle_oauth.settings.yml
├── avc_moodle_sync.settings.yml
└── avc_moodle_data.settings.yml

sites/avc/private/keys/
├── oauth_private.key
└── oauth_public.key
```

---

## Document History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2026-01-13 | Claude Code | Initial NWP implementation guide based on existing infrastructure analysis and AVC-Moodle integration proposal |

---

**END OF IMPLEMENTATION GUIDE**
