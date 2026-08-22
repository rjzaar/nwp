"""The Settings pane — the estate's DECLARED FACTS, read-only (ops#383).

WHAT THIS PANE IS, AND WHAT IT IS DELIBERATELY NOT

    It is a WINDOW onto facts that are declared somewhere else — merge
    authority (ops#385), review mode (ADR-0037), each site's canonical phase
    (ops#33), the merge queue, and how fresh the console's own feeds are. It
    is NOT a second place to set any of them.

    That is not a style preference. `approvers:` is the estate's worked
    example: the review mode is derived from ONE declaration, there is
    deliberately no `pl mr review-mode set`, and CLAUDE.md records why — "a
    policy expressed in several places is a policy that drifts". ops#385 says
    the same thing about merge authority in as many words: "no console
    toggle". So this file asserts the ABSENCE of controls as hard as it
    asserts the presence of content.

THE THREE STATES, WHICH ARE NEVER TWO

    declared      we read the source and it says something.
    not-declared  we read the source and it declares nothing. (No authority
                  granted is the normal state; it must not read as an error.)
    unavailable   we could not look. Never an empty list, never a default that
                  looks like a decision.

    Every feed on this pane carries one of those three, and the tests below
    pin each one per feed, because "I could not look" rendering as "there is
    nothing there" is the estate's most expensive recurring bug.

TENANCY
    Owner-only, and stricter than Sessions: the tab is not even rendered for a
    non-owner, and /panes/settings is a 403 with an audited denial.
"""
import json
import os
import sys
import tempfile
from pathlib import Path

import pytest

CONSOLE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(CONSOLE))

TEMPLATES = CONSOLE / "templates"


# ---------------------------------------------------------------------------
# fixtures — the review/sessions idiom: module-scoped env, fresh app import
# ---------------------------------------------------------------------------
@pytest.fixture(scope="module")
def mod():
    pytest.importorskip("fastapi")
    pytest.importorskip("httpx")
    tmp = tempfile.mkdtemp(prefix="nwp-console-settings-test-")
    os.environ["NWP_CONSOLE_DATA"] = tmp
    os.environ["NWP_CONSOLE_ROOT"] = tmp
    os.environ["NWP_CONSOLE_QUOKKA_URL"] = "http://127.0.0.1:9"
    os.environ["NWP_CONSOLE_STT_BACKEND"] = "off"
    os.environ["NWP_CONSOLE_TTS_BACKEND"] = "off"
    for m in list(sys.modules):
        if m == "app" or m.startswith("app."):
            del sys.modules[m]
    from app import main as app_main

    app_main.store.add_user("rob", "owner")
    app_main.store.add_user("olly", "operator")
    app_main.store.add_user("vera", "viewer")
    return app_main


def _client(mod, name="rob"):
    from fastapi import Request
    from fastapi.testclient import TestClient

    def _as_header_user(request: Request):
        who = request.headers.get("x-test-user")
        u = mod.store.get_user(who) if who else None
        return None if u is None else {"name": who, "role": u.get("role", "viewer")}

    mod.app.dependency_overrides[mod.current_user] = _as_header_user
    return TestClient(mod.app, headers={"x-test-user": name})


# -- the one boundary these tests fake: `pl` ---------------------------------
AUTHORITY_OK = {
    "declared": True,
    "granted_to": "nwp-automation-dev",
    "granted_by": "rob",
    "granted_on": "2026-08-22",
    "ref": "ops#385",
    "scope": "non-sensitive paths, no prod-phase site, never CLAUDE.md",
}

REVIEW_MODE_SOLO = """
review mode: solo
  from:          approvers: in ~/nwp/private/secrets-registry.yml (1 declared)
  projection:    solo

ONE reviewer. You approve by clicking Merge on the MR page.
"""

