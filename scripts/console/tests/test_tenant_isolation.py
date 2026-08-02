"""T7 — CROSS-PROJECT LEAKAGE, end to end, through the real HTTP surface.

THE test of this whole stage. The fixture snapshot contains seven `ss-nw`
sites AND five foreign ones (avc, mt, cathnet, dir, dir1). `dana` is a member
of `ss-nw` only. Every assertion below is of the form "the response must not
contain a foreign site name", checked against the rendered bytes — not against
an intermediate data structure, because what leaks is what is *sent*.

To see it fail on purpose (proof the test bites):

    NWP_CONSOLE_TEST_DISABLE_SCOPE=1 pytest tests/test_tenant_isolation.py

which makes the scoped gatherers stop filtering — i.e. simulates a future
change that forgets the boundary — and every leakage assertion below goes red.
That switch is honoured ONLY by this test module (see _maybe_break_scoping);
it does not exist in the application.
"""
import json
import os
import shutil
import sys
import tempfile
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

FIXTURE = Path(__file__).resolve().parent / "fixtures" / "fleet-state-mixed.json"

# Sites dana must NEVER see, anywhere, in any response.
FOREIGN = ("avc", "mt", "cathnet", "dir1")
MINE = ("nwc", "ssc", "nwd", "ssd", "saintschool")


@pytest.fixture(scope="module")
def env():
    tmp = tempfile.mkdtemp(prefix="nwp-console-tenant-test-")
    os.environ["NWP_CONSOLE_DATA"] = tmp
    os.environ["NWP_CONSOLE_ROOT"] = tmp
    os.environ["NWP_CONSOLE_QUOKKA_URL"] = "http://127.0.0.1:9"     # ollama dead
    os.environ["NWP_CONSOLE_STT_BACKEND"] = "off"
    os.environ["NWP_CONSOLE_TTS_BACKEND"] = "off"
    os.environ["NWP_CONSOLE_DEMO_SITES"] = "nwd,ssd,avc"            # avc is a demo site TOO
    os.environ["NWP_CONSOLE_CI_PROJECTS"] = "nwp/nwp,nwp/nwc"
    os.environ["NWP_CONSOLE_SCOPE_STRICT"] = "1"                    # a leak must RAISE in tests
    os.environ["NWP_CONSOLE_FLEET_MAX_AGE"] = "0"                   # never "stale"
    shutil.copy(FIXTURE, Path(tmp) / "fleet-state.json")
    for m in list(sys.modules):
        if m == "app" or m.startswith("app."):
            del sys.modules[m]
    return tmp


@pytest.fixture(scope="module")
def mod(env):
    pytest.importorskip("fastapi")
    pytest.importorskip("httpx")
    from app import main as app_main

    # One project holding exactly the ss-nw seven; the rest belong to nobody.
    app_main.projects.add_project(
        "ss-nw", name="Saint School + Narrow Way",
        sites=["nwc", "ssc", "nwd", "ssd", "ss", "ss2", "saintschool"],
        demo_sites=["nwd"],
        gitlab={"issue_label": "project::ss-nw", "ci_projects": ["nwp/nwc"]},
        created_by="rob",
    )
    app_main.projects.add_project(
        "personal", name="Operator's own",
        sites=["avc", "mt", "cathnet", "dir", "dir1"],
        demo_sites=["avc"],
        gitlab={"issue_label": "project::personal", "ci_projects": ["nwp/nwp"]},
        created_by="rob",
    )
    app_main.store.add_user("dana", "operator")
    app_main.store.add_user("rob2", "owner")
    app_main.store.add_user("nomad", "operator")          # member of nothing
    app_main.projects.set_project_role("dana", "ss-nw", "operator")
    _maybe_break_scoping(app_main)
    return app_main


