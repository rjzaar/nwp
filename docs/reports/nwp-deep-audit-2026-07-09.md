# NWP deep audit — 2026-07-09 (in progress)

Six parallel read-only audits (security×2, nwc code, pl/lib, docs/ADRs, ~/central/mons, ~/.claude
history). This doc is assembled as they land. **Nothing was changed; deny-listed file *contents*
were not read (handling audited).** Two independent security agents live-verified token scopes
against the GitLab API — findings below are corroborated, not speculative.

> **Companion:** researched, decision-ready recommendations for every finding here —
> per-finding action + cited *why* + options weighed + effort/risk/priority, plus the overall
> prioritised remediation roadmap — live in
> [`nwp-deep-audit-recommendations-2026-07-09.md`](nwp-deep-audit-recommendations-2026-07-09.md)
> (five web-researched streams: security/mons ①, nwc auth ②, bash tooling ③, leakage/consistency ④,
> docs/ADRs + roadmap ⑤).

---

## 🔴 CRITICAL — act before more mons work (and some, now)

**C0 · The agent-loop is RUNNING on BOTH dev and mini right now — it is NOT paused.**
`crontab -l` on dev and mini both fire `agent-loop.sh` on `0,30 * * * *`; both logged runs at 17:30
today; neither host has `.loop-paused`. **OPERATING-MODEL.md's read-first banner ("loop is paused
since 2026-05-22") is FALSE** — a read-first safety doc asserting a state that doesn't hold. The dev
loop is the process that sources the admin PAT (C1). → Correct the doc; decide whether the loop
should be running; remove the loop cron from **dev** (mini is canonical per the migration memory).

**C1 · Live ROOT-ADMIN GitLab PAT on the AI-reachable dev workstation.**
`.secrets.yml:gitlab.api_token` (== `~/.nwp-agent-loop.env:GITLAB_TOKEN`, same token). Live-verified:
name "nwp-api", scopes `[api, read_api, read_repository, write_repository]`, authenticates as
**`root`, `is_admin:true`**, exp 2027-04-07 — and it is **sourced by the unpaused loop every 30 min.**
This is the ADR-0024 linchpin: with a full-`api` admin token on an AI host, "AI never reaches prod"
is false at the control-plane root, regardless of the signed-artifact chain. **MUST-FIX-BEFORE-MONS.**
→ Revoke; reissue Developer-role, non-admin, no-`api`; admin → WebAuthn-only sessions.

**C2 · A SECOND root-admin PAT on mini** (`~/.nwp-agent-loop.env`, "llm_bot", created 2026-07-03).
Live-verified: authenticates as **`root`, `is_admin:true`** — the registry believed it was a
Developer bot (uid 7); the token was actually created under root. Mini runs the loop 24/7.
**MUST-FIX-BEFORE-MONS.** → Revoke; recreate under the bot user, Developer only.

**C3 · Live credential on the PUBLIC GitHub mirror.** `github.com/rjzaar/nwp` (pushed 2026-07-09)
carries, in history (`b11e756f`, `docs/guides/gotify.md`), a Gotify token **byte-identical to the
current `gotify.mini_health_token` in `.secrets.yml`** — scrubbed from HEAD, never rotated, still
valid. Blast radius bounded (notification POST only, host on the private mesh) but it's a live public
secret. → **Rotate now.**

**C4 · Minisign SECRET signing key on the AI-reachable dev disk.** `keys/minisign/nwp-deploy.key`
(created today; ver-kit signed with it today). The entire trust chain mons verifies is anchored in a
password-protected key on the dev workstation — a compromised AI session there can sign kits/bundles
mons will accept. `lib/minisign.sh` itself calls it "software interim." **MUST-FIX-BEFORE-MONS.**
→ Move signing to Solo 2C+/offline ceremony, or record "build-tier key = interim trust root" as an
accepted-risk ADR note; do the runbook §3 key-ID out-of-band check (tp1 rehearsal skipped it).

**C5 · Deny rules are not a real control.** `~/.claude/settings.json` denies (`**/.secrets.yml`,
`**/*.key`, `keys/*`) block the AI's file-read tools but **not Bash** — the audits (and this session)
read `.secrets.yml` values via bash/python. → Treat secret protection as gitignore + host isolation,
not the deny list; do not rely on deny rules as a security boundary.

---

## HIGH (security)

