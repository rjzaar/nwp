# ops#61 — Course-Content Source Reconciliation (v3 canonical vs v1 app)

**Date:** 2026-07-09
**Work item:** ops#61 item 1 — the hard gate (reconcile the two divergent
course-content sources before anything downstream is built).
**Status:** READ-ONLY analysis. Nothing was modified, moved, or merged.
**Author:** analysis agent (automated parse + hash comparison of both trees).

---

## 0. Sources compared

| Tag | Path | Repo | Files |
|-----|------|------|-------|
| **v3 (CANONICAL)** | `~/dir/courses_v3/catalog/*.yaml` | `nwp/courses` (git, 1 commit) | 55 course YAMLs + `schema.yaml` (v3.0.0) |
| **v1 (APP)** | `~/nwp/sites/ss2/dev/data/learning-points/courses/*.yaml` | untracked (inside `sites/ss2`) | 49 course YAMLs + `schema.yaml` (v1.0.0) |

The v1 app tree feeds the Flutter app through
`~/nwp/sites/ss2/dev/faith_formation/tools/build_seed_db.py`
(`DEFAULT_YAML_DIR = .../data/learning-points/courses`, `glob("*.yaml")`).

> Note on the ops#61 brief: it locates v1 at `.../learning-points/*.yaml`. The
> actual course files live one level down in `.../learning-points/courses/*.yaml`
> — the only `*.yaml` at the `learning-points/` top level are `schema.yaml` and
> `slot_schema.yaml`. This report uses the `courses/` subdirectory that the build
> script actually consumes.

---

## 1. Headline result (read this first)

**The ops#61 hypothesis — "v1 has more quiz items (1,703 vs 1,671) → app-side
edits never came back to canonical" — is DISPROVEN.**

- Every one of the **1,671 quiz items that share an ID across both sources is
  byte-for-byte identical** (verified by SHA-1 over the fully-serialised item,
  not just question text). Zero drift. No scattered app-side edits exist.
- The entire 32-item gap is **one course code: `D6`**, and it is a *deliberate,
  documented whole-course replacement*, not an app edit:
  - **v1 `D6`** = "Discernment in Daily Life" — 4 LPs, 32 quiz items
    (`D6.01` From Theory to Practice … `D6.04` The Ebb and Flow of the Spiritual Life).
  - **v3 `D6`** = "Fight, Don't Run: The Combat Posture" — 5 LPs, **0 quiz items**
    (`D6.01` The Aggressive-Dog Principle … `D6.05` When to Move, When to Hold).
  - These are **different courses reusing the same code** (a code collision), per
    `~/dir/courses_v3/catalog/D6.yaml` header and `PROPOSAL.md §4.2`.
- So the raw counts invert the real risk. v3 is the structural **superset**
  (more courses, more LPs, richer schema); the "missing" 32 items belong to a
  v1 course topic that **exists nowhere in v3**.

**The real gate item:** v1 `D6`'s full content (4 LPs × depth text + 32 quizzes)
survives in exactly **one place** — the untracked app file. Its claimed backup is
missing (see §5.1). If v3 is declared canonical and v1 retired without action,
this course is permanently lost.

---

## 2. Inventory (computed, both sources)

| Metric | v3 (canonical) | v1 (app) |
|--------|---------------:|---------:|
| Courses | **55** | **49** |
| Learning points | **247** | **217** |
| Quiz items | **1,671** | **1,703** |
| LPs with 0 quiz items | 34 | 0 |
| Course-YAML parse errors | 0 | 0 |

### Course-code correspondence

- **In both (49):** A1–A5, B1–B6, C1–C5, D1–D6, E1–E5, F1–F4, G1–G4, H1–H4,
  I1–I3, J1–J7.
- **v3-only (6, all NEW):** `A6` Confession as Encounter · `A7` Praying the Mass ·
  `A8` Silence in the Mass · `B7` What Prayer Is Not (Apophatic Primer) ·
  `D7` Renouncing the Lies of the Enemy · `D8` Renewal of the Mind.
- **v1-only:** none. (v1 is a strict code-subset of v3.)

The +30 LPs in v3 (247 vs 217) come from: the 6 new courses (29 LPs) + the
rewritten `D6` (+1 LP, 5 vs 4). All 30 new/rewritten LPs carry **no quizzes yet**.

---

## 3. Per-course quiz delta (49 shared courses)

**48 of 49 shared courses are identical in LP count AND quiz count.** Only `D6`
differs.

