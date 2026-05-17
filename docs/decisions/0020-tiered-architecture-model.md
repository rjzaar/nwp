# ADR-0020: Tiered Architecture Model

**Status:** Proposed
**Date:** 2026-05-09
**Decision Makers:** Robert Karsten Zaar
**Related Issues:** Generic OSS adoption; reference-architecture clarity
**References:** [ADR-0017](0017-distributed-build-deploy-pipeline.md), [ADR-0021](0021-public-only-repo-scope.md), [ADR-0022](0022-nwp-verifier-binary-split.md), [F32](../proposals/F32-tiered-architecture-implementation.md)

## Context

NWP today bakes a specific four-host topology into the tool: a development workstation, a CI/build host, an AI/LLM host, and an offline-deploy verifier. ADR-0017 documents this as the operator's reference deployment, and CLAUDE.md's "Distributed Actor Glossary" treats it as the working model.

For NWP to be useful to other operators, that four-host assumption needs to become a *capability ceiling*, not a *baseline requirement*. A solo Drupal host with one laptop should be able to install NWP and host a site; a small organisation with a build server should be able to add CI; an operator with cloud accounts but no extra hardware should be able to use cloud CI / cloud AI / cloud signing instead of local equivalents.

The ad-hoc alternative — separate "lite" and "full" forks of NWP — has been considered and rejected (§"Alternatives" below). The community evidence from k3s, GitLab, Mastodon, Nomad, Caddy, MinIO, and HashiCorp's broader stack is that a **single binary with composable capability** scales from laptop to data centre without forking.

## Options Considered

### Option 1: Tiered model with role labels + feature flags + adapter backends — CHOSEN

Same `nwp` (`pl`) binary across hosts. Capability composition via three orthogonal mechanisms:

- **Roles per host** in `nwp.yml` (`roles: [authoring, ci-host, ai-host, verifier]`) describing what a host *does*, never what its hostname *is*.
- **Feature flags** (`features.<name>.enabled`) describing what's *turned on*.
- **Adapter selectors** (`features.<name>.backend`) describing *how* a feature is implemented (`gitlab-runner` / `gh-actions` / `drone` / etc.).

A `tier:` preset (1, 2, 3, 4) is sugar that expands into a coherent default bundle of feature flags. Per-feature overrides take precedence.

**Pros:** Single binary; same code paths for solo and operator-grade installs; clean degradation for missing capabilities; auto-detection can suggest tier-ups without enabling them silently.

**Cons:** Adds a tier abstraction the current codebase doesn't have; requires schema v3 of `nwp.yml`; introduces non-trivial migration work.

### Option 2: One binary per role (`nwp-cli`, `nwp-ci`, `nwp-ai`, `nwp-deploy`)

**Rejected.** Four packages to ship, version, sign, distribute. Inter-binary version skew is a recurring source of bugs (Drone has wrestled with server/runner skew for a decade). Tier-1 users would install only one binary but face an artificial complexity wall when adopting tier 2. The capability-isolation argument — that AI code shouldn't live on the verifier — is solved better by a single, narrow binary split for that one threat boundary (see ADR-0022) plus subprocess sandboxing for the AI bridge.

### Option 3: Auto-detection that enables features silently

**Rejected.** A `pl` binary that finds `gitlab-runner` installed and silently routes CI through it is surprising; a system update that installs a new binary could change NWP's behaviour without any user action. Worse, the verifier (per ADR-0017) cannot rely on auto-detection — it must declare its mode in config to refuse non-deploy operations. A consistent rule across hosts is "configuration is explicit; auto-detection only suggests".

### Option 4: No tier model — just a wall of feature flags

**Rejected.** Tier-1 users would face fourteen unfamiliar booleans on first run. The GitLab `roles ['xxx_role']` precedent applies: tier names a coherent bundle, the bundle is implemented as flags. Both layers exist; both are auditable.

### Option 5: Separate "lite" and "full" forks of NWP

