"""The Demo pane as a tester-management surface — tranche 1 (ops#328).

WHAT THESE TESTS PIN:

  * The pane reads `pl demo codes <site> list --json` (a real contract, not
    the old heuristic table-grep) plus `pl demo seal-status --json`, and
    renders per-state counts, filter chips and a checkbox per code.
  * The GOLDEN INTERACTION is first-class: the seal banner names the capture
    age and says plainly that live changes revert at the nightly reset unless
    a new golden is sealed. An unreachable box renders CANNOT VERIFY — an
    unreadable seal and a fresh seal must never look alike.
  * An unreadable code registry renders CANNOT VERIFY, never an empty table
    (the ops#281 / !394 lesson: unreadable-renders-as-clean).
  * Bulk revoke/purge DISCHARGE (ops#327): the action route executes the pl
    verb and then RE-READS the registry, rendering the re-read state — the
    result of an action is the state it left, not a note about intent.
  * Truncation honesty: filtered views say "showing N of M".
  * Viewers get no checkboxes, no bulk buttons, and a 403 on the POST.

Red-then-green: this module was run against the pre-ops#328 console and
observed RED (parsers/actions missing, route absent, old template) before the
implementation existed.
"""
import json
import os
import sys
import tempfile
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import actions, parsers  # noqa: E402
from app.actions import ActionError, build_action  # noqa: E402

DEMO = ["nwd"]

CODES_JSON = {
    "ok": True, "site": "nwd", "registry": "present",
    "registry_path": "/x/sites/nwd/demo-codes.json",
    "generated_at": "2026-08-09T10:00:00Z",
    "codes": [
        {"id": "c1", "bundle": "tester-member", "state": "live",
         "expires": 1790000000, "expires_iso": "2026-08-20T00:00:00Z",
         "created": 1780000000, "created_iso": "2026-08-01T00:00:00Z",
         "hash_prefix": "aabbccddeeff"},
        {"id": "c2", "bundle": "tester-guild-leader", "state": "live",
         "expires": 1790000000, "expires_iso": "2026-08-20T00:00:00Z",
         "created": 1780000000, "created_iso": "2026-08-01T00:00:00Z",
         "hash_prefix": "bbccddeeff00"},
        {"id": "c3", "bundle": "tester-member", "state": "revoked",
         "expires": 1790000000, "expires_iso": "2026-08-20T00:00:00Z",
         "created": 1780000000, "created_iso": "2026-08-01T00:00:00Z",
         "hash_prefix": "ccddeeff0011"},
        {"id": "c4", "bundle": "tester-member", "state": "expired",
         "expires": 1700000000, "expires_iso": "2026-07-01T00:00:00Z",
         "created": 1690000000, "created_iso": "2026-06-01T00:00:00Z",
         "hash_prefix": "ddeeff001122"},
    ],
    "counts": {"live": 2, "revoked": 1, "expired": 1, "total": 4},
}

SEAL_JSON = {
    "ok": True, "site": "nwd", "tier": "live",
    "sealed_at": "2026-08-09T07:17:31Z", "age_seconds": 7300,
    "last_reset": "2026-08-09T03:17:00Z",
    "source": "box:/var/lib/nwp-demo/nwd/golden",
    "reset_window": "01:00-03:30 Australia/Melbourne nightly (04:00 floor)",
    "warning": "changes made after sealed_at revert at the next reset unless a new golden is sealed",
}


# ---------------------------------------------------------------------------
# parsers — pure, no app needed
# ---------------------------------------------------------------------------
def test_parse_demo_codes_json_ok():
    p = parsers.parse_demo_codes_json(json.dumps(CODES_JSON))
    assert p["ok"] is True
    assert [r["id"] for r in p["codes"]] == ["c1", "c2", "c3", "c4"]
    assert p["counts"] == {"live": 2, "revoked": 1, "expired": 1, "total": 4}


def test_parse_demo_codes_json_unreadable_is_not_empty():
    """ok:false (exit-2 side) must surface as CANNOT VERIFY, never as a clean
    zero-code registry."""
    p = parsers.parse_demo_codes_json(json.dumps(
        {"ok": False, "registry": "unreadable", "reason": "registry exists but could not be parsed"}))
    assert p["ok"] is False
    assert "parsed" in p["reason"]
    p2 = parsers.parse_demo_codes_json("total garbage, no JSON at all")
    assert p2["ok"] is False and p2["reason"]


def test_parse_demo_codes_json_absent_registry_is_ok_and_empty():
    p = parsers.parse_demo_codes_json(json.dumps(
        {"ok": True, "site": "nwd", "registry": "absent", "codes": [],
         "counts": {"live": 0, "revoked": 0, "expired": 0, "total": 0}}))
    assert p["ok"] is True and p["registry"] == "absent" and p["codes"] == []


