"""Role model — pure, stdlib only, unit-tested.

Three roles, strictly ordered. Enforcement is server-side per route:
  viewer   — GET everything (dashboards, panes, audit page: no)
  operator — viewer + POST the allowlisted safe actions + issue actions + audit page
  owner    — operator + user management
"""
from __future__ import annotations

ROLES = ("viewer", "operator", "owner")
_ORDER = {r: i for i, r in enumerate(ROLES)}


def is_valid_role(role: str) -> bool:
    return role in _ORDER


def role_allows(have: str, need: str) -> bool:
    """True iff a user holding `have` may use a route requiring `need`.

    Unknown roles on either side fail closed.
    """
    if have not in _ORDER or need not in _ORDER:
        return False
    return _ORDER[have] >= _ORDER[need]
