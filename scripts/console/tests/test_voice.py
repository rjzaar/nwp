"""Voice: limits, audio cleanup, degradation, auth, and the no-action guarantee.

Nothing here needs whisper or piper installed — every test stubs the process
layer (`voice._run`) so the contract is tested, not the model. The one real
subprocess is `stt_worker.py`, exercised only through its argument contract.
"""
import json
import os
import subprocess
import sys
import tempfile
import wave
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import voice  # noqa: E402


@pytest.fixture(autouse=True)
def _clean_probes():
    voice.reset_probe_cache()
    yield
    voice.reset_probe_cache()


@pytest.fixture
def fw(monkeypatch):
    """Pretend faster-whisper is installed and healthy."""
    monkeypatch.setattr(voice, "stt_backend", lambda: "faster-whisper")
    return voice


def _worker_reply(obj: dict, rc: int = 0):
    class P:
        returncode = rc
        stdout = json.dumps(obj).encode()
        stderr = b""

    return P()


# ---------------------------------------------------------------------------
# availability / degradation
# ---------------------------------------------------------------------------
def test_no_backend_means_unavailable_not_a_crash(monkeypatch):
    monkeypatch.setattr(voice.config, "STT_BACKEND", "auto")
    monkeypatch.setattr(voice.config, "STT_PYTHON", "/nonexistent/python")
    monkeypatch.setattr(voice.config, "STT_WHISPER_CLI", "/nonexistent/whisper-cli")
    assert voice.stt_backend() == ""
    assert voice.stt_available() is False
    with pytest.raises(voice.VoiceUnavailable):
        voice.transcribe(b"anything")


def test_backend_off_short_circuits_without_probing(monkeypatch):
    calls = []
    monkeypatch.setattr(voice.config, "STT_BACKEND", "off")
    monkeypatch.setattr(voice, "_run", lambda *a, **k: calls.append(a))
    assert voice.stt_backend() == ""
    assert calls == []


def test_junk_model_name_disables_stt(monkeypatch):
    """The model name reaches a HF repo resolver — keep it boring or refuse."""
    monkeypatch.setattr(voice.config, "STT_BACKEND", "auto")
    monkeypatch.setattr(voice, "_faster_whisper_ok", lambda: True)
    for bad in ("../../etc/passwd", "base;rm -rf /", "", "a" * 200, "$(id)"):
        voice.reset_probe_cache()
        monkeypatch.setattr(voice.config, "STT_MODEL", bad)
        assert voice.stt_backend() == "", bad
    voice.reset_probe_cache()
    monkeypatch.setattr(voice.config, "STT_MODEL", "base.en")
    assert voice.stt_backend() == "faster-whisper"


def test_tts_unavailable_when_piper_absent(monkeypatch):
    monkeypatch.setattr(voice.config, "TTS_BACKEND", "auto")
    monkeypatch.setattr(voice.config, "TTS_PIPER", "/nonexistent/piper")
    assert voice.tts_available() is False
    with pytest.raises(voice.VoiceUnavailable):
        voice.synthesize("hello")


# ---------------------------------------------------------------------------
# limits
# ---------------------------------------------------------------------------
def test_oversize_audio_is_refused_before_any_process_spawns(fw, monkeypatch):
    spawned = []
    monkeypatch.setattr(voice.config, "STT_MAX_BYTES", 1024)
    monkeypatch.setattr(voice, "_run", lambda *a, **k: spawned.append(a))
    with pytest.raises(voice.AudioTooLarge):
        voice.transcribe(b"x" * 1025)
    assert spawned == [], "size cap must be enforced before we fork a transcriber"


def test_empty_audio_is_refused(fw):
    with pytest.raises(voice.AudioUnreadable):
        voice.transcribe(b"")


def test_max_seconds_is_handed_to_the_worker(fw, monkeypatch):
    seen = {}

    def fake_run(argv, timeout, **kw):
        seen["argv"] = argv
        return _worker_reply({"ok": True, "text": "hi", "duration": 1.0})

    monkeypatch.setattr(voice.config, "STT_MAX_SECONDS", 42)
    monkeypatch.setattr(voice.config, "STT_MODEL", "base")
    monkeypatch.setattr(voice, "_run", fake_run)
    voice.transcribe(b"audio")
    assert "42" in seen["argv"] and "base" in seen["argv"]


def test_worker_too_long_becomes_audio_too_long(fw, monkeypatch):
    monkeypatch.setattr(
        voice, "_run",
        lambda *a, **k: _worker_reply({"ok": False, "error": "too_long", "detail": "90.0s"}, rc=3),
    )
    with pytest.raises(voice.AudioTooLong):
        voice.transcribe(b"audio")


def test_worker_unreadable_becomes_audio_unreadable(fw, monkeypatch):
    monkeypatch.setattr(
        voice, "_run",
        lambda *a, **k: _worker_reply({"ok": False, "error": "unreadable", "detail": "bad header"}, rc=3),
    )
    with pytest.raises(voice.AudioUnreadable):
        voice.transcribe(b"not really audio")


