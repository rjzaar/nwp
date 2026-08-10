# ADR-0038: Instance names and instance state live in private overlay repos; the engine ships only the sample pair

**Status:** Accepted
**Date:** 2026-08-10
**Decision Makers:** Robert Zaar (operator ruling 2026-08-09, recorded on nwp/ops#326)
**Related Issues:** nwp/ops#326, nwp/ops#101
**Amends:** [ADR-0036](0036-site-classes-and-invariant-sets.md) in part — the
"tracked = in the engine repo" premise.
**Supersedes in part:** the withdrawal rationale of ADR-0021 (public-only repo
scope), which relied on a leakage gate that never covered *site names*.
**Relates to:** [ADR-0031](0031-paired-site-versioning-and-promotion.md),
[ADR-0037](0037-review-mode-follows-approvers.md) (the projection precedent),
F33 §10 (the phased move-out this revives).

## Context

**Operator ruling, 2026-08-09** (verbatim on nwp/ops#326; one instance name
redacted here, because this file is in the tree the ruling is about):

> "when I mean <a private formation site> is private, there should be a separation between the code
> itself nwp and the sites the code runs (ie each site in it's own repo).
> ideally there should be a generic auto-moodle site connected with a
> drupalguildcommons site which can be used by any particular curricula, eg ss
> being supported by nw. In this case ssd is shipped with nwd as a sample
> example."

`nwp/nwp` is the generic engine and is publicly mirrored (github.com/rjzaar/nwp,
ops#101). Two classes of thing had accreted in its tracked tree that are not the
engine:

1. **Instance names.** A real formation site's class declaration — its name,
   member cap and attestation history — was publicly readable. A census found
   ~4,700 word-boundary references to 19 private instance names across ~424
   tracked files, including two `pl` verb families *named after* private sites.
2. **Instance state.** `servers/` was deliberately re-tracked on 2026-07-25
   (the `.gitignore` flipped from blanket-ignore to allowlist) because "host
   configuration was versioned only when someone remembered `git add -f`". That
   put 95 files — nginx vhosts with real domains, the operator crontab, mail
   aliases, ufw rules, authorized keys, host inventories — into the public
   mirror.

The naïve fix (gitignore it all) collides head-on with two doctrines that are
**both correct**:

- **ADR-0036 reviewability:** "A claim that decides whether the Art.9 consent
  gate applies to a live formation site has to be reviewable in a merge
  request." Gitignoring a class declaration makes it unreviewable.
- **The 2026-07-25 versioning lesson:** load-bearing host state that lives only
  on a box is state that a rebuild loses. Gitignoring it re-creates exactly the
  gap the allowlist closed.

## Decision

**Tracked means tracked in *a reviewed repository*, resolved by a search path —
not "tracked in the engine repo".**

1. **The engine ships the sample pair and nothing else instance-shaped.** `nwd`
   (guild commons) + `ssd` (auto-moodle), `class: demo`, are legitimately named
   in-tree: they are the shipped example. Product code names stay
   (`nwc`, `ss-moodle-plugins`, frankenstyle plugin ids) — they name products,
   not instances (operator ruling, Q2).

2. **Declarations resolve through a two-element search path.** Shipped
   `classes/` · `pairs/` · `lib/sanitizers/` **first**, then the private overlay
   (`private/{classes,pairs,sanitizers}/`, each env-overridable). A declaration
   present in **both** fails closed as `contradictory` — never "first one wins
   silently". Undeclared remains exit 1; unreadable remains exit 2.

3. **Per-host state is versioned IN PLACE by a private per-server repository.**
   `servers/<host>/.git`, remote `nwp/server-<host>`. The files do not move, so
   every `pl` verb that reads `servers/<host>/…` reads the same path as before;
   only the repository boundary moves, and MR reviewability moves with it. The
   engine keeps generic mechanism only (installers, hooks, snippets, shipped
   systemd units, templates).

4. **The engine's CI must never need a private fact.** Where it seems to,
   either the check belongs to the overlay, or the fact deserves a
   *projection* (the `.nwp-review-mode` pattern from ADR-0037). Applied: the
   CI boundary and key-rotation jobs run against the **sample** pair contract;
   nginx capture-hygiene runs against a **shipped fixture** plus the real
   capture when a checkout has one.

5. **A permanent guard, whose deny-list is not in the repo.**
   `scripts/ci/lint-site-names.sh` + a shrink-only `.site-name-baseline`. The
   deny-list lives in `private/site-names.deny` and in a file-type CI variable;
   **no readable deny-list is exit 2 CANNOT VERIFY, never exit 0**. A tracked
   deny-list — or a hashed one — would itself be the leak (2–11 lowercase
   characters are dictionary-trivial to reverse).

6. **Verb names are API surface with no baseline tolerance.** The site-name
   lint is baseline-tolerant because it carries ~400 rows of migration debt; a
   `pl` verb or engine library *named* after a private instance is different in
   kind — it is printed by `pl --help`, it is the one reference a reader cannot
   avoid. `tests/unit/test-verb-name-privacy.bats` carries no baseline.

## Consequences

**Good**

- The public mirror stops disclosing instance names and infrastructure identity
  as new work lands; the baseline holds the remaining debt and can only shrink.
- Reviewability is preserved, not traded away: overlay repos have their own MRs,
  which in solo mode (ADR-0037) is a click, not a process.
- The versioning lesson is preserved: `pl doctor` now asks the *stronger*
  question — is `servers/<host>/` a repo, with a remote, pushed and clean? — and
  a host directory holding state with no repo is a named failure rather than a
  silent skip.
- Each guard asserts **both directions**: the generic mechanism must stay
  trackable *and* the identity state must stay untrackable, so a revert either
  way is visible.

**Costs, accepted**

- An operator clone needs the overlay repos present for full fidelity; a bare
  engine checkout resolves only the sample pair. That is the point.
- The first `git pull` after the split deletes the moved files from the working
  tree (they leave the engine's tree). They are recoverable exactly —
  `git -C servers/<host> checkout -- .` — and `pl doctor` prints that command.
- Git history still contains everything. **The history scrub is Phase 4 and is
  operator-gated on ops#101** (the mirror going private); until then the names
  remain in public history regardless of tree state.

## Alternatives rejected

| Alternative | Why not |
|---|---|
| Gitignore instance state, full stop | Breaks ADR-0036 reviewability and re-creates the 2026-07-25 "versioned only if someone remembers" gap. |
| Move the files to `private/servers/<host>/` | Every verb that reads `servers/<host>/…` would need repointing, and several read the path directly with no override. Moving the *repo boundary* costs nothing; moving the *path* costs everything. |
| A tracked deny-list, or a hashed one | The list would be the leak. Short lowercase names fall to dictionary attack in milliseconds. |
| Per-name rows in the baseline | Index churn, and post-scrub the rows would still group files by which unknown name they shared — a re-identification aid. |
| Rename the verb families instead of retiring them | Researched: one family's modules were never written ("will be enabled once created"), it had zero callers and zero tests, and it was superseded by the proven OIDC path; the other had exited 127 since the F23 layout change. Renaming dead code preserves nothing but the name. |