def _maybe_break_scoping(app_main):
    """The deliberate hole, for proving the test can fail.

    With NWP_CONSOLE_TEST_DISABLE_SCOPE=1 the scoped gatherers are replaced by
    their fleet-wide raw counterparts — exactly what a future refactor that
    "forgot to pass the scope" would produce. Every leakage assertion in this
    file must then fail. If they still pass, the assertions are not testing
    what they claim to.
    """
    if os.environ.get("NWP_CONSOLE_TEST_DISABLE_SCOPE") != "1":
        return
    import app.scope as scope_mod

    app_main._gather_rag = lambda sc, force=False: app_main._gather_rag_raw(force=force)
    app_main._gather_todo = lambda sc, force=False: app_main._gather_todo_raw(force=force)
    app_main._gather_demo = lambda sc, force=False: app_main._gather_demo_raw(
        list(app_main.config.DEMO_SITES), force=force)
    def _unscoped_issues(sc, state="opened", label=""):
        blocks = app_main._gather_issues_raw(state, label)
        for b in blocks:
            b["shown"] = len(b["issues"])          # NOT scope-filtered: the hole
        return blocks, {"ok": any(b["ok"] for b in blocks), "any_unreadable": False,
                        "unreadable": [], "truncated": False,
                        "shown": sum(b["shown"] for b in blocks), "total": None, "error": ""}

    app_main._gather_issues = _unscoped_issues
    app_main._gather_security = lambda sc, force=False: app_main._gather_security_raw(force=force)
    # ...and the second net too, since a real regression could remove either.
    scope_mod.scrub = lambda obj, scope: (obj, 0)
    scope_mod.redact = lambda ctx, scope: ctx


def _client(mod, name):
    """A client that authenticates as `name` on every request.

    The identity travels in a header rather than in a dependency_overrides
    entry, because that dict is global to the app: two client fixtures in one
    test would otherwise both resolve to whichever was created last, and the
    isolation assertions would silently be checking the wrong user. The ROLE is
    looked up in the store, exactly as the real current_user does.
    """
    from fastapi import Request
    from fastapi.testclient import TestClient

    def _as_header_user(request: Request):
        who = request.headers.get("x-test-user")
        u = mod.store.get_user(who) if who else None
        return None if u is None else {"name": who, "role": u.get("role", "viewer")}

    mod.app.dependency_overrides[mod.current_user] = _as_header_user
    return TestClient(mod.app, headers={"x-test-user": name})


@pytest.fixture
def dana(mod):
    return _client(mod, "dana")


@pytest.fixture
def owner(mod):
    return _client(mod, "rob2")


@pytest.fixture
def nomad(mod):
    return _client(mod, "nomad")


def assert_no_foreign(text, where):
    for f in FOREIGN:
        assert f not in text, f"LEAK: foreign site {f!r} appeared in {where}"


# ---------------------------------------------------------------------------
# read panes
# ---------------------------------------------------------------------------
@pytest.mark.parametrize("path", ["/panes/fleet", "/panes/todo", "/panes/backups",
                                  "/panes/demo", "/panes/visuals", "/tabs/counts", "/"])
def test_read_surfaces_carry_no_foreign_site(dana, path):
    r = dana.get(path)
    assert r.status_code == 200, r.text[:300]
    assert_no_foreign(r.text, path)


def test_the_visuals_pane_actually_charts_dana_own_sites(dana):
    """The positive control for the line above.

    `/panes/visuals` passing the no-foreign-site check would be worthless if
    the pane rendered nothing at all — an empty pane leaks nothing and proves
    nothing. This asserts the pane really did draw dana's fleet, so the
    leakage assertion is measuring a populated page.
    """
    r = dana.get("/panes/visuals")
    assert r.status_code == 200, r.text[:300]
    assert "<svg" in r.text, "visuals pane drew no chart at all — leakage check would be vacuous"
    assert any(s in r.text for s in MINE), "visuals pane shows none of dana's own sites"


