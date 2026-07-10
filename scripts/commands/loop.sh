#!/bin/bash
#
# pl loop — one-screen status of the self-healing loop (ops#57).
#
# The loop's state is spread across a kill-switch file, cron, two logs, a daily
# ledger, and the RAG state. This gathers them into one read-only dashboard so
# you can see, at a glance, whether the loop is armed, what it last did, and
# whether it's near its daily cap.
#
# Reports on the RUNTIME tree ($HOME/nwp, override with NWP_ROOT) — the loop runs
# from there, not from a worktree — so it's accurate wherever you invoke it.
#
# The loop is built from independent PARTS. Each can be enabled/disabled on its
# own with a WRAPPER-ENFORCED switch (lib/loop-parts.sh, deep-audit C0): the
# cron/entrypoint wrappers consult the state BEFORE running any agent logic.
#
# Usage:
#   pl loop                       show the dashboard (alias: pl loop status)
#   pl loop enable  <part|all>    arm a part (or clear the global kill with `all`)
#   pl loop disable <part|all>    disable a part (or `all` = global kill-switch)
#   pl loop parts                 list the parts and their current state
#   pl loop -h|--help
#
# Parts: fix-loop · respawn-drain · rag-sync · webhook  (and `all` = global kill)
#
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
source "$PROJECT_ROOT/lib/ui.sh"

RT="${NWP_ROOT:-$HOME/nwp}"                       # runtime tree the loop actually uses
export NWP_ROOT="$RT"                             # loop-parts.sh reads sentinels relative to this
source "$PROJECT_ROOT/lib/loop-parts.sh"
KILL="$RT/.loop-paused"
RAG_PAUSE="$RT/.rag-sync-paused"
STATE_FILE="$RT/.agent-loop.state.json"
LOG="$RT/logs/agent-loop.log"
RAG_LOG="$RT/logs/rag-sync.log"
RAG_STATE="$RT/private/rag/state.json"
ENV_FILE="$HOME/.nwp-agent-loop.env"
DAILY_CAP="${AGENT_LOOP_DAILY_CAP:-5}"
YQ="$(command -v yq || echo "$HOME/.local/bin/yq")"

dot(){ case "$1" in RED) printf '🔴';; AMBER) printf '🟠';; GREEN) printf '🟢';; on) printf '🟢';; off) printf '🔴';; *) printf '⚪';; esac; }

# pl loop enable|disable <part|all>
cmd_toggle(){
    local action="$1" part="${2:-}" val
    if [ -z "$part" ]; then
        print_error "usage: pl loop $action <part|all>"
        printf '  parts: %s   (or "all" = global kill-switch)\n' "${LOOP_PARTS[*]}" >&2
        return 2
    fi
    if ! loop_part_is_known "$part"; then
        print_error "unknown part: $part"
        printf '  known: %s all\n' "${LOOP_PARTS[*]}" >&2
        return 2
    fi
    if [ "$action" = "enable" ]; then val=enabled; else val=disabled; fi
    if loop_part_set "$part" "$val"; then
        if [ "$part" = "all" ]; then
            print_success "loop GLOBAL kill-switch -> $val (every part)"
            [ "$val" = "enabled" ] && print_info "individual parts keep their own state; check: pl loop parts"
        else
            print_success "loop part '$part' -> $val"
        fi
        print_info "state file: $(loop_parts_state_file)"
    else
        print_error "failed to write loop state"
        return 1
    fi
}

# pl loop parts — one line per part, plus the global kill.
cmd_parts(){
    print_header "Self-healing loop — parts"
    if loop_global_killed; then
        printf '  %s  GLOBAL KILL active — every part is disabled right now\n' "$(dot off)"
        [ -f "$RT/.loop-paused" ]                 && printf '        · legacy sentinel .loop-paused present\n'
        [ "$(loop_part_raw all)" = "disabled" ]   && printf '        · parts.state: all=disabled\n'
        echo
    fi
    local p st d
    for p in "${LOOP_PARTS[@]}"; do
        st="$(loop_part_state_word "$p")"; d=on; [ "$st" = disabled ] && d=off
        printf '  %s  %-14s %-9s %s\n' "$(dot $d)" "$p" "$st" "$(loop_part_desc "$p")"
    done
    echo
    print_info "toggle: pl loop enable|disable <part|all>   ·   state: $(loop_parts_state_file)"
}

