# YAML Parser Consolidation Proposal

**Status:** PROPOSED
**Created:** 2026-01-13
**Updated:** 2026-01-13
**Related:** docs/proposals/nwp-deep-analysis.md (Section 8.3.2)
**Issue:** Duplicate YAML parsing code scattered across codebase

---

## Executive Summary

Despite having a comprehensive `lib/yaml-write.sh` library (1270 lines, 18 functions), NWP still has **5+ duplicate YAML parsing implementations** scattered throughout the codebase. These duplicates create maintenance burden, inconsistency risk, and code bloat.

**Goal:** Consolidate all YAML parsing to use the existing `lib/yaml-write.sh` library and eliminate duplication.

### Comparison with Alternative Approaches

| Aspect | NWP Current | Pleasy Pattern | Recommended |
|--------|-------------|----------------|-------------|
| **Parsing** | On-demand (lazy) | Upfront (eager eval) | On-demand + caching |
| **Variable Access** | Function calls | Bash indirect `${!var}` | Function calls |
| **Write Support** | ✅ Yes | ❌ No | ✅ Required |
| **Validation** | ✅ Partial | ❌ None | ✅ Full |
| **Security** | ✅ Site name validation | ❌ None | ✅ Required |
| **Dependencies** | yq (optional) + AWK | Pure AWK/sed | yq-first |
| **Code Size** | ~4,275 lines (fragmented) | ~139 lines | ~1,500 lines (unified) |

---

## Comparative Analysis: Pleasy's Conflation Pattern

The **pleasy** project (~/tmp/pleasy) uses an alternative approach worth understanding. Its `parse_yaml.sh` (139 lines) converts nested YAML into flat bash variables using underscore concatenation ("conflation").

### How Pleasy Works

**Input YAML:**
```yaml
recipes:
  oc:
    source: git@github.com:rjzaar/opencourse.git
    dev: y
    prod:
      alias: cathnet
      uri: "opencat.org"
```

**Generated Variables:**
```bash
recipes_oc_source="git@github.com:rjzaar/opencourse.git"
recipes_oc_dev="y"
recipes_oc_prod_alias="cathnet"
recipes_oc_prod_uri="opencat.org"
recipes_oc_prod_="recipes_oc_prod_alias recipes_oc_prod_uri"  # index
recipes_oc_="recipes_oc_source recipes_oc_dev recipes_oc_prod_"  # index
recipes_="recipes_oc_ recipes_loc_ recipes_stg_"  # index
```

**Access Pattern:**
```bash
sitename="oc"
rp="recipes_${sitename}_source"
value=${!rp}  # Indirect expansion → git@github.com:rjzaar/opencourse.git
```

### Pleasy Pros

| Advantage | Description |
|-----------|-------------|
| **Fast access** | No file I/O after initial parse |
| **Simple syntax** | `${!varname}` is readable |
| **Portable** | Works in bash 3.x (macOS default) |
| **No dependencies** | Pure AWK/sed |
| **Enumerable** | Index variables allow iteration |
| **Compact** | 139 lines total |

### Pleasy Cons

| Disadvantage | Description |
|--------------|-------------|
| **Namespace pollution** | All variables in global scope |
| **No write support** | Read-only; can't modify YAML programmatically |
| **Complex sed pipeline** | 10+ chained sed commands, hard to debug |
| **No validation** | Malformed YAML produces wrong variable names |
| **No security checks** | No path traversal or injection prevention |
| **Stale data risk** | Must detect config changes to re-parse |

### Why NWP Can't Adopt Pleasy Directly

1. **Write operations required** - NWP's site registry needs `yaml_add_site()`, `yaml_update_site_field()`, etc.
2. **Security validation** - NWP validates site names to prevent injection attacks
3. **Multiple config files** - NWP parses nwp.yml, .secrets.yml, .nwp-developer.yml
4. **Backup/restore** - NWP maintains transaction safety for YAML modifications

### Lessons to Borrow from Pleasy

1. **Caching concept** - Parse once, access many times (see Phase 7)
2. **Index variables** - For enumeration without re-parsing
3. **Indirect expansion** - Clean access pattern for dynamic keys

---

## Current State

### ✅ What Exists

**`lib/yaml-write.sh`** - Comprehensive YAML library with:
- **Reading functions:**
  - `yaml_site_exists()` - Check if site exists
  - `yaml_get_site_field()` - Get field value
  - `yaml_get_site_list()` - List all sites
  - `yaml_get_site_purpose()` - Get site purpose

- **Writing functions:**
  - `yaml_add_site()` - Add new site
  - `yaml_remove_site()` - Remove site
  - `yaml_update_site_field()` - Update field
  - `yaml_add_site_modules()` - Add modules array
  - `yaml_add_site_production()` - Add production config
  - `yaml_add_site_live()` - Add live config
  - `yaml_add_migration_stub()` - Add migration entry
  - `yaml_complete_site_stub()` - Complete stub

- **Utility functions:**
  - `yaml_validate()` - Validate YAML syntax (yq or awk)
  - `yaml_validate_sitename()` - Validate site names
  - `yaml_backup()` - Backup before modifications
  - `yaml_validate_or_restore()` - Rollback on error

### ❌ What's Duplicated

Despite this library, multiple scripts still contain inline YAML parsing:

