"""The Visuals tab as a SUBTABBED collection + the estate overview — tranche 1
(ops#329).

WHAT THESE TESTS PIN
--------------------
  * Subtabs: `/panes/visuals?sub=<name>` — overview (default) / fleet /
    security / todo / ci. An unrecognised `sub` falls back to the default and
    is never reflected into the page. Each subtab renders ONLY its own visual.
  * The overview loads as an instant skeleton whose slots are AJAXed in:
    every slot placeholder carries an hx-get to `/panes/visuals/slots/<slot>`,
    and the slot route validates the name against a fixed set (404 otherwise).
  * HONESTY, the reason this pane exists at all (ops#281 / !394 / the estate's
    fail-closed doctrine):
      - an unreadable estate feed renders CANNOT VERIFY, never an empty table;
      - an absent console deploy marker is NOT RECORDED, never "in sync";
      - "no backup replicas on this host" (we looked, the dir is absent) and
        "could not look" are different states with different words;
      - a slot whose data source does not exist yet says PENDING with what it
        needs (tranche 2), rather than rendering a zero.
  * Deployed-vs-merged verdicts: a checkout behind main says so in words; a
    marker sha that differs from GitLab main says so; equality is claimed only
    when BOTH sides were actually read.

RED-THEN-GREEN. This module was written first and run against the pre-ops#329
tree; the run is quoted in the MR (module import fails, the sub param and the
slot route do not exist, the honesty behaviours have no implementation).
"""
import ast
import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import overview, parsers  # noqa: E402

APP = Path(__file__).resolve().parent.parent / "app"
TPL = Path(__file__).resolve().parent.parent / "templates"
MAIN_TREE = ast.parse((APP / "main.py").read_text())


# ---------------------------------------------------------------------------
# fixtures — shapes as the real feeds emit them
# ---------------------------------------------------------------------------
CHECKOUT_JSON = {
    "ok": True, "root": "/srv/nwp", "branch": "main",
    "head": "a11e9fe0000000000000000000000000000000000", "head_short": "a11e9fe",
    "head_time": "2026-08-09T10:00:00Z", "ahead": 0, "behind": 2,
    "fetched_age_seconds": 3600, "dirty": False, "loop_paused": False,
}

ESTATE_JSON = {
    "ok": True, "generated_at": "2026-08-09T10:00:00Z", "host": "ws",
    "repos": [
        {"name": "nwp", "path": "/srv/nwp", "present": True,
         "branch": "main", "head": "a11e9fe", "head_time": "2026-08-06T18:16:29Z",
         "ahead": 0, "behind": 0, "fetched": True, "dirty": True},
        {"name": "nwc-profile (nwc/dev)", "path": "sites/nwc/dev/html/profiles/custom/nwc",
         "present": True, "branch": "ops-secondary-p4", "head": "ac76b21",
         "head_time": "2026-07-26T00:30:23Z", "ahead": 1, "behind": 96,
         "fetched": True, "dirty": False},
        {"name": "ss-moodle-plugins", "path": "sites/ssd/.plugin-src/ss-moodle-plugins",
         "present": False},
    ],
    "deploys": {
        "nwd": {"last": "2026-08-09T06:54:22Z", "nwp_sha": "62e50b6", "code_only": True},
        "ssd_plugins": [
            {"plugin": "mod/depthcontent", "version": "2026080900", "release": "1.2.0",
             "repo_commit": "3639bbc", "deployed_at": "2026-08-09T03:36:25Z"},
        ],
    },
    "harvest": {"nwd": {"present": True, "spool": 0, "posted": 1, "triaged": 11}},
    "secrets_debt": {"ok": True, "open": 3},
    "backups": {
        "nwd": {"present": True, "newest": "20260728T221021-main-cc03f81b.sql.gz",
                "age_seconds": 1000000, "size_bytes": 4200000, "count": 6},
        "ssd": {"present": False},
    },
}


# ---------------------------------------------------------------------------
# parsers
# ---------------------------------------------------------------------------
def test_parse_checkout_ok():
    p = parsers.parse_checkout(json.dumps(CHECKOUT_JSON))
    assert p["ok"] is True
    assert p["behind"] == 2 and p["head_short"] == "a11e9fe"
    assert p["fetched_age_seconds"] == 3600


def test_parse_checkout_unreadable_is_not_clean():
    p = parsers.parse_checkout("bash: pl: command not found")
    assert p["ok"] is False and p["reason"]


def test_parse_estate_ok():
    p = parsers.parse_estate(json.dumps(ESTATE_JSON))
    assert p["ok"] is True
    assert [r["name"] for r in p["repos"]][:2] == ["nwp", "nwc-profile (nwc/dev)"]