# ---------------------------------------------------------------------------
# help — a REACHABILITY property, not a leakage one.
#
# Help names no site, by construction (the content carries no markup and no
# site token), so "no foreign site appeared" would pass on a blank page. What
# is worth pinning here is that the real app serves it to a scoped member with
# SCOPE_STRICT on — i.e. that _pane()'s scrub did not drop a row and 500 — and
# that an unknown topic 404s instead of rendering an empty body.
# Requested by docs/reports/console-v2/help-wiring.md ("Known gap").
# ---------------------------------------------------------------------------
def _help_section_ids():
    from app import help as help_mod

    return [s["id"] for s in help_mod.SECTIONS]


def test_help_is_reachable_by_a_scoped_member(dana):
    r = dana.get("/help")
    assert r.status_code == 200, r.text[:300]
    assert_no_foreign(r.text, "/help")


@pytest.mark.parametrize("sid", _help_section_ids())
def test_every_help_section_is_reachable_by_a_scoped_member(dana, sid):
    r = dana.get(f"/help/{sid}")
    assert r.status_code == 200, r.text[:300]


@pytest.mark.parametrize("sid", ["nope", "does-not-exist", "roles2"])
def test_an_unknown_help_topic_404s_for_a_scoped_member(dana, sid):
    r = dana.get(f"/help/{sid}")
    assert r.status_code == 404, (
        f"/help/{sid} returned {r.status_code}, not 404 — an unknown topic rendering "
        f"as a 200 is indistinguishable from a topic nobody wrote"
    )


def test_the_help_section_ids_were_actually_found():
    """The parametrize above is computed; an empty list would make it vacuous."""
    assert len(_help_section_ids()) >= 10, "help section walker found almost nothing"


def _scope_of(mod, name):
    """The Scope the app itself would resolve for `name` — memberships read
    from the store, exactly as resolve_scope() does on a real request."""
    from app.scope import resolve

    u = mod.store.get_user(name)
    rec = {"name": name, "role": u["role"], "projects": mod.store.memberships(name)}
    return resolve(rec, mod.projects.all_projects(),
                   console_demo_sites=mod.config.DEMO_SITES,
                   ci_allowlist=mod.config.CI_PROJECTS)


def test_fleet_pane_shows_my_sites_and_recounts(dana, mod):
    r = dana.get("/panes/fleet")
    assert r.status_code == 200
    for s in ("nwc", "ssc", "nwd", "ssd", "saintschool"):
        assert s in r.text, f"{s} missing from my own fleet pane"
    assert_no_foreign(r.text, "/panes/fleet")
    # The fixture's fleet-wide totals are 3 RED / 2 AMBER. Scoped to ss-nw the
    # true answer is 0 RED / 1 AMBER. A count taken before filtering would
    # encode exactly the foreign facts the filtering exists to hide, so the
    # recount is a leakage assertion, not a cosmetic one.
    rag, _res, _prov = mod._gather_rag(_scope_of(mod, "dana"))
    assert rag["counts"]["RED"] == 0, "RED count leaked foreign totals"
    assert rag["counts"]["AMBER"] == 1
    assert len(rag["sites"]) == 7


def test_todo_summary_is_recomputed_not_inherited(dana, mod):
    r = dana.get("/panes/todo")
    assert r.status_code == 200
    assert_no_foreign(r.text, "/panes/todo")
    todo = mod._gather_todo(_scope_of(mod, "dana"))[0]
    assert todo["summary"]["total"] == 2, "todo total still counts foreign items"
    assert todo["summary"]["high"] == 1, "todo high-priority count leaked foreign items"


def test_demo_pane_only_covers_my_demo_site(dana):
    """avc is in config.DEMO_SITES but belongs to `personal`: the tier gate
    says the verb exists, the scope says whose site it may touch."""
    r = dana.get("/panes/demo")
    assert r.status_code == 200
    assert_no_foreign(r.text, "/panes/demo")


