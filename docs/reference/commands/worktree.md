# worktree

**Status:** ACTIVE
**Last Updated:** 2026-07-26

List and safely prune git worktrees, with a fate manifest.

## Synopsis

```bash
pl worktree list  [--repo=<path>] [--base=<ref>] [--no-size]
pl worktree prune [--repo=<path>] [--base=<ref>] [--no-size] [--dry-run|--confirm|--yes]
```

## Why this exists

Worktrees accumulate silently. Every `pl issue work <N>` and every agent
session creates one; nothing ever removed them. Measured in `~/nwp` on
2026-07-26:

| Measure | Value |
|---------|-------|
| `git worktree list \| wc -l` | 110 (90 an hour earlier — still growing) |
| Disk in non-primary trees | ~1.2 GB |
| Trees with an unmerged commit | 24 |
| Trees classified `REMOVE` | 60 (~784 MB reclaimable) |

`pl branch stranded --prune-merged` does **not** cover this: it prunes **branch
refs**, not checkouts. Its own header comment records "77 worktrees" as a known
unaddressed problem.

## What it will not do

- **It never deletes a branch ref.** Removing a checkout must never remove the
  ref — that stays `pl branch stranded --prune-merged`'s job. Enforced by a
  test that diffs `git branch --list` across a prune.
- **It never passes `--force` to `git worktree remove`.** Our predicates
  already refuse dirty trees; git's own refusal is a second, independent gate.
- **It never acts without printing the manifest first**, and dry-run is the
  default.

## Fates

A worktree is removed only if **every** predicate passes. The first predicate
that objects becomes the fate, and the reason is printed.

| Fate | Meaning |
|------|---------|
| `KEEP(primary)` | the repo's own checkout |
| `KEEP(current)` / `KEEP(self)` | the tree `$PWD` is in, or the one `pl` is running from |
| `KEEP(locked)` | `git worktree lock` was used |
| `KEEP(detached)` | no branch, so merged-ness is not computable — not our call |
| `KEEP(unmerged)` | `git rev-list --count <base>..<branch>` > 0 |
| `KEEP(payload)` | untracked **or ignored** data: `backups/`, `*.sql.gz`, `*.dump`… |
| `KEEP(dirty)` | tracked files modified or staged |
| `KEEP(untracked)` | any other untracked file |
| `KEEP(stash)` | a stash entry names its branch |
| `KEEP(uncomparable)` | the ahead-count could not be computed |
| `STALE` | registration whose directory is gone (no files to delete) |
| `REMOVE` | all of the above passed |

### Why `KEEP(payload)` is load-bearing

The nwp tree gitignores `backups/`. An **ignored** payload is invisible to the
untracked predicate *and* to `git worktree remove`'s own refusal — git deletes
ignored files without complaint. `wt_payload()` is the only thing standing
between a gitignored `backups/*.sql.gz` and deletion. The acceptance test
proves this: removing the payload predicate makes the fixture's W4 disappear.

### Stricter than `pl branch stranded`

`stranded` calls a branch `IDENTICAL` (prunable) when its *files* match main,
even if its commits never merged — right for a ref, wrong for a checkout, since
those commits are the only record of how the work was done. Here the gate is
blunt: the ahead-count must be exactly `0`.

## Options

| Option | Description | Default |
|--------|-------------|---------|
| `--repo=<path>` | Repository to operate on | this NWP checkout |
| `--base=<ref>` | Merged-ness base | `origin/main`, then `main`, `origin/master`, `master` |
| `--no-size` | Skip `du(1)` — much faster on a large estate | off |
| `--dry-run` | Print the manifest, change nothing | **default for `prune`** |
| `--confirm` | Print the manifest, then ask y/N | - |
| `-y, --yes` | Print the manifest and remove without prompting | - |

If no base ref resolves, the command **fails closed**: with no base there is no
notion of "merged", so nothing is prunable.

## Examples

```bash
pl worktree list --no-size          # fast fate-classified inventory
pl worktree prune                   # dry-run: what would go, and why not
pl worktree prune --confirm         # manifest, then y/N
pl worktree prune --yes             # act (see the warning below)
```

## Operational warnings

- **`--yes` is an operator-timed action.** Other agent sessions hold worktrees.
  A session that has just committed and pushed leaves a tree that is clean and
  fully merged — indistinguishable from debris — and this tool cannot see that
  a process is attached to it. Run the real prune when no other session is
  active. This is why the AI workflow that built the verb ran only `--dry-run`.
- Reads use `git --no-optional-locks` throughout, so scanning other agents'
  worktrees does not rewrite their index or race a live session.
- `wt_stash_count` matches stash subjects by **branch name**, because
  `refs/stash` is shared across a repo's worktrees. It is a per-branch signal,
  not a per-worktree one — it errs toward KEEP.

## Implementation

| File | Role |
|------|------|
| `scripts/commands/worktree.sh` | verb, manifest rendering, removal path |
| `lib/worktree-prune.sh` | classification engine (`wt_scan`, predicates) |
| `tests/unit/test-worktree-prune.bats` | 19 acceptance tests |

The verb sources `lib/impact.sh` and renders the standard fate manifest before
confirming, like every other destructive verb (nwp/ops#47).

## See also

- `pl branch stranded` — the branch-ref half of the same problem
- `pl issue work <N>` — what creates most of these worktrees
