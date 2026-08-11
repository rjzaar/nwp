# P78 — Silver relevance labels for clip retrieval, and the instrument that decides whether to believe them

**Status:** PROPOSED — method and instrument only. No production code, no schema change, no live
write, no catalogue `video:` block touched.
**Owner:** *(unassigned)*
**Issue:** `nwp/ops#348`
**Siblings — none of these is on `main` yet, so they are cited by branch rather than linked:**
`P75-clip-catalogue-triage-and-guild-workflow.md` (guild process, branch `ops-337`) ·
`P76-clip-retrieval-hybrid-recall-inspectable-rerank.md` (the engine, branch `ops-349`, MR !430) ·
`P77-clip-retrieval-evaluation-harness.md` (the harness, branch `ops-348`, MR !431).
**P78 is the ruler's ruler**:
P77 says *how* to measure, P78 supplies the labels to measure against and — the load-bearing
part — the test that says whether those labels may be believed.

---

## 0. The one-paragraph version

The operator asked whether some of the relevance judging should be done by hand to create a gold
standard. The answer is **yes, but only ~30 items of it, and not yet as gold**. Human judging is
the estate's scarcest resource and P77 §3.4 costs a full gold programme at 13–22 hours. This
proposal instead produces a **machine-judged SILVER label set now** — graded 0–3, with a
one-line interrogable rationale on every judgement, judged blind to the incumbent — and then
spends **60–90 minutes of the operator's time** on a deliberately-selected 30 learning points
whose only purpose is to answer *"is the machine judge trustworthy on this corpus, and where does
it fail?"*. **The agreement threshold is committed in this document, before he judges**, so the
test can fail. If it fails, the labels are discarded in one step.

**Nothing here is named gold. Nothing here may be quoted as an accuracy figure.**

---

## 1. Why silver, and why the word matters

P77 §1 establishes that the estate's existing 205 episode labels are bag-level, single-annotator,
and necessary-but-not-sufficient. They say *"an author cited this episode"*. They do not rank the
40 candidates, and P75 measured that **172 of 175** live clips are not their learning point's top
candidate. So the estate has no passage-level relevance judgements at all.

Three routes to getting some:

| route | cost | what it can support |
|---|---|---|
| exhaustive human judging | 13–22 h (P77 §3.4) | gold; nDCG; absolute claims |
| **machine judging (this proposal)** | **hours of machine time, ~0 human** | **deltas between rankers; a shortlist filter — *if calibrated*** |
| nothing | 0 | the `21 → 22` situation |

The middle row is only worth anything **with the calibration attached**, and that is why §4 is
the centre of this document rather than an appendix. A machine label set without a measured
agreement figure is precisely the estate's named failure shape — a check nobody has seen fail —
relocated into the ground truth, where it is worse, because everything downstream inherits it
silently.

**Naming discipline, enforced by the artefact itself.** Every file in the label set carries
`label_class: SILVER-MACHINE-JUDGED`, the judging model, the date, the prompt hash, and the
abstention counts. There is no `gold` in any filename, key or variable. A future session that
wants to call these gold has to edit the field that says they are not.

### 1.1 What was produced — measured 2026-08-11

| | |
|---|---|
| judgements | **3,309** — expected 3,309, **0 missing**, 0 duplicate, 0 unparseable |
| learning points, complete | **251 of 251** |
| rationales failing the interrogability check | **0** |
| grade **3** (this is the passage) | 638 (19.3%) |
| grade **2** (relevant) | 956 (28.9%) |
| grade **1** (related, not this point) | **1,502 (45.4%)** |
| grade **0** (irrelevant) | 184 (5.6%) |
| `ABSTAIN-DOCTRINE` | 17 |
| `ABSTAIN-PEDAGOGY` | 12 |
| confidence high / medium / low | 751 / 2,228 / 330 |
| LPs with a grade-3 somewhere in the judged pool | **209 of 251** |

**Grade 1 dominates at 45.4%, and that is the corpus's signature.** 648 episodes of one show
means the modal failure is *right territory, wrong point*, not *irrelevant*.

**Confidence behaves like confidence.** High-confidence judgements are 52.5% grade 3;
low-confidence are **0.9%** grade 3. `low` reliably means *"I could not find the passage in
what I was shown"*, which is what makes stratum B of §4.2 informative rather than arbitrary.

---

## 2. What was judged, and how it was blinded

### 2.1 The pool

| | |
|---|---|
| learning points | **251** (all of them, including the 46 with no provenance) |
| candidates judged | **3,309** |
| from the current pipeline (`_runs_v3.json` @ `c22dfbd`) | top **10** per LP — 2,489 |
| from the P76 hybrid pilot (BM25 + bge-m3, RRF) | top **4** per LP for the 205 it covers — **820** |
| provenance-injected candidates in the pool | 95 (flagged, never excluded from judging, always excludable in analysis) |

Two rankers, deliberately. A pool fed by one ranker can only ever agree with that ranker, and
P77 §3.6 makes the pooling bias a stated refusal (`POOL-NAIVE`) rather than a caveat. Two rankers
also supply the disagreement axis that §4 selects the calibration items from — which is not a
heuristic but what Minimal Test Collections reduces to (P77 §3.4).

### 2.2 The blinding contract

The judge saw, per candidate: an opaque key (`C01`…), a coarse duration band, and up to three
excerpts. It did **not** see, and could not infer:

- the candidate's **rank**, or which of the two rankers produced it
- `score_total`, `quality`, or any of the 16 `q_parts` — the rubric's own opinion
- the **episode number or title**, the media id, or any deep link
- whether the candidate came from the `source: provenance` injected pool
- **which episode the provenance map names for that learning point**
- whether the catalogue's `video:` block currently points here

Candidate order is a deterministic shuffle seeded on `sha256(salt ‖ lp_id)`, so position carries
no rank information. The un-blinding key is written to a separate file and joined only after
judging.

**The blinding is enforced structurally and has been proven red.** The builder asserts the exact
allowed key set on every packet and candidate object. Injecting a single leaked field
(`episode_title`) makes it exit **2** naming **3,309** leaks; the clean build exits 0 with 0. It
is a structural check and not a text grep on purpose: a grep false-positives on the learning
point's own prose — the catalogue text contains the words *source*, *rank* and *quality* — and a
check that fires for the wrong reason is not a check.

