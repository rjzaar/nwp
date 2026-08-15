"""The Sessions tab — tmux on the console host, through the console's own gate.

WHY THIS EXISTS
    The operator's long-running work (agent sessions, `claude`, builds) must
    live ON the console host and survive the laptop dropping wifi. tmux is the
    survivor; the console tab is only the intermittent window onto it. That
    window is a REAL SHELL on the agent host, so the whole file is mostly about
    refusals:

      1. AUTH — the pane, the start-form, the terminal page and the WEBSOCKET
         are all unreachable unauthenticated, and the websocket (the shell
         itself) is owner-only. Proven behaviourally AND structurally (an AST
         net over @app.websocket, which test_route_scoping.py does not scan).
      2. NAMES — the session name is the ONLY user input on this surface. It is
         validated against one strict regex in one place; `; rm -rf /` shapes
         are refused BEFORE any subprocess is spawned (asserted with a spy,
         not inferred from the status code).
      3. HELP — every tab in PANES must be covered by the in-app help. This is
         the coverage net the help system always implied but never hung: it was
         observed RED against the pre-Sessions tree (Review and Visuals had no
         entry in the "panes" defs) before the content was written.
"""
import ast
import os
import sys
import tempfile
from pathlib import Path

import pytest

CONSOLE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(CONSOLE))

MAIN = CONSOLE / "app" / "main.py"


# ---------------------------------------------------------------------------
# fixtures — the review-pane idiom: module-scoped env, fresh app import
# ---------------------------------------------------------------------------
@pytest.fixture(scope="module")
def mod():
    pytest.importorskip("fastapi")
    pytest.importorskip("httpx")
    tmp = tempfile.mkdtemp(prefix="nwp-console-sessions-test-")
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
    # A real credential, because current_user (and therefore the websocket
    # gate) refuses a user with none — the cookie alone must never be enough.
    app_main.store.add_credential("rob", "cred-1", "cGs=", 0)
    app_main.store.add_user("olly", "operator")
    app_main.store.add_credential("olly", "cred-2", "cGs=", 0)
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
    headers = {"x-test-user": name} if name else {}
    return TestClient(mod.app, headers=headers)


def _session_cookie(mod, user="rob"):
    """A REAL signed session cookie — the websocket path reads the cookie
    itself (no Depends to override), so these tests exercise the real gate."""
    return f"{mod.config.SESSION_COOKIE}={mod._signer.dumps({'u': user})}"


# ---------------------------------------------------------------------------
# 1. help coverage — every tab must be covered by the in-app help
# ---------------------------------------------------------------------------
def test_every_tab_has_an_entry_in_the_panes_help(mod):
    """Observed RED before this feature: Review and Visuals were tabs with no
    row in help's "panes" defs. A tab the help does not mention is a surface
    the operator learns by clicking — on a console that reaches a shell,
    that is not acceptable. New tab without help = this goes red."""
    from app import help as help_mod

    sec = help_mod.get_section("panes")
    assert sec is not None
    terms = [r["term"].lower()
             for b in sec["blocks"] if b["kind"] == "defs" for r in b["rows"]]
    for pane, label in mod.PANES:
        assert any(label.lower() in t for t in terms), (
            f"tab {label!r} ({pane}) has no entry in the 'panes' help section"
        )


def test_sessions_has_its_own_help_section(mod):
    """The detach-safe workflow (start on the host, close the laptop freely,
    rejoin) is the point of the feature, so it gets its own section — same
    bar the other behavioural surfaces (rag, roles, projects) clear."""
    from app import help as help_mod

    sec = help_mod.get_section("sessions")
    assert sec is not None, "no help section 'sessions'"
    text = " ".join(_strings(sec)).lower()
    for must in ("tmux", "wifi", "detach", "owner"):
        assert must in text, f"sessions help never mentions {must!r}"


def _strings(obj):
    if isinstance(obj, str):
        yield obj
    elif isinstance(obj, dict):
        for v in obj.values():
            yield from _strings(v)
    elif isinstance(obj, (list, tuple)):
        for v in obj:
            yield from _strings(v)


