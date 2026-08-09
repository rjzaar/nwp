"""T-visuals — the Visuals pane: geometry, honesty, and tenancy.

Three layers, in increasing cost:

  1. GEOMETRY   — pure arithmetic over app/visuals.py. Stdlib only; no jinja2,
                  no fastapi, no filesystem, no server.
  2. HONESTY    — the states this pane exists to keep apart: "clean" (we asked,
                  the answer is zero) versus "we could not find out". Getting
                  these two confused is the single failure mode that matters
                  here, because a chart that looks healthy because it is empty
                  is worse than no chart at all.
  3. TENANCY    — the real Scope, over the real published-snapshot fixture,
                  through the real templates: a member must not see a foreign
                  site anywhere in the rendered bytes.

PROVING THESE TESTS CAN FAIL (the red-first switch)
---------------------------------------------------
A test that only ever passes proves nothing, so this module ships with a
switch that simulates the naive implementation — the one that treats every
readable feed as a drawable chart and every zero as good news:

    NWP_CONSOLE_TEST_NAIVE_VISUALS=1 python3 -m pytest tests/test_visuals.py

Expect the honesty and negative-control tests to go RED (they are listed in
RED_FIRST below, and `test_the_red_first_switch_is_wired` fails if the switch
stops biting). The switch is honoured ONLY by this module; it does not exist
in the application, exactly like NWP_CONSOLE_TEST_DISABLE_SCOPE in
test_tenant_isolation.py.
"""
import json
import os
import re
import shutil
import sys
import tempfile
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import visuals  # noqa: E402  (path juggling above is deliberate)

FIXTURE = Path(__file__).resolve().parent / "fixtures" / "fleet-state-mixed.json"

# Sites dana must NEVER see. Same set the tenancy suite uses, minus `dir`,
# which is a substring of `dir1` and of the word "direction" — asserting on it
# would make this file fail for reasons that are not leaks.
FOREIGN = ("avc", "mt", "cathnet", "dir1")

NAIVE = os.environ.get("NWP_CONSOLE_TEST_NAIVE_VISUALS") == "1"

# The tests the red-first switch must break. Named so the proof is checkable
# rather than a claim in a docstring.
RED_FIRST = (
    "test_a_zero_is_only_clean_when_every_site_was_actually_audited",
    "test_an_unreadable_feed_never_produces_a_drawable_chart",
    "test_the_two_zeros_are_visibly_different_states",
    "test_a_missing_artifact_renders_no_chart_at_all",
)


# ---------------------------------------------------------------------------
# the red-first switch
# ---------------------------------------------------------------------------
def _naive_severity_view(sec):
    """The bug: any readable feed is a chart, and a zero is just a zero.

    This is what you get by writing the obvious thing — it draws an empty
    chart for a fleet nobody managed to audit, which reads as "no problems".
    """
    totals = (sec or {}).get("totals") or {}
    by_sev = totals.get("by_severity") or {}
    bars = [{"severity": s, "count": int(by_sev[s]), "role": "muted", "x": 74, "y": 0,
             "w": 10, "h": 14, "path": "M0,0 Z", "label": s, "label_y": 11, "tip_x": 90}
            for s in sorted(by_sev)]
    return {"ok": True, "state": "ok", "bars": bars, "height": max(14, len(bars) * 24),
            "baseline_x": 74, "total": int(totals.get("advisories", 0) or 0),
            "sites": int(totals.get("sites", 0) or 0), "sites_affected": 0,
            "sites_unknown": 0, "platform_alerts": 0, "worst": "",
            "table": [{"severity": b["severity"], "count": b["count"]} for b in bars]}


def _naive_fleet_view(rag, max_tiles=visuals.MAX_TILES):
    """The same bug on the fleet chart: render whatever arrived, even nothing."""
    sites = [s for s in ((rag or {}).get("sites") or []) if isinstance(s, dict)]
    return {"ok": True, "state": "ok", "segments": [], "legend": [],
            "bar_h": visuals.FLEET_BAR_H, "tiles": [], "tiles_h": 20,
            "total": len(sites), "shown": 0, "hidden": 0, "worst": "",
            "table": []}


