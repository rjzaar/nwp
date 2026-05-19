# ADRs — Architecture Decision Records

**Audience:** Coder, recognizing which ADRs apply to a PR under review.
**Status:** v1 — 2026-05-20.
**Read time:** 10 minutes (or look up by number as needed).

This is the reviewer's index of NWC's architectural decisions. Each entry summarizes one ADR — what it decided, why it was decided, and which kind of PR makes you want to check it.

The full ADRs live at `~/nwp/sites/nwc/dev/html/profiles/custom/nwc/docs/decisions/adr-XXXX-*.md`. This page is the cheat sheet.

If you only remember three things:

1. **A PR that contradicts an ADR is at minimum a T3.** It needs a new ADR superseding the old one. No quiet contradictions.
2. **An ADR is amended, not edited.** If a PR's diff includes changes to an existing ADR file (other than a `Superseded by: ADR-XXXX` line), reject and ask for a new ADR.
3. **When in doubt, check whether the ADR is `Accepted` or `Superseded`.** Superseded ADRs document history; Accepted ones constrain new code.

---

## Decisions affecting most PRs

### ADR-0001 — NWC is the platform
**Status:** Accepted. **Touches:** anything claiming to be "the framework".

Decision: NWC is a real, named product with a canonical deployment. It is not a generic CMS framework. Forks are allowed but must rename. PRs that try to "generalize" NWC into something reusable should be pushed back.

**You'll see this when:** an agent PR refactors `nwc_*` modules into something prefix-neutral. Reject — that's scope creep against a settled decision.

---

### ADR-0010 — Decision Log visibility tiers
**Status:** Accepted. **Touches:** `nwc_decision_log`, anything that publishes "decisions".

Decision: The public Decision Log has three tiers — `Stewards`, `Members`, `Public`. Stewards-only content must never become member-visible by accident. The default visibility for new decision-log nodes is `Stewards`; broadening to `Members` or `Public` is an explicit per-node act.

**You'll see this when:** PR touches `field_visibility_tier` defaults or modifies the access check in `nwc_decision_log`. Watch for defaults silently shifting.

---

### ADR-0015 — Two-site topology
**Status:** Accepted. **Touches:** any cross-site config, `field_content_visibility`.

Decision: NWC runs as `nwc.nwpcode.org` (canonical) + `nwd.nwpcode.org` (demo). Both are first-class production. Both deploy from the same repo via the parallel-install pattern (see ADR-0016). Saint School (Moodle) is paired: `ssc` ↔ `nwc`, `ssd` ↔ `nwd`.

**You'll see this when:** a PR fixes something in `nwc` but doesn't mention `nwd`. Ask explicitly: does this apply to both? If the diff is profile-local, it auto-applies via the rsync; if it touches infra (nginx, ddev), check both.

---

### ADR-0016 — `nwd` deployment pattern (parallel install)
**Status:** Accepted. **Touches:** deploy pipeline, profile changes.

Decision: `nwd` deploys by *rsyncing* the same `profiles/custom/nwc/` tree into the `nwd` codebase, not via Drupal multisite. Both sites share zero runtime state. The deploy pipeline does this rsync automatically; PRs against `nwp/nwc` apply to both.

**You'll see this when:** the deploy pipeline log shows two rsync steps. If one fails, both should fail — never silently deploy to only one.

---

## Decisions affecting editorial PRs

### ADR-0020 — Editorial state machine
**Status:** Accepted. **Touches:** `nwc_editorial`, anything modifying `EditorialStateService`.

Decision: All state transitions of `editorial_revision` go through `EditorialStateService::advance()`. Direct writes to the `state` field are forbidden. Guards (copyright, hotfix justification, trial completion) live in the service, not in callers.

**You'll see this when:** any change to `nwc_editorial/`. Look for `$rev->set('state', ...)` outside the service — that's an immediate reject.

---

### ADR-0021 — Template-driven stage skipping
**Status:** Accepted. **Touches:** `EditorialRevision::CHANGE_*` constants, `getStagePath()`.

Decision: A revision's `change_kind` (typo, pedagogical, doctrinal, hotfix, etc.) determines which review stages it skips. Templates are defined in `EditorialRevision` constants; adding a new template is a T3 decision.

**You'll see this when:** PR adds a new `CHANGE_*` constant or modifies `EditorialStateService::getStagePath()`. Requires ADR amendment.

---

### ADR-0022 — Trial feedback A1–E3 classification
**Status:** Accepted. **Touches:** `nwc_trialing_guild`, `TrialFeedbackHandler`.

Decision: Trial feedback uses a fixed A1–E3 classification mapped to four outcomes (`fold`, `revise`, `halt`, `escalate`). The classification table is part of the contract; new classes can be added but existing ones cannot be reassigned without a superseding ADR.

**You'll see this when:** PR changes `TrialFeedbackHandler::classify()` or its lookup table. Adding a new class is T2; reassigning an existing one is T3.

---

### ADR-0023 — Copyright clearance gate
**Status:** Accepted. **Touches:** `nwc_copyright`, `nwc_copyright_guild`.

Decision: A revision cannot leave `in_copyright_clearance` without a recorded clearance (justification text + cleared-by user + timestamp). Enforced by `EditorialStateService::advance()`. Cross-site sync to Moodle's `tool_policy` happens on `approved` transition.

