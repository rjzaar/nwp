import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.actions import ACTIONS, ActionError, FORBIDDEN_VERBS, build_action  # noqa: E402

DEMO = ["nwd"]


def test_unknown_action_rejected():
    with pytest.raises(ActionError):
        build_action("stg2live", {}, DEMO)
    with pytest.raises(ActionError):
        build_action("", {}, DEMO)
    with pytest.raises(ActionError):
        build_action("rag_refresh; rm -rf /", {}, DEMO)


def test_rag_refresh():
    # build_action now returns the whole spec, not just min_role: the route
    # needs BOTH role axes plus the site/global scope flag to gate on.
    argv, spec = build_action("rag_refresh", {}, DEMO)
    assert argv == ["rag", "--no-todo"]
    assert spec["min_role"] == "operator"
    assert spec["scope"] == "global", "a fleet-wide sweep must be marked global"


def test_demo_reset_keeps_idle_guard():
    argv, _ = build_action("demo_reset", {"site": "nwd"}, DEMO)
    assert "--if-idle" in argv and "30m" in argv
    assert argv[:3] == ["demo", "reset", "nwd"]


def test_demo_reset_rejects_non_demo_site():
    for bad in ("nwc", "avc", "prod", "../etc", "nwd; reboot", "NWD", "a" * 40, ""):
        with pytest.raises(ActionError):
            build_action("demo_reset", {"site": bad}, DEMO)


def test_code_issue_bundle_allowlist():
    argv, _ = build_action("demo_code_issue", {"site": "nwd", "bundle": "tester-member"}, DEMO)
    assert argv == ["demo", "codes", "nwd", "issue", "tester-member", "--expires=14d", "--tier=live"]
    for bad in ("sitemanager", "tester-sitemanager", "admin", "", "tester-member --force"):
        with pytest.raises(ActionError):
            build_action("demo_code_issue", {"site": "nwd", "bundle": bad}, DEMO)


def test_code_revoke_id_validation():
    argv, _ = build_action("demo_code_revoke", {"site": "nwd", "code_id": "abc123_X-"}, DEMO)
    assert argv[-2] == "abc123_X-" and argv[-1] == "--tier=live"
    for bad in ("", "a b", "x;y", "$(id)", "a" * 41, "café"):
        with pytest.raises(ActionError):
            build_action("demo_code_revoke", {"site": "nwd", "code_id": bad}, DEMO)


def test_no_live_prod_verbs_in_map():
    """The load-bearing property: no action can reach the live/prod tier."""
    for name, spec in ACTIONS.items():
        argv = None
        for params in (
            {},
            {"site": "nwd"},
            {"site": "nwd", "bundle": "tester-member"},
            {"site": "nwd", "code_id": "x1"},
            # ops#328 t3 — the per-tester editor's two writes
            {"site": "nwd", "account": "demo_writer", "seed_key": "writers"},
            {"site": "nwd", "account": "demo_writer", "level": "2"},
            # the join queue — approve/reject take a request id, and add takes
            # the operator-typed name and bundle
            {"site": "nwd", "request_id": "r-a1b2c3d4e5f6"},
            {"site": "nwd", "account": "demo_writer", "display_name": "Rob Zaar",
             "bundle": "tester-member"},
        ):
            try:
                argv, _ = build_action(name, params, DEMO)
                break
            except ActionError:
                continue
        assert argv is not None, f"no valid params found for {name}"
        assert argv[0] not in FORBIDDEN_VERBS
        joined = " ".join(argv)
        for verb in ("stg2live", "live2prod", "stg2prod", "deploy-gate", "server-apply", "rollback", "restore"):
            assert verb not in joined


def test_every_action_requires_at_least_operator():
    for spec in ACTIONS.values():
        assert spec["min_role"] in ("operator", "owner")


