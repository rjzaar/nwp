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
#   pl loop --host <role>         read the loop state on ANOTHER machine, over
#                                 ssh, and say which machine it read
#   pl loop enable  <part|all>    arm a part (or clear the WRITE kill with `all`)
#   pl loop disable <part|all>    disable a part (or `all` = WRITE kill-switch)
#   pl loop disable oversight     stop the READ-ONLY half too (separate on purpose)
#   pl loop parts                 list the parts and their current state
#   pl loop schedule [status]     is anything going to wake the loop on this host?
#   pl loop schedule install|remove [--execute] [--host <role>]
#                                 own the rag-sync cron BY CODE, idempotently
#   pl loop -h|--help
#
# Parts: fix-loop · respawn-drain · rag-sync · webhook
#   `all`       = WRITE kill-switch (every part that can change the estate)
#   `oversight` = OVERSIGHT kill-switch (the read-only parts; ops#230)
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
            print_success "loop WRITE kill-switch -> $val (every part that can change the estate)"
            # Saying this out loud every time is the point of ops#230: the
            # operator must know exactly what they did and did not switch off.
            print_info "read-only OVERSIGHT (rag-sync) is NOT affected and keeps running — by design."
            print_info "to stop oversight too (rarely right): pl loop disable oversight"
            [ "$val" = "enabled" ] && print_info "individual parts keep their own state; check: pl loop parts"
        elif [ "$part" = "oversight" ]; then
            print_success "loop OVERSIGHT kill-switch -> $val (every read-only part)"
            [ "$val" = "disabled" ] && print_warning "the fleet's RAG grade will stop reaching nwp/ops. pl todo will file an RSY item and pl rag will grade (global) RED until you re-enable it — that is deliberate."
        else
            print_success "loop part '$part' -> $val"
        fi
        print_info "state file: $(loop_parts_state_file)"
    else
        print_error "failed to write loop state"
        return 1
    fi
}

# pl loop parts — one line per part, plus both kills.
cmd_parts(){
    print_header "Self-healing loop — parts"
    if loop_write_killed; then
        printf '  %s  WRITE KILL active — every part that can CHANGE the estate is disabled\n' "$(dot off)"
        [ -f "$RT/.loop-paused" ]                 && printf '        · legacy sentinel .loop-paused present\n'
        [ "$(loop_part_raw all)" = "disabled" ]   && printf '        · parts.state: all=disabled\n'
        if loop_gates_unified; then
            printf '        %s NWP_LOOP_UNIFIED_GATES=1 — this ALSO blinds read-only oversight (pre-ops#230 behaviour)\n' "$(dot off)"
        else
            printf '        · read-only oversight is NOT affected (ops#230: capability-keyed gates)\n'
        fi
        echo
    fi
    if loop_oversight_killed; then
        printf '  %s  OVERSIGHT KILL active — the read-only half is off: %s\n' "$(dot off)" "$(loop_oversight_kill_reason)"
        printf '        · the fleet RAG grade is not reaching nwp/ops. Re-arm: pl loop enable oversight\n'
        echo
    fi
    local p st d cap
    for p in "${LOOP_PARTS[@]}"; do
        st="$(loop_part_state_word "$p")"; d=on; [ "$st" = disabled ] && d=off
        cap="$(loop_part_capability "$p")"
        printf '  %s  %-14s %-9s %-8s %s\n' "$(dot $d)" "$p" "$st" "[$cap]" "$(loop_part_desc "$p")"
    done
    echo
    printf '  capability decides WHICH kill applies: [write] parts answer to `all` (.loop-paused),\n'
    printf '  [observe] parts answer to `oversight` (.oversight-paused). They are separate switches\n'
    printf '  because a kill for "do not let agents write" must never mean "stop looking" (ops#230).\n'
    echo
    print_info "toggle: pl loop enable|disable <part|all|oversight>   ·   state: $(loop_parts_state_file)"
}

