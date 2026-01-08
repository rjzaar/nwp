# NWP Roadmap - Pending & Future Work

**Last Updated:** January 8, 2026

Pending implementation items and future improvements for NWP.

> **For completed work, see [MILESTONES.md](MILESTONES.md)** (P01-P35)

---

## Current Status

| Metric | Value |
|--------|-------|
| Current Version | v0.12 |
| Test Success Rate | 98% |
| Completed Proposals | P01-P35 (100%) |
| Pending Proposals | F01-F06 |

---

## Phase Overview

| Phase | Focus | Proposals | Status |
|-------|-------|-----------|--------|
| Phase 1-5b | Foundation through Import | P01-P31 | ✅ Complete |
| Phase 5c | Live Deployment Automation | P32-P35 | ✅ Complete |
| **Phase 6** | **AI & Visual Testing** | **F01-F03** | **Future** |
| **Phase 7** | **Governance & Security** | **F04-F06** | **Future** |

---

## Phase 6: AI & Visual Testing (FUTURE)

### F01: GitLab MCP Integration for Claude Code
**Status:** PLANNED | **Priority:** MEDIUM | **Effort:** Low | **Dependencies:** NWP GitLab server

Enable Claude Code to directly interact with NWP GitLab via the Model Context Protocol (MCP):

**Benefits:**
- Claude can fetch CI logs directly without manual copy/paste
- Automatic investigation of CI failures
- Create issues for bugs found during code review
- Monitor pipeline status in real-time

**Implementation:**
1. Generate GitLab personal access token during setup
2. Store token in `.secrets.yml`
3. Configure MCP server in Claude Code
4. Add MCP configuration to `cnwp.yml`

**Success Criteria:**
- [ ] Token generated during GitLab setup
- [ ] Token stored in .secrets.yml
- [ ] MCP server configurable via setup.sh
- [ ] Claude can fetch CI logs via MCP

---

### F02: Automated CI Error Resolution
**Status:** PLANNED | **Priority:** LOW | **Effort:** Medium | **Dependencies:** F01

Extend MCP integration to automatically detect and fix common CI errors:

**Auto-fixable Errors:**
| Error Type | Detection | Auto-fix |
|------------|-----------|----------|
| PHPCS style | `phpcs` output | `phpcbf --fix` |
| Missing docblock | PHPStan error | Add docblock template |
| Unused import | PHPStan error | Remove import |

**Success Criteria:**
- [ ] Common PHPCS errors auto-fixed
- [ ] Issues created for complex errors
- [ ] Notification sent with resolution status

---

### F03: Visual Regression Testing (VRT)
**Status:** IN PROGRESS | **Priority:** MEDIUM | **Effort:** Medium | **Dependencies:** Behat BDD Framework

Automated visual regression testing using BackstopJS:

**Implementation:**
1. DDEV BackstopJS addon: `ddev get mmunz/ddev-backstopjs`
2. Configure scenarios for critical pages
3. Define viewports: mobile (375px), tablet (768px), desktop (1280px)
4. Integrate with GitLab CI pipeline

**Commands:**
```bash
ddev backstop reference     # Create baseline screenshots
ddev backstop test          # Compare against baseline
ddev backstop approve       # Approve changes as new baseline
```

**Success Criteria:**
- [x] DDEV BackstopJS addon installed
- [ ] Configuration created for test site
- [ ] Baseline screenshots captured
- [ ] Visual comparison tests pass
- [ ] GitLab CI stage integrated
- [ ] `pl vrt` command available

---

## Phase 7: Governance & Security (FUTURE)

### F04: Distributed Contribution Governance
**Status:** PROPOSED | **Priority:** HIGH | **Effort:** High | **Dependencies:** GitLab
**Proposal:** [DISTRIBUTED_CONTRIBUTION_GOVERNANCE.md](DISTRIBUTED_CONTRIBUTION_GOVERNANCE.md)

Establish a governance framework for distributed NWP development:

**Key Features:**
- Multi-tier repository topology (Canonical → Primary → Developer)
- Architecture Decision Records (ADRs) for tracking design decisions
- Issue queue categories following Drupal's model (Bug, Task, Feature, Support, Plan)
- Claude integration for decision enforcement and historical context
- CLAUDE.md as "standing orders" for AI-assisted governance

