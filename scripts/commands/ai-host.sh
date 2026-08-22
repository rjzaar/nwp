#!/usr/bin/env bash
# pl ai-host - LLM-host (AI) utilities (F21 Phase 3a)
#
# (File retains its legacy hostname-prefixed filename to avoid breaking
#  external references; the role-labeled successor name is `ai-host.sh`.
#  The legacy `pl <legacy-host-label>` subcommand still works as an alias.
#  See docs/reference/role-vocabulary.md for the host-to-role mapping.)
#
# Currently supports: pl ai-host llm health
#
# Rationale: Phase 3a deliberately leaves the generic `pl llm` namespace
# unclaimed until the agent role stabilises after Phase 10. `pl ai-host` is
# scoped to the operator's local LLM host, so it can carry targeted
# diagnostics without locking in a cross-provider LLM CLI shape.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/ui.sh"

# SSH host alias for the AI/LLM host. Default assumes ~/.ssh/config has an
# entry matching the operator's local convention; override with the env var.
AI_HOST_SSH="${NWP_AI_HOST_SSH:-${NWP_MINI_SSH_HOST:-ai-host}}"

# Models baselined in F21 Phase 3a.
# NOTE (ops#383): this is the HEALTH BASELINE, not the estate's only model
# claim — scripts/console/app/config.py defaults QUOKKA_MODEL=llama3.3:70b for
# the console chat tab. Measured 2026-08-15 on the AI host: all three models
# are registered, so the two surfaces disagree on defaults, not on reality.
# If you change either, change it as a decision, not a drive-by.
MODEL_CHAT="llama3.1:8b"
MODEL_CODER="qwen2.5-coder:14b"

# Eval-rate floors from Phase 3a success criteria.
THRESHOLD_CHAT_TOKS=25
THRESHOLD_CODER_TOKS=20

################################################################################
# Help
################################################################################

show_help() {
    cat << 'EOF'
Usage: pl ai-host SUBCOMMAND [OPTIONS]

AI/LLM-host utilities (F21 Phase 3a).

Subcommands:
    llm health       Check the local LLM stack on the AI host
    sessions         List agent tmux sessions on the AI host
    attach [NAME]    Attach to a session (READ-ONLY by default)
    term             Interactive session picker (the `miniterm` menu)

Options for `llm health`:
    --json           Emit structured JSON (for Phase 12 alerting consumers)
    --quick          Skip the benchmark (daemon + models + binding only)
    -h, --help       Show this help

Checks performed:
    1. ollama systemd --user unit is active
    2. Daemon responds to /api/tags over loopback
    3. Listening socket is bound to 127.0.0.1 (not 0.0.0.0)
    4. Baseline chat model (llama3.1:8b) is registered
    5. Baseline coder model (qwen2.5-coder:14b) is registered
    6. Chat model sustains >= 25 tok/s eval rate (unless --quick)
    7. Coder model sustains >= 20 tok/s eval rate (unless --quick)

Exit codes (llm health):
    0 - All checks passed
    1 - One or more checks MEASURED a failure
    2 - CANNOT VERIFY — the host/daemon could not be asked, so nothing was
        measured. Never graded as pass OR fail; recheck by re-running once
        the route works (e.g. NWP_AI_HOST_SSH=<alias>). Distinct from 1:
        "the model is genuinely absent" is a measurement, "I could not
        list the models" is not (ops#383).

Environment:
    NWP_AI_HOST_SSH - SSH host alias for the AI host (default: ai-host;
                      back-compat: also honours NWP_MINI_SSH_HOST)

Why attach is read-only by default:
    Long agent runs live in tmux on the AI host so they survive a disconnect
    (the dev laptop crashed mid-operation on 2026-08-02 and killed seven
    running agents). Attaching read-WRITE to a session where an agent is
    working means your keystrokes go into its prompt — one stray keypress
    injects input into a task mid-flight. Use --write only when you intend
    to type.

Examples:
    pl ai-host sessions
    pl ai-host attach nwp            # read-only
    pl ai-host attach nwp --write    # you can type; warns first
    pl ai-host term                  # interactive picker
    pl ai-host llm health
    pl ai-host llm health --quick
    pl ai-host llm health --json | jq .

References:
    docs/proposals/F21-distributed-build-deploy-pipeline.md (Phase 3a)
    docs/guides/local-llm.md
EOF
}

