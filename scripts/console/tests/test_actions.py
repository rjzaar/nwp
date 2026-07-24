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
    argv, role = build_action("rag_refresh", {}, DEMO)
    assert argv == ["rag", "--no-todo"]
    assert role == "operator"


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
    assert argv == ["demo", "codes", "nwd", "issue", "tester-member", "--expires=14d"]
    for bad in ("sitemanager", "tester-sitemanager", "admin", "", "tester-member --force"):
        with pytest.raises(ActionError):
            build_action("demo_code_issue", {"site": "nwd", "bundle": bad}, DEMO)


def test_code_revoke_id_validation():
    argv, _ = build_action("demo_code_revoke", {"site": "nwd", "code_id": "abc123_X-"}, DEMO)
    assert argv[-1] == "abc123_X-"
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
