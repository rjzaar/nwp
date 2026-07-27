"""NWP Console configuration — env-driven, stdlib only.

Every knob is an environment variable so the systemd unit's EnvironmentFile
(~/.config/nwp-console/env on the deploy host, written by `pl console deploy`
from the gitignored nwp.yml settings.console block) is the single place to tune
a deployment. Committed defaults are placeholders (P61 leakage gate).
"""
from __future__ import annotations

import os
from pathlib import Path


def _env(name: str, default: str) -> str:
    v = os.environ.get(name, "").strip()
    return v if v else default


HOME = Path(os.environ.get("HOME", "/root"))

# Transport (uvicorn binds these — see the systemd unit; app also reads them
# for building absolute URLs in enrolment links).
BIND = _env("NWP_CONSOLE_BIND", "100.64.0.2")
PORT = int(_env("NWP_CONSOLE_PORT", "8600"))

# WebAuthn relying party. RP_ID must be a DNS name (never an IP) and ORIGIN
# must be exactly what the browser sees in the URL bar, or every ceremony fails.
# Real values come from the EnvironmentFile written by `pl console deploy`
# (sourced from the gitignored nwp.yml settings.console block) — the committed
# defaults are placeholders by design (P61 leakage gate).
RP_ID = _env("NWP_CONSOLE_RP_ID", "console.example.com")
RP_NAME = _env("NWP_CONSOLE_RP_NAME", "NWP Console")
ORIGIN = _env("NWP_CONSOLE_ORIGIN", f"https://{RP_ID}:{PORT}")

# State: users.json + audit.jsonl + session-signing secret live here (0700).
DATA_DIR = Path(_env("NWP_CONSOLE_DATA", str(HOME / ".local/share/nwp-console")))

# The nwp checkout whose `pl` the read panes and allowlisted actions shell to.
NWP_ROOT = Path(_env("NWP_CONSOLE_ROOT", str(HOME / "nwp")))

# GitLab (issues + CI panes). The token file is provisioned BY THE OPERATOR
# (0600, walled ops_note_token pattern — see README). If absent, both panes
# degrade to read-nothing + deep-links; nothing crashes.
GITLAB_HOST = _env("NWP_CONSOLE_GITLAB_HOST", "gitlab.example.com")
GITLAB_TOKEN_FILE = Path(
    _env("NWP_CONSOLE_GITLAB_TOKEN_FILE", str(HOME / ".config/nwp-console/gitlab.token"))
)
OPS_PROJECT = _env("NWP_CONSOLE_OPS_PROJECT", "nwp/ops")
CI_PROJECTS = [p.strip() for p in _env("NWP_CONSOLE_CI_PROJECTS", "nwp/nwp").split(",") if p.strip()]

# Demo tier sites the demo pane covers. This is the TIER GATE, not a grant:
# it says which sites the demo verbs exist for at all. WHICH of them a given
# request may act on comes from the Scope (project.demo_sites ∩ this list) —
# see app/scope.py. Never pass this list to build_action().
DEMO_SITES = [s.strip() for s in _env("NWP_CONSOLE_DEMO_SITES", "nwd").split(",") if s.strip()]

# Project scoping (multi-tenancy). Strict mode turns a scrubbed foreign row
# from "dropped + audited" into a hard error — it is set in CI and in the test
# suite, so a leak fails the build instead of being quietly repaired at render
# time. It is deliberately OFF in production: a leak must not become a 500.
SCOPE_STRICT = _env("NWP_CONSOLE_SCOPE_STRICT", "0") in ("1", "true", "on", "yes")

# Signed cookie remembering the last project a member looked at.
PROJECT_COOKIE = "nwp_console_project"

# Sessions
SESSION_COOKIE = "nwp_console_session"
SESSION_MAX_AGE = 7 * 24 * 3600  # 7 days
CHALLENGE_MAX_AGE = 300  # 5 minutes for a WebAuthn ceremony

# Subprocess guard rails
PL_TIMEOUT = int(_env("NWP_CONSOLE_PL_TIMEOUT", "180"))
PANE_CACHE_TTL = int(_env("NWP_CONSOLE_CACHE_TTL", "60"))

# Enrolment tokens (one-time) expire after this many hours.
ENROL_TOKEN_HOURS = int(_env("NWP_CONSOLE_ENROL_HOURS", "48"))

# How old a published docs library may be before the page shouts. Deliberately
# NOT the fleet max-age: docs change on a commit, days apart, where a RAG grade
# goes stale in minutes. Same idiom (_provenance.html), different number.
LIBRARY_MAX_AGE = int(_env("NWP_CONSOLE_LIBRARY_MAX_AGE", str(14 * 24 * 3600)))

# Quokka — the local-LLM chat tab. Talks ONLY to the loopback ollama on the
# console host itself (AI tier); read-only context injection, zero action path.
QUOKKA_URL = _env("NWP_CONSOLE_QUOKKA_URL", "http://127.0.0.1:11434")
QUOKKA_MODEL = _env("NWP_CONSOLE_QUOKKA_MODEL", "llama3.3:70b")
QUOKKA_TIMEOUT = int(_env("NWP_CONSOLE_QUOKKA_TIMEOUT", "60"))

# -- Gotify push notifications (Phase 3) ------------------------------------
# The console's "tell me" channel: a SELF-HOSTED Gotify server on the mesh.
# Empty URL (the committed default) = the whole feature is a silent no-op, so
# dev checkouts and fresh deploys never error. The application token is
# provisioned by the OPERATOR at GOTIFY_TOKEN_FILE (0600) — `pl console deploy`
# never copies it, exactly like the GitLab pane token.
GOTIFY_URL = _env("NWP_CONSOLE_GOTIFY_URL", "")
GOTIFY_TOKEN_FILE = Path(
    _env("NWP_CONSOLE_GOTIFY_TOKEN_FILE", str(HOME / ".config/nwp-console/gotify.token"))
)
GOTIFY_TIMEOUT = int(_env("NWP_CONSOLE_GOTIFY_TIMEOUT", "5"))

