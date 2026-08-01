# Stage Visuals — wiring contract for the integrator

**Branch:** `console/stage-visuals` · **Status:** ready to wire · **Owner:** stage-visuals agent

I own `scripts/console/app/visuals.py`, `scripts/console/templates/pane_visuals.html`,
`scripts/console/templates/_visual_fleet.html`, `_visual_severity.html`,
`_visual_todo.html`, `_visual_ci.html`, `_visual_nodata.html`,
`scripts/console/tests/test_visuals.py` and this document. I have **not** touched
`app/main.py`, `templates/base.html`, `templates/index.html`, `app/config.py`,
`static/style.css` or the nav. Everything below is what you need to add. Follow it
literally; where a choice is load-bearing I say why, so you can tell a typo from a
decision.

---

## 1. Route to register

One route. `GET`, HTML, behind `scoped("viewer")`. There is no second route and
no `POST` — see §6.

| # | Path | Handler | Auth dependency | Returns |
|---|------|---------|-----------------|---------|
| R1 | `GET /panes/visuals` | `pane_visuals` | `sc: Scope = Depends(scoped("viewer"))` | pane fragment |

Add `visuals` to main.py's existing package import:

```python
from . import (advisories, config, fleet_state, notify, parsers, quokka,
               scope as scope_mod, visuals, voice, webauthn_flow)
```

```python
@app.get("/panes/visuals", response_class=HTMLResponse)
def pane_visuals(request: Request, force: int = 0, sc: Scope = Depends(scoped("viewer"))):
    rag, _res, prov = _gather_rag(sc, force=bool(force))
    todo = _gather_todo(sc, force=bool(force))[0]
    # Both of these are best-effort for the same reason pane_fleet treats the
    # security feed that way: this pane's job is the at-a-glance read, and one
    # unavailable feed must degrade to one honest "no data" card rather than
    # taking the whole tab down.
    sec = {"ok": False, "error": "security data unavailable on this host"}
    try:
        sec = _gather_security(sc, force=bool(force))[0]
    except Exception:  # noqa: BLE001
        pass
    try:
        blocks, api_ok = _gather_ci(sc)
    except Exception:  # noqa: BLE001
        blocks, api_ok = [], False
    ctx = visuals.page_context(rag, todo, sec, blocks, api_ok, prov)
    return _pane(request, "pane_visuals.html", ctx, sc,
                 tab="visuals", tab_count="", tab_alert=bool(prov.get("stale")))
```

### Notes that are not style preferences

- **The handler MUST be named `pane_visuals`.** `tests/test_route_scoping.py`
  builds `PANE_ROUTES` from every route whose function name starts with
  `pane_`, and only those routes are required to render through `_pane()`.
  Name it `visuals_page` and it silently drops out of that check — the pane
  keeps working and stops being covered, which is the worst of the two.
- **`_pane()`, not `templates.TemplateResponse`.** `_pane()` is where scrub +
  redact live. `test_every_pane_route_renders_through_pane` fails on a bare
  `TemplateResponse`, and it is right to.
- **Leave `redactable` at its default (`True`).** This is a read pane. The
  exemption exists for action results whose argv was already scope-validated;
  nothing here shells out or takes a parameter.
- **`prov` goes at the TOP LEVEL of the context, and `page_context` already
  puts it there.** `scope.redact()` strips `ctx["prov"]["host"]` and
  `["note"]` by **exact path**, so nesting it under `vz` would silently exempt
  the Visuals tab from a redaction every other read pane obeys — the
  publisher's hostname is infrastructure a tenant need not learn.
  `test_the_shared_redactor_reaches_the_visuals_publisher_host` fails if you
  move it.