################################################################################
# SSH helper
################################################################################

ai_host_ssh() {
    ssh -o BatchMode=yes -o ConnectTimeout=5 "$AI_HOST_SSH" "$@"
}

################################################################################
# Individual checks
#
# Each check function sets a pair of globals:
#   CHECK_<name>_STATUS   - "ok" | "fail"
#   CHECK_<name>_DETAIL   - short human-readable string
# and returns 0 on success, 1 on failure.
################################################################################

# `x=$(cmd || echo LITERAL)` does NOT replace the output on failure — it
# APPENDS the literal to whatever the command already printed. Both checks
# below used that shape, and `systemctl is-active` / `curl -w %{http_code}`
# both print their answer AND exit non-zero when the answer is bad, which is
# their normal failure mode. So the two commonest real failures produced a
# two-line detail ("inactive\nunreachable", "000\n000"), and emit_json
# interpolates the detail into python source: `pl ai-host llm health --json`
# died with `SyntaxError: unterminated string literal` on exactly the runs it
# exists to report. Reproduced 2026-08-03 with a stubbed ssh.
#
# The rule both now follow (the ai_host_sessions idiom already in this file):
# capture the exit status separately, keep the command's own words, and only
# invent a sentinel when the command said nothing recognisable. Three states,
# never two — "the unit is stopped" and "I could not reach the host" are
# different facts and the operator is told which one happened.
_ai_host_last_line() { printf '%s' "${1##*$'\n'}"; }
# A detail is a ONE-LINE field (it lands in a table column and in JSON).
_ai_host_flatten()  { local s="${1//$'\n'/ | }"; printf '%s' "${s//$'\r'/}"; }

check_systemd_active() {
    local out rc state
    out=$(ai_host_ssh 'systemctl --user is-active ollama.service' 2>&1); rc=$?
    state="$(_ai_host_last_line "$out")"
    case "$state" in
        active|inactive|failed|activating|deactivating|reloading|unknown) ;;
        *)
            # Not a systemd state word: the TRANSPORT failed, systemd was never
            # asked. That is blindness, not a measurement (ops#383).
            CHECK_SYSTEMD_DETAIL="unreachable (rc=${rc}: $(_ai_host_flatten "${out:-no output}"))"
            CHECK_SYSTEMD_STATUS=blind
            return 1 ;;
    esac
    CHECK_SYSTEMD_DETAIL="$state"
    if [[ "$state" == "active" ]]; then
        CHECK_SYSTEMD_STATUS=ok
        return 0
    fi
    CHECK_SYSTEMD_STATUS=fail
    return 1
}

check_daemon_reachable() {
    local out rc http
    out=$(ai_host_ssh 'curl -sS -o /dev/null -w "%{http_code}" --max-time 5 http://127.0.0.1:11434/api/tags' 2>&1); rc=$?
    http="$(_ai_host_last_line "$out")"
    if [[ ! "$http" =~ ^[0-9]{3}$ ]]; then
        # curl always prints a 3-digit code when it ran (000 on connect
        # failure). No code = the ssh leg failed = we never looked (ops#383).
        CHECK_DAEMON_DETAIL="unreachable (rc=${rc}: $(_ai_host_flatten "${out:-no output}"))"
        CHECK_DAEMON_STATUS=blind
        return 1
    fi
    CHECK_DAEMON_DETAIL="HTTP $http on 127.0.0.1:11434/api/tags"
    if [[ "$http" == "200" ]]; then
        CHECK_DAEMON_STATUS=ok
        return 0
    fi
    CHECK_DAEMON_STATUS=fail
    return 1
}

