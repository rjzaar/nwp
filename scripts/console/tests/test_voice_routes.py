"""/quokka/stt + /quokka/tts as routes: auth, roles, limits, audit, degradation.

The transcriber is stubbed throughout — this file is about the HTTP contract
and what lands in the audit log (transcript yes, audio never).
"""
import json
import os
import sys
import tempfile
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))


@pytest.fixture(scope="module")
def env():
    tmp = tempfile.mkdtemp(prefix="nwp-console-voice-test-")
    os.environ["NWP_CONSOLE_DATA"] = tmp
    os.environ["NWP_CONSOLE_QUOKKA_URL"] = "http://127.0.0.1:9"  # ollama dead
    os.environ["NWP_CONSOLE_ROOT"] = tmp
    os.environ["NWP_CONSOLE_STT_BACKEND"] = "off"   # nothing real is ever invoked
    os.environ["NWP_CONSOLE_TTS_BACKEND"] = "off"
    for m in list(sys.modules):
        if m == "app" or m.startswith("app."):
            del sys.modules[m]
    return tmp


@pytest.fixture(scope="module")
def mod(env):
    pytest.importorskip("fastapi")
    pytest.importorskip("httpx")
    from app import main as app_main

    return app_main


@pytest.fixture
def client(mod):
    from fastapi.testclient import TestClient

    mod.app.dependency_overrides[mod.current_user] = lambda: {"name": "t", "role": "viewer"}
    yield TestClient(mod.app)
    mod.app.dependency_overrides.clear()


@pytest.fixture
def anon(mod):
    """No session at all — the auth gate must fire before anything else."""
    from fastapi.testclient import TestClient

    mod.app.dependency_overrides.clear()
    return TestClient(mod.app)


def _audit_tail(mod):
    """Oldest-first, so [-1] is the entry the test just caused (AuditLog.tail
    hands back newest-first for the /audit page)."""
    return list(reversed(mod.audit.tail(20)))


def _wav(blob=b"fake-opus-bytes"):
    return {"audio": ("clip.webm", blob, "audio/webm")}


# ---------------------------------------------------------------------------
# auth
# ---------------------------------------------------------------------------
def test_stt_requires_a_session(anon):
    r = anon.post("/quokka/stt", files=_wav())
    assert r.status_code == 401


def test_tts_requires_a_session(anon):
    r = anon.post("/quokka/tts", data={"text": "hello"})
    assert r.status_code == 401


def test_viewer_may_use_voice(client, mod, monkeypatch):
    """Voice is viewer+ — the same bar as typing, because it IS typing."""
    monkeypatch.setattr(mod.voice, "stt_available", lambda: True)
    monkeypatch.setattr(mod.voice, "transcribe",
                        lambda b: {"text": "what is red", "duration": 2.0, "secs": 0.9,
                                   "backend": "faster-whisper"})
    r = client.post("/quokka/stt", files=_wav())
    assert r.status_code == 200
    assert r.json()["transcript"] == "what is red"


def test_cross_origin_post_refused(client, mod, monkeypatch):
    monkeypatch.setattr(mod.voice, "stt_available", lambda: True)
    monkeypatch.setattr(mod.voice, "transcribe", lambda b: {"text": "x", "duration": 1, "secs": 1, "backend": "b"})
    r = client.post("/quokka/stt", files=_wav(), headers={"Origin": "https://evil.example"})
    assert r.status_code == 403


# ---------------------------------------------------------------------------
# degradation
# ---------------------------------------------------------------------------
def test_stt_503_with_a_friendly_line_when_no_backend(client):
    r = client.post("/quokka/stt", files=_wav())
    assert r.status_code == 503
    detail = r.json()["detail"]
    assert "type instead" in detail.lower()


def test_tts_503_when_piper_absent(client):
    r = client.post("/quokka/tts", data={"text": "hello"})
    assert r.status_code == 503


def test_quokka_pane_hides_the_mic_when_stt_is_unavailable(client):
    html = client.get("/panes/quokka").text
    assert 'id="qk-mic"' not in html
    assert "isn't installed on this host" in html
    assert 'id="qk-speak"' in html, "browser speech-out is offered even with no server voice"


def test_quokka_pane_shows_the_mic_when_stt_is_available(client, mod, monkeypatch):
    monkeypatch.setattr(mod.voice, "stt_available", lambda: True)
    html = client.get("/panes/quokka").text
    assert 'id="qk-mic"' in html
    assert "never leave the mesh" in html or "never stored" in html


