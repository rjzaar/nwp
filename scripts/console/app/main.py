"""NWP Console — FastAPI app (mesh-only, passkey-only, role-gated).

Transport gate = the Headscale mesh (uvicorn binds the tailnet IP only).
App gate = WebAuthn passkeys + three server-enforced roles + audit log.
Action gate = the fail-closed allowlist in actions.py (no live/prod verbs).
"""
from __future__ import annotations

import json
from pathlib import Path

from fastapi import Depends, FastAPI, Form, HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse, Response
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from itsdangerous import BadSignature, URLSafeTimedSerializer

from . import config, parsers, webauthn_flow
from .actions import ACTIONS, ActionError, build_action
from .authz import role_allows
from .gitlab_api import GitLab
from .runner import run_pl, run_pl_cached
from .store import AuditLog, StoreError, UserStore

BASE = Path(__file__).resolve().parent.parent

app = FastAPI(title="NWP Console", docs_url=None, redoc_url=None, openapi_url=None)
app.mount("/static", StaticFiles(directory=str(BASE / "static")), name="static")
templates = Jinja2Templates(directory=str(BASE / "templates"))

_signer = URLSafeTimedSerializer(config.secret_key(), salt="nwp-console-session")
_challenge_signer = URLSafeTimedSerializer(config.secret_key(), salt="nwp-console-challenge")

store = UserStore(config.DATA_DIR / "users.json")
audit = AuditLog(config.DATA_DIR / "audit.jsonl")
gitlab = GitLab(config.GITLAB_HOST, config.GITLAB_TOKEN_FILE)


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
def index(request: Request, user: dict = Depends(require("viewer"))):
    return templates.TemplateResponse(
        request,
        "index.html",
        {"user": user, "gitlab_url": gitlab.web_url(), "can_act": role_allows(user["role"], "operator")},
    )


def _pane(request: Request, template: str, ctx: dict, user: dict) -> HTMLResponse:
    ctx = dict(ctx, user=user, can_act=role_allows(user["role"], "operator"))
    return templates.TemplateResponse(request, template, ctx)


@app.get("/panes/fleet", response_class=HTMLResponse)
def pane_fleet(request: Request, force: int = 0, user: dict = Depends(require("viewer"))):
    res = run_pl_cached(config.NWP_ROOT, ["rag", "--json", "--no-todo"],
                        ttl=config.PANE_CACHE_TTL, timeout=config.PL_TIMEOUT, force=bool(force))
    rag = parsers.parse_rag(res["out"]) if res["out"] else {"ok": False, "error": res["err"] or f"rc={res['rc']}"}
    return _pane(request, "pane_fleet.html", {"rag": rag, "res": res}, user)


@app.get("/panes/todo", response_class=HTMLResponse)
def pane_todo(request: Request, force: int = 0, user: dict = Depends(require("viewer"))):
    res = run_pl_cached(config.NWP_ROOT, ["todo", "check", "--json"],
                        ttl=config.PANE_CACHE_TTL, timeout=config.PL_TIMEOUT, force=bool(force))
    todo = parsers.parse_todo(res["out"]) if res["out"] else {"ok": False, "error": res["err"] or f"rc={res['rc']}"}
    return _pane(request, "pane_todo.html", {"todo": todo, "res": res}, user)


@app.get("/panes/backups", response_class=HTMLResponse)
def pane_backups(request: Request, force: int = 0, user: dict = Depends(require("viewer"))):
    res = run_pl_cached(config.NWP_ROOT, ["todo", "check", "--json"],
                        ttl=config.PANE_CACHE_TTL, timeout=config.PL_TIMEOUT, force=bool(force))
    todo = parsers.parse_todo(res["out"]) if res["out"] else {"ok": False, "error": res["err"] or f"rc={res['rc']}"}
    items = parsers.todo_backup_items(todo)
    return _pane(request, "pane_backups.html", {"items": items, "todo_ok": todo.get("ok", False), "res": res}, user)