check_loopback_only() {
    local listen rc
    # The old `|| true` + 2>/dev/null swallowed the ssh verdict, so an
    # unreachable host rendered as '<no listener>' — a bind measurement this
    # check never took (ops#383). Capture the status; '<no listener>' is only
    # sayable when ss actually ran and found nothing.
    listen=$(ai_host_ssh "ss -tlnH 'sport = :11434' 2>/dev/null | awk '{print \$4}'" 2>&1); rc=$?
    if [[ $rc -ne 0 ]]; then
        CHECK_BIND_DETAIL="CANNOT VERIFY (rc=${rc}: $(_ai_host_flatten "${listen:-no output}"))"
        CHECK_BIND_STATUS=blind
        return 1
    fi
    CHECK_BIND_DETAIL="$(_ai_host_flatten "${listen:-<no listener>}")"
    if [[ "$listen" == "127.0.0.1:11434" ]]; then
        CHECK_BIND_STATUS=ok
        return 0
    fi
    CHECK_BIND_STATUS=fail
    return 1
}

check_model_registered() {
    local model="$1"
    local var_prefix="$2"
    local out rc found
    # 'I could not list the models' and 'the model is not in the list' are
    # different facts. The old shape piped the ssh straight into grep with
    # `|| true`, so `ssh: Could not resolve hostname` printed
    # '<model> NOT registered' — an absence this check never measured
    # (ops#383, the ops#214 defect class). Only a listing that RAN may say
    # 'NOT registered'.
    out=$(ai_host_ssh '~/.local/bin/ollama list' 2>&1); rc=$?
    if [[ $rc -ne 0 ]]; then
        printf -v "CHECK_${var_prefix}_MODEL_STATUS" "blind"
        printf -v "CHECK_${var_prefix}_MODEL_DETAIL" "%s: CANNOT VERIFY — could not list models (rc=%s: %s)" \
            "$model" "$rc" "$(_ai_host_flatten "${out:-no output}")"
        return 1
    fi
    # grep WITHOUT -q: it consumes all input, so awk never takes a SIGPIPE
    # that pipefail would promote into a verdict (lint:pipefail-sigpipe).
    found=$(printf '%s\n' "$out" | awk '{print $1}' | grep -Fx "$model" || true)
    if [[ -n "$found" ]]; then
        printf -v "CHECK_${var_prefix}_MODEL_STATUS" "ok"
        printf -v "CHECK_${var_prefix}_MODEL_DETAIL" "%s registered" "$model"
        return 0
    fi
    printf -v "CHECK_${var_prefix}_MODEL_STATUS" "fail"
    printf -v "CHECK_${var_prefix}_MODEL_DETAIL" "%s NOT registered" "$model"
    return 1
}

# Benchmark a single model. Uses a fixed short prompt, streams off so we get
# a single JSON blob with eval_count + eval_duration. Parses on dev (we know
# python3 is available locally; the AI host may or may not have jq).
benchmark_model() {
    local model="$1"
    local floor="$2"
    local var_prefix="$3"
    local prompt='Write one short sentence greeting the world.'
    local payload rc
    payload=$(ai_host_ssh "curl -sS --max-time 60 http://127.0.0.1:11434/api/generate -d '{\"model\":\"$model\",\"prompt\":\"$prompt\",\"stream\":false}'" 2>&1); rc=$?

    if [[ $rc -ne 0 ]]; then
        # The ssh/curl leg failed: no measurement was taken (ops#383). This is
        # only reachable if the transport died AFTER the daemon checks passed.
        printf -v "CHECK_${var_prefix}_BENCH_STATUS" "blind"
        printf -v "CHECK_${var_prefix}_BENCH_DETAIL" "CANNOT VERIFY (rc=%s: %s)" "$rc" "$(_ai_host_flatten "${payload:-no output}")"
        printf -v "CHECK_${var_prefix}_BENCH_RATE" "0"
        return 1
    fi
    if [[ -z "$payload" ]]; then
        printf -v "CHECK_${var_prefix}_BENCH_STATUS" "fail"
        printf -v "CHECK_${var_prefix}_BENCH_DETAIL" "no response from %s" "$model"
        printf -v "CHECK_${var_prefix}_BENCH_RATE" "0"
        return 1
    fi

    local rate
    rate=$(python3 -c '
import sys, json
try:
    d = json.loads(sys.stdin.read())
    if d.get("eval_duration", 0) > 0:
        print("%.2f" % (d["eval_count"] / (d["eval_duration"] / 1e9)))
    else:
        print("0")
except Exception:
    print("0")
' <<< "$payload")

    printf -v "CHECK_${var_prefix}_BENCH_RATE" "%s" "$rate"

    # Compare as float: awk is more portable than bash for this.
    if awk -v r="$rate" -v f="$floor" 'BEGIN { exit !(r+0 >= f+0) }'; then
        printf -v "CHECK_${var_prefix}_BENCH_STATUS" "ok"
        printf -v "CHECK_${var_prefix}_BENCH_DETAIL" "%s tok/s (floor %s)" "$rate" "$floor"
        return 0
    fi
    printf -v "CHECK_${var_prefix}_BENCH_STATUS" "fail"
    printf -v "CHECK_${var_prefix}_BENCH_DETAIL" "%s tok/s below floor %s" "$rate" "$floor"
    return 1
}

################################################################################
# Output formatters
################################################################################

# _emit_check STATUS "label-ok: detail" "label-fail: detail" ["label-blind: detail"]
# Three renderings, never two: BLIND is a WARN row saying the measurement was
# not taken — it must not wear the ✗ of a measured failure (ops#383).
_emit_check() {
    local st="$1" ok_msg="$2" fail_msg="$3" blind_msg="${4:-$3}"
    case "$st" in
        ok)    print_status OK   "$ok_msg" ;;
        blind) print_status WARN "$blind_msg" ;;
        *)     print_status FAIL "$fail_msg" ;;
    esac
}

