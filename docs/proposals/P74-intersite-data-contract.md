# P74 — Intersite data contract (nwc ↔ ss) — schemas + change-impact gate

**Status:** PROPOSED — 2026-07-11. Formalises the 4-way research in
[`docs/reports/intersite-contract-research-2026-07-10.md`](../reports/intersite-contract-research-2026-07-10.md)
into an actionable, phased proposal. **Phase 0 (the JSON Schemas) is IMPLEMENTED in this same change**
(`contracts/` + wired into `pairs/ssc.pair-contract.yml`); Phases 1–3 + the open questions are proposed
work.
**Parent:** [ADR-0031](../decisions/0031-paired-site-versioning-and-promotion.md) (paired-site
versioning). This is the *data-shape + change-detection* layer ADR-0031 D5 assumed but never specified.
**Related:** [P66](P66-module-passports-scoped-ai-fixes.md) (deptrac module boundaries — reused here),
`lib/impact.sh` (fate-manifest — sibling), `lib/pair.sh` `pair_guard`.

## Problem

nwc (Drupal/Open Social — OIDC provider, copyright source, feedback sink) and ss (Moodle — OIDC
consumer, real students) share real data across a small boundary. Today the pair contract pins the
boundary at **module-version** granularity, but the things that actually break are **payload shapes**
(a renamed OIDC claim, a retyped JSON field). There is also **no commit-time detector** telling a
developer "this change is internal, ship freely" vs "this touches the boundary, coordinate." And the
boundary inventory found **three live surfaces the contract doesn't declare at all**
(role→cohort sync, badge read, the sanitizer shared-salt).

## Goal

Make it so **most changes progress freely within one site, and only a change that could affect the
other side triggers cross-site work** — driven by data (the pair contract), not hardcoded, and rooted
in signatures per the threat model. No new service, no SaaS.

## Mechanism (research §2–§3): JSON Schema, git-native, signed — NOT XML

Three layers on top of the existing pair contract:
1. **Coordination (shipped):** `pairs/ssc.pair-contract.yml` `surfaces:` (min-versions, policy, rails)
   enforced by `pair_guard` at deploy.
2. **Data-shape (Phase 0, this change):** one **JSON Schema (Draft 2020-12)** per surface in
   `contracts/`, referenced from the pair contract by path + `sha256`, validated on both sides in CI
   (Opis in PHP; `contracts/validate.py` here for the git-side check).
3. **Compatibility (Phase 3):** a CI checker enforcing expand-and-contract (BACKWARD) against the
   git-committed prior schema — a schema registry's guarantee with only git + `pair_guard`'s
   provider-first ordering.

**Rejected:** XML/XSD (both surfaces are already JSON; no impedance layer needed), Protobuf/Avro/
registry (running service — violates no-SaaS), Pact/PactFlow (best mode is SaaS-only). Full rationale
+ citations in the research report §2.

## Phase 0 — IMPLEMENTED here

`contracts/`:
- `oauth_sso.claims.schema.json` — the **closed** OIDC claim allow-list (`sub` required; the curated
  set; `additionalProperties:false` = the data-minimisation gate — adding a claim is now a
  boundary-touching change). `guilds` custom-claim shape pinned.
- `copyright_sync.record.schema.json` — the single-writer copyright POST body.
- `feedback_bridge.message.schema.json` — the Moodle→nwc feedback POST body.
- `SHA256SUMS` — the pins (fold into the minisign bundle in Phase 3 so the consumer trusts by
  signature, not host).
- `validate.py` — git-native validator (schema-valid + good/bad sample behaviour; fail-closed).

Wired into `pairs/ssc.pair-contract.yml`: each `surfaces.<name>` now carries `schema:` + `schema_sha256:`.
(`pair_guard` doesn't enforce the sha yet — that's Phase 3; the pins are inert-but-present today.)

## Phases 1–3 (proposed)

- **Phase 1 — declare the full boundary.** Add the 3 undeclared surfaces (role-sync, badge-read,
  shared-salt) to the contract; add a `boundary:` path/symbol map per surface; a manifest-honesty test
  that fails if a boundary symbol is referenced from a file outside the declared paths.
- **Phase 2 — the classifier.** `lib/boundary.sh` + `pl impact` (INTERNAL vs BOUNDARY-TOUCHING, in
  `lib/impact.sh`'s idiom) + a CI fork cloned from `lint:doc-truth` (contract-verify, a
  `contract_version`-bump gate, CODEOWNERS scoped to the boundary paths). Reuses P66's deptrac engine.
- **Phase 3 — compat + trust.** The expand-contract checker; fold `contracts/` into the minisign
  bundle; signed-artifact cross-repo sync to the Moodle plugin repos.

## Open questions (go-live prerequisites — filed as ops issues)

The research surfaced ~15 unexplored risks. The three that are **prerequisites before real students on
live** are filed separately: **GDPR erasure propagation** (no nwc→Moodle delete channel),
**OIDC issuer key-rotation runbook** (the #1 real-world SSO outage), **DR/rollback identity asymmetry**
(a DB restore renumbers uids and severs UID-locks). See research report §4 for the full ranked list
(join-integrity monitoring, `sub`-as-anchor, claim allow-list [Phase 0 addresses this], token
revocation, consent system-of-record, moodledata backups, shared-salt blast radius, …).

## Success criteria

- [x] Phase 0: 3 schemas authored, validated, wired + sha-pinned into the pair contract.
- [ ] Phase 1: 3 undeclared surfaces declared; boundary manifest + honesty test.
- [ ] Phase 2: `pl impact` classifier + CI fork + CODEOWNERS.
- [ ] Phase 3: expand-contract checker + minisign bundle + cross-repo sync.
- [ ] The 3 go-live-prerequisite open questions resolved (their ops issues closed).
