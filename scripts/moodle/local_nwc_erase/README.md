# local_nwc_erase — NWC → ssc erasure receiver (ops#81)

Moodle `local` plugin that **receives a signed right-to-be-forgotten erase
command** from NWC's `nwc_moodle_erase` Drupal module and performs a **true
Privacy-API erasure** of the matching user when they are deleted on nwc.

**Staged, NOT installed.** Like the F26 `auth_nwc` client
(`scripts/f26/moodle/`), this tree lives under `scripts/moodle/` in the nwp
repo and is copied into a Moodle root by the operator — no Moodle DDEV site is
owned by this build. Maturity is **ALPHA**. Do **not** enable on any live site
without the two-person review in §Deploy.

## Why this exists

Deleting a person on nwc (the OIDC provider) does nothing on ssc (Moodle, the
consumer). Left behind: the `mdl_user` row + residual PII, grades / quiz
attempts / completions, `tool_policy` consent rows, the
`auth_oauth2_linked_login` SSO link, and moodledata files. This channel
propagates the erasure. (Design: `scratchpad/golive/81-erasure.md`; pitfall
2e / Open-Q3.)

## What it is

One HTTPS POST endpoint `/local/nwc_erase/erase.php`, guarded exactly like
`local_nwc_copyright_sync/policy_set.php` (Bearer token + optional IP allowlist
+ JSON body). It is **not** a Moodle web service (`db/services.php` is
deliberately empty — no WS attack surface).

| File | Role |
|---|---|
| `erase.php` | Bearer/IP/issuer/command guard rail → `eraser::execute()` |
| `status.php` | Smoke endpoint (GET → 200; **never** exercises a real delete) |
| `classes/erase_guard.php` | **Pure, Moodle-free** guards + command validation + idempotency decision (unit-tested) |
| `classes/eraser.php` | Moodle-coupled destructive half: resolve-by-idnumber, Privacy-API delete, oauth2-link delete, audit log |
| `db/install.xml` | `local_nwc_erase_log` audit table (stores the UUID `sub`, never an email) |
| `db/services.php` | Intentionally empty — no external WS function |
| `settings.php` | `enabled` kill switch (default OFF), `admin_token`, `allowed_ips`, `allowed_issuer` |
| `tests/erase_guard_logic_test.php` | Standalone `php` unit test (26 cases; no Moodle needed) |

## Privacy-API integration point (NOT `delete_user()`)

`classes/eraser.php::execute()`:

1. Resolve the target **strictly by `idnumber == sub`** (the F26 UID-lock;
   `sub` = the durable Drupal account UUID, ops#83). **Never by email.**
2. Delete `auth_oauth2_linked_login` for that user (sever the re-link door).
3. `\tool_dataprivacy\api::create_data_request($userid, DATAREQUEST_TYPE_DELETE)`
   → `approve_data_request()` → queue `process_data_request_task` — the
   Privacy-API fan-out that runs every component's `delete_data_for_user()`
   across all contexts. Moodle's ordinary `delete_user()` is only a **soft**
   delete (leaves lastip/phone/address/idnumber, not GDPR-compliant), so it is
   deliberately not used.
4. moodledata file sweep is delegated to the ops#84 dataroot scrubber
   (`lib/sanitizers/moodle-dataroot.sh`) run on the Moodle host; the receiver
   records a marker for it (full in-request wiring = P3).
5. Write an immutable audit row and return `200`.

`action=anonymise` records the softer intent but for P1/P2 drives the same
Privacy-API DELETE (Moodle exposes only DELETE + EXPORT request types; the
DELETE fan-out already lawfully retains required aggregate rows). A distinct
keep-de-identified-aggregates path is a **P4** refinement.

## Fail-closed guards (all refuse and erase NOTHING)

- `enabled` kill switch OFF by default → 503.
- Missing/invalid Bearer (constant-time `hash_equals`) → 401.
- Source IP not in a configured allowlist → 403.
- Command fails the closed schema (missing field, `additionalProperties`,
  bad `action` enum, empty `sub`/`request_id`/`issuer`, non-int `timestamp`) → 400.
- Configured `allowed_issuer` mismatch → 403.
- Unresolvable `sub` (no `idnumber` match) → **200 no-op** (idempotent: already gone).
- Replayed `request_id` → **200 no-op** (safe to re-POST after a 502).
- Any exception → audit `error` row + 500, erases nothing.

## Boundary — ver / prod (CLAUDE.md AI-never-prod)

This channel makes a **destructive** cross-site write. On dev / stg /
live-test tiers (`*.nwpcode.org`) AI/agents may operate it (A14). **Real prod
erasure fires only through the `ver` desktop Solo-touch deploy gate**
(`lib/deploy-gate.sh`); the prod-tier receiver token is a `ver`-held secret,
never on an AI-accessible build/agent host. No AI-accessible machine may fire
an erase at prod.

## Deploy + wire (operator; prod is ver-gated)

1. `cp -r scripts/moodle/local_nwc_erase <moodle_root>/local/nwc_erase`
2. Site admin → Notifications (installs the plugin + `local_nwc_erase_log`).
3. Site admin → Plugins → Local plugins → **NWC Erasure Receiver**: set a strong
   `admin_token`, optionally `allowed_ips` (the nwc host) + `allowed_issuer`,
   then tick **enabled** (fail-closed until you do).
4. Configure the sender (`scripts/drupal/nwc_moodle_erase`) with the SAME token
   + this site's `/local/nwc_erase/erase.php` URL.
5. **Prod only:** the token is provisioned by `ver`; the erase POST is fired
   behind the ver Solo-touch gate. Two-person review of this destructive,
   auth-adjacent path is required (CLAUDE.md sensitive-path rule).

## Rollback

Untick **enabled** (channel goes fail-closed immediately) or uninstall the
plugin (Site admin → Plugins → Uninstall). The `local_nwc_erase_log` audit
table is preserved on disable.
