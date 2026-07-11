# nwc_moodle_erase — NWC → ssc erasure sender (ops#81)

Drupal (nwc profile) module that **propagates a right-to-be-forgotten user
deletion on nwc to the ssc Moodle** by POSTing a signed erase command to the
`local_nwc_erase` receiver.

## Staging note (why it lives here, not in the profile)

The nwc profile (`sites/nwc/dev/html/profiles/custom/nwc/`) is a **separate,
gitignored git repo** — code committed there never appears on an nwp-repo
branch. So, exactly like the F26 `auth_nwc` client under `scripts/f26/moodle/`,
this module is **staged** under `scripts/drupal/` on the nwp branch (reviewable
+ pushed together with the receiver) and the operator copies it to the profile:

```
cp -r scripts/drupal/nwc_moodle_erase \
  sites/nwc/dev/html/profiles/custom/nwc/modules/nwc_features/nwc_moodle/modules/nwc_moodle_erase
```

That target path is the one declared in `pairs/ssc.pair-contract.yml`
(`boundary.erasure.provider_paths`), and the service class is `NwcMoodleErase`
(the declared `provider_symbols`), so once copied it satisfies the boundary
manifest.

## Flow (mirrors nwc_moodle_sync)

1. `hook_user_predelete($account)` — reads the **durable account UUID**
   (`$account->uuid()` == the OIDC `sub` == `mdl_user.idnumber`, ops#83) and
   enqueues `{sub, request_id, action, issuer, timestamp}` on the
   `nwc_moodle_erase` queue. **Never** derives `sub` from an email; refuses to
   enqueue if the account has no UUID.
2. `hook_cron()` drains the queue via `EraseWorker`, which calls
   `NwcMoodleErase::send()` — a Bearer-POST of the command (matching
   `contracts/erasure.command.schema.json`) to `/local/nwc_erase/erase.php`,
   the same HTTP shape as `nwc_copyright`'s `MoodleToolPolicySync`.

## Idempotent, retriable, audited

- `request_id` is the idempotency key; a transport error re-throws so the queue
  requeues, and the receiver treats a replayed `request_id` as a 200 no-op.
- A malformed queue item is dropped (not retried forever).
- Deletion of the Drupal user is never blocked/rolled back by a Moodle outage
  (POST happens on cron, not in the predelete transaction).
- Delivery + outcome are logged to the `nwc_moodle_erase` channel; the receiver
  writes the durable audit row.

## Files

| File | Role |
|---|---|
| `nwc_moodle_erase.module` | `hook_user_predelete` (enqueue) + `hook_cron` (drain) |
| `src/NwcMoodleErase.php` | `buildCommand()` (closed shape, fail-closed) + `send()` (Bearer Guzzle POST) |
| `src/Plugin/QueueWorker/EraseWorker.php` | Queue worker → `send()`; requeue on transport error |
| `config/install/nwc_moodle_erase.settings.yml` | Fail-closed defaults (erase OFF, no token) |
| `config/schema/nwc_moodle_erase.schema.yml` | Config schema |

## Configure

`drush config:set nwc_moodle_erase.settings admin_token '<same as receiver>'`,
`moodle_url '<https://ssc-tier>'`, `issuer '<nwc issuer>'`, then
`enable_erase true`. Fail-closed until `enable_erase` is on **and** both
`moodle_url` + `admin_token` are set.

## Boundary — ver / prod (CLAUDE.md AI-never-prod)

Destructive cross-site write. dev/stg/live-test tiers (`*.nwpcode.org`) are
agent-operable (A14). **Real prod erasure fires only through the `ver` desktop
Solo-touch gate**; the prod-tier `admin_token` is a `ver`-held secret, never on
an AI-accessible build/agent host. Two-person review of this destructive,
auth-adjacent path is required before enabling on any live tier (CLAUDE.md
sensitive-path rule).
