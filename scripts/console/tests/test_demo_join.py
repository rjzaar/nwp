"""The Demo pane's JOIN QUEUE and ADD-A-TESTER controls.

Operator ruling 2026-08-15:

    "It is only for those testers listed in the demo tab of nwpconsole. Also
     I'd like to be able to add new testers to the list, ie setting their
     names, etc. If anyone enroles through the join, and admin (me or another
     tester with admin rights) approves those logins then they are added to
     the testers list on nwpconsole."

THE ACCESS MODEL THESE TESTS PIN, in one sentence: approval IS the persistence
decision — an unapproved join never becomes an account, and an approved tester
persists through the nightly reset with their own password.

WHAT THIS MODULE PINS

  * The pending queue is read through `pl demo testers <site> requests --json
    --tier=live` (pl-first — the console never talks drush), parsed by a real
    contract with counts and a malformed-line warning.
  * Approve/reject/add are THREE allowlisted actions building fixed argv. No
    free text ever reaches a command line: the request id, the account name,
    the display name and the bundle are each shape-validated, and an unknown
    bundle is unrepresentable.
  * WHO MAY APPROVE: operator, on both axes. This deliberately reuses the
    console's existing role model rather than inventing a "tester admin"
    permission — "the operator, and testers holding admin rights" is expressed
    by giving that person a console account with the operator role, which is
    the mechanism that already exists (`pl console user add … --role=operator`)
    and is already capped by `effective_project_role`. A second permission
    system for the same question is a second policy that drifts.
  * A viewer gets no controls and is refused server-side.
  * FAIL-CLOSED READS: an unreadable request store renders CANNOT VERIFY, never
    an empty-but-healthy "no one is waiting" queue (ops#281).
  * The approval RESULT carries a password, so the result route is
    non-redactable and the password must never reach the audit log.

RED-THEN-GREEN: run against the tree at b88d025 (before any of this existed)
and observed RED — 21 failures, all "cannot import"/"unknown action". Counts in
the commit message.
"""
import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import parsers  # noqa: E402
from app.actions import ACTIONS, ActionError, build_action  # noqa: E402

DEMO = ["nwd"]

REQUESTS_JSON = {
    "ok": True,
    "store": "/var/lib/nwp-demo/nwd/join-requests.jsonl",
    "state_filter": "pending",
    "counts": {"pending": 2, "approved": 5, "rejected": 1, "total": 8},
    "malformed_lines": 0,
    "requests": [
        {"id": "r-a1b2c3d4e5f6", "ts": 1786249111, "bundle": "tester-member",
         "display_name": "Rob Zaar", "note": "keen to test the courses half",
         "state": "pending", "decided_by": None, "decided_at": None, "account": None},
        {"id": "r-0f0e0d0c0b0a", "ts": 1786249000, "bundle": "tester-content-manager",
         "display_name": "Ann Other", "note": "",
         "state": "pending", "decided_by": None, "decided_at": None, "account": None},
    ],
}

STORE_UNREADABLE_JSON = {
    "ok": False,
    "reason": "the join request store exists but could not be read — CANNOT VERIFY, not empty",
}

NOT_DEPLOYED_JSON = {
    "ok": False,
    "not_deployed": True,
    "reason": "drush command nwc:join-requests is not on nwd live yet — merge + deploy "
              "the nwc profile MR, then refresh",
}

APPROVE_OK = {
    "ok": True, "approved": True, "request_id": "r-a1b2c3d4e5f6",
    "account": "Francis-1234", "display_name": "Rob Zaar", "bundle": "tester-member",
    "password": "ABCD-EFGH-JKLM-NPQR",
    "note": "the password is shown ONCE and is not stored or logged anywhere",
}

APPROVE_REGISTRY_FAILED = {
    "ok": False, "refused": True, "account": "Francis-1234",
    "reason": "the tester registry could not be written — the approval is ABANDONED. "
              "'Francis-1234' was created BLOCKED on nwd and will be wiped by tonight's "
              "reset. Do NOT tell anybody they are approved: nobody has been approved.",
}


# ---------------------------------------------------------------------------
# parsers — pure
# ---------------------------------------------------------------------------
def test_parse_join_requests_ok_shape():
    p = parsers.parse_join_requests_json(json.dumps(REQUESTS_JSON))
    assert p["ok"] is True
    assert p["counts"]["pending"] == 2
    assert [r["id"] for r in p["requests"]] == ["r-a1b2c3d4e5f6", "r-0f0e0d0c0b0a"]
    assert p["requests"][0]["display_name"] == "Rob Zaar"
    assert p["requests"][0]["bundle"] == "tester-member"


