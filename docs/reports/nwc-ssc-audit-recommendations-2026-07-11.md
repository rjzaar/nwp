# NWP nwc↔ssc Pilot — Final Synthesis & Decision Doc

*Synthesised from per-finding recommendations + per-branch dispositions. Grounded on the audit at `/home/rob/nwp/docs/reports/nwc-ssc-pilot-audit-2026-07-11.md`. All work stays inside the AI blast radius (dev / stg / live-test / CI) except items explicitly marked **OPERATOR-ONLY** (prod deploy, minisign signing, GitLab token provisioning, sensitive-path merges). Nothing here proposes an AI write to prod; the mons/ver boundary is untouched throughout.*

> **Verification note:** I am the synthesiser working from sub-agent findings that were each verified against live code on origin/main. I did not independently re-run their `grep`/`git` checks. Where a claim is load-bearing and unverified by me, it is flagged **[sub-verified, not re-checked]**. Two items I explicitly could **not** verify are called out in §4. There is no S6 finding in the input set (S6 = email_verified/requireconfirmation is referenced only as a sibling of S7); it is out of scope for this doc.

---

## 1. RECOMMENDATIONS TABLE

| ID | Recommendation (one line) | Priority | Effort | Key reason |
|----|---------------------------|----------|--------|-----------|
| **S1** | Ship BOTH: fail-closed pre-push sensitive-path denylist in `agent-loop.sh` (nwp/nwp, now) **and** remove `agent-eligible` from `TIER_LABELS` so member feedback needs a human promote (nwc profile → live) | **P0** | ~1 day | Member→AI chain feeds attacker text to `claude -p --dangerously-skip-permissions`; the CLAUDE.md auth/secret/CI/live boundary is enforced only by prompt prose today |
| **S2** | Scrub the loop's exec env (`env -i` allowlist) + downscope the admin PAT to an nwp-group **Developer** access-token (api scope); file FS-isolation (bwrap/uid) fast-follow | **P0** | ~0.5 day + FS follow-up | Turns S1 injection from "bad MR a human rejects" into GitLab-admin + root on the forge/artifact host; token+webhook secret currently sit in the injected subprocess env |
| **S3** | Wrapper script `feedback-sync.sh` (PATH + `command -v ddev`), **reinstall** the absent cron line, add `pl loop` freshness check, document the authoritative host | **P0** | ~2–3 hr | Feedback pipeline dead ~7 wks; regular-member concern/safeguarding reports never created; no monitor caught it |
| **S4** | depthcontent stored-XSS: attribute-strip `<details>/<summary>` wrappers + purify body via `format_text`, re-wrap literal tags; add first module test; apply to 3 copies + metabox source | **P1** (P0 the moment content delegation/`addinstance` lands) | ~0.5 day | Only raw-HTML sink; reachability gated today (CLI/teacher-authored) but becomes member-exploitable under P72/P70 |
| **S5** | **Regenerate + commit** `contracts/erasure.command.schema.json`, re-`sums`, re-pin pair contract (AI); operator-sign `.minisig`; phased ops#81 live deploy behind a cross-site erase integration test | **P0** (schema/CI) | Schema ~1 hr; live deploy ~1–2 days | 3 red gates live (validate.py crash, sums bats RED, `pl contracts verify` RED); blocks pair activation; RTBF hole |
| **S7** | OIDC hardening: H1 https-only guard in `verify-nwc-issuer.sh` + HSTS + 2-word docblock fix. **Reject** cert-pin (H2); **drop** H3 (impossible) & H4 (premise false) | **P2** | ~1–2 hr | Design is sound; only need a fail-closed tripwire against silent http:// drift on the one load-bearing assumption (userinfo-over-TLS) |
| **S8** | Harden pair-guard now (yq → **fail-closed**; mark private/ state "advisory"); then sign+activate ops#83 restore-gate **after S5** | **P1** | ~1 day (gated on S5) | yq-absent = fail-open on CI hosts; live coupled restore orphans ssc SSO UID-locks with nothing guarding it |
| **S9** | depthcontent S13 crowd-lock: add `enable_autolock` setting defaulting **OFF** + `sql_like_escape` now; then normalized `vote_key` column + delegated transaction + human/guild promotion gate | **P1** | ~1.5–2.5 days | 3 colluding students auto-promote arbitrary "locked" catechetical content; no human/guild gate; out of nwc-ssc pilot scope but ALPHA-live-bound |
| **S10** | Quiz mastery: re-grade server-side (answer key already in `content_json`); mastery is derived, never client-asserted | **P2** | ~1 day | Forge-to-authority risk once mastery feeds Sojourners leveling → guild tiers |
| **S11** | LegalGate/TheologyGate bootstrap: replace blanket `return TRUE` with permission-scoped bootstrap (admin/uid1 only); two-person review | **P2** | ~2–3 hr | Anonymous floor already fixed; residual = authed member can author legal/consent docs during unseeded window |
| **S12** | GuildClaims: replace `LIKE '%guild%'` with explicit allow-list; keep `accessCheck(FALSE)` | **P2** | <1 hr | Future group/rel type containing "guild" would silently leak memberships across the OIDC boundary |
| **S13-guild** | Seed a real, independent 2nd Shepherd + Copyright mentor before **wider** launch (not the pilot); anti-self-review already engages at n=2 | **P1** | ~0 code; governance hours | uid 1 = sole authority over content+legal+consent; any "guild-reviewed" claim is currently false |
| **ID-TESTS** | 3-rung test ladder: **Rung 0** CI-gate the existing `decide()` script (nwp, ~1 hr) → **Rung 1** observer.php PHPUnit + manual `idnumber==sub` oracle → **Rung 2** full e2e + reconcile-task+SUSPEND + CI-gate 37 nwc suites | **P1** (Rung 0 is a P0-cheap win) | Rung 0 ~1 hr; Rung 1 ~1–2 d; Rung 2 ~4–6 d | The SSO identity core has zero executed tests; its only test runs nowhere; pair-smoke round-trip is a stub |
| **mon-live-health** | Detection-first: awareness-freshness check (stale CVE→RED), per-site HTTP/OIDC probe→RED, schedule pair-smoke; then Gotify push as slice 2 | **P1** | ~2 days | 10-day-stale security signal reads **GREEN**; a live 500/SSO outage reaches RAG through no path |
| **usability** | Defect routing is the pilot gate: fix feedback-sync (=S3), re-point depthcontent "Report a problem" to a human channel, freshness+Gotify alert on safeguarding reports; ship member onboarding doc; then rag-noise + cross-host `pl loop` | **P0** (defect routing / safeguarding) | ~3 days | Under 13+ posture, silently dropping force-routed safeguarding reports is a duty-of-care failure; locked-out testers have no recourse |

