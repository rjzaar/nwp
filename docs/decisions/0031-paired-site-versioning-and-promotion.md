# NWP-ADR-0031: Paired-Site Versioning & Promotion — five planes, a versioned pair contract, provider-first ordering

**Status:** Accepted (2026-07-10, operator)
**Date:** 2026-07-10
**Decision Makers:** Robert Karsten Zaar (with AI assistance)
**Related Issues:** ops#22 (nwc 2.0 punch list), ops#31 (policy version-bookkeeping race),
ops#48 (P67 maturity classes), ops#49 (`pl gitlab` unified surface), ops#61 (canonical content
model), ops#66 (federation, blocked on F26/F28)
**References:** [NWP-ADR-0017](0017-distributed-build-deploy-pipeline.md) (trust-through-signatures,
expand-contract), [NWP-ADR-0027](0027-unified-course-content-architecture.md) (canonical content,
disposable adapters), [NWP-ADR-0028](0028-ver-single-operator-human-gated-workstation.md) (deploy gate),
[F26](../proposals/F26-avc-ss-oidc.md) (OIDC; extended by nwp!49 draft),
[F28](../proposals/F28-unified-pipeline.md) (signed bundles, `dependencies` field),
[F30](../proposals/F30-content-federation-network.md) §3.4 (manifest version-constraints, superseded),
[P65](../proposals/P65-seed-content-lifecycle.md), [P67](../proposals/P67-per-site-workflow-maturity.md),
[P72](../proposals/P72-moodle-to-nwc-suggest-edit-bridge.md),
onboarding NWP-ADR-0031 (Moodle schema-defensiveness), `docs/onboarding/repo-map.md` (paired-PR convention).

> **Numbering note (2026-07-10).** This ADR takes **0031** — 0027–0030 are now on `main`
> (unified course content, ver workstation, nwc authorization model, canonical/maturity axes).
> Separately, `docs/onboarding/adrs.md` cites an *NWC-profile-local* "NWP-ADR-0030/0031" series
> (cross-site POST auth; Moodle plugin compatibility) that does not exist in `docs/decisions/`;
> recommend renumbering that onboarding series as `NWC-ADR-*` to avoid colliding with this record.

---

## Context

NWP runs **paired sites across two stacks**: `nwc` (Drupal/Open Social, canonical) ↔ `ssc`
(Moodle, real Saint School students), and their demo twins `nwd` ↔ `ssd`. The pairs are coupled
by OAuth2/OIDC SSO, copyright-policy sync, and a feedback bridge. `pl` was designed to move **one
site** through dev → stg → live → prod; the question this ADR answers is how **two sites on two
stacks stay in version sync** as they move — and how multiple concurrent ops MRs across the ss
and nw sides are coordinated.

A four-front research sweep (2026-07-10: repo/tag inventory, promotion-machinery audit, docs
sweep, GitLab audit) established the current state:

**Tagging.** The `nwp/nwc` profile repo has a real but lapsed practice: 5 durable tags across two
competing schemes (`v0.4.0` vs `nwc/v1.0.0`), last durable tag 2026-05-22; composer.json declares
`0.5.0` **untagged**; 11 local-only `pre-*` rollback anchors pollute `git tag -l`. The Moodle side
has **zero tags and no taggable boundary**: all Moodle site trees are clones of upstream
`github.com/moodle/moodle` (local commits unpushable); the integration plugins on ssc/ssd sit as
**untracked files** inside those clones; the two GitLab plugin repos (`nwp/auth-nwc-oauth2`,
`nwp/local-nwc-copyright-sync`) were pushed once (2026-05-19) and have already drifted from the
working trees (`local_nwc_copyright_sync` 0.2.0 on ssc/ssd vs 0.1.0 in-repo/ss). `~/dir/courses_v3`
(canonical plugin builds) has no git remote. Zero GitLab milestones or releases exist on any project.

**Promotion machinery.** Every guard and gate is keyed on one site string (`canonical_guard_*`,
`maturity_*`, `deploy_gate_require`; the Solo manifest binds `site=<one>`). Nothing reads
`project.type`; `pl stg2live ssc` today would write a Drupal `settings.local.php` into the Moodle
tree, lay a Drupal nginx vhost, never move `moodledata`, never rewrite `$CFG->wwwroot`, and the
Drupal-only sanitizer would pass raw Moodle PII. `paired_with:` / `sibling_sites:` / `oauth2:` keys
in `.nwp.yml` have **zero code consumers**. `ssc` is not registered in global `nwp.yml` at all —
its guards evaluate invisible defaults.

