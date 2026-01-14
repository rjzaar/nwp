# ADR-0014: Git Hooks for Documentation Enforcement

**Status:** Accepted
**Date:** 2026-01-14 (v0.23.0)
**Decision Makers:** Rob
**Related Issues:** Documentation standards, v0.23.0 major documentation release
**Related Commits:** 8e19d5ab (comprehensive documentation)
**References:** [git-hooks.md](../development/git-hooks.md), [.git/hooks/pre-commit](../../.git/hooks/pre-commit)

## Context

After v0.23.0's massive documentation effort (100% command coverage, 35 files, 17,235 lines added), a problem emerged:

**How to maintain documentation quality going forward?**

Issues:
1. **Documentation drift** - Code changes, docs don't update
2. **Stale dates** - "Last Updated" dates months old
3. **Missing documentation** - New commands added without docs
4. **Protected files** - cnwp.yml must never be committed (user-specific)

Traditional solutions:
- **Manual reviews** - Error-prone, inconsistent
- **CI checks** - Too late (already committed)
- **Lint tools** - Don't catch semantic issues

## Decision

Implement **client-side git hooks** for pre-commit validation:

**Hook 1: pre-commit** - Prevents bad commits before they happen
- Block commits of cnwp.yml (user-specific config)
- Warn about outdated documentation (Last Updated > 7 days ago)
- Validate command documentation structure

**Hook 2: commit-msg** - Ensures quality commit messages
- Require minimum message length (10 chars)
- Warn about overly long first lines (>72 chars)
- Prevent empty commit messages

## Rationale

### Why Git Hooks?

**Alternatives considered:**

**1. CI/CD checks (GitLab CI)**
- **Problem:** Too late (already committed and pushed)
- **Result:** Must force-push to fix, messy history
- **When useful:** Final safety net, not primary prevention

**2. Pre-push hooks**
- **Problem:** Batch of commits already made
- **Result:** Hard to fix without rewriting history
- **When useful:** Expensive operations (full test suite)

**3. Manual code review**
- **Problem:** Reviewer burden, inconsistent
- **Result:** Issues slip through
- **When useful:** Complex logic, architecture decisions

**4. Client-side pre-commit hooks (CHOSEN)**
- **Benefit:** Catch issues before commit
- **Result:** Clean history, immediate feedback
- **Trade-off:** Must be installed locally

### Why pre-commit vs pre-push?

**pre-commit advantages:**
- Immediate feedback (before commit is created)
- Easy to fix (files still staged, not committed)
- Cleaner git history (bad commits never created)
- Per-commit validation (not batch)

