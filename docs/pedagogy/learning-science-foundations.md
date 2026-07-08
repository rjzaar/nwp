# Learning-science foundations of the course-content model — a Pedagogy Guild briefing

**Owner:** Pedagogy Guild (`nwc_pedagogy_guild`). **Status:** for discussion — not settled.
**Purpose:** explain *why* the course system is built the way it is, in learning-science terms, and
put the reasoning **up for the Guild to challenge and improve**. This is part of the Guild's brief:
the editorial pipeline routes pedagogical revisions through `in_pedagogy_review`, and the Guild owns
the standards those reviews apply. This document is those standards' evidence base.
**Drives:** the render contract and moderation rubric in
[`P70`](../proposals/P70-audience-variants-and-learnersourced-stories.md) (schema v3.1 atom typing +
`story_contribution`), which sits under [ops#61](https://git.nwpcode.org/nwp/ops/-/issues/61)
(canonical content model). Principle numbers here are cited by P70 §4–§5.
**Evidence base:** two research syntheses, 2026-07-08 (learning science + Moodle 4.5 capability).
Source URLs inline. Each claim carries an **evidence-strength flag** — the Guild should weight its
standards accordingly and *not* treat weak/directional findings as settled.

---

## 0. The design in one sentence

**Hold the concept's deep structure invariant; vary the surface framing to force abstraction and
match the audience; sequence difficulty on a separate axis; require every relatable element to
carry the core rather than decorate it; and gate learner-contributed content through peer voting as
triage plus a light, signal-targeted human review.**

Everything below is why each clause of that sentence is there.

---

## 1. Why "fixed core + swappable framing" is the right shape

**Variation Theory** (Marton; Lo & Pang). A feature becomes *discernible* only when experienced as
**varying against an invariant background**. Four patterns: *Contrast* (non-examples), *Separation*
(vary one dimension, hold the rest), *Fusion* (vary several critical aspects together),
*Generalization* (hold the critical feature invariant, vary surface). "Fixed core + swap examples"
is the **Generalization** pattern.

> **Correction to the naïve version — important for reviewers.** A core that is *only ever* held
> static can be memorised as a set of instances *without* the learner ever discerning the essence.
> The critical aspect must **first be varied** (Contrast/Separation) to be taught, *then* held
> invariant while surface swaps to generalise it. This is why the schema has a **`contrast`** atom
> type, not just `core` + `variants` — see P70 §3.

*Design implication:* vary what you want noticed, hold invariant what you want backgrounded, and
flip which is which as each aspect moves from not-yet-grasped to grasped.
**Evidence: MODERATE** as causal science (large practitioner base, few controlled trials until a
2025 field experiment); MODERATE→STRONG as a design heuristic.
kb.edu.hku.hk/approaches_variation_theory · nature.com/articles/s41599-019-0284-z ·
link.springer.com/article/10.1007/s11251-025-09721-y

## 2. Why examples must vary — and why depth gates how much

**Example-variability effect** (Paas & van Merriënboer 1994; Cognitive Load Theory, Sweller).
High-variability worked examples give the best **far transfer** — *but only when overall load is
low*. **Expertise-reversal effect** (Kalyuga et al.): support that helps novices *hurts* experts.
Direct test (Likourezos, Kalyuga & Sweller 2019): a genuine crossover — low-prior-knowledge
learners did better with *low* variability, high-prior-knowledge learners with *high* variability.

*Design implication:* introduce a concept with **one** low-variability, high-guidance example; raise
variability as expertise rises. **Treat "depth" as also "expertise"** — this is why the render
contract shows *one* example at Basic and the full contrasting set at Advanced (P70 §4.3), and why
depth and audience are **separate axes**.
**Evidence: STRONG** (RCTs, repeated replication). Flag: "germane load" was later redefined toward
element-interactivity — the effect stands, the theoretical gloss shifted.
link.springer.com/article/10.1007/BF02213420 ·
link.springer.com/article/10.1007/s10648-019-09462-8

## 3. Why metaphors come in pairs, with their limits stated

**Analogical transfer** (Gick & Holyoak 1983; Gentner structure-mapping). A *single* analogy
transfers poorly (~30% spontaneous). **Two** source analogs + prompted comparison roughly doubles
transfer (21%→45%) by inducing an abstract schema; transfer rides on shared **relational/deep
structure**, not surface. A lone sticky metaphor **entrenches misconceptions** via over-mapping
(Spiro et al.); every analogy breaks down, so its break-down points must be **named** (Glynn TWA;
Treagust FAR; Clement bridging analogies).

*Design implication:* multiple, deliberately diverse metaphors per concept; make the comparison
explicit; state where each fails; pick pairs whose failure modes don't overlap so they self-correct.
This is why `metaphor` atoms **must** carry `breaks_down_at` (P70 §3 validator rule).
**Evidence: STRONG** for the two-analog comparison effect.
reasoninglab.psych.ucla.edu (Gick & Holyoak 1983) · groups.psych.northwestern.edu/gentner (2003)

## 4. Why "relatable" is not enough — the load-bearing test

**Personalization principle** (Mayer; Moreno & Mayer 2000): conversational, second-person framing
improves transfer (large effect, g≈0.70 in a 2025 re-analysis) via *social agency*. **But**
interesting-but-irrelevant material — **seductive details** (Harp & Mayer 1998; meta-analyses Rey
2012; Sundararajan & Adesope 2020, g≈−0.33) — reliably *depresses* learning, worst when
front-loaded, and **cannot** be neutralised by highlighting or signalling. The only fix is removal.

> **The reviewer's test.** Personalization *re-voices the core*; a seductive detail *adds a unit of
> content*. The question is never "is it interesting?" but **"remove this — is a required core idea
> lost? If no, cut it."** Guard the **opening** hardest: a relatable-but-off-core hook primes the
> wrong schema and is maximally damaging. This *is* the moderation rubric for both authored variants
> and contributed stories (P70 §5 step 4).

*Boundary conditions:* personalization helps novices and abstract content most, weakens for experts,
and is culture/language-dependent (a Czech replication found no effect) — dose it, don't over-do it.
**Evidence: STRONG** for the seductive-details caution; MODERATE→STRONG for personalization with
boundary conditions.
sciencedirect.com/science/article/pii/S1747938X25000673 · eric.ed.gov/?id=EJ576496 ·
link.springer.com/article/10.1007/s10648-020-09522-4

## 5. Why relevance should be self-generated (and audience-matched)

Strongest *causal* motivation evidence: **utility-value interventions** (Hulleman & Harackiewicz
2009, *Science*) — learners who write **their own** connection between material and their lives
raise grades and interest; the effect concentrates in low-expectation students (Harackiewicz 2016
closed ~61% of an achievement gap, d=0.55). **Self-Determination Theory** (Deci & Ryan) gives the
mechanism (autonomy/competence/relatedness → persistence); **interest theory** (Hidi & Renninger)
shows a relevant hook can mature situational interest into durable interest. **Funds of Knowledge /
Culturally Responsive Pedagogy** (Moll & González; Gay; Ladson-Billings) — anchor examples in each
audience's *actual lived world* (a parent's household, a priest's pastoral life, a young person's
peer/digital world), asset-based, not stereotyped.

