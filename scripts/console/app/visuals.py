"""Visuals — the at-a-glance graphical view of the fleet. Pure, stdlib only.

WHAT THIS MODULE IS
-------------------
Everything here turns an ALREADY-SCOPED gatherer result into SVG *geometry*:
plain dicts of x/y/width/path/label. The templates then emit `<svg>` and place
those numbers. Nothing here does I/O, spawns anything, or knows what a Scope is
— the narrowing happened before the data arrived (main.py's `_gather_*(sc)`),
which is the same division of labour `advisories.read_feed` uses.

Consequences that are deliberate:

  * the charts are unit-testable **without** jinja2, fastapi or a filesystem —
    the geometry is just arithmetic, so the test suite asserts on numbers
    rather than on scraped markup;
  * this module cannot leak, because it never chooses what it is given;
  * every row it emits for a per-site chart carries the `site` key, so
    `scope.scrub()` can still drop a foreign row if a future gatherer regresses.
    Under SCOPE_STRICT that drop RAISES — which is the point. A chart row keyed
    any other way would be invisible to the scrubber and silently exempt from
    net 2.

NO COLOR IS DECIDED HERE, ON PURPOSE
------------------------------------
Python emits a *role* ("crit"/"warn"/"ok"/"muted"); the template maps the role
to a CSS class that resolves to the console's existing `--err`/`--warn`/`--ok`/
`--muted` custom properties. So the charts follow the console's theme from the
one place it is already defined, and a retheme never has to be repeated here.

WHY EVERY MARK ALSO CARRIES TEXT
--------------------------------
This is a measurement, not a preference. The console's status trio was run
through the data-viz palette validator against this app's own chart surface
(`--card` #1a212b, dark):

    green #3fb96a  vs  amber #e0a93f   ->  CVD dE 4.5 (protan)

4.5 is below even the 6-8 "legal only with secondary encoding" band. A reader
with the most common form of colour-blindness cannot tell a GREEN site from an
AMBER one by colour. So the grade word, the severity name and the pipeline
status word are load-bearing content, not decoration: **no state in this pane
is ever encoded by colour alone**, and every chart ships a table-view twin.

(Contrast vs the surface PASSES for all four roles at >= 3:1, so the marks
themselves are legible; it is only hue-vs-hue that fails.)
"""
from __future__ import annotations

# --- canvas -----------------------------------------------------------------
# One viewBox width for every chart so they align down the pane. The <svg> is
# rendered at width:100% with a max-width, so this is a coordinate system, not
# a pixel size.
CHART_W = 360

GAP = 2                 # THE surface gap: between stacked segments and tiles alike
RADIUS = 4              # rounded data-end
BAR_H = 14              # bar thickness (the spec caps this at 24)
ROW_H = 24              # row pitch for bar charts
FLEET_BAR_H = 18

# Rough advance width per character for the console's 11.5px system-ui labels.
# Used ONLY to decide whether a label FITS; when it does not, the label is
# dropped to the legend/table rather than clipped or overflowed.
_CHAR_PX = 6.3

# --- roles ------------------------------------------------------------------
# The four states this pane can paint, mapped to the console's own tokens by
# the template. "muted" means *unknown*, never "fine".
ROLES = ("crit", "warn", "ok", "muted")

_GRADE_ROLE = {"RED": "crit", "AMBER": "warn", "GREEN": "ok"}

# critical and high deliberately SHARE the console's red.
#
# A distinct orange step for `high` was tried (#ec835a, the data-viz status
# "serious" step) and REJECTED on measurement: against #e2604f it scores
# normal-vision dE 7.9, below the hard floor of 15 — i.e. a reader with full
# colour vision cannot reliably tell the two bars apart. A scale that LOOKS
# five-valued but reads as four is worse than an honest four, so `high` keeps
# the red it already wears everywhere else in the console (.chip.sev-high,
# .adv.sev-high) and is told apart by its label.
_SEV_ROLE = {"critical": "crit", "high": "crit", "medium": "warn", "low": "ok"}

_PRIO_ROLE = {"high": "crit", "medium": "warn", "low": "muted"}

# low priority is MUTED, not green: a low-priority todo is not good news, it is
# merely not urgent. Green here would read as "resolved".

_CI_ROLE = {"success": "ok", "failed": "crit", "running": "warn", "pending": "warn",
            "created": "warn", "waiting_for_resource": "warn", "preparing": "warn"}

