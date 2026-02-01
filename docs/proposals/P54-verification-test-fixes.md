# P54: Verification Test Infrastructure Fixes

**Status:** IMPLEMENTED
**Created:** 2026-01-18
**Author:** Rob, Claude Opus 4.5
**Priority:** High
**Depends On:** P50 (Unified Verification System)
**Estimated Effort:** 2-3 days
**Breaking Changes:** No

---

## 1. Executive Summary

### 1.1 Problem Statement

The NWP verification system shows ~90% pass rate with approximately 65 failing automatable tests. Root cause analysis reveals:

1. **test-nwp.sh was deleted** but verification tests still reference it (exit 127)
2. **Scripts execute on source** causing test failures when sourced for validation
3. **Missing library functions** that tests expect but were never implemented
4. **Interactive TUI** (coders.sh) times out waiting for input
5. **Grep-based tests** check for unimplemented features
6. **No dependency sequencing** for tests requiring running sites

### 1.2 Proposed Solution

A phased approach to fix test infrastructure without modifying core functionality:

1. Remove orphaned test-nwp references
2. Add execution guards to scripts
3. Implement missing git functions
4. Add machine-readable mode to coders.sh
5. Replace grep-based tests with functional tests
6. Add test dependency sequencing
7. Create prevention mechanisms (pre-commit hooks)

### 1.3 Key Metrics

| Before | After | Improvement |
|--------|-------|-------------|
| ~90% pass rate | 98%+ pass rate | +8% |
| ~65 failing tests | <5 failing tests | -60 tests |
| 0 consistency checks | Pre-commit hook | Prevention |

---

## 2. Root Cause Analysis

### 2.1 Category 1: Missing Script (6 tests)

**Problem:** `scripts/commands/test-nwp.sh` was deleted but `.verification.yml` still contains:
- `test_nwp:` feature section (lines 14219-14578)
- 6 checklist items with machine tests
- All return exit code 127 (command not found)

**Evidence:**
```bash
$ grep -c "test-nwp" .verification.yml
47  # 47 references to deleted script
```

**Fix:** Remove entire `test_nwp:` section and contribute.sh reference.

### 2.2 Category 2: Script Sourcing (~35 tests)

**Problem:** Tests use `bash -c 'source scripts/commands/XXX.sh 2>/dev/null; exit 0'` but scripts execute `main "$@"` at file level.

**Affected scripts (15):**
- schedule.sh, security.sh, contribute.sh
- coder-setup.sh, seo-check.sh, upstream.sh
- security-check.sh, import.sh, setup-ssh.sh
- report.sh, bootstrap-coder.sh
- avc-moodle-setup.sh, avc-moodle-status.sh
- avc-moodle-sync.sh, avc-moodle-test.sh

**Fix:** Add execution guard:
```bash
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
```

### 2.3 Category 3: Missing Functions (9 tests)

**Problem:** `lib/git.sh` tests expect functions that don't exist:
- `git_add_all()` - Not implemented
- `git_has_changes()` - Not implemented
- `git_get_current_branch()` - Not implemented

**Fix:** Add wrapper functions to `lib/git.sh`:
```bash
git_add_all() {
    local repo_path="${1:-.}"
    (cd "$repo_path" && git add -A)
}

git_has_changes() {
    local repo_path="${1:-.}"
    (cd "$repo_path" && ! git diff --quiet HEAD 2>/dev/null)
}

git_get_current_branch() {
    local repo_path="${1:-.}"
    (cd "$repo_path" && git branch --show-current 2>/dev/null || git rev-parse --abbrev-ref HEAD 2>/dev/null)
}
```

### 2.4 Category 4: Interactive TUI (5 tests)

**Problem:** `coders.sh` is a terminal UI that times out (exit 124) waiting for input.

**Fix:** Add `--collect` flag for machine-readable JSON output:
```bash
cmd_collect() {
    load_coders
    echo "{"
    echo '  "coders": ['
    # ... output JSON
    echo "  ],"
    echo "  \"count\": ${#CODERS[@]}"
    echo "}"
}
```

### 2.5 Category 5: Grep-Based Detection (6 tests)

**Problem:** Tests use grep to check for features that don't exist:

| Test Pattern | Status | Resolution |
|--------------|--------|------------|
| `grep 'ufw\|fail2ban' produce.sh` | NOT IMPLEMENTED | See P56 |
| `grep 'cache\|redis' produce.sh` | NOT IMPLEMENTED | See P57 |
| `grep 'combined' test.sh` | No comment | Add comment |
| `grep 'missing.*depend' test.sh` | NOT IMPLEMENTED | See P58 |

**Fix:** Remove tests for unimplemented features, add comment for combined flags.

