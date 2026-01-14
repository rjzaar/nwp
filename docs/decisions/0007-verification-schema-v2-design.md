# ADR-0007: Verification Schema v2 Design

**Status:** Accepted
**Date:** 2026-01-10
**Decision Makers:** Rob
**Related Issues:** F09 (Comprehensive Testing Infrastructure), v0.18.0
**Related Commits:** 37a2c3d5, bc0c796c, 54e5b218
**References:** [VERIFY_ENHANCEMENTS.md](../testing/verify-enhancements.md), [verification-tasks.md](../reference/verification-tasks.md)

## Context

NWP's `.verification.yml` file tracks manual verification of 42+ features across 10 categories. The original schema (v1) had limitations:

1. **Binary verification** - Features were either verified or not, with no partial completion tracking
2. **No team collaboration support** - In distributed teams, multiple people may verify different aspects
3. **No audit trail** - History of verification events was not tracked
4. **Checklist items as strings** - Simple array of strings with no completion metadata
5. **No granular progress** - Couldn't see which specific checklist items were complete

With F04 (Distributed Contribution Governance) enabling multi-developer collaboration, the verification system needed to support:
- Multiple team members completing different checklist items
- Partial completion status (3 of 5 items complete)
- Audit trail for accountability
- Auto-verification when all items completed

## Options Considered

### Option 1: Schema v2 with Individual Item Tracking
- **Pros:**
  - Each checklist item tracks: `text`, `completed`, `completed_by`, `completed_at`
  - Supports distributed team collaboration
  - Clear audit trail of who completed what
  - Auto-verification possible when all items complete
  - Partial completion status for progress tracking
  - History array tracks all verification events
- **Cons:**
  - More complex YAML structure
  - Requires migration script for existing files
  - Larger file size (more metadata per item)

### Option 2: Keep v1 Schema, Add Separate Tracking File
- **Pros:**
  - No migration needed
  - Simpler YAML structure
- **Cons:**
  - Two files to synchronize (error-prone)
  - No atomic updates
  - Harder to query completion status
  - More complex implementation

### Option 3: External Database (SQLite)
- **Pros:**
  - Powerful queries
  - Better for large teams
  - Relational data model
- **Cons:**
  - Over-engineering for NWP scale
  - Loses human-readable/editable format
  - Requires database migrations
  - Harder to version control

## Decision

Implement Schema v2 with individual checklist item tracking in `.verification.yml`:

```yaml
version: 2

features:
  feature_id:
    name: "Feature Name"
    description: "Description"
    files:
      - file1.sh
      - file2.sh
    checklist:
      - text: "Checklist item 1"
        completed: false
        completed_by: null
        completed_at: null
      - text: "Checklist item 2"
        completed: true
        completed_by: "rob"
        completed_at: "2026-01-10T14:30:00Z"
    verified: false
    verified_by: null
    verified_at: null
    file_hash: "..."
    notes: "..."
    history:
      - action: "checklist_item_completed"
        by: "rob"
        at: "2026-01-10T14:30:00Z"
        context: "Item 2 completed"
```

**Key Features:**
1. **Individual item tracking** - Each checklist item is an object with completion metadata
2. **Auto-verification** - When all items complete, feature auto-verifies with `verified_by: "checklist"`
3. **Partial status** - Status code `3` for features with some items complete (displayed as `[◐]`)
4. **History tracking** - All verification events logged in `history` array
5. **Backward compatibility** - v1 files are automatically upgraded on first read

## Rationale

### Why Individual Item Tracking?

The key insight: **verification is a team activity, not an individual action**. In F04's distributed governance model, different developers may verify different aspects:
- Developer A tests the UI (items 1-3)
- Developer B tests the API (items 4-6)
- Developer C tests edge cases (items 7-9)

This requires granular tracking of who completed what and when.

### Why Auto-Verification?

Manual verification is redundant when all checklist items are complete. Auto-verification with `verified_by: "checklist"` provides:
- Clear signal that verification is complete via checklist
- Audit trail preserved in item-level metadata
- Reduces manual steps

### Why Partial Completion Status?

Progress visibility is critical for:
- Understanding how much work remains
- Distributed teams knowing what others completed
- Prioritizing incomplete items

The `[◐]` indicator (half-circle) visually communicates "in progress".