def test_parse_seal_status_ok_and_age():
    p = parsers.parse_seal_status(json.dumps(SEAL_JSON))
    assert p["ok"] is True
    assert p["sealed_at"] == "2026-08-09T07:17:31Z"
    assert p["age_seconds"] == 7300
    assert p["age_human"]  # non-empty human rendering
    assert "Melbourne" in p["reset_window"]


def test_parse_seal_status_fail_carries_reason():
    p = parsers.parse_seal_status(json.dumps(
        {"ok": False, "site": "nwd", "tier": "live",
         "reason": "cannot reach nwd's live box over ssh"}))
    assert p["ok"] is False and "ssh" in p["reason"]
    assert parsers.parse_seal_status("no json here")["ok"] is False


def test_fmt_age_shapes():
    assert parsers.fmt_age(90) == "1m"
    assert parsers.fmt_age(7300) == "2h 01m"
    assert parsers.fmt_age(200000) == "2d 7h"
    assert parsers.fmt_age(None) == "unknown time"
    assert parsers.fmt_age(-5) == "unknown time"


# ---------------------------------------------------------------------------
# actions — bulk revoke / purge
# ---------------------------------------------------------------------------
def test_bulk_revoke_builds_one_argv_with_every_id():
    argv, spec = build_action("demo_code_revoke",
                              {"site": "nwd", "code_ids": ["c1", "c2", "c9"]}, DEMO)
    assert argv == ["demo", "codes", "nwd", "revoke", "c1", "c2", "c9", "--tier=live"]
    assert spec["min_role"] == "operator"


def test_bulk_revoke_single_string_still_works():
    """The pre-ops#328 form field shape must keep working."""
    argv, _ = build_action("demo_code_revoke", {"site": "nwd", "code_id": "c7"}, DEMO)
    assert argv == ["demo", "codes", "nwd", "revoke", "c7", "--tier=live"]


def test_bulk_one_bad_id_rejects_the_whole_batch():
    for bad in ("a b", "x;y", "$(id)", "", "a" * 41):
        with pytest.raises(ActionError):
            build_action("demo_code_revoke",
                         {"site": "nwd", "code_ids": ["c1", bad, "c2"]}, DEMO)
    with pytest.raises(ActionError):
        build_action("demo_code_revoke", {"site": "nwd", "code_ids": []}, DEMO)


def test_bulk_batch_size_is_bounded():
    ids = [f"c{i}" for i in range(actions.CODE_IDS_MAX + 1)]
    with pytest.raises(ActionError):
        build_action("demo_code_revoke", {"site": "nwd", "code_ids": ids}, DEMO)


def test_purge_maps_to_the_purge_verb():
    argv, spec = build_action("demo_code_purge",
                              {"site": "nwd", "code_ids": ["c3", "c4"]}, DEMO)
    assert argv == ["demo", "codes", "nwd", "purge", "c3", "c4", "--tier=live"]
    assert spec["min_role"] == "operator"
    assert spec["scope"] == "site"


# ---------------------------------------------------------------------------
# routes + rendering
# ---------------------------------------------------------------------------
@pytest.fixture(scope="module")
def mod():
    pytest.importorskip("fastapi")
    pytest.importorskip("httpx")
    tmp = tempfile.mkdtemp(prefix="nwp-console-demo-test-")
    os.environ["NWP_CONSOLE_DATA"] = tmp
    os.environ["NWP_CONSOLE_ROOT"] = tmp
    os.environ["NWP_CONSOLE_QUOKKA_URL"] = "http://127.0.0.1:9"
    os.environ["NWP_CONSOLE_STT_BACKEND"] = "off"
    os.environ["NWP_CONSOLE_TTS_BACKEND"] = "off"
    os.environ["NWP_CONSOLE_DEMO_SITES"] = "nwd"
    for m in list(sys.modules):
        if m == "app" or m.startswith("app."):
            del sys.modules[m]
    from app import main as app_main

    app_main.store.add_user("rob", "owner")
    app_main.store.add_user("vera", "viewer")
    return app_main


def _client(mod, name="rob"):
    from fastapi import Request
    from fastapi.testclient import TestClient

    def _as_header_user(request: Request):
        who = request.headers.get("x-test-user")
        u = mod.store.get_user(who) if who else None
        return None if u is None else {"name": who, "role": u.get("role", "viewer")}

    mod.app.dependency_overrides[mod.current_user] = _as_header_user
    return TestClient(mod.app, headers={"x-test-user": name})


