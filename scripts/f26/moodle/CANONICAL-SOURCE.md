# `auth_nwc` lives in **nwp/ss-moodle-plugins** — not here

This directory used to hold a full copy of the `auth_nwc` Moodle plugin. It has
been **retired to this pointer** (programme item 9, 2026-07-26).

## Why

`auth_nwc` carries two load-bearing properties: the **SSO uid-lock**
(`mdl_user.idnumber` == nwc uid, which the ssc/ssd OIDC identities depend on) and
the **Art.9 consent gate** (ops#118). It existed in three repositories at three
different versions:

| Copy | `$plugin->version` | `$plugin->release` |
|---|---|---|
| `scripts/f26/moodle/auth_nwc` (this repo — **removed**) | `2026071101` | `1.0.0` |
| `sites/ssc/dev/auth/nwc` | `2026072400` | `1.2.0-draft` |
| `sites/*/.plugin-src/ss-moodle-plugins/auth/nwc` | `2026072400` | `1.2.0-draft` |
| **LIVE** `ssc:/var/www/ssc/auth/nwc` (probed 2026-07-26) | `2026072400` | `1.2.0-draft` |

Every other copy — including the one actually serving members — was newer. This
copy was the *only* one committed to `nwp/nwp`, so it was also the one most
likely to be picked up by anyone reading this repo. A deploy sourced from it
would have silently **downgraded live ssc and dropped the Art.9 consent gate**.
Nothing detected that, because nothing compared the copies.

## Where it is now

**Canonical: `nwp/ss-moodle-plugins`, path `auth/nwc/`.** That repo is the
release repo for every first-party NWP Moodle plugin, and it is what
`pl moodle plugins sync <site> --apply` fetches into
`sites/<site>/.plugin-src/ss-moodle-plugins/`.

## How the drift is now detected

```bash
pl moodle plugin drift ssc auth/nwc          # compares dev tree, repo cache and LIVE
```

`pl moodle plugin drift` fails when copies disagree on `$plugin->version`, and —
importantly — also fails with **"cannot verify"** when it finds fewer than two
copies to compare. "I found nothing" is never reported as "everything agrees".

## Install / wiring instructions

The Drupal-issuer half of the F26 wiring is still documented in `INSTALL.md` in
this directory; only the plugin *source* moved. Substitute step 1's
`cp -r scripts/f26/moodle/auth_nwc <moodle_root>/auth/nwc` with the guarded verb:

```bash
pl moodle plugins sync   <site> --apply
pl moodle plugin  deploy <site> auth/nwc --tier=live --apply
```
