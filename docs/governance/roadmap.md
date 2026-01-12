# NWP Roadmap - Pending & Future Work

**Last Updated:** January 12, 2026

Pending implementation items and future improvements for NWP.

> **For completed work, see [Milestones](../reports/milestones.md)** (P01-P35)

---

## Current Status

| Metric | Value |
|--------|-------|
| Current Version | v0.20.0 |
| Test Success Rate | 98% |
| Completed Proposals | P01-P35, F04, F05, F07, F09 |
| Pending Proposals | F01-F03, F06, F08, F10, F11 |
| Experimental/Outlier | X01 |
| Recent Enhancements | Documentation restructure (v0.20.0), Verify TUI console (v0.18-v0.19) |

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
| **Phase 8** | **Developer Experience** | **F10, F11** | **Future** |
| **Phase X** | **Experimental/Outliers** | **X01** | **Exploratory** |

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
| 9 | F10 | PROPOSED | Independent, developer privacy/experience |
| 10 | F11 | PROPOSED | Depends on F10, hardware-specific config |
| 11 | F02 | PLANNED | Depends on F01, lowest priority |
| - | X01 | EXPLORATORY | Outlier - significant scope expansion |

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
- [x] SSH status column in pl coders (v0.19.0) - Shows if coder has SSH keys on GitLab
- [x] Onboarding status tracking (v0.19.0) - GL, GRP, SSH, NS, DNS, SRV, SITE columns
- [x] Role-based requirement checking - Core/Steward require full onboarding

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

## Phase 8: Developer Experience (FUTURE)

### F10: Local LLM Support & Privacy Options
**Status:** PROPOSED | **Priority:** MEDIUM | **Effort:** Medium | **Dependencies:** None
**Guide:** [LOCAL_LLM_GUIDE.md](LOCAL_LLM_GUIDE.md) - Complete guide to using open source AI models

Provide developers with privacy-focused alternatives to cloud-based AI by integrating local LLM support into NWP workflows:

**Why This Matters:**
- Privacy concerns with cloud-based AI processing codebase/secrets
- Data sovereignty requirements
- Offline development capability
- Cost optimization for high-volume usage
- Developer autonomy and choice

**Supported Local LLM Platforms:**

| Platform | Best For | Integration Level |
|----------|----------|-------------------|
| Ollama | General purpose, easiest setup | Primary target |
| LM Studio | GUI users, model exploration | Documentation |
| llama.cpp | Advanced users, custom builds | Documentation |
| text-generation-webui | Full-featured local UI | Documentation |

**Recommended Models for NWP Work:**

| Model | Size | Purpose | Hardware |
|-------|------|---------|----------|
| qwen2.5-coder | 7B-32B | Bash/PHP coding | 16-64GB RAM |
| deepseek-coder-v2 | 16B | Code generation | 32GB+ RAM |
| llama3.2 | 3B-70B | General tasks | 8-128GB RAM |
| codestral | 22B | Multi-language coding | 32GB+ RAM |

**Implementation Approach:**

```bash
# 1. Detection & Setup
pl llm setup                    # Interactive setup wizard
pl llm setup --provider ollama  # Auto-configure Ollama
pl llm doctor                   # Verify installation

# 2. Model Management
pl llm models list              # Show available/installed models
pl llm models install qwen2.5-coder:7b
pl llm models benchmark         # Test performance on sample tasks

# 3. Integration with Existing Tools
pl llm chat                     # Interactive chat (like Claude)
pl llm code-review issue-123    # Review code using local LLM
pl llm ask "How do I fix this bash error?"

# 4. AI Provider Selection
pl config set ai.provider local     # Switch to local LLM
pl config set ai.provider anthropic # Switch back to Claude
pl config get ai.provider            # Show current provider
```

**Configuration in cnwp.yml:**