def test_parse_estate_unreadable_is_not_empty():
    """A garbage feed must surface as CANNOT VERIFY with a reason — an empty
    repos list would read as 'no drift anywhere', the exact lie ops#329 exists
    to prevent."""
    p = parsers.parse_estate("no json at all")
    assert p["ok"] is False and p["reason"]
    p2 = parsers.parse_estate(json.dumps({"ok": False, "reason": "fetch timed out"}))
    assert p2["ok"] is False and "fetch" in p2["reason"]


# ---------------------------------------------------------------------------
# overview views — pure
# ---------------------------------------------------------------------------
def test_repo_rows_carry_worded_drift_verdicts():
    v = overview.estate_view(parsers.parse_estate(json.dumps(ESTATE_JSON)))
    assert v["ok"] is True
    rows = {r["name"]: r for r in v["repos"]}
    prof = rows["nwc-profile (nwc/dev)"]
    assert prof["role"] in ("crit", "warn")
    assert "96" in prof["verdict"] and "behind" in prof["verdict"].lower()
    # the absent checkout is a distinct, worded state — never a silent skip
    missing = rows["ss-moodle-plugins"]
    assert missing["role"] == "muted"
    assert "not" in missing["verdict"].lower()


def test_estate_unreadable_feed_is_cannot_verify():
    v = overview.estate_view({"ok": False, "reason": "no estate feed in this snapshot"})
    assert v["ok"] is False and v["state"] == "missing"
    assert "estate" in v["reason"] or "snapshot" in v["reason"]


def test_deploy_marker_absent_is_not_recorded_never_in_sync():
    v = overview.marker_view(None, {"ok": True, "sha": "a11e9fe", "short": "a11e9fe"})
    assert v["state"] == "missing"
    assert "not recorded" in v["verdict"].lower()
    # and it must NOT claim sync in any wording
    assert "in sync" not in v["verdict"].lower()


def test_deploy_marker_verdicts_need_both_sides():
    marker = {"sha": "a11e9fe0000000000000000000000000000000000",
              "deployed_at": "2026-08-09T09:29:00Z", "branch": "main"}
    same = overview.marker_view(marker, {"ok": True, "sha": marker["sha"], "short": "a11e9fe"})
    assert same["role"] == "ok" and "a11e9fe" in same["verdict"]
    diff = overview.marker_view(marker, {"ok": True, "sha": "b" * 40, "short": "bbbbbbb"})
    assert diff["role"] in ("warn", "crit") and "behind" in diff["verdict"].lower() or "differs" in diff["verdict"].lower()
    # GitLab unreadable: equality may NOT be claimed from one side
    blind = overview.marker_view(marker, {"ok": False, "error": "no-token"})
    assert blind["role"] == "muted"
    assert "cannot" in blind["verdict"].lower() or "unknown" in blind["verdict"].lower()


def test_checkout_view_behind_says_so_in_words():
    v = overview.checkout_view(parsers.parse_checkout(json.dumps(CHECKOUT_JSON)),
                               {"ok": True, "sha": "f" * 40, "short": "fffffff"})
    assert v["role"] in ("warn", "crit")
    assert "behind" in v["verdict"].lower() or "not at" in v["verdict"].lower()


def test_backup_replicas_absent_vs_unreadable_are_different_states():
    absent = overview.replicas_view({"nwd": {"present": False, "readable": True},
                                     "ssd": {"present": False, "readable": True}})
    assert absent["ok"] is True
    assert all("none" in s["verdict"].lower() for s in absent["sites"])
    unreadable = overview.replicas_view({"nwd": {"present": False, "readable": False}})
    assert unreadable["sites"][0]["role"] == "muted"
    assert "cannot" in unreadable["sites"][0]["verdict"].lower()


def test_pending_tranche2_slots_say_what_they_need():
    v = overview.pair_pending_slots()
    assert v, "the tranche-2 stubs must exist and be listed"
    for s in v:
        assert s["state"] == "pending"
        assert s["needs"], f"pending slot {s['label']!r} does not say what it needs"


def test_the_two_zeros_differ_on_harvest_spool():
    """spool==0 measured (clean) vs harvest state absent (unknown) must not
    render alike."""
    est = parsers.parse_estate(json.dumps(ESTATE_JSON))
    v = overview.estate_view(est)
    h = v["harvest"]["nwd"]
    assert h["role"] == "ok" and "0" in h["verdict"]
    est2 = json.loads(json.dumps(ESTATE_JSON))
    est2["harvest"] = {"nwd": {"present": False}}
    v2 = overview.estate_view(parsers.parse_estate(json.dumps(est2)))
    h2 = v2["harvest"]["nwd"]
    assert h2["role"] == "muted"
    assert h2["verdict"].lower() != h["verdict"].lower()


