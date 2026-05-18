# F32: Tiered Architecture Implementation

**Status:** IN PROGRESS — Phase A complete (commits `e9ad8f2`, `2017799`, `9f9632d`); Phases B–G pending
**Created:** 2026-05-09
**Author:** Robert Karsten Zaar (with AI assistance)
**Priority:** High (architectural change; gates the public release)
**Depends On:** [F33](F33-repository-topology-refactor.md) (repo split must land first), [P61](P61-leakage-hygiene-ci.md) (leakage gate before any public-bound proposal commits)
**Breaking Changes:** Yes — schema v2 → v3 of `nwp.yml`; `pl` dispatch refactor; verifier installation changes
**Estimated Effort:** ~7 phases, multi-week buildout
**Architecture decision records:** [ADR-0020](../decisions/0020-tiered-architecture-model.md), [ADR-0022](../decisions/0022-nwp-verifier-binary-split.md)

> **Why this proposal exists.** [ADR-0020](../decisions/0020-tiered-architecture-model.md) captures the architectural *decision* for a tiered architecture model. This proposal is the *implementation plan* — a phased, numbered work breakdown that can be tracked in the roadmap, milestone'd as phases complete, and pointed at by code references. The ADR is the "why"; F32 is the "what to build, in what order, and how to know each phase is done."

---

## 1. Executive Summary

NWP becomes a single binary that scales gracefully from a single-laptop install (Tier 1) to the full reference deployment (Tier 4) by composing three orthogonal mechanisms in `nwp.yml`:

- **Roles per host** (`hosts.<name>.roles: [ci-host, ai-host, verifier, ...]`).
- **Feature flags** (`features.<name>.enabled: true`).
- **Adapter selectors** (`features.<name>.backend: gitlab-runner | gh-actions | ...`).

A `tier:` preset is sugar that expands to coherent feature defaults; per-feature overrides take precedence. Auto-detection (`pl doctor`) emits suggestions; never enables features silently. A small fixed CLI surface (`pl init`, `pl tier-up`, `pl tier-down`, `pl doctor`, `pl host`, `pl ai`, `pl ci`) wraps the existing site-management commands.

Tier 4 carries one justified binary split: a separately-built `nwp-verifier` for the verifier role (see [ADR-0022](../decisions/0022-nwp-verifier-binary-split.md)). Every other host runs the same `nwp` binary.

The phased rollout below lands the schema, the new CLI, the AI bridge subprocess, the `nwp-verifier` build, the reference deployments, the documentation reorganisation, and a rolling adapter library expansion.

## 2. Goals

- **G1.** A new user can complete a Tier 1 install in under 15 minutes from `pl init`.
- **G2.** The reference Tier 4 deployment migrates to schema v3 with a single `pl tier migrate-config` invocation, no manual edits.
- **G3.** Every command in the existing CLI either continues to work unchanged, or has a clearly-aliased replacement with a deprecation notice.
- **G4.** `pl doctor` correctly identifies tier-up opportunities for at least three test environments (laptop-only, laptop+cloud-CI, laptop+cloud-AI).
- **G5.** Round-trip property holds: `pl tier-up X` followed by `pl tier-down X` is a byte-for-byte no-op on `nwp.yml`.
- **G6.** No public artefact (proposal, example config, README) references hostnames or per-instance details — only role labels.
- **G7.** `nwp-verifier` is reproducibly built and contains no AI-vendor library symbols.

## 3. Non-Goals

- This proposal does **not** restructure the public/private repository boundary itself; that work is [F33](F33-repository-topology-refactor.md).
- This proposal does **not** rewrite existing X-/A-/S-/M- proposals to use role labels; that work is [F34](F34-role-label-proposal-rewrite.md).
- This proposal does **not** install the leakage hygiene CI gate; that work is [P61](P61-leakage-hygiene-ci.md), which must land before any proposal in this series is committed to the public repo.
- This proposal does **not** add new adapter implementations beyond a minimum viable set (one CI adapter, one AI adapter, one deploy adapter per tier); ecosystem expansion is Phase G, rolling.

## 4. Architecture

### 4.1 The unified composition model

Three mechanisms compose:

