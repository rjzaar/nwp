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


def parse_security(stdout: str) -> dict:
    """`pl fleet security --json` → {"ok", "sites", "totals"}.

    The heavy lifting (and ALL the sanitising) lives in advisories.read_feed —
    this is only the stdout→JSON step every other parser here does. Advisory
    text is third-party and ends up in the DOM, so it is re-cleaned on the way
    in even though the publisher already cleaned it on the way out.
    """
    from . import advisories

    data = extract_json(stdout)
    if data is None:
        return {"ok": False, "error": "no JSON found in pl fleet security output",
                "sites": [], "totals": advisories.totals([]), "raw": strip_ansi(stdout)[-4000:]}
    view = advisories.read_feed(data)
    if not view.get("ok"):
        view["raw"] = strip_ansi(stdout)[-4000:]
    return view


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


# ---------------------------------------------------------------------------
# Tab counts — pure formatters for the tab-bar titles. Contract: return a
# short string ("" on any parse failure — a missing number must NEVER block
# or break a tab) and never raise.
# ---------------------------------------------------------------------------
def fmt_rag_tab(rag: dict) -> str:
    """parsed rag → '2🔴 1🟡 9🟢' (non-zero groups only; '' when unparsed)."""
    try:
        if not rag.get("ok"):
            return ""
        c = rag.get("counts", {})
        parts = [f"{c[k]}{dot}" for k, dot in (("RED", "🔴"), ("AMBER", "🟡"), ("GREEN", "🟢")) if c.get(k)]
        return " ".join(parts)
    except Exception:  # noqa: BLE001 — counts are decoration, never load-bearing
        return ""


def fmt_n_tab(n, suffix: str = "") -> str:
    """int → '(14)' / '(2 stale)'; anything non-int-able → ''."""
    try:
        n = int(n)
    except (TypeError, ValueError):
        return ""
    return f"({n}{(' ' + suffix) if suffix else ''})"


DEMO_LIVE_ROW_RE = re.compile(r"\blive\b", re.I)
DEMO_EVENT_RE = re.compile(r"\b(reset-ok|reset-failed|skip-active|skip-floor)\b")


def demo_live_code_count(codes: dict) -> int:
    """parse_demo_codes result → number of live (usable) codes. 0 on doubt."""
    try:
        return sum(1 for r in codes.get("rows", []) if DEMO_LIVE_ROW_RE.search(r))
    except Exception:  # noqa: BLE001
        return 0


def demo_reset_alert(status: dict) -> bool:
    """parse_demo_status result → True when the LAST logged reset event is a
    skip or failure (the tab shows a dot). No events / no data → False."""
    try:
        events = DEMO_EVENT_RE.findall(status.get("raw", "") or "")
        return bool(events) and events[-1] != "reset-ok"
    except Exception:  # noqa: BLE001
        return False


def ci_running_count(blocks) -> int:
    """CI pane blocks → number of head pipelines currently running/pending."""
    n = 0
    try:
        for b in blocks or []:
            for row in b.get("mrs", []):
                pipe = row.get("pipeline") or {}
                if str(pipe.get("status", "")).lower() in ("running", "pending"):
                    n += 1
    except Exception:  # noqa: BLE001
        return 0
    return n


# ---------------------------------------------------------------------------
# Invite email extraction (`pl demo invite` → the copyable draft)
# ---------------------------------------------------------------------------
def extract_invite_email(stdout: str) -> str:
    """Slice the copy-ready email out of `pl demo invite` output.

    The draft runs from the 'Subject:' line through the 'With gratitude,'
    closing. Returns '' when no draft is present (caller shows raw output).
    """
    text = strip_ansi(stdout or "")
    start = text.find("Subject:")
    if start == -1:
        return ""
    end_marker = "With gratitude,"
    end = text.find(end_marker, start)
    if end != -1:
        return text[start : end + len(end_marker)].rstrip()
    # Fallback: stop before the trailing status lines if the closing changed.
    end = text.find("Draft saved", start)
    return (text[start:end] if end != -1 else text[start:]).rstrip()


def fmt_age(secs) -> str:
    """Seconds → '2h 01m' / '3d 4h' / 'unknown time'. Never raises; anything
    non-sensical reads as unknown rather than as a small number."""
    if not isinstance(secs, int) or isinstance(secs, bool) or secs < 0:
        return "unknown time"
    if secs < 3600:
        return f"{secs // 60}m"
    if secs < 86400:
        return f"{secs // 3600}h {(secs % 3600) // 60:02d}m"
    return f"{secs // 86400}d {(secs % 86400) // 3600}h"


DEMO_CODE_STATES = ("live", "revoked", "expired")