*Design implication:* the `application` slot should, at Intermediate+, **prompt the learner to
author their own** application (P70 §4.4), and audience examples should come from that group's real
context. Generic relevance ("useful for the exam") does not work.
**Evidence: STRONG** (utility-value RCTs; SDT). CRT: strong *directionally*, weak on large causal
RCTs (an epistemological-tradition mismatch, not a refutation).
science.org/doi/10.1126/science.1177067 · pmc.ncbi.nlm.nih.gov/articles/PMC5589190

## 6. Why depth is a separate axis

**Bruner's spiral curriculum** most directly licenses the model — the same core taught "in some
intellectually honest form" at every level, revisited at increasing depth. **Vygotsky ZPD +
scaffolding** (Wood, Bruner & Ross 1976) gives the mechanism for stepping the ladder: target just
beyond current ability, fade support. **Bloom's revised taxonomy** (Anderson & Krathwohl 2001) is
itself a precedent for *two orthogonal axes* (cognitive process × knowledge type) — exactly the
"separate depth from framing" move.

*Design implication:* keep depth (difficulty) and framing (relevance) genuinely orthogonal in the
data model; calibrate the *steps* by ZPD; **don't enforce depth as a strict prerequisite chain** —
allow overlap and skipping (the strict Bloom hierarchy is contested).
**Evidence:** ZPD/scaffolding STRONG; spiral MODERATE. **Flag: Krashen's i+1 is CONTESTED**
(vague/untestable, from second-language acquisition) — use as intuition only, not load-bearing.
simplypsychology.org/bruner.html · link.springer.com/article/10.1007/s10648-010-9127-6

## 7. Why learner stories are gated the way they are

**Generation effect** (Slamecka & Graf 1978; meta-analytic d≈0.40) + **generative learning**
(Wittrock; Fiorella & Mayer): *authoring* content deepens the **author's** learning — so
contribution is a *learning act*, valuable even when the story is not published. **Learnersourcing
with peer evaluation** (PeerWise — Denny; RiPPLE — Khosravi): peer votes **rank and surface**
candidates but **do not certify** — individual raters are noisy, only ~25–35% of learner-generated
items are high quality, and crowds approach expert quality *only in aggregate with enough raters*.
The proven safeguard is **signal-targeted moderation** (RiPPLE/Darvishi 2022): auto-flag suspect
items (high downvotes, low discrimination) for human spot-check rather than reviewing everything.
Expect the **90-9-1 curve** (~1% produce most content) → incentivise the *authoring act*.