def test_scratch_path_never_leaks_into_the_error(fw, monkeypatch):
    """Regression: PyAV quotes the filename it choked on, and that string was
    being handed straight to the browser in an HTTP body."""
    seen = {}

    def fake_run(argv, timeout, **kw):
        path = argv[2]
        seen["path"] = path
        return _worker_reply(
            {"ok": False, "error": "unreadable",
             "detail": f"InvalidDataError: Invalid data found when processing input: '{path}'"},
            rc=3,
        )

    monkeypatch.setattr(voice, "_run", fake_run)
    with pytest.raises(voice.AudioUnreadable) as e:
        voice.transcribe(b"not audio")
    assert seen["path"] not in str(e.value)
    assert "<audio>" in str(e.value)


def test_transcript_is_capped(fw, monkeypatch):
    monkeypatch.setattr(voice.config, "STT_MAX_CHARS", 20)
    monkeypatch.setattr(voice, "_run",
                        lambda *a, **k: _worker_reply({"ok": True, "text": "y" * 500, "duration": 3}))
    assert len(voice.transcribe(b"audio")["text"]) == 20


def test_timeout_is_reported_not_hung(fw, monkeypatch):
    def boom(*a, **k):
        raise subprocess.TimeoutExpired(cmd="stt", timeout=1)

    monkeypatch.setattr(voice, "_run", boom)
    with pytest.raises(voice.VoiceError) as e:
        voice.transcribe(b"audio")
    assert "timed out" in str(e.value)


# ---------------------------------------------------------------------------
# the audio never survives the request
# ---------------------------------------------------------------------------
def test_audio_file_exists_only_during_transcription_then_is_gone(fw, monkeypatch):
    seen = {}

    def fake_run(argv, timeout, **kw):
        path = argv[2]
        seen["path"] = path
        seen["existed"] = os.path.exists(path)
        seen["bytes"] = Path(path).read_bytes()
        seen["mode"] = os.stat(path).st_mode & 0o777
        return _worker_reply({"ok": True, "text": "hello there", "duration": 2.0})

    monkeypatch.setattr(voice, "_run", fake_run)
    out = voice.transcribe(b"OPUSPAYLOAD")
    assert out["text"] == "hello there"
    assert seen["existed"] is True
    assert seen["bytes"] == b"OPUSPAYLOAD"
    assert seen["mode"] == 0o600, "the scratch audio must not be world/group readable"
    assert not os.path.exists(seen["path"]), "audio must be deleted immediately after transcription"


def test_audio_is_deleted_even_when_the_transcriber_explodes(fw, monkeypatch):
    seen = {}

    def fake_run(argv, timeout, **kw):
        seen["path"] = argv[2]
        raise subprocess.TimeoutExpired(cmd="stt", timeout=1)

    monkeypatch.setattr(voice, "_run", fake_run)
    with pytest.raises(voice.VoiceError):
        voice.transcribe(b"audio")
    assert not os.path.exists(seen["path"]), "a failed/ timed-out transcription must not leak audio"


def test_no_audio_is_left_behind_in_the_scratch_dir(fw, monkeypatch):
    monkeypatch.setattr(voice, "_run",
                        lambda *a, **k: _worker_reply({"ok": True, "text": "ok", "duration": 1}))
    scratch = voice._scratch_dir()
    for _ in range(5):
        voice.transcribe(b"audio")
    assert list(scratch.glob("qk-*")) == []


def test_scratch_dir_is_private(monkeypatch):
    with tempfile.TemporaryDirectory() as tmp:
        monkeypatch.setattr(voice.config, "VOICE_TMPDIR", tmp)
        d = voice._scratch_dir()
        assert oct(os.stat(d).st_mode & 0o777) == "0o700"


def test_scratch_dir_refuses_a_symlink(monkeypatch):
    with tempfile.TemporaryDirectory() as tmp:
        base = Path(tmp)
        (base / "real").mkdir()
        (base / f"nwp-console-voice-{os.getuid()}").symlink_to(base / "real")
        monkeypatch.setattr(voice.config, "VOICE_TMPDIR", str(base))
        with pytest.raises(voice.VoiceError):
            voice._scratch_dir()


def test_shred_truncates_then_unlinks():
    fd, path = tempfile.mkstemp()
    os.write(fd, b"secret audio")
    os.close(fd)
    voice._shred(path)
    assert not os.path.exists(path)
    voice._shred(path)  # idempotent, never raises


def test_browser_filename_never_reaches_the_filesystem(fw, monkeypatch):
    """The route hands us bytes only — prove the temp name is ours, not theirs."""
    seen = {}
    monkeypatch.setattr(voice, "_run", lambda argv, timeout, **k: (
        seen.update(path=argv[2]) or _worker_reply({"ok": True, "text": "x", "duration": 1})))
    voice.transcribe(b"audio")
    name = Path(seen["path"]).name
    assert name.startswith("qk-") and name.endswith(".bin")