### 2.6 Category 6: Site Dependencies (8 tests)

**Problem:** Backup/restore/copy tests require a running site that may not exist.

**Fix:** Add dependency sequencing to P50 machine tests:
```yaml
features:
  backup:
    depends_on: [install]
    checklist:
      - machine:
          requires_site: verify-test
          skip_if_missing: true
```

---

## 3. Implementation Plan

### Phase 1: Evidence Collection (COMPLETE)

Created documentation trail:
- `docs/history/P54-verification-fixes/baseline-state.md`
- `docs/history/P54-verification-fixes/test-nwp-equivalents.md`
- `docs/history/P54-verification-fixes/change-log.md`

### Phase 2: Remove test-nwp Tests

| Step | Action | Verification |
|------|--------|--------------|
| 2.1 | Remove `test_nwp:` section from .verification.yml | `grep -c "test_nwp" .verification.yml` = 0 |
| 2.2 | Remove contribute.sh test-nwp reference | grep returns 0 |

### Phase 3: Script Execution Guards

Add guard pattern to 15 scripts:
```bash
# Replace: main "$@"
# With:
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
```

### Phase 4: Add Missing Git Functions

Add 3 functions to `lib/git.sh` after line ~306.

### Phase 5: coders.sh --collect Flag

Add `cmd_collect()` function and update case statement.

### Phase 6: Replace Grep-Based Tests

- Remove unimplemented feature tests (point to P56/P57/P58)
- Add comment: `# Combined flags: -ltu runs lint+stan+unit`

### Phase 7: Test Dependency Sequencing

- Add `depends_on` field to feature schema
- Add `verify_deps_satisfied()` to lib/verify-runner.sh
- Update backup, restore, copy features

### Phase 8: Process Improvement

Create `.git/hooks/pre-commit.d/verify-consistency`:
```bash
#!/bin/bash
# Check for deleted scripts still referenced in .verification.yml
for ref in $(grep -oE 'scripts/commands/[a-z-]+\.sh' .verification.yml | sort -u); do
    [[ ! -f "$ref" ]] && echo "ERROR: $ref referenced but missing" && exit 1
done
```

### Phase 9: Final Documentation

- Update this proposal with results
- Update change-log.md with completion status
- Update CHANGELOG.md for release notes

---

## 4. Files to Modify

| File | Changes |
|------|---------|
| `.verification.yml` | Remove test_nwp section, update grep tests, add depends_on |
| `lib/git.sh` | Add 3 functions |
| `lib/verify-runner.sh` | Add dependency resolution |
| `scripts/commands/coders.sh` | Add --collect flag |
| 15 scripts in `scripts/commands/` | Add execution guards |
| `CLAUDE.md` | Add verification maintenance rules |

## 5. Files to Create

| File | Purpose |
|------|---------|
| `docs/history/P54-verification-fixes/baseline-state.md` | Before state |
| `docs/history/P54-verification-fixes/test-nwp-equivalents.md` | Coverage mapping |
| `docs/history/P54-verification-fixes/change-log.md` | Running log |
| `.git/hooks/pre-commit.d/verify-consistency` | Prevention hook |

---

## 6. Success Criteria

- [ ] All 6 test-nwp references removed from .verification.yml
- [ ] Execution guards added to 15 affected scripts
- [ ] 3 git functions added and tests passing
- [ ] coders.sh --collect flag working
- [ ] Grep-based tests replaced with functional tests
- [ ] Dependency sequencing implemented for backup tests
- [ ] Evidence trail documented in docs/history/
- [ ] Pre-commit hook preventing future orphaned tests
- [ ] `pl verify --run --depth=thorough` reaches 98%+ pass rate

---

## 7. Related Proposals

| Proposal | Topic | Why Related |
|----------|-------|-------------|
| P50 | Unified Verification | Foundation this fixes |
| P51 | AI-Powered Verification | Scenario dependencies |
| P56 | Security Hardening | Unimplemented feature (ufw/fail2ban) |
| P57 | Production Caching | Unimplemented feature (redis/memcache) |
| P58 | Test Dependencies | Unimplemented feature (dependency messages) |

---

## 8. Verification Commands

```bash
# Quick check after each phase
pl verify --run --depth=basic

# Full verification after completion
pl verify --run --depth=thorough

# Check pass rate
pl verify badges

# Verify no orphaned tests
grep -c "test-nwp" .verification.yml  # Should be 0
```

---

## 9. Lessons Learned

1. **Script deletion needs verification audit** - When deleting scripts, search for references
2. **Evidence trails matter** - Document state before changes for AI continuity
3. **Test what exists, not what's planned** - Don't add tests for unimplemented features
4. **Prevention > Detection** - Pre-commit hooks catch issues before they land