if NAIVE:  # pragma: no cover — only ever taken by the red-first proof run
    visuals.severity_view = _naive_severity_view
    visuals.fleet_view = _naive_fleet_view


def test_the_red_first_switch_is_wired():
    """The switch must actually be reachable, or the proof above is folklore."""
    assert callable(_naive_severity_view) and callable(_naive_fleet_view)
    assert RED_FIRST, "no tests are claimed to go red — the proof means nothing"
    if NAIVE:
        assert visuals.severity_view is _naive_severity_view


# ---------------------------------------------------------------------------
# 1. GEOMETRY — stdlib only
# ---------------------------------------------------------------------------
_ARC = re.compile(r"[Aa]\d")


def test_bar_path_rounds_only_the_requested_end():
    """'4px rounded data-end, square at the baseline' — per END, not per corner.

    Rounding an interior join would open a wedge of surface that reads as a
    gap which is not the 2px spacer, i.e. it would invent a separation.
    """
    both = visuals.bar_path(0, 0, 100, 14, 4, left=True, right=True)
    right = visuals.bar_path(0, 0, 100, 14, 4, left=False, right=True)
    square = visuals.bar_path(0, 0, 100, 14, 4, left=False, right=False)
    assert len(_ARC.findall(both)) == 4, both      # two corners per rounded end
    assert len(_ARC.findall(right)) == 2, right
    assert not _ARC.findall(square), square
    for d in (both, right, square):
        assert d.endswith("Z")


def test_bar_path_clamps_the_radius_on_a_tiny_bar():
    """A 3px bar must not grow a 4px radius and turn inside out."""
    d = visuals.bar_path(0, 0, 3, 14, 4, left=True, right=True)
    assert "-" not in d.split("M")[1][:12], d      # no negative sweep coords
    assert d.endswith("Z")


def test_stack_omits_zero_counts_and_gaps_the_rest():
    segs = visuals.stack([("a", 3, "crit"), ("b", 0, "warn"), ("c", 1, "ok")], 100.0)
    assert [s["label"] for s in segs] == ["a", "c"], "a zero-count segment was drawn"
    # widths + the single 2px gap fill the width exactly
    assert round(sum(s["w"] for s in segs) + visuals.GAP, 2) == 100.0
    assert round(segs[1]["x"] - (segs[0]["x"] + segs[0]["w"]), 2) == visuals.GAP


def test_stack_rounds_only_the_outer_ends_of_the_whole_bar():
    segs = visuals.stack([("a", 1, "crit"), ("b", 1, "warn"), ("c", 1, "ok")], 300.0)
    assert len(_ARC.findall(segs[0]["path"])) == 2, "first segment lost its left round"
    assert not _ARC.findall(segs[1]["path"]), "an interior join was rounded"
    assert len(_ARC.findall(segs[2]["path"])) == 2, "last segment lost its right round"


def test_stack_of_nothing_is_empty_not_a_zero_width_bar():
    assert visuals.stack([("a", 0, "crit")], 100.0) == []
    assert visuals.stack([], 100.0) == []


def test_a_label_that_does_not_fit_is_dropped_rather_than_clipped():
    """The spec forbids clipping or overflowing a label. `fits` is the
    predicate that decides, so it must be pessimistic, not optimistic."""
    assert visuals.fits("7", 40) is True
    assert visuals.fits("1234567890", 20) is False
    segs = visuals.stack([("tiny", 1, "crit"), ("big", 200, "ok")], 300.0)
    assert segs[0]["label_inside"] is False, "a value was set inside a ~1px segment"
    assert segs[1]["label_inside"] is True


def test_clamp_text_never_exceeds_its_width_and_keeps_short_names_intact():
    assert visuals.clamp_text("avc", 100) == "avc"
    long = visuals.clamp_text("a-very-long-site-name-indeed", 40)
    assert long.endswith("…") and len(long) < len("a-very-long-site-name-indeed")


