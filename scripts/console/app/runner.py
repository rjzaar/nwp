"""Subprocess wrapper for `pl` — the ONLY module that spawns processes.

Everything funnels through run_pl(): argv list (never shell=True), fixed
executable (NWP_ROOT/pl), sanitised env, hard timeout, and a small TTL cache
so a phone refreshing the dashboard doesn't stampede slow pl commands.
"""
from __future__ import annotations

import os
import subprocess
import threading
import time
from pathlib import Path

_cache: dict = {}
_cache_lock = threading.Lock()
_inflight: dict = {}


def _env() -> dict:
    env = {
        "HOME": os.environ.get("HOME", "/tmp"),
        "PATH": os.environ.get("PATH", "/usr/local/bin:/usr/bin:/bin"),
        "LANG": "C.UTF-8",
        "NO_COLOR": "1",
        "TERM": "dumb",
    }
    return env


def run_pl(root: Path, args: list[str], timeout: int = 180) -> dict:
    """Run <root>/pl <args...>. Returns {rc, out, err, secs, cmd}. Never raises."""
    pl = Path(root) / "pl"
    cmd = [str(pl)] + list(args)
    started = time.time()
    if not pl.exists():
        return {"rc": 127, "out": "", "err": f"pl not found at {pl}", "secs": 0.0, "cmd": " ".join(cmd)}
    try:
        p = subprocess.run(
            cmd,
            cwd=str(root),
            env=_env(),
            capture_output=True,
            text=True,
            timeout=timeout,
            stdin=subprocess.DEVNULL,
        )
        return {
            "rc": p.returncode,
            "out": p.stdout[-200_000:],
            "err": p.stderr[-20_000:],
            "secs": round(time.time() - started, 1),
            "cmd": " ".join(cmd),
        }
    except subprocess.TimeoutExpired:
        return {"rc": 124, "out": "", "err": f"timed out after {timeout}s", "secs": float(timeout), "cmd": " ".join(cmd)}
    except OSError as e:
        return {"rc": 126, "out": "", "err": str(e), "secs": round(time.time() - started, 1), "cmd": " ".join(cmd)}


def run_pl_cached(root: Path, args: list[str], ttl: int = 60, timeout: int = 180, force: bool = False) -> dict:
    """TTL-cached run_pl. One in-flight run per key; others get the stale copy."""
    key = (str(root), tuple(args))
    now = time.time()
    with _cache_lock:
        hit = _cache.get(key)
        if hit and not force and now - hit[0] < ttl:
            return dict(hit[1], cached=True, age=int(now - hit[0]))
        lock = _inflight.setdefault(key, threading.Lock())
    if not lock.acquire(blocking=False):
        # Someone else is already running it: serve stale if any, else wait.
        if hit:
            return dict(hit[1], cached=True, age=int(now - hit[0]), refreshing=True)
        lock.acquire()
        lock.release()
        with _cache_lock:
            hit = _cache.get(key)
        return dict(hit[1], cached=True) if hit else {"rc": 1, "out": "", "err": "race", "secs": 0, "cmd": ""}
    try:
        res = run_pl(root, args, timeout=timeout)
        with _cache_lock:
            _cache[key] = (time.time(), res)
        return dict(res, cached=False)
    finally:
        lock.release()
