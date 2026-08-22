# NWP-ADR-0029: nwc authorization model — a domain-layer choke-point, machine-id guild resolution, fail-closed floors

**Status:** Proposed
**Date:** 2026-07-09
**Decision Makers:** Robert Karsten Zaar (draft; operator to accept)
**Related Issues:** P73 (editorial authorization hardening, Phases A+B merged on
`unfork/open-social-13`), ops#62 (NWC onboarding / Class-3 preservation)
**References:** [NWP-ADR-0005](0005-distributed-contribution-governance.md) (governance),
[NWP-ADR-0027](0027-unified-course-content-architecture.md) (canonical content + member-level
attribution), CLAUDE.md (Security Red Flags),
the nwp deep-audit recommendations of 2026-07-09
(`docs/reports/nwp-deep-audit-recommendations-2026-07-09.md`, stream ②, "the next P73s"),
OWASP Top-10 **A01:2021 — Broken Access Control**.

---

## Context

P73 fixed **one** authorization defect (editorial state transitions) in the nwc module
suite. The 2026-07-09 deep audit (stream ②), verified against `unfork/open-social-13`,
found the **same two root causes** repeated across ~8 other services — the editorial fix
was one instance of a class, not the class itself. This ADR records the *model* the class
must be fixed against, so the remaining fixes are consistent rather than re-litigated
service by service.

The two recurring root causes:

1. **Authorization enforced at the route/form layer while the domain method trusts
   caller-supplied identity, role, or method.** A Drupal route `_custom_access` or form
   check does not protect the service method underneath it: `->save()` runs **no** access
   check, so JSON:API / REST / VBO reach the mutator directly. Services that accept a
   caller-supplied `$grantor` / `$mentor` / `$method` / `reporter_uid` and *record it as
   fact* produce a **self-attested, forgeable audit trail** (the confused-deputy
   anti-pattern). Observed in `ScopeGrantService::grant()` (has `assertFunction()` but
   never calls it), `SkillProgressionService::recordVote()` (trusts caller `$method`,
   never calls `canVerify()`), `RatificationService`, `GuildService::promoteMember`,
   `StoryModerationService::route()`.

2. **Guild membership resolved by mutable label, not a stable machine identity.** When a
   guild is looked up by its human-readable name, a rename empties the resolved pool — and
   an empty pool that is reused as a raw boolean gate **fails OPEN** (four-eyes silently
   waived). `LegalGate` already carries a `GuildLocator`, but `GuildLocator::load()` still
   resolves key→label→Group *by label* because guild groups carry no machine name, and the
   guild/governance/story services still resolve by label directly.

A third, related failure is the **fail-open fallback**: `LegalGate::can()` returns TRUE
when the Copyright Guild is unseeded or empty-at-tier. On a fresh install this makes legal
authoring reachable by **anonymous**. P73 §1 itself warned that an advisory "allow when we
cannot decide" fallback "becomes fail-OPEN when reused as a raw boolean gate." The audit
confirmed the warning came true.

Governing design facts (Drupal access model): `access` returns a **trinary**
(`allowed` / `neutral` / `forbidden`, **forbidden-wins**); `checkAccess`,
`checkCreateAccess`, and `checkFieldAccess` are **distinct** methods (overriding one does
not cover the others); and `->save()` performs no access check at all, so an
`EntityAccessControlHandler` is the *only* thing covering non-form write paths.

## Options Considered

### Option 1: Fix each call-site in place (status quo)
- **Pros:** smallest per-fix diff; no new shared code.
- **Cons:** this is exactly what has been happening — P73 fixed 1 of 9; the sanitizer grew
  4 divergent implementations. Fixing one call-site leaves its siblings fail-open. Violates
  **complete mediation**: "a control present in *most* paths provides no guarantee" because
  the attacker routes through the path that lacks it.

### Option 2: One god-authorizer for all nwc domains
- **Pros:** single entry point.
- **Cons:** couples unrelated bounded contexts (editorial ≠ guild ≠ governance) with
  different rules and audit needs; a single create-path method invites the
  forbidden-poisoning bug (a forbidden in one bundle denying an unrelated one). Rejected.

### Option 3: A shared authorization substrate + one authorizer per bounded context (CHOSEN)
- **Pros:** economy-of-mechanism (the security analogue of DRY) — one definition to audit,
  one place a fix lands everywhere, no divergent copies to drift fail-open; keeps
  per-domain rules separate; implement-once-reuse (OWASP A01).
- **Cons:** up-front substrate work (a locator + an eligibility primitive) and a data
  migration to add machine names; must ship with positive regression tests so tightened
  gates do not deadlock a live progression flow.

## Decision

Adopt **Option 3**. The nwc authorization model has five load-bearing properties. Every
new or hardened nwc service must satisfy all five; a service that cannot is not wired to
a public route until it can.

