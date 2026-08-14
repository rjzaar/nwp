# P79 — Calibration as guild work: the panel instrument for clip relevance

**Status:** PROPOSED — instrument, thresholds and tooling. No production code, no schema change,
no live write, no catalogue `video:` block touched.
**Owner:** *(unassigned)*
**Issue:** `nwp/ops#348`
**Supersedes nothing.** It generalises **P78 §4** and leaves P78's four gates verbatim.
**Siblings:** `P75` (guild triage + workflow) · `P76` (the engine) · `P77` (the harness) ·
`P78` (the silver labels and the calibration instrument this one hands to a panel).

**The ruling this implements, verbatim:**

> *"3 is really for the media guild to do. use max effort to work out how it can be setup in
> the media guild."*

---

## 0. The one-paragraph version

P78 built a 30-learning-point, 120-judgement calibration set and committed four gates *before*
anybody judged, so the test could fail. It was designed for **one** assessor. Moving it to the
Media Guild is not a relabelling: with one assessor every gate measures **operator-vs-machine**,
and with N members the instrument acquires a second axis — **human-vs-human** — which is the one
quantity no machine measurement in this estate could ever supply, because all sixteen judging
instances were the same model and *"a systematic error shared by all instances is invisible here
by construction"* (P78 §5.2.7). This proposal adds **Gate 0 (panel coherence)**, **Gate 1b (the
machine must not be an outlier on the panel)** and **Gate 3b (the raters must share one scale)**;
generalises Gate 4's kill switch to require **corroboration** so one volunteer's bad morning
cannot delete 3,309 labels; and establishes the direction that matters most — **a panel that did
not agree with itself has not measured the machine, and therefore may not condemn it.** All of
it degrades to N = 1 without changing the artefact format, and all of it has been observed red.

**Nothing here is named gold. Nothing here may be quoted as an accuracy figure.**

---

## 1. What actually changes, on three planes

| plane | with one assessor | with a panel |
|---|---|---|
| **statistics** | Cohen's κ, one pair of vectors, one bootstrap over items | Krippendorff's α across raters *and* per-rater κ against the machine; cluster bootstrap over learning points; three new gates; one gate that can now **fail without condemning the labels** |
| **workflow** | one document, one seed, one answers file | one packet **per rater**, own seed, anti-self-review applied at build time, abstentions become **routes** to Theology and formation |
| **software** | `render_calibration.py` → `CALIBRATION-SET.md` → `score_calibration.py` | `pl clips calibrate packet` / `score` / `status`, with the join, the rights boundary and the integrity checks inside the verb |

The single most important consequence is on the third row of the first column and it is easy to
miss: **`score_calibration.py` takes one file and would happily take the guild's first rater's
file and score it as if that rater were the operator.** It would return a number. The number
would be a κ against a machine, computed from one person's morning, with no way to tell an
idiosyncratic assessor from a faulty label set — which is precisely the ambiguity the ruling
removes and the existing tool cannot see.

---

## 2. The guild already declared this instrument, and never built it

This is not new policy. `nwc_guild/config/install/guilds/media-guild.yml` already contains:

```yaml
onboarding:
  phases:
    - { id: 0.5, members: 'Rob + Greg (calibration)',
        pairing: 'opt-in pre-pair calibration vs synthetic key (§10.1)' }

calibration:
  enabled: true
  opt_in: true
  description: 'New members may opt to complete calibration tasks against a synthetic answer key
                before entering live pairing.'
  counts_toward_practitioner: false
  bootstrap_note: 'For the first member (Greg), the synthetic key was built by Rob — calibration
                   is calibration against Rob.'
```

Three things follow, and they shape everything below.

**(a) The guild's calibration and P78's calibration are the same 120 judgements read two ways.**
The guild asks *"does this member judge like the Master?"* P78 asks *"does the machine judge like
a human?"* One is the rater-vs-rater axis and the other is the rater-vs-machine axis of a single
answers file. **Run one and you get the other for free.** That is why this proposal adds an axis
rather than a second exercise: asking a small guild to do two 90-minute sittings when one sitting
answers both questions is how a process acquires a reputation for busywork.

**(b) The `bootstrap_note` describes a circularity that a panel dissolves.** *"Calibration is
calibration against Rob"* — with one Master there is nothing else to calibrate against, so the
exercise can only measure conformity to one person. The moment a second human judges the same
items, the key stops being a person and becomes a *measurement*, and the machine becomes a third
opinion that can be scored against both. **The synthetic key P78 already produced is exactly the
artefact `§10.1` was waiting for.**

**(c) The blinding and anti-self-review this proposal enforces are already declared and already
unbuilt.** `pairing.anti_self_review: true # pair never includes the task author (ADR-0006)` and
`pairing.blind: true # neither member sees the other answer until both submit` are both in the
spec; P75 §3.1 measured them as *"Does not exist"* (grep returns nothing) and *"The opposite is
built in"* (`ApplyDecisionForm.php:44-51` prints the author's name and endorsement count to the
person deciding). P79 does not propose them. **It instantiates them, in the one place where they
can be made structural rather than promised.**

---

## 3. Multi-rater statistics: how the four gates generalise

### 3.1 Two axes, and the order they are evaluated in

