# NWP Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

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

See [MILESTONES.md](docs/MILESTONES.md) for complete implementation history of proposals P01-P35.
