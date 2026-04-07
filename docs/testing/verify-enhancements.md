# NWP Verification Console - Interactive TUI Guide

**Last Updated:** January 14, 2026

A comprehensive guide to the `pl verify` interactive verification console introduced in v0.18.0, with Schema v2 enhancements in v0.19.0 and auto-verification via checklist completion in v0.19.0.

---

## Quick Start

```bash
# Launch interactive TUI console (default)
pl verify

# Or use the traditional status report
pl verify report
pl verify status    # alias for report
```

**What changed in v0.19.0:** The default behavior of `pl verify` now opens the interactive TUI console instead of showing a static status report. The old status view is still available via `pl verify report`.

---

## Overview

The NWP verification system tracks which features have been manually tested and verified by humans. Starting in v0.18.0, `pl verify` opens an **interactive terminal UI (TUI)** that allows you to:

- Navigate features by category
- View verification status at a glance
- Mark features as verified with a single keypress
- Edit checklists interactively
- Add notes and view history
- Toggle checklist preview mode
- Auto-verify via checklist completion

---

## Console Layout

```
┌──────────────────────────────────────────────────────────────────┐
│ NWP Verification Console                                         │
│ ←→:Category ↑↓:Feature | v:Verify i:Checklist u:Unverify |      │
│  d:Details n:Notes h:History p:Preview | c:Check r:Refresh q:Quit│
├──────────────────────────────────────────────────────────────────┤
│  [✓]Verified: 42  |  [◐]Partial: 8  |  [○]Unverified: 15  |     │
│  [!]Modified: 3  |  Total: 68                                    │
├──────────────────────────────────────────────────────────────────┤
│  [Core Scripts (12/12)]  Deployment  Infrastructure & CLI  ...   │
├──────────────────────────────────────────────────────────────────┤
│  ── Core Scripts ──  (12 features, page 1/7)                     │
│                                                                   │
│  > [✓] (setup)         NWP Setup                                 │
│    [✓] (install)       Site Installation                         │
│    [○] (status)        Site Status Check                         │
│    [!] (modify)        Modify Site Options                       │
│    [◐] (backup)        Site Backup (4/6 checklist items - 67%)  │
│    [✓] (restore)       Site Restore                              │
│                                                                   │
├──────────────────────────────────────────────────────────────────┤
│  NWP Setup                                                        │
│  Initial environment setup and prerequisite installation          │
│  ✓ Verified by rob at 2026-01-10T15:30:45-05:00                 │
└──────────────────────────────────────────────────────────────────┘
```

---

## Keyboard Shortcuts

### Navigation

| Key | Action |
|-----|--------|
| `↑` `↓` | Navigate features within current category |
| `←` `→` | Navigate between categories (wraps around) |

### Actions

| Key | Action |
|-----|--------|
| `v` | Mark current feature as verified |
| `i` | Open interactive checklist editor |
| `u` | Unverify current feature |
| `d` / `Enter` | Show detailed information about feature |
| `n` | Edit notes in text editor (nano/vim/vi) |
| `h` | Show verification history timeline |
| `p` | Toggle checklist preview mode (shows first 3 items) |
| `c` | Check for invalidated verifications (files changed) |
| `r` | Refresh data (reload from .verification.yml) |
| `q` | Quit console |

---

## Status Indicators

| Symbol | Meaning | Description |
|--------|---------|-------------|
| `[✓]` | Verified | Feature tested and code unchanged |
| `[○]` | Unverified | Not yet tested or never verified |
| `[!]` | Modified | Was verified but code changed (needs re-testing) |
| `[◐]` | Partial | Some checklist items completed but not fully verified |

**Partial completion** (v0.19.0): Shows completion percentage like "4/6 checklist items - 67%"

---

## Categories

Features are organized into 7 categories for easy navigation:

