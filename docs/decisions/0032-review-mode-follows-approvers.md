# ADR-0032: Review mode follows `approvers:` — one reviewer today, two when there are two

**Status:** Accepted
**Date:** 2026-08-06
**Supersedes:** nothing. **Amends:** the two-person assumption baked into ADR-0028's
Phase 1 dispensation and into `pl mr`'s D13 hold.

## Context

The D13 hold mechanism was built after 2026-08-01, when a merge sweeper armed
`merge_when_pipeline_succeeds` on a deliberately held MR and it self-merged the
moment CI went green. The fix was correct and remains in force. But it was built
assuming **two** reviewers: a sensitive-path MR is set to Draft and stays
unmergeable until somebody who is *not* the author records a release note bound to
the head commit.

There is one human. The operator, 2026-08-06, stated twice:

> *"The current system is just you and me. We don't need the extra overhead of two
> checks for now. It should only be happening once I approve the shift and there is
> a second human dev in the system. Until then I should be able to approve/merge
> once and only in one spot which is the MR location."*

A two-person rule with one available person is not two-person review. It is a
ritual: the operator releases as themselves, then merges as themselves, in two
places, and the second step authenticates nothing. `cmd_release` already said so in
its own comments — *"a two-person rule with only one available person is not
two-person review, and pretending otherwise is how real controls come to be
ignored."*

## Decision

**The number of reviewers is read from `approvers:` in
`private/secrets-registry.yml`.** One name → `solo`. Two or more → `team`.

| | `solo` | `team` |
|---|---|---|
| approval | the **Merge click on the MR page**, and nothing else | a release recorded by a non-author, bound to the head sha |
| `pl mr release` | not needed | required |
| `pl mr release --merge` | **refused** — a shell would be a second approval spot | allowed when the token identity ≠ author |
| sensitive-path MR | **reported** (terminal + a note on the MR) | **held as Draft** |
| gate job | exit 0 | exit 1 |

**Adding the second name is the entire switch.** It is simultaneously the operator
approving the shift and the second human dev existing — the two conditions of the
ruling — so nothing has to be remembered, and there is no way to be in team mode
with nobody available to be the second pair of eyes. This reuses the pattern
`cmd_release` already used for the ADR-0028 dispensation, and its rationale
verbatim: *"Keyed off a DECLARED FACT, never a date or a phase name: inert today,
correct forever, and it arms without anyone remembering to arm it."*

### The invariant that spans both modes

> **A machine never merges. A human merges.**

Auto-merge is disarmed in both modes, and every verb that could merge refuses when
the token's **forge-verified** identity (`GET /user`) is a bot. Solo mode removes
the *second* human, never the human. The 2026-08-01 incident was a machine merging
something no person had approved, and that remains impossible. The AI holds a bot
token, so **the AI cannot merge** — verified live: `pl mr merge` refuses
`@group_9_bot_…` with "A machine never merges."

## Consequences

### What got simpler

One approval, one place. The operator reads the sensitive-path note on the MR and
clicks Merge. No `pl mr release`, no `--approved-by` handle to invent, no Draft to
lift first.

### What we accept

The Draft hold no longer protects sensitive-path MRs from the operator's own
mistaken click. That is the point: it never protected against *them*, only against
a second party's absence, and the reporting is louder than before (a note on the MR
rather than terminal output nobody reads).

### The complexity we deliberately did NOT add

`private/` is a separate repository, so CI cannot read the registry — which is why
the pre-existing dispensation check silently does nothing in a pipeline. The gate
runs in CI and must know the mode, so the count is projected into the tracked
`.nwp-review-mode`.

Two representations of one fact can disagree, and the operator asked specifically
that this not *"drift back into complexity"*. Three properties keep that honest:

1. **The registry wins wherever it is readable**, so a stale projection can never
   loosen policy — only be out of date somewhere it is not consulted.
2. **Drift is measured, not hoped away.** `scripts/ci/lint-review-mode-projection.sh`
   compares them and is wired into **pre-commit**, because only a host with both can
   compare — a CI job cannot, so a CI check would be theatre. It exits 2 (CANNOT
   VERIFY) where the registry is absent, never 0.
3. **There is no `pl mr review-mode set`.** Asking for one gets an error explaining
   that a settable mode is a way to be in team mode with nobody to be the second
   reviewer. `sync` only copies the derived value.

### Fail-closed direction

Nothing readable — no registry, no projection, an unrecognised word, zero declared
approvers — reads as **`team`**, the stricter mode.

This is not the obvious default. The obvious default is today's mode, and it is
wrong: a typo or a bad checkout would then silently switch the estate to
single-approval, the permissive direction. It nearly happened while writing this —
`.nwp-review-mode` was silently gitignored (the root `.gitignore` denies `/*` and
allowlists back), so it existed locally and would have been **absent in CI**.
Because the fallback is `team`, that surfaced as CI holding everything: annoying and
visible. Had it defaulted to `solo`, the same mistake would have disabled
two-person review in the pipeline with nothing complaining.

## Evidence

Red-then-green, and the switch **proven to fire** rather than assumed armable
(ops#214: *"an inert guard nobody has seen fire is the 'check that has never been
proven to fail' class"*):

| fixture | mode | gate on a `CLAUDE.md` diff |
|---|---|---|
| `approvers: [rjzaar]` | solo | exit **0**, not held, note posted, auto-merge disarmed |
| `approvers: [rjzaar, seconddev]` | team | exit **1**, **held** as Draft |
| `approvers: []` | team | held |
| registry absent (CI) | from the projection | as projected |
| nothing readable | team | held |

`tests/unit/test-review-mode.bats` — 36 cases. Ten mutations, each verified to have
applied, to still parse, and to land in the intended function; **all ten caught**,
including "2 approvers no longer arm team" (33/36), "unreadable → solo" (32/36),
"bots may merge" (34/36) and "solo mode holds anyway" (32/36).

Live: the AI's own bot token is refused from merging.

## Reverting

Add a second name to `approvers:`, run `pl mr review-mode sync`, commit. Team mode
is not removed by this ADR, only switched off — which is why it is tested in the
refusing direction.
