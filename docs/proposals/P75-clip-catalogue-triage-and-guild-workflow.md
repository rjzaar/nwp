# P75 — The clip catalogue is wrong and the guild has no workable process

**Status:** PROPOSED — research and design only. No code, no schema, no live write, no golden
shipped with this document.
**Owner:** *(unassigned)*
**Issue:** [nwp/ops#337](https://git.nwpcode.org/nwp/ops/-/issues/337) · follows
[ops#336](https://git.nwpcode.org/nwp/ops/-/issues/336) (P3 granularity)
**Predecessors:** P64 (clip choice as data, not content) · ADR-0017 (Media Guild promotion) ·
ADR-0006 (anti-self-review) · P73 (editorial authorization hardening — the `unilateral` stamp
pattern reused in §3)
**Evidence base:** `~/dir/courses_v3/build/reports/clip-granularity-correction.md`,
`~/dir/courses_v3/build/reports/current-clip-vs-rubric.md`,
`~/dir/courses_v3/build/CRITERIA-V3-ADDENDUM.md`,
`~/dir/courses_v3/history/corpus_v2/CRITERIA.md`,
`~/dir/courses_v3/catalog/*.yaml` (56 course files, read 2026-08-11),
`.../nwc_guild/config/install/guilds/media-guild.yml` (476 lines),
`.../nwc_features/nwc_clip_review/` (code map, read-only, 2026-08-11), and read-only
`pl drush {nwc,nwd} --tier=live --execute -- sqlq` measurements taken 2026-08-11.

Everything in this document that is a number is a measurement with the command or path that
produced it. Everything that is a preference is labelled as a recommendation with what the
alternative loses. Everything that needs the operator is collected in §8.

---

## 0. The finding that reframes the problem

The review workflow has **never once run**. Measured read-only on `nwd` live, 2026-08-11:

```
pl drush nwd --tier=live --execute -- sqlq \
  "SELECT (SELECT COUNT(*) FROM users_field_data WHERE uid>0) AS users,
          (SELECT COUNT(*) FROM nwc_lp_review_slot) AS slots,
          (SELECT COUNT(*) FROM nwc_video_snippet) AS snippets,
          (SELECT COUNT(*) FROM nwc_clip_suggestion) AS suggestions,
          (SELECT COUNT(*) FROM nwc_learner_signal) AS signals,
          (SELECT COUNT(*) FROM nwc_clip_review_decision) AS decisions"

users  slots  snippets  suggestions  signals  decisions
27     176    1275      0            0        0
```

176 slots, all `depth=standard`, all `status=pending`; 1,275 candidate snippets, all
`origin=rubric`. **Zero suggestions and zero decisions in the module's entire life.** On `nwc`
live the same tables are empty at 0/0/0/0.

Who can act, measured the same way:

| | nwd live | nwc live |
|---|---|---|
| accounts (uid>0) | 27 | 2 |
| ever logged in (`access>0`) | **10** | 2 |
| role `administrator` | 2 | 2 |
| role `sitemanager` | **0** | 0 |

`apply clip suggestion` is granted at install to `sitemanager` and `administrator`
(`nwc_clip_review.install:42–63`). There is no `sitemanager`, so **exactly two accounts on the
whole estate can apply a clip**, and one person is doing the work.

So this is not a backlog problem with a staffing solution. It is a **process that has never been
exercised**, in front of a **queue of 1,177**, worked by **one person**. Every design choice below
follows from those three facts, in that order.

---

## 1. Triage — make the queue self-prioritising

### 1.1 What is actually wrong, counted

From `current-clip-vs-rubric.md` (175 rankable of 176; `B2.04` is CANNOT VERIFY — §7):

| | count |
|---|---|
| is its LP's top candidate | 3 |
| is **not** its LP's top candidate | 172 |
| would appear in the reviewer's top-8 | 27 |
| would **not** | 148 |
| median rank | 31 |
| in the bottom decile of its own ranked list | 35 |
| overlaps **no** candidate the rubric found | 66 |
| shorter than the rubric's own minimum run (90 s) | 24 |
| below the smallest duration bucket (2 min) | 61 |
| composite score below zero | 3 |

And from the catalogue itself, counted directly across the 56 course files:

```
window "0:00"–"8:00", exactly:            64 of 176   (36%)
distinct (episode, start, end) reused:    12 tuples across 25 clips
distinct episodes cited by all 176 clips: 108
duration: min 32 s · median 151 s · max 480 s
```

**Sixty-four of the 176 clips are the first eight minutes of an episode.** That single figure
carries more triage signal than the whole ranking table, and it is independent of the rubric —
see §5.

Empty slots, counted from the same files (`depths` keys present per learning point):

```
short 251 · standard 250 · longer 242 · detailed 217 · advanced 217   = 1,177
video: blocks present:                    176, all on `standard`
standard slots with no clip:              74
learning points with no clip at any depth: 75
non-standard-depth slots, never attempted: 927
```

### 1.2 The design: bands of *evidence*, then prominence, then episode batching

A flat 1,177-row list is unworkable and a single blended priority score is untrustworthy — it
would be exactly the opaque ranking the estate rejected when it chose an inspectable rubric over
ML (`CRITERIA.md` §"Why not just ML?"). So the queue is ordered by a **band**, which is a
statement about *evidence*, and only sorted *within* the band by anything continuous.

| Band | Definition (all measurable today) | n | Why it is where it is |
|---|---|---|---|
| **0 · DEFAULTED** | window is exactly `0:00–8:00` | **64** | Evidence of *non-selection*, not of low quality. Needs no rubric argument. |
| **1 · BROKEN** | shorter than the 90 s minimum run (24), or composite < 0 (3, disjoint), or unresolvable (1) | **28** distinct, of which 3 also sit in B0 | Structurally unusable whatever the topic. Defects, not preferences. |
| **2 · CONTESTED** | not in B0; gap to top ≥ 6 or composite < 2 | **34** | Rubric and human disagree loudly. This is where rubric-blindness actually lives (§5). |
| **3 · CONFIRMABLE** | not in B0; already rank ≤ 8 in its own list | **18** | Seconds each. 3 are already #1; 6 have gap < 1. |
| **4 · MID** | the remainder | **59** | Lowest value per hour. Defer. |
| **5 · EMPTY standard** | LP has no clip at all | **75** | New work, not repair. |
| **6 · EMPTY other depths** | short / longer / detailed / advanced | **927** | §6 recommends these are never slots at all. |

(Bands 0–4 partition the 175 rankable clips: 64 + 34 + 18 + 59 = 175, with Band 1 cutting across
Bands 0/2/4 as a flag rather than a fifth bucket.)

**Within a band, order by prominence — from data the catalogue already carries, not opinion:**

1. `pathways:` contains `beginner` — 16 courses, **74 learning points** (`A1 A2 A3 A4 A5 A6 A7 A8
   B1 B2 B3 B4 B5 B6 E4 H1`). These are the clips a new member meets first.
2. `tier.min` ascending — 23 courses sit at tier ≤ 1.
3. LP sequence within the course. A broken clip on `A1.01` is the most-seen clip in the estate.

Cross-tabulated, this is not a rounding effect:

| Band | n | of which in a `beginner` course |
|---|---|---|
| 0 · DEFAULTED | 64 | 5 |
| 2 · CONTESTED | 34 | **16** |
| 3 · CONFIRMABLE | 18 | 6 |
| 4 · MID | 59 | 25 |
| 5 · EMPTY | 75 | **21** |

**Then batch by episode.** Auditioning an episode is the expensive act — a 25–40 minute listen.
Trimming a second range out of an episode already loaded is nearly free. Measured on
`_runs_v3.json` (8,626 candidates):

```
251 LP top candidates draw on only  69 distinct episodes
38 episodes are the top candidate for >=3 LPs, covering 216 of 251 LPs
ep 609 is the top candidate for 22 LPs; ep 580 for 17; ep 225 for 11
the 176 live clips draw on 108 distinct episodes; 13 episodes serve >=3 clips
```

So a reviewer who listens to episode 609 once is holding the context for up to 22 tasks. The
queue should offer them.

> **Honest caveat.** Part of that concentration is real (DIR returns to the same subjects) and
> part is the residual pooling §4 exists to fix — 193 of 251 LPs still share a top with a sibling.
> The batching gain is real *today* and will shrink as the tags land. That is fine: batching is an
> ordering, not a commitment, and nothing downstream depends on it staying true.

### 1.3 What "self-prioritising" means concretely

**A volunteer must never see 1,177 rows.** The queue surface is:

- one **"next task"** action that pops the head of the ordered queue;
- a **band summary** (six numbers) so the shape of the work is visible without being the work;
- the batch: "you are in episode 609 — 6 more slots this episode can serve".

Everything needed to compute the order already exists and is already stored. The obstruction is
presentational and is being fixed in the ops#336 P1 lane: the queue controller hard-caps at
`->range(0, 100)` sorted by `changed DESC` (`ReviewQueueController.php:14–18`), so **76 of the
176 slots are unreachable**; `'#filters' => []` is returned and never rendered
(`ReviewQueueController.php:37`); there is no pager anywhere in the module.

### 1.4 What is deliberately *not* in the priority key

- **Learner signal.** `nwc_learner_signal` has **0 rows**, and the cross-site bearer token is
  empty on `nwd` live (`config:get nwc_feedback.cross_site bearer_token` → `''`, recorded in
  ops#336), so the endpoint rejects everything and the value can only ever be 0. Putting it in the
  key now would be a term that has never been observed non-zero — a check nobody has seen fire.
  Name it as a future tie-breaker with a **stated arming condition** (first non-zero signal row),
  and leave it out until then.
- **Rank gap alone.** The gap is a rubric-internal quantity, so sorting by it sorts by *how loudly
  the rubric disagrees* — precisely the axis on which the rubric can be wrong. It is a
  within-band sort, never the band itself.
- **Endorsement count.** Self-endorsement is unguarded today
  (`ClipSuggestionService::endorse()` has no author check, while `nwc_guild`'s
  `EndorsementService.php:79` does), so the number is not yet evidence of anything.

---

## 2. The unit of work

### 2.1 The guild's own rule decides this, not convenience

Media Guild skill #5, verbatim from `media-guild.yml`:

```yaml
- code: 'clip-selection'
  name: 'Clip Selection'
  task_unit: 'One clip proposed (time range + brief rationale)'
  match_rule: 'time_range_iou:0.7'
  match_description: 'Time-range IoU ≥ 0.7 between the two clips'
```

**IoU is undefined across episodes.** You cannot compute the intersection-over-union of a range in
episode 156 against a range in episode 295 — the answer is not 0, it is *meaningless*. So if the
unit of work is "find and propose a clip for this slot", the guild's own matching rule is
undefined for most pairs, and the pairing machinery misreads "we searched differently" as
"someone is wrong". The spec then flags the whole cohort: `non_matcher_review_threshold_pct: 30`.

The measured scale of that risk: **66 of the 175 live clips overlap no candidate the rubric
found**, and the candidate pool spans **591 distinct episodes**. Two independent reviewers turned
loose on 648 episodes will not converge on an episode by accident.

### 2.2 Recommendation: one slot, two stages, both already skills in the spec

**Unit of work = one `(learning point, depth)` slot.** The task on that slot has two stages, and
each stage maps to a skill the guild has already locked, with a match rule that is already
well-defined for it:

| Stage | Question | Guild skill | `task_unit` | `match_rule` |
|---|---|---|---|---|
| **A · SOURCE** | which episode? | #7 `course-mapping` | 'One clip mapped to a v3 Saint School (course, session) target' | `course_session_tuple_exact` |
| **B · TRIM** | which range within it? | #5 `clip-selection` | 'One clip proposed (time range + brief rationale)' | `time_range_iou:0.7` |

Stage A is discrete and exactly-matchable. Stage B's IoU is well defined because both members are
trimming **the same audio**. Nothing new is invented; the two-step process is already written into
the twelve skills, and reading it that way is what makes the tolerance meaningful.

This also closes a measured dead end. `VideoSnippet::ORIGIN_SUGGESTED_NEW` has **zero writers**
anywhere in the codebase, and `ClipSuggestion::KIND_NEW_CLIP` is selectable in the form but has no
code path that creates a snippet for it — `ClipSuggestionForm::validateForm()` requires an
existing `proposed_snippet` entity id for every kind except `re_trim`, typed by hand into a
`#type => 'number'` field. **Proposing a genuinely new clip is not possible today.** Stage A *is*
that missing act, and the corpus search shipped in `nwp/dir1-project!1` is its instrument.

### 2.3 The alternatives, and what they lose

- **One LP across all depths.** Loses on two counts. 927 of the 1,177 slots are non-standard
  depths and §6 recommends they should not be slots at all — bundling depths bundles work that
  should not exist. And depth is a *length* axis in the schema (`short` = 35–60 words, `standard` =
  300–500), so a bundled task silently asks for several different trims under one credit.
- **One episode across every slot it could serve.** Attractive — 38 episodes cover 216 of 251 LP
  tops — but wrong as the *unit*: the credit becomes unbounded and variable (22 slots for ep 609,
  1 for a long tail), and the guild's per-skill task counts (`5 matched pairs` → Practitioner)
  stop meaning a comparable amount of work. **Adopt it as the batching key, not the unit** (§1.2).
  Batch = episode; unit of credit = slot.
- **The whole course as a unit.** Loses the ability to stop. A volunteer must be able to finish
  something in one sitting; the median course has 4–5 LPs and an episode audition each.

---

## 3. Trust and throughput — how blind dual attestation and one active human meet

### 3.1 What exists today, measured

| Guard | Status |
|---|---|
| Separation of proposer and applier | **Does not exist.** `ReviewDecisionService::apply()` checks four things: writer present, `apply clip suggestion` permission, suggestion belongs to slot, suggestion active. It never compares `suggestion.author` to the acting user. |
| Anti-self-review | **Does not exist.** `grep -rniE "self[_ -]?review\|author.*!==.*admin"` over the module returns nothing. |
| Blind review | **The opposite is built in.** `ApplyDecisionForm.php:44–51` renders each option as `'#%d %s by %s — %s endorsements%s'` — author name and endorsement count shown to the decider. |
| Dual attestation / IoU / pairing | **Does not exist in `nwc_clip_review`.** `grep -rniE "blind\|dual[_ ]?attest\|attestation\|\biou\b\|time_range\|\bpair"` returns nothing. |
| Guild membership consulted | **Nowhere.** The only coupling is one fire-and-forget call *after* the apply is already authorised. |
| Clip work earns skill credit | **No.** `MediaLevelingService::recordAppliedClip()` awards a recognition point and **deliberately no `SkillCredit`**; the ladder is fed solely by `recordMatchedPair()`, which **has no caller anywhere**. |
| Self-endorsement | **Allowed.** `ClipSuggestionService::endorse()` de-duplicates the same user but has no author check. |
| `doctrinal_blocker` override "is recorded" | **Not implemented.** `DoctrinalBlockerForm.php:39` promises it; `ReviewDecision` has no field for it and `apply()` writes nothing. |
| `STATUS_LOCKED` | **Unenforced and unreachable** — `lock()` has no route and no caller. |

So: today one person can propose and apply with no separation at all, and doing so advances
nothing on the ladder the guild spec is built around.

### 3.2 The spec already answers this — it simply was not built

Three clauses of `media-guild.yml`, quoted:

```yaml
sampling:
  - { tier: 'pre_approval', fraction: 1.0, note: 'Working toward Practitioner — every task dual-attested.' }

locked_choices:
  lonely_tasks: 'wait in queue; Master may unilaterally complete with self-flag for later re-verification'

onboarding.phases:
  - { id: 0,   members: 'Rob only',                 pairing: 'n/a (bootstrap Master in every skill)' }
  - { id: 0.5, members: 'Rob + Greg (calibration)', pairing: 'opt-in pre-pair calibration vs synthetic key' }
  - { id: 1,   members: 'Rob + Greg (live)',        pairing: "Greg's tasks pair with Rob's submissions on the same tasks" }
```

`lonely_tasks` is the whole answer for the first fifty clips. The bootstrap Master completes alone
and **self-flags for later re-verification**. The gap is that a self-flag which is not stored is
not a self-flag — and today there is nowhere to store it.

### 3.3 Recommendation, in build order

1. **Build the ledger before the pairing.** A completion by a single actor is permitted and is
   stamped `unilateral` with a reason, persisted on the decision record. This is the pattern the
   operator already adopted for editorial in **P73** (*"the override must be explicit, persisted
   (`unilateral` stamp) and audited, and it re-tightens automatically the moment a second qualified
   member exists"*). Reusing it is one policy expressed once, not two policies that will drift.
2. **Build the one guard that can be proven red on day one.** Refuse `apply` when
   `suggestion.author == actor` **unless** the `unilateral` stamp carries a reason. With 2 accounts
   and 1 worker this fires on *every single apply immediately* — the exact opposite of the
   ops#214 class of guard nobody has ever seen fire. And it produces, from clip #1, the trail the
   later dual attestation needs in order to re-verify.
3. **Close self-endorsement.** `nwc_guild`'s `EndorsementService.php:79` already contains the exact
   check (`'You cannot endorse yourself.'`). Copying a proven check into the module that lacks it
   is cheap and provable.
4. **Arm the second attester by a declared fact, not a flag.** The requirement for a second
   attestation arms when a second account holds Clip Selection eligibility. Same shape as the
   `approvers:` switch in `CLAUDE.md`: *inert today, correct forever, arms without anyone
   remembering to arm it.* There must be no "turn on dual review" setting, because a setting is a
   second place for the policy to live.
5. **Make blindness a property of the view, not a promise.** `pairing.blind: true` is in the spec;
   the apply form does the opposite. Hide author name and endorsement count until both submissions
   are in. Testable: the rendered form must not contain the author's account name before close.
6. **Wire `recordMatchedPair()`.** Stage A exact-match and Stage B IoU ≥ 0.7 are the two events
   that should call it. Until they do, the Practitioner ladder is decorative for clip work, and a
   volunteer's effort buys them nothing.

**Throughput cost of all this: zero for the first fifty clips.** Nothing waits for a second human.
What changes is that each of those fifty leaves a row saying who decided it alone and why — which
is what makes them re-verifiable when the second human arrives, rather than silently grandfathered.

**What the alternative loses.** Building blind pairing first is the "correct" order on paper and
would stop the programme dead: with one active worker, every task enters `pairing.pool` and waits
forever. The spec anticipated this and wrote `lonely_tasks`; ignoring it in favour of the stricter
path is how a guild acquires a process nobody can start.

---

## 4. The tags question

### 4.1 The measured situation

```
learning points carrying `tags:`      0 of 251
courses carrying `tags:`             56 of 56
distinct tag values                 122   (198 applications; median 3 per course)
namespaces in use                   topic 138 · saints 41 · false-teaching 7 · risk 6 · state 5 · season 1
```

`catalog/schema.yaml` declares `allowed_tag_namespaces` (saints, false-teaching, state, season,
risk, topic) and documents `tags:` at **course** level only. LP-level `tier:` override is
documented; LP-level `tags:` is not. So this is a schema addition, not a fill-in-the-blank.

And the pipeline that needs them reads less than it could. `scripts/lp_taxonomy.py` derives each
LP's `{keywords, phrases}` from **the LP title, the course tags, and the course title** — its own
docstring says so. The LP's own body text is never read, though it is present and substantial:

```
short.summary   present on 251 of 251 LPs, median  25 words
standard.text   present on 250 of 251 LPs, median  70 words, mean 133
lp.title                                  median   4 words
```

That is the whole cause of the residual defect the granularity report reports honestly: **193 of
251 LPs still share their top candidate with a sibling**, and courses whose LP titles are
metaphors (`A4` — *The Jungle Hike*, *Your Yes — The Centre*) collapse to **one** distinct top
across all their LPs.

### 4.2 The discriminating text already exists — measured

Naive verbatim match of the existing 122-term course vocabulary (slug → spaces) against each LP's
`title + short.summary + standard.text`:

| | count |
|---|---|
| LPs matching ≥1 vocabulary term | **243** of 251 |
| LPs matching ≥1 term their **own course does not already carry** | **222** of 251 |
| LPs matching **no** term at all | 8 |
| courses in which **every** LP gets a *distinct* extra-term set | **42** of 56 |
| courses in which all LPs share one extra-term set | **0** |

`A4`, `B7`, `D7` and `J7` — the four courses the granularity report singles out as collapsing to a
single top candidate — each yield **a distinct extra-term set for every one of their LPs**.

> **Read this as an upper bound, not a prediction.** It is a substring match against an existing
> vocabulary, not `lp_taxonomy.py`'s tokeniser, and it says nothing about whether the terms are
> the *right* ones. What it establishes is narrow and load-bearing: **the text that separates
> sibling LPs is already sitting in the catalogue, unread.**

### 4.3 Two fixes, and the order matters

**Fix A — read the bodies. Free, buildable, no editorial hours.**
Extend `lp_taxonomy.py` to derive terms from `short.summary` and `standard.text` as well as the
title, keeping the same `GENERIC_TERMS` denylist (which exists precisely to stop `prayer` / `god` /
`soul` re-creating the pooling) and the same per-term `derivation` provenance already stored in
`_runs_v3.json::topics[lp].derivation`. **Then re-measure the 193-of-251 figure.**

- *What it loses:* derived terms are a function of prose, so a text rewrite silently changes the
  candidate pool. They are not curatable — you cannot build a "show me every LP about the examen"
  filter or pathway from them. And where titles are metaphors, the bodies may be too.

**Fix B — add `tags:` to the learning points. Editorial, durable.**

- **Vocabulary.** The six declared namespaces, seeded with the existing 122 values, plus three
  namespaces that resolve to registries the estate already keeps, so a tag names a *record* rather
  than a slug:
  - `work:<id>` → `catalog/works.yaml` (3 entries today; `validate_v32.py` already errors on a
    dangling `book_ref`, so the pattern is established)
  - `discipline:<uid>` → `catalog/disciplines.yaml` (8 canonical Rules; **17 LPs are already named
    as gateways in its `note:` fields** — free seed data)
  - `paradigm:<element>` → the four declared `allowed_paradigm_elements`
- **Who does it.** Media Guild **skill #3, Topic Tagging** — it already exists, its `task_unit` is
  *"One segment/session tag-set application"* and its `match_rule` is `jaccard:0.8`. An LP tag-set
  is exactly that unit under exactly that tolerance. No new machinery, no new skill, no new
  governance.
- **Bootstrapped, not authored cold.** A proposal pass emits, per LP, a ranked candidate tag-set
  drawn **only** from the declared vocabulary, each term accompanied by the sentence that
  justified it. The human confirms, edits or rejects. Feasibility measured above: 243 of 251 LPs
  get at least one candidate; the 8 that get none go to cold authoring.
- **Validation.** `validate_v32.py` already resolves `book_ref`/`recommended_reading` against
  `works.yaml` and errors on a dangling reference; extending the same treatment to `tags:` (every
  namespace in `allowed_tag_namespaces`; every `work:`/`discipline:`/`paradigm:` value resolving to
  a registry row) is the natural shape. Its red-then-green proof is trivial and must be taken: a
  fixture LP carrying `topic:not-a-real-thing` must fail before the validator is believed.

### 4.4 Volume and hours — the real numbers

| Quantity | Figure | Source |
|---|---|---|
| learning points to tag | **251** | counted across the 56 course files |
| words to read per LP | ≈ **100** (title 4 + short 25 + standard 70, medians) | counted |
| reading time per LP at 200 wpm | ≈ **30 s** | derived |
| confirm/edit a proposed 3–5 term set | **1.5–3.5 min** | judgement, stated as an estimate |
| **per LP, all in** | **2–4 min** | |
| **one complete pass, one person** | **8–17 h** | 251 × 2–4 min |
| the 8 cold-authored LPs | + ~2 h | |
| vocabulary additions + review | + ~1 h | |
| **realistic single-pass total** | **11–20 h** | ≈ 3 working days, or 25 LPs an evening × 10 evenings |
| under `sampling.pre_approval: 1.0` (every task dual-attested) | **22–40 person-hours** | 2× the above |
| under the §3 bootstrap (one actor, `unilateral` stamp) | **11–20 h**, one person | |

The expensive part is not reading. It is the judgement *"is this the term that separates this LP
from its siblings, or is it the course's term again?"* — which is exactly the skill the `jaccard:0.8`
tolerance is calibrated for, and exactly what a second attester later checks.

### 4.5 Recommendation

**Do Fix A, measure, then commission Fix B scoped to the residue.**

- What that order buys: the 251-LP editorial pass may shrink to the ~29 LPs with no distinct
  extra-term and the ~14 courses whose sets are not distinct — possibly a 2–3 hour job instead of a
  20-hour one, spent by the estate's scarcest resource.
- What it loses: nothing in quality, and roughly one build-cycle of delay. If the operator wants
  the durable, curatable key regardless of what Fix A yields — a defensible position, since tags
  serve filters, pathways and the discipline registry, not only clip scoring — then Fix B is
  commissioned on its own merits and Fix A becomes a cheap complement.
- **Not recommended: doing neither.** The granularity report's own verdict is that 193 of 251 LPs
  share a top candidate with a sibling. Skipping both fixes means the guild does that
  discrimination by hand, 193 times, forever, instead of once.

---

## 5. Rescue vs re-pick — and how to tell the two apart

**Recommendation: neither wholesale. Three dispositions, assigned by evidence about the *act of
choosing*, not by the score.**

### 5.1 Band 0 — treat as an open slot (64 clips)

Not because the rubric scores them badly. Because **the window is prima facie not a choice**:

- the identical window `0:00–8:00` recurs **64 times** across 49 courses;
- the rubric's `intro_position` penalty (−1.5, "1.0 if clip starts in first 45 s") fires on all 64
  **by construction**, so their scores carry no independent information;
- **23** of them overlap no candidate at all; only **7 of 64** would appear in a reviewer's top-8;
- their median rank is **36**, at the 83rd percentile of their own candidate lists.

A human choosing for pedagogical fit does not choose the first eight minutes sixty-four times.
This is the one class where automation is safe — **and even here what is automated is emptying the
slot and queueing it, never writing a new clip.**

### 5.2 Bands 3 and near-ties — confirm (18 + 6)

Already rank ≤ 8 in their own list (18), of which 3 are #1; plus 6 with a gap under 1.0. One
reviewer, seconds each, "keep" or "promote to top". Cheapest evidence in the programme, and it
seeds the ledger of §3 with low-risk decisions.

### 5.3 Everything else — rescue with evidence, one at a time (Bands 1, 2, 4)

Present the reviewer with **the reason the rubric disagrees**, never the bare disagreement. The
material exists and is simply not rendered: all 8,626 candidates carry the **16 inspectable
`q_parts` sub-scores** and a `preview_text`, both **stored and never displayed** (ops#336 P1).

**The discriminator is *which* sub-scores are low.**

| Low sub-scores | What it means | Verdict |
|---|---|---|
| `opener_clean`, `ender_clean`, `dangling_opener`, `ad_hits`, `serial_marker`, `intro_position` | **Packaging** — the excerpt is not self-contained | The rubric is right, and a human reading the LP cannot see it without listening. **Re-trim; keep the episode.** A pedagogically perfect passage that starts mid-sentence is still a bad clip. |
| `density`, `breadth`, `title_match`, `off_topic_tail` | **Topical fit** — the clip does not use the LP's terms | The rubric may be **blind**. Its terms come from the LP *title* only (§4), so a clip that teaches *"Your Yes — The Centre"* without ever saying "centre" scores near zero on breadth and is not thereby wrong. **Human judgement wins; record the reason.** |
| `has_definition` = `has_authority` = `has_example` = 0 | Names the topic, teaches nothing | `CRITERIA.md` already lists this under *Reviewer escalation*. **Escalate; never auto-act.** |
| `bucket_center`, duration flags | Length | Product preference, not correctness. **Ignore** unless below the 90 s minimum run, which is Band 1. |

**The operating rule, in one line:** *a clip that loses on packaging is re-trimmed; a clip that
loses only on topical fit is presumed rubric-blind and kept unless a human says otherwise.*

**And the disagreement is not discarded — it is routed.** Every "kept despite low topical fit" is a
datum saying *this LP's terms do not describe what actually teaches it*. That is precisely a §4
Fix B tag candidate. The argument becomes the editorial input instead of being won and forgotten.

Likewise, when the same sub-score is overruled repeatedly, that is a rubric-weight question, and
the route already exists in two places: `CRITERIA.md`'s closing paragraph (*"If the rubric misranks
enough clips once reviewers start using it, the signals and weights get revised here — no model to
retrain"*) and `media-guild.yml`'s `annual_review.inputs` (mismatch rate per skill, tie-break
frequency, Spotter-tier earnings). **Record the overrule with its sub-score; the review mechanism
is already specified.**

### 5.4 Explicitly rejected: automated re-rank + human confirm across all 172

- **What it buys:** speed. 172 confirmations at ~2 minutes is ~6 hours; an automated re-pick is
  minutes.
- **What it costs, and why the trade is bad:** it replaces 172 clips nobody chose with 172 clips
  nobody chose. The defect is *absence of a human decision*, and a score does not supply one. It
  would also destroy the only evidence the estate can get about **where the rubric is blind** — the
  disagreements are the dataset for §4 and for the rubric's own revision route. And it inverts the
  reason the estate rejected ML: a reviewer must be able to ask *"why this one?"* and get an answer,
  which is impossible when the answer is "the batch job said so and you clicked yes 172 times".

---

## 6. Depth tiers — should the other four exist at all?

### 6.1 The facts

```
1,177 slots = short 251 + standard 250 + longer 242 + detailed 217 + advanced 217
176 video: blocks, ALL on `standard`
176 review slots on nwd live, ALL depth=standard
```

`catalog/schema.yaml` describes depth as a **length/complexity axis of the text** — `short` =
"Level 1: Quick review (35-60 words)", `standard` = "Level 2: Default learner (300-500 words)" —
and places the `video:` example under `standard`. Nothing in `CRITERIA.md` is depth-aware; its
duration buckets already encode "a clip has a right length".

### 6.2 The options

| | Option | New slots | Verdict |
|---|---|---|---|
| i | `standard` only | 74 | The status quo made explicit. |
| ii | `standard` + `short` (a 60–120 s hook) | 74 + 251 | Doubles the queue for an unevidenced need. |
| iii | all five tiers | 74 + 927 | Not a backlog; a wish. |
| **iv** | **one clip per learning point, rendered at every depth** | **74** | **Recommended.** |

### 6.3 Recommendation: (iv) — the clip is a property of the learning point

Keep exactly one clip per LP, authored once, rendered by every depth that displays the LP. In slot
terms this looks like "standard only", but the *key* changes from `(course, lp, depth)` to
`(course, lp)`, and `depth` becomes a rendering choice rather than an axis of work.

Consequences, all favourable:

- the outstanding work drops from **1,177 slots to 251 learning points**, of which **176 have a
  clip** — and the terrifying "1,001 empty" becomes "75 to author, 172 to review";
- the estate stops inventing a second meaning for `depth`, which the schema defines as a property
  of the *text*;
- `LpReviewSlot.depth` today is a free-text `string(16)` with no allowed-values validation, whose
  own description lists six values including `scholar` — a fifth-and-a-half tier nobody has
  attempted. Collapsing the key removes an unvalidated dimension rather than validating it.

**The one real pull the other way, stated fairly:** 24 of the current clips are already shorter
than the rubric's 90 s minimum run and 61 are below the 2-minute bucket — a third of the picks are
*already* short-form. That is evidence the current picks are broken (§1.1), not evidence that a
`short` tier is wanted. If a genuine short-form need appears later, the additive path is **one**
extra tier, not four, and the module already supports producing a second range from the same
episode as a re-trim.

**What (iv) loses:** an advanced learner sees the same excerpt as a beginner. Mitigation costs
nothing today and can wait for a real request.

---

## 7. `B2.04` — one case, and the class it represents

`B2.04` *Sacred Attention* (ep 600) is unrankable: its catalogue `video:` window matches no
transcript segment, so `current-clip-vs-rubric.md` reports it as **`CANNOT VERIFY`**, excludes it
from the 175, and says so in words. **That handling was correct** — it is the estate's fail-closed
rule working exactly as intended.

**The class is: the citation and the corpus disagree, and nothing standing notices.** Its other
members, all measurable:

- a window that falls outside the episode's transcript span (`B2.04`);
- an episode number with no transcript at all;
- a media address that no longer resolves — measured elsewhere: **8,094 of 8,626** v3 candidates
  carry no `youtube_id`, and audio is the only medium with complete coverage (648/648 episodes);
- an `audio_url` that 404s;
- a window that survives a re-transcription with different boundaries — dir1 segments average
  **3.41 s / 54.6 chars** (`nwp/dir1-project!1`), so boundaries genuinely move.

**Why such a case vanishes today.** The report is a one-off artefact. Nothing *standing* re-asks
the question, and the review UI has no state to hold the answer: all 176 slots are `pending`, and
of the entity's four statuses (`pending`, `suggestions_open`, `applied`, `locked`) the fourth has
**no route and no caller**. The entity already carries a dead status and lacks a live one.

**Recommendation.**

1. **A citation-resolution check over the whole catalogue that exits 2 CANNOT VERIFY** — per the
   estate rule — listing every `video:` block that does not resolve to a transcript span and every
   media address that does not resolve. It exits 0 only when every citation resolves.
   **Today it must fail on exactly one case, `B2.04`.** That makes it the cheapest provable gate in
   this entire document: the red already exists and is already named, so it can be observed red
   before it is trusted green. This is buildable now and is the single highest
   confidence-per-hour item here.
2. **A visible disposition**, so an unresolvable citation becomes a queue item with a reason rather
   than an absence. (Touches the entity; belongs to whoever owns the module lane.)
3. **Ownership.** An unresolvable citation is a media-provenance fact, so it belongs to Media Guild
   skill #8, `provenance-verification` (`verdict_and_hash_exact`) — again, existing machinery.

---

## 8. What needs a ruling, what the guild decides, what is merely buildable

### 8.1 Operator rulings surfaced

| # | Ruling | Recommendation | If unruled |
|---|---|---|---|
| **R1** | Is a clip a property of the **learning point**, or of **(learning point, depth)**? | Learning point (§6, option iv) | The backlog stays 1,177 and four tiers stay nominally owed |
| **R2** | May a `0:00–8:00` window be treated as **not a choice**, and its slot re-opened without a per-clip human argument? | Yes — 64 clips; the automated act is *emptying*, never writing (§5.1) | The single largest, cleanest triage class stays blocked behind 64 individual arguments |
| **R3** | Bootstrap attestation: adopt the guild spec's own `lonely_tasks` rule — single-actor completion with a **persisted `unilateral` stamp + reason**, the second attester arming automatically when a second account holds Clip Selection eligibility? | Yes; same declared-fact shape as `approvers:` and P73 | Either the process stalls waiting for a second human, or the first fifty decisions are made with no trail |
| **R4** | LP-level `tags:` — **additive** to course tags? Which namespaces are admissible (the 6 declared + `work:` / `discipline:` / `paradigm:`)? Is the vocabulary closed, with additions going through the guild? | Additive; the 6 + 3 registry-backed namespaces; closed-with-guild-additions | The editorial pass cannot start, because "what is a legal tag" is undefined |
| **R5** | Is the tags pass commissioned **before** or **after** the free body-text derivation is measured? | After (§4.5) | Up to 20 h of the estate's scarcest resource may be spent on LPs a free fix separates anyway |
| **R6** | **Where does the DIR pipeline live and get reviewed?** `~/dir` has one remote — a bare mirror on met — and the forge has **no `nwp/dir` project** (ops#336, enumerated with the group bot: 28 projects, none of them it). Every clip-selection script lives there with **no MR location, no CI and no review gate.** | Create `nwp/dir`, or relocate `scripts/` into `nwp/courses` | Every recommendation in this document lands in a repo nothing can review |
| **R7** | Is there to be a **`pl` verb for clip work** (proposed name: a `clip` verb)? Measured: `scripts/commands/` contains no clip / course / corpus verb and `pl`'s help mentions none, yet the standing order is that every operation on the estate is performed by a `pl` command. | Yes — the queue, the triage, the tag proposal and the citation check are all currently bare Python | The estate acquires four more operations only one session knows how to repeat |
| **R8** | Should applying a clip earn **guild credit**? Today `recordAppliedClip()` grants recognition only and `recordMatchedPair()` has no caller, so clip work advances nothing on the ladder. | Wire Stage A / Stage B matching to `recordMatchedPair()` (§3.3.6) | The Practitioner ladder stays decorative for the guild's headline activity |

### 8.2 The guild decides (not the operator)

- Rubric weight revisions arising from repeated overrules — the route is `CRITERIA.md`'s own
  closing paragraph plus `media-guild.yml::annual_review`, owned by the Pipeline Operations
  Master, falling back to guild-admin.
- The `time_range_iou` tolerance itself (`0.7` today) and the Stage A exact-match rule — same
  annual review, `output: 'single PolicyDecision proposing tolerance changes per skill'`.
- Whether an episode audition batch is one task or several for credit purposes (§2.3).
- Additions to the tag vocabulary (skill-catalogue governance already reads:
  *Master-proposed PolicyDecision + guild-admin approval; additive*).

### 8.3 Buildable with no ruling at all

1. **The citation-resolution check** (§7) — has an existing red (`B2.04`).
2. **Anti-self-apply guard + persisted `unilateral` stamp** (§3.3.2) — fires on every apply today.
3. **Self-endorsement guard** (§3.3.3) — the check already exists in `nwc_guild`.
4. **Render `q_parts` and `preview_text`** (§5.3) — already stored on all candidates.
5. **Body-text term derivation in `lp_taxonomy.py`** (§4.3 Fix A) — no editorial hours.
6. **Queue ordering + "next task" + band summary** (§1.3) — every input already exists.
7. **Blind the apply form** until submissions close (§3.3.5).

None of the seven is implemented by this proposal. Each is named with the measurement that would
prove it red first.

---

## 9. Sequencing (for the operator to accept, amend or reject)

| Phase | Work | Blocked on | Cost |
|---|---|---|---|
| **0** | Citation-resolution check; anti-self-apply guard + `unilateral` stamp; self-endorsement guard | nothing | small, and all three have observable reds |
| **1** | Render `q_parts` + `preview_text`; queue ordering, band summary, "next task", episode batch | R6/R7 for where it lives | the difference between a workable and an unworkable queue |
| **2** | Band 0 sweep — 64 defaulted windows re-opened and re-picked, ordered by beginner-pathway prominence, batched by episode | **R2** | the largest single quality gain available |
| **3** | Fix A (body-text derivation) + re-measure the 193/251 shared-top figure | nothing | hours, not days |
| **4** | Bands 3 → 2 → 4 rescue-with-evidence, recording every overrule against its sub-score | phase 1 | ~6 h for the confirmations; open-ended for the contested |
| **5** | Fix B (LP `tags:`), scoped by phase 3's measurement | **R4, R5** | 11–20 h single-pass; 2–3 h if scoped to the residue |
| **6** | Band 5 — the 75 learning points with no clip | phases 1–2 | new authoring, the largest remaining tranche |
| **7** | Wire `recordMatchedPair()`; arm the second attester | **R3, R8**, and a second account | — |

Depth tiers (Bands 6 / 927 slots) appear nowhere in this plan. That is the recommendation of §6,
and **R1** is the ruling that makes it explicit rather than merely deferred.

---

## 10. What this proposal deliberately does not do

- It ships **no code, no schema change, no golden, no live write**. Every measurement above was
  taken read-only, through `pl` verbs where a verb existed.
- It does **not** rewrite any of the 176 catalogue `video:` blocks.
- It does **not** re-rank or re-pick anything automatically — §5.4 argues against exactly that.
- It does **not** touch the sync pipeline, the review-UI lane, or repo/CI hygiene, all of which
  had other agents in flight on 2026-08-11.
