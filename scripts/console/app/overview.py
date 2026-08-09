"""The estate overview — pure view-builders for the Visuals tab's Overview
subtab (ops#329). Stdlib only; no I/O, no subprocess, no Scope knowledge.

WHAT THIS MODULE IS
-------------------
The same division of labour as visuals.py: main.py's scoped gatherers hand in
ALREADY-SCOPED parsed feeds; this module turns them into small view dicts of
role + worded verdict that the `_ov_slot_*.html` fragments place. Nothing here
chooses what it is given, so it cannot leak.

THE PANE'S JOB (operator request, 2026-08-09)
---------------------------------------------
One glance answers: which checkout is stale, what is actually deployed, what
tonight's reset restores, what the demo pair's feedback legs hold, what is
owed. The drift class that bit twice on 2026-08-09 — merged code that was not
deployed, a console that sat stale — is the primary content, so every repo row
and marker verdict is WORDS, not a colour: the console's measured CVD rule
(see visuals.py) applies here unchanged, and "muted" means UNKNOWN, never
"fine".

HONESTY RULES (the estate doctrine, restated for this pane)
-----------------------------------------------------------
  * An unreadable feed is CANNOT VERIFY — role muted/warn + a reason — never
    an empty table.
  * An ABSENT deploy marker is "not recorded", never "in sync": equality is
    claimed only when both sides were actually read.
  * "We looked and there are none" (replicas absent on a readable disk) and
    "we could not look" are different states with different words.
  * A slot whose data source does not exist yet (tranche 2) says PENDING and
    names what it needs — it never renders a zero.
"""
from __future__ import annotations

# The slot endpoints the overview skeleton AJAXes in, grouped by LATENCY CLASS
# so one slow probe never blocks a fast one:
#   local  — console-host reads: own checkout, deploy marker, services, ages
#   estate — the published `estate` feed (workstation repos/deploys/backups)
#   pair   — the demo pair: seal (ssh, TTL-cached), codes, reset trail, spool
#   ops    — decisions + open MRs + CI + RAG headline chips
# A fixed, reviewable set: the slot route 404s anything else.
SLOTS = ("local", "estate", "pair", "ops")

# Verified guild wiring (nwd/stg profile, the only checkout carrying ops#94):
# GapDetector::GAP_SLOTS + EditorialAtomMinter. Rendered as STATIC edges with
# PENDING badges until the tranche-2 drush surface exists — architecture is a
# fact we may draw; counts are measurements we may not invent.
GUILD_EDGES = (
    ("core / contrast atoms", "Theology"),
    ("quiz atoms", "Pedagogy"),
    ("media atoms", "Media"),
    ("audience variants", "Writers"),
    ("stories", "Writers"),
)


def _reason_of(feed, default: str) -> str:
    if isinstance(feed, dict):
        return str(feed.get("reason") or feed.get("error") or default)
    return default


def _nodata(reason: str, hint: str = "", kind: str = "missing") -> dict:
    """Same two-zeros contract as visuals._nodata: 'missing' shouts, 'clean'
    reassures, and there is no third option."""
    return {"ok": False, "state": kind, "reason": reason, "hint": hint}


def fmt_age(secs) -> str:
    if not isinstance(secs, (int, float)) or isinstance(secs, bool) or secs < 0:
        return "unknown age"
    secs = int(secs)
    if secs < 3600:
        return f"{secs // 60}m"
    if secs < 86400:
        return f"{secs // 3600}h {(secs % 3600) // 60:02d}m"
    return f"{secs // 86400}d {(secs % 86400) // 3600}h"


def _short(sha) -> str:
    s = str(sha or "")
    return s[:7] if len(s) >= 7 else s


