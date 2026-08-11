# P76 — Clip retrieval: hybrid recall, inspectable ordering

**Status:** PROPOSED — research and design only. No production code, no schema, no live
write, no catalogue `video:` block touched by this document.
**Owner:** *(unassigned)*
**Issue:** `nwp/ops#349`
**Sibling:** `nwp/ops#337` / **P75** — P75 is the
*guild process* (who reviews a clip, and how). **P76 is the engine** (which clips get offered
to them). They are independent: P75 ships without P76 and vice versa.
**Predecessors:** [P64](P64-clip-choice-as-data-not-content.md) (clip choice as data) ·
`~/dir/courses_v3/build/CRITERIA-V3-ADDENDUM.md` · `~/dir/courses_v3/history/corpus_v2/CRITERIA.md`
**Estimated effort:** Phase 1 ≈ 2 days · Phases 1–3 ≈ 6–8 days · full arc ≈ 12–15 days

---

## CORRECTION 1 — 2026-08-11, post-publication. The "112 hand-chosen spans" were not hand-chosen.

> This block is deliberately at the top and deliberately not a silent edit. The first
> version of this document called the 112 non-default catalogue `video:` windows a
> **passage-level human gold set** and built §2.3, §2.4, §7's L3 target and part of the
> §9 sequencing on that. **The operator says he did not pick them, and the evidence says
> he is right.** They are output of an AI authoring pass on **2026-03-08**. Grading a
> ranker against them measures the 2026-03-08 algorithm against itself — the same
> self-grading defect this document already identified once, in §2.2, for the
> `source: provenance` injection.

**How they were made — measured, not inferred.** Full evidence chain in the correction
comment on `nwp/ops#349`; the four load-bearing facts:

1. **All 107 distinct non-default windows appear *verbatim* in a predecessor prose
   document**, `~/dir/courses_v3/reference/predecessors/MOODLE_STANDALONE_COURSES.md`
   (mtime **2026-03-08 14:47**), as lines of the form
   `**Video:** Ep 645 | 6:56-8:55 (~2 min) — Dan Burke names the Universal Call … Embedded MCQ at 7:30: …`.
   `extract_learning_points.py:100` is a **regex scrape** of exactly that pattern — no
   scoring, no matching, no boundary logic — and running that regex over that document
   yields **exactly 112 matches**, exactly the 112 blocks. Nothing in the catalogue is
   absent from the document; no window has ever been edited since
   (`git log` on `courses_v3/catalog/` shows one video-field change ever, a D6→D9 copy).

2. **The operator commissioned the pass, in writing.** `~/.claude/prompts.log`,
   `[2026-03-08T09:07:50]`: *"Now go through all the episodes … Then find the best examples
   of the explanations within all the episodes … The second which has the explanation plus
   the key video snippets where each point is explained the best."* And
   `[2026-03-08T11:19:08]`: *"… Videos can be up to 7 minutes but ideally about 2-4 minutes."*

3. **The start times are machine-read off a transcript, and we can tell which one.** Against
   `transcripts/whisper_large/` — the INT8 Whisper run that landed at **2026-03-08 07:36**,
   seven hours before the document was written — **83 of 112 start times (74 %) fall within
   ±0.5 s of a transcript segment start** and **105 of 112 (94 %) within ±1.0 s**, against
   measured nulls of 26 % and 46 % (**z = +11.8** and **z = +10.1**). Against the *later*
   transcript generations (`whisper_large_fp16` 2026-03-24, `whisper_merged` 2026-04-15,
   both re-segmented) the same test collapses to 48 % and 50 % — which is why an earlier
   pass of this analysis, run only against `whisper_merged`, wrongly concluded the windows
   were *not* transcript-derived. **End** times show no alignment at all (26 %, z = −0.2);
   **78 of 112 (70 %) end on an exact minute.** A listener cannot hear an ASR segment
   boundary. The signature is: *start copied from a transcript line, end rounded off.*

4. **The negative control behaves.** The 64 default `0:00–8:00` blocks show start alignment
   of **1/64 (2 %, z = −4.5)** — no alignment — and their content relevance to their own
   learning point sits at the **53rd percentile** of same-length windows in the same episode,
   i.e. chance. The 112 sit at the **89th percentile median**. So the pass *did* read the
   corpus for the 112 and *did not* for the 64.

**What this invalidates in this document.**

| claim | status |
|---|---|
| "112 are genuinely hand-chosen spans" (§2.3) | **FALSE** — corrected in place below |
| "the author's own picks are **median 1:45**" (§2.3, and repeated in the ops#349 summary) | **FALSE as stated.** 1:45 is the *AI pass's* output distribution. The **author's** recorded target is *"up to 7 minutes but ideally about 2-4 minutes"* — the opposite end. |
| "the retrieval unit is **3.7× too long**" (§2.4) | **NOT ESTABLISHED, and possibly backwards.** The 3.7× is measured against the AI pass's own median. Against the operator's recorded 2–4 min ideal, today's 394 s top-1 median is ≈1.6–3.3× the ideal band and *inside* his 7-minute maximum. |
| "a *passage-level* gold set … the most valuable asset in this problem" (§2.3) | **FALSE.** It is a machine artefact of the same family as the system under test. |
| every IoU / coverage / mIoU number computed against the 112 | **Arithmetic still correct; the *interpretation* is void.** They describe agreement with a 2026-03-08 model, not accuracy. |
| §2.1 (injection), §2.5 (corpus), §3 (pilot), §4 (literature), §5 (determinism), §6 (inspectability) | **Unaffected** — none of them uses the 112 as truth. |

**What survives, and it is the useful part.** §2.4's *diagnosis* does not depend on the 112:
`bucket_center` demonstrably rewards the midpoint of the `xxl` bucket and puts 19 of 251 top
picks over 15 minutes. That is a defect against the **operator's** stated ≤7-minute ceiling,
which is a real human instruction on the record. The unit is still wrong; the *target* is
2–4 minutes, not 105 seconds.

**Two integrity defects found while establishing the above, both new and both fixable without
any relevance judgement:**

- **61 of the 176 blocks specify an end time beyond the length of the YouTube video their own
  `youtube_id` names.** All 176 `youtube_id`s are a `difflib` **fuzzy title match** from
  `dir_sd_map.json` at `threshold: 0.4` (median score 0.613; 62 of 108 episodes below 0.7).
  **15 YouTube IDs are claimed by more than one episode** — `BpBHuteO4iM` by eight
  (285, 286, 287, 289, 290, 295, 298, 300). Ep 9's block says `1:37–5:00`; the video it
  points at is **36 seconds long**. The timestamps are on the *podcast* timeline; the link
  is to a *different recording*.
- **Two windows do not exist at all**: `B2.yaml` ep 600 `31:25–32:55` in an episode 28:51
  long, and `C1.yaml` ep 398 `26:23–28:00` in an episode 27:16 long.

---

## 0. How to read this document

Every number below is either **MEASURED** (the command that produced it is given, and it was
run on this estate on 2026-08-11), **CITED** (someone else's published measurement, with a
URL), or **ESTIMATE** (labelled as such, with the reasoning). There are no unlabelled
performance claims, and nothing in §4 says a technique *will* work here — §7 says what has to
be measured before anyone believes it.

The pilot in §3 ran entirely on the estate's own GPU build host. **No corpus text left the estate**,
which the rights position (`derivative-cleared-pending`, password-gated) requires.

---

## 1. The problem, and why the previous fix was right but insufficient

251 curriculum learning points must each be matched to the best short passage in a 648-episode
podcast corpus. The courses were **authored from this corpus**, so a good passage very likely
exists for most points.

> **CORRECTED (see CORRECTION 1).** The original sentence read *"so a good passage **provably**
> exists for nearly every point. This is retrieval with a known-good answer."* That is not
> proven and the measurement goes the other way. The learning-point prose is **paraphrase, not
> quotation**: indexing every word-timed 6-gram of all 648 episodes and matching it against
> each learning point's `title` + `short.summary` + `standard.text`, the **median learning
> point has a longest verbatim overlap with the corpus of ZERO words**. Only **22 of 251** have
> a maximal verbatim span of ≥10 words that resolves to one or two episodes; only 10 reach 14
> words. So for 229 of 251 points there is no *provable* answer — only a plausible one. This is
> retrieval **without** a known-good answer, which is the whole difficulty and is why §7's
> harness matters more than any single ranker in §4.

`scripts/lp_taxonomy.py` + `scripts/extract_courses_v3.py` build a per-LP term list, count
occurrences, detect "runs", and score each run with a 16-part hand-weighted composite
(`CRITERIA.md`: density, breadth, title match, clean opener/ender, penalties for ads and
serial markers). Every candidate carries its 16 `q_parts`, so a reviewer can ask *"why this
one?"* and get an answer. **That property is doctrine and this proposal does not weaken it** —
see §6.

P75 Fix A (`~/dir` commit `c22dfbd`, 2026-08-11) made the term lists read the learning point's
own prose instead of only its title. It is a good change, honestly reported, and its own
commit message states the limit:

> LPs sharing a top candidate with a sibling 193 → 127 of 251
> provenance episode is the top candidate 21/205 → **22/205**

Separation improved by a third. **Agreement with the author's own recorded episode moved by
one.** The commit correctly scopes the remainder as "Fix B — an editorial pass". This proposal
argues Fix B is not, or not only, editorial: three measurements below show the losses are in
the **retrieval unit** and the **ordering stage**, neither of which more term work can reach.

---

## 2. The measured state — five findings, three of which are new

All commands run against `~/dir` at `c22dfbd`, 2026-08-11.

### 2.1 The baseline, replicated exactly

Scoring `courses_v3/build/_runs_v3.json` against
`courses_v3/build/lp_episode_map.json` (`method: provenance` 195 + `sibling-inference` 10 =
**205** labelled learning points):

| metric | value |
|---|---|
| episode is the **top** candidate | **22 / 205 = 10.7 %** |
| episode in top 3 | 43 / 205 = 21.0 % |
| episode in top 5 | 60 / 205 = 29.3 % |
| episode in top 8 | 87 / 205 = 42.4 % |
| episode in top 20 | 138 / 205 = 67.3 % |
| episode anywhere in the 40-candidate pool | 167 / 205 = 81.5 % |
| **episode MRR@10** | **0.192** |

This reproduces the figures in `c22dfbd`'s commit message to the unit, so the harness is
measuring the same thing the build reports.

### 2.2 NEW — 13 of the 22 top-1 hits were handed to the builder

`extract_courses_v3.py` builds three candidate pools (`CRITERIA-V3-ADDENDUM.md` §3). One of
them, `source: provenance`, is drawn **from the LP's recorded provenance episode only**, at a
relaxed entry floor. That is a defensible product decision — it guarantees the reviewer sees
something from the right episode. It is **not** defensible as evaluation input, and it has
been silently inflating the headline number:

```
candidate sources: corpus 9125 · provenance 228
of the 167 pool hits@40: reachable by the corpus-wide search = 132
                         only present because the gold episode was injected =  35
top-1 hits that are injected candidates: 13 of 22
```

**Corpus-wide, unassisted, the current ranker's top-1 is 9 / 205 = 4.4 %**, and its
recall@40 is 132 / 205 = 64.4 %. The 10.7 % and 81.5 % figures measure a system that was told
part of the answer.

This is the estate's own "swallowed verdict" shape (CLAUDE.md: *a check that has never been
proven to fail is not a check*) — a measurement that cannot go below a floor set by the label
itself. Nothing here was done in bad faith; the pools are documented. But **every comparison
in this proposal is against the corpus-wide number**, and any future eval harness must
exclude `source != corpus` candidates or it will grade itself.

