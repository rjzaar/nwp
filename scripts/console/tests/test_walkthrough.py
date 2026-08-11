"""ops#328 t5 — the Walkthrough subtab: parser, view builder, routes, template.

WHAT THIS SUBTAB IS
-------------------
One click from the console into any part of the demo pair, already signed in as
an all-permissions walkthrough account. The operator asked for auto-login on
render; this is deliberately NOT that, and these tests pin the difference:

  * THE CREDENTIAL IS MINTED ON CLICK, NEVER ON RENDER. Minting on render would
    burn a one-time token every time a poller repainted the pane, flood the
    demo log, and place a live credential in a page nobody asked to use. So the
    rendered pane contains NO link, and every jump is a POST that mints and
    303s. `test_the_pane_never_carries_a_credential` is the guard.

  * THE DESTINATION IS AN ALLOWLIST, NOT A PARAMETER. `dest` must be one of the
    verb's own target paths for that site. Anything else is refused before a
    credential exists — an operator-facing redirector that takes free text is an
    open redirect wearing a lab coat.

  * A TARGET NOBODY MEASURED RENDERS AS UNKNOWN. Not as a live link, not as a
    broken one.

  * THE ALL-PERMISSIONS CAVEAT IS RENDERED, NOT ASSUMED. This account cannot see
    what a member sees: a link that 403s for a member, a gate that should block,
    a tool that should be hidden all look fine to it. The pane must say so and
    point at the per-tester editor, which answers the other question.
"""
import importlib
import sys
from pathlib import Path

import pytest

APP = Path(__file__).resolve().parent.parent / "app"
TPL = Path(__file__).resolve().parent.parent / "templates"
sys.path.insert(0, str(APP.parent))

from app import parsers, walkthrough  # noqa: E402


# --------------------------------------------------------------------------
# fixtures
# --------------------------------------------------------------------------
def _doc(**over):
    d = {
        "ok": True,
        "site": "nwd",
        "tier": "live",
        "phase": "dev",
        "jump_in_allowed": True,
        "provider": {"site": "nwd", "base": "https://provider.example"},
        "consumer": {"site": "ssd", "base": "https://consumer.example"},
        "account": {"present": True, "name": "nwcdemo_walkthrough", "uid": 33,
                    "admin": True, "guilds": 16, "roles": ["verified", "administrator"],
                    "sojourner_level": 0, "fenced": True, "active": True,
                    "guild_roles": [{"label": "Media Guild", "roles": ["guild-admin"]}]},
        "groups": {"source": "catalog", "count": 16, "groups": [], "note": "n"},
        "session": {"provider": {"signout": {"label": "Sign out", "path": "/user/logout/confirm"}},
                    "consumer": {"signout": {"label": "Sign out", "path": "/login/logout.php"}}},
        "dropped": [],
        "counts": {"total": 3, "verified": 2, "missing": 0, "drifted": 0,
                   "ambiguous": 0, "unknown": 1, "cannot_verify": 0, "dropped": 0},
        "verification": {"state": "measured", "at": "2026-08-11T00:00:00Z",
                         "age_seconds": 120, "source": "this host"},
        "targets": [
            {"id": "provider.entry.stream", "side": "provider", "section": "entry",
             "section_label": "Entry points", "group": None, "group_seed_key": None,
             "key": "stream", "label": "Stream", "path": "/stream",
             "path_template": "/stream", "route": "social_core.homepage",
             "kind": "route", "admin_only": False, "note": None,
             "verify": {"state": "verified", "detail": "router", "at": "x"}},
            {"id": "provider.guilds.media.dashboard", "side": "provider", "section": "guilds",
             "section_label": "Guilds & interest groups", "group": "Media Guild",
             "group_seed_key": "media", "key": "dashboard", "label": "Guild dashboard",
             "path": "/group/10/guild-dashboard", "path_template": "/group/{gid}/guild-dashboard",
             "route": "nwc_guild.dashboard", "kind": "route", "admin_only": False, "note": None,
             "verify": {"state": "unknown", "detail": "not measured", "at": None}},
            {"id": "consumer.entry.courses", "side": "consumer", "section": "entry",
             "section_label": "Entry points", "group": None, "group_seed_key": None,
             "key": "courses", "label": "All courses", "path": "/course/index.php",
             "path_template": "/course/index.php", "route": None, "kind": "route",
             "admin_only": False, "note": None,
             "verify": {"state": "verified", "detail": "HTTP 200", "at": "x"}},
        ],
    }
    d.update(over)
    return d


