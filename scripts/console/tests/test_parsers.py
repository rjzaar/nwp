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


# --- tab counts (full-screen tabs feature) ------------------------------------
from app.parsers import (  # noqa: E402
    ci_running_count,
    demo_live_code_count,
    demo_reset_alert,
    extract_invite_email,
    fmt_n_tab,
    fmt_rag_tab,
)


def test_fmt_rag_tab_counts_in_title():
    assert fmt_rag_tab(parse_rag(RAG_JSON)) == "1🔴 1🟡 1🟢"
    two = parse_rag(RAG_JSON)
    two["counts"] = {"RED": 0, "AMBER": 0, "GREEN": 9, "OTHER": 0}
    assert fmt_rag_tab(two) == "9🟢"


def test_fmt_rag_tab_degrades_to_empty():
    """A parse failure must give NO number, never an exception/blocked tab."""
    assert fmt_rag_tab(parse_rag("garbage")) == ""
    assert fmt_rag_tab({}) == ""
    assert fmt_rag_tab({"ok": True}) == ""
    assert fmt_rag_tab(None) == ""


def test_fmt_n_tab():
    assert fmt_n_tab(14) == "(14)"
    assert fmt_n_tab(0) == "(0)"
    assert fmt_n_tab(2, "stale") == "(2 stale)"
    assert fmt_n_tab("7") == "(7)"
    assert fmt_n_tab(None) == ""
    assert fmt_n_tab("wat") == ""


def test_demo_live_code_count():
    codes = parse_demo_codes(
        "id    bundle                 state    expires\n"
        "c1    tester-member          live     2026-08-08\n"
        "c2    tester-guild-leader    revoked  2026-08-08\n"
        "c3    tester-member          expired  2026-07-01\n"
        "c4    tester-content-manager live     2026-08-08\n"
    )
    assert demo_live_code_count(codes) == 2
    assert demo_live_code_count(parse_demo_codes("")) == 0
    assert demo_live_code_count({}) == 0


def test_demo_reset_alert_last_event_wins():
    ok_then_skip = parse_demo_status(
        "Recent resets/skips (last 10):\n"
        "  2026-07-23T14:00:00Z reset-ok tier=dev took=41s\n"
        "  2026-07-24T14:00:00Z skip-active tier=dev window=30m\n"
    )
    assert demo_reset_alert(ok_then_skip) is True
    skip_then_ok = parse_demo_status(
        "  2026-07-23T14:00:00Z skip-floor tier=dev\n"
        "  2026-07-24T14:00:00Z reset-ok tier=dev took=39s\n"
    )
    assert demo_reset_alert(skip_then_ok) is False
    assert demo_reset_alert(parse_demo_status("")) is False
    assert demo_reset_alert({}) is False


def test_ci_running_count():
    blocks = [
        {"project": "nwp/nwp", "mrs": [
            {"mr": {"iid": 1}, "pipeline": {"status": "running"}},
            {"mr": {"iid": 2}, "pipeline": {"status": "success"}},
            {"mr": {"iid": 3}, "pipeline": None},
            {"mr": {"iid": 4}, "pipeline": {"status": "pending"}},
        ]},
    ]
    assert ci_running_count(blocks) == 2
    assert ci_running_count([]) == 0
    assert ci_running_count(None) == 0
    assert ci_running_count([{"mrs": "broken"}]) == 0


# --- invite email extraction --------------------------------------------------
INVITE_STDOUT = (
    "\x1b[1mInvitation draft — nwd (3 level(s), codes expire in 14d)\x1b[0m\n\n"
    "Subject: Would you help us test Saint School?\n\nHi!\n\n"
    "HOW TO JOIN (3 steps)\n\n1. Open:  https://nwd.example.org/demo/join\n"
    "──────── MEMBER TESTER ────────\n\nYour code:  ABCDE-FGHJK-LMNPQ-RSTUV\n\n"
    "With gratitude,\n\n"
    "[OK] Draft saved: sites/nwd/demo-invites/invite-x.md (mode 0600 — it contains PLAINTEXT codes)\n"
)


def test_extract_invite_email_slices_draft_only():
    email = extract_invite_email(INVITE_STDOUT)
    assert email.startswith("Subject:")
    assert email.endswith("With gratitude,")
    assert "ABCDE-FGHJK-LMNPQ-RSTUV" in email
    assert "Draft saved" not in email        # trailing status lines removed
    assert "Invitation draft" not in email   # leading header removed


def test_extract_invite_email_degrades():
    assert extract_invite_email("no draft here") == ""
    assert extract_invite_email("") == ""
    assert extract_invite_email(None) == ""
