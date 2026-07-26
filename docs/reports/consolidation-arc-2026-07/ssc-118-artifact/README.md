# ops#118 — Moodle-side Art.9 consent gate: what is preserved here, and what is not

**Recoverable artifact:** `ops-118-moodle-art9-gate.patch` (84 KB).
It is a full `git show` of commit `346025ce13dc2151c0a6d084c1b24c19b713aa91`
("REVIEW(legal/cross-app): ops#118 Moodle-side Art.9 formation-data consent
gate"), covering all 8 changed files with complete pre-/post- context. It
applies to any Moodle checkout and needs nothing from this laptop.

## The bundle that used to sit beside it was a brick — it was removed

`ops-118-moodle-art9-gate.bundle` was committed here as the durable copy of the
same work. It was created with a revision range, so it was a **thin** bundle: it
carried the objects *since* an upstream Moodle commit and recorded that commit
as a prerequisite it did not contain.

Reproduced before removal, in an empty repository:

```
$ git init -q scratch
$ git -C scratch bundle verify .../ops-118-moodle-art9-gate.bundle
error: Repository lacks these prerequisite commits:
error: 67c80957df19d4d908e4927fb1c40db02fe40dd2
```

`67c8095…` is an upstream `moodle/moodle` weekly-release commit ("weekly release
4.4.12+"). It is not in this repository and not in the bundle. Outside the one
working copy on the authoring laptop that still holds Moodle's history, the
bundle restores **nothing**.

The trap that produced it: `git bundle verify` run from *inside* the repository
you bundled reports success, because it resolves the prerequisites against the
repo you are standing in. That green is meaningless.

### Why it was deleted rather than annotated

The alternative was a `.prereq.json` manifest declaring "fetch `67c8095…` from
`https://github.com/moodle/moodle.git`". That declaration was **not verifiable
from here** — the agent that reviewed this had no route to github, and no
independent Moodle checkout it was permitted to read. Writing a recoverability
claim that nobody had tested would have reproduced the original defect one layer
up. An artifact that asserts a safety it does not provide is worse than no
artifact, because it stops anyone looking for a real one.

Nothing was lost. The bundle blob remains in this repository's history forever:

```
git show 8e27949952be75ef73fe5ba7de3b48015c96af29 > ops-118-moodle-art9-gate.bundle
```

and the same commit content is in the `.patch` beside this file, and on
`nwp/ss-moodle-plugins` `origin/ops-137-depthcontent-amd-build`.

## This cannot happen again silently

`pl snapshot` now owns bundle creation and checking:

| Need | Command |
|---|---|
| Make a bundle that is provably restorable | `pl snapshot bundle <repo> --out=<file>` |
| Check one | `pl snapshot verify <bundle>` |
| Check every bundle in the tree (the gate) | `pl snapshot audit` |

`pl snapshot bundle` verifies its own output in a pristine scratch repository
with every inherited `GIT_*` variable cleared, and **deletes** the artifact
rather than shipping one that fails. A deliberately thin bundle is still allowed
— a fork of a 1 GB upstream should not commit 1 GB — but only via
`--thin --base=<ref> --prereq-source=<url>`, which writes a manifest naming every
prerequisite object and where it can be fetched from. `pl snapshot audit` fails
on any bundle that is neither standalone nor completely declared.
