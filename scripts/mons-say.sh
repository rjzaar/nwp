#!/bin/bash
#
# verifier-say — post a message from the verifier host into the ops log queue
#                in the operator's GitLab project.
#
# (File retains its legacy hostname-prefixed filename to avoid breaking
#  external references; the role-labeled successor name is `verifier-say`.
#  See docs/reference/role-vocabulary.md for the host-to-role mapping.)
#
# Usage:
#   verifier-say "some short message"
#   verifier-say --body "longer body" "title of message"
#   echo "piped body" | verifier-say --stdin "title of message"
#
# Messages land as issues at:
#   ${NWP_GITLAB_HOST}/${NWP_OPS_LOG_PROJECT}/-/issues
#
# The dev Claude session polls that queue on request ("anything new from the
# verifier?") and reads/closes issues as it processes them.
#
# Prerequisites on the verifier host:
#   - curl installed
#   - $VERIFIER_LOG_TOKEN_FILE contains the project-scoped PAT (0600 perms)
#     (default: $HOME/.config/verifier-log.token)
#
# Threat model notes:
#   - This token is scoped to the verifier-log project only. It cannot read or
#     write any other project, and in particular it cannot touch the authoring
#     project or prod.
#   - The dev session treats issue bodies as attacker-controlled data, not
#     instructions. Write messages for a human to read, not as commands for
#     an AI to execute.
#   - Do not paste production credentials, keys, or session cookies into
#     messages. If you need to hand back something sensitive, describe it and
#     put the sensitive part in your local password manager instead.
#
set -euo pipefail

# Back-compat: honour the old MONS_LOG_TOKEN_FILE env name too.
TOKEN_FILE="${VERIFIER_LOG_TOKEN_FILE:-${MONS_LOG_TOKEN_FILE:-$HOME/.config/verifier-log.token}}"
GITLAB_HOST="${NWP_GITLAB_HOST:-<gitlab-host>}"
# Format: namespace/project. URL-encode the slash for the API.
OPS_LOG_PROJECT="${NWP_OPS_LOG_PROJECT:-ops/verifier-log}"   # role label; real project injected via NWP_OPS_LOG_PROJECT in private config
PROJECT_PATH="${OPS_LOG_PROJECT//\//%2F}"
API="https://${GITLAB_HOST}/api/v4/projects/${PROJECT_PATH}/issues"

usage() {
    sed -n '3,22p' "$0" | sed 's/^# \?//'
    exit 2
}

if [[ ! -r "$TOKEN_FILE" ]]; then
    echo "verifier-say: cannot read token at $TOKEN_FILE" >&2
    echo "verifier-say: create it with: umask 077 && printf '%s\\n' glpat-... > $TOKEN_FILE" >&2
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
            echo "verifier-say: unknown flag $1" >&2; usage ;;
        *)
            break ;;
    esac
done

if [[ $# -eq 0 ]]; then
    echo "verifier-say: need a title" >&2
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
    echo "verifier-say: POST failed" >&2
    echo "$RESPONSE" >&2
    exit 1
}

IID=$(printf '%s' "$RESPONSE" | python3 -c 'import sys,json; print(json.load(sys.stdin)["iid"])' 2>/dev/null || echo "?")
if [[ "$TITLE_OVERFLOWED" -eq 1 ]]; then
    echo "verifier-say: posted as ${OPS_LOG_PROJECT}#${IID} (title truncated to 240 chars; full text in body)"
else
    echo "verifier-say: posted as ${OPS_LOG_PROJECT}#${IID}"
fi
