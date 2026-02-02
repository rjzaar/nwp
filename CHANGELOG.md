# NWP Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [Unreleased]

---

## [v0.29.0] - 2026-02-02

### Changed
- **Backup gzip compression**: Database backups now use `.sql.gz` format (gzip compressed), reducing backup size significantly
- **Restore `.sql.gz` support**: Restore script handles both `.sql.gz` and legacy `.sql` backup files
- **`pl status` path fix**: Status command now works correctly from any working directory (uses absolute paths)

### Fixed
- **Verification test commands**: Fixed 30+ incorrect command syntaxes in `.verification.yml`:
  - Install commands: corrected positional argument order (`pl install <recipe> <target>`)
  - Recipe name: `nwp` → `d` (matching actual recipe name in nwp.yml)
  - Backup sanitize: `--sanitize basic` → `--sanitize --sanitize-level=basic`
  - Restore flags: `--latest -y` → `-fy` (correct flag names)
  - Removed invalid `-y` flag from backup commands
  - ddev describe patterns: added `OK` status (DDEV v1.24+ uses `OK` not `running`)
  - drush status patterns: `connected` → `Drupal|connected` (matching actual output)
  - Replaced unsupported `expect_output_gt` with `test -gt` commands
  - GitLab recipe: removed ddev checks (GitLab doesn't use DDEV)
  - Podcast recipe: changed to prerequisite checks (cloud infra required)
- **Backup sanitize workflow**: Decompress, sanitize, recompress for `.sql.gz` files
- **Restore tar path**: Fixed double-extension bug (`.tar.gz.tar.gz`) in file path derivation
- **Verification pass rate**: Improved from 96.4% to 99.5%+ (437→438+ of 440 tests passing)

---

## [v0.28.0] - 2026-02-01

### Added
- **P54**: Verification test fixes - execution guards on 35 scripts, 3 git functions, --collect for coders
- **P53**: Badge accuracy - fixed percentage calculations, renamed AI→Functional, v2 badge schema
- **P58**: Test dependency handling - --check-deps, --install-deps, --skip-missing flags
- **P56**: Production security hardening - UFW firewall, fail2ban, SSL hardening in produce.sh
- **P57**: Production performance - Redis/Memcache caching, PHP-FPM tuning, nginx optimization
- **F13**: Timezone configuration - centralized timezone in settings, updated StackScripts and fin-monitor
- **F15**: SSH user management - get_ssh_user() resolution chain, deploy-key, key-audit commands
- **F14**: Claude API integration - workspace provisioning, per-coder API keys, spend limits
- **P55**: Opportunistic human verification - tester prompts, bug reports, pl fix command
- **F03**: Visual regression testing - pl vrt baseline/compare/report/accept

### Changed
- Badge schema updated from v1 to v2 with category breakdowns
- verify.sh --ai renamed to --functional (--ai still accepted for compatibility)
- Badge label "Machine Verified" renamed to "Automated Tests"
- produce.sh now includes security and performance provisioning steps

### New Files
- lib/timezone.sh - Timezone configuration helpers
- lib/claude-api.sh - Claude API provisioning and management
- lib/verify-opportunistic.sh - Tester prompt system
- lib/verify-issues.sh - Bug report and issue management
- scripts/commands/fix.sh - AI-assisted issue fixing (pl fix)
- scripts/commands/vrt.sh - Visual regression testing (pl vrt)
- docs/proposals/F03-visual-regression-testing.md

---

## [v0.26.0] - 2026-02-01

### Added

- **F15**: SSH User Management proposal with worth-it evaluation
- **F13**: Timezone Configuration proposal
- **F14**: Claude API Integration proposal for team provisioning and spend controls
- Comprehensive NWP analysis report (2026-01-20)
- Podcast recipe: `use_server` option to install on existing server
- Podcast recipe: `base_domain` support for domain construction
- Automatic Cloudflare to Linode DNS fallback in podcast setup
- Auto-detect and offer existing server for same base domain
- `fin-monitor.sh` command

### Fixed

- DNS provider check exiting early due to `set -e`
- `linode_get_domain_id` failing with `pipefail`
- Podcast install to use site-specific domain over recipe default
- Podcast install header and `use_server` lookup
- yq v4 compatibility issues in P51 verification libraries

### Changed

- Renamed config file from `cnwp.yml` to `nwp.yml` for consistency

### Documentation

- Updated ROADMAP.md with current version and P50/P51 completion status
- Updated MILESTONES.md with P51 AI-Powered Deep Verification milestone
- Updated KNOWN_ISSUES.md with verification test infrastructure issues (P54)
- Added P52-P58 proposals for future work tracking
- Updated key metrics to reflect 88% machine verification rate

### Proposals Added

- **P52**: ~~Rename NWP to NWO~~ - REJECTED (NWP = Narrow Way Project, permanent name)
- **P53**: Verification Badge Accuracy - PROPOSED
- **P54**: Verification Test Fixes - PLANNED
- **P55**: Opportunistic Human Verification - PROPOSED
- **P56**: Produce Security Hardening - PROPOSED
- **P57**: Produce Performance - PROPOSED
- **P58**: Test Dependency Handling - PROPOSED

---

## [v0.25.0] - 2026-01-15

### Added
- Verification Execution Proposal documentation for systematic testing
- Parallel agent verification strategy (5 agents, 553 items)

### Fixed
- **lib/git.sh**: Git bundle path issue - relative paths now converted to absolute before `cd` to prevent incorrect path resolution
- **scripts/commands/restore.sh**: Backup selection error - `print_info` now uses stderr to prevent command substitution issues

### Verified
- Systematic verification of 70/89 features (78%)
- 424 checklist items verified, 0 failures
- lib_linode fully verified including instance creation/deletion
- Skipped items require external infrastructure (Cloudflare API, remote SSH)

---

## [v0.24.0] - 2026-01-15

### Added

#### Verification System Enhancements

Complete overhaul of the verification system with detailed verification instructions for all 553 checklist items across 89 features.

**Verification Content:**
- `how_to_verify` field: Step-by-step instructions for each checklist item
- `related_docs` field: Links to relevant documentation for each item
- 100% coverage: All 553 items now have verification instructions

**TUI Improvements:**
- Press `d` on any checklist item to view verification details
- Press `1-9` to open related documentation inline
- Clickable OSC 8 hyperlinks in supported terminals

**New Features (9 added):**
- avc_moodle_setup, avc_moodle_status, avc_moodle_sync, avc_moodle_test
- bootstrap_coder, doctor
- lib_avc_moodle, lib_podcast, lib_ssh

**Documentation:**
- Added CLAUDE_CHEATSHEET.md - Quick reference for Claude Code usage
- Added COMMAND_INVENTORY.md - Complete inventory of all pl commands

### Fixed

- Fixed YAML syntax errors in .verification.yml that prevented parsing
- Fixed TUI doc viewing (inline cat instead of problematic less calls)

---

#### AVC Email Reply System

Allows group members to reply to notification emails to create comments on content. Users receive notification emails with `Reply-To: reply+{token}@domain` headers and can respond directly via email.

**Features:**
- Secure token-based email reply system with HMAC-SHA256 signed tokens
- SendGrid Inbound Parse and Mailgun Routes integration
- Queue-based async processing for reliability
- Rate limiting (10/hour, 50/day per user; 100/hour per group)
- Spam filtering with configurable score threshold
- Content sanitization before comment creation

**Drush Commands:**
- `email-reply:status` - Check system status
- `email-reply:enable` - Enable email reply
- `email-reply:disable` - Disable email reply
- `email-reply:configure` - Configure settings
- `email-reply:generate-token` - Generate test token
- `email-reply:simulate` - Simulate email reply
- `email-reply:process-queue` - Process queue
- `email-reply:setup-test` - Set up test infrastructure
- `email-reply:test` - Run end-to-end test

**Testing Tools:**
- DDEV command: `ddev email-reply-test {setup|test|simulate|webhook|queue}`
- Web UI testing: `/admin/config/avc/email-reply/test`
- Automated end-to-end testing via Drush

**Recipe Integration:**
- `email_reply` configuration option in avc and avc-dev recipes
- Auto-configuration via post-install script
- Environment-aware setup (dev/stage: debug mode, production: optimized)

**Documentation:**
- Updated `docs/guides/email-setup.md` with email reply section
- Updated `docs/reference/commands/email.md` with Drush commands
- Module README with complete usage guide

---

## [v0.23.0] - 2026-01-14

### Documentation (Major Release)

This release represents the most comprehensive documentation update in NWP history, achieving **100% command documentation coverage** and complete library API reference.

#### Command Documentation (31 new files)

**Deployment Commands (6):**
- `stg2prod` - Staging to production deployment with module reinstallation
- `stg2live` - Staging to live with security hardening and password regeneration
- `prod2stg` - Production to staging pull for testing production issues
- `live` - Live server provisioning and management (shared/dedicated/temporary)
- `live2prod` - Direct live to production deployment
- `live2stg` - Live to staging pull workflow

**Testing Commands (4):**
- `test` - Comprehensive DDEV site testing (PHPCS, PHPStan, PHPUnit, Behat)
- `test-nwp` - Master NWP system test suite (22+ test categories)
- `run-tests` - BATS test orchestrator for unit/integration/E2E tests
- `testos` - OpenSocial-specific testing with Selenium

**Setup & Migration (7):**
- `setup` - Interactive TUI for managing 25+ prerequisites and components
- `setup-ssh` - SSH key generation and distribution to Linode servers
- `modify` - Interactive modification of existing site options
- `migration` - Platform migration workflow (Drupal 7/8/9, WordPress, Joomla)
- `migrate-secrets` - Two-tier secrets architecture migration tool
- `sync` - Remote site re-synchronization with automatic sanitization
- `upstream` - Distributed governance upstream synchronization

**Operations (7):**
- `rollback` - Deployment rollback management with rollback points
- `schedule` - Cron-based backup scheduling (database, full, bundle)
- `email` - Email infrastructure setup (Postfix, DKIM, SPF, DMARC)
- `storage` - Backblaze B2 cloud storage management
- `produce` - Production server provisioning on Linode
- `seo-check` - SEO monitoring and validation (robots.txt, sitemap.xml)
- `theme` - Frontend build tool management (Gulp, Grunt, Webpack, Vite)

**Specialized (7):**
- `avc-moodle-setup` - OAuth2 SSO setup for AVC-Moodle integration
- `avc-moodle-status` - Integration health dashboard
- `avc-moodle-sync` - Role/cohort synchronization (full, guild, user modes)
- `avc-moodle-test` - Comprehensive test suite (15 individual tests)
- `podcast` - Podcast hosting infrastructure with Castopod
- `bootstrap-coder` - Automated coder onboarding with identity detection
- `uninstall_nwp` - Safe uninstall with state-based intelligent removal

#### Library API Reference

**Created:** `docs/reference/api/library-functions.md`
- Documents **300+ functions** across **38 library files**
- Complete function signatures with parameters and return values
- Usage examples and security notes
- Cross-references to YAML_API.md and security documentation

**Key Libraries Documented:**
- `common.sh` (18 functions) - Core utilities and secrets management
- `ui.sh` (22 functions) - Output formatting and color support
- `ssh.sh` (5 functions) - SSH security controls
- `remote.sh` (7 functions) - Remote server operations
- `cloudflare.sh` (26+ functions) - Cloudflare API operations
- `linode.sh` (38+ functions) - Linode server management
- `yaml-write.sh` (40+ functions) - YAML parsing and modification
- `checkbox.sh` (30+ functions) - Multi-select TUI interface
- `tui.sh` (12 functions) - Full-screen TUI framework
- `git.sh` (60+ functions) - Git and GitLab API integration
- `install-common.sh` (35+ functions) - Installation workflow
- `testing.sh` (15 functions) - Test harness and assertions
- Plus 26 more specialized libraries

#### Git Hooks Implementation

**Created pre-commit hook:**
- Prevents committing `nwp.yml` (user-specific configuration)
- Warns about outdated documentation dates (>7 days)
- Validates command documentation structure
- Color-coded output with bypass instructions

**Created commit-msg hook:**
- Enforces non-empty commit messages
- Requires minimum 10 characters
- Warns about overly long first lines

**Documentation:** `docs/development/git-hooks.md`
- Complete hook documentation with examples
- Troubleshooting guide
- Customization instructions

#### Documentation Improvements

**Enhanced Core Documentation:**
- Updated `docs/SECURITY.md` with YAML/AWK injection protection (5-layer system)
- Expanded `lib/README.md` with yaml-write.sh, checkbox.sh, tui.sh documentation
- Updated `docs/VERIFY_ENHANCEMENTS.md` for v0.22.0+ features
- Added "Last Updated" dates to key documentation files

**README.md Enhancements:**
- Added environment naming clarity (dev/stg/live/prod)
- Recipe configuration hierarchy explanation
- Two-tier secrets early cross-reference
- pl CLI vs direct scripts clarification
- Site purpose values moved higher

**Documentation Index Updates:**
- Updated `docs/reference/commands/README.md` to 100% coverage (48/48 commands)
- Expanded `docs/README.md` with Development section and Git Hooks
- Added individual links to all 48 command documentation files

#### Workflow Guides (4 new comprehensive guides)

- `docs/guides/migration-workflow.md` - Complete migration process for all platforms
- `docs/guides/email-setup.md` - Email infrastructure and SMTP configuration
- `docs/deployment/rollback-procedures.md` - Rollback strategies and recovery
- `docs/guides/frontend-theming.md` - Unified frontend workflow for all build tools

#### Verification Documentation

**Created:** `docs/reference/verification-tasks.md`
- Complete reference for 42+ features across 10 categories
- Verification system explanation with SHA256 hashing
- Example checklists for major features
- Integration with `pl verify` command

### Impact

**Documentation Coverage:**
- Before: 39% (19/48 commands documented)
- After: **100% (48/48 commands documented)**
- Improvement: +61 percentage points

**Content Statistics:**
- 35 files changed
- 17,235 lines added
- Command documentation: +31 files
- Library API: 300+ functions documented
- Total documentation: ~42,000 lines

**Quality Enforcement:**
- Git hooks operational and tested
- Automated documentation standards checking
- Cross-reference validation
- Date tracking for freshness

### Documentation Standards

All new documentation follows `DOCUMENTATION_STANDARDS.md`:
- Consistent file naming (lowercase-with-hyphens)
- Standard structure (Synopsis, Description, Examples, Troubleshooting)
- Last Updated dates on all files
- Practical examples from actual codebase
- Comprehensive troubleshooting sections
- Cross-references to related documentation

---

## [v0.22.0] - 2026-01-14

### Added

- **CC0 Public Domain Dedication**
  - Added comprehensive CC0 1.0 Universal public domain dedication documentation
  - New `docs/CC0_DEDICATION.md` with full legal details and FAQs
  - Updated `CONTRIBUTING.md` with contributor agreement (CC0 dedication required)
  - Added license information to `example.nwp.yml` and `README.md`
  - Biblical foundation: "Freely you have received, freely give." — Matthew 10:8

- **AVC Help Documentation System**
  - Automated help page creation via `migrate_help_to_book.php` script
  - Integrated into avc-dev recipe `post_install_scripts`
  - Creates comprehensive help documentation on installation:
    - Main help hub at /help
    - User guide, guild guide, member levels, and more
    - All help pages secured to community-only (login required)

- **AVC Automated Content Generation**
  - Sample content generation in avc-dev recipe for development
  - Creates realistic test data for guild resources and member profiles
  - Helps developers test features with populated content

- **Shell Script Support in Recipes**
  - `post_install_scripts` now supports shell scripts (.sh) in addition to PHP
  - Enables more flexible post-installation automation

- **Complex Password Generation**
  - New `generate_random_password()` function for secure test user passwords
  - Creates complex passwords with letters, numbers, and special characters

### Changed

- **GitLab Composer Authentication**
  - Automatic GitLab composer configuration from `.secrets.yml`
  - Streamlines private repository access during installation

- **AVC Branding Updates**
  - Removed all Apostoli Viae references across codebase
  - Updated to AV Commons branding throughout
  - Fixed contact emails and URLs in documentation and database
  - Updated About page with AV Commons-specific content

- **Module Installation**
  - Development modules now installed via composer before enabling
  - Ensures proper dependency resolution

### Fixed

- **Test Suite Improvements**
  - Fixed test failures for non-existent site handling (unique names)
  - Achieved 99%+ pass rate across test suite
  - Fixed critical test issues for reliable CI/CD

- **nwp.yml Data Integrity**
  - Fixed critical bug preventing nwp.yml from being emptied on duplicate site entries
  - Improved site registration handling

- **AVC Guild Resources UX**
  - Made both title and URL clickable on /guild-resources page
  - Improved link accessibility and user experience

### Documentation

- **Comprehensive Documentation History Analysis**
  - Added detailed analysis of documentation evolution
  - Tracks major documentation milestones and restructuring

- **AVC Proposal Migration**
  - Moved AVC Error Reporting Module proposal to AVC repository
  - Better organization of AVC-specific features

---

## [v0.21.0] - 2026-01-13

### Added

- **YAML Parser Consolidation** (P17)
  - New unified YAML API with 4 core read functions:
    - `yaml_get_setting()` - Read settings with dot notation
    - `yaml_get_array()` - Read array values
    - `yaml_get_recipe_field()` - Read recipe fields
    - `yaml_get_secret()` - Read from .secrets.yml
  - Additional helper functions:
    - `yaml_get_all_sites()` - List all site names
    - `yaml_get_coder_list()` - List all coder names
    - `yaml_get_coder_field()` - Get coder field value
    - `yaml_get_recipe_list()` - Get recipe list array
  - 34 comprehensive BATS tests for YAML functions
  - Full API documentation in `docs/YAML_API.md`

- **yq YAML Processor**
  - Added yq as required setup component
  - Automatic installation via snap or binary download
  - yq-first with AWK fallback pattern for robust parsing

- **Automated Coder Identity Bootstrap**
  - New system for automated coder identity setup
  - Streamlined onboarding for new developers

- **AVC-Moodle SSO Integration**
  - Added Composer to setup prerequisites
  - Implemented SSO integration between AVC and Moodle

### Changed

- **Migrated 5 files to consolidated YAML functions:**
  - `lib/cloudflare.sh`
  - `lib/linode.sh`
  - `lib/common.sh`
  - `lib/install-common.sh`
  - `lib/b2.sh`

- Fixed `pl status` interactive mode with progressive loading
- Fixed variable name collision in coders.sh
- Fixed Linode NS record creation grep pattern
- Fixed Moodle CSS/JS loading in DDEV

### Documentation

- Added comprehensive YAML API documentation
- Updated roadmap with pragmatic priorities
- Added API client abstraction proposal for future reference

---

## [v0.20.0] - 2026-01-12

### Added

- **Major Documentation Restructure**
  - Reorganized 49 documentation files into 11 topic-based folders
  - New structure: guides/, reference/, deployment/, testing/, security/, proposals/, governance/, projects/, reports/
  - All files renamed to lowercase with hyphens for consistency
  - Git history preserved for all moved files

- **Command Reference Documentation**
  - New `docs/reference/commands/` directory with command index
  - Reference pages for 8 previously undocumented commands:
    - badges, coders, coder-setup, contribute, import, report, security, security-check
  - Comprehensive README.md listing all 43 NWP commands by category

- **Documentation Standards**
  - New `docs/DOCUMENTATION_STANDARDS.md` with guidelines for:
    - File naming conventions
    - Folder structure
    - Document structure requirements
    - Markdown style guide
    - Cross-reference guidelines
    - Proposal lifecycle

- **Deep Analysis Expansion**
  - Added detailed pros/cons analysis for alternative tool choices (Section 8.3)
  - CLI framework, YAML parsing, testing, API clients, progress indicators

### Changed

- Updated 150+ cross-references to use new documentation paths
- Rewrote `docs/README.md` as comprehensive navigation hub
- Updated root `README.md`, `CHANGELOG.md`, `KNOWN_ISSUES.md` with new paths
- Podcast theme documentation added to `docs/themes/`

### Documentation

- Command coverage increased from 43% to 62% (18 → 26 of 42 commands)
- New folder organization makes documentation discoverable
- Clear separation: guides vs reference vs proposals vs reports

---

## [v0.19.1] - 2026-01-12

### Added

- **Automated Site Email Configuration**
  - Auto-configure site emails during `pl live` deployment
  - Site email set to `sitename@nwpcode.org`
  - Admin email forwarding configured automatically
  - Configurable via `settings.email` in nwp.yml

- **Email Verification in Deployments**
  - Added email verification step to `stg2live` and `stg2prod`
  - Displays configured site email and admin address
  - Option to skip with `email.auto_configure: false`

- **AVC Work Management Documentation**
  - Added design drafts for work management module
  - Implementation planning documents

### Changed

- `stg2live.sh` now includes email verification step
- `stg2prod.sh` now includes email verification step

---

## [v0.19.0] - 2026-01-11

### Added

- **SSH Column in pl coders**
  - New SSH status column showing if coder has SSH keys on GitLab
  - Uses GitLab API to check `/users/:id/keys` endpoint
  - Status display: ✓ (has keys), ✗ (no keys), ? (unknown)

- **Auto-verification via Checklist Completion**
  - When all checklist items are completed, feature auto-verifies
  - Sets `verified_by: "checklist"` for multi-coder collaboration
  - Each item tracks individual `completed_by` for audit trail
  - Displays "Verified via checklist" instead of individual name
  - Auto-unverifies if checklist item uncompleted on checklist-verified feature

- **Partial Verification Display**
  - Shows ◐ indicator with completion percentage in `pl verify report`
  - Summary includes partial count alongside verified/unverified

### Changed

- `pl verify` now opens interactive TUI console by default
- Old status view renamed to `pl verify report` (status still works as alias)
- Reordered console footer: v:Verify i:Checklist u:Unverify

### Fixed

- Checklist toggle bug: Space now toggles only selected item (not all)
- AWK state machine in `get_checklist_item_status` returning duplicate values
- Added Escape key handling to exit checklist editor back to main console
- Column alignment in pl coders TUI for Unicode characters

---

## [v0.18.0] - 2026-01-10

### Added

- **Interactive Verification Console Enhancements**
  - Individual checklist item tracking with completion status
  - Press `i` in console to edit checklist items (toggle with Space)
  - Press `n` to edit notes in text editor (nano/vim/vi)
  - Press `h` to view verification history timeline
  - Press `p` to toggle checklist preview mode (shows first 3 items)
  - Partial completion status indicator `[◐]` for features with some items done
  - Verification history tracking for all events (verified, invalidated, checklist changes, notes)
  - Schema v2 migration for `.verification.yml` with backward compatibility
  - Migration script: `migrate-verification-v2.sh`
  - Comprehensive documentation: `VERIFY_ENHANCEMENTS.md`

### Changed

- `.verification.yml` upgraded from v1 to v2 format
  - Checklist items now objects with: text, completed, completed_by, completed_at
  - Added history array for audit trail
- Console summary now shows "Partial: N" count for partially completed features
- Updated console header with new keyboard shortcuts

### Fixed

- `delete.sh` - Fixed YAML comment parsing to strip trailing comments from settings
- Integration tests improved with better error handling and skip logic

### Technical Details

- Added ~700 lines to verify.sh with new interactive features
- AWK-based YAML parsing for efficient schema version detection
- All 77 verification tasks migrated successfully to schema v2
- Backward compatible with v1 format

---

## [v0.17.0] - 2026-01-09

### Added

- **Distributed Contribution Governance (F04)** - Phases 1-5 complete
  - `docs/decisions/` - Architecture Decision Records with 5 foundational ADRs
  - `docs/ROLES.md` - Formal role definitions (Newcomer → Contributor → Core → Steward)
  - `docs/CORE_DEVELOPER_ONBOARDING_PROPOSAL.md` - Full automation plan
  - `lib/developer.sh` - Developer level detection library
  - `scripts/commands/coders.sh` - Interactive TUI with arrow navigation, bulk actions, GitLab sync
  - `coder-setup.sh provision` - Automated Linode server provisioning
  - `coder-setup.sh remove` - Full offboarding with GitLab cleanup

- **Dynamic Badges Proposal (F08)** - GitLab-primary CI strategy with self-hosted support

- **Comprehensive Testing Proposal** - Full test documentation and Linode infrastructure plan
  - Documents all 23 test categories (200+ assertions) in test-nwp.sh
  - NWP feature inventory (38 commands, 36 libraries, 150+ functions)
  - TUI testing requirements
  - Proposed Linode-based E2E testing (~$32/month)

- **Release Tag Process** - Added to CLAUDE.md standing orders
  - 8-step release checklist
  - Changelog format template
  - Version numbering scheme

- **GitLab User Creation** - Automatic user creation in coder-setup.sh add command

- **Linode DNS Support** - Alternative to Cloudflare for coder NS delegation

### Changed

- **setup.sh** - Auto-select required and recommended components on first run
- **Executive Summary** - Updated for technical leadership audience
- **F08 Roadmap** - Updated to reflect self-hosted GitLab badge support

### Fixed

- **coders.sh TUI** - Fixed crash on space bar (removed set -e, added bounds checking)
- **coder-setup.sh** - Cloudflare now optional, graceful fallback when not configured

### Documentation

- Admin guide for developer onboarding to GitLab
- Clarified Cloudflare is optional for coder-setup

---

## [v0.16.0] - 2026-01-05

### Added

- Live deployment automation (P32-P35)
- SSH hardening for Linode provisioning
- Badges library improvements

### Fixed

- SSH hardening lockout during Linode provisioning
- badges.sh YAML comment stripping
- setup.sh crash when cancelling apply changes prompt

---

## [v0.15.0] and earlier

See [Milestones](docs/reports/milestones.md) for complete implementation history of proposals P01-P35.
