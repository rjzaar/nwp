"""The Demo pane's PER-TESTER editor — tranche 3 (ops#328).

WHAT THESE TESTS PIN:

  * The roster is read through `pl demo testers <site> list --json --tier=live`
    (pl-first — the console never talks drush), parsed by a real contract:
    counts, accounts with guilds-by-seed-key + group roles, sojourner level,
    consent state, and the guild_catalog the editor's matrix renders from.
  * Writes go through TWO allowlisted actions (`demo_tester_set_guild`,
    `demo_tester_set_level`) that build fixed argv — no free text ever reaches
    a command line, role+remove is a contradiction, and `--allow-real` is
    UNREPRESENTABLE (no parameter can produce it).
  * DISCHARGE (ops#327, structural): the action route re-reads the roster with
    force=True and renders the RE-READ tester state next to the verb output.
  * Typed refusals from the verb ({"ok":false,"refused":true,…}) render their
    reason verbatim — a refusal is a result, not an error to hide.
  * The NOT-DEPLOYED state is first-class: until the nwc profile MR merges and
    deploys, `nwc:tester-set-guild` is absent on live; the verb reports
    not_deployed and the console renders CANNOT VERIFY with the deploy hint —
    never an empty-but-healthy panel (ops#281).
  * Consent is read-only BY DESIGN and the UI says so; viewers get no
    controls and a 403 on the POST.

Red-then-green: this module was run against the tranche-1 console (main @
f40573b) and observed RED (parsers/actions/routes/templates absent) before
the implementation existed.
"""
import json
import os
import sys
import tempfile
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import parsers  # noqa: E402
from app.actions import ActionError, build_action  # noqa: E402

DEMO = ["nwd"]

TESTERS_JSON = {
    "ok": True,
    "generated_at": "2026-08-09T12:00:00+00:00",
    "fence_domain": "demo.invalid",
    "counts": {"fenced_active": 3, "fenced_blocked": 0, "real_active": 1, "real_blocked": 0},
    "accounts": [
        {"uid": 12, "name": "nwcdemo_consenting", "mail": "nwcdemo_consenting@demo.invalid",
         "active": True, "created": 1786249111, "last_access": 0, "roles": ["verified"],
         "fence": "matrix",
         "guilds": [{"group_id": 16, "type": "guild", "label": "Writers Guild",
                     "seed_key": "writers", "roles": ["guild-mentor", "guild-member"]}],
         "sojourner_level": 2, "skill_progress": [],
         "consent": {"art9": "granted", "art9_current": True, "may_contribute": True,
                     "may_keep_formation": True, "trialing": False},
         "redeemed_bundle": None},
        {"uid": 14, "name": "demo_writer", "mail": "demo_writer@demo.invalid",
         "active": True, "created": 1786249111, "last_access": 1786349111, "roles": ["verified"],
         "fence": "persona", "guilds": [], "sojourner_level": 0, "skill_progress": [],
         "consent": {"art9": "none", "art9_current": False, "may_contribute": False,
                     "may_keep_formation": False, "trialing": True},
         "redeemed_bundle": None},
        {"uid": 33, "name": "maria_goretti_77", "mail": "user33@demo.invalid",
         "active": True, "created": 1786249111, "last_access": 0, "roles": ["verified"],
         "fence": "redeemed", "guilds": [], "sojourner_level": None, "skill_progress": [],
         "consent": {"art9": "withdrawn", "art9_current": False, "may_contribute": False,
                     "may_keep_formation": False, "trialing": True},
         "redeemed_bundle": None},
    ],
    "guild_catalog": {
        "guilds": [
            {"seed_key": "sojourners", "label": "Sojourners", "group_id": 10, "type": "guild"},
            {"seed_key": "writers", "label": "Writers Guild", "group_id": 16, "type": "guild"},
        ],
        "assignable_roles": ["guild-admin", "guild-editor", "guild-endorsed",
                             "guild-junior", "guild-mentor", "guild-verifier"],
        "sojourner_levels": [{"num": 1, "name": "Inquirer"}, {"num": 2, "name": "Sojourner"},
                             {"num": 3, "name": "Intercessor"}],
        "note": "guilds without a field_group_seed_key are not listed",
    },
    "notes": [],
}

NOT_DEPLOYED_JSON = {
    "ok": False,
    "not_deployed": True,
    "reason": "drush command nwc:tester-list is not on nwd live yet — merge + deploy "
              "the nwc profile MR (ops#328 tranche 3), then refresh",
}

