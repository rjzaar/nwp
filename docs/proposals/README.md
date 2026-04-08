# NWP Proposals

This directory contains proposal documents for **NWP core** features and
enhancements.

> **NWP-only.** Site-specific work (mass times, cathnet, ss faith formation
> app, avc workflow, etc.) lives in each site's own
> `sites/<name>/docs/proposals/` directory under its own per-project
> numbering scheme. Run `pl proposals` to aggregate the full picture across
> NWP and every site.

---

## Numbering Scheme

NWP uses three prefix series in this directory:

| Prefix | Meaning | Range in use |
|--------|---------|---|
| **P##** | Core Phase Proposals — foundational architecture, phases of the original NWP buildout | P01–P60 |
| **F##** | Feature Enhancements — additive features and refactors | F01–F21 |
| **X##** | Experimental / Outlier — speculative ideas not yet on the roadmap | X01 |

Per-project local schemes (each site is its own namespace, numbering
restarts at 01):

| Prefix | Project | Path |
|--------|---------|---|
| **A##** | AVC | `sites/avc/docs/proposals/` |
| **S##** | Sacred Sources (ss) | `sites/ss/docs/proposals/` |
| **M##** | Mass Times (mt) | `sites/mt/docs/proposals/` |
| **C##** | CathNet | `sites/cathnet/docs/proposals/` |
| **D##** | Directory Search (dir1) | `sites/dir1/docs/proposals/` *(none yet)* |

NWP proposals may **reference** site-specific proposals by their per-project
ID, but no NWP proposal carries site-specific design content. The split is
strict: NWP core stays generic; sites carry their own specifics.

---

## 2026-04-08 Renumbering

On 2026-04-08 the NWP F-series was made consecutive and several proposals
were moved into per-project schemes. Old IDs are retained as aliases inside
each renamed file's header.

| Old ID | New location | Reason |
|---|---|---|
| F16 | `sites/mt/docs/proposals/M01-mass-times-scraper.md` | Site-specific (mt) |
| F17 | `sites/mt/docs/proposals/M02-mt-site-creation.md` | Site-specific (mt) |
| F18 | `sites/cathnet/docs/proposals/C01-acmc.md` | Site-specific (cathnet) |
| F19 | `sites/cathnet/docs/proposals/C02-nlp-qa.md` | Site-specific (cathnet) |
| F19 Amendment A1 | `sites/cathnet/docs/proposals/C02a-amendment-A1-synthesis.md` | Site-specific (cathnet) |
| F20 | `sites/ss/docs/proposals/S01-faith-formation-app.md` | Site-specific (ss) |
| F21 (old) | `sites/cathnet/docs/proposals/C03-neo4j-knowledge-graph.md` | Site-specific (cathnet) |
| F22 | `docs/proposals/F16-claude-code-web-access.md` | NWP core, slid into freed slot |
| F23 | `docs/proposals/F17-project-separation.md` | NWP core, slid into freed slot |
| F24 | `docs/proposals/F18-unified-backup-strategy.md` | NWP core, slid into freed slot |
| F25 | `docs/proposals/F19-baseline-reset-cleanup.md` | NWP core, slid into freed slot |
| F26 | `docs/proposals/F20-solveit-methodology.md` | NWP core, slid into freed slot |
| F23 Phase 9 | `sites/avc/docs/proposals/A03-oauth2-guild-sync.md` | AVC-specific extracted |
| (new) | `docs/proposals/F21-distributed-build-deploy-pipeline.md` | New NWP F21, implements ADR-0017 |

The **P##** series was deliberately **not** renumbered. P50–P60 are
referenced from ~60 verification scenario files and would have a large
blast radius. The slot **P59 exists and is implemented** (SSH IdentitiesOnly
hardening, v0.31.0); the previous claim in this README that "there is no
P59" was an error and has been removed.

---

## Proposal Status Overview

### Completed (NWP core)

See [milestones.md](../reports/milestones.md) for the full version history.