1. **Core Scripts** (12) - setup, install, status, modify, backup, restore, sync, copy, delete, make, migration, import
2. **Deployment** (8) - live, dev2stg, stg2prod, prod2stg, stg2live, live2stg, live2prod, produce
3. **Infrastructure & CLI** (9) - podcast, schedule, security, setup_ssh, uninstall, pl_cli, test_nwp, moodle, theme
4. **Libraries** (11) - lib_* functions
5. **Services & Config** (10) - GitLab, Linode, config files, tests
6. **CI/CD & Quality** (12) - CI, renovate, security updates, code quality tools
7. **Server & Production** (16) - Server management, multi-coder, monitoring

Navigate categories with `←` `→` arrows. Category names in the header show verification progress (e.g., "Core Scripts (12/12)" means 12 verified out of 12 total).

---

## Interactive Checklist Editor

Press `i` on any feature to open the checklist editor.

### Checklist Editor Controls

| Key | Action |
|-----|--------|
| `↑` `↓` | Navigate checklist items |
| `Space` | Toggle item completion (marks as done/undone) |
| `Enter` / `q` | Save changes and return to main console |
| `Escape` | Exit without saving |

### Checklist Display

```
┌──────────────────────────────────────────────────────────┐
│ Checklist Editor: Site Backup                            │
│ Use ↑↓ to navigate, Space to toggle, Enter/q to exit    │
├──────────────────────────────────────────────────────────┤
│                                                           │
│ > [✓] Test full backup with default options              │
│   [✓] Test database-only backup (-b flag)                │
│   [ ] Test backup with git commit (-bg flag)             │
│   [ ] Test cross-environment backup compatibility        │
│   [ ] Verify backup file structure and contents          │
│   [ ] Test restore from backup                           │
│                                                           │
│ Progress: 2/6 items completed                            │
└──────────────────────────────────────────────────────────┘
```

---

## Auto-verification via Checklist (v0.19.0)

**New in v0.19.0:** When all checklist items are completed, the feature automatically verifies itself.

### How It Works

1. Edit checklist and toggle all items to completed
2. System detects all items are done
3. Feature automatically marks as verified with `verified_by: "checklist"`
4. History shows "Verified via checklist" instead of individual name
5. Each item tracks `completed_by` for audit trail

### Multi-coder Collaboration

Perfect for distributed teams:

- **Alice** completes items 1-3
- **Bob** completes items 4-6
- System auto-verifies when all done
- History shows who completed each item
- No single person needs to manually verify

### Auto-unverification

If you uncomplete a checklist item on a feature that was auto-verified via checklist, it automatically unverifies the feature.

**Example:**
```bash
# Feature shows: [✓] Verified via checklist
# You press 'i' and uncheck an item with Space
# Feature now shows: [◐] Partial (5/6 items - 83%)
```

---

## Checklist Preview Mode

Press `p` to toggle preview mode. When enabled, the console shows the first 3 checklist items below each feature name.

### Preview Display

```
  [◐] (backup)        Site Backup (4/6 checklist items - 67%)
    ├─ [✓] Test full backup with default options
    ├─ [✓] Test database-only backup (-b flag)
    └─ [ ] Test backup with git commit (-bg flag)
        ... 3 more item(s)
```

**Use case:** Quickly scan which specific items remain for partially-completed features without opening the editor.

---

## Notes Editor

Press `n` to add or edit notes about a feature.

### Editor Selection

The system auto-detects your preferred editor:
1. Uses `$EDITOR` environment variable
2. Falls back to `nano`
3. Falls back to `vim`
4. Falls back to `vi`

### Setting Your Editor

```bash
# In your ~/.bashrc or ~/.bash_profile
export EDITOR=nano     # or vim, vi, emacs, etc.
```

### Notes Use Cases

- Document why verification failed
- Note dependencies that need fixing
- Track edge cases discovered during testing
- Explain special requirements

---

## Verification History

Press `h` to view the complete history timeline for a feature.

### History Display