def test_num_never_raises_on_a_hostile_feed_value():
    for junk in (None, "x", [], {}, "-4", -4, float("nan")):
        assert visuals._num(junk) >= 0


# ---------------------------------------------------------------------------
# 2. HONESTY — the two zeros, and the unreadable feed
# ---------------------------------------------------------------------------
def _sec(advisories=0, unknown=0, sites=3, by_sev=None, platform=0):
    return {"ok": True, "totals": {
        "sites": sites, "sites_affected": 1 if advisories else 0,
        "advisories": advisories, "sites_unknown": unknown,
        "platform_alerts": platform, "by_severity": by_sev or {}, "worst": ""}}


def test_a_zero_is_clean_only_when_every_site_was_actually_audited():
    v = visuals.severity_view(_sec(advisories=0, unknown=0))
    assert v["state"] == "clean"
    assert "no open advisories" in v["reason"]


def test_a_zero_is_only_clean_when_every_site_was_actually_audited():
    """THE test of this pane.

    `pl audit` reports a site whose record is stale/unreadable/missing as
    UNKNOWN, and the published totals carry that as `sites_unknown`. Drawing
    zero bars for such a fleet says "no advisories" when the truth is "nobody
    looked" — the exact lie the console's provenance idiom exists to prevent.
    """
    v = visuals.severity_view(_sec(advisories=0, unknown=2, sites=3))
    assert v["ok"] is False, "an unaudited fleet was rendered as a chart"
    assert v["state"] != "clean", "'nobody looked' was reported as 'clean'"
    assert "could not be audited" in v["reason"]
    assert "not clean" in v["hint"].lower()


def test_platform_alerts_are_surfaced_even_though_they_have_no_bars():
    """A Moodle behind on point releases has no advisory list but IS the RED.
    It must not vanish just because it cannot be drawn as a severity bar."""
    v = visuals.severity_view(_sec(advisories=0, unknown=0, platform=2))
    assert v["ok"] is False and v["state"] != "clean"
    assert "platform security releases" in v["reason"]

    # ...and when there ARE bars, the count still rides along for the template.
    v2 = visuals.severity_view(_sec(advisories=1, by_sev={"high": 1}, platform=2))
    assert v2["ok"] is True and v2["platform_alerts"] == 2


def test_the_two_zeros_are_visibly_different_states():
    clean = visuals.severity_view(_sec(advisories=0, unknown=0))
    unknown = visuals.severity_view(_sec(advisories=0, unknown=1))
    assert clean["state"] == "clean"
    assert unknown["state"] == "missing"
    assert clean["state"] != unknown["state"], (
        "'audited and clean' and 'never audited' render identically — a reader "
        "cannot tell good news from no news"
    )


@pytest.mark.parametrize("view,bad", [
    ("fleet_view", {"ok": False, "error": "boom"}),
    ("severity_view", {"ok": False, "error": "no security feed in this snapshot"}),
    ("todo_view", {"ok": False, "error": "nope"}),
])
def test_an_unreadable_feed_never_produces_a_drawable_chart(view, bad):
    v = getattr(visuals, view)(bad)
    assert v["ok"] is False, f"{view} drew a chart from an unreadable feed"
    assert v["state"] == "missing"
    assert v["reason"], "a no-data state with no reason is an empty chart with a border"
    assert not v.get("segments") and not v.get("bars") and not v.get("rows")


@pytest.mark.parametrize("view", ["fleet_view", "severity_view", "todo_view"])
def test_garbage_input_degrades_instead_of_raising(view):
    for junk in (None, {}, [], "text", {"ok": True}):
        v = getattr(visuals, view)(junk)
        assert isinstance(v, dict) and "ok" in v


def test_ci_distinguishes_no_token_from_no_merge_requests():
    """Two different facts that a naive pane collapses into one empty strip."""
    no_token = visuals.ci_view([], api_ok=False)
    assert no_token["ok"] is False and "token" in no_token["reason"]

    empty = visuals.ci_view([{"project": "nwp/nwp", "mrs": [], "url": "u"}], api_ok=True)
    assert empty["ok"] is False and empty["state"] == "clean"
    assert "no open merge requests" in empty["reason"]