**pre-push disadvantages:**
- Multiple commits might be bad
- Hard to fix without rewriting history
- All-or-nothing (can't push good commits, leave bad)

**Decision:** Use pre-commit for cheap checks, pre-push for expensive checks (future).

### What to Enforce

**Critical (block commit):**
- cnwp.yml commits (user-specific, should never be committed)
- Empty commit messages

**Important (warn, allow bypass):**
- Outdated documentation (Last Updated > 7 days)
- Malformed command documentation
- Long commit message subject lines

**Not enforced:**
- Code style (use shellcheck separately)
- Test failures (use CI/CD)
- Documentation completeness (too subjective)

### cnwp.yml Protection

**The problem:**
```bash
# User accidentally:
git add -A
git commit -m "Update feature"
# cnwp.yml gets committed with their personal config
```

**The solution:**
```bash
# pre-commit hook checks:
if git diff --cached --name-only | grep -q "^cnwp.yml$"; then
    echo "ERROR: Refusing to commit cnwp.yml"
    echo "This file contains user-specific configuration"
    exit 1
fi
```

**Why this matters:**
- cnwp.yml is in .gitignore, but `git add -A` overrides
- Contains user paths, secrets references, server IPs
- Each user has different configuration
- example.cnwp.yml is the template, cnwp.yml is instance

**How to bypass (if really needed):**
```bash
git commit --no-verify  # Skips hooks
```

### Documentation Freshness

**The problem:**
- File modified: January 14, 2026
- "Last Updated: December 15, 2025"
- Reader sees month-old date, assumes stale

**The solution:**
```bash
# Check if doc files changed and dates are old
for file in docs/**/*.md; do
    if git diff --cached --name-only | grep -q "$file"; then
        last_updated=$(grep "Last Updated:" "$file" | awk '{print $3}')
        days_old=$(( ($(date +%s) - $(date -d "$last_updated" +%s)) / 86400 ))
        if [ "$days_old" -gt 7 ]; then
            echo "WARNING: $file has Last Updated: $last_updated ($days_old days ago)"
        fi
    fi
done
```

**Why 7 days?**
- Aggressive enough to catch issues
- Forgiving enough for minor edits
- Can be adjusted per project

**Why warning, not error?**
- Sometimes date is intentionally old (historical docs)
- Sometimes change doesn't warrant date update (typo fix)
- Trust developer judgment, but raise awareness

### Bypass Mechanism

**How to skip hooks:**
```bash
git commit --no-verify
```

**When to use:**
- False positives (hook is wrong)
- Emergency hotfix (no time for docs)
- Intentional exception (with reason)

**When NOT to use:**
- "I'll update docs later" (you won't)
- "Docs are annoying" (discipline > convenience)
- "Hook is slow" (make hook faster, don't skip)

## Consequences

### Positive
- **Prevents mistakes** - cnwp.yml protection catches accidents
- **Maintains quality** - Documentation stays fresh
- **Immediate feedback** - Before commit created
- **Automated enforcement** - No manual checking needed
- **Clean history** - Bad commits never created

### Negative
- **Installation required** - New developers must install hooks
- **Can be bypassed** - --no-verify defeats enforcement
- **False positives** - Sometimes warning is wrong
- **Slight friction** - Extra second per commit

### Neutral
- **Not mandatory** - Hooks can be bypassed if needed
- **Local only** - Each developer installs separately
- **Gradual adoption** - Can add more checks over time

## Implementation Notes

### Installation

**Automatic (during setup):**
```bash
./setup.sh --install-git-hooks
```

**Manual:**
```bash
cp git-hooks/pre-commit .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
```

### Hook Location

Git hooks stored in `.git/hooks/` (local, not version-controlled).

Template hooks stored in `git-hooks/` (version-controlled, copied to .git/hooks/).

### Hook Performance

**Fast checks only:**
- File name checks: <0.01s
- Date parsing: <0.1s
- Regex validation: <0.1s

**Total overhead:** <0.2s per commit

**Expensive checks (not in pre-commit):**
- Full test suite: 2+ minutes (use CI/CD)
- Shellcheck all files: 10+ seconds (use pre-push)
- YAML validation: 1+ second (use pre-push)

### Hook Development

**Guidelines:**
- Keep fast (<1 second total)
- Provide clear error messages
- Allow bypass with --no-verify
- Use exit 1 for errors, exit 0 for warnings
- Test on multiple shells (bash, zsh)

**Example structure:**
```bash
#!/bin/bash
# Description of hook

# Check 1: Critical (block)
if [critical_condition]; then
    echo "ERROR: ..."
    exit 1
fi

# Check 2: Warning (allow)
if [warning_condition]; then
    echo "WARNING: ..."
    # Don't exit, just warn
fi

exit 0
```

## Review

**30-day review date:** 2026-02-14
**Review outcome:** Pending

**Success Metrics:**
- [x] Hooks implemented and tested
- [x] Documentation written
- [ ] Adoption: % of developers with hooks installed
- [ ] Effectiveness: # of cnwp.yml commits prevented
- [ ] False positives: Minimal
- [ ] Performance: <0.5s per commit

## Related Decisions

- **ADR-0002: YAML-Based Configuration** - cnwp.yml protection
- **ADR-0009: Five-Layer YAML Protection** - File protection strategies
- **CLAUDE.md**: Release Tag Process - Documentation update checklist

## Future Enhancements

**Possible additions (not planned):**

**pre-push hook:**
- Run shellcheck on changed files
- Run YAML syntax validation
- Check for TODO/FIXME comments
- Verify test suite passes (optional, slow)

**prepare-commit-msg hook:**
- Auto-add issue number from branch name
- Template commit messages
- Add Co-Authored-By for pair programming

**post-commit hook:**
- Update CHANGELOG.md automatically
- Increment version numbers
- Generate commit statistics

**commit-msg enhancements:**
- Enforce conventional commits format
- Require issue references
- Spell-check commit messages
