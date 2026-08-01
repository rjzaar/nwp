import json
import stat
import sys
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.store import CRED_HANDLE_LEN, AuditLog, StoreError, UserStore  # noqa: E402


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


def test_addkey_token_keeps_credentials(store):
    """The whole point: enrolling a second key must not cost you the first."""
    store.add_user("rob", "owner")
    store.add_credential("rob", "credA", "pkA", 3)

    token = store.add_key_token("rob")
    assert store.peek_token(token) == "rob"
    assert token not in store.path.read_text()          # hashed at rest, like the others
    assert store.find_credential("credA") is not None   # <- the contrast with reset_user

    # Redeeming it adds a SECOND credential rather than replacing the first.
    assert store.consume_token(token) == "rob"
    store.add_credential("rob", "credB", "pkB", 0)
    assert len(store.get_user("rob")["credentials"]) == 2
    assert store.consume_token(token) is None           # still single-use

    with pytest.raises(StoreError):
        store.add_key_token("nobody")


def test_addkey_supersedes_an_unredeemed_token(store):
    """One outstanding token per user — re-issuing must kill the old one."""
    first = store.add_user("rob", "owner")
    second = store.add_key_token("rob")
    assert store.peek_token(first) is None
    assert store.peek_token(second) == "rob"


def test_credential_metadata_is_recorded_and_read_back(store):
    store.add_user("rob", "owner")
    store.add_credential("rob", "credA", "pkA", 0, meta={
        "aaguid": "8876631b-d4a0-427f-5773-0ec71c9e0279",
        "transports": ["usb", "nfc"], "device_type": "single_device", "backed_up": False})
    c = store.get_user("rob")["credentials"][0]
    assert c["transports"] == ["usb", "nfc"]
    assert c["aaguid"].startswith("8876631b")
    row = store.credentials_view("rob")[0]
    assert row["handle"] == "credA"          # shorter than CRED_HANDLE_LEN: whole id
    assert "security key" in row["label"] and "usb" in row["label"]


def test_credential_label_never_guesses(store):
    from app.store import credential_label
    # The case that must NOT be dressed up: everything enrolled before we
    # started recording metadata.
    assert "unknown" in credential_label({"id": "x", "public_key": "y", "sign_count": 0})
    assert "platform" in credential_label({"transports": ["internal"]})
    assert "phone" in credential_label({"transports": ["hybrid"]})
    assert "security key" in credential_label({"transports": ["usb"]})
    # A synced passkey must say so — it is not "on one device" in any sense.
    assert "synced" in credential_label({"transports": ["internal"], "device_type": "multi_device"})
    assert "backed up" in credential_label(
        {"transports": ["internal"], "device_type": "multi_device", "backed_up": True})
    assert "bound to that device" in credential_label(
        {"transports": ["usb"], "device_type": "single_device"})


def test_remove_credential_one_at_a_time(store):
    store.add_user("rob", "owner")
    store.add_credential("rob", "aaaa1111zzz", "pk1", 0, meta={"transports": ["usb"]})
    store.add_credential("rob", "aaaa2222zzz", "pk2", 0, meta={"transports": ["internal"]})
    store.add_credential("rob", "bbbb3333zzz", "pk3", 0)

    with pytest.raises(StoreError, match="ambiguous"):
        store.remove_credential("rob", "aaaa")      # matches two
    with pytest.raises(StoreError, match="too short"):
        store.remove_credential("rob", "aa")
    with pytest.raises(StoreError, match="no passkey"):
        store.remove_credential("rob", "cccc")
    with pytest.raises(StoreError, match="no such user"):
        store.remove_credential("nobody", "aaaa1111")

    gone = store.remove_credential("rob", "aaaa1111")
    assert gone["id"] == "aaaa1111zzz"
    assert [c["id"] for c in store.get_user("rob")["credentials"]] == ["aaaa2222zzz", "bbbb3333zzz"]
    # the survivors are untouched — that is the whole difference from reset
    assert store.find_credential("aaaa2222zzz") is not None


def test_handles_grow_until_unique(store):
    """Observed live: two Solo credentials on one account shared a prefix.

    A listing that shows the same handle twice hands you a revoke command that
    can only answer "ambiguous", so the handle has to widen instead.
    """
    store.add_user("rob", "owner")
    shared = "owBYUcommonprefix"
    store.add_credential("rob", shared + "AAAA", "pk1", 0)
    store.add_credential("rob", shared + "BBBB", "pk2", 0)
    handles = [r["handle"] for r in store.credentials_view("rob")]
    assert len(set(handles)) == 2, handles
    assert all(len(h) >= CRED_HANDLE_LEN for h in handles)
    # and each printed handle must actually resolve
    gone = store.remove_credential("rob", handles[0])
    assert gone["id"] == shared + "AAAA"


def test_remove_credential_refuses_the_last_one(store):
    """A lockout with no enrolment link attached is not a thing this offers."""
    store.add_user("rob", "owner")
    store.add_credential("rob", "onlykey123", "pk", 0)
    with pytest.raises(StoreError, match="LAST passkey"):
        store.remove_credential("rob", "onlykey")
    assert store.find_credential("onlykey123") is not None


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
