# P70 — Audience variants + learnersourced stories: schema v3.1 atom-typing and the `story_contribution` write-back

**Status:** PROPOSED — 2026-07-08. Operator decisions this session: (1) write as a short
proposal; (2) capture user-contributed content in **nwc/Drupal** (not Moodle). Ready to schedule.
**Parent:** **ops#61** (canonical CMS-neutral course-content model). P70 is a *scoped extension of
ops#61's schema* — it does not introduce a second source of truth.
**Research base:** two parallel research passes 2026-07-08 — a Moodle-4.5 capability survey and a
learning-science survey — synthesised in
[`docs/pedagogy/learning-science-foundations.md`](../pedagogy/learning-science-foundations.md)
(the Pedagogy Guild briefing). Every design choice below traces to a numbered principle there.
**Reuses:** the **P64 / ops#60** `clip_choice` write-back rail (entity → pending/live → nightly
export to `nwp/courses`) almost verbatim; the existing **`nwc_editorial`** pipeline stage
`in_pedagogy_review` + `CHANGE_PEDAGOGICAL` template; **P65 / ops#32** seed-content lifecycle.
**Prior art:** the roadmap already names *"adaptation overlays — sites create youth adaptations
without forking; overlays contain only what differs"* and `F30-content-federation-network`. P70 is
the **schema formalisation** of that intent.

---

## 1. The question this answers

> Different audiences (youth / parent / priest / general) need different **examples, metaphors,
> intros, and "how to live it" applications** — but the **conceptual core is the same** and must
> not drift. Separately, users should be able to **contribute their own stories/anecdotes**, which
> get **voted on**, with the good ones surfacing. How is this modelled without duplicating courses?

Two orthogonal axes (**depth** — already in schema v3 as `depths`; and **audience** — new), plus a
**learnersourcing** loop. The naïve answer (a course per audience×depth) is rejected: it duplicates
the core N times and drifts — the exact failure already visible as `course-library` v1/v2/v3 in
`~/theocat/private/mental-prayer`.

## 2. Where this lives (inherited from ops#61 — non-negotiable)

Moodle (ss) is a **disposable render target** — `populate_courses.php --clear` overwrites
`depthcontent.content_json`; nothing survives a rebuild. Therefore **audience variants and
contributed stories are authored in the canonical `nwp/courses` YAML**, and every target (ss
`mod_depthcontent`, Flutter `courses.db`, nwc/Drupal) renders them as a pure function of canonical
JSON. Anything authored *in* Moodle — including a Glossary of user stories — would be wiped. This is
the load-bearing constraint that dictates the write-back design in §4.

**Prerequisite:** ops#61 work-item 1 (reconcile the two divergent sources — v3 catalog 1,671
quizzes vs untracked ss2 v1 1,703) must land **first**. Do not vary framing over a core that
disagrees with itself.

## 3. Schema v3.1 — atom typing (the authoring model)

Each learning point gains typed content atoms. Backwards-compatible: an LP with only a flat body is
read as a single `core` atom.

```yaml
id: mp.method.reflect
core:                         # single-sourced. the invariant "object of learning". never varies.
  concept: "Reflection (meditatio) is turning the word over until it moves you to respond."
  method_steps: [ ... ]
contrast:                     # NEW — non-examples that fix the concept boundary (audience-agnostic)
  - "Not analysis: you are not solving the text like a puzzle."
  - "Not just a nice feeling with no response."
variants:                     # swappable framing, tagged by axis
  - { slot: intro,       audience: [youth],  depth: basic,        body: "..." }
  - { slot: example,     audience: [parent],                      body: "..." }
  - { slot: metaphor,    audience: [priest],                      body: "...",
      breaks_down_at: "where the analogy fails — always stated (Principle 4)" }
  - { slot: application, audience: [youth],   prompt_self: true,  body: "..." }
contributed:                  # learnersourced, populated by write-back (§4) after moderation
  - { slot: story, audience: [youth], author: "@u", approved: true, votes: 42, body: "..." }
```

**Controlled vocabularies** (extend `schema.yaml`):
- `audience`: `youth | parent | priest | general` (open list; validator warns on unknown).
- `slot`: `intro | example | metaphor | contrast | application | story`.

**Validator rules** (CI, extends the existing v3 validator): every LP **must** have a `core`;
`metaphor` atoms **must** carry `breaks_down_at`; `variants`/`contributed` **may** be empty.

## 4. The render contract (what adapters MUST do)

Rendering is *not* "show every atom whose audience matches." It is depth-gated, per the learning
science (Principles 2–5):

