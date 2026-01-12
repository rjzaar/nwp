# contribute

Submit contributions to upstream repository via merge request.

## Overview

The `contribute` command helps you submit contributions to the upstream NWP repository. It runs tests, checks prerequisites, generates a merge request description, and creates the MR using GitLab CLI (glab or gh).

## Usage

```bash
pl contribute [options]
```

## Options

| Flag | Description |
|------|-------------|
| `--branch <name>` | Feature branch name (auto-detected if omitted) |
| `--title <title>` | MR title (auto-generated from commits if omitted) |
| `--draft` | Create as draft MR |
| `--no-tests` | Skip running tests before creating MR |
| `--help, -h` | Show help message |

## Examples

### Auto-detect branch and run tests
```bash
pl contribute
```

### Create draft MR
```bash
pl contribute --draft
```

### Custom title
```bash
pl contribute --title "Fix bug #123"
```

### Skip tests (not recommended)
```bash
pl contribute --no-tests
```

## Prerequisites

Before running contribute, ensure:

1. **Upstream Configured**: Run `pl upstream configure`
2. **GitLab CLI Installed**: Install `glab` or `gh`
3. **Changes Committed**: All changes committed to feature branch
4. **Tests Passing**: Tests should pass (run automatically)

## Pre-flight Checks

The command performs these checks:

1. **Git Repository**: Verifies you're in a git repository
2. **Uncommitted Changes**: Ensures working directory is clean
3. **Upstream Remote**: Checks upstream is configured
4. **Feature Branch**: Ensures you're not on main/master
5. **Commits to Contribute**: Verifies you have new commits
6. **GitLab CLI**: Checks for glab or gh

## Test Execution

Unless `--no-tests` is specified, the command:

1. Runs `test-nwp.sh`
2. Captures test output
3. Fails if tests don't pass
4. Includes test status in MR description

## MR Description Generation

The generated MR includes:

### Summary Section
- Single commit: Uses commit message and body
- Multiple commits: Lists all commits with bullets

### Test Plan Section
- Test execution status
- Manual testing checklist
- Documentation update reminder

### Related Issues Section
- Placeholder for issue links
- Supports `Closes #123`, `Related to #456` syntax

### Footer
- Generated with Claude Code attribution

## GitLab CLI Support

Supports two CLI tools:

**glab** (GitLab CLI):
```bash
glab mr create --title "..." --description "..." --source-branch ...
```

**gh** (GitHub CLI):
```bash
gh pr create --title "..." --body "..." --base main --head ...
```

Auto-detects which tool is available.

## Branch Management

The command automatically:
- Detects current branch name
- Pushes branch to origin with `-u` flag
- Sets up tracking for the branch
- Creates MR from branch to main

## Decision Compliance

Checks for uncommitted decision records in `docs/decisions/` and warns if found.

## Manual MR Creation

If GitLab CLI is not available, the command:
- Provides the MR URL with query parameters
- Displays the generated description
- Allows manual MR creation via web interface

## Workflow Example

```bash
# 1. Create feature branch
git checkout -b feature/my-feature

# 2. Make changes and commit
git add .
git commit -m "Add new feature"

# 3. Submit contribution
pl contribute

# 4. Address feedback in MR
# Make changes, commit, push

# 5. MR gets merged
```

## Draft MRs

Use `--draft` flag for:
- Work in progress
- Early feedback
- Complex features needing discussion

Draft MRs:
- Show [Draft] prefix
- Don't trigger auto-merge
- Can be marked ready later

## Related Commands

- [upstream.sh](upstream.md) - Configure upstream repository
- [test-nwp.sh](test-nwp.md) - Run tests before contributing
- [coders.sh](coders.md) - Manage contributor accounts

## See Also

- `docs/DISTRIBUTED_CONTRIBUTION_GOVERNANCE.md` - Contribution guidelines
- `docs/decisions/` - Architecture Decision Records
- GitLab MR documentation
