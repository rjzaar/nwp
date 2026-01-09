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
| Completed Proposals | P01-P35, F04, F05, F07, F09 |
| Pending Proposals | F01-F03, F06, F08 |

---

## Phase Overview

| Phase | Focus | Proposals | Status |
|-------|-------|-----------|--------|
| Phase 1-5b | Foundation through Import | P01-P31 | ✅ Complete |
| Phase 5c | Live Deployment Automation | P32-P35 | ✅ Complete |
| Phase 6 | Governance & Security | F04, F05, F07 | ✅ Complete |
| Phase 6b | Security Pipeline | F06 | Planned |
| Phase 7 | Testing & CI Enhancement | F09 | ✅ Complete |
| **Phase 7b** | **CI Enhancements** | **F01-F03, F08** | **Future** |

---

## Recommended Implementation Order

Based on dependencies, current progress, and priority:

| Order | Proposal | Status | Rationale |
|-------|----------|--------|-----------|
| 1 | F05 | ✅ COMPLETE | Security headers in all deployment scripts |
| 2 | F04 | ✅ COMPLETE | All 8 phases done, governance framework complete |
| 3 | F09 | ✅ COMPLETE | Testing infrastructure with BATS, CI integration |
| 4 | F07 | ✅ COMPLETE | SEO/robots.txt for staging/production |
| 5 | F06 | PLANNED | Depends on F04 (now complete) |
| 6 | F01 | PLANNED | Foundation for F02, enhances CI |
| 7 | F03 | IN PROGRESS | Independent, visual testing |
| 8 | F08 | PROPOSED | Needs stable GitLab infrastructure |
| 9 | F02 | PLANNED | Depends on F01, lowest priority |

---

## Phase 6: Governance & Security (COMPLETE)

### F05: Security Headers & Hardening
**Status:** ✅ COMPLETE | **Priority:** HIGH | **Effort:** Low | **Dependencies:** stg2live

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
- [x] Security headers in linode_deploy.sh templates

---

### F04: Distributed Contribution Governance
**Status:** ✅ COMPLETE | **Priority:** HIGH | **Effort:** High | **Dependencies:** GitLab
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
- [x] GitLab issue templates created (Bug, Feature, Task, Support)
- [x] `pl upstream sync` command
- [x] `pl contribute` command
- [x] Security scan stage in CI (security:scan, security:review jobs)

---

### F07: SEO & Search Engine Control
**Status:** ✅ COMPLETE | **Priority:** HIGH | **Effort:** Medium | **Dependencies:** stg2live, recipes
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

**Success Criteria:**
- [x] X-Robots-Tag header on staging nginx configs
- [x] `templates/robots-staging.txt` created
- [x] `templates/robots-production.txt` with sitemap reference
- [x] Environment detection in deployment scripts
- [x] SEO settings in cnwp.yml schema
- [ ] Existing staging sites protected (requires redeployment)
- [ ] Production sites have working sitemap.xml (requires module install)

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
**Status:** ✅ COMPLETE | **Priority:** HIGH | **Effort:** High | **Dependencies:** Linode, GitLab CI
**Proposal:** [COMPREHENSIVE_TESTING_PROPOSAL.md](COMPREHENSIVE_TESTING_PROPOSAL.md)

Automated testing infrastructure using BATS framework with GitLab CI integration:

**Test Suites:**
- Unit tests (BATS) - ~2 minutes, every commit
- Integration tests (BATS) - ~5 minutes, every commit
- E2E tests (Linode) - ~45 minutes, nightly (placeholder)

**Test Structure:**
| Directory | Purpose | Tests |
|-----------|---------|-------|
| `tests/unit/` | Function-level tests | 76 tests |
| `tests/integration/` | Workflow tests | 72 tests |
| `tests/e2e/` | Full deployment tests | Placeholder |
| `tests/helpers/` | Shared test utilities | - |

**Coverage Goals:**
| Category | Current | Target |
|----------|---------|--------|
| Unit | ~40% | 80% |
| Integration | ~60% | 95% |
| E2E | ~10% | 80% |
| **Overall** | **~45%** | **85%** |

**Success Criteria:**
- [x] `tests/unit/` directory with BATS tests
- [x] `tests/integration/` modular test suite
- [x] `tests/e2e/` placeholder with documentation
- [x] `tests/helpers/test-helpers.bash` shared utilities
- [x] GitLab CI pipeline with lint, test, e2e stages
- [x] `scripts/commands/run-tests.sh` unified test runner
- [ ] E2E tests on Linode (infrastructure ready, tests pending)
- [ ] Test results dashboard

---

## Priority Matrix

| Order | Proposal | Priority | Effort | Dependencies | Phase | Status |
|-------|----------|----------|--------|--------------|-------|--------|
| 1 | F05 | HIGH | Low | stg2live | 6 | ✅ Complete |
| 2 | F04 | HIGH | High | GitLab | 6 | ✅ Complete |
| 3 | F09 | HIGH | High | Linode, GitLab CI | 7 | ✅ Complete |
| 4 | F07 | HIGH | Medium | stg2live, recipes | 6 | ✅ Complete |
| 5 | F06 | HIGH | Medium | F04, GitLab CI | 6b | Planned |
| 6 | F01 | MEDIUM | Low | GitLab | 7b | Planned |
| 7 | F03 | MEDIUM | Medium | Behat | 7b | In Progress |
| 8 | F08 | MEDIUM | Medium | verify.sh, test-nwp.sh, GitLab | 7b | Proposed |
| 9 | F02 | LOW | Medium | F01 | 7b | Planned |

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
*F09 (Testing) moved to position 3: January 9, 2026*
*F05, F04, F07, F09 completed: January 9, 2026*