**What could not be fully blinded, stated honestly:**

1. **Duration band is shown.** The judge needs to know whether three excerpts sample two minutes
   or twenty. Duration is not the rubric's score, but the rubric's `bucket_ctr` term does prefer
   long windows, so band is a weak correlate of the incumbent's preference. Recorded, and carried
   on every row so the correlation is measurable rather than assumed.
2. **The corpus is one show.** A judge cannot be blinded to the fact that every candidate is
   Divine Intimacy Radio. This bounds grade 0 from below — see §5.
3. **The learning-point prose sometimes names its own source** (e.g. *"Dan Burke emphasises…"*,
   an explicit `sources:` block). Where it does, a judge can infer something about provenance
   from the query side. This was not stripped, because stripping the LP's own text would change
   what is being judged; it is recorded as a residual leak.

### 2.3 The excerpts, and the bias this creates

Excerpts are sampled at **fixed fractions** of the window (start / middle / end), never chosen
for relevance. Choosing the highest-lexical-overlap sub-window would import the ranker's own
lexical bias into the judge and manufacture agreement — the exact failure P76 §6.3 item 4 names
for the highlight UI.

The price is real and is the single largest known weakness of this label set:

> **Long candidates are systematically under-sampled.** A `15+ min` window is judged on roughly a
> sixth of its text. A passage that does teach the learning point, eleven minutes in, will be
> graded on evidence that does not contain it. **The bias runs one way: it suppresses grades on
> long candidates.**

Because the current pipeline's candidates are median 394 s and the hybrid's are 150 s, this bias
is **not symmetric between the two rankers** and would flatter the hybrid in any head-to-head.
`duration_band` is carried on every judgement so the effect can be measured, and any
ranker-vs-ranker claim from this set must be reported stratified by band or not at all.

**Measured, and the bias is real:** mean grade by band is 1.770 at `~3-5 min`, 1.489 at
`~5-10 min` and **1.274 at `15+ min`** — the longest windows score lowest, which is what an
under-sampling bias looks like. So the raw top-1 comparison below is *not* admissible as it
stands:

| ranker | top-1 mean grade | top-1 graded 3 | top-1 graded ≥2 |
|---|---|---|---|
| current pipeline (n=251) | 1.656 | 43 (17.1%) | 129 (51.4%) |
| P76 hybrid (n=205) | **2.299** | **100 (48.8%)** | **165 (80.5%)** |

**Band-matched, it survives.** `~3-5 min` is the only band both rankers populate in quantity:

| | n | mean grade |
|---|---|---|
| current, `~3-5 min` | 914 | **1.395** |
| hybrid, `~3-5 min` | 791 | **2.204** |

Controlling for the one bias that could have manufactured it, the hybrid's advantage is
**larger**, not smaller. This is a silver-label result and inherits every caveat in §5 — but it
is the first passage-level evidence in the estate bearing on P76's architecture claim, and it
points the same way P76's own episode-level numbers did.

---

## 3. The scale, and the two abstentions

| grade | name | test |
|---|---|---|
| **3** | THIS IS THE PASSAGE | an excerpt states or teaches the LP's specific claim |
| **2** | RELEVANT | genuinely about the LP's subject and supports it, but does not make its particular claim |
| **1** | RELATED, NOT THIS POINT | same broad territory, different question — the corpus's dominant failure mode |
| **0** | IRRELEVANT | different subject, advertisement, station ident, listener chat |

Graded rather than binary, because P77 §2.2 makes graded relevance the precondition for nDCG ever
becoming quotable, and because binary judging on a single-show corpus collapses: almost everything
is "sort of about prayer".

**Every judgement carries a one-line rationale naming what in the passage matched what in the
learning point.** This is not documentation, it is the deliverable's validity condition: a label a
reviewer cannot interrogate is worth nothing to this estate. Rationales of the *"seems relevant"*
class are rejected by the aggregator.

### The abstentions, and why they are not a hedge

- **`ABSTAIN-DOCTRINE`** — the topical match is visible but the decision turns on doctrinal
  soundness or the correct reading of a magisterial or saintly text. **Theology's call.**
- **`ABSTAIN-PEDAGOGY`** — the topical match is visible but the decision turns on formation fit:
  right depth, safe framing, presumed prior formation. **The Media Guild's remit is explicitly
  "not theological formation"** (ADR-0017), so this is the formation guild's call, not a
  retrieval question at all.

The method file forbids abstaining out of uncertainty — that is a grade with `confidence: low`.
**An abstention means "this question is not mine to answer", never "I do not know".** A silver set
that quietly answers questions it has no standing to answer is worse than a smaller one, because
the answers look like the others.

### 3.1 The abstention rate is a finding, and it points the opposite way to the intuition

**29 of 3,309 judgements — 0.88% — turned on a guild question.** 17 doctrinal, 12 pedagogical.
They were not evenly spread: they cluster on deliverance and the demonic, acquired-vs-infused
contemplation, corporal mortification, lay authority over the enemy, and reading John of the
Cross's dark night onto another saint's experience — i.e. exactly the places a formation
programme would expect them.

The operational reading, stated carefully because it is load-bearing for the production run:

> **Topical shortlisting is almost never a guild question. Choosing the one clip may still be.**

Under 1% of *candidates* needed a doctrinal or pedagogical ruling to be **placed on a shortlist**.
That supports building the shortlist by machine. It does **not** support the machine making the
final pick, because the final pick is where the doctrinal and formation questions concentrate —
and a shortlist of 16 that contains one unsound passage has done its job correctly while still
handing a human something that needs a guild eye.

**And this number is itself a machine judgement.** It is the machine's own estimate of how often
it was out of its depth, which is precisely the quantity a miscalibrated judge would get wrong.
**§4.4's fifth reported quantity is the operator's own abstention rate**, for exactly this reason:
if he abstains materially more often than 0.88%, the machine has been answering guild questions
it has no standing to answer, and the taxonomy — not the grades — is what needs fixing.

---

## 4. THE CALIBRATION INSTRUMENT