def _json(doc):
    import json
    return json.dumps(doc)


# --------------------------------------------------------------------------
# 1. parser
# --------------------------------------------------------------------------
def test_parser_reads_the_verbs_document():
    p = parsers.parse_walkthrough_json(_json(_doc()))
    assert p["ok"] is True
    assert p["account"]["present"] is True and p["account"]["admin"] is True
    assert len(p["targets"]) == 3
    assert p["counts"]["unknown"] == 1


def test_parser_never_invents_a_verdict():
    """An unrecognised verify.state must not become 'verified' — nor an empty
    string that a template renders as a bare link."""
    doc = _doc()
    doc["targets"][0]["verify"] = {"state": "banana", "detail": "", "at": None}
    p = parsers.parse_walkthrough_json(_json(doc))
    assert p["targets"][0]["verify"]["state"] == "unknown"


def test_parser_refuses_to_read_an_absolute_path_as_a_target():
    """The catalogue is hostname-free by rule; a path that is not site-relative
    would build a link to somewhere else entirely, so it is dropped here too."""
    doc = _doc()
    doc["targets"][0]["path"] = "https://evil.example/x"
    p = parsers.parse_walkthrough_json(_json(doc))
    assert [t["path"] for t in p["targets"]] == ["/group/10/guild-dashboard", "/course/index.php"]


def test_unreadable_output_is_cannot_verify_not_an_empty_walkthrough():
    p = parsers.parse_walkthrough_json("boom: something went wrong\n")
    assert p["ok"] is False
    assert p["targets"] == []
    assert "no JSON" in p["reason"] or "CANNOT VERIFY" in p["reason"]


def test_a_refusal_document_keeps_its_reason():
    p = parsers.parse_walkthrough_json(
        '{"ok": false, "reason": "CANNOT VERIFY: the roster read failed"}')
    assert p["ok"] is False and "roster read failed" in p["reason"]


# --------------------------------------------------------------------------
# 2. the view builder
# --------------------------------------------------------------------------
def test_columns_are_grouped_by_side_and_keep_section_order():
    v = walkthrough.page_view(parsers.parse_walkthrough_json(_json(_doc())))
    assert [c["side"] for c in v["columns"]] == ["provider", "consumer"]
    prov = v["columns"][0]
    assert prov["site"] == "nwd"
    assert [s["key"] for s in prov["sections"]] == ["entry", "guilds"]


def test_guild_targets_are_folded_into_one_block_per_guild():
    v = walkthrough.page_view(parsers.parse_walkthrough_json(_json(_doc())))
    guilds = [s for s in v["columns"][0]["sections"] if s["key"] == "guilds"][0]
    assert [g["group"] for g in guilds["groups"]] == ["Media Guild"]
    assert guilds["groups"][0]["targets"][0]["label"] == "Guild dashboard"


def test_the_all_permissions_caveat_is_part_of_the_view_not_the_template():
    """It is a property of the account, so it travels with the data — a caveat
    that lives only in markup is one edit away from being dropped."""
    v = walkthrough.page_view(parsers.parse_walkthrough_json(_json(_doc())))
    assert v["caveat"]
    assert "member" in v["caveat"].lower()


