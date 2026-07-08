# P72 — Moodle → nwc "suggest edit / new variant" bridge

**Status:** PROPOSED — 2026-07-09.
**Author:** Robert Karsten Zaar (with AI assistance).
**Parent / anchor:** [ADR-0027 §10](../decisions/0027-unified-course-content-architecture.md)
("Editorial signal is direct-to-Drupal, exported to canonical on approve").
**Depends on (all unbuilt or partial):**
[F26](F26-avc-ss-oidc.md) OIDC (DESIGNED-ONLY, scoped AVC↔SS — see §3),
**ops#50** nwc authoring surface (the *create* form — unbuilt; today `nwc_editorial` can only
*transition* an existing revision, not originate one — see §2),
[P70](P70-audience-variants-and-learnersourced-stories.md) atom typing (`core` / `contrast` /
`variants` / `contributed`),
[ADR-0027](../decisions/0027-unified-course-content-architecture.md) canonical model + ceremony
spectrum.
**Related rails (already work, downstream of a created revision):** `nwc_editorial` A30 state
machine, the P64 / ops#60 write-back, P65 / ops#32 seed-content lifecycle.

---

## 1. What this proposes

A learner reading a learning point on **ss** (Moodle `mod_depthcontent`) can click **"Suggest an
edit / propose a variant"** on a specific *atom* (core text, an audience variant, a quiz item, or a
media slot). That click carries them — **authenticated, no second login** — into **nwc** (Drupal),
where it opens a pre-populated **"propose revision"** form that creates an `editorial_revision`
routed to the owning guild's review queue. From there, everything is already built: the A30
pipeline reviews it, and on approval the P64 rail exports it to canonical `nwp/courses`.

This is the concrete build-out of **ADR-0027 §10**, which states the architecture but flags that
"this whole leg is front-of-pipeline net-new, gated on F26." P72 specifies that net-new front of
pipeline.

```
  ss / mod_depthcontent (learner)                      nwc / Drupal (editorial)
  ────────────────────────────────                     ────────────────────────
  [Suggest edit / propose variant]  ── deep-link ──►   F26 OIDC auth hand-off
   per-atom affordance (§4a)          (§4b context)     (§4c) ──► "propose revision"
                                                                  CREATE form (§4d, ops#50)
                                                                        │ creates
                                                                        ▼
                                                          editorial_revision (routed to guild)
                                                                        │  A30 (already built)
                                                                        ▼
                                                          approve ─► P64 export ─► nwp/courses
```

**Scope of this document:** the *front of pipeline* only — the affordance, the deep-link, the auth
hand-off, and the create form / entity fields. Everything downstream of a created revision is
explicitly out of scope (it already works). This is a **spec**; its auth leg (F26) is
**human-gated** for build and merge — see §5.

---

## 2. The front-of-pipeline gaps (all net-new)

Today, nothing connects a Moodle reader to the nwc editorial pipeline, and the pipeline itself has
no *originate* entry point. Four gaps, each net-new:

### (a) A per-atom "suggest edit / variant" affordance in `mod_depthcontent` render

`sites/ss2/dev/mod/depthcontent/view.php` renders a learning point as depth-tagged sections
(`.dc-depth-section[data-depth-level]`), inline/grouped quiz items
(`.dc-quiz-item[data-quizitem][data-min-depth]`), and a practice block. **None of these carry a
"suggest an edit" control today.** The existing S13 feedback panel (`.dc-fb-btn`, driven by
`depthcontent_fb_state`) is a *different, in-Moodle* mechanism and must not be conflated with this
(see §6).

P72 adds a small per-atom control — one affordance next to each editable atom, distinguishing atom
type so the deep-link can carry it:

| Rendered element (today) | Atom type carried | Notes |
|---|---|---|
| `.dc-depth-section` body text | `core` (or `variant` if that depth section is audience-framed) | the invariant vs. framing distinction is P70's; see §4b |
| `.dc-quiz-item` | `quiz` | quiz item's `data-quizitem` id becomes `slot` |
| media (image / audio / clip slot) | `media` | slot id from the render |
| a variant intro / example block (P70 `variants:`) | `variant` | carries `slot` + `audience` |