# ---------------------------------------------------------------------------
# 2. the name validator — the ONLY user input on this surface
# ---------------------------------------------------------------------------
GOOD_NAMES = ["work", "claude-1", "ops_336", "a", "A" * 32]
BAD_NAMES = [
    "", " ", "; rm -rf /", "a; rm -rf /", "$(reboot)", "`id`", "a|b", "a&b",
    "-t", "--help", "-", "../x", "a/b", "a:b", "a.b", "a b", "=x",
    "a\nb", "a\tb", "ünïcode", "A" * 33, "'", '"', "a'b",
]


def test_good_names_are_accepted():
    from app import sessions as s

    for n in GOOD_NAMES:
        assert s.valid_name(n), f"{n!r} should be a valid session name"


@pytest.mark.parametrize("bad", BAD_NAMES, ids=[repr(b)[:20] for b in BAD_NAMES])
def test_hostile_names_are_refused(bad):
    from app import sessions as s

    assert not s.valid_name(bad), f"{bad!r} accepted as a session name"


def test_non_strings_are_refused():
    from app import sessions as s

    for bad in (None, 7, ["work"], b"work"):
        assert not s.valid_name(bad)


def test_new_session_never_spawns_for_a_hostile_name(monkeypatch):
    """The status code says refused; THIS says refused before any process was
    spawned — the difference between a 400 and a blind negation."""
    from app import sessions as s

    spawned = []
    monkeypatch.setattr(s.subprocess, "run",
                        lambda *a, **k: spawned.append(a) or None)
    for bad in BAD_NAMES:
        r = s.new_session(bad)
        assert not r["ok"] and "invalid" in r["error"].lower()
    assert spawned == [], f"a hostile name reached subprocess.run: {spawned[:2]}"


def test_attach_argv_is_exact_match_and_flag_proof():
    """tmux `-t name` is a PREFIX match ('work' would attach 'workbench');
    `=name` is exact. And the argv is a list — no shell ever sees the name."""
    from app import sessions as s

    argv = s.attach_argv("work")
    assert argv[0] == "tmux"
    assert "=work" in argv
    assert not any(a == "work" for a in argv), "bare name would prefix-match"


# ---------------------------------------------------------------------------
# 3. list/new — parsing and fail-closed reads
# ---------------------------------------------------------------------------
class _FakeProc:
    def __init__(self, rc=0, out="", err=""):
        self.returncode, self.stdout, self.stderr = rc, out, err


def test_list_sessions_parses_the_tmux_format(monkeypatch):
    from app import sessions as s

    out = ("work\t1785751838\t1\t3\tclaude\tmini\n"
           "idle\t1785658428\t0\t1\tbash\tmini\n")
    monkeypatch.setattr(s.subprocess, "run", lambda *a, **k: _FakeProc(0, out))
    r = s.list_sessions()
    assert r["ok"] and len(r["sessions"]) == 2
    w = r["sessions"][0]
    assert w["name"] == "work" and w["attached"] and w["windows"] == 3
    assert w["command"] == "claude"
    assert not r["sessions"][1]["attached"]


def test_no_tmux_server_is_an_empty_list_not_an_error(monkeypatch):
    from app import sessions as s

    monkeypatch.setattr(
        s.subprocess, "run",
        lambda *a, **k: _FakeProc(1, "", "no server running on /tmp/tmux-1000/default"))
    r = s.list_sessions()
    assert r["ok"] and r["sessions"] == []


def test_a_broken_tmux_is_an_error_not_an_empty_list(monkeypatch):
    """Fail closed: 'I could not look' must never render as 'no sessions'."""
    from app import sessions as s

    monkeypatch.setattr(s.subprocess, "run",
                        lambda *a, **k: _FakeProc(127, "", "tmux: command not found"))
    r = s.list_sessions()
    assert not r["ok"] and r["error"]

    def boom(*a, **k):
        raise OSError("no tmux binary")

    monkeypatch.setattr(s.subprocess, "run", boom)
    r = s.list_sessions()
    assert not r["ok"] and "tmux" in r["error"]


