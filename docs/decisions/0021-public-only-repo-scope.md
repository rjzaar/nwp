# ADR-0021: Public-Only NWP Repository Scope

**Status:** Proposed
**Date:** 2026-05-09
**Decision Makers:** Robert Karsten Zaar
**Related Issues:** Generic OSS release; per-instance configuration leakage
**References:** [ADR-0020](0020-tiered-architecture-model.md), [ADR-0022](0022-nwp-verifier-binary-split.md), [F33](../proposals/F33-repository-topology-refactor.md), [P61](../proposals/P61-leakage-hygiene-ci.md)

## Context

The NWP repository today contains a mix of generic infrastructure code (the `pl` CLI, recipes, deploy patterns, ADRs and proposals) and operator-specific configuration (`sites/<name>/` directories with per-site YAML, `nwp.yml` with live domain bindings, `keys/prod_*` materials, server inventories under `servers/<host>/`). The operator-specific portions are gitignored where credentials are concerned, but per-site configuration files, server inventories, and operator-specific proposals (X-series referring to specific hosts; per-site A-/S-/M-/C-series proposals tied to particular school content) are tracked in git.

This shape works for a sole maintainer but blocks public release: the same repository cannot be both the canonical generic tool and the operator's private deployment record. Every contributor PR would either touch the operator's per-site config or trip the contributor's own attempt to add their per-site config. Per-file scrubbing every commit is unsustainable.

The community evidence — Drupal core + per-site configuration via Composer; Coolify control plane + per-destination configs; Mastodon core + per-instance branding patches; HashiCorp tools + per-cluster HCL files; Kubernetes core + Kustomize overlays — converges on **public framework + private instance overlay**, with the public side carrying the framework and the private side carrying the instance bindings.

## Options Considered

### Option 1: Public framework + private instance overlay (separate repository) — CHOSEN

Public NWP repo contains framework code, ADRs, generic proposals, recipes, examples, and `tier-N.example.nwp.yml` templates with role labels.

A separate **private monorepo** (`nwp-instances/`) contains one directory per operator-deployed site (`avc/`, `ss/`, `mt/`, etc.), each holding `nwp.yml`, `.secrets.yml`, profile-specific config, server inventories, and Tier-B (private) per-site proposals.

`pl` reads from `nwp-instances/` if present; otherwise from the public repo's `sites/` (deprecated path, removed in v1.0.0). Cross-machine sync of the private overlay is the operator's responsibility (private GitLab, encrypted backup pipeline, etc.).

**Pros:** Clean topological separation; public history is genuinely public-only; private repo gets full backup, history, branching; public release becomes possible without per-file gating; bidirectional flow (generalisable patterns upstreamed; operator specifics pushed down) is well-defined.

**Cons:** Two repositories to maintain; setup wizard and docs must explain the convention; existing contributors must learn the new layout.

### Option 2: Single repo with `private/` directory in `.gitignore`

**Rejected.** The "gitignore the private bits" pattern means the private content is not in version control and not in the operator's backup pipeline. A `git clean -fdx` obliterates work; a laptop failure loses everything. The pattern is acceptable for ephemeral test fixtures but not for long-lived per-site configuration. (Documented in `~central/PUBLIC-PRIVATE-STRATEGY.md` §1.3.)

### Option 3: Public main + private branch

**Rejected.** Catastrophic failure mode: one accidental `git push origin private` to the public remote leaks everything. Documented cases of this happening across the ecosystem; the dotfiles community has largely abandoned the pattern.

### Option 4: Submodules embedding private content in the public repo

**Rejected.** The submodule URL leaks the private repo's existence in `.gitmodules`. Combined with the well-known UX problems (forgotten `--recurse-submodules`, detached HEAD by default, painful updates), submodules are the wrong tool for the public/private split.

### Option 5: GitLab CE/EE-style strict-superset monorepo

**Rejected.** Enormous tooling overhead designed for a corporation with full-time release engineers. Inappropriate for a sole maintainer; the operational cost dwarfs the friction it removes.

## Decision

Adopt **Option 1**: public framework + separate private instance overlay.

- The public NWP repository (`nwp/`) carries:
  - Generic framework code (the `pl` CLI, library modules, recipes, deploy scaffolding).
  - Per-tier `nwp.yml` templates (`tier-1.example.nwp.yml`, `tier-2.example.nwp.yml`, `tier-3.example.nwp.yml`, `tier-4.example.nwp.yml`).
  - ADRs, F-/P-/X-series proposals (all using role labels per the canonical vocabulary).
  - Documentation, including the per-tier guides (see [F32](../proposals/F32-tiered-architecture-implementation.md) Phase F).
  - `LICENSE` (CC0-1.0 OR MIT, dual-licensed).
  - `CONTRIBUTING.md` (including the public/private convention).

- The public NWP repository **does not contain**:
  - Per-site configuration directories (`sites/<name>/` content).
  - Live `nwp.yml` (only the templates).
  - Any `.secrets.yml`, `.secrets.data.yml`, `keys/prod_*` material.
  - Server inventories under `servers/<host>/`.
  - Operator-specific F-/P-/X-series proposals (these become private addenda — see [F34](../proposals/F34-role-label-proposal-rewrite.md)).
  - Per-site Tier-B proposals (these live with the per-site directory in the private overlay).

- A separate private repository (`nwp-instances/`) is introduced. Its layout is one subdirectory per site; one optional `_global/` subdirectory for cross-site shared configuration; a top-level `instance-manifest.yml` binding role labels to actual hosts (see [ADR-0020](0020-tiered-architecture-model.md) §"Roles").