This is the deliverable that matters. Everything above is only as good as this.

### 4.1 What the operator is asked to do

**30 learning points, 4 candidates each = 120 graded judgements, ~60–90 minutes.** He grades on
the same 0–3 scale, from the same short excerpts, without seeing the machine's grade, its
rationale, its confidence, which ranker produced the candidate, or its rank. Candidate order
within each learning point is re-shuffled under a **second, different seed**, so his ordering
leaks neither the machine's opinion nor either ranker's.

The document is self-contained and lives **outside this repository** — see §6.

### 4.2 How the 30 were chosen — and why not at random

A random 30 would spend the operator's scarcest hour measuring the easy middle. The strata:

| stratum | n | why |
|---|---|---|
| **A — ranker disagreement** | 12 | the two rankers put a **different episode** at rank 1, and the machine graded the two top-1s differently. Maximum information about which ranker should feed the production shortlist. This is Minimal Test Collections' own selection rule: a candidate both systems rank identically has weight zero (P77 §3.4). |
| **B — lowest machine confidence** | 10 | where the machine itself says it is least sure. If agreement holds here, it holds everywhere. |
| **C — controls, machine certain** | 8 | 4 where the machine graded a candidate **3 at high confidence**, 4 where it graded the whole shortlist **≤1 at high confidence**. These carry no information about ranker choice. They exist to expose a **systematic skew**. |

**Stratum C is the one that can sink the whole set.** A judge that disagrees on hard cases is
noisy, and noise averages out over a comparison. A judge that is *wrong where it was certain* is
faulty, and its errors are correlated — they will not average out, and every downstream number
inherits them. That is why C has its own independent kill switch in §4.4.

**Stratified selection is not a random sample, and the consequence is stated.** These 30 are
deliberately drawn from the hard and the extreme, so the agreement measured on them is
**not** an unbiased estimate of agreement over all 3,309 judgements — it is expected to be
**lower** on strata A and B and **higher** on C. Agreement is therefore reported **per stratum,
never pooled into one headline number**, and the thresholds below are set per stratum for that
reason.

### 4.3 The statistics

| what | statistic | why this one |
|---|---|---|
| graded agreement, 0–3 | **quadratic-weighted Cohen's κ** | ordinal: a 3-vs-0 disagreement must not score the same as 3-vs-2. Unweighted κ treats them alike. |
| screening agreement | **Cohen's κ** on the binary collapse `grade ≥ 2` = "worth a human's time" | this is the decision the production run actually makes |
| direction of error | **mean signed difference** (operator − machine) | κ is blind to a uniform offset. A judge one whole grade too generous can post a respectable κ. |
| where it fails | **full 4×4 confusion matrix**, plus the same split by `duration_band` | names the failure instead of scoring it |
| abstentions | reported separately, **never imputed** | an abstention is not a grade and may not be silently folded in |

**Sample-size honesty, stated before the numbers exist.** n = 120 paired judgements gives κ a
standard error of roughly **0.05–0.09**, so a 95% CI of about **±0.10–0.18**. Two consequences,
both binding:

1. **Report the bootstrap CI, never the point estimate alone.**
2. **A CI that straddles a threshold is `CANNOT VERIFY`, graded AMBER — not a pass.** Fail-closed
   is the estate rule (CLAUDE.md), and this is exactly the case it exists for. The tempting
   reading of "κ = 0.58, threshold 0.60, close enough" is the `21 → 22` error wearing different
   clothes.

### 4.4 THE THRESHOLDS — committed here, before any human judgement exists

Four gates. **All four must pass.** They are stated so the test can fail, and the fourth can fail
on its own regardless of the other three.

**Gate 1 — screening agreement (primary).** Cohen's κ on the binary `grade ≥ 2`, over all 120
judgements:

| κ | verdict |
|---|---|
| **≥ 0.45** | **PASS** — the silver set may be used to compare rankers and to certify a machine-built shortlist |
| 0.30 – 0.45 | **PARTIAL** — usable for ranker *deltas* only; may **not** certify a shortlist for human authors |
| **< 0.30** | **DISCARD** |

Why 0.45 and not a Landis & Koch band: the bands were called arbitrary divisions **by their own
authors** (P77 §3.5), and quoting them as a finding is the same error class as `21 → 22`. The
number is set by the *use*. The production run asks the machine to reduce ~100 candidates to 16
for a human author. At the base rate of `grade ≥ 2` observed in this pool, κ below ~0.3 means the
filter is barely better than chance-corrected noise and the 16 cannot be trusted to contain what
the human would have chosen; ~0.45 is the point at which the filter's errors are small enough
that a human reading 16 still reaches the passage he would have found reading 100.

**Gate 2 — graded agreement.** Quadratic-weighted κ over the numeric grades:

| κ_w | verdict |
|---|---|
| **≥ 0.60** | graded metrics (nDCG and the like) may be computed from silver labels |
| 0.40 – 0.60 | **binary collapse only** — graded metrics REFUSED |
| **< 0.40** | **DISCARD** |

**Gate 3 — directional bias.** |mean signed difference| over the 120 numeric pairs must be
**≤ 0.5 grades**. Above that the set is systematically skewed and must be recalibrated even if
Gates 1 and 2 pass — a uniformly generous judge agrees about *ordering* while inflating every
absolute figure, and absolute figures are what a shortlist promise is made of.

**Gate 4 — the control gate (independent kill switch).** On the stratum-C judgements (32 items,
**31 scoreable** — one is an abstention pair and abstentions are never folded into a grade): if
the operator disagrees by **≥ 2 grades on more than 2 of them**, the **entire set is DISCARDED
regardless of Gates 1–3**. Rationale in §4.2: correlated error where the judge was certain is a
fault, not noise, and no aggregate statistic is allowed to average it away. The gate reports
`CANNOT VERIFY` rather than passing if fewer than 20 control pairs are scoreable.

### 4.4.1 Every gate has been observed RED, before any human judgement exists

Per the standing order — a check never proven to fail is not a check — the scorer was run against
six adversarial answer sets constructed from the machine's own grades:

| answer set | Gate 1 | Gate 2 | Gate 3 | Gate 4 | overall / exit |
|---|---|---|---|---|---|
| perfect agreement | PASS | GRADED | PASS | PASS (0/31) | PASS · 0 |
| **scale inverted** | **DISCARD** | **DISCARD** | **FAIL** (generous 0.71) | **DISCARD** (16/31) | DISCARD · **1** |
| **uniform +1 offset** | CANNOT VERIFY | CANNOT VERIFY | **FAIL** (harsh 0.67) | PASS | CANNOT VERIFY · **2** |
| **controls wrecked, rest perfect** | CANNOT VERIFY | CANNOT VERIFY | PASS | **DISCARD (31/31)** | DISCARD · **1** |
| 9 answers missing | PASS | GRADED | PASS | PASS | **CANNOT VERIFY · 2** |
| realistic noise (±1 on ~half) | PASS | GRADED | PASS | PASS | PASS · 0 |

Four things this establishes that an untested threshold could not:

1. **Gate 3 fires in both directions** — a systematically generous judge and a systematically
   harsh one both fail it.
2. **Gate 4 is genuinely independent.** In row 4 it discards the set while Gate 3 passes
   outright and Gates 1–2 only go amber. The kill switch is not decoration.
3. **The fail-closed CI rule bites.** The `+1 offset` row returns
   `CANNOT VERIFY (95% CI [0.571, 0.694] straddles the 0.60 threshold)` rather than reading
   0.63 as a pass. This is the `21 → 22` discipline applied to the estate's own instrument.
4. **The gates tolerate honest disagreement and not systematic error.** Perturbing roughly half
   the grades by ±1 still passes; a uniform one-grade shift does not. That is the correct
   sensitivity for an instrument measuring a judgement humans genuinely differ on (P77 §3.5:
   assessor Jaccard ≈ 0.30 with system rankings preserved at τ ≈ 0.94).

The six answer files are kept beside the label set so the red proof can be re-run.

**And a fifth thing that is not a gate but must be reported:** the operator's own
`ABSTAIN-DOCTRINE` / `ABSTAIN-PEDAGOGY` rate. If he abstains on materially more items than the
machine did, the machine has been answering guild questions it has no standing to answer, and the
abstention taxonomy — not the grades — is what needs fixing.

### 4.5 Discarding in one step

If any gate fails:

```
rm -rf <label-set-directory>
```

Nothing else in the tree changes. This is a property of the §6 split, not a promise: the engine
repo receives the **method, the generator and the aggregate statistics** and never the labels, so
no committed artefact, no test fixture and no baseline row depends on a label file. The set is
identified by a single `label_set_id`; retiring it is deleting one directory and, if it was ever
cited, marking that `label_set_id` retired in the report that cited it.

---

## 5. Where machine judgement is weakest on THIS corpus

Stated before the calibration result, so it cannot be written to fit whatever comes back.

1. **The floor is not 0, it is 1.** 648 episodes of one show on one subject. Almost every
   candidate is *"sort of about the interior life"*, so the honest floor is grade 1 (right
   territory, wrong point) and grade 0 is nearly reserved for advertisements and listener chat.
   Observed across batches: grade 0 ranged from **0%** to **18%** of a batch. A metric that
   assumes an irrelevant tail does not have one here.
2. **The 1-versus-2 boundary is where all the difficulty is, and it is a judgement about the
   curriculum, not the passage.** *"Supports the point"* versus *"is about a neighbouring point"*
   depends on what the course intends the learner to take away — which the author knows and the
   machine infers from ~200 words. This is where the calibration is most likely to disagree, and
   it is the boundary the production shortlist actually turns on.
3. ~~**The judge is not internally consistent, and this is measured.**~~ **SUPERSEDED
   2026-08-11 by the separating experiment — see §5.2. The 2.9 %–35.5 % spread was
   almost entirely the COURSES, not the judges.** What this row originally said, and
   correctly flagged as an upper bound, was: the 26 judging batches were independent
   instances of the same model with the same prompt; their grade-3 rates span **2.9 % to
   35.5 %** (sd 7.8 pp) and their mean grades span **1.20 to 1.98** (sd 0.19); four batches
   returned no grade 0 at all. That observation stands as an observation. Its *reading* —
   *"absolute grade rates from this set are not trustworthy"* — does not: instance identity
   was confounded with which courses each instance judged, and **§5.2 separated them**.
   Measured on identical items, the judge-only sd is **1.53 pp** (95 % CI 0.80–3.63),
   i.e. **3.8 %** of that variance (95 % CI 1.1 %–21.6 %). The remaining ~96 % is which
   learning points a batch happened to contain. The correct replacement warning is
   narrower and is stated in §5.2.
4. **Long windows are judged on a fraction of their text** (§2.3), and the bias is asymmetric
   between the two rankers.
5. **Sibling learning points are near-duplicates by construction.** Courses walk through one
   teaching in five steps; the machine (like the ranker) cannot always tell step 3 from step 4.
   P75 measured 127 of 251 LPs still sharing a top candidate with a sibling; the judge inherits
   exactly that confusion.
6. **Doctrinal and pedagogical calls are not the machine's** (§3), and the abstention counts are
   the honest measure of how often they arose.
7. **A transcription error is invisible to the judge as well as the ranker.** A misspelt proper
   noun (P76 §3.7) reads as an absence to both, so the judge cannot correct for it and will grade
   a correct passage down.

---

## 5.1 Three incidental findings the judging pass produced

These are by-products, not the deliverable, and each is reported with what it does and does not
establish.

**(a) The two rankers essentially never agree, and that alone raises the stakes.** Over the 205
learning points both rankers cover, they place a candidate from a **different episode** at rank 1
for **186 of 205 (90.7%)**, and **84** learning points have *zero* episode overlap between the two
top-lists. Whatever else is true, the choice of ranker for the production shortlist is not a
detail — it changes almost every answer.

**(b) The provenance episode is independently corroborated — the first such evidence.** The judge
was blind to which candidates came from the `source: provenance` injected pool. It graded them
**mean 2.151, 35.5% grade 3**, against **1.609 / 19.0%** for corpus-wide candidates. A blinded
judge finding the provenance-episode material substantially better is evidence *about the episode
map*, obtained without using the episode map. It does **not** license folding injected candidates
back into any retrieval metric — P76 §2.2's exclusion rule stands, because the objection there was
that the *ranker* was told the answer, not that the answer was wrong.