def test_a_missing_account_disables_every_jump_and_says_why():
    doc = _doc()
    doc["account"] = {"present": False, "name": "nwcdemo_walkthrough", "uid": None,
                      "admin": False, "guilds": 0, "roles": [],
                      "reason": "seeded by drush nwc:seed-demo"}
    v = walkthrough.page_view(parsers.parse_walkthrough_json(_json(doc)))
    assert v["can_jump"] is False
    assert "nwc:seed-demo" in v["blocked_reason"]


def test_prod_phase_disables_every_jump():
    v = walkthrough.page_view(parsers.parse_walkthrough_json(
        _json(_doc(phase="prod", jump_in_allowed=False))))
    assert v["can_jump"] is False
    assert "prod" in v["blocked_reason"]


def test_never_measured_is_shouted_not_implied():
    doc = _doc(verification={"state": "never", "at": None, "age_seconds": None,
                             "source": None, "note": "n"})
    v = walkthrough.page_view(parsers.parse_walkthrough_json(_json(doc)))
    assert v["verification"]["state"] == "never"
    assert v["verification"]["warn"] is True


def test_an_unreadable_document_yields_an_explicit_nodata_state():
    v = walkthrough.page_view(parsers.parse_walkthrough_json("garbage"))
    assert v["ok"] is False
    assert v["columns"] == []
    assert v["reason"]


# --------------------------------------------------------------------------
# 3. destination allowlisting (this is the security-relevant one)
# --------------------------------------------------------------------------
@pytest.mark.parametrize("bad", [
    "https://evil.example/x", "//evil.example/x", "/stream\r\nSet-Cookie: a=b",
    "stream", "", "/../etc/passwd", "/stream?destination=//evil.example",
])
def test_a_destination_off_the_allowlist_is_refused(bad):
    doc = parsers.parse_walkthrough_json(_json(_doc()))
    with pytest.raises(walkthrough.DestinationError):
        walkthrough.resolve_destination(doc, "provider", bad)


def test_only_a_declared_target_path_is_accepted():
    doc = parsers.parse_walkthrough_json(_json(_doc()))
    assert walkthrough.resolve_destination(doc, "provider", "/stream") == "/stream"
    # a real path, but on the OTHER half — the sides do not share an allowlist
    with pytest.raises(walkthrough.DestinationError):
        walkthrough.resolve_destination(doc, "provider", "/course/index.php")


def test_the_signout_chain_nests_the_destination_inside_the_one_time_path():
    url = walkthrough.signout_then(
        "https://provider.example", "/user/logout/confirm",
        "https://provider.example/user/reset/33/1/abc/login", "/group/10/guild-dashboard")
    assert url.startswith("https://provider.example/user/logout/confirm?destination=")
    assert "%2Fuser%2Freset%2F33%2F1%2Fabc%2Flogin" in url
    assert "evil" not in url
    # the credential is nested exactly ONCE and its HOST is not nested at all:
    # Drupal refuses an external `destination`, and a doubled host would also
    # put the one-time link in the outer query string twice.
    assert url.count("%2Fuser%2Freset%2F") == 1
    assert "/user/reset/" not in url.split("?", 1)[0]
    assert "https%3A%2F%2F" not in url


def test_the_jump_url_carries_the_destination_and_nothing_else():
    url = walkthrough.jump_url("https://provider.example/user/reset/33/1/abc/login",
                               "/group/10/guild-dashboard")
    assert url == ("https://provider.example/user/reset/33/1/abc/login"
                   "?destination=%2Fgroup%2F10%2Fguild-dashboard")


# --------------------------------------------------------------------------
# 4. the subtab is wired into Visuals
# --------------------------------------------------------------------------
def test_walkthrough_is_a_visuals_subtab():
    from app import visuals
    assert "walkthrough" in visuals.SUBTABS
    assert visuals.norm_subtab("walkthrough") == "walkthrough"


