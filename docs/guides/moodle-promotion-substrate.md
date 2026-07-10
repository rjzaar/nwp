# Moodle promotion substrate — `pl moodle-promote` / `pl moodle-smoke` (ADR-0031 D8)

> **Status: SHIPPED (substrate + OAuth wiring descriptors), enabling a live pair
> is operator-gated.** This is the Moodle-stack analogue of the settings.php
> rewrite + `drush cr` the Drupal promotion commands do. **Date:** 2026-07-10.
> **ADR:** [ADR-0031](../decisions/0031-paired-site-versioning-and-promotion.md)
> D8 (Moodle promotion substrate); **F26** (OIDC — native `simple_oauth`
> `/oauth/userinfo`, route `simple_oauth.userinfo`).

## Why

`pl` was built to move a **Drupal** site through the tiers: it rewrites
`html/sites/default/settings.local.php` and runs `drush cr`. A Moodle site has
none of that — no drush, a `config.php` instead of `settings.php`, a `moodledata`
dir, and `$CFG->wwwroot` baked into the DB. ADR-0031 D8 requires a per-type
substrate so `pl` can promote a Moodle tier at all. This is that substrate.

## What it delivers

| Piece | Where | Role |
|---|---|---|
| Substrate library | [`lib/moodle-promote.sh`](../../lib/moodle-promote.sh) | settings writer, wwwroot-rewrite plan, vhost generator, OIDC wiring, plan orchestrator |
| Entry command | [`scripts/commands/moodle-promote.sh`](../../scripts/commands/moodle-promote.sh) | `pl moodle-promote <site> --tier=dev\|stg [--apply]` |
| Smoke | [`scripts/commands/moodle-smoke.sh`](../../scripts/commands/moodle-smoke.sh) | `pl moodle-smoke <consumer> --tier=… [--run]` |
| Per-tier config schema | [`example.nwp.yml`](../../example.nwp.yml) `sites.<m>.moodle.tiers` | wwwroot/dataroot/db*/prefix per tier (NO password) |
| Sanitizer (separate agent) | `lib/sanitizers/moodle.sh` + `sanitize_staging_db` dispatch | fail-closed stub — untouched here |

Mapping to the Drupal steps:

| Drupal | Moodle substrate |
|---|---|
| rewrite `settings.local.php` | `moodle_write_config` → `config.php` |
| `drush cr` | `moodle_purge_caches_cmd` (printed) |
| base-URL fixups | `moodle_wwwroot_rewrite_plan` (`admin/cli/replace.php`, printed) |
| nginx vhost | `moodle_generate_vhost` (written to a file, not installed) |
| smoke | `pl moodle-smoke` (bootstrap + login + OIDC discovery) |

## Safety model (fail-closed, off-unless-configured)

- **Non-canonical tiers only.** `moodle_write_config` REFUSES any tier that is
  not `dev`/`stg`/`test`. A `live`/`prod` Moodle root holds real students'
  records (ADR-0031 plane 5b) and is **never** rewritten by the pipeline.
- **Off unless configured.** A site whose `project.type != moodle` is a no-op.
  Even for a Moodle site, the settings writer refuses until a
  `.moodle.tiers.<tier>.wwwroot` is present — so the fleet's Moodle sites (which
  have no `moodle:` block today) are inert.
- **No secrets.** `$CFG->dbpass` is NEVER on argv or hardcoded — it is resolved
  at write time from `get_data_secret` (`moodle.<site>.<tier>.db_password`) or,
  for a ddev dev tier, the well-known non-secret `db` default
  (`dbpass_ddev_default: true`). `config.php` is written mode `0600`.
- **No network, no install, no DB execution.** The vhost is written to a file
  (never installed/reloaded); the wwwroot DB-side rewrite + cache purge are
  **printed** (`php admin/cli/…`), never run. The smoke is dry-run by default and
  refuses `--run` against prod without `--force-prod`.
- **Additive.** No Drupal promotion path is touched; the Moodle sanitizer files
  are owned by a separate agent and are only *called* through the existing
  `sanitize_staging_db` dispatch, never modified here.

## Config (add to a Moodle site in `nwp.yml`; template in `example.nwp.yml`)

```yaml
sites:
  ssc:
    project: { type: moodle }
    paired_with: nwc
    moodle:
      tiers:
        dev:
          wwwroot: "https://ssc-dev.ddev.site"
          dataroot: "/var/www/ssc/dev/moodledata"
          dbtype: mariadb
          dbhost: db
          dbname: db
          dbuser: db
          prefix: "mdl_"
          dbpass_ddev_default: true       # ddev dev DB pass is the non-secret 'db'
        stg:
          wwwroot: "https://ssc-stg.ddev.site"
          dataroot: "/var/www/ssc/stg/moodledata"
          # … dbpass comes from get_data_secret: moodle.ssc.stg.db_password
      oauth:
        client_id: ss_moodle
        client_secret_source: "moodle.ssc.oauth.client_secret"
        enabled: false
```

