# ADR-0040: Bounded standing merge authority — a machine may merge inside a measured bound

**Status:** Accepted
**Date:** 2026-08-22
**Supersedes:** nothing.
**Amends:** the cross-mode invariant stated in
[ADR-0037](0037-review-mode-follows-approvers.md) and in CLAUDE.md — *"A machine
never merges. A human merges."* It is narrowed, not withdrawn.
**Issue:** nwp/ops#385

## Context

`_mr_merge_actor_ok` was written after 2026-08-01, when a merge sweeper armed
`merge_when_pipeline_succeeds` on a deliberately held MR and it self-merged the
moment CI went green. The fix keyed the refusal on the token's **forge-verified**
identity rather than on a config flag: a bot is refused, a human is not, and
"I could not tell" is refused too. ADR-0037 then made that the one thing which
does *not* change between `solo` and `team` review mode, because solo drops the
Draft hold and this became the last thing standing between an armed automation
and a merged MR.

The cost of that, in daily practice, is a queue that only one person can move.
The operator described the loop he was in on 2026-08-22: click Merge, watch it
fail, paste the failure to an agent, wait, click again. Every MR — including the
large majority that touch nothing sensitive — needs him at the keyboard.

He asked for the queue to be delegated, and stated the bound himself:

> never a prod-phase site, never a sensitive path, never CLAUDE.md itself.
> *"do it all and get it working."*

## Decision

**A named machine may merge, inside a bound that is declared once and measured on
every merge.**

### 1. One declaration, one place

`merge_authority:` in `private/secrets-registry.yml`, beside `approvers:` — the
same declared-fact pattern ADR-0037 established:

```yaml
merge_authority:
  granted_to: <the bot's forge handle>
  granted_by: <the human who granted it>
  granted_on: "YYYY-MM-DD"
  ref: nwp/ops#385
  scope: non-sensitive-non-prod
```

`lib/gitlab-mr.sh:_mr_merge_authority` is the only reader. There is deliberately
**no** environment variable, CLI flag, console toggle or per-project override.
Deleting the block revokes the grant everywhere, immediately, with no code
change — that is the revocation procedure. With no block present, behaviour is
byte-for-byte what it was before this ADR.

`scope:` is an enum of exactly one value. It exists so that a future second bound
has to be *spelled*, and so that any value this build does not understand fails
closed rather than being read as "whatever the current bound happens to be".

**Provenance of the grant itself.** `granted_by:` records *who decided*; it does
not record *how the decision reached the file*, and only one of those is checkable
from the repository. The 2026-08-22 grant was given **verbally in session and
transcribed by an agent** — the commit that wrote it used the operator's default
git identity, was unsigned, and bundled the grant with unrelated exposure records.
So the block also carries `granted_via:`, stating that plainly, because a
machine's standing permission to merge should not rest on an attribution nobody
checked. That is ops#361's borrowed-attribution defect pointing the other way.
The honest closure is the operator amending and signing the block himself; until
then the record says what is true rather than what is convenient.

### 2. The bound is mechanical — and it, not any review, is the safety property

Nothing in this mechanism asks whether a change *looked* reviewed, and nothing
trusts a marker anyone typed. Every merge reads the MR's own diff and refuses if:

1. any path matches CLAUDE.md's **Sensitive File Paths** list. `nwp_sensitive_globs`
   parses that section **at run time**, so adding a line to the standing order
   tightens the bound with no code change;