1. **A domain-layer authorization choke-point per bounded context.** Model a
   `GuildActionAuthorizer` / `GovernanceAuthorizer` on the existing `TransitionAuthorizer`
   — **not** one god-authorizer (Option 2). Every mutator delegates its authorization
   decision to its context's authorizer *before* mutating. Route/form checks remain, but
   are **defence-in-depth on top of** the domain check, never the only gate.

2. **Machine-id (not label) guild resolution, injected everywhere.** Add a stable
   machine-name base field to the guild group bundle; make `GuildLocator::load()` resolve
   by it; ship a one-time label→key migration. Inject the locator into **every** service
   that resolves a guild (a shared `GuildEligibility` primitive is the natural carrier).
   No call-site may resolve a guild by its display label.

3. **Empty-pool fallback must FAIL CLOSED when reused as a raw gate.** An "unseeded /
   empty-at-tier" condition may drive a *bootstrap* affordance, but must never grant a
   *security* decision. Concretely: in `can()`, return `forbidden()` for an anonymous
   actor **before** any unseeded/empty-tier fallback; add a hard **permission floor** on
   the sensitive routes (`_permission`, granted only to seeded roles) that Drupal **ANDs**
   with the tier check; and mirror the floor inside the authorizer so the domain path
   (`advance()`) is floored too, not just the route.

4. **A `bypass editorial separation` permission floor for the unilateral override.** The
   unilateral legal/doctrinal override (four-eyes-waived) must be gated by an explicit,
   restricted, **audited** permission — never a silent fall-through of the coarse surface
   permission. Define `bypass editorial separation` in `nwc_editorial.permissions.yml`;
   require it (else deny) when an allow is granted **only** via `unilateral` **and**
   `change_kind ∈ {legal, doctrine-core}`, together with the confirm-form step and the
   persisted `unilateral` audit stamp. Ordinary frictionless unilateral advances are
   unaffected. (P73 §3.3 specified this permission; `grep` finds zero matches today.)

5. **Every mutator takes the acting account from `currentUser`, never a caller-supplied
   identity.** No authority-minting or state-mutating method accepts a free-form
   `$grantor` / `$mentor` / `$method` / `reporter_uid` as trusted input. Caller-supplied
   values are treated as *hints* (e.g. for display); the server re-derives the real actor
   and method, authorizes first, throws on deny, and derives the audit identity from the
   authenticated actor. Add a belt-and-suspenders `EntityAccessControlHandler` per mutable
   entity overriding `checkAccess` / `checkCreateAccess` / `checkFieldAccess` and
   hard-denying request-borne API writes (the only cover for JSON:API / VBO).

## Rationale

OWASP A01:2021 is the single most prevalent web weakness; its prescriptions are exactly
this model: **deny by default, enforce server-side, implement-the-check-once-and-reuse,
log failures.** The deep audit's meta-finding is that NWP already *has* the right pattern
(fail-closed, trinary, entity-handler) but applies it *unevenly* — which is the precise
failure **complete mediation** exists to prevent. Consolidating each control into a single
definition (properties 1–2) is **economy-of-mechanism**; making the fallback fail closed
(property 3) and the override explicitly permissioned (property 4) restores **fail-safe
defaults**; sourcing identity from `currentUser` (property 5) closes the confused-deputy /
self-attested-audit hole. P73 proved the pattern on editorial; this ADR generalises it so
the remaining services converge instead of each re-inventing a gate.

## Consequences

### Positive
- One authoritative model; H5/H6/H7/H8/L1 (shared root cause) become mechanical
  applications of the substrate, and H1/H2/H3/H4/M1/M3/M5/M7 (one-off surfaces) are fixed
  with the same principles.
- Audit trails become trustworthy (actor derived from the authenticated session).
- A guild rename can no longer silently waive four-eyes.

### Negative
- Up-front substrate (locator machine-name migration + `GuildEligibility` primitive) before
  the dependent fixes land.
- Tightening live gates risks deadlocking an in-flight progression flow unless shipped with
  positive regression tests alongside the negative direct-service-call tests.

### Neutral
- All H-items plus M1/M3/M5/L1 are security-critical → **two-person review** (CLAUDE.md
  sensitive-path rule). M6/M7/L2/L3 are integrity/robustness, not authorization, and do not
  require two-person review.

## Implementation Notes
- **Sequencing:** land the substrate (GuildLocator injection + `GuildEligibility`
  fail-closed trinary: "does `$actor` hold ≥tier T in guild `$key`, and `$actor` ≠
  subject?", cache-context `['user']`) first, behind the P73 test discipline; then
  H5→H6→H7→H8→L1 on top; fix H1/H2/H3/H4/M1/M3/M5/M7 directly in parallel.
- Do **not** wire the governance UI/API until H7 (`ScopeGrantService::grant()` /
  `LegislationService::enactDirect()`) lands — it is cheap to fix while unwired.
- This ADR is the authorization companion to NWP-ADR-0027's content model: NWP-ADR-0027 severs
  *individual identity* at the site boundary (member-level, CC0); this ADR ensures the
  *acting identity inside* a site is authentic and authorized.

## Review
**30-day review date:** 2026-08-09
**Review outcome:** Pending
