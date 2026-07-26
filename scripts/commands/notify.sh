#!/bin/bash
set -uo pipefail

################################################################################
# pl notify — THE notification path, and a way to prove it works.
#
# WHY THIS EXISTS
#
# Every producer used to curl Gotify with its own inline token and its own
# `|| true`:
#   scripts/secrets-daily-audit.sh   curl the message URL with the token inline, then `|| true`
#   scripts/console/app/config.py    its own token file
# Consequences, all observed:
#   1. A failed notification was indistinguishable from a successful one,
#      because `|| true` discards exactly the signal you wanted.
#   2. The token went into the URL, i.e. into /proc/<pid>/cmdline, readable by
#      any local user.
#   3. There was NO way to ask "can this machine notify me at all?" — so the
#      security detector could sit un-fired against a real server indefinitely
#      and nothing said so. The notification system could not notify you that it
#      could not notify you.
#
# This verb is the single path, it fails loudly, it passes the token through a
# 0600 curl config file (never argv), and `pl notify health` is a real probe
# whose failure `pl todo` surfaces.
#
# Usage:
#   pl notify send <app> "message" [--priority N] [--title T]
#   pl notify health [<app>]
# Exit: 0 delivered · 1 usage · 2 not configured · 3 delivery failed
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

source "$PROJECT_ROOT/lib/ui.sh" 2>/dev/null || true
source "$PROJECT_ROOT/lib/common.sh" 2>/dev/null || true

SECRETS_FILE="${NWP_SECRETS_FILE:-$PROJECT_ROOT/.secrets.yml}"

show_help() {
    cat <<EOF
${BOLD:-}pl notify${NC:-} — send an operator notification, and prove the path works

${BOLD:-}USAGE:${NC:-}
    pl notify send <app> "message" [--priority N] [--title T]
    pl notify health [<app>]

${BOLD:-}SUBCOMMANDS:${NC:-}
    send      Deliver a message. Exits NON-ZERO if it was not delivered.
    health    Deliver a canary and assert the server stored it. Exits non-zero
              if this machine cannot notify you — which is the whole point.

${BOLD:-}CONFIG (.secrets.yml):${NC:-}
    gotify.url                  base URL of the Gotify server
    gotify.<app>_token          per-app write token (e.g. gotify.ops_token)
    gotify.mini_health_token    fallback used when no per-app token exists

${BOLD:-}OVERRIDES (for tests / one-offs):${NC:-}
    NWP_NOTIFY_URL, NWP_NOTIFY_TOKEN

${BOLD:-}NOTE:${NC:-} the token is passed to curl through a 0600 config file, never on
the command line and never in the URL — a token in argv is readable from
/proc/<pid>/cmdline by any local user.
EOF
}

_secret() {  # $1 = yq path
    [ -f "$SECRETS_FILE" ] || return 1
    command -v yq >/dev/null 2>&1 || return 1
    yq eval "$1 // \"\"" "$SECRETS_FILE" 2>/dev/null | grep -v '^null$' | head -1
}

# Resolve the endpoint + token for an app. Never prints the token.
# Sets NOTIFY_URL and NOTIFY_TOKEN. Returns 2 when not configured.
_resolve() {
    local app="${1:-ops}"
    NOTIFY_URL="${NWP_NOTIFY_URL:-}"
    NOTIFY_TOKEN="${NWP_NOTIFY_TOKEN:-}"

    [ -z "$NOTIFY_URL" ]   && NOTIFY_URL="$(_secret '.gotify.url' || true)"
    if [ -z "$NOTIFY_TOKEN" ]; then
        NOTIFY_TOKEN="$(_secret ".gotify.${app}_token" || true)"
        [ -z "$NOTIFY_TOKEN" ] && NOTIFY_TOKEN="$(_secret '.gotify.mini_health_token' || true)"
    fi

    if [ -z "$NOTIFY_URL" ]; then
        printf 'notify: NOT CONFIGURED — no gotify.url in %s and no NWP_NOTIFY_URL\n' "$SECRETS_FILE" >&2
        return 2
    fi
    if [ -z "$NOTIFY_TOKEN" ]; then
        printf 'notify: NOT CONFIGURED — no token for app "%s" (gotify.%s_token) and no NWP_NOTIFY_TOKEN\n' "$app" "$app" >&2
        return 2
    fi
    return 0
}

