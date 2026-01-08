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

## Rejected Proposals

| ADR | Title | Date | Reason |
|-----|-------|------|--------|
| - | - | - | - |

## Superseded Decisions

| ADR | Title | Superseded By |
|-----|-------|---------------|
| - | - | - |

## Creating a New ADR

1. Copy `template.md` to `NNNN-short-title.md` (next available number)
2. Fill in all sections
3. Set status to "Proposed"
4. Create MR for review
5. Update this index when accepted

## Quick Decision Log

For decisions that don't warrant a full ADR, see [decision-log.md](decision-log.md).

---

*See also: [DISTRIBUTED_CONTRIBUTION_GOVERNANCE.md](../DISTRIBUTED_CONTRIBUTION_GOVERNANCE.md) for the full governance framework.*
