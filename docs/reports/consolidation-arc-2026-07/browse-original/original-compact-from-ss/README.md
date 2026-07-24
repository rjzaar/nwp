# local_browse — Saint School all-courses browse page

A Moodle local plugin that adds `/local/browse/` — a single page listing
**every visible course grouped by Paradigm-rail category**, with a card
per course (title, summary, code badge, category-colour left border).

## Why it exists

Moodle's default `/course/index.php` only shows category names; to see
courses inside a rail, a user has to click into it. The Saint School v3
UX wants one page that shows the entire catalog at once with summaries —
similar to the v1 SS landing page's "Browse All 49 Courses" approach.

## Files

```
local/browse/
├── version.php
├── index.php               The all-courses page
├── README.md
└── lang/en/local_browse.php
```

No DB schema, no capabilities (uses the same guest-view permissions as
Moodle's standard course browsing). Pure read-only render.

## URL

`/local/browse/` (auto-resolved by Moodle to `/local/browse/index.php`).
The Saint School topbar's **"All courses"** link points here. The dark
footer's **"All courses"** link also points here.

## Visual language

Each Paradigm rail is colour-coded to match the home-page tiles:

| Rail | Hex |
|------|-----|
| Sacraments | `#5D4037` (dark brown) |
| Prayer & Recollection | `#1565C0` (blue) |
| Ascesis | `#7B1FA2` (purple) |
| "Your Yes" | `#2E7D32` (green, the brand colour) |

Each course card has:
- A coloured left border in the rail colour
- The course code in monospace (e.g. `A1`, `B6`) in the rail colour
- The course full title
- The course summary (truncated to 140 characters)
- Hover: 2px slide-right + deeper shadow

## Preservation

Lives in the manifest at `~/dir/courses_v3/plugins/manifest.yaml` as
`local_browse`. Installed by `install_plugins.sh` like every other plugin.

## Future improvements

- Add per-tier badges (Tier 0, Tier 1, etc.) drawn from course tags
- Optional filter pills (by saint, by season, by risk)
- Optional "completed" state per course for logged-in users
- Optional search box that filters within the page (vs Moodle's full
  course-search at `/course/search.php`)