def parse_demo_codes_json(stdout: str) -> dict:
    """`pl demo codes <site> list --json` (ops#328) — a real contract.

    ok:false — including the verb's own exit-2 unreadable-registry document —
    surfaces as CANNOT VERIFY with a reason; it must never collapse into an
    empty-but-healthy list (ops#281 / !394)."""
    raw = strip_ansi(stdout or "")[-4000:]
    data = extract_json(stdout)
    if not isinstance(data, dict) or "ok" not in data:
        return {"ok": False, "reason": "no JSON found in pl demo codes list --json output "
                "(is the deployed pl older than ops#328?)", "raw": raw,
                "codes": [], "counts": {}}
    if not data.get("ok"):
        return {"ok": False,
                "reason": str(data.get("reason", "registry unreadable"))[:300],
                "raw": raw, "codes": [], "counts": {}}
    codes = []
    for r in data.get("codes", []) or []:
        if not isinstance(r, dict):
            continue
        state = str(r.get("state", ""))[:12]
        codes.append({
            "id": str(r.get("id", ""))[:40],
            "bundle": str(r.get("bundle", ""))[:40],
            "state": state if state in DEMO_CODE_STATES else "?",
            "expires_iso": str(r.get("expires_iso", ""))[:25],
            "created_iso": str(r.get("created_iso", ""))[:25],
            "hash_prefix": str(r.get("hash_prefix", ""))[:16],
        })
    raw_counts = data.get("counts", {})
    if not isinstance(raw_counts, dict):
        raw_counts = {}
    counts = {}
    for k in ("live", "revoked", "expired", "total"):
        try:
            counts[k] = int(raw_counts.get(k, 0) or 0)
        except (TypeError, ValueError):
            counts[k] = 0
    return {"ok": True, "registry": str(data.get("registry", "present"))[:16],
            "codes": codes, "counts": counts, "raw": raw}


# ops#329 D4: the return leg is hourly; older than TWO cycles = the leg has
# stopped and the reading is CANNOT VERIFY (stale return leg). Kept in sync
# with lib/demo-box-status.sh's DEMO_RETURN_LEG_MAX_AGE.
RETURN_LEG_STALE_SECS = 7200


def _to_int(v):
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


def _seal_feedback_status(d) -> dict:
    """The ops#329 D4 return-leg block of the seal document. An absent or
    unreported block keeps a REASON (a deployed pl older than D4 must render
    CANNOT VERIFY, never silence); staleness is recomputed here so a document
    whose emitter under-claimed still carries the verdict."""
    if not isinstance(d, dict) or not d.get("reported"):
        return {"reported": False,
                "by_design": bool(isinstance(d, dict) and d.get("by_design")),
                "reason": str((d or {}).get(
                    "reason",
                    "the deployed pl does not carry the return leg "
                    "(pre-ops#329 D4 — redeploy/merge first)"))[:300]}
    age = _to_int(d.get("age_seconds"))
    return {"reported": True,
            "by_design": False,
            "result": str(d.get("result", "?"))[:16],
            "ts": str(d.get("ts", ""))[:25],
            "summary": str(d.get("summary", ""))[:120],
            "advanced": _to_int(d.get("advanced")),
            "drafts_captured": _to_int(d.get("drafts_captured")),
            "checked": _to_int(d.get("checked")),
            "age_seconds": age,
            "age_human": fmt_age(age),
            "stale": bool(d.get("stale"))
                     or (age is not None and age > RETURN_LEG_STALE_SECS)}


def _seal_backups(d) -> dict:
    """The ops#329 D5 live-box backups block: newest file per subdir of
    /var/backups/nwp-pull. missing/unreadable keep their identities — an
    unreadable dir and an empty one never render alike."""
    if not isinstance(d, dict) or not d.get("reported"):
        return {"reported": False,
                "by_design": bool(isinstance(d, dict) and d.get("by_design")),
                "reason": str((d or {}).get(
                    "reason",
                    "the deployed pl does not carry the box backups "
                    "(pre-ops#329 D5 — redeploy/merge first)"))[:300]}
    entries = []
    for e in (d.get("entries") or [])[:12]:
        if not isinstance(e, dict):
            continue
        age = _to_int(e.get("age_seconds"))
        entries.append({"subdir": str(e.get("subdir", ""))[:40],
                        "empty": bool(e.get("empty")),
                        "newest": str(e.get("newest", ""))[:80],
                        "bytes": _to_int(e.get("bytes")),
                        "mtime": str(e.get("mtime", ""))[:25],
                        "age_seconds": age,
                        "age_human": fmt_age(age)})
    return {"reported": True,
            "by_design": False,
            "state": str(d.get("state", "?"))[:16],
            "dir": str(d.get("dir", ""))[:120],
            "entries": entries}


