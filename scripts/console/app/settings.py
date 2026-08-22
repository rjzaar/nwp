"""Settings — the estate's DECLARED FACTS, turned into views. Stdlib only.

WHY THIS MODULE EXISTS, AND WHY IT CANNOT ACT

    The Settings pane shows five facts that are declared somewhere else:
    merge authority (ops#385), review mode (ADR-0037), each site's canonical
    phase (ops#33), the merge queue, and how fresh this console's own feeds
    are. Not one of them is settable here. `app/help.py` carries the same
    boundary for the same reason — it is CONTENT, and content must never be
    able to run anything — so this module imports no runner, no subprocess,
    no actions and no main. It is handed text that somebody else read, and it
    turns that text into a view. tests/test_settings_pane.py asserts the
    import ban structurally, because "nobody will call it that way" is not a
    control.

    There is deliberately no `set` anything here. CLAUDE.md's standing order
    on `approvers:` is explicit — "a policy expressed in several places is a
    policy that drifts" — and ops#385 repeats it for merge authority: "no
    console toggle, no env var, no CLI flag". A console that could flip these
    would be the second declaration site both rulings exist to prevent.

THE THREE STATES, WHICH ARE NEVER TWO

    DECLARED      the source was read and it says something.
    NOT_DECLARED  the source was read and it declares nothing. "No merge
                  authority is granted" is a real, normal, load-bearing
                  answer — it means a human merges — and it must never look
                  like a failure.
    UNAVAILABLE   we could not look: the verb does not exist here, the file
                  was unreadable, the output did not parse. It must never
                  look like NOT_DECLARED, and it must never be rendered as an
                  empty list. Every UNAVAILABLE carries a `reason`.

    Collapsing the last two is the estate's most expensive recurring bug (an
    unreadable tracker rendering as a clean board; `|| echo "[]"` turning a
    removed subcommand into "no security updates"). Three states, always.

WHAT IT READS, AND WHAT HAPPENS BEFORE IT EXISTS

    `pl mr authority --json` and `pl mr ready --json` are being built by other
    streams (ops#385, the merge-queue work). Until they land, both feeds come
    back non-zero and this module reports UNAVAILABLE with the verb's own
    error text — which is the honest state, and is visibly different from
    "nothing is granted" / "nothing is queued". The argv is declared once,
    here, so the day the verbs land there is exactly one place to check.
"""
from __future__ import annotations

import re

from . import parsers

# ---------------------------------------------------------------------------
# the three states
# ---------------------------------------------------------------------------
DECLARED = "declared"
NOT_DECLARED = "not-declared"
UNAVAILABLE = "unavailable"

# Where each fact is DECLARED. Rendered on the pane beside the value, because
# a fact shown without its declaration site invites the reader to look for a
# switch here — and there is not one.
REGISTRY = "private/secrets-registry.yml"
AUTHORITY_WHERE = f"{REGISTRY} → merge_authority:  (ops#385)"
REVIEW_MODE_WHERE = f"{REGISTRY} → approvers:  (ADR-0037)"
PHASE_WHERE = "nwp.yml → canonical:  (pl canonical set <site> <phase>, ops#33)"
QUEUE_WHERE = "the forge — open merge requests"

# The ONE place each read's argv is written down.
AUTHORITY_ARGV = ["mr", "authority", "--json"]
REVIEW_MODE_ARGV = ["mr", "review-mode"]
QUEUE_ARGV = ["mr", "ready", "--json"]

REVIEW_MODES = ("solo", "team")
# CLAUDE.md: "no readable registry, no projection, or an unrecognised value
# reads as `team`, the stricter mode". Named here so the pane can SAY that the
# value it is showing is the fail-closed default rather than a decision.
FAIL_CLOSED_MODE = "team"

_MODE_RE = re.compile(r"review mode:\s*([A-Za-z][A-Za-z-]*)", re.I)
_FROM_RE = re.compile(r"(?m)^\s*from:\s*(.+?)\s*$")
_PROJ_RE = re.compile(r"(?m)^\s*projection:\s*(.+?)\s*$")


def cmd(argv) -> str:
    return "pl " + " ".join(argv)