# Which events may push. Comma-separated subset of notify.EVENT_KINDS
# (rag, demo_tester, demo_reset, token_expiry, security, ci, brief) — each
# individually toggleable; "" or "none" disables every event but leaves the
# test button live.
NOTIFY_EVENTS = [
    e.strip() for e in _env(
        "NWP_CONSOLE_NOTIFY_EVENTS", "rag,demo_tester,demo_reset,token_expiry,security,ci"
    ).split(",")
    if e.strip() and e.strip().lower() != "none"
]

# Seconds between checker passes. The gathers are TTL-cached and shared with
# the panes, so this is cheap; below PANE_CACHE_TTL it just re-reads the cache.
NOTIFY_INTERVAL = int(_env("NWP_CONSOLE_NOTIFY_INTERVAL", "300"))

# Optional daily morning brief, local "HH:MM" ("" = off). Requires 'brief' in
# NOTIFY_EVENTS and a reachable local model (Quokka); it never wakes one.
NOTIFY_BRIEF_AT = _env("NWP_CONSOLE_NOTIFY_BRIEF_AT", "")

# Where the dedupe high-water marks live (0600) so restarts don't re-notify.
NOTIFY_STATE_FILE = Path(_env("NWP_CONSOLE_NOTIFY_STATE", str(DATA_DIR / "notify-state.json")))
# ---------------------------------------------------------------------------
# Voice — talk to Quokka, Quokka talks back. Everything runs ON THIS HOST:
# faster-whisper/whisper.cpp for speech in, piper for speech out. No cloud
# speech API is used anywhere, and the browser's SpeechRecognition (which
# uploads audio to Google in Chromium/Brave) is never called. See app/voice.py.
# Absent backends are not an error: the mic button hides and /quokka/stt 503s.
# ---------------------------------------------------------------------------
# auto | faster-whisper | whisper-cli | off
STT_BACKEND = _env("NWP_CONSOLE_STT_BACKEND", "auto")
# faster-whisper model id: tiny(.en)/base(.en)/small(.en)/… Small = low latency.
STT_MODEL = _env("NWP_CONSOLE_STT_MODEL", "base")
# Interpreter that HAS faster-whisper (kept out of the console venv on purpose).
STT_PYTHON = _env("NWP_CONSOLE_STT_PYTHON", "/usr/bin/python3")
STT_WHISPER_CLI = _env("NWP_CONSOLE_STT_WHISPER_CLI", str(HOME / "whisper.cpp/build/bin/whisper-cli"))
STT_WHISPER_MODEL_FILE = _env(
    "NWP_CONSOLE_STT_WHISPER_MODEL", str(HOME / "whisper.cpp/models/ggml-base.en.bin")
)
STT_LANGUAGE = _env("NWP_CONSOLE_STT_LANGUAGE", "en")  # "" => auto-detect
STT_MAX_SECONDS = int(_env("NWP_CONSOLE_STT_MAX_SECONDS", "60"))
STT_MAX_BYTES = int(_env("NWP_CONSOLE_STT_MAX_BYTES", str(10 * 1024 * 1024)))
STT_MAX_CHARS = int(_env("NWP_CONSOLE_STT_MAX_CHARS", "4000"))  # matches the chat cap
STT_TIMEOUT = int(_env("NWP_CONSOLE_STT_TIMEOUT", "120"))
STT_THREADS = int(_env("NWP_CONSOLE_STT_THREADS", "4"))  # be a good neighbour to ollama

TTS_BACKEND = _env("NWP_CONSOLE_TTS_BACKEND", "auto")  # auto | off (off => browser voices)
TTS_PIPER = _env("NWP_CONSOLE_TTS_PIPER", str(HOME / "piper/venv/bin/piper"))
TTS_VOICE = _env("NWP_CONSOLE_TTS_VOICE", str(HOME / "piper/voices/en_US-lessac-medium.onnx"))
TTS_MAX_CHARS = int(_env("NWP_CONSOLE_TTS_MAX_CHARS", "2000"))
TTS_TIMEOUT = int(_env("NWP_CONSOLE_TTS_TIMEOUT", "60"))

# Where the milliseconds-long audio scratch file lives (0700 dir, 0600 file,
# truncated + unlinked in a finally). Default: the system temp dir.
VOICE_TMPDIR = _env("NWP_CONSOLE_VOICE_TMPDIR", "")

# -- Published fleet state ---------------------------------------------------
# The console DISPLAYS fleet state; it does not compute it. The machine that
# holds the sites runs `pl fleet publish`, which drops a schema-versioned
# snapshot here (0600). The panes prefer it, show its provenance and age, and
# mark it STALE loudly once it is older than FLEET_MAX_AGE. Absent snapshot =>
# the previous behaviour (shell out to the local `pl`), clearly labelled.
FLEET_STATE_FILE = Path(_env("NWP_CONSOLE_FLEET_STATE", str(DATA_DIR / "fleet-state.json")))
FLEET_MAX_AGE = int(_env("NWP_CONSOLE_FLEET_MAX_AGE", "7200"))  # 2h


def secret_key() -> bytes:
    """Session-signing secret; auto-generated once, 0600."""
    path = Path(_env("NWP_CONSOLE_SECRET_FILE", str(DATA_DIR / "secret.key")))
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        import secrets as _s

        path.touch(mode=0o600)
        path.write_text(_s.token_hex(32))
        path.chmod(0o600)
    return path.read_text().strip().encode()
