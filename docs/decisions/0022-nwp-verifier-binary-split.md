# ADR-0022: nwp-verifier Binary Split for the Verifier Role

> **Naming note.** The verifier binary is named after the role it performs (`verifier`), not after any specific host that carries the role. Earlier internal references (after the operator's own historical host name for this role) are preserved in ADR-0019; that ADR will be rewritten by [F34](../proposals/F34-role-label-proposal-rewrite.md) to use the verifier role label.

**Status:** Proposed
**Date:** 2026-05-09
**Decision Makers:** Robert Karsten Zaar
**Related Issues:** Threat-model boundary at the verifier; AI-free build-time guarantee
**References:** [ADR-0017](0017-distributed-build-deploy-pipeline.md), [ADR-0019](0019-mons-always-on-hardware-rooted-keys.md), [ADR-0020](0020-tiered-architecture-model.md), [F32](../proposals/F32-tiered-architecture-implementation.md)

## Context

ADR-0017 establishes the verifier role: a host that is the sole writer to production, runs no AI code, and stays offline by default. ADR-0019 layers hardware-rooted keys on top of that mode.

[ADR-0020](0020-tiered-architecture-model.md) introduces a single-binary architecture for NWP: `pl` runs on every host, configuration determines the role, and feature flags gate behaviour. That works cleanly for the authoring / CI / AI hosts. For the verifier it raises a question: should the same binary run there, with feature flags disabling AI / SaaS / outbound network?

The operator's threat model, formalised in CLAUDE.md and ADR-0017, requires that **AI never touches a host with production-write capability**. "Touches" includes the binary itself: even if a feature flag disables AI at runtime, the AI adapter code is *present* in the binary, importable by any process that can read the file. That code might (in some future supply-chain compromise) be loaded via library injection, called via a debugger, or invoked by a side-channel. The threat model is strict enough that *the verifier's binary must contain no AI code at all*.

This is a **build-time guarantee**, not a runtime guarantee. Configuration cannot satisfy it.

## Options Considered

### Option 1: Same binary on all hosts; feature flags disable AI on the verifier

**Rejected.** A feature flag `features.ai.enabled: false` only affects runtime dispatch. The AI adapter code is still present in the binary. The threat model requires the AI code paths to be absent from the verifier's binary.

### Option 2: Process-level sandbox on the verifier (systemd `ProtectHome`, bubblewrap, namespaces)

**Rejected** as the *primary* mechanism. Process sandboxing is a useful defence-in-depth layer (and is used inside the AI bridge subprocess on AI-capable hosts; see [F32](../proposals/F32-tiered-architecture-implementation.md) Phase C), but it does not satisfy the build-time guarantee. A sandbox-escape vulnerability or misconfiguration could let AI code execute. The threat model demands the code not be there in the first place.

### Option 3: A separately-built `nwp-verifier` binary for the verifier — CHOSEN

A second build target produces a `nwp-verifier` binary that:
- Compiles only the deploy-verifier code paths.
- Excludes all AI adapters.
- Excludes all CI adapters.
- Excludes all SaaS clients (no Anthropic, OpenAI, GitHub, GitLab.com, sigstore, cosign clients).
- Excludes the auto-detection logic that probes for AI / CI capabilities.
- Includes only: signature verification, deploy executor, audit logger, the dedicated VPN client used by the verifier, and the minimum Drupal-deploy machinery.

Distributed as a separately-signed reproducible build. Installed on the verifier host instead of `nwp`.

**Pros:** Satisfies the build-time guarantee mechanically. Smaller binary, smaller attack surface. Reproducible build is auditable. Cleanly mirrors the rke2 (security-hardened) vs k3s (convenience) split that is the canonical OSS precedent.

**Cons:** Two build targets to maintain. The verifier installation procedure differs from other hosts. Bug fixes that touch shared code must be ported to both binaries (mitigated by sharing source modules).

### Option 4: Four binaries (one per role)

**Rejected** for the reasons in [ADR-0020](0020-tiered-architecture-model.md): package skew, four installation paths, four bug surfaces, no benefit over Option 3 for non-verifier roles. The threat-model argument that justifies splitting the verifier does not apply to the AI host (which by design *runs* AI), the CI host (which processes untrusted code in containers anyway), or the authoring host (which is the operator's primary workstation).

## Decision

Adopt **Option 3**: a separately-built `nwp-verifier` binary for the verifier role.

- Build system (`Makefile` / `bin/build`) gains a `nwp-verifier` target alongside `nwp`.
- `nwp-verifier` is built from the same source tree but with build tags / Cargo features / Bash script-includes that exclude the AI, CI, and SaaS modules.
- `nwp-verifier` is reproducible: identical bit-for-bit output from a checkout + the official build environment. Build provenance recorded via SLSA-style attestations or equivalent.
- `nwp-verifier` is signed by the operator's hardware-rooted key (per [ADR-0019](0019-mons-always-on-hardware-rooted-keys.md)) and distributed to the verifier through the same offline channel as production deploy artefacts.
- The verifier host runs `nwp-verifier` only. `nwp` is not installed there.
- All other roles (authoring, CI, AI, mirror-store, voice-agent, etc.) run `nwp`.
- The shared CLI surface — `pl deploy`, `pl verify`, `pl status` — works on both binaries; commands not relevant to the verifier (`pl install`, `pl ai *`, `pl ci *`) are absent from `nwp-verifier` and produce a "command not available in nwp-verifier" error.

## Rationale

### Configuration cannot satisfy a code-presence requirement

A runtime feature flag is a request to behave differently; it does not change what code is present. The threat model requires that the verifier's binary contain no AI code, period. The only mechanism that satisfies a code-presence requirement is build-time exclusion.

### rke2 vs k3s is the precedent

The Rancher project distributes both k3s (convenience-focused, broadly inclusive) and rke2 (security-hardened, CIS-compliant, narrow). They share substantial source but build to two binaries with different inclusion sets. The rke2 binary is what users put on production hosts when audit and minimal attack surface matter; k3s is what users put on developer machines and edge nodes. NWP's `nwp` and `nwp-verifier` mirror the same split: `nwp` everywhere convenience matters; `nwp-verifier` where the threat-model boundary matters.

### One binary split, no more

The expense of a binary split is real (build matrix, distribution, version skew). [ADR-0020](0020-tiered-architecture-model.md) explicitly rejected splitting binaries by tier or by role for non-verifier roles. The verifier is the *only* role that justifies a build-time boundary; every other capability separation is achieved by configuration, sandboxed subprocess, or both.

### The smaller binary is itself a security feature

`nwp-verifier` ships with no HTTP client beyond what the deploy executor needs, no JSON-RPC client (the AI bridge protocol), no LLM SDK code, no CI runner integration, no third-party telemetry. The reduced attack surface is meaningful: a vulnerability in any excluded module is irrelevant to the verifier.

### Reproducible build closes the supply-chain loop

The signed-deploy chain in ADR-0017 already requires reproducible builds for production artefacts. Extending that requirement to `nwp-verifier` itself means the operator can independently verify (from a checkout + the documented build environment) that the binary on the verifier was built from the public source. This is the SLSA Level 3+ pattern; it is straightforward for a Bash/PHP-shaped codebase like NWP.

## Consequences

### Positive

- The threat-model boundary becomes mechanical: no AI code can run on the verifier because no AI code is present.
- Smaller binary on the verifier; fewer dependencies; faster cold start.
- Reproducible build invites third-party audit (the operator, a future contributor, or a security researcher can verify the binary).
- The split is consistent with rke2/k3s and other precedent; not novel.

### Negative

- Build matrix grows by one target.
- Verifier installation is a different step from other-host installation (`sudo install -m 0755 nwp-verifier /usr/local/bin/` vs `pl bootstrap`).
- Shared bug fixes must build both targets and verify both.
- Reproducible build infrastructure (build-environment Docker image, SLSA attestation, signed manifests) is a non-trivial setup cost.

### Neutral

- The verifier's `nwp-verifier` does not need the AI bridge, the CI runner, or any auto-detection logic that probes for those. This is by design; it is not a missing feature.
- Tier 1, 2, and 3 users do not encounter `nwp-verifier` at all. It is a Tier 4 concern.

## Implementation Notes

- Build target lives at `bin/build-nwp-verifier.sh` (or `Makefile` target `make nwp-verifier`).
- Source modules are organised under `lib/` so that `lib/ai/`, `lib/ci/`, `lib/saas/` directories are entirely absent from the `nwp-verifier` build.
- The `nwp-verifier` binary's `--version` reports as `nwp-verifier vX.Y.Z` (distinct from `nwp vX.Y.Z`) so version skew is auditable in deploy logs.
- The build environment is documented in [`docs/reference/reproducible-build.md`](../reference/reproducible-build.md) (authored by F32 Phase D); the documentation includes the exact base image, build commands, and expected hashes.
- CI for the public repo produces both `nwp` and `nwp-verifier` artefacts on every release; the `nwp-verifier` artefact is additionally signed with the build-time key.

## Migration Path

**Effective:** v0.31.0 (after F32 Phase D lands).

**For the operator's existing setup:**
1. Build `nwp-verifier` v0.31.0 on the build host.
2. Sign the artefact per ADR-0019.
3. Transfer to the verifier through the existing offline channel.
4. Install on the verifier; remove the previous `nwp` installation from the verifier.
5. Verify a representative deploy works end-to-end.
6. Update the verifier's runbook to reflect that `nwp-verifier` is now the binary.

**For new Tier 4 adopters:**
- Documentation in [`docs/tiers/tier-4-add-verifier.md`](../tiers/tier-4-add-verifier.md) (authored by F32 Phase F) describes the `nwp-verifier` build, sign, transfer, and install process.

## Review

**30-day review:** 2026-06-09.

**Success metrics:**
- `nwp-verifier` is reproducibly built (bit-for-bit identical from independent checkouts).
- The verifier deploy chain works end-to-end with `nwp-verifier` in place of `nwp`.
- A `strings` check on `nwp-verifier` returns zero matches for AI-vendor library symbols (Anthropic SDK, OpenAI SDK, Ollama client, etc.).

## Related Decisions

- [ADR-0017](0017-distributed-build-deploy-pipeline.md) — establishes the verifier role and the AI-free constraint.
- [ADR-0019](0019-mons-always-on-hardware-rooted-keys.md) — hardware-rooted keys on the verifier; signing covers `nwp-verifier` artefacts as well as deploy artefacts.
- [ADR-0020](0020-tiered-architecture-model.md) — single-binary tier model; this ADR is the one justified exception.
- [F32](../proposals/F32-tiered-architecture-implementation.md) Phase D — implements the build target and verifier installation procedure.
