# test-nwp.sh to P50/P51 Equivalents Mapping

**Created**: 2026-01-18
**Purpose**: Map deleted test-nwp.sh categories to existing P50/P51 verification coverage

---

## Background

The `scripts/commands/test-nwp.sh` script was deleted but `.verification.yml` still contains the `test_nwp:` feature section with 6 checklist items referencing it. This document maps the intended test coverage to equivalent verification in the current system.

## Original test-nwp Categories (from verification.yml)

The `test_nwp:` section describes a "Comprehensive test suite - 22 test categories":

| # | Checklist Item | What It Tested |
|---|----------------|----------------|
| 1 | Run full test suite | All 22+ categories, 98%+ pass rate |
| 2 | Test critical functionality | Core features, expected warnings |
| 3 | Review output formatting | Color-coded, well-formatted output |
| 4 | Run category-specific tests | Individual category isolation |
| 5 | Run OpenSocial tests | OpenSocial-specific validation |
| 6 | Run site-specific tests | Behat/PHPUnit, template validation |

## P50 Coverage Equivalents

P50 provides layered machine verification through `.verification.yml`:

| test-nwp Category | P50 Equivalent | Coverage Status |
|-------------------|----------------|-----------------|
| Script syntax | `bash -n` checks in all `lib_*` and command features | COVERED |
| Script sourcing | Source tests per feature | COVERED |
| Function existence | `type func_name` checks | COVERED |
| Command execution | `pl command --help` functional tests | COVERED |
| Exit code validation | `expect_exit: 0` in machine checks | COVERED |

### Feature-Level Mapping

| Feature Area | test-nwp Coverage | P50 Feature Section |
|--------------|-------------------|---------------------|
| Installation | Install tests | `install:` (lines 590-1200) |
| Backup/Restore | Backup tests | `backup:`, `restore:` |
| Status checks | Status tests | `status:` |
| Configuration | Modify tests | `modify:` |
| Libraries | lib_* tests | `lib_common:`, `lib_ui:`, `lib_git:`, etc. |
| CLI framework | CLI tests | `pl_cli:`, `lib_cli_register:` |
| Testing | Test command tests | `test:`, `run_tests:` |

## P51 Coverage Equivalents

P51 provides AI-powered deep verification through scenarios:

| test-nwp Category | P51 Equivalent | Coverage Status |
|-------------------|----------------|-----------------|
| Integration tests | AI scenarios with multi-step verification | COVERED |
| Output quality | AI analysis of command output | COVERED |
| Error handling | AI verification of error paths | COVERED |
| Documentation | AI comparison of docs vs implementation | COVERED |

### Scenario-Level Mapping

| Scenario Type | test-nwp Equivalent | P51 Scenario |
|--------------|---------------------|--------------|
| Fresh install | Full install test | `scenario_fresh_install` |
| Backup workflow | Backup category | `scenario_backup_restore` |
| Migration | Migration tests | `scenario_site_migration` |
| Multi-site | Site management | `scenario_multi_site_workflow` |

## Coverage Analysis

### Fully Covered by P50/P51

These test-nwp functions are now redundant:
- Script syntax validation (bash -n)
- Script sourcing validation
- Function existence checks
- Basic command execution
- Exit code verification
- Help output validation

### Not Directly Covered

These may need explicit tests added to P50:
- OpenSocial-specific tests (testos.sh covers some)
- Color-coded output verification (visual inspection)
- Category isolation testing

### Recommendation

**Remove the `test_nwp:` section entirely** because:

1. All core functionality is covered by individual feature sections in P50
2. Integration testing is covered by P51 scenarios
3. The script no longer exists (exit 127 failures)
4. Maintaining orphaned tests creates false failures

### Migration Steps

1. Verify each P50 feature has `bash -n` syntax check
2. Verify each command has `--help` functional test
3. Verify library functions have existence checks
4. Remove `test_nwp:` section from .verification.yml
5. Remove `test-nwp` reference from contribute.sh verification

## Verification After Removal

Run to confirm no coverage loss:
```bash
# Check P50 covers all commands
pl verify --run --depth=basic 2>&1 | grep -E "(PASS|FAIL)" | wc -l

# Check P51 covers integration
pl verify ai --list-scenarios

# Confirm no test-nwp references remain
grep -c "test-nwp" .verification.yml  # Should be 0
```

---

## Appendix: Original test-nwp.sh Intent

Based on the verification.yml description, test-nwp.sh was designed to:

1. **Aggregate all tests** - Run 22+ test categories in sequence
2. **Provide summary** - Total tests, passed, failed, warnings
3. **Log results** - Create `.logs/test-nwp-<timestamp>.log`
4. **Support isolation** - Run individual categories with flags

This functionality is now distributed across:
- `pl verify --run` for machine tests
- `pl verify ai` for AI scenarios
- Individual command tests via `pl test`
