"""Scope — the tenancy choke point. Pure unit tests, no HTTP, no filesystem.

These are the fail-closed tests: every one of them asserts that the WRONG
answer is refusal. If a change makes one of these go green by widening access
rather than by fixing a bug, the change is the bug.
"""
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import scope as scope_mod  # noqa: E402
from app.authz import effective_project_role, project_role_allows  # noqa: E402
from app.scope import Scope, ScopeError, resolve  # noqa: E402

# The real fleet, near enough: these names are the whole reason exact matching
# is mandatory (ss/ss2/ssc/ssd/saintschool, dir/dir1, nwc/nwd/nwt/nw1).
PROJECTS = {
    "ss-nw": {
        "name": "Saint School + Narrow Way",
        "sites": ["nwc", "ssc", "nwd", "ssd", "ss", "ss2", "saintschool"],
        "demo_sites": ["nwd"],
        "gitlab": {"issue_label": "project::ss-nw", "ci_projects": ["nwp/nwc"]},
    },
    "personal": {
        "name": "Operator's own",
        "sites": ["avc", "mt", "cathnet", "dir", "dir1"],
        "demo_sites": [],
        "gitlab": {"issue_label": "project::personal", "ci_projects": []},
    },
}
CONSOLE_DEMO = ["nwd", "ssd"]
CI_ALL = ["nwp/nwp", "nwp/nwc"]


def _resolve(role, memberships, requested=None, explicit=False, projects=PROJECTS, name="dana"):
    rec = {"name": name, "role": role, "projects": memberships}
    return resolve(rec, projects, console_demo_sites=CONSOLE_DEMO, ci_allowlist=CI_ALL,
                   requested=requested, requested_explicit=explicit)


# ---------------------------------------------------------------------------
# T1 — the effective-role table, in full
# ---------------------------------------------------------------------------
@pytest.mark.parametrize("global_role", ["viewer", "operator", "owner"])
@pytest.mark.parametrize("project_role", ["viewer", "operator", "maintainer"])
def test_effective_role_never_exceeds_global_cap(global_role, project_role):
    """A membership is a grant WITHIN a ceiling, never a way through it."""
    eff = effective_project_role(global_role, project_role)
    cap = {"viewer": "viewer", "operator": "operator", "owner": "maintainer"}[global_role]
    order = ["viewer", "operator", "maintainer"]
    assert eff is not None
    assert order.index(eff) <= order.index(cap), f"{global_role}+{project_role} escalated to {eff}"


def test_viewer_recorded_as_maintainer_stays_a_viewer():
    """The headline escalation: promoting someone inside a project must not
    promote them on the console."""
    assert effective_project_role("viewer", "maintainer") == "viewer"
    sc = _resolve("viewer", {"ss-nw": "maintainer"})
    assert sc.project_role == "viewer"
    assert not sc.can("operator")
    assert not sc.can("maintainer")


@pytest.mark.parametrize("bad", [None, "", "admin", "root", "Owner", "MAINTAINER", 0, [], {}])
def test_unknown_roles_fail_closed(bad):
    """Junk on either axis must REFUSE — and must refuse by returning, not by
    raising. An exception is not a decision: caught by a broad handler upstream
    it can become an allow just as easily as a deny. (Unhashable values like
    {} and [] used to raise TypeError here.)"""
    assert effective_project_role(bad, "viewer") is None
    assert effective_project_role("operator", bad) is None
    assert project_role_allows(bad, "viewer") is False
    assert project_role_allows("maintainer", bad) is False


def test_unknown_global_role_yields_empty_scope():
    sc = _resolve("superuser", {"ss-nw": "maintainer"})
    assert sc.sites == frozenset()
    assert sc.project_role is None
    assert sc.all_sites is False


# ---------------------------------------------------------------------------
# T2 — EXACT site matching (the substring bug the real names make inevitable)
# ---------------------------------------------------------------------------
@pytest.mark.parametrize("allowed,rejected", [
    (["ss", "ssc"], ["ss2", "ssd", "saintschool", "ssc1", "s", "sscx"]),
    (["dir"], ["dir1", "dir10", "directory"]),
    (["nwc"], ["nwc-dev", "nw1", "nwd", "nwt", "nwcx", "nw"]),
    (["nw1"], ["nw", "nw11", "nwc"]),
])
def test_exact_site_matching(allowed, rejected):
    sc = Scope(user="d", global_role="operator", project_id="p", project_role="operator",
               sites=frozenset(allowed))
    for s in allowed:
        assert sc.allows_site(s), f"{s} should be allowed"
    for s in rejected:
        assert not sc.allows_site(s), f"{s} LEAKED via substring match"
        with pytest.raises(ScopeError):
            sc.require_site(s)