| axis | question | statistic | new? |
|---|---|---|---|
| **H** | do the humans agree with each other? | Krippendorff's α over the human raters only | **yes — this is what N buys** |
| **M** | does the machine agree with the humans? | per-rater Cohen's κ against the machine | no — P78 §4.4 |

**Axis H is evaluated first and it gates axis M.** If the humans do not agree with each other, a
low machine agreement says nothing about the machine: the instrument did not resolve. This is
the direction that matters, because the permissive answer here is *deletion* — P78 §4.5's remedy
for a failed calibration is `rm -rf <label-set-directory>`, and a run that deleted 3,309 labels
because two volunteers read row 1 of the grade table differently would be the estate's named
failure shape pointed at its own ground truth.

### 3.2 Why Krippendorff's α and not Fleiss' κ or a majority label

- **α handles a variable number of raters per item and missing values**, which P77 §3.5 calls
  *"the realistic shape of guild judging"*. Fleiss requires a fixed rater count; Cohen requires
  exactly two and no gaps. Both would forbid the capacity ladder in §6 by construction.
- **α is gated on the INTERVAL metric**, not ordinal, for one reason: P78 §5.2.3 reported the
  machine panel at interval α **0.921 [0.887, 0.947]**. Gating the human panel on a different
  metric would put the two numbers on different rulers and make the comparison that motivates
  the whole exercise unquotable. Ordinal α is computed and reported alongside.
- **There is deliberately no majority/consensus label.** Voting manufactures a cleaner reference
  than exists — and at N = 2 there is no majority at all. Every statistic below is either
  per-rater or pairwise.
- **The panel statistic for Gates 1 and 2 is the MEAN OF PER-RATER κ, never a κ over pooled
  rater-machine pairs.** Pooling would count three ratings of one item as three independent
  observations and narrow the confidence interval on a dependence the design deliberately
  created. That is the *asserts less than it looks* shape (P78 §5.2.6 caught the same shape in
  its own pre-registered shortlist statistic and reported it four ways rather than absorbing it).
- **The bootstrap is a CLUSTER bootstrap over learning points**, not over items. Four candidates
  of one learning point are judged together, in one context, against one piece of prose; P78
  §5.2 already established the LP as the unit of dependence. *This is a change from
  `score_calibration.py`, which resampled items* — see §3.9.

### 3.3 Gate 0 — panel coherence *(NEW, committed here before any panel exists)*

Krippendorff's α, interval metric, **over the human raters only**. Including the machine would be
the circularity the exercise exists to break: a panel whose coherence is propped up by the thing
being tested cannot testify about it.

| α (95% cluster-bootstrap CI) | verdict | consequence |
|---|---|---|
| **≥ 0.667** | **COHERENT** | the panel is a usable reference standard; Gates 1–4 stand as written |
| 0.400 – 0.667 | **SCREENING-ONLY** | the panel agrees about *what is worth a human's time* but not about *how relevant*. **Gate 2 is capped at BINARY regardless of its own value.** |
| **< 0.400** | **INSTRUMENT FAILURE** | **exit 2. Nothing follows about the machine. The labels are NOT discarded and P78 §4.5 is NOT triggered.** |

**Why 0.667 and not Krippendorff's 0.800.** 0.667 is Krippendorff's own lowest value supporting
even *tentative* conclusions (P77 §3.5 / [D8]), and tentative is exactly the claim strength P78
permits — *"nothing here may be quoted as an accuracy figure"*. The bar is set at the claim being
made, not one band above it. The 0.800 *"firm conclusions"* bar is refused deliberately: P77 §3.5
records Voorhees' TREC assessors overlapping at **Jaccard ≈ 0.30** on the relevant set, and P76
§7.1 records *"two competent reviewers agree on ~67% of relevance decisions and three on ~45%"*.
**A gate set at 0.800 for human relevance judging is a gate that cannot pass, which is as useless
as one that cannot fail.**

**Why 0.400 is the floor.** Below it the coincidence matrix is closer to chance than to
structure, and a panel that is not a reference standard cannot testify about anything.

**What happens on failure — and it is not "try harder".** The report emits the **disagreement
composition** (`0↔1`, `1↔2`, `2↔3`, `>1 grade apart`), reusing P78 §5.2.5's decomposition, which
found **57.7%** of machine disagreement at the `1↔2` boundary. *Where* the panel disagrees names
*which row of the grade table* is ambiguous. The remedy is to rewrite that row, re-brief, and
re-run — a rubric fix, never a label deletion.

**Expect CANNOT VERIFY at N = 2, and expect it to be right.** One pairwise α over 120 items has a
wide CI, and the straddle rule turns a CI crossing 0.667 into CANNOT VERIFY rather than the
nearer band. **The cheapest way out of that is a third rater, not more items per rater** — which
is P77 §3.4's *"shallow-and-wide beats deep-and-narrow"* applied to people instead of topics.

### 3.4 Gate 1 — screening agreement *(P78 §4.4, unchanged thresholds)*

Cohen's κ on the binary collapse `grade ≥ 2` = *"worth a human's time"*, computed **per rater**
against the machine, reported per rater, and gated on the mean with a cluster-bootstrap CI.
**PASS ≥ 0.45 · PARTIAL ≥ 0.30 · DISCARD below.** Per-rater values are always printed: a panel
mean that hides one member at 0.15 and another at 0.75 is a number nobody should act on.