```
═══════════════════════════════════════════════════════════════
  Verification History: Site Backup
═══════════════════════════════════════════════════════════════

  2026-01-12 10:15:23  rob       ✓ Checklist item completed
     Item 4 completed

  2026-01-12 09:42:10  alice     ✓ Checklist item completed
     Item 3 completed

  2026-01-11 14:20:35  system    ! Invalidated
     Files changed - auto-invalidated

  2026-01-10 16:05:12  rob       ✓ Verified
     Manual verification

  2026-01-09 11:30:00  rob       📝 Notes updated

Showing last 5 entries
```

### History Events

| Icon | Event Type | Description |
|------|------------|-------------|
| ✓ | verified | Feature marked as verified |
| ○ | unverified | Feature marked as unverified |
| ! | invalidated | Code changed, verification invalid |
| ✓ | checklist_item_completed | Individual checklist item done |
| ○ | checklist_item_uncompleted | Item marked incomplete |
| 📝 | notes_updated | Notes added or edited |

---

## Schema v2 Format

Starting in v0.18.0, `.verification.yml` uses schema v2 with enhanced tracking.

### Schema Upgrade

Old installations automatically upgraded from v1 to v2. The migration script:
- Converts simple checklist strings to objects
- Adds `history` array to each feature
- Maintains backward compatibility

### v2 Checklist Format

**v1 (old):**
```yaml
checklist:
  - "Test full backup"
  - "Test database backup"
```

**v2 (new):**
```yaml
checklist:
  - text: "Test full backup"
    completed: true
    completed_by: "rob"
    completed_at: "2026-01-10T15:30:45-05:00"
  - text: "Test database backup"
    completed: false
    completed_by: null
    completed_at: null
```

### v2 History Format

```yaml
history:
  - action: "verified"
    by: "rob"
    at: "2026-01-10T15:30:45-05:00"
    context: "Manual verification"
  - action: "checklist_item_completed"
    by: "alice"
    at: "2026-01-09T11:20:00-05:00"
    context: "Item 3 completed"
```

---

## Verification Workflow

### 1. Identify Features Needing Verification

Launch console and look for:
- `[!]` Modified features (highest priority - code changed)
- `[◐]` Partial features (work in progress)
- `[○]` Unverified features (never tested)

### 2. Review What Changed

Press `d` or `Enter` on a feature to see:
- Which files are tracked
- Recent git commits affecting those files
- Full checklist of verification steps

### 3. Test the Feature

Follow the checklist:
- Create test sites as needed
- Test each scenario
- Check error handling and edge cases

### 4. Mark Progress

**Option A: Complete checklist items as you go**
1. Press `i` to open checklist editor
2. Use `Space` to mark items complete
3. When all items done, auto-verifies

**Option B: Verify in one step**
1. Test all scenarios
2. Press `v` to mark verified
3. Optionally add notes with `n`

### 5. Check History

Press `h` to confirm verification recorded correctly.

---

## Example Verification Session

```bash
# Launch console
pl verify

# Navigate to "backup" feature using arrow keys
# Press 'd' to see details and checklist

# Press 'i' to open checklist editor
# Press Space on "Test full backup" → [✓]
# Press Down arrow
# Press Space on "Test DB backup" → [✓]
# Press Down arrow
# Press Space on "Test with git" → [✓]
# ... mark all items
# Press Enter to save

# System auto-verifies: [✓] Verified via checklist

# Press 'h' to view history
# See all checklist completions and auto-verification

# Press 'q' to quit
```

---

## Command-Line Alternatives

If you prefer non-interactive commands:

```bash
# View status report (old default behavior)
pl verify report
pl verify status

# Check for code changes
pl verify check

# Show feature details
pl verify details backup

# Mark as verified
pl verify verify backup

# Unverify
pl verify unverify backup

# List all features
pl verify list

# Summary statistics
pl verify summary

# Reset all verifications
pl verify reset
```

---

## Integration with Development

### When Code Changes

