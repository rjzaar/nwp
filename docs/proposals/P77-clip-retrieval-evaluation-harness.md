# P77 — Measuring clip retrieval: an evaluation harness, so a ranking change can be judged instead of argued about

**Status:** PROPOSED — research and design only. No production code, no schema change, no
golden shipped with this document. Every snippet below is illustrative.
**Created:** 2026-08-11
**Owner:** *(unassigned)*
**Issue:** [nwp/ops#348](https://git.nwpcode.org/nwp/ops/-/issues/348) · decisions D1–D4 live there
**Predecessors:** [P75](P75-clip-catalogue-triage-and-guild-workflow.md) (the triage this measures) ·
[P64](P64-clip-choice-as-data-not-content.md) (clip choice as data) ·
[P69](P69-fix-engine-bakeoff.md) (the estate's precedent for *"same battery, same rig, same
metrics, chronicled as it happens"*) · ADR-0027 (unified course content)
**Related:** [nwp/ops#337](https://git.nwpcode.org/nwp/ops/-/issues/337) (P75) ·
[nwp/ops#338](https://git.nwpcode.org/nwp/ops/-/issues/338) (`~/dir` has no forge home, no CI)

**Evidence base — every number below was computed today (2026-08-11) from these files:**

| file | what was read |
|---|---|
| `~/dir/courses_v3/build/lp_episode_map.json` | 251 learning points, 205 with an episode attribution |
| `~/dir/courses_v3/catalog/*.yaml` | 61 files, 56 courses, 176 `video:` blocks |
| `~/dir/courses_v3/build/_runs_v3.json` (`c22dfbd`) | the **after** ranker — 9,353 candidates |
| `~/dir` `git show e89079f:courses_v3/build/_runs_v3.json` | the **before** ranker — 8,626 candidates |
| `~/dir/courses_v3/history/corpus_v2/_runs.json` | inspected and **ruled out** — see §1.6 |
| `.../nwc_features/nwc_guild/config/install/guilds/media-guild.yml` | `time_range_iou:0.7` |

Reproduction commands for every figure are in Appendix A. **Nothing here is an estimate unless
it says "estimate".** Where the literature is cited, the claim is attributed; where the estate is
measured, the command is given.

**One honesty note about the research, in the spirit of the document.** Three literature passes were
run and all three returned. Where a source could not be obtained or a widely-repeated figure did not
survive checking, **the figure is not quoted and is listed at the end of Appendix B** with the reason
— six of them, including two cases where the folklore version of a number is materially wrong (MTC's
"under three hours" is 15 annotator-hours across six people; statAP's "4% of the pool" appears only in
an abstract, its experiments reporting 1.7% and 11.5%). Only §4.5's two adaptive-analysis sources
retain a partial caveat, marked in place.

**And one correction this pass forced on the document itself.** An earlier draft reported the
minimum detectable effect from a computation that is effectively **50% power**, giving "+10 items at
S@8"; the properly powered figure is **+18** (§3.2). The smaller number was the flattering one. It is
recorded rather than quietly replaced, because publishing a resolution more optimistic than the
instrument's is the exact error §0 describes.

---

## 0. The finding that reframes the problem

The estate improved sibling separation from **193 → 127 of 251** learning points, saw top-1
episode accuracy move **21 → 22 of 205**, and concluded: *separation improved, correctness did
not.*

**That conclusion is wrong.** Re-measuring the same two artefacts with a paired test:

| metric | before (`e89079f`) | after (`c22dfbd`) | Δ | discordant pairs | exact McNemar *p* |
|---|---|---|---|---|---|
| S@1 — right episode at rank 1 | 21/205 (10.2%) | 22/205 (10.7%) | +1 | 7 better, 6 worse | **1.000** |
| S@5 | 59/205 (28.8%) | 60/205 (29.3%) | +1 | 15 better, 14 worse | **1.000** |
| S@8 — what a reviewer actually sees | 87/205 (42.4%) | 87/205 (42.4%) | 0 | 20 better, 20 worse | **1.000** |
| **S@40 — is it in the pool at all** | **149/205 (72.7%)** | **167/205 (81.5%)** | **+18** | 24 better, 6 worse | **0.0014** |
| MRR | 0.206 | 0.211 | +0.005 | — | — |
| *(proxy)* LPs sharing a top with a sibling | 193 | 127 | −66 | — | — |

Three things follow, and they are the whole reason this document exists.

**First, `21 → 22` is seven learning points improved and six degraded.** It is a coin landing
heads once. A 95% paired bootstrap CI on that delta is **[−2.9 pp, +3.9 pp]** (10,000 resamples).
The estate read a point estimate as a verdict.

**Second, the change actually worked — on an axis nobody measured.** It put the right episode
*into the candidate pool* for 18 more learning points, and that is significant at *p* = 0.0014
with a bootstrap CI of **[+3.9 pp, +14.1 pp]**. A genuine, sizeable, statistically solid win was
filed as a disappointment because the only metric anyone looked at was the one the change was
least able to move.

**Third, `21 → 22` was never readable in the first place.** At n = 205 with the observed
discordance rates, the smallest improvement that could *even reach* α = 0.05 is **+9 to +14
learning points**, and the smallest **reliably detectable at 80% power is +10 to +18** (§3.2).
Asking whether +1 meant anything was asking a question the instrument cannot answer — and the
failure was not that the answer came back "no", it was that nobody knew the instrument's
resolution before reading the dial. (S@40's +18 clears even the 80%-power bar of +15, which is why
the recall finding is safe to act on.)

> **This is not a criticism of the ranking work.** The separation fix is well-engineered and
> red-then-green proven (`~/dir` `c22dfbd` quotes five failing assertions before the fix). The
> defect is that the estate had **proxies and no correctness measurement**, so it could not tell a
> recall win from a null result. That is a missing instrument, and this proposal is the instrument.

---

## 1. What the existing labels can prove, and what they cannot

### 1.1 The "205" is four different label sets wearing one number

`lp_episode_map.json` records a `method` (provenance 195 / sibling-inference 10 / none 46) and a
`confidence`. Those two fields hide the distinction that actually matters for evaluation. Parsing
the `evidence:` prose splits the 251 into six classes:

| class | n | evidence shape | independent of the artefact under test? |
|---|---|---|---|
| **P1** | **133** | `recorded clip in depths.standard.video (episode N); inline citation "Ep N" agrees` | **partly** — two witnesses that agree |
| **P2** | **43** | `recorded clip in depths.standard.video (episode N)` | **no** — the label *is* the clip |
| **P3** | **19** | `author citation in prose: "Ep N"` (no clip exists) | **yes** — written for another purpose |
| **S** | **10** | `all sibling LPs in course JN source from Ep N; … verify before publishing` | **no** — inferred |
| N1 | 29 | retreat-sourced; audio is not a DIR episode at all | n/a — **not answerable** |
| N2 | 17 | unresolved; a TF-IDF guess was computed and **deliberately withheld** | n/a |

Two observations about this table that are worth more than the counts.

**P2 is a clip grading itself.** Forty-three of the 205 labels say nothing except *"the episode is
the one the existing clip points at"*. Using them to score a ranker asks the ranker to reproduce
the artefact P75 exists because it is wrong. Measured separately, P2's S@1 is 4/43 (9.3%) against
P1's 17/133 (12.8%) — the difference is not significant at this n, but the *epistemic* status is
categorically different and should never be averaged into one figure silently.

**N2 is the estate's fail-closed doctrine already applied to labels, by someone else, before this
proposal existed.** Seventeen entries record a computed lexical best guess and then refuse to
assign it, in words: *"UNVERIFIED lexical guess, ~N–N% reliability — not assigned"*. That is
exactly the rule §5 asks the harness to follow, and it is already the map's behaviour. The
harness must not undo it by quietly promoting those guesses to truth.

**Recommendation (ops#348 D1): the primary label set is P1 + P3, n = 152.** P2 and S are computed
and reported beside it, never folded in. The measured cost of that choice is small and the
measured benefit is that the number means something:

| set | n | S@1 | S@5 | S@8 | S@40 | MRR |
|---|---|---|---|---|---|---|
| all labelled | 205 | 22 (10.7%) | 60 (29.3%) | 87 (42.4%) | 167 (81.5%) | 0.211 |
| **P1+P3 (primary)** | **152** | **18 (11.8%)** | **45 (29.6%)** | **66 (43.4%)** | **126 (82.9%)** | **0.218** |
| P2 (contaminated) | 43 | 4 (9.3%) | 15 (34.9%) | 18 (41.9%) | 34 (79.1%) | 0.217 |
| P3 only (clean, tiny) | 19 | 1 (5.3%) | 3 (15.8%) | 6 (31.6%) | 15 (78.9%) | 0.132 |
| S (self-flagged unverified) | 10 | 0 (0.0%) | 0 (0.0%) | 3 (30.0%) | 7 (70.0%) | 0.073 |

### 1.2 The labels are multi-gold, and the convention swings the score more than the sample size does

**90 of the 205** labelled learning points name **more than one** episode in their evidence:

```
episodes named per LP:   1 -> 115    2 -> 71    3 -> 16    4 -> 3
```

Thirteen say so explicitly (`primary of [597, 500, 558]`); seventy-seven carry a multi-episode
inline citation (`"Ep 16, 192"`). Treating only the primary as correct scores a candidate drawn
from a *second episode the author also cited* as a miss.

| | STRICT (primary only) | LENIENT (any named) | swing |
|---|---|---|---|
| S@1 | 22/205 (10.7%) | 27/205 (13.2%) | +2.4 pp |
| S@5 | 60/205 (29.3%) | 77/205 (37.6%) | +8.3 pp |
| **S@8** | **87/205 (42.4%)** | **104/205 (50.7%)** | **+8.3 pp** |
| S@40 | 167/205 (81.5%) | 178/205 (86.8%) | +5.3 pp |

**The definitional swing (±8.3 pp) is roughly twice the statistical resolution of the sample
(±4 pp).** A single headline accuracy figure for this corpus is therefore a *choice* presented as
a *measurement*, and the choice is worth more than the evidence. It also changes the verdict's
shape on the very change in §0:

| | STRICT | LENIENT |
|---|---|---|
| S@8 before → after | 87 → 87 (*p* = 1.000) | 95 → 104 (*p* = 0.233) |
| S@40 before → after | 149 → 167 (*p* = 0.0014) | 161 → 178 (*p* = 0.0005) |

The *direction* is stable under both conventions — which is the reassuring part, and is the
standard robustness argument for label-convention sensitivity. The *magnitude* is not.

**Recommendation (ops#348 D2): report both, every run, side by side. Refuse to emit one alone.**

### 1.3 Episode truth and window truth are different label sets with different eligibility

The catalogue's 176 `video:` blocks are the only window-level signal that exists. **64 of them are
the byte-identical default `0:00–8:00`** — measured, and P75 §5.1 already argues from the same
figure that they are evidence of *non-selection*. That leaves **112 real human window choices**.

But an author who defaulted the *window* may still have chosen the *episode* deliberately, and
31 of the 64 defaults carry an independent prose citation agreeing with the episode (class P1):

| label class | real window | default `0:00–8:00` | no window at all | total |
|---|---|---|---|---|
| P1 | 102 | **31** | 0 | 133 |
| P2 | 10 | **33** | 0 | 43 |
| P3 | 0 | 0 | 19 | 19 |
| S | 0 | 0 | 10 | 10 |
| N | 0 | 0 | 46 | 46 |
| **total** | **112** | **64** | **75** | **251** |

So the two evaluation sets are **not nested and not interchangeable**:

- **Episode set** = 205 (primary 152), which *includes* 64 learning points whose windows are
  inadmissible.
- **Window set** = 112, which *excludes* every default and every learning point with no clip.

Mixing them is not a hypothetical error — it inflates the score measurably. Scored naively over
all 176 windows the ranker's mIoU is **0.023**; over the 112 real ones it is **0.013**, and over
the 64 defaults alone it is **0.039**. **The non-selections score highest.** They start at
`0:00`, and so do plenty of candidates.

### 1.4 What the 205 can and cannot support — stated precisely

**CAN support** (these are claims the label set is competent to settle):

1. *Did the ranker place a candidate from the attributed episode at rank ≤ k?* Binary, per learning
   point, over 205 (primary 152). This is the harness's spine.
2. *Is the attributed episode in the candidate pool at all?* The recall ceiling. Measured: **38 of
   205 labelled learning points have zero candidates from their labelled episode in the top 40**,
   so S@k for k ≤ 40 is capped at 167/205 = 81.5% by pool construction, not by ranking.
3. *Did a change improve or degrade a given learning point?* Paired, per item — the discordant-pair
   counts in §0 — which is strictly more informative than the two aggregate rates.
4. *A lower bound on window quality*, over the 112, with all the caveats of §2.3.

**CANNOT support** (asking these of this label set produces a number that looks like an answer):

1. **"This clip is the best clip."** The label says *"an author cited this episode"*. It does not
   rank the 40 candidates and it does not claim the author's own clip was good — P75 measured that
   **172 of 175** live clips are not their learning point's top candidate and **66 overlap no
   candidate at all**. The label is **necessary, not sufficient**: right episode is a
   precondition for a right clip and nothing more.
2. **"Precision@k."** Precision needs every retrieved item judged. Nothing here judges the other
   39 candidates, and an unjudged candidate from a different episode may be perfectly good — the
   estate has **648 episodes** on the same handful of subjects and P75 measured **591 distinct
   episodes** across the candidate pool. Reporting precision would encode *"unjudged = wrong"*,
   which is the single best-documented bias in test-collection construction (§1.5).
3. **"nDCG."** Graded gain needs graded judgements. There are two grades available — *cited* and
   *not mentioned* — and the second is an absence of evidence, not a zero. See §2.2.
4. **Anything about the 46 unlabelled learning points.** 29 are retreat-sourced with no DIR
   episode to be right about; 17 are honestly unresolved. These are **CANNOT VERIFY**, and the
   harness must carry them as a third outcome, never as failures (§5.2).
5. **Anything about window boundaries above the arithmetic ceiling** — for **91 of the 112** real
   windows, no candidate in the right episode is geometrically capable of reaching IoU ≥ 0.7
   (§2.3).

### 1.5 What the retrieval-evaluation literature calls all of this

Four established bodies of work describe the estate's exact situation, and the third of them
supplies a rule this proposal adopts wholesale.

**(a) The formal name for "right episode, unknown right window" is a *bag-level* label.** This is
**multiple-instance learning** [B1]: a *bag* (the episode) is positive iff at least one *instance*
(a window) inside it is positive. MIL's known and long-standing limitation is precisely the one
that matters here — bag-level predictions are accurate while **instance-level predictions remain
weak**, because the label was never adjudicated at instance granularity. The label-provenance name
for the same thing is **distant supervision** [B2], and in retrieval and NLP the general term for a
machine-derived label is **silver**, opposed to human-adjudicated **gold** [B3]. The governing
convention in that literature is *train on silver, evaluate on gold* — silver labels support model
fitting, not verdicts.

**(b) TREC Deep Learning transfers labels between granularities in one direction only, and says
so.** The 2019 overview states the operation and its assumption outright [B4]:

> *"we **transferred the passage-level label to the corresponding source document that contained
> the passage**. We do this **under the assumption that a document with a relevant passage is a
> relevant document**…"*

That is **fine → coarse**, and it is *sufficient*: one relevant passage does imply a relevant
document. **The opposite direction — document label ⟹ passage label — is the necessary-but-not-
sufficient one, and TREC DL deliberately does not do it.** Instead NIST assessors were paid for
*separate* passage-level and document-level graded judgements, on two different 4-point scales.

**This is the single most directly applicable finding in the literature, and it settles §1.4.**
The estate's episode label is a document-level label; the thing being retrieved is a passage. So:

> **L1 (episode) is a legitimate bag-level metric. It licenses no claim whatever about which
> window inside the episode is right.** Any window claim must come from the window labels (the 112)
> and be scored separately — which is why §2.5 has three levels rather than one composite.

Buckley & Voorhees' design rationale for `bpref` generalises the same discipline into a rule the
harness follows [B5]: **build the metric only out of comparisons the labels can actually settle,
and out of nothing else.** `bpref` compares a judged-relevant document against a judged-non-relevant
one and lets unjudged documents move nothing. The analogue here: score *in-episode vs out-of-episode*
(which the label settles) and **refuse to score within-episode ordering against an episode label**
(which it does not).

**(c) Pooling bias is small in the direction the pool was built and unbounded outside it.** Zobel's
leave-out-uniques test [B6] measured the advantage a system gets from having contributed to the
pool: **0.5%** average on TREC-5 at depth 100, **2.2%** on TREC-3, rising to **2.3% / 14%** at
depth 10, and to **7% / 19%** on the ten queries with the most answers. Later collections are
worse: **9.6% mean and 45.5% max** on TREC 2004 Terabyte [B7]. Zobel also measured that recall is
badly overestimated — extrapolating, *"at best **50%–70% of the relevant documents have been
found**; … **measures based on recall are highly uncertain**."*

Buckley et al. [B7] then showed the bias is **qualitative, not merely small**: judged-relevant sets
skew toward documents containing topic **title** words (`titlestat_rel` **0.719** on AQUAINT vs
0.588 on Disks 4&5 over the same topics, higher on 48 of 50 topics, *p* = 6.25 × 10⁻¹⁰), so the
collections *"are fine for comparing title-word-emphasizing retrieval techniques. **Problems will
arise for other types of runs that do not have a title word emphasis**."*

**That warning lands directly on this estate.** The candidate pool is built by one rubric, and
`~/dir` `c22dfbd` has just changed how learning-point terms are derived. A future ranker that
works differently will retrieve candidates this pool never contained — and **38 of 205 learning
points already have no candidate from their labelled episode in the top 40**, so the hole is
measured, not hypothetical. Two mitigations from the same literature are adopted in §3.4 and §5.2:
report **success@40 (pool recall) separately from success@8 (ranking)** so a pool change cannot
hide inside a ranking number; and prefer **pooled judgements over the union of the systems being
compared** rather than a fixed list.

**(d) Sparse silver labels discriminate coarsely and fail exactly where systems are close.** MS
MARCO is the canonical case and its own paper declares the defect [B8]: editors *"were **not
required to annotate every passage**… this annotation should be considered as **incomplete**"*. In
the dev set, **94% of queries have exactly one known relevant passage** [B9]. Then Arabzadeh,
Vtyurina, Yan & Clarke measured what that costs [B10] — crowdworkers making *preference*
judgements over all 6,980 dev queries:

- When the neural ranker's top result disagreed with the qrel, the crowd **preferred the ranker's
  passage 2,996 times to the qrel's 2,116** — i.e. the label loses its own dispute ~59% of the time.
- Under preference qrels built from a shallow pool, the **original qrels win only 46.6%** of their
  pairings while the pooled preference qrels win **91.8%**.
- A hypothetical system scoring **MRR@10 = 1.0** against official qrels scores **0.3320** against
  preference qrels — real rankers beat "perfect".
- Kendall's τ between the two orderings is **0.65**, and *"at the top rungs of the leaderboard, the
  relative order of the runs changes dramatically."*

The independent counterweight [B11] found the same sparsity (94.4%, no negative labels at all) but
a calmer conclusion: extrapolating extra relevant passages raised absolute scores while system
**orderings stayed resilient (top-weighted τ > 0.9 even at d = 20)**. **The two results are not in
conflict and together they are the estate's operating rule:** sparse derived labels are reliable
for separating clearly different systems and unreliable for separating close ones — which is
exactly the regime `21 → 22` sat in.

BEIR [B12] standardised nDCG@10 across 18 datasets whose average relevant-documents-per-query
ranges from **1.0 (ArguAna) to 493.5 (TREC-COVID)**, and states the pooling premise plainly:
*"**All other unseen documents are assumed to be irrelevant.**"* Notably, its own Limitations
section lists English-only, short documents and single-field indexing — **it does not list label
sparsity**, which is itself worth remembering when a benchmark number is quoted.

**Why this proposal does not adopt `bpref` or condensed lists.** Both are the standard answers to
incompleteness — `bpref`'s absolute value stays stable as judgements are removed, correlating with
MAP at τ ≈ 0.93 under complete judgements and holding τ > 0.9 down to 25–50% of qrels [B5]; Sakai
showed graded relevance on **condensed lists** (delete unjudged, then score) is more robust still
[B13]. Neither fits here: both are designed for *many* relevant documents per topic, and this
corpus has **one episode per learning point** with the "unjudged" set being 39 of 40 candidates.
Condensed lists would additionally make a ranker that retrieves nothing but unjudged candidates
indistinguishable from a correct one. **success@k with an explicitly reported CANNOT-VERIFY count
is the honest form of the same idea at this scale** — and it is why §5.2 forbids scoring an
unmeasurable item as a miss.

**And the estate should expect its own labels to lose disputes.** P75 measured that **172 of 175**
live clips are not their learning point's top candidate and **66 overlap no candidate at all**.
Arabzadeh et al.'s recommendation for exactly this situation — *maintain the "right answer" by
ongoing comparative judgements rather than fixing it once at collection time* — is what §3.4's
G2 tranche is, and their measured cost (**500 queries, mean pool 6.32, $1,022**) is why it is
affordable at this estate's scale (607 judgements).

### 1.6 One artefact that looked usable and is not

`~/dir/courses_v3/history/corpus_v2/_runs.json` is keyed by **podcast-topic slug** across 12 topic
files (`01-foundations-of-prayer/what-is-prayer`, …), not by learning point. It predates the
ops#336 re-keying and has **no join to the 251 learning points**. It is therefore **not a second
ranker for comparison purposes** and the harness must refuse to load it rather than key-match by
name and quietly evaluate 1,414 candidates against the wrong questions. Recorded here so the next
session does not spend the hour rediscovering it.

The real "before" artefact is the tracked previous revision of the same file
(`git show e89079f:courses_v3/build/_runs_v3.json`), which is what §0 uses.

---

## 2. Metric selection

### 2.1 The task, stated so a metric can be chosen for it

> One learning point (a title plus ~100 words of prose). One right episode, known for 205 of 251.
> One right window inside it, **unknown** — 112 human windows exist and are themselves soft.
> 40 candidates are ranked. **8** are shown to a human, who picks one.
> There is exactly one slot to fill. There is no "browse more results".

Four properties of that statement drive everything:

- **One relevant item per query** (or a small set) → rank-based single-target metrics, not
  set-based ones.
- **A hard cutoff at 8** → the operational metric is *success@8*, because a right answer at rank 9
  is worth exactly as much as one at rank 400.
- **Binary, incomplete, necessary-but-not-sufficient labels** → no precision, no graded gain.
- **The unit retrieved (a window) is finer than the unit labelled (an episode)** → the metric must
  be reported at more than one level, or it will conflate two different failures.

### 2.2 The metric set, and why each one is in or out

| metric | verdict | why |
|---|---|---|
| **success@k** (a.k.a. recall@k with one relevant item), k ∈ {1, 5, 8, 40} | **IN — primary** | Binary per learning point, so it is directly paired and directly testable. k = 8 is the product's real cutoff; k = 1 is what an automated pick would use; k = 40 is the recall ceiling and is what caught the §0 win. |
| **MRR** | **IN — secondary, reported never quoted alone** | Sensitive to movement anywhere in the list, so it registers progress that success@8 rounds away. But it is dominated by rank 1 (a move 40 → 9 is worth 0.09 of a rank-1 hit) and it is *unstable on this n*: it moved +0.005 in §0 on a change whose S@8 did not move at all. Useful as a tie-breaker, dangerous as a headline. |
| **success@k restricted to in-pool items** | **IN — diagnostic** | Separates *ranking* failure from *retrieval* failure. Measured: MRR is 0.211 overall but **0.259 among the 167 whose episode is in the pool at all**. Without this split, a pool change and a ranking change look identical. |
| **nDCG** | **OUT today · IN after G1** | Needs graded relevance. The only grades available *today* are "author cited it" and "author did not mention it", and the second is missing evidence, not grade 0. nDCG would also silently reward filling ranks 2–8 with more segments from the right episode — exactly the sibling-pooling defect P75 §4 is trying to remove. **A metric that rewards the known defect is worse than no metric.** But nDCG is the TREC Podcasts Track's primary metric [C10] over its graded PEGFB scale, and if §3.4's G1 tranche produces PEGFB grades then nDCG becomes the right headline and this row flips. Its normalisation is against an *ideal* gain vector [B14], so it is more sensitive to label incompleteness than success@k — which is why it must wait for real grades rather than being approximated from derived ones. |
| **MAP** | **OUT** | Averages precision over all relevant items. With one relevant episode per query MAP degenerates to MRR while looking more authoritative, and with multi-gold labels (§1.2) it would weight an author's second citation equally with the primary. |
| **precision@k** | **OUT** | See §1.4.2 — the labels cannot support it. |
| **R@k, IoU=m** (temporal) | **IN — reported, but not as the ranker's score** | §2.3. |
| **mIoU** | **IN — reported *only* beside a constant baseline** | §2.4 — on its own it is actively misleading here. |
| **IoP and IoG** (intersection over prediction / over ground truth) [C9] | **IN — always as a pair, never singly** | Precision and recall on the time axis, which tIoU conflates. Each is gameable in a known and opposite direction (IoP by a very short prediction, IoG by a very long one), so the pair is informative and either alone is not. Measured: the constant `0:00–8:00` scores IoG **0.412** by containing the gold window outright 42 times. |
| **midpoint containment@k** | **IN — the honest window metric today** | §2.3, and empirically the most annotator-stable criterion available: 82.7% of a span's centre survives independent re-annotation vs 72.5% IoU overall [C8]. |
| **dR@n,IoU@m** (de-biased) [C7] | **OUT for now — revisit if a trimmer ships** | Designed for exactly the over-long-prediction exploit measured in §2.4, and worth adopting the day a Stage B trimmer starts emitting variable-length windows. Today it would penalise the generator's fixed duration buckets, which is a known property, not a finding. |
| **rank-biased overlap** (RBO) between two rankers | **IN — as the "how much changed" number** | Label-free, so it is available on all 251 including the 46 CANNOT VERIFY, and it answers *"did anything happen"* separately from *"was it good"*. Measured for the §0 pair at p = 0.9 over the top 8, normalised to [0,1] by the attainable maximum `1 − p^k`: **mean 0.545, median 0.561**, with **21 of 251** learning points having an identical ordered top-8 and **9** disjoint. **The short-list trap is real and is named in the source** [D5]: *"if two search engines each only supply 7 results … and p = 0.9, then even if both results lists are identical, the base RBO score will only be 0.767."* Here the truncated maximum at k = 8 is **0.570**, so quoting the raw 0.310 as a [0,1] similarity would understate agreement by nearly half. **The harness should use the paper's own `RBO_EXT` (extrapolated) and report the residual as `RBO_EXT [RBO_MIN – RBO_MAX]`**; the naive normalisation used above is an approximation and is labelled as one. At p = 0.9 the top 10 ranks carry **86%** of the weight — close to this estate's 8-deep review cutoff, which is why p = 0.9 is the right setting here rather than a default. |

### 2.3 Temporal IoU: the right metric for the wrong stage

**The published analogue is exact.** *Video moment retrieval* / *temporal sentence grounding* is
"natural-language query → time span in a long recording", and it has a settled metric [C1–C4]:

```
tIoU(P, G)  = |P ∩ G| / |P ∪ G|                      (1-D intervals)

R@n, IoU@m  = fraction of queries for which AT LEAST ONE of the top-n predicted
              moments has tIoU > m                    [C5, Eq. 1]
```

with k ∈ {1, 5} and m ∈ {0.3, 0.5, 0.7} as the near-universal settings, plus **mIoU** (mean tIoU
of the top-1). QVHighlights [C4] adds COCO-style mAP averaged over IoU ∈ [0.5 : 0.05 : 0.95],
because a query there can have several disjoint gold moments. **So the guild's
`time_range_iou: 0.7` is the literature's strictest standard threshold**, and §7.3 uses exactly
this protocol.

**But the same literature is unusually candid that this metric is easy to fool, and the estate has
just reproduced its central result.** Otani et al. [C6] built three *blind* baselines that never
see the video, only the temporal prior of the training set. R@1 (IoU > 0.5):

| | Charades-STA | ActivityNet Captions |
|---|---|---|
| uniform random (no prior) | 10.77 | 13.57 |
| **Prior-Only Blind** | **22.9** | 10.8 |
| **Action-Aware Blind** | **28.3** | **23.1** |
| **Blind-TAN** (trained on queries alone) | **37.8** | **41.3** |
| 2D-TAN (sees the video) | 42.2 | 44.0 |

On ActivityNet the query-only Blind-TAN at **41.3 beats every published deep model in the
31.7–36.8 band.** Shuffling the video segments at inference left **67.9% of 2D-TAN's predictions
exactly unchanged.** Yuan et al. [C7] went further with **PredictAll** — *always return the whole
recording* — which scores **11.9% R@1 at IoU@0.7** on ActivityNet Captions, beating CTRL (5.2),
ACRN (5.1) and WSSL (6.4) **at the strictest threshold in common use**. Their diagnosis is
arithmetic: *"if the ground-truth moment is the whole video, any predictions with duration longer
than 0.3 can achieve R@1, IoU@0.3 = 1."* Their fix was a de-biased metric, **dR@n,IoU@m**, which
multiplies R@n,IoU@m by two normalised boundary-distance discounts so an over-long prediction that
squeaks past a low threshold is penalised.

> **§2.4 is this finding, measured on the estate's own data.** A constant `0:00–8:00` that never
> looks at the query scores mIoU **0.107** against the ranker's **0.013**. The estate did not read
> that in a paper and then look; it fell out of writing the anti-cheat register (§4.4). That the
> published literature predicts it is corroboration, not the source.

**The gold boundaries are soft, and there is published measurement of how soft.** This is the
finding that most changes what the estate should conclude from a low L3 score:

- **Human–human boundary agreement is ~72.5% IoU on Charades and 58.7% on MultiTHUMOS** [C8], with
  a median start error of **0.9 ± 0.8 s** against an end error of **1.4 ± 1.4 s** — the *end* of a
  span is the more contested edge. And: *"only **76.1% were over 50% IOU**"* — **roughly a quarter
  of independent human re-annotations would be scored WRONG at the standard IoU = 0.5 threshold.**
- **The centre is far more stable than the edges** [C8]: excluding the outer thirds raises human
  self-consistency from **72.5% to 79.8% IoU**, and *"**82.7% of the centre was covered by a
  subsequent annotator**."*
- DiDeMo [C2] quantised its videos into **5-second segments precisely because of this**: their
  measured annotator standard deviation on start/end points (**2.49 s** on 25–30 s videos) exceeded
  the difference between two annotation *tools* (2.45 s). Its acceptance rule requires 3 of 4
  annotators to agree, where agreement means *one of the start **or** end* differs by at most one
  segment — one-sided-tolerant by construction. Its published human upper bound is **Rank@1 =
  74.75, mIoU = 96.05** — *not* 100, and the paper says so: *"it is impossible to achieve 100% on
  all metrics."*
- Otani et al. [C6] re-collected 5 annotations per pair (11,440 annotations, 77 annotators) and
  scored **humans against the published ground truth**: a randomly chosen fresh annotator agrees at
  IoU > 0.5 only **42.8%** (Charades) / **35.4%** (ActivityNet) of the time — and on ActivityNet is
  *beaten by 2D-TAN*.

**Two consequences, both adopted.** First, **§3.4's G1 tranche (30 doubly-judged windows) is not
optional diligence — it is the only way to know whether an L3 number is measuring the ranker or
the annotators**, and the literature says the noise is large enough to matter. Second,
**centre-anchored containment is the empirically more stable criterion**, which is the published
justification for the midpoint metric §2.3 recommends below.

**Asymmetric alternatives exist and are named.** NExT-GQA [C9] introduced **IoP** = |P ∩ G| / |P|
(intersection over *prediction*) on the argument that *"any individual frame or moment which
sufficiently tells the answer should be considered a valid grounding, as opposed to retrieving all
of the video contents that match with the query"* — IoU punishes a correct *sub-span* of a
generous gold window; IoP does not. Its mirror, **IoG** = |P ∩ G| / |G|, is coverage of the gold
span. **The pair is precision and recall on the time axis, and tIoU conflates them.** Each is
individually gameable in a known direction — IoP by an arbitrarily short prediction, IoG by an
arbitrarily long one — so the literature reports them together, and so does this proposal.
Measured here:

| | mIoP | mIoG | IoG ≥ 0.5 |
|---|---|---|---|
| ranker top-1 | 0.015 | 0.055 | 7/112 |
| best of top-8 | 0.071 | 0.198 | 22/112 |
| best of 40 | 0.200 | **0.541** | **61/112** |
| **constant `0:00–8:00`** | 0.108 | **0.412** | **48/112** |

The last row is the demonstration: an eight-minute constant **fully contains the gold window for
42 of the 112** and so scores IoG 0.412 while knowing nothing. **IoG alone would be a worse metric
than IoU here, not a better one.** Reported as a pair with IoP, and beside the constant, it is
informative — the ranker's best-of-40 clears the constant on IoG (0.541 vs 0.412) but its top-1
does not.

**The closest thing to this task in the IR literature refused IoU entirely.** The **TREC Podcasts
Track** (2020, 2021) [C10, C11] retrieved *jump-in points* in 100,000 English podcast episodes —
the same medium, the same lengths, the same product question. Its design:

- **Fixed 120-second segments on a 60-second stride** (overlapping, *"to account for the case where
  a phrase or sentence is split across segment boundaries"*), giving 3.4M segments averaging
  340 ± 70 words. Runs submit an offset that must be a multiple of 60; length is always 120.
- **A graded 5-point relevance scale (Perfect / Excellent / Good / Fair / Bad) that folds boundary
  error into the *grade*, asymmetrically and by listener experience.** Verbatim: *Excellent* is
  *"an ideal entry point … begins at or very close to the start of a discussion on the topic"*;
  *Good* is *"a few minutes 'off' in terms of position, so that while it is relevant … they might
  have preferred to start two minutes earlier or later"*; *Fair* is *"a sub-par entry point …
  segments that start well into a discussion without providing enough context."*
- **Primary metric: mean nDCG**, plus nDCG@30 and P@10.

**That is a direct answer to ops#348 D3 from the one published programme that faced this exact
problem: at podcast length, with soft boundaries, the field chose fixed windows and graded human
judgement of the jump-in point over boundary arithmetic.** It is also the shape P75 §5.3 already
reached independently — *"a clip that loses on packaging is re-trimmed; a clip that loses only on
topical fit is presumed rubric-blind"* is a listener-experience grading rule, not an overlap rule.
The audio-ML community has gone the other way (DCASE 2026 Task 6 makes `recall1@0.7` its primary
metric [C12]) but on **1-minute** recordings, not 40–90-minute ones.

**Recommendation for the estate's own gold windows (§3.4 G1): grade the jump-in point on the TREC
PEGFB scale rather than re-measuring boundaries**, and keep tIoU/IoP/IoG as automatic secondary
figures. It is cheaper for the guild, it is the published choice for this medium, and it survives
the annotator noise that makes a hard IoU ≥ 0.7 gate unmeasurable.

**What it scores here, measured.** Against the 112 real human windows:

```
R@1,  IoU>=0.3 :   2 of 112 ( 1.8%)     IoU>=0.5 :  0 ( 0.0%)     IoU>=0.7 :  0 ( 0.0%)
R@8,  IoU>=0.3 :  10 of 112 ( 8.9%)     IoU>=0.5 :  2 ( 1.8%)     IoU>=0.7 :  2 ( 1.8%)
R@40, IoU>=0.3 :  30 of 112 (26.8%)     IoU>=0.5 :  8 ( 7.1%)     IoU>=0.7 :  5 ( 4.5%)
mIoU(top-1) = 0.013        mIoU(best of all 40) = 0.185
```

**And the reason is arithmetic, not ranking.** The candidate generator's duration-bucket floor
puts its **shortest possible candidate at 120 s**, median **263 s**; the human windows have median
**106 s** and maximum **241 s**. Since IoU ≥ m requires a duration ratio ≥ m, a 263 s candidate
against a 106 s gold window can reach at most **0.40** even if perfectly nested. Counted:

```
of the 112 real windows —
  have >=1 candidate in the right episode                          88 (78.6%)
  ...whose DURATION even permits IoU >= 0.7                        21 (18.8%)   <- the ceiling
  ...whose DURATION even permits IoU >= 0.5                        44 (39.3%)
```

**So `R@1, IoU≥0.7 = 0/112` is not a measurement of the ranker.** It is a measurement of a unit
mismatch between the candidate generator and the guild's tolerance. Scoring the ranker on it
would be the same error as §0 in the opposite direction: a number that cannot move, quoted as if
it could.

**The metric that does work today is containment.** Does *some* candidate cover the moment?

```
gold-window midpoint falls inside a candidate —
  @1  :   7 of 112 ( 6.2%)
  @8  :  22 of 112 (19.6%)
  @40 :  61 of 112 (54.5%)
```

**The moment is found for 54.5% and the boundaries are wrong for 95.5%.** That is a precise,
actionable, and rather hopeful diagnosis: it says the estate needs P75 §2.2's **Stage B trimmer**,
not a better scorer — and it is invisible to any metric that only reports IoU.

**Recommendation (ops#348 D3): `time_range_iou: 0.7` binds human↔human pairing (Stage B) and is
not the ranker's target (Stage A). The harness computes and prints IoU anyway**, at three
thresholds, permanently beside the containment figures and beside the arithmetic ceiling — so
that the day the generator emits human-scale windows, the change is visible in a number that was
already being printed rather than in a metric invented to celebrate it.

### 2.4 The trivial baseline that beats the ranker, and why it must be printed every run

| predictor | mIoU on the 112 | IoU ≥ 0.3 | IoU ≥ 0.5 | IoU ≥ 0.7 |
|---|---|---|---|---|
| **constant `0:00–8:00`, ignores the query entirely** | **0.107** | 15 (13.4%) | 0 | 0 |
| constant: prior median start + prior median duration | 0.070 | 11 (9.8%) | 8 (7.1%) | 4 (3.6%) |
| first in-episode candidate (**oracle episode**, no ranking) | 0.120 | 18 (16.1%) | 5 (4.5%) | 2 (1.8%) |
| **the actual ranker, top-1** | **0.013** | 2 (1.8%) | 0 | 0 |
| oracle centre + prior median length (upper bound for a length-blind trimmer) | 0.763 | 112 (100%) | 102 (91.1%) | 74 (66.1%) |

**A constant that never looks at the query scores 8× the ranker's mIoU.** The mechanism is not
mysterious — the ranker's top-1 is usually in the *wrong episode*, scoring a hard 0 — but that is
precisely why the baseline row matters: without it, "mIoU 0.013" reads as *"windows are hard"*
rather than *"episode selection is the bottleneck and this metric is mostly measuring that"*.

The last row is also load-bearing in the other direction: **even a trimmer that knew the exact
centre and used the prior median length would only reach IoU ≥ 0.7 on 66.1%.** That is the
realistic ceiling for Stage B without learning duration, and it is the number any future trimmer
should be judged against — not against 100%.

**Design rule: every window metric prints with its constant baseline and its arithmetic ceiling on
the same line. A window metric emitted alone is a defect in the harness, not a result.**

### 2.5 The three levels, which is the whole anti-conflation design

| level | question | label set | metric | current value |
|---|---|---|---|---|
| **L1 — SOURCE** | right episode? | 205 (primary 152) | success@{1,5,8,40}, MRR | S@8 = 42.4% · S@40 = 81.5% |
| **L2 — LOCALITY** | does a candidate cover the moment? | 112 | midpoint containment@{1,8,40} | 19.6% @8 · 54.5% @40 |
| **L3 — BOUNDARY** | are the edges right? | 112 | R@k,IoU=m · mIoU | 1.8% @8 IoU≥0.7 |

Read down the column and the estate's actual state is legible in one glance: **L1 is the
bottleneck at the top of the list, L2 says the material is mostly there, L3 is capped by a unit
mismatch.** Any one of those three numbers on its own supports a different and wrong story.

---

## 3. A gold set that does not exhaust the guild

### 3.1 The literature on how many items, and which test to use

**(a) Topic-set size.** Voorhees & Buckley [D1] introduced the **swap-rate / error-rate**
methodology: repeatedly split the topic set, compare system pairs on each half, and measure how
often the halves disagree about which system is better, as a function of topic count and observed
difference. Sakai's *topic set size design* work [D2] turned that into explicit tables — given a
target detectable difference, a significance level and a power, return the required topic count.
The guidance converging out of that literature is **~150-170 topics** as a floor for effects worth
shipping, well above the folk figure of 50.

**The estate is already past that floor at 205**, which is the single most useful thing this
subsection has to say: §3.3's measured scaling shows more labels buy surprisingly little, and the
literature agrees. §3.2 does not rely on the published tables at all — it computes the estate's own
resolution exactly, from the estate's own outcome vectors, which is strictly better than a table
lookup because it uses the *observed* discordance instead of an assumed effect-size distribution.

**(b) Which test.** Smucker, Allan & Carterette [D3] compared the **randomisation (permutation)
test**, the **bootstrap**, the **paired t-test**, the **Wilcoxon signed-rank test** and the
**sign test** on IR evaluation data. The settled conclusion: randomisation is the appropriate
reference, bootstrap and paired t agree with it closely, and **Wilcoxon and the sign test are
discouraged** because they discard magnitude information and can disagree with the other three.

**What this proposal uses, and why it differs.** The estate's per-item outcome at fixed k is
**binary**, not a continuous per-topic score, so the t/randomisation framing does not apply
directly. The correct paired test is **McNemar's** [D4], conditioning on the discordant pairs; and
at the counts actually observed (13, 29, 40, 30) the **exact binomial** form is required rather
than the chi-squared approximation, which is unreliable below roughly 25 discordant pairs. Sizing
uses the matched relation **N ≈ (z_{α/2} + z_β)² · π_D / δ²**. **MRR and mIoU are continuous
per-item scores**, so those use the **paired bootstrap** — the Smucker et al.-endorsed family, and
the thing that produces the confidence interval the `21 → 22` report most conspicuously lacked.

**(c) The comparison that needs no labels.** **Rank-biased overlap** [D5] gives a top-weighted
similarity between two ranked lists with no judgements at all, which is why §2.2 includes it: it
answers *"did anything change"* across all 251 learning points — including the 46 that are CANNOT
VERIFY — separately from *"was the change good"* on the 205 that are not.

**One convention worth knowing the provenance of.** The ubiquitous *"τ ≥ 0.9 means two rankings
agree"* threshold traces to **Voorhees [D6]** — the same paper as §3.5's assessor-agreement result
— as recorded in Sanderson's survey [D15]: *"Voorhees suggested τ ≥ 0.9 as such a threshold, which
was adopted by a number of subsequent researchers."* It is a **suggestion that hardened into a
standard**, and it has been criticised on exactly that basis: Sanderson & Soboroff [D16] show the
value of τ depends on the score range of the items being ranked, which *"makes use of absolute
thresholds difficult"*. **Recorded here because it is the same failure mode this document is
about** — a number quoted as a standard by people who never read where it came from. The harness
therefore cites the threshold it is judging against rather than asserting one.

### 3.2 What n = 205 can actually resolve — measured on this data

**Two different questions, and the difference matters.** "What is the smallest result that *could*
be significant?" is not "what is the smallest result I will *reliably* detect?" — the first is a
~50%-power statement, the second is the one a plan should be built on. Both are computed here on
the estate's own outcome vectors, exactly (exact McNemar for the first; the standard McNemar
sizing relation **N ≈ (z_{α/2} + z_β)² · π_D / δ²** with α = 0.05 two-sided and power 0.80 for the
second, where π_D is the observed discordant proportion):

| | discordant pairs | π_D | could reach *p* < 0.05 | detectable at 80% power | **observed Δ** |
|---|---|---|---|---|---|
| S@1 | 13 | 0.063 | +9 items (4.4 pp) | **+10 items (4.9 pp)** | **+1** |
| S@5 | 29 | 0.141 | +13 items (6.3 pp) | **+15 items (7.4 pp)** | **+1** |
| S@8 | 40 | 0.195 | +14 items (6.8 pp) | **+18 items (8.6 pp)** | **0** |
| S@40 | 30 | 0.146 | +12 items (5.9 pp) | **+15 items (7.5 pp)** | **+18** ✓ |

**The instrument's resolution on the existing labels is 5–9 percentage points**, and it degrades as
the two rankers become *more* different — more discordant pairs means more noise to overcome, which
is why S@8 (40 discordant) is the least sensitive row despite being the most operationally
interesting. Three consequences, all worth stating up front:

1. **A change worth less than roughly +10 to +18 learning points (depending on k) is not
   measurable with what exists**, and the harness must say so rather than print a delta (§5.4).
2. **The existing labels are enough to run the harness today.** S@40's **+18 clears even the
   80%-power bar of +15**, and returned *p* = 0.0014. This is not a proposal that blocks on new
   labelling — it starts with 205 free labels and adds more only where they buy resolution.
3. **The "could reach" column must never be quoted as the plan's sensitivity.** It is the number
   that flatters, and this document nearly quoted it: an earlier draft reported "+10 items at S@8"
   from the 50%-power computation when the properly-powered figure is **+18**. Recorded because the
   error is exactly the one §0 is about.

### 3.3 How much new labelling buys how much resolution

Holding the discordance rate fixed at the observed S@8 value (40 of 205 = 19.5%) and re-running
both computations at larger n:

| labelled items | discordant pairs | could reach *p* < 0.05 | **detectable at 80% power** |
|---|---|---|---|
| **205 (today, free)** | 40 | +14 (6.8 pp) | **+18 (8.6 pp)** |
| 300 | 59 | +17 (5.7 pp) | +21 (7.1 pp) |
| 400 | 78 | +20 (5.0 pp) | +25 (6.2 pp) |
| **500** | 98 | +22 (4.4 pp) | **+28 (5.5 pp)** |
| 800 | 156 | +26 (3.2 pp) | +35 (4.4 pp) |
| 1,000 | 195 | +29 (2.9 pp) | +39 (3.9 pp) |

Both columns are exact for the stated discordance; **the assumption that the discordance rate stays
constant as n grows is an estimate**, and it is the load-bearing one — a larger gold set drawn from
harder learning points would raise it and erode the gain.

The shape of the answer is the point: **going from 205 to 500 labelled items — a 2.4x labelling
programme — moves the properly-powered resolution from 8.6 pp to 5.5 pp.** It never buys the
ability to read `+1`. This is also roughly where the IR sizing literature lands independently: the
guidance in that work converges on **~150-170 topics** as the floor for detecting effects worth
shipping, and the estate is already past it at 205. **More labels are not the estate's
bottleneck.** Two other routes are cheaper and should be exhausted first:

- **Use the paired structure** (already free — it is why S@40 was significant at +18/205 while an
  unpaired comparison of 72.7% vs 81.5% would have been marginal).
- **Report at the level the change targets.** The §0 change was a *recall* change; measured at
  L1-S@40 it was unambiguous. Most of the sensitivity the estate needs is available by measuring
  the right thing, not by measuring more things.

### 3.4 The gold set: what to label, how many, and how long it takes

**The expensive decision is what to label, not how much**, and the literature is unusually
concrete about it. Concentrated judging is a **10-35x** saving over exhaustive pooling:

| method | effort | result |
|---|---|---|
| Minimal Test Collections [D10] | 2,200 judgements = **11.9%** of a depth-100 pool (15 annotator-hours across 6 people) | **96%** confidence in the final ranking; systems binned correctly after 50 judgements, ranked correctly after 250 |
| statAP [D11] | **11.5%** of the pool | τ = **0.950** — pooling at the *same* cost gets 0.912 |
| move-to-front [D12] | **10%** of the budget | ρ = **0.990** with the full-pool benchmark |
| bandit selection (MM-NS) [D17] | **34** judgements vs DOCID order's **1,181** | τ ≥ 0.9 — a **~35x** reduction |
| active learning, no system pool [D18] | **20%** of human judgements | τ = 0.9 |

**And the estate's G2 design turns out to be Minimal Test Collections, arrived at independently.**
MTC's selection weight for a document is the **difference in its reciprocal ranks between the two
systems**; a document both systems rank identically has weight zero and **is never selected**.
"Judge where the rankers disagree" is not a heuristic — it is what expected-loss-reduction reduces
to when the loss is the sign of the difference. Measured on the two artefacts in §0:

```
LPs where the two rankers disagree at rank 1     : 105 of 205 (51%)
LPs where the two top-8 SETS differ              : 182 of 205 (89%)
top-8 overlap between the two rankers            : mean 4.5 of 8 (median 4)
identical top-8 on                               :  22 of 205
```

Because the lists overlap, a **pooled** judgement set is much smaller than judging each ranker
separately — measured over the two artefacts across all 205 learning points:

| pool depth | judgements in the union | mean per LP | vs judging both lists separately |
|---|---|---|---|
| 1 | **310** | 1.5 | 2 |
| **2** | **607** | **3.0** | 4 |
| 3 | 913 | 4.5 | 6 |
| 5 | 1,474 | 7.2 | 10 |
| 8 | 2,310 | 11.3 | 16 |

**Shallow-and-wide beats deep-and-narrow, measured.** Carterette et al. [D19] costed the trade
directly: **20 judgements/query x 250 topics = 44 assessor-hours** beats both 10x600 (85 h) and
40x250 (63 h) for the same τ — and **5 judgements/query never reaches τ = 0.9 at all**. That last
clause is a live warning here: depth-3 pooling gives a mean of **4.5 judgements per learning
point**, right at the boundary where the published curve stops working. **So G2 goes wide, not
deep: depth-2 over all 205 learning points (607 judgements) rather than depth-3 over the 105
disagreements (538).** Nearly the same cost, more topics, and it does not sit on the cliff edge.

**Prefer preference judgements to relevance grades.** Measured medians: a **preference** judgement
takes **2.87 s** against **6.33 s** for a graded relevance judgement [D20] — and preferences pair
naturally with the McNemar sizing in §3.2, since "which of these two is better" *is* a discordant
pair. It is also what [B10] used to show MS MARCO's labels lose their own disputes.

**Recommended gold-set plan — three tranches, each with a stated purpose and an exit test:**

| tranche | what | volume | purpose | hours |
|---|---|---|---|---|
| **G0 — free** | the 205 existing episode labels, graded P1/P2/P3/S; the 112 real windows | **0 new** | the §7 baseline; enough to detect the ≥ +18 items that matter | **0** |
| **G1 — window gold** | re-audition the **112** existing human windows, grading the jump-in point on the TREC PEGFB scale (§2.3); **30** of them judged twice, independently | 112 items, 30 doubly-judged | a defensible L3 gold, and the **only** way to learn whether an L3 number measures the ranker or the annotators | **9-15 h** (estimate) |
| **G2 — depth-2 pool, preference form** | the depth-2 union over the two rankers, **all 205 LPs**, asked as *"which of these two is the better clip for this learning point?"* | **607** judgements | breaks the "unjudged = wrong" assumption; wide rather than deep, per [D19] | **4-7 h** (estimate) |

**Total: ~13-22 hours of one person's time**, against P75 §4.4's 11-20 h for the tag pass and a
queue P75 measured at 1,177 slots.

**Where the hour estimates come from, and why they are not the literature's.** The only *measured*
published throughput figure is ~**13 s** per judgement for expert NIST assessors on web documents
[D20] — at which rate 607 judgements is 2.2 hours. The estate's items are slower for a structural
reason: a candidate carries a **110-word median preview** (≈33 s to read at 200 wpm, measured in
§3.4's inputs) and a judgement that is at all careful involves sampling the audio. So the estimates
above run **3-5x** the published text rate. **They are estimates and are labelled as such**; the
published figure is given so the multiplier is visible rather than buried.

**G1 must happen first**, and not for the obvious reason: it is the only tranche that measures the
noise floor (§3.5), and until that exists every L3 number is uninterpretable.

**Explicitly not recommended: labelling the 46 CANNOT VERIFY learning points.** 29 are
retreat-sourced — there is no DIR episode to be right about, so a label would be an invention.
The remaining 17 already carry a computed guess the map's author deliberately withheld; promoting
it now would be exactly the error the withholding avoided.

### 3.5 Agreement: measure it before scoring anyone against it

**The single most important result in this literature is that assessors disagree a great deal and
system rankings survive it anyway.** Voorhees [D6] had TREC topics re-judged by independent
assessors: the overlap between assessors' relevant sets was around **Jaccard 0.30** — they agree
about which documents are relevant less than a third of the time — and yet the **ranking of systems
was preserved at τ ≈ 0.94**. The identical pattern has since been found outside IR: Recht et al.
[D21] rebuilt CIFAR-10/ImageNet test sets and saw **11-14% absolute accuracy drops with the model
ranking almost exactly preserved**.

**Both halves matter here, and they point in opposite directions:**

- **The reassuring half.** A *comparison* between two rankers can be trusted on labels individual
  humans would argue about. That is the licence for G0 — run the harness today, on 205 imperfect
  labels, and believe the **deltas**.
- **The disciplining half.** An *absolute* number carries the assessors' idiosyncrasies with it.
  "S@8 = 42.4%" is a property of this label set, not of the world, and must never be quoted as
  "the ranker is 42% accurate". §5.5's baseline file exists to record it as *what was measured
  when*, not as a score.

**The one thing that breaks the reassuring half is systematic assessor error, not honest
disagreement.** Measured: random judging collapses τ to **0.34**; non-expert judges give
**0.66-0.73** [D20]. **So the quality control belongs on assessor calibration, not on label
volume** — which is a direct argument for G1's 30 doubly-judged items over a larger single-judged
set, and it inverts the intuitive plan.

That distinction is sharper still at L3, where §2.3's boundary-agreement measurements apply:
independent human re-annotations agree with published gold at IoU > 0.5 only **42.8% / 35.4%** of
the time [C6], and human-human boundary IoU is **72.5% / 58.7%** with only **76.1%** of
re-annotations above IoU 0.5 [C8]. **A hard IoU ≥ 0.7 gate would be scoring the annotators.**

**Which agreement statistic, for which judgement:**

| what is judged | statistic | why |
|---|---|---|
| binary accept/reject, 2 raters | **Cohen's κ** [D7] | the standard two-rater nominal case |
| a graded scale (the PEGFB 5-point scale, §2.3), 2+ raters | **Krippendorff's α**, ordinal | κ treats "Excellent vs Good" as the same error as "Excellent vs Bad"; ordinal α does not |
| variable raters, missing judgements | **Krippendorff's α** [D8] | the only one that handles any number of raters, any measurement level, and missing data — the realistic shape of guild judging |
| **time intervals on a continuum** | **Krippendorff's α_U (unitizing)** [D9] | annotators must both *find* and *delimit* units. This is exactly G1's doubly-judged trims, and it is the statistic that exists for it |
| fixed number of raters, nominal | Fleiss' κ | applicable, strictly less general than α |

**On interpreting the number.** The Landis & Koch bands [D7] (0.21-0.40 *fair*, 0.41-0.60
*moderate*, 0.61-0.80 *substantial*) are the most-quoted scale in existence and were described **by
their own authors as arbitrary divisions**. Krippendorff's recommendation is markedly stricter —
**α ≥ 0.800 for firm conclusions, 0.667 the lowest value supporting even tentative ones** [D8].
**Report the coefficient and its n and cite the threshold being applied; never emit an adjective.**
"Substantial agreement" is a Landis & Koch band quoted as if it were a finding — the same class of
error as `21 → 22`, and the same class as the τ ≥ 0.9 convention in §3.1.

**The estate-specific point.** Nobody has ever measured whether two people choosing a clip for the
same learning point agree. P75 measured the adjacent fact — **66 of 175 live clips overlap no
candidate the rubric found**, over a pool spanning **591 distinct episodes** — and drew the right
conclusion for pairing (*"two independent reviewers turned loose on 648 episodes will not converge
on an episode by accident"*). The same fact is a warning for evaluation: **if two humans routinely
disagree at IoU 0.5, an L3 score below that gap is measuring annotators, not rankers.**

**This is why G1's 30 doubly-judged items exist**, and it is the cheapest insurance in this
document: 30 items, ~3 h, producing a **noise floor** that every future L3 number is printed
against. The harness should refuse to call an L3 difference meaningful when it is smaller than the
measured human-human disagreement — the same shape as refusing to call +1/205 an improvement.

### 3.6 The finding that constrains everything above: judged pools are NOT reusable

**This is the most consequential thing the research turned up, and it changes what the harness is
allowed to claim.** Every direct published test of test-collection *reusability* — can a collection
built by judging systems A and B fairly evaluate a later system C that contributed nothing? — has
come back negative.

- **Leave-one-out penalties** grew as collections got harder. Historically small — TREC-5 **0.5%**,
  TREC-8 ad hoc **0.8%**, TREC-9 web **1.1%** — but TREC-8 CLIR **6.3%**, TREC 2001 CLIR **8.0%**,
  and then the case that broke the consensus [B7]: a run whose MAP **would have been 0.202 instead
  of 0.266 had it not contributed to the pool — a 23% relative drop.** The mechanism was the
  title-word bias quoted in §1.5.
- **The designed experiment settled it.** The Million Query 2009 track tested reusability directly
  and reported [D22]: *"We **do not reject** the hypothesis that it is possible to reuse MQ09
  topics and judgments for **within-site** comparisons… 2. We **do reject** the hypothesis that it
  is possible to reuse MQ09 topics and judgments for **between-site** comparisons."* Between-site
  τ was **0.7643 (statMAP) / 0.8350 (MTC)** — the overview's own words: *"both of which are rather
  low."*
- **The prescription** [D19]: *"Reusability in the sense it is traditionally understood is
  impossible… Instead, evaluation should report a confidence based on the missing judgments."*
- The same effect shows up in the sampling metrics: xinfAP's τ against **non-pooled** systems falls
  to **0.8678** at 12.7% judged, where pooled systems hold **0.9345** [D11].

**What this obliges the harness to do**, and it is a new refusal rather than a caveat:

> **A comparison is valid for the rankers that contributed to the pool. It is a weaker claim about
> any ranker that did not.** The harness records, per judgement, **which artefact pair produced
> it**, and when asked to score an artefact that contributed to none of them it must say so — a
> `POOL-NAIVE` flag on the report, not a footnote.

**This is not academic here.** The estate's whole purpose in building this is to evaluate *future*
rankers, and G2's pool is drawn from the top-2 of two **specific** artefacts — so a future ranker
that retrieves differently will retrieve mostly unjudged candidates, which is precisely the
condition [B7] measured a 23% penalty under. **The bias is designed in and cannot be designed
out**; what can be done is to make it visible and bounded, in three ways:

1. **G1's 112 windows are judged independently of any ranker**, giving an unbiased spine that no
   amount of G2 can contaminate — which is a second, independent reason to do G1 first.
2. **Every G2 judgement is stamped with the artefact pair that surfaced it**, so a later session
   can tell a general label from a pool-mined one instead of inheriting a silently biased
   collection.
3. **A genuinely new ranker triggers a re-judging budget** (§9 phase 7), sized by how far it
   departs from the pool — owed, not optional.

A collection quietly reused past its validity is precisely the "check nobody has seen fail" shape,
relocated into the label set: it keeps producing confident numbers, and nothing in the output says
they stopped meaning anything.

## 4. Guarding against the trap the estate already fell into

### 4.1 The trap, named

**A proxy is a quantity that correlates with quality under assumptions nobody re-checks.**
"Sibling separation" is a proxy: distinct tops *should* mean better-targeted retrieval. It moved
193 → 127. Correctness at the top of the list did not move. Both facts are true, and the failure
was reporting the first without the second — not the proxy itself, which was a perfectly
reasonable engineering target and which, measured properly (§0), came with a real recall win.

### 4.2 Design rule 1 — correctness and separation are one report or neither

The harness emits a **single report** containing both columns, and there is no flag, no
sub-command and no output mode that emits one without the other:

```
=== CORRECTNESS (labels) ===              === SEPARATION (proxy, no labels) ===
L1 S@1    21 ->  22   p=1.000  ns         siblings sharing a top   193 -> 127   -66
L1 S@8    87 ->  87   p=1.000  ns         distinct top candidates   97 -> 141   +44
L1 S@40  149 -> 167   p=0.0014  **        distinct episodes at top  69 -> 102   +33
L2 mid@8  24 ->  22   (-2)                RBO(before,after)@8 norm       0.545
L3 IoU>=0.5@8  5 ->   2   (-3)  [ceiling 44/112; constant baseline 0/112]

VERDICT: separation improved; top-of-list correctness UNCHANGED (ns at n=205,
         MDE +10 items); pool recall IMPROVED (+18, p=0.0014); window metrics
         DEGRADED at the top of the list (-3 at IoU>=0.5@8, below the noise floor
         -- see G1).
```

That verdict paragraph is generated, not written, and it is the deliverable. **Its job is to be
awkward.** The §0 change genuinely degraded L2 and L3 at the top of the list (midpoint@8 24 → 22,
IoU≥0.5@8 5 → 2) while improving L1-S@40 and the separation proxy. A report that could not say
all four of those things at once is a report that will be quoted selectively.

### 4.3 Design rule 2 — never one number

There is no composite score, no weighted blend, no single "clip quality index". The estate already
made this argument once, in `~/dir/courses_v3/history/corpus_v2/CRITERIA.md`'s *"Why not just
ML?"*, and P75 §1.2 re-made it for the triage queue: *"a single blended priority score is
untrustworthy — it would be exactly the opaque ranking the estate rejected."* A composite
evaluation metric has the identical defect with the identical mechanism: it lets a gain on a cheap
component pay for a loss on the expensive one, invisibly.

### 4.4 Design rule 3 — the anti-cheat register

For every metric, the harness knows the **cheapest way to move it without improving anything**,
prints that adversary's score alongside, and fails if the adversary wins:

| metric | how to cheat it | the printed adversary | current: ranker vs adversary |
|---|---|---|---|
| mIoU, R@k IoU=m | emit windows at the prior's length and position | constant `0:00–8:00` | **0.013 vs 0.107 — ranker LOSES** |
| success@k (episode) | flood ranks 1–8 with segments from one episode | "all 8 from the top-1 episode" | to be computed per run |
| separation | make tops distinct by randomising | random permutation of the pool | to be computed per run |
| midpoint containment | emit maximally long candidates | "whole episode as one candidate" | to be computed per run |
| any of them | tune until the test set is memorised | the held-out split, §4.5 | — |

The first row is the proof that this register is not theatre: it is already firing, today, on the
current ranker, and it was found by writing the register rather than by suspecting the result.

### 4.5 Overfitting discipline at n = 205

**The problem has a name and a formal treatment: *adaptive data analysis*.** A held-out set is
valid for *one* question. Ask it a second question chosen *after seeing the first answer*, and the
guarantee degrades — the analyst has become a channel through which the holdout leaks into the
method. Dwork, Feldman, Hardt, Pitassi, Reingold & Roth [D13] formalised this and gave a mechanism
(**Thresholdout**) that answers many adaptive queries validly by adding calibrated noise and
reporting a holdout value only when it differs *significantly* from the training value. Their
illustrative experiment is the memorable part: on data with **no real signal at all**, the standard
holdout procedure reported substantial accuracy after a few rounds of adaptive feature selection,
while the reusable holdout correctly reported none.

**But the empirical picture is milder than the theory's worst case, and the design should reflect
both.** Roelofs et al. [D14] meta-analysed Kaggle competitions — comparing each team's public
leaderboard score (queried repeatedly during the competition) against its private score (queried
once) — and found **little evidence of substantial adaptive overfitting** in most competitions:
public and private rankings largely agreed, with the clearest degradation where **test sets were
small**. *(The per-competition statistics were not obtained and are not quoted; the qualitative
finding is the paper's headline.)* The same group's ImageNet/CIFAR replication work [D21] is the
sharper version of the same lesson and is quoted in §3.5: **absolute scores moved 11–14 points
while the ranking held.**

**The synthesis, and it is why §4.5's rule is a budget rather than a prohibition:** repeated
holdout reuse is dangerous *in principle* and usually survivable *in practice* — except in the one
regime where it is most dangerous, **small test sets**, which is precisely this estate's regime at
n = 72. So the design does not forbid re-reading TEST (a prohibition would be ignored under
deadline and would push work into the dark). It **counts** the reads and prints the count, which is
the honest minimum: a reader can then discount a figure that has been optimised against, and the
count going up is itself visible evidence rather than a private fact.

**The concrete rule for this estate, sized to this data — and one place where the data refuses.**

A conventional 60/20/20 split of 205 leaves 41 items in TEST, and **at n = 41 the exact McNemar
test cannot return a significant result at all**: the observed discordance rate yields 4
discordant pairs, and even a perfect 4–0 split gives *p* = 0.125. A three-way split does not
merely blunt the instrument, **it removes it.** So: **two folds, not three.**

The real course-level split, counted:

```
labelled LPs by course letter (n=205):
  A 21 · B 28 · C 22 · D 22 · E 23 · F 17 | G 17 · H 17 · I 13 · J 25
  DEV = courses A-F = 133      TEST = courses G-J = 72
```

| discipline | rule |
|---|---|
| **Two folds, not three** | **DEV = 133** (courses A–F) · **TEST = 72** (courses G–J). Splitting **by course** matters: sibling learning points share a candidate pool, so a learning-point-level split leaks (P75 measured 127 of 251 still sharing a top with a sibling). MDE: **+9 items / 6.6 pp on DEV, +7 items / 10.3 pp on TEST** — both worse than the unsplit 4.9 pp, which is the price of the discipline and must be printed with every split reading. |
| **TEST is opened on a counter** | The harness writes an append-only `evaluation-log.jsonl` row every time TEST is scored: timestamp, both artefact hashes, the git ref, and who asked. The count is printed in every report: *"TEST has been read 7 times."* |
| **A budget, not a prohibition** | TEST is read at most **once per merge request**, and the count is in the MR. Reading it twice is allowed and is visible, which is the point — see the reusable-holdout literature above. |
| **Cross-validation on DEV** | 5-fold by course for anything tuned, so a tuning decision is never made on a single 137-item read. |
| **Never reportable** | A number obtained on DEV **may not be quoted as the harness's verdict**. The report labels it `DEV (tuned on — not a verdict)` in the output itself, so a copy-paste into an issue carries its own warning. |

**What "we tuned on this" must never be reported as:** an accuracy, a score, a percentage, or a
comparison. It is reported as **"a DEV reading, taken N times, not a verdict"** — with N. The
single most expensive omission in the §0 episode was not a wrong number; it was a number quoted
with no statement of what it could resolve.

> **The split does not work for L2/L3, measured, and the harness must say so rather than pretend.**
> The 112 real windows are not spread across the courses the way the episode labels are:
>
> ```
> 112 windows by course letter:  A 20 · B 25 · C 19 · D 17 · E 16 · F 9 | G 6 · H 0 · I 0 · J 0
> ```
>
> **A–F holds 106 of them and G–J holds 6.** So the same course split that gives L1 a workable
> 133/72 gives L3 a TEST fold of **six items**, which can prove nothing. The honest handling is
> **not** to invent a different split for L3 — a per-metric split is a per-metric excuse — but to
> report L2/L3 as **DEV-only, explicitly labelled un-held-out**, until §3.4's G1 tranche produces
> window labels on the G–J courses. **That is a real limitation of this proposal and it is stated
> here rather than discovered later.** It is also a concrete argument for doing G1: it is the only
> tranche that makes the window metrics honestly testable rather than merely computable.

---

## 5. Fitting the estate's doctrine

### 5.1 Red-then-green: a metric that has never been observed to fall is not a metric

`CLAUDE.md`'s standing order says a check that has never been proven to fail is a hypothesis. The
same is true of a metric, and it is *harder*, because a metric that only ever goes up looks like
success.

**The harness ships with a mutation battery: known-bad rankers that it must score WORSE than the
real one.** Each is a one-line transformation of an existing artefact, so each is cheap and each
has an unarguable expected direction:

| mutant | expected verdict | proves |
|---|---|---|
| **shuffle** — permute each learning point's 40 candidates | S@1, S@8, MRR must **fall**; S@40 must **not move** | the metric measures *ranking*, not pool membership — and that the two are separable |
| **truncate** — drop the pool to top 10 | S@40 must **fall**, S@8 must **not move** | the recall/ranking split is real |
| **reverse** — reverse each list | every success@k for k < 40 must **fall** | monotonicity |
| **episode-flood** — replace ranks 2–8 with more segments from the rank-1 episode | separation must **fall**; S@8 must **not rise** | the anti-cheat register of §4.4 fires |
| **constant-window** — replace every window with `0:00–8:00` | L3 must **rise** to the constant baseline while L1 collapses | that L3 alone is gameable, demonstrated rather than asserted |
| **identity** — the same artefact twice | every delta exactly **0**, every *p* exactly 1.0 | determinism (§5.3) |

**None of these is a test that the harness passes. They are tests that the harness's *metrics* can
fail, run before any of its numbers are believed.** `pl verify gates` should list the harness only
after this battery has been observed red — and the mutants are the red.

### 5.2 Fail-closed: an unmeasurable item is CANNOT VERIFY, never a zero

Three outcomes per item, never two:

```
HIT(rank)  |  MISS  |  CANNOT_VERIFY(reason)
```

`CANNOT_VERIFY` is **excluded from the denominator and printed with its count and reason**, never
scored as a miss. The cases that exist today, all measured:

| case | n | reason |
|---|---|---|
| no episode label | 46 | 29 retreat-sourced (no DIR episode exists), 17 unresolved-and-withheld |
| default `0:00–8:00` window, for L2/L3 only | 64 | not a human selection (P75 §5.1) |
| catalogue window resolves to no transcript span | 1 (`B2.04`) | P75 §7 — the estate's existing named example |
| learning point absent from one of the two artefacts | 0 today | must still be handled: an artefact that lost a learning point is a **regression**, not a silent smaller denominator |

**And the denominators are printed, every run, next to every rate.** `42.4%` is not a result;
`87 / 205 (46 CANNOT VERIFY)` is. The last row above is the one that will actually bite: two
artefacts with different learning-point sets would otherwise compare 205 against 198 and call the
difference progress.

**Harness exit codes**, matching `pl server health`'s existing shape: `0` = compared, `1` = a
regression the caller asked to gate on, `2` = **CANNOT VERIFY** (an artefact unreadable, the label
map missing, the two artefacts not comparable). **Exit 2 is never a pass and never graded green.**

### 5.3 Determinism

The inputs already make this achievable, which is a credit to the generator:

- `_runs_v3.json::meta.content_sha256` and eleven `inputs_sha256` entries (catalog, transcripts,
  `lp_taxonomy.py`, `course_taxonomy.py`, the episode map, …).
- `meta.sort_key = (-quality, -score_total, -duration_s, ep, start_s)` — a **total** order, so
  there are no ties to break non-deterministically.

**The harness records both artefacts' `content_sha256` in every report and in every
`evaluation-log.jsonl` row.** Same two hashes → byte-identical report, and the `identity` mutant
in §5.1 proves it. A report whose hashes are not both present is not a result. Bootstrap
resampling uses a **fixed seed recorded in the report**; if it is not recorded, the CI figures are
not reproducible and the report is a story.

> **Cross-reference:** ops#343 has `verify:gates` non-deterministic on the shared runner. A
> measurement harness with the same defect would be worse than none, because its output is
> *specifically* the thing people will quote.

### 5.4 What the harness must REFUSE to do

This list is the design. A harness that will do these things on request will eventually be asked.

1. **Refuse to print a delta it cannot resolve.** Below the MDE the output is
   `ns (MDE +10 items at n=205)`, not `+1`. The bare `+1` is what caused §0.
2. **Refuse to emit correctness without separation, or separation without correctness** (§4.2).
3. **Refuse to emit a window metric without its constant baseline and arithmetic ceiling** (§2.4).
4. **Refuse to emit a single composite score.** There is no `--score` flag and asking for one
   returns the reason, not a number (§4.3).
5. **Refuse to count an unmeasurable item as a miss** (§5.2).
6. **Refuse to score TEST without logging the read**, and refuse to hide the read count (§4.5).
7. **Refuse to pick a label convention.** STRICT and LENIENT are both printed; there is no
   `--lenient` flag, because the flag would become a default and the default would become the
   number (§1.2).
8. **Refuse to load `history/corpus_v2/_runs.json`** as a comparison artefact — named error,
   pointing at §1.6.
9. **Refuse to compare artefacts whose learning-point sets differ**, without reporting the
   difference first (§5.2).
10. **Refuse to promote the 17 withheld lexical guesses to labels** (§1.1, §3.4).
11. **Refuse to present a pool-mined comparison as valid for a ranker that did not contribute to
    the pool.** Every judgement is stamped with its artefact pair; scoring a stranger against it
    prints `POOL-NAIVE` on the report. Between-site reusability has been directly tested and
    **rejected** (§3.6), with a worst measured leave-one-out penalty of **23% of MAP**.

### 5.5 Shrink-only baselines

One file, `docs/reports/clip-eval-baseline.json`, holding the current measured values for every
metric in §2.5 plus the two artefact hashes. It is **not** a threshold to beat — regression gating
on a noisy metric would fail builds for coin flips. It is the **record of what was measured when**,
so that "did this get worse" is answerable without re-deriving history. Rows may be updated only
with the measurement that produced them; a row whose value changes without an artefact-hash change
is a determinism bug and the harness says so.

---

## 6. Where it lives, and how it runs

### 6.1 The interface — one command, two artefacts

**This verb does not exist. The lines below are a specification, not instructions**, and are
written so that they cannot be copied and run — see the note at the end of this section.

```
SPEC  pl clip eval <before.json> <after.json> [options]

        --labels=<path>       default ~/dir/courses_v3/build/lp_episode_map.json
        --catalog=<dir>       default ~/dir/courses_v3/catalog/
        --set=dev|test|all    default dev; test logs the read (§4.5)
        --grade=p1p3|all      label grades to include (§1.1); default p1p3
        --json                machine-readable, same content, same refusals
        --mutants             run the §5.1 battery and assert the expected directions

SPEC  pl clip eval <after.json>     single artefact: absolute figures, no deltas, no p-values
SPEC  pl clip eval --baseline       re-record docs/reports/clip-eval-baseline.json
```

Exit `0` compared · `1` gated regression · `2` **CANNOT VERIFY**.

**Why a `pl` verb and not a script in `~/dir`.** The standing order (`CLAUDE.md`) is that every
operation goes through `pl`, and P75 R7 already records that `scripts/commands/` contains no clip,
course or corpus verb while four clip operations live as bare Python. This is the fifth, and it is
the one whose whole value is being trustworthy. A measurement tool outside the reviewed tree is a
measurement nobody can audit.

> **A gate fired on this document, correctly, and it is recorded rather than baselined.**
> `pl doc-truth` reported `[dead-command-ref] … → pl clip` against the first draft of the block
> above — because the verb genuinely does not exist. **That is the gate working**, and the right
> response was to stop writing a not-yet-built verb in runnable form: hence the `SPEC` prefix in
> the block above, and hence this document naming the subverb (`clip eval`) rather than the
> runnable two-token form everywhere else. It was **not** baselined: `pl doc-truth --baseline`
> would have recorded "this doc may prescribe a dead command" permanently, and baselines are
> shrink-only. The gate is green on this document as written.
>
> There is a small real gap behind it, worth a line in ops#337's tail rather than a fix here.
> `dead-command-ref` exists to catch *prescriptions*, and a PROPOSED design document naming the
> interface it is proposing to build is not a prescription. The existing per-line escape hatch is
> `<!-- doc-truth:retired -->`, whose name asserts the opposite of the truth here — a future verb,
> not a removed one. A `<!-- doc-truth:proposed -->` sibling marker would say the true thing; using
> the `retired` marker for it would put a false statement in the tree to silence a true gate,
> which is worse than the prefix used above.

### 6.2 `~/dir` has no forge project and no CI — what that means for a harness

ops#338 measured it: `~/dir`'s only remote is a bare mirror at `met:mirrors/dir.git`; there is no
`nwp/dir` among the group's 28 projects; there is no pipeline. **Every script that decides which
clip a learner sees has no MR location and no review gate.**

For a harness whose entire job is trustworthy measurement, that is disqualifying, and waiting for
ops#338 is not necessary. ops#338 also measured *why* the obvious fix is not free: `_runs_v3.json`
embeds **5,151,351 characters of verbatim transcript ≈ 38% of the DIR corpus** in its `preview`
fields, against a rights posture of `derivative-cleared-pending` and the corpus-search API bound of 0.24% per
request.

**The resolution falls out of what an evaluation record actually is:**

> A per-learning-point vector of integer ranks, a set of outcome enums, two `sha256` hashes, and
> a count. **It contains no transcript.**

So:

| component | home | why |
|---|---|---|
| harness code (the proposed `clip eval` verb, metric library, mutant battery) | **`nwp/nwp`** | reviewed, CI'd, red-then-green, `pl verify gates`-visible **today** |
| candidate artefacts (`_runs_v3.json`, 38% corpus) | **stay in `~/dir`**, read by path, never copied | rights posture unchanged; ops#338 decides their home on its own merits |
| labels (`lp_episode_map.json`, 77 KB, no transcript) | **`nwp/nwp`** as a tracked fixture, or `nwp/courses` | it is the gold set; it must be versioned where changes to it are reviewable |
| reports + `evaluation-log.jsonl` + baseline | **`nwp/nwp`** under `docs/reports/` | ranks and hashes only — **the harness must assert no `preview` field ever reaches them** |

That last assertion is itself a testable gate with an obvious red: feed it a report containing a
`preview` key and it must refuse.

**One honest limitation.** The harness is reviewable and CI-able; **the generator it measures is
not, until ops#338 is decided.** A trustworthy ruler measuring an unreviewed object is a real
improvement and an incomplete one, and this document does not claim otherwise. It does mean the
harness can be built now, which is the point.

### 6.3 CI

Two jobs, both cheap (the whole §0 analysis ran in seconds on two 20 MB files):

- **`clip-eval:mutants`** — the §5.1 battery on a small tracked fixture pair. Must be observed red
  before it is trusted (delete an expected direction, watch it pass, restore it). Runs on every
  MR touching the harness. **This is the gate.**
- **`clip-eval:baseline`** — recompute the §7 figures from the tracked label fixture and assert
  they match `docs/reports/clip-eval-baseline.json`. Guards determinism, not quality.

Neither may be `allow_failure: true` — `scripts/ci/lint-gate-redproof.sh` already names that as
the strongest CANNOT-FAIL finding it produces, and a measurement job that cannot redden the
pipeline is a placeholder wearing a gate's name.

---

## 7. Worked example — the current ranker's baseline

**This is the number everything future is judged against.** Computed 2026-08-11 from the two
tracked artefacts named in the evidence base. Reproduction: Appendix A.

### 7.1 L1 — SOURCE (episode), n = 205 labelled, STRICT

| k | before `e89079f` | after `c22dfbd` | Δ | discordant (after-only / before-only) | McNemar *p* | bootstrap 95% CI |
|---|---|---|---|---|---|---|
| 1 | 21 (10.2%) | **22 (10.7%)** | +1 | 7 / 6 | 1.000 | [−2.9, +3.9] pp |
| 5 | 59 (28.8%) | **60 (29.3%)** | +1 | 15 / 14 | 1.000 | [−4.4, +5.9] pp |
| 8 | 87 (42.4%) | **87 (42.4%)** | 0 | 20 / 20 | 1.000 | [−5.9, +5.9] pp |
| 40 | 149 (72.7%) | **167 (81.5%)** | **+18** | 24 / 6 | **0.0014** | **[+3.9, +14.1] pp** |
| MRR | 0.206 | **0.211** | +0.005 | — | — | — |

Under LENIENT (§1.2): S@1 24 → **27**, S@5 67 → **77**, S@8 95 → **104** (*p* = 0.233),
S@40 161 → **178** (*p* = 0.0005).

On the recommended **P1+P3 primary set (n = 152)**, the current ranker scores S@1 **18 (11.8%)**,
S@5 **45 (29.6%)**, S@8 **66 (43.4%)**, S@40 **126 (82.9%)**, MRR **0.218**.

**Recall ceiling: 38 of 205 labelled learning points have no candidate from their labelled episode
anywhere in the top 40.** Among the 167 that do, the first correct-episode candidate sits at
median rank **8**, mean **10.8**.

### 7.2 L2 — LOCALITY (does a candidate cover the moment), n = 112

Gold-midpoint containment:

| k | before | after | Δ |
|---|---|---|---|
| 1 | 8 (7.1%) | **7 (6.2%)** | −1 |
| 8 | 24 (21.4%) | **22 (19.6%)** | −2 |
| 40 | 48 (42.9%) | **61 (54.5%)** | **+13** |

IoP / IoG (time-axis precision and recall), best in the top-k, with the constant for scale:

| | mIoP before → after | mIoG before → after | IoG ≥ 0.5 before → after |
|---|---|---|---|
| top-1 | 0.024 → **0.015** | 0.065 → **0.055** | 8 → **7** |
| best of top-8 | 0.089 → **0.071** | 0.213 → **0.198** | 24 → **22** |
| best of 40 | 0.163 → **0.200** | 0.422 → **0.541** | 48 → **61** |
| *constant `0:00–8:00`* | *0.108* | *0.412* | *48 (contains the gold window outright 42×)* |

### 7.3 L3 — BOUNDARY (temporal IoU), n = 112

| | before | after | Δ | constant `0:00–8:00` | arithmetic ceiling |
|---|---|---|---|---|---|
| R@1, IoU ≥ 0.3 | 4 (3.6%) | **2 (1.8%)** | −2 | **15 (13.4%)** | — |
| R@8, IoU ≥ 0.3 | 12 (10.7%) | **10 (8.9%)** | −2 | — | — |
| R@40, IoU ≥ 0.3 | 24 (21.4%) | **30 (26.8%)** | +6 | — | — |
| R@1, IoU ≥ 0.5 | 1 (0.9%) | **0 (0.0%)** | −1 | 0 | 44 (39.3%) |
| R@8, IoU ≥ 0.5 | 5 (4.5%) | **2 (1.8%)** | −3 | — | 44 (39.3%) |
| R@1, IoU ≥ 0.7 | 1 (0.9%) | **0 (0.0%)** | −1 | 0 | **21 (18.8%)** |
| R@8, IoU ≥ 0.7 | 4 (3.6%) | **2 (1.8%)** | −2 | — | **21 (18.8%)** |
| mIoU (top-1) | 0.022 | **0.013** | −0.009 | **0.107** | — |

### 7.4 The proxy, reported beside it and never instead of it

| | before | after | Δ |
|---|---|---|---|
| LPs sharing a top candidate with a sibling | 193 | **127** | **−66** |
| distinct top candidates | 97 | **141** | +44 |
| distinct episodes drawn on at rank 1 | 69 | **102** | +33 |

### 7.5 The verdict the harness would have printed

> **Separation improved substantially (193 → 127 siblings sharing a top).**
> **Pool recall improved significantly (S@40 149 → 167, *p* = 0.0014, CI [+3.9, +14.1] pp).**
> **Top-of-list episode correctness is UNCHANGED** — S@1 +1 and S@8 +0 are both far below the
> minimum detectable effect of +10 items at n = 205; *p* = 1.000 with symmetric discordance
> (7/6 and 20/20).
> **Window metrics DEGRADED at the top of the list** (midpoint@8 24 → 22; IoU ≥ 0.5@8 5 → 2),
> though every L3 figure sits below both the constant baseline (mIoU 0.107) and the arithmetic
> ceiling (21/112 at IoU ≥ 0.7), so **L3 currently measures a unit mismatch, not the ranker.**
> **CANNOT VERIFY: 46 learning points (no episode label) at L1; 139 at L2/L3 (64 defaults +
> 75 with no clip).**

Every clause of that is a measured fact, four of the five clauses are things the estate did not
know this morning, and two of them are unflattering. **That is the deliverable.**

---

## 8. What needs a ruling

Four rulings, on [nwp/ops#348](https://git.nwpcode.org/nwp/ops/-/issues/348) with full options and
recommendations. Summarised here only:

| # | Ruling | Recommendation |
|---|---|---|
| **D1** | Is the episode map admissible as truth, and in which grades? | **P1+P3 (n = 152) primary; P2 and S reported separately, never folded in** |
| **D2** | STRICT or LENIENT multi-episode matching? | **Both, always, side by side — the definitional swing (±8.3 pp) exceeds the sample's resolution (±4 pp)** |
| **D3** | Does `time_range_iou: 0.7` bind the ranker, or only human↔human pairing? | **Pairing only (P75 Stage B); the harness prints IoU anyway, beside its ceiling and its constant baseline** |
| **D4** | Where does the harness live, given ops#338? | **`nwp/nwp` as a `clip eval` verb — an evaluation record is ranks and hashes, so it carries no corpus and needs no rights decision** |

**Not the operator's call, and recorded here so nobody asks for a ruling on it:** which metrics
are computed (§2 — the data settles it), the mutant battery (§5.1 — doctrine), and the gold-set
tranche order (§3.4 — G1 first, because it is the only one that measures the noise floor).

---

## 9. Sequencing

| phase | work | blocked on | cost |
|---|---|---|---|
| **0** | `clip eval` L1 only, two artefacts, success@k + MRR + McNemar + bootstrap, three-outcome fail-closed, both label conventions | nothing | small — the §7 L1 figures are already computed |
| **1** | The §5.1 mutant battery + `clip-eval:mutants` CI job, each mutant **observed red** | phase 0 | the phase that makes phase 0 believable |
| **2** | L2 + L3 with constant baselines and arithmetic ceilings; separation column; the generated verdict paragraph | phase 0 | §7.2–7.5 are computed; this is packaging them honestly |
| **3** | DEV/TEST split by course, `evaluation-log.jsonl`, read counter | phase 0 | small, and it must precede any tuning |
| **4** | **G1** — re-audition the 112 windows, 30 doubly-judged, publish the human-human noise floor | **D3** | 9–15 h (estimate) |
| **5** | **G2** — depth-2 pooled **preference** judgements over all 205 LPs (**607** judgements) | phase 3, D1 | 4–7 h (estimate) |
| **6** | Retire `docs/reports/clip-eval-baseline.json`'s provisional rows as real gold replaces derived labels | phases 4–5 | — |
| **7** | **Re-judging budget when a genuinely new ranker arrives** — owed, not optional (§3.6) | a new ranker existing | proportional to how far it departs from the pool |

Phases 0–3 need **no new labelling and no operator ruling except D4** (where the code lives), and
they are what turns `21 → 22` from an argument into a measurement.

**Phase 7 is in the table because §3.6 makes it an obligation rather than a nicety.** Between-site
reusability of a judged pool has been directly tested and rejected, with a worst measured
leave-one-out penalty of **23% of MAP**. A collection silently reused past its validity is the
"check nobody has seen fail" shape relocated into the label set, and the only defence is to have
written the re-judging into the plan before the tempting moment arrives.

---

## 10. What this proposal deliberately does not do

- It ships **no production code**. The snippets are illustrative; the prototype that produced §7
  ran from a scratch directory and is not proposed for merge as-is.
- It does **not** change the ranker, the rubric, the candidate generator, or any weight. It cannot:
  a ruler that is also the thing being measured is not a ruler.
- It does **not** re-pick, re-trim or rewrite any of the 176 catalogue `video:` blocks — P75 §5.4
  argues against exactly that and this document supplies no new reason to.
- It does **not** create labels. Every figure in §7 comes from evidence that already existed and
  was unused.
- It does **not** resolve ops#338. It is designed so that it does not have to.
- It does **not** claim the current ranker is bad. It claims that until today **nobody could have
  known either way**, and that one of the two things the estate believed about the last change was
  false.

---

## Appendix A — reproduction

Every figure in §0, §1, §2 and §7 was produced from these inputs, in a scratch directory, with no
write to `~/dir` and no network:

```bash
# the two artefacts
cd ~/dir
git show e89079f:courses_v3/build/_runs_v3.json > /tmp/runs_before.json   # 8,626 candidates
cp courses_v3/build/_runs_v3.json               /tmp/runs_after.json      # 9,353 candidates

# labels: 251 learning points, 205 with an episode
python3 -c "import json;m=json.load(open('courses_v3/build/lp_episode_map.json'));print(len(m),sum(1 for v in m.values() if v.get('episode')))"

# the four label grades are read off the evidence prose:
#   P1  evidence starts 'recorded clip' AND contains 'agrees'      -> 133
#   P2  evidence starts 'recorded clip' without 'agrees'           ->  43
#   P3  evidence starts 'author citation in prose'                 ->  19
#   S   method == 'sibling-inference'                              ->  10

# windows: 176 video: blocks across catalog/*.yaml; 64 are exactly 0:00-8:00
```

`success@k` is *"the first candidate whose `ep` equals a labelled episode has rank ≤ k"*.
Temporal IoU is the 1-D intersection over union of `(start_s, end_s)` against the catalogue
window, **scored 0 when the episode differs** (never undefined — P75 §2.1 is right that IoU across
episodes is meaningless, so the harness treats a wrong episode as an explicit 0 at L3 and reports
L1 separately rather than pretending L3 alone is interpretable).
Significance is the **exact** two-sided McNemar (binomial on discordant pairs), not the
chi-squared approximation, because several cells have fewer than 10 discordant pairs.
Confidence intervals are paired bootstraps over learning points, 10,000 resamples, **seed 1**.

---

## Appendix B — sources

Every figure attributed to a source below was read from that source by the research pass that
produced this document. Where a number is a *published measurement* it is quoted as such; where
this document extrapolates from one, it says "estimate".

### B — incomplete labels, pooling, graded relevance, coarse-vs-fine truth

- **[B1]** Dietterich, T.G., Lathrop, R.H. & Lozano-Pérez, T. (1997). *Solving the multiple instance
  problem with axis-parallel rectangles.* Artificial Intelligence 89(1–2), 31–71. —
  https://doi.org/10.1016/S0004-3702(96)00034-3 · SVM formulations: Andrews, Tsochantaridis &
  Hofmann, *Support Vector Machines for Multiple-Instance Learning*, NIPS 2002 —
  https://papers.nips.cc/paper/2232-support-vector-machines-for-multiple-instance-learning
- **[B2]** Mintz, M., Bills, S., Snow, R. & Jurafsky, D. (2009). *Distant supervision for relation
  extraction without labeled data.* ACL-IJCNLP 2009. — https://aclanthology.org/P09-1113/
- **[B3]** Schindler, D. et al. *Distant supervision for silver label generation of software
  mentions in social scientific publications.* CEUR-WS Vol-2414. —
  https://ceur-ws.org/Vol-2414/paper3.pdf
- **[B4]** Craswell, N., Mitra, B., Yilmaz, E., Campos, D. & Voorhees, E. (2020). *Overview of the
  TREC 2019 Deep Learning Track.* arXiv:2003.07820. — https://arxiv.org/pdf/2003.07820 ·
  https://trec.nist.gov/pubs/trec28/papers/OVERVIEW.DL.pdf
- **[B5]** Buckley, C. & Voorhees, E.M. (2004). *Retrieval evaluation with incomplete information.*
  SIGIR '04, 25–32. — https://tsapps.nist.gov/publication/get_pdf.cfm?pub_id=150469
- **[B6]** Zobel, J. (1998). *How reliable are the results of large-scale information retrieval
  experiments?* SIGIR '98, 307–314. —
  https://people.eng.unimelb.edu.au/jzobel/fulltext/sigir98.pdf ·
  https://dl.acm.org/doi/10.1145/290941.291014
- **[B7]** Buckley, C., Dimmick, D., Soboroff, I. & Voorhees, E. (2007). *Bias and the limits of
  pooling for large collections.* Information Retrieval 10, 491–508. —
  https://tsapps.nist.gov/publication/get_pdf.cfm?pub_id=51236
- **[B8]** Bajaj, P. et al. (2016). *MS MARCO: A Human Generated MAchine Reading COmprehension
  Dataset.* arXiv:1611.09268. — https://arxiv.org/abs/1611.09268
- **[B9]** Mackenzie, J., Petri, M. & Moffat, A. (2021). *A Sensitivity Analysis of the MSMARCO
  Passage Collection.* arXiv:2112.03396. — https://arxiv.org/pdf/2112.03396
- **[B10]** Arabzadeh, N., Vtyurina, A., Yan, X. & Clarke, C.L.A. (2022). *Shallow pooling for
  sparse labels.* Information Retrieval Journal 25, 365–385. — https://arxiv.org/abs/2109.00062 ·
  https://doi.org/10.1007/s10791-022-09411-0
- **[B11]** *(the counterweight to [B10] — same paper as [B9], cited in both roles.)*
- **[B12]** Thakur, N., Reimers, N., Rücklé, A., Srivastava, A. & Gurevych, I. (2021). *BEIR: A
  Heterogenous Benchmark for Zero-shot Evaluation of Information Retrieval Models.* NeurIPS 2021
  Datasets & Benchmarks. — https://arxiv.org/abs/2104.08663
- **[B13]** Sakai, T. (2007). *Alternatives to Bpref.* SIGIR '07, 71–78. —
  https://dl.acm.org/doi/10.1145/1277741.1277756
- **[B14]** Järvelin, K. & Kekäläinen, J. (2002). *Cumulated gain-based evaluation of IR
  techniques.* ACM TOIS 20(4), 422–446. —
  https://faculty.cc.gatech.edu/~zha/CS8803WST/dcg.pdf · https://dl.acm.org/doi/10.1145/582415.582418
- **[B15]** Voorhees, E., Soboroff, I. & Lin, J. (2022). *Can Old TREC Collections Reliably Evaluate
  Modern Neural Retrieval Models?* arXiv:2201.11086. — https://arxiv.org/abs/2201.11086
- **[B16]** Lipani, A., Lupu, M. & Hanbury, A. (2015). *Splitting Water: Precision and
  Anti-Precision to Reduce Pool Bias.* SIGIR '15, 103–112. —
  https://doi.org/10.1145/2766462.2767749 · open follow-up (*Fixed-Cost Pooling Strategies*):
  https://discovery.ucl.ac.uk/id/eprint/10083262/13/Lipani_Fixed-Cost%20Pooling%20Strategies_AAM.pdf
- **[B17]** Lin, Y., Ji, H., Liu, Z. & Sun, M. (2018). *Denoising Distantly Supervised Open-Domain
  Question Answering.* ACL 2018. — https://aclanthology.org/P18-1161/ · and Chen, D., Fisch, A.,
  Weston, J. & Bordes, A. (2017). *Reading Wikipedia to Answer Open-Domain Questions.* ACL 2017. —
  https://aclanthology.org/P17-1171/

### C — temporal grounding, moment retrieval, boundary agreement, podcast IR

- **[C1]** Gao, J., Sun, C., Yang, Z. & Nevatia, R. (2017). *TALL: Temporal Activity Localization
  via Language Query.* ICCV 2017, 5267–5275. — https://arxiv.org/abs/1705.02101
- **[C2]** Hendricks, L.A., Wang, O., Shechtman, E., Sivic, J., Darrell, T. & Russell, B. (2017).
  *Localizing Moments in Video with Natural Language* (DiDeMo). ICCV 2017. —
  https://arxiv.org/abs/1708.01641
- **[C3]** Krishna, R., Hata, K., Ren, F., Fei-Fei, L. & Niebles, J.C. (2017). *Dense-Captioning
  Events in Videos* (ActivityNet Captions). ICCV 2017, 706–715. — https://arxiv.org/abs/1705.00754
- **[C4]** Lei, J., Berg, T.L. & Bansal, M. (2021). *Detecting Moments and Highlights in Videos via
  Natural Language Queries* (QVHighlights, Moment-DETR). NeurIPS 2021. —
  https://arxiv.org/abs/2107.09609
- **[C5]** *(the R@n,IoU@m definition as formalised in [C7], Eq. 1.)*
- **[C6]** Otani, M., Nakashima, Y., Rahtu, E. & Heikkilä, J. (2020). *Uncovering Hidden Challenges
  in Query-Based Video Moment Retrieval.* BMVC 2020. — https://arxiv.org/abs/2009.00325 ·
  https://mayu-ot.github.io/hidden-challenges-MR/
- **[C7]** Yuan, Y., Lan, X., Wang, X., Chen, L., Wang, Z. & Zhu, W. (2021). *A Closer Look at
  Temporal Sentence Grounding in Videos: Dataset and Metric.* HuMA '21 @ ACM MM. —
  https://arxiv.org/abs/2101.09028 · journal version: Lan, X. et al., ACM TOMM 2022 —
  https://arxiv.org/abs/2203.05243
- **[C8]** Sigurdsson, G.A., Russakovsky, O. & Gupta, A. (2017). *What Actions are Needed for
  Understanding Human Actions in Videos?* ICCV 2017. — https://arxiv.org/abs/1708.02696
- **[C9]** Xiao, J., Yao, A., Li, Y. & Chua, T.-S. (2024). *Can I Trust Your Answer? Visually
  Grounded Video Question Answering* (NExT-GQA, IoP). CVPR 2024. — https://arxiv.org/abs/2309.01327
- **[C10]** Jones, R., Carterette, B., Clifton, A., Eskevich, M., Jones, G.J.F., Karlgren, J.,
  Pappu, A., Reddy, S. & Yu, Y. (2020). *TREC 2020 Podcasts Track Overview.* NIST SP 1266. —
  https://arxiv.org/abs/2103.15953 · https://trec.nist.gov/pubs/trec29/papers/OVERVIEW.P.pdf ·
  https://trecpodcasts.github.io/
- **[C11]** Karlgren, J. et al. (2021). *TREC 2021 Podcasts Track Overview.* TREC-30. —
  https://trec.nist.gov/pubs/trec30/papers/Overview-Pod.pdf
- **[C12]** Munakata, H., Nishimura, T., Nakada, S. & Komatsu, T. (2025). *Language-based Audio
  Moment Retrieval.* ICASSP 2025. — https://arxiv.org/abs/2409.15672 · DCASE 2026 Task 6 —
  https://dcase.community/challenge2026/task-audio-moment-retrieval-from-long-audio
- **[C13]** Huang, J., Jin, H., Gong, S. & Liu, Y. (2022). *Video Activity Localisation with
  Uncertainties in Temporal Boundary* (EMB). ECCV 2022, LNCS 13694, 724–740. —
  https://arxiv.org/abs/2206.12923

### D — sample size, significance testing, agreement, pooling effort, reusability

- **[D1]** Voorhees, E.M. & Buckley, C. (2002). *The effect of topic set size on retrieval
  experiment error.* SIGIR '02, 316-323. — https://dl.acm.org/doi/10.1145/564376.564432
  · Sanderson, M. & Zobel, J. (2005). *Information retrieval system evaluation: effort,
  sensitivity and reliability.* SIGIR '05 — https://dl.acm.org/doi/10.1145/1076034.1076064
  · Webber, W., Moffat, A. & Zobel, J. (2008). *Statistical power in retrieval experimentation.*
  CIKM '08 — https://dl.acm.org/doi/10.1145/1458082.1458146
- **[D2]** Sakai, T. (2016). *Topic set size design.* Information Retrieval Journal 19(3), 256-283.
  — https://link.springer.com/article/10.1007/s10791-015-9273-z
- **[D3]** Smucker, M.D., Allan, J. & Carterette, B. (2007). *A comparison of statistical
  significance tests for information retrieval evaluation.* CIKM '07, 623-632. —
  https://dl.acm.org/doi/10.1145/1321440.1321528
- **[D4]** McNemar, Q. (1947). *Note on the sampling error of the difference between correlated
  proportions or percentages.* Psychometrika 12(2), 153-157. —
  https://link.springer.com/article/10.1007/BF02295996
- **[D5]** Webber, W., Moffat, A. & Zobel, J. (2010). *A similarity measure for indefinite
  rankings.* ACM TOIS 28(4), Article 20. — https://dl.acm.org/doi/10.1145/1852102.1852106 ·
  author PDF: http://www.williamwebber.com/research/papers/wmz10_tois.pdf
- **[D6]** Voorhees, E.M. (2000). *Variations in relevance judgments and the measurement of
  retrieval effectiveness.* Information Processing & Management 36(5), 697-716. —
  https://www.sciencedirect.com/science/article/abs/pii/S0306457300000105
- **[D7]** Landis, J.R. & Koch, G.G. (1977). *The measurement of observer agreement for categorical
  data.* Biometrics 33(1), 159-174. — https://www.jstor.org/stable/2529310 · Cohen, J. (1960).
  *A coefficient of agreement for nominal scales.* Educational and Psychological Measurement 20(1),
  37-46. — https://journals.sagepub.com/doi/10.1177/001316446002000104
- **[D8]** Krippendorff, K. (2004/2018). *Content Analysis: An Introduction to Its Methodology*,
  ch. 11-12 (reliability). Sage. · *Computing Krippendorff's Alpha-Reliability* —
  https://repository.upenn.edu/asc_papers/43/
- **[D9]** Krippendorff, K. (1995). *On the reliability of unitizing continuous data.* Sociological
  Methodology 25, 47-76. — https://www.jstor.org/stable/271061 · extended in Krippendorff, K.,
  Mathet, Y., Bouvry, S. & Widlöcher, A. (2016). *On the reliability of unitizing textual continua:
  further developments.* Quality & Quantity 50, 2347-2364. —
  https://link.springer.com/article/10.1007/s11135-015-0266-1
  *(Both are paywalled; the figures used here come from the open §12.4 treatment in [D8].)*
- **[D10]** Carterette, B., Allan, J. & Sitaraman, R. (2006). *Minimal test collections for
  retrieval evaluation.* SIGIR '06, 268-275. — https://doi.org/10.1145/1148170.1148219
- **[D11]** Aslam, J.A., Pavlu, V. & Yilmaz, E. (2006). *A statistical method for system evaluation
  using incomplete judgments.* SIGIR '06, 541-548 (statAP). —
  https://dl.acm.org/doi/10.1145/1148170.1148263 · Yilmaz, E., Kanoulas, E. & Aslam, J.A. (2008).
  *A simple and efficient sampling method for estimating AP and NDCG* (xinfAP). SIGIR '08 —
  https://dl.acm.org/doi/10.1145/1390334.1390419
- **[D12]** Cormack, G.V., Palmer, C.R. & Clarke, C.L.A. (1998). *Efficient construction of large
  test collections.* SIGIR '98, 282-289 (move-to-front pooling). —
  https://dl.acm.org/doi/10.1145/290941.291009
- **[D13]** Dwork, C., Feldman, V., Hardt, M., Pitassi, T., Reingold, O. & Roth, A. (2015).
  *The reusable holdout: Preserving validity in adaptive data analysis.* Science 349(6248),
  636-638. — https://www.science.org/doi/10.1126/science.aaa9375
- **[D14]** Roelofs, R., Fridovich-Keil, S., Miller, J., Shankar, V., Hardt, M., Recht, B. &
  Schmidt, L. (2019). *A Meta-Analysis of Overfitting in Machine Learning.* NeurIPS 2019. —
  https://papers.nips.cc/paper/2019/hash/ee39e503b6bedf0c98c388b7e8589aca-Abstract.html
- **[D15]** Sanderson, M. (2010). *Test Collection Based Evaluation of Information Retrieval
  Systems.* Foundations and Trends in Information Retrieval 4(4), 247-375, §6.1 (provenance of the
  τ ≥ 0.9 convention). — https://doi.org/10.1561/1500000009
- **[D16]** Sanderson, M. & Soboroff, I. (2007). *Problems with Kendall's tau.* SIGIR '07, 839-840.
  — https://dl.acm.org/doi/10.1145/1277741.1277935
- **[D17]** Losada, D.E., Parapar, J. & Barreiro, Á. (2017). *Multi-armed bandits for adjudicating
  documents in pooling-based evaluation of information retrieval systems.* IP&M 53(5), 1005-1025.
  — https://www.sciencedirect.com/science/article/abs/pii/S0306457317300602
- **[D18]** Rahman, M.M., Kutlu, M. & Lease, M. (2020). *Constructing test collections using
  multi-armed bandits and active learning.* ICTIR '20. —
  https://dl.acm.org/doi/10.1145/3409256.3409824
- **[D19]** Carterette, B., Pavlu, V., Kanoulas, E., Aslam, J.A. & Allan, J. (2008). *Evaluation
  over thousands of queries.* SIGIR '08, 651-658 (cost optimum; *"reusability … is impossible"*).
  — https://dl.acm.org/doi/10.1145/1390334.1390445
- **[D20]** Carterette, B. & Soboroff, I. (2010). *The effect of assessor errors on IR system
  evaluation.* SIGIR '10, 539-546. — https://dl.acm.org/doi/10.1145/1835449.1835540 ·
  and the preference-vs-graded timing comparison in the preference-judgement literature
  (see [B10] for the crowd-cost anchor: **500 queries, mean pool 6.32, $1,022**).
- **[D21]** Recht, B., Roelofs, R., Schmidt, L. & Shankar, V. (2019). *Do ImageNet Classifiers
  Generalize to ImageNet?* ICML 2019. — https://arxiv.org/abs/1902.10811 · and *Do CIFAR-10
  Classifiers Generalize to CIFAR-10?* — https://arxiv.org/abs/1806.00451
- **[D22]** Carterette, B., Pavlu, V., Fang, H. & Kanoulas, E. (2009/2010). *Million Query Track
  Overview.* TREC-18/19 — the designed reusability experiment. —
  https://trec.nist.gov/pubs/trec18/papers/MQ09OVERVIEW.pdf
- **[D23]** Freund, Y., Seung, H.S., Shamir, E. & Tishby, N. (1997). *Selective sampling using the
  query by committee algorithm.* Machine Learning 28, 133-168 — the theory behind "label where the
  committee disagrees", including its own negative result that the guarantee is conditional. —
  https://link.springer.com/article/10.1023/A:1007330508534

**Figures deliberately NOT quoted, having failed verification:** statAP's headline *"4% of the
pool"* (appears only in that paper's abstract and conclusion; the experiments report 1.7% and
11.5%, which is what §3.4 uses) · Cormack et al.'s relevant-document gain (figures only, no stated
percentage in the text — §3.4 therefore cites [D12]'s ρ result and [B7]'s independent
re-measurement instead) · MTC's *"under three hours"* (that is **wall-clock with six annotators in
parallel = 15 annotator-hours**; §3.4 quotes the annotator-hours) · the specific per-competition
statistics in [D14] · Voorhees's *"65% precision at 65% recall"* ceiling (attributed to [D6] by
secondary sources but not located in it) · Yilmaz et al.'s τ_AP paper (no accessible copy obtained;
no numbers from it appear here).

### Sources deliberately NOT used, and why

- **`bpref` / condensed lists** [B5, B13] — designed for many relevant items per topic; this corpus
  has one episode per learning point. §1.5 explains.
- **`dR@n,IoU@m`** [C7] — the right metric once a Stage B trimmer emits variable-length windows;
  today it would penalise a known fixed-bucket property rather than reveal anything. §2.2.
- **Published per-judgement timing figures** — the research pass did not establish a reliable
  published rate for how long a relevance judgement takes, and none is asserted here. The hour
  estimates in §3.4 are labelled estimates and are anchored on P75 §4.4's own measured reading
  rates and on [B10]'s measured crowd cost, not on a literature figure.