case "${1:-status}" in
    -h|--help) sed -n '3,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    status|"") ;;
    enable|disable) cmd_toggle "$@"; exit $? ;;
    parts) cmd_parts; exit $? ;;
    *) print_error "unknown arg: $1"; exit 2 ;;
esac

print_header "Self-healing loop — status"

# ── Parts (wrapper-enforced enable/disable — deep-audit C0) ───────────────────
if loop_global_killed; then
    printf '  %s  GLOBAL KILL active — every part disabled' "$(dot off)"
    [ -f "$RT/.loop-paused" ]               && printf '  (.loop-paused, since %s)' "$(date -r "$RT/.loop-paused" +%Y-%m-%d 2>/dev/null || echo '?')"
    [ "$(loop_part_raw all)" = "disabled" ] && printf '  (all=disabled)'
    printf '\n'
fi
printf '  parts:      '
_first=1
for _p in "${LOOP_PARTS[@]}"; do
    _st="$(loop_part_state_word "$_p")"; _d=on; [ "$_st" = disabled ] && _d=off
    [ "$_first" = 1 ] || printf '              '
    printf '%s %-14s %s\n' "$(dot $_d)" "$_p" "$_st"
    _first=0
done
printf '              (toggle: pl loop enable|disable <part|all> · detail: pl loop parts)\n'
echo

# ── Fix loop (issue → MR) ────────────────────────────────────────────────────
if loop_part_enabled fix-loop; then
    printf '  %s  fix loop:   ARMED   (part enabled — acts on agent-eligible issues)\n' "$(dot on)"
else
    printf '  %s  fix loop:   DISABLED (pl loop enable fix-loop to arm)\n' "$(dot off)"
fi

# cron armed?
cron_loop="$(crontab -l 2>/dev/null | grep -cE '^[0-9*].*agent-loop\.sh' || true)"
cron_rag="$(crontab -l 2>/dev/null  | grep -cE '^[0-9*].*rag-sync\.sh'   || true)"
sched="$(crontab -l 2>/dev/null | grep -E '^[0-9*].*agent-loop\.sh' | grep -oE '^[^ ]+ [^ ]+ [^ ]+ [^ ]+ [^ ]+' | head -1)"
if [ "${cron_loop:-0}" -gt 0 ]; then printf '  %s  cron:       armed   (%s)\n' "$(dot on)" "${sched:-schedule}"
else printf '  %s  cron:       ABSENT  (loop will not wake — see scripts/agent-loop/crontab.entry)\n' "$(dot off)"; fi

# token env
if [ -f "$ENV_FILE" ]; then printf '  %s  token env:  present  (%s)\n' "$(dot on)" "${ENV_FILE/#$HOME/~}"
else printf '  %s  token env:  MISSING  (%s — loop cannot auth)\n' "$(dot off)" "${ENV_FILE/#$HOME/~}"; fi

# daily MR count vs cap
today="$(date -u +%Y-%m-%d)"; used=0
[ -f "$STATE_FILE" ] && used="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("daily",{}).get(sys.argv[2],0))' "$STATE_FILE" "$today" 2>/dev/null || echo 0)"
last_run="$( [ -f "$STATE_FILE" ] && python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("last_run") or "never")' "$STATE_FILE" 2>/dev/null || echo '?')"
capdot=on; [ "${used:-0}" -ge "$DAILY_CAP" ] && capdot=off
printf '  %s  MRs today:  %s / %s   (last run: %s)\n' "$(dot $capdot)" "${used:-0}" "$DAILY_CAP" "$last_run"

