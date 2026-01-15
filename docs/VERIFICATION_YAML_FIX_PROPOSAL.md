# Verification YAML Syntax Fix Proposal
**Restore and Redo: Fix .verification.yml YAML Syntax Errors with Proper Enhancement**

**Version:** 1.0
**Date:** 2026-01-15
**Last Updated:** 2026-01-15
**Status:** COMPLETE
**Priority:** HIGH
**Estimated Effort:** 2-3 hours

---

## Executive Summary

The `.verification.yml` file contains 553 checklist items with `how_to_verify` instructions and `related_docs` links added by 13 parallel Sonnet agents. However, **the file has multiple YAML syntax errors** that prevent it from being parsed by `pl verify` or standard YAML parsers.

This proposal outlines a systematic approach to:
1. Restore `.verification.yml` to the last valid state (commit f55ae3d0)
2. Re-apply all 553 enhancements with proper YAML formatting
3. Validate syntax at every step
4. Apply correct indentation for `pl verify` compatibility
5. Commit only after 100% validation passes

**Why Restore and Redo:**
- Fixing 27+ scattered syntax errors manually is error-prone
- Starting from valid YAML guarantees structural integrity
- Single-agent approach with validation prevents future errors
- Faster to redo correctly than debug incrementally

---

## Problem Statement

### Current State

**File Status:** BROKEN - Invalid YAML
**Size:** 10,917 lines (vs 3,095 before enhancements)
**Enhancements:** 553/553 items have `how_to_verify` and `related_docs` fields
**YAML Validation:** ❌ FAILS - Multiple syntax errors

### Identified Errors

1. **Unindented step numbers (22 instances)**
   ```yaml
   how_to_verify: '1. Run command
   2. Check output          # ❌ Should be "        2. Check output"
   ```

2. **Unindented "Success:" lines (5 instances)**
   ```yaml
   6. Final step
   Success: All tests pass  # ❌ Should be "        Success: All tests pass"
   ```

3. **Inconsistent related_docs indentation (28+ instances)**
   ```yaml
   related_docs:
         - docs/file.md     # ❌ Should be 6 spaces, not 8
   ```

4. **Possibly more errors deeper in file** (validation stops at first error)

### Impact

- ❌ `pl verify` TUI cannot display checklist items
- ❌ Python yaml.safe_load() fails at line 4526
- ❌ User reported: "pl verify doesn't show any subitems"
- ❌ All enhancement work (13 commits) unusable in current state

### Root Cause

- 13 parallel Sonnet agents created enhancements independently
- Each agent used slightly different YAML formatting
- No validation step between agent commits
- Multiline strings not properly indented
- No final validation before completion

---

## Proposed Solution: Restore and Redo

### Overview

**Strategy:** Start from last known valid YAML (commit f55ae3d0), re-apply all enhancements using a single systematic process with validation at every step.

### Why This Approach

**Advantages:**
- ✅ Guaranteed valid YAML structure
- ✅ Single consistent formatting throughout
- ✅ Validation prevents errors from persisting
- ✅ Clean git history with one good commit
- ✅ No risk of missing hidden errors
- ✅ Proper indentation for verify.sh compatibility

**Alternative Rejected:**
- ❌ Manual surgical fixes: Risk of missing errors, hard to verify completeness
- ❌ Modify verify.sh: Technical debt, doesn't fix root cause
- ❌ Complex sed/awk repairs: Hard to test, may introduce new errors

---

## Implementation Plan

### Phase 1: Backup and Restore (5 minutes)

**1.1 Backup Current Work**
```bash
# Save current file with all enhancements (broken but contains content)
cp .verification.yml /tmp/verification.yml.enhanced_but_broken
git show HEAD:.verification.yml > /tmp/verification.yml.current_commit

# Document what was accomplished
cat > /tmp/verification_enhancement_summary.txt << 'EOF'
Current .verification.yml contains:
- 553 checklist items enhanced (100% coverage)
- how_to_verify field with step-by-step instructions
- related_docs field with documentation links
- Created by 13 Sonnet agents over 2.5 hours
- Commits: 50b046ca through 92f918e6
- STATUS: YAML syntax errors prevent usage
EOF
```