def test_publisher_hostname_is_redacted_for_a_member_but_not_the_owner(dana, owner):
    """prov.host names the workstation — infrastructure a tenant needn't know."""
    assert "workstation-secret-hostname" not in dana.get("/panes/fleet").text
    assert "workstation-secret-hostname" in owner.get("/panes/fleet").text


# ---------------------------------------------------------------------------
# actions
# ---------------------------------------------------------------------------
def test_action_on_a_foreign_demo_site_is_refused_and_audited(dana, mod):
    r = dana.post("/actions/run", data={"action": "demo_reset", "site": "avc"})
    assert r.status_code == 200          # rendered refusal, not a crash
    assert "not a demo site you may act on" in r.text
    entry = json.loads(Path(mod.config.DATA_DIR / "audit.jsonl").read_text().splitlines()[-1])
    assert entry["ok"] is False
    assert entry["project"] == "ss-nw", "the rejection must be stamped with the scope it happened in"


def test_action_on_my_own_demo_site_builds_the_exact_argv(dana, mod, monkeypatch):
    seen = {}

    def fake_run(root, argv, timeout=None):
        seen["argv"] = argv
        return {"rc": 0, "out": "ok", "err": "", "secs": 0.1, "cmd": " ".join(argv)}

    monkeypatch.setattr(mod, "run_pl", fake_run)
    r = dana.post("/actions/run", data={"action": "demo_reset", "site": "nwd"})
    assert r.status_code == 200, r.text[:300]
    assert seen["argv"] == ["demo", "reset", "nwd", "--tier=live", "--if-idle", "30m", "--yes"]


def test_fleet_wide_action_is_refused_to_a_scoped_operator(dana):
    """`pl rag` sweeps every site. Filtering its OUTPUT afterwards is not the
    same promise as never having run it on a scoped user's behalf."""
    r = dana.post("/actions/run", data={"action": "rag_refresh"})
    assert r.status_code == 403


def test_owner_may_still_run_the_fleet_wide_action(owner, mod, monkeypatch):
    monkeypatch.setattr(mod, "run_pl",
                        lambda root, argv, timeout=None: {"rc": 0, "out": "", "err": "",
                                                          "secs": 0, "cmd": ""})
    assert owner.post("/actions/run", data={"action": "rag_refresh"}).status_code == 200


# ---------------------------------------------------------------------------
# GitLab surfaces
# ---------------------------------------------------------------------------
def test_issues_are_filtered_by_the_project_label(dana, mod, monkeypatch):
    monkeypatch.setattr(mod.gitlab, "list_issues", lambda *a, **k: {"ok": True, "data": [
        {"iid": 1, "title": "mine", "labels": ["project::ss-nw"], "updated_at": "2099-01-01T00:00:00Z"},
        {"iid": 2, "title": "SECRET-personal-issue", "labels": ["project::personal"],
         "updated_at": "2099-01-01T00:00:00Z"},
        {"iid": 3, "title": "UNLABELLED-ops-issue", "labels": [], "updated_at": "2099-01-01T00:00:00Z"},
    ]})
    r = dana.get("/panes/issues")
    assert r.status_code == 200
    assert "mine" in r.text
    assert "SECRET-personal-issue" not in r.text
    assert "UNLABELLED-ops-issue" not in r.text, "an unlabelled issue must not fall into a project"


def test_issue_write_to_a_foreign_issue_is_refused(dana, mod, monkeypatch):
    monkeypatch.setattr(mod.gitlab, "get_issue",
                        lambda *a, **k: {"ok": True, "data": {"iid": 2, "labels": ["project::personal"]}})
    called = {"n": 0}
    monkeypatch.setattr(mod.gitlab, "post_note",
                        lambda *a, **k: called.update(n=called["n"] + 1) or {"ok": True})
    r = dana.post("/issues/2/note", data={"body": "hello"})
    assert r.status_code == 403
    assert called["n"] == 0, "the write reached GitLab despite the refusal"


