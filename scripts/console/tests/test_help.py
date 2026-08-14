"""The in-app Help section: content shape, scope-safety, rendering, routes.

Three layers, because each can be wrong on its own:

  1. DATA — app/help.py is content, so the tests are about the *shape* that
     makes it renderable and scrub-safe, and about `get_section()` answering
     None (never a fabricated empty section) for anything that is not one.
  2. RENDER — through a real Jinja environment, because the thing that must
     hold is that every declared section actually reaches the page and that no
     help string can become markup. A hand-rolled stand-in would only prove the
     stand-in works.
  3. ROUTES — a small FastAPI app wired EXACTLY as docs/reports/console-v2/
     help-wiring.md tells the integrator to wire it, using the real
     `scoped("viewer")` and the real `_pane()`. main.py belongs to the
     integrator, so this proves the declared wiring works; it does not prove
     they pasted it. The wiring doc says so too.

The negative control that matters: an unknown section id must 404, not render
an empty page. An empty 200 is indistinguishable from a topic someone forgot
to write, and it is the failure this file exists to make impossible.
"""
import os
import sys
import tempfile
from pathlib import Path

import pytest

CONSOLE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(CONSOLE))

from app import help as help_mod  # noqa: E402  (after the path insert, as every module here does)

TEMPLATES = CONSOLE / "templates"


# ---------------------------------------------------------------------------
# 1. the content itself
# ---------------------------------------------------------------------------
def test_there_is_actually_some_help():
    """Guard against every assertion below passing over an empty tuple — the
    classic way a content test becomes decoration."""
    assert len(help_mod.SECTIONS) >= 10, f"only {len(help_mod.SECTIONS)} sections"
    ids = [s["id"] for s in help_mod.SECTIONS]
    for expected in ("panes", "rag", "roles", "projects", "audit", "library"):
        assert expected in ids, f"no help section covers {expected!r}"


def test_section_ids_are_unique_and_url_safe():
    ids = [s["id"] for s in help_mod.SECTIONS]
    assert len(set(ids)) == len(ids), "duplicate section id — one would shadow the other"
    for sid in ids:
        assert help_mod.SECTION_ID_RE.match(sid), f"{sid!r} is not a URL-safe section id"


@pytest.mark.parametrize("s", help_mod.SECTIONS, ids=[s["id"] for s in help_mod.SECTIONS])
def test_every_section_is_renderable(s):
    assert s["title"].strip(), f"{s['id']}: empty title"
    assert s["summary"].strip(), f"{s['id']}: empty summary"
    assert s["blocks"], f"{s['id']}: no blocks"
    for b in s["blocks"]:
        assert b["kind"] in help_mod.BLOCK_KINDS, f"{s['id']}: unknown block kind {b['kind']!r}"
        if b["kind"] in ("text", "note"):
            assert b["text"].strip()
        elif b["kind"] == "list":
            assert b["items"] and all(str(i).strip() for i in b["items"])
        elif b["kind"] == "defs":
            assert b["rows"] and all(r["term"].strip() and r["desc"].strip() for r in b["rows"])


def test_help_content_carries_no_markup():
    """No block may contain raw HTML. The template never uses |safe, so markup
    here would render as visible angle brackets — and the day someone adds
    |safe to 'make that table work', unescaped content would be waiting."""
    for s in help_mod.SECTIONS:
        for chunk in _strings_of(s):
            assert "<" not in chunk and ">" not in chunk, f"{s['id']}: markup in help text: {chunk[:60]!r}"


def _strings_of(obj):
    if isinstance(obj, str):
        yield obj
    elif isinstance(obj, dict):
        for v in obj.values():
            yield from _strings_of(v)
    elif isinstance(obj, (list, tuple)):
        for v in obj:
            yield from _strings_of(v)


