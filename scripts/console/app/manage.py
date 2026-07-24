"""Management CLI — run ON THE DEPLOY HOST (shell access = the trust boundary).

    python3 -m app.manage user-add <name> --role viewer|operator|owner
    python3 -m app.manage user-reset <name>          # break-glass re-enrol
    python3 -m app.manage user-role <name> <role>
    python3 -m app.manage user-rm <name>
    python3 -m app.manage user-list

user-add / user-reset print a ONE-TIME enrolment URL (48 h expiry). The token
is stored hashed; the plaintext appears only in this terminal output.

`pl console user ...` on the workstation is a thin ssh wrapper around this.
"""
from __future__ import annotations

import argparse
import sys

from . import config
from .store import AuditLog, StoreError, UserStore


def _store() -> UserStore:
    return UserStore(config.DATA_DIR / "users.json")


def _audit(action: str, detail: dict) -> None:
    AuditLog(config.DATA_DIR / "audit.jsonl").append("(shell)", "owner", action, detail, True)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="app.manage", description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("user-add")
    p.add_argument("name")
    p.add_argument("--role", default="viewer", choices=["viewer", "operator", "owner"])

    p = sub.add_parser("user-reset")
    p.add_argument("name")

    p = sub.add_parser("user-role")
    p.add_argument("name")
    p.add_argument("role", choices=["viewer", "operator", "owner"])

    p = sub.add_parser("user-rm")
    p.add_argument("name")

    sub.add_parser("user-list")

    a = ap.parse_args(argv)
    store = _store()
    try:
        if a.cmd == "user-add":
            token = store.add_user(a.name, a.role, config.ENROL_TOKEN_HOURS)
            _audit("user.add", {"name": a.name, "role": a.role})
            print(f"user '{a.name}' created with role '{a.role}'.")
            print("ONE-TIME enrolment link (expires in "
                  f"{config.ENROL_TOKEN_HOURS} h, single use — open it on the device that holds the passkey):")
            print(f"  {config.ORIGIN}/enroll?token={token}")
        elif a.cmd == "user-reset":
            token = store.reset_user(a.name, config.ENROL_TOKEN_HOURS)
            _audit("user.reset", {"name": a.name})
            print(f"user '{a.name}': all passkeys revoked. New ONE-TIME enrolment link:")
            print(f"  {config.ORIGIN}/enroll?token={token}")
        elif a.cmd == "user-role":
            store.set_role(a.name, a.role)
            _audit("user.role", {"name": a.name, "role": a.role})
            print(f"user '{a.name}' role -> {a.role}")
        elif a.cmd == "user-rm":
            store.remove_user(a.name)
            _audit("user.rm", {"name": a.name})
            print(f"user '{a.name}' removed")
        elif a.cmd == "user-list":
            for u in store.list_users():
                pending = " (enrolment pending)" if u["enrol_pending"] else ""
                print(f"{u['name']:<20} {u['role']:<9} passkeys={u['passkeys']}{pending}  created={u['created']}")
    except StoreError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