RAG_JSON = {
    "sites": [
        {"site": "nwc", "rag": "GREEN", "phase": "live"},
        {"site": "ss", "rag": "AMBER", "phase": "(dev)"},
        {"site": "ver", "rag": "GREEN", "phase": "prod"},
    ]
}

QUEUE_JSON = {
    "ok": True,
    "mrs": [
        {"project": "nwp/nwp", "iid": 471, "title": "console: settings pane",
         "url": "https://h/nwp/nwp/-/merge_requests/471",
         "ready": False, "blockers": ["pipeline running"]},
        {"project": "nwp/nwp", "iid": 468, "title": "docs: tidy",
         "url": "https://h/nwp/nwp/-/merge_requests/468", "ready": True, "blockers": []},
    ],
}


def _fake_pl(mod, monkeypatch, *, authority=None, review_mode=REVIEW_MODE_SOLO,
             rag=None, queue=None, authority_rc=0, review_rc=0, queue_rc=0,
             authority_err="", review_err="", queue_err=""):
    """Fake the ONE boundary (run_pl_cached), dispatching on argv.

    Passing None for a feed means "this verb answered with nothing usable",
    which is how the not-yet-existing verbs behave today.
    """
    seen = []

    def fake(root, args, **kw):
        args = list(args)
        seen.append(args)
        if args[:2] == ["mr", "authority"]:
            out = json.dumps(authority) if authority is not None else ""
            return {"rc": authority_rc, "out": out, "err": authority_err,
                    "secs": 0.1, "cmd": "pl mr authority --json"}
        if args[:2] == ["mr", "review-mode"]:
            return {"rc": review_rc, "out": review_mode or "", "err": review_err,
                    "secs": 0.1, "cmd": "pl mr review-mode"}
        if args[:2] == ["mr", "ready"]:
            out = json.dumps(queue) if queue is not None else ""
            return {"rc": queue_rc, "out": out, "err": queue_err,
                    "secs": 0.1, "cmd": "pl mr ready --json"}
        if args[:1] == ["rag"]:
            out = json.dumps(rag if rag is not None else RAG_JSON)
            return {"rc": 0, "out": out, "err": "", "secs": 0.1, "cmd": "pl rag --json"}
        return {"rc": 2, "out": "", "err": "unstubbed: " + " ".join(args),
                "secs": 0.1, "cmd": "pl " + " ".join(args)}

    monkeypatch.setattr(mod, "run_pl_cached", fake)
    return seen


# ---------------------------------------------------------------------------
# 1. the tab exists, is owner-only, and is covered by help
# ---------------------------------------------------------------------------
def test_settings_is_a_tab(mod):
    assert ("settings", "Settings") in mod.PANES


def test_settings_is_declared_owner_only(mod):
    """One list, so the tab bar and the route cannot disagree about who may
    see it. A pane that is hidden in the bar but reachable at its URL is not
    owner-only, it is unlisted."""
    assert "settings" in mod.OWNER_ONLY_PANES


def test_settings_has_its_own_help_section(mod):
    from app import help as help_mod

    sec = help_mod.get_section("settings")
    assert sec is not None, "no help section 'settings'"
    text = " ".join(_strings(sec)).lower()
    for must in ("declared", "read-only", "not declared", "secrets-registry"):
        assert must in text, f"settings help never mentions {must!r}"


def test_settings_help_says_this_is_not_where_you_change_things(mod):
    """The whole doctrine of the pane, in the place an operator reads when they
    wonder why there is no switch."""
    from app import help as help_mod

    text = " ".join(_strings(help_mod.get_section("settings"))).lower()
    assert "drift" in text or "one place" in text, (
        "the settings help does not explain WHY there is no toggle here"
    )


def _strings(obj):
    if isinstance(obj, str):
        yield obj
    elif isinstance(obj, dict):
        for v in obj.values():
            yield from _strings(v)
    elif isinstance(obj, (list, tuple)):
        for v in obj:
            yield from _strings(v)


