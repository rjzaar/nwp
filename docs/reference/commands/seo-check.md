# seo-check

**Last Updated:** 2026-01-14

Comprehensive SEO monitoring and sitemap verification for Drupal sites.

## Overview

The `seo-check` command provides comprehensive SEO analysis including robots.txt validation, HTTP header checks, sitemap.xml verification, and environment-specific recommendations. It helps ensure staging sites are protected from indexing and production sites are optimized for search engines.

## Synopsis

```bash
pl seo-check <command> [options] <sitename>
```

## Commands

| Command | Description |
|---------|-------------|
| `check <sitename>` | Full SEO check (robots.txt, headers, sitemap) |
| `staging <sitename>` | Verify staging site is protected from indexing |
| `production <sitename>` | Verify production site is optimized for SEO |
| `sitemap <sitename>` | Check sitemap.xml configuration |
| `headers <sitename>` | Check HTTP headers for SEO directives |
| `index-risk <domain>` | Check if domain might be indexed |

## Options

| Option | Description |
|--------|-------------|
| `-h, --help` | Show help message |
| `-d, --debug` | Enable debug output |
| `-q, --quiet` | Only show errors and warnings |
| `-v, --verbose` | Show detailed output (including full content) |
| `--domain <domain>` | Override domain for checks (auto-detect otherwise) |

## Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `sitename` | Yes (except index-risk) | Site identifier for SEO checks |
| `domain` | Yes (for index-risk) | Domain name to check indexation risk |

## Examples

### Full SEO Check

```bash
pl seo-check check avc
```

Performs complete SEO check for `avc` site (robots.txt, headers, sitemap).

### Verify Staging Protection

```bash
pl seo-check staging avc-stg
```

Verifies staging site is properly protected from search engine indexing.

### Verify Production SEO

```bash
pl seo-check production avc
```

Checks production site SEO configuration and optimization.

### Check Sitemap Only

```bash
pl seo-check sitemap avc
```

Verifies sitemap.xml exists, is valid, and contains URLs.

### Check HTTP Headers

```bash
pl seo-check headers avc
```

Display SEO-related HTTP headers (X-Robots-Tag, Link, Cache-Control).

### Check Indexation Risk

```bash
pl seo-check index-risk avc-stg.nwpcode.org
```

Simulates Google crawler checks to assess if site might be indexed.

### Verbose Output

```bash
pl seo-check check avc -v
```

Show full robots.txt and sitemap.xml content during checks.

### Override Domain

```bash
pl seo-check check avc --domain avc.example.com
```

Check specific domain instead of auto-detected domain.

## Environment Detection

Sites are categorized automatically:

| Pattern | Environment | Expected Behavior |
|---------|-------------|-------------------|
| `*-stg`, `*_stg` | Staging | Block all indexing |
| `*-prod`, `*_prod`, `*-live`, `*_live` | Production | Allow indexing, optimize SEO |
| Other | Development | Typically not checked |

## SEO Checks Performed

### Robots.txt Check

**For Staging:**
- ✓ Should contain `Disallow: /`
- ✓ Should block all crawlers
- ✗ Should NOT reference sitemap

**For Production:**
- ✓ Should reference sitemap.xml
- ✓ Should block admin paths
- ✗ Should NOT block all crawlers

### X-Robots-Tag Header Check

**For Staging:**
- ✓ Should contain `noindex`
- ✓ Should contain `nofollow`

**For Production:**
- ✗ Should NOT contain `noindex`
- ✓ Can contain other directives (noarchive, etc.)

### Sitemap Check (Production Only)

- ✓ sitemap.xml should return HTTP 200
- ✓ Content-Type should be XML
- ✓ Should contain valid XML structure
- ✓ Should contain URL entries
- ℹ Reports number of URLs found

### Meta Robots Tag Check

- Checks HTML for `<meta name="robots">`
- Verifies appropriate directives for environment

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success - all checks passed |
| 1 | Checks found issues or warnings |

