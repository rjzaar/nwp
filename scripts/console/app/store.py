"""User + project store, and the audit log — stdlib only, unit-tested.

users.json (0600) layout, schema_version 2:
  {"schema_version": 2,
   "users": {"<name>": {"role": "...", "created": "...",
                        "credentials": [{"id": b64url, "public_key": b64url,
                                         "sign_count": 0, "added": "..."}],
                        "enrol": {"token_sha256": "...", "expires": epoch} | null,
                        "projects": {"<pid>": "viewer|operator|maintainer"}}},
   "projects": {"<pid>": {"name": ..., "description": ..., "sites": [...],
                          "demo_sites": [...],
                          "gitlab": {"issue_label": ..., "ci_projects": [...]},
                          "created": ..., "created_by": ...}}}

A v1 file (no schema_version, no projects) loads cleanly and reads as "no
projects exist" — which the Scope layer turns into legacy, all-sites behaviour.

Enrolment tokens are ONE-TIME: stored hashed, consumed on first successful use.
The plaintext is printed exactly once by `pl console user add|reset` and never
stored anywhere.

LOCKING (this is a permission property, not a tidiness one). Every mutator does
read-modify-write on ONE json file. Before projects that raced into a lost
update; with projects a lost update is a lost (or resurrected) grant. So every
mutator runs inside `_locked(path)` — an exclusive flock on a sidecar
`<file>.lock` held across the read AND the write — and the write itself stays
atomic (tmp + os.replace). The sidecar is used rather than the file itself
because os.replace() swaps the inode out from under any lock held on it.

audit.jsonl (0600): one JSON object per line
  {"ts": iso8601, "user": ..., "role": ..., "action": ..., "detail": {...},
   "ok": bool, "project": "<pid>"|null}
"""
from __future__ import annotations

import contextlib
import fcntl
import hashlib
import json
import os
import re
import secrets
import time
from datetime import datetime, timezone
from pathlib import Path

from .authz import is_valid_project_role, is_valid_role

USERNAME_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,31}$")
PROJECT_ID_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,31}$")
SITE_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,30}$")

SCHEMA_VERSION = 2


class StoreError(Exception):
    pass


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _hash_token(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


@contextlib.contextmanager
def _locked(path: Path):
    """Exclusive lock over one store file, held across read-modify-write."""
    path = Path(path)
    lock = path.with_name(path.name + ".lock")
    lock.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd = os.open(lock, os.O_WRONLY | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        with contextlib.suppress(OSError):
            fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


class _JsonStore:
    """Shared plumbing for the two views over users.json (users + projects)."""

    def __init__(self, path: Path):
        self.path = Path(path)

    def _load(self) -> dict:
        if not self.path.exists():
            return {"schema_version": SCHEMA_VERSION, "users": {}, "projects": {}}
        raw = self.path.read_text()
        if not raw.strip():                  # genuinely empty file == fresh store
            return {"schema_version": SCHEMA_VERSION, "users": {}, "projects": {}}
        try:
            data = json.loads(raw)
        except json.JSONDecodeError as e:  # corrupt store: refuse, don't wipe
            raise StoreError(f"corrupt user store {self.path}: {e}")
        # NB: no `or {}` here. A falsy-but-valid JSON value ([] , 0, "", null)
        # would be coerced to an empty store, which then gets SAVED over the
        # real file on the next write — silently deleting every user and every
        # grant. Corrupt must mean refuse, never "start again from nothing".
        if not isinstance(data, dict):
            raise StoreError(f"corrupt user store {self.path}: not an object")
        data.setdefault("users", {})
        # A v1 file has no "projects" key at all. Absent == none exist, which
        # the Scope layer reads as legacy mode. Never invent one.
        data.setdefault("projects", {})
        if not isinstance(data["users"], dict) or not isinstance(data["projects"], dict):
            raise StoreError(f"corrupt user store {self.path}: bad shape")
        return data

    def _save(self, data: dict) -> None:
        data["schema_version"] = SCHEMA_VERSION
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        tmp = self.path.with_suffix(".tmp")
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=1, sort_keys=True)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, self.path)