def parse_seal_status(stdout: str) -> dict:
    """`pl demo seal-status <site> --json` (ops#328): what tonight's reset
    restores — plus, since ops#329 D4/D5, the box's return-leg last run and
    its nightly pull-backup ages. ok:false keeps its reason — 'I could not
    read the staged golden' and 'no golden' lead to different actions and
    never render alike."""
    raw = strip_ansi(stdout or "")[-2000:]
    data = extract_json(stdout)
    if not isinstance(data, dict) or "ok" not in data:
        return {"ok": False, "reason": "no JSON found in pl demo seal-status output "
                "(is the deployed pl older than ops#328?)", "raw": raw}
    if not data.get("ok"):
        return {"ok": False, "reason": str(data.get("reason", "CANNOT VERIFY"))[:300],
                "raw": raw}
    age = data.get("age_seconds")
    try:
        age = int(age)
    except (TypeError, ValueError):
        age = None
    return {"ok": True,
            "sealed_at": str(data.get("sealed_at", ""))[:25],
            "age_seconds": age,
            "age_human": fmt_age(age),
            "last_reset": str(data.get("last_reset") or "")[:40],
            "source": str(data.get("source", ""))[:120],
            "reset_window": str(data.get("reset_window", ""))[:80],
            "feedback_status": _seal_feedback_status(data.get("feedback_status")),
            "backups": _seal_backups(data.get("backups")),
            "raw": raw}


def parse_nwc_drush(stdout: str, command: str) -> dict:
    """`pl drush <site> --tier=live --execute -- <command> --format=json`
    (ops#329 tranche 2): the nwc profile's read-only status surface.

    The verb interleaves its own chrome (Target/Fallback/header lines) with
    drush's stdout, so the JSON is pulled with the same balanced-brace scan
    every other mixed-output parser here uses.

    THE load-bearing branch is `not_deployed`: until the nwc profile MR is
    merged AND deployed to live, drush answers `Command "…" is not defined`
    on stderr — that is a DEPLOY GAP, not a mystery, and the reason says
    exactly what discharges it. Everything else unreadable is CANNOT VERIFY
    with the raw tail kept; an ok:false payload keeps the command's own
    reason (the profile side already fails closed with exit 2).
    """
    raw = strip_ansi(stdout or "")
    if f'Command "{command}" is not defined' in raw:
        return {"ok": False, "not_deployed": True,
                "reason": f"drush command {command} is not on live yet — "
                          f"merge + deploy the nwc profile MR (ops#329 tranche 2), "
                          f"then refresh this slot",
                "raw": raw[-2000:]}
    data = extract_json(stdout)
    if not isinstance(data, dict) or "ok" not in data:
        return {"ok": False,
                "reason": f"no JSON found in {command} output "
                          f"(box unreachable, or the deployed pl/profile is older than ops#329 t2)",
                "raw": raw[-2000:]}
    if not data.get("ok"):
        return {"ok": False, "reason": str(data.get("reason", "CANNOT VERIFY"))[:300],
                "raw": raw[-2000:]}
    return {"ok": True, "data": data, "raw": raw[-2000:]}


def parse_checkout(stdout: str) -> dict:
    """`pl fleet checkout --json` (ops#329) — this host's own nwp checkout.

    Network-free by contract on the emitting side (pl-freshness idiom): the
    behind-count is vs origin/main AS OF THE LAST FETCH, and the age of that
    fetch rides along so the consumer can say so."""
    data = extract_json(stdout)
    if not isinstance(data, dict) or "ok" not in data:
        return {"ok": False, "reason": "no JSON from pl fleet checkout --json "
                "(is this checkout older than ops#329?)"}
    if not data.get("ok"):
        return {"ok": False, "reason": str(data.get("reason", "checkout unreadable"))[:300]}
    def _int(v):
        try:
            return int(v)
        except (TypeError, ValueError):
            return None
    return {"ok": True,
            "root": str(data.get("root", ""))[:200],
            "branch": str(data.get("branch", ""))[:60],
            "head": str(data.get("head", ""))[:40],
            "head_short": str(data.get("head_short", ""))[:12],
            "head_time": str(data.get("head_time", ""))[:30],
            "ahead": _int(data.get("ahead")),
            "behind": _int(data.get("behind")),
            "fetched_age_seconds": _int(data.get("fetched_age_seconds")),
            "dirty": bool(data.get("dirty")),
            "loop_paused": bool(data.get("loop_paused"))}


