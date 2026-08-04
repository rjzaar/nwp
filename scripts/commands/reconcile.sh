#!/bin/bash
################################################################################
# reconcile.sh — `pl reconcile`: compare every known copy of state, daily.
#
# WHY THIS VERB EXISTS (operator-approved R1, 2026-08-04)
#   Every incident of 2026-08-01..04 was the SAME incident: two copies of state
#   that nothing reconciled. Oversight ran 15 days dark on a checkout 94 commits
#   behind a merged fix. Both 2026-08-03 live fixes were reverted overnight
#   because the box's golden was two days older than the repo's (ops#269). A
#   pair stayed RED for a week because its probes could not run. The registry
#   asserted an expiry for a deleted token. None of these were subtle — each was
#   checkable in one command that nobody was running on a schedule.
#
#   This verb is that schedule's body: one caller for probes that ALREADY exist,
#   one table, red lines named. It adds no new probe logic on purpose — a second
#   implementation is how resolvers drift (ops#267 grew three).
#
# HONESTY RULES (the estate's core lesson, enforced per check)
#   * CANNOT-VERIFY is a distinct outcome, never rendered as OK. "I could not
#     look" and "nothing is wrong" are opposite facts.
#   * Exit: 0 all OK · 1 at least one RED · 3 nothing red but ≥1 CANNOT-VERIFY.
#   * Each check is timeout-bounded: one wedged probe must not silence the rest.
#
# CHECKS
#   checkouts   every AGENT-CAPABLE host's ~/nwp + the ssd plugin cache, vs
#               origin/main. Hosts come from `pl host --list` (role labels), never
#               hardcoded — the gitleaks ruleset bans bare hostnames and it is right
#               to: a verb that embeds them cannot follow the fleet.
#               Agent hosts are RED on ANY drift — stale agent code is how
#               oversight went dark. The authoring host is INFO (the operator
#               works there; churn is normal) and REDdens only past 20.
#   goldens     box-staged golden sha256 vs local capture, per demo site — the
#               exact divergence that reverted ops#218/#228 overnight.
#   secrets     `pl secrets audit --offline` (location agreement, no probes).
#   schedule    oversight (rag-sync) scheduled on at least one host.
#   pair        `pl pair-smoke ssd --tier=live --run` — contract vs deployment.
#   plugindrift `pl moodle plugin drift` — copies vs canonical.
#   doctruth    `pl doc-truth` — docs vs code.
################################################################################
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=/dev/null
source "$PROJECT_ROOT/lib/common.sh" 2>/dev/null || true

RC_SSH="${NWP_RECONCILE_SSH:-ssh -o BatchMode=yes -o ConnectTimeout=10}"
declare -a ROWS=(); REDS=0; BLINDS=0
row() { # status name detail
    ROWS+=("$(printf '%-14s %-12s %s' "$1" "$2" "$3")")
    case "$1" in RED) REDS=$((REDS+1));; CANNOT-VERIFY) BLINDS=$((BLINDS+1));; esac
}

# -- checkouts ----------------------------------------------------------------
_rc_behind_local() { # dir
    git -C "$1" fetch -q origin 2>/dev/null || { echo "?"; return 1; }
    git -C "$1" rev-list --count HEAD..origin/main 2>/dev/null || echo "?"
}
check_checkouts() {
    local n
    n="$(timeout 60 bash -c "$(declare -f _rc_behind_local); _rc_behind_local '$PROJECT_ROOT'")" || n="?"
    if [ "$n" = "?" ]; then row CANNOT-VERIFY checkout-authoring "could not read local git state"
    elif [ "${n:-0}" -gt 20 ] 2>/dev/null; then row RED checkout-authoring "$n behind origin/main"
    else row OK checkout-authoring "$n behind (operator churn tolerated to 20)"; fi

    # Roles, resolved at run time. `pl host <role>` maps a role label to its
    # host; the ai-host and ci-host are the ones that RUN agents, so stale code
    # there is the oversight-went-dark failure. No bare hostname in this file.
    local role host
    for role in ai-host ci-host; do
        host="$("$PROJECT_ROOT/pl" host "$role" 2>/dev/null | tail -1 | tr -d ' ')"
        if [ -z "$host" ]; then row CANNOT-VERIFY "checkout-$role" "role unresolved in the instance manifest"; continue; fi
        n="$(timeout 60 $RC_SSH "$host" 'cd ~/nwp 2>/dev/null && git fetch -q origin 2>/dev/null; git -C ~/nwp rev-list --count HEAD..origin/main 2>/dev/null' 2>/dev/null | tail -1)"
        if ! [[ "$n" =~ ^[0-9]+$ ]]; then row CANNOT-VERIFY "checkout-$role" "unreachable or no checkout — NOT 'in sync'"
        elif [ "$n" -gt 0 ]; then row RED "checkout-$role" "$n behind origin/main — agents there run STALE code"
        else row OK "checkout-$role" "current"; fi
    done

    local cache="$PROJECT_ROOT/sites/ssd/.plugin-src/ss-moodle-plugins"
    if [ -d "$cache" ]; then
        n="$(timeout 60 bash -c "$(declare -f _rc_behind_local); _rc_behind_local '$cache'")" || n="?"
        if [ "$n" = "?" ]; then row CANNOT-VERIFY cache-ssd-plug "unreadable"
        elif [ "${n:-0}" -gt 0 ] 2>/dev/null; then row RED cache-ssd-plug "$n behind — a deploy from here ships OLD code (ops#229's cousin)"
        else row OK cache-ssd-plug "current"; fi
    else row CANNOT-VERIFY cache-ssd-plug "cache absent on this host"; fi
}

