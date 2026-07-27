# Stage Help — the in-app Help section: wiring contract for the integrator

**Branch:** `console/stage-help` · **Status:** ready to wire · **Owner:** help-stage agent

I own `scripts/console/app/help.py`, `scripts/console/templates/help.html`,
`scripts/console/templates/_help_section.html`,
`scripts/console/tests/test_help.py` and this file. I have **not** touched
`app/main.py`, `templates/base.html`, `app/config.py` or the nav. Everything
below is what you need to add. Follow it literally; where a choice is
load-bearing I say why, so you can tell a typo from a decision.

---

## 1. Routes to register

Two routes, both `GET`, both HTML, both behind `scoped("viewer")`. No POSTs.

| # | Path | Handler | Auth dependency | Returns |
|---|------|---------|-----------------|---------|
| R1 | `GET /help` | `help_page` | `sc: Scope = Depends(scoped("viewer"))` | full page, every topic |
| R2 | `GET /help/{section_id}` | `help_section` | `sc: Scope = Depends(scoped("viewer"))` | one topic, or 404 |

Add `help` to main.py's existing `from . import (...)` block.

```python
@app.get("/help", response_class=HTMLResponse)
def help_page(request: Request, sc: Scope = Depends(scoped("viewer"))):
    return _pane(request, "help.html", help.page_context(), sc)


@app.get("/help/{section_id}", response_class=HTMLResponse)
def help_section(request: Request, section_id: str, sc: Scope = Depends(scoped("viewer"))):
    ctx = help.page_context(section_id)
    if ctx is None:
        raise HTTPException(status_code=404)
    return _pane(request, "help.html", ctx, sc)
```

That snippet is not prose: `tests/test_help.py::wired` **executes exactly these
two handler bodies** against the real `scoped("viewer")` and the real `_pane()`.
If the fixture and this section ever disagree, one of them is wrong.

### Notes that are not style preferences

- **`_pane()`, not `templates.TemplateResponse`.** `page_context()` returns
  precisely the ctx `_pane()` expects, and `_pane()` is where scrub + redact
  live. Note the trap: the AST test's
  `test_every_pane_route_renders_through_pane` only inspects routes **named
  `pane_*`**, so these two handlers are *not* covered by it — a
  `TemplateResponse` here would merge green. That is exactly why it is written
  down instead of assumed. Do **not** rename them to `pane_help`: they are not
  tab panes and putting them in that namespace would imply a tab that does not
  exist.
- **Leave `redactable` at its default (`True`).** This is a read surface. The
  exemption exists for action results whose argv was already scope-validated;
  nothing here shells out, and `help.py` imports neither `runner` nor
  `subprocess` nor `actions`.
- **`scrub()` is a no-op here and must stay one — but not for the reason you
  would guess.** `scope.scrub()` recurses into dicts and lists and **stops at a
  tuple**: a tuple is returned untouched, its contents never examined. The help
  content is authored as tuples (they are constants), so a context handed over
  verbatim would score *zero dropped rows because nothing was looked at*.
  `page_context()` therefore hands over **lists** (`help._walkable()`), and
  `test_the_scrubber_can_actually_see_into_the_help_context` plants a foreign
  `site` key to prove the zero is a measurement and not blindness. Do not
  "simplify" `_walkable()` away. Under `SCOPE_STRICT` (CI) a single dropped row
  *raises*, so if a future help row grows a `site` key the page 500s in CI —
  which is the intended alarm, and mutation **M4** below demonstrates it firing.
- **There is no `prov` key, deliberately.** Help is static: nothing is gathered,
  so there is no publisher, no age and nothing that can be stale. Do not wire
  `_provenance.html` into `help.html` to be consistent with the other panes —
  a provenance line that always says "just now, from here" trains readers to
  ignore the one on the Fleet pane that matters.
- **`section_id` needs no sanitising in the route.** `help.get_section()`
  validates it against `SECTION_ID_RE` and looks it up in a dict; it is never
  turned into a filesystem path or a template name. Do not add a second check
  that could disagree with the first.
- **404 must not become an empty 200.** `page_context()` returns `None` for
  anything that is not a section, and the route raises 404. A help page that
  rendered an unknown topic as an empty body is indistinguishable from a topic
  someone forgot to write. `test_an_unknown_section_404s_rather_than_rendering_an_empty_page`
  pins it; mutation **M1** is that exact regression.
- **Do not add `help_page` to `UNSCOPED_ALLOWLIST`.** It is authenticated,
  viewer+, like every other read.
- **No POST routes, no actions, no new argv.** The action allowlist and the
  Quokka AST test are untouched by this stage.

### One decision I could not make for you