def _fake_demo(mod, monkeypatch, codes=None, seal=None, codes_rc=0, seal_rc=0,
               calls=None):
    """Fake BOTH spawners. Dispatches on the pl argv; records calls when a
    list is passed so discharge tests can assert the re-read happened."""
    codes = CODES_JSON if codes is None else codes
    seal = SEAL_JSON if seal is None else seal

    def fake_cached(root, args, **kw):
        if calls is not None:
            calls.append((list(args), bool(kw.get("force"))))
        a = list(args)
        if a[:2] == ["demo", "status"]:
            return {"rc": 0, "out": "Demo status\n2026-08-09T03:17:00Z reset-ok tier=live\n",
                    "err": "", "secs": 0.1, "cmd": "pl demo status"}
        if a[:2] == ["demo", "codes"] and "--json" in a:
            return {"rc": codes_rc, "out": json.dumps(codes), "err": "", "secs": 0.1,
                    "cmd": "pl demo codes list --json"}
        if a[:2] == ["demo", "seal-status"]:
            return {"rc": seal_rc, "out": json.dumps(seal), "err": "", "secs": 0.1,
                    "cmd": "pl demo seal-status"}
        return {"rc": 1, "out": "", "err": f"unexpected args {a}", "secs": 0, "cmd": ""}

    monkeypatch.setattr(mod, "run_pl_cached", fake_cached)
    return fake_cached


def test_pane_renders_states_counts_and_checkboxes(mod, monkeypatch):
    _fake_demo(mod, monkeypatch)
    r = _client(mod).get("/panes/demo")
    assert r.status_code == 200
    body = r.text
    assert "All (4)" in body and "Live (2)" in body
    assert "Revoked (1)" in body and "Expired (1)" in body
    for cid in ("c1", "c2", "c3", "c4"):
        assert cid in body
    assert 'name="code_ids"' in body                     # operator sees checkboxes
    assert "Revoke selected" in body and "Purge selected" in body
    assert "showing 4 of 4" in body


def test_filter_narrows_rows_and_declares_it(mod, monkeypatch):
    _fake_demo(mod, monkeypatch)
    r = _client(mod).get("/panes/demo?state=live")
    assert r.status_code == 200
    body = r.text
    assert 'value="c1"' in body and 'value="c2"' in body
    assert 'value="c3"' not in body and 'value="c4"' not in body
    # the !394 lesson: a narrowed view must say it is narrowed, with real counts
    assert "showing 2 of 4" in body and "filter: live" in body
    # counts on the chips stay whole-registry
    assert "Revoked (1)" in body


def test_bad_filter_value_falls_back_to_all(mod, monkeypatch):
    _fake_demo(mod, monkeypatch)
    r = _client(mod).get("/panes/demo?state=%3Cscript%3E")
    assert r.status_code == 200
    assert "showing 4 of 4" in r.text


def test_unreadable_registry_is_cannot_verify_not_empty(mod, monkeypatch):
    _fake_demo(mod, monkeypatch,
               codes={"ok": False, "registry": "unreadable",
                      "reason": "registry exists but could not be parsed"},
               codes_rc=2)
    body = _client(mod).get("/panes/demo").text
    assert "CANNOT VERIFY" in body
    assert "no codes in this view" not in body           # unreadable ≠ empty


def test_seal_banner_names_age_and_revert(mod, monkeypatch):
    _fake_demo(mod, monkeypatch)
    body = _client(mod).get("/panes/demo").text
    assert "Golden sealed" in body
    assert "2h 01m" in body                              # 7300 s, humanised
    assert "revert" in body                              # the honest warning
    assert "pl demo golden nwd --tier=live --with-pair" in body


def test_seal_unreachable_is_cannot_verify(mod, monkeypatch):
    _fake_demo(mod, monkeypatch,
               seal={"ok": False, "site": "nwd", "tier": "live",
                     "reason": "cannot reach nwd's live box over ssh"},
               seal_rc=2)
    body = _client(mod).get("/panes/demo").text
    assert "CANNOT VERIFY the staged golden" in body
    assert "Golden sealed" not in body


def test_viewer_sees_no_write_ui(mod, monkeypatch):
    _fake_demo(mod, monkeypatch)
    body = _client(mod, "vera").get("/panes/demo").text
    assert 'name="code_ids"' not in body
    assert "Revoke selected" not in body and "Purge selected" not in body
    # …but still sees the data and the seal banner
    assert "Live (2)" in body and "Golden sealed" in body


def test_viewer_cannot_post_bulk(mod, monkeypatch):
    _fake_demo(mod, monkeypatch)
    r = _client(mod, "vera").post("/actions/demo_codes",
                                  data={"site": "nwd", "op": "revoke", "code_ids": ["c1"]})
    assert r.status_code == 403


