# upstream

**Last Updated:** 2026-01-14

Sync local NWP repository with upstream in the distributed contribution governance model.

## Synopsis

```bash
pl upstream <command> [options]
```

## Description

The `upstream` command manages synchronization with upstream NWP repositories in the distributed governance model. It allows Tier 2 contributors to pull changes from Tier 1 maintainers, Tier 1 to pull from Tier 0 (core), and helps maintain a coordinated development workflow.

The command handles Git remotes, fetching updates, merging or rebasing changes, and tracking sync status. It also alerts to important changes in `CLAUDE.md` (standing orders) and `docs/decisions/` (ADRs).

## Commands

| Command | Description |
|---------|-------------|
| `sync` | Sync with upstream repository |
| `status` | Show upstream sync status |
| `configure` | Configure upstream repository |
| `info` | Show upstream configuration |

## Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `command` | Yes | Upstream command to execute |

## Options

| Option | Description |
|--------|-------------|
| `--pull` | Pull changes from upstream (default) |
| `--merge` | Use merge strategy (default) |
| `--rebase` | Use rebase strategy |
| `--dry-run` | Show what would happen without making changes |
| `--help, -h` | Show help message |

## Tier System

NWP uses a tiered governance model:

| Tier | Role | Can Sync From | Examples |
|------|------|---------------|----------|
| Tier 0 | Core Maintainers | - | Main NWP repository |
| Tier 1 | Regional/Org Maintainers | Tier 0 | Agency forks, regional variations |
| Tier 2 | Contributors | Tier 0 or Tier 1 | Individual developers, small teams |

See [Distributed Contribution Governance](../../governance/distributed-contribution-governance.md) for details.

## Examples

### Configure Upstream

```bash
pl upstream configure
```

Interactive configuration:

```
═══════════════════════════════════════════════════════════════
  Configure Upstream Repository
═══════════════════════════════════════════════════════════════

[!] Upstream already configured: /home/rob/nwp/.nwp-upstream.yml

Reconfigure? (y/N) y

[i] Enter upstream repository details:

Upstream URL: git@github.com:example/nwp-fork.git
Upstream tier (0-2): 1
Maintainer email: maintainer@example.com
Auto pull frequency (never/daily/weekly) [daily]: weekly
Auto push (auto/manual) [manual]: manual

[✓] Configuration saved to /home/rob/nwp/.nwp-upstream.yml

[i] Adding git remote 'upstream'...
[✓] Remote added

[i] Fetching from upstream...
[✓] Fetched successfully

[✓] Upstream configured successfully

Next steps:
  pl upstream sync    # Sync with upstream
  pl upstream status  # Check sync status
```

### Show Upstream Info

```bash
pl upstream info
```

Output:

```
═══════════════════════════════════════════════════════════════
  Upstream Configuration
═══════════════════════════════════════════════════════════════

[i] Configuration file: /home/rob/nwp/.nwp-upstream.yml

Upstream Repository:
  URL:        git@github.com:example/nwp-fork.git
  Tier:       1
  Maintainer: maintainer@example.com

Sync Settings:
  Auto Pull:  weekly
  Auto Push:  manual

[✓] Git remote 'upstream' configured correctly
```

### Check Sync Status

```bash
pl upstream status
```

Output when behind:

```
═══════════════════════════════════════════════════════════════
  Upstream Sync Status
═══════════════════════════════════════════════════════════════

[i] Fetching from upstream...
[✓] Fetched

Current branch: main
Upstream branch: upstream/main

[!] Behind upstream by 5 commit(s)

Recent upstream commits:
a1b2c3d Update CLAUDE.md security restrictions
e4f5g6h Add ADR-0015: Multi-tier governance model
h7i8j9k Fix backup retention policy
k0l1m2n Update documentation standards
n3o4p5q Add migrate-secrets command

To sync:
  pl upstream sync
```

Output when ahead:

```
[i] Ahead of upstream by 3 commit(s)

Recent local commits:
z9y8x7w Add custom deployment script
w6v5u4t Update agency-specific theme
t3s2r1q Custom import workflow

To contribute changes:
  pl contribute
```

### Sync with Upstream (Merge)

```bash
pl upstream sync
```

Output:

```
═══════════════════════════════════════════════════════════════
  Sync with Upstream
═══════════════════════════════════════════════════════════════

Current branch: main
Strategy: merge

[i] Fetching from upstream...
[✓] Fetched

[i] Behind upstream by 5 commit(s)

Recent upstream commits:
a1b2c3d Update CLAUDE.md security restrictions
e4f5g6h Add ADR-0015: Multi-tier governance model
h7i8j9k Fix backup retention policy

Sync with upstream? (Y/n) y

[i] Merging from upstream...
Merge made by the 'ort' strategy.
 CLAUDE.md                     | 15 +++++++++++++++
 docs/decisions/0015-governance.md | 120 +++++++++++++++++++++++++
 lib/backup.sh                 |  8 +++---
 3 files changed, 139 insertions(+), 4 deletions(-)

[✓] Merged successfully

[!] CLAUDE.md was updated from upstream

Review new standing orders:
  git diff HEAD~1 HEAD -- CLAUDE.md

[i] New decisions from upstream:
  docs/decisions/0015-multi-tier-governance.md

Review decisions:
  git diff HEAD~1 HEAD -- docs/decisions/

[✓] Sync complete

Current status:
a1b2c3d (HEAD -> main) Merge remote-tracking branch 'upstream/main'
b2c3d4e Update CLAUDE.md security restrictions
c3d4e5f Add ADR-0015: Multi-tier governance model
```

### Sync with Rebase

```bash
pl upstream sync --rebase
```

Replays local commits on top of upstream:

```
Current branch: main
Strategy: rebase

[i] Rebasing onto upstream...
Successfully rebased and updated refs/heads/main.
[✓] Rebased successfully
```

### Dry Run

```bash
pl upstream sync --dry-run
```

Shows what would happen:

```
Current branch: main
Strategy: merge
Mode: DRY RUN (no changes will be made)

[i] Fetching from upstream...
[i] [DRY RUN] Would fetch from upstream

[i] Behind upstream by 5 commit(s)

Recent upstream commits:
a1b2c3d Update CLAUDE.md security restrictions
e4f5g6h Add ADR-0015: Multi-tier governance model

[i] [DRY RUN] Would run: git merge upstream/main
```

## Configuration File

Located at: `.nwp-upstream.yml`

```yaml
# NWP Upstream Configuration
# This file configures the upstream repository for distributed development
# See: docs/DISTRIBUTED_CONTRIBUTION_GOVERNANCE.md

upstream:
  url: git@github.com:example/nwp-fork.git
  tier: 1
  maintainer: maintainer@example.com

sync:
  auto_pull: weekly
  auto_push: manual
  last_sync: "2026-01-14T15:30:00Z"

# Optional: downstream repositories (Tier 1/2 maintainers only)
downstream: []
```

### Configuration Fields

| Field | Description | Values |
|-------|-------------|--------|
| `url` | Upstream Git repository URL | Git URL (SSH or HTTPS) |
| `tier` | Your tier in governance model | 0, 1, or 2 |
| `maintainer` | Maintainer contact email | Email address |
| `auto_pull` | Automatic pull frequency | never, daily, weekly |
| `auto_push` | Automatic push behavior | auto, manual |
| `last_sync` | Timestamp of last sync | ISO 8601 timestamp |

## Sync Strategies

### Merge (Default)

```bash
pl upstream sync --merge
```

Creates merge commit:

```
*   a1b2c3d (HEAD -> main) Merge remote-tracking branch 'upstream/main'
|\
| * e4f5g6h (upstream/main) Update from core
* | h7i8j9k Local changes
|/
```

**Pros:**
- Preserves complete history
- Clear record of when upstream was merged
- Easier conflict resolution

**Cons:**
- Creates merge commits (can clutter history)
- Non-linear history

### Rebase

```bash
pl upstream sync --rebase
```

Replays local commits on top of upstream:

```
* a1b2c3d (HEAD -> main) Local changes (replayed)
* e4f5g6h (upstream/main) Update from core
```

**Pros:**
- Linear history
- No merge commits
- Cleaner log

