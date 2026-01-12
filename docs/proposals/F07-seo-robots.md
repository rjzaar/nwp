# SEO & Search Engine Control Proposal

A proposal for comprehensive search engine control across all NWP environments, ensuring staging sites are protected from indexing while production sites are properly optimized.

**Status:** PROPOSAL
**Created:** January 2026
**Related:** [Roadmap](../governance/roadmap.md), [Distributed Contribution Governance](../governance/distributed-contribution-governance.md)

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Current State Analysis](#current-state-analysis)
3. [Problems Identified](#problems-identified)
4. [Proposed Solutions](#proposed-solutions)
5. [Implementation Details](#implementation-details)
6. [Success Criteria](#success-criteria)

---

## Executive Summary

NWP sites currently have **no environment-aware search engine controls**. This creates two distinct problems:

1. **Staging sites are indexable** - Search engines can crawl and index staging content, causing duplicate content penalties, exposed test data, and SEO confusion
2. **Production sites lack SEO optimization** - No sitemap.xml references, missing meta tags, incomplete robots.txt configuration

This proposal establishes a layered defense for staging sites and SEO best practices for production sites.

---

## Current State Analysis

### Live/Production Sites

| Feature | Current State | Issue |
|---------|---------------|-------|
| robots.txt | Standard Drupal default | Missing sitemap reference |
| Sitemap.xml | Not configured | Search engines can't discover content efficiently |
| Meta robots | Not set globally | Relies on page-level config only |
| X-Robots-Tag | Not implemented | N/A for production |
| Canonical URLs | Drupal default | Works but not verified |

**Example: avc.nwpcode.org**
```
robots.txt: Standard Drupal (allows crawling, blocks /admin/, /user/, etc.)
sitemap.xml: Returns 404 (NOT CONFIGURED)
X-Robots-Tag: None
```

### Staging Sites

| Feature | Current State | Issue |
|---------|---------------|-------|
| robots.txt | **Identical to production** | Allows full crawling |
| X-Robots-Tag | Not implemented | No header-level protection |
| Meta robots | Not set | No page-level protection |
| HTTP Auth | Not enforced | Publicly accessible |
| noindex meta | Not configured | Pages can be indexed |

**Critical Risk**: Staging sites (e.g., `avc-stg.nwpcode.org`) are fully indexable by search engines.

### Environment Detection

NWP already detects environments via suffixes in `lib/install-common.sh`:
- `-stg` = Staging
- `_live` / `_prod` = Production
- No suffix = Development/Local

This detection is **not used** for SEO/robots.txt controls.

---

## Problems Identified

### Problem 1: Staging Site Indexation (Critical)

**Impact**: HIGH
**Likelihood**: CERTAIN (already happening)

Search engines will index staging sites because:
- robots.txt allows crawling
- No X-Robots-Tag headers block indexing
- No meta robots tags on pages
- Sites are publicly accessible

**Consequences**:
- Duplicate content penalties in Google
- Test/dummy data appears in search results
- Staging URLs compete with production URLs
- Potential exposure of development features/bugs

### Problem 2: Missing Sitemap.xml (High)

**Impact**: MEDIUM
**Likelihood**: CERTAIN

Production sites have no sitemap.xml configured:
- Search engines can't efficiently discover content
- New pages may take longer to be indexed
- No insight into indexation status
- robots.txt doesn't reference sitemap

### Problem 3: Incomplete robots.txt (Medium)

**Impact**: LOW-MEDIUM
**Likelihood**: LIKELY

Current robots.txt issues:
- No `Sitemap:` directive pointing to sitemap.xml
- No crawl-delay for aggressive bots
- No specific rules for AI crawlers (GPTBot, ClaudeBot, etc.)
- Same file used across all environments

### Problem 4: No Meta Robots Defaults (Medium)

**Impact**: MEDIUM
**Likelihood**: POSSIBLE

Drupal metatag module findings:
- 403 pages: Has `noindex` (correct)
- 404 pages: Missing `noindex` (should have it)
- Global default: No robots meta tag
- No staging-specific configuration

---

## Proposed Solutions

### Solution Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    ENVIRONMENT DETECTION                         │
│              (existing: lib/install-common.sh)                   │
└─────────────────────────────┬───────────────────────────────────┘
                              │
              ┌───────────────┴───────────────┐
              │                               │
              ▼                               ▼
┌─────────────────────────┐     ┌─────────────────────────┐
│     STAGING SITES       │     │   PRODUCTION SITES      │
│    (block indexing)     │     │   (optimize indexing)   │
└─────────────────────────┘     └─────────────────────────┘
              │                               │
              ▼                               ▼
┌─────────────────────────┐     ┌─────────────────────────┐
│ Layer 1: X-Robots-Tag   │     │ Layer 1: Sitemap.xml    │
│   "noindex, nofollow"   │     │   Auto-generated        │
├─────────────────────────┤     ├─────────────────────────┤
│ Layer 2: robots.txt     │     │ Layer 2: robots.txt     │
│   "Disallow: /"         │     │   + Sitemap directive   │
├─────────────────────────┤     │   + AI bot rules        │
│ Layer 3: Meta robots    │     ├─────────────────────────┤
│   noindex on all pages  │     │ Layer 3: Meta robots    │
├─────────────────────────┤     │   Proper canonical URLs │
│ Layer 4: HTTP Basic Auth│     ├─────────────────────────┤
│   Optional but advised  │     │ Layer 4: Structured     │
└─────────────────────────┘     │   Data / Schema.org     │
                                └─────────────────────────┘
```

### Staging Protection Layers

**Why multiple layers?**
- robots.txt is advisory; malicious bots ignore it
- X-Robots-Tag is authoritative but requires HTTP response
- Meta tags work for HTML but not images/PDFs
- HTTP Auth is the ultimate protection

| Layer | Protection | Bypassed By |
|-------|------------|-------------|
| robots.txt | Polite bots | Malicious crawlers, direct links |
| X-Robots-Tag | All HTTP clients | Direct file access |
| Meta robots | HTML parsers | Non-HTML resources |
| HTTP Basic Auth | Nothing | Leaked credentials only |

### Production Optimization

| Feature | Purpose |
|---------|---------|
| Sitemap.xml | Efficient content discovery |
| robots.txt Sitemap directive | Points bots to sitemap |
| AI bot rules | Control GPTBot, ClaudeBot, etc. |
| Canonical URLs | Prevent duplicate content |
| Structured data | Rich search results |

---

## Implementation Details

### 1. Staging: X-Robots-Tag Header

**File**: `scripts/commands/stg2live.sh` (nginx config generation)

Add to staging server blocks:
```nginx
# Block search engine indexing for staging sites
add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet" always;
```

**Detection Logic**:
```bash
# In nginx config generation
if [[ "$site_name" == *"-stg"* ]] || [[ "$site_name" == *"_stg"* ]]; then
    # Add X-Robots-Tag header
fi
```

### 2. Staging: Environment-Specific robots.txt

**Option A**: Nginx rewrite (recommended)
```nginx
# For staging sites, serve blocking robots.txt
location = /robots.txt {
    return 200 "User-agent: *\nDisallow: /\n";
    add_header Content-Type text/plain;
}
```

**Option B**: Deploy different file
```bash
# In deployment script
if is_staging_site "$site_name"; then
    cp templates/robots-staging.txt "$webroot/robots.txt"
fi
```

**Template**: `templates/robots-staging.txt`
```
# Staging site - DO NOT INDEX
User-agent: *
Disallow: /

# Prevent all archiving
User-agent: ia_archiver
Disallow: /
```

### 3. Production: Enhanced robots.txt

**Template**: `templates/robots-production.txt`
```
#
# robots.txt - Production Site
#
# This file controls search engine crawling behavior.
# Last updated: [DATE]
#

User-agent: *
# CSS, JS, Images (allow for rendering)
Allow: /core/*.css$
Allow: /core/*.js$
Allow: /core/*.gif
Allow: /core/*.jpg
Allow: /core/*.jpeg
Allow: /core/*.png
Allow: /core/*.svg
Allow: /profiles/*.css$
Allow: /profiles/*.js$

# Block admin and system paths
Disallow: /core/
Disallow: /profiles/
Disallow: /admin/
Disallow: /comment/reply/
Disallow: /filter/tips
Disallow: /node/add/
Disallow: /search/
Disallow: /user/
Disallow: /media/oembed
Disallow: /*/media/oembed

# Block index.php versions
Disallow: /index.php/

# Block common Drupal files
Disallow: /README.md
Disallow: /web.config
Disallow: /CHANGELOG.txt
Disallow: /INSTALL.txt
Disallow: /LICENSE.txt

# Crawl rate limiting (optional)
Crawl-delay: 1

# AI Crawler Controls
# Uncomment to block AI training crawlers
# User-agent: GPTBot
# Disallow: /
# User-agent: ClaudeBot
# Disallow: /
# User-agent: Google-Extended
# Disallow: /
# User-agent: CCBot
# Disallow: /

# Sitemap location
Sitemap: https://[DOMAIN]/sitemap.xml
```

### 4. Production: Sitemap.xml Configuration

**Drupal Module**: Simple XML Sitemap (recommended)
```bash
ddev composer require drupal/simple_sitemap
ddev drush en simple_sitemap
```

**Configuration** (exportable):
```yaml
# config/sync/simple_sitemap.settings.yml
settings:
  max_links: 2000
  cron_generate: true
  remove_duplicates: true
  skip_untranslated: true
```

**Nginx location block**:
```nginx
location = /sitemap.xml {
    try_files $uri @drupal;
}
```

### 5. Metatag Configuration Fixes

**404 pages** - Add noindex:
```yaml
# metatag.metatag_defaults.404.yml
tags:
  robots: 'noindex, nofollow'
```

**Staging global override** (via config split):
```yaml
# config/staging/metatag.metatag_defaults.global.yml
tags:
  robots: 'noindex, nofollow, noarchive'
```

### 6. Optional: HTTP Basic Auth for Staging

**Nginx configuration**:
```nginx
# For staging sites
auth_basic "Staging Site";
auth_basic_user_file /etc/nginx/.htpasswd;

# Allow specific paths without auth (health checks, etc.)
location = /health {
    auth_basic off;
}
```

**Password file generation** (in deployment):
```bash
# Generate htpasswd during staging deployment
htpasswd -bc /etc/nginx/.htpasswd staging "$STAGING_PASSWORD"
```

### 7. Recipe/cnwp.yml Integration

**New settings in cnwp.yml**:
```yaml
settings:
  seo:
    # Staging protection
    staging_noindex: true           # Add X-Robots-Tag to staging
    staging_robots_block: true      # Use blocking robots.txt on staging
    staging_http_auth: false        # Enable HTTP Basic Auth on staging

    # Production optimization
    sitemap_enabled: true           # Enable sitemap.xml generation
    ai_bots_allowed: true           # Allow AI training crawlers
    crawl_delay: 1                  # Seconds between requests
```

**Recipe override example**:
```yaml
recipes:
  nwp:
    seo:
      ai_bots_allowed: false        # Block AI crawlers for this recipe
```

---

## Implementation Plan

### Phase 1: Critical Protection (Immediate)

- [ ] Add X-Robots-Tag header to staging sites in stg2live.sh
- [ ] Create `templates/robots-staging.txt`
- [ ] Add environment detection to nginx config generation
- [ ] Deploy to existing staging sites (avc-stg, etc.)

### Phase 2: Production Optimization

- [ ] Create `templates/robots-production.txt` with sitemap reference
- [ ] Document Simple XML Sitemap module setup
- [ ] Add sitemap.xml location block to nginx configs
- [ ] Update production sites with new robots.txt

### Phase 3: Drupal Configuration

- [ ] Fix 404 metatag noindex configuration
- [ ] Create staging config split for metatag
- [ ] Export and document configuration

### Phase 4: Recipe Integration

- [ ] Add `seo` settings section to cnwp.yml schema
- [ ] Update example.cnwp.yml with SEO options
- [ ] Integrate settings into deployment scripts
- [ ] Document in NWP_TRAINING_BOOKLET.md

### Phase 5: Optional Enhancements

- [ ] HTTP Basic Auth implementation for staging
- [ ] AI crawler control configuration
- [ ] Monitoring for staging indexation
- [ ] Google Search Console integration guide

---

## Success Criteria

### Staging Sites

- [ ] X-Robots-Tag header present: `noindex, nofollow`
- [ ] robots.txt returns `Disallow: /`
- [ ] No staging pages appear in Google search results
- [ ] Test: `curl -sI https://site-stg.domain.org | grep X-Robots-Tag`

### Production Sites

- [ ] robots.txt includes `Sitemap:` directive
- [ ] sitemap.xml returns valid XML
- [ ] 404 pages have `noindex` meta tag
- [ ] Google Search Console shows no errors
- [ ] Test: `curl -s https://site.domain.org/sitemap.xml | head -5`

### Configuration

- [ ] SEO settings in cnwp.yml documented
- [ ] Templates in `templates/` directory
- [ ] Deployment scripts handle environment detection
- [ ] Existing sites updated

---

## Verification Commands

```bash
# Check staging protection
curl -sI https://avc-stg.nwpcode.org | grep -i "x-robots-tag"
# Expected: X-Robots-Tag: noindex, nofollow

curl -s https://avc-stg.nwpcode.org/robots.txt
# Expected: User-agent: * / Disallow: /

# Check production optimization
curl -s https://avc.nwpcode.org/robots.txt | grep -i sitemap
# Expected: Sitemap: https://avc.nwpcode.org/sitemap.xml

curl -sI https://avc.nwpcode.org/sitemap.xml
# Expected: HTTP/2 200, Content-Type: application/xml
```

---

## References

- [Google robots.txt Specification](https://developers.google.com/search/docs/crawling-indexing/robots/robots_txt)
- [X-Robots-Tag HTTP Header](https://developers.google.com/search/docs/crawling-indexing/robots-meta-tag)
- [Drupal Simple XML Sitemap](https://www.drupal.org/project/simple_sitemap)
- [Drupal Metatag Module](https://www.drupal.org/project/metatag)
- [AI Crawler Control](https://platform.openai.com/docs/gptbot)

---

*Proposal created: January 2026*
*Status: Ready for review*
