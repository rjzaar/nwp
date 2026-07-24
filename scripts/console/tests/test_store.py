import json
import stat
import sys
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.store import AuditLog, StoreError, UserStore  # noqa: E402


@pytest.fixture
def store(tmp_path):
    return UserStore(tmp_path / "users.json")


def test_add_user_and_token_roundtrip(store):
    token = store.add_user("rob", "owner")
    assert len(token) > 30
    # plaintext never stored
    raw = store.path.read_text()
    assert token not in raw
    assert store.peek_token(token) == "rob"
    assert store.consume_token(token) == "rob"
    # single use
    assert store.consume_token(token) is None
    assert store.peek_token(token) is None


def test_token_expiry(store):
    token = store.add_user("rob", "owner", token_hours=0)
    time.sleep(0.01)
    assert store.peek_token(token) is None


def test_duplicate_user_and_bad_names(store):
    store.add_user("rob", "owner")
    with pytest.raises(StoreError):
        store.add_user("rob", "viewer")
    for bad in ("Rob", "", "-x", "a b", "x" * 33, "röb"):
        with pytest.raises(StoreError):
            store.add_user(bad, "viewer")
    with pytest.raises(StoreError):
        store.add_user("ok", "admin")


def test_credentials_and_reset(store):
    store.add_user("rob", "owner")
    store.add_credential("rob", "credA", "pkA", 3)
    assert store.find_credential("credA")[0] == "rob"
    store.add_user("eve", "viewer")
    with pytest.raises(StoreError):  # cross-user duplicate credential id
        store.add_credential("eve", "credA", "pkE", 0)
    store.update_sign_count("credA", 9)
    assert store.find_credential("credA")[1]["sign_count"] == 9
    token = store.reset_user("rob")
    assert store.find_credential("credA") is None
    assert store.peek_token(token) == "rob"


def test_role_change_and_remove(store):
    store.add_user("dev2", "viewer")
    store.set_role("dev2", "operator")
    assert store.get_user("dev2")["role"] == "operator"
    with pytest.raises(StoreError):
        store.set_role("dev2", "superuser")
    store.remove_user("dev2")
    assert store.get_user("dev2") is None
    with pytest.raises(StoreError):
        store.remove_user("dev2")


def test_store_file_is_0600(store):
    store.add_user("rob", "owner")
    mode = stat.S_IMODE(store.path.stat().st_mode)
    assert mode == 0o600


def test_corrupt_store_refuses_not_wipes(store, tmp_path):
    store.add_user("rob", "owner")
    store.path.write_text("{corrupt")
    with pytest.raises(StoreError):
        store.list_users()
    assert "corrupt" in store.path.read_text()  # untouched


def test_audit_append_and_tail(tmp_path):
    log = AuditLog(tmp_path / "audit.jsonl")
    assert log.tail() == []
    log.append("rob", "owner", "action.rag_refresh", {"rc": 0}, True)
    log.append("dev2", "operator", "issue.close", {"iid": 5}, False)
    entries = log.tail()
    assert len(entries) == 2
    assert entries[0]["action"] == "issue.close"  # newest first
    assert entries[1]["ok"] is True
    mode = stat.S_IMODE(log.path.stat().st_mode)
    assert mode == 0o600
    # every line is standalone JSON
    for line in log.path.read_text().splitlines():
        json.loads(line)


def test_audit_tolerates_garbage_lines(tmp_path):
    log = AuditLog(tmp_path / "audit.jsonl")
    log.append("rob", "owner", "x", {}, True)
    with open(log.path, "a") as f:
        f.write("not-json\n")
    entries = log.tail()
    assert entries[0]["action"] == "unparseable-audit-line"