- **`scrub()` must stay a no-op here, and there is a test pinning it.** The
  per-site rows this pane emits (fleet tiles, todo rows) deliberately carry the
  `site` key so `scrub()` *can* filter them — but the gatherers already
  narrowed them, so nothing should ever be dropped. Under `SCOPE_STRICT` (CI) a
  single dropped row **raises**, so a future regression 500s the pane in CI
  instead of quietly rendering 11/12ths of the truth.
  `test_the_context_carries_no_row_the_scrubber_would_have_to_drop` is the pin.
- **CI rows key on `project`, NOT `site`, and must stay that way.** A CI project
  is not a site. Giving those rows a `site` key would make `scrub()` drop every
  one of them for a scoped reader (and raise under `SCOPE_STRICT`). Their
  narrowing happens upstream in `Scope.ci_projects`, which is why
  `_gather_ci(sc)` is the only correct source. `test_ci_rows_do_not_invent_a_site_key`
  and `test_ci_charts_only_cover_the_projects_in_scope` cover both halves.
- **Use `_gather_rag/_gather_todo/_gather_security/_gather_ci` — never the
  `_raw` twins.** `test_no_route_calls_a_raw_gatherer` enforces it. The raw
  gatherers are the owner-only background paths.
- **Do not read `config.CI_PROJECTS` or `config.DEMO_SITES` in the handler.**
  `test_no_route_reads_demo_or_ci_config_directly` enforces it; the Scope
  narrows both.
- **`tab_count=""` is deliberate, and `tab_alert` is not.** A count here would
  duplicate the Fleet tab's RAG badge on the tab bar right next to it. What is
  *worth* surfacing from the tab bar is that the numbers are no longer current
  — hence the alert dot on `prov.stale`, matching how the Fleet tab already
  flags itself.
- **`prov` comes from the RAG gather, not from any of the other three.** All
  three snapshot feeds come from the same `pl fleet publish` file, so their
  provenance is identical in practice; taking RAG's keeps the pane's headline
  provenance the same object the Fleet tab shows. (CI is not snapshot-fed at
  all — see §5.)

---

## 2. Nav tab (the 8th, and the last)

Per the stage-4 contract: *"The bottom nav is full: 7 panes + Visuals = 8 is the
phone ceiling."* This is that 8th entry. In `main.py`:

```python
PANES = [
    ("fleet", "Fleet"), ("issues", "Issues"), ("todo", "Todo"), ("demo", "Demo"),
    ("backups", "Backups"), ("ci", "CI"), ("quokka", "Quokka"), ("visuals", "Visuals"),
]
```

**Append it; do not insert it.** `index.html` uses `PANES[0]` as the pane a
device opens on when it has no remembered tab, so moving Visuals to the front
would change the landing pane for every new device and every private-window
session. If you later decide Visuals *should* be the landing tab, that is a
deliberate product change and deserves its own commit message, not a side
effect of adding a tab.

Nothing else in `index.html` needs editing — the tab bar, the `?tab=` deep-link
handling and the `localStorage` memory all iterate `PANES`.

**This tab is now the ceiling.** A ninth pane does not fit on a phone; the next
feature goes in the header (as the Library did) or inside an existing pane.

---

## 3. Config keys

**None.** There is nothing to add to `config.py`.