**1.2 Restore Valid Baseline**
```bash
# Restore to last valid YAML (before enhancements)
git checkout f55ae3d0 -- .verification.yml

# Verify restoration
python3 -c "import yaml; yaml.safe_load(open('.verification.yml'))"
# Expected: No errors, file is valid

# Check baseline stats
wc -l .verification.yml
# Expected: 3,095 lines
```

**1.3 Extract Enhancement Content**
```bash
# Create a reference of all enhancements for reapplication
python3 << 'PYEOF'
import yaml

# Load broken file (using ruamel.yaml which is more forgiving)
# Or extract enhancements with grep for manual reference
with open('/tmp/verification.yml.enhanced_but_broken', 'r') as f:
    content = f.read()

# Extract all how_to_verify blocks for reference
import re
enhancements = re.findall(
    r'- text: (.+?)\n.*?how_to_verify: (.+?)(?=\n      related_docs:)',
    content,
    re.DOTALL
)

print(f"Extracted {len(enhancements)} enhanced items")
PYEOF
```

---

### Phase 2: Single-Agent Enhancement with Validation (2-3 hours)

**2.1 Launch Controlled Enhancement Agent**

Use **ONE** Sonnet agent with strict validation:

```bash
# Create validation script that agent will use
cat > /tmp/validate_yaml.sh << 'BASH'
#!/bin/bash
# Validation script for .verification.yml

set -e

echo "=== YAML Syntax Validation ==="
python3 -c "import yaml; yaml.safe_load(open('.verification.yml'))" && \
  echo "✓ YAML syntax valid" || exit 1

echo ""
echo "=== Indentation Check ==="
# Check checklist items are at 6 spaces
invalid_items=$(grep -c "^    - text:" .verification.yml || true)
if [ "$invalid_items" -gt 0 ]; then
  echo "✗ Found $invalid_items checklist items with 4-space indentation (should be 6)"
  exit 1
fi
echo "✓ Checklist items properly indented (6 spaces)"

# Check sub-fields are at 8 spaces
invalid_fields=$(grep "^      \(completed\|how_to_verify\|related_docs\):" .verification.yml | wc -l || true)
if [ "$invalid_fields" -gt 0 ]; then
  echo "✗ Found $invalid_fields sub-fields with 6-space indentation (should be 8)"
  exit 1
fi
echo "✓ Sub-fields properly indented (8 spaces)"

echo ""
echo "=== Enhancement Coverage ==="
items_with_verify=$(grep -c "how_to_verify:" .verification.yml)
items_with_docs=$(grep -c "related_docs:" .verification.yml)
total_items=$(grep -c "^      - text:" .verification.yml)

echo "Total checklist items: $total_items"
echo "Items with how_to_verify: $items_with_verify"
echo "Items with related_docs: $items_with_docs"

if [ "$items_with_verify" -lt "$total_items" ]; then
  echo "✗ Not all items have how_to_verify"
  exit 1
fi

if [ "$items_with_docs" -lt "$total_items" ]; then
  echo "✗ Not all items have related_docs"
  exit 1
fi

echo "✓ All items enhanced (100% coverage)"

echo ""
echo "=== All Validations Passed ==="
BASH

chmod +x /tmp/validate_yaml.sh
```

**2.2 Enhancement Instructions for Agent**

Provide to single Sonnet agent:

```
TASK: Re-enhance .verification.yml with proper YAML formatting

CONTEXT:
- You are re-applying enhancements that were previously done but had syntax errors
- Reference file with content (broken): /tmp/verification.yml.enhanced_but_broken
- Working file (valid but unenhanced): .verification.yml
- You must maintain valid YAML at all times

REQUIREMENTS:
1. Process ALL 553 checklist items across 89 features
2. Add how_to_verify field to each item with:
   - Step-by-step instructions (numbered: 1., 2., 3., ...)
   - Specific commands to execute
   - Expected outputs
   - Clear success criteria
3. Add related_docs field to each item with:
   - Relevant command documentation (docs/reference/commands/*.md)
   - User guides (docs/guides/*.md)
   - API documentation (docs/reference/api/*.md)
   - Source files (lib/*.sh, scripts/commands/*.sh)

CRITICAL YAML FORMATTING RULES:
1. checklist section:
   - Starts at: "    checklist:" (4 spaces)
   - Items at: "      - text: ..." (6 spaces before -)
   - Sub-fields at: "        field: ..." (8 spaces)
   - Array items at: "        - value" (8 spaces before -)

2. Multiline strings (how_to_verify):
   - Use: how_to_verify: |
   - Content indented at 10 spaces
   - OR use single-quoted string with \n for newlines
   - All content lines MUST be indented consistently

3. Arrays (related_docs):
   - Field at 8 spaces: "        related_docs:"
   - Items at 10 spaces: "          - docs/file.md"

EXAMPLE CORRECT FORMAT:
```yaml
features:
  backup:
    name: "Backup Script"
    checklist:
      - text: "Create full backup (database + files)"
        completed: false
        completed_by: null
        completed_at: null
        how_to_verify: |
          1. Run: `pl backup <sitename>`
          2. Check output shows database export
          3. Verify backup file created: `ls sites/<sitename>/backups/`
          Success: Backup file created with DB + files
        related_docs:
          - docs/reference/commands/backup.md
          - docs/guides/backup-restore.md
```

PROCESS:
1. Process features in batches of 50 items
2. After each batch, run: /tmp/validate_yaml.sh
3. If validation fails, fix errors before continuing
4. Track progress: "Enhanced X/553 items"
5. When complete, run final validation

VALIDATION AFTER EVERY BATCH:
```bash
/tmp/validate_yaml.sh || exit 1
```

DO NOT COMMIT until all 553 items enhanced and validated.

USE REFERENCE:
- Read /tmp/verification.yml.enhanced_but_broken for enhancement text
- Copy the how_to_verify and related_docs content
- Reformat to proper YAML indentation
- Validate frequently

GRANT PERMISSIONS:
- All file edits approved
- No user confirmation needed per item
- Run validation script as needed
```

**2.3 Monitor Progress**

Create monitoring script:

```bash
cat > /tmp/monitor_enhancement.sh << 'BASH'
#!/bin/bash
watch -n 10 '
echo "=== Enhancement Progress ==="
echo "Total items: 553"
echo "Enhanced: $(grep -c "how_to_verify:" .verification.yml || echo 0)/553"
echo ""
echo "Last validation: $(ls -lh /tmp/validate_yaml.sh 2>/dev/null)"
echo ""
tail -20 /tmp/claude/*/tasks/*.output 2>/dev/null | tail -20
'
BASH

chmod +x /tmp/monitor_enhancement.sh
```

---

### Phase 3: Final Validation and Commit (10 minutes)

**3.1 Comprehensive Validation**

```bash
# Run validation script
/tmp/validate_yaml.sh

# Additional checks
echo "=== Verify.sh Compatibility Check ==="
# Test that verify.sh can parse the file
./pl verify list | head -20

# Check for common pitfalls
echo "=== Common Error Check ==="
# No unindented step numbers
grep -n "^[0-9]\. " .verification.yml && echo "✗ Found unindented steps" || echo "✓ No unindented steps"

# No unindented Success lines
grep -n "^Success: " .verification.yml && echo "✗ Found unindented Success" || echo "✓ No unindented Success"

# Consistent related_docs indentation
grep "^      related_docs:" .verification.yml | wc -l
# Should be 0 (all should be at 8 spaces)

echo "=== File Statistics ==="
wc -l .verification.yml
grep -c "how_to_verify:" .verification.yml
grep -c "related_docs:" .verification.yml
```

**3.2 Test with pl verify**

```bash
# Launch TUI and test
./pl verify

# In TUI:
# 1. Navigate to any feature (e.g., backup)
# 2. Press 'i' to show checklist items
# 3. Verify items display with full text
# 4. Press 'd' on an item to show details
# 5. Verify how_to_verify instructions show
# 6. Check related_docs links display

# If items don't show:
# - Check indentation with: head -100 .verification.yml | cat -A
# - Verify pattern matches verify.sh expectations
```