```yaml
ai:
  # Provider: anthropic (Claude API), local (Ollama/local), none (disabled)
  provider: anthropic

  # Claude API settings (when provider=anthropic)
  anthropic:
    api_key_env: ANTHROPIC_API_KEY
    model: claude-sonnet-4-5

  # Local LLM settings (when provider=local)
  local:
    backend: ollama                    # ollama, lm-studio, llama-cpp
    endpoint: http://localhost:11434   # API endpoint
    model: qwen2.5-coder:7b            # Default model
    timeout: 120                       # Seconds

  # Feature flags
  features:
    code_review: true        # AI-assisted code review
    commit_messages: true    # AI-generated commit messages
    error_analysis: true     # Analyze CI/test errors
    documentation: false     # AI-generated docs (opt-in)
```

**Integration Points:**

| Feature | Current | With Local LLM |
|---------|---------|----------------|
| Code review | Manual | `pl llm review <file>` |
| Commit messages | Manual | `pl commit --ai-message` |
| Error debugging | Manual log reading | `pl llm explain <error-log>` |
| Documentation | Manual writing | `pl llm doc <function>` |
| Test generation | Manual writing | `pl llm test <file>` |

**Privacy Architecture:**

```
┌─────────────────────────────────────┐
│ Developer Choice (cnwp.yml)         │
├─────────────────────────────────────┤
│                                     │
│  [Anthropic Cloud]  [Local LLM]    │
│        ↓                ↓           │
│   Claude API        Ollama         │
│   (paid, powerful)  (free, private)│
│   Data sent out     Data stays     │
│                                     │
└─────────────────────────────────────┘

Protected Files (never sent to AI):
- .secrets.data.yml (always blocked)
- keys/prod_* (always blocked)
- *.sql, *.sql.gz (always blocked)
- User can add to .aiignore
```

**Implementation Phases:**

1. **Foundation** (Week 1)
   - Add `lib/llm.sh` library
   - Ollama detection and validation
   - Configuration schema in cnwp.yml

2. **Core Commands** (Week 2)
   - `pl llm setup` - Guided installation
   - `pl llm chat` - Interactive chat interface
   - `pl llm ask` - One-shot questions
   - Provider switching logic

3. **Tool Integration** (Week 3)
   - Code review integration
   - Commit message generation
   - Error log analysis
   - `.aiignore` file support

4. **Documentation** (Week 4)
   - Installation guides for Ollama/LM Studio
   - Model selection guide
   - Privacy comparison chart
   - Troubleshooting guide

**File Structure:**

```
lib/llm.sh                     # LLM integration library
scripts/commands/llm.sh        # LLM management commands
docs/LOCAL_LLM_GUIDE.md        # Complete setup guide
templates/aiignore.txt         # Default .aiignore template
tests/unit/test-llm.bats       # Unit tests for LLM functions
```

**Hardware Requirements Guide:**

| Use Case | Recommended Model | RAM | GPU | Speed |
|----------|-------------------|-----|-----|-------|
| Quick scripts | qwen2.5-coder:3b | 8GB | No | Fast |
| General dev | qwen2.5-coder:7b | 16GB | Optional | Good |
| Complex code | qwen2.5-coder:32b | 64GB | Yes | Slow |
| Production | Claude API | N/A | N/A | Fast |

**Comparison Matrix:**

| Feature | Claude API | Local LLM |
|---------|------------|-----------|
| **Privacy** | Data sent to Anthropic | All local |
| **Cost** | $3-15 per million tokens | Free after setup |
| **Quality** | Excellent | Good to Very Good |
| **Speed** | Fast | Depends on hardware |
| **Offline** | No | Yes |
| **Setup** | API key only | Install + models |
| **Maintenance** | None | Update models |

**Success Criteria:**

- [ ] `lib/llm.sh` library with Ollama integration
- [ ] `pl llm setup` command with interactive wizard
- [ ] `pl llm chat` for interactive sessions
- [ ] `pl llm ask` for one-shot questions
- [ ] AI provider selection in cnwp.yml
- [ ] `.aiignore` file support (similar to .gitignore)
- [x] `docs/LOCAL_LLM_GUIDE.md` with setup instructions
- [ ] Model recommendation based on hardware detection
- [ ] Integration with existing `pl` commands (opt-in flags)
- [x] Privacy comparison documentation
- [ ] Benchmark command to test local model performance
- [ ] Graceful fallback when local LLM unavailable