### Per-finding rationale (the *why*, and the option not taken)

**S1 — why disable auto-eligibility + denylist, not sandbox-only.** Disabling `agent-eligible` auto-stamping makes project 16 behave like project 21, which the codebase already treats as the deliberate A14 human-promotion boundary — this *removes an inconsistency* rather than inventing policy, so it is low-regret. Sandbox-only was rejected as the S1 fix because it narrows blast radius (that is S2's job) but leaves the routing and the missing pre-push filter intact — attacker text still reaches an autonomous editor with push rights. The denylist is non-negotiable defense-in-depth: even a human-promoted issue carries an injectable body, and `--dangerously-skip-permissions` means moving the boundary from prose into deterministic, fail-closed code is the only real restraint. Half A (nwp/nwp) ships first because it guards every origin including already-promoted issues; Half B only bites once deployed to live nwc.

**S2 — why group Developer token + `env -i`, not a bot user or env-scrub-only.** A GitLab **group** access token (Developer, `api` only) is the exact floor: high enough to open MRs, low enough that protected-`main` + no-admin enforce the human-merge gate for free; it has no login seat, auto-expires, dies with the group, and matches the existing `mons_bot_token`/`ops_note_token` pattern. `env -i`-only was rejected as theatre — the token *also* lives in `~/.nwp-agent-loop.env`, a file the same-uid subprocess can read. A full bot **user** + PAT was rejected: it consumes a seat and grants broader/longer-lived credentials for marginal out-of-scope mayo coverage. **Honest scoping correction (both S2 and the audit under-state this):** `env -i` + token-downscope do **not** neutralise `~/.ssh/gitlab_linode` (NOPASSWD root on the forge box) or `.secrets.yml`, which sit on the same-uid disk readable by the subprocess. Only the filesystem-isolation follow-up (bwrap/dedicated uid) closes the forge-root path — tracked as a distinct P1 issue, not implied-solved.

**S3 — why a wrapper + reinstall + monitor, not a one-line path edit.** Hardcoding `/usr/local/bin/ddev` works on this host but silently rebreaks if the loop's host installs ddev elsewhere; a bare inline `command -v ddev` fails under cron's stripped PATH (which excludes `/usr/local/bin`). The wrapper matches how `agent-loop.sh`/`rag-sync.sh` are already invoked and is the natural home for a heartbeat. **Material correction to the audit:** the feedback-sync line is not merely broken — it is **absent** from the live crontab (removed ~2026-05-22 after it started failing), so fixing `crontab.entry` is necessary but not sufficient; the corrected line must be **reinstalled**. The 7-week invisibility is the real lesson: a path fix without a `pl loop` freshness gate just resets the clock on the next silent death.

**S4 — why attribute-strip + purify, and why P1 not P0.** Passing the whole block through bare `clean_text()` risks HTMLPurifier dropping `<details>` entirely (not in Moodle's default allow-list), silently breaking the disclosure UX the hack exists to preserve; whitelisting `<details>` in the **global** HTMLPurifier config is a disproportionate fleet-wide blast radius for one module. Attribute-stripping the wrapper then purifying the inner body reuses Moodle's trusted cleaner, is module-scoped, and is directly unit-testable. Priority is honestly **P1**: reachability is fully gated today (only `addinstance`-capable teachers/managers and the operator CLI write `content_json`; student `submitfeedback` renders escaped via `s()`), so no member can reach the sink during the supervised pilot. It **snaps back to P0** the moment P72 suggest-edit write-back or P70 learnersourced rendering enables member-authored `content_json`, or any non-operator gets `addinstance`. Because the fix is ~½ day, batch it into pilot hardening now rather than risk it being forgotten when P72 lands.

**S5 — why regenerate-and-commit, not gate-staged.** "Staging" the erasure surface (deleting `schema`/`schema_sha256` from the pair contract) does **not** fix `validate.py` (independent hard-coded erasure CASE still crashes CI), leaves `SHA256SUMS` listing a non-existent file (verify stays RED), *and* drops the wire-shape pin on the single most destructive surface (RTBF hard-delete of real students' PII) exactly as it goes live — strictly more work AND weaker. Reconstructing bytes to match the stale `88955e47` pin is impossible (the file was never committed to any ref; `git log --all` confirms no recoverable bytes) — re-`sums` + re-pin is the sanctioned path. The schema's closed wire-shape is pinned down by three mutually-consistent sources (`erase_guard.php:78-131`, `validate.py`'s good/bad CASE, `ops81-erasure-channel.md`), so regeneration is deterministic. Splitting **sign** into an operator-only phase honours "trust flows through signatures, not machines" (minisign key stays off the AI tier); deferring the live deploy behind a real cross-site integration test + mons/Solo honours "AI never writes to prod" and the D6 `--code-only` UID-lock rule.

**S7 — why only H1 + doc tidy.** The accepted no-JWKS design is sound, so the goal is regression-proofing the one load-bearing assumption (userinfo-over-TLS) cheaply, not adding crypto. H2 cert-pinning is theatre here (co-located hosts, Let's-Encrypt ~60d rotation footgun, no Moodle core hook) and a real login-outage risk. H3 (verify userinfo `sub` == code-exchange `sub`) is **incoherent** — Moodle core never parses the id_token, so there is no second `sub`; implementing it means adopting the very JWKS path the design omits and would break ops#82 hard-swap rotation. H4's premise is **false** — the comments already correctly disclaim JWKS verification (only a 2-word ambiguity at `uid_lock.php:15,56`). Full id_token/JWKS verification is recorded as a **deliberately-deferred** option (feasible; provider already publishes JWKS + signs RS256) that is intentionally not taken because it reintroduces rotation fragility.

**S8 — why harden-then-activate-after-S5, not soft-gate.** The self-attesting `private/` state is acceptable *because* the hardware-Solo deploy gate runs after `pair_guard` and is the actual boundary — rebuilding pair state into a signed store is over-engineering (rejected). The correct fix is to stop over-claiming (mark it advisory) and add the ONE signature check that belongs here (`SHA256SUMS.minisig` verify in `pair_guard`'s paired branch, behind an "if .minisig exists" grace so it no-ops until signed). The yq → fail-closed change is a one-line correctness fix with no downside (off-unless-configured). Activating ops#83 with `NWP_PAIR_GATE_SOFT` to dodge the missing erasure schema was rejected — it silently disarms the very invariant you are turning on. Activation **hard-depends on S5** because turning on `paired_with:` arms `pair_guard`, which fail-closes on the missing pinned erasure schema and would refuse every paired deploy. **Correction to "deploy ops#83":** the restore-gate is already merged and fully wired (`restore.sh:470`, `rollback.sh:253`, 15 bats cases) — it is **inert**, not undeployed; the gap is that the pair is not activated and the local tree is 6 commits behind.

**S9 — why flag-off-now + full hardening, not a one-liner or removal.** Inertness here is a runtime accident (empty tables), not a design guarantee — auto-promotion is one admin "enable" away, and no feature flag exists yet, so *adding one defaulting OFF is itself the primary near-term fix*. The `sql_like_escape` one-liner alone leaves the `why_text` JSON-substring collision, the lost-update race, and the core governance defect (crowd auto-promotion with no human) fully open. Ripping the feature out throws away legitimate advisory signal — Level B already models a reviewer veto, so the fix is to make Level A honour a human/guild gate too. **Scope correction:** depthcontent is only on the `ss`/`ss2` faith-formation Moodle (gitignored, canonical on metabox), **not** on ssc/ssd — so relative to the nwc-ssc pilot this is doubly out of scope; it gates the ss→ssc migration / ADR-0027/P70 roadmap.

**S10/S11/S12 — why fix-all-now-but-keep-P2.** Each is cheap, self-contained, no live exploit today. S10's server-side re-grade is nearly free (answer key already server-side) and deferring risks it being forgotten precisely when mastery starts gating Sojourners leveling → guild tiers → LegalGate/TheologyGate authority. S11's dangerous anonymous case is *already* fixed (H1 floor added post-audit); the residual is an admin-gated authed member in a transient bootstrap window — a **permission-scoped** bootstrap is the right shape because a blanket fail-closed would reintroduce the empty-pool deadlock P68 was designed to avoid. S12 keeps `accessCheck(FALSE)` (legitimate for a system claim-builder); only the substring `LIKE` is wrong.

**S13-guild — why it gates wider launch, not the pilot.** Pilot content is operator-authored, so four-eyes on your own content adds little in a small supervised cohort, and the resolver proceeds (honest `unilateral=TRUE`, audited) rather than deadlocking. The dynamic anti-self-review mechanism is **already shipped and verified** (`EditorialPoolResolver::applySeparation()`); separation auto-engages the instant a 2nd qualifying member exists — zero code work, only real humans. The **hard constraint**: the second member must be a genuinely-trusted, vetted, independent human who accepts the covenant — never a second operator-controlled account, which fakes four-eyes and defeats audit honesty. Order by member-facing reach: Shepherds (legal/consent publish forces re-acceptance on every member) first, then Copyright mentor, then Theology.

**ID-TESTS — why a 3-rung ladder, not a flat "2–3 day e2e."** Rung 0 CI-gates the *already-written* `decide()` test (`auth_nwc` is git-tracked in nwp, no Moodle/DB needed) for ~1 hr — the highest ROI move in the whole audit, which the flat framing buried. Rung 1 tests `observer.php`, the *live* enforcement self-labelled "UNTESTED — draft," plus a documented manual `idnumber==sub` oracle that matches the "small supervised cohort" readiness bar without over-investing. Rung 2 (full e2e, reconcile-task+SUSPEND, CI-gating 37 suites) is correctly P1/broader-launch: OIDC auth-code flows are flaky to script and the SUSPEND assertion is **physically un-passable** until `\auth_nwc\task\reconcile_locks` exists (P1#11). **depthcontent tests are deferred** — it isn't installed on the pilot's Moodles; spending pilot budget there tests code no pilot member touches.

**mon-live-health — why detection-first, Gotify second.** Front-load the cheapest, highest-severity fix: the awareness-freshness age check (~2 hr) which today silently grades 10-day-old CVE data as GREEN and defeats the "Oversight = pl rag" premise. **Correction to the audit:** `cache_stale` is a substring match on composer output, not age-based — the P1#14 threshold "escalate cache_stale beyond 48h" describes a dimension that doesn't exist; an age check must be built from scratch. Detection-into-RAG reuses the proven `rag-auto`→GitLab lifecycle (probes must reach RED via `SEC_CATS`, else outages only hit AMBER). Gotify (ADR-0017-sanctioned, self-hosted, **not** Pushover/Twilio) is slice 2 so detection isn't blocked on infra that may not be stood up; degrade to the existing GitLab-issue path until a Gotify server exists.

**usability — why defect routing is the pilot gate, above the member doc.** The task's real question resolves against the threat model: the feedback pipeline is *provably* dead ~7 weeks, and under the 13+-minors posture it silently swallows **force-routed safeguarding/concern reports** — a duty-of-care failure, so this outranks the member doc (P0 over the audit's "High"). The member doc is cheap and rides the same gate (it's the locked-out tester's only recourse and closes the opaque-SSO-denial gap). rag-noise (0 GREEN buries real regressions among ~19 trivia issues) and `pl loop` host-locality (dev shows "active" for a loop that actually runs on mini) are fast-follow before the cohort grows — during a live pilot they *mask* regressions. Reading mini over Headscale (mini is AI-tier, meshed) is correct; **never** route through mons.

---

## 2. BRANCH DISPOSITIONS

| Branch | What it is | Content status | Disposition | Action |
|--------|-----------|----------------|-------------|--------|
| `origin/ops-nwp-avatars-moodle` | ops#86 Phase-2 Moodle nwp_avatars plugin + child theme (17 net-new files); **new nwc→Moodle WS write endpoint, RISK_PERSONAL**; ALPHA, `--no-verify` | genuinely-unmerged | **needs-operator-decision** | Two-person review of the WS endpoint + access control; phpcs pass + ss-dev smoke test; then `git merge --no-ff`. **Sensitive: new external input handler + personal data.** |
| `origin/chore/gitleaks-allowlist-issue-urls` | 1 commit, `.gitleaks.toml` only: allow public git.nwpcode.org issue/MR URLs | genuinely-unmerged | **merge** | Human merge (leak-scanner config); validate gitleaks parses new `[[rules.allowlists]]` plural form. **Sensitive-adjacent: weakens a leak rule.** |
| `origin/pl-rollback-stdin-fix` | 1 commit, `ssh -n` on 5 rollback preflight calls (stdin fix) | genuinely-unmerged | **rebase-then-merge** | Cherry-pick onto fresh main; small MR flagged as touching prod-write `lib/rollback-remote.sh`; 1 human reviewer. Delete both it and identical `archive/` dup. **Sensitive: prod-write path.** |
| `origin/stg2live-drush-graceful` | 1 commit: `drush --version` guards that **silently skip** password-securing + security-module install when drush absent | genuinely-unmerged | **needs-operator-decision** | Open ops issue (skip-vs-require-drush design Q); two-person security review; stale "line ~1185" comment must be fixed on rebase. **Sensitive: silently skips hardening in a deploy script.** |
| `ops-79` | 5-commit deploy-gate hardening | already-in-main (different SHAs, merge `81bdd41`) | **abandon-delete** | `git branch -D ops-79` |
| `ops-87` | `pl backup sweep` + live-backup freshness signal | already-in-main (merge `fec3eb3`) | **abandon-delete** | `git branch -D ops-87` |
| `ops-78-codium-setup` | VSCodium `pl setup` editor feature | already-in-main (merge `43d3e1d`) | **abandon-delete** | `git branch -D ops-78-codium-setup` |
| `ops-24` | `lib/sanitizers/mayo.allow` (5 published non-PII contacts mirroring `mayo.sh`) | genuinely-unmerged | **merge** | Human sanitizer-path sign-off (entries already match `mayo.sh:404-408`), then merge, close ops#24, delete branch. **Sensitive: `lib/sanitizers/`.** |
| `ops-22` | docs-only nw2 punch-list update | genuinely-unmerged | **merge** | `git merge --no-ff ops-22` (docs-only, clean) |
| `docs/onboarding-getting-started` | README "Get Started" block | already-in-main (`d897887`) | **abandon-delete** | `git branch -D docs/onboarding-getting-started` |
| `feat/nwptoolkit-deploy` | ops#34 AI-authored shared-box deploy script + nginx auth vhost | genuinely-unmerged | **needs-operator-decision** | Two-person review of remote sudo/systemd/nginx heredoc; confirm deploy-from-tree design still current; if approved push + MR (do **not** direct-merge). **Sensitive: server-config + shared-prod-box deploy.** |
| `feat/autolog-mapping-rebased` | stale docs/tooling (verify-autolog + old P65) | already-in-main (`92d4a0e`, `5809030`; P65 superseded) | **abandon-delete** | `git branch -D feat/autolog-mapping-rebased` |

### Needs operator decision (4)
- **`origin/ops-nwp-avatars-moodle`** — new personal-data WS write endpoint; requires two-person review + smoke test before merge.
- **`origin/stg2live-drush-graceful`** — changes two security-hardening functions to *silently skip*; design question (skip vs. make drush a non-dev requirement) is unresolved.
- **`feat/nwptoolkit-deploy`** — AI-authored server-config + shared-box deploy; confirm design is current before pushing to MR.
- **`origin/pl-rollback-stdin-fix`** — trivially safe but touches the prod-write rollback path; needs one human reviewer.

### Sensitive-path merges (route to human, never agent auto-merge)
`ops-24` (`lib/sanitizers/`), `origin/pl-rollback-stdin-fix` + `origin/stg2live-drush-graceful` (prod-write deploy/rollback), `feat/nwptoolkit-deploy` (server config), `origin/ops-nwp-avatars-moodle` (external input handler + personal data), `origin/chore/gitleaks-allowlist-issue-urls` (leak-rule config).

### Exact cleanup commands

**Delete now (already in main, safe, no review):**
```bash
git branch -D ops-79
git branch -D ops-87
git branch -D ops-78-codium-setup
git branch -D docs/onboarding-getting-started
git branch -D feat/autolog-mapping-rebased
git fetch --prune        # clear [gone] tracking refs
```

**Merge after human review:**
```bash
# ops-22 (docs-only, clean)
git merge --no-ff ops-22

# chore/gitleaks-allowlist-issue-urls  → normal merge / MR, human reviewer
# ops-24  → sanitizer-path human sign-off, then merge, close ops#24, delete branch
```

**Rebase-then-MR (prod-write path, 228 behind — do NOT merge the stale branch):**
```bash
git switch -c ops-rollback-stdin-fix origin/main
git cherry-pick 1813994
# open MR "pl rollback: ssh -n to stop preflight eating stdin", 1 human reviewer
# after merge:
git branch -D pl-rollback-stdin-fix archive/pl-rollback-stdin-fix   # drop both dups
```

**Hold for operator decision:** `origin/ops-nwp-avatars-moodle`, `origin/stg2live-drush-graceful`, `feat/nwptoolkit-deploy` — do not delete, do not auto-merge.

---

## 3. SEQUENCED ACTION PLAN

> Dependency spine: **S5 Phase A** unblocks **S8 activation** and clears CI. **S1 Half A** guards every origin and must precede re-arming feedback intake. **S3 feedback-sync** must NOT re-arm member intake until **S1** lands. **ID-TESTS Rung 0** is a ~1 hr P0-value win. **Rung 2 SUSPEND** is blocked on P1#11 (`reconcile_locks`).

### PHASE 0 — P0, do first (mostly AI-safe; two operator gates)

1. **[AI] S1 Half A** — pre-push sensitive-path denylist in `agent-loop.sh` + bats test (nwp/nwp). Ships immediately, guards even already-promoted issues. *(~½ day)*
2. **[AI] S5 Phase A** — author `contracts/erasure.command.schema.json`, `pl contracts sums`, re-pin `pairs/ssc.pair-contract.yml`, run `validate.py` + sums bats + `contracts compat` green; MR via `pl issue work 81`. Clears the 3 red gates + the booby-trapped `contracts:compat` CI job. *(~1 hr)*
3. **[AI] ID-TESTS Rung 0** — CI job running `php scripts/f26/moodle/auth_nwc/tests/uid_lock_logic_test.php`, assert exit 0. Highest ROI in the audit. *(~1 hr)*
4. **[AI] S3 + usability defect-routing** — `feedback-sync.sh` wrapper, **reinstall** the absent cron line, `pl loop` freshness check, document authoritative host (dev). Re-point depthcontent "Report a problem" to a human channel. **Gate: do not re-enable member→loop intake until S1 Half B + S2 land.** *(~1 day combined)*
5. **[OPERATOR] S2** — mint nwp-group Developer token (`api` scope), swap `~/.nwp-agent-loop.env`, `AGENT_LOOP_DRY_RUN=1` verify, re-own `~/.ssh/nwp` to the bot; wrap the `claude -p` call in `env -i` allowlist. *(~½ day; needs GitLab admin)*
6. **[AI, then OPERATOR deploy] S1 Half B** — remove `agent-eligible` from `TIER_LABELS`, fence member body as untrusted in `PROMPT.md` (nwc profile repo); **operator deploys to live nwc**.
7. **[AI] usability member doc** — onboarding doc (register→approve→verify→SSO→course) with an explicit "locked out / hit a bug → contact X" recourse line. *(~½ day)*
8. **[OPERATOR] S5 Phase B (sign)** — `pl contracts sign` → commit `SHA256SUMS.minisig`, at bundle time (needs minisign key). *(~10 min)*

**File a P1 fast-follow ops issue:** S2 filesystem isolation (bwrap/dedicated uid) — the only thing that closes the `~/.ssh/gitlab_linode` forge-root path.

### PHASE 1 — P1 (after Phase 0; several gated on S5)

9. **[AI] S8 harden** — yq → fail-closed in `pair_schema_verify`; mark `private/` state advisory in code/help/docs. *(~½ hr)* Wire `contracts verify` (minisig+checksum) into `pair_guard` behind an "if `.minisig` exists" grace. *(~1–2 hr)* **Needs S5 Phase A+B.**
10. **[AI] ID-TESTS Rung 1** — `observer.php` PHPUnit (two-person, auth surface) + documented manual `idnumber==sub` oracle + reconcile `observer.php` header vs `version.php`. *(~1–2 days)*
11. **[AI] S4** — depthcontent XSS fix + first module test; apply to `ss2/dev` (canonical), `ss/dev`, and metabox source. **Hard prereq before any P72/P70 content delegation.** *(~½ day)*
12. **[AI] S9 Step 1** — `enable_autolock` setting defaulting OFF + `sql_like_escape` one-liner (metabox depthcontent repo). *(~½ day)*
13. **[AI] mon-live-health Slice 1** — resolve authoritative audit host (schedule `pl audit` or rsync met's JSONs); `check_awareness_freshness` (stale→SEC→RED); per-site HTTP/OIDC probe (new `HEALTH` cat→RED); schedule pair-smoke via a flock'd cron wrapper. *(~1 day)*
14. **[AI] usability rag/loop** — reclassify `rag.sh` GREEN to tolerate informational-low todos; make `pl loop` cross-host aware (read mini state read-only over Headscale, never mons). *(~1.5 days)*
15. **[GOVERNANCE / OPERATOR] S13-guild** — seed one real independent Shepherd + one Copyright mentor (covenant acceptance). ~0 code; before **wider** launch. *(governance hours)*
16. **[AI, then OPERATOR] S8 activate + S5 Phase C** — pull local tree current; add `paired_with: nwc`; populate identity ledger + anchors + join-snapshot; build the cross-site erase-propagation integration test; `pl pair-smoke ssc` + `pl pair --restore-check ssc`. **Operator** deploys ops#81 (provider-first, `--code-only`) via mons/ver Solo path + live synthetic-account smoke erase. **Needs ops#83 restore-gate deployed with-or-before ops#81.** *(integration test ~1–2 days; deploy ~½ day)*

### PHASE 2 — P2 (opportunistic; each cheap, none pilot-blocking)

17. **[AI] S10** — server-side quiz re-grade + first phpunit test. **Before** any Sojourners-leveling/certificate wiring. *(~1 day)*
18. **[AI, two-person] S11** — permission-scoped bootstrap in LegalGate + TheologyGate + denial test. *(~2–3 hr)*
19. **[AI] S12** — `LIKE` → allow-list + claims-emission test. *(<1 hr)*
20. **[AI] S7** — https-only guard in `verify-nwc-issuer.sh` + HSTS + 2-word docblock fix. *(~1–2 hr)*
21. **[AI] mon-live-health Slice 2** — `lib/notify.sh` Gotify producer + RED-transition hook (needs a self-hosted Gotify server; else degrade to GitLab-issue path). *(~½–1 day)*
22. **[AI] S9 Step 2** — normalized `vote_key` column + delegated transaction + human/guild promotion gate. **Before S13 serves real students.** *(~1–2 days)*
23. **[AI] ID-TESTS Rung 2** — full DDEV e2e (`idnumber==sub`, `allow_failure:false`); build `\auth_nwc\task\reconcile_locks` (P1#11) **then** the SUSPEND e2e; CI-gate the 37 nwc suites in the nwc repo. *(~4–6 days)*

### Branch cleanup (interleave anytime; AI-safe deletes vs. operator-review merges)
- **AI-safe now:** delete `ops-79`, `ops-87`, `ops-78-codium-setup`, `docs/onboarding-getting-started`, `feat/autolog-mapping-rebased`.
- **Operator/human-review merges:** `ops-22` (docs), `chore/gitleaks-allowlist-issue-urls`, `ops-24` (sanitizer sign-off), `pl-rollback-stdin-fix` (rebase+MR).
- **Operator decisions before any merge:** `ops-nwp-avatars-moodle`, `stg2live-drush-graceful`, `feat/nwptoolkit-deploy`.

---

## 4. OPEN DECISIONS FOR THE OPERATOR

1. **GitLab token provisioning (S2).** *Mint an nwp-group Developer access-token (api scope, 90-day) for the agent-loop and re-own `~/.ssh/nwp` onto it?* **Recommended default: yes.** Trade-off: mayo/mayo falls outside the nwp group, so mayo-routed issues become unroutable (fail-safe: de-eligibilised with a comment) — acceptable for the nwc/ssc pilot. AI cannot and must not perform this.

2. **S2 filesystem isolation.** *Approve the P1 fast-follow to run the `claude` subprocess under bwrap/dedicated uid with no read access to `~/.ssh`, `~/.nwp-agent-loop.env`, `.secrets.yml`?* **Recommended: yes, schedule it** — `env -i` + token-downscope leave `~/.ssh/gitlab_linode` (NOPASSWD root on the forge box) disk-readable; this is the only thing that actually closes the forge-root path.

3. **`stg2live-drush-graceful` design (branch).** *Skip password-securing + security-module install when drush is absent, or make drush a non-dev requirement so it's always present on a full deploy?* **Recommended default: make drush a requirement** (don't silently skip hardening); route the branch through two-person security review either way.

4. **S13-guild second member.** *Who is the real, vetted, independent human who will accept the Shepherd covenant (and separately the Copyright mentor)?* **Recommended default: seed the Shepherd first** (legal/consent publish is the only action that hits every member on next login; a 2nd Shepherd makes every legal approval consent-of-both with zero code). **Hard rule: never a second operator-controlled account.**

5. **Pilot go/no-go framing.** *Is a small, operator-supervised, feedback-intake-disabled cohort acceptable once Phase 0 P0 items land, deferring full e2e (Rung 2) to broader launch?* **Recommended default: yes** — the audit's own readiness verdict supports it, provided S1+S2+S3+S5-Phase-A and ID-TESTS Rung 0 are done and member intake stays gated until S1 Half B deploys.

6. **`feat/nwptoolkit-deploy` (branch).** *Is deploy-from-`~/nwptoolkit` still the chosen design, or was it superseded by the deferred `nwptoolkit-export` CLI?* **Recommended default: confirm current, then push+MR for two-person review**; if superseded, abandon-delete.

### Items I could not verify (flag)
- **Live DB / table-emptiness claims** for S9 (depthcontent vote tables) and S1 "STARVED not firing" — the sub-agents could not query live DBs under the read-only mandate; treat "inert" as *"not currently activated,"* not *"safe by design."* **[not re-checked by synthesiser]**
- **Whether a self-hosted Gotify server actually exists yet** — ADR-0017/0019 sanction it but the sub-agent found *zero* Gotify implementation in `scripts/`/`lib/`. mon-live-health Slice 2 assumes one is stood up; if not, that is a separate infra task and detection (Slice 1) must ship degraded to the GitLab-issue path. **[unresolved]**
- All origin/main code claims are **[sub-verified, not independently re-checked]** by me; the local checkout is 6 commits behind origin/main, so any local-tree action must `git pull` main first (via the tree-sync owner, not in a shared worktree).
---

## Addendum — 3 findings the fan-out couldn't schema-fit (operator-filled from the audit + live ground truth)

**S6 — email_verified=TRUE + Moodle `requireconfirmation=0` email-linking.** *Priority P1 · ~½ day config+audit (+1–2 day durable follow-up).*
**Recommendation:** Set `requireconfirmation=1` on the live ssc OAuth2 issuer (id=1), and on ssd at provisioning; live-verify no *unlinked* privileged Moodle account shares a member email; as a durable follow-up implement the `observer.php` sub-vs-idnumber corroboration so an OIDC login whose email matches an unlinked admin is refused.
**Why:** `email_verified` is hardcoded TRUE (stock simple_oauth; the nwc hook doesn't override it), and Moodle core `auth_oauth2` links a new OIDC login to a pre-existing *unlinked* account by email string when `requireconfirmation=0` — *without* checking `email_verified`. The UUID UID-lock protects already-linked members (Moodle resolves by `idnumber`), so this can only hijack a pre-existing unlinked admin — but that's real. `requireconfirmation=1` is the supported stock lever (no core fork, no upgrade breakage). Chosen over allowed-domain-only (in-domain member could still target an in-domain admin) and over relying on the observer (self-described UNTESTED draft; protects only by the luck of both admins having empty `idnumber`). Risk if ignored: admin-account takeover by email assertion, bounded to unlinked accounts.

**VERSIONING — source↔live drift detector + tag-hygiene recursion + stale tree + FEATURE_BACKUP_MOODLE2.** *Priority P1 · git-pull minutes, drift detector 1–2 days, tag-hygiene ½ day.*
**Recommendation:** (1) `git pull` the local `~/nwp` tree to origin/main (via the tree owner, not a shared worktree) — trivial, fixes the root cause of the audit's blind spots. (2) Add a **signed path→sha256 deploy manifest**, re-verified on a cron, surfacing `DRIFT` into `pl rag`. (3) Recurse `tag-hygiene.sh` into nested `sites/**/version.php`. (4) FEATURE_BACKUP_MOODLE2 is **already resolved** — the depthcontent backup subplugin IS merged (MR !88); the audit's "absent" was the stale-checkout artifact. Just confirm on origin/main and bump the module `version.php` so Moodle sees the change.
**Why:** NWP's load-bearing property is "trust flows through signatures, not machines" — yet nothing verifies deployed code against signed source, breaking that property exactly at the deploy boundary (the OIDC hook + depthcontent both drifted once and were caught only by hand). The signed drift manifest is the highest-value versioning fix. tag-hygiene recursion closes the "one D3 gate blind to its own nested targets" cheaply. Risk if ignored: silent malicious or accidental drift on security-critical code goes undetected.

**PAIR-ACTIVATE — add `paired_with: nwc` to nwp.yml.** *Priority P2 (but a required final gate) · ~30–60 min · gated on S5.*
**Recommendation:** Register ssc as a site and add `paired_with: nwc` to its `nwp.yml` entry as the **final** step before the first live coupled deploy — *after* S5 (erasure schema committed + sums signed) and the ops#83 restore-gate are in place, so `pair_schema_verify` doesn't fail-close every deploy.
**Why:** Activating before S5 fail-closes every nwc/ssc deploy (the missing erasure schema → `pair_schema_verify` RED). Leaving it off through launch leaves the ADR-0031 D6 hazard — a full-DB push to nwc live severing the UID-locked ssc SSO identities — guarded only by operator habit (`--code-only` convention). So it's low-effort but a *required* closing gate, sequenced right after S5 + ops#83 deploy (see Phase 1 step 16). Risk if skipped: `--code-only` / provider-first / red-pair-block stay inert; an accidental full-DB push could sever live SSO identities with no automated block.