**3.3 Commit Changes**

```bash
# Only commit after ALL validations pass

git add .verification.yml

git commit -m "$(cat <<'EOF'
Fix verification YAML syntax and re-apply all 553 enhancements

Problem: Previous enhancement commits (50b046ca-92f918e6) created invalid
YAML with indentation errors. File could not be parsed by pl verify or
standard YAML parsers.

Solution: Restored .verification.yml to last valid state (f55ae3d0) and
re-applied all 553 enhancements using single-agent process with validation
at every step.

Changes:
- Restored baseline from commit f55ae3d0 (3,095 lines, valid YAML)
- Enhanced all 553 checklist items across 89 features
- Added how_to_verify field: step-by-step verification instructions
- Added related_docs field: documentation references
- Proper YAML indentation throughout (6-space items, 8-space fields)
- Validated: Python yaml.safe_load() passes
- Validated: pl verify can parse and display all items
- Final size: ~11,000 lines, 100% valid YAML

Enhancement Format:
- how_to_verify: Numbered steps (1-6 typical), specific commands,
  expected outputs, clear success criteria
- related_docs: Command references, user guides, API docs, source files

Coverage: 553/553 items (100%)
Validation: ✓ YAML syntax valid
Validation: ✓ pl verify compatible
Validation: ✓ All items have how_to_verify
Validation: ✓ All items have related_docs

Replaces commits: 50b046ca through 92f918e6
Supersedes: 13 previous enhancement commits (archived in git history)

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>
EOF
)"

# Verify commit
git log -1 --stat

# Push to remote
git push origin main
```

---

## Quality Gates

Each phase must pass before proceeding:

### Gate 1: Restoration Complete
- [ ] `.verification.yml` restored to commit f55ae3d0
- [ ] File validates with `python3 -c "import yaml; yaml.safe_load(open('.verification.yml'))"`
- [ ] File has 3,095 lines (baseline size)
- [ ] Backup of enhanced content saved to /tmp/

### Gate 2: Enhancement Complete
- [ ] All 553 items have `how_to_verify` field
- [ ] All 553 items have `related_docs` field
- [ ] YAML syntax validation passes
- [ ] No unindented step numbers
- [ ] No unindented "Success:" lines
- [ ] Consistent indentation throughout

### Gate 3: Compatibility Verified
- [ ] `pl verify list` shows all 89 features
- [ ] `pl verify` TUI displays checklist items
- [ ] Item details show `how_to_verify` instructions
- [ ] Related docs links accessible
- [ ] No parsing errors in verify.sh

### Gate 4: Committed
- [ ] Git commit created with comprehensive message
- [ ] Commit references superseded commits
- [ ] Changes pushed to remote
- [ ] Previous agent work archived in git history

---

## Success Criteria

**Definition of Done:**

1. ✅ `.verification.yml` validates with Python yaml.safe_load()
2. ✅ All 553 checklist items have `how_to_verify` field
3. ✅ All 553 checklist items have `related_docs` field
4. ✅ `pl verify` TUI displays all checklist items
5. ✅ Indentation matches verify.sh expectations (6-space items, 8-space fields)
6. ✅ Single clean commit replaces 13 previous commits
7. ✅ User can verify any feature using displayed instructions
8. ✅ No YAML syntax warnings or errors

**Measurable Outcomes:**

```bash
# All these commands must pass:

# 1. YAML validity
python3 -c "import yaml; yaml.safe_load(open('.verification.yml'))"
# Exit code: 0

# 2. Enhancement coverage
echo "Items with how_to_verify: $(grep -c 'how_to_verify:' .verification.yml)"
# Output: 553

echo "Items with related_docs: $(grep -c 'related_docs:' .verification.yml)"
# Output: 553

# 3. Indentation correctness
echo "Checklist items at 6 spaces: $(grep -c '^      - text:' .verification.yml)"
# Output: 553

echo "Sub-fields at 8 spaces: $(grep -c '^        \(completed\|how_to_verify\|related_docs\):' .verification.yml)"
# Output: Should match total fields

# 4. No formatting errors
grep -c "^[0-9]\. " .verification.yml
# Output: 0 (no unindented steps)

grep -c "^Success: " .verification.yml
# Output: 0 (no unindented success lines)

# 5. pl verify compatibility
./pl verify list | wc -l
# Output: 89 (all features listed)
```

