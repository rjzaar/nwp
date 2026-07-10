# P73 — Editorial-workflow authorization hardening: one fail-closed domain-layer choke-point

**Status:** ✅ **APPROVED — 2026-07-09 (operator, sole authority).** Operator decision on §7 Q1:
*"Until there is a second reviewer I have full authority"* — the sole-actor bootstrap override is the
**adopted policy** (not hard-block): the operator, as sole authority, may proceed unilaterally on any
stage incl. legal/doctrinal until a separate eligible reviewer exists; the override must be **explicit,
persisted (`unilateral` stamp) and audited**, and it **re-tightens automatically** the moment a
second qualified member exists. This also satisfies the two-person-review requirement (the operator
is the sole authority and has approved).
**Sensitivity:** 🔴 **SECURITY-CRITICAL — legal/doctrinal authorization + auth logic.** Built with
explicit operator approval + authority; each phase still ships with the full negative+positive tests.
**Research base:** two parallel surveys 2026-07-09 — a complete authorization-surface map of
`nwc_editorial` (on `feat/ops50-legal-authoring`) and a sourced best-practice brief (OWASP A01 /
Saltzer & Schroeder / Symfony Workflow guards / Drupal Access API). Follow-on to **ops#71** (which
scoped only `advance()`); this proposal broadens to the real surface.
**Relation:** hardens the P68 editorial pipeline (ops#50/#51) + the P70/P71 gates. Does **not**
block the ops50 line from merging — the P68 *legal* gates are already domain-enforced (see §1); this
closes the *general* pipeline gap. Preserves the P68 §4 anti-self-review + the P71 advisory fallbacks.

---

## 1. The finding — a presentation-layer-only authorization defect (OWASP A01)

`EditorialStateService::advance()` enforces **only three special-case gates** (legal / theology-for-core
/ audience-fit) + one data check (`copyright_cleared`). It performs **no general stage-pool
eligibility check** — it never reads `eligible_reviewers`, never requires a claim, never consults
`STATE_ROLE_MAP`/`STATE_GUILD`. The pool resolver's careful role/guild math governs **notification and
claim only**, not advancement. So for every ordinary stage (writer, pedagogy, media, safeguarding,
non-legal copyright, approved→trial→production) the only barrier is the route permission `transition
editorial revision` — **granted to no role at install**. This is a textbook *Missing Function-Level
Authorization* / presentation-layer-only defect: the button is hidden in `TransitionForm`, but the
domain service is unguarded, so any programmatic caller (drush, a future JSON:API/REST endpoint,
Views bulk op, another module) reaches the transition unchecked.

**The mutation surface and its guards today** (from the code map):

| Entry point | Guard today | Gap |
|---|---|---|
| `advance()` | legal/theology/audience gates + copyright data-check | **no general pool check** (P1) |
| `transition()` (**public**, the shared funnel) | none | anyone can drive any state (P2) |
| `requestRevision()` / `escalate()` / `reject()` / `markAsHotfix()` | none | side-loops ungated (P2) |
| `recordCopyrightClearance()` | legal only | non-legal = form-only (P3) |
| `LegalDocForm::submit` | route `_custom_access` + advance re-check | ✅ (the one well-gated path) |
| `EditorialClaimService::claim()` | `eligible_reviewers` membership | ✅ but **claim isn't required to advance** (P8) |
| Entity CRUD (JSON:API/REST/Views) | none — **no entity access handler** | programmatic bypass (P6) |

Secondary gaps: the three gates are **not composable** (three `can()` signatures; `LegalGate` alone
**lacks the sole-eligible fallback** the others have, so an unseeded Copyright/Shepherds guild
*hard-locks* legal) (P4); button-visibility duplicates gate logic the service should own (P5);
`promote…` permissions are defined but never checked and `transition editorial revision` is granted
to nobody (P7); guilds are resolved by **mutable label string**, not machine id (P7); no `unilateral`
audit stamp is persisted (P8).

**Correct scoping:** the P68 *legal* graded gates (edit/clear/push/approve) **are** enforced inside
`advance()` and are **not** bypassable — so this is not a P68 merge blocker. It is a hardening of the
*general* pipeline that every other atom type flows through.

## 2. Design principles (sourced)

1. **Complete mediation, fail-closed** (Saltzer & Schroeder; OWASP A01): authorize *every* call to a
   mutation, default **DENY**. A whitelist pool check that denies-when-uncertain fails *closed*.
2. **Authorize in the domain, not the UI** (OWASP A01 / API5:2023 "Missing Function-Level Authz";
   confused-deputy): the service is the security boundary; `TransitionForm` `#access` is cosmetic.
3. **One policy object, reused everywhere** (Symfony Voter/Workflow-`guard`; OWASP "implement once,
   reuse"): every transition routes through a single authorizer that the UI *also* consults.
4. **Proper Drupal trinary access** (Access API): return `AccessResultInterface`, `neutral` for ops
   you don't own, **forbidden wins**, always `->isAllowed()` (never truthy-test the object), attach
   cache contexts.
5. **Person-based separation of duties** with an **explicit, logged bootstrap override** (four-eyes /
   ISO 27001 A.5.3): author/prior-actor can't approve; the empty-pool case is a *named, audited*
   unilateral exception, never a silent fall-through.
6. **CSRF + confirm on state-changing routes**; **tamper-evident audit** of every attempt
   (allow/deny/override); **test the programmatic-bypass path** as a first-class negative test.

## 3. The design — a single `TransitionAuthorizer` choke-point

### 3.1 One authorizer, consulted by every mutator and by the UI
Introduce `TransitionAuthorizer` (new service) with one method:

```php
// Returns a Drupal trinary result; default outcome is forbidden().
public function authorize(
  EditorialRevision $rev,
  string $action,            // advance | clear | request_revision | escalate | reject | hotfix
  AccountInterface $actor,
  ?string $toState = NULL,   // for advance: the computed next state
): AccessResultInterface;
```

It composes, **forbidden-wins**, in order:
1. **Data preconditions** (existing): `copyright_cleared` before leaving clearance; hotfix reason.
2. **General stage-pool eligibility (the P1/P2 fix):** the actor must be in
   `PoolResolver::resolve($rev)` for `$rev`'s current state — **reuse `resolve()` verbatim** so the
   `applySeparation()` unilateral / sole-eligible fallback and the advisory-when-unseeded behaviour
   are honoured *exactly* (no new fallback logic, no deadlock).
3. **Graded action gate:** consult the one applicable gate for `(atom_type, change_kind, from→to)`
   via a new uniform `GateInterface` (§3.2).
4. **Separation of duties:** already inside `resolve()` (author/prior-actor exclusion); made
   person-based + multi-account-resistant (§3.4).
5. **Optional claim precondition:** if `require_claim_to_advance` is set for the stage, `actor ==
   claimed_by` (P8). Default off; recommend on for legal/theology.

**Every mutator calls `authorize()` first and throws on deny** — `advance()`, `transition()` (made
`private` or guarded — P2), `recordCopyrightClearance()`, `requestRevision()`, `escalate()`,
`reject()`, `markAsHotfix()`. The `TransitionForm` calls the *same* `authorize()` to decide button
visibility, so UI and domain never drift (§ principle 3). `TrialFeedbackHandler` must pass a real
`AccountInterface`, not a caller-supplied `reporter_uid`.

### 3.2 Unify the three gates behind `GateInterface`
```php
interface GateInterface {
  public function applies(EditorialRevision $rev, string $from, string $to): bool;
  public function authorize(EditorialRevision $rev, string $from, string $to, AccountInterface $a): AccessResultInterface;
  public function requirement(EditorialRevision $rev, string $from, string $to): string;
}
```
Refactor `LegalGate` / `TheologyGate` / `AudienceFitGate` to implement it; register them in a
tagged-service collection the authorizer iterates. **Fix P4:** give `LegalGate` the same
sole-eligible/advisory fallback the others have — *but* for legal/doctrinal the bootstrap override is
gated higher (§3.3). Resolve guilds by **machine id / config key**, not human label (P7).

### 3.3 The bootstrap override — explicit, gated, audited (not silent)
When `resolve()`/a gate would allow only via the empty-pool fallback, the authorizer returns an
**explicit `unilateral` allow outcome** that:
- **persists a new `unilateral` field** on the revision (records that no separate reviewer existed);
- **writes an audit record** (§3.5) tagged `override=unilateral` with the reason;
- for `change_kind=legal` (and core/contrast doctrine), **requires an elevated permission**
  (`bypass editorial separation`) + the confirm-form step (§3.4) — the highest-stakes exceptions get
  the loudest gate. Default for ordinary content stays the existing frictionless sole-member proceed.

This keeps the default fail-closed (four-eyes required) while preserving the operator-bootstrap
reality as an *affirmatively-granted, recorded* exception (best-practice §5).

### 3.4 Belt-and-suspenders: entity access + route + CSRF
- **Add an `EntityAccessControlHandler` for `EditorialRevision` (+ `EditorialArtifact`)** whose
  `update`/state-change `checkAccess()` delegates to `TransitionAuthorizer` (returns `neutral` for
  ops it doesn't own). **This is the fix for P6** — it closes JSON:API/REST/Views-bulk/programmatic
  paths that never touch `advance()`. If JSON:API is ever enabled, also ship an explicit deny.
- **Route access:** add `_entity_access: 'editorial_revision.update'` (or a `_custom_access`
  consulting the authorizer) to the transition route, alongside the existing `_permission`.
- **CSRF/confirm:** the `TransitionForm` is a Form API form (has `form_token` — good). Any
  direct-link transition needs `_csrf_token: 'TRUE'` + `_csrf_confirm_form_route` (a `ConfirmFormBase`
  redirect, the `user.logout` pattern) — which doubles as the deliberate confirmation gate for
  high-stakes advances.
- **Install grants (P7):** grant the coarse `transition editorial revision` to a broad
  "editorial participant" role (the *fine* authority is then the authorizer's job), and either wire
  or delete the dead `promote…` permissions.

### 3.5 Audit every attempt (tamper-evident)
Extend the existing transition logging into an **append-only, hash-chained** audit record for every
`authorize()` call: `actor, revision, from→to, action, decision(allow/deny/unilateral), deciding rule,
before/after state, timestamp`. Log **denials and failures** (OWASP A01), not just successes; anchor
the chain off-host. This is the compliance bar for legal/doctrinal governance (SOX/17a-4-analogous).

## 4. What MUST be preserved (do not regress)
The unilateral/sole-eligible fallback (`applySeparation` L153-156), the `prior_actors` copyright-
reviewer exclusion, the advisory pass when a guild is unseeded/empty (Theology/Audience), author-
re-inclusion-when-sole, and the two-tier theology approve→confirm sequencing. The hardening routes
P1-P3 **through** these — it must never hard-fail a stage that legitimately has no separate reviewer,
or it will **deadlock the pipeline** (four-eyes-bottleneck anti-pattern).

## 5. Phased plan (each phase ships with tests; sensitive → two-person review)
0. **Instrument + prove the gap.** Add the direct-service-call negative tests that currently *pass a
   transition they shouldn't* (red), and add decision audit logging. No behaviour change.
1. **Core choke-point.** `TransitionAuthorizer` + general pool check in `advance()`; make
   `transition()` private/guarded. Routed through `resolve()` (fallbacks preserved).
2. **Side-loops + gate unification.** Guard `requestRevision/escalate/reject/hotfix` +
   `recordCopyrightClearance` (non-legal); `GateInterface`; fix `LegalGate` fallback; machine-id
   guild lookup.
3. **Entity/route/CSRF layer.** Entity access handler + `_entity_access` + confirm-form + JSON:API
   deny + install permission grants.
4. **Audited override + tamper-evident trail.** Persist `unilateral`; hash-chained off-host audit;
   elevated bar for legal/doctrine.

## 6. Tests (both polarities — the regression guard is as important as the gate)
- **Negative, via direct service call (not the form):** vertical escalation (junior advances a
  mentor-gated stage), horizontal/IDOR (advance a revision you have no role on), self-review (author
  approves own), each side-loop mutator, the entity-access/JSON:API path — **all must deny.**
- **Positive regression:** a correctly-graded pool reviewer still advances; the bootstrap override
  still works when no separate reviewer exists (no deadlock); the Wave-5 course suite (91/91) + the
  113-scenario narrative suite still pass (both call `advance()` with seeded actors — the check must
  accept them).

## 7. Open questions
1. Should legal/doctrine bootstrap override be *possible at all*, or should those stages **hard-block**
   until a real second reviewer exists (accepting deadlock as the safe default for the highest-stakes
   docs)? *Recommend: possible but elevated-permission + confirm + loud audit.*
2. Make `require_claim_to_advance` the default for which stages?
3. Audit store: reuse the existing pipeline_audit tables + add hash-chaining, or a dedicated
   append-only store?
