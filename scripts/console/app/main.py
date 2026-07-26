"""NWP Console — FastAPI app (mesh-only, passkey-only, role-gated, scoped).

Transport gate = the Headscale mesh (uvicorn binds the tailnet IP only).
App gate     = WebAuthn passkeys + three server-enforced roles + audit log.
Action gate  = the fail-closed allowlist in actions.py (no live/prod verbs).
Tenancy gate = the Scope choke point in scope.py (see below).

TENANCY, in three nets, because one is never enough:

  1. `scoped(need)` — the FastAPI dependency on every route that can show or
     touch site-derived data. It resolves ONE Scope per request and 403s a
     request for a project the caller may not use.
  2. `_pane()` — scrubs any dict carrying a foreign `site` key out of the
     render context and redacts free-text passthroughs, so a gatherer that
     forgets to filter still cannot leak through a template.
  3. tests/test_route_scoping.py — an AST pass over THIS FILE asserting that
     every route has a dependency, that no route body calls a raw gatherer,
     and that no route reads config.DEMO_SITES/CI_PROJECTS directly. A net you
     can forget to hang is not a net.

Scoping is INERT until an owner creates a project: with none, every scope is
legacy/all-sites and behaviour is byte-identical to the pre-project console.
"""
from __future__ import annotations

import asyncio
import contextlib
import json
import time
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path

from fastapi import Depends, FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse, Response, StreamingResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from itsdangerous import BadSignature, URLSafeTimedSerializer

from . import (advisories, config, fleet_state, notify, parsers, quokka,
               scope as scope_mod, voice, webauthn_flow)
from .actions import ACTIONS, ActionError, build_action
from .authz import PROJECT_ROLES, project_role_allows, role_allows
from .gitlab_api import GitLab
from .runner import run_pl, run_pl_cached
from .scope import Scope, ScopeError, ScopeLeak
from .store import AuditLog, ProjectStore, StoreError, UserStore

# Tab order = the whole UI: one full-screen pane at a time.
PANES = [
    ("fleet", "Fleet"), ("issues", "Issues"), ("todo", "Todo"), ("demo", "Demo"),
    ("backups", "Backups"), ("ci", "CI"), ("quokka", "Quokka"),
]

# The ONLY routes allowed to carry no scope dependency: unauthenticated
# surfaces (health/login/enrol/PWA/static) plus the fail-closed landing page a
# project-less user is sent to. Asserted by tests/test_route_scoping.py, so
# adding a route here is a decision a reviewer sees.
UNSCOPED_ALLOWLIST = frozenset({
    "health", "login_page", "logout", "enroll_page",
    "register_options", "register_verify", "login_options", "login_verify",
    "manifest", "service_worker", "no_project",
})

BASE = Path(__file__).resolve().parent.parent


async def _notify_loop() -> None:
    """Periodic push checker. One task, no extra unit, no extra port.

    Every pass runs in a worker thread (the gatherers shell out to `pl`) and
    swallows its own failures — the notifier must never be able to take the
    console down or block a request.
    """
    await asyncio.sleep(min(60, max(1, config.NOTIFY_INTERVAL)))  # let the host settle
    while True:
        try:
            await asyncio.to_thread(_notify_pass)
        except asyncio.CancelledError:
            raise
        except Exception:  # noqa: BLE001 — a bad pass must not kill the loop
            pass
        await asyncio.sleep(config.NOTIFY_INTERVAL)


@asynccontextmanager
async def _lifespan(_app: FastAPI):
    task = None
    if config.NOTIFY_INTERVAL > 0:
        task = asyncio.create_task(_notify_loop())
    try:
        yield
    finally:
        if task is not None:
            task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await task


app = FastAPI(title="NWP Console", docs_url=None, redoc_url=None, openapi_url=None, lifespan=_lifespan)
app.mount("/static", StaticFiles(directory=str(BASE / "static")), name="static")
templates = Jinja2Templates(directory=str(BASE / "templates"))

_signer = URLSafeTimedSerializer(config.secret_key(), salt="nwp-console-session")
_challenge_signer = URLSafeTimedSerializer(config.secret_key(), salt="nwp-console-challenge")

store = UserStore(config.DATA_DIR / "users.json")
# Same file, same lock — projects and memberships live beside the users they
# grant, so a membership can never reference a project that a concurrent write
# has just deleted.
projects = ProjectStore(config.DATA_DIR / "users.json", ci_allowlist=config.CI_PROJECTS)
audit = AuditLog(config.DATA_DIR / "audit.jsonl")
gitlab = GitLab(config.GITLAB_HOST, config.GITLAB_TOKEN_FILE)
notifier = notify.Notifier(config.GOTIFY_URL, config.GOTIFY_TOKEN_FILE, config.GOTIFY_TIMEOUT)
notify_state = notify.NotifyState(config.NOTIFY_STATE_FILE)


# ---------------------------------------------------------------------------
# session / auth plumbing
# ---------------------------------------------------------------------------
def current_user(request: Request) -> dict | None:
    raw = request.cookies.get(config.SESSION_COOKIE)
    if not raw:
        return None
    try:
        sess = _signer.loads(raw, max_age=config.SESSION_MAX_AGE)
    except BadSignature:
        return None
    name = sess.get("u")
    u = store.get_user(name) if name else None
    if not u or not u.get("credentials"):
        return None
    return {"name": name, "role": u.get("role", "viewer")}


def require(min_role: str):
    def dep(request: Request, user: dict | None = Depends(current_user)) -> dict:
        if user is None:
            raise HTTPException(status_code=401)
        if not role_allows(user["role"], min_role):
            raise HTTPException(status_code=403, detail=f"requires role {min_role}")
        return user

    return dep


# ---------------------------------------------------------------------------
# tenancy: one Scope per request, resolved once, obeyed everywhere
# ---------------------------------------------------------------------------
NO_PROJECT_DETAIL = "no-project"


def _project_cookie(request: Request) -> str | None:
    """The last project this browser looked at. SIGNED, because an unsigned
    one would be a client-controlled tenancy hint; and even signed it is only
    ever a preference — resolve() re-checks membership before honouring it."""
    raw = request.cookies.get(config.PROJECT_COOKIE)
    if not raw:
        return None
    try:
        v = _signer.loads(raw, max_age=config.SESSION_MAX_AGE)
    except BadSignature:
        return None
    return v.get("p") if isinstance(v, dict) else None


def _set_project_cookie(resp: Response, pid: str) -> None:
    resp.set_cookie(
        config.PROJECT_COOKIE, _signer.dumps({"p": pid}),
        max_age=config.SESSION_MAX_AGE, httponly=True, secure=True,
        samesite="strict", path="/",
    )


def resolve_scope(request: Request, user: dict) -> Scope:
    """Session + store + request -> Scope. Raises ScopeError (=> 403).

    Memberships are read from the STORE on every request, never carried in the
    session cookie or in whatever dict the auth layer happens to hand over. A
    grant that lives in a cookie is a grant that survives its own revocation
    until the cookie expires; reading the store means `pl console project
    unassign` takes effect on the very next request.
    """
    requested = request.query_params.get("project")
    explicit = requested is not None
    if not explicit:
        requested = _project_cookie(request)
    try:
        memberships = store.memberships(user.get("name", ""))
    except StoreError:
        memberships = {}          # unreadable store => no grants, never all
    rec = {"name": user.get("name", ""), "role": user.get("role", ""), "projects": memberships}
    return scope_mod.resolve(
        rec, projects.all_projects(),
        console_demo_sites=config.DEMO_SITES,
        ci_allowlist=config.CI_PROJECTS,
        requested=requested, requested_explicit=explicit,
    )


def scoped(need: str):
    """Net 1. `need` is the PROJECT role floor (viewer/operator/maintainer).

    Fail-closed ordering matters here: unauthenticated -> 401; a project the
    caller may not use -> 403 + an audited denial (never a quiet fallback to
    something they may see); no membership at all -> the /no-project landing,
    which is a 403 for anything that is not an HTML GET.
    """
    if need not in PROJECT_ROLES:                     # programming error, not input
        raise ValueError(f"unknown project role floor: {need!r}")

    def dep(request: Request, user: dict | None = Depends(current_user)) -> Scope:
        if user is None:
            raise HTTPException(status_code=401)
        try:
            sc = resolve_scope(request, user)
        except ScopeError as e:
            audit.append(user["name"], user["role"], "scope.denied",
                         {"requested": request.query_params.get("project", ""),
                          "path": request.url.path, "reason": str(e)}, False)
            raise HTTPException(status_code=403, detail=str(e)) from e
        if sc.project_role is None:
            raise HTTPException(status_code=403, detail=NO_PROJECT_DETAIL)
        if not sc.can(need):
            raise HTTPException(status_code=403, detail=f"requires project role {need}")
        return sc

    return dep


def _user_of(sc: Scope) -> dict:
    """The {name, role} shape the templates and audit log already speak."""
    return {"name": sc.user, "role": sc.global_role}


