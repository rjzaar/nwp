# NWP Roadmap - Pending & Future Work

**NWP — Narrow Way Project** | Drupal hosting, deployment & infrastructure automation

**Last Updated:** February 1, 2026

Pending implementation items and future improvements for NWP.

> **For completed work, see [Milestones](../reports/milestones.md)**
> - Phase 1-5c: P01-P35 (Foundation through Live Deployment)
> - Phase 6-7: F04 (phases 1-5), F05, F07, F09, F12
> - Phase 8: P50, P51 (Unified Verification System)
> - Phase 9: P53-P58 (Verification & Production Hardening)
> - Phase 10 (partial): F03, F13, F14, F15 (Developer Experience)

---

## Current Status

| Metric | Value |
|--------|-------|
| Current Version | v0.28.0 |
| Test Success Rate | 88% (Machine Verified) |
| Completed Proposals | P01-P35, P50-P51, P53-P58, F03-F05, F07, F09, F12-F15 |
| Pending Proposals | F01-F02, F06, F08, F10-F11 |
| Rejected Proposals | P52 (rename — NWP is the permanent project name) |
| Experimental/Outlier | X01 |
| Recent Enhancements | v0.28.0: P53-P58, F03, F13-F15 (10 proposals implemented) |

---

## Proposal Designation System

| Prefix | Meaning | Count | Example |
|--------|---------|-------|---------|
| **P##** | Core Phase Proposals | 35 complete | P01-P35: Foundation→Live Deployment |
| **F##** | Feature Enhancements | 9 complete, 6 pending | F04: Governance, F09: Testing, F12: Todo |
| **X##** | Experimental Outliers | 1 exploratory | X01: AI Video (scope expansion) |

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
| **Phase 9** | **Verification & Production Hardening** | **P52-P58** | **✅ Complete** |
| **Phase 10** | **Developer Experience** | **F10, F11, F13, F14, F15** | **Partial (F13, F14, F15 ✅)** |
| **Phase X** | **Experimental/Outliers** | **X01** | **Possible** |

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
| 15 | F10 | PROPOSED | Local LLM support and privacy options |
| 16 | F11 | PROPOSED | Developer workstation LLM config (depends on F10) |
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
**Status:** ✅ IMPLEMENTED | **Priority:** MEDIUM | **Effort:** Medium | **Dependencies:** Behat BDD Framework

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

### F10: Local LLM Support & Privacy Options
**Status:** PROPOSED | **Priority:** MEDIUM | **Effort:** Medium | **Dependencies:** None
**Guide:** [F10-local-llm-guide.md](../proposals/F10-local-llm-guide.md) - Complete guide to using open source AI models

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

**Configuration in nwp.yml:**

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
│ Developer Choice (nwp.yml)         │
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
   - Configuration schema in nwp.yml

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
- [ ] AI provider selection in nwp.yml
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

### F15: SSH User Management
**Status:** ✅ IMPLEMENTED | **Priority:** MEDIUM | **Effort:** ~10 hours (practical version) | **Dependencies:** None
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
**Status:** ✅ IMPLEMENTED | **Priority:** MEDIUM | **Effort:** Low | **Dependencies:** None
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
**Status:** ✅ IMPLEMENTED | **Priority:** MEDIUM | **Effort:** Medium | **Dependencies:** None (benefits from F10)
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
**Status:** ✅ IMPLEMENTED | **Priority:** HIGH | **Effort:** 2-3 days | **Dependencies:** P50
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
**Status:** ✅ IMPLEMENTED | **Priority:** MEDIUM | **Effort:** 2-3 days | **Dependencies:** P50
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
**Status:** ✅ IMPLEMENTED | **Priority:** MEDIUM | **Effort:** 3-5 days | **Dependencies:** P54
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
**Status:** ✅ IMPLEMENTED | **Priority:** MEDIUM | **Effort:** 1-2 weeks | **Dependencies:** P54
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

#### P57: Production Caching & Performance
**Status:** ✅ IMPLEMENTED | **Priority:** MEDIUM | **Effort:** 1-2 weeks | **Dependencies:** P54
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
**Status:** ✅ IMPLEMENTED | **Priority:** LOW | **Effort:** 4-5 weeks | **Dependencies:** P50
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

## Phase X: Experimental & Outlier Features

> **Note:** These proposals explore capabilities outside NWP's core mission of Drupal hosting/deployment. They are marked as "outliers" because they represent significant scope expansion. Implementation would only occur if there's strong user demand and clear use cases.

### X01: AI Video Generation Integration
**Status:** POSSIBLE (deprioritized by Deep Analysis re-evaluation) | **Priority:** LOW | **Effort:** High | **Dependencies:** F10 (Local LLM)
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
| 15 | F10 | MEDIUM | Medium | None | 10 | Proposed |
| 16 | F11 | MEDIUM | Low | F10 | 10 | Proposed |
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
| - | X01 | LOW | High | F10 (optional) | X | Possible |

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
- [F10-local-llm-guide.md](../proposals/F10-local-llm-guide.md) - Complete guide to running open source AI models locally (F10)

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
*F12 (Unified Todo Command) completed: January 17, 2026*
*F15 (SSH User Management) added: January 24, 2026*
*F14 (Claude API Integration) added: February 1, 2026*
*Phase 9 (P52-P58 Verification & Production Hardening) added: February 1, 2026*
*F12 renumber conflict resolved (F12=Todo, F15=SSH): February 1, 2026*
*F01, F02, F06, F08, X01 reclassified as POSSIBLE per Deep Analysis: February 1, 2026*
*Broken proposal links fixed, Phase numbering updated: February 1, 2026*
*F15 expanded to ~10h practical scope with developer key onboarding: February 1, 2026*
*P56 updated with SSH key management for coder onboarding (Section 7): February 1, 2026*
