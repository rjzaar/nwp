"""Quokka — the console's local-LLM chat helper. stdlib only.

Trust properties (hold the line on these in review):

  * Talks ONLY to the loopback ollama on this same host (config.QUOKKA_URL,
    default 127.0.0.1:11434). No cloud LLM, no new network surface.
  * READ-ONLY by construction: this module has no import path to actions.py
    or runner.py — Quokka literally cannot build or run a command. Its fleet
    knowledge arrives as a rendered text block (context injection), never as
    tool/function calls, which also keeps it model-portable.
  * Never invents fleet facts: the persona prompt pins Quokka to the LIVE
    STATE block and tells it to say so when the answer isn't in it.
  * Degrades politely: ollama down/slow → QuokkaError, and the caller shows
    "Quokka is asleep" while every other tab keeps working.
"""
from __future__ import annotations

import json
import urllib.error
import urllib.request

PERSONA = (
    "You are Quokka, the household's friendly local ops assistant for the NWP "
    "fleet (a small set of self-hosted community sites). Be concise, warm and "
    "plain-language; prefer short bullet lists. A LIVE STATE block is included "
    "with each message — it is your ONLY source of truth about the fleet. "
    "Never invent fleet facts: if the live state doesn't contain the answer, "
    "say so plainly. You cannot run commands or change anything; when action "
    "is needed, suggest what the operator could run on the workstation."
)

BRIEF_PROMPT = (
    "Using ONLY the LIVE STATE block above, give the operator a morning "
    "brief: (1) what changed in the last 24 hours, (2) what is red or "
    "failing right now, (3) what most needs the operator's attention today. "
    "Short bullets, plain language, no preamble."
)


class QuokkaError(Exception):
    """Any failure talking to the local model — callers degrade politely."""


def alive(url: str, timeout: int = 3) -> bool:
    """Is ollama answering on this host? Cheap probe for the tab dot."""
    try:
        with urllib.request.urlopen(f"{url.rstrip('/')}/api/tags", timeout=timeout) as r:
            return r.status == 200
    except (urllib.error.URLError, TimeoutError, OSError, ValueError):
        return False


def chat_stream(url: str, model: str, messages: list[dict], timeout: int = 60):
    """Yield assistant text chunks from ollama /api/chat (NDJSON stream).

    Raises QuokkaError on connection/protocol failure (possibly mid-stream —
    callers that already sent chunks should append an apology, not crash).
    """
    payload = json.dumps({"model": model, "messages": messages, "stream": True}).encode()
    req = urllib.request.Request(
        f"{url.rstrip('/')}/api/chat", data=payload,
        headers={"Content-Type": "application/json"}, method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            for line in r:
                line = line.strip()
                if not line:
                    continue
                try:
                    d = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if d.get("error"):
                    raise QuokkaError(str(d["error"])[:200])
                chunk = (d.get("message") or {}).get("content", "")
                if chunk:
                    yield chunk
                if d.get("done"):
                    return
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        raise QuokkaError(str(e)[:200]) from e


# ---------------------------------------------------------------------------
# Live-state rendering — pure functions over ALREADY-PARSED data (the parsers
# and runner stay in the caller; this module never gathers anything itself).
# ---------------------------------------------------------------------------
def _line_rag(rag: dict) -> str:
    if not (isinstance(rag, dict) and rag.get("ok")):
        return "Fleet RAG: unavailable"
    by = {"RED": [], "AMBER": [], "GREEN": []}
    for s in rag.get("sites", []):
        by.setdefault(s.get("grade", "OTHER"), []).append(s.get("site", "?"))
    parts = []
    for grade in ("RED", "AMBER", "GREEN"):
        names = by.get(grade, [])
        if names:
            parts.append(f"{grade.lower()}={len(names)} ({', '.join(names[:8])})")
    return "Fleet RAG: " + (", ".join(parts) if parts else "no sites reported")


def _line_issues(issues, api_ok: bool) -> list[str]:
    if not api_ok or not isinstance(issues, list):
        return ["Open issues: unavailable"]
    lines = [f"Open issues: {len(issues)}"]
    for i in issues[:5]:
        try:
            lines.append(f"  #{i['iid']} {str(i.get('title', ''))[:90]}")
        except (TypeError, KeyError):
            continue
    return lines


def _line_todo(todo: dict) -> str:
    if not (isinstance(todo, dict) and todo.get("ok")):
        return "Todo: unavailable"
    items = todo.get("items", [])
    high = sum(1 for i in items if i.get("priority") == "high")
    return f"Todo: {len(items)} items ({high} high)"


def _line_demo(demo_sites: list[dict]) -> list[str]:
    if not demo_sites:
        return ["Demo tier: no sites configured"]
    lines = []
    for d in demo_sites:
        try:
            site = d.get("site", "?")
            n = d.get("live_codes", 0)
            last = str(d.get("last_event", "") or "no resets logged")
            lines.append(f"Demo {site}: {n} live invite codes; last reset event: {last}")
        except (TypeError, AttributeError):
            continue
    return lines or ["Demo tier: unavailable"]


def _line_ci(blocks, api_ok: bool) -> list[str]:
    if not api_ok:
        return ["CI: unavailable"]
    lines = []
    try:
        for b in blocks or []:
            for row in b.get("mrs", []):
                mr = row.get("mr", {})
                pipe = row.get("pipeline") or {}
                lines.append(
                    f"CI {b.get('project', '?')} !{mr.get('iid', '?')} "
                    f"{str(mr.get('title', ''))[:60]}: {pipe.get('status', 'no pipeline')}"
                )
    except (TypeError, AttributeError):
        return ["CI: unavailable"]
    return lines or ["CI: no open merge requests"]


def render_context(state: dict) -> str:
    """state (parsed pieces, any of which may be missing/broken) → the LIVE
    STATE text block. Never raises — a broken feed reads 'unavailable'."""
    lines = [f"LIVE STATE (auto-generated {state.get('generated', '')} — read-only):"]
    try:
        lines.append(_line_rag(state.get("rag", {})))
        lines.extend(_line_issues(state.get("issues"), state.get("issues_ok", False)))
        lines.append(_line_todo(state.get("todo", {})))
        lines.extend(_line_demo(state.get("demo", [])))
        lines.extend(_line_ci(state.get("ci"), state.get("ci_ok", False)))
        extra = state.get("extra_lines", [])
        if isinstance(extra, list):
            lines.extend(str(x)[:200] for x in extra[:60])
    except Exception:  # noqa: BLE001 — context is best-effort, never fatal
        lines.append("(parts of the live state failed to render)")
    return "\n".join(lines)


def build_messages(context: str, history: list[dict], user_msg: str) -> list[dict]:
    """Assemble the ollama message list: persona, capped history, then the
    user's message with the LIVE STATE block prepended (context injection)."""
    msgs: list[dict] = [{"role": "system", "content": PERSONA}]
    total = 0
    kept: list[dict] = []
    for turn in reversed(history[-12:]):
        role = turn.get("role")
        content = str(turn.get("content", ""))[:2000]
        if role not in ("user", "assistant") or not content:
            continue
        total += len(content)
        if total > 8000:
            break
        kept.append({"role": role, "content": content})
    msgs.extend(reversed(kept))
    msgs.append({"role": "user", "content": f"{context}\n\n---\n\n{user_msg}"})
    return msgs