def test_a_pipelineless_mr_is_unknown_not_success():
    v = visuals.ci_view([{"project": "p", "mrs": [{"mr": {"iid": 1}, "pipeline": None}],
                          "url": "u"}], api_ok=True)
    assert v["cells" if "cells" in v else "strips"]
    cell = v["strips"][0]["cells"][0]
    assert cell["status"] == "none" and cell["role"] == "muted", (
        "an MR with no pipeline was painted as if it had passed"
    )


def test_fleet_view_marks_an_unrecognised_grade_as_unknown_not_green():
    v = visuals.fleet_view({"ok": True, "counts": {"RED": 0, "AMBER": 0, "GREEN": 0, "OTHER": 1},
                            "sites": [{"site": "x", "grade": "WAT", "reasons": [], "phase": ""}]})
    assert v["tiles"][0]["role"] == "muted"
    assert v["tiles"][0]["grade"] == "WAT"


def test_every_per_site_row_carries_the_key_the_scrubber_looks_for():
    """scope.scrub() drops a dict whose `site` is out of scope. A chart row
    keyed any other way would be invisible to net 2 and silently exempt."""
    fleet = visuals.fleet_view({"ok": True, "counts": {"RED": 1, "AMBER": 0, "GREEN": 0, "OTHER": 0},
                                "sites": [{"site": "avc", "grade": "RED", "reasons": [], "phase": ""}]})
    assert all("site" in t for t in fleet["tiles"])
    assert all("site" in r for r in fleet["table"])

    todo = visuals.todo_view({"ok": True, "items": [{"site": "avc", "priority": "high"}]})
    assert all("site" in r for r in todo["rows"])
    assert all("site" in r for r in todo["table"])


def test_ci_rows_do_not_invent_a_site_key():
    """A CI project is not a site. Giving these rows a `site` key would make
    scrub() drop every one of them (and RAISE under SCOPE_STRICT)."""
    v = visuals.ci_view([{"project": "nwp/nwp", "mrs": [{"mr": {"iid": 1},
                          "pipeline": {"status": "success"}}], "url": "u"}], api_ok=True)
    assert "site" not in v["strips"][0]
    assert all("site" not in c for c in v["strips"][0]["cells"])


def test_an_unattributed_todo_item_is_shown_but_fails_closed_when_scoped():
    """An item with no site is kept (never silently dropped from the totals),
    but its `site` is "" — which scope.allows_site("") refuses, so a scoped
    reader loses the row rather than seeing an unattributable one."""
    v = visuals.todo_view({"ok": True, "items": [{"site": "", "priority": "high"}]})
    assert v["rows"][0]["site"] == ""
    assert v["rows"][0]["display"] == "—"


# ---------------------------------------------------------------------------
# 3. RENDER — needs jinja2 (skips cleanly on a bare interpreter)
# ---------------------------------------------------------------------------
TPL = Path(__file__).resolve().parent.parent / "templates"

GOOD_RAG = {"ok": True, "counts": {"RED": 1, "AMBER": 1, "GREEN": 1, "OTHER": 0},
            "sites": [{"site": "nwc", "grade": "RED", "reasons": ["2 advisories"], "phase": "live"},
                      {"site": "ssc", "grade": "AMBER", "reasons": [], "phase": "dev"},
                      {"site": "ssd", "grade": "GREEN", "reasons": [], "phase": "dev"}]}
GOOD_TODO = {"ok": True, "items": [{"site": "nwc", "priority": "high"},
                                   {"site": "nwc", "priority": "low"},
                                   {"site": "ssc", "priority": "medium"}]}
GOOD_SEC = _sec(advisories=4, by_sev={"critical": 1, "medium": 3})
GOOD_CI = [{"project": "nwp/nwc", "url": "https://example/x",
            "mrs": [{"mr": {"iid": 7}, "pipeline": {"status": "failed"}},
                    {"mr": {"iid": 8}, "pipeline": {"status": "success"}}]}]
