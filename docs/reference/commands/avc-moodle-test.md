# avc-moodle-test

**Last Updated:** 2026-01-14

Test OAuth2 SSO and integration functionality between AVC and Moodle sites.

## Synopsis

```bash
pl avc-moodle-test <avc-site> <moodle-site>
```

## Description

Runs a comprehensive test suite to verify OAuth2 Single Sign-On integration between an AVC (OpenSocial) site and a Moodle site. This command validates endpoints, configuration, connectivity, and security settings.

The test suite checks:
- OAuth2 endpoint accessibility and response codes
- AVC Drupal module installation and configuration
- Moodle plugin installation and configuration
- nwp.yml configuration accuracy
- Network connectivity and HTTPS enforcement
- OAuth2 key file permissions and validity

Use this command after initial setup, configuration changes, or to troubleshoot integration issues.

## Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `avc-site` | Yes | Name of the AVC/OpenSocial site |
| `moodle-site` | Yes | Name of the Moodle site |

## Options

| Option | Description | Default |
|--------|-------------|---------|
| `-h, --help` | Show help message and exit | - |
| `-d, --debug` | Enable debug output | false |

## Examples

### Basic Test

```bash
pl avc-moodle-test avc ss
```

Runs all integration tests and displays pass/fail results.

### Debug Mode

```bash
pl avc-moodle-test --debug avc ss
```

Shows detailed debug information for failed tests.

## Test Suite

The command runs these test categories in order:

### 1. OAuth2 Endpoint Tests

Tests OAuth2 endpoint accessibility:

| Test | Endpoint | Pass Criteria |
|------|----------|---------------|
| Authorize endpoint | `/oauth/authorize` | HTTP 200 or 302 |
| Token endpoint | `/oauth/token` | HTTP 200 or 405 (method not allowed for GET) |
| UserInfo endpoint | `/oauth/userinfo` | HTTP 200 or 401 (unauthorized without token) |

### 2. AVC Configuration Tests

Validates AVC Drupal configuration:

| Test | Check | Pass Criteria |
|------|-------|---------------|
| Simple OAuth module enabled | Module list | Module shows as enabled |
| OAuth private key exists | File system | File exists at correct path |
| OAuth public key exists | File system | File exists at correct path |
| Private key permissions | File permissions | 600 (rw-------) |

### 3. Moodle Configuration Tests

Validates Moodle configuration:

| Test | Check | Pass Criteria |
|------|-------|---------------|
| Moodle config.php exists | File system | File exists |
| Moodle wwwroot configured | config.php | Contains wwwroot setting |

### 4. nwp.yml Configuration Tests

Validates NWP configuration file:

| Test | Check | Pass Criteria |
|------|-------|---------------|
| nwp.yml exists | File system | File exists in project root |
| AVC site configured | YAML structure | AVC site entry exists |
| Moodle site configured | YAML structure | Moodle site entry exists |

### 5. Network Connectivity Tests

Validates network and security:

| Test | Check | Pass Criteria |
|------|-------|---------------|
| AVC site reachable | HTTP request | HTTP 200, 302, or 303 |
| Moodle site reachable | HTTP request | HTTP 200, 302, or 303 |
| AVC uses HTTPS | URL scheme | URL starts with https:// |
| Moodle uses HTTPS | URL scheme | URL starts with https:// |

## Output

### Passing Tests

```bash
pl avc-moodle-test avc ss
```

