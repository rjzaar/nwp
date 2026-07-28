#!/usr/bin/env bash
#
# lib/loop-preflight.sh — the agent-loop's resource/health gate.
#
# WHY THIS EXISTS (ops#109, operator decision 23)
# -----------------------------------------------
# Decision 23 makes ONE host — the ai-host — the sole owner of the agent-loop.
# Before it, the cron lived on a second box whose checkout tracked a mirror
# remote, so "which machine runs the loop" was answered by whichever crontab you
# happened to read. Consolidating fixes that. But consolidation CONCENTRATES the
# load: the ai-host is also the LLM host, the webhook receiver and a
# gitlab-runner. A :00/:30 tick with no gate spawns a headless `claude -p` on
# top of whatever the operator was already doing on that box.
#
# This library is that gate. It runs BEFORE the loop claims an issue and answers
# exactly one question: *is this host busy enough that the run should wait?*
#
# DEFER, NOT FAIL
# ---------------
# The gate's outcome is a DEFERRED RUN, not an error. A deferral costs 30
# minutes, claims no issue, churns no label, spawns no agent, and exits 0 so
# cron stays green. That asymmetry is the whole design:
#
#   * a run deferred by mistake costs the operator 30 minutes of latency;
#   * a run that piles onto a loaded box costs the operator their evening.
#
# So this gate is FAIL-SAFE: **a probe that cannot answer DEFERS.** That is a
# different rule from lib/host-capture.sh's fail-CLOSED (where blindness is an
# error the caller must handle) and from the loop's sensitive-path gate (where
# blindness is a refusal to push). Here blindness is simply "not now".
#
# THE ONE DOCUMENTED EXCEPTION is ollama. It is an OPTIONAL service — most hosts
# that could own the loop never run it — so an unreachable or unparseable
# /api/ps is read as "no model resident", never as "cannot tell". Fail-safe on
# an absent service is not safety; it is a loop that defers forever.
#
# REUSE, NOT REINVENTION
# ----------------------
# Signals 1 and 2 (RAM, load) are NOT re-implemented here. They go through
# `pl server health`'s own engine — host_health_probe / host_health_eval /
# host_health_require in lib/host-capture.sh — so the loop and the verb the
# standing orders call "a REQUIRED PREFLIGHT" cannot drift apart, and so the
# loop inherits that engine's disk and swap-pressure checks for free. Only
# signals 3 and 4, which are specific to an AI/CI host, are new code.
#
# SIGNALS AND DEFAULTS (every threshold is env-overridable)
# --------------------------------------------------------
#   AGENT_LOOP_MIN_MEM_MB          default 2048
#       Available system RAM floor. A headless `claude -p` is a Node process
#       that then runs the repo's own test commands (bats, php, composer,
#       sometimes ddev). 2 GB is the smallest floor under which such a run is
#       likely to be OOM-killed mid-edit, leaving a half-written worktree and a
#       burned retry. Deliberately 4x `pl server health`'s own 512 MB default:
#       that default asks "is this box dying", this one asks "can it host a
#       build".
#
#   AGENT_LOOP_MAX_LOAD_PCT        default 150   (percent of ONE core)
#       Load average per core. PER CORE because a fixed load number is
#       meaningless without the core count — load 8 is idle on 32 cores and
#       drowning on 2. Set BELOW host-capture's own 200% because the loop is
#       discretionary background work and should yield earlier than a verb
#       protecting a live site.
#
#   AGENT_LOOP_REQUIRE_IDLE_OLLAMA default 1     (1 = defer on a resident model)
#   AGENT_LOOP_OLLAMA_URL          default http://127.0.0.1:11434
#   AGENT_LOOP_OLLAMA_TIMEOUT      default 3     (seconds)
#       A model resident in ollama means the local LLM is in use: ollama keeps a
#       model loaded for ~5 minutes after its last request, so a non-empty
#       /api/ps is a good proxy for "the operator is working on this box right
#       now". This signal exists BECAUSE the RAM floor cannot see it — the
#       model occupies iGPU VRAM, a different pool from the system RAM signal 1
#       reads, so a 30 GB-free reading and a fully-loaded LLM are the same
#       number.
#
#   AGENT_LOOP_MAX_RUNNER_JOBS     default 0     (defer if ANY job is running)
#   AGENT_LOOP_RUNNER_USER         default gitlab-runner
#       Concurrent gitlab-runner jobs. Decision 23 puts the loop on the same box
#       as the CI runner, and a runner job (composer, ddev, phpunit) is the
#       heaviest thing that box does. Probed as "processes owned by the runner
#       user": the runner DAEMON runs as root, so a non-zero count means a
#       shell-executor job is actually executing, not merely that the service is
#       enabled. If the runner user does not exist the runner is not installed
#       and the answer is 0 — not blindness.
#
#   AGENT_LOOP_SKIP_PREFLIGHT      default 0     (1 = skip the gate entirely)
#       An explicit, logged escape hatch for an operator running the loop by
#       hand. Deliberately NOT consulted by anything automatic.
#
# Inherited from lib/host-capture.sh, unchanged: NWP_HEALTH_MIN_DISK_MB (2048)
# and NWP_HEALTH_MIN_SWAP_FREE_PCT (25).
#
# Dependency-light on purpose: sourcing this must be safe from a bare cron
# wrapper. It needs lib/host-capture.sh, plus curl and python3 (both already
# hard dependencies of agent-loop.sh).

