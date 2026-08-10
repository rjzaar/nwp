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
         "what": "", "options": [], "recommend": "", "unblocks": "", "depends_on": [],
         "possibly_stale": True,
         "stale_hint": "Triage: ALREADY DONE (bucket C). Recommend close."},
    ],
    "outside_queue": {"label": "decision::wanted", "count": 48},
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


def test_approve_discharges_the_decision_labels(mod, monkeypatch):
    """ops#327: an approval that leaves `needs-decision` / `decision::wanted`
    on the issue is an undischarged instruction — the queue keeps showing it
    and the operator re-approves (#139 was approved FOUR times). Approve must
    drop both labels in the same action and then RE-READ the issue, so what
    renders is the tracker's state, not the console's hope."""
    seen = {}
    monkeypatch.setattr(mod.gitlab, "post_note",
                        lambda p, i, b: {"ok": True, "status": 201, "data": {}})

    def fake_remove(project, iid, label):
        seen.update(project=project, iid=iid, label=label)
        return {"ok": True, "status": 200, "data": {"labels": ["console"]}}

    def fake_get(project, iid):
        seen["reread"] = True
        return {"ok": True, "status": 200, "data": {"labels": ["console"]}}

    monkeypatch.setattr(mod.gitlab, "remove_label", fake_remove)
    monkeypatch.setattr(mod.gitlab, "get_issue", fake_get)
    r = _client(mod).post("/review/decision/279/approve")
    assert r.status_code == 200
    assert seen["project"] == mod.config.OPS_PROJECT and seen["iid"] == 279
    assert "needs-decision" in seen["label"] and "decision::wanted" in seen["label"]
    assert seen.get("reread") is True, "must re-read the issue, not trust the PUT"
    assert "discharged" in r.text
    assert "NOT DISCHARGED" not in r.text


def test_approve_that_cannot_discharge_is_loud(mod, monkeypatch):
    """The label mutation failing (403, network, walled token) must NOT look
    discharged — a quiet half-success recreates the exact re-approval loop."""
    monkeypatch.setattr(mod.gitlab, "post_note",
                        lambda p, i, b: {"ok": True, "status": 201, "data": {}})
    monkeypatch.setattr(mod.gitlab, "remove_label",
                        lambda p, i, l: {"ok": False, "error": "http-403",
                                         "detail": "insufficient scope"})
    r = _client(mod).post("/review/decision/279/approve")
    assert r.status_code == 200
    assert "NOT DISCHARGED" in r.text
    assert "http-403" in r.text
    # and it must point at the recovery path
    assert "sweep-approved" in r.text


def test_approve_reread_showing_labels_is_not_discharged(mod, monkeypatch):
    """A PUT that claims ok while the tracker still shows the labels is a lie
    the re-read catches; render the re-read, loudly."""
    monkeypatch.setattr(mod.gitlab, "post_note",
                        lambda p, i, b: {"ok": True, "status": 201, "data": {}})
    monkeypatch.setattr(mod.gitlab, "remove_label",
                        lambda p, i, l: {"ok": True, "status": 200, "data": {}})
    monkeypatch.setattr(mod.gitlab, "get_issue",
                        lambda p, i: {"ok": True, "status": 200,
                                      "data": {"labels": ["needs-decision"]}})
    r = _client(mod).post("/review/decision/279/approve")
    assert "NOT DISCHARGED" in r.text
    assert "needs-decision" in r.text


def test_approve_unverifiable_reread_is_not_discharged(mod, monkeypatch):
    """Labels removed but the verifying re-read failed => CANNOT VERIFY, which
    must render as not-discharged, never as success."""
    monkeypatch.setattr(mod.gitlab, "post_note",
                        lambda p, i, b: {"ok": True, "status": 201, "data": {}})
    monkeypatch.setattr(mod.gitlab, "remove_label",
                        lambda p, i, l: {"ok": True, "status": 200, "data": {}})
    monkeypatch.setattr(mod.gitlab, "get_issue",
                        lambda p, i: {"ok": False, "error": "timeout"})
    r = _client(mod).post("/review/decision/279/approve")
    assert "NOT DISCHARGED" in r.text


def test_failed_approval_note_never_touches_labels(mod, monkeypatch):
    """No note, no discharge: the note IS the instruction; labels must not be
    dropped for an approval that was never recorded."""
    called = {}
    monkeypatch.setattr(mod.gitlab, "post_note",
                        lambda p, i, b: {"ok": False, "error": "no-token"})
    monkeypatch.setattr(mod.gitlab, "remove_label",
                        lambda p, i, l: called.update(hit=True) or {"ok": True})
    r = _client(mod).post("/review/decision/279/approve")
    assert r.status_code == 200
    assert not called, "labels were mutated for an approval that failed to record"
    assert "failed" in r.text


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


def test_stale_decision_is_flagged_not_hidden(mod, monkeypatch):
    """The ops#143 lesson: a ## Decision block can outlive its answer. The pane
    flags it and still renders the issue — a flag to read, never a hide."""
    _fake_queue(mod, monkeypatch, QUEUE)
    body = _client(mod).get("/panes/review").text
    assert "possibly already resolved" in body
    assert "ALREADY DONE" in body
    assert "avc retirement" in body  # still rendered in full


def test_outside_queue_backlog_is_declared(mod, monkeypatch):
    """~50 decision::wanted issues were invisible to the queue — hiding their
    existence made '5 decisions waiting' read as the whole decision surface."""
    _fake_queue(mod, monkeypatch, QUEUE)
    body = _client(mod).get("/panes/review").text
    assert "decision::wanted" in body
    assert "48" in body