**Coordination precedent.** The un-fork used same-named branches in two repos
(`unfork/open-social-13` in `nwp/nwc` + `nwp/nwc-project`), an explicit "Pairs with nwp/nwc!7"
line in the MR body, and the ops issue as the shared review package. F26's nwc↔ss extension is a
live draft (nwp!49, AUTH, human-gated) shipping both stack halves in one staging repo. The
onboarding docs prescribe `paired/<x>-<y>` branches — never used in practice.

### The framing correction

"Two sites must move in lockstep" is the wrong model here. The system has **five planes** with
three distinct movement patterns, and only a narrow contract actually couples the pair:

| # | Plane | Where truth lives | How it moves | Version signal | Disposable? |
|---|-------|-------------------|--------------|----------------|-------------|
| 1 | **Drupal code** | `nwp/nwc` git repo | git up the tiers (rsync/composer); P67 maturity axis | semver tag | rebuildable |
| 2 | **Drupal site content** | one environment's DB, declared by `canonical:` (ops#33) — nwc is `canonical: dev` today | DB pulls **down** (sanitized); content pushes up (canonical-guarded) | P67 provenance+age stamps, not git | **no** — it *is* the community; also holds in-flight editorial state (P68) that exists nowhere else |
| 3 | **Moodle code** | GitLab plugin repos + pinned Moodle core tag (today: untracked files in upstream clones) | plugin manifest + installer into site trees | `$plugin->version` / `release` + repo tag | rebuildable once repos fixed |
| 4 | **Formation content (canonical)** | `nwp/courses` YAML + JSON Schema (NWP-ADR-0027) | git MRs; rendered **sideways** into any environment as a pure function | schema version (v3.0.0 → v3.1) + repo history | it's the canon |
| 5a | **Moodle rendered course rows** | none — projection of plane 4 | `populate_courses.php --clear` re-render | the plane-4 version it was rendered from | **yes** (NWP-ADR-0027 D1) |
| 5b | **Moodle learning/user state** (accounts, enrolments, attempts, completions, badges, `tool_policy` acceptances, `moodledata` files) | the ssc **live** DB + dataroot | never regenerated; backup/restore + (future) sanitized pulls only | none today | **absolutely not — PII, minors' records** |

Movement patterns: **code flows up** (git, dev→stg→live→prod), **site content flows down**
(sanitized DB pulls), **formation content flows sideways** (canonical repo → rendered into
whichever environment). A paired promotion scheme must respect all three, not force them into one.

### The cross-plane rails (what "version sync" actually means here)

1. **Identity rail (5b ↔ 2).** F26 UID-lock: `mdl_user.idnumber` locks to the Drupal uid on
   first SSO. ssc's *user state* is coupled to nwc's *site content* (uids live in the DB).
   ⚠️ **Live hazard today:** nwc is `canonical: dev`, so a full-DB `pl stg2live nwc` is a legal
   operation — and it would renumber/replace live users, silently severing every UID-lock on ssc.
2. **Policy rail (2 → 5b).** `nwc_copyright vN` → `local_nwc_copyright_sync` →
   `tool_policy_versions` → student **re-consent events**. Document versions in the Drupal DB
   drive irreversible acceptance rows in Moodle user state. ops#31 (dual-writer version race) is
   this rail malfunctioning: a spurious bump forces sitewide re-consent.
3. **Render id-stability (4 → 5a ← 5b).** Plane 5a is disposable *only if* re-rendering is
   id-stable, because 5b rows (attempts, grades) point at 5a rows (course-modules, quizzes). P72
   already pins deep-links to canonical ids ("not Moodle's `cm->id`"), but nothing yet *guarantees*
   `--clear` re-render preserves the ids user state hangs off. "Disposable" is safe for content
   and dangerous for grades until this contract is explicit and tested.