FRESH_PROV = {"source": "published", "host": "ws", "age_human": "14 min", "stale": False,
              "snapshot_present": True, "max_age_human": "2 h",
              "generated_at": "2099-01-01T00:00:00Z", "local_host": "console"}


# With subtabs (ops#329) each render shows ONE chart, so the honesty and
# leakage assertions below sweep EVERY chart subtab and concatenate the bytes:
# the coverage claim ("no chart may…") stays exactly as wide as before.
CHART_SUBS = ("fleet", "security", "todo", "ci")


def _render(rag=GOOD_RAG, todo=GOOD_TODO, sec=GOOD_SEC, ci=GOOD_CI, api_ok=True,
            prov=None, user_role="owner"):
    jinja2 = pytest.importorskip("jinja2")
    env = jinja2.Environment(loader=jinja2.FileSystemLoader(str(TPL)), autoescape=True)
    outs = []
    for sub in CHART_SUBS:
        ctx = visuals.page_context(rag, todo, sec, ci, api_ok,
                                   prov or dict(FRESH_PROV), sub=sub)
        ctx.update(user={"name": "rob", "role": user_role}, can_act=False, scope=None,
                   tab="visuals", tab_count="", tab_alert=False)
        outs.append(env.get_template("pane_visuals.html").render(**ctx))
    return "\n".join(outs)


def test_the_pane_renders_all_four_visuals_from_fixture_data():
    out = _render()
    for heading in ("Fleet status", "Open advisories by severity",
                    "Todo load by site", "CI pipelines"):
        assert heading in out, f"{heading!r} missing from the pane"
    assert out.count("<svg") >= 4, "not every visual drew a chart"
    for site in ("nwc", "ssc", "ssd"):
        assert site in out


def test_the_pane_is_read_only():
    """No form, no POST, no action. The Visuals tab is a read surface; the
    allowlist and the Quokka AST test are unaffected by it.

    Since ops#329 the pane DOES carry <button> elements — the subtab bar and
    the overview's per-slot ⟳ — but every one of them is an hx-GET (a re-read,
    never a write), so the assertion that matters is the absence of any POST
    path, not the absence of buttons."""
    out = _render()
    assert "<form" not in out and "hx-post" not in out


def test_no_state_is_encoded_by_colour_alone():
    """Measured, not stylistic: green vs amber is CVD dE 4.5 (protan) on this
    surface, so a reader with the most common colour-blindness gets NOTHING
    from the hue. Every mark must therefore be accompanied by its word."""
    out = _render()
    for word in ("RED", "AMBER", "GREEN"):     # the grade on every tile
        assert word in out
    for word in ("critical", "medium"):        # the severity on every bar
        assert word in out
    for word in ("failed", "success"):         # the pipeline status
        assert word in out
    assert out.count("vzlegend") >= 2, "a multi-series chart shipped without a legend"


def test_every_chart_offers_a_table_view_twin():
    """Tooltips enhance, never gate: every value must also be readable without
    hovering (and by a screen reader)."""
    out = _render()
    assert out.count("Table view") == 4, "a chart has no table-view twin"


def test_a_missing_artifact_renders_no_chart_at_all():
    """THE negative control.

    With every feed unreadable the pane must render the explicit warned
    no-data state — and NOT a single <svg>. An empty chart with axes and no
    marks is indistinguishable from a healthy one at a glance, which is the
    whole failure this pane is built to avoid.
    """
    out = _render(rag={"ok": False, "error": "boom"},
                  todo={"ok": False, "error": "nope"},
                  sec={"ok": False, "error": "no security feed in this snapshot"},
                  ci=[], api_ok=False)
    assert "<svg" not in out, "an empty-but-green chart was drawn for missing data"
    assert out.count("vznodata-missing") >= 4
    assert "no data" in out
    for reason in ("boom", "nope", "no security feed", "token"):
        assert reason in out, f"the pane hid the reason {reason!r}"
    # and it must not be silently reassuring anywhere
    assert "no open advisories" not in out