[ -n "${_NWP_LOOP_PREFLIGHT_SOURCED:-}" ] && return 0
_NWP_LOOP_PREFLIGHT_SOURCED=1

# Route through the caller's logger when there is one (agent-loop.sh defines
# log(), which tees to logs/agent-loop.log — a deferral MUST be visible there,
# otherwise a quiet loop and a deferring loop look identical). Fall back to
# stderr so the library is usable standalone, e.g. from `pl loop preflight`.
loop_pf_log() {
    if declare -F log >/dev/null 2>&1; then
        log "$*"
    else
        printf '%s\n' "$*" >&2
    fi
}

# --------------------------------------------------------------------------
# SIGNAL 3 — ollama.
#
# Split into a TRANSPORT function and a PARSE function so tests can stub the
# transport and still exercise the real parse. A parser tested only through a
# stub of itself is a parser with no test.
# --------------------------------------------------------------------------

# loop_pf_fetch_ollama_ps
# Prints the raw /api/ps body. Returns non-zero when ollama could not be
# reached at all — which the caller reads as "no model", see the header.
loop_pf_fetch_ollama_ps() {
    local base="${AGENT_LOOP_OLLAMA_URL:-http://127.0.0.1:11434}"
    local timeout="${AGENT_LOOP_OLLAMA_TIMEOUT:-3}"
    command -v curl >/dev/null 2>&1 || return 1
    curl -sS --max-time "$timeout" "${base%/}/api/ps" 2>/dev/null || return 1
}

# loop_pf_ollama_model_resident
# 0 = a model IS resident. 1 = none resident, ollama absent, or the body could
# not be parsed. Never returns "unknown": see the header's documented exception.
loop_pf_ollama_model_resident() {
    local body
    body="$(loop_pf_fetch_ollama_ps)" || return 1
    [ -n "$body" ] || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    printf '%s' "$body" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)          # malformed => "no model", per the header
if not isinstance(d, dict):
    raise SystemExit(1)
raise SystemExit(0 if (d.get("models") or []) else 1)
'
}

# --------------------------------------------------------------------------
# SIGNAL 4 — gitlab-runner jobs.
# --------------------------------------------------------------------------

# loop_pf_runner_jobs
# Prints the number of processes owned by the runner user.
# Returns 0 when it answered, 3 when it is BLIND (the user exists but the count
# could not be taken) — and blind is a defer, not a zero.
loop_pf_runner_jobs() {
    local user="${AGENT_LOOP_RUNNER_USER:-gitlab-runner}"

    # No such user => gitlab-runner is not installed on this host => 0 jobs.
    # This is a real answer, not blindness: there is nothing here to be busy.
    if ! id -u "$user" >/dev/null 2>&1; then
        printf '0\n'
        return 0
    fi

    command -v pgrep >/dev/null 2>&1 || { printf 'BLIND\n'; return 3; }

    local n rc=0
    n="$(pgrep -u "$user" -c 2>/dev/null)" || rc=$?
    case "$rc" in
        0) : ;;
        1) n=0 ;;                       # pgrep's documented "no matches"
        *) printf 'BLIND\n'; return 3 ;;  # 2/3 = usage or fatal error
    esac
    printf '%s\n' "${n:-0}"
    return 0
}

