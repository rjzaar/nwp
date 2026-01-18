# P54 Baseline State

**Captured**: 2026-01-18
**Purpose**: Document verification state before P54 fixes

---

## Summary

The NWP verification system shows 97% pass rate with 14 failing automatable tests across 4 categories.

## Verification Statistics (Pre-Fix)

| Metric | Value |
|--------|-------|
| Total Items | 575 |
| Tests Run | 524 |
| Passed | 510 |
| Failed | 14 |
| Pass Rate | 97% |

## Specific Failures

```
Failed Items:
  - produce:2              # grep test for ufw/fail2ban
  - produce:3              # grep test for cache/redis
  - test_nwp:0             # deleted script
  - test_nwp:1             # deleted script
  - test_nwp:2             # deleted script
  - test_nwp:3             # deleted script
  - test_nwp:4             # deleted script
  - test_nwp:5             # deleted script
  - lib_git:4              # missing git function
  - security_validation:2  # backtick rejection
  - security_validation:3  # pipe rejection
  - security_validation:5  # security validation
  - security_validation:15 # security validation
  - security_validation:17 # security validation
```

Log file: `/home/rob/nwp/.logs/verification/verify-20260118-190436.log`

## Failure Categories (Actual)

| Category | Count | Items | Root Cause |
|----------|-------|-------|------------|
| 1. Missing script (test-nwp.sh) | 6 | test_nwp:0-5 | Script deleted but tests remain |
| 2. Grep-based detection | 2 | produce:2,3 | Tests check for unimplemented features |
| 3. Missing library function | 1 | lib_git:4 | Function expected but not implemented |
| 4. Security validation | 5 | security_validation:2,3,5,15,17 | Security input validation tests |

## Key Findings

### Category 1: test-nwp.sh Deleted

The `scripts/commands/test-nwp.sh` script was deleted at some point, but 6 verification tests in `.verification.yml` still reference it:
- Line 14219+: `test_nwp:` section with 6 checklist items
- Each item has `bash -n scripts/commands/test-nwp.sh` checks
- All return exit code 127 (command not found)

### Category 2: Script Sourcing

Tests use pattern: `bash -c 'source scripts/commands/XXX.sh 2>/dev/null; exit 0'`

These scripts execute `main "$@"` at file level, causing:
- Immediate execution when sourced
- Help messages printed
- Exit before test can complete

Affected scripts (15):
- schedule.sh, security.sh, contribute.sh
- coder-setup.sh, seo-check.sh, upstream.sh
- security-check.sh, import.sh, setup-ssh.sh
- report.sh, bootstrap-coder.sh
- avc-moodle-setup.sh, avc-moodle-status.sh
- avc-moodle-sync.sh, avc-moodle-test.sh

### Category 3: Missing Git Functions

`lib/git.sh` tests expect functions that don't exist:
- `git_add_all()` - Not implemented
- `git_has_changes()` - Not implemented
- `git_get_current_branch()` - Not implemented

### Category 4: Interactive TUI

`coders.sh` is a terminal UI application:
- Uses `gum` for interactive menus
- Times out (exit 124) waiting for user input
- No `--collect` or machine-readable mode exists

### Category 5: Unimplemented Features

Grep-based tests check for features that don't exist:

| Test | Expected | Actual |
|------|----------|--------|
| `grep 'ufw\|fail2ban' produce.sh` | Security hardening | NOT IMPLEMENTED |
| `grep 'cache\|redis' produce.sh` | Caching system | NOT IMPLEMENTED |
| `grep 'combined' test.sh` | Combined flags docs | No comment exists |
| `grep 'missing.*depend' test.sh` | Dependency messages | NOT IMPLEMENTED |

### Category 6: Site Dependencies

Backup/restore/copy tests require a running site `verify-test`:
- `pl backup verify-test --sanitize basic -f`
- `ddev describe 2>&1 | grep -qiE 'running|stopped'`
- Site may not exist in all environments

## Why This Wasn't Caught

1. **No verification-script consistency check** - Deleted scripts leave orphaned tests
2. **No evidence trail** - Changes lack documentation for AI/human continuity
3. **P50 machine tests lack dependency sequencing** - Unlike P51 scenarios which have `depends_on`

## Files to Reference

- `/home/rob/nwp/p54.md` - Original root cause analysis
- `/home/rob/nwp/docs/P54-IMPLEMENTATION-PLAN.md` - Detailed fix plan
- `/home/rob/nwp/.verification.yml` - Verification definition file

---

## Expected State After P54

| Metric | Before | Target |
|--------|--------|--------|
| Pass Rate | 97% | 99%+ |
| Failing Tests | 14 | <5 |
| test-nwp References | 6 | 0 |

### Fixes by Category

| Category | Tests | Fix |
|----------|-------|-----|
| test_nwp:0-5 | 6 | Remove section from .verification.yml |
| produce:2,3 | 2 | Remove (feature not implemented, see P56/P57) |
| lib_git:4 | 1 | Add missing function to lib/git.sh |
| security_validation | 5 | Investigate - may be legitimate test issues |

After implementation, run:
```bash
pl verify --run --depth=thorough
pl verify badges
```