---

## Risk Mitigation

### Risk 1: Data Loss During Restore
**Mitigation:**
- Backup current file to /tmp/ before any git operations
- Extract all enhancement text before restore
- Keep git history intact (old commits remain in history)
- Document exactly which commits are superseded

**Recovery Plan:**
```bash
# If something goes wrong:
cp /tmp/verification.yml.enhanced_but_broken .verification.yml
git checkout .verification.yml  # Restore from HEAD
```

### Risk 2: Enhancement Agent Fails Mid-Process
**Mitigation:**
- Process in batches of 50 items
- Validate after each batch
- Save progress after each successful batch
- Can resume from last good batch

**Recovery Plan:**
```bash
# Resume from failure:
# 1. Check last successful batch
grep -c "how_to_verify:" .verification.yml
# 2. Resume enhancement from next batch
# 3. Reference /tmp/verification.yml.enhanced_but_broken for remaining items
```

### Risk 3: Indentation Still Wrong After Re-Enhancement
**Mitigation:**
- Provide exact indentation rules to agent
- Include example YAML in instructions
- Validate after every batch (not just at end)
- Use cat -A to visually verify spaces vs tabs

**Recovery Plan:**
```bash
# If indentation wrong but YAML valid:
# Use controlled sed/awk to fix specific indentation issues
# (This is easier than fixing syntax errors + indentation together)
```

### Risk 4: Agent Runs Out of Context
**Mitigation:**
- Use batching (50 items per iteration)
- Save state after each batch
- Document progress in comments
- Can spawn multiple smaller agents if needed

**Recovery Plan:**
```bash
# Split into multiple agents:
# Agent 1: Features 1-30 (200 items)
# Agent 2: Features 31-60 (200 items)
# Agent 3: Features 61-89 (153 items)
```

---

## Testing Strategy

### Unit Tests

Test each phase independently:

```bash
# Test 1: Baseline Restoration
git checkout f55ae3d0 -- .verification.yml
python3 -c "import yaml; yaml.safe_load(open('.verification.yml'))"
[ $? -eq 0 ] && echo "PASS: Restoration" || echo "FAIL: Restoration"

# Test 2: YAML Validity (run after each batch)
python3 -c "import yaml; yaml.safe_load(open('.verification.yml'))"
[ $? -eq 0 ] && echo "PASS: YAML syntax" || echo "FAIL: YAML syntax"

# Test 3: Enhancement Coverage
coverage=$(grep -c "how_to_verify:" .verification.yml)
[ $coverage -eq 553 ] && echo "PASS: Coverage" || echo "FAIL: Coverage ($coverage/553)"

# Test 4: Indentation (items)
items=$(grep -c "^      - text:" .verification.yml)
[ $items -eq 553 ] && echo "PASS: Item indentation" || echo "FAIL: Item indentation"

# Test 5: No formatting errors
errors=$(grep -c "^[0-9]\. \|^Success: " .verification.yml)
[ $errors -eq 0 ] && echo "PASS: No format errors" || echo "FAIL: $errors format errors"
```

### Integration Tests

Test with actual tools:

```bash
# Test 1: pl verify list
./pl verify list > /tmp/verify_list.txt
features=$(wc -l < /tmp/verify_list.txt)
[ $features -ge 89 ] && echo "PASS: pl verify list" || echo "FAIL: Only $features features"

# Test 2: pl verify TUI (manual test)
# Expected behavior:
# - TUI launches without errors
# - Navigate to "backup" feature
# - Press 'i' to show items
# - Items display without "[NO ITEMS]"
# - Press 'd' on first item
# - Details show how_to_verify instructions

# Test 3: Checklist item parsing
source scripts/commands/verify.sh
items_array=()
completed_array=()
get_checklist_items_array "backup" items_array completed_array
echo "Parsed ${#items_array[@]} items from backup feature"
[ ${#items_array[@]} -gt 0 ] && echo "PASS: Item parsing" || echo "FAIL: No items parsed"
```