# ---------------------------------------------------------------------------
# 2. lookup + context, including the negative control
# ---------------------------------------------------------------------------
def test_a_known_section_resolves():
    s = help_mod.get_section("panes")
    assert s is not None and s["id"] == "panes"


@pytest.mark.parametrize(
    "bad",
    ["nope", "", "PANES", "panes/", "../config", "help.py", "a" * 40, None, 7, ["panes"]],
)
def test_anything_that_is_not_a_section_is_none(bad):
    """None, never an empty section — this is what lets the route 404."""
    assert help_mod.get_section(bad) is None


def test_page_context_without_an_id_carries_every_section():
    ctx = help_mod.page_context()
    assert [s["id"] for s in ctx["help"]["sections"]] == [s["id"] for s in help_mod.SECTIONS]
    assert ctx["help"]["single"] is False
    assert len(ctx["help"]["index"]) == len(help_mod.SECTIONS)


def test_page_context_with_an_id_carries_only_that_section():
    ctx = help_mod.page_context("rag")
    assert [s["id"] for s in ctx["help"]["sections"]] == ["rag"]
    assert ctx["help"]["single"] is True and ctx["help"]["current"] == "rag"
    # …and the index is still whole, so the page can offer the way back.
    assert len(ctx["help"]["index"]) == len(help_mod.SECTIONS)


def test_page_context_is_none_for_an_unknown_section():
    assert help_mod.page_context("nope") is None
    assert help_mod.page_context("../secrets") is None


# ---------------------------------------------------------------------------
# 3. scope-safety of the context shape
# ---------------------------------------------------------------------------
def _narrow_scope():
    from app.scope import Scope

    return Scope(user="dana", global_role="operator", project_id="ss-nw",
                 project_role="operator", sites=frozenset({"nwc"}), all_sites=False)


def test_the_scrubber_has_nothing_to_drop_in_the_help_context():
    """scrub() drops any dict carrying an out-of-scope `site` key, and under
    SCOPE_STRICT (CI) a single dropped row RAISES. Help is static and names no
    site, so the correct number of dropped rows is exactly zero — for the whole
    page and for every single-section page."""
    from app import scope as scope_mod

    sc = _narrow_scope()
    for ctx in [help_mod.page_context()] + [help_mod.page_context(s["id"]) for s in help_mod.SECTIONS]:
        clean, dropped = scope_mod.scrub(ctx, sc)
        assert dropped == 0
        assert clean == ctx


def test_the_scrubber_can_actually_see_into_the_help_context():
    """POSITIVE CONTROL for the test above, and the reason `_walkable()` exists.

    scrub() recurses into dicts and lists and STOPS at a tuple — it returns one
    untouched, contents unexamined. The content is authored as tuples, so a
    context handed over verbatim would score zero drops because nothing was
    looked at, not because nothing was there. Plant a foreign row and the
    scrubber must find it; if this ever goes green-by-blindness, the zero above
    means nothing.
    """
    from app import scope as scope_mod

    ctx = help_mod.page_context()
    ctx["help"]["sections"][0]["blocks"].append({"kind": "text", "text": "x", "site": "avc"})
    _clean, dropped = scope_mod.scrub(ctx, _narrow_scope())
    assert dropped == 1, "the scrubber cannot see inside the help context — the zero above is blind"


def test_redaction_is_a_noop_over_the_help_context():
    """redact() strips free-text passthroughs by exact path (rag.raw, todo.raw,
    res.cmd, res.err, prov.host, prov.note). Help gathers nothing, so it has
    none of those keys — asserted here so that a future 'let me show the
    publisher host on the help page' change has to think about it."""
    from app import scope as scope_mod

    ctx = help_mod.page_context()
    assert scope_mod.redact(ctx, _narrow_scope()) == ctx
    for top, _key in scope_mod.REDACT_PATHS:
        assert top not in ctx, f"help ctx grew a redactable {top!r} key"


