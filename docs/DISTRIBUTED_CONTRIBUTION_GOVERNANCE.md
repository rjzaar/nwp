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
4. [Fork-Based Contributions](#fork-based-contributions)
5. [Issue Queue Categories](#issue-queue-categories)
6. [Decision Tracking System](#decision-tracking-system)
7. [Claude's Role in Governance](#claudes-role-in-governance)
8. [CLAUDE.md as Standing Orders](#claudemd-as-standing-orders)
9. [Question and Decision Recording](#question-and-decision-recording)
10. [Change Classification](#change-classification)
11. [Integration Workflow](#integration-workflow)
12. [Security Considerations](#security-considerations)
13. [Malicious Code Detection](#malicious-code-detection)
14. [Implementation Plan](#implementation-plan)

---

## Executive Summary

This proposal establishes a governance framework for distributed NWP development where:

- Contributors can participate via simple GitHub/GitLab forks (recommended for most)
- Power users can run their own GitLab instances for full autonomy
- Changes flow upstream through a hierarchy of repositories
- Claude assists with code review, decision enforcement, and documentation
- All design decisions are recorded and searchable
- Rejected features are documented to prevent repeated work
- New developers can understand historical context

**Key Innovation #1: Decision Memory.** Claude reads a `CLAUDE.md` file containing "standing orders" that encode project decisions, rejected features, and coding standards. Before implementing changes, Claude checks this history and explains to developers when their request conflicts with previous decisions.

**Key Innovation #2: Scope Verification.** Claude's superpower for security is comparing what a merge request *claims* to do (title, description, linked issue) against what it *actually* does (the diff). A human reviewer might miss that a "typo fix" also modifies `backup.sh` and adds an external URL, but Claude systematically analyzes every change and flags mismatches. This catches malicious code hidden in legitimate-looking contributions.

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

## Fork-Based Contributions

For contributors who don't need or want to run their own GitLab infrastructure, a simpler fork-based workflow is available. This is the recommended path for most contributors.

### Fork Model Overview

```
┌─────────────────────────────────────────────────────────────┐
│              TIER 0: github.com/nwp/nwp                     │
│                   (Canonical - public)                       │
└────────────────────────────┬────────────────────────────────┘
                             │
┌────────────────────────────┴────────────────────────────────┐
│              TIER 1: git.nwpcode.org/nwp/nwp                │
│                   (Primary maintainer)                       │
└────────────────────────────┬────────────────────────────────┘
                             │
        ┌────────────────────┼────────────────────┐
        │                    │                    │
        ▼                    ▼                    ▼
┌───────────────┐   ┌───────────────┐   ┌───────────────┐
│   Fork A      │   │   Fork B      │   │   Fork C      │
│ (GitHub fork) │   │ (GitHub fork) │   │ (GitLab fork) │
│  alice/nwp    │   │   bob/nwp     │   │  carol/nwp    │
└───────────────┘   └───────────────┘   └───────────────┘
```

### When to Use Forks vs Full GitLab Instances

| Contribution Type | Recommended Approach | Reason |
|-------------------|---------------------|--------|
| Bug fixes | Fork | Simple, fast, minimal setup |
| Documentation | Fork | No CI needed for docs |
| Small features | Fork | Upstream CI handles testing |
| Large features | Fork or Tier 2 | Depends on iteration needs |
| Core development | Tier 2 GitLab | Full CI/CD, multiple branches |
| Experimental work | Tier 2 GitLab | Privacy, custom pipelines |
| Organizational use | Tier 2+ GitLab | Independence, internal policies |

### Fork Workflow

#### Initial Setup

```bash
# 1. Fork the repository on GitHub/GitLab (via web UI)

# 2. Clone your fork locally
git clone git@github.com:YOUR_USERNAME/nwp.git
cd nwp

# 3. Add upstream remote
git remote add upstream git@github.com:nwp/nwp.git

# 4. Verify remotes
git remote -v
# origin    git@github.com:YOUR_USERNAME/nwp.git (fetch)
# origin    git@github.com:YOUR_USERNAME/nwp.git (push)
# upstream  git@github.com:nwp/nwp.git (fetch)
# upstream  git@github.com:nwp/nwp.git (push)
```

#### Contributing via Fork

```bash
# 1. Sync your fork with upstream
git fetch upstream
git checkout main
git merge upstream/main
git push origin main

# 2. Create feature branch
git checkout -b fix/issue-123-backup-path

# 3. Make changes, commit (Claude assists here)
# ... edit files ...
git add -A
git commit -m "Fix backup path handling for spaces (#123)"

# 4. Push to your fork
git push origin fix/issue-123-backup-path

# 5. Create Pull Request via GitHub/GitLab web UI
#    - PR from: YOUR_USERNAME/nwp:fix/issue-123-backup-path
#    - PR to:   nwp/nwp:main (or git.nwpcode.org for Tier 1)
```

#### Keeping Fork in Sync

```bash
# Regular sync (recommended: before starting new work)
git fetch upstream
git checkout main
git merge upstream/main
git push origin main

# Or use GitHub's "Sync fork" button in the web UI
```

### Claude Integration with Forks

Claude's governance features work the same way with forks:

1. **CLAUDE.md is inherited** - Your fork contains the same standing orders
2. **Decision history travels** - ADRs and decision logs are in the repo
3. **Security checks apply** - Upstream CI runs all security scans on PRs
4. **Scope verification** - Claude (on maintainer's side) reviews PR scope

#### Fork-Specific Claude Workflow

```
Developer with Fork                    Upstream Maintainer
       │                                      │
       │  1. Clone fork                       │
       │  2. Work with Claude locally         │
       │     - Claude checks CLAUDE.md        │
       │     - Claude checks docs/decisions/  │
       │  3. Push to fork                     │
       │  4. Create PR ──────────────────────▶│
       │                                      │
       │                         5. CI runs security scans
       │                         6. Claude reviews PR scope
       │                         7. Maintainer reviews
       │                         8. Merge or request changes
       │  ◀──────────────────────────────────│
       │                                      │
```

### Advantages of Fork Model

| Advantage | Description |
|-----------|-------------|
| **Zero infrastructure** | No GitLab server to maintain |
| **Familiar workflow** | Standard GitHub/GitLab PR process |
| **Built-in sync** | Platform handles fork synchronization |
| **Free CI** | GitHub Actions / GitLab CI on upstream |
| **Visibility** | PRs visible in upstream's issue tracker |
| **Lower barrier** | Anyone with GitHub account can contribute |

### Limitations of Fork Model

| Limitation | Workaround |
|------------|------------|
| **No private CI** | Use local testing, or upgrade to Tier 2 |
| **Platform dependency** | Can't work if GitHub/GitLab is down |
| **Less autonomy** | Subject to upstream's CI policies |
| **No custom pipelines** | Must use upstream's CI configuration |
| **Limited branch experiments** | Create branches in fork, but no private CI |

### Hybrid Contribution Paths

Contributors can start with forks and graduate to full GitLab instances:

```
Contribution Journey:

┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│  Newcomer   │────▶│  Regular    │────▶│    Core     │
│             │     │ Contributor │     │  Developer  │
└─────────────┘     └─────────────┘     └─────────────┘
       │                   │                   │
       ▼                   ▼                   ▼
   GitHub Fork        GitHub Fork         Tier 2 GitLab
   Simple PRs        Complex PRs         Full instance
   Bug fixes         Features            Core development
```

### Fork Configuration (Optional)

For forks that want to track their relationship formally:

```yaml
# .nwp-fork.yml (optional, in fork's root)
fork:
  upstream: git@github.com:nwp/nwp.git
  contributor: alice@example.com
  sync_strategy: merge  # or rebase

# Areas of focus (helps maintainers route reviews)
expertise:
  - lib/backup.sh
  - recipes/dm/
```

### Quick Reference: Fork Commands

```bash
# Sync fork with upstream
git fetch upstream && git merge upstream/main && git push origin main

# Create feature branch
git checkout -b feature/my-feature

# Push and create PR
git push origin feature/my-feature
# Then use web UI to create PR

# Clean up after PR merged
git checkout main
git branch -d feature/my-feature
git push origin --delete feature/my-feature
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

## Malicious Code Detection

A critical concern in distributed development is detecting malicious code hidden in legitimate-looking contributions (supply chain attacks).

### Attack Vectors

| Attack Type | Example | Detection Difficulty |
|-------------|---------|---------------------|
| Backdoor in dependency | Adding malicious npm/composer package | High |
| Obfuscated payload | Base64-encoded eval() | Medium |
| Logic bomb | `if (date > X) { malicious() }` | High |
| Typosquatting | `druapl/core` instead of `drupal/core` | Medium |
| Scope creep | Bug fix + hidden feature | Medium |
| Credential harvesting | Logging passwords to file | Medium |

### Defense in Depth

No single layer catches everything. Multiple detection layers make bypassing exponentially harder.

```
┌─────────────────────────────────────────────────────────────┐
│                    CONTRIBUTION FLOW                        │
├─────────────────────────────────────────────────────────────┤
│  1. Developer submits MR                                    │
│         ↓                                                   │
│  2. CI: Automated scans (gitleaks, semgrep, composer audit) │
│         ↓                                                   │
│  3. Claude: Scope check + red flag analysis                 │
│         ↓                                                   │
│  4. Human: Maintainer review (with Claude's notes)          │
│         ↓                                                   │
│  5. Sensitive paths: Require 2nd approver                   │
│         ↓                                                   │
│  6. Merge + deploy to staging first                         │
│         ↓                                                   │
│  7. Post-deploy monitoring                                  │
└─────────────────────────────────────────────────────────────┘
```

### Layer 1: Automated CI Security Scans

Add to `.gitlab-ci.yml`:

```yaml
security_scan:
  stage: security
  script:
    # Dependency audit
    - composer audit
    - npm audit 2>/dev/null || true

    # Secret detection
    - gitleaks detect --source . --verbose

    # SAST (Static Application Security Testing)
    - semgrep --config auto .

    # Suspicious pattern detection
    - |
      echo "=== Suspicious Pattern Scan ==="
      grep -rn "eval\|base64_decode\|exec\|system\|passthru" \
        --include="*.php" --include="*.sh" . || true
  allow_failure: false
```

### Layer 2: Scope Verification (Claude)

Claude should verify that changes match the stated purpose:

```markdown
## MR Scope Verification

Before approving any MR, verify:

1. **Scope Check:** Does the diff match the issue description?
   - Bug fix should only touch relevant code
   - Flag: "This MR modifies 15 files but the bug is in 1 function"

2. **Proportionality:** Is the change size appropriate?
   - Simple typo fix = few lines
   - Flag: "500 lines changed for a typo fix"

3. **Unrelated Changes:** Are there changes outside the fix?
   - Flag: "This also modifies authentication code"
```

### Layer 3: Red Flag Detection

Add to CLAUDE.md for automated flagging:

```markdown
## Security Red Flags

### High Risk (Block and Escalate)
- [ ] Modifies authentication/authorization without auth-related issue
- [ ] Adds new external network calls (curl, file_get_contents with URL)
- [ ] Introduces eval(), exec(), system(), or dynamic code execution
- [ ] Modifies .htaccess, nginx.conf, or server configs
- [ ] Changes cryptographic functions or key handling
- [ ] Adds dependencies not mentioned in issue description
- [ ] Modifies CI/CD pipeline configuration

### Medium Risk (Require Explanation)
- [ ] Changes significantly more files than issue scope suggests
- [ ] Includes "cleanup" or "refactoring" alongside bug fix
- [ ] Modifies database queries or schema
- [ ] Changes file permissions or ownership logic
- [ ] Adds new user input handling without validation

### Verification Questions
When flags are triggered, ask:
1. "This MR modifies [X] which wasn't mentioned in the issue. Can you explain?"
2. "The new dependency [Y] - what does it do and why is it needed?"
3. "This changes authentication logic - was this intentional?"
```

### Layer 4: Diff Analysis Script

Create `lib/security-review.sh`:

```bash
#!/bin/bash
# Security analysis for merge requests

analyze_mr_security() {
    local base_branch="${1:-main}"

    echo "=== MR Security Analysis ==="

    # 1. File count vs claimed scope
    local files_changed=$(git diff --name-only "$base_branch" | wc -l)
    echo "Files changed: $files_changed"

    # 2. Lines added/removed
    git diff --stat "$base_branch" | tail -1

    # 3. Suspicious patterns in diff
    echo ""
    echo "=== Suspicious Pattern Scan ==="
    git diff "$base_branch" | grep -E \
        'eval\(|base64_decode|exec\(|system\(|passthru|shell_exec|proc_open' \
        && echo "WARNING: Potential code execution patterns found" || echo "OK: No execution patterns"

    # 4. New dependencies
    echo ""
    echo "=== New Dependencies ==="
    git diff "$base_branch" -- composer.json package.json 2>/dev/null | \
        grep "^\+" | grep -v "^\+\+\+" || echo "None"

    # 5. Sensitive file modifications
    echo ""
    echo "=== Sensitive Files Modified ==="
    git diff --name-only "$base_branch" | grep -E \
        'settings\.php|\.env|\.htaccess|nginx\.conf|auth|login|password|credential|secret|token|\.gitlab-ci' \
        || echo "None"

    # 6. New external URLs
    echo ""
    echo "=== New External URLs ==="
    git diff "$base_branch" | grep -oE 'https?://[^"'"'"')\s]+' | sort -u || echo "None"

    # 7. New file permissions changes
    echo ""
    echo "=== Permission Changes ==="
    git diff "$base_branch" | grep -E 'chmod|chown|0777|0755' || echo "None"
}

# Export for use
export -f analyze_mr_security
```

### Layer 5: Two-Person Rule

Sensitive paths require two approvers:

| Path Pattern | Reason | Required Approvers |
|--------------|--------|-------------------|
| `lib/auth*` | Authentication | 2 |
| `**/settings.php` | Credentials | 2 |
| `.gitlab-ci.yml` | CI pipeline | 2 |
| `composer.json` | Dependencies | 2 |
| `lib/*secret*` | Secret handling | 2 |
| `scripts/commands/live*.sh` | Production deployment | 2 |
| `CLAUDE.md` | AI standing orders | 2 |

Configure in GitLab:
- Settings → Merge requests → Approval rules
- Create rule for each sensitive path pattern

### Layer 6: Post-Merge Monitoring

```bash
# lib/security-monitor.sh

post_deploy_security_check() {
    local site="$1"

    echo "=== Post-Deploy Security Audit: $site ==="

    # Check for unexpected outbound connections (requires site access)
    echo "Recent PHP errors:"
    ddev drush watchdog:show --type=php --severity=error --count=10 2>/dev/null || echo "N/A"

    # Check for new files in unexpected locations
    echo ""
    echo "PHP files in files directory (should be empty):"
    find "sites/$site/html/sites/default/files" -name "*.php" -mtime -1 2>/dev/null || echo "None"

    # Check for modified core files
    echo ""
    echo "Core integrity:"
    ddev drush core:status --field=drupal-version 2>/dev/null || echo "N/A"
}
```

### Layer 7: Contributor Trust Levels

Implement graduated trust based on contribution history:

| Trust Level | Requirements | Capabilities |
|-------------|--------------|--------------|
| New | First contribution | All changes reviewed, no sensitive paths |
| Contributor | 5+ merged MRs, 3+ months | Standard review, no sensitive paths |
| Trusted | 20+ merged MRs, 1+ year, vouched | Can review others, sensitive with 2nd approver |
| Maintainer | Appointed by project lead | Full access, can approve sensitive paths |

### Example: Detecting Hidden Malicious Code

**Scenario:** Developer submits "Fix typo in error message"

**What Claude should check:**

```
MR Analysis:
- Title: "Fix typo in error message"
- Files changed: 3 (expected: 1)
- Lines changed: 47 (expected: ~2)

Red Flags Detected:
1. File lib/backup.sh modified (not related to error messages)
2. New external URL added: http://evil.com/collect
3. New dependency: "logging-helper" (not in issue description)

Claude Response:
"This MR claims to fix a typo but modifies 3 files with 47 lines changed.
I found the following concerns:

1. lib/backup.sh was modified - this file handles backups, not error messages
2. A new external URL (http://evil.com/collect) was added
3. A new dependency 'logging-helper' was added without explanation

Please explain these changes or split this into separate MRs."
```

### CI Gate Configuration

Add to `.gitlab-ci.yml`:

```yaml
security_gate:
  stage: security
  script:
    - source lib/security-review.sh
    - analyze_mr_security origin/main > security-report.txt
    - cat security-report.txt

    # Fail on high-risk patterns
    - |
      if grep -q "WARNING:" security-report.txt; then
        echo "SECURITY REVIEW REQUIRED"
        echo "High-risk patterns detected. Manual review required."
        exit 1
      fi
  artifacts:
    paths:
      - security-report.txt
    when: always
  rules:
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
```

### Summary: Security Review Checklist

For every MR, verify:

- [ ] **Scope matches description** - Changes align with stated purpose
- [ ] **No unexpected files** - Only relevant files modified
- [ ] **No new dependencies** - Or dependencies are explained and audited
- [ ] **No suspicious patterns** - eval, exec, base64_decode, external URLs
- [ ] **No sensitive path changes** - Or has required approvers
- [ ] **CI security scan passed** - Automated checks complete
- [ ] **Proportional change size** - Lines changed match complexity

---

## Implementation Plan

### Phase 1: Foundation

- [ ] Create `docs/decisions/` directory structure
- [ ] Create ADR template and index
- [ ] Create decision-log.md
- [ ] Extend CLAUDE.md with standing orders section
- [ ] Create GitLab issue templates

### Phase 2: Issue Queue

- [ ] Configure GitLab labels (bug, task, feature, support, plan)
- [ ] Configure GitLab priority labels (P1-P4)
- [ ] Create issue templates in `.gitlab/issue_templates/`
- [ ] Document issue workflow in CONTRIBUTING.md

### Phase 3: Claude Integration

- [ ] Update CLAUDE.md with decision checking instructions
- [ ] Create `lib/decisions.sh` for querying decisions
- [ ] Add decision search to `pl` CLI
- [ ] Test Claude's decision-checking behavior

### Phase 4: Fork Support

- [ ] Document fork workflow in CONTRIBUTING.md
- [ ] Create `.nwp-fork.yml` schema (optional tracking)
- [ ] Add fork setup instructions to README
- [ ] Configure GitHub/GitLab PR templates for forks
- [ ] Test Claude governance with forked contributions

### Phase 5: Multi-Tier Support

- [ ] Create `.nwp-upstream.yml` schema
- [ ] Implement `pl sync upstream` command
- [ ] Implement `pl contribute` command
- [ ] Document tier setup process

### Phase 6: Automation

- [ ] GitLab CI for decision validation
- [ ] Automated ADR number assignment
- [ ] MR template with decision checklist
- [ ] Notification on new standing orders

### Phase 7: Security Review System

- [ ] Create `lib/security-review.sh` with `analyze_mr_security()`
- [ ] Add security scan stage to `.gitlab-ci.yml`
- [ ] Configure GitLab approval rules for sensitive paths
- [ ] Add security red flags to CLAUDE.md
- [ ] Create `lib/security-monitor.sh` for post-deploy checks
- [ ] Document contributor trust levels
- [ ] Test security gate with sample malicious MRs

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