class UserStore(_JsonStore):
    # -- user management -----------------------------------------------------
    def add_user(self, name: str, role: str, token_hours: int = 48,
                 project: str = "", project_role: str = "viewer") -> str:
        """Create a user + one-time enrolment token. Returns the PLAINTEXT token.

        `project` is optional: creating a user WITH a membership in one call is
        the onboarding path (`pl console user add dana --project ss-nw`), and
        doing it under one lock means the user is never briefly project-less.
        """
        if not USERNAME_RE.match(name or ""):
            raise StoreError(f"invalid username: {name!r} (want ^[a-z0-9][a-z0-9_-]{{0,31}}$)")
        if not is_valid_role(role):
            raise StoreError(f"invalid role: {role!r}")
        if project and not is_valid_project_role(project_role):
            raise StoreError(f"invalid project role: {project_role!r}")
        token = secrets.token_urlsafe(32)
        with _locked(self.path):
            data = self._load()
            if name in data["users"]:
                raise StoreError(f"user already exists: {name} (use reset to re-enrol)")
            if project and project not in data["projects"]:
                raise StoreError(f"no such project: {project}")
            data["users"][name] = {
                "role": role,
                "created": _now_iso(),
                "credentials": [],
                "enrol": {"token_sha256": _hash_token(token), "expires": int(time.time()) + token_hours * 3600},
                "projects": {project: project_role} if project else {},
            }
            self._save(data)
        return token

    def reset_user(self, name: str, token_hours: int = 48) -> str:
        """Break-glass: wipe credentials, issue a fresh one-time token."""
        token = secrets.token_urlsafe(32)
        with _locked(self.path):
            data = self._load()
            if name not in data["users"]:
                raise StoreError(f"no such user: {name}")
            u = data["users"][name]
            u["credentials"] = []
            u["enrol"] = {"token_sha256": _hash_token(token), "expires": int(time.time()) + token_hours * 3600}
            self._save(data)
        return token

    def set_role(self, name: str, role: str) -> None:
        if not is_valid_role(role):
            raise StoreError(f"invalid role: {role!r}")
        with _locked(self.path):
            data = self._load()
            if name not in data["users"]:
                raise StoreError(f"no such user: {name}")
            data["users"][name]["role"] = role
            self._save(data)

    def remove_user(self, name: str) -> None:
        with _locked(self.path):
            data = self._load()
            if name not in data["users"]:
                raise StoreError(f"no such user: {name}")
            del data["users"][name]
            self._save(data)

    def list_users(self) -> list[dict]:
        data = self._load()
        out = []
        for name, u in sorted(data["users"].items()):
            projects = u.get("projects") or {}
            out.append(
                {
                    "name": name,
                    "role": u.get("role", "?"),
                    "created": u.get("created", ""),
                    "passkeys": len(u.get("credentials", [])),
                    "enrol_pending": bool(u.get("enrol")),
                    "projects": dict(sorted(projects.items())) if isinstance(projects, dict) else {},
                }
            )
        return out

    def get_user(self, name: str) -> dict | None:
        return self._load()["users"].get(name)

    # -- enrolment tokens ----------------------------------------------------
    def peek_token(self, token: str) -> str | None:
        """Username for a live token, WITHOUT consuming it (for the GET page)."""
        h = _hash_token(token or "")
        now = time.time()
        for name, u in self._load()["users"].items():
            e = u.get("enrol")
            if e and e.get("token_sha256") == h and e.get("expires", 0) > now:
                return name
        return None

    def consume_token(self, token: str) -> str | None:
        """Single-use redeem: returns username and burns the token, or None.

        The check and the burn MUST be under one lock or the token is not
        single-use under concurrency.
        """
        h = _hash_token(token or "")
        now = time.time()
        with _locked(self.path):
            data = self._load()
            for name, u in data["users"].items():
                e = u.get("enrol")
                if e and e.get("token_sha256") == h and e.get("expires", 0) > now:
                    u["enrol"] = None
                    self._save(data)
                    return name
        return None

    # -- credentials ---------------------------------------------------------
    def add_credential(self, name: str, cred_id_b64: str, public_key_b64: str, sign_count: int) -> None:
        with _locked(self.path):
            data = self._load()
            if name not in data["users"]:
                raise StoreError(f"no such user: {name}")
            for u in data["users"].values():
                for c in u.get("credentials", []):
                    if c["id"] == cred_id_b64:
                        raise StoreError("credential already registered")
            data["users"][name]["credentials"].append(
                {"id": cred_id_b64, "public_key": public_key_b64, "sign_count": int(sign_count), "added": _now_iso()}
            )
            self._save(data)

    def find_credential(self, cred_id_b64: str) -> tuple[str, dict] | None:
        for name, u in self._load()["users"].items():
            for c in u.get("credentials", []):
                if c["id"] == cred_id_b64:
                    return name, c
        return None

    def update_sign_count(self, cred_id_b64: str, new_count: int) -> None:
        with _locked(self.path):
            data = self._load()
            for u in data["users"].values():
                for c in u.get("credentials", []):
                    if c["id"] == cred_id_b64:
                        c["sign_count"] = int(new_count)
                        self._save(data)
                        return

    # -- memberships (read side; writes live on ProjectStore) ----------------
    def memberships(self, name: str) -> dict:
        """{pid: project_role} as RECORDED. The cap is applied in scope.py."""
        u = self.get_user(name) or {}
        p = u.get("projects")
        return dict(p) if isinstance(p, dict) else {}


