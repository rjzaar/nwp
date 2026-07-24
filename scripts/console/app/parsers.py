"""Defensive parsers for `pl` output — pure, stdlib only, unit-tested.

The contract with the rest of the app: every parser returns a dict with
{"ok": bool, ...} and NEVER raises on weird input. When parsing fails the
pane shows the raw (ANSI-stripped) text instead — brittle-parser honesty.
"""
from __future__ import annotations

import json
import re

ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]|\x1b\][^\x07]*\x07")


def strip_ansi(text: str) -> str:
    return ANSI_RE.sub("", text or "")


def extract_json(text: str):
    """Pull the first JSON object/array out of mixed stdout (warnings + JSON)."""
    text = strip_ansi(text or "")
    for opener, closer in (("{", "}"), ("[", "]")):
        start = text.find(opener)
        while start != -1:
            depth = 0
            in_str = False
            esc = False
            for i in range(start, len(text)):
                ch = text[i]
                if esc:
                    esc = False
                    continue
                if ch == "\\":
                    esc = in_str
                    continue
                if ch == '"':
                    in_str = not in_str
                    continue
                if in_str:
                    continue
                if ch == opener:
                    depth += 1
                elif ch == closer:
                    depth -= 1
                    if depth == 0:
                        try:
                            return json.loads(text[start : i + 1])
                        except json.JSONDecodeError:
                            break
            start = text.find(opener, start + 1)
    return None


def parse_rag(stdout: str) -> dict:
    """`pl rag --json` → {"ok", "sites": [{"site","grade","reasons"}], "counts"}."""
    data = extract_json(stdout)
    if data is None:
        return {"ok": False, "error": "no JSON found in pl rag output", "raw": strip_ansi(stdout)[-4000:]}
    sites = []
    raw_sites = data.get("sites", data) if isinstance(data, dict) else data
    if isinstance(raw_sites, dict):
        it = raw_sites.items()
    elif isinstance(raw_sites, list):
        it = ((d.get("site", d.get("name", "?")), d) for d in raw_sites if isinstance(d, dict))
    else:
        return {"ok": False, "error": "unrecognised pl rag JSON shape", "raw": strip_ansi(stdout)[-4000:]}
    for name, d in it:
        if not isinstance(d, dict):
            continue
        grade = str(d.get("rag", d.get("grade", d.get("status", "?")))).upper()
        # Real emitter fields (rag.sh): security, stale, todo_high/med/low, top.
        reasons = []
        try:
            sec = int(d.get("security", 0) or 0)
            if sec:
                reasons.append(f"{sec} security advisor{'y' if sec == 1 else 'ies'}")
        except (TypeError, ValueError):
            pass
        if d.get("stale"):
            reasons.append("audit cache stale")
        th, tm, tl = (d.get("todo_high", 0), d.get("todo_med", 0), d.get("todo_low", 0))
        if any((th, tm, tl)):
            reasons.append(f"todo {th}/{tm}/{tl} (high/med/low)")
        top = str(d.get("top", "") or "").strip()
        if top:
            reasons.append(top[:160])
        extra = d.get("reasons", [])
        if isinstance(extra, list):
            reasons.extend(str(r)[:160] for r in extra)
        phase = d.get("phase", "")
        sites.append({"site": str(name), "grade": grade, "reasons": reasons[:8], "phase": str(phase)})
    counts = {"RED": 0, "AMBER": 0, "GREEN": 0, "OTHER": 0}
    for s in sites:
        counts[s["grade"] if s["grade"] in counts else "OTHER"] += 1
    return {"ok": True, "sites": sites, "counts": counts}


def parse_todo(stdout: str) -> dict:
    """`pl todo check --json` → {"ok", "items": [{"site","check","priority","text"}]}."""
    data = extract_json(stdout)
    if data is None:
        return {"ok": False, "error": "no JSON found in pl todo output", "raw": strip_ansi(stdout)[-4000:]}
    items = []
    raw_items = data.get("items", data.get("todos", data)) if isinstance(data, dict) else data
    if not isinstance(raw_items, list):
        return {"ok": False, "error": "unrecognised pl todo JSON shape", "raw": strip_ansi(stdout)[-4000:]}
    for d in raw_items:
        if not isinstance(d, dict):
            continue
        text = str(d.get("title", "") or d.get("text", "") or d.get("message", "") or "")
        desc = str(d.get("description", "") or "")
        if desc and desc not in text:
            text = f"{text} — {desc}" if text else desc
        items.append(
            {
                "site": str(d.get("site", d.get("project", "")))[:40],
                "check": str(d.get("id", d.get("category", d.get("check", ""))))[:40],
                "priority": str(d.get("priority", d.get("level", "")))[:12],
                "text": text[:300],
                "action": str(d.get("action", ""))[:120],
            }
        )
    summary = data.get("summary", {}) if isinstance(data, dict) else {}
    return {"ok": True, "items": items, "summary": summary if isinstance(summary, dict) else {}}


def todo_backup_items(todo: dict) -> list[dict]:
    """Backup-freshness slice of the todo items (backups pane)."""
    if not todo.get("ok"):
        return []
    out = []
    for it in todo["items"]:
        blob = " ".join([it["check"], it["text"]]).lower()
        if "backup" in blob or "sweep" in blob:
            out.append(it)
    return out


def parse_demo_status(stdout: str) -> dict:
    """`pl demo status <site>` is a human table; extract headline lines, keep raw."""
    text = strip_ansi(stdout or "")
    lines = [l.rstrip() for l in text.splitlines()]
    highlights = []
    for l in lines:
        ll = l.lower()
        if any(k in ll for k in ("golden", "last reset", "reset:", "skip", "codes", "captured", "verified")):
            s = l.strip()
            if s and len(highlights) < 12:
                highlights.append(s[:160])
    return {"ok": bool(text.strip()), "highlights": highlights, "raw": text[-6000:]}


def parse_demo_codes(stdout: str) -> dict:
    """`pl demo codes <site> list` — hashes only. Keep rows that look tabular."""
    text = strip_ansi(stdout or "")
    rows = []
    for l in text.splitlines():
        s = l.strip()
        if not s or set(s) <= {"-", "=", "+", "|", " "}:
            continue
        if re.search(r"[0-9a-f]{8}", s, re.I) or re.search(r"\b(active|revoked|expired|used)\b", s, re.I):
            rows.append(s[:200])
    return {"ok": bool(text.strip()), "rows": rows[:100], "raw": text[-6000:]}
