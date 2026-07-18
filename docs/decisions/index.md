# Architecture Decision Records

This directory contains Architecture Decision Records (ADRs) documenting significant technical and process decisions made for the NWP project.

## What is an ADR?

An Architecture Decision Record captures a decision that has significant impact on the project's architecture, development process, or contributor workflow. ADRs help:

- **Document context** - Why was this decision made?
- **Preserve history** - What alternatives were considered?
- **Onboard newcomers** - Understand project evolution
- **Prevent re-litigation** - Avoid repeated discussions

## When to Create an ADR

Create an ADR for:
- Architectural changes (new patterns, significant refactoring)
- Technology choices (frameworks, libraries, tools)
- Process changes (workflows, governance, contribution rules)
- Rejected proposals (to prevent repeated work)

Do NOT create an ADR for:
- Bug fixes
- Minor enhancements
- Routine maintenance
- Implementation details within established patterns

## ADR Status Lifecycle

```
Proposed → Accepted → [Deprecated | Superseded]
    ↓
 Rejected
```

## Accepted Decisions

| ADR | Title | Date | Status |
|-----|-------|------|--------|
| [0001](0001-use-ddev-for-local-development.md) | Use DDEV for local development | 2026-01-08 | Accepted |
| [0002](0002-yaml-based-configuration.md) | YAML-based configuration | 2026-01-08 | Accepted |
| [0003](0003-bash-for-automation-scripts.md) | Bash for automation scripts | 2026-01-08 | Accepted |
| [0004](0004-two-tier-secrets-architecture.md) | Two-tier secrets architecture | 2026-01-08 | Accepted |
| [0005](0005-distributed-contribution-governance.md) | Distributed contribution governance | 2026-01-08 | Accepted |
| [0006](0006-contribution-workflow.md) | Contribution workflow | 2026-01-09 | Accepted |
| [0007](0007-verification-schema-v2-design.md) | Verification schema v2 design | 2026-01-10 | Accepted |
| [0008](0008-recipe-system-architecture.md) | Recipe system architecture | 2025-12-15 | Accepted |
| [0009](0009-five-layer-yaml-protection.md) | Five-layer YAML protection system | 2026-01-14 | Accepted |
| [0010](0010-tui-framework-design.md) | TUI framework design (checkbox.sh and tui.sh) | 2025-12-01 | Accepted |
| [0011](0011-proposal-designation-system.md) | Proposal designation system (P##, F##, X##) | 2026-01-10 | Accepted |
| [0012](0012-cc0-public-domain-dedication.md) | CC0 public domain dedication | 2026-01-14 | Accepted |
| [0015](0015-yq-first-awk-fallback-pattern.md) | yq-first with AWK fallback pattern | 2026-01-13 | Accepted |
| [0016](0016-avc-email-reply-architecture.md) | AVC email reply architecture | 2026-01-15 | Accepted |
| [0017](0017-distributed-build-deploy-pipeline.md) | Distributed build/deploy pipeline (build-tier build, verifier deploy) | 2026-04-07 | Accepted (implementation started; F21 Phases 1 ✅, 2 ✅, 3a ✅) |
| [0018](0018-twilio-bounded-saas-for-pstn.md) | Twilio as bounded SaaS dependency for PSTN voice/SMS | 2026-04-08 | Accepted |
| [0024](0024-self-deploying-prod-supersedes-verifier.md) | Self-deploying prod via a runner resident on the prod host — **canonical for production deploy authority** | 2026-06-25 | Accepted 2026-06-28 (A14); **not operational** until the linchpin (token downscope) + WebAuthn + protected runner land. Supersedes 0019, amends 0017. Live-test-tier deploy grant 2026-07-01 |
| [0025](0025-production-backup-to-ver.md) | Production backup to `ver` (restic, custodian-pull, append-only) | 2026-06-29 | Accepted |
| [0026](0026-nwp-server-capability-agent.md) | The `nwp-server` AI-free capability agent | 2026-06-28 | Accepted (renumbered from a duplicate 0024, 2026-07-02); field-validated 2026-07-02 (nwp/ops#23), `publish` verb defect resolved 2026-07-02 |
| [0027](0027-unified-course-content-architecture.md) | Unified course-content architecture (one canonical model, federation by overlay, trust-ceremony spectrum) | 2026-07-08 | Accepted 2026-07-09. **Supersedes F30** (specifics), **amends P70** (attribution → member-level/CC0); ops#61 canonical + `adaptations/<member>/` overlays + signed provenance |
| [0028](0028-ver-single-operator-human-gated-workstation.md) | ver as a single-operator, human-gated desktop workstation | 2026-07-09 | Accepted. Amends 0017/0026 (ver *operating posture* only); ver runs full `pl` on a desktop, browser-AI allowed, **no live AI execution on the box**; prod-writes hardware+signature-gated; Solo **W/W2**; DR-backup half deferred |
| [0031](0031-paired-site-versioning-and-promotion.md) | Paired-site versioning & promotion — five planes, versioned pair contract, provider-first ordering | 2026-07-10 | Accepted |

## Rejected Proposals

| ADR | Title | Date | Reason |
|-----|-------|------|--------|
| [0021](0021-public-only-repo-scope.md) | Public-only repo scope | 2026-05-09 | Never accepted; its separate private-repo (`nwp-instances/`) option was abandoned — F33 superseded, nwc is canonical **in-tree**; the public/private boundary is enforced by P61 + F34 instead |

## Superseded Decisions

| ADR | Title | Superseded By |
|-----|-------|---------------|
| [0013](0013-four-state-deployment-model.md) | Four-state deployment model (dev/stg/live/prod) | [0030](0030-per-site-canonical-maturity-axes.md) (code is `canonical: dev\|live\|prod` + `maturity:`, rejects `stg` as a state) |
| [0019](0019-verifier-always-on-hardware-rooted-keys.md) | verifier always-on with hardware-rooted keys | [0024](0024-self-deploying-prod-supersedes-verifier.md) (before implementation) |

## Deprecated Decisions

| ADR | Title | Note |
|-----|-------|------|
| [0014](0014-git-hooks-documentation-enforcement.md) | Git hooks for documentation enforcement | Never installed in practice; superseded-in-intent by **P62 `pl doc-truth`** (baseline-safe CI gate `lint:doc-truth`, see ADR-0030) |

## Proposed (not yet accepted)

| ADR | Title | Date | Note |
|-----|-------|------|------|
| [0020](0020-tiered-architecture-model.md) | Tiered architecture model | 2026-04 | Accepted (2026-07-18) |
| [0022](0022-nwp-verifier-binary-split.md) | nwp-verifier binary split | 2026-04 | Superseded by 0026 (2026-07-18); its build target was renamed/re-scoped to `nwp-server` by 0026; no standalone verifier host to build under 0024 |
| 0023 | *(reserved for the AI Confidentiality Boundary, P67 — not yet drafted)* | — | Reserved |
| [0029](0029-nwc-authorization-model.md) | nwc authorization model (domain-layer choke-point, machine-id guild resolution, fail-closed floors) | 2026-07-09 | Proposed; generalises P73, cites OWASP A01 |
| [0030](0030-per-site-canonical-maturity-axes.md) | Per-site canonical & maturity axes + impact/fate-manifest contract | 2026-07-09 | Accepted (2026-07-18); supersedes 0013 (ops#33 `canonical:` + P67 `maturity:` + ops#47 `lib/impact.sh`) |

## Creating a New ADR

1. Copy `template.md` to `NNNN-short-title.md` (next available number)
2. Fill in all sections
3. Set status to "Proposed"
4. Create MR for review
5. Update this index when accepted

## Quick Decision Log

For decisions that don't warrant a full ADR, see [decision-log.md](decision-log.md).

---

*See also: [Distributed Contribution Governance](../governance/distributed-contribution-governance.md) for the full governance framework.*