# ---------------------------------------------------------------------------
# 2. tenancy — a non-owner may not reach it, and may not see it
# ---------------------------------------------------------------------------
@pytest.mark.parametrize("who", ["olly", "vera"])
def test_a_non_owner_cannot_reach_the_settings_pane(mod, monkeypatch, who):
    _fake_pl(mod, monkeypatch, authority=AUTHORITY_OK)
    r = _client(mod, who).get("/panes/settings")
    assert r.status_code == 403, (
        f"{who} ({mod.store.get_user(who)['role']}) reached the settings pane"
    )


@pytest.mark.parametrize("who", ["olly", "vera"])
def test_a_non_owner_does_not_see_the_settings_tab(mod, who):
    r = _client(mod, who).get("/")
    assert r.status_code == 200
    assert 'id="tab-settings"' not in r.text, "the settings tab rendered for a non-owner"
    assert "'settings'" not in r.text, (
        "the pane-switching script still lists 'settings', so it can be activated"
    )


def test_the_owner_does_see_the_settings_tab(mod):
    r = _client(mod, "rob").get("/")
    assert r.status_code == 200
    assert 'id="tab-settings"' in r.text


def test_a_refused_settings_read_is_audited(mod, monkeypatch):
    _fake_pl(mod, monkeypatch, authority=AUTHORITY_OK)
    before = len(mod.audit.tail(500))
    _client(mod, "vera").get("/panes/settings")
    rows = mod.audit.tail(500)[before:]
    assert any(r.get("action", "").startswith("settings.denied") for r in rows), (
        f"no settings.denied audit row after a refusal: {rows}"
    )


# ---------------------------------------------------------------------------
# 3. READ-ONLY — there is no second place to set any of this
# ---------------------------------------------------------------------------
def test_the_settings_pane_offers_no_control_at_all():
    """ops#385: "no console toggle, no env var, no CLI flag". A form here would
    be exactly the second declaration site ADR-0037 removed from review mode."""
    body = (TEMPLATES / "pane_settings.html").read_text()
    for forbidden in ("<form", "hx-post", "hx-put", "hx-delete", "<input", "<select"):
        assert forbidden not in body, (
            f"pane_settings.html contains {forbidden!r} — the Settings pane RENDERS "
            "declared facts; it must never be a place to set one"
        )


def test_no_settings_write_route_exists(mod):
    """The template could be innocent and the route still be there."""
    paths = [r.path for r in mod.app.routes if getattr(r, "path", "").startswith("/settings")]
    assert not paths, f"write-shaped settings routes exist: {paths}"
    for r in mod.app.routes:
        if getattr(r, "path", "") == "/panes/settings":
            assert set(r.methods) <= {"GET", "HEAD"}, f"/panes/settings accepts {r.methods}"


# ---------------------------------------------------------------------------
# 4. merge authority — declared, not declared, and could-not-look
# ---------------------------------------------------------------------------
def test_declared_merge_authority_renders_with_its_declaration_site(mod, monkeypatch):
    _fake_pl(mod, monkeypatch, authority=AUTHORITY_OK)
    r = _client(mod, "rob").get("/panes/settings")
    assert r.status_code == 200
    assert "nwp-automation-dev" in r.text
    assert "ops#385" in r.text
    assert "secrets-registry.yml" in r.text, (
        "the pane does not say WHERE merge authority is declared"
    )


def test_undeclared_merge_authority_is_not_an_error_and_not_a_grant(mod, monkeypatch):
    """No authority is the NORMAL state (a human merges). It must read as a
    fact that was looked up, not as a failure and not as a grant."""
    _fake_pl(mod, monkeypatch, authority={"declared": False})
    r = _client(mod, "rob").get("/panes/settings")
    assert r.status_code == 200
    assert "NOT DECLARED" in r.text
    assert "a human merges" in r.text.lower()


