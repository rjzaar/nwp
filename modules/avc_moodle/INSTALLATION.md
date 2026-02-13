# AVC-Moodle SSO Integration - Installation Guide

Complete installation and configuration guide for AVC-Moodle SSO integration.

## Overview

This integration provides:
- OAuth2/OpenID Connect Single Sign-On between AVC and Moodle
- Automatic guild role synchronization to Moodle cohorts and roles
- Display of Moodle badges and course completions on AVC profiles

## Architecture

The integration consists of three parts:

1. **Drupal Modules** (on AVC):
   - `avc_moodle_oauth` - OAuth2 provider for SSO
   - `avc_moodle_sync` - Guild role synchronization
   - `avc_moodle_data` - Display Moodle data on AVC

2. **Moodle Plugin**:
   - `auth_avc_oauth2` - OAuth2 authentication plugin

3. **NWO Commands** (optional):
   - `pl avc-moodle-setup` - Initial setup
   - `pl avc-moodle-test` - Test connection
   - `pl avc-moodle-sync` - Manual sync
   - `pl avc-moodle-status` - Check status

## Prerequisites

### On AVC (Drupal)

- Drupal 10 or 11
- Simple OAuth module (`composer require drupal/simple_oauth`)
- Group module OR Organic Groups (for guild functionality)
- PHP 8.1 or later
- OpenSSL extension enabled

### On Moodle

- Moodle 4.0 or later
- Web Services enabled
- OAuth2 authentication enabled
- PHP 8.1 or later
- HTTPS required (for OAuth2)

### General Requirements

- Both systems must be accessible via HTTPS
- AVC must be accessible from Moodle server (for OAuth2)
- Moodle must be accessible from AVC server (for Web Services API)

## Installation Steps

### Phase 1: Install AVC Modules

#### 1.1. Copy Modules to AVC

```bash
# If using NWO
cd /home/rob/nwp
cp -r modules/avc_moodle sites/avc/html/modules/custom/

# Or manually
cp -r modules/avc_moodle /path/to/drupal/modules/custom/
```

#### 1.2. Install Dependencies

```bash
cd /path/to/drupal
composer require drupal/simple_oauth
```

#### 1.3. Enable Modules

```bash
# Using Drush
drush en avc_moodle avc_moodle_oauth -y

# Optional submodules (enable as needed)
drush en avc_moodle_sync -y    # For role synchronization
drush en avc_moodle_data -y    # For displaying Moodle data
```

Or via Drupal UI: `/admin/modules`

### Phase 2: Configure Simple OAuth (AVC)

#### 2.1. Generate OAuth2 Keys

```bash
# Using OpenSSL
cd /path/to/drupal

# Generate private key
openssl genrsa -out private.key 2048

# Generate public key
openssl rsa -in private.key -pubout -out public.key

# Set permissions
chmod 600 private.key public.key
chown www-data:www-data private.key public.key
```

#### 2.2. Configure Simple OAuth Module

1. Visit `/admin/config/people/simple_oauth`
2. Set paths:
   - **Public Key Path:** `/path/to/drupal/public.key`
   - **Private Key Path:** `/path/to/drupal/private.key`
3. Save configuration

#### 2.3. Create OAuth2 Client

1. Visit `/admin/config/people/simple_oauth/oauth2_client`
2. Click "Add OAuth2 Client"
3. Configure:
   - **Label:** Moodle SSO
   - **Client ID:** (generate or use: `moodle-sso`)
   - **Secret:** (generate strong secret)
   - **Redirect URI:** `https://moodle.example.com/admin/oauth2callback.php`
   - **Scopes:** (leave default or add custom)
4. Save and note the Client ID and Secret

### Phase 3: Configure avc_moodle_oauth Module

1. Visit `/admin/config/services/avc-moodle/oauth`
2. Configure:
   - **Moodle URL:** `https://moodle.example.com`
   - **Enable automatic user provisioning:** Checked
   - **Include guild memberships:** Checked (if using sync)
   - **Include guild roles:** Checked (if using sync)
3. Save configuration

### Phase 4: Install Moodle Plugin

#### 4.1. Copy Plugin to Moodle

```bash
cd /path/to/moodle
cp -r /home/rob/nwp/moodle_plugins/auth/avc_oauth2 auth/
chown -R www-data:www-data auth/avc_oauth2
```