def test_pane_never_uses_the_browser_speech_recognition_api(client, mod, monkeypatch):
    """Brave/Chromium's SpeechRecognition uploads audio to Google. Not here."""
    monkeypatch.setattr(mod.voice, "stt_available", lambda: True)
    html = client.get("/panes/quokka").text
    assert "webkitSpeechRecognition" not in html
    assert "new SpeechRecognition" not in html
    assert "MediaRecorder" in html


# ---------------------------------------------------------------------------
# limits
# ---------------------------------------------------------------------------
def test_oversize_upload_is_413(client, mod, monkeypatch):
    monkeypatch.setattr(mod.voice, "stt_available", lambda: True)
    monkeypatch.setattr(mod.config, "STT_MAX_BYTES", 64)

    def refuse(blob):
        raise mod.voice.AudioTooLarge("recording is larger than 0 MB")

    monkeypatch.setattr(mod.voice, "transcribe", refuse)
    r = client.post("/quokka/stt", files=_wav(b"x" * 500))
    assert r.status_code == 413


def test_over_long_audio_is_413(client, mod, monkeypatch):
    monkeypatch.setattr(mod.voice, "stt_available", lambda: True)

    def refuse(blob):
        raise mod.voice.AudioTooLong("75.0s exceeds the 60s limit")

    monkeypatch.setattr(mod.voice, "transcribe", refuse)
    r = client.post("/quokka/stt", files=_wav())
    assert r.status_code == 413
    assert "60s" in r.json()["detail"]


def test_undecodable_audio_is_400(client, mod, monkeypatch):
    monkeypatch.setattr(mod.voice, "stt_available", lambda: True)

    def refuse(blob):
        raise mod.voice.AudioUnreadable("bad header")

    monkeypatch.setattr(mod.voice, "transcribe", refuse)
    assert client.post("/quokka/stt", files=_wav()).status_code == 400


def test_the_route_reads_at_most_the_cap_plus_one(client, mod, monkeypatch):
    """A 40-minute upload must not be buffered whole before we refuse it."""
    seen = {}
    monkeypatch.setattr(mod.voice, "stt_available", lambda: True)
    monkeypatch.setattr(mod.config, "STT_MAX_BYTES", 100)

    def cap(blob):
        seen["len"] = len(blob)
        raise mod.voice.AudioTooLarge("too big")

    monkeypatch.setattr(mod.voice, "transcribe", cap)
    client.post("/quokka/stt", files=_wav(b"y" * 50_000))
    assert seen["len"] == 101


# ---------------------------------------------------------------------------
# audit: the transcript is recorded, the audio is not
# ---------------------------------------------------------------------------
def test_audit_records_the_transcript_and_never_the_audio(client, mod, monkeypatch):
    monkeypatch.setattr(mod.voice, "stt_available", lambda: True)
    monkeypatch.setattr(mod.voice, "transcribe",
                        lambda b: {"text": "is anything red today", "duration": 3.1, "secs": 1.2,
                                   "backend": "faster-whisper"})
    client.post("/quokka/stt", files=_wav(b"SECRETAUDIOBYTES"))
    entry = [e for e in _audit_tail(mod) if e["action"] == "quokka.stt"][-1]
    assert entry["ok"] is True
    assert entry["user"] == "t" and entry["role"] == "viewer"
    assert entry["detail"]["transcript"] == "is anything red today"
    assert entry["detail"]["audio_bytes"] == len(b"SECRETAUDIOBYTES")
    blob = json.dumps(entry)
    assert "SECRETAUDIOBYTES" not in blob, "raw audio must never reach the audit log"


def test_audit_records_stt_failures_too(client, mod, monkeypatch):
    monkeypatch.setattr(mod.voice, "stt_available", lambda: True)

    def boom(blob):
        raise mod.voice.AudioTooLong("90s")

    monkeypatch.setattr(mod.voice, "transcribe", boom)
    client.post("/quokka/stt", files=_wav())
    entry = [e for e in _audit_tail(mod) if e["action"] == "quokka.stt"][-1]
    assert entry["ok"] is False and "too_long" in entry["detail"]["error"]


def test_tts_audits_use_not_content(client, mod, monkeypatch):
    monkeypatch.setattr(mod.voice, "tts_backend", lambda: "piper")
    monkeypatch.setattr(mod.voice, "synthesize", lambda t: b"RIFFfake")
    r = client.post("/quokka/tts", data={"text": "two sites are amber"})
    assert r.status_code == 200
    assert r.headers["content-type"].startswith("audio/wav")
    assert r.headers["cache-control"] == "no-store"
    entry = [e for e in _audit_tail(mod) if e["action"] == "quokka.tts"][-1]
    assert entry["detail"]["chars"] == len("two sites are amber")
    assert "two sites are amber" not in json.dumps(entry), "the reply text is already audited by quokka.chat"
