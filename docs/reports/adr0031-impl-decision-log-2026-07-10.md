# NWP-ADR-0031 implementation — decision log (2026-07-10, autonomous)

Operator directive: do items 1–5, max-effort test+fix as I go, research decisions myself + proceed +
log them, then run complete tests on everything testable and fix bugs. Report when finished.

## Hard boundaries (what "working" can and cannot mean here)
- **Buildable + testable by me:** the Moodle sanitizer (synthetic Moodle DB), pair contract + `pair_guard`
  (fixtures/synthetic), Moodle-promotion substrate + OAuth *wiring* code, local drift edits, M1 review.
- **Structurally operator-only (no access / threat model):** actual build-host **tagging + GitLab releases**,
  **deploying to live ssc/ssd**, a **live OIDC round-trip**. These get verified-ready runbooks, not "done."
- Standing rules held: `--code-only` for nwc live; never commit `nwp.yml`; no `sites/tmp/`; `ver` role-vocab
  (gitleaks); no writes to live sites/servers; fail-closed; sanitizer/auth = extra scrutiny.

## Plan (5 items → streams)
1. **M1** (nwc auth) — review the *local* nwc branch `feat/f26-drop-custom-userinfo`, php-l/static-check,
   push → MR → merge to nwc main. Full OIDC round-trip = operator (live). *[me]*
2. **Drift → tags** — local drift edits (plugin version bumps, `format_tabbed` release) where source is
   local; run `pl tag-hygiene`; produce the exact tagging runbook. Actual tag/release = operator. *[agent]*
3. **Moodle sanitizer** — author `moodle_sanitize()` per the interface spec; test against a synthetic
   Moodle DB (throwaway MariaDB, `mdl_*`). *[agent]*
4. **Pair config + contract** — author a real ssc↔nwc / ssd↔nwd pair contract + a bats suite exercising
   every `pair_guard` path; prepare operator activation (real `paired_with`). *[agent]*
5. **OAuth half + Moodle promotion substrate** — settings-writer/vhost/wwwroot-rewrite/Moodle-aware smoke +
   OAuth wiring per F26; test static/synthetic; live enable = operator. *[agent, after 1/4]*

Then: **comprehensive test pass** (all bats/unit, `pl` smoke, sanitizer synthetic run, pair_guard paths) +
fix bugs.

## Decisions (appended as made)
- **D0 (2026-07-10):** use isolated worktrees + subagents (not a full Workflow — no explicit workflow
  opt-in this turn); I coordinate + test + merge. Everything logged here for post-hoc review.
- **D1:** merge policy this run = **merge what passes my tests** (operator authorized "get it all working");
  everything is off-by-default until configured, so merges are behaviour-neutral. Highest-risk live checks
  (OIDC round-trip, real tagging, live deploy) are left as operator runbooks, not merged as "done."

## Results

### Item 1 — M1 (nwc auth) ✅ DONE + verified
- **D2:** the M1 branch `feat/f26-drop-custom-userinfo` was based on a *stale* nwc main (two-dot diff
  falsely showed ~12k deletions). Cherry-picked the single real commit `a09d6bc` onto **current** main —
  **conflict-free**. Merged as **nwc MR !28** (`6ec577c`).
- Fix: deletes the custom `UserInfoController` (hardcoded `email_verified=>TRUE`, unfiltered token lookup)
  + its colliding route; native `simple_oauth` now serves `/oauth/userinfo`; new
  `NwcOidcClaimsServiceProvider` curates the claims allow-list so guild claims still flow.
- **Verified:** php -l clean; hardcoded `email_verified` count = 0; controller deleted; **nwc-dev pulled +
  `drush cr` OK + HTTP 200 + route table now shows `simple_oauth.userinfo: /oauth/userinfo`.**
- **Operator-remaining:** live OIDC round-trip (Moodle → userinfo returns curated claims); mirror the
  `simple_oauth_21` GitHub composer pin before non-dev use.

### Item 2 — drift → tags ✅ DONE (my part) / operator-remaining flagged
- Local main was **10 commits behind origin/main** (MRs !60–63 had merged server-side); fast-forwarded to
  pick up `lib/pair.sh`, `lib/sanitizers/moodle.sh`, `scripts/commands/tag-hygiene.sh`, `pairs/`.
