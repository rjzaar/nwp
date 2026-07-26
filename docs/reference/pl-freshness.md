# `pl` checkout freshness

**Last Updated:** 2026-07-26
**Code:** `lib/pl-freshness.sh`, sourced by `pl`
**Tests:** `tests/unit/test-pl-freshness.bats`

## The problem this solves

`/usr/local/bin/pl` is a symlink into **one** checkout — on the dev workstation,
`~/nwp`. That single checkout is the code path for every `pl secrets
audit`, every `pl rag`, every `pl deploy-gate`, and every impact/fate manifest
on the machine.

`VERSION` inside `pl` is a hardcoded string. A checkout sitting exactly on
`origin/main` and one forty commits behind it both answer `0.30.0`. So an
operator reading a green oversight surface had no way to know *which* code
produced it — and reading last month's logic is one of the easier ways to be
confidently wrong about a fleet.

`pl` now says so, in at most one line, on stderr.

```
pl: this checkout (/path/to/nwp) is 4 commits behind origin/main as of
2026-07-26 23:44 (last local fetch; not re-checked — `pl version --check` fetches)
```

## What it does and does not claim

The number is **commits behind as of the last fetch**, not "commits behind right
now", and the banner says exactly that. `pl` reads only refs already on disk; it
never contacts a remote. A banner that implied a live check while doing none
would be worse than no banner, because it would be *trusted*.

To ask the remote, ask explicitly:

```
$ pl version --check
NWP CLI (pl) version 0.30.0
freshness: 4 commits behind origin/main (checked just now) — `git -C /path/to/nwp pull` to update
```

`pl version --check` is the only `pl` path that touches the network for
freshness. It also clears the cached verdict, so the next ordinary `pl` agrees
with it.

## When it stays silent — deliberately

Silence is the default, and the following are **never** reported:

| State | Why |
|---|---|
| Up to date with upstream | Nothing to say |
| **Detached HEAD** | Deliberately pinned |
| **No upstream on the branch** | Local/topic branch; nothing to be behind |
| **HEAD is exactly a tag** | Someone checked out a release on purpose |
| Ahead of upstream (unpushed work) | Being ahead is not being stale |
| Upstream has moved but this checkout has not fetched | `pl` cannot know without the network, and will not guess |
| `NWP_NO_FRESHNESS_CHECK` set to anything non-empty | Explicit opt-out |
| Nested `pl` (`NWP_FRESHNESS_SHOWN` already exported) | Say it once, not once per subprocess |
| No `git`, corrupt `.git`, unreadable repo, unwritable cache | Fail open (below) |

The three pinned cases are the ones a naive `git rev-list --count HEAD..@{u}`
gets wrong. An operator nagged about a choice they made on purpose learns to
ignore the banner, and an ignored banner is worse than an absent one.

## Fail open, always

Every failure path produces silence and exit status 0. A broken freshness check
must never be the reason an emergency `pl rollback` does not run. The whole
check runs in a subshell with `set +e` so it cannot trip `pl`'s own `set -euo
pipefail`, and the call site is `pl_freshness_banner "$SCRIPT_DIR" || true`.

## Cost

* **Cold** (first call, or HEAD moved, or TTL expired): about six `git`
  invocations, all local — `rev-parse`, `describe`, one `rev-list --count`. No
  network, no object download.
* **Warm** (within the TTL, HEAD unchanged): a single `git rev-parse HEAD`. No
  revision-graph walk. `tests/unit/test-pl-freshness.bats` case (h) asserts this
  with a `git` shim that records every invocation, so a regression to
  "rev-list on every `pl` call" fails the suite rather than merely being slow.

## Where the cache lives

`${XDG_CACHE_HOME:-$HOME/.cache}/nwp/freshness<flattened-checkout-path>.v1`

Deliberately **outside** the checkout: a cache file inside the repo would dirty
`git status` and give the leakage/containment gates an unexplained file to trip
on. The key includes the checkout path, so a linked worktree and the main
checkout are separate subjects and cannot inherit each other's verdict.

Record format: `<expiry-epoch>|<head-sha>|<count>|<upstream>|<fetch-epoch>`.
The verdict is keyed on HEAD as well as time, so moving the checkout invalidates
it immediately regardless of TTL; the TTL only covers "HEAD stood still but a
fetch brought new upstream commits in".

## Environment

| Variable | Effect |
|---|---|
| `NWP_NO_FRESHNESS_CHECK` | Non-empty → the banner never runs |
| `NWP_FRESHNESS_TTL` | Cached-verdict lifetime in seconds (default 1800) |
| `NWP_FRESHNESS_SHOWN` | Set by `pl` itself; suppresses the banner in nested `pl` calls |
| `NO_COLOR` | Drops the colour, **not** the message — the line is as useful in a log as on a terminal |
| `XDG_CACHE_HOME` | Where the verdict cache goes |

## Deliberate non-goals

* **It does not fetch on a timer, and nothing was wired into `pl todo` or
  `pl rag` to fetch on their behalf.** Those surfaces were out of scope for this
  change. The consequence is honest but real: on a checkout that nobody ever
  fetches, the banner stays silent forever, because the only number it can
  compute is zero. `pl version --check` is the manual remedy; an automatic
  periodic fetch is a separate decision with its own risk surface.
* **It does not report uncommitted or unpushed local changes.** Different
  question, different verb (`pl doctor`).
* **It does not block anything.** It is a banner, never a gate.