# ---------------------------------------------------------------------------
# 4. rendering, through a real Jinja environment
# ---------------------------------------------------------------------------
@pytest.fixture(scope="module")
def jinja():
    jinja2 = pytest.importorskip("jinja2")
    env = jinja2.Environment(
        loader=jinja2.FileSystemLoader(str(TEMPLATES)), autoescape=True
    )
    # base.html is the app's real layout; nothing in it needs the app object.
    return env


def _render(jinja, ctx):
    return jinja.get_template("help.html").render(user={"name": "dana", "role": "operator"},
                                                  scope=None, **ctx)


def test_the_full_page_renders_every_declared_section(jinja):
    html = _render(jinja, help_mod.page_context())
    for s in help_mod.SECTIONS:
        assert f'id="help-{s["id"]}"' in html, f"section {s['id']} has no anchor on the page"
        assert s["title"] in html, f"section {s['id']} title missing from the page"
        assert s["summary"] in html


def _content_strings(block, where: str) -> list:
    """A block's actual CONTENT strings — never its discriminator.

    This exists because the obvious implementation is silently vacuous.
    `_strings_of()` walks `dict.values()`, and a block's FIRST value is its
    kind: `{"kind": "text", "text": "…"}` yields `"text"` before it yields a
    word of help. Probing the page for that string proves nothing whatsoever,
    because the template's own class names — `helptext`, `helplist`, `helpdefs`,
    `helpnote` — each contain their kind as a substring, and they are emitted by
    the stylesheet in `help.html` whether or not a single block rendered. A body
    test built that way passes forever, including over a title-only shell.

    So: read the content keys BY NAME, and refuse to guess at an unknown kind
    rather than quietly probing nothing.
    """
    kind = block.get("kind")
    if kind in ("text", "note"):
        return [block["text"]]
    if kind == "list":
        return [str(i) for i in block["items"]]
    if kind == "defs":
        return [r["desc"] for r in block["rows"]] + [r["term"] for r in block["rows"]]
    raise AssertionError(
        f"{where}: unknown block kind {kind!r} — this probe would cover nothing. "
        "Teach _content_strings() the new kind at the same time as the template."
    )


def _body_probe(block, where: str) -> str:
    """A distinctive run of this block's prose, escaped as Jinja will escape it.

    Distinctive = long. A 40+ character run of English cannot be satisfied by a
    class name, an id, a heading or any of the page furniture, which is the
    whole failure this replaces.
    """
    from markupsafe import escape          # a hard dependency of jinja2

    best = max(_content_strings(block, where), key=len)
    assert len(best) >= 40, (
        f"{where}: longest content string is only {len(best)} chars ({best!r}) — "
        "too short to prove anything; probing it could collide with page furniture"
    )
    return str(escape(best[:80]))


def test_the_full_page_renders_the_body_of_each_section(jinja):
    """Titles alone would pass if every section rendered as an empty shell —
    and note that titles and summaries BOTH also appear in the table of
    contents, so the sibling test above cannot detect that shell either.

    This one probes every block of every section for a long, distinctive run of
    its real prose. Gut the `{% for b in s.blocks %}` loop in
    `_help_section.html` and this is the test that goes red.
    """
    html = _render(jinja, help_mod.page_context())
    for s in help_mod.SECTIONS:
        for i, block in enumerate(s["blocks"]):
            where = f"section {s['id']} block {i} ({block.get('kind')})"
            assert _body_probe(block, where) in html, f"{where} rendered no body text"


def test_the_body_probe_is_not_satisfied_by_an_empty_shell(jinja):
    """The meta-test: prove the probe above can actually FAIL.

    Renders each section as a title-only shell — exactly what a gutted block
    loop produces — and asserts the probes are absent. Without this, a probe
    that had drifted back to matching page furniture would look like coverage.
    """
    shell = jinja.from_string(
        '<section id="help-{{ s.id }}"><h2>{{ s.title }}</h2>'
        '<p class="helptext helplist helpdefs helpnote">{{ s.summary }}</p></section>'
    )
    for s in help_mod.SECTIONS:
        html = shell.render(s=s)
        for i, block in enumerate(s["blocks"]):
            where = f"section {s['id']} block {i}"
            assert _body_probe(block, where) not in html, (
                f"{where}: the probe matches a title-only shell — it is vacuous")


