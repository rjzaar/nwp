"""tmux sessions on the console host — list, start, and the pty bridge.

WHY THIS EXISTS
    The operator's long-running work (agent runs, `claude`, builds) must live
    ON the console host and survive the laptop dropping wifi. tmux is what
    survives; the console's Sessions tab is only an intermittent window onto
    it. This module is the whole tmux surface: everything the routes in
    main.py can do to a session funnels through here.

THREAT SHAPE
    A terminal is a shell on the agent host, so this file follows the
    runner.py doctrine and then some:

      * argv lists only, never shell=True — no string a user typed is ever
        parsed by a shell;
      * the session NAME is the only user input that exists on this surface,
        and it is validated against ONE strict regex in ONE place. Everything
        (routes, websocket, this module's own entry points) calls the same
        `valid_name`. The regex forbids a leading `-` (tmux would read a flag),
        `:` and `.` (tmux target syntax), `/` (paths), whitespace and quotes;
      * attach uses `=name` — tmux's EXACT-match target. A bare name is a
        prefix match, and "attach to the session I named" must never mean
        "attach to whichever session this happens to prefix";
      * reads fail closed: "tmux is broken/absent" is an error the pane must
        show, never an empty list that looks like a quiet host. The one
        rc!=0 that IS a real answer — "no server running" — is recognised
        explicitly and returns ok + empty.

    Auth is deliberately NOT here: the routes own it (owner-only, and for the
    websocket a cookie gate that runs before accept()). This module assumes a
    caller that main.py has already refused for everyone else.
"""
from __future__ import annotations

import asyncio
import contextlib
import fcntl
import json
import os
import pty
import re
import signal
import struct
import subprocess
import termios
import time

# One regex, one place. Starts with an alphanumeric (never `-`: tmux would
# parse a flag), then up to 31 of [A-Za-z0-9_-]. No `:` or `.` (tmux target
# grammar), no `/`, no spaces, no quotes, no unicode.
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$")

# Output field separator for list-sessions: a REAL tab embedded in the argv
# (tmux -F does not interpret backslash escapes; Python supplies the byte).
_LIST_FORMAT = "\t".join((
    "#{session_name}", "#{session_created}", "#{session_attached}",
    "#{session_windows}", "#{pane_current_command}", "#{pane_title}",
))

_TMUX_TIMEOUT = 10


def valid_name(name) -> bool:
    return isinstance(name, str) and bool(NAME_RE.match(name))


def attach_argv(name: str) -> list:
    """The exact argv the pty bridge execs. `=name` = exact-match target."""
    return ["tmux", "attach-session", "-t", f"={name}"]


def _run(argv: list) -> subprocess.CompletedProcess:
    return subprocess.run(
        argv, capture_output=True, text=True,
        timeout=_TMUX_TIMEOUT, stdin=subprocess.DEVNULL,
    )


def list_sessions() -> dict:
    """{ok, sessions:[{name, created, attached, windows, command, title}], error}.

    Fail closed: an unrunnable/broken tmux is {ok: False, error}, never an
    empty list. "no server running" is tmux's real answer for "you have no
    sessions yet" and maps to ok + [].
    """
    try:
        p = _run(["tmux", "list-sessions", "-F", _LIST_FORMAT])
    except (OSError, subprocess.TimeoutExpired) as e:
        return {"ok": False, "sessions": [], "error": f"tmux unavailable: {e}"}
    if p.returncode != 0:
        err = (p.stderr or p.stdout or "").strip()
        if "no server running" in err or "No such file or directory" in err:
            return {"ok": True, "sessions": [], "error": ""}
        return {"ok": False, "sessions": [],
                "error": err[:200] or f"tmux exited {p.returncode}"}
    sessions = []
    for line in (p.stdout or "").splitlines():
        parts = line.split("\t")
        if len(parts) < 6 or not valid_name(parts[0]):
            # A session somebody created by hand with a name the console
            # cannot safely address: show nothing rather than a dead link.
            continue
        try:
            created, attached, windows = int(parts[1]), int(parts[2]), int(parts[3])
        except ValueError:
            continue
        sessions.append({
            "name": parts[0], "created": created, "attached": attached > 0,
            "windows": windows, "command": parts[4], "title": parts[5],
        })
    return {"ok": True, "sessions": sessions, "error": ""}


