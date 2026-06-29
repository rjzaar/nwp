#!/bin/bash
################################################################################
# lib/gitlab-issues.sh — sourceable GitLab issue API helpers for nwp/ops.
#
# Single home for the authenticated curl plumbing so multiple commands reuse it
# instead of duplicating the token handling:
#   - pl issue  (scripts/commands/issue.sh)  — the read+write work-board CLI
#   - pl rag --sync-issues (scripts/commands/rag.sh) — RAG → issue upsert (ops#6)
#
# Values-safe by construction: the api token is read from .secrets.yml by THIS
# lib and used only inside a 0600 curl config + a 0600 data file — never printed,
# never in argv / ps / shell history. Prefers the least-privilege
# gitlab.ops_note_token (Reporter on nwp/ops), falling back to gitlab.api_token.
#
# Provides: _host _token _api_get _api_send _jget _require_ok  (+ a guarded die).
# Config it reads (all overridable by the sourcing script BEFORE sourcing):
#   PROJECT_ROOT  SECRETS_FILE  PROJECT_ID  YQ
################################################################################

# Resolve shared config only if the sourcing script hasn't already set it. The
# `:=` defaults are no-ops when the caller pre-defines these (issue.sh does).
if [ -z "${PROJECT_ROOT:-}" ]; then
  PROJECT_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
fi
: "${SECRETS_FILE:=${NWP_SECRETS_FILE:-$PROJECT_ROOT/.secrets.yml}}"
: "${PROJECT_ID:=${NWP_OPS_PROJECT_ID:-21}}"          # nwp/ops
: "${YQ:=$(command -v yq || true)}"

# Only define die if the caller hasn't (issue.sh defines its own; rag.sh doesn't).
if ! declare -F die >/dev/null 2>&1; then
  die(){ print_error "$*" 2>/dev/null || echo "ERROR: $*" >&2; exit 1; }
fi

_host(){
  local h="${NWP_GITLAB_HOST:-}"
  [ -z "$h" ] && h=$("$YQ" e '.gitlab.server.domain // ""' "$SECRETS_FILE" 2>/dev/null | grep -v '^null$')
  [ -z "$h" ] && h="<gitlab-host>"   # real host comes from .gitlab.server.domain; placeholder keeps the live domain out of git (see .gitleaks.toml)
  printf '%s' "$h"
}

_token(){
  local t
  t=$("$YQ" e '.gitlab.ops_note_token // .gitlab.api_token // ""' "$SECRETS_FILE" 2>/dev/null | grep -v '^null$')
  [ -n "$t" ] || die "no usable token in $SECRETS_FILE (gitlab.ops_note_token / gitlab.api_token)"
  printf '%s' "$t"
}

# run an authenticated GET; prints the JSON body. token stays in a 0600 curl config.
_api_get(){ # $1 = path (e.g. /projects/21/issues?...)
  local host token cfg
  host=$(_host); token=$(_token)
  cfg=$(mktemp); chmod 600 "$cfg"
  printf 'silent\nmax-time = 20\nheader = "PRIVATE-TOKEN: %s"\nurl = "https://%s/api/v4%s"\n' "$token" "$host" "$1" > "$cfg"
  token=""
  curl -K "$cfg" 2>/dev/null
  rm -f "$cfg"
}

# run an authenticated write (POST/PUT). The JSON body is passed via a 0600 temp
# file so newlines/quotes in titles & descriptions survive, and the payload never
# lands in argv / ps / shell history. token stays in the 0600 curl config too.
_api_send(){ # $1=METHOD $2=path [$3=json-body]
  local method="$1" path="$2" payload="${3:-}"
  local host token cfg body=""
  host=$(_host); token=$(_token)
  cfg=$(mktemp); chmod 600 "$cfg"
  {
    printf 'silent\nmax-time = 30\n'
    printf 'header = "PRIVATE-TOKEN: %s"\n' "$token"
    printf 'request = "%s"\n' "$method"
    if [ -n "$payload" ]; then
      body=$(mktemp); chmod 600 "$body"; printf '%s' "$payload" > "$body"
      printf 'header = "Content-Type: application/json"\n'
      printf 'data = "@%s"\n' "$body"
    fi
    printf 'url = "https://%s/api/v4%s"\n' "$host" "$path"
  } > "$cfg"
  token=""
  curl -K "$cfg" 2>/dev/null
  rm -f "$cfg" ${body:+"$body"}
}

# extract one scalar field from a GitLab JSON object response
_jget(){ "$YQ" e -p=json ".$1 // \"\"" - 2>/dev/null | grep -v '^null$'; }

# require an expected field in a response, else die with GitLab's error message.
# prints the field value on success.
_require_ok(){ # $1=json $2=key-that-must-exist  $3=action-description
  local json="$1" key="$2" desc="$3" v msg
  v=$(printf '%s' "$json" | _jget "$key")
  if [ -z "$v" ]; then
    msg=$(printf '%s' "$json" | "$YQ" e -p=json '.message // .error // ""' - 2>/dev/null | grep -v '^null$')
    die "$desc failed${msg:+: $msg}"
  fi
  printf '%s' "$v"
}
