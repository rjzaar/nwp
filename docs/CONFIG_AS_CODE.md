# Config-as-Code + the Config-Drift Gate (report P3 / nwp/ops#63)

**Status:** mechanism landed, per-site rollout is an operator task.
**Last Updated:** 2026-07-24

## The gap this closes

Every industry reference tool (Vortex is the one we benchmarked against) keeps a
Drupal site's **exported configuration in git** and treats a mismatch between
tracked config and active config as a build failure. NWP historically did the
opposite: the config sync directory is gitignored, so `stg2live` deliberately
runs **no** `config:import` and `stg2prod` skips it unless
`NWP_ALLOW_CONFIG_IMPORT=1` (the ops#63 "cheap guard", already merged). The
result is that a live/prod site's **active** config drifts invisibly from git:
`drush updatedb` runs `hook_update_N` / `hook_post_update_NAME`, which may
rewrite active config, and nothing notices, records, or reviews it.

Two things fix this, and they are independent — a site can adopt the gate before
it fully tracks config as code:

1. **The config-drift gate** — a fail-closed check wrapped around live
   `drush updatedb` that exports config before and after and aborts the deploy
   if update hooks changed active config unexpectedly. Reusable, host-agnostic,
   **off by default** (`lib/config-drift.sh`).
2. **Tracked config-as-code** — the site commits `config/sync` to its repo and
   uses `config_split` for per-environment overrides (dev/stg/live/prod), so the
   deploy can eventually run a trusted `config:import` and the drift gate has a
   git baseline to reconcile against.

## 1. The config-drift gate

`lib/config-drift.sh` provides `config_drift_guarded_updatedb`. It does **not**
call `ssh` or `drush` itself — the caller injects an *executor function* (so the
same code runs locally in unit tests and over ssh against a live box) and a
*drush prefix* valid on the target. Around `drush updatedb` it:

1. exports active config to a fresh temp dir on the target (snapshot **before**),
2. fingerprints it as a sorted `sha256` manifest **on the target** (no files
   cross the ssh boundary),
3. runs `drush updatedb`,
4. exports + fingerprints again (snapshot **after**),
5. compares.

| Outcome | Exit | Deploy behaviour |
|---------|------|------------------|
| active config unchanged by updatedb | 0 | proceed |
| `updatedb` itself failed | 1 | abort, fail-loud (schema hooks not applied) |
| **active config changed** (drift) | 2 | **abort, fail-closed**, print the manifest diff |
| gate could not run (export failed / no config) | 3 | abort — cannot verify |

Legitimate drift (e.g. a module update that genuinely adds a config key) is
handled by opting in with **`NWP_ALLOW_CONFIG_DRIFT=1`**: the gate downgrades the
drift to a warning, prints the diff, and proceeds — after which the operator
exports and commits the new config to the tracked `config/sync`.

### Enablement — off until a site opts in

The gate engages only when a site opts in, so **existing deploys are byte-for-byte
unchanged** until config-as-code is adopted. `config_drift_enabled <site>`:

1. `NWP_CONFIG_DRIFT_GATE` env override wins if set (`1` on / `0` off);
2. else per-site `.nwp.yml` → `config.drift_gate: true`;
3. else **OFF**.

It is wired into `stg2live.sh`'s `run_live_db_updates` (the live `updatedb`
step). When disabled, the original updatedb path runs unchanged; when enabled,
the gated path replaces it and maps the exit codes above onto the existing
fail-loud/abort semantics (maintenance mode is left ON on any abort, exactly as
today).

## 2. Making a site track config as code (per-site rollout)

This is an **operator task, per-site** — do not gitignore-flip sites in bulk.
`pl config track <site>` scaffolds the layout and prints the exact steps; it is
**dry-run by default** and never runs git or edits `.gitignore` for you.

Recommended layout inside the site's own profile/repo:

```
<docroot>/../config/
  sync/          # the canonical exported config (committed)
  dev/           # config_split: dev-only overrides (devel, kint, ...)
  stg/           # config_split: staging overrides
  live/          # config_split: live overrides
  prod/          # config_split: prod overrides
```

Steps (also printed by `pl config track <site>`):

1. **Un-ignore `config/sync` in the site repo.** In the *site's* `.gitignore`
   (not NWP's), remove/negate the pattern that ignores `config/sync` — e.g. add
   `!config/sync/`. Keep dumps, `settings.local.php`, and keys ignored.
2. **Point Drupal at the sync dir** in `settings.php` (usually already set):
   `$settings['config_sync_directory'] = '../config/sync';`
3. **Export the current active config** from the environment you trust as the
   baseline: `ddev drush cex -y` (dev) — then review and commit `config/sync`.
4. **Add `config_split`** (`composer require drupal/config_split`) and define one
   split per environment pointing at `config/dev`, `config/stg`, `config/live`,
   `config/prod`. Put environment-only modules/settings in the matching split so
   the shared `config/sync` stays environment-neutral. Activate the right split
   per environment via `settings.local.php` (e.g.
   `$config['config_split.config_split.dev']['status'] = TRUE;`).
5. **Move the runtime-only set into `settings.local.php` overrides** rather than
   tracked config: the `simple_oauth` signing-key paths, OAuth grants, the
   error-report token, the `search_api` server backend — the config that must
   differ per host and must **never** be clobbered by an import (see the ops#63
   guard commit and the `stg2live`/`stg2prod` rsync excludes for `oauth-keys/`,
   `keys/`).
6. **Opt the site into the drift gate:** set `config.drift_gate: true` in the
   site's `.nwp.yml` (or run a deploy with `NWP_CONFIG_DRIFT_GATE=1`).
7. Once a trusted baseline exists, a deploy `config:import` can be enabled with
   `NWP_ALLOW_CONFIG_IMPORT=1` (still fail-closed by default per the ops#63
   guard).

## Rollout status

- **Done / reviewable:** the gate library, its wiring into `stg2live` (off by
  default), the `pl config track` scaffolder, unit tests.
- **Operator TODO (per-site):** actually un-ignore `config/sync`, export the
  baseline, add `config_split`, move the runtime-only set to `settings.local.php`,
  then flip `config.drift_gate: true`. No real site is converted by this change.
