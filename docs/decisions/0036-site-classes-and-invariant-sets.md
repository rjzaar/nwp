# ADR-0036: Site classes — what a site IS, and therefore which invariants apply

**Status:** Proposed (operator to accept)
**Date:** 2026-07-28
**Decision Makers:** Robert Karsten Zaar (to accept); drafted under nwp/ops#153
**Related Issues:** nwp/ops#153 (rgs Art.9 gate absent), nwp/ops#154 (the gate is
unsatisfiable on an unpaired site), ops#137 (the ship-together invariant),
ops#118 (the consent gate itself), ops#149 (`sites/rgs/.nwp.yml`), ops#103
(canonical plugin source)
**References:** [ADR-0030](0030-per-site-canonical-maturity-axes.md) (the two
existing per-site axes — this ADR adds the third and does not disturb them),
[ADR-0031](0031-paired-site-versioning-and-promotion.md) (pair contract, D6
`--code-only`), [ADR-0035](0035-erasure-propagation-op-to-rp.md),
`lib/moodle-gate.sh`, `lib/pair.sh`, `scripts/commands/contracts.sh`
(`key-rotation` — the conditional-arm pattern this ADR generalises).

---

## Context

`pl moodle gate-status rgs` reports:

```
mod/depthcontent             [UNGATED]
auth/nwc                     [ABSENT]   <- expected: rgs has no SSO
```