def test_an_unreadable_store_is_cannot_verify_not_an_empty_queue():
    """THE ops#281 case. An empty queue and an unreadable one look identical on
    a pane unless the parser keeps them apart — and acting on the wrong one
    means a person who asked to join is never seen."""
    p = parsers.parse_join_requests_json(json.dumps(STORE_UNREADABLE_JSON))
    assert p["ok"] is False
    assert "CANNOT VERIFY" in p["reason"] or "could not be read" in p["reason"]
    assert not p.get("requests"), "an unreadable store must not present a requests list"


def test_garbage_output_is_a_typed_refusal_not_a_crash():
    p = parsers.parse_join_requests_json("Segmentation fault\n")
    assert p["ok"] is False
    assert p["reason"]


def test_not_deployed_is_first_class():
    """Until the nwc profile MR merges and deploys, nwc:join-requests does not
    exist on live. That must render as CANNOT VERIFY with the deploy hint, never
    as a healthy empty queue."""
    p = parsers.parse_join_requests_json(json.dumps(NOT_DEPLOYED_JSON))
    assert p["ok"] is False
    assert p.get("not_deployed") is True
    assert "deploy" in p["reason"]


def test_malformed_lines_are_surfaced_not_swallowed():
    """A line the store could not parse may be somebody's request. The count
    reaches the pane so the operator knows the queue is not the whole truth."""
    raw = dict(REQUESTS_JSON, malformed_lines=3)
    p = parsers.parse_join_requests_json(json.dumps(raw))
    assert p["ok"] is True
    assert p["malformed_lines"] == 3


def test_parse_join_decision_carries_the_refusal_reason_verbatim():
    p = parsers.parse_join_decision_json(json.dumps(APPROVE_REGISTRY_FAILED))
    assert p["ok"] is False
    assert p["refused"] is True
    assert "nobody has been approved" in p["reason"]
    assert "wiped" in p["reason"]


def test_parse_join_decision_ok_carries_the_password_once():
    p = parsers.parse_join_decision_json(json.dumps(APPROVE_OK))
    assert p["ok"] is True
    assert p["account"] == "Francis-1234"
    assert p["password"] == "ABCD-EFGH-JKLM-NPQR"


# ---------------------------------------------------------------------------
# actions — fixed argv, strict validators
# ---------------------------------------------------------------------------
def test_the_three_new_actions_exist_and_are_operator_gated():
    for name in ("demo_join_approve", "demo_join_reject", "demo_tester_add"):
        assert name in ACTIONS, f"{name} is not an allowlisted action"
        spec = ACTIONS[name]
        # BOTH axes. A global operator who is only a project viewer must not
        # be able to approve inside that project.
        assert spec["min_role"] == "operator"
        assert spec["min_project_role"] == "operator"
        assert spec["label"].strip()


def test_approve_builds_the_pl_verb_with_an_explicit_tier():
    argv, _spec = build_action(
        "demo_join_approve", {"site": "nwd", "request_id": "r-a1b2c3d4e5f6"}, DEMO)
    assert argv[:4] == ["demo", "testers", "nwd", "approve"]
    assert "r-a1b2c3d4e5f6" in argv
    assert "--tier=live" in argv
    assert "--json" in argv


def test_reject_builds_its_own_verb_and_cannot_be_confused_with_approve():
    argv, _spec = build_action(
        "demo_join_reject", {"site": "nwd", "request_id": "r-a1b2c3d4e5f6"}, DEMO)
    assert "reject" in argv
    assert "approve" not in argv


@pytest.mark.parametrize("bad", [
    "", "not a request id", "r-abc;rm -rf /", "../../etc/passwd", "-x", "a" * 100,
])
def test_a_bad_request_id_is_refused_by_name_never_passed_through(bad):
    with pytest.raises(ActionError) as e:
        build_action("demo_join_approve", {"site": "nwd", "request_id": bad}, DEMO)
    assert "request" in str(e.value).lower()


def test_add_builds_a_fixed_argv_with_account_display_and_bundle():
    argv, _spec = build_action("demo_tester_add", {
        "site": "nwd", "account": "Francis-1234",
        "display_name": "Rob Zaar", "bundle": "tester-member",
    }, DEMO)
    assert argv[:4] == ["demo", "testers", "nwd", "add"]
    assert "Francis-1234" in argv
    assert "Rob Zaar" in argv
    assert "tester-member" in argv
    assert "--tier=live" in argv


def test_add_carries_the_optional_attributes_when_given():
    argv, _spec = build_action("demo_tester_add", {
        "site": "nwd", "account": "Francis-1234", "display_name": "Rob Zaar",
        "bundle": "tester-member", "guild": "writers", "level": "2", "admin": "1",
    }, DEMO)
    assert "--guild=writers" in argv
    assert "--level=2" in argv
    assert "--admin" in argv


