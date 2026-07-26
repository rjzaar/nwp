"""Role model — pure, stdlib only, unit-tested.

TWO axes, and they are not the same axis:

  * GLOBAL role (viewer/operator/owner) — what a person may do to the console
    itself. Unchanged, still enforced server-side per route.
  * PROJECT role (viewer/operator/maintainer) — what a person may do INSIDE
    one project (a named set of sites). Only owners administer projects.

The global role is a CEILING: a project membership can never grant more than
the global role already allows (see `effective_project_role`). That is the
property that makes "add dana as a project maintainer" a safe operation — it
cannot turn a global viewer into someone who can run actions.

Enforcement is server-side per route:
  viewer     — GET everything in scope (audit page: no)
  operator   — viewer + POST the allowlisted safe actions + issue/CI actions
  owner      — operator + user/project management, and the unscoped view
"""
from __future__ import annotations

ROLES = ("viewer", "operator", "owner")
_ORDER = {r: i for i, r in enumerate(ROLES)}

# Per-project roles. Deliberately a DIFFERENT vocabulary from the global one:
# "maintainer" is a project word (may assign members to this project) and must
# never read as "owner" (may create projects, edit site lists, manage users).
PROJECT_ROLES = ("viewer", "operator", "maintainer")
_PORDER = {r: i for i, r in enumerate(PROJECT_ROLES)}

# Global role -> the highest project role it may ever reach.
CAP = {"viewer": "viewer", "operator": "operator", "owner": "maintainer"}


def is_valid_role(role: str) -> bool:
    # `isinstance` first, deliberately: a dict or list reaching this from a
    # malformed store would make `role in _ORDER` raise TypeError, and an
    # exception is not a refusal — under a broad `except` somewhere upstream
    # it could just as easily become an allow. Non-strings are simply invalid.
    return isinstance(role, str) and role in _ORDER


def is_valid_project_role(role: str) -> bool:
    return isinstance(role, str) and role in _PORDER


def role_allows(have: str, need: str) -> bool:
    """True iff a user holding `have` may use a route requiring `need`.

    Unknown roles on either side fail closed.
    """
    if not is_valid_role(have) or not is_valid_role(need):
        return False
    return _ORDER[have] >= _ORDER[need]


def project_role_allows(have, need) -> bool:
    """Same ordering test for the project axis. None/unknown/non-string fails
    closed — and returns False rather than raising, so a malformed store can
    never turn a permission question into an unhandled exception."""
    if not is_valid_project_role(have) or not is_valid_project_role(need):
        return False
    return _PORDER[have] >= _PORDER[need]


def effective_project_role(global_role, project_role):
    """The role actually in force inside a project. None == no access.

    A membership NEVER escalates past the global cap: a global viewer who is
    recorded as a project maintainer is still, effectively, a project viewer.
    """
    if not is_valid_role(global_role):
        return None
    if global_role == "owner":
        return "maintainer"
    cap = CAP.get(global_role)
    if cap is None or not is_valid_project_role(project_role):
        return None
    return project_role if _PORDER[project_role] <= _PORDER[cap] else cap


def library_shards(scope) -> list:
    """Derived grant — the ONLY place shard names are computed (Stage 4 uses
    it; it lives here now so the grant and the cap are reviewed together)."""
    if getattr(scope, "project_role", None) is None:
        return []
    s = ["contributor"] + [f"project-{pid}" for pid, _name in getattr(scope, "memberships", ())]
    if getattr(scope, "global_role", "") == "owner":
        s += ["private"]
    return sorted(set(s + ["public"]))


def visual_views(scope) -> tuple:
    """Which Visuals sub-views a scope may see (Stage 2+ consumes this).

    Feeds that are not site-scoped cannot be filtered by site, so they are
    owner-only views rather than scoped views.
    """
    base = ("overview", "fleet", "pipeline", "dr", "security", "consent", "demo", "activity")
    if getattr(scope, "global_role", "") == "owner":
        return base
    return tuple(v for v in base if v not in ("secrets", "leakage", "risk_global"))
