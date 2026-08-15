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

# The join queue's request ids (`r-` + 12 hex from JoinRequestStore) and the
# human name a tester is known by. The name is the ONE free-text field on this
# whole surface, so it is validated tightly at the door rather than escaped at
# every render: letters, marks, digits, spaces and ordinary name punctuation.
JOIN_REQUEST_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
# Anchored both ends, so a `<`, `;`, `/` or control character anywhere fails.
# The value is .strip()ed before matching, so a trailing space cannot pass.
DISPLAY_NAME_RE = re.compile(r"^[^\W\d_][\w .'\u2019-]{0,99}$", re.UNICODE)


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


def _valid_request_id(value) -> str:
    """A join request id. Named refusal, never a bare False — a caller's test
    that only proves non-zero proves nothing about which rule fired."""
    if not isinstance(value, str) or not JOIN_REQUEST_ID_RE.match(value):
        raise ActionError("invalid join request id")
    return value


def _valid_display_name(value) -> str:
    """The name a tester is known by, as the operator types it.

    This is the only free text on the surface, and it lands in a file the reset
    leg reads and a table the console renders, so it is bounded HERE. Refusing
    at the door beats escaping at every render, and the registry library
    revalidates it anyway — two independent checks, not one trusted one.
    """
    if not isinstance(value, str):
        raise ActionError("invalid display name")
    v = value.strip()
    if not v or len(v) > 100 or not DISPLAY_NAME_RE.match(v):
        raise ActionError(
            "invalid display name — letters, digits, spaces, apostrophes, "
            "dots and hyphens only, up to 100 characters"
        )
    return v


def _valid_bundle(value) -> str:
    """A tester bundle, from the literal allowlist.

    `sitemanager` and `administrator` were DECIDED OUT and the apply-route
    bundles mint accounts on the site's real application form, not here —
    neither is representable, because the allowlist has no entry for them.
    """
    if not isinstance(value, str) or value not in BUNDLES:
        raise ActionError(
            "invalid bundle — must be one of: " + ", ".join(BUNDLES)
        )
    return value


def _add_optionals(p: dict) -> list:
    """The optional attributes of an added tester.

    Absent means ABSENT: an empty guild must never become `--guild=`, which the
    verb would then have to interpret. Every value is shape-checked here and
    revalidated by the verb's library.
    """
    out = []
    guild = (p.get("guild") or "").strip()
    if guild:
        if not TESTER_SEED_KEY_RE.match(guild):
            raise ActionError("invalid guild seed key")
        out.append(f"--guild={guild}")
    level = str(p.get("level") or "").strip()
    if level:
        if not level.isdigit() or not (0 <= int(level) <= 10):
            raise ActionError("invalid level — 0 to 10")
        out.append(f"--level={int(level)}")
    # A checkbox: any truthy form the browser sends means "grant it", but the
    # flag itself is a fixed literal, never built from the value.
    if str(p.get("admin") or "").strip().lower() in ("1", "true", "on", "yes"):
        out.append("--admin")
    return out


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
    # -- the join queue (operator ruling 2026-08-15) ------------------------
    #
    # THE ACCESS MODEL, in one sentence: approval IS the persistence decision —
    # an unapproved join never becomes an account, and an approved tester
    # persists through the nightly reset with their own password.
    #
    # WHO MAY APPROVE: operator on BOTH axes. "the operator, and testers
    # holding admin rights" is expressed by giving that person a console
    # account with the operator role — the mechanism that already exists and
    # is already capped by effective_project_role. A separate "tester admin"
    # permission would be a second policy answering the same question, and a
    # policy expressed twice is a policy that drifts.
    "demo_join_approve": {
        "min_role": "operator",
        "min_project_role": "operator",
        "scope": "site",
        "label": "Approve this join request (creates the tester)",
        # Wraps `pl demo testers … approve`, which orchestrates: create the
        # account BLOCKED, write the tester registry, stage the payload, and
        # only THEN activate. The console never sees those steps individually
        # — it sees one verb that either approved somebody or refused and said
        # why, which is the only honest granularity for an operator.
        "build": lambda p, ds: [
            "demo", "testers", _valid_site(p.get("site", ""), ds), "approve",
            _valid_request_id(p.get("request_id", "")), "--tier=live", "--json",
        ],
    },
    "demo_join_reject": {
        "min_role": "operator",
        "min_project_role": "operator",
        "scope": "site",
        "label": "Reject this join request",
        # Creates nothing and destroys nothing: it records the decision so the
        # queue stops showing it. Nobody had an account to remove, because a
        # join never made one.
        "build": lambda p, ds: [
            "demo", "testers", _valid_site(p.get("site", ""), ds), "reject",
            _valid_request_id(p.get("request_id", "")), "--tier=live", "--json",
        ],
    },
    "demo_tester_add": {
        "min_role": "operator",
        "min_project_role": "operator",
        "scope": "site",
        "label": "Add a tester to the registry",
        # The operator's "I'd like to be able to add new testers to the list,
        # ie setting their names". Writes the tester registry and re-stages the
        # payload — so the person survives tonight's reset — without going
        # through a join request at all.
        "build": lambda p, ds: [
            "demo", "testers", _valid_site(p.get("site", ""), ds), "add",
            _valid_tester_account(p.get("account", "")),
            _valid_display_name(p.get("display_name", "")),
            _valid_bundle(p.get("bundle", "")),
        ] + _add_optionals(p) + ["--tier=live", "--json"],
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
    "demo_code_reveal": {
        "min_role": "operator",
        "min_project_role": "operator",
        "scope": "site",
        "label": "Reveal an invite code (shown once)",
        # ops#328 t4. Reads ONE row's plaintext back out of the invite packs by
        # hashing what is in them and matching the sha256 the registry already
        # stored — the registry stays hash-only. No tier: it touches no running
        # site. The verb is home-guarded (the packs live with the registry) and
        # appends an ACCESS record naming the id, never the value.
        "build": lambda p, ds: [
            "demo", "codes", _valid_site(p.get("site", ""), ds), "reveal",
            _valid_code_id(p.get("code_id", "")), "--json",
        ],
    },
    "demo_tester_login": {
        "min_role": "operator",
        "min_project_role": "operator",
        "scope": "site",
        "label": "Sign in as this tester (one-time link)",
        # ops#328 t4. The personas have no passwords, so a one-time login link
        # is the only way to see the site as one of them. Fixed argv: the
        # account is the only variable and it is shape-validated; --allow-real
        # is unrepresentable here as everywhere else on this surface. The verb
        # refuses uid<=1 and any account off the @demo.invalid fence, and it
        # proves the returned link belongs to the expected uid before it is
        # shown at all.
        "build": lambda p, ds: [
            "demo", "testers", _valid_site(p.get("site", ""), ds), "login",
            _valid_tester_account(p.get("account", "")), "--tier=live", "--json",
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
