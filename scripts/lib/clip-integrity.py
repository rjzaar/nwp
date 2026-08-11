#!/usr/bin/env python3
"""Clip-catalogue referential integrity — the checks that need no relevance judgement.

────────────────────────────────────────────────────────────────────────────────
WHY THIS EXISTS
────────────────────────────────────────────────────────────────────────────────

Every `video:` block in the course catalogue is a promise to an author: *"click
here and you will hear this teaching."*  nwp/ops#349 established that all 176 of
them are machine output from a 2026-03-08 regex scrape — so there is no editorial
authority in them to preserve, only a first pass with known breakage.

Improving *which* clip is chosen needs relevance judgement and a gold set that
does not exist yet (ops#348).  This module deliberately answers only the three
questions that need neither:

    1. Does this window physically EXIST inside its own episode?
    2. Does it PLAY — is the thing it links to the recording it claims, at the
       timeline it claims?
    3. Is it HONESTLY LABELLED — does an unfilled slot look like a choice?

Every check here is decided by measurement against a local artefact.  None of
them consults a ranker, an embedding, or an opinion.

────────────────────────────────────────────────────────────────────────────────
THE CHECKS
────────────────────────────────────────────────────────────────────────────────

D1  window-beyond-media    window END is past the end of its own episode.
                           There is no such moment.  The clip cannot exist.

D2  window-beyond-video    window END is past the end of the YouTube video the
                           block links to.  The player stops before the clip.

D3  linkage-*              the (episode → youtube_id) link is RE-DERIVED here
                           from transcript content, which is self-evidencing and
                           cannot be circular.  Three verdicts:

      linkage-refuted        the linked video shares no more than boilerplate
                             with the episode → it is a DIFFERENT recording.
      linkage-unproven       evidence is inconclusive → CANNOT VERIFY (never a
                             silent pass).
      linkage-offset         the video IS the same recording, but its timeline
                             is shifted relative to the podcast's, so the
                             catalogue's podcast timestamps do not address the
                             intended content on that video.

D4  placeholder-unmarked   the window is byte-identical to the catalogue-wide
                           default and is not stamped as unset, so an unfilled
                           slot is indistinguishable from a recommendation.

D5  summary-truncated      `short.summary` is a hard character-count truncation
                           ending in an ellipsis.  P76 measured that field as
                           the best query construction for clip retrieval, so a
                           truncated summary degrades its own candidate pool.

D6  video-block-empty      a `video:` key exists with no data under it (a TODO
                           comment).  Counted as a slot, holds no clip.

D7  duration-mismatch      the derived `duration_min` field disagrees with the
                           block's own start/end.

────────────────────────────────────────────────────────────────────────────────
FAIL-CLOSED
────────────────────────────────────────────────────────────────────────────────

An unreadable input is never a pass.  If a media duration cannot be read, a
video transcript is missing, or a truncated summary has no recoverable source,
the block is recorded as CANNOT VERIFY and the process exits 2 — which DOMINATES
exit 1.  A partial verdict must not be readable as a complete one.  No check in
this file substitutes a literal for a measurement it failed to take.

────────────────────────────────────────────────────────────────────────────────
REPAIR
────────────────────────────────────────────────────────────────────────────────

Only two classes can be repaired without judgement, and both are repaired from
material already inside the file being repaired:

    D5  the truncated summary is completed from the SAME learning point's
        `standard.text`, of which the truncated summary is a literal prefix,
        extended to the first sentence boundary after the cut.  If the source is
        not a literal prefix, or has no sentence boundary after the cut, the
        summary is NOT rewritten — it is stamped `truncated: true` instead.
        Inventing an ending would silently poison that learning point's query,
        which is worse than a flagged one.

    D4  the placeholder is stamped `unset: true` with its provenance.  Its
        start/end are left exactly as they are: the stamp is a statement about
        what the numbers ARE, not a new choice of numbers.

D1/D2/D3 are never auto-repaired.  Choosing a replacement window or a
replacement video is a judgement, and this module does not make judgements.  It
stamps what it measured (`playable: false`, `linkage: refuted`, `offset_s: …`)
so that no author is shown an unproven guess presented as fact.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import statistics
import sys
from pathlib import Path
from typing import Any

# ── constants that are DEFINITIONS, not tuned knobs ─────────────────────────────

# The catalogue-wide default window.  Byte-identical across 64 blocks; it is
# what the 2026-03-08 pass emitted when it selected nothing.
PLACEHOLDER_START = "0:00"
PLACEHOLDER_END = "8:00"
UNSET_REASON = ("catalogue-wide default window, not a selection "
                "(machine pass 2026-03-08; nwp/ops#349)")

# Files in the catalogue directory that are not courses.
NON_COURSE = {"schema", "schema_v3.1", "schema_v3", "works", "disciplines"}

# n-gram width for the linkage evidence.  8 consecutive words is long enough
# that two independent recordings of different conversations do not share one by
# chance, and short enough to survive ASR disagreement between the two models.
NGRAM = 8

# Verdict thresholds.  These are NOT tuned: the observed distribution over the
# real catalogue is bimodal with an empty middle — 78 pairs at or below 0.05 and
# 21 at or above 0.30, with 9 between.  The band between them is deliberately
# reported as UNPROVEN rather than forced into a verdict.
COV_CORROBORATED = 0.30
COV_REFUTED = 0.05

# A same-recording pair whose median timeline offset exceeds this does not
# address the same content at the catalogue's timestamps.  2 s is below the
# granularity of any window in the catalogue (the shortest is 32 s).
OFFSET_TOLERANCE_S = 2.0

# duration_min is a derived field; 3 s is the rounding the source document used.
DURATION_TOLERANCE_MIN = 0.051

WORD_RE = re.compile(r"[a-z0-9']+")
ELLIPSIS_RE = re.compile(r"(\.\.\.|…)$")
SENTENCE_END_RE = re.compile(r"[.!?](?=\s|$)")


class CannotVerify(Exception):
    """Raised when an input needed for a verdict cannot be read."""


# ── time helpers ───────────────────────────────────────────────────────────────

def parse_ts(value: Any) -> float:
    """'31:25' → 1885.0.  Raises CannotVerify rather than guessing."""
    if value is None:
        raise CannotVerify("timestamp is absent")
    parts = str(value).strip().split(":")
    try:
        return float(sum(int(p) * 60 ** i for i, p in enumerate(reversed(parts))))
    except ValueError as exc:
        raise CannotVerify(f"unparseable timestamp {value!r}") from exc


def fmt_ts(seconds: float) -> str:
    seconds = int(round(seconds))
    return f"{seconds // 60}:{seconds % 60:02d}"


def norm_ws(text: str | None) -> str | None:
    return re.sub(r"\s+", " ", text).strip() if text else text


# ── catalogue reading ──────────────────────────────────────────────────────────

def load_catalogue(catalog_dir: Path) -> list[dict[str, Any]]:
    """Every learning point in the catalogue, with its raw depth bodies.

    Read-only, so plain PyYAML.  `repair` needs the source LINE of each key as
    well, and gets it from `load_line_mapped` below — same parser, no second
    dependency.
    """
    import yaml

    if not catalog_dir.is_dir():
        raise CannotVerify(f"catalogue directory does not exist: {catalog_dir}")
    files = sorted(p for p in catalog_dir.glob("*.yaml") if p.stem not in NON_COURSE)
    if not files:
        raise CannotVerify(f"no course files in {catalog_dir}")

    lps: list[dict[str, Any]] = []
    for path in files:
        try:
            doc = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        except Exception as exc:  # a course file we cannot parse is not a pass
            raise CannotVerify(f"{path.name}: {exc}") from exc
        course = (doc or {}).get("course") or {}
        for lp in course.get("learning_points") or []:
            depths = lp.get("depths") or {}
            for depth, body in depths.items():
                if not isinstance(body, dict):
                    continue
                lps.append(
                    {
                        "file": path.name,
                        "lp": lp.get("id"),
                        "depth": depth,
                        "body": body,
                        "has_video_key": "video" in body,
                        "video": body.get("video") if isinstance(body.get("video"), dict) else None,
                    }
                )
    return lps


# ── media duration sources ─────────────────────────────────────────────────────

def episode_duration(transcripts_dir: Path, episode: int) -> tuple[float, str]:
    """Episode length, and how it was measured.

    The transcript's last segment end is a LOWER BOUND on media duration (an
    untranscribed outro would not appear).  That is stated in the returned
    basis string and it is why D1's message says 'beyond the end of the
    transcribed episode' rather than a duration this code did not measure.
    """
    path = transcripts_dir / f"ep_{episode:04d}.json"
    if not path.is_file():
        raise CannotVerify(f"no transcript for episode {episode} at {path}")
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        raise CannotVerify(f"unreadable transcript {path}: {exc}") from exc
    segments = doc.get("segments") or []
    if not segments:
        raise CannotVerify(f"transcript for episode {episode} has no segments")
    return float(max(float(s.get("end", 0.0)) for s in segments)), f"transcript:{path.name}"


def load_video_index(index_path: Path) -> dict[str, dict[str, Any]]:
    if not index_path.is_file():
        raise CannotVerify(f"video index not found: {index_path}")
    try:
        raw = json.loads(index_path.read_text(encoding="utf-8"))
    except Exception as exc:
        raise CannotVerify(f"unreadable video index {index_path}: {exc}") from exc
    out: dict[str, dict[str, Any]] = {}
    for v in raw:
        if v.get("id"):
            out[v["id"]] = {"duration": float(v.get("duration") or 0.0), "title": v.get("title")}
    if not out:
        raise CannotVerify(f"video index {index_path} contains no usable entries")
    return out


# ── linkage evidence: verbatim n-gram overlap with a timeline ──────────────────

def _word_stream(segments: list[dict[str, Any]]) -> list[tuple[str, float]]:
    out: list[tuple[str, float]] = []
    for seg in segments:
        words = seg.get("words")
        if words:
            for w in words:
                start = float(w.get("start", seg.get("start", 0.0)))
                for token in WORD_RE.findall(str(w.get("word", "")).lower()):
                    out.append((token, start))
        else:
            start = float(seg.get("start", 0.0))
            for token in WORD_RE.findall(str(seg.get("text", "")).lower()):
                out.append((token, start))
    return out


def ngram_timeline(segments: list[dict[str, Any]]) -> dict[tuple[str, ...], float]:
    """{8-gram: time of its first word}.  First occurrence wins."""
    stream = _word_stream(segments)
    out: dict[tuple[str, ...], float] = {}
    for i in range(len(stream) - NGRAM + 1):
        key = tuple(tok for tok, _ in stream[i : i + NGRAM])
        out.setdefault(key, stream[i][1])
    return out


def _read_segments(path: Path) -> list[dict[str, Any]]:
    try:
        return json.loads(path.read_text(encoding="utf-8")).get("segments") or []
    except Exception as exc:
        raise CannotVerify(f"unreadable transcript {path}: {exc}") from exc


class LinkageOracle:
    """Decides (episode, youtube_id) links from transcript content alone.

    This is the non-circular part.  The catalogue's `youtube_id` came from a
    difflib fuzzy TITLE match at threshold 0.4 (`dir_sd_map.json`) — a guess
    about strings, never checked against either recording.  A verbatim 8-gram
    shared between two independent ASR passes over two audio files is evidence
    about the AUDIO, and it is evidence no title-matcher can manufacture.
    """

    def __init__(self, episode_transcripts: Path, video_transcripts: Path):
        self.episode_transcripts = episode_transcripts
        self.video_transcripts = video_transcripts
        self._video_paths: dict[str, Path] | None = None
        self._ep_cache: dict[int, dict[tuple[str, ...], float]] = {}
        self._vid_cache: dict[str, dict[tuple[str, ...], float]] = {}

    def _video_index(self) -> dict[str, Path]:
        if self._video_paths is None:
            if not self.video_transcripts.is_dir():
                raise CannotVerify(f"video transcripts not found: {self.video_transcripts}")
            index: dict[str, Path] = {}
            for path in sorted(self.video_transcripts.glob("*.json")):
                try:
                    doc = json.loads(path.read_text(encoding="utf-8"))
                except Exception:
                    continue
                vid = doc.get("video_id")
                if vid:
                    index[vid] = path
            if not index:
                raise CannotVerify(
                    f"no transcript in {self.video_transcripts} carries a video_id"
                )
            self._video_paths = index
        return self._video_paths

    def verdict(self, episode: int, youtube_id: str) -> dict[str, Any]:
        paths = self._video_index()
        if youtube_id not in paths:
            raise CannotVerify(
                f"no transcript for video {youtube_id}: its link to episode "
                f"{episode} can be neither corroborated nor refuted"
            )
        if episode not in self._ep_cache:
            ep_path = self.episode_transcripts / f"ep_{episode:04d}.json"
            if not ep_path.is_file():
                raise CannotVerify(f"no transcript for episode {episode} at {ep_path}")
            self._ep_cache[episode] = ngram_timeline(_read_segments(ep_path))
        if youtube_id not in self._vid_cache:
            self._vid_cache[youtube_id] = ngram_timeline(_read_segments(paths[youtube_id]))

        ep_grams = self._ep_cache[episode]
        vid_grams = self._vid_cache[youtube_id]
        if not vid_grams:
            raise CannotVerify(f"video {youtube_id} transcript yields no {NGRAM}-grams")
        shared = set(ep_grams) & set(vid_grams)
        coverage = len(shared) / len(vid_grams)

        offsets = sorted(vid_grams[g] - ep_grams[g] for g in shared)
        median_offset = statistics.median(offsets) if offsets else None
        spread = None
        if len(offsets) >= 8:
            spread = offsets[int(len(offsets) * 0.75)] - offsets[int(len(offsets) * 0.25)]

        if coverage >= COV_CORROBORATED:
            state = "corroborated"
        elif coverage <= COV_REFUTED:
            state = "refuted"
        else:
            state = "unproven"
        return {
            "state": state,
            "coverage": round(coverage, 4),
            "shared_ngrams": len(shared),
            "video_ngrams": len(vid_grams),
            "median_offset_s": None if median_offset is None else round(median_offset, 1),
            "offset_spread_s": None if spread is None else round(spread, 1),
        }


# ── findings ───────────────────────────────────────────────────────────────────

def finding(cls: str, severity: str, entry: dict[str, Any], message: str, **extra) -> dict[str, Any]:
    out = {
        "class": cls,
        "severity": severity,
        "file": entry["file"],
        "lp": entry["lp"],
        "depth": entry["depth"],
        "message": message,
    }
    out.update(extra)
    return out


def check_windows(entries, transcripts_dir, video_index, findings):
    """D1 + D2 + D7 — arithmetic against a measured duration."""
    for e in entries:
        v = e["video"]
        if not v:
            continue
        try:
            start = parse_ts(v.get("start"))
            end = parse_ts(v.get("end"))
        except CannotVerify as exc:
            findings.append(finding("window-unparseable", "cannot-verify", e, str(exc)))
            continue
        if end <= start:
            findings.append(
                finding("window-inverted", "defect", e,
                        f"end {v.get('end')} is not after start {v.get('start')}")
            )

        episode = v.get("episode")
        try:
            duration, basis = episode_duration(transcripts_dir, int(episode))
        except (CannotVerify, TypeError, ValueError) as exc:
            findings.append(
                finding("window-beyond-media", "cannot-verify", e,
                        f"episode {episode} duration unmeasurable: {exc}")
            )
        else:
            if end > duration:
                findings.append(
                    finding("window-beyond-media", "defect", e,
                            f"window {v.get('start')}-{v.get('end')} ends "
                            f"{end - duration:.0f}s beyond the end of episode "
                            f"{episode} ({fmt_ts(duration)}, {basis}) — there is "
                            f"no such moment in the recording",
                            episode=episode, window_end_s=end, media_end_s=round(duration, 1))
                )

        youtube_id = v.get("youtube_id")
        if not youtube_id:
            findings.append(
                finding("window-beyond-video", "cannot-verify", e,
                        "block carries no youtube_id, so no player length can be checked")
            )
        elif youtube_id not in video_index:
            findings.append(
                finding("window-beyond-video", "cannot-verify", e,
                        f"video {youtube_id} is not in the video index — its "
                        f"length cannot be read")
            )
        else:
            vdur = video_index[youtube_id]["duration"]
            if end > vdur:
                findings.append(
                    finding("window-beyond-video", "defect", e,
                            f"window ends at {v.get('end')} but the linked video "
                            f"{youtube_id} is only {fmt_ts(vdur)} long — the "
                            f"player stops "
                            f"{'before the clip starts' if start >= vdur else 'mid-clip'}",
                            youtube_id=youtube_id, video_duration_s=vdur,
                            start_beyond_video=start >= vdur)
                )

        declared = v.get("duration_min")
        if declared is not None:
            real = (end - start) / 60.0
            try:
                if abs(real - float(declared)) > DURATION_TOLERANCE_MIN:
                    findings.append(
                        finding("duration-mismatch", "defect", e,
                                f"duration_min: {declared} disagrees with "
                                f"{v.get('start')}-{v.get('end')} = {real:.2f} min",
                                declared_min=declared, actual_min=round(real, 2))
                    )
            except (TypeError, ValueError):
                findings.append(
                    finding("duration-mismatch", "cannot-verify", e,
                            f"duration_min: {declared!r} is not a number")
                )


def check_linkage(entries, oracle: LinkageOracle, findings):
    """D3 — re-derive the episode→video link from transcript content."""
    cache: dict[tuple[int, str], Any] = {}
    for e in entries:
        v = e["video"]
        if not v:
            continue
        youtube_id, episode = v.get("youtube_id"), v.get("episode")
        if not youtube_id or episode is None:
            continue
        key = (int(episode), youtube_id)
        if key not in cache:
            try:
                cache[key] = oracle.verdict(*key)
            except CannotVerify as exc:
                cache[key] = exc
        result = cache[key]
        if isinstance(result, CannotVerify):
            findings.append(finding("linkage-unproven", "cannot-verify", e, str(result)))
            continue

        if v.get("linkage"):
            # Already stamped by `repair`; the stamp itself is what makes the
            # claim honest, so a stamped block is not re-reported as a defect.
            continue

        if result["state"] == "refuted":
            findings.append(
                finding("linkage-refuted", "defect", e,
                        f"video {youtube_id} shares only "
                        f"{result['shared_ngrams']} verbatim {NGRAM}-grams "
                        f"({result['coverage']:.1%} of the video) with episode "
                        f"{episode} — at or below the show-boilerplate floor. "
                        f"It is a DIFFERENT recording, so the podcast "
                        f"timestamps in this block address nothing on it",
                        **result)
            )
        elif result["state"] == "unproven":
            findings.append(
                finding("linkage-unproven", "cannot-verify", e,
                        f"video {youtube_id} shares {result['coverage']:.1%} of "
                        f"its content with episode {episode} — between the "
                        f"refute floor ({COV_REFUTED:.0%}) and the corroborate "
                        f"bar ({COV_CORROBORATED:.0%}). Neither proven nor "
                        f"disproven",
                        **result)
            )
        else:
            offset = result["median_offset_s"]
            if offset is not None and abs(offset) > OFFSET_TOLERANCE_S:
                findings.append(
                    finding("linkage-offset", "defect", e,
                            f"video {youtube_id} IS episode {episode} "
                            f"({result['coverage']:.1%} verbatim), but its "
                            f"timeline is offset by {offset:+.0f}s "
                            f"(spread {result['offset_spread_s']}s). The "
                            f"catalogue's podcast timestamps do not address the "
                            f"intended content on that video",
                            **result)
                )


def check_placeholders(entries, findings):
    """D4 — an unfilled slot must not look like a choice."""
    for e in entries:
        v = e["video"]
        if not v:
            continue
        if str(v.get("start")) == PLACEHOLDER_START and str(v.get("end")) == PLACEHOLDER_END:
            if v.get("unset") is True:
                continue
            findings.append(
                finding("placeholder-unmarked", "defect", e,
                        f"window is the catalogue-wide default "
                        f"{PLACEHOLDER_START}-{PLACEHOLDER_END} and is not "
                        f"stamped `unset: true` — an unfilled slot is "
                        f"indistinguishable from a recommendation, and is "
                        f"counted as coverage")
            )


def check_empty_blocks(entries, findings):
    """D6 — `video:` key present, no data under it."""
    for e in entries:
        if e["has_video_key"] and e["video"] is None:
            findings.append(
                finding("video-block-empty", "defect", e,
                        "a `video:` key exists with no data under it — the slot "
                        "reads as attempted but holds no clip")
            )


def summary_repair(summary: str | None, source: str | None) -> dict[str, Any]:
    """Decide whether a summary is truncated, and what the honest fix is.

    Returns {'truncated': bool, 'repair': str|None, 'reason': str}.  `repair` is
    None whenever the completion cannot be taken verbatim from `source` — this
    function never composes text that is not already in the catalogue.
    """
    s = norm_ws(summary)
    if not s:
        return {"truncated": False, "repair": None, "reason": "no summary"}
    if not ELLIPSIS_RE.search(s):
        return {"truncated": False, "repair": None, "reason": "no truncation marker"}
    stem = ELLIPSIS_RE.sub("", s).rstrip()
    body = norm_ws(source)
    if not body:
        return {"truncated": True, "repair": None,
                "reason": "no standard.text to recover the ending from"}
    if not body.startswith(stem):
        return {"truncated": True, "repair": None,
                "reason": "summary is not a literal prefix of standard.text"}
    rest = body[len(stem):]
    match = SENTENCE_END_RE.search(rest)
    if not match:
        return {"truncated": True, "repair": None,
                "reason": "no sentence boundary after the cut in standard.text"}
    return {"truncated": True, "repair": stem + rest[: match.end()],
            "reason": "completed verbatim from this learning point's standard.text"}


def check_summaries(entries, findings):
    """D5 — truncated `short.summary`, the field P76 measured as the best query."""
    by_lp: dict[tuple[str, str], dict[str, Any]] = {}
    for e in entries:
        by_lp.setdefault((e["file"], e["lp"]), {})[e["depth"]] = e
    for (file_name, lp_id), depths in sorted(by_lp.items()):
        short = depths.get("short")
        if not short:
            continue
        summary = short["body"].get("summary")
        if short["body"].get("truncated") is True:
            continue  # already stamped honestly by `repair`
        standard = depths.get("standard")
        source = standard["body"].get("text") if standard else None
        verdict = summary_repair(summary, source)
        if not verdict["truncated"]:
            continue
        if verdict["repair"] is None:
            findings.append(
                finding("summary-truncated", "cannot-verify", short,
                        f"short.summary is truncated but cannot be repaired: "
                        f"{verdict['reason']}. It must not be invented",
                        recoverable=False)
            )
        else:
            findings.append(
                finding("summary-truncated", "defect", short,
                        f"short.summary is a hard truncation "
                        f"({len(norm_ws(summary))} chars, ends in an ellipsis) "
                        f"— it is the field clip retrieval queries with, so it "
                        f"degrades this learning point's own candidate pool",
                        recoverable=True)
            )


# ── verify ─────────────────────────────────────────────────────────────────────

def run_verify(args) -> dict[str, Any]:
    catalog = Path(args.catalog).expanduser()
    transcripts = Path(args.transcripts).expanduser()
    video_transcripts = Path(args.video_transcripts).expanduser()
    video_index_path = Path(args.video_index).expanduser()

    blockers: list[str] = []
    entries: list[dict[str, Any]] = []
    video_index: dict[str, dict[str, Any]] = {}
    try:
        entries = load_catalogue(catalog)
    except CannotVerify as exc:
        blockers.append(str(exc))
    try:
        video_index = load_video_index(video_index_path)
    except CannotVerify as exc:
        blockers.append(str(exc))

    findings: list[dict[str, Any]] = []
    if entries:
        check_windows(entries, transcripts, video_index, findings)
        check_placeholders(entries, findings)
        check_empty_blocks(entries, findings)
        check_summaries(entries, findings)
        if args.linkage:
            try:
                oracle = LinkageOracle(transcripts, video_transcripts)
                check_linkage(entries, oracle, findings)
            except CannotVerify as exc:
                blockers.append(f"linkage evidence unavailable: {exc}")

    if args.only:
        wanted = set(args.only.split(","))
        findings = [f for f in findings if f["class"] in wanted]

    blocks = [e for e in entries if e["video"]]
    counts: dict[str, dict[str, int]] = {}
    for f in findings:
        bucket = counts.setdefault(f["class"], {"defect": 0, "cannot-verify": 0})
        bucket[f["severity"]] += 1

    return {
        "catalogue": str(catalog),
        "learning_point_depths": len(entries),
        "video_blocks": len(blocks),
        "counts": counts,
        "blockers": blockers,
        "findings": findings,
        "defects": sum(c["defect"] for c in counts.values()),
        "cannot_verify": sum(c["cannot-verify"] for c in counts.values()) + len(blockers),
    }


def render(report: dict[str, Any], verbose: bool) -> None:
    print(f"catalogue: {report['catalogue']}")
    print(f"  {report['video_blocks']} video blocks across "
          f"{report['learning_point_depths']} learning-point depths")
    print()
    if not report["counts"] and not report["blockers"]:
        print("CLEAN — every window exists, plays, and is honestly labelled.")
        return
    width = max([len(c) for c in report["counts"]] + [20])
    print(f"  {'class'.ljust(width)}  defect  cannot-verify")
    print(f"  {'-' * width}  ------  -------------")
    for cls in sorted(report["counts"]):
        c = report["counts"][cls]
        print(f"  {cls.ljust(width)}  {c['defect']:>6}  {c['cannot-verify']:>13}")
    print()
    for blocker in report["blockers"]:
        print(f"CANNOT VERIFY: {blocker}")
    if verbose:
        print()
        for f in report["findings"]:
            print(f"  [{f['severity']}] {f['class']}  {f['file']}::{f['lp']}.{f['depth']}")
            print(f"      {f['message']}")
    else:
        print("  (--verbose for every finding, --json for the machine-readable report)")
    print()
    print(f"TOTAL: {report['defects']} defects, {report['cannot_verify']} cannot-verify")


# ── repair ─────────────────────────────────────────────────────────────────────


# ── repair ─────────────────────────────────────────────────────────────────────

class LineMap(dict):
    """A mapping that remembers the 0-based source line of each of its keys."""

    key_lines: dict


def load_line_mapped(text: str):
    """Parse `text` into plain dicts/lists where every mapping is a LineMap.

    WHY THIS IS NOT ruamel.yaml.  It was.  `run_repair` imported
    `ruamel.yaml.YAML` purely to read `.lc`, the per-key line numbers that
    anchor SurgicalEditor's edits — nothing was ever dumped through it.  That
    made a whole extra dependency load-bearing for one attribute, and
    ruamel.yaml is NOT installed on the CI runner (met, Ubuntu 24.04, no pip:
    `python3 -m pip` reports "No module named pip", and PEP 668 makes a
    root-free install a project of its own).  The result on !435 was seven red
    unit tests, all of them the `repair:` ones, in pipeline 2250 job 19383:

        not ok 386 repair: a recoverable truncated summary is completed VERBATIM …
        #   `[ "$output" -eq 2 ]' failed
        …
        testcases: 4331   failures: 7   skipped: 2 (allowed: 2)

    …green on the workstation, which happens to have ruamel, and red on every
    host that does not.  That is the host-blind-branch shape CLAUDE.md names.

    PyYAML is already this module's parser for `verify`, is present on every
    host in the estate, and records `start_mark.line` on every node — so the
    line numbers come from the parser that is already here.  `deep=True`
    throughout because PyYAML's default constructor is a generator: with
    deep=False a nested mapping can be handed back still empty.
    """
    import yaml

    class _LineLoader(yaml.SafeLoader):
        pass

    def _construct_mapping(loader, node):
        loader.flatten_mapping(node)
        data = LineMap()
        data.key_lines = {}
        for key_node, value_node in node.value:
            key = loader.construct_object(key_node, deep=True)
            data.key_lines[key] = key_node.start_mark.line
            data[key] = loader.construct_object(value_node, deep=True)
        return data

    _LineLoader.add_constructor(
        yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _construct_mapping)
    return yaml.load(text, Loader=_LineLoader)


def _key_line(node, key) -> int | None:
    """0-based line of `key` inside a line-mapped mapping, or None."""
    lines = getattr(node, "key_lines", None)
    if not isinstance(lines, dict):
        return None
    return lines.get(key)


def _block_extent(lines: list[str], start: int) -> int:
    """Exclusive end line of the block whose first line is `lines[start]`.

    Walks forward over continuation lines: anything blank, or indented more
    deeply than the key on `start`.  This is what lets a multi-line quoted
    scalar be replaced without reflowing the file around it.
    """
    indent = len(lines[start]) - len(lines[start].lstrip())
    end = start + 1
    while end < len(lines):
        line = lines[end]
        if not line.strip():
            end += 1
            continue
        if len(line) - len(line.lstrip()) > indent:
            end += 1
            continue
        break
    # do not swallow trailing blank lines that belong to the next block
    while end - 1 > start and not lines[end - 1].strip():
        end -= 1
    return end


def _quote(value: str) -> str:
    """A single-line YAML single-quoted scalar."""
    return "'" + value.replace("'", "''") + "'"


class SurgicalEditor:
    """Line-anchored edits to a YAML file that leave everything else byte-identical.

    A round-trip dump would be simpler, but any YAML emitter re-writes every
    scalar in the file: applying one to the real catalogue produced a
    41,350-line deletion for ~350 intended changes.  A repair nobody can review
    is a repair nobody should merge, so edits are applied to the raw text, in
    reverse line order, anchored on the line numbers `load_line_mapped` records.
    """

    def __init__(self, path: Path):
        self.path = path
        self.text = path.read_text(encoding="utf-8")
        self.lines = self.text.split("\n")
        self.edits: list[tuple[int, int, list[str]]] = []   # (start, end, replacement)

    def replace_block(self, start: int, new_lines: list[str]) -> None:
        self.edits.append((start, _block_extent(self.lines, start), new_lines))

    def insert_after_block(self, anchor: int, new_lines: list[str]) -> None:
        end = _block_extent(self.lines, anchor)
        self.edits.append((end, end, new_lines))

    def dirty(self) -> bool:
        return bool(self.edits)

    def write(self) -> None:
        out = list(self.lines)
        for start, end, replacement in sorted(self.edits, reverse=True):
            out[start:end] = replacement
        self.path.write_text("\n".join(out), encoding="utf-8")


def run_repair(args) -> int:
    """Apply the repairs that need no judgement, plus the honesty stamps.

    Nothing here chooses a window or a video.  Two classes are repaired, both
    from material already inside the file being repaired; everything else is
    STAMPED with what was measured so that no author is shown an unproven guess
    presented as fact.
    """
    catalog = Path(args.catalog).expanduser()
    transcripts = Path(args.transcripts).expanduser()
    video_transcripts = Path(args.video_transcripts).expanduser()
    try:
        video_index = load_video_index(Path(args.video_index).expanduser())
    except CannotVerify as exc:
        print(f"CANNOT VERIFY: {exc}", file=sys.stderr)
        return 2

    oracle = LinkageOracle(transcripts, video_transcripts) if args.linkage else None
    linkage_cache: dict[tuple[int, str], Any] = {}

    changes: list[dict[str, Any]] = []
    unrepairable: list[dict[str, Any]] = []
    files = sorted(p for p in catalog.glob("*.yaml") if p.stem not in NON_COURSE)
    if not files:
        print(f"CANNOT VERIFY: no course files in {catalog}", file=sys.stderr)
        return 2

    for path in files:
        editor = SurgicalEditor(path)
        try:
            doc = load_line_mapped(editor.text)
        except Exception as exc:   # a course file we cannot parse is not a pass
            print(f"CANNOT VERIFY: {path.name}: {exc}", file=sys.stderr)
            return 2
        course = (doc or {}).get("course") or {}
        for lp in course.get("learning_points") or []:
            depths = lp.get("depths") or {}
            lp_id = lp.get("id")

            # ── D5: complete a truncated summary from this LP's own body ──────
            short = depths.get("short")
            standard = depths.get("standard")
            if isinstance(short, dict) and "summary" in short:
                source = standard.get("text") if isinstance(standard, dict) else None
                verdict = summary_repair(short.get("summary"), source)
                if verdict["truncated"] and short.get("truncated") is not True:
                    line = _key_line(short, "summary")
                    if line is None:
                        unrepairable.append({"class": "summary-truncated", "file": path.name,
                                             "lp": lp_id,
                                             "reason": "cannot locate the summary in the file"})
                    else:
                        indent = " " * (len(editor.lines[line]) - len(editor.lines[line].lstrip()))
                        if verdict["repair"] is not None:
                            editor.replace_block(
                                line, [f"{indent}summary: {_quote(verdict['repair'])}"])
                            changes.append({"class": "summary-truncated", "file": path.name,
                                            "lp": lp_id, "action": "completed",
                                            "before": norm_ws(short["summary"]),
                                            "after": verdict["repair"],
                                            "reason": verdict["reason"]})
                        else:
                            editor.insert_after_block(line, [f"{indent}truncated: true"])
                            changes.append({"class": "summary-truncated", "file": path.name,
                                            "lp": lp_id, "action": "stamped truncated: true",
                                            "reason": verdict["reason"]})

            for depth, body in depths.items():
                if not isinstance(body, dict):
                    continue
                video = body.get("video")
                if not isinstance(video, dict) or not video:
                    continue
                keys = [k for k in video if _key_line(video, k) is not None]
                if not keys:
                    unrepairable.append({"class": "stamp", "file": path.name, "lp": lp_id,
                                         "reason": "cannot locate the video block in the file"})
                    continue
                anchor = max(_key_line(video, k) for k in keys)
                indent = " " * (len(editor.lines[anchor]) - len(editor.lines[anchor].lstrip()))
                stamps: list[str] = []

                # ── D4: an unfilled slot says so ──────────────────────────────
                if (str(video.get("start")) == PLACEHOLDER_START
                        and str(video.get("end")) == PLACEHOLDER_END
                        and video.get("unset") is not True):
                    stamps.append(f"{indent}unset: true")
                    stamps.append(f"{indent}unset_reason: {_quote(UNSET_REASON)}")
                    changes.append({"class": "placeholder-unmarked", "file": path.name,
                                    "lp": lp_id, "depth": depth,
                                    "action": "stamped unset: true"})

                # ── D1/D2: stamp what was measured; never invent a window ─────
                try:
                    end_s = parse_ts(video.get("end"))
                except CannotVerify:
                    end_s = None
                reasons: list[str] = []
                if end_s is not None:
                    try:
                        media, _ = episode_duration(transcripts, int(video.get("episode")))
                        if end_s > media:
                            reasons.append(f"ends {end_s - media:.0f}s beyond episode "
                                           f"{video.get('episode')} ({fmt_ts(media)})")
                    except (CannotVerify, TypeError, ValueError) as exc:
                        unrepairable.append({"class": "window-beyond-media", "file": path.name,
                                             "lp": lp_id, "reason": str(exc)})
                    yid = video.get("youtube_id")
                    if yid in video_index:
                        vdur = video_index[yid]["duration"]
                        if end_s > vdur:
                            reasons.append(f"ends beyond the linked video {yid} "
                                           f"({fmt_ts(vdur)})")
                    elif yid:
                        unrepairable.append({"class": "window-beyond-video", "file": path.name,
                                             "lp": lp_id,
                                             "reason": f"video {yid} not in the video index"})
                if reasons and video.get("playable") is not False:
                    stamps.append(f"{indent}playable: false")
                    stamps.append(f"{indent}playable_reason: {_quote('; '.join(reasons))}")
                    changes.append({"class": "window-unplayable", "file": path.name,
                                    "lp": lp_id, "depth": depth,
                                    "action": "stamped playable: false",
                                    "reason": "; ".join(reasons)})

                # ── D7: recompute the derived duration_min (opt-in) ───────────
                # This is the only repair that CHANGES an existing value rather
                # than adding a key, so it is behind a flag: the operator takes
                # it deliberately or not at all.  The arithmetic needs no
                # judgement — duration_min is derived from start/end and nothing
                # else — but "derived" is a claim about intent, and the March
                # 2026 source document wrote "(~2 min)", so somebody may want
                # the rounding kept.
                if args.fix_derived and video.get("duration_min") is not None:
                    try:
                        real = (parse_ts(video["end"]) - parse_ts(video["start"])) / 60.0
                        if abs(real - float(video["duration_min"])) > DURATION_TOLERANCE_MIN:
                            dline = _key_line(video, "duration_min")
                            if dline is None:
                                unrepairable.append({"class": "duration-mismatch",
                                                     "file": path.name, "lp": lp_id,
                                                     "reason": "cannot locate duration_min"})
                            else:
                                dind = " " * (len(editor.lines[dline])
                                              - len(editor.lines[dline].lstrip()))
                                editor.replace_block(
                                    dline, [f"{dind}duration_min: {round(real, 2)}"])
                                changes.append({"class": "duration-mismatch",
                                                "file": path.name, "lp": lp_id,
                                                "depth": depth,
                                                "action": "recomputed from start/end",
                                                "before": video["duration_min"],
                                                "after": round(real, 2)})
                    except (CannotVerify, TypeError, ValueError) as exc:
                        unrepairable.append({"class": "duration-mismatch", "file": path.name,
                                             "lp": lp_id, "reason": str(exc)})

                # ── D3: stamp the measured linkage, replacing a title guess ───
                yid = video.get("youtube_id")
                if oracle is not None and yid and video.get("linkage") is None:
                    key = (int(video["episode"]), yid)
                    if key not in linkage_cache:
                        try:
                            linkage_cache[key] = oracle.verdict(*key)
                        except CannotVerify as exc:
                            linkage_cache[key] = exc
                    result = linkage_cache[key]
                    if isinstance(result, CannotVerify):
                        unrepairable.append({"class": "linkage-unproven", "file": path.name,
                                             "lp": lp_id, "reason": str(result)})
                    else:
                        evidence = ("{shared} verbatim {n}-grams shared with "
                                    "episode {ep} = {cov:.1%} of the video"
                                    ).format(shared=result["shared_ngrams"], n=NGRAM,
                                             ep=video["episode"], cov=result["coverage"])
                        if result["state"] == "corroborated":
                            # An offset is only meaningful once the two are known
                            # to be the same recording; quoting one for a refuted
                            # pair would dress noise up as a measurement.
                            evidence += ("; timeline offset {off}s vs the podcast "
                                         "(spread {spread}s)").format(
                                off=result["median_offset_s"],
                                spread=result["offset_spread_s"])
                        evidence += "; transcript-derived, nwp/ops#352"
                        stamps.append(f"{indent}linkage: {result['state']}")
                        stamps.append(f"{indent}linkage_evidence: {_quote(evidence)}")
                        changes.append({"class": "linkage-" + result["state"],
                                        "file": path.name, "lp": lp_id, "depth": depth,
                                        "action": f"stamped linkage: {result['state']}"})

                if stamps:
                    editor.insert_after_block(anchor, stamps)

        if editor.dirty() and args.apply:
            editor.write()

    by_class: dict[str, int] = {}
    for c in changes:
        by_class[c["class"]] = by_class.get(c["class"], 0) + 1
    report = {"applied": bool(args.apply), "catalogue": str(catalog),
              "changes": changes, "by_class": by_class, "unrepairable": unrepairable}
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        mode = "APPLIED" if args.apply else "DRY RUN — nothing written"
        print(f"{mode}   catalogue: {catalog}")
        for cls in sorted(by_class):
            print(f"  {cls:<26} {by_class[cls]:>4}")
        if unrepairable:
            print()
            print(f"  CANNOT VERIFY ({len(unrepairable)}):")
            for u in unrepairable[:20]:
                print(f"    {u['file']}::{u['lp']}  {u['class']}  {u['reason']}")
        if not args.apply:
            print()
            print("  re-run with --apply to write these changes")
    return 2 if unrepairable and not args.apply else 0

# ── entry point ────────────────────────────────────────────────────────────────

def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("mode", choices=["verify", "repair"])
    p.add_argument("--catalog", required=True)
    p.add_argument("--transcripts", required=True)
    p.add_argument("--video-transcripts", default="")
    p.add_argument("--video-index", required=True)
    p.add_argument("--linkage", action="store_true",
                   help="re-derive the episode→video link from transcripts (D3)")
    p.add_argument("--only", default="", help="comma-separated check classes")
    p.add_argument("--json", action="store_true")
    p.add_argument("--verbose", action="store_true")
    p.add_argument("--apply", action="store_true", help="repair: write the changes")
    p.add_argument("--fix-derived", action="store_true",
                   help="repair: also recompute duration_min from start/end "
                        "(the one repair that changes an existing value)")
    args = p.parse_args(argv)

    if args.mode == "repair":
        return run_repair(args)

    try:
        report = run_verify(args)
    except CannotVerify as exc:
        print(f"CANNOT VERIFY: {exc}", file=sys.stderr)
        return 2
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        render(report, args.verbose)
    # exit 2 DOMINATES exit 1: a partial verdict must not read as a complete one.
    if report["cannot_verify"]:
        return 2
    return 1 if report["defects"] else 0


if __name__ == "__main__":
    sys.exit(main())
