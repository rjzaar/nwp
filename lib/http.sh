#!/bin/bash
################################################################################
# lib/http.sh — the one place NWP decides how long to wait for the network.
#
# WHY THIS EXISTS
#
# `grep -rnE "curl -[a-zA-Z]*s" --include=*.sh lib/ scripts/commands/ |
#  grep -v -- "--max-time"` returned 124 call sites with no timeout at all. On a
# low-latency link they return instantly; on a higher-latency one curl's own
# defaults take over — ~2 minutes to give up on a connect, and effectively
# unbounded for a transfer that stalls mid-body. That is how `pl rag` went from
# seconds to >200s and how the */30 `pl fleet publish` cron started exiting 124
# and publishing nothing.
#
# The bug is not any one of those 124 sites. The bug is that there was no shared
# answer to "how long should NWP wait?", so every site invented one (usually
# "forever"). This file is that answer. Fix the policy here, not in 124 places.
#
# ── A TIMEOUT IS NOT AN ERROR. IT IS "I COULD NOT TELL." ──────────────────────
#
# This is already NWP's vocabulary and this library reuses it rather than
# inventing a 5th spelling:
#
#   lib/boundary.sh        return 2  = CANNOT-VERIFY
#   pl secrets audit       return 2  = host unreachable, did not probe
#   scripts/nwp-daily-audit.sh       COULD_NOT_AUDIT
#   lib/todo-checks.sh     todo_add_unknown() -> UNK item -> `pl rag` cannot grade GREEN
#
# So: NWP_HTTP_RC_UNREACHABLE = 2. A caller that maps rc 2 to "no findings" has
# reintroduced the false-green this library exists to prevent. Map it to UNKNOWN.
#
#   rc 0  the server answered                     -> body on stdout, believe it
#   rc 1  the server answered with an HTTP error  -> a real verdict (401 = dead
#                                                    token). NOT unknown.
#   rc 2  no answer: DNS/connect/timeout/TLS      -> UNKNOWN. Assert nothing.
#
# ── INTERACTIVE vs BATCH ─────────────────────────────────────────────────────
#
# There is no single right number, because there are two callers with opposite
# needs:
#
#   an operator running `pl rag` wants an answer in SECONDS, with the parts we
#   could not reach marked UNKNOWN. Retrying three times in front of a human
#   turns a 30s cap into a 90s stall and buys nothing they wanted.
#
#   a nightly cron has all night, nobody is waiting, and a transient blip that
#   costs it a whole night of data is a worse outcome than waiting. It should
#   retry before declaring blindness.
#
# Hence two profiles. How the context is determined (first match wins):
#
#   1. $NWP_HTTP_PROFILE is set to `interactive` or `batch`  — explicit, wins.
#   2. any of stdin/stdout/stderr is a TTY                   -> interactive
#   3. otherwise                                             -> batch
#
# Rule 2 is the load-bearing one and it is chosen deliberately over checking
# stdout alone: an operator running `pl rag --json > f` or `pl todo check --json
# | jq` has redirected stdout but still has a terminal on stderr. cron, CI,
# systemd timers and the agent-loop have a terminal on none of the three. So
# `pl rag --json | jq` stays fast, and the same command from crontab retries.
#
# Any individual budget can still be overridden per-invocation:
#   NWP_HTTP_CONNECT_TIMEOUT  NWP_HTTP_MAX_TIME  NWP_HTTP_ATTEMPTS
#
# ── ON RETRIES AND LATENCY MULTIPLICATION ────────────────────────────────────
#
# Retries multiply latency: N attempts of an M-second cap is N*M seconds of
# worst case, plus backoff. That is affordable for a nightly job and never for
# an interactive one. Batch is therefore deliberately modest (2 attempts, not
# 3), and any caller that runs on a tight schedule (`pl fleet publish` is */30,
# not nightly) must ALSO impose a hard per-unit deadline of its own rather than
# trusting the sum of the per-call budgets. Belt and braces: the budget bounds
# one call, the deadline bounds the job.
################################################################################

