# P60: Verification Badge Accuracy v2

**Status:** PROPOSED
**Created:** 2026-02-02
**Author:** Claude (Opus 4.5)
**Priority:** Medium
**Depends On:** P53 (Verification Categorization & Badge Accuracy)
**Estimated Effort:** 2-3 days
**Breaking Changes:** No

---

## 1. Executive Summary

### 1.1 Problem Statement

The verification badge system reports 90.3% machine verification coverage (514/569), but this number is misleading due to three data integrity issues introduced during the rapid evolution from P50 through P54:

1. **Wrong denominator**: The badge divides by 569 (all items with a `machine:` block), but 117 of those items are marked `automatable: false`. The denominator should be 452.
2. **102 data inconsistencies**: Items marked `automatable: false` have `machine.state.verified: true`. Non-automatable items shouldn't count as machine-verified.
3. **40 unverifiable items classified as automatable**: Features like `dev2stg`, `stg2prod`, and `prod2stg` require live infrastructure and can never pass locally, yet are marked `automatable: true`.
4. **12-item depth gap**: 12 items marked `automatable: true` have no test commands at some depth levels, causing them to be skipped during runs.
5. **Runner divergence**: `lib/verify-runner.sh` has no awareness of the `automatable` flag, while `scripts/commands/verify.sh` respects it — creating inconsistent counts depending on which code path is used.

### 1.2 Proposed Solution

- Fix badge calculation to use correct denominator (automatable items only)
- Clean 102 data inconsistencies in `.verification.yml`
- Introduce `environment_dependent` category for infrastructure-requiring tests
- Add missing test commands for the 12-item depth gap
- Update `verify-runner.sh` to understand the `automatable` flag
- Regenerate the statistics section from actual data

### 1.3 Key Metrics

| Metric | Before | After |
|--------|--------|-------|
| Badge denominator | 569 (all items) | 452 (automatable only) |
| Machine verified display | 514/569 = 90.3% | 412/412 = 100% (local) |
| Data inconsistencies | 102 | 0 |
| Unclassified items | 40 | 0 |
| Runner agreement | No | Yes |

---

## 2. Root Cause Analysis

### 2.1 Historical Context

The verification system evolved through four proposals in rapid succession:

| Date | Proposal | Change | Side Effect |
|------|----------|--------|-------------|
| Jan 16 | P50 | Created unified `.verification.yml` with `verify-runner.sh` | All items got `machine:` blocks |
| Jan 17 | P50 | `verify.sh` gained `run_machine_checks()` | Two code paths for counting |
| Jan 18 | P53 | Added `automatable: true/false` flag | Flag added but existing data not cleaned |
| Feb 1 | P54 | Fixed test commands, BASH_SOURCE guards | Pass rate improved but badge unchanged |

P53 correctly identified the denominator problem and added the `automatable` flag, but:
- Existing `verified: true` states on non-automatable items were not cleared
- `verify-runner.sh` was not updated to understand the new flag
- No data migration was performed on the 569 existing items

### 2.2 The 102 Data Inconsistencies

These items have both `automatable: false` AND `machine.state.verified: true`:

```yaml
# Example: backup item 5
- text: Test --git flag pushes to GitLab repository
  machine:
    automatable: false          # Cannot be machine-tested
    reason: Requires GitLab repository access
    state:
      verified: true            # But claims machine-verified!
```

These items were manually verified by humans (via `completed: true`, `completed_by: greg`), and the `verified: true` was set during an early bulk update before the `automatable` flag existed.

### 2.3 The 40 Infrastructure-Dependent Items

Features requiring live servers that cannot be tested locally:

| Feature | Count | Requires |
|---------|-------|----------|
| dev2stg | 19 | Running staging server |
| stg2prod | 6 | Production server access |
| prod2stg | 5 | Production database access |
| security_validation | 4 | Full stack with SSL |
| lib_dev2stg_tui | 3 | TUI + staging server |
| live2stg | 2 | Live server SSH access |
| stg2live | 1 | Staging-to-live promotion |

These are genuinely automatable — but only in a CI/CD environment with infrastructure access, not on a developer workstation. They need a distinct classification.

### 2.4 The 12-Item Depth Gap

12 items have `automatable: true` but are missing test commands at one or more depth levels. When a run uses that depth, they're silently skipped. These should either:
- Have test commands added at all depths
- Have `automatable` set to `false` with explanation

### 2.5 Runner Divergence

| Capability | `verify-runner.sh` | `verify.sh` |
|------------|-------------------|-------------|
| Counts items | All with `machine:` block | Filters by `automatable: true` |
| Updates YAML state | No | Yes (`update_machine_verified()`) |
| Generates badges | Yes (`generate_badges_json()`) | Yes (`generate_badges()`) |
| Respects `automatable` flag | No | Yes |
| Used by | Background runs, log-based | `pl verify --run`, TUI |