emit_human() {
    local status="$1"
    print_header "AI-host LLM Health"

    _emit_check "$CHECK_SYSTEMD_STATUS" \
        "systemd --user unit: $CHECK_SYSTEMD_DETAIL" \
        "systemd --user unit: $CHECK_SYSTEMD_DETAIL"

    _emit_check "$CHECK_DAEMON_STATUS" \
        "daemon reachable: $CHECK_DAEMON_DETAIL" \
        "daemon reachable: $CHECK_DAEMON_DETAIL"

    _emit_check "$CHECK_BIND_STATUS" \
        "listener bound loopback-only: $CHECK_BIND_DETAIL" \
        "listener NOT loopback-only: $CHECK_BIND_DETAIL" \
        "listener: $CHECK_BIND_DETAIL"

    _emit_check "$CHECK_CHAT_MODEL_STATUS" \
        "chat model: $CHECK_CHAT_MODEL_DETAIL" \
        "chat model: $CHECK_CHAT_MODEL_DETAIL"

    _emit_check "$CHECK_CODER_MODEL_STATUS" \
        "coder model: $CHECK_CODER_MODEL_DETAIL" \
        "coder model: $CHECK_CODER_MODEL_DETAIL"

    if [[ "${QUICK:-0}" != "1" ]]; then
        _emit_check "$CHECK_CHAT_BENCH_STATUS" \
            "chat bench: $CHECK_CHAT_BENCH_DETAIL" \
            "chat bench: $CHECK_CHAT_BENCH_DETAIL"
        _emit_check "$CHECK_CODER_BENCH_STATUS" \
            "coder bench: $CHECK_CODER_BENCH_DETAIL" \
            "coder bench: $CHECK_CODER_BENCH_DETAIL"
    fi

    echo
    case "$status" in
        ok)
            print_success "AI-host LLM stack healthy" ;;
        blind)
            print_error "CANNOT VERIFY — could not measure the LLM stack on ${AI_HOST_SSH} (this is 'could not look', not 'unhealthy')"
            print_info  "recheck: fix the route (NWP_AI_HOST_SSH=<alias>) and re-run — the verdict clears on its own terms" ;;
        *)
            print_error "AI-host LLM stack unhealthy — see checks above" ;;
    esac
}