# Guard against double-sourcing (common.sh, todo-checks.sh and command scripts
# may each pull this in).
[ -n "${NWP_HTTP_SH_LOADED:-}" ] && return 0
NWP_HTTP_SH_LOADED=1

# The "I could not tell" exit code. Same meaning as lib/boundary.sh's rc 2.
NWP_HTTP_RC_UNREACHABLE=2
NWP_HTTP_RC_HTTP_ERROR=1

# Interactive: a human is watching. One shot, give up fast, report UNKNOWN.
: "${NWP_HTTP_INTERACTIVE_CONNECT:=4}"
: "${NWP_HTTP_INTERACTIVE_MAXTIME:=8}"
: "${NWP_HTTP_INTERACTIVE_ATTEMPTS:=1}"

# Batch: nobody is waiting. Wait longer and retry before declaring blindness.
: "${NWP_HTTP_BATCH_CONNECT:=8}"
: "${NWP_HTTP_BATCH_MAXTIME:=20}"
: "${NWP_HTTP_BATCH_ATTEMPTS:=2}"

# Seconds to sleep between attempts (doubled each time). Batch only.
: "${NWP_HTTP_BACKOFF:=2}"

################################################################################
# Policy
################################################################################

# Which profile is in force. Prints `interactive` or `batch`.
nwp_http_profile() {
    case "${NWP_HTTP_PROFILE:-}" in
        interactive|batch) printf '%s' "$NWP_HTTP_PROFILE"; return 0 ;;
        "") ;;
        *) # A typo must not silently pick a policy. Say so, then be safe (fast).
           printf 'lib/http.sh: unknown NWP_HTTP_PROFILE=%s (want interactive|batch) — using interactive\n' \
               "$NWP_HTTP_PROFILE" >&2
           printf 'interactive'; return 0 ;;
    esac
    if [ -t 0 ] || [ -t 1 ] || [ -t 2 ]; then printf 'interactive'; else printf 'batch'; fi
}

nwp_http_connect_timeout() {
    if [ -n "${NWP_HTTP_CONNECT_TIMEOUT:-}" ]; then printf '%s' "$NWP_HTTP_CONNECT_TIMEOUT"; return 0; fi
    case "$(nwp_http_profile)" in
        batch) printf '%s' "$NWP_HTTP_BATCH_CONNECT" ;;
        *)     printf '%s' "$NWP_HTTP_INTERACTIVE_CONNECT" ;;
    esac
}

nwp_http_max_time() {
    if [ -n "${NWP_HTTP_MAX_TIME:-}" ]; then printf '%s' "$NWP_HTTP_MAX_TIME"; return 0; fi
    case "$(nwp_http_profile)" in
        batch) printf '%s' "$NWP_HTTP_BATCH_MAXTIME" ;;
        *)     printf '%s' "$NWP_HTTP_INTERACTIVE_MAXTIME" ;;
    esac
}

nwp_http_attempts() {
    if [ -n "${NWP_HTTP_ATTEMPTS:-}" ]; then printf '%s' "$NWP_HTTP_ATTEMPTS"; return 0; fi
    case "$(nwp_http_profile)" in
        batch) printf '%s' "$NWP_HTTP_BATCH_ATTEMPTS" ;;
        *)     printf '%s' "$NWP_HTTP_INTERACTIVE_ATTEMPTS" ;;
    esac
}

# One-line human description, for banners and UNKNOWN reasons.
nwp_http_budget_desc() {
    printf '%s profile: connect %ss, total %ss, %s attempt(s)' \
        "$(nwp_http_profile)" "$(nwp_http_connect_timeout)" \
        "$(nwp_http_max_time)" "$(nwp_http_attempts)"
}

################################################################################
# Emitters — for call sites that must keep building their own curl invocation
################################################################################

