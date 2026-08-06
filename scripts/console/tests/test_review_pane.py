"""The Review pane — the operator's ONE queue (ops#295).

WHAT THESE TESTS PIN:

  * The pane reads `pl decisions --json` and NOTHING else — so the tests fake
    that one boundary (run_pl_cached) and the pane must render decisions with
    their recommendation AND open MRs with a GitLab deep-link.
  * Approve-on-an-MR is a LINK, never a POST: no route on this host may merge
    (ADR-0032 — the console host is AI-reachable; the merge click happens on
    the MR page as the operator themselves).
  * Every write is a note tagged [console-review] SERVER-side — the tag is what
    the next session searches for, so a client that omits it must not matter.
  * An unreadable queue renders CANNOT-VERIFY, and an unreadable MR project
    says its MRs are NOT SHOWN. Empty and unreadable must never look alike —
    the Issues pane learned this the hard way (404 rendered as a clean board).
  * The MR-note write path is bounded by the REVIEW_MR_PROJECTS allowlist; a
    POSTed project name is attacker-chosen until proven otherwise.
"""
import json
import os
import sys
import tempfile
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))


QUEUE = {
    "count": 2,
    "decisions": [
        {"iid": 279, "title": "Practice tick decision", "url": "https://h/nwp/ops/-/issues/279",
         "labels": ["needs-decision"], "complete": True, "gate": "blocks-testers",
         "what": "Decide what a member DOES with Today's practice.",
         "options": ["**A. Self-attested tick.** Cheap.", "**B. Evidenced.** Slow."],
         "recommend": "A, not wired to guild levels.",
         "unblocks": "the practice half of every lesson page", "depends_on": []},
        {"iid": 188, "title": "avc retirement", "url": "https://h/nwp/ops/-/issues/188",
         "labels": ["needs-decision"], "complete": False, "gate": "housekeeping",
         "what": "", "options": [], "recommend": "", "unblocks": "", "depends_on": []},
    ],
    "mrs": {
        "open_total": 1,
        "projects": [
            {"project": "nwp/nwp", "ok": True, "error": "", "items": [
                {"project": "nwp/nwp", "iid": 371, "title": "console: review pane",
                 "url": "https://h/nwp/nwp/-/merge_requests/371", "draft": False,
                 "merge_status": "mergeable", "has_conflicts": False,
                 "source_branch": "feat/console-review-pane", "author": "bot",
                 "updated_at": "2026-08-06T09:00:00Z", "labels": [],
                 "description": "What: the pane.\nWhy: one queue."},
            ]},
            {"project": "nwp/nwc", "ok": False,
             "error": "CANNOT-READ (token walled to another project, or forge unreachable)",
             "items": []},
        ],
    },
}


@pytest.fixture(scope="module")
def mod():
    pytest.importorskip("fastapi")
    pytest.importorskip("httpx")
    tmp = tempfile.mkdtemp(prefix="nwp-console-review-test-")
    os.environ["NWP_CONSOLE_DATA"] = tmp
    os.environ["NWP_CONSOLE_ROOT"] = tmp
    os.environ["NWP_CONSOLE_QUOKKA_URL"] = "http://127.0.0.1:9"
    os.environ["NWP_CONSOLE_STT_BACKEND"] = "off"
    os.environ["NWP_CONSOLE_TTS_BACKEND"] = "off"
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


def _fake_queue(mod, monkeypatch, payload=None, rc=0, err=""):
    def fake(root, args, **kw):
        assert list(args) == ["decisions", "--json"], "the pane must read the ONE source"
        return {"rc": rc, "out": json.dumps(payload) if payload is not None else "",
                "err": err, "secs": 0.1, "cmd": "pl decisions --json"}
    monkeypatch.setattr(mod, "run_pl_cached", fake)


def test_review_is_a_tab(mod):
    assert ("review", "Review") in mod.PANES