def test_an_unknown_subtab_still_falls_back_and_is_never_reflected():
    from app import visuals
    assert visuals.norm_subtab("<script>") == visuals.DEFAULT_SUBTAB


# --------------------------------------------------------------------------
# 5. template
# --------------------------------------------------------------------------
def _render(doc=None, can_act=True):
    jinja2 = pytest.importorskip("jinja2")
    from app import visuals
    env = jinja2.Environment(loader=jinja2.FileSystemLoader(str(TPL)), autoescape=True)
    ctx = visuals.page_context(None, None, None, [], False,
                               {"stale": False}, sub="walkthrough")
    ctx["vz"]["walkthrough"] = walkthrough.page_view(
        parsers.parse_walkthrough_json(_json(doc if doc else _doc())))
    ctx.update(user={"name": "rob", "role": "owner"}, can_act=can_act, scope=None,
               tab="visuals", tab_count="", tab_alert=False)
    return env.get_template("pane_visuals.html").render(**ctx)


def test_the_pane_renders_both_halves_with_their_labels():
    out = _render()
    assert "Stream" in out and "All courses" in out and "Media Guild" in out


def test_the_pane_never_carries_a_credential():
    """Nothing here is a link to a site: every jump is a POST that mints at
    click time. A rendered one-time link is the failure this design exists to
    avoid."""
    out = _render()
    assert "/user/reset/" not in out
    assert 'href="https://provider.example/stream"' not in out


def test_each_jump_is_a_post_to_the_allowlisted_action():
    out = _render()
    assert out.count('action="/actions/walkthrough_go"') >= 1
    assert 'name="dest"' in out


def test_an_unknown_target_is_marked_unknown_in_the_rendered_page():
    out = _render()
    assert "unknown" in out.lower()


def test_a_viewer_gets_no_jump_buttons():
    out = _render(can_act=False)
    assert "/actions/walkthrough_go" not in out


def test_the_caveat_and_the_other_view_are_both_offered():
    out = _render()
    assert "member" in out.lower()
    assert "Demo" in out          # the pointer at the per-tester editor


def test_the_signout_control_is_present_for_both_halves():
    out = _render()
    assert "/user/logout/confirm" in out
    assert "/login/logout.php" in out


def test_the_chart_subtabs_are_still_form_free():
    """The walkthrough subtab is the ONLY part of Visuals that acts. That was
    a documented property of the whole pane; narrowing it must be deliberate
    and must not silently spread."""
    jinja2 = pytest.importorskip("jinja2")
    from app import visuals
    env = jinja2.Environment(loader=jinja2.FileSystemLoader(str(TPL)), autoescape=True)
    for sub in ("fleet", "security", "todo", "ci"):
        ctx = visuals.page_context({"ok": False}, {"ok": False}, {"ok": False}, [], False,
                                   {"stale": False}, sub=sub)
        ctx.update(user={"name": "rob", "role": "owner"}, can_act=True, scope=None,
                   tab="visuals", tab_count="", tab_alert=False)
        out = env.get_template("pane_visuals.html").render(**ctx)
        assert "<form" not in out and "hx-post" not in out, f"{sub} grew an action"


# --------------------------------------------------------------------------
# 6. the ROUTES — where the credential actually travels
# --------------------------------------------------------------------------
import json          # noqa: E402
import os            # noqa: E402
import tempfile      # noqa: E402

DOC = _doc()
LOGIN_OK = {"ok": True, "account": "nwcdemo_walkthrough", "uid": 33, "site": "nwd",
            "uri": "https://provider.example",
            "url": "https://provider.example/user/reset/33/1786/abcdef/login",
            "shown_once": True, "note": "one-time"}