def test_add_omits_the_optionals_entirely_when_blank():
    """An empty guild must not become `--guild=`, which the verb would then
    have to interpret. Absent means absent."""
    argv, _spec = build_action("demo_tester_add", {
        "site": "nwd", "account": "Francis-1234", "display_name": "Rob Zaar",
        "bundle": "tester-member", "guild": "", "level": "", "admin": "",
    }, DEMO)
    assert not [a for a in argv if a.startswith("--guild")]
    assert not [a for a in argv if a.startswith("--level")]
    assert "--admin" not in argv


@pytest.mark.parametrize("bad", ["sitemanager", "administrator", "apply-auto",
                                 "apply-review", "", "tester-member; rm -rf /"])
def test_add_refuses_any_bundle_outside_the_tester_allowlist(bad):
    """`sitemanager` was DECIDED OUT, and the apply bundles mint accounts on
    the real application form, not here. Neither is representable."""
    with pytest.raises(ActionError) as e:
        build_action("demo_tester_add", {
            "site": "nwd", "account": "Francis-1234",
            "display_name": "Rob Zaar", "bundle": bad}, DEMO)
    assert "bundle" in str(e.value).lower()


@pytest.mark.parametrize("bad", ["", "two words are fine but not; this",
                                 "<script>", "a" * 200])
def test_add_refuses_a_bad_display_name_by_name(bad):
    with pytest.raises(ActionError) as e:
        build_action("demo_tester_add", {
            "site": "nwd", "account": "Francis-1234",
            "display_name": bad, "bundle": "tester-member"}, DEMO)
    assert "display name" in str(e.value).lower()


def test_a_display_name_may_contain_ordinary_human_punctuation():
    """The refusals above must not be so broad that a real person cannot be
    named — the negative tests would then be proving nothing useful."""
    for good in ["Rob Zaar", "Máire O'Brien", "Jean-Luc P."]:
        argv, _spec = build_action("demo_tester_add", {
            "site": "nwd", "account": "Francis-1234",
            "display_name": good, "bundle": "tester-member"}, DEMO)
        assert good in argv


def test_none_of_the_new_actions_can_reach_a_site_outside_scope():
    for name, params in (
        ("demo_join_approve", {"request_id": "r-a1b2c3d4e5f6"}),
        ("demo_join_reject", {"request_id": "r-a1b2c3d4e5f6"}),
        ("demo_tester_add", {"account": "Francis-1234", "display_name": "Rob Zaar",
                             "bundle": "tester-member"}),
    ):
        with pytest.raises(ActionError):
            build_action(name, dict(params, site="ss"), DEMO)


def test_allow_real_is_unrepresentable_on_every_new_action():
    """The @demo.invalid fence is the point. No parameter value may produce
    --allow-real on any of these argv."""
    for name, params in (
        ("demo_join_approve", {"site": "nwd", "request_id": "--allow-real"}),
        ("demo_tester_add", {"site": "nwd", "account": "--allow-real",
                             "display_name": "x", "bundle": "tester-member"}),
    ):
        with pytest.raises(ActionError):
            build_action(name, params, DEMO)


# ---------------------------------------------------------------------------
# routes — the enforcement is server-side, not a hidden button
# ---------------------------------------------------------------------------
@pytest.fixture(scope="module")
def mod():
    import os
    import tempfile

    pytest.importorskip("fastapi")
    pytest.importorskip("httpx")
    tmp = tempfile.mkdtemp(prefix="nwp-console-join-test-")
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


def _fake_requests(mod, monkeypatch, payload=None, calls=None):
    payload = REQUESTS_JSON if payload is None else payload

    def fake_cached(root, args, **kw):
        if calls is not None:
            calls.append(list(args))
        return {"rc": 0, "out": json.dumps(payload), "err": "", "secs": 0.1}

    monkeypatch.setattr(mod, "run_pl_cached", fake_cached)
    return payload


def test_a_viewer_CANNOT_approve_a_join_request(mod, monkeypatch):
    """THE authorisation proof. Approving creates an account and decides who
    survives the nightly reset — it is not a read. A viewer is refused by the
    ROUTE, not merely denied a button: a hidden control is not a permission."""
    _fake_requests(mod, monkeypatch)
    r = _client(mod, "vera").post(
        "/actions/demo_join",
        data={"site": "nwd", "op": "approve", "request_id": "r-a1b2c3d4e5f6"},
    )
    assert r.status_code == 403, (
        f"a viewer got {r.status_code} on approve — approval must be operator+")