@app.exception_handler(403)
async def _forbidden(request: Request, exc):
    """A project-less user browsing gets the explainer page; everything else
    (POSTs, htmx JSON, other 403 reasons) gets a plain 403."""
    detail = getattr(exc, "detail", "")
    if (detail == NO_PROJECT_DETAIL and request.method == "GET"
            and "text/html" in request.headers.get("accept", "")):
        return RedirectResponse("/no-project", status_code=303)
    return JSONResponse({"error": "forbidden", "detail": str(detail)}, status_code=403)


def _guard_origin(request: Request) -> None:
    """CSRF belt: browsers send Origin on POST; if present it must be ours."""
    origin = request.headers.get("origin")
    if origin and origin.rstrip("/") != config.ORIGIN.rstrip("/"):
        raise HTTPException(status_code=403, detail="cross-origin POST refused")
    sfs = request.headers.get("sec-fetch-site")
    if sfs and sfs not in ("same-origin", "none"):
        raise HTTPException(status_code=403, detail="cross-site POST refused")


@app.exception_handler(401)
async def _unauth(request: Request, exc):
    if "text/html" in request.headers.get("accept", "") and request.method == "GET":
        return RedirectResponse("/login", status_code=303)
    return JSONResponse({"error": "unauthenticated"}, status_code=401)


def _set_session(resp: Response, username: str) -> None:
    resp.set_cookie(
        config.SESSION_COOKIE,
        _signer.dumps({"u": username}),
        max_age=config.SESSION_MAX_AGE,
        httponly=True,
        secure=True,
        samesite="strict",
        path="/",
    )


def _set_challenge(resp: Response, payload: dict) -> None:
    resp.set_cookie(
        "nwp_console_chal",
        _challenge_signer.dumps(payload),
        max_age=config.CHALLENGE_MAX_AGE,
        httponly=True,
        secure=True,
        samesite="strict",
        path="/",
    )


def _get_challenge(request: Request) -> dict | None:
    raw = request.cookies.get("nwp_console_chal")
    if not raw:
        return None
    try:
        return _challenge_signer.loads(raw, max_age=config.CHALLENGE_MAX_AGE)
    except BadSignature:
        return None


# ---------------------------------------------------------------------------
# health + auth pages
# ---------------------------------------------------------------------------
@app.get("/health")
def health():
    return {"ok": True, "app": "nwp-console"}


@app.get("/login", response_class=HTMLResponse)
def login_page(request: Request, user: dict | None = Depends(current_user)):
    if user:
        return RedirectResponse("/", status_code=303)
    return templates.TemplateResponse(request, "login.html", {"rp_id": config.RP_ID})


@app.post("/logout")
def logout(request: Request):
    _guard_origin(request)
    resp = RedirectResponse("/login", status_code=303)
    resp.delete_cookie(config.SESSION_COOKIE, path="/")
    return resp


@app.get("/enroll", response_class=HTMLResponse)
def enroll_page(request: Request, token: str = ""):
    name = store.peek_token(token)
    return templates.TemplateResponse(
        request, "enroll.html", {"valid": name is not None, "username": name or "", "token": token}
    )


# -- WebAuthn: registration -------------------------------------------------
@app.post("/webauthn/register/options")
def register_options(request: Request, payload: dict):
    _guard_origin(request)
    token = str(payload.get("token", ""))
    name = store.peek_token(token)
    if not name:
        raise HTTPException(status_code=403, detail="invalid or expired enrolment token")
    u = store.get_user(name) or {}
    existing = [c["id"] for c in u.get("credentials", [])]
    opts_json, challenge = webauthn_flow.registration_options(config.RP_ID, config.RP_NAME, name, existing)
    resp = JSONResponse(json.loads(opts_json))
    _set_challenge(resp, {"mode": "reg", "c": challenge, "token": token})
    return resp


@app.post("/webauthn/register/verify")
def register_verify(request: Request, payload: dict):
    _guard_origin(request)
    chal = _get_challenge(request)
    if not chal or chal.get("mode") != "reg":
        raise HTTPException(status_code=403, detail="no registration in progress (challenge expired?)")
    name = store.consume_token(chal.get("token", ""))  # single-use burn happens HERE
    if not name:
        raise HTTPException(status_code=403, detail="enrolment token no longer valid")
    try:
        cred = webauthn_flow.verify_registration(
            json.dumps(payload.get("credential", {})), chal["c"], config.ORIGIN, config.RP_ID
        )
        store.add_credential(name, cred["cred_id_b64"], cred["public_key_b64"], cred["sign_count"])
    except (StoreError, Exception) as e:  # noqa: BLE001 — surface, fail closed
        audit.append(name, "?", "enroll.fail", {"error": str(e)[:200]}, False)
        raise HTTPException(status_code=400, detail=f"registration failed: {str(e)[:200]}")
    audit.append(name, store.get_user(name).get("role", "?"), "enroll.ok", {}, True)
    resp = JSONResponse({"ok": True})
    _set_session(resp, name)
    resp.delete_cookie("nwp_console_chal", path="/")
    return resp


# -- WebAuthn: login --------------------------------------------------------
@app.post("/webauthn/login/options")
def login_options(request: Request, payload: dict):
    _guard_origin(request)
    username = str(payload.get("username", "")).strip()
    allowed: list[str] = []
    if username:
        u = store.get_user(username)
        if u:
            allowed = [c["id"] for c in u.get("credentials", [])]
        # unknown user => empty allow-list, same as usernameless (no user enum)
    opts_json, challenge = webauthn_flow.authentication_options(config.RP_ID, allowed)
    resp = JSONResponse(json.loads(opts_json))
    _set_challenge(resp, {"mode": "auth", "c": challenge})
    return resp


@app.post("/webauthn/login/verify")
def login_verify(request: Request, payload: dict):
    _guard_origin(request)
    chal = _get_challenge(request)
    if not chal or chal.get("mode") != "auth":
        raise HTTPException(status_code=403, detail="no login in progress (challenge expired?)")
    credential = payload.get("credential", {})
    cred_id = str(credential.get("id", ""))
    found = store.find_credential(cred_id)
    if not found:
        audit.append("(unknown)", "-", "login.fail", {"reason": "unknown credential"}, False)
        raise HTTPException(status_code=403, detail="unknown credential")
    name, cred = found
    try:
        new_count = webauthn_flow.verify_authentication(
            json.dumps(credential), chal["c"], config.ORIGIN, config.RP_ID, cred["public_key"], cred["sign_count"]
        )
        store.update_sign_count(cred_id, new_count)
    except Exception as e:  # noqa: BLE001 — any crypto failure = refuse
        audit.append(name, "-", "login.fail", {"error": str(e)[:200]}, False)
        raise HTTPException(status_code=403, detail="authentication failed")
    audit.append(name, store.get_user(name).get("role", "?"), "login.ok", {}, True)
    resp = JSONResponse({"ok": True})
    _set_session(resp, name)
    resp.delete_cookie("nwp_console_chal", path="/")
    return resp


# ---------------------------------------------------------------------------
# dashboard + panes
# ---------------------------------------------------------------------------
@app.get("/", response_class=HTMLResponse)
def index(request: Request, sc: Scope = Depends(scoped("viewer"))):
    return templates.TemplateResponse(
        request,
        "index.html",
        {"user": _user_of(sc), "gitlab_url": gitlab.web_url(), "panes": PANES,
         "can_act": sc.can("operator"), "scope": sc},
    )


@app.get("/no-project", response_class=HTMLResponse)
def no_project(request: Request, user: dict | None = Depends(current_user)):
    """Where an authenticated user with zero memberships lands. Deliberately a
    page and not an empty dashboard: 'you have no project yet, ask the owner'
    is information; a working-looking console showing nothing is not."""
    if user is None:
        raise HTTPException(status_code=401)
    return templates.TemplateResponse(
        request, "no_project.html",
        {"user": user, "has_projects": bool(projects.all_projects())},
    )


@app.post("/scope/switch")
def scope_switch(request: Request, project: str = Form(""), sc: Scope = Depends(scoped("viewer"))):
    """Change the active project. The membership check is resolve()'s, not
    this route's — asking for one you may not have is a 403 there."""
    _guard_origin(request)
    pid = (project or "").strip()
    allowed = {p for p, _ in sc.memberships}
    if pid in ("", "*"):
        if sc.global_role != "owner":
            raise HTTPException(status_code=403, detail="only an owner may view all projects")
        resp = RedirectResponse("/", status_code=303)
        resp.delete_cookie(config.PROJECT_COOKIE, path="/")
        audit.append(sc.user, sc.global_role, "scope.switch", {"to": "*"}, True, project=None)
        return resp
    if pid not in allowed:
        audit.append(sc.user, sc.global_role, "scope.denied", {"requested": pid, "path": "/scope/switch"}, False)
        raise HTTPException(status_code=403, detail=f"not a member of project: {pid}")
    resp = RedirectResponse("/", status_code=303)
    _set_project_cookie(resp, pid)
    audit.append(sc.user, sc.global_role, "scope.switch", {"to": pid}, True, project=pid)
    return resp


