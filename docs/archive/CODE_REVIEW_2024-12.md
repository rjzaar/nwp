# NWP Code Review & Improvement Plan

**Date:** December 2024
**Reviewer:** Claude Code
**Scope:** NWP, Vortex, Social, Varbase codebases

---

## Part 1: NWP Improvement Steps (Prioritized)

### Critical (Do First)

1. **Fix undefined `print_warn` function in install.sh:778**
   - Either define `print_warn()` function or change call to `print_status "WARN"`
   - This is a blocking bug that will cause script failure

### High Priority

2. **Add input validation for site names before destructive operations**
   - Create a `validate_sitename()` function in a shared library
   - Check for empty strings, special characters, absolute paths starting with `/`
   - Apply to: delete.sh:294, copy.sh:534, restore.sh:528

3. **Consolidate duplicate helper functions into shared libraries**
   - Create `lib/ui.sh` containing:
     - `print_header()`
     - `print_status()`
     - `print_error()`
     - `print_info()`
     - `print_warning()` (standardized name)
     - `show_elapsed_time()`
   - Create `lib/common.sh` containing:
     - `ocmsg()` (or rename to `debug_msg()`)
     - `validate_sitename()`
   - Update all scripts to source these libraries

4. **Standardize function naming across all scripts**
   - Choose either `print_warning` or `print_warn` (recommend `print_warning`)
   - Update all references consistently
   - Document naming conventions

5. **Add strict mode to main scripts**
   - Add `set -euo pipefail` to: install.sh, backup.sh, restore.sh, copy.sh, make.sh, delete.sh
   - Review each script for compatibility with strict mode
   - Add explicit error handling where needed

### Medium Priority

6. **Add error checking in `create_test_content()` function (install.sh:410-551)**
   - Check return codes after each `ddev drush php:eval` call
   - Log failures with meaningful error messages
   - Consider adding a `--continue-on-error` flag for test environments

7. **Make test credentials configurable (install.sh:442,529)**
   - Replace hardcoded `--password="test123"` with environment variable
   - Default to generated random password if not specified
   - Document in README.md

8. **Improve YAML parsing in lib/linode.sh:22**
   - Use a more robust YAML parsing approach
   - Handle edge cases: inline comments, quoted values, multi-line strings
   - Consider using `yq` if available, with awk fallback

9. **Add YAML validation to lib/yaml-write.sh**
   - Validate YAML syntax after write operations
   - Use `yq` or Python yaml module for validation
   - Provide clear error messages on validation failure

10. **Fix incomplete mode validation in make.sh:727**
    - Change from empty-string check to whitelist validation
    - Validate `$MODE` against allowed values: `dev`, `prod`
    - Show usage message for invalid modes

### Low Priority

11. **Clean up nwp.yml configuration structure**
    - Remove or clarify duplicate `test-nwp` entry (appears in both sites and recipes)
    - Add comments explaining the intended structure
    - Update documentation to match

12. **Add negative test cases to test-nwp.sh**
    - Test invalid recipe names
    - Test missing DDEV scenarios
    - Test permission errors
    - Test disk space issues

13. **Implement or remove TODO in test-nwp.sh:702**
    ```bash
    # TODO: Add actual deployment tests here when stg2prod.sh is ready
    ```

14. **Investigate and fix Linode SSH timeout issue (Test 12)**
    - Increase timeout or implement exponential backoff
    - Add better diagnostics for SSH connection failures
    - Consider cloud-init completion checking

15. **Update README.md documentation**
    - Document that Test 1b env file issue is fixed
    - Add troubleshooting section for edge cases
    - Ensure flag documentation matches implementation

16. **Rename `ocmsg()` to `debug_msg()` for clarity**
    - More descriptive function name
    - Update all references across scripts
    - Add documentation comment explaining purpose

17. **Add atomic operations for directory creation (install.sh:591-603)**
    - Check directory exists after cd, or use lock file
    - Handle race conditions more gracefully

18. **Improve command piping error handling (backup.sh:270)**
    - Replace `|| true` with explicit error handling
    - Ensure tar failures are properly reported

---

## Part 2: Comprehensive Code Review

### 1. NWP (Narrow Way Project)

#### Critical Issues

**1. Undefined Function `print_warn` - `/home/rob/nwp/install.sh:778`**
```bash
print_warn "Vortex DDEV script not found, using manual configuration"
```
The function `print_warn` is never defined. Only `print_error`, `print_info`, `print_status`, and `print_header` exist. This will cause script failure.

**Fix:** Change to `print_status "WARN"` or define `print_warn()`.

#### Code Quality Issues