**Cons:**
- Rewrites history (don't use if already pushed)
- More complex conflict resolution

## Git Remote Configuration

The command manages Git remotes:

```bash
# Added by configure command
git remote add upstream git@github.com:example/nwp-fork.git

# Verify
git remote -v
# origin    git@github.com:yourfork/nwp.git (fetch)
# origin    git@github.com:yourfork/nwp.git (push)
# upstream  git@github.com:example/nwp-fork.git (fetch)
# upstream  git@github.com:example/nwp-fork.git (push)
```

## Branch Handling

The command detects the upstream default branch:

1. Tries `upstream/main`
2. Falls back to `upstream/master`
3. Errors if neither exists

Most NWP repositories use `main`.

## Change Notifications

### CLAUDE.md Updates

When `CLAUDE.md` changes:

```
[!] CLAUDE.md was updated from upstream

Review new standing orders:
  git diff HEAD~1 HEAD -- CLAUDE.md
```

This file contains AI assistant instructions - important to review.

### New ADRs

When files in `docs/decisions/` change:

```
[i] New decisions from upstream:
  docs/decisions/0015-multi-tier-governance.md

Review decisions:
  git diff HEAD~1 HEAD -- docs/decisions/
```

Architecture Decision Records (ADRs) are immutable once created - new ones indicate architectural changes.

## Uncommitted Changes

If you have uncommitted changes:

```
[!] You have uncommitted changes

 M lib/backup.sh
 M docs/custom-notes.md

Continue anyway? (y/N)
```

**Recommendation:** Commit or stash changes before syncing.

## Auto-Sync (Future)

Configuration supports future auto-sync:

```yaml
sync:
  auto_pull: daily
  auto_push: manual
```

When implemented:
- `daily`: Check for updates once per day
- `weekly`: Check for updates once per week
- `never`: Manual sync only

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success or user cancelled |
| 1 | Error (not a git repo, fetch failed, merge conflict) |

## Prerequisites

- Git repository (`.git/` directory exists)
- Git installed
- Network access to upstream repository
- SSH key configured (for SSH URLs)
- Clean working directory (or willingness to proceed with uncommitted changes)

## Conflict Resolution

### Merge Conflicts

If conflicts occur during merge:

```
[✗] Merge failed - resolve conflicts and commit

CONFLICT (content): Merge conflict in lib/backup.sh
Automatic merge failed; fix conflicts and then commit the result.
```

Resolve manually:

```bash
# Edit conflicted files
vim lib/backup.sh

# Mark as resolved
git add lib/backup.sh

# Complete merge
git commit
```

### Rebase Conflicts

If conflicts occur during rebase:

```
[✗] Rebase failed - resolve conflicts and run: git rebase --continue

CONFLICT (content): Merge conflict in lib/backup.sh
```

Resolve manually:

```bash
# Edit conflicted files
vim lib/backup.sh

# Mark as resolved
git add lib/backup.sh

# Continue rebase
git rebase --continue
```

## Timestamp Tracking

After successful sync, updates `last_sync`:

```yaml
sync:
  last_sync: "2026-01-14T15:30:00Z"
```

Shown in status output:

```
Last sync: 2026-01-14T15:30:00Z
```

## Notes

- **Requires Git**: Must be in a Git repository
- **Upstream remote**: Automatically manages `upstream` remote
- **Fetch before sync**: Always fetches latest before checking status
- **Preserves local work**: Both merge and rebase preserve local commits
- **Safe dry-run**: Use `--dry-run` to preview changes
- **Tier-aware**: Configuration tracks your tier in governance model
- **CLAUDE.md alerts**: Warns when AI instructions change
- **ADR tracking**: Notifies of new architecture decisions

## Troubleshooting

### Not a Git Repository

**Symptom:** "Not a git repository"

**Solution:**
1. Ensure you're in NWP directory
2. Check for `.git/`: `ls -la .git`
3. Initialize if needed: `git init`

### Upstream Remote Not Configured

**Symptom:** "Upstream remote not configured"

**Solution:**
```bash
pl upstream configure
# Or manually:
git remote add upstream <url>
```

### Fetch Failed

**Symptom:** "Failed to fetch from upstream"

**Solution:**
1. Check network: `ping github.com`
2. Verify SSH key: `ssh -T git@github.com`
3. Check URL: `git remote get-url upstream`
4. Update URL if wrong: `git remote set-url upstream <correct-url>`

### Merge/Rebase Failed

**Symptom:** Conflicts during sync

**Solution:**
1. Review conflicts: `git status`
2. Edit conflicted files
3. Mark resolved: `git add <files>`
4. Complete operation:
   - Merge: `git commit`
   - Rebase: `git rebase --continue`

### Branch Not Found

**Symptom:** "Upstream main/master branch not found"

**Solution:**
1. Check remote branches: `git branch -r`
2. Fetch all: `git fetch upstream`
3. If upstream uses different default:
   ```bash
   git fetch upstream develop
   git merge upstream/develop
   ```

## Related Commands

- [contribute.sh](../scripts/contribute.sh) - Submit changes upstream (Tier 2→1 or 1→0)
- Git commands for manual management

## See Also

- [Distributed Contribution Governance](../../governance/distributed-contribution-governance.md) - Complete governance model
- [Contribution Guidelines](../../governance/contribution-guidelines.md) - How to contribute
- [Git Workflow](../../guides/git-workflow.md) - NWP Git practices
- [CLAUDE.md](../../../CLAUDE.md) - AI assistant standing orders
- [Architecture Decisions](../../decisions/) - ADR repository