def test_metacharacter_guard_is_backstop():
    # Even a hypothetical future param that slipped a validator is caught.
    from app import actions as A

    A.ACTIONS["_tmp_bad"] = {"min_role": "operator", "label": "x", "build": lambda p, ds: ["rag", "a;b"]}
    try:
        with pytest.raises(ActionError):
            build_action("_tmp_bad", {}, DEMO)
    finally:
        del A.ACTIONS["_tmp_bad"]


def test_demo_invite_action():
    argv, spec = build_action("demo_invite", {"site": "nwd"}, DEMO)
    assert argv == ["demo", "invite", "nwd", "--tier=live"]
    assert spec["min_role"] == "operator"
    argv, _ = build_action("demo_invite", {"site": "nwd", "all": "1"}, DEMO)
    assert argv == ["demo", "invite", "nwd", "--tier=live", "--all"]
    argv, _ = build_action("demo_invite", {"site": "nwd", "all": ""}, DEMO)
    assert argv == ["demo", "invite", "nwd", "--tier=live"]


def test_demo_invite_strict_validation():
    for bad_site in ("nwc", "", "nwd; rm -rf", "../nwd", "NWD"):
        with pytest.raises(ActionError):
            build_action("demo_invite", {"site": bad_site}, DEMO)
    for bad_flag in ("yes", "--force", "1;2", "maybe"):
        with pytest.raises(ActionError):
            build_action("demo_invite", {"site": "nwd", "all": bad_flag}, DEMO)


# ---------------------------------------------------------------------------
# project scoping (Stage 1): both axes declared, and allowed_sites is the gate
# ---------------------------------------------------------------------------
def test_every_action_declares_both_role_axes_and_a_scope():
    """A new action that forgets `min_project_role`/`scope` would fall back to
    whatever the route assumes. Make the omission a test failure instead."""
    for name, spec in ACTIONS.items():
        assert spec.get("min_role") in ("viewer", "operator", "owner"), name
        assert spec.get("min_project_role") in ("viewer", "operator", "maintainer"), \
            f"{name} does not declare min_project_role"
        assert spec.get("scope") in ("site", "global"), \
            f"{name} does not declare scope (site|global)"


def test_empty_allowed_sites_refuses_every_site_scoped_action():
    """The fail-closed core of the action gate: a scope with no demo sites (a
    project that has none, or a user with no project at all) can run nothing."""
    for name, spec in ACTIONS.items():
        if spec.get("scope") != "site":
            continue
        for site in ("nwd", "avc", "ss", ""):
            with pytest.raises(ActionError):
                build_action(name, {"site": site, "bundle": "tester-member", "code_id": "c1"}, [])


def test_a_console_demo_site_outside_the_scope_is_still_refused():
    """config.DEMO_SITES says the verb EXISTS for a site; the scope says who
    may use it. Passing the console-wide list here would re-open the boundary,
    so the argument is the scope's list and nothing else."""
    with pytest.raises(ActionError):
        build_action("demo_reset", {"site": "avc"}, ["nwd"])
    argv, spec = build_action("demo_reset", {"site": "nwd"}, ["nwd"])
    assert argv == ["demo", "reset", "nwd", "--tier=live", "--if-idle", "30m", "--yes"]
    assert spec["scope"] == "site"


def test_all_demo_actions_name_tier_live():
    """Regression: the console manages the PUBLIC (live) demo, and the demo
    verbs refuse without an explicit tier. Every demo action MUST carry
    --tier=live, or the console button silently errors 'Re-run naming the tier'
    (the 2026-07 invite-button bug). No demo action may default to dev."""
    cases = [
        ("demo_reset", {"site": "nwd"}),
        ("demo_code_issue", {"site": "nwd", "bundle": "tester-member"}),
        ("demo_invite", {"site": "nwd"}),
        ("demo_code_revoke", {"site": "nwd", "code_id": "abc123_X-"}),
    ]
    for action, params in cases:
        argv, _ = build_action(action, params, DEMO)
        assert "--tier=live" in argv, f"{action} is missing --tier=live: {argv}"