def test_bulk_revoke_discharges_by_rereading(mod, monkeypatch):
    """ops#327: the response must carry the RE-READ registry, not just rc=0."""
    calls = []
    after = json.loads(json.dumps(CODES_JSON))
    after["codes"][0]["state"] = "revoked"               # c1 now revoked
    after["counts"] = {"live": 1, "revoked": 2, "expired": 1, "total": 4}
    _fake_demo(mod, monkeypatch, codes=after, calls=calls)

    ran = {}

    def fake_run_pl(root, args, **kw):
        ran["argv"] = list(args)
        return {"rc": 0, "out": "[OK] Revoked 1 code(s): c1", "err": "", "secs": 0.4,
                "cmd": "pl " + " ".join(args)}

    monkeypatch.setattr(mod, "run_pl", fake_run_pl)
    r = _client(mod).post("/actions/demo_codes",
                          data={"site": "nwd", "op": "revoke", "code_ids": ["c1"]})
    assert r.status_code == 200
    assert ran["argv"] == ["demo", "codes", "nwd", "revoke", "c1", "--tier=live"]
    # the registry was RE-READ with force (cache bypassed) after the action…
    reread = [(a, f) for a, f in calls if a[:2] == ["demo", "codes"] and "--json" in a]
    assert reread and reread[-1][1] is True
    # …and the response renders the re-read state, not the pre-action one
    body = r.text
    assert "re-read" in body.lower()
    assert "Revoked (2)" in body and "Live (1)" in body


def test_bulk_purge_runs_the_purge_verb(mod, monkeypatch):
    calls = []
    _fake_demo(mod, monkeypatch, calls=calls)
    ran = {}

    def fake_run_pl(root, args, **kw):
        ran["argv"] = list(args)
        return {"rc": 0, "out": "[OK] Purged 2 code(s)", "err": "", "secs": 0.2, "cmd": ""}

    monkeypatch.setattr(mod, "run_pl", fake_run_pl)
    r = _client(mod).post("/actions/demo_codes",
                          data={"site": "nwd", "op": "purge", "code_ids": ["c3", "c4"]})
    assert r.status_code == 200
    assert ran["argv"] == ["demo", "codes", "nwd", "purge", "c3", "c4", "--tier=live"]


def test_bulk_failure_shows_rc_and_still_rereads(mod, monkeypatch):
    """A refused batch (e.g. a live id in a purge) must show the refusal AND
    the re-read state — the operator needs to see nothing changed."""
    calls = []
    _fake_demo(mod, monkeypatch, calls=calls)

    def fake_run_pl(root, args, **kw):
        return {"rc": 1, "out": "", "err": "REFUSED: 'c1' is a LIVE code", "secs": 0.2, "cmd": ""}

    monkeypatch.setattr(mod, "run_pl", fake_run_pl)
    r = _client(mod).post("/actions/demo_codes",
                          data={"site": "nwd", "op": "purge", "code_ids": ["c1"]})
    assert r.status_code == 200
    assert "LIVE code" in r.text
    reread = [(a, f) for a, f in calls if a[:2] == ["demo", "codes"] and "--json" in a]
    assert reread and reread[-1][1] is True


def test_unknown_bulk_op_is_rejected_without_running_anything(mod, monkeypatch):
    _fake_demo(mod, monkeypatch)

    def boom(root, args, **kw):                          # pragma: no cover
        raise AssertionError("run_pl must not be called for an unknown op")

    monkeypatch.setattr(mod, "run_pl", boom)
    r = _client(mod).post("/actions/demo_codes",
                          data={"site": "nwd", "op": "detonate", "code_ids": ["c1"]})
    assert r.status_code == 200
    assert "unknown bulk op" in r.text.lower()


def test_bad_site_is_rejected_by_the_allowlist(mod, monkeypatch):
    _fake_demo(mod, monkeypatch)

    def boom(root, args, **kw):                          # pragma: no cover
        raise AssertionError("run_pl must not be called for a refused site")

    monkeypatch.setattr(mod, "run_pl", boom)
    r = _client(mod).post("/actions/demo_codes",
                          data={"site": "avc", "op": "revoke", "code_ids": ["c1"]})
    assert r.status_code == 200
    assert "not a demo site" in r.text


def test_select_all_toggle_present_for_operator(mod, monkeypatch):
    """Header carries a select-all checkbox that toggles every code_ids box."""
    _fake_demo(mod, monkeypatch)
    body = _client(mod).get("/panes/demo").text
    assert 'id="demo-select-all"' in body
    # it must drive the row checkboxes, not merely exist
    assert "code_ids" in body and "demo-select-all" in body


def test_select_all_absent_for_viewer(mod, monkeypatch):
    _fake_demo(mod, monkeypatch)
    body = _client(mod, "vera").get("/panes/demo").text
    assert 'id="demo-select-all"' not in body
