# local_browse — Saint School tabbed course front-door

A Moodle local plugin that adds `/local/browse/` — a **guest-viewable, tabbed
multi-front over the single Saint-School course catalog**. One catalog, several
doors; the entry point is navigation, not content.

## Tabs (locked order)

`?view=` selects the tab. The default is set by `local_browse | default_view`
(shipped default: `curated`).

| `view=` | Tab label | What it renders |
|---------|-----------|-----------------|
| `curated` *(default)* | **Where to begin** | "Where would you like to begin?" — **intent tiles** from the data contract (below). Each tile = heading + blurb + ordered course cards. |
| `ascent` | **The journey** | Courses grouped by Paradigm rail. Rail colour/label keyed off a **stable category `idnumber`** (not the display name). |
| `browse` | **Browse everything** | Flat, in-page-filterable list + the **N8 toggles**. |
| *(future)* `forme` | **For me now** | Deterministic personalization — reserved slot, built after formation lands. |

Everything is **guest-safe**: no capability checks, and the Browse toggles work
for anonymous visitors (they degrade to GET-params; logged-in users get them
persisted as user preferences).

## Intent-tile data contract (version 1)

The Curated tab renders from this structure. It is what the nwc **Theology-Editor**
authoring / def-sync path produces; engineering owns only the mechanism.

```
intent_tiles (version:1):
  { "version": 1,
    "tiles": [
      { "id":           slug,          # stable, unique
        "heading":      string,        # short intent phrase
        "blurb":        string,        # who this is for (1–2 sentences)
        "action_label": string,        # call-to-action label
        "order":        int,           # ascending render order
        "courses":      [shortcode,…]  # ordered course codes, e.g. "A1","B4"
      }, … ] }
```

- A course shortcode that does **not** resolve to a visible course in this Moodle
  is skipped at render time — tiles may safely list not-yet-built codes.
- **Source of truth at runtime:** the `local_browse | intent_tiles_json` admin
  setting. If it is empty or invalid JSON, the plugin falls back to the **shipped
  seed** in [`db/intent_tiles.php`](db/intent_tiles.php). This lets def-sync
  overwrite the tiles **without a code change**.
- The shipped seed ports **ss2's 10 intent tiles** (the 11 authored pathway YAMLs
  are the backbone) onto ssc's v3 courses, and deliberately places the 6 v3-new
  courses (A6, A7, A8, B7, D7, D8) so the curated map covers the whole catalog.

## Rail colour — keyed off `idnumber`, not the name

The old fragility was colour-by-exact-category-**name**. `local_browse_rail_style()`
now resolves colour + label by a stable **idnumber** first, then falls back to the
legacy name map, then to a neutral default:

| idnumber | Colour | Label |
|----------|--------|-------|
| `rail_sacraments` | `#5D4037` | Sacraments |
| `rail_prayer` | `#1565C0` | Prayer & Recollection |
| `rail_ascesis` | `#7B1FA2` | Ascesis |
| `rail_your_yes` | `#2E7D32` | "Your Yes" |

**Operator action (not done here):** stamp these idnumbers on the four live rail
categories so the Ascent tab stops depending on the display name. Until then the
name fallback keeps it working. (The catalog build script `create_v3_courses.php`
creates the categories by name only — outside this plugin's scope to change.)

## N8 toggles (Browse tab)

Two ratified toggles, persisted as user preferences for logged-in users and as
GET-params for everyone (guest-safe):

- **Catalog version** — `cat=v3` (live catalog, default) | `cat=v1` (the frozen
  ss2 archive). `v1` renders **read-only deep-links** to the archive from the seed
  manifest in [`db/v1manifest.php`](db/v1manifest.php) (49 courses). Links are
  built as `{v1_base_url}/course/view.php?name=<shortcode>`; set the base URL in
  `local_browse | v1_base_url`. If it is unset, titles show with a notice and no
  broken links.
- **Show** — `content=courses` (default) | `content=books` (courses + book
  studies). Book studies are **copyright-gated** (N8 §C.2): a book study renders
  only once its work is `status: cleared`. None are cleared in the shipped stub,
  so the toggle currently shows an explicit "nothing cleared yet" notice.

## Files

```
local/browse/
├── version.php
├── index.php                 Tab shell + view=selector + the three renderers
├── settings.php              Admin settings (default_view, intent_tiles_json, v1_base_url)
├── locallib.php              Helpers: tile loading, rail-style, toggle/pref resolution
├── db/
│   ├── intent_tiles.php      Shipped seed for the Curated tab (data-contract v1)
│   └── v1manifest.php        Shipped seed for the Browse v1-archive toggle
├── lang/en/local_browse.php
├── tests/behat/browse_page.feature
└── README.md
```

No DB schema, no capabilities — pure read-only render.

## Making it the site home

To make this the guest-viewable site home on ssc (retiring the flat
`frontpage=6` FRONTPAGEALLCOURSELIST): point the front page at `/local/browse/`
(an admin front-page redirect, or a small site-home wrapper) and ensure guest
access is enabled. **Do not change live config from the plugin** — this is an
operator step; see `local_browse | homenote` in the plugin settings.

## Preservation

Lives in the manifest at `~/dir/courses_v3/plugins/manifest.yaml` as
`local_browse`. Installed by `install_plugins.sh` like every other plugin.

## Future improvements

- Tab 4 **"For me now"** (deterministic personalization: current-course pointer,
  suggested-next ≤3, pathway position, tier-gated visibility).
- Per-tier badges, filter pills (by saint / season / risk).
- Book-studies as alternates *inside* rail sections once works are cleared.
