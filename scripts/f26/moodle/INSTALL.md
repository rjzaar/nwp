# F26 Moodle client (`auth_nwc`) — install & wire to the nwc issuer

> **⚠ The plugin source is NO LONGER in this directory.** It was a stale
> `2026071101 / 1.0.0` copy while every other copy — including live `ssc` — was
> `2026072400 / 1.2.0-draft` with the Art.9 consent gate. Canonical source is
> **`nwp/ss-moodle-plugins`, `auth/nwc/`**. See [CANONICAL-SOURCE.md](CANONICAL-SOURCE.md).
> Check for drift with `pl moodle plugin drift <site> auth/nwc`.

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
scripts/f26/verify-nwc-issuer.sh               # 6/6 (endpoints + anon-gate + discovery)
scripts/f26/verify-native-userinfo.sh          # 3/3 (native userinfo returns claims + guilds)
```

The nwc issuer also has OIDC discovery enabled (F26 rec b — the
`simple_oauth_server_metadata` module from `e0ipso/simple_oauth_21`), so
`https://nwc-dev.ddev.site/.well-known/openid-configuration` serves the full
provider metadata. Note the client secret file
`scripts/f26/.f26-moodle-client-secret` (gitignored — copy by hand).

## 1. Install the plugin

```bash
# Canonical source is nwp/ss-moodle-plugins — sync it, then deploy with the
# guarded verb (never a hand cp: that is what produced the 3-way version split).
pl moodle plugins sync   <site> --apply
pl moodle plugin  deploy <site> auth/nwc --tier=live --apply
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

**Prefer auto-discovery (F26 rec b).** The nwc issuer now serves
`/.well-known/openid-configuration`, so let Moodle discover the endpoints
instead of hand-entering them:

- Set **Service base URL** to `https://nwc-dev.ddev.site` and save. Moodle's
  OAuth2 issuer discovery (`\core\oauth2\api::discover_endpoints()`) fetches
  `<base>/.well-known/openid-configuration` and auto-populates the
  authorization, token, userinfo and JWKS endpoints. Confirm they were filled
  in under the issuer's **Endpoints** after saving.

Manual entry remains available as a fallback (e.g. if discovery is blocked):

| Endpoint | URL |
|---|---|
| Authorization | `https://nwc-dev.ddev.site/oauth/authorize` |
| Token | `https://nwc-dev.ddev.site/oauth/token` |
| Userinfo | `https://nwc-dev.ddev.site/oauth/userinfo` |
| JWKS | `https://nwc-dev.ddev.site/.well-known/jwks.json` |
| Discovery | `https://nwc-dev.ddev.site/.well-known/openid-configuration` |

Configure user-field mappings: `sub → idnumber`, `email → email`,
`given_name → firstname`, `family_name → lastname`. The `sub → idnumber`
mapping is what makes the UID-lock durable. Note the numeric **issuer id**.

> Discovery is provided by the `simple_oauth_server_metadata` module (submodule
> of `e0ipso/simple_oauth_21`). It is **not** on packages.drupal.org, so it is
> installed via a git VCS composer repo pinned to a tag — see the F26 review
> report §Discovery. Same maintainer as `simple_oauth` itself. For non-dev
> environments, mirror it into `git.<gitlab-host>` per the NWP threat model rather
> than pulling from GitHub at deploy time.

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