def _pane(request: Request, template: str, ctx: dict, sc: Scope,
          tab: str = "", tab_count: str = "", tab_alert: bool = False,
          redactable: bool = True) -> HTMLResponse:
    """Render a pane. When `tab` is set, the template's _tabcount include emits
    an hx-swap-oob span so the tab title's count refreshes WITH the pane.

    Net 2 of the tenancy design lives here, and it applies to EVERY pane by
    construction rather than by remembering:

      scrub  — drop any dict carrying a `site` key outside the scope, however
               deeply nested. A dropped row is audited; under SCOPE_STRICT
               (CI) it raises, so a leak fails the build instead of being
               silently repaired forever.
      redact — remove free-text passthroughs (raw command output, publisher
               host, provenance notes) from READ panes for a scoped reader.
               `redactable=False` exempts action/invite results, whose argv was
               already validated against this scope's own site list.
    """
    if not sc.all_sites:
        ctx, dropped = scope_mod.scrub(ctx, sc)
        if dropped:
            audit.append(sc.user, sc.global_role, "scope.leak",
                         {"pane": template, "dropped": dropped}, False, project=sc.project_id)
            if config.SCOPE_STRICT:
                raise ScopeLeak(f"{dropped} foreign row(s) reached {template}")
        if redactable:
            ctx = scope_mod.redact(ctx, sc)
    ctx = dict(ctx, user=_user_of(sc), can_act=sc.can("operator"), scope=sc,
               tab=tab, tab_count=tab_count, tab_alert=tab_alert)
    return templates.TemplateResponse(request, template, ctx)


# -- shared gatherers (panes + tab counts + Quokka context) ------------------
#
# Fleet state is PUBLISHED to this host, not computed on it: the sites live on
# the workstation, so `pl rag` here sees an empty fleet. `pl fleet publish`
# ships a snapshot; fleet_state.decide() picks the source and hands back the
# provenance the panes render. See scripts/console/app/fleet_state.py.
#
# EVERY gatherer comes in two halves:
#   _gather_X_raw()  fleet-wide, no boundary. Callable ONLY by the owner-only
#                    background paths (_notify_pass) and by its own scoped
#                    wrapper. Routes must not call it — asserted by the AST
#                    test, because "I'll remember to filter" is not a control.
#   _gather_X(sc)    the same data narrowed to one Scope, with every derived
#                    number RECOMPUTED rather than inherited (a count taken
#                    before filtering encodes exactly the foreign facts the
#                    filtering exists to hide).
def _gather_fleet_feed(name: str, argv: list[str], parse, rows_key: str,
                       empty_is_missing: bool = False,
                       force: bool = False, project_id: str | None = None) -> tuple[dict, dict, dict]:
    def local() -> tuple[dict, dict]:
        res = run_pl_cached(config.NWP_ROOT, argv, ttl=config.PANE_CACHE_TTL,
                            timeout=config.PL_TIMEOUT, force=force)
        parsed = parse(res["out"]) if res["out"] else {
            "ok": False, "error": res["err"] or f"rc={res['rc']}"}
        return parsed, res

    snap, snap_scoped = fleet_state.load_for(config.DATA_DIR, project_id, config.FLEET_STATE_FILE)
    parsed, res, prov = fleet_state.decide(snap, name, local, config.FLEET_MAX_AGE, rows_key)
    prov = dict(prov, scoped=snap_scoped)
    if parsed is None:                       # published feed won: parse it the same way
        parsed = parse(res["out"])
    # For RAG, an 'ok, zero sites' answer from a host that has no sites is not
    # an answer. Saying so (with the fix) beats an empty table that looks
    # healthy — and it keeps the RAG notifier from seeding an empty fleet and
    # then screaming RED at every site the moment publishing starts. (An empty
    # TODO sweep, by contrast, is real good news — hence the flag.)
    if empty_is_missing and prov["source"] == "local" and parsed.get("ok") and not parsed.get(rows_key):
        parsed = dict(fleet_state.empty_local_error(prov, "fleet"), **{rows_key: []})
    return parsed, res, prov


def _gather_rag_raw(force: bool = False, project_id: str | None = None) -> tuple[dict, dict, dict]:
    return _gather_fleet_feed("rag", ["rag", "--json", "--no-todo"],
                              parsers.parse_rag, "sites", empty_is_missing=True,
                              force=force, project_id=project_id)


def _gather_todo_raw(force: bool = False, project_id: str | None = None) -> tuple[dict, dict, dict]:
    return _gather_fleet_feed("todo", ["todo", "check", "--json"],
                              parsers.parse_todo, "items", force=force, project_id=project_id)


def _gather_rag(sc: Scope, force: bool = False) -> tuple[dict, dict, dict]:
    rag, res, prov = _gather_rag_raw(force=force, project_id=sc.project_id)
    if sc.all_sites or not rag.get("ok"):
        return rag, res, prov
    sites = sc.filter_rows(rag.get("sites", []))
    if not sites:
        return dict(fleet_state.empty_project_error(sc.project_id or "?", "fleet"), sites=[]), res, prov
    counts = {"RED": 0, "AMBER": 0, "GREEN": 0, "OTHER": 0}
    for s in sites:                      # recount: never inherit a fleet total
        counts[s["grade"] if s.get("grade") in counts else "OTHER"] += 1
    return dict(rag, sites=sites, counts=counts), res, prov


def _gather_todo(sc: Scope, force: bool = False) -> tuple[dict, dict, dict]:
    todo, res, prov = _gather_todo_raw(force=force, project_id=sc.project_id)
    if sc.all_sites or not todo.get("ok"):
        return todo, res, prov
    items = sc.filter_rows(todo.get("items", []))
    summary = {"total": len(items)}
    for prio in ("high", "medium", "low"):
        summary[prio] = sum(1 for i in items if i.get("priority") == prio)
    return dict(todo, items=items, summary=summary), res, prov


def _gather_security_raw(force: bool = False, project_id: str | None = None) -> tuple[dict, dict, dict]:
    """Security advisories, from the SAME published snapshot as everything else.

    This host cannot run `composer audit` — it has no sites. A snapshot with no
    `security` feed (published before this feature existed, or with
    --no-security) degrades to the honest "no security data in this snapshot"
    rather than to a reassuring zero.
    """
    return _gather_fleet_feed("security", ["fleet", "security", "--json"],
                              parsers.parse_security, "sites", empty_is_missing=True,
                              force=force, project_id=project_id)


def _gather_security(sc: Scope, force: bool = False) -> tuple[dict, dict, dict]:
    """Advisories are per-site, so they scope exactly like RAG does — and the
    totals are recomputed, because a fleet-wide advisory count would tell a
    member precisely how many holes exist in sites they cannot see."""
    sec, res, prov = _gather_security_raw(force=force, project_id=sc.project_id)
    if sc.all_sites or not sec.get("ok"):
        return sec, res, prov
    sites = sc.filter_rows(sec.get("sites", []))
    # RECOMPUTE the headline from the filtered blocks. Inheriting the published
    # `totals` would put the fleet-wide advisory count above a list of this
    # project's sites — the reader would see "9 advisories" over one row and
    # learn the size of a problem in sites they cannot see.
    return dict(sec, sites=sites, totals=advisories.totals(sites)), res, prov


def _gather_demo_raw(sites: list[str], force: bool = False) -> list[dict]:
    out = []
    for site in sites:
        st = run_pl_cached(config.NWP_ROOT, ["demo", "status", site],
                           ttl=config.PANE_CACHE_TTL, timeout=config.PL_TIMEOUT, force=force)
        codes = run_pl_cached(config.NWP_ROOT, ["demo", "codes", site, "list"],
                              ttl=config.PANE_CACHE_TTL, timeout=config.PL_TIMEOUT, force=force)
        status = parsers.parse_demo_status(st["out"] if st["rc"] == 0 else st["out"] + "\n" + st["err"])
        codes_p = parsers.parse_demo_codes(codes["out"])
        events = parsers.DEMO_EVENT_RE.findall(status.get("raw", "") or "")
        out.append(
            {
                "site": site, "status": status, "codes": codes_p, "rc": st["rc"],
                "live_codes": parsers.demo_live_code_count(codes_p),
                "alert": parsers.demo_reset_alert(status),
                "last_event": events[-1] if events else "",
            }
        )
    return out


def _gather_demo(sc: Scope, force: bool = False) -> list[dict]:
    # Narrowed BEFORE the shell-out, not after: a scoped reader should not even
    # cause `pl demo status` to run against another project's site.
    return _gather_demo_raw(sorted(sc.demo_sites), force=force)


def _gather_issues_raw() -> dict:
    return gitlab.list_issues(config.OPS_PROJECT)


def _gather_issues(sc: Scope) -> tuple[list[dict], dict]:
    r = _gather_issues_raw()
    issues = (r.get("data") or []) if r.get("ok") else []
    return sc.filter_issues(issues), r