def test_issue_write_to_my_own_issue_is_allowed(dana, mod, monkeypatch):
    monkeypatch.setattr(mod.gitlab, "get_issue",
                        lambda *a, **k: {"ok": True, "data": {"iid": 1, "labels": ["project::ss-nw"]}})
    monkeypatch.setattr(mod.gitlab, "post_note", lambda *a, **k: {"ok": True, "data": {}})
    assert dana.post("/issues/1/note", data={"body": "hello"}).status_code == 200


def test_issue_write_fails_closed_when_the_tracker_is_unreachable(dana, mod, monkeypatch):
    monkeypatch.setattr(mod.gitlab, "get_issue", lambda *a, **k: {"ok": False, "error": "boom"})
    called = {"n": 0}
    monkeypatch.setattr(mod.gitlab, "post_note",
                        lambda *a, **k: called.update(n=called["n"] + 1) or {"ok": True})
    r = dana.post("/issues/9/note", data={"body": "x"})
    assert r.status_code == 502
    assert called["n"] == 0, "an API outage became a write-anywhere window"


def test_scoped_operator_cannot_strip_their_own_scoping_label(dana, mod, monkeypatch):
    monkeypatch.setattr(mod.gitlab, "get_issue",
                        lambda *a, **k: {"ok": True, "data": {"iid": 1, "labels": ["project::ss-nw"]}})
    r = dana.post("/issues/1/label", data={"label": "project::ss-nw", "mode": "remove"})
    assert r.status_code == 403


def test_ci_retry_outside_the_project_is_refused(dana):
    assert dana.post("/ci/retry", data={"project": "nwp/nwp", "pipeline_id": "1"}).status_code == 400


# ---------------------------------------------------------------------------
# audit, Quokka, admin
# ---------------------------------------------------------------------------
def test_audit_page_shows_only_my_project(dana, mod):
    """Another project's activity, and the pre-project entries that carry no
    stamp at all, must not appear. (dana's OWN rejected attempt to touch avc
    does appear, and should: it is her action, echoing back her own input, and
    an audit log that hides what you tried to do is not an audit log.)"""
    mod.audit.append("rob2", "owner", "action.demo_reset",
                     {"argv": ["demo", "reset", "avc"], "marker": "FOREIGN-PROJECT-ENTRY"},
                     True, project="personal")
    mod.audit.append("someone", "operator", "legacy.thing",
                     {"site": "cathnet", "marker": "LEGACY-UNSTAMPED-ENTRY"}, True)
    r = dana.get("/audit")
    assert r.status_code == 200
    assert "FOREIGN-PROJECT-ENTRY" not in r.text, "another project's audit entry leaked"
    assert "LEGACY-UNSTAMPED-ENTRY" not in r.text, "an unstamped legacy entry leaked"
    assert "rob2" not in r.text, "another project's actor leaked"

    # The owner, by contrast, still sees the whole log including both of those.
    o = _client(mod, "rob2").get("/audit")
    assert "FOREIGN-PROJECT-ENTRY" in o.text and "LEGACY-UNSTAMPED-ENTRY" in o.text


def test_quokka_context_is_built_from_scoped_state_only(dana, mod, monkeypatch):
    captured = {}

    def fake_stream(url, model, messages, timeout=None):
        captured["messages"] = messages
        yield "ok"

    monkeypatch.setattr(mod.quokka, "chat_stream", fake_stream)
    mod._qk_ctx_cache.clear()
    r = dana.post("/quokka/chat", data={"message": "how is the fleet?", "history": "[]"})
    assert r.status_code == 200
    r.read()
    blob = json.dumps(captured["messages"])
    assert_no_foreign(blob, "quokka chat context")
    assert "ssc" in blob, "the model was not told about the project's own sites"


