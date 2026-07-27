# ADR-0034: Erasure propagation from nwc (OP) to ss/ssc (RP)

**Status:** Proposed
**Date:** 2026-07-28
**Decision Makers:** operator (rjzaar) — pending
**Related Issues:** ops#81, ops#83 (UID-lock), ops#84 (moodledata scrub), ops#93 / R2.2 (zero-rows test), ops#139 (logstore)

## Context

Deleting a person on **nwc** (Drupal/Open Social, the OIDC **provider**) does nothing to their
account on **ss/ssc** (Moodle, the **consumer**). Left stranded: the `mdl_user` row and its
residual PII, grades / quiz attempts / course completions, `tool_policy_acceptances` (consent),
the `auth_oauth2_linked_login` SSO link, and `moodledata` files. This is risk 1 of 15 in
`docs/reports/intersite-contract-research-2026-07-10.md` §4, and DPIA risk R5.

An Art. 17 obligation lands the day a real member asks — regardless of what is automated. That
timing constraint, not the technology, drives this decision.

**Prior art already in the tree** (this ADR ratifies and completes it rather than starting
fresh): commit `272e352` staged both channel halves — `scripts/moodle/local_nwc_erase`
(receiver: Privacy-API delete, bearer/IP/issuer guard, idempotent on `request_id`, audit log
storing the UUID and never an email, 26 unit tests) and `scripts/drupal/nwc_moodle_erase`
(sender: `hook_user_predelete` → queue → cron drain → Bearer POST). `pl erasure
plan|execute|verify|status|list` exists and fails closed in four documented stages. The design
narrative is `docs/guides/ops81-erasure-channel.md`. **Both halves are staged, not deployed**,
`enabled` defaults off, and the Art. 17 semantics are unapproved.

**Correcting the record:** `REMEDIATION-PLAN.md` R2.1 and ops#81 note 1796 both state the
sender "does not exist". That was true when written (2026-07-25 note; the plan predates it) but
the sender landed 2026-07-11. The remaining work is *deploy, approve, prove* — not *build*.

## Options Considered

### Option A: OpenID Provider Commands

The emerging standard designed for exactly this: an OP POSTs a signed Command Token to an RP
Command Endpoint; `delete` is a defined command, and Command Tokens reuse the ID Token schema
and verification.

- **Pros:** purpose-built and right-shaped; interoperable if the ecosystem adopts it;
  vendor-neutral; our bespoke message is already close to its shape, so later migration is
  cheap.
