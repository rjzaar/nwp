# ADR-0026: The `nwp-server` AI-Free Capability Agent

> **Renumbering note (2026-07-02).** This ADR was originally filed as a second,
> duplicate **ADR-0024**. By operator decision (2026-07-02, nwp/ops#28) it is
> renumbered **ADR-0026** and re-scoped: it defines the **`nwp-server` AI-free
> capability agent** — its capability set, build target, and three-key credential
> ledger. **Routine real-production deploy authority belongs to
> [ADR-0024](0024-self-deploying-prod-supersedes-verifier.md)** (self-deploying
> prod via a protected runner resident on the prod host), which is canonical for
> the deploy-authority question. This agent's deploy-apply authority is the
> **live-test tier** (per the 2026-07-01 operator grant recorded in ADR-0024) plus
> the documented **escalation / reserve path** for real prod.

> **Naming note.** This ADR renames the build target ADR-0022 called `nwp-verifier`
> to **`nwp-server`**, to match the role it actually performs: the host pulls,
> verifies, and *applies* signed bundles itself, rather than being written to by a
> separate offline verifier host. The build-time AI-free guarantee, the
> reproducible build, and the hardware-rooted signing of ADR-0022 are inherited
> unchanged — only the role and the name evolve. References to `nwp-verifier` in
> ADR-0019/0022 should be read as the predecessor of `nwp-server`.

**Status:** Accepted (renumbered from a duplicate 0024, 2026-07-02) —
**decision A14 resolved in favour (2026-06-29):** hosts MAY verify-and-apply their
own signed deploys via the `nwp-server` agent, **within the tier scope above**:
the live-test tier now, and the escalation/reserve path for real prod. Routine
real-prod deploy authority is governed by
[ADR-0024](0024-self-deploying-prod-supersedes-verifier.md). This amends
ADR-0017's "the verifier is the sole prod-writer; prod runs no deploy logic."
The offline `verifier` role is retained for hardware-gated/irreversible actions
and as a fallback (see §"Naming reconciliation").
**Date:** 2026-06-28 (A14 resolved 2026-06-29; renumbered + re-scoped 2026-07-02)
**Decision Makers:** Robert Karsten Zaar
**Related Issues:** nwp/ops#4 (Session D); nwp/ops#23 (field validation);
nwp/ops#28 (ADR-0024 duplicate reconciliation); the prod-participation capability set
**References:** [ADR-0017](0017-distributed-build-deploy-pipeline.md),
[ADR-0019](0019-verifier-always-on-hardware-rooted-keys.md),
[ADR-0022](0022-nwp-verifier-binary-split.md),
[ADR-0024](0024-self-deploying-prod-supersedes-verifier.md) (deploy authority),
[ADR-0025](0025-production-backup-to-ver.md) (backup verb),
`~/central/nwc-internal/reeval-2026-06-11/08-VISION-PRINCIPLES-AND-CONTROL-PLANE.md` (§K, §V),
OPERATING-MODEL.md §5,§6.

## Context

ADR-0017 establishes a strict pipeline: an AI-capable build/test/sign tier
produces signed artifacts; an **offline-by-default verifier host** is the
*sole* writer to production — it verifies signatures locally and pushes to prod
over a dedicated one-to-one WireGuard tunnel. Production hosts run user-facing
sites and do **not** run deploy logic; they are written *to*.

ADR-0022 then establishes that the verifier must run a **separately-built binary**
(`nwp-verifier`) that contains *no AI, CI, or SaaS code at all* — a build-time
guarantee, because a runtime feature flag cannot make code absent. The AI-free
property is achieved by building from the shared source tree with the
`lib/ai/`, `lib/ci/`, `lib/saas/` modules **excluded from the artifact**.

Two pressures motivate revisiting the "prod is written-to, never self-applies"
shape of ADR-0017:

1. **Operational latency and the offline verifier.** The verifier host is offline
   by default and connects only while actively deploying. Routine, low-risk
   applies (a security patch the loop already produced and a human already
   approved) still require bringing the verifier online, verifying, and
   tunnelling. For a growing fleet this serialises every apply through one
   offline laptop.
2. **The control-loop vision (08 §V, OPERATING-MODEL §6).** The self-healing loop
   is: `pl status` 🔴/🟠 → issue → loop auto-fix (issue→MR) → **human merge
   approval** → signed bundle → **prod pulls + verifies + applies** → re-test →
   `pl status` re-checks. That loop wants the production host to be an active
   participant that *pulls and applies* a bundle it has independently verified —
   not a passive target.

The question A14 decides: **may the production host itself verify a signed bundle
and apply it**, given that doing so adds deploy logic to a prod box?

The hard constraint is unchanged from ADR-0017/0022 and CLAUDE.md: **no
AI-accessible machine may write to prod, and no AI code may be present on a host
with production-write capability.** A prod host that self-applies now *has*
production-write capability over itself — so it must carry **zero AI code** and
**zero credentials that reach the control plane or any other prod host.**

## Decision

Adopt the **`nwp-server`** agent: a minimal, separately-signed, AI-free build
target (the ADR-0022 `nwp-verifier` target, renamed and re-scoped) that runs **on
each host it serves** and lets that host verify-and-apply its own deploys. This
amends ADR-0017's "verifier is the sole prod-writer" to "**a signed, AI-free agent
on the host is the writer to *that host*; it pulls only signed bundles it
independently verifies.**" The offline verifier role is retained as a
defence-in-depth option and for the irreversible, hardware-token-gated actions of
ADR-0019.

**Tier scope (2026-07-02 reconciliation).** The agent's *capability set* is
defined here; its *deploy-apply authority* is tiered:

- **Live-test tier:** the agent may self-deploy now, per the 2026-07-01 operator
  grant (recorded in ADR-0024's header).
- **Real user-facing production, routine deploys:** governed by
  [ADR-0024](0024-self-deploying-prod-supersedes-verifier.md) (the
  runner-resident model) once its preconditions land; until then the offline
  deploy host + hardware token (ADR-0017) remains the gate.
- **Real production, escalation/reserve:** the agent is the documented
  escalation / reserve path (offline signature re-verification and
  hardware-gated applies) if ADR-0024's escalation triggers fire.

### Same trust tier, same build target — NOT a new repo

`nwp-server` is **a build target of the `nwp` source tree**, per ADR-0022 (which
rejected both the same-binary-with-flags option and the four-binaries option). It
is **not** its own repository. A separate repo would add version skew without
adding to the guarantee — the guarantee is *build-time exclusion*, which a build
target already provides. The AI-free property is mechanical: the AI/CI/SaaS
modules are absent from the artifact.

### Capability set (and nothing else)

`nwp-server` exposes exactly these verbs on the prod host, mapping to existing
shared modules:

| Verb | What it does | Reuses |
|------|--------------|--------|
| `pull+verify` | fetch a signed bundle from the self-hosted git/artifact host over public HTTPS; minisign-verify locally; verify the payload/scripts SHA-256 against the manifest | `lib/minisign.sh`, `lib/bundle-verify.sh` |
| `apply` | apply the verified bundle in canonical order, enter maintenance, run, and **roll back on failure** — this host only | `lib/rollback.sh` |
| `snapshot → sanitize → verify → publish` | snapshot this host's DB, run the per-site sanitizer, **fail-closed PII gate**, then publish the sanitized artifact to *its own* repo | `lib/sanitizers/*`, **`lib/pii-gate.sh`** |
| `rollback` | restore the previous release/DB on this host | `lib/rollback.sh` |
| `status` | emit local health as JSON for the control plane to read | `scripts/commands/status.sh` (local-only subset) |

The **fail-closed PII gate** between sanitize and publish is mandatory: any PII
match aborts the publish (this is the same `lib/pii-gate.sh` the `pl onboard`
chain uses; see nwp/ops#4 checkbox 1). Raw user data never leaves the prod host;
only a gated, sanitized artifact is published.

### Credential ledger on prod (the inviolable part)

`nwp-server` holds **exactly three** credentials, and nothing else:

1. a **read-only deploy key** — pull signed bundles (inbound, one-way);
2. a **write-only-to-its-own-repo deploy key** — publish the sanitized artifact
   (outbound, one-way; optionally locked with an `authorized_keys` forced
   `command=`);
3. the **minisign public key** — verify bundle signatures.

**Zero** Personal Access Tokens, **zero** control-plane credentials, **zero** keys
that reach another prod host. Both data directions are one-way. A compromise of a
prod host therefore cannot pivot to the control plane, to another prod host, or to
any AI-capable machine — the blast radius is that single box.

### Naming reconciliation

- The ADR-0022 build target `nwp-verifier` is **renamed `nwp-server`** to reflect
  the self-deploying-prod role. Build target: `scripts/build-nwp-server.sh` /
  `pl build-server` (this ADR's companion implementation under nwp/ops#4
  checkbox 2). `--version` reports `nwp-server vX.Y.Z`, distinct from `nwp`.
- ADR-0019's hardware-rooted signing of the artifact is unchanged.
- ADR-0017's offline-verifier role is **retained**, not deleted: it remains the
  sole path for irreversible, hardware-token-gated actions, and a fallback when a
  prod host cannot be trusted to self-apply.

## Rationale

- **Build-time, not runtime.** A self-applying prod host raises the stakes of the
  AI-free property; ADR-0022's build-time exclusion is exactly what makes it safe.
  The renamed target inherits that mechanism verbatim.
- **One-way credentials bound the blast radius.** Read-only-in, write-only-out,
  no lateral keys — this is the property that lets a prod box self-deploy without
  becoming a pivot point. It is the prod-side analogue of "trust flows through
  signatures, not machines" (CLAUDE.md).
- **The loop needs an active prod endpoint.** OPERATING-MODEL §6's self-healing
  loop terminates at "prod pulls + verifies + applies." Without `nwp-server` that
  step is a manual, offline-verifier operation; with it, routine applies close the
  loop automatically while merges stay human-gated.
- **A14 is the gate, not this ADR.** Granting verify-and-apply to prod is the
  operator's decision (hardware token / WebAuthn merge approval boundary). This
  ADR specifies *how* to do it safely if A14 says yes; it does not pre-empt A14.

## Consequences

### Positive
- Routine applies no longer serialise through one offline laptop.
- The control loop has a real prod endpoint; `pl status` → fix → approve → apply →
  re-check becomes mechanical.
- Inherits ADR-0022's reduced attack surface and reproducible, auditable build.
- The credential ledger makes a prod compromise non-pivoting by construction.

### Negative
- Prod hosts now run deploy logic (more code on prod than ADR-0017's pure target).
  Mitigated by the minimal capability set, the AI-free build, and the
  three-credential ledger.
- Two writer paths exist (the offline verifier for hardware-gated/irreversible;
  `nwp-server` for routine). The runbook must state clearly which path each
  action takes.
- A second rename of a still-Proposed ADR-0022 target; F34's role-label cleanup
  must account for `nwp-verifier` → `nwp-server`.

### Neutral
- The build mechanism (allowlist + fail-closed deny-symbol scan) is shared with
  the ADR-0022 target; only the included capability set and the name differ.

## Implementation Notes

- Build target: `scripts/build-nwp-server.sh`, invoked as `pl build-server`
  (nwp/ops#4 checkbox 2). Allowlist-driven (include only the capability modules),
  with a **fail-closed deny-symbol scan** that fails the build if any AI/CI/SaaS
  vendor token appears in the assembled artifact — the mechanical form of
  ADR-0022's `strings`-check success metric.
- The physical `lib/ai/`, `lib/ci/`, `lib/saas/` partition (the 08 K1.1/K1.2
  prerequisite) is a follow-up migration; the allowlist already encodes the
  boundary, so the reorg is mechanical and verifiable against the deny scan.
- Reproducible-build documentation (base image, commands, expected hashes) tracks
  ADR-0022's `docs/reference/reproducible-build.md`.

## Migration Path

**A14 resolved in favour (2026-06-29).** `nwp-server` is cleared to be installed on
a host *with apply authority* (within the tier scope above) once two build-out
gates are met:
1. The capability set is assembled and `pl build-server` passes the fail-closed
   deny-scan (apply/rollback/publish/config-resolution libs landed on
   `feat/nwp-server-buildout`; the LOCAL `status` verb has since landed and was
   exercised in the 2026-07-02 field validation below).
2. The three-key, one-way credential ledger is provisioned on the target host.

Until both gates are met on a real production host, `nwp-server` is **built and
audited** but the offline `verifier` path stays the active real-prod writer. The
`lib/ai|ci|saas` physical partition is no longer a hard prerequisite — the
allowlist already excludes those modules by construction — but remains worthwhile
for repo hygiene.

## Validation record (2026-07-02)

The agent was field-validated on **2026-07-02** (nwp/ops#23) on a **disposable
prod-boundary test host**, deployed exactly as it would be on real prod:
**artifact only** (no full `nwp` tree), the **three-key ledger**, **no PAT, no
AI**. The full signed cycle ran end-to-end:

- **pull** — signed bundle fetched and verified fail-closed (minisign +
  payload/scripts SHA-256 against the manifest);
- **verify** — standalone verification, including a **tamper negative-test**: a
  deliberately corrupted bundle was correctly **rejected**;
- **apply** — dry-run (no mutation) then execute; a real code deploy took effect;
- **rollback** — re-applying the previous bundle restored the prior state;
- **status** — local JSON reflected real site state.

### Known defect: the `publish` verb is mis-wired (open)

As shipped, `nwp-server publish` routes to the **build-tier registry uploader**:
it expects a full-`api` Personal Access Token and **never invokes the
snapshot → sanitize → fail-closed PII gate** chain this ADR specifies. That
violates the three-key credential ledger (a PAT must never exist on an
agent host) and does not deliver the sanitized-publish capability. **The
`publish` verb MUST NOT be used until a prod-side
snapshot → sanitize → PII-gate → publish implementation replaces the mis-wired
routing.** Tracked as open work in nwp/ops#23.

## Review

**30-day review:** 2026-07-28. **Success metrics:**
- `pl build-server` produces an artifact whose deny-symbol scan returns zero AI/CI/
  SaaS matches (the mechanical AI-free check).
- The capability set is exactly the verbs above (plus the ADR-0025 `backup`
  verb) — no `install`, no `ai *`, no `ci *`, no SaaS clients.
- The credential ledger on any `nwp-server` host is exactly three keys, all
  one-way.

## Related Decisions

- [ADR-0017](0017-distributed-build-deploy-pipeline.md) — establishes the verifier
  role and the AI-free constraint that this ADR amends.
- [ADR-0019](0019-verifier-always-on-hardware-rooted-keys.md) — hardware-rooted
  signing, inherited unchanged.
- [ADR-0022](0022-nwp-verifier-binary-split.md) — the build-time AI-free split;
  this ADR renames and re-scopes its `nwp-verifier` target to `nwp-server`.
- [ADR-0024](0024-self-deploying-prod-supersedes-verifier.md) — canonical for
  routine real-prod deploy authority (runner-resident model); records the
  2026-07-01 live-test-tier grant under which this agent applies today.
- [ADR-0025](0025-production-backup-to-ver.md) — the `backup` verb that extends
  this agent's capability set.