def test_unreadable_merge_authority_says_so_rather_than_defaulting(mod, monkeypatch):
    """The verb is missing / the registry is unreadable. That is "I could not
    look" and it must never render as "no authority is granted" — the two have
    the same practical effect today and opposite meanings tomorrow."""
    _fake_pl(mod, monkeypatch, authority=None, authority_rc=2,
             authority_err="unknown: pl mr authority")
    r = _client(mod, "rob").get("/panes/settings")
    assert r.status_code == 200
    assert "CANNOT VERIFY" in r.text
    assert "unknown: pl mr authority" in r.text, "the reason is not shown"
    assert "NOT DECLARED" not in r.text.split("Review mode")[0], (
        "an unreadable authority feed rendered as NOT DECLARED — that is a "
        "measurement substituted for a reading that never happened"
    )


def test_authority_module_states(mod):
    from app import settings as st

    ok = st.parse_authority({"rc": 0, "out": json.dumps(AUTHORITY_OK), "err": ""})
    assert ok["state"] == st.DECLARED
    assert ok["granted_to"] == "nwp-automation-dev"

    none = st.parse_authority({"rc": 0, "out": json.dumps({"declared": False}), "err": ""})
    assert none["state"] == st.NOT_DECLARED

    dead = st.parse_authority({"rc": 127, "out": "", "err": "no such verb"})
    assert dead["state"] == st.UNAVAILABLE
    assert "no such verb" in dead["reason"]

    junk = st.parse_authority({"rc": 0, "out": "not json at all", "err": ""})
    assert junk["state"] == st.UNAVAILABLE, "unparseable output must not read as 'none'"


def test_an_incomplete_authority_block_fails_closed(mod):
    """ops#385 §4: unparseable block / unrecognised scope -> a human merges.
    A grant with no scope is not a narrower grant, it is an unusable one."""
    from app import settings as st

    got = st.parse_authority({"rc": 0, "err": "", "out": json.dumps(
        {"declared": True, "granted_to": "some-bot", "ref": "", "scope": ""})})
    assert got["state"] == st.DECLARED
    assert got["warnings"], "a block missing scope:/ref: raised no warning"
    assert got["fails_closed"] is True


# ---------------------------------------------------------------------------
# 5. review mode — derived, never set here
# ---------------------------------------------------------------------------
def test_review_mode_is_rendered_with_its_source(mod, monkeypatch):
    _fake_pl(mod, monkeypatch, authority=AUTHORITY_OK)
    r = _client(mod, "rob").get("/panes/settings")
    assert "solo" in r.text
    assert "approvers:" in r.text, "the pane does not name the declaration that derives the mode"


def test_review_mode_parses_the_four_sources(mod):
    from app import settings as st

    solo = st.parse_review_mode({"rc": 0, "out": REVIEW_MODE_SOLO, "err": ""})
    assert solo["state"] == st.DECLARED and solo["mode"] == "solo"
    assert "approvers:" in solo["source"]

    fallback = st.parse_review_mode({"rc": 0, "err": "", "out": (
        "review mode: team\n  from:          NOT DECLARED — no registry, no projection\n"
        "  projection:    (none)\n")})
    assert fallback["state"] == st.NOT_DECLARED, (
        "the fail-closed default rendered as a declared policy — CLAUDE.md: "
        "'I could not read the policy' must never look like a decision"
    )
    assert fallback["mode"] == "team", "the fail-closed direction is team"

    drift = st.parse_review_mode({"rc": 1, "err": "", "out": (
        "review mode: solo\n  from:          approvers: in registry (1 declared)\n"
        "  projection:    team\n"
        "DRIFT: the registry says solo but the projection says team.\n")})
    assert drift["drift"] is True
    assert drift["state"] == st.DECLARED

    dead = st.parse_review_mode({"rc": 2, "out": "", "err": "pl: command not found"})
    assert dead["state"] == st.UNAVAILABLE and "command not found" in dead["reason"]


