#!/bin/bash
set -euo pipefail
################################################################################
# scripts/commands/fleet.sh — publish fleet state to a console host (pl fleet)
#
# WHY THIS EXISTS
# ---------------
# The NWP Console runs on the console host and used to shell out to
# `pl rag` / `pl todo check` THERE. But the sites live on the workstation, so
# the console host's `pl rag --json` legitimately returns ZERO sites: the Fleet
# tab was empty and the flagship "a site went RED" push could never fire.
#
# The console should DISPLAY fleet state, not try to compute it. So the machine
# that HAS the sites publishes one compact, schema-versioned snapshot, and the
# console consumes it (see scripts/console/app/fleet_state.py).
#
#   pl fleet publish [--to <host>]   gather -> snapshot -> ship (0600) -> verify
#   pl fleet snapshot [--out <path>] gather -> snapshot only (no network)
#   pl fleet status [--to <host>]    what is published locally / on the host
#   pl fleet schedule [--remove]     install the periodic publish cron HERE
#
# Idempotent and safe to run often: it only ever writes one file, atomically.
# Exits non-zero if the snapshot could not be built or could not be shipped.
#
# Publishing host: today the workstation (where the sites are). Later ver/met
# can take it over — nothing in the schema is workstation-specific beyond the
# recorded `generated_by.host`, which is exactly the provenance the UI shows.
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
PROJECT_ROOT="${PROJECT_ROOT:-$REPO_ROOT}"

source "$REPO_ROOT/lib/ui.sh"
source "$REPO_ROOT/lib/impact.sh"   # ops#47 impact contract (see cmd_schedule)

# --- schema ------------------------------------------------------------------
# Bump FLEET_SCHEMA_VERSION on any BREAKING change to the snapshot shape. The
# consumer refuses versions it does not know rather than mis-rendering them.
#
# The `security` feed was ADDED WITHOUT a version bump, deliberately. The
# consumer rejects the WHOLE snapshot when the version is unknown
# (fleet_state.SUPPORTED_VERSIONS), so bumping to 2 would blank the Fleet AND
# Todo panes on any console that had not been upgraded yet — a new feature
# taking out two working ones during the deploy window. Adding a feed is
# backwards-compatible by construction instead: an old console never asks for
# `security` and ignores it, and a new console tolerates a snapshot that has no
# `security` feed (it says "no security data in this snapshot"). Both
# directions are covered by tests. v2 stays reserved for a real BREAKING change.
FLEET_SCHEMA="nwp.fleet-state"
FLEET_SCHEMA_VERSION=1

# Where `pl audit` caches its per-site composer-audit records. The security
# feed is built FROM this cache, not from a fresh `composer audit` — see
# scripts/console/app/advisories.py for why (16 × ddev exec would not fit the
# */30 publish window, and would let the console disagree with `pl rag`).
AUDIT_STATE_DIR="${NWP_AUDIT_STATE_DIR:-$PROJECT_ROOT/private/update-awareness}"

# Advisory only: the console has its own NWP_CONSOLE_FLEET_MAX_AGE. This tells
# a consumer what cadence the publisher intends, so "stale" means something.
FLEET_MAX_AGE_HINT=7200          # 2h

LOCAL_STATE="$PROJECT_ROOT/private/fleet/fleet-state.json"
DEFAULT_REMOTE_REL=".local/share/nwp-console/fleet-state.json"

# ssh alias of the console host: --to > env > nwp.yml settings.console.host.
_console_cfg_file() {
    if [ -n "${NWP_CONSOLE_CONFIG:-}" ]; then
        [ -f "$NWP_CONSOLE_CONFIG" ] && printf '%s' "$NWP_CONSOLE_CONFIG"
        return 0
    fi
    local f
    for f in "$PROJECT_ROOT/nwp.yml" "$HOME/nwp-instances/_global/nwp.yml" "$HOME/nwp/nwp.yml"; do
        [ -f "$f" ] && { printf '%s' "$f"; return 0; }
    done
    return 0
}

_console_cfg() { # $1 key under settings.console, $2 default
    local f v=""
    f=$(_console_cfg_file)
    if [ -n "$f" ] && command -v yq >/dev/null 2>&1; then
        v=$(yq e ".settings.console.$1 // \"\"" "$f" 2>/dev/null | grep -v '^null$' || true)
    fi
    printf '%s' "${v:-$2}"
}

CONSOLE_HOST="${NWP_CONSOLE_HOST:-$(_console_cfg host "")}"