# ---------------------------------------------------------------------------
# speech out
# ---------------------------------------------------------------------------
def test_synthesize_wraps_raw_pcm_into_a_real_wav(monkeypatch, tmp_path):
    pcm = b"\x01\x02" * 1000
    monkeypatch.setattr(voice, "tts_backend", lambda: "piper")
    monkeypatch.setattr(voice.config, "TTS_VOICE", str(tmp_path / "v.onnx"))
    (tmp_path / "v.onnx.json").write_text(json.dumps({"audio": {"sample_rate": 22050}}))

    class P:
        returncode = 0
        stdout = pcm
        stderr = b""

    seen = {}
    monkeypatch.setattr(voice, "_run", lambda argv, timeout, stdin_bytes=None: (
        seen.update(argv=argv, text=stdin_bytes) or P()))
    data = voice.synthesize("  Two   sites are amber.\n")
    with wave.open(__import__("io").BytesIO(data)) as w:
        assert w.getnchannels() == 1 and w.getsampwidth() == 2 and w.getframerate() == 22050
        assert w.getnframes() == len(pcm) // 2
    assert seen["text"] == b"Two sites are amber."     # whitespace normalised
    assert "--output-raw" in seen["argv"]              # never writes audio to disk


def test_synthesize_caps_text_and_refuses_empty(monkeypatch):
    monkeypatch.setattr(voice, "tts_backend", lambda: "piper")
    seen = {}

    class P:
        returncode = 0
        stdout = b"\x00\x00"
        stderr = b""

    monkeypatch.setattr(voice.config, "TTS_MAX_CHARS", 10)
    monkeypatch.setattr(voice, "_run", lambda argv, timeout, stdin_bytes=None: (
        seen.update(text=stdin_bytes) or P()))
    voice.synthesize("z" * 500)
    assert len(seen["text"]) == 10
    with pytest.raises(voice.VoiceError):
        voice.synthesize("   ")


def test_synthesize_failure_is_a_voice_error(monkeypatch):
    monkeypatch.setattr(voice, "tts_backend", lambda: "piper")

    class P:
        returncode = 1
        stdout = b""
        stderr = b"no such voice"

    monkeypatch.setattr(voice, "_run", lambda *a, **k: P())
    with pytest.raises(voice.VoiceError):
        voice.synthesize("hello")


# ---------------------------------------------------------------------------
# the worker's own contract (the one real subprocess in this file)
# ---------------------------------------------------------------------------
def test_worker_emits_json_on_bad_arguments():
    p = subprocess.run([sys.executable, str(voice.WORKER), "only-one-arg"],
                       capture_output=True, text=True, timeout=60)
    assert p.returncode == 3
    obj = json.loads(p.stdout)
    assert obj["ok"] is False and obj["error"] == "failed"


def test_worker_classifies_undecodable_bytes_as_unreadable(tmp_path):
    """Junk bytes are a 400, not a 500 — and the path stays out of the reply.

    Skipped where faster-whisper isn't installed (the dev workstation); it runs
    for real on the console host.
    """
    pytest.importorskip("faster_whisper")
    junk = tmp_path / "junk.bin"
    junk.write_bytes(os.urandom(4096))
    p = subprocess.run([sys.executable, str(voice.WORKER), str(junk), "base", "60", "en"],
                       capture_output=True, text=True, timeout=300)
    obj = json.loads(p.stdout)
    assert obj["ok"] is False
    assert obj["error"] == "unreadable", obj
    assert str(junk) not in obj["detail"] and "<audio>" in obj["detail"]


def test_worker_selftest_matches_whether_faster_whisper_is_importable():
    p = subprocess.run([sys.executable, str(voice.WORKER), "--selftest"],
                       capture_output=True, text=True, timeout=120)
    try:
        import faster_whisper  # noqa: F401

        expected = 0
    except ImportError:
        expected = 1  # unhandled ImportError -> rc 1; the caller reads it as "no backend"
    assert p.returncode == expected


# ---------------------------------------------------------------------------
# structural guarantee: voice cannot act
# ---------------------------------------------------------------------------
def test_voice_has_no_action_path():
    """Voice may spawn a transcriber and a synthesiser — and NOTHING else. It
    must have no import path to the action allowlist or the `pl` runner, so a
    spoken sentence is exactly as (un)privileged as a typed one."""
    import ast
    import inspect

    tree = ast.parse(inspect.getsource(voice))
    imported = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            imported.extend(a.name for a in node.names)
        elif isinstance(node, ast.ImportFrom):
            imported.append(node.module or "")
            imported.extend(a.name for a in node.names)
    for forbidden in ("actions", "runner", "build_action", "ACTIONS"):
        assert not any(forbidden in str(i) for i in imported), f"voice imports {forbidden!r}"
    src = inspect.getsource(voice)
    assert "shell=True" not in src
    assert "os.system" not in src


def test_stt_worker_has_no_network_or_action_imports():
    import ast

    tree = ast.parse(voice.WORKER.read_text())
    imported = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            imported.extend(a.name for a in node.names)
        elif isinstance(node, ast.ImportFrom):
            imported.append(node.module or "")
    for forbidden in ("urllib", "requests", "socket", "subprocess", "actions", "runner"):
        assert not any(forbidden in str(i) for i in imported), f"worker imports {forbidden!r}"