**Rejected.** GitLab CE/EE divergence pain at single-maintainer scale. The strict-superset model (CE is a real subset of EE) requires enormous tooling investment that NWP cannot sustain. Forking would also fragment the documentation, confuse contributors, and double the maintenance burden.

## Decision

Adopt **Option 1**: tiered model with role labels + feature flags + adapter backends.

- One `nwp` binary across every host that runs general NWP work. (One narrow binary split is justified separately for the verifier — see ADR-0022.)
- `nwp.yml` schema v3 introduces `tier:`, `hosts.<name>.roles`, `features.<name>.{enabled, backend, ...}`, `policy.*`.
- Tier presets:
  - **T1 (Laptop)** — single host wears all roles; manual deploy with loud warnings.
  - **T2 (+ CI)** — adds CI; backend interchangeable.
  - **T3 (+ AI)** — adds sandboxed AI bridge; backend interchangeable.
  - **T4 (Full)** — adds the offline-verifier deploy chain.
- Per-feature `backend` selectors decouple capability from implementation: the same `tier: 3` is achievable with self-hosted CI + local LLM, or cloud CI + cloud AI, or any mix.
- Auto-detection (`pl doctor`) emits *suggestions* in human-readable form; never changes config.
- Tier upgrades are explicit, additive, reversible operations (`pl tier-up <feature>`, `pl tier-down <feature>`).

## Rationale

### Single binary, composable capability

The strongest cross-project pattern in modern infrastructure tooling is "same binary, additive flags, configuration determines behaviour". k3s embodies this most cleanly (one ~50 MB binary becomes server / agent / kubectl / ctr via multi-call dispatch; flags `--cluster-init` / `--server` / `--datastore-endpoint` choose the topology). HashiCorp Nomad does the same (`nomad agent -dev` for laptops; HCL stanzas for production; identical API surface across topologies). Mastodon's three Ruby processes (`web`, `sidekiq`, `streaming`) all read the same `.env.production` and scale from one box to one hundred without architectural change.

NWP gets the same property when the binary is invariant under tier and the configuration determines the role.

### Roles are the seam

Hardcoding hostnames into NWP's code or proposals leaks the operator's topology and prevents reuse. Role labels (`ci-host`, `ai-host`, `verifier`, `mirror-store`, `voice-agent`, `signed-deploy`) are a small fixed vocabulary that public artefacts reference; the binding from role to actual hostname lives in private per-instance configuration. This keeps the public NWP repo generic and reusable. The role vocabulary is canonical (see [`docs/reference/role-vocabulary.md`](../reference/role-vocabulary.md), authored by F32) and any new role is added there before being used elsewhere.

### Feature flags are the truth, tier is the sugar

Tier is a UX concept — "I want a coherent bundle for my situation". Features are the implementation seam — "this command path must check whether AI is enabled". Code gates on feature flags (`if features.ai.enabled`); humans pick tiers. The two layers do not collapse into each other.

### Adapter backends absorb ecosystem variety

CI today means GitLab Runner, GitHub Actions, GitLab.com, Drone, Forgejo Runner, Woodpecker, BuildKite, CircleCI, on-laptop Docker. AI today means Claude API, OpenAI, Ollama, GitHub Copilot, LMStudio, no AI at all. Deploy today means direct SSH, GPG-signed releases, sigstore/cosign, the offline-verifier chain. NWP cannot pick winners; it provides the seam (`features.ci.backend`, `features.ai.backend`, `features.deploy.mode`) and ships the most commonly-needed adapters as library code under `lib/adapters/<feature>/<backend>/`.

### Auto-detection suggests; never enables

Auto-detection is a discovery aid, not a configuration mechanism. The principle of least surprise demands that NWP's behaviour is fully described by `nwp.yml`. `pl doctor` probes the environment and prints suggestions ("ANTHROPIC_API_KEY detected — run `pl tier-up ai --backend=claude-api` to enable"); the user always runs the upgrade explicitly. This is critical for the verifier: ADR-0017's threat model requires that the verifier's mode is declared in config and not subject to silent change.

