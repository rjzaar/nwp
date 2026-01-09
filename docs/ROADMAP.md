# NWP Roadmap - Pending & Future Work

**Last Updated:** January 9, 2026

Pending implementation items and future improvements for NWP.

> **For completed work, see [MILESTONES.md](MILESTONES.md)** (P01-P35)

---

## Current Status

| Metric | Value |
|--------|-------|
| Current Version | v0.17 |
| Test Success Rate | 98% |
| Completed Proposals | P01-P35 (100%) |
| Pending Proposals | F01-F09 |

---

## Phase Overview

| Phase | Focus | Proposals | Status |
|-------|-------|-----------|--------|
| Phase 1-5b | Foundation through Import | P01-P31 | ✅ Complete |
| Phase 5c | Live Deployment Automation | P32-P35 | ✅ Complete |
| **Phase 6** | **Governance & Security** | **F04-F07** | **In Progress** |
| **Phase 7** | **Testing & CI Enhancement** | **F01-F03, F08-F09** | **Future** |

---

## Recommended Implementation Order

Based on dependencies, current progress, and priority:

| Order | Proposal | Status | Rationale |
|-------|----------|--------|-----------|
| 1 | F05 | IMPLEMENTED | Only 1 item left - quick win |
| 2 | F04 | IN PROGRESS | 5/8 phases done, foundation for F06 |
| 3 | F07 | PROPOSED | No F-dependencies, protects staging now |
| 4 | F06 | PLANNED | Depends on F04 (mostly done) |
| 5 | F01 | PLANNED | Foundation for F02, enhances CI |
| 6 | F03 | IN PROGRESS | Independent, visual testing |
| 7 | F08 | PROPOSED | Needs stable GitLab infrastructure |
| 8 | F02 | PLANNED | Depends on F01, lowest priority |
| 9 | F09 | PROPOSED | High effort, builds on all testing |

---

## Phase 6: Governance & Security (IN PROGRESS)

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

### F04: Distributed Contribution Governance
**Status:** IN PROGRESS | **Priority:** HIGH | **Effort:** High | **Dependencies:** GitLab
**Proposal:** [DISTRIBUTED_CONTRIBUTION_GOVERNANCE.md](DISTRIBUTED_CONTRIBUTION_GOVERNANCE.md)
**Onboarding:** [CORE_DEVELOPER_ONBOARDING_PROPOSAL.md](CORE_DEVELOPER_ONBOARDING_PROPOSAL.md)

Establish a governance framework for distributed NWP development:

**Key Features:**
- Multi-tier repository topology (Canonical → Primary → Developer)
- Architecture Decision Records (ADRs) for tracking design decisions
- Issue queue categories following Drupal's model (Bug, Task, Feature, Support, Plan)
- Claude integration for decision enforcement and historical context
- CLAUDE.md as "standing orders" for AI-assisted governance
- Developer role detection and coders TUI management

**Key Innovations:**
1. **Decision Memory** - Claude checks `CLAUDE.md` and `docs/decisions/` before implementing changes
2. **Scope Verification** - Claude compares MR claims vs actual diffs to detect hidden malicious code
3. **Developer Identity** - Local NWP installations know the developer's role via `.nwp-developer.yml`
4. **Coders TUI** - Full management interface for coders with contribution tracking

**Implementation Phases:**
1. Foundation (decision records, ADR templates) - **COMPLETE**
2. Developer Roles (ROLES.md, access levels) - **COMPLETE**
3. Onboarding Automation (provision, offboarding) - **COMPLETE**
4. Developer Level Detection (`lib/developer.sh`) - **COMPLETE**
5. Coders TUI (`scripts/commands/coders.sh`) - **COMPLETE**
6. Issue Queue (GitLab labels, templates) - PENDING
7. Multi-Tier Support (upstream sync, contribute) - PENDING
8. Security Review System (malicious code detection) - PENDING

**Completed in January 2026:**
- [x] `docs/decisions/` directory with ADR template and 5 foundational ADRs
- [x] `docs/ROLES.md` - Formal role definitions (Newcomer -> Contributor -> Core -> Steward)
- [x] `CONTRIBUTING.md` - Entry point for developers
- [x] `coder-setup.sh provision` - Automated Linode provisioning
- [x] `coder-setup.sh remove` - Full offboarding with GitLab cleanup
- [x] `lib/developer.sh` - Developer level detection library
- [x] `scripts/commands/coders.sh` - Full TUI with arrow navigation, bulk actions, auto-sync