```
================================================================================
AVC-Moodle Integration Tests
================================================================================
AVC Site: avc
Moodle Site: ss

[1/5] Testing OAuth2 Endpoints
  OAuth2 authorize endpoint...                      ✓ PASS
  OAuth2 token endpoint...                          ✓ PASS
  OAuth2 userinfo endpoint...                       ✓ PASS

[2/5] Testing AVC Configuration
  Simple OAuth module enabled...                    ✓ PASS
  OAuth private key exists...                       ✓ PASS
  OAuth public key exists...                        ✓ PASS
  OAuth private key has correct permissions...      ✓ PASS

[3/5] Testing Moodle Configuration
  Moodle config.php exists...                       ✓ PASS
  Moodle wwwroot configured...                      ✓ PASS

[4/5] Testing nwp.yml Configuration
  nwp.yml exists...                                ✓ PASS
  AVC site configured in nwp.yml...                ✓ PASS
  Moodle site configured in nwp.yml...             ✓ PASS

[5/5] Testing Network Connectivity
  AVC site reachable...                             ✓ PASS
  Moodle site reachable...                          ✓ PASS
  AVC site uses HTTPS...                            ✓ PASS
  Moodle site uses HTTPS...                         ✓ PASS

================================================================================
Test Results
================================================================================

✓ All tests passed! (15/15)

Test Summary:
  Total Tests:  15
  Passed:       15
  Failed:       0
  Success Rate: 100%
```

### Failing Tests

```bash
pl avc-moodle-test avc ss
```

```
================================================================================
AVC-Moodle Integration Tests
================================================================================
AVC Site: avc
Moodle Site: ss

[1/5] Testing OAuth2 Endpoints
  OAuth2 authorize endpoint...                      ✗ FAIL
  OAuth2 token endpoint...                          ✓ PASS
  OAuth2 userinfo endpoint...                       ✗ FAIL

[2/5] Testing AVC Configuration
  Simple OAuth module enabled...                    ✓ PASS
  OAuth private key exists...                       ✓ PASS
  OAuth public key exists...                        ✓ PASS
  OAuth private key has correct permissions...      ✗ FAIL

[3/5] Testing Moodle Configuration
  Moodle config.php exists...                       ✓ PASS
  Moodle wwwroot configured...                      ✓ PASS

[4/5] Testing nwp.yml Configuration
  nwp.yml exists...                                ✓ PASS
  AVC site configured in nwp.yml...                ✓ PASS
  Moodle site configured in nwp.yml...             ✓ PASS

[5/5] Testing Network Connectivity
  AVC site reachable...                             ✓ PASS
  Moodle site reachable...                          ✓ PASS
  AVC site uses HTTPS...                            ✓ PASS
  Moodle site uses HTTPS...                         ✓ PASS

================================================================================
Test Results
================================================================================

✗ Some tests failed: 12 passed, 3 failed (Total: 15)

Test Summary:
  Total Tests:  15
  Passed:       12
  Failed:       3
  Success Rate: 80%
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | All tests passed (100% success rate) |
| 1 | One or more tests failed |
| 1 | Site validation failed (could not run tests) |

## Prerequisites

### Both Sites
- Sites must be installed and configured
- DDEV must be running
- Sites must be accessible

### System
- curl for HTTP testing
- stat for file permission checking
- yq for YAML parsing

## Detailed Test Explanations

### OAuth2 Authorize Endpoint Test

**What it tests:** Verifies the OAuth2 authorization endpoint is accessible.

**How it works:** Makes an HTTP GET request to `https://<avc-site>/oauth/authorize` and checks for HTTP 200 or 302 response.

**Why it matters:** This is the entry point for SSO login. If this fails, users cannot initiate login from Moodle.

**Common failures:**
- Site not running
- Simple OAuth not enabled
- Route not configured
- .htaccess blocking access

### OAuth2 Token Endpoint Test

**What it tests:** Verifies the OAuth2 token exchange endpoint is accessible.

**How it works:** Makes an HTTP GET request to `https://<avc-site>/oauth/token` and checks for any response (even 405 Method Not Allowed is acceptable for GET).

**Why it matters:** This endpoint exchanges authorization codes for access tokens. Without it, login flow cannot complete.

**Common failures:**
- Simple OAuth not configured
- Route not registered
- Web server misconfiguration

### OAuth2 UserInfo Endpoint Test

**What it tests:** Verifies the OAuth2 user information endpoint is accessible.

**How it works:** Makes an HTTP GET request to `https://<avc-site>/oauth/userinfo` and checks for response.

**Why it matters:** This endpoint provides user profile information. Moodle needs this to create/update user accounts.