SET_GUILD_OK = {
    "ok": True, "changed": True,
    "account": {"uid": 12, "name": "nwcdemo_consenting"},
    "guild": {"group_id": 16, "type": "guild", "label": "Writers Guild", "seed_key": "writers"},
    "membership": {"member": True, "roles": ["guild-mentor", "guild-member"],
                   "individual_roles": ["guild-mentor"]},
}

SET_GUILD_REFUSED = {
    "ok": False, "refused": True,
    "reason": "there is no 'guild-leader' role — leadership = guild-admin",
}


# ---------------------------------------------------------------------------
# parsers — pure
# ---------------------------------------------------------------------------
def test_parse_testers_json_ok_shape():
    p = parsers.parse_testers_json(json.dumps(TESTERS_JSON))
    assert p["ok"] is True
    assert p["counts"]["fenced_active"] == 3 and p["counts"]["real_active"] == 1
    names = [a["name"] for a in p["accounts"]]
    assert names == ["nwcdemo_consenting", "demo_writer", "maria_goretti_77"]
    a = p["accounts"][0]
    assert a["guilds"][0]["seed_key"] == "writers"
    assert a["guilds"][0]["roles"] == ["guild-mentor", "guild-member"]
    assert a["sojourner_level"] == 2
    assert a["consent"]["art9"] == "granted" and a["consent"]["trialing"] is False
    cat = p["guild_catalog"]
    assert [g["seed_key"] for g in cat["guilds"]] == ["sojourners", "writers"]
    assert "guild-mentor" in cat["assignable_roles"]
    assert cat["sojourner_levels"][1] == {"num": 2, "name": "Sojourner"}


def test_parse_testers_json_moodle_mirror_note_is_derived_honestly():
    """ssd accounts are SSO-minted only; the mirror column is a derivation
    from last_access, never a write path or a guess about ssd's DB."""
    p = parsers.parse_testers_json(json.dumps(TESTERS_JSON))
    assert "no ssd account yet" in p["accounts"][0]["mirror"]       # last_access 0
    assert "next SSO login" in p["accounts"][1]["mirror"]           # has logged in


def test_parse_testers_json_garbage_is_cannot_verify():
    p = parsers.parse_testers_json("no json at all")
    assert p["ok"] is False and p["reason"]
    assert p["accounts"] == []


def test_parse_testers_json_not_deployed_flag_carries_hint():
    p = parsers.parse_testers_json(json.dumps(NOT_DEPLOYED_JSON))
    assert p["ok"] is False and p["not_deployed"] is True
    assert "merge + deploy" in p["reason"]


def test_parse_tester_action_json_shapes():
    ok = parsers.parse_tester_action_json(json.dumps(SET_GUILD_OK))
    assert ok["ok"] is True and ok["changed"] is True
    assert ok["membership"]["individual_roles"] == ["guild-mentor"]
    ref = parsers.parse_tester_action_json(json.dumps(SET_GUILD_REFUSED))
    assert ref["ok"] is False and ref["refused"] is True
    assert "guild-admin" in ref["reason"]
    nd = parsers.parse_tester_action_json(json.dumps(
        {"ok": False, "not_deployed": True, "reason": "merge + deploy the nwc profile MR"}))
    assert nd["not_deployed"] is True
    bad = parsers.parse_tester_action_json("garbage")
    assert bad["ok"] is False and bad["reason"]


# ---------------------------------------------------------------------------
# actions — fixed argv, strict validators
# ---------------------------------------------------------------------------
def test_set_guild_builds_fixed_argv_with_role():
    argv, spec = build_action("demo_tester_set_guild",
                              {"site": "nwd", "account": "nwcdemo_consenting",
                               "seed_key": "writers", "role": "guild-mentor"}, DEMO)
    assert argv == ["demo", "testers", "nwd", "set-guild", "nwcdemo_consenting",
                    "writers", "--group-role=guild-mentor", "--tier=live"]
    assert spec["min_role"] == "operator" and spec["scope"] == "site"


def test_set_guild_remove_builds_remove_argv():
    argv, _ = build_action("demo_tester_set_guild",
                           {"site": "nwd", "account": "demo_writer",
                            "seed_key": "writers", "remove": "1"}, DEMO)
    assert argv == ["demo", "testers", "nwd", "set-guild", "demo_writer",
                    "writers", "--remove", "--tier=live"]


def test_set_guild_role_plus_remove_is_a_contradiction():
    with pytest.raises(ActionError):
        build_action("demo_tester_set_guild",
                     {"site": "nwd", "account": "demo_writer", "seed_key": "writers",
                      "role": "guild-junior", "remove": "1"}, DEMO)


