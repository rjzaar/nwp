# ADR-0027: Unified Course-Content Architecture — one canonical model, federation by overlay, and the trust-ceremony spectrum

**Status:** Accepted (2026-07-09) — supersedes F30 (specifics), amends P70 (attribution → member-level/CC0)
**Date:** 2026-07-08 (accepted 2026-07-09)
**Decision Makers:** Robert Karsten Zaar (with AI assistance)
**Related Issues:** ops#61 (canonical content model), ops#32 (P65 seed-content lifecycle),
ops#48 (P67 per-site axes), ops#60 (nwc write-back), ops#62 (NWC onboarding + Class-3 preservation)
**References:** [F30](../proposals/F30-content-federation-network.md) (Content Federation Network),
[F26](../proposals/F26-avc-ss-oidc.md) (OIDC), [F28](../proposals/F28-unified-pipeline.md) (signed
pipeline), [F29](../proposals/F29-mayo-comprehensive-integration.md) (mayo integration),
[P64](../proposals/P64-clip-choice-as-data-not-content.md),
[P65](../proposals/P65-seed-content-lifecycle.md),
[P67](../proposals/P67-per-site-workflow-maturity.md),
[P70](../proposals/P70-audience-variants-and-learnersourced-stories.md),
[Pedagogy Guild briefing](../pedagogy/learning-science-foundations.md),
[ADR-0012](0012-cc0-public-domain-dedication.md) (CC0),
[ADR-0017](0017-distributed-build-deploy-pipeline.md) (trust-through-signatures),
[ADR-0005](0005-distributed-contribution-governance.md).

---

## Context

One system — "how course content is authored once and shared across many sites" — is currently
described across **six proposals authored over three months**, agreeing in spirit but drifting in
vocabulary and specifics, none fully built:

| Proposal | Date | The piece it describes | Drift |
|---|---|---|---|
| **F30** Content Federation Network | Apr 2026 | the grand vision: registry, review, overlays, contribute-back, manifests | stale naming (avc / nwpcom.org / saint.school / S05 / `sites/ss/dev/data/…`); depends on F26/F28/F29 (all proposed) |
| **ops#61** canonical content model | Jul 2026 | re-derives F30's "central repository" with *current* reality | authoritative on specifics (nwc / `~/dir/courses_v3` / schema v3) |
| **P64 / ops#60** | Jun–Jul | the contribute-back rail (entity + export) | broken MR path; entity redesign |
| **P65 / ops#32** | Jul | the distribution lifecycle (DRAFT delivery, provenance manifest) | in progress |
| **P67 / ops#48** | Jul | the per-*site* axes (`canonical:`, `maturity:`) | MR !47 in review |
| **P70** | Jul (this session) | atom-grain audience variants + learnersourced stories, grounded in learning science | new |

The felt problem is not that any one is wrong — it is that **there is no single authoritative
statement of the whole**, so "which is canonical?" has no answer. This ADR is that statement. It
supersedes F30's *specifics*, adopts F30's *architecture*, and positions the others as mechanisms.

### Clarifications settled this session (the load-bearing facts)

1. **Moodle is a disposable render target** (ops#61): `populate_courses.php --clear` overwrites
   content; nothing authored *in* Moodle survives. Content is authored in canonical `nwp/courses`.
2. **Audiences need swappable framing, not duplicate courses** (P70): a fixed conceptual core plus
   audience-varied intros/examples/metaphors/application, on a separate depth axis — grounded in
   variation theory, cognitive-load / example-variability, analogical transfer, the personalization
   principle, utility-value motivation, and learnersourcing (see the Pedagogy Guild briefing).
3. **Safeguarding is a *people-interaction* boundary, not a *content* boundary.** The rule is
   *"minors must not interact with unchecked adults."* It isolates **communities and their users**,
   never the content.
4. **Content that passed its origin site's checks flows freely.** The receiving side does not
   re-run the origin's checks; it **verifies provenance** (a signature that the content passed those
   checks) — the NWP threat model's *"trust flows through signatures, not machines"* (ADR-0017).
5. **Content is attributed to the *member*, not the individual author**, and is **CC0**
   (ADR-0012). This one choice satisfies safeguarding + copyright + trust simultaneously (Decision 6).

---

## Decision

### 1. One canonical model, authoritative