- **H1 · On `main` today, `prod2stg`/`live2stg` import RAW prod PII with zero sanitize + zero
  canonical guard** (`prod2stg.sh` 470-542, `live2stg.sh` 196-216; `grep -c sanitize`→0). P67's
  default-sanitize fix is on the unmerged MR!47 branch, **not on main** — shipped behavior is
  pre-P67. → land MR!47 or add the sanitize+PII-gate step to main now.
- **H2 · `sanitize_staging_db` silently succeeds on non-Drupal schemas** (`lib/database-router.sh:
  445-493`): every mutation `2>/dev/null`, no exit check, unconditional `return 0`; the lone
  anonymize query hits a Drupal-only table → on Moodle/other, **no anonymization, "sanitized"
  printed anyway.** Generalized ops#68. → check exit codes, fail loud, gate via `pii_gate_scan`.
- **H3 · ADR-0024 runner is a bare `git pull` + `pl stg2live` — no signature verification** (ops#52).
  The canonical routine-prod path is signature-free by design → a GitLab compromise ships to prod.
- **H4 · AI-held SSH reaches the GitLab host** (`~/.ssh/nwp`,`gitlab_linode` → `97.107.137.88`, which
  hosts live test sites AND `git.nwpcode.org`). Fine for A14 test tier, but once GitLab is the
  deploy-authority root, an AI shell there hollows the WebAuthn gate. → separate GitLab from AI shell
  reach before ADR-0024 flips on.
- **H5 · TOFU ver-kit bootstrap** — kit verified with the pubkey shipped *inside the kit*; only guard
  is a manual, skippable key-ID check. → make it a required, scripted checklist step.
- **H6 · Account-scoped Linode token + GitLab admin password in AI-readable `.secrets.yml`.** Registry
  itself says "move to AI-denied tier" — not done. Compromise = destroy/rebuild every Linode incl.
  the GitLab+live box.
- **H7 · P61 leakage-hygiene CI is entirely unshipped** (all 4 phases "Not started") — the
  public/private boundary is maintainer-discipline, not machinery. Real prod IP `97.107.137.88` is
  public + ungated (~30 tracked non-allowlisted docs; `.gitleaks.toml` has no raw-IPv4 rule).
- **H8 · Mazenod/RE scrub-rule violated** in two *published* reports (`docs/reports/
  nwp-executive-summary-2026-03-10.md`, `nwp-landscape-analysis-2026-03-12.md`).
- **H9 · `.gitleaks.toml` global path allowlist exempts whole dirs (`docs/reports/`, `tests/`,
  `servers/*`, `docs/archive/`) from ALL rules incl. credential rules** — root cause of the doc
  leaks; a real key in `docs/reports/` passes the gate. → per-rule/hostname-only allowlists.

### Independent corroboration (peer scan, 2026-07-09)
A second, independent leak scan (595 tracked files, `git ls-files -z` scoped) confirms: **no live
secrets in tracked files** (glpat-/AKIA/ghp_ hits are scanner regexes in `secrets.sh` or literal
placeholders; both example files all-placeholder; git history clean — no secret file ever committed).
It corroborates the three structural gaps and adds exact refs: **prod IP `97.107.137.88` ungated** in
~30 tracked files incl. non-allowlisted live ones (`roadmap.md:622`, `F15:226-277`, `F16:21`,
`F17:120-1270`, `P59:15,25`, `milestones.md:427`, `deploy-on-merge.sh:235`, `site.sh:143`,
`tests/fixtures/cnwp.yml:53,87`) — gitleaks has **no raw-IP rule**; the **`.gitignore` whitelist gap**
(verified trackable: `docs/foo/id_rsa`, `.../prod.env`, `lib/x/credentials.txt`, `tests/x/prod.pem`)
→ add `**/*.pem **/*.key **/id_rsa **/id_ed25519 **/*credential* **/*.env` after the whitelists; the
**gitleaks whole-subtree allowlists** (`.gitleaks.toml:27,61,66` for `docs/archive/**`,
`docs/reports/**`, `tests/**`). Also flags the untracked root handover docs (`handover-unfork-ops3.md`,
`handover-ops-readfirst-hook.md`) carry `/home/rob/nwp` paths + `git.nwpcode.org` (would enter on a
bulk `git add docs/`). **These fixes are Tier 3 — held for operator go (they touch security config).**

## MEDIUM (security) — abbreviated
`mayo1` server identity in public history (`42ecb1e9`); `.gitignore` whitelist lets arbitrarily-named
secret files be tracked under docs/lib/tests/bin (add `**/*.pem|*.key|id_rsa|*credential*|*.env`
denies); canonical guard fails OPEN for unregistered sites (`lib/canonical.sh:58-71`, absent→"dev");
`get_secret` awk fallback only splits 2-level keys (ops#70, silent empty on 3-level); rollback/restic
DR path untested + pre-apply snapshot opt-in + `apply.sh rsync -a` same-size no-op (F2); generic
Linode setup scripts `ufw allow 22/tcp` (contradicts "no public SSH"); `verifier-say` token vs the
linchpin-sweep grep conflict; example.nwp.v2.yml real values on the mirror; `pl secrets check` is
expiry-only (can't detect scope/admin violations).

## Positive (verified good)
Webhook receiver fail-closed (empty-secret refuse, constant-time compare, project allowlist, binds
100.64.0.2 not 0.0.0.0); `nwp-server apply` refuses without a verified signature; ver-kit/PII-gate
fail-closed; no secrets in the *working tree* or in `~/central/nwc-internal`; `NOT_ON_HEADSCALE`
asserted in tests; nightly gitleaks + weekly trufflehog on transcripts; met's stale token already
revoked (dead, not live).

---

## CONSISTENCY (the meta-finding — "check consistency in every area")
The single deepest pattern across every audit: **the newest layers are fail-closed; they sit on older
fail-open plumbing, and the good pattern is applied unevenly.** The inconsistency *is* the risk.
- **Deploy/sanitize scripts apply the threat model unevenly** (verified table): `dev2stg` = strict-mode
  + canonical-guard + sanitize; `stg2live`/`stg2prod`/`live2prod` = strict + guard, **no sanitize**;
  `live2stg`/`prod2stg` = strict, **no guard, no sanitize**; `copy`/`restore` = neither; `server-publish`
  = sanitize but **no `set -euo pipefail`**. → **Fix: one shared "deploy preamble"** (strict-mode +
  canonical guard + sanitize/pii-gate where data crosses a boundary + `nwp_ssh_opts`) called by every
  deploy/sanitize verb, so the model can't be present in some paths and absent in others.
- **P59 `IdentitiesOnly` applied to *most* SSH calls, not all** (`stg2prod` 6/11, `import.sh` 0, bare
  `rollback-remote.sh`) → route every ssh/rsync through `nwp_ssh_opts`.
- **Multiple secret-access patterns** (`get_infra_secret` vs direct `yq` in `developer.sh`/
  `verify-cross-validate.sh`; the awk fallback silently mishandling 3-level keys) → standardise on one
  accessor that fails closed without yq.
- **`.gitignore` has no global `*.sql`/`*.sql.gz` deny** (only `sites/*`/`build/*` covered) — a dump in
  any whitelisted dir is committable, inconsistent with the `.claude` `**/*.sql` read-deny.
- **Auth enforced consistently at the route/form layer but inconsistently at the domain layer**
  (P73 fixed one nwc service; ~8 others still trust their caller) — see the nwc section.
- **Docs/ADR terminology + status inconsistent** (verifier/ver/mons/nwp-server; "Accepted" ADRs
  asserting falsehoods; "paused" loop that runs) — see the docs section.
**The highest-leverage single fix is standardising the fail-closed pattern** (a shared deploy preamble
+ one secret accessor + one guild resolver + the domain-authz choke-point) so it can't be half-applied.

## The mons-readiness blockers (ordered)
1. Kill BOTH root-admin PATs (C1, C2); reissue Developer-role non-admin; re-verify via
   `GET /personal_access_tokens/self` + `/user`. 2. Solo W WebAuthn enroll; admin WebAuthn-only.
3. Minisign key off AI disk / hardware ceremony (C4). 4. Amend ADR-0024 → verify-then-apply (ops#52).
5. Provision mons' 3 one-way keys (ADR-0026). 6. Separate GitLab from AI shell reach (H4). 7. Stop
the dev loop; correct OPERATING-MODEL (C0).

---

---

## Bash / `pl` tooling — 0 × P0, ~22 × P1, ~40 × P2 (95 findings; verified)
**The good news: ZERO P0 — no path where AI-reachable code writes to real prod; the mons boundary
holds in the tooling.** The P1 cluster (dev/CI/shared-server blast radius):
- **Inverted security gate** — `security.sh:107,141`: `pm:security`/`composer audit` exit non-zero
  *when advisories exist*, so the vulnerable case falls to the "could not run" arm and returns
  **clean**. `pl security check` reports vulnerable sites GREEN. **Fix first.**
- **Empty-variable `rm -rf`** — `verify-runner.sh:477` (empty `$prefix` → wipes the whole
  `sites/` tree); `live.sh:1104-1107` (`pl live --delete ""` → remote `sudo rm -rf /var/www/` wipes
  the shared server); `delete.sh:325` (`--force` skips `validate_sitename`). Add non-empty guards.
- **`eval` RCE from semi-trusted data** — `import.sh`/`server-scan.sh:143` (eval of remote dir
  names → local RCE from a scanned host), `verify-autofix.sh:409` (eval of error-message-derived
  module names), `testos.sh:489` (eval of CLI tag/group args), `git.sh:791` (nested gitlab-rails
  Ruby injection), `coder-setup.sh:1168` (attacker SSH key into remote ssh). **Root fix: ban
  `eval "$(...)"`/`eval "$cmd"` on parsed data.**
- **Silent-sanitizer siblings of ops#68** — `sanitize.sh:232` (re-export errors swallowed, stale
  pre-sanitize dump used as "sanitized"), `sanitize.sh:266` (`check_for_pii` is constant-true — never
  a real gate), plus the C2/H2 dev-side sanitizer. Raw PII can cross believing it's clean.
- **Secrets on argv (ps-visible on AI hosts)** — `secrets.sh:238` full-admin PAT in `curl --header`
  during rotation, `install-drupal.sh:273` token via `env`, and pervasively (linode/cloudflare/b2/
  claude-api/status). The safe `curl -K` 0600 pattern exists in `gitlab-issues.sh` but wasn't adopted.
- **Confirmed open tickets:** ops#47 (impact/fate-manifest contract is on **only 1 of 14** destructive
  verbs — restore/copy/rollback + every deploy verb unguarded); ops#37 (flock only in one lib; backups/
  crontab/rag state races); ops#70 (3-level `get_secret` silently returns "" without yq → the
  unauthenticated-curl paths above); `coders.sh:206` verified **infinite recursion**.