**Success Criteria:**
- [x] `docs/decisions/` directory with ADR template
- [x] `docs/ROLES.md` with role definitions
- [x] `CONTRIBUTING.md` as developer entry point
- [x] `coder-setup.sh provision` command
- [x] `coder-setup.sh remove` with full offboarding
- [x] `lib/developer.sh` for role detection
- [x] `scripts/commands/coders.sh` TUI with bulk actions
- [ ] GitLab issue templates created
- [ ] `pl sync upstream` command
- [ ] `pl contribute` command
- [ ] Security scan stage in CI

---

### F07: SEO & Search Engine Control
**Status:** PROPOSED | **Priority:** HIGH | **Effort:** Medium | **Dependencies:** stg2live, recipes
**Proposal:** [SEO_ROBOTS_PROPOSAL.md](SEO_ROBOTS_PROPOSAL.md)

Comprehensive search engine control ensuring staging sites are protected while production sites are optimized:

**Staging Protection (4 Layers):**
| Layer | Method | Purpose |
|-------|--------|---------|
| 1 | X-Robots-Tag header | `noindex, nofollow` on all responses |
| 2 | robots.txt | `Disallow: /` for all crawlers |
| 3 | Meta robots | noindex on all Drupal pages |
| 4 | HTTP Basic Auth | Optional access control |

**Production Optimization:**
- Sitemap.xml generation via Simple XML Sitemap module
- robots.txt with `Sitemap:` directive
- AI crawler controls (GPTBot, ClaudeBot, etc.)
- Proper canonical URLs and meta tags

**Current Issues:**
- Staging sites use production robots.txt (fully indexable)
- No X-Robots-Tag headers on staging
- Production sites missing sitemap.xml
- 404 pages missing noindex meta tag

**Success Criteria:**
- [ ] X-Robots-Tag header on staging nginx configs
- [ ] `templates/robots-staging.txt` created
- [ ] `templates/robots-production.txt` with sitemap reference
- [ ] Environment detection in deployment scripts
- [ ] SEO settings in cnwp.yml schema
- [ ] Existing staging sites protected
- [ ] Production sites have working sitemap.xml

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

## Phase 7: Testing & CI Enhancement (FUTURE)

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

### F08: Dynamic Cross-Platform Badges
**Status:** PROPOSED | **Priority:** MEDIUM | **Effort:** Medium | **Dependencies:** verify.sh, test-nwp.sh, GitLab infrastructure
**Proposal:** [DYNAMIC_BADGES_PROPOSAL.md](DYNAMIC_BADGES_PROPOSAL.md)

Add dynamic badges using Shields.io that work on both GitHub and GitLab READMEs, with full support for self-hosted GitLab instances:

**Badge Types:**
| Badge | Source | Display |
|-------|--------|---------|
| Pipeline | GitLab CI native | CI pass/fail status |
| Coverage | GitLab CI native | Code coverage % |
| **Verification** | .badges.json | Features verified % |
| **Tests** | .badges.json | test-nwp pass rate % |

**What is Shields.io?**
- Free, open-source badge service (shields.io)
- Serves 1.6B+ images/month
- Used by VS Code, Vue.js, Bootstrap
- Supports dynamic badges from JSON endpoints

**Self-Hosted GitLab Support:**
```bash
./setup.sh gitlab --domain git.example.org --with-badges
./setup.sh gitlab-badges  # Add to existing GitLab
```

**Implementation:**
1. Create `lib/badges-dynamic.sh` for JSON generation
2. Add `pl badges json` command
3. CI job generates `.badges.json` on main branch
4. READMEs use Shields.io endpoint badges
5. `templates/gitlab-ci-badges.yml` for any GitLab instance
6. `gitlab_configure_badges()` in `lib/git.sh`

**Success Criteria:**
- [ ] `lib/badges-dynamic.sh` created
- [ ] `.badges.json` generated by CI
- [ ] Verification badge on GitHub/GitLab READMEs
- [ ] Test pass rate badge on READMEs
- [ ] Nightly job updates test results
- [ ] Self-hosted GitLab badge automation

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

### F09: Comprehensive Testing Infrastructure
**Status:** PROPOSED | **Priority:** HIGH | **Effort:** High | **Dependencies:** Linode, GitLab CI
**Proposal:** [COMPREHENSIVE_TESTING_PROPOSAL.md](COMPREHENSIVE_TESTING_PROPOSAL.md)

