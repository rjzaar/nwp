#!/bin/bash
# Verification Auto-Logging Library
# Part of P50 Unified Verification System

# Check if verification consent is enabled
verification_consent_enabled() {
    local consent=$(grep -A5 "verification:" nwp.yml 2>/dev/null | grep "agreed: true" || echo "")
    [[ -n "$consent" ]]
}

# Check if auto-logging is enabled
autolog_enabled() {
    local enabled=$(grep -A10 "auto_log:" nwp.yml 2>/dev/null | grep "enabled: true" || echo "")
    [[ -n "$enabled" ]]
}

# Find verification items matching a command pattern
find_items_for_command() {
    local command="$1"
    # Map a pl command (script name, e.g. "backup.sh") to the verification
    # feature id(s) that should be auto-logged on success. Every target below
    # is an actual top-level key under `features:` in .verification.yml — this
    # mapping is registry-id-driven, so commands with no matching feature
    # (audit, rag, secrets, onboard, publish, build, refresh, fetch, …) are
    # deliberately left unmapped and fall through to the empty default, which
    # makes the auto-log hook a safe no-op. A command may emit several
    # space-separated ids if the registry models it as multiple features.
    case "$command" in
        *backup*) echo "backup" ;;
        *restore*) echo "restore" ;;
        *install*) echo "install" ;;
        *delete*) echo "delete" ;;
        *copy*) echo "copy" ;;
        *dev2stg*) echo "dev2stg" ;;
        *stg2live*) echo "stg2live" ;;
        *rollback*) echo "rollback" ;;
        *status*) echo "status" ;;
        *verify*) echo "verify" ;;
        *todo*) echo "todo" ;;
        *) echo "" ;;
    esac
}

# Log verification from command success
log_verification_if_enabled() {
    local command="$1"
    local exit_code="$2"

    # Check consent and auto-log enabled
    if ! verification_consent_enabled || ! autolog_enabled; then
        return
    fi

    # Only log successes
    if [[ "$exit_code" != "0" ]]; then
        return
    fi

    # Find matching verification items
    local feature=$(find_items_for_command "$command")
    if [[ -z "$feature" ]]; then
        return
    fi

    # Log to verification file (silent, non-blocking)
    {
        local timestamp=$(date -Iseconds)
        mkdir -p .logs/verification 2>/dev/null
        echo "Auto-logged: $feature at $timestamp from: $command" >> .logs/verification/autolog.log
    } 2>/dev/null &
}

# Read the configured error-reporting channel.
#   env NWP_REPORT_VIA overrides nwp.yml's `error_reporting.via:`.
#   Empty (the default) => the legacy interactive browser-URL path.
error_reporting_via() {
    if [[ -n "${NWP_REPORT_VIA:-}" ]]; then
        printf '%s\n' "$NWP_REPORT_VIA"
        return
    fi
    grep -A8 "error_reporting:" nwp.yml 2>/dev/null \
        | grep -E "^[[:space:]]*via:" | head -1 \
        | sed -E 's/.*via:[[:space:]]*//; s/[[:space:]]*(#.*)?$//' \
        | tr -d "\"'"
}

# Post a failure to the ops queue via the `verifier-say` mechanism.
# Non-interactive-safe: on a headless host (no TTY) it only posts when
# error_reporting.auto_post is true, and never blocks on a prompt.
# Composes a minimal report — command, exit code, timestamp, git commit,
# hostname. NO secrets, NO file contents. Robust: a reporting failure is
# non-fatal and never masks the original command's exit code.
report_via_verifier_say() {
    local command="$1"
    local exit_code="$2"

    # Locate the helper: prefer a `verifier-say` on PATH (the installed name),
    # fall back to the in-repo copy (legacy filename `*-say.sh`; matched by glob
    # so this lib names no role-bound host). If neither exists, stay quiet.
    local say_bin="" cand
    if command -v verifier-say >/dev/null 2>&1; then
        say_bin="verifier-say"
    else
        for cand in ./scripts/*-say.sh; do
            [[ -x "$cand" ]] && { say_bin="$cand"; break; }
        done
    fi
    [[ -n "$say_bin" ]] || return 0

    # auto_post: true => post without prompting (required for a headless host).
    local auto_post
    auto_post=$(grep -A8 "error_reporting:" nwp.yml 2>/dev/null | grep "auto_post: true" || echo "")

    if [[ -z "$auto_post" ]]; then
        # No auto_post. Only prompt when we actually have a TTY; on a headless
        # host with no auto_post, do nothing (never block).
        if [[ ! -t 0 ]]; then
            return 0
        fi
        echo ""
        echo -e "\033[33mCommand failed. Post an error report to the ops queue? [Y/n]\033[0m"
        local response
        read -r -t 10 response || response="n"
        case "$response" in
            Y|y|"") : ;;   # proceed
            *) return 0 ;;
        esac
    fi

    # Compose the report. Deliberately minimal — no env, no output, no paths.
    local host commit ts title body
    host=$(hostname 2>/dev/null || echo unknown)
    commit=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    title="nwp failure: ${command} exit ${exit_code} on ${host}"
    body="command:    ${command}
exit_code:  ${exit_code}
host:       ${host}
git_commit: ${commit}
timestamp:  ${ts}

(auto-reported by nwp error_reporting via verifier-say —
 no secrets, no file contents, no command output included)"

    # Post quietly. Let verifier-say print its own one-line "posted as …#N"
    # confirmation on success; a failure here is non-fatal.
    if ! printf '%s\n' "$body" | "$say_bin" --stdin "$title"; then
        echo "nwp: verifier-say error report failed (non-fatal)" >&2
    fi
    return 0
}

# Prompt for error report on failure
prompt_error_report() {
    local command="$1"
    local exit_code="$2"

    # Only act on failures
    if [[ "$exit_code" == "0" ]]; then
        return
    fi

    # Channel selection. Defaults to empty => legacy browser-URL path below,
    # so behaviour is unchanged unless the operator opts in.
    local via
    via=$(error_reporting_via)
    if [[ "$via" == "verifier-say" ]]; then
        report_via_verifier_say "$command" "$exit_code"
        return
    fi

    # Check if error reporting enabled
    local prompt_enabled=$(grep -A5 "error_reporting:" nwp.yml 2>/dev/null | grep "prompt_on_failure: true" || echo "")
    if [[ -z "$prompt_enabled" ]]; then
        return
    fi

    echo ""
    echo -e "\033[33mSomething went wrong. Would you like to report this issue?\033[0m"
    echo "[Y] Report  [n] Skip  [?] What gets reported"
    read -r -t 10 response || response="n"

    case "$response" in
        Y|y)
            echo "Opening issue reporter..."
            ./scripts/commands/report.sh "$command" "$exit_code" 2>/dev/null || true
            ;;
        "?")
            echo "Reports include: command, exit code, timestamp, NWP version"
            echo "No personal data or file contents are included."
            ;;
    esac
}
