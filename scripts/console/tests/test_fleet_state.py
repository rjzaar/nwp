"""fleet_state — published-snapshot consumption, freshness and provenance.

The behaviour these lock down is the reason the module exists:
  * the console prefers PUBLISHED fleet state over its own (site-less) `pl`;
  * a stale snapshot is never presented as current;
  * a stale snapshot is still better than an empty local answer, and the UI
    says which one you are looking at either way.
"""
import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import fleet_state  # noqa: E402

NOW = datetime(2026, 7, 26, 12, 0, 0, tzinfo=timezone.utc)

RAG_DATA = {
    "generated": None,
    "summary": {"RED": 2, "AMBER": 0, "GREEN": 1},
    "sites": [
        {"site": "avc", "rag": "RED", "phase": "(dev)", "security": 13},
        {"site": "nwc", "rag": "RED", "phase": "(dev)", "security": 3},
        {"site": "nwd", "rag": "GREEN", "phase": "(live)", "security": 0},
    ],
}
TODO_DATA = {
    "timestamp": "2026-07-26T11:00:00Z",
    "summary": {"total": 2, "high": 0, "medium": 2, "low": 0},
    "items": [
        {"id": "BAK-avc", "category": "BAK", "priority": "medium",
         "title": "Backup is 14 days old", "site": "avc", "action": "pl backup avc"},
        {"id": "BAK-mt", "category": "BAK", "priority": "medium",
         "title": "Backup is 14 days old", "site": "mt", "action": "pl backup mt"},
    ],
}


def snapshot(age_minutes=10, host="workstation", feeds=None):
    when = NOW - timedelta(minutes=age_minutes)
    return {
        "schema": "nwp.fleet-state",
        "schema_version": 1,
        "generated_at": when.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "generated_by": {"host": host, "user": "rob", "root": "$HOME/nwp", "pl_version": "0.30.0"},
        "max_age_hint_seconds": 7200,
        "summary": {"RED": 2, "AMBER": 0, "GREEN": 1, "sites": 3},
        "feeds": {
            "rag": {"ok": True, "rc": 3, "secs": 0.4, "cmd": "pl rag --json --no-todo", "data": RAG_DATA},
            "todo": {"ok": True, "rc": 0, "secs": 30.5, "cmd": "pl todo check --json", "data": TODO_DATA},
        } if feeds is None else feeds,
    }


def write(tmp_path, obj, name="fleet-state.json"):
    p = tmp_path / name
    p.write_text(json.dumps(obj) if not isinstance(obj, str) else obj)
    return p


# ---------------------------------------------------------------------------
# loading
# ---------------------------------------------------------------------------
def test_load_roundtrip(tmp_path):
    p = write(tmp_path, snapshot())
    snap = fleet_state.load(p)
    assert snap is not None
    assert fleet_state.source_host(snap) == "workstation"


def test_load_missing_file_is_none(tmp_path):
    assert fleet_state.load(tmp_path / "nope.json") is None


def test_load_corrupt_json_is_none(tmp_path):
    assert fleet_state.load(write(tmp_path, "{not json")) is None


def test_load_rejects_foreign_schema(tmp_path):
    bad = snapshot()
    bad["schema"] = "something.else"
    assert fleet_state.load(write(tmp_path, bad)) is None


def test_load_rejects_unknown_schema_version(tmp_path):
    """Refuse rather than mis-render a future shape."""
    future = snapshot()
    future["schema_version"] = 99
    assert fleet_state.load(write(tmp_path, future)) is None


# ---------------------------------------------------------------------------
# age
# ---------------------------------------------------------------------------
def test_age_seconds():
    assert fleet_state.age_seconds(snapshot(age_minutes=14), NOW) == 14 * 60


def test_age_of_future_snapshot_clamps_to_zero():
    """Clock skew must not make a brand-new snapshot look ancient."""
    assert fleet_state.age_seconds(snapshot(age_minutes=-30), NOW) == 0


def test_age_unparseable_is_none():
    assert fleet_state.age_seconds({"generated_at": "yesterday"}, NOW) is None


def test_fmt_age():
    assert fleet_state.fmt_age(5) == "just now"
    assert fleet_state.fmt_age(14 * 60) == "14 min"
    assert fleet_state.fmt_age(2 * 3600) == "2 h"
    assert fleet_state.fmt_age(2 * 3600 + 5 * 60) == "2 h 5 min"
    assert fleet_state.fmt_age(3 * 86400) == "3 days"
    assert fleet_state.fmt_age(None) == "unknown age"


def test_fmt_duration():
    assert fleet_state.fmt_duration(7200) == "2 h"
    assert fleet_state.fmt_duration(1800) == "30 min"
    assert fleet_state.fmt_duration(86400) == "1 day"


# ---------------------------------------------------------------------------
# as_result — a published feed shaped like a run_pl() result
# ---------------------------------------------------------------------------
def test_as_result_carries_data_and_age():
    res = fleet_state.as_result(snapshot(age_minutes=14), "rag", NOW)
    assert res["rc"] == 0
    assert json.loads(res["out"])["sites"][0]["site"] == "avc"
    assert res["age"] == 14 * 60
    assert "published by workstation" in res["cmd"]


def test_as_result_none_for_failed_feed():
    snap = snapshot(feeds={"rag": {"ok": False, "rc": 1, "error": "boom"}})
    assert fleet_state.as_result(snap, "rag", NOW) is None