**(c) A data-quality defect that costs retrieval accuracy for free.** **59 of 251** learning
points have a catalogue `depths.short.summary` that is **truncated mid-sentence, ending in
`...`**. P76 §3.2 measured `title + short.summary` as the **best-performing query construction**
(26.3% R@1, against 16.1% for title alone) — so **23.5% of learning points are querying the
corpus with a truncated version of the single most valuable field they have.** This was found by
noticing that the operator's calibration document would have shown him less of a learning point
than the machine saw. Repairing the summaries is a catalogue edit with no model, no index and no
new dependency, and it belongs in P76 Phase 1 rather than here.

---

## 5.2 THE SEPARATING EXPERIMENT — run 2026-08-11, and it moves item 3 above

§5 item 3 called the 2.9 %–35.5 % spread an **upper bound**, because instance identity was
confounded with which courses each instance judged, and named the clean separation as *"the
single cheapest thing a follow-up should do"*. It was done. This section is the result.

**The design, in one line:** several independent instances judge the **same** items, so
instance-to-instance disagreement is measurable with item difficulty held constant by
construction.

### 5.2.1 What was run, and how it was sized

| | |
|---|---|
| **Arm A — identical items, original working conditions** | **20 learning points**, 2 drawn from each of the 10 course families A–J with a fixed seed and **no reference to any observed grade** — selecting on the outcome would manufacture the course effect being measured. **263 items.** Split into two panels of 10 LPs (**136** and **127** items) so each instance's workload matches the original run's **~127 per batch**; working conditions must match or the measurement is of a different thing. **8 fresh instances per panel = 16.** |
| **Arm B — the shortlist arm** | **6** of the same 20 LPs, pool deepened to the current pipeline's **top-40** (P76 Phase 3's stated shortlist depth), so *"pick the best 16"* is a real **16-of-40** selection and not a formality. **234 items**, two panels of 3 LPs, **5 instances per panel = 10.** |
| total | **26 fresh instances, 3,274 new judgements**, same model, same prompt file (`sha256 790bb029…`, byte-identical to the original run's) |
| plus | the **original 2026-08-11 label set re-entered as one more rater** on Arm A — legitimate because Arm A packets were **reproduced byte-identically** from `unblinding_key.json`, and the builder **exits 2** if any packet's key set differs from what the original instance actually answered |

Sizing: 8 instances × ~130 items is the point where the cluster bootstrap over learning
points (the unit of dependence) still resolves a judge sd of ~1.5 pp, while each instance's
load stays inside the original run's envelope. All CIs are 95 % cluster bootstrap over
learning points, 4,000 resamples.

### 5.2.2 The harness was proven able to return "inconsistent" FIRST

Thresholds and the scorer were written, hashed and recorded in `PRE-REGISTRATION.md`
**before a single instance was launched** (`answers/` was empty; the hashes are in that
file). The bands for graded and screening agreement are **deliberately the same numbers as
Gates 1 and 2 of §4.4**, so machine-vs-machine sits on the same ruler as machine-vs-human.

Eight synthetic answer sets, scored before any real answer existed:

| synthetic set | exit | QWK | κ (≥2) | judge sd | top-16 overlap | 1↔2 verdict |
|---|---|---|---|---|---|---|
| **identical instances** | 0 | **1.000** | 1.000 | 0.00 pp | **1.000** | n/a — no disagreement to locate |
| ±1 on ~35 % of items | 2 | 0.690 | 0.584 | 1.76 pp | 0.718 | CONFIRMED |
| **1↔2 flipped at random** | 2 | 0.730 | **0.218** | 0.00 pp | 0.644 | **CONFIRMED** |
| **2↔3 flipped at random** | 2 | 0.834 | 1.000 | 1.99 pp | 0.837 | **REFUTED** |
| **systematic harshness spread** | 2 | 0.465 | 0.290 | **30.07 pp** | 0.865 | CANNOT VERIFY |
| **independent random grades** | 0 | **−0.023** | −0.046 | 2.49 pp | **0.422** (chance 0.400) | — |
| one instance short of a full set | 0 | — | — | — | — | that instance **excluded and named** |
| only three instances | **2** | — | — | — | — | **CANNOT VERIFY**, `MIN_JUDGES=4` |

Four things this establishes that an untested harness could not. **It reports total
inconsistency as total inconsistency** (κ ≈ 0, overlap at chance). **It reports identity as
identity** (κ = 1.000, judge sd 0.00, overlap 1.000). **The boundary detector points where
the disagreement actually is** — it says CONFIRMED on a 1↔2-only perturbation and **REFUTED**
on a 2↔3-only one, which is the negative control without which §5 item 2's claim could not
be tested at all. And **fail-closed bites**: too few instances exits 2, an incomplete
instance is excluded rather than silently averaged, and a CI straddling a band edge returns
CANNOT VERIFY rather than the nearer band.

### 5.2.3 Result 1 — grade agreement between instances, on identical items

Arm A, 16 fresh instances, 20 learning points, 263 items, 56 instance pairs:

| statistic | value | 95 % CI | verdict vs the pre-registered band |
|---|---|---|---|
| **quadratic-weighted κ**, mean over pairs | **0.915** | [0.882, 0.941] | **GRADED-USABLE** (≥ 0.60) |
| **Cohen's κ on `grade ≥ 2`** (the screening decision) | **0.873** | [0.823, 0.916] | **PASS** (≥ 0.45) |
| Krippendorff's α, interval metric | **0.921** | [0.887, 0.947] | above Krippendorff's own **0.800 "firm conclusions"** bar (P77 §3.5) |
| exact agreement | 0.893 | [0.866, 0.923] | — |
| **agreement within one grade** | **1.0000** | [1.000, 1.000] | — |

Arm B agrees: κ_w **0.902** [0.831, 0.927], κ(≥2) 0.854, α 0.911.

**Across all 9,586 paired comparisons in both arms, not one pair ever differed by more than
a single grade.** No instance called a passage 3 that another called 1 or 0. The 4×4
confusion matrix is strictly tri-diagonal.

Per-instance grade-3 rates on identical items: **15.4 %–21.3 %** on panel A1 and
**15.8 %–17.3 %** on panel A2 — against the 2.9 %–35.5 % that instance identity was blamed
for.

**And the label set actually in hand is reproducible.** Entering the original run's own
judgements as an extra rater gives κ_w **0.897** [0.860, 0.923] over 18 raters. Original-
versus-fresh pairs average κ_w **0.833** (range 0.765–0.901) against **0.915** (0.845–0.970)
for fresh-versus-fresh — slightly lower, which is expected, because the original instance
answered the identical *items* inside a different *batch* and so had different context. It
is a real gap and it is small.

### 5.2.4 Result 2 — how much of the 2.9 %–35.5 % spread was the judge

| | |
|---|---|
| observed between-batch sd of grade-3 rate (§5 item 3) | **7.8 pp**, range width **32.6 pp** |
| **judge-only sd, measured on identical items** | **1.53 pp**, 95 % CI **[0.80, 3.63]** |
| **judge share of the between-batch VARIANCE** | **3.8 %**, 95 % CI **[1.1 %, 21.6 %]** |
| content share — which learning points a batch contained | **96.2 %**, 95 % CI [78.4 %, 98.9 %] |
| implied content-only between-batch sd | **7.65 pp** |
| **range a judge-only effect would produce across 26 batches** | **6.0 pp**, CI [3.2, 14.4] — against the observed **32.6 pp** |

**The twelvefold spread was the courses.** Roughly 6 pp of the 32.6 pp range is attributable
to which instance judged; the other ~27 pp is which learning points it was handed. Some
courses genuinely have no good passage in the corpus for their learning points, and that —
not judge temperament — is what the spread was measuring.

Entering the original label set as an extra rater raises the judge sd to 1.78 pp (share
5.2 %), which is the more conservative of the two and still small.

**The replacement warning, narrower than the one it replaces:** *absolute grade rates from
this set carry a judge term of about ±1.5 pp on a batch of ~130 judgements. That is small
enough to quote a rate with, and far too small to explain a difference of tens of points
between courses. A large difference between two batches is a statement about their
learning points.*

### 5.2.5 Result 3 — where the disagreement actually is

Of **9,586** paired comparisons, **1,047 (10.9 %)** disagree. Their composition:

| boundary | share of all disagreement |
|---|---|
| 0 ↔ 1 (irrelevant vs related) | **18.5 %** |
| **1 ↔ 2 (related vs relevant)** | **57.7 %** |
| 2 ↔ 3 (relevant vs the passage) | 23.8 % |
| more than one grade apart | **0.0 %** |

Pairwise discordance at each cut, Arm A pooled: **1.56 %** at `≥1`, **6.17 %** at `≥2`,
**2.94 %** at `≥3`. The `≥2` cut exceeds `≥1` by **+4.61 pp** [2.04, 7.20] and `≥3` by
**+3.24 pp** [0.05, 6.23] — **CONFIRMED**, but the second leg only barely, and it is
**CANNOT VERIFY** on panel A1 alone and on Arm B alone.

**So §5 item 2 is half right and should be quoted at that strength.** The 1↔2 boundary
**is** where most disagreement lives — 57.7 %, more than the other two boundaries combined
— and that is the boundary a shortlist turns on, exactly as claimed. But *"carries **all**
the difficulty"* is too strong: 23.8 % of disagreement is at 2↔3, and on the deep Arm B
pools the 1↔2 cut is not separably worse than 0↔1. **§5 item 1's claim that the floor is
grade 1 also needs qualifying**: grade 0 is used, and used consistently — the `≥1` cut is
the *least* contested of the three — but its rate is strongly LP-dependent (0.7 %–3.7 % on
one panel, 7.9 %–11.8 % on the other), which is the same content effect as §5.2.4.

### 5.2.6 Result 4 — the decisive one: does any of this reach the 16-slot shortlist?

The product is a **shortlist**, not a grade. Grade disagreement that does not move a
candidate out of the top 16 costs an author nothing. Arm B measures this directly: each
instance picks its best 16 from a real pool of 40.

**A defect in the pre-registered statistic, found in the data and reported rather than
absorbed.** On 4 of the 6 Arm B learning points an instance grades **fewer than 16**
candidates at ≥ 2. Its top 16 is therefore *"everything I thought was worth a human's time,
plus grade-1 filler"*, and the filler is chosen by a tie-break that is deliberately
judge-independent (so that identical grade vectors give identical shortlists — the property
that makes the `identical instances` red-proof row mean anything). Two instances then agree
on the filler **for free**. A statistic that is partly free agreement is the *asserts less
than it looks* shape, so it is reported four ways:

| statistic | value | 95 % CI | reading |
|---|---|---|---|
| **S-A, as pre-registered** (shared tie-break) | **0.852** | [0.824, 0.881] | **STABLE** (band ≥ 0.69) |
| S-A with a **judge-specific** tie-break (ties pay chance) | 0.769 | [0.680, 0.845] | **CANNOT VERIFY** — the lower bound straddles the 0.69 edge |
| **marginal-preserving null** — each instance keeps its own grade profile, grades shuffled across candidates | **0.462** | [0.415, 0.531] | the honest floor for this data; it is **not** 16/40 = 0.400 |
| **Jaccard of the `grade ≥ 2` sets** — tie-break free | **0.813** | [0.714, 0.902] | the statistic with neither artefact |
| Jaccard of the `grade = 3` sets | 0.682 | [0.404, 0.950] | see below |
| **S-B — recall of one instance's grade-3 items inside another's top 16** | **1.000** | [1.000, 1.000] | **CARRIES-BEST** |
| S-C — same single best candidate | 0.767 / 1.000 by panel | — | reported, not a gate |

Arm A at the matching selection fraction (top 5 of 14, f = 0.36 against production's
16/40 = 0.40) agrees over 20 learning points: overlap **0.878** [0.844, 0.911], judge-specific
tie-break 0.801, null 0.413, Jaccard(≥2) **0.868** [0.814, 0.912].

**The number that matters, and its benchmark.** Two independent instances agree on **81 %**
of the set they call *worth a human's time*, tie-break free. P77 §3.5 records the human
comparator: Voorhees' TREC assessors overlapped at **Jaccard ≈ 0.30** on the relevant set,
and system rankings survived at τ ≈ 0.94 anyway. **These machine instances agree with each
other about 2.7× as closely as human assessors agreed with each other**, on the statistic
the human number was measured with.

**S-B's honest limit.** It came back at exactly 1.000, and its headroom is real: instances
find only 0–4 grade-3s per 40-candidate pool, and 16 slots is a lot of room. It is not
guaranteed — the red proof drove it to 0.846, 0.772 and 0.413 on the noisy, harshness-spread
and random sets — but a ceiling reached this easily should be read as *"no instance ever
pushed another's best passage out of a 16-slot list"* and not as a tight bound.

**And the one place set agreement does NOT hold: the single pick.** The grade-3 sets overlap
at Jaccard 0.682 with a CI of **[0.404, 0.950]** — too wide to act on — and per learning
point the values are **0.85, 0.25, 1.00, 1.00, 0.85, 0.14**. On two of six, independent
instances barely agree about *which* passage is *the* passage, while still agreeing about
which 16 are worth reading. That is §3.1's operational reading, now measured rather than
argued: **build the shortlist by machine, do not let the machine make the pick.**

### 5.2.7 What this experiment CANNOT establish

- **It measures reliability, not validity.** A machine judge audited machine judges. Every
  number above says *the instances agree with each other*; not one says *they are right*.
  **Only the operator's §4 calibration set can speak to validity**, and nothing here reduces
  the need for it — if anything §5.2.3 sharpens it, because agreement this high means
  §4's gates will be measuring the model's *bias*, which is the quantity a single instance
  cannot see in itself.
- **Every instance is the same model.** This is stochastic self-consistency, not judge
  independence. A systematic error shared by all instances of `claude-opus-5` is invisible
  here **by construction**, and κ_w = 0.915 is exactly what a shared systematic bias would
  also look like.
- **Arm B is 6 learning points.** The shortlist CIs are wide and the grade-3 Jaccard CI is
  too wide to act on. Treat Arm B as a direct measurement of small n, not as an estimate
  over the catalogue.
- **The 26-batch partition was never recorded.** `silver_labels.json` carries no batch id —
  a real gap, since it is the one field that would have made this decomposition trivial. The
  decomposition anchors on the **reported** 7.8 pp. Reconstructions of the partition give
  6.2–7.0 pp, which would raise the judge share to at most ~6 % — still small, and the
  direction of the conclusion does not move.
- **Nothing here touches §2.3's excerpt bias.** Long windows are still judged on a fraction
  of their text, and all instances inherit that bias identically — which is precisely why
  agreeing about it proves nothing about it.
- **The per-panel run exits 2**, because the 1↔2-versus-2↔3 comparison straddles zero on 3
  of the 4 panels. That is the fail-closed rule working, not a failure of the experiment.

### 5.2.8 The bottom line for the authorised 16-per-LP production run

> **Machine shortlisting is reliable enough to hand an author. Machine picking is not.**
>
> Handing an author **16 candidates chosen by one instance** is safe: a differently-seeded
> instance would have chosen 81–85 % of the same set, would never have disagreed by more than
> one grade about any of them, and never once pushed the other's best passage off the list.
> The part that is **not** reliable is the last step — *which one of the 16* — where
> independent instances agree at Jaccard 0.68 with a CI spanning 0.40 to 0.95. **That step
> belongs to the author, and it is the same step §3.1 already reserved for the guilds on
> doctrinal grounds.** The reliability finding and the doctrinal finding land on the same
> boundary from opposite directions.

Artefacts, reproduction commands and the pre-registration hashes:
`~/dir/courses_v3/judge-consistency-2026-08-11/` (Appendix A). Counts and hashes only are
committed here, as `docs/reports/clip-judge-consistency-2026-08-11.json`, per §6.

---

## 6. Where each artefact may live — a rights constraint that changes the shape of the delivery

**`nwp/nwp` is publicly mirrored** to `github.com/rjzaar/nwp` (ADR-0039). The corpus is
`derivative-cleared-pending` and password-gated. Therefore:

| artefact | home | why |
|---|---|---|
| this proposal, the builder, the aggregator, the selector, the judging prompt | **`nwp/nwp`** | method and code; carries no corpus text |
| aggregate statistics, grade distribution, abstention counts, the thresholds | **`nwp/nwp`** | counts and hashes only |
| **the 3,309 labels with their rationales** | **`~/dir`, never committed here** | rationales quote passage fragments |
| **the calibration document** (excerpts the operator reads) | **`~/dir`, never committed here** | it is short excerpts of a password-gated corpus |

This is P77 §6.2's rule applied one level further out: *an evaluation record is ranks and hashes,
so it carries no corpus*. Here the record is **grades and hashes**. The rationales are the one
part that unavoidably quotes the corpus, which is precisely why they are the part that stays
behind — and it is a real cost, because the rationales are what make the labels interrogable, so
**a reviewer of this MR can check the method but cannot check the labels**. That limitation is
recorded rather than engineered around.

Human-facing excerpts are capped at **600 characters** per candidate, the estate's own bound.

---

## 7. What was deliberately NOT judged

- **The 176 catalogue `video:` windows were not used as truth, in any form.** The operator has
  stated he did not hand-pick the 112 non-default windows — *"It might have been an extra pass"* —
  and a separate investigation into their provenance had **posted no verdict on ops#348 or #349 at
  the time this was built**. They are therefore treated as **UNKNOWN provenance**. No window fed
  the judging, the selection, or any threshold. If the investigation later establishes them, they
  become an independent spine to check this set against — which is strictly better than having
  assumed it.
- **Window boundaries (P77's L3).** This set judges *whether a passage teaches the point*, never
  *whether its edges are right*. L3 is capped by an arithmetic unit mismatch (P77 §2.3) and
  belongs to a trimmer that does not exist.
- **The 46 `method: none` learning points were judged, but nothing was inferred about their
  provenance.** P77 §3.4 refuses to promote the 17 withheld lexical guesses to labels and this
  proposal does not either.
- **Doctrinal soundness and formation fit** — routed to the two abstentions.

---

## 8. Sequencing

| phase | work | blocked on |
|---|---|---|
| 0 | silver label set + blinding red-proof + aggregate report | — (**done**) |
| 1 | calibration document to the operator | phase 0 |
| **2** | **operator judges 30 LPs (~60–90 min); gates evaluated as written in §4.4** | **the operator** |
| 3 | if PASS: silver labels become P77's L1/L2 input; if PARTIAL: binary use only; if DISCARD: one `rm` | phase 2 |
| 4 | re-judge against the shared deep pool when it lands, and re-run the same gates | the pool |
| 5 | G1 (the 112 windows) **only if** the provenance investigation admits them | that verdict |

**Phase 2 is a decision point, not a formality.** Every outcome including DISCARD is written down
in advance, which is the only thing that makes the other outcomes mean anything.

**§5.2 does not move phase 2 and must not be read as doing so.** The separating experiment
shows the instances are consistent *with each other*; it says nothing about whether they are
right. If anything it raises the value of the operator's 60–90 minutes, because at κ_w = 0.915
between instances, the residual risk is a bias **shared by every instance**, and a shared bias
is exactly what a human comparator — and only a human comparator — can see.

---

## Appendix A — reproduction

The prototype that produced everything above ran from a scratch directory and, following P77
§10's precedent, **is not proposed for merge as-is** — it is measurement code, not a `pl` verb,
and the standing order says the eventual home is a verb (the `clip silver` subverb, alongside P77's
proposed `clip eval`). It is kept, with the label set, at:

```
~/dir/courses_v3/silver-labels-2026-08-11/
    MANIFEST.json          label_class, judge model, prompt sha256, blinding contract,
                           residual gaps, input hashes, discard procedure
    JUDGE-PROMPT.md        THE METHOD — the verbatim instruction given to every judge
    silver_labels.json     3,309 judgements with rationales   <- corpus-derived, stays here
    unblinding_key.json    rank / ranker / episode / score, joined only after judging
    calibration_set.json   the 30 LPs, their strata, and the machine's own answers
    build_packets.py       blinding + uniform excerpt sampling + the structural leak check
    aggregate.py           fail-closed aggregation (missing = CANNOT VERIFY, never 0)
    select_calibration.py  the stratified selection
    render_calibration.py  the operator document
    score_calibration.py   the four gates
    redproof/*.json        the six adversarial answer sets of §4.4.1

~/dir/courses_v3/reports/CALIBRATION-SET.md      <- the operator works through this
~/dir/courses_v3/reports/answers-template.json
```

The §5.2 separating experiment is a sibling directory, same rights constraint:

```
~/dir/courses_v3/judge-consistency-2026-08-11/
    PRE-REGISTRATION.md    thresholds + scorer hashes + the red-proof table, recorded
                           with answers/ EMPTY, before any instance was launched
    THRESHOLDS.md          the bands, and why each one is where it is
    JUDGE-PROMPT.md        byte-identical to the silver run's (sha256 790bb029…)
    build_consistency_packets.py   Arm A reproduced from unblinding_key.json (exits 2
                           on any key-set mismatch); Arm B deepened to top-40
    render_panel.py        the packet a judge instance reads
    packets/panel_*.{json,md}      2 Arm A panels + 2 Arm B panels
    answers/*.jsonl        26 fresh instances, 3,274 judgements  <- corpus-derived, stays here
    make_redproof.py · run_redproof.sh · redproof/
                           the 8 adversarial sets of §5.2.2, and the driver that
                           scores all 8 in one pass
    analyse.py             the pre-registered scorer (fail-closed; exit 2 CANNOT VERIFY)
    analyse_pooled.py      pooling + the variance decomposition (defines no new band)
    shortlist_null.py      the tie-break null and the tie-break-free Jaccards of §5.2.6
    result_*.json · shortlist_null_*.json
```

**Re-running §5.2:**

```
cd ~/dir/courses_v3/judge-consistency-2026-08-11
BOOT=1200 bash run_redproof.sh                     # the 8 rows of §5.2.2
python3 analyse.py answers --boot=4000             # per panel; exit 2 (Q3 straddles) is expected
python3 analyse_pooled.py answers --arm=A           # §5.2.3 and §5.2.4
python3 shortlist_null.py answers --arm=B --k=16    # §5.2.6
```

Committed to `nwp/nwp` by this MR: **this proposal**,
`docs/reports/clip-silver-labels-2026-08-11.json`, and
`docs/reports/clip-judge-consistency-2026-08-11.json` — counts, coefficients, hashes and gate
status only, with no rationale, no excerpt and no `preview` field, per §6.

**Re-running the red proof:**

```
cd ~/dir/courses_v3/silver-labels-2026-08-11
python3 score_calibration.py redproof/controls_broken.json   # expect exit 1, Gate 4 DISCARD
python3 score_calibration.py redproof/offset.json            # expect exit 2, CANNOT VERIFY
python3 score_calibration.py redproof/perfect.json           # expect exit 0
```

**Scoring the real answers, when they exist:**

```
python3 score_calibration.py ~/dir/courses_v3/reports/answers.json
```

## Appendix B — what this session did NOT do

- **No GPU inference and no index build.** A separate agent owns that work and is building a
  shared deep pool at `~/clip-pool/` on the estate GPU build host; it did not exist when this
  ran. The only remote action taken here was a read-only copy of the already-existing P76
  pilot artefacts.
- **No corpus text left the estate's own machines**, and nothing was written to `~/dir`'s
  build outputs, the catalogue, or any live tier.
- **No `video:` block was read as truth, edited, or inferred from** (§7).
- **No GPU work and no contention with the indexing agent** in the §5.2 follow-up either: it
  is CPU-only, local-only, and read-only against `~/dir`. `pl server health --all` was run as
  the standing preflight and returned HEALTHY on all three hosts; no remote host was touched.
- **No claim that the current ranker is bad or that the hybrid is good.** §2.3's comparison is
  silver-labelled, single-judge, and un-calibrated until §4 runs. It is a hypothesis with a
  number attached, which is more than existed yesterday and less than a result.