Automated testing infrastructure using Linode for comprehensive E2E testing:

**Test Environment Types:**
| Type | Purpose | Instance | Duration |
|------|---------|----------|----------|
| Fresh Install | Clean server setup | Nanode | 2h |
| Pre-configured | Existing sites | Standard-1 | 4h |
| Production | Multi-region deploy | 2x Standard-2 | 6h |
| Multi-coder | Developer scenarios | Std-2 + 2x Nanode | 4h |

**Test Suites:**
- Unit tests (BATS) - ~2 minutes, every commit
- Integration tests (DDEV) - ~15 minutes, main branch
- E2E tests (Linode) - ~45 minutes, nightly
- TUI tests (Expect) - ~10 minutes, TUI file changes

**Coverage Goals:**
| Category | Current | Target |
|----------|---------|--------|
| Unit | ~20% | 80% |
| Integration | ~60% | 95% |
| E2E | ~30% | 80% |
| TUI | 0% | 70% |
| **Overall** | **~40%** | **85%** |

**Estimated Cost:** ~$32/month

**Success Criteria:**
- [ ] `tests/unit/` directory with BATS tests
- [ ] `tests/integration/` modular test suite
- [ ] `tests/e2e/provision-and-test.sh` for Linode
- [ ] `tests/tui/` with Expect scripts
- [ ] GitLab CI pipeline with all stages
- [ ] Auto-cleanup of test instances
- [ ] Test results dashboard

---

## Priority Matrix

| Order | Proposal | Priority | Effort | Dependencies | Phase |
|-------|----------|----------|--------|--------------|-------|
| 1 | F05 | HIGH | Low | stg2live | 6 |
| 2 | F04 | HIGH | High | GitLab | 6 |
| 3 | F07 | HIGH | Medium | stg2live, recipes | 6 |
| 4 | F06 | HIGH | Medium | F04, GitLab CI | 6 |
| 5 | F01 | MEDIUM | Low | GitLab | 7 |
| 6 | F03 | MEDIUM | Medium | Behat | 7 |
| 7 | F08 | MEDIUM | Medium | verify.sh, test-nwp.sh, GitLab | 7 |
| 8 | F02 | LOW | Medium | F01 | 7 |
| 9 | F09 | HIGH | High | Linode, GitLab CI | 7 |

---

## References

### Core Documentation
- [MILESTONES.md](MILESTONES.md) - Completed implementation history
- [SCRIPTS_IMPLEMENTATION.md](SCRIPTS_IMPLEMENTATION.md) - Script architecture
- [CICD.md](CICD.md) - CI/CD pipeline setup
- [TESTING.md](TESTING.md) - Testing framework

### Governance (F04)
- [DISTRIBUTED_CONTRIBUTION_GOVERNANCE.md](DISTRIBUTED_CONTRIBUTION_GOVERNANCE.md) - Governance proposal
- [CORE_DEVELOPER_ONBOARDING_PROPOSAL.md](CORE_DEVELOPER_ONBOARDING_PROPOSAL.md) - Developer onboarding
- [CODER_ONBOARDING.md](CODER_ONBOARDING.md) - New coder guide
- [ROLES.md](ROLES.md) - Developer role definitions
- [decisions/](decisions/) - Architecture Decision Records

### Security (F05, F06)
- [DATA_SECURITY_BEST_PRACTICES.md](DATA_SECURITY_BEST_PRACTICES.md) - Security architecture
- [WORKING_WITH_CLAUDE_SECURELY.md](WORKING_WITH_CLAUDE_SECURELY.md) - Secure AI workflows

### Proposals
- [SEO_ROBOTS_PROPOSAL.md](SEO_ROBOTS_PROPOSAL.md) - SEO & search engine control (F07)
- [DYNAMIC_BADGES_PROPOSAL.md](DYNAMIC_BADGES_PROPOSAL.md) - Cross-platform badges (F08)
- [COMPREHENSIVE_TESTING_PROPOSAL.md](COMPREHENSIVE_TESTING_PROPOSAL.md) - Testing infrastructure (F09)

---

*Document restructured: January 5, 2026*
*Phase 5c (P32-P35) completed: January 5, 2026*
*Phase 6-7 reorganized: January 9, 2026*
*Proposals reordered by implementation priority: January 9, 2026*
