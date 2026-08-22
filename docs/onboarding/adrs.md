# ADRs — the decisions a reviewer needs to recognise

**Audience:** Coder, recognizing which decisions apply to a PR under review.
**Status:** v2 — 2026-08-22 (ops#383; supersedes the v1 numbered cheat-sheet).
**Read time:** 10 minutes.

This is a **reviewer's orientation page, not a decision register.** The register is
the profile repo's own `docs/decisions/` directory; this page tells you what the
decisions there *feel like* when they show up in a diff, so you recognise one
before you approve something that contradicts it.

## Which series, and how to cite it

Two ADR series exist and their numbers collide. Always write the prefix:

- **`NWC-ADR-NNNN`** — the **nwc site profile** decisions. Files live in the nwc
  profile repo at `profiles/custom/nwc/docs/decisions/NNNN-slug.md`. Everything
  on this page except where noted is one of these.
- **`NWP-ADR-NNNN`** — the **engine** decisions, in this repo at
  [`docs/decisions/`](../decisions/index.md). Infrastructure, deploy pipeline,
  secrets, verification.

`NWC-ADR-0017` (Media Guild promotion) and `NWP-ADR-0017` (distributed
build/deploy pipeline) are different documents about different things. A bare
`ADR-0017` names neither, which is why `lint:adr-namespace` rejects it. <!-- adr-namespace:literal -->

> **What v1 of this page got wrong, recorded so it is not re-invented.** It
> assigned its own numbers — 0020, 0021, 0022, 0023, 0030, 0031, 0032, 0040,
> 0050, 0051, 0060, 0061, 0070 — banded 10/20/30/40/50/60/70 so its sections
> would sort tidily. Six of those numbers named no file in any repo. The rest
> collided with real engine ADRs: its "Editorial state machine" at 0020 read as
> the engine's *tiered architecture model*, and its "Copyright clearance gate"
> at 0023 pointed at a number the engine has deliberately left reserved. The
> numbers bought formatting and cost correctness, so they are gone. Nothing was
> renumbered to fix this — the invented numbers were simply deleted, because
> they were never anybody's identifiers.

## If you only remember three things

1. **A PR that contradicts an ADR is at minimum a T3.** It needs a new ADR
   superseding the old one. No quiet contradictions.
2. **An ADR is amended, not edited.** If a PR's diff changes an existing ADR
   file (other than adding a `Superseded by:` line), reject and ask for a new ADR.
3. **Check `Accepted` vs `Superseded`.** Superseded ADRs document history;
   Accepted ones constrain new code.

---

## Decisions affecting most PRs

**NWC is the platform, not a framework** — `NWC-ADR-0001`. NWC is a real, named
product with a canonical deployment; it is not a generic CMS anybody instantiates.
Forks are allowed but must rename. *You'll see this when* an agent PR refactors
`nwc_*` modules into something prefix-neutral, or proposes a "framework layer".
That is scope creep against a settled decision — push back.

**Three guilds plus Stewards** — `NWC-ADR-0002`. Guilds, Stewards and Interest
Groups are distinct things with distinct authority; an Interest Group has **zero**
routing authority. Promoting one to a guild is gated on a triple-test (sustained
bottleneck + enough eligible members + a named steward). *You'll see this when* a
PR grants routing or approval power to something that is currently an IG.

**Decision visibility tiers** — `NWC-ADR-0010`. The public Decision Log has three
tiers: `Stewards`, `Members`, `Public`. New decision-log nodes default to
`Stewards`; broadening is an explicit per-node act. *You'll see this when* a PR
touches `field_visibility_tier` defaults or the access check in
`nwc_decision_log`. Watch for defaults silently shifting outward.

**Two-site topology** — `NWC-ADR-0015`. NWC runs as a canonical site plus a demo
site; both are first-class, both deploy from the same repo. The Moodle side is
paired to each. *You'll see this when* a PR fixes something in the canonical site
without mentioning the demo. Ask explicitly whether it applies to both: a
profile-local diff auto-applies via the rsync, but an infra change (nginx, ddev)
must be checked on both.

**Parallel-install deployment, not multisite** — `NWC-ADR-0016`. The demo site
deploys by *rsyncing* the same `profiles/custom/nwc/` tree into a second codebase.
The two sites share zero runtime state. *You'll see this when* the deploy log
shows two rsync steps. If one fails, both must fail — never a silent half-deploy.

---

## Decisions affecting editorial PRs

**The editorial state machine is template-driven** — `NWC-ADR-0006`. This is the
big one for editorial work, and it decides three things people often cite
separately:

- All state transitions of `editorial_revision` go through the state service.
  Direct writes to the `state` field are forbidden.
- A revision's `change_kind` (typo, pedagogical, doctrinal, hotfix…) selects
  which review stages it **skips**, via templates declared as constants. Adding a
  new template is a T3 decision.
- The guards — copyright clearance, hotfix justification, trial completion —
  live **in the service**, not in its callers. In particular, a revision cannot
  leave copyright clearance without a recorded clearance (justification, a
  cleared-by user, a timestamp).

*You'll see this when* any change lands in `nwc_editorial/`. Look for a direct
`set('state', …)` outside the service, a new `CHANGE_*` constant, or a guard being
made optional. All three are reject-or-escalate.

**Anti-self-review (Policy Z)** — `NWC-ADR-0007`. Reviewers may hold several
skills, but nobody reviews their own work; the pairing rule excludes the task
author. *You'll see this when* a PR touches pool resolution or pairing config —
`anti_self_review` quietly flipping to false is the failure mode.

**Solo approval only via an auditable scope grant** — `NWC-ADR-0008`. One-person
approval is legitimate *only* as an explicit, recorded grant, never as an implicit
fallback when no second reviewer is available. *You'll see this when* a PR adds a
"if no reviewer is available, proceed" branch. That is the decision inverted.

**Role-based routing** — `NWC-ADR-0009`. Approval routing keys off roles, not
badge predicates. *You'll see this when* a PR starts computing eligibility from
accumulated badges — that is the rejected alternative.

**Pipeline-origin content is first-class** — `NWC-ADR-0011`. Auto-generated
content enters the same pipeline as human-authored content, with operator
accountability attached; it is not exempt and not silently published.

**ADRs live in files, synced to entities** — `NWC-ADR-0013`. The files are
canonical; the in-site `decision_record` entities are a projection for
presentation. *You'll see this when* a PR edits the entity as though it were the
source. It is not.

---

## Decisions affecting content and deployment PRs

**Demo content policy** — `NWC-ADR-0014`. The shipped curriculum content is demo
content for the platform: reviewed upstream during authoring, published on
install, and never updated in place — updates arrive as new draft revisions
entering the receiving site's own workflow, and local edits win.

**Two-tier deployment (trial → production)** — `NWC-ADR-0012`. The trial tier is
the gate between "approved in editorial" and "shown to the trialing guild".
Content does not skip it.

**Media Guild, dual attestation** — `NWC-ADR-0017`. The Media Guild was promoted
from an Interest Group and reviews by *structure*, not by gatekeeper: two members
independently proposing the same change on the same slot is the approval. Its
remit is explicitly **not** theological formation — that routes to the formation
guild. *You'll see this when* a clip/media PR asks for a single-approver path, or
routes a formation question to Media.

**Guild leveling** — `NWC-ADR-0018`. Levels are within-guild; there is no
cross-guild shared level layer. Sojourners transitions into Theology by a defined
path.

---

## Engine decisions that reach into profile PRs

These are `NWP-` series and live in [this repo's register](../decisions/index.md):

- **`NWP-ADR-0017`** — distributed build/deploy pipeline. Trust flows through
  signatures, not machines; no AI-accessible host writes to prod. This is why you
  cannot SSH to a live host, and why deploys originate from the offline box.
- **`NWP-ADR-0004`** — two-tier secrets. `.secrets.yml` (infrastructure, readable)
  versus `.secrets.data.yml` (user data, not). A PR moving a credential across
  that line is an operator action, not a coder one.
- **`NWP-ADR-0028`** — the human-gated deploy workstation, and the hardware-token
  gate on prod writes.
- **`NWP-ADR-0037`** — review mode follows `approvers:`. It decides whether one
  approval or two is required, and it is declared in exactly one place.

---

## There is no "draft ADR" you can implement

v1 of this page listed three drafts (digest emails, cross-stack search
federation, trial cohort sizing) under invented numbers. They were never ADRs and
had no files. **If a PR claims to implement a draft ADR, push back hard** — it is
reading future intent as present commitment. A decision that is not written down,
with a number and a status, is not a decision yet.

---

## How to write a new ADR, if a PR is missing one

You probably won't author one, but if a PR needs one and you can sketch the shape:

1. Take the next unused number **in the series you are writing for** — the profile
   series for profile decisions, the engine series for engine decisions. Never
   reuse a number, and never renumber an existing ADR.
2. File it as `NNNN-short-slug.md` in that repo's `docs/decisions/`. The filename
   stays bare; the directory is the namespace.
3. Header: `# NWC-ADR-NNNN: <Title>` (or `NWP-` for engine), then
   `**Status:** Proposed | Accepted | Superseded by <PREFIX>-ADR-NNNN` — exactly
   one `**Status:**` line, in that shape, or `pl doc-truth`'s `adr-hygiene` check
   fails the build.
4. Body: `## Context`, `## Decision`, `## Consequences`, `## Alternatives considered`.
5. Reference it from the PR description with the prefix. Bare `ADR-NNNN` fails
   `lint:adr-namespace`.

For agent-generated PRs the agent should produce the ADR alongside the code
change. If it didn't, that is a T3 reject.

---

## See also

- [`docs/decisions/index.md`](../decisions/index.md) — the engine register, and
  the full statement of the namespace rule
- [architecture-brief.md](./architecture-brief.md) — what the decisions are
  talking *about*
- [pr-review-checklist.md §6](./pr-review-checklist.md#6-special-checks-for-t3) —
  when to demand an ADR draft