The control is **render-only** and reads the (course, lp, depth, audience, atom) coordinates already
present in the page. It does **not** write anything in Moodle — Moodle is a disposable render target
(ADR-0027 Decision 1 / P70 §2); the signal must leave for nwc.

### (b) A deep-link carrying the atom coordinates

The affordance links to an nwc route, carrying enough to identify the atom uniquely:

```
https://<nwc-host>/nwc/editorial/propose
    ?course_id=<canonical course id>
    &lp_id=<learning-point id, e.g. mp.method.reflect>
    &depth=<short|standard|longer|detailed|advanced>
    &audience=<youth|single|married|religious|priest|_none_>
    &atom_type=<core|variant|quiz|media>
    &slot=<slot/quizitem/media id, when atom_type≠core>
```

These coordinates are exactly P70's atom key `(course_id, lp_id, depth, audience, slot)` plus the
atom type. They are canonical-model coordinates, **not** Moodle row ids — so the same deep-link
shape works from the Flutter app or nwc's own render later. `course_id` / `lp_id` must be the
canonical ids (present in `content_json`), not Moodle's `cm->id` / instance id.

### (c) The F26 OIDC authenticated hand-off

The learner is authenticated on ss (Moodle). The deep-link must land them **already
authenticated** on nwc (Drupal) so the created revision is attributed to a real member — with **no
second login**. That cross-domain single sign-on is exactly **F26 OIDC**, which is designed only,
not built, and is currently scoped AVC↔SS. P72 needs it extended to **nwc↔ss** (§3). Until that
lands, the whole leg cannot ship — an unauthenticated hand-off would create orphan/anonymous
revisions and defeat member-level attribution (ADR-0027 Decision 6).

### (d) The nwc "propose revision" CREATE form — the unbuilt ops#50 authoring surface

**This is the load-bearing gap.** Today `nwc_editorial` can only **transition** a revision that
already exists — it cannot **originate** one:

- `nwc_editorial.routing.yml` exposes exactly three surfaces: `my_work` (dashboard),
  `transition_form` (`/nwc/editorial/revision/{editorial_revision}/transition`), and the
  pipeline-audit queue. **There is no create route.**
- `TransitionForm` (`src/Form/TransitionForm.php`) takes an existing `EditorialRevision` as a route
  parameter and only advances / revises / escalates / rejects / claims / clears it. Its own doc
  comments twice defer to "the ops#50 authoring surface" for the *create* / rich-text-preview side
  (see the `$body` render comment and the `subject_ref` gap below).
- So a revision is assumed to *already exist*; nothing in the module lets a user bring one into
  being.

P72 requires building that create surface (ops#50): a new route (e.g.
`nwc_editorial.propose` → a `ProposeRevisionForm`) and a permission (e.g. `originate editorial
revision`, distinct from the existing `transition editorial revision`) that any authenticated
member may hold. The form:

1. Reads the deep-link coordinates (§4b) into hidden/derived fields.
2. Resolves-or-creates the target **`EditorialArtifact`** for `(course_id, lp_id)` and records the
   atom coordinates as **structured context** (new fields — see below).
3. Sets `author` = the F26-resolved member uid, `origin = human`.
4. Maps `atom_type → change_kind` (see below) to pick the correct A30 stage path.
5. Creates the `EditorialRevision` in `state = draft` and submits it, entering the existing A30
   machine at the first stage its `change_kind` dictates — routed to the owning guild's pool by the
   existing `EditorialPoolResolver`.

#### New structured context fields (there is only unstructured `subject_ref` today)

