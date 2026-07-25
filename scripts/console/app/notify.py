"""Gotify push notifications — the console's "tell me" channel (Phase 3).

The console's six read panes answer "what is going on?" *when you look*. This
module is the half that speaks first: it POSTs to a **self-hosted Gotify**
server on the mesh, which pushes to the Gotify app on the operator's phone.
Nothing leaves the mesh; no SaaS is involved.

Two halves, deliberately separated so the interesting half is unit-testable:

  * **delivery** — `Notifier`: one POST to Gotify. FAIL-OPEN by construction —
    every failure path returns False and nothing here can raise into a caller.
    A notification must NEVER break the thing that triggered it. Unconfigured
    (no URL or no token file) => silent no-op, so dev checkouts don't error.

  * **detection** — the pure `detect_*` functions, over ALREADY-GATHERED pane
    data plus the previous `NotifyState`. No I/O, no network, no subprocesses,
    no clock beyond what the caller passes in. They decide WHAT to say and
    return the next state; they never send anything.

Dedupe contract: every detector fires on **state CHANGE only**, and the state
is persisted (0600 JSON) so a console restart does not re-notify. The first run
against an empty state **seeds silently** — otherwise a deploy would fire one
push per already-red site. You are told about changes from that point on.

Token discipline mirrors `gitlab_api.py`: the application token is read from a
0600 file the operator provisions on the console host. `pl console deploy`
never copies it; it is never logged, never rendered, never placed in argv.
"""
from __future__ import annotations

import fcntl
import json
import os
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

STATE_VERSION = 1

# The toggle keys. Each is switchable on its own via NWP_CONSOLE_NOTIFY_EVENTS.
EVENT_KINDS = ("rag", "demo_tester", "demo_reset", "token_expiry", "ci", "brief")

# Gotify priority ladder. The Android client raises a sound/heads-up
# notification at >= 8 and stays quiet below it, so the loud end is reserved
# for "a human has to look now".
P_LOUD = 8      # a site just went red
P_HIGH = 7      # the demo reset actually failed
P_NORMAL = 6    # a tester filed something; CI went red
P_LOW = 5       # token expiry, test push
P_QUIET = 4     # recovery — good news, no need to buzz
P_MUTED = 3     # the morning brief

# Seam for tests: monkeypatch this instead of hitting the network.
_urlopen = urllib.request.urlopen


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


@dataclass
class Event:
    """One thing worth saying. `kind` is the toggle key; `click` deep-links
    back into the console tab that shows the detail."""

    kind: str
    title: str
    message: str
    priority: int = P_LOW
    click: str = ""
    dedupe: str = ""  # opaque change-key, for tests and the audit detail

    def as_detail(self) -> dict:
        """What lands in the audit log — never the body, just the shape."""
        return {"kind": self.kind, "title": self.title[:120], "priority": self.priority,
                "dedupe": self.dedupe[:120]}


# ---------------------------------------------------------------------------
# delivery
# ---------------------------------------------------------------------------
class Notifier:
    """Minimal Gotify client. Every public method is total: it returns a bool
    and never raises, because the caller is always in the middle of doing
    something more important than notifying."""

    def __init__(self, url: str, token_file: Path, timeout: int = 5):
        self.url = (url or "").rstrip("/")
        self.token_file = Path(token_file)
        self.timeout = timeout

    def _token(self) -> str | None:
        try:
            t = self.token_file.read_text().strip()
            return t or None
        except OSError:
            return None

    def configured(self) -> bool:
        """False => every send() is a no-op. Dev checkouts land here."""
        return bool(self.url) and self._token() is not None

    def status(self) -> dict:
        """For the UI. Deliberately reports only *whether* a token exists."""
        return {
            "url": self.url,
            "token_file": str(self.token_file),
            "has_token": self._token() is not None,
            "configured": self.configured(),
        }

    def send(self, title: str, message: str, priority: int = P_LOW, click: str = "") -> bool:
        """POST one message. Returns True only on a 2xx from Gotify."""
        if not self.configured():
            return False
        token = self._token()
        if not token:
            return False
        payload: dict = {
            "title": str(title)[:250],
            "message": str(message)[:4000],
            "priority": int(priority),
        }
        if click:
            # Gotify's client extras: tapping the notification opens the console.
            payload["extras"] = {"client::notification": {"click": {"url": click}}}
        try:
            data = json.dumps(payload).encode()
            req = urllib.request.Request(f"{self.url}/message", data=data, method="POST")
            req.add_header("Content-Type", "application/json")
            # Header auth, not ?token= — keeps the token out of Gotify's access log.
            req.add_header("X-Gotify-Key", token)
            with _urlopen(req, timeout=self.timeout) as r:
                return 200 <= getattr(r, "status", 200) < 300
        except (urllib.error.URLError, urllib.error.HTTPError, OSError, ValueError, TimeoutError):
            return False
        except Exception:  # noqa: BLE001 — fail-open is the whole point
            return False

    def send_event(self, ev: Event) -> bool:
        return self.send(ev.title, ev.message, ev.priority, ev.click)