def _gather_ci_raw(ci_projects) -> tuple[list[dict], bool]:
    blocks = []
    api_ok = gitlab.has_token()
    for project in ci_projects:
        mrs = []
        r = gitlab.open_mrs(project)
        for mr in (r.get("data") or []) if r.get("ok") else []:
            d = gitlab.mr_detail(project, mr["iid"])
            pipe = (d.get("data") or {}).get("head_pipeline") if d.get("ok") else None
            mrs.append({"mr": mr, "pipeline": pipe})
        blocks.append({"project": project, "mrs": mrs, "url": gitlab.web_url(project + "/-/merge_requests")})
    return blocks, api_ok


def _gather_ci(sc: Scope) -> tuple[list[dict], bool]:
    return _gather_ci_raw(sorted(sc.ci_projects))


_qk_alive_cache = {"t": 0.0, "v": False}


def _quokka_alive() -> bool:
    now = time.time()
    if now - _qk_alive_cache["t"] > 60:
        _qk_alive_cache["v"] = quokka.alive(config.QUOKKA_URL)
        _qk_alive_cache["t"] = now
    return _qk_alive_cache["v"]


def _demo_tab(demo_sites: list[dict]) -> tuple[str, bool]:
    total = sum(d.get("live_codes", 0) for d in demo_sites)
    return parsers.fmt_n_tab(total, "codes"), any(d.get("alert") for d in demo_sites)


# -- tab counts (every tab, one cheap endpoint; each count independent) ------
@app.get("/tabs/counts", response_class=HTMLResponse)
def tab_counts(request: Request, sc: Scope = Depends(scoped("viewer"))):
    counts: list[dict] = []

    def add(pane: str, fn):
        """Each count is computed independently and best-effort: a broken
        feed degrades to no-number, it must NEVER break or block a tab."""
        text, alert = "", False
        try:
            text, alert = fn()
        except Exception:  # noqa: BLE001
            pass
        counts.append({"pane": pane, "text": text, "alert": alert})

    def _issues_count():
        issues, r = _gather_issues(sc)
        return (parsers.fmt_n_tab(len(issues)) if r.get("ok") else ""), False

    def _todo_counts():
        todo = _gather_todo(sc)[0]
        todo_txt = parsers.fmt_n_tab(len(todo.get("items", []))) if todo.get("ok") else ""
        stale = len(parsers.todo_backup_items(todo))
        return todo_txt, (parsers.fmt_n_tab(stale, "stale") if stale else "")

    todo_txt, backups_txt = "", ""
    try:
        todo_txt, backups_txt = _todo_counts()
    except Exception:  # noqa: BLE001
        pass

    # The fleet tab flags itself when the state it is showing is stale, so a
    # dead publisher is visible from the tab bar, not only inside the pane.
    add("fleet", lambda: (lambda rag, _r, prov: (parsers.fmt_rag_tab(rag), bool(prov.get("stale"))))(*_gather_rag(sc)))
    add("issues", _issues_count)
    add("todo", lambda: (todo_txt, False))
    add("demo", lambda: _demo_tab(_gather_demo(sc)))
    add("backups", lambda: (backups_txt, False))
    add("ci", lambda: ((lambda n: f"({n}▶)" if n else "")(parsers.ci_running_count(_gather_ci(sc)[0])), False))
    add("quokka", lambda: ("\U0001f7e2" if _quokka_alive() else "\U0001f4a4", False))
    return templates.TemplateResponse(request, "tab_counts.html", {"counts": counts})


@app.get("/panes/fleet", response_class=HTMLResponse)
def pane_fleet(request: Request, force: int = 0, sc: Scope = Depends(scoped("viewer"))):
    rag, res, prov = _gather_rag(sc, force=bool(force))
    # The security feed is gathered separately and best-effort: it is the NEW
    # thing on this pane, and a pane that has always worked must not start
    # failing because of it. Every advisory view below is derived from the
    # SCOPE-FILTERED feed, so the headline count, the affected-site list and
    # the per-site breakdown all describe this project only.
    sec = {"ok": False, "error": "security data unavailable on this host", "sites": [],
           "totals": advisories.totals([])}
    try:
        sec = _gather_security(sc, force=bool(force))[0]
    except Exception:  # noqa: BLE001
        pass
    audit_from, audit_to = advisories.audit_window(sec)
    return _pane(request, "pane_fleet.html",
                 {"rag": rag, "res": res, "prov": prov, "sec": sec,
                  "sec_headline": advisories.headline(sec),
                  "sec_sites": advisories.affected_sites(sec),
                  "sec_by_site": advisories.by_site(sec),
                  "sec_audit_from": audit_from, "sec_audit_to": audit_to}, sc,
                 tab="fleet", tab_count=parsers.fmt_rag_tab(rag), tab_alert=bool(prov.get("stale")))


@app.get("/panes/todo", response_class=HTMLResponse)
def pane_todo(request: Request, force: int = 0, sc: Scope = Depends(scoped("viewer"))):
    todo, res, prov = _gather_todo(sc, force=bool(force))
    return _pane(request, "pane_todo.html", {"todo": todo, "res": res, "prov": prov}, sc,
                 tab="todo", tab_count=parsers.fmt_n_tab(len(todo.get("items", []))) if todo.get("ok") else "")


@app.get("/panes/backups", response_class=HTMLResponse)
def pane_backups(request: Request, force: int = 0, sc: Scope = Depends(scoped("viewer"))):
    todo, res, prov = _gather_todo(sc, force=bool(force))
    items = parsers.todo_backup_items(todo)
    return _pane(request, "pane_backups.html",
                 {"items": items, "todo_ok": todo.get("ok", False), "res": res, "prov": prov}, sc,
                 tab="backups", tab_count=parsers.fmt_n_tab(len(items), "stale") if items else "")


@app.get("/panes/demo", response_class=HTMLResponse)
def pane_demo(request: Request, force: int = 0, sc: Scope = Depends(scoped("viewer"))):
    sites = _gather_demo(sc, force=bool(force))
    from .actions import BUNDLES

    count, alert = _demo_tab(sites)
    return _pane(request, "pane_demo.html", {"demo_sites": sites, "bundles": BUNDLES}, sc,
                 tab="demo", tab_count=count, tab_alert=alert)


@app.get("/panes/issues", response_class=HTMLResponse)
def pane_issues(request: Request, sc: Scope = Depends(scoped("viewer"))):
    issues, r = _gather_issues(sc)
    return _pane(
        request,
        "pane_issues.html",
        {
            "issues": issues,
            "api_ok": r.get("ok", False),
            "api_error": r.get("error", ""),
            # A scoped reader is told WHICH label bounds their view, so an
            # empty pane reads as "nothing carries this label" rather than as
            # "the tracker is broken".
            "issue_labels": sorted(sc.issue_labels),
            "project": config.OPS_PROJECT,
            "project_url": gitlab.web_url(config.OPS_PROJECT),
        },
        sc,
        tab="issues", tab_count=parsers.fmt_n_tab(len(issues)) if r.get("ok") else "",
    )


@app.get("/panes/ci", response_class=HTMLResponse)
def pane_ci(request: Request, sc: Scope = Depends(scoped("viewer"))):
    blocks, api_ok = _gather_ci(sc)
    n = parsers.ci_running_count(blocks)
    return _pane(request, "pane_ci.html", {"blocks": blocks, "api_ok": api_ok}, sc,
                 tab="ci", tab_count=(f"({n}▶)" if n else ""))


# ---------------------------------------------------------------------------
# actions (operator+) — the ONLY shell-out path, via the allowlist
# ---------------------------------------------------------------------------
def _action_gate(sc: Scope, spec: dict) -> None:
    """Both axes, plus the fleet-wide exception. Raises HTTPException(403).

    A "global" action (one that cannot be narrowed to a project — `pl rag`
    sweeps the whole fleet) is refused to a scoped caller outright. Running it
    would compute over sites they may not see, and 'the output is filtered
    afterwards' is not the same promise as 'it never ran on your behalf'.
    """
    if not role_allows(sc.global_role, spec.get("min_role", "owner")):
        raise HTTPException(status_code=403, detail="insufficient global role")
    if not sc.can(spec.get("min_project_role", "maintainer")):
        raise HTTPException(status_code=403, detail="insufficient project role")
    if spec.get("scope") == "global" and not sc.all_sites:
        raise HTTPException(status_code=403,
                            detail="fleet-wide action: run it unscoped (owner) or on the workstation")


