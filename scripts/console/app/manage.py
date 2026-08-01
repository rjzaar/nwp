"""Management CLI — run ON THE DEPLOY HOST (shell access = the trust boundary).

    python3 -m app.manage user-add <name> --role viewer|operator|owner
                                         [--project <pid> --project-role <r>]
    python3 -m app.manage user-addkey <name>         # +1 passkey, keeps the rest
    python3 -m app.manage user-keys <name>           # list passkeys + what each one is
    python3 -m app.manage user-rmkey <name> <handle> # revoke ONE (never the last)
    python3 -m app.manage user-reset <name>          # break-glass re-enrol
    python3 -m app.manage user-role <name> <role>
    python3 -m app.manage user-rm <name>
    python3 -m app.manage user-list
    python3 -m app.manage user-show <name>

    python3 -m app.manage project-list
    python3 -m app.manage project-add <pid> [--name ..] [--sites a b c]
                                           [--demo-sites ..] [--issue-label ..]
                                           [--ci-projects ..]
    python3 -m app.manage project-set <pid> [--sites ..] [--demo-sites ..] ...
    python3 -m app.manage project-rm <pid>
    python3 -m app.manage project-assign <user> <pid> --role viewer|operator|maintainer
    python3 -m app.manage project-unassign <user> <pid>
    python3 -m app.manage project-export [--out FILE]

user-add / user-addkey / user-reset print a ONE-TIME enrolment URL (48 h
expiry). addkey keeps existing passkeys; reset revokes them. The token
is stored hashed; the plaintext appears only in this terminal output.

project-export writes the read-only project->sites projection consumed by the
workstation (private/project-map.json). It contains NO user, credential or
token data — only the map the publisher and the doc-library gate need. The
console host stays the single AUTHOR of that map; the workstation only ever
receives a copy.

`pl console user ...` / `pl console project ...` on the workstation are thin
ssh wrappers around this.
"""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

# Load the deployed EnvironmentFile BEFORE importing config (config reads env
# at import time) so CLI printouts — the enrolment ORIGIN links especially —
# match what the running service uses. systemd passes these vars to the app;
# a bare shell invocation would otherwise print placeholder-default URLs.
# (Mirrors the hotfix applied live on the deploy host, 2026-07-24.)
_ENV_FILE = Path.home() / ".config/nwp-console/env"
if _ENV_FILE.exists():
    for _line in _ENV_FILE.read_text().splitlines():
        if "=" in _line and not _line.strip().startswith("#"):
            _k, _v = _line.split("=", 1)
            os.environ.setdefault(_k.strip(), _v.strip())

import json

from . import config
from .store import AuditLog, ProjectStore, StoreError, UserStore


def _store() -> UserStore:
    return UserStore(config.DATA_DIR / "users.json")


def _projects() -> ProjectStore:
    # Same file, same lock as the user store — a membership can never point at
    # a project a concurrent write has just removed.
    return ProjectStore(config.DATA_DIR / "users.json", ci_allowlist=config.CI_PROJECTS)


