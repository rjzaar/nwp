#!/bin/bash
# lib/pl-freshness.sh — does `pl` know how old `pl` is?
#
# THE PROBLEM
#   /usr/local/bin/pl is a symlink into ONE shared checkout. That checkout is
#   the sole code path for every `pl secrets audit`, `pl rag`, `pl deploy-gate`
#   and every impact/fate manifest on the machine. `VERSION` in `pl` is a
#   hardcoded string, so a checkout forty commits behind origin/main and one
#   sitting exactly on it both answer "0.30.0". An operator reading a green
#   oversight surface therefore cannot tell which code produced it, and the
#   most common way to be wrong about a fleet is to be reading last month's
#   logic. This library makes `pl` say, in one line, when it is behind.
#
# THE FOUR CONSTRAINTS THAT SHAPE IT
#
#   1. NEVER TOUCH THE NETWORK.  `pl` is on the hot path of everything; a
#      freshness check that fetched would put a remote round trip (and a
#      hang, on a flaky link or an air-gapped deploy host) in front of every
#      single command. So it reads ONLY refs already on disk. That makes
#      the number it reports "commits behind as of the last fetch", NOT
#      "commits behind right now" — and the banner says exactly that, because
#      a banner that implies a fresh check when it did not do one is worse
#      than no banner. `pl version --check` is the one verb allowed to fetch,
#      and only because the operator asked it to.
#
#   2. NEVER NAG A PINNED CHECKOUT.  Detached HEAD, no upstream, or HEAD
#      sitting exactly on a tag are all deliberate states. A naive
#      `rev-list --count HEAD..@{u}` either errors or reports a meaningless
#      number in those cases, and an operator who is nagged for a choice they
#      made on purpose learns to ignore the banner — which costs more than
#      never having shipped it.
#
#   3. FAIL OPEN, ALWAYS.  A freshness check must never be the reason an
#      emergency `pl rollback` does not run. Every failure path here is
#      swallowed: no git, corrupt repo, unwritable cache, weird locale — all
#      produce silence and exit status 0. The whole body runs in a subshell
#      with `set +e` so it cannot trip `pl`'s own `set -euo pipefail`.
#
#   4. WRITE NOTHING INTO THE CHECKOUT.  The verdict cache lives under
#      ${XDG_CACHE_HOME:-$HOME/.cache}/nwp/, keyed by checkout path. A cache
#      file inside the repo would dirty `git status`, and this repo's leakage
#      and containment gates treat unexpected files in the tree as findings.
#
# OUTPUT CONTRACT
#   At most ONE line, on STDERR, ever. stdout is untouched so that anything
#   parsing `pl version` (or any other verb) is unaffected. Exit status is
#   never changed. `NWP_NO_FRESHNESS_CHECK=1` silences it; NO_COLOR and a
#   non-tty stderr drop the colour but NOT the message — the banner is at
#   least as useful in a log file as on a terminal.

# TTL for the cached verdict. Bounded above by "how long am I willing to keep
# telling you a stale number" and below by "how often am I willing to walk the
# revision graph". The cache is ALSO keyed on HEAD, so it is invalidated the
# instant the checkout moves, TTL or no TTL — the TTL only covers the case
# where HEAD stands still but a fetch brought new upstream commits in.
: "${NWP_FRESHNESS_TTL:=1800}"
NWP_FRESHNESS_CACHE_SCHEMA="1"

# _pl_freshness_cache_file <checkout-dir> -> path (stdout)
_pl_freshness_cache_file() {
    local dir="$1"
    local base="${XDG_CACHE_HOME:-$HOME/.cache}/nwp"
    # Key on the checkout path, flattened. Two checkouts of the same repo (a
    # worktree, a second clone) are different subjects and must not share a
    # verdict.
    local key="${dir//\//%}"
    printf '%s/freshness%s.v%s' "$base" "$key" "$NWP_FRESHNESS_CACHE_SCHEMA"
}

# _pl_freshness_mtime <file> -> epoch seconds (stdout), 0 if unknown
_pl_freshness_mtime() {
    local f="$1" v=""
    [ -e "$f" ] || { printf '0'; return 0; }
    v="$(stat -c %Y "$f" 2>/dev/null)" || v=""
    [ -n "$v" ] || v="$(stat -f %m "$f" 2>/dev/null)" || v=""   # BSD/macOS
    printf '%s' "${v:-0}"
}

