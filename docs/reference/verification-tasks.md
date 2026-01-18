# NWP Verification Tasks Reference

**Status:** ACTIVE
**Last Updated:** 2026-01-14

Complete reference for NWP's feature verification system including all tracked features, verification checklists, and integration with the `pl verify` command.

## Overview

NWP uses a verification tracking system (`.verification.yml`) to ensure all features have been manually tested by humans. When code is modified, verifications are automatically invalidated through SHA256 file hashing, ensuring features are re-tested after changes.

## Verification System

### How It Works

1. **Feature Tracking** - Each feature has:
   - Name and description
   - Associated source files
   - Verification checklist with detailed instructions
   - Verification status and metadata
   - File hashes (SHA256)

2. **Detailed Verification Instructions** - Each checklist item includes:
   - **how_to_verify**: Step-by-step verification procedure with:
     - Numbered steps (1., 2., 3., ...)
     - Specific commands to execute
     - Expected outputs and behaviors
     - Clear success criteria
   - **related_docs**: Links to relevant documentation:
     - Command reference pages
     - User guides
     - API documentation
     - Source code files

3. **Change Detection** - When files are modified:
   - SHA256 hashes are compared
   - Mismatches invalidate verification
   - Features marked for re-verification

4. **History Tracking** - All verification actions logged:
   - Who verified
   - When verified
   - Checklist completion
   - Notes and context

### Example Enhanced Checklist Item

```yaml
- text: Run setup.sh on a fresh system and verify all prerequisites install
  completed: false
  completed_by: null
  completed_at: null
  how_to_verify: |
    1. On a fresh Ubuntu/Debian system: `cd ~/nwp && ./scripts/commands/setup.sh` or `pl setup`
    2. Use arrow keys to navigate and SPACE to select required components
    3. Press ENTER to apply and watch installation process
    4. Verify Docker: `docker --version` (should show v20+)
    5. Verify DDEV: `ddev version` (should show v1.21+)
    6. Check setup status: `pl setup --status` (should show all required components with [✓])
    Success: All required components marked with [✓] and no error messages during installation
  related_docs:
    - docs/reference/commands/setup.md
    - docs/guides/setup.md
    - docs/guides/quickstart.md
```

This format provides testers with:
- **Clear steps**: Exactly what to run and check
- **Expected behavior**: What success looks like
- **Documentation**: Where to find more information

## Feature Categories

NWP tracks 89 features across these categories:

### Core Scripts (15 features)
- `setup` - Prerequisites setup (Docker, DDEV, Linode, GitLab)
- `install` - Main installation script
- `status` - Site status dashboard
- `backup` - Backup creation
- `restore` - Restore from backups
- `copy` - Site copying/cloning
- `delete` - Site deletion
- `make` - Dev/prod mode toggle
- `modify` - Site modification
- `email` - Email configuration
- `migration` - Site migration
- `migrate_secrets` - Secrets migration to two-tier
- `import` - Import external sites
- `doctor` - System diagnostics
- `bootstrap_coder` - Automated coder identity setup

### Deployment (9 features)
- `dev2stg` - Development to staging
- `stg2prod` - Staging to production
- `prod2stg` - Production to staging sync
- `live2stg` - Live to staging sync
- `stg2live` - Staging to live deployment
- `live` - Live deployment management
- `live2prod` - Live to production
- `produce` - Production environment setup
- `rollback` - Deployment rollback

### Infrastructure (6 features)
- `podcast` - Podcast site setup (Castopod)
- `schedule` - Cron scheduling
- `security` - Security hardening
- `setup_ssh` - SSH key management
- `uninstall` - Complete NWP uninstallation
- `sync` - Synchronization operations

### AVC-Moodle Integration (4 features)
- `avc_moodle_setup` - OAuth2 SSO setup between AVC and Moodle
- `avc_moodle_status` - Integration health dashboard
- `avc_moodle_sync` - Role and cohort synchronization
- `avc_moodle_test` - SSO and integration testing