**Security Considerations:**

- `.aiignore` file to exclude sensitive paths
- Same data protection rules as Claude integration
- No secrets sent to any AI (local or cloud)
- User consent required for any AI features
- Clear indication of which provider is active

**Documentation Deliverables:**

- Setup guide for Ollama (Linux, macOS, Windows)
- Model selection guide (speed vs quality tradeoffs)
- Privacy comparison (cloud vs local)
- Hardware requirements calculator
- Troubleshooting common issues
- Integration examples for common workflows

**Future Enhancements:**

- Model fine-tuning on NWP codebase
- Custom model training for site-specific patterns
- Multi-model support (use different models for different tasks)
- Model quantization recommendations
- Distributed inference (multiple machines)

---

### F11: Developer Workstation Local LLM Configuration
**Status:** PROPOSED | **Priority:** MEDIUM | **Effort:** Low | **Dependencies:** F10 (Local LLM Support)
**Hardware Target:** Ryzen 9 12-core, 32GB RAM, 1TB SSD, NVIDIA RTX 2060 (6GB VRAM)

Provide optimized local LLM configuration for mid-range developer workstations, enabling privacy-focused AI assistance without cloud dependencies.

**Hardware Analysis:**

| Component | Spec | LLM Impact |
|-----------|------|------------|
| CPU | Ryzen 9 12-core | Excellent for CPU inference, ~15-25 tokens/sec on 7B |
| RAM | 32GB | Comfortable for 7B-14B models with headroom |
| SSD | 1TB NVMe | Store 5-10 models simultaneously |
| GPU | RTX 2060 6GB | Partial offload (3-4 layers), ~20% speedup |

**Recommended Models (Optimized for 32GB RAM + RTX 2060):**

| Model | Size | RAM Used | GPU Layers | Speed | Best For |
|-------|------|----------|------------|-------|----------|
| **qwen2.5-coder:7b** | 4.7GB | ~10GB | 8-10 | Fast | Daily coding (PRIMARY) |
| **qwen2.5-coder:14b** | 9GB | ~18GB | 4-6 | Good | Complex refactoring |
| **deepseek-coder-v2:16b** | 10GB | ~20GB | 4-5 | Moderate | Multi-language |
| **llama3.2:8b** | 4.9GB | ~12GB | 8-10 | Fast | General Q&A |
| **phi3:3.8b** | 2.4GB | ~6GB | Full | Very Fast | Quick lookups |
| **mistral:7b** | 4.1GB | ~10GB | 8-10 | Fast | Fast general purpose |

**Optimal Configuration for RTX 2060:**

```bash
# Install Ollama
curl -fsSL https://ollama.com/install.sh | sh

# Pull recommended models for your hardware
ollama pull qwen2.5-coder:7b      # Primary coding model
ollama pull phi3:3.8b              # Fast lookups
ollama pull llama3.2:8b            # General tasks

# Configure GPU layers (RTX 2060 = 6GB VRAM)
# Create custom modelfile for optimal performance
cat > ~/.ollama/Modelfile-nwp <<'EOF'
FROM qwen2.5-coder:7b

# Optimize for RTX 2060 (6GB VRAM) + 32GB RAM
PARAMETER num_gpu 10
PARAMETER num_thread 12
PARAMETER num_ctx 4096

# NWP-focused system prompt
SYSTEM """
You are an expert in bash scripting, PHP, and Drupal development.
You work with the NWP (Node Web Platform) deployment framework.
Provide secure, well-tested code with clear explanations.
"""
EOF

ollama create nwp-coder -f ~/.ollama/Modelfile-nwp
```

**Performance Expectations:**

