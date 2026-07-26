"""Published fleet-state snapshots — the console DISPLAYS fleet state.

The console host has no sites. Shelling out to `pl rag` here returns an empty
fleet, which is why the Fleet tab was blank and the "a site went RED" push
could never fire. The machine that HAS the sites publishes one snapshot
(`pl fleet publish`, scripts/commands/fleet.sh) and this module consumes it.

Everything here is pure and stdlib-only: one file read plus arithmetic on a
clock the caller passes in. The decision of WHICH source to show lives in
`decide()` so it can be unit-tested without a filesystem, a subprocess or a
network.

The rule, and why (this is the honesty contract):

  1. Published snapshot present and younger than max_age  -> show it.
  2. Published snapshot present but STALE                  -> try the local
     `pl` shell-out; use it ONLY if it actually knows something (ok AND
     non-empty). Otherwise keep showing the stale snapshot, marked STALE
     loudly. A local run on a host with no sites is not a fallback, it is an
     empty answer, and replacing loud-stale-truth with a quiet empty table is
     the exact failure this whole change exists to fix.
  3. No snapshot -> local shell-out (the previous behaviour), labelled as such.

In every case the provenance (which host, how old) is rendered in the UI.
Old data is NEVER presented as current.
"""
from __future__ import annotations

import json
import re
import socket
from datetime import datetime, timezone
from pathlib import Path

SCHEMA = "nwp.fleet-state"
SUPPORTED_VERSIONS = (1,)

# A project id reaches this module from a signed cookie / a validated query
# param, but it is about to become part of a FILE NAME, so it is re-validated
# here rather than trusted. Defence in depth costs one regex.
_PID_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,31}$")


# ---------------------------------------------------------------------------
# reading
# ---------------------------------------------------------------------------
def load(path) -> dict | None:
    """Read a published snapshot. Returns None for missing/corrupt/foreign
    files — never raises, and never guesses at an unknown schema version."""
    try:
        raw = Path(path).read_text()
    except (OSError, ValueError):
        return None
    try:
        data = json.loads(raw or "")
    except (json.JSONDecodeError, ValueError):
        return None
    if not isinstance(data, dict):
        return None
    if data.get("schema") != SCHEMA:
        return None
    try:
        if int(data.get("schema_version", 0)) not in SUPPORTED_VERSIONS:
            return None
    except (TypeError, ValueError):
        return None
    return data


def load_for(data_dir, project_id, default_path=None) -> tuple[dict | None, bool]:
    """Prefer a per-project snapshot when one has been published.

    Render-time filtering (the Scope choke point) is the default and needs no
    publisher change. But when a project must be FILE-isolated — a contractor
    who should not have another tenant's bytes on the same disk page — the
    publisher can drop `fleet-state.<pid>.json` and this picks it up with no
    code change at all. Returns (snapshot, scoped_flag); the flag is rendered
    by _provenance.html so the reader knows which of the two they are seeing.
    """
    if project_id:
        pid = str(project_id)
        if _PID_RE.match(pid):
            scoped_path = Path(data_dir) / f"fleet-state.{pid}.json"
            snap = load(scoped_path)
            if snap is not None:
                return snap, True
    if default_path is None:
        default_path = Path(data_dir) / "fleet-state.json"
    return load(default_path), False


def feed(snap: dict | None, name: str) -> dict | None:
    """One feed of a snapshot ({'ok','rc','secs','cmd','data'}), or None."""
    if not isinstance(snap, dict):
        return None
    f = (snap.get("feeds") or {}).get(name)
    return f if isinstance(f, dict) else None


def source_host(snap: dict | None) -> str:
    if not isinstance(snap, dict):
        return ""
    return str((snap.get("generated_by") or {}).get("host", "") or "")


def generated_at(snap: dict | None) -> str:
    if not isinstance(snap, dict):
        return ""
    return str(snap.get("generated_at", "") or "")