- Ran `pl tag-hygiene`: **13 stray `pre-*` rollback tags** (2 nwp / 11 nwc) to move into `refs/rollback/`,
  and **nwc `composer:0.5.0` has no `v0.5.0` tag**. Both are tag mutations on shared repos + remotes →
  **operator/build-host** (per boundaries + shared-tree rule). Documented in
  `docs/guides/ops74-tag-release-runbook.md`. Linter + confirmed drift state = my deliverable, done.

### Item 4 — pair contract + guard tests ✅ DONE + merged
- Agent authored `pairs/ssc.pair-contract.yml` (nwc→ssc, **identity-coupled**: `uid_lock:true`,
  `coupled_tiers:[live,prod]` → D6 `--code-only` bites; one-writer policy; F26-gated endpoint stubs;
  5-URL smoke set) + `pairs/ssd.pair-contract.yml` (nwd→ssd demo twin, **uncoupled**).
- **`tests/unit/test-pair-guard.bats` — I re-ran it against the real `lib/pair.sh`: 15/15 green**, every
  guard path (unpaired no-op / fail-closed missing contract / red-pair block + override ledger /
  provider-first / cv-ahead refuse / full-DB coupled REFUSE vs `--code-only` PASS / uncoupled-demo PASS /
  record_success). **No `pair_guard` bug** — lib/pair.sh unmodified.
- Additive only (no nwp.yml/deploy-script/pair.sh change); fleet off-by-default → zero behaviour change.
  Contracts parse. gitleaks clean. Merged **nwp MR !64** (`416205e`).
- **Operator-remaining:** add the `paired_with:` keys to `nwp.yml` to activate (documented in
  `pairs/README.md`); no live pair exists yet by design.

### Decisions (continued)
- **D3 (sanitizer = MR-not-merge):** item 3 (Moodle sanitizer body) is the one exception to D1's
  merge-what-passes policy. CLAUDE.md: sanitization code "requires explicit human review — same scrutiny
  as authentication code." So I **build it + test it exhaustively on a synthetic Moodle DB, then hold it
  as a SECURITY-REVIEW MR (pushed, not merged)** for the operator's personal review of the anonymisation
  SQL. Rationale it's safe to leave unmerged: it's fail-closed, and no fleet site is Moodle-canonical, so
  it's behaviourally inert until the operator wires a Moodle pair + runs a promotion **on the prod host**
  (operator/ver-gated) — i.e. the operator is already in the loop before it can ever run.
- **D4 (item 5 in parallel):** the Moodle-promotion **substrate** (settings-writer / vhost / wwwroot-rewrite
  / Moodle-smoke + OAuth wiring) is independent of the sanitizer *body* (different files), so launched
  concurrently with the sanitizer finishing. Scoped OFF lib/sanitizers/moodle.sh + the sanitize dispatch
  to avoid collision. Held as MR (carries OAuth = auth-adjacent).

### Interim verification (already-merged parts, run by me)
- **Full main health after ff:** `bats tests/unit/` = **234/234 pass, 0 fail**; `bash -n` clean on all
  deploy/sanitize/pair libs + commands.
- **Dispatch (`detect_site_stack`):** `nwc→drupal`, `ss→moodle`, `ss2→moodle` (config-driven `.project.type`
  authoritative). **`sanitize_staging_db ss` (Moodle) → fail-closed refuse, exit 1, no DB touched** — the
  load-bearing "no un-sanitized Moodle promotion" property holds; Drupal path unchanged.
- **Pair tooling:** `pl pair list` = clean no-op (0 `paired_with`); `pl pair-smoke ssc --dry-run` resolves
  the contract, lists all 5 smoke URLs, touches no network, exit 0; nonexistent consumer → exit 1
  (fail-closed). `test-pair-guard.bats` 15/15.
- Local main at `416205e` (pair merge); MariaDB (via ss-dev-db container, isolated schema) ready for the
  synthetic sanitizer test.

### Item 3 — Moodle sanitizer ✅ BUILT + tested + hardened, 🔴 HELD as SECURITY MR !65 (per D3)
- Agent replaced the fail-closed stub with a **prod-native** `moodle_sanitize()`: live DB read-only →
  `<db>_sanitize_scratch` → mutate scratch → export; creds via `ABORT_AFTER_CONFIG` php read → 0600 file
  (never argv); `$CFG->prefix` resolved (never `mdl_`); real PII only ever hashed via shared-salt
  `oidc-email.sh` (AVC↔SS OIDC join preserved on email + email-shaped username + `auth_oauth2_linked_login`);
  fail-closed post-condition + pii_sweep; consent (`tool_policy_acceptances`) truncated explicitly, defs kept;
  volatile/log/free-text-attempt tables enumerated (not pattern-matched).