# ---------------------------------------------------------------------------
# persisted state
# ---------------------------------------------------------------------------
class NotifyState:
    """0600 JSON blob holding the last-seen value for every detector, so a
    restart does not re-notify. Corrupt/unreadable state degrades to empty
    (i.e. re-seed silently) rather than crashing the checker."""

    def __init__(self, path: Path):
        self.path = Path(path)

    def load(self) -> dict:
        try:
            data = json.loads(self.path.read_text() or "{}")
            return data if isinstance(data, dict) else {}
        except (OSError, json.JSONDecodeError, ValueError):
            return {}

    def save(self, data: dict) -> bool:
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            data = dict(data, version=STATE_VERSION)
            tmp = self.path.with_suffix(".tmp")
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w") as f:
                fcntl.flock(f, fcntl.LOCK_EX)
                json.dump(data, f, indent=1, sort_keys=True)
            os.replace(tmp, self.path)
            return True
        except OSError:
            return False


# ---------------------------------------------------------------------------
# detection — pure functions. (data, previous state) -> (events, next state)
# ---------------------------------------------------------------------------
def _console(console_url: str, tab: str) -> str:
    return f"{console_url.rstrip('/')}/?tab={tab}" if console_url else ""


def detect_rag(rag: dict, prev, console_url: str = "") -> tuple[list[Event], dict]:
    """Fleet grade transitions. Fires when a site ENTERS red, and when a site
    recovers to green from red/amber. Steady state is silent."""
    if not rag.get("ok"):
        return [], (prev if isinstance(prev, dict) else {})  # unparseable: say nothing, keep state
    now = {str(s.get("site")): str(s.get("grade", "?")).upper()
           for s in rag.get("sites", []) if s.get("site")}
    if not isinstance(prev, dict):
        return [], now  # first run: seed silently
    reasons = {str(s.get("site")): list(s.get("reasons") or []) for s in rag.get("sites", [])}
    events: list[Event] = []
    for site in sorted(now):
        grade, was = now[site], prev.get(site)
        if grade == was:
            continue
        if grade == "RED":
            why = "; ".join(str(r) for r in reasons.get(site, [])[:3]) or "no reason reported"
            events.append(Event(
                kind="rag", title=f"\U0001f534 {site} is RED",
                message=f"{site}: {was or 'unknown'} -> RED\n{why}",
                priority=P_LOUD, click=_console(console_url, "fleet"),
                dedupe=f"rag:{site}:{was}->{grade}"))
        elif grade == "GREEN" and was in ("RED", "AMBER"):
            events.append(Event(
                kind="rag", title=f"\U0001f7e2 {site} recovered",
                message=f"{site}: {was} -> GREEN",
                priority=P_QUIET, click=_console(console_url, "fleet"),
                dedupe=f"rag:{site}:{was}->{grade}"))
    return events, now


def detect_demo_tester(issues, issues_ok: bool, prev, gitlab_url: str = "",
                       label: str = "demo-tester") -> tuple[list[Event], dict]:
    """New GitLab issues carrying the demo-tester label. Keyed on issue iid, so
    edits to an already-seen issue stay quiet."""
    if not issues_ok or not isinstance(issues, list):
        return [], (prev if isinstance(prev, dict) else {})  # API down: never lose the high-water mark
    tagged = []
    for i in issues:
        if not isinstance(i, dict):
            continue
        labels = [str(x).lower() for x in (i.get("labels") or [])]
        if label.lower() in labels:
            try:
                tagged.append((int(i.get("iid", 0)), i))
            except (TypeError, ValueError):
                continue
    high = max((iid for iid, _ in tagged), default=0)
    if not isinstance(prev, dict) or "last_iid" not in prev:
        return [], {"last_iid": high}  # first run: seed silently
    last = int(prev.get("last_iid") or 0)
    events = []
    for iid, i in sorted(tagged):
        if iid <= last:
            continue
        title = str(i.get("title", ""))[:160]
        author = str((i.get("author") or {}).get("username", "?"))
        url = str(i.get("web_url", "")) or gitlab_url
        events.append(Event(
            kind="demo_tester", title=f"\U0001f4dd New tester report #{iid}",
            message=f"{title}\nfiled by {author}",
            priority=P_NORMAL, click=url, dedupe=f"issue:{iid}"))
    return events, {"last_iid": max(high, last)}