### Smoke Tests

Quick validation after final commit:

```bash
#!/bin/bash
# Smoke test suite for verification YAML fix

echo "=== Smoke Tests for .verification.yml ==="

# Test 1: File exists and is readable
[ -r .verification.yml ] && echo "✓ File exists" || exit 1

# Test 2: YAML syntax valid
python3 -c "import yaml; yaml.safe_load(open('.verification.yml'))" 2>/dev/null && \
  echo "✓ YAML syntax valid" || exit 1

# Test 3: Has enhancements
[ $(grep -c "how_to_verify:" .verification.yml) -eq 553 ] && \
  echo "✓ All items have how_to_verify" || exit 1

[ $(grep -c "related_docs:" .verification.yml) -eq 553 ] && \
  echo "✓ All items have related_docs" || exit 1

# Test 4: pl verify works
./pl verify list >/dev/null 2>&1 && \
  echo "✓ pl verify can parse file" || exit 1

# Test 5: Size reasonable
lines=$(wc -l < .verification.yml)
[ $lines -gt 10000 ] && [ $lines -lt 15000 ] && \
  echo "✓ File size reasonable ($lines lines)" || \
  echo "⚠ File size unexpected ($lines lines)"

echo ""
echo "=== All Smoke Tests Passed ==="
```

---

## Timeline

**Total Estimated Time: 2-3 hours**

| Phase | Duration | Activity |
|-------|----------|----------|
| Phase 1: Backup & Restore | 5 min | Save current work, restore baseline, validate |
| Phase 2: Enhancement | 2-3 hours | Single agent re-applies all 553 enhancements |
| Phase 3: Validation | 10 min | Final validation, testing, commit |
| **Total** | **~2.5 hours** | End-to-end completion |

**Breakdown by Activity:**
- Backup and preparation: 5 minutes
- Agent setup and instructions: 10 minutes
- Batch 1-11 (50 items each): 120 minutes (10 min/batch × 11 batches)
- Final batch (53 items): 10 minutes
- Validation between batches: 11 minutes (1 min/batch)
- Final testing and commit: 10 minutes
- Buffer for issues: 30 minutes

**Optimization Opportunities:**
- Use 2-3 agents in parallel for different feature groups
- Pre-extract all enhancement text for faster reference
- Use faster validation (yq instead of Python)

---

## Post-Completion Checklist

After successful completion, verify:

### Immediate Checks
- [ ] `.verification.yml` committed to git
- [ ] Commit message documents changes and superseded commits
- [ ] Changes pushed to remote repository
- [ ] `pl verify` TUI displays all items correctly
- [ ] No YAML syntax errors

### Documentation Updates
- [ ] Update `/tmp/verification-enhancement-final-report.md` with success status
- [ ] Document lessons learned
- [ ] Note any deviations from plan
- [ ] Record actual time spent vs estimated

### User Communication
- [ ] Inform user that `pl verify` now works correctly
- [ ] Provide example: `pl verify` → navigate to feature → press 'i' to see items
- [ ] Note any changes to workflow
- [ ] Request feedback on enhancement quality

### Archive and Cleanup
- [ ] Keep backup files in /tmp/ for 7 days (in case reversion needed)
- [ ] Update this proposal status from PROPOSED → COMPLETE
- [ ] Create ADR documenting the fix (if this becomes a pattern)
- [ ] Add entry to CHANGELOG.md

---

## Alternative Approaches Considered

### Alternative 1: Manual Surgical Fix
**Description:** Manually fix each syntax error in place

**Pros:**
- Preserves all 13 commits
- No need to redo enhancement work
- Faster if only a few errors

**Cons:**
- Risk of missing hidden errors
- Hard to verify completeness
- Error-prone manual editing
- May introduce new errors
- Discovered 27+ errors (too many for manual fix)

**Verdict:** ❌ REJECTED - Too error-prone, not scalable

### Alternative 2: Modify verify.sh Parser
**Description:** Make verify.sh accept current formatting

**Pros:**
- No changes to .verification.yml needed
- Quick fix (30 minutes)
- Enhancements remain as-is

