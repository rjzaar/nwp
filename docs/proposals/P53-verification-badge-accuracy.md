# P53 Proposal: Verification Categorization and Badge Accuracy

**Target File:** `docs/proposals/P53-verification-badge-accuracy.md`

**Status:** IMPLEMENTED
**Created:** 2026-01-18
**Author:** Claude Opus 4.5 (research/design), Rob (requirements)
**Priority:** Medium
**Estimated Effort:** 2-3 days
**Breaking Changes:** Yes - `--ai` flag removed (use `--functional`)

---

## 1. Problem Statement

The current NWP verification system has three significant accuracy and clarity issues:

### 1. "AI Verification" is Misleading
P51's "AI-Powered Deep Verification" uses sophisticated bash/drush scenario testing but contains **zero AI/LLM calls**. The "AI" name implies Claude API integration that doesn't exist. It's actually:
- Scenario-based workflow testing
- State capture and comparison (before/after)
- Checkpoint-based resumable runs
- Auto-fix pattern matching (not ML)

### 2. Machine % Denominator is Wrong
The 88% "Machine Verified" badge uses incorrect math:
```
Current:  511 verified / 575 total = 88%
Problem:  123 items are marked automatable: false
Correct:  511 verified / 494 automatable = 103% (capped at 100%)
```

The current percentage includes items that **cannot** be machine-verified in the denominator, deflating the displayed coverage.

### 3. No Category Distinction
Items requiring human judgment are lumped with automatable items:
- "Error message clarity" - subjective
- "On a fresh system" - environmental
- "Requires GitLab repository" - external dependency
- "Visual confirmation needed" - interactive

## Current State (Detailed Analysis)

| Category | Count | Passed | Failed |
|----------|-------|--------|--------|
| **Automatable (True)** | 458 | 411 | **47** |
| **Not Automatable (False)** | 117 | 100* | 17 |
| **Total** | 575 | 511 | 64 |

*NOTE: 100 items marked "automatable: false" show "verified: true" - this is inconsistent data that should be cleaned up.

**Current Badge Calculation (Wrong):**
```
Machine Verified % = 511 / 575 = 88.9%
(Includes 100 non-automatable items in numerator!)
```

**Correct Automated Coverage:**
```
Automated % = 411 / 458 = 89.7%
(Only count actually automatable items)
```

**What's Blocking the 10% Gap?**
47 automatable items have FAILED their tests:
- `dev2stg` tests (10+ items) - require running site
- `lib_safe_ops` tests (4 items) - require test site
- `live_deployment` tests - require production config
- Various integration tests requiring specific conditions

These are real test failures that need investigation, not items that "can't be tested."

## Proposed Solution

### 1. Rename Verification Types

| Current (Misleading) | Proposed (Accurate) |
|---------------------|---------------------|
| AI-Powered Deep Verification | **Functional Verification** |
| AI Coverage | **Functional Coverage** |
| `--ai` flag | `--functional` flag (remove `--ai` completely) |
| Machine Verified | **Automated Tests** |
| Human Verified | **Manual Reviews** |

### 2. Simplify Item Categories

Reduce to two categories (simplest mental model - "can it run unattended?"):

| Category | Description | Count |
|----------|-------------|-------|
| **Automatable** | Script can verify without human intervention | 458 |
| **Human-Required** | Needs human judgment, external systems, or specific environments | 117 |

**Data Cleanup Required:**
100 items marked `automatable: false` have `verified: true` - this is inconsistent. These need:
1. Re-evaluation if they're actually automatable (change flag to true)
2. Or removal of `verified: true` if tests were incorrectly run on them

### 3. Fix Percentage Calculations

**Automated Coverage:**
```
verified_automatable / total_automatable = X%
(Only items that CAN be machine-verified in denominator)
```

**Manual Coverage:**
```
verified_human / total_human_required = Y%
(Only items that NEED human review in denominator)
```

**Overall/Fully Verified:**
```
both_verified / total_all = Z%
(All items, for overall progress)
```

### 4. Updated Badge Display

**Selected: 4 Badges (Functional before Manual)**
```
[Automated: 90%] [Functional: 15/17] [Manual: 8%] [Overall: 1%]
```

- **Automated**: 411/458 items with `automatable: true` that pass
- **Functional**: X/17 scenarios passing (P51 workflow tests)
- **Manual**: Human-verified items / human-required items
- **Overall**: Both machine AND human verified / total

### 5. Schema Updates

Add category field to `.verification.yml` items:
```yaml
machine:
  automatable: false
  category: human_required  # NEW: automatable|human_required|external_dependent|environment_specific
  reason: "Error message quality requires human judgment..."
```

Update `.badges.json` to v2:
```json
{
  "badges": {
    "automated_coverage": { "message": "100%", "detail": "494/494" },
    "manual_coverage": { "message": "8%", "detail": "8/95" },
    "functional_coverage": { "message": "88%", "detail": "15/17" }
  },
  "breakdown": {
    "by_category": {
      "automatable": { "total": 494, "verified": 494 },
      "human_required": { "total": 65, "verified": 8 }
    }
  }
}
```

## Implementation Plan

### Phase 1: Add Categories to Schema
1. Add `category` field to verification item schema
2. Create script to auto-categorize based on `reason` text patterns
3. Review and correct auto-categorization manually

### Phase 2: Fix Calculations
1. Update `count_total_items()` to return per-category counts
2. Update `count_machine_verified_items()` to only count automatable items
3. Update badge generation to use correct denominators

### Phase 3: Rename AI References
1. Replace `--ai` flag with `--functional` (remove --ai completely)
2. Update badge labels from "AI" to "Functional"
3. Update all documentation references
4. Rename P51 docs from "AI-Powered" to "Functional"

### Phase 4: Update Badges
1. Update `.badges.json` schema to v2
2. Update README.md badge URLs
3. Update `generate_badges_json()` function

### Phase 5: Documentation
1. Update P51 proposal docs with renamed terminology
2. Add "Understanding Verification Categories" guide
3. Update command reference docs

## Files to Modify

| File | Changes |
|------|---------|
| `scripts/commands/verify.sh` | Category counts, percentage fixes, --functional flag |
| `lib/verify-runner.sh` | Badge generation, color logic |
| `.verification.yml` | Add category field to all items |
| `lib/badges.sh` | Badge URL generation |
| `README.md` | Update badge names/URLs |
| `docs/proposals/P51-*.md` | Rename "AI" references |

## Verification

After implementation:
1. Run `pl verify badges` - should show corrected percentages
2. Run `pl verify --functional` - should work (--ai removed)
3. Run `pl verify --ai` - should error with "unknown flag"
4. Check `.badges.json` - should have v2 schema with breakdown
5. README badges should display accurate category-specific coverage:
   - Automated: ~90% (411/458)
   - Functional: X/17 scenarios
   - Manual: ~6% (7/117)
   - Overall: ~1% (7/575)
