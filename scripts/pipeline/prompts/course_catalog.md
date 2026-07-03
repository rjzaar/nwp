# Stage 4 — Course catalog YAML (v3 schema)

You are authoring **one course** for the **{{SET_TITLE}}** set (slug `{{SET_SLUG}}`).
Emit a single v3-schema catalog YAML file that the generic `validate_catalog.py`
and `build_json.py` accept **unchanged**. The output is written to
`catalog/{{COURSE_CODE}}.yaml`.

## The course to build (from the taxonomy)

```
{{COURSE_SLOT}}
```

## This set's controlled vocabulary (generated per set — DO NOT substitute Saint School's)

The `paradigm.primary`, `tier`, tag namespaces and pathways you use MUST come
from **this set's** vocabulary below. **NEVER reuse Saint School's
Catholic-theology vocabulary.**

```
{{VOCAB}}
```

## Required output shape (v3 catalog — this is the engine's grammar)

Top-level `course:` mapping. `validate_catalog.py` enforces:

- `course.code` MUST equal the filename stem (`{{COURSE_CODE}}`).
- `course.schema_version` MUST equal `3`.
- `course.title` present.
- `course.paradigm.primary` MUST be in `allowed_paradigm_elements`;
  every `paradigm.supporting` too.
- `course.tier.min` <= `course.tier.max`; both in `allowed_tiers`.
- every `course.tags[*]` in `namespace:slug` form, namespace in
  `allowed_tag_namespaces`.
- every `course.pathways[*]` in `allowed_pathways`.
- each `learning_points[*].id` matches `^{{COURSE_CODE}}\.\d+$` (e.g.
  `{{COURSE_CODE}}.01`), unique within the course.
- each learning point has a non-empty `depths` mapping. Depth keys are drawn
  from: `short`, `standard`, `longer`, `detailed`, `advanced`, `scholar`.

```
course:
  code: "{{COURSE_CODE}}"
  title: "..."
  schema_version: 3
  category: "{{COURSE_CODE_LETTER}}"
  category_name: "..."
  sessions: {{SESSIONS}}          # 4–6, one learning point per session
  prerequisites: []
  paradigm:
    primary: "<rail-slug from allowed_paradigm_elements>"
    supporting: []
  tier:
    min: 0                        # in allowed_tiers
    max: 0
  tags:
    - "<namespace>:<slug>"        # namespace in allowed_tag_namespaces
  pathways:
    - "<pathway-slug>"            # in allowed_pathways
  learning_points:
    - id: "{{COURSE_CODE}}.01"
      title: "..."
      session: 1
      depths:
        short:
          summary: "35–60 word quick review."
        standard:
          text: "300–500 words for the default learner."
          key_quotes:
            - text: "verbatim quote from the transcript"
              source: "ep NNNN"
          video:
            episode: 1            # a source episode number for this set
            start: "MM:SS"
            end: "MM:SS"
```

## Clip selection — CRITERIA rubric (v2 composite; apply when choosing the `video` clip)

Choose the clip per learning point the way the corpus rubric would rank it —
prefer clips that are (weights are directly comparable, inputs normalised to
[0,1]):

- **Dense on-topic** (`+3.0 density`) and **broad** (`+2.0` distinct terms hit)
  rather than one word repeated.
- **Clean edges** — opens on a capital after a full stop (`+1.0`), ends on
  `. ? !` (`+1.0`); avoid mid-sentence starts.
- **Standalone** — has a definition (`+2.0`), cites a specific authority/work
  (`+1.5`), or gives a concrete example (`+1.0`).
- Penalise ad reads (`-2.0`), show intros in the first 45s (`-1.5`), serial
  markers like "part two"/"next week" (`-2.0`), dangling openers
  ("It"/"That"/"And" with no antecedent, `-1.5`), and off-topic tails (`-1.0`).
- Prefer the **middle of a duration bucket** over the edges.

## Depth guidance (v3 six-depth ladder)

short 35–60w · standard 300–500w · longer ~1–1.5kw · detailed ~2–3kw ·
advanced 3–5kw · scholar 5kw+. For a first pass, `short` + `standard` (with a
`video` clip) per learning point is sufficient and validates; add deeper levels
where the transcript supports them.

## Source transcript context

Draw titles, quotes, learning points and clip timestamps from this set's own
transcripts — do not invent facts not present here:

{{TRANSCRIPT_CONTEXT}}

## Output

Emit **only** the YAML document (top-level `course:` mapping) — no prose, no
code fences.