def test_a_clean_result_looks_different_from_a_missing_one_in_the_markup():
    clean = _render(sec=_sec(advisories=0, unknown=0))
    missing = _render(sec=_sec(advisories=0, unknown=2))
    assert "vznodata-clean" in clean
    assert "vznodata-missing" in missing
    assert "could not be audited" in missing


def test_staleness_shouts_on_every_snapshot_fed_chart():
    """A chart scrolled to on its own must still carry the warning, so the
    ribbon is per-chart and not only in the provenance line."""
    stale = dict(FRESH_PROV, stale=True, age_human="5 h")
    out = _render(prov=stale)
    # Three chart ribbons — fleet, severity, todo. (_provenance.html emits its
    # own "⚠ STALE" line as well, which is why this counts the ribbon CLASS
    # rather than the glyph.)
    assert out.count('class="vzstale"') == 3, "a snapshot-fed chart is missing its stale ribbon"
    assert "drawn from STALE fleet state" in out
    # ...and the CI strip, which is read LIVE, must NOT claim to be stale.
    ci_block = out.split("CI pipelines", 1)[1]
    assert "STALE" not in ci_block
    assert "live" in ci_block


def test_a_hostile_feed_value_is_escaped_not_executed():
    """Snapshot text is third-party. Jinja autoescape is the mechanism; this
    asserts the pane actually runs with it on."""
    nasty = '<script>alert(1)</script>'
    out = _render(rag={"ok": True, "counts": {"RED": 1, "AMBER": 0, "GREEN": 0, "OTHER": 0},
                       "sites": [{"site": nasty, "grade": "RED", "reasons": [], "phase": nasty}]})
    assert "<script>alert(1)</script>" not in out
    assert "&lt;script&gt;" in out


# ---------------------------------------------------------------------------
# 4. TENANCY — the real Scope, the real snapshot, the real templates
# ---------------------------------------------------------------------------
@pytest.fixture(scope="module")
def env():
    tmp = tempfile.mkdtemp(prefix="nwp-console-visuals-test-")
    os.environ["NWP_CONSOLE_DATA"] = tmp
    os.environ["NWP_CONSOLE_ROOT"] = tmp
    os.environ["NWP_CONSOLE_QUOKKA_URL"] = "http://127.0.0.1:9"
    os.environ["NWP_CONSOLE_STT_BACKEND"] = "off"
    os.environ["NWP_CONSOLE_TTS_BACKEND"] = "off"
    os.environ["NWP_CONSOLE_DEMO_SITES"] = "nwd,ssd,avc"
    os.environ["NWP_CONSOLE_CI_PROJECTS"] = "nwp/nwp,nwp/nwc"
    os.environ["NWP_CONSOLE_SCOPE_STRICT"] = "1"       # a leak must RAISE here
    os.environ["NWP_CONSOLE_FLEET_MAX_AGE"] = "0"      # never "stale"
    os.environ["NWP_CONSOLE_NOTIFY_INTERVAL"] = "0"    # no background task
    shutil.copy(FIXTURE, Path(tmp) / "fleet-state.json")
    for m in list(sys.modules):
        if m == "app" or m.startswith("app."):
            del sys.modules[m]
    return tmp


@pytest.fixture(scope="module")
def mod(env):
    pytest.importorskip("fastapi")
    from app import main as app_main

    app_main.projects.add_project(
        "ss-nw", name="Saint School + Narrow Way",
        sites=["nwc", "ssc", "nwd", "ssd", "ss", "ss2", "saintschool"],
        demo_sites=["nwd"],
        gitlab={"issue_label": "project::ss-nw", "ci_projects": ["nwp/nwc"]},
        created_by="rob")
    app_main.projects.add_project(
        "personal", name="Operator's own",
        sites=["avc", "mt", "cathnet", "dir", "dir1"],
        demo_sites=["avc"],
        gitlab={"issue_label": "project::personal", "ci_projects": ["nwp/nwp"]},
        created_by="rob")
    app_main.store.add_user("dana", "operator")
    app_main.store.add_user("rob2", "owner")
    app_main.projects.set_project_role("dana", "ss-nw", "operator")
    return app_main