def _first_line(res: dict) -> str:
    """The verb's own words for why it could not answer. stderr first, then
    stdout — `die` writes to stderr, but a python traceback may not."""
    for key in ("err", "out"):
        text = parsers.strip_ansi(str(res.get(key) or "")).strip()
        if text:
            return text.splitlines()[0][:240]
    return ""


def _why(res: dict, argv) -> str:
    said = _first_line(res)
    rc = res.get("rc")
    if said:
        return f"{said}  (rc={rc}, `{cmd(argv)}`)"
    return f"`{cmd(argv)}` exited rc={rc} and said nothing"


# ---------------------------------------------------------------------------
# 1. merge authority (ops#385)
# ---------------------------------------------------------------------------
_AUTHORITY_FIELDS = ("granted_to", "granted_by", "granted_on", "ref", "scope")


def parse_authority(res: dict) -> dict:
    """`pl mr authority --json` → a view.

    FAIL-CLOSED, in the same direction ops#385 §4 specifies for the verb
    itself: unreadable registry, unparseable block, missing scope → a human
    merges. `fails_closed` is therefore True everywhere except a complete,
    declared grant — the pane renders it as the headline, so the reader is
    never left inferring the effect from the absence of a field.
    """
    view = {
        "state": UNAVAILABLE, "reason": "", "where": AUTHORITY_WHERE,
        "cmd": cmd(AUTHORITY_ARGV), "warnings": [], "fails_closed": True,
        "bounds": [],
    }
    view.update({f: "" for f in _AUTHORITY_FIELDS})

    if res.get("rc") != 0:
        view["reason"] = _why(res, AUTHORITY_ARGV)
        return view

    data = parsers.extract_json(res.get("out") or "")
    if not isinstance(data, dict):
        view["reason"] = (f"unparseable output from `{cmd(AUTHORITY_ARGV)}` — "
                          "no JSON object found")
        return view

    block = data.get("merge_authority")
    if not isinstance(block, dict):
        block = data

    granted_to = str(block.get("granted_to") or "").strip()
    # An explicit `declared: false` and an empty block mean the same thing and
    # are BOTH a reading, not a failure: nothing is granted, so a human merges.
    if data.get("declared") is False or not granted_to:
        view["state"] = NOT_DECLARED
        return view

    view["state"] = DECLARED
    for f in _AUTHORITY_FIELDS:
        view[f] = str(block.get(f) or "").strip()
    bounds = block.get("bounds")
    if isinstance(bounds, list):
        view["bounds"] = [str(b)[:200] for b in bounds if isinstance(b, (str, int, float))]

    missing = [f for f in _AUTHORITY_FIELDS if not view[f]]
    if missing:
        # Not a narrower grant — an unusable one. Say which field is missing,
        # so the fix is obvious and nobody "reads through" the gap.
        view["warnings"].append(
            "INCOMPLETE: no " + ", ".join(missing) + " — the accessor fails closed on "
            "an unparseable block, so this reads as NO authority")
    view["fails_closed"] = bool(missing)
    return view


# ---------------------------------------------------------------------------
# 2. review mode (ADR-0037) — DERIVED from approvers:, reported by the verb
# ---------------------------------------------------------------------------
def parse_review_mode(res: dict) -> dict:
    """`pl mr review-mode` → a view.

    rc is NOT the verdict here: the verb returns 1 when the registry and the
    tracked projection DISAGREE, and that answer is one of the most useful
    things this pane can show (CI reads the projection, so drift means CI is
    enforcing the wrong policy right now). The parse is therefore driven by
    the text, and rc only colours it.
    """
    view = {"state": UNAVAILABLE, "reason": "", "where": REVIEW_MODE_WHERE,
            "cmd": cmd(REVIEW_MODE_ARGV), "mode": "", "source": "",
            "projection": "", "drift": False}

    text = parsers.strip_ansi(res.get("out") or "") + "\n" + parsers.strip_ansi(res.get("err") or "")
    m = _MODE_RE.search(text)
    if not m:
        view["reason"] = _why(res, REVIEW_MODE_ARGV)
        return view

    mode = m.group(1).lower()
    if mode not in REVIEW_MODES:
        # An unrecognised value is a reading we cannot act on, and CLAUDE.md
        # says it reads as `team`. Report BOTH: what was there, and what it
        # therefore means.
        view["reason"] = (f"unrecognised review mode {mode!r} from "
                          f"`{cmd(REVIEW_MODE_ARGV)}` — reads as the fail-closed "
                          f"{FAIL_CLOSED_MODE}")
        view["mode"] = FAIL_CLOSED_MODE
        return view

    view["mode"] = mode
    f = _FROM_RE.search(text)
    view["source"] = f.group(1).strip() if f else ""
    p = _PROJ_RE.search(text)
    view["projection"] = p.group(1).strip() if p else ""
    view["drift"] = "DRIFT:" in text
    # "NOT DECLARED" is the verb's own word for no registry AND no projection.
    # The mode it prints in that case is the fail-closed default, so it must
    # not be rendered as somebody's decision.
    view["state"] = NOT_DECLARED if "NOT DECLARED" in text else DECLARED
    return view


