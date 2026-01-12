# SEO Setup Guide

This guide covers how to configure search engine optimization (SEO) for NWP sites, including staging protection and production optimization.

**See also:** `docs/SEO_ROBOTS_PROPOSAL.md` for the complete specification

---

## Table of Contents

1. [Quick Start](#quick-start)
2. [Staging Site Protection](#staging-site-protection)
3. [Production Site Optimization](#production-site-optimization)
4. [Sitemap Configuration](#sitemap-configuration)
5. [SEO Monitoring](#seo-monitoring)
6. [Troubleshooting](#troubleshooting)

---

## Quick Start

### Check Your Site's SEO Status

```bash
# Full SEO check
./scripts/commands/seo-check.sh check mysite

# Check staging protection only
./scripts/commands/seo-check.sh staging mysite-stg

# Check production SEO only
./scripts/commands/seo-check.sh production mysite
```

### Verify Staging Protection is Working

```bash
# Check X-Robots-Tag header
curl -sI https://mysite-stg.example.com | grep -i x-robots-tag
# Expected: X-Robots-Tag: noindex, nofollow

# Check robots.txt
curl -s https://mysite-stg.example.com/robots.txt
# Expected: User-agent: * / Disallow: /

# Use the seo-check script
./scripts/commands/seo-check.sh staging mysite-stg --domain mysite-stg.example.com
```

---

## Staging Site Protection

Staging sites should **never** be indexed by search engines. NWP uses a layered defense approach:

### Layer 1: X-Robots-Tag Header (Most Effective)

The nginx configuration for staging sites automatically adds:

```nginx
add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet" always;
```

**Verify it's working:**
```bash
curl -sI https://mysite-stg.example.com | grep -i x-robots-tag
```

If missing, check your nginx configuration in `/etc/nginx/sites-available/`.

### Layer 2: robots.txt

Staging sites use `templates/robots-staging.txt` which blocks all crawlers:

```
User-agent: *
Disallow: /
```

**Deploy to staging:**
```bash
# Copy staging robots.txt to webroot
cp templates/robots-staging.txt /var/www/mysite-stg/html/robots.txt
```

### Layer 3: Meta Robots Tags (Drupal)

Configure the Metatag module to add noindex to all pages on staging:

1. Install and enable Metatag if not already present:
   ```bash
   ddev composer require drupal/metatag
   ddev drush en metatag -y
   ```

2. Go to `/admin/config/search/metatag`

3. Edit "Global" defaults and add:
   - Robots: `noindex, nofollow`

4. Export config:
   ```bash
   ddev drush cex -y
   ```

### Layer 4: HTTP Basic Auth (Optional)

For sensitive staging sites, add HTTP Basic Authentication:

```nginx
# In nginx server block for staging
auth_basic "Staging Site";
auth_basic_user_file /etc/nginx/.htpasswd-staging;

# Allow health checks without auth
location = /health {
    auth_basic off;
}
```

Generate password file:
```bash
htpasswd -bc /etc/nginx/.htpasswd-staging staginguser "your-secure-password"
```

---

## Production Site Optimization

Production sites should be properly configured for search engine indexing.

### robots.txt Configuration

Production sites use `templates/robots-production.txt` which:
- Allows crawling of content
- Blocks admin paths
- References sitemap.xml
- Optionally controls AI crawlers

**Deploy to production:**
```bash
# Copy production robots.txt (replace [DOMAIN] with actual domain)
sed 's/\[DOMAIN\]/example.com/g' templates/robots-production.txt > /var/www/mysite/html/robots.txt
```

### Required Drupal Modules

For full SEO functionality, install these modules:

1. **Metatag** - Meta tags for all pages
2. **Simple XML Sitemap** - Generate sitemap.xml
3. **Pathauto** - Clean URLs
4. **Redirect** - Handle URL redirects

```bash
ddev composer require drupal/metatag drupal/simple_sitemap drupal/pathauto drupal/redirect
ddev drush en metatag simple_sitemap pathauto redirect -y
```

---

## Sitemap Configuration

### Installing Simple XML Sitemap

```bash
# Install the module
ddev composer require drupal/simple_sitemap

# Enable it
ddev drush en simple_sitemap -y

# Clear cache
ddev drush cr
```

### Configuring the Sitemap

1. Go to `/admin/config/search/simplesitemap`

2. **Settings tab:**
   - Max links per sitemap: 2000 (recommended)
   - Generate during cron: Yes
   - Remove duplicates: Yes

3. **Entities tab:**
   - Enable for Content types you want indexed
   - Enable for Taxonomy vocabularies if needed
   - Set default priority and change frequency

4. **Custom links tab:**
   - Add important pages not auto-detected

### Generating the Sitemap

```bash
# Generate sitemap manually
ddev drush simple-sitemap:generate

# Or via cron (recommended for production)
# Sitemap regenerates during each cron run
```

### Verifying the Sitemap

```bash
# Check sitemap exists and is valid
curl -sI https://example.com/sitemap.xml
# Expected: HTTP/2 200, Content-Type: application/xml

# View sitemap content
curl -s https://example.com/sitemap.xml | head -20

# Use seo-check script
./scripts/commands/seo-check.sh sitemap mysite --domain example.com
```

### Drush Commands for Simple Sitemap

```bash
# Generate sitemap
ddev drush simple-sitemap:generate

# Rebuild sitemap (full regeneration)
ddev drush simple-sitemap:rebuild

# Check sitemap status
ddev drush simple-sitemap:status
```

---

## SEO Monitoring

### Using the SEO Check Script

The `seo-check.sh` script provides comprehensive SEO monitoring:

```bash
# Full check (robots.txt, headers, sitemap)
./scripts/commands/seo-check.sh check mysite

# Staging-specific checks
./scripts/commands/seo-check.sh staging mysite-stg

# Production-specific checks
./scripts/commands/seo-check.sh production mysite

# Sitemap only
./scripts/commands/seo-check.sh sitemap mysite

# Check HTTP headers
./scripts/commands/seo-check.sh headers mysite

# Check indexation risk (for any domain)
./scripts/commands/seo-check.sh index-risk mysite-stg.example.com
```

### Adding to Automated Checks

Add SEO checks to your CI/CD or cron:

```bash
# Add to crontab for daily monitoring
0 8 * * * /path/to/nwp/scripts/commands/seo-check.sh check mysite --quiet >> /var/log/seo-check.log 2>&1
```

### Manual Verification Commands

```bash
# Check X-Robots-Tag header
curl -sI https://example.com | grep -i x-robots-tag

# Check robots.txt content
curl -s https://example.com/robots.txt

# Check sitemap exists
curl -sI https://example.com/sitemap.xml

# Check for meta robots in HTML
curl -s https://example.com | grep -i 'name="robots"'

# Check Google indexation (search query simulation)
# Note: This is just informational, not actual Google data
echo "To check actual indexation, search Google for: site:example.com"
```

### Monitoring for Accidental Staging Indexation

If you suspect a staging site has been indexed:

1. **Check Google Search Console** (if configured)
   - Look for staging URLs in the index

2. **Google Search:**
   ```
   site:mysite-stg.example.com
   ```
   - If results appear, the site has been indexed

3. **Request removal:**
   - Fix staging protection (add X-Robots-Tag, update robots.txt)
   - Use Google Search Console to request URL removal
   - Wait for re-crawl

4. **Verify protection:**
   ```bash
   ./scripts/commands/seo-check.sh index-risk mysite-stg.example.com
   ```

---

## Troubleshooting

### Staging Site Being Indexed

**Symptoms:** Staging URLs appearing in Google search results

**Solutions:**
1. Add X-Robots-Tag header in nginx:
   ```nginx
   add_header X-Robots-Tag "noindex, nofollow" always;
   ```

2. Deploy blocking robots.txt:
   ```bash
   cp templates/robots-staging.txt /var/www/mysite-stg/html/robots.txt
   ```

3. Request removal in Google Search Console

### Sitemap Not Found (404)

**Symptoms:** `/sitemap.xml` returns 404

**Solutions:**
1. Install Simple XML Sitemap:
   ```bash
   ddev composer require drupal/simple_sitemap
   ddev drush en simple_sitemap -y
   ```

2. Generate sitemap:
   ```bash
   ddev drush simple-sitemap:generate
   ```

3. Check nginx location block allows sitemap.xml

### robots.txt Not Being Served

**Symptoms:** robots.txt shows Drupal default or 404

**Solutions:**
1. Check if physical file exists in webroot
2. Verify nginx configuration:
   ```nginx
   location = /robots.txt {
       allow all;
       log_not_found off;
       access_log off;
   }
   ```

3. For environment-specific robots.txt, use nginx rewrite:
   ```nginx
   # Staging: override with blocking robots.txt
   location = /robots.txt {
       return 200 "User-agent: *\nDisallow: /\n";
       add_header Content-Type text/plain;
   }
   ```

### X-Robots-Tag Header Missing

**Symptoms:** No X-Robots-Tag in response headers

**Solutions:**
1. Check nginx configuration includes the header
2. Ensure `always` keyword is present (sends header on all responses)
3. Restart nginx after configuration changes:
   ```bash
   sudo nginx -t && sudo systemctl reload nginx
   ```

### Production Site Not Being Indexed

**Symptoms:** Site content not appearing in Google

**Solutions:**
1. Check robots.txt isn't blocking everything:
   ```bash
   curl -s https://example.com/robots.txt
   ```

2. Check for blocking X-Robots-Tag:
   ```bash
   curl -sI https://example.com | grep -i x-robots-tag
   ```

3. Verify sitemap is referenced in robots.txt
4. Submit sitemap to Google Search Console

---

## Configuration Reference

### cnwp.yml SEO Settings

```yaml
settings:
  seo:
    # Staging protection
    staging_noindex: true          # Add X-Robots-Tag to staging
    staging_robots_block: true     # Deploy blocking robots.txt
    staging_http_auth: false       # Enable HTTP Basic Auth

    # Production optimization
    production_robots: true        # Deploy optimized robots.txt
    sitemap_enabled: true          # Enable sitemap.xml
    ai_bots_allowed: true          # Allow AI crawlers
    crawl_delay: 1                 # Seconds between requests

    # Meta tags
    meta_robots_404: true          # Add noindex to 404 pages
    canonical_urls: true           # Enforce canonical URLs
```

### Template Files

| File | Purpose |
|------|---------|
| `templates/robots-staging.txt` | Blocking robots.txt for staging |
| `templates/robots-production.txt` | Optimized robots.txt for production |

### Related Scripts

| Script | Purpose |
|--------|---------|
| `scripts/commands/seo-check.sh` | SEO monitoring and verification |
| `scripts/commands/stg2live.sh` | Deploys SEO configurations |

---

## Best Practices

1. **Always verify staging protection** before making a staging site public
2. **Use multiple layers** of protection for staging (header + robots.txt + meta tags)
3. **Generate sitemaps** from production, not staging
4. **Monitor regularly** using the seo-check script
5. **Keep robots.txt updated** when adding new features
6. **Use canonical URLs** to prevent duplicate content issues

---

*Last updated: January 2026*
