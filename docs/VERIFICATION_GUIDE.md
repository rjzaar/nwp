# NWP Function Verification Guide

A practical guide for new coders tasked with verifying NWP functions.

---

## Quick Overview: What is NWP?

**Narrow Way Project (NWP)** is a recipe-based automation system for managing local Drupal/Moodle development environments using DDEV. Key facts:

- **~50,000 lines** of bash code across 60+ files
- **22 main scripts** for installation, backup, deployment, etc.
- **25 library files** in `lib/` providing reusable functions
- **Recipe-driven** configuration via `cnwp.yml`
- **Two-tier secrets** architecture (infrastructure vs. data secrets)

---

## The Verification System

NWP has a built-in verification tracking system that ensures all features have been human-tested after code changes.

### How It Works

1. Each feature has associated source files tracked in `.verification.yml`
2. When you verify a feature, SHA256 hashes of those files are stored
3. When code changes, hashes no longer match → verification becomes invalid
4. Run `./verify.sh check` to detect invalidated verifications

### Key Commands

```bash
# Launch interactive TUI console (default since v0.19.0)
./verify.sh                  # Interactive console with keyboard navigation
pl verify                    # Same, via pl CLI

# View status report (old default)
./verify.sh report           # Show verification status report
./verify.sh status           # Alias for report

# Check what needs testing
./verify.sh list             # List all trackable features
./verify.sh check            # Find invalidated verifications

# Get testing details
./verify.sh details backup   # What changed? What to test?

# Mark as verified after testing
./verify.sh verify backup    # Mark 'backup' as verified

# Administration
./verify.sh reset            # Clear all verifications (start fresh)
```

**What's New (v0.18.0+):** The default `./verify.sh` now opens an interactive TUI console instead of showing a static report. See [VERIFY_ENHANCEMENTS.md](VERIFY_ENHANCEMENTS.md) for the complete console guide with keyboard shortcuts, checklist editing, history viewing, and auto-verification features.

---

## Verification Categories (42 Features)

| Category | Features | What They Cover |
|----------|----------|-----------------|
| **Core Scripts** (12) | setup, install, backup, restore, copy, make, delete, dev2stg, stg2prod, prod2stg, modify, verify | Main CLI tools |
| **Deployment** (8) | dev2stg, stg2prod, live, live2stg, live2prod, etc. | Environment pipelines |
| **Libraries** (12) | tui, checkbox, yaml_write, git, cloudflare, linode, etc. | Reusable functions |
| **Infrastructure** (5) | podcast, schedule, security, production | Server operations |
| **Testing** (1) | test_nwp | Integration tests |
| **GitLab** (4) | gitlab_setup, gitlab_backup, gitlab_restore, gitlab_upgrade | GitLab management |
| **Linode** (3) | linode_setup, linode_deploy, linode_backup | Server provisioning |

---

## Your Verification Workflow

### Step 1: Check Current Status

```bash
cd /home/rob/nwp
./verify.sh        # Opens interactive console (v0.19.0+)
# or
./verify.sh report # Traditional status report
```

**Interactive Console (recommended):** Navigate with arrow keys, press `v` to verify, `i` to edit checklists, `h` for history. See [VERIFY_ENHANCEMENTS.md](VERIFY_ENHANCEMENTS.md) for full keyboard shortcuts.

Look for:
- `[✓]` = Verified and unchanged
- `[!]` = Was verified but code changed (needs re-testing)
- `[◐]` = Partially complete (some checklist items done)
- `[○]` = Never verified

### Step 2: Pick a Feature to Verify

Start with features marked `[!]` (invalidated) or `[ ]` (untested).

```bash
# Get details on what to test
./verify.sh details backup
```

This shows:
- Which files are associated with the feature
- What changed since last verification
- Suggested test scenarios

### Step 3: Understand the Feature

**Every script has built-in help:**

```bash
./backup.sh --help
./restore.sh --help
./install.sh --help --list
```

**Check the documentation:**

| Document | When to Read |
|----------|--------------|
| `docs/SCRIPTS_IMPLEMENTATION.md` | Detailed script documentation |
| `docs/QUICKSTART.md` | Overall workflow |
| `docs/TESTING.md` | Testing infrastructure |
| `README.md` | Feature overview with examples |

### Step 4: Test the Feature

**Create a test site if needed:**

```bash
# Quick test site (uses 'nwp' recipe)
./install.sh testsite

# Or specific recipe
./install.sh testsite -r d   # Standard Drupal
```

**Run the feature with various options:**