# ---------------------------------------------------------------------------
# 4. routes — auth refusals, then the owner path
# ---------------------------------------------------------------------------
def test_sessions_is_a_tab(mod):
    assert ("sessions", "Sessions") in mod.PANES


def test_unauthenticated_pane_is_refused(mod):
    r = _client(mod, name=None).get("/panes/sessions")
    assert r.status_code == 401


def test_unauthenticated_start_is_refused(mod, monkeypatch):
    from app import sessions as s

    spawned = []
    monkeypatch.setattr(s.subprocess, "run", lambda *a, **k: spawned.append(a) or None)
    r = _client(mod, name=None).post("/sessions/new", data={"name": "work"})
    assert r.status_code == 401
    assert spawned == []


def test_unauthenticated_terminal_page_is_refused(mod):
    r = _client(mod, name=None).get("/sessions/term/work")
    assert r.status_code == 401


def test_a_viewer_gets_no_session_data(mod, monkeypatch):
    from app import sessions as s

    spawned = []
    monkeypatch.setattr(s.subprocess, "run", lambda *a, **k: spawned.append(a) or None)
    body = _client(mod, name="vera").get("/panes/sessions").text
    assert "owner" in body.lower()          # the refusal explains itself
    assert spawned == [], "a viewer's pane load ran tmux"


def test_a_non_owner_cannot_start_or_join(mod):
    c = _client(mod, name="olly")           # global OPERATOR — still not enough
    assert c.post("/sessions/new", data={"name": "work"}).status_code == 403
    assert c.get("/sessions/term/work").status_code == 403


def test_the_owner_sees_the_sessions_and_the_start_form(mod, monkeypatch):
    from app import sessions as s

    monkeypatch.setattr(
        s.subprocess, "run",
        lambda *a, **k: _FakeProc(0, "work\t1785751838\t1\t3\tclaude\tmini\n"))
    body = _client(mod).get("/panes/sessions").text
    assert "work" in body and "claude" in body
    assert "/sessions/new" in body          # the start form
    assert "/sessions/term/work" in body    # the jump-in link


def test_a_hostile_name_is_refused_at_the_route_too(mod, monkeypatch):
    from app import sessions as s

    spawned = []
    monkeypatch.setattr(s.subprocess, "run", lambda *a, **k: spawned.append(a) or None)
    r = _client(mod).post("/sessions/new", data={"name": "; rm -rf /"})
    assert r.status_code == 400
    assert spawned == []


def test_the_owner_can_start_a_session(mod, monkeypatch):
    from app import sessions as s

    calls = []

    def fake_run(argv, **k):
        calls.append(list(argv))
        if "list-sessions" in argv:
            return _FakeProc(0, "")
        return _FakeProc(0, "")

    monkeypatch.setattr(s.subprocess, "run", fake_run)
    r = _client(mod).post("/sessions/new", data={"name": "work"})
    assert r.status_code == 200
    started = [c for c in calls if "new-session" in c]
    assert started and "work" in " ".join(started[0])


def test_terminal_page_refuses_a_hostile_name_before_rendering(mod):
    r = _client(mod).get("/sessions/term/%3B%20rm%20-rf")
    assert r.status_code == 400


# ---------------------------------------------------------------------------
# 5. the websocket — the shell itself
# ---------------------------------------------------------------------------
def test_unauthenticated_websocket_is_refused(mod):
    """THE refusal this feature must prove: no cookie, no shell."""
    from starlette.websockets import WebSocketDisconnect

    c = _client(mod, name=None)
    with pytest.raises(WebSocketDisconnect) as e:
        with c.websocket_connect("/sessions/ws/work"):
            pass
    assert e.value.code == 1008


def test_a_garbage_cookie_websocket_is_refused(mod):
    from starlette.websockets import WebSocketDisconnect

    c = _client(mod, name=None)
    with pytest.raises(WebSocketDisconnect) as e:
        with c.websocket_connect(
                "/sessions/ws/work",
                headers={"cookie": f"{mod.config.SESSION_COOKIE}=forged"}):
            pass
    assert e.value.code == 1008


