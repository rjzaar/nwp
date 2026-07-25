#!/usr/bin/env python3
"""Out-of-process faster-whisper transcriber. Stdlib + faster_whisper only.

Deliberately NOT imported by the console venv. app/voice.py runs this as a
short-lived SUBPROCESS with an interpreter that has faster-whisper installed
(NWP_CONSOLE_STT_PYTHON), because:

  * the long-lived uvicorn process stays ~130 MB — a transcription's ~400 MB
    peak belongs to a child that exits and gives the memory straight back
    (the console host shares its RAM with local LLMs, and the unit sets a
    MemoryMax);
  * the console venv keeps its "deliberately tiny" dependency list — no
    ctranslate2/onnxruntime/av in the web app's import graph;
  * a wedged model load is killed by a plain subprocess timeout;
  * the same console code runs on a host with no STT at all — it just reports
    "unavailable" and the tab degrades.

Contract (one JSON object on stdout, nothing else):
    stt_worker.py --selftest                        -> rc 0 iff importable
    stt_worker.py <audio> <model> <max_secs> <lang> -> {"ok":true,"text":...}
                                                    or {"ok":false,"error":...}

NEVER prints the audio path, the audio bytes, or anything but that object:
stdout is captured into the console's logs on error paths.
"""
from __future__ import annotations

import json
import sys

# Error kinds the caller maps to HTTP status / user-facing text.
ERR_NO_BACKEND = "no_backend"
ERR_TOO_LONG = "too_long"
ERR_UNREADABLE = "unreadable"
ERR_FAILED = "failed"


def _out(obj: dict) -> None:
    sys.stdout.write(json.dumps(obj))
    sys.stdout.flush()


def _fail(kind: str, detail: str = "") -> int:
    _out({"ok": False, "error": kind, "detail": detail[:300]})
    return 3


def _probe_duration(path: str) -> float:
    """Container duration in seconds, or 0.0 if it can't be read cheaply.

    Done BEFORE loading the model so an over-long upload costs us a header
    parse, not a transcription.
    """
    try:
        import av

        with av.open(path) as container:
            if container.duration:
                return float(container.duration) / 1_000_000.0
            for stream in container.streams:
                if stream.type == "audio" and stream.duration and stream.time_base:
                    return float(stream.duration * stream.time_base)
    except Exception:  # noqa: BLE001 — probing is best-effort; the real gate is below
        return 0.0
    return 0.0


def main(argv: list[str]) -> int:
    if "--selftest" in argv:
        try:
            import faster_whisper  # noqa: F401  (the import IS the test)
        except Exception:  # noqa: BLE001 — a broken install is "no backend", not a crash
            return 1
        return 0
    if len(argv) < 4:
        return _fail(ERR_FAILED, "usage: stt_worker.py <audio> <model> <max_secs> <lang>")
    path, model, max_secs_s, lang = argv[0], argv[1], argv[2], argv[3]
    try:
        max_secs = float(max_secs_s)
    except ValueError:
        return _fail(ERR_FAILED, "bad max_secs")

    try:
        from faster_whisper import WhisperModel
    except Exception as e:  # noqa: BLE001
        return _fail(ERR_NO_BACKEND, str(e))

    probed = _probe_duration(path)
    if probed > max_secs:
        return _fail(ERR_TOO_LONG, f"{probed:.1f}s exceeds the {max_secs:.0f}s limit")

    try:
        m = WhisperModel(model, device="cpu", compute_type="int8")
        segments, info = m.transcribe(
            path,
            beam_size=1,                    # greedy: push-to-talk wants latency, not BLEU
            language=(lang or None),        # empty => auto-detect
            vad_filter=True,                # drop silence: whisper hallucinates on it
            condition_on_previous_text=False,  # no runaway repetition loops
        )
        # Backstop: probing can fail on a headerless/streamed container, so
        # re-check against the duration the decoder actually saw. Generators
        # are lazy — this reads before consuming segments only for `duration`,
        # which faster-whisper fills in eagerly.
        if float(info.duration or 0) > max_secs:
            return _fail(ERR_TOO_LONG, f"{info.duration:.1f}s exceeds the {max_secs:.0f}s limit")
        text = "".join(s.text for s in segments).strip()
    except Exception as e:  # noqa: BLE001
        # A corrupt/unsupported upload is the caller's problem (400), not an
        # outage (500): anything raised by PyAV — the demuxer/decoder — plus
        # plain ValueError means "those bytes aren't audio we can read".
        origin = (getattr(type(e), "__module__", "") or "").split(".")[0]
        kind = ERR_UNREADABLE if origin == "av" or isinstance(e, ValueError) else ERR_FAILED
        # NEVER echo the scratch path back to the browser (PyAV puts it in the
        # message); the caller scrubs too, but fix it at the source.
        return _fail(kind, f"{type(e).__name__}: {e}".replace(path, "<audio>"))

    _out({"ok": True, "text": text, "duration": round(float(info.duration or 0), 2), "model": model})
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except SystemExit:
        raise
    except Exception as e:  # noqa: BLE001 — never traceback onto stdout
        raise SystemExit(_fail(ERR_FAILED, f"{type(e).__name__}: {e}"))