# ---------------------------------------------------------------------------
# 3. canonical phase per site (ops#33)
# ---------------------------------------------------------------------------
# `pl rag --json` carries the phase per site (lib/rag-render.py: explicit value,
# or the literal "(dev)" when the site never declared one). The console host
# holds no sites, so this arrives in the PUBLISHED fleet snapshot like every
# other per-site fact — which is also why the view carries the snapshot's
# provenance: a phase table from a three-day-old snapshot is a three-day-old
# phase table.
DEFAULT_PHASE_MARKER = "(dev)"


def phases_view(rag: dict, prov: dict | None = None) -> dict:
    view = {"state": UNAVAILABLE, "reason": "", "where": PHASE_WHERE,
            "rows": [], "prov": dict(prov or {}),
            "counts": {"declared": 0, "default": 0, "unknown": 0, "prod": 0}}

    if not isinstance(rag, dict) or not rag.get("ok"):
        view["reason"] = (str((rag or {}).get("error") or "").strip()
                          or "the fleet feed did not answer")
        return view

    sites = rag.get("sites") or []
    if not sites:
        # Zero sites is not "no site is prod". This host has no sites of its
        # own, so an empty list means the snapshot did not carry them.
        view["reason"] = ("the fleet feed answered with no sites, so there is no "
                          "phase table to show")
        return view

    rows = []
    for s in sites:
        if not isinstance(s, dict):
            continue
        raw = str(s.get("phase") or "").strip()
        known = bool(raw)
        invalid = raw.startswith("invalid:")
        declared = known and not invalid and raw != DEFAULT_PHASE_MARKER
        rows.append({
            "site": str(s.get("site") or "?"),
            "phase": raw if known else "",
            # What to SHOW. "not carried by this feed" is a different sentence
            # from "(dev)", and the reader needs to be able to tell them apart:
            # one is a site nobody classified, the other is a snapshot that
            # predates the field.
            "display": raw if known else "not carried by this feed",
            "known": known, "declared": declared, "invalid": invalid,
            "prod": declared and raw == "prod",
            "grade": str(s.get("grade") or ""),
        })
    rows.sort(key=lambda r: r["site"])

    counts = view["counts"]
    for r in rows:
        if not r["known"]:
            counts["unknown"] += 1
        elif r["declared"]:
            counts["declared"] += 1
        else:
            counts["default"] += 1
        if r["prod"]:
            counts["prod"] += 1
    view["rows"] = rows
    view["state"] = DECLARED
    return view


# ---------------------------------------------------------------------------
# 4. the merge queue
# ---------------------------------------------------------------------------
_QUEUE_KEYS = ("mrs", "items", "merge_requests", "queue")