*Design implication:* voting = triage; a light, signal-targeted Pedagogy-Guild gate = certification;
frame "add your story" as a spiritual/learning practice. Because stories have **no
machine-checkable key**, the human gate matters *more* than for quiz items. This is exactly the P70
§5 flow (submit → vote → auto-flag → `in_pedagogy_review` → approve → write back).
**Evidence:** generation effect STRONG; PeerWise learning gains MODERATE/correlational;
peer-moderation quality MIXED (reliable only with aggregation + safeguards).
link.springer.com/article/10.1007/s10648-015-9348-9 · dl.acm.org/doi/10.1145/1404520.1404526 ·
learning-analytics.info/index.php/JLA/article/view/6373

## 8. Equity is the retention case, not a footnote

Audience-matched relevance is a **targeted retention lever**: its measured benefits concentrate in
**low-confidence, first-generation, and disengaging learners** (the utility-value RCTs). That maps
onto a faith-formation audience with real dropout risk — the versioning work is not polish, it is
where the retention gain lives.
**Evidence: STRONG** (same RCT base as §5).

---

## The seven standards (what `in_pedagogy_review` should enforce)

1. **Deep structure visible; surface varied.** Protect relational structure, not wording. *(Strong)*
2. **Vary a critical aspect to teach it; hold it invariant to generalise it.** Require `contrast`,
   not just a static core. *(Moderate)*
3. **Match example concreteness/variability to depth; fade guidance as depth rises.** One example at
   Basic, the contrasting set at Advanced. *(Strong)*
4. **Multiple diverse metaphors, compared, with limits stated — never one sticky metaphor.**
   *(Strong)*
5. **Every framing element must be load-bearing** — "remove it: is a required idea lost?" Guard the
   opening hardest. *(Strong)*
6. **Relevance self-generated and drawn from the audience's real world.** *(Strong causal for
   utility-value; directional for CRT)*
7. **Learnersourced stories: peer-vote triage + signal-targeted light human gate; contribution is
   itself a learning act.** *(Generation effect strong; peer-moderation mixed → safeguards
   required)*

---

## Questions the Pedagogy Guild is asked to resolve

These are genuinely open — the system should be shaped by the Guild's answer, not the other way
round:

1. **Audience vocabulary.** Is `youth | parent | priest | general` the right starting axis? What is
   missing (`single`, `religious`, `convert`, `RCIA`)? Is *audience* even the right cut, versus
   *state of prayer* or *disposition*?
2. **Depth calibration.** How many depth levels, and what defines the ZPD step between them for
   *this* subject matter (interior prayer), where "difficulty" is not purely cognitive?
3. **The load-bearing test in a faith context.** §4 says cut anything not load-bearing for the core
   *learning* objective. But a story may be load-bearing for *formation/consolation* while not for
   the cognitive core. Does the Guild want a **second axis of value** (formative, not just
   instructional) that the seductive-details rule must not override?
4. **Voting threshold.** What up/down ratio + minimum rater count should promote a story out of
   triage? (Start conservative; tune with data.)
5. **Where CRT evidence is weak.** §5/§7 flag culturally-responsive and in-system learnersourcing
   gains as directionally-but-not-causally established. Is the Guild comfortable building standards
   on directional evidence, with a plan to measure locally?

## Scoring & motivation — operator has set the frame; the Guild refines it

Operator decision (2026-07-08): **guild scores are part of the site — "all education uses grades;
this is the site's version of that"** — but a user may **opt out of *seeing* scores**. The scoring
design must follow the reputation research (see [P71]): points accrue on **peer/higher-tier
corroboration**, not raw activity or the bare act of approving; the score is framed as **mastery
feedback + recognition**, not a competitive public leaderboard (SDT: controlling/competitive rewards
crowd *out* intrinsic/spiritual motivation; informational recognition crowds it *in*). The Guild is
asked to resolve the specifics:

6. **Recognition vs comparison surfacing.** Given scores stay but are opt-out-visible, how should
   they be *shown* (private mastery view? guild-internal? never a global ranked leaderboard?) to keep
   the "grade" framing without triggering social-comparison harm?
7. **Corroboration rule.** What counts as the "downstream corroboration" that releases points to a
   reviewer (content survives N days? a higher tier concurs? the doctrine holds through theology)?
8. **Anti-gaming.** Thresholds for flagging reciprocal propose↔approve pairs / clique farming; blind
   vs open reviewer assignment within a guild.
9. **Grade legitimacy in a faith context.** Where is the line between a healthy "grade" (competence
   signal) and reframing *service/formation* as a transactional game — especially for Sojourners,
   whose levels are formation-by-course-completion, not performance?

## How this gets in front of the Guild

The Guild is a `group`-entity guild (bundle `guild`); like the others it has a discussion surface.
Recommended: seed a **`pedagogy-guild.yml`** in `nwc_guild/config/install/guilds/` (the module
`nwc_pedagogy_guild` exists but no guild is seeded yet — parity gap worth closing anyway), then post
this document as the Guild's founding discussion topic, with §"Questions" as the agenda. Revisions to
*this* document should themselves flow through the editorial pipeline as `CHANGE_PEDAGOGICAL` — the
Guild's standards, kept honest by the Guild's own process.