`EditorialArtifact` currently carries a single free-form `subject_ref` string
(`'External reference (e.g. node:42, ss_session:foo)'`) — too weak to carry the five-part atom key,
and it forces every consumer to re-parse a string. P72 adds **structured** context so routing,
de-duplication, and write-back are deterministic. Preferred home: on `EditorialArtifact` for the
atom's *location*, on `EditorialRevision` for the *atom being changed*:

| Entity | New field | Type | Purpose |
|---|---|---|---|
| `EditorialArtifact` | `canonical_course_id` | string | canonical course id (P70 key part 1) |
| `EditorialArtifact` | `canonical_lp_id` | string | learning-point id (P70 key part 2) |
| `EditorialRevision` | `atom_type` | list_string: `core` / `variant` / `quiz` / `media` | which kind of atom |
| `EditorialRevision` | `atom_depth` | list_string: `short`…`advanced` | P70 depth axis |
| `EditorialRevision` | `atom_audience` | list_string: `youth`/`single`/`married`/`religious`/`priest`/`_none_` | P70 audience axis (open list, ADR-0027 Dec. 1) |
| `EditorialRevision` | `atom_slot` | string | slot / quizitem / media id (empty for `core`) |
| `EditorialRevision` | `origin_render_target` | list_string: `moodle` / `flutter` / `drupal` | where the suggestion came from (provenance) |