def test_pane_renders_decisions_and_mrs(mod, monkeypatch):
    _fake_queue(mod, monkeypatch, QUEUE)
    body = _client(mod).get("/panes/review").text
    # decision, with the parts the operator asked for
    assert "Practice tick decision" in body
    assert "Recommend:" in body and "not wired to guild levels" in body
    assert "Self-attested tick" in body
    # the incomplete decision is listed, not hidden
    assert "avc retirement" in body and "no <code>## Decision</code> block" in body
    # MR with deep-link approve
    assert "console: review pane" in body
    assert "https://h/nwp/nwp/-/merge_requests/371" in body
    assert "Approve on GitLab" in body


def test_no_merge_route_exists(mod):
    """ADR-0032: nothing on this host may merge. If someone adds a merge
    route, this fails and the diff gets the conversation it deserves."""
    for r in mod.app.routes:
        assert "merge" not in getattr(r, "path", ""), r.path


def test_unreadable_mr_project_says_not_shown(mod, monkeypatch):
    _fake_queue(mod, monkeypatch, QUEUE)
    body = _client(mod).get("/panes/review").text
    assert "CANNOT-READ" in body and "not shown" in body


def test_unreadable_queue_is_cannot_verify_not_empty(mod, monkeypatch):
    _fake_queue(mod, monkeypatch, None, rc=1, err="no token")
    body = _client(mod).get("/panes/review").text
    assert "CANNOT-VERIFY" in body
    assert "No decisions are waiting" not in body


def test_viewer_sees_no_write_forms(mod, monkeypatch):
    _fake_queue(mod, monkeypatch, QUEUE)
    body = _client(mod, "vera").get("/panes/review").text
    assert "/review/decision/279/approve" not in body
    assert "/review/mr/note" not in body
    # but the read and the deep-link still work
    assert "Practice tick decision" in body
    assert "https://h/nwp/nwp/-/merge_requests/371" in body


def test_approve_posts_a_tagged_note(mod, monkeypatch):
    seen = {}

    def fake_note(project, iid, body):
        seen.update(project=project, iid=iid, body=body)
        return {"ok": True, "status": 201, "data": {}}

    monkeypatch.setattr(mod.gitlab, "post_note", fake_note)
    r = _client(mod).post("/review/decision/279/approve")
    assert r.status_code == 200
    assert seen["project"] == mod.config.OPS_PROJECT and seen["iid"] == 279
    assert seen["body"].startswith("**[console-review]**")
    assert "APPROVED" in seen["body"]


def test_comment_is_tagged_server_side(mod, monkeypatch):
    seen = {}

    def fake_note(project, iid, body):
        seen.update(body=body)
        return {"ok": True, "status": 201, "data": {}}

    monkeypatch.setattr(mod.gitlab, "post_note", fake_note)
    r = _client(mod).post("/review/decision/279/note", data={"body": "go with B instead"})
    assert r.status_code == 200
    assert seen["body"].startswith("**[console-review]**")
    assert "go with B instead" in seen["body"]


def test_mr_note_is_bounded_by_the_allowlist(mod, monkeypatch):
    called = {}

    def fake_mr_note(project, iid, body):
        called.update(project=project, iid=iid, body=body)
        return {"ok": True, "status": 201, "data": {}}

    monkeypatch.setattr(mod.gitlab, "post_mr_note", fake_mr_note)
    c = _client(mod)
    # not on the allowlist: refused before any network write
    r = c.post("/review/mr/note",
               data={"project": "evil/project", "iid": 1, "body": "x"})
    assert r.status_code == 400
    assert not called
    # allowlisted: goes through, tagged
    r = c.post("/review/mr/note",
               data={"project": "nwp/nwp", "iid": 371, "body": "please rebase"})
    assert r.status_code == 200
    assert called["project"] == "nwp/nwp" and called["iid"] == 371
    assert called["body"].startswith("**[console-review]**")