```bash
# Example: Testing backup feature
./backup.sh testsite              # Full backup
./backup.sh testsite -b           # Database only
./backup.sh testsite -bg          # DB + git commit
./backup.sh testsite -y           # Auto-confirm
```

**Check error handling:**

```bash
./backup.sh nonexistent_site      # Should fail gracefully
./backup.sh ""                    # Should validate input
```

### Step 5: Mark as Verified

**Option A: In the interactive console (recommended):**
1. Navigate to the feature with arrow keys
2. Press `v` to mark verified
3. Or press `i` to edit checklist items individually

**Option B: Command line:**
```bash
./verify.sh verify backup
```

**Option C: Auto-verification via checklist (v0.19.0+):**
- Open console and press `i` on a feature
- Mark all checklist items complete with `Space`
- Feature auto-verifies when all items are done
- Perfect for team collaboration

See [VERIFY_ENHANCEMENTS.md](VERIFY_ENHANCEMENTS.md) for detailed console usage.

---

## Where to Find Help

### 1. Built-in Script Help

Every script supports `--help`:

```bash
./install.sh --help    # Usage, options, examples
./modify.sh --help     # Site modification options
./dev2stg.sh --help    # Deployment options
```

### 2. The Modify TUI (Interactive Help)

The `modify.sh` script has an interactive TUI with explanations:

```bash
./modify.sh sitename
```

**What you'll see:**
- Arrow key navigation between options
- **Each option shows a description** explaining what it does
- Dependencies shown (e.g., "requires: devel")
- Conflicts shown (e.g., "conflicts with: production_mode")
- Environment tabs (dev/stage/live/prod)

**TUI Controls:**
- `↑/↓` - Navigate options
- `Space` - Toggle selection
- `Enter` - Confirm and apply
- `q` - Quit without saving

### 3. Documentation Files

| File | Purpose |
|------|---------|
| `README.md` | Project overview, all features |
| `docs/QUICKSTART.md` | 5-minute getting started |
| `docs/SCRIPTS_IMPLEMENTATION.md` | Every script documented |
| `docs/NWP_TRAINING_BOOKLET.md` | 8-phase comprehensive training |
| `docs/TESTING.md` | Testing infrastructure |
| `docs/DATA_SECURITY_BEST_PRACTICES.md` | Secrets architecture |

### 4. Code Comments

Libraries have inline documentation:

```bash
# Read function headers
head -50 lib/common.sh
head -50 lib/yaml-write.sh
```

### 5. Example Configuration

```bash
# See all available options
cat example.cnwp.yml

# See current user config (if exists)
cat cnwp.yml
```

---

## Understanding the Code Structure

### Main Scripts (Root Directory)

```
install.sh      - Create new sites from recipes
setup.sh        - Install prerequisites
backup.sh       - Backup sites (full or DB-only)
restore.sh      - Restore from backups
copy.sh         - Duplicate sites
make.sh         - Toggle dev/prod mode
delete.sh       - Remove sites safely
modify.sh       - Interactive option editor
dev2stg.sh      - Deploy dev → staging
stg2prod.sh     - Deploy staging → production
verify.sh       - Feature verification tracking
```

### Library Files (lib/)

**Core (source these first):**
```
ui.sh           - Colors, status messages, formatting
common.sh       - Validation, secrets, config reading
yaml-write.sh   - YAML file manipulation
```

**Installation:**
```
install-common.sh  - Shared install logic, option definitions
install-drupal.sh  - Drupal/OpenSocial installer
install-moodle.sh  - Moodle installer
install-steps.sh   - Step tracking for resume capability
```

**TUI (Interactive):**
```
tui.sh          - Terminal UI framework
checkbox.sh     - Multi-select with dependencies
```

**Infrastructure:**
```
git.sh          - Git operations, GitLab API
linode.sh       - Linode API client
cloudflare.sh   - DNS management
remote.sh       - SSH operations
```

### Function Naming Conventions

| Prefix | Purpose | Example |
|--------|---------|---------|
| `print_` | Output/display | `print_status()`, `print_error()` |
| `validate_` | Input validation | `validate_sitename()` |
| `install_` | Installation | `install_drupal()`, `install_moodle()` |
| `get_` | Retrieve data | `get_secret()`, `get_yaml_value()` |
| `yaml_` | YAML operations | `yaml_add_site()`, `yaml_update()` |
| `git_` | Git operations | `git_init()`, `git_commit_backup()` |
| `ask_` | User prompts | `ask_yes_no()` |

---

## Testing a Library Function

### Example: Testing yaml-write.sh

```bash
# Run the dedicated test suite
./tests/test-yaml-write.sh

# Or test manually
source lib/ui.sh
source lib/common.sh
source lib/yaml-write.sh

# Test a function
yaml_get_value "sites.testsite.recipe" "cnwp.yml"
```