emit_json() {
    local status="$1"
    local quick="${QUICK:-0}"
    # Details are REMOTE TEXT (systemctl / curl / ssh error output). They used
    # to be pasted straight into this python source, so any detail containing a
    # newline or a double quote produced a SyntaxError instead of JSON — the
    # emitter broke on precisely the unhealthy hosts it is meant to describe.
    # Hand them over as environment variables and let json.dumps do the quoting.
    J_HOST="$AI_HOST_SSH" \
    J_STATUS="$status" \
    J_QUICK="$quick" \
    J_SYSTEMD_S="$CHECK_SYSTEMD_STATUS"          J_SYSTEMD_D="$CHECK_SYSTEMD_DETAIL" \
    J_DAEMON_S="$CHECK_DAEMON_STATUS"            J_DAEMON_D="$CHECK_DAEMON_DETAIL" \
    J_BIND_S="$CHECK_BIND_STATUS"                J_BIND_D="$CHECK_BIND_DETAIL" \
    J_CHATM_S="$CHECK_CHAT_MODEL_STATUS"         J_CHATM_D="$CHECK_CHAT_MODEL_DETAIL" \
    J_CODERM_S="$CHECK_CODER_MODEL_STATUS"       J_CODERM_D="$CHECK_CODER_MODEL_DETAIL" \
    J_CHATB_S="${CHECK_CHAT_BENCH_STATUS:-skip}" J_CHATB_D="${CHECK_CHAT_BENCH_DETAIL:-}" \
    J_CHATB_R="${CHECK_CHAT_BENCH_RATE:-0}" \
    J_CODERB_S="${CHECK_CODER_BENCH_STATUS:-skip}" J_CODERB_D="${CHECK_CODER_BENCH_DETAIL:-}" \
    J_CODERB_R="${CHECK_CODER_BENCH_RATE:-0}" \
    python3 - <<'PY'
import json, os
e = os.environ
def chk(s, d): return {"status": e[s], "detail": e[d]}
doc = {
    "host":   e["J_HOST"],
    "status": e["J_STATUS"],
    "quick":  bool(int(e["J_QUICK"] or "0")),
    "checks": {
        "systemd":     chk("J_SYSTEMD_S", "J_SYSTEMD_D"),
        "daemon":      chk("J_DAEMON_S",  "J_DAEMON_D"),
        "bind":        chk("J_BIND_S",    "J_BIND_D"),
        "chat_model":  chk("J_CHATM_S",   "J_CHATM_D"),
        "coder_model": chk("J_CODERM_S",  "J_CODERM_D"),
    },
}
if not doc["quick"]:
    doc["checks"]["chat_bench"]  = dict(chk("J_CHATB_S",  "J_CHATB_D"),  rate_toks=float(e["J_CHATB_R"]  or 0))
    doc["checks"]["coder_bench"] = dict(chk("J_CODERB_S", "J_CODERB_D"), rate_toks=float(e["J_CODERB_R"] or 0))
print(json.dumps(doc, indent=2))
PY
}

################################################################################
# Main
################################################################################