The per-tier **issuer URL** for OIDC comes from the **pair contract**
(`pairs/<consumer>.pair-contract.yml` → `endpoints.<tier>.issuer`), not this
block.

## Usage

```
pl moodle-promote ssc --tier=dev --dry-run     # plan only (default) — writes nothing
pl moodle-promote ssc --tier=dev --apply       # write config.php + vhost + OIDC descriptors
pl moodle-smoke   ssc --tier=dev --dry-run     # plan the bootstrap + login + OIDC probes
```

`--apply` writes:

- `sites/ssc/dev/config.php` (mode 0600),
- `private/moodle/ssc/ssc-dev.nginx.conf`,
- `private/moodle/ssc/ssc-dev.oidc-consumer.yml` (Moodle auth_nwc_oauth2 issuer
  descriptor — off-by-default),
- `private/moodle/ssc/ssc-dev.oidc-provider-snippet.yml` (Drupal simple_oauth
  Consumer artifact — apply on nwc; NOT committed to the nwc repo),

then **prints** the wwwroot DB-rewrite + cache-purge commands for the operator.

## OAuth wiring (F26) — off-by-default

- **Consumer (Moodle):** the descriptor points at nwc's **native** endpoints —
  `.../oauth/authorize`, `.../oauth/token`, and importantly
  `.../oauth/userinfo` (F26 M1: native `simple_oauth`, no custom
  UserInfoController). `client_id` + `client_secret_source` come from config; the
  secret **value** is never written — the pipeline resolves it into a 0600 file
  at apply time. `enabled: false` until the operator flips it.
- **Provider (nwc / Drupal):** the substrate emits a Consumer-entity artifact
  (redirect URI = the Moodle tier's `wwwroot` + `/admin/oauth2callback.php`,
  PKCE S256, `openid email profile`). It is an **operator TODO**, not a commit
  into the nwc profile repo. The `NwcOidcClaimsServiceProvider` claim allow-list
  already exists on the provider side.

## Operator TODOs to actually enable a live Moodle pair

1. **Register + configure** the Moodle site: add the `moodle.tiers.<tier>` block
   (above) and, per ADR-0031 D4, register `ssc`/`ssd` in `nwp.yml`.
2. **Provision the DB password secret** for non-ddev tiers:
   `moodle.<site>.<tier>.db_password` in `.secrets.data.yml`
   (data-secret tier — not readable by AI).
3. **Author the pair contract** `pairs/<consumer>.pair-contract.yml`
   (`endpoints.<tier>.issuer`) — the OIDC wiring reads it.
4. **Provider client secret:** generate the `ss_moodle` Consumer secret on nwc
   (Drupal), store it as `moodle.<consumer>.oauth.client_secret`
   (`client_secret_source`), and apply the provider snippet on nwc.
5. **Install the vhost** on the server (`private/moodle/<site>/<site>-<tier>.nginx.conf`
   → nginx `sites-available`/`conf.d`), `nginx -t`, reload — NWP does not.
6. **DNS** for the tier host (the `wwwroot` hostname).
7. **DB-side `$CFG->wwwroot` rewrite** on the promoted (non-prod) Moodle:
   `php admin/cli/replace.php --search=<old> --replace=<new> --non-interactive`
   then `php admin/cli/purge_caches.php` — printed by `--apply`, run by the
   operator. **Never** against a live/prod site.
8. **`moodledata`** joins the backup surface (ADR-0031 D8 — it is in zero backups
   today). The sanitizer/backup work owns scrubbing user-uploaded files.
9. **Flip `oauth.enabled: true`** and run `pl moodle-smoke <consumer> --tier=<t>
   --run` (a token round-trip stays F26-gated).

## Deliberate stubs / fail-closed choices (auth-adjacent)

- No real OIDC token round-trip, no `simple_oauth` client creation, no secret is
  read/written — those are F26 human-gated (nwp!49) and left as descriptors +
  TODOs.
- `moodle_oauth_*` **refuse** a `prod` tier and refuse an empty issuer rather
  than guess.
- The DB-side wwwroot rewrite is **printed, not executed** — Moodle's
  `admin/cli/replace.php` is destructive text replacement; running it is an
  operator act against a non-prod site.
- The Moodle **sanitizer** remains the fail-closed stub owned by the sanitizer
  agent; this substrate calls the existing `sanitize_staging_db` dispatch and
  never modifies it.