def queue_view(res: dict) -> dict:
    """`pl mr ready --json` → a view.

    An ANSWERED empty queue is a measurement and says "none open". A queue we
    could not read is UNAVAILABLE and says why. Readiness that the verb did
    not report stays None — coercing a missing field to False would invent a
    verdict about whether an MR may merge, which is precisely the field a
    reader would act on.
    """
    view = {"state": UNAVAILABLE, "reason": "", "where": QUEUE_WHERE,
            "cmd": cmd(QUEUE_ARGV), "rows": [], "ready_count": 0}

    if res.get("rc") != 0:
        view["reason"] = _why(res, QUEUE_ARGV)
        return view

    data = parsers.extract_json(res.get("out") or "")
    if data is None:
        view["reason"] = f"unparseable output from `{cmd(QUEUE_ARGV)}` — no JSON found"
        return view

    items = None
    if isinstance(data, list):
        items = data
    elif isinstance(data, dict):
        if data.get("ok") is False:
            view["reason"] = (str(data.get("error") or "").strip()
                              or f"`{cmd(QUEUE_ARGV)}` reported ok=false with no reason")
            return view
        for k in _QUEUE_KEYS:
            if isinstance(data.get(k), list):
                items = data[k]
                break
    if items is None:
        view["reason"] = (f"unrecognised shape from `{cmd(QUEUE_ARGV)}` — expected a list "
                          f"under one of: {', '.join(_QUEUE_KEYS)}")
        return view

    rows = []
    for it in items:
        if not isinstance(it, dict):
            continue
        ready = it.get("ready")
        blockers = it.get("blockers") or it.get("reasons") or []
        rows.append({
            "project": str(it.get("project") or ""),
            "iid": it.get("iid"),
            "title": str(it.get("title") or "")[:200],
            "url": str(it.get("url") or ""),
            "draft": bool(it.get("draft")),
            "ready": ready if isinstance(ready, bool) else None,
            "blockers": [str(b)[:200] for b in blockers if isinstance(b, (str, int, float))],
        })
    view["rows"] = rows
    view["ready_count"] = sum(1 for r in rows if r["ready"] is True)
    view["state"] = DECLARED
    return view


# ---------------------------------------------------------------------------
# 5. freshness of what this console itself serves
# ---------------------------------------------------------------------------
def _fresh_row(name: str, prov: dict | None, what: str) -> dict:
    p = dict(prov or {})
    present = bool(p.get("snapshot_present"))
    return {
        "name": name,
        "present": present,
        # An absent artefact has NO age. Rendering "never" as a duration is how
        # a thing that was never published starts looking merely old.
        "age_human": str(p.get("age_human") or "") if present else "",
        "stale": bool(p.get("stale")) if present else False,
        "source": str(p.get("source") or ""),
        "host": str(p.get("host") or ""),
        "generated_at": str(p.get("generated_at") or "") if present else "",
        "max_age_human": str(p.get("max_age_human") or ""),
        "note": str(p.get("note") or ""),
        "what": what,
    }


def freshness_view(fleet_prov: dict | None = None, library_prov: dict | None = None) -> list:
    """The console host holds no sites and no docs: everything it serves was
    PUBLISHED to it. So "how old is what I am looking at" is a setting-shaped
    fact in its own right, and it is the one the other four depend on."""
    return [
        _fresh_row("fleet snapshot", fleet_prov,
                   "RAG, todo, backups, security and the phase table above — "
                   "published by pl fleet publish"),
        _fresh_row("library bundle", library_prov,
                   "the documents on /library — published by pl library publish"),
    ]


# ---------------------------------------------------------------------------
# the tab's own alert
# ---------------------------------------------------------------------------
def alert(authority: dict, review: dict, phases: dict) -> bool:
    """What is worth a red dot on the tab bar. Deliberately a SHORT list.

    IN:  review-mode drift — the registry and the projection disagree, so CI is
         enforcing a policy the registry does not agree with, right now.
         An unreadable review policy — the console cannot tell the operator
         what the rules are, and that is the one thing this tab is for.
         A granted-but-incomplete authority block — a real defect in a real
         declaration, and it silently means "no authority" (fail-closed).

    OUT: "no authority is granted" — the normal, safe state. A dot on it would
         be a dot on every ordinary day.
    OUT: a feed we cannot read because its verb does not exist here yet
         (`pl mr authority`, `pl mr ready`). That condition will hold for weeks
         at a time, and a dot that is permanently lit is a dot people learn to
         ignore — the same reason `pl canonical show` stopped going red in
         every worktree for a condition its own doctrine calls normal. The
         pane says CANNOT VERIFY about it, loudly, where it can be read.
    OUT: an absent fleet snapshot — the Fleet tab already raises that, and one
         fault should light one lamp.
    """
    return bool(
        review.get("drift")
        or review.get("state") == UNAVAILABLE
        or (authority.get("state") == DECLARED and authority.get("warnings"))
    )
