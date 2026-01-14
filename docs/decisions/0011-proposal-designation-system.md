# ADR-0011: Proposal Designation System (P##, F##, X##)

**Status:** Accepted
**Date:** 2026-01-10 (formalized in roadmap reorganization)
**Decision Makers:** Rob
**Related Issues:** Roadmap organization, proposal lifecycle management
**Related Commits:** 039dce6a (roadmap reorganization)
**References:** [roadmap.md](../governance/roadmap.md), [milestones.md](../reports/milestones.md)

## Context

As NWP grew from 5 to 39 implemented proposals, a naming problem emerged:
- All proposals numbered P01-P39 sequentially
- Mixing core infrastructure (P01-P35) with post-foundation features (F04-F09)
- No way to distinguish experimental/outlier proposals
- Sequential numbering implied false ordering/priority
- Hard to understand project evolution at a glance

## Decision

Implement three-tier proposal designation system:

| Prefix | Meaning | Count | Example |
|--------|---------|-------|---------|
| **P##** | Core Phase Proposals | 35 complete | P01-P35: Foundation→Live Deployment |
| **F##** | Feature Enhancements | 4 complete, 7 pending | F04: Governance, F09: Testing |
| **X##** | Experimental Outliers | 1 exploratory | X01: AI Video (scope expansion) |

**Renumbering done:**
- F04 (phases 1-5 complete, 6-8 pending)
- F05 (complete: Security Headers & Hardening)
- F06 (planned: Malicious Code Detection Pipeline)
- F07 (complete: SEO & Search Engine Control)
- F08 (proposed: Dynamic Cross-Platform Badges)
- F09 (complete: Comprehensive Testing Infrastructure)
- F10 (proposed: Local LLM Support & Privacy Options)
- F11 (proposed: Developer Workstation Local LLM Config)
- X01 (exploratory: AI Video Generation Integration)

## Rationale

### Why Three Tiers?

**P## (Core Phases 1-5c):**
- Foundation of NWP infrastructure
- Must be complete for platform to function
- Sequential (each builds on previous)
- Historical record (completed Dec 2025 - Jan 2026)

**F## (Features):**
- Post-foundation enhancements
- Platform is functional without these
- Can be implemented in any order (mostly)
- Added value but not core requirements

**X## (Experimental):**
- Outside core mission (Drupal deployment/hosting)
- Exploratory, might not be implemented
- Significant scope expansion
- Requires strong user demand to justify

### Why Not Sequential Numbering?

**Problems with P01-P39:**
- Implies F04 comes "after" P35 (false)
- Hides project evolution (phases vs features)
- No way to mark outliers
- Newcomers confused by "What's P37?"

**Benefits of prefixes:**
- Immediate context (core vs feature vs experimental)
- Clear project structure
- Easy to explain to new contributors
- Groups related proposals (F04-F11: phase 6-8)

### Why "F" for Features?

**Alternatives considered:**
- E## (Enhancements) - Too similar to "Experimental"
- A## (Add-ons) - Sounds optional/afterthought
- M## (Modules) - Confusing (Drupal modules)
- R## (Refinements) - Undersells value

**"Feature" chosen because:**
- Industry-standard term
- Clear value proposition
- Not pejorative
- Aligns with "feature flag" terminology

### Why "X" for Experimental?

**Signals:**
- Explore, don't commit
- May never be implemented
- Outside normal scope
- Needs justification

**Example X01 (AI Video):**
- NWP mission: Drupal infrastructure
- Video generation: Content creation
- Significant scope expansion
- Marked X## to flag this

## Consequences

### Positive
- **Clear structure** - Instant understanding of proposal type
- **Historical clarity** - P01-P35 are "the foundation"
- **Flexibility** - Can add F12, F13, X02 as needed
- **Newcomer friendly** - Easier to onboard
- **Scope clarity** - X## flags scope expansion

### Negative
- **Renumbering effort** - Updated all documentation
- **Learning curve** - Must explain prefix system
- **Not chronological** - F04 started before P35 completed

### Neutral
- **Backward compatibility** - Old P## references still work
- **No code changes** - Proposal IDs are documentation-only

## Implementation Notes

**Roadmap sections:**
```markdown
## Phase 1-5c: Foundation (P01-P35)
✅ Complete

## Phase 6-8: Features (F04-F11)
- F04: Governance (phases 1-5 complete)
- F05: Security ✅
- F06: Security Pipeline (planned)
- ...

## Phase X: Experimental (X01)
- X01: AI Video (exploratory, scope expansion)
```

**Proposal file naming:**
- Core: Keep as phases (P01-P35 in milestones.md)
- Features: F04+ in roadmap.md
- Experimental: X01+ in roadmap.md

## Review

**30-day review date:** 2026-02-10
**Review outcome:** Pending

**Success Metrics:**
- [x] All proposals categorized
- [x] Roadmap reorganized
- [x] Documentation updated
- [ ] Newcomer feedback: Clear vs confusing
- [ ] Community proposals: Which prefix to use?

## Related Decisions

- **ADR-0005: Distributed Contribution Governance** - F04 proposal
- **ADR-0007: Verification Schema v2** - F09 proposal