# What the demo reset log can say (see parsers.DEMO_EVENT_RE). Anything that
# is not reset-ok means the golden restore did not happen this cycle.
_RESET_BAD = {
    "reset-failed": ("⚠️", "reset FAILED", P_HIGH),
    "skip-floor": ("⏰", "reset SKIPPED (04:00 floor)", P_NORMAL),
    "skip-active": ("\U0001f465", "reset SKIPPED (testers active)", P_LOW),
}


def detect_demo_reset(demo_sites, prev, console_url: str = "") -> tuple[list[Event], dict]:
    """Daily demo reset outcome, from the event trail `pl demo status` prints.
    Fires when the latest outcome CHANGES to something that is not reset-ok."""
    if not isinstance(demo_sites, list):
        return [], (prev if isinstance(prev, dict) else {})
    now = {}
    for d in demo_sites:
        if not isinstance(d, dict):
            continue
        site, last = str(d.get("site", "")), str(d.get("last_event", "") or "")
        if site and last:
            now[site] = last
    if not isinstance(prev, dict):
        return [], now  # first run: seed silently
    events = []
    for site in sorted(now):
        last, was = now[site], prev.get(site)
        if last == was or last not in _RESET_BAD:
            continue
        icon, what, prio = _RESET_BAD[last]
        events.append(Event(
            kind="demo_reset", title=f"{icon} {site} demo {what}",
            message=f"{site}: last reset event is '{last}' (was '{was or 'unknown'}').\n"
                    f"The demo tier may be serving stale or dirty content.",
            priority=prio, click=_console(console_url, "demo"),
            dedupe=f"demo:{site}:{last}"))
    # Sites that vanished from the pane keep their old value out of the state.
    return events, now


# The credential-is-dying vocabulary, across BOTH emitters in lib/todo-checks.sh:
#   check_token_liveness -> "Token DEAD (revoked/invalid): <id>"
#                           "Token expiring soon: <id> (live expiry …)"
#   check_secret_expiry  -> "Secret EXPIRED <n> days ago: <id>"
#                           "Secret expires in <n> days: <id>"
#   check_token_rotation -> "Token rotation due: <id> (<n> days old)"
# Deliberately NOT matched: "Token rotation not tracked" and "<n> of <m>
# secret(s) have no recorded rotation" — those are registry hygiene nags that
# never change on their own, so pushing them is noise, not news.
_TOKEN_SIGNALS = (
    "token dead", "token expiring", "secret expired", "secret expires", "token rotation due",
)


def _is_token_item(item: dict) -> bool:
    text = str(item.get("text", "")).lower()
    return any(sig in text for sig in _TOKEN_SIGNALS)


def detect_token_expiry(todo: dict, prev, console_url: str = "") -> tuple[list[Event], dict]:
    """Dead/expiring tokens, reusing what `pl todo check --json` already
    computes from `pl secrets audit`. One push per token, not per poll; a token
    that is fixed and later re-expires notifies again."""
    if not todo.get("ok"):
        return [], (prev if isinstance(prev, dict) else {})
    current: dict[str, dict] = {}
    for it in todo.get("items", []):
        if isinstance(it, dict) and _is_token_item(it):
            key = str(it.get("check") or it.get("text", ""))[:80]
            if key:
                current[key] = it
    if not isinstance(prev, dict) or "notified" not in prev:
        return [], {"notified": sorted(current)}  # first run: seed silently
    seen = set(prev.get("notified") or [])
    events = []
    for key in sorted(current):
        if key in seen:
            continue
        it = current[key]
        prio = P_HIGH if str(it.get("priority", "")).lower() == "high" else P_LOW
        events.append(Event(
            kind="token_expiry", title=f"\U0001f511 Token needs attention: {key}",
            message=f"{str(it.get('text', ''))[:400]}\n\n{str(it.get('action', '')) or 'pl secrets steps ' + key}",
            priority=prio, click=_console(console_url, "todo"), dedupe=f"token:{key}"))
    return events, {"notified": sorted(current)}


