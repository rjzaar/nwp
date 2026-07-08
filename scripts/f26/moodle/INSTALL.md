# F26 Moodle client (`auth_nwc`) — install & wire to the nwc issuer

**AUTH SURFACE — REQUIRES HUMAN REVIEW BEFORE ENABLE.** Config-only in this
repo: no Moodle DDEV site is owned by this build, so these steps are documented,
not applied. The nwc (Drupal) issuer side *has* been provisioned and verified on
`nwc-dev` (see `../provision-nwc-issuer.sh` / `../verify-nwc-issuer.sh`).

The plugin rides on Moodle **core OAuth2** for the protocol dance and adds only
the F26 §3.2 **UID-lock** (`mdl_user.idnumber` == nwc uid).

## 0. Prerequisites (nwc side — already done on nwc-dev)

Run once against the Drupal issuer:

```bash
scripts/f26/provision-nwc-issuer.sh            # registers keys + ss_moodle client
scripts/f26/verify-nwc-issuer.sh               # 4/4 endpoints OK
```

Note the printed endpoints and the client secret file
`scripts/f26/.f26-moodle-client-secret` (gitignored — copy by hand).

## 1. Install the plugin

```bash
cp -r scripts/f26/moodle/auth_nwc  <moodle_root>/auth/nwc
# then: Site admin > Notifications  (installs the plugin)
```

## 2. Register nwc as a custom OAuth2 service in Moodle

Site admin > Server > **OAuth 2 services** > *Create new custom service*:

| Field | Value |
|---|---|
| Name | `NWC` |
| Client ID | `ss_moodle` |
| Client secret | (contents of `.f26-moodle-client-secret`) |
| Service base URL | `https://nwc-dev.ddev.site` |
| Scopes included | `openid email profile` |
| This service will be used | *Login page and internal* |

Then set the endpoints (simple_oauth 6.1.1 core does **not** serve
`.well-known/openid-configuration`, so enter them manually):

| Endpoint | URL |
|---|---|
| Authorization | `https://nwc-dev.ddev.site/oauth/authorize` |
| Token | `https://nwc-dev.ddev.site/oauth/token` |
| Userinfo | `https://nwc-dev.ddev.site/oauth/userinfo` |
| JWKS / discovery | `https://nwc-dev.ddev.site/.well-known/jwks.json` |

Configure user-field mappings: `sub → idnumber`, `email → email`,
`given_name → firstname`, `family_name → lastname`. The `sub → idnumber`
mapping is what makes the UID-lock durable. Note the numeric **issuer id**.

> To get auto-discovery instead of manual endpoints, add the
> `simple_oauth_server_metadata` submodule on the nwc side (composer). Left out
> here to avoid an un-reviewed dependency add (CLAUDE.md red flag).

## 3. Enable + point the plugin at the issuer

- Site admin > Plugins > **Authentication** > Manage authentication → enable **NWC OIDC (F26)**.
- Settings:
  - **nwc base URL**: `https://nwc-dev.ddev.site`
  - **OAuth2 issuer id**: the id from step 2
  - **Auto-redirect**: optional
  - **Migration: link legacy accounts by verified email**: ON *only* during a
    migration window, then OFF (F26 §3.2).

## 4. Smoke test (needs a running Moodle)

1. Log out of Moodle. Click **Log in with NWC** (or hit `/auth/oauth2/login.php?id=<issuerid>`).
2. Authenticate on nwc, consent once.
3. Back in Moodle: confirm `mdl_user.idnumber` == the nwc uid (`sub`).
4. Change the email on nwc, log in again: Moodle email updates, `idnumber` unchanged.
5. Log in again: the same row is reused (matched by `idnumber`, not email).

## Rollback

- Disable the **NWC OIDC (F26)** auth method (users fall back to existing methods).
- Delete the custom OAuth2 service.
- Uninstall `auth_nwc` (Site admin > Plugins > Uninstall). No core schema is
  altered by this plugin (it only writes standard `mdl_user` fields).