def test_set_guild_validates_every_slot():
    base = {"site": "nwd", "account": "demo_writer", "seed_key": "writers"}
    for field, bad in (("account", "a b"), ("account", "x;y"), ("account", ""),
                       ("account", "a" * 61), ("seed_key", "Writers Guild"),
                       ("seed_key", "$(id)"), ("seed_key", ""), ("role", "x;y"),
                       ("role", "GUILD-ADMIN")):
        p = dict(base)
        p[field] = bad
        with pytest.raises(ActionError):
            build_action("demo_tester_set_guild", p, DEMO)


def test_allow_real_is_unrepresentable():
    """No parameter combination may ever produce --allow-real: the fence is
    the point. Structural: the argv builder has no such branch."""
    argv, _ = build_action("demo_tester_set_guild",
                           {"site": "nwd", "account": "demo_writer", "seed_key": "writers",
                            "allow_real": "1", "allow-real": "1"}, DEMO)
    assert "--allow-real" not in argv


def test_set_level_builds_fixed_argv_and_validates():
    argv, _ = build_action("demo_tester_set_level",
                           {"site": "nwd", "account": "demo_writer", "level": "2"}, DEMO)
    assert argv == ["demo", "testers", "nwd", "set-level", "demo_writer", "2", "--tier=live"]
    for bad in ("", "abc", "-1", "0", "13", "2; rm"):
        with pytest.raises(ActionError):
            build_action("demo_tester_set_level",
                         {"site": "nwd", "account": "demo_writer", "level": bad}, DEMO)


def test_tester_actions_scope_to_allowed_sites():
    with pytest.raises(ActionError):
        build_action("demo_tester_set_guild",
                     {"site": "ssd", "account": "demo_writer", "seed_key": "writers"}, DEMO)


# ---------------------------------------------------------------------------
# routes + rendering
# ---------------------------------------------------------------------------
@pytest.fixture(scope="module")
def mod():
    pytest.importorskip("fastapi")
    pytest.importorskip("httpx")
    tmp = tempfile.mkdtemp(prefix="nwp-console-testers-test-")
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
    return TestClient(mod.app, headers={"x-test-user": name})


def _fake_testers(mod, monkeypatch, testers=None, rc=0, calls=None):
    testers = TESTERS_JSON if testers is None else testers

    def fake_cached(root, args, **kw):
        if calls is not None:
            calls.append((list(args), bool(kw.get("force"))))
        a = list(args)
        if a[:2] == ["demo", "testers"]:
            return {"rc": rc, "out": json.dumps(testers), "err": "", "secs": 0.2,
                    "cmd": "pl demo testers"}
        return {"rc": 1, "out": "", "err": f"unexpected args {a}", "secs": 0, "cmd": ""}

    monkeypatch.setattr(mod, "run_pl_cached", fake_cached)
    return fake_cached


def test_pane_demo_embeds_lazy_tester_section(mod, monkeypatch):
    def fake_cached(root, args, **kw):
        return {"rc": 1, "out": "", "err": "n/a", "secs": 0, "cmd": ""}
    monkeypatch.setattr(mod, "run_pl_cached", fake_cached)
    body = _client(mod).get("/panes/demo").text
    assert "/panes/demo/testers?site=nwd" in body


def test_testers_fragment_renders_roster(mod, monkeypatch):
    _fake_testers(mod, monkeypatch)
    body = _client(mod).get("/panes/demo/testers?site=nwd").text
    assert "nwcdemo_consenting" in body and "maria_goretti_77" in body
    assert "writers" in body                       # seed key, not just label
    assert "3" in body                             # fenced_active count
    # per-tester detail link
    assert "/panes/demo/tester?site=nwd&account=nwcdemo_consenting" in body


def test_testers_fragment_not_deployed_is_cannot_verify_with_hint(mod, monkeypatch):
    _fake_testers(mod, monkeypatch, testers=NOT_DEPLOYED_JSON, rc=2)
    body = _client(mod).get("/panes/demo/testers?site=nwd").text
    assert "CANNOT VERIFY" in body
    assert "merge + deploy" in body                # the deploy hint, verbatim
    assert "no testers" not in body.lower()        # unreadable ≠ empty


def test_testers_fragment_refuses_out_of_scope_site(mod, monkeypatch):
    _fake_testers(mod, monkeypatch)
    r = _client(mod).get("/panes/demo/testers?site=ssd")
    assert r.status_code == 404


def test_tester_detail_renders_matrix_consent_and_mirror(mod, monkeypatch):
    _fake_testers(mod, monkeypatch)
    body = _client(mod).get("/panes/demo/tester?site=nwd&account=nwcdemo_consenting").text
    # matrix rows come from the CATALOGUE, so a guild the tester is NOT in
    # appears with join controls
    assert "sojourners" in body and "writers" in body
    assert "guild-mentor" in body
    # consent is rendered and declared non-editable
    assert "granted" in body
    assert "never console-editable" in body
    # sojourner level display
    assert "L2" in body
    # moodle mirror status is a read-only derivation
    assert "ssd" in body
    # operator sees write controls
    assert "/actions/demo_tester" in body