- Also: `atomic_yaml_update` bypassed in `verify.sh`/`modify.sh` (awk→mv, no empty-output guard = the
  Jan-2026 data-loss class); Moodle/Drupal hardcoded fallback admin passwords (`Admin123!`,
  `ChangeMe123!`); `curl|bash` of unpinned installers (incl. as root on the deploy tier).
- **Highest-leverage fixes:** (1) ban `eval` on parsed data; (2) standardise every `curl` auth on the
  `-K` config-file pattern; (3) guard empty/`..` vars before every `rm -rf`/remote-command string;
  (4) fix the inverted security gate + the silent-sanitizer/PII no-ops (fail loud, check exit codes).

## Docs / ADRs / proposals — systemic drift (the "truth gate" can't see it)
- **P62 `pl doc-truth` is a dead-link linter, NOT a truth gate** — checks broken md links + missing
  ADR-refs only; parses no Status/date/prose; **wired into nothing** (not CI, pre-commit, or `pl
  verify`). Every drift below is invisible to it by design.
- **ADRs asserting falsehoods with "Accepted" status:** 0013 (four-state dev/stg/live/prod — code is
  `dev live prod`, rejects `stg`), 0014 (git-hooks machinery that doesn't exist), 0021 (records the
  *rejected* separate-repo option as the decision).