| Task | Model | Expected Speed | Quality |
|------|-------|----------------|---------|
| Quick script help | phi3:3.8b | 2-3 sec | Good |
| Code review | qwen2.5-coder:7b | 5-8 sec | Very Good |
| Complex refactor | qwen2.5-coder:14b | 15-25 sec | Excellent |
| General Q&A | llama3.2:8b | 4-6 sec | Very Good |

**GPU Acceleration Setup (RTX 2060):**

```bash
# Verify NVIDIA drivers
nvidia-smi

# Check CUDA support
nvidia-smi -L

# Ollama auto-detects GPU, but verify:
ollama run qwen2.5-coder:7b "test"
# Should show GPU utilization in nvidia-smi

# Monitor GPU during inference
watch -n 1 nvidia-smi
```

**Memory Management (32GB Optimization):**

```bash
# Keep ~8GB free for system/browser
# Recommended concurrent usage:
# - 1 large model (14B) + development tools
# - OR 2 medium models (7B each) for comparison
# - OR 1 medium (7B) + coding + browser

# Check memory before loading large model
free -h

# Unload unused models
ollama stop qwen2.5-coder:14b
```

**Storage Layout (1TB SSD):**

```
~/. ollama/models/           # ~50-80GB for models
├── qwen2.5-coder:7b        # 4.7GB
├── qwen2.5-coder:14b       # 9GB
├── deepseek-coder-v2:16b   # 10GB
├── llama3.2:8b             # 4.9GB
├── phi3:3.8b               # 2.4GB
└── mistral:7b              # 4.1GB
                            # Total: ~35GB
                            # Plenty of room for more
```

**NWP Integration Commands:**

```bash
# Quick coding help (uses phi3 for speed)
alias ai-quick='ollama run phi3:3.8b'

# Code review (uses qwen2.5-coder:7b)
alias ai-code='ollama run nwp-coder'

# Complex tasks (uses 14b when needed)
alias ai-deep='ollama run qwen2.5-coder:14b'

# Add to ~/.bashrc or ~/.zshrc
```

**Benchmarking Your Setup:**

```bash
#!/bin/bash
# benchmark-llm.sh - Test your hardware

models=("phi3:3.8b" "qwen2.5-coder:7b" "llama3.2:8b")
prompt="Write a bash function to safely backup a Drupal database"

echo "Benchmarking Local LLM Performance"
echo "Hardware: Ryzen 9 12-core, 32GB RAM, RTX 2060"
echo "-------------------------------------------"

for model in "${models[@]}"; do
    echo -n "Testing $model... "
    start=$(date +%s.%N)
    ollama run "$model" "$prompt" > /dev/null 2>&1
    end=$(date +%s.%N)
    duration=$(echo "$end - $start" | bc)
    echo "${duration}s"
done
```

**Comparison: Your Hardware vs Cloud API:**

| Metric | Your Workstation | Claude API |
|--------|------------------|------------|
| Privacy | 100% local | Data sent to Anthropic |
| Cost | $0/month (electricity ~$5) | $50-200/month |
| Speed (7B) | 15-25 tok/sec | 50-100 tok/sec |
| Quality (7B) | Very Good | Excellent |
| Offline | Yes | No |
| Best For | Daily coding, privacy | Complex architecture |

**Hybrid Workflow Recommendation:**

```
Daily Development (Local):
├── Code review → qwen2.5-coder:7b
├── Quick scripts → phi3:3.8b
├── Debug errors → llama3.2:8b
└── Commit messages → qwen2.5-coder:7b

Complex Tasks (Claude API):
├── Architecture decisions
├── Security audits
└── Novel problem solving
```

**Success Criteria:**

- [ ] Ollama installed with GPU acceleration verified
- [ ] qwen2.5-coder:7b running at 15+ tokens/sec
- [ ] Custom nwp-coder modelfile created
- [ ] Shell aliases configured for quick access
- [ ] Benchmark script confirms expected performance
- [ ] Memory usage stays under 24GB during inference
- [ ] GPU shows utilization during model inference