@app.get("/panes/demo", response_class=HTMLResponse)
def pane_demo(request: Request, force: int = 0, user: dict = Depends(require("viewer"))):
    sites = []
    for site in config.DEMO_SITES:
        st = run_pl_cached(config.NWP_ROOT, ["demo", "status", site],
                           ttl=config.PANE_CACHE_TTL, timeout=config.PL_TIMEOUT, force=bool(force))
        codes = run_pl_cached(config.NWP_ROOT, ["demo", "codes", site, "list"],
                              ttl=config.PANE_CACHE_TTL, timeout=config.PL_TIMEOUT, force=bool(force))
        sites.append(
            {
                "site": site,
                "status": parsers.parse_demo_status(st["out"] if st["rc"] == 0 else st["out"] + "\n" + st["err"]),
                "codes": parsers.parse_demo_codes(codes["out"]),
                "rc": st["rc"],
            }
        )
    from .actions import BUNDLES

    return _pane(request, "pane_demo.html", {"demo_sites": sites, "bundles": BUNDLES}, user)


@app.get("/panes/issues", response_class=HTMLResponse)
def pane_issues(request: Request, user: dict = Depends(require("viewer"))):
    r = gitlab.list_issues(config.OPS_PROJECT)
    issues = r.get("data") if r.get("ok") else []
    return _pane(
        request,
        "pane_issues.html",
        {
            "issues": issues or [],
            "api_ok": r.get("ok", False),
            "api_error": r.get("error", ""),
            "project": config.OPS_PROJECT,
            "project_url": gitlab.web_url(config.OPS_PROJECT),
        },
        user,
    )


@app.get("/panes/ci", response_class=HTMLResponse)
def pane_ci(request: Request, user: dict = Depends(require("viewer"))):
    blocks = []
    api_ok = gitlab.has_token()
    for project in config.CI_PROJECTS:
        mrs = []
        r = gitlab.open_mrs(project)
        for mr in (r.get("data") or []) if r.get("ok") else []:
            d = gitlab.mr_detail(project, mr["iid"])
            pipe = (d.get("data") or {}).get("head_pipeline") if d.get("ok") else None
            mrs.append({"mr": mr, "pipeline": pipe})
        blocks.append({"project": project, "mrs": mrs, "url": gitlab.web_url(project + "/-/merge_requests")})
    return _pane(request, "pane_ci.html", {"blocks": blocks, "api_ok": api_ok}, user)


# ---------------------------------------------------------------------------
# actions (operator+) — the ONLY shell-out path, via the allowlist
# ---------------------------------------------------------------------------
@app.post("/actions/run", response_class=HTMLResponse)
def action_run(
    request: Request,
    action: str = Form(...),
    site: str = Form(""),
    bundle: str = Form(""),
    code_id: str = Form(""),
    user: dict = Depends(require("operator")),
):
    _guard_origin(request)
    params = {"site": site, "bundle": bundle, "code_id": code_id}
    try:
        argv, min_role = build_action(action, params, config.DEMO_SITES)
    except ActionError as e:
        audit.append(user["name"], user["role"], f"action.{action}", {"params": params, "rejected": str(e)}, False)
        return _pane(request, "action_result.html", {"label": action, "res": None, "error": str(e)}, user)
    if not role_allows(user["role"], min_role):
        raise HTTPException(status_code=403)
    res = run_pl(config.NWP_ROOT, argv, timeout=config.PL_TIMEOUT)
    audit.append(
        user["name"], user["role"], f"action.{action}",
        {"argv": argv, "rc": res["rc"], "secs": res["secs"]}, res["rc"] == 0,
    )
    label = ACTIONS[action]["label"]
    res_view = dict(res, out=parsers.strip_ansi(res["out"])[-8000:], err=parsers.strip_ansi(res["err"])[-2000:])
    return _pane(request, "action_result.html", {"label": label, "res": res_view, "error": None}, user)


# -- GitLab-backed issue actions (operator+) --------------------------------
def _iid_ok(iid: int) -> int:
    if not (0 < iid < 10_000_000):
        raise HTTPException(status_code=400, detail="bad issue iid")
    return iid


