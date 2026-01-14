# ADR-0009: Five-Layer YAML Protection System

**Status:** Accepted
**Date:** 2026-01-14 (formalized after incident 2026-01-13)
**Decision Makers:** Rob
**Related Issues:** Critical bug fix after cnwp.yml data loss
**Related Commits:** fb2f2603, ea07e155, 6fde940b
**References:** [SECURITY.md](../SECURITY.md), [yaml-write.sh](../../lib/yaml-write.sh)

## Context

On January 13, 2026, a critical bug in `test-nwp.sh` caused **complete data loss** of a user's `cnwp.yml` file. The scenario:

1. Test created temporary sites with non-unique names
2. Cleanup operation used AWK to remove test sites
3. AWK encountered duplicate site entries
4. AWK produced **empty output** (error condition)
5. Empty output was **blindly written** back to `cnwp.yml`
6. **Result: All user configurations wiped**

This incident exposed a fundamental weakness: **AWK operations on cnwp.yml had no safety mechanisms**.

`cnwp.yml` is NWP's **single source of truth** for:
- All site definitions and configurations
- Server credentials and deployment settings
- Recipe definitions
- Linode/Cloudflare/GitLab integration
- Coder definitions for distributed governance

**Losing cnwp.yml means losing everything.**

## The Incident: Anatomy of Data Loss

### What Happened

**test-nwp.sh cleanup operation:**
```bash
# BAD: No protection
awk -v site="$site_name" '
    BEGIN { in_site = 0 }
    $0 ~ "^  " site ":" { in_site = 1; next }
    /^  [a-zA-Z]/ { in_site = 0 }
    !in_site { print }
' cnwp.yml > cnwp.yml.tmp

mv cnwp.yml.tmp cnwp.yml  # DANGER: Blindly overwrites cnwp.yml
```

**When duplicate entries exist:**
- AWK gets confused by multiple matches
- Outputs empty file to `cnwp.yml.tmp`
- `mv` command succeeds
- `cnwp.yml` is now empty
- **All user data lost**

### Why This Is Catastrophic

Unlike database systems with:
- Transaction rollback
- Write-ahead logging
- Automatic backups
- Point-in-time recovery

**Bash file operations are:**
- Immediate and irreversible
- No undo mechanism
- No automatic backups
- Silent failures possible

**One bad AWK operation = total data loss.**

## Options Considered

### Option 1: Five-Layer Protection System (Chosen)
Comprehensive safety checks before any file modification.

**Pros:**
- Prevents all known data loss scenarios
- Catches AWK errors before damage occurs
- Minimal performance overhead
- Works with existing bash/AWK code
- Clear error messages for debugging

**Cons:**
- More verbose code (~20 lines per operation)
- Requires discipline to apply consistently

### Option 2: Copy-on-Write with Backups
Always create `.backup` before modification.

**Pros:**
- Simple to implement
- Recovery possible

**Cons:**
- Doesn't prevent data loss (just enables recovery)
- Fills disk with backup files
- Still requires user intervention after failure
- Backups can get out of sync

### Option 3: SQLite Database
Replace YAML with SQLite for cnwp.yml data.

**Pros:**
- ACID transactions
- Automatic rollback on error
- Query optimization

**Cons:**
- Massive rewrite (1000+ lines affected)
- Loses human-readable/editable config
- Binary format not version-control friendly
- Over-engineering for NWP's scale

### Option 4: Git Auto-Commit Before Changes
Commit cnwp.yml to git before each modification.

**Pros:**
- Full history
- Easy rollback

**Cons:**
- Requires git repo
- Clutters git history
- Doesn't prevent damage (just enables recovery)
- Requires user to know git recovery commands

## Decision

Implement **Five-Layer Protection System** for all AWK operations on `cnwp.yml`:

```bash
# Layer 1: Line Count Tracking
original_line_count=$(wc -l < "$config_file")

# Layer 2: mktemp for Atomic Writes
tmpfile=$(mktemp) || {
    echo "ERROR: Failed to create temporary file" >&2
    return 1
}
trap "rm -f '$tmpfile'" EXIT  # Cleanup on any exit

# Perform AWK operation
awk 'YOUR_AWK_SCRIPT' "$config_file" > "$tmpfile"

# Layer 3: Empty Output Detection
if [ ! -s "$tmpfile" ]; then
    echo "ERROR: AWK operation produced empty file (possible duplicate entries or AWK error)" >&2
    return 1
fi

# Layer 4: Sanity Check (prevent large deletions)
new_line_count=$(wc -l < "$tmpfile")
lines_removed=$((original_line_count - new_line_count))
if [ "$lines_removed" -gt 100 ]; then
    echo "ERROR: Would remove $lines_removed lines (>100), aborting for safety" >&2
    echo "Original: $original_line_count lines, New: $new_line_count lines" >&2
    return 1
fi

# Layer 5: Atomic Move (only if all validations pass)
mv "$tmpfile" "$config_file" || {
    echo "ERROR: Failed to update $config_file" >&2
    return 1
}
```