| File | Lines | Pattern | Functions |
|------|-------|---------|-----------|
| `lib/yaml-write.sh` | 1,270 | AWK state machine | 18 functions (canonical) |
| `lib/install-common.sh` | 1,361 | AWK recipes | `get_recipe_value`, `get_recipe_list_value`, `get_settings_value` |
| `lib/common.sh` | 628 | AWK secrets | `get_secret`, `get_secret_nested`, `get_data_secret`, `get_setting` |
| `lib/linode.sh` | 678 | yq + AWK | `parse_yaml_value` |
| `lib/developer.sh` | ~200 | yq only | `get_developer_*` functions |
| `lib/state.sh` | 338 | grep + awk chains | Inline parsing |
| `scripts/commands/bootstrap-coder.sh` | ~600 | yq + AWK | Inline yq -i writes |
| `scripts/commands/coder-setup.sh` | ~300 | yq + AWK | Inline yq -i writes |
| `scripts/commands/avc-moodle-setup.sh` | ~470 | yq + grep | Inline parsing |
| **Total** | **~5,845** | **7 patterns** | **~30 functions** |

Specific duplicate locations:

1. **`lib/install-common.sh`** - Custom awk parser for recipe/site registration
2. **`lib/cloudflare.sh`** - Custom awk for settings parsing
3. **`lib/linode.sh`** - Custom awk for Linode config
4. **`lib/b2.sh`** - Custom awk for B2 credentials
5. **`lib/avc-moodle.sh`** - Custom awk for Moodle config
6. **`scripts/commands/status.sh`** - Custom awk for site listing
7. **`scripts/commands/schedule.sh`** - Custom awk for schedule config

### Pattern of Duplication

Each script contains variations of:

```bash
# Pattern 1: Read from settings section
awk '
    /^settings:/ { in_settings = 1; next }
    in_settings && /^[a-zA-Z]/ && !/^  / { in_settings = 0 }
    in_settings && /^  url:/ {
        sub(/^  url: */, "")
        print
        exit
    }
' nwp.yml
```

```bash
# Pattern 2: Read from sites section
awk '
    /^sites:/ { in_sites = 1; next }
    in_sites && /^[a-zA-Z]/ { in_sites = 0 }
    in_sites && $0 ~ "^  " site ":" { found = 1 }
    # ... more parsing ...
' nwp.yml
```

```bash
# Pattern 3: Read nested values
awk -v site="$sitename" '
    /^sites:/ { in_sites = 1; next }
    in_sites && $0 ~ "^  " site ":" { in_site = 1; next }
    in_site && /^    directory:/ {
        sub(/^    directory: */, "")
        print
        exit
    }
' nwp.yml
```

---

## Problems with Current Duplication

### 1. Maintenance Burden
- Changes to YAML structure require updating 5+ locations
- Bug fixes must be replicated across files
- Each duplicate can drift and become inconsistent

### 2. Inconsistent Error Handling
- Some parsers validate input, some don't
- Some handle missing keys gracefully, some fail silently
- Different error messages for same issues

### 3. No yq Optimization
- `lib/yaml-write.sh` uses `yq` if available for robust parsing
- Duplicates don't check for `yq`, always use awk
- Missing optimization opportunity

### 4. Code Bloat
- Each duplicate is 10-30 lines
- Total: ~150+ lines of repeated parsing logic
- Harder to read and understand scripts

### 5. Testing Complexity
- Must test each duplicate independently
- No centralized test coverage
- Bugs hide in less-used scripts

### 6. Specific Inconsistencies Found

| Issue | Severity | Examples |
|-------|----------|----------|
| **Quote stripping differs** | Medium | `gsub(/["'"'"']/, "")` vs `gsub(/^["']│["']$/, "")` |
| **Comment handling differs** | Medium | Some use `sub(/ *#.*$/, "")`, some don't |
| **Error handling differs** | High | Silent return vs stderr vs exit code |
| **Nesting depth varies** | Medium | 2-level vs 3-level support |
| **List return format** | Low | Space-separated vs newline-separated |
| **yq availability check** | Medium | Some check, some assume AWK only |

### 7. All YAML Files Parsed

| File | Purpose | Parsers Used |
|------|---------|--------------|
| `nwp.yml` | Site registry | yaml-write.sh, install-common.sh, state.sh |
| `example.nwp.yml` | Template | install-common.sh |
| `.secrets.yml` | Infrastructure secrets | common.sh, linode.sh |
| `.secrets.data.yml` | Production credentials | common.sh (blocked for AI) |
| `.nwp-developer.yml` | Developer identity | developer.sh |
| `.ddev/config.yaml` | DDEV per-site config | backup.sh, state.sh (grep only) |

---

## Proposed Solution

### New Functions Specification

The following functions will be added to `lib/yaml-write.sh`:

```bash
# Add to lib/yaml-write.sh

#######################################
# Get value from settings section
# Arguments:
#   $1 - Key path (e.g., "url", "email.domain", "gitlab.default_group")
#   $2 - Config file (optional)
# Returns:
#   Value or empty string
#######################################
yaml_get_setting() {
    local key_path="$1"
    local config_file="${2:-$YAML_CONFIG_FILE}"

    # Use yq if available
    if command -v yq &>/dev/null; then
        yq eval ".settings.${key_path}" "$config_file" 2>/dev/null | grep -v "^null$"
        return ${PIPESTATUS[0]}
    fi

    # Fallback to awk
    local keys=()
    IFS='.' read -ra keys <<< "$key_path"

    awk -v depth="${#keys[@]}" '
        BEGIN {
            # Build key array from arguments
            for (i = 1; i < depth + 1; i++) {
                keys[i] = ARGV[i + 1]
                delete ARGV[i + 1]
            }
            current_depth = 0
            in_settings = 0
        }

        /^settings:/ { in_settings = 1; current_depth = 1; next }

        in_settings && current_depth == depth {
            # At target depth, look for final key
            pattern = "^" sprintf("%*s", depth * 2, "") keys[depth] ":"
            if ($0 ~ pattern) {
                sub(pattern " *", "")
                sub(/#.*/, "")
                gsub(/["'"'"']/, "")
                gsub(/^[[:space:]]+|[[:space:]]+$/, "")
                print
                exit
            }
        }

        in_settings && current_depth < depth {
            # Navigate nested structure
            pattern = "^" sprintf("%*s", current_depth * 2, "") keys[current_depth] ":"
            if ($0 ~ pattern) {
                current_depth++
            }
        }

        # Exit settings section
        in_settings && /^[a-zA-Z]/ && !/^  / { exit }
    ' "$config_file" "${keys[@]}"
}

#######################################
# Get list of coders from other_coders section
# Arguments:
#   $1 - Config file (optional)
# Returns:
#   List of coder names, one per line
#######################################
yaml_get_coder_list() {
    local config_file="${2:-$YAML_CONFIG_FILE}"

    if command -v yq &>/dev/null; then
        yq eval '.other_coders.coders | keys | .[]' "$config_file" 2>/dev/null
        return ${PIPESTATUS[0]}
    fi

    awk '
        /^other_coders:/ { in_other_coders = 1; next }
        in_other_coders && /^  coders:/ { in_coders = 1; next }
        in_coders && /^[a-zA-Z]/ && !/^    / { exit }
        in_coders && /^    [a-zA-Z_-]+:/ {
            match($0, /^    ([a-zA-Z_-]+):/, arr)
            print arr[1]
        }
    ' "$config_file"
}

#######################################
# Get coder field value
# Arguments:
#   $1 - Coder name
#   $2 - Field name (e.g., "email", "status", "notes")
#   $3 - Config file (optional)
# Returns:
#   Field value or empty string
#######################################
yaml_get_coder_field() {
    local coder_name="$1"
    local field_name="$2"
    local config_file="${3:-$YAML_CONFIG_FILE}"

    if command -v yq &>/dev/null; then
        yq eval ".other_coders.coders.${coder_name}.${field_name}" "$config_file" 2>/dev/null | grep -v "^null$"
        return ${PIPESTATUS[0]}
    fi

    awk -v coder="$coder_name" -v field="$field_name" '
        /^other_coders:/ { in_other_coders = 1; next }
        in_other_coders && /^  coders:/ { in_coders = 1; next }
        in_coders && $0 ~ "^    " coder ":" { in_coder = 1; next }
        in_coder && /^[a-zA-Z]/ && !/^      / { exit }
        in_coder && $0 ~ "^      " field ":" {
            sub("^      " field ": *", "")
            sub(/#.*/, "")
            gsub(/["'"'"']/, "")
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")
            print
            exit
        }
    ' "$config_file"
}

#######################################
# Get array values from a section
# Arguments:
#   $1 - Path (e.g., "other_coders.nameservers", "sites.mysite.modules.enabled")
#   $2 - Config file (optional)
# Returns:
#   Array values, one per line
#######################################
yaml_get_array() {
    local path="$1"
    local config_file="${2:-$YAML_CONFIG_FILE}"

    if command -v yq &>/dev/null; then
        yq eval ".${path}[]" "$config_file" 2>/dev/null | grep -v "^null$"
        return ${PIPESTATUS[0]}
    fi

    # Parse path into sections
    local sections=()
    IFS='.' read -ra sections <<< "$path"
    local depth="${#sections[@]}"

    awk -v depth="$depth" '
        BEGIN {
            # Build section array from path
            for (i = 1; i < depth + 1; i++) {
                sections[i] = ARGV[i + 1]
                delete ARGV[i + 1]
            }
            current_depth = 0
            in_array = 0
        }

        # Navigate to target depth
        current_depth < depth && NF > 0 {
            indent = match($0, /^[[:space:]]*/) - 1
            expected_indent = (current_depth + 1) * 2

            if (indent == expected_indent - 2) {
                gsub(/^[[:space:]]+|:.*/, "")
                if ($0 == sections[current_depth + 1]) {
                    current_depth++
                }
            }
        }

        # At target depth, collect array items
        current_depth == depth && /^[[:space:]]*-[[:space:]]/ {
            sub(/^[[:space:]]*-[[:space:]]*/, "")
            sub(/#.*/, "")
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")
            print
        }

        # Exit when leaving target section
        current_depth == depth && /^[a-zA-Z]/ && !/^[[:space:]]/ { exit }
    ' "$config_file" "${sections[@]}"
}
```

### Migration Examples

