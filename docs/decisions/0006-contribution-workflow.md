# ADR-0006: Contribution Workflow

**Status:** Accepted
**Date:** 2026-01-09
**Decision Makers:** Rob
**Related Issues:** N/A (implements governance framework from ADR-0005)

## Context

With the distributed contribution governance framework established in ADR-0005, we need concrete tooling and workflow documentation for contributors to sync with upstream repositories and submit contributions. The key challenges are:

1. **Synchronization**: Developers working on Tier 2+ repositories need to pull changes from upstream
2. **Contribution**: Changes need to flow upstream through merge requests with proper security review
3. **Strategy Choice**: Merge vs rebase has implications for history and conflict resolution
4. **Multi-tier topology**: Changes may traverse multiple repository tiers (Canonical -> Primary -> Developer)
5. **Security**: Contributions must be reviewed for scope verification and malicious code

## Options Considered

### Option 1: Merge Strategy by Default
- **Pros:**
  - Preserves complete history of when changes were integrated
  - Lower risk of conflicts in collaborative environments
  - Better traceability for audit purposes
  - Easier to revert if needed (single merge commit)
  - Familiar to most developers
- **Cons:**
  - Creates more merge commits in history
  - History can become "noisy" with many merge commits

### Option 2: Rebase Strategy by Default
- **Pros:**
  - Cleaner, linear history
  - Easier to read git log
- **Cons:**
  - Rewrites history, can cause issues in multi-developer scenarios
  - Harder to revert (need to identify individual commits)
  - Can lose context of when integration happened
  - More potential for conflicts if commits are reordered

### Option 3: Squash Merge
- **Pros:**
  - Single commit per feature
  - Very clean history
- **Cons:**
  - Loses individual commit granularity
  - Makes bisecting harder
  - Loses author attribution for multi-author work

## Decision

Implement the contribution workflow using:

1. **`pl upstream sync`** - Synchronize local repository with upstream, using **merge strategy by default**
2. **`pl contribute`** - Submit changes upstream via merge request with pre-flight security checks
3. **Multi-tier topology** support via `.nwp-upstream.yml` configuration
4. **Security review requirements** enforced via decision compliance checks and scope verification

The merge strategy is the default because:
- It preserves complete history, important for distributed governance
- It's safer in multi-tier scenarios where multiple developers may be integrating
- Contributors can still use `--rebase` flag when appropriate for their workflow

## Rationale

### Merge Strategy Rationale

In a multi-tier repository topology (Canonical -> Primary -> Developer -> Developer), merge commits provide crucial audit trail:

1. **When** changes were integrated at each tier
2. **What** upstream state existed at integration time
3. **Who** performed the integration

Rebase obscures this information and can cause conflicts when different tier maintainers rebase the same commits differently.

### Tool Design Rationale

The `pl upstream` and `pl contribute` commands provide:

1. **Discoverability**: Single entry point for contribution workflows
2. **Safety**: Pre-flight checks before destructive operations
3. **Consistency**: Same workflow across all tiers
4. **Flexibility**: Options for different strategies (--rebase, --dry-run, --draft)

### Security Review Integration

The `pl contribute` command enforces:
1. All changes committed (no uncommitted work)
2. Feature branch required (no direct contribution from main)
3. Decision compliance check (ADRs committed)
4. Test suite passing (unless --no-tests)
5. Generated MR description with scope documentation

## Consequences

### Positive
- Clear, documented workflow for all contributors
- Consistent tooling across repository tiers
- Built-in security review checkpoints
- Supports both fork-based and tier-based contributions
- Merge strategy preserves complete audit trail
- Optional rebase for developers who prefer linear history

### Negative
- Additional tooling to learn for new contributors
- Merge commits add verbosity to git history
- Requires upstream configuration before use

### Neutral
- Contributors can use raw git if preferred, tools are convenience wrappers
- Issue templates standardize but don't restrict contribution formats

