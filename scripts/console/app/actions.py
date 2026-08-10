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

from .scope import SITE_RE

CODE_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,40}$")

# ops#328 t3 — the per-tester editor's slots. The console always addresses
# accounts by USERNAME (the roster's own `name` field), never mail/uid, so
# the shape is a username shape. Seed keys are lowercase machine ids
# (field_group_seed_key); group roles are Group-2.x ids like guild-mentor —
# the VERB and the drush command validate the real role set, this only pins
# the shape so no free text reaches an argv.
TESTER_ACCOUNT_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,59}$")
TESTER_SEED_KEY_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,39}$")
TESTER_GROUP_ROLE_RE = re.compile(r"^[a-z][a-z0-9-]{0,39}$")
TESTER_LEVEL_MIN, TESTER_LEVEL_MAX = 1, 12

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


def _valid_site(site: str, allowed_sites: list[str]) -> str:
    """`allowed_sites` is the caller's SCOPE-narrowed demo-site set, not the
    console-wide one: config.DEMO_SITES says which sites the demo tier exists
    for, the Scope says which of those THIS request may touch. Both must hold,
    and an empty list therefore refuses every site (fail closed)."""
    if not isinstance(site, str) or not SITE_RE.match(site):
        raise ActionError("invalid site name")
    if site not in (allowed_sites or []):
        raise ActionError(f"site {site!r} is not a demo site you may act on")
    return site


def _valid_bundle(bundle: str) -> str:
    if bundle not in BUNDLES:
        raise ActionError("invalid role bundle")
    return bundle


def _valid_code_id(code_id: str) -> str:
    if not isinstance(code_id, str) or not CODE_ID_RE.match(code_id):
        raise ActionError("invalid code id")
    return code_id


# Bulk-select ceiling (ops#328). The verb re-validates every id server-side;
# this bound only keeps a runaway form from building an absurd argv.
CODE_IDS_MAX = 50


def _valid_code_ids(value) -> list[str]:
    """One or many code ids — the console's bulk checkboxes. Accepts a list
    (multi-value form field) or a single string. Every id passes the same
    strict validator, and ONE bad id rejects the WHOLE batch — the verb
    enforces the same rule, so a half-applied bulk action is unrepresentable
    at both layers."""
    if isinstance(value, str):
        value = [value] if value else []
    if not isinstance(value, (list, tuple)) or not value:
        raise ActionError("no code ids selected")
    if len(value) > CODE_IDS_MAX:
        raise ActionError(f"too many code ids in one batch (max {CODE_IDS_MAX})")
    return [_valid_code_id(v) for v in value]


def _valid_tester_account(value) -> str:
    if not isinstance(value, str) or not TESTER_ACCOUNT_RE.match(value):
        raise ActionError("invalid tester account name")
    return value


def _valid_seed_key(value) -> str:
    if not isinstance(value, str) or not TESTER_SEED_KEY_RE.match(value):
        raise ActionError("invalid guild seed key (lowercase machine id — guilds are "
                          "addressed by field_group_seed_key, never by label)")
    return value


def _valid_group_role(value) -> str:
    """'member' (plain membership) or an id-shaped Group-2.x role. The verb +
    drush validate against the REAL role set (individual-scope only, no
    guild-leader); this only guarantees argv hygiene."""
    if value == "member":
        return value
    if not isinstance(value, str) or not TESTER_GROUP_ROLE_RE.match(value):
        raise ActionError("invalid group role id")
    return value


def _valid_level(value) -> str:
    try:
        n = int(str(value), 10)
    except (TypeError, ValueError):
        raise ActionError("level must be an integer")
    if not (TESTER_LEVEL_MIN <= n <= TESTER_LEVEL_MAX):
        raise ActionError(f"level must be {TESTER_LEVEL_MIN}..{TESTER_LEVEL_MAX}")
    return str(n)


def _build_tester_set_guild(p: dict, ds: list) -> list:
    """Role and remove are contradictory; --allow-real is UNREPRESENTABLE —
    no parameter maps to it, deliberately (the @demo.invalid fence is the
    point of the whole surface)."""
    site = _valid_site(p.get("site", ""), ds)
    account = _valid_tester_account(p.get("account", ""))
    seed_key = _valid_seed_key(p.get("seed_key", ""))
    role = p.get("role", "") or ""
    remove = _valid_flag(p.get("remove", ""))
    if role and remove:
        raise ActionError("role and remove are contradictory — pass exactly one")
    argv = ["demo", "testers", site, "set-guild", account, seed_key]
    if role:
        argv.append("--group-role=" + _valid_group_role(role))
    if remove:
        argv.append("--remove")
    argv.append("--tier=live")
    return argv


def _valid_flag(value) -> bool:
    """Checkbox-style boolean: only exact known truthy strings count."""
    if value in ("", None, False, "0", "false", "off"):
        return False
    if value in ("1", "true", "on", True):
        return True
    raise ActionError("invalid flag value")


