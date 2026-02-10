# Guide: Creating a Moodle Site with Microsoft SSO using NWP

**Date:** 2026-02-10
**NWP Version:** 0.29+

---

## Overview

This guide walks through two main tasks:

1. **Creating a Moodle site** using NWP's Moodle recipe (`m`)
2. **Configuring Microsoft account sign-on** via Moodle's built-in OAuth2 support and Microsoft Entra ID (formerly Azure AD)

NWP handles the Moodle installation and infrastructure. Microsoft SSO is configured at the Moodle level after the site is running.

---

## Prerequisites

- NWP installed at `~/nwp/`
- DDEV installed and working
- Docker running
- A Microsoft account with access to the [Azure portal](https://portal.azure.com) (for registering the OAuth2 app)
- For production: a domain name and DNS control

---

## Part 1: Create the Moodle Site

### Step 1: Configure the recipe in nwp.yml

The Moodle recipe is already defined in `example.nwp.yml`. If your `nwp.yml` doesn't have it yet, add or verify the recipe section:

```yaml
recipes:
  m:
    type: moodle
    source: https://github.com/moodle/moodle.git
    branch: MOODLE_404_STABLE
    webroot: .
    sitename: "My Moodle Site"
    php: 8.1
    database: mariadb
    auto: y
```

Customize `sitename` and `branch` as needed. Available stable branches include `MOODLE_404_STABLE`, `MOODLE_403_STABLE`, etc.

### Step 2: Install the site

Run the NWP install command, providing the recipe (`m`) and a site name:

```bash
cd ~/nwp
pl install m mysite
```

Replace `mysite` with your desired site name (e.g., `lms`, `school`, `moodle`).

NWP will execute 7 steps automatically:

1. Clone the Moodle repository
2. Configure DDEV
3. Set PHP memory/upload limits
4. Launch DDEV containers
5. Create the moodledata directory (outside webroot)
6. Run the Moodle installer (database setup, admin account)
7. Post-installation configuration (cache purge, DDEV compatibility)

### Step 3: Verify the installation

Once installation completes, NWP displays the admin credentials and opens the site. You can also access it manually:

```bash
cd ~/nwp/sites/mysite
ddev launch
```

Default admin credentials (unless overridden in `.secrets.yml`):

| Field    | Default          |
|----------|------------------|
| Username | `admin`          |
| Password | `Admin123!`      |
| Email    | `admin@example.com` |

To customize these before installation, add to your `.secrets.yml`:

```yaml
moodle:
  admin_user: myadmin
  admin_password: MySecurePassword123!
  admin_email: admin@yourdomain.com
  shortname: lms
```

### Step 4: Confirm the site is working

Log in as admin and verify:

- The dashboard loads
- You can navigate to **Site administration**
- The site name appears correctly

---

## Part 2: Register an App in Microsoft Entra ID

Before configuring Moodle, you need to register an OAuth2 application in Microsoft's identity platform.

### Step 1: Go to the Azure portal

Navigate to [https://portal.azure.com](https://portal.azure.com) and sign in with your Microsoft account.

### Step 2: Register a new application

1. Go to **Microsoft Entra ID** (or search "App registrations" in the top bar)
2. Click **App registrations** in the left sidebar
3. Click **+ New registration**
4. Fill in:
   - **Name:** `Moodle LMS` (or whatever you prefer)
   - **Supported account types:** Choose based on your needs:
     - *Single tenant* -- Only accounts in your organization
     - *Multitenant* -- Accounts in any Microsoft Entra directory
     - *Multitenant + personal Microsoft accounts* -- Broadest access (includes @outlook.com, @hotmail.com, etc.)
   - **Redirect URI:**
     - Platform: **Web**
     - URI: `https://mysite.ddev.site/admin/oauth2callback.php`
     - For production: `https://yourdomain.com/admin/oauth2callback.php`
5. Click **Register**

### Step 3: Note the Application (client) ID

After registration, you'll see the **Overview** page. Copy these values -- you'll need them for Moodle:

- **Application (client) ID** -- e.g., `a1b2c3d4-e5f6-7890-abcd-ef1234567890`
- **Directory (tenant) ID** -- e.g., `f0e1d2c3-b4a5-6789-0123-456789abcdef`

### Step 4: Create a client secret

1. In the left sidebar, click **Certificates & secrets**
2. Click **+ New client secret**
3. Add a description (e.g., `Moodle OAuth2`) and choose an expiry (24 months recommended)
4. Click **Add**
5. **Copy the secret value immediately** -- it won't be shown again

### Step 5: Configure API permissions (optional but recommended)

By default the app has `User.Read` permission, which is sufficient for basic SSO. For additional profile data:

1. Go to **API permissions**
2. Click **+ Add a permission**
3. Select **Microsoft Graph** > **Delegated permissions**
4. Add:
   - `openid` (sign-in)
   - `profile` (name, photo)
   - `email` (email address)
5. Click **Grant admin consent** if you're a tenant admin

---

## Part 3: Configure Microsoft OAuth2 in Moodle

### Option A: Using the Moodle Admin UI (recommended)

#### Step 1: Navigate to OAuth2 services

Log in as admin, then go to:

**Site administration > Server > OAuth 2 services**

#### Step 2: Create a Microsoft issuer

Click the **Microsoft** button (Moodle has a built-in Microsoft template).

Fill in:

| Field         | Value                                      |
|---------------|--------------------------------------------|
| Name          | `Microsoft`                                |
| Client ID     | Your Application (client) ID from Step 3 above |
| Client secret | Your client secret from Step 4 above       |

Leave the other fields at their defaults -- Moodle auto-configures the Microsoft endpoints.

Click **Save changes**.

#### Step 3: Enable the OAuth2 authentication plugin

Go to: **Site administration > Plugins > Authentication > Manage authentication**

1. Enable **OAuth 2** by clicking the eye icon (if not already enabled)
2. Click **Settings** next to OAuth 2
3. Configure as needed -- the defaults work for most setups

#### Step 4: Link the issuer to the login page

After enabling the OAuth 2 auth plugin, go back to:

**Site administration > Server > OAuth 2 services**

Verify your Microsoft issuer shows with a green checkmark. Users will now see a "Microsoft" login button on the Moodle login page.

### Option B: Using the Moodle CLI (automated)

If you prefer command-line configuration (useful for scripting), SSH into the DDEV container:

```bash
cd ~/nwp/sites/mysite

# Enable the OAuth2 authentication plugin
ddev exec php admin/cli/cfg.php --name=auth --set="oauth2"

# Purge caches so the auth plugin loads
ddev exec php admin/cli/purge_caches.php
```

The OAuth2 issuer (Microsoft endpoints, client ID, client secret) must still be configured via the admin UI or by inserting records into the `mdl_oauth2_issuer` table, since Moodle does not provide CLI commands for OAuth2 issuer management.

---

## Part 4: Test the SSO Flow

### Step 1: Open a private/incognito browser window

Navigate to your Moodle site's login page:

```
https://mysite.ddev.site/login/index.php
```

### Step 2: Click the Microsoft login button

You should see a "Microsoft" button below the standard login form. Click it.

### Step 3: Authenticate with Microsoft

You'll be redirected to Microsoft's login page. Sign in with a Microsoft account that matches the tenant type you chose:

- **Single tenant:** Must be an account in your organization
- **Multitenant + personal:** Any Microsoft account works

### Step 4: Grant consent (first login only)

On first login, Microsoft shows a consent screen listing the permissions your app requests. Click **Accept**.

### Step 5: Verify the Moodle account

After consent, you're redirected back to Moodle. Depending on your Moodle settings:

- **New account created:** Moodle creates a user account linked to the Microsoft identity
- **Existing account linked:** If the email matches an existing Moodle user, the accounts are linked

Check the user profile to confirm the name and email populated correctly.

### Troubleshooting

| Problem | Cause | Fix |
|---------|-------|-----|
| "Redirect URI mismatch" | The redirect URI in Azure doesn't match Moodle's URL | Update the redirect URI in Azure App Registration to match exactly: `https://yoursite/admin/oauth2callback.php` |
| "Invalid client secret" | Secret expired or copied incorrectly | Generate a new secret in Azure and update it in Moodle |
| No Microsoft button on login page | OAuth2 auth plugin not enabled | Enable it at Site administration > Plugins > Authentication > Manage authentication |
| "User not in tenant" | Single-tenant app but user is external | Change to multitenant in Azure, or add the user to your directory |
| Login loops back to login page | Cookie/session issue in DDEV | Clear browser cookies, or check DDEV HTTPS config with `ddev describe` |

---

## Part 5: Production Deployment

### Step 1: Update the redirect URI

When moving from DDEV to production, update the redirect URI in Azure:

1. Go to your app registration in the Azure portal
2. Go to **Authentication**
3. Update the redirect URI from `https://mysite.ddev.site/admin/oauth2callback.php` to `https://yourdomain.com/admin/oauth2callback.php`
4. You can keep both URIs if you need dev and production to work simultaneously

### Step 2: Deploy with NWP

Use NWP's deployment pipeline to push to production:

```bash
# Push to staging first
pl dev2stg mysite

# Then to production on Linode
pl stg2prod mysite-stg
```

### Step 3: Update Moodle's wwwroot

After deployment, verify Moodle's `$CFG->wwwroot` in `config.php` matches your production domain. NWP's deployment scripts handle this, but verify:

```bash
# On the production server
grep wwwroot /var/www/mysite/config.php
```

### Step 4: Enforce HTTPS

For production, ensure HTTPS is enforced. In Moodle admin:

**Site administration > Security > HTTP security**

Enable: **Use HTTPS for logins**

Or via CLI on the server:

```bash
php admin/cli/cfg.php --name=loginhttps --set=1
```

---

## Part 6: Optional Enhancements

### Restrict login to Microsoft only

If you want to disable manual username/password login and require Microsoft SSO:

1. Go to **Site administration > Plugins > Authentication > Manage authentication**
2. Disable **Manual accounts** (but keep at least one admin with manual login for emergency access)
3. Set **Self registration** to **Disable**

### Auto-create accounts with specific roles

In the OAuth 2 auth plugin settings:

- **Role for new users:** Set to `student` (or your preferred default)
- **Allowed domains:** Restrict to `@yourorganization.com` if needed

### Map Microsoft groups to Moodle cohorts

For automatic role assignment based on Microsoft Entra groups, install the **auth_oidc** plugin from Microsoft's official Moodle integration package:

1. Download from [https://github.com/Microsoft/moodle-auth_oidc](https://github.com/Microsoft/moodle-auth_oidc)
2. Extract to `sites/mysite/auth/oidc/`
3. Visit **Site administration > Notifications** to install
4. Configure group-to-cohort mapping in the plugin settings

This is more capable than the built-in OAuth2 plugin and supports:

- Automatic group/team sync
- User field mapping
- Profile photo sync
- Microsoft 365 integration (Teams, OneDrive)

### Combine with AVC-Moodle SSO

If you also run an AVC (Drupal) site and want both AVC SSO and Microsoft SSO, Moodle supports multiple OAuth2 issuers. Users will see both login options on the login page:

```
[Login with AVC]     [Login with Microsoft]
```

Set up AVC SSO using NWP's built-in integration:

```bash
pl avc-moodle-setup avc mysite
```

See `docs/NWP_MOODLE_SSO_IMPLEMENTATION.md` for the full AVC integration guide.

---

## Quick Reference

### Key URLs

| Environment | Moodle URL                           | Redirect URI for Azure                              |
|-------------|--------------------------------------|-----------------------------------------------------|
| DDEV (dev)  | `https://mysite.ddev.site`           | `https://mysite.ddev.site/admin/oauth2callback.php` |
| Production  | `https://yourdomain.com`             | `https://yourdomain.com/admin/oauth2callback.php`   |

### Key NWP Commands

| Command                          | Description                          |
|----------------------------------|--------------------------------------|
| `pl install m mysite`            | Create a new Moodle site             |
| `pl dev2stg mysite`              | Push to staging                      |
| `pl stg2prod mysite-stg`        | Deploy to production                 |
| `pl backup mysite`               | Backup the site                      |
| `pl restore mysite`              | Restore from backup                  |
| `pl avc-moodle-setup avc mysite` | Set up AVC-Moodle SSO (if using AVC) |

### Microsoft Entra ID Endpoints (for reference)

These are auto-configured by Moodle's Microsoft template, but for reference:

| Endpoint      | URL                                                                                 |
|---------------|-------------------------------------------------------------------------------------|
| Authorization | `https://login.microsoftonline.com/{tenant-id}/oauth2/v2.0/authorize`               |
| Token         | `https://login.microsoftonline.com/{tenant-id}/oauth2/v2.0/token`                   |
| User info     | `https://graph.microsoft.com/v1.0/me`                                               |
| Logout        | `https://login.microsoftonline.com/{tenant-id}/oauth2/v2.0/logout`                  |

Replace `{tenant-id}` with your Directory (tenant) ID, or use `common` for multitenant apps.
