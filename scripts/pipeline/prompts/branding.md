# Stage 4 — Branding config (for apply_branding.php)

Produce a **branding JSON** for the **{{SET_TITLE}}** Moodle course site (set slug
`{{SET_SLUG}}`). The generic `apply_branding.php --config branding.json` consumes
this to brand the site (colours, top bar, hero, category names, footer). Category
and course references are by NAME/shortname and resolved at runtime.

## Hard rule — brand THIS set, do not reuse Saint School

Colours, category names, hero copy, and pathway tiles MUST reflect
**{{SET_TITLE}}** and its own controlled vocabulary (below). **NEVER reuse Saint
School's green/brown palette, its "rail" category names, or its Catholic-theology
copy.** The `categories` keys are this set's paradigm-rail slugs, mapped to a
human category name in the domain's own language.

## This set's vocabulary + taxonomy

```
{{VOCAB}}
```

## Required JSON shape

Mirror the keys the engine's branding config carries (a subset is fine for a
first pass; `site`, `categories`, `colors`, `topbar`, `hero`, `footer` are the
load-bearing ones):

```json
{
  "site": {
    "fullname": "{{SET_TITLE}}",
    "shortname": "{{SET_TITLE}}",
    "summary_html": "<p><strong>N self-contained 15-minute courses.</strong> ~15 minutes/day.</p>"
  },
  "categories": {
    "<rail-slug>": "<Human Category Name>"
  },
  "default_category": "<rail-slug>",
  "colors": {
    "brand": "#RRGGBB",
    "brand_dark": "#RRGGBB",
    "accent": "#RRGGBB",
    "bg": "#fafafa",
    "text": "#222",
    "muted": "#666"
  },
  "badge_text": "NEW",
  "topbar": {
    "brand": "{{SET_TITLE}}",
    "brand_sub": "<short tagline>",
    "nav": [
      {"label": "Home", "url": "/"},
      {"label": "All courses", "url": "/course/index.php"},
      {"label": "<Rail>", "category": "<Human Category Name>"},
      {"label": "Log in", "url": "/login/index.php", "cta": true}
    ]
  },
  "hero": {
    "title": "{{SET_TITLE}}: Courses",
    "lines_html": [
      "<strong>N self-contained 15-minute courses.</strong>",
      "Each takes ~15 minutes/day, completable in one week.",
      "<strong>Where would you like to begin?</strong>"
    ]
  },
  "tiles": [
    {
      "quote": "I want to ...",
      "body": "One or two sentences describing the pathway.",
      "code_line": "Pathway — A1 → A2 → ...",
      "button": "Start here",
      "course": "A1",
      "color": "#RRGGBB"
    }
  ],
  "footer": {
    "brand": "{{SET_TITLE}}",
    "tagline_html": "One-line formation tagline for this set.",
    "bottom_html": "© 2026 {{SET_TITLE}} · Built on <a href=\"https://moodle.com\">Moodle</a>"
  }
}
```

## Constraints

- Every `categories` key MUST be a `paradigm` rail slug from
  `allowed_paradigm_elements`.
- `tiles[*].course` and any `nav[*].course` MUST reference course codes that
  exist in the taxonomy.
- Colours must be a coherent palette that fits **{{SET_TITLE}}** — not Saint
  School's greens.

## Set context

- title: {{SET_TITLE}}
- description: {{SET_DESCRIPTION}}

## Output

Emit **only** the JSON object — no prose, no code fences.
