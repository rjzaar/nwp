"""Scope — THE tenancy choke point. Pure, stdlib only, unit-tested.

Every request that can show or touch site-derived data resolves to exactly one
`Scope` first, and every gatherer, pane and action then reads its allowed set
from that object. There is deliberately no second path: if you find yourself
filtering by site anywhere else, that is the bug.

Why render-time filtering (one snapshot, filtered here) rather than one file
per project: the project->sites map has exactly ONE author (users.json on the
console host). Duplicating it into the publisher would create a second author
and therefore drift — and drift in a tenancy map is a disclosure. The
publish-time escape hatch still exists (`fleet-state.<pid>.json`, see
fleet_state.load_for) for a project that must be file-isolated, and it reads
its site list from the exported map rather than inventing one.

Fail-closed rules this module exists to guarantee:

  * A site is allowed only by EXACT membership of `Scope.sites`. Never
    startswith, never `in` on a string. The real fleet holds ss / ss2 / ssc /
    ssd / saintschool and dir / dir1 and nwc / nwd / nwt / nw1 — every
    substring test on those names either leaks a neighbour or hides one.
  * Zero memberships while projects exist == see nothing (not "see all").
  * An explicit ?project= for a project you are not in is a 403 + an audited
    denial, never a silent fallback to something you may see.
  * A stale/forged project cookie is ignored, never widened.
  * Unknown roles, missing user records and malformed stores all resolve to
    the empty scope.
  * NO projects at all == legacy mode: byte-identical to the pre-project
    console, so this whole layer is inert until an owner creates a project.

This module must not import main/actions/runner/subprocess — asserted by the
AST test in tests/test_route_scoping.py.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, replace

from .authz import (
    CAP,
    effective_project_role,
    is_valid_role,
    library_shards,
    project_role_allows,
)

SITE_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,30}$")
PROJECT_ID_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,31}$")

# Free-text passthroughs that must not reach a scoped (non-owner) reader: they
# are unfiltered command output, publisher hostnames and provenance notes, any
# of which can name a site outside the project. Structured rows are scrubbed;
# these are simply removed.
REDACT_PATHS = (
    ("rag", "raw"),
    ("todo", "raw"),
    ("res", "cmd"),
    ("res", "err"),
    ("prov", "host"),
    ("prov", "note"),
)


class ScopeError(Exception):
    """Requested a project the caller may not use — the route returns 403."""


class ScopeLeak(Exception):
    """A foreign row reached a render context. Raised only under strict mode
    (NWP_CONSOLE_SCOPE_STRICT=1, set in CI): in production the row is dropped
    and audited, because a leak must never be repaired by a 500 that shows a
    stack trace instead."""


@dataclass(frozen=True)
class Scope:
    user: str
    global_role: str
    project_id: str | None
    project_role: str | None            # post-cap; None == no access at all
    sites: frozenset = frozenset()      # THE allowed set; empty == see nothing
    all_sites: bool = False             # True == unscoped (owner / legacy)
    memberships: tuple = ()             # ((pid, name), ...) for the picker
    demo_sites: frozenset = frozenset()
    issue_labels: frozenset = frozenset()
    ci_projects: frozenset = frozenset()
    library_shards: tuple = ()
    legacy: bool = False                # True when no projects exist at all
    project_name: str = ""
    denied_reason: str = ""

    # -- site gate -----------------------------------------------------------
    def allows_site(self, site) -> bool:
        if self.all_sites:
            return True
        return isinstance(site, str) and site in self.sites

    def require_site(self, site) -> str:
        if not self.allows_site(site):
            raise ScopeError(f"site not in scope: {site!r}")
        return site

    def filter_rows(self, rows, key: str = "site") -> list:
        """Keep only rows whose site is in scope. A row with no site (or a
        non-string one) is dropped for a scoped reader: fleet-global rows are
        owner material, and 'probably harmless' is not a security rule."""
        if not isinstance(rows, list):
            return []
        if self.all_sites:
            return list(rows)
        return [r for r in rows if isinstance(r, dict) and self.allows_site(r.get(key))]

    # -- capability gate -----------------------------------------------------
    def can(self, need: str) -> bool:
        return project_role_allows(self.project_role, need)

    # -- GitLab surfaces -----------------------------------------------------
    def issue_allowed(self, issue) -> bool:
        if self.all_sites:
            return True
        if not self.issue_labels or not isinstance(issue, dict):
            return False
        labels = issue.get("labels") or []
        return bool(isinstance(labels, list) and self.issue_labels & {str(x) for x in labels})

    def filter_issues(self, issues) -> list:
        if not isinstance(issues, list):
            return []
        return [i for i in issues if self.issue_allowed(i)]

    def ci_allowed(self, project) -> bool:
        return isinstance(project, str) and project in self.ci_projects

    # -- audit ---------------------------------------------------------------
    def audit_allowed(self, entry) -> bool:
        """Unscoped readers see everything. A scoped reader sees only entries
        stamped with their project — including, deliberately, none of the
        pre-project entries that carry no stamp."""
        if self.all_sites:
            return True
        return isinstance(entry, dict) and entry.get("project") == self.project_id

    @property
    def label(self) -> str:
        if self.legacy:
            return ""
        if self.all_sites:
            return "All projects"
        return self.project_name or (self.project_id or "no project")


def empty_scope(user: str = "", global_role: str = "", reason: str = "no project membership") -> Scope:
    """The fail-closed answer: authenticated, but may see nothing."""
    return Scope(user=user, global_role=global_role, project_id=None, project_role=None,
                 sites=frozenset(), all_sites=False, denied_reason=reason)


def fleet_scope(user: str = "(system)") -> Scope:
    """An explicitly fleet-wide scope for the owner-only background paths (the
    notifier's push checker and the morning brief). Named so a reviewer can
    grep for every place the boundary is intentionally not applied."""
    return Scope(user=user, global_role="owner", project_id=None, project_role="maintainer",
                 sites=frozenset(), all_sites=True, legacy=False)


def _valid_membership_map(user_rec) -> dict:
    p = (user_rec or {}).get("projects")
    if not isinstance(p, dict):
        return {}
    return {k: v for k, v in p.items() if isinstance(k, str) and PROJECT_ID_RE.match(k)}


def resolve(user_rec, projects, console_demo_sites=(), ci_allowlist=(),
            requested=None, requested_explicit=False) -> Scope:
    """Resolve one request to one Scope.

    user_rec  {"name","role"} from the session (or None/garbage — fails closed)
    projects  {pid: project} exactly as stored
    requested the pid from ?project= or the signed cookie
    requested_explicit True when it came from the QUERY STRING (a deliberate
              act, so a non-member gets a 403 + an audit line) rather than from
              a cookie (which may simply be stale, and is silently ignored).
    """
    if not isinstance(user_rec, dict):
        return empty_scope(reason="no user record")
    name = str(user_rec.get("name", "") or "")
    grole = str(user_rec.get("role", "") or "")
    if not is_valid_role(grole):
        return empty_scope(user=name, global_role=grole, reason=f"unknown role {grole!r}")

    projects = projects if isinstance(projects, dict) else {}
    console_demo = frozenset(console_demo_sites or ())
    ci_all = frozenset(ci_allowlist or ())

    # --- legacy: no projects exist => behave exactly as before ---------------
    if not projects:
        sc = Scope(user=name, global_role=grole, project_id=None,
                   project_role=CAP.get(grole), sites=frozenset(), all_sites=True,
                   memberships=(), demo_sites=console_demo, issue_labels=frozenset(),
                   ci_projects=ci_all, legacy=True)
        return _with_shards(sc)

    is_owner = grole == "owner"
    recorded = _valid_membership_map(user_rec)
    if is_owner:
        # An owner may enter any project (and administers all of them), so the
        # picker lists everything. This is a view, not an escalation: an owner
        # can already see the whole fleet unscoped.
        member_pids = sorted(projects)
    else:
        member_pids = sorted(p for p in recorded if p in projects)
    memberships = tuple((p, str(projects[p].get("name", p))) for p in member_pids)

    req = requested if isinstance(requested, str) and requested else None
    if req is not None and not PROJECT_ID_RE.match(req):
        if requested_explicit:
            raise ScopeError(f"invalid project id: {req!r}")
        req = None

    # --- owner: unscoped unless a project is explicitly chosen --------------
    if is_owner:
        if req in (None, "*"):
            sc = Scope(user=name, global_role=grole, project_id=None, project_role="maintainer",
                       sites=frozenset(), all_sites=True, memberships=memberships,
                       demo_sites=console_demo, issue_labels=frozenset(), ci_projects=ci_all)
            return _with_shards(sc)
        if req not in projects:
            if requested_explicit:
                raise ScopeError(f"no such project: {req}")
            sc = Scope(user=name, global_role=grole, project_id=None, project_role="maintainer",
                       sites=frozenset(), all_sites=True, memberships=memberships,
                       demo_sites=console_demo, issue_labels=frozenset(), ci_projects=ci_all)
            return _with_shards(sc)
        return _scoped(name, grole, req, "maintainer", projects[req], memberships, console_demo, ci_all)

    # --- member --------------------------------------------------------------
    if not member_pids:
        # Authenticated, projects exist, belongs to none: sees NOTHING. This is
        # the default a new user lands in, and it is the correct one.
        if requested_explicit and req:
            raise ScopeError(f"not a member of project: {req}")
        return empty_scope(user=name, global_role=grole,
                           reason="you are not a member of any project")

    if req is not None and req not in member_pids:
        if requested_explicit:
            raise ScopeError(f"not a member of project: {req}")
        req = None            # stale cookie: fall back, NEVER widen
    pid = req or member_pids[0]

    eff = effective_project_role(grole, recorded.get(pid))
    if eff is None:
        return empty_scope(user=name, global_role=grole, reason="membership role not recognised")
    return _scoped(name, grole, pid, eff, projects[pid], memberships, console_demo, ci_all)


def _scoped(name, grole, pid, project_role, project, memberships, console_demo, ci_all) -> Scope:
    sites = frozenset(s for s in (project.get("sites") or [])
                      if isinstance(s, str) and SITE_RE.match(s))
    demo = frozenset(s for s in (project.get("demo_sites") or []) if s in sites) & console_demo
    gl = project.get("gitlab") or {}
    label = str(gl.get("issue_label", "") or "")
    ci = frozenset(str(p) for p in (gl.get("ci_projects") or [])) & ci_all
    sc = Scope(
        user=name, global_role=grole, project_id=pid, project_role=project_role,
        sites=sites, all_sites=False, memberships=memberships, demo_sites=demo,
        issue_labels=frozenset([label]) if label else frozenset(),
        ci_projects=ci, project_name=str(project.get("name", pid)),
    )
    return _with_shards(sc)


def _with_shards(sc: Scope) -> Scope:
    return replace(sc, library_shards=tuple(library_shards(sc)))


# ---------------------------------------------------------------------------
# net 2: scrub + redact over a render context
# ---------------------------------------------------------------------------
def scrub(obj, scope: Scope):
    """Recursively drop any dict carrying a `site` key outside the scope.

    This is the belt to the gatherers' braces: if a new pane forgets to filter
    (or a feed grows a nested site-keyed row nobody anticipated), the row still
    does not reach the template. Returns (clean_obj, dropped_count).
    """
    if scope.all_sites:
        return obj, 0
    dropped = 0

    def walk(o):
        nonlocal dropped
        if isinstance(o, dict):
            if "site" in o and not scope.allows_site(o.get("site")):
                dropped += 1
                return None, True
            out = {}
            for k, v in o.items():
                nv, drop = walk(v)
                if not drop:
                    out[k] = nv
            return out, False
        if isinstance(o, list):
            out = []
            for v in o:
                nv, drop = walk(v)
                if not drop:
                    out.append(nv)
            return out, False
        return o, False

    clean, _ = walk(obj)
    return clean, dropped


def redact(ctx: dict, scope: Scope) -> dict:
    """Strip free-text passthroughs from a READ pane's context for a scoped
    reader. Action/invite results are exempt by construction — their argv was
    already validated against the scope's own site list, so their output is
    about this project by definition."""
    if scope.all_sites or not isinstance(ctx, dict):
        return ctx
    out = dict(ctx)
    for top, key in REDACT_PATHS:
        v = out.get(top)
        if isinstance(v, dict) and key in v:
            v = dict(v)
            v.pop(key, None)
            out[top] = v
    demo = out.get("demo_sites")
    if isinstance(demo, list):
        cleaned = []
        for d in demo:
            if isinstance(d, dict) and isinstance(d.get("status"), dict):
                st = dict(d["status"])
                st.pop("raw", None)
                d = dict(d, status=st)
            cleaned.append(d)
        out["demo_sites"] = cleaned
    sec = out.get("security")
    if isinstance(sec, list):
        out["security"] = [dict(s, raw="") if isinstance(s, dict) and "raw" in s else s for s in sec]
    return out
