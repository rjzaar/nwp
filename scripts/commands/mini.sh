#!/usr/bin/env bash
# pl mini - mini-specific utilities (F21 Phase 3a)
#
# Currently supports: pl mini llm health
#
# Rationale: Phase 3a deliberately leaves the generic `pl llm` namespace
# unclaimed until the agent role stabilises after Phase 10. `pl mini` is
# mini-scoped, so it can carry targeted diagnostics without locking in
# a cross-provider LLM CLI shape.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/ui.sh"

# SSH host alias for mini. Default assumes ~/.ssh/config has a `mini` entry.
MINI_SSH_HOST="${NWP_MINI_SSH_HOST:-mini}"

# Models baselined in F21 Phase 3a.
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
Usage: pl mini SUBCOMMAND [OPTIONS]

Mini-specific utilities (F21 Phase 3a).

Subcommands:
    llm health       Check the local LLM stack on mini

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

Exit codes:
    0 - All checks passed
    1 - One or more checks failed

Environment:
    NWP_MINI_SSH_HOST - SSH host alias for mini (default: mini)

Examples:
    pl mini llm health
    pl mini llm health --quick
    pl mini llm health --json | jq .

References:
    docs/proposals/F21-distributed-build-deploy-pipeline.md (Phase 3a)
    docs/guides/local-llm.md
EOF
}

################################################################################
# SSH helper
################################################################################

mini_ssh() {
    ssh -o BatchMode=yes -o ConnectTimeout=5 "$MINI_SSH_HOST" "$@"
}

################################################################################
# Individual checks
#
# Each check function sets a pair of globals:
#   CHECK_<name>_STATUS   - "ok" | "fail"
#   CHECK_<name>_DETAIL   - short human-readable string
# and returns 0 on success, 1 on failure.
################################################################################

check_systemd_active() {
    local state
    state=$(mini_ssh 'systemctl --user is-active ollama.service' 2>/dev/null || echo "unreachable")
    CHECK_SYSTEMD_DETAIL="$state"
    if [[ "$state" == "active" ]]; then
        CHECK_SYSTEMD_STATUS=ok
        return 0
    fi
    CHECK_SYSTEMD_STATUS=fail
    return 1
}

check_daemon_reachable() {
    local http
    http=$(mini_ssh 'curl -sS -o /dev/null -w "%{http_code}" --max-time 5 http://127.0.0.1:11434/api/tags' 2>/dev/null || echo "000")
    CHECK_DAEMON_DETAIL="HTTP $http on 127.0.0.1:11434/api/tags"
    if [[ "$http" == "200" ]]; then
        CHECK_DAEMON_STATUS=ok
        return 0
    fi
    CHECK_DAEMON_STATUS=fail
    return 1
}