def _scope_of(mod, name):
    from app.scope import resolve

    u = mod.store.get_user(name)
    rec = {"name": name, "role": u["role"], "projects": mod.store.memberships(name)}
    return resolve(rec, mod.projects.all_projects(),
                   console_demo_sites=mod.config.DEMO_SITES,
                   ci_allowlist=mod.config.CI_PROJECTS)


def _context_for(mod, who, ci_blocks=None, api_ok=False):
    """Exactly what the wired route will build: the SCOPED gatherers, then
    visuals.page_context, then _pane()'s two nets applied by hand (since this
    module does not own main.py and the route is not wired yet)."""
    from app import scope as scope_mod

    sc = _scope_of(mod, who)
    rag, _res, prov = mod._gather_rag(sc)
    todo = mod._gather_todo(sc)[0]
    sec = mod._gather_security(sc)[0]
    pc = mod.visuals.page_context if hasattr(mod, "visuals") else visuals.page_context
    # One MERGED context across every chart subtab, so the assertions below
    # keep covering all four views exactly as they did pre-subtabs.
    ctx = None
    for sub in CHART_SUBS:
        c = pc(rag, todo, sec, ci_blocks or [], api_ok, prov, sub=sub)
        if ctx is None:
            ctx = c
        else:
            for k, v in c["vz"].items():
                ctx["vz"].setdefault(k, v)
    clean, dropped = scope_mod.scrub(ctx, sc)
    if not sc.all_sites:
        clean = scope_mod.redact(clean, sc)
    return sc, ctx, clean, dropped


def _render_ctx(ctx, role="operator"):
    """Render a (possibly merged) context across every chart subtab and
    concatenate — a leak into ANY chart's bytes still fails."""
    jinja2 = pytest.importorskip("jinja2")
    env_ = jinja2.Environment(loader=jinja2.FileSystemLoader(str(TPL)), autoescape=True)
    outs = []
    for sub in CHART_SUBS:
        c = dict(ctx, vz=dict(ctx["vz"], sub=sub,
                              subtabs=ctx["vz"].get("subtabs", list(CHART_SUBS))),
                 user={"name": "x", "role": role}, can_act=False, scope=None,
                 tab="visuals", tab_count="", tab_alert=False)
        outs.append(env_.get_template("pane_visuals.html").render(**c))
    return "\n".join(outs)


def test_a_member_sees_no_foreign_site_in_any_chart(mod):
    """The leakage assertion, made against the RENDERED BYTES — what leaks is
    what is sent, not what an intermediate dict happened to hold."""
    _sc, _ctx, clean, _dropped = _context_for(mod, "dana")
    out = _render_ctx(clean)
    for f in FOREIGN:
        assert f not in out, f"LEAK: foreign site {f!r} reached the Visuals pane"
    for mine in ("nwc", "ssc", "ssd"):
        assert mine in out, f"{mine} vanished from my own Visuals pane"


def test_the_owner_still_sees_the_whole_fleet(mod):
    _sc, ctx, clean, _d = _context_for(mod, "rob2")
    out = _render_ctx(clean, role="owner")
    for site in FOREIGN + ("nwc", "ssc"):
        assert site in out, f"owner lost sight of {site}"


def test_chart_totals_are_recomputed_not_inherited_from_the_fleet(mod):
    """A count taken before filtering encodes exactly the foreign facts the
    filtering exists to hide. The fixture is 12 sites fleet-wide; ss-nw is 7."""
    _sc, ctx, _clean, _d = _context_for(mod, "dana")
    assert ctx["vz"]["fleet"]["total"] == 7, "the fleet chart counted foreign sites"
    owner_ctx = _context_for(mod, "rob2")[1]
    assert owner_ctx["vz"]["fleet"]["total"] == 12
    # todo: the fixture holds 6 items fleet-wide, 2 of them in ss-nw
    assert ctx["vz"]["todo"]["total"] == 2, "the todo chart counted foreign items"
    # advisories: 2 affected sites fleet-wide, 1 of them in ss-nw
    assert ctx["vz"]["severity"]["sites"] == 1, "the advisory headline leaked fleet totals"