# ---------------------------------------------------------------------------
# repos / drift
# ---------------------------------------------------------------------------
def _repo_verdict(r: dict) -> tuple[str, str]:
    """One parsed estate repo row -> (role, worded verdict)."""
    if not r.get("present"):
        return "muted", "checkout not present on the publisher"
    ahead, behind = r.get("ahead"), r.get("behind")
    if not r.get("fetched"):
        return "muted", "fetch failed — counts are vs the LAST successful fetch, currency unknown"
    if not isinstance(behind, int) or not isinstance(ahead, int):
        return "muted", "no origin/main to compare against"
    bits = []
    role = "ok"
    if behind:
        role = "crit" if behind >= 20 else "warn"
        bits.append(f"{behind} behind origin/main")
    if ahead:
        role = role if role != "ok" else "warn"
        bits.append(f"{ahead} ahead (unmerged work)")
    if r.get("dirty"):
        role = role if role != "ok" else "warn"
        bits.append("uncommitted changes")
    if not bits:
        return "ok", "at origin/main"
    return role, ", ".join(bits)


def estate_view(est: dict) -> dict:
    """parsers.parse_estate result -> the estate slot's view."""
    if not isinstance(est, dict) or not est.get("ok"):
        return _nodata(_reason_of(est, "no estate feed in this snapshot"),
                       "The workstation publishes it: pl fleet publish "
                       "(the estate feed ships with the fleet snapshot)")
    repos = []
    for r in est.get("repos") or []:
        if not isinstance(r, dict):
            continue
        role, verdict = _repo_verdict(r)
        repos.append({
            "name": str(r.get("name", "?"))[:60],
            "branch": str(r.get("branch", ""))[:40],
            "head": _short(r.get("head")),
            "head_time": str(r.get("head_time", ""))[:25],
            "role": role, "verdict": verdict,
        })

    deploys = est.get("deploys") if isinstance(est.get("deploys"), dict) else {}
    nwd = deploys.get("nwd") if isinstance(deploys.get("nwd"), dict) else None
    nwd_row = None
    if nwd:
        nwd_row = {
            "last": str(nwd.get("last", ""))[:25],
            "nwp_sha": _short(nwd.get("nwp_sha")),
            "code_only": bool(nwd.get("code_only")),
            # The manifest records the TOOL's sha, not the profile's — the
            # honest ladder, not a claim (lib/feedback-loop.sh:355).
            "note": "manifest records the nwp tool sha, not the profile sha — "
                    "'what commit is live' needs profile_sha (tranche 2)",
        }
    plugins = []
    for p in deploys.get("ssd_plugins") or []:
        if isinstance(p, dict):
            plugins.append({
                "plugin": str(p.get("plugin", "?"))[:50],
                "release": str(p.get("release", ""))[:20],
                "repo_commit": _short(p.get("repo_commit")),
                "deployed_at": str(p.get("deployed_at", ""))[:25],
            })

    harvest = {}
    for site, h in (est.get("harvest") or {}).items():
        if not isinstance(h, dict):
            continue
        if not h.get("present"):
            harvest[str(site)] = {"role": "muted",
                                  "verdict": "harvest state absent on the publisher — unknown, not empty"}
            continue
        spool = h.get("spool")
        n = spool if isinstance(spool, int) else -1
        if n < 0:
            harvest[str(site)] = {"role": "muted", "verdict": "spool count unreadable"}
        elif n == 0:
            harvest[str(site)] = {"role": "ok",
                                  "verdict": f"0 unposted (posted awaiting triage: {h.get('posted', '?')})"}
        else:
            harvest[str(site)] = {"role": "warn",
                                  "verdict": f"{n} captured digest(s) NOT yet posted"}

    debt = est.get("secrets_debt") if isinstance(est.get("secrets_debt"), dict) else {}
    if debt.get("ok"):
        n = debt.get("open")
        n = n if isinstance(n, int) else 0
        debt_row = {"role": "warn" if n else "ok",
                    "verdict": (f"{n} exposure(s) owed rotation — blocks prod bring-up"
                                if n else "no rotation debt")}
    else:
        debt_row = {"role": "muted", "verdict": "registry unreadable — debt unknown, not zero"}

    backups = {}
    for site, b in (est.get("backups") or {}).items():
        if not isinstance(b, dict):
            continue
        if not b.get("present"):
            backups[str(site)] = {"role": "warn", "verdict": "no local backups found"}
        else:
            age = b.get("age_seconds")
            backups[str(site)] = {
                "role": "warn" if (isinstance(age, int) and age > 7 * 86400) else "ok",
                "verdict": f"newest {fmt_age(age)} old "
                           f"({b.get('count', '?')} file(s))",
                "newest": str(b.get("newest", ""))[:80],
            }

    return {
        "ok": True, "state": "ok",
        "host": str(est.get("host", ""))[:40],
        "generated_at": str(est.get("generated_at", ""))[:25],
        "repos": repos,
        "nwd_deploy": nwd_row,
        "ssd_plugins": plugins,
        "harvest": harvest,
        "secrets_debt": debt_row,
        "backups": backups,
    }