## Prerequisites

- `curl` command-line tool installed
- Internet connectivity
- Site must be publicly accessible via HTTP/HTTPS
- DNS resolution for domain
- Valid domain in `nwp.yml` or provided via `--domain`

## Output Interpretation

### Status Indicators

- **OK**: Check passed, no issues
- **INFO**: Informational message, not a problem
- **WARN**: Warning, should be reviewed
- **FAIL**: Critical issue, must be fixed

### Example Output

```
SEO Check: avc-stg (Environment: staging)
=========================================

Checking robots.txt at: https://avc-stg.example.com/robots.txt
  OK   robots.txt blocks all crawlers (Disallow: /)

Checking X-Robots-Tag header for: https://avc-stg.example.com
  OK   X-Robots-Tag header contains 'noindex'
  OK   X-Robots-Tag header also contains 'nofollow'

Summary
=======
  OK   Staging site is properly protected from search engine indexing
```

## Troubleshooting

### Domain Not Auto-Detected

**Symptom:** Error "Could not determine domain for site"

**Solution:**
```bash
# Specify domain manually
pl seo-check check mysite --domain mysite.example.com

# Or add domain to nwp.yml
sites:
  mysite:
    live:
      domain: "mysite.example.com"
```

### Site Unreachable

**Symptom:** "Could not fetch headers (site unreachable)"

**Solution:**
1. Verify site is running: `curl https://domain.com`
2. Check DNS resolution: `host domain.com`
3. Test SSL certificate: `curl -I https://domain.com`
4. Check firewall rules
5. Verify domain in `nwp.yml` is correct

### Robots.txt Not Found

**Symptom:** "robots.txt not found or unreachable (HTTP 404)"

**Solution:**
```bash
# For staging, create blocking robots.txt
cat > sites/mysite/web/robots.txt << EOF
User-agent: *
Disallow: /
EOF

# For production, create permissive robots.txt
cat > sites/mysite/web/robots.txt << EOF
User-agent: *
Disallow: /admin/
Disallow: /user/
Sitemap: https://mysite.com/sitemap.xml
EOF
```

### Staging Site Not Protected

**Symptom:** "Staging site is NOT properly protected"

**Solution:**
1. **Add X-Robots-Tag header** in web server config:

```nginx
# Nginx: sites/mysite/nginx.conf
add_header X-Robots-Tag "noindex, nofollow" always;
```

```apache
# Apache: sites/mysite/.htaccess
Header set X-Robots-Tag "noindex, nofollow"
```

2. **Create blocking robots.txt**:
```bash
cp templates/robots-staging.txt sites/mysite/web/robots.txt
```

3. **Enable Drupal Metatag module**:
```bash
pl drush mysite en metatag -y
pl drush mysite config-set metatag.metatag_defaults.global tags.robots "noindex, nofollow"
```

### Production Site Blocked

**Symptom:** "Production site has X-Robots-Tag: noindex"

**Solution:**
```bash
# Remove X-Robots-Tag from web server config
# Check nginx or Apache configuration files

# Verify Drupal metatag settings
pl drush mysite config-get metatag.metatag_defaults.global tags.robots

# Clear caches
pl drush mysite cr
```

### Sitemap Not Found

**Symptom:** "sitemap.xml not found (404)"

**Solution:**
Install and configure Simple XML Sitemap module:

```bash
# Install module
pl drush mysite composer require drupal/simple_sitemap
pl drush mysite en simple_sitemap -y

# Generate sitemap
pl drush mysite simple-sitemap:generate

# Verify
curl https://mysite.com/sitemap.xml
```

### Index Risk Check Shows High Risk

**Symptom:** Multiple warnings in index-risk check

**Solution:**
Apply all three protection layers:

