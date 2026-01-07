# Distributed Contribution Governance with Claude

A proposal for managing multi-tier Git repositories with AI-assisted code governance, decision tracking, and secure contribution workflows.

**Status:** PROPOSAL
**Created:** January 2026
**Related:** CICD.md, WORKING_WITH_CLAUDE_SECURELY.md, ROADMAP.md

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [The Problem](#the-problem)
3. [Distributed Repository Topology](#distributed-repository-topology)
4. [Issue Queue Categories](#issue-queue-categories)
5. [Decision Tracking System](#decision-tracking-system)
6. [Claude's Role in Governance](#claudes-role-in-governance)
7. [CLAUDE.md as Standing Orders](#claudemd-as-standing-orders)
8. [Question and Decision Recording](#question-and-decision-recording)
9. [Change Classification](#change-classification)
10. [Integration Workflow](#integration-workflow)
11. [Security Considerations](#security-considerations)
12. [Implementation Plan](#implementation-plan)

---

## Executive Summary

This proposal establishes a governance framework for distributed NWP development where:

- Multiple developers can run their own GitLab instances
- Changes flow upstream through a hierarchy of repositories
- Claude assists with code review, decision enforcement, and documentation
- All design decisions are recorded and searchable
- Rejected features are documented to prevent repeated work
- New developers can understand historical context

**Key Innovation:** Claude reads a `CLAUDE.md` file containing "standing orders" that encode project decisions, rejected features, and coding standards. Before implementing changes, Claude checks this history and explains to developers when their request conflicts with previous decisions.

---

## The Problem

### Current Challenges

1. **Isolated Development:** Developers work independently without visibility into others' decisions
2. **Lost Context:** Why features were rejected or designs chosen is not recorded
3. **Repeated Work:** Same features get proposed and rejected multiple times
4. **Inconsistent Standards:** Different developers apply different patterns
5. **Difficult Onboarding:** New developers don't understand historical decisions

### Desired State

1. **Transparent History:** All decisions documented and searchable
2. **AI-Assisted Governance:** Claude enforces standards and explains decisions
3. **Distributed but Connected:** Multiple repos can contribute while maintaining coherence
4. **Easy Onboarding:** New developers can query Claude about project history

---

## Distributed Repository Topology

### Multi-Tier Architecture

```
                    ┌─────────────────────────────────────┐
                    │         TIER 0: CANONICAL           │
                    │     github.com/nwp/nwp (public)     │
                    │         Main release repo           │
                    └──────────────┬──────────────────────┘
                                   │
                    ┌──────────────┴──────────────────────┐
                    │         TIER 1: PRIMARY             │
                    │   git.nwpcode.org/nwp/nwp           │
                    │   (Rob's GitLab - auto-push to T0)  │
                    └──────────────┬──────────────────────┘
                                   │
          ┌────────────────────────┼────────────────────────┐
          │                        │                        │
┌─────────┴─────────┐   ┌─────────┴─────────┐   ┌─────────┴─────────┐
│   TIER 2: DEV A   │   │   TIER 2: DEV B   │   │   TIER 2: DEV C   │
│  git.deva.org/nwp │   │  git.devb.org/nwp │   │  git.devc.org/nwp │
│  (pushes to T1)   │   │  (pushes to T1)   │   │  (pushes to T1)   │
└─────────┬─────────┘   └───────────────────┘   └───────────────────┘
          │
┌─────────┴─────────┐
│   TIER 3: DEV D   │
│  (pushes to T2-A) │
│  2 repos removed  │
└───────────────────┘
```

### Tier Definitions

| Tier | Description | Push Target | Claude Access |
|------|-------------|-------------|---------------|
| 0 | Canonical (GitHub) | N/A (receives only) | Read-only |
| 1 | Primary (maintainer) | Tier 0 | Full access |
| 2 | Developer (1 removed) | Tier 1 | Full access |
| 3 | Developer (2 removed) | Tier 2 | Full access |
| N | Developer (N-1 removed) | Tier N-1 | Full access |

### Repository Configuration

Each tier's GitLab stores its upstream in `.nwp-upstream.yml`:

```yaml
# .nwp-upstream.yml
upstream:
  url: git@git.nwpcode.org:nwp/nwp.git
  tier: 1
  maintainer: rob@nwpcode.org

downstream:
  - git@git.deva.org:nwp/nwp.git
  - git@git.devb.org:nwp/nwp.git

sync:
  auto_pull: daily
  auto_push: manual  # Requires merge request
```

---

## Issue Queue Categories

Following Drupal's proven model, all work is categorized in GitLab issues:

### Category Definitions

| Category | Label | Purpose | Examples |
|----------|-------|---------|----------|
| **Bug** | `bug` | Something broken that worked before | "backup.sh fails with spaces in path" |
| **Task** | `task` | Work item, refactoring, cleanup | "Consolidate duplicate functions" |
| **Feature Request** | `feature` | New functionality | "Add S3 backup support" |
| **Support Request** | `support` | Usage questions, how-to | "How do I configure multi-site?" |
| **Plan** | `plan` | Meta-issues, RFCs, architecture | "RFC: New deployment strategy" |

### Priority Levels

| Priority | Label | SLA (if applicable) |
|----------|-------|---------------------|
| Critical | `P1` | Security issues, data loss |
| Major | `P2` | Blocks significant functionality |
| Normal | `P3` | Standard priority (default) |
| Minor | `P4` | Nice to have, cosmetic |

### Status Workflow

```
┌──────────┐    ┌─────────────┐    ┌──────────────┐    ┌────────┐
│  Open    │───▶│ In Progress │───▶│ Needs Review │───▶│ Merged │
└──────────┘    └─────────────┘    └──────────────┘    └────────┘
     │                │                    │
     │                ▼                    ▼
     │         ┌─────────────┐    ┌──────────────┐
     └────────▶│ Won't Fix   │    │ Needs Work   │
               └─────────────┘    └──────────────┘
```

### GitLab Issue Templates

Create `.gitlab/issue_templates/` with:

```markdown
<!-- .gitlab/issue_templates/Bug.md -->
## Bug Report

**NWP Version:** (run `pl --version`)
**Environment:** (OS, DDEV version)

### Current Behavior
<!-- What's happening? -->

### Expected Behavior
<!-- What should happen? -->

### Steps to Reproduce
1.
2.
3.

### Error Output
```
<!-- Paste sanitized output here -->
```

### Possible Fix
<!-- Optional: If you have ideas -->
```

```markdown
<!-- .gitlab/issue_templates/Feature.md -->
## Feature Request

### Problem Statement
<!-- What problem does this solve? -->

### Proposed Solution
<!-- How should it work? -->

### Alternatives Considered
<!-- What else could solve this? -->

### Implementation Notes
<!-- Technical considerations -->

### Acceptance Criteria
- [ ] Criterion 1
- [ ] Criterion 2
```

```markdown
<!-- .gitlab/issue_templates/Plan.md -->
## Plan / RFC

**Status:** Draft | Discussion | Accepted | Rejected | Superseded

### Summary
<!-- 1-2 sentence overview -->

### Motivation
<!-- Why is this needed? -->

### Detailed Design
<!-- Technical specification -->

### Drawbacks
<!-- Why might we NOT do this? -->

### Alternatives
<!-- What else was considered? -->

### Unresolved Questions
<!-- What needs more discussion? -->

### Decision
<!-- To be filled after discussion -->
**Decision Date:**
**Decision:**
**Rationale:**
```

---

## Decision Tracking System

### Architecture Decision Records (ADRs)

Store decisions in `docs/decisions/` as numbered markdown files:

```
docs/decisions/
├── 0001-use-ddev-for-local-development.md
├── 0002-yaml-based-configuration.md
├── 0003-reject-docker-compose-alternative.md
├── 0004-bash-over-python-for-scripts.md
├── template.md
└── index.md
```

### ADR Template

```markdown
<!-- docs/decisions/template.md -->
# ADR-NNNN: [Short Title]

**Status:** Proposed | Accepted | Deprecated | Superseded by ADR-NNNN
**Date:** YYYY-MM-DD
**Decision Makers:** [Names]
**Related Issues:** #123, #456

## Context

<!-- What is the issue we're facing? What forces are at play? -->

## Options Considered

### Option 1: [Name]
- **Pros:**
- **Cons:**

### Option 2: [Name]
- **Pros:**
- **Cons:**

## Decision

<!-- What is the change we're proposing/making? -->

## Rationale

<!-- Why did we choose this option over others? -->

## Consequences

### Positive
-

### Negative
-

### Neutral
-

## Implementation Notes

<!-- Technical details for implementers -->

## Review

**30-day review date:** YYYY-MM-DD
**Review outcome:** [Confirmed | Modified | Reverted]
```

### ADR Index

```markdown
<!-- docs/decisions/index.md -->
# Architecture Decision Records

## Accepted Decisions

| ADR | Title | Date | Status |
|-----|-------|------|--------|
| 0001 | Use DDEV for local development | 2025-12-01 | Accepted |
| 0002 | YAML-based configuration | 2025-12-05 | Accepted |
| 0004 | Bash over Python for scripts | 2025-12-10 | Accepted |

## Rejected Proposals

| ADR | Title | Date | Reason |
|-----|-------|------|--------|
| 0003 | Docker Compose alternative | 2025-12-08 | DDEV provides better DX |

## Superseded

| ADR | Title | Superseded By |
|-----|-------|---------------|
| - | - | - |
```

---

## Claude's Role in Governance

### Pre-Implementation Checks

Before implementing any change, Claude should:

1. **Search Decision History**
   ```
   Check docs/decisions/ for related ADRs
   Check GitLab issues for prior discussions
   Check CLAUDE.md for explicit restrictions
   ```

2. **Classify the Change** (see Change Classification section)

3. **Warn on Conflicts**
   ```
   "This feature was previously rejected in ADR-0003 because [reason].
   The decision was made on [date] by [decision makers].
   Would you like to:
   1. Understand the original rationale
   2. Propose reconsidering (create new RFC)
   3. Modify your approach to work within constraints"
   ```

4. **Document Questions Asked**
   ```
   Record all clarifying questions in issue comments
   This creates audit trail for future reference
   ```

### Post-Implementation Documentation

After completing work, Claude should:

1. **Update ADRs** if design decisions were made
2. **Link Issues** to relevant decisions
3. **Update CLAUDE.md** if new standing orders apply

---

## CLAUDE.md as Standing Orders

### Extended CLAUDE.md Structure

```markdown
# Claude Code Instructions

## Protected Files
[existing content]

## Standing Orders

### DO NOT IMPLEMENT

These features have been explicitly rejected. Do not implement without RFC:

| Feature | Rejected Date | ADR | Reason |
|---------|---------------|-----|--------|
| Python rewrite | 2025-12-10 | ADR-0004 | Bash preferred for ops tooling |
| Docker Compose | 2025-12-08 | ADR-0003 | DDEV provides better DX |
| GUI installer | 2025-12-15 | ADR-0007 | TUI sufficient, reduces deps |

### ALWAYS DO

| Requirement | Reason | Reference |
|-------------|--------|-----------|
| Run shellcheck on new scripts | Code quality | CONTRIBUTING.md |
| Add tests for new commands | Prevent regressions | TESTING.md |
| Update CHANGES.md | Changelog maintenance | - |

### STYLE GUIDELINES

| Pattern | Example | Anti-pattern |
|---------|---------|--------------|
| Use `print_info` | `print_info "Starting..."` | `echo "Starting..."` |
| Quote variables | `"$var"` | `$var` |
| Use `[[ ]]` | `[[ -f file ]]` | `[ -f file ]` |

## Decision History Queries

When a developer asks about implementing something, check:

1. `docs/decisions/*.md` - ADRs
2. GitLab issues with `plan` or `feature` labels
3. This file's "DO NOT IMPLEMENT" section
4. `docs/ROADMAP.md` for planned features

If a match is found, explain the history before proceeding.

## Recording Decisions

When making design decisions during implementation:

1. Ask the developer: "This involves a design decision about [X]. Should I:"
   - Document it as an ADR (for architectural choices)
   - Add it to issue comments (for implementation details)
   - Add it to CLAUDE.md standing orders (for project-wide rules)

2. Record the question asked and answer given
3. Link to relevant prior decisions
```

---

## Question and Decision Recording

### Decision Log Format

Create `docs/decisions/decision-log.md` as a running log:

```markdown
# Decision Log

Quick decisions that don't warrant full ADRs but should be recorded.

## 2026-01

### 2026-01-08: Error message format
**Context:** During report.sh implementation
**Question:** Should error messages include timestamps?
**Decision:** No, keep messages concise. Timestamps in log files only.
**Decided by:** Rob
**Related:** #234

### 2026-01-07: Default backup retention
**Context:** backup.sh enhancement
**Question:** How many backups to keep by default?
**Decision:** 10 backups, configurable via cnwp.yml
**Decided by:** Rob
**Related:** #230
```

### GitLab Issue Decision Comments

When decisions are made in issues, use a structured format:

```markdown
## Decision Record

**Date:** 2026-01-08
**Participants:** @rob, @claude

### Question
Should we support both YAML and JSON configuration?

### Options Discussed
1. YAML only (current)
2. YAML + JSON
3. JSON only

### Decision
**Option 1: YAML only**

### Rationale
- Consistency with existing config
- YAML supports comments
- No compelling use case for JSON

### Follow-up
- [ ] Document in ADR if this comes up again
- [x] Update FAQ with explanation
```

---

## Change Classification

### Classification Matrix

| Type | Description | Review Level | ADR Required | Tests Required |
|------|-------------|--------------|--------------|----------------|
| **Typo Fix** | Documentation/comment typos | Self-merge | No | No |
| **Bug Fix** | Fixing broken functionality | Peer review | No | Yes |
| **Enhancement** | Improving existing feature | Peer review | Maybe | Yes |
| **New Feature** | Adding new functionality | Maintainer review | Yes (if architectural) | Yes |
| **Refactor** | Code reorganization | Peer review | Maybe | Yes |
| **Breaking Change** | Changes existing behavior | Maintainer + RFC | Yes | Yes |
| **Security Fix** | Security vulnerability | Fast-track + review | No | Yes |

### Claude's Classification Prompt

When starting work, Claude should identify:

```
Change Classification:
- Type: [Bug Fix / Enhancement / New Feature / etc.]
- Scope: [Single file / Multiple files / Architectural]
- Risk: [Low / Medium / High]
- Tests: [Required / Optional / N/A]
- ADR: [Required / Recommended / Not needed]
- Review: [Self / Peer / Maintainer]

Proceed? [Y/n]
```

---

## Integration Workflow

### Merge Request Flow

```
Developer (Tier 2)                Upstream (Tier 1)
       │                                │
       │  1. Create feature branch      │
       │  2. Implement with Claude      │
       │  3. Claude checks decisions    │
       │  4. Tests pass                 │
       │  5. Create MR to upstream      │
       │─────────────────────────────▶  │
       │                                │
       │                    6. CI runs on upstream
       │                    7. Maintainer reviews
       │                    8. Claude summarizes changes
       │                    9. Decision: merge/reject/request changes
       │  ◀─────────────────────────────│
       │                                │
       │  10. If rejected:              │
       │      - Reason documented       │
       │      - ADR created if needed   │
       │      - Standing orders updated │
       │                                │
```

### Sync Workflow

```bash
# Pull from upstream (daily or manual)
pl sync upstream

# This runs:
# 1. git fetch upstream
# 2. git merge upstream/main (or rebase)
# 3. Resolve conflicts if any
# 4. Update local CLAUDE.md from upstream
# 5. Notify developer of new decisions/standing orders
```

### Push Workflow

```bash
# Push to upstream (via MR)
pl contribute

# This runs:
# 1. Run full test suite
# 2. Check for uncommitted decision records
# 3. Generate MR description from commits
# 4. Create MR on upstream GitLab
# 5. Link related issues
```

---

## Security Considerations

### Sensitive Data in Distributed Repos

| Data Type | Tier 0-1 | Tier 2+ | Handling |
|-----------|----------|---------|----------|
| API tokens | Never | Never | `.secrets.yml` (gitignored) |
| Production credentials | Never | Never | `.secrets.data.yml` (gitignored) |
| User site configs | Never | Never | `cnwp.yml` (gitignored) |
| Decision records | Yes | Yes | Public, no PII |
| Error reports | Sanitized | Sanitized | Use `report.sh` |

### Claude Access by Tier

| Tier | CLAUDE.md | Decisions | Code | Secrets |
|------|-----------|-----------|------|---------|
| 0 | Read | Read | Read | Never |
| 1 | Read/Write | Read/Write | Read/Write | Infra only |
| 2+ | Read/Write | Read/Write | Read/Write | Infra only |

### Safe Information Sharing

When sharing between tiers, use:

```bash
# Generate sanitized project state for sharing
pl report --sanitize --output=project-state.md

# This includes:
# - Recent decisions (no PII)
# - Open issues (titles only)
# - Test results (pass/fail counts)
# - Code metrics (lines, complexity)
```

---

## Implementation Plan

### Phase 1: Foundation (Week 1-2)

- [ ] Create `docs/decisions/` directory structure
- [ ] Create ADR template and index
- [ ] Create decision-log.md
- [ ] Extend CLAUDE.md with standing orders section
- [ ] Create GitLab issue templates

### Phase 2: Issue Queue (Week 2-3)

- [ ] Configure GitLab labels (bug, task, feature, support, plan)
- [ ] Configure GitLab priority labels (P1-P4)
- [ ] Create issue templates in `.gitlab/issue_templates/`
- [ ] Document issue workflow in CONTRIBUTING.md

### Phase 3: Claude Integration (Week 3-4)

- [ ] Update CLAUDE.md with decision checking instructions
- [ ] Create `lib/decisions.sh` for querying decisions
- [ ] Add decision search to `pl` CLI
- [ ] Test Claude's decision-checking behavior

### Phase 4: Multi-Tier Support (Week 4-5)

- [ ] Create `.nwp-upstream.yml` schema
- [ ] Implement `pl sync upstream` command
- [ ] Implement `pl contribute` command
- [ ] Document tier setup process

### Phase 5: Automation (Week 5-6)

- [ ] GitLab CI for decision validation
- [ ] Automated ADR number assignment
- [ ] MR template with decision checklist
- [ ] Notification on new standing orders

---

## References

### Drupal Community Practices
- [Drupal Issue Categories](https://www.drupal.org/docs/develop/issues/fields-and-other-parts-of-an-issue/issue-category-field)
- [Drupal Core Gates](https://www.drupal.org/about/core/policies/core-change-policies/core-gates)
- [Drupal Merge Request Guidelines](https://www.drupal.org/docs/develop/git/using-git-to-contribute-to-drupal/merge-request-guidelines)

### Architecture Decision Records
- [ADR GitHub Organization](https://adr.github.io/)
- [ADR Best Practices (TechTarget)](https://www.techtarget.com/searchapparchitecture/tip/4-best-practices-for-creating-architecture-decision-records)

### Open Source Governance
- [Open Source Best Practices](https://opensource.guide/best-practices/)
- [InnerSource Patterns](https://patterns.innersourcecommons.org/)

### NWP Documentation
- [CICD.md](CICD.md) - CI/CD pipeline setup
- [WORKING_WITH_CLAUDE_SECURELY.md](WORKING_WITH_CLAUDE_SECURELY.md) - Secure AI workflows
- [ROADMAP.md](ROADMAP.md) - Feature roadmap

---

*Proposal created: January 2026*
*Status: Ready for review*