1. **Always render `core` + `contrast`.** The concept and its boundary are audience-agnostic.
2. **Select `variants` by the reader's `(audience, depth)`.**
3. **Gate variant *count* by depth** (Principle 3 — expertise-reversal is real):
   - `basic` → **one** clean, concrete example; guidance high.
   - `intermediate` → a small set.
   - `advanced` → the full contrasting set; metaphors **rendered in pairs with their
     `breaks_down_at` visible** (Principle 4).
4. **`application` atoms with `prompt_self: true`** render as a *prompt for the reader to write
   their own* connection (Principle 6 — self-generated relevance; the strongest causal motivation
   result, and it feeds §5).
5. **`contributed` stories** render only where `approved: true`, ranked by `votes`.

This contract is identical across ss `mod_depthcontent`, the Flutter app, and nwc/Drupal — it is a
property of the canonical model, enforced once in the adapter test-suite.

## 5. `story_contribution` — capture, vote, moderate, write back (nwc/Drupal)

Modelled directly on P64's `clip_choice` (§entity + pending/live + nightly export). New entity in
`nwc/` (`nwc_features/nwc_story`), keyed by `(course_id, lp_id, depth, audience)`:

| field | purpose |
|---|---|
| `body` | the contributed story/anecdote/example |
| `author` | contributor uid (drives the generation-effect credit, Principle 7) |
| `status` | `pending → in_voting → in_review → approved/rejected` |
| `votes_up` / `votes_down` / `rater_agreement` | triage signals |
| `flag_reason` | auto-set when a triage signal trips (see below) |

**Flow (voting is *triage*, not certification — Principle 7):**
1. **Submit** → `pending`. Contribution is framed in-app as a *spiritual/learning practice*, because
   even a rejected story benefits its author (generation effect). This also fights the 90-9-1
   participation curve — incentivise the *act* of authoring, not just acceptance.
2. **Peer vote** → `in_voting`. Community up/down-votes **rank and surface** candidates. Reuses the
   Drupal voting/flag stack the guild UI already has.
3. **Auto-flag** the suspicious minority — high downvote ratio *or* low rater agreement (the
   RiPPLE / Khosravi signal pattern) — and route **only those**, plus a periodic sample, into the
   formal gate. High-agreement top-voted items still pass through the gate but pre-sorted.
4. **Moderate** → enters `nwc_editorial` as an `editorial_revision`, `change_kind =
   CHANGE_PEDAGOGICAL`, landing at **`in_pedagogy_review`** — the Pedagogy Guild's existing queue.
   The moderator applies the **load-bearing test** (Principle 5): *"remove this — is a required core
   idea lost? If no, it is a seductive detail; cut it."* Stories have no machine-checkable key, so
   this human gate is mandatory. `approved` → `in_production`.
5. **Write back.** A nightly drush job (mirror of P64's `clip_choices_history.jsonl`) appends
   approved `story_contribution` revisions to `contributed_stories_history.jsonl` in `nwp/courses`
   **and** upserts the `contributed:` block of the target LP's catalog YAML. From there the next
   build carries the story to *every* render target. Idempotent; tracks `last_exported_revision_id`.
6. **Distribute — do not reinvent.** Getting an approved story *back out* to the fleet is **not**
   new work: it rides the **P65 / ops#32 seed-content lifecycle**. `drush nwc-content:update`
   already delivers canonical updates to each site **as DRAFT revisions, skipping locally-modified
   content**, tracked by the ops#32 item-4 **provenance manifest** (package version + UUIDs +
   hashes). P70's `variants:` and `contributed:` atoms are just more canonical content flowing that
   rail. Adding a parallel distributor would be wrong.