def test_the_context_carries_no_row_the_scrubber_would_have_to_drop(mod):
    """Net 2 must be a NO-OP here. Under SCOPE_STRICT a dropped row raises, so
    if a future change lets a foreign row into this context the pane 500s in
    CI rather than quietly rendering 11/12ths of the truth."""
    _sc, _ctx, _clean, dropped = _context_for(mod, "dana")
    assert dropped == 0, f"{dropped} row(s) had to be scrubbed out of the Visuals context"


def test_the_shared_redactor_reaches_the_visuals_publisher_host(mod):
    """`prov` must sit at the TOP LEVEL of the context: redact() strips
    ctx['prov']['host'] and ['note'] by EXACT PATH, so nesting it under `vz`
    would silently exempt this pane from a redaction every other read pane
    obeys."""
    _sc, ctx, clean, _d = _context_for(mod, "dana")
    assert "prov" in ctx, "prov is not at the top level — redact() cannot reach it"
    assert ctx["prov"].get("host") == "workstation-secret-hostname"
    assert "host" not in clean["prov"], "the publisher hostname reached a member"
    out = _render_ctx(clean)
    assert "workstation-secret-hostname" not in out

    # ...and the owner still sees it, because the redaction is about tenancy.
    owner_clean = _context_for(mod, "rob2")[2]
    assert owner_clean["prov"].get("host") == "workstation-secret-hostname"


def test_ci_charts_only_cover_the_projects_in_scope(mod, monkeypatch):
    """The CI strip is keyed on `project`, which scrub() cannot filter — so the
    narrowing has to have happened upstream, in Scope.ci_projects."""
    def fake_open_mrs(project, per_page=10):
        return {"ok": True, "data": [{"iid": 1, "title": f"MR in {project}",
                                      "web_url": "https://x"}]}

    monkeypatch.setattr(mod.gitlab, "has_token", lambda: True)
    monkeypatch.setattr(mod.gitlab, "open_mrs", fake_open_mrs)
    monkeypatch.setattr(mod.gitlab, "mr_detail",
                        lambda p, i: {"ok": True, "data": {"head_pipeline": {"status": "failed", "id": 1}}})

    sc = _scope_of(mod, "dana")
    blocks, api_ok = mod._gather_ci(sc)
    assert api_ok is True
    assert [b["project"] for b in blocks] == ["nwp/nwc"], "a foreign CI project was queried"

    view = visuals.ci_view(blocks, api_ok)
    assert view["ok"] is True and view["total"] == 1
    out = _render_ctx({"prov": {}, "vz": {"fleet": visuals.fleet_view({"ok": False, "error": "x"}),
                                          "severity": visuals.severity_view({"ok": False}),
                                          "todo": visuals.todo_view({"ok": False}),
                                          "ci": view, "stale": False,
                                          "chart_w": visuals.CHART_W}})
    assert "nwp/nwc" in out
    assert "nwp/nwp" not in out, "LEAK: a foreign CI project reached the pane"


def test_a_project_whose_sites_are_all_absent_says_so(mod):
    """A member whose sites are simply not in the snapshot must be told, not
    shown an empty chart that reads as 'everything here is fine'."""
    mod.projects.add_project("ghost", name="Ghost", sites=["ghosty"], created_by="rob")
    mod.store.add_user("gus", "operator")
    mod.projects.set_project_role("gus", "ghost", "operator")
    _sc, ctx, clean, _d = _context_for(mod, "gus")
    assert ctx["vz"]["fleet"]["ok"] is False
    out = _render_ctx(clean)
    assert "<svg" not in out.split("Fleet status", 1)[1].split("</section>", 1)[0]
    assert "no data" in out