### 3.5 Gate 1b — the machine must not be an OUTLIER on the panel *(NEW; armed at N ≥ 3)*

**This is the question a single assessor cannot ask.** Build the panel `{r₁ … r_N, machine}` and
compute each member's mean pairwise κ against the others. The machine **DISCARDS** if its mean is
more than **0.15** below the *lowest human's*.

The same machine κ of 0.46 means opposite things depending on the humans: if they agree with each
other at 0.50 the machine is behaving like a panel member; if they agree at 0.85 it is an outlier
sitting outside a group that demonstrably can agree. **Only a panel can tell those apart.**

- **Why 0.15.** Set from the instrument's own resolution, not a convention: P78 §4.3 puts κ's SE
  at n = 120 at 0.05–0.09, i.e. a 95% CI of ±0.10–0.18. A gap narrower than that cannot be told
  from noise. 0.15 sits inside the upper half of that band.
- **Why armed at 3 and not 2.** With two humans, *"the lowest human"* is itself scored partly
  against the machine, so the comparison is not independent of what it is testing. At N ≤ 2 the
  gate reports **NOT ARMED** and is excluded from the overall verdict — inert today, correct
  forever, arming off a declared fact (how many answers files exist) rather than a flag. Per the
  standing order, an inert gate is worthless unless it has been seen to fire; §3.10 row G is that
  proof.

### 3.6 Gate 2 — graded agreement *(P78 §4.4, unchanged thresholds, one new cap)*

Quadratic-weighted κ per rater, mean, cluster-bootstrap CI. **GRADED ≥ 0.60 · BINARY ≥ 0.40 ·
DISCARD below.** New: **if Gate 0 returns SCREENING-ONLY, Gate 2 is capped at BINARY regardless
of its own value.** The machine may track the panel's grades closely while the panel does not
agree with itself about them; a graded metric built on that would inherit an agreement that does
not exist.

### 3.7 Gate 3 — directional bias, and Gate 3b — scale dispersion *(3b is NEW; armed at N ≥ 2)*

Gate 3 is unchanged: |panel mean signed difference| ≤ **0.5** grades.

**Gate 3b exists because Gate 3 can pass VACUOUSLY on a panel.** One rater a whole grade generous
and another a whole grade harsh average to a panel bias of zero while agreeing with nobody. That
cancellation is invisible to every statistic P78 committed, and **it is the single new failure
mode a panel introduces.** So: the **between-rater standard deviation of per-rater signed bias**
must also be ≤ **0.5** grades — same unit, same tolerance, because it is the same "half a grade".

The two gates have **different remedies**, which is why they are separate. Gate 3 failing is the
*machine* being skewed: fix the prompt or the scale. Gate 3b failing is the *raters* being
calibrated differently from each other: brief them again. A single combined gate would tell you
something is wrong and not which lever to pull.

**Honest limit:** Gate 3b is not statistically independent of Gate 0 — opposed scale usage
necessarily depresses α. Its value is **diagnostic**, and §3.10 rows C and D show it: two runs
with the same overall verdict and completely different causes, distinguished only by 3b.

### 3.8 Gate 4 — the control kill switch, now CORROBORATED

P78 §4.4: if the assessor disagrees by ≥ 2 grades on more than 2 of the 32 stratum-C control
judgements, **the entire set is DISCARDED regardless of Gates 1–3**. Correlated error where the
judge was certain is a fault, not noise.

Handing that to a panel unchanged would mean **any one volunteer having a bad morning deletes
3,309 labels.** The generalisation:

