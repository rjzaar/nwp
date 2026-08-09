"""Estate overview tranche 2 (ops#329): the demo-pair interconnection slots
wired to the nwc profile's read-only drush surface over `pl drush nwd
--tier=live`, through the cached-collector pattern.

The load-bearing case here is the one the console will ACTUALLY be in first:
the nwc profile MR is merged but not yet deployed to live nwd, so drush
answers `Command "nwc:signal-counts" is not defined` — that must render as
CANNOT VERIFY with the deploy hint, never as an empty-but-healthy row and
never as a crash.
"""
import ast
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import config, overview, parsers  # noqa: E402

APP = Path(__file__).resolve().parent.parent / "app"
TPL = Path(__file__).resolve().parent.parent / "templates"

# ---------------------------------------------------------------------------
# fixtures: realistic `pl drush nwd --tier=live --execute -- …` output shapes
# ---------------------------------------------------------------------------
PL_CHROME = (
    "INFO: Target: gitlab@203.0.113.9:/var/www/nwd\n"
    "INFO: Remote command: cd /var/www/nwd && sudo -u www-data drush nwc:signal-counts --format=json\n"
    "═══ Running drush on live ═══\n"
)

SIGNALS_JSON = """
{
  "ok": true,
  "generated_at": "2026-08-09T12:00:00+00:00",
  "total": 9,
  "sources": {
    "feedback": {"total": 5, "by_group": {"open": 3, "awaiting_poster": 1, "resolved": 1, "follow_up": 0}},
    "error":    {"total": 3, "by_group": {"open": 2, "awaiting_poster": 0, "resolved": 1, "follow_up": 0}},
    "help":     {"total": 1, "by_group": {"open": 0, "awaiting_poster": 0, "resolved": 1, "follow_up": 0}}
  },
  "fast_path_queue": {"name": "nwc_feedback_fast_path", "depth": 2},
  "help_ratio": {"topics_with_votes": 4, "up": 7, "down": 1, "ratio": 0.875}
}
"""

NOT_DEFINED = (
    PL_CHROME
    + " [error]  Command \"nwc:signal-counts\" is not defined.\n"
    + "ERROR: drush RAN on live and the command failed (exit 1). Not retrying the remaining candidates:"
    + " re-running would repeat any write the command already made.\n"
)

GAPS_JSON = """
{
  "ok": true,
  "generated_at": "2026-08-09T12:00:00+00:00",
  "gap_sweep_last": {"timestamp": 1770630000, "age_seconds": 1800, "swept": true},
  "wip_ttl_seconds": 86400,
  "guilds": {
    "pedagogy": {"label": "Pedagogy Guild", "members": 3, "open_gaps": 4, "claimed_gaps": 1, "wip_claims": 2},
    "media":    {"label": "Media Guild",    "members": null, "open_gaps": 0, "claimed_gaps": 0, "wip_claims": 0},
    "writers":  {"label": "Writers Guild",  "members": 2, "open_gaps": 1, "claimed_gaps": 0, "wip_claims": 0},
    "theology": {"label": "Theology Guild", "members": 4, "open_gaps": 0, "claimed_gaps": 0, "wip_claims": 1}
  },
  "gaps": {"open_total": 5, "claimed_total": 1, "by_slot": {"quiz": 4, "variant": 2}, "unparsed_gap_tasks": 0},
  "wip_claims_total": 3
}
"""

COMPLETION_JSON = """
{
  "ok": true, "armed": false,
  "reason": "nwc_moodle_data.settings:enable_completion_pull is FALSE",
  "last_attempt": {"timestamp": 0, "age_seconds": null, "ever_attempted": false},
  "interval_seconds": 900
}
"""

# Hostname-generic on purpose (P61 leakage rule, enforced by the gitleaks
# pre-commit gate): fixtures never carry a real estate domain.
MOODLE_STATUS_JSON = """
{"ok": true, "moodle_url": "https://moodle.example.invalid", "host_override": "",
 "sync_enabled": false, "automatic_sync": false, "connected": true}
"""

TESTERS_JSON = """
{
  "ok": true, "fence_domain": "demo.invalid",
  "counts": {"fenced_active": 12, "fenced_blocked": 1, "real_active": 0, "real_blocked": 0},
  "accounts": [], "notes": []
}
"""


# ---------------------------------------------------------------------------
# parser: the nwc drush envelope
# ---------------------------------------------------------------------------
def test_parse_nwc_drush_happy_json_through_pl_chrome():
    p = parsers.parse_nwc_drush(PL_CHROME + SIGNALS_JSON + "\nOK drush completed on live\n",
                                "nwc:signal-counts")
    assert p["ok"] is True
    assert p["data"]["total"] == 9
    assert p["data"]["fast_path_queue"]["depth"] == 2