def _audit(action: str, detail: dict, project: str | None = None) -> None:
    AuditLog(config.DATA_DIR / "audit.jsonl").append("(shell)", "owner", action, detail, True,
                                                     project=project)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="app.manage", description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("user-add")
    p.add_argument("name")
    p.add_argument("--role", default="viewer", choices=["viewer", "operator", "owner"])
    p.add_argument("--project", default="", help="also add them to this project (one atomic write)")
    p.add_argument("--project-role", default="viewer",
                   choices=["viewer", "operator", "maintainer"])

    p = sub.add_parser("user-addkey")
    p.add_argument("name")

    p = sub.add_parser("user-keys")
    p.add_argument("name")

    p = sub.add_parser("user-rmkey")
    p.add_argument("name")
    p.add_argument("handle", help="the short handle from user-keys (prefix of the credential id)")

    p = sub.add_parser("user-reset")
    p.add_argument("name")

    p = sub.add_parser("user-role")
    p.add_argument("name")
    p.add_argument("role", choices=["viewer", "operator", "owner"])

    p = sub.add_parser("user-rm")
    p.add_argument("name")

    sub.add_parser("user-list")

    p = sub.add_parser("user-show")
    p.add_argument("name")

    # -- projects ------------------------------------------------------------
    sub.add_parser("project-list")

    def _proj_fields(p, required_pid=True):
        p.add_argument("pid")
        p.add_argument("--name", default=None)
        p.add_argument("--description", default=None)
        p.add_argument("--sites", nargs="*", default=None)
        p.add_argument("--demo-sites", nargs="*", default=None)
        p.add_argument("--issue-label", default=None)
        p.add_argument("--ci-projects", nargs="*", default=None)

    _proj_fields(sub.add_parser("project-add"))
    _proj_fields(sub.add_parser("project-set"))

    p = sub.add_parser("project-rm")
    p.add_argument("pid")

    p = sub.add_parser("project-assign")
    p.add_argument("user")
    p.add_argument("pid")
    p.add_argument("--role", default="viewer", choices=["viewer", "operator", "maintainer"])

    p = sub.add_parser("project-unassign")
    p.add_argument("user")
    p.add_argument("pid")

    p = sub.add_parser("project-export")
    p.add_argument("--out", default="", help="write here instead of stdout")

    a = ap.parse_args(argv)
    store = _store()
    try:
        if a.cmd == "user-add":
            token = store.add_user(a.name, a.role, config.ENROL_TOKEN_HOURS,
                                   project=a.project, project_role=a.project_role)
            _audit("user.add", {"name": a.name, "role": a.role,
                                "project": a.project or None}, project=a.project or None)
            where = f" and added to project '{a.project}' as {a.project_role}" if a.project else ""
            print(f"user '{a.name}' created with role '{a.role}'{where}.")
            print("ONE-TIME enrolment link (expires in "
                  f"{config.ENROL_TOKEN_HOURS} h, single use — open it on the device that holds the passkey):")
            print(f"  {config.ORIGIN}/enroll?token={token}")
        elif a.cmd == "user-addkey":
            token = store.add_key_token(a.name, config.ENROL_TOKEN_HOURS)
            _audit("user.addkey", {"name": a.name})
            n = len((store.get_user(a.name) or {}).get("credentials", []))
            print(f"user '{a.name}': {n} existing passkey(s) KEPT. "
                  "ONE-TIME link to enrol one MORE (open it on the device holding the new key):")
            print(f"  {config.ORIGIN}/enroll?token={token}")
        elif a.cmd == "user-keys":
            rows = store.credentials_view(a.name)
            if not rows:
                print(f"user '{a.name}' has no passkeys (enrolment pending)")
            for r in rows:
                print(f"{r['handle']:<12} {r['label']:<52} added={r['added']} sign_count={r['sign_count']}")
        elif a.cmd == "user-rmkey":
            gone = store.remove_credential(a.name, a.handle)
            _audit("user.revokekey", {"name": a.name, "handle": gone["id"][:10]})
            left = len((store.get_user(a.name) or {}).get("credentials", []))
            print(f"revoked passkey {gone['id'][:10]} on '{a.name}' — {left} passkey(s) still work")
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
            has_projects = bool(_projects().all_projects())
            for u in store.list_users():
                pending = " (enrolment pending)" if u["enrol_pending"] else ""
                if u["role"] == "owner":
                    proj = "all(owner)"
                elif u["projects"]:
                    proj = ",".join(f"{k}:{v}" for k, v in u["projects"].items())
                else:
                    # Spelled out, because with projects configured this account
                    # can sign in and see literally nothing — that is a state
                    # somebody needs to notice, not a blank column.
                    proj = "NONE(sees nothing)" if has_projects else "-"
                print(f"{u['name']:<20} {u['role']:<9} passkeys={u['passkeys']} "
                      f"projects={proj}{pending}  created={u['created']}")
        elif a.cmd == "user-show":
            u = store.get_user(a.name)
            if u is None:
                print(f"ERROR: no such user: {a.name}", file=sys.stderr)
                return 1
            print(f"user:        {a.name}")
            print(f"global role: {u.get('role', '?')}")
            print(f"created:     {u.get('created', '')}")
            print(f"passkeys:    {len(u.get('credentials', []))}")
            for r in store.credentials_view(a.name):
                print(f"             {r['handle']}  {r['label']}  (added {r['added']})")
            print(f"enrolment:   {'pending' if u.get('enrol') else 'complete'}")
            memb = store.memberships(a.name)
            allp = _projects().all_projects()
            if u.get("role") == "owner":
                print("projects:    ALL (global owner — membership is not consulted)")
            elif memb:
                for pid, role in sorted(memb.items()):
                    sites = " ".join(sorted((allp.get(pid) or {}).get("sites") or []))
                    stale = "" if pid in allp else "   [PROJECT NO LONGER EXISTS]"
                    print(f"projects:    {pid} ({role}){stale}")
                    print(f"             sites: {sites or '(none)'}")
            else:
                print("projects:    none" + ("  -> this user sees NOTHING" if allp else ""))
        # -- projects --------------------------------------------------------
        elif a.cmd == "project-list":
            ps = _projects().list_projects()
            if not ps:
                print("no projects — the console is in legacy mode "
                      "(every user sees the whole fleet, bounded by global role only)")
            for p in ps:
                gl = p["gitlab"]
                print(f"{p['id']:<16} {p['name']}")
                print(f"  sites:      {' '.join(p['sites']) or '(none)'}")
                print(f"  demo:       {' '.join(p['demo_sites']) or '(none)'}")
                print(f"  issue label:{' ' + gl.get('issue_label', '') if gl.get('issue_label') else ' (none -> NO issues)'}")
                print(f"  ci:         {' '.join(gl.get('ci_projects') or []) or '(none -> NO CI)'}")
                print(f"  members:    {', '.join(f'{k}:{v}' for k, v in p['members'].items()) or '(none)'}")
        elif a.cmd in ("project-add", "project-set"):
            gl = None
            if a.issue_label is not None or a.ci_projects is not None:
                gl = {"issue_label": a.issue_label or "", "ci_projects": a.ci_projects or []}
            if a.cmd == "project-add":
                _projects().add_project(
                    a.pid, name=a.name or "", description=a.description or "",
                    sites=a.sites or [], demo_sites=a.demo_sites or [],
                    gitlab=gl, created_by="(shell)")
                _audit("project.add", {"pid": a.pid, "sites": a.sites or []}, project=a.pid)
                print(f"project '{a.pid}' created")
            else:
                _projects().set_project(
                    a.pid, name=a.name, description=a.description,
                    sites=a.sites, demo_sites=a.demo_sites, gitlab=gl)
                _audit("project.set", {"pid": a.pid, "sites": a.sites}, project=a.pid)
                print(f"project '{a.pid}' updated")
        elif a.cmd == "project-rm":
            gc = _projects().remove_project(a.pid)
            _audit("project.rm", {"pid": a.pid, "memberships_removed": gc})
            print(f"project '{a.pid}' removed ({gc} membership(s) revoked with it)")
        elif a.cmd == "project-assign":
            _projects().set_project_role(a.user, a.pid, a.role)
            _audit("project.assign", {"pid": a.pid, "member": a.user, "role": a.role}, project=a.pid)
            print(f"'{a.user}' assigned to '{a.pid}' as {a.role}")
        elif a.cmd == "project-unassign":
            _projects().unset_project_role(a.user, a.pid)
            _audit("project.unassign", {"pid": a.pid, "member": a.user}, project=a.pid)
            print(f"'{a.user}' removed from '{a.pid}'")
        elif a.cmd == "project-export":
            data = json.dumps(_projects().export_map(), indent=1, sort_keys=True)
            if a.out:
                path = Path(a.out)
                path.parent.mkdir(parents=True, exist_ok=True)
                # 0600 before content: the map names every site of every
                # tenant, which is exactly the fact the boundary protects.
                fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
                with os.fdopen(fd, "w") as f:
                    f.write(data + "\n")
                print(f"wrote {path}")
            else:
                print(data)
    except StoreError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
