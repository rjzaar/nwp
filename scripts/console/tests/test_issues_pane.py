"""The Issues pane must show EVERY tracker, say how much it is not showing,
and be filterable.

THE BUG THESE TESTS PIN (measured 2026-08-02 against the deployed console):

  * `config.OPS_PROJECT` was a single string, so the pane read `nwp/ops` only.
    Tester feedback does not land there — `drush nwc-feedback:sync-to-gitlab`
    files it in `nwp/nwc` (nwc#8 "[feedback-2] help topic should be clickable",
    labels demo-tester/feedback/needs-human/tier-3). The operator's own console
    could not show the operator their testers' reports.
  * `list_issues` asked for ONE page of 40. There were 136 open in nwp/ops. The
    40th-newest was #190; the demo-harvest issue #189 was already off the end,
    with nothing in the UI saying so.
  * The console's walled token returns HTTP 404 for nwp/nwc. 404 rendered as an
    empty list, which is indistinguishable from "no open issues" — so the fix
    is not "show it" but "show it, or say out loud that you cannot".
  * There were no filter controls at all.
"""
import os
import sys
import tempfile
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))


@pytest.fixture(scope="module")
def mod():
    pytest.importorskip("fastapi")
    pytest.importorskip("httpx")
    tmp = tempfile.mkdtemp(prefix="nwp-console-issues-test-")
    os.environ["NWP_CONSOLE_DATA"] = tmp
    os.environ["NWP_CONSOLE_ROOT"] = tmp
    os.environ["NWP_CONSOLE_QUOKKA_URL"] = "http://127.0.0.1:9"
    os.environ["NWP_CONSOLE_STT_BACKEND"] = "off"
    os.environ["NWP_CONSOLE_TTS_BACKEND"] = "off"
    os.environ["NWP_CONSOLE_ISSUE_PROJECTS"] = "nwp/ops,nwp/nwc"
    for m in list(sys.modules):
        if m == "app" or m.startswith("app."):
            del sys.modules[m]
    from app import main as app_main

    app_main.store.add_user("rob", "owner")
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


def _issue(iid, title, labels, project):
    return {"iid": iid, "title": title, "labels": labels,
            "updated_at": "2026-08-01T07:03:27Z",
            "web_url": f"https://git.example.com/{project}/-/issues/{iid}",
            "author": {"username": "group_9_bot"}}


OPS_ROWS = [_issue(193, "Demo harvest — nwd", ["auto-harvest", "demo-tester"], "nwp/ops"),
            _issue(179, "ops thing", ["agent-eligible"], "nwp/ops")]
NWC_ROWS = [_issue(8, "[feedback-2] help topic should be clickable",
                   ["demo-tester", "feedback", "needs-human", "tier-3"], "nwp/nwc")]


# ---------------------------------------------------------------------------
# 1. BOTH trackers are read
# ---------------------------------------------------------------------------
def test_config_reads_more_than_one_tracker(mod):
    assert "nwp/ops" in mod.config.ISSUE_PROJECTS
    assert "nwp/nwc" in mod.config.ISSUE_PROJECTS, (
        "tester feedback lands in nwp/nwc; a console that reads only nwp/ops "
        "hides the queue the demo pilot exists to produce"
    )


def test_pane_renders_feedback_from_the_second_tracker(mod, monkeypatch):
    def fake(project, state="opened", per_page=100, labels="", max_pages=4):
        rows = OPS_ROWS if project == "nwp/ops" else NWC_ROWS
        return {"ok": True, "data": rows, "total": len(rows), "truncated": False}

    monkeypatch.setattr(mod.gitlab, "list_issues", fake)
    body = _client(mod).get("/panes/issues").text
    assert "help topic should be clickable" in body
    assert "nwp/nwc" in body
    assert "needs-human" in body            # the policy label is visible, not just the title


def test_iid_collisions_across_trackers_stay_separate(mod, monkeypatch):
    """ops#8 is not nwc#8. Rows must stay in per-tracker blocks."""
    collide = [_issue(8, "an ops issue that happens to be #8", ["demo-tester"], "nwp/ops")]

    def fake(project, state="opened", per_page=100, labels="", max_pages=4):
        return {"ok": True, "data": collide if project == "nwp/ops" else NWC_ROWS,
                "total": 1, "truncated": False}

    monkeypatch.setattr(mod.gitlab, "list_issues", fake)
    blocks = mod._gather_issues_raw()
    by_project = {b["project"]: [i["title"] for i in b["issues"]] for b in blocks}
    assert by_project["nwp/ops"] == ["an ops issue that happens to be #8"]
    assert by_project["nwp/nwc"] == ["[feedback-2] help topic should be clickable"]