def parse_estate(stdout: str) -> dict:
    """`pl fleet estate --json` (ops#329) — the workstation's estate feed:
    repo drift, deploy records, harvest spool, secrets debt, backup ages.

    ok:false keeps its reason and must never collapse into empty lists — an
    empty repos table reads as "no drift anywhere", which is exactly the lie
    the overview exists to prevent."""
    data = extract_json(stdout)
    if not isinstance(data, dict) or "ok" not in data:
        return {"ok": False, "reason": "no JSON from pl fleet estate --json "
                "(is the publisher's pl older than ops#329?)"}
    if not data.get("ok"):
        return {"ok": False, "reason": str(data.get("reason", "estate feed unreadable"))[:300]}
    repos = [r for r in (data.get("repos") or []) if isinstance(r, dict)]
    return {"ok": True,
            "generated_at": str(data.get("generated_at", ""))[:30],
            "host": str(data.get("host", ""))[:60],
            "repos": repos,
            "deploys": data.get("deploys") if isinstance(data.get("deploys"), dict) else {},
            "harvest": data.get("harvest") if isinstance(data.get("harvest"), dict) else {},
            "secrets_debt": data.get("secrets_debt") if isinstance(data.get("secrets_debt"), dict) else {},
            "backups": data.get("backups") if isinstance(data.get("backups"), dict) else {}}


def parse_demo_codes(stdout: str) -> dict:
    """`pl demo codes <site> list` — hashes only. Keep rows that look tabular."""
    text = strip_ansi(stdout or "")
    rows = []
    for l in text.splitlines():
        s = l.strip()
        if not s or set(s) <= {"-", "=", "+", "|", " "}:
            continue
        # State words match the real emitter (demo.sh cmd_status): live|revoked|expired.
        if re.search(r"[0-9a-f]{8}", s, re.I) or re.search(r"\b(live|active|revoked|expired|used)\b", s, re.I):
            rows.append(s[:200])
    return {"ok": bool(text.strip()), "rows": rows[:100], "raw": text[-6000:]}


# ---------------------------------------------------------------------------
# ops#328 tranche 3 — the per-tester editor's reads
# ---------------------------------------------------------------------------
TESTER_ART9_STATES = ("none", "granted", "stale", "withdrawn")


def _tester_mirror_note(last_access) -> str:
    """The Moodle-mirror column is a DERIVATION, never a claim about ssd's DB:
    ssd accounts are SSO-minted only, and guild memberships reconcile into the
    managed nwcguild:<uuid> cohorts at login. There is no cheap read-only
    per-user ssd surface (researched in ops#329 t2), so the honest rendering
    is what the SSO contract guarantees, keyed on whether the tester has ever
    logged in."""
    try:
        la = int(last_access or 0)
    except (TypeError, ValueError):
        la = 0
    if la <= 0:
        return "no ssd account yet — SSO-minted at first login"
    return "guilds mirror to ssd cohorts at next SSO login"