**What You CAN'T Run Efficiently:**

| Model | Why Not |
|-------|---------|
| qwen2.5-coder:32b | Needs 64GB RAM |
| llama3.1:70b | Needs 128GB RAM |
| codestral:22b | Needs 48GB+ RAM |
| Any model fully on GPU | 6GB VRAM too small |

**Upgrade Path (If Needed Later):**

| Upgrade | Cost | Benefit |
|---------|------|---------|
| +32GB RAM (64GB total) | ~$80 | Run 32B models |
| RTX 4060 Ti 16GB | ~$400 | 2-3x faster inference |
| RTX 4070 12GB | ~$550 | Full 7B on GPU |

---

### F09: Comprehensive Testing Infrastructure
**Status:** ✅ COMPLETE + ENHANCED | **Priority:** HIGH | **Effort:** High | **Dependencies:** Linode, GitLab CI
**Proposal:** [COMPREHENSIVE_TESTING_PROPOSAL.md](COMPREHENSIVE_TESTING_PROPOSAL.md)
**Console Guide:** [VERIFY_ENHANCEMENTS.md](VERIFY_ENHANCEMENTS.md)

Automated testing infrastructure using BATS framework with GitLab CI integration, plus interactive verification console with schema v2 enhancements:

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
- [x] Interactive verification console (v0.18.0) - Arrow navigation, checklist editor, history
- [x] Verification schema v2 (v0.18.0) - Individual checklist item tracking, audit trail
- [x] Auto-verification via checklist (v0.19.0) - Team collaboration, multi-coder support
- [x] Partial completion display (v0.19.0) - Shows progress for features in development
- [x] Checklist preview mode - Toggle display of first 3 items per feature
- [ ] E2E tests on Linode (infrastructure ready, tests pending)
- [ ] Test results dashboard

**Verification Console Features (v0.18.0-v0.19.0):**
- Default `pl verify` opens interactive TUI console
- Keyboard shortcuts: v:Verify, i:Checklist, u:Unverify, h:History, n:Notes, p:Preview
- Category navigation with ←→ arrows
- Feature navigation with ↑↓ arrows
- Interactive checklist editor with Space to toggle items
- Notes editor with auto-detection (nano/vim/vi)
- History timeline showing all verification events
- Auto-verification when all checklist items completed
- Perfect for distributed teams - each person completes different items

---

## Phase X: Experimental & Outlier Features

> **Note:** These proposals explore capabilities outside NWP's core mission of Drupal hosting/deployment. They are marked as "outliers" because they represent significant scope expansion. Implementation would only occur if there's strong user demand and clear use cases.

### X01: AI Video Generation Integration
**Status:** EXPLORATORY | **Priority:** LOW | **Effort:** High | **Dependencies:** F10 (Local LLM)
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
- [ ] Add video API config to cnwp.yml
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

**Configuration in cnwp.yml:**

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
- [ ] Configuration in cnwp.yml
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
| 9 | F10 | MEDIUM | Medium | None | 8 | Proposed |
| 10 | F11 | MEDIUM | Low | F10 | 8 | Proposed |
| 11 | F02 | LOW | Medium | F01 | 7b | Planned |
| - | X01 | LOW | High | F10 (optional) | X | Exploratory |

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

### Proposals
- [SEO_ROBOTS_PROPOSAL.md](SEO_ROBOTS_PROPOSAL.md) - SEO & search engine control (F07)
- [DYNAMIC_BADGES_PROPOSAL.md](DYNAMIC_BADGES_PROPOSAL.md) - Cross-platform badges (F08)
- [COMPREHENSIVE_TESTING_PROPOSAL.md](COMPREHENSIVE_TESTING_PROPOSAL.md) - Testing infrastructure (F09)

### Guides
- [LOCAL_LLM_GUIDE.md](LOCAL_LLM_GUIDE.md) - Complete guide to running open source AI models locally (F10)

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