# ---------------------------------------------------------------------------
# 2. An unreadable tracker is NEVER rendered as an empty one
# ---------------------------------------------------------------------------
def test_unreadable_tracker_says_so_instead_of_showing_nothing(mod, monkeypatch):
    """The walled ops_note_token really does 404 on nwp/nwc. That must read as
    'I could not look', never as 'there is nothing there'."""
    def fake(project, state="opened", per_page=100, labels="", max_pages=4):
        if project == "nwp/nwc":
            return {"ok": False, "error": "http-404", "data": [], "total": None, "truncated": False}
        return {"ok": True, "data": OPS_ROWS, "total": 2, "truncated": False}

    monkeypatch.setattr(mod.gitlab, "list_issues", fake)
    body = _client(mod).get("/panes/issues").text
    assert "could not read" in body
    assert "http-404" in body
    assert "No opened issues in nwp/nwc" not in body

    _blocks, summary = mod._gather_issues(mod.scope_mod.fleet_scope("t"))
    assert summary["any_unreadable"] is True
    assert summary["unreadable"] == ["nwp/nwc"]
    assert summary["ok"] is True            # ops still answered; the pane is not dead


def test_tab_count_flags_an_unreadable_tracker(mod, monkeypatch):
    """A smaller number with no warning is the failure mode being closed."""
    def fake(project, state="opened", per_page=100, labels="", max_pages=4):
        if project == "nwp/nwc":
            return {"ok": False, "error": "http-404", "data": [], "total": None, "truncated": False}
        return {"ok": True, "data": OPS_ROWS, "total": 2, "truncated": False}

    monkeypatch.setattr(mod.gitlab, "list_issues", fake)
    body = _client(mod).get("/tabs/counts").text
    assert "alert-dot" in body


# ---------------------------------------------------------------------------
# 3. Truncation is stated, not silent
# ---------------------------------------------------------------------------
def test_pane_states_how_many_it_is_not_showing(mod, monkeypatch):
    def fake(project, state="opened", per_page=100, labels="", max_pages=4):
        if project == "nwp/ops":
            return {"ok": True, "data": OPS_ROWS, "total": 136, "truncated": True}
        return {"ok": True, "data": [], "total": 0, "truncated": False}

    monkeypatch.setattr(mod.gitlab, "list_issues", fake)
    body = _client(mod).get("/panes/issues").text
    assert "of 136" in body
    assert "cut off" in body


def test_list_issues_paginates(monkeypatch):
    """The old body issued one page and returned it as if it were everything."""
    from app.gitlab_api import GitLab

    gl = GitLab("git.example.com", Path("/nonexistent/token"))
    pages = {1: [{"iid": n} for n in range(100)], 2: [{"iid": 100}]}
    seen = []

    def fake_req(method, path, payload=None, project=None):
        page = int(path.split("&page=")[1])
        seen.append(page)
        return {"ok": True, "status": 200, "total": 101, "data": pages.get(page, [])}

    monkeypatch.setattr(gl, "_req", fake_req)
    r = gl.list_issues("nwp/ops")
    assert seen == [1, 2]
    assert len(r["data"]) == 101
    assert r["total"] == 101
    assert r["truncated"] is False


def test_list_issues_reports_when_the_page_budget_runs_out(monkeypatch):
    from app.gitlab_api import GitLab

    gl = GitLab("git.example.com", Path("/nonexistent/token"))

    def fake_req(method, path, payload=None, project=None):
        return {"ok": True, "status": 200, "total": 500, "data": [{"iid": 1}] * 100}

    monkeypatch.setattr(gl, "_req", fake_req)
    r = gl.list_issues("nwp/ops", max_pages=2)
    assert r["truncated"] is True
    assert r["total"] == 500


# ---------------------------------------------------------------------------
# 4. Filterable — by state and by label, AT THE API
# ---------------------------------------------------------------------------
def test_filters_reach_the_api_not_just_the_template(mod, monkeypatch):
    calls = []

    def fake(project, state="opened", per_page=100, labels="", max_pages=4):
        calls.append((project, state, labels))
        return {"ok": True, "data": [], "total": 0, "truncated": False}

    monkeypatch.setattr(mod.gitlab, "list_issues", fake)
    _client(mod).get("/panes/issues?state=all&label=needs-human")
    assert ("nwp/ops", "all", "needs-human") in calls
    assert ("nwp/nwc", "all", "needs-human") in calls