@pytest.fixture(scope="module")
def mod():
    pytest.importorskip("fastapi")
    pytest.importorskip("httpx")
    tmp = tempfile.mkdtemp(prefix="nwp-console-walkthrough-test-")
    os.environ["NWP_CONSOLE_DATA"] = tmp
    os.environ["NWP_CONSOLE_ROOT"] = tmp
    os.environ["NWP_CONSOLE_QUOKKA_URL"] = "http://127.0.0.1:9"
    os.environ["NWP_CONSOLE_STT_BACKEND"] = "off"
    os.environ["NWP_CONSOLE_TTS_BACKEND"] = "off"
    os.environ["NWP_CONSOLE_DEMO_SITES"] = "nwd"
    for m in list(sys.modules):
        if m == "app" or m.startswith("app."):
            del sys.modules[m]
    from app import main as app_main

    app_main.store.add_user("rob", "owner")
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
    return TestClient(mod.app, headers={"x-test-user": name}, follow_redirects=False)


def _wire(mod, monkeypatch, doc=None, login=None, calls=None):
    doc = DOC if doc is None else doc

    def fake_cached(root, args, **kw):
        if list(args)[:2] == ["demo", "walkthrough"]:
            return {"rc": 0, "out": json.dumps(doc), "err": "", "secs": 0.2, "cmd": "pl"}
        return {"rc": 1, "out": "", "err": "n/a", "secs": 0, "cmd": ""}

    def fake_run(root, args, **kw):
        if calls is not None:
            calls.append(list(args))
        return {"rc": 0, "out": json.dumps(LOGIN_OK if login is None else login),
                "err": "", "secs": 0.4, "cmd": "pl"}

    monkeypatch.setattr(mod, "run_pl_cached", fake_cached)
    monkeypatch.setattr(mod, "run_pl", fake_run)


def _post(mod, **data):
    return _client(mod).post("/actions/walkthrough_go", data=data,
                             headers={"Origin": mod.config.ORIGIN,
                                      "Sec-Fetch-Site": "same-origin",
                                      "x-test-user": "rob"})


def test_the_pane_route_renders_the_walkthrough_subtab(mod, monkeypatch):
    _wire(mod, monkeypatch)
    body = _client(mod).get("/panes/visuals?sub=walkthrough").text
    assert "Walkthrough" in body and "Media Guild" in body
    assert "/user/reset/" not in body


def test_a_good_jump_303s_onto_the_target_carrying_the_destination(mod, monkeypatch):
    calls = []
    _wire(mod, monkeypatch, calls=calls)
    r = _post(mod, site="nwd", side="provider", dest="/stream")
    assert r.status_code == 303
    assert r.headers["location"] == (
        "https://provider.example/user/reset/33/1786/abcdef/login"
        "?destination=%2Fstream")
    # the mint is UNCACHED and its argv is the fixed allowlisted one
    assert calls == [["demo", "testers", "nwd", "login", "nwcdemo_walkthrough",
                      "--tier=live", "--json"]]


def test_the_signout_variant_chains_through_the_sites_own_confirm_page(mod, monkeypatch):
    _wire(mod, monkeypatch)
    r = _post(mod, site="nwd", side="provider", dest="/stream", signout="1")
    assert r.status_code == 303
    loc = r.headers["location"]
    assert loc.startswith("https://provider.example/user/logout/confirm?destination=")
    assert "%2Fuser%2Freset%2F33%2F1786%2Fabcdef%2Flogin" in loc


@pytest.mark.parametrize("bad", [
    "https://evil.example/x",       # caught by shape
    "/admin/nwc/feedback",          # a REAL path — caught ONLY by the allowlist
    "/course/index.php",            # real, but on the other half
])
def test_a_destination_off_the_allowlist_mints_NOTHING(mod, monkeypatch, bad):
    """The second case is the one that matters: a perfectly well-formed,
    genuinely-existing site path that this side's catalogue did not declare.
    Only the allowlist can refuse it, so only this case proves the allowlist is
    reached from the route at all."""
    calls = []
    _wire(mod, monkeypatch, calls=calls)
    r = _post(mod, site="nwd", side="provider", dest=bad)
    assert r.status_code == 200                    # rendered refusal, not a redirect
    assert "Nothing was opened" in r.text
    assert calls == [], "a credential was minted for a destination we refused"


