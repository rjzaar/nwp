"""Tests for the Gotify notifier.

Nothing here touches the network: `notify._urlopen` is the single seam and every
test replaces it. The two properties that matter most are asserted directly —
**fail-open** (a notification failure can never raise into a caller) and
**dedupe** (a detector speaks only when its input actually changed).
"""
import json
import stat
import sys
from datetime import datetime
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import notify  # noqa: E402
from app.notify import Event, Notifier, NotifyState  # noqa: E402


# ---------------------------------------------------------------------------
# fakes
# ---------------------------------------------------------------------------
class FakeResp:
    def __init__(self, status=200):
        self.status = status

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


@pytest.fixture
def token_file(tmp_path):
    p = tmp_path / "gotify.token"
    p.write_text("AtokenValue123\n")
    return p


@pytest.fixture
def captured(monkeypatch):
    """Capture the request the Notifier would have sent."""
    box = {}

    def fake_urlopen(req, timeout=None):
        box["url"] = req.full_url
        box["method"] = req.get_method()
        box["headers"] = {k.lower(): v for k, v in req.header_items()}
        box["body"] = json.loads(req.data.decode())
        box["timeout"] = timeout
        return FakeResp(200)

    monkeypatch.setattr(notify, "_urlopen", fake_urlopen)
    return box


# ---------------------------------------------------------------------------
# delivery: no-op when unconfigured, fail-open always
# ---------------------------------------------------------------------------
def test_noop_when_no_url(token_file, captured):
    n = Notifier("", token_file)
    assert n.configured() is False
    assert n.send("t", "m") is False
    assert captured == {}, "unconfigured notifier must not touch the network"


def test_noop_when_no_token_file(tmp_path, captured):
    n = Notifier("http://100.64.0.2:8080", tmp_path / "absent.token")
    assert n.configured() is False
    assert n.send("t", "m") is False
    assert captured == {}


def test_noop_when_token_file_empty(tmp_path, captured):
    p = tmp_path / "empty.token"
    p.write_text("   \n")
    assert Notifier("http://x", p).send("t", "m") is False
    assert captured == {}


@pytest.mark.parametrize(
    "boom",
    [OSError("refused"), TimeoutError("slow"), ValueError("garbage"), RuntimeError("surprise")],
)
def test_fail_open_on_any_transport_error(token_file, monkeypatch, boom):
    """The whole point: a dead Gotify must never raise into the caller."""
    def explode(req, timeout=None):
        raise boom

    monkeypatch.setattr(notify, "_urlopen", explode)
    n = Notifier("http://100.64.0.2:8080", token_file)
    assert n.send("t", "m") is False  # returns, does not raise


def test_fail_open_on_non_2xx(token_file, monkeypatch):
    monkeypatch.setattr(notify, "_urlopen", lambda req, timeout=None: FakeResp(500))
    assert Notifier("http://x", token_file).send("t", "m") is False


def test_send_shape_and_header_auth(token_file, captured):
    n = Notifier("http://100.64.0.2:8080/", token_file, timeout=3)
    assert n.send("Title", "Body", 8, "https://console/?tab=fleet") is True
    assert captured["url"] == "http://100.64.0.2:8080/message"
    assert captured["method"] == "POST"
    assert captured["timeout"] == 3
    assert captured["body"]["title"] == "Title"
    assert captured["body"]["message"] == "Body"
    assert captured["body"]["priority"] == 8
    click = captured["body"]["extras"]["client::notification"]["click"]["url"]
    assert click == "https://console/?tab=fleet"
    # Token travels in a header, never in the query string (keeps it out of logs).
    assert captured["headers"]["x-gotify-key"] == "AtokenValue123"
    assert "token" not in captured["url"]


def test_send_truncates_oversized_body(token_file, captured):
    Notifier("http://x", token_file).send("T" * 500, "M" * 9000)
    assert len(captured["body"]["title"]) <= 250
    assert len(captured["body"]["message"]) <= 4000


def test_status_never_leaks_the_token(token_file):
    st = Notifier("http://x", token_file).status()
    assert st["has_token"] is True
    assert "AtokenValue123" not in json.dumps(st)


# ---------------------------------------------------------------------------
# state persistence
# ---------------------------------------------------------------------------
def test_state_roundtrip_and_perms(tmp_path):
    s = NotifyState(tmp_path / "sub" / "notify-state.json")
    assert s.load() == {}  # absent => empty, no crash
    assert s.save({"rag": {"avc": "GREEN"}}) is True
    assert s.load()["rag"] == {"avc": "GREEN"}
    assert stat.S_IMODE(s.path.stat().st_mode) == 0o600