def test_the_tab_dot_is_reserved_for_things_that_are_actually_wrong(mod):
    """The anti-fatigue decision, pinned so it is a decision and not a drift.

    A dot that is lit every ordinary day is a dot people stop seeing — the
    estate learned that when `pl canonical show` went red in forty worktrees
    for a condition its own doctrine calls normal. So: no authority granted is
    NOT an alert (it is the safe state), and a verb that does not exist here
    yet is NOT an alert (it will hold for weeks). Drift IS.
    """
    from app import settings as st

    quiet = st.parse_review_mode({"rc": 0, "out": REVIEW_MODE_SOLO, "err": ""})
    assert st.alert(st.parse_authority({"rc": 0, "out": '{"declared": false}', "err": ""}),
                    quiet, {"state": st.DECLARED}) is False
    assert st.alert(st.parse_authority({"rc": 2, "out": "", "err": "unknown: pl mr authority"}),
                    quiet, {"state": st.DECLARED}) is False, (
        "a not-yet-built verb lights the tab dot permanently"
    )
    assert st.alert(st.parse_authority({"rc": 0, "err": "", "out": json.dumps(
        {"declared": True, "granted_to": "b", "scope": ""})}), quiet,
        {"state": st.DECLARED}) is True, "an incomplete GRANT is a real defect and must show"


def test_review_mode_drift_flags_the_tab(mod, monkeypatch):
    """Drift means CI is enforcing the wrong policy right now. That belongs on
    the tab bar, not only inside a pane nobody opened."""
    _fake_pl(mod, monkeypatch, authority=AUTHORITY_OK, review_rc=1, review_mode=(
        "review mode: solo\n  from: approvers: in registry (1 declared)\n"
        "  projection:    team\nDRIFT: the registry says solo but the projection says team.\n"))
    r = _client(mod, "rob").get("/panes/settings")
    assert "DRIFT" in r.text
    assert 'hx-swap-oob' in r.text and 'tabcount-settings' in r.text


# ---------------------------------------------------------------------------
# 6. canonical phase per site
# ---------------------------------------------------------------------------
def test_canonical_phases_render_per_site(mod, monkeypatch):
    _fake_pl(mod, monkeypatch, authority=AUTHORITY_OK)
    r = _client(mod, "rob").get("/panes/settings")
    assert "nwc" in r.text and "live" in r.text
    assert "prod" in r.text, "a prod-phase site did not render"


def test_a_defaulted_phase_is_not_a_declared_one(mod):
    from app import settings as st

    view = st.phases_view({"ok": True, "sites": [
        {"site": "a", "phase": "live"}, {"site": "b", "phase": "(dev)"}, {"site": "c"}]},
        {"source": "published", "age_human": "3m", "stale": False})
    by = {r["site"]: r for r in view["rows"]}
    assert by["a"]["declared"] is True
    assert by["b"]["declared"] is False and by["b"]["known"] is True
    assert by["c"]["known"] is False, (
        "a feed that carries no phase for a site must read as 'not carried', "
        "never as the dev default — that would be inventing a declaration"
    )


def test_an_unreadable_fleet_feed_shows_no_phase_table(mod):
    from app import settings as st

    view = st.phases_view({"ok": False, "error": "no published snapshot on this host"}, {})
    assert view["state"] == st.UNAVAILABLE
    assert "no published snapshot" in view["reason"]
    assert view["rows"] == []


def test_an_unreadable_fleet_feed_renders_as_unavailable_not_empty(mod, monkeypatch):
    _fake_pl(mod, monkeypatch, authority=AUTHORITY_OK, rag={"nope": True})
    r = _client(mod, "rob").get("/panes/settings")
    assert r.status_code == 200
    low = r.text.lower()
    assert "cannot verify" in low
    assert "no sites are canonically" not in low, (
        "an unreadable fleet feed produced a positive claim about phases"
    )