### 2.3 CORRECTED — the passage-level "gold set" is a 2026-03-08 machine artefact

> **This section originally read "NEW — there is a passage-level gold set, and it has never
> been scored against", and called the 112 windows "genuinely hand-chosen spans … the most
> valuable asset in this problem". Both claims are withdrawn.** See CORRECTION 1 at the top
> for the evidence. What follows is the corrected version; the counts are unchanged because
> the counts were never the error.

The provenance map records only an episode. The catalogue records more. Across the 56 course
files:

- **176 learning points carry a `depths.standard.video` block with an exact
  `episode` + `start` + `end`.**
- **64 of those are placeholders** — `start: 0`, duration exactly `08:00`. Measured: their
  content relevance to their own learning point is at the **53rd percentile** of same-length
  windows in the same episode, i.e. indistinguishable from chance, and `CRITERIA.md`'s own
  `intro_position` rule scores them negative because they land in the show intro.
- **112 carry a specific window.** Median **105.5 s**, mean 118 s, range 32–241 s. These are
  **AI output from 2026-03-08**, regex-scraped verbatim out of
  `MOODLE_STANDALONE_COURSES.md` by `extract_learning_points.py:100`. Their start times sit
  on `whisper_large` segment boundaries 94 % of the time (±1.0 s, null 46 %, **z = +10.1**);
  their end times are at chance and 70 % land on an exact minute.

**They are a `silver` label set of the worst kind for this purpose: produced by the ancestor
of the system under test.** They can be used as a *consistency* baseline — "did this change
alter behaviour a lot?" — and must never be used as an *accuracy* score.

**They did NOT correct the brief; the original correction was itself the error.** The target
unit is widely described as "2–4 minutes" and **that description is right, because it is the
operator's own recorded instruction** (`~/.claude/prompts.log`, `[2026-03-08T11:19:08]`:
*"Videos can be up to 7 minutes but ideally about 2-4 minutes"*). The 105 s median is the
2026-03-08 model **undershooting** that instruction — only 1 of 112 windows exceeds 4 minutes
and none reaches 7. Design for the operator's **2–4 min ideal with a 7 min ceiling**, not for
~90–180 s.

Scoring the current pool against those 112 spans (a hit = same episode, and the candidate
covers ≥ 50 % of the span) — **read as agreement with the 2026-03-08 pass, not as accuracy**:

| metric | value |
|---|---|
| top-1 covers the recorded span | **7 / 112 = 6.2 %** |
| any of the 40 candidates covers it | 61 / 112 = 54.5 % |

### 2.4 CORRECTED — the retrieval unit is too long, but not by "3.7×"

> **The heading originally read "the retrieval unit is 3.7× too long".** The 3.7× was measured
> against the 112 machine windows, so it is a ratio to another algorithm's preference, not to a
> requirement. **Withdrawn as a factor.** The *defect* is unaffected and is measured against a
> real human instruction: the operator's recorded target is **2–4 minutes ideal, 7 minutes
> maximum**; today's top-1 median is **394 s = 6 min 34 s**, at the very top of his ceiling and
> well outside his ideal band, and **19 of 251 top picks exceed 15 minutes**, i.e. more than
> double the stated maximum. Read the `gold span duration` row below as *"what the 2026-03-08
> pass emitted"*, not as a target.

| | value |
|---|---|
| top-1 candidate duration, median | **394 s** |
| top-1 candidate duration, mean | 442 s |
| top-1 candidates landing in the 120–240 s band | 51 of 251 |
| top-1 candidates ≥ 900 s (the `xxl` bucket) | 19 |
| gold span duration, median | **105.5 s** |
| when a covering candidate exists, its duration ÷ gold duration | **3.7× median, 4.6× mean** |

The `bucket_center` term of the composite actively rewards the midpoint of whatever bucket a
run falls into — 18 minutes for `xxl`. The system is not choosing bad *material*; over half the
time the right material is somewhere in the pool. It is choosing the wrong *unit*, and then a
reviewer has to find the 105 seconds inside a 6-minute clip by hand.

### 2.5 The corpus, measured

`transcripts/whisper_merged/` — 648 episodes, **291,599 segments**, mean 3.37 s / 55.1 chars,
**2,987,435 words**, 295.6 hours, mean episode 27.4 min. **291,542 of 291,599 segments carry
word-level timings** (99.98 %) — so any boundary this proposal proposes can be expressed as an
exact timestamp.

### 2.6 NEW (CORRECTION 1 follow-up) — the best correlation obtainable with no trustworthy labels

The operator's instruction on being told the gold set was machine-made:

> *"You need to work out the best correlation for now until we get humans into the loop and
> that's part of phase 2. So do the best you can for now."*

**Step 1 — inventory what is left after the circularity is subtracted.** Measured from
`~/dir/courses_v3/build/lp_episode_map.json` (n = 251) by its own `evidence` strings:

| label source | n | independent of the 2026-03-08 clip pass? |
|---|---|---|
| `provenance` — *"recorded clip in `depths.standard.video`"* | **176** | **NO — it *is* the 2026-03-08 pass** |
| `provenance` — *"author citation in prose"* (e.g. `Ep 156`) | **19** | partly — same authoring programme, but written to cite a source, not to pick a clip; attests the **episode** only, never the window |
| `sibling-inference` (self-flagged *"verify before publishing"*) | 10 | no |
| `none` | 46 | n/a |

Zero entries carry both a clip and a prose citation in the same evidence string, so
**176 of the 195 `provenance` labels — 90 % — are the artefact under test.** This is the same
defect as §2.2's injected candidates, one layer up: there the *candidates* were seeded from the
recorded episode; here the *labels* are.

**Step 2 — build a label set that cannot be circular.** A verbatim string match between the
catalogue prose and a word-timed transcript is *self-evidencing*: whoever wrote the prose, the
fact that a 14-word sequence occurs in ep 16 at 04:11 is a property of the corpus, checkable
deterministically by anyone, and independent of anybody's judgement. Indexing every 6-gram of
all 648 episodes with word-level timings and extending each seed to its maximal verbatim span:

| | n of 251 |
|---|---|
| longest verbatim span with the corpus, **median across all LPs** | **0 words** |
| ≥1 maximal verbatim span of ≥10 words resolving to ≤2 episodes | **22** |
| …of ≥14 words | 10 |
| of the 22, also carrying a recorded `video:` block | 12 |
| — anchor's episode **agrees** with the recorded episode | **9 of 12 (75 %)** |

Two things follow, and they point in opposite directions. **The 2026-03-08 pass got the
*episode* mostly right** where we can check it independently — 75 %, though on n = 12, whose 95 %
CI is [50 %, 100 %] and therefore excludes almost nothing. And **the prose is paraphrase, not
quotation** — the median learning point shares no six consecutive words with the corpus at all,
so this method cannot be scaled to the full 251 by relaxing thresholds. It yields 22, not 205.

**Step 3 — the measurement that answers the operator's question.** Two rankers, identical code
path, differing only in the retrieval unit, scored on **both** label sets. Local, CPU, BM25
only, no dense component, no GPU, no corpus leaving the estate
(`k1=0.9, b=0.4`, query = `title + short.summary + standard.text`, MaxP aggregation to episode):

| ranker | label set | R@1 | R@8 | R@40 |
|---|---|---|---|---|
| **A** whole-episode BM25 (648 units) | CIRCULAR, n=176 | 18.8 % [13–25] | 43.8 % [36–51] | 61.9 % [55–69] |
| **B** 150 s windows, stride 75 s, MaxP (14,303 units) | CIRCULAR, n=176 | 17.0 % [11–23] | **51.7 %** [44–59] | 65.3 % [58–72] |
| **A** whole-episode BM25 | INDEPENDENT, n=22 | 45.5 % [25–66] | 72.7 % [54–91] | 81.8 % [66–98] |
| **B** 150 s windows, MaxP | INDEPENDENT, n=22 | **50.0 %** [29–71] | **77.3 %** [60–95] | **86.4 %** [72–100] |

