# P52: Rename NWP to NWO (Narrow Way Operations)

**Status:** PROPOSED
**Created:** 2026-01-18
**Author:** Rob, Claude Opus 4.5
**Priority:** Medium
**Estimated Effort:** 2-3 days
**Breaking Changes:** Yes - complete fresh start (no backward compatibility)

---

## 1. Executive Summary

Rename the project from NWP to NWO (Narrow Way Operations). This involves renaming directories, configuration files, scripts, documentation, and all internal references. This is a clean break with no backward compatibility period.

### 1.1 Scope of Changes

| Category | Current | New |
|----------|---------|-----|
| Project directory | `~/nwp` | `~/nwo` |
| Config file | `cnwp.yml` | `nwo.yml` |
| Example config | `example.cnwp.yml` | `example.nwo.yml` |
| Environment prefix | `NWP_*` | `NWO_*` |
| Function prefix | `nwp_*` | `nwo_*` |
| Git repository | `nwp/nwp.git` | `nwp/nwo.git` |

### 1.2 Reference Count (Current State)

| Pattern | Count |
|---------|-------|
| `nwp` (lowercase) | ~4,383 |
| `NWP` (uppercase) | ~1,752 |
| `cnwp` | ~1,442 |
| **Total references** | **~7,577** |

---

## 2. Detailed Change Analysis

### 2.1 Directory Structure

```
BEFORE                          AFTER
~/nwp/                    →     ~/nwo/
~/nwp/sites/              →     ~/nwo/sites/
~/nwp/sitebackups/        →     ~/nwo/sitebackups/
~/nwp/lib/                →     ~/nwo/lib/
~/nwp/scripts/            →     ~/nwo/scripts/
~/nwp/docs/               →     ~/nwo/docs/
```

### 2.2 Configuration Files

| File | Action |
|------|--------|
| `cnwp.yml` | Rename to `nwo.yml` |
| `example.cnwp.yml` | Rename to `example.nwo.yml` |
| `.secrets.yml` | Update internal references |
| `.secrets.example.yml` | Update internal references |
| `.secrets.data.yml` | Update internal references |

### 2.3 Script Changes

Files requiring updates (grep for `nwp`, `NWP`, `cnwp`):

#### Core Scripts
- [ ] `pl` - Main entry point, version string, paths (23 references)
- [ ] `scripts/commands/*.sh` - All command scripts
- [ ] `lib/*.sh` - All library files

#### Linode Server Scripts (15 files to rename)
```
linode/nwp-audit.sh           → linode/nwo-audit.sh
linode/nwp-backup.sh          → linode/nwo-backup.sh
linode/nwp-bluegreen-deploy.sh → linode/nwo-bluegreen-deploy.sh
linode/nwp-bootstrap.sh       → linode/nwo-bootstrap.sh
linode/nwp-canary.sh          → linode/nwo-canary.sh
linode/nwp-createsite.sh      → linode/nwo-createsite.sh
linode/nwp-cron.conf          → linode/nwo-cron.conf
linode/nwp-healthcheck.sh     → linode/nwo-healthcheck.sh
linode/nwp-monitor.sh         → linode/nwo-monitor.sh
linode/nwp-notify.sh          → linode/nwo-notify.sh
linode/nwp-perf-baseline.sh   → linode/nwo-perf-baseline.sh
linode/nwp-rollback.sh        → linode/nwo-rollback.sh
linode/nwp-scheduled-backup.sh → linode/nwo-scheduled-backup.sh
linode/nwp-swap-prod.sh       → linode/nwo-swap-prod.sh
linode/nwp-verify-backup.sh   → linode/nwo-verify-backup.sh
```

#### Server-Side Directories
```
/home/$SSH_USER/nwp-scripts   → /home/$SSH_USER/nwo-scripts
```