### Example: Testing UI Functions

```bash
source lib/ui.sh

# Test output functions
print_status "Testing status message"
print_error "Testing error message"
print_warning "Testing warning"
print_header "Section Header"
```

---

## Integration Tests

NWP includes integration test suites:

```bash
# Full integration tests
./tests/test-integration.sh

# YAML writing tests
./tests/test-yaml-write.sh

# Podcast feature tests
./tests/test-podcast.sh
```

Run these after making changes to verify nothing broke.

---

## Common Verification Scenarios

### Verifying backup.sh

1. Create a test site: `./install.sh verifytest`
2. Full backup: `./backup.sh verifytest`
3. DB-only backup: `./backup.sh verifytest -b`
4. With git: `./backup.sh verifytest -bg`
5. Check backup exists: `ls sitebackups/verifytest/`
6. Verify: `./verify.sh verify backup`

### Verifying restore.sh

1. Have a backup ready
2. Restore full: `./restore.sh verifytest`
3. Restore DB-only: `./restore.sh verifytest -b`
4. Restore latest: `./restore.sh verifytest -f`
5. Cross-site restore: `./restore.sh sourcesite targetsite`
6. Verify: `./verify.sh verify restore`

### Verifying install.sh

1. Install with different recipes:
   ```bash
   ./install.sh test1 -r nwp
   ./install.sh test2 -r d
   ./install.sh test3 -r os
   ```
2. Test resume: `./install.sh test1 --step=3`
3. Test content creation: `./install.sh test1 --create-content`
4. Verify: `./verify.sh verify install`

### Verifying modify.sh

1. Open TUI: `./modify.sh testsite`
2. Navigate options with arrow keys
3. Toggle some options with space
4. Confirm with enter
5. Verify changes applied
6. Verify: `./verify.sh verify modify`

---

## Tips for New Coders

### 1. Start Small
Begin with simpler features like `ui.sh` functions before tackling complex scripts like `install.sh`.

### 2. Use Test Sites
Always test on dedicated test sites, never on real project sites.

```bash
./install.sh verifytest1 -r d
./install.sh verifytest2 -r nwp
```

### 3. Clean Up After Testing

```bash
./delete.sh verifytest1 -y
./delete.sh verifytest2 -y
```

### 4. Check Git Status
Before verifying, ensure you're testing the current code:

```bash
git status
git log -3 --oneline
```

### 5. Read the Diff
When a verification is invalidated, see exactly what changed:

```bash
./verify.sh details featurename
git diff HEAD~5 -- lib/common.sh  # Example: see recent changes
```

### 6. Document Issues
If you find bugs during verification:

```bash
./report.sh "Description of the issue"
```

---

## Security Notes

### Files You Should NOT Touch

- `.secrets.data.yml` - Contains production credentials
- `keys/prod_*` - Production SSH keys
- `*.sql`, `*.sql.gz` - Database dumps with user data
- `cnwp.yml` - User's local config (don't commit)

### Safe Operations

When testing, use infrastructure secrets only:

```bash
# Safe - infrastructure tokens
source lib/common.sh
get_infra_secret "linode.api_token" ""

# Blocked - data secrets (will fail for AI)
get_data_secret "production_database.password" ""
```

---

## Quick Reference Card

```bash
# Check status
./verify.sh                    # Current status
./verify.sh list              # All features
./verify.sh check             # Find invalidated

# Get help
./scriptname.sh --help        # Any script
./modify.sh sitename          # TUI with explanations

# Test sites
./install.sh testsite -r d    # Create
./delete.sh testsite -y       # Remove

# After testing
./verify.sh verify featurename

# Run tests
./tests/test-integration.sh
./tests/test-yaml-write.sh
```

---

## Next Steps

1. Run `./verify.sh` to see current status
2. Pick one feature to start with
3. Read its `--help` and documentation
4. Create test site and run tests
5. Mark verified when complete
6. Move to next feature

**Goal:** All features showing `[✓]` with current code hashes.

---

# NWP Documentation Guide

A complete map of all NWP documentation organized by purpose.

## Learning Path (New Users)

| Step | Document | Purpose |
|------|----------|---------|
| 1 | [QUICKSTART.md](QUICKSTART.md) | Get running in 5 minutes |
| 2 | [SETUP.md](SETUP.md) | Detailed setup options |
| 3 | [FEATURES.md](FEATURES.md) | Feature reference by category |
| 4 | [NWP_TRAINING_BOOKLET.md](NWP_TRAINING_BOOKLET.md) | Comprehensive 8-phase training |

