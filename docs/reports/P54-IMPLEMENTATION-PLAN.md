# P54: Verification Test Infrastructure Fixes - Implementation Plan

**Created**: 2026-01-18
**Status**: PLANNED
**Related**: p54.md (root), P50 (machine verification), P51 (AI verification)

---

## Executive Summary

Analysis of p54.md revealed ~65 failing verification tests across 6 categories. Root cause: test-nwp.sh was deleted but verification tests still reference it, plus systemic issues with script sourcing, missing functions, and lack of test dependencies.

**Why This Wasn't Caught**:
1. No verification-script consistency checking
2. No evidence trail for AI/human continuity
3. P50 machine tests lack dependency sequencing (unlike P51 scenarios)

---

## Phased Implementation Plan

### Phase 1: Evidence Collection and Baseline

**Priority**: FIRST (enables all other phases)

| Step | Action | Output |
|------|--------|--------|
| 1.1 | Create `docs/history/P54-verification-fixes/` directory | Directory structure |
| 1.2 | Run `pl verify --run --depth=basic` | baseline-state.md |
| 1.3 | Map 22 test-nwp categories to P50/P51 | test-nwp-equivalents.md |
| 1.4 | Initialize change tracking | change-log.md |

**Deliverables**:
- `docs/history/P54-verification-fixes/baseline-state.md`
- `docs/history/P54-verification-fixes/test-nwp-equivalents.md`
- `docs/history/P54-verification-fixes/change-log.md`

---

### Phase 2: Remove test-nwp References (Category 1)

**Priority**: HIGH (6 tests failing with exit 127)

| Step | Action | File |
|------|--------|------|
| 2.1 | Verify equivalents exist in P50/P51 | (from Phase 1) |
| 2.2 | Remove `test_nwp:` section (lines 14219-14500+) | .verification.yml |
| 2.3 | Remove contribute.sh test-nwp references | .verification.yml |
| 2.4 | Verify removal | `grep -c "test-nwp" .verification.yml` → 0 |

**Tests Fixed**: 6

---

### Phase 3: Script Execution Guards (Category 2)

**Priority**: HIGH (~35 tests failing)

**Approach A - Add guards to scripts**:

| Step | Script | Pattern |
|------|--------|---------|
| 3.1 | schedule.sh | Add `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi` |
| 3.2 | security.sh | Same pattern |
| 3.3 | contribute.sh | Same pattern |
| 3.4 | coder-setup.sh | Same pattern |
| 3.5 | seo-check.sh | Same pattern |
| 3.6 | upstream.sh | Same pattern |
| 3.7 | security-check.sh | Same pattern |
| 3.8 | import.sh | Same pattern |
| 3.9 | setup-ssh.sh | Same pattern |
| 3.10 | report.sh | Same pattern |
| 3.11 | avc-moodle-setup.sh | Same pattern |
| 3.12 | avc-moodle-status.sh | Same pattern |
| 3.13 | avc-moodle-sync.sh | Same pattern |
| 3.14 | avc-moodle-test.sh | Same pattern |
| 3.15 | bootstrap-coder.sh | Same pattern |

**Approach B - Update verification tests**:

| Step | Action | File |
|------|--------|------|
| 3.16 | Change source tests to syntax checks | .verification.yml |

**Tests Fixed**: ~35

---

### Phase 4: Add Missing Git Functions (Category 3)

**Priority**: MEDIUM (9 tests failing)

| Step | Function | Implementation |
|------|----------|----------------|
| 4.1 | `git_add_all()` | `(cd "$1" && git add -A)` |
| 4.2 | `git_has_changes()` | `(cd "$1" && ! git diff --quiet HEAD)` |
| 4.3 | `git_get_current_branch()` | `(cd "$1" && git branch --show-current)` |

**File**: `lib/git.sh` (insert after line ~306)

**Tests Fixed**: 9

---

### Phase 5: coders.sh --collect Flag (Category 4)

**Priority**: MEDIUM (5 tests timing out)

| Step | Action | File |
|------|--------|------|
| 5.1 | Add `cmd_collect()` function | scripts/commands/coders.sh |
| 5.2 | Add case for `collect\|--collect` | scripts/commands/coders.sh |
| 5.3 | Output JSON with coders list | (machine-parseable) |
| 5.4 | Update verification tests | .verification.yml |

**Design**: JSON output with `{coders: [...], count: N, timestamp: "..."}` for machine verification.

**Tests Fixed**: 5

---

### Phase 6: Replace Grep-Based Tests (Category 5)

**Priority**: MEDIUM (6 tests failing)

| Step | Current Test | Replacement |
|------|--------------|-------------|
| 6.1 | `grep 'set_option' modify.sh` | `./modify.sh --help` functional test |
| 6.2 | `grep 'css.*aggregat' make.sh` | `./make.sh --help` functional test |
| 6.3 | `grep 'ufw\|fail2ban' produce.sh` | Remove (unimplemented feature) |
| 6.4 | `grep 'cache\|redis' produce.sh` | Remove (unimplemented feature) |
| 6.5 | `grep 'combined' test.sh` | `./test.sh --help` functional test |
| 6.6 | `grep 'missing.*depend' test.sh` | `./test.sh --help` functional test |