#### 4.2. Install Plugin

1. Visit `https://moodle.example.com/admin/index.php`
2. Follow installation prompts
3. Click "Upgrade Moodle database now"

### Phase 5: Configure OAuth2 Issuer in Moodle

#### 5.1. Create Custom OAuth2 Service

1. Go to: Site administration > Server > OAuth 2 services
2. Click "Create new custom service"
3. Configure:
   - **Name:** AVC OAuth2
   - **Client ID:** (from Phase 2.3)
   - **Client secret:** (from Phase 2.3)
   - **Service base URL:** `https://avc.example.com`
   - **Enabled:** Yes

4. Add endpoints:
   - **Authorization endpoint:** `/oauth/authorize`
   - **Token endpoint:** `/oauth/token`
   - **User info endpoint:** `/oauth/userinfo`

5. Configure user field mappings:
   - `sub` → `username` or `idnumber`
   - `email` → `email`
   - `name` → `firstname` + `lastname`
   - `given_name` → `firstname`
   - `family_name` → `lastname`
   - `picture` → `picture`

6. Save configuration and note the Issuer ID

### Phase 6: Configure auth_avc_oauth2 Plugin

1. Go to: Site administration > Plugins > Authentication > Manage authentication
2. Enable "AVC OAuth2"
3. Click "Settings" for AVC OAuth2
4. Configure:
   - **AVC URL:** `https://avc.example.com`
   - **OAuth2 Issuer ID:** (from Phase 5.1)
   - **Auto-redirect:** Optional (enables automatic redirect to AVC)
5. Save changes

### Phase 7: Test SSO Integration

#### 7.1. Test from Moodle

1. Log out of Moodle
2. Visit Moodle login page
3. Click "Log in via AVC OAuth2" (or auto-redirect if enabled)
4. Should redirect to AVC login
5. Log in with AVC credentials
6. Grant permissions (first time only)
7. Should return to Moodle logged in

#### 7.2. Verify User Creation

1. In Moodle, go to: Site administration > Users > Browse list of users
2. Find the user you just logged in as
3. Verify profile data was synced correctly

## Optional: Configure Role Synchronization

If you want to sync AVC guild roles to Moodle cohorts and roles:

### Step 1: Enable Web Services in Moodle

1. Go to: Site administration > Advanced features
2. Enable "Web services"
3. Save changes

### Step 2: Create Web Service User

1. Go to: Site administration > Users > Accounts > Add a new user
2. Create user: `avc_sync_user`
3. Note the user ID

### Step 3: Create Web Service Role

1. Go to: Site administration > Users > Permissions > Define roles
2. Add a new role: "AVC Sync Service"
3. Grant capabilities:
   - `moodle/user:viewalldetails`
   - `moodle/cohort:view`
   - `moodle/cohort:manage`
   - `moodle/role:assign`
   - `webservice/rest:use`
4. Save role

### Step 4: Assign Role to User

1. Go to: Site administration > Users > Permissions > Assign system roles
2. Select "AVC Sync Service"
3. Assign to `avc_sync_user`

### Step 5: Create Web Service

1. Go to: Site administration > Server > Web services > External services
2. Add custom service: "AVC Guild Sync"
3. Enable: Yes
4. Authorized users only: Yes
5. Add functions:
   - `core_user_get_users`
   - `core_cohort_search_cohorts`
   - `core_cohort_add_cohort_members`
   - `core_cohort_delete_cohort_members`
   - `core_role_assign_roles`
   - `core_role_unassign_roles`
   - `core_webservice_get_site_info`

### Step 6: Create Token

1. Go to: Site administration > Server > Web services > Manage tokens
2. Add token for `avc_sync_user` and "AVC Guild Sync" service
3. Copy the token

### Step 7: Configure avc_moodle_sync Module

1. Visit `/admin/config/services/avc-moodle/sync`
2. Configure:
   - **Moodle URL:** `https://moodle.example.com`
   - **Webservice Token:** (from Step 6)
   - **Enable synchronization:** Checked
   - **Enable automatic synchronization:** Checked (for real-time sync)
3. Configure role mapping (YAML format):
```yaml
guild_1:
  cohort: "avc-members"
  roles:
    member: 5
    leader: 3
guild_2:
  cohort: "avc-premium"
  roles:
    member: 5
    admin: 4
```
4. Save configuration