def test_a_non_owner_websocket_is_refused(mod):
    from starlette.websockets import WebSocketDisconnect

    c = _client(mod, name=None)
    with pytest.raises(WebSocketDisconnect) as e:
        with c.websocket_connect(
                "/sessions/ws/work",
                headers={"cookie": _session_cookie(mod, "olly")}):
            pass
    assert e.value.code == 1008


def test_a_hostile_name_websocket_is_refused_before_any_pty(mod, monkeypatch):
    from starlette.websockets import WebSocketDisconnect

    from app import sessions as s

    forked = []
    monkeypatch.setattr(s, "bridge", lambda *a, **k: forked.append(a))
    c = _client(mod, name=None)
    with pytest.raises(WebSocketDisconnect):
        with c.websocket_connect(
                "/sessions/ws/bad;name",
                headers={"cookie": _session_cookie(mod, "rob")}):
            pass
    assert forked == []


def test_a_cross_origin_websocket_is_refused(mod):
    """SameSite=strict keeps the cookie off a cross-site handshake in real
    browsers, but the server must not depend on browser behaviour alone."""
    from starlette.websockets import WebSocketDisconnect

    c = _client(mod, name=None)
    with pytest.raises(WebSocketDisconnect) as e:
        with c.websocket_connect(
                "/sessions/ws/work",
                headers={"cookie": _session_cookie(mod, "rob"),
                         "origin": "https://evil.example"}):
            pass
    assert e.value.code == 1008


def test_the_owner_websocket_reaches_a_pty_and_round_trips(mod, monkeypatch):
    """The one positive control: with the real cookie gate passed, the bridge
    really is a live pty round trip (stub argv, not tmux, so CI needs no tmux
    server). Without this, every refusal above could be a broken route."""
    from app import sessions as s

    monkeypatch.setattr(s, "attach_argv",
                        lambda name: ["sh", "-c", "printf READY; cat"])
    c = _client(mod, name=None)
    with c.websocket_connect(
            "/sessions/ws/work",
            headers={"cookie": _session_cookie(mod, "rob")}) as ws:
        buf = b""
        while b"READY" not in buf:
            buf += ws.receive_bytes()
        ws.send_text("0hello-tmux\r")
        buf = b""
        while b"hello-tmux" not in buf:
            buf += ws.receive_bytes()


# ---------------------------------------------------------------------------
# 6. the structural net — tomorrow's websocket route cannot skip the gate
# ---------------------------------------------------------------------------
def _ws_routes():
    tree = ast.parse(MAIN.read_text())
    out = []
    for node in ast.walk(tree):
        if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        for dec in node.decorator_list:
            f = dec.func if isinstance(dec, ast.Call) else dec
            if (isinstance(f, ast.Attribute) and f.attr == "websocket"
                    and isinstance(f.value, ast.Name) and f.value.id == "app"):
                out.append(node)
    return out


def test_websocket_routes_exist():
    """Guard: the net below is parametrized over a computed list; an empty
    list would make it vacuous."""
    assert _ws_routes(), "no @app.websocket routes found in main.py"


def test_every_websocket_route_calls_the_owner_gate():
    """test_route_scoping.py's AST pass scans get/post/put/delete/patch — NOT
    @app.websocket. This is the equivalent net for the socket surface: every
    websocket route must call _ws_owner (the cookie+role+origin gate) and
    must do so BEFORE accept() — a shell handed out first and checked second
    is a shell handed out."""
    for fn in _ws_routes():
        names = []
        for n in ast.walk(fn):
            if isinstance(n, ast.Call):
                f = n.func
                names.append(f.attr if isinstance(f, ast.Attribute) else getattr(f, "id", ""))
        assert "_ws_owner" in names, f"websocket route {fn.name!r} never calls _ws_owner"
        assert "accept" in names, f"websocket route {fn.name!r} never accepts (dead route?)"
        src = ast.unparse(fn)
        assert src.index("_ws_owner") < src.index("accept"), (
            f"websocket route {fn.name!r} accepts before it authenticates"
        )