- **P01–P35** — Core phases 1–5c (Foundation through Live Deployment)
- **P50** — Unified Verification System
- **P51** — AI-Powered (Functional) Verification
- **P53** — Verification Categorization & Badge Accuracy
- **P54** — Verification Test Infrastructure Fixes
- **P55** — Opportunistic Human Verification
- **P56** — Production Security Hardening
- **P57** — Production Caching & Performance
- **P58** — Test Command Dependency Handling
- **P59** — SSH IdentitiesOnly Hardening
- **P60** — Verification Badge Accuracy v2 (post-P58 follow-up)
- **F03** — Visual Regression Testing
- **F04** — Distributed Contribution Governance (phases 1–5 complete)
- **F05** — Security Headers & Hardening
- **F07** — SEO & Search Engine Control
- **F09** — Comprehensive Testing Infrastructure
- **F12** — Unified Todo Command
- **F13** — Timezone Configuration
- **F14** — Claude API Integration
- **F15** — SSH User Management
- **F17** — Project Separation (formerly F23; phases 1–8, 10 complete; phase 9 extracted to AVC A03)
- **F19** — Pre-Baseline Cleanup (formerly F25; the work that produced the v0.30.0 baseline)

### Rejected

- ~~**P52** — Rename NWP to NWO~~ — **REJECTED.** NWP is the permanent
  project name. The file is kept (rather than archived) so the rejection is
  visible to anyone scanning the index.

### Proposed (NWP core)

- **F16** — Claude Code Web Access (formerly F22)
- **F18** — Unified Backup Strategy (formerly F24)
- **F20** — Integrating the SolveIt Methodology into NWP (formerly F26)
- **F21** — Distributed Build/Deploy Pipeline (mmt build, mons deploy) — *new, implements [ADR-0017](../decisions/0017-distributed-build-deploy-pipeline.md)*

### Pending (see [roadmap.md](../governance/roadmap.md))

- **F04** — Phases 6–8 (Issue Queue, Multi-Tier, Security Review)

### Promoted to guides

- **F10** — Local LLM Support & Privacy Options → [`docs/guides/local-llm.md`](../guides/local-llm.md) (2026-04-08). The file was always a how-to; moving it fixed the miscategorisation. The actual provisioning work is tracked under F21 Phase 3a.
- **F11** — Developer Workstation Local LLM Configuration. F11 never had a file; its intent (set up a local LLM on a developer/agent workstation) is fully subsumed by F21 Phase 3a and the guide. The F11 slot is retired; do not reclaim the number.

### Possible (deprioritized, see [roadmap.md](../governance/roadmap.md))

- **F01** — GitLab MCP Integration
- **F02** — Automated CI Error Resolution
- **F06** — Malicious Code Detection Pipeline
- **F08** — Dynamic Cross-Platform Badges
- **X01** — AI Video Generation Integration

### Site-specific proposals

Use `pl proposals` to aggregate everything below into one view.

| Site | Proposals dir | Notes |
|---|---|---|
| AVC | `sites/avc/docs/proposals/` | A01 (Guild multi-verification), A02 (Workflow system), A03 (OAuth2/Guild sync) |
| Sacred Sources | `sites/ss/docs/proposals/` | S01 (Faith Formation app, in progress) |
| Mass Times | `sites/mt/docs/proposals/` | M01 (Scraper & Display), M02 (Site creation) |
| CathNet | `sites/cathnet/docs/proposals/` | C01 (ACMC), C02 (NLP QA), C02a (Synthesis amendment), C03 (Neo4j KG) |
| Directory Search | `sites/dir1/docs/proposals/` | None yet |

---

## Lifecycle

1. **PROPOSED** — Idea documented, awaiting discussion
2. **PLANNED** — Accepted, scheduled for implementation
3. **IN PROGRESS** — Active development
4. **COMPLETE** — Implemented and verified
5. **Moved to milestones.md** — Archived as completed work

Last Updated: 2026-04-08