# ---------------------------------------------------------------------------
# the console host's own state
# ---------------------------------------------------------------------------
def checkout_view(co: dict, gitlab_main: dict | None) -> dict:
    """This host's ~/nwp checkout vs origin/main AND vs GitLab's live main."""
    if not isinstance(co, dict) or not co.get("ok"):
        return dict(_nodata(_reason_of(co, "checkout state unreadable"),
                            "pl fleet checkout --json failed on this host"),
                    role="muted", verdict="CANNOT VERIFY")
    role, bits = "ok", []
    behind = co.get("behind")
    if isinstance(behind, int) and behind > 0:
        role = "warn"
        bits.append(f"{behind} behind origin/main as of last fetch "
                    f"({fmt_age(co.get('fetched_age_seconds'))} ago)")
    gl = gitlab_main if isinstance(gitlab_main, dict) else {}
    if gl.get("ok") and gl.get("sha"):
        if str(co.get("head", "")).startswith(_short(gl["sha"])) or co.get("head") == gl.get("sha"):
            bits.append(f"at GitLab main ({_short(gl['sha'])})")
        else:
            role = "warn" if role == "ok" else role
            bits.append(f"not at GitLab main (main is {_short(gl['sha'])}) — "
                        f"this host runs stale code until git pull")
    else:
        bits.append("GitLab main unknown (API unreadable) — currency cannot be confirmed")
        role = "muted" if role == "ok" else role
    if co.get("dirty"):
        role = "warn" if role == "ok" else role
        bits.append("uncommitted changes")
    if not bits:
        bits.append("at origin/main")
    return {"ok": True, "state": "ok", "role": role,
            "branch": str(co.get("branch", ""))[:40],
            "head": _short(co.get("head") or co.get("head_short")),
            "verdict": "; ".join(bits)}


def marker_view(marker: dict | None, gitlab_main: dict | None) -> dict:
    """The console's own deployed-vs-main verdict, from the `.nwp-deployed.json`
    marker `pl console deploy` writes. ABSENT marker = NOT RECORDED — the
    console that sat stale on 2026-08-09 would have LOOKED healthy under any
    default-green reading, which is why there is none."""
    if not isinstance(marker, dict) or not marker.get("sha"):
        return {"ok": False, "state": "missing", "role": "muted",
                "verdict": "deployment not recorded — no .nwp-deployed.json marker; "
                           "redeploy with the updated pl console deploy to start recording",
                "deployed_at": ""}
    gl = gitlab_main if isinstance(gitlab_main, dict) else {}
    sha = str(marker.get("sha", ""))
    if not gl.get("ok") or not gl.get("sha"):
        return {"ok": True, "state": "ok", "role": "muted",
                "verdict": f"deployed {_short(sha)} — GitLab main unknown (API unreadable), "
                           f"so currency CANNOT be verified",
                "deployed_at": str(marker.get("deployed_at", ""))[:25]}
    if sha == gl["sha"] or _short(sha) == _short(gl["sha"]):
        return {"ok": True, "state": "ok", "role": "ok",
                "verdict": f"deployed at main HEAD ({_short(sha)})",
                "deployed_at": str(marker.get("deployed_at", ""))[:25]}
    return {"ok": True, "state": "ok", "role": "warn",
            "verdict": f"deployed {_short(sha)} differs from main ({_short(gl['sha'])}) — "
                       f"merged code is NOT deployed (behind main until pl console deploy)",
            "deployed_at": str(marker.get("deployed_at", ""))[:25]}