**Key Innovations:**
1. **Decision Memory** - Claude checks `CLAUDE.md` and `docs/decisions/` before implementing changes, explaining conflicts with previous decisions
2. **Scope Verification** - Claude compares MR claims vs actual diffs to detect hidden malicious code

**Implementation Phases:**
1. Foundation (decision records, ADR templates)
2. Issue Queue (GitLab labels, templates)
3. Claude Integration (decision checking, `lib/decisions.sh`)
4. Multi-Tier Support (upstream sync, contribute commands)
5. Automation (CI validation, MR templates)
6. Security Review System (malicious code detection)

**Success Criteria:**
- [ ] `docs/decisions/` directory with ADR template
- [ ] CLAUDE.md extended with standing orders
- [ ] GitLab issue templates created
- [ ] `pl sync upstream` command
- [ ] `pl contribute` command
- [ ] Security scan stage in CI

---

### F05: Security Headers & Hardening
**Status:** IMPLEMENTED | **Priority:** HIGH | **Effort:** Low | **Dependencies:** stg2live

Comprehensive security header configuration for nginx deployments:

**Headers Added:**
- `Strict-Transport-Security` (HSTS) - 1 year with includeSubDomains
- `Content-Security-Policy` - Drupal-compatible CSP
- `Referrer-Policy` - strict-origin-when-cross-origin
- `Permissions-Policy` - Disable geolocation, microphone, camera
- `server_tokens off` - Hide nginx version
- `fastcgi_hide_header` - Remove X-Generator, X-Powered-By

**Success Criteria:**
- [x] Security headers in stg2live nginx config
- [x] Server version hidden
- [x] CMS fingerprinting headers removed
- [ ] Security headers in linode_deploy.sh templates

---

### F06: Malicious Code Detection Pipeline
**Status:** PLANNED | **Priority:** HIGH | **Effort:** Medium | **Dependencies:** F04, GitLab CI
**Proposal:** Part of [DISTRIBUTED_CONTRIBUTION_GOVERNANCE.md](DISTRIBUTED_CONTRIBUTION_GOVERNANCE.md)

Automated security scanning for merge requests:

**CI Security Gates:**
| Tool | Purpose |
|------|---------|
| `composer audit` | Dependency vulnerabilities |
| `gitleaks` | Secret detection |
| `semgrep` | SAST scanning |
| Custom patterns | eval(), exec(), external URLs |

**Claude Review Checks:**
- Scope verification (diff matches MR description)
- Proportionality check (change size vs stated purpose)
- Red flag detection (auth changes, new dependencies, external URLs)
- Sensitive path alerts (settings.php, .gitlab-ci.yml, auth code)

**Success Criteria:**
- [ ] `lib/security-review.sh` created
- [ ] Security scan stage in `.gitlab-ci.yml`
- [ ] GitLab approval rules for sensitive paths
- [ ] Security red flags in CLAUDE.md
- [ ] Contributor trust levels documented

---

## Priority Matrix

| Proposal | Priority | Effort | Dependencies | Phase |
|----------|----------|--------|--------------|-------|
| F01 | MEDIUM | Low | GitLab | 6 |
| F02 | LOW | Medium | F01 | 6 |
| F03 | MEDIUM | Medium | Behat | 6 |
| F04 | HIGH | High | GitLab | 7 |
| F05 | HIGH | Low | stg2live | 7 |
| F06 | HIGH | Medium | F04, GitLab CI | 7 |

---

## References

- [MILESTONES.md](MILESTONES.md) - Completed implementation history
- [SCRIPTS_IMPLEMENTATION.md](SCRIPTS_IMPLEMENTATION.md) - Script architecture
- [CICD.md](CICD.md) - CI/CD pipeline setup
- [TESTING.md](TESTING.md) - Testing framework
- [DISTRIBUTED_CONTRIBUTION_GOVERNANCE.md](DISTRIBUTED_CONTRIBUTION_GOVERNANCE.md) - Governance proposal (F04)
- [WORKING_WITH_CLAUDE_SECURELY.md](WORKING_WITH_CLAUDE_SECURELY.md) - Secure AI workflows

---

*Document restructured: January 5, 2026*
*Phase 5c (P32-P35) completed: January 5, 2026*
*Phase 7 (F04-F06) added: January 8, 2026*