`scoped("viewer")` 403s a user with **no project membership**, which the 403
handler turns into a redirect to `/no-project`. Consequence: a brand-new user
who has not been assigned to a project yet **cannot read the help that explains
why they are seeing that page.**

I have implemented the brief as written (`scoped("viewer")`) and am flagging it
rather than quietly widening a boundary. If you want help reachable there, the
minimal honest change is yours to make in your files, and it is a reviewable
one: `help_page` on `Depends(current_user)` with its name added to
`UNSCOPED_ALLOWLIST`. Note `require("viewer")` is **not** an option — the AST
test asserts `require()` is only ever called with `"owner"`. Help content is
static and site-agnostic, so nothing leaks either way; it is purely a question
of whether the allowlist grows an entry.

---

## 2. Header entry (NOT a nav tab)

The bottom tab bar is full (7 panes) and Help is not a pane. It goes in the
**header** in `base.html`, inside the `{% if user %}` block, next to where the
Library link goes:

```html
<a href="/help" title="Help" aria-label="Help">?</a>
```

Visible to **every authenticated user** — no role condition. Every topic on the
page describes something a viewer can see or a limit that applies to them.

Stage 4's contract already refers to "the Help `?` button" as the anchor its
Library link sits beside; this is that button. Whichever of us lands second,
the two are adjacent and neither needs the other to exist.

---

## 3. Config keys

**None.** No new environment variable, no new default, nothing to add to
`config.py` or to the `settings.console` block. `help.py` is stdlib-only
(`re` and nothing else), adds no dependency, reads no file at runtime, spawns
nothing, and imports nothing from `main`/`actions`/`runner`/`subprocess`.

There is no max-age knob because there is nothing to be stale.

### CI baseline

`scripts/ci/.console-collect-baseline` is checked in both directions
(`collection_errors=0`, `skipped=1`). This stage adds **46 tests, 0 collection
errors and 0 skips** when the declared requirements are installed — the
`importorskip` calls in `test_help.py` are for `jinja2`, `fastapi` and `httpx`,
all of which are in `requirements.txt` / `requirements-dev.txt`. Measured
locally: **533 passed, 1 skipped** (the pre-existing optional-STT skip). The
baseline file needs **no edit**.

---

## 4. Templates

| File | Role |
|------|------|
| `help.html` | The whole of `/help` and `/help/<id>`. Extends `base.html`. Renders the topic index, then each section. |
| `_help_section.html` | One section: heading, summary, and its blocks. Included in a loop by `help.html`; expects the loop variable `s`. |

`help.html` carries its own `<style>` block rather than adding to
`static/style.css`, because several workstreams are editing that file at once
and this avoids a conflict for you. It is self-contained and every selector is
`.help*`-prefixed, so folding it in later is a copy-paste.

**Neither template uses `|safe`, anywhere, and a test enforces that** (with
Jinja comments stripped first, so the comment explaining the rule does not trip
it). All content is escaped by the normal autoescape path, which is what makes
"content is just strings in a Python file" safe to edit casually.

---

## 5. How to maintain the content

Everything a reader sees lives in `SECTIONS` in `app/help.py`: a tuple of
`{"id", "title", "summary", "blocks"}`. A block is one of four kinds, each with
a one-letter constructor:

| Kind | Constructor | Renders as |
|------|-------------|-----------|
| `text` | `_t("…")` | a paragraph |
| `list` | `_l("…", "…")` | a bulleted list |
| `defs` | `_d(("term", "meaning"), …)` | a two-column table |
| `note` | `_n("…")` | a highlighted callout |

Rules the tests enforce, so you find out at CI time rather than in production:

- **No `<` or `>` in any content string.** Not a markup filter — a *style* rule
  that keeps the "content is text, never markup" claim true by inspection. Write
  `“?tab=” plus a pane name`, not `?tab=<pane>`. (`test_help_content_carries_no_markup`.)
- **Section ids are URL-safe and unique** (`SECTION_ID_RE`), because each is a
  real URL and a duplicate would silently shadow its twin.
- **An unknown block kind renders a visible error, not silence** — a block
  nobody renders is a paragraph of help that quietly stopped existing
  (mutation M5).
- Every section needs a non-empty title, summary and at least one block.

### Where the content came from, and what will make it wrong

Every claim was read off the code, not off the README's aspirations. If you
change any of these, the corresponding section needs a line changed:

| Section | Derived from | Goes stale if you change… |
|---------|--------------|---------------------------|
| `start` | `main.py` docstring, `README.md`, `index.html` footnote | the tier story (reads here, live/prod elsewhere) |
| `panes` | `PANES`, every `pane_*` route + template, `tab_counts` | adding/removing/reordering a pane, the 90 s count refresh, the 60-row todo cap |
| `rag` | `scripts/commands/rag.sh` help text, `parsers.parse_rag` | the RED/AMBER/GREEN rule, or the unscanned-is-never-green property |
| `roles` | `authz.py` (`ROLES`, `PROJECT_ROLES`, `CAP`, `effective_project_role`) | any role name, or the global-role ceiling |
| `projects` | `scope.py`, `_scopebar.html`, `no_project.html` | what a project narrows (sites/issues/CI/demo/audit), legacy mode |
| `freshness` | `fleet_state.py`, `_provenance.html` | the three provenance shapes or the stale banner |
| `actions` | `actions.py` (`ACTIONS`, `FORBIDDEN_VERBS`), `_action_gate` | adding, removing or renaming an action; the global-action refusal |
| `audit` | `/audit` route, `store.AuditLog`, `Scope.audit_allowed` | who sees which entries |
| `notifications` | `_notify_view` rows, `config.NOTIFY_EVENTS` | the event list |
| `quokka` | `quokka.py`, `voice.py`, the chat/brief/stt/tts routes | the no-cloud-speech property, the mic gating |
| `pwa` | `static/sw.js`, `manifest`, session cookie settings | adding offline caching, or adding keyboard shortcuts (there are none today, and the help says so) |
| `library` | Stage 4's `stage4-wiring.md` | wiring `/library` — the section says "not wired here yet" and should then say where it is |
| `trouble` | the degraded paths in every pane | any new "this looks broken but isn't" shape |

The `library` section deliberately describes `/library` as forthcoming-if-absent
rather than asserting it exists, since the two stages land independently.

---

## 6. Evidence

- **46 test cases** in `tests/test_help.py`; **533 console tests green,
  1 skipped** (`python3 -m pytest scripts/console/tests/`), unchanged skip count.
- The suite is in three layers, because each can be wrong alone: the content
  *shape*, the *render* through a real Jinja environment, and the *routes*
  through a real `TestClient` using the real `scoped()` + `_pane()`.
- **5 mutations, each proven to turn specific tests RED** — harness output:

```
=== M1: unknown topic renders as an empty section instead of 404 ===
    RED: test_anything_that_is_not_a_section_is_none[nope]
    RED: test_page_context_is_none_for_an_unknown_section
    RED: test_an_unknown_section_404s_rather_than_rendering_an_empty_page
=== M2: the whole-page context serves only the first section ===
    RED: test_page_context_without_an_id_carries_every_section
    RED: test_the_full_page_renders_every_declared_section
    RED: test_the_help_page_serves_every_declared_section_over_http
=== M3: the section template renders help text with |safe ===
    RED: test_help_text_is_escaped_not_interpreted
    RED: test_no_template_in_this_stage_uses_safe
=== M4: a help row grows a `site` key (the shape scrub() drops) ===
    RED: test_the_scrubber_has_nothing_to_drop_in_the_help_context
    RED: test_the_scrubber_can_actually_see_into_the_help_context
    RED: test_a_viewer_can_load_the_help_page
    RED: test_the_help_page_serves_every_declared_section_over_http
    RED: test_each_section_is_reachable_on_its_own_url
    RED: test_a_scoped_member_gets_help_with_strict_scoping_on
=== M5: an unknown block kind renders as silence ===
    RED: test_an_unknown_block_kind_is_loud_rather_than_silent
```

**One defect was found this way rather than assumed away.** M4 originally
stayed **green**: planting a foreign `site` key on every help row changed
nothing, because `scope.scrub()` does not traverse tuples and the content is
authored as tuples. The "scrub has nothing to drop" test was passing without
looking at anything. Fixed by `_walkable()` (hand the context over as lists),
pinned by a positive control, and M4 now goes red six ways — including the
three route tests, which is `SCOPE_STRICT` doing its job.

That tuple blind spot is a property of `scope.scrub()` itself, not of this
stage. **Any other stage whose context nests rows inside a tuple is being
scrubbed only in appearance.** Worth a look during integration; I have not
touched `scope.py` because it is not mine.

### Known gap — please close it when you wire

The route tests build their own `FastAPI()` and register the two handlers
above; they cannot prove *your* `main.py` did. After wiring, add `/help` and
`/help/{id}` to `test_tenant_isolation.py` so this surface is covered by the
same must-go-red property as every other route. The assertion worth having is
not a leakage one (help names no site, by construction and by the no-markup
content rule) but a **reachability** one: `dana` gets 200 on `/help` and on
every `/help/<id>`, and 404 — never 200 — on an id that does not exist, with
`NWP_CONSOLE_SCOPE_STRICT=1` set as that suite already does.