# action name -> spec. Every entry declares BOTH axes:
#   min_role         global role floor (unchanged)
#   min_project_role project role floor inside the scope
#   scope            "site"   — acts on one site, gated by allowed_sites
#                    "global" — acts on the whole fleet; cannot be narrowed to
#                               a project, so it is unscoped-only (owner, or a
#                               legacy install with no projects at all)
ACTIONS: dict = {
    "rag_refresh": {
        "min_role": "operator",
        "min_project_role": "operator",
        "scope": "global",
        "label": "Re-run RAG fleet check",
        "build": lambda p, ds: ["rag", "--no-todo"],
    },
    "demo_reset": {
        "min_role": "operator",
        "min_project_role": "operator",
        "scope": "site",
        "label": "Demo reset (idle-guarded)",
        # --if-idle stays even on the console's "force" button: never
        # green-light a wipe while a tester session is active.
        # --tier=live is a fixed literal: the console only ever acts on the
        # PUBLIC demo site (config.DEMO_SITES = the live demo); the demo verbs
        # refuse without an explicit tier, and the console host has no local
        # dev instance to act on.
        "build": lambda p, ds: ["demo", "reset", _valid_site(p.get("site", ""), ds), "--tier=live", "--if-idle", "30m", "--yes"],
    },
    "demo_code_issue": {
        "min_role": "operator",
        "min_project_role": "operator",
        "scope": "site",
        "label": "Issue demo invite code",
        "build": lambda p, ds: [
            "demo", "codes", _valid_site(p.get("site", ""), ds), "issue",
            _valid_bundle(p.get("bundle", "")), "--expires=14d", "--tier=live",
        ],
    },
    "demo_invite": {
        "min_role": "operator",
        "min_project_role": "operator",
        "scope": "site",
        "label": "Invitation email draft",
        # Renders the copy-ready invite email (pl demo invite): one fresh code
        # per level, plaintext ONLY in the command output (registry stores
        # hashes). Args are fixed literals except the validated site and the
        # boolean --all toggle — no free-text ever reaches the argv.
        "build": lambda p, ds: (
            ["demo", "invite", _valid_site(p.get("site", ""), ds), "--tier=live"]
            + (["--all"] if _valid_flag(p.get("all", "")) else [])
        ),
    },
    "demo_code_revoke": {
        "min_role": "operator",
        "min_project_role": "operator",
        "scope": "site",
        "label": "Revoke demo invite code(s)",
        # One or many ids (ops#328 bulk select). `code_id` kept for the
        # pre-bulk form shape; `code_ids` is the checkbox field.
        "build": lambda p, ds: (
            ["demo", "codes", _valid_site(p.get("site", ""), ds), "revoke"]
            + _valid_code_ids(p.get("code_ids") or p.get("code_id") or "")
            + ["--tier=live"]
        ),
    },
    "demo_tester_set_guild": {
        "min_role": "operator",
        "min_project_role": "operator",
        "scope": "site",
        "label": "Set tester guild membership/role",
        # ops#328 t3: wraps `pl demo testers … set-guild`, which wraps drush
        # nwc:tester-set-guild. Fences at every layer: this argv can never
        # carry --allow-real; the verb refuses it by name and requires the
        # site to report demo_mode=true; the drush command refuses accounts
        # off the @demo.invalid fence and validates the real role set.
        "build": _build_tester_set_guild,
    },
    "demo_tester_set_level": {
        "min_role": "operator",
        "min_project_role": "operator",
        "scope": "site",
        "label": "Set tester Sojourner level (raise-only, via evidence)",
        # There is no raw level setter anywhere in the chain: the drush side
        # records qualifying course completions and recomputes. Demotion is a
        # typed refusal the console renders verbatim.
        "build": lambda p, ds: [
            "demo", "testers", _valid_site(p.get("site", ""), ds), "set-level",
            _valid_tester_account(p.get("account", "")), _valid_level(p.get("level", "")),
            "--tier=live",
        ],
    },
    "demo_code_purge": {
        "min_role": "operator",
        "min_project_role": "operator",
        "scope": "site",
        "label": "Purge revoked/expired invite code(s)",
        # Housekeeping, not revocation: the verb refuses any LIVE id and
        # archives the rows to demo-codes-purged.json rather than deleting.
        "build": lambda p, ds: (
            ["demo", "codes", _valid_site(p.get("site", ""), ds), "purge"]
            + _valid_code_ids(p.get("code_ids") or p.get("code_id") or "")
            + ["--tier=live"]
        ),
    },
}


def build_action(name: str, params: dict, allowed_sites) -> tuple[list[str], dict]:
    """Validate + build. Returns (pl argv tail, spec). Raises ActionError.

    `allowed_sites` MUST be the requesting Scope's demo-site set. Passing the
    console-wide list here would re-open the boundary this argument exists to
    close, so the route passes sorted(scope.demo_sites) and nothing else.
    """
    spec = ACTIONS.get(name)
    if spec is None:
        raise ActionError(f"unknown action: {name!r}")
    argv = spec["build"](params or {}, list(allowed_sites or []))
    # Belt & braces: re-assert the verb tier even if the map is edited later.
    if argv[0] in FORBIDDEN_VERBS:
        raise ActionError("action maps to a forbidden verb tier")
    for a in argv:
        if not isinstance(a, str) or any(ch in a for ch in ";|&$`\n\r<>"):
            raise ActionError("argv failed the shell-metacharacter guard")
    return argv, spec