**2. Massive Code Duplication (~400+ lines)**
Helper functions are copy-pasted across 8+ scripts:
- `ocmsg()` - identical in backup.sh, restore.sh, copy.sh, make.sh, delete.sh
- `print_header()`, `print_status()`, `show_elapsed_time()` - repeated everywhere

**Recommendation:** Create `lib/ui.sh` and `lib/common.sh` with shared functions.

**3. Inconsistent Function Naming**
- `delete.sh:65` defines `print_warning()`
- `install.sh:778` calls undefined `print_warn()`

**4. Missing Error Handling in `create_test_content()` - `install.sh:410-551`**
Multiple ddev drush commands silently ignore errors:
```bash
ddev drush php:eval "..." >/dev/null 2>&1  # Errors silently ignored
```

**5. Hardcoded Test Passwords - `install.sh:442,529`**
```bash
--password="test123"
```
Should be configurable or generated.

**6. Fragile YAML Parsing - `lib/linode.sh:22`**
```bash
token=$(awk '/^linode:/{f=1} f && /api_token:/{print $2; exit}' ...)
```
Doesn't handle comments, multi-line values, or YAML edge cases.

#### Security Concerns

**7. Missing Input Validation Before Destructive Operations**
`delete.sh:294` and others use site names in `rm -rf` without validation:
```bash
if rm -rf "$sitename" 2>/dev/null; then
```
If `$sitename` is empty, malformed, or contains special chars, unintended deletion could occur.

**8. Most Scripts Lack Strict Mode**
Missing `set -euo pipefail` allows silent failures.

#### Documentation Issues

**9. YAML Configuration Confusion - `nwp.yml:201-204`**
`test-nwp` appears both as a site and recipe, violating intended structure.

**10. Known Issue: Linode SSH Timeout (Test 12)**
Instance provisioning succeeds but SSH never becomes available. 600-second timeout insufficient.

---

### 2. Vortex (Drupal Project Template)

#### Observations

Vortex is a well-structured Drupal project template with comprehensive tooling. The CLAUDE.md documentation is excellent.

#### Minor Issues

**1. TODO in phpunit.xml:3**
```xml
<!-- TODO set checkForUnintentionallyCoveredCode="true" once https://www.drupal.org/node/2626832 is resolved. -->
```
Drupal issue #2626832 may now be resolved - worth checking.

**2. Placeholder Values in composer.json**
```json
"name": "your_org/your_site",
"description": "Drupal 11 implementation of YOURSITE for YOURORG"
```
These are intentional template placeholders but could trip up users who forget to update them.

#### Strengths

- Excellent documentation (CLAUDE.md is comprehensive)
- Well-organized project structure
- Proper use of ahoy for task orchestration
- Good separation of concerns in scripts

#### Suggestions for NWP Integration

The NWP codebase references Vortex in `install.sh`. Consider:
- Aligning NWP's helper functions with Vortex patterns
- Using Vortex's ahoy-style command organization

---

### 3. Open Social (Drupal Profile)

#### Issues Found

**1. Multiple Unresolved TODOs in Codebase**
- `social_core.info.yml:35` - `# TODO: Issue #3109479`
- `social.profile:72` - `// @todo when composer hits remove this.`
- `social.profile:131` - `// @todo Add 'event_type' if module is enabled.`

**2. Debug Code Left in Tests - `SocialDrupalContext.php:256`**
```php
// TODO: Remove debug.
```

**3. Incomplete Test Coverage**
Multiple test files have TODO comments indicating missing functionality:
- `post-create.feature:53` - `# TODO: Scenario: Succesfully delete a post`
- `view-profile-hero.feature:16-19` - Multiple TODOs about incomplete scenarios
- `event-overview.feature:30` - `#@TODO make a scenario for filters to work`

**4. Outdated PHPStan Baseline**
`phpstan-baseline.neon` is 597KB - this suggests significant technical debt being suppressed.

**5. Drupal Core Version**
Using `drupal/core: 10.5.1` - Drupal 10.5.x is in security-only mode. Consider upgrading to Drupal 11.

**6. Patch-Heavy Dependencies**
`composer.json` contains 30+ patches for Drupal core and contrib modules. This creates maintenance burden and upgrade complexity.

#### Code Quality

**7. Typo in social.profile:83**
```php
'title' => t('Address module requirements)'),
                                        ↑ Extra parenthesis
```

#### Recommendations

- Clean up TODO/debug comments in production code
- Plan Drupal 11 upgrade path
- Consider contributing patches upstream to reduce patch count
- Update PHPStan configuration to address baseline issues incrementally

---

### 4. Varbase (Drupal CMS Starter Kit)

#### Issues Found