def detect_ci(blocks, api_ok: bool, prev, console_url: str = "") -> tuple[list[Event], dict]:
    """Head-pipeline failures on open MRs. Keyed on project!iid -> pipeline:status,
    so a still-failing pipeline stays quiet until something actually changes."""
    if not api_ok or not isinstance(blocks, list):
        return [], (prev if isinstance(prev, dict) else {})
    now: dict[str, str] = {}
    meta: dict[str, dict] = {}
    for b in blocks:
        if not isinstance(b, dict):
            continue
        project = str(b.get("project", "?"))
        for row in b.get("mrs", []) or []:
            mr = (row or {}).get("mr") or {}
            pipe = (row or {}).get("pipeline") or {}
            if not pipe:
                continue
            key = f"{project}!{mr.get('iid', '?')}"
            now[key] = f"{pipe.get('id', '?')}:{str(pipe.get('status', '')).lower()}"
            meta[key] = {"mr": mr, "pipe": pipe, "project": project}
    if not isinstance(prev, dict):
        return [], now  # first run: seed silently
    events = []
    for key in sorted(now):
        val = now[key]
        if val == prev.get(key) or not val.endswith(":failed"):
            continue
        m = meta[key]
        title = str(m["mr"].get("title", ""))[:140]
        url = str(m["pipe"].get("web_url") or m["mr"].get("web_url", ""))
        events.append(Event(
            kind="ci", title=f"❌ CI failed on {key}",
            message=f"{title}\npipeline {m['pipe'].get('id', '?')} failed",
            priority=P_NORMAL, click=url or _console(console_url, "ci"),
            dedupe=f"ci:{key}:{val}"))
    return events, now


def due_for_brief(prev, at_hhmm: str, now_local: datetime) -> bool:
    """True at most once a day, at/after the configured local HH:MM. Missing a
    window (console down) just means it fires on the next check that day."""
    if not at_hhmm:
        return False
    try:
        hh, mm = (int(x) for x in at_hhmm.split(":", 1))
    except (ValueError, TypeError):
        return False
    if (now_local.hour, now_local.minute) < (hh, mm):
        return False
    today = now_local.strftime("%Y-%m-%d")
    last = (prev or {}).get("last") if isinstance(prev, dict) else None
    return last != today


# ---------------------------------------------------------------------------
# orchestration
# ---------------------------------------------------------------------------
def run_checks(gathered: dict, state: dict, console_url: str = "",
               enabled=None) -> tuple[list[Event], dict]:
    """Run every enabled detector over one gather. Returns (events, next state).

    Each detector is isolated: a broken or missing feed yields no events and
    leaves its own slice of state untouched, exactly like the tab-count
    gatherers. One bad feed can never suppress the others.
    """
    enabled = set(EVENT_KINDS) if enabled is None else set(enabled)
    state = dict(state) if isinstance(state, dict) else {}
    events: list[Event] = []

    plan = [
        ("rag", lambda: detect_rag(gathered.get("rag") or {}, state.get("rag"), console_url)),
        ("demo_tester", lambda: detect_demo_tester(
            gathered.get("issues"), bool(gathered.get("issues_ok")), state.get("demo_tester"),
            gathered.get("gitlab_url", ""))),
        ("demo_reset", lambda: detect_demo_reset(gathered.get("demo"), state.get("demo_reset"), console_url)),
        ("token_expiry", lambda: detect_token_expiry(
            gathered.get("todo") or {}, state.get("token_expiry"), console_url)),
        ("ci", lambda: detect_ci(gathered.get("ci"), bool(gathered.get("ci_ok")), state.get("ci"), console_url)),
    ]
    for kind, call in plan:
        if kind not in enabled:
            continue
        try:
            evs, next_state = call()
        except Exception:  # noqa: BLE001 — a broken feed must not stop the rest
            continue
        state[kind] = next_state
        events.extend(evs)
    return events, state


def deliver(notifier: Notifier, events, state: dict) -> tuple[int, int]:
    """Send events, stamping last_sent per kind. Returns (sent, failed).
    Never raises: delivery failures are counted, not propagated."""
    state.setdefault("last_sent", {})
    sent = failed = 0
    for ev in events:
        if notifier.send_event(ev):
            sent += 1
            state["last_sent"][ev.kind] = _now_iso()
        else:
            failed += 1
    return sent, failed