################################################################################
# pl loop schedule — own the rag-sync cron BY CODE (ops#230 item 2).
#
# On 2026-08-02 `crontab -l` on this host was EMPTY and `pl loop` said
# `cron: ABSENT`. Lifting the pause would have restarted nothing. The estate has
# been here before (ops#171, ops#156): a schedule that was installed by hand,
# from a runbook, is a schedule that nobody can reinstall, verify or move — so
# when it disappears it disappears silently and stays gone.
#
# This verb is the code that owns it. The entry is written as a MANAGED BLOCK
# delimited by markers, so re-installing rewrites rather than duplicates, and
# removing takes out exactly what was put in. Dry-run by default; the crontab is
# backed up before any write.
#
# --host <role> delegates to `pl host schedule`, which prints the declared
# remote entry (its --execute is not enabled in this release, deliberately).
################################################################################
SCHED_BEGIN="# >>> nwp loop schedule (managed by \`pl loop schedule\`) >>>"
SCHED_END="# <<< nwp loop schedule <<<"
SCHED_DEFAULT="30 4 * * *"

_sched_line(){
    printf '%s %s/scripts/agent-loop/rag-sync.sh >> %s/logs/rag-sync.log 2>&1\n' \
        "${1:-$SCHED_DEFAULT}" "$RT" "$RT"
}

_sched_block(){
    printf '%s\n' "$SCHED_BEGIN"
    printf '# Stage 1 of the self-healing loop: turn the live RAG state into tracked\n'
    printf '# nwp/ops issues. READ-ONLY (files issues; no bumps, no deploys), which is\n'
    printf '# why the WRITE kill does not stop it — see ops#230 and lib/loop-parts.sh.\n'
    printf '# Managed by: pl loop schedule install|remove. Do not hand-edit this block.\n'
    printf 'SHELL=/bin/bash\n'
    printf 'PATH=%s/.local/bin:/usr/local/bin:/usr/bin:/bin\n' "$HOME"
    _sched_line "$1"
    printf '%s\n' "$SCHED_END"
}

cmd_schedule_status(){
    print_header "Loop schedule — host: $(hostname -s 2>/dev/null || hostname)"
    local cron_all managed other
    cron_all="$(crontab -l 2>/dev/null || true)"
    managed="$(printf '%s\n' "$cron_all" | awk -v b="$SCHED_BEGIN" -v e="$SCHED_END" '$0==b{f=1} f{print} $0==e{f=0}')"
    other="$(printf '%s\n' "$cron_all" | grep -E '^[[:space:]]*[0-9*].*rag-sync\.sh' || true)"

    if [ -n "$managed" ]; then
        printf '  %s  managed block: PRESENT\n' "$(dot on)"
        printf '%s\n' "$managed" | sed 's/^/        /'
    else
        printf '  %s  managed block: ABSENT — `pl loop schedule` does not own a schedule here\n' "$(dot off)"
    fi
    if [ -n "$other" ]; then
        printf '\n  rag-sync cron lines seen on this host:\n'
        printf '%s\n' "$other" | sed 's/^/        /'
    fi
    echo
    # The freshness verdict, from the SAME probe pl todo and pl rag use.
    if [ -f "$PROJECT_ROOT/lib/oversight-freshness.sh" ]; then
        # shellcheck source=/dev/null
        source "$PROJECT_ROOT/lib/oversight-freshness.sh"
        NWP_ROOT="$RT" oversight_probe
        printf '  %s  oversight: %s — %s\n' "$(dot "$OVERSIGHT_GRADE")" "$OVERSIGHT_STATE" "$OVERSIGHT_DETAIL"
        [ "$OVERSIGHT_GRADE" = GREEN ] || printf '     fix: %s\n' "$OVERSIGHT_ACTION"
    fi
    echo
    print_info "install: pl loop schedule install [--schedule=\"$SCHED_DEFAULT\"] --execute"
    print_info "elsewhere: pl loop schedule install --host <role>   ·   read: pl loop --host <role>"
    [ -n "$managed" ] && return 0 || return 1
}