The single source of truth is **`nwp/courses`**: authored in **YAML**, distributed as **JSON**,
contracted by a **JSON Schema** (ops#61). F30's *architecture* — federation, adaptation overlays,
contribute-back, three-stage review, per-site manifests, signed distribution — is **adopted**;
F30's *specifics* (old names/paths/S05) are **superseded** by ops#61's current reality. Every render
target is a **pure function of canonical JSON** and is disposable.

```
                         ┌───────────────────────────────────────────┐
                         │   CANONICAL STORE  — nwp/courses (git)      │
                         │   YAML (author) → JSON (dist) → JSON Schema │
                         │   core · contrast · variants · contributed  │
                         │   + audience/depth axes  + adaptations/<m>/ │
                         └───────────────────────┬─────────────────────┘
                                                 │  build = pure function
                     ┌───────────────────────────┼───────────────────────────┐
                     ▼                            ▼                           ▼
             ss mod_depthcontent           Flutter courses.db          nwc / Drupal
             (Moodle — disposable)         (offline app)               (community + render)
                     ▲                                                        ▲
                     └──────────────── all honour the SAME render contract ───┘
                          (depth-gated variant selection — P70 §4)
```

### 2. Two orthogonal boundaries — never conflated

This is the crux the session clarified. Safeguarding lives entirely in the **left** column; content
lives entirely in the **right** column.

```
   COMMUNITY / INTERACTION boundary            CONTENT boundary
   (safeguarding — isolates PEOPLE)            (isolates NOTHING for safeguarding)
   ─────────────────────────────────           ─────────────────────────────────
   • minors ✕ interact-with unchecked adults   • content flows freely once checked
   • per-site community, own user base         • receiver VERIFIES provenance (signature),
   • OIDC trust chains (F26)                      does not re-review
   • F29 two-tier sanitization                 • attributed to the MEMBER, CC0 (Dec. 6)
   • Safeguarding Guild / in_safeguarding_review  • one canonical store, many overlays

        mayo users ──✕──> nwc users            mayo content ──✓──> canonical / other members
        (no cross-community interaction)        (verified, freely shared)
```

**Consequence:** you do **not** fork or isolate the content repo to protect minors. Isolation is
achieved at the community layer; content is shared at the content layer. These are independent.

### 3. Federation by overlay, not fork (uphold F30 §6.5, now more strongly)

A member site (mayo, avcommons, future) is a **federation member**: same canonical code, its own
community + user base, its own **manifest** selecting courses, and an **`adaptations/<member>/`**
overlay carrying only what differs. It is **not** a git fork of the code or a divergent copy of the
content. Because content needs no safeguarding isolation (Decision 2), the F30 argument against
forks (doubled review, catalogue fragmentation, broken contribute-back, sync drift) stands
undiluted. *Single exception, unchanged from F30:* a **hard policy/doctrine split** → a
separate-but-friendly project (different repo, different governance, no content reciprocity).

### 4. Contribute-back = provenance verification, not re-review

Content flows **back** to canonical the same way it flows out — through the signed rail. On ingest
the canonical side does two cheap, automatable things: **verify the member's signature** (proof it
passed the member's checks) and **schema-validate**. It does **not** re-run the member's
safeguarding or authoring review. Two distinct events, do not confuse them:

- **Accept / host** a member's content (stays in `adaptations/<member>/`, served to that member's
  users, offered to opt-in members): **provenance verification only.**