def test_corrupt_state_degrades_to_empty(tmp_path):
    p = tmp_path / "notify-state.json"
    p.write_text("{not json")
    assert NotifyState(p).load() == {}


# ---------------------------------------------------------------------------
# detection: RAG
# ---------------------------------------------------------------------------
def _rag(**sites):
    return {"ok": True, "sites": [{"site": s, "grade": g, "reasons": ["because"]}
                                  for s, g in sites.items()]}


def test_rag_first_run_seeds_silently():
    """A fresh deploy must not fire one push per already-red site."""
    events, state = notify.detect_rag(_rag(avc="RED", ss="GREEN"), None)
    assert events == []
    assert state == {"avc": "RED", "ss": "GREEN"}


def test_rag_fires_on_entering_red():
    events, state = notify.detect_rag(_rag(avc="RED"), {"avc": "GREEN"}, "https://c")
    assert len(events) == 1
    assert events[0].kind == "rag"
    assert "avc" in events[0].title and "RED" in events[0].title
    assert events[0].priority == notify.P_LOUD
    assert events[0].click == "https://c/?tab=fleet"
    assert "because" in events[0].message
    assert state == {"avc": "RED"}


def test_rag_fires_on_recovery_to_green():
    events, _ = notify.detect_rag(_rag(avc="GREEN"), {"avc": "RED"})
    assert len(events) == 1
    assert events[0].priority == notify.P_QUIET
    assert "recovered" in events[0].title


def test_rag_steady_state_is_silent():
    """Dedupe: the same grade on every poll says nothing."""
    prev = {"avc": "RED", "ss": "GREEN"}
    events, state = notify.detect_rag(_rag(avc="RED", ss="GREEN"), prev)
    assert events == []
    assert state == prev


def test_rag_amber_transitions_are_quiet():
    events, _ = notify.detect_rag(_rag(avc="AMBER"), {"avc": "GREEN"})
    assert events == []  # only red-entry and green-recovery are worth a buzz


def test_rag_unparseable_keeps_state_and_says_nothing():
    prev = {"avc": "GREEN"}
    events, state = notify.detect_rag({"ok": False, "error": "boom"}, prev)
    assert events == []
    assert state == prev, "a broken feed must not wipe the high-water mark"


# ---------------------------------------------------------------------------
# detection: demo-tester issues
# ---------------------------------------------------------------------------
def _issue(iid, labels=("demo-tester",), title="broke"):
    return {"iid": iid, "title": title, "labels": list(labels),
            "author": {"username": "tester"}, "web_url": f"https://gl/-/issues/{iid}"}


def test_issues_first_run_seeds_silently():
    events, state = notify.detect_demo_tester([_issue(7)], True, None)
    assert events == []
    assert state == {"last_iid": 7}


def test_issues_fires_only_for_new_iids():
    events, state = notify.detect_demo_tester(
        [_issue(7), _issue(8), _issue(9)], True, {"last_iid": 7})
    assert [e.dedupe for e in events] == ["issue:8", "issue:9"]
    assert state == {"last_iid": 9}
    assert events[0].click == "https://gl/-/issues/8"


def test_issues_ignores_unlabelled():
    events, state = notify.detect_demo_tester(
        [_issue(8, labels=("bug",))], True, {"last_iid": 7})
    assert events == []
    assert state == {"last_iid": 7}


def test_issues_api_down_preserves_high_water_mark():
    prev = {"last_iid": 7}
    events, state = notify.detect_demo_tester([], False, prev)
    assert events == []
    assert state == prev, "an API outage must not reset the mark and re-notify later"


def test_issues_edit_to_seen_issue_stays_quiet():
    events, _ = notify.detect_demo_tester([_issue(7, title="edited")], True, {"last_iid": 7})
    assert events == []


# ---------------------------------------------------------------------------
# detection: demo reset
# ---------------------------------------------------------------------------
def test_demo_reset_ok_is_silent():
    events, state = notify.detect_demo_reset(
        [{"site": "nwd", "last_event": "reset-ok"}], {"nwd": "skip-floor"})
    assert events == []
    assert state == {"nwd": "reset-ok"}


def test_demo_reset_failure_fires():
    events, _ = notify.detect_demo_reset(
        [{"site": "nwd", "last_event": "reset-failed"}], {"nwd": "reset-ok"}, "https://c")
    assert len(events) == 1
    assert events[0].priority == notify.P_HIGH
    assert events[0].click == "https://c/?tab=demo"


def test_demo_skip_floor_fires_at_lower_priority():
    events, _ = notify.detect_demo_reset(
        [{"site": "nwd", "last_event": "skip-floor"}], {"nwd": "reset-ok"})
    assert len(events) == 1
    assert events[0].priority == notify.P_NORMAL
    assert "04:00" in events[0].title