cmd_schedule_write(){
    local action="$1"; shift
    local execute=0 expr="$SCHED_DEFAULT" target="" a
    while [ $# -gt 0 ]; do
        case "$1" in
            --execute)    execute=1; shift ;;
            --schedule=*) expr="${1#--schedule=}"; shift ;;
            --host)       target="${2:-}"; shift 2 ;;
            --host=*)     target="${1#--host=}"; shift ;;
            *) print_error "unknown arg: $1"; return 2 ;;
        esac
    done

    if [ -n "$target" ]; then
        # Cross-host stays in the one place that owns remote cron.
        print_info "delegating to: pl host schedule $target $action --name=rag-sync …"
        if [ "$action" = "install" ]; then
            exec "$PROJECT_ROOT/scripts/commands/host.sh" schedule "$target" install \
                --name=rag-sync --schedule="$expr" \
                --command="\$HOME/nwp/scripts/agent-loop/rag-sync.sh" \
                $([ "$execute" = 1 ] && echo --execute)
        else
            exec "$PROJECT_ROOT/scripts/commands/host.sh" schedule "$target" remove \
                --name=rag-sync $([ "$execute" = 1 ] && echo --execute)
        fi
    fi

    command -v crontab >/dev/null 2>&1 || { print_error "no crontab binary on this host"; return 1; }

    local cur new
    cur="$(crontab -l 2>/dev/null || true)"
    # Strip any existing managed block, then (for install) append a fresh one.
    new="$(printf '%s\n' "$cur" | awk -v b="$SCHED_BEGIN" -v e="$SCHED_END" '$0==b{f=1} !f{print} $0==e{f=0}')"
    if [ "$action" = "install" ]; then
        new="$(printf '%s\n%s\n' "${new%$'\n'}" "$(_sched_block "$expr")")"
    fi
    # Never leave a stray leading blank line behind on an empty crontab.
    new="$(printf '%s\n' "$new" | sed '/./,$!d')"

    print_header "Loop schedule — $action on $(hostname -s 2>/dev/null || hostname)"
    printf '  resulting crontab:\n'
    printf '%s\n' "$new" | sed 's/^/        /'
    echo
    if [ "$execute" -ne 1 ]; then
        print_warning "DRY RUN — nothing was written. Re-run with --execute."
        return 0
    fi

    # Back up before touching it. `crontab -r` mistakes are unrecoverable.
    local bak_dir="$RT/private/rollback/ops230"
    mkdir -p "$bak_dir"
    local bak="$bak_dir/crontab.$(date -u +%Y%m%dT%H%M%SZ).bak"
    printf '%s\n' "$cur" > "$bak"
    printf '%s\n' "$new" | crontab - || { print_error "crontab write failed — prior crontab saved at $bak"; return 1; }
    print_success "crontab updated (previous copy: $bak)"
    cmd_schedule_status || true
}

cmd_schedule(){
    # A `--host` anywhere means "not this machine". Reading a remote schedule is
    # `pl host schedule <target> list`; there is exactly one implementation of
    # remote cron and this is not it.
    local _a _t=""
    for _a in "$@"; do case "$_a" in --host=*) _t="${_a#--host=}" ;; esac; done
    if [ -z "$_t" ]; then
        local _prev=""
        for _a in "$@"; do [ "$_prev" = "--host" ] && { _t="$_a"; break; }; _prev="$_a"; done
    fi
    if [ -n "$_t" ] && { [ "${1:-status}" = status ] || [ -z "${1:-}" ]; }; then
        exec "$PROJECT_ROOT/scripts/commands/host.sh" schedule "$_t" list
    fi
    case "${1:-status}" in
        ""|status) cmd_schedule_status ;;
        install|remove) local a="$1"; shift; cmd_schedule_write "$a" "$@" ;;
        -h|--help)
            printf 'pl loop schedule [status]\n'
            printf 'pl loop schedule install [--schedule="%s"] [--host <role>] [--execute]\n' "$SCHED_DEFAULT"
            printf 'pl loop schedule remove  [--host <role>] [--execute]\n' ;;
        *) print_error "unknown: pl loop schedule $1 (status|install|remove)"; return 2 ;;
    esac
}

################################################################################
# --host <role|server|hostname> — interrogate the loop on ANOTHER machine.
#
# THE BUG THIS FIXES (fix-programme item 6): this dashboard read $HOME/nwp on
# whatever machine you typed it on, with no ssh anywhere in the file — while the
# loop is split across two hosts (fix-loop cron on the build-host, webhook unit
# on the ai-host) with three divergent .loop-paused sentinels. `pl loop enable
# all` typed on the authoring host cleared the AUTHORING host's sentinel,
# printed all-green, and armed nothing. The ai-host's loop had been dark since
# 2026-07-18 and no `pl` surface could see it.
#
# So: every rendering now NAMES the machine it interrogated, and the write verbs
# refuse to run against a machine that is not this one.
################################################################################
LOOP_TARGET=""
if [ "${1:-}" = "--host" ]; then
    LOOP_TARGET="${2:-}"
    [ -n "$LOOP_TARGET" ] || { print_error "usage: pl loop --host <role|server|hostname> [status]"; exit 2; }
    shift 2
    # shellcheck source=/dev/null
    source "$PROJECT_ROOT/lib/server-resolver.sh"
    # shellcheck source=/dev/null
    source "$PROJECT_ROOT/lib/host-capture.sh"