**Tests Fixed**: 6

---

### Phase 7: Test Dependency Sequencing (Category 6)

**Priority**: HIGH (8 tests failing, architectural improvement)

| Step | Action | File |
|------|--------|------|
| 7.1 | Add `depends_on` field support to schema | .verification.yml |
| 7.2 | Add `verify_deps_satisfied()` function | lib/verify-runner.sh |
| 7.3 | Add `verify_resolve_order()` function | lib/verify-runner.sh |
| 7.4 | Add `depends_on: [install]` to backup feature | .verification.yml |
| 7.5 | Add `depends_on: [install]` to restore feature | .verification.yml |
| 7.6 | Add `depends_on: [install]` to copy feature | .verification.yml |
| 7.7 | Add `requires_site` and `skip_if_missing` fields | .verification.yml |

**Pattern from P51** (`lib/verify-scenarios.sh`):
- Topological sort for execution order
- `is_gate` flag for blocking dependencies
- `scenario_deps_satisfied()` function

**Tests Fixed**: 8 (conditional skip with clear message)

---

### Phase 8: Process Improvement

**Priority**: HIGH (prevent recurrence)

| Step | Action | File |
|------|--------|------|
| 8.1 | Create pre-commit hook | .git/hooks/pre-commit.d/verify-consistency |
| 8.2 | Add verification maintenance rules | CLAUDE.md |
| 8.3 | Add CI verification job | .gitlab-ci.yml (if exists) |

**Hook Logic**:
```bash
# Check for deleted scripts still referenced in .verification.yml
for ref in $(grep -oE 'scripts/commands/[a-z-]+\.sh' .verification.yml | sort -u); do
    [[ ! -f "$ref" ]] && echo "ERROR: $ref referenced but missing" && exit 1
done
```

---

### Phase 9: Final Documentation and Verification

**Priority**: LAST (wraps up implementation)

| Step | Action | File |
|------|--------|------|
| 9.1 | Run full verification suite | `pl verify --run --depth=thorough` |
| 9.2 | Document final state | docs/history/P54-verification-fixes/verification-after.md |
| 9.3 | Move p54.md to proposals (fix P53→P54 label) | docs/proposals/P54-verification-test-fixes.md |
| 9.4 | Update CHANGELOG.md | CHANGELOG.md |

---

## Summary of Changes

### Files to Modify

| File | Changes |
|------|---------|
| `.verification.yml` | Remove test_nwp (6), update source tests (~35), update grep tests (6), add depends_on |
| `lib/git.sh` | Add 3 functions |
| `lib/verify-runner.sh` | Add dependency resolution |
| `scripts/commands/coders.sh` | Add --collect flag |
| 15 scripts in `scripts/commands/` | Add execution guards |
| `CLAUDE.md` | Add verification maintenance rules |

### Files to Create

| File | Purpose |
|------|---------|
| `docs/history/P54-verification-fixes/baseline-state.md` | Before state |
| `docs/history/P54-verification-fixes/test-nwp-equivalents.md` | Coverage mapping |
| `docs/history/P54-verification-fixes/change-log.md` | Running log |
| `docs/history/P54-verification-fixes/verification-after.md` | After state |
| `docs/proposals/P54-verification-test-fixes.md` | Final proposal |
| `.git/hooks/pre-commit.d/verify-consistency` | Prevention hook |

---

## Success Criteria

- [ ] Phase 1: Evidence trail established
- [ ] Phase 2: 0 test-nwp references in .verification.yml
- [ ] Phase 3: All 15 scripts have execution guards
- [ ] Phase 4: git_add_all, git_has_changes, git_get_current_branch exist and work
- [ ] Phase 5: coders.sh --collect returns valid JSON
- [ ] Phase 6: No grep-based tests for unimplemented features
- [ ] Phase 7: Dependency sequencing working for backup tests
- [ ] Phase 8: Pre-commit hook prevents orphaned tests
- [ ] Phase 9: `pl verify --run --depth=thorough` achieves 98%+ pass rate

---

## Test Count Summary

| Category | Tests | Status |
|----------|-------|--------|
| 1. test-nwp references | 6 | Remove |
| 2. Script sourcing | ~35 | Fix with guards + test updates |
| 3. Missing git functions | 9 | Add functions |
| 4. coders.sh TUI | 5 | Add --collect flag |
| 5. Grep-based detection | 6 | Replace with functional tests |
| 6. Running site needs | 8 | Add dependency sequencing |
| **Total** | **~69** | **Target: <5 remaining** |

---

## Verification Commands

```bash
# Phase 1: Baseline
pl verify --run --depth=basic 2>&1 | tee baseline.log
grep -c "FAIL" baseline.log

# After each phase
pl verify --run --depth=basic

# Final verification
pl verify --run --depth=thorough
pl verify badges

# Expected final result: 98%+ pass rate
```
