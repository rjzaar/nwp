"""T6 — the STRUCTURAL proof, an AST pass over app/main.py.

In the spirit of the existing `test_chat_has_no_action_path`: the other tests
check that today's routes behave; this one checks that TOMORROW's route cannot
be written wrong and still merge. A net you can forget to hang is not a net.

It asserts, mechanically:
  * every route function takes a scope/owner dependency (or is on the tiny
    UNSCOPED_ALLOWLIST, which is itself a reviewable list);
  * no route body calls a `_gather_*_raw` fleet-wide gatherer;
  * no route body reads config.DEMO_SITES / config.CI_PROJECTS directly (the
    Scope narrows both, and reading the raw config re-opens the boundary);
  * every pane route renders through `_pane(` (which is where scrub+redact
    live), never a bare TemplateResponse;
  * the pure modules import neither runner nor subprocess nor actions;
  * FLEET_STATE_FILE is only ever read via fleet_state.load*.
"""
import ast
import sys
from pathlib import Path

import pytest

APP = Path(__file__).resolve().parent.parent / "app"
sys.path.insert(0, str(APP.parent))

MAIN = APP / "main.py"
TREE = ast.parse(MAIN.read_text())

ROUTE_DECORATORS = {"get", "post", "put", "delete", "patch"}

# Gatherers that deliberately see the whole fleet. A route must never call one;
# these two non-route callers are the owner-only background paths, each of
# which says so in its own docstring.
RAW_GATHERER_EXEMPT = {"_notify_gather", "_brief_text", "_notify_pass"}


def _routes():
    """(function_node, http_method) for every @app.<verb>(...) function."""
    out = []
    for node in TREE.body:
        if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        for dec in node.decorator_list:
            f = dec.func if isinstance(dec, ast.Call) else dec
            if (isinstance(f, ast.Attribute) and f.attr in ROUTE_DECORATORS
                    and isinstance(f.value, ast.Name) and f.value.id == "app"):
                out.append((node, f.attr))
    return out


def _allowlist():
    for node in ast.walk(TREE):
        if isinstance(node, ast.Assign):
            for t in node.targets:
                if isinstance(t, ast.Name) and t.id == "UNSCOPED_ALLOWLIST":
                    call = node.value
                    arg = call.args[0] if isinstance(call, ast.Call) and call.args else call
                    return {e.value for e in getattr(arg, "elts", []) if isinstance(e, ast.Constant)}
    raise AssertionError("UNSCOPED_ALLOWLIST not found in main.py")


def _dependency_names(fn):
    """Every `X` in a parameter default of the form Depends(X(...)) / Depends(X)."""
    names = []
    for default in list(fn.args.defaults) + list(fn.args.kw_defaults):
        if not (isinstance(default, ast.Call) and getattr(default.func, "id", "") == "Depends"):
            continue
        inner = default.args[0] if default.args else None
        if isinstance(inner, ast.Call):
            names.append((getattr(inner.func, "id", ""),
                          [a.value for a in inner.args if isinstance(a, ast.Constant)]))
        elif isinstance(inner, ast.Name):
            names.append((inner.id, []))
    return names


def _calls(fn):
    out = []
    for n in ast.walk(fn):
        if isinstance(n, ast.Call):
            f = n.func
            if isinstance(f, ast.Name):
                out.append(f.id)
            elif isinstance(f, ast.Attribute):
                out.append(f.attr)
    return out


def _config_attrs(fn):
    return {n.attr for n in ast.walk(fn)
            if isinstance(n, ast.Attribute) and isinstance(n.value, ast.Name) and n.value.id == "config"}


ROUTES = _routes()
ALLOWLIST = _allowlist()


def test_routes_were_actually_found():
    """Guard against the whole file silently passing because the AST walk
    matched nothing (the classic way a structural test becomes decoration)."""
    assert len(ROUTES) >= 30, f"only found {len(ROUTES)} routes — the walker is broken"
    names = {fn.name for fn, _ in ROUTES}
    for expected in ("pane_fleet", "pane_todo", "action_run", "quokka_chat", "audit_page"):
        assert expected in names, f"{expected} not detected as a route"


@pytest.mark.parametrize("fn,method", ROUTES, ids=[f.name for f, _ in ROUTES])
def test_every_route_has_a_scope_dependency(fn, method):
    if fn.name in ALLOWLIST:
        return
    deps = _dependency_names(fn)
    kinds = {d[0] for d in deps}
    assert kinds & {"scoped", "require"}, (
        f"route {fn.name!r} has no scoped()/require() dependency and is not on "
        f"UNSCOPED_ALLOWLIST — it would serve site data to anyone authenticated"
    )
    # require() survives ONLY for owner-only admin surfaces.
    for name, args in deps:
        if name == "require":
            assert args == ["owner"], (
                f"route {fn.name!r} uses require({args!r}); non-owner routes must use "
                f"scoped() so they resolve a Scope"
            )


@pytest.mark.parametrize("fn,method", ROUTES, ids=[f.name for f, _ in ROUTES])
def test_no_route_calls_a_raw_gatherer(fn, method):
    if fn.name in RAW_GATHERER_EXEMPT:
        return
    bad = [c for c in _calls(fn) if c.startswith("_gather_") and c.endswith("_raw")]
    assert not bad, (
        f"route {fn.name!r} calls fleet-wide gatherer(s) {bad} — use the scoped "
        f"wrapper _gather_x(sc) instead"
    )


