# Decision Log

Quick decisions that don't warrant full ADRs but should be recorded for future reference.

For significant architectural decisions, create a proper ADR in this directory.

---

## 2026-01

### 2026-01-08: Developer role detection
**Context:** Core developer onboarding proposal
**Question:** How should NWP local code know the developer's access level?
**Decision:** Use `.nwp-developer.yml` file in project root (gitignored)
**Decided by:** Rob
**Related:** CORE_DEVELOPER_ONBOARDING_PROPOSAL.md

### 2026-01-08: Contribution tracking dimensions
**Context:** Coders TUI design
**Question:** What contribution metrics should be tracked?
**Decision:** Track: commits, merge requests, reviews, issues created/closed, documentation, tests
**Decided by:** Rob
**Related:** CORE_DEVELOPER_ONBOARDING_PROPOSAL.md

### 2026-01-08: Default GitLab access level for new coders
**Context:** coder-setup.sh GitLab integration
**Question:** What access level should new coders receive by default?
**Decision:** Developer (30) - allows branch push and MR creation, but not merge to main
**Decided by:** Rob
**Related:** coder-setup.sh

---

## Template

```markdown
### YYYY-MM-DD: [Short title]
**Context:** [What were you working on?]
**Question:** [What needed to be decided?]
**Decision:** [What was decided?]
**Decided by:** [Who made the decision?]
**Related:** [Issue #, file, or ADR reference]
```