Examples of how to replace duplicates with library calls:

#### Example: lib/cloudflare.sh

**Before:**
```bash
get_base_domain() {
    awk '
        /^settings:/ { in_settings = 1; next }
        in_settings && /^[a-zA-Z]/ && !/^  / { in_settings = 0 }
        in_settings && /^  url:/ {
            sub(/^  url: */, "")
            print
            exit
        }
    ' nwp.yml
}
```

**After:**
```bash
source "$PROJECT_ROOT/lib/yaml-write.sh"

get_base_domain() {
    yaml_get_setting "url"
}
```

#### Example: scripts/commands/status.sh

**Before:**
```bash
get_all_sites() {
    awk '
        /^sites:/ { in_sites = 1; next }
        in_sites && /^[a-zA-Z]/ { in_sites = 0 }
        in_sites && /^  [a-zA-Z]/ {
            sub(/:.*/, "")
            sub(/^  /, "")
            print
        }
    ' nwp.yml
}
```

**After:**
```bash
source "$PROJECT_ROOT/lib/yaml-write.sh"

get_all_sites() {
    yaml_get_site_list
}
```

### Test Examples

Example tests for the new functions:

```bash
# tests/test-yaml-read.sh

@test "yaml_get_setting reads simple key" {
    echo "settings:" > "$TEST_CONFIG"
    echo "  url: example.com" >> "$TEST_CONFIG"

    result=$(yaml_get_setting "url" "$TEST_CONFIG")
    [ "$result" = "example.com" ]
}

@test "yaml_get_setting reads nested key" {
    echo "settings:" > "$TEST_CONFIG"
    echo "  email:" >> "$TEST_CONFIG"
    echo "    domain: example.com" >> "$TEST_CONFIG"

    result=$(yaml_get_setting "email.domain" "$TEST_CONFIG")
    [ "$result" = "example.com" ]
}

@test "yaml_get_array reads list items" {
    echo "other_coders:" > "$TEST_CONFIG"
    echo "  nameservers:" >> "$TEST_CONFIG"
    echo "    - ns1.linode.com" >> "$TEST_CONFIG"
    echo "    - ns2.linode.com" >> "$TEST_CONFIG"

    result=$(yaml_get_array "other_coders.nameservers" "$TEST_CONFIG")
    [ "$(echo "$result" | wc -l)" -eq 2 ]
}
```

### API Documentation Template

Template for the consolidated API documentation:

```markdown
# lib/yaml-write.sh API Reference

## Reading Functions

### yaml_get_setting
Get a value from the settings section.

**Usage:**
```bash
url=$(yaml_get_setting "url")
email=$(yaml_get_setting "email.admin_email")
```

**Arguments:**
- `$1` - Key path (dot-notation for nested keys)
- `$2` - Config file (optional, defaults to nwp.yml)

**Returns:** Value or empty string

### yaml_get_site_field
Get a field from a site entry.

**Usage:**
```bash
directory=$(yaml_get_site_field "mysite" "directory")
recipe=$(yaml_get_site_field "mysite" "recipe")
```

### yaml_get_array
Get array values as newline-separated list.

**Usage:**
```bash
nameservers=$(yaml_get_array "other_coders.nameservers")
modules=$(yaml_get_array "sites.mysite.modules.enabled")
```
```

---

## Implementation Plan (Numbered Phases)

### Phase 1: Foundation - Core Functions (Priority: Critical)

**Objective:** Add essential read functions to `lib/yaml-write.sh`

| Step | Task | File | Status |
|------|------|------|--------|
| 1.1 | Add `yaml_get_setting()` function | lib/yaml-write.sh | [ ] |
| 1.2 | Add `yaml_get_array()` function | lib/yaml-write.sh | [ ] |
| 1.3 | Add `yaml_get_coder_list()` function | lib/yaml-write.sh | [ ] |
| 1.4 | Add `yaml_get_coder_field()` function | lib/yaml-write.sh | [ ] |
| 1.5 | Add `yaml_get_recipe_field()` function | lib/yaml-write.sh | [ ] |
| 1.6 | Add `yaml_get_secret()` wrapper function | lib/yaml-write.sh | [ ] |
| 1.7 | Verify yq and AWK implementations produce identical output | lib/yaml-write.sh | [ ] |
| 1.8 | Run existing tests to ensure no regressions | tests/ | [ ] |

**Deliverables:**
- 6 new functions in yaml-write.sh
- All functions support yq-first with AWK fallback
- Consistent error handling across all functions

---

### Phase 2: Testing Infrastructure (Priority: Critical)

**Objective:** Create comprehensive test suite for new functions