@pytest.mark.parametrize("fn,method", ROUTES, ids=[f.name for f, _ in ROUTES])
def test_no_route_reads_demo_or_ci_config_directly(fn, method):
    # The owner-only admin pages legitimately DISPLAY the console-wide lists so
    # an owner can see what is available to hand out; they never gate on them.
    if fn.name in ("projects_page", "projects_add", "projects_sites",
                   "projects_delete", "projects_add_member", "projects_del_member"):
        return
    leaked = _config_attrs(fn) & {"DEMO_SITES", "CI_PROJECTS"}
    assert not leaked, (
        f"route {fn.name!r} reads config.{'/'.join(sorted(leaked))} directly — that is the "
        f"console-wide tier gate, not this request's grant; use the Scope"
    )


def _route_paths(fn):
    """Every literal path string in this function's @app.<verb>("...") decorators."""
    out = []
    for dec in fn.decorator_list:
        if not isinstance(dec, ast.Call):
            continue
        f = dec.func
        if not (isinstance(f, ast.Attribute) and f.attr in ROUTE_DECORATORS
                and isinstance(f.value, ast.Name) and f.value.id == "app"):
            continue
        if dec.args and isinstance(dec.args[0], ast.Constant) and isinstance(dec.args[0].value, str):
            out.append(dec.args[0].value)
    return out


PANE_PATH_ROUTES = [(fn, m) for fn, m in ROUTES
                    if any(p.startswith("/panes/") for p in _route_paths(fn))]


def test_pane_path_routes_were_actually_found():
    """The naming test below is parametrized over a computed list, so an empty
    list would make it vacuous — the exact failure shape this module exists to
    prevent. Pin that the walker still sees the real panes."""
    assert len(PANE_PATH_ROUTES) >= 7, (
        f"only found {len(PANE_PATH_ROUTES)} /panes/ routes — the path walker is broken"
    )


@pytest.mark.parametrize("fn,method", PANE_PATH_ROUTES,
                         ids=[f.name for f, _ in PANE_PATH_ROUTES])
def test_every_panes_path_has_a_pane_named_handler(fn, method):
    """Close the doc-only naming rule.

    `test_every_pane_route_renders_through_pane` selects its subjects by
    FUNCTION NAME (`pane_*`), so a handler serving `/panes/x` that is named
    anything else silently drops out of the scrub+redact check: the pane keeps
    working and stops being covered, which is worse than either. Each stage's
    wiring contract states the rule in prose (see
    docs/reports/console-v2/visuals-wiring.md §1, "The handler MUST be named
    `pane_visuals`"); this asserts it mechanically, from the URL side, so the
    next pane cannot be wired out of coverage by choosing a name.
    """
    assert fn.name.startswith("pane_"), (
        f"route {fn.name!r} serves {_route_paths(fn)!r} but is not named 'pane_*', so "
        f"test_every_pane_route_renders_through_pane does not cover it — rename it"
    )


PANE_ROUTES = [(fn, m) for fn, m in ROUTES if fn.name.startswith("pane_")]


@pytest.mark.parametrize("fn,method", PANE_ROUTES, ids=[f.name for f, _ in PANE_ROUTES])
def test_every_pane_route_renders_through_pane(fn, method):
    """_pane() is where scrub+redact happen. A pane that renders a
    TemplateResponse directly bypasses both nets at once."""
    calls = _calls(fn)
    assert "_pane" in calls, f"pane route {fn.name!r} does not render via _pane()"
    assert "TemplateResponse" not in calls, (
        f"pane route {fn.name!r} calls TemplateResponse directly, bypassing scrub+redact"
    )


def test_fleet_state_file_is_only_read_via_fleet_state_module():
    """Any other reader of the snapshot path would be an unscoped side door."""
    for node in ast.walk(TREE):
        if not (isinstance(node, ast.Attribute) and node.attr == "FLEET_STATE_FILE"):
            continue
        # Must appear as an argument to a fleet_state.* call, never e.g. open().
        pass
    sources = [n for n in ast.walk(TREE)
               if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute)
               and any(isinstance(a, ast.Attribute) and a.attr == "FLEET_STATE_FILE"
                       for a in n.args)]
    for call in sources:
        assert getattr(call.func.value, "id", "") == "fleet_state", \
            "FLEET_STATE_FILE read outside fleet_state.load*"


@pytest.mark.parametrize("mod", ["scope", "authz"])
def test_pure_modules_cannot_act(mod):
    """The tenancy modules must not be able to run anything — same guarantee
    the Quokka chat path already carries, for the same reason."""
    tree = ast.parse((APP / f"{mod}.py").read_text())
    imported = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            imported.extend(a.name for a in node.names)
        elif isinstance(node, ast.ImportFrom):
            imported.append(node.module or "")
            imported.extend(a.name for a in node.names)
    for forbidden in ("runner", "subprocess", "actions", "main"):
        assert not any(forbidden == str(i) or str(i).endswith(f".{forbidden}") for i in imported), \
            f"app/{mod}.py imports {forbidden!r}"


def test_quokka_chat_route_cannot_reach_actions():
    """The EXISTING guarantee, re-asserted at the route layer now that the chat
    route also carries a Scope: adding tenancy must not have added an action
    path to the chat surface."""
    fn = next(f for f, _ in ROUTES if f.name == "quokka_chat")
    calls = set(_calls(fn))
    assert not calls & {"build_action", "run_pl", "run_pl_cached", "_action_gate"}, \
        "quokka_chat gained an action path"