def test_demo_repeated_failure_is_deduped():
    """Dedupe: a stuck failure buzzes once, not every five minutes."""
    events, _ = notify.detect_demo_reset(
        [{"site": "nwd", "last_event": "reset-failed"}], {"nwd": "reset-failed"})
    assert events == []


def test_demo_first_run_seeds_silently():
    events, state = notify.detect_demo_reset([{"site": "nwd", "last_event": "reset-failed"}], None)
    assert events == []
    assert state == {"nwd": "reset-failed"}


# ---------------------------------------------------------------------------
# detection: token expiry
# ---------------------------------------------------------------------------
def _todo(*items):
    return {"ok": True, "items": list(items)}


TOK_DEAD = {"check": "nwp-api", "priority": "high",
            "text": "Token DEAD (revoked/invalid): nwp-api", "action": "pl secrets steps nwp-api"}
TOK_SOON = {"check": "ops-note", "priority": "medium",
            "text": "Token expiring soon: ops-note (live expiry 2026-08-01)", "action": ""}
NOT_TOK = {"check": "backup-sweep", "priority": "high", "text": "Backup sweep is stale", "action": ""}


def test_token_first_run_seeds_silently():
    events, state = notify.detect_token_expiry(_todo(TOK_DEAD), None)
    assert events == []
    assert state == {"notified": ["nwp-api"]}


def test_token_new_item_fires_once():
    events, state = notify.detect_token_expiry(_todo(TOK_DEAD, TOK_SOON), {"notified": ["nwp-api"]})
    assert [e.dedupe for e in events] == ["token:ops-note"]
    assert state == {"notified": ["nwp-api", "ops-note"]}
    # Second pass with identical input says nothing.
    again, _ = notify.detect_token_expiry(_todo(TOK_DEAD, TOK_SOON), state)
    assert again == []


def test_token_ignores_non_token_todo_items():
    events, state = notify.detect_token_expiry(_todo(NOT_TOK), {"notified": []})
    assert events == []
    assert state == {"notified": []}


def test_token_refires_after_being_fixed_then_breaking_again():
    _, cleared = notify.detect_token_expiry(_todo(), {"notified": ["nwp-api"]})
    assert cleared == {"notified": []}
    events, _ = notify.detect_token_expiry(_todo(TOK_DEAD), cleared)
    assert len(events) == 1, "a token that breaks again must be reported again"


def test_token_dead_is_louder_than_expiring():
    dead, _ = notify.detect_token_expiry(_todo(TOK_DEAD), {"notified": []})
    soon, _ = notify.detect_token_expiry(_todo(TOK_SOON), {"notified": []})
    assert dead[0].priority > soon[0].priority


# ---------------------------------------------------------------------------
# detection: CI
# ---------------------------------------------------------------------------
def _ci(status, pipe_id=100, iid=5):
    return [{"project": "nwp/nwp", "mrs": [
        {"mr": {"iid": iid, "title": "a change", "web_url": "https://gl/mr/5"},
         "pipeline": {"id": pipe_id, "status": status, "web_url": "https://gl/p/1"}}]}]


def test_ci_first_run_seeds_silently():
    events, state = notify.detect_ci(_ci("failed"), True, None)
    assert events == []
    assert state == {"nwp/nwp!5": "100:failed"}


def test_ci_failure_fires():
    events, _ = notify.detect_ci(_ci("failed"), True, {"nwp/nwp!5": "100:running"})
    assert len(events) == 1
    assert events[0].kind == "ci"
    assert events[0].click == "https://gl/p/1"


def test_ci_success_is_silent():
    events, _ = notify.detect_ci(_ci("success"), True, {"nwp/nwp!5": "100:running"})
    assert events == []


def test_ci_same_failure_is_deduped():
    events, _ = notify.detect_ci(_ci("failed"), True, {"nwp/nwp!5": "100:failed"})
    assert events == []


def test_ci_new_pipeline_failing_again_fires():
    events, _ = notify.detect_ci(_ci("failed", pipe_id=101), True, {"nwp/nwp!5": "100:failed"})
    assert len(events) == 1, "a retry that fails again is news"


def test_ci_api_down_preserves_state():
    prev = {"nwp/nwp!5": "100:failed"}
    events, state = notify.detect_ci([], False, prev)
    assert events == [] and state == prev


# ---------------------------------------------------------------------------
# morning brief scheduling
# ---------------------------------------------------------------------------
def test_brief_not_due_before_the_hour():
    assert notify.due_for_brief({}, "07:30", datetime(2026, 7, 25, 7, 0)) is False


