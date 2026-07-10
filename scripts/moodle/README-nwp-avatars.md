# NWP avatars for Moodle (ss) — ops#86 Phase 2

Moodle counterpart to the Drupal `nwp_avatars` / `mayo_avatars` module. Members
pick a non-PII patron **saint** + **colour**; it renders as their Moodle user
picture everywhere. **No photos, ever.** Real names are kept.

This directory is a **staging area** in the `nwp` repo (Moodle plugins deploy to
the build host, not into a site tree here — mirroring `scripts/f26/moodle/…`).
Two plugins ship:

| Plugin | Type | Role |
|--------|------|------|
| `local_nwp_avatars` | `local` | Storage (2 profile fields), local SVG serve route, WS receiver, helper API. |
| `theme_ss_avatars`  | `theme` | Child theme overriding `render_user_picture()` to emit the avatar. |

> **This is a FIRST CUT, untested on a live Moodle instance.** There is no
> Moodle here to functional-test against; only `php -l` and a standalone
> render-parity test have been run. Every item that needs the ss build host is
> tagged **TODO(build-host)** in the code and listed below.

## Deploy (build host)

```
# Into the ss Moodle root:
cp -r local_nwp_avatars  <moodleroot>/local/nwp_avatars
cp -r theme_ss_avatars   <moodleroot>/theme/ss_avatars
sudo -u www-data php admin/cli/upgrade.php     # runs db/install.php
sudo -u www-data php admin/cli/purge_caches.php
```

Then, in the UI: set `theme_ss_avatars` (or fold its renderer into the site's
existing custom theme — see the parent TODO), enable Web services + a REST
token bound to `local/nwp_avatars:sync` for nwc, and confirm the config posture
below.

## Config posture — "ss never has photos" (pin in `config.php`)

```php
$CFG->disableuserimages = true;   // removes the photo upload control; blanks existing.
$CFG->enablegravatar    = false;  // else external photos re-enter by email hash.
```

Pinning in `config.php` (not just the admin UI) means the switch cannot be
toggled off later. Note: admins retain picture privileges even with
`disableuserimages` on — acceptable on ss (few, trusted admins). The plugin's
admin settings page surfaces a live OK/WARNING for both flags.

## Rasterise-to-PNG fallback (design path (d))

The theme override is a **theme renderer** — it does NOT reach surfaces that
read `user/icon` directly: **forum-digest emails, the mobile app, and some web
services** (e.g. `core_user_get_users` `profileimageurl`). For full coverage
those need the chosen SVG **rasterised to a PNG** and injected via
`process_new_icon()` on sync. A setting `local_nwp_avatars/rasterise_to_icon`
is stubbed for this; **the rasteriser itself is not implemented in this cut** —
build it once the on-ss coverage test shows which surfaces bypass the theme.
If used, `disableuserimages` must be **off** and uploads blocked by capability
instead (the two are mutually exclusive).

## Shared-asset drift (CRITICAL)

`local_nwp_avatars/classes/avatar_manager.php` is a **hand port** of the Drupal
`AvatarManager.php` (source of truth:
`sites/mayo/dev/html/modules/custom/mayo_avatars/src/AvatarManager.php`; the
merged nwc `nwp_avatars` is the same art). The SVG output **must stay
byte-identical** across Drupal and Moodle — the two are independent copies today.

- `tests/render_match_test.php` asserts byte-parity against the Drupal source
  when it is reachable (auto-located in the repo, or via
  `NWP_AVATARS_DRUPAL_SOURCE`). **Run it in CI on both sides.**
- **Future:** replace the hand copy with a single signed **`nwp-avatars-assets`**
  bundle (minisign, per NWP's signed-artifact pattern): one canonical
  `saints.json` + `colours.json` + SVG templates, a generator emitting both the
  Drupal asset dir and the Moodle `avatar_manager`, both consumers verifying the
  signature. That removes the drift risk this hand-port carries.

## Data flow

```
member picks avatar in nwc (Drupal nwp_avatars)
  → nwc pushes (avatar_saint, avatar_colour) over WS  [local_nwp_avatars_set_avatar]
    → Moodle custom profile fields  (profile_field_avatar_saint/_colour)
      → theme render_user_picture() reads fields
        → <img src=/local/nwp_avatars/avatar.php?saint=&colour=>  (local SVG, immutable cache)
```

No render-time dependency on nwc; nwc being down only means a stale-but-correct
cached choice. OIDC claim→custom-field mapping is NOT used (unsupported —
MDL-61789), so the choice arrives via **WS**, not login claims.

## BUILD-HOST TODO list (cannot verify without a live ss)

1. **Enabled auth plugin** — is it `auth/avc_oauth2` (fork) or core `oauth2`?
   Does the fork already patch custom-profile-field mapping (MDL-61789)? If yes,
   §3/WS may simplify. Default assumption: WS sync (this cut).
2. **Theme override reach** — confirm `render_user_picture()` covers *every*
   surface (forums, gradebook, digests/emails, mobile app, WS avatar URLs).
   Emails/mobile/WS bypass it → may force the rasterise-to-icon fallback.
3. **`disableuserimages` vs programmatic icon** — mutually exclusive. Decide
   (c) theme override vs (d) rasterise after the coverage test. If (d), verify
   uploads are still blocked with `disableuserimages` off.
4. **Theme parent** — `config.php` sets `parents => ['boost']` as a placeholder.
   Set it to the theme actually enabled on ss (may be a custom boost child); or
   fold the renderer override into that theme (one theme per page).
5. **Custom profile field names** — `db/install.php` creates `avatar_saint` /
   `avatar_colour`. Confirm these do not clash with fields the existing nwc sync
   already created, and match what the nwc WS push will target.
6. **WS user matching** — confirm the OIDC `sub` ↔ Moodle user linkage (username
   vs idnumber) so `set_avatar` targets the right account. `usermatch` param
   defaults to `username`.
7. **WS token/role** — create the REST token + service user holding ONLY
   `local/nwp_avatars:sync`; enable the `NWP avatar sync` service (ships
   disabled). Mirror the existing nwc→ss sync's token posture.
8. **How the choice arrives** — confirm WS sync (not claim mapping). oauth2
   cannot map the `avatar_saint`/`avatar_colour` custom claims (MDL-61789), so
   the WS path is load-bearing.
9. **Gravatar** — confirm `enablegravatar` is off on ss.
10. **avatar.php auth** — the SVG route runs without login (non-PII static
    image). If ss must gate avatars behind login, wrap it in `require_login()`.
11. **Transport choice for the receiver** — this cut ships a Moodle *external
    function*; the sibling `local_nwc_copyright_sync` uses a bearer-token PHP
    endpoint. Confirm which the operator wants for consistency.

## Tests run in this cut

- `php -l` clean on every PHP file.
- `tests/render_match_test.php`: 67 avatars × 4 colours rendered, all
  well-formed XML, **byte-identical to the Drupal source of truth** (parity
  check passed against `mayo_avatars/src/AvatarManager.php`).