def test_parse_nwc_drush_not_defined_is_the_deploy_gap_not_a_mystery():
    """THE state the console is in until the nwc MR is merged AND deployed."""
    p = parsers.parse_nwc_drush(NOT_DEFINED, "nwc:signal-counts")
    assert p["ok"] is False
    assert p.get("not_deployed") is True
    assert "nwc:signal-counts" in p["reason"]
    assert "deploy" in p["reason"].lower(), "the reason must carry the deploy hint"


def test_parse_nwc_drush_garbage_is_cannot_verify_not_empty():
    p = parsers.parse_nwc_drush("ssh: connect to host … port 22: Connection timed out",
                                "nwc:signal-counts")
    assert p["ok"] is False
    assert not p.get("not_deployed")
    assert p["reason"]


def test_parse_nwc_drush_ok_false_keeps_the_commands_own_reason():
    p = parsers.parse_nwc_drush('{"ok": false, "reason": "CANNOT VERIFY: db gone"}',
                                "nwc:signal-counts")
    assert p["ok"] is False
    assert "db gone" in p["reason"]


# ---------------------------------------------------------------------------
# view builders
# ---------------------------------------------------------------------------
def _parsed(js: str, cached_age=None) -> dict:
    p = parsers.parse_nwc_drush(PL_CHROME + js, "x")
    p["age"] = cached_age if cached_age is not None else 0
    p["cached"] = cached_age is not None
    return p


def test_signals_view_renders_counts_per_source():
    v = overview.signals_view(_parsed(SIGNALS_JSON))
    assert v["ok"] is True
    rows = {r["source"]: r for r in v["rows"]}
    assert rows["error"]["open"] == 2
    assert rows["help"]["open"] == 0
    assert v["fast_path"]["depth"] == 2
    assert "0.875" in v["help_ratio"]["verdict"] or "88" in v["help_ratio"]["verdict"]


def test_signals_view_zero_open_is_clean_not_missing():
    empty = SIGNALS_JSON.replace('"open": 3', '"open": 0').replace('"open": 2', '"open": 0')
    v = overview.signals_view(_parsed(empty))
    rows = {r["source"]: r for r in v["rows"]}
    assert rows["error"]["role"] == "ok", "a measured zero is clean, not unknown"


def test_signals_view_not_deployed_carries_the_hint():
    v = overview.signals_view(parsers.parse_nwc_drush(NOT_DEFINED, "nwc:signal-counts"))
    assert v["ok"] is False
    assert "deploy" in (v["reason"] + v.get("hint", "")).lower()


def test_view_age_stamp_present_when_cached():
    v = overview.signals_view(_parsed(SIGNALS_JSON, cached_age=240))
    assert "4m" in v["age_note"], "per-value age stamp must surface the cache age"
    v2 = overview.signals_view(_parsed(SIGNALS_JSON))
    assert "fresh" in v2["age_note"]


def test_gap_view_null_members_is_cannot_count_not_zero():
    v = overview.gap_status_view(_parsed(GAPS_JSON))
    guilds = {g["key"]: g for g in v["guilds"]}
    assert guilds["media"]["members_display"] not in ("0", 0)
    assert "cannot" in str(guilds["media"]["members_display"]).lower()
    assert guilds["pedagogy"]["open_gaps"] == 4


def test_gap_view_never_swept_is_loud():
    never = GAPS_JSON.replace('"timestamp": 1770630000, "age_seconds": 1800, "swept": true',
                              '"timestamp": 0, "age_seconds": null, "swept": false')
    v = overview.gap_status_view(_parsed(never))
    assert v["sweep"]["role"] in ("warn", "crit")
    assert "never" in v["sweep"]["verdict"].lower()


def test_completion_view_not_armed_shows_why_and_never_attempted():
    v = overview.completion_view(_parsed(COMPLETION_JSON), _parsed(MOODLE_STATUS_JSON))
    assert v["ok"] is True
    assert "enable_completion_pull" in v["armed"]["verdict"]
    assert "never" in v["last_attempt"]["verdict"].lower()
    assert v["api"]["role"] == "ok"


def test_users_view_nwd_counts_and_ssd_stays_pending_with_exact_need():
    v = overview.users_view(_parsed(TESTERS_JSON))
    assert v["ok"] is True
    assert v["nwd"]["fenced_active"] == 12
    assert v["ssd"]["state"] == "pending"
    assert "pl demo measure" in v["ssd"]["needs"], \
        "the ssd count names its exact tranche-3 need, not a vague TODO"


# ---------------------------------------------------------------------------
# pending list: implemented slots leave, unimplemented stay
# ---------------------------------------------------------------------------
def test_pending_list_shrunk_to_what_is_actually_still_pending():
    pend = overview.pair_pending_slots()
    assert pend, "the list must stay non-empty (SSO + return leg + ssd count)"
    labels = " | ".join(p["label"] for p in pend)
    needs = " | ".join(p["needs"] for p in pend)
    # Still pending — with their needs intact:
    assert "SSO" in labels
    assert "return leg" in labels
    assert "ssd" in labels.lower()
    # Wired in this tranche — must no longer be listed as pending:
    for gone in ("error-report queue", "help feedback", "fast-path queue depth",
                 "guild backlogs", "completion pull"):
        assert gone not in labels, f"{gone} is wired now; a stale PENDING entry lies"
    assert "nwc:signal-counts" not in needs
    assert "nwc:editorial:gap-status" not in needs


