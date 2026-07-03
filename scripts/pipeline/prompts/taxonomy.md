# Stage 4 — Taxonomy + per-set controlled vocabulary

You are the course architect for the **{{SET_TITLE}}** podcast (set slug `{{SET_SLUG}}`).
Your job: read the episode summaries below and derive a **course taxonomy** and a
**controlled vocabulary** for this set, emitted as a single YAML document.

## Set

- slug: `{{SET_SLUG}}`
- title: {{SET_TITLE}}
- description: {{SET_DESCRIPTION}}

## Hard rule — vocabulary is generated FROM THIS SET, never reused

Controlled vocabularies are **ALWAYS AI-generated per set** from the actual
episode content. **NEVER reuse the Saint School Catholic-theology vocabulary**
(rails like `sacraments`/`prayer`/`ascesis`/`your-yes`, tiers 0–5 of the
Disciplines Tree, tag namespaces like `saints`/`false-teaching`, or its pathway
slugs). Those are Saint School's, not this set's. Invent the rails, tiers, tag
namespaces and pathways that fit **{{SET_TITLE}}**'s subject matter, in the
domain's own language.

## What to emit

A YAML document with exactly these top-level keys. It becomes this set's
`schema.yaml` vocabulary (the same `allowed_*` keys the generic
`validate_catalog.py` reads), plus a `taxonomy` block the next stage turns into
one course per slot.

```
schema_version_expected: 3

# ── controlled vocabulary (derived from THIS set) ──
allowed_paradigm_elements:   # 3–6 top-level "rails"/themes for this podcast
  - <rail-slug>
allowed_tiers: [0, 1, 2, 3]  # a difficulty/progression ladder that fits the set
allowed_tag_namespaces:      # cross-cutting tag namespaces (namespace:slug form)
  - <namespace>
allowed_pathways:            # curated learner journeys, kebab-case slugs
  - <pathway-slug>
allowed_retreat_series: []   # usually empty unless the set has named series

# ── taxonomy: one entry per intended course ──
taxonomy:
  - code: "A1"               # category letter + number (A1, A2, ..., B1, ...)
    title: "<course title>"
    paradigm: <rail-slug>    # MUST be in allowed_paradigm_elements
    tier: 0                  # MUST be in allowed_tiers
    tags: ["<namespace>:<slug>"]
    pathways: ["<pathway-slug>"]
    sessions: 5              # 4–6 (v3 distribution: mostly 4–5)
    episodes: [1, 4, 7]      # source episode numbers this course draws on
    summary: "<one sentence on what this course teaches>"
```

## Constraints

- Derive **course COUNT from the corpus** (one course per taxonomy slot). Cap at
  **{{MAX_COURSES}}** courses. Saint School produced 49–55; a smaller podcast may
  warrant fewer — let the content decide, do not pad.
- Every `taxonomy[*].paradigm` value MUST appear in `allowed_paradigm_elements`;
  every `tier` in `allowed_tiers`; every tag as `namespace:slug` with `namespace`
  in `allowed_tag_namespaces`; every pathway in `allowed_pathways`.
- Course codes: category letter (A, B, C, …) groups a paradigm/theme; number is
  the course within it. Keep codes unique.
- `sessions`: 4–6 (each ≈15 min).

## Episode summaries

{{EPISODE_SUMMARIES}}

## Output

Emit **only** the YAML document — no prose, no code fences.
