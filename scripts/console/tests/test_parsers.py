import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.parsers import (  # noqa: E402
    extract_json,
    parse_demo_codes,
    parse_demo_status,
    parse_rag,
    parse_todo,
    strip_ansi,
    todo_backup_items,
)

# Fixtures mirror the REAL emitters (sampled 2026-07-25 from pl on the workstation).
RAG_JSON = json.dumps(
    {
        "generated": None,
        "summary": {"RED": 1, "AMBER": 1, "GREEN": 1},
        "sites": [
            {"site": "avc", "rag": "RED", "phase": "(dev)", "maturity": "(inc)", "security": 13,
             "ignored": 0, "stale": False, "todo_high": 0, "todo_med": 0, "todo_low": 0, "top": ""},
            {"site": "nwc", "rag": "AMBER", "phase": "dev", "maturity": "beta", "security": 0,
             "ignored": 0, "stale": True, "todo_high": 1, "todo_med": 2, "todo_low": 0,
             "top": "Uncommitted changes"},
            {"site": "nwt", "rag": "GREEN", "phase": "(dev)", "maturity": "(inc)", "security": 0,
             "ignored": 0, "stale": False, "todo_high": 0, "todo_med": 0, "todo_low": 0, "top": ""},
        ],
    }
)

TODO_JSON = json.dumps(
    {
        "timestamp": "2026-07-24T23:36:37Z",
        "summary": {"total": 3, "high": 1, "medium": 1, "low": 1},
        "items": [
            {"id": "INC-dir", "category": "INC", "priority": "high",
             "title": "Incomplete installation (step 0)", "description": "Site: dir | Stalled",
             "site": "dir", "action": "pl install -s=1 dir"},
            {"id": "BAK-nwc", "category": "BAK", "priority": "medium",
             "title": "Backup is 9 days old", "description": "Site: nwc", "site": "nwc",
             "action": "pl backup nwc"},
            {"id": "TOK-linode", "category": "TOK", "priority": "low",
             "title": "Token rotation not tracked: linode", "description": "Last rotated: unknown",
             "site": "", "action": "pl todo token linode"},
        ],
    }
)


def test_strip_ansi():
    assert strip_ansi("\x1b[0;31mRED\x1b[0m ok") == "RED ok"
    assert strip_ansi("") == ""
    assert strip_ansi(None) == ""


def test_extract_json_with_noise():
    noisy = "WARNING: cache stale\n" + RAG_JSON + "\ntrailing"
    assert extract_json(noisy)["summary"]["RED"] == 1
    assert extract_json("no json here") is None
    assert extract_json("{broken") is None


def test_parse_rag_real_shape():
    r = parse_rag(RAG_JSON)
    assert r["ok"]
    assert r["counts"] == {"RED": 1, "AMBER": 1, "GREEN": 1, "OTHER": 0}
    avc = next(s for s in r["sites"] if s["site"] == "avc")
    assert avc["grade"] == "RED"
    assert any("13 security advisories" in x for x in avc["reasons"])
    nwc = next(s for s in r["sites"] if s["site"] == "nwc")
    assert any("stale" in x for x in nwc["reasons"])
    assert any("todo 1/2/0" in x for x in nwc["reasons"])
    assert any("Uncommitted" in x for x in nwc["reasons"])


def test_parse_rag_garbage_is_graceful():
    r = parse_rag("\x1b[31mtable output only, no json\x1b[0m")
    assert not r["ok"]
    assert "raw" in r and "table output" in r["raw"]
    assert not parse_rag("")["ok"]
    assert parse_rag('"just a string"')["ok"] is False


def test_parse_todo_real_shape():
    t = parse_todo(TODO_JSON)
    assert t["ok"]
    assert len(t["items"]) == 3
    assert t["summary"]["high"] == 1
    inc = t["items"][0]
    assert inc["site"] == "dir" and inc["priority"] == "high"
    assert "Incomplete installation" in inc["text"] and "Stalled" in inc["text"]
    assert inc["action"] == "pl install -s=1 dir"


def test_todo_backup_slice():
    t = parse_todo(TODO_JSON)
    items = todo_backup_items(t)
    assert len(items) == 1 and items[0]["site"] == "nwc"
    assert todo_backup_items({"ok": False}) == []


def test_parse_demo_status_heuristics():
    out = "\x1b[1mDemo status: nwd\x1b[0m\nGolden image: captured 2026-07-20 (verified)\nLast reset: 2026-07-24 04:01 ok\nCodes: 3 active\nnoise line\n"
    d = parse_demo_status(out)
    assert d["ok"]
    assert any("Golden" in h for h in d["highlights"])
    assert any("Last reset" in h for h in d["highlights"])
    assert "noise line" in d["raw"]
    assert parse_demo_status("")["ok"] is False


def test_parse_demo_codes_hashes_only_rows():
    out = "ID       HASH        BUNDLE          STATUS\nc01  9f86d081aa  tester-member   active\n----\nrandom prose\n"
    d = parse_demo_codes(out)
    assert d["ok"]
    assert any("9f86d081aa" in r for r in d["rows"])
    assert not any(r.startswith("----") for r in d["rows"])