- **My adversarial review + additions:** added a **`$CFG->prefix` charset guard** (`^[A-Za-z0-9_]+$`,
  identifier-injection defense-in-depth) + a bats case for it (commit `b4c21a8`).
- **I re-ran everything independently:** unit bats **8/8** (incl. my guard test); integration synthetic
  **22/22** (real PII gone, OIDC join ×4, consent truncated, tampered-scratch → fail-closed). bash -n +
  gitleaks clean. Scope = only `lib/sanitizers/moodle.sh` + tests; Drupal path + nwp.yml untouched.
- **HELD, not merged** (D3): CLAUDE.md mandates human review of sanitization code. **Operator review points
  on MR !65:** (1) learning-state classification (free-text attempt tables truncated vs numeric aggregates
  kept), (2) `moodledata` file-scrub deferred (needs prod host), (3) dev-side dispatch stub still to wire.
  Behaviourally inert until merged + a Moodle pair configured + a promotion run on the prod host.

### Item 5 — Moodle promotion substrate + OAuth wiring ✅ DONE + merged (MR !66)
- New `lib/moodle-promote.sh` + `pl moodle-promote` / `pl moodle-smoke`: the Moodle analogue of the Drupal
  promotion env-rewrite. config.php writer (tier-aware, 0600, password never on argv, **refuses
  non-dev/stg/test + live-domain + non-Moodle root**), vhost generator (writes a file, never installs),
  wwwroot DB-rewrite **plan** (prints `admin/cli/replace.php`, never runs), Moodle smoke (dry-run default,
  refuses prod), OAuth **descriptors** (consumer issuer-per-tier from the pair contract, native
  `/oauth/userinfo` per F26 M1, `enabled:false`, **no secret value**; provider snippet = operator TODO
  artifact, not committed to nwc).
- **D4 REVISED (after my review):** the OAuth here is descriptor-only / no-secret / `enabled:false` /
  refuses-prod, and every genuinely auth-sensitive step (secret provisioning, `enabled:true`, applying the
  provider snippet on nwc) is an operator TODO **not in this merge**. So it's provably inert plumbing like
  B/C/D were → **merged** (MR !66), not held. The one held item remains the PII-mutating sanitizer (!65).
- Verified by me: **27/27 new bats, 261/0 full suite in-branch**; OAuth path = native userinfo + no secret.
  Additive: no existing deploy path / sanitizer / dispatch / nwp.yml touched; example.nwp.yml gains a
  `moodle.tiers`/`moodle.oauth` schema. Fleet-inert (0 sites have `moodle.tiers`).

## Comprehensive test pass (final merged main `efadc26`)
- **`bats tests/unit/` → 276 passed / 0 failed** (234 base + 15 pair-guard + 27 substrate).
- **`bash -n` → 170/170 shell files clean** across `lib/` + `scripts/commands/`.
- **`pl doc-truth` → SUCCESS** (no new drift; 148 baselined).
- **Dispatch:** `nwc/avc→drupal`, `ss/ss2→moodle` ✓; **`sanitize_staging_db ss` → exit 1 (fail-closed)** —
  no un-sanitized Moodle promotion possible.
- **`pl` smoke (all off-by-default):** `pair list` no-op · `pair-smoke --dry-run` resolves contract, no
  network · `tag-hygiene` reports the 14 findings · `moodle-promote` Drupal no-op / Moodle plan-only ·
  `moodle-smoke --dry-run` no network. Sanitizer (MR !65 branch): unit 8/8 + integration synthetic 22/22.

## Scorecard
| # | Item | State | Ref |
|---|------|-------|-----|
| 1 | M1 nwc auth (drop custom userinfo) | ✅ merged + verified | nwc MR !28 (`6ec577c`) |
| 2 | Drift → tags | ✅ my part done; tagging = operator | `pl tag-hygiene` + ops74 runbook |
| 3 | Moodle sanitizer | ✅ built+tested+hardened, 🔴 **HELD for review** | nwp MR !65 |
| 4 | Pair contract + guard tests | ✅ merged | nwp MR !64 (`416205e`) |
| 5 | Moodle promote substrate + OAuth | ✅ merged | nwp MR !66 (`efadc26`) |

**Everything merged is fleet-inert / off-unless-configured → zero behaviour change on the live fleet.**
Operator actions remaining are all structurally operator-only: review+merge MR !65, cut the tags/releases,
wire a real Moodle pair (`moodle.tiers` + `paired_with`), the live OIDC round-trip.
