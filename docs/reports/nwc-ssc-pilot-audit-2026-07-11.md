Reconciliation complete — and it reshapes several findings. Full report follows.

---

# NWP / nwc ↔ ssc Comprehensive Audit — Final Synthesis

**Scope:** nwc (Drupal/Open Social 13, OIDC provider) ↔ ssc/ssd (Moodle 4.4 consumers), the `pl` fleet tooling, the agent-loop, the NWP-ADR-0031 pair contract, guild governance, and mod_depthcontent.
**Basis:** 7 subsystem maps, 6 dimension audits, 3 red-team passes, operator LIVE ground-truth corrections, plus my own read-only confirmation of the contested facts.

> **Critical methodology note discovered during synthesis:** the local working tree every prior agent audited (`HEAD = 2fc4fa7`, local `main`) is **6 commits behind `origin/main` (`6ec6411`)**. The ops#81 (`ff1d996`) and ops#83 (`ae75696`) merges **are present on `origin/main`** (verified: `lib/pair.sh` on origin/main has 6 `pair_guard_restore` refs; `scripts/f26/nwc-identity-ledger.sh`, `scripts/moodle/local_nwc_erase/`, `scripts/drupal/nwc_moodle_erase/` all exist there). They are **absent from the stale local checkout**, which is why multiple red-team passes wrongly concluded "branch-only / restore ungated on main." **Ground-truth #2 is correct; those red-team claims are discarded.** The stale checkout is itself a finding (see §6).

---

## 1. Executive Summary

Ranked, most important first:

1. **The agent-loop is ARMED, not paused** (no `.loop-paused`, no `~/.config/nwp-loop/parts.state`, cron `0,30 * * * *` live). It is merely *starved* (last issue processed 2026-05-20) because the feedback→GitLab sync is dead on the dev host. This flips several "latent, low-exposure" findings into live-once-fed chains. **This is the single most important correction to the prior "paused" framing.**

2. **The A14 human-promotion boundary is bypassable and prompt-only.** `nwc_feedback` auto-stamps `agent-eligible` on tier-1/2 member feedback and routes it to project 16, which the loop polls; for project 16 the loop *defaults* `kind=nwc-drupal` with no human label required. The member-controlled issue body is fed verbatim to `claude -p --dangerously-skip-permissions`, and there is **no pre-push denylist filter** (the only `git diff --name-only` runs *after* `git push`). The auth/secret/CI/`live*.sh` boundary is enforced solely by prompt prose + human MR review.

3. **Trust-root concentration amplifies #2.** The loop process holds an `api`-scope `GITLAB_TOKEN` (per MEMORY, a full-admin PAT) and `~/.ssh/nwp`; MEMORY records `gitlab_linode` = NOPASSWD root on the forge box. A prompt-injected agent could exfiltrate the token → GitLab admin → root on the code/artifact distribution host. **The mons/prod boundary itself holds** — no prod key exists on this tier — but the forge/CI tier is a very high-value single point.

4. **Stored XSS in mod_depthcontent is real and confirmed.** `depthcontent_render_markdown()` (view.php ~141–164) pulls `<details>…</details>` blocks out *before* `format_text()` sanitizes, then re-inserts them raw. Bounded today (CLI-authored content) but becomes member-exploitable under the NWP-ADR-0027/P70 learnersourced roadmap.

5. **The OIDC identity model is sound as designed.** `sub` **is the Drupal UUID** (operator LIVE-verified; ssc `idnumber` = a real UUID), so the UID-lock survives uid renumber and the "uid-reuse takeover" red-team thread is **false and discarded**. Moodle deliberately does **not** verify the id_token JWKS signature; trust = TLS + confidential client + PKCE + userinfo. This is a defensible, documented trade-off — not a hole — but it leaves no cryptographic backstop below TLS.

6. **ops#81 (erasure) + ops#83 (identity ledger + both-or-forward restore gate) ARE merged to origin/main — but NOT deployed to live ssc/nwc.** That deployment gap is the real open item, not a missing merge.

7. **Two contract artifacts are genuinely missing on real main:** `contracts/erasure.command.schema.json` (only 3 of 4 schemas present) and `contracts/SHA256SUMS.minisig` (unsigned, by design pending operator `pl contracts sign`). The missing schema will hard-fail `validate.py` and `pair_schema_verify` the moment the pair activates.

8. **The pair contract is DORMANT.** No site declares `paired_with:` in `nwp.yml`; ssc isn't even a registered top-level site. So provider-first ordering, `--code-only` UID-lock protection, and red-pair blocking are all **inert** — the D6 hazard is guarded today only by operator convention.