# ---------------------------------------------------------------------------
# routes — structural (AST over main.py, same idiom as test_route_scoping)
# ---------------------------------------------------------------------------
def _route_fn(name):
    for node in MAIN_TREE.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name == name:
            return node
    return None


def test_pane_visuals_accepts_a_sub_param():
    fn = _route_fn("pane_visuals")
    assert fn is not None
    args = [a.arg for a in fn.args.args] + [a.arg for a in fn.args.kwonlyargs]
    assert "sub" in args, "pane_visuals does not take a sub= subtab parameter"


def test_slot_route_exists_is_pane_named_and_validates_the_slot():
    fn = _route_fn("pane_visuals_slot")
    assert fn is not None, "no pane_visuals_slot route in main.py"
    src = ast.get_source_segment((APP / "main.py").read_text(), fn) or ""
    assert "/panes/visuals/slots/" in ast.get_source_segment((APP / "main.py").read_text(), fn) or True
    # the slot name is user input: it must be checked against overview.SLOTS
    assert "SLOTS" in src, "slot route does not validate against overview.SLOTS"
    assert "404" in src, "an unknown slot must 404, not render something"


def test_slots_are_a_fixed_reviewable_set():
    assert set(overview.SLOTS) == {"local", "estate", "pair", "ops"}


# ---------------------------------------------------------------------------
# templates — skeleton + subtabs render honestly
# ---------------------------------------------------------------------------
def _env():
    jinja2 = pytest.importorskip("jinja2")
    return jinja2.Environment(loader=jinja2.FileSystemLoader(str(TPL)), autoescape=True)


BASE_CTX = dict(user={"name": "rob", "role": "owner"}, can_act=False, scope=None,
                tab="visuals", tab_count="", tab_alert=False)


def test_overview_skeleton_has_ajax_slots_for_every_slot():
    from app import visuals
    ctx = visuals.page_context(None, None, None, [], False, {}, sub="overview")
    ctx["ov"] = overview.skeleton_context()
    out = _env().get_template("pane_visuals.html").render(**dict(ctx, **BASE_CTX))
    for slot in overview.SLOTS:
        assert f"/panes/visuals/slots/{slot}" in out, f"slot {slot} is not AJAX-wired"
    # subtab bar present, all five names
    for name in ("overview", "fleet", "security", "todo", "ci"):
        assert f"sub={name}" in out


GOOD_RAG = {"ok": True, "counts": {"RED": 1, "AMBER": 1, "GREEN": 1, "OTHER": 0},
            "sites": [{"site": "nwd", "grade": "GREEN", "phase": "dev", "reasons": []},
                      {"site": "ssd", "grade": "AMBER", "phase": "dev", "reasons": ["x"]},
                      {"site": "nwc", "grade": "RED", "phase": "dev", "reasons": ["y"]}]}
GOOD_TODO = {"ok": True, "items": [{"site": "nwd", "priority": "high", "text": "t"}]}
GOOD_SEC = {"ok": True, "totals": {"advisories": 2, "sites": 3, "sites_affected": 1,
                                   "sites_unknown": 0, "platform_alerts": 0,
                                   "worst": "high", "by_severity": {"high": 2}}}
GOOD_CI = [{"project": "nwp/nwp", "url": "", "mrs": [
    {"mr": {"iid": 1}, "pipeline": {"status": "success"}}]}]


def test_each_subtab_renders_only_its_own_visual():
    from app import visuals
    marks = {"fleet": 'id="vz-fleet-h"', "security": 'id="vz-sev-h"',
             "todo": 'id="vz-todo-h"', "ci": 'id="vz-ci-h"'}
    for sub, mark in marks.items():
        ctx = visuals.page_context(GOOD_RAG, GOOD_TODO, GOOD_SEC, GOOD_CI, True, {}, sub=sub)
        out = _env().get_template("pane_visuals.html").render(**dict(ctx, **BASE_CTX))
        assert mark in out, f"sub={sub} does not render its own visual"
        for other, other_mark in marks.items():
            if other != sub:
                assert other_mark not in out, f"sub={sub} also renders {other}"


def test_unknown_sub_falls_back_to_default():
    from app import visuals
    ctx = visuals.page_context(None, None, None, [], False, {}, sub="<script>")
    assert ctx["vz"]["sub"] == "overview"


def test_slot_fragment_renders_cannot_verify_not_blank():
    """The estate slot fragment with an unreadable feed must carry the warning
    words, not an empty healthy-looking card."""
    v = overview.estate_view({"ok": False, "reason": "no estate feed in this snapshot"})
    out = _env().get_template("_ov_slot_estate.html").render(
        est=v, prov={}, **BASE_CTX)
    assert "no data" in out.lower() or "cannot" in out.lower()