### Step 8: Test Synchronization

```bash
# Test connection
drush avc-moodle:test-connection

# Sync a single user
drush avc-moodle:sync-user admin

# Sync a guild
drush avc-moodle:sync-guild 1

# Full sync
drush avc-moodle:sync-all
```

## Optional: Configure Moodle Data Display

To display Moodle badges and course completions on AVC profiles:

### Step 1: Configure Module

1. Visit `/admin/config/services/avc-moodle/data`
2. Configure:
   - **Moodle URL:** `https://moodle.example.com`
   - **Webservice Token:** (reuse token from sync, or create new with badge/completion permissions)
   - **Enable badges display:** Checked
   - **Enable course completions display:** Checked
3. Save configuration

### Step 2: Place Blocks

1. Go to: Structure > Block layout
2. Place "Moodle Badges" block in desired region
3. Configure block visibility (e.g., only on user profiles)
4. Save configuration

## Troubleshooting

### SSO Not Working

**Symptoms:** Redirect loop, authentication fails, user not created

**Solutions:**
1. Verify OAuth2 endpoints are accessible:
   ```bash
   curl https://avc.example.com/oauth/authorize
   curl https://avc.example.com/oauth/token
   curl https://avc.example.com/oauth/userinfo
   ```

2. Check Client ID and Secret match exactly

3. Verify redirect URI matches exactly (including trailing slash)

4. Check Drupal logs: `/admin/reports/dblog`

5. Check Moodle logs: Site administration > Reports > Logs

6. Enable debugging in both systems

### Role Sync Not Working

**Symptoms:** Cohorts/roles not assigned, API errors

**Solutions:**
1. Test API connection:
   ```bash
   drush avc-moodle:test-connection
   ```

2. Verify webservice token permissions

3. Check role mapping YAML syntax

4. Verify cohorts exist in Moodle

5. Check logs on both systems

### Badges Not Displaying

**Symptoms:** No badges shown, API errors

**Solutions:**
1. Verify webservice token has badge permissions

2. Check user mapping (AVC user → Moodle user)

3. Clear cache: `drush cr`

4. Check block placement and visibility

## Security Considerations

1. **Always use HTTPS** for both AVC and Moodle

2. **Protect OAuth2 keys:**
   ```bash
   chmod 600 private.key public.key
   chown www-data:www-data private.key public.key
   ```

3. **Use strong secrets** for OAuth2 client

4. **Limit webservice token permissions** to minimum required

5. **Use separate tokens** for different operations if possible

6. **Monitor logs** for unauthorized access attempts

7. **Regularly rotate** webservice tokens and OAuth2 secrets

8. **Validate redirect URIs** strictly

## Performance Optimization

1. **Enable caching** for Moodle data (default: 1 hour)

2. **Use queue** for async sync (automatic with cron)

3. **Batch sync operations** during off-peak hours:
   ```bash
   drush avc-moodle:sync-all
   ```

4. **Monitor queue size:**
   ```bash
   drush queue:list
   ```

5. **Adjust batch size** in sync settings if needed

## Maintenance

### Regular Tasks

1. **Monitor sync status:**
   ```bash
   drush avc-moodle:status
   ```

2. **Check logs** weekly for errors

3. **Test SSO** after updates to either system

4. **Verify role mappings** when creating new guilds

5. **Clear caches** after configuration changes:
   ```bash
   drush cr
   ```

### When Updating

1. **Before updating Drupal/Moodle:**
   - Test SSO in dev environment
   - Backup configuration
   - Note any custom changes

2. **After updating:**
   - Test SSO immediately
   - Verify module/plugin compatibility
   - Check for new configuration options

## Support

For issues:

1. Check logs in both systems
2. Review this documentation
3. Search existing issues
4. Create detailed bug report with:
   - Drupal version
   - Moodle version
   - Module/plugin versions
   - Steps to reproduce
   - Log excerpts

## Appendix: NWO Commands

If using NWO, you can use these commands:

```bash
# Setup (interactive)
pl avc-moodle-setup

# Test connection
pl avc-moodle-test

# Sync operations
pl avc-moodle-sync user admin
pl avc-moodle-sync guild 1
pl avc-moodle-sync all

# Check status
pl avc-moodle-status

# Generate keys
pl avc-moodle-generate-keys
```

See `lib/avc-moodle.sh` for implementation details.
