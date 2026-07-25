"""Voice for Quokka — speech in (STT) and speech out (TTS), 100% on this host.

Trust properties (hold the line on these in review):

  * NO CLOUD SPEECH, EVER. Recognition runs in a faster-whisper (or
    whisper.cpp) process on the console host; synthesis runs in a local piper
    process. The browser's built-in `SpeechRecognition` is deliberately NOT
    used anywhere in this app — Chromium and Brave implement it by shipping
    your microphone audio to Google. The only in-browser speech we will touch
    is `speechSynthesis` (output only, no audio leaves the device), and only
    as the fallback when this host has no piper.
  * AUDIO IS NEVER PERSISTED. The upload lands in a 0600 file in a 0700
    scratch dir, is truncated and unlinked in a `finally`, and nothing about
    it reaches the audit log — the audit log records the TRANSCRIPT (same as a
    typed message) plus sizes/timings, never the bytes.
  * NO ACTION PATH. This module can transcribe and synthesise; it has no
    import of actions.py/runner.py and cannot build or run a `pl` command. The
    transcript re-enters the SAME read-only Quokka pipeline as typed text, so
    speaking to Quokka is exactly as (un)privileged as typing to it.
  * Fixed argv, never a shell. The only interpolated value is a path WE
    generated (`mkstemp`); the browser-supplied filename is discarded, and the
    model name is regex-validated before it can reach the HF hub resolver.
  * Degrades politely. No backend installed => `available()` is False, the mic
    button never renders, and /quokka/stt answers 503 with a friendly line
    while every other tab keeps working.

Honest new attack surface (say it out loud in review): an authenticated
viewer+ can now feed arbitrary bytes to a media decoder (PyAV/ffmpeg) on the
console host. That is a big C surface. It is bounded by: WebAuthn + the mesh
(no anonymous reach), a size cap before the bytes touch disk, a duration cap,
a hard subprocess timeout, and the decode happening in a short-lived child
process rather than in uvicorn.
"""
from __future__ import annotations

import io
import json
import os
import re
import stat
import subprocess
import tempfile
import time
import wave
from pathlib import Path

from . import config

WORKER = Path(__file__).resolve().parent / "stt_worker.py"

# Model names reach a HuggingFace repo resolver / a file path — keep them boring.
_MODEL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/-]{0,63}$")

PROBE_TTL = 300  # seconds; a backend appearing/vanishing is a deploy-time event


class VoiceError(Exception):
    """Any voice failure. `kind` maps to the HTTP status the route returns."""

    kind = "failed"


class VoiceUnavailable(VoiceError):
    kind = "unavailable"


class AudioTooLarge(VoiceError):
    kind = "too_large"


class AudioTooLong(VoiceError):
    kind = "too_long"


class AudioUnreadable(VoiceError):
    kind = "unreadable"


_KINDS = {
    "too_long": AudioTooLong,
    "unreadable": AudioUnreadable,
    "no_backend": VoiceUnavailable,
}


# ---------------------------------------------------------------------------
# process plumbing (fixed argv, sanitised env, hard timeout — never raises OSError)
# ---------------------------------------------------------------------------
def _env() -> dict:
    return {
        "HOME": os.environ.get("HOME", "/tmp"),
        "PATH": os.environ.get("PATH", "/usr/local/bin:/usr/bin:/bin"),
        "LANG": "C.UTF-8",
        "NO_COLOR": "1",
        "HF_HUB_DISABLE_TELEMETRY": "1",
        "OMP_NUM_THREADS": str(config.STT_THREADS),
        "TOKENIZERS_PARALLELISM": "false",
    }