def test_a_prod_phase_site_mints_NOTHING(mod, monkeypatch):
    calls = []
    _wire(mod, monkeypatch, doc=_doc(phase="prod", jump_in_allowed=False), calls=calls)
    r = _post(mod, site="nwd", side="provider", dest="/stream")
    assert r.status_code == 200 and "prod" in r.text
    assert calls == []


def test_an_unreadable_walkthrough_mints_NOTHING(mod, monkeypatch):
    calls = []

    def fake_cached(root, args, **kw):
        return {"rc": 2, "out": '{"ok": false, "reason": "CANNOT VERIFY"}', "err": "",
                "secs": 0, "cmd": "pl"}

    monkeypatch.setattr(mod, "run_pl_cached", fake_cached)
    monkeypatch.setattr(mod, "run_pl",
                        lambda *a, **k: calls.append(a) or {"rc": 0, "out": "", "err": "",
                                                            "secs": 0, "cmd": ""})
    r = _post(mod, site="nwd", side="provider", dest="/stream")
    assert r.status_code == 200 and "refusing to mint" in r.text
    assert calls == []


def test_a_failed_mint_is_a_refusal_page_not_a_redirect_to_nowhere(mod, monkeypatch):
    _wire(mod, monkeypatch,
          login={"ok": False, "refused": True,
                 "reason": "uid 1 is never eligible"})
    r = _post(mod, site="nwd", side="provider", dest="/stream")
    assert r.status_code == 200
    assert "uid 1 is never eligible" in r.text


def test_the_consumer_half_is_sent_to_its_own_login_and_mints_nothing(mod, monkeypatch):
    """ssd accounts are SSO-minted, so there is no link to mint there. Sending
    the operator to the Moodle page (which redirects to its own login with the
    SSO button) is the honest one; faking a session is not on offer."""
    calls = []
    _wire(mod, monkeypatch, calls=calls)
    r = _post(mod, site="nwd", side="consumer", dest="/course/index.php")
    assert r.status_code == 303
    assert r.headers["location"] == "https://consumer.example/course/index.php"
    assert calls == []


def test_a_viewer_cannot_jump(mod, monkeypatch):
    _wire(mod, monkeypatch)
    r = _client(mod, name="vera").post(
        "/actions/walkthrough_go", data={"site": "nwd", "side": "provider", "dest": "/stream"},
        headers={"Origin": mod.config.ORIGIN, "Sec-Fetch-Site": "same-origin",
                 "x-test-user": "vera"})
    assert r.status_code == 403


def test_a_cross_origin_post_is_refused(mod, monkeypatch):
    _wire(mod, monkeypatch)
    r = _client(mod).post("/actions/walkthrough_go",
                          data={"site": "nwd", "side": "provider", "dest": "/stream"},
                          headers={"Origin": "https://evil.example",
                                   "Sec-Fetch-Site": "cross-site",
                                   "x-test-user": "rob"})
    assert r.status_code == 403


def test_a_site_outside_the_callers_scope_mints_nothing(mod, monkeypatch):
    calls = []
    _wire(mod, monkeypatch, calls=calls)
    r = _post(mod, site="ssc", side="provider", dest="/stream")
    assert r.status_code == 200 and "refusing to mint" in r.text
    assert calls == []


def test_the_audit_line_never_carries_the_credential(mod, monkeypatch):
    _wire(mod, monkeypatch)
    _post(mod, site="nwd", side="provider", dest="/stream")
    rows = mod.audit.tail(20)
    hits = [r for r in rows if r.get("action") == "action.walkthrough_go"]
    assert hits, "the jump was not audited at all"
    blob = json.dumps(hits)
    assert "/user/reset/" not in blob
    assert "abcdef" not in blob