fi

_loop_remote_probe() {
    cat <<'PROBE'
set -u
printf 'NWPLOOP v1\n'
R="${NWP_ROOT:-$HOME/nwp}"
printf 'root=%s\n' "$R"
if [ -f "$R/.loop-paused" ]; then printf 'kill=present\nkill_mtime=%s\n' "$(stat -c %Y "$R/.loop-paused" 2>/dev/null || echo 0)"
else printf 'kill=absent\n'; fi
if [ -f "$R/.rag-sync-paused" ]; then printf 'rag_pause=present\n'; else printf 'rag_pause=absent\n'; fi
if [ -f "$R/.oversight-paused" ]; then printf 'ovr_kill=present\n'; else printf 'ovr_kill=absent\n'; fi
[ -f "$R/logs/agent-loop.log" ] && printf 'log_mtime=%s\n' "$(stat -c %Y "$R/logs/agent-loop.log" 2>/dev/null || echo 0)"
if crontab -l 2>/dev/null | grep -qE '^[0-9*].*agent-loop\.sh'; then printf 'cron=present\n'; else printf 'cron=absent\n'; fi
# The OVERSIGHT half is a separate fact from the fix loop and has its own cron
# and its own last-completed-run line. Reporting only the fix loop is how a
# remote `pl loop --host` could read reassuring while oversight was dead there.
if crontab -l 2>/dev/null | grep -qE '^[0-9*].*rag-sync\.sh'; then printf 'ragcron=present\n'; else printf 'ragcron=absent\n'; fi
if [ -f "$R/logs/rag-sync.log" ]; then
  printf 'rag_last=%s\n' "$(grep 'rag-sync done' "$R/logs/rag-sync.log" 2>/dev/null | tail -1 | awk '{print $1}')"
else printf 'rag_last=\n'; fi
PROBE
}