def services_view(services: dict) -> list[dict]:
    """{name: 'up'|'down'|'unknown'} -> worded rows. 'unknown' is muted — a
    probe that could not run never renders as either up or down."""
    rows = []
    for name, st in (services or {}).items():
        st = str(st)
        rows.append({
            "name": str(name)[:40],
            "role": {"up": "ok", "down": "crit"}.get(st, "muted"),
            "verdict": {"up": "up", "down": "DOWN"}.get(st, "unknown (probe failed)"),
        })
    return rows


# ---------------------------------------------------------------------------
# backup replicas on this host (~/nwp-backup-set/<site>/)
# ---------------------------------------------------------------------------
def replicas_view(sites: dict) -> dict:
    """{site: {present, readable, newest?, age_seconds?, count?}} — gathered by
    main.py from the console host's own disk. The two zeros stay apart:
    readable-and-absent is a real (bad) answer; unreadable is no answer."""
    rows = []
    for site, r in (sites or {}).items():
        r = r if isinstance(r, dict) else {}
        if not r.get("readable", True):
            rows.append({"site": str(site), "role": "muted",
                         "verdict": "CANNOT VERIFY — replica dir unreadable"})
        elif not r.get("present"):
            rows.append({"site": str(site), "role": "warn",
                         "verdict": "NONE on this host — pl backup replicate has never "
                                    "landed here (no cron schedules it; ops#329 D3)"})
        else:
            rows.append({"site": str(site),
                         "role": "warn" if (isinstance(r.get("age_seconds"), int)
                                            and r["age_seconds"] > 7 * 86400) else "ok",
                         "verdict": f"{r.get('count', '?')} file(s), newest "
                                    f"{fmt_age(r.get('age_seconds'))} old"})
    return {"ok": True, "state": "ok", "sites": rows}


# ---------------------------------------------------------------------------
# the demo pair — tranche-2 stubs
# ---------------------------------------------------------------------------
def pair_pending_slots() -> list[dict]:
    """The interconnection readings whose data source does not exist yet.
    Each names its tranche-2 need EXACTLY, so the pane is a work order rather
    than a blank. Rendered muted with a PENDING badge — never as zeros."""
    return [
        {"label": "SSO / OIDC pair wiring (nwd↔ssd)", "state": "pending",
         "needs": "JSON from ssd-oidc-wire.sh --check / pl pair-smoke (tranche 2)"},
        {"label": "completion pull (ssd→nwd) armed + last run", "state": "pending",
         "needs": "nwc-moodle:completion-status --format=json + state "
                  "nwc_moodle_data.completion_pull.last (tranche 2)"},
        {"label": "error-report queue (source=error)", "state": "pending",
         "needs": "drush nwc:signal-counts --format=json over nwc_feedback (tranche 2)"},
        {"label": "help feedback (source=help + helpful ratio)", "state": "pending",
         "needs": "same nwc:signal-counts + state nwc_help.helpful_ratio (tranche 2)"},
        {"label": "fast-path queue depth", "state": "pending",
         "needs": "queue nwc_feedback_fast_path count via the same drush surface (tranche 2)"},
        {"label": "hourly feedback-status return leg (met, minute 7)", "state": "pending",
         "needs": "met log ~/logs/demo-feedback-status-nwd.log is unreachable from the "
                  "console — ops#329 D4 decides the publisher"},
        {"label": "guild backlogs (gap tasks / WIP claims / members)", "state": "pending",
         "needs": "drush nwc:editorial:gap-status --format=json (tranche 2)"},
        {"label": "user counts (nwd fenced vs other; ssd mdl_user)", "state": "pending",
         "needs": "drush nwc:tester-list + measure feed (tranche 2)"},
    ]


# ---------------------------------------------------------------------------
# skeleton
# ---------------------------------------------------------------------------
def skeleton_context() -> dict:
    """Everything the instant skeleton needs — static structure only, no data.
    Values arrive by slot AJAX; the skeleton itself must render in one pass
    with zero gathers."""
    return {"slots": list(SLOTS), "guild_edges": [
        {"what": w, "guild": g} for w, g in GUILD_EDGES]}