show_help() {
    cat <<EOF
${BOLD}pl fleet${NC} — publish fleet state to the console host

${BOLD}USAGE:${NC}
    pl fleet publish [--to <ssh-host>] [--dest <path>] [--no-todo] [--no-security]
                     [--refresh-security] [--dry-run] [--quiet]
                     [--allow-empty] [--force]
    pl fleet snapshot [--out <path>] [--no-todo] [--no-security] [--refresh-security]
    pl fleet security [--json]
    pl fleet estate [--json]
    pl fleet checkout [--json]
    pl fleet status [--to <ssh-host>]
    pl fleet schedule [--schedule "<cron>"] [--remove] [-y]
    pl fleet sync install|remove|run|status [--host=<role>]
                     [--schedule='*/15 * * * *'] [--dry-run] [--quiet]

${BOLD}WHY:${NC}
    The console host has no sites, so \`pl rag\` there sees an empty fleet. This
    publishes ONE snapshot from the machine that DOES have the sites; the
    console displays it with its provenance and age, and marks it STALE loudly
    once it is older than the console's max-age (default 2h).

${BOLD}OPTIONS:${NC}
    --to <ssh-host>   console host (default: settings.console.host in nwp.yml)
    --dest <path>     absolute path on the host
                      (default: \$HOME/$DEFAULT_REMOTE_REL)
    --out <path>      snapshot: write here instead of $LOCAL_STATE
    --no-todo         skip the (slower) todo sweep; publish the RAG feed only
    --no-security     skip the security-advisory feed
    --refresh-security  re-run \`pl audit --all --security-only\` first. SLOW
                      (one ddev container per site) — never use this on the cron
    --dry-run         build the snapshot, print the summary, ship nothing
    --quiet           only report failures (for cron)
    --allow-empty     permit a snapshot that names ZERO sites. Off by default:
                      publishing from a git worktree (no sites/, no
                      private/update-awareness/) once replaced a good snapshot
                      with an all-zeros one and the console showed an empty
                      fleet. Zero sites is UNKNOWN, not a clean fleet.
    --force           publish even if the fleet population collapsed by more
                      than half against the snapshot being replaced

${BOLD}SNAPSHOT:${NC}
    schema $FLEET_SCHEMA v$FLEET_SCHEMA_VERSION — generated_at (UTC), generated_by
    (host/user/root/version), and one entry per feed under .feeds:
      feeds.rag.data      = \`pl rag --json --no-todo\` verbatim
      feeds.todo.data     = \`pl todo check --json\` verbatim (backup freshness too)
      feeds.security.data = \`pl fleet security --json\` — per site: state, count,
                            and every advisory (id, CVE, package, installed +
                            affected versions, title, severity, reported, link)
    Written 0600, shipped atomically (tmp + mv), never contains a secret.

${BOLD}SECURITY FEED:${NC}
    Built from \`pl audit\`'s cached records in private/update-awareness/, the
    same source \`pl rag\` grades RED on — so the console's advisory detail and
    its RAG badge can never disagree. Costs ~0.1 s, not 16 container starts.
    Refresh the cache with \`pl audit --all\` (the daily timer already does).

${BOLD}EXAMPLES:${NC}
    pl fleet publish                     # gather + ship to the console host
    pl fleet publish --to <host> --dry-run  # see what would be published
    pl fleet security                    # what the console will show, as a table
    pl fleet security --json | python3 -m json.tool   # every advisory in full
    pl fleet schedule                    # publish every 30 min from this host

${BOLD}FLEET SYNC (ops#360 — engine-code propagation):${NC}
    pl fleet sync status                 # is any nwp host running stale main?
    pl fleet sync run --host=ai-host     # one supervised sync now (or bootstrap)
    pl fleet sync install --host=ai-host # provision the */15 cron on that host
    Targets are ROLES resolved via the private instance manifest, never
    hostnames. Prod-reaching roles (verifier, signed-deploy, prod-cluster,
    prod-agent, prod-au) and 'authoring' are REFUSED — prod receives code as
    signed artifacts through its own path (NWP-ADR-0017/0028), and sessions
    control the dev tree. The worker (scripts/fleet-sync-host.sh) is
    fast-forward-only, verifies signatures (enforcing under
    NWP_REQUIRE_SIGNED_COMMITS=1), health-checks what changed, reverts on
    failure, and ledgers every outcome.
EOF
}

# --- security feed -------------------------------------------------------------
# `pl fleet security --json` — the structured advisory list for one fleet.
#
# It is its own verb (not just an inline block) for three reasons: the console's
# LOCAL fallback path needs a `pl` argv to shell out to on a host that DOES have
# sites; an operator can run it by hand to see exactly what will be published;
# and _capture_feed then treats it like every other feed, inheriting the same
# best-effort/ok:false honesty.
cmd_security() {
    local as_json=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --json)    as_json=true; shift ;;
            -h|--help) show_help; return 0 ;;
            *) print_error "unknown option: $1"; return 1 ;;
        esac
    done
    # NWP_REPO locates the shared advisories module (it ships with this repo);
    # NWP_ROOT locates the DATA (sites/*/composer.lock). They are the same
    # directory in production and deliberately separable under test.
    local out
    out=$(NWP_AUDIT_DIR="$AUDIT_STATE_DIR" NWP_ROOT="$PROJECT_ROOT" NWP_REPO="$REPO_ROOT" \
          NWP_SITES="$(_known_sites)" python3 - 2>&1 <<'PY'
import json, os, sys
sys.path.insert(0, os.path.join(os.environ["NWP_REPO"], "scripts", "console"))
from datetime import datetime, timezone
try:
    from app import advisories
except ImportError as e:                       # scripts/console missing/broken
    sys.stderr.write("advisories module unavailable: %s\n" % e)
    sys.exit(1)
feed = advisories.build_feed(
    os.environ["NWP_AUDIT_DIR"],
    sites=[s for s in os.environ.get("NWP_SITES", "").split() if s],
    root=os.environ["NWP_ROOT"],
    now=datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
)
json.dump(feed, sys.stdout, sort_keys=True, separators=(",", ":"))
PY
    ) || { print_error "could not build the security feed: ${out:-no output}"; return 1; }

    if [ "$as_json" = true ]; then
        printf '%s\n' "$out"
        return 0
    fi
    printf '%s' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
t = d.get("totals", {})
print("Security advisories — %d site(s), %d advisor%s on %d site(s)" % (
    t.get("sites", 0), t.get("advisories", 0),
    "y" if t.get("advisories") == 1 else "ies", t.get("sites_affected", 0)))
sev = t.get("by_severity", {})
if sev:
    print("  by severity: " + ", ".join("%s=%d" % kv for kv in sorted(sev.items())))
print()
print("  %-14s %-10s %5s %8s  %s" % ("SITE", "STATE", "ADV", "IGNORED", "CHECKED"))
for b in d.get("sites", []):
    print("  %-14s %-10s %5s %8s  %s %s" % (
        b.get("site", "?"), b.get("state", "?"), b.get("count", 0),
        b.get("ignored", 0), b.get("checked", "-"), b.get("note", "")[:50]))
print()
print("  Detail: pl fleet security --json | python3 -m json.tool")
'
}

# Site names `pl audit` would sweep — so a site that STOPPED being audited shows
# up as "missing" instead of quietly vanishing from the list.
#
# This MUST stay the same query as lib/yaml-write.sh:yaml_get_all_sites(), which
# is what `pl audit` itself uses to build its site list; if the two ever
# disagree, this pane invents "missing" sites that were never in scope, or hides
# ones that were. It is duplicated rather than sourced on purpose: fleet.sh
# deliberately pulls in only ui.sh + impact.sh (it runs from cron every 30
# minutes), and yaml-write.sh is a large dependency for one `yq` expression.
# yq-only, no awk fallback — an unparsable config must yield "no sites" (every
# site reads "missing") rather than a half-parsed list that looks complete.
_known_sites() {
    local f="${NWP_CONFIG_FILE:-$PROJECT_ROOT/nwp.yml}"
    [ -f "$f" ] || return 0
    command -v yq >/dev/null 2>&1 || return 0
    yq e '.sites | keys | .[]' "$f" 2>/dev/null | grep -vE '^(null|---)$' | tr '\n' ' ' || true
}

# --- gathering ---------------------------------------------------------------
# Each feed is captured independently and best-effort: a feed that fails is
# recorded as ok:false with its rc/stderr, and the others still publish. The
# consumer degrades that feed only (same contract as the console's panes).
#
# PER-FEED DEADLINE (this is the bit that keeps the */30 cron alive).
#
# `pl fleet publish` runs from cron every 30 minutes to feed the console. Before
# this, no feed had a wall clock: a slow link made `pl todo check --json` block
# for minutes, the cron's own `timeout` fired first, and the whole publish exited
# 124 having shipped NOTHING. The console then sat on hours-old data — correctly
# marked stale by _provenance.html, but stale is not the same as informed.
#
# The fix matches the honesty this function already had for a feed that FAILS: a
# feed that runs out of time is recorded ok:false with its reason, and the other
# feeds still publish. A partial snapshot that names its own gaps beats no
# snapshot, every time. Per-feed override: FLEET_FEED_BUDGET_<name>.
: "${FLEET_FEED_BUDGET:=90}"

# ops#329 D7 — THE TODO FEED NEEDS ITS OWN, LONGER DEADLINE.
#
# `pl fleet publish` on 2026-08-10:
#   feed todo : BLIND (90.0s, rc=124) — feed exceeded its 90s deadline
# every run, so the console's todo panel was permanently unknown and the */30
# cron spent 90s producing nothing.
#
# It was not slowness; it was arithmetic. `pl todo check` carries its OWN wall
# clock (TODO_SWEEP_BUDGET, default 150s in lib/todo-checks.sh) and is built to
# stop at it and file an explicit `UNK-budget-<check>` item for every check it
# did not reach — a partial answer that names its own gaps, which is exactly
# what a 30-minute snapshot wants. A 90s outer deadline over a 150s inner
# budget means that machinery can never run: the kill always lands first and
# discards everything gathered so far.
#
# Measured cost of the sweep on the publishing workstation, 2026-08-10:
#   cold cache 98.4s   ·   warm cache 72.6s
# so 90s was below the cold figure as well.
#
# 180s is the deadline; the sweep is told to stop at 160s (below). The usual
# run therefore COMPLETES, and a pathological one self-truncates and publishes
# what it has with the gaps named. rc=124 becomes the last resort it was always
# meant to be instead of the normal path.
: "${FLEET_FEED_BUDGET_TODO:=180}"

# How much of the todo feed's deadline is reserved for everything that is not
# the sweep itself: pl start-up, sourcing, and emitting the JSON after the
# sweep has stopped.
: "${FLEET_SWEEP_HEADROOM:=20}"

# Budgets for the ship leg. The whole job must fit inside the */30 cron window
# with room to spare: 90 (rag) + 180 (todo) + 90 (security) + 90 (estate)
# + 20 + 20 + 60 = 550s worst case, against a 1800s window.
: "${SSH_STEP_BUDGET:=20}"   # $HOME resolution, size verification
: "${SSH_SHIP_BUDGET:=60}"   # the snapshot transfer itself

_feed_budget() { # $1 = feed name
    local var="FLEET_FEED_BUDGET_${1^^}"
    printf '%s' "${!var:-$FLEET_FEED_BUDGET}"
}

# _todo_sweep_budget → the wall clock handed to `pl todo check` as
# TODO_SWEEP_BUDGET, DERIVED from the feed's deadline rather than written down
# a second time. Two independent numbers are how the 90-vs-150 mismatch
# happened in the first place; a derived one cannot drift, and moving the
# deadline moves this with it.
#
# The invariant — inner < outer, always — is enforced here by construction, so
# it holds for any operator override of FLEET_FEED_BUDGET_TODO, including
# absurd ones.
_todo_sweep_budget() {
    local outer inner
    outer=$(_feed_budget todo)
    [[ "$outer" =~ ^[0-9]+$ ]] || outer=180
    inner=$(( outer - FLEET_SWEEP_HEADROOM ))
    (( inner < 1 )) && inner=1
    (( inner >= outer )) && inner=1
    printf '%s' "$inner"
}

_capture_feed() { # $1 outdir, $2 name, $3... argv
    local outdir="$1" name="$2"; shift 2
    local started ended rc=0 budget
    budget=$(_feed_budget "$name")
    started=$(date +%s.%N)
    set +e
    timeout --kill-after=10 "$budget" "$PROJECT_ROOT/pl" "$@" \
        >"$outdir/$name.out" 2>"$outdir/$name.err"
    rc=$?
    set -e
    # Leave the reason where _assemble can find it even though the feed wrote no
    # usable stderr of its own — a bare rc=124 in the snapshot is a puzzle, and
    # the operator reading the console should not have to solve it.
    if [ "$rc" = 124 ] || [ "$rc" = 137 ]; then
        printf 'feed exceeded its %ss deadline (rc=%s) — published as blind, not as clean\n' \
            "$budget" "$rc" >> "$outdir/$name.err"
    fi
    ended=$(date +%s.%N)
    printf '%s' "$rc" > "$outdir/$name.rc"
    awk -v a="$started" -v b="$ended" 'BEGIN{printf "%.1f", b-a}' > "$outdir/$name.secs"
    printf '%s' "pl $*" > "$outdir/$name.cmd"
    return 0
}

# Assemble the snapshot JSON from the captured feeds. Pure python3 + stdlib:
# no jq dependency, and every feed's stdout is parsed defensively (a feed whose
# JSON does not parse is published as ok:false with the raw tail attached).
_assemble() { # $1 outdir, $2 feed names (space separated) -> JSON on stdout
    NWP_FEED_DIR="$1" NWP_FEEDS="$2" \
    NWP_SCHEMA="$FLEET_SCHEMA" NWP_SCHEMA_VERSION="$FLEET_SCHEMA_VERSION" \
    NWP_MAX_AGE_HINT="$FLEET_MAX_AGE_HINT" NWP_ROOT="$PROJECT_ROOT" \
    NWP_ALLOW_EMPTY="${FLEET_ALLOW_EMPTY:-0}" \
    python3 - <<'PY'
import json, os, socket, subprocess, sys
from datetime import datetime, timezone

d = os.environ["NWP_FEED_DIR"]
names = [n for n in os.environ["NWP_FEEDS"].split() if n]
root = os.environ["NWP_ROOT"]


def read(path, limit=200_000):
    try:
        with open(path, "r", errors="replace") as f:
            return f.read()[:limit]
    except OSError:
        return ""


ALLOW_EMPTY = os.environ.get("NWP_ALLOW_EMPTY", "0") == "1"


def _population(name, data):
    """How many SITES did this feed actually see? None = not population-bearing.

    This is the number that separates "the fleet is clean" from "I could not see
    the fleet". Both render as zeros; only this tells them apart.
    """
    if not isinstance(data, dict):
        return None
    if name == "rag":
        sites = data.get("sites")
        return len(sites) if isinstance(sites, list) else 0
    if name == "security":
        totals = data.get("totals")
        if not isinstance(totals, dict):
            return 0
        try:
            return int(totals.get("sites", 0) or 0)
        except (TypeError, ValueError):
            return 0
    return None   # `todo`: 0 items is a legitimate clean result, not a blind spot


def pl_version():
    try:
        out = subprocess.run([os.path.join(root, "pl"), "--version"],
                             capture_output=True, text=True, timeout=20).stdout
        return out.strip().split()[-1] if out.strip() else ""
    except Exception:  # noqa: BLE001
        return ""


feeds = {}
for name in names:
    out = read(f"{d}/{name}.out")
    err = read(f"{d}/{name}.err", 4000)
    try:
        rc = int(read(f"{d}/{name}.rc") or 1)
    except ValueError:
        rc = 1
    try:
        secs = float(read(f"{d}/{name}.secs") or 0)
    except ValueError:
        secs = 0.0
    cmd = read(f"{d}/{name}.cmd", 400).strip()
    data, perr = None, ""
    try:
        data = json.loads(out)
    except (json.JSONDecodeError, ValueError):
        # Tolerate leading warnings before the JSON body.
        start = min([i for i in (out.find("{"), out.find("[")) if i != -1] or [-1])
        if start != -1:
            try:
                data = json.loads(out[start:])
            except (json.JSONDecodeError, ValueError):
                perr = "feed stdout is not JSON"
        else:
            perr = "feed produced no JSON"
    # A feed is usable when its JSON parsed — NOT when rc is 0. `pl rag`
    # deliberately exits 3 when any site is RED (that is the signal, not a
    # failure), and the console's parsers have always read stdout only. The rc
    # is recorded so a consumer can still see it.
    ok = data is not None
    feed = {"ok": ok, "rc": rc, "secs": round(secs, 1), "cmd": cmd}
    if data is not None:
        feed["data"] = data
    if not ok:
        tail = err.strip().splitlines()[-1] if err.strip() else ""
        # A feed that ran out of time and a feed that emitted garbage are
        # different problems with different fixes, and "feed produced no JSON"
        # described both. timeout(1) reports 124, or 137 when the --kill-after
        # SIGKILL was needed; say so plainly and set `blind` so a consumer can
        # distinguish "this feed is broken" from "this feed was not reached in
        # time" without parsing English.
        timed_out = rc in (124, 137)
        feed["blind"] = timed_out
        feed["error"] = (tail if timed_out and tail else
                         (f"feed exceeded its deadline (rc={rc})" if timed_out else
                          (perr or tail or f"rc={rc}")))
        feed["raw"] = out[-2000:]

    # ── A FEED THAT READ NOTHING IS NOT A CLEAN FEED ─────────────────────────
    #
    # Publishing from a git worktree shipped a snapshot to the live console in
    # which security.totals was {advisories: 0, sites: 0} and rag.data.sites was
    # [], with EVERY feed marked ok. It replaced a good snapshot (88 advisories
    # across 12 sites, 24 rag sites) with an empty one, and the console showed an
    # empty fleet until it was republished. Nothing was broken and nothing timed
    # out: worktrees have no sites/ and no private/update-awareness/, so both
    # feeds truthfully reported what they could see, which was nothing.
    #
    # This is the same defect as the timeout case one level up — the feed could
    # not GATHER rather than could not FINISH — so it gets the same vocabulary
    # (blind: true), not a parallel one. `pl audit` already refuses to let a site
    # with no record read as "0 advisories" (state: missing); this extends that
    # from the site to the feed, because a feed with no sites at all had no
    # per-site record to mark missing.
    #
    # `todo` is deliberately NOT population-bearing: zero todo items is a real,
    # common and correct clean result.
    if feed.get("ok"):
        pop = _population(name, data)
        if pop is not None:
            feed["population"] = pop
            if pop == 0 and not ALLOW_EMPTY:
                feed["ok"] = False
                feed["blind"] = True
                feed["error"] = (
                    "gathered 0 sites — this feed read no site data at all, which is "
                    "UNKNOWN, not a clean fleet. Usual cause: publishing from a tree "
                    "with no sites/ or no private/update-awareness/ (e.g. a git "
                    "worktree). If this host genuinely has no sites, set "
                    "FLEET_ALLOW_EMPTY=1 or pass --allow-empty.")
    feeds[name] = feed

# One flat headline so a consumer (or a human with jq) can answer "how bad is
# it?" without walking the feeds.
summary = {}
rag = (feeds.get("rag") or {}).get("data") or {}
if isinstance(rag, dict):
    s = rag.get("summary") or {}
    if isinstance(s, dict):
        for k in ("RED", "AMBER", "GREEN"):
            try:
                summary[k] = int(s.get(k, 0) or 0)
            except (TypeError, ValueError):
                summary[k] = 0
    sites = rag.get("sites")
    summary["sites"] = len(sites) if isinstance(sites, list) else 0

# Security headline, so `pl fleet status`/a jq one-liner can answer "how exposed
# are we?" without walking feeds.security.data.sites.
sec = (feeds.get("security") or {}).get("data") or {}
sec_totals = sec.get("totals") if isinstance(sec, dict) else None
if isinstance(sec_totals, dict):
    for k in ("advisories", "sites_affected", "sites_unknown"):
        try:
            summary["security_" + k] = int(sec_totals.get(k, 0) or 0)
        except (TypeError, ValueError):
            summary["security_" + k] = 0
    summary["security_worst"] = str(sec_totals.get("worst", "") or "")
    # Per-site count, the number the Fleet pane makes clickable.
    per_site = {}
    for b in sec.get("sites") or []:
        if isinstance(b, dict) and b.get("site"):
            try:
                per_site[str(b["site"])] = int(b.get("count", 0) or 0)
            except (TypeError, ValueError):
                per_site[str(b["site"])] = 0
    summary["security_by_site"] = per_site

todo = (feeds.get("todo") or {}).get("data") or {}
items = todo.get("items") if isinstance(todo, dict) else None
if isinstance(items, list):
    summary["todo_items"] = len(items)
    # Backup freshness = the slice the console's Backups pane shows.
    summary["backup_items"] = sum(
        1 for it in items
        if isinstance(it, dict)
        and ("backup" in f"{it.get('id','')} {it.get('title','')} {it.get('category','')}".lower()
             or "sweep" in f"{it.get('id','')} {it.get('title','')}".lower())
    )
    # ops#329 D7. The sweep is now allowed to run out of ITS budget and report
    # a partial answer (that is the point — see _todo_sweep_budget). A partial
    # answer that reaches the envelope looking whole is the same defect the
    # BLIND marker exists to prevent, one level in. `pl todo check` names every
    # check it did not reach as an UNK-budget-*/UNK-timeout-* item, so count
    # them here: a consumer reading only the summary can then tell a small
    # number of findings from a small number of QUESTIONS ASKED.
    summary["todo_unknown_checks"] = sum(
        1 for it in items
        if isinstance(it, dict) and str(it.get("id", "")).startswith("UNK-")
    )

# A consumer must be able to answer "can I trust this snapshot's zeros?" from
# the envelope, without walking every feed. `population` is the total fleet the
# snapshot actually saw; `degraded` says at least one feed is blind.
pop_feeds = {n: f.get("population") for n, f in feeds.items() if "population" in f}
summary["population"] = max([p for p in pop_feeds.values() if isinstance(p, int)] or [0])
summary["degraded"] = (any(f.get("blind") or not f.get("ok") for f in feeds.values())
                       # ops#329 D7: a sweep that answered only part of the
                       # question degrades the snapshot too. It is not blind —
                       # the feed carries real findings — but a consumer must
                       # not read its zeros as clean.
                       or bool(summary.get("todo_unknown_checks")))

snapshot = {
    "schema": os.environ["NWP_SCHEMA"],
    "schema_version": int(os.environ["NWP_SCHEMA_VERSION"]),
    "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "generated_by": {
        "host": socket.gethostname(),
        "user": os.environ.get("USER", ""),
        "root": root,
        "pl_version": pl_version(),
    },
    "max_age_hint_seconds": int(os.environ["NWP_MAX_AGE_HINT"]),
    "summary": summary,
    "feeds": feeds,
}
json.dump(snapshot, sys.stdout, sort_keys=True, separators=(",", ":"))
sys.stdout.write("\n")
PY
}

# Build the snapshot into $1 (0600). Non-zero if EVERY feed failed — a snapshot
# with nothing usable in it is worse than none, because it would look fresh.
build_snapshot() { # $1 dest, $2 include_todo, $3 quiet, $4 include_security, $5 refresh_security
    local dest="$1" include_todo="${2:-true}" quiet="${3:-false}"
    local include_security="${4:-true}" refresh_security="${5:-false}"
    local tmpdir; tmpdir=$(mktemp -d); chmod 700 "$tmpdir"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmpdir'" RETURN

    local feeds="rag"
    [ "$quiet" = true ] || print_info "Gathering rag (pl rag --json --no-todo)…"
    _capture_feed "$tmpdir" rag rag --json --no-todo
    if [ "$include_todo" = true ]; then
        [ "$quiet" = true ] || print_info "Gathering todo + backup freshness (pl todo check --json)…"
        # ops#329 D7: hand the sweep a budget strictly inside this feed's
        # deadline, so it self-truncates and reports its gaps as UNK-budget-*
        # items instead of being killed with everything it had gathered.
        # Exported in a subshell so the value cannot leak into the other feeds.
        ( export TODO_SWEEP_BUDGET; TODO_SWEEP_BUDGET="$(_todo_sweep_budget)"
          _capture_feed "$tmpdir" todo todo check --json )
        feeds="rag todo"
    fi
    if [ "$include_security" = true ]; then
        # --refresh-security re-runs the (slow, container-bound) audit FIRST.
        # Off by default: the cache is refreshed by the daily audit timer, and a
        # */30 publish must never depend on 16 ddev containers being up.
        if [ "$refresh_security" = true ]; then
            [ "$quiet" = true ] || print_info "Refreshing the audit cache (pl audit --all --security-only)… this is slow"
            "$PROJECT_ROOT/pl" audit --all --security-only >/dev/null 2>&1 || true
        fi
        [ "$quiet" = true ] || print_info "Gathering security advisories (pl fleet security --json)…"
        _capture_feed "$tmpdir" security fleet security --json
        feeds="$feeds security"
    fi
    # The estate feed (ops#329): repo drift + deploy records + harvest spool +
    # secrets debt + backup ages, for the console's overview subtab. Additive —
    # an older console ignores it (fleet.sh:36-50). Its git fetches are
    # time-boxed per repo, and the whole feed carries the same 90s deadline as
    # the others, so the */30 cron budget grows to 4 feeds x 90s + ship ≈ 460s
    # worst case — still comfortably inside the window.
    [ "$quiet" = true ] || print_info "Gathering estate drift (pl fleet estate --json)…"
    _capture_feed "$tmpdir" estate fleet estate --json
    feeds="$feeds estate"

    local json
    json=$(_assemble "$tmpdir" "$feeds") || { print_error "failed to assemble the snapshot"; return 1; }

    # Refuse to publish a snapshot in which no feed is ok.
    if ! printf '%s' "$json" | python3 -c \
        'import json,sys; d=json.load(sys.stdin); sys.exit(0 if any(f.get("ok") for f in d.get("feeds",{}).values()) else 1)'; then
        print_error "every feed failed — refusing to publish a snapshot with no usable data"
        printf '%s' "$json" | python3 -c \
            'import json,sys; d=json.load(sys.stdin); [print("  %s: %s" % (k, v.get("error",""))) for k,v in d.get("feeds",{}).items()]' || true
        return 1
    fi

    # …and refuse one that saw no FLEET, even if some feed technically parsed.
    #
    # The check above passes on a worktree publish: `todo` returns a valid empty
    # item list, so "some feed is ok" is satisfied while both feeds that carry
    # the actual fleet saw zero sites. The console then renders an empty fleet
    # as though it were a clean one. A snapshot that cannot name a single site
    # is not a fleet snapshot; refusing is strictly better than overwriting a
    # good one with it.
    if [ "${FLEET_ALLOW_EMPTY:-0}" != "1" ]; then
        if ! printf '%s' "$json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
feeds = d.get("feeds", {})
bearing = {n: f for n, f in feeds.items() if "population" in f or n in ("rag", "security")}
sys.exit(0 if any(f.get("ok") and f.get("population", 0) > 0 for f in bearing.values()) else 1)'; then
            print_error "this tree has no fleet to publish — refusing to overwrite a good snapshot with an empty one"
            print_info "  Every population-bearing feed (rag, security) saw 0 sites."
            print_info "  Usual cause: running from a git worktree, which has no sites/ and"
            print_info "  no private/update-awareness/. Publish from the real tree instead."
            print_hint "  If this host genuinely has no sites: pl fleet publish --allow-empty"
            return 1
        fi
    fi

    mkdir -p "$(dirname "$dest")"
    ( umask 077; printf '%s' "$json" > "$dest.tmp.$$" )
    chmod 600 "$dest.tmp.$$"
    mv -f "$dest.tmp.$$" "$dest"
    return 0
}

_summarise() { # $1 snapshot file
    python3 - "$1" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:  # noqa: BLE001
    print(f"  unreadable snapshot: {e}"); sys.exit(0)
s = d.get("summary", {})
gb = d.get("generated_by", {})
print(f"  generated_at : {d.get('generated_at','?')}  (by {gb.get('host','?')} as {gb.get('user','?')})")
print(f"  schema       : {d.get('schema','?')} v{d.get('schema_version','?')}")
print("  fleet        : {} sites — {} RED / {} AMBER / {} GREEN".format(
    s.get("sites", 0), s.get("RED", 0), s.get("AMBER", 0), s.get("GREEN", 0)))
_unk = s.get("todo_unknown_checks", 0)
print("  todo         : {} items ({} backup-freshness){}".format(
    s.get("todo_items", "-"), s.get("backup_items", "-"),
    # ops#329 D7 — never let a partial sweep's item count read as a full one.
    "" if not _unk else
    f"  [{_unk} check(s) did NOT run — their result is UNKNOWN, not clean]"))
if "security_advisories" in s:
    print("  security     : {} advisories on {} site(s), worst={} ({} unknown)".format(
        s.get("security_advisories", 0), s.get("security_sites_affected", 0),
        s.get("security_worst", "-") or "-", s.get("security_sites_unknown", 0)))
else:
    print("  security     : not in this snapshot")
for name, f in sorted(d.get("feeds", {}).items()):
    # BLIND (ran out of time) reads differently from FAILED (broke). The
    # operator's next move is different for each: wait/raise the budget vs fix.
    mark = "ok" if f.get("ok") else ("BLIND" if f.get("blind") else "FAILED")
    print(f"  feed {name:<9}: {mark} ({f.get('secs','?')}s, rc={f.get('rc','?')})"
          + ("" if f.get("ok") else f" — {f.get('error','')}"))
PY
}

# --- shipping ----------------------------------------------------------------
_dest_ok() { # refuse anything that is not a boring absolute path
    [[ "$1" =~ ^/[A-Za-z0-9._/-]+$ ]]
}

cmd_publish() {
    local host="$CONSOLE_HOST" dest="" include_todo=true dry_run=false quiet=false
    local include_security=true refresh_security=false force=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --to)       host="${2:-}"; shift 2 ;;
            --to=*)     host="${1#--to=}"; shift ;;
            --dest)     dest="${2:-}"; shift 2 ;;
            --dest=*)   dest="${1#--dest=}"; shift ;;
            --no-todo)  include_todo=false; shift ;;
            --no-security) include_security=false; shift ;;
            --refresh-security) refresh_security=true; shift ;;
            --dry-run)  dry_run=true; shift ;;
            --quiet|-q) quiet=true; shift ;;
            --allow-empty) export FLEET_ALLOW_EMPTY=1; shift ;;
            --force)    force=true; shift ;;
            -h|--help)  show_help; return 0 ;;
            *) print_error "unknown option: $1"; return 1 ;;
        esac
    done

    build_snapshot "$LOCAL_STATE" "$include_todo" "$quiet" "$include_security" "$refresh_security" || return 1
    [ "$quiet" = true ] || { print_success "snapshot built: $LOCAL_STATE"; _summarise "$LOCAL_STATE"; }

    if [ "$dry_run" = true ]; then
        print_info "--dry-run: nothing shipped (would go to ${host:-<no host>}:${dest:-\$HOME/$DEFAULT_REMOTE_REL})"
        return 0
    fi

    if [ -z "$host" ]; then
        print_error "no console host: pass --to <ssh-host> or set settings.console.host in nwp.yml"
        return 1
    fi

    # Resolve $HOME on the host once so the destination is always absolute
    # (a remote "~/..." inside quotes does NOT expand, and silently writing to
    # a literal ./~ directory is exactly the kind of quiet failure to avoid).
    if [ -z "$dest" ]; then
        local rhome
        # ConnectTimeout bounds the TCP+auth handshake ONLY. A session that
        # stalls after connect — the exact failure a congested link produces —
        # is unbounded, so the ship leg could hang past the */30 window even
        # once the feeds were bounded. timeout(1) bounds the whole ssh.
        rhome=$(timeout "$SSH_STEP_BUDGET" \
                ssh -o ConnectTimeout=15 -o BatchMode=yes "$host" 'printf %s "$HOME"' 2>/dev/null) \
            || { print_error "cannot ssh to $host (within ${SSH_STEP_BUDGET}s)"; return 1; }
        [ -n "$rhome" ] || { print_error "could not resolve \$HOME on $host"; return 1; }
        dest="$rhome/$DEFAULT_REMOTE_REL"
    fi
    _dest_ok "$dest" || { print_error "refusing suspicious --dest: $dest"; return 1; }

    # ── COLLAPSE GUARD ───────────────────────────────────────────────────────
    #
    # The zero-population refusal above catches the total-blindness case. This
    # catches the subtler one: a snapshot that sees SOME sites but drastically
    # fewer than the one it is about to replace (half the fleet's configs
    # unreadable, a partial checkout, a half-finished migration). The console
    # cannot tell a shrinking fleet from a shrinking view of it, so the decision
    # belongs here, where the previous number is still available.
    #
    # Fail-OPEN if the remote cannot be read: not being able to compare is not
    # evidence of collapse, and a first publish has nothing to compare against.
    # Refusing there would make the guard the outage.
    if [ "$force" != true ]; then
        local new_pop old_pop
        new_pop=$(python3 -c '
import json,sys
try: print(json.load(open(sys.argv[1])).get("summary",{}).get("population",0) or 0)
except Exception: print(0)' "$LOCAL_STATE" 2>/dev/null || echo 0)
        old_pop=$(timeout "$SSH_STEP_BUDGET" ssh -o ConnectTimeout=15 -o BatchMode=yes "$host" \
                  "cat '$dest' 2>/dev/null" 2>/dev/null | python3 -c '
import json,sys
try: print(json.load(sys.stdin).get("summary",{}).get("population",0) or 0)
except Exception: print(-1)' 2>/dev/null || echo -1)
        if [ "${old_pop:--1}" -gt 0 ] 2>/dev/null && [ "${new_pop:-0}" -lt $(( old_pop / 2 )) ] 2>/dev/null; then
            print_error "refusing to publish: fleet population collapsed ${old_pop} → ${new_pop} sites"
            print_info "  The snapshot on ${host} names ${old_pop} site(s); this one names ${new_pop}."
            print_info "  That is more likely a broken view of the fleet than a shrunken fleet."
            print_hint "  If the fleet really did shrink: pl fleet publish --force"
            return 1
        fi
    fi

    [ "$quiet" = true ] || print_info "Shipping to ${host}:${dest} (0600, atomic)"
    # umask first so the tmp file is never briefly world-readable.
    if ! timeout "$SSH_SHIP_BUDGET" \
            ssh -o ConnectTimeout=20 -o BatchMode=yes "$host" \
            "umask 077; mkdir -p \"\$(dirname '$dest')\" && cat > '$dest.tmp.\$\$' && chmod 600 '$dest.tmp.\$\$' && mv -f '$dest.tmp.\$\$' '$dest'" \
            < "$LOCAL_STATE"; then
        print_error "failed to ship the snapshot to ${host}:${dest} (within ${SSH_SHIP_BUDGET}s)"
        return 1
    fi

    # Verify what landed: same byte count, and it still parses over there is
    # the consumer's problem — size + mtime is the cheap honest check.
    local local_size remote_size
    local_size=$(wc -c < "$LOCAL_STATE" | tr -d ' ')
    remote_size=$(timeout "$SSH_STEP_BUDGET" \
                  ssh -o ConnectTimeout=15 -o BatchMode=yes "$host" "wc -c < '$dest'" 2>/dev/null | tr -d ' ' || true)
    if [ "$local_size" != "$remote_size" ]; then
        print_error "verification failed: shipped $local_size bytes, host reports '${remote_size:-none}'"
        return 1
    fi
    [ "$quiet" = true ] || print_success "published ${local_size} bytes to ${host}:${dest}"
    return 0
}

cmd_snapshot() {
    local out="$LOCAL_STATE" include_todo=true include_security=true refresh_security=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --out)     out="${2:-}"; shift 2 ;;
            --out=*)   out="${1#--out=}"; shift ;;
            --no-todo) include_todo=false; shift ;;
            --no-security) include_security=false; shift ;;
            --refresh-security) refresh_security=true; shift ;;
            --allow-empty) export FLEET_ALLOW_EMPTY=1; shift ;;
            -h|--help) show_help; return 0 ;;
            *) print_error "unknown option: $1"; return 1 ;;
        esac
    done
    build_snapshot "$out" "$include_todo" false "$include_security" "$refresh_security" || return 1
    print_success "snapshot written: $out"
    _summarise "$out"
}

cmd_status() {
    local host="$CONSOLE_HOST"
    while [ $# -gt 0 ]; do
        case "$1" in
            --to)   host="${2:-}"; shift 2 ;;
            --to=*) host="${1#--to=}"; shift ;;
            *) shift ;;
        esac
    done
    print_info "Local snapshot: $LOCAL_STATE"
    if [ -f "$LOCAL_STATE" ]; then
        _summarise "$LOCAL_STATE"
        local age; age=$(( $(date +%s) - $(stat -c %Y "$LOCAL_STATE") ))
        echo "  age          : $((age / 60)) min"
    else
        print_warning "  none yet — run: pl fleet publish"
    fi
    if [ -n "$host" ]; then
        print_info "On ${host}:"
        ssh -o ConnectTimeout=15 -o BatchMode=yes "$host" \
            'f="$HOME/.local/share/nwp-console/fleet-state.json";
             if [ -f "$f" ]; then
                 printf "  %s\n  mtime: %s  size: %s bytes  mode: %s\n" \
                     "$f" "$(date -r "$f" -u +%FT%TZ)" "$(wc -c < "$f" | tr -d " ")" "$(stat -c %a "$f")"
             else
                 echo "  no published snapshot on this host"
             fi' 2>/dev/null || print_warning "  (unreachable)"
    fi
}

# --- schedule ----------------------------------------------------------------
CRON_MARKER="# NWP Fleet Publish (pl fleet publish -> console host)"
CRON_DEFAULT="*/30 * * * *"

# cron runs with a bare PATH (typically /usr/bin:/bin). NWP's tooling does not
# all live there — `yq` is commonly in ~/.local/bin (installed by `pl setup`),
# and without it `_console_cfg` silently returns the default, so the publish
# resolves NO console host and fails every half hour into a log nobody reads.
# Bake the directories of the binaries this job actually needs into the entry,
# resolved HERE where the interactive PATH is correct. (Same class of bug as
# the 15-day-silent backup sweep: a cron that fails quietly is worse than none.)
_cron_path() {
    local out="" d b
    for b in yq ssh python3 git; do
        d=$(command -v "$b" 2>/dev/null) || continue
        d=$(dirname "$d")
        case ":$out:" in *":$d:"*) continue ;; esac
        out="${out:+$out:}$d"
    done
    printf '%s' "${out:+$out:}/usr/local/bin:/usr/bin:/bin"
}

# `crontab -` REPLACES the whole crontab, and the filter below drops EVERY line
# mentioning `pl fleet publish` — including one a human wrote by hand. That is a
# small overwrite of something the operator owns, so it gets the ops#47
# treatment: compute what is displaced, say it out loud, and only prompt when
# something is actually being taken away (a first install displaces nothing).
cmd_schedule() {
    local remove=false schedule="$CRON_DEFAULT" auto_yes=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --remove)     remove=true; shift ;;
            --schedule)   schedule="${2:-}"; shift 2 ;;
            --schedule=*) schedule="${1#--schedule=}"; shift ;;
            --yes|-y)     auto_yes=true; shift ;;
            -h|--help)    show_help; return 0 ;;
            *) print_error "unknown option: $1"; return 1 ;;
        esac
    done
    command -v crontab >/dev/null 2>&1 || { print_error "no crontab on this machine"; return 1; }

    local current cleaned dropped n_drop n_keep
    current="$(crontab -l 2>/dev/null || true)"
    dropped="$(printf '%s\n' "$current" | grep -F -e "$CRON_MARKER" -e 'pl fleet publish' || true)"
    cleaned="$(printf '%s\n' "$current" | grep -v -F "$CRON_MARKER" | grep -v 'pl fleet publish' || true)"
    n_drop=$(printf '%s' "$dropped" | grep -c . || true)
    n_keep=$(printf '%s' "$cleaned" | grep -c . || true)

    impact_reset
    if [ "$n_drop" -gt 0 ]; then
        impact_delete "Crontab lines" \
            "$n_drop line(s) mentioning '$CRON_MARKER' or 'pl fleet publish' are removed by this rewrite"
        impact_warn "removed verbatim — check nothing here is yours: $(printf '%s' "$dropped" | tr '\n' '\036' | sed 's/\o036/  ⏎  /g')"
    fi
    impact_keep "${n_keep} other crontab line(s) on this machine — preserved verbatim"
    impact_keep "No site, database, backup or console file is touched — this verb only schedules 'pl fleet publish'"

    if [ "$remove" = true ]; then
        [ "$n_drop" -gt 0 ] || impact_keep "no fleet-publish entry is installed — nothing to remove"
        impact_render
        if [ "$n_drop" -gt 0 ]; then
            impact_confirm standard "rewrite this machine's crontab" "$auto_yes" \
                || { print_info "Cancelled."; return 1; }
        fi
        printf '%s\n' "$cleaned" | crontab -
        print_status "OK" "Removed the fleet-publish cron entry"
        return 0
    fi

    local entry="$CRON_MARKER
$schedule cd $PROJECT_ROOT && PATH=\"$(_cron_path)\" ./pl fleet publish --quiet >> $PROJECT_ROOT/logs/fleet-publish.log 2>&1"
    impact_overwrite "Crontab" \
        "one fleet-publish entry on '$schedule' installed for $(id -un) on $(hostname -s 2>/dev/null || hostname)"
    impact_render
    if [ "$n_drop" -gt 0 ]; then
        impact_confirm standard "rewrite this machine's crontab" "$auto_yes" \
            || { print_info "Cancelled."; return 1; }
    fi
    printf '%s\n%s\n' "$cleaned" "$entry" | crontab -
    print_status "OK" "Publishing fleet state on '$schedule' from this machine"
    print_info "The console marks the snapshot STALE past its max-age (default 2h) —"
    print_info "keep this cadence well inside that window."
    print_hint "Verify: crontab -l | grep -A1 'NWP Fleet Publish'"
}

# ---------------------------------------------------------------------------
# pl fleet checkout [--json] — THIS host's own nwp checkout, network-free
# (ops#329). The console runs it on its own host to answer "is the code I am
# running current?": branch, HEAD, ahead/behind vs origin/main AS OF THE LAST
# FETCH (with the age of that fetch riding along — the pl-freshness rule:
# never touch the network on a read path), dirtiness, and the loop-pause flag.
# ---------------------------------------------------------------------------
cmd_checkout() {
    local as_json=false a
    for a in "$@"; do
        case "$a" in
            --json) as_json=true ;;
            *) print_error "REFUSED: unrecognised argument(s) for 'pl fleet checkout': $a"
               return 2 ;;
        esac
    done
    NWP_ROOT="$PROJECT_ROOT" NWP_AS_JSON="$as_json" python3 - <<'PY'
import json, os, subprocess, sys

root = os.environ["NWP_ROOT"]

def git(*args, timeout=10):
    try:
        p = subprocess.run(["git", "-C", root, *args], capture_output=True,
                           text=True, timeout=timeout)
        return p.stdout.strip() if p.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired):
        return None

head = git("rev-parse", "HEAD")
if head is None:
    doc = {"ok": False, "reason": f"{root} is not a readable git checkout"}
    print(json.dumps(doc)); sys.exit(2)

counts = git("rev-list", "--left-right", "--count", "origin/main...HEAD")
behind = ahead = None
if counts:
    try:
        behind, ahead = (int(x) for x in counts.split())
    except ValueError:
        pass

# Age of the last fetch: newest of the ref artefacts a fetch touches. This is
# what makes the behind-count honest — it is a fact about that moment.
fetched = None
gitdir = git("rev-parse", "--git-common-dir") or git("rev-parse", "--git-dir")
if gitdir:
    if not os.path.isabs(gitdir):
        gitdir = os.path.join(root, gitdir)
    import time
    times = []
    for rel in ("FETCH_HEAD", "refs/remotes/origin/main", "packed-refs"):
        try:
            times.append(os.stat(os.path.join(gitdir, rel)).st_mtime)
        except OSError:
            pass
    if times:
        fetched = max(0, int(time.time() - max(times)))

doc = {
    "ok": True,
    "root": root,
    "branch": git("rev-parse", "--abbrev-ref", "HEAD") or "",
    "head": head,
    "head_short": head[:7],
    "head_time": git("log", "-1", "--format=%cI") or "",
    "ahead": ahead,
    "behind": behind,
    "fetched_age_seconds": fetched,
    "dirty": bool(git("status", "--porcelain", "-uno")),
    "loop_paused": os.path.exists(os.path.join(root, ".loop-paused")),
}
if os.environ.get("NWP_AS_JSON") == "true":
    print(json.dumps(doc, sort_keys=True))
else:
    b = "?" if behind is None else behind
    a = "?" if ahead is None else ahead
    print(f"checkout : {root}")
    print(f"branch   : {doc['branch']} @ {doc['head_short']}  ({doc['head_time']})")
    print(f"vs origin/main : {b} behind / {a} ahead"
          + (f"  (as of last fetch, {fetched}s ago)" if fetched is not None
             else "  (fetch age unknown)"))
    print(f"dirty    : {doc['dirty']}   loop_paused: {doc['loop_paused']}")
PY
}

# ---------------------------------------------------------------------------
# pl fleet estate [--json] — the estate feed (ops#329): repo drift for the
# fixed set of checkouts the demo pair runs from, deploy records, harvest
# spool counts, secrets rotation debt, and local backup ages. Published with
# the fleet snapshot (feeds.estate) so the console renders it with provenance
# and age; each git fetch is time-boxed and a failed fetch is RECORDED
# (fetched:false) rather than silently serving stale counts as current.
# ---------------------------------------------------------------------------
cmd_estate() {
    local as_json=false a
    for a in "$@"; do
        case "$a" in
            --json) as_json=true ;;
            *) print_error "REFUSED: unrecognised argument(s) for 'pl fleet estate': $a"
               return 2 ;;
        esac
    done
    NWP_ROOT="$PROJECT_ROOT" NWP_AS_JSON="$as_json" python3 - <<'PY'
import glob, json, os, re, subprocess, sys, time
from datetime import datetime, timezone

root = os.environ["NWP_ROOT"]
DEMO_SITES = ("nwd", "ssd")

# The fixed, reviewable checkout set. Growing it is a reviewed change, not a
# discovery pass — a repo nobody expected must not silently join the feed.
REPOS = [
    ("nwp", "."),
    ("nwc-profile (nwd/stg)", "sites/nwd/stg/html/profiles/custom/nwc"),
    ("nwc-profile (nwd/dev)", "sites/nwd/dev/html/profiles/custom/nwc"),
    ("nwc-profile (nwc/dev)", "sites/nwc/dev/html/profiles/custom/nwc"),
    ("ss-moodle-plugins (ssd)", "sites/ssd/.plugin-src/ss-moodle-plugins"),
]


def git(path, *args, timeout=10):
    try:
        p = subprocess.run(["git", "-C", path, *args], capture_output=True,
                           text=True, timeout=timeout)
        return p.stdout.strip() if p.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired):
        return None


repos = []
for name, rel in REPOS:
    path = os.path.normpath(os.path.join(root, rel))
    if git(path, "rev-parse", "HEAD") is None:
        repos.append({"name": name, "path": rel, "present": False})
        continue
    fetched = git(path, "fetch", "-q", "origin", timeout=25) is not None
    counts = git(path, "rev-list", "--left-right", "--count", "origin/main...HEAD")
    behind = ahead = None
    if counts:
        try:
            behind, ahead = (int(x) for x in counts.split())
        except ValueError:
            pass
    head = git(path, "rev-parse", "HEAD") or ""
    repos.append({
        "name": name, "path": rel, "present": True,
        "branch": git(path, "rev-parse", "--abbrev-ref", "HEAD") or "",
        "head": head[:12],
        "head_time": git(path, "log", "-1", "--format=%cI") or "",
        "ahead": ahead, "behind": behind, "fetched": fetched,
        "dirty": bool(git(path, "status", "--porcelain", "-uno")),
    })

# --- deploy records ---------------------------------------------------------
deploys = {}
manifests = sorted(glob.glob(os.path.join(root, "private/deploys/nwd/stg2live-*.json")))
if manifests:
    try:
        with open(manifests[-1]) as f:
            m = json.load(f)
        deploys["nwd"] = {"last": m.get("timestamp", ""),
                          "nwp_sha": str(m.get("nwp_sha", ""))[:12],
                          "code_only": str(m.get("code_only", "")) == "true"}
    except (OSError, ValueError):
        deploys["nwd"] = None
else:
    deploys["nwd"] = None

# ssd plugin lockfile — a tiny tolerant walk of the known shape; stdlib has no
# YAML and this file is machine-written by moodle_lock_record.
plugins = []
lock = os.path.join(root, "sites/ssd/.nwp-plugins.lock.yml")
try:
    tier = plugin = None
    row = {}
    with open(lock) as f:
        for line in f:
            if re.match(r"^  (\S+):\s*$", line):
                tier = line.strip().rstrip(":")
                plugin = None
            elif re.match(r"^    \S+.*:\s*$", line):
                if plugin and row:
                    plugins.append(dict(row, plugin=plugin, tier=tier))
                plugin = line.strip().rstrip(":")
                row = {}
            else:
                m = re.match(r"^      (\w+):\s*\"?([^\"\n]*)\"?\s*$", line)
                if m:
                    row[m.group(1)] = m.group(2)
    if plugin and row:
        plugins.append(dict(row, plugin=plugin, tier=tier))
except OSError:
    pass
deploys["ssd_plugins"] = [
    {"plugin": p.get("plugin", "?"), "tier": p.get("tier", ""),
     "version": p.get("version", ""), "release": p.get("release", ""),
     "repo_commit": str(p.get("repo_commit", ""))[:12],
     "deployed_at": p.get("deployed_at", "")}
    for p in plugins if p.get("tier") == "live"
]

# --- harvest spool ----------------------------------------------------------
harvest = {}
for site in DEMO_SITES:
    hdir = os.path.join(root, "sites", site, "demo-harvest")
    if not os.path.isdir(hdir):
        harvest[site] = {"present": False}
        continue
    try:
        spool = len(glob.glob(os.path.join(hdir, "harvest-*.md")))
        posted = len(glob.glob(os.path.join(hdir, "posted", "harvest-*.md")))
        triaged = sum(len(glob.glob(os.path.join(d, "harvest-*.md")))
                      for d in glob.glob(os.path.join(hdir, "triaged-*")))
        harvest[site] = {"present": True, "spool": spool, "posted": posted,
                         "triaged": triaged}
    except OSError:
        harvest[site] = {"present": True, "spool": None}

# --- secrets rotation debt --------------------------------------------------
debt = {"ok": False}
try:
    p = subprocess.run([os.path.join(root, "pl"), "secrets", "debt", "--json"],
                       capture_output=True, text=True, timeout=30, cwd=root)
    rows = json.loads(p.stdout or "[]")
    if isinstance(rows, list):
        debt = {"ok": True, "open": len(rows)}
except (OSError, ValueError, subprocess.TimeoutExpired):
    pass

# --- local backup ages ------------------------------------------------------
backups = {}
for site in DEMO_SITES:
    bdir = os.path.join(root, "sites", site, "backups")
    try:
        files = [p for p in glob.glob(os.path.join(bdir, "*"))
                 if os.path.isfile(p) and (p.endswith(".sql.gz") or p.endswith(".tar.gz"))]
        if not files:
            backups[site] = {"present": False}
            continue
        newest = max(files, key=os.path.getmtime)
        backups[site] = {"present": True,
                         "newest": os.path.basename(newest),
                         "age_seconds": max(0, int(time.time() - os.path.getmtime(newest))),
                         "size_bytes": os.path.getsize(newest),
                         "count": len(files)}
    except OSError:
        backups[site] = {"present": False}

doc = {
    "ok": True,
    "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "host": __import__("socket").gethostname(),
    "repos": repos,
    "deploys": deploys,
    "harvest": harvest,
    "secrets_debt": debt,
    "backups": backups,
}
if os.environ.get("NWP_AS_JSON") == "true":
    print(json.dumps(doc, sort_keys=True))
else:
    print(f"estate feed from {doc['host']} at {doc['generated_at']}")
    for r in repos:
        if not r["present"]:
            print(f"  {r['name']}: NOT PRESENT")
        else:
            b = "?" if r["behind"] is None else r["behind"]
            a = "?" if r["ahead"] is None else r["ahead"]
            f = "" if r["fetched"] else "  [FETCH FAILED — counts vs last fetch]"
            print(f"  {r['name']}: {r['branch']}@{r['head'][:7]}  {b} behind / {a} ahead{f}")
    print(f"  secrets debt: {'open=' + str(debt.get('open')) if debt.get('ok') else 'UNREADABLE'}")
    for site, h in harvest.items():
        print(f"  {site} harvest: " + ("absent" if not h.get("present")
              else f"spool={h.get('spool')} posted={h.get('posted')} triaged={h.get('triaged')}"))
PY
}

# ---------------------------------------------------------------------------
# pl fleet sync — automated engine-code propagation to nwp hosts (ops#360).
#
# On 2026-08-12 the ai-host's ~/nwp — the clone the ARMED agent-loop executes from —
# was measured 59 commits behind origin/main. This family provisions ONE
# reviewed worker (scripts/fleet-sync-host.sh) as a marked */15 cron on each
# non-prod host, and makes "who is behind?" a first-class, fail-closed fact.
#
#   pl fleet sync install --host=<role> [--schedule='*/15 * * * *'] [--dry-run]
#   pl fleet sync remove  --host=<role>
#   pl fleet sync run     --host=<role>      one supervised sync now (also the
#                                            bootstrap when the worker has not
#                                            reached the host yet)
#   pl fleet sync status  [--host=<role>] [--quiet]
#
# THE GUARD (NWP-ADR-0017/0028, CLAUDE.md "key off the canonical phase/role, never
# a hostname list"): every verb that targets a host first resolves the ROLE
# through the instance manifest and REFUSES when the role — or ANY role the
# resolved host also holds — is prod-reaching (verifier, signed-deploy,
# prod-cluster, prod-agent, prod-au). the verifier tier receives code as signed
# artifacts through their own verification path, never through this. The
# guard is inert today (no prod exists) and proven RED against a fixture
# manifest in tests/unit/test-fleet-sync.bats, the estate's standard for
# inert guards. `authoring` is refused too: sessions control the dev tree.
# No readable manifest = CANNOT VERIFY = refusal, never a pass.
# ---------------------------------------------------------------------------
SYNC_CRON_BEGIN="# >>> nwp fleet sync (pl fleet sync) >>>"
SYNC_CRON_END="# <<< nwp fleet sync <<<"
SYNC_DENY_ROLES="verifier signed-deploy prod-cluster prod-agent prod-au"
SYNC_DEFAULT_ROLES="ai-host ci-host"

_sync_manifest() { printf '%s' "${NWP_INSTANCE_MANIFEST:-$HOME/nwp-instances/instance-manifest.yml}"; }

_sync_role_hosts() { # $1 = role → hosts, space-separated (empty if unbound)
    yq e ".roles.\"$1\" // [] | .[]" "$(_sync_manifest)" 2>/dev/null | tr '\n' ' '
}

# Resolve + guard a target role. Prints the bound host(s) on stdout.
# Returns 2 (refusal) on: deny role, authoring, unresolvable manifest,
# unbound role, or a host that ALSO holds a deny role.
_sync_guard_role() {
    local role="$1" manifest; manifest="$(_sync_manifest)"
    if [ "$role" = "authoring" ]; then
        print_error "REFUSED: --host=authoring — the dev workstation is out of scope for auto-sync; sessions control that tree (concurrent branches, worktrees)"
        return 2
    fi
    local dr
    for dr in $SYNC_DENY_ROLES; do
        if [ "$role" = "$dr" ]; then
            print_error "REFUSED: --host=$role is a prod-reaching role — prod hosts receive code as SIGNED ARTIFACTS via their own verification path (NWP-ADR-0017/0028), never via fleet sync"
            return 2
        fi
    done
    if [ ! -f "$manifest" ] || ! command -v yq >/dev/null 2>&1; then
        print_error "CANNOT VERIFY: instance manifest unreadable ($manifest) or yq missing — cannot prove the target is not prod, refusing (fail closed)"
        return 2
    fi
    local hosts; hosts="$(_sync_role_hosts "$role")"
    if [ -z "${hosts// /}" ]; then
        print_error "REFUSED: role '$role' is bound to no host in $manifest"
        return 2
    fi
    local h dhosts dh
    for dr in $SYNC_DENY_ROLES; do
        dhosts="$(_sync_role_hosts "$dr")"
        for h in $hosts; do
            for dh in $dhosts; do
                if [ "$h" = "$dh" ]; then
                    print_error "REFUSED: host '$h' (role $role) is ALSO bound to prod-reaching role '$dr' — a multi-role box with a prod leg is never an auto-sync target"
                    return 2
                fi
            done
        done
    done
    printf '%s\n' "$hosts"
}

_sync_ssh_cmd() { # $1 = host → an ssh argv prefix
    local c=""
    if [ -f "$REPO_ROOT/lib/server-resolver.sh" ]; then
        # shellcheck source=/dev/null
        source "$REPO_ROOT/lib/server-resolver.sh" 2>/dev/null || true
        declare -F get_server_ssh_command >/dev/null 2>&1 \
            && c=$(get_server_ssh_command "$1" 2>/dev/null) || c=""
    fi
    printf '%s' "${c:-ssh -o BatchMode=yes -o ConnectTimeout=10 $1}"
}

_sync_remote_root() { # $1 = ssh cmd; where the target's checkout lives
    # the remote loop breaks after the first hit, so no `| head` is needed —
    # and under pipefail a head-truncated pipe is a sigpipe race (ops#351)
    $1 'for d in "$HOME/nwp" /opt/nwp /srv/nwp; do [ -d "$d/.git" ] && { echo "$d"; break; }; done' 2>/dev/null
}

cmd_sync() {
    local sub="${1:-status}"; shift || true
    local ROLE="" SCHED='*/15 * * * *' DRY=false QUIET=false a
    for a in "$@"; do case "$a" in
        --host=*)     ROLE="${a#--host=}" ;;
        --schedule=*) SCHED="${a#--schedule=}" ;;
        --dry-run|-n) DRY=true ;;
        --quiet|-q)   QUIET=true ;;
        -h|--help)    show_help; return 0 ;;
        *) print_error "REFUSED: unrecognised argument for 'pl fleet sync': $a"; return 2 ;;
    esac; done

    case "$sub" in
    install|run)
        [ -n "$ROLE" ] || { print_error "usage: pl fleet sync $sub --host=<role>"; return 2; }
        local hosts; hosts=$(_sync_guard_role "$ROLE") || return 2
        local h ssh_cmd root rc=0
        for h in $hosts; do
            ssh_cmd=$(_sync_ssh_cmd "$h")
            root=$(_sync_remote_root "$ssh_cmd")
            [ -n "$root" ] || { print_error "$h: no nwp checkout found (\$HOME/nwp, /opt/nwp, /srv/nwp) — clone it first"; rc=2; continue; }
            if [ "$sub" = "run" ]; then
                print_header "fleet sync — supervised run on $h ($ROLE)"
                if $ssh_cmd "[ -f '$root/scripts/fleet-sync-host.sh' ]" 2>/dev/null; then
                    $ssh_cmd "NWP_SYNC_ROLE=$ROLE bash '$root/scripts/fleet-sync-host.sh'" || rc=2
                else
                    # Bootstrap: the reviewed worker has not REACHED this host
                    # yet (it arrives with the very pull it performs). Minimal
                    # guarded ff-only pull, same refusals, loudly labelled.
                    print_warning "$h: worker not present yet — BOOTSTRAP (minimal guarded ff-only pull; the worker takes over from the next sync)"
                    $ssh_cmd "set -e
                        cd '$root'
                        b=\$(git rev-parse --abbrev-ref HEAD)
                        [ \"\$b\" = main ] || { echo \"SKIPPED: on branch \$b, not main\"; exit 2; }
                        [ -z \"\$(git status --porcelain -uno)\" ] || { echo 'SKIPPED: tree is dirty'; exit 2; }
                        git fetch -q origin main
                        from=\$(git rev-parse HEAD); to=\$(git rev-parse origin/main)
                        git merge-base --is-ancestor \"\$from\" \"\$to\" || { echo 'REFUSED: diverged'; exit 2; }
                        git merge --ff-only -q \"\$to\"
                        echo \"BOOTSTRAP SYNCED: \${from:0:9} -> \${to:0:9}\"" || rc=2
                fi
                continue
            fi
            # install
            local block="$SYNC_CRON_BEGIN
$SCHED NWP_SYNC_ROLE=$ROLE $root/scripts/fleet-sync-host.sh >> $root/logs/fleet-sync-cron.log 2>&1
$SYNC_CRON_END"
            print_header "fleet sync — install on $h ($ROLE)"
            printf '%s\n' "$block" | sed 's/^/  /'
            if [ "$DRY" = true ]; then print_warning "--dry-run: nothing written"; continue; fi
            if ! $ssh_cmd "[ -f '$root/scripts/fleet-sync-host.sh' ]" 2>/dev/null; then
                print_error "$h: $root/scripts/fleet-sync-host.sh not present — run 'pl fleet sync run --host=$ROLE' once to bootstrap, then install"
                rc=2; continue
            fi
            # idempotent marked-block rewrite (same idiom as pl secrets cron)
            if $ssh_cmd "BLOCK=\$(cat <<'EOF'
$block
EOF
)
set -e
cur=\$(crontab -l 2>/dev/null || true)
new=\$(printf '%s\n' \"\$cur\" | awk 'BEGIN{s=1} /^# >>> nwp fleet sync/{s=0} s{print} /^# <<< nwp fleet sync/{s=1}')
printf '%s\n%s\n' \"\$new\" \"\$BLOCK\" | grep -v '^\$' | crontab -"; then
                print_success "installed on $h — schedule: $SCHED"
                print_hint "verify: pl fleet sync status --host=$ROLE"
            else
                print_error "failed to install the cron block on $h"; rc=2
            fi
        done
        return $rc
        ;;
    remove)
        [ -n "$ROLE" ] || { print_error "usage: pl fleet sync remove --host=<role>"; return 2; }
        # deliberately NOT the full guard: if a host BECAME prod-bound you must
        # still be able to remove the cron. Only resolve the role.
        command -v yq >/dev/null 2>&1 && [ -f "$(_sync_manifest)" ] \
            || { print_error "CANNOT VERIFY: manifest unreadable — cannot resolve '$ROLE'"; return 2; }
        local h ssh_cmd
        for h in $(_sync_role_hosts "$ROLE"); do
            ssh_cmd=$(_sync_ssh_cmd "$h")
            if $ssh_cmd "cur=\$(crontab -l 2>/dev/null || true); printf '%s\n' \"\$cur\" | awk 'BEGIN{s=1} /^# >>> nwp fleet sync/{s=0} s{print} /^# <<< nwp fleet sync/{s=1}' | crontab -" 2>/dev/null; then
                print_success "removed the fleet-sync cron block from $h"
            else
                print_error "could not rewrite crontab on $h"; return 2
            fi
        done
        ;;
    status)
        local roles="${ROLE:-${NWP_FLEET_SYNC_ROLES:-}}"
        if [ -z "$roles" ]; then
            local cfgf; cfgf=$(_console_cfg_file)
            [ -n "$cfgf" ] && command -v yq >/dev/null 2>&1 \
                && roles=$(yq e '.settings.fleet.sync_roles // ""' "$cfgf" 2>/dev/null | grep -v '^null$' || true)
            roles="${roles:-$SYNC_DEFAULT_ROLES}"
        fi
        command -v yq >/dev/null 2>&1 && [ -f "$(_sync_manifest)" ] \
            || { print_error "CANNOT VERIFY: instance manifest unreadable — cannot resolve sync targets"; return 2; }
        # the truth is the FORGE's main, not this checkout's opinion of it
        local truth
        truth=$(git -C "$REPO_ROOT" ls-remote origin refs/heads/main 2>/dev/null | cut -f1)
        if [ -z "$truth" ]; then
            print_error "CANNOT VERIFY: could not read origin's main from here — no host can be graded"
            return 2
        fi
        [ "$QUIET" = true ] || print_header "fleet sync — engine-code currency per host (truth: main @ ${truth:0:9})"
        local role h seen=" " rc=0 ssh_cmd info
        for role in $roles; do
            local skip_dr=false dr
            for dr in $SYNC_DENY_ROLES authoring; do
                [ "$role" = "$dr" ] && { print_warning "$role: excluded from sync by policy"; skip_dr=true; }
            done
            [ "$skip_dr" = true ] && continue
            for h in $(_sync_role_hosts "$role"); do
                case "$seen" in *" $h "*) continue ;; esac
                seen="$seen$h "
                ssh_cmd=$(_sync_ssh_cmd "$h")
                info=$($ssh_cmd "for d in \"\$HOME/nwp\" /opt/nwp /srv/nwp; do [ -d \"\$d/.git\" ] && { root=\$d; break; }; done
                    [ -n \"\${root:-}\" ] || { echo NOROOT; exit 0; }
                    echo HEAD=\$(git -C \"\$root\" rev-parse HEAD 2>/dev/null)
                    echo BRANCH=\$(git -C \"\$root\" rev-parse --abbrev-ref HEAD 2>/dev/null)
                    echo BEHIND=\$(git -C \"\$root\" rev-list --count HEAD..$truth 2>/dev/null || echo unknown)
                    echo STATE=\$(cat \"\$root/logs/fleet-sync-state.json\" 2>/dev/null | tr -d '\n')" 2>/dev/null) || info=""
                if [ -z "$info" ]; then
                    print_error "$h ($role): UNREACHABLE — CANNOT VERIFY (an unreachable host is never 'up to date')"
                    rc=2; continue
                fi
                if [ "$info" = "NOROOT" ]; then
                    print_error "$h ($role): no nwp checkout found"; rc=2; continue
                fi
                local hd st behind branch last
                hd=$(printf '%s\n' "$info" | sed -n 's/^HEAD=//p')
                branch=$(printf '%s\n' "$info" | sed -n 's/^BRANCH=//p')
                behind=$(printf '%s\n' "$info" | sed -n 's/^BEHIND=//p')
                st=$(printf '%s\n' "$info" | sed -n 's/^STATE=//p')
                last=$(printf '%s' "$st" | python3 -c 'import json,sys
try: d=json.load(sys.stdin); print(f"{d[\"result\"]} at {d[\"ts\"]}" + (" restart_pending="+",".join(d["restart_pending"]) if d.get("restart_pending") else ""))
except Exception: print("no sync record")' 2>/dev/null || echo "no sync record")
                if [ "$hd" = "$truth" ]; then
                    [ "$QUIET" = true ] || print_success "$h ($role): CURRENT @ ${hd:0:9} — $last"
                    case "$last" in *restart_pending*) print_warning "$h: a long-running service is still executing pre-pull code"; [ $rc -lt 1 ] && rc=1 ;; esac
                else
                    local bdesc="${behind:-?} commit(s)"
                    [ "$behind" = "unknown" ] && bdesc="count unknown — host has not fetched current main"
                    print_error "$h ($role): BEHIND ($bdesc; HEAD ${hd:0:9}, branch ${branch:-?}) — $last"
                    print_hint "  settle now: pl fleet sync run --host=$role"
                    [ $rc -lt 1 ] && rc=1
                fi
            done
        done
        return $rc
        ;;
    *) print_error "usage: pl fleet sync install|remove|run|status [--host=<role>]"; return 2 ;;
    esac
}

main() {
    local sub="${1:-}"; shift || true
    case "$sub" in
        -h|--help|"") show_help ;;
        publish)  cmd_publish "$@" ;;
        snapshot) cmd_snapshot "$@" ;;
        security) cmd_security "$@" ;;
        estate)   cmd_estate "$@" ;;
        checkout) cmd_checkout "$@" ;;
        status)   cmd_status "$@" ;;
        schedule) cmd_schedule "$@" ;;
        sync)     cmd_sync "$@" ;;
        *) print_error "Unknown subcommand: $sub"; show_help; return 1 ;;
    esac
}

# Sourced by tests (bats) to exercise the budget arithmetic without dispatching
# — the same idiom demo.sh and ver-test.sh already use. `pl` reaches this file
# through run_script, which EXECUTES it, so the guard never affects dispatch.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