def test_a_viewer_CANNOT_add_a_tester(mod, monkeypatch):
    _fake_requests(mod, monkeypatch)
    r = _client(mod, "vera").post(
        "/actions/demo_tester_add",
        data={"site": "nwd", "account": "Francis-1234",
              "display_name": "Rob Zaar", "bundle": "tester-member"},
    )
    assert r.status_code == 403


def test_a_viewer_MAY_read_the_queue(mod, monkeypatch):
    """The read is deliberately viewer-visible: seeing who is waiting is not
    the same power as deciding. If this ever 403s, the negative tests above
    stop proving anything about the WRITE specifically."""
    _fake_requests(mod, monkeypatch)
    r = _client(mod, "vera").get("/panes/demo/requests?site=nwd")
    assert r.status_code == 200
    assert "Rob Zaar" in r.text


def test_the_queue_pane_renders_cannot_verify_not_an_empty_table(mod, monkeypatch):
    _fake_requests(mod, monkeypatch, payload=STORE_UNREADABLE_JSON)
    r = _client(mod).get("/panes/demo/requests?site=nwd")
    assert r.status_code == 200
    assert "CANNOT VERIFY" in r.text
    assert "nobody is waiting" not in r.text


def test_the_queue_declares_malformed_lines_on_the_pane(mod, monkeypatch):
    _fake_requests(mod, monkeypatch, payload=dict(REQUESTS_JSON, malformed_lines=2))
    r = _client(mod).get("/panes/demo/requests?site=nwd")
    assert "NOT the whole truth" in r.text


def test_a_site_outside_scope_is_404_not_a_silent_other_site(mod, monkeypatch):
    _fake_requests(mod, monkeypatch)
    r = _client(mod).get("/panes/demo/requests?site=ss")
    assert r.status_code == 404


def test_approve_result_shows_the_password_once_and_says_so(mod, monkeypatch):
    calls = []
    _fake_requests(mod, monkeypatch, calls=calls)
    monkeypatch.setattr(mod, "run_pl", lambda root, args, **kw: {
        "rc": 0, "out": json.dumps(APPROVE_OK), "err": "", "secs": 0.2})
    r = _client(mod).post(
        "/actions/demo_join",
        data={"site": "nwd", "op": "approve", "request_id": "r-a1b2c3d4e5f6"},
    )
    assert r.status_code == 200
    assert "ABCD-EFGH-JKLM-NPQR" in r.text
    assert "shown ONCE" in r.text
    # DISCHARGE: the queue was re-read, cache bypassed.
    assert any("requests" in c for c in calls), "the queue was not re-read after the write"


def test_a_refused_approval_renders_the_reason_VERBATIM(mod, monkeypatch):
    """These reasons are the operationally important ones in the whole feature.
    A summarised 'approval failed' would lose 'do NOT tell anybody they are
    approved', which is the only part that changes what the operator does."""
    _fake_requests(mod, monkeypatch)
    monkeypatch.setattr(mod, "run_pl", lambda root, args, **kw: {
        "rc": 2, "out": json.dumps(APPROVE_REGISTRY_FAILED), "err": "", "secs": 0.2})
    r = _client(mod).post(
        "/actions/demo_join",
        data={"site": "nwd", "op": "approve", "request_id": "r-a1b2c3d4e5f6"},
    )
    assert r.status_code == 200
    assert "nobody has been approved" in r.text
    assert "wiped by tonight" in r.text


def test_the_password_never_reaches_the_audit_log(mod, monkeypatch):
    """A credential in an append-only log is a credential you cannot revoke."""
    _fake_requests(mod, monkeypatch)
    monkeypatch.setattr(mod, "run_pl", lambda root, args, **kw: {
        "rc": 0, "out": json.dumps(APPROVE_OK), "err": "", "secs": 0.2})
    written = []
    real = mod.audit.append
    monkeypatch.setattr(mod.audit, "append",
                        lambda *a, **k: (written.append((a, k)), real(*a, **k))[1])
    _client(mod).post(
        "/actions/demo_join",
        data={"site": "nwd", "op": "approve", "request_id": "r-a1b2c3d4e5f6"},
    )
    assert written, "the approval wrote no audit line at all"
    blob = json.dumps(written, default=str)
    assert "ABCD-EFGH-JKLM-NPQR" not in blob, "the password reached the audit log"


def test_an_unknown_join_op_is_rejected_not_guessed(mod, monkeypatch):
    _fake_requests(mod, monkeypatch)
    r = _client(mod).post(
        "/actions/demo_join",
        data={"site": "nwd", "op": "delete", "request_id": "r-a1b2c3d4e5f6"},
    )
    assert r.status_code == 200
    assert "unknown join op" in r.text