# --------------------------------------------------------------------------
# THE GATE
# --------------------------------------------------------------------------

# loop_preflight [label]
# 0 = PROCEED. 1 = DEFER (reason logged via loop_pf_log).
# Never returns anything else: the caller's only decision is run or wait.
loop_preflight() {
    local label="${1:-the agent-loop run}"

    if [ "${AGENT_LOOP_SKIP_PREFLIGHT:-0}" = "1" ]; then
        loop_pf_log "preflight SKIPPED (AGENT_LOOP_SKIP_PREFLIGHT=1) — running ${label} unguarded"
        return 0
    fi

    # --- signals 1 + 2 (+ disk + swap): pl server health's own engine --------
    if ! declare -F host_health_require >/dev/null 2>&1; then
        # Fail-safe. The alternative — proceeding unmeasured — is exactly the
        # hole this gate exists to close, and a loud 30-minute deferral is a
        # far better failure mode than an unguarded claude spawn.
        loop_pf_log "PREFLIGHT DEFER: lib/host-capture.sh is not loaded, so host headroom cannot be measured"
        return 1
    fi

    # The loop's load threshold, applied to the shared evaluator. Assigned
    # rather than exported so it cannot leak into an unrelated `pl server
    # health` call later in the same shell.
    local saved_load="${HOST_MAX_LOAD_PER_CORE:-}"
    HOST_MAX_LOAD_PER_CORE="${AGENT_LOOP_MAX_LOAD_PCT:-150}"

    local hout hrc=0
    hout="$(host_health_require LOCAL "${AGENT_LOOP_MIN_MEM_MB:-2048}" "$label" 2>&1)" || hrc=$?

    HOST_MAX_LOAD_PER_CORE="$saved_load"

    if [ "$hrc" -ne 0 ]; then
        # rc 1 = measured, no headroom. rc 3 = could not measure. Both defer;
        # the distinction is kept in the log so the operator can tell a busy
        # host from a broken probe.
        if [ "$hrc" -eq 3 ]; then
            loop_pf_log "PREFLIGHT DEFER: could not measure host headroom (UNKNOWN is never treated as healthy)"
        else
            loop_pf_log "PREFLIGHT DEFER: the host has no headroom for ${label}"
        fi
        local l
        while IFS= read -r l; do
            [ -n "$l" ] && loop_pf_log "  ${l}"
        done <<<"$hout"
        return 1
    fi

    # --- signal 3: a resident ollama model ----------------------------------
    if [ "${AGENT_LOOP_REQUIRE_IDLE_OLLAMA:-1}" = "1" ]; then
        if loop_pf_ollama_model_resident; then
            loop_pf_log "PREFLIGHT DEFER: a model is resident in ollama — the local LLM is in use (VRAM is a separate pool from the RAM headroom above)"
            return 1
        fi
    fi

    # --- signal 4: concurrent gitlab-runner jobs ----------------------------
    local runner_count rrc=0
    runner_count="$(loop_pf_runner_jobs)" || rrc=$?
    if [ "$rrc" -ne 0 ]; then
        loop_pf_log "PREFLIGHT DEFER: could not count gitlab-runner job processes (blind probe defers; user=${AGENT_LOOP_RUNNER_USER:-gitlab-runner})"
        return 1
    fi
    local max_jobs="${AGENT_LOOP_MAX_RUNNER_JOBS:-0}"
    if [ "$runner_count" -gt "$max_jobs" ] 2>/dev/null; then
        loop_pf_log "PREFLIGHT DEFER: ${runner_count} gitlab-runner process(es) running (allowance ${max_jobs}) — a CI job is the heaviest thing this host does"
        return 1
    fi

    loop_pf_log "preflight OK — host has headroom for ${label} (ollama idle, ${runner_count} runner job(s))"
    return 0
}