def test_as_result_none_for_absent_feed():
    assert fleet_state.as_result(snapshot(), "nosuch", NOW) is None


# ---------------------------------------------------------------------------
# decide — the source-selection rule
# ---------------------------------------------------------------------------
def _local(sites=("x",), ok=True):
    """A fake local `pl` shell-out. Records whether it was called at all."""
    calls = []

    def getter():
        calls.append(1)
        parsed = {"ok": ok, "sites": [{"site": s, "grade": "GREEN"} for s in sites]}
        return parsed, {"rc": 0, "out": json.dumps(parsed), "err": "", "secs": 1.0, "cmd": "pl rag"}

    getter.calls = calls
    return getter


def test_fresh_snapshot_wins_and_local_is_never_run():
    local = _local()
    parsed, res, prov = fleet_state.decide(snapshot(age_minutes=14), "rag", local, 7200, "sites", NOW)
    assert prov["source"] == "published"
    assert prov["host"] == "workstation"
    assert prov["age_human"] == "14 min"
    assert prov["stale"] is False
    assert local.calls == []          # no pointless shell-out when we have fresh state
    assert json.loads(res["out"])["summary"]["RED"] == 2


def test_stale_snapshot_is_marked_stale_when_local_knows_nothing():
    """The console-host case: local `pl` has no sites, so the stale snapshot is what
    you are looking at — and it says STALE, loudly."""
    local = _local(sites=())          # ok but empty == knows nothing
    parsed, res, prov = fleet_state.decide(snapshot(age_minutes=300), "rag", local, 7200, "sites", NOW)
    assert prov["source"] == "published"
    assert prov["stale"] is True
    assert prov["snapshot_stale"] is True
    assert prov["age_human"] == "5 h"
    assert prov["max_age_human"] == "2 h"
    assert local.calls == [1]         # it did try the fallback first
    assert json.loads(res["out"])["sites"][0]["site"] == "avc"


def test_stale_snapshot_yields_to_a_local_answer_that_knows_something():
    local = _local(sites=("a", "b"))
    parsed, res, prov = fleet_state.decide(snapshot(age_minutes=300), "rag", local, 7200, "sites", NOW)
    assert prov["source"] == "local"
    assert prov["snapshot_stale"] is True          # still reported in the UI
    assert "was not used" in prov["note"]
    assert parsed["sites"][0]["site"] == "a"


def test_no_snapshot_falls_back_to_local():
    local = _local(sites=("a",))
    parsed, res, prov = fleet_state.decide(None, "rag", local, 7200, "sites", NOW)
    assert prov["source"] == "local"
    assert prov["snapshot_present"] is False
    assert "no published fleet state" in prov["note"]


def test_failed_published_feed_falls_back_to_local():
    snap = snapshot(feeds={"rag": {"ok": False, "rc": 1, "error": "pl rag blew up"}})
    local = _local(sites=("a",))
    parsed, res, prov = fleet_state.decide(snap, "rag", local, 7200, "sites", NOW)
    assert prov["source"] == "local"
    assert "no usable 'rag' feed" in prov["note"]


def test_boundary_exactly_at_max_age_is_still_fresh():
    local = _local(sites=())
    _p, _r, prov = fleet_state.decide(snapshot(age_minutes=120), "rag", local, 7200, "sites", NOW)
    assert prov["stale"] is False
    _p, _r, prov = fleet_state.decide(snapshot(age_minutes=121), "rag", local, 7200, "sites", NOW)
    assert prov["stale"] is True


def test_todo_feed_uses_items_as_its_rows():
    local = _local(sites=())
    parsed, res, prov = fleet_state.decide(snapshot(age_minutes=5), "todo", local, 7200, "items", NOW)
    assert prov["source"] == "published"
    assert len(json.loads(res["out"])["items"]) == 2


# ---------------------------------------------------------------------------
# honesty helpers
# ---------------------------------------------------------------------------
def test_empty_local_error_points_at_the_fix():
    prov = fleet_state._prov(source="local", local_host="console-host")
    err = fleet_state.empty_local_error(prov)
    assert err["ok"] is False
    assert "pl fleet publish" in err["error"]
    assert "console-host" in err["error"]


def test_describe_flags_stale_state_for_the_model():
    _p, _r, prov = fleet_state.decide(snapshot(age_minutes=300), "rag", _local(sites=()), 7200, "sites", NOW)
    line = fleet_state.describe(prov)
    assert line.startswith("WARNING")
    assert "STALE" in line and "workstation" in line


def test_describe_fresh_is_calm():
    _p, _r, prov = fleet_state.decide(snapshot(age_minutes=3), "rag", _local(), 7200, "sites", NOW)
    assert fleet_state.describe(prov) == "Fleet/todo state above was published by workstation 3 min ago."


def test_published_data_parses_with_the_existing_rag_parser():
    """The published feed must be consumable by the SAME parser as stdout —
    that is what keeps one shape in the app."""
    from app import parsers

    res = fleet_state.as_result(snapshot(), "rag", NOW)
    rag = parsers.parse_rag(res["out"])
    assert rag["ok"] is True
    assert rag["counts"]["RED"] == 2
    assert {s["site"] for s in rag["sites"]} == {"avc", "nwc", "nwd"}


def test_published_todo_parses_into_backup_items():
    from app import parsers

    res = fleet_state.as_result(snapshot(), "todo", NOW)
    todo = parsers.parse_todo(res["out"])
    assert todo["ok"] is True
    assert len(parsers.todo_backup_items(todo)) == 2
