# ADR-0030: Per-site canonical & maturity axes + the impact/fate-manifest contract

**Status:** Proposed
**Date:** 2026-07-09
**Decision Makers:** Robert Karsten Zaar (draft; operator to accept)
**Related Issues:** ops#33 (canonicality phases — merged, MRs !34/!36/!39/!44),
P67 / ops#48 (per-site maturity classes — MR !47 in review), ops#47 (impact/fate-manifest
contract on destructive verbs)
**Supersedes:** [ADR-0013](0013-four-state-deployment-model.md) (four-state dev/stg/live/prod).
**References:** [ADR-0017](0017-distributed-build-deploy-pipeline.md) (trust model),
[ADR-0024](0024-self-deploying-prod-supersedes-verifier.md) (deploy authority),
[ADR-0026](0026-nwp-server-capability-agent.md), [ADR-0028](0028-ver-single-operator-human-gated-workstation.md)
(cites the phase guards + impact-manifest), `lib/canonical.sh`, `lib/impact.sh`,
`tests/unit/test-impact-contract.bats`,
the nwp deep-audit recommendations of 2026-07-09
(`docs/reports/nwp-deep-audit-recommendations-2026-07-09.md`, stream ⑤).

---

## Context

ADR-0013 (2025-12) described deployment as **four named states** — `dev → stg → live →
prod` — as if a site's environments were a fixed linear pipeline. Two things have since
made that framing wrong in substance, not just detail:

