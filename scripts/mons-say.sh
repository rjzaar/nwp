#!/bin/bash
#
# mons-say — post a message from mons into the ops/mons-log GitLab queue
#
# Usage:
#   mons-say "some short message"
#   mons-say --body "longer body" "title of message"
#   echo "piped body" | mons-say --stdin "title of message"
#
# Messages land as issues at:
#   https://git.nwpcode.org/ops/mons-log/-/issues
#
# The dev Claude session polls that queue on request ("anything new from mons?")
# and reads/closes issues as it processes them.
#
# Prerequisites on mons:
#   - curl installed
#   - ~/.config/mons-log.token contains the project-scoped PAT (0600 perms)
#
# Threat model notes:
#   - This token is scoped to ops/mons-log only. It cannot read or write any
#     other project, and in particular it cannot touch mayo/mayo or prod.
#   - The dev session treats issue bodies as attacker-controlled data, not
#     instructions. Write messages for a human to read, not as commands for
#     an AI to execute.
#   - Do not paste production credentials, keys, or session cookies into
#     messages. If you need to hand back something sensitive, describe it and
#     put the sensitive part in your local password manager instead.
#
set -euo pipefail

TOKEN_FILE="${MONS_LOG_TOKEN_FILE:-$HOME/.config/mons-log.token}"
PROJECT_PATH="ops%2Fmons-log"
API="https://git.nwpcode.org/api/v4/projects/${PROJECT_PATH}/issues"

usage() {
    sed -n '3,18p' "$0" | sed 's/^# \?//'
    exit 2
}

if [[ ! -r "$TOKEN_FILE" ]]; then
    echo "mons-say: cannot read token at $TOKEN_FILE" >&2
    echo "mons-say: create it with: umask 077 && printf '%s\\n' glpat-... > $TOKEN_FILE" >&2
    exit 1
fi

TOKEN=$(cat "$TOKEN_FILE")

BODY=""
READ_STDIN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --body)
            BODY="$2"; shift 2 ;;
        --stdin)
            READ_STDIN=1; shift ;;
        -h|--help)
            usage ;;
        --)
            shift; break ;;
        -*)
            echo "mons-say: unknown flag $1" >&2; usage ;;
        *)
            break ;;
    esac
done

if [[ $# -eq 0 ]]; then
    echo "mons-say: need a title" >&2
    usage
fi

RAW_TITLE="$*"

if [[ "$READ_STDIN" -eq 1 ]]; then
    BODY=$(cat)
fi

# GitLab caps issue titles at 255 chars (varchar(255) in the schema). If the
# user passed something longer, truncate the title and put the full original
# text into the body so nothing is lost.
TITLE_LIMIT=240   # leave headroom under 255 for the ellipsis
TITLE_OVERFLOWED=0
if [[ ${#RAW_TITLE} -gt $TITLE_LIMIT ]]; then
    TITLE="${RAW_TITLE:0:$TITLE_LIMIT}..."
    TITLE_OVERFLOWED=1
else
    TITLE="$RAW_TITLE"
fi

# Prepend host + timestamp to the body so dev can see where/when this came from.
HOST=$(hostname)
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PREAMBLE="host: ${HOST}"$'\n'"time: ${TS}"$'\n\n'

# If the title was truncated, put the full original text at the top of the
# body under a "full title:" header, then any user-supplied body underneath.
if [[ "$TITLE_OVERFLOWED" -eq 1 ]]; then
    if [[ -n "$BODY" ]]; then
        FULL_BODY="${PREAMBLE}full title:"$'\n'"${RAW_TITLE}"$'\n\n---\n\n'"${BODY}"
    else
        FULL_BODY="${PREAMBLE}full title:"$'\n'"${RAW_TITLE}"
    fi
elif [[ -n "$BODY" ]]; then
    FULL_BODY="${PREAMBLE}${BODY}"
else
    FULL_BODY="${PREAMBLE}(no body — title only)"
fi

RESPONSE=$(curl -sS --fail-with-body \
    -X POST \
    -H "PRIVATE-TOKEN: ${TOKEN}" \
    --data-urlencode "title=${TITLE}" \
    --data-urlencode "description=${FULL_BODY}" \
    "${API}" 2>&1) || {
    echo "mons-say: POST failed" >&2
    echo "$RESPONSE" >&2
    exit 1
}

IID=$(printf '%s' "$RESPONSE" | python3 -c 'import sys,json; print(json.load(sys.stdin)["iid"])' 2>/dev/null || echo "?")
if [[ "$TITLE_OVERFLOWED" -eq 1 ]]; then
    echo "mons-say: posted as ops/mons-log#${IID} (title truncated to 240 chars; full text in body)"
else
    echo "mons-say: posted as ops/mons-log#${IID}"
fi