# ── RED / AMBER decision tiers (nwp/ops#279) ─────────────────────────────────
#
# Operator: "add to the review a red and amber. Red means decision needed, amber
# decision wanted. Red is always first. The ambers should be in an appropriate
# sequence."
#
# These render the TEMPLATE directly rather than the whole app, because the two
# bugs worth catching here are both template-level:
#   * `outside_queue.items` resolved to dict.items (the METHOD) and blew up on
#     |length — which is why the JSON key is `issues`, not `items`;
#   * the amber tier rendering as EMPTY when it was merely unreadable.

def _render_review(**over):
    from jinja2 import Environment, FileSystemLoader
    import pathlib
    tdir = pathlib.Path(__file__).resolve().parents[1] / "templates"
    env = Environment(loader=FileSystemLoader(str(tdir)))
    ctx = dict(q={"ok": True}, decisions=[], mrs={"projects": [], "open_total": 0},
               gates={}, can_act=False, gitlab_ok=True,
               write_project="nwp/ops", mr_note_projects=[], outside_queue={})
    ctx.update(over)
    return env.get_template("pane_review.html").render(**ctx)


def _amber(**over):
    oq = {"label": "decision::wanted", "count": 2, "attempted": True, "readable": True,
          "issues": [
              {"iid": 81, "title": "Erasure channel", "url": "u", "bucket": "go-live",
               "why": "labelled go-live-prereq", "what": "", "labels": []},
              {"iid": 97, "title": "Leakage gate", "url": "u", "bucket": "security",
               "why": "labelled security", "what": "", "labels": []},
          ]}
    oq.update(over)
    return oq


def test_red_tier_is_labelled_and_precedes_amber():
    h = _render_review(outside_queue=_amber())
    assert "RED — decision needed" in h
    assert "AMBER — decision wanted" in h
    assert h.index("RED — decision needed") < h.index("AMBER — decision wanted")


def test_amber_issues_render_in_bucket_order():
    h = _render_review(outside_queue=_amber())
    assert "#81" in h and "#97" in h
    # go-live before security — the sequence the renderer assigned must survive.
    assert h.index("Go Live") < h.index("Security")


def test_amber_order_declares_that_it_is_partly_inferred():
    # A sequence that looks authoritative but is guessed is worse than one that
    # admits it: the operator must know whether to trust it or re-check.
    assert "partly inferred" in _render_review(outside_queue=_amber())


def test_unreadable_amber_never_renders_as_empty():
    h = _render_review(outside_queue={"attempted": True, "readable": False,
                                      "issues": [], "count": None})
    assert "CANNOT-VERIFY" in h
    assert "empty backlog" in h


def test_not_attempted_falls_back_to_the_count_footer():
    h = _render_review(outside_queue={"attempted": False, "readable": False,
                                      "issues": [], "count": 55})
    assert "Beyond this queue" in h and "55" in h
    # Must NOT shout cannot-verify at an operator whose fetch was simply not run.
    assert "empty backlog" not in h


def test_amber_key_is_issues_not_items():
    """`items` collides with dict.items in Jinja — the bug this rename fixed."""
    h = _render_review(outside_queue=_amber())
    assert "#81" in h        # would raise TypeError on |length if it regressed


# ── colours EVIDENT per item (nwp/ops#292) ───────────────────────────────────
#
# Operator: "I want to be able to see all ambers in my decision list with the
# colors evident." Section headers carried the colour; the ITEMS did not, so a
# scrolled list read as an undifferentiated wall. Each row now carries its own
# tier marker — and, per the estate's CVD discipline (_visual_fleet.html: "the
# colour alone carries nothing" for a protan reader), the marker is a WORD in a
# coloured chip plus a coloured border, never colour alone.

RED_DECISIONS = [
    {"iid": 279, "title": "Practice tick decision", "url": "u",
     "labels": ["needs-decision"], "complete": True, "gate": "blocks-testers",
     "what": "w", "options": [], "recommend": "", "unblocks": "", "depends_on": [],
     "possibly_stale": False},
    {"iid": 143, "title": "Second red", "url": "u",
     "labels": ["needs-decision"], "complete": False, "gate": "housekeeping",
     "what": "", "options": [], "recommend": "", "unblocks": "", "depends_on": [],
     "possibly_stale": False},
]


def test_every_red_item_carries_the_red_marker():
    h = _render_review(decisions=RED_DECISIONS, outside_queue=_amber())
    # one coloured card border + one worded chip PER red item, not per section
    assert h.count("rev-card rev-red") == 2
    assert h.count('rag-chip-red">RED<') == 2


def test_every_amber_row_carries_the_amber_marker_and_gate():
    h = _render_review(outside_queue=_amber())
    # each row: amber-bordered row class + worded AMBER chip + its gate/bucket chip
    assert h.count("rev-amber-row") >= 2
    assert h.count('rag-chip-amber">AMBER<') == 2
    assert 'amber-gate-chip">go-live<' in h
    assert 'amber-gate-chip">security<' in h


def test_amber_with_declared_gate_shows_the_declared_gate():
    oq = _amber()
    oq["issues"][0].update(bucket="declared", gate="blocks-prod",
                           why="declares its own Gate")
    h = _render_review(outside_queue=oq)
    assert 'amber-gate-chip">blocks-prod<' in h


def test_partial_amber_fetch_is_declared_never_silent():
    """32 fetched of 150 existing must say so — a truncated tier rendering as
    the whole tier is the unreadable-renders-as-clean failure again."""
    h = _render_review(outside_queue=_amber(count=150))
    assert "PARTIAL" in h
    assert "2 of 150" in h


def test_complete_amber_fetch_shows_no_partial_warning():
    h = _render_review(outside_queue=_amber(count=2))
    assert "PARTIAL" not in h