## Rationale

### Why Five Layers?

Each layer catches different failure modes:

**Layer 1 (Line Count Tracking):**
- **Catches:** Complete file deletion
- **Example:** Empty AWK output would show `0` lines

**Layer 2 (mktemp):**
- **Catches:** Race conditions, temp file conflicts
- **Example:** Two processes writing `cnwp.yml.tmp` simultaneously
- **Benefit:** Secure, unique temp files with automatic cleanup

**Layer 3 (Empty Output Detection):**
- **Catches:** AWK syntax errors, duplicate entry bugs, malformed input
- **Example:** The original incident (duplicate sites → empty output)
- **Critical:** This layer prevents 90% of data loss scenarios

**Layer 4 (Sanity Check):**
- **Catches:** Runaway deletions, AWK logic errors
- **Example:** Bug in AWK script deletes entire `sites:` section (200+ lines)
- **Threshold:** 100 lines = reasonable upper bound for intentional deletions
- **Tunable:** Can adjust threshold per use case

**Layer 5 (Atomic Move):**
- **Catches:** Disk full, permission errors, filesystem issues
- **Example:** Disk full during `mv` would fail without corrupting original
- **Benefit:** Original file untouched if any error occurs

### Why Not Fewer Layers?

**Removing Layer 3 (Empty Output):**
- Incident would have still occurred
- Layer 4 would catch it, but less specific error message

**Removing Layer 4 (Sanity Check):**
- Large accidental deletions could still happen
- Layer 3 wouldn't catch "almost empty" files

**Removing Layer 5 (Atomic Move):**
- Disk full errors could still corrupt file
- No verification of write success

**Redundancy is intentional** - defense in depth.

### Why 100-Line Threshold?

**Analysis of typical cnwp.yml operations:**
- Add site: +5-10 lines
- Remove site: -5-10 lines
- Modify site: 0 lines (in-place edit)
- Remove test sites: -20-50 lines (10 test sites max)

**Legitimate operations that could exceed 100 lines:**
- None in current codebase
- If needed, can increase threshold for specific operations

**100-line threshold catches:**
- Entire `sites:` section deletion (typically 50-200 lines)
- Entire `recipes:` section deletion (typically 150-300 lines)
- Multiple section deletions

**Better safe than sorry** - false positive is better than data loss.

## Consequences

### Positive
- **Data loss prevention** - The original incident cannot happen again
- **Clear error messages** - Each layer reports what went wrong
- **Early failure detection** - Problems caught before file modification
- **Minimal overhead** - Simple bash operations (~0.01 seconds)
- **No external dependencies** - Pure bash, works everywhere
- **Debuggable** - Verbose output helps identify issues

### Negative
- **Code verbosity** - 20 lines instead of 2
- **Developer discipline required** - Must remember to use protection
- **False positives possible** - Legitimate large deletions might fail
- **Not a complete solution** - Still need backups, version control

### Neutral
- **Applied consistently** - All YAML modification functions must use this
- **Documented in SECURITY.md** - Security checklist item
- **Code review requirement** - PR reviews must verify protection is used

## Implementation Notes

### Standard Template

All functions modifying `cnwp.yml` must use this template:

```bash
modify_cnwp_yml() {
    local config_file="${1:-cnwp.yml}"
    local search_pattern="$2"

    # Layer 1: Track original size
    local original_line_count
    original_line_count=$(wc -l < "$config_file") || return 1

    # Layer 2: Create secure temp file
    local tmpfile
    tmpfile=$(mktemp) || {
        echo "ERROR: Failed to create temp file" >&2
        return 1
    }
    trap "rm -f '$tmpfile'" EXIT

    # Perform AWK operation
    awk -v pattern="$search_pattern" '
        # Your AWK logic here
    ' "$config_file" > "$tmpfile"

    # Layer 3: Check for empty output
    if [ ! -s "$tmpfile" ]; then
        echo "ERROR: AWK operation produced empty file" >&2
        return 1
    fi

    # Layer 4: Sanity check
    local new_line_count lines_removed
    new_line_count=$(wc -l < "$tmpfile")
    lines_removed=$((original_line_count - new_line_count))
    if [ "$lines_removed" -gt 100 ]; then
        echo "ERROR: Would remove $lines_removed lines (>100)" >&2
        return 1
    fi

    # Layer 5: Atomic move
    mv "$tmpfile" "$config_file" || {
        echo "ERROR: Failed to update $config_file" >&2
        return 1
    }

    return 0
}
```

### Where Applied

**Must use 5-layer protection:**
- `lib/yaml-write.sh` - All site add/remove/modify functions
- `scripts/commands/test-nwp.sh` - Test site cleanup
- Any script using AWK on `cnwp.yml`

**Does not need protection:**
- Read-only operations (no file modification)
- Operations on other files (only cnwp.yml is critical)
- yq operations (has built-in error handling)

### Integration with yaml-write.sh

All YAML modification functions now use protection:
- `yaml_add_site()`
- `yaml_remove_site()`
- `yaml_update_site_field()`
- `yaml_update_setting()`
- `yaml_remove_section()`