def new_session(name) -> dict:
    """Start a detached session named `name`, shell in $HOME. {ok, error}."""
    if not valid_name(name):
        return {"ok": False, "error": "invalid session name (letters, digits, - and _ only, max 32)"}
    home = os.path.expanduser("~")
    try:
        # `new-session -d` runs the user's default shell as a login-ish shell
        # in $HOME; -s is safe because valid_name forbids a leading dash and
        # every tmux metacharacter. No user text beyond the name is passed.
        p = _run(["tmux", "new-session", "-d", "-s", name, "-c", home])
    except (OSError, subprocess.TimeoutExpired) as e:
        return {"ok": False, "error": f"tmux unavailable: {e}"}
    if p.returncode != 0:
        return {"ok": False, "error": (p.stderr or p.stdout or "").strip()[:200]
                or f"tmux exited {p.returncode}"}
    return {"ok": True, "error": ""}


# ---------------------------------------------------------------------------
# the pty bridge — websocket <-> `tmux attach`
# ---------------------------------------------------------------------------
# Wire protocol (client -> server, TEXT frames; first char is the kind):
#   "0<data>"          keystrokes, written to the pty verbatim
#   "1[cols, rows]"    resize (JSON pair), applied with TIOCSWINSZ
# Server -> client: BINARY frames of raw pty output.
def _set_winsize(fd: int, cols: int, rows: int) -> None:
    cols = max(2, min(int(cols), 500))
    rows = max(2, min(int(rows), 300))
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


def _reap(pid: int) -> None:
    """SIGHUP the tmux CLIENT (the session it was attached to lives on),
    escalating to SIGKILL only if it ignores us. Blocking — call off-loop."""
    with contextlib.suppress(ProcessLookupError, ChildProcessError, OSError):
        os.kill(pid, signal.SIGHUP)
        for _ in range(50):
            if os.waitpid(pid, os.WNOHANG)[0]:
                return
            time.sleep(0.02)
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)


async def bridge(ws, name: str) -> None:
    """Pump bytes between an ACCEPTED, AUTHENTICATED websocket and a pty
    running `tmux attach` on this host. Returns when either side hangs up;
    the tmux session itself always survives this function."""
    argv = attach_argv(name)
    pid, fd = pty.fork()
    if pid == 0:  # child: exec immediately; never return into the server
        os.environ["TERM"] = "xterm-256color"
        try:
            os.execvp(argv[0], argv)
        finally:
            os._exit(127)

    loop = asyncio.get_running_loop()
    out_q: asyncio.Queue = asyncio.Queue()

    def _on_readable() -> None:
        try:
            data = os.read(fd, 65536)
        except OSError:
            data = b""
        out_q.put_nowait(data)
        if not data:
            loop.remove_reader(fd)

    loop.add_reader(fd, _on_readable)

    async def pump_out() -> None:
        while True:
            data = await out_q.get()
            if not data:          # pty closed: tmux client detached or died
                return
            await ws.send_bytes(data)

    async def pump_in() -> None:
        while True:
            msg = await ws.receive_text()   # raises WebSocketDisconnect on close
            if not msg:
                continue
            kind, payload = msg[0], msg[1:]
            if kind == "0":
                os.write(fd, payload.encode())
            elif kind == "1":
                with contextlib.suppress(ValueError, TypeError, OSError):
                    cols, rows = json.loads(payload)
                    _set_winsize(fd, cols, rows)

    t_out = asyncio.ensure_future(pump_out())
    t_in = asyncio.ensure_future(pump_in())
    try:
        done, _pending = await asyncio.wait({t_out, t_in},
                                            return_when=asyncio.FIRST_COMPLETED)
        for t in done:                     # surface nothing; both ends just end
            with contextlib.suppress(Exception):
                t.result()
    finally:
        for t in (t_out, t_in):
            t.cancel()
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await t
        with contextlib.suppress(OSError):
            loop.remove_reader(fd)
        with contextlib.suppress(OSError):
            os.close(fd)
        await loop.run_in_executor(None, _reap, pid)
        with contextlib.suppress(Exception):
            await ws.close()
