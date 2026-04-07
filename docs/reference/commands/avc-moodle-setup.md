# avc-moodle-setup

**Last Updated:** 2026-01-14

Configure Single Sign-On (SSO) integration between AVC and Moodle sites using OAuth2-based authentication.

## Synopsis

```bash
pl avc-moodle-setup <avc-site> <moodle-site> [OPTIONS]
```

## Description

Sets up OAuth2 Single Sign-On integration between an AVC (OpenSocial) site and a Moodle site. This script automates the configuration of OAuth2 providers, client credentials, and the installation of required modules on both platforms.

The integration enables:
- Seamless SSO from Moodle to AVC
- User authentication via OAuth2
- Optional role synchronization between platforms
- Optional badge display from Moodle on AVC user profiles

This script handles the complete setup process including key generation, module installation, OAuth2 configuration, endpoint testing, and configuration file updates.

## Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `avc-site` | Yes | Name of the AVC/OpenSocial site (OAuth provider) |
| `moodle-site` | Yes | Name of the Moodle site (OAuth client) |

## Options

| Option | Description | Default |
|--------|-------------|---------|
| `-h, --help` | Show help message and exit | - |
| `-d, --debug` | Enable debug output | false |
| `--regenerate-keys` | Regenerate OAuth2 RSA keys (use with caution) | false |
| `--skip-test` | Skip SSO flow testing | false |
| `--role-sync` | Enable role synchronization during setup | false |
| `--badge-display` | Enable badge display during setup | false |

## Examples

### Basic Setup

```bash
pl avc-moodle-setup avc ss
```

Sets up SSO integration between the `avc` site and the `ss` Moodle site with default options.

### Setup with Role Sync and Badge Display

```bash
pl avc-moodle-setup avc ss --role-sync --badge-display
```

Enables optional features during initial setup.

### Regenerate OAuth2 Keys

```bash
pl avc-moodle-setup avc ss --regenerate-keys
```

Forces regeneration of OAuth2 RSA key pairs (warning: this will break existing authentication until reconfigured).

### Skip Testing Phase

```bash
pl avc-moodle-setup avc ss --skip-test
```

Completes setup without running endpoint tests (useful for automation).

## Setup Process

The command performs these steps in order:

### Step 1: Site Validation
- Verifies both AVC and Moodle sites exist
- Checks that DDEV is running
- Confirms Drush is available for AVC
- Validates Moodle CLI tools are accessible

### Step 2: OAuth2 Key Generation
- Generates 2048-bit RSA key pair
- Stores private key in `<avc-site>/private/keys/oauth_private.key` (600 permissions)
- Stores public key in `<avc-site>/private/keys/oauth_public.key` (644 permissions)
- Skips if keys exist (unless `--regenerate-keys` specified)

### Step 3: AVC Module Installation
- Installs Simple OAuth module via Composer (`drupal/simple_oauth:^5.2`)
- Enables Simple OAuth module via Drush
- Prepares for custom AVC-Moodle modules (when available)

### Step 4: Moodle Plugin Installation
- Checks for auth_avc_oauth2 plugin (when available)
- Installs local_cohortrole plugin for role assignment
- Prepares plugin directory structure

### Step 5: OAuth2 Configuration in AVC
- Configures Simple OAuth with key paths
- Sets token expiration to 300 seconds (5 minutes)
- Generates OAuth2 client credentials for Moodle
- Outputs client ID and redirect URI for manual configuration

### Step 6: OAuth2 Configuration in Moodle
- Displays OAuth2 issuer endpoint URLs
- Provides configuration values for manual setup
- Shows admin interface location for completion

### Step 7: SSO Flow Testing
- Tests OAuth2 authorize endpoint accessibility
- Tests OAuth2 token endpoint accessibility
- Tests OAuth2 userinfo endpoint accessibility
- Provides manual testing instructions

### Step 8: Configuration Updates
- Updates nwp.yml with integration settings
- Records moodle_site and moodle_url in AVC site config
- Records avc_site and avc_url in Moodle site config
- Enables optional features if flags specified

### Step 9: Optional Features
- Configures role_sync if `--role-sync` enabled
- Configures badge_display if `--badge-display` enabled

### Step 10: Summary
- Displays next steps for manual completion
- Shows URLs for admin interfaces
- Provides testing instructions
- Reports execution time

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Setup completed successfully |
| 1 | Site validation failed |
| 1 | Key generation failed |
| 1 | Module installation failed |
| 1 | OAuth2 configuration failed |
| 1 | nwp.yml update failed |

## Prerequisites

### Both Sites
- Sites must be installed and accessible
- DDEV must be running for both sites
- Sites must use HTTPS (DDEV provides this automatically)

### AVC Site
- Drush must be available
- Composer must be available
- Write access to private/keys/ directory

### Moodle Site
- Moodle CLI tools must be available
- Admin access to Moodle interface for final configuration

### System
- OpenSSL for key generation
- yq for YAML manipulation

## Output

The command produces color-coded output with progress indicators:

