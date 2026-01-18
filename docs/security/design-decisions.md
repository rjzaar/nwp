# NWP Design Decisions: The Why Behind the Architecture

**Purpose:** Document the rationale behind key architectural decisions in NWP.
**Audience:** Future developers, contributors, and AI assistants.
**Last Updated:** January 2026

---

## Table of Contents

1. [Configuration Management](#1-configuration-management)
2. [Security Architecture](#2-security-architecture)
3. [Recipe System](#3-recipe-system)
4. [Deployment Workflow](#4-deployment-workflow)
5. [Git & Backup Strategy](#5-git--backup-strategy)
6. [Testing Infrastructure](#6-testing-infrastructure)
7. [Library Architecture](#7-library-architecture)
8. [CLI Design](#8-cli-design)

---

## 1. Configuration Management

### Why YAML (nwp.yml) instead of ENV files alone?

**Decision:** Use `nwp.yml` as the single source of truth, generating `.env` files from it.

**Rationale:**
- YAML supports hierarchical configuration with inheritance
- Human-readable and easy to edit for complex structures
- Recipes can override global defaults cleanly
- `.env` files are generated for compatibility with tools that expect them

**Trade-off:** Adds a generation step, but eliminates duplication and drift between configs.

### Why example.nwp.yml + nwp.yml pattern?

**Decision:** Template file is committed (`example.nwp.yml`), user config is gitignored (`nwp.yml`).

**Rationale:**
- Schema changes and defaults go in the example (version controlled)
- User-specific site data stays local (never committed)
- Users copy example to create their own config
- Prevents accidental credential commits

### Why no yq dependency?

**Decision:** Use `awk` instead of `yq` for YAML parsing.

**Rationale:**
- `awk` is universally available on all Unix systems
- No external dependencies to install
- Reduces setup friction for new users
- Works in minimal Docker containers

---

## 2. Security Architecture

### Why two-tier secrets?

**Decision:** Separate `.secrets.yml` (infrastructure) from `.secrets.data.yml` (production data).

**Rationale:**
- AI assistants can help with infrastructure (Linode, Cloudflare, GitLab) without accessing user data
- Production database passwords, SSH keys, SMTP credentials are fully blocked
- Defense-in-depth: even if one file leaks, data credentials are separate
- Clear mental model: "infrastructure" vs "data" access

**Implementation:**
```bash
# Safe for AI access
token=$(get_infra_secret "linode.api_token" "")

# Blocked from AI access
db_pass=$(get_data_secret "production_database.password" "")
```

### Why validate_sitename() before destructive operations?

**Decision:** Mandatory validation before `rm -rf` in delete.sh, copy.sh, restore.sh.

**Rationale:**
- Prevents path traversal attacks (`../../../etc`)
- Prevents command injection via special characters
- Defense-in-depth: even if input comes from config file
- Sitenames must be alphanumeric with underscores/hyphens only

### Why set -euo pipefail in all scripts?

**Decision:** Strict mode enabled by default.

**Rationale:**
- Exit immediately on errors (no silent failures)
- Catch undefined variables
- Fail pipeline if any command fails
- Forces explicit error handling

---

## 3. Recipe System

### Why recipe-based configuration?

**Decision:** Each site type (Drupal, Moodle, GitLab) defined as a "recipe" in nwp.yml.

**Rationale:**
- Single command installs any site type: `pl install avc mysite`
- Recipe-specific values override settings defaults
- Clear hierarchy: recipe -> settings -> profile -> hardcoded defaults
- Extensible: new application types just need new recipes

### Why profile_source for development?

**Decision:** Allow cloning profile from git instead of Composer package.

**Rationale:**
- Active development on both site and profile simultaneously
- Changes to profile immediately visible without publish cycle
- Production can still use Composer packages
- Flexibility for different workflows

### Why auto mode?

**Decision:** `auto: y` in recipes enables fully automated installation.

**Rationale:**
- Essential for CI/CD pipelines
- Reproducible installations without user interaction
- Skips TUI confirmation prompts
- Still validates inputs, just doesn't prompt

---

## 4. Deployment Workflow

### Why four states (DEV -> STG -> LIVE -> PROD)?

**Decision:** Four-state workflow with optional LIVE stage.

**Rationale:**
- **DEV**: Active development on DDEV (local)
- **STG**: Local staging for testing before cloud deployment
- **LIVE**: Cloud staging for client preview (optional)
- **PROD**: Production deployment

**Key insight:** LIVE is optional. Small projects can deploy STG -> PROD directly. Enterprise projects benefit from client preview on LIVE before production.

### Why NWP GitLab as primary remote?

**Decision:** Self-hosted GitLab created by setup.sh is the default git remote.

**Rationale:**
- Full data sovereignty
- No dependency on external services
- SSH access via `ssh git-server` alias
- External remotes (GitHub) are optional additions
- Backup destination without requiring third-party accounts

### Why never auto-deploy to production?

**Decision:** Automated security updates deploy to LIVE for review, never to PROD.

**Rationale:**
- Production changes require human approval
- LIVE allows testing in production-like environment
- Catches issues that automated tests might miss
- "Trust but verify" approach

---

## 5. Git & Backup Strategy

### Why separate code and database repositories?

**Decision:** Site code in `mysite/.git`, database backups in `sitebackups/mysite/db/.git`.

**Rationale:**
- Different retention policies (code forever, DB backups rotate)
- Different access controls (code public, DB private)
- Database uses `backup` branch to avoid GitLab main branch protection
- Cleaner history (code commits not mixed with DB dumps)

### Why git bundle support?

**Decision:** Support for single-file repository archives.

**Rationale:**
- Portable: copy to USB, offline storage
- Complete history in one file
- Supports incremental bundles
- Disaster recovery without network access

### Why 3-2-1 backup strategy?

**Decision:** Primary (NWP GitLab) + Secondary (external) + Tertiary (local bare repo).

**Rationale:**
- Industry-standard backup practice
- Survives single point of failure
- `--push-all` pushes to all configured remotes
- Different geographic locations for remotes

---

## 6. Testing Infrastructure

### Why BATS for shell scripts?

**Decision:** BATS (Bash Automated Testing System) for testing bash scripts.

**Rationale:**
- Standard framework, widely understood
- No external dependencies beyond bash
- Tests run in isolation
- Easy to write: just bash with assertions

### Why Mailpit for email testing?

**Decision:** Mailpit captures all development emails.

**Rationale:**
- Never sends to real recipients during development
- Web UI for visual inspection
- API for automated testing
- Catches accidental emails to production addresses

### Why Docker test environment?

**Decision:** Docker containers for isolated testing.

**Rationale:**
- Reproducible across machines
- Doesn't affect development environment
- Clean state for each test run
- Matches CI/CD environment

---

## 7. Library Architecture

### Why consolidated helper functions?

**Decision:** Shared libraries in `lib/` directory (ui.sh, common.sh, git.sh, etc.).

**Rationale:**
- Eliminated ~400+ lines of duplicate code
- Consistent function naming across all scripts
- Single source of truth for validation logic
- Easier testing and maintenance

**Libraries:**
- `lib/ui.sh` - User interface (print_header, print_status, print_warning)
- `lib/common.sh` - Utilities (validate_sitename, debug_msg)
- `lib/git.sh` - Git and GitLab API operations
- `lib/install-common.sh` - Shared installation functions
- `lib/install-drupal.sh` - Drupal-specific installation

---

## 8. CLI Design

### Why single entry point (pl command)?

**Decision:** All NWP functionality accessed via `pl` command.

**Rationale:**
- Consistent interface for all operations
- Tab completion support
- Reduces cognitive load (one command to remember)
- Easy to document and teach

**Examples:**
```bash
pl install d mysite      # Install Drupal site
pl backup -g mysite      # Backup with git
pl provision mysite      # Provision server
```

### Why step resumption (s=N)?

**Decision:** Installation can resume from any step with `./install.sh recipe s=5`.

**Rationale:**
- Installations can fail at any step
- Avoids restarting from scratch
- Sequential step numbering (no confusing substeps like 4.5)
- Saves time during debugging

---

## Key Architectural Principles

1. **Single Source of Truth:** nwp.yml for config, examples for templates
2. **Security by Default:** Protected files, validated inputs, strict mode
3. **Flexibility with Sensible Defaults:** Override when needed, but defaults work
4. **Self-Hosted First:** NWP GitLab primary, external services optional
5. **No External Dependencies for Core:** awk instead of yq, bash instead of specialized tools
6. **Test Everything:** BATS for scripts, Behat for Drupal, Docker for isolation
7. **Document the Why:** This document exists for future reference

---

## See Also

- [Architecture Analysis](../reference/architecture-analysis.md) - Detailed research and comparisons
- [Features](../reference/features.md) - Feature overview
- [Data Security Best Practices](data-security-best-practices.md) - Security guidelines
- [Libraries](../reference/libraries.md) - Library function reference