def _run(argv: list[str], timeout: int, stdin_bytes: bytes | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(  # noqa: S603 — fixed argv, no shell, sanitised env
        argv,
        input=stdin_bytes,
        capture_output=True,
        timeout=timeout,
        env=_env(),
        stdin=None if stdin_bytes is not None else subprocess.DEVNULL,
    )


def _scratch_dir() -> Path:
    """A 0700 dir we own, for audio that lives for milliseconds.

    Refuses to use a path that isn't a real directory owned by us (symlink /
    other-uid squatting in a shared /tmp).
    """
    d = Path(config.VOICE_TMPDIR or tempfile.gettempdir()) / f"nwp-console-voice-{os.getuid()}"
    d.mkdir(parents=True, exist_ok=True, mode=0o700)
    st = os.lstat(d)
    if stat.S_ISLNK(st.st_mode) or not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid():
        raise VoiceError(f"refusing to use scratch dir {d} (not a directory we own)")
    os.chmod(d, 0o700)
    return d


def _shred(path: str) -> None:
    """Drop the blocks, then the name. Best-effort and never raises."""
    try:
        with open(path, "r+b") as fh:
            fh.truncate(0)
            fh.flush()
            os.fsync(fh.fileno())
    except OSError:
        pass
    try:
        os.unlink(path)
    except OSError:
        pass


# ---------------------------------------------------------------------------
# availability probes (TTL-cached: they cost a process spawn)
# ---------------------------------------------------------------------------
_probe_cache: dict[str, tuple[float, object]] = {}


def _cached(key: str, fn):
    now = time.time()
    hit = _probe_cache.get(key)
    if hit and now - hit[0] < PROBE_TTL:
        return hit[1]
    try:
        val = fn()
    except Exception:  # noqa: BLE001 — a probe must never break a page render
        val = ""
    _probe_cache[key] = (now, val)
    return val


def reset_probe_cache() -> None:
    """Tests (and a future `pl console status`) want a fresh look."""
    _probe_cache.clear()


def _faster_whisper_ok() -> bool:
    py = Path(config.STT_PYTHON)
    if not py.is_file() or not os.access(py, os.X_OK) or not WORKER.is_file():
        return False
    try:
        return _run([str(py), str(WORKER), "--selftest"], timeout=30).returncode == 0
    except (subprocess.TimeoutExpired, OSError):
        return False


def _whisper_cli_ok() -> bool:
    cli, model = Path(config.STT_WHISPER_CLI), Path(config.STT_WHISPER_MODEL_FILE)
    return cli.is_file() and os.access(cli, os.X_OK) and model.is_file()


def stt_backend() -> str:
    """'faster-whisper' | 'whisper-cli' | '' (none available)."""
    want = (config.STT_BACKEND or "auto").strip().lower()
    if want == "off" or not _MODEL_RE.match(config.STT_MODEL or ""):
        return ""

    def probe() -> str:
        if want in ("auto", "faster-whisper") and _faster_whisper_ok():
            return "faster-whisper"
        if want in ("auto", "whisper-cli") and _whisper_cli_ok():
            return "whisper-cli"
        return ""

    return str(_cached(f"stt:{want}", probe))


def stt_available() -> bool:
    return bool(stt_backend())


def tts_backend() -> str:
    """'piper' | '' — empty means the browser's speechSynthesis is the only TTS."""
    if (config.TTS_BACKEND or "auto").strip().lower() == "off":
        return ""

    def probe() -> str:
        binary, voice = Path(config.TTS_PIPER), Path(config.TTS_VOICE)
        if binary.is_file() and os.access(binary, os.X_OK) and voice.is_file():
            return "piper"
        return ""

    return str(_cached("tts", probe))


def tts_available() -> bool:
    return bool(tts_backend())


# ---------------------------------------------------------------------------
# speech IN
# ---------------------------------------------------------------------------
def transcribe(audio: bytes) -> dict:
    """Audio bytes -> {"text", "duration", "secs", "backend"}.

    The caller has already enforced auth. We enforce size, duration, time and
    cleanup. The bytes touch disk for as long as one subprocess runs and no
    longer; the browser-supplied filename is never used.
    """
    backend = stt_backend()
    if not backend:
        raise VoiceUnavailable("no speech-to-text backend on this host")
    if not audio:
        raise AudioUnreadable("empty recording")
    if len(audio) > config.STT_MAX_BYTES:
        raise AudioTooLarge(f"recording is larger than {config.STT_MAX_BYTES // (1024 * 1024)} MB")

    started = time.time()
    fd, path = tempfile.mkstemp(prefix="qk-", suffix=".bin", dir=str(_scratch_dir()))
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as fh:
            fh.write(audio)
        if backend == "faster-whisper":
            text, duration = _stt_faster_whisper(path)
        else:
            text, duration = _stt_whisper_cli(path)
    except VoiceError as e:
        # Decoder errors quote the filename they choked on. The scratch path is
        # ours, not the caller's business, and it goes into an HTTP body — so
        # scrub it from every message on the way out (belt to the worker's braces).
        raise type(e)(str(e).replace(path, "<audio>")) from None
    finally:
        _shred(path)  # runs on success, on raise, and on timeout
    return {
        "text": text.strip()[: config.STT_MAX_CHARS],
        "duration": duration,
        "secs": round(time.time() - started, 2),
        "backend": backend,
    }


def _stt_faster_whisper(path: str) -> tuple[str, float]:
    argv = [
        config.STT_PYTHON, str(WORKER), path,
        config.STT_MODEL, str(config.STT_MAX_SECONDS), config.STT_LANGUAGE,
    ]
    try:
        p = _run(argv, timeout=config.STT_TIMEOUT)
    except subprocess.TimeoutExpired:
        raise VoiceError(f"transcription timed out after {config.STT_TIMEOUT}s") from None
    except OSError as e:
        raise VoiceUnavailable(str(e)[:200]) from e
    out = (p.stdout or b"").decode("utf-8", "replace").strip()
    try:
        res = json.loads(out)
    except json.JSONDecodeError:
        err = (p.stderr or b"").decode("utf-8", "replace").strip()[-300:]
        raise VoiceError(f"transcriber produced no result (rc={p.returncode}) {err}") from None
    if not res.get("ok"):
        kind = str(res.get("error", "failed"))
        raise _KINDS.get(kind, VoiceError)(str(res.get("detail") or kind)[:300])
    return str(res.get("text", "")), float(res.get("duration") or 0)


def _stt_whisper_cli(path: str) -> tuple[str, float]:
    """whisper.cpp fallback: ffmpeg -> 16 kHz mono s16le wav -> whisper-cli.

    Unlike the faster-whisper path this cannot cheaply pre-probe duration, so
    it caps the decode at the limit and then REFUSES anything that hit the cap
    (rather than silently transcribing a truncated clip).
    """
    cap = config.STT_MAX_SECONDS
    wav = path + ".wav"
    try:
        try:
            conv = _run(
                ["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-i", path,
                 "-t", str(cap + 1), "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", wav],
                timeout=config.STT_TIMEOUT,
            )
        except subprocess.TimeoutExpired:
            raise VoiceError("audio decode timed out") from None
        except OSError as e:
            raise VoiceUnavailable(f"ffmpeg missing: {str(e)[:120]}") from e
        if conv.returncode != 0 or not os.path.exists(wav):
            raise AudioUnreadable((conv.stderr or b"").decode("utf-8", "replace")[-200:] or "could not decode audio")
        seconds = os.path.getsize(wav) / 32000.0  # 16 kHz * 2 bytes, mono
        if seconds > cap:
            raise AudioTooLong(f"{seconds:.1f}s exceeds the {cap}s limit")
        argv = [config.STT_WHISPER_CLI, "-m", config.STT_WHISPER_MODEL_FILE, "-f", wav,
                "-nt", "-np", "-t", str(config.STT_THREADS)]
        if config.STT_LANGUAGE:
            argv += ["-l", config.STT_LANGUAGE]
        try:
            p = _run(argv, timeout=config.STT_TIMEOUT)
        except subprocess.TimeoutExpired:
            raise VoiceError(f"transcription timed out after {config.STT_TIMEOUT}s") from None
        except OSError as e:
            raise VoiceUnavailable(str(e)[:200]) from e
        if p.returncode != 0:
            raise VoiceError((p.stderr or b"").decode("utf-8", "replace")[-200:] or "whisper-cli failed")
        text = " ".join((p.stdout or b"").decode("utf-8", "replace").split())
        return text, round(seconds, 2)
    finally:
        _shred(wav)


# ---------------------------------------------------------------------------
# speech OUT
# ---------------------------------------------------------------------------
def synthesize(text: str) -> bytes:
    """Text -> WAV bytes via local piper. Never touches disk.

    piper writes headerless s16le mono to stdout with --output-raw; we wrap it
    in a WAV header in memory, so the reply audio exists only in RAM and in
    the HTTP response.
    """
    if not tts_available():
        raise VoiceUnavailable("no local text-to-speech on this host")
    clean = " ".join(str(text).split())[: config.TTS_MAX_CHARS]
    if not clean:
        raise VoiceError("nothing to say")
    argv = [config.TTS_PIPER, "-m", config.TTS_VOICE, "--output-raw"]
    try:
        p = _run(argv, timeout=config.TTS_TIMEOUT, stdin_bytes=clean.encode("utf-8"))
    except subprocess.TimeoutExpired:
        raise VoiceError(f"speech synthesis timed out after {config.TTS_TIMEOUT}s") from None
    except OSError as e:
        raise VoiceUnavailable(str(e)[:200]) from e
    if p.returncode != 0 or not p.stdout:
        raise VoiceError((p.stderr or b"").decode("utf-8", "replace")[-200:] or "piper produced no audio")
    return _wav(p.stdout, voice_sample_rate())


def voice_sample_rate() -> int:
    """Sample rate from the voice's sidecar JSON (piper voices ship one)."""
    try:
        meta = json.loads(Path(str(config.TTS_VOICE) + ".json").read_text())
        rate = int(meta.get("audio", {}).get("sample_rate", 0))
        if 4000 <= rate <= 96000:
            return rate
    except (OSError, ValueError, TypeError, json.JSONDecodeError):
        pass
    return 22050  # piper's medium-voice default


def _wav(pcm: bytes, rate: int) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(pcm)
    return buf.getvalue()