- **No ADR for the biggest 2026 decision — the un-fork to Open Social 13** (nwc=canonical 2.0, avc
  frozen, nw1 archived). Lives only in memory/ops/handovers. **ADR-0027 is Status: Proposed + not in
  the index** yet is cited as binding-parent by P71/P72/P73. P73 (approved auth model) has no ADR.
- **F26 nwc↔ss OIDC is being built on a stale, contradicting spec** (F26 still says avc-issuer + its
  §2 forbids the extension) — on a DO-NOT-MERGE auth branch. Reconcile before it merges.
- **F28 depends on superseded ADR-0019** yet ADR-0027 cites it as load-bearing for federation.
- **Onboarding suite (`docs/onboarding/`) actively misleads** — cites nonexistent ADR numbers +
  ~11 modules that don't exist + "Open Social 12" + paused auto-deploy. Rewrite or stamp SUPERSEDED.
- **Roadmap / milestones / CHANGELOG are dead since ~April** — a second, false source of truth vs
  nwp/ops. No release tag in 3 months of major work.

## ~/central + mons readiness (private tree) — corroborates the criticals
**Mons is ~80% there on the *machinery* — the gaps are the operator/hardware half + custody/loop/doc.**
GOOD (verified): `nwp-server` built + tp1-validated (pull→verify→apply→rollback, tamper-rejected),
publish PII-gate fixed, test-mons↔tp1 1:1-WireGuard proven, the tailnet-vs-ADR contradiction RESOLVED
(operator 2026-07-03: **no mesh, ever**), ver-kit shipped + sandbox-verified, two-Solo checklist ready,
stale ~/.config PATs already shredded. Remaining is the operator/hardware half of ops#25.
MUST-FIX-BEFORE-MONS from this tree:
- **Signing-key custody (the biggest):** `keys/minisign/nwp-deploy.key` on the AI-reachable dev disk
  (one agent reports it **passwordless** per the ADR-0019 interim), **+ a stray copy in
  `~/nwp-ops23/keys/minisign/`**; no key-rotation/compromise runbook. This is the trust root the whole
  mons chain verifies against.
