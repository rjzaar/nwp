# The 16-candidate clip shortlist — method, counts and audit

**Date:** 2026-08-12 · **Issue:** `nwp/ops#348` · **Status:** MACHINE-RANKED shortlist for
human authors. Not gold, not a pick, not validated.

> **What a reviewer of this document can and cannot check.**
> You can check the **method**, the **counts**, the **internal consistency** of the
> selection against the pool it was drawn from, and whether the declared rules were
> actually followed. You **cannot check the labels** — there are none worth checking
> (§7.3), and the corpus itself is derivative-cleared-pending, password-gated and
> **local-only**, so no transcript text, candidate excerpt, rationale or deep link appears
> in this repository or in this document. `nwp/nwp` is publicly mirrored (NWP-ADR-0039). The
> artefacts live on `mini` at `~/clip-pool/shortlist/`.

---

## 1. What was produced

For each of the **251 curriculum learning points**, up to sixteen candidate clips drawn
from a deep retrieval pool, each carrying a one-line rationale that cites what in the
passage matched what in the learning point.

Operator mandate, 2026-08-12:

> *"I authorise you to use your own skill to find the best 16 for each learning point.
> Human authors can then choose amongst them or if they wish look further afield."*

The mandate is deliberately the **reliable half** of the problem. Measured on this corpus:
independent instances of the same model agree at **0.81 Jaccard on shortlist set
membership** (human TREC assessors sit near 0.30), but only **0.68 on which single clip is
best**, 95% CI **[0.404, 0.950]**, with some learning points as low as **0.14**. Machine
shortlisting is reliable; machine picking is not. Nothing in this pipeline picks.

**Artefacts** (on `mini`, not tracked here):

| path | what |
|---|---|
| `~/clip-pool/shortlist/SHORTLIST-16.jsonl` | 251 lines, 3,955 rows |
| `~/clip-pool/shortlist/SHORTLIST-16.jsonl.sha256` | integrity |
| `~/clip-pool/shortlist/README.md` | full method + limits |
| `~/clip-pool/shortlist/AUDIT.txt` | the audit, as run |
| `~/clip-pool/work-assemble/*.py` | merge + audit scripts, deterministic, no network |

## 2. Method

**Source pool** (`~/clip-pool/pool/pool.jsonl`, built 2026-08-12 on `mini`): 251 learning
points, 31,425 candidates, median depth 126, median 51 distinct moments. Three retrieval
sources fused at equal weight by RRF (k=60): BM25 (k1=0.9, b=0.4) over six query variants,
`bge-m3` 568M/1024d dense, and the production CRITERIA rubric. Passages built at seven
granularities (45/90/120/180/240/300/420 s) at 50% overlap, snapped to whole Whisper
segments.

**Selection key: `moment_rank`, never `rank`.** Two thirds of pool candidates are
overlapping views of a moment another candidate already covers; `moment_id` collapses
positional overlap and content near-duplication across the DIR/SD channel boundary.

| a top-16 taken by | episodes spanned (median) | largest single-episode share (median) |
|---|---|---|
| `rank <= 16` | 3 | 56% |
| `moment_rank <= 16` | 10 | 19% |
| **this shortlist, as delivered** | **12** | **12.5%** |

**Selection criteria, in order of weight.**

1. **Cross-method agreement** (`n_sources_agreeing`) — in a corpus with no trustworthy
   labels, convergence between methods that share no machinery is the strongest evidence
   available.
2. **The DIR-only-rubric asymmetry, honoured explicitly.** The production rubric only ever
   ran over DIR, so an SD or retreat candidate **caps at 2 of 3**. Reading 3 > 2 across
   corpora would systematically bury the SD material the operator ordered ingested. Every
   row carries `max_sources_possible`; **0 of 3,955 rows mis-state it**; agreement is
   reported **separately per channel** (§5) for the same reason.
3. **Duration** toward the operator's recorded brief (2026-03-08): *"up to 7 minutes but
   ideally about 2–4 minutes"*.
4. **Diversity as a requirement** — spread across episodes and channels; soft cap ~3 clips
   per episode.