SEVERITY_LADDER = ("critical", "high", "medium", "low", "unknown")
PRIORITY_LADDER = ("high", "medium", "low")


# ---------------------------------------------------------------------------
# small geometry helpers
# ---------------------------------------------------------------------------
def _num(value) -> int:
    """Any feed value -> a non-negative int. Never raises: a chart must not be
    the thing that 500s because a publisher wrote a string where a count went."""
    try:
        n = int(value)
    except (TypeError, ValueError):
        return 0
    return max(0, n)


def fits(text: str, width: float, size: float = 11.5) -> bool:
    """Does `text` fit in `width` px with padding on both sides?

    The spec is explicit that a label which does not fit is moved out or
    dropped to the legend/table — never clipped, never overflowed. This is the
    predicate that decides, and it is deliberately pessimistic.
    """
    return len(str(text)) * (_CHAR_PX * size / 11.5) + 10 <= width


def clamp_text(text: str, width: float, size: float = 11.5) -> str:
    """Truncate with an ellipsis to fit `width`. The FULL value always survives
    in the row's <title> and in the table-view twin, so nothing is gated."""
    text = str(text or "")
    per = _CHAR_PX * size / 11.5
    room = int(max(0, (width - 4) // per))
    if len(text) <= room:
        return text
    return text[: max(0, room - 1)] + "…" if room > 1 else ""


def bar_path(x: float, y: float, w: float, h: float, r: float = RADIUS,
             left: bool = False, right: bool = True) -> str:
    """A rect with only the chosen ends rounded — the 'rounded data-end, square
    at the baseline' rule. Returns an SVG path `d`.

    Rounding is applied per END rather than per corner because a stacked bar's
    interior joins must stay square: rounding them would open a wedge of
    surface between segments that reads as a gap that is not the 2px spacer.
    """
    w = max(0.0, float(w))
    h = float(h)
    r = max(0.0, min(float(r), w / 2.0, h / 2.0))
    return _bar_path_full(x, y, w, h, r if left else 0.0, r if right else 0.0)


def _bar_path_full(x: float, y: float, w: float, h: float, lr: float, rr: float) -> str:
    """The workhorse: `lr`/`rr` are the already-clamped left/right end radii."""
    w = max(0.0, float(w))
    lr = max(0.0, min(float(lr), w / 2.0, float(h) / 2.0))
    rr = max(0.0, min(float(rr), w / 2.0, float(h) / 2.0))
    parts = [f"M{x + lr:g},{y:g}", f"H{x + w - rr:g}"]
    if rr:
        parts.append(f"A{rr:g},{rr:g} 0 0 1 {x + w:g},{y + rr:g}")
    parts.append(f"V{y + h - rr:g}")
    if rr:
        parts.append(f"A{rr:g},{rr:g} 0 0 1 {x + w - rr:g},{y + h:g}")
    parts.append(f"H{x + lr:g}")
    if lr:
        parts.append(f"A{lr:g},{lr:g} 0 0 1 {x:g},{y + h - lr:g}")
    parts.append(f"V{y + lr:g}")
    if lr:
        parts.append(f"A{lr:g},{lr:g} 0 0 1 {x + lr:g},{y:g}")
    parts.append("Z")
    return " ".join(parts)


def stack(counts: list[tuple[str, int, str]], width: float, x0: float = 0.0,
          y: float = 0.0, h: float = BAR_H) -> list[dict]:
    """A horizontal stacked bar: [(label, count, role)] -> segment dicts.

    Zero-count entries are omitted entirely (a zero-width mark with a 2px gap
    on each side is 4px of surface pretending to be data). The outer ends of
    the whole bar are rounded; every interior join stays square.
    """
    live = [(label, _num(n), role) for label, n, role in counts if _num(n) > 0]
    total = sum(n for _l, n, _r in live)
    if not live or total <= 0:
        return []
    inner = max(0.0, float(width) - GAP * (len(live) - 1))
    out: list[dict] = []
    cursor = float(x0)
    for i, (label, n, role) in enumerate(live):
        w = inner * n / total
        seg = {
            "label": label,
            "count": n,
            "role": role,
            "x": round(cursor, 2),
            "y": y,
            "w": round(w, 2),
            "h": h,
            "pct": round(100.0 * n / total, 1),
            "path": _bar_path_full(round(cursor, 2), y, round(w, 2), h,
                                   RADIUS if i == 0 else 0.0,
                                   RADIUS if i == len(live) - 1 else 0.0),
        }
        # Label INSIDE the segment only when the number genuinely fits. An
        # interior segment has no free end to move a label to, so when it does
        # not fit the value is carried by the legend and the table instead.
        seg["label_inside"] = fits(str(n), w)
        seg["label_x"] = round(cursor + w / 2.0, 2)
        seg["label_y"] = round(y + h / 2.0 + 4, 2)
        out.append(seg)
        cursor += w + GAP
    return out


def _err_of(feed, default: str) -> str:
    """The error a feed reports, or `default`.

    Takes the non-dict case seriously: a gatherer that hands back a bare
    string (or None) must produce the honest no-data state, not an
    AttributeError. A chart is never allowed to be the thing that 500s the
    pane — that would turn a missing feed into a missing PANE.
    """
    if isinstance(feed, dict):
        return str(feed.get("error", "") or default)
    return default


def _nodata(reason: str, hint: str = "", kind: str = "missing") -> dict:
    """The explicit empty state.

    `kind` distinguishes the two zeros that must never look alike:
      "missing"  we could not find out            -> shouts, muted/warned
      "clean"    we DID find out, and it is zero  -> reassuring, and earned
    An empty chart with no state at all is the failure this whole console
    exists to avoid, so there is no third option.
    """
    return {"ok": False, "state": kind, "reason": reason, "hint": hint}


# ---------------------------------------------------------------------------
# V1 — fleet RAG: one part-to-whole bar + a per-site tile grid
# ---------------------------------------------------------------------------
TILE_COLS = 3
TILE_H = 34
TILE_RULE_W = 4
MAX_TILES = 24


def fleet_view(rag: dict, max_tiles: int = MAX_TILES) -> dict:
    """`_gather_rag(sc)`'s parsed result -> the fleet status visual.

    Two readings of one truth: the stacked bar answers "how is the fleet",
    the tiles answer "which site". Both come from the same filtered rows, so
    they cannot disagree.
    """
    if not isinstance(rag, dict) or not rag.get("ok"):
        return _nodata(_err_of(rag, "fleet state unavailable"),
                       "Publish from the machine that holds the sites: pl fleet publish")

    sites = [s for s in (rag.get("sites") or []) if isinstance(s, dict)]
    if not sites:
        return _nodata("no sites in this view",
                       "Either nothing is published for this project, or its site "
                       "list is empty. Check: pl fleet publish")

    counts = rag.get("counts") if isinstance(rag.get("counts"), dict) else {}
    ordered = [("RED", _num(counts.get("RED")), "crit"),
               ("AMBER", _num(counts.get("AMBER")), "warn"),
               ("GREEN", _num(counts.get("GREEN")), "ok"),
               ("other", _num(counts.get("OTHER")), "muted")]
    segments = stack(ordered, CHART_W, 0.0, 0.0, FLEET_BAR_H)

    # A legend is always present for >= 2 series, and it is the dependable
    # identity channel here because the hues themselves are not (see module
    # docstring: green vs amber is dE 4.5 under protan).
    legend = [{"label": label, "count": n, "role": role}
              for label, n, role in ordered if n > 0]

    tile_w = (CHART_W - GAP * (TILE_COLS - 1)) / TILE_COLS
    name_w = tile_w - TILE_RULE_W - 14
    tiles = []
    for i, s in enumerate(sites[:max_tiles]):
        grade = str(s.get("grade", "") or "?").upper()
        col, row = i % TILE_COLS, i // TILE_COLS
        x = col * (tile_w + GAP)
        y = row * (TILE_H + GAP)
        name = str(s.get("site", "") or "?")
        tiles.append({
            # `site` — the key scope.scrub() looks for. Do not rename it.
            "site": name,
            "grade": grade,
            "role": _GRADE_ROLE.get(grade, "muted"),
            "phase": str(s.get("phase", "") or ""),
            "reasons": [str(r) for r in (s.get("reasons") or [])][:3],
            "x": round(x, 2), "y": round(y, 2),
            "w": round(tile_w, 2), "h": TILE_H,
            "rule": _bar_path_full(round(x, 2), round(y, 2), TILE_RULE_W, TILE_H, RADIUS, 0.0),
            "label": clamp_text(name, name_w),
            "label_x": round(x + TILE_RULE_W + 7, 2),
            "name_y": round(y + 14, 2),
            "grade_y": round(y + 27, 2),
        })
    rows = (len(tiles) + TILE_COLS - 1) // TILE_COLS
    return {
        "ok": True,
        "state": "ok",
        "segments": segments,
        "legend": legend,
        "bar_h": FLEET_BAR_H,
        "tiles": tiles,
        "tiles_h": max(0, rows * (TILE_H + GAP) - GAP),
        "total": len(sites),
        "shown": len(tiles),
        "hidden": max(0, len(sites) - len(tiles)),
        "worst": ("RED" if _num(counts.get("RED")) else
                  "AMBER" if _num(counts.get("AMBER")) else
                  "GREEN" if _num(counts.get("GREEN")) else ""),
        # The table-view twin. Same rows, same `site` key, no geometry.
        "table": [{"site": t["site"], "grade": t["grade"], "phase": t["phase"],
                   "reasons": t["reasons"]} for t in tiles],
    }


# ---------------------------------------------------------------------------
# V2 — open advisories by severity (horizontal bars, worst first)
# ---------------------------------------------------------------------------
SEV_LABEL_W = 70
SEV_TIP_W = 34


def severity_view(sec: dict) -> dict:
    """`_gather_security(sc)`'s result -> advisories by severity.

    The zero here is the dangerous one. `totals.advisories == 0` means "clean"
    ONLY when every site was actually audited; with any site in
    stale/unreadable/missing state a zero is an ABSENCE of knowledge, and the
    published feed says so (`totals.sites_unknown`). Those two are rendered as
    different states, never as the same empty chart.
    """
    if not isinstance(sec, dict) or not sec.get("ok"):
        return _nodata(_err_of(sec, "no security data in this snapshot"),
                       "The console cannot run composer audit — it holds no sites. "
                       "Publish with: pl fleet publish")

    totals = sec.get("totals") if isinstance(sec.get("totals"), dict) else {}
    by_sev = totals.get("by_severity") if isinstance(totals.get("by_severity"), dict) else {}
    unknown_sites = _num(totals.get("sites_unknown"))
    platform_alerts = _num(totals.get("platform_alerts"))
    n_sites = _num(totals.get("sites"))
    total_adv = _num(totals.get("advisories"))

    # Worst first, then any severity string the feed invented, then "unknown".
    known = [s for s in SEVERITY_LADDER if _num(by_sev.get(s))]
    extra = sorted(k for k in by_sev if k not in SEVERITY_LADDER and _num(by_sev.get(k)))
    ladder = known + extra

    if not ladder:
        if unknown_sites or platform_alerts:
            bits = []
            if unknown_sites:
                bits.append(f"{unknown_sites} of {n_sites} site(s) could not be audited")
            if platform_alerts:
                bits.append(f"{platform_alerts} site(s) behind on platform security releases")
            return _nodata(
                "; ".join(bits),
                "No advisory list means UNKNOWN, not clean — a site whose audit "
                "record is stale or missing may well be affected. Refresh with: pl audit")
        return _nodata(f"no open advisories across {n_sites} site(s)",
                       "Every site in this view was audited and came back clean.",
                       kind="clean")

    peak = max(_num(by_sev.get(s)) for s in ladder)
    plot_x = SEV_LABEL_W + 4
    plot_w = CHART_W - plot_x - SEV_TIP_W
    bars = []
    for i, sev in enumerate(ladder):
        n = _num(by_sev.get(sev))
        w = plot_w * n / peak if peak else 0.0
        y = i * ROW_H
        bars.append({
            "severity": sev,
            "count": n,
            "role": _SEV_ROLE.get(sev, "muted"),
            "x": plot_x, "y": round(y, 2),
            "w": round(w, 2), "h": BAR_H,
            "path": _bar_path_full(plot_x, round(y, 2), round(w, 2), BAR_H, 0.0, RADIUS),
            "label": sev,
            "label_y": round(y + BAR_H / 2.0 + 4, 2),
            # The value rides the TIP, outside the bar — always legible, never
            # clipped, whatever the bar's length.
            "tip_x": round(plot_x + w + 6, 2),
        })
    return {
        "ok": True,
        "state": "ok",
        "bars": bars,
        "height": max(0, len(bars) * ROW_H - (ROW_H - BAR_H)),
        "baseline_x": plot_x,
        "total": total_adv,
        "sites": n_sites,
        "sites_affected": _num(totals.get("sites_affected")),
        "sites_unknown": unknown_sites,
        "platform_alerts": platform_alerts,
        "worst": str(totals.get("worst", "") or ""),
        "table": [{"severity": b["severity"], "count": b["count"]} for b in bars],
    }


# ---------------------------------------------------------------------------
# V3 — open todo load by site (stacked, high/medium/low)
# ---------------------------------------------------------------------------
TODO_LABEL_W = 78
TODO_TIP_W = 30
MAX_TODO_ROWS = 12


def todo_view(todo: dict, max_rows: int = MAX_TODO_ROWS) -> dict:
    """`_gather_todo(sc)`'s result -> per-site todo load, worst first.

    Priority is an ORDERED scale, so the stack is always in the same
    high->medium->low order for every site: a reader compares the red heads of
    the bars down the column without re-reading the legend each row.
    """
    if not isinstance(todo, dict) or not todo.get("ok"):
        return _nodata(_err_of(todo, "todo sweep unavailable"),
                       "The sweep runs where the sites live: pl todo check")

    items = [i for i in (todo.get("items") or []) if isinstance(i, dict)]
    if not items:
        return _nodata("no open todo items in this view",
                       "The sweep ran and found nothing outstanding.", kind="clean")

    agg: dict[str, dict] = {}
    for it in items:
        site = str(it.get("site", "") or "")
        key = site or "—"          # unattributed items are shown, never dropped
        row = agg.setdefault(key, {"site": site, "display": key,
                                   "high": 0, "medium": 0, "low": 0, "other": 0, "total": 0})
        prio = str(it.get("priority", "") or "").strip().lower()
        row["high" if prio == "high" else
            "medium" if prio in ("medium", "med") else
            "low" if prio == "low" else "other"] += 1
        row["total"] += 1

    rows_all = sorted(agg.values(), key=lambda r: (-r["total"], r["display"]))
    rows = rows_all[:max_rows]
    peak = max((r["total"] for r in rows), default=0)
    plot_x = TODO_LABEL_W + 4
    plot_w = CHART_W - plot_x - TODO_TIP_W

    out_rows = []
    for i, r in enumerate(rows):
        y = i * ROW_H
        width = plot_w * r["total"] / peak if peak else 0.0
        segs = stack(
            [("high", r["high"], "crit"), ("medium", r["medium"], "warn"),
             ("low", r["low"], "muted"), ("other", r["other"], "muted")],
            width, plot_x, y, BAR_H,
        )
        out_rows.append({
            # `site` is the scrubber's key. It is "" for the unattributed
            # bucket, and scope.allows_site("") is False — so for a SCOPED
            # reader that bucket is dropped rather than shown, which is the
            # correct fail-closed answer for a row we cannot attribute.
            "site": r["site"],
            "display": r["display"],
            "label": clamp_text(r["display"], TODO_LABEL_W),
            "high": r["high"], "medium": r["medium"], "low": r["low"],
            "other": r["other"], "total": r["total"],
            "y": round(y, 2),
            "label_y": round(y + BAR_H / 2.0 + 4, 2),
            "segments": segs,
            "tip_x": round(plot_x + width + 6, 2),
        })

    legend = [{"label": lab, "role": role,
               "count": sum(r[key] for r in rows)}
              for lab, key, role in (("high", "high", "crit"), ("medium", "medium", "warn"),
                                     ("low", "low", "muted"), ("other", "other", "muted"))
              if sum(r[key] for r in rows)]

    return {
        "ok": True,
        "state": "ok",
        "rows": out_rows,
        "legend": legend,
        "height": max(0, len(out_rows) * ROW_H - (ROW_H - BAR_H)),
        "baseline_x": plot_x,
        "total": sum(r["total"] for r in rows_all),
        "sites": len(rows_all),
        "shown": len(out_rows),
        "hidden": max(0, len(rows_all) - len(out_rows)),
        "table": [{"site": r["site"], "display": r["display"], "high": r["high"],
                   "medium": r["medium"], "low": r["low"], "other": r["other"],
                   "total": r["total"]} for r in out_rows],
    }


# ---------------------------------------------------------------------------
# V4 — CI: head-pipeline state of the open MRs, one strip per project
# ---------------------------------------------------------------------------
CELL = 16
CELL_GAP = 4
CELLS_PER_ROW = 17


def ci_view(blocks, api_ok: bool) -> dict:
    """`_gather_ci(sc)` -> one status strip per CI project.

    Each cell is ONE open merge request's head pipeline. The cell's <title> is
    deliberately only `!iid — status`: the MR *title* is free text from GitLab
    and this chart is about state, not prose. (The CI pane still shows titles;
    this adds no new free-text surface to a scoped reader.)

    Note the rows here key on `project`, NOT `site` — a CI project is not a
    site, and inventing a `site` key would make scrub() drop the row. Scoping
    happens upstream via `Scope.ci_projects`.
    """
    if not api_ok:
        return _nodata("no GitLab token provisioned on this host",
                       "Pipeline states are unavailable; the CI tab still deep-links "
                       "into GitLab. See the README's token section.")

    blocks = [b for b in (blocks or []) if isinstance(b, dict)]
    if not blocks:
        return _nodata("no CI projects in this view",
                       "This project has no gitlab.ci_projects configured.")

    strips = []
    grand: dict[str, int] = {}
    for b in blocks:
        cells = []
        tally: dict[str, int] = {}
        mrs = [m for m in (b.get("mrs") or []) if isinstance(m, dict)]
        for i, row in enumerate(mrs):
            pipe = row.get("pipeline") if isinstance(row.get("pipeline"), dict) else None
            status = str((pipe or {}).get("status", "") or "").strip().lower() or "none"
            mr = row.get("mr") if isinstance(row.get("mr"), dict) else {}
            col, ln = i % CELLS_PER_ROW, i // CELLS_PER_ROW
            cells.append({
                "status": status,
                "role": _CI_ROLE.get(status, "muted"),
                "iid": _num(mr.get("iid")),
                "x": col * (CELL + CELL_GAP),
                "y": ln * (CELL + CELL_GAP),
                "size": CELL,
            })
            tally[status] = tally.get(status, 0) + 1
            grand[status] = grand.get(status, 0) + 1
        lines = (len(cells) + CELLS_PER_ROW - 1) // CELLS_PER_ROW
        strips.append({
            "project": str(b.get("project", "") or "?"),
            "url": str(b.get("url", "") or ""),
            "cells": cells,
            "count": len(cells),
            "height": max(CELL, lines * (CELL + CELL_GAP) - CELL_GAP),
            "tally": [{"status": s, "count": n, "role": _CI_ROLE.get(s, "muted")}
                      for s, n in sorted(tally.items(), key=lambda kv: (-kv[1], kv[0]))],
        })

    if not any(s["count"] for s in strips):
        return _nodata("no open merge requests in this view",
                       "Nothing is in flight on the CI projects you can see.", kind="clean")

    return {
        "ok": True,
        "state": "ok",
        "strips": strips,
        "cell": CELL,
        "legend": [{"status": s, "count": n, "role": _CI_ROLE.get(s, "muted")}
                   for s, n in sorted(grand.items(), key=lambda kv: (-kv[1], kv[0]))],
        "total": sum(s["count"] for s in strips),
        "failed": grand.get("failed", 0),
        "table": [{"project": s["project"], "count": s["count"], "tally": s["tally"]}
                  for s in strips],
    }


# ---------------------------------------------------------------------------
# the pane context
# ---------------------------------------------------------------------------
def page_context(rag, todo, sec, ci_blocks, ci_api_ok, prov) -> dict:
    """Everything the Visuals pane renders, from already-scoped inputs.

    `prov` is returned at the TOP LEVEL on purpose. `scope.redact()` strips
    `ctx["prov"]["host"]` and `["note"]` by EXACT PATH, so nesting it under
    `vz` would silently exempt this pane from a redaction every other read
    pane obeys — the publisher's hostname is infrastructure a tenant need not
    learn. `test_the_shared_redactor_reaches_the_visuals_publisher_host` fails
    if you move it.
    """
    prov = prov if isinstance(prov, dict) else {}
    return {
        "prov": prov,
        "vz": {
            "fleet": fleet_view(rag),
            "severity": severity_view(sec),
            "todo": todo_view(todo),
            "ci": ci_view(ci_blocks, ci_api_ok),
            # Staleness must SHOUT on every chart, not only in the provenance
            # line: a chart screenshotted or scrolled to on its own must still
            # carry the warning that its numbers are not current.
            "stale": bool(prov.get("stale")),
            "chart_w": CHART_W,
        },
    }