def test_a_single_section_page_renders_only_that_section(jinja):
    html = _render(jinja, help_mod.page_context("rag"))
    assert 'id="help-rag"' in html
    for s in help_mod.SECTIONS:
        if s["id"] != "rag":
            assert f'id="help-{s["id"]}"' not in html, f"single-section page leaked {s['id']}"
    assert "all help topics" in html          # the way back


def test_every_block_kind_reaches_the_page(jinja):
    """One synthetic section exercising all four kinds — proof the template
    handles each, independent of which kinds today's content happens to use."""
    ctx = {"help": {"index": [], "single": True, "current": "x", "sections": [{
        "id": "x", "title": "Synthetic", "summary": "sum", "blocks": (
            help_mod._t("a paragraph here"),
            help_mod._l("first item", "second item"),
            help_mod._d(("a term", "its meaning")),
            help_mod._n("a note here"),
        )}]}}
    html = _render(jinja, ctx)
    for probe in ("a paragraph here", "first item", "second item", "a term", "its meaning", "a note here"):
        assert probe in html
    assert "helpnote" in html and "helpdefs" in html and "helplist" in html


def test_an_unknown_block_kind_is_loud_rather_than_silent(jinja):
    ctx = {"help": {"index": [], "single": True, "current": "x", "sections": [{
        "id": "x", "title": "Synthetic", "summary": "sum",
        "blocks": ({"kind": "video", "text": "…"},)}]}}
    html = _render(jinja, ctx)
    assert "unknown block kind" in html, "a block kind nobody renders vanished silently"


def test_help_text_is_escaped_not_interpreted(jinja):
    """The content file is trusted, but the template must not be the thing that
    trusts it: no |safe anywhere, so hostile text renders as text."""
    ctx = {"help": {"index": [], "single": True, "current": "x", "sections": [{
        "id": "x", "title": "<script>alert(1)</script>", "summary": "s",
        "blocks": (help_mod._t("<img src=x onerror=alert(1)>"),)}]}}
    html = _render(jinja, ctx)
    assert "<script>alert(1)</script>" not in html
    assert "<img src=x" not in html
    assert "&lt;script&gt;" in html and "&lt;img" in html


def test_no_template_in_this_stage_uses_safe():
    """Checked over the templates with their Jinja comments stripped — the
    comments *talk about* |safe, and a check that its own documentation trips
    is a check that gets deleted rather than fixed."""
    import re as _re

    for name in ("help.html", "_help_section.html"):
        body = _re.sub(r"\{#.*?#\}", "", (TEMPLATES / name).read_text(), flags=_re.S)
        assert "|safe" not in body and "| safe" not in body, f"{name} uses |safe"


# ---------------------------------------------------------------------------
# 5. the routes, wired exactly as help-wiring.md declares them
# ---------------------------------------------------------------------------
def _purge_app_modules() -> None:
    """Drop `app.*` so the next import re-reads config from the environment."""
    for m in list(sys.modules):
        if m == "app" or m.startswith("app."):
            del sys.modules[m]