def age_seconds(snap: dict | None, now: datetime | None = None) -> float | None:
    """Seconds since generated_at, or None if it can't be read. Clock skew
    (a snapshot from the future) clamps to 0 rather than reading as ancient."""
    stamp = generated_at(snap)
    if not stamp:
        return None
    try:
        when = datetime.strptime(stamp, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except (ValueError, TypeError):
        return None
    now = now or datetime.now(timezone.utc)
    if now.tzinfo is None:
        now = now.replace(tzinfo=timezone.utc)
    return max(0.0, (now - when).total_seconds())


def fmt_age(secs) -> str:
    """Human age, deliberately coarse: nobody needs seconds on a fleet view."""
    if secs is None:
        return "unknown age"
    try:
        secs = int(secs)
    except (TypeError, ValueError):
        return "unknown age"
    if secs < 60:
        return "just now"
    if secs < 3600:
        return f"{secs // 60} min"
    if secs < 86400:
        h, m = secs // 3600, (secs % 3600) // 60
        return f"{h} h" if not m else f"{h} h {m} min"
    d = secs // 86400
    return f"{d} day" if d == 1 else f"{d} days"


def fmt_duration(secs) -> str:
    try:
        secs = int(secs)
    except (TypeError, ValueError):
        return "?"
    if secs % 86400 == 0 and secs >= 86400:
        d = secs // 86400
        return f"{d} day" if d == 1 else f"{d} days"
    if secs % 3600 == 0:
        return f"{secs // 3600} h"
    return f"{secs // 60} min"


# ---------------------------------------------------------------------------
# a published feed, shaped like a run_pl() result
# ---------------------------------------------------------------------------
def as_result(snap: dict, name: str, now: datetime | None = None) -> dict | None:
    """Re-present a published feed as a run_pl()-shaped dict, so the existing
    parsers and templates consume it unchanged. Returns None if the feed is
    absent or was published as failed (then the caller falls back)."""
    f = feed(snap, name)
    if not f or not f.get("ok") or "data" not in f:
        return None
    age = age_seconds(snap, now)
    return {
        "rc": 0,
        "out": json.dumps(f.get("data")),
        "err": "",
        "secs": f.get("secs", 0),
        "cmd": str(f.get("cmd", "")) + f"  [published by {source_host(snap) or '?'}]",
        "cached": True,
        "age": int(age) if age is not None else 0,
        "published": True,
    }


# ---------------------------------------------------------------------------
# the decision
# ---------------------------------------------------------------------------
def _prov(**kw) -> dict:
    base = {
        "source": "local",
        "host": "",
        "local_host": socket.gethostname(),
        "generated_at": "",
        "age_seconds": None,
        "age_human": "",
        "stale": False,
        "snapshot_present": False,
        "snapshot_stale": False,
        "max_age_human": "",
        "note": "",
    }
    base.update(kw)
    return base


def default_usable(parsed: dict, key: str) -> bool:
    """'This source actually knows something': parsed ok AND at least one row.
    An ok-but-empty answer from a host with no sites is not an answer."""
    if not isinstance(parsed, dict) or not parsed.get("ok"):
        return False
    rows = parsed.get(key)
    return bool(isinstance(rows, list) and rows)


def decide(snap, name, local_getter, max_age, rows_key, now=None):
    """Pick the source for one feed.

    local_getter() -> (parsed, res)   — called lazily, at most once.
    Returns (parsed, res, provenance).
    """
    now = now or datetime.now(timezone.utc)
    max_age_human = fmt_duration(max_age)
    pub_res = as_result(snap, name, now) if snap else None
    age = age_seconds(snap, now) if snap else None
    stale = bool(pub_res is not None and age is not None and max_age > 0 and age > max_age)
    host = source_host(snap)

    if pub_res is not None and not stale:
        return (
            None,
            pub_res,
            _prov(source="published", host=host, generated_at=generated_at(snap),
                  age_seconds=age, age_human=fmt_age(age), stale=False,
                  snapshot_present=True, snapshot_stale=False, max_age_human=max_age_human),
        )

    # Either there is no usable published feed, or it is stale: consult the
    # local `pl`. It only wins if it actually knows something.
    parsed, res = local_getter()
    local_ok = default_usable(parsed, rows_key)

    if pub_res is not None and stale and not local_ok:
        return (
            None,
            pub_res,
            _prov(source="published", host=host, generated_at=generated_at(snap),
                  age_seconds=age, age_human=fmt_age(age), stale=True,
                  snapshot_present=True, snapshot_stale=True, max_age_human=max_age_human,
                  note="this host cannot compute fleet state, so the stale snapshot is "
                       "still what you are looking at"),
        )

    note = ""
    if pub_res is not None and stale:
        note = (f"the published snapshot from {host or '?'} is {fmt_age(age)} old "
                f"(older than {max_age_human}) and was not used")
    elif snap is not None:
        note = f"the published snapshot from {host or '?'} has no usable '{name}' feed"
    else:
        note = "no published fleet state on this host"
    return (
        parsed,
        res,
        _prov(source="local", host="", generated_at=generated_at(snap),
              age_seconds=age, age_human=fmt_age(age) if age is not None else "",
              stale=False, snapshot_present=snap is not None, snapshot_stale=stale,
              max_age_human=max_age_human, note=note),
    )


def describe(prov: dict) -> str:
    """One plain-text line of provenance, for Quokka's LIVE STATE block and
    logs. The model must not be able to mistake stale data for current data."""
    if not isinstance(prov, dict):
        return ""
    if prov.get("source") == "published":
        who = prov.get("host") or "an unknown host"
        if prov.get("stale"):
            return (f"WARNING: the fleet/todo state above is STALE — published by {who} "
                    f"{prov.get('age_human', '?')} ago (older than {prov.get('max_age_human', '?')}). "
                    f"It may no longer reflect reality; say so if asked.")
        return f"Fleet/todo state above was published by {who} {prov.get('age_human', '?')} ago."
    where = prov.get("local_host") or "this host"
    note = prov.get("note") or "no published fleet state"
    return (f"NOTE: the fleet/todo state above was computed on {where} ({note}). "
            f"This host does not hold the sites, so it may be incomplete.")


def empty_local_error(prov: dict, what: str = "fleet", project: str = "") -> dict:
    """What to show instead of a silent empty table when the LOCAL shell-out
    on a host with no sites returns 'ok, zero rows'. Saying nothing here is how
    the Fleet tab looked healthy while showing nothing at all."""
    where = prov.get("local_host") or "this host"
    return {
        "ok": False,
        "error": (f"no {what} state on {where} — the sites live elsewhere. "
                  f"Publish from the machine that has them: pl fleet publish"),
        "no_state": True,
    }


def empty_project_error(project: str, what: str = "fleet") -> dict:
    """A project whose sites are ALL absent from the snapshot must say so.

    An empty table for a project reads as 'everything is fine here', which is
    the same lie the empty Fleet tab told before publishing existed — except
    worse, because a member cannot tell the difference between "my sites are
    healthy" and "my sites are not being published at all"."""
    return {
        "ok": False,
        "error": (f"no {what} data for project '{project}' in the published snapshot — "
                  f"none of this project's sites appear in it. Check that the publisher "
                  f"still knows about them: pl fleet publish"),
        "no_state": True,
        "project_empty": True,
    }
