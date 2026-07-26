"""ProjectStore + the locking that makes a grant survive a concurrent write.

The concurrency test here is the reason Stage 0 existed: before `_locked()`,
every mutator did read-modify-write with no lock across the read, so two
simultaneous writers silently lost one update. With users that is annoying;
with projects it is a permission bug — a membership that was granted and then
vanished, or one that was revoked and came back.
"""
import json
import sys
import tempfile
import threading
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.store import ProjectStore, StoreError, UserStore  # noqa: E402


@pytest.fixture
def paths(tmp_path):
    return tmp_path / "users.json"


@pytest.fixture
def stores(paths):
    return UserStore(paths), ProjectStore(paths, ci_allowlist=["nwp/nwp", "nwp/nwc"])


# ---------------------------------------------------------------------------
# T5a — concurrency: every grant survives
# ---------------------------------------------------------------------------
def test_twenty_concurrent_writers_all_survive(stores):
    """Fails on the pre-Stage-0 code (lost updates), passes with _locked()."""
    users, projects = stores
    projects.add_project("p1", sites=["ss"], created_by="t")

    errors = []

    def add(i):
        try:
            users.add_user(f"u{i:02d}", "viewer")
            projects.set_project_role(f"u{i:02d}", "p1", "viewer")
        except Exception as e:  # noqa: BLE001
            errors.append(e)

    threads = [threading.Thread(target=add, args=(i,)) for i in range(20)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    assert not errors, errors
    listed = {u["name"] for u in users.list_users()}
    assert len(listed) == 20, f"lost updates: only {len(listed)} of 20 users survived"
    members = projects.list_projects()[0]["members"]
    assert len(members) == 20, f"lost grants: only {len(members)} of 20 memberships survived"


def test_enrolment_token_is_single_use_under_concurrency(stores):
    """The check and the burn must be under ONE lock or the token is not
    single-use — two racing redemptions would both succeed."""
    users, _ = stores
    token = users.add_user("dana", "viewer")
    winners = []

    def redeem():
        got = users.consume_token(token)
        if got:
            winners.append(got)

    threads = [threading.Thread(target=redeem) for _ in range(12)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert winners == ["dana"], f"token redeemed {len(winners)} times"


# ---------------------------------------------------------------------------
# T5b — corruption refuses rather than wipes
# ---------------------------------------------------------------------------
def test_corrupt_json_refuses_and_does_not_wipe(paths):
    paths.parent.mkdir(parents=True, exist_ok=True)
    paths.write_text('{"users": {"rob": ')      # truncated
    store = UserStore(paths)
    with pytest.raises(StoreError):
        store.list_users()
    with pytest.raises(StoreError):
        store.add_user("dana", "viewer")
    assert paths.read_text() == '{"users": {"rob": '   # untouched


@pytest.mark.parametrize("junk", ['[]', '"a string"', '{"users": []}', '{"projects": 3}'])
def test_bad_shapes_refuse(paths, junk):
    paths.parent.mkdir(parents=True, exist_ok=True)
    paths.write_text(junk)
    with pytest.raises(StoreError):
        UserStore(paths).list_users()


# ---------------------------------------------------------------------------
# T5c — the invariants, each with its own refusal
# ---------------------------------------------------------------------------
def test_a_site_belongs_to_at_most_one_project_and_the_error_names_it(stores):
    _users, projects = stores
    projects.add_project("ss-nw", sites=["nwc", "ssc"], created_by="t")
    with pytest.raises(StoreError) as e:
        projects.add_project("other", sites=["ssc", "avc"], created_by="t")
    assert "ssc" in str(e.value) and "ss-nw" in str(e.value), \
        "the refusal must name BOTH the clashing site and the project that holds it"


def test_moving_a_site_between_projects_is_refused_on_edit_too(stores):
    _users, projects = stores
    projects.add_project("a", sites=["ss"], created_by="t")
    projects.add_project("b", sites=["nwc"], created_by="t")
    with pytest.raises(StoreError):
        projects.set_project("b", sites=["nwc", "ss"])


def test_demo_sites_must_be_a_subset(stores):
    _users, projects = stores
    with pytest.raises(StoreError):
        projects.add_project("p", sites=["nwc"], demo_sites=["nwd"], created_by="t")
    projects.add_project("p", sites=["nwc", "nwd"], demo_sites=["nwd"], created_by="t")
    with pytest.raises(StoreError):
        projects.set_project("p", demo_sites=["ssd"])


def test_ci_projects_must_be_in_the_console_allowlist(stores):
    _users, projects = stores
    with pytest.raises(StoreError) as e:
        projects.add_project("p", sites=["ss"], gitlab={"ci_projects": ["evil/repo"]}, created_by="t")
    assert "evil/repo" in str(e.value)


@pytest.mark.parametrize("bad_pid", ["", "-x", "A", "x" * 33, "a b", "../etc", "p/../q", "p.json"])
def test_bad_project_ids_refused(stores, bad_pid):
    _users, projects = stores
    with pytest.raises(StoreError):
        projects.add_project(bad_pid, sites=["ss"], created_by="t")


@pytest.mark.parametrize("bad_site", ["", "-x", "A", "x" * 32, "a b", "../ss", "ss/../x", "ss_1"])
def test_bad_site_names_refused(stores, bad_site):
    _users, projects = stores
    with pytest.raises(StoreError):
        projects.add_project("p", sites=[bad_site], created_by="t")


def test_absent_gitlab_keys_mean_none_not_all(stores):
    _users, projects = stores
    projects.add_project("p", sites=["ss"], created_by="t")
    p = projects.get_project("p")
    assert p["gitlab"] == {}, "an unset label/CI list must be ABSENT, never a wildcard"


def test_deleting_a_project_gcs_every_membership(stores):
    users, projects = stores
    projects.add_project("p", sites=["ss"], created_by="t")
    users.add_user("dana", "viewer")
    users.add_user("sam", "operator")
    projects.set_project_role("dana", "p", "viewer")
    projects.set_project_role("sam", "p", "maintainer")
    assert projects.remove_project("p") == 2
    assert users.memberships("dana") == {}
    assert users.memberships("sam") == {}


def test_assign_refuses_unknown_user_or_project(stores):
    users, projects = stores
    projects.add_project("p", sites=["ss"], created_by="t")
    users.add_user("dana", "viewer")
    with pytest.raises(StoreError):
        projects.set_project_role("nobody", "p", "viewer")
    with pytest.raises(StoreError):
        projects.set_project_role("dana", "nope", "viewer")
    with pytest.raises(StoreError):
        projects.set_project_role("dana", "p", "admin")


# ---------------------------------------------------------------------------
# T5d — schema v1 <-> v2
# ---------------------------------------------------------------------------
def test_v1_file_loads_as_no_projects(paths):
    """A pre-projects users.json must load cleanly and read as legacy mode."""
    paths.parent.mkdir(parents=True, exist_ok=True)
    paths.write_text(json.dumps({
        "users": {"rob": {"role": "owner", "created": "2026-01-01T00:00:00Z",
                          "credentials": [{"id": "x", "public_key": "y", "sign_count": 1}],
                          "enrol": None}}
    }))
    users, projects = UserStore(paths), ProjectStore(paths)
    assert projects.all_projects() == {}
    assert users.get_user("rob")["role"] == "owner"
    assert users.memberships("rob") == {}
    assert users.list_users()[0]["passkeys"] == 1


def test_v2_roundtrip_keeps_v1_keys(stores, paths):
    """Adding projects must not drop anything a v1 reader depends on."""
    users, projects = stores
    users.add_user("rob", "owner")
    users.add_credential("rob", "cid", "pk", 3)
    projects.add_project("p", sites=["ss"], created_by="rob")
    projects.set_project_role("rob", "p", "maintainer")

    data = json.loads(paths.read_text())
    assert data["schema_version"] == 2
    u = data["users"]["rob"]
    for k in ("role", "created", "credentials", "enrol", "projects"):
        assert k in u, f"v2 write dropped {k}"
    assert u["credentials"][0]["sign_count"] == 3
    assert u["projects"] == {"p": "maintainer"}


def test_file_is_0600_and_atomic(stores, paths):
    users, _ = stores
    users.add_user("dana", "viewer")
    assert (paths.stat().st_mode & 0o777) == 0o600
    assert not paths.with_suffix(".tmp").exists(), "temp file left behind"


def test_export_map_carries_no_user_or_credential_data(stores):
    users, projects = stores
    users.add_user("dana", "viewer")
    users.add_credential("dana", "SECRET-CRED-ID", "SECRET-PUBKEY", 0)
    projects.add_project("p", name="P", sites=["ss", "nwc"], demo_sites=[], created_by="rob")
    projects.set_project_role("dana", "p", "viewer")

    blob = json.dumps(projects.export_map())
    assert "SECRET-CRED-ID" not in blob and "SECRET-PUBKEY" not in blob
    assert "dana" not in blob, "the exported map must contain no user data at all"
    assert json.loads(blob)["projects"]["p"]["sites"] == ["nwc", "ss"]


def test_unassigned_sites_are_reported(stores):
    _users, projects = stores
    projects.add_project("p", sites=["ss", "nwc"], created_by="t")
    # Sites in no project are owner-only — surfacing them is how an operator
    # notices a site nobody has been given.
    assert projects.unassigned_sites(["ss", "nwc", "avc", "mt"]) == ["avc", "mt"]