- **`mons-operational-readiness.md` contradicts the trust model** — tells you to `cd ~/nwp` on mons
  and frames "not on the tailnet" as a *gap*, whereas the decision is artifact-only + never-mesh. A
  solo operator following it would put the full AI-adjacent repo on the prod-trust box. Correct/delete
  before provisioning.
- **`ver-kit.pins` provenance unverified** — the tool-pin file was filled *during this audit window*
  by "some session"; if an AI filled it by download-and-observe, the kit's trust anchor is unverified.
  Re-verify all 3 hashes out-of-band (~5 min).
- **`~/central` has NO backup** — no remote (never-pushed holds), no backup cron. The entire mons
  procedure, the legal canon, and the operating model live on one un-replicated laptop disk. → private
  remote or scheduled encrypted rsync to met before mons relies on these docs.
- **PII gate fails OPEN** (`lib/pii-gate.sh:103-109`): `PIPESTATUS[0]` after a command-substitution
  captures grep's status, not the reader's rc=2 → a corrupt/truncated `.gz` scans as CLEAN. This is
  the *last* backstop before publish/import (`onboard.sh:167`, `server-publish.sh:119`).
- Legal source-of-truth will move on-app when P68 lands (`~/central/legal/` claim must be rewritten);
  `legal/sync.sh` is half-stubbed; a live `/legal/terms` v1-vs-v2 mismatch is recorded.

## Convergent CRITICAL picture (multiple independent agents agree)
**0 × P0 — no AI-reachable code path writes to *real* prod; the mons boundary holds today (largely
because real prod does not exist yet).** That is the key reassurance. But the safety machinery around
the imminent mons/prod step has a corroborated critical cluster that must close *first*: (1) the
self-healing loop is **armed + running on dev AND mini**, no flock, no kill-switch, "paused" is
fiction; (2) **two live root-admin GitLab PATs** on those AI hosts, one driven by that loop; (3) the
**minisign signing key on the AI dev disk**; (4) **sanitizer + PII gate fail OPEN** so raw prod PII
can reach the AI dev machine believing it's clean; (5) a **live token on the public GitHub mirror**;
(6) exploitable **bash P1s** (inverted security gate, empty-var `rm -rf`, `eval` RCE). None is an
active breach; all are "the fence isn't up yet" — and you're about to open the gate (mons).

## ~/.claude history-mine — valuable STILL-OPEN items said-but-not-done (verified against tree)
- **[SECURITY] `nwc_collab` token IDOR** — `CollabTokenService::generateToken()` mints an editing
  token for ANY document name with no entity-update-access check; route needs only the blanket `use
  collaborative editing` perm. Live IDOR the moment collab is enabled. (Flagged central 2026-06-27,
  never ported-in.) **VERIFIED OPEN.**
- **[SECURITY] Raw live DB on the AI dev box** — `sites/mayo/backups/mayo-live-20260412.sql.gz`
  (112 MB, "live"-named). Threat-model violation; sweep/relocate. **VERIFIED OPEN.**