def test_quokka_cache_is_per_scope(dana, owner, mod, monkeypatch):
    """One shared cache would hand the first caller's fleet to the next."""
    seen = []

    def fake_stream(url, model, messages, timeout=None):
        seen.append(json.dumps(messages))
        yield "ok"

    monkeypatch.setattr(mod.quokka, "chat_stream", fake_stream)
    mod._qk_ctx_cache.clear()
    dana.post("/quokka/chat", data={"message": "a", "history": "[]"}).read()
    owner.post("/quokka/chat", data={"message": "a", "history": "[]"}).read()
    assert len(seen) == 2
    assert_no_foreign(seen[0], "dana's quokka context")
    assert "avc" in seen[1], "the owner's context was served from dana's cache"


@pytest.mark.parametrize("path", ["/users", "/projects"])
def test_member_cannot_reach_admin_surfaces(dana, path):
    assert dana.get(path).status_code == 403


def test_member_cannot_edit_a_project_site_list(dana):
    """Editing the site list IS a permission grant — owner only, always."""
    r = dana.post("/projects/ss-nw/sites", data={"sites": "nwc ssc avc"})
    assert r.status_code == 403


def test_explicit_foreign_project_is_403_and_audited(dana, mod):
    r = dana.get("/panes/fleet?project=personal")
    assert r.status_code == 403
    tail = [json.loads(x) for x in Path(mod.config.DATA_DIR / "audit.jsonl").read_text().splitlines()[-5:]]
    assert any(e["action"] == "scope.denied" for e in tail), "the denial was not audited"


def test_user_with_no_membership_sees_nothing(nomad):
    """Authenticated, projects exist, member of none => the explainer page, and
    NOT an empty-looking dashboard that reads as 'the fleet is fine'."""
    r = nomad.get("/panes/fleet", headers={"accept": "text/html"}, follow_redirects=False)
    assert r.status_code == 303 and r.headers["location"] == "/no-project"

    landing = nomad.get("/no-project")
    assert landing.status_code == 200
    assert_no_foreign(landing.text, "/no-project")
    for mine in MINE:
        assert mine not in landing.text, f"the no-project page named {mine}"

    # htmx/JSON callers get a plain 403, not a redirect to an HTML page.
    assert nomad.get("/panes/fleet").status_code == 403
    assert nomad.get("/tabs/counts").status_code == 403
    # ...and every action is refused, including one that IS a console demo site.
    assert nomad.post("/actions/run", data={"action": "demo_reset", "site": "nwd"}).status_code == 403


def test_owner_still_sees_the_whole_fleet(owner):
    r = owner.get("/panes/fleet")
    assert r.status_code == 200
    for s in FOREIGN + MINE:
        assert s in r.text, f"owner lost sight of {s}"


# ---------------------------------------------------------------------------
# security advisories (merged from feat/console-security-advisories)
# ---------------------------------------------------------------------------
def test_security_advisories_are_scoped_on_the_fleet_pane(dana, owner, mod):
    """An advisory names a package, a version and a CVE for one site. A
    fleet-wide advisory list would tell a member exactly how many holes exist
    in sites they cannot see — the most sensitive per-site fact there is."""
    r = dana.get("/panes/fleet")
    assert r.status_code == 200
    assert "PKSA-MINE-1" in r.text, "my own advisory vanished"
    assert "PKSA-SECRET-9" not in r.text, "LEAK: a foreign advisory id reached a member"
    assert "SECRET-ADVISORY-TITLE" not in r.text
    assert "drupal/secretpkg" not in r.text

    sec = mod._gather_security(_scope_of(mod, "dana"))[0]
    assert [s["site"] for s in sec["sites"]] == ["ssc"]
    # The headline is RECOMPUTED: inheriting the published totals would print
    # the fleet-wide advisory count above a one-row table, telling a member how
    # big a problem is in sites they cannot see.
    assert sec["totals"]["advisories"] == 1, "advisory headline leaked fleet-wide totals"
    assert sec["totals"]["sites"] == 1

    # The owner still sees both.
    o = owner.get("/panes/fleet")
    assert "PKSA-MINE-1" in o.text and "PKSA-SECRET-9" in o.text