`subject_ref` is retained (backwards compatibility) but the new fields become the routing/write-back
source of truth. The nightly P64/P70 write-back (which upserts the `contributed:` / `variants:`
block of the target LP's YAML) reads these structured fields rather than parsing `subject_ref`.

#### `atom_type → change_kind` mapping

The create form derives the A30 `change_kind` (already an enum on `EditorialRevision`, driving which
stages apply per ADR-0006) from the atom being edited, defaulting conservatively (the user may
refine within the allowed set for that atom):

| `atom_type` | proposed default `change_kind` | rationale / gate |
|---|---|---|
| `core` (existing text edit) | `clarity` — or `doctrinal` / `factual` if the user flags it | **core is the invariant** (P70). A `core` edit that touches meaning is `doctrinal` → the Theology/Sojourners gate (see §3.1). Never silently allow a `core` rewrite to skip theology review. |
| `core` (proposing *new* framing) | `new_content` | typically the user actually wants a **variant**, not a core edit — the form should nudge toward `variant` (below) |
| `variant` (new/edited audience framing) | `pedagogy` | lands at `in_pedagogy_review` — the Pedagogy Guild's existing queue (matches P70 §5 step 4) |
| `quiz` | `pedagogy` (content) or `factual` (wrong answer) | pedagogy queue; a wrong-key report is `factual` |
| `media` | `new_content` | a new/replacement media slot; may also touch `safeguarding` if it depicts people |

A `contributed` *story* (a learner's own anecdote) is **not** this form — that is P70's
`story_contribution` micro-loop (peer-vote triage first). P72 is the **authored-edit / variant**
path — the middle of ADR-0027 §5's ceremony spectrum ("authored, within a community → normal
editorial pipeline → `nwc_editorial`"), not the micro end.

---

## 3. The F26 dependency + scope gap

ADR-0027 §10 names the hard dependency plainly: "the authenticated cross-domain hand-off is F26
OIDC, which is designed only, not built, and is currently scoped AVC↔SS — extending it to nwc↔ss is
a prerequisite."

### 3.1 F26 as written is AVC↔SS only — and says so as a non-goal

F26 §2 lists, under **Non-goals**: *"Not a general SSO for all NWP sites. F26 is AVC↔SS
specifically. Adding another site to this SSO graph is out of scope and would require a separate
proposal."* F26's whole architecture (§3) makes **AVC the OIDC issuer** (`simple_oauth`) and **SS
the client** (`auth_oidc`), locking Moodle's `idnumber` to the AVC uid on first login.

P72 needs the identity to resolve into **nwc**, not AVC — because the editorial pipeline, the guild
membership, and the member attribution (ADR-0027 Decision 6) all live in **nwc/Drupal**, and nwc
(not avc) is the canonical 2.0 site. So this is not "reuse F26 as-is"; it is a **scope extension**.

### 3.2 The nwc↔ss scope extension P72 requires

Two viable shapes; the choice is an operator/F26-author decision, flagged here:

1. **nwc becomes the issuer for ss** (mirror F26's AVC-issuer design onto nwc): `simple_oauth` on
   nwc, `auth_oidc` on ss pointed at nwc's `.well-known/openid-configuration`, Moodle `idnumber`
   locks to the **nwc** uid. Cleanest for P72 (the identity that lands is already an nwc member), but
   it means ss has *two* potential issuers (avc for legacy AVC users, nwc for nwc users) — a graph
   F26 explicitly deferred.
2. **nwc as a second relying party behind the same issuer**: keep F26's issuer, add nwc as an
   additional OIDC client, and reconcile the ss learner's identity to an nwc member. More moving
   parts; keeps one issuer.

Either way this is **a new auth-graph edge F26 did not design**, and per F26's own non-goal it
"would require a separate proposal." P72 *is* the proposal that requests it — but the **build and
review of that auth edge is F26/human-owned**, not P72-owned (§5). P72 specifies the *consumer*
contract (a hand-off that lands an authenticated nwc member on the propose form); it does **not**
authorise autonomously building the SSO.

### 3.3 What P72 can build without F26, and what it cannot

- **Buildable now (no auth surface):** the ops#50 create form + new structured fields +
  `atom_type → change_kind` mapping + the `mod_depthcontent` affordance + deep-link **shape**. These
  can be built and tested with an ordinary logged-in nwc session (the operator/author logs into nwc
  directly, pastes/loads the coordinates). This exercises the entire front-of-pipeline **except**
  the cross-domain identity hop.
- **Blocked on F26 (auth surface, human-gated):** the actual cross-domain authenticated hand-off
  from a Moodle session into an nwc session. Do not stub this with a shared secret, a bearer token
  in the URL, or an "auto-create anonymous user" shortcut — any of those is an auth-surface change
  that must go through the human review gate (§5), and several would violate the threat model
  outright.

---

## 4. Design detail (front-of-pipeline)

*(4a–4d correspond to the four gaps in §2; consolidated here for the builder.)*

- **4a Affordance:** a per-atom control rendered in `view.php`, reading atom coordinates already on
  the page. Visible to authenticated learners with a new capability (e.g.
  `mod/depthcontent:suggestedit`). No Moodle-side persistence.
- **4b Deep-link + the core-vs-variant call:** the render must decide whether a depth section is
  `core` (invariant) or a `variant` (audience framing) — P70 §3 makes atoms typed in canonical YAML,
  so `content_json` should carry the atom type through to the render; the affordance reads it. If a
  section's atom type is not yet carried (pre-P70 flat LP), default to `core` and `change_kind =
  clarity` (conservative — routes through theology if it touches meaning).
- **4c Auth hand-off:** F26 OIDC (nwc↔ss extension, §3) — **human-gated build**.
- **4d Create form (ops#50):** new `nwc_editorial.propose` route + `ProposeRevisionForm` +
  `originate editorial revision` permission + the new structured fields (§2d). Resolves-or-creates
  the `EditorialArtifact`, creates the `EditorialRevision`, submits into A30.

---

## 5. SECURITY FLAG — F26 is an auth surface; its build is human-gated (not autonomous)

**This must not be lost.** F26 is an **authentication surface**. Under the NWP threat model
(CLAUDE.md — "Authentication/Authorization Changes" are High-Risk / Block-and-Escalate; ADR-0017
trust boundaries) **and F26's own §4.4 review gate** (1 human approver during build-out, 2 once live
in prod), the OIDC hand-off:

- **MUST get human review before merge.** It may **NOT** be built and merged autonomously overnight
  by the self-healing loop or any agent. An agent may draft/spec it (this document); it may not ship
  the auth edge.
- The **nwc↔ss scope extension (§3.2)** is a *new auth-graph edge F26 explicitly deferred* — it
  therefore needs at least the same human sign-off as F26 itself, applied to the new edge.
- **No shortcuts.** No shared-secret hand-off, no bearer token in the deep-link, no "auto-create
  anonymous contributor," no copying signing keys into a preview (F26 §4.1 makes the last one
  load-bearing). Any of these is an auth-surface change and hits the same gate.

**This proposal is a spec.** Its *authoring-surface* half (ops#50 create form, structured fields,
mapping, affordance) is ordinary feature work and can proceed on the normal path. Its *auth* half
(F26 nwc↔ss) is **human-gated** and is a prerequisite that P72 requests but does not itself
authorise building.

---

## 6. Do not conflate with the existing S13 in-Moodle feedback

`mod_depthcontent` already has an S13 feedback loop — the `.dc-fb-btn` "Help improve this /
Report a problem" panel (`view.php` §S13), backed by `depthcontent_fb_state` and the
`classes/external/feedback.php` web services (`submit_level_a` = clip-vote on a candidate,
`submit_level_b` = thumbs + teaching verdict). That is a **UX precedent** for "a learner can flag an
atom" — the per-atom placement, the warm invitation to help — and P72's affordance (§2a) should
look and feel consistent with it.

But it is a **different mechanism** and must stay separate:

- **S13 stays entirely in Moodle** — it votes on pre-authored clip *choices* (P64 "choice as data,
  not content") within the disposable render target; it does not create editorial revisions and does
  not leave for nwc.
- **P72 leaves Moodle** — it hands a learner into nwc's `nwc_editorial` pipeline to **originate new
  authored content / variants** that flow to canonical.

Conflating them (e.g. routing S13 votes into `editorial_revision`, or rendering P72's control from
`depthcontent_fb_state`) would break both: S13 would gain an auth/cross-site surface it does not
need, and P72 would inherit a vote-triage model meant for a different (micro-loop) ceremony tier.
Keep the two panels visually kin but mechanically distinct.

---

## 7. Implementation order (prerequisite-ordered)

1. **ops#50 create form** — `nwc_editorial.propose` route + `ProposeRevisionForm` + `originate
   editorial revision` permission + new structured fields on `EditorialArtifact` /
   `EditorialRevision` + `atom_type → change_kind` mapping. *Buildable now; no auth surface.*
2. **`mod_depthcontent` affordance + deep-link** — per-atom control in `view.php`, reading atom
   coordinates; links to the propose route. *Buildable now.* (Depends on P70 atoms being carried in
   `content_json` to distinguish core vs. variant; falls back to `core` otherwise.)
3. **F26 nwc↔ss scope extension** — *human-gated* (§5). Blocks the end-to-end authenticated flow.
4. **End-to-end** — with 1–3 in place, a learner on ss clicks "suggest edit," lands authenticated on
   the nwc propose form, and creates a routed `editorial_revision`. Everything downstream (A30
   review, P64 export to `nwp/courses`, P65/ops#32 redistribution) already works.

---

## 8. Consequences

**Positive**
- Closes ADR-0027 §10's named front-of-pipeline gap with a concrete build.
- Gives `nwc_editorial` its missing *originate* entry point (ops#50) — useful well beyond Moodle
  (Flutter and nwc's own render can reuse the same propose route + deep-link shape).
- Replaces the weak free-form `subject_ref` with structured atom coordinates, making routing,
  de-duplication, and write-back deterministic.

**Costs / risks**
- **Hard blocker:** F26 (auth) is designed-only and scoped AVC↔SS; the nwc↔ss edge is net-new and
  human-gated. The authenticated flow cannot ship until it lands.
- Depends on P70 atoms being carried through the Moodle render to distinguish `core` from `variant`;
  without it, the affordance conservatively treats everything as `core`.
- Adds fields to two content entities — a schema/update-hook change in `nwc_editorial` (medium risk,
  ordinary migration).
