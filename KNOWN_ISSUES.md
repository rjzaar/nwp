# Known Issues

This document tracks known issues and test failures in the NWP system.

**Last Updated**: 2025-12-29
**Test Suite Success Rate**: 94% (57/70 passed + 9/70 expected warnings)

## Active Issues

### 1. Dev Modules Test Failures (Test 5)

**Status**: FAILING
**Priority**: Medium
**Tests Affected**:
- "Dev modules enabled"
- "Dev modules disabled in prod mode"

**Description**:
The dev/prod mode switching tests in Test 5 are failing. The `make.sh` script successfully runs `dev` and `prod` commands, but the module status checks fail to detect the expected module states.

**Expected Behavior**:
- After `./make.sh dev test-nwp`: dev modules (devel, webprofiler) should be enabled
- After `./make.sh prod test-nwp`: dev modules should be disabled

**Actual Behavior**:
- Module status checks report dev modules in unexpected states

**Investigation Needed**:
- Check if make.sh dev/prod commands are actually enabling/disabling modules
- Verify drush pm:list output format matches test expectations
- Review DEV_MODULES configuration in cnwp.yml

**Workaround**: None currently

---

### 2. Delete Test Site Creation (Test 8b)

**Status**: FAILING
**Priority**: Medium
**Test Affected**: "Create site for deletion test"

**Description**:
Test 8b attempts to create a temporary site (`test-nwp_delete`) for testing the delete.sh functionality, but site creation fails.

**Expected Behavior**:
- `./install.sh test-nwp_delete --recipe=test-nwp -y` should create a new site
- Site should be available for deletion testing

**Actual Behavior**:
- Site creation fails during Test 8b
- Subsequent delete tests are skipped

**Investigation Needed**:
- Check why install.sh fails for this specific site
- Review install.sh logs for error messages
- May be related to resource exhaustion (multiple test sites already running)

**Workaround**: Skip delete tests when site creation fails (already implemented)

---

### 3. Linode SSH Timeout (Test 12)

**Status**: FAILING
**Priority**: High (blocks production deployment testing)
**Test Affected**: "Linode instance provisioned"

**Description**:
Linode instances are successfully created and boot to "running" state, but SSH does not become available within the 360-second timeout period.

**Expected Behavior**:
- Instance provisions in ~30-60 seconds
- Instance boots to "running" state
- SSH becomes available within 6 minutes (360s)
- Tests can connect and run commands

**Actual Behavior**:
```
Created instance: 89280156 (label: nwp-test-20251229-113214)
Waiting for instance 89280156 to boot...
...... [status: provisioning]
.....Instance is running
Instance IP: 50.116.54.150
Waiting for SSH to be available on 50.116.54.150...
........................................................................ERROR: SSH did not become available within 360 seconds
Instance 89280156 deleted
```

**Investigation Needed**:
- Check if SSH service starts on Ubuntu 22.04 Linode images
- Verify SSH configuration in cloud-init
- Test manual SSH connection to a Linode instance before it's deleted
- Consider increasing timeout further (8-10 minutes)
- Check if firewall rules are blocking SSH
- Review Linode boot logs via Lish console

**Potential Causes**:
1. SSH daemon not starting automatically on fresh Ubuntu 22.04 images
2. Cloud-init taking longer than expected to configure SSH keys
3. Network connectivity issues during provisioning
4. Firewall blocking SSH (unlikely - Linode default allows port 22)

**Workaround**: Manual testing on Linode instances

**Related Files**:
- `lib/linode.sh` - wait_for_ssh() function (line 145-168)
- `test-nwp.sh` - Test 12 (Linode Production Testing)

---

## Test Results Summary

### Test 12: Linode Production Testing (Latest Run)

**Timestamp**: 2025-12-29 11:32:14

**Provisioning Steps**:
1. ✓ Create Linode instance via API
2. ✓ Wait for instance to boot (status: running)
3. ✓ Get instance IP address
4. ✗ Wait for SSH to become available (TIMEOUT)
5. ✓ Delete instance (cleanup)

**Instance Details**:
- Instance ID: 89280156
- Label: nwp-test-20251229-113214
- IP: 50.116.54.150
- Region: us-east
- Type: g6-nanode-1 (1GB RAM)
- Image: linode/ubuntu22.04
- Boot Time: ~90 seconds (to "running" state)
- SSH Wait Time: 360+ seconds (timed out)

---

## Resolved Issues

### ✓ Local Variable Scope Error (setup-ssh.sh)
**Fixed**: 2025-12-29 (Commit: f6dde433)
**Issue**: `local: can only be used in a function` errors
**Resolution**: Removed `local` keyword from for loops in main script body

### ✓ YAML Comment Parsing
**Fixed**: 2025-12-29 (Commit: f6dde433)
**Issue**: Server details included inline YAML comments
**Resolution**: Added comment stripping to get_server_detail() function

### ✓ Linode API Key Permissions
**Fixed**: 2025-12-29 (Commit: 8c185e39)
**Issue**: API token lacked SSH Keys read permission
**Resolution**: Changed approach to pass SSH public key content directly instead of key ID

### ✓ JSON Parsing with Spaces
**Fixed**: 2025-12-29 (Commit: 0f452598)
**Issue**: Linode API returns `"id": 123` but grep expected `"id":123`
**Resolution**: Updated grep patterns to handle optional spaces: `'"id"[: ]*[0-9]*'`

---

## Testing Environment

**System**: Ubuntu Linux 6.14.0-37-generic
**DDEV Version**: (as detected)
**Test Sites Created**: test-nwp, test-nwp_copy, test-nwp1, test-nwp2, test-nwp3
**Linode API**: v4
**SSH Keys**: Ed25519, manually added to Linode Cloud Manager

---

## Contributing

When investigating or fixing these issues:

1. Update this document with findings
2. Reference test log files for detailed output
3. Update test suite if test expectations need adjustment
4. Document any workarounds discovered
5. Update success rate when tests are fixed

**Test Logs Location**: `test-nwp-YYYYMMDD-HHMMSS.log`