- A control item counts toward the kill switch only when **a majority of scoreable raters** is
  off by ≥ 2 grades on it (⌈N/2⌉; at N = 1 the majority is that one rater, so the gate is
  byte-for-byte P78's). The limit stays **> 2 items → DISCARD**.
- **A rogue rater is still visible.** Per-rater severe counts are reported, and any rater whose
  count exceeds the panel median by ≥ 5 is named `OUTLIER-RATER` — **reported, never dropped.**
  Dropping a file to make a gate pass is the swallowed-verdict shape. The finding is about the
  rater; the remedy is a conversation, not a deletion.
- **≥ 20 scoreable control pairs per rater** (P78's minimum, per person). A rater below it is
  excluded from Gate 4 **and named**; if nobody qualifies, Gate 4 is CANNOT VERIFY.

This is the same corroboration logic P71 proposes for editorial scoring and P75 §3.3.1 proposes
for the `unilateral` stamp, arrived at from the statistics rather than from the governance.

### 3.9 The one place this departs from P78's committed code, declared

`score_calibration.py` bootstraps by resampling **items**. This scorer resamples **learning
points**. Item resampling treats four judgements about one piece of prose as four independent
observations and reports a CI narrower than the data supports.

The change is in the **fail-closed direction** (wider CIs mean more CANNOT VERIFY, never more
PASS), but it is a change to a pre-registered instrument and so it is measured, not asserted:
**run against all six of P78 §4.4.1's adversarial answer sets, every OVERALL verdict and every
exit code is identical** (§3.10 row N1). CIs widen — e.g. `offset`'s Gate 2 moves from
[0.571, 0.694] to [0.585, 0.683], and `controls_broken`'s Gate 2 from [0.030, 0.443] to
[−0.093, 0.626] — and **on none of the six does the widening change a verdict.**

### 3.10 EVERY GATE HAS BEEN OBSERVED RED, before any human judgement exists

Per the standing order — a check never proven to fail is not a check. Answer sets are constructed
from the machine's own grades over the real 120-item set; the bats suite repeats the load-bearing
ones against a synthetic corpus-free fixture so they run on a CI runner that has never seen
`~/dir`.

| # | answer set | Gate 0 (α) | Gate 1 | Gate 1b | Gate 3 / 3b | Gate 4 | OVERALL · exit |
|---|---|---|---|---|---|---|---|
| **N1** | P78's six sets, one rater each | NOT ARMED | — | NOT ARMED | — | — | **all six OVERALL and exit codes identical to `score_calibration.py`** |
| **A** | three **byte-identical** answers files | *not reached* | — | — | — | — | **DUPLICATE-RATER · 2**, exact agreement 1.000, pair named |
| **B** | one rater, grades randomly permuted, alone | NOT ARMED | DISCARD | NOT ARMED | PASS / — | **DISCARD (11 items)** | DISCARD · 1 |
| **C** | two honest raters **+ the same random rater** | **0.163** [0.067, 0.272] INSTRUMENT FAILURE | CANNOT VERIFY | PASS | PASS / PASS | **PASS (0 corroborated)** + `rand` named, 11 severe vs panel median 0 | CANNOT VERIFY · 2 |
| **D** | one rater uniformly +1, one uniformly −1 | −0.138 INSTRUMENT FAILURE | CANNOT VERIFY | NOT ARMED | **PASS / FAIL (sd 0.79)** | PASS | CANNOT VERIFY · 2 |
| **E** | three raters agreeing around a shifted truth | CANNOT VERIFY (CI straddles 0.400) | CANNOT VERIFY | PASS | PASS / PASS | **DISCARD (3 corroborated)** | DISCARD · 1 |
| **F** | **three raters answering at random** | −0.035 INSTRUMENT FAILURE | **DISCARD** | PASS | PASS / PASS | **DISCARD** | **CANNOT VERIFY · 2 — labels NOT discarded** |
| **G** | three raters who agree with each other and read `1↔2` the opposite way to the machine | **0.936 COHERENT** | DISCARD | **DISCARD** (machine 0.701 below lowest human; means 0.526 / 0.528 / 0.526 vs **−0.175**) | PASS / PASS | PASS | DISCARD · 1 |
| **H₃₀** | as G, but only 30% of `1↔2` items flipped | **0.958 COHERENT** | **CANNOT VERIFY** (0.570, CI [0.414, 0.710] straddles 0.45) | **DISCARD** (gap 0.220) | PASS / PASS | PASS | **DISCARD · 1** |
| **H₂₂** | as H₃₀, 22% flipped | 0.959 COHERENT | **PASS** (0.665) | **PASS** | PASS / PASS | PASS | PASS · 0 |

Six things this establishes that an untested instrument could not:

1. **Row F is the whole design in one line.** Gates 1, 2 *and* 4 all say DISCARD, and the run
   **refuses to discard**, because the panel did not resolve and therefore never measured the
   machine. Fail-closed here means *refusing to delete*, which is the opposite of the reflex.
2. **Rows B and C are the same rater.** Alone, that person's answers delete the label set. On a
   panel of three they produce `PASS (0 corroborated)` plus an `OUTLIER-RATER` row naming them.
   **That is exactly what the operator's ruling buys, measured.**
3. **Row H₃₀ is why Gate 1b is worth having.** Gate 1 returns CANNOT VERIFY — the single-assessor
   instrument says *"I could not tell"* — while a coherent panel makes the machine's outlier
   status decidable. Gate 1b **decides a case Gate 1 explicitly cannot**, and row H₂₂ shows it is
   not trigger-happy: it passes the case Gate 1 accepts.
4. **Row D catches the vacuous pass.** Gate 3 reports PASS on a panel where one rater is a whole
   grade generous and another a whole grade harsh. Only Gate 3b sees it. Compare with row C,
   which has the *same overall verdict* and a *different remedy* — C is one random rater, D is two
   differently-briefed ones — and 3b is the only statistic that separates them.
5. **Row A is the failure whose symptom is a good number.** Three copies of one opinion give
   α = 1.000 and measure nothing. The detector fires at exact agreement ≥ 0.98 because the
   highest exact agreement ever *measured* on this instrument is **0.893 [0.866, 0.923]** (P78
   §5.2.3) — between instances of *one model* on identical items. Independent humans do not
   exceed that. **This is deliberately not the guild's `agreement_rate_for_auto_approval: 0.95`**,
   which is a binary stage-approval rate over a sample; a number reused across two meanings is a
   number that drifts.
6. **Row N1 makes the thresholds honest.** If they moved when the panel arrived they were not
   committed in advance.

**Additionally proven, and not a gate:** a rater's answers written in *their own* shuffled
ordering, joined through their own packet, produce **verdicts identical to the canonical
ordering**; and the same file scored with the join map withheld is **REFUSED** — *"Refusing to
guess which candidate was graded — score it with its packet or not at all."* A scorer that joined
on the raw label would compare one rater's grade about one passage with another's grade about a
different one and report the result as disagreement.

**Mutation testing of the bats suite, observed:** 13 tests green; four mutations applied to the
Python only (`COLLUSION_EXACT` → 1.01; Gate 0's dominance moved below DISCARD; Gate 4's
corroboration forced to 1; the rights refusal → `if False:`) produced **four failures of
thirteen**, one per mutation. Mutation 4 did not merely fail a check — the mutated builder
actually wrote 600-character corpus excerpts into `docs/reports/` inside the publicly mirrored
repository, and the file had to be deleted by hand before the suite would go green again.

---

## 4. Blinding and anti-self-interest — enforced in the artefact, not in the policy

### 4.1 Blind at the packet, never at the template

**A template that declines to print a field still ships it.** The estate has the counter-example
in its own tree: `pairing.blind: true` is declared in `media-guild.yml` while
`ApplyDecisionForm.php:44-51` renders `'#%d %s by %s — %s endorsements%s'` — author name and
endorsement count — to the person deciding.

So the calibration packet is **built** blind. Per rater, per item, the artefact carries exactly
three fields — `label`, `duration_band`, `excerpt` — and the builder asserts that key set and
exits 2 on any extra. Withheld: rank, ranker, `score_total`, `quality`, all 16 `q_parts`, episode
number and title, media id, the source pool, the machine's grade, its rationale, its confidence,
and the catalogue's current `video:` block. **The un-blinding key never enters the packet at
all** — the join is done offline by the scorer, against a file the rater never receives.

### 4.2 Two new withholdings, which are also a PARITY FIX

The packet also withholds the learning point's **catalogue address (`lp_id`)** and its **course
title**, replacing the first with a per-rater alias (`LP01` …).

This is not extra caution, it is a correction. `JUDGE-PROMPT.md` records what the machine saw:
*"the LP (title, one-sentence summary, ~200 words of body prose)"* — and nothing else. But
`render_calibration.py` prints `lp_id` and `*Course: …*` to the human. **The operator's own
calibration document therefore shows him two fields the machine judge never saw**, which breaks
the parity the comparison depends on *and* hands the reader a `grep` key straight into the
catalogue. Withholding both improves parity and reduces navigability at once.

### 4.3 Per-rater presentation order

Each rater's learning-point order and within-LP candidate order are shuffled under
`sha256(salt ‖ rater_id ‖ lp_id)`. One shared shuffle would make order and fatigue effects
**identical across the panel** — a systematic error the raters share, which is the exact class
P78 §5.2.7 says a same-model panel cannot see in itself, and it would inflate Gate 0's α for a
reason that has nothing to do with judgement. The builder **refuses** to emit two packets with
an identical ordering.

### 4.4 Anti-self-review, applied at BUILD time

`ADR-0006` / `pairing.anti_self_review: true`. A rater must not calibrate a learning point whose
current clip choice they authored or for which they filed a `ClipSuggestion`. The exclusion list
is passed to the builder and **the excluded learning points are not in that rater's packet at
all** — an exclusion applied at render time still ships the item to the browser.

**And it fails closed rather than shrinking quietly.** If exclusions drop a rater below 60 items,
or below the **20 control items Gate 4 needs**, the builder **refuses to build the packet** and
says why. Proven: excluding 5 control learning points leaves 12 controls and returns
*"only 12 control items survive the exclusions, below the 20 Gate 4 needs … refused rather than
built blind."*

**How much this bites today is measurable and small.** P75 measured **172 of 175** live clips as
not their learning point's top candidate, and ops#349 established all 176 `video:` blocks as
machine output from a 2026-03-08 regex scrape — so almost no incumbent choice has a human author
to be conflicted about. `nwc_clip_review` has **0 suggestions and 0 decisions in the module's
entire life** (P75 §0). The exclusion list starts empty and grows exactly as fast as the guild
does.

### 4.5 What is NOT enforced, stated plainly

**A rater who wants to defeat the blinding can search the learning point's prose.** The prose
cannot be withheld — it is the thing being judged against, and the machine saw it. Three
defences, none of them perfect and all of them honest:

1. **Structural**, in the payload: there is nothing to reveal because nothing was shipped.
2. **Attested**: the rater records that they did not look up the episode or the current clip.
   An attestation is not a control, but an unrecorded promise is not even that.
3. **Detectable afterwards**: the calibration set carries each candidate's episode, so *"does
   this rater's grade profile track the incumbent `video:` block more closely than the panel
   norm?"* is computable after the fact. **This is specified and NOT built** (§9) — it needs the
   catalogue joined to the calibration set, which is scope this proposal does not take.

---

## 5. Doctrine and pedagogy: abstentions become ROUTES

P78 §3 defines `ABSTAIN-DOCTRINE` and `ABSTAIN-PEDAGOGY` and is emphatic that *"an abstention
means 'this question is not mine to answer', never 'I do not know'."* In one operator's hands an
abstention is a gap in the data. **In guild hands it is a referral**, and the guild already has
the ladder for it.

| | `ABSTAIN-DOCTRINE` | `ABSTAIN-PEDAGOGY` |
|---|---|---|
| **routed to** | **Sojourners propose → Theology approves** (the existing apprenticeship model) | the **formation** guild — the Media Guild's remit is explicitly *"not theological formation"* (ADR-0017) |
| **the question asked** | *"Is this passage doctrinally sound to place in front of a learner at this point?"* | *"Is this the right depth and a safe framing for a learner at this point?"* |
| **the answer** | **SOUND · UNSOUND · NEEDS-CONTEXT** | **FITS · TOO-DEEP · UNSAFE-FRAMING** |
| **precedent** | `tie_break.third_member_preference: active Master in this skill (other than the original two)` — the guild's own escalation shape | same |

**Two planes, and they must not be merged.**

- The **relevance plane** is graded 0–3, calibrated, and produces the shortlist.
- The **admissibility plane** is binary, guild-ruled, and *filters* the shortlist.

A routed verdict **never becomes a grade** and is never folded into any κ — P78's rule that an
abstention is not a grade holds exactly. An `UNSOUND` candidate is removed from the shortlist
whatever its relevance grade; a grade-3 passage that is doctrinally unsound is a *correct
retrieval result* and an *inadmissible clip*, and a system that cannot say both things at once
will eventually say the wrong one.

**Routing does not block scoring.** The rater's sitting completes, the routes queue
asynchronously, and the gates are evaluated on the numeric pairs with abstention pairs counted
and excluded — exactly as P78 specified. A guild that has to wait for a theologian before it can
learn whether its labels are usable will not run this twice.

**The panel adds a measurement here that no single assessor could make.** P78 §4.4 already
required the operator's abstention rate to be reported against the machine's **0.88%** (29 of
3,309). With N raters the report also emits the **Jaccard of the abstention item-sets**: *equal
rates on disjoint items means the abstention taxonomy is not shared*, even though the frequency
looks agreed. Two raters abstaining at 1% on completely different items is a finding about the
taxonomy, and the fix is the taxonomy, not the grades.

---

## 6. Recruitment reality: the capacity ladder

The guild is small and the estate has recorded exactly how small: 27 accounts on `nwd` live, **10
ever logged in**, 2 with `administrator`, **0 with `sitemanager`** — and `apply clip suggestion`
is granted only to those two roles, so *"exactly two accounts on the whole estate can apply a
clip, and one person is doing the work"* (P75 §3.1). P68 documented the same empty-clearance-pool
problem from the legal side.

**Design for N = 2–3. Degrade to N = 1 without changing the artefact format.**

| N | design | which gates are armed |
|---|---|---|
| **1** | the operator, exactly P78 §4.4. The guild's own `locked_choices.lonely_tasks` already sanctions this: *"Master may unilaterally complete with self-flag for later re-verification"* | 1, 2, 3, 4 |
| **2** | **complete crossing** — both raters judge all 30 LPs / 120 items | + **0**, **3b** |
| **3** | **complete crossing** — all three judge all 120 | + **1b** (all seven) |
| **≥ 4**, or > 120 items | **incomplete balanced design**: the **8 control LPs (32 items) are judged by everyone**, and the remaining 22 LPs are allotted so that **every pair of raters shares ≥ 10 LPs (40 items)** | all seven; pairwise κ on anchor-sized overlaps is reported CI-only, never gated |

**Why complete crossing up to N = 3, rather than splitting the work.** 120 items is one sitting.
The estate's bottleneck is *recruitment*, not per-person minutes, so full crossing extracts the
most statistical power per human-hour and makes every pairwise κ computable on all 120 items.
Splitting would save nobody any time and would halve the precision of every pairwise number.

**Why the anchor is the control stratum.** Gate 4 is the independent kill switch and it requires
corroboration; corroboration requires that the raters judged the *same* controls. The anchor set
must therefore be common, and it is the one stratum where that is non-negotiable.

**Why ≥ 10 shared LPs.** P78 §4.3 puts κ's SE at n = 120 at 0.05–0.09; at n = 40 it is roughly
0.09–0.16, which is why overlaps at anchor size are reported with their CI and never gated.

**The artefact format does not change at any rung.** One answers file per rater, the same flat
`{label: grade}` JSON P78 already committed. Krippendorff's α is chosen precisely because it is
defined on incomplete designs, so climbing the ladder changes the roster and nothing else.

---

## 7. Where it runs: the exact gaps between `nwc_clip_review` and a member grading on a Saturday

Audited against the module as it stands on `nwd` (branch `ops-328-clip-corpus`). **The headline
is better than expected and the conclusion is unexpected:**

> **The deep-review surface is already almost blind — and the calibration does not need the site
> at all.** A packet is a Markdown file and a JSON file. A member can do the whole 60–90 minutes
> today, with nothing deployed anywhere. **That is why the packet exporter is what this proposal
> ships and the UI work is what it defers.**

**Corrections to assumptions worth recording.** There is **no `RubricExplainer`** anywhere in
`src/` — the rubric breakdown is stored as raw JSON and never rendered. The off-list telemetry
(`ChoiceOutcome`, `choice_rank`, outcomes `shortlist`/`off_list`/`rejected`/`no_shortlist`) is
real but sits **unmerged** on `ops-338-choice-telemetry`, not on main.

### (a) Pure data plumbing — **BUILT BY THIS PROPOSAL**

| gap | status |
|---|---|
| a per-rater blinded packet, own seed, anti-self-review at build time | `scripts/lib/clip-calibration-packet.py` |
| an answers template per rater, in the schema the scorer already reads | same |
| N-rater scoring, both axes, seven gates, fail-closed | `scripts/lib/clip-calibration-multi.py` |
| the join between a rater's local labels and the candidates | in the scorer; refuses without the map |
| the rights boundary between the packet and the mirrored repo | enforced in the builder, proven red |
| a verb, per the standing order | `pl clips calibrate packet\|score\|status` |

### (b) Needs new UI — **specified, NOT built**

1. **No route serves a fixed, pre-selected item list to a named person.**
   `ReviewQueueController` is a flat slot list, `->range(0, 100)` sorted by `changed DESC` —
   the same list for everybody, and P75 measured that this leaves **76 of 176 slots
   unreachable**. Calibration needs its own route rendering one packet item at a time.
2. **Excerpt truncation is on the wrong side of the wire.** `PREVIEW_CHARS = 600` exists only in
   `data/build-clip-corpus.py:65`, capping a `preview_text` the UI never renders. What the deep
   template actually prints is `full_text`, `context_before`, `context_after` — **untruncated**,
   from unbounded `string_long` fields. The estate's 600-character bound is enforced where the
   corpus was *built* and nowhere it is *displayed*.
3. **Two real leaks on the deep surface**, both trivial to suppress on a calibration route and
   both currently rendered: `q={{ c.quality.value }}` (the raw rubric score, unlabelled and
   unexplained) at `nwc-clip-review-deep.html.twig:26-27`, and `ep {{ c.episode.value }}` at
   line 26. A third, the `Current:` incumbent box at lines 13-22, is *outside* the candidate list
   — the list itself carries no `is_current` flag, so the incumbent is disclosed but not marked.
4. **No per-rater answer storage.** Nothing per-user exists beyond `ClipSuggestion.endorsers` and
   `LearnerSignal.signal_user`.
5. **No progress or resume.** 30 learning points is a morning, not a page load.

### (c) Needs new access control / policy — **specified, NOT built**

1. **A `grade calibration item` permission that does not imply `apply clip suggestion`.**
   Today the only clip-review capability of substance is held by 2 accounts.
2. **Live-queue anti-self-review.** `ReviewDecisionService::apply()` never compares
   `suggestion.author` to the acting user, and `endorse()` will let an author endorse their own
   suggestion. P79 solves this *for calibration* at build time; the live queue still needs it,
   and P75 §3.3.2 already specifies the guard that would fire on **every apply immediately** —
   the opposite of the ops#214 class of guard nobody has seen fire.
3. **`lock clip review slot` is a declared permission with no route** — dead, and worth deleting
   or wiring rather than leaving as apparent coverage.

---

## 8. Formation, not chores

The estate frames guild work as formation — the Sojourners ladder, the audience birthing ladder,
`transcript_verification_check` as *"base activity before earning any badge"*. Calibration fits
that frame precisely, and the reason is not motivational packaging:

**Calibration is the only task in the clip programme where a member finds out what they actually
believe.** Every other unit of work — confirm a Band 3 clip, re-trim a Band 1 window — asks a
member to apply a standard. Calibration asks 120 times, in a row, blind, where *this* member puts
the line between *"supports the point"* and *"is about a neighbouring point"* — the `1↔2`
boundary that P78 §5.2.5 measured as **57.7% of all disagreement**, and which P78 §5 item 2 names
as *"a judgement about the curriculum, not the passage"*. A member who has been through it once
has a formed, examined view of what the courses are actually teaching, and the panel's own α
tells them whether that view is shared. That is what formation means here: not that the work is
worthy, but that **the worker is measurably different afterwards, and can see how.**

Concretely, and within the guild's existing rules:

- It stays **`opt_in: true`** and **`counts_toward_practitioner: false`**, exactly as
  `media-guild.yml` locked at Q-MG-08. Calibration is against a key, not a live pair, and
  inflating the Practitioner ladder with it would devalue the five matched pairs that earn it.
- It is **`separately_tracked: true`** — and the panel gives that tracking something real to hold:
  a member's own per-rater κ, their bias, and their α against the panel. **Nobody is scored, and
  the report says so**; what is recorded is that they participated in the measurement that decided
  whether 3,309 labels were believed or deleted.
- **The `bootstrap_note` stops being true the day a second member judges**, and that is worth
  saying out loud to a new member: *"calibration is calibration against Rob"* becomes *"calibration
  is calibration against a measurement Rob is one input to"*. The second rater is the person who
  changes that, which is a genuine and unusually legible contribution for a first task.
- **It is the shortest path to a real decision in the whole programme.** One morning determines
  whether the machine's shortlist may be trusted. P75 §2.3 makes the case for a unit a volunteer
  *can finish in one sitting*; this one finishes something the estate is actually blocked on.

---

## 9. What was built, what was not, and why

**Built, red-proved, and in this MR:**

- `scripts/lib/clip-calibration-multi.py` — the seven-gate panel scorer.
- `scripts/lib/clip-calibration-packet.py` — the per-rater blinded packet builder.
- `pl clips calibrate packet | score | status`.
- `tests/unit/test-clips-calibrate.bats` — 13 tests, mutation-proved at 4/13.
- `tests/fixtures/clip-calibration/calibration_set.json` — 30 synthetic learning points carrying
  **no corpus**, so the suite runs on a runner that has never seen `~/dir`.
- `docs/guides/clip-calibration-for-guild-members.md` — the one page a member reads.

**Deliberately NOT built, with the reason:**

| not built | why |
|---|---|
| the Drupal calibration route, per-rater answer entity, progress/resume | §7 establishes the calibration **does not need the site**. Building a UI first would delay the ruling behind a deployment and would be designed against a workflow nobody has run yet. Build it after the first real panel, informed by it. |
| the display-path 600-character truncation and the `q=` / `ep` suppression | real defects, but they belong to `nwc_clip_review` and to ops#338's open decision about where the clip code lives — not to a calibration MR. Recorded in §7(b) so they are not lost. |
| the incumbent-correlation detector (§4.5.3) | needs the catalogue joined to the calibration set. Specified so it can be built; not smuggled into scope. |
| any change to `render_calibration.py` or `score_calibration.py` in `~/dir` | ops#338 is an **open operator decision** about where that code should live, and `pl clips`' own header records the rule: *"new code must not accrete in ~/dir while that is undecided."* The new code is a verb. |
| lowering Gate 0 to a threshold the panel will definitely clear | that is the `21 → 22` error in advance. The floor is set from the claim being made; if a real panel lands at 0.55 the honest answer is SCREENING-ONLY, and it is written down before anyone judges. |
| a majority/consensus label | manufactures a cleaner reference than exists, and does not exist at all at N = 2. |
| touching any `video:` block, any live tier, or the corpus | P78 §7 stands. |

**A gap this proposal creates and does not close:** the packet builder emits a rater's document
and join map to `~/dir`, and there is no verb yet that *collects* completed answers files from
members who are not the operator. Today that is a file each; at N = 4 it is an upload form, and
that is the point at which §7(b)'s UI stops being optional.

---

## 10. Sequencing — the exact order to turn this on for real members

Steps 1–4 need no new member and no deployment. **The operator can run the whole instrument
himself today**, and doing so is the cheapest possible de-risking of the guild version, because
it exercises every piece of tooling with N = 1 before a volunteer's time is spent.

| # | step | command | blocked on |
|---|---|---|---|
| 1 | build the operator's own packet | `pl clips calibrate packet --rater=rob` | — |
| 2 | grade it (60–90 min) | read `calibration-packet-rob.md`, fill `answers-rob.json` | the operator |
| 3 | check it is complete before scoring | `pl clips calibrate status` | step 2 |
| 4 | score at N = 1 — **this is P78 phase 2, discharged** | `pl clips calibrate score` | step 3 |
| 5 | **the switch: name the second rater.** Exclusions only if that member has authored a clip choice | `pl clips calibrate packet --rater=greg [--exclusions=…]` | a second member |
| 6 | they grade their own packet, in their own order | — | that member |
| 7 | re-score — **Gates 0 and 3b arm themselves** off the number of answers files | `pl clips calibrate score` | step 6 |
| 8 | third rater — **Gate 1b arms** | as step 5 | a third member |
| 9 | route the abstentions | the `routes` block of the report → Theology / formation | step 7 |
| 10 | act on the verdict | PASS → the labels feed P77's L1/L2 · PARTIAL → deltas only · DISCARD → P78 §4.5 · **INSTRUMENT FAILURE → fix the rubric row, re-brief, re-run** | step 7 |

**Nothing in steps 5–8 is a configuration change.** There is no "enable panel mode" flag, and
there deliberately never will be one: the gates arm off how many answers files exist, which is
the same declared-fact pattern as `approvers:` in `private/secrets-registry.yml` and the same
warning P75 §3.3.4 already wrote — *"There must be no 'turn on dual review' setting, because a
setting is a second place for the policy to live."*

**Step 4 is not a formality and step 7 does not supersede it.** P78 §8 records that phase 2 is a
decision point with every outcome written in advance. A panel makes the decision better; it does
not make it later.

---

## Appendix A — reproduction

```bash
pl clips calibrate status
pl clips calibrate packet --rater=<id> [--rater=<id> ...] [--exclusions=FILE]
pl clips calibrate score                       # scores every rater who handed in
bats tests/unit/test-clips-calibrate.bats      # 13 tests, corpus-free fixture
```

The N = 1 equivalence proof of §3.9, against P78's own six adversarial sets:

```bash
for f in perfect inverted offset controls_broken incomplete noisy; do
  python3 scripts/lib/clip-calibration-multi.py \
    --cal=~/dir/courses_v3/silver-labels-2026-08-11/calibration_set.json \
    ~/dir/courses_v3/silver-labels-2026-08-11/redproof/$f.json
done
```

Packets, answers and the calibration set stay in `~/dir` and are never committed here (P78 §6);
the builder refuses to write them into this repository and that refusal is test 12.

## Appendix B — what this session did NOT do

- **No GPU work, no index build, no network access, no remote host touched.** The `ai-host`
  measurement host was unreachable (`ssh rc 255`) throughout; `pl clips finish` reported it as
  CANNOT VERIFY and it was never treated as anything else.
- **No corpus text was copied into this repository**, and the one time a mutated builder did so
  it was detected by its own test and deleted.
- **No live tier, no `video:` block, no catalogue edit, no `~/dir` build output written.**
- **No claim that the machine judge is good or bad.** Every number in §3.10 is from an
  adversarial answer set constructed from the machine's own grades. **No human has judged
  anything yet** — `pl clips finish` reports `0 of 120 judgements graded`. This proposal builds
  the ruler and proves it can read low; it does not report a measurement.