**Trial before graduation (ops#48).** A contributed story may be routed to a `stabilizing` or a
`pl branch` **twin** for real classroom trial (Trialing Guild, `in_trial`) before it graduates to
`production` sites — reusing the P67 maturity axis and twin-content provenance rather than a bespoke
staging path.

**Package vs instance (P65 / P68).** `core` + authored `variants` = **canonical/package** content;
a site's *own* not-yet-accepted contributed stories = **instance** content. The P68 fail-closed gate
principle applies: a site must not publish another site's un-accepted stories.

**User-facing surface (ops#62).** "Add your story" is **not** a new UI silo: it belongs in the
existing **orientation / glossary page** (nwc `/node/36`) beside the **Help / Feedback /
Report-an-error** section, explained "how + when to use each" in the operator's welcome voice.
Framing the act as a spiritual/learning practice (Principle 7) is exactly that onboarding-voice
concern. New user-facing glossary entries needed: *version/audience, depth, contribute a story*
(distinct from the Pedagogy Guild's internal briefing terms).

**Content-store boundary (do not conflate).** ops#62 / ops#32-item-3 preserve **community/site**
content (help, welcomes, orientation) in the **nwc recipe `content/`** (Class-3, `default_content`,
UUID-keyed YAML). P70's **course** content (`core`/`contrast`/`variants`/`contributed`) lives in
**`nwp/courses`** (ops#61) — a *different* store. A contributed story is *course* content: it writes
back to `nwp/courses`, **not** to the nwc recipe. Two stores, one distribution rail (§5.6).

**Authority** (reuses P64 R3 mitigation): the moderate/approve action is guild-role-gated
(`in_pedagogy_review` pool = Pedagogy Guild); anyone may *submit* and *vote*.

## 6. Two entry doors (unchanged, adapter-side)

Both are projections of the same catalog: **"the journey"** = depth-ordered, completion-gated
pathway (the *paradigm of ascent*); **"browse everything"** = the flat catalog filtered by
`audience`/`depth` custom fields (the *original-ss listing* the operator likes). One source, two
doors — a rendering concern, not a content one.

## 7. Phasing

1. **(prereq) ops#61 item 1** — reconcile the two sources; declare v3 canonical.
2. **Schema v3.1** — add `audience` vocab + atom typing + validator rules; migrate existing LPs
   (flat body → single `core`). No behaviour change yet.
3. **Render contract** — implement depth-gated selection in one adapter (ss `mod_depthcontent`
   preferred, since ops#61 item 4 is already un-stripping its build); add the shared adapter test.
4. **Authoring** — populate `contrast` + a first audience's `variants` for one pilot course
   (mental-prayer is the obvious candidate; its v3 library already implies the structure).
5. **`story_contribution`** — entity + voting + `in_pedagogy_review` routing + nightly write-back.
6. **Second adapter** — Flutter app + nwc/Drupal honour the same contract.

## 8. Relationships

- **ops#61** — parent; this extends its schema and reuses its adapter pattern. *Do not* create a
  parallel content model.
- **P64 / ops#60** — the `clip_choice` write-back rail this copies; generalise, don't reinvent.
- **P65 / ops#32** — the **content-distribution rail P70 rides** (§5.6): `nwc-content:update`
  DRAFT-revision delivery + skip-locally-modified + provenance manifest + package/instance split +
  fail-closed gate. P70 authors *what* varies; ops#32 delivers it. Do not build a parallel pipeline.
- **P67 / ops#48 (MR !47, in review)** — the two per-**site** axes (`canonical:` content-flow,
  `maturity:` code-flow) and `pl branch` twins. P70's `audience`/`depth` are per-**content-atom**
  axes that *compose* with the site model via a per-site manifest (which audiences a site serves);
  contributed stories trial on `stabilizing`/twin sites before graduating (§5).
- **`nwc_editorial` / `nwc_pedagogy_guild` / Trialing Guild** — the review + trial pipeline the
  moderation and trial steps plug into; no new stage, no new template.
- **ops#62 (NWC onboarding)** — supplies the **user-facing surface** (orientation/glossary +
  Help/Feedback/Report-an-error, operator welcome voice) and marks the **content-store boundary**:
  community content → nwc recipe `content/` (Class-3); P70 course content → `nwp/courses`. Same
  distribution rail, different store (§5).
- **Roadmap "adaptation overlays" + F30** — P70 is the schema that makes those buildable. It
  **relocates** the adaptation from a *per-site fork* (roadmap framing) to a *per-atom `audience`
  tag in canonical* selected by a site manifest — resolving the "overlay vs per-site" tension below.

## 9. Open questions (operator / Pedagogy Guild)

1. **Audience vocabulary** — is `youth | parent | priest | general` the right starting set, or add
   e.g. `single`, `religious`, `convert`? (Open list, so cheap to extend.)
2. **Overlay vs per-site** — the roadmap frames adaptations as *per-site overlays*; P70 frames them
   as *audience tags in one canonical LP*, with a **per-site manifest selecting which audiences a
   site serves** (composing with the ops#48 per-site axes). Recommended resolution: audience lives
   in canonical (single-sourced, no fork); the site chooses. Pedagogy Guild to confirm the axis is
   **audience**, not **site**.
3. **Write-back granularity** — nightly batch (P64's choice) vs per-approval commit. Recommend
   nightly.
4. **Voting threshold** — what up/down ratio + minimum rater count promotes a story out of
   `in_voting`? Needs a real number; start conservative, tune with data.