Two badge generators exist with different logic — `verify-runner.sh:1089-1231` and `verify.sh:3575-3701`. Only `verify.sh` filters by automatable flag.

---

## 3. Implementation Plan

### Phase 1: Data Cleanup

1. Clear `machine.state.verified` to `false` on all 102 items where `automatable: false`
2. Add `environment_dependent: true` field to the 40 infrastructure items
3. Set `automatable: false` on those 40 items (they can't pass locally)
4. Update their `reason:` field to explain the infrastructure requirement

### Phase 2: Fix Badge Calculation

1. Update `count_automatable_items()` in `verify.sh` (line 2517) — should already be correct, verify
2. Update `count_machine_verified_items()` (line 2528) — must exclude `automatable: false` items
3. Update `generate_badges()` (line 3575) — ensure denominator uses automatable count
4. Update badge generation in `verify-runner.sh` (line 1089) — add automatable awareness
5. Add separate "Environment Tests" badge for infrastructure-dependent items

### Phase 3: Fill Depth Gaps

1. Identify the 12 items with missing depth-level commands
2. Add appropriate test commands at all depth levels, or reclassify as non-automatable
3. Ensure every `automatable: true` item has commands at least at `basic` and `standard` depths

### Phase 4: Unify Runners

1. Add `is_item_automatable()` function to `verify-runner.sh`
2. Update `verify-runner.sh` badge generation to respect the automatable flag
3. Ensure both badge generators produce identical output for the same data
4. Add `update_machine_verified()` capability to `verify-runner.sh` so background runs update state

### Phase 5: Statistics Regeneration

1. Update the `statistics:` section at the top of `.verification.yml` to be auto-generated
2. Add `pl verify stats` subcommand that recalculates and updates the statistics block
3. Call this automatically after `pl verify --run` completes

---

## 4. Files to Modify

| File | Changes |
|------|---------|
| `.verification.yml` | Clear 102 inconsistent states; add `environment_dependent` to 40 items; fill 12 depth gaps; regenerate statistics |
| `scripts/commands/verify.sh` | Fix `count_machine_verified_items()` to exclude non-automatable; add `pl verify stats` subcommand |
| `lib/verify-runner.sh` | Add `is_item_automatable()` function; update badge generation; add state update capability |
| `.badges.json` | Regenerated with correct percentages |

## 5. Files to Create

None.

---

## 6. New Badge Display

After implementation, three badges should be generated:

| Badge | Calculation | Meaning |
|-------|-------------|---------|
| **Automated Tests** | Passed / automatable items | What % of locally-testable items pass |
| **Environment Tests** | Passed / environment-dependent items | What % pass in CI with infrastructure |
| **Human Verified** | Completed / human-only items | What % have been manually verified |

---

## 7. Success Criteria

- [ ] Zero items with `automatable: false` AND `machine.state.verified: true`
- [ ] Badge denominator equals count of `automatable: true` items only
- [ ] All `automatable: true` items have test commands at basic and standard depths minimum
- [ ] 40 infrastructure items reclassified with `environment_dependent: true`
- [ ] `verify-runner.sh` and `verify.sh` produce identical badge calculations
- [ ] `pl verify badges` output matches `pl verify --run` results
- [ ] `statistics:` section auto-regenerated after each run
- [ ] Badge shows 100% for locally-passing items after a clean run

---

## 8. Verification Commands

```bash
# Phase 1: Verify data cleanup
# Count items with automatable: false AND verified: true (should be 0)
awk '/automatable: false/{af=1} af && /verified: true/{count++; af=0} /^    - text:/{af=0} END{print count}' .verification.yml

# Phase 2: Verify badge math
pl verify badges  # Should show automatable-only denominator

# Phase 3: Verify depth coverage
pl verify --run --depth=basic    # All automatable items should run
pl verify --run --depth=standard # All automatable items should run

# Phase 4: Verify runner agreement
pl verify badges > /tmp/badges1.txt
# Compare with verify-runner.sh output

# Phase 5: Verify statistics
pl verify stats  # Should match badge output
```

---

## 9. Related Proposals

| Proposal | Topic | Relationship |
|----------|-------|-------------|
| P50 | Unified Verification System | Created the YAML structure and verify-runner.sh |
| P51 | AI-Powered Verification | Added functional/scenario testing layer |
| P53 | Verification Badge Accuracy v1 | Added automatable flag; this proposal completes that work |
| P54 | Verification Test Fixes | Fixed test commands; uncovered the data issues |

---

## 10. Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| YAML corruption during bulk state update | Low | High | Use ADR-0009 five-layer protection for all writes |
| Badge regression (shows lower %) | Medium | Low | Expected — correct number will be lower but accurate |
| Breaking verify.sh TUI display | Low | Medium | Test TUI after changes |

---

*Last Updated: 2026-02-02*