- **Cons:** **draft-02, dated 25 September 2025** ([spec](https://openid.net/specs/openid-provider-commands-1_0.html)),
  Standards Track but *not* ratified — no Final or Implementer's Draft status, and the search
  surfaced no 2026 status change. Neither `simple_oauth` (Drupal) nor Moodle ships a Command
  Endpoint, so we would implement both ends anyway *and* track a moving spec. Building a
  legally-required control on an unratified draft means re-doing it when the draft moves.

### Option B: signed NWP-native erasure message over the existing intersite contract machinery

A bespoke command that borrows Provider Commands' *shape* (signed, `sub`-keyed, idempotent,
audited delete instruction) and rides transport NWP already runs in production for
`copyright_sync`: Guzzle POST → plain Moodle endpoint, `Authorization: Bearer`, IP allowlist,
JSON body, idempotency guard. Pinned by `contracts/erasure.command.schema.json` (P74 Phase-0),
sha-pinned from the pair contract, minisign-signed.

- **Pros:** reuses a live, reviewed transport and the P74 schema + minisign trust model; no
  dependency on a moving spec; already built and unit-tested; keeps the door open to swap in
  Provider Commands later because the message shape is deliberately similar.
- **Cons:** bespoke, so no ecosystem interop; we own the security review of a remotely-triggerable
  delete; needs its own conformance tests.

### Option C: operator-runbook-only (manual paired erasure)

No channel. On an Art. 17 request the operator runs the Drupal erasure, then separately runs a
Moodle Privacy-API delete, then verifies both.

- **Pros:** available today with existing tools; zero new attack surface; no remotely-triggerable
  delete endpoint exists to be abused.
- **Cons:** unbounded latency and human error on a legal deadline; no machine proof both halves
  ran; does not scale past a handful of members; the two halves can silently diverge.

## Decision

**Adopt Option B, on a staged path, with Option C as the standing fallback that is never
retired.**

1. **Now — C is the operating procedure.** `pl erasure plan` builds and schema-validates the
   command and ledgers it; the operator executes both halves by runbook
   (`docs/guides/ops81-erasure-channel.md` §6). This is what answers a request received
   tomorrow.
2. **Next — deploy B behind its kill switch.** Install receiver and sender, `enabled` off, on
   dev/stg first. Requires the two-person review the receiver README mandates.
3. **Then — approve semantics and prove it.** Operator sets `semantics_approved` (an Art. 17
   lawful-basis judgement about anonymise-vs-delete and which aggregates are lawfully retained
   — an agent must not settle it), and ops#93 / R2.2's end-to-end zero-rows test goes green.
   Only then does the channel go live on a real tier.
4. **Later — reassess Provider Commands** when it reaches Implementer's Draft or Final and a
   Moodle/Drupal Command Endpoint exists.

**C is never retired.** Automation that has failed silently is worse than no automation on a
legal deadline, so the runbook remains the documented fallback.

### Identity anchor

`sub` = the Drupal account **UUID** = `mdl_user.idnumber` (the ops#83 UID-lock). The receiver
resolves **strictly by `idnumber == sub`, never by email** — Moodle stock `auth_oauth2` links on
email, and email is recycling- and confusable-unsafe. Pinned in
`contracts/erasure.command.schema.json`.

### Idempotency

`request_id` is the idempotency key. A replayed `request_id` is a **200 no-op, never a second
delete**; an unresolvable `sub` is also a 200 no-op (already gone). Transport errors requeue;
malformed items are dropped rather than retried forever. This is what makes the channel safe to
re-POST after a 502.

### What Moodle actually deletes

Via `\tool_dataprivacy\api::create_data_request(DELETE)` → `approve_data_request()` →
`process_data_request_task`, which fans out every component's `delete_data_for_user()`.
Moodle's ordinary `delete_user()` is only a **soft** delete (leaves lastip, phone, address,
idnumber) and is deliberately **not** used. Covered: `mdl_user` + residual PII;
`grade_grades` / `quiz_attempts` / `course_completions`; `tool_policy_acceptances`;
`auth_oauth2_linked_login` (also deleted proactively to sever the re-link door);
`depthcontent_*` and `local_practice_*` via their own privacy providers; `logstore_standard_log`
via its core provider (ops#139 Appendix B). `moodledata` files are delegated to the ops#84
dataroot scrubber.

### What survives, deliberately

- **Consent records** (`nwc_art9_consent`) — Art. 7(1) requires the controller to *demonstrate*
  consent, so the proof must outlive the consent. Retained 6 years; `Art9ErasureService`
  already distinguishes withdrawal (`keepConsentRecords: TRUE`) from account deletion.
- **Editorial audit chain** (`nwc_editorial_audit`) — retained under Art. 17(3); its value is
  that it is unbroken. Must be disclosed in the privacy notice (decision D9).
- **Authored doctrinal content** — pseudonymised to uid 0, not deleted: community work by many
  hands, with the name severed.

These must match the DPIA's claims exactly; a divergence between what we retain and what we say
we retain is the failure mode here.

### Proof of erasure

Per request, the controller keeps: the ledger entry under `private/erasure/` (command, schema
validation, timestamps), the receiver's immutable audit row (storing the UUID `sub`, never an
email), and the `pl erasure verify` residual-row probe result. `verify` reports **CANNOT-VERIFY**
rather than "0 rows, clean" when a probe is unset — a blind check is not a clean check.

## Rationale

Three things decide it.

**The spec is not ready and we would build both ends regardless.** Option A's only real
advantage is interop, and interop requires an ecosystem that does not exist: no Command Endpoint
ships in either platform. We would write the same two plugins, plus carry the risk of a draft
that moves. Borrowing the shape without the dependency keeps the upside and drops the cost.

**The trust model permits B, and this is the part most likely to be got wrong.** "AI must never
write to prod" does not forbid an *app-to-app* call between two applications that both already
live inside the prod boundary — nwc and ss are co-resident, and the erase POST is a server-local
call made by the Drupal application, not by any AI-run machine. The AI's role ends at *authoring*
code, which reaches prod only as a signed artifact verified by the offline deploy host. The
boundary that must hold
is therefore about **who holds the token**: the prod-tier receiver token is a `ver`-held secret,
never present on an AI-accessible build or agent host, and a real prod erasure fires only behind
the `ver` Solo-touch gate. On the dev/stg/live-test tier agents may operate the channel
per A14. No polling queue is needed to satisfy the trust model — the push never originates from
an AI-accessible machine.

**The legal obligation is not contingent on the automation.** That is why C leads the staged
path and is never retired. Shipping B without R2.2 green would relocate the uncertainty rather
than remove it: FK-free tables with no cascade are exactly where erasure silently fails, and a
silent failure means telling a member their erasure completed when it did not — worse than an
error.

## Consequences

### Positive

- An Art. 17 request is answerable today by runbook and, once staged, automatically.
- The message shape is pinned, closed (`additionalProperties: false`), sha-pinned from the pair
  contract and minisign-signed — a destructive cross-site command cannot drift unreviewed.
- `pl contracts erasure` (added with this ADR) makes "does this pair have a defined, pinned,
  closed erasure channel?" a re-runnable question instead of a document.
- Migration to Provider Commands later is a transport swap, not a redesign.

### Negative

- A remotely-triggerable delete endpoint exists on the Moodle side. Mitigated by: kill switch
  defaulting off, bearer + IP allowlist + issuer check, closed schema, fail-closed on every
  guard, and mandatory two-person review before any live tier.
- We own the conformance testing that a ratified standard would have given us.
- The staged path means the automated channel is *not* the control on day one; the runbook is,
  and runbooks depend on people.

### Follow-ups

- `pairs/ssd.pair-contract.yml` pins the erasure schema but declares **neither**
  `receiver_path` nor `sender_path` — found by the new gate. Either declare both or record why
  the demo pair is exempt.
- `pairs/ssc.pair-contract.yml` comments still read `NOT BUILT` for both paths; they are built
  and staged, undeployed. Correct the comment so the contract stops asserting something false.
- Register any new schema in `contracts/validate.py`'s hand-maintained `CASES` list — `sums`,
  `sign` and `bundle` auto-discover but `validate.py` does not, so a new schema is pinned and
  signed yet silently unvalidated.
