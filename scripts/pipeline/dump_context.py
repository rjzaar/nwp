#!/usr/bin/env python3
"""Dump bounded transcript/summary context for a set, for stage-4 AI authoring.

Part of NWP (Narrow Way Project). Tracks nwp/ops#34; design in
``~/central/PODCAST-PIPELINE-PROPOSAL-2026-07-02.md`` §6.

This is the *interim* stand-in for the proposal's ``nwptoolkit export`` subcommand
(deferred to avoid the ~/nwptoolkit collision — another agent is deploying from
that tree). It reads the DIR-scheme ``ep_NNNN.json`` files **directly** off disk
rather than going through a nwptoolkit CLI, so this pipeline layer stays wholly
inside ``~/nwp``.

Two modes feed the two stage-4 chunk shapes (proposal §6):

  * ``--mode summaries``   — one line per episode (number + title), from
    ``episodes.json``. Feeds the single taxonomy call.
  * ``--mode transcripts`` — bounded transcript text from ``ep_NNNN.json``,
    across the selected episodes, capped at ``--max-chars``. Feeds the
    per-course course_catalog / branding / seed calls.

Transcript JSON is read tolerantly: it uses a top-level ``text`` field if present
(rg scheme), else concatenates ``segments[*].text`` (dir scheme). Both schemes
are DIR-layout (``ep_NNNN.json`` <-> ``episodes[N-1]``).

Set resolution (no nwptoolkit import): read ``sets/<slug>/set.yml`` under
``--toolkit-root`` (default ~/nwptoolkit) for ``transcripts.dir`` and
``transcripts.episodes_json``; or pass ``--transcripts-dir`` / ``--episodes-json``
explicitly.

Usage::

    dump_context.py --set rg --mode summaries --max-chars 8000
    dump_context.py --set rg --mode transcripts --episodes 1,3,4 --max-chars 40000 --out ctx.md
    dump_context.py --transcripts-dir ~/nwptoolkit/sets/rg/transcripts/whisper_large \
                    --mode transcripts --max-chars 40000
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path
from typing import Optional


def _expand(p: str) -> Path:
    return Path(os.path.expanduser(os.path.expandvars(p)))


def _read_set_yml(toolkit_root: Path, slug: str) -> dict:
    """Minimal set.yml reader for transcripts.{dir,episodes_json}.

    Uses PyYAML if available; else a tiny line scanner for the two keys we need
    (keeps this helper dependency-light on a fresh box).
    """
    set_yml = toolkit_root / "sets" / slug / "set.yml"
    if not set_yml.exists():
        sys.exit(f"error: no set.yml for set '{slug}' at {set_yml}")
    text = set_yml.read_text()
    try:
        import yaml  # type: ignore

        data = yaml.safe_load(text) or {}
        return (data.get("transcripts") or {})
    except Exception:
        # Fallback: scan the transcripts: block for dir / episodes_json.
        out: dict = {}
        in_block = False
        for line in text.splitlines():
            if re.match(r"^transcripts:\s*$", line):
                in_block = True
                continue
            if in_block:
                if line and not line[0].isspace():
                    break
                m = re.match(r"\s+(dir|episodes_json):\s*(.+?)\s*$", line)
                if m:
                    out[m.group(1)] = m.group(2)
        return out


def _load_episodes(episodes_json: Optional[Path]) -> list:
    if not episodes_json or not episodes_json.exists():
        return []
    data = json.loads(episodes_json.read_text())
    if isinstance(data, dict):
        # tolerate {"episodes": [...]} wrappers
        for k in ("episodes", "items", "data"):
            if isinstance(data.get(k), list):
                return data[k]
        return []
    return data if isinstance(data, list) else []


def _episode_title(episodes: list, idx0: int) -> str:
    if 0 <= idx0 < len(episodes):
        ep = episodes[idx0]
        if isinstance(ep, dict):
            return str(ep.get("title") or ep.get("slug") or f"episode {idx0 + 1}")
    return f"episode {idx0 + 1}"


def _transcript_text(ep_json: Path) -> str:
    try:
        d = json.loads(ep_json.read_text())
    except Exception:
        return ""
    txt = d.get("text")
    if isinstance(txt, str) and txt.strip():
        return txt.strip()
    segs = d.get("segments") or []
    parts = [str(s.get("text", "")).strip() for s in segs if isinstance(s, dict)]
    return " ".join(p for p in parts if p)


def _ep_numbers(transcript_dir: Path, subset: Optional[list[int]]) -> list[int]:
    found = []
    for f in sorted(transcript_dir.glob("ep_*.json")):
        m = re.match(r"ep_(\d+)\.json$", f.name)
        if m:
            found.append(int(m.group(1)))
    if subset:
        want = set(subset)
        return [n for n in found if n in want]
    return found


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--set", dest="slug", help="set slug (resolves paths from set.yml)")
    ap.add_argument("--toolkit-root", default=os.path.expanduser("~/nwptoolkit"),
                    help="nwptoolkit root holding sets/<slug>/set.yml (default ~/nwptoolkit)")
    ap.add_argument("--transcripts-dir", help="override: dir of ep_NNNN.json")
    ap.add_argument("--episodes-json", help="override: episodes.json path")
    ap.add_argument("--mode", choices=("summaries", "transcripts"), default="transcripts")
    ap.add_argument("--episodes", help="comma-separated episode numbers to include (default: all)")
    ap.add_argument("--max-chars", type=int, default=40000, help="hard cap on emitted characters")
    ap.add_argument("--per-episode-chars", type=int, default=0,
                    help="optional per-episode transcript cap (0 = no per-episode cap)")
    ap.add_argument("--out", help="write here instead of stdout")
    args = ap.parse_args()

    # Resolve transcript dir + episodes.json.
    transcript_dir: Optional[Path] = None
    episodes_json: Optional[Path] = None
    if args.transcripts_dir:
        transcript_dir = _expand(args.transcripts_dir)
    if args.episodes_json:
        episodes_json = _expand(args.episodes_json)
    if (transcript_dir is None or episodes_json is None) and args.slug:
        tr = _read_set_yml(_expand(args.toolkit_root), args.slug)
        if transcript_dir is None and tr.get("dir"):
            transcript_dir = _expand(tr["dir"])
        if episodes_json is None and tr.get("episodes_json"):
            episodes_json = _expand(tr["episodes_json"])
    if transcript_dir is None:
        sys.exit("error: no transcripts dir (pass --transcripts-dir or --set with a valid set.yml)")
    if not transcript_dir.is_dir():
        sys.exit(f"error: transcripts dir not found: {transcript_dir}")

    subset: Optional[list[int]] = None
    if args.episodes:
        subset = [int(x) for x in args.episodes.split(",") if x.strip()]

    episodes = _load_episodes(episodes_json)
    out_parts: list[str] = []
    budget = args.max_chars

    if args.mode == "summaries":
        for n in _ep_numbers(transcript_dir, subset):
            line = f"{n:04d}: {_episode_title(episodes, n - 1)}"
            if len(line) + 1 > budget:
                out_parts.append(f"... (truncated at {args.max_chars} chars)")
                break
            out_parts.append(line)
            budget -= len(line) + 1
    else:  # transcripts
        for n in _ep_numbers(transcript_dir, subset):
            if budget <= 0:
                out_parts.append(f"... (truncated at {args.max_chars} chars)")
                break
            body = _transcript_text(transcript_dir / f"ep_{n:04d}.json")
            if not body:
                continue
            if args.per_episode_chars and len(body) > args.per_episode_chars:
                body = body[: args.per_episode_chars].rstrip() + " ..."
            header = f"=== ep_{n:04d} — {_episode_title(episodes, n - 1)} ==="
            block = header + "\n" + body
            if len(block) > budget:
                block = block[: max(0, budget)].rstrip() + "\n... (truncated)"
            out_parts.append(block)
            budget -= len(block) + 1

    text = "\n".join(out_parts) + "\n"
    if args.out:
        Path(args.out).write_text(text)
        sys.stderr.write(f"wrote {len(text)} chars to {args.out}\n")
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