def test_brief_due_after_the_hour():
    assert notify.due_for_brief({}, "07:30", datetime(2026, 7, 25, 7, 30)) is True
    assert notify.due_for_brief({}, "07:30", datetime(2026, 7, 25, 9, 0)) is True


def test_brief_only_once_per_day():
    prev = {"last": "2026-07-25"}
    assert notify.due_for_brief(prev, "07:30", datetime(2026, 7, 25, 9, 0)) is False
    assert notify.due_for_brief(prev, "07:30", datetime(2026, 7, 26, 8, 0)) is True


def test_brief_off_when_unset_or_malformed():
    assert notify.due_for_brief({}, "", datetime(2026, 7, 25, 9, 0)) is False
    assert notify.due_for_brief({}, "not-a-time", datetime(2026, 7, 25, 9, 0)) is False


# ---------------------------------------------------------------------------
# orchestration
# ---------------------------------------------------------------------------
def _gathered():
    return {
        "rag": _rag(avc="RED"),
        "issues": [_issue(9)], "issues_ok": True,
        "demo": [{"site": "nwd", "last_event": "reset-failed"}],
        "todo": _todo(TOK_DEAD),
        "ci": _ci("failed"), "ci_ok": True,
    }


def test_run_checks_fires_every_kind_once_seeded():
    seeded = {"rag": {"avc": "GREEN"}, "demo_tester": {"last_iid": 8},
              "demo_reset": {"nwd": "reset-ok"}, "token_expiry": {"notified": []},
              "ci": {"nwp/nwp!5": "100:running"}}
    events, state = notify.run_checks(_gathered(), seeded, "https://c")
    assert {e.kind for e in events} == {"rag", "demo_tester", "demo_reset", "token_expiry", "ci"}
    assert state["rag"] == {"avc": "RED"}


def test_run_checks_honours_the_enabled_set():
    seeded = {"rag": {"avc": "GREEN"}, "demo_tester": {"last_iid": 8},
              "demo_reset": {"nwd": "reset-ok"}, "token_expiry": {"notified": []},
              "ci": {"nwp/nwp!5": "100:running"}}
    events, state = notify.run_checks(_gathered(), seeded, "", enabled={"rag"})
    assert {e.kind for e in events} == {"rag"}
    assert state["demo_reset"] == {"nwd": "reset-ok"}, "disabled detectors leave state untouched"


def test_run_checks_empty_enabled_set_is_silent():
    events, _ = notify.run_checks(_gathered(), {}, "", enabled=set())
    assert events == []


def test_run_checks_isolates_a_broken_feed(monkeypatch):
    """One exploding detector must not suppress the others."""
    def explode(*a, **k):
        raise RuntimeError("bad feed")

    monkeypatch.setattr(notify, "detect_rag", explode)
    seeded = {"demo_reset": {"nwd": "reset-ok"}}
    events, state = notify.run_checks(_gathered(), seeded, "")
    assert any(e.kind == "demo_reset" for e in events)
    assert "rag" not in state


def test_run_checks_first_run_is_entirely_silent():
    events, state = notify.run_checks(_gathered(), {}, "")
    assert events == []
    assert set(state) == {"rag", "demo_tester", "demo_reset", "token_expiry", "ci"}


def test_run_checks_is_idempotent_across_restarts():
    """The persisted state is the whole restart story: pass 2 says nothing."""
    _, state = notify.run_checks(_gathered(), {}, "")
    events, state2 = notify.run_checks(_gathered(), state, "")
    assert events == []
    assert state2 == state


# ---------------------------------------------------------------------------
# delivery bookkeeping
# ---------------------------------------------------------------------------
def test_deliver_stamps_last_sent_and_counts(token_file, captured):
    n = Notifier("http://x", token_file)
    state = {}
    sent, failed = notify.deliver(n, [Event("rag", "t", "m"), Event("ci", "t2", "m2")], state)
    assert (sent, failed) == (2, 0)
    assert set(state["last_sent"]) == {"rag", "ci"}


def test_deliver_counts_failures_without_raising(token_file, monkeypatch):
    monkeypatch.setattr(notify, "_urlopen", lambda req, timeout=None: FakeResp(503))
    state = {}
    sent, failed = notify.deliver(Notifier("http://x", token_file), [Event("rag", "t", "m")], state)
    assert (sent, failed) == (0, 1)
    assert state["last_sent"] == {}, "a failed push must not claim a last-sent time"


def test_event_detail_carries_no_body():
    d = Event("rag", "Title", "secret body text", 8, "https://c").as_detail()
    assert "secret body text" not in json.dumps(d)
    assert d["kind"] == "rag" and d["priority"] == 8