def test_allows_site_rejects_non_strings():
    sc = Scope(user="d", global_role="operator", project_id="p", project_role="operator",
               sites=frozenset(["ss"]))
    for junk in (None, 1, ["ss"], {"ss": 1}, b"ss"):
        assert not sc.allows_site(junk)


def test_filter_rows_drops_foreign_and_siteless():
    sc = _resolve("operator", {"ss-nw": "operator"})
    rows = [{"site": "ssc"}, {"site": "avc"}, {"site": "ss2"}, {"no": "site"}, "junk", None]
    kept = sc.filter_rows(rows)
    assert [r["site"] for r in kept] == ["ssc", "ss2"]


# ---------------------------------------------------------------------------
# T3 — fail-closed defaults
# ---------------------------------------------------------------------------
def test_zero_memberships_while_projects_exist_sees_nothing():
    sc = _resolve("operator", {})
    assert sc.sites == frozenset()
    assert sc.all_sites is False
    assert sc.project_role is None
    assert sc.library_shards == ()


def test_missing_user_record_is_empty():
    for junk in (None, "dana", 42, []):
        sc = resolve(junk, PROJECTS)
        assert sc.sites == frozenset() and sc.project_role is None and not sc.all_sites


def test_explicit_request_for_foreign_project_raises():
    with pytest.raises(ScopeError):
        _resolve("operator", {"ss-nw": "operator"}, requested="personal", explicit=True)


def test_explicit_request_when_member_of_nothing_raises():
    with pytest.raises(ScopeError):
        _resolve("operator", {}, requested="ss-nw", explicit=True)


def test_stale_cookie_falls_back_and_never_widens():
    """A cookie naming a project you left (or never had) is IGNORED — it must
    not 403 you out of the console, and it must not hand you the project."""
    sc = _resolve("operator", {"ss-nw": "operator"}, requested="personal", explicit=False)
    assert sc.project_id == "ss-nw"
    assert "avc" not in sc.sites
    sc2 = _resolve("operator", {"ss-nw": "operator"}, requested="deleted-project", explicit=False)
    assert sc2.project_id == "ss-nw"


def test_unassigned_site_is_in_no_member_scope():
    """A site in no project is owner-only, with no configuration required."""
    projects = {"ss-nw": PROJECTS["ss-nw"]}
    sc = _resolve("operator", {"ss-nw": "operator"}, projects=projects)
    for orphan in ("avc", "mt", "cathnet", "hidden", "mg", "fin"):
        assert not sc.allows_site(orphan)


def test_legacy_mode_is_byte_identical_all_sites():
    """No projects at all => the pre-project console, exactly."""
    sc = _resolve("operator", {}, projects={})
    assert sc.legacy is True
    assert sc.all_sites is True
    assert sc.allows_site("anything-at-all")
    assert sc.project_role == "operator"


def test_owner_unscoped_by_default_but_can_enter_any_project():
    sc = _resolve("owner", {}, name="rob")
    assert sc.all_sites is True and sc.project_role == "maintainer"
    scoped = _resolve("owner", {}, requested="personal", explicit=True, name="rob")
    assert scoped.project_id == "personal" and scoped.all_sites is False
    assert scoped.allows_site("avc") and not scoped.allows_site("ssc")


def test_owner_explicit_unknown_project_raises():
    with pytest.raises(ScopeError):
        _resolve("owner", {}, requested="nope", explicit=True, name="rob")


def test_demo_sites_are_intersected_with_the_console_tier():
    """project.demo_sites ∩ config.DEMO_SITES — both must hold."""
    sc = _resolve("operator", {"ss-nw": "operator"})
    assert sc.demo_sites == frozenset(["nwd"])
    sc2 = _resolve("operator", {"personal": "operator"})
    assert sc2.demo_sites == frozenset()


def test_ci_projects_intersected_with_console_allowlist():
    sc = _resolve("operator", {"ss-nw": "operator"})
    assert sc.ci_projects == frozenset(["nwp/nwc"])
    assert sc.ci_allowed("nwp/nwc") and not sc.ci_allowed("nwp/nwp")


