import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.authz import ROLES, is_valid_role, role_allows  # noqa: E402


def test_role_order():
    assert role_allows("owner", "viewer")
    assert role_allows("owner", "operator")
    assert role_allows("owner", "owner")
    assert role_allows("operator", "viewer")
    assert not role_allows("operator", "owner")
    assert not role_allows("viewer", "operator")
    assert role_allows("viewer", "viewer")


def test_unknown_roles_fail_closed():
    assert not role_allows("admin", "viewer")
    assert not role_allows("owner", "root")
    assert not role_allows("", "")
    assert not role_allows(None, "viewer")


def test_role_set_is_exactly_three():
    assert ROLES == ("viewer", "operator", "owner")
    assert is_valid_role("operator")
    assert not is_valid_role("admin")