*(95 % normal-approximation intervals. This is an independent local replication, not the §3
pilot; the denominators and query construction differ, so the absolute numbers are not
comparable to §3.1's and are not offered as such.)*

**Read the table down the columns, not across the rows.** Chunking moves R@8 by +7.9 points on
one label set and +4.6 on the other, and every interval overlaps. **Changing which label set you
believe moves R@1 from 17 % to 50 % — nearly three-fold, and far more than any ranker change in
this document.** That is the honest state of the art here: *the measurement instrument is the
dominant term.*

**Step 4 — what may therefore be claimed in phase 1.**

- **CLAIMABLE.** Referential and arithmetic defects, which need no relevance judgement at all:
  two windows that lie outside their episode; 61 blocks whose end exceeds the length of their
  own linked video; 15 `youtube_id`s claimed by 2–8 episodes; 64 windows measured at the 53rd
  percentile of chance. Every one of these is verifiable by construction and every fix is a
  guaranteed improvement.
- **CLAIMABLE.** Recall, at large *k*, as a *containment* property — "the right material is
  somewhere in the pool" — because that direction is robust to a noisy label: a label that is
  merely *plausible* still tells you the pool missed something when it misses.
- **NOT CLAIMABLE, and this is the answer to the operator's question.** *Which of two rankers
  orders better.* At n = 22 independent labels the minimum detectable effect exceeds the entire
  range of any change proposed in this document; at n = 176 the labels are the ancestor of the
  system being scored. **We can improve retrieval. We cannot yet prove which of two rankers is
  better.**
- **BEST AVAILABLE PROXY, and how far to trust it.** Report every ranking number **twice** —
  once against the CIRCULAR set, marked `CIRCULAR`, and once against the INDEPENDENT anchor set,
  marked `n=22`. Treat a change as *promising* only when both move the same way, and never
  quote either alone. Treat the CIRCULAR number strictly as a **regression detector**: a large
  move means behaviour changed a lot, never that it improved. This is the same discipline
  §7 already applies to `POOL-NAIVE`, extended to the labels themselves.
- **THE CHEAPEST WAY OUT is not more ranker work.** It is the G1 tranche in P77 §3.4: human
  window judgements. The anchor method above is also a *gold generator*, not only an evaluator —
  it identifies, with proof, the 22 learning points whose prose demonstrably came from a
  specific moment, which is the correct seed set to hand a human reviewer first because their
  answers can be checked.

---

## 3. The pilot — what was actually measured on this corpus

Everything in this section was run on the estate GPU build host (Strix Halo, gfx1151,
ollama 0.20.3) on 2026-08-11. Scripts are in the session scratchpad; they are throwaway measurement code, not a
proposed implementation.

**Setup.** Sliding windows over the Whisper segments, snapped to segment boundaries: target
150 s, stride 75 s (50 % overlap) → **13,957 passages**, median 152 s, median 428 words. The
150 s / 50 % geometry is not invented — it is TREC Podcasts' 2020/2021 segment definition
(120 s, 60 s step) widened to this corpus's gold median
([arXiv:2103.15953](https://arxiv.org/abs/2103.15953)).

**Baselines are corpus-wide and injection-free.** All 13,957 passages are searched every time.
Nothing is seeded from the gold episode.

### 3.1 Chunk size is the single biggest lever

BM25 only, verbose query, same code, only the window geometry changed. `psg IoU` = the
candidate overlaps the gold span with IoU ≥ 0.3 (which penalises *both* missing it and
swallowing it in a much longer clip).

| window / stride | passages | ep R@1 | ep R@5 | ep R@8 | ep MRR@10 | psg-IoU R@1 | psg-IoU R@8 |
|---|---|---|---|---|---|---|---|
| 60 s / 30 s | 33,024 | 21.0 % | 35.1 % | 43.4 % | 0.275 | 11.6 % | 28.6 % |
| 90 s / 45 s | 22,530 | 22.4 % | 37.6 % | 43.4 % | 0.293 | 17.0 % | 38.4 % |
| **150 s / 75 s** | **13,957** | 20.0 % | 41.5 % | 47.8 % | 0.287 | 17.0 % | 37.5 % |
| 240 s / 120 s | 9,043 | 19.5 % | 39.0 % | 45.9 % | 0.274 | 16.1 % | 38.4 % |
| 300 s / 150 s | 7,140 | 19.5 % | 38.0 % | 46.8 % | 0.277 | 18.8 % | 37.5 % |
| 600 s / 300 s | 3,866 | 19.0 % | 36.6 % | 45.4 % | 0.270 | **3.6 %** | 5.4 % |

Two things to read here. **Episode-level accuracy is nearly flat across 60–600 s** — so the
"which episode" question is insensitive to the unit. **Passage-level accuracy is not**, and it
collapses at 600 s exactly as it should: a 10-minute clip that contains the right 105 seconds
is not an answer. The usable band is **90–300 s**, which is where the human picks live.

Note also that the *coverage* metric (≥ 50 % of gold covered) rises monotonically with window
length — 60 s: 6.2 %, 600 s: 25.9 % — which is why it must not be used alone. A long-enough
window covers everything and answers nothing. **IoU is the honest metric; report both.**

### 3.2 Query construction — the verbose body hurts, measurably

BM25, 150 s windows, only the query text changed.

| query | ep R@1 | ep R@5 | ep R@40 | ep MRR@10 | psg-IoU R@1 |
|---|---|---|---|---|---|
| LP title only | 16.1 % | 25.4 % | 48.3 % | 0.203 | 8.0 % |
| **title + `short.summary`** | **26.3 %** | 41.0 % | 69.3 % | **0.323** | 17.0 % |
| `short.summary` only | 26.3 % | 41.0 % | 67.8 % | 0.323 | 15.2 % |
| title + summary + first 40 words of body | 24.4 % | 41.0 % | 66.8 % | 0.315 | 15.2 % |
| title + summary + full `standard.text` | 20.0 % | 41.5 % | 65.4 % | 0.287 | 11.6 % |
| title + summary + course tags | 22.9 % | 40.5 % | **72.7 %** | 0.306 | 13.4 % |

**Adding the body prose monotonically degrades rank-1** (26.3 → 24.4 → 20.0) while barely
moving R@5. Course tags do the opposite: they cost precision and buy the best recall@40 in the
table. This is a clean precision/recall split and it says the two legs should get *different*
queries — tags into the recall leg, title+summary into the ordering leg.

This is the classic verbose-query result and it is well documented. On topically coherent
newswire the verbose-query penalty is small or negative, but **early precision favours the
concise query**: Lease, Allan & Croft 2009 report W10g P@5 of 39.20 for `<desc>` vs 31.20 for
`<title>` in the *other* direction, and Huston & Croft (SIGIR 2010) measure **+105 % nDCG@5**
from removing "stop structure" — filler phrasing of the *"Students will understand that…"*
kind, which is exactly what curriculum prose is made of
([Huston & Croft 2010](https://ciir-publications.cs.umass.edu/pub/web/getpdf.php?id=930),
[Bendersky & Croft 2008](https://ciir-publications.cs.umass.edu/pub/web/getpdf.php?id=821)).
Oracle query reduction is worth up to +30–43 % MAP and automatic methods have only ever
captured about a quarter of it (Kumaran & Carvalho 2009; Lease et al. 2009), so **do not build
an automatic reducer** — use the fields the author already separated for you.

### 3.3 Dense, lexical, and hybrid — measured on this corpus

`BAAI/bge-m3` (568M, 1024-dim, 8192 ctx, MIT, no prefix required) via ollama on the GPU build host;
13,957 passages embedded in 15.5 min; exact (brute-force) cosine search, no ANN index.

| system | ep R@1 | ep R@5 | ep R@8 | ep R@20 | ep R@40 | ep MRR@10 | psg-IoU R@1 | psg-IoU R@8 | psg-IoU R@40 |
|---|---|---|---|---|---|---|---|---|---|
| current pipeline, corpus-wide (§2.2) | **4.4 %** | — | — | — | 64.4 % | — | — | — | — |
| current pipeline, as reported (§2.1) | 10.7 % | 29.3 % | 42.4 % | 67.3 % | 81.5 % | 0.192 | 6.2 % | — | 54.5 % |
| BM25, q = title+summary | **26.3 %** | 41.0 % | 45.9 % | 58.0 % | 69.3 % | **0.323** | 17.0 % | 37.5 % | 58.9 % |
| dense bge-m3, q = title+summary | 18.5 % | 40.0 % | 43.9 % | 57.6 % | 66.8 % | 0.267 | 16.1 % | 34.8 % | 53.6 % |
| dense bge-m3, q = full | 17.6 % | 40.0 % | 46.8 % | 62.0 % | 68.3 % | 0.267 | 16.1 % | 39.3 % | 58.9 % |
| hybrid RRF, bm25(t+s) + dense(t+s) | 22.4 % | 42.0 % | 50.2 % | 66.8 % | 72.2 % | 0.314 | 17.9 % | 42.9 % | 66.1 % |
| **hybrid RRF, bm25(t+s) + dense(full)** | 21.0 % | **44.9 %** | **52.2 %** | 67.3 % | **74.6 %** | 0.317 | **18.8 %** | **44.6 %** | 66.1 % |
| hybrid RRF, bm25(full) + dense(full) | 20.0 % | 43.4 % | 51.7 % | **67.8 %** | 74.6 % | 0.301 | 17.0 % | 42.9 % | **67.0 %** |

RRF = reciprocal rank fusion, `k = 60`, the constant from
[Cormack, Clarke & Büttcher, SIGIR 2009](https://dl.acm.org/doi/10.1145/1571941.1572114).

**Read this table carefully, because it is the whole architecture:**

1. **Chunking alone doubles corpus-wide top-1** — 4.4 % → 26.3 % — with *no neural component
   at all*, no hand-built term lists, and a 40-word stopword list. The operator's diagnosis
   (*"identifying the particularities rather than getting caught up with stop words"*) is
   right about stop words being a distraction, and the particularity that mattered most turned
   out to be the **unit of retrieval**, not the vocabulary.
2. **The dense leg does not beat BM25 at rank 1 on this corpus.** 18.5 % vs 26.3 %. This is
   the predicted result for a sub-1B embedder on paragraph-length queries — BRIGHT measures
   BM25 at nDCG@10 14.5 with BGE 13.7, Instructor-L 14.2, SBERT 14.9, and only
   >1B models (GritLM 21.0, Qwen 22.5) clearing it
   ([arXiv:2407.12883](https://arxiv.org/abs/2407.12883)). **A 4B embedder was then tested and
   did not fix it** — §7.2, which is the measurement that most shapes this proposal.
3. **The dense leg is worth having anyway, because it buys recall the lexical leg cannot.**
   Hybrid R@8 52.2 % vs BM25's 45.9 %; R@40 74.6 % vs 69.3 %; passage-IoU R@8 44.6 % vs
   37.5 %. Fusion beats both legs at every depth except rank 1.
4. **Therefore: dense supplies RECALL, lexical supplies ORDERING.** That is not a compromise
   made to satisfy the estate's explainability doctrine. It is what the numbers on this corpus
   say, and it happens to be the same conclusion the interpretable-ranking literature reached
   from the other direction (§6.2).

### 3.4 NEW — the metric itself was wrong: aggregate passages to episodes

Everything above ranks *passages* and asks where the first passage from the gold episode
lands. But the question the reviewer asks is "which **episode**?", and eight top passages may
all come from two episodes. Aggregating passage scores to an episode score — **MaxP**, the
maximum-scoring passage, and **sum-of-top-3** — changes the numbers materially:

| system (episode-level ranking, 648 episodes) | R@1 | R@3 | R@5 | R@8 | R@20 | MRR@10 |
|---|---|---|---|---|---|---|
| BM25 t+s, `k1=1.2 b=0.75`, MaxP | 26.3 % | 38.5 % | 47.3 % | 53.2 % | 65.9 % | 0.350 |
| **BM25 t+s, `k1=0.9 b=0.4`, MaxP** | **27.3 %** | 40.0 % | 46.8 % | 52.7 % | 64.9 % | 0.350 |
| BM25 t+s, `k1=1.5 b=0.75`, MaxP | 25.9 % | 39.0 % | 47.3 % | 53.7 % | 67.3 % | 0.347 |
| BM25 t+s, `k1=0.9 b=0.4`, sum-top-3 | 25.9 % | 40.5 % | 49.3 % | 57.1 % | 67.8 % | 0.357 |
| dense bge-m3, MaxP | 17.6 % | 36.1 % | 44.9 % | 53.7 % | 67.3 % | 0.290 |
| hybrid RRF, MaxP | 21.0 % | 41.0 % | 52.7 % | 60.5 % | 73.2 % | 0.340 |
| **hybrid RRF, sum-top-3** | 24.9 % | **47.8 %** | **59.0 %** | **63.4 %** | **73.2 %** | **0.386** |

**Against the reported baseline of 10.7 % / 42.4 % / MRR 0.192** (itself inflated by
injection, §2.2), the best measured configuration is **27.3 % top-1** and **63.4 % top-8**
with **MRR@10 0.386** — a doubling of MRR and a 21-point gain at top-8, from components that
are two indexes and a fusion function.

**Aggregation is a ten-line change and it moves more than the choice of retriever.** That
matches the published ablations: Dai & Callan measure Robust04 description-query nDCG@20 going
FirstP 0.491 → **MaxP 0.529** ([arXiv:1905.09217](https://arxiv.org/abs/1905.09217)), and
Kamalloo et al. measure MaxP helping on **15 of 18** BEIR datasets
([SIGIR 2024](https://cs.uwaterloo.ca/~jimmylin/publications/Kamalloo_etal_SIGIR2024.pdf)).

The BM25 parameter change (`k1=0.9, b=0.4`, the Anserini/BEIR defaults, against the textbook
1.2/0.75) is worth **+1.0 point** here. Published ablations put it at +1.2–1.4 nDCG on BEIR
average, roughly 3× the spread across all BM25 *variants* — so use those parameters, and do
**not** spend time on BM25L/BM25+/ATIRE, which an ANOVA over three TREC collections found
statistically indistinguishable
([Kamphuis et al., ECIR 2020](https://cs.uwaterloo.ca/~jimmylin/publications/Kamphuis_etal_ECIR2020_preprint.pdf)).
But see §3.6: +1.0 point on 205 queries is **inside the noise**.

### 3.5 The noise floor — read every number above through this

n = 205. At p ≈ 0.27 the standard error is `√(0.27 × 0.73 / 205)` = **3.1 points**, so a 95 %
confidence interval is roughly **± 6 points**. At the passage level (n = 112) the SE is
**± 4.4 points**.

**Any difference smaller than ~6 points in this document is not a result.** That includes the
BM25 parameter change (+1.0), the choice between `title+summary` and `summary only` (0.0), and
`k1=1.2` vs `k1=0.9` (1.0). It does **not** include 4.4 % → 27.3 % top-1, or 42.4 % → 63.4 %
top-8, which are far outside it.

Any future comparison must therefore use **paired bootstrap or McNemar over per-query
outcomes**, not a difference of headline percentages, and the eval harness (Phase 0) should
emit the paired test alongside the point estimate. Two systems with the same headline number
can differ on which queries they get right, and that is the comparison that matters.

### 3.6 The headroom, stated as a number

The hybrid's 40-candidate pool contains the right episode **74.6 %** of the time and a
span-overlapping passage **66.1 %** of the time. Top-1 is **27.3 %**. **The gap between 27 %
and 75 % is entirely an ordering problem** — the material is in the shortlist and the ranker
is not putting it first. Every remaining phase of this proposal targets that gap; none of it
targets recall, which is close to solved.

### 3.7 Two cheap levers this pilot did NOT test, and should be tested first

Both are lexical, deterministic, fully inspectable, and cost nothing to try. Neither is in any
number above, so both are pure upside on top of 27.3 %.

**Citation-aware tokenisation.** `Jn 1:14`, `CCC 1213`, `Lumen Gentium 40`, `Rom 8:28-30` are
the highest-IDF tokens in this corpus and **every default analyser shreds them** — the pilot's
own regex reduced `Jn 1:14` to `jn`. Fusing them into single tokens (`jn_1_14`) plus a
normalised alias (`john_1_14`) makes a query and its source passage citing the same verse an
*exact rare-term match*. `standard.text` bodies carry explicit `sources:` blocks
(`Vatican II, Lumen Gentium, Chapter 5`), so the query side already has them. This may move
top-1 more than any model change in this document, and it is a tokeniser rule.

**Whisper proper-noun normalisation.** The discriminative vocabulary here is proper nouns —
Athanasius, Chalcedon, Teresa of Ávila, *homoousios* — and these are exactly what ASR gets
wrong. Entity-aware ASR correction work reports **28–39 % relative WER reductions on
rare-entity test sets** ([arXiv:2506.07510](https://arxiv.org/abs/2506.07510)), implying rare-
entity WER is far above corpus average. A misspelled name is invisible to BM25 **and**
corrupts the dense vector; no retrieval architecture recovers it. **Measure it first
(§7.6)** — count how many spellings of twenty key names occur across the 648 transcripts. If
the answer is "one each", this whole lever is closed and that is worth knowing in an hour.

---

## 4. Recommended architecture

```
  learning point                                  648 episodes / 291,599 segments
        │                                                      │
        │                                        ┌─────────────┴──────────────┐
        │                                        │  A. PASSAGE BUILD          │
        │                                        │  ad/boilerplate mask       │
        │                                        │  sentence-snapped windows  │
        │                                        │  150 s target, 75 s stride │
        │                                        │  → ~14k passages, hashed   │
        │                                        └─────────────┬──────────────┘
        │                                                      │
  ┌─────┴──────┐                              ┌────────────────┴───────────────┐
  │ B. QUERY   │                              │  C. INDEX (two, both artefacts)│
  │ title+summ │──────────── lexical ────────▶│  BM25 (bm25s, deterministic)   │
  │ +tags      │──────────── semantic ───────▶│  bge-m3 flat float32, exact    │
  └─────┬──────┘                              └────────────────┬───────────────┘
        │                                                      │
        │            ┌──────────────────────────────┐          │
        └───────────▶│  D. RRF FUSION  k=60         │◀─────────┘
                     │  → top-40 shortlist          │
                     └──────────────┬───────────────┘
                                    │
                     ┌──────────────┴───────────────┐
                     │  E. RERANK — INSPECTABLE     │
                     │  the CRITERIA composite,     │
                     │  refitted on 40 real         │
                     │  candidates, 16 q_parts kept │
                     │  + span trimming to ~105 s   │
                     └──────────────┬───────────────┘
                                    │
                     ┌──────────────┴───────────────┐
                     │  F. REVIEWER SCREEN          │
                     │  matched spans highlighted,  │
                     │  q_parts shown, one-line why │
                     └──────────────────────────────┘
```

### Named components and versions

| stage | component | version | licence | deterministic? |
|---|---|---|---|---|
| A | Whisper transcripts (already built) | `whisper_merged`, in tree | — | yes (fixed artefact) |
| A | ad / boilerplate mask | new, rule + near-duplicate | — | **yes** |
| A | sentence snapping | `wtpsplit` SaT `sat-3l-sm` **or** Whisper's own punctuation | wtpsplit 2.2.1 | model inference: no · cached output: yes |
| C | BM25 | **`bm25s`** (pure Python + numpy) | 0.3.10, MIT | **yes, but only with `PYTHONHASHSEED=0`** — §5.4(b) |
| C | embeddings | **`BAAI/bge-m3`** via ollama `bge-m3` (568M, 1024-d, 8192 ctx) | MIT | **no** — see §5.3 |
| C | vector index | **none — brute-force `numpy` matmul**, fp16 on disk, fp32 in RAM | numpy 2.x | **yes, with `OPENBLAS_CORETYPE` pinned** — §5.4(a) |
| D | fusion | RRF, `k = 60` | — | **yes** |
| E | rerank rubric | the existing `CRITERIA.md` composite, refitted | in tree | **yes** |
| E | span trimming | new, rule-based over word timings | — | **yes** |

**Everything except the two model-inference steps is deterministic**, and both of those are
made deterministic-by-construction with a content-addressed cache (§5.3).

### 4.1 Why `bge-m3` and not the leaderboard leader

- It needs **no instruction prefix**, which removes an entire silent-failure class. Ollama's
  `/api/embed` **never applies a prompt template** — the handler passes text straight to the
  model — and `sentence-transformers`' `encode_query()` is a **no-op** for E5, BGE-v1.5 and
  Nomic because those repos ship no `prompts` key. A model whose card says the prefix is
  mandatory will silently run without it in both of the common local paths.
- On **LMEB**, the one benchmark whose query lengths (7.9–161.5 words) span this task's
  regime, `bge-m3` dense scores **56.83 without instructions**, above Qwen3-Embedding-8B
  (54.63) and 4B (51.44); and LMEB correlates with MTEB English v2 at Pearson **−0.115**
  ([arXiv:2603.12572](https://arxiv.org/abs/2603.12572)). MTEB rank does not predict this task.
- It is **mean-pooled**, so late chunking ([arXiv:2409.04701](https://arxiv.org/abs/2409.04701))
  stays available as a Phase-4 option. Every decoder-based 2026 top-tier embedder is
  last-token pooled and cannot do it.
- It ships sparse and ColBERT heads from the same weights, so §7.3's experiments cost one
  model download, not three.
- MIT licence. `jina-embeddings-v3/v4/v5` are CC-BY-NC and are therefore **out** for this
  estate regardless of quality.

**The co-equal alternative is `ibm-granite/granite-embedding-english-r2`** — 149M, 768-dim,
8192 context, **Apache-2.0**, **no prefix required**, BEIR 53.1. It is a quarter the size of
bge-m3, so a quarter of the reindex cost; it excludes MS MARCO from its training data on
licensing grounds, which is the cleanest contamination story available; and at 149M it runs
comfortably as **ONNX Runtime on CPU**, which is the most reproducible inference path this
estate has — no kernel autotuning, no GPU reduction-order variance, no ROCm-vs-Vulkan backend
question. Bake both off in M2; if they land within the §3.5 noise floor of each other, take
granite for the determinism and the cost.

**Passage length is a hard filter on this shortlist.** A 150 s passage is ~430 words ≈ 600
tokens. Every 512-token model — `multilingual-e5-large-instruct`, `nomic-embed-text-v2-moe`,
`stella`, `bge-large-en-v1.5`, and every `mxbai-rerank-*-v1` — would silently truncate a third
of every passage. Do not shortlist one, and check `max_seq_length` before believing any
benchmark number.

### 4.2 Why the passage build is the first phase and not the last

§3.1 is the evidence: 4.4 % → 26.3 % from the unit alone. The literature agrees that this is
where to spend, and — importantly — agrees on the *cheap* version:

- **Do not use semantic chunking.** Qu et al. (Findings of NAACL 2025,
  [arXiv:2410.13070](https://arxiv.org/abs/2410.13070)) find fixed-size chunking wins on **all
  four natural-document datasets** (HotpotQA 90.59 vs 87.37; MSMARCO 93.58 vs 92.23;
  ConditionalQA 68.11 vs 64.44; Qasper 90.99 vs 89.27); semantic chunking's large wins occur
  only on corpora artificially stitched from unrelated documents. LumberChunker's own table
  ranks semantic chunking **last** (DCG@20 44.74, below plain recursive at 54.72,
  [arXiv:2406.17526](https://arxiv.org/abs/2406.17526)).
- **Do not train or import a topic segmenter.** Wikipedia-trained neural segmenters transfer
  *badly* to conversational speech: on AMI/ICSI the supervised Wiki-727K BiLSTM (Pk 0.447 /
  0.410) is **worse than 1997 TextTiling** (0.391 / 0.382)
  ([arXiv:2106.12978](https://arxiv.org/abs/2106.12978)).
- **The overlap is the boundary fix.** TREC Podcasts ran two years over 100,000 podcasts, said
  in 2020 it would move to "freely selected jump-in points", and **never did** — it stayed on
  fixed 2-minute windows with 50 % overlap, whose stated purpose is "to account for the case
  where a phrase or sentence is split across the imposed segment boundaries"
  ([2020 overview](https://arxiv.org/abs/2103.15953),
  [2021 overview](https://trec.nist.gov/pubs/trec30/papers/Overview-Pod.pdf)).

What *is* worth building in stage A is the **ad and boilerplate mask**, because it is
evidenced and because this corpus makes it unusually cheap. Reddy et al. (EACL 2021,
[arXiv:2103.02585](https://arxiv.org/abs/2103.02585)) measure **24.01 % of transcript
sentences** as extraneous in a comparable podcast corpus, get sentence F1 **0.769** with a
BERT classifier that sees the *previous sentence* as context, and improve document-level
accuracy 43.1 → 49.1 by smoothing the label sequence. This estate does not need their
classifier for the bulk of it: **648 episodes of one show** means recurring intros, outros and
stock sponsor reads are near-duplicates across episodes and fall out of minhash/simhash for
free. The existing `AD_PHRASES` list covers the rest. Note the existing `fragment_flag`
signal has **never once fired** in the shipped corpus_v2 pool — `CRITERIA-V3-ADDENDUM.md`
§5.1 documents the swallowed `ValueError` — so treat any "we already filter that" claim in
this area as needing a red proof.

### 4.3 The reranker — this is where the remaining 48 points are

§3.6: the shortlist is right 74.6 % of the time and rank 1 is right 27.3 % of the time.
Everything about how to close that is contested, and the contested-ness is itself the finding:

**Evidence FOR a neural reranker.** Jina's reranker-v3 paper reports BEIR nDCG@10 rising from
55.81 (first stage) to 61.94 with reranking, with `mxbai-rerank-large-v2` at 61.44 and
`bge-reranker-v2-m3` at 56.51 — roughly **+6 points**. TREC Podcasts 2021's best runs were all
hybrids with rerankers, and best-over-BM25 at nDCG@30 on topical queries was **0.37 vs 0.25
(+48 % relative)**.

**Evidence AGAINST, on tasks shaped like this one.** On ArguAna — the only BEIR dataset with
paragraph-length queries (mean 192.98 words) — BM25 scores 0.315 and **BM25 + cross-encoder
scores 0.311**, i.e. reranking made it worse
([BEIR, arXiv:2104.08663](https://arxiv.org/abs/2104.08663)). On TREC Podcasts 2020 the BERT
reranker scored **nDCG 0.43 against BM25's 0.52** (though it won P@10, 0.57 vs 0.49).
"Drowning in Documents" ([arXiv:2411.11767](https://arxiv.org/abs/2411.11767)) measures
rerankers ending up **worse than first-stage alone at high K in 53.3 % of academic
experiments**. And small rerankers are actively harmful: at TREC ToT 2025 Gemma-3-1B scored
RR **0.0868 against 0.3038 for no reranking at all**, while 27B reached 0.5104.

**The synthesis, and the recommendation.** The *shape* of the reranking gain is consistent
across every source: it **sharpens the top of the list and damages the tail**. For a workflow
where a human reads a shortlist of 8, that trade is free. So: **rerank, but at K = 40, never
K = 100+; and use an inspectable reranker first.**

The inspectable reranker already exists. `CRITERIA.md`'s composite was designed to answer
*"why this one?"* — it has simply never been run on a candidate set that contained the right
answer. Refitting it over a 40-candidate hybrid shortlist is Phase 3, costs no new dependency,
keeps all 16 `q_parts`, and is the configuration the interpretable-ranking literature actually
supports (§6.2). A neural cross-encoder is Phase 5, gated on Phase 3's numbers, and must beat
the rubric on this corpus before it is adopted — not on BEIR.

### 4.4 Span trimming — the cheapest single quality win

The gold spans are median 105 s; candidates are median 394 s. Word-level timings exist for
99.98 % of segments. A rule-based trimmer — start at the first sentence boundary within the
window that follows a pause, end at the last full stop before the query-term density drops —
converts a "roughly right 150 s window" into "the right 105 seconds", is fully deterministic,
and is explainable in one line ("trimmed to the sentence that first names *X*"). Spotify's
production preview system does exactly this: candidate region first, **then** a "trimmer model
to adjust the start and end of each preview candidate to improve coherence"
([arXiv:2505.23908](https://arxiv.org/abs/2505.23908)).

---

## 5. Stack, cost, determinism

### 5.1 There is no vector database in this design, and that is deliberate

**14,000 vectors × 1024 dims × float32 = 57 MB.** A brute-force exact scan is one numpy matmul,
single-digit milliseconds, and **recall@k = 1.0 by construction**. An ANN index would add a
dependency, a service, and — decisively for this estate — **non-determinism**: HNSW graph
construction is insertion-order dependent.

So: **no FAISS-HNSW, no Qdrant, no LanceDB, no sqlite-vec, no Weaviate, no Vespa, no Milvus.**
A flat `float32` array in a `.npy` file, hash-declared like every other build artefact.
`faiss.IndexFlatIP` is acceptable if a dependency is wanted; plain numpy is preferred.

Likewise **no embedding quantization**. Binary/int8 buys ~50 MB here and costs recall, and the
"binary retains 96 %" figure is a property of `mxbai-embed-large-v1`, which was *trained* for
it — `e5-base-v2` retains **74.77 %**
([HF measurement](https://huggingface.co/blog/embedding-quantization)).

**Independently measured, on the estate's weakest box** (i7-1165G7, numpy 2.4.2 on
scipy-OpenBLAS 0.3.31), exact top-100 over a flat float32 matrix:

| N × dim | mean | p95 | resident |
|---|---|---|---|
| 30,000 × 1024 | 7.9 ms | 12.3 ms | 123 MB |
| **60,000 × 1024** | **16.5 ms** | 24.3 ms | 246 MB |
| 100,000 × 1024 | 28.2 ms | 39.1 ms | 410 MB |

Batching 32 queries into one GEMM: **2.6 ms/query**. Thread count barely matters — a
matrix-*vector* product is memory-bandwidth-bound. `faiss.IndexFlatIP` measured **22.3 ms** at
30k × 1024, *slower* than plain numpy, because numpy dispatches straight to an OpenBLAS
`sgemv`. **Use numpy.**

**And the HNSW rejection is measured, not assumed.** Building each index twice in separate
processes and comparing the file's sha256:

| index | 1 thread | 4 threads |
|---|---|---|
| `faiss.IndexFlatIP` | identical | **identical** |
| `faiss.IndexIVFFlat` | identical | **identical** |
| `faiss.IndexHNSWFlat` | identical | **DIFFER** |
| `hnswlib` (explicit `random_seed`) | identical | **DIFFER** |

This matches FAISS's own documentation — *"The HNSW add function is performed in an
unspecified order… several runs will give different results"*
([FAISS wiki](https://github.com/facebookresearch/faiss/wiki/Threads-and-asynchronous-calls)).
An explicit seed does **not** help, because the seed does not control thread interleaving.

**Store fp16, compute fp32.** Measured: fp16 on disk → fp32 in RAM halves the file (123 MB vs
246 MB) with **identical top-10 ordering** and no speed loss. A *native* fp16 matmul is **18×
slower** (296 ms vs 16.5 ms) because numpy has no BLAS path for it. int8 preserved the top-50
*set* but **reordered the top-10** — don't.

### 5.2 Serving

Nothing runs at serve time. The pipeline is a **build** that emits a static artefact
(JSON or SQLite: per learning point, 40 ranked candidates with their `q_parts`, timestamps,
deep links and matched spans). The 3.9 GB review server reads that file. **No inference on the
review box, ever.** This is the same shape `_runs_v3.json` already has, so the consumer
contract does not change.

Build hosts: the GPU build host for embedding (measured: 13,957 passages in 930 s with bge-m3, ≈15 emb/s);
anything for BM25 and fusion. **The forge box is not a build host** — it has 3.8 GB of RAM
and serves GitLab plus five live sites (CLAUDE.md), and `pl server health` is a required
preflight before anything heavy touches it.

**This is the answer to "but the query has to be embedded somewhere".** In the proposed
workflow it does not: the queries are the 251 learning points, they are known at build time,
and their results are precomputed. Zero inference and zero vectors on the review box — it
serves a file. Only if the reviewer later wants free-text search does query encoding become a
question, and the fallbacks then are, in order: lexical-only live search (needs no model at
all), or proxying one 5 ms forward pass to the GPU host over the mesh.

If it is ever wanted, the *maximal* version of this is well-trodden: the artefact can be served
as **static files behind nginx with `Range` support**, with the client doing the query —
either the Pagefind index-sharding pattern, or SQLite-over-HTTP-range-requests, which fetches
**~70 KiB for a full-text search over an 8 MiB FTS table**
([phiresky](https://phiresky.github.io/blog/2021/hosting-sqlite-databases-on-github-pages/),
[Pagefind](https://pagefind.app/)). No application process, no Python, no model, no memory
pressure. Out of scope for Phase 4, noted so nobody proposes a service later.

### 5.3 Determinism — what is, what isn't, and how the build stays byte-identical

The current build is byte-identical across two independent runs and hash-declared
(`meta.inputs_sha256` / `meta.content_sha256`). That property must survive.

| component | deterministic? | why |
|---|---|---|
| passage windowing | **yes** | pure function of the transcript JSON |
| ad/boilerplate mask | **yes** | rules + hashing |
| BM25 scoring | **yes** | integer counts and a fixed formula |
| RRF fusion | **yes** | rank arithmetic; ties broken by the existing total order |
| CRITERIA composite | **yes** | already proven — `extract_courses_v3.py` sorts on a total order |
| span trimming | **yes** | rules over word timings |
| **embedding inference** | **NO** | see below |

GPU transformer inference is bitwise reproducible **for a fixed batch shape** — Thinking
Machines' analysis shows the forward pass contains virtually no atomic adds and that identical
matmuls give bitwise-identical results; the real culprit is **lack of batch invariance**, and
their fix (`VLLM_BATCH_INVARIANT=1`) **requires NVIDIA compute capability ≥ 8.0 and has no
documented ROCm support**
([thinkingmachines.ai](https://thinkingmachines.ai/blog/defeating-nondeterminism-in-llm-inference/)).
On top of that, ollama has a documented open bug where agreement with reference
implementations swings on `num_ctx` alone (512 → 0.938, **513 → 0.448**,
[ollama#7595](https://github.com/ollama/ollama/issues/7595)), and has changed embedding values
across releases with no deprecation notice (#3777, #7085, #9520, #14449).

**The answer is not to make inference deterministic. It is to make the build not depend on
it.** Embeddings become a **content-addressed cache artefact**, keyed on

```
SHA256( model_digest ‖ runtime_version ‖ backend ‖ exact_input_text ‖
        pooling ‖ normalize ‖ dims ‖ num_ctx )
```

A cache hit is never recomputed. The vector file is hashed into `inputs_sha256` exactly like
`corpus_term_df.json` already is, and the build **refuses to run against a stale table** —
which is the pattern `c22dfbd` already established. A model or runtime upgrade then becomes a
*visible, deliberate reindex*, not silent drift.

**And it must be proven red.** Per the standing order: embed a 1,000-item fixture twice and
assert byte equality — then embed it once more **at a different batch size and assert the
hash differs**. If it does not differ, the check is asserting nothing.

The gate must assert **ordering**, not just similarity. ollama issue #7085's entire finding
was that **cosine stayed high while retrieval order changed** across versions — a
cosine-threshold gate would have passed it silently. So: `cosine ≥ 0.999 element-wise` **AND**
identical top-k on a held-out query set, proven red first against a deliberately wrong pooling
mode or a stripped instruction prefix.

### 5.4 Three further determinism traps, each measured, none of them the model's fault

**(a) OpenBLAS picks a different kernel per CPU microarchitecture.** Same input, same code,
same numpy — four different score vectors:

```
OPENBLAS_CORETYPE=SKYLAKEX    -> 042284e4b836df82…
OPENBLAS_CORETYPE=HASWELL     -> 96a0c97e65dfba78…
OPENBLAS_CORETYPE=SANDYBRIDGE -> 68419662c6de5323…
OPENBLAS_CORETYPE=NEHALEM     -> 7bfe518cef10babe…
```

Scores were bit-identical across *thread counts*, so this is not a threading problem — it is
runtime CPU dispatch. **Consequence: hash the top-k result set, never the score vector, and
make the sort stable with an explicit tie-break on passage ID.** Otherwise the build's hash
depends on which box ran it.

**(b) `bm25s` index artefacts are not byte-reproducible by default.** Built in separate
processes, `bm25s` 0.3.10 with a stemmer produced **three different file hashes in three
runs**. Cause, in `bm25s/tokenization.py`: `vocab = set(tokens_stemmed)` followed by
`{token: i for i, token in enumerate(vocab)}` — `set[str]` iteration order depends on Python's
per-process string-hash randomisation, so term→ID assignment varies. Setting
`PYTHONHASHSEED=0` fixes it; so does `sorted(set(...))`, which is worth an upstream PR. **There
is no open or closed bm25s issue mentioning determinism** — this is undocumented upstream and
the build verb must pin it. Retrieval *results* were bitwise equal throughout; it is the bytes
that move.

SQLite FTS5 and `sqlite-vec` both rebuilt byte-identical — but SQLite's byte-identity is **per
library version** (the file header at offset 96 stores `SQLITE_VERSION_NUMBER`), so pin SQLite
too.

**(c) Low precision manufactures ties, and ties are broken by list order.** Measured on 200
scores: normalised dot products in bf16 gave **~184 unique values out of 200**; a cross-encoder
sigmoid over bf16 logits gave **~150 of 200**. Upcast to fp32 first and both return 200. So
roughly a quarter of a bf16 reranker's scores would be ties resolved by index order, which
*"inflates the variance and bias of retrieval metrics and can even flip model rankings"*
([sentence-transformers #3894](https://github.com/UKPLab/sentence-transformers/issues/3894)).
**Keep the forward pass in fp16/bf16, upcast the final scoring op to fp32 before the activation
and before sorting.** Free, and it should be done from day one.

---

## 6. The explainability design

The estate rejected ML ranking so a reviewer can ask *"why did you pick this one?"* and get a
one-line answer. This proposal does not ask for that to be relaxed. It asks for the neural
component to be confined to the stage where the question is not asked.

### 6.1 Where each question is answered

| reviewer question | answered by | mechanism |
|---|---|---|
| "Why is this **in the list**?" | recall stage | *"It is one of the 40 passages that scored highest on your words or on meaning."* Non-answer, and that is fine — nobody audits a shortlist. |
| "Why is this **first**?" | **CRITERIA composite** | The existing 16 `q_parts`, unchanged. `density 0.42 · breadth 0.90 · title_match 1 · has_definition 1 · serial_marker 0` |
| "Why is this **passage**, not the one before it?" | span trimming | *"Trimmed to start at the sentence that first says 'prayer of quiet' and end at the last full stop before the topic drops away."* |
| "Where in it?" | matched-span highlight | Exact character offsets of every matched term, with word-level timestamps |
| "What did the machine think this LP is **about**?" | the derived term list | Already stored: `_runs_v3.json::topics[lp_id].derivation` records which term came from which field |

### 6.2 Why this is not a compromise

The interpretability tax on ranking is **small, and sometimes negative**:

- **Select-And-Rank** (Leonhardt, Rudra & Anand, ACM TOIS,
  [arXiv:2106.12460](https://arxiv.org/abs/2106.12460)) constrains a ranker to see **only**
  sentences chosen by an inspectable selector — faithfulness by construction, not by argument.
  nDCG@20: TREC-DL **0.597 interpretable vs 0.581 black-box BERT**; Core17 **0.411 vs 0.399**;
  ClueWeb09 0.303 vs 0.313. The tax is **−3.2 % on one collection and negative on two**.
- The same paper measures a **BM25 sentence selector** at nDCG@20 **0.568**, against 0.501 for
  a *neural* BERT selector — *"our lightweight selection strategies… perform better than heavy
  parameterized and time-consuming neural selection models."* A cheap inspectable lexical
  stage in front of a stronger stage is a published, competitive configuration.
- On tabular ranking, Neural RankGAM costs **2.09 NDCG@5 points (4.6 % relative)** against a
  DNN ([arXiv:2005.02553](https://arxiv.org/abs/2005.02553)).
- Rudin's argument that the accuracy/interpretability curve is a *"fictional depiction"* is
  strongest on structured data and weakest on text ranking
  ([Nature MI 2019](https://www.nature.com/articles/s42256-019-0048-x)) — which is exactly why
  the Select-And-Rank numbers, which *are* text ranking, carry the weight here.

**And on this corpus, §3.3 measured the interpretable leg WINNING at rank 1** (BM25 26.3 % vs
dense 18.5 %). There is currently no measured accuracy cost to explainability here at all.

### 6.3 Where explainability genuinely costs something — stated honestly

1. **The recall stage is opaque and will stay opaque.** *"Why did the dense leg surface this?"*
   has no faithful one-line answer. The mitigation is structural, not explanatory: **a passage
   the dense leg alone surfaced can never be ranked first**, because ordering is done by the
   rubric, which scores it on inspectable terms. If it wins, it wins on grounds the reviewer
   can see. If it scores zero on every rubric part, it will not be first.
2. **A neural cross-encoder (Phase 5) would break this.** Its score is a single opaque number
   with no decomposition. It is therefore proposed **only** as a shortlist *reorderer whose
   output is re-scored by the rubric*, or not at all — see §8.
3. **Post-hoc explainers are refused outright.** LIME/SHAP-style ranker explanations are known
   to **disagree with each other** on the same model, and attention is not explanation. Jacovi
   & Goldberg's warning is the operative one: *"where faithfulness carries legal consequences,
   a plausible but unfaithful interpretation may be the worst-case scenario"*
   ([ACL 2020](https://aclanthology.org/2020.acl-main.386/)). A post-hoc explainer nobody has
   shown capable of disagreeing with its model is precisely the estate's "check that has never
   been proven to fail".
4. **Highlighting can manufacture false agreement.** Select-And-Rank's user study (80
   participants, 960 judgements) found reviewers shown short selected spans were **faster and
   no less accurate** — the throughput case for highlighting. But it also found reviewers on
   full documents degraded into browser term-matching. **A UI that highlights only
   high-lexical-overlap spans will make reviewers agree with the machine's lexical bias
   without making them correct.** The acceptance test for the highlight UI must therefore
   include passages that are correct **and** lexically dissimilar.

---

## 7. What to measure before committing — the gates

Each of these is a decision point with a stated threshold. If a phase does not clear its gate,
it does not ship, and the fallback is named.

### 7.1 M1 — Is the labelled set trustworthy? *(half a day, do this first)*

Every number in this proposal rests on 205 single-annotator labels. The IR literature says
that is a shakier foundation than it looks: two competent reviewers agree on ~67 % of
relevance decisions and three on ~45 % (Grossman & Cormack); and re-adjudicating the
highest-disagreement TREC Podcast segments, **human experts sided with LLM judgements over the
original TREC assessors** ([ECIR 2026, arXiv:2601.05603](https://arxiv.org/abs/2601.05603)).

**Do:** double-annotate a random 40 of the 205. Have a second reader judge, blind, whether the
recorded provenance episode is *the best* source for that LP or merely *a* source.
**Gate:** if second-reader agreement is below ~75 %, the ceiling of this whole exercise is the
label noise, and the target metric must move to graded relevance over a top-8 shortlist rather
than top-1 exact match.

### 7.2 M2 — Does a bigger embedder change the dense leg's verdict? — **ANSWERED, and the answer is no**

§3.3 measured bge-m3 (568M) **losing to BM25 at rank 1**, which is what BRIGHT predicts for
sub-1B embedders on long queries — BM25 14.5 nDCG@10 against BGE 13.7, Instructor-L 14.2,
SBERT 14.9, with only >1B models (GritLM 21.0, Qwen 22.5) clearing it. The obvious inference
is "use a bigger embedder". **This was tested and the inference does not hold here.**

`qwen3-embedding:4b-fp16` (4B, 2560-dim, Apache-2.0), with the correct
`Instruct: …\nQuery:` prefix applied to the query side only, embedding the frozen top-50 hybrid
shortlist (4,253 unique passages, ~35 min on the GPU host) and re-ordering it by cosine:

| ordering of the frozen top-50 shortlist | ep R@1 | ep R@3 | ep R@8 | MRR@10 | psg-IoU R@1 |
|---|---|---|---|---|---|
| **fusion order (RRF, no rerank)** | **20.0 %** | 34.6 % | 51.7 % | **0.301** | **17.0 %** |
| bge-m3 (568M) cosine | 17.6 % | 30.2 % | 46.8 % | 0.267 | 16.1 % |
| **Qwen3-Embedding-4B** (7× larger) | 17.1 % | **35.1 %** | **53.2 %** | 0.281 | 8.9 % |

**A 7× larger embedder does not beat the 568M one at rank 1** (17.1 % vs 17.6 %), and
**neither dense model can reorder the shortlist better than the fusion order it came from**
(20.0 %). The 4B model is better deeper in the list (R@8 53.2 %, MRR 0.281) and markedly
*worse* at picking the right passage span (psg-IoU R@1 8.9 % vs 16.1 %). Every difference at
R@1 is inside the §3.5 noise floor; the passage-IoU drop is the only one approaching it.

**Verdict: keep bge-m3** (or granite-r2, §4.1). A full-corpus 4B index would cost ~7× the
embedding time, ~2.5× the storage, and buys nothing measurable at the rank that matters.

**Two honest caveats.** The shortlist being reordered was *selected by* BM25 + bge-m3, which
mildly favours bge-m3 — a fair test would re-index the whole corpus with the 4B model, which
is the ~3.5 hour job this experiment was designed to avoid. And 4B is not 8B; the BRIGHT
crossover may sit higher. Neither caveat changes the operational conclusion, because the
result that actually matters is that **no dense model beat the fusion order** — which is an
argument about the *stage*, not the model size.

**What this does to the architecture: it strengthens it.** If a 4B embedder cannot order this
shortlist, the ordering has to come from something else — and the inspectable rubric is
already sitting there, unmeasured on a shortlist that contains the answer. That is Phase 3,
and M2 has just removed its most plausible competitor.

### 7.3 M3 — Does a reranker help *here*? *(1–2 days)*

**Do:** on the frozen top-40 hybrid shortlist, compare four orderings — (a) fusion order,
(b) the refitted CRITERIA composite, (c) **`Alibaba-NLP/gte-reranker-modernbert-base`**
(149M, **8192 tokens**, Apache-2.0), (d) an LLM listwise reranker using a model already resident on the
GPU build host.
**Gate:** adopt (c) or (d) **only if** it beats (b) by **≥ 8 points** top-1 — outside the
noise floor of §3.5, measured with a paired test — **and** its output can be re-scored by the
rubric without contradiction. Given ArguAna (BM25 0.315 → BM25+CE **0.311**) and TREC Podcasts
2020 (BM25 nDCG 0.52 → BERT rerank **0.43**) both measure reranking *hurting* on tasks shaped
like this one, the null result is a live possibility and must be reported, not retried until
it passes.

Two selection constraints that eliminate most of the field before the experiment starts:

- **A 512-token reranker is disqualified.** A 150 s passage is ~430 words ≈ 600 tokens, plus
  the query. `bge-reranker-base/large` and all `mxbai-rerank-*-v1` are hard-capped at 512 and
  would silently truncate the passage in half. `bge-reranker-v2-m3` is 8192 by architecture
  but was **fine-tuned at 1024** and its official example passes `max_length=512` — raise it
  explicitly or it truncates.
- **Small rerankers can be worse than none.** In IBM's controlled comparison at top-20,
  `ms-marco-MiniLM-L12` bought **+0.1** and `bge-reranker-base` **−0.1**, while the 8192-token
  `gte-reranker-modernbert-base` bought **+3.0**
  ([arXiv:2508.21085](https://arxiv.org/abs/2508.21085)). At TREC ToT 2025 a 1B model scored
  RR **0.0868 against 0.3038 for no reranking at all**.

**Serving:** `sentence-transformers` `CrossEncoder` on PyTorch-ROCm. **Not ollama** — it has no
rerank endpoint and [PR #7219 was closed](https://github.com/ollama/ollama/pull/7219). **Not a
llama.cpp GGUF without a sanity check** — [issue #16407](https://github.com/ggml-org/llama.cpp/issues/16407)
reports wrong scores for Qwen3-Reranker, BGE, mxbai and jina, and many community GGUFs are
missing `cls.output.weight`. Score an obviously-relevant and an obviously-irrelevant pair
before trusting any number.

### 7.6 M5 — are the proper nouns even spelled consistently? *(1 hour, do it with M1)*

**Do:** pick twenty names/terms the courses depend on (Athanasius, Chalcedon, Ávila, Lumen
Gentium, *homoousios*, Ripperger, Garrigou-Lagrange…) and count distinct spellings across the
648 transcripts.
**Gate:** if any key term has > 2 spellings, a normalisation pass over the transcripts goes
into Phase 1 and is probably worth more than any model on this page. If they are all clean,
close the question and record it.

### 7.4 M4 — Does the ad/boilerplate mask fire? *(half a day)*

**Do:** count masked sentences. Reddy et al.'s base rate is 24 %.
**Gate:** if the mask flags < 5 % of the corpus, it is probably broken, not the corpus clean —
`fragment_flag` has never fired once (§4.2). Prove it red on a fixture episode with a known
sponsor read.

### 7.5 The standing metric set

Report all six, always, on both label sets, always corpus-wide with `source: provenance`
candidates excluded, and always **episode-aggregated** (MaxP or sum-top-3, §3.4) rather than
as a raw passage list:

`episode R@1 · R@8 · R@40 · MRR@10` and `passage IoU≥0.3 R@1 · R@8`.

Plus, on every comparison, a **paired bootstrap or McNemar p-value over per-query outcomes**
(§3.5), and — per the standing order on determinism — **Kendall's τ between three identical
runs**. If τ < 1.0 the check is a hypothesis, not a gate.

Never report coverage-only passage metrics (§3.1), never report a pool that was seeded from
the label (§2.2), and never report a passage-list rank as if it were an episode rank (§3.4).

---

## 8. What is NOT recommended, and why

| rejected | why |
|---|---|
| **A vector database** (Qdrant / Weaviate / Milvus / Vespa / LanceDB / Chroma / Typesense / Meilisearch) | 14k vectors = 57 MB; measured brute force is 16.5 ms at 60k × 1024 with recall 1.0. Also, per host: Vespa's own docs say *"start with an 8 GB node"* — more than the whole review box; Typesense holds the index in RAM by design and is GPL-3.0; Meilisearch is now **MIT AND BUSL-1.1** and defaults `MEILI_MAX_INDEXING_MEMORY` to **two-thirds of available RAM**, which is a plausible repeat of the 2026-07-25 OOM; Marqo's OSS project is **deprecated**; Chroma pulls **77** transitive packages. |
| **HNSW / any ANN index** | **Measured non-reproducible**: `IndexHNSWFlat` and `hnswlib` produce different index bytes across multi-threaded builds, seed or no seed (§5.1). `IndexFlat` and `IndexIVFFlat` *are* reproducible — but at this scale flat numpy is faster than FAISS flat anyway. |
| **`sqlite-vec` on the hot path** | Byte-reproducible and zero-dependency, so fine as *storage*. But it is a scalar C loop with no BLAS: measured **89.5 ms/query** at 30k × 1024 against numpy's 7.9 ms. |
| **SQLite FTS5 as the lexical leg** | Reproducible and tiny (15.5 MB at `detail=none`), but it has **no stopword facility at all** and does not skip: measured **445–569 ms p99 on common terms**. `bm25s`' cost is flat regardless of term selectivity, which is the property this workload needs. FTS5 also hard-codes `k1=1.2 b=0.75` and returns a **negated** score. |
| **Embedding quantization** (binary / int8) | Saves ~50 MB. Costs recall. The famous 96 % retention is a property of one model trained for it; `e5-base-v2` retains 74.77 %. |
| **Semantic chunking** (LlamaIndex `SemanticSplitterNodeParser`, LangChain `SemanticChunker`) | Loses to fixed-size on all four *natural*-document datasets in [arXiv:2410.13070](https://arxiv.org/abs/2410.13070); ranked **last** in LumberChunker's own table. Its percentile breakpoint *guarantees* ~5 % of gaps become boundaries whether or not a topic shifted. |
| **A trained topic segmenter** (TextTiling successors, Wiki-727K models, C99) | Wikipedia-trained models are **worse than 1997 TextTiling** on conversational speech (Pk 0.447 vs 0.391). Human ceiling on segmentation is Pk ≈ 15, not 0. And there is no gold segmentation here to train or measure against. |
| **ColBERT / late interaction** | Collapses at paragraph query length — ArguAna 0.233 and DORIS-MAE 12.57, both **below BM25**. Its MaxSim explainability is genuinely attractive, but ColBERTv2 injects `[MASK]` expansion tokens that carry score mass, so naive highlighting *lies* ([MaxSimE, SIGIR 2023](https://dl.acm.org/doi/pdf/10.1145/3539618.3592017)). Revisit only if M3 fails and something interpretable is still wanted. |
| **SPLADE / learned sparse** | Attractive (an explicit weighted term vector is readable). But it needs a training/inference stack this estate does not have, and SIGIR 2026's "wacky weights" analysis shows the uninterpretable part of the vector does its work **in-domain specifically** ([arXiv:2605.19628](https://arxiv.org/abs/2605.19628)) — i.e. exactly here. Park it. |
| **HyDE** | Generates a hypothetical answer to embed. This corpus's queries are already 100-word paragraphs — HyDE's premise is a *short* query with no document-like text. CRUMB measures LLM query rewriting "harms better performing models while bringing notable improvements to weaker models". Non-deterministic, and adds an unexplainable step upstream of everything. |
| **Automatic query reduction / key-term extraction** (KeyBERT, YAKE, RAKE) | The oracle is worth +30–43 % MAP; automatic methods have captured ~8–11 %, and Huston & Croft measure a **−51 %** downside when the wrong terms go. The author already separated `title` / `short.summary` / `standard.text` by hand — §3.2 says just use the right field. Free, deterministic, and better. |
| **Sub-query decomposition at the retrieval stage** | Measured to *hurt*: nDCG@10 72.7 monolithic → 58.7 naive decomposition, with recall failure rising from <1 % to 3.5–12 % ([arXiv:2606.08577](https://arxiv.org/abs/2606.08577)). It helps at the *rerank* stage only; revisit in Phase 5. |
| **doc2query / docTTTTTquery over the corpus** | Genuinely tempting — it is inspectable (you can show a reviewer the generated questions) and it runs offline. But it adds a generation pass over 14k passages that must be cached and re-run on any model change, and §3.4 says the problem is ordering, not recall. **Phase 6 candidate, explicitly deferred, not rejected.** |
| **Fine-tuning an embedder on the 205 pairs** | 205 examples is enough to *measure* a ceiling, not to train. It would also destroy the labelled set as an evaluation instrument. |
| **Any hosted API** (OpenAI, Cohere, Voyage, Jina API) | Corpus is `derivative-cleared-pending` and password-gated. Prohibited by the threat model and by the rights position. Not a close call. |
| **Jina embedding models** (v3 / v4 / v5) **and the whole Jina reranker line** (v2 / v3 / v3.5 / m0) | Strong — `jina-reranker-v3.5` posts the best BEIR number on the board at **63.20**, ~5.7 points clear — and all of it is **CC-BY-NC-4.0**. Unusable, however tempting. |
| **ollama for embedding or reranking in the shipped build** | Fine for the pilot; wrong for an artefact anyone depends on. It has **no rerank endpoint at all** (the request has been open since June 2025; PR #7219 closed), it applies L2 normalisation with no way to disable it, `truncate` behaviour has changed across releases, embedding **values changed between 0.3.3 and 0.3.12 with retrieval order changing while cosine stayed high** ([#7085](https://github.com/ollama/ollama/issues/7085)), and a mis-tagged GGUF's `pooling_type` cannot be overridden ([#16076](https://github.com/ollama/ollama/issues/16076)). Use `sentence-transformers` as the correctness oracle and llama.cpp or ONNX Runtime for the build. |
| **llama.cpp `--reranking` without an A/B** | `token_type_ids` are hardcoded to zero, which mis-scores BERT-family cross-encoders ([PR #21729](https://github.com/ggml-org/llama.cpp/pull/21729)); Qwen3-family rerankers return ~1e-20 for everything because the rerank path pools from CLS and Qwen3 emits a yes/no logit ([#25447](https://github.com/ggml-org/llama.cpp/issues/25447), maintainer-declared out of scope); and the rerank prompt cache is write-only, leaking ~23 MB per call ([#26293](https://github.com/ggml-org/llama.cpp/issues/26293) — set `--cache-ram 0`). Never run `--embedding` and `--reranking` in one process. |
| **`mxbai-embed-large` / `nomic-embed-text`** | The two most-pulled ollama embedding models, and the wrong defaults for long-form content: 0.660 and 0.633 on long-document needle retrieval against 0.973 for bge-m3. |
| **LangChain / LlamaIndex / Haystack** | Two indexes, one fusion function and a scoring rubric. A framework would be more code than the thing it wraps, and a bigger audit surface. Plain Python. |
| **Post-hoc explainers (LIME / SHAP / attention) for the ranker** | §6.3 item 3. Unfalsifiable by construction. |
| **Replacing the CRITERIA composite with a learned ranker** | Explicitly out of scope. It is the estate's answer to *"why this one?"* and §3.3 measures it having no accuracy cost here. |

---

## 9. Build sequence and effort

| phase | what | effort | gate |
|---|---|---|---|
| **0** | **Eval harness first.** Score `_runs_v3.json` against both label sets, corpus-wide, injection excluded, episode-aggregated. Emit the six metrics **plus a paired significance test**. Commit as a red-then-green fixture. | **0.5 d** | Reproduces §2.1 to the unit *and* §2.2's corpus-wide 4.4 % |
| **0b** | M1 double-annotation (§7.1) + M5 proper-noun spelling count (§7.6) | 0.5 d | ≥ 75 % agreement, else re-target the metric |
| **1** | **Passage build**: ad/boilerplate mask, sentence-snapped 150 s/75 s windows, citation-aware tokeniser (§3.7), `k1=0.9 b=0.4`, MaxP/sum-top-3 aggregation, hashed artefact | **2 d** | ≥ 22 % corpus-wide episode R@1 with BM25 alone (measured: 27.3 %) |
| **2** | **Hybrid recall**: bm25s index + bge-m3 flat vectors + RRF, content-addressed embedding cache with the batch-size red proof | **2 d** | ≥ 70 % episode R@40 and ≥ 58 % R@8 (measured: 74.6 % / 63.4 %); build byte-identical twice |
| **3** | **Inspectable rerank**: refit the CRITERIA composite over the top-40 shortlist; span trimming into the operator's **2–4 min band** *(was "to ~105 s" — CORRECTION 1: 105 s was the 2026-03-08 model's median, not a target)* | **2–3 d** | top-1 ≥ 38 %; passage-IoU R@1 ≥ 28 % **against the CIRCULAR set — a regression detector only, not a quality gate (§2.6)**; every candidate still carries 16 `q_parts` |
| **4** | **Reviewer screen**: matched-span highlight, `q_parts` panel, one-line why; the lexically-dissimilar acceptance case from §6.3 item 4 | 2 d | A reviewer can state the reason for the top pick without opening the transcript |
| **5** | *(gated on M3)* neural or LLM reranker, top-40 only | 2 d | Beats Phase 3 by ≥ 8 points top-1 on a paired test, or is dropped and the null result recorded |
| **6** | *(deferred)* doc2query corpus expansion; late chunking | 3 d | — |

**Phases 0–3 are the proposal.** 4 is the delivery. 5 and 6 are options that must earn their
way in.

---

## 10. The testable claim

Stated so it can be falsified, on the 205-point provenance set, **corpus-wide with
`source: provenance` candidates excluded**, against today's corpus-wide baseline of
**top-1 4.4 % / R@40 64.4 %**:

All figures **episode-aggregated** (§3.4). Baseline is the corpus-wide, injection-excluded
number from §2.2 — not the 10.7 % that has been quoted.

| metric | today (corpus-wide) | after Phase 1 (BM25 only) | after Phase 2 (hybrid) | after Phase 3 (**the claim**) |
|---|---|---|---|---|
| episode R@1 | **4.4 %** | **27.3 %** ✅ measured | 24.9 % ✅ | **≥ 38 %** |
| episode R@3 | — | 40.0 % ✅ | **47.8 %** ✅ | ≥ 55 % |
| episode R@8 | — | 52.7 % ✅ | **63.4 %** ✅ measured | ≥ 68 % |
| episode R@40 (recall ceiling) | 64.4 % | 69.3 % ✅ | **74.6 %** ✅ | 74.6 % — *unchanged; rerank adds no recall* |
| episode MRR@10 | — | 0.350 ✅ | **0.386** ✅ | **≥ 0.48** |
| passage IoU≥0.3 R@1 (n=112) | 6.2 %¹ | 17.0 % ✅ | **18.8 %** ✅ | **≥ 28 %** |
| passage IoU≥0.3 R@8 | — | 37.5 % ✅ | **44.6 %** ✅ | ≥ 52 % |

¹ the §2.3 coverage figure; the current pipeline's IoU figure is lower still, because its
candidates are far longer than the windows it is being compared to.

> **CORRECTION 1 applies to the last two rows of this table.** Every `passage IoU (n=112)` row
> is scored against the 2026-03-08 machine windows. **They are not a quality gate and the
> ≥28 % / ≥52 % targets are withdrawn as such** — they remain valid as *regression detectors*
> (§2.6 step 4). The `episode R@k` rows are scored against the same 176-block-derived
> attribution and carry the same caveat; the R@40 row is the most robust of them because
> recall-at-large-*k* degrades gracefully under a noisy label, and the corpus-wide 4.4 %
> baseline of §2.2 is unaffected because it is a *within-label-set* comparison. The original
> footnote said the candidates are "3.7× too long"; that factor is withdrawn (§2.4).

**Phases 1 and 2 are already measured**, not projected — that is what §3 is, and it is the
main claim of this document: *the gains attributed here to chunking, query construction,
fusion and aggregation have been observed on this corpus, on this hardware, against this
labelled set.*

**Only the Phase 3 row is a forward claim.** It is a claim about closing roughly a quarter of
the gap between 27 % (what is ranked first) and 75 % (what is in the shortlist), using an
inspectable rubric and span trimming. Every threshold in that column clears the §3.5 noise
floor of ±6 points, so it can actually be falsified.

If Phase 3 cannot beat **38 % top-1** with an inspectable rubric over a shortlist that
contains the answer 74.6 % of the time, then the rubric is the binding constraint and M3's
neural options become the live path — and that, too, is a result worth having, provided it is
reported rather than retried until it passes.

---

## 11. Open questions for the operator

1. **Is `source: provenance` injection wanted in the product?** It is right for a reviewer
   (always show something from the known episode) and wrong for evaluation. Recommendation:
   keep it, label it loudly on the candidate, and exclude it from every metric.
2. **The 64 placeholder `video:` blocks** (`start: 0`, 8 minutes) are recorded as if they were
   choices. Should they be marked as unset so they stop diluting both the label set and the
   reviewer's sense of what is decided? *(CORRECTION 1 strengthens this: they measure at the
   53rd percentile — chance — and land in the show intro, which `CRITERIA.md`'s own
   `intro_position` rule scores negative.)*
3. **The 46 LPs with `method: none`** have no provenance at all. They are the strongest
   argument for this work — nobody knows where they came from — and they can never be scored.
4. **Which host owns the embedding build?** The estate's GPU agent host is proposed — it is
   where the VRAM is, and it never touches prod.
5. **NEW (CORRECTION 1). Should the *other* 112 `video:` blocks also be marked unset — or
   marked `provenance: machine-2026-03-08`?** They are AI output, not selections; 61 of the 176
   link to a YouTube video shorter than their own end time and 2 lie outside their episode
   entirely. Recommendation: **do not delete them** (they encode a real and mostly-correct
   *episode* attribution — 75 % agreement on the 12 independently checkable cases) but **stamp
   every one with its provenance** so no future session can mistake them for judgements again.
   This is the specific instance of the standing order that a check nobody has seen fail is not
   a check: an unlabelled artefact was read as a gold set by two proposals and one issue.
6. **NEW. Do you want the referential-integrity repairs done in phase 1, ahead of any ranker
   work?** They are the only clip-quality work that is provably positive without a human
   judgement (§2.6 step 4): the 2 impossible windows, the 61 over-length links, the 15
   many-to-one `youtube_id`s. Recommendation: yes, and as their own MR against `~/dir`.

---

## References

Aggregation and BM25 configuration — [Dai & Callan, Deeper Text Understanding for IR, SIGIR 2019, arXiv:1905.09217](https://arxiv.org/abs/1905.09217) ·
[Resources for Brewing BEIR, SIGIR 2024](https://cs.uwaterloo.ca/~jimmylin/publications/Kamalloo_etal_SIGIR2024.pdf) ·
[Kamphuis et al., Which BM25 Do You Mean?, ECIR 2020](https://cs.uwaterloo.ca/~jimmylin/publications/Kamphuis_etal_ECIR2020_preprint.pdf) ·
[bm25s, arXiv:2407.03618](https://arxiv.org/abs/2407.03618)

Rerankers — [Granite Embedding R2, arXiv:2508.21085](https://arxiv.org/abs/2508.21085) ·
[Entity-aware ASR correction, arXiv:2506.07510](https://arxiv.org/abs/2506.07510)

Retrieval and fusion — [Cormack, Clarke & Büttcher, RRF, SIGIR 2009](https://dl.acm.org/doi/10.1145/1571941.1572114) ·
[BEIR, arXiv:2104.08663](https://arxiv.org/abs/2104.08663) ·
[BRIGHT, arXiv:2407.12883](https://arxiv.org/abs/2407.12883) ·
[LMEB, arXiv:2603.12572](https://arxiv.org/abs/2603.12572)

Podcast / spoken retrieval — [TREC Podcasts 2020, arXiv:2103.15953](https://arxiv.org/abs/2103.15953) ·
[TREC Podcasts 2021 overview](https://trec.nist.gov/pubs/trec30/papers/Overview-Pod.pdf) ·
[100,000 Podcasts, COLING 2020](https://aclanthology.org/2020.coling-main.519/) ·
[Detecting Extraneous Content in Podcasts, EACL 2021 / arXiv:2103.02585](https://arxiv.org/abs/2103.02585) ·
[Podcast preview generation, arXiv:2505.23908](https://arxiv.org/abs/2505.23908)

Chunking and segmentation — [Is Semantic Chunking Worth the Cost?, arXiv:2410.13070](https://arxiv.org/abs/2410.13070) ·
[LumberChunker, arXiv:2406.17526](https://arxiv.org/abs/2406.17526) ·
[Solbiati et al., arXiv:2106.12978](https://arxiv.org/abs/2106.12978) ·
[Late chunking, arXiv:2409.04701](https://arxiv.org/abs/2409.04701) ·
[Contextual Retrieval, Anthropic 2024](https://www.anthropic.com/engineering/contextual-retrieval) ·
[Segment Any Text, arXiv:2406.16678](https://arxiv.org/abs/2406.16678)

Verbose queries — [Bendersky & Croft 2008](https://ciir-publications.cs.umass.edu/pub/web/getpdf.php?id=821) ·
[Huston & Croft, SIGIR 2010](https://ciir-publications.cs.umass.edu/pub/web/getpdf.php?id=930) ·
[BM25Q, arXiv:2509.02558](https://arxiv.org/abs/2509.02558) ·
[Decomposition at rerank only, arXiv:2606.08577](https://arxiv.org/abs/2606.08577)

Reranking — [Drowning in Documents, arXiv:2411.11767](https://arxiv.org/abs/2411.11767)

Explainability — [Select-And-Rank, arXiv:2106.12460](https://arxiv.org/abs/2106.12460) ·
[Interpretable LTR with GAMs, arXiv:2005.02553](https://arxiv.org/abs/2005.02553) ·
[Rudin, Nature MI 2019](https://www.nature.com/articles/s42256-019-0048-x) ·
[Jacovi & Goldberg, ACL 2020](https://aclanthology.org/2020.acl-main.386/) ·
[Axiomatic explanations, arXiv:2106.08019](https://arxiv.org/abs/2106.08019) ·
[MaxSimE, SIGIR 2023](https://dl.acm.org/doi/pdf/10.1145/3539618.3592017) ·
[Wacky Weights, arXiv:2605.19628](https://arxiv.org/abs/2605.19628)

Labels and evaluation — [Human vs LLM judgments on TREC Podcasts, arXiv:2601.05603](https://arxiv.org/abs/2601.05603) ·
[Cormack & Grossman, AutoTAR, arXiv:1504.06868](https://arxiv.org/abs/1504.06868)

Determinism and serving — [Defeating Nondeterminism in LLM Inference](https://thinkingmachines.ai/blog/defeating-nondeterminism-in-llm-inference/) ·
[ollama#7595, num_ctx sensitivity](https://github.com/ollama/ollama/issues/7595) ·
[Embedding quantization, HuggingFace](https://huggingface.co/blog/embedding-quantization)