9. **email_verified is unconditionally TRUE** (stock simple_oauth; the nwc hook does not override it). A real hardening gap, but blast radius is **bounded by the UUID UID-lock** (Moodle resolves by `idnumber`, not email). Ranked medium, not critical-takeover. A sharper *adjacent* mechanism — Moodle core auth_oauth2 email-linking with `requireconfirmation=0` — deserves a config check (§3).

10. **Monitoring is entirely pull/on-demand with no live-outage detection and no alerting.** Nothing probes ssc/nwc for 500s, reachability, or SSO health on a timer; a broken site surfaces only when a human runs a command or a member complains.

11. **Test coverage is starkly asymmetric.** The bash/contract tier (pair_guard, schema pins, boundary, sanitizer) is genuinely strong and CI-gated. But the SSO round-trip is never exercised end-to-end, ssc/ssd application code (depthcontent) has zero NWP tests, and the 37 nwc PHPUnit files + narrative Behat run in no CI job.

**Readiness verdict: NOT YET READY for real members on the *paired, governed* footing — but close, and closer than the stale checkout suggests.** The identity core (UUID sub, UID-lock, fail-closed decide()) is trustworthy; ops#81/83 are built. The blockers are operational, not architectural: (a) neutralize the member→agent-loop chain and add a pre-push filter, (b) fix/land the depthcontent XSS before any content delegation, (c) commit the erasure schema + sign the sums and *deploy* ops#81/83, (d) activate the pair (`paired_with`) so the guards stop being convention, (e) restore + monitor the feedback pipeline. A small-cohort, operator-supervised live-test with the loop's member-feedback intake disabled is defensible now; a broader/learnersourced launch is not.

---

## 2. How It All Works (plain language)

### (a) For an ssc / nwc MEMBER

1. **You register on nwc** (`nwc.nwpcode.org`, a Drupal/Open Social site). Registration is gated: an admin approves you and you verify your email. Your account gets a permanent internal ID — a UUID — that becomes your identity everywhere.
2. **You log into the courses on ssc** (`ssc.nwpcode.org`, a Moodle site) by clicking login; Moodle bounces you to nwc to sign in (single sign-on). Behind the scenes nwc vouches for you over an encrypted channel, and Moodle permanently stamps your nwc UUID onto your Moodle account (`idnumber`). From then on Moodle always finds "you" by that UUID — never by email — so even if you change your email, your courses and history stay attached to the right person.
3. **You self-enrol and take a course.** Each learning point is a "depthcontent" activity. You can read it at six depth levels (short → scholar) and your choice is remembered. Videos are external (YouTube) links; question sets appear inline or grouped at the end. As you answer, the app tracks progress (new → learning → review → mastered) and schedules spaced-repetition reviews.
4. **You can give feedback.** On a clip you'll see "Help improve this / Report a problem." Two things to know honestly: today those buttons feed an automatic crowd-vote (a clip can get "locked in" once a few viewers agree) — there is no human reviewing your defect report yet, and the votes don't persist a canonical change. Separately, feedback you file inside nwc *is* meant to become a tracked issue — but that pipeline is currently broken on the main host (see operator notes), so in-app feedback may silently go nowhere until fixed.
5. **What you cannot do:** you can't see other members' private data across sites; your identity is severed at the site boundary for content attribution. Your quiz "mastery" is currently self-reported by your browser (low stakes today, since no certificate is issued).

### (b) For a GUILD member (governance, feedback, legal)

Guilds are in-app Drupal `group` roles with a graded ladder (admin > mentor > endorsed > junior/member, plus verifier/outsider). Who owns what:

- **Copyright Guild** — authors/edits legal + agreement docs, performs copyright clearance (mentor+), and its head pushes a cleared revision to the Shepherds.
- **Shepherds Guild** (machine key `stewards`) — the oversight body; *approves* legal docs → publish, holds the Decision Log and hot-fix authority.
- **Theology Guild** — reviews/approves doctrine-bearing (`core`/`contrast`) content; a higher confirmation tier exists for the most sensitive atoms.
- **Sojourners** — apprentice theology sub-guild, auto-leveled by course completion; members *propose* core edits but do **not** approve them (Theology does).
- **Writers / Pedagogy / Media Guilds** — decisive for prose variants, quiz atoms, and non-doctrinal media respectively.