| Course | v1 LP | v3 LP | v1 quiz | v3 quiz | Δ (v1−v3) |
|--------|------:|------:|--------:|--------:|----------:|
| **D6** | 4 | 5 | **32** | **0** | **+32 (v1 more)** |
| all other 48 shared | = | = | = | = | 0 |

- Courses where **v1 has MORE** quiz items: **`D6` only** (+32).
- Courses where **v3 has MORE** quiz items: **none**.
- v3-only quiz IDs (present v3, absent v1): **0**.
- v1-only quiz IDs (present v1, absent v3): **32 — all in `D6`.**

Full per-course table in the machine-readable appendix (§7).

---

## 4. The 32 v1-only quiz items (what would be lost)

All 32 belong to v1 `D6` "Discernment in Daily Life". Matched by
`(learning-point id + normalised question text)` **and** confirmed absent from v3
by full-item hash. Complete ID list:

```
D6.01.q1–q8   From Theory to Practice
D6.02.q1–q8   Discernment in Relationships
D6.03.q1–q8   Discernment in Decision-Making
D6.04.q1–q8   The Ebb and Flow of the Spiritual Life
```

Type mix: multichoice ×4, truefalse ×16, fillinblank ×9, matching ×3.

### 4.1 Concrete samples (verbatim from v1 `D6.yaml`)

**`D6.01.q1`** (multichoice, standard)
> Q: *What is the primary tool for applying discernment in daily life?*
> - ✅ The Daily Examen — a regular review of consolation and desolation
>   *(fb: Correct. The examen is your primary tool; the 14 rules are your reference guide.)*
> - ❌ A weekly study group on discernment theory
> - ❌ Memorising all 14 rules perfectly
> - ❌ Avoiding all difficult situations

**`D6.02.q3`** (matching, standard)
> Q: *Match each relational experience to its likely source.*
> - Feeling encouraged and outward-focused → God (consolation)
> - Feeling drained and self-absorbed → Enemy (desolation)
> - Desire to serve others → God (consolation)

**`D6.03.q1`** (multichoice, standard)
> Q: *When should big decisions NEVER be made?*
> - ✅ In desolation — decisions then are unreliable (Rule 5)
>   *(fb: Correct. Rule 5 applies directly to decision-making.)*
> - ❌ In consolation — you might be too optimistic
> - ❌ On weekdays — decisions should be made on Sundays
> - ❌ When you have complete information

