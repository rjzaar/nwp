# F34: Role-Label Proposal Rewrite

**Status:** PROPOSED
**Created:** 2026-05-09
**Author:** Robert Karsten Zaar (with AI assistance)
**Priority:** Medium (cosmetic but blocks public release of existing proposals)
**Depends On:** [P61](P61-leakage-hygiene-ci.md) (leakage gate before any rewritten proposal commits), [F33](F33-repository-topology-refactor.md) (private overlay must exist for instance addenda)
**Breaking Changes:** No (existing proposals are rewritten in place; addenda land in the private overlay)
**Estimated Effort:** ~4 phases; mostly content-editing work
**Architecture decision records:** [ADR-0020](../decisions/0020-tiered-architecture-model.md), [ADR-0021](../decisions/0021-public-only-repo-scope.md)

> **Why this proposal exists.** [ADR-0020](../decisions/0020-tiered-architecture-model.md) introduces a fixed role-label vocabulary; [ADR-0021](../decisions/0021-public-only-repo-scope.md) makes the public repo generic. Existing proposals (X-series, F-series cluster-related, per-site A-/S-/M-/C-series) were written assuming specific hostnames and per-instance details. This proposal is the editorial work to bring them into compliance with the role-label vocabulary, with operator-specific bindings extracted to private addenda.

---

## 1. Executive Summary

