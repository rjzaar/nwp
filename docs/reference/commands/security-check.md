# security-check

Test HTTP security headers on any URL (Mozilla Observatory-style).

## Overview

The `security-check` command tests HTTP security headers on any URL to identify security misconfigurations. It's similar to Mozilla Observatory but runs locally as a CLI tool.

## Usage

```bash
pl security-check <url>
```

## Options

| Flag | Description |
|------|-------------|
| `-h, --help` | Show help message |
| `-v, --verbose` | Show detailed header values |
| `-j, --json` | Output results as JSON |

## Examples

### Check a domain
```bash
pl security-check https://example.com
```

### Check local DDEV site
```bash
pl security-check https://mysite.ddev.site
```

### Verbose mode with details
```bash
pl security-check -v https://drupal.org
```

### JSON output for automation
```bash
pl security-check -j https://example.com
```

## Headers Checked

### Strict-Transport-Security (HSTS)
- **Pass**: Present with max-age ≥ 6 months and includeSubDomains
- **Warn**: Present but max-age < 6 months or missing includeSubDomains
- **Fail**: Missing

Recommended: `Strict-Transport-Security: max-age=31536000; includeSubDomains`

### Content-Security-Policy (CSP)
- **Pass**: Present with default-src and no unsafe directives
- **Warn**: Report-only mode, contains unsafe-inline/unsafe-eval, or missing default-src
- **Fail**: Missing

Helps prevent XSS attacks.

### X-Frame-Options
- **Pass**: DENY or SAMEORIGIN (or CSP frame-ancestors)
- **Warn**: Invalid value
- **Fail**: Missing and no CSP frame-ancestors

Prevents clickjacking attacks.

### X-Content-Type-Options
- **Pass**: nosniff
- **Warn**: Invalid value
- **Fail**: Missing

Prevents MIME type sniffing.

### Referrer-Policy
- **Pass**: Secure policy (no-referrer, strict-origin, etc.)
- **Warn**: Missing or weak policy
- **Info**: Non-critical but recommended

Controls referrer information leakage.

### Permissions-Policy
- **Pass**: Present (formerly Feature-Policy)
- **Warn**: Missing or using deprecated Feature-Policy
- **Info**: Controls browser features (camera, microphone, etc.)

### Server Token Exposure
- **Pass**: No version info exposed
- **Warn**: Server header exposes version, X-Powered-By, or X-Generator present
- **Info**: Helps prevent targeted attacks

## Grading System

Results are assigned a letter grade:

- **A+**: All headers pass, no warnings
- **A**: All pass, ≤ 2 warnings
- **B**: ≤ 1 failure, ≤ 3 warnings
- **C**: ≤ 2 failures
- **D**: ≤ 4 failures
- **F**: > 4 failures (critical headers missing)

## Exit Codes

- **0**: All headers pass
- **1**: One or more headers fail/missing
- **2**: Connection error or invalid URL

## Verbose Mode

With `-v` flag, displays:
- Raw header values for all checked headers
- Detailed recommendations for each failure/warning
- Links to additional resources

## JSON Output

With `-j` flag, outputs structured JSON:

```json
{
  "url": "https://example.com",
  "checks": {
    "hsts": {"result": "PASS", "recommendation": ""},
    "csp": {"result": "FAIL", "recommendation": "Add Content-Security-Policy..."},
    ...
  },
  "summary": {
    "passed": 5,
    "warned": 1,
    "failed": 1
  }
}
```

## URL Handling

- Automatically adds `https://` if no protocol specified
- Warns if testing HTTP URLs (HTTPS strongly recommended)
- Follows redirects to check final destination
- Timeout: 10 seconds per request

## Resources

The command references:
- Mozilla Observatory: https://observatory.mozilla.org/
- Security Headers: https://securityheaders.com/
- OWASP Secure Headers: https://owasp.org/www-project-secure-headers/

## Common Issues

### HSTS Not Set
Add to nginx config:
```nginx
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
```

### CSP Missing
Add to nginx config:
```nginx
add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline';" always;
```

### X-Frame-Options Missing
Add to nginx config:
```nginx
add_header X-Frame-Options "SAMEORIGIN" always;
```

## Related Commands

- [security.sh](security.md) - Drupal security updates
- [seo-check.sh](seo-check.md) - SEO and robots.txt validation
- [audit.sh](audit.md) - General site audit

## See Also

- OWASP Security Headers Project
- Mozilla Observatory documentation
- Security best practices guides
