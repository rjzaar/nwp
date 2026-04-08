# NWP Roadmap - Pending & Future Work

**NWP — Narrow Way Project** | Drupal hosting, deployment & infrastructure automation

**Last Updated:** April 8, 2026

Pending implementation items and future improvements for **NWP core**.

> **NWP-only.** This roadmap covers NWP itself. Site-specific roadmaps for
> AVC, Sacred Sources (ss), Mass Times (mt), CathNet, and Directory Search
> (dir1) live inside each site at `sites/<name>/docs/proposals/`. Use
> `pl proposals` to aggregate everything into one view.

> **2026-04-08 renumbering.** The NWP F-series was made consecutive on
> 2026-04-08. Old F22–F26 slots became F16–F20; F18–F21 (the old
> site-specific proposals) moved into per-project namespaces (M01, M02,
> C01, C02, C02a, C03, S01). A new F21 was created for the distributed
> build/deploy pipeline (ADR-0017). See
> [docs/proposals/README.md](../proposals/README.md) for the full
> mapping. Old IDs survive as aliases inside each renamed file.

> **For completed work, see [Milestones](../reports/milestones.md)**
> - Phase 1-5c: P01-P35 (Foundation through Live Deployment)
> - Phase 6-7: F04 (phases 1-5), F05, F07, F09, F12
> - Phase 8: P50, P51 (Unified Verification System)
> - Phase 9: P53-P59 (Verification & Production Hardening)
> - Phase 10 (partial): F03, F13, F14, F15 (Developer Experience)
> - Phase 11: F17 (Project Separation, formerly F23 — phases 1–8, 10)
> - Phase 12: F19 (Pre-Baseline Cleanup, formerly F25)

---

## Current Status

| Metric | Value |
|--------|-------|
| Current Version | v0.30.0 (F17 phases 1–8, 10 landed; F19 baseline reset complete) |
| Test Success Rate | 99.5% (Machine Verified) |
| Completed NWP Proposals | P01–P35, P50–P51, P53–P60, F03–F05, F07, F09, F12–F15, F17 (phases 1–8, 10), F19 |
| Proposed NWP Proposals | F16 (Claude Code Web), F18 (Unified Backup), F20 (SolveIt), F21 (Distributed Build/Deploy Pipeline) |
| Pending NWP Proposals | F01, F02, F06, F08 |
| Rejected NWP Proposals | P52 (rename — NWP is the permanent project name) |
| Experimental/Outlier | X01, X02 |
| Recent Enhancements | v0.30.0: F17 project separation v2 — per-site `.nwp.yml`, schema migrations, `pl site/server/proposals` commands, modules/pipelines/backups moved into sites |
| Site-specific work | See `sites/<name>/docs/proposals/` and `pl proposals` |

---

## Proposal Designation System

| Prefix | Meaning | Count | Example |
|--------|---------|-------|---------|
| **P##** | Core Phase Proposals | 35 complete | P01-P35: Foundation→Live Deployment |
| **F##** | Feature Enhancements | 9 complete, 6 pending | F04: Governance, F09: Testing, F12: Todo |
| **X##** | Experimental Outliers | 2 exploratory | X01: AI Video, X02: Local Voice Agent |

**Why different prefixes?**
- P01-P35: Core NWP infrastructure built during phases 1-5c (all complete)
- F01+: Post-foundation feature additions for mature platform (Phase 6+)
- X01+: Exploratory proposals outside core Drupal deployment mission

---

## Phase Overview

| Phase | Focus | Proposals | Status |
|-------|-------|-----------|--------|
| Phase 1-5b | Foundation through Import | P01-P31 | ✅ Complete |
| Phase 5c | Live Deployment Automation | P32-P35 | ✅ Complete |
| Phase 6 | Governance & Security | F04, F05, F07, F12 | ✅ Complete |
| Phase 6b | Security Pipeline | F06 | Possible |
| Phase 7 | Testing & CI Enhancement | F09 | ✅ Complete |
| **Phase 7b** | **CI Enhancements** | **F01-F03, F08** | **Possible** |
| **Phase 8** | **Unified Verification** | **P50, P51** | **✅ Complete** |
| **Phase 9** | **Verification & Production Hardening** | **P53-P59** | **✅ Complete** |
| **Phase 10** | **Developer Experience** | **F13, F14, F15** (F10 → [guide](../guides/local-llm.md), F11 subsumed) | **✅ Complete** |
| **Phase 11** | **Project Separation** | **F17 (was F23)** | **✅ Complete (phases 1–8, 10)** |
| **Phase 12** | **Baseline Reset & v0.30.0** | **F19 (was F25)** | **✅ Complete** |
| **Phase 13** | **Distributed Build/Deploy Pipeline** | **F21 (new, implements ADR-0017)** | **PROPOSED** |
| **Phase 14** | **Claude Code Web + Backup + SolveIt** | **F16 (was F22), F18 (was F24), F20 (was F26)** | **PROPOSED** |
| **Phase X** | **Experimental/Outliers** | **X01, X02** | **X01 Possible, X02 Proposed** |

---

## Recommended Implementation Order

Based on dependencies, current progress, and priority:

| Order | Proposal | Status | Rationale |
|-------|----------|--------|-----------|
| | **Completed** | | |
| 1 | F05 | ✅ COMPLETE | Security headers in all deployment scripts |
| 2 | F04 | ✅ COMPLETE | Governance framework (phases 1-5) |
| 3 | F09 | ✅ COMPLETE | Testing infrastructure with BATS, CI integration |
| 4 | F07 | ✅ COMPLETE | SEO/robots.txt for staging/production |
| 5 | F12 | ✅ COMPLETE | Unified todo command with TUI and notifications |
| 6 | P50 | ✅ COMPLETE | Unified verification system |
| 7 | P51 | ✅ COMPLETE | AI-powered (functional) verification |
| | **Next: Verification Fixes (Phase 9a)** | | *Fix what's broken before building more* |
| 8 | P54 | ✅ COMPLETE | Fix ~65 failing verification tests, 98%+ pass rate |
| 9 | P53 | ✅ COMPLETE | Fix misleading "AI" naming and badge accuracy |
| 10 | P58 | ✅ COMPLETE | Test dependency handling (helpful error messages) |
| | **Next: Production Hardening (Phase 9b)** | | *Features tests expect but don't exist yet* |
| 11 | P56 | ✅ COMPLETE | UFW, fail2ban, SSL hardening for production servers |
| 12 | P57 | ✅ COMPLETE | Redis/Memcache, PHP-FPM tuning, nginx optimization |
| | **Next: Developer Experience (Phase 10)** | | *Quality of life improvements* |
| 13 | F13 | ✅ COMPLETE | Centralize timezone configuration |
| 14 | F15 | ✅ COMPLETE | SSH user management + developer key onboarding (~10h) |
| — | F10 | → GUIDE | Local LLM Support → [docs/guides/local-llm.md](../guides/local-llm.md) (2026-04-08); provisioning tracked under F21 Phase 3a |
| — | F11 | RETIRED | Developer workstation LLM config — subsumed by local-llm guide + F21 Phase 3a |
| 17 | F14 | ✅ COMPLETE | Claude API team management, spend controls |
| | **Later / Conditional** | | |
| 18 | P55 | ✅ COMPLETE | Opportunistic human verification (4-5 weeks, opt-in) |
| - | P52 | ❌ REJECTED | Rename rejected — NWP is the permanent project name |
| 20 | F03 | ✅ COMPLETE | Visual regression testing (pl vrt) |
| | **Possible (deprioritized)** | | *Reconsidered only if circumstances change* |
| - | F01 | POSSIBLE | GitLab MCP Integration |
| - | F02 | POSSIBLE | Automated CI Error Resolution |
| - | F06 | POSSIBLE | Malicious Code Detection Pipeline |
| - | F08 | POSSIBLE | Dynamic Cross-Platform Badges |
| - | X01 | POSSIBLE | AI Video Generation |