1. **The code does not model four states; it models three canonicality *phases*.** The
   shipped guard library `lib/canonical.sh` (ops#33) recognises exactly **`dev | live |
   prod`** as the phase axis and **explicitly rejects `stg`** — `stg` is a *transient
   working copy*, not a canonicality phase. The phase answers "**which host is the source
   of truth for content?**", which governs which direction a copy may safely flow:
   - `canonical: dev` — dev DB is the source of truth (no real audience yet);
   - `canonical: live` — live is the source; content changes on dev are no longer
     authoritative (code/config-only deploys still flow up);
   - `canonical: prod` — prod is the source; live/dev are downstream sanitized copies.
   The phase lives per-site in the global `nwp.yml` (`sites.<name>.canonical`); guards
   allow only exact known-safe phases and **fail closed** on anything else
   (`invalid:<raw>`), with transitions recorded by `pl canonical set` to an append-only
   ledger.

2. **"Where content is canonical" and "how mature the code pipeline is" are two
   independent questions.** P67 / ops#48 add a second, orthogonal per-site axis —
   **`maturity: incubating | stabilizing | production`** — answering "**who may deploy
   code, past what gate?**" This is the code-flow axis beside canonical's content-flow
   axis; the two compose into ~6 valid combinations. Absent field = `incubating` = today's
   behaviour, so migration is a no-op and the operator assigns real classes site-by-site.

Separately, the ops#47 work established a hard **impact / fate-manifest contract** for
destructive verbs (`lib/impact.sh`): before any irreversible action, the command prints a
manifest labelling every affected component **DELETE / OVERWRITE / ARCHIVE / KEEP** with
live-computed sizes and data-loss warnings (from `du`, `docker`, `git`, DB queries — never
assumptions, never AI). `-y` skips the *prompt*, never the *report*; confirmation strength
matches reversibility (`y/N` while a recovery path survives, typed-name when none will).
`tests/unit/test-impact-contract.bats` fails any destructive command script that does not
source the lib, behind a **shrink-only allowlist** — the allowlist of not-yet-converted
verbs may only get smaller, never grow, so coverage ratchets forward and cannot regress.

These three mechanisms — the two per-site axes and the fate-manifest contract — are the
current canonical model of "what state is a site in, and what may safely happen to it."
ADR-0013 predates all of them and now misdescribes the system. This ADR records the
current model and supersedes ADR-0013.

## Options Considered

### Option 1: Amend ADR-0013 in place
- **Pros:** one document.
- **Cons:** the ADR convention forbids rewriting an accepted record's substance; ADR-0013's
  entire thesis ("four states, `stg` is a state, `live` and `prod` are separate named
  states in a fixed line") is what changed. An amendment banner cannot honestly leave the
  body's four-state model standing as accepted.

### Option 2: Supersede ADR-0013 with a new record (CHOSEN)
- **Pros:** follows the convention (supersede, don't rewrite); ADR-0013 keeps its
  historical body with a status banner; the current two-axis + fate-manifest model gets a
  clean authoritative statement.
- **Cons:** one more ADR to cross-reference.

## Decision

Adopt **Option 2**. A site's deployable state is described by **two orthogonal per-site
axes plus one destructive-action contract**, all enforced in shipped code:

### 1. `canonical:` — the content-flow axis (ops#33, `lib/canonical.sh`)
Values **`dev | live | prod`** (the only accepted values; `stg` is explicitly **not** a
phase). The phase names which host is the source of truth for *content*, and the guards in
the deploy verbs (`dev2stg`, `stg2live`, `stg2prod`, `live2prod`, `live2stg`, `prod2stg`)
use it to permit only known-safe copy directions and to force `live2stg` / `prod2stg` to
default-sanitize. Unknown/absent values fail closed. Transitions are explicit operator acts
recorded to an append-only ledger.

### 2. `maturity:` — the code-flow axis (P67 / ops#48)
Values **`incubating | stabilizing | production`**. It names who may deploy code and past
what gate, independently of where content is canonical. **Its promotion gate is the `stg`
verification step (§4)** — off while `incubating`, a required test-gated stage once
`stabilizing` / `production`. Absent = `incubating`. Rendered beside the PHASE column
(a `MAT` column) in `pl status` / `pl rag`.

### 3. The impact / fate-manifest contract on destructive verbs (ops#47, `lib/impact.sh`)
Every destructive verb sources `lib/impact.sh` and, before acting, renders a fate manifest
(DELETE / OVERWRITE / ARCHIVE / KEEP, live-computed) and requires a reversibility-matched
confirmation. `-y` skips the prompt, never the report. `test-impact-contract.bats` enforces
sourcing under a **shrink-only allowlist** — the CI-enforced ratchet that guarantees the
contract's coverage can only expand.

### 4. `stg` is the verification gate of the code axis — not a state, not a mere copy
The four-state linear model of ADR-0013 is retired: `stg` is **not** a canonicality phase
or a maturity value, and a site never "sits in" staging. But `stg` is more than a transient
copy — it is the **verification gate of the code-flow (`maturity:`) axis**: an **ephemeral
environment composed as candidate code × sanitized canonical data**, built to prove a
release against realistic data before it may reach live/prod.

- **Composition.** Data flows *down* from the canonical host, **sanitized** (`live2stg` /
  `prod2stg`); candidate code flows *up* (`dev2stg`). The point is "new code against
  real-shaped data" — the closest safe rehearsal of a live/prod deploy.
- **Keyed to maturity, so it switches on exactly when there is content worth protecting:**
  - `incubating` — **no stg gate.** `dev→live` may deploy directly; there is no canonical
    data at risk and nothing to rehearse against. *(The common early state — a site with no
    audience does not need staging.)*
  - `stabilizing` / `production` — stg is a **required gate**: `stg2live` / `stg2prod` may
    write only after a fresh stg run (candidate code + freshly-sanitized canonical data) has
    **passed its test suite**.
- **Ephemeral — rebuilt per deploy, not a long-lived box.** A persistent staging environment
  *drifts* (manual tweaks, stale data, config matching neither dev nor live) and then tests a
  fiction. stg is composed fresh each release and discarded — the review-environment /
  deploy-preview pattern — so it always reflects *this* candidate's code against *current*
  sanitized data.

## Rationale

The guards had to encode what is *actually safe*, and "which host is canonical for
content" is the property that determines safe copy direction — not a position in a fixed
`dev→stg→live→prod` line. Splitting content-canonicality (`canonical:`) from code-maturity
(`maturity:`) lets a site be, e.g., `canonical: prod` (real users, prod is the content
source) while still `maturity: stabilizing` (code deploys gated but not yet at full
production ceremony) — a real combination the four-state model could not express. Making
both axes fail closed on unknown values, and making destructive verbs prove their intent
via a live-computed manifest under a shrink-only CI ratchet, are the same fail-safe-defaults
/ complete-mediation principles the deep audit found NWP applies unevenly elsewhere — here
they are applied and enforced.

## Consequences

### Positive
- One authoritative statement of per-site state matching shipped code; docs stop asserting
  a four-state pipeline the code rejects.
- The two axes compose (~6 valid combinations) and both fail closed.
- Destructive actions carry an auditable, live-computed record of what the command believed;
  coverage can only grow (shrink-only allowlist).

### Negative
- Readers must hold two axes in mind instead of one linear pipeline.
- Cross-references to ADR-0013 in older docs now point at a superseded record (the
  `pl doc-truth` ADR gate keeps those links resolving; their *substance* is redirected here).

### Neutral
- Migration is a no-op: absent `canonical` defaults to `dev`, absent `maturity` to
  `incubating` — today's behaviour. The operator assigns real classes site-by-site via
  `pl canonical set` / `pl maturity set`.
- The `stg` verification gate is **inert while a site is `incubating`** (no canonical data to
  rehearse against) and becomes a required test-gated step only once the site is
  `stabilizing` / `production` — early sites keep the simple `dev→live` path and pay the
  staging cost exactly when there is live/prod content worth protecting.

## Implementation Notes
- Phase guards: `lib/canonical.sh` + the six deploy verbs (ops#33, merged).
- Maturity axis: P67 / ops#48 (MR !47) — `pl maturity set`, `MAT` column, one-line hook in
  `canonical_deploy_manifest` / `build_impact_report`.
- **`stg` verification gate (follow-up):** compose the existing verbs into a
  build-verify-discard step — `live2stg` / `prod2stg` (sanitized data) + `dev2stg` (candidate
  code) → run the site's test suite → promote on green. Enforce it when `maturity ≥
  stabilizing`; allow the direct `dev→live` path while `incubating`. Keep stg ephemeral
  (rebuilt per deploy) to prevent staging drift. This is the code-axis counterpart to the
  content-axis phase guards.
- Fate-manifest contract: `lib/impact.sh` + `tests/unit/test-impact-contract.bats`
  (shrink-only allowlist), reference consumer `scripts/commands/delete.sh`.
- ADR-0028 already depends on this model (it cites "canonical phase guards (dev|live|prod,
  ADR-0013-successor)" and the impact-manifest as ver's ergonomic prod-write gate); this
  ADR is that named successor.

## Review
**30-day review date:** 2026-08-09
**Review outcome:** Pending