# last log line
if [ -f "$LOG" ]; then printf '     last log:   %s\n' "$(tail -1 "$LOG" 2>/dev/null | cut -c1-90)"; fi

echo
# ── RAG → issue sync (stage 1) ───────────────────────────────────────────────
if ! loop_part_enabled rag-sync; then
    printf '  %s  rag-sync:   DISABLED' "$(dot off)"
    [ -f "$RAG_PAUSE" ] && printf '  (.rag-sync-paused present)'
    printf '\n'
elif [ "${cron_rag:-0}" -gt 0 ]; then printf '  %s  rag-sync:   armed   (daily; stage 1 of the loop)\n' "$(dot on)"
else printf '  %s  rag-sync:   part enabled but no cron\n' "$(dot off)"; fi
[ -f "$RAG_LOG" ] && printf '     last run:   %s\n' "$(grep 'rag-sync done' "$RAG_LOG" 2>/dev/null | tail -1 | cut -c1-70)"

echo
# ── Fleet RAG (what the loop grades) ─────────────────────────────────────────
if [ -f "$RAG_STATE" ]; then
    read -r r a g gen < <(python3 -c '
import json,sys
d=json.load(open(sys.argv[1])); s=d.get("summary",{})
g=lambda *k:next((s[x] for x in k if x in s),0)
print(g("RED","red"), g("AMBER","amber"), g("GREEN","green"), d.get("generated","?"))' "$RAG_STATE" 2>/dev/null || echo "? ? ? ?")
    printf '  fleet RAG:   %s %s red   %s %s amber   %s %s green    (generated %s)\n' "$(dot RED)" "$r" "$(dot AMBER)" "$a" "$(dot GREEN)" "$g" "$gen"
else
    printf '  fleet RAG:   (no state — run `pl rag`)\n'
fi

# ── Queue (best-effort; needs the ops read token + network) ──────────────────
# prefer the loop's own token (exact visibility the loop has), else the ops read token
tok=""
[ -f "$ENV_FILE" ] && tok="$( { grep -E '^GITLAB_TOKEN=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d "\"' "; } || true)"
[ -n "$tok" ] || tok="$("$YQ" -r '.gitlab.ops_note_token // .gitlab.api_token' "$RT/.secrets.yml" 2>/dev/null || true)"
host="$(git -C "$RT" remote get-url origin 2>/dev/null | sed -E 's#git@([^:]+):.*#\1#')"
if [ -n "${tok:-}" ] && [ "$tok" != "null" ] && [ -n "${host:-}" ]; then
    set +e
    # count only when the API returns a JSON *list* (an error object must not count as 1)
    count_list(){ python3 -c 'import json,sys
try: d=json.load(sys.stdin); print(len(d) if isinstance(d,list) else 0)
except Exception: print(0)'; }
    elig=0
    for pid in 16 21; do
        n=$(curl -s --max-time 6 --header "PRIVATE-TOKEN: $tok" "https://$host/api/v4/projects/$pid/issues?labels=agent-eligible&state=opened&per_page=100" 2>/dev/null | count_list)
        elig=$((elig + ${n:-0}))
    done
    auto=$(curl -s --max-time 6 --header "PRIVATE-TOKEN: $tok" "https://$host/api/v4/projects/21/issues?labels=rag-auto&state=opened&per_page=100" 2>/dev/null | count_list)
    set -e
    edot=on; [ "${elig:-0}" -eq 0 ] && edot='*'
    printf '  queue:       %s agent-eligible (loop acts on these)   ·   %s open rag-auto issues\n' "${elig:-?}" "${auto:-?}"
    [ "${elig:-0}" -eq 0 ] && printf '               (loop is idle until you label an issue `agent-eligible`)\n'
else
    printf '  queue:       (offline — could not read the ops token)\n'
fi

echo
print_info "detail: pl rag · logs/agent-loop.log · logs/rag-sync.log · guide: docs/handover-ops6-self-healing-loop.md"