**You'll see this when:** PR touches the copyright gate or the Moodle sync trigger. Removing the gate or making clearance optional is a T3-level architectural concern.

---

## Decisions affecting cross-site PRs

### ADR-0030 — Cross-site POST authentication (shared secret)
**Status:** Accepted. **Touches:** `nwc_feedback`, cross-site bridge routes.

Decision: Cross-site POSTs (Moodle → Drupal, Drupal → Moodle) authenticate via a shared secret in the `X-NWC-Shared-Secret` header, not OAuth. This is because OAuth's interactive auth code flow can't be used for server-to-server batched POSTs. The simple_oauth interceptor must be bypassed on these routes via `_oauth_skip_auth: TRUE`.

**You'll see this when:** PR adds or modifies a cross-site route. If `_oauth_skip_auth` is missing, the route returns 401 before the controller runs — request changes.

---

### ADR-0031 — Moodle plugin compatibility
**Status:** Accepted. **Touches:** `local-nwc-copyright-sync`, `auth-nwc-oauth2`.

Decision: Moodle plugins must be schema-defensive across Moodle 4.x minor versions. Use `$DB->get_columns()` to detect schema and adapt; never assume a column exists. Moodle 4.4 moved `tool_policy.name` → `tool_policy_versions.name`; future minor versions may move more.

**You'll see this when:** PR touches Moodle plugin code. Look for raw `$DB->set_field('tool_policy', 'name', ...)` — should be guarded by a schema check.

---

### ADR-0032 — OAuth as SSO mechanism
**Status:** Accepted. **Touches:** `nwc_oauth_bridge`, `auth-nwc-oauth2`.

Decision: NWC Drupal is the OAuth issuer; Saint School Moodle is the client. Token lifetime is 1 hour; refresh 30 days. Auth-related PRs are auto-T3 and require Rob.

**You'll see this when:** any PR touching OAuth scopes, token lifetimes, or client registration. Always page Rob for these.

---

## Decisions affecting governance + audit PRs

### ADR-0040 — Governance audit completeness
**Status:** Accepted. **Touches:** `nwc_governance`.

Decision: Every state transition, every approval, every deploy stage must write a `governance_action`. Audit writes are part of the transaction — if the audit fails, the action rolls back. Removing or weakening audit writes is a regression even if tests pass.

**You'll see this when:** PR touches `EditorialStateService` or `deploy-on-merge.sh`. Look for missing `governance_action::create()` calls relative to the actions taken.

---

## Decisions affecting deploy / infrastructure PRs

### ADR-0050 — Deploy pipeline stages + tier gate
**Status:** Accepted. **Touches:** `~/nwp/scripts/agent-loop/`, `pl` commands.

Decision: The pipeline runs dev → stg → tier-gate → live with smoke checks at each stage. T1 + T2 auto-promote to live; T3 stops at stg. Snapshots taken before every `stg2live`. Auto-rollback on smoke failure.

**You'll see this when:** PR touches `deploy-on-merge.sh`, `pl` commands, or smoke check URLs. These are T3 infrastructure changes.

---

### ADR-0051 — Pause loop, not break loop
**Status:** Accepted. **Touches:** `agent-loop.sh`.

Decision: The agent loop has a single-file kill switch (`/home/rob/nwp/.loop-paused`). Any other way of stopping the loop (renaming scripts, removing cron entries, etc.) is forbidden — it makes resume harder.

**You'll see this when:** A PR removes or refactors the kill-switch mechanism. Reject; the simplicity is the point.

---

## Open / draft ADRs

These are decisions Rob has marked as "considered, not yet accepted". You won't see PRs against them yet.

- **ADR-0060 (draft)** — Decision Log digest emails (under design)
- **ADR-0061 (draft)** — Cross-stack search federation (Drupal + Moodle unified)
- **ADR-0070 (draft)** — Trial cohort size and selection (not in MVP)

If the agent ever opens a PR claiming to implement a draft ADR, push back hard — it's reading future intent as present commitment.

---

## How to write a new ADR (if you ever need to)

You probably won't need to author one (Rob's the architect), but if a PR is missing one and you can sketch the shape:

1. Pick the next number in sequence.
2. File at `~/nwp/sites/nwc/dev/html/profiles/custom/nwc/docs/decisions/adr-XXXX-short-slug.md`.
3. Header: `# ADR-XXXX: <Title>`, then `**Status:** Proposed | Accepted | Superseded by ADR-YYYY`.
4. Body sections: `## Context`, `## Decision`, `## Consequences`, `## Alternatives considered`.
5. Reference from PR description: `**Self-flag:** ⚠ ADR change (ADR-XXXX draft attached)`.

For agent-generated PRs, the agent should produce the ADR alongside the code change. If it didn't, that's a T3 reject.

---

## See also

- `~/nwp/sites/nwc/dev/html/profiles/custom/nwc/docs/decisions/` — the actual ADR files
- [architecture-brief.md](./architecture-brief.md) — what the ADRs are talking *about*
- [pr-review-checklist.md §6](./pr-review-checklist.md#6-special-checks-for-t3) — when to demand an ADR draft