@app.post("/actions/run", response_class=HTMLResponse)
def action_run(
    request: Request,
    action: str = Form(...),
    site: str = Form(""),
    bundle: str = Form(""),
    code_id: str = Form(""),
    sc: Scope = Depends(scoped("operator")),
):
    _guard_origin(request)
    params = {"site": site, "bundle": bundle, "code_id": code_id}
    try:
        # sorted(sc.demo_sites), NEVER config.DEMO_SITES: the tier gate says
        # the verb exists, the scope says whose site it may touch.
        argv, spec = build_action(action, params, sorted(sc.demo_sites))
    except ActionError as e:
        audit.append(sc.user, sc.global_role, f"action.{action}",
                     {"params": params, "rejected": str(e)}, False, project=sc.project_id)
        return _pane(request, "action_result.html", {"label": action, "res": None, "error": str(e)}, sc,
                     redactable=False)
    _action_gate(sc, spec)
    res = run_pl(config.NWP_ROOT, argv, timeout=config.PL_TIMEOUT)
    audit.append(
        sc.user, sc.global_role, f"action.{action}",
        {"argv": argv, "rc": res["rc"], "secs": res["secs"]}, res["rc"] == 0, project=sc.project_id,
    )
    label = ACTIONS[action]["label"]
    res_view = dict(res, out=parsers.strip_ansi(res["out"])[-8000:], err=parsers.strip_ansi(res["err"])[-2000:])
    return _pane(request, "action_result.html", {"label": label, "res": res_view, "error": None}, sc,
                 redactable=False)


# -- invite email (operator+): allowlisted `pl demo invite`, copyable draft --
@app.post("/actions/invite", response_class=HTMLResponse)
def action_invite(
    request: Request,
    site: str = Form(""),
    all_levels: str = Form(""),
    sc: Scope = Depends(scoped("operator")),
):
    """The phone-friendly path to `pl demo invite`: runs the allowlisted
    action and shows the complete draft in a copyable textarea. The plaintext
    codes live in the response body only — the audit log records argv + sizes,
    never the draft."""
    _guard_origin(request)
    params = {"site": site, "all": all_levels}
    try:
        argv, spec = build_action("demo_invite", params, sorted(sc.demo_sites))
    except ActionError as e:
        audit.append(sc.user, sc.global_role, "action.demo_invite",
                     {"params": params, "rejected": str(e)}, False, project=sc.project_id)
        return _pane(request, "invite_result.html", {"email": "", "res": None, "error": str(e)}, sc,
                     redactable=False)
    _action_gate(sc, spec)
    res = run_pl(config.NWP_ROOT, argv, timeout=config.PL_TIMEOUT)
    email = parsers.extract_invite_email(res["out"]) if res["rc"] == 0 else ""
    audit.append(
        sc.user, sc.global_role, "action.demo_invite",
        {"argv": argv, "rc": res["rc"], "secs": res["secs"], "email_chars": len(email)}, res["rc"] == 0,
        project=sc.project_id,
    )
    res_view = dict(res, out=parsers.strip_ansi(res["out"])[-4000:], err=parsers.strip_ansi(res["err"])[-2000:])
    return _pane(request, "invite_result.html", {"email": email, "res": res_view, "error": None}, sc,
                 redactable=False)


# ---------------------------------------------------------------------------
# Quokka — local-LLM chat (viewer+). READ-ONLY BY CONSTRUCTION: these routes
# never import or touch actions.py/build_action; Quokka's only fleet
# knowledge is the rendered LIVE STATE text block (context injection).
# ---------------------------------------------------------------------------
# Per-scope, because the LIVE STATE block IS site data: one shared cache would
# hand the first caller's fleet to the next caller's model.
_qk_ctx_cache: dict = {}


