"""Fail-closed action allowlist — pure, stdlib only, unit-tested.

THE ONLY shell-outs the console may perform are built here. Properties the
tests assert and reviewers should hold the line on:

  * Fixed map: action name -> literal argv template. Unknown action => reject.
  * No string interpolation of user input into a command line — argv lists
    only, never shell=True, and every user-supplied argument must pass a
    strict validator before it is placed into its own argv slot.
  * No live/prod verbs. Nothing in this map may ever touch live or prod
    (stg2live, live2prod, stg2prod, live, deploy-gate, server-apply, rollback,
    restore, delete...). Anything on that tier gets a read-only view and a
    "run this on the workstation" instruction instead.
  * Every action carries min_role (enforced by the route) and is audit-logged.
"""
from __future__ import annotations

import re

SITE_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,30}$")
CODE_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,40}$")

# Role bundles `pl demo codes issue` accepts (decisions §4.4 — sitemanager never).
BUNDLES = (
    "tester-member",
    "tester-guild-leader",
    "tester-content-manager",
    "tester-copyright-reviewer",
    "tester-safeguarding-reviewer",
)

# Verbs that must NEVER appear as the pl subcommand of any action.
FORBIDDEN_VERBS = frozenset(
    {
        "live", "stg2live", "live2prod", "stg2prod", "prod2stg", "live2stg",
        "deploy-gate", "server-apply", "rollback", "restore", "delete",
        "cutover", "publish", "secrets", "install",
    }
)


class ActionError(Exception):
    """Raised for any invalid action request — the route returns 400."""


def _valid_site(site: str, demo_sites: list[str]) -> str:
    if not isinstance(site, str) or not SITE_RE.match(site):
        raise ActionError("invalid site name")
    if site not in demo_sites:
        raise ActionError(f"site {site!r} is not a console-managed demo site")
    return site


def _valid_bundle(bundle: str) -> str:
    if bundle not in BUNDLES:
        raise ActionError("invalid role bundle")
    return bundle


def _valid_code_id(code_id: str) -> str:
    if not isinstance(code_id, str) or not CODE_ID_RE.match(code_id):
        raise ActionError("invalid code id")
    return code_id


# action name -> (min_role, human label, argv builder(params, demo_sites))
ACTIONS: dict = {
    "rag_refresh": {
        "min_role": "operator",
        "label": "Re-run RAG fleet check",
        "build": lambda p, ds: ["rag", "--no-todo"],
    },
    "demo_reset": {
        "min_role": "operator",
        "label": "Demo reset (idle-guarded)",
        # --if-idle stays even on the console's "force" button: never
        # green-light a wipe while a tester session is active.
        "build": lambda p, ds: ["demo", "reset", _valid_site(p.get("site", ""), ds), "--if-idle", "30m", "--yes"],
    },
    "demo_code_issue": {
        "min_role": "operator",
        "label": "Issue demo invite code",
        "build": lambda p, ds: [
            "demo", "codes", _valid_site(p.get("site", ""), ds), "issue",
            _valid_bundle(p.get("bundle", "")), "--expires=14d",
        ],
    },
    "demo_code_revoke": {
        "min_role": "operator",
        "label": "Revoke demo invite code",
        "build": lambda p, ds: [
            "demo", "codes", _valid_site(p.get("site", ""), ds), "revoke",
            _valid_code_id(p.get("code_id", "")),
        ],
    },
}


def build_action(name: str, params: dict, demo_sites: list[str]) -> tuple[list[str], str]:
    """Validate + build. Returns (pl argv tail, min_role). Raises ActionError."""
    spec = ACTIONS.get(name)
    if spec is None:
        raise ActionError(f"unknown action: {name!r}")
    argv = spec["build"](params or {}, list(demo_sites))
    # Belt & braces: re-assert the verb tier even if the map is edited later.
    if argv[0] in FORBIDDEN_VERBS:
        raise ActionError("action maps to a forbidden verb tier")
    for a in argv:
        if not isinstance(a, str) or any(ch in a for ch in ";|&$`\n\r<>"):
            raise ActionError("argv failed the shell-metacharacter guard")
    return argv, spec["min_role"]
