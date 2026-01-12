# NWP Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

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
  - Configurable via `settings.email` in cnwp.yml

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