4. **Editorial round-trip (5a → 2 → 4).** Formation content is authored/reviewed as Drupal
   entities (P68/ops#50) and exits to `nwp/courses` via P64 export. Plane 2 contains the *working
   state* of plane 4 — backups/pulls of nwc must preserve it; a canonical flip must not strand drafts.
5. **Code contract (3 ↔ 1).** The three integration surfaces: OAuth/OIDC (nwc `simple_oauth`
   issuer ↔ Moodle auth plugin), copyright sync, feedback bridge. House philosophy is already
   **defensive tolerance, not pinning** (onboarding NWP-ADR-0031 schema-defensiveness; NWP-ADR-0017
   expand-contract).

## Options Considered

### Option 1: Collapse the pair into one versioned unit (socialbase/socialblue precedent)
- **Pros:** version skew becomes structurally impossible; one tag, one release.
- **Cons:** impossible across stacks — Drupal profile and Moodle plugins cannot share a package
  or a deploy mechanism; would recreate the fork-maintenance problem the un-fork just escaped.
  Right for *same-stack* twins only (nwc/nwd already share `nwp/nwc`; ssc/ssd share one plugin set).

### Option 2: Atomic two-site promotion transaction (orchestrator with cross-site rollback)
- **Pros:** "both or neither" is easy to reason about.
- **Cons:** distributed-transaction machinery across two stacks, two DBs, one shared host; a
  failed half still leaves users mid-session on mismatched halves (rollback is not atomic for
  live traffic); doubles the blast radius of every deploy; per-site Solo-touch manifests
  (NWP-ADR-0028) would need multi-site semantics, complicating the security-critical path. The
  failure mode it protects against (brief contract skew) is better eliminated by making contract
  changes backward-compatible.

### Option 3 (chosen): Versioned pair contract + provider-first ordering + per-plane canonicality
- **Pros:** matches every existing mechanism (expand-contract, NWP-ADR-0031 defensiveness, F28
  `dependencies`, F30 version-constraints, P67 axes); each side stays independently deployable
  and rollback-able; the contract is a small, testable artifact; the security-critical deploy
  gate stays single-site and simple.
- **Cons:** requires discipline (contract bumps must be expand-contract); brief windows where
  sides run different code versions are *normal* — the smoke suite, not a transaction, is the
  safety net; more moving parts to document than option 1.

## Decision

### D1. Five planes, three movement patterns — named and load-bearing
The plane table above is the authoritative decomposition. Any tool, guard, or runbook that says
"promote the pair" must say **which plane** it moves. Formation content (plane 4) is **never**
version-synced site-against-site: sites declare which `nwp/courses` schema version they can
render, exactly like a code dependency.

### D2. Version the contract, not the pair
A **pair contract** — `pair-contract.yml`, one per pair, living in the provider's repo
(`nwp/nwc`) with a copy-consuming check on the consumer side — records, with a monotonically
increasing `contract_version`:
- **Code surfaces:** per surface (oauth-sso, copyright-sync, feedback-bridge), the minimum
  counterpart versions: "nwc ≥ 0.5 requires `auth_nwc_oauth2` ≥ 1.1".
- **Data rails:** (a) identity — the UID-lock invariant + the canonical-phase coupling rule (D6);
  (b) policy — the single-writer rule for `nwc_copyright` version fields (resolves ops#31's
  design flaw: version becomes one real field with one writer, both sync paths read it);
  (c) render id-stability — the canonical-id join-key guarantee, declared in the `nwp/courses`
  schema and enforced by the shared adapter test-suite (NWP-ADR-0027 §7).
- **Per-environment provider endpoints:** the OAuth issuer URL for each tier
  (`dev: https://nwc-dev.ddev.site`, `live: https://nwc.<example-prod-domain>`, …) — making the currently
  dead `paired_with:`/`oauth2:` keys in `.nwp.yml` **live configuration** consumed by `pl`.

### D3. Tagging policy (both sides)
- `nwp/nwc`: single scheme **`vX.Y.Z`** (the `nwc/v*` scheme is retired; existing `nwc/v1.0.0*`
  tags are historical). Tag **v0.5.0 now** to match composer.json. A tag is cut whenever
  composer.json's version changes; composer version and tag may never diverge again.
- Moodle plugin repos (`nwp/auth-nwc-oauth2`, `nwp/local-nwc-copyright-sync`, and any future
  plugin): tag **`vX.Y.Z`** matching `$plugin->release`; `$plugin->version` (YYYYMMDDXX) remains
  the Moodle-native monotonic key. Bumping `release` without tagging is the failure mode to CI-check.
- Rollback anchors (`pre-*`) are **out-of-band**: never pushed to origin, or namespaced
  `rollback/*` so `git tag -l 'v*'` stays clean.
- Moodle **core** is pinned to released upstream tags (UPDATE-HANDLING §6C; requires converting
  the `--depth 1` clones to taggable clones).
- GitLab **releases** (not just tags) are cut for `nwp/nwc` and plugin repos at contract bumps,
  so "what pairs with what" is answerable from the GitLab UI.

### D4. Repo boundaries: plugins are the versioned unit on the Moodle side; site trees are not
- The GitLab plugin repos are **canonical** for Moodle custom code. The drifted working copies on
  ssc/ssd/ss are reconciled *into* them first (the 0.2.0 tree state wins where it is the newest).
- Site trees remain upstream-Moodle clones; plugins deploy into them via a **manifest +
  installer** (adopting the proven `~/dir/courses_v3/plugins/` manifest + `install_plugins.sh`
  pattern, `pl`-managed), with a lockfile per site tree recording installed plugin versions —
  the Moodle analogue of `composer.lock` ("lock flows up").
- `~/dir/courses_v3` gets a git remote (subtree split; single-disk canon is unacceptable).
- The F26 `auth_nwc` plugin (currently staged inside nwp/nwp MR !49) lands in
  `nwp/auth-nwc-oauth2` when the human auth review passes — plugin code does not live in the
  tool repo.
- `ssc`/`ssd` are **registered in global `nwp.yml`** so canonical/maturity/RAG stop evaluating
  invisible defaults (ssc currently has no entry and no RAG issue).

### D5. Promotion: no atomic pair transaction; expand-contract + provider-first + pair smoke
- Contract-surface changes MUST be **expand-contract** (backward compatible): new claim/endpoint
  added → both sides updated in either order → old form removed one release later. Ordering is
  therefore normally free.
- When `contract_version` bumps, **provider promotes first, consumer second** (nwc before ssc),
  enforced by a new **`pair_guard`** at the same choke points as the existing guards
  (`canonical_guard_content_push` → `maturity_guard_deploy` → `pair_guard` →
  `deploy_gate_require`). `pair_guard` reads the pair contract + both sites' deployed versions
  and refuses a consumer promotion past its provider (with a ledgered `--override-pair` escape,
  same shape as `--override-canonical`).
- After **any** promotion of either half, the **pair smoke suite** runs against both halves of
  that tier (the onboarding 5-URL set: OAuth callback, copyright-sync status endpoint, feedback
  POST, + an actual token round-trip on non-prod tiers). A failed pair smoke is a red RAG signal
  on both sites — the safety net is observation, not transaction.
- The **deploy gate stays per-site** (two Solo touches for a paired prod deploy is accepted;
  the ed25519-sk manifest stays single-site and simple). F28 bundles carry the counterpart
  bundle id in the existing `dependencies` manifest field so the verifier tier can verify "this ssc
  bundle expects nwc-bundle-X applied" — the field exists; this ADR gives it its first use.
- Rollback remains per-site; because contract changes are expand-contract, rolling back one half
  never strands the other outside the contract window.
  - **Carve-out (ops#83):** "rollback is safe per-site" is asserted here for **code** (git revert
    up the tiers). It does **not** cover a **DB restore/rebuild that renumbers Drupal uids** at a
    `coupled_tier` — that operation can silently re-point or orphan every consumer UID-lock and is
    governed instead by **D9** (the `sub_stability: uuid` durable anchor + the both-or-forward
    paired-restore invariant). Code rollback ≠ identity restore.

### D6. Per-plane canonicality — pair phases are legitimately asymmetric, with one directional invariant
Forcing "pair members' `canonical:` phases must match" is **rejected**. ssc is effectively
`canonical: live` for user state (real students) while nwc is `canonical: dev` for community
content — that is correct today. The invariant is directional:

> **An identity-coupled consumer with real users forces its provider's user-bearing environment
> to be treated as canonical:** once real ssc users UID-lock against nwc live uids, nwc must
> either flip to `canonical: live` or restrict that tier to `--code-only` deploys. Full-DB
> pushes that renumber uids on a live provider are forbidden while any consumer holds UID-locks
> against it.

`pair_guard` enforces this mechanically (refuse full-DB `stg2live`/`stg2prod` on a provider whose
pair contract declares live identity coupling). Until built, this is a standing operator rule —
see the Immediate hazard note below.

### D7. Multi-MR coordination: the ops issue is the transaction
Formalizing the pattern that already worked (un-fork nwc!7 + nwc-project!2):
- **One ops issue per cross-site change**; every MR in every affected repo carries
  `Refs/Closes nwp/ops#N`. The ops issue is the shared review package and the coordination record.
- **Same branch name in every affected repo: `ops-N`.** The onboarding `paired/<x>-<y>` prefix is
  retired unbuilt; a **`paired` label** on the MRs carries the semantics instead.
- Each MR body carries an explicit **"Pairs with `<repo>!<iid>`"** line (or "No counterpart —
  <why>", satisfying the pr-review-checklist smell test: a bridge fix touching one repo only).
- **Merge order = provider first, same day** for contract-bump MRs.
- `pl issue work N` gains a preflight: check `origin/ops-N` in **every** pair-affected repo
  (profile, plugin repos, courses) before building — the recorded failure mode (ops#60 fully
  built on an unmerged branch; 6 orphan branches on nwp/nwc today) becomes a mechanical check.
- ops#49 (`pl gitlab`) is the natural home for tooling this (create twin branches, cross-link
  MRs, block merge while a declared pair MR is red) — convention first, tooling when ops#49 lands.

### D8. Moodle promotion substrate is a prerequisite, tracked separately
Paired promotion presupposes `pl` can promote a Moodle site *at all*. A **type-dispatch layer**
(per-type: settings-writer, vhost template, cache-clear, `$CFG->wwwroot` rewrite, `moodledata`
handling, sanitizer, smoke) is required. The **Moodle sanitizer is security-critical** (plane 5b
is minors' learning records + consent rows): it gets the same human-review treatment as auth
code, and P67's fail-closed behavior (abort rather than pass raw PII) is the required default.
`moodledata` joins the backup surface (it is in zero backups today).

### D9. Identity durability under restore/DR (ops#83)

D5's expand-contract reasoning makes **code** rollback safe per-site. It says nothing about a **DB
restore/rebuild that renumbers Drupal uids**, and the identity rail makes that case dangerous: the
UID-lock binds `mdl_user.idnumber == OIDC sub == Drupal account`, and with the historical
`sub = $account->id()` mapping the `sub` **is** the renumber-fragile serial uid. A full-DB push
(blocked by `--code-only`, D6), a rebuild/re-seed/migrate (Open Social upgrade, re-import), or a
point-in-time-**asymmetric** restore then silently re-points every ssc `idnumber` at the wrong — or
no — nwc account. This decision closes that gap with two clauses, both required:

- **(A) Durable anchor — `sub` is the Drupal account UUID, not the serial uid.** The Drupal `uuid`
  base field is row-stored (survives a plain restore), never renumbered, and never reused, so the
  lock survives a *within-half* renumber/rebuild/migrate and uid-reuse. Emitted via the existing
  `hook_simple_oauth_oidc_claims_alter` in `nwc_oidc_claims` (`$claim_values['sub'] =
  $account->uuid()`) — no core patch; `uid_lock` already treats `sub` as an opaque string and
  Moodle `idnumber` is varchar(255). **This is LIVE-PROVEN: UUID-`sub` is already deployed on the
  nwc live tier** (done while the five Moodles are empty seed instances — trivial now, a cross-stack
  flag-day once real students hold locks). Recorded in the pair contract as
  `identity.sub_stability: uuid`.
- **(B) Both-or-forward restore invariant.** For any restore/rebuild of a UID-lock provider (nwc) or
  consumer (ssc) at a `coupled_tier`, either **both halves are restored to the same logical cut**, or
  the provider is restored/rebuilt to a point **no older than the consumer's newest locked
  identity** — provider identities are append-only *forward* of every consumer lock, never dropped
  behind one. In one line: *when in doubt, restore both halves to one instant, or neither.* (A)
  handles within-half renumber; (B) handles cross-half point-in-time asymmetry — neither alone
  suffices. Recorded as `identity.restore.invariant: both-or-forward`.

**Provider identity ledger.** nwc snapshots an append-only `(uuid, uid, email, created_ts)` ledger
with every backup (`identity.restore.ledger: provider`). It is the *deterministic* old-uid→uuid
repair map after a renumbering restore — reconciliation joins on the ledger, **never** on email
(recycled/changed emails make an email join unsafe; email fallback is a human-gated last resort).

**`pair_guard` restore choke-point.** `pair_guard` gains a restore gate (parallel to its existing
`--code-only`/full-DB-push refusal, D6) that **refuses a coupled-tier restore/rebuild** lacking the
consumer join-snapshot + provider ledger (`identity.restore.pre_check_required: true`; escape =
ledgered `--override-pair`).

**Join-integrity probe.** The pair smoke suite (D5) is liveness-only today (JWKS 200, endpoints up).
D9 adds a **join-integrity probe**: after a restore, pick a real `idnumber` and confirm it still
resolves to the correct nwc account — not just that the endpoints answer. Clearing the ssc
`autoredirect` guard is gated on that probe going green.

**Scope split.** `--code-only` (D6) covers the full-DB *push*; D9 covers *restore/rebuild*. Both are
faces of the same identity rail (D2(a)). Tooling — the ledger, the `pair_guard` restore gate, and the
join-integrity probe — is **phased** (tracked under ops#83 / ops C / ops#49); the `sub_stability:
uuid` anchor is already live, and the both-or-forward rule is a standing operator rule until the gate
lands (see the paired-restore runbook, `docs/guides/ops83-dr-restore.md`).

## Immediate hazard note (standing rule until `pair_guard` exists)

**Do not run a full-DB `pl stg2live nwc` / `stg2prod nwc` while ssc users hold UID-locks against
nwc's live tier.** nwc's `canonical: dev` setting makes this a legal operation today, and it
would silently sever every ssc SSO identity (D6). Use `--code-only` for nwc live deploys until
the guard lands or nwc flips to `canonical: live`.

## Rationale

- Every existing mechanism in the corpus points at option 3: NWP-ADR-0017's expand-contract and
  "trust flows through signatures, not machines"; onboarding NWP-ADR-0031's schema-defensiveness;
  F28's designed-but-unused `dependencies` field; F30 §3.4's version constraints; P67's
  deliberately per-site axes. Option 3 composes them; options 1–2 fight them.
- The one lockstep precedent (socialbase/socialblue) worked precisely because both halves shared
  a stack and a package boundary — the condition the nwc↔ssc pair lacks by construction.
- Making the *contract* the versioned artifact keeps the security-critical paths (deploy gate,
  sanitizer, the offline-verifier boundary) single-site and auditable, per the threat model.
- The five-plane decomposition prevents the recurring category error of the last three months of
  docs: "content" meant four different things (community DB, canonical courses, rendered rows,
  learning records) with four different sync semantics.

## Consequences

### Positive
- "What version of nwc pairs with what version of ssc?" becomes answerable (tags + contract +
  GitLab releases) — it is unanswerable today.
- ssc's integration code stops being untracked single-disk files; the Moodle side gets a real
  git identity without versioning Moodle core.
- ops#31's race is fixed at the design level (single-writer version field), not patched.
- The UID-lock deploy hazard is named, guarded, and eventually mechanical.
- Multiple concurrent ops MRs across repos have one convention (`ops-N` everywhere + Pairs-with
  lines + ops issue as transaction) instead of three half-conventions.

### Negative
- Discipline cost: contract bumps require expand-contract thinking and provider-first sequencing.
- Two Solo touches per paired prod deploy (accepted; simplicity of the gate wins).
- A new artifact (`pair-contract.yml`) to keep honest — mitigated by `pair_guard` + pair smoke
  consuming it (dead-doc keys are what this ADR is cleaning up; the contract must never become one).

### Neutral
- Brief version-skew windows between halves are normal and observable (pair smoke), not faults.
- The onboarding docs' `paired/` branch convention and phantom ADR series need reconciliation
  passes (folded into the ops issues).

## Implementation Notes

Work is decomposed into four ops issues (filed alongside this ADR):
- **ops A — Moodle-side repo hygiene & registration** (D4): reconcile plugin drift into GitLab
  repos; plugin manifest + installer + per-site lockfile; register ssc/ssd in `nwp.yml`; remote
  for `~/dir/courses_v3`; convert Moodle clones to taggable.
- **ops B — Tag & release hygiene** (D3): tag `nwp/nwc` v0.5.0; retire dual scheme; plugin repo
  tags; `pre-*` out-of-band policy; GitLab releases at contract bumps; CI check
  composer-version↔tag and `$plugin->release`↔tag.
- **ops C — Pair contract + guards + pairing config** (D2, D5, D6, D7): `pair-contract.yml`
  schema; make `paired_with`/`oauth2` keys live (per-env issuer URLs — also fixes ssc-dev ↔
  nwc-dev OAuth wiring); `pair_guard` at the guard choke points; pair smoke suite; `pl issue
  work` multi-repo preflight; document the D6 standing rule. Auth-half depends on F26 review
  (nwp!49, human-gated).
- **ops D — Moodle type-dispatch in the promotion pipeline** (D8): type strategy layer;
  **Moodle sanitizer (human-reviewed, fail-closed)**; `moodledata` in backups; `$CFG->wwwroot`
  rewrite; Moodle-aware smoke.

Dependencies: A → B → C; D independent of A–C but blocks real ssc stg/live parity; C's auth half
gated on F26 sign-off. The D6 standing rule is effective immediately (no build required).

## Review

**30-day review date:** 2026-08-09
**Review outcome:** Pending