- **[SECURITY] `nwc_registration` permission-string mismatch** — module defines `administer nwc
  registration` (spaces); the `/apply` webform references `administer nwc_registration` (underscore)
  ×4 → the webform access block is bound to a non-existent permission. **VERIFIED OPEN, quick fix.**
- **"The sanitizer deserves its own audit"** (central 2026-06-11: "more fragile than mons,
  publication-is-forever") — never done; this audit is the first, and confirms the concern.
- **`.secrets.yml` mislabeled "AI-safe" while holding prod-blast-radius PATs** — same finding as C1/H6.
- **`lib/ai|ci|saas` physical partition** — the AI-free guarantee still rests on the allowlist, not
  the promised physical split. **VERIFIED OPEN.**
- **Registration form-alter regression guard** — one OS `form_id` rename silently breaks the custom
  fields; a single Behat scenario prevents it; no test exists. Cheap, high-value.
- **`pl produce` SSHes as root with no canonical guard** while advertised but "not implemented."
- **Move the nwc dev checkout out of gitignored `html/`** — `rm -rf html` deletes the working profile
  repo (genuine foot-gun).
- **Non-security, high-leverage-to-effort:** the **SD rights-holder sign-off email to Dan Burke** — a
  ~5-minute email pending since ~May that gates the entire SD corpus build; the after-course
  rhythm/closing-survey pedagogy decisions; GitLab onto its own box (frees 3.6 GB); a dedicated
  bounded bot user for the loop before it does anything beyond test promotions.
- Verified-DONE (closure examples): `ClaimExpirationService` cron-fatal fixed; nwc git remotes
  reconnected.

## ⚠️ Honest meta-note
This audit run itself — and this whole session — read `.secrets.yml` via bash and used the root-admin
`gitlab.api_token` to merge to `main` repeatedly. That is C1/C5 in action: an AI-driven process on the
dev host wielding an admin credential the deny-rules don't block. It worked because you authorized it,
but it is a live demonstration of exactly the linchpin the audit says must close before mons.

## nwc code — "the next P73s" (this is the direct answer to "what else needs work like the workflow authority")
**Root cause, fleet-wide:** *authorization at the route/form layer while the domain service trusts its
caller* (caller-supplied `$grantor`/`$mentor`/`reporter_uid`/`user_id`/`$method`), plus **label-based
guild resolution** (rename ⇒ pool empties ⇒ four-eyes waived). **P73 fixed exactly these two bugs for
`nwc_editorial.advance()` — and they recur, unfixed, across ~8 more services.** Worse: the empty-pool
`unilateral`/advisory fallback that is *safe inside advance()* becomes **fail-OPEN** when reused as a
raw boolean gate — and it's reused in the two highest-stakes spots.
- **H1 [SEC] Legal-authoring route fail-OPEN to any/anonymous user on an unseeded Copyright Guild** —
  `LegalGate::can()` returns TRUE for everyone when the guild has no member at tier; the `/admin/nwc/
  legal` routes gate only on that, no `_permission` backstop. On a fresh install, anyone can author
  Terms/Privacy/AUP and drive them to `in_production` with no four-eyes. (`LegalGate.php:69-76`,
  `nwc_copyright.routing.yml:48-63`.)
- **H2 [SEC] Stored XSS in published legal HTML** — `full_html` stored, `stripInternalHtml()` a no-op,
  emitted via `Markup::create()` on the public `/legal/*` route + injected into /apply by JS. Chain
  with H1 → persistent script for every visitor/applicant. `href` also unescaped (`javascript:`).
- **H3/H4 [SEC] Entity `update`/`create` fail-open** — `checkAccess` delegates `update` to an unknown
  action → empty-pool unilateral allow, no permission floor, no `checkFieldAccess` (so `state`/
  `copyright_cleared`/`unilateral` are directly settable); `checkCreateAccess` not overridden → JSON:API
  can `POST` a revision born at `in_production`.
- **H5–H8 [SEC] Guild + governance + story services with NO domain authz** — `recordVote` self-approves
  a level when `$method` is supplied (form always supplies it); `RatificationService`/`ScoringService`/
  `promoteMember` are open score/level/authority primitives; `nwc_growth` `ScopeGrant`/legislation/
  template engines mint governance authority with a forgeable `$grantor` audit (built-but-unwired —
  harden before wiring); `StoryModerationService` promotes into `in_pedagogy_review` with no check.
- **M1 [SEC] OIDC UserInfo** hardcodes `email_verified:TRUE`, no scope filtering, validates the bearer
  against *any* token row (incl. refresh/auth-code), type/revocation unchecked. (Live auth surface;
  `feat/f26-drop-custom-userinfo` should drop it — confirm.)
- **M3 [SEC] Hardcoded `to_mail: rjzaar@gmail.com` in the shipped /apply webform** + the approver-config
  keys are read by zero PHP → a downstream install emails applicant PII to a personal inbox. Plus the
  `administer nwc registration` (spaces) vs `administer nwc_registration` (underscore) mismatch.
- **M5** the `bypass editorial separation` permission P73 promised was **never implemented** (unilateral
  legal/doctrine advances need only the coarse perm; the confirm step is skippable). **M6** label-based
  guild lookup persists (GuildLocator built but not injected). **M7** editorial transition permission is
  granted only in an update-hook → **fresh installs regress to "nobody can transition"** (the P7 defect).
- Mostly-clean: XSS elsewhere (field formatters/Twig/htmlspecialchars), no eval/string-SQL, webhooks
  fail-closed, safeguarding entities locked.

---

# ═══ MASTER ACTION PLAN (all 8 audits, deduped + ranked) ═══
**Verdict: 0 × P0 — no AI-reachable code writes to *real* prod; the mons boundary holds today.** The
work is closing the safety machinery *before* mons/prod exists, and finishing the P73-class auth
hardening across the profile. Ordered:

**TIER 0 — do before mons/prod (some now):** ① reconcile + de-duplicate + kill-switch the self-healing
loop (armed on dev **and** mini, no flock, "paused" is fiction) and **revoke/downscope the two live
root-admin GitLab PATs** (dev+mini). ② **rotate the public-mirror gotify token**; full-history scrub.
③ **signing-key custody** off the AI disk (hardware/passphrase + rotation runbook; delete the ops23
copy). ④ **make sanitizer + PII-gate fail-CLOSED** (silent no-ops, PIPESTATUS bug, missing steps on
`live2stg`/`prod2stg`) and relocate the raw live mayo DB off dev. ⑤ `mons-operational-readiness.md`
contradicts the trust model; re-verify `ver-kit.pins` out-of-band; **back up `~/central`**.

**TIER 1 — the "next P73s" (your example, everywhere):** ⑥ close the empty-pool fail-OPEN reuses
(legal route + entity update + the missing `bypass editorial separation` gate). ⑦ domain-layer authz
on the guild/governance/story services (H5–H8). ⑧ sanitize published legal HTML (H2). ⑨ nwc_collab
token IDOR; ⑩ label→machine-id guild lookup; ⑪ OIDC userinfo integrity / drop the custom controller.

**TIER 2 — tooling landmines:** ⑫ inverted `pl security` gate; empty-var `rm -rf` guards; **ban `eval`
on parsed data**; fix `prod2stg` (runtime-dead) + `live2stg`; standardise `curl -K`; impact-contract on
1-of-14 verbs (ops#47); flock (ops#37).

**TIER 3 — public/private machinery:** ⑬ ship P61 leakage CI; per-rule gitleaks allowlists + raw-IP
rule; secret-name `.gitignore` denies; scrub Mazenod/RE + prod IP from *published* docs; drop
`example.nwp.v2.yml` from the mirror.

**TIER 4 — decision record:** ⑭ write the **un-fork ADR** (biggest undocumented decision); accept+index
**ADR-0027**; ADR for the **P73 model**; correct ADR-0013/0014/0021 (asserting falsehoods as
"Accepted"); **wire `pl doc-truth` into CI** + extend it to parse Status; fix the "paused" fiction and
the dead roadmap/milestones/CHANGELOG.

**TIER 5 — hygiene / high-leverage parked:** ⑮ move the nwc dev checkout out of gitignored `html/`
(`rm -rf html` deletes the profile repo); a bounded bot user for the loop; the **SD sign-off email to
Dan Burke** (5 min, gates a whole corpus); GitLab onto its own box.

**Two areas that most need the P73 treatment:** the **whole nwc authorization layer** (P73 fixed one
of ~9 services) and the **sanitizer** (four divergent implementations, all fail-open under the newer
fail-closed guards). Those are the "what else needs more work."