# _pl_freshness_when <epoch> -> human string (stdout)
_pl_freshness_when() {
    local e="$1"
    if [ -z "$e" ] || [ "$e" = "0" ]; then
        printf 'an unknown time'
        return 0
    fi
    date -d "@$e" '+%Y-%m-%d %H:%M' 2>/dev/null \
        || date -r "$e" '+%Y-%m-%d %H:%M' 2>/dev/null \
        || printf 'an unknown time'
}

# _pl_freshness_compute <checkout-dir>
#   Prints one cache record to stdout:  <head-sha>|<count>|<upstream>|<fetch-epoch>
#   A count of 0 means "say nothing" and covers BOTH "up to date" and every
#   pinned/undeterminable state, deliberately: the caller does not need to
#   know why it should stay quiet, only that it should.
#   Returns non-zero and prints nothing if even the HEAD sha is unavailable.
_pl_freshness_compute() {
    local dir="$1" head branch upstream count gitdir fetch_epoch=0

    head="$(git -C "$dir" rev-parse HEAD 2>/dev/null)" || return 1
    [ -n "$head" ] || return 1

    # Pinned case 1: detached HEAD.
    branch="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)" || branch=""
    if [ -z "$branch" ] || [ "$branch" = "HEAD" ]; then
        printf '%s|0||0' "$head"; return 0
    fi

    # Pinned case 2: HEAD is exactly a tag. Someone checked out a release.
    if git -C "$dir" describe --exact-match --tags HEAD >/dev/null 2>&1; then
        printf '%s|0||0' "$head"; return 0
    fi

    # Pinned case 3: no upstream configured — nothing to be behind.
    upstream="$(git -C "$dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)" || upstream=""
    if [ -z "$upstream" ]; then
        printf '%s|0||0' "$head"; return 0
    fi

    # The only network-free question worth asking: how far is HEAD behind the
    # remote-tracking ref we already have on disk?
    count="$(git -C "$dir" rev-list --count "HEAD..$upstream" 2>/dev/null)" || count=""
    case "$count" in
        ''|*[!0-9]*) printf '%s|0||0' "$head"; return 0 ;;
    esac

    # When was that remote-tracking ref last refreshed? Four candidates, in
    # descending order of directness. This is best-effort by design: if none of
    # them exists the banner says "as of an unknown time", which is the honest
    # answer and still better than implying the check was live.
    #   * FETCH_HEAD in the per-worktree git dir — written by every fetch/pull;
    #   * FETCH_HEAD in the COMMON dir — `pl` runs from linked worktrees here,
    #     and a fetch done in the main checkout lands there, not in ours;
    #   * the loose remote-tracking ref file;
    #   * packed-refs — after `git gc` the loose ref above is gone.
    local commondir
    gitdir="$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null)" || gitdir=""
    commondir="$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || commondir=""
    local cand
    for cand in "$gitdir/FETCH_HEAD" "$commondir/FETCH_HEAD" \
                "$commondir/refs/remotes/$upstream" "$commondir/packed-refs"; do
        case "$cand" in /FETCH_HEAD|/refs/*|/packed-refs) continue ;; esac
        [ "$fetch_epoch" = "0" ] || break
        fetch_epoch="$(_pl_freshness_mtime "$cand")"
    done

    printf '%s|%s|%s|%s' "$head" "$count" "$upstream" "$fetch_epoch"
}

# _pl_freshness_emit <count> <upstream> <fetch-epoch> <checkout-dir>
_pl_freshness_emit() {
    local count="$1" upstream="$2" fetch_epoch="$3" dir="$4"
    [ "${count:-0}" -gt 0 ] 2>/dev/null || return 0

    local noun="commits"
    [ "$count" = "1" ] && noun="commit"

    local c0="" c1=""
    if [ -z "${NO_COLOR:-}" ] && [ -t 2 ]; then
        c0=$'\033[1;33m'; c1=$'\033[0m'
    fi

    # "as of <time>" is load-bearing: it is the honest qualifier that stops the
    # line reading as though pl just asked the remote. It did not.
    printf '%spl: this checkout (%s) is %s %s behind %s as of %s (last local fetch; not re-checked — `pl version --check` fetches)%s\n' \
        "$c0" "$dir" "$count" "$noun" "$upstream" "$(_pl_freshness_when "$fetch_epoch")" "$c1" >&2
}

# _pl_freshness_run <checkout-dir>  — the whole check; assumes set +e.
_pl_freshness_run() {
    local dir="$1"
    [ -n "$dir" ] && [ -d "$dir" ] || return 0
    command -v git >/dev/null 2>&1 || return 0

    local cache now head record
    cache="$(_pl_freshness_cache_file "$dir")"
    now="$(date +%s 2>/dev/null)"
    [ -n "$now" ] || return 0

    head="$(git -C "$dir" rev-parse HEAD 2>/dev/null)"
    [ -n "$head" ] || return 0   # not a repo / broken repo → silence

    # Warm path: one cheap rev-parse above, and NO revision-graph walk.
    if [ -f "$cache" ]; then
        local c_expires c_head c_count c_up c_fetch
        IFS='|' read -r c_expires c_head c_count c_up c_fetch < "$cache" 2>/dev/null
        if [ -n "$c_expires" ] && [ "$c_head" = "$head" ] \
           && [ "$c_expires" -gt "$now" ] 2>/dev/null; then
            _pl_freshness_emit "$c_count" "$c_up" "$c_fetch" "$dir"
            return 0
        fi
    fi

    record="$(_pl_freshness_compute "$dir")" || return 0
    [ -n "$record" ] || return 0

    local r_head r_count r_up r_fetch
    IFS='|' read -r r_head r_count r_up r_fetch <<< "$record"

    # Best-effort cache write. An unwritable cache costs a rev-list per call,
    # never a failure.
    local cdir tmp
    cdir="$(dirname "$cache")"
    if mkdir -p "$cdir" 2>/dev/null; then
        tmp="$cache.$$"
        if printf '%s|%s\n' "$((now + NWP_FRESHNESS_TTL))" "$record" > "$tmp" 2>/dev/null; then
            mv -f "$tmp" "$cache" 2>/dev/null || rm -f "$tmp" 2>/dev/null
        else
            rm -f "$tmp" 2>/dev/null
        fi
    fi

    _pl_freshness_emit "$r_count" "$r_up" "$r_fetch" "$dir"
    return 0
}

# pl_freshness_banner <checkout-dir>
#   The only entry point `pl` calls. Safe under `set -euo pipefail`, safe on a
#   broken repo, safe with no git, safe with no writable HOME.
pl_freshness_banner() {
    local dir="${1:-}"

    # Explicit opt-out, and re-entrancy: a `pl` that shells out to `pl` should
    # not repeat itself. The export happens whatever the verdict.
    if [ -n "${NWP_NO_FRESHNESS_CHECK:-}" ] || [ -n "${NWP_FRESHNESS_SHOWN:-}" ]; then
        export NWP_FRESHNESS_SHOWN=1
        return 0
    fi
    export NWP_FRESHNESS_SHOWN=1

    ( set +e +u +o pipefail; _pl_freshness_run "$dir" ) || true
    return 0
}

# pl_freshness_check <checkout-dir>
#   `pl version --check`. The ONE path allowed to talk to the remote, because
#   the operator typed --check. Still fails open; still never changes exit
#   status of the caller. Reports on stdout (it is the requested output here,
#   not an aside).
pl_freshness_check() {
    local dir="${1:-}"
    (
        set +e +u +o pipefail
        [ -n "$dir" ] && [ -d "$dir" ] || { echo "freshness: no checkout to check"; exit 0; }
        if ! command -v git >/dev/null 2>&1; then
            echo "freshness: git is not installed; cannot check"
            exit 0
        fi

        local upstream remote to
        upstream="$(git -C "$dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"
        if [ -z "$upstream" ]; then
            echo "freshness: this checkout has no upstream (detached or pinned) — nothing to compare"
            exit 0
        fi
        remote="${upstream%%/*}"

        # Bounded: a hung remote must not hang `pl version`.
        to=""
        command -v timeout >/dev/null 2>&1 && to="timeout 30"
        if ! $to git -C "$dir" fetch --quiet "$remote" >/dev/null 2>&1; then
            echo "freshness: fetch from '$remote' failed (offline?) — reporting last known state"
        fi

        # Invalidate the cached verdict so the next ordinary `pl` agrees.
        rm -f "$(_pl_freshness_cache_file "$dir")" 2>/dev/null

        local record r_head r_count r_up r_fetch noun
        record="$(_pl_freshness_compute "$dir")"
        if [ -z "$record" ]; then
            echo "freshness: could not read this checkout's git state"
            exit 0
        fi
        IFS='|' read -r r_head r_count r_up r_fetch <<< "$record"
        if [ "${r_count:-0}" -eq 0 ] 2>/dev/null; then
            echo "freshness: up to date with ${r_up:-upstream} (checked just now)"
        else
            noun="commits"; [ "$r_count" = "1" ] && noun="commit"
            echo "freshness: $r_count $noun behind $r_up (checked just now) — \`git -C $dir pull\` to update"
        fi
        exit 0
    ) || true
    return 0
}