# POST a message. Echoes the server's response body on success.
# The token goes in a 0600 curl config file so it never reaches argv.
_post() {
    local app="$1" message="$2" priority="$3" title="$4"

    local cfg; cfg="$(mktemp)" || return 3
    chmod 600 "$cfg"
    # `header` entries in a curl config file are read from the file, so the
    # secret never appears in the process table.
    printf 'header = "X-Gotify-Key: %s"\n' "$NOTIFY_TOKEN" > "$cfg"

    local body http rc=0
    body=$(curl -sS --max-time 15 -w '\n%{http_code}' \
             -K "$cfg" \
             -H 'Content-Type: application/json' \
             --data-binary @- \
             "${NOTIFY_URL%/}/message" <<EOF
{"title":$(_json "$title"),"message":$(_json "$message"),"priority":$priority}
EOF
    ) || rc=$?
    rm -f "$cfg"

    if [ "$rc" -ne 0 ]; then
        printf 'notify: FAIL — %s is unreachable (curl exit %s)\n' "${NOTIFY_URL%/}" "$rc" >&2
        return 3
    fi

    http="${body##*$'\n'}"
    body="${body%$'\n'*}"
    if [ "$http" != "200" ]; then
        printf 'notify: FAIL — server returned HTTP %s\n' "$http" >&2
        return 3
    fi
    printf '%s\n' "$body"
    return 0
}

_json() { python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1"; }

cmd_send() {
    local app="${1:-}"; shift || true
    local message="${1:-}"; shift || true
    local priority=5 title="NWP"

    while [ $# -gt 0 ]; do
        case "$1" in
            --priority) priority="${2:-5}"; shift 2 ;;
            --priority=*) priority="${1#*=}"; shift ;;
            --title) title="${2:-NWP}"; shift 2 ;;
            --title=*) title="${1#*=}"; shift ;;
            *) shift ;;
        esac
    done

    if [ -z "$app" ] || [ -z "$message" ]; then
        printf 'usage: pl notify send <app> "message" [--priority N] [--title T]\n' >&2
        return 1
    fi

    _resolve "$app" || return $?

    local resp
    resp=$(_post "$app" "$message" "$priority" "$title") || return $?

    # Report the stored message id: proof the server accepted AND persisted it,
    # not merely that a socket opened.
    local id
    id=$(printf '%s' "$resp" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("id",""))
except Exception: print("")' 2>/dev/null)
    if [ -z "$id" ]; then
        printf 'notify: FAIL — server returned 200 but no message id (did it store it?)\n' >&2
        return 3
    fi
    printf 'notify: delivered (message id %s)\n' "$id"
    return 0
}

cmd_health() {
    local app="${1:-ops}"

    if ! _resolve "$app"; then
        printf 'notify health: FAIL — this machine cannot notify you (not configured)\n' >&2
        return 2
    fi

    local stamp; stamp=$(date -u +%FT%TZ)
    local resp rc=0
    resp=$(_post "$app" "pl notify health canary $stamp on $(hostname)" 1 "NWP notify health") || rc=$?
    if [ "$rc" -ne 0 ]; then
        printf 'notify health: FAIL — this machine cannot notify you\n' >&2
        return 3
    fi

    local id
    id=$(printf '%s' "$resp" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("id",""))
except Exception: print("")' 2>/dev/null)
    if [ -z "$id" ]; then
        printf 'notify health: FAIL — 200 with no stored message id\n' >&2
        return 3
    fi

    printf 'notify health: OK — canary stored as message id %s\n' "$id"
    # Record the last known-good so pl todo can age it (an alert path that has
    # not been exercised in weeks is not a working alert path).
    mkdir -p "$PROJECT_ROOT/private" 2>/dev/null || true
    printf '%s\n' "$stamp" > "$PROJECT_ROOT/private/.notify-last-ok" 2>/dev/null || true
    return 0
}

main() {
    local sub="${1:-}"
    case "$sub" in
        -h|--help|help|"") show_help; return 0 ;;
        send)   shift; cmd_send "$@" ;;
        health) shift; cmd_health "$@" ;;
        *) printf 'pl notify: unknown subcommand "%s"\n\n' "$sub" >&2; show_help >&2; return 1 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