def test_bad_filter_values_fall_back_instead_of_reaching_the_api(mod):
    assert mod._issue_filters("wat", "x") == ("opened", "x")
    assert mod._issue_filters("closed", "a" * 200) == ("closed", "")
    assert mod._issue_filters("all", "bad\nlabel") == ("all", "")


def test_quick_label_chips_include_the_approval_states(mod, monkeypatch):
    monkeypatch.setattr(mod.gitlab, "list_issues",
                        lambda *a, **k: {"ok": True, "data": [], "total": 0, "truncated": False})
    body = _client(mod).get("/panes/issues").text
    for want in ("agent-eligible", "needs-human", "demo-tester"):
        assert f"label={want}" in body


# ---------------------------------------------------------------------------
# 5. The approval workflow's own state is visible
# ---------------------------------------------------------------------------
def test_paused_agent_loop_is_announced(mod, monkeypatch):
    monkeypatch.setattr(mod.gitlab, "list_issues",
                        lambda *a, **k: {"ok": True, "data": [], "total": 0, "truncated": False})
    marker = mod.config.NWP_ROOT / ".loop-paused"
    marker.parent.mkdir(parents=True, exist_ok=True)
    marker.touch()
    try:
        body = _client(mod).get("/panes/issues").text
        assert "paused" in body and "agent-eligible" in body
    finally:
        marker.unlink()
    body = _client(mod).get("/panes/issues").text
    assert "loop-paused" not in body


# ---------------------------------------------------------------------------
# 6. Writes stay walled to the ONE writable tracker
# ---------------------------------------------------------------------------
def test_only_the_write_tracker_offers_act_forms(mod, monkeypatch):
    def fake(project, state="opened", per_page=100, labels="", max_pages=4):
        return {"ok": True, "data": OPS_ROWS if project == "nwp/ops" else NWC_ROWS,
                "total": 2, "truncated": False}

    monkeypatch.setattr(mod.gitlab, "list_issues", fake)
    body = _client(mod).get("/panes/issues").text
    # one act block per ops row, none for the read-only nwc row
    assert body.count("/issues/193/note") == 1
    assert "/issues/8/note" not in body
    assert "read-only here" in body


def test_a_per_tracker_token_file_is_used_when_present(tmp_path):
    from app.gitlab_api import GitLab

    default = tmp_path / "gitlab.token"
    default.write_text("A")
    gl = GitLab("git.example.com", default)
    assert gl.token_file_for("nwp/nwc") == default      # no sibling yet
    sibling = tmp_path / "gitlab.nwc.token"
    sibling.write_text("B")
    assert gl.token_file_for("nwp/nwc") == sibling
    assert gl.token_file_for("nwp/ops") == default
    # traversal in a project slug must not escape the config dir
    assert gl.token_file_for("../../etc/passwd") == default


# ---------------------------------------------------------------------------
# 7. Notifications: a per-tracker high-water mark
# ---------------------------------------------------------------------------
def test_demo_tester_high_water_is_per_tracker():
    from app import notify

    rows = [dict(_issue(193, "ops harvest", ["demo-tester"], "nwp/ops"), _project="nwp/ops"),
            dict(_issue(8, "tester feedback", ["demo-tester"], "nwp/nwc"), _project="nwp/nwc")]
    # Seed each tracker silently on first sight.
    events, state = notify.detect_demo_tester(rows, True, {})
    assert events == []
    assert state["per_project"] == {"nwp/ops": 193, "nwp/nwc": 8}

    # A NEW nwc row at iid 9 must fire even though 9 << 193.
    rows2 = rows + [dict(_issue(9, "another tester report", ["demo-tester"], "nwp/nwc"),
                         _project="nwp/nwc")]
    events, state = notify.detect_demo_tester(rows2, True, state)
    assert [e.dedupe for e in events] == ["issue:nwp/nwc:9"]
    assert "nwc#9" in events[0].title
    assert state["per_project"]["nwp/nwc"] == 9


def test_legacy_notify_state_is_not_reset():
    """An existing notify-state.json holds {"last_iid": N} for untagged rows."""
    from app import notify

    rows = [_issue(8, "old shape", ["demo-tester"], "nwp/ops")]     # no _project
    events, state = notify.detect_demo_tester(rows, True, {"last_iid": 7})
    assert [e.dedupe for e in events] == ["issue:8"]
    assert state["last_iid"] == 8