def parse_testers_json(stdout: str) -> dict:
    """`pl demo testers <site> list --json --tier=live` (ops#328 t3).

    Pass-through of drush nwc:tester-list's contract, sanitised. ok:false —
    including the wrapper's exit-2 CANNOT VERIFY and the not_deployed document
    it emits while the nwc profile MR is unmerged/undeployed — carries its
    reason + flags and must never collapse into an empty-but-healthy roster
    (ops#281)."""
    raw = strip_ansi(stdout or "")[-4000:]
    data = extract_json(stdout)
    if not isinstance(data, dict) or "ok" not in data:
        return {"ok": False, "not_deployed": False,
                "reason": "no JSON found in pl demo testers list --json output "
                          "(is the deployed pl older than ops#328 tranche 3?)",
                "raw": raw, "accounts": [], "counts": {}, "guild_catalog": {}}
    if not data.get("ok"):
        return {"ok": False,
                "not_deployed": bool(data.get("not_deployed")),
                "reason": str(data.get("reason", "roster unreadable"))[:400],
                "raw": raw, "accounts": [], "counts": {}, "guild_catalog": {}}

    counts = {}
    raw_counts = data.get("counts", {}) if isinstance(data.get("counts"), dict) else {}
    for k in ("fenced_active", "fenced_blocked", "real_active", "real_blocked"):
        try:
            counts[k] = int(raw_counts.get(k, 0) or 0)
        except (TypeError, ValueError):
            counts[k] = 0

    accounts = []
    for r in data.get("accounts", []) or []:
        if not isinstance(r, dict):
            continue
        guilds = []
        for g in r.get("guilds", []) or []:
            if not isinstance(g, dict):
                continue
            guilds.append({
                "group_id": g.get("group_id"),
                "type": str(g.get("type", ""))[:32],
                "label": str(g.get("label", ""))[:80],
                "seed_key": (str(g.get("seed_key"))[:40] if g.get("seed_key") else None),
                "roles": [str(x)[:40] for x in (g.get("roles") or []) if isinstance(x, str)],
            })
        consent_raw = r.get("consent", {}) if isinstance(r.get("consent"), dict) else {}
        art9 = str(consent_raw.get("art9", "?"))[:12]
        lvl = r.get("sojourner_level")
        accounts.append({
            "uid": r.get("uid"),
            "name": str(r.get("name", ""))[:60],
            "mail": str(r.get("mail", ""))[:80],
            "active": bool(r.get("active")),
            "fence": str(r.get("fence", "?"))[:10],
            "last_access": r.get("last_access"),
            "roles": [str(x)[:40] for x in (r.get("roles") or []) if isinstance(x, str)],
            "guilds": guilds,
            "sojourner_level": (int(lvl) if isinstance(lvl, (int, float)) else None),
            "skill_progress": [
                {"guild": str(s.get("guild") or "")[:60], "skill": str(s.get("skill") or "")[:60],
                 "level": s.get("level")}
                for s in (r.get("skill_progress") or []) if isinstance(s, dict)
            ][:20],
            "consent": {
                "art9": art9 if art9 in TESTER_ART9_STATES else "?",
                "art9_current": bool(consent_raw.get("art9_current")),
                "may_contribute": bool(consent_raw.get("may_contribute")),
                "may_keep_formation": bool(consent_raw.get("may_keep_formation")),
                "trialing": bool(consent_raw.get("trialing")),
            },
            "redeemed_bundle": r.get("redeemed_bundle"),
            "mirror": _tester_mirror_note(r.get("last_access")),
        })

    cat_raw = data.get("guild_catalog", {}) if isinstance(data.get("guild_catalog"), dict) else {}
    catalog = {
        "guilds": [
            {"seed_key": str(g.get("seed_key", ""))[:40], "label": str(g.get("label", ""))[:80],
             "group_id": g.get("group_id"), "type": str(g.get("type", ""))[:32]}
            for g in (cat_raw.get("guilds") or []) if isinstance(g, dict) and g.get("seed_key")
        ],
        "assignable_roles": [str(x)[:40] for x in (cat_raw.get("assignable_roles") or [])
                             if isinstance(x, str)],
        "sojourner_levels": [
            {"num": int(l.get("num", 0) or 0), "name": str(l.get("name", ""))[:60]}
            for l in (cat_raw.get("sojourner_levels") or []) if isinstance(l, dict)
        ],
        "note": str(cat_raw.get("note", ""))[:200],
    }

    return {"ok": True, "not_deployed": False, "counts": counts, "accounts": accounts,
            "guild_catalog": catalog, "generated_at": str(data.get("generated_at", ""))[:32],
            "raw": raw}


def parse_tester_action_json(stdout: str) -> dict:
    """A tester-editor write's outcome (`pl demo testers … set-guild|set-level`).

    Four honest shapes: ok (with the drush side's RE-READ state), a typed
    refusal (refused:true — rendered verbatim, a refusal is a result), the
    not_deployed document (the nwc profile MR not on live yet), and CANNOT
    VERIFY for everything else."""
    raw = strip_ansi(stdout or "")[-3000:]
    data = extract_json(stdout)
    if not isinstance(data, dict) or "ok" not in data:
        return {"ok": False, "refused": False, "not_deployed": False,
                "reason": "no JSON in the verb output", "raw": raw}
    out = {
        "ok": bool(data.get("ok")),
        "refused": bool(data.get("refused")),
        "not_deployed": bool(data.get("not_deployed")),
        "reason": str(data.get("reason", ""))[:500],
        "changed": bool(data.get("changed")),
        "raw": raw,
    }
    if isinstance(data.get("membership"), dict) and out["ok"]:
        m = data["membership"]
        out["membership"] = {
            "member": bool(m.get("member")),
            "roles": [str(x)[:40] for x in (m.get("roles") or []) if isinstance(x, str)],
            "individual_roles": [str(x)[:40] for x in (m.get("individual_roles") or [])
                                 if isinstance(x, str)],
        }
    for k in ("level_before", "level_after", "requested"):
        if isinstance(data.get(k), int):
            out[k] = data[k]
    if isinstance(data.get("codes_added"), list):
        out["codes_added"] = [str(x)[:10] for x in data["codes_added"]][:80]
    if isinstance(data.get("note"), str):
        out["note"] = data["note"][:300]
    return out