### Utility & Management (11 features)
- `badges` - GitLab badge management
- `email` - Email configuration
- `report` - Error reporting to GitLab
- `rollback` - Deployment rollback
- `storage` - Cloud storage (Backblaze B2)
- `theme` - Frontend build tool management
- `seo_check` - SEO monitoring and validation
- `run_tests` - Comprehensive test runner
- `upstream` - Upstream repository sync
- `security_check` - HTTP security headers check
- `verify` - Feature verification tracking

### Coder Management (3 features)
- `coders` - Multi-coder TUI
- `coder_setup` - Coder provisioning
- `contribute` - Contribution workflow

### CLI & Testing (3 features)
- `pl_cli` - PL CLI wrapper
- `test_nwp` - NWP test suite
- `test` - DDEV site testing (PHPCS, PHPStan, PHPUnit, Behat)
- `testos` - OpenSocial testing suite

### Libraries (29 features)
- `lib_common` - Common utilities
- `lib_ui` - UI formatting
- `lib_state` - State detection
- `lib_database_router` - Database routing
- `lib_testing` - Testing framework
- `lib_preflight` - Preflight checks
- `lib_tui` - Terminal UI framework
- `lib_checkbox` - Interactive checkboxes
- `lib_yaml_write` - YAML writing/parsing
- `lib_git` - Git operations
- `lib_cloudflare` - Cloudflare API
- `lib_linode` - Linode API
- `lib_b2` - Backblaze B2 storage
- `lib_cli_register` - CLI registration
- `lib_ddev_generate` - DDEV config generation
- `lib_developer` - Developer identity management
- `lib_env_generate` - Environment file generation
- `lib_frontend` - Frontend build tools
- `lib_install_common` - Common installation functions
- `lib_install_drupal` - Drupal installation
- `lib_install_gitlab` - GitLab installation
- `lib_install_moodle` - Moodle installation
- `lib_install_podcast` - Podcast installation
- `lib_install_steps` - Installation step tracking
- `lib_live_server_setup` - Live server provisioning
- `lib_badges` - Dynamic badges
- `lib_sanitize` - Database sanitization
- `lib_safe_ops` - Safe operations
- `lib_remote` - Remote operations
- `lib_server_scan` - Server scanning
- `lib_import` - Import library
- `lib_import_tui` - Import TUI
- `lib_dev2stg_tui` - Dev2stg TUI
- `lib_terminal` - Terminal utilities
- `lib_avc_moodle` - AVC-Moodle integration
- `lib_podcast` - Podcast infrastructure
- `lib_ssh` - SSH helpers with security controls

### Configuration (2 features)
- `config_example` - example.nwp.yml
- `config_secrets` - .secrets.example.yml

## Verification Commands

### Interactive TUI

```bash
# Launch interactive verification console
pl verify
```

**Navigation:**
- `↑/↓` - Navigate features
- `SPACE` - Toggle verification
- `v` - Verify selected
- `u` - Unverify selected
- `d` - Show details
- `c` - Check for invalidations
- `q` - Quit

### Command-Line Verification

```bash
# Verify specific feature
pl verify verify backup

# With username
pl verify verify install rob

# Unverify feature
pl verify unverify backup

# Check for invalidations
pl verify check

# Show status report
pl verify report

# List all features
pl verify list

# Show summary statistics
pl verify summary

# Reset all verifications
pl verify reset
```

## Verification Checklist Examples

### Backup Feature Checklist

- [ ] Create full backup (database + files)
- [ ] Create database-only backup
- [ ] Verify backup files created
- [ ] Verify backup naming convention
- [ ] Test backup with message
- [ ] Test combined flags (-bd, -by)
- [ ] Verify backup rotation works
- [ ] Test git integration (-g flag)
- [ ] Test sanitized backup (--sanitize)
- [ ] Confirm backups are restorable

### Install Feature Checklist

- [ ] Install standard Drupal recipe (d)
- [ ] Install OpenSocial recipe (os)
- [ ] Install with custom target name
- [ ] Install with test content (-c)
- [ ] Install with purpose flags (-p=t/i/p/m)
- [ ] Resume from specific step (s=N)
- [ ] Verify recipe validation works
- [ ] Test auto-numbering (nwp, nwp1, nwp2)
- [ ] Verify all installation steps complete
- [ ] Confirm site accessible after install

### Dev2stg Feature Checklist

