# verify

**Status:** ACTIVE
**Last Updated:** 2026-01-14

Interactive verification console for tracking manual testing and feature validation with automatic invalidation on code changes.

## Synopsis

```bash
pl verify [COMMAND] [ARGS]
```

## Description

The `verify` command provides an interactive TUI for tracking which NWP features have been manually tested and verified. When code changes, verifications are automatically invalidated, ensuring features are re-tested after modifications.

Tracks 42+ features across 10 categories with SHA256 file hashing for change detection.

## Commands

| Command | Description |
|---------|-------------|
| (default) | Interactive TUI console |
| `report` | Show verification status report |
| `check` | Check for invalidated verifications |
| `details <id>` | Show what changed and verification checklist |
| `verify` | Interactive verification mode |
| `verify <id>` | Mark specific feature as verified |
| `unverify <id>` | Mark feature as unverified |
| `list` | List all feature IDs |
| `summary` | Show summary statistics |
| `reset` | Reset all verifications |
| `help` | Show help message |

## Interactive TUI

Launch the verification console:

```bash
pl verify
```

**Navigation:**
- `↑/↓` - Navigate features
- `SPACE` - Toggle verification status
- `ENTER` - Mark as verified
- `v` - Verify selected feature
- `u` - Unverify selected feature
- `d` - Show details for feature
- `c` - Check for invalidations
- `r` - Refresh display
- `q` - Quit

## Feature Categories

- **Core Scripts** (12) - setup, install, status, backup, restore, etc.
- **Deployment** (8) - dev2stg, stg2prod, live, etc.
- **Infrastructure** (5) - podcast, schedule, security, etc.
- **CLI & Testing** (2) - pl_cli, test_nwp
- **Libraries** (12) - tui, checkbox, yaml_write, git, etc.
- **Moodle** (1) - Moodle installation support
- **GitLab** (4) - setup, hardening, repo management
- **Linode** (3) - setup, deploy, test server
- **Configuration** (2) - example configs
- **Tests** (1) - integration tests

## Examples

### Interactive Verification

```bash
# Launch TUI
pl verify

# Navigate and verify features interactively
```

### Command-Line Verification

```bash
# Verify specific feature
pl verify verify backup

# Verify with username
pl verify verify install rob

# Check for invalidations
pl verify check

# Show verification status
pl verify report
```

### Verification Workflow

```bash
# After code changes, check what needs re-verification
pl verify check

# Get detailed checklist for modified feature
pl verify details dev2stg

# After manual testing, mark as verified
pl verify verify dev2stg

# Show overall progress
pl verify summary
```

## Output

Status report:

```
═══════════════════════════════════════════════════════════════
  NWP Feature Verification Status
═══════════════════════════════════════════════════════════════

Core Scripts:
  [✓] setup       - Initial NWP setup  (verified by rob on 2026-01-14)
  [✓] install     - Site installation  (verified by rob on 2026-01-14)
  [✓] backup      - Backup creation    (verified by rob on 2026-01-13)
  [!] restore     - Restore from backup (modified since verification)
  [ ] delete      - Site deletion      (not verified)

Deployment:
  [✓] dev2stg     - Dev to staging     (verified by rob on 2026-01-14)
  [ ] stg2prod    - Staging to prod    (not verified)

═══════════════════════════════════════════════════════════════
  Summary: 25/42 verified (60%), 3 invalidated, 14 not verified
═══════════════════════════════════════════════════════════════
```

Details view:

```
═══════════════════════════════════════════════════════════════
  Feature: dev2stg (Dev to Staging Deployment)
═══════════════════════════════════════════════════════════════

Status: Modified since verification
Last Verified: 2026-01-13 by rob

Files Modified Since Verification:
  - scripts/commands/dev2stg.sh (5 changes)
  - lib/database-router.sh (2 changes)

Recent Commits:
  a1b2c3d4 - Fix database source selection (2026-01-14)
  b2c3d4e5 - Add retry logic for config import (2026-01-14)

Verification Checklist:
  [ ] Install development site
  [ ] Deploy to staging with TUI
  [ ] Test production database source
  [ ] Test development database source
  [ ] Run with essential test preset
  [ ] Run with full test preset
  [ ] Verify configuration import
  [ ] Verify production mode enabled
  [ ] Check staging site works correctly
  [ ] Test resume from interruption

After testing, mark as verified:
  pl verify verify dev2stg
```

Summary:

```
═══════════════════════════════════════════════════════════════
  Verification Summary
═══════════════════════════════════════════════════════════════

Progress: [████████████░░░░░░░░] 25/42 (60%)

Status Breakdown:
  ✓ Verified:     25 features
  ! Modified:      3 features (need re-verification)
  ☐ Not Verified: 14 features

By Category:
  Core Scripts:     8/12  (67%)
  Deployment:       4/8   (50%)
  Infrastructure:   3/5   (60%)
  CLI & Testing:    2/2   (100%)
  Libraries:        5/12  (42%)

Next Actions:
  1. Re-verify modified features (3)
  2. Verify remaining features (14)
```

## Verification Storage

Verification state is stored in `.verification.yml`:

```yaml
features:
  backup:
    status: verified
    verified_by: rob
    verified_at: 2026-01-13T14:22:15Z
    file_hashes:
      scripts/commands/backup.sh: sha256:a1b2c3d4...
      lib/backup-common.sh: sha256:b2c3d4e5...
```

## See Also

- [verify --run](./verify.md) - Automated verification suite
- [Human Testing Guide](../../testing/human-testing.md) - Manual testing procedures
- [Verification Tasks](../../reference/verification-tasks.md) - Complete verification checklist
