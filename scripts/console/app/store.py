"""User store + audit log — stdlib only, unit-tested.

users.json (0600) layout:
  {"users": {"<name>": {"role": "...", "created": "...",
                        "credentials": [{"id": b64url, "public_key": b64url,
                                         "sign_count": 0, "added": "..."}],
                        "enrol": {"token_sha256": "...", "expires": epoch} | null}}}

Enrolment tokens are ONE-TIME: stored hashed, consumed on first successful use.
The plaintext is printed exactly once by `pl console user add|reset` and never
stored anywhere.

audit.jsonl (0600): one JSON object per line
  {"ts": iso8601, "user": ..., "role": ..., "action": ..., "detail": {...}, "ok": bool}
"""
from __future__ import annotations

import fcntl
import hashlib
import json
import os
import re
import secrets
import time
from datetime import datetime, timezone
from pathlib import Path

from .authz import is_valid_role

USERNAME_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,31}$")


class StoreError(Exception):
    pass


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _hash_token(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


class UserStore:
    def __init__(self, path: Path):
        self.path = Path(path)

    # -- plumbing ------------------------------------------------------------
    def _load(self) -> dict:
        if not self.path.exists():
            return {"users": {}}
        try:
            return json.loads(self.path.read_text() or "{}") or {"users": {}}
        except json.JSONDecodeError as e:  # corrupt store: refuse, don't wipe
            raise StoreError(f"corrupt user store {self.path}: {e}")

    def _save(self, data: dict) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        tmp = self.path.with_suffix(".tmp")
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            json.dump(data, f, indent=1, sort_keys=True)
        os.replace(tmp, self.path)

    # -- user management -----------------------------------------------------
    def add_user(self, name: str, role: str, token_hours: int = 48) -> str:
        """Create a user + one-time enrolment token. Returns the PLAINTEXT token."""
        if not USERNAME_RE.match(name or ""):
            raise StoreError(f"invalid username: {name!r} (want ^[a-z0-9][a-z0-9_-]{{0,31}}$)")
        if not is_valid_role(role):
            raise StoreError(f"invalid role: {role!r}")
        data = self._load()
        if name in data["users"]:
            raise StoreError(f"user already exists: {name} (use reset to re-enrol)")
        token = secrets.token_urlsafe(32)
        data["users"][name] = {
            "role": role,
            "created": _now_iso(),
            "credentials": [],
            "enrol": {"token_sha256": _hash_token(token), "expires": int(time.time()) + token_hours * 3600},
        }
        self._save(data)
        return token

    def reset_user(self, name: str, token_hours: int = 48) -> str:
        """Break-glass: wipe credentials, issue a fresh one-time token."""
        data = self._load()
        if name not in data["users"]:
            raise StoreError(f"no such user: {name}")
        token = secrets.token_urlsafe(32)
        u = data["users"][name]
        u["credentials"] = []
        u["enrol"] = {"token_sha256": _hash_token(token), "expires": int(time.time()) + token_hours * 3600}
        self._save(data)
        return token

    def set_role(self, name: str, role: str) -> None:
        if not is_valid_role(role):
            raise StoreError(f"invalid role: {role!r}")
        data = self._load()
        if name not in data["users"]:
            raise StoreError(f"no such user: {name}")
        data["users"][name]["role"] = role
        self._save(data)

    def remove_user(self, name: str) -> None:
        data = self._load()
        if name not in data["users"]:
            raise StoreError(f"no such user: {name}")
        del data["users"][name]
        self._save(data)

    def list_users(self) -> list[dict]:
        data = self._load()
        out = []
        for name, u in sorted(data["users"].items()):
            out.append(
                {
                    "name": name,
                    "role": u.get("role", "?"),
                    "created": u.get("created", ""),
                    "passkeys": len(u.get("credentials", [])),
                    "enrol_pending": bool(u.get("enrol")),
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
        """Single-use redeem: returns username and burns the token, or None."""
        h = _hash_token(token or "")
        now = time.time()
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
        data = self._load()
        for u in data["users"].values():
            for c in u.get("credentials", []):
                if c["id"] == cred_id_b64:
                    c["sign_count"] = int(new_count)
                    self._save(data)
                    return


class AuditLog:
    def __init__(self, path: Path):
        self.path = Path(path)

    def append(self, user: str, role: str, action: str, detail: dict, ok: bool) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        line = json.dumps(
            {"ts": _now_iso(), "user": user, "role": role, "action": action, "detail": detail, "ok": bool(ok)},
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