def _quokka_state(sc: Scope, force: bool = False) -> dict:
    """Best-effort live-state gather from the EXISTING scoped gatherers."""
    state: dict = {"generated": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")}
    try:
        rag, _res, prov = _gather_rag(sc, force=force)
        state["rag"] = rag
        # Tell the model where this came from, so it can never present a stale
        # snapshot as the current state of the fleet.
        line = fleet_state.describe(prov)
        if line:
            state.setdefault("extra_lines", []).append(line)
    except Exception:  # noqa: BLE001
        pass
    try:
        issues, r = _gather_issues(sc)
        state["issues_ok"] = bool(r.get("ok"))
        state["issues"] = issues
    except Exception:  # noqa: BLE001
        pass
    try:
        state["todo"] = _gather_todo(sc, force=force)[0]
    except Exception:  # noqa: BLE001
        pass
    try:
        state["demo"] = _gather_demo(sc, force=force)
    except Exception:  # noqa: BLE001
        pass
    try:
        blocks, api_ok = _gather_ci(sc)
        state["ci"], state["ci_ok"] = blocks, api_ok
    except Exception:  # noqa: BLE001
        pass
    if not sc.all_sites:
        state.setdefault("extra_lines", []).append(
            f"You are answering inside project '{sc.project_id}'. The state above covers ONLY "
            f"this project's sites ({', '.join(sorted(sc.sites)) or 'none'}). You have no "
            f"knowledge of any other site; say so if asked about one."
        )
    return state


def _quokka_context(sc: Scope) -> str:
    key = sc.project_id or "*"
    now = time.time()
    hit = _qk_ctx_cache.get(key)
    if hit and now - hit["t"] < 60:
        return hit["text"]
    text = quokka.render_context(_quokka_state(sc))
    _qk_ctx_cache[key] = {"t": now, "text": text}
    return text


def _brief_state(sc: Scope) -> dict:
    """Richer 24h context for the morning brief."""
    state = _quokka_state(sc)
    extra: list[str] = []
    cutoff = datetime.now(timezone.utc) - timedelta(hours=24)
    # Issues touched in the last 24 h (includes the demo-tester ones).
    try:
        recent = []
        for i in state.get("issues", []):
            try:
                ts = datetime.fromisoformat(str(i.get("updated_at", "")).replace("Z", "+00:00"))
                if ts >= cutoff:
                    labels = ",".join(i.get("labels", [])[:4])
                    recent.append(f"  #{i['iid']} {str(i.get('title', ''))[:80]}" + (f" [{labels}]" if labels else ""))
            except (ValueError, KeyError, TypeError):
                continue
        extra.append(f"Issues updated in the last 24h: {len(recent)}")
        extra.extend(recent[:15])
    except Exception:  # noqa: BLE001
        pass
    # Demo reset/skip trail + unposted harvest digests (spool titles only).
    try:
        for d in state.get("demo", []):
            raw = d.get("status", {}).get("raw", "") or ""
            trail = [ln.strip() for ln in raw.splitlines() if parsers.DEMO_EVENT_RE.search(ln)]
            if trail:
                extra.append(f"Demo {d['site']} recent reset log:")
                extra.extend(f"  {ln[:160]}" for ln in trail[-5:])
            hdir = config.NWP_ROOT / "sites" / d["site"] / "demo-harvest"
            if hdir.is_dir():
                spools = sorted(p.name for p in hdir.glob("harvest-*.md"))[-5:]
                if spools:
                    extra.append(f"Demo {d['site']} unposted error harvests: {', '.join(spools)}")
    except Exception:  # noqa: BLE001
        pass
    # Audit-log highlights (last 24 h): what ran, what failed.
    #
    # Filtered through the SAME rule as the /audit page: a scoped reader sees
    # only entries stamped with their own project, and never the pre-project
    # entries that carry no stamp. Without this the brief would happily narrate
    # another tenant's failures — the model repeats whatever it is told.
    try:
        by_action: dict[str, int] = {}
        fails: list[str] = []
        for e in (x for x in audit.tail(300) if sc.audit_allowed(x)):
            try:
                ts = datetime.fromisoformat(str(e.get("ts", "")).replace("Z", "+00:00"))
            except ValueError:
                continue
            if ts < cutoff:
                continue
            by_action[e.get("action", "?")] = by_action.get(e.get("action", "?"), 0) + 1
            if not e.get("ok"):
                fails.append(f"  FAILED {e.get('action', '?')} by {e.get('user', '?')} at {e.get('ts', '')}")
        if by_action:
            extra.append("Console activity (24h): " + ", ".join(f"{k}×{v}" for k, v in sorted(by_action.items())))
        extra.extend(fails[:8])
    except Exception:  # noqa: BLE001
        pass
    state["extra_lines"] = extra
    return state


def _quokka_streaming_response(messages: list[dict], sc: Scope, action: str, prompt_summary: str):
    def gen():
        got: list[str] = []
        ok = False
        try:
            for chunk in quokka.chat_stream(config.QUOKKA_URL, config.QUOKKA_MODEL, messages,
                                            timeout=config.QUOKKA_TIMEOUT):
                got.append(chunk)
                yield chunk
            ok = True
        except quokka.QuokkaError as e:
            yield ("\n\n" if got else "") + (
                f"Quokka is asleep (local model unavailable: {e}). The other tabs still work."
            )
        finally:
            audit.append(sc.user, sc.global_role, action,
                         {"prompt": prompt_summary[:200], "reply": "".join(got)[:200],
                          "model": config.QUOKKA_MODEL}, ok, project=sc.project_id)
    return StreamingResponse(gen(), media_type="text/plain; charset=utf-8")


@app.get("/panes/quokka", response_class=HTMLResponse)
def pane_quokka(request: Request, force: int = 0, sc: Scope = Depends(scoped("viewer"))):
    awake = _quokka_alive()
    # Voice probes are TTL-cached in voice.py and fail closed, so a host with
    # no whisper/piper just renders the tab without a mic button.
    return _pane(request, "pane_quokka.html",
                 {"awake": awake, "model": config.QUOKKA_MODEL,
                  "stt_ok": voice.stt_available(), "tts_ok": voice.tts_available(),
                  "stt_max_seconds": config.STT_MAX_SECONDS}, sc,
                 tab="quokka", tab_count=("\U0001f7e2" if awake else "\U0001f4a4"))


@app.post("/quokka/chat")
def quokka_chat(request: Request, message: str = Form(...), history: str = Form("[]"),
                sc: Scope = Depends(scoped("viewer"))):
    """The context block is built from the SCOPED gatherers, so the model is
    never told a fact about a site the asker may not see. The history comes
    from the client and is therefore untrusted — but it can only ever contain
    what this same scope was already shown."""
    _guard_origin(request)
    msg = message.strip()[:4000]
    if not msg:
        raise HTTPException(status_code=400, detail="empty message")
    try:
        hist = json.loads(history)
        if not isinstance(hist, list):
            hist = []
    except json.JSONDecodeError:
        hist = []
    messages = quokka.build_messages(_quokka_context(sc), hist, msg)
    return _quokka_streaming_response(messages, sc, "quokka.chat", msg)


@app.get("/quokka/brief")
def quokka_brief(request: Request, sc: Scope = Depends(scoped("viewer"))):
    """Morning brief over a richer 24h context. Also the future-automation
    hook — returns 503 cleanly when the local model is down."""
    if not _quokka_alive():
        raise HTTPException(status_code=503, detail="Quokka is asleep (local model not reachable)")
    messages = quokka.build_messages(quokka.render_context(_brief_state(sc)), [], quokka.BRIEF_PROMPT)
    return _quokka_streaming_response(messages, sc, "quokka.brief", "summarize today")


# ---------------------------------------------------------------------------
# Gotify push notifications (Phase 3) — the console speaks first.
#
# One periodic checker, no second service and no second port. It reuses the
# EXACT gatherers the panes use (and their TTL cache), so watching costs
# roughly one extra pane refresh per NOTIFY_INTERVAL. Detection lives in
# notify.py as pure functions; this layer only feeds them and ships the result.
# ---------------------------------------------------------------------------
def _notify_gather() -> dict:
    """One best-effort gather for the checker. A feed that fails is simply
    absent — its detector then produces nothing and leaves its state alone.

    Notifications are OWNER-ONLY and FLEET-WIDE by design (there is one Gotify
    channel and it belongs to the operator), so this path deliberately runs at
    `scope_mod.fleet_scope()` rather than at any user's scope. It is named that
    way so every intentional crossing of the boundary is greppable — and it is
    unreachable from a request, because nothing routes here.
    """
    fleet = scope_mod.fleet_scope("(checker)")
    g: dict = {"gitlab_url": gitlab.web_url(config.OPS_PROJECT)}
    try:
        g["rag"] = _gather_rag(fleet)[0]
    except Exception:  # noqa: BLE001
        pass
    try:
        r = _gather_issues_raw()
        g["issues"], g["issues_ok"] = (r.get("data") or []), bool(r.get("ok"))
    except Exception:  # noqa: BLE001
        pass
    try:
        g["demo"] = _gather_demo_raw(list(config.DEMO_SITES))
    except Exception:  # noqa: BLE001
        pass
    try:
        g["todo"] = _gather_todo(fleet)[0]
    except Exception:  # noqa: BLE001
        pass
    try:
        g["security"] = _gather_security(fleet)[0]
    except Exception:  # noqa: BLE001
        pass
    try:
        g["ci"], g["ci_ok"] = _gather_ci_raw(list(config.CI_PROJECTS))
    except Exception:  # noqa: BLE001
        pass
    return g


def _brief_text() -> str:
    """Render the morning brief for pushing. Returns '' when the local model is
    asleep — the brief is a nice-to-have and never wakes or waits on one.

    Owner-only and fleet-wide for the same reason as _notify_gather: it is
    pushed to the operator's own phone, not served to a scoped reader.
    """
    if not _quokka_alive():
        return ""
    try:
        messages = quokka.build_messages(
            quokka.render_context(_brief_state(scope_mod.fleet_scope("(checker)"))), [], quokka.BRIEF_PROMPT)
        return "".join(quokka.chat_stream(config.QUOKKA_URL, config.QUOKKA_MODEL, messages,
                                          timeout=config.QUOKKA_TIMEOUT)).strip()
    except Exception:  # noqa: BLE001
        return ""


def _notify_pass() -> dict:
    """One checker pass: gather -> detect -> send -> persist. Never raises."""
    if not notifier.configured():
        return {"ok": False, "skipped": "unconfigured"}
    try:
        state = notify_state.load()
        events, state = notify.run_checks(
            _notify_gather(), state, config.ORIGIN, set(config.NOTIFY_EVENTS)
        )
        sent, failed = notify.deliver(notifier, events, state)

        # Optional daily brief, gated on its own toggle + a configured time.
        if "brief" in config.NOTIFY_EVENTS and config.NOTIFY_BRIEF_AT:
            if notify.due_for_brief(state.get("brief"), config.NOTIFY_BRIEF_AT, datetime.now()):
                text = _brief_text()
                if text and notifier.send("☀️ NWP morning brief", text,
                                          notify.P_MUTED, f"{config.ORIGIN}/?tab=quokka"):
                    sent += 1
                    state["brief"] = {"last": datetime.now().strftime("%Y-%m-%d")}
                    state.setdefault("last_sent", {})["brief"] = notify._now_iso()

        notify_state.save(state)
        if events or sent:
            audit.append("(checker)", "-", "notify.push",
                         {"events": [e.as_detail() for e in events], "sent": sent, "failed": failed},
                         failed == 0)
        return {"ok": True, "sent": sent, "failed": failed, "events": len(events)}
    except Exception as e:  # noqa: BLE001 — fail-open, always
        return {"ok": False, "error": str(e)[:200]}


def _notify_view(request: Request, user: dict, message: str = "") -> HTMLResponse:
    state = notify_state.load()
    last_sent = state.get("last_sent", {}) if isinstance(state, dict) else {}
    rows = [
        {"kind": k, "label": lbl, "enabled": k in config.NOTIFY_EVENTS, "last": last_sent.get(k, "")}
        for k, lbl in (
            ("rag", "Site goes RAG red (and recovers to green)"),
            ("demo_tester", "New demo-tester issue in GitLab"),
            ("demo_reset", "Demo reset failed or was skipped"),
            ("token_expiry", "Token dead or nearing expiry"),
            ("security", "New security advisory on a site (composer audit)"),
            ("ci", "CI pipeline failed on an open MR"),
            ("brief", f"Daily morning brief{' at ' + config.NOTIFY_BRIEF_AT if config.NOTIFY_BRIEF_AT else ' (no time set)'}"),
        )
    ]
    return templates.TemplateResponse(
        request, "notifications.html",
        {"user": user, "rows": rows, "status": notifier.status(), "message": message,
         "interval": config.NOTIFY_INTERVAL, "seeded": bool(state.get("rag") is not None)},
    )


@app.get("/notifications", response_class=HTMLResponse)
def notifications_page(request: Request, user: dict = Depends(require("owner"))):
    return _notify_view(request, user)


@app.post("/notifications/test", response_class=HTMLResponse)
def notifications_test(request: Request, user: dict = Depends(require("owner"))):
    """Send one real push, so the operator can prove the phone leg end-to-end."""
    _guard_origin(request)
    if not notifier.configured():
        return _notify_view(request, user, "not configured — set NWP_CONSOLE_GOTIFY_URL and "
                                           "provision the token file (see the setup steps below)")
    ok = notifier.send(
        "✅ NWP Console test",
        f"Test push requested by {user['name']} at {notify._now_iso()}.\n"
        "If you can read this on your phone, the whole chain works.",
        notify.P_LOW, f"{config.ORIGIN}/?tab=fleet",
    )
    audit.append(user["name"], user["role"], "notify.test", {"delivered": ok}, ok)
    return _notify_view(request, user,
                        "test push accepted by Gotify" if ok else
                        "Gotify did NOT accept the push — check the URL, the token file, and that "
                        "the Gotify service is up (the console itself is unaffected)")


@app.post("/notifications/check", response_class=HTMLResponse)
def notifications_check(request: Request, user: dict = Depends(require("owner"))):
    """Run a checker pass now instead of waiting for the interval."""
    _guard_origin(request)
    res = _notify_pass()
    if res.get("skipped"):
        return _notify_view(request, user, "not configured — nothing was checked")
    if not res.get("ok"):
        return _notify_view(request, user, f"check failed: {res.get('error', 'unknown')}")
    return _notify_view(request, user,
                        f"checked: {res['events']} event(s) detected, {res['sent']} sent, "
                        f"{res['failed']} failed")
# -- voice (viewer+): speech in, speech out — BOTH LOCAL TO THIS HOST -------
# Speaking to Quokka is exactly as privileged as typing to it: /quokka/stt
# only returns text, which the page then posts to /quokka/chat like any other
# message. No cloud speech API is involved on either leg (see app/voice.py).
_VOICE_STATUS = {"unavailable": 503, "too_large": 413, "too_long": 413, "unreadable": 400, "failed": 500}


@app.post("/quokka/stt")
def quokka_stt(request: Request, audio: UploadFile = File(...), sc: Scope = Depends(scoped("viewer"))):
    """Push-to-talk audio -> transcript. The audio is never persisted and never
    logged; the transcript is audited exactly like a typed message."""
    _guard_origin(request)
    if not voice.stt_available():
        raise HTTPException(status_code=503, detail="Speech recognition isn't available on this host — type instead.")
    try:
        # Cap the read itself: one byte over the limit is enough to refuse
        # without ever materialising a big buffer.
        blob = audio.file.read(config.STT_MAX_BYTES + 1)
    except OSError:
        raise HTTPException(status_code=400, detail="could not read the upload") from None
    finally:
        try:
            audio.file.close()  # starlette's spill file is unlinked on close
        except OSError:
            pass
    try:
        res = voice.transcribe(blob)
    except voice.VoiceError as e:
        audit.append(sc.user, sc.global_role, "quokka.stt",
                     {"audio_bytes": len(blob), "error": f"{e.kind}: {str(e)[:160]}"}, False,
                     project=sc.project_id)
        raise HTTPException(status_code=_VOICE_STATUS.get(e.kind, 500), detail=str(e)[:200]) from None
    audit.append(
        sc.user, sc.global_role, "quokka.stt",
        {"transcript": res["text"][:200], "audio_bytes": len(blob), "audio_secs": res["duration"],
         "secs": res["secs"], "backend": res["backend"], "model": config.STT_MODEL},
        True, project=sc.project_id,
    )
    return JSONResponse({"transcript": res["text"], "secs": res["secs"], "duration": res["duration"]})


@app.post("/quokka/tts")
def quokka_tts(request: Request, text: str = Form(...), sc: Scope = Depends(scoped("viewer"))):
    """Reply text -> WAV from the local piper voice. 503 when piper isn't
    installed; the page then falls back to the device's own offline voices."""
    _guard_origin(request)
    started = time.time()
    try:
        wav = voice.synthesize(text)
    except voice.VoiceError as e:
        raise HTTPException(status_code=_VOICE_STATUS.get(e.kind, 500), detail=str(e)[:200]) from None
    # The words were already audited as Quokka's reply — record only that the
    # speaker was used, not the text again.
    audit.append(sc.user, sc.global_role, "quokka.tts",
                 {"chars": len(text), "wav_bytes": len(wav), "secs": round(time.time() - started, 2),
                  "backend": voice.tts_backend()}, True, project=sc.project_id)
    return Response(wav, media_type="audio/wav", headers={"Cache-Control": "no-store"})


# -- GitLab-backed issue actions (operator+) --------------------------------
def _iid_ok(iid: int) -> int:
    if not (0 < iid < 10_000_000):
        raise HTTPException(status_code=400, detail="bad issue iid")
    return iid


def _require_issue_in_scope(sc: Scope, iid: int) -> None:
    """An issue is writable only if it carries one of THIS scope's labels.

    The check re-fetches the issue rather than trusting the pane that offered
    the button: the pane was rendered from a filtered list, but a POST is a
    fresh request and its iid is entirely attacker-chosen. An unscoped (owner)
    caller skips the fetch — they may write to anything.

    Fail-closed on an API error: if we cannot prove the issue is in scope, we
    refuse. A tracker outage must not become a write-anywhere window.
    """
    if sc.all_sites:
        return
    if not sc.issue_labels:
        raise HTTPException(status_code=403, detail="this project has no issue label configured")
    r = gitlab.get_issue(config.OPS_PROJECT, iid)
    if not r.get("ok"):
        raise HTTPException(status_code=502, detail="cannot verify issue scope (tracker unreachable)")
    if not sc.issue_allowed(r.get("data") or {}):
        audit.append(sc.user, sc.global_role, "scope.denied",
                     {"iid": iid, "reason": "issue not labelled for this project"}, False,
                     project=sc.project_id)
        raise HTTPException(status_code=403, detail="issue is not in this project")


@app.post("/issues/{iid}/note", response_class=HTMLResponse)
def issue_note(request: Request, iid: int, body: str = Form(...), sc: Scope = Depends(scoped("operator"))):
    _guard_origin(request)
    _require_issue_in_scope(sc, _iid_ok(iid))
    r = gitlab.post_note(config.OPS_PROJECT, _iid_ok(iid), body)
    audit.append(sc.user, sc.global_role, "issue.note", {"iid": iid, "ok": r.get("ok"), "len": len(body)},
                 r.get("ok", False), project=sc.project_id)
    return _pane(request, "issue_action_result.html", {"iid": iid, "verb": "note", "r": r}, sc, redactable=False)


@app.post("/issues/{iid}/label", response_class=HTMLResponse)
def issue_label(
    request: Request, iid: int, label: str = Form(...), mode: str = Form("add"),
    sc: Scope = Depends(scoped("operator")),
):
    _guard_origin(request)
    _require_issue_in_scope(sc, _iid_ok(iid))
    want = label.strip()
    # Removing the label that PUTS the issue in your project would move it out
    # of your own view and into nobody's — a scoped operator may not do that.
    if not sc.all_sites and mode == "remove" and want in sc.issue_labels:
        raise HTTPException(status_code=403, detail="cannot remove this project's own scoping label")
    fn = gitlab.remove_label if mode == "remove" else gitlab.add_label
    r = fn(config.OPS_PROJECT, _iid_ok(iid), want)
    audit.append(sc.user, sc.global_role, "issue.label",
                 {"iid": iid, "label": want, "mode": mode, "ok": r.get("ok")},
                 r.get("ok", False), project=sc.project_id)
    return _pane(request, "issue_action_result.html", {"iid": iid, "verb": f"label {mode}", "r": r}, sc,
                 redactable=False)


@app.post("/issues/{iid}/close", response_class=HTMLResponse)
def issue_close(request: Request, iid: int, sc: Scope = Depends(scoped("operator"))):
    _guard_origin(request)
    _require_issue_in_scope(sc, _iid_ok(iid))
    r = gitlab.close_issue(config.OPS_PROJECT, _iid_ok(iid))
    audit.append(sc.user, sc.global_role, "issue.close", {"iid": iid, "ok": r.get("ok")},
                 r.get("ok", False), project=sc.project_id)
    return _pane(request, "issue_action_result.html", {"iid": iid, "verb": "close", "r": r}, sc, redactable=False)


@app.post("/ci/retry", response_class=HTMLResponse)
def ci_retry(request: Request, project: str = Form(...), pipeline_id: int = Form(...),
             sc: Scope = Depends(scoped("operator"))):
    _guard_origin(request)
    # sc.ci_projects is already the intersection of this project's declared CI
    # projects with the console's configured allowlist, so this one test does
    # the work of both. A project with none configured retries nothing.
    if not sc.ci_allowed(project):
        raise HTTPException(status_code=400, detail="unknown project")
    r = gitlab.retry_pipeline(project, pipeline_id)
    audit.append(sc.user, sc.global_role, "ci.retry",
                 {"project": project, "pipeline": pipeline_id, "ok": r.get("ok")},
                 r.get("ok", False), project=sc.project_id)
    return _pane(request, "issue_action_result.html", {"iid": pipeline_id, "verb": "pipeline retry", "r": r}, sc,
                 redactable=False)


# ---------------------------------------------------------------------------
# audit page (operator+) + user management (owner)
# ---------------------------------------------------------------------------
@app.get("/audit", response_class=HTMLResponse)
def audit_page(request: Request, sc: Scope = Depends(scoped("operator"))):
    """A scoped operator sees only their own project's entries. Entries written
    before projects existed carry no `project` key at all and are therefore
    owner-only: a backfill would have to guess which tenant they belonged to,
    and a guess in an audit log is worse than an omission."""
    entries = [e for e in audit.tail(300) if sc.audit_allowed(e)]
    return templates.TemplateResponse(
        request, "audit.html",
        {"user": _user_of(sc), "entries": entries, "scope": sc},
    )


@app.get("/users", response_class=HTMLResponse)
def users_page(request: Request, user: dict = Depends(require("owner"))):
    return templates.TemplateResponse(
        request, "users.html",
        {"user": user, "users": store.list_users(), "message": None, "enrol_link": None,
         "projects": projects.list_projects()},
    )


def _users_view(request: Request, user: dict, message: str, enrol_link: str | None = None) -> HTMLResponse:
    return templates.TemplateResponse(
        request, "users.html",
        {"user": user, "users": store.list_users(), "message": message, "enrol_link": enrol_link,
         "projects": projects.list_projects()},
    )


@app.post("/users/add", response_class=HTMLResponse)
def users_add(request: Request, name: str = Form(...), role: str = Form("viewer"),
              project: str = Form(""), project_role: str = Form("viewer"),
              user: dict = Depends(require("owner"))):
    """Create a user, optionally with their first membership in the same write.

    Onboarding a dev is one action, so it is one lock: a user who exists for a
    moment with no project would be shown /no-project by any request that
    raced in, and — worse — the two-step version invites forgetting step two,
    which leaves an account that can log in and see nothing forever.
    """
    _guard_origin(request)
    try:
        token = store.add_user(name.strip(), role, config.ENROL_TOKEN_HOURS,
                               project=project.strip(), project_role=project_role)
    except StoreError as e:
        return _users_view(request, user, f"error: {e}")
    audit.append(user["name"], user["role"], "user.add",
                 {"name": name.strip(), "role": role,
                  "project": project.strip() or None, "project_role": project_role if project.strip() else None},
                 True, project=project.strip() or None)
    where = f" in project '{project.strip()}' as {project_role}" if project.strip() else ""
    return _users_view(request, user,
                       f"user '{name.strip()}' created ({role}){where}. One-time enrolment link (shown ONCE):",
                       f"{config.ORIGIN}/enroll?token={token}")


@app.post("/users/{name}/reset", response_class=HTMLResponse)
def users_reset(request: Request, name: str, user: dict = Depends(require("owner"))):
    _guard_origin(request)
    try:
        token = store.reset_user(name, config.ENROL_TOKEN_HOURS)
    except StoreError as e:
        return _users_view(request, user, f"error: {e}")
    audit.append(user["name"], user["role"], "user.reset", {"name": name}, True)
    return _users_view(request, user, f"user '{name}' passkeys revoked. New one-time enrolment link (shown ONCE):",
                       f"{config.ORIGIN}/enroll?token={token}")


@app.post("/users/{name}/role", response_class=HTMLResponse)
def users_role(request: Request, name: str, role: str = Form(...), user: dict = Depends(require("owner"))):
    _guard_origin(request)
    if name == user["name"]:
        return _users_view(request, user, "refusing to change your own role (ask another owner or use the shell CLI)")
    try:
        store.set_role(name, role)
    except StoreError as e:
        return _users_view(request, user, f"error: {e}")
    audit.append(user["name"], user["role"], "user.role", {"name": name, "role": role}, True)
    return _users_view(request, user, f"user '{name}' role -> {role}")


@app.post("/users/{name}/delete", response_class=HTMLResponse)
def users_delete(request: Request, name: str, user: dict = Depends(require("owner"))):
    _guard_origin(request)
    if name == user["name"]:
        return _users_view(request, user, "refusing to delete yourself")
    try:
        store.remove_user(name)
    except StoreError as e:
        return _users_view(request, user, f"error: {e}")
    audit.append(user["name"], user["role"], "user.rm", {"name": name}, True)
    return _users_view(request, user, f"user '{name}' removed")


# ---------------------------------------------------------------------------
# projects (owner) — the tenancy boundary itself
#
# EDITING A PROJECT'S SITE LIST IS A PERMISSION GRANT. That is the whole
# reason these routes are require("owner") and not scoped("maintainer"): a
# project maintainer may hand out access to what the project already contains,
# but only an owner decides what it contains. Asserted by a test.
# ---------------------------------------------------------------------------
def _projects_view(request: Request, user: dict, message: str = "") -> HTMLResponse:
    known = sorted({s for p in projects.list_projects() for s in p["sites"]})
    return templates.TemplateResponse(
        request, "projects.html",
        {"user": user, "projects": projects.list_projects(), "message": message,
         "users": store.list_users(), "project_roles": PROJECT_ROLES,
         "demo_sites": config.DEMO_SITES, "ci_projects": config.CI_PROJECTS,
         "known_sites": known},
    )


def _split_csv(raw: str) -> list[str]:
    return [x.strip() for x in (raw or "").replace(",", " ").split() if x.strip()]


@app.get("/projects", response_class=HTMLResponse)
def projects_page(request: Request, user: dict = Depends(require("owner"))):
    return _projects_view(request, user)


@app.post("/projects/add", response_class=HTMLResponse)
def projects_add(request: Request, pid: str = Form(...), name: str = Form(""),
                 sites: str = Form(""), demo_sites: str = Form(""),
                 issue_label: str = Form(""), ci_projects: str = Form(""),
                 user: dict = Depends(require("owner"))):
    _guard_origin(request)
    try:
        projects.add_project(
            pid.strip(), name=name.strip(), sites=_split_csv(sites),
            demo_sites=_split_csv(demo_sites),
            gitlab={"issue_label": issue_label.strip(), "ci_projects": _split_csv(ci_projects)},
            created_by=user["name"],
        )
    except StoreError as e:
        return _projects_view(request, user, f"error: {e}")
    audit.append(user["name"], user["role"], "project.add",
                 {"pid": pid.strip(), "sites": _split_csv(sites)}, True, project=pid.strip())
    return _projects_view(request, user, f"project '{pid.strip()}' created")


@app.post("/projects/{pid}/sites", response_class=HTMLResponse)
def projects_sites(request: Request, pid: str, sites: str = Form(""), demo_sites: str = Form(""),
                   issue_label: str = Form(""), ci_projects: str = Form(""),
                   user: dict = Depends(require("owner"))):
    """Owner-only, and deliberately so — see the block comment above."""
    _guard_origin(request)
    try:
        projects.set_project(
            pid, sites=_split_csv(sites), demo_sites=_split_csv(demo_sites),
            gitlab={"issue_label": issue_label.strip(), "ci_projects": _split_csv(ci_projects)},
        )
    except StoreError as e:
        return _projects_view(request, user, f"error: {e}")
    audit.append(user["name"], user["role"], "project.sites",
                 {"pid": pid, "sites": _split_csv(sites)}, True, project=pid)
    return _projects_view(request, user, f"project '{pid}' updated")


@app.post("/projects/{pid}/delete", response_class=HTMLResponse)
def projects_delete(request: Request, pid: str, user: dict = Depends(require("owner"))):
    _guard_origin(request)
    try:
        gc = projects.remove_project(pid)
    except StoreError as e:
        return _projects_view(request, user, f"error: {e}")
    audit.append(user["name"], user["role"], "project.rm", {"pid": pid, "memberships_removed": gc}, True)
    return _projects_view(request, user, f"project '{pid}' removed ({gc} membership(s) revoked with it)")


def _may_administer(sc: Scope, pid: str) -> bool:
    """Owner anywhere; project maintainer only in their OWN project."""
    if sc.global_role == "owner":
        return True
    return sc.project_id == pid and sc.can("maintainer")


@app.post("/projects/{pid}/members", response_class=HTMLResponse)
def projects_add_member(request: Request, pid: str, member: str = Form(...),
                        role: str = Form("viewer"), sc: Scope = Depends(scoped("viewer"))):
    """Assign an EXISTING user to a project. A maintainer may not mint users
    (that is an owner power) and may not grant above their own project role —
    otherwise 'maintainer' would be a route to manufacturing an owner."""
    _guard_origin(request)
    if not _may_administer(sc, pid):
        raise HTTPException(status_code=403, detail="not a maintainer of this project")
    if sc.global_role != "owner" and not project_role_allows(sc.project_role, role):
        raise HTTPException(status_code=403, detail="cannot grant a role above your own")
    user = _user_of(sc)
    try:
        projects.set_project_role(member.strip(), pid, role)
    except StoreError as e:
        return _projects_view(request, user, f"error: {e}")
    audit.append(sc.user, sc.global_role, "project.assign",
                 {"pid": pid, "member": member.strip(), "role": role}, True, project=pid)
    return _projects_view(request, user, f"'{member.strip()}' assigned to '{pid}' as {role}")


@app.post("/projects/{pid}/members/{member}/delete", response_class=HTMLResponse)
def projects_del_member(request: Request, pid: str, member: str, sc: Scope = Depends(scoped("viewer"))):
    _guard_origin(request)
    if not _may_administer(sc, pid):
        raise HTTPException(status_code=403, detail="not a maintainer of this project")
    user = _user_of(sc)
    try:
        projects.unset_project_role(member, pid)
    except StoreError as e:
        return _projects_view(request, user, f"error: {e}")
    audit.append(sc.user, sc.global_role, "project.unassign", {"pid": pid, "member": member}, True, project=pid)
    return _projects_view(request, user, f"'{member}' removed from '{pid}'")


# ---------------------------------------------------------------------------
# PWA bits
# ---------------------------------------------------------------------------
@app.get("/manifest.webmanifest")
def manifest():
    return JSONResponse(
        {
            "name": "NWP Console",
            "short_name": "NWP",
            "start_url": "/",
            "display": "standalone",
            "background_color": "#10151c",
            "theme_color": "#10151c",
            "icons": [
                {"src": "/static/icon-192.png", "sizes": "192x192", "type": "image/png"},
                {"src": "/static/icon-512.png", "sizes": "512x512", "type": "image/png"},
            ],
        },
        media_type="application/manifest+json",
    )


@app.get("/sw.js")
def service_worker():
    return Response((BASE / "static" / "sw.js").read_text(), media_type="application/javascript")