`app/visuals.py` imports nothing from `config`, `main`, `runner`, `actions` or
`subprocess` — it is arithmetic over dicts it is handed. The two size caps
(`MAX_TILES = 24`, `MAX_TODO_ROWS = 12`) are module constants with keyword
overrides; both are about what fits on a phone, not about a deployment, so
promoting them to environment variables would add a knob nobody will ever turn.
When a cap bites, the pane says so in words (*"+N more site(s) — all N are in
the table below"*) rather than silently truncating.

**No new dependencies.** No chart library, no CDN, no `requirements.txt`
change. Every chart is SVG emitted by Jinja from geometry computed in stdlib
Python. The only client-side JavaScript involved is the htmx already vendored
in `static/`.

---

## 4. Templates

| File | Role |
|---|---|
| `pane_visuals.html` | the pane: `<style>` block, the stale banner, four includes |
| `_visual_fleet.html` | V1 — RAG part-to-whole bar + per-site tile grid |
| `_visual_severity.html` | V2 — open advisories by severity |
| `_visual_todo.html` | V3 — todo load per site, stacked by priority |
| `_visual_ci.html` | V4 — head-pipeline state per CI project |
| `_visual_nodata.html` | the shared explicit empty state (see §7) |

All five partials read `vz.*` off the context and are included by
`pane_visuals.html`, which pulls in `_tabcount.html` and `_provenance.html`
itself. They are **not** htmx swap targets — there is one swap target on this
pane and it is `#pane-body`, exactly as for every other pane.

**Styles live in a `<style>` block inside `pane_visuals.html`, not in
`static/style.css`,** because several workstreams are editing that file and
this avoids a conflict for you. Every selector is `.vz*`-prefixed and the block
is self-contained, so consolidating it later is a single move. It defines no
colour of its own: the four role classes resolve to the console's existing
`--err` / `--warn` / `--ok` / `--muted` custom properties, so a retheme happens
once in `style.css` and the charts follow.

---

## 5. What the four visuals are built on (and how that was verified)

Every source below was read in the code before anything was drawn. Nothing here
is inferred from a name.

| # | Visual | Source | Verified in |
|---|---|---|---|
| V1 | Fleet RAG: part-to-whole bar + per-site tiles | `_gather_rag(sc)` → `{sites:[{site,grade,reasons,phase}], counts:{RED,AMBER,GREEN,OTHER}}` | `parsers.parse_rag`, `main._gather_rag` (counts **recomputed** after filtering) |
| V2 | Open advisories by severity | `_gather_security(sc)` → `totals.by_severity` | `advisories.totals()` builds `by_severity` per site block; `main._gather_security` recomputes totals from the filtered blocks |
| V3 | Todo load per site, stacked high/medium/low | `_gather_todo(sc)` → `items[{site,priority,…}]`, aggregated per site here | `parsers.parse_todo`, `main._gather_todo` |
| V4 | CI head-pipeline state per project | `_gather_ci(sc)` → `[{project, mrs:[{mr,pipeline}], url}]` | `main._gather_ci_raw`, `gitlab_api.open_mrs` / `mr_detail` |

**V1–V3 are snapshot-fed; V4 is live.** V1, V2 and V3 all come from the one
`pl fleet publish` file, which is why they share a `prov` and all three carry
the STALE ribbon together. V4 is read from the GitLab API on every request, so
it carries a `live` tag **instead of** a stale ribbon — stamping it with the
snapshot's age would be a lie in the reassuring direction.
`test_staleness_shouts_on_every_snapshot_fed_chart` asserts exactly three
ribbons and none in the CI block.

### There is no time series, and none is invented

I looked for history and there is none to draw. `fleet_state.py` reads **one**
snapshot and overwrites it; `store.py` holds users, projects and `audit.jsonl`.
`audit.jsonl` *is* timestamped history, but it is a log of **console actions**,
not of site health — an "uptime over time" chart built from it would be
measuring how often someone opened a tab. So every visual here is
current-state, honestly labelled as such. If per-site history is wanted later,
the right move is for the publisher to retain N snapshots (or emit a rollup),
not for the console to infer a trend from the one file it has.

---

## 6. Read-only, and why that is structural rather than a promise

No `POST`, no `<form>`, no `<button>`, no action. `app/visuals.py` imports
neither `actions` nor `runner` nor `subprocess`, and the pane's rendered markup
contains no form element at all — `test_the_pane_is_read_only` asserts the
rendered bytes, not the intent. Nothing here goes near the action allowlist, so
the Quokka AST test and `actions.py` are unaffected.

The one piece of client-side behaviour is a self-refresh poller:

```html
<div hx-get="/panes/visuals" hx-target="#pane-body" hx-trigger="every 120s" hx-swap="innerHTML"></div>
```

It lives **inside** the pane, so switching tabs replaces `#pane-body` and the
timer stops by construction — no orphaned poller, and no polling of a pane
nobody is looking at. htmx swaps atomically, so there is no skeleton flash.

---

## 7. The two zeros — the reason this pane needed a design at all

The failure mode a graphical tab invites is an **empty chart that looks
healthy**. Axes, a legend, no marks: at a glance that reads as *"no problems"*,
and it is indistinguishable from *"nobody managed to look"*. That is the same
lie the empty Fleet tab told before publishing existed, except a chart tells it
more convincingly.

So every visual resolves to exactly one of three states, and the two zeros are
rendered differently on purpose:

| state | meaning | rendering |
|---|---|---|
| `ok` | there is data | the chart |
| `clean` | we asked, and the answer really is zero | quiet, bordered, `✓`, and it says who it asked |
| `missing` | we could **not** find out | warned, `⚠ … — no data`, the reason, and the command that fixes it |

Concretely, the case that drove it: `totals.advisories == 0` is good news
**only** when every site was actually audited. With any site in
`stale`/`unreadable`/`missing` state the published feed reports
`totals.sites_unknown`, and drawing zero bars for that fleet would claim "no
advisories" when the truth is "nobody looked".
`test_a_zero_is_only_clean_when_every_site_was_actually_audited` is the test of
this whole pane. Two related cases are handled the same way: a site behind on
**platform** security releases (Moodle) has no advisory list and so cannot
appear as a bar — it gets an explicit warning line instead of vanishing; and an
MR with **no pipeline** is painted `muted`/unknown, never as if it had passed.

**With every feed unreadable the pane renders zero `<svg>` elements.**
`test_a_missing_artifact_renders_no_chart_at_all` is the negative control.

---

## 8. Colour — measured, not chosen

The `dataviz` skill's validator was run against **this app's own chart
surface** (`--card` `#1a212b`, dark mode), not against the skill's default
surface. Results:

```
node validate_palette.js "#e2604f,#e0a93f,#3fb96a,#8b98a9" --mode dark --surface "#1a212b"
  [PASS] Contrast vs surface    all 4 >= 3:1
  [FAIL] CVD separation         worst adjacent #3fb96a<->#e0a93f dE 4.5 (protan)
```

Two decisions follow, and both are load-bearing:

- **No state in this pane is encoded by colour alone.** Green vs amber at
  ΔE 4.5 under protan is below even the 6–8 "legal only with secondary
  encoding" band: for the most common form of colour-blindness the hue carries
  *nothing*. So every tile states its grade word, every severity bar its name,
  every pipeline cell its status, and every multi-series chart ships a legend.
  `test_no_state_is_encoded_by_colour_alone` pins it. This is why the labels
  are not negotiable padding — deleting them deletes the information.
- **A fifth severity colour was rejected on measurement.** `high` wanted its
  own step between critical-red and medium-amber; the obvious candidate
  (`#ec835a`, the skill's status "serious") measures **normal-vision ΔE 7.9**
  against `#e2604f` — below the hard floor of 15, i.e. unreliable even with
  full colour vision. A scale that *looks* five-valued but reads as four is
  worse than an honest four, so `critical` and `high` share the red they
  already wear in `.chip.sev-high` and `.adv.sev-high`, and are told apart by
  their labels.

Everything else follows the console's existing vocabulary rather than inventing
one: `--err`/`--warn`/`--ok`/`--muted`, with `muted` meaning **unknown**, never
"fine". Text always wears text tokens (`--fg`/`--muted`), never a data colour.

Mark specs applied: bars ≤ 24px thick with a 4px rounded data-end and a square
baseline; a 2px surface gap between every stacked segment and every tile;
solid hairline axes, one step off the surface, never dashed; values at the bar
tip rather than inside it (a label is dropped to the legend/table rather than
clipped — `test_a_label_that_does_not_fit_is_dropped_rather_than_clipped`).

**Hover is `<title>` plus a table view, not a tooltip layer.** A crosshair
tooltip needs a charting runtime, and this pane ships no JavaScript. Native SVG
`<title>` gives hover text for free, and **every chart carries a `<details>`
table view with the same numbers** — so no value is reachable only by hovering,
and a screen reader gets the data rather than a picture.
`test_every_chart_offers_a_table_view_twin` asserts all four.

---

## 9. What I did NOT build, and why

**Backup freshness/age bars** were on the candidate list and are not here. The
console's only backup signal is `parsers.todo_backup_items(todo)` — a
substring slice of the todo sweep for items whose text mentions "backup" or
"sweep". Those items carry a `site`, a `priority` and **prose**
(`"backup is 9 days old"`); there is no structured age field anywhere in the
published snapshot. A freshness bar would therefore have to regex an age out of
a human sentence and chart it, which is fabrication wearing a chart's clothes —
and it would be silently wrong the first time the sweep reworded its output.
The count-per-site version that *would* be honest is already what V3 draws,
from the same feed. If backup age is wanted as a chart, the fix belongs in the
publisher: emit a real `age_seconds` in the todo feed, and V3 grows a sibling.

---

## 10. Tests

```
cd scripts/console && python3 -m pytest tests/test_visuals.py -q     # 40 passed
cd scripts/console && python3 -m pytest tests/ -q                    # 527 passed, 1 skipped
PYTEST=…/pytest bash scripts/ci/test-console.sh                      # exit 0
```

`scripts/ci/test-console.sh` passes with `collection_errors=0` and `skipped=1`,
matching `scripts/ci/.console-collect-baseline` — **the baseline file does not
need editing.** `tests/test_visuals.py` imports only stdlib plus
`app.visuals` at module level, so it adds no collection error, and its jinja2 /
fastapi needs go through `pytest.importorskip` inside the tests and fixtures
that use them, so it adds no *skip* either on a machine with the declared
requirements installed. (Both numbers are shrink-only in that script: moving
either in either direction turns the job red.)

### Proving the tests can fail

Same idiom as `test_tenant_isolation.py`. The switch replaces the honest
zero-handling with the naive implementation — every readable feed is a chart,
every zero is good news:

```
NWP_CONSOLE_TEST_NAIVE_VISUALS=1 python3 -m pytest tests/test_visuals.py
# expect 16 failures, including all four named in RED_FIRST
```

It is honoured only by that test module and does not exist in the app.
`test_the_red_first_switch_is_wired` fails if the switch stops biting.

The suite found one real bug during development, fixed in the same branch: a
gatherer handing back a non-dict (a bare string, or `None`) crashed the
no-data path's error extraction — which would have turned a missing *feed*
into a missing *pane*. Hence `visuals._err_of()`.

### Reviewer's shortcut

The three assertions worth reading first, because they are the ones that would
catch a real regression:

- `test_a_zero_is_only_clean_when_every_site_was_actually_audited` — the pane's reason for existing;
- `test_a_missing_artifact_renders_no_chart_at_all` — zero `<svg>` when everything is unreadable;
- `test_a_member_sees_no_foreign_site_in_any_chart` — leakage, asserted against the rendered bytes, through the real Scope and the real fixture snapshot.

---

## 11. CI expectations

`boundary:classify` and `test:verification` were `allow_failure` amber when
this was written; since ops#165 (2026-08-02) both are expected GREEN —
`boundary:classify` classifies for real (yq bootstrapped, honesty check moved
to `pl pair check` where the corpus exists) and `test:verification` measures
the checkout under test. A red on either is now a real finding, not weather.
The `bats` jobs may fail randomly on the mini runner (infrastructure fix in
flight) — note it, do not chase it. The signal that matters for this branch is
`test:console`.