## Implementation Notes

### Scripts Implemented

1. **`scripts/commands/upstream.sh`**
   - Commands: `sync`, `status`, `configure`, `info`
   - Options: `--merge` (default), `--rebase`, `--dry-run`, `--pull`
   - Configuration via `.nwp-upstream.yml`

2. **`scripts/commands/contribute.sh`**
   - Pre-flight checks: git status, uncommitted changes, upstream config, feature branch, commits to contribute
   - Decision compliance check: verifies ADRs are committed
   - Test execution (unless `--no-tests`)
   - MR creation via `glab` or `gh` CLI
   - Options: `--branch`, `--title`, `--draft`, `--no-tests`

### Multi-Tier Repository Topology

```
                    +-----------------------------------------+
                    |         TIER 0: CANONICAL               |
                    |     github.com/nwp/nwp (public)         |
                    |         Main release repo               |
                    +-------------------+---------------------+
                                        |
                    +-------------------+---------------------+
                    |         TIER 1: PRIMARY                 |
                    |   git.nwpcode.org/nwp/nwp               |
                    |   (Rob's GitLab - auto-push to T0)      |
                    +-------------------+---------------------+
                                        |
          +-----------------------------+-----------------------------+
          |                             |                             |
+---------+---------+       +-----------+---------+       +-----------+---------+
|   TIER 2: DEV A   |       |   TIER 2: DEV B     |       |   TIER 2: DEV C     |
|  git.deva.org/nwp |       |  git.devb.org/nwp   |       |  git.devc.org/nwp   |
|  (pushes to T1)   |       |  (pushes to T1)     |       |  (pushes to T1)     |
+-------------------+       +---------------------+       +---------------------+
```

### Configuration Format

`.nwp-upstream.yml`:
```yaml
upstream:
  url: git@git.nwpcode.org:nwp/nwp.git
  tier: 1
  maintainer: rob@nwpcode.org

sync:
  auto_pull: daily
  auto_push: manual

downstream: []
```

### Issue Templates

Located in `.gitlab/issue_templates/`:
- `Bug.md` - Bug reports with version, environment, reproduction steps
- `Feature.md` - Feature requests with problem statement, solution, alternatives
- `Task.md` - Work items, refactoring, cleanup
- `Support.md` - Usage questions, how-to requests

### Security Review Requirements

Per ADR-0005, contributions require:
1. **Scope verification**: Changes must match stated purpose
2. **Red flag detection**: Automated checks for suspicious patterns
3. **Sensitive path protection**: Two-person rule for critical files
4. **CI security gate**: Automated scans (gitleaks, semgrep, dependency audit)

### Edge Cases and Limitations

1. **Conflict Resolution**: Both merge and rebase can encounter conflicts; user must resolve manually
2. **Upstream Branch Detection**: Script tries `main` first, then `master` for compatibility
3. **GitLab CLI Requirement**: Full automation requires `glab` or `gh` CLI installed; manual MR creation fallback provided
4. **Test Script Dependency**: Expects `pl verify --run` for test execution; skips gracefully if missing
5. **CLAUDE.md Updates**: Script warns when upstream sync updates CLAUDE.md (new standing orders)
6. **Decision Record Changes**: Script notifies when upstream sync brings new ADRs

### Workflow Example

```bash
# Initial setup (one-time)
pl upstream configure
# Enter upstream URL, tier, maintainer, sync preferences

# Regular sync with upstream
pl upstream sync              # Merge by default
pl upstream sync --rebase     # Or rebase if preferred
pl upstream status            # Check sync status

# Contributing changes
git checkout -b feature/my-feature
# ... make changes ...
git add -A && git commit -m "Add new feature"

pl contribute                 # Runs tests, creates MR
pl contribute --draft         # Create as draft MR
pl contribute --no-tests      # Skip tests (not recommended)
```

## Review

**30-day review date:** 2026-02-09
**Review outcome:** Pending
