# ADR-0005: Distributed Contribution Governance

**Status:** Accepted
**Date:** 2026-01-08
**Decision Makers:** Rob
**Related Issues:** N/A (governance framework)

## Context

NWP supports multiple contribution models:
1. Fork-based contributions (simple PRs from GitHub/GitLab forks)
2. Tier-2 GitLab instances (developers running their own GitLab)
3. Direct contributions from core developers

We need a governance framework that:
- Tracks design decisions (ADRs)
- Prevents repeated work on rejected features
- Enables AI assistance in code review
- Scales across distributed repositories

## Options Considered

### Option 1: Drupal-Inspired Governance + ADRs
- **Pros:**
  - Proven model from large open source project
  - Issue categories match our needs
  - ADRs provide decision memory
  - Compatible with AI assistance
- **Cons:**
  - Requires discipline to maintain
  - Initial setup overhead

### Option 2: Minimal Process
- **Pros:**
  - Low overhead
  - Fast decision making
- **Cons:**
  - Knowledge lost when people leave
  - Repeated discussions of rejected ideas
  - Inconsistent standards

### Option 3: Heavy ITIL-Style Governance
- **Pros:**
  - Comprehensive change management
- **Cons:**
  - Overkill for our scale
  - Slows development significantly

## Decision

Adopt the framework documented in `DISTRIBUTED_CONTRIBUTION_GOVERNANCE.md`:

1. **Decision Tracking**: ADRs in `docs/decisions/`, quick decisions in `decision-log.md`
2. **Issue Categories**: Bug, Task, Feature, Support, Plan (Drupal-inspired)
3. **Trust Progression**: Newcomer → Contributor → Core Developer → Steward
4. **AI Integration**: Claude checks decision history before implementing changes
5. **Security Review**: Multi-layer malicious code detection

## Rationale

This framework provides the right balance of structure and agility. The ADR system creates institutional memory without bureaucratic overhead. AI integration helps enforce standards consistently.

## Consequences

### Positive
- Design decisions are documented and searchable
- New developers can understand project history
- Rejected features won't be repeatedly proposed
- AI assistants can help enforce governance

### Negative
- Requires discipline to create ADRs
- Initial learning curve for contributors

### Neutral
- CLAUDE.md contains standing orders for AI
- All contributors should read governance docs

## Implementation Notes

Directory structure:
```
docs/
├── decisions/
│   ├── index.md
│   ├── template.md
│   ├── decision-log.md
│   └── 0001-*.md, 0002-*.md, etc.
├── DISTRIBUTED_CONTRIBUTION_GOVERNANCE.md
├── CORE_DEVELOPER_ONBOARDING_PROPOSAL.md
├── ROLES.md
└── CONTRIBUTING.md (root level)
```

## Review

**30-day review date:** 2026-02-08
**Review outcome:** Pending