```bash
# 1. X-Robots-Tag header (highest priority)
# Add to web server config

# 2. Meta robots tag
pl drush mysite config-set metatag.metatag_defaults.global tags.robots "noindex, nofollow"

# 3. robots.txt (backup layer)
cp templates/robots-staging.txt sites/mysite/web/robots.txt
```

## Best Practices

### Staging Protection

Always use multiple layers of protection:

```bash
# 1. HTTP Header (highest priority)
# 2. Meta robots tag
# 3. robots.txt (fallback)

# Verify all layers
pl seo-check staging mysite-stg -v
```

### Production Optimization

```bash
# Install sitemap module
pl drush mysite composer require drupal/simple_sitemap
pl drush mysite en simple_sitemap -y

# Install SEO modules
pl drush mysite composer require drupal/metatag drupal/pathauto
pl drush mysite en metatag pathauto -y

# Generate sitemap
pl drush mysite simple-sitemap:generate

# Verify SEO configuration
pl seo-check production mysite
```

### Regular Monitoring

```bash
# Daily cron check for production
0 9 * * * /path/to/nwp/pl seo-check production mysite || mail -s "SEO Check Failed" admin@example.com

# Weekly staging verification
0 8 * * 1 /path/to/nwp/pl seo-check staging mysite-stg || echo "Staging not protected!" | mail -s "URGENT: Staging SEO Issue" admin@example.com
```

### Pre-Launch Checklist

```bash
# Before launching production
pl seo-check staging mysite-stg     # Verify staging protected
pl seo-check production mysite      # Verify production optimized
pl seo-check sitemap mysite         # Verify sitemap working
pl seo-check headers mysite         # Verify headers correct
```

## Automation Examples

### Check All Sites

```bash
#!/bin/bash
for site in $(ls sites/); do
  if [[ "$site" =~ -stg$ ]]; then
    pl seo-check staging "$site"
  else
    pl seo-check production "$site"
  fi
done
```

### Weekly SEO Report

```bash
#!/bin/bash
{
  echo "Weekly SEO Report - $(date)"
  echo "=============================="
  echo ""

  for site in avc nwp mysite; do
    echo "Site: $site"
    pl seo-check check "$site"
    echo ""
  done
} | mail -s "Weekly SEO Report" admin@example.com
```

## Notes

- HTTP timeout for checks is 10 seconds (configurable in script)
- SSL certificate errors may cause checks to fail
- DNS propagation can affect domain checks (wait 24-48 hours after changes)
- Checks are read-only (no modifications to sites)
- Based on `docs/SEO_ROBOTS_PROPOSAL.md` specification
- Works with both Drupal 9 and Drupal 10
- Compatible with Simple XML Sitemap and XML Sitemap modules

## Performance Considerations

- Checks make HTTP requests (requires network access)
- Each check typically completes in 1-5 seconds
- Verbose mode (`-v`) increases output processing time
- Multiple sites can be checked in parallel
- No impact on site performance (read-only checks)

## Security Implications

- Checks reveal site URLs and structure
- Does not expose credentials or sensitive data
- Safe to run on production sites
- Can help identify security misconfigurations (exposed admin paths)
- Index-risk check simulates crawler behavior
- Does not modify any site configuration

## Related Commands

- [security.sh](security.md) - Security update management
- [live-deploy.sh](live-deploy.md) - Production deployment
- [config.sh](config.md) - Site configuration management
- [drush.sh](drush.md) - Drupal command-line operations

## See Also

- [SEO Robots Proposal](../../proposals/SEO_ROBOTS_PROPOSAL.md) - Full SEO specification
- [SEO Setup Guide](../../guides/seo-setup.md) - Implementing SEO best practices
- [Staging Best Practices](../../guides/staging-best-practices.md) - Staging environment setup
- [Robots.txt Templates](../../templates/) - Template robots.txt files
- [Google Search Console](https://search.google.com/search-console) - Monitor search performance
- [Bing Webmaster Tools](https://www.bing.com/webmasters) - Bing search optimization