cmd_llm_health() {
    local json=0
    QUICK=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)  json=1; shift ;;
            --quick) QUICK=1; shift ;;
            -h|--help) show_help; exit 0 ;;
            *) print_error "Unknown option: $1"; show_help; exit 2 ;;
        esac
    done

    check_systemd_active       || true
    check_daemon_reachable     || true
    check_loopback_only        || true
    check_model_registered "$MODEL_CHAT"  CHAT  || true
    check_model_registered "$MODEL_CODER" CODER || true

    if [[ "$QUICK" != "1" ]]; then
        # Only run benchmarks if the daemon is up and the models are present;
        # otherwise they'll definitely fail and the output is noise.
        if [[ "$CHECK_DAEMON_STATUS" == "ok" && "$CHECK_CHAT_MODEL_STATUS" == "ok" ]]; then
            benchmark_model "$MODEL_CHAT"  "$THRESHOLD_CHAT_TOKS"  CHAT  || true
        else
            CHECK_CHAT_BENCH_STATUS=skip
            CHECK_CHAT_BENCH_DETAIL="skipped (prereqs failed)"
            CHECK_CHAT_BENCH_RATE=0
        fi
        if [[ "$CHECK_DAEMON_STATUS" == "ok" && "$CHECK_CODER_MODEL_STATUS" == "ok" ]]; then
            benchmark_model "$MODEL_CODER" "$THRESHOLD_CODER_TOKS" CODER || true
        else
            CHECK_CODER_BENCH_STATUS=skip
            CHECK_CODER_BENCH_DETAIL="skipped (prereqs failed)"
            CHECK_CODER_BENCH_RATE=0
        fi
    fi

    # Overall verdict, three states (ops#383):
    #   fail  — at least one check MEASURED something bad          → exit 1
    #   blind — nothing measured bad, but ≥1 check could not look  → exit 2
    #   ok    — every check measured, all good                     → exit 0
    # A measured failure outranks blindness (the stack IS unhealthy, however
    # much else we could not see); blindness outranks ok, because a verdict
    # with an unmeasured check in it is not a pass (CLAUDE.md: never grade
    # CANNOT VERIFY as green). Skipped benches count as neither.
    local overall=ok s
    for s in "$CHECK_SYSTEMD_STATUS" "$CHECK_DAEMON_STATUS" "$CHECK_BIND_STATUS" \
             "$CHECK_CHAT_MODEL_STATUS" "$CHECK_CODER_MODEL_STATUS" \
             "${CHECK_CHAT_BENCH_STATUS:-skip}" "${CHECK_CODER_BENCH_STATUS:-skip}"; do
        case "$s" in
            fail)  overall=fail; break ;;
            blind) overall=blind ;;
        esac
    done

    if [[ "$json" == "1" ]]; then
        emit_json "$overall"
    else
        emit_human "$overall"
    fi

    case "$overall" in
        ok)    return 0 ;;
        blind) return 2 ;;
        *)     return 1 ;;
    esac
}


################################################################################
# Agent sessions (tmux) on the AI host
#
# The ai-host is the durable agent host. These surfaces let the operator see what is
# running and watch it. READ-ONLY is the default on purpose — see show_help.
################################################################################

AI_HOST_SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)

# ai_host_sessions — emit "name<TAB>windows<TAB>attached" per session.
# Distinguishes THREE states, never two: sessions / none / unreachable.
# "Could not look" must never render as "nothing running" (ops#214 family).
ai_host_sessions() {
    local out rc
    # NOTE: the separator must be a REAL tab. Passing the two characters \t
    # through ssh hands tmux a literal backslash-t, which it prints verbatim
    # and the reader then fails to split on — caught in testing.
    local fmt
    fmt=$(printf '#{session_name}\t#{session_windows}\t#{?session_attached,attached,}')
    out=$(ssh "${AI_HOST_SSH_OPTS[@]}" "$AI_HOST_SSH" \
        "tmux list-sessions -F $(printf '%q' "$fmt")" 2>&1)
    rc=$?
    if [[ $rc -ne 0 ]]; then
        if [[ "$out" == *"no server running"* || "$out" == *"No such file"* ]]; then
            return 1   # genuinely no sessions
        fi
        printf '%s\n' "$out" >&2
        return 3       # UNREACHABLE — not the same as none
    fi
    [[ -z "$out" ]] && return 1
    printf '%s\n' "$out"
    return 0
}

cmd_sessions() {
    local rows rc
    rows=$(ai_host_sessions); rc=$?
    case $rc in
        3) print_error "UNREACHABLE: cannot reach ${AI_HOST_SSH} — this is 'could not look', not 'nothing running'"; return 3 ;;
        1) print_info "No tmux sessions on ${AI_HOST_SSH}"; return 1 ;;
    esac
    printf '%s\n' "$rows" | while IFS=$'\t' read -r name wins att; do
        printf '  %-24s %s window(s)%s\n' "$name" "$wins" "${att:+  · attached}"
    done
}

# _ai_host_spawn — open the attach in a NEW terminal when one exists, so the
# operator keeps the shell they ran this from. Falls back to attaching here.
_ai_host_spawn() {
    local session="$1" mode="${2:-read}" ropt="-r" cmd term
    [[ "$mode" == write ]] && ropt=""
    cmd="ssh -t $(printf '%q' "$AI_HOST_SSH") 'tmux attach ${ropt} -t $(printf '%q' "$session")'"
    for term in gnome-terminal x-terminal-emulator xfce4-terminal konsole alacritty kitty xterm; do
        command -v "$term" >/dev/null 2>&1 || continue
        case "$term" in
            gnome-terminal) nohup "$term" --title="${AI_HOST_SSH}:${session}" -- bash -lc "$cmd" >/dev/null 2>&1 & ;;
            *)              nohup "$term" -e bash -lc "$cmd" >/dev/null 2>&1 & ;;
        esac
        if [[ "$mode" == write ]]; then
            print_warning "${session}: opened in WRITE mode — your keystrokes reach the agent"
        else
            print_success "${session}: opened read-only"
        fi
        return 0
    done
    print_info "No terminal emulator found — attaching in this shell"
    eval "$cmd"
}