**The editorial engine** (`nwc_editorial`) is a template-driven state machine. Each change picks a stage path by `change_kind` (typo/legal/doctrinal/…), sometimes refined by atom type (a `core` typo still clears Theology; a `variant` typo doesn't). Every transition goes through **one fail-closed authorizer** (`TransitionAuthorizer::decide()`) that checks: anonymous-can-never-touch-legal, data preconditions, stage-pool eligibility, the graded gates (Legal/Theology/AudienceFit, "forbidden wins"), and logs every allow/deny.

**Anti-self-review** is dynamic: it excludes the author *while a second eligible reviewer exists*; if the pool would go empty it lets the solo operator proceed but stamps the decision `unilateral=TRUE` (sticky, audited). This is honest — but note that today **uid 1 is admin of every guild**, so essentially every publish is currently unilateral until real second members are seeded.

**Legal publishing** (`legal` change-kind, the P68 short path): draft → copyright clearance → Shepherds approval → publish mints a new `data_policy` revision and turns on the login consent gate, so every member re-accepts on next login. P68 is labeled "PROPOSED" but the code is largely **implemented** — treat code, not the proposal header, as ground truth.

**Member feedback → issue** (`nwc_feedback`): members submit a Feedback entity; concern/safeguarding are forced private and force-routed to a human (good). A classifier assigns tiers and *auto-attaches `agent-eligible`* to tier-1/2, then pushes to GitLab. **This auto-labeling is the security concern in §3** — it lets member-originated issues enter the AI loop without a human deliberately promoting them.

### (c) For an OPERATOR

- **`pl rag`** is fleet oversight: per-site Red/Amber/Green, merging a cached security signal (`pl audit` → `private/update-awareness/*.json`) with a work/drift signal (`pl todo`, ~16 checks). It writes `private/rag/state.json` and exits 3 if any site is RED. Current steady state: 2 RED / 19 AMBER / 0 GREEN.
- **`pl status`** renders cached RAG dots + live HTTP/DDEV/disk/DB health on demand. **`pl loop`** is a read-only dashboard of the agent-loop.
- **`pl pair`** surfaces the NWP-ADR-0031 contract status; `pair_guard` is a deploy-time choke-point wired into `stg2live`/`stg2prod`/`live2prod`/`moodle-promote` that (once a pair is configured) enforces provider-first ordering, schema-pin integrity, red-pair blocking, and the `--code-only` UID-lock rule. It runs *before* the per-site hardware Solo deploy gate.
- **The agent-loop** (`scripts/agent-loop/`): rag-sync files/closes `rag-auto` issues daily; once a human promotes an issue to `agent-eligible`, the loop clones into an isolated worktree, runs Claude under a boundary prompt, and opens an MR that **never auto-merges**. A webhook receiver handles merged-MR deploys to the *test tier only* (AI never touches real prod).
- **Backups**: three tiers — dev-side `pl backup`, prod restic DR pulled by the offline hardware-keyed `ver`, and operator forge-box/LUKS-stick crons.
- **The mons/ver boundary is inviolable:** AI's blast radius is dev/stg/live-test + CI. Irreversible prod writes require the offline `ver` desktop + hardware Solo touch.

---

## 3. Security Findings (ranked, deduped, ground-truth applied)

### CRITICAL

**S1 — Member-reachable agent-loop + prompt injection + no pre-push boundary filter (armed).**
Chain, all code-confirmed: `GitLabSyncService.php` auto-adds `agent-eligible` to tier-1/2 feedback and `routeProject()` defaults to project 16; `agent-loop.sh` polls `16,21`; for project 16 the loop **defaults `kind=nwc-drupal`** (no human `kind::` label required, unlike the ops tracker), copies the member-authored issue body verbatim into `PROMPT.md`, and runs `claude -p "$(cat PROMPT.md)" --dangerously-skip-permissions`. `git push` runs **before** the only `git diff --name-only`, so nothing filters a diff touching `lib/auth*`, `*secret*`, `keys/`, `.gitlab-ci.yml`, `lib/sanitizers/*`, or `scripts/commands/live*.sh` — only reviewer diligence at merge. The loop is armed (no pause sentinels; parts default enabled). **Currently starved** because feedback-sync is dead on the dev host (S3), but (a) the injection + no-filter half is exploitable via *any* `agent-eligible` issue regardless of origin, and (b) the member-origination half re-arms the instant the sync is restored on any host.
**Fix:** stop the classifier writing `agent-eligible` (require a human); remove the project-16 `kind` default so unlabeled issues are unroutable; add a hard pre-push denylist check that refuses + strips `agent-eligible` on any boundary-path hit; fence `${description}` as untrusted input.

### HIGH

**S2 — Trust-root concentration (amplifier for S1).** The loop env holds an `api`-scope PAT (MEMORY: full-admin) + `~/.ssh/nwp`; forge-box key = NOPASSWD root. A single leak/exfil = GitLab admin + forge root. Prod stays isolated by mons.
**Fix:** run Claude with a scrubbed env (`env -i` allowlist); downscope the loop to a project-scoped Developer bot token; confine the push key to `agent/*` via a GitLab push rule. (MEMORY already flags downscoping the linchpin PAT.)

**S3 — In-app feedback pipeline dead + unmonitored.** `crontab.entry` runs the sync via `/usr/bin/ddev` but ddev is at `/usr/local/bin/ddev`; `feedback-sync.log` is frozen at 2026-05-22 ending in `not found`. The webhook fast-path isn't running. Concern/safeguarding reports (correctly force-routed to needs-human in code) therefore never get created. No freshness check exists.
**Fix:** correct the ddev path (`command -v ddev`); add a `feedback-sync.log` freshness check into `pl todo`; document the single authoritative host.

**S4 — Stored XSS via depthcontent `<details>` raw re-insertion.** `view.php` extracts `<details ...>...</details>` (the `[^>]*>` open-tag match permits `ontoggle`/`onclick`), runs `format_text` on the rest, then str_replaces the **raw** block back and echoes it. Bounded now (trusted CLI authoring, `addinstance` is RISK_XSS) but directly member-exploitable once NWP-ADR-0027/P70 delegates `content_json`.
**Fix:** don't re-insert raw; run each block through `clean_text()`/`purify_html` whitelisting only `<details>/<summary>` with attributes stripped, or allow those tags via Moodle's format config. Add a test asserting an `onerror`/`ontoggle` handler is stripped.

**S5 — Missing erasure schema + unsigned SHA256SUMS (confirmed on real main).** `contracts/erasure.command.schema.json` is absent yet pinned by `pairs/ssc.pair-contract.yml`, listed in `SHA256SUMS`, and referenced by `validate.py` → `validate.py` **crashes now** (FileNotFoundError) and `pair_schema_verify` fails closed the moment the pair activates. No `SHA256SUMS.minisig` exists, so schema pins are hashed but not signature-anchored at deploy. ops#81's erasure *code* is merged but **not deployed**, so a member erased on nwc still persists on ssc (GDPR retention gap).
**Fix:** commit the schema (regenerate + `pl contracts sign`), or gate the surface as `staged` so verify skips it until deployed; verify the `.minisig` inside `pair_guard`; wire `validate.py` into CI unconditionally; **deploy** ops#81 with an integration test that an nwc erase anonymizes the ssc row.

### MEDIUM

**S6 — email_verified=TRUE + core auth_oauth2 email-linking.** Stock simple_oauth hardcodes `email_verified=true`; the nwc hook doesn't override it. **Per ground truth this is bounded by the UUID UID-lock** (Moodle resolves by `idnumber`) and is ranked medium, not critical-takeover. The sharper adjacent mechanism the red-team surfaced — Moodle core links an OIDC login to a pre-existing *unlinked* account by email string when `requireconfirmation=0` (which the NWP config writers set), *without* checking `email_verified` — is a genuine config concern but requires a pre-existing unlinked privileged Moodle account and is **unverified against live ssc config**. It cannot re-point an *already-linked* member (the UUID lock protects those).
**Fix:** set `requireconfirmation: 1` (or disable email account-linking) on the ssc/ssd issuer; have the observer corroborate the *actual* login `sub` against stored `idnumber` (the current `claims['sub']=$user->idnumber` read-back can only catch an empty idnumber); configure a non-empty allowed-login-domain; add a test that an OIDC login whose email matches an unlinked admin is refused.

**S7 — OIDC no-JWKS trust model (verdict: accepted design, not a hole).** The consumer never verifies the RS256/JWKS signature; identity comes from the bearer userinfo call. Under PKCE(S256) + confidential client + TLS this is defensible and is what makes key rotation a hard-swap. The residual risk is that cross-site identity rests entirely on userinfo-over-TLS + client-secret confidentiality with no crypto fallback.
**Fix (hardening, not a block):** reject non-HTTPS issuer endpoints; consider cert pinning for the userinfo host; verify the userinfo `sub` matches the code-exchange `sub`; correct the residual "verified against JWKS" comments in the released plugin docs.

**S8 — Pair-guard state is self-attesting; `pair_schema_verify` no-ops without yq.** Provider-first `.cv`, RAG, and anchor files under `private/` are written by the deploying actor; the schema check hashes an on-disk file with no signature and **returns 0 (skip) when yq is absent** (`lib/pair.sh`). An actor with dev/live-test blast radius can satisfy every pair invariant. The real backstop remains the downstream Solo gate.
**Fix:** verify `SHA256SUMS.minisig` inside `pair_guard` (fail-closed once signed); make `pair_schema_verify` fail-closed when yq is missing; treat `private/` pair state as advisory only.

**S9 — S13 crowd-lock: unescaped LIKE vote-gaming + non-atomic tally + no provenance.** `maybe_lock_level_a()` builds the distinct-voter LIKE from `chosen_vote_key` (PARAM_TEXT) without `sql_like_escape()`; `%`/`_` become wildcards to inflate/collide the tally. Append+increment+lock aren't transactional. Lock-in promotes a clip into `current_clip_json` on ≥3 votes with no signature/guild review. Inert today (empty table, disposable render target) but activates with S13.
**Fix:** `sql_like_escape()` the key; count from a normalized `vote_key` column; wrap in a transaction; gate lock-in behind human/guild review with recorded provenance before S13 serves real students.

### LOW

**S10 — Client-asserted quiz mastery.** `record_response` trusts client `correct`; `submit_review` trusts client `passed`. Forgeable, low stakes today, but matters if progress ever gates Sojourners auto-leveling or credentials. *Fix:* evaluate server-side from the stored answer key.

**S11 — LegalGate fails open on unseeded guild.** Advisory-TRUE when the guild has no member at the required tier; mitigated because install seeds uid 1 everywhere and registration is admin-gated. *Fix:* fail closed for legal/consent, requiring an explicit admin role in the bootstrap window.

**S12 — Guild-claim over-share.** `GuildClaimsService` matches `type LIKE '%guild%'` with `accessCheck(FALSE)`; any group type containing "guild" is emitted across the boundary. Low direct-auth impact (`guilds` isn't consumed by the lock). *Fix:* explicit allow-list of guild type ids.

**S13 — Single-operator guild concentration.** uid 1 = admin of every guild → every publish unilateral. Honestly audited; compromise of that one account = full content+legal+consent authority. *Fix:* seed real second members before wider launch.

### Discarded per ground truth (do not re-raise)
- `sub` = integer uid / uid-reuse account-takeover after restore / "contradicts the contract" — **FALSE** (`sub` is the Drupal UUID, live-verified).
- "redeploy-from-repo reverts sub to integer" — **FALSE** (the override lives in the deployed profile repo, gitignored from nwp).
- ops#81/83 "branch-only / not merged / restore ungated on main" — **FALSE** (merged to origin/main; artifact of a stale local checkout).
- The "Usability: high / issue:'test' / rec:'test'" entry — a placeholder stub, discarded.

**Genuine strengths (say so):** the OIDC identity core is well-engineered — UUID `sub`, resolve-by-idnumber-never-email, `uid_lock::decide()` a pure fail-closed unit-tested function that DENYs on empty sub. The sanitizer refuses a salt <16 bytes and never echoes it. `pair_guard`'s D6 `--code-only` rule is genuinely fail-closed for both halves. copyright_sync uses `hash_equals` and `htmlspecialchars`-escapes output. The mons/prod boundary is structurally intact across every reviewed surface.

---

## 4. Usability Improvements (ranked, per audience)

**Members**
1. **No member-facing onboarding doc exists anywhere** (register on nwc → get approved → SSO into ssc courses). Every doc is operator/coder/governance-facing. A real-tester pilot went live with zero member docs. *(High.)*
2. **"Report a problem" goes nowhere a human sees.** S13 feeds only an anonymous crowd-vote; route genuine defect reports to a human/GitLab channel distinct from the improvement vote. *(High.)*
3. **SSO denial is opaque** — a failed UID-lock only shows an on-screen error, no cause, no ops signal. A locked-out member has no recourse but to complain.

**Guild members**
4. **P68 proposal header says "PROPOSED" but the feature is built** — reconcile status so guild members trust the in-app authoring surface exists.
5. **Anti-self-review silently collapses to `unilateral`** with one operator; surface this state in the UI so reviewers know four-eyes isn't engaged, and publish the plan to seed second members.

**Operators**
6. **`pl rag` is 0-GREEN steady state** (2 RED / 19 AMBER), diluting signal and keeping a `rag-auto` issue open for nearly every site — alarm fatigue.
7. **Host-local loop state is invisible cross-machine** — `pl loop` reflects only the host it runs on; the dev host reads "loop active" while its webhook + feedback-sync are actually broken. Add a cross-host rollup.
8. **Roadmap contradicts reality** (F26 still "AVC↔SS / PROPOSED" though proven live) — stale status misleads operators and the loop.

---

## 5. Test Coverage — {nwc, ssc, ssd} × {dev, live} × {unit, integration, e2e}

**Explicit answer to "are tests created for both ssc and nwc, both live and dev": NO — coverage is starkly asymmetric, and no tier is "live"-tested.**

| | unit | integration | e2e/behat |
|---|---|---|---|
| **nwc/dev** | Strong (37 PHPUnit) — **but not CI-gated**; `phpunit.xml` registers only 1 of ~10 suites | "Way of Anselm" Behat (13 phases, no phase04) — **not CI** | Rich, operator-run only |
| **nwc/live** | none (AI prod-barred; live-test gets `pl verify` command-exists smoke) | none | none |
| **ssc & ssd (Moodle)** | **Zero NWP-authored app tests.** depthcontent = 0 tests. Every `*behat*.feature` under ssc/ssd is **stock Moodle** | none | none |
| **Cross-site (SSO / pair / erasure)** | Bash/contract unit tier: **genuinely strong + CI-gated** (pair_guard 15 cases, schema-pins, contract-compat, boundary-honesty, oidc-email, moodle-promote config-writer) — but **fixtures/config-strings only** | none | **The nwc→ssc/ssd OIDC login is never exercised end-to-end** |

**What CI actually runs:** `bats tests/unit/`, and for integration **only** `06-scripts-validation.bats` (existence + `bash -n` + `--help`). The real lifecycle bats 01–05 never run in CI. `test:verification` is `allow_failure:true` smoke; both e2e jobs use `|| true`. **No CI job runs phpunit or Behat.**

**Top gaps:**
1. **SSO round-trip untested.** The only SSO test (`uid_lock_logic_test.php`) is a plain-`php` script no harness invokes, covering only pure `decide()` — not `observer.php` (the live enforcement, self-labeled "UNTESTED ON MOODLE — draft"), not a real login.
2. **ssc/ssd application layer (the real-students tier) is the least-tested in the fleet** — depthcontent's 7 tables, 4 WS endpoints, and client-verdict handling have zero tests.
3. **Guild/editorial logic exists but isn't CI-gated**, and the committed `phpunit.xml` runs <10% of it.
4. **Migration framework** (`lib/migrate-schema.sh`, `lib/migrations/*`) has only existence smoke.

**Strength:** the NWP-ADR-0031/P74 bash-contract tier is the best-tested, most security-relevant coverage in the repo and it's fail-closed and CI-enforced. The gap is purely that the application-layer suites that *do* exist aren't automated.

---

## 6. Versioning Integrity + Drift

**Consistent where enforced:** nwp tool `VERSION="0.30.0"` matches tag `v0.30.0`; pair-contract `consumer_min` values match in-tree plugin releases (auth_nwc 1.0.0, local_nwc_copyright_sync 0.2.1). auth_nwc's `version.php` is meticulously D3-annotated.

**Real weaknesses (detection side):**
1. **The local dev checkout is 6 commits behind `origin/main`** — every prior audit ran against a stale tree, which is why they missed ops#81/83. This is a live source-drift finding in itself: the working tree isn't kept synced, and there is no signal for it.
2. **No source↔live drift detector anywhere.** Nothing hashes deployed plugin/module code against repo source. The two historical drifts (a stale 22-line vs 54-line `nwc_oidc_claims.module` on the security-critical OIDC hook; depthcontent) were both caught by hand. This breaks "trust flows through signatures" at the deploy boundary.
3. **`tag-hygiene.sh` covers ~none of the plugins it governs** — it lints only repo-root `version.php`, but auth_nwc/format_tabbed/depthcontent/copyright_sync all live nested under `sites/`. The one D3 gate is effectively blind to its own targets.
4. **`FEATURE_BACKUP_MOODLE2 => true` in all three depthcontent copies with no `backup/moodle2` subplugin present** and `version.php` un-bumped (2026041500 / 1.1.0). The "just added" subplugin is absent from this checkout (canonical source may be on metabox). Native course backup/restore of a depthcontent activity will error or silently omit the `content_json` blob — a plausible ss→ssc migration path.
5. **format_tabbed's D3 `release`/maturity applied to only 1 of 4 working-tree copies** — the exact "empty-release" defect tag-hygiene names, uncaught.
6. **Contract references a nonexistent artifact** — erasure schema hash pinned for a missing file (see S5).

*Fix priority:* commit erasure schema + sign sums; add a signed path→sha256 deploy manifest re-verified on a schedule (surface `DRIFT` into `pl rag`); recurse tag-hygiene into nested `version.php`; resolve or flip `FEATURE_BACKUP_MOODLE2`; **`git pull` the dev tree to origin/main.**

---

## 7. Monitoring + Feedback / Issue Lifecycle

**How problems are (meant to be) detected and routed:**
- **Fleet health:** on-demand `pl rag`/`status`/`todo`/`audit`, refreshed by daily cron. RAG → `rag-auto` GitLab issues (idempotent, auto-closing — a genuinely well-built lifecycle). A human promotes an issue to `agent-eligible`; the loop opens a non-auto-merging MR.
- **Member feedback:** nwc form → Feedback entity → classifier → GitLab issue (concern/safeguarding force-routed to humans) → loop.
- **DR/backups:** three tiers with freshness SSH-checked back into `pl todo` (LBK).

**Blind spots (the important part):**
1. **No live-outage/error/SSO detection in the always-on path.** `rag.sh` has zero HTTP probes; `todo-checks.sh` actively probes only SSL-cert expiry; `pair-smoke.sh` (the one real nwc↔ssc round-trip probe) is scheduled in **no cron**. A 500 on ssc, a down nwc, or a broken login surfaces to no one until a human runs a command.
2. **Security ("R") signal is silently stale** — nothing on this host refreshes `private/update-awareness/*.json` (the daily audit runs on met); staleness only downgrades to AMBER, never fires. A fresh CVE is invisible until a manual re-run.
3. **Feedback pipeline dead + unmonitored** (S3) — the entire in-app support channel silently loses reports.
4. **S13 defect reports reach no human** (§4).
5. **SSO denials are invisible to ops** — dev-only mtrace gated on DEBUG_DEVELOPER; no counter, no alert.
6. **No push/on-call path** despite the threat model favoring self-hosted Gotify.

*Fix:* schedule `pair-smoke` + per-site HTTP probes → feed a todo check so RED transitions drive RAG→RED; escalate `cache_stale` beyond ~48h to RED; wire a Gotify alert; add feedback-sync freshness monitoring.

**Strengths:** safeguarding/concern feedback fails safe to a human; the RAG→issue auto-close lifecycle is low-noise; SSL expiry is genuinely probed; the cron discipline (flock singletons, per-part kill-switches, EXIT-trap-0) is defensively engineered.

---

## 8. Reconciled Red-Team Holes (only those that held up)

| Hole | Verdict | Notes |
|---|---|---|
| Agent-loop **not paused** — armed via cron, no sentinels, parts default enabled | **CONFIRMED** | I verified: no `.loop-paused`, no `parts.state`, state shows last daily 2026-05-20 (starved, not disarmed). Prior "paused" framing is wrong. |
| A14 bypass: member feedback auto-`agent-eligible` → project 16 → default `kind=nwc-drupal` → auto-processed | **CONFIRMED** | Answers the open question YES; project 16 (unlike ops tracker 21) needs no `kind::` label. |
| Prompt injection + **no pre-push denylist** (`git push` before the only `diff`) | **CONFIRMED** | Boundary is prompt-prose + human review only. |
| Stored XSS via depthcontent `<details>` raw re-insertion | **CONFIRMED** | Bounded until content delegation. |
| Missing `erasure.command.schema.json` + no `SHA256SUMS.minisig` on real main | **CONFIRMED** | `validate.py` crashes now; fails `pair_schema_verify` on activation. |
| `pair_schema_verify` no-ops when yq absent; pair state self-attesting | **CONFIRMED** | Downstream Solo gate is the real backstop. |
| S13 unescaped LIKE vote-gaming; client-asserted mastery; guild-claim over-share; LegalGate fail-open; single-operator unilateral | **CONFIRMED** | Ranked Medium/Low as above. |
| **email_verified=true** enables takeover — barrier is a truthful email_verified | **OVERSTATED → reconciled** | Ground truth: bounded by UUID lock, ranked **medium**. The real config lever is `requireconfirmation=0` (needs live verification), not email_verified. |
| No crypto backstop below TLS / "forged id_token → spoofing" | **CONFIRMED but reframed** | A forged id_token is inert (never parsed); risk is strictly userinfo-over-TLS + client secret. Accepted design; harden, don't block. |
| `sub`=integer uid / uid-reuse takeover / redeploy reverts sub | **FALSE — DISCARDED** | `sub` is the Drupal UUID (live-verified); override is in the deployed profile repo. |
| ops#83 restore-gate "not on main" / restore ungated | **FALSE — DISCARDED** | Merged to origin/main; the red-team saw a stale local checkout. Real gap = **not deployed to live**. |
| "Usability" finding `issue:'test'` | **FALSE — DISCARDED** | Placeholder stub. |

---

## 9. What Still Needs To Be Done

### P0 — blocks real members / security-critical

1. **Neutralize the member→agent-loop chain (S1).** Stop the classifier auto-writing `agent-eligible`; require human promotion; remove the project-16 `kind` default. *Effort: ~half day (code + test).*
2. **Add a hard pre-push boundary filter to `agent-loop.sh` (S1).** `git diff --name-only` against the sensitive-path denylist *before* `git push`; refuse + strip label + AGENT-NOTE on any hit. Fence `${description}` as untrusted. *Effort: ~half day.*
3. **Scrub the loop's execution env + downscope the token (S2).** `env -i` allowlist for the Claude subprocess; replace the admin PAT with a project-scoped Developer bot token; push-rule confine `~/.ssh/nwp` to `agent/*`. *Effort: 1 day.*
4. **Fix the depthcontent `<details>` XSS before any content delegation (S4).** Purify each block; add a stripping test. *Effort: ~half day.* **Do not enable learnersourced/`suggest-edit` content until done.**
5. **Commit `erasure.command.schema.json` + `pl contracts sign` the sums (S5).** Or mark the surface `staged`. Wire `validate.py` into CI unconditionally. *Effort: 2–4 hrs.*
6. **Deploy ops#81 + ops#83 to live ssc/nwc, and pull the dev tree to origin/main (§6).** The code is merged; the risk is the deployment/checkout gap. Add the erase-propagation integration test. *Effort: 1 day incl. verification.*
7. **Set `requireconfirmation: 1` (or disable email account-linking) on the ssc/ssd issuer + verify live config (S6).** Confirm no unlinked privileged Moodle accounts share member emails. *Effort: config + audit, ~half day.*
8. **Restore + monitor the feedback pipeline (S3).** Fix the ddev path; add log-freshness to `pl todo`; confirm the authoritative host. *Effort: 2 hrs.*

### P1 — should do soon

9. **Add a scheduled live-health probe** (`pair-smoke` + per-site HTTP) feeding RAG, and a Gotify alert on RED transitions (§7). *Effort: 1 day.*
10. **Add a source↔live drift detector** (signed deploy manifest re-verified on cron → `DRIFT` in `pl rag`) (§6). *Effort: 1–2 days.*
11. **Build the reconcile task + implement observer sub-vs-idnumber corroboration** so deleted nwc accounts suspend Moodle rows and wrong-row links are caught (S6). *Effort: 1–2 days.*
12. **Add an end-to-end SSO integration test** (scripted DDEV nwc→ssc, assert `idnumber==sub`, plus deleted-account SUSPEND) and a `observer.php` PHPUnit test (§5). *Effort: 2–3 days.*
13. **CI-gate the nwc PHPUnit suite** (register all module dirs in `phpunit.xml`; add a Drupal-DB job) and schedule the narrative Behat pre-tag (§5). *Effort: 2 days.*
14. **Escalate stale security signal to RED beyond ~48h + schedule `pl audit`** on the rag-sync host (§7). *Effort: half day.*
15. **Resolve `FEATURE_BACKUP_MOODLE2` (§6)** — implement the subplugin + bump version, or flip the flag false; add a CI check. *Effort: half day–1 day.*
16. **Seed real second guild members** so anti-self-review engages before wider launch (S13). *Effort: operator/governance.*

### P2 — improvement

17. **Write the member-facing onboarding doc** (register → approve → SSO → courses) (§4). *Effort: half day.*
18. **Activate the pair** (`paired_with` in `nwp.yml`, register ssc) *after* P0#5–6, so `pair_guard` stops being convention (§3/§8). *Effort: config + smoke.*
19. **Harden S13** (escape LIKE, normalized vote column, transaction, human gate on lock-in) before S13 goes live (S9). *Effort: 1 day.*
20. **Server-side quiz correctness** (S10); **explicit guild-type allow-list** (S12); **fail-closed LegalGate bootstrap** (S11). *Effort: small each.*
21. **Recurse `tag-hygiene` into nested plugins; reconcile format_tabbed copies; delete retired avc_copyright_sync trees** (§6). *Effort: half day.*
22. **Reconcile doc status** (P68, F26 roadmap) and consider extending `doc-truth` to status drift (§4/§6). *Effort: small.*

---

### Bottom line
The architecture is fundamentally sound and, once the dev checkout is synced to origin/main, considerably more complete than the audited snapshot implied (ops#81/83 are done, the UUID identity model is proven). The remaining blockers are operational and concentrated: **stop member input from reaching an armed, over-privileged AI loop; kill the stored XSS before content delegation; finish and deploy the erasure/restore machinery; and give the fleet real live-health monitoring.** None require re-architecting the trust model — the mons/prod boundary, the UUID UID-lock, and the fail-closed contract tier are the parts worth keeping exactly as they are.