---

## Phase 6: Governance & Security

### F04: Distributed Contribution Governance (Phases 6-8)
**Status:** PARTIAL (Phases 1-5 Complete, Phases 6-8 Pending) | **Priority:** HIGH | **Effort:** Medium | **Dependencies:** GitLab
**Proposal:** [distributed-contribution-governance.md](distributed-contribution-governance.md)

**Phases 1-5 Complete** (see [Milestones](../reports/milestones.md#f04-distributed-contribution-governance-phases-1-5)):
- Foundation, Developer Roles, Onboarding Automation, Developer Detection, Coders TUI

**Remaining Phases:**

**Phase 6: Issue Queue (PENDING)**
- GitLab issue templates for Bug, Feature, Task, Support, Plan
- Label taxonomy following Drupal's model
- Issue triage workflow
- Priority and severity classifications

**Phase 7: Multi-Tier Support (PENDING)**
- `pl upstream sync` - Sync changes from canonical repository
- `pl contribute` - Submit changes to upstream
- Merge request workflow for distributed development
- Conflict resolution helpers

**Phase 8: Security Review System (PENDING)**
- Automated security scanning for merge requests
- Malicious code pattern detection
- Sensitive file path approvals
- See F06 for detailed security pipeline

---

### F07: SEO & Search Engine Control
**Status:** ✅ COMPLETE (implementation) | **Proposal:** [F07-seo-robots.md](../proposals/F07-seo-robots.md)

**Implementation Complete** (see [Milestones](../reports/milestones.md#f07-seo--search-engine-control)):
- All 4-layer staging protection implemented
- Production optimization features available
- Templates, scripts, and configuration ready

**Note:** Deployment to existing sites is a usage task, not a development task. Users can redeploy staging sites or apply settings as needed. See proposal for deployment instructions.

---

### F06: Malicious Code Detection Pipeline
**Status:** POSSIBLE (deprioritized by Deep Analysis re-evaluation) | **Priority:** LOW | **Effort:** Medium | **Dependencies:** F04, GitLab CI
**Proposal:** Part of [distributed-contribution-governance.md](distributed-contribution-governance.md)

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
**Status:** POSSIBLE (deprioritized by Deep Analysis re-evaluation) | **Priority:** LOW | **Effort:** Low | **Dependencies:** NWP GitLab server

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
4. Add MCP configuration to `nwp.yml`

**Success Criteria:**
- [ ] Token generated during GitLab setup
- [ ] Token stored in .secrets.yml
- [ ] MCP server configurable via setup.sh
- [ ] Claude can fetch CI logs via MCP

---

### F03: Visual Regression Testing (VRT)
**Status:** ✅ COMPLETE | **Priority:** MEDIUM | **Effort:** Medium | **Dependencies:** Behat BDD Framework

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
**Status:** POSSIBLE (deprioritized by Deep Analysis re-evaluation) | **Priority:** LOW | **Effort:** Medium | **Dependencies:** verify.sh, GitLab infrastructure
**Proposal:** [F08-dynamic-badges.md](../proposals/F08-dynamic-badges.md)

Add dynamic badges using Shields.io that work on both GitHub and GitLab READMEs, with full support for self-hosted GitLab instances:

**Badge Types:**
| Badge | Source | Display |
|-------|--------|---------|
| Pipeline | GitLab CI native | CI pass/fail status |
| Coverage | GitLab CI native | Code coverage % |
| **Verification** | .badges.json | Features verified % |
| **Tests** | .badges.json | Verification pass rate % |

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
**Status:** POSSIBLE (deprioritized by Deep Analysis re-evaluation) | **Priority:** LOW | **Effort:** Medium | **Dependencies:** F01

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

## Phase 8: Developer Experience (FUTURE)

### F10: Local LLM Support & Privacy Options — PROMOTED TO GUIDE (2026-04-08)

The F10 proposal content was always a how-to guide — installation steps,
hardware sizing, model selection, privacy trade-offs — not a feature
proposal with phases and success criteria. On 2026-04-08 it was moved to
[`docs/guides/local-llm.md`](../guides/local-llm.md) and the proposal slot
was retired.

The actual "install and persist a local LLM on a NWP-managed machine" work
is now tracked under **F21 Phase 3a — mini as local-LLM agent**
([proposal](../proposals/F21-distributed-build-deploy-pipeline.md)), which
is the concrete provisioning plan the guide describes at the abstract level.

Any previously planned `pl llm …` CLI surface is deliberately *not*
committed to yet. F21 Phase 3a leaves the CLI question open until mini's
agent role has stabilised; the guide documents the manual `ollama` CLI and
REST API until then.

---

### F11: Developer Workstation Local LLM Configuration — SUBSUMED (2026-04-08)

F11 described an ideal local LLM configuration for a specific developer
workstation (Ryzen 9 + RTX 2060) and never had a corresponding file. Its
intent is fully covered by:

- [`docs/guides/local-llm.md`](../guides/local-llm.md) — the hardware-agnostic guide (promoted from F10)
- **F21 Phase 3a — mini as local-LLM agent** — the concrete provisioning
  of NWP's actual production local-LLM machine (mini, Beelink Ryzen AI
  MAX+ 395 with Radeon 8060S iGPU via Vulkan, which landed ~2× the
  benchmark speed the F11 RTX 2060 target was designed around)

The F11 slot is **retired**; do not reclaim the number.

---

### F15: SSH User Management
**Status:** ✅ COMPLETE | **Priority:** MEDIUM | **Effort:** ~10 hours (practical version) | **Dependencies:** None
**Proposal:** [F15-ssh-user-management.md](../proposals/F15-ssh-user-management.md)

Unify NWP's 7 different approaches to SSH user determination and add per-developer SSH key management.

**Problem:**
- Hardcoded user assumptions in `live2stg.sh` and `remote.sh`
- Inconsistent behavior between commands
- No streamlined flow for developer SSH key onboarding

**Practical Version (DO IT - ~10 hours):**
1. Create `get_ssh_user()` function in `lib/ssh.sh` with resolution chain (2h)
2. Fix hardcoded scripts: `live2stg.sh:139-140`, `lib/remote.sh:99` (1h)
3. Add `ssh_user` field to recipe definitions and `example.nwp.yml` (1h)
4. Add `--ssh-key` / `--ssh-key-file` flags to `coder-setup.sh add` (2h)
5. Add `pl coder-setup deploy-key` for server key deployment (2h)
6. Add `pl coder-setup key-audit` for annual SSH key review (1h)
7. Update fail2ban in StackScripts to whitelist known developer IPs (1h)

**Postponed (implement only if scaling):**
- Two-tier sudo access, audit logging, automated key rotation, migration tooling

**Success Criteria:**
- [ ] `get_ssh_user()` function with fallback chain
- [ ] `live2stg.sh` and `lib/remote.sh` use dynamic SSH user
- [ ] `coder-setup.sh add --ssh-key` registers key to GitLab and servers
- [ ] Annual key audit available via `pl coder-setup key-audit`
- [ ] Standard documented in example.nwp.yml

---

### F13: Timezone Configuration
**Status:** ✅ COMPLETE | **Priority:** MEDIUM | **Effort:** Low | **Dependencies:** None
**Proposal:** [F13-timezone-configuration.md](../proposals/F13-timezone-configuration.md)

Centralize timezone configuration in `nwp.yml` instead of hardcoding across 14+ scripts.

**Problem:**
- Timezone hardcoded in 3 different values across 14 files (`America/New_York`, `Australia/Sydney`, `UTC`)
- No way to change timezone without editing multiple scripts
- Cron jobs, server provisioning, and status displays make independent assumptions

**Solution:**
- `settings.timezone` global default in `nwp.yml`
- `sites.<name>.timezone` per-site override
- Inheritance: site → settings → UTC (fallback)
- Helper functions for any script to read effective timezone

**Affected Areas:**
- Linode server provisioning (6 files)
- Financial monitor cron and scheduling (3 files)
- Backup scheduling (`schedule.sh`)
- GitLab Rails timezone
- DDEV container timezone
- Drupal site timezone during install

**Success Criteria:**
- [ ] `settings.timezone` in `nwp.yml` and `example.nwp.yml`
- [ ] Per-site override documented in `example.nwp.yml`
- [ ] Helper functions for timezone access
- [ ] No hardcoded timezone values remain (except UTC fallback)
- [ ] `fin-monitor` reads timezone from nwp.yml
- [ ] Linode provisioning reads timezone from nwp.yml

---

### F14: Claude API Integration
**Status:** ✅ COMPLETE | **Priority:** MEDIUM | **Effort:** Medium | **Dependencies:** None (complements the [local LLM guide](../guides/local-llm.md) for provider-choice scenarios)
**Proposal:** [F14-claude-api-integration.md](../proposals/F14-claude-api-integration.md)

Integrate Claude API key management into NWP's two-tier secrets architecture for team provisioning, spend control, and consistent configuration.

**Problem:**
- No managed way to provision Claude API access for coders
- No spend limits or usage visibility across the team
- Each coder configures Claude Code independently
- No key rotation or security controls

**Solution:**
- `claude:` section in `.secrets.yml` for org/admin API keys
- `settings.claude:` in `nwp.yml` for spend limits and model defaults
- `bootstrap-coder.sh` provisions workspace-scoped API keys during onboarding
- Admin API enforces per-coder monthly spend limits
- Key rotation, usage monitoring, OpenTelemetry integration

**Success Criteria:**
- [ ] Claude secrets in `.secrets.example.yml`
- [ ] Claude settings in `example.nwp.yml`
- [ ] `lib/claude-api.sh` with provisioning and rotation functions
- [ ] `bootstrap-coder.sh` provisions API keys during onboarding
- [ ] Per-coder spend limits enforced via Admin API
- [ ] Usage monitoring and OTEL metrics export
- [ ] Claude Code managed settings with deny rules

---

### F09: Comprehensive Testing Infrastructure
**Status:** ✅ COMPLETE (infrastructure) | **Proposal:** [F09-comprehensive-testing.md](../proposals/F09-comprehensive-testing.md)

**Infrastructure Complete** (see [Milestones](../reports/milestones.md#f09-comprehensive-testing-infrastructure)):
- BATS framework with 148 tests (76 unit + 72 integration)
- GitLab CI integration with lint, test, e2e stages
- Interactive verification console with schema v2
- `pl verify` TUI, `pl run-tests` unified test runner
- E2E test infrastructure ready

**Remaining Work:**
- [ ] E2E tests on Linode (infrastructure ready, actual tests pending)
- [ ] Test results dashboard (optional enhancement)

---

## Phase 9: Verification & Production Hardening (✅ COMPLETE)

> **Dependency chain:** P54 must come first — it fixes the test infrastructure that P53, P56, P57, and P58 all depend on. P55 and P52 are independent but should come later.

### Phase 9a: Fix What's Broken

#### P54: Verification Test Infrastructure Fixes
**Status:** ✅ COMPLETE | **Priority:** HIGH | **Effort:** 2-3 days | **Dependencies:** P50
**Proposal:** [P54-verification-test-fixes.md](../proposals/P54-verification-test-fixes.md)

Fix ~65 failing automatable verification tests caused by systemic issues, not real bugs. Root causes:

| Category | Count | Problem |
|----------|-------|---------|
| Missing script | 6 | `test-nwp.sh` deleted but still referenced |
| Script sourcing | ~35 | Scripts run `main "$@"` when sourced for testing |
| Missing functions | 9 | `lib/git.sh` tests expect functions that don't exist |
| Interactive TUI | 5 | `coders.sh` times out waiting for input |
| Grep-based detection | 6 | Tests grep for unimplemented features (→ P56/P57/P58) |
| Site dependencies | ~8 | Backup tests need running site that may not exist |

**Implementation:**
1. Remove orphaned test-nwp references from `.verification.yml`
2. Add execution guards (`BASH_SOURCE` check) to 15 scripts
3. Add missing `git_add_all()`, `git_has_changes()`, `git_get_current_branch()` to `lib/git.sh`
4. Add `--collect` flag to `coders.sh` for machine-readable output
5. Replace grep-based tests with functional tests (or remove for unimplemented features)
6. Add test dependency sequencing (`depends_on`, `skip_if_missing`)
7. Create pre-commit hook to prevent future orphaned tests

**Success Criteria:**
- [ ] `pl verify --run --depth=thorough` reaches 98%+ pass rate
- [ ] Execution guards on 15 affected scripts
- [ ] 3 git functions added and passing
- [ ] Pre-commit hook preventing orphaned tests

---

#### P53: Verification Categorization & Badge Accuracy
**Status:** ✅ COMPLETE | **Priority:** MEDIUM | **Effort:** 2-3 days | **Dependencies:** P50
**Proposal:** [P53-verification-badge-accuracy.md](../proposals/P53-verification-badge-accuracy.md)

Fix three accuracy issues in the verification system:

1. **"AI Verification" is misleading** — P51's "AI-Powered Deep Verification" contains zero AI/LLM calls. It's scenario-based bash/drush testing. Rename `--ai` flag to `--functional`.
2. **Machine % denominator is wrong** — 88% badge includes 123 non-automatable items in denominator, deflating the score. Correct: 411/458 automatable = 90%.
3. **No category distinction** — Human-judgment items lumped with automatable ones.

**Changes:**
- Rename `--ai` → `--functional` (breaking: remove `--ai` entirely)
- Fix percentage calculation to exclude non-automatable items from denominator
- Add `category` field to `.verification.yml` schema
- Update badge display to show per-category coverage

**Success Criteria:**
- [ ] `--functional` flag replaces `--ai`
- [ ] Badge percentages use correct denominators
- [ ] Categories distinguish automatable vs human-required items

---

#### P58: Test Command Dependency Handling
**Status:** ✅ COMPLETE | **Priority:** MEDIUM | **Effort:** 3-5 days | **Dependencies:** P54
**Proposal:** [P58-test-dependency-handling.md](../proposals/P58-test-dependency-handling.md)

Add dependency checking and helpful error messages to `test.sh` when PHPCS, PHPStan, or PHPUnit are missing. Currently tests fail silently or with cryptic errors.

**Features:**
- `check_test_dependencies()` function detecting missing tools
- Clear error messages with installation instructions
- `--check-deps` flag to show status of all test dependencies
- `--install-deps` flag for auto-installation
- `--skip-missing` flag to skip unavailable test suites gracefully

**Success Criteria:**
- [ ] Clear error messages when test tools are missing
- [ ] `--check-deps`, `--install-deps`, `--skip-missing` flags working
- [ ] Combined flags documentation satisfies grep test

---

### Phase 9b: Production Hardening

#### P56: Production Security Hardening
**Status:** ✅ COMPLETE | **Priority:** MEDIUM | **Effort:** 1-2 weeks | **Dependencies:** P54
**Proposal:** [P56-produce-security-hardening.md](../proposals/P56-produce-security-hardening.md)

Add security hardening features to `produce.sh` for production server provisioning. Currently verification tests expect these features but they don't exist. Also includes developer SSH key management for secure onboarding (see P56 Section 7).

**Features:**
- UFW firewall configuration (deny incoming, allow SSH/HTTP/HTTPS)
- Fail2ban intrusion prevention (SSH, nginx brute-force protection)
- SSL hardening (TLSv1.2+, strong ciphers, DH parameters, HSTS)
- Security headers (X-Frame-Options, CSP, X-Content-Type-Options)
- Developer SSH key onboarding via `coder-setup.sh` (key submission, approval, deployment, revocation)
- Annual SSH key audit

**CLI options:** `--no-firewall`, `--no-fail2ban`, `--no-ssl-hardening`, `--security-only`

**Success Criteria:**
- [ ] UFW, fail2ban, SSL hardening implemented in `produce.sh`
- [ ] SSL Labs test scores A or A+
- [ ] All features optional via CLI flags
- [ ] Developer SSH key onboarding integrated with `coder-setup.sh`

---

#### P59: SSH IdentitiesOnly Hardening (Fail2ban Lockout Fix)
**Status:** ✅ COMPLETE (v0.31.0) | **Priority:** HIGH | **Effort:** Medium | **Dependencies:** None
**Proposal:** [P59-ssh-identitiesonly-hardening.md](../proposals/P59-ssh-identitiesonly-hardening.md)

Force `IdentitiesOnly=yes` on every `ssh`, `scp`, and `rsync` call in NWP so that SSH does not offer every key in `~/.ssh/` on every connection. Without this, developers with several keys trip fail2ban (`maxretry=3`) and are locked out of nwpcode.org.

**Problem:**
- Developers with >3 keys in `~/.ssh/` were intermittently locked out of `97.107.137.88` by fail2ban
- Root cause: NWP scripts ssh by raw IP, bypassing `~/.ssh/config` Host aliases, so OpenSSH offers every key it knows about until one succeeds
- ~80 ssh/scp/rsync call sites across `lib/` and `scripts/commands/` had no `IdentitiesOnly` option

**Solution:**
- New helpers in `lib/ssh.sh`: `nwp_ssh_opts <name>`, `nwp_ssh`, `nwp_scp`, `nwp_rsync`, `_nwp_ssh_args_for`, `NWP_SSH_HARDENING_OPTS`
- `lib/common.sh` auto-sources `lib/ssh.sh` so every script gets the helpers for free
- Migrated 13 commands and 11 lib files: every ssh/scp/rsync call now includes `-o IdentitiesOnly=yes` plus a per-site `-i <key>` resolved from `nwp.yml`
- Server-provisioning scripts (`produce.sh`) add `-o IdentitiesOnly=yes` directly since they have no site context yet

**Success Criteria:**
- [x] No `ssh`/`scp`/`rsync` call in `lib/` or `scripts/commands/` runs without `-o IdentitiesOnly=yes`
- [x] `nwp_ssh_opts` and friends available in every script that sources `lib/common.sh`
- [x] All 27 modified files pass `bash -n`
- [x] Generated scripts (e.g. `lib/podcast.sh` deploy template) emit hardened ssh/scp
- [ ] Documentation updated to show the safe form (tracked alongside this proposal)

---

#### P57: Production Caching & Performance
**Status:** ✅ COMPLETE | **Priority:** MEDIUM | **Effort:** 1-2 weeks | **Dependencies:** P54
**Proposal:** [P57-produce-performance.md](../proposals/P57-produce-performance.md)

Add caching and performance optimization to `produce.sh`. Currently no caching features exist despite verification tests expecting them.

**Features:**
- Redis caching with Drupal integration (default cache backend)
- Memcached as alternative for memory-constrained servers
- PHP-FPM tuning based on server memory (dynamic `max_children` calculation)
- Nginx optimization (gzip, open file cache, static asset caching)

**CLI options:** `--cache redis|memcache|none`, `--memory SIZE`, `--performance-only`

**Expected impact:** 50%+ page load reduction, 90%+ cache hit rate.

**Success Criteria:**
- [ ] Redis/Memcache integration in `produce.sh`
- [ ] PHP-FPM tuned based on server memory
- [ ] Nginx gzip and caching enabled
- [ ] All features optional via CLI flags

---

### Phase 9c: Advanced Verification & Rename

#### P55: Opportunistic Human Verification
**Status:** ✅ COMPLETE | **Priority:** LOW | **Effort:** 4-5 weeks | **Dependencies:** P50
**Proposal:** [P55-opportunistic-human-verification.md](../proposals/P55-opportunistic-human-verification.md)

Opt-in system where designated testers receive interactive prompts after running commands, capturing real-world verification without dedicated test sessions. Includes bug report system with automatic diagnostics, GitLab issue submission, and a `pl fix` TUI for AI-assisted issue resolution.

**Key components:**
- Tester role system (opt-in via `pl coders tester --enable`)
- Post-command verification prompts with full how-to-verify details
- Bug report creation with automatic diagnostics collection
- `pl fix` TUI for Claude-assisted issue resolution
- Integration with `pl todo` (bugs category)
- Issue lifecycle: open → investigating → fixed → verified

**Why later:** Large scope (4-5 weeks), requires stable verification system (P54 first), opt-in feature that doesn't block other work.

**Success Criteria:**
- [ ] Tester role with opt-in prompts
- [ ] Bug reports with automatic diagnostics
- [ ] `pl fix` TUI for issue resolution
- [ ] Integration with `pl todo`

---

#### P52: Rename NWP to NWO
**Status:** ❌ REJECTED | **Decision Date:** February 1, 2026

This proposal is permanently rejected. The project is and will remain **NWP — Narrow Way Project**. This name reflects the project's ethos and is the permanent identity. No rename will be considered.

---

## Phase 13: Distributed Build/Deploy Pipeline (PROPOSED)

### F21: Distributed Build/Deploy Pipeline (mmt build, mons deploy)
**Status:** PROPOSED | **Priority:** HIGH | **Effort:** Multi-week (~13 phases) | **Dependencies:** F17 (Project Separation), F18 (Unified Backup)
**Proposal:** [F21-distributed-build-deploy-pipeline.md](../proposals/F21-distributed-build-deploy-pipeline.md)
**Architecture decision record:** [ADR-0017](../decisions/0017-distributed-build-deploy-pipeline.md)

Move from a single-machine, AI-co-located build/deploy model to a distributed
pipeline that:

- Runs build/test/lint on home hardware (`met` + `mini` = `mmt`)
- Air-gaps a separate AI-free deploy machine (`mons`) with hardware-token
  prod SSH keys (Solo 2C+)
- Migrates `git.nwpcode.org` from Newark to `au-mel` for sub-10 ms RTT
- Hosts production sites in `us-iad`
- Replaces in-place prod overwrites with blue-green slot swaps and
  forward-compat migrations
- Sanitizes production data on prod and publishes the snapshots as the
  CI test substrate (clean PII boundary, makes site source open-sourceable)

**Why now:** AI is now a meaningful share of NWP's code authoring. The
single-tier model where AI agents and prod credentials share a trust domain
is the dominant risk in the current threat model.

**Phases:** See F21 § 4 for the full 13-phase breakdown. Phases 1–4 are
reversible and can start without hardware tokens; phase 5 requires Solo
2C+ tokens (long lead time, order in phase 1); phase 9 is the
end-to-end "moment of truth"; phases 11–13 are stabilization, per-site
rollout, and tabletop drills.

---

## Phase X: Experimental & Outlier Features

> **Note:** These proposals explore capabilities outside NWP's core mission of Drupal hosting/deployment. They are marked as "outliers" because they represent significant scope expansion. Implementation would only occur if there's strong user demand and clear use cases.

### X01: AI Video Generation Integration
**Status:** POSSIBLE (deprioritized by Deep Analysis re-evaluation) | **Priority:** LOW | **Effort:** High | **Dependencies:** [Local LLM guide](../guides/local-llm.md) (optional)
**Type:** OUTLIER - Significant scope expansion beyond core NWP mission

Integrate AI video generation capabilities into NWP for automated content creation on Drupal sites:

**⚠️ Why This is an Outlier:**
- NWP's core mission: Drupal deployment, hosting, site management
- Video generation: Content creation, not infrastructure
- Significant complexity and resource requirements
- May be better served by dedicated tools/services
- Would require ongoing maintenance of video generation stack

**Potential Use Cases:**

| Use Case | Tool Integration | Benefit |
|----------|------------------|---------|
| Blog → Video | Pictory API | Auto-convert posts to video |
| Tutorial Videos | Synthesia API | Create training content |
| Social Media | Opus Clip API | Auto-generate shorts |
| Product Demos | Runway API | Showcase Drupal modules |
| AI Avatars | HeyGen API | Video testimonials |

**Why Consider This (Despite Being an Outlier)?**

**1. Content Velocity**
- Drupal sites need regular content
- Video content drives engagement
- Manual video creation is expensive/time-consuming

**2. Integration with Existing Content**
- Drupal already manages blog posts, products, documentation
- Auto-generate video versions of existing content
- Multi-channel content distribution

**3. Marketing for NWP Sites**
- Help NWP users create marketing videos
- Reduce barrier to video content
- Competitive advantage for NWP-hosted sites

**Two Possible Approaches:**

#### Approach A: API Integration (Recommended if pursued)

**Simpler, more practical:**

```bash
# Add video generation as a service integration
pl video setup                      # Configure API keys
pl video blog-to-video <post-id>    # Convert Drupal post to video
pl video avatar-record "script"     # Generate AI avatar video
pl video status                     # Check generation jobs
```

**Architecture:**
```
Drupal Post (API)
    ↓
NWP extraction
    ↓
Third-party API (Pictory, Synthesia, etc.)
    ↓
Video file
    ↓
Upload to Drupal Media Library
```

**Services to integrate:**
- **Pictory** - Blog to video ($23-119/mo)
- **Synthesia** - AI avatars ($22-67/mo)
- **Runway** - Creative video ($12-76/mo)
- **HeyGen** - Presenter videos ($24-120/mo)

**Pros:**
- No GPU hardware required
- Professional quality output
- Maintained by specialized companies
- Faster implementation

**Cons:**
- Recurring costs per user
- Data sent to third parties
- API rate limits
- Vendor lock-in

#### Approach B: Self-Hosted (Not Recommended)

**Complex, expensive, ongoing maintenance:**

```bash
# Setup local video generation infrastructure
pl video-server setup               # Install GPU drivers, models
pl video-server models list         # Show available models
pl video-server generate-from-text  # Generate video locally
```

**Requirements:**
- Dedicated GPU server (RTX 4090, $2000-3000)
- 64GB+ RAM
- Stable Video Diffusion, AnimateDiff
- Ongoing model updates and maintenance
- Significant storage (video files)

**Pros:**
- No recurring API costs
- Complete privacy
- Full control over generation

**Cons:**
- High upfront hardware cost ($3000-5000)
- Ongoing maintenance burden
- Lower quality than commercial APIs
- GPU obsolescence (2-3 year cycle)
- Electricity costs
- Complex troubleshooting

**Implementation Plan (If Approach A Pursued):**

**Phase 1: Foundation (2 weeks)**
- [ ] Research API options (Pictory, Synthesia, Runway)
- [ ] Create `lib/video-generation.sh` library
- [ ] Add video API config to nwp.yml
- [ ] Basic API integration for one service

**Phase 2: Drupal Integration (2 weeks)**
- [ ] Content extraction from Drupal API
- [ ] Template system for video generation
- [ ] Upload generated videos to Drupal Media
- [ ] Drush command: `drush nwp:video:generate <nid>`

**Phase 3: CLI Commands (1 week)**
- [ ] `pl video setup` - Configure API credentials
- [ ] `pl video blog-to-video` - Blog post conversion
- [ ] `pl video status` - Check generation jobs
- [ ] `pl video list` - Show generated videos

**Phase 4: Automation (1 week)**
- [ ] Scheduled generation (new posts)
- [ ] Batch processing
- [ ] Queue management
- [ ] Error handling and retry logic

**Configuration in nwp.yml:**

```yaml
video_generation:
  enabled: false  # Opt-in feature

  provider: pictory  # pictory, synthesia, runway, heygen

  # API credentials (stored in .secrets.yml)
  api_key_env: VIDEO_GENERATION_API_KEY

  # Generation settings
  auto_generate: false  # Auto-generate on new post publish
  video_format: mp4
  resolution: 1080p

  # Pictory-specific settings
  pictory:
    voice: "professional_male"
    music: true
    style: "modern"

  # Synthesia-specific settings
  synthesia:
    avatar: "anna_professional"
    background: "office"

  # Upload settings
  drupal_media_type: video
  storage_location: "sites/default/files/videos"
```

**File Structure:**

```
lib/video-generation.sh           # Video generation library
lib/video-providers/
  ├── pictory.sh                  # Pictory API integration
  ├── synthesia.sh                # Synthesia API integration
  └── runway.sh                   # Runway API integration
scripts/commands/video.sh         # CLI commands
docs/VIDEO_GENERATION_GUIDE.md    # Complete guide
templates/video-config.yml        # Config template
tests/unit/test-video.bats        # Unit tests
```

**Cost Analysis (Monthly per site):**

| Service | Price | Videos/Month | Cost per Video |
|---------|-------|--------------|----------------|
| Pictory | $23-119 | 10-120 | $2-12 |
| Synthesia | $22-67 | 10-360 | $0.20-7 |
| Runway | $12-76 | Varies | $1-5 |
| HeyGen | $24-120 | 20-unlimited | $1-6 |

**Self-hosted comparison:**
- Initial: $3000-5000 (hardware)
- Running: $50-100/mo (electricity)
- ROI: 2-3 years vs API costs
- Maintenance: Significant ongoing effort

**Example Workflows:**

```bash
# 1. Convert blog post to video
pl video blog-to-video --post 123 --provider pictory --voice professional_male

# 2. Create AI avatar announcement
pl video avatar --script "Welcome to our new website" --avatar anna --provider synthesia

# 3. Generate social media shorts
pl video social --source video123.mp4 --platform tiktok --duration 60s

# 4. Batch process recent posts
pl video batch --recent 10 --provider pictory

# 5. Check generation status
pl video status
# Output:
# Job ID  | Type      | Status      | Started    | Progress
# v-1234  | blog      | processing  | 5 min ago  | 45%
# v-1235  | avatar    | complete    | 10 min ago | 100%
# v-1236  | social    | queued      | -          | 0%
```

**Drupal Module Integration:**

Optional companion Drupal module for UI-based generation:

```php
// Admin UI: node/123/generate-video
// Drush: drush nwp:video:generate 123
// Cron: Auto-generate on publish (if enabled)
```

**Success Criteria:**

- [ ] API integration with at least one provider (Pictory or Synthesia)
- [ ] `lib/video-generation.sh` library
- [ ] `pl video setup` command
- [ ] `pl video blog-to-video` working end-to-end
- [ ] Generated videos uploaded to Drupal Media
- [ ] Configuration in nwp.yml
- [ ] API keys stored in .secrets.yml
- [ ] Error handling and retry logic
- [ ] Documentation with cost analysis
- [ ] Example workflows documented
- [ ] Drush command for Drupal integration

**Why This Might NOT Be Worth It:**

**1. Scope Creep**
- NWP is about infrastructure, not content creation
- Video generation is a separate domain
- Better to integrate existing tools via Drupal modules

**2. Maintenance Burden**
- APIs change frequently
- Multiple providers to maintain
- Video generation is complex and error-prone

**3. Cost vs Benefit**
- Users can use these services directly
- May not justify development/maintenance effort
- Drupal already has video modules

**4. Alternative Approach**
- Document how to use video generation services
- Provide Drupal module recommendations
- Focus NWP on infrastructure strengths

**Decision Framework:**

Should X01 be implemented? Only if:
- [ ] 5+ users explicitly request this feature
- [ ] Clear ROI demonstrated (time/cost savings)
- [ ] Dedicated maintainer willing to own this
- [ ] Doesn't distract from core NWP mission
- [ ] Can be cleanly separated (optional module)

**Recommended Path Forward:**

**Instead of building this into NWP:**
1. Create guide: "Integrating Video Generation with NWP Drupal Sites"
2. Document available Drupal modules for video
3. Provide API integration examples
4. Let users choose their own video generation tools
5. Revisit if demand emerges

**If building anyway, choose Approach A (API Integration)** with Pictory as first provider.

---

### X02: Local Voice Agent on mini (Twilio + Pipecat + local LLM)
**Status:** PROPOSED | **Priority:** LOW | **Effort:** ~4 phases | **Dependencies:** [Local LLM guide](../guides/local-llm.md), F21 Phase 3a (mini as local-LLM agent), F21 Phase 1 (Headscale — soft)
**Proposal:** [X02-local-voice-agent-on-mini.md](../proposals/X02-local-voice-agent-on-mini.md)
**Architecture decision record:** [ADR-0018: Twilio as bounded SaaS dependency](../decisions/0018-twilio-bounded-saas-for-pstn.md)
**Type:** OUTLIER — voice telephony is scope expansion beyond NWP's core Drupal mission

Run an AI voice agent on **mini** (Beelink Ryzen AI Max+ 395) that answers
phone calls on a Twilio US 10DLC number using a fully local stack: Pipecat
orchestration + faster-whisper STT + Llama 3.1 8B (or Qwen 2.5 7B) on
Ollama + Piper/Kokoro TTS. Zero cloud AI inference.

**⚠️ Why This is an Outlier:**
- NWP's core mission: Drupal deployment, hosting, site management
- Voice telephony: communication channel, not infrastructure
- Introduces NWP's first bounded third-party SaaS dependency (Twilio); see ADR-0018 for the trust-boundary decision
- Must coexist with mini's primary tenant (the coding agent) without evicting it

**Coexistence strategy:** Ollama `keep_alive=24h` on the coding model
(resident), `keep_alive=5m` on the voice model (loads on call, unloads
after). STT and TTS run on CPU so the iGPU is only contended for LLM work.
Phase 0 preflight validates memory headroom before anything else is built.

**Threat model alignment:**
- mini has no prod access; voice agent tool allowlist starts empty and
  nothing prod-adjacent is ever added
- Twilio sees audio only; all STT/LLM/TTS/state local on mini
- No inbound port on the home router — Twilio reaches mini via a
  Headscale-routed ingress on the `au-mel` Linode
- Call logs, transcripts, and conversation state stay in local SQLite
- Pipecat's transport abstraction means swapping Twilio for Telnyx /
  Bandwidth / SignalWire / self-hosted Asterisk is a single-file change,
  verified by the Phase 3 runbook

**Phases** (see proposal for detail):

1. **Phase 0** — Preflight: verify mini can run 8B at voice-grade latency
   alongside the coding agent
2. **Phase 1** — Twilio paid account + US 10DLC number + TwiML hello-world
   (no A2P 10DLC dependency)
3. **Phase 2** — Pipecat pipeline: `TwilioFrameSerializer` + Whisper +
   Ollama + Piper + systemd
4. **Phase 3** — Polish, coexistence load test, observability, provider-swap runbook
5. **Phase 4** *(parallel, slow track)* — SMS via A2P 10DLC registration
   (TCR 10–15 day review; gated on business registration details and an
   updated privacy policy that explicitly mentions SMS; voice is unaffected)

**Self-contained:** Everything lives under `servers/mini/voice-agent/`.
No changes to `lib/`, `scripts/commands/`, `pl`, or `recipes/`. Deletes
cleanly if the experiment fails.

**Success Criteria:** see proposal § 7. Headline: local LLM answers calls
with < 1.5 s p50 latency, coding agent tokens/sec degrades < 10 %, no
inbound port on the home router, 7 days operation with ≥ 10 test calls
and no incident.

---

## Deep Analysis Re-Evaluation (January 2026)

**Full Report:** [NWP_DEEP_ANALYSIS_REEVALUATION.md](../reports/NWP_DEEP_ANALYSIS_REEVALUATION.md)

A comprehensive re-evaluation of all recommendations from the NWP Deep Analysis, applying YAGNI principle and 1-2 developer reality. Out of 33 major recommendations:

- **11 (33%) - DO IT**: Real problems with clear ROI
- **13 (39%) - DON'T**: Over-engineering or YAGNI violations
- **9 (27%) - MAYBE**: Context-dependent, nice-to-have

**Time Saved:** 400-650 hours of over-engineering avoided

---

### Priority 1: Critical (20 hours, DO IT)

| Item | Effort | Status | Rationale |
|------|--------|--------|-----------|
| **YAML Parsing Consolidation** | 6h | PLANNED | Real duplication across 5+ files, causes maintenance burden |
| **Documentation Organization** | 3h | PLANNED | 14 orphaned docs, 140 [PLANNED] options confusing users |
| **pl doctor Command** | 10h | PLANNED | High troubleshooting value, catches common issues early |

**Total: ~20 hours, high impact**

---

### Priority 2: Important (12 hours, DO IT)

| Item | Effort | Status | Rationale |
|------|--------|--------|-----------|
| **Progress Indicators** | 10h | PLANNED | Users think commands hang, real UX problem |
| **NO_COLOR Support** | 1h | PLANNED | Standard convention, easy win |
| **SSH Host Key Documentation** | 0.5h | PLANNED | Document security trade-offs |

**Total: ~12 hours, good value**

---

### Priority 3: Optional (33 hours, MAYBE)

| Item | Effort | Condition |
|------|--------|-----------|
| **Better Error Messages** | 3h | Fix top 5 incrementally |
| **E2E Smoke Tests** | 10h | One test only, not comprehensive suite |
| **Visual Regression Testing** | 20h | Only if active theme development |
| **CI Integration Tests** | 2h | Add DDEV to CI infrastructure |
| **Command Reference Matrix** | 1h | Add "Common Workflows" section only |
| **Group Setup Components** | 2h | If onboarding many users regularly |
| **--dry-run Flag** | 10h | If preview capability valuable |
| **Audit Outdated Docs** | Ongoing | Fix incrementally as noticed |
| **SSH Host Key Verification** | 3h | If security > convenience |

**Total: ~33 hours if all done, pick and choose based on need**

---

### Confirmed NOT Worth It (400+ hours saved)

These items were thoroughly evaluated and rejected as over-engineering for NWP's scale:

#### Architecture Over-Engineering (100+ hours)

| Item | Why Not | Hours Saved |
|------|---------|-------------|
| **API Abstraction Layer** | APIs break 1-2x/year, fix in 5 min. No ROI for 40+ hour investment. | 40+ |
| **Break Apart God Objects** | No bugs from status.sh or coders.sh. Working code isn't debt. | 32-48 |
| **Monolithic Function Refactoring** | install_drupal() works fine. No tests needed if not breaking. | 16-24 |
| **Break Circular Dependencies** | No evidence of problems. Academic exercise. | 8-16 |

#### Testing Over-Engineering (150+ hours)

| Item | Why Not | Hours Saved |
|------|---------|-------------|
| **80% Test Coverage Target** | Vanity metric. Current 15-20% catches bugs fine. | 80-160 |
| **TUI Testing Framework** | Complex, fragile, not worth maintenance burden. | 20-30 |
| **Comprehensive E2E Suite** | Manual testing works. One smoke test sufficient. | 50-80 |

#### Feature Over-Engineering (150+ hours)

| Item | Proposal | Why Not | Hours Saved |
|------|----------|---------|-------------|
| **GitLab MCP Integration** | F01 | Saves 5 seconds per CI failure. Not worth 16 hours. | 16 |
| **Auto-Fix CI Errors** | F02 | Way over-engineered. Developers can fix their own errors. | 40-80 |
| **Badge System** | F08 | Private tool with no audience. Who's seeing these badges? | 20-40 |
| **Video Generation** | X01 | Massive scope creep. Not infrastructure tool's job. | 40-80 |
| **Malicious Code Detection** | F06 | No external contributors. Solving non-existent problem. | 20-40 |

> **Note:** These proposals are now categorized as [Possible (Not Prioritized)](#possible-not-prioritized) rather than active.

#### UX Over-Engineering (30+ hours)

| Item | Why Not | Hours Saved |
|------|---------|-------------|
| **Group Confirmation Prompts** | Users can press Enter. Not a real problem. | 3-6 |
| **--json Output** | No API consumers. Building for hypothetical users. | 8-12 |
| **Command Suggestions on Typo** | Nice-to-have but low ROI. | 4-8 |
| **Summary After Operations** | Already have output. More polish than value. | 6-10 |

#### Rewrite Fantasies (200+ hours)

| Item | Why Not | Hours Saved |
|------|---------|-------------|
| **Rewrite Bash to Go/Python** | 48K lines work fine. Rewrite would introduce bugs. | 200+ |
| **Plugin System for Recipes** | No external recipe developers. YAGNI. | 40+ |

---

### Reality Check Principles Applied

1. **YAGNI (You Aren't Gonna Need It)**
   - Don't build for hypothetical problems
   - API abstraction for APIs that rarely break
   - Malicious code detection with no contributors

2. **80/20 Rule**
   - 20% of effort provides 80% of value
   - Focus on real user pain: progress, docs, troubleshooting
   - Skip academic exercises: god objects, circular deps

3. **Real vs Hypothetical Problems**
   - **Real:** Users think commands hang (no progress)
   - **Hypothetical:** God objects might cause bugs someday
   - **Real:** Docs hard to find (14 orphaned)
   - **Hypothetical:** APIs might break frequently (they don't)

4. **Scale-Appropriate Solutions**
   - 1-2 developers don't need enterprise testing frameworks
   - Fix bugs as they occur, don't chase coverage percentages
   - Human processes over automation where appropriate

---

### Time Investment Comparison

**If following original deep analysis:** 500-800 hours (3-5 months full-time)

**If following re-evaluation:**
- Priority 1 (Critical): 20 hours
- Priority 2 (Important): 12 hours
- Priority 3 (Optional): 0-33 hours (pick and choose)
- **Total: 32-65 hours (1-2 weeks)**

**Time saved by not over-engineering:** 435-768 hours (2-4.5 months)

**Better use of saved time:**
- Build features users actually want
- Improve existing functionality
- Document what exists
- Or take a well-deserved vacation

---

### Implementation Approach

#### This Month (Priority 1 - 20 hours)

1. **Consolidate YAML parsing** (6h)
   ```bash
   # Create lib/yaml-helpers.sh
   # Migrate 5+ duplicate parsers
   # Add yq support with awk fallback
   ```

2. **Organize documentation** (3h)
   ```bash
   # Index 14 orphaned docs
   # Link governance docs from main README
   # Clean up [PLANNED] markers in nwp.yml
   ```

3. **Add pl doctor command** (10h)
   ```bash
   # Check prerequisites (DDEV, Docker, PHP, Composer)
   # Verify configuration (nwp.yml, .secrets.yml)
   # Diagnose common issues (ports, permissions, DNS)
   # Show actionable fix suggestions
   ```

#### Next Month (Priority 2 - 12 hours)

4. **Add progress indicators** (10h)
   - Spinners for short operations
   - Step progress for workflows
   - Periodic status updates for long ops

5. **NO_COLOR support** (1h)
   - Check NO_COLOR env var in lib/ui.sh
   - Disable colors if set

6. **Document SSH host key behavior** (0.5h)
   - Explain accept-new trade-offs
   - Document strict mode option

#### Later (Priority 3 - Pick and choose)

Only implement if you have spare time and the specific need arises:

- Better error messages (fix top 5 most common)
- One E2E smoke test (not comprehensive suite)
- Visual regression testing (only if theme work)
- CI integration tests (if CI infrastructure allows)

---

### Never Do List (Confirmed)

Do not attempt these items - they were thoroughly evaluated and rejected:

❌ **Architecture:**
- API abstraction layers
- Break apart god objects
- Refactor monolithic functions
- Break circular dependencies

❌ **Testing:**
- Chase 80% test coverage
- TUI testing framework
- Comprehensive E2E suites

❌ **UX:**
- Group confirmation prompts
- --json output
- Command suggestions
- Comprehensive summaries

❌ **Rewrites:**
- Rewrite bash to Go/Python
- Plugin system for recipes

**Reasoning:** These items solve hypothetical problems, not real ones. They're over-engineered for a 1-2 developer project. Time is better spent on features users actually want.

### Possible (Not Prioritized)

These feature proposals were deprioritized by the Deep Analysis re-evaluation. They remain documented but are not recommended unless circumstances change (e.g., external contributors join, scaling demands emerge):

| Proposal | Name | Condition to Reconsider |
|----------|------|------------------------|
| F01 | GitLab MCP Integration | If CI failure debugging becomes a major time sink |
| F02 | Automated CI Error Resolution | If F01 is implemented and CI errors are frequent |
| F06 | Malicious Code Detection Pipeline | If external contributors start submitting code |
| F08 | Dynamic Cross-Platform Badges | If NWP becomes a public/community tool |
| X01 | AI Video Generation | If 5+ users explicitly request it |

---

## Priority Matrix

| Order | Proposal | Priority | Effort | Dependencies | Phase | Status |
|-------|----------|----------|--------|--------------|-------|--------|
| | **Completed** | | | | | |
| 1 | F05 | HIGH | Low | stg2live | 6 | ✅ Complete |
| 2 | F04 | HIGH | High | GitLab | 6 | ✅ Complete |
| 3 | F09 | HIGH | High | Linode, GitLab CI | 7 | ✅ Complete |
| 4 | F07 | HIGH | Medium | stg2live, recipes | 6 | ✅ Complete |
| 5 | F12 | MEDIUM | Medium | None | 6 | ✅ Complete |
| 6 | P50 | HIGH | High | None | 8 | ✅ Complete |
| 7 | P51 | HIGH | High | P50 | 8 | ✅ Complete |
| | **Phase 9a: Verification Fixes** | | | | | |
| 8 | P54 | HIGH | Low (2-3d) | P50 | 9 | ✅ Complete |
| 9 | P53 | MEDIUM | Low (2-3d) | P50 | 9 | ✅ Complete |
| 10 | P58 | MEDIUM | Low (3-5d) | P54 | 9 | ✅ Complete |
| | **Phase 9b: Production Hardening** | | | | | |
| 11 | P56 | MEDIUM | Medium (1-2w) | P54 | 9 | ✅ Complete |
| 12 | P57 | MEDIUM | Medium (1-2w) | P54 | 9 | ✅ Complete |
| | **Phase 10: Developer Experience** | | | | | |
| 13 | F13 | MEDIUM | Low | None | 10 | ✅ Complete |
| 14 | F15 | MEDIUM | Low (~10h) | None | 10 | ✅ Complete |
| — | F10, F11 | — | — | — | — | → Promoted to [local-llm guide](../guides/local-llm.md) + F21 Phase 3a (2026-04-08) |
| 17 | F14 | MEDIUM | Medium | None | 10 | ✅ Complete |
| | **Later / Conditional** | | | | | |
| 18 | P55 | LOW | High (4-5w) | P50 | 9 | ✅ Complete |
| - | P52 | - | - | - | - | ❌ Rejected |
| 20 | F03 | LOW | Medium | Behat | 7b | ✅ Complete |
| | **Possible (deprioritized)** | | | | | |
| - | F01 | LOW | Low | GitLab | 7b | Possible |
| - | F02 | LOW | Medium | F01 | 7b | Possible |
| - | F06 | LOW | Medium | F04, GitLab CI | 6b | Possible |
| - | F08 | LOW | Medium | verify.sh, GitLab | 7b | Possible |
| - | X01 | LOW | High | Local LLM guide (optional) | X | Possible |

---

## Site-specific Roadmaps

NWP intentionally does not carry site-specific roadmap content. Each site
manages its own work in its own project directory.

| Site | Where its proposals live | Notes |
|---|---|---|
| AVC | [`sites/avc/docs/proposals/`](../../sites/avc/docs/proposals/) | A01 (Guild multi-verification), A02 (Workflow system), A03 (OAuth2/Guild sync — extracted from F23 phase 9) |
| Sacred Sources (ss) | [`sites/ss/docs/proposals/`](../../sites/ss/docs/proposals/) | S01 (Faith Formation app, in progress) |
| Mass Times (mt) | [`sites/mt/docs/proposals/`](../../sites/mt/docs/proposals/) | M01 (Scraper & Display, implemented), M02 (Site creation, deployed) |
| CathNet | [`sites/cathnet/docs/proposals/`](../../sites/cathnet/docs/proposals/) | C01 (ACMC), C02 (NLP QA), C02a (Synthesis amendment), C03 (Neo4j KG) |
| Directory Search (dir1) | [`sites/dir1/docs/proposals/`](../../sites/dir1/docs/proposals/) | None yet |

Run `pl proposals` to aggregate NWP and every site's proposals into one
list, filtered by status or by site.

---

## References

### Core Documentation
- [Milestones](../reports/milestones.md) - Completed implementation history
- [Scripts Implementation](../reference/scripts-implementation.md) - Script architecture
- [CI/CD](../deployment/cicd.md) - CI/CD pipeline setup
- [Testing](../testing/testing.md) - Testing framework

### Governance (F04)
- [Distributed Contribution Governance](distributed-contribution-governance.md) - Governance proposal
- [Core Developer Onboarding](core-developer-onboarding.md) - Developer onboarding
- [Coder Onboarding](../guides/coder-onboarding.md) - New coder guide
- [Roles](roles.md) - Developer role definitions
- [Architecture Decisions](../decisions/) - Architecture Decision Records

### Security (F05, F06)
- [Data Security Best Practices](../security/data-security-best-practices.md) - Security architecture
- [Working with Claude Securely](../guides/working-with-claude-securely.md) - Secure AI workflows

### Proposals - Phase 9 (Verification & Production)
- [P52-rename-nwp-to-nwo.md](../proposals/P52-rename-nwp-to-nwo.md) - ~~Rename project~~ REJECTED (P52)
- [P53-verification-badge-accuracy.md](../proposals/P53-verification-badge-accuracy.md) - Badge accuracy & categorization (P53)
- [P54-verification-test-fixes.md](../proposals/P54-verification-test-fixes.md) - Verification test fixes (P54)
- [P55-opportunistic-human-verification.md](../proposals/P55-opportunistic-human-verification.md) - Opportunistic human verification (P55)
- [P56-produce-security-hardening.md](../proposals/P56-produce-security-hardening.md) - Production security hardening (P56)
- [P57-produce-performance.md](../proposals/P57-produce-performance.md) - Production caching & performance (P57)
- [P58-test-dependency-handling.md](../proposals/P58-test-dependency-handling.md) - Test dependency handling (P58)

### Proposals - Features
- [F07-seo-robots.md](../proposals/F07-seo-robots.md) - SEO & search engine control (F07)
- [F08-dynamic-badges.md](../proposals/F08-dynamic-badges.md) - Cross-platform badges (F08)
- [F09-comprehensive-testing.md](../proposals/F09-comprehensive-testing.md) - Testing infrastructure (F09)
- [F13-timezone-configuration.md](../proposals/F13-timezone-configuration.md) - Timezone configuration (F13)
- [F14-claude-api-integration.md](../proposals/F14-claude-api-integration.md) - Claude API integration (F14)
- [F15-ssh-user-management.md](../proposals/F15-ssh-user-management.md) - SSH user management (F15)

### Guides
- [Local LLM Guide](../guides/local-llm.md) - Running open source AI models locally (promoted from F10 on 2026-04-08)
- [Moodle Microsoft SSO](../guides/moodle-microsoft-sso.md) - Creating a Moodle site with Microsoft SSO using NWP

---

*Document restructured: January 5, 2026*
*Phase 5c (P32-P35) completed: January 5, 2026*
*Phase 6-7 reorganized: January 9, 2026*
*Proposals reordered by implementation priority: January 9, 2026*
*F09 (Testing) moved to position 3: January 9, 2026*
*F05, F04, F07, F09 completed: January 9, 2026*
*F10 (Local LLM Support) added: January 10, 2026*
*X01 (AI Video Generation) added as experimental outlier: January 10, 2026*
*Phase X (Experimental/Outliers) created: January 10, 2026*
*F11 (Developer Workstation Local LLM Config) added: January 11, 2026*
*F10 promoted to guide (`docs/guides/local-llm.md`) and F11 subsumed: 2026-04-08 — the provisioning work they described is now tracked under F21 Phase 3a*
*F12 (Unified Todo Command) completed: January 17, 2026*
*F15 (SSH User Management) added: January 24, 2026*
*F14 (Claude API Integration) added: February 1, 2026*
*Phase 9 (P52-P58 Verification & Production Hardening) added: February 1, 2026*
*F12 renumber conflict resolved (F12=Todo, F15=SSH): February 1, 2026*
*F01, F02, F06, F08, X01 reclassified as POSSIBLE per Deep Analysis: February 1, 2026*
*Broken proposal links fixed, Phase numbering updated: February 1, 2026*
*F15 expanded to ~10h practical scope with developer key onboarding: February 1, 2026*
*P56 updated with SSH key management for coder onboarding (Section 7): February 1, 2026*
*X02 (Local Voice Agent on mini) added as experimental outlier; ADR-0018 added (Twilio as bounded SaaS): April 8, 2026*