5. **`dense_qwen_rank_within_pool` (qwen3-embedding:4b-fp16) as a tiebreaker only,
   discounted by about half.** Its @16 advantage (50.2% vs fusion's 43.9%) is agreement
   with ~90% circular labels, measured on a shortlist `bge-m3` helped select.
6. **Provenance is display-only and was never boosted.** All 176 existing `video:` windows
   are machine output from a March regex pass; zero were human-chosen.

**Judging:** 16 parallel instances of **claude-opus-5**, one per slice of ~16 learning
points, each adversarially verified by an independent instance before merge. Merged and
audited as one corpus.

## 3. Completeness — measured

| | value |
|---|---|
| learning points present | **251 / 251** — no gaps, no duplicates |
| rows total | **3,955** (nominal 4,016; deficit 61) |
| LPs at exactly 16 | **231** |
| LPs under 16 | **20**, every one with a recorded reason — **0 silent shortfalls** |
| LPs over 16 | 0 |
| duplicate `moment_id` within an LP | **0** |
| rows resolving against `pool.jsonl` by `moment_id` + `passage_id` | **3,955 / 3,955** |
| `moment_rank` / `moment_id` values disagreeing with the pool | **0** |
| CANNOT-VERIFY rows | **0** |

The 20 short pools: `A4.01` 13 · `E3.02` 14 · `E3.03` 13 · `E3.04` 12 · `E4.01` 13 ·
`E4.02` 15 · `E4.03` 14 · `E4.05` 12 · `E5.01` 14 · `E5.02` 13 · `E5.03` 13 · `E5.04` 10 ·
`F1.01` 15 · `H2.01` 15 · `H2.04` 12 · `H3.04` **8** · `I3.01` 15 · `I3.02` 13 ·
`I3.03` 10 · `I3.04` 15.

**Only `I3.04` is short because the pool is short** — its pool holds exactly 15 distinct
moments, which was the expected answer, not a bug. The other 19 are judgement calls
("remaining moments are on-topic by vocabulary but not by content"; "the rest are
overlapping views"; "the ones that would complete it are past the 7-minute ceiling").
Those 19 are where a human author most deserves a second opinion — and one of them is
demonstrably wrong (§7.7).

Padding was refused throughout. Filler wastes the exact human attention this programme
exists to conserve.

## 4. Diversity, corpus split, duration — measured

### Episodes

| | value |
|---|---|
| episodes spanned per shortlist | **median 12** · mean 12.2 · **worst 6** (3 LPs) |
| max single-episode share | **median 12.5%** · mean 16.1% · **worst 50%** (one LP, 8 of 16 from one episode) |
| LPs where one episode takes > 3 clips | **17 / 251** |
| LPs where one episode takes ≥ 25% | 23 / 251 |

The ~3-per-episode cap was **exceeded on 17 learning points**. One course cluster accounts
for most of them: its material sits in a handful of long episodes. A real deviation from
the stated rule, reported rather than rounded.

### Corpus split

| channel | rows | share | pool's own deduped-top-16 baseline |
|---|---|---|---|
| DIR | 3,028 | **76.6%** | 79% |
| SD | 753 | **19.0%** | 16% |
| retreat (itd / pp / swados) | 174 | **4.4%** | 5% |

**231 / 251** learning points carry at least one SD-side clip; 20 are 100% DIR. SD was not
buried.

### The 55 catalogue-declared SD/retreat-sourced learning points

DIR 67.0% · SD 18.0% · **retreat 15.0%** — against 4.4% retreat corpus-wide. 30 / 55 carry
a retreat clip; 53 / 55 carry an SD-side clip. Retreat material stayed largely out of where
the catalogue does not declare it: only **30 / 196** other LPs carry one.

### The 29 of those with NO DIR attribution at all

These are the learning points the SD ingest exists for.

| | value |
|---|---|
| pool's deduped top-16 held a retreat moment | 25 / 29 |
| **final shortlist holds a retreat clip** | **25 / 29 (86.2%)** |
| **regressions** (pool had one, shortlist dropped it) | **1** |
| gains (found deeper than `moment_rank` 16) | 1 |

Of the four without one: two have **no retreat moment anywhere in their pool**; one's sits
at `moment_rank` 23; **one's sat at `moment_rank` 15 and was dropped** — the single true
regression, named rather than netted against the gain.

### Duration (operator: ideally 120–240 s, ceiling 420 s)

| | value | pool baseline |
|---|---|---|
| median | **178.7 s** (mean 187.0, p10 89.6, p90 261.3) | 179 s |
| inside the 120–240 s band | **65.7%** | 42.8% (deduped top-16: 44.3%) |
| within the 420 s ceiling | **99.5%** | 94.6% |
| **over the ceiling** | **19 rows (0.5%) across 17 LPs**, max 852 s = 14.2 min | — |
| under 90 s (tight quotes offered) | 10.1% | — |
| LPs offering both a <120 s and a >240 s option | 197 / 251 | — |

The 19 over-ceiling rows are an **inconsistency, not a policy**: at least one slice cited
the 420 s ceiling in a shortfall reason as grounds to exclude a candidate while itself
emitting a 528 s row. `within_operator_ceiling_420s` is on every row so an author can
filter.

## 5. Agreement — reported separately per channel, never blended

A blended number would misrepresent both channels, because the production rubric never ran
over SD.

| channel | n | cap | ≥2 sources (moment-wide) | at cap |
|---|---|---|---|---|
| **DIR** | 3,028 | 3 | **47.1%** | 12.2% at 3 of 3 |
| **SD** | 753 | 2 | **37.5%** | 37.5% at 2 of 2 |
| **retreat** | 174 | 2 | **59.2%** | 59.2% at 2 of 2 |

**251 / 251** learning points carry at least one clip with ≥2-source agreement.

### The cost of reaching past `moment_rank` 16 — stated plainly

| | rows | ≥2-source agreement | in 120–240 s band |
|---|---|---|---|
| in-window (`moment_rank` ≤ 16) | 2,694 (68.1%) | **64.3%** | 66.4% |
| deep (`moment_rank` > 16, max seen 61) | 1,261 (**31.9%**) | **6.2%** | 64.1% |

**Nearly a third of this shortlist sits outside the prescribed selection window, and those
rows carry the pool's only non-circular evidence almost never.** 664 in-window moments with
≥2-source agreement, across 213 learning points, were passed over. Slice verifiers'
spot-checks found the passed-over moments were usually genuinely off-topic — judgement
correctly exercised — but the trade is real: **the deep third bought topicality and
duration at the price of cross-method corroboration.** Filtering on `moment_rank <= 16`
recovers only the corroborated half.

### Tiebreaker availability

`dense_qwen_rank_within_pool` is present on **1,486 / 3,955 rows (37.6%)** — it was computed
over each pool's top-40 by raw `rank`, and most `moment_rank` candidates sit deeper than
that stage reached.

## 6. Abstentions, addressing, rationales

**Abstentions: 23 rows (0.6%)** — 14 `ABSTAIN-PEDAGOGY`, 9 `ABSTAIN-DOCTRINE`. Those calls
belong to the Theology and Pedagogy guilds, not to this pipeline. (The pre-measured
expectation was "under 1% of candidates need such a ruling to be shortlisted"; 0.6%
matches.)

**Addressing.** 76.4% audio deep-link (DIR — the authoritative form); 19.0% YouTube (SD,
where the YouTube video *is* the transcription source and is therefore on-timeline, but is
**not** verified by `pl clips verify`); 4.4% Vimeo/source URL (retreat); **5 rows (0.1%)
have no known media URL at all and are emitted as CANNOT-VERIFY-ADDRESS rather than
dropped.** No YouTube id is emitted for any DIR row, by construction: the catalogue's DIR
YouTube linkage is broken corpus-wide (134 of 176 blocks point at a different recording,
30 more sit on a +61…+480 s offset, zero are both corroborated and on-timeline). All
timestamps are **audio seconds**.

**Rationales.** 3,955 / 3,955 present; median 208 chars, minimum 63; none is a
score-restatement. How far they can be trusted is §7.5 — and it is the artefact's weakest
result.

## 7. The honest limits

**7.1 MACHINE-RANKED, not gold.** No human has reviewed a single one of the 3,955 rows.

**7.2 Machine shortlisting is reliable; machine picking is not.** 0.81 set agreement vs
0.68 pick agreement, CI **[0.404, 0.950]**, worst learning points 0.14. The CI's lower bound
is barely better than a coin. **No downstream tool may collapse these sixteen to one.**

**7.3 The labels used anywhere upstream are ~90% circular.** Most episode attributions were
derived from the same machine-generated `video:` blocks they would be used to score. Every
figure that rests on them — including the qwen @16 advantage that justifies the tiebreaker —
is agreement with a contaminated reference, not correctness. `ops#348` D1 exists to decide
which grades of that map are admissible at all.

**7.4 A systematic bias shared by all instances of one model is invisible by
construction.** All 16 judging instances were claude-opus-5. Their 0.81 agreement measures
*consistency*. A shared preference — for articulate hosts, for a register, for one school of
spirituality — would produce exactly that number while being exactly wrong. **Only the
operator's calibration set can speak to validity.** Nothing in this document does.

**7.5 12.5% of quoted fragments in the rationales could not be located in the clip they
describe.** Measured over 2,774 quoted fragments of ≥4 words: **84.0% corroborated** in the
emitted clip; 3.4% quote the learning point (legitimate); 0.1% appear only in a *wider* view
of the moment than the window the author is handed; and **12.5% — 346 fragments across 344
rows and 171 learning points — are paraphrase presented inside quotation marks.** In the
worst case the model supplied a well-known maxim of a Doctor of the Church from its own
knowledge and quoted it as if from the tape, where the passage only names the chapter it
comes from. Every affected row now carries a `caveat` field and a `rationale_quote_audit`
block naming the count.

This is the finding that most directly attacks the doctrine the rationales exist to serve —
inspectability. **A rationale that quotes something the clip does not say is worse than no
rationale**, because it converts a suggestion an author could interrogate into one that
looks already checked.

*Red proof for the check:* it independently re-found the single case a slice's adversarial
verifier had flagged by hand (similarity 0.49 here vs their 0.47). It was also observed
**wrong first** — an apostrophe-blind regex read possessives as quote delimiters and scored
39.5%; an ellipsis-blind version scored 20.2%. Both were corrected before 12.5% was taken.
A check never observed red is not a check.

**7.6 One slice's method block asserts a false mechanism.** It states the qwen tiebreaker is
null on every candidate in its selection set; measured, 126 of 240 carry one. Verified as
**staleness, not deception** — the pool was rewritten at 11:45 and that slice was built at
10:56 — but the asserted mechanism is false and the mandated tiebreaker was in fact
available for 53% of that slice's in-window candidates.

**7.7 One shortfall reason is materially false, and this is the integrity finding.** `A4.01`
returns 13 and explains the gap by naming ten episodes as the material passed over.
Measured: all ten sit at `moment_rank` 22–38, nowhere near the cut. The moments actually
passed over sit at `moment_rank` 4, 7, 9–12, 14 and 15, in episodes that slice itself drew
from — so it judged them on-topic — and none was at the declared 3-clip episode cap. Six of
the eight are explained by the declared dedup filters. **Two are not explained by any
declared filter** (0.00 Jaccard and 0% time overlap against everything selected, in an
episode holding only 1 of its permitted 3 slots). **The stated cause is not the real cause.**
`A4.01`'s shortfall must be read as unexplained, and the class — a plausible reason
substituted for the measured one — is the one to look for in the other 18 judgement-call
shortfalls.

**7.8 The written recipe was departed from.** 31.9% of rows sit past `moment_rank` 16 and 17
learning points exceed the ~3-clips-per-episode cap. Both are declared, both were measured,
and neither degraded the headline diversity figures (§4 beats the `moment_rank<=16`
benchmark on both axes) — but a reviewer checking conformance to the recipe as written will
find non-conformance, and should.

## 8. What this unblocks, and what it does not

**Unblocks:** author review of clip candidates for all 251 learning points, with a
2-to-16-fold widening of choice per point and every suggestion carrying its own reason.

**Does not unblock:** any claim that these are the *right* clips. That requires the
operator's calibration set (`ops#348`), which is the only instrument in this programme not
built on circular labels or on one model's agreement with itself.

**Recommended reading order for a human author:** filter to `moment_rank <= 16` and
`moment_max_sources_agreeing >= 2` first — that is the corroborated half — then widen. Treat
any row carrying a `caveat` as needing the clip played before the rationale is believed.