| Step | Task | File | Status |
|------|------|------|--------|
| 2.1 | Create `tests/bats/yaml-read.bats` test file | tests/bats/ | [ ] |
| 2.2 | Add tests for `yaml_get_setting()` - simple keys | tests/bats/yaml-read.bats | [ ] |
| 2.3 | Add tests for `yaml_get_setting()` - nested keys | tests/bats/yaml-read.bats | [ ] |
| 2.4 | Add tests for `yaml_get_setting()` - missing keys | tests/bats/yaml-read.bats | [ ] |
| 2.5 | Add tests for `yaml_get_array()` - list values | tests/bats/yaml-read.bats | [ ] |
| 2.6 | Add tests for `yaml_get_array()` - empty lists | tests/bats/yaml-read.bats | [ ] |
| 2.7 | Add tests for `yaml_get_recipe_field()` | tests/bats/yaml-read.bats | [ ] |
| 2.8 | Add tests for `yaml_get_secret()` | tests/bats/yaml-read.bats | [ ] |
| 2.9 | Add edge case tests (quotes, comments, special chars) | tests/bats/yaml-read.bats | [ ] |
| 2.10 | Test with yq installed | tests/bats/yaml-read.bats | [ ] |
| 2.11 | Test with yq NOT installed (AWK fallback) | tests/bats/yaml-read.bats | [ ] |
| 2.12 | Verify >90% code coverage for new functions | tests/ | [ ] |

**Deliverables:**
- Comprehensive test suite with 20+ test cases
- Tests pass with both yq and AWK implementations
- Edge cases documented and tested

---

### Phase 3: High-Impact Migrations (Priority: High)

**Objective:** Replace duplicates in most-used files first

#### 3.1 Migrate `lib/cloudflare.sh`

| Step | Task | Status |
|------|------|--------|
| 3.1.1 | Identify all inline YAML parsing in cloudflare.sh | [ ] |
| 3.1.2 | Add `source "$PROJECT_ROOT/lib/yaml-write.sh"` | [ ] |
| 3.1.3 | Replace `get_base_domain()` with `yaml_get_setting "url"` | [ ] |
| 3.1.4 | Replace any other inline AWK parsers | [ ] |
| 3.1.5 | Test `pl cloudflare` commands still work | [ ] |
| 3.1.6 | Remove deprecated inline parsing code | [ ] |

#### 3.2 Migrate `lib/linode.sh`

| Step | Task | Status |
|------|------|--------|
| 3.2.1 | Identify all inline YAML parsing in linode.sh | [ ] |
| 3.2.2 | Add `source "$PROJECT_ROOT/lib/yaml-write.sh"` | [ ] |
| 3.2.3 | Replace `parse_yaml_value()` calls with `yaml_get_setting()` | [ ] |
| 3.2.4 | Update `get_linode_token()` to use consolidated function | [ ] |
| 3.2.5 | Test `pl linode` commands still work | [ ] |
| 3.2.6 | Remove deprecated `parse_yaml_value()` function | [ ] |

#### 3.3 Migrate `scripts/commands/status.sh`

| Step | Task | Status |
|------|------|--------|
| 3.3.1 | Identify all inline YAML parsing in status.sh | [ ] |
| 3.3.2 | Add `source "$PROJECT_ROOT/lib/yaml-write.sh"` | [ ] |
| 3.3.3 | Replace `get_all_sites()` with `yaml_get_site_list` | [ ] |
| 3.3.4 | Replace any other inline AWK site parsers | [ ] |
| 3.3.5 | Test `pl status` command still works | [ ] |
| 3.3.6 | Remove deprecated inline parsing code | [ ] |

#### 3.4 Migrate `lib/install-common.sh`

| Step | Task | Status |
|------|------|--------|
| 3.4.1 | Identify all inline YAML parsing in install-common.sh | [ ] |
| 3.4.2 | Ensure yaml-write.sh is sourced | [ ] |
| 3.4.3 | Replace `get_recipe_value()` with `yaml_get_recipe_field()` | [ ] |
| 3.4.4 | Replace `get_recipe_list_value()` with `yaml_get_array()` | [ ] |
| 3.4.5 | Replace `get_settings_value()` with `yaml_get_setting()` | [ ] |
| 3.4.6 | Test `pl install` commands still work | [ ] |
| 3.4.7 | Remove deprecated functions | [ ] |

**Deliverables:**
- 4 major files migrated
- All `pl` commands tested and working
- ~80 lines of duplicate code removed

---

### Phase 4: Secondary Migrations (Priority: Medium)

**Objective:** Replace duplicates in remaining files

#### 4.1 Migrate `lib/common.sh`

| Step | Task | Status |
|------|------|--------|
| 4.1.1 | Identify all `get_secret*` functions in common.sh | [ ] |
| 4.1.2 | Replace `get_secret()` with `yaml_get_secret()` | [ ] |
| 4.1.3 | Replace `get_secret_nested()` with `yaml_get_setting()` using dot notation | [ ] |
| 4.1.4 | Keep `get_data_secret()` separate (security boundary) | [ ] |
| 4.1.5 | Replace `get_setting()` with `yaml_get_setting()` | [ ] |
| 4.1.6 | Test all scripts using common.sh | [ ] |
| 4.1.7 | Remove deprecated functions | [ ] |

#### 4.2 Migrate `lib/b2.sh`

| Step | Task | Status |
|------|------|--------|
| 4.2.1 | Identify inline YAML parsing in b2.sh | [ ] |
| 4.2.2 | Replace with `yaml_get_secret()` calls | [ ] |
| 4.2.3 | Test B2 backup functionality | [ ] |
| 4.2.4 | Remove deprecated inline parsing | [ ] |

#### 4.3 Migrate `lib/avc-moodle.sh`