def test_missing_issue_label_means_no_issues_not_all_issues():
    projects = {"p": {"name": "p", "sites": ["ss"], "gitlab": {}}}
    sc = _resolve("operator", {"p": "operator"}, projects=projects)
    assert sc.issue_labels == frozenset()
    assert sc.filter_issues([{"iid": 1, "labels": ["anything"]}]) == []


def test_issue_filtering_matches_labels_exactly():
    sc = _resolve("operator", {"ss-nw": "operator"})
    issues = [
        {"iid": 1, "labels": ["project::ss-nw"]},
        {"iid": 2, "labels": ["project::personal"]},
        {"iid": 3, "labels": []},
        {"iid": 4, "labels": ["project::ss-nw-extra"]},
        {"iid": 5, "labels": ["bug", "project::ss-nw"]},
    ]
    assert [i["iid"] for i in sc.filter_issues(issues)] == [1, 5]


def test_audit_entries_without_project_are_owner_only():
    sc = _resolve("operator", {"ss-nw": "operator"})
    assert sc.audit_allowed({"project": "ss-nw"})
    assert not sc.audit_allowed({"project": "personal"})
    assert not sc.audit_allowed({"project": None})
    assert not sc.audit_allowed({})            # legacy, pre-project entry
    owner = _resolve("owner", {}, name="rob")
    assert owner.audit_allowed({})             # ...but the owner still sees it


# ---------------------------------------------------------------------------
# T4 — scrub drops foreign rows however deeply nested
# ---------------------------------------------------------------------------
def test_scrub_drops_nested_foreign_rows():
    sc = _resolve("operator", {"ss-nw": "operator"})
    ctx = {
        "rag": {"sites": [{"site": "ssc", "grade": "GREEN"},
                          {"site": "avc", "grade": "RED"}]},
        "deep": {"deeper": {"rows": [{"site": "mt"}, {"site": "nwd"}]}},
        "untouched": "hello",
    }
    clean, dropped = scope_mod.scrub(ctx, sc)
    assert dropped == 2
    assert [s["site"] for s in clean["rag"]["sites"]] == ["ssc"]
    assert [s["site"] for s in clean["deep"]["deeper"]["rows"]] == ["nwd"]
    assert clean["untouched"] == "hello"
    assert "avc" not in str(clean) and "mt" not in str(clean)


def test_scrub_is_a_noop_for_unscoped_readers():
    owner = _resolve("owner", {}, name="rob")
    ctx = {"rows": [{"site": "avc"}, {"site": "ssc"}]}
    clean, dropped = scope_mod.scrub(ctx, owner)
    assert dropped == 0 and clean == ctx


def test_redact_removes_free_text_passthroughs_for_scoped_readers():
    sc = _resolve("operator", {"ss-nw": "operator"})
    ctx = {
        "rag": {"raw": "avc RED\nmt AMBER", "sites": []},
        "res": {"cmd": "pl rag --json", "err": "avc: boom", "out": "kept"},
        "prov": {"host": "workstation.internal", "note": "n", "age_human": "2m"},
        "demo_sites": [{"site": "nwd", "status": {"raw": "...avc...", "ok": True}}],
    }
    out = scope_mod.redact(ctx, sc)
    assert "raw" not in out["rag"]
    assert "cmd" not in out["res"] and "err" not in out["res"] and out["res"]["out"] == "kept"
    assert "host" not in out["prov"] and out["prov"]["age_human"] == "2m"
    assert "raw" not in out["demo_sites"][0]["status"]


def test_redact_leaves_owner_context_alone():
    owner = _resolve("owner", {}, name="rob")
    ctx = {"res": {"cmd": "pl rag"}, "prov": {"host": "ws"}}
    assert scope_mod.redact(ctx, owner) == ctx


def test_fleet_scope_is_explicitly_unscoped():
    """The named escape hatch for the owner-only background paths."""
    fs = scope_mod.fleet_scope()
    assert fs.all_sites is True and fs.global_role == "owner" and fs.legacy is False
    assert fs.allows_site("literally-anything")


# ---------------------------------------------------------------------------
# library shards (derived grant — Stage 4 consumes it, the cap is tested now)
# ---------------------------------------------------------------------------
def test_library_shards_follow_membership_and_never_leak_private():
    member = _resolve("operator", {"ss-nw": "operator"})
    assert member.library_shards == ("contributor", "project-ss-nw", "public")
    owner = _resolve("owner", {}, name="rob")
    assert "private" in owner.library_shards
    nobody = _resolve("operator", {})
    assert nobody.library_shards == ()