check_loopback_only() {
    local listen
    listen=$(mini_ssh "ss -tlnH 'sport = :11434' 2>/dev/null | awk '{print \$4}'" 2>/dev/null || true)
    CHECK_BIND_DETAIL="${listen:-<no listener>}"
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
    local found
    found=$(mini_ssh '~/.local/bin/ollama list' 2>/dev/null | awk '{print $1}' | grep -Fx "$model" || true)
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
# python3 is available locally; mini may or may not have jq).
benchmark_model() {
    local model="$1"
    local floor="$2"
    local var_prefix="$3"
    local prompt='Write one short sentence greeting the world.'
    local payload
    payload=$(mini_ssh "curl -sS --max-time 60 http://127.0.0.1:11434/api/generate -d '{\"model\":\"$model\",\"prompt\":\"$prompt\",\"stream\":false}'" 2>/dev/null || true)

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

emit_human() {
    local status="$1"
    print_header "Mini LLM Health"

    if [[ "$CHECK_SYSTEMD_STATUS" == "ok" ]]; then
        print_status OK "systemd --user unit: $CHECK_SYSTEMD_DETAIL"
    else
        print_status FAIL "systemd --user unit: $CHECK_SYSTEMD_DETAIL"
    fi

    if [[ "$CHECK_DAEMON_STATUS" == "ok" ]]; then
        print_status OK "daemon reachable: $CHECK_DAEMON_DETAIL"
    else
        print_status FAIL "daemon reachable: $CHECK_DAEMON_DETAIL"
    fi

    if [[ "$CHECK_BIND_STATUS" == "ok" ]]; then
        print_status OK "listener bound loopback-only: $CHECK_BIND_DETAIL"
    else
        print_status FAIL "listener NOT loopback-only: $CHECK_BIND_DETAIL"
    fi

    if [[ "$CHECK_CHAT_MODEL_STATUS" == "ok" ]]; then
        print_status OK "chat model: $CHECK_CHAT_MODEL_DETAIL"
    else
        print_status FAIL "chat model: $CHECK_CHAT_MODEL_DETAIL"
    fi

    if [[ "$CHECK_CODER_MODEL_STATUS" == "ok" ]]; then
        print_status OK "coder model: $CHECK_CODER_MODEL_DETAIL"
    else
        print_status FAIL "coder model: $CHECK_CODER_MODEL_DETAIL"
    fi

    if [[ "${QUICK:-0}" != "1" ]]; then
        if [[ "$CHECK_CHAT_BENCH_STATUS" == "ok" ]]; then
            print_status OK "chat bench: $CHECK_CHAT_BENCH_DETAIL"
        else
            print_status FAIL "chat bench: $CHECK_CHAT_BENCH_DETAIL"
        fi
        if [[ "$CHECK_CODER_BENCH_STATUS" == "ok" ]]; then
            print_status OK "coder bench: $CHECK_CODER_BENCH_DETAIL"
        else
            print_status FAIL "coder bench: $CHECK_CODER_BENCH_DETAIL"
        fi
    fi

    echo
    if [[ "$status" == "ok" ]]; then
        print_success "mini LLM stack healthy"
    else
        print_error "mini LLM stack unhealthy — see checks above"
    fi
}

emit_json() {
    local status="$1"
    local quick="${QUICK:-0}"
    python3 - <<PY
import json
doc = {
    "host": "${MINI_SSH_HOST}",
    "status": "${status}",
    "quick": bool(int("${quick}")),
    "checks": {
        "systemd":      {"status": "${CHECK_SYSTEMD_STATUS}",      "detail": "${CHECK_SYSTEMD_DETAIL}"},
        "daemon":       {"status": "${CHECK_DAEMON_STATUS}",       "detail": "${CHECK_DAEMON_DETAIL}"},
        "bind":         {"status": "${CHECK_BIND_STATUS}",         "detail": "${CHECK_BIND_DETAIL}"},
        "chat_model":   {"status": "${CHECK_CHAT_MODEL_STATUS}",   "detail": "${CHECK_CHAT_MODEL_DETAIL}"},
        "coder_model":  {"status": "${CHECK_CODER_MODEL_STATUS}",  "detail": "${CHECK_CODER_MODEL_DETAIL}"},
    },
}
if not doc["quick"]:
    doc["checks"]["chat_bench"]  = {"status": "${CHECK_CHAT_BENCH_STATUS:-skip}",  "detail": "${CHECK_CHAT_BENCH_DETAIL:-}",  "rate_toks": float("${CHECK_CHAT_BENCH_RATE:-0}")}
    doc["checks"]["coder_bench"] = {"status": "${CHECK_CODER_BENCH_STATUS:-skip}", "detail": "${CHECK_CODER_BENCH_DETAIL:-}", "rate_toks": float("${CHECK_CODER_BENCH_RATE:-0}")}
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

    local overall=ok

    check_systemd_active       || overall=fail
    check_daemon_reachable     || overall=fail
    check_loopback_only        || overall=fail
    check_model_registered "$MODEL_CHAT"  CHAT  || overall=fail
    check_model_registered "$MODEL_CODER" CODER || overall=fail

    if [[ "$QUICK" != "1" ]]; then
        # Only run benchmarks if the daemon is up and the models are present;
        # otherwise they'll definitely fail and the output is noise.
        if [[ "$CHECK_DAEMON_STATUS" == "ok" && "$CHECK_CHAT_MODEL_STATUS" == "ok" ]]; then
            benchmark_model "$MODEL_CHAT"  "$THRESHOLD_CHAT_TOKS"  CHAT  || overall=fail
        else
            CHECK_CHAT_BENCH_STATUS=skip
            CHECK_CHAT_BENCH_DETAIL="skipped (prereqs failed)"
            CHECK_CHAT_BENCH_RATE=0
        fi
        if [[ "$CHECK_DAEMON_STATUS" == "ok" && "$CHECK_CODER_MODEL_STATUS" == "ok" ]]; then
            benchmark_model "$MODEL_CODER" "$THRESHOLD_CODER_TOKS" CODER || overall=fail
        else
            CHECK_CODER_BENCH_STATUS=skip
            CHECK_CODER_BENCH_DETAIL="skipped (prereqs failed)"
            CHECK_CODER_BENCH_RATE=0
        fi
    fi

    if [[ "$json" == "1" ]]; then
        emit_json "$overall"
    else
        emit_human "$overall"
    fi

    [[ "$overall" == "ok" ]]
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