| Step | Task | Status |
|------|------|--------|
| 4.3.1 | Identify inline YAML parsing in avc-moodle.sh | [ ] |
| 4.3.2 | Replace with consolidated functions | [ ] |
| 4.3.3 | Test Moodle integration commands | [ ] |
| 4.3.4 | Remove deprecated inline parsing | [ ] |

#### 4.4 Migrate `scripts/commands/schedule.sh`

| Step | Task | Status |
|------|------|--------|
| 4.4.1 | Identify inline YAML parsing in schedule.sh | [ ] |
| 4.4.2 | Replace with consolidated functions | [ ] |
| 4.4.3 | Test schedule commands | [ ] |
| 4.4.4 | Remove deprecated inline parsing | [ ] |

#### 4.5 Migrate `lib/state.sh`

| Step | Task | Status |
|------|------|--------|
| 4.5.1 | Identify grep+awk chains in state.sh | [ ] |
| 4.5.2 | Replace with `yaml_get_site_field()` calls | [ ] |
| 4.5.3 | Test state detection functionality | [ ] |
| 4.5.4 | Remove deprecated inline parsing | [ ] |

**Deliverables:**
- 5 additional files migrated
- All `pl` commands tested and working
- ~70 lines of duplicate code removed

---

### Phase 5: Cleanup & Rename (Priority: Medium)

**Objective:** Final cleanup and optional rename

| Step | Task | File | Status |
|------|------|------|--------|
| 5.1 | Audit codebase for any remaining inline YAML parsing | All files | [ ] |
| 5.2 | Remove any remaining deprecated functions | Various | [ ] |
| 5.3 | Update all `source` statements for consistency | Various | [ ] |
| 5.4 | Consider rename: `lib/yaml-write.sh` → `lib/yaml.sh` | lib/ | [ ] |
| 5.5 | If renamed, update all 50+ source statements | Various | [ ] |
| 5.6 | Run full test suite | tests/ | [ ] |
| 5.7 | Verify no regressions in any `pl` command | All commands | [ ] |

**Deliverables:**
- Zero inline YAML parsers remaining
- Optional: cleaner filename
- Full test pass

---

### Phase 6: Documentation (Priority: Medium)

**Objective:** Document the consolidated API

| Step | Task | File | Status |
|------|------|------|--------|
| 6.1 | Create `docs/YAML_API.md` reference document | docs/ | [ ] |
| 6.2 | Document all read functions with examples | docs/YAML_API.md | [ ] |
| 6.3 | Document all write functions with examples | docs/YAML_API.md | [ ] |
| 6.4 | Document error handling behavior | docs/YAML_API.md | [ ] |
| 6.5 | Document yq vs AWK behavior differences | docs/YAML_API.md | [ ] |
| 6.6 | Add migration guide for script authors | docs/YAML_API.md | [ ] |
| 6.7 | Update CLAUDE.md with YAML best practices | CLAUDE.md | [ ] |
| 6.8 | Add inline documentation to yaml-write.sh | lib/yaml-write.sh | [ ] |

**Deliverables:**
- Complete API reference document
- Migration guide for contributors
- Updated CLAUDE.md

---

### Phase 7: Performance Optimization - Caching (Priority: Low)

**Objective:** Add pleasy-inspired caching for hot paths

| Step | Task | File | Status |
|------|------|------|--------|
| 7.1 | Add bash version check for associative array support | lib/yaml-write.sh | [ ] |
| 7.2 | Implement `_YAML_CACHE` associative array | lib/yaml-write.sh | [ ] |
| 7.3 | Implement `yaml_cache_load()` function | lib/yaml-write.sh | [ ] |
| 7.4 | Implement `yaml_cached_get()` function | lib/yaml-write.sh | [ ] |
| 7.5 | Implement `yaml_cache_invalidate()` function | lib/yaml-write.sh | [ ] |
| 7.6 | Add mtime-based cache invalidation | lib/yaml-write.sh | [ ] |
| 7.7 | Add tests for caching functionality | tests/bats/yaml-read.bats | [ ] |
| 7.8 | Benchmark before/after for hot paths | tests/ | [ ] |
| 7.9 | Document caching usage and limitations | docs/YAML_API.md | [ ] |

**Deliverables:**
- Optional caching for repeated reads
- Automatic invalidation on file change
- Performance benchmarks

---

### Phase 8: Schema Validation (Priority: Low)

**Objective:** Add optional schema validation

| Step | Task | File | Status |
|------|------|------|--------|
| 8.1 | Create JSON schema for nwp.yml | schemas/cnwp.schema.json | [ ] |
| 8.2 | Create JSON schema for .secrets.yml | schemas/secrets.schema.json | [ ] |
| 8.3 | Implement `yaml_validate_schema()` function | lib/yaml-write.sh | [ ] |
| 8.4 | Add schema validation to `pl validate` command | scripts/commands/ | [ ] |
| 8.5 | Document schema validation usage | docs/YAML_API.md | [ ] |

**Deliverables:**
- JSON schemas for config files
- Optional validation command
- Better error messages for malformed configs

---

## Implementation Summary