# ---------------------------------------------------------------------------
# 7. the merge queue — consume `pl mr ready --json`, degrade honestly
# ---------------------------------------------------------------------------
def test_the_merge_queue_renders_readiness(mod, monkeypatch):
    _fake_pl(mod, monkeypatch, authority=AUTHORITY_OK, queue=QUEUE_JSON)
    r = _client(mod, "rob").get("/panes/settings")
    assert "471" in r.text and "468" in r.text
    assert "pipeline running" in r.text


def test_a_missing_ready_verb_is_not_an_empty_queue(mod, monkeypatch):
    """`pl mr ready` is being built by another stream. Until it lands the pane
    must say it cannot see the queue — an empty table would read as 'nothing
    to merge', which is the opposite of the truth on most days."""
    _fake_pl(mod, monkeypatch, authority=AUTHORITY_OK, queue=None, queue_rc=2,
             queue_err="unknown: pl mr ready")
    r = _client(mod, "rob").get("/panes/settings")
    body = r.text
    assert "unknown: pl mr ready" in body
    assert "nothing to merge" not in body.lower()
    assert "no open merge requests" not in body.lower()


def test_an_answered_empty_queue_is_allowed_to_say_empty(mod):
    """The other half of the same rule: when the verb DID answer, zero rows is
    a real measurement and must be reported as one."""
    from app import settings as st

    view = st.queue_view({"rc": 0, "out": json.dumps({"ok": True, "mrs": []}), "err": ""})
    assert view["state"] == st.DECLARED and view["rows"] == []


def test_a_row_with_no_readiness_field_says_so(mod):
    from app import settings as st

    view = st.queue_view({"rc": 0, "err": "", "out": json.dumps(
        {"ok": True, "mrs": [{"project": "p", "iid": 1, "title": "t"}]})})
    assert view["rows"][0]["ready"] is None, (
        "a missing readiness field was coerced to a boolean — that invents a verdict"
    )


# ---------------------------------------------------------------------------
# 8. freshness of what this console itself serves
# ---------------------------------------------------------------------------
def test_freshness_distinguishes_absent_from_old(mod):
    from app import settings as st

    rows = st.freshness_view(
        # A placeholder host, not a real one: the engine repo is publicly
        # mirrored and the gitleaks ruleset bans internal hostnames in tracked
        # files (it caught this line on the first commit attempt).
        fleet_prov={"snapshot_present": True, "age_human": "12m", "stale": False,
                    "source": "published", "host": "publisher-host"},
        library_prov={"snapshot_present": False, "age_human": "", "stale": False,
                      "source": "local", "note": "no published library on this host"},
    )
    by = {r["name"]: r for r in rows}
    assert by["fleet snapshot"]["present"] is True
    assert by["library bundle"]["present"] is False
    assert by["library bundle"]["age_human"] == "", (
        "an absent bundle was given an age — absence has no age"
    )


def test_freshness_renders_on_the_pane(mod, monkeypatch):
    _fake_pl(mod, monkeypatch, authority=AUTHORITY_OK)
    r = _client(mod, "rob").get("/panes/settings")
    low = r.text.lower()
    assert "fleet snapshot" in low
    assert "library" in low


# ---------------------------------------------------------------------------
# 9. the pane may not become an unscoped side door
# ---------------------------------------------------------------------------
def test_the_settings_module_cannot_run_anything(mod):
    """Same boundary help.py carries: this module is a VIEW over already-read
    text. If it could shell out, the read-only claim would rest on nobody
    calling the wrong function."""
    import ast

    tree = ast.parse((CONSOLE / "app" / "settings.py").read_text())
    imported = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            imported.extend(a.name for a in node.names)
        elif isinstance(node, ast.ImportFrom):
            imported.append(node.module or "")
            imported.extend(a.name for a in node.names)
    for forbidden in ("runner", "subprocess", "actions", "main", "os"):
        assert not any(forbidden == str(i) or str(i).endswith(f".{forbidden}")
                       for i in imported), f"app/settings.py imports {forbidden!r}"