The Art.9 consent gate (ops#118/ops#137) requires a shipped artifact to carry
**≥1 `may_keep_formation` call delegating to `auth_nwc`**. `rgs` is **unpaired**:
no SSO, no OIDC consumer, no `auth_nwc`, and no nwc consent source to delegate
*to*. So **no artifact rgs can ever run will satisfy that check**. The only way
through `pl moodle plugin deploy` is `--allow-ungated`, every time, forever
(ops#154). Two such entries already sit in `private/moodle-gate/rgs.log`.

A gate that can only ever be overridden has stopped being a gate. It has become
a ritual — and worse, a *loud* ritual, which trains an operator to type past a
refusal that on a different site would be a genuine stop.

The root cause is not the gate. It is that **the estate now contains genuinely
different KINDS of site, and has exactly one undifferentiated gate set.** `ssc`
(real students, paired provider, UID-locked SSO) and `rgs` (live formation
content, no members yet, no provider at all) are asked the same question, and
only one of them can possibly answer it.

### What already exists, and what this must not duplicate

ADR-0030 gives every site **two orthogonal axes**, both shipped and enforced:

| Axis | Values | Question it answers | Enforced in |
|---|---|---|---|
| `canonical:` | `dev\|live\|prod` | which host is true for **content** | `lib/canonical.sh` |
| `maturity:` | `incubating\|stabilizing\|production` | how carefully **code** moves | `maturity_guard_deploy` |

Neither answers "**does the Art.9 consent gate apply here?**" That is not a
question about content direction or deploy ceremony. It is a question about
**what the site is and what data it holds** — and it is currently answered
nowhere, which is why it gets re-litigated per site, per deploy, by hand.

Note also a fact that shapes the design: **`nwp.yml` is never committed and
`sites/*` is gitignored.** Neither can carry a claim a reviewer needs to see.
`maturity:` and `canonical:` live in `nwp.yml`, which is acceptable for "how
careful are we with deploys". It is *not* acceptable for "this live formation
site is exempt from the special-category-data gate".

## Options Considered

### Option 1: Special-case rgs in `lib/moodle-gate.sh`
- **Pros:** smallest possible diff; unblocks ops#154 today.
- **Cons:** the next standalone site re-opens it; the exemption is invisible to
  review (a hardcoded site name in a library); and it encodes no evidence, so it
  cannot notice the day rgs takes a member — which ops#153 names as precisely
  the moment the exposure becomes real.

### Option 2: Widen the plugin-level `exempt` allowlist
- **Pros:** the mechanism already exists (`MOODLE_GATE_EXEMPT_DEFAULT`).
- **Cons:** wrong axis entirely. `mod/depthcontent` is *not* gate-free — it is
  gate-free **on this site**. Exempting the plugin globally would silently
  un-gate it on `ssc`, where real students' formation data lives. This option is
  actively dangerous.

### Option 3: A per-site CLASS axis with positively-evidenced N/A (CHOSEN)
- **Pros:** answers the question once, per site, in a reviewable place;
  composes with the two existing axes instead of competing; makes "this gate
  doesn't apply here" a *checkable claim* rather than a skip; generalises beyond
  Moodle/Art.9 to every invariant the estate carries.
- **Cons:** a third axis to hold in mind; one more thing to declare per site.

### Option 4: Forbid standalone sites from taking members at all
- **Pros:** simplest safety story.
- **Cons:** forbids rgs's stated purpose (a formation site built to take
  members). Rejected as a *class rule* — but adopted, in effect, as an
  *evidence* rule: see §Art.9 posture for rgs, where the member cap makes the
  exemption self-dissolving rather than the class permanently celibate.

## Decision

Adopt **Option 3**. A site declares a **`class:`** — a closed set of four —
answering "what IS this site, and therefore which data invariants bind it?"

### 1. The third axis, and how the three compose

```
  canonical:  where CONTENT is true      (dev | live | prod)
  maturity:   how carefully CODE moves   (incubating | stabilizing | production)
  class:      what the site IS           (member-paired | member-standalone
                                          | demo | service)
```

They are orthogonal and independently declared. A worked example, `ssc`:

```
canonical: live          content is authoritative on the live tier
maturity:  stabilizing   code deploys only from clean, merged main
class:     member-paired real students; consent+identity from the nwc pair
```

Changing one never implies the others. `rgs` is `class: member-standalone`
whatever its maturity; promoting rgs to `maturity: production` would harden how
its *code* ships and would not alter its Art.9 posture by one line.

**Critically, the defaults differ, and deliberately.** ADR-0030 says absent
`maturity` = `incubating` = today's behaviour, because a permissive default on
the code axis costs a little review ceremony. On the **data** axis a permissive
default would mean "assume no members, assume no special-category data" — an
assertion no machine may make on no evidence. So:

> **Absent `class` is `undeclared`, and `undeclared` is non-zero.** It is not
> "no constraints"; it is "nobody has said what this is", and nothing that
> depends on knowing may proceed on it.

### 2. The four classes, and the decision procedure

Answer in order. **First match wins.** Each branch turns on a checkable fact.

1. **Does the site hold, or is it intended to hold, accounts belonging to real
   people who are not operators of the estate?**
   - No, and all accounts are seeded/synthetic and the site is resettable → **`demo`**
   - No, and there are no non-operator accounts at all → **`service`**
   - Yes → question 2
2. **Does an external paired provider supply identity and consent** (a contract
   exists in `pairs/`, `identity.uid_lock: true`)?
   - Yes → **`member-paired`**
   - No → **`member-standalone`**

| Class | Sites | Art.9 | Erasure | Pair contract | UID-lock `--code-only` | Real member PII |
|---|---|---|---|---|---|---|
| `member-paired` | `nwc`, `ssc` | REQUIRED (delegated) | REQUIRED | REQUIRED | REQUIRED | YES |
| `member-standalone` | `rgs` | REQUIRED (local, or exempt-by-evidence) | CONDITIONAL | FORBIDDEN | N/A (asserted) | CONDITIONAL |
| `demo` | `nwd`, `ssd`, `nwt` | N/A (asserted) | N/A (asserted) | OPTIONAL | OPTIONAL | FORBIDDEN |
| `service` | *(operator to ratify — see §Migration)* | N/A (asserted) | N/A (asserted) | FORBIDDEN | N/A (asserted) | FORBIDDEN |

Two classes were considered and **merged**, on the rule that *classes must
differ in which invariants apply, not merely in vibe*: a `public-readonly`
content site (dir1, ba, mt, cathnet, mayo) and an `internal` tooling site (fin)
have **identical** invariant vectors — no members, no Art.9, no erasure subject,
no pair. They are one class, `service`. Resisting the fifth class is the point:
an axis with ten values is a taxonomy, not a gate.

### 3. How "N/A" is asserted POSITIVELY

This is the load-bearing half. The project's recurring defect is a check that
cannot fail; a class that let a site *skip* a gate would industrialise that
defect. So:

> **A class may RECLASSIFY a gate failure into an evidenced exemption. It may
> never suppress the scan that produces the failure.**

Mechanically, in `lib/moodle-gate.sh`, the class is consulted **only on the
failure path**. An artifact that passes the ordinary ops#137 scan passes
regardless of class. This has two consequences worth stating plainly: declaring
a class can never *newly refuse* a site that used to deploy (so day-one breakage
is nil), and it can never *silence* the scan (so the evidence trail is intact).

Each class names a required **Art.9 posture**, and every posture carries a
positive obligation — the pattern proven by `pl contracts key-rotation`, where
`consumer_verifies_signature: false` REQUIRES a positive scan showing no
verification code exists, and an unreadable corpus is CANNOT-VERIFY:

> *"Absence of evidence is not a pass."* — `scripts/commands/contracts.sh`

| Posture | Obligation (all checked) | Failure tokens |
|---|---|---|
| `delegated` | a pair contract must exist; `consent_source` must equal its provider; the artifact must delegate to it (the ops#137 scan, **unchanged**) | `NO-CONSENT-SOURCE`, `CONSENT-SOURCE-MISMATCH` |
| `local` | a local consent source must be **named** and its root must **exist on disk**; the artifact must delegate to *that* class | `NO-LOCAL-CONSENT-SOURCE`, `LOCAL-SOURCE-ABSENT` |
| `none-stored` | `probe_cmd` non-empty; a full attestation present; attestation fresher than `max_age_days`; `formation_rows == 0`; `member_count <= max_members`; `expires` in the future | `NO-PROBE`, `NO-ATTESTATION`, `STALE-ATTESTATION`, `EVIDENCE-CONTRADICTS`, `MEMBER-CAP-EXCEEDED`, `EXEMPTION-EXPIRED` |

`none-stored` — the only posture that lets an artifact ship without a gate call
site — is deliberately the posture with the **most** obligations. It costs more
to declare than `--allow-ungated` costs to type, and unlike `--allow-ungated` it
**expires** and it **notices members**.

Four further anti-vacuity properties:

- **The class must permit the posture.** A `member-paired` site cannot declare
  `none-stored`, however perfect its evidence — `POSTURE-NOT-PERMITTED`. This is
  what stops the axis becoming a way to quietly downgrade `ssc`.
- **The declaration must be reviewable.** The authoritative record is the
  **tracked** `classes/<site>.class.yml`. A class declared only in gitignored
  config is `cannot-verify:config-only-no-tracked-declaration` — refused, because
  a claim no reviewer can see is not a claim.
- **Sources must agree.** `classes/<site>.class.yml` is the source of truth; the
  `class:` keys in `sites/<site>/.nwp.yml` and `nwp.yml` are *also honoured*, and
  a disagreement is `contradictory:` and fails closed. This is exactly the shape
  `lib/pair.sh` already uses for pair membership.
- **Using an exemption is an event, not just a setting.** Every exempted deploy
  appends `action=class-exempt` with its evidence to
  `private/moodle-gate/<site>.log` — the same ledger that already holds rgs's two
  `action=allow-ungated` lines, so the file reads as one continuous story.

`--allow-ungated` is **kept**, unchanged, for genuine one-offs. The difference is
that it is no longer the *only* door, so its use stops being routine.

### 4. Art.9 posture for a standalone formation site — the rgs recommendation

The question ops#153 actually asks: *what is the Art.9 posture for a standalone
formation site with no consent source?* The three honest options:

- **(a) A local consent source.** Correct, and the **required exit** — but it is
  real Moodle work (a consent record `may_keep_formation` can delegate to), and
  it must not be faked with a stub that makes the gate green while consenting
  nobody.
- **(b) "Stores no formation data" as a checkable assertion.** True of rgs
  *today*, verified on the box 2026-07-28: `depthcontent_progress` = 0 rows, no
  consent/art9/nwc tables at all, 1 non-admin user (the sample account, last
  login 2026-07-08 — deploy day).
- **(c) Forbid the class from taking members.** Safe, but it forbids the site's
  purpose.

**Recommendation: (b), bounded by (c)'s cap, with (a) as the mandatory exit.**

These are not three options but one mechanism. rgs declares `none-stored` with
`max_members: 1` and an attested `formation_rows: 0`, expiring **2026-10-31**.
The cap means the exemption **dissolves automatically the day rgs takes a second
account** — which is exactly the condition ops#153 identifies ("it becomes one
the day rgs takes a member"). That sentence stops being a paragraph someone must
remember and becomes a check that goes red. The expiry means that even if
nothing changes, the claim must be re-argued before winter.

This is strictly safer than the status quo, which is an unbounded
`--allow-ungated` habit with no evidence, no cap, and no expiry.

The exit to posture `local` is recorded in `classes/rgs.class.yml`, along with
its three real blockers, none of which this ADR pretends to solve:

- ops#154 — two unbuilt AMD modules also block `pl moodle plugin deploy`;
- ops#103 — rgs has no canonical buildable source in any repo with a remote (its
  build tree lives on `mini:~/nwp/sites/rgs`);
- **version skew** — rgs runs `mod_depthcontent` 2026072801, ssc/ssd run
  2026072600. Moodle refuses a version downgrade, so the gated ssc copy cannot
  simply be moved onto rgs; the gate has to come **forward** onto rgs's line.

### 5. Relationship to the mons boundary

The class axis is **advisory about data, never about deploy authority**. It does
not touch the ADR-0017 mons boundary, the A14 test-tier rule, or
`deploy_gate_require`. A `service` class does not make a prod write acceptable to
an AI-run host; `maturity: production` and the mons boundary continue to govern
that, unchanged. Guard ordering is unchanged:
`maturity_guard_deploy` → `pair_guard` → `deploy_gate_require`, with the Art.9
assertion where it already sat.

## Consequences

### Positive
- "Which gates apply to this site" is answered by declaration, once, in a
  reviewable file — not re-derived per deploy.
- rgs gets a satisfiable posture, so `--allow-ungated` stops being permanent.
- The exemption is self-dissolving: the first real member trips it.
- The rule generalises — erasure, pair, and sanitize invariants are already
  expressed per class and can be wired to the same evidence discipline.

### Negative
- A third axis to learn, and one more per-site declaration to maintain.
- `classes/` is a new tracked directory whose review burden is real (that is
  also its purpose).
- The `service` class currently has **no** ratified members: classifying a site
  as "has no members" is an operator assertion, and the migration deliberately
  refuses to guess it.

### Neutral / migration
- **`CURRENT_SITE_SCHEMA` 2 → 3.** `lib/migrations/site/003-site-class.sh` adds
  `class:` as **null** with a pointer comment and **guesses nothing**.
  Auto-classifying would be the exact failure this axis prevents: writing
  `class: service` onto a Moodle site the migration has never looked inside is a
  machine asserting "this site has no members" on no evidence — and that
  assertion is what switches the Art.9 gate off.
- **What breaks on day one: nothing deploys differently.** The class is consulted
  only on an already-failing gate path, so no site that deploys today stops
  deploying. The visible changes are (i) `pl doctor` reports 18 site configs as
  schema-stale until `pl site migrate` runs, and (ii) `pl class show` lists every
  undeclared site — which is the intended prompt, not a regression.
- **Shipped declarations: two.** `classes/rgs.class.yml` (the site that forced
  this) and `classes/ssc.class.yml` (the negative control — properly paired,
  `delegated`, exempt from nothing). The remaining ~16 sites are left
  `undeclared` on purpose; each is an operator assertion about real people's
  data, and the ADR's table above is a *proposal* for that ratification, not a
  fait accompli.

## Implementation Notes

- `classes/registry.yml` — the closed set, the decision procedure, the invariant
  matrix, the posture obligations. Tracked.
- `classes/<site>.class.yml` — per-site declaration + evidence. Tracked.
- `lib/siteclass.sh` — pure resolver/checker (no ssh, no network, no secrets);
  `siteclass_of` is tri-state (0 declared / 1 undeclared / 2 cannot-verify).
- `scripts/commands/class.sh` — `pl class show|check|set|list|evidence`.
- `lib/moodle-gate.sh` — consults the class on the failure path only; posture
  `local` retargets the required delegation class; `none-stored` + valid evidence
  yields `EXEMPT BY EVIDENCE`, ledgered.
- `tests/unit/test-siteclass.bats` — 28 tests, built as sabotage: every
  obligation of `none-stored` is broken individually and asserted to fail with
  its own token, plus the abuse case (a paired site cannot buy an exemption) and
  a negative control (a properly-evidenced site passes).
- **Deferred deliberately:** `pl class evidence --refresh` (re-attesting means a
  live DB read, which needs a `pl server health` preflight and does not belong in
  a gate library — it refuses with the exact probe to run); wiring the class to
  the erasure/pair/sanitize invariants beyond reporting; ratifying the ~16
  undeclared sites.

## Review
**30-day review date:** 2026-08-27
**Review outcome:** Pending