These are pedagogically sound Ignatian-discernment-application items. Several
other `D6` items are lower-quality auto-generated artifacts (e.g. `D6.02.q4`
"Ignatius of Loyola writes: The Church Fathers writes: The Catechism (PD)
writes: St." — a malformed stem), so a fold-back should be a curated lift, not a
blind copy.

---

## 5. Schema drift (v1 1.0.0 → v3 3.0.0)

Field presence counted across every course/LP/quiz item in each tree.

### Course level — v3 ADDS fields; drops none

| Field | v1 | v3 | Note |
|-------|----|----|------|
| code, title, category, category_name, sessions, prerequisites, certificate_quote, learning_points | ✅ | ✅ | shared |
| certificate_source | 48/49 | 55/55 | v1 missing on 1 course |
| **schema_version** | — | 55/55 | v3 new (MUST = 3) |
| **paradigm** {primary, supporting} | — | 55/55 | v3 nav rail |
| **tier** {min, max} | — | 55/55 | Disciplines-Tree 0–5 |
| **tags** (namespaced) | — | 55/55 | saints:/topic:/state:/… |
| **pathways** | — | 55/55 | curated ordered lists |
| **retreat_source** | — | 13/55 | provenance (swados/itd/pp) |

### Learning-point level — identical key set

Both use exactly: `id, title, session, depths, quiz_items, practice,
related_points, dogmatic_propositions, catechism_paragraphs`. No new LP-level
fields in v3. Differences are population, not schema:
- `quiz_items`: v1 217/217 LPs, v3 213/247 LPs (34 v3 LPs have none — see §6).
- `depths`: v1 every LP has 5 levels (short/standard/longer/detailed/advanced).
  v3 varies (standard 246/247, longer 238, detailed 213, advanced 213) — the new
  courses ship incomplete depth ladders too.
- Schema comments describe a 6th `scholar` depth; **neither tree actually authors
  it** — both cap at `advanced`.

### Quiz-item level — ZERO schema drift

Identical key vocabulary in both, per type:
`id, question, type, difficulty` + `options` (multichoice) /
`correct_answer, feedback_correct, feedback_incorrect` (truefalse) /
`template, blanks, accept_alternatives` (fillinblank) / `pairs` (matching) /
`feedback` (shortanswer). **Folding v1 quiz items into v3 needs no field
mapping** — drop them in as-is.

> Minor doc-only drift: v3 `schema.yaml` lists quiz `type` as
> `multichoice | truefalse | shortanswer`, but real data in both trees also uses
> `fillinblank` and `matching`. Cosmetic; the build script handles all five.

### 5.1 Broken provenance (action-relevant)

`~/dir/courses_v3/catalog/D6.yaml` header states the old content is
"preserved at `~/dir/courses_v3/history/ss_v1/courses/D6.yaml`". **That file does
not exist.** `history/ss_v1/courses/` contains only lightweight `*.md` outlines
(e.g. `D6.md`) with titles + short summaries and **no quiz items and no
full-depth text**. Therefore the *only* complete copy of v1 `D6` is the untracked
app YAML. Treat it as unbacked primary data.

---

## 6. Recommended merge procedure (steps — NOT executed)

> ⚠️ **THIS IS AN IRREVERSIBLE DATA MERGE. NEEDS HUMAN EYES BEFORE EXECUTING.**
> The v1 `D6` content is unbacked (its stated backup is missing, §5.1) and the
> `D6` code was deliberately repurposed. No script should auto-resolve the code
> collision or delete the app tree. Operator decides fate of v1 `D6` first.

Because the two trees are otherwise identical (1,671/1,671 shared items hash-equal),
this is **not** a broad content merge. It reduces to two operator decisions and a
retire step.

**Step 0 — Freeze & snapshot.** Copy `~/nwp/sites/ss2/dev/data/learning-points/`
to a dated, read-only archive before touching anything (it is untracked and its
`D6` is the sole surviving copy).

**Step 1 — DECIDE the fate of v1 `D6` "Discernment in Daily Life" (operator).**
Options:
  - (a) **Intentionally retired** — accept the v3 `D6` swap; drop v1 `D6`. Record
    the decision in ops#61. (Then its 32 quizzes are deliberately dropped, and the
    ops#61 count discrepancy is closed with an explanation, not a merge.)
  - (b) **Re-slot** — the "discernment application" material is still wanted; move
    v1 `D6` to the next free D-code (**`D9`**), rewriting `code:` and every
    `D6.xx`/`D6.xx.qN` id → `D9.xx`/`D9.xx.qN`, add the v3 course-level fields
    (schema_version, paradigm, tier, tags, pathways), then curate the 32 quiz
    items (some are malformed auto-gen, §4.1). Add to v3 catalog as a new file.

**Step 2 — Repair provenance regardless of Step 1.** Write the true full v1 `D6`
YAML into `history/ss_v1/courses/D6.yaml` (or fix the header pointer) so the
"preserved at …" claim in `D6.yaml` becomes accurate.

**Step 3 — Confirm no other fold needed.** Already verified: the other 48 shared
courses + 1,671 shared items are hash-identical; the 6 v3-only courses have no v1
counterpart. Nothing else to reconcile. (The 34 zero-quiz LPs in v3 are *forward
authoring* work — new content awaiting quizzes — **not** a v1→v3 reconciliation
item; track separately.)

**Step 4 — Declare v3 canonical.** With Step 1 resolved, v3 `catalog/` is the
single source of truth (superset structure + v3 schema).

**Step 5 — Retire v1 / re-point the app.** Change `build_seed_db.py`
`DEFAULT_YAML_DIR` to consume `~/dir/courses_v3/catalog` (add a `schema.yaml`
skip and tolerate the v3-only fields — the builder already ignores unknown keys;
verify). Rebuild `courses.db`, regenerate the app seed, and **delete the cached
app DB** per MEMORY (`~/.local/share/org.nwpcode.faith_formation/courses.db`) so
the new seed takes. Then archive (do not delete) the old app tree.

**Step 6 — Verify parity.** Rebuild the seed DB from v3 and diff course/LP/quiz
counts against this report's expected post-merge totals before retiring anything.

---

## 7. Machine-readable appendix

### 7.1 Per-course `(v1_lp, v1_quiz, v3_lp, v3_quiz)` — all 55 codes

`null` = course absent in that source. Only `D6` has a non-zero, non-null delta.

```json
[
 {"course":"A1","v1_lp":4,"v1_quiz":31,"v3_lp":4,"v3_quiz":31},
 {"course":"A2","v1_lp":5,"v1_quiz":39,"v3_lp":5,"v3_quiz":39},
 {"course":"A3","v1_lp":4,"v1_quiz":29,"v3_lp":4,"v3_quiz":29},
 {"course":"A4","v1_lp":4,"v1_quiz":32,"v3_lp":4,"v3_quiz":32},
 {"course":"A5","v1_lp":4,"v1_quiz":32,"v3_lp":4,"v3_quiz":32},
 {"course":"A6","v1_lp":null,"v1_quiz":null,"v3_lp":5,"v3_quiz":0},
 {"course":"A7","v1_lp":null,"v1_quiz":null,"v3_lp":5,"v3_quiz":0},
 {"course":"A8","v1_lp":null,"v1_quiz":null,"v3_lp":5,"v3_quiz":0},
 {"course":"B1","v1_lp":4,"v1_quiz":30,"v3_lp":4,"v3_quiz":30},
 {"course":"B2","v1_lp":5,"v1_quiz":38,"v3_lp":5,"v3_quiz":38},
 {"course":"B3","v1_lp":6,"v1_quiz":47,"v3_lp":6,"v3_quiz":47},
 {"course":"B4","v1_lp":4,"v1_quiz":32,"v3_lp":4,"v3_quiz":32},
 {"course":"B5","v1_lp":5,"v1_quiz":42,"v3_lp":5,"v3_quiz":42},
 {"course":"B6","v1_lp":4,"v1_quiz":32,"v3_lp":4,"v3_quiz":32},
 {"course":"B7","v1_lp":null,"v1_quiz":null,"v3_lp":5,"v3_quiz":0},
 {"course":"C1","v1_lp":4,"v1_quiz":28,"v3_lp":4,"v3_quiz":28},
 {"course":"C2","v1_lp":4,"v1_quiz":28,"v3_lp":4,"v3_quiz":28},
 {"course":"C3","v1_lp":5,"v1_quiz":40,"v3_lp":5,"v3_quiz":40},
 {"course":"C4","v1_lp":5,"v1_quiz":40,"v3_lp":5,"v3_quiz":40},
 {"course":"C5","v1_lp":4,"v1_quiz":32,"v3_lp":4,"v3_quiz":32},
 {"course":"D1","v1_lp":4,"v1_quiz":28,"v3_lp":4,"v3_quiz":28},
 {"course":"D2","v1_lp":5,"v1_quiz":40,"v3_lp":5,"v3_quiz":40},
 {"course":"D3","v1_lp":5,"v1_quiz":40,"v3_lp":5,"v3_quiz":40},
 {"course":"D4","v1_lp":4,"v1_quiz":32,"v3_lp":4,"v3_quiz":32},
 {"course":"D5","v1_lp":5,"v1_quiz":40,"v3_lp":5,"v3_quiz":40},
 {"course":"D6","v1_lp":4,"v1_quiz":32,"v3_lp":5,"v3_quiz":0},
 {"course":"D7","v1_lp":null,"v1_quiz":null,"v3_lp":5,"v3_quiz":0},
 {"course":"D8","v1_lp":null,"v1_quiz":null,"v3_lp":4,"v3_quiz":0},
 {"course":"E1","v1_lp":5,"v1_quiz":37,"v3_lp":5,"v3_quiz":37},
 {"course":"E2","v1_lp":4,"v1_quiz":30,"v3_lp":4,"v3_quiz":30},
 {"course":"E3","v1_lp":4,"v1_quiz":31,"v3_lp":4,"v3_quiz":31},
 {"course":"E4","v1_lp":5,"v1_quiz":40,"v3_lp":5,"v3_quiz":40},
 {"course":"E5","v1_lp":5,"v1_quiz":40,"v3_lp":5,"v3_quiz":40},
 {"course":"F1","v1_lp":4,"v1_quiz":28,"v3_lp":4,"v3_quiz":28},
 {"course":"F2","v1_lp":4,"v1_quiz":31,"v3_lp":4,"v3_quiz":31},
 {"course":"F3","v1_lp":5,"v1_quiz":38,"v3_lp":5,"v3_quiz":38},
 {"course":"F4","v1_lp":4,"v1_quiz":32,"v3_lp":4,"v3_quiz":32},
 {"course":"G1","v1_lp":5,"v1_quiz":40,"v3_lp":5,"v3_quiz":40},
 {"course":"G2","v1_lp":4,"v1_quiz":32,"v3_lp":4,"v3_quiz":32},
 {"course":"G3","v1_lp":4,"v1_quiz":32,"v3_lp":4,"v3_quiz":32},
 {"course":"G4","v1_lp":4,"v1_quiz":32,"v3_lp":4,"v3_quiz":32},
 {"course":"H1","v1_lp":5,"v1_quiz":40,"v3_lp":5,"v3_quiz":40},
 {"course":"H2","v1_lp":5,"v1_quiz":40,"v3_lp":5,"v3_quiz":40},
 {"course":"H3","v1_lp":4,"v1_quiz":32,"v3_lp":4,"v3_quiz":32},
 {"course":"H4","v1_lp":4,"v1_quiz":32,"v3_lp":4,"v3_quiz":32},
 {"course":"I1","v1_lp":5,"v1_quiz":40,"v3_lp":5,"v3_quiz":40},
 {"course":"I2","v1_lp":4,"v1_quiz":32,"v3_lp":4,"v3_quiz":32},
 {"course":"I3","v1_lp":4,"v1_quiz":32,"v3_lp":4,"v3_quiz":32},
 {"course":"J1","v1_lp":5,"v1_quiz":40,"v3_lp":5,"v3_quiz":40},
 {"course":"J2","v1_lp":4,"v1_quiz":32,"v3_lp":4,"v3_quiz":32},
 {"course":"J3","v1_lp":4,"v1_quiz":32,"v3_lp":4,"v3_quiz":32},
 {"course":"J4","v1_lp":5,"v1_quiz":40,"v3_lp":5,"v3_quiz":40},
 {"course":"J5","v1_lp":4,"v1_quiz":32,"v3_lp":4,"v3_quiz":32},
 {"course":"J6","v1_lp":4,"v1_quiz":32,"v3_lp":4,"v3_quiz":32},
 {"course":"J7","v1_lp":5,"v1_quiz":40,"v3_lp":5,"v3_quiz":40}
]
```

### 7.2 `(course, lp, source, quiz_count)` for the divergent + new content

The 48 hash-identical shared courses are omitted here for brevity (v1 == v3, see
7.1). Rows below cover the only actionable content: v1-only `D6` LPs, the v3
`D6` rewrite, and the 6 new v3-only courses.

```json
[
 {"course":"D6","lp":"D6.01","source":"v1","quiz_count":8},
 {"course":"D6","lp":"D6.02","source":"v1","quiz_count":8},
 {"course":"D6","lp":"D6.03","source":"v1","quiz_count":8},
 {"course":"D6","lp":"D6.04","source":"v1","quiz_count":8},
 {"course":"D6","lp":"D6.01","source":"v3","quiz_count":0},
 {"course":"D6","lp":"D6.02","source":"v3","quiz_count":0},
 {"course":"D6","lp":"D6.03","source":"v3","quiz_count":0},
 {"course":"D6","lp":"D6.04","source":"v3","quiz_count":0},
 {"course":"D6","lp":"D6.05","source":"v3","quiz_count":0},
 {"course":"A6","lp":"A6.01..A6.05","source":"v3","quiz_count":0},
 {"course":"A7","lp":"A7.01..A7.05","source":"v3","quiz_count":0},
 {"course":"A8","lp":"A8.01..A8.05","source":"v3","quiz_count":0},
 {"course":"B7","lp":"B7.01..B7.05","source":"v3","quiz_count":0},
 {"course":"D7","lp":"D7.01..D7.05","source":"v3","quiz_count":0},
 {"course":"D8","lp":"D8.01..D8.04","source":"v3","quiz_count":0}
]
```

Full 464-row `(course, lp, source, quiz_count)` and the 32 v1-only quiz items
(with full option/feedback bodies) were generated during analysis and can be
regenerated deterministically from the two source trees via the parse script if a
build agent needs the exhaustive per-LP form.

---

## 8. One-paragraph summary for the operator

v3 and v1 are **not** genuinely divergent content sources: 1,671 of their quiz
items share IDs and are **byte-identical**, and 48 of 49 shared courses match
exactly. v3 is the clean structural superset (55 vs 49 courses, 247 vs 217 LPs,
plus the v3 nav schema). The entire 1,703-vs-1,671 discrepancy is a single
**deliberate** course swap: v1 `D6` "Discernment in Daily Life" (4 LPs, 32
quizzes) was replaced under the same code by v3 `D6` "Fight, Don't Run" (5 LPs, 0
quizzes). The 32 "extra" v1 items are all `D6`, and the full v1 `D6` course
exists only in the untracked app file (its documented backup is missing). Decide
whether to retire v1 `D6` or re-slot it to `D9`, repair the broken history
pointer, then declare v3 canonical and re-point the app builder — no other fold
is required.
