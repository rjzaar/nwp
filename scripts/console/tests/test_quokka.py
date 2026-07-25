"""Quokka: context-block builder, degradation path, and app smoke.

The smoke tests import the FastAPI app with a stubbed environment (tmp data
dir, ollama pointed at a dead loopback port) and an overridden session dep —
they need fastapi+httpx installed (skipped otherwise, e.g. in a bare venv).
"""
import json
import os
import sys
import tempfile
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import quokka  # noqa: E402

# ---------------------------------------------------------------------------
# context builder (pure)
# ---------------------------------------------------------------------------
FULL_STATE = {
    "generated": "2026-07-25 03:00 UTC",
    "rag": {"ok": True, "counts": {"RED": 1, "AMBER": 0, "GREEN": 2, "OTHER": 0},
            "sites": [{"site": "avc", "grade": "RED"}, {"site": "nwc", "grade": "GREEN"},
                      {"site": "nwt", "grade": "GREEN"}]},
    "issues_ok": True,
    "issues": [{"iid": 140, "title": "Demo tester: broken save button"},
               {"iid": 139, "title": "CI flake"}],
    "todo": {"ok": True, "items": [{"priority": "high"}, {"priority": "low"}]},
    "demo": [{"site": "nwd", "live_codes": 3, "last_event": "reset-ok"}],
    "ci_ok": True,
    "ci": [{"project": "nwp/nwp",
            "mrs": [{"mr": {"iid": 155, "title": "demo tier"}, "pipeline": {"status": "success"}}]}],
}


def test_render_context_carries_live_facts():
    ctx = quokka.render_context(FULL_STATE)
    assert "LIVE STATE" in ctx and "read-only" in ctx
    assert "red=1 (avc)" in ctx
    assert "green=2 (nwc, nwt)" in ctx
    assert "Open issues: 2" in ctx and "#140" in ctx and "broken save button" in ctx
    assert "Todo: 2 items (1 high)" in ctx
    assert "Demo nwd: 3 live invite codes" in ctx and "reset-ok" in ctx
    assert "!155" in ctx and "success" in ctx


def test_render_context_degrades_per_feed_never_raises():
    ctx = quokka.render_context({})
    assert "Fleet RAG: unavailable" in ctx
    assert "Open issues: unavailable" in ctx
    assert "Todo: unavailable" in ctx
    assert "CI: unavailable" in ctx
    # actively hostile shapes
    ctx = quokka.render_context(
        {"rag": "nope", "issues": {"not": "a list"}, "issues_ok": True,
         "todo": 7, "demo": [None, {"site": "nwd"}], "ci": 3, "ci_ok": True}
    )
    assert "LIVE STATE" in ctx  # rendered, no exception


def test_build_messages_shape_and_caps():
    hist = [{"role": "user", "content": "hi"}, {"role": "assistant", "content": "hello"},
            {"role": "hacker", "content": "ignored"}, {"role": "user", "content": ""}]
    msgs = quokka.build_messages("CTX", hist, "what's red?")
    assert msgs[0]["role"] == "system" and "Quokka" in msgs[0]["content"]
    assert "never invent" in msgs[0]["content"].lower()
    assert [m["role"] for m in msgs[1:-1]] == ["user", "assistant"]  # bad turns dropped
    assert msgs[-1]["role"] == "user"
    assert msgs[-1]["content"].startswith("CTX")       # context injected
    assert msgs[-1]["content"].endswith("what's red?")
    # history is capped
    big = [{"role": "user", "content": "x" * 2000}] * 50
    assert len(quokka.build_messages("CTX", big, "q")) <= 14


def test_chat_stream_unreachable_raises_quokka_error():
    with pytest.raises(quokka.QuokkaError):
        list(quokka.chat_stream("http://127.0.0.1:9", "any-model", [{"role": "user", "content": "hi"}], timeout=2))


def test_alive_false_on_dead_port():
    assert quokka.alive("http://127.0.0.1:9", timeout=1) is False


# ---------------------------------------------------------------------------
# app smoke: /panes/quokka renders; /quokka/brief 503s when ollama is absent
# ---------------------------------------------------------------------------
@pytest.fixture(scope="module")
def client():
    pytest.importorskip("fastapi")
    pytest.importorskip("httpx")
    tmp = tempfile.mkdtemp(prefix="nwp-console-test-")
    os.environ["NWP_CONSOLE_DATA"] = tmp
    os.environ["NWP_CONSOLE_QUOKKA_URL"] = "http://127.0.0.1:9"  # dead: Quokka asleep
    os.environ["NWP_CONSOLE_ROOT"] = tmp  # no pl here; panes degrade, never crash
    for m in list(sys.modules):
        if m == "app" or m.startswith("app."):
            del sys.modules[m]
    from app import main as app_main
    from fastapi.testclient import TestClient

    app_main.app.dependency_overrides[app_main.current_user] = lambda: {"name": "t", "role": "viewer"}
    return TestClient(app_main.app)


def test_health(client):
    assert client.get("/health").json()["ok"] is True


def test_index_has_all_seven_tabs(client):
    html = client.get("/").text
    for pane in ("fleet", "issues", "todo", "demo", "backups", "ci", "quokka"):
        assert f'id="tab-{pane}"' in html
        assert f'id="tabcount-{pane}"' in html
    assert 'hx-get="/tabs/counts"' in html
    assert "localStorage" in html  # active tab persisted


def test_tab_counts_endpoint_degrades_not_blocks(client):
    r = client.get("/tabs/counts")
    assert r.status_code == 200
    assert 'hx-swap-oob' in r.text
    assert 'id="tabcount-quokka"' in r.text
    assert "💤" in r.text  # ollama stubbed dead → asleep dot, not an error


def test_quokka_pane_renders_asleep(client):
    r = client.get("/panes/quokka")
    assert r.status_code == 200
    assert "asleep" in r.text
    assert "qk-form" in r.text


def test_quokka_chat_degrades_politely(client):
    r = client.post("/quokka/chat", data={"message": "hello", "history": "[]"})
    assert r.status_code == 200
    assert "asleep" in r.text


def test_quokka_brief_503_when_ollama_absent(client):
    r = client.get("/quokka/brief")
    assert r.status_code == 503
    assert "asleep" in r.json()["detail"]


def test_chat_has_no_action_path():
    """Structural guarantee: quokka.py imports NOTHING that can act (no
    actions map, no runner, no subprocess) — chat cannot trigger actions."""
    import ast
    import inspect

    tree = ast.parse(inspect.getsource(quokka))
    imported = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            imported.extend(a.name for a in node.names)
        elif isinstance(node, ast.ImportFrom):
            imported.append(node.module or "")
            imported.extend(a.name for a in node.names)
    for forbidden in ("actions", "runner", "subprocess", "os"):
        assert not any(forbidden in str(i) for i in imported), f"quokka imports {forbidden!r}"


def test_invite_route_requires_operator(client):
    # viewer session (from the fixture) must be refused
    r = client.post("/actions/invite", data={"site": "nwd"})
    assert r.status_code == 403