cmd_remote_status() {
    local target="$1" prefix name raw rc=0
    prefix="$(host_resolve_dest "$target")" || { print_error "cannot resolve target: $target"; return 1; }
    name="$(host_resolve_name "$target")"

    raw="$(host_run "$prefix" "$(_loop_remote_probe)" 2>/dev/null)" || rc=$?
    print_header "Self-healing loop — host: ${name}"
    if [ "$rc" -ne 0 ] || [[ "$raw" != *"NWPLOOP"* ]]; then
        printf '  %s  UNKNOWN — could not interrogate %s (rc=%s).\n' "$(dot off)" "$name" "$rc"
        printf '      An unreachable loop host is NOT a healthy one. Fix the route, then re-run.\n'
        return 3
    fi

    local root="" kill="" kill_mtime="" rag_pause="" log_mtime="" cron="" line
    local ovr_kill="" ragcron="" rag_last=""
    while IFS= read -r line; do
        case "$line" in
            root=*)       root="${line#root=}" ;;
            kill=*)       kill="${line#kill=}" ;;
            kill_mtime=*) kill_mtime="${line#kill_mtime=}" ;;
            rag_pause=*)  rag_pause="${line#rag_pause=}" ;;
            ovr_kill=*)   ovr_kill="${line#ovr_kill=}" ;;
            log_mtime=*)  log_mtime="${line#log_mtime=}" ;;
            cron=*)       cron="${line#cron=}" ;;
            ragcron=*)    ragcron="${line#ragcron=}" ;;
            rag_last=*)   rag_last="${line#rag_last=}" ;;
        esac
    done <<< "$raw"

    printf '  host:       %s   (tree: %s)\n' "$name" "${root:-?}"
    if [ "$kill" = "present" ]; then
        local since="?"
        [ -n "$kill_mtime" ] && since="$(date -d "@$kill_mtime" +%Y-%m-%d 2>/dev/null || echo '?')"
        printf '  %s  loop:       PAUSED on %s (.loop-paused since %s)\n' "$(dot off)" "$name" "$since"
    else
        printf '  %s  loop:       armed on %s (no .loop-paused)\n' "$(dot on)" "$name"
    fi
    if [ "$rag_pause" = "present" ] || [ "$ovr_kill" = "present" ]; then
        printf '  %s  rag-sync:   PAUSED on %s (%s)\n' "$(dot off)" "$name" \
            "$( [ "$rag_pause" = present ] && printf '.rag-sync-paused '; [ "$ovr_kill" = present ] && printf '.oversight-paused')"
    else
        printf '  %s  rag-sync:   not paused on %s\n' "$(dot on)" "$name"
    fi
    if [ "$cron" = "present" ]; then printf '  %s  cron:       armed on %s\n' "$(dot on)" "$name"
    else printf '  %s  cron:       ABSENT on %s — the loop will not wake\n' "$(dot off)" "$name"; fi
    # The oversight schedule is its own fact. "Not paused" is not "alive".
    if [ "$ragcron" = "present" ]; then printf '  %s  rag cron:   armed on %s\n' "$(dot on)" "$name"
    else printf '  %s  rag cron:   ABSENT on %s — oversight will not wake there (pl loop schedule install --host %s)\n' "$(dot off)" "$name" "$target"; fi
    if [ -n "$rag_last" ]; then
        local _re _rage
        _re="$(date -d "$rag_last" +%s 2>/dev/null || echo 0)"
        if [ "$_re" != "0" ]; then
            _rage=$(( ( $(date +%s) - _re ) / 86400 ))
            if [ "$_rage" -ge 7 ]; then printf '  %s  oversight:  last COMPLETED run on %s was %sd ago (%s)\n' "$(dot off)" "$name" "$_rage" "$rag_last"
            elif [ "$_rage" -ge 2 ]; then printf '  %s  oversight:  last completed run on %s was %sd ago (%s)\n' "$(dot AMBER)" "$name" "$_rage" "$rag_last"
            else printf '  %s  oversight:  last completed run on %s was %sd ago\n' "$(dot on)" "$name" "$_rage"; fi
        fi
    else
        printf '  %s  oversight:  NO completed rag-sync run on %s — grades are not reaching the tracker from there\n' "$(dot off)" "$name"
    fi
    if [ -n "$log_mtime" ]; then
        printf '     last log:   %s\n' "$(date -d "@$log_mtime" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '?')"
    else
        printf '     last log:   (no agent-loop.log on %s)\n' "$name"
    fi
    echo
    print_info "write verbs must be run ON ${name}: pl loop enable|disable <part|all>"
    return 0
}

if [ -n "$LOOP_TARGET" ]; then
    case "${1:-status}" in
        status|"") cmd_remote_status "$LOOP_TARGET"; exit $? ;;
        schedule) shift; cmd_schedule "${1:-status}" --host "$LOOP_TARGET" "${@:2}"; exit $? ;;
        enable|disable|parts)
            # Refusing is the whole point: a toggle typed here would silently
            # write the LOCAL sentinel and report success for the wrong machine.
            _tname="$(host_resolve_name "$LOOP_TARGET")"
            print_error "refusing: 'pl loop $1' writes local state, but you targeted ${_tname}."
            print_hint  "Run it ON ${_tname} (e.g. via that host's own pl), or use 'pl loop --host ${LOOP_TARGET}' to read only."
            exit 2 ;;
        *) print_error "unknown arg: $1"; exit 2 ;;
    esac
fi

case "${1:-status}" in
    -h|--help) sed -n '3,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    status|"") ;;
    enable|disable) cmd_toggle "$@"; exit $? ;;
    parts) cmd_parts; exit $? ;;
    schedule) shift; cmd_schedule "$@"; exit $? ;;
    *) print_error "unknown arg: $1"; exit 2 ;;
esac

# Always NAME the machine this dashboard describes — the loop is split across
# hosts, and an unlabelled dashboard is how the ai-host stayed dark for eight
# consecutive nights while this screen read all-green on the authoring host.
print_header "Self-healing loop — status (this machine: $(hostname -s 2>/dev/null || hostname))"
print_info "other machines: pl loop --host <role>   (e.g. pl loop --host ai-host)"