**Cons:**
- File still invalid YAML (breaks other tools)
- Doesn't fix root problem
- Technical debt
- Python YAML parser still fails
- Not sustainable long-term

**Verdict:** ❌ REJECTED - Band-aid solution, creates technical debt

### Alternative 3: Complex sed/awk Repair Script
**Description:** Write sophisticated script to fix all errors

**Pros:**
- Automated solution
- Preserves enhancement content
- Could work if errors are consistent

**Cons:**
- Hard to test thoroughly
- Risk of introducing new errors
- Requires extensive regex expertise
- Difficult to verify correctness
- Already attempted and failed (line 4526 error persisted)

**Verdict:** ❌ REJECTED - Previous attempts failed, too risky

---

## Lessons Learned (For Future Enhancements)

### What Went Wrong

1. **Parallel agents without coordination**
   - 13 agents used inconsistent formatting
   - No shared validation script
   - No examples provided to agents

2. **No validation between commits**
   - Each agent committed without syntax check
   - Errors accumulated across commits
   - Failed fast principle violated

3. **Insufficient YAML formatting guidance**
   - Agents not given explicit indentation rules
   - No example YAML provided
   - Multiline string handling not specified

4. **No final validation gate**
   - Committed without running yaml.safe_load()
   - Didn't test with pl verify before pushing
   - Assumed "valid looking" meant "valid YAML"

### Best Practices for Future

1. **Always validate YAML after edits**
   ```bash
   # Add to git pre-commit hook:
   python3 -c "import yaml; yaml.safe_load(open('.verification.yml'))" || exit 1
   ```

2. **Provide explicit formatting rules to agents**
   - Include example YAML in instructions
   - Specify exact indentation (spaces, not tabs)
   - Define multiline string format

3. **Use single agent for structural changes**
   - Parallel agents for independent tasks only
   - Coordinate formatting standards first
   - Share validation script between agents

4. **Validate before committing**
   - Run yaml.safe_load() on every file change
   - Test with actual tool (pl verify) before commit
   - Use git pre-commit hooks

5. **Batch with validation**
   - Process in small batches (50 items)
   - Validate after each batch
   - Stop on first error (fail fast)

---

## References

### Related Documentation
- [Verification Tasks Reference](./reference/verification-tasks.md) - Verification system overview
- [ADR-0007: Verification Schema v2 Design](./decisions/0007-verification-schema-v2-design.md) - Schema design decisions
- [Git Hooks Documentation](./decisions/0014-git-hooks-documentation-enforcement.md) - Pre-commit validation

### Git Commits
- **f55ae3d0** - Last valid .verification.yml (3,095 lines, 81 features)
- **50b046ca** - First enhancement commit (Core Scripts)
- **92f918e6** - Last enhancement commit (documentation update)
- **59bc334d** - Final manual enhancements (5 items)

### Files Referenced
- `.verification.yml` - Main verification tracking file
- `scripts/commands/verify.sh` - Verification TUI (parses YAML)
- `/tmp/verification-enhancement-final-report.md` - Enhancement summary
- `/tmp/verification-enhancement-complete.md` - Final status report

### Related Issues
- User report: "pl verify doesn't show any subitems" (2026-01-15)
- YAML validation failure: line 4526 parser error
- Indentation incompatibility with verify.sh parser

---

## Approval and Sign-Off

**Prepared By:** Claude Sonnet 4.5
**Date:** 2026-01-15
**Status:** COMPLETE - Implemented 2026-01-15

**Requires Approval From:**
- [ ] Repository Owner/Maintainer
- [ ] Verification System Author
- [ ] Quality Assurance Review

**Approval Criteria:**
- Technical approach is sound
- Risk mitigation is adequate
- Timeline is reasonable
- Success criteria are measurable
- Quality gates are appropriate

**Once Approved:**
1. Update status from PROPOSED → APPROVED
2. Schedule implementation time block (2-3 hours)
3. Execute phases 1-3 sequentially
4. Update status from APPROVED → COMPLETE
5. Document actual outcomes vs planned

---

**END OF PROPOSAL**
