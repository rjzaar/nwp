#!/usr/bin/env bash
#
# lib/nginx-conf-parity.sh — the engine behind `pl server conf-drift <server>`.
#
# WHY THIS FILE EXISTS (nwp/ops#157 / #92 / #106, register D19)
# ------------------------------------------------------------
# `pl server roots` reconciles what nginx is RUNNING against what NWP declares.
# It cannot see the other half of the danger: a vhost FILE sitting in the
# host's conf.d that is not in the tracked server repo. On 2026-07-29 two such
# strays (cathnet.conf, dir1.conf) sat on the box, each claiming a live
# server_name with a root that no longer existed. They did nothing — until an
# unrelated `gitlab-ctl hup nginx` (reloading a legitimately-changed vhost)
# armed them, and a live site 404'd for ~15 minutes. On an omnibus-nginx host
# ANY reload activates whatever is in conf.d; an unloaded stray is a time bomb
# whose fuse is the next reload.
#
# This verb makes the tracked server repo the source of truth for WHICH conf
# files may exist, and flags any divergence BEFORE a reload can arm it:
#   STRAY      on the box, not in the tracked repo — the time bomb
#   UNDEPLOYED in the tracked repo, not on the box — drift the other way
#
# DESIGN RULES (shared with lib/served-roots.sh — do not relax without a
# decision-log entry):
#  1. FAIL CLOSED ON BLINDNESS. An unreadable box dir, a dead transport, or a
#     missing tracked repo is CANNOT-VERIFY (rc=3), NEVER a clean "in parity".
#     An empty box listing that we could not prove is empty is blindness.
#  2. NO HAND-MAINTAINED ALLOWLIST. The only way to make a conf legitimate is to
#     track it in servers/<server>/nginx/conf.d/ (or retire it to a sibling
#     directory that is, by construction, NOT in conf.d). A retired conf is
#     invisible to nginx AND recorded — the same discipline the 2026-07-29
#     cleanup used (mothballed-YYYYMMDD/).
#  3. READ-ONLY BY CONSTRUCTION. The box side is a single `ls` of one directory.
#     It writes nothing, reloads nothing, runs no nginx binary.
#  4. CHEAP AND SERIAL. One ssh round trip, one ls. Never nginx -t/-T (that
#     parses the whole graph and is heavier than this needs to be, on a box
#     that OOMs — design rule 4 of served-roots).