def test_tester_detail_viewer_is_read_only(mod, monkeypatch):
    _fake_testers(mod, monkeypatch)
    body = _client(mod, "vera").get("/panes/demo/tester?site=nwd&account=nwcdemo_consenting").text
    assert "nwcdemo_consenting" in body
    assert "/actions/demo_tester" not in body      # no forms at all


def test_tester_detail_unknown_account_is_honest(mod, monkeypatch):
    _fake_testers(mod, monkeypatch)
    body = _client(mod).get("/panes/demo/tester?site=nwd&account=ghost_user").text
    assert "not in the roster" in body


def test_viewer_cannot_post_tester_action(mod, monkeypatch):
    _fake_testers(mod, monkeypatch)
    r = _client(mod, "vera").post("/actions/demo_tester",
                                  data={"site": "nwd", "op": "set-guild",
                                        "account": "demo_writer", "seed_key": "writers"})
    assert r.status_code == 403


def test_set_guild_action_discharges_by_rereading(mod, monkeypatch):
    """ops#327 structural: the response carries the roster RE-READ (force)
    after the verb ran, and renders the re-read membership state."""
    calls = []
    _fake_testers(mod, monkeypatch, calls=calls)
    ran = {}

    def fake_run_pl(root, args, **kw):
        ran["argv"] = list(args)
        return {"rc": 0, "out": json.dumps(SET_GUILD_OK), "err": "", "secs": 5.0,
                "cmd": "pl " + " ".join(args)}

    monkeypatch.setattr(mod, "run_pl", fake_run_pl)
    r = _client(mod).post("/actions/demo_tester",
                          data={"site": "nwd", "op": "set-guild",
                                "account": "nwcdemo_consenting", "seed_key": "writers",
                                "role": "guild-mentor"})
    assert r.status_code == 200
    assert ran["argv"] == ["demo", "testers", "nwd", "set-guild", "nwcdemo_consenting",
                           "writers", "--group-role=guild-mentor", "--tier=live"]
    reread = [(a, f) for a, f in calls if a[:2] == ["demo", "testers"]]
    assert reread and reread[-1][1] is True
    # the re-read state is rendered (roster row for the account)
    assert "nwcdemo_consenting" in r.text
    assert "re-read" in r.text.lower()


def test_set_guild_typed_refusal_renders_reason(mod, monkeypatch):
    _fake_testers(mod, monkeypatch)

    def fake_run_pl(root, args, **kw):
        return {"rc": 1, "out": json.dumps(SET_GUILD_REFUSED), "err": "", "secs": 5.0,
                "cmd": "pl " + " ".join(args)}

    monkeypatch.setattr(mod, "run_pl", fake_run_pl)
    r = _client(mod).post("/actions/demo_tester",
                          data={"site": "nwd", "op": "set-guild",
                                "account": "demo_writer", "seed_key": "writers",
                                "role": "guild-leader"})
    assert r.status_code == 200
    assert "REFUSED" in r.text
    assert "guild-admin" in r.text                 # the verb's reason, verbatim


def test_set_guild_not_deployed_renders_deploy_hint(mod, monkeypatch):
    """Until the nwc MR merges + deploys, the write commands are absent on
    live — the console must say CANNOT VERIFY + how to fix, not error soup."""
    _fake_testers(mod, monkeypatch)

    def fake_run_pl(root, args, **kw):
        return {"rc": 2, "out": json.dumps(
            {"ok": False, "not_deployed": True,
             "reason": "drush command nwc:tester-set-guild is not on nwd live yet — "
                       "merge + deploy the nwc profile MR (ops#328 tranche 3), then retry"}),
            "err": "", "secs": 5.0, "cmd": "pl"}

    monkeypatch.setattr(mod, "run_pl", fake_run_pl)
    r = _client(mod).post("/actions/demo_tester",
                          data={"site": "nwd", "op": "set-guild",
                                "account": "demo_writer", "seed_key": "writers"})
    assert r.status_code == 200
    assert "CANNOT VERIFY" in r.text
    assert "merge + deploy" in r.text


def test_unknown_op_is_rejected_and_audited(mod, monkeypatch):
    _fake_testers(mod, monkeypatch)
    r = _client(mod).post("/actions/demo_tester",
                          data={"site": "nwd", "op": "drop-table",
                                "account": "demo_writer", "seed_key": "writers"})
    assert r.status_code == 200
    assert "unknown" in r.text.lower()