- **Promote** member content into the **shared canonical `courses/`** (becomes the default for the
  whole network): still gets a **Pedagogy + Theology applicability review** (is it well-made and
  doctrinally sound *for everyone*?) — but **safeguarding is not re-run** (it was a people-check at
  origin; the content already cleared the origin's content checks).

### 5. Ceremony scales with trust distance (the unifying principle)

There is one spectrum, not many bespoke workflows. Ceremony is proportional to how far the content
travels and how many users it becomes canonical for:

| Scope | Example | Gate | Mechanism |
|---|---|---|---|
| micro, within a community | a user's story on nwc | peer-vote triage + **light Pedagogy gate** | P70 `story_contribution` + P64 rail |
| authored, within a community | a new `variant` atom | normal editorial pipeline | `nwc_editorial` |
| member-only, cross-community | mayo youth overlay | member's own checks + **signature**; receiver **verifies** | `adaptations/mayo/` + F28 sign |
| promoted to shared canonical | mayo course → everyone | **Pedagogy + Theology** applicability review + MR | F30 three-stage (no safeguarding re-run) |

### 6. Attribution is member-level and CC0 — one move, three wins

Content leaving a site is attributed to the **member organisation** (e.g. *mayo*), **not** the
individual author, and is **CC0** (ADR-0012).

> **Invariant (absolute, all sites, no exceptions):** *No individual contributor is ever
> identifiable once content has left its origin site.* Identity is retained **only inside the origin
> site** — for the generation-effect credit that motivates contribution (Pedagogy briefing
> Principle 7) and for the origin's own moderation/accountability — and is **severed at the site
> boundary**. It never travels with the content, to canonical or to any other member. This holds
> identically for mayo and for every contributing site.

This single rule satisfies:

- **Safeguarding** — no individual identity (adult *or* minor) crosses the community boundary; the
  organisation is the accountable, vouching party.
- **Copyright** — CC0 public-domain dedication means no attribution chains and no per-contributor
  clearance to merge, share, or relicense within the federation (the copyright gate operates on the
  member's attestation, not N individual authors).
- **Trust** — the member's **signature** is the unit of provenance (ADR-0017), exactly the
  granularity Decisions 4–5 verify against.

```
  individual author (private to origin)
        │  writes story/adaptation
        ▼
  ┌──────────────── origin site (e.g. mayo) ────────────────┐
  │  origin checks (pedagogy/safeguarding of PEOPLE) pass    │
  │  strip individual identity → attribute to MEMBER "mayo"  │
  │  mark CC0 · SIGN with member key                         │
  └───────────────────────────┬─────────────────────────────┘
                              │  signed, CC0, member-attributed
                              ▼
        canonical ingest:  VERIFY signature + schema-validate
                              │
              ┌───────────────┴───────────────┐
              ▼                                ▼
     host in adaptations/mayo/        promote to shared courses/
     (provenance only)                (+ Pedagogy+Theology review)
```

### 7. The schema unifies F30 overlays and P70 variant-atoms

An overlay (F30) and a variant-atom (P70) are the same construct — **canonical + delta, merged at
build**. Schema **v3.1** (P70 §3) adds: atom typing (`core` / `contrast` / `variants` /
`contributed`), the **`audience` axis** (`youth · single · married · religious · priest` — open
list, more later) and the **`depth` axis**, `adaptations/<member>/` overlays, and a **per-site
manifest** that selects which courses + audiences a site serves. The **depth-gated render contract**
(P70 §4) — grounded in the learning science — is a property of the canonical model, enforced once in
a shared adapter test-suite.

### 8. Distribution rides existing rails

- **Within the fleet:** the **P65 / ops#32 seed-content lifecycle** — `nwc-content:update` delivers
  canonical updates as **DRAFT revisions, skipping locally-modified content**, tracked by the
  provenance manifest. Do not build a parallel distributor.
- **Cross-site / cross-trust-boundary:** the **F28 signed-artifact pipeline** + **F26 OIDC** trust
  chain. Content-store boundary (ops#62): *community* content → nwc recipe `content/` (Class-3);
  *course* content → `nwp/courses`. Two stores, one rail.

### 9. Site model vs content model — and the birthing ladder

- **Per-site axes** (ops#48): `canonical:` (content flow) and `maturity:` (code flow) — properties
  of a **site**.
- **Audience/depth** — properties of a **content atom**, not a site. "A different framing within a
  community" = an `audience` atom (P70). "A separate community needing isolation" = a **federation
  member** (F30). Same canonical content either way; the two compose via the manifest.
- **An audience is a *lifecycle*, not a fixed choice — the birthing ladder:**

```
  Interest Group  ──promote──▶  Audience Guild  ──birth──▶  Federation member site
  (audience tag,               (owns its variant/story       (own community + users +
   zero overhead,               overlay; routing authority     safeguarding boundary;
   ADR-0002)                    + score; incubating)           overlay travels with it)
        │ triple-test:                │ ops#48 maturity:              │ content still a
        │ bottleneck + 5 members      │ incubating→stabilizing        │ CANONICAL OVERLAY,
        │ + distinct credentialing    │ →production                   │ never a fork
```

  A new audience starts as one block in `interest-groups.yml` (an `application_tag` like `youth`).
  If it earns routing authority (ADR-0002 triple-test — the Media-from-Video-IG precedent), it is
  **promoted to an audience guild** that owns that audience's `variants`/`contributed` atoms — and
  **structurally cannot touch `core`** (it has no `core` atom to edit; the invariant stays with
  Theology/Sojourners). If it grows a full community, it is **birthed into a federation member site**
  (mayo = the first youth birth; F29 bootstraps it, F30 generalises the pattern) — carrying its
  overlay, which **remains a canonical overlay, never a fork.** Promotion and birthing are
  **deliberate governance acts, not automatic thresholds.**

### 10. Editorial signal is direct-to-Drupal, exported to canonical on approve

A "suggest an edit/variant" action from a render target (ss Moodle `mod_depthcontent`) creates an
`editorial_revision` **directly in the nwc Drupal pipeline** (review happens in Drupal), and the
approved result is **exported to `nwp/courses`** (the P64 rail). This **supersedes F30 §6.6's**
git-issue/MR transport (which depended on the also-unbuilt F27) — consistent with retiring F30
(Decision 5) and with ops#61 (git is the canonical *store*; the Drupal pipeline is the *review*).
**Hard dependency:** the authenticated cross-domain hand-off is **F26 OIDC**, which is *designed
only, not built*, and is currently scoped AVC↔SS — extending it to nwc↔ss is a prerequisite. The
nwc-side "propose revision" *create* form (the ops#50 authoring surface) is also unbuilt. So this
whole leg is **front-of-pipeline net-new, gated on F26**; everything downstream of a created
revision already works.

---

## Consequences

**Positive**
- One authoritative model; the six proposals stop competing and become *mechanisms* of one system.
- Safeguarding correctly and cheaply scoped: a people-boundary, so no content re-review on ingest —
  ingest is signature-verify + schema-validate (automatable).
- CC0 + member-attribution removes per-contributor copyright and identity handling in one stroke.
- P70's learning-science render contract is locked to the canonical model, so every target
  (Moodle/app/Drupal) delivers the same pedagogy.

**Costs / risks**
- **Hard prerequisite unchanged:** ops#61 source-reconciliation (v3 catalog 1,671 quizzes vs
  untracked ss2 v1 1,703) must land **before** anything downstream.
- **F26 (OIDC) and F28 (signed pipeline) are load-bearing and still Proposed** — the cross-site half
  of federation cannot ship until they do. The within-fleet half (ops#32) can proceed sooner.
- **F30 needs a rewrite** to current naming, or a note that this ADR + ops#61 supersede its
  specifics; leaving F30 as-is invites the same drift again.
- Member signing keys (who holds mayo's key, how it is provisioned) is a new key-management surface
  (fits ADR-0017's model but must be specified).

**Supersedes / amends**
- **Retires F30** (operator decision 5): F30 is replaced by a "superseded by ADR-0027" note; its
  *architecture* is adopted here, its *specifics* (naming, paths, S05 schema, content in `sites/ss/`)
  are dropped. The buildable cross-site federation work moves to a new re-grounded ops issue.
- **Amends P70:** attribution/`author` handling changes to member-level + CC0 (Decision 6); the
  contributed-story write-back is reframed as the micro end of the Decision-5 spectrum; the
  `audience` vocabulary is fixed to Decision 1.

---

## Implementation path (prerequisite-ordered)

1. **ops#61 item 1** — reconcile the two divergent sources; declare v3 canonical. *(gate)*
2. **Schema v3.1** — atom typing + `audience`/`depth` + `adaptations/<member>/` + manifest +
   validator; migrate flat LPs → single `core`. No behaviour change.
3. **Render contract** in one adapter (ss `mod_depthcontent`, whose build is already being
   un-stripped in ops#61 item 4) + shared adapter test.
4. **Within-fleet distribution** — ride ops#32 items 4/5 (provenance manifest + `nwc-content:update`).
5. **P70 micro-loop** — `story_contribution` (member-attributed, CC0) + peer-vote triage +
   `in_pedagogy_review` gate + write-back.
6. **Federation** — re-ground F30 to this ADR; `adaptations/<member>/` + manifest + F28 signing +
   F26 OIDC; provenance-verify ingest; promotion review. *(blocked on F26/F28)*

---

## Decisions settled 2026-07-08 (operator)

1. **Audience vocabulary** — starting set **`youth · single · married · religious · priest`**, as an
   **open list** (validator warns on unknowns; more added later). Axis stays demographic *audience*;
   a *disposition / state-of-prayer* axis may be proposed by the Pedagogy Guild later.
2. **Contributed-content default tier** — **community tier** (per-site, Class-3) by default;
   promotion into shared canonical `courses/` is a deliberate editorial act, never automatic.
3. **Formative value** — a second **formative / consolation** value axis **exists** and may justify
   keeping an element the strict instructional load-bearing test would cut — **bounded**: named
   explicitly per item by the Pedagogy Guild, and never applied to the opening.
4. **Member signing key** — **each member holds its own key**, provisioned at onboarding; mechanics
   fold into F28 / ADR-0017 key management.
5. **F30 disposition** — **retire F30** (replace with a "superseded by ADR-0027" note); the buildable
   cross-site federation work moves to a new **re-grounded ops issue** (blocked on F26/F28).

## Deferred to the Pedagogy Guild
- The precise semantics of the formative-value axis and its guardrails (Decision 3).
- Whether a *disposition / state-of-prayer* axis should join or replace demographic audience (Dec. 1).
- The atom-type→guild ownership + guild-scoped scoring model (under active research 2026-07-08).
- The render-contract and moderation-rubric specifics in
  [`../pedagogy/learning-science-foundations.md`](../pedagogy/learning-science-foundations.md).