# ── Parts (wrapper-enforced enable/disable — deep-audit C0) ───────────────────
if loop_write_killed; then
    printf '  %s  WRITE KILL active — parts that can change the estate are disabled' "$(dot off)"
    [ -f "$RT/.loop-paused" ]               && printf '  (.loop-paused, since %s)' "$(date -r "$RT/.loop-paused" +%Y-%m-%d 2>/dev/null || echo '?')"
    [ "$(loop_part_raw all)" = "disabled" ] && printf '  (all=disabled)'
    printf '\n'
    loop_gates_unified \
      && printf '              %s NWP_LOOP_UNIFIED_GATES=1 — this ALSO blinds oversight (pre-ops#230)\n' "$(dot off)" \
      || printf '              read-only oversight is unaffected (ops#230)\n'
fi
if loop_oversight_killed; then
    printf '  %s  OVERSIGHT KILL active — the read-only half is off (%s)\n' "$(dot off)" "$(loop_oversight_kill_reason)"
fi
printf '  parts:      '
_first=1
for _p in "${LOOP_PARTS[@]}"; do
    _st="$(loop_part_state_word "$_p")"; _d=on; [ "$_st" = disabled ] && _d=off
    [ "$_first" = 1 ] || printf '              '
    printf '%s %-14s %-9s [%s]\n' "$(dot $_d)" "$_p" "$_st" "$(loop_part_capability "$_p")"
    _first=0
done
printf '              (toggle: pl loop enable|disable <part|all|oversight> · detail: pl loop parts)\n'
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
# `|| true` is load-bearing: with `set -euo pipefail`, an empty grep here KILLED
# `pl loop` mid-report — and it is empty exactly when the agent-loop cron is
# absent, i.e. when the loop is most broken. The dashboard aborted (exit 1) just
# before the line that would have said "cron: ABSENT". Observed on this host:
# the agent-loop cron IS missing, and `pl loop` had been exiting 1 without ever
# saying so.
sched="$(crontab -l 2>/dev/null | grep -E '^[0-9*].*agent-loop\.sh' | grep -oE '^[^ ]+ [^ ]+ [^ ]+ [^ ]+ [^ ]+' | head -1 || true)"
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
# ── RAG → issue sync (stage 1) — the OVERSIGHT half ──────────────────────────
if ! loop_part_enabled rag-sync; then
    printf '  %s  rag-sync:   DISABLED — %s\n' "$(dot off)" "$(loop_part_disabled_reason rag-sync)"
elif [ "${cron_rag:-0}" -gt 0 ]; then printf '  %s  rag-sync:   armed   (daily; stage 1 of the loop)\n' "$(dot on)"
else printf '  %s  rag-sync:   part enabled but NO CRON — nothing will wake it (pl loop schedule install --execute)\n' "$(dot off)"; fi
[ -f "$RAG_LOG" ] && printf '     last run:   %s\n' "$(grep 'rag-sync done' "$RAG_LOG" 2>/dev/null | tail -1 | cut -c1-70)"

# Freshness of the READ half, from the SAME probe pl todo and pl rag use
# (lib/oversight-freshness.sh, ops#230). "armed" and "actually completing" are
# different facts: for 16 nights rag-sync was armed, exited 0 every night, and
# completed nothing — and for the last two of those there was no cron at all.
if [ -f "$PROJECT_ROOT/lib/oversight-freshness.sh" ]; then
    # shellcheck source=/dev/null
    source "$PROJECT_ROOT/lib/oversight-freshness.sh"
    NWP_ROOT="$RT" oversight_probe
    printf '  %s  freshness:  %s — %s\n' "$(dot "$OVERSIGHT_GRADE")" "$OVERSIGHT_STATE" "$OVERSIGHT_DETAIL"
    [ "$OVERSIGHT_GRADE" = GREEN ] || printf '                 fix: %s\n' "$OVERSIGHT_ACTION"
fi
if loop_gates_unified; then
    printf '     gates:      %sUNIFIED%s — NWP_LOOP_UNIFIED_GATES=1 is set, so the WRITE kill also blinds\n' "${RED}" "${NC}"
    printf '                 read-only oversight. That is the pre-ops#230 behaviour that cost 16 nights.\n'
else
    printf '     gates:      SPLIT BY CAPABILITY — [write] parts answer to the WRITE kill (.loop-paused),\n'
    printf '                 [observe] parts to the OVERSIGHT kill (.oversight-paused). ops#230.\n'
fi

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
