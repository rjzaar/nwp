# Stranded work relevant to the console dual-version library

**Found:** 2026-07-26, while auditing worktree sprawl (77 worktrees, 1.2 GB, 8 branches carrying
unmerged commits).

## `pubrel/scrub-and-gate` — 2 commits, unmerged for 9 days

Worktree: `/home/rob/nwp-pubrel` @ `2e50905`

```
2e50905 security(release): swap personal email for role addresses + tighten gate (ops#98)
e1b62db security(leakage-gate): enforce email + bare-domain + prod-IP; genericise prose
        (public-release prep)
```

35 files changed, +136 / -78 — mostly `docs/proposals/*`, `docs/guides/*`, plus
`scripts/agent-loop/agent-loop.sh`.

### Why this matters right now

The operator has asked for the docs library to be surfaced in the console in **two versions**:
the complete set, and a **public** one "purged of all my private information."

This branch already builds a large part of that mechanism: it **hardens the leakage gate to enforce
email addresses, bare domains and prod IPs**, and genericises the prose across the doc corpus. That
is precisely the fail-closed classifier the public library needs.

**Do not build a second scrubber.** Whoever implements the dual-version library must first read this
branch, decide whether to merge it or rebase it forward, and build on top of it. Building a parallel
purge pipeline would leave two classifiers that can disagree — and a false "public" classification is
the worst outcome for this feature.

### Open questions for whoever picks it up

- Why did it sit unmerged for 9 days? Was it blocked on review (it touches
  `scripts/agent-loop/agent-loop.sh`, and the commits are security-class), or simply forgotten?
- Does it still apply cleanly to `main`, given the docs batch that landed since?
- ops#98 is referenced — check that issue's state before assuming this is the whole of the work.

## Other unmerged branches found in the same sweep

| Branch | Commits | Last activity |
|---|---|---|
| `ops-79` | 5 | 2 weeks ago |
| `ops-127` | 2 | 2 days ago (the known stranded parts 2/3 of MR !142) |
| `ops-93` | 1 | 8 days ago |
| `pubrel/scrub-and-gate` | 2 | 9 days ago |
| `chore/gitleaks-allowlist-issue-urls` | 1 | 2 weeks ago |
| `fix/moodle-deploy-snapshot-cli-script` | 1 | 4 hours ago (duplicate of a fix in another MR) |
| `feat/console-security-advisories` | 1 | today (MR !167, blocked on main's red CI) |
| `feat/demo-tier-ssd` | 1 | 14 hours ago |

The remaining ~69 worktrees carry no unmerged commits and are stale clutter. They are not merely
untidy: this repo has a standing rule against committing in `~/nwp` directly *because* concurrent
sessions switch branches under each other, and 77 checkouts of the same repo makes that hazard worse,
not better.