@pytest.fixture(scope="module")
def env():
    """Module-scoped env, RESTORED on teardown.

    `NWP_CONSOLE_SCOPE_STRICT=1` in particular must not outlive this file.
    `os.environ` is process-global and pytest runs modules in one process in
    sorted order, so setting it and walking away silently re-configures every
    test module sorted after `test_help.py` — turning a scrub drop from a
    counted return value into a raised exception in suites that never asked for
    that. Teardown restores the previous values (unsetting the ones that were
    absent) and purges `app.*` again, so the next module imports under the
    environment it actually declared.
    """
    tmp = tempfile.mkdtemp(prefix="nwp-console-help-test-")
    wanted = {
        "NWP_CONSOLE_DATA": tmp,
        "NWP_CONSOLE_ROOT": tmp,
        "NWP_CONSOLE_QUOKKA_URL": "http://127.0.0.1:9",
        "NWP_CONSOLE_STT_BACKEND": "off",
        "NWP_CONSOLE_TTS_BACKEND": "off",
        # A leak must RAISE here, not be quietly repaired — same as the tenancy suite.
        "NWP_CONSOLE_SCOPE_STRICT": "1",
    }
    saved = {k: os.environ.get(k) for k in wanted}
    os.environ.update(wanted)
    _purge_app_modules()
    try:
        yield tmp
    finally:
        for k, old in saved.items():
            if old is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = old
        _purge_app_modules()


@pytest.fixture(scope="module")
def wired(env):
    """The integrator's snippet, executed. If this fixture stops matching
    help-wiring.md §1, one of the two is wrong."""
    pytest.importorskip("fastapi")
    pytest.importorskip("httpx")
    from fastapi import Depends, FastAPI, HTTPException, Request
    from fastapi.responses import HTMLResponse

    from app import help as help_module
    from app import main as app_main
    from app.scope import Scope

    app_main.projects.add_project("ss-nw", name="Saint School + Narrow Way",
                                  sites=["nwc", "ssc"], created_by="rob")
    app_main.store.add_user("dana", "operator")
    app_main.projects.set_project_role("dana", "ss-nw", "operator")

    api = FastAPI()

    @api.get("/help", response_class=HTMLResponse)
    def help_page(request: Request, sc: Scope = Depends(app_main.scoped("viewer"))):
        return app_main._pane(request, "help.html", help_module.page_context(), sc)

    @api.get("/help/{section_id}", response_class=HTMLResponse)
    def help_section(request: Request, section_id: str,
                     sc: Scope = Depends(app_main.scoped("viewer"))):
        ctx = help_module.page_context(section_id)
        if ctx is None:
            raise HTTPException(status_code=404)
        return app_main._pane(request, "help.html", ctx, sc)

    return api, app_main, help_module


def _client(wired, user):
    from fastapi.testclient import TestClient

    api, app_main, _ = wired
    api.dependency_overrides[app_main.current_user] = (lambda: user) if user else (lambda: None)
    return TestClient(api)


def test_a_viewer_can_load_the_help_page(wired):
    r = _client(wired, {"name": "dana", "role": "viewer"}).get("/help")
    assert r.status_code == 200
    assert "Help" in r.text


def test_the_help_page_serves_every_declared_section_over_http(wired):
    _api, _main, help_module = wired
    body = _client(wired, {"name": "dana", "role": "viewer"}).get("/help").text
    for s in help_module.SECTIONS:
        assert f'id="help-{s["id"]}"' in body, f"{s['id']} missing from the served page"


def test_each_section_is_reachable_on_its_own_url(wired):
    _api, _main, help_module = wired
    c = _client(wired, {"name": "dana", "role": "viewer"})
    for s in help_module.SECTIONS:
        r = c.get(f"/help/{s['id']}")
        assert r.status_code == 200, f"/help/{s['id']} -> {r.status_code}"
        assert f'id="help-{s["id"]}"' in r.text


def test_an_unknown_section_404s_rather_than_rendering_an_empty_page(wired):
    """THE negative control. A 200 with nothing in it is indistinguishable from
    a topic someone forgot to write."""
    c = _client(wired, {"name": "dana", "role": "viewer"})
    for bad in ("nope", "PANES", "..%2fconfig", "help.py", "a" * 40):
        r = c.get(f"/help/{bad}")
        assert r.status_code == 404, f"/help/{bad} -> {r.status_code}, expected 404"