#### Key Variables to Rename
```bash
# Current → New
NWP_VERSION      → NWO_VERSION
NWP_ROOT         → NWO_ROOT
NWP_RECIPE       → NWO_RECIPE
NWP_CLI_PROMPT   → NWO_CLI_PROMPT
NWP_AUTO_PROVISION → NWO_AUTO_PROVISION
NWP_PRIVATE_DIR  → NWO_PRIVATE_DIR
NWP_CMI_DIR      → NWO_CMI_DIR
PROJECT_ROOT     → (keep as is - generic)
nwp_config_*     → nwo_config_*
```

### 2.4 Documentation Updates

| Document | Changes Required |
|----------|------------------|
| `README.md` | Project name, paths, examples |
| `CLAUDE.md` | All NWP references |
| `docs/*.md` | All documentation files |
| `docs/proposals/*.md` | Historical references (note: keep as historical record) |
| `CHANGELOG.md` | Add migration note |

### 2.5 Git Repository

- [ ] Rename repository on GitLab/GitHub (if desired)
- [ ] Update git remote URLs
- [ ] Update any CI/CD pipelines referencing `nwp`

### 2.6 DDEV Configuration

Each site's `.ddev/config.yaml` may contain:
- Project naming conventions
- Hook scripts referencing `~/nwp`

### 2.7 External References

