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
    # Map commands to verification features
    case "$command" in
        *backup*) echo "backup" ;;
        *restore*) echo "restore" ;;
        *install*) echo "install" ;;
        *delete*) echo "delete" ;;
        *copy*) echo "copy" ;;
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

# Prompt for error report on failure
prompt_error_report() {
    local command="$1"
    local exit_code="$2"

    # Check if error reporting enabled
    local prompt_enabled=$(grep -A5 "error_reporting:" nwp.yml 2>/dev/null | grep "prompt_on_failure: true" || echo "")
    if [[ -z "$prompt_enabled" ]]; then
        return
    fi

    # Only prompt on failures
    if [[ "$exit_code" == "0" ]]; then
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