```yaml
# nwp.yml (v3 schema, Tier 3 example, role labels)
nwp:
  version: 3
  tier: 3                              # preset: expands to coherent defaults
hosts:
  dev:     { local: true, roles: [authoring, deployer] }
  ci-host: { ssh: user@ci-host.tailnet, roles: [ci-host, build-host] }
  ai-host: { ssh: user@ai-host.tailnet, roles: [ai-host] }
features:
  ci:
    enabled: true
    backend: gitlab-runner             # adapter selector
    runner_host: ci-host               # references a host by name (which is itself a role-friendly name)
  ai:
    enabled: true
    backend: claude-api                # adapter selector
    bridge_host: ai-host
    sandbox: systemd                   # subprocess isolation
    blast_radius: [dev, stg]
```

Tier presets expand to feature defaults; explicit per-feature flags override. The full schema is defined in [`docs/reference/nwp.yml.md`](../reference/nwp.yml.md) (authored in Phase A).

### 4.2 Code dispatch under the new model

Every `pl` subcommand reads `nwp.yml` once and routes based on:

1. The current host's `roles` (does this command apply here?).
2. The relevant `features.<name>.enabled` flag (is this capability turned on?).
3. The `features.<name>.backend` adapter (which implementation to call?).

Hardcoded host references in the current dispatch (per-host AI health checks; literal hostname arms in the dispatch table) become role-routed equivalents (`pl ai health` finds whichever host carries the `ai-host` role).

### 4.3 The AI bridge subprocess

`features.ai.enabled: true` causes `pl` to launch `nwp-ai-bridge` as a separate process, sandboxed via systemd-run / bubblewrap / Docker (configurable per-host). The bridge:

- Runs as a separate user (`nwp-ai`) with no read access to production keys.
- Implements the adapter pattern internally (the only place that imports any LLM SDK).
- Communicates with `pl` via stdio JSON-RPC.
- Can be killed and restarted independently of the main process.

### 4.4 The `nwp-verifier` binary

A second build target produces `nwp-verifier` with all AI / CI / SaaS modules compiled out. Installed only on the verifier role host. See [ADR-0022](../decisions/0022-nwp-verifier-binary-split.md) for the rationale; this proposal builds the target in Phase D.

## 5. Phases

### Phase A — Schema v3 + tier-aware dispatch

**Goal:** `nwp.yml` v3 schema authored; existing `pl` commands route via the new model; existing operator config migrates cleanly.

**Tasks:**
- [ ] Author `lib/schema/nwp_yml_v3.json` (JSON Schema for v3).
- [ ] Author [`docs/reference/nwp.yml.md`](../reference/nwp.yml.md) covering every section.
- [ ] Author [`docs/reference/role-vocabulary.md`](../reference/role-vocabulary.md) listing the canonical role labels.
- [ ] Implement `lib/migrations/global/migrate_002_to_003.sh` (with prompts for role-label rebinding).
- [ ] Refactor `pl` dispatch to read `tier:` and `features.*` and route accordingly.
- [ ] Replace hardcoded host references in `pl` (literal hostname dispatch arms) with role-routed equivalents.
- [ ] Add backwards-compatible aliases for one minor release.
- [ ] Tests: schema validation, round-trip migration, alias coverage.

**Definition of done:** `pl status` reports the current tier and host/feature matrix; existing operator config migrates with `pl tier migrate-config` and produces identical behaviour for at least one representative deploy.

### Phase B — `pl init` + `pl tier-up` + `pl tier-down` + `pl doctor`

**Goal:** First-run wizard, tier-transition commands, and capability-audit command.

**Tasks:**
- [ ] Implement `pl init [--tier=N | --non-interactive | --config=path]` with the wizard prompts (target ≤ 15 minutes for Tier 1).
- [ ] Implement `pl tier-up <feature> [--backend=X --host=Y]` as additive YAML transforms with confirmation prompts.
- [ ] Implement `pl tier-down <feature>` as the inverse.
- [ ] Implement `pl doctor` with the probes listed in [ADR-0020](../decisions/0020-tiered-architecture-model.md) §"Auto-detection".
- [ ] Implement `pl host add <name> [--ssh=... | --local] [--roles=...]`.
- [ ] Implement `pl host roles <name> [+role | -role]`.
- [ ] Implement `pl tier` (print current tier and host/feature matrix).
- [ ] Add round-trip property test (`tier-up X` followed by `tier-down X` is a no-op).
- [ ] Add safety check: tier-up refuses if any operation lock is held.
- [ ] Tests: wizard non-interactive mode, idempotency, lock-file behaviour.

**Definition of done:** A new user can run `pl init --tier=1 --non-interactive` against a clean workstation and end up with a working tier-1 NWP install. `pl doctor` identifies a tier-up opportunity in at least three test environments.

### Phase C — AI bridge subprocess (`nwp-ai-bridge`)