# ---------------------------------------------------------------------------
# template: the pair slot fragment renders the new rows honestly
# ---------------------------------------------------------------------------
def _env():
    jinja2 = pytest.importorskip("jinja2")
    return jinja2.Environment(loader=jinja2.FileSystemLoader(str(TPL)), autoescape=True)


BASE_CTX = dict(user={"name": "rob", "role": "owner"}, can_act=False, scope=None,
                tab="visuals", tab_count="", tab_alert=False)


def _nwc_ctx(signals=None, gaps=None, completion=None, users=None) -> dict:
    return {
        "site": "nwd",
        "signals": signals if signals is not None else overview.signals_view(_parsed(SIGNALS_JSON)),
        "gaps": gaps if gaps is not None else overview.gap_status_view(_parsed(GAPS_JSON)),
        "completion": completion if completion is not None
        else overview.completion_view(_parsed(COMPLETION_JSON), _parsed(MOODLE_STATUS_JSON)),
        "users": users if users is not None else overview.users_view(_parsed(TESTERS_JSON)),
    }


def test_pair_fragment_renders_not_deployed_as_cannot_verify_with_hint():
    """The not-found-on-live rendering proof — the state live will be in first."""
    nd = overview.signals_view(parsers.parse_nwc_drush(NOT_DEFINED, "nwc:signal-counts"))
    out = _env().get_template("_ov_slot_pair.html").render(
        pair_sites=[], pending=overview.pair_pending_slots(),
        guild_edges=overview.skeleton_context()["guild_edges"],
        nwc=_nwc_ctx(signals=nd), slot="pair", **BASE_CTX)
    assert "CANNOT VERIFY" in out
    assert "deploy" in out.lower()
    assert "nwc:signal-counts" in out


def test_pair_fragment_renders_counts_and_age_stamp():
    ctx = _nwc_ctx(signals=overview.signals_view(_parsed(SIGNALS_JSON, cached_age=240)))
    out = _env().get_template("_ov_slot_pair.html").render(
        pair_sites=[], pending=overview.pair_pending_slots(),
        guild_edges=overview.skeleton_context()["guild_edges"],
        nwc=ctx, slot="pair", **BASE_CTX)
    assert "fast-path" in out.lower()
    assert "4m" in out, "the per-value age stamp must be visible"
    assert "Pedagogy" in out


def test_pair_fragment_without_nwc_context_still_renders():
    """Older callers (and scoped-out readers) pass no nwc block — the fragment
    must degrade to the tranche-1 rendering, not crash."""
    out = _env().get_template("_ov_slot_pair.html").render(
        pair_sites=[], pending=overview.pair_pending_slots(),
        guild_edges=overview.skeleton_context()["guild_edges"],
        slot="pair", **BASE_CTX)
    assert "PENDING" in out


# ---------------------------------------------------------------------------
# main.py wiring: cached collector, live tier, latency budget — by AST/source
# ---------------------------------------------------------------------------
MAIN_SRC = (APP / "main.py").read_text()
MAIN_TREE = ast.parse(MAIN_SRC)


def _fn_src(name: str) -> str:
    for node in ast.walk(MAIN_TREE):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name == name:
            return ast.get_source_segment(MAIN_SRC, node) or ""
    return ""


def test_gather_nwc_exists_and_goes_through_the_cached_collector():
    src = _fn_src("_nwc_drush_probe") + _fn_src("_gather_nwc")
    assert src, "no _gather_nwc/_nwc_drush_probe in main.py"
    assert "run_pl_cached" in src, "drush probes must use the TTL cache, never bare run_pl"
    assert "OVERVIEW_DRUSH_TTL" in src, "drush probes must be latency-tiered on their own TTL"
    assert "--tier=live" in src
    assert '"--"' in src, "drush args must go through the verb's -- separator"


def test_gather_nwc_is_scope_narrowed_before_the_shellout():
    src = _fn_src("_gather_nwc")
    assert "demo_sites" in src, "scope must be checked BEFORE the shell-out"


def test_drush_ttl_is_latency_tiered():
    assert config.OVERVIEW_DRUSH_TTL >= 300, \
        "drush-over-ssh measured 5-7s per probe — TTL must be snapshot-class (>=300s)"
    assert config.OVERVIEW_DRUSH_TTL >= config.PANE_CACHE_TTL


def test_pair_slot_route_passes_nwc():
    src = _fn_src("pane_visuals_slot")
    assert "_gather_nwc" in src, "the pair slot must gather the nwc interconnection data"