def test_help_is_behind_authentication(wired):
    """The fixture app is a BARE `FastAPI()`: it registers the two handlers and
    nothing else, so an unauthenticated request surfaces the raw 401 that
    `scoped("viewer")` raises. That is what is being pinned here — the route
    refuses, rather than rendering help to a stranger.

    It is NOT what a browser will see once this is wired into the real app; see
    the next test. Do not "fix" that difference by loosening this assertion.
    """
    r = _client(wired, None).get("/help")
    assert r.status_code == 401


def test_the_real_app_redirects_an_unauthenticated_browser_to_login(wired):
    """The delta the integrator would otherwise meet as a surprise.

    `main.py` registers `@app.exception_handler(401)`, which turns the same 401
    into `303 -> /login` when the request is a GET that says it accepts HTML.
    So once `/help` is wired into the real app, a signed-out browser lands on
    the sign-in page, not on a 401 — while an htmx/JSON caller still gets the
    401. Asserted against the REAL app object (on `/`, which is already wired)
    so it stays true independently of this stage.
    """
    from fastapi.testclient import TestClient

    _api, app_main, _ = wired
    c = TestClient(app_main.app)

    browser = c.get("/", headers={"accept": "text/html"}, follow_redirects=False)
    assert browser.status_code == 303, f"expected a redirect for a browser, got {browser.status_code}"
    assert browser.headers["location"] == "/login"

    # …and the machine-shaped request is still a plain 401, not a redirect.
    api_call = c.get("/", headers={"accept": "application/json"}, follow_redirects=False)
    assert api_call.status_code == 401


def test_a_scoped_member_gets_help_with_strict_scoping_on(wired):
    """dana is in one project and SCOPE_STRICT is set, so _pane() raises if the
    context carried a single foreign row. A 200 here is the proof that the help
    context survives the shared scrub+redact path unchanged."""
    r = _client(wired, {"name": "dana", "role": "operator"}).get("/help")
    assert r.status_code == 200
    assert "Saint School" in r.text or "ss-nw" in r.text     # the scope bar rendered too


# ---------------------------------------------------------------------------
# 6. coverage: the tab bar may not grow a pane the help does not describe
# ---------------------------------------------------------------------------
def test_every_pane_in_the_tab_bar_has_its_own_help_section(wired):
    """THE coverage gate. main.PANES is the whole UI — one full-screen pane per
    entry — so a pane id with no same-id help section is a screen with no
    instructions. This is the test that goes red when someone adds a tab
    without writing its help, which is exactly when it should."""
    _api, app_main, help_module = wired
    ids = {s["id"] for s in help_module.SECTIONS}
    missing = [pane for pane, _label in app_main.PANES if pane not in ids]
    assert not missing, (
        f"panes with no help section (need /help/<pane> with the same id): {missing}"
    )


def test_the_tab_bar_offers_contextual_help_for_the_active_pane():
    """The [feedback-2] item ('help topic should be clickable'), from the tab
    bar's side: index.html carries a contextual help link whose href the
    pane-switching script retargets to /help/<active pane>. String-asserted
    against the template because the script is inline and never unit-run."""
    body = (TEMPLATES / "index.html").read_text()
    assert 'id="pane-help"' in body, "no contextual help link in the tab bar"
    assert "'/help/' +" in body, "the script does not retarget the help link per pane"


def test_the_demo_help_actually_tells_a_tester_how_to_get_in():
    """The operator's ask, pinned: the tester-facing demo help must name the
    join path, the code, the nightly reset and the code's survival of it.
    Presence-of-words, not prose quality — but a section that loses any of
    these has lost the instruction it exists to give."""
    s = help_mod.get_section("demo-tester")
    assert s is not None, "no demo-tester help section"
    text = " ".join(_strings_of(s))
    for must in ("/demo/join", "code", "reset", "expir"):
        assert must in text, f"demo-tester help no longer mentions {must!r}"