**Goal:** AI integration runs as a sandboxed subprocess with the adapter pattern internally; `pl` itself imports no LLM SDK.

**Tasks:**
- [ ] Implement `bin/nwp-ai-bridge` with the JSON-RPC stdio protocol.
- [ ] Implement adapters: `claude-api`, `openai`, `ollama`, `manual` (a stub backend useful for testing).
- [ ] Author the systemd user-unit template that confines the bridge (`ProtectHome=true` for production-key directories; restrictive egress; non-`nwp` user).
- [ ] Wire `pl ai suggest`, `pl ai review`, `pl ai explain`, `pl ai health` to route through the bridge.
- [ ] Audit existing AI-using code paths; route through bridge.
- [ ] Document the bridge's threat-model role in [`docs/reference/threat-model.md`](../reference/threat-model.md).
- [ ] Tests: each adapter returns sensible output for canned prompts; sandbox enforcement (bridge cannot read production-key files).

**Definition of done:** `pl ai suggest` works end-to-end with the `claude-api` and `ollama` adapters; the bridge subprocess cannot read files in `keys/` or `*/secrets*.yml` per the sandbox configuration.

### Phase D — `nwp-verifier` binary build target

**Goal:** A separately-built, reproducible verifier binary per [ADR-0022](../decisions/0022-nwp-verifier-binary-split.md).

**Tasks:**
- [ ] Author `bin/build-nwp-verifier.sh` that builds the verifier-only binary with AI / CI / SaaS modules excluded.
- [ ] Author [`docs/reference/reproducible-build.md`](../reference/reproducible-build.md) with the exact build environment and expected hashes.
- [ ] Add CI step that produces both `nwp` and `nwp-verifier` artefacts on every release; both signed by the operator's hardware-rooted key.
- [ ] Author [`docs/tiers/tier-4-add-verifier.md`](../tiers/tier-4-add-verifier.md) with the install procedure.
- [ ] Tests: `strings nwp-verifier` returns zero matches for AI-vendor library symbols; reproducibility test (two independent builds produce bit-for-bit-identical output).

**Definition of done:** `nwp-verifier` builds reproducibly; the operator's verifier host can deploy a representative production change end-to-end with `nwp-verifier` in place of `nwp`.

### Phase E — Tier reference deployments

**Goal:** Three documented reference deployments at three tiers, with end-to-end CI smoke-tests.

**Tasks:**
- [ ] Author [`docs/deployment/reference-tier-1.md`](../deployment/reference-tier-1.md) — solo-blogger setup; one laptop + one VPS; manual SSH deploy.
- [ ] Author [`docs/deployment/reference-tier-4.md`](../deployment/reference-tier-4.md) — full reference with role labels (no hostnames).
- [ ] Author [`docs/deployment/reference-cloud-only.md`](../deployment/reference-cloud-only.md) — Tier 4-cloud variant (cosign + GH Actions OIDC instead of an offline verifier).
- [ ] Set up CI smoke-tests that bring up each reference deployment on ephemeral cloud VMs, run a full install + deploy + backup cycle, and tear down.
- [ ] Update README to point to the tier docs as the first user-facing destination.

**Definition of done:** All three reference deployments install cleanly in CI smoke-tests; each has copy-pasteable install steps in its docs page.

### Phase F — Documentation reorganisation

**Goal:** Documentation is organised around tier as the primary axis; "Choose your tier" decision tree is the first user-facing page after the README.

