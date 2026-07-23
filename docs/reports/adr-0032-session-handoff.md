# ADR-0032 Sanitising Suite — Session Handoff / State-of-Things

**Written:** 2026-07-23 · **Covers:** one long working session (2026-07-20) + follow-up checks (07-21, 07-23)
**Purpose:** hand the full picture to another conversation — what was built, where it lives, what's proven, what's only-in-conversation, and what remains. Read this **with** the ops issues (esp. ops#114 umbrella + ops#116).

> ⚠️ This doc is UNCOMMITTED (docs/reports/). It's a handoff, not a project doc — commit it or delete it as you like.
> ✅ As of 2026-07-23 **none of this work is superseded** — all commits are on `origin/main`; only unrelated `stg2live`/`pl audit` commits landed since.

---

## 1. TL;DR — what this session accomplished

Designed, built, tested, and **merged** the ADR-0032 non-production data-refresh & sanitising suite for the coupled Drupal+Moodle fleet, then validated it against real databases. The single most important outcome:

> **Found and fixed a CRITICAL cross-stack SSO bug:** the Drupal sanitisers (`standard.sh`, `mayo.sh`) did **not** use the shared OIDC email hash — they used positional `user<uid>@example.com` while Moodle used `<hash>@sanitized.test`. So a sanitised `nwc↔ssc` dev refresh would have produced **mismatched emails across the two stacks and broken the SSO join**. Fixed so both stacks hash identically; **proven** at the data layer.

Everything is on `main`. The only work left genuinely needs a real prod host or a human at a browser.

---

## 2. Where everything lives (all MERGED to `origin/main`, tip was `0fcec0b`)

### Commits (newest→oldest, the ADR-0032 body)
| Commit | What |
|---|---|
| `9d70b43` | **SSO fix** — Drupal sanitisers use the shared OIDC email hash |
| `694047d` | **Prod guard** — fail-closed scratch-distinct check |
| `3d707f8` | **Flow B** — stack-aware `nwp-server backup` (moodledata) + systemd timer |
| `6101bd8` | Fix: resolve DDEV moodledata host mount for `pl fixture-load` |
| `9dc80eb` | Fix: don't leak `set -euo` from the sourced loader lib (CI `test:unit` hotfix) |
| `3119790` | **Flow A glue** — `pl fixture-load` command |
| `236deea` | Flow A loader core — `lib/moodle-fixture-load.sh` |
| `2d71ac3` | Flow A 2a — wire moodle-full bundle into `server-publish` |
| `61286f7` | **Flow A** — `moodle-full.sh` atomic sanitised-artifact orchestrator |
| `392cc4f` | Fix: pii-gate allowlist `@sanitized.test` |

### Key files on `main`
- `docs/decisions/0032-non-prod-data-refresh-and-file-store.md` — the ADR
- `lib/sanitizers/oidc-email.sh` — shared salt hash; **new** `oidc_email_rewrite_sql`
- `lib/sanitizers/moodle.sh` — Moodle DB sanitiser (scratch-DB; already used the hash)
- `lib/sanitizers/moodle-full.sh` — **new**; composes DB + dataroot scrub + gate → bundle
- `lib/sanitizers/moodle-dataroot.sh` — moodledata omit-and-placeholder scrubber (pre-existing, now wired)
- `lib/sanitizers/standard.sh`, `lib/sanitizers/mayo.sh` — Drupal sanitisers; **SSO fix + prod guard added**
- `lib/sanitizers/ssc.sh` — **new**; ssc resolver → delegates to moodle-full.sh
- `lib/prod-guard.sh` — **new**; `prod_guard_scratch_distinct`
- `lib/pii-gate.sh` — **new** `pii_gate_scan_artifact` (bundle-aware); `@sanitized.test` allowlisted
- `lib/moodle-fixture-load.sh` — **new**; dev/stg loader core (`moodle_fixture_verify_extract`, `moodle_scaffold_empty_dataroot`, `moodle_fixture_load`)
- `scripts/commands/fixture-load.sh` — **new** `pl fixture-load`
- `scripts/commands/server-publish.sh` — bundle-aware (Moodle → `.tar.gz`)
- `scripts/commands/server-backup.sh` — stack-aware (Moodle → moodledata + mysqldump)
- `lib/server-backup-resolve.sh` — **new**; stack detect, moodledata resolve, `sb_moodle_db_dump`
- `scripts/systemd/nwp-server-backup@.{service,timer}` + `.env.example` — **new**; nightly DR timer
- `pairs/ssc.pair-contract.yml` — `shared_salt` boundary now lists standard.sh + mayo.sh as consumers
- Tests: `tests/unit/test-{moodle-full,pii-gate-artifact,moodle-fixture-load,server-backup-resolve,prod-guard}.bats`, additions to `test-oidc-email.bats` and `test-sanitize-dispatch.bats`. **Full unit suite 686/686.**

### Ops issues (all OPEN — nothing closed)
- **ops#114** — ADR-0032 umbrella (has the "fully merged" consolidation + residuals table). **Start here.**
- **ops#110** — ssc sanitiser Path A wiring (code complete, merged)
- **ops#111** — Flow A (built, live-validated, merged)
- **ops#112** — Flow B (built, merged)
- **ops#113** — Prod guards **+ the SSO fix rode on this branch** (see the reviewer note there)
- **ops#115** — Tier 1 validation results (real-MySQL)
- **ops#116** — Tier 2: the critical SSO finding + fix + proof + the Linode-deferral decision

---

## 3. The architecture in one paragraph (so the next conversation gets it)

Two independent flows. **Flow A (dev copy):** on the prod host, `moodle-full.sh` sanitises the DB into a scratch copy (`moodle.sh`), scrubs moodledata **omit-and-placeholder** (`moodle-dataroot.sh` → empty `filedir` + a manifest; **no user file bytes ever copied**), gates it (`pii_gate_scan_artifact`), and publishes a `.tar.gz` bundle `{db.sql.gz, dataroot-manifest}` via `server-publish`. The dev/stg side (`pl fixture-load`) verifies + imports the DB, rebuilds an empty moodledata scaffold locally, and (best-effort) `moosh file-dbcheck` prunes orphaned rows. Because the file scrub is omit-and-placeholder, **moodledata needs no byte transport for dev copies** — that's the key insight that made this tractable. **Flow B (DR backup):** `nwp-server backup` sends **raw** DB + files + **moodledata** to `ver` only (restic), honoring the ADR-0025 "raw→ver only" invariant. Cross-stack SSO is preserved by the **deterministic OIDC email hash** (`oidc-email.sh`, shared salt) — the same real email → the same `<hash>@sanitized.test` on **both** stacks.

---

## 4. Bugs found & fixed this session (all merged)

1. **🔴 CRITICAL — Drupal sanitisers didn't use the shared OIDC hash** (`9d70b43`). Would have broken the SSO join in every sanitised nwc↔ssc dev refresh. Fixed: `standard.sh`/`mayo.sh` now call `oidc_email_rewrite_sql` (conditional on a salt being present; non-paired sites keep positional fallback). **This is the headline result.**
2. **pii-gate rejected every Moodle dump** — `@sanitized.test` wasn't allowlisted (`392cc4f`). Would have failed Gate 2 in production.
3. **DDEV dataroot = container path** — `pl fixture-load`/`server-backup` read `/var/www/moodledata` from config.php; now read the host mount from `.ddev/docker-compose.moodledata.yaml` (`6101bd8`). *Found by the live ssc-dev dry-run.*
4. **`set -euo` leaked from a sourced lib → CI `test:unit` red** — older CI bats doesn't snapshot shell options (`9dc80eb`). *Sourced libs must NOT set shell options — see `pii-gate.sh` as the reference.*
5. **`tar -tzf` returns 0 on a plain `.sql.gz`** — bundle detection now uses the tar entry list, not exit code.

---

## 5. Validation done (and how to reproduce)

### Tier 1 — prod-native suite vs a REAL MySQL (throwaway MariaDB, no Linode)
Proved `moodle.sh` + `moodle-full.sh` + `server-backup` (mysqldump-via-config + restic of moodledata) + round-trip load all work against a real DB. **Zero bugs in the prod-native code.** Live DB untouched (read-only scratch model confirmed). Full write-up in **ops#115**.

### Tier 2a — the SSO round-trip survives sanitisation (data-layer proof, no Linode)
Reproduction script preserved at **`docs/reports/adr-0032-paired-sso-test.sh`** (needs Docker + MariaDB client). It: spins MariaDB, seeds a Drupal DB + Moodle DB with matching real emails, runs `standard.sh` (via a `drush` shim) + `moodle.sh` with the SAME salt, and compares the join key. Result:
```
john.smith@gmail.com → Drupal='c371ea9a0d8aae68@sanitized.test'
                       Moodle='c371ea9a0d8aae68@sanitized.test'  ✅ MATCH
```
Also proved (separate run): `mdl_auth_oauth2_linked_login.uniqid` (the durable OIDC **sub**) is **preserved unchanged**; its `email` is the same cross-stack hash; `confirmtoken` cleared. Neither Drupal sanitiser touches `uuid`; `moodle.sh` doesn't touch `uniqid`. **So the SSO join survives on BOTH keys (sub + email).** Full write-up in **ops#116**.

To re-run the paired proof:
```bash
bash docs/reports/adr-0032-paired-sso-test.sh
```

---

## 6. Conversation-only knowledge (NOT captured elsewhere — the important bit)

These are facts/decisions/gotchas that live only in the session, now recorded here:

- **DEPLOY PREREQ (undocumented elsewhere):** the sanitiser's config.php/drush DB user **must have `CREATE`/`DROP DATABASE`** privilege for the `<db>_sanitize_scratch` scratch DB, or the prod-native sanitisers fail closed at scratch-create. Add this to any real-prod deploy runbook.
- **Testing without prod secrets:** `oidc-email.sh` reads the salt from `.secrets.data.yml` (prod-only). Override for tests with `OIDC_SANITIZER_SALT_FILE=<yaml>` or `OIDC_SANITIZER_SALT=<≥16 bytes>`. `.secrets.data.yml` is absent on dev, so `moodle.sh` had **never run on dev** before this session.
- **`moosh` is NOT in the Moodle DDEV image** — `pl fixture-load`'s orphan-prune step falls back to a hint, so dev copies show "file missing" placeholders until pruned. Consider adding moosh to the image (optional follow-up).
- **The DDEV in-place Drupal path** (`lib/database-router.sh:_sanitize_staging_db_drupal`) is inherently prod-safe (ddev drush hits the container DB) — that's why the prod guard is scratch-distinctness, NOT a hostname refuse (a hostname refuse would break the prod-native sanitisers, which run on prod by design).
- **Design decision — physical Linode deferred to a SUPERVISED session** (see ops#116). The only remaining unique value is a **live browser OAuth login** after sanitisation, which needs OAuth secrets, real-domain DNS, a heavy Open Social+Moodle install, and a browser step that can't be automated. The data-layer proof already validates the sanitiser behaviour. **No Linode was provisioned.**
- **Provisioning primitives mapped** (for the supervised Linode, from an agent survey): `lib/linode.sh` (`create_linode_instance`, `provision_test_linode`, `delete_linode_instance`, `list_test_linodes`/`cleanup_test_linodes` filter on `nwp-test` label), `scripts/commands/test-ver.sh` (disposable multi-box pattern + `assert` no-PAT sweep — reuse for isolation), `servers/nwpcode/linode/*` (linode-cli + StackScript), `pl install <recipe>` (recipes `nwd-dev`/`ssd-dev`), `scripts/f26/nwc-provider-oidc-setup.sh` (Drupal provider OIDC), `lib/moodle-promote.sh:moodle_generate_oidc_apply_script` + `pl moodle config` (Moodle consumer OIDC). DNS is **Linode DNS** (`lib/linode.sh:linode_upsert_dns_a`), NOT Cloudflare. nwd=OIDC provider, ssd=consumer (`ssd/.nwp.yml oauth2.provider_url=https://nwd.nwpcode.org`). Isolation rule: test box holds ONLY `linode.api_token`, NO `.secrets.data.yml`, NO prod keys/PATs.

---

## 7. What remains (all needs a real prod host or supervision — NOT blockers)

1. **Prod-host validation** (ops#111/#112/#115): real-HTTPS `nwp-server publish`, `nwp-server backup` mysqldump/restic on a live Moodle host, and the systemd nightly timer firing. Can't be done from dev.
2. **Supervised Linode live-OAuth test** (ops#116): stand up disposable nwd+ssd, wire OIDC, do one real login → sanitise → reload → login. ~half a day; needs a human at the browser + secret steps. All primitives mapped (§6).
3. **moosh in the Moodle DDEV image** (optional) — auto-prune orphaned `mdl_files`.
4. **Deploy-prereq doc line** — the scratch-DB CREATE/DROP privilege (§6).
5. **Fixture signing** — considered + DEFERRED in the ADR (uncommon industry practice; cheap for NWP but adds a 4th prod key or a per-refresh Solo touch; low priority).

---

## 8. For the next conversation — quickest path to context
1. Read **ops#114** (umbrella) then **ops#116** (the SSO fix + proof + Linode decision).
2. This doc's §6 (conversation-only knowledge) + §7 (residuals).
3. Re-run `docs/reports/adr-0032-paired-sso-test.sh` to see the SSO proof live.
4. The code is all on `main` — grep `lib/sanitizers/`, `lib/prod-guard.sh`, `lib/moodle-fixture-load.sh`, `scripts/commands/{fixture-load,server-publish,server-backup}.sh`.