- `pl` detects the private overlay at `${NWP_INSTANCES_DIR:-$HOME/nwp-instances}` and reads from there if present. During the transition (v0.31.0–v0.40.0), `pl` falls back to the deprecated `nwp/sites/` path; v1.0.0 removes the fallback.

## Rationale

### Topology determines what's possible

The repository topology determines the answer to "can I publish this commit safely?". When the same file mixes generic framework patterns and per-site bindings, the answer is "only after a per-file scrub". When the boundary runs between repositories, the answer is "yes" or "no" by file path. The latter is the only sustainable shape for a public OSS tool.

### Backup is a first-class concern

Per-site configuration represents weeks of work: domain bindings, recipe overrides, custom modules, deploy hooks, per-site troubleshooting notes. Treating it as gitignored "private/" content fails the basic reliability test. Promoting it to a separate private git repository — with full history, full backup, full machine-to-machine sync — preserves the operator's investment.

### Bidirectional flow is the health metric

The existence of two repositories invites a discipline: when an operator-specific customisation generalises (the same pattern would help any NWP user), upstream it to the public repo with a config knob. When a public component needs operator-specific configuration, push the configuration down to the private overlay. The metric "how many private patterns were upstreamed this quarter" is a useful health signal; zero means either hoarding or genuinely private work, both fine in moderation.

### Drupal-on-Composer is the proven pattern

Drupal core is public; per-site `composer.json` specifies which Drupal version the site uses; per-site `web/sites/<site>/settings.php` carries instance-specific configuration. The Drupal community has lived with this split for fifteen years and the tooling around it is mature. NWP applying the same shape to its own architecture costs nothing in novelty and gains a deep ecosystem of conventions (Composer, Drush, settings.local.php inclusion, etc.).

## Consequences

### Positive

- NWP becomes publishable as a generic OSS tool.
- Per-site configuration gets full version control and backup independently.
- Contributor onboarding does not require disclosing operator-specific deployment details.
- The reference Tier 4 deployment (the operator's setup) becomes a documented example, not the implicit baseline.
- The public repo is small enough to clone quickly and reason about completely.

### Negative

- Two repositories to maintain.
- Cross-machine sync of the private overlay is the operator's responsibility (private GitLab + encrypted backup pipeline; mirror to a CI host nightly).
- Existing `pl` commands that assume `nwp/sites/<name>/` paths must be refactored to detect the private overlay.
- Documentation must explain the convention clearly (see [F32](../proposals/F32-tiered-architecture-implementation.md) Phase F).

### Neutral

- The role-label vocabulary (defined in [ADR-0020](0020-tiered-architecture-model.md) and propagated by [F34](../proposals/F34-role-label-proposal-rewrite.md)) becomes the contract between the two repositories: public artefacts reference roles; private overlay binds roles to hosts.
- The leakage gate (gitleaks pre-commit + CI hard-fail; see [P61](../proposals/P61-leakage-hygiene-ci.md)) becomes essential — it enforces the boundary mechanically rather than by maintainer discipline.

## Implementation Notes

- The cutover is implemented by [F33](../proposals/F33-repository-topology-refactor.md): create the private overlay, move per-site directories, install `pl` layout detection, retain backwards-compatible symlinks during a deprecation window.
- The public repo's `LICENSE` is dual-licensed CC0-1.0 OR MIT; see the operator's separate copyright work for the rationale.
- Contributor agreement: the public CONTRIBUTING.md states "by submitting a PR you certify the DCO and dedicate your contribution under the dual licence". The private overlay carries no contributor agreement (operator-only).
- Cross-references between the two repositories use **role labels and proposal IDs** in the public direction; the private overlay may reference public artefacts by file path. A public artefact never references a private artefact by file path or repository name.

## Migration Path

**Effective:** v0.31.0.

**Cutover sequence (executed by [F33](../proposals/F33-repository-topology-refactor.md)):**
1. The operator creates the private `nwp-instances/` repository on private hosting.
2. A migration script copies per-site directories from `nwp/sites/<name>/` into `nwp-instances/<name>/`.
3. The same script generates `nwp-instances/instance-manifest.yml` from the operator's existing host configuration.
4. The public `nwp/sites/<name>/` directories become symlinks to `${NWP_INSTANCES_DIR}/<name>/` for backwards compatibility through v0.40.0; v1.0.0 deletes the symlinks.
5. The operator commits the cutover to both repositories on the same date and verifies a representative deploy works end-to-end.

## Review

**30-day review:** 2026-06-09.

**Success metrics:**
- The public NWP repository can be cloned by a stranger and used to install a Tier 1 site without any reference to the operator's private overlay.
- A `gitleaks` scan of the public repo (per [P61](../proposals/P61-leakage-hygiene-ci.md)) returns zero findings against the operator-specific ruleset.
- Contributor PRs target only public-repo files; per-site work is naturally invisible to contributors.

## Related Decisions

- [ADR-0017](0017-distributed-build-deploy-pipeline.md) — the original four-host architecture; its concrete host bindings move to the private overlay.
- [ADR-0020](0020-tiered-architecture-model.md) — the tier/role/feature model that the public-only scope serves.
- [ADR-0022](0022-nwp-verifier-binary-split.md) — the verifier binary split, decided independently.
- [F33](../proposals/F33-repository-topology-refactor.md) — the cutover implementation.
- [F34](../proposals/F34-role-label-proposal-rewrite.md) — propagation of role labels into existing proposals.
- [P61](../proposals/P61-leakage-hygiene-ci.md) — the leakage gate that enforces the public/private boundary.
