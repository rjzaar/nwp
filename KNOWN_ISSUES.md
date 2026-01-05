# Known Issues

This document tracks known issues and limitations in the NWP system.

**Last Updated**: 2026-01-05

See also: [docs/ROADMAP.md](docs/ROADMAP.md) for planned improvements.

---

## Active Issues

### 1. Linode SSH Timeout (Test 12)

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

### 2. Social Profile Drush Conflict

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
