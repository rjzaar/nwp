# Known Issues

This document tracks known issues and limitations in the NWP system.

**Last Updated**: 2026-01-20

See also: [Roadmap](docs/governance/roadmap.md) for planned improvements.

---

## Active Issues

### 1. Verification Test Infrastructure (~65 failing tests)

**Status**: PLANNED FIX (P54)
**Priority**: High

**Description**:
The verification system shows ~88% pass rate with approximately 65 failing automatable tests due to test infrastructure issues, not code failures.

**Root Causes**:
1. `test-nwp.sh` was deleted but verification tests still reference it (exit 127)
2. Scripts execute `main "$@"` when sourced for validation
3. Missing library functions (`git_add_all`, `git_has_changes`, `git_get_current_branch`)
4. Interactive TUI (coders.sh) times out waiting for input
5. Grep-based tests check for unimplemented features

**Workaround**:
Run verification with `--depth=basic` for quicker results.

**Solution**:
See [P54 Proposal](docs/proposals/P54-verification-test-fixes.md) for comprehensive fix plan.

---

### 2. Verification Badge Accuracy

**Status**: PROPOSED FIX (P53)
**Priority**: Medium

**Description**:
The "Machine Verified" percentage uses incorrect math:
- Current: 511 verified / 575 total = 88%
- Problem: 117 items are marked `automatable: false`
- Correct: 511 verified / 458 automatable = ~89.7%

Also, "AI Verification" naming is misleading - the system uses bash/drush scenario testing with zero AI/LLM calls.

**Solution**:
See [P53 Proposal](docs/proposals/p53.md) for categorization and badge accuracy fixes.

---

### 3. Linode SSH Timeout (Test 12)

**Status**: FAILING (600s timeout insufficient)
**Priority**: Medium

**Description**:
Linode instances are created and boot to "running" state, but SSH does not become available within the 600-second (10 minute) timeout period.

**Root Cause Analysis**:
Cloud-init on fresh Ubuntu 22.04 Linode instances takes significant time. Even 10 minutes is insufficient, suggesting:
1. SSH service may not start automatically on Ubuntu 22.04 Linode images
2. Potential network/routing issue preventing SSH connections
3. SSH keys might not be properly configured in cloud-init

**Workaround**:
Use larger instance types (g6-standard-1 or higher) for faster boot times, or manually verify SSH access before running production tests.

**Next Steps**:
1. Check Lish console logs for boot errors
2. Try larger instance type or different OS image
3. Consider using Linode StackScripts for guaranteed SSH setup

**Related Files**: `lib/linode.sh` (wait_for_ssh function)

---

### 4. Social Profile Drush Conflict

**Status**: KNOWN LIMITATION (tests skip gracefully)
**Priority**: Low (external dependency)

**Description**:
The social profile (goalgorilla/social_template) has an outdated drush requirement (`drush/drush: dev-test-74`) that conflicts with modern Drupal requirements (needs `^12.5` or higher).

**Impact**:
- Dev/prod mode tests skip with warning when using social profile
- Does not affect NWP functionality
- Other recipes (nwp, d, dm) work normally

**Workaround**:
Use a different recipe (nwp, drupal10) for testing dev/prod functionality.

**Long-term Solution**:
Wait for social profile maintainers to update their composer.json drush requirement.

---

### 5. Coder Management Security Gap

**Status**: INVESTIGATION NEEDED
**Priority**: Low (requires intentional misuse)

**Description**:
Admin status for coders is determined solely from local `nwp.yml` without GitLab API validation. A coder could theoretically self-promote by editing their local nwp.yml.

**Mitigations**:
- Audit logging tracks all coder changes
- Critical operations still require actual GitLab permissions

**Proposed Solution**:
Add GitLab API validation for sensitive operations requiring steward permissions.

---

## Resolved Issues

### Environment Variable Generation (Test 1b)
**Fixed**: 2026-01-03
**Issue**: Tests checked wrong directory due to auto-increment naming
**Resolution**: Added cleanup_test_sites() at start of test-nwp.sh

### Delete Test Site Creation (Test 8b)
**Fixed**: 2026-01-03
**Issue**: Test used incorrect recipe name format (underscore vs hyphen)
**Resolution**: Updated test-nwp.sh to use correct recipe name `test-nwp`

### Local Variable Scope Error (setup-ssh.sh)
**Fixed**: 2025-12-29
**Issue**: `local: can only be used in a function` errors
**Resolution**: Removed `local` keyword from for loops in main script body

### YAML Comment Parsing
**Fixed**: 2025-12-29
**Issue**: Server details included inline YAML comments
**Resolution**: Added comment stripping to get_server_detail() function

### Linode API Key Permissions
**Fixed**: 2025-12-29
**Issue**: API token lacked SSH Keys read permission
**Resolution**: Pass SSH public key content directly instead of key ID

### JSON Parsing with Spaces
**Fixed**: 2025-12-29
**Issue**: Linode API JSON spacing mismatch
**Resolution**: Updated grep patterns to handle optional spaces

---

## Contributing

When investigating or fixing issues:
1. Update this document with findings
2. Reference test log files for detailed output
3. Update test suite if expectations need adjustment
4. Document any workarounds discovered