# nginx_parity_listing_script — emits the on-box conf.d basenames, one per line,
# behind a banner. Only *.conf directly in conf.d (not subdirectories: a
# retired/mothballed conf lives in a subdir precisely so nginx does not read it,
# and neither should this check count it as present).
nginx_parity_listing_script() {
    cat <<'PROBE'
set -u
D=/etc/nginx/conf.d
if [ ! -d "$D" ]; then echo "NWPCONF v1"; echo "confdir=absent"; exit 0; fi
if [ ! -r "$D" ]; then echo "NWPCONF v1"; echo "confdir=unreadable"; exit 0; fi
echo "NWPCONF v1"
echo "confdir=present"
# maxdepth 1: top-level conf.d only; mothballed/retired live in subdirs.
for f in "$D"/*.conf; do
    [ -e "$f" ] || continue
    b=$(basename "$f")
    echo "F$b"
done
PROBE
}

# nginx_parity_tracked_dir <server> <root> — echo the tracked conf.d path, or
# empty. The server repo (servers/<server>/) is a separate local checkout; the
# vhost baseline lives at servers/<server>/nginx/conf.d/.
nginx_parity_tracked_dir() {
    local server="$1" root="$2"
    printf '%s/servers/%s/nginx/conf.d' "$root" "$server"
}

# nginx_parity_compare <onbox_newline_list> <tracked_newline_list>
# Populates in the caller's scope:
#   NP_STRAY[]      basenames on the box but not tracked
#   NP_UNDEPLOYED[] basenames tracked but not on the box
#   NP_MATCHED      count present in both
# Pure: no I/O. Both inputs are newline-separated basenames (may be empty).
nginx_parity_compare() {
    local onbox="$1" tracked="$2"
    NP_STRAY=(); NP_UNDEPLOYED=(); NP_MATCHED=0
    local -A on=() tr=()
    local b
    while IFS= read -r b; do [ -n "$b" ] && on["$b"]=1; done <<< "$onbox"
    while IFS= read -r b; do [ -n "$b" ] && tr["$b"]=1; done <<< "$tracked"
    for b in "${!on[@]}"; do
        if [ -n "${tr[$b]:-}" ]; then NP_MATCHED=$((NP_MATCHED+1)); else NP_STRAY+=("$b"); fi
    done
    for b in "${!tr[@]}"; do
        [ -z "${on[$b]:-}" ] && NP_UNDEPLOYED+=("$b")
    done
    return 0
}

# nginx_parity_check <server> <root> — orchestrate. Prints a report.
#   rc 0  in parity (every on-box conf is tracked, and vice versa)
#   rc 1  drift found (strays and/or undeployed)
#   rc 3  CANNOT-VERIFY (blindness — never treated as parity)
# The box side runs through the same host_run/PROBE_CMD indirection as
# served-roots, so tests inject a fake box with --probe-cmd.
nginx_parity_check() {
    local server="$1" root="$2" prefix="$3"

    local tracked_dir; tracked_dir="$(nginx_parity_tracked_dir "$server" "$root")"
    if [ ! -d "$tracked_dir" ]; then
        printf 'CANNOT-VERIFY: no tracked nginx baseline at %s — cannot say what may be served.\n' "$tracked_dir"
        printf '  (Track the vhost baseline first: it is what strays are diffed against.)\n'
        return 3
    fi

    local capture rc
    capture="$(host_run "$prefix" "$(nginx_parity_listing_script)" 2>/dev/null)"; rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$capture" ] || [[ "$capture" != *"NWPCONF"* ]]; then
        printf 'CANNOT-VERIFY: the conf.d listing probe failed (rc=%s) — this is NOT "in parity".\n' "$rc"
        return 3
    fi
    local confdir; confdir="$(printf '%s\n' "$capture" | sed -n 's/^confdir=//p' | head -1)"
    case "$confdir" in
        present) ;;
        unreadable) printf 'CANNOT-VERIFY: /etc/nginx/conf.d is unreadable over this transport.\n'; return 3 ;;
        absent)     printf 'CANNOT-VERIFY: /etc/nginx/conf.d does not exist on the host (unexpected).\n'; return 3 ;;
        *)          printf 'CANNOT-VERIFY: conf.d listing did not report its state.\n'; return 3 ;;
    esac

    local onbox tracked
    onbox="$(printf '%s\n' "$capture" | sed -n 's/^F//p')"
    tracked="$(cd "$tracked_dir" && for f in *.conf; do [ -e "$f" ] && basename "$f"; done)"

    nginx_parity_compare "$onbox" "$tracked"

    echo "  tracked baseline : $tracked_dir"
    echo "  in parity        : ${NP_MATCHED} conf file(s) present in both"
    local n
    if [ "${#NP_STRAY[@]}" -gt 0 ]; then
        echo ""
        echo "  STRAY on the box (NOT tracked — armed by the next nginx reload):"
        for n in $(printf '%s\n' "${NP_STRAY[@]}" | sort); do echo "    - /etc/nginx/conf.d/$n"; done
    fi
    if [ "${#NP_UNDEPLOYED[@]}" -gt 0 ]; then
        echo ""
        echo "  UNDEPLOYED (tracked but absent on the box):"
        for n in $(printf '%s\n' "${NP_UNDEPLOYED[@]}" | sort); do echo "    - $n"; done
    fi

    if [ "${#NP_STRAY[@]}" -gt 0 ] || [ "${#NP_UNDEPLOYED[@]}" -gt 0 ]; then
        echo ""
        echo "  A stray conf serves whatever it says the moment nginx reloads. Retire it"
        echo "  to a conf.d subdirectory (invisible to nginx) or track it; deploy an"
        echo "  undeployed one or remove it from the baseline. Then re-check."
        return 1
    fi
    return 0
}