cmd_attach() {
    local session="${1:-}" mode=read
    shift 2>/dev/null || true
    [[ "${1:-}" == "--write" || "${1:-}" == "-w" ]] && mode=write
    if [[ -z "$session" ]]; then print_error "usage: pl ai-host attach <session> [--write]"; return 2; fi
    _ai_host_spawn "$session" "$mode"
}

cmd_term() {
    local rows rc choice mode=read pick i yn nn
    while true; do
        rows=$(ai_host_sessions); rc=$?
        printf '\n  \033[1msessions on %s\033[0m   %s\n\n' "$AI_HOST_SSH" \
            "$([[ "$mode" == write ]] && printf '\033[0;33m[WRITE MODE]\033[0m' || printf '\033[2m[read-only]\033[0m')"
        case $rc in
            3) printf '  \033[0;31mUNREACHABLE\033[0m: cannot reach %s.\n     That is "could not look", not "nothing running".\n' "$AI_HOST_SSH" ;;
            1) printf '  \033[2mno sessions running\033[0m\n' ;;
            0) i=0
               while IFS=$'\t' read -r name wins att; do
                   i=$((i+1))
                   printf '   \033[1m%s\033[0m) %-22s %s window(s)%s\n' "$i" "$name" "$wins" "${att:+  · attached}"
               done <<< "$rows" ;;
        esac
        printf '\n  [1-9] attach   [w] write-mode   [n] new   [h] help   [r] refresh   [q] quit\n  > '
        read -r choice || { printf '\n'; return 0; }
        case "$choice" in
            q|Q|'') printf '\n'; return 0 ;;
            h|H) show_help ;;
            r|R) continue ;;
            w|W) if [[ "$mode" == write ]]; then mode=read
                 else
                     printf '\n  \033[0;33mCAUTION\033[0m: write mode sends your keystrokes into the session.\n'
                     printf '  If an agent is working there, you are typing into its prompt.\n  Enable? [y/N] '
                     read -r yn; [[ "$yn" == y || "$yn" == Y ]] && mode=write
                 fi ;;
            n|N) printf '  new session name: '; read -r nn
                 [[ -z "$nn" ]] && continue
                 ssh "${AI_HOST_SSH_OPTS[@]}" "$AI_HOST_SSH" "tmux new-session -d -s $(printf '%q' "$nn")" \
                     && _ai_host_spawn "$nn" "$mode" ;;
            [1-9]|[1-9][0-9])
                 pick=$(printf '%s\n' "$rows" | sed -n "${choice}p" | cut -f1)
                 [[ -z "$pick" ]] && { printf '  no session %s\n' "$choice"; continue; }
                 _ai_host_spawn "$pick" "$mode" ;;
            *) printf '  unknown option: %s\n' "$choice" ;;
        esac
    done
}

main() {
    if [[ $# -eq 0 ]]; then
        show_help
        exit 0
    fi

    case "$1" in
        -h|--help)
            show_help
            ;;
        sessions)
            shift
            cmd_sessions "$@"
            ;;
        attach)
            shift
            cmd_attach "$@"
            ;;
        term)
            shift
            cmd_term "$@"
            ;;
        llm)
            shift
            case "${1:-}" in
                health)
                    shift
                    cmd_llm_health "$@"
                    ;;
                *)
                    print_error "Unknown llm subcommand: ${1:-<none>}"
                    show_help
                    exit 2
                    ;;
            esac
            ;;
        *)
            print_error "Unknown subcommand: $1"
            show_help
            exit 2
            ;;
    esac
}

main "$@"
