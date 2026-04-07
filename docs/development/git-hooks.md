# Git Hooks

Git hooks are automated scripts that run at specific points in the Git workflow. NWP uses git hooks to enforce code quality standards and prevent common mistakes.

## Overview

NWP provides two git hooks:

| Hook | When it Runs | Purpose |
|------|--------------|---------|
| `pre-commit` | Before each commit | Validates files, checks documentation dates, prevents committing protected files |
| `commit-msg` | After commit message entry | Validates commit message format and length |

## Pre-commit Hook

**Location:** `.git/hooks/pre-commit`

The pre-commit hook runs automatically before each commit and performs the following checks:

### 1. Protected File Check

**Prevents committing `nwp.yml`**

The `nwp.yml` file contains user-specific site configurations and must never be committed to git.

```
ERROR: Attempting to commit nwp.yml

nwp.yml contains user-specific site configurations and must never be committed.

If you need to update the configuration template:
  - Edit example.nwp.yml instead
  - Each user has their own local nwp.yml file

To unstage nwp.yml:
  git reset HEAD nwp.yml
```

**Why this exists:**
- `nwp.yml` is in `.gitignore` for a reason
- Each user has their own local site configurations
- `example.nwp.yml` serves as the template for new installations
- Users copy `example.nwp.yml` to `nwp.yml` and customize it

### 2. Documentation Date Check

**Warns about stale "Last Updated" dates**

For any `.md` file in the `docs/` directory being committed, the hook checks:
- Does the file have a "Last Updated" date?
- Is the date more than 7 days old?

```
WARNING: docs/guides/quickstart.md
  Last Updated: 2025-12-15 (more than 7 days old)
  Consider updating the date to: 2026-01-14
```

**Why this exists:**
- Keeps documentation dates accurate
- Helps users know if documentation is current
- Encourages updating docs when making changes

**Note:** This is a warning only. Commits will still proceed, but you should consider updating the date if the content has changed.

### 3. Command Documentation Structure

**Validates required sections in command documentation**

For files in `docs/reference/commands/` (excluding README.md), the hook checks for:
- Overview or Description section
- Usage or Syntax section
- Examples section

```
WARNING: docs/reference/commands/backup.md
  Missing recommended sections:
  - Examples section
```

**Why this exists:**
- Ensures consistent documentation structure
- Makes command documentation more useful
- Helps contributors know what to include

**Note:** This is a warning only. Commits will proceed even with missing sections.

### Sample Output

**Success (no issues):**
```
Running NWP pre-commit checks...

Checking Last Updated dates in documentation files...

Validating command documentation structure...

All pre-commit checks passed!
```

**With warnings:**
```
Running NWP pre-commit checks...

Checking Last Updated dates in documentation files...
WARNING: docs/guides/quickstart.md
  Last Updated: 2025-12-15 (more than 7 days old)
  Consider updating the date to: 2026-01-14

Pre-commit checks passed with 1 warning(s)

Warnings are advisory only. Commit will proceed.
To bypass warnings in the future: git commit --no-verify
```

**With errors:**
```
Running NWP pre-commit checks...

ERROR: Attempting to commit nwp.yml

nwp.yml contains user-specific site configurations and must never be committed.

Pre-commit check failed with 1 error(s)

To bypass this hook (not recommended):
  git commit --no-verify
```

## Commit-msg Hook

**Location:** `.git/hooks/commit-msg`

The commit-msg hook runs after you enter your commit message and validates the message format.

### Validations

#### 1. Non-empty Message

Commit messages must not be empty.

```
ERROR: Empty commit message

Commit messages must not be empty.

Please provide a meaningful commit message describing your changes.
```

#### 2. Minimum Length

The first line must be at least 10 characters.

```
ERROR: Commit message too short

First line: "Fix bug"
Length: 7 characters

Commit messages should be at least 10 characters to be meaningful.

Good examples:
  - Fix backup restoration for staging sites
  - Add validation to dev2stg workflow
  - Update documentation for install command
```

#### 3. Maximum Length

The first line must not exceed 500 characters.

```
ERROR: Commit message first line too long

First line length: 523 characters

The first line should be a concise summary (< 500 characters).
Use additional lines for detailed explanation.
```

#### 4. Conventional Length Warning

If the first line exceeds 72 characters (Git convention), you'll get a warning:

```
WARNING: Commit message first line is long (95 chars)

Convention suggests keeping the first line under 72 characters.
This is advisory only - commit will proceed.
```