```
[1/10] Validating sites
  ✓ AVC site validated
  ✓ Moodle site validated

[2/10] Generating OAuth2 keys
  ✓ RSA key pair generated (2048-bit)

[3/10] Installing AVC modules
  ✓ Simple OAuth module installed
  ✓ Simple OAuth module enabled

[4/10] Installing Moodle plugins
  ℹ Moodle authentication plugin will be installed once created

[5/10] Configuring OAuth2 in AVC
  ✓ Simple OAuth key paths configured
  ✓ Token lifetime set to 5 minutes
  ⚠ OAuth2 client creation requires manual setup

[6/10] Configuring OAuth2 in Moodle
  ⚠ Moodle OAuth2 configuration requires manual setup

[7/10] Testing SSO flow
  ✓ OAuth2 authorize endpoint reachable
  ✓ OAuth2 token endpoint reachable
  ✓ OAuth2 userinfo endpoint reachable

[8/10] Updating nwp.yml
  ✓ nwp.yml updated with integration settings

[9/10] Configuring optional features
  ℹ Role synchronization enabled
  ℹ Badge display enabled

[10/10] Setup complete
  ✓ AVC-Moodle SSO setup completed successfully!

Next Steps:
1. Complete OAuth2 client setup in AVC:
   Visit: https://avc.example.com/admin/config/services/consumer

2. Complete OAuth2 issuer setup in Moodle:
   Visit: https://ss.example.com/admin/settings.php?section=oauth2

3. Test SSO login:
   Visit: https://ss.example.com
   Click 'Login with AVC'

4. Check integration status:
   pl avc-moodle-status avc ss

Setup completed in 45s
```

## Configuration Files

### nwp.yml Updates

For the AVC site:
```yaml
sites:
  avc:
    moodle_integration:
      enabled: true
      moodle_site: "ss"
      moodle_url: "https://ss.example.com"
      role_sync: true          # if --role-sync specified
      badge_display: true      # if --badge-display specified
```

For the Moodle site:
```yaml
sites:
  ss:
    avc_integration:
      enabled: true
      avc_site: "avc"
      avc_url: "https://avc.example.com"
```

### OAuth2 Keys

Private key location: `<avc-site>/private/keys/oauth_private.key`
- Permissions: 600 (read/write owner only)
- Format: PEM-encoded RSA private key
- Size: 2048 bits

Public key location: `<avc-site>/private/keys/oauth_public.key`
- Permissions: 644 (readable by web server)
- Format: PEM-encoded RSA public key
- Size: 2048 bits

## Manual Configuration Steps

After running this script, you must manually complete:

### 1. AVC OAuth2 Client Setup

Visit the AVC admin interface and create an OAuth2 client:

```
URL: https://<avc-site>/admin/config/services/consumer

Client ID: moodle_<moodle-site>
Redirect URI: https://<moodle-site>/admin/oauth2callback.php
Grant Types: Authorization Code
Scopes: openid profile email
```

Save the generated client secret for the next step.

### 2. Moodle OAuth2 Issuer Setup

Visit the Moodle admin interface and configure the OAuth2 service:

```
URL: https://<moodle-site>/admin/settings.php?section=oauth2

Name: AVC
Client ID: moodle_<moodle-site>
Client Secret: <from AVC setup above>
Issuer URL: https://<avc-site>
Authorization Endpoint: https://<avc-site>/oauth/authorize
Token Endpoint: https://<avc-site>/oauth/token
UserInfo Endpoint: https://<avc-site>/oauth/userinfo
```

## Troubleshooting

### Keys Already Exist

**Symptom:**
```
OAuth2 keys already exist - skipping generation
Use --regenerate-keys to force regeneration
```

**Solution:** This is normal if you've run setup before. Keys are preserved to maintain existing authentication. Only use `--regenerate-keys` if you intentionally want to invalidate all existing OAuth2 sessions.

### DDEV Not Running

**Symptom:**
```
DDEV configuration not found - this script requires DDEV
```

**Solution:** Start DDEV for both sites:
```bash
cd sites/avc && ddev start
cd sites/ss && ddev start
```

### Simple OAuth Already Installed

**Symptom:**
```
Simple OAuth module already installed
```

**Solution:** This is normal. The script detects existing installations and skips redundant steps.

### OAuth2 Endpoints Not Reachable

**Symptom:**
```
OAuth2 authorize endpoint not reachable
```

**Solution:**
1. Verify AVC site is running: `ddev describe -p avc`
2. Check that Simple OAuth is enabled: `ddev drush pm:list --status=enabled | grep oauth`
3. Verify HTTPS is working: `curl -k https://avc.ddev.site`
4. Check firewall/network settings

### Manual Configuration Required

**Symptom:**
```
OAuth2 client creation requires manual setup
```

**Solution:** This is expected. OAuth2 client credentials cannot be fully automated without additional modules. Follow the "Manual Configuration Steps" section above to complete setup.

## Security Considerations

### Key Management
- Private keys are stored with 600 permissions (owner read/write only)
- Keys are stored in the private/ directory (outside web root)
- Regenerating keys invalidates all existing OAuth2 sessions
- Back up keys before regeneration

### Token Lifetime
- Default token lifetime is 5 minutes (300 seconds)
- Shorter lifetimes increase security but may impact user experience
- Adjust via `simple_oauth.settings.token_expiration` if needed

### HTTPS Requirement
- OAuth2 requires HTTPS for security
- DDEV provides HTTPS automatically with self-signed certificates
- Production deployments must use valid SSL/TLS certificates

### Client Secret Protection
- Store client secrets securely
- Never commit client secrets to git
- Use .secrets.yml for production credentials
- Rotate secrets periodically

## Related Commands

- [avc-moodle-status](avc-moodle-status.md) - Check integration health
- [avc-moodle-sync](avc-moodle-sync.md) - Manually trigger role/cohort sync
- [avc-moodle-test](avc-moodle-test.md) - Test OAuth2 and integration functionality

## See Also

- AVC-Moodle Integration Library: `/home/rob/nwp/lib/avc-moodle.sh`
- Simple OAuth Module: https://www.drupal.org/project/simple_oauth
- Moodle OAuth2 Documentation: https://docs.moodle.org/en/OAuth_2_authentication
- OAuth2 Specification: https://oauth.net/2/