## Consequences

### Positive

- NWP becomes installable by users without the operator's reference cluster.
- Documentation organises around tier as the primary axis (see [F32](../proposals/F32-tiered-architecture-implementation.md) Phase F).
- Public NWP artefacts (proposals, examples) reference roles and remain generic; per-instance bindings live in the private overlay (see [ADR-0021](0021-public-only-repo-scope.md)).
- The reference Tier 4 deployment (the operator's current four-host setup) becomes the documented top of the tier ladder rather than the implicit baseline.
- Adapter pattern allows ecosystem additions without core changes.

### Negative

- Schema migration is required (v2 → v3); see [F32](../proposals/F32-tiered-architecture-implementation.md) Phase A.
- Existing CLI commands that reference hosts directly (per-host health checks; literal hostname dispatch arms in `pl`) must be refactored to use roles; transitional aliases retain backwards compatibility for one minor release.
- Documentation grows: per-tier pages, upgrade guides, reference deployments.
- Test matrix expands: CI must exercise at least Tier 1, Tier 4-cloud, and Tier 4-self-hosted.

### Neutral

- The verifier role requires a separately-built binary (see [ADR-0022](0022-nwp-verifier-binary-split.md)); this is decided independently of the tier model and applies only at Tier 4.
- AI integration becomes a sandboxed subprocess (the `nwp-ai-bridge`); this is decided as part of [F32](../proposals/F32-tiered-architecture-implementation.md) Phase C and applies whenever Tier 3 or higher is configured.

## Implementation Notes

- Schema v3 is documented in [`docs/reference/nwp.yml.md`](../reference/nwp.yml.md), authored by F32 Phase A.
- Migration script `lib/migrations/global/migrate_002_to_003.sh` converts existing v2 `nwp.yml` to v3 by inferring `tier: 4` from the presence of verifier-shaped configuration; the script prompts for role-label rebinding.
- The `pl tier-up` / `pl tier-down` commands implement additive YAML transforms; round-trip property test confirms `tier-up X` followed by `tier-down X` is a byte-for-byte no-op.
- Auto-detection probes are listed in F32 Phase B and surface in `pl doctor`.

## Migration Path

**Effective:** v0.31.0 (after F32 Phase A lands).

**Backwards compatibility:**
- Old `nwp.yml` (v2) continues to work for one minor release; `pl status` prints a one-line "schema v2 detected; run `pl tier migrate-config` to upgrade" notice.
- Hardcoded host references in `pl` (per-host AI health and dispatch arms) become aliases for the role-routed equivalents (`pl ai health` routes to whichever host carries the `ai-host` role); aliases removed in v1.0.0.

## Review

**30-day review:** 2026-06-09.

**Success metrics:**
- A new user can complete the Tier 1 install path in under 15 minutes from `pl init`.
- The operator's existing four-host setup produces an identical-behaviour migration to v3 with no manual edits beyond running `pl tier migrate-config`.
- `pl doctor` correctly identifies tier-up opportunities for at least three different test environments (laptop-only, laptop+cloud-CI, laptop+cloud-AI).

## Related Decisions

- [ADR-0017](0017-distributed-build-deploy-pipeline.md) — defines the four-host reference deployment that becomes Tier 4.
- [ADR-0021](0021-public-only-repo-scope.md) — public NWP repo carries the framework; per-instance config lives in a private overlay; the `tier:` config lives in the private overlay's `nwp.yml`.
- [ADR-0022](0022-nwp-verifier-binary-split.md) — the only justified binary split, for the verifier role at Tier 4.
- [F32](../proposals/F32-tiered-architecture-implementation.md) — phased implementation work.
- [F33](../proposals/F33-repository-topology-refactor.md) — the repo split that the tier model presupposes.
- [F34](../proposals/F34-role-label-proposal-rewrite.md) — propagation of the role-label vocabulary into existing proposals.
- [P61](../proposals/P61-leakage-hygiene-ci.md) — leakage gate that ensures public proposals stay generic.