**Common failures:**
- Simple OAuth not fully configured
- Custom endpoints not implemented
- User mapping module missing

### Private Key Permissions Test

**What it tests:** Verifies OAuth2 private key has secure permissions (600).

**How it works:** Uses `stat -c '%a'` to check file permissions.

**Why it matters:** Private key must be readable only by owner (600) for security. Overly permissive permissions are a security risk.

**Common failures:**
- Key generated with wrong permissions
- Manual file editing changed permissions
- File system mounted with wrong permissions

### HTTPS Enforcement Test

**What it tests:** Verifies both sites use HTTPS.

**How it works:** Checks if site URLs start with `https://`.

**Why it matters:** OAuth2 requires HTTPS for security. Credentials sent over HTTP can be intercepted.

**Common failures:**
- HTTP configured instead of HTTPS
- DDEV not using HTTPS (should auto-configure)
- Reverse proxy misconfiguration

## Troubleshooting

### OAuth2 Endpoints Failing

**Symptom:**
```
OAuth2 authorize endpoint...                      ✗ FAIL
```

**Solution:**
1. Check if AVC site is running:
   ```bash
   cd sites/avc && ddev describe
   ```

2. Verify Simple OAuth is enabled:
   ```bash
   cd sites/avc && ddev drush pm:list --status=enabled | grep oauth
   ```

3. Test endpoint manually:
   ```bash
   curl -k https://avc.ddev.site/oauth/authorize
   ```

4. Check Apache/Nginx error logs:
   ```bash
   ddev logs
   ```

### Private Key Permission Failure

**Symptom:**
```
OAuth private key has correct permissions...      ✗ FAIL
```

**Solution:**
```bash
cd sites/avc
chmod 600 private/keys/oauth_private.key
```

### Module Not Enabled

**Symptom:**
```
Simple OAuth module enabled...                    ✗ FAIL
```

**Solution:**
```bash
cd sites/avc
ddev drush en -y simple_oauth
ddev drush cr
```

### Site Not Reachable

**Symptom:**
```
AVC site reachable...                             ✗ FAIL
```

**Solution:**
1. Start DDEV: `cd sites/avc && ddev start`
2. Check DDEV status: `ddev describe`
3. Test URL: `curl -I https://avc.ddev.site`
4. Check firewall/network settings

### nwp.yml Missing Configuration

**Symptom:**
```
AVC site configured in nwp.yml...                ✗ FAIL
```

**Solution:**
1. Run setup again: `pl avc-moodle-setup avc ss`
2. Manually verify nwp.yml has correct structure
3. Check for YAML syntax errors: `yq eval '.' nwp.yml`

## Test Automation

### CI/CD Integration

Add to your CI/CD pipeline:

```yaml
test_avc_moodle_integration:
  script:
    - ddev start
    - ./pl avc-moodle-test avc ss
  only:
    - merge_requests
    - main
```

### Pre-Deploy Checks

Add to deployment script:

```bash
#!/bin/bash
# Pre-deployment check
if ! ./pl avc-moodle-test avc ss; then
    echo "Integration tests failed - aborting deployment"
    exit 1
fi

# Continue with deployment...
```

### Monitoring

Run periodic tests via cron:

```bash
0 */6 * * * /usr/local/bin/pl avc-moodle-test avc ss || mail -s "AVC-Moodle Integration Test Failure" admin@example.com
```

## Related Commands

- [avc-moodle-setup](avc-moodle-setup.md) - Initial integration setup
- [avc-moodle-status](avc-moodle-status.md) - Check integration health
- [avc-moodle-sync](avc-moodle-sync.md) - Manually trigger synchronization

## See Also

- AVC-Moodle Integration Library: `/home/rob/nwp/lib/avc-moodle.sh`
- Simple OAuth Testing: https://www.drupal.org/docs/contributed-modules/simple-oauth
- OAuth2 Security Best Practices: https://oauth.net/2/
- Moodle Authentication Testing: https://docs.moodle.org/en/OAuth_2_authentication