| Phase | Description | Steps | Priority | Dependencies |
|-------|-------------|-------|----------|--------------|
| **1** | Core Functions | 8 | Critical | None |
| **2** | Testing | 12 | Critical | Phase 1 |
| **3** | High-Impact Migrations | 24 | High | Phase 1-2 |
| **4** | Secondary Migrations | 20 | Medium | Phase 1-3 |
| **5** | Cleanup & Rename | 7 | Medium | Phase 1-4 |
| **6** | Documentation | 8 | Medium | Phase 1-5 |
| **7** | Caching | 9 | Low | Phase 1-6 |
| **8** | Schema Validation | 5 | Low | Phase 1-6 |
| **Total** | | **93 steps** | | |

---

## Execution Order

```
Phase 1 ──► Phase 2 ──► Phase 3 ──► Phase 4 ──► Phase 5 ──► Phase 6
   │           │           │           │           │           │
   └───────────┴───────────┴───────────┴───────────┴───────────┘
                                  │
                                  ▼
                    ┌─────────────┴─────────────┐
                    │                           │
                    ▼                           ▼
                 Phase 7                     Phase 8
                (Caching)               (Schema Validation)
```

**Critical Path:** Phases 1-2 must complete before any migrations.
**Parallel Work:** Phases 7-8 can be done independently after Phase 6.

---

## Success Metrics

1. **✅ Zero duplicate YAML parsers** - All parsing uses `lib/yaml-write.sh`
2. **✅ Consistent error handling** - All parsers validate and report errors uniformly
3. **✅ yq optimization** - All parsers benefit from yq when installed
4. **✅ Reduced code** - Remove ~150 lines of duplicate parsing logic
5. **✅ Better tests** - Centralized testing with >90% coverage
6. **✅ Easier maintenance** - Single location for YAML parsing changes

---

## Risk Mitigation

### Risk: Breaking existing scripts
**Mitigation:**
- Add new functions first, don't modify existing ones
- Replace one script at a time
- Run tests after each replacement
- Keep backups of original code

### Risk: Performance regression
**Mitigation:**
- Benchmark before and after
- yq should be faster than awk for complex queries
- awk fallback preserves original performance

### Risk: Incompatibility with edge cases
**Mitigation:**
- Test with all existing nwp.yml variations
- Test with .verification.yml
- Test with example.nwp.yml
- Add edge case tests

---

## Benefits

### For Developers
- Single, well-documented API for YAML operations
- No need to write custom awk parsers
- Consistent error messages
- Better IDE autocomplete (function names)

### For Maintainers
- One location to fix bugs
- One location to add features
- One location to optimize
- Easier code review

### For Users
- More reliable parsing
- Better error messages
- Faster operations (with yq)
- Consistent behavior

---

## Alternative Considered: Separate yaml-read.sh

The deep analysis suggested creating a separate `lib/yaml-read.sh` wrapper. We decided against this because:

1. **`lib/yaml-write.sh` already has reading functions** - No need to split
2. **Naming is confusing** - "yaml-write.sh" already does reads
3. **More files to maintain** - Better to keep related functions together
4. **Historical reason** - yaml-write.sh was created first, has established usage

**Decision:** Keep everything in `lib/yaml-write.sh` and optionally rename it to `lib/yaml.sh` in the future if the "write" name becomes too misleading.

---

## Implementation Options

Four approaches were considered for this consolidation:

### Option A: Adopt Pleasy Pattern (Hybrid) - NOT RECOMMENDED

Add a `yaml_load_all` function using conflation for read-heavy scripts:

```bash
yaml_load_all() {
    local config_file="${1:-$YAML_CONFIG_FILE}"
    local prefix="${2:-cfg}"

    if command -v yq &>/dev/null; then
        eval "$(yq eval -o=shell "$config_file" | sed "s/^/$prefix_/")"
    else
        eval "$(parse_yaml_to_vars "$config_file" "$prefix")"
    fi
}
```

**Verdict:** Doesn't solve write problem, namespace pollution, security concerns.

### Option B: Consolidate to Single Parser - RECOMMENDED

Implement the proposed `yaml_get_setting()` and related functions in Phase 1.

**Verdict:** Consistent, testable, maintainable. This proposal follows this approach.

### Option C: yq-First with AWK Fallback

Make yq the primary parser, keep AWK only for yq-less systems:

```bash
yaml_get() {
    local path="$1"
    local file="${2:-$YAML_CONFIG_FILE}"

    if command -v yq &>/dev/null; then
        yq eval ".$path // \"\"" "$file"
    else
        _yaml_get_awk "$path" "$file"
    fi
}
```

**Verdict:** Good approach, incorporated into Option B implementation.

### Option D: Hybrid with Caching (Future Phase 7)

Combine pleasy's caching with NWP's structure:

```bash
declare -gA YAML_CACHE

yaml_get_cached() {
    local key="$1"
    local file="${2:-$YAML_CONFIG_FILE}"
    local cache_key="${file}::${key}"

    if [[ -z "${YAML_CACHE[$cache_key]+x}" ]]; then
        YAML_CACHE[$cache_key]=$(yaml_get "$key" "$file")
    fi
    echo "${YAML_CACHE[$cache_key]}"
}
```

**Verdict:** Best of both worlds for hot paths. Requires bash 4+ (associative arrays). Defer to Phase 7.

---

## Industry Best Practices

### yq (Mike Farah's Go Implementation)

The de facto standard for YAML in shell:

```bash
# Read nested value
yq eval '.sites.mysite.directory' nwp.yml

# Update value in place
yq eval -i '.sites.mysite.enabled = true' nwp.yml

# Delete key
yq eval -i 'del(.sites.oldsite)' nwp.yml

# Merge files
yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' base.yml overlay.yml
```

### YAML Anchors & Aliases

Pleasy's parser supports YAML anchors; NWP's AWK parsers don't:

```yaml
defaults: &defaults
  dev: y
  webroot: docroot

sites:
  mysite:
    <<: *defaults
    directory: sites/mysite
```

**Recommendation:** Rely on yq for anchor support; document AWK fallback limitation.

### Security Considerations

NWP already has these (pleasy doesn't):

```bash
# From yaml-write.sh - KEEP THESE
if [[ "$name" == *".."* ]] || [[ "$name" == *"/"* ]]; then
    echo "Error: Site name cannot contain path components" >&2
    return 1
fi
```

---

## Priority Matrix

| Priority | Task | Effort | Impact | Dependencies |
|----------|------|--------|--------|--------------|
| 1 | Add `yaml_get_setting()` | Low | High | None |
| 2 | Add `yaml_get_array()` | Low | Medium | None |
| 3 | Replace `lib/cloudflare.sh` duplicate | Low | Medium | Priority 1 |
| 4 | Replace `lib/linode.sh` duplicate | Medium | Medium | Priority 1 |
| 5 | Replace `lib/common.sh` get_secret variants | Medium | High | Priority 1-2 |
| 6 | Add comprehensive tests | Medium | High | Priority 1-2 |
| 7 | Implement caching (Phase 7) | High | Low | Priority 1-6 |

---

## Decision Record

### Decision: Keep yaml-write.sh as Canonical Source

**Considered:**
1. Create new `lib/yaml.sh` fresh
2. Adopt pleasy's `parse_yaml.sh` approach
3. Extend existing `lib/yaml-write.sh`

**Chosen:** Option 3 - Extend existing `lib/yaml-write.sh`

**Rationale:**
- Already has 18 working functions with tests
- Has security validation (pleasy lacks this)
- Has write support (pleasy is read-only)
- Has backup/restore capability
- Renaming to `lib/yaml.sh` can happen in Phase 5

### Decision: yq-First, AWK Fallback

**Considered:**
1. AWK only (maximum portability)
2. yq only (maximum robustness)
3. yq-first with AWK fallback

**Chosen:** Option 3 - yq-first with AWK fallback

**Rationale:**
- yq handles edge cases (anchors, complex nesting, multiline)
- AWK ensures NWP works on minimal systems
- Already implemented in `yaml_validate()`, extend pattern

### Decision: No Pleasy-Style Global Variables

**Considered:**
1. Adopt pleasy conflation pattern
2. Keep function-based access

**Chosen:** Option 2 - Keep function-based access

**Rationale:**
- Write support required for site registry
- Security validation required
- Namespace pollution undesirable
- Caching in Phase 7 provides performance benefits without drawbacks

---

## Conclusion

The consolidation of duplicate YAML parsers is a straightforward refactoring that will:
- Eliminate ~150 lines of duplicate code across 7 files
- Unify ~30 scattered functions into one library
- Improve maintainability with single source of truth
- Enable yq optimization across all scripts
- Provide consistent error handling and security validation
- Make the codebase easier to understand

The pleasy analysis confirmed that NWP's approach (function-based with write support) is correct for our use case, while identifying the caching optimization as a valuable future enhancement.

The work can be done incrementally with minimal risk, and the benefits compound over time as the system grows.

**Status:** Ready for implementation
**Priority:** Medium (Code quality improvement, not urgent)
**Effort:** 4 weeks part-time
**Risk:** Low (incremental changes with testing)

---

## Appendix: Function Migration Map

| Current Function | File | Migrate To |
|-----------------|------|------------|
| `get_recipe_value()` | install-common.sh | `yaml_get_setting()` or new `yaml_get_recipe_field()` |
| `get_recipe_list_value()` | install-common.sh | `yaml_get_array()` |
| `get_settings_value()` | install-common.sh | `yaml_get_setting()` |
| `get_secret()` | common.sh | `yaml_get_setting()` with secrets file |
| `get_secret_nested()` | common.sh | `yaml_get_setting()` with dot notation |
| `get_data_secret()` | common.sh | Keep separate (security boundary) |
| `parse_yaml_value()` | linode.sh | `yaml_get_setting()` |
| `get_developer_*()` | developer.sh | Keep (yq-only is fine) |
| Inline grep+awk | state.sh | `yaml_get_site_field()` |

## Appendix: Pleasy parse_yaml.sh Reference

For reference, the core algorithm from pleasy (139 lines):

```bash
# Key insight: Track indent level to build variable names
indent = length($1)/length("  ");
vname[indent] = $2;
for (i in vname) {if (i > indent) {delete vname[i]}}
for (i=0; i<indent; i++) { vn=(vn)(vname[i])("_")}
printf("%s=\"%s\"\n", vn vname[indent], value);
```

This elegant solution trades off:
- ✅ Fast access (no file I/O after parse)
- ✅ Simple syntax (`${!varname}`)
- ❌ No write support
- ❌ No validation
- ❌ Global namespace pollution

NWP chooses the function-based approach for safety and write capability, with optional caching in Phase 7 for performance-critical paths.