@app.post("/issues/{iid}/note", response_class=HTMLResponse)
def issue_note(request: Request, iid: int, body: str = Form(...), user: dict = Depends(require("operator"))):
    _guard_origin(request)
    r = gitlab.post_note(config.OPS_PROJECT, _iid_ok(iid), body)
    audit.append(user["name"], user["role"], "issue.note", {"iid": iid, "ok": r.get("ok"), "len": len(body)}, r.get("ok", False))
    return _pane(request, "issue_action_result.html", {"iid": iid, "verb": "note", "r": r}, user)


@app.post("/issues/{iid}/label", response_class=HTMLResponse)
def issue_label(
    request: Request, iid: int, label: str = Form(...), mode: str = Form("add"), user: dict = Depends(require("operator"))
):
    _guard_origin(request)
    fn = gitlab.remove_label if mode == "remove" else gitlab.add_label
    r = fn(config.OPS_PROJECT, _iid_ok(iid), label.strip())
    audit.append(user["name"], user["role"], "issue.label", {"iid": iid, "label": label.strip(), "mode": mode, "ok": r.get("ok")}, r.get("ok", False))
    return _pane(request, "issue_action_result.html", {"iid": iid, "verb": f"label {mode}", "r": r}, user)


@app.post("/issues/{iid}/close", response_class=HTMLResponse)
def issue_close(request: Request, iid: int, user: dict = Depends(require("operator"))):
    _guard_origin(request)
    r = gitlab.close_issue(config.OPS_PROJECT, _iid_ok(iid))
    audit.append(user["name"], user["role"], "issue.close", {"iid": iid, "ok": r.get("ok")}, r.get("ok", False))
    return _pane(request, "issue_action_result.html", {"iid": iid, "verb": "close", "r": r}, user)


@app.post("/ci/retry", response_class=HTMLResponse)
def ci_retry(request: Request, project: str = Form(...), pipeline_id: int = Form(...), user: dict = Depends(require("operator"))):
    _guard_origin(request)
    if project not in config.CI_PROJECTS:
        raise HTTPException(status_code=400, detail="unknown project")
    r = gitlab.retry_pipeline(project, pipeline_id)
    audit.append(user["name"], user["role"], "ci.retry", {"project": project, "pipeline": pipeline_id, "ok": r.get("ok")}, r.get("ok", False))
    return _pane(request, "issue_action_result.html", {"iid": pipeline_id, "verb": "pipeline retry", "r": r}, user)


# ---------------------------------------------------------------------------
# audit page (operator+) + user management (owner)
# ---------------------------------------------------------------------------
@app.get("/audit", response_class=HTMLResponse)
def audit_page(request: Request, user: dict = Depends(require("operator"))):
    return templates.TemplateResponse(request, "audit.html", {"user": user, "entries": audit.tail(300)})


@app.get("/users", response_class=HTMLResponse)
def users_page(request: Request, user: dict = Depends(require("owner"))):
    return templates.TemplateResponse(
        request, "users.html", {"user": user, "users": store.list_users(), "message": None, "enrol_link": None}
    )


def _users_view(request: Request, user: dict, message: str, enrol_link: str | None = None) -> HTMLResponse:
    return templates.TemplateResponse(
        request, "users.html", {"user": user, "users": store.list_users(), "message": message, "enrol_link": enrol_link}
    )


@app.post("/users/add", response_class=HTMLResponse)
def users_add(request: Request, name: str = Form(...), role: str = Form("viewer"), user: dict = Depends(require("owner"))):
    _guard_origin(request)
    try:
        token = store.add_user(name.strip(), role, config.ENROL_TOKEN_HOURS)
    except StoreError as e:
        return _users_view(request, user, f"error: {e}")
    audit.append(user["name"], user["role"], "user.add", {"name": name.strip(), "role": role}, True)
    return _users_view(request, user, f"user '{name.strip()}' created ({role}). One-time enrolment link (shown ONCE):",
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