### Why History Tracking?

Accountability and audit trail are governance requirements:
- Who made changes and when
- Why features were unverified
- Pattern analysis (frequently invalidated features need attention)

## Consequences

### Positive
- **Distributed team support** - Multiple developers can contribute to verification
- **Progress visibility** - Partial completion shows work-in-progress
- **Accountability** - Clear audit trail of all actions
- **Reduced manual work** - Auto-verification when checklist complete
- **Better reporting** - Can query completion rates, identify bottlenecks

### Negative
- **Migration required** - Existing v1 files need migration (automated by `migrate-verification-v2.sh`)
- **Larger file size** - More metadata per item (~3x increase)
- **Parsing complexity** - AWK scripts more complex for object arrays

### Neutral
- **Backward compatibility** - v1 files work but lack new features
- **Version field** - Must check `version: 2` to enable features

## Implementation Notes

### Interactive Checklist Editor (Press `i` in Console)
```bash
./pl verify console
# Navigate to feature
# Press 'i' to edit checklist
# Use ↑↓ to navigate items
# Press Space to toggle completion
# Enter to save
```

### Status Codes
- `0` = Unverified (no items complete, not verified)
- `1` = Verified (manually verified or auto-verified via checklist)
- `2` = Modified (files changed since verification)
- `3` = Partial (some checklist items complete, but not verified)

### Category Redistribution

Schema v2 enabled category redistribution (commit fdf34af4) to prevent overcrowding:
- **Problem:** Some categories had 20+ features, poor UX
- **Solution:** Max 14 items per category for comfortable arrow navigation
- **Implementation:** Split large categories (e.g., "Testing" split into "Test Suites" and "Test Infrastructure")

This decision demonstrates schema flexibility - the richer v2 metadata enabled better organization.

### Performance Optimization

AWK-based parsing for efficiency:
```bash
# Fast schema version detection
awk '/^version:/ {print $2; exit}' .verification.yml

# Efficient checklist item extraction
awk '/^  checklist:/,/^  [a-z]/' .verification.yml
```

Single-pass AWK scripts avoid repeated file reads.

## Migration Path

### Automated Migration
```bash
./migrate-verification-v2.sh
# Creates .verification.yml.v1.backup
# Converts checklist strings to objects
# Preserves all existing data
```

### Manual Migration (if needed)
```yaml
# v1 format
checklist:
  - "Item 1"
  - "Item 2"

# v2 format
checklist:
  - text: "Item 1"
    completed: false
    completed_by: null
    completed_at: null
  - text: "Item 2"
    completed: false
    completed_by: null
    completed_at: null
```

## Alternatives Considered

### Alternative 1: Add `progress` Field to v1 Schema
Simple integer field showing number of items complete.

**Rejected because:**
- Doesn't show *which* items are complete
- No individual accountability
- No audit trail
- Doesn't support distributed teams

### Alternative 2: Tags/Labels Instead of Objects
Use inline markers like `- "[x] Item 1"` (markdown-style).

**Rejected because:**
- No structured metadata (who, when)
- Harder to parse reliably
- No timestamp tracking
- Not extensible

### Alternative 3: Separate `.verification-progress.yml`
Keep v1 schema, add progress tracking in separate file.

**Rejected because:**
- Two files can get out of sync
- Atomic updates impossible
- More complex to maintain
- Violates single source of truth

## Review

**30-day review date:** 2026-02-10
**Review outcome:** Pending

**Success Metrics:**
- [ ] All 77 features migrated to v2 (COMPLETE)
- [ ] Distributed teams successfully collaborate on verification
- [ ] Auto-verification reduces manual verification by 50%+
- [ ] No data loss or corruption reports
- [ ] Performance acceptable (<1 second for console rendering)

## Related Decisions

- **ADR-0002: YAML-Based Configuration** - Established YAML as config format
- **ADR-0005: Distributed Contribution Governance** - Enabled multi-developer collaboration
- **ADR-0009: Five-Layer YAML Protection System** (pending) - Security constraints on YAML parsing

## Future Enhancements

Possible additions for schema v3 (not planned):
- Priority/severity levels per feature
- Team assignment to features
- Time estimates and actual time tracking
- Dependencies between features
- Verification expiration (re-verify after N days)
- Integration with GitLab issues
