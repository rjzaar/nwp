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
FLEET_SCHEMA="nwp.fleet-state"
FLEET_SCHEMA_VERSION=1

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
    pl fleet publish [--to <ssh-host>] [--dest <path>] [--no-todo] [--dry-run] [--quiet]
    pl fleet snapshot [--out <path>] [--no-todo]
    pl fleet status [--to <ssh-host>]
    pl fleet schedule [--schedule "<cron>"] [--remove] [-y]

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
    --dry-run         build the snapshot, print the summary, ship nothing
    --quiet           only report failures (for cron)

${BOLD}SNAPSHOT:${NC}
    schema $FLEET_SCHEMA v$FLEET_SCHEMA_VERSION — generated_at (UTC), generated_by
    (host/user/root/version), and one entry per feed under .feeds:
      feeds.rag.data   = \`pl rag --json --no-todo\` verbatim
      feeds.todo.data  = \`pl todo check --json\` verbatim (backup freshness too)
    Written 0600, shipped atomically (tmp + mv), never contains a secret.

${BOLD}EXAMPLES:${NC}
    pl fleet publish                     # gather + ship to the console host
    pl fleet publish --to <host> --dry-run  # see what would be published
    pl fleet schedule                    # publish every 30 min from this host
EOF
}

# --- gathering ---------------------------------------------------------------
# Each feed is captured independently and best-effort: a feed that fails is
# recorded as ok:false with its rc/stderr, and the others still publish. The
# consumer degrades that feed only (same contract as the console's panes).
_capture_feed() { # $1 outdir, $2 name, $3... argv
    local outdir="$1" name="$2"; shift 2
    local started ended rc=0
    started=$(date +%s.%N)
    set +e
    "$PROJECT_ROOT/pl" "$@" >"$outdir/$name.out" 2>"$outdir/$name.err"
    rc=$?
    set -e
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
        feed["error"] = perr or tail or f"rc={rc}"
        feed["raw"] = out[-2000:]
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
build_snapshot() { # $1 dest file, $2 include_todo(true|false), $3 quiet
    local dest="$1" include_todo="${2:-true}" quiet="${3:-false}"
    local tmpdir; tmpdir=$(mktemp -d); chmod 700 "$tmpdir"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmpdir'" RETURN

    local feeds="rag"
    [ "$quiet" = true ] || print_info "Gathering rag (pl rag --json --no-todo)…"
    _capture_feed "$tmpdir" rag rag --json --no-todo
    if [ "$include_todo" = true ]; then
        [ "$quiet" = true ] || print_info "Gathering todo + backup freshness (pl todo check --json)…"
        _capture_feed "$tmpdir" todo todo check --json
        feeds="rag todo"
    fi

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
print("  todo         : {} items ({} backup-freshness)".format(
    s.get("todo_items", "-"), s.get("backup_items", "-")))
for name, f in sorted(d.get("feeds", {}).items()):
    mark = "ok" if f.get("ok") else "FAILED"
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
    while [ $# -gt 0 ]; do
        case "$1" in
            --to)       host="${2:-}"; shift 2 ;;
            --to=*)     host="${1#--to=}"; shift ;;
            --dest)     dest="${2:-}"; shift 2 ;;
            --dest=*)   dest="${1#--dest=}"; shift ;;
            --no-todo)  include_todo=false; shift ;;
            --dry-run)  dry_run=true; shift ;;
            --quiet|-q) quiet=true; shift ;;
            -h|--help)  show_help; return 0 ;;
            *) print_error "unknown option: $1"; return 1 ;;
        esac
    done

    build_snapshot "$LOCAL_STATE" "$include_todo" "$quiet" || return 1
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
        rhome=$(ssh -o ConnectTimeout=15 -o BatchMode=yes "$host" 'printf %s "$HOME"' 2>/dev/null) \
            || { print_error "cannot ssh to $host"; return 1; }
        [ -n "$rhome" ] || { print_error "could not resolve \$HOME on $host"; return 1; }
        dest="$rhome/$DEFAULT_REMOTE_REL"
    fi
    _dest_ok "$dest" || { print_error "refusing suspicious --dest: $dest"; return 1; }

    [ "$quiet" = true ] || print_info "Shipping to ${host}:${dest} (0600, atomic)"
    # umask first so the tmp file is never briefly world-readable.
    if ! ssh -o ConnectTimeout=20 -o BatchMode=yes "$host" \
            "umask 077; mkdir -p \"\$(dirname '$dest')\" && cat > '$dest.tmp.\$\$' && chmod 600 '$dest.tmp.\$\$' && mv -f '$dest.tmp.\$\$' '$dest'" \
            < "$LOCAL_STATE"; then
        print_error "failed to ship the snapshot to ${host}:${dest}"
        return 1
    fi

    # Verify what landed: same byte count, and it still parses over there is
    # the consumer's problem — size + mtime is the cheap honest check.
    local local_size remote_size
    local_size=$(wc -c < "$LOCAL_STATE" | tr -d ' ')
    remote_size=$(ssh -o ConnectTimeout=15 -o BatchMode=yes "$host" "wc -c < '$dest'" 2>/dev/null | tr -d ' ' || true)
    if [ "$local_size" != "$remote_size" ]; then
        print_error "verification failed: shipped $local_size bytes, host reports '${remote_size:-none}'"
        return 1
    fi
    [ "$quiet" = true ] || print_success "published ${local_size} bytes to ${host}:${dest}"
    return 0
}

cmd_snapshot() {
    local out="$LOCAL_STATE" include_todo=true
    while [ $# -gt 0 ]; do
        case "$1" in
            --out)     out="${2:-}"; shift 2 ;;
            --out=*)   out="${1#--out=}"; shift ;;
            --no-todo) include_todo=false; shift ;;
            -h|--help) show_help; return 0 ;;
            *) print_error "unknown option: $1"; return 1 ;;
        esac
    done
    build_snapshot "$out" "$include_todo" false || return 1
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

main() {
    local sub="${1:-}"; shift || true
    case "$sub" in
        -h|--help|"") show_help ;;
        publish)  cmd_publish "$@" ;;
        snapshot) cmd_snapshot "$@" ;;
        status)   cmd_status "$@" ;;
        schedule) cmd_schedule "$@" ;;
        *) print_error "Unknown subcommand: $sub"; show_help; return 1 ;;
    esac
}

main "$@"