- [ ] Deploy with interactive TUI
- [ ] Deploy with auto mode (-y)
- [ ] Test production database source
- [ ] Test development database source
- [ ] Test custom backup file source
- [ ] Run with quick test preset
- [ ] Run with essential test preset
- [ ] Run with full test preset
- [ ] Run with skip tests
- [ ] Verify configuration import (3× retry)
- [ ] Verify production mode enabled
- [ ] Test preflight-only mode
- [ ] Test staging auto-creation
- [ ] Confirm staging site functional

## Verification Workflow

### Pre-Release Verification

Before each release:

1. **Check status**
   ```bash
   pl verify summary
   ```

2. **Identify unverified features**
   ```bash
   pl verify list
   ```

3. **Check for invalidations**
   ```bash
   pl verify check
   ```

4. **Review details for modified features**
   ```bash
   pl verify details backup
   ```

5. **Manually test each feature**
   - Follow verification checklist
   - Test all scenarios
   - Document any issues

6. **Mark as verified**
   ```bash
   pl verify verify backup
   ```

7. **Confirm 100% verification**
   ```bash
   pl verify summary
   ```

### Post-Modification Workflow

After code changes:

1. **Automatic invalidation** - `pl verify check` detects changes

2. **Review changes**
   ```bash
   pl verify details feature-id
   ```

3. **Test modified functionality** - Follow displayed checklist

4. **Re-verify**
   ```bash
   pl verify verify feature-id
   ```

## Verification File Format

`.verification.yml` structure:

```yaml
version: 2

features:
  backup:
    name: "Backup Script (backup.sh)"
    description: "Create backups of Drupal sites"
    files:
      - scripts/commands/backup.sh
      - lib/backup-common.sh
    checklist:
      - text: "Create full backup"
        completed: true
        completed_by: "rob"
        completed_at: "2026-01-14T10:30:00Z"
      - text: "Create database-only backup"
        completed: true
        completed_by: "rob"
        completed_at: "2026-01-14T10:35:00Z"
    verified: true
    verified_by: "rob"
    verified_at: "2026-01-14T10:40:00Z"
    file_hash:
      scripts/commands/backup.sh: "sha256:a1b2c3d4..."
      lib/backup-common.sh: "sha256:b2c3d4e5..."
    notes: "All backup modes tested successfully"
    history:
      - action: "verified"
        by: "rob"
        at: "2026-01-14T10:40:00Z"
      - action: "checklist_item_completed"
        by: "rob"
        at: "2026-01-14T10:35:00Z"
        context: "Item 2 completed"
```

## Integration with CI/CD

### Pre-Deployment Check

```yaml
# .gitlab-ci.yml
verify_before_deploy:
  stage: verify
  script:
    - ./pl verify check
    - ./pl verify summary
    - ./pl verify report
  only:
    - main
```

### Release Gate

Require 100% verification before release:

```bash
#!/bin/bash
# scripts/ci/verify-gate.sh

verification_percentage=$(./pl verify summary | grep -oP '\d+(?=%)')

if [ "$verification_percentage" -lt 100 ]; then
  echo "ERROR: Only ${verification_percentage}% verified"
  echo "All features must be verified before release"
  exit 1
fi

echo "✓ All features verified (100%)"
```

## Best Practices

### Verification Frequency

- **After code changes** - Re-verify affected features
- **Before releases** - 100% verification required
- **Weekly** - Review verification status
- **Monthly** - Full re-verification of all features

### Verification Quality

- **Follow checklist completely** - Don't skip items
- **Test edge cases** - Not just happy path
- **Document issues** - Add notes to verification
- **Multiple testers** - Different people verify
- **Real environments** - Test in realistic conditions

### Maintenance

- **Update checklists** - Keep checklists current
- **Add new features** - Update `.verification.yml` for new features
- **Review history** - Learn from past verifications
- **Refine process** - Improve verification workflow

## Related Commands

- [verify](../reference/commands/verify.md) - Verify command reference
- [verify --run](../reference/commands/verify.md) - Automated verification suite

## See Also

- [Human Testing Guide](../testing/human-testing.md) - Manual testing procedures
- [Testing Documentation](../testing/testing.md) - Automated testing framework
- `.verification.yml` - Verification tracking file