**1. TODOs in Build Configuration - `build.xml:120,162`**
```xml
<!-- TODO: Execute manual update steps as needed. -->
<!-- TODO: Delete the database and recreate it? -->
```

**2. All Dependencies Use Dev Branches - `composer.json`**
```json
"drupal/varbase_core": "10.1.x-dev",
"drupal/varbase_api": "10.1.x-dev",
```
All 20+ dependencies are `-dev` versions. This is acceptable for a development install but risky for production without pinning.

**3. Dynamic Include Pattern in AssemblerForm.php**
```php
include_once $formbit_file_name;
call_user_func_array($demo_content_key . "_build_formbit", ...);
```
This pattern at lines 143-150 and 257-264 dynamically includes PHP files and calls functions based on configuration keys. While functional, this pattern:
- Makes code harder to trace/debug
- Could be a security concern if keys are user-controlled (they appear to come from YAML config)

**4. Global State Usage - `AssemblerForm.php:322,327,361,366`**
```php
$GLOBALS['install_state']['varbase']['extra_features_configs'][$extra_feature_key] = ...
```
Using `$GLOBALS` is generally discouraged in modern PHP. Consider using Drupal's state or a service.

#### Strengths

- Clean modular architecture with separate components
- Good use of Drupal's installation profile system
- Comprehensive form handling for installation options

---

## Part 3: Summary Tables

### NWP Improvement Priority Matrix

| # | Priority | Issue | File:Line | Effort |
|---|----------|-------|-----------|--------|
| 1 | Critical | `print_warn` undefined | install.sh:778 | Low |
| 2 | High | Input validation for destructive ops | delete.sh:294 | Medium |
| 3 | High | Consolidate duplicate functions | Multiple | High |
| 4 | High | Standardize function naming | Multiple | Medium |
| 5 | High | Add strict mode to scripts | Multiple | Medium |
| 6 | Medium | Error handling in test content | install.sh:410-551 | Medium |
| 7 | Medium | Configurable test credentials | install.sh:442,529 | Low |
| 8 | Medium | Improve YAML parsing | lib/linode.sh:22 | Medium |
| 9 | Medium | YAML validation after writes | lib/yaml-write.sh | Medium |
| 10 | Medium | Mode validation whitelist | make.sh:727 | Low |
| 11 | Low | Clean up nwp.yml structure | nwp.yml:201-204 | Low |
| 12 | Low | Add negative test cases | test-nwp.sh | High |
| 13 | Low | Implement deployment TODO | test-nwp.sh:702 | Medium |
| 14 | Low | Fix Linode SSH timeout | test-nwp.sh | High |
| 15 | Low | Update README.md | README.md | Low |
| 16 | Low | Rename ocmsg to debug_msg | Multiple | Low |
| 17 | Low | Atomic directory operations | install.sh:591-603 | Low |
| 18 | Low | Improve pipe error handling | backup.sh:270 | Low |

### Cross-Project Health Summary

| Codebase | Health | Critical Issues | Recommended Action |
|----------|--------|-----------------|-------------------|
| **NWP** | ⚠️ Needs Work | 1 | Fix `print_warn`, consolidate code |
| **Vortex** | ✅ Good | 0 | Use as reference for NWP patterns |
| **Social** | ⚠️ Moderate | 0 | Consider upstream contributions |
| **Varbase** | ⚠️ Moderate | 0 | Pin versions for production |

---

## Part 4: Quick Wins (Can Do Today)

These fixes can be implemented quickly with minimal risk:

1. **Fix `print_warn`** - 2 minutes
2. **Add input validation function** - 15 minutes
3. **Make test password configurable** - 5 minutes
4. **Fix mode validation in make.sh** - 5 minutes
5. **Add comments to nwp.yml** - 5 minutes

**Total estimated time for quick wins: ~30 minutes**

---

## Appendix: File Locations Reference

### NWP Main Scripts
- `/home/rob/nwp/install.sh` (~1600 lines)
- `/home/rob/nwp/backup.sh`
- `/home/rob/nwp/restore.sh`
- `/home/rob/nwp/copy.sh`
- `/home/rob/nwp/make.sh`
- `/home/rob/nwp/delete.sh`

### NWP Libraries
- `/home/rob/nwp/lib/yaml-write.sh`
- `/home/rob/nwp/lib/linode.sh`

### NWP Configuration
- `/home/rob/nwp/nwp.yml`
- `/home/rob/nwp/example.nwp.yml`

### NWP Testing
- `/home/rob/nwp/test-nwp.sh`
- `/home/rob/nwp/tests/`

### NWP Documentation
- `/home/rob/nwp/README.md`
- `/home/rob/nwp/KNOWN_ISSUES.md`
- `/home/rob/nwp/docs/`