# Timeout flags for a plain `curl ... $(nwp_http_curl_args)` call site.
# Word-splitting is intended here; these are two numeric flags.
nwp_http_curl_args() {
    printf -- '--connect-timeout %s --max-time %s' \
        "$(nwp_http_connect_timeout)" "$(nwp_http_max_time)"
}

# The same budget as `curl -K` config lines, for the 0600-config pattern that
# keeps tokens out of argv (see lib/gitlab-issues.sh, scripts/commands/secrets.sh).
# CLAUDE.md: never let a token reach curl's argv, where `ps` can read it.
nwp_http_config_lines() {
    printf 'connect-timeout = %s\nmax-time = %s\n' \
        "$(nwp_http_connect_timeout)" "$(nwp_http_max_time)"
}

################################################################################
# The helper itself
################################################################################

# Map a curl exit status onto NWP's verdict vocabulary.
#   "could not tell" = we never got an answer from the far end.
_nwp_http_classify() { # $1 = curl exit status
    case "$1" in
        0)  return 0 ;;
        # 5 no proxy host, 6 no host (DNS), 7 connect refused/unreachable,
        # 28 operation timed out, 35 TLS handshake, 52 empty reply,
        # 55/56 send/recv failure. None of these is a verdict about the resource.
        5|6|7|28|35|52|55|56) return "$NWP_HTTP_RC_UNREACHABLE" ;;
        # 22 = HTTP >= 400 under -f. The server answered; that IS a verdict.
        22) return "$NWP_HTTP_RC_HTTP_ERROR" ;;
        *)  return "$NWP_HTTP_RC_UNREACHABLE" ;;
    esac
}

# nwp_http_get <url> [extra curl-config line]...
#
# Performs an authenticated-or-not GET under the active budget and prints the
# response body on stdout. Extra arguments are appended verbatim to a 0600 curl
# config file, so credentials are passed as
#     nwp_http_get "$url" "header = \"PRIVATE-TOKEN: $token\""
# and never appear in argv / ps / shell history. The config is removed before
# the function returns, on every path.
#
# Returns 0 / 1 / 2 per the vocabulary at the top of this file. On rc 2 nothing
# is printed — the caller MUST NOT read the empty output as "nothing found".
nwp_http_get() {
    local url="$1"; shift
    local attempts backoff i=0 rc=0 status cfg
    attempts=$(nwp_http_attempts)
    backoff="$NWP_HTTP_BACKOFF"

    cfg=$(mktemp) || return "$NWP_HTTP_RC_UNREACHABLE"
    chmod 600 "$cfg"
    {
        printf 'silent\nfail\nlocation\n'
        nwp_http_config_lines
        local line
        for line in "$@"; do printf '%s\n' "$line"; done
        printf 'url = "%s"\n' "$url"
    } > "$cfg"

    while :; do
        i=$((i + 1))
        status=0
        curl -K "$cfg" 2>/dev/null || status=$?
        _nwp_http_classify "$status"; rc=$?
        # Retry only what a retry can fix: an unanswered call. An HTTP 401 will
        # be 401 again in two seconds, and re-probing an auth endpoint that is
        # rate-limiting us makes the answer worse, not better.
        if [ "$rc" -ne "$NWP_HTTP_RC_UNREACHABLE" ] || [ "$i" -ge "$attempts" ]; then
            break
        fi
        sleep "$backoff"
        backoff=$((backoff * 2))
    done

    rm -f "$cfg"
    return "$rc"
}

# Convenience for the common NWP case: an authenticated GitLab API GET.
#   nwp_http_gitlab_get <host> <path> <token>
# Token goes into the 0600 config, never argv.
nwp_http_gitlab_get() {
    local host="$1" path="$2" token="$3"
    nwp_http_get "https://${host}/api/v4${path}" "header = \"PRIVATE-TOKEN: ${token}\""
}