The verification system automatically detects code changes:
1. Each feature tracks SHA256 hashes of its source files
2. When files change, hash no longer matches
3. Status changes from `[✓]` to `[!]` (modified)
4. History records "invalidated" event

### Running Verification Check

```bash
# Manually check for invalidations
pl verify
# Press 'c' in console

# Or via command line
pl verify check
```

This scans all verified features and automatically unverifies any with changed files.

### Re-verification After Changes

1. Press `c` to check for invalidations
2. Navigate to features marked `[!]`
3. Press `d` to see what changed
4. Test affected functionality
5. Press `v` to re-verify

---

## Best Practices

### For Individual Developers

1. **Verify as you develop** - Mark features verified when implementing
2. **Check before commits** - Run `pl verify check` before committing
3. **Update checklists** - Add new test scenarios as edge cases are discovered
4. **Document in notes** - Explain special requirements or known issues

### For Teams

1. **Use checklist collaboration** - Multiple developers complete different items
2. **Review history** - Check who verified what and when
3. **Auto-verification** - Let checklist completion verify instead of manual
4. **Track invalidations** - Regular `pl verify check` to catch regressions

### For Release Managers

1. **Require verification** - All features must show `[✓]` before release
2. **Review partial completions** - Check `[◐]` features before tagging
3. **Check modified features** - No `[!]` status at release time
4. **Export status** - Use `pl verify summary` for release reports

---

## Troubleshooting

### Console Not Working

**Issue:** Console crashes or displays incorrectly

**Solution:**
- Ensure terminal supports ANSI colors (most modern terminals do)
- Try increasing terminal size (minimum 80 cols x 24 rows)
- Check `$TERM` environment variable is set correctly

### Verification Lost After Git Pull

**Issue:** Features show unverified after pulling code

**Cause:** `.verification.yml` not tracked in git

**Solution:** NWP intentionally excludes this file. Each developer tracks their own verification status.

### Checklist Editor Won't Open

**Issue:** Press `i` but nothing happens

**Cause:** Feature has no defined checklist

**Solution:** Not all features have checklists yet. Press `d` to see if checklist exists.

### Auto-verification Not Working

**Issue:** All checklist items marked but feature not verified

**Cause:** May be in v1 schema format

**Solution:**
```bash
# Check schema version
grep "^version:" .verification.yml

# If v1, run migration
./scripts/commands/migrate-verification-v2.sh
```

---

## Technical Details

### File Location

```
.verification.yml
```

**Note:** This file is in `.gitignore` - each developer maintains their own verification status.

### Schema Version Detection

The console auto-detects schema version:
- Checks `version: 2` field at top of file
- Falls back to v1 parsers if v1 format detected
- All features work with both versions

### Hash Calculation

- Uses SHA256 of all tracked files concatenated
- Changes to any tracked file invalidate verification
- Stored in `file_hash` field for each feature

### Performance

- Initial load: ~100ms for 77 features
- Category navigation: Instant
- Checklist editor: Sub-second startup
- Status checks: ~50ms per feature

---

## Related Documentation

- [VERIFICATION_GUIDE.md](VERIFICATION_GUIDE.md) - Overall verification system guide
- [TESTING.md](TESTING.md) - Automated testing infrastructure
- [HUMAN_TESTING.md](HUMAN_TESTING.md) - Manual testing procedures
- [CHANGELOG.md](../CHANGELOG.md) - Version history with verification features

---

## Migration from v1 to v2

If your installation uses the old v1 format:

```bash
# Run migration script
./scripts/commands/migrate-verification-v2.sh

# Verify upgrade
grep "^version:" .verification.yml
# Should show: version: 2
```

**What the migration does:**
- Adds `version: 2` header
- Converts checklist strings to objects
- Adds `completed: false` to all items
- Initializes empty history arrays
- Backs up original file to `.verification.yml.v1.backup`

---

*Last updated: January 12, 2026*