## Reference Documents

| Document | When to Use |
|----------|-------------|
| [FEATURES.md](FEATURES.md) | Looking up a specific feature or command |
| [LIB_REFERENCE.md](LIB_REFERENCE.md) | Writing scripts using NWP libraries |
| [SCRIPTS_IMPLEMENTATION.md](SCRIPTS_IMPLEMENTATION.md) | Understanding script internals |
| [../README.md](../README.md) | Project overview with examples |

## Deployment & Production

| Document | Purpose |
|----------|---------|
| [PRODUCTION_DEPLOYMENT.md](PRODUCTION_DEPLOYMENT.md) | Deploying sites to production |
| [LINODE_DEPLOYMENT.md](LINODE_DEPLOYMENT.md) | Linode-specific setup |
| [SSH_SETUP.md](SSH_SETUP.md) | SSH key configuration |
| [CICD.md](CICD.md) | CI/CD pipeline setup |

## Security & Best Practices

| Document | Purpose |
|----------|---------|
| [DATA_SECURITY_BEST_PRACTICES.md](DATA_SECURITY_BEST_PRACTICES.md) | Two-tier secrets, AI safety |
| [../CLAUDE.md](../CLAUDE.md) | AI assistant rules, protected files |

## Testing & Verification

| Document | Purpose |
|----------|---------|
| [TESTING.md](TESTING.md) | Running Behat, PHPUnit, PHPStan |
| [VERIFICATION_GUIDE.md](VERIFICATION_GUIDE.md) | Feature verification system (this doc) |
| [../KNOWN_ISSUES.md](../KNOWN_ISSUES.md) | Current known issues |

## GitLab & Infrastructure

| Document | Purpose |
|----------|---------|
| [../linode/gitlab/README.md](../linode/gitlab/README.md) | GitLab server setup |
| [../linode/gitlab/GITLAB_COMPOSER.md](../linode/gitlab/GITLAB_COMPOSER.md) | Composer package registry |
| [../linode/gitlab/GITLAB_MIGRATION.md](../linode/gitlab/GITLAB_MIGRATION.md) | Repository migration |
| [../linode/README.md](../linode/README.md) | Linode provisioning |

## Backup & Migration

| Document | Purpose |
|----------|---------|
| [BACKUP_IMPLEMENTATION.md](BACKUP_IMPLEMENTATION.md) | Backup system details |
| [GIT_BACKUP_RECOMMENDATIONS.md](GIT_BACKUP_RECOMMENDATIONS.md) | Git-based backup strategy |
| [MIGRATION_SITES_TRACKING.md](MIGRATION_SITES_TRACKING.md) | Sites registry migration |

## Planning & Roadmap

| Document | Purpose |
|----------|---------|
| [ROADMAP.md](ROADMAP.md) | Development roadmap (35 proposals complete, F01-F03 pending) |
| [CHANGES.md](CHANGES.md) | Version changelog |
| [ARCHITECTURE_ANALYSIS.md](ARCHITECTURE_ANALYSIS.md) | Research and comparisons |

## Archived Documents

Historical proposals and research in `docs/archive/`:
- Training system planning (Moodle/CodeRunner)
- Email/Postfix infrastructure proposal
- Original Vortex comparison and deployment analysis
- Code reviews and implementation summaries
- Import system proposal (now implemented)

## Document Organization

```
nwp/
├── README.md                 # Project overview
├── CLAUDE.md                 # AI assistant instructions
├── KNOWN_ISSUES.md           # Active issues
│
├── docs/                     # Main documentation
│   ├── README.md             # Navigation index
│   ├── QUICKSTART.md         # 5-minute guide
│   ├── SETUP.md              # Detailed setup
│   ├── FEATURES.md           # Feature reference
│   ├── LIB_REFERENCE.md      # Library API
│   ├── NWP_TRAINING_BOOKLET.md  # Training guide
│   ├── VERIFICATION_GUIDE.md # This document
│   └── archive/              # Historical docs
│
├── linode/                   # Linode infrastructure
│   ├── README.md             # Provisioning guide
│   └── gitlab/               # GitLab documentation
│       ├── README.md         # GitLab setup
│       ├── GITLAB_COMPOSER.md # Package registry
│       └── GITLAB_MIGRATION.md # Migration guide
│
├── templates/                # Configuration templates
│   └── env/                  # Environment templates (.env.*, .secrets.*)
│
└── lib/                      # Library scripts
    ├── env-generate.sh       # Generate .env from cnwp.yml
    └── ddev-generate.sh      # Generate DDEV config
```

---

*Last updated: January 2026*