**Note:** This is a warning only. Commits will still proceed.

### Sample Output

**Success:**
```
(No output - commit proceeds normally)
```

**With error:**
```
ERROR: Commit message too short

First line: "Fix bug"
Length: 7 characters

Commit messages should be at least 10 characters to be meaningful.
```

## Bypassing Hooks

In rare cases, you may need to bypass git hooks. Use the `--no-verify` flag:

```bash
git commit --no-verify -m "Emergency fix"
```

### When to Bypass

**Legitimate reasons:**
- Emergency hotfix that needs immediate deployment
- Committing work-in-progress to a feature branch
- Automated commits from CI/CD systems
- When hooks are genuinely incorrect (then fix the hook!)

**Not legitimate reasons:**
- "The hook is annoying"
- "I don't want to update the date"
- "My commit message is fine" (when it's actually too short)

### Best Practice

If you find yourself frequently using `--no-verify`:
1. Consider whether the hook is overly strict
2. Open an issue to discuss adjusting the hook
3. Submit a PR to improve the hook logic

## Hook Installation

Git hooks in `.git/hooks/` are **not** tracked by Git. They are installed automatically by:

1. **Initial setup:** Running `./setup.sh` copies hooks to `.git/hooks/`
2. **Manual installation:** Copy hooks from `.hooks/` (if we add that directory)

**Current approach:** Hooks are created directly in `.git/hooks/` and documented here.

## Troubleshooting

### Hook Not Running

If hooks don't run automatically:

1. **Check if executable:**
   ```bash
   ls -la .git/hooks/pre-commit
   ls -la .git/hooks/commit-msg
   ```

   Should show `-rwxr-xr-x` (executable permissions).

2. **Make executable:**
   ```bash
   chmod +x .git/hooks/pre-commit
   chmod +x .git/hooks/commit-msg
   ```

3. **Verify hook exists:**
   ```bash
   cat .git/hooks/pre-commit
   cat .git/hooks/commit-msg
   ```

### Hook Reports Wrong Date

If the date check fails incorrectly:

1. **Check system date:**
   ```bash
   date +%Y-%m-%d
   ```

2. **Check date format in file:**
   Must be `YYYY-MM-DD` format, e.g., `2026-01-14`

3. **Common patterns recognized:**
   - `Last Updated: 2026-01-14`
   - `Updated: 2026-01-14`
   - Case-insensitive

### Hook Fails on Bash Syntax

If you see errors like `date: invalid option`:

1. **Check Bash version:**
   ```bash
   bash --version
   ```

   Hooks require Bash 4.0+.

2. **Verify date command:**
   ```bash
   date -d "2026-01-14" +%s
   ```

   Should output Unix timestamp.

### Disabling Hooks Temporarily

To temporarily disable hooks during development:

```bash
# Rename hooks
mv .git/hooks/pre-commit .git/hooks/pre-commit.disabled
mv .git/hooks/commit-msg .git/hooks/commit-msg.disabled

# Re-enable later
mv .git/hooks/pre-commit.disabled .git/hooks/pre-commit
mv .git/hooks/commit-msg.disabled .git/hooks/commit-msg
```

Or use `--no-verify` on individual commits.

## Customizing Hooks

### Adjusting Date Warning Threshold

Edit `.git/hooks/pre-commit` and change:

```bash
seven_days_ago=$((current_timestamp - 604800))  # 7 days in seconds
```

To a different value:
- 1 day: 86400
- 3 days: 259200
- 14 days: 1209600
- 30 days: 2592000

### Adding New Protected Files

To prevent committing additional files, add to the pre-commit hook:

```bash
if git diff --cached --name-only | grep -q "^.secrets.yml$"; then
    echo -e "${RED}ERROR: Attempting to commit .secrets.yml${NC}"
    # ... error message ...
    errors=$((errors + 1))
fi
```

### Adding Custom Validations

Add new validation sections following the existing pattern:

```bash
# ============================================================================
# Check 4: Your Custom Check
# ============================================================================

# Your validation logic here
if [ condition ]; then
    echo -e "${RED}ERROR: Description${NC}"
    errors=$((errors + 1))
fi
```

## Related Documentation

- [CLAUDE.md](../../CLAUDE.md) - Protected files and git commit workflow
- [Developer Workflow](../guides/developer-workflow.md) - Complete development lifecycle
- [Contribution Workflow](../governance/distributed-contribution-governance.md) - Security review process

---

Last Updated: 2026-01-14