A handful of existing proposals reference specific hostnames in their bodies (X02 and X03 each name the operator's hosts dozens of times; F21 / F24 / F25 reference cluster hostnames extensively; ADR-0017 and ADR-0019 reference the verifier by hostname). Per-site proposals (A-series in the AVC profile, S-series in the SS profile, M-series in MT, C-series in cathnet) similarly reference specific deployment context.

For the public repo to be a generic OSS artefact, every public proposal needs to:

- Reference **role labels** (`voice-agent`, `ci-host`, `ai-host`, `verifier`, `mirror-store`, etc.), not hostnames.
- Use **generic hardware shapes** ("a host with GPU and 32 GB+ unified RAM") rather than specific models.
- Use the operator's full legal name ("Robert Karsten Zaar (with AI assistance)") rather than informal short forms.
- Reference dependencies by proposal ID (e.g. "F21 Phase 3a"), never by what the operator's roll-out looks like.

Where a proposal's value depends on concrete bindings (e.g. "X02's actual deployment lives at /home/.../servers/<voice-agent-host>/voice-agent/"), those concrete bindings move to a **private addendum** in the `nwp-instances/_proposals-private/` directory. The public proposal references the addendum as "(operator's instance bindings, private)" without disclosing the path.

The work is editorial, not architectural. It sequences as: define the canonical role vocabulary; rewrite the X-series; audit and rewrite the cluster-aware F-series; coordinate per-site Tier-A scrub propagation across AVC / SS / MT.

## 2. Goals

- **G1.** Every public proposal in `docs/proposals/` references roles, not hostnames.
- **G2.** Every public ADR in `docs/decisions/` references roles, not hostnames (rewriting existing ADRs in place where they currently use hostnames; ADR-0019 is the principal example).
- **G3.** A `gitleaks` scan of `docs/` returns zero findings against the operator-specific ruleset (per [P61](P61-leakage-hygiene-ci.md)).
- **G4.** Per-site proposal content (A-/S-/M-series) is split into Tier A (public, in the per-site profile) and Tier B (private, in the per-site `nwp-instances/<site>/proposals/` directory) according to the existing TIER_SPLIT.md pattern from the SS profile.
- **G5.** No public proposal contains the literal author string "Rob Zaar" or model-version identifiers ("Claude Opus 4.6"); author convention is "Robert Karsten Zaar (with AI assistance)".

## 3. Non-Goals

- This proposal does **not** change the technical content of any existing proposal — only the wording.
- This proposal does **not** introduce new role labels beyond what [ADR-0020](../decisions/0020-tiered-architecture-model.md) authorises.
- This proposal does **not** affect per-site profiles' code (only their proposal content).

## 4. Architecture

### 4.1 The canonical role vocabulary

The role-label table is authored by [F32](F32-tiered-architecture-implementation.md) Phase A as `docs/reference/role-vocabulary.md`. F34 references it; any new role needed for a proposal rewrite is added to `role-vocabulary.md` first.

Initial vocabulary (from [ADR-0020](../decisions/0020-tiered-architecture-model.md)):

| Role label | Used by |
|---|---|
| `authoring` | The operator's primary workstation; signed commits originate here |
| `ci-host` | Self-hosted runner (GitLab Runner, Forgejo Runner, Drone) |
| `build-host` | Drupal artefact builder; often co-located with `ci-host` |
| `ai-host` | Local LLM or AI-bridge subprocess host |
| `voice-agent` | Telephony / push-to-talk role (X02-style) |
| `transcription-worker` | Whisper CPU forward |
| `transcription-gpu` | Whisper Vulkan / CUDA |
| `mirror-store` | F24-style corpus mirror |
| `rag-backend` | X03-style RAG service |
| `verifier` | Offline signed-deploy verifier |
| `signed-deploy` | Synonym for `verifier` in deploy contexts |
| `gitlab-host` | Self-hosted GitLab + artefact distribution |
| `prod-cluster` | User-facing Drupal sites |

### 4.2 The instance-addendum pattern

For proposals that genuinely need concrete bindings (typically X-series experimental work that benefits from a worked example):

- The **public proposal** contains the architecture, design choices, security analysis, and phase plan, written generically using role labels.
- A short **private addendum** in the operator's `nwp-instances/_proposals-private/<id>-instance.md` records the operator's actual host bindings, the milestone-to-commit-hash mapping, and any operator-specific notes.
- The public proposal references the addendum as "(operator's instance bindings, private)" without disclosing the path.

The split follows the example worked through in §13.5 of the operator's planning context: roughly 90% of any proposal is generic value (architecture, design, security); the 10% that names specific hosts moves to the private addendum.

### 4.3 Per-site proposal Tier A / Tier B split

The existing pattern in the SS profile's `proposals/TIER_SPLIT.md` is generalised:

- **Tier A** (public, generic, reusable across deployments): generic Drupal / Moodle / process patterns. Stays in the per-site profile (which becomes shareable when the profile is published).
- **Tier B** (private, deployment-specific): tied to specific deployment, course catalogue, content corpus. Moves to `nwp-instances/<site>/proposals/`.

Each profile gets a `TIER_SPLIT.md` explaining the classification. The SS profile's existing TIER_SPLIT is the template.

## 5. Phases

### Phase 1 — Define and publish the canonical role vocabulary

**Goal:** `docs/reference/role-vocabulary.md` exists; the role-label table is canonical and referenced by all subsequent rewrites.

**Tasks:**
- [ ] Coordinate with [F32](F32-tiered-architecture-implementation.md) Phase A to author `docs/reference/role-vocabulary.md`.
- [ ] Confirm the role table covers every role implied by existing proposals.
- [ ] Add a "Style Guide" section to `docs/reference/role-vocabulary.md` covering: never use hostnames in public; use the role label even when only one host carries it; if a new role is needed, add it here first.

**Definition of done:** `docs/reference/role-vocabulary.md` exists with the full table and style guide.

### Phase 2 — Rewrite the X-series and the cluster-aware F-series

**Goal:** X02, X03, F21, F24, F25 (any other cluster-aware proposals identified by audit) are rewritten in place using role labels; instance addenda landed in the private overlay.

**Tasks:**
- [ ] Run `gitleaks` against `docs/proposals/X*.md` and `docs/proposals/F*.md` to enumerate hostname leakage.
- [ ] For each leaking proposal:
  - [ ] Copy current content to `nwp-instances/_proposals-private/<id>-instance.md` as the starting point for the addendum.
  - [ ] Rewrite the public proposal in place: replace hostname references with role labels; replace specific hardware mentions with generic shapes; update the author line to "Robert Karsten Zaar (with AI assistance)"; remove the AI-model-version annotation.
  - [ ] Edit the private addendum to contain only the operator-specific deltas (host bindings, hardware specifics, milestone-to-commit mapping, operator notes).
  - [ ] Add a short "Reference deployment" subsection at the end of the public proposal: "In the operator's deployment, the role bindings are documented in the private instance addendum."
- [ ] Run gitleaks again; iterate until clean.
- [ ] Verify that proposal cross-references (X03 depends on X02 etc.) still resolve.

**Definition of done:** Every X-series and cluster-aware F-series proposal passes gitleaks; private addenda exist for proposals that warrant them.

### Phase 3 — Audit and rewrite the remaining F-/P-series proposals

**Goal:** Every proposal in `docs/proposals/` is gitleaks-clean.

**Tasks:**
- [ ] `gitleaks detect --source docs/proposals/ --report-path /tmp/gitleaks-proposals.json`.
- [ ] For each finding: classify as (a) hostname → rewrite with role label; (b) personal name → use legal name; (c) author convention violation → fix; (d) genuine operator-only detail → move to private addendum.
- [ ] Re-run gitleaks; iterate until empty.

**Definition of done:** `gitleaks detect --source docs/proposals/` returns zero findings.

### Phase 4 — Per-site Tier A / Tier B propagation

**Goal:** Every per-site profile has a `TIER_SPLIT.md`; Tier B proposals move to the per-site private overlay; Tier A proposals stay in the public profile (rewritten if leaking).

**Tasks:**
- [ ] **AVC profile (27 proposals A01-A27):**
  - [ ] Author `nwp-instances/<avc-site>/profiles/<avc-profile>/proposals/TIER_SPLIT.md` based on the SS template.
  - [ ] Apply the cross-cutting AVC scrub (the public name in scrubbed material is "AV Commons"; operator-internal site names do not appear in public content).
  - [ ] Move Tier B proposals to the per-site private location.
  - [ ] Rewrite Tier A proposals in place using role labels.
- [ ] **SS profile (13 proposals S01-S13):** the existing TIER_SPLIT.md classifies these (5 Tier A, 8 Tier B); execute the move.
- [ ] **MT profile (2 proposals M01-M02):** likely both Tier A (generic Mass Times scraper + generic site creation pattern); add the experimental / pre-alpha banner.
- [ ] **Cathnet profile (5 proposals C01-C03 and amendments):** all stay private (the cathnet site's territorial permission constrains public scope); move all to the per-site private overlay.
- [ ] Run gitleaks against each Tier A profile; iterate until clean.

**Definition of done:** Every per-site profile has a `TIER_SPLIT.md`; Tier B content lives in the private overlay; Tier A content passes gitleaks.

## 6. Test plan

- **gitleaks regression:** `gitleaks detect --source docs/proposals/ --source docs/decisions/` returns zero findings after each phase.
- **Cross-reference integrity:** every `(see [F##](...))` link in rewritten proposals resolves to an existing file.
- **Author-line audit:** `grep -r "Rob Zaar\|Robert Zaar\|Robert K Zaar" docs/` returns zero matches in proposal/ADR bodies (only `Robert Karsten Zaar` permitted).
- **Hostname audit:** `grep -rE "\\b(mini|metabox|met|mons|carlo)\\b" docs/proposals/ docs/decisions/` returns zero matches.
- **Private addendum sanity:** every public proposal that references an instance addendum has a corresponding file in `nwp-instances/_proposals-private/`.

## 7. Rollback plan

Each rewrite is a content edit committed individually. Rollback for a specific proposal: `git revert <commit>`. The private addenda remain in the private overlay regardless; rollback of a public rewrite does not delete the addendum.

## 8. Open questions

- **OQ-1.** Should the AVC scrub work be done as a single bulk PR (faster turnaround but harder to review) or as 27 individual PRs (one per proposal — more reviewable but slow)? Recommendation: bulk PR with a structured diff (one section per proposal); reviewer can scan section-by-section.
- **OQ-2.** Where do the older "non-numbered" proposals (`API_CLIENT_ABSTRACTION.md`, `CODER_IDENTITY_BOOTSTRAP.md`, `nwp-deep-analysis.md`, etc.) sit in the tier scheme? Recommendation: re-classify as either F-series (assign next available number) or move to `docs/notes/` as historical context. Defer to Phase 3 audit.

## 9. Phase status

| Phase | Status | Notes |
|---|---|---|
| 1 | Not started | Coordinated with F32 Phase A |
| 2 | Not started | X02, X03 are the worked examples |
| 3 | Not started | — |
| 4 | Not started | SS already has its TIER_SPLIT |

## 10. Related decisions and proposals

- [ADR-0020](../decisions/0020-tiered-architecture-model.md) — defines the role vocabulary that this proposal propagates.
- [ADR-0021](../decisions/0021-public-only-repo-scope.md) — public-only scope; this proposal makes existing proposals comply.
- [F32](F32-tiered-architecture-implementation.md) — Phase A authors the canonical role-vocabulary doc.
- [F33](F33-repository-topology-refactor.md) — provides the `nwp-instances/_proposals-private/` location for addenda.
- [P61](P61-leakage-hygiene-ci.md) — leakage gate; the gating that makes this proposal verifiable.