2. any site touched has **canonical phase `prod`** (ops#33). Keyed off the phase,
   never off a site's name — "refuse nwc and ss" is wrong today and would miss a
   new prod site later. Inert until the first `pl canonical set <site> prod`, and
   armed by that command alone;
3. **CLAUDE.md itself** appears in the diff. This is checked independently of the
   list it contains, because an MR editing that list could otherwise widen the
   bound it is being judged by;
4. the diff touches **the bound's own enforcement machinery** — `lib/gitlab-mr.sh`,
   `lib/sensitive-paths.sh`, `lib/canonical.sh`, `scripts/commands/mr.sh`, and the
   three suites that hold them to their red-proofs. These are entries in the
   CLAUDE.md list, so rule 1 enforces them; they are called out here because the
   *reason* is different from an ordinary sensitive path.

**Why rule 4 is not optional.** The merging process runs the code it had **before**
the merge, so an MR that edits the bound is judged by the version it is about to
replace. An MR editing `_mr_merge_scope_ok` **and its own tests together** stays
CI-green — CI runs the tests the MR ships — matches no other glob, and would
machine-merge with zero human eyes, leaving every subsequent merge unbounded.
Rule 3's argument about the list is exactly this argument about the code; the
first version of this ADR made it for one file and not for the others.

*Added 2026-08-23 after a cross-model review (Fable) of !474 reproduced the
attack. Findings A1 and A2.*

### 3. Fail closed

Unreadable registry, missing or malformed block, unrecognised `scope:`, a handle
that is not the token's own, an unreadable diff, or an empty change set — all of
them mean **a human merges**. An empty change set is blindness, never a clean
bill of health; ops#293 is the whole history of an empty parse reading as
"nothing sensitive".

A **truncated** change set is the same thing wearing a better disguise, and it
read as clean until 2026-08-23. `_mr_changed_files` capped diff pagination and
stopped with rc 0, so an MR too big to read whole was indistinguishable from one
that had been read whole. Measured: 30 full pages of padding plus `.gitlab-ci.yml`
on page 31 gave rc 0, 3000 paths, the sensitive path absent, and the bound graded
the MR **in scope**. The cap now returns rc 1 → CANNOT VERIFY. This is
pre-existing code whose *failure direction* this ADR changed: before, it failed
to apply a hold; after, a bot merged on it.

### 3a. The merge is pinned to the commit that was measured

The bound is measured against the diff, and `pl mr merge` may then poll, rebase
and `--wait` for minutes before the merge call. Unpinned, a commit pushed into
that window merges **unmeasured**, and the attribution note's own claim — measured
against this MR's own diff immediately before merging — is not true.

So the merge passes GitLab's `sha` parameter, carrying the head commit read
*before* the scope check. If the source branch has moved, the forge answers 409
and nothing merges. The exit is a **recheck** (re-run, and the new head is
measured on its own terms), never a borrowed approval — ops#361.

If the head sha cannot be read at all, the merge is refused (exit 4) rather than
sent unpinned. A permissive fallback is how a check that cannot run becomes a
check that passes.

### 4. Truthful attribution

Every machine merge posts a note naming the machine — *"merged by @&lt;bot&gt;
under standing authorization &lt;ref&gt;; cross-model review: &lt;state&gt;"* — and
saying plainly that no human clicked and nobody approved it at merge time.
The operator's identity is never used, implied or borrowed.

ops#361 recorded this defect running the other way: a fail-closed guard whose
only exit required recording an operator approval that was never given, and two
agents duly recorded one. Attribution must never be the price of getting work
done, in either direction.

## Consequences

**What improves.** The queue moves without the operator. The bound is narrower
and more legible than "a human clicked", because a human click asserts nothing
about the diff — the 2026-08-01 incident is precisely a case where clicking would
have been no protection either.

**What is deliberately not gained.** No review, no approval, no trust. Anything
outside the bound still needs a human on the MR page, in both review modes.

**How it can go wrong, and what catches it.** The grant is only as narrow as the
three measurements. Each has a test that has been **observed red** with only the
source reverted (`tests/unit/test-merge-authority.bats`, plus end-to-end cases in
`tests/unit/test-mr-merge.bats` that assert on the wire — whether `PUT …/merge`
was actually sent). The prod-phase case runs against a fixture marked `prod`,
because no real site is prod and an inert guard nobody has seen fire is the
ops#214 class.

**The 2026-08-01 incident remains fixed.** That sweeper held no grant, matched no
declaration, and measured no diff. It would be refused today for the original
reason, unchanged.

## Alternatives considered

**A `--i-have-checked` flag, or an allowlist of "safe" MR labels.** Both are
assertions by the actor about itself. The whole point of keying on the
forge-verified identity in the first place was to stop trusting typed claims.

**Two-person review restored instead.** There is one human. ADR-0037 already
records why a two-person rule with one available person is a ritual rather than
a control.

**Let the bot merge everything and rely on the CI gate.** The CI gate reports;
the bound refuses. Reporting is not a bound, and the sensitive-path gate is
*reported* rather than held in solo mode precisely so the operator can click
once — which is the behaviour this ADR must not quietly convert into a machine
click.