**Tasks:**
- [ ] Restructure `docs/` per the layout in [ADR-0020](../decisions/0020-tiered-architecture-model.md) §"Documentation organisation" (also captured in the operator's planning context).
- [ ] Author `docs/tiers/README.md` with the literal decision tree.
- [ ] Author per-tier pages (`tier-1-laptop.md`, `tier-2-add-ci.md`, `tier-3-add-ai.md`, `tier-4-add-verifier.md`, `tier-4-cloud-variant.md`, `comparison-matrix.md`).
- [ ] Author the upgrade guides (`upgrade/1-to-2.md`, `upgrade/2-to-3.md`, `upgrade/3-to-4.md`, `upgrade/any-to-any.md`, `upgrade/data-migration.md`).
- [ ] Author the reference docs (`reference/nwp.yml.md`, `reference/pl-cli.md`, `reference/feature-flags.md`, `reference/role-vocabulary.md`, `reference/threat-model.md`).
- [ ] Update README to link to `docs/tiers/README.md` as the first user-facing destination.

**Definition of done:** A first-time visitor can land on the README, click through to "Choose your tier", identify their tier in under 60 seconds, and reach an install procedure they can copy.

### Phase G — Adapter library expansion (rolling)

**Goal:** Each new adapter (CI, AI, deploy mode, secrets, backup, VPN, DNS) is an additive PR.

Each adapter PR adds a single backend implementation under `lib/adapters/<feature>/<backend>/` plus tests and a one-paragraph reference doc. No core changes required.

**Initial coverage** (the minimum viable set, landed by end of Phase E):
- CI: `gitlab-runner`, `gh-actions`, `docker-local`.
- AI: `claude-api`, `ollama`, `manual`.
- Deploy mode: `manual`, `ci-direct`, `offline-verifier`.

**Open-ended additions** (welcomed via PR):
- CI: `forgejo-runner`, `drone`, `woodpecker`, `circleci`, `buildkite`.
- AI: `openai`, `copilot`, `lmstudio`.
- Deploy mode: `gpg-signed`, `ci-signed` (sigstore/cosign), `argocd`.
- Secrets: `sops`, `vault`, `1password-cli`, `bitwarden-cli`.
- Backup: `restic-s3`, `restic-b2`, `borg-ssh`, `rsync-ssh`.
- VPN: `wireguard-direct`, `headscale`, `tailscale`.
- DNS: `cloudflare-api`, `linode-api`, `acme-dns`.

**Definition of done (per adapter):** adapter passes the standard adapter test suite (`lib/adapters/<feature>/_test/conformance.sh`); reference doc added.

## 6. Test plan

- **Unit tests** for the schema validator, the migration script, the tier-up/tier-down round-trip property, the auto-detection probes.
- **Integration tests** for each adapter (canned scenarios that exercise the full path).
- **End-to-end smoke-tests** in CI for the three reference deployments (Phase E).
- **Reproducibility test** for `nwp-verifier` (two independent builds, byte-for-byte comparison).
- **Symbol-absence test** for `nwp-verifier` (`strings` should report zero AI-vendor symbols).
- **Backwards-compatibility test** for the v2 → v3 migration on the operator's own `nwp.yml`.

## 7. Rollback plan

Each phase is independently reversible up to and including Phase D:

- **Phase A rollback:** `pl tier migrate-config --downgrade-to-v2`.
- **Phase B rollback:** the `tier-up`/`tier-down`/`init`/`doctor` commands are additions; not invoking them leaves prior behaviour unchanged.
- **Phase C rollback:** disable AI bridge by setting `features.ai.enabled: false`; the bridge subprocess will not launch.
- **Phase D rollback:** continue using `nwp` on the verifier; do not install `nwp-verifier`. (This preserves the convenience-vs-security trade-off of pre-F32 NWP.)

Phases E, F, and G are documentation/library additions; rollback means deleting the added files.

## 8. Open questions

- **OQ-1.** Schema version naming: `version: 3` (integer, current proposal) vs `version: "v3"` (string)? Decision deferred to Phase A; the JSON Schema author picks.
- **OQ-2.** Should `pl init` default to `--tier=1` if the user hits Enter without typing? Argument for: lowest-friction onboarding. Argument against: the user might own a CI box and not realise. Phase B picks; reversible later.
- **OQ-3.** Adapter discovery: filesystem layout (`lib/adapters/<feature>/<backend>/`) vs registry (`lib/adapters/registry.yml`)? Phase G picks; the filesystem layout is simpler and matches kubectl-plugin convention.

## 9. Phase status

| Phase | Status | Notes |
|---|---|---|
| A | Not started | — |
| B | Not started | — |
| C | Not started | — |
| D | Not started | — |
| E | Not started | — |
| F | Not started | — |
| G | Not started | Rolling, no completion date |

## 10. Related decisions and proposals

- [ADR-0020](../decisions/0020-tiered-architecture-model.md) — the architectural decision this proposal implements.
- [ADR-0021](../decisions/0021-public-only-repo-scope.md) — repository scope; F33 implements the cutover.
- [ADR-0022](../decisions/0022-nwp-verifier-binary-split.md) — verifier binary split; this proposal builds the target in Phase D.
- [F33](F33-repository-topology-refactor.md) — repository topology refactor; must land before this proposal's CI smoke-tests.
- [F34](F34-role-label-proposal-rewrite.md) — propagation of role-label vocabulary into existing proposals.
- [P61](P61-leakage-hygiene-ci.md) — leakage gate; must land first.