# -- goldens ------------------------------------------------------------------
check_goldens() {
    local site l b
    for site in nwd ssd; do
        l="$(cut -d' ' -f1 "$PROJECT_ROOT/sites/$site/demo-golden-live/golden.db.sql.gz.sha256" 2>/dev/null | head -1)"
        [ -n "$l" ] || { row CANNOT-VERIFY "golden-$site" "no local capture to compare"; continue; }
        # SSH target from the tracked server record, never a literal IP.
        local sshcmd
        sshcmd="$(get_server_ssh_command live 2>/dev/null)"
        [ -n "$sshcmd" ] || { row CANNOT-VERIFY "golden-$site" "cannot resolve the live host from servers/live/.nwp-server.yml"; continue; }
        # No pipe inside the remote command: the nested quoting for `cut -d' '`
        # broke it silently and the check regressed to CANNOT-VERIFY — i.e. the
        # single most important check in this verb went blind while looking
        # healthy. Split the field locally with awk instead.
        b="$(timeout 90 $sshcmd -o BatchMode=yes -o ConnectTimeout=10 "sudo -n sha256sum /var/lib/nwp-demo/$site/golden/golden.db.sql.gz" 2>/dev/null | awk 'NF{print $1}' | tail -1)"
        if ! [[ "$b" =~ ^[0-9a-f]{64}$ ]]; then row CANNOT-VERIFY "golden-$site" "box hash unreadable — staging state UNKNOWN"
        elif [ "$l" = "$b" ]; then row OK "golden-$site" "box == local (${l:0:12}…)"
        else row RED "golden-$site" "BOX HOLDS A DIFFERENT GOLDEN — tonight's reset restores the box copy, not yours (ops#269)"; fi
    done
}

# -- delegated verb checks ----------------------------------------------------
_verb() { # name timeout cmd... — OK on 0, RED otherwise, CANNOT-VERIFY on timeout/124
    local name="$1" to="$2"; shift 2
    local out rc=0
    out="$(timeout "$to" "$@" 2>&1)" || rc=$?
    if [ "$rc" -eq 124 ]; then row CANNOT-VERIFY "$name" "probe timed out after ${to}s"
    elif [ "$rc" -eq 0 ]; then row OK "$name" "clean"
    else row RED "$name" "exit $rc — $(printf '%s' "$out" | grep -m1 -oE '(ERROR|RED|FAIL)[^|]{0,70}' || echo 'see verb output')"; fi
}
check_schedule() {
    local total=0 n
    n=$(crontab -l 2>/dev/null | grep -c rag-sync); total=$((total+n))
    local ah; ah="$("$PROJECT_ROOT/pl" host ai-host 2>/dev/null | tail -1 | tr -d ' ')"
    if [ -n "$ah" ]; then
        n=$(timeout 40 $RC_SSH "$ah" 'crontab -l 2>/dev/null | grep -c rag-sync' 2>/dev/null | tail -1)
        [[ "$n" =~ ^[0-9]+$ ]] && total=$((total+n))
    fi
    if [ "$total" -ge 1 ]; then row OK oversight-cron "rag-sync scheduled on $total host(s)"
    else row RED oversight-cron "rag-sync scheduled NOWHERE — the fleet goes dark silently (15 days last time)"; fi
}

main() {
    local json=false; [ "${1:-}" = "--json" ] && json=true
    check_checkouts
    check_goldens
    _verb secrets-loc 120 "$PROJECT_ROOT/pl" secrets audit --offline --quiet
    check_schedule
    _verb pair-ssd 180 "$PROJECT_ROOT/pl" pair-smoke ssd --tier=live --run
    _verb plugin-drift 180 "$PROJECT_ROOT/pl" moodle plugin drift ssd
    _verb doc-truth 180 "$PROJECT_ROOT/pl" doc-truth

    echo "══════════ pl reconcile — $(date -u +%FT%TZ) ══════════"
    printf '%s\n' "${ROWS[@]}"
    echo "──────────────────────────────────────────────────────"
    echo "RED=$REDS  CANNOT-VERIFY=$BLINDS  (exit: 1 if red, 3 if only blind, 0 clean)"
    if [ "$REDS" -gt 0 ]; then return 1
    elif [ "$BLINDS" -gt 0 ]; then return 3
    else return 0; fi
}
main "$@"