- [ ] Any symlinks pointing to `~/nwp`
- [ ] Shell aliases or functions (user's `.bashrc`, `.zshrc`)
- [ ] Cron jobs referencing `~/nwp`
- [ ] systemd services (if any)

---

## 3. Migration Strategy

### 3.1 Phase 1: Preparation (Pre-Migration)

1. **Audit all references**
   ```bash
   # Find all NWP references in codebase
   grep -r "nwp\|NWP\|cnwp" --include="*.sh" --include="*.yml" --include="*.md" .
   ```

2. **Create migration script** (`scripts/commands/migrate-to-nwo.sh`)
   - Validates current installation
   - Creates backup of configuration
   - Performs rename operations
   - Updates all file contents
   - Validates new installation

3. **Update example config first**
   - Rename `example.cnwp.yml` → `example.nwo.yml`
   - Test with fresh installation

### 3.2 Phase 2: Code Changes

1. **Create feature branch**
   ```bash
   git checkout -b feature/rename-nwp-to-nwo
   ```

2. **Bulk rename operations**
   ```bash
   # Rename files
   git mv example.cnwp.yml example.nwo.yml

   # Update file contents (careful review required)
   find . -type f \( -name "*.sh" -o -name "*.yml" -o -name "*.md" \) \
     -exec sed -i 's/cnwp\.yml/nwo.yml/g' {} \;
   find . -type f \( -name "*.sh" -o -name "*.yml" -o -name "*.md" \) \
     -exec sed -i 's/NWP_/NWO_/g' {} \;
   # ... additional patterns
   ```

3. **Manual review of changes**
   - Verify no unintended replacements
   - Check string literals vs variable names
   - Ensure URLs and paths are correct

### 3.3 Phase 3: Testing

1. **Fresh installation test**
   - Clone to `~/nwo`
   - Run setup
   - Install a test site
   - Run verification suite

2. **Migration test**
   - Test migration script on existing `~/nwp` installation
   - Verify all sites still work
   - Verify backups are accessible

### 3.4 Phase 4: Release

1. **Create migration documentation**
2. **Tag release with migration notes**
3. **Announce breaking change**

---

## 4. Installation (Fresh Start)

Since this is a complete fresh start with no backward compatibility:

### 4.1 New Installation

```bash
# Clone the renamed repository
cd ~
git clone git@git.nwpcode.org:nwp/nwo.git

# Copy and configure
cd ~/nwo
cp example.nwo.yml nwo.yml
# Edit nwo.yml with your site configurations

# Run setup
./pl setup

# Verify
./pl doctor
```

### 4.2 For Existing Users

Existing `~/nwp` installations should be treated as legacy. Users should:

1. **Backup existing sites and data**
2. **Fresh clone** of the new `nwo` repository
3. **Migrate site configurations** manually from `cnwp.yml` to `nwo.yml`
4. **Update shell aliases** if using `alias pl='~/nwp/pl'`
5. **Update cron jobs** if any reference `~/nwp`

---

## 5. Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Broken site paths | High | Migration script updates DDEV configs |
| Lost backups | High | Backup validation before migration |
| Broken cron jobs | Medium | Document manual steps for cron updates |
| Git history references | Low | Keep historical references in docs |
| User confusion | Medium | Clear migration documentation |

---

## 6. Complete Change List

Based on comprehensive audit (~7,577 total references):

### 6.1 Core Changes
- [ ] **Version string** in `pl` script (`NWP_VERSION` → `NWO_VERSION`)
- [ ] **Help text** in all commands
- [ ] **Error messages** referencing NWP
- [ ] **Environment variables** (`NWP_*` → `NWO_*`)

### 6.2 File System
- [ ] **Project directory** (`~/nwp` → `~/nwo`)
- [ ] **Config files** (`cnwp.yml` → `nwo.yml`, `example.cnwp.yml` → `example.nwo.yml`)
- [ ] **Log directories** (`.logs/` references)

### 6.3 Verification System
- [ ] `.verification.yml` - Documentation paths and examples
- [ ] `.verification-scenarios/*.yml` - Any hardcoded paths
- [ ] `.verification-checkpoint.yml`
- [ ] `.verification-peaks.yml`

### 6.4 Server/Linode Scripts (15 files)
- [ ] Rename all `linode/nwp-*.sh` → `linode/nwo-*.sh`
- [ ] Update internal references within these scripts
- [ ] Update `linode/linode_server_setup.sh` (`nwp-scripts` directory)
- [ ] Update server-side paths (`/home/$USER/nwp-scripts`)

### 6.5 Git Repository
- [ ] Repository rename: `nwp/nwp.git` → `nwp/nwo.git`
- [ ] Update any remote URL references in scripts

### 6.6 Shell/Cron Integration
- [ ] User shell aliases (`alias pl='~/nwp/pl'`)
- [ ] Cron jobs referencing `~/nwp`
- [ ] Any systemd services

### 6.7 Test Fixtures
- [ ] `tests/fixtures/sample-site/composer.json` ("nwp/test-site" → "nwo/test-site")

---

## 7. Implementation Checklist

### Pre-Migration
- [ ] Create comprehensive grep audit of all references
- [ ] Identify all files requiring changes
- [ ] Create migration script
- [ ] Test migration on copy of installation
- [ ] Update example.nwo.yml

### Code Changes
- [ ] Rename configuration files
- [ ] Update pl script
- [ ] Update all lib/*.sh files
- [ ] Update all scripts/commands/*.sh files
- [ ] Update all documentation
- [ ] Update CLAUDE.md
- [ ] Update verification scenarios

### Testing
- [ ] Run full verification suite
- [ ] Test fresh installation
- [ ] Test migration from existing installation
- [ ] Test all major commands

### Release
- [ ] Update CHANGELOG.md
- [ ] Create migration guide
- [ ] Tag release
- [ ] Update any external documentation

---

## 8. Success Criteria

- [ ] Fresh `git clone` to `~/nwo` works out of the box
- [ ] All existing sites continue to function after migration
- [ ] `pl doctor` passes
- [ ] `pl verify --run` achieves same coverage as before
- [ ] All documentation references NWO consistently
- [ ] Migration script handles edge cases gracefully

---

## 9. Decisions Made

| Question | Decision |
|----------|----------|
| Linode servers | Yes, update to `nwo-scripts` |
| Domain `nwpcode.org` | Stays as-is (separate from project name) |
| CLI command `pl` | Keep as `pl` |
| Backward compatibility | None - clean break |
| Git repository | `nwp/nwo.git` |

## 10. Open Questions

1. **Site names?** Should any existing sites with "nwp" in their name be renamed? (Probably not - site names are user choice)

2. **Git tags/releases?** Should historical tags be preserved as-is or annotated?

---

## 11. Timeline Estimate

| Phase | Duration |
|-------|----------|
| Audit & Planning | 2-4 hours |
| Migration Script | 4-6 hours |
| Code Changes | 4-6 hours |
| Documentation | 2-3 hours |
| Testing | 4-6 hours |
| **Total** | **16-25 hours (2-3 days)** |