class ProjectStore(_JsonStore):
    """Projects = the tenancy boundary. Same file, same lock as UserStore.

    A project is a NAMED SET OF SITES plus the GitLab surfaces that belong with
    them. Editing `sites` is therefore a permission grant, which is why only a
    global owner may do it (enforced by the route, asserted by a test).

    Invariants enforced here, on write, every time:
      * pid and site names match their regexes (no path/label injection);
      * a site belongs to AT MOST ONE project — the refusal names the other
        project, because silently reassigning a site moves data between tenants;
      * demo_sites is a subset of sites;
      * gitlab.ci_projects is a subset of the console's configured CI projects
        (when an allowlist is supplied);
      * deleting a project garbage-collects every membership that names it.
    """

    def __init__(self, path: Path, ci_allowlist=None):
        super().__init__(path)
        # None == "not configured here, skip the check" (used by pure unit
        # tests); a list == fail closed to that list.
        self.ci_allowlist = None if ci_allowlist is None else list(ci_allowlist)

    # -- validation ----------------------------------------------------------
    @staticmethod
    def _ok_pid(pid: str) -> str:
        if not isinstance(pid, str) or not PROJECT_ID_RE.match(pid):
            raise StoreError(f"invalid project id: {pid!r} (want ^[a-z0-9][a-z0-9_-]{{0,31}}$)")
        return pid

    @staticmethod
    def _ok_sites(sites) -> list:
        out = []
        for s in sites or []:
            if not isinstance(s, str) or not SITE_RE.match(s):
                raise StoreError(f"invalid site name: {s!r} (want ^[a-z0-9][a-z0-9-]{{0,30}}$)")
            if s not in out:
                out.append(s)
        return sorted(out)

    def _ok_gitlab(self, gl) -> dict:
        gl = dict(gl or {})
        label = str(gl.get("issue_label", "") or "")
        if len(label) > 100 or any(c in label for c in ",\n\r"):
            raise StoreError("invalid gitlab.issue_label")
        ci = [str(p) for p in (gl.get("ci_projects") or [])]
        if self.ci_allowlist is not None:
            bad = [p for p in ci if p not in self.ci_allowlist]
            if bad:
                raise StoreError(
                    f"gitlab.ci_projects not in the console's configured CI projects: {', '.join(bad)}"
                )
        out = {}
        # Absent keys are meaningful: no issue_label => this project sees NO
        # issues; no ci_projects => NO CI. Never "all". So only store what was
        # actually given.
        if label:
            out["issue_label"] = label
        if ci:
            out["ci_projects"] = sorted(set(ci))
        return out

    @staticmethod
    def _claim_conflict(data: dict, pid: str, sites: list) -> None:
        for other, proj in (data.get("projects") or {}).items():
            if other == pid:
                continue
            clash = sorted(set(sites) & set(proj.get("sites") or []))
            if clash:
                raise StoreError(
                    f"site(s) {', '.join(clash)} already belong to project '{other}' — "
                    f"a site belongs to at most one project"
                )

    # -- reads ---------------------------------------------------------------
    def all_projects(self) -> dict:
        return self._load()["projects"]

    def get_project(self, pid: str) -> dict | None:
        return self._load()["projects"].get(pid)

    def list_projects(self) -> list[dict]:
        data = self._load()
        out = []
        for pid, p in sorted(data["projects"].items()):
            members = {n: (u.get("projects") or {}).get(pid)
                       for n, u in data["users"].items() if pid in (u.get("projects") or {})}
            out.append({
                "id": pid,
                "name": p.get("name", pid),
                "description": p.get("description", ""),
                "sites": list(p.get("sites") or []),
                "demo_sites": list(p.get("demo_sites") or []),
                "gitlab": dict(p.get("gitlab") or {}),
                "created": p.get("created", ""),
                "created_by": p.get("created_by", ""),
                "members": dict(sorted(members.items())),
            })
        return out

    def unassigned_sites(self, known_sites) -> list:
        """Sites the console knows about that are in no project => owner-only."""
        claimed = set()
        for p in self._load()["projects"].values():
            claimed |= set(p.get("sites") or [])
        return sorted(set(known_sites) - claimed)

    # -- writes --------------------------------------------------------------
    def add_project(self, pid: str, name: str = "", description: str = "", sites=(),
                    demo_sites=(), gitlab=None, created_by: str = "") -> None:
        pid = self._ok_pid(pid)
        sites = self._ok_sites(sites)
        demo = self._ok_sites(demo_sites)
        if set(demo) - set(sites):
            raise StoreError(f"demo_sites not in sites: {', '.join(sorted(set(demo) - set(sites)))}")
        gl = self._ok_gitlab(gitlab)
        with _locked(self.path):
            data = self._load()
            if pid in data["projects"]:
                raise StoreError(f"project already exists: {pid}")
            self._claim_conflict(data, pid, sites)
            data["projects"][pid] = {
                "name": name or pid, "description": description, "sites": sites,
                "demo_sites": demo, "gitlab": gl,
                "created": _now_iso(), "created_by": created_by,
            }
            self._save(data)

    def set_project(self, pid: str, name=None, description=None, sites=None,
                    demo_sites=None, gitlab=None) -> None:
        pid = self._ok_pid(pid)
        with _locked(self.path):
            data = self._load()
            p = data["projects"].get(pid)
            if p is None:
                raise StoreError(f"no such project: {pid}")
            new = dict(p)
            if name is not None:
                new["name"] = str(name) or pid
            if description is not None:
                new["description"] = str(description)
            if sites is not None:
                new["sites"] = self._ok_sites(sites)
                self._claim_conflict(data, pid, new["sites"])
            if demo_sites is not None:
                new["demo_sites"] = self._ok_sites(demo_sites)
            if gitlab is not None:
                new["gitlab"] = self._ok_gitlab(gitlab)
            missing = set(new.get("demo_sites") or []) - set(new.get("sites") or [])
            if missing:
                raise StoreError(f"demo_sites not in sites: {', '.join(sorted(missing))}")
            data["projects"][pid] = new
            self._save(data)

    def remove_project(self, pid: str) -> int:
        """Delete a project and GC every membership naming it. Returns the
        number of memberships removed (a grant must never outlive its target)."""
        with _locked(self.path):
            data = self._load()
            if pid not in data["projects"]:
                raise StoreError(f"no such project: {pid}")
            del data["projects"][pid]
            gc = 0
            for u in data["users"].values():
                pr = u.get("projects")
                if isinstance(pr, dict) and pid in pr:
                    del pr[pid]
                    gc += 1
            self._save(data)
            return gc

    def set_project_role(self, user: str, pid: str, role: str) -> None:
        if not is_valid_project_role(role):
            raise StoreError(f"invalid project role: {role!r} (want one of viewer/operator/maintainer)")
        with _locked(self.path):
            data = self._load()
            if user not in data["users"]:
                raise StoreError(f"no such user: {user}")
            if pid not in data["projects"]:
                raise StoreError(f"no such project: {pid}")
            pr = data["users"][user].get("projects")
            if not isinstance(pr, dict):
                pr = {}
            pr[pid] = role
            data["users"][user]["projects"] = pr
            self._save(data)

    def unset_project_role(self, user: str, pid: str) -> None:
        with _locked(self.path):
            data = self._load()
            if user not in data["users"]:
                raise StoreError(f"no such user: {user}")
            pr = data["users"][user].get("projects") or {}
            if pid not in pr:
                raise StoreError(f"user '{user}' is not a member of '{pid}'")
            del pr[pid]
            data["users"][user]["projects"] = pr
            self._save(data)

    # -- export (the one authorised copy of the project->sites map) ----------
    def export_map(self) -> dict:
        """The read-only projection shipped to the workstation as
        private/project-map.json. Contains NO user, credential or token data —
        only the project->sites map the publisher and the doc-library gate need.
        """
        data = self._load()
        return {
            "schema": "nwp.project-map",
            "schema_version": 1,
            "generated_at": _now_iso(),
            "projects": {
                pid: {
                    "name": p.get("name", pid),
                    "sites": sorted(p.get("sites") or []),
                    "demo_sites": sorted(p.get("demo_sites") or []),
                }
                for pid, p in sorted(data["projects"].items())
            },
        }


class AuditLog:
    def __init__(self, path: Path):
        self.path = Path(path)

    def append(self, user: str, role: str, action: str, detail: dict, ok: bool,
               project: str | None = None) -> None:
        """`project` is the scope the action was taken in (None == unscoped /
        owner-wide). Entries written before projects existed have no key at
        all, and the audit view treats those as owner-only — a backfill would
        have to guess, and guessing about who saw what is not auditing."""
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        line = json.dumps(
            {"ts": _now_iso(), "user": user, "role": role, "action": action, "detail": detail,
             "ok": bool(ok), "project": project},
            sort_keys=True,
        )
        fd = os.open(self.path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        with os.fdopen(fd, "a") as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            f.write(line + "\n")

    def tail(self, n: int = 200) -> list[dict]:
        if not self.path.exists():
            return []
        out = []
        for line in self.path.read_text().splitlines()[-n:]:
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                out.append({"ts": "?", "user": "?", "action": "unparseable-audit-line", "raw": line[:200]})
        return list(reversed(out))