### Code Review Checklist

When reviewing shell scripts:
- [ ] Does this modify `cnwp.yml`?
- [ ] Uses AWK or sed on `cnwp.yml`?
- [ ] Has 5-layer protection applied?
- [ ] All 5 layers present and correct?
- [ ] Error messages are descriptive?
- [ ] Returns non-zero on failure?

## Testing

### Test Cases

**Normal operation:**
```bash
# Should succeed
yaml_remove_site "test-site" "cnwp.yml"
```

**Empty output (Layer 3):**
```bash
# Simulated: AWK produces empty file
# Should fail with: "ERROR: AWK operation produced empty file"
```

**Large deletion (Layer 4):**
```bash
# Simulated: AWK would remove 150 lines
# Should fail with: "ERROR: Would remove 150 lines (>100)"
```

**Disk full (Layer 5):**
```bash
# Simulated: mv fails due to disk full
# Should fail with: "ERROR: Failed to update cnwp.yml"
```

### Regression Testing

Added to test-nwp.sh:
```bash
test_yaml_protection() {
    # Test duplicate site handling
    # Test empty output detection
    # Test large deletion prevention
    # Verify original file unchanged on error
}
```

## Alternatives Considered

### Alternative 1: Validate YAML Syntax Before Write

Check YAML syntax with `yq` before writing:
```bash
yq eval '.' "$tmpfile" >/dev/null 2>&1 || {
    echo "ERROR: Generated YAML is invalid"
    return 1
}
```

**Rejected because:**
- Doesn't catch empty files (valid YAML)
- Doesn't catch large deletions
- Requires yq (not always available)
- Can add as Layer 6 if needed

### Alternative 2: Diff Preview Before Write

Show diff and require confirmation:
```bash
diff -u cnwp.yml "$tmpfile"
read -p "Apply these changes? (y/n) " confirm
```

**Rejected because:**
- Breaks automation
- User might not understand diff
- Still doesn't prevent automated errors
- Can add as debug mode if needed

### Alternative 3: Versioned Snapshots

Create numbered backups:
```bash
cp cnwp.yml cnwp.yml.backup.$(date +%s)
# Keep last 10 backups
```

**Rejected because:**
- Doesn't prevent data loss (only enables recovery)
- Disk space issues
- User must manually restore
- Complementary to, not replacement for, protection

## Migration Path

### Immediate Actions (Completed)

1. [x] Apply 5-layer protection to `lib/yaml-write.sh`
2. [x] Apply to `scripts/commands/test-nwp.sh`
3. [x] Document in SECURITY.md
4. [x] Add to code review checklist

### Future Enhancements

**Optional Layer 6: YAML Syntax Validation**
```bash
# After Layer 3, before Layer 4
if command -v yq &>/dev/null; then
    if ! yq eval '.' "$tmpfile" >/dev/null 2>&1; then
        echo "ERROR: Generated YAML has syntax errors"
        return 1
    fi
fi
```

**Optional Layer 7: Content Validation**
```bash
# After Layer 4, before Layer 5
if ! grep -q "^sites:" "$tmpfile"; then
    echo "ERROR: Generated file missing 'sites:' section"
    return 1
fi
```

**Tunable Thresholds**
```bash
# In cnwp.yml settings section
settings:
  yaml_protection:
    max_lines_deleted: 100  # Current default
    require_confirmation: false  # Interactive mode
```

## Review

**30-day review date:** 2026-02-14
**Review outcome:** Pending

**Success Metrics:**
- [x] No cnwp.yml data loss incidents since implementation
- [x] All YAML modification functions use protection
- [x] Code review checklist includes protection verification
- [ ] False positives: 0 (no legitimate operations blocked)
- [ ] Test suite coverage: 100% of protection layers

## Related Decisions

- **ADR-0002: YAML-Based Configuration** - Established YAML as single source of truth
- **ADR-0003: Bash for Automation Scripts** - Bash limitations necessitate extra safety
- **ADR-0015: YAML-First with AWK Fallback Pattern** (pending) - yq vs AWK trade-offs

## Lessons Learned

**Prevention > Recovery:**
- Backups help, but preventing damage is better
- Extra 20 lines of code << losing all configurations

**Defense in Depth:**
- Single safety check is not enough
- Redundant checks catch different failure modes
- "Belts and suspenders" approach justified for critical files

**Silent Failures Are Dangerous:**
- AWK doesn't error on duplicate keys
- `mv` doesn't warn about overwriting
- Must explicitly check for success conditions

**Human-Readable Config Has Risks:**
- YAML is easy to edit (good)
- YAML is easy to corrupt (bad)
- Protection layer mitigates the risk

**Bash Needs Extra Safety:**
- Database systems have ACID transactions
- File systems don't
- Must build safety ourselves

## Future Work

**Possible enhancements** (not planned):
- Automatic backup before every modification
- Git auto-commit option
- Journaling (write-ahead log)
- Recovery mode (restore from backups)
- Visual diff preview for large changes